//! The hub the devices are reached through: Zigbee2MQTT (over MQTT, kept
//! connected by a thread of its own that holds every device's latest
//! state) or Home Assistant (its REST API, asked when needed).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const model = @import("model.zig");
const mqtt = @import("mqtt.zig");
const http = @import("http.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");

pub const State = struct {
    props: model.Props,
    /// seconds since the state last changed; null when unknown
    age_s: ?f64 = null,
};

pub const Secrets = struct {
    ha_token: []const u8 = "",
    mqtt_user: ?[]const u8 = null,
    mqtt_password: ?[]const u8 = null,
};

pub const Hub = union(enum) {
    z2m: *Z2m,
    ha: *Ha,

    pub fn start(gpa: Allocator, io: Io, cfg: *const config.Config, secrets: Secrets) !Hub {
        switch (cfg.hub) {
            .zigbee2mqtt => {
                const z = try gpa.create(Z2m);
                z.* = try .init(gpa, io, cfg, secrets);
                z.thread = try std.Thread.spawn(.{}, Z2m.loop, .{z});
                return .{ .z2m = z };
            },
            .homeassistant => {
                const h = try gpa.create(Ha);
                h.* = .{ .gpa = gpa, .io = io, .cfg = cfg, .token = secrets.ha_token, .client = .init(gpa, io, try http.Target.parse(cfg.url)) };
                h.client.user_agent = "homemcp";
                return .{ .ha = h };
            },
        }
    }

    pub fn stop(h: Hub) void {
        switch (h) {
            .z2m => |z| z.stop(),
            .ha => |x| {
                x.client.deinit();
                x.gpa.destroy(x);
            },
        }
    }

    /// Every device's state, in the order of the config.
    pub fn states(h: Hub, a: Allocator) ![]State {
        return switch (h) {
            .z2m => |z| z.states(a),
            .ha => |x| x.states(a),
        };
    }

    /// One line on how the hub is reached.
    pub fn status(h: Hub, a: Allocator) ![]const u8 {
        return switch (h) {
            .z2m => |z| z.status(a),
            .ha => |x| std.fmt.allocPrint(a, "Home Assistant at {s}{s}{s}", .{ x.cfg.url, if (x.problem.len > 0) ": the last request failed: " else "", x.problem }),
        };
    }

    /// Sends an action to a device. `number` and `text` as the action needs.
    pub fn command(h: Hub, a: Allocator, dev: *const config.Device, action: model.Action, number: ?f64, text: ?[]const u8) !void {
        return switch (h) {
            .z2m => |z| z.command(a, dev, action, number, text),
            .ha => |x| x.command(a, dev, action, number, text),
        };
    }
};

// ---- Zigbee2MQTT ----

pub const Z2m = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    secrets: Secrets,
    lock: Io.Mutex = .init,
    json: [][]u8,
    at_ns: []i128,
    available: []?bool,
    bridge: ?bool = null,
    client: ?*mqtt.Client = null,
    problem: []u8 = &.{},
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn init(gpa: Allocator, io: Io, cfg: *const config.Config, secrets: Secrets) !Z2m {
        const n = cfg.devices.len;
        const json = try gpa.alloc([]u8, n);
        for (json) |*j| j.* = &.{};
        const at = try gpa.alloc(i128, n);
        @memset(at, 0);
        const av = try gpa.alloc(?bool, n);
        @memset(av, null);
        return .{ .gpa = gpa, .io = io, .cfg = cfg, .secrets = secrets, .json = json, .at_ns = at, .available = av };
    }

    fn stop(z: *Z2m) void {
        z.stopping.store(true, .release);
        if (z.thread) |th| th.join();
        for (z.json) |j| z.gpa.free(j);
        z.gpa.free(z.json);
        z.gpa.free(z.at_ns);
        z.gpa.free(z.available);
        z.gpa.free(z.problem);
        z.gpa.destroy(z);
    }

    fn setProblem(z: *Z2m, what: []const u8) void {
        z.lock.lockUncancelable(z.io);
        defer z.lock.unlock(z.io);
        z.gpa.free(z.problem);
        z.problem = z.gpa.dupe(u8, what) catch &.{};
    }

    fn loop(z: *Z2m) void {
        var backoff_ms: u32 = 500;
        while (!z.stopping.load(.acquire)) {
            if (z.session()) {
                backoff_ms = 500;
            } else |e| {
                z.setProblem(@errorName(e));
            }
            var waited: u32 = 0;
            while (waited < backoff_ms and !z.stopping.load(.acquire)) : (waited += 100) z.io.sleep(.fromMilliseconds(100), .awake) catch {};
            backoff_ms = @min(backoff_ms * 2, 10_000);
        }
    }

    fn session(z: *Z2m) !void {
        const c = try z.gpa.create(mqtt.Client);
        defer z.gpa.destroy(c);
        var id_buf: [32]u8 = undefined;
        var rnd: [4]u8 = undefined;
        z.io.randomSecure(&rnd) catch {};
        const client_id = try std.fmt.bufPrint(&id_buf, "homemcp-{x}", .{std.mem.readInt(u32, &rnd, .little)});
        try c.connect(z.gpa, z.io, z.cfg.mqtt_host, z.cfg.mqtt_port, client_id, z.secrets.mqtt_user, z.secrets.mqtt_password, 30);
        {
            z.lock.lockUncancelable(z.io);
            defer z.lock.unlock(z.io);
            z.client = c;
            z.gpa.free(z.problem);
            z.problem = &.{};
        }
        defer {
            z.lock.lockUncancelable(z.io);
            z.client = null;
            z.lock.unlock(z.io);
            c.close();
        }
        var topic_buf: [512]u8 = undefined;
        try c.subscribe(try std.fmt.bufPrint(&topic_buf, "{s}/#", .{z.cfg.base}));
        // Zigbee2MQTT does not keep device states on the broker: ask
        for (z.cfg.devices) |d| {
            c.publish(try std.fmt.bufPrint(&topic_buf, "{s}/{s}/get", .{ z.cfg.base, d.id }), "{\"state\":\"\"}", false) catch {};
        }
        while (!z.stopping.load(.acquire)) {
            if (try c.next(500)) |m| z.handle(m);
            try c.keepAlive();
        }
        c.bye();
    }

    fn handle(z: *Z2m, m: mqtt.Message) void {
        if (m.topic.len <= z.cfg.base.len + 1 or !std.mem.startsWith(u8, m.topic, z.cfg.base) or m.topic[z.cfg.base.len] != '/') return;
        const rel = m.topic[z.cfg.base.len + 1 ..];
        z.lock.lockUncancelable(z.io);
        defer z.lock.unlock(z.io);
        if (std.mem.eql(u8, rel, "bridge/state")) {
            z.bridge = online(m.payload);
            return;
        }
        for (z.cfg.devices, 0..) |d, i| {
            if (std.mem.eql(u8, rel, d.id)) {
                const copy = z.gpa.dupe(u8, m.payload) catch return;
                z.gpa.free(z.json[i]);
                z.json[i] = copy;
                z.at_ns[i] = sock.nowNs(z.io);
                return;
            }
            if (rel.len == d.id.len + "/availability".len and std.mem.startsWith(u8, rel, d.id) and std.mem.endsWith(u8, rel, "/availability")) {
                z.available[i] = online(m.payload);
                return;
            }
        }
    }

    /// `{"state":"online"}` or plain `online`.
    fn online(payload: []const u8) ?bool {
        const p = std.mem.trim(u8, payload, " \r\n");
        if (std.mem.eql(u8, p, "online")) return true;
        if (std.mem.eql(u8, p, "offline")) return false;
        if (std.mem.indexOf(u8, p, "\"online\"") != null) return true;
        if (std.mem.indexOf(u8, p, "\"offline\"") != null) return false;
        return null;
    }

    fn states(z: *Z2m, a: Allocator) ![]State {
        const out = try a.alloc(State, z.cfg.devices.len);
        const now = sock.nowNs(z.io);
        z.lock.lockUncancelable(z.io);
        defer z.lock.unlock(z.io);
        for (z.cfg.devices, 0..) |d, i| {
            var p: model.Props = .{};
            if (z.json[i].len > 0) if (jv.parse(a, try a.dupe(u8, z.json[i]))) |v| {
                p = model.fromZ2m(d.kind, v);
            };
            p.available = z.available[i];
            if (z.bridge == false) p.available = false;
            out[i] = .{ .props = p, .age_s = if (z.at_ns[i] > 0) @as(f64, @floatFromInt(now - z.at_ns[i])) / std.time.ns_per_s else null };
        }
        return out;
    }

    fn status(z: *Z2m, a: Allocator) ![]const u8 {
        z.lock.lockUncancelable(z.io);
        defer z.lock.unlock(z.io);
        const where = try std.fmt.allocPrint(a, "Zigbee2MQTT through the broker at {s}:{d}", .{ z.cfg.mqtt_host, z.cfg.mqtt_port });
        if (z.client == null) return std.fmt.allocPrint(a, "{s}: not connected{s}{s}, trying again", .{ where, if (z.problem.len > 0) " (" else "", if (z.problem.len > 0) try std.fmt.allocPrint(a, "{s})", .{z.problem}) else "" });
        return std.fmt.allocPrint(a, "{s}: connected, bridge {s}", .{ where, if (z.bridge) |b| (if (b) "online" else "OFFLINE") else "not heard from yet" });
    }

    fn command(z: *Z2m, a: Allocator, dev: *const config.Device, action: model.Action, number: ?f64, text: ?[]const u8) !void {
        const i = z.cfg.device(dev.name).?;
        const payload: []const u8 = switch (action) {
            .on => "{\"state\":\"ON\"}",
            .off => "{\"state\":\"OFF\"}",
            .brightness => try std.fmt.allocPrint(a, "{{\"state\":\"ON\",\"brightness\":{d}}}", .{@as(i64, @intFromFloat(@round(number.? * 254.0 / 100.0)))}),
            .temperature => blk: {
                // the device's own setpoint property: never both
                z.lock.lockUncancelable(z.io);
                const occupied = std.mem.indexOf(u8, z.json[i], "occupied_heating_setpoint") != null;
                z.lock.unlock(z.io);
                break :blk try std.fmt.allocPrint(a, "{{\"{s}\":{s}}}", .{ if (occupied) "occupied_heating_setpoint" else "current_heating_setpoint", model.num(number.?) });
            },
            .mode => try std.fmt.allocPrint(a, "{{\"system_mode\":{f}}}", .{std.json.fmt(text.?, .{})}),
            .open => if (dev.kind == .valve) "{\"state\":\"ON\"}" else "{\"state\":\"OPEN\"}",
            .close => if (dev.kind == .valve) "{\"state\":\"OFF\"}" else "{\"state\":\"CLOSE\"}",
            .stop => "{\"state\":\"STOP\"}",
            .position => try std.fmt.allocPrint(a, "{{\"position\":{d}}}", .{@as(i64, @intFromFloat(@round(number.?)))}),
            .lock => "{\"state\":\"LOCK\"}",
            .unlock => "{\"state\":\"UNLOCK\"}",
            .arm_home, .arm_away, .disarm => return error.NotSupportedByHub,
        };
        const topic = try std.fmt.allocPrint(a, "{s}/{s}/set", .{ z.cfg.base, dev.id });
        z.lock.lockUncancelable(z.io);
        defer z.lock.unlock(z.io);
        const c = z.client orelse return error.NotConnected;
        try c.publish(topic, payload, false);
    }
};

// ---- Home Assistant ----

pub const Ha = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.Config,
    token: []const u8,
    client: http.Client,
    problem: []const u8 = "",

    fn states(h: *Ha, a: Allocator) ![]State {
        const ans = http.fetch(&h.client, a, .{
            .method = .GET,
            .path = "/api/states",
            .key = h.token,
            .limits = .{ .idle_ms = 10_000, .total_ms = 20_000 },
        }) catch |e| {
            h.problem = @errorName(e);
            return e;
        };
        if (ans.status == 401) {
            h.problem = "the token was refused (HA_TOKEN)";
            return error.Unauthorized;
        }
        if (ans.status != 200) {
            h.problem = "an unexpected answer";
            return error.BadAnswer;
        }
        h.problem = "";
        const list = jv.arr(jv.parse(a, ans.body)) orelse return error.BadAnswer;
        const out = try a.alloc(State, h.cfg.devices.len);
        for (h.cfg.devices, 0..) |d, i| {
            out[i] = .{ .props = .{ .available = false } };
            for (list) |s| if (std.mem.eql(u8, jv.str(jv.get(s, "entity_id")) orelse "", d.id)) {
                out[i] = .{ .props = model.fromHa(d.kind, s), .age_s = ageOf(h.io, jv.str(jv.get(s, "last_changed"))) };
                break;
            };
        }
        return out;
    }

    fn command(h: *Ha, a: Allocator, dev: *const config.Device, action: model.Action, number: ?f64, text: ?[]const u8) !void {
        const domain = dev.id[0..std.mem.indexOfScalar(u8, dev.id, '.').?];
        const id = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(dev.id, .{})});
        const Call = struct { service: []const u8, extra: []const u8 = "" };
        const call: Call = switch (action) {
            .on => .{ .service = "turn_on" },
            .off => .{ .service = "turn_off" },
            .brightness => .{ .service = "turn_on", .extra = try std.fmt.allocPrint(a, ",\"brightness_pct\":{d}", .{@as(i64, @intFromFloat(@round(number.?)))}) },
            .temperature => .{ .service = "set_temperature", .extra = try std.fmt.allocPrint(a, ",\"temperature\":{s}", .{model.num(number.?)}) },
            .mode => .{ .service = "set_hvac_mode", .extra = try std.fmt.allocPrint(a, ",\"hvac_mode\":{f}", .{std.json.fmt(text.?, .{})}) },
            .open => .{ .service = if (dev.kind == .valve) "open_valve" else "open_cover" },
            .close => .{ .service = if (dev.kind == .valve) "close_valve" else "close_cover" },
            .stop => .{ .service = "stop_cover" },
            .position => .{ .service = "set_cover_position", .extra = try std.fmt.allocPrint(a, ",\"position\":{d}", .{@as(i64, @intFromFloat(@round(number.?)))}) },
            .lock => .{ .service = "lock" },
            .unlock => .{ .service = "unlock" },
            .arm_home => .{ .service = "alarm_arm_home" },
            .arm_away => .{ .service = "alarm_arm_away" },
            .disarm => .{ .service = "alarm_disarm" },
        };
        const ans = http.fetch(&h.client, a, .{
            .path = try std.fmt.allocPrint(a, "/api/services/{s}/{s}", .{ domain, call.service }),
            .body = try std.fmt.allocPrint(a, "{{\"entity_id\":{s}{s}}}", .{ id, call.extra }),
            .key = h.token,
            .limits = .{ .idle_ms = 15_000, .total_ms = 30_000 },
        }) catch |e| {
            h.problem = @errorName(e);
            return e;
        };
        if (ans.status == 401) return error.Unauthorized;
        if (ans.status != 200) return error.Refused;
    }
};

/// Seconds since an ISO 8601 time such as 2026-11-22T10:01:02.123+00:00.
fn ageOf(io: Io, iso: ?[]const u8) ?f64 {
    const s = iso orelse return null;
    if (s.len < 19) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    // days from civil (Howard Hinnant)
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = if (mo > 2) mo - 3 else mo + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const then = days * 86400 + hh * 3600 + mm * 60 + ss;
    const now = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    return @floatFromInt(@max(0, now - then));
}

test "online and offline, in both of Zigbee2MQTT's forms" {
    try std.testing.expectEqual(true, Z2m.online("{\"state\":\"online\"}").?);
    try std.testing.expectEqual(false, Z2m.online("offline").?);
    try std.testing.expect(Z2m.online("{}") == null);
}

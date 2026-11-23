//! The hub the devices are reached through: Zigbee2MQTT (over MQTT, kept
//! connected by a thread of its own that holds every device's latest
//! state) or Home Assistant (its REST API, asked when needed, and its
//! WebSocket API, followed by a thread of its own for changes). Either
//! thread tells `Events` the main state of each device the home file lists.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const model = @import("model.zig");
const mqtt = @import("mqtt.zig");
const http = @import("http.zig");
const jv = @import("jv.zig");
const sock = @import("sock.zig");
const color = @import("color.zig");
const when = @import("when.zig");
const ws = @import("ws.zig");
const events_mod = @import("events.zig");

/// After a connection, how long first states fill in silently (and reads
/// wait for them).
const settle_ns = 3 * std.time.ns_per_s;

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
                errdefer gpa.destroy(z);
                z.* = try .init(gpa, io, cfg, secrets);
                z.thread = std.Thread.spawn(.{}, Z2m.loop, .{z}) catch |e| {
                    z.free();
                    return e;
                };
                return .{ .z2m = z };
            },
            .homeassistant => {
                const h = try gpa.create(Ha);
                errdefer gpa.destroy(h);
                h.* = .{ .gpa = gpa, .io = io, .cfg = cfg, .token = secrets.ha_token, .client = .init(gpa, io, try http.Target.parse(cfg.url)), .events = try .init(gpa, io, cfg) };
                h.client.user_agent = "homemcp";
                h.thread = std.Thread.spawn(.{}, Ha.follow, .{h}) catch |e| {
                    h.client.deinit();
                    h.events.deinit();
                    return e;
                };
                return .{ .ha = h };
            },
        }
    }

    pub fn stop(h: Hub) void {
        switch (h) {
            .z2m => |z| z.stop(),
            .ha => |x| x.stop(),
        }
    }

    /// Where changes are kept and told from.
    pub fn events(h: Hub) *events_mod.Events {
        return switch (h) {
            .z2m => |z| &z.events,
            .ha => |x| &x.events,
        };
    }

    /// Whether changes come in as they happen now.
    pub fn eventsUp(h: Hub) bool {
        return switch (h) {
            .z2m => |z| z.connected(),
            .ha => |x| x.ws_up.load(.acquire),
        };
    }

    /// One plain line on whether changes come in.
    pub fn eventsStatus(h: Hub, a: Allocator) ![]const u8 {
        return switch (h) {
            .z2m => |z| if (z.connected()) "Changes come in as they happen (Zigbee2MQTT's state topics)." else "Changes are not coming in: not connected to the broker; trying again.",
            .ha => |x| blk: {
                if (x.ws_up.load(.acquire)) break :blk "Changes come in as they happen (Home Assistant's WebSocket API).";
                x.ws_lock.lockUncancelable(x.io);
                defer x.ws_lock.unlock(x.io);
                if (x.ws_problem_len == 0) break :blk "Changes are not coming in yet: connecting to Home Assistant's WebSocket API.";
                break :blk try std.fmt.allocPrint(a, "Changes are not coming in: {s}; trying again.", .{x.ws_problem[0..x.ws_problem_len]});
            },
        };
    }

    /// Before resource `uri` is read: as current as the hub can make it
    /// (Home Assistant: asked, when its state isn't known or changes aren't
    /// coming in; Zigbee2MQTT: the first states, just after connecting).
    pub fn settle(h: Hub, a: Allocator, uri: []const u8) void {
        const ev = h.events();
        if (!ev.has(uri)) return;
        // a device's index; null: presence
        const which: ?usize = blk: {
            const prefix = "home://device/";
            if (!std.mem.startsWith(u8, uri, prefix)) break :blk null;
            for (ev.cfg.devices, 0..) |d, i| if (std.mem.eql(u8, d.name, uri[prefix.len..])) break :blk i;
            return;
        };
        switch (h) {
            .z2m => |z| z.settle(which),
            .ha => |x| {
                const known = if (which) |i| ev.known(i) else ev.peopleKnown();
                if (known and x.ws_up.load(.acquire)) return;
                if (which != null) _ = x.states(a) catch {} else _ = x.people(a) catch {};
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

    /// Where each person of the home file's [people] is, in its order.
    pub fn people(h: Hub, a: Allocator) ![]model.Presence {
        return switch (h) {
            .z2m => &.{},
            .ha => |x| x.people(a),
        };
    }

    /// One line on how the hub is reached.
    pub fn status(h: Hub, a: Allocator) ![]const u8 {
        return switch (h) {
            .z2m => |z| z.status(a),
            .ha => |x| std.fmt.allocPrint(a, "Home Assistant at {s}{s}{s}", .{ x.cfg.url, if (x.problem.len > 0) ": the last request failed: " else "", x.problem }),
        };
    }

    /// For a scene: the first thing it sets that homemcp guards (a lock, an
    /// alarm, a valve, a garage door or gate, a device the home file
    /// guards); null when none, or when the scene doesn't say what it sets.
    pub fn sceneSets(h: Hub, a: Allocator, dev: *const config.Device) !?[]const u8 {
        return switch (h) {
            .z2m => null,
            .ha => |x| x.sceneSets(a, dev),
        };
    }

    /// Says `message` on speaker `dev`: an Assist satellite's
    /// `assist_satellite.announce`, a media player's `tts.speak` through
    /// `[home] tts`. Home Assistant only; it returns once Home Assistant
    /// has played it (its REST call waits up to 10 s).
    pub fn announce(h: Hub, a: Allocator, dev: *const config.Device, message: []const u8) !void {
        return switch (h) {
            .z2m => error.NotSupportedByHub,
            .ha => |x| x.announce(a, dev, message),
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
    events: events_mod.Events,
    started_ns: i128,
    /// When the session last subscribed (nowNs); 0 when it never did.
    connected_ns: i128 = 0,

    fn init(gpa: Allocator, io: Io, cfg: *const config.Config, secrets: Secrets) !Z2m {
        const n = cfg.devices.len;
        const json = try gpa.alloc([]u8, n);
        for (json) |*j| j.* = &.{};
        const at = try gpa.alloc(i128, n);
        @memset(at, 0);
        const av = try gpa.alloc(?bool, n);
        @memset(av, null);
        return .{ .gpa = gpa, .io = io, .cfg = cfg, .secrets = secrets, .json = json, .at_ns = at, .available = av, .events = try .init(gpa, io, cfg), .started_ns = sock.nowNs(io) };
    }

    fn stop(z: *Z2m) void {
        z.stopping.store(true, .release);
        if (z.thread) |th| th.join();
        z.free();
        z.gpa.destroy(z);
    }

    /// What it holds (not itself).
    fn free(z: *Z2m) void {
        for (z.json) |j| z.gpa.free(j);
        z.gpa.free(z.json);
        z.gpa.free(z.at_ns);
        z.gpa.free(z.available);
        z.gpa.free(z.problem);
        z.events.deinit();
    }

    fn connected(z: *Z2m) bool {
        z.lock.lockUncancelable(z.io);
        defer z.lock.unlock(z.io);
        return z.client != null;
    }

    /// Waits for device `which`'s first state while it may still come: in
    /// the first moments after the start or a connection.
    fn settle(z: *Z2m, which: ?usize) void {
        const i = which orelse return;
        var waited: u32 = 0;
        while (waited < 3500 and !z.events.known(i)) : (waited += 100) {
            const now = sock.nowNs(z.io);
            const starting = now - z.started_ns < settle_ns + std.time.ns_per_s / 2;
            const just = z.connected_ns != 0 and now - z.connected_ns < settle_ns;
            if (!starting and !just) return;
            z.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
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
        z.connected_ns = sock.nowNs(z.io);
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

    /// One message from the broker: a device's state or availability, or
    /// the bridge's. What changed a listed device's main state goes to
    /// `events`; anything else is dropped.
    pub fn handle(z: *Z2m, m: mqtt.Message) void {
        if (m.topic.len <= z.cfg.base.len + 1 or !std.mem.startsWith(u8, m.topic, z.cfg.base) or m.topic[z.cfg.base.len] != '/') return;
        const rel = m.topic[z.cfg.base.len + 1 ..];
        var arena_state = std.heap.ArenaAllocator.init(z.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const lines = a.alloc(?[]const u8, z.cfg.devices.len) catch return;
        @memset(lines, null);
        var any = false;
        {
            z.lock.lockUncancelable(z.io);
            defer z.lock.unlock(z.io);
            var touched: ?usize = null;
            if (std.mem.eql(u8, rel, "bridge/state")) {
                z.bridge = online(m.payload);
            } else for (z.cfg.devices, 0..) |d, i| {
                if (std.mem.eql(u8, rel, d.id)) {
                    const copy = z.gpa.dupe(u8, m.payload) catch return;
                    z.gpa.free(z.json[i]);
                    z.json[i] = copy;
                    z.at_ns[i] = sock.nowNs(z.io);
                    touched = i;
                    break;
                }
                if (rel.len == d.id.len + "/availability".len and std.mem.startsWith(u8, rel, d.id) and std.mem.endsWith(u8, rel, "/availability")) {
                    z.available[i] = online(m.payload);
                    touched = i;
                    break;
                }
            } else return;
            // the main state of each device it may have changed, as it stands now
            for (z.cfg.devices, 0..) |d, i| {
                if (touched) |x| if (x != i) continue;
                lines[i] = model.headline(a, d.kind, z.propsOf(a, i)) catch null;
                any = true;
            }
        }
        if (!any) return;
        const now = sock.nowNs(z.io);
        const mode: events_mod.Mode = if (z.connected_ns != 0 and now - z.connected_ns < settle_ns) .fill else .change;
        const at_ms: i64 = @intCast(@divFloor(Io.Clock.real.now(z.io).nanoseconds, std.time.ns_per_ms));
        for (lines, 0..) |l, i| z.events.device(i, l, at_ms, mode);
    }

    /// Device `i`'s state from what was heard; under z.lock.
    fn propsOf(z: *Z2m, a: Allocator, i: usize) model.Props {
        var p: model.Props = .{};
        if (z.json[i].len > 0) if (jv.parse(a, a.dupe(u8, z.json[i]) catch return p)) |v| {
            p = model.fromZ2m(z.cfg.devices[i].kind, v);
        };
        p.available = z.available[i];
        if (z.bridge == false) p.available = false;
        return p;
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
        for (0..z.cfg.devices.len) |i| {
            out[i] = .{ .props = z.propsOf(a, i), .age_s = if (z.at_ns[i] > 0) @as(f64, @floatFromInt(now - z.at_ns[i])) / std.time.ns_per_s else null };
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
            .on => if (dev.kind == .fan) "{\"fan_state\":\"ON\"}" else "{\"state\":\"ON\"}",
            .off => if (dev.kind == .fan) "{\"fan_state\":\"OFF\"}" else "{\"state\":\"OFF\"}",
            .brightness => try std.fmt.allocPrint(a, "{{\"state\":\"ON\",\"brightness\":{d}}}", .{@as(i64, @intFromFloat(@round(number.? * 254.0 / 100.0)))}),
            .color => blk: {
                var hb: [7]u8 = undefined;
                break :blk try std.fmt.allocPrint(a, "{{\"state\":\"ON\",\"color\":{{\"hex\":\"{s}\"}}}}", .{color.hex(&hb, color.parse(text.?) orelse return error.BadValue)});
            },
            // Zigbee2MQTT takes colour temperature in mireds
            .color_temp => try std.fmt.allocPrint(a, "{{\"state\":\"ON\",\"color_temp\":{d}}}", .{@as(i64, @intFromFloat(@round(1e6 / number.?)))}),
            .speed => try std.fmt.allocPrint(a, "{{\"fan_mode\":\"{s}\"}}", .{fanMode(number.?)}),
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
            .arm_home, .arm_away, .disarm, .activate, .play, .pause, .volume, .announce => return error.NotSupportedByHub,
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
    events: events_mod.Events,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The WebSocket is connected, signed in and subscribed.
    ws_up: std.atomic.Value(bool) = .init(false),
    ws_lock: Io.Mutex = .init,
    ws_problem: [160]u8 = undefined,
    ws_problem_len: usize = 0,
    /// The WebSocket's socket while one is open (under ws_lock): a stop
    /// wakes whatever waits on it.
    ws_handle: ?sock.Handle = null,

    fn stop(h: *Ha) void {
        h.stopping.store(true, .release);
        {
            h.ws_lock.lockUncancelable(h.io);
            defer h.ws_lock.unlock(h.io);
            if (h.ws_handle) |x| sock.shutdown(x);
        }
        if (h.thread) |th| th.join();
        h.client.deinit();
        h.events.deinit();
        h.gpa.destroy(h);
    }

    fn setWsProblem(h: *Ha, what: []const u8) void {
        h.ws_lock.lockUncancelable(h.io);
        defer h.ws_lock.unlock(h.io);
        const n = @min(what.len, h.ws_problem.len);
        @memcpy(h.ws_problem[0..n], what[0..n]);
        h.ws_problem_len = n;
    }

    /// The thread that follows Home Assistant's changes over its WebSocket
    /// API, connecting again after 1 s, 2 s, 4 s ... up to a minute.
    fn follow(h: *Ha) void {
        var backoff_ms: u32 = 1000;
        while (!h.stopping.load(.acquire)) {
            const began = sock.nowNs(h.io);
            h.session() catch |e| h.setWsProblem(wsProblem(e));
            h.ws_up.store(false, .release);
            // a session that held a while starts the waits over
            if (sock.nowNs(h.io) - began > 60 * std.time.ns_per_s) backoff_ms = 1000;
            var waited: u32 = 0;
            while (waited < backoff_ms and !h.stopping.load(.acquire)) : (waited += 50) h.io.sleep(.fromMilliseconds(50), .awake) catch {};
            backoff_ms = @min(backoff_ms * 2, 60_000);
        }
    }

    fn session(h: *Ha) !void {
        const c = try ws.Conn.open(h.gpa, h.io, h.cfg.url, "/api/websocket", 5000);
        {
            h.ws_lock.lockUncancelable(h.io);
            defer h.ws_lock.unlock(h.io);
            h.ws_handle = c.raw.s.handle;
        }
        defer {
            h.ws_lock.lockUncancelable(h.io);
            h.ws_handle = null;
            h.ws_lock.unlock(h.io);
            c.close();
        }
        if (h.stopping.load(.acquire)) return;
        var arena_state = std.heap.ArenaAllocator.init(h.gpa);
        defer arena_state.deinit();
        {
            const a = arena_state.allocator();
            const hello = jv.parse(a, (try c.next(10_000)) orelse return error.NoAnswer) orelse return error.NotHomeAssistant;
            if (!std.mem.eql(u8, jv.str(jv.get(hello, "type")) orelse "", "auth_required")) return error.NotHomeAssistant;
            try c.send(try std.fmt.allocPrint(a, "{{\"type\":\"auth\",\"access_token\":{f}}}", .{std.json.fmt(h.token, .{})}));
            const ok = jv.parse(a, (try c.next(10_000)) orelse return error.NoAnswer) orelse return error.NotHomeAssistant;
            const ty = jv.str(jv.get(ok, "type")) orelse "";
            if (std.mem.eql(u8, ty, "auth_invalid")) return error.Unauthorized;
            if (!std.mem.eql(u8, ty, "auth_ok")) return error.NotHomeAssistant;
        }
        // subscribed first, then every state: nothing falls between
        try c.send("{\"id\":1,\"type\":\"subscribe_events\",\"event_type\":\"state_changed\"}");
        try c.send("{\"id\":2,\"type\":\"get_states\"}");
        var next_id: i64 = 3;
        var heard = sock.nowNs(h.io);
        var pinged = heard;
        while (!h.stopping.load(.acquire)) {
            const now = sock.nowNs(h.io);
            if (try c.next(250)) |msg| {
                heard = sock.nowNs(h.io);
                _ = arena_state.reset(.retain_capacity);
                const a = arena_state.allocator();
                const v = jv.parse(a, msg) orelse continue;
                // a list, when Home Assistant sends several at once
                if (v == .array) {
                    for (v.array.items) |item| try h.onMessage(a, item);
                } else try h.onMessage(a, v);
                continue;
            }
            if (now - pinged >= 30 * std.time.ns_per_s) {
                var buf: [48]u8 = undefined;
                try c.send(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"type\":\"ping\"}}", .{next_id}));
                next_id += 1;
                pinged = now;
            }
            // pinged and no answer: the connection is gone
            if (now - heard >= 75 * std.time.ns_per_s) return error.NoAnswer;
        }
    }

    fn onMessage(h: *Ha, a: Allocator, v: jv.Value) !void {
        const ty = jv.str(jv.get(v, "type")) orelse return;
        const id = jv.int(jv.get(v, "id")) orelse 0;
        if (std.mem.eql(u8, ty, "result")) {
            const ok = jv.boolean(jv.get(v, "success")) orelse false;
            if (id == 1) {
                if (!ok) return error.Refused;
                h.setWsProblem("");
                h.ws_up.store(true, .release);
            } else if (id == 2 and ok) {
                for (jv.arr(jv.get(v, "result")) orelse &.{}) |st| h.note(a, st, .fill);
            }
            return;
        }
        if (std.mem.eql(u8, ty, "event")) {
            const data = jv.at(v, &.{ "event", "data" });
            // removed entities have no new state
            const st = jv.get(data, "new_state") orelse return;
            h.note(a, st, .change);
        }
    }

    /// One entity's state, kept only when the home file lists it.
    fn note(h: *Ha, a: Allocator, st: jv.Value, mode: events_mod.Mode) void {
        const id = jv.str(jv.get(st, "entity_id")) orelse return;
        const at_ms = when.parseMs(jv.str(jv.get(st, "last_updated")) orelse "") orelse
            @as(i64, @intCast(@divFloor(Io.Clock.real.now(h.io).nanoseconds, std.time.ns_per_ms)));
        for (h.cfg.devices, 0..) |d, i| if (std.mem.eql(u8, d.id, id)) {
            h.events.device(i, model.headline(a, d.kind, model.fromHa(d.kind, st)) catch null, at_ms, mode);
        };
        for (h.cfg.people, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) {
            h.events.person(i, .of(jv.str(jv.get(st, "state")) orelse ""), at_ms, mode);
        };
    }

    /// Every entity's state object (GET /api/states).
    fn allStates(h: *Ha, a: Allocator) ![]jv.Value {
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
        return jv.arr(jv.parse(a, ans.body)) orelse error.BadAnswer;
    }

    fn people(h: *Ha, a: Allocator) ![]model.Presence {
        const list = try h.allStates(a);
        const out = try a.alloc(model.Presence, h.cfg.people.len);
        for (h.cfg.people, out) |p, *o| {
            o.* = .unknown;
            for (list) |x| if (std.mem.eql(u8, jv.str(jv.get(x, "entity_id")) orelse "", p.id)) {
                o.* = .of(jv.str(jv.get(x, "state")) orelse "");
                h.note(a, x, .fill);
                break;
            };
        }
        return out;
    }

    fn sceneSets(h: *Ha, a: Allocator, dev: *const config.Device) !?[]const u8 {
        const list = try h.allStates(a);
        const scene = for (list) |x| {
            if (std.mem.eql(u8, jv.str(jv.get(x, "entity_id")) orelse "", dev.id)) break x;
        } else return null;
        for (jv.arr(jv.at(scene, &.{ "attributes", "entity_id" })) orelse &.{}) |m| {
            const id = jv.str(m) orelse continue;
            if (guardedEntity(h.cfg, list, id)) return try a.dupe(u8, id);
        }
        return null;
    }

    fn states(h: *Ha, a: Allocator) ![]State {
        const list = try h.allStates(a);
        const out = try a.alloc(State, h.cfg.devices.len);
        for (h.cfg.devices, 0..) |d, i| {
            out[i] = .{ .props = .{ .available = false } };
            for (list) |s| if (std.mem.eql(u8, jv.str(jv.get(s, "entity_id")) orelse "", d.id)) {
                out[i] = .{ .props = model.fromHa(d.kind, s), .age_s = ageOf(h.io, jv.str(jv.get(s, "last_changed"))) };
                // what is asked for is current too: a change the WebSocket
                // hasn't brought yet counts (an older answer never does)
                h.note(a, s, .fill);
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
            .color => blk: {
                const c = color.parse(text.?) orelse return error.BadValue;
                break :blk .{ .service = "turn_on", .extra = try std.fmt.allocPrint(a, ",\"rgb_color\":[{d},{d},{d}]", .{ c.r, c.g, c.b }) };
            },
            .color_temp => .{ .service = "turn_on", .extra = try std.fmt.allocPrint(a, ",\"color_temp_kelvin\":{d}", .{@as(i64, @intFromFloat(@round(number.?)))}) },
            .speed => .{ .service = "set_percentage", .extra = try std.fmt.allocPrint(a, ",\"percentage\":{d}", .{@as(i64, @intFromFloat(@round(number.?)))}) },
            .activate => .{ .service = "turn_on" },
            .play => .{ .service = "media_play" },
            .pause => .{ .service = "media_pause" },
            .volume => .{ .service = "volume_set", .extra = try std.fmt.allocPrint(a, ",\"volume_level\":{s}", .{model.num(@round(number.?) / 100)}) },
            // said only through `announce`
            .announce => return error.NotSupportedByHub,
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

    fn announce(h: *Ha, a: Allocator, dev: *const config.Device, message: []const u8) !void {
        const id = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(dev.id, .{})});
        const msg = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(message, .{})});
        const path, const body = switch (dev.kind) {
            .satellite => .{ "/api/services/assist_satellite/announce", try std.fmt.allocPrint(a, "{{\"entity_id\":{s},\"message\":{s},\"preannounce\":true}}", .{ id, msg }) },
            .media => .{ "/api/services/tts/speak", try std.fmt.allocPrint(a, "{{\"entity_id\":{f},\"media_player_entity_id\":{s},\"message\":{s}}}", .{ std.json.fmt(h.cfg.tts, .{}), id, msg }) },
            else => return error.NotASpeaker,
        };
        const ans = http.fetch(&h.client, a, .{
            .path = path,
            .body = body,
            .key = h.token,
            // Home Assistant answers once it has played it, or after 10 s
            .limits = .{ .idle_ms = 20_000, .total_ms = 30_000 },
        }) catch |e| {
            h.problem = @errorName(e);
            return e;
        };
        if (ans.status == 401) return error.Unauthorized;
        if (ans.status != 200) return error.Refused;
    }
};

/// Whether Home Assistant entity `id` is one homemcp guards: a lock, an
/// alarm panel, a valve, a garage door, gate or door, or a device the home
/// file guards. `states` are every entity's, for a cover's device class.
pub fn guardedEntity(cfg: *const config.Config, states: []const jv.Value, id: []const u8) bool {
    const domain = id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
    for ([_][]const u8{ "lock", "alarm_control_panel", "valve" }) |x| if (std.mem.eql(u8, domain, x)) return true;
    if (std.mem.eql(u8, domain, "cover")) for (states) |st| {
        if (!std.mem.eql(u8, jv.str(jv.get(st, "entity_id")) orelse "", id)) continue;
        const dc = jv.str(jv.at(st, &.{ "attributes", "device_class" })) orelse "";
        for ([_][]const u8{ "garage", "gate", "door" }) |x| if (std.mem.eql(u8, dc, x)) return true;
    };
    for (cfg.devices) |d| if (d.guarded and std.mem.eql(u8, d.id, id)) return true;
    return false;
}

/// A WebSocket problem in plain words.
fn wsProblem(e: anyerror) []const u8 {
    return switch (e) {
        error.Unauthorized => "the token was refused (HA_TOKEN)",
        error.ConnectFailed => "can't connect to Home Assistant",
        error.Timeout, error.NoAnswer => "Home Assistant stopped answering",
        error.NotWebSocket => "no WebSocket API at /api/websocket",
        error.NotHomeAssistant => "what answered isn't Home Assistant's WebSocket API",
        error.Refused => "Home Assistant refused to send state changes",
        error.Closed => "the connection ended",
        error.CertificateRejected => "its https certificate was not accepted",
        else => @errorName(e),
    };
}

/// Zigbee2MQTT's fan modes for a speed in %.
fn fanMode(pct: f64) []const u8 {
    return if (pct <= 34) "low" else if (pct <= 67) "medium" else "high";
}

/// Seconds since an ISO 8601 time such as 2026-11-22T10:01:02.123+00:00.
fn ageOf(io: Io, iso: ?[]const u8) ?f64 {
    const then = when.parseMs(iso orelse return null) orelse return null;
    const now = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms);
    return @as(f64, @floatFromInt(@max(0, now - then))) / 1000;
}

test "online and offline, in both of Zigbee2MQTT's forms" {
    try std.testing.expectEqual(true, Z2m.online("{\"state\":\"online\"}").?);
    try std.testing.expectEqual(false, Z2m.online("offline").?);
    try std.testing.expect(Z2m.online("{}") == null);
}

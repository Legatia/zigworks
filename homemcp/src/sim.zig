//! homemcp-sim: a home of eight made-up devices, for trying homemcp
//! without hardware. It plays Zigbee2MQTT (through an MQTT broker) or Home
//! Assistant's REST API. Sensors change when told to: publish JSON to
//! `homesim/<friendly name>` (Zigbee2MQTT), or POST it to
//! `/homesim/<entity id>` (Home Assistant), with any of occupancy,
//! contact, available, temperature.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const mqtt = @import("mqtt.zig");
const sock = @import("sock.zig");
const jv = @import("jv.zig");

const Kind = enum { light, plug, climate, lock, cover, motion, contact, valve };

const Dev = struct {
    name: []const u8,
    entity: []const u8,
    kind: Kind,
    on: bool = false,
    brightness: u8 = 254,
    temperature: f64 = 19.5,
    setpoint: f64 = 20,
    mode: []const u8 = "heat",
    locked: bool = true,
    position: u8 = 0,
    occupancy: bool = false,
    closed: bool = true,
    battery: u8 = 90,
    available: bool = true,
    changed_s: i64 = 0,
};

pub const Home = struct {
    io: Io,
    lock: Io.Mutex = .init,
    devs: [8]Dev = .{
        .{ .name = "Living room light", .entity = "light.living_room", .kind = .light },
        .{ .name = "Kettle plug", .entity = "switch.kettle", .kind = .plug },
        .{ .name = "Hall thermostat", .entity = "climate.hall", .kind = .climate },
        .{ .name = "Front door", .entity = "lock.front_door", .kind = .lock, .battery = 80 },
        .{ .name = "Garage door", .entity = "cover.garage_door", .kind = .cover },
        .{ .name = "Hall motion", .entity = "binary_sensor.hall_motion", .kind = .motion },
        .{ .name = "Back door", .entity = "binary_sensor.back_door", .kind = .contact },
        .{ .name = "Water main", .entity = "valve.water_main", .kind = .valve, .on = true },
    },

    fn init(io: Io) Home {
        var h: Home = .{ .io = io };
        const now = nowS(io);
        for (&h.devs) |*d| d.changed_s = now;
        return h;
    }

    fn find(h: *Home, by_entity: bool, key: []const u8) ?*Dev {
        for (&h.devs) |*d| if (std.mem.eql(u8, if (by_entity) d.entity else d.name, key)) return d;
        return null;
    }

    /// The heating moves a tenth of a degree towards where it is heading.
    fn tick(h: *Home) bool {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        const d = &h.devs[2];
        const target: f64 = if (std.mem.eql(u8, d.mode, "off")) 17 else d.setpoint;
        if (@abs(d.temperature - target) < 0.05) return false;
        const step: f64 = if (target > d.temperature) 0.1 else -0.1;
        d.temperature = @round((d.temperature + step) * 10) / 10;
        return true;
    }

    /// The test triggers: occupancy, contact, available, temperature.
    fn poke(h: *Home, d: *Dev, v: jv.Value) void {
        if (jv.boolean(jv.get(v, "occupancy"))) |x| d.occupancy = x;
        if (jv.boolean(jv.get(v, "contact"))) |x| d.closed = x;
        if (jv.boolean(jv.get(v, "available"))) |x| d.available = x;
        if (jv.num(jv.get(v, "temperature"))) |x| d.temperature = x;
        if (jv.boolean(jv.get(v, "locked"))) |x| d.locked = x;
        d.changed_s = nowS(h.io);
    }
};

fn nowS(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

// ---- Zigbee2MQTT ----

fn z2mState(a: Allocator, d: *const Dev) ![]u8 {
    return switch (d.kind) {
        .light => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"brightness\":{d},\"linkquality\":120}}", .{ onOff(d.on), d.brightness }),
        .plug => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"power\":{d}}}", .{ onOff(d.on), @as(u32, if (d.on) 2000 else 0) }),
        .valve => std.fmt.allocPrint(a, "{{\"state\":\"{s}\"}}", .{onOff(d.on)}),
        .climate => std.fmt.allocPrint(a, "{{\"local_temperature\":{d:.1},\"current_heating_setpoint\":{d},\"system_mode\":\"{s}\",\"running_state\":\"{s}\"}}", .{ d.temperature, d.setpoint, d.mode, if (heating(d)) "heat" else "idle" }),
        .lock => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"lock_state\":\"{s}\",\"battery\":{d}}}", .{ if (d.locked) "LOCK" else "UNLOCK", if (d.locked) "locked" else "unlocked", d.battery }),
        .cover => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"position\":{d}}}", .{ if (d.position > 0) "OPEN" else "CLOSE", d.position }),
        .motion => std.fmt.allocPrint(a, "{{\"occupancy\":{},\"battery\":{d}}}", .{ d.occupancy, d.battery }),
        .contact => std.fmt.allocPrint(a, "{{\"contact\":{},\"battery\":{d}}}", .{ d.closed, d.battery }),
    };
}

fn heating(d: *const Dev) bool {
    return !std.mem.eql(u8, d.mode, "off") and d.temperature < d.setpoint;
}

fn onOff(b: bool) []const u8 {
    return if (b) "ON" else "OFF";
}

/// Applies a `/set` message as the device would.
fn z2mSet(h: *Home, d: *Dev, v: jv.Value) void {
    if (jv.str(jv.get(v, "state"))) |st| {
        if (eqlI(st, "ON")) d.on = true;
        if (eqlI(st, "OFF")) d.on = false;
        if (eqlI(st, "TOGGLE")) d.on = !d.on;
        if (eqlI(st, "LOCK")) d.locked = true;
        if (eqlI(st, "UNLOCK")) d.locked = false;
        if (eqlI(st, "OPEN")) d.position = 100;
        if (eqlI(st, "CLOSE")) d.position = 0;
    }
    if (jv.int(jv.get(v, "brightness"))) |b| {
        d.brightness = @intCast(std.math.clamp(b, 0, 254));
        d.on = b > 0;
    }
    if (jv.num(jv.get(v, "current_heating_setpoint"))) |x| d.setpoint = x;
    if (jv.num(jv.get(v, "occupied_heating_setpoint"))) |x| d.setpoint = x;
    if (jv.str(jv.get(v, "system_mode"))) |m| d.mode = modeName(m);
    if (jv.int(jv.get(v, "position"))) |p| d.position = @intCast(std.math.clamp(p, 0, 100));
    d.changed_s = nowS(h.io);
}

fn modeName(m: []const u8) []const u8 {
    for ([_][]const u8{ "off", "heat", "auto", "cool" }) |x| if (eqlI(m, x)) return x;
    return "heat";
}

pub fn runZ2m(gpa: Allocator, io: Io, host: []const u8, port: u16, base: []const u8) !void {
    var home: Home = .init(io);
    while (true) {
        z2mSession(gpa, io, &home, host, port, base) catch |e| {
            std.log.warn("broker {s}:{d}: {s}; trying again", .{ host, port, @errorName(e) });
        };
        io.sleep(.fromMilliseconds(500), .awake) catch {};
    }
}

fn z2mSession(gpa: Allocator, io: Io, home: *Home, host: []const u8, port: u16, base: []const u8) !void {
    const c = try gpa.create(mqtt.Client);
    defer gpa.destroy(c);
    try c.connect(gpa, io, host, port, "homemcp-sim", null, null, 30);
    defer c.close();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try c.publish(try topic(a, base, "bridge/state", ""), "{\"state\":\"online\"}", true);
    try c.publish(try topic(a, base, "bridge/devices", ""), try bridgeDevices(a, home), true);
    for (&home.devs) |*d| {
        try c.publish(try topic(a, base, d.name, "/availability"), if (d.available) "{\"state\":\"online\"}" else "{\"state\":\"offline\"}", true);
        try c.publish(try topic(a, base, d.name, ""), try z2mState(a, d), false);
    }
    try c.subscribe(try topic(a, base, "+", "/set"));
    try c.subscribe(try topic(a, base, "+", "/get"));
    try c.subscribe("homesim/+");
    var last_tick = sock.nowNs(io);
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        if (try c.next(200)) |m| {
            const payload = try a.dupe(u8, m.payload);
            const tp = try a.dupe(u8, m.topic);
            const v = jv.parse(a, payload) orelse jv.Value{ .object = .empty };
            if (std.mem.startsWith(u8, tp, "homesim/")) {
                home.lock.lockUncancelable(io);
                const d = home.find(false, tp["homesim/".len..]);
                if (d) |x| home.poke(x, v);
                home.lock.unlock(io);
                if (d) |x| {
                    try c.publish(try topic(a, base, x.name, "/availability"), if (x.available) "{\"state\":\"online\"}" else "{\"state\":\"offline\"}", true);
                    if (x.available) try c.publish(try topic(a, base, x.name, ""), try z2mState(a, x), false);
                }
            } else if (tp.len > base.len + 1) {
                const rel = tp[base.len + 1 ..];
                const set = std.mem.endsWith(u8, rel, "/set");
                const get = std.mem.endsWith(u8, rel, "/get");
                if (set or get) {
                    home.lock.lockUncancelable(io);
                    const d = home.find(false, rel[0 .. rel.len - 4]);
                    if (d) |x| if (x.available and set) z2mSet(home, x, v);
                    const out = if (d) |x| (if (x.available) try z2mState(a, x) else null) else null;
                    home.lock.unlock(io);
                    if (out) |o| try c.publish(try topic(a, base, rel[0 .. rel.len - 4], ""), o, false);
                }
            }
        }
        if (sock.nowNs(io) - last_tick >= 2 * std.time.ns_per_s) {
            last_tick = sock.nowNs(io);
            if (home.tick()) {
                home.lock.lockUncancelable(io);
                const o = try z2mState(a, &home.devs[2]);
                home.lock.unlock(io);
                try c.publish(try topic(a, base, home.devs[2].name, ""), o, false);
            }
        }
        try c.keepAlive();
    }
}

fn topic(a: Allocator, base: []const u8, name: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}{s}", .{ base, name, suffix });
}

fn bridgeDevices(a: Allocator, home: *Home) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '[');
    for (home.devs, 0..) |d, i| {
        if (i > 0) try o.append(a, ',');
        try o.print(a, "{{\"friendly_name\":{f},\"ieee_address\":\"0x00124b00000000{x:0>2}\",\"type\":\"EndDevice\",\"supported\":true,\"definition\":{{\"model\":\"SIM-{s}\",\"vendor\":\"homemcp-sim\",\"description\":\"a made-up {s}\"}}}}", .{ std.json.fmt(d.name, .{}), i, @tagName(d.kind), @tagName(d.kind) });
    }
    try o.append(a, ']');
    return o.items;
}

// ---- Home Assistant ----

fn haState(a: Allocator, d: *const Dev) ![]u8 {
    var tbuf: [20]u8 = undefined;
    const when = iso(&tbuf, d.changed_s);
    const head = try std.fmt.allocPrint(a, "{{\"entity_id\":\"{s}\",\"last_changed\":\"{s}\",\"last_updated\":\"{s}\",", .{ d.entity, when, when });
    if (!d.available) return std.fmt.allocPrint(a, "{s}\"state\":\"unavailable\",\"attributes\":{{\"friendly_name\":{f}}}}}", .{ head, std.json.fmt(d.name, .{}) });
    const body = switch (d.kind) {
        .light => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"brightness\":{d}", .{ if (d.on) "on" else "off", @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(d.brightness)) * 255.0 / 254.0))) }),
        .plug => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"current_power_w\":{d}", .{ if (d.on) "on" else "off", @as(u32, if (d.on) 2000 else 0) }),
        .valve => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{", .{if (d.on) "open" else "closed"}),
        .climate => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"current_temperature\":{d:.1},\"temperature\":{d},\"hvac_action\":\"{s}\",\"hvac_modes\":[\"off\",\"heat\",\"auto\"]", .{ d.mode, d.temperature, d.setpoint, if (std.mem.eql(u8, d.mode, "off")) "off" else if (heating(d)) "heating" else "idle" }),
        .lock => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"battery_level\":{d}", .{ if (d.locked) "locked" else "unlocked", d.battery }),
        .cover => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"current_position\":{d},\"device_class\":\"garage\"", .{ if (d.position > 0) "open" else "closed", d.position }),
        .motion => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"device_class\":\"motion\"", .{if (d.occupancy) "on" else "off"}),
        .contact => try std.fmt.allocPrint(a, "\"state\":\"{s}\",\"attributes\":{{\"device_class\":\"door\"", .{if (d.closed) "off" else "on"}),
    };
    const sep = if (body[body.len - 1] == '{') "" else ",";
    return std.fmt.allocPrint(a, "{s}{s}{s}\"friendly_name\":{f}}}}}", .{ head, body, sep, std.json.fmt(d.name, .{}) });
}

/// A Home Assistant service call on one entity; false when the service is
/// not one this kind of device has.
fn haService(h: *Home, d: *Dev, domain: []const u8, service: []const u8, v: jv.Value) bool {
    const svc = std.mem.eql;
    const ok = switch (d.kind) {
        .light => blk: {
            if (!svc(u8, domain, "light")) break :blk false;
            if (svc(u8, service, "turn_on")) {
                d.on = true;
                if (jv.num(jv.get(v, "brightness_pct"))) |p| d.brightness = @intFromFloat(@round(std.math.clamp(p, 0, 100) * 254.0 / 100.0));
                break :blk true;
            }
            if (svc(u8, service, "turn_off")) {
                d.on = false;
                break :blk true;
            }
            break :blk false;
        },
        .plug => blk: {
            if (!svc(u8, domain, "switch")) break :blk false;
            if (svc(u8, service, "turn_on")) d.on = true else if (svc(u8, service, "turn_off")) d.on = false else break :blk false;
            break :blk true;
        },
        .climate => blk: {
            if (!svc(u8, domain, "climate")) break :blk false;
            if (svc(u8, service, "set_temperature")) {
                d.setpoint = jv.num(jv.get(v, "temperature")) orelse break :blk false;
            } else if (svc(u8, service, "set_hvac_mode")) {
                d.mode = modeName(jv.str(jv.get(v, "hvac_mode")) orelse break :blk false);
            } else break :blk false;
            break :blk true;
        },
        .lock => blk: {
            if (!svc(u8, domain, "lock")) break :blk false;
            if (svc(u8, service, "lock")) d.locked = true else if (svc(u8, service, "unlock")) d.locked = false else break :blk false;
            break :blk true;
        },
        .cover => blk: {
            if (!svc(u8, domain, "cover")) break :blk false;
            if (svc(u8, service, "open_cover")) {
                d.position = 100;
            } else if (svc(u8, service, "close_cover")) {
                d.position = 0;
            } else if (svc(u8, service, "stop_cover")) {} else if (svc(u8, service, "set_cover_position")) {
                d.position = @intCast(std.math.clamp(jv.int(jv.get(v, "position")) orelse break :blk false, 0, 100));
            } else break :blk false;
            break :blk true;
        },
        .valve => blk: {
            if (!svc(u8, domain, "valve")) break :blk false;
            if (svc(u8, service, "open_valve")) d.on = true else if (svc(u8, service, "close_valve")) d.on = false else break :blk false;
            break :blk true;
        },
        .motion, .contact => false,
    };
    if (ok) d.changed_s = nowS(h.io);
    return ok;
}

const HaSim = struct {
    home: Home,
    token: []const u8,
    gpa: Allocator,
    io: Io,
};

pub fn runHa(gpa: Allocator, io: Io, port: u16, token: []const u8) !void {
    const l = try sock.Listener.open(port);
    defer l.close();
    const sim = try gpa.create(HaSim);
    sim.* = .{ .home = .init(io), .token = token, .gpa = gpa, .io = io };
    const ticker = try std.Thread.spawn(.{}, haTicker, .{sim});
    ticker.detach();
    std.log.info("Home Assistant stand-in on 127.0.0.1:{d}", .{l.port});
    while (true) {
        const conn = l.accept() catch continue;
        const th = std.Thread.spawn(.{}, haServe, .{ sim, conn }) catch {
            sock.closeHandle(conn);
            continue;
        };
        th.detach();
    }
}

fn haTicker(sim: *HaSim) void {
    while (true) {
        sim.io.sleep(.fromMilliseconds(2000), .awake) catch {};
        _ = sim.home.tick();
    }
}

fn haServe(sim: *HaSim, conn: sock.Handle) void {
    defer sock.closeHandle(conn);
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(sim.io, conn, &rbuf, &wbuf, 60_000);
    var server = std.http.Server.init(&sk.reader, &sk.writer);
    while (true) {
        var req = server.receiveHead() catch return;
        var arena_state = std.heap.ArenaAllocator.init(sim.gpa);
        defer arena_state.deinit();
        haHandle(sim, arena_state.allocator(), &req) catch return;
    }
}

fn haHandle(sim: *HaSim, a: Allocator, req: *std.http.Server.Request) !void {
    const target = try a.dupe(u8, req.head.target);
    const method = req.head.method;
    var auth: []const u8 = "";
    var it = req.iterateHeaders();
    while (it.next()) |hd| if (std.ascii.eqlIgnoreCase(hd.name, "authorization")) {
        auth = try a.dupe(u8, hd.value);
    };
    var body_buf: [8192]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&body_buf);
    const body = try body_reader.allocRemaining(a, .limited(1 << 20));
    const route = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const want = try std.fmt.allocPrint(a, "Bearer {s}", .{sim.token});
    if (!std.mem.eql(u8, auth, want)) return json(req, .unauthorized, "{\"message\":\"401: Unauthorized\"}");
    const home = &sim.home;
    home.lock.lockUncancelable(sim.io);
    defer home.lock.unlock(sim.io);
    if (method == .GET and std.mem.eql(u8, route, "/api/")) return json(req, .ok, "{\"message\":\"API running.\"}");
    if (method == .GET and std.mem.eql(u8, route, "/api/states")) {
        var o: std.ArrayList(u8) = .empty;
        try o.append(a, '[');
        for (&home.devs, 0..) |*d, i| {
            if (i > 0) try o.append(a, ',');
            try o.appendSlice(a, try haState(a, d));
        }
        try o.append(a, ']');
        return json(req, .ok, o.items);
    }
    if (method == .GET and std.mem.startsWith(u8, route, "/api/states/")) {
        const d = home.find(true, route["/api/states/".len..]) orelse return json(req, .not_found, "{\"message\":\"Entity not found.\"}");
        return json(req, .ok, try haState(a, d));
    }
    if (method == .POST and std.mem.startsWith(u8, route, "/api/services/")) {
        const rest = route["/api/services/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return json(req, .bad_request, "{\"message\":\"Invalid service\"}");
        const v = jv.parse(a, body) orelse return json(req, .bad_request, "{\"message\":\"Data should be valid JSON.\"}");
        const d = home.find(true, jv.str(jv.get(v, "entity_id")) orelse "") orelse return json(req, .bad_request, "{\"message\":\"Entity not found.\"}");
        if (!d.available) return json(req, .ok, "[]");
        if (!haService(home, d, rest[0..slash], rest[slash + 1 ..], v)) return json(req, .bad_request, "{\"message\":\"Service not found.\"}");
        return json(req, .ok, try std.fmt.allocPrint(a, "[{s}]", .{try haState(a, d)}));
    }
    if (method == .POST and std.mem.startsWith(u8, route, "/homesim/")) {
        const d = home.find(true, route["/homesim/".len..]) orelse return json(req, .not_found, "{}");
        home.poke(d, jv.parse(a, body) orelse return json(req, .bad_request, "{}"));
        return json(req, .ok, try haState(a, d));
    }
    return json(req, .not_found, "{\"message\":\"Not found\"}");
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn eqlI(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn iso(buf: *[20]u8, secs: i64) []const u8 {
    return @import("server.zig").isoTime(buf, secs);
}

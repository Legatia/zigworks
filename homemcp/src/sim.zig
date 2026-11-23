//! homemcp-sim: a made-up home for trying homemcp without hardware. It
//! plays Zigbee2MQTT (through an MQTT broker) or Home Assistant (its REST
//! API and its WebSocket API: events, states, registries). Sensors and
//! people change when told to: publish JSON to `homesim/<friendly name>`
//! (Zigbee2MQTT), or POST it to `/homesim/<entity id>` (Home Assistant),
//! with any of occupancy, contact, available, temperature, locked, leak,
//! smoke, home, zone. `POST /homesim/drop_websockets` cuts every
//! WebSocket, as a restart of Home Assistant would.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const mqtt = @import("mqtt.zig");
const sock = @import("sock.zig");
const jv = @import("jv.zig");
const color = @import("color.zig");
const when = @import("when.zig");

const Kind = enum { light, plug, climate, lock, cover, motion, contact, valve, lamp, fan, speaker, scene, person, camera, smoke, setting, temp, leak, other };

const Dev = struct {
    name: []const u8,
    entity: []const u8,
    kind: Kind,
    /// Home Assistant's area (through its device)
    area: []const u8 = "",
    /// Home Assistant's device it belongs to: "" one of its own, "-" none
    device: []const u8 = "",
    /// Not on Zigbee
    ha_only: bool = false,
    /// A voice alias set in Home Assistant
    alias: []const u8 = "",
    /// Home Assistant's entity category (config, diagnostic)
    category: []const u8 = "",
    on: bool = false,
    brightness: u8 = 254,
    rgb: color.Rgb = .{ .r = 255, .g = 255, .b = 255 },
    temp_mode: bool = true,
    kelvin: u32 = 2700,
    temperature: f64 = 19.5,
    setpoint: f64 = 20,
    mode: []const u8 = "heat",
    locked: bool = true,
    position: u8 = 0,
    occupancy: bool = false,
    closed: bool = true,
    wet: bool = false,
    smoke: bool = false,
    battery: u8 = 90,
    available: bool = true,
    speed: u8 = 0,
    playing: []const u8 = "idle",
    volume: u8 = 20,
    home: bool = false,
    zone: []const u8 = "",
    activated_ms: i64 = 0,
    members: []const []const u8 = &.{},
    changed_ms: i64 = 0,
};

const areas = [_][2][]const u8{
    .{ "living_room", "Living room" },
    .{ "kitchen", "Kitchen" },
    .{ "hall", "Hall" },
    .{ "bedroom", "Bedroom" },
    .{ "garage", "Garage" },
};

pub const n_devs = 21;

pub const Home = struct {
    io: Io,
    lock: Io.Mutex = .init,
    devs: [n_devs]Dev = .{
        .{ .name = "Living room light", .entity = "light.living_room", .kind = .light, .area = "living_room", .alias = "the big light" },
        .{ .name = "Kettle plug", .entity = "switch.kettle", .kind = .plug, .area = "kitchen" },
        .{ .name = "Hall thermostat", .entity = "climate.hall", .kind = .climate, .area = "hall" },
        .{ .name = "Front door", .entity = "lock.front_door", .kind = .lock, .battery = 80, .area = "hall" },
        .{ .name = "Garage door", .entity = "cover.garage_door", .kind = .cover, .area = "garage" },
        .{ .name = "Hall motion", .entity = "binary_sensor.hall_motion", .kind = .motion, .area = "hall" },
        .{ .name = "Back door", .entity = "binary_sensor.back_door", .kind = .contact, .area = "kitchen" },
        .{ .name = "Water main", .entity = "valve.water_main", .kind = .valve, .on = true, .area = "kitchen" },
        .{ .name = "Bedroom lamp", .entity = "light.bedroom_lamp", .kind = .lamp, .area = "bedroom" },
        .{ .name = "Ceiling fan", .entity = "fan.ceiling_fan", .kind = .fan, .area = "bedroom" },
        .{ .name = "Kitchen speaker", .entity = "media_player.kitchen_speaker", .kind = .speaker, .area = "kitchen", .ha_only = true },
        .{ .name = "Evening", .entity = "scene.evening", .kind = .scene, .device = "-", .ha_only = true, .members = &.{ "light.living_room", "light.bedroom_lamp" } },
        .{ .name = "Leaving", .entity = "scene.leaving", .kind = .scene, .device = "-", .ha_only = true, .members = &.{ "light.living_room", "lock.front_door" } },
        .{ .name = "Anna", .entity = "person.anna", .kind = .person, .device = "-", .ha_only = true, .home = true },
        .{ .name = "Ben", .entity = "person.ben", .kind = .person, .device = "-", .ha_only = true },
        .{ .name = "Front door camera", .entity = "camera.front_door", .kind = .camera, .area = "hall", .ha_only = true },
        .{ .name = "Kitchen smoke alarm", .entity = "binary_sensor.kitchen_smoke", .kind = .smoke, .area = "kitchen" },
        .{ .name = "Kettle child lock", .entity = "switch.kettle_child_lock", .kind = .setting, .device = "d-switch.kettle", .category = "config", .ha_only = true },
        .{ .name = "Sun", .entity = "sun.sun", .kind = .other, .device = "-", .ha_only = true },
        .{ .name = "Living room temperature", .entity = "sensor.living_room_temperature", .kind = .temp, .area = "living_room", .temperature = 21.5 },
        .{ .name = "Sink leak", .entity = "binary_sensor.sink_leak", .kind = .leak, .area = "kitchen" },
    },

    fn init(io: Io) Home {
        var h: Home = .{ .io = io };
        const now = nowMs(io);
        for (&h.devs) |*d| d.changed_ms = now;
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
        d.changed_ms = nowMs(h.io);
        return true;
    }

    /// The test triggers: occupancy, contact, available, temperature,
    /// locked, leak, smoke; a person's home or zone.
    fn poke(h: *Home, d: *Dev, v: jv.Value) void {
        if (jv.boolean(jv.get(v, "occupancy"))) |x| d.occupancy = x;
        if (jv.boolean(jv.get(v, "contact"))) |x| d.closed = x;
        if (jv.boolean(jv.get(v, "available"))) |x| d.available = x;
        if (jv.num(jv.get(v, "temperature"))) |x| d.temperature = x;
        if (jv.boolean(jv.get(v, "locked"))) |x| d.locked = x;
        if (jv.boolean(jv.get(v, "leak"))) |x| d.wet = x;
        if (jv.boolean(jv.get(v, "smoke"))) |x| d.smoke = x;
        if (jv.boolean(jv.get(v, "home"))) |x| {
            d.home = x;
            d.zone = "";
        }
        if (jv.str(jv.get(v, "zone"))) |z| {
            d.home = false;
            d.zone = for ([_][]const u8{ "Work", "School" }) |known| {
                if (std.mem.eql(u8, z, known)) break known;
            } else "";
        }
        d.changed_ms = nowMs(h.io);
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// "2026-11-23T10:00:00.123000+00:00", as Home Assistant writes times.
fn isoMs(a: Allocator, ms: i64) ![]u8 {
    var tb: [20]u8 = undefined;
    const s = when.isoTime(&tb, @divFloor(ms, 1000));
    return std.fmt.allocPrint(a, "{s}.{d:0>3}000+00:00", .{ s[0 .. s.len - 1], @as(u64, @intCast(@mod(ms, 1000))) });
}

fn fanSpeed(pct: f64) u8 {
    if (pct <= 0) return 0;
    const idx: u32 = @min(3, @as(u32, @intFromFloat(@ceil(pct * 3 / 100))));
    return @intCast(idx * 100 / 3);
}

// ---- Zigbee2MQTT ----

fn z2mState(a: Allocator, d: *const Dev) ![]u8 {
    return switch (d.kind) {
        .light => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"brightness\":{d},\"linkquality\":120}}", .{ onOff(d.on), d.brightness }),
        .lamp => blk: {
            const xy = color.toXy(d.rgb);
            break :blk std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"brightness\":{d},\"color_mode\":\"{s}\",\"color_temp\":{d},\"color\":{{\"x\":{d:.4},\"y\":{d:.4}}},\"linkquality\":120}}", .{ onOff(d.on), d.brightness, if (d.temp_mode) "color_temp" else "xy", 1_000_000 / d.kelvin, xy.x, xy.y });
        },
        .plug => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"power\":{d}}}", .{ onOff(d.on), @as(u32, if (d.on) 2000 else 0) }),
        .valve => std.fmt.allocPrint(a, "{{\"state\":\"{s}\"}}", .{onOff(d.on)}),
        .fan => std.fmt.allocPrint(a, "{{\"fan_state\":\"{s}\",\"fan_mode\":\"{s}\"}}", .{ onOff(d.on), if (!d.on or d.speed == 0) "off" else if (d.speed <= 33) "low" else if (d.speed <= 66) "medium" else "high" }),
        .climate => std.fmt.allocPrint(a, "{{\"local_temperature\":{d:.1},\"current_heating_setpoint\":{d},\"system_mode\":\"{s}\",\"running_state\":\"{s}\"}}", .{ d.temperature, d.setpoint, d.mode, if (heating(d)) "heat" else "idle" }),
        .lock => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"lock_state\":\"{s}\",\"battery\":{d}}}", .{ if (d.locked) "LOCK" else "UNLOCK", if (d.locked) "locked" else "unlocked", d.battery }),
        .cover => std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"position\":{d}}}", .{ if (d.position > 0) "OPEN" else "CLOSE", d.position }),
        .motion => std.fmt.allocPrint(a, "{{\"occupancy\":{},\"battery\":{d}}}", .{ d.occupancy, d.battery }),
        .contact => std.fmt.allocPrint(a, "{{\"contact\":{},\"battery\":{d}}}", .{ d.closed, d.battery }),
        .smoke => std.fmt.allocPrint(a, "{{\"smoke\":{},\"battery\":{d}}}", .{ d.smoke, d.battery }),
        .temp => std.fmt.allocPrint(a, "{{\"temperature\":{d:.1},\"humidity\":45,\"battery\":{d}}}", .{ d.temperature, d.battery }),
        .leak => std.fmt.allocPrint(a, "{{\"water_leak\":{},\"battery\":{d}}}", .{ d.wet, d.battery }),
        else => a.dupe(u8, "{}"),
    };
}

/// What each kind exposes, as Zigbee2MQTT's bridge/devices says.
fn z2mExposes(k: Kind) []const u8 {
    const state = "{\"name\":\"state\",\"property\":\"state\",\"type\":\"binary\",\"access\":7,\"value_on\":\"ON\",\"value_off\":\"OFF\"}";
    const bright = "{\"name\":\"brightness\",\"property\":\"brightness\",\"type\":\"numeric\",\"access\":7,\"value_min\":0,\"value_max\":254}";
    const battery = "{\"name\":\"battery\",\"property\":\"battery\",\"type\":\"numeric\",\"access\":1,\"unit\":\"%\"}";
    return switch (k) {
        .light => "[{\"type\":\"light\",\"features\":[" ++ state ++ "," ++ bright ++ "]}]",
        .lamp => "[{\"type\":\"light\",\"features\":[" ++ state ++ "," ++ bright ++ ",{\"name\":\"color_temp\",\"property\":\"color_temp\",\"type\":\"numeric\",\"access\":7,\"value_min\":153,\"value_max\":500,\"unit\":\"mired\"},{\"name\":\"color_xy\",\"property\":\"color\",\"type\":\"composite\",\"access\":7}]}]",
        .plug => "[{\"type\":\"switch\",\"features\":[" ++ state ++ "]},{\"name\":\"power\",\"property\":\"power\",\"type\":\"numeric\",\"access\":5,\"unit\":\"W\"}]",
        // a water valve is a switch to Zigbee2MQTT: only its name says otherwise
        .valve => "[{\"type\":\"switch\",\"features\":[" ++ state ++ "]}]",
        .fan => "[{\"type\":\"fan\",\"features\":[{\"name\":\"state\",\"property\":\"fan_state\",\"type\":\"binary\",\"access\":7,\"value_on\":\"ON\",\"value_off\":\"OFF\"},{\"name\":\"mode\",\"property\":\"fan_mode\",\"type\":\"enum\",\"access\":7,\"values\":[\"off\",\"low\",\"medium\",\"high\",\"on\"]}]}]",
        .climate => "[{\"type\":\"climate\",\"features\":[{\"name\":\"local_temperature\",\"property\":\"local_temperature\",\"type\":\"numeric\",\"access\":5,\"unit\":\"°C\"},{\"name\":\"current_heating_setpoint\",\"property\":\"current_heating_setpoint\",\"type\":\"numeric\",\"access\":7,\"value_min\":5,\"value_max\":30,\"unit\":\"°C\"},{\"name\":\"system_mode\",\"property\":\"system_mode\",\"type\":\"enum\",\"access\":7,\"values\":[\"off\",\"heat\",\"auto\"]},{\"name\":\"running_state\",\"property\":\"running_state\",\"type\":\"enum\",\"access\":5,\"values\":[\"idle\",\"heat\"]}]}]",
        .lock => "[{\"type\":\"lock\",\"features\":[{\"name\":\"state\",\"property\":\"state\",\"type\":\"binary\",\"access\":7,\"value_on\":\"LOCK\",\"value_off\":\"UNLOCK\"},{\"name\":\"lock_state\",\"property\":\"lock_state\",\"type\":\"enum\",\"access\":1}]}," ++ battery ++ "]",
        .cover => "[{\"type\":\"cover\",\"features\":[{\"name\":\"state\",\"property\":\"state\",\"type\":\"enum\",\"access\":7,\"values\":[\"OPEN\",\"CLOSE\",\"STOP\"]},{\"name\":\"position\",\"property\":\"position\",\"type\":\"numeric\",\"access\":7,\"value_min\":0,\"value_max\":100}]}]",
        .motion => "[{\"name\":\"occupancy\",\"property\":\"occupancy\",\"type\":\"binary\",\"access\":1}," ++ battery ++ "]",
        .contact => "[{\"name\":\"contact\",\"property\":\"contact\",\"type\":\"binary\",\"access\":1}," ++ battery ++ "]",
        .smoke => "[{\"name\":\"smoke\",\"property\":\"smoke\",\"type\":\"binary\",\"access\":1}," ++ battery ++ "]",
        .temp => "[{\"name\":\"temperature\",\"property\":\"temperature\",\"type\":\"numeric\",\"access\":1,\"unit\":\"°C\"},{\"name\":\"humidity\",\"property\":\"humidity\",\"type\":\"numeric\",\"access\":1,\"unit\":\"%\"}," ++ battery ++ "]",
        .leak => "[{\"name\":\"water_leak\",\"property\":\"water_leak\",\"type\":\"binary\",\"access\":1}," ++ battery ++ "]",
        else => "[]",
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
    if (jv.get(v, "color")) |cv| {
        if (jv.str(jv.get(cv, "hex"))) |hx| if (color.parse(hx)) |c| {
            d.rgb = c;
            d.temp_mode = false;
        };
        if (jv.num(jv.get(cv, "x"))) |x| if (jv.num(jv.get(cv, "y"))) |y| {
            d.rgb = color.fromXy(x, y);
            d.temp_mode = false;
        };
    }
    if (jv.num(jv.get(v, "color_temp"))) |m| if (m > 0) {
        d.kelvin = @intFromFloat(@round(1e6 / m));
        d.temp_mode = true;
    };
    if (jv.str(jv.get(v, "fan_state"))) |st| {
        d.on = eqlI(st, "ON");
        if (d.on and d.speed == 0) d.speed = 33;
    }
    if (jv.str(jv.get(v, "fan_mode"))) |m| {
        if (eqlI(m, "off")) d.on = false else {
            d.on = true;
            d.speed = if (eqlI(m, "low")) 33 else if (eqlI(m, "medium")) 66 else 100;
        }
    }
    if (jv.num(jv.get(v, "current_heating_setpoint"))) |x| d.setpoint = x;
    if (jv.num(jv.get(v, "occupied_heating_setpoint"))) |x| d.setpoint = x;
    if (jv.str(jv.get(v, "system_mode"))) |m| d.mode = modeName(m);
    if (jv.int(jv.get(v, "position"))) |p| d.position = @intCast(std.math.clamp(p, 0, 100));
    d.changed_ms = nowMs(h.io);
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
        if (d.ha_only) continue;
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
                if (d) |x| if (!x.ha_only) home.poke(x, v);
                home.lock.unlock(io);
                if (d) |x| if (!x.ha_only) {
                    try c.publish(try topic(a, base, x.name, "/availability"), if (x.available) "{\"state\":\"online\"}" else "{\"state\":\"offline\"}", true);
                    if (x.available) try c.publish(try topic(a, base, x.name, ""), try z2mState(a, x), false);
                };
            } else if (tp.len > base.len + 1) {
                const rel = tp[base.len + 1 ..];
                const set = std.mem.endsWith(u8, rel, "/set");
                const get = std.mem.endsWith(u8, rel, "/get");
                if (set or get) {
                    home.lock.lockUncancelable(io);
                    const found = home.find(false, rel[0 .. rel.len - 4]);
                    const d = if (found) |x| (if (x.ha_only) null else x) else null;
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

/// Zigbee2MQTT's bridge/devices for the devices it plays.
pub fn bridgeDevices(a: Allocator, home: *Home) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "[{\"friendly_name\":\"Coordinator\",\"ieee_address\":\"0x00124b0000000000\",\"type\":\"Coordinator\",\"supported\":false,\"definition\":null}");
    for (home.devs, 0..) |d, i| {
        if (d.ha_only) continue;
        try o.print(a, ",{{\"friendly_name\":{f},\"ieee_address\":\"0x00124b00000000{x:0>2}\",\"type\":\"EndDevice\",\"supported\":true,\"definition\":{{\"model\":\"SIM-{s}\",\"vendor\":\"homemcp-sim\",\"description\":\"{s}\",\"exposes\":{s}}}}}", .{ std.json.fmt(d.name, .{}), i + 1, @tagName(d.kind), if (d.kind == .valve) "Water valve" else "A made-up device", z2mExposes(d.kind) });
    }
    try o.appendSlice(a, ",{\"friendly_name\":\"0x00124b0000000099\",\"ieee_address\":\"0x00124b0000000099\",\"type\":\"EndDevice\",\"supported\":false,\"definition\":null}]");
    return o.items;
}

// ---- Home Assistant: states and services ----

fn haState(a: Allocator, d: *const Dev) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    const t = try isoMs(a, d.changed_ms);
    const state: []const u8 = if (!d.available) "unavailable" else switch (d.kind) {
        .light, .lamp, .plug, .fan, .setting => if (d.on) "on" else "off",
        .valve => if (d.on) "open" else "closed",
        .climate => d.mode,
        .lock => if (d.locked) "locked" else "unlocked",
        .cover => if (d.position > 0) "open" else "closed",
        .motion => if (d.occupancy) "on" else "off",
        .contact => if (d.closed) "off" else "on",
        .smoke => if (d.smoke) "on" else "off",
        .leak => if (d.wet) "on" else "off",
        .speaker => d.playing,
        .scene => if (d.activated_ms == 0) "unknown" else try isoMs(a, d.activated_ms),
        .person => if (d.home) "home" else if (d.zone.len > 0) d.zone else "not_home",
        .camera => "idle",
        .temp => try std.fmt.allocPrint(a, "{d:.1}", .{d.temperature}),
        .other => "above_horizon",
    };
    try o.print(a, "{{\"entity_id\":\"{s}\",\"state\":{f},\"last_changed\":\"{s}\",\"last_updated\":\"{s}\",\"attributes\":{{", .{ d.entity, std.json.fmt(state, .{}), t, t });
    if (d.available) switch (d.kind) {
        .light => try o.print(a, "\"brightness\":{d},\"color_mode\":\"brightness\",\"supported_color_modes\":[\"brightness\"],", .{@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(d.brightness)) * 255.0 / 254.0)))}),
        .lamp => {
            try o.appendSlice(a, "\"supported_color_modes\":[\"color_temp\",\"hs\"],\"min_color_temp_kelvin\":2000,\"max_color_temp_kelvin\":6500,");
            if (d.on) {
                try o.print(a, "\"brightness\":{d},", .{@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(d.brightness)) * 255.0 / 254.0)))});
                const hs = color.toHs(d.rgb);
                if (d.temp_mode) {
                    try o.print(a, "\"color_mode\":\"color_temp\",\"color_temp_kelvin\":{d},", .{d.kelvin});
                } else try o.print(a, "\"color_mode\":\"hs\",\"hs_color\":[{d},{d}],\"rgb_color\":[{d},{d},{d}],", .{ hs[0], hs[1], d.rgb.r, d.rgb.g, d.rgb.b });
            }
        },
        .plug => try o.print(a, "\"current_power_w\":{d},\"device_class\":\"outlet\",", .{@as(u32, if (d.on) 2000 else 0)}),
        .fan => try o.print(a, "\"percentage\":{d},\"percentage_step\":33.333333333333336,", .{if (d.on) d.speed else 0}),
        .climate => try o.print(a, "\"current_temperature\":{d:.1},\"temperature\":{d},\"hvac_action\":\"{s}\",\"hvac_modes\":[\"off\",\"heat\",\"auto\"],", .{ d.temperature, d.setpoint, if (std.mem.eql(u8, d.mode, "off")) "off" else if (heating(d)) "heating" else "idle" }),
        .lock => try o.print(a, "\"battery_level\":{d},", .{d.battery}),
        .cover => try o.print(a, "\"current_position\":{d},\"device_class\":\"garage\",", .{d.position}),
        .motion => try o.appendSlice(a, "\"device_class\":\"motion\","),
        .contact => try o.appendSlice(a, "\"device_class\":\"door\","),
        .smoke => try o.appendSlice(a, "\"device_class\":\"smoke\","),
        .leak => try o.appendSlice(a, "\"device_class\":\"moisture\","),
        .temp => try o.appendSlice(a, "\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\"state_class\":\"measurement\","),
        .speaker => try o.print(a, "\"volume_level\":{d},\"is_volume_muted\":false,\"device_class\":\"speaker\",", .{@as(f64, @floatFromInt(d.volume)) / 100}),
        .scene => {
            try o.appendSlice(a, "\"entity_id\":[");
            for (d.members, 0..) |m, i| try o.print(a, "{s}\"{s}\"", .{ if (i > 0) "," else "", m });
            try o.appendSlice(a, "],");
        },
        .person => try o.print(a, "\"user_id\":null,\"source\":\"device_tracker.{s}_phone\",", .{d.entity["person.".len..]}),
        .camera => try o.appendSlice(a, "\"brand\":\"homemcp-sim\","),
        .valve, .setting, .other => {},
    };
    try o.print(a, "\"friendly_name\":{f}}}}}", .{std.json.fmt(d.name, .{})});
    return o.items;
}

/// A Home Assistant service call on one entity; false when the service is
/// not one this kind of device has.
fn haService(h: *Home, d: *Dev, domain: []const u8, service: []const u8, v: jv.Value) bool {
    const eq = std.mem.eql;
    const ok = switch (d.kind) {
        .light, .lamp => blk: {
            if (!eq(u8, domain, "light")) break :blk false;
            if (eq(u8, service, "turn_on")) {
                d.on = true;
                if (jv.num(jv.get(v, "brightness_pct"))) |p| d.brightness = @intFromFloat(@round(std.math.clamp(p, 0, 100) * 254.0 / 100.0));
                if (d.kind == .lamp) {
                    if (jv.arr(jv.get(v, "rgb_color"))) |c| if (c.len == 3) {
                        d.rgb = .{ .r = byteOf(c[0]), .g = byteOf(c[1]), .b = byteOf(c[2]) };
                        d.temp_mode = false;
                    };
                    if (jv.num(jv.get(v, "color_temp_kelvin"))) |k| {
                        // the lamp holds its colour temperature in mireds
                        const mired = @round(1e6 / std.math.clamp(k, 2000, 6500));
                        d.kelvin = @intFromFloat(@round(1e6 / mired));
                        d.temp_mode = true;
                    }
                }
                break :blk true;
            }
            if (eq(u8, service, "turn_off")) {
                d.on = false;
                break :blk true;
            }
            break :blk false;
        },
        .plug, .setting => blk: {
            if (!eq(u8, domain, "switch")) break :blk false;
            if (eq(u8, service, "turn_on")) d.on = true else if (eq(u8, service, "turn_off")) d.on = false else break :blk false;
            break :blk true;
        },
        .fan => blk: {
            if (!eq(u8, domain, "fan")) break :blk false;
            if (eq(u8, service, "turn_on")) {
                d.on = true;
                if (jv.num(jv.get(v, "percentage"))) |p| d.speed = fanSpeed(p);
                if (d.speed == 0) d.speed = 33;
            } else if (eq(u8, service, "turn_off")) {
                d.on = false;
            } else if (eq(u8, service, "set_percentage")) {
                const p = jv.num(jv.get(v, "percentage")) orelse break :blk false;
                d.speed = fanSpeed(p);
                d.on = d.speed > 0;
            } else break :blk false;
            break :blk true;
        },
        .climate => blk: {
            if (!eq(u8, domain, "climate")) break :blk false;
            if (eq(u8, service, "set_temperature")) {
                d.setpoint = jv.num(jv.get(v, "temperature")) orelse break :blk false;
            } else if (eq(u8, service, "set_hvac_mode")) {
                d.mode = modeName(jv.str(jv.get(v, "hvac_mode")) orelse break :blk false);
            } else break :blk false;
            break :blk true;
        },
        .lock => blk: {
            if (!eq(u8, domain, "lock")) break :blk false;
            if (eq(u8, service, "lock")) d.locked = true else if (eq(u8, service, "unlock")) d.locked = false else break :blk false;
            break :blk true;
        },
        .cover => blk: {
            if (!eq(u8, domain, "cover")) break :blk false;
            if (eq(u8, service, "open_cover")) {
                d.position = 100;
            } else if (eq(u8, service, "close_cover")) {
                d.position = 0;
            } else if (eq(u8, service, "stop_cover")) {} else if (eq(u8, service, "set_cover_position")) {
                d.position = @intCast(std.math.clamp(jv.int(jv.get(v, "position")) orelse break :blk false, 0, 100));
            } else break :blk false;
            break :blk true;
        },
        .valve => blk: {
            if (!eq(u8, domain, "valve")) break :blk false;
            if (eq(u8, service, "open_valve")) d.on = true else if (eq(u8, service, "close_valve")) d.on = false else break :blk false;
            break :blk true;
        },
        .speaker => blk: {
            if (!eq(u8, domain, "media_player")) break :blk false;
            if (eq(u8, service, "media_play")) {
                d.playing = "playing";
            } else if (eq(u8, service, "media_pause")) {
                d.playing = "paused";
            } else if (eq(u8, service, "volume_set")) {
                const x = jv.num(jv.get(v, "volume_level")) orelse break :blk false;
                d.volume = @intFromFloat(@round(std.math.clamp(x, 0, 1) * 100));
            } else break :blk false;
            break :blk true;
        },
        .scene => blk: {
            if (!eq(u8, domain, "scene") or !eq(u8, service, "turn_on")) break :blk false;
            d.activated_ms = nowMs(h.io);
            // what the scene sets
            if (eq(u8, d.entity, "scene.evening")) {
                const l = h.find(true, "light.living_room").?;
                l.on = true;
                l.brightness = 102;
                l.changed_ms = d.activated_ms;
                const lamp = h.find(true, "light.bedroom_lamp").?;
                lamp.on = true;
                lamp.temp_mode = true;
                lamp.kelvin = 2703;
                lamp.changed_ms = d.activated_ms;
            } else {
                const l = h.find(true, "light.living_room").?;
                l.on = false;
                l.changed_ms = d.activated_ms;
                const lk = h.find(true, "lock.front_door").?;
                lk.locked = true;
                lk.changed_ms = d.activated_ms;
            }
            break :blk true;
        },
        else => false,
    };
    if (ok) d.changed_ms = nowMs(h.io);
    return ok;
}

fn byteOf(v: jv.Value) u8 {
    const x = jv.num(v) orelse return 0;
    return @intFromFloat(std.math.clamp(@round(x), 0, 255));
}

// ---- Home Assistant: the server ----

/// A WebSocket client of the stand-in.
const WsClient = struct {
    ws: std.http.Server.WebSocket,
    handle: sock.Handle,
    write_lock: Io.Mutex = .init,
    /// The id of its subscribe_events for state_changed, once it asked.
    sub_id: ?i64 = null,

    fn send(c: *WsClient, io: Io, text: []const u8) void {
        c.write_lock.lockUncancelable(io);
        defer c.write_lock.unlock(io);
        c.ws.writeMessage(text, .text) catch {};
    }
};

pub const HaSim = struct {
    gpa: Allocator,
    io: Io,
    token: []const u8,
    home: Home,
    listener: sock.Listener,
    port: u16,
    stopping: std.atomic.Value(bool) = .init(false),
    /// WebSocket clients; under home.lock
    clients: std.ArrayList(*WsClient) = .empty,
    /// Each device's state as the clients last saw it; under home.lock
    seen: [n_devs][]const u8 = @splat(""),
    accept_done: std.atomic.Value(bool) = .init(false),

    /// Serves on 127.0.0.1:`port` (0: a free one, see `port`) until stop.
    pub fn start(gpa: Allocator, io: Io, port: u16, token: []const u8) !*HaSim {
        const l = try sock.Listener.open(port);
        errdefer l.close();
        const sim = try gpa.create(HaSim);
        sim.* = .{ .gpa = gpa, .io = io, .token = try gpa.dupe(u8, token), .home = .init(io), .listener = l, .port = l.port };
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        for (&sim.home.devs, &sim.seen) |*d, *s| s.* = try gpa.dupe(u8, try haState(arena_state.allocator(), d));
        (try std.Thread.spawn(.{}, acceptLoop, .{sim})).detach();
        (try std.Thread.spawn(.{}, ticker, .{sim})).detach();
        return sim;
    }

    /// Stops listening and cuts the WebSockets. Its memory is kept: threads
    /// still finishing may use it.
    pub fn stop(sim: *HaSim) void {
        sim.stopping.store(true, .release);
        // a connection wakes the accept, which then sees it should stop
        if (sock.connect(sim.io, "127.0.0.1", sim.port, 1000)) |h| sock.closeHandle(h) else |_| {}
        var waited: u32 = 0;
        while (!sim.accept_done.load(.acquire) and waited < 2000) : (waited += 10) sim.io.sleep(.fromMilliseconds(10), .awake) catch {};
        sim.listener.close();
        sim.dropWebSockets();
    }

    /// Cuts every WebSocket (their threads end).
    pub fn dropWebSockets(sim: *HaSim) void {
        sim.home.lock.lockUncancelable(sim.io);
        defer sim.home.lock.unlock(sim.io);
        for (sim.clients.items) |c| sock.shutdown(c.handle);
    }

    /// Changes an entity as a sensor or a hand would (see Home.poke).
    pub fn poke(sim: *HaSim, entity: []const u8, json_text: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(sim.gpa);
        defer arena_state.deinit();
        const v = jv.parse(arena_state.allocator(), json_text) orelse return error.BadJson;
        {
            sim.home.lock.lockUncancelable(sim.io);
            defer sim.home.lock.unlock(sim.io);
            const d = sim.home.find(true, entity) orelse return error.NoSuchEntity;
            sim.home.poke(d, v);
        }
        sim.broadcast();
    }

    /// Tells the WebSocket clients about every state that changed since
    /// they were last told (state_changed, with the old and new state).
    fn broadcast(sim: *HaSim) void {
        var arena_state = std.heap.ArenaAllocator.init(sim.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        sim.home.lock.lockUncancelable(sim.io);
        defer sim.home.lock.unlock(sim.io);
        for (&sim.home.devs, &sim.seen) |*d, *seen| {
            const now = haState(a, d) catch continue;
            if (std.mem.eql(u8, now, seen.*)) continue;
            const fired = isoMs(a, nowMs(sim.io)) catch continue;
            for (sim.clients.items) |c| {
                const id = c.sub_id orelse continue;
                const msg = std.fmt.allocPrint(a, "{{\"id\":{d},\"type\":\"event\",\"event\":{{\"event_type\":\"state_changed\",\"data\":{{\"entity_id\":\"{s}\",\"old_state\":{s},\"new_state\":{s}}},\"origin\":\"LOCAL\",\"time_fired\":\"{s}\",\"context\":{{\"id\":\"sim\",\"parent_id\":null,\"user_id\":null}}}}}}", .{ id, d.entity, seen.*, now, fired }) catch continue;
                c.send(sim.io, msg);
            }
            const keep = sim.gpa.dupe(u8, now) catch continue;
            sim.gpa.free(seen.*);
            seen.* = keep;
        }
    }

    fn acceptLoop(sim: *HaSim) void {
        defer sim.accept_done.store(true, .release);
        while (!sim.stopping.load(.acquire)) {
            const conn = sim.listener.accept() catch {
                if (sim.stopping.load(.acquire)) return;
                continue;
            };
            if (sim.stopping.load(.acquire)) {
                sock.closeHandle(conn);
                return;
            }
            const th = std.Thread.spawn(.{}, serve, .{ sim, conn }) catch {
                sock.closeHandle(conn);
                continue;
            };
            th.detach();
        }
    }

    fn ticker(sim: *HaSim) void {
        while (!sim.stopping.load(.acquire)) {
            sim.io.sleep(.fromMilliseconds(2000), .awake) catch {};
            if (sim.home.tick()) sim.broadcast();
        }
    }

    fn serve(sim: *HaSim, conn: sock.Handle) void {
        defer sock.closeHandle(conn);
        var rbuf: [64 * 1024]u8 = undefined;
        var wbuf: [64 * 1024]u8 = undefined;
        var sk: sock.Socket = undefined;
        sk.init(sim.io, conn, &rbuf, &wbuf, 60_000);
        var server = std.http.Server.init(&sk.reader, &sk.writer);
        while (!sim.stopping.load(.acquire)) {
            var req = server.receiveHead() catch return;
            if (std.mem.eql(u8, req.head.target, "/api/websocket")) switch (req.upgradeRequested()) {
                .websocket => |key| {
                    // a quiet home sends nothing for a long time
                    sk.idle_ms = 3_600_000;
                    return sim.webSocket(&req, key orelse return, conn);
                },
                else => {},
            };
            var arena_state = std.heap.ArenaAllocator.init(sim.gpa);
            defer arena_state.deinit();
            const changed = sim.handle(arena_state.allocator(), &req) catch return;
            if (changed) sim.broadcast();
        }
    }

    /// One REST request; true when it changed something.
    fn handle(sim: *HaSim, a: Allocator, req: *std.http.Server.Request) !bool {
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
        if (method == .POST and std.mem.eql(u8, route, "/homesim/drop_websockets")) {
            sim.dropWebSockets();
            _ = try json(req, .ok, "{}");
            return false;
        }
        const home = &sim.home;
        home.lock.lockUncancelable(sim.io);
        defer home.lock.unlock(sim.io);
        if (method == .GET and std.mem.eql(u8, route, "/api/")) return json(req, .ok, "{\"message\":\"API running.\"}");
        if (method == .GET and std.mem.eql(u8, route, "/api/states")) {
            _ = try json(req, .ok, try allStates(a, home));
            return false;
        }
        if (method == .GET and std.mem.startsWith(u8, route, "/api/states/")) {
            const d = home.find(true, route["/api/states/".len..]) orelse return json(req, .not_found, "{\"message\":\"Entity not found.\"}");
            _ = try json(req, .ok, try haState(a, d));
            return false;
        }
        if (method == .POST and std.mem.startsWith(u8, route, "/api/services/")) {
            const rest = route["/api/services/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return json(req, .bad_request, "{\"message\":\"Invalid service\"}");
            const v = jv.parse(a, body) orelse return json(req, .bad_request, "{\"message\":\"Data should be valid JSON.\"}");
            const d = home.find(true, jv.str(jv.get(v, "entity_id")) orelse "") orelse return json(req, .bad_request, "{\"message\":\"Entity not found.\"}");
            if (!d.available) {
                _ = try json(req, .ok, "[]");
                return false;
            }
            if (!haService(home, d, rest[0..slash], rest[slash + 1 ..], v)) return json(req, .bad_request, "{\"message\":\"Service not found.\"}");
            _ = try json(req, .ok, try std.fmt.allocPrint(a, "[{s}]", .{try haState(a, d)}));
            return true;
        }
        if (method == .POST and std.mem.startsWith(u8, route, "/homesim/")) {
            const d = home.find(true, route["/homesim/".len..]) orelse return json(req, .not_found, "{}");
            home.poke(d, jv.parse(a, body) orelse return json(req, .bad_request, "{}"));
            _ = try json(req, .ok, try haState(a, d));
            return true;
        }
        return json(req, .not_found, "{\"message\":\"Not found\"}");
    }

    /// Home Assistant's WebSocket API, as much of it as homemcp uses.
    fn webSocket(sim: *HaSim, req: *std.http.Server.Request, key: []const u8, conn: sock.Handle) void {
        const ws = req.respondWebSocket(.{ .key = key }) catch return;
        const c = sim.gpa.create(WsClient) catch return;
        defer sim.gpa.destroy(c);
        c.* = .{ .ws = ws, .handle = conn };
        c.send(sim.io, "{\"type\":\"auth_required\",\"ha_version\":\"2026.11.0\"}");
        var arena_state = std.heap.ArenaAllocator.init(sim.gpa);
        defer arena_state.deinit();
        {
            const m = c.ws.readSmallMessage() catch return;
            const v = jv.parse(arena_state.allocator(), m.data) orelse return;
            if (!std.mem.eql(u8, jv.str(jv.get(v, "type")) orelse "", "auth") or !std.mem.eql(u8, jv.str(jv.get(v, "access_token")) orelse "", sim.token)) {
                c.send(sim.io, "{\"type\":\"auth_invalid\",\"message\":\"Invalid access token or password\"}");
                return;
            }
            c.send(sim.io, "{\"type\":\"auth_ok\",\"ha_version\":\"2026.11.0\"}");
        }
        {
            sim.home.lock.lockUncancelable(sim.io);
            defer sim.home.lock.unlock(sim.io);
            sim.clients.append(sim.gpa, c) catch return;
        }
        defer {
            sim.home.lock.lockUncancelable(sim.io);
            for (sim.clients.items, 0..) |x, i| if (x == c) {
                _ = sim.clients.swapRemove(i);
                break;
            };
            sim.home.lock.unlock(sim.io);
        }
        while (!sim.stopping.load(.acquire)) {
            _ = arena_state.reset(.retain_capacity);
            const a = arena_state.allocator();
            const m = c.ws.readSmallMessage() catch return;
            if (m.opcode == .ping) {
                c.write_lock.lockUncancelable(sim.io);
                c.ws.writeMessage(m.data, .pong) catch {};
                c.write_lock.unlock(sim.io);
                continue;
            }
            const v = jv.parse(a, m.data) orelse return;
            const id = jv.int(jv.get(v, "id")) orelse return;
            const kind = jv.str(jv.get(v, "type")) orelse "";
            const answer = sim.command(a, c, id, kind, v) catch return;
            c.send(sim.io, answer);
        }
    }

    fn command(sim: *HaSim, a: Allocator, c: *WsClient, id: i64, kind: []const u8, v: jv.Value) ![]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, kind, "ping")) return std.fmt.allocPrint(a, "{{\"id\":{d},\"type\":\"pong\"}}", .{id});
        if (eq(u8, kind, "subscribe_events")) {
            if (!eq(u8, jv.str(jv.get(v, "event_type")) orelse "", "state_changed")) return failure(a, id, "unauthorized", "Unauthorized.");
            sim.home.lock.lockUncancelable(sim.io);
            c.sub_id = id;
            sim.home.lock.unlock(sim.io);
            return result(a, id, "null");
        }
        sim.home.lock.lockUncancelable(sim.io);
        defer sim.home.lock.unlock(sim.io);
        const home = &sim.home;
        if (eq(u8, kind, "get_states")) return result(a, id, try allStates(a, home));
        if (eq(u8, kind, "get_config")) return result(a, id, "{\"location_name\":\"The flat (made up by homemcp-sim)\",\"version\":\"2026.11.0\",\"unit_system\":{\"temperature\":\"°C\"}}");
        if (eq(u8, kind, "config/area_registry/list")) {
            var o: std.ArrayList(u8) = .empty;
            try o.append(a, '[');
            for (areas, 0..) |ar, i| try o.print(a, "{s}{{\"area_id\":\"{s}\",\"name\":\"{s}\",\"aliases\":[],\"floor_id\":null,\"icon\":null}}", .{ if (i > 0) "," else "", ar[0], ar[1] });
            try o.append(a, ']');
            return result(a, id, o.items);
        }
        if (eq(u8, kind, "config/device_registry/list")) {
            var o: std.ArrayList(u8) = .empty;
            try o.append(a, '[');
            var first = true;
            for (home.devs) |d| {
                if (d.device.len > 0) continue;
                try o.print(a, "{s}{{\"id\":\"d-{s}\",\"name\":{f},\"name_by_user\":null,\"area_id\":\"{s}\",\"manufacturer\":\"homemcp-sim\",\"model\":\"SIM-{s}\",\"disabled_by\":null,\"entry_type\":null}}", .{ if (first) "" else ",", d.entity, std.json.fmt(d.name, .{}), d.area, @tagName(d.kind) });
                first = false;
            }
            try o.append(a, ']');
            return result(a, id, o.items);
        }
        if (eq(u8, kind, "config/entity_registry/list")) {
            var o: std.ArrayList(u8) = .empty;
            try o.append(a, '[');
            for (home.devs, 0..) |d, i| {
                if (i > 0) try o.append(a, ',');
                try entityEntry(a, &o, &d, false);
            }
            try o.append(a, ']');
            return result(a, id, o.items);
        }
        if (eq(u8, kind, "config/entity_registry/get_entries")) {
            var o: std.ArrayList(u8) = .empty;
            try o.append(a, '{');
            for (jv.arr(jv.get(v, "entity_ids")) orelse &.{}, 0..) |e, i| {
                const name = jv.str(e) orelse continue;
                try o.print(a, "{s}{f}:", .{ if (i > 0) "," else "", std.json.fmt(name, .{}) });
                if (home.find(true, name)) |d| try entityEntry(a, &o, d, true) else try o.appendSlice(a, "null");
            }
            try o.append(a, '}');
            return result(a, id, o.items);
        }
        return failure(a, id, "unknown_command", "Unknown command.");
    }
};

fn entityEntry(a: Allocator, o: *std.ArrayList(u8), d: *const Dev, with_aliases: bool) !void {
    const device = if (std.mem.eql(u8, d.device, "-")) "null" else if (d.device.len > 0) try std.fmt.allocPrint(a, "\"{s}\"", .{d.device}) else try std.fmt.allocPrint(a, "\"d-{s}\"", .{d.entity});
    const category = if (d.category.len > 0) try std.fmt.allocPrint(a, "\"{s}\"", .{d.category}) else "null";
    try o.print(a, "{{\"entity_id\":\"{s}\",\"id\":\"e-{s}\",\"device_id\":{s},\"area_id\":null,\"name\":null,\"original_name\":{f},\"platform\":\"homesim\",\"disabled_by\":null,\"hidden_by\":null,\"entity_category\":{s},\"has_entity_name\":false", .{ d.entity, d.entity, device, std.json.fmt(d.name, .{}), category });
    if (with_aliases) {
        if (d.alias.len > 0) try o.print(a, ",\"aliases\":[{f}]", .{std.json.fmt(d.alias, .{})}) else try o.appendSlice(a, ",\"aliases\":[]");
    }
    try o.append(a, '}');
}

fn allStates(a: Allocator, home: *Home) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, '[');
    for (&home.devs, 0..) |*d, i| {
        if (i > 0) try o.append(a, ',');
        try o.appendSlice(a, try haState(a, d));
    }
    try o.append(a, ']');
    return o.items;
}

fn result(a: Allocator, id: i64, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"id\":{d},\"type\":\"result\",\"success\":true,\"result\":{s}}}", .{ id, body });
}

fn failure(a: Allocator, id: i64, code: []const u8, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"id\":{d},\"type\":\"result\",\"success\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ id, code, message });
}

/// Plays Home Assistant on 127.0.0.1:`port` until killed; `ready` is told
/// the port it listens on.
pub fn runHa(gpa: Allocator, io: Io, port: u16, token: []const u8, ready: *const fn (Io, u16) void) !void {
    const sim = try HaSim.start(gpa, io, port, token);
    ready(io, sim.port);
    while (true) io.sleep(.fromSeconds(3600), .awake) catch {};
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !bool {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    return false;
}

fn eqlI(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

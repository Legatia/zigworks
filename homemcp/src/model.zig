//! Devices as the agent sees them: kinds, the actions each kind can take,
//! which are always guarded, and one view (Props) of a device's state made
//! from Zigbee2MQTT's or Home Assistant's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const jv = @import("jv.zig");

pub const Kind = enum {
    light,
    @"switch",
    plug,
    climate,
    cover,
    lock,
    alarm,
    valve,
    sensor,

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }

    /// The actions a device of this kind can take at all.
    pub fn actions(k: Kind) []const Action {
        return switch (k) {
            .light => &.{ .on, .off, .brightness },
            .@"switch", .plug => &.{ .on, .off },
            .climate => &.{ .temperature, .mode },
            .cover => &.{ .open, .close, .stop, .position },
            .lock => &.{ .lock, .unlock },
            .alarm => &.{ .arm_home, .arm_away, .disarm },
            .valve => &.{ .open, .close },
            .sensor => &.{},
        };
    }

    /// Locks, alarms and valves are acted on only through the guarded tool.
    pub fn alwaysGuarded(k: Kind) bool {
        return k == .lock or k == .alarm or k == .valve;
    }
};

pub const Action = enum {
    on,
    off,
    brightness,
    temperature,
    mode,
    open,
    close,
    stop,
    position,
    lock,
    unlock,
    arm_home,
    arm_away,
    disarm,

    pub fn parse(s: []const u8) ?Action {
        return std.meta.stringToEnum(Action, s);
    }

    pub const Needs = enum { nothing, number, text };

    pub fn needs(a: Action) Needs {
        return switch (a) {
            .brightness, .temperature, .position => .number,
            .mode => .text,
            else => .nothing,
        };
    }
};

/// One view of a device's state, whichever hub it came from. Unknown: null.
pub const Props = struct {
    available: ?bool = null,
    on: ?bool = null,
    brightness: ?f64 = null, // %
    position: ?f64 = null, // % open
    cover: ?[]const u8 = null, // open, closed, opening, closing, stopped
    lock: ?[]const u8 = null, // locked, unlocked, not_fully_locked, jammed, ...
    temperature: ?f64 = null, // measured, °C
    setpoint: ?f64 = null, // °C
    mode: ?[]const u8 = null, // heat, off, auto, ...
    heating: ?[]const u8 = null, // what it is doing: heat, idle, ...
    humidity: ?f64 = null,
    occupancy: ?bool = null,
    open: ?bool = null, // a door or window contact: true = open
    leak: ?bool = null,
    smoke: ?bool = null,
    alarm: ?[]const u8 = null, // disarmed, armed_home, armed_away, triggered, ...
    battery: ?f64 = null,
    power: ?f64 = null, // W
    value: ?f64 = null, // another sensor's number
    unit: ?[]const u8 = null,

    pub const fields = [_][]const u8{ "on", "brightness", "position", "cover", "lock", "temperature", "setpoint", "mode", "heating", "humidity", "occupancy", "open", "leak", "smoke", "alarm", "battery", "power", "value", "available" };
};

/// From a Zigbee2MQTT state message (and availability, if known).
pub fn fromZ2m(kind: Kind, v: jv.Value) Props {
    var p: Props = .{};
    if (jv.str(jv.get(v, "state"))) |st| switch (kind) {
        .cover => p.cover = if (eqlI(st, "OPEN")) "open" else if (eqlI(st, "CLOSE") or eqlI(st, "CLOSED")) "closed" else st,
        .lock => p.lock = if (eqlI(st, "LOCK")) "locked" else if (eqlI(st, "UNLOCK")) "unlocked" else st,
        else => p.on = eqlI(st, "ON") or eqlI(st, "OPEN"),
    };
    if (jv.num(jv.get(v, "brightness"))) |b| p.brightness = round1(b / 254.0 * 100.0);
    if (jv.num(jv.get(v, "position"))) |x| p.position = x;
    if (jv.str(jv.get(v, "lock_state"))) |x| p.lock = x;
    if (jv.num(jv.get(v, "local_temperature"))) |x| p.temperature = x;
    if (jv.num(jv.get(v, "temperature"))) |x| p.temperature = x;
    if (jv.num(jv.get(v, "occupied_heating_setpoint"))) |x| p.setpoint = x;
    if (jv.num(jv.get(v, "current_heating_setpoint"))) |x| p.setpoint = x;
    if (jv.str(jv.get(v, "system_mode"))) |x| p.mode = x;
    if (jv.str(jv.get(v, "running_state"))) |x| p.heating = x;
    if (jv.num(jv.get(v, "humidity"))) |x| p.humidity = x;
    if (jv.boolean(jv.get(v, "occupancy"))) |x| p.occupancy = x;
    if (jv.boolean(jv.get(v, "contact"))) |x| p.open = !x; // Zigbee2MQTT: contact true = closed
    if (jv.boolean(jv.get(v, "water_leak"))) |x| p.leak = x;
    if (jv.boolean(jv.get(v, "smoke"))) |x| p.smoke = x;
    if (jv.num(jv.get(v, "battery"))) |x| p.battery = x;
    if (jv.num(jv.get(v, "power"))) |x| p.power = x;
    if (kind == .cover and p.cover == null) if (p.position) |pos| {
        p.cover = if (pos <= 0) "closed" else "open";
    };
    return p;
}

/// From a Home Assistant state object.
pub fn fromHa(kind: Kind, v: jv.Value) Props {
    var p: Props = .{};
    const id = jv.str(jv.get(v, "entity_id")) orelse "";
    const domain = id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
    const st = jv.str(jv.get(v, "state")) orelse "unknown";
    const attrs = jv.get(v, "attributes");
    p.available = !std.mem.eql(u8, st, "unavailable");
    if (!p.available.?) return p;
    const dclass = jv.str(jv.get(attrs, "device_class")) orelse "";
    switch (kind) {
        .light => {
            p.on = eql(st, "on");
            if (jv.num(jv.get(attrs, "brightness"))) |b| p.brightness = round1(b / 255.0 * 100.0);
            if (p.on == false) p.brightness = 0;
        },
        .@"switch", .plug => {
            p.on = eql(st, "on");
            if (jv.num(jv.get(attrs, "current_power_w"))) |w| p.power = w;
        },
        .climate => {
            p.mode = st;
            p.temperature = jv.num(jv.get(attrs, "current_temperature"));
            p.setpoint = jv.num(jv.get(attrs, "temperature"));
            p.heating = jv.str(jv.get(attrs, "hvac_action"));
        },
        .cover => {
            p.cover = st;
            p.position = jv.num(jv.get(attrs, "current_position"));
        },
        .lock => p.lock = st,
        .alarm => p.alarm = st,
        .valve => p.on = eql(st, "open") or eql(st, "opening"),
        .sensor => {
            if (std.mem.eql(u8, domain, "binary_sensor")) {
                const on = eql(st, "on");
                if (eqlAny(dclass, &.{ "motion", "occupancy", "presence" })) {
                    p.occupancy = on;
                } else if (eqlAny(dclass, &.{ "door", "window", "opening", "garage_door" })) {
                    p.open = on;
                } else if (eqlAny(dclass, &.{ "moisture", "water" })) {
                    p.leak = on;
                } else if (eqlAny(dclass, &.{ "smoke", "gas", "carbon_monoxide" })) {
                    p.smoke = on;
                } else p.on = on;
            } else if (std.fmt.parseFloat(f64, st)) |x| {
                if (eql(dclass, "temperature")) {
                    p.temperature = x;
                } else if (eql(dclass, "humidity")) {
                    p.humidity = x;
                } else if (eql(dclass, "battery")) {
                    p.battery = x;
                } else if (eql(dclass, "power")) {
                    p.power = x;
                } else {
                    p.value = x;
                    p.unit = jv.str(jv.get(attrs, "unit_of_measurement"));
                }
            } else |_| {}
        },
    }
    if (kind != .sensor) {
        if (jv.num(jv.get(attrs, "battery_level"))) |b| p.battery = b;
    }
    return p;
}

/// A short description: "on, 60% bright", "21.5 °C, set to 21 °C, mode heat".
pub fn describe(a: Allocator, kind: Kind, p: Props) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    if (p.available == false) return a.dupe(u8, "offline");
    switch (kind) {
        .light => if (p.on) |on| {
            try o.appendSlice(a, if (on) "on" else "off");
            if (on) if (p.brightness) |b| try o.print(a, ", {s}% bright", .{num(b)});
        },
        .@"switch", .plug => if (p.on) |on| try o.appendSlice(a, if (on) "on" else "off"),
        .valve => if (p.on) |on| try o.appendSlice(a, if (on) "open" else "closed"),
        .cover => cover: {
            const moving = if (p.cover) |c| eql(c, "opening") or eql(c, "closing") else false;
            if (p.position) |pos| if (pos > 0 and pos < 100) {
                try o.print(a, "{s}% open", .{num(pos)});
                if (moving) try o.print(a, ", {s}", .{p.cover.?});
                break :cover;
            };
            if (p.cover) |c| try o.appendSlice(a, c);
        },
        .lock => if (p.lock) |l| try o.appendSlice(a, l),
        .alarm => if (p.alarm) |al| try o.appendSlice(a, al),
        .climate => {
            if (p.temperature) |x| try o.print(a, "{s} °C", .{num(x)});
            if (p.setpoint) |x| try o.print(a, "{s}set to {s} °C", .{ sep(&o), num(x) });
            if (p.mode) |m| try o.print(a, "{s}mode {s}", .{ sep(&o), m });
            if (p.heating) |h| try o.print(a, "{s}{s}", .{ sep(&o), if (eql(h, "heat") or eql(h, "heating")) "heating" else h });
        },
        .sensor => {},
    }
    if (kind == .sensor or kind == .plug or kind == .@"switch") {
        if (p.occupancy) |x| try o.print(a, "{s}{s}", .{ sep(&o), if (x) "someone there" else "nobody there" });
        if (p.open) |x| try o.print(a, "{s}{s}", .{ sep(&o), if (x) "open" else "closed" });
        if (p.leak) |x| try o.print(a, "{s}{s}", .{ sep(&o), if (x) "WATER LEAK" else "dry" });
        if (p.smoke) |x| try o.print(a, "{s}{s}", .{ sep(&o), if (x) "SMOKE" else "no smoke" });
        if (kind == .sensor) if (p.temperature) |x| try o.print(a, "{s}{s} °C", .{ sep(&o), num(x) });
        if (p.humidity) |x| try o.print(a, "{s}humidity {s}%", .{ sep(&o), num(x) });
        if (p.power) |x| try o.print(a, "{s}{s} W", .{ sep(&o), num(x) });
        if (p.value) |x| try o.print(a, "{s}{s}{s}{s}", .{ sep(&o), num(x), if (p.unit != null) " " else "", p.unit orelse "" });
        if (kind == .sensor) if (p.on) |x| try o.print(a, "{s}{s}", .{ sep(&o), if (x) "on" else "off" });
    }
    if (p.battery) |b| if (b <= 20) try o.print(a, "{s}battery low ({s}%)", .{ sep(&o), num(b) });
    if (o.items.len == 0) try o.appendSlice(a, "no state reported yet");
    return o.items;
}

/// Whether the state shows an action took effect: null when the state
/// says nothing either way.
pub fn took(action: Action, number: ?f64, text: ?[]const u8, p: Props) ?bool {
    return switch (action) {
        .on => if (p.on) |x| x else null,
        .off => if (p.on) |x| !x else null,
        .brightness => if (p.brightness) |b| @abs(b - number.?) <= 2 else null,
        .temperature => if (p.setpoint) |s| @abs(s - number.?) < 0.01 else null,
        .mode => if (p.mode) |m| std.ascii.eqlIgnoreCase(m, text.?) else null,
        .open => if (p.cover) |c| (eql(c, "open") or eql(c, "opening")) else if (p.on) |x| x else null,
        .close => if (p.cover) |c| (eql(c, "closed") or eql(c, "closing")) else if (p.on) |x| !x else null,
        .stop => true,
        .position => if (p.position) |x| @abs(x - number.?) <= 2 else null,
        .lock => if (p.lock) |l| eql(l, "locked") else null,
        .unlock => if (p.lock) |l| eql(l, "unlocked") else null,
        .arm_home => if (p.alarm) |x| (eql(x, "armed_home") or eql(x, "arming")) else null,
        .arm_away => if (p.alarm) |x| (eql(x, "armed_away") or eql(x, "arming")) else null,
        .disarm => if (p.alarm) |x| eql(x, "disarmed") else null,
    };
}

/// A property's value as text, for waits and messages; null when unknown.
pub fn field(a: Allocator, p: Props, name: []const u8) !?[]const u8 {
    inline for (@typeInfo(Props).@"struct".field_names) |fname| {
        if (std.mem.eql(u8, fname, name)) {
            const v = @field(p, fname);
            if (v == null) return null;
            return switch (@TypeOf(v.?)) {
                bool => if (v.?) "yes" else "no",
                f64 => try a.dupe(u8, num(v.?)),
                []const u8 => v.?,
                else => null,
            };
        }
    }
    return null;
}

var num_buf: [8][32]u8 = undefined;
var num_i: usize = 0;

/// A number without needless decimals (from a small ring of buffers).
pub fn num(x: f64) []const u8 {
    num_i = (num_i + 1) % num_buf.len;
    const buf = &num_buf[num_i];
    if (@abs(x - @round(x)) < 1e-9 and @abs(x) < 1e15) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(@round(x)))}) catch "?";
    const s = std.fmt.bufPrint(buf, "{d:.2}", .{x}) catch return "?";
    var e = s.len;
    while (e > 0 and s[e - 1] == '0') e -= 1;
    if (e > 0 and s[e - 1] == '.') e -= 1;
    return s[0..e];
}

fn sep(o: *std.ArrayList(u8)) []const u8 {
    return if (o.items.len > 0) ", " else "";
}

fn round1(x: f64) f64 {
    return @round(x * 10) / 10;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn eqlI(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn eqlAny(a: []const u8, list: []const []const u8) bool {
    for (list) |x| if (eql(a, x)) return true;
    return false;
}

const t = std.testing;

test "Zigbee2MQTT states" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const light = fromZ2m(.light, jv.parse(a, "{\"state\":\"ON\",\"brightness\":127,\"linkquality\":90}").?);
    try t.expectEqual(true, light.on.?);
    try t.expectEqual(50, light.brightness.?);
    try t.expectEqualStrings("on, 50% bright", try describe(a, .light, light));
    const lock = fromZ2m(.lock, jv.parse(a, "{\"state\":\"LOCK\",\"lock_state\":\"not_fully_locked\"}").?);
    try t.expectEqualStrings("not_fully_locked", lock.lock.?);
    try t.expectEqual(false, took(.lock, null, null, lock).?);
    const th = fromZ2m(.climate, jv.parse(a, "{\"local_temperature\":20.5,\"current_heating_setpoint\":21,\"system_mode\":\"heat\",\"running_state\":\"heat\"}").?);
    try t.expectEqualStrings("20.5 °C, set to 21 °C, mode heat, heating", try describe(a, .climate, th));
    const door = fromZ2m(.sensor, jv.parse(a, "{\"contact\":false,\"battery\":15}").?);
    try t.expectEqualStrings("open, battery low (15%)", try describe(a, .sensor, door));
    const cover = fromZ2m(.cover, jv.parse(a, "{\"position\":40}").?);
    try t.expectEqualStrings("40% open", try describe(a, .cover, cover));
    try t.expectEqualStrings("yes", (try field(a, door, "open")).?);
    try t.expect((try field(a, door, "lock")) == null);
}

test "Home Assistant states" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const light = fromHa(.light, jv.parse(a, "{\"entity_id\":\"light.hall\",\"state\":\"on\",\"attributes\":{\"brightness\":255}}").?);
    try t.expectEqualStrings("on, 100% bright", try describe(a, .light, light));
    const motion = fromHa(.sensor, jv.parse(a, "{\"entity_id\":\"binary_sensor.hall\",\"state\":\"on\",\"attributes\":{\"device_class\":\"motion\"}}").?);
    try t.expectEqualStrings("someone there", try describe(a, .sensor, motion));
    const gone = fromHa(.lock, jv.parse(a, "{\"entity_id\":\"lock.front\",\"state\":\"unavailable\",\"attributes\":{}}").?);
    try t.expectEqualStrings("offline", try describe(a, .lock, gone));
    const clim = fromHa(.climate, jv.parse(a, "{\"entity_id\":\"climate.hall\",\"state\":\"heat\",\"attributes\":{\"current_temperature\":19.5,\"temperature\":21,\"hvac_action\":\"heating\"}}").?);
    try t.expectEqual(true, took(.temperature, 21, null, clim).?);
    try t.expectEqualStrings("19.5 °C, set to 21 °C, mode heat, heating", try describe(a, .climate, clim));
}

//! The home file: which hub, which devices the agent may see, and what it
//! may do with each. An INI file:
//!
//!   [home]
//!   name = The flat
//!   hub = zigbee2mqtt              ; or homeassistant
//!   mqtt = 127.0.0.1:1883          ; zigbee2mqtt: the broker
//!   base = zigbee2mqtt             ; zigbee2mqtt: its base topic
//!   url = http://127.0.0.1:8123    ; homeassistant: its address
//!   log = actions.jsonl            ; optional: one line per action (relative: to this file)
//!
//!   [limits]                       ; what the agent may choose
//!   temperature = 16 24            ; °C
//!   brightness = 1 100             ; %
//!   position = 0 100               ; %
//!
//!   [device hall_light]
//!   id = Hall light                ; zigbee2mqtt friendly name, or Home Assistant entity id
//!   kind = light                   ; light switch plug climate cover lock alarm valve sensor
//!   allow = on, off, brightness    ; what the agent may do (seeing it is always allowed)
//!   guarded = no                   ; yes: only through home_guarded, asked every time
//!   modes = off, heat              ; climate: the modes it may choose
//!   note = the one by the stairs
//!
//! Secrets come from the environment, never from this file: HA_TOKEN for
//! Home Assistant, MQTT_USER and MQTT_PASSWORD for the broker.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");
const model = @import("model.zig");

pub const Hub = enum { zigbee2mqtt, homeassistant };

pub const Range = struct { min: f64, max: f64 };

pub const Device = struct {
    name: []const u8,
    id: []const u8,
    kind: model.Kind,
    allow: []const model.Action,
    guarded: bool,
    modes: []const []const u8,
    note: []const u8,

    pub fn allows(d: *const Device, a: model.Action) bool {
        for (d.allow) |x| if (x == a) return true;
        return false;
    }
};

pub const Config = struct {
    name: []const u8 = "the home",
    hub: Hub = .zigbee2mqtt,
    mqtt_host: []const u8 = "127.0.0.1",
    mqtt_port: u16 = 1883,
    base: []const u8 = "zigbee2mqtt",
    url: []const u8 = "",
    log_path: []const u8 = "",
    temperature: Range = .{ .min = 16, .max = 24 },
    brightness: Range = .{ .min = 1, .max = 100 },
    position: Range = .{ .min = 0, .max = 100 },
    devices: []Device = &.{},

    pub fn device(c: *const Config, name: []const u8) ?usize {
        for (c.devices, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return i;
        return null;
    }

    /// Whether any device can be acted on through the guarded tool.
    pub fn hasGuarded(c: *const Config) bool {
        for (c.devices) |d| if (d.guarded and d.allow.len > 0) return true;
        return false;
    }

    pub fn hasOrdinary(c: *const Config) bool {
        for (c.devices) |d| if (!d.guarded and d.allow.len > 0) return true;
        return false;
    }
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| {
        diag.* = .{ .what = try std.fmt.allocPrint(a, "can't read {s}: {s}", .{ path, @errorName(e) }) };
        return error.BadConfig;
    };
    var c = try parse(a, text, diag);
    if (c.log_path.len > 0 and !std.fs.path.isAbsolute(c.log_path))
        c.log_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(path) orelse ".", c.log_path });
    return c;
}

const Pending = struct { name: []const u8, line: usize, id: []const u8 = "", kind: []const u8 = "", allow: []const u8 = "", guarded: ?bool = null, modes: []const u8 = "", note: []const u8 = "" };

pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Config {
    var bad: usize = 0;
    const entries = ini.parse(a, text, &bad) catch return fail(diag, bad, "not a key = value line or [section]");
    var c: Config = .{};
    var pend: std.ArrayList(Pending) = .empty;
    var hub_line: usize = 0;
    for (entries) |e| {
        const k = e.key;
        const v = e.value;
        if (eql(e.section, "home")) {
            if (eql(k, "name")) {
                c.name = v;
            } else if (eql(k, "hub")) {
                c.hub = std.meta.stringToEnum(Hub, v) orelse return fail(diag, e.line, "hub: zigbee2mqtt or homeassistant");
                hub_line = e.line;
            } else if (eql(k, "mqtt")) {
                const colon = std.mem.lastIndexOfScalar(u8, v, ':');
                c.mqtt_host = if (colon) |i| v[0..i] else v;
                c.mqtt_port = if (colon) |i| std.fmt.parseInt(u16, v[i + 1 ..], 10) catch return fail(diag, e.line, "mqtt: host:port") else 1883;
            } else if (eql(k, "base")) {
                c.base = std.mem.trimEnd(u8, v, "/");
            } else if (eql(k, "url")) {
                c.url = v;
            } else if (eql(k, "log")) {
                c.log_path = v;
            } else return unknown(a, diag, e);
        } else if (eql(e.section, "limits")) {
            const r = range(v) orelse return fail(diag, e.line, "a limit is two numbers: 16 24");
            if (eql(k, "temperature")) {
                c.temperature = r;
            } else if (eql(k, "brightness")) {
                c.brightness = r;
            } else if (eql(k, "position")) {
                c.position = r;
            } else return unknown(a, diag, e);
        } else if (eql(e.section, "device")) {
            if (e.name.len == 0) return fail(diag, e.line, "[device] needs a name: [device hall_light]");
            for (e.name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return fail(diag, e.line, "a device name is letters, digits and _");
            const d = blk: {
                for (pend.items) |*x| if (eql(x.name, e.name)) break :blk x;
                try pend.append(a, .{ .name = e.name, .line = e.line });
                break :blk &pend.items[pend.items.len - 1];
            };
            if (eql(k, "id")) {
                d.id = v;
            } else if (eql(k, "kind")) {
                d.kind = v;
            } else if (eql(k, "allow")) {
                d.allow = v;
            } else if (eql(k, "guarded")) {
                d.guarded = if (eql(v, "yes") or eql(v, "on")) true else if (eql(v, "no") or eql(v, "off")) false else return fail(diag, e.line, "guarded: yes or no");
            } else if (eql(k, "modes")) {
                d.modes = v;
            } else if (eql(k, "note")) {
                d.note = v;
            } else return unknown(a, diag, e);
        } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown section [{s}]", .{e.section}));
    }
    if (c.hub == .homeassistant and c.url.len == 0) return fail(diag, hub_line, "hub = homeassistant needs url = http://...");
    var devs: std.ArrayList(Device) = .empty;
    for (pend.items) |d| {
        if (d.id.len == 0) return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}] has no id", .{d.name}));
        const kind = model.Kind.parse(d.kind) orelse return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: kind is one of light, switch, plug, climate, cover, lock, alarm, valve, sensor", .{d.name}));
        if (c.hub == .homeassistant and std.mem.indexOfScalar(u8, d.id, '.') == null)
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a Home Assistant id is an entity id, such as light.hall", .{d.name}));
        if (c.hub == .zigbee2mqtt and kind == .alarm)
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: alarms need hub = homeassistant", .{d.name}));
        var allow: std.ArrayList(model.Action) = .empty;
        var it = std.mem.tokenizeAny(u8, d.allow, ", \t");
        while (it.next()) |w| {
            const act = model.Action.parse(w) orelse return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: no action called {s}", .{ d.name, w }));
            const ok = for (kind.actions()) |x| {
                if (x == act) break true;
            } else false;
            if (!ok) return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a {s} can't {s}", .{ d.name, @tagName(kind), w }));
            try allow.append(a, act);
        }
        var modes: std.ArrayList([]const u8) = .empty;
        var mi = std.mem.tokenizeAny(u8, d.modes, ", \t");
        while (mi.next()) |w| try modes.append(a, w);
        if (kind == .climate and modes.items.len == 0) try modes.appendSlice(a, &.{ "off", "heat" });
        try devs.append(a, .{
            .name = d.name,
            .id = d.id,
            .kind = kind,
            .allow = allow.items,
            .guarded = kind.alwaysGuarded() or (d.guarded orelse false),
            .modes = modes.items,
            .note = d.note,
        });
    }
    if (devs.items.len == 0) return fail(diag, 0, "no [device NAME] section");
    c.devices = devs.items;
    return c;
}

fn range(v: []const u8) ?Range {
    var it = std.mem.tokenizeAny(u8, v, " \t,");
    const lo = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const hi = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    if (it.next() != null or lo > hi) return null;
    return .{ .min = lo, .max = hi };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(diag: *Diag, line: usize, what: []const u8) error{BadConfig} {
    diag.* = .{ .line = line, .what = what };
    return error.BadConfig;
}

fn unknown(a: Allocator, diag: *Diag, e: ini.Entry) error{ BadConfig, OutOfMemory } {
    return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown key {s} in [{s}{s}{s}]", .{ e.key, e.section, if (e.name.len > 0) " " else "", e.name }));
}

const t = std.testing;

test "devices, their actions, guarded ones" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    const c = try parse(arena.allocator(),
        \\[home]
        \\name = Test flat
        \\mqtt = 10.0.0.5:1884
        \\[limits]
        \\temperature = 18 22
        \\[device hall_light]
        \\id = Hall light
        \\kind = light
        \\allow = on, off, brightness
        \\[device front_door]
        \\id = Front door
        \\kind = lock
        \\allow = lock
        \\[device garage]
        \\id = Garage door
        \\kind = cover
        \\allow = close
        \\guarded = yes
        \\[device motion]
        \\id = Hall motion
        \\kind = sensor
    , &d);
    try t.expectEqual(1884, c.mqtt_port);
    try t.expectEqualStrings("10.0.0.5", c.mqtt_host);
    try t.expectEqual(18, c.temperature.min);
    try t.expectEqual(4, c.devices.len);
    try t.expect(!c.devices[0].guarded and c.devices[0].allows(.brightness));
    try t.expect(c.devices[1].guarded and c.devices[1].allows(.lock) and !c.devices[1].allows(.unlock));
    try t.expect(c.devices[2].guarded);
    try t.expectEqual(0, c.devices[3].allow.len);
    try t.expect(c.hasGuarded() and c.hasOrdinary());
}

test "mistakes are named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device x]\nid = X\nkind = light\nallow = unlock\n", &d));
    try t.expectEqualStrings("[device x]: a light can't unlock", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[home]\nhub = homeassistant\nurl = http://h:8123\n[device x]\nid = Hall light\nkind = light\n", &d));
    try t.expectEqualStrings("[device x]: a Home Assistant id is an entity id, such as light.hall", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device x]\nid = X\nkind = toaster\n", &d));
}

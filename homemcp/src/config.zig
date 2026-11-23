//! The home file: which hub, which devices the agent may see, and what it
//! may do with each. An INI file:
//!
//!   [home]
//!   name = The flat
//!   hub = zigbee2mqtt              ; or homeassistant
//!   mqtt = 127.0.0.1:1883          ; zigbee2mqtt: the broker
//!   base = zigbee2mqtt             ; zigbee2mqtt: its base topic
//!   url = http://127.0.0.1:8123    ; homeassistant: its address
//!   tts = tts.piper                ; homeassistant: the text-to-speech a media player announces with
//!   log = actions.jsonl            ; optional: one line per action (relative: to this file)
//!
//!   [limits]                       ; what the agent may choose
//!   temperature = 16 24            ; °C
//!   brightness = 1 100             ; %
//!   position = 0 100               ; %
//!   color_temp = 2200 6500         ; K
//!   volume = 0 60                  ; %
//!   speed = 1 100                  ; %
//!
//!   [device hall_light]
//!   id = Hall light                ; zigbee2mqtt friendly name, or Home Assistant entity id
//!   kind = light                   ; light switch plug climate cover lock alarm valve sensor fan scene media satellite smoke
//!   room = Hall
//!   alias = the stairs light       ; what people call it (more lines, or commas, for more)
//!   allow = on, off, brightness    ; what the agent may do (seeing it is always allowed)
//!   guarded = no                   ; yes: only through home_guarded, asked every time
//!   modes = off, heat              ; climate: the modes it may choose
//!   note = the one by the stairs
//!
//!   [people]                       ; homeassistant: who is home, from its person entities
//!   anna = person.anna
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
    room: []const u8 = "",
    /// What people call it, as written in the file.
    aliases: []const []const u8 = &.{},

    pub fn allows(d: *const Device, a: model.Action) bool {
        for (d.allow) |x| if (x == a) return true;
        return false;
    }
};

/// Someone whose being home or away homemcp follows (a Home Assistant
/// person entity).
pub const Person = struct { name: []const u8, id: []const u8 };

pub const Config = struct {
    name: []const u8 = "the home",
    hub: Hub = .zigbee2mqtt,
    mqtt_host: []const u8 = "127.0.0.1",
    mqtt_port: u16 = 1883,
    base: []const u8 = "zigbee2mqtt",
    url: []const u8 = "",
    /// Home Assistant's text-to-speech entity a media player announces
    /// with (`tts.speak`); "": media players don't announce.
    tts: []const u8 = "",
    log_path: []const u8 = "",
    temperature: Range = .{ .min = 16, .max = 24 },
    brightness: Range = .{ .min = 1, .max = 100 },
    position: Range = .{ .min = 0, .max = 100 },
    color_temp: Range = .{ .min = 2200, .max = 6500 },
    volume: Range = .{ .min = 0, .max = 60 },
    speed: Range = .{ .min = 1, .max = 100 },
    devices: []Device = &.{},
    people: []Person = &.{},

    /// The device called `name`: its name in the file or one of its
    /// aliases. Case, spaces, `_` and `-`, and a leading "the" or "my"
    /// don't matter ("The big light", "living room light").
    pub fn device(c: *const Config, name: []const u8) ?usize {
        for (c.devices, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return i;
        var want_buf: [norm_max]u8 = undefined;
        const want = normalize(&want_buf, name) orelse return null;
        var buf: [norm_max]u8 = undefined;
        for (c.devices, 0..) |d, i| {
            if (eqlOpt(normalize(&buf, d.name), want)) return i;
            for (d.aliases) |al| if (eqlOpt(normalize(&buf, al), want)) return i;
        }
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

    /// The devices that may be given a message to say (`allow` has
    /// announce), by index, in the file's order, at most `buf.len`.
    pub fn speakers(c: *const Config, buf: []usize) []usize {
        var n: usize = 0;
        for (c.devices, 0..) |d, i| if (d.allows(.announce) and n < buf.len) {
            buf[n] = i;
            n += 1;
        };
        return buf[0..n];
    }
};

const norm_max = 128;

/// A name as it is matched: lowercase, `_` and `-` as spaces, one space
/// between words, without a leading "the " or "my ". Null when too long.
pub fn normalize(buf: *[norm_max]u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var space = true; // no leading space
    for (std.mem.trim(u8, s, " \t")) |ch0| {
        const ch = std.ascii.toLower(ch0);
        if (ch == ' ' or ch == '_' or ch == '-' or ch == '\t') {
            if (space) continue;
            space = true;
            if (n == buf.len) return null;
            buf[n] = ' ';
            n += 1;
            continue;
        }
        space = false;
        if (n == buf.len) return null;
        buf[n] = ch;
        n += 1;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    var out: []const u8 = buf[0..n];
    for ([_][]const u8{ "the ", "my " }) |lead| {
        if (out.len > lead.len and std.mem.startsWith(u8, out, lead)) out = out[lead.len..];
    }
    return out;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

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

const Pending = struct {
    name: []const u8,
    line: usize,
    id: []const u8 = "",
    kind: []const u8 = "",
    allow: []const u8 = "",
    guarded: ?bool = null,
    modes: []const u8 = "",
    note: []const u8 = "",
    room: []const u8 = "",
    aliases: std.ArrayList([]const u8) = .empty,
};

pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Config {
    var bad: usize = 0;
    const entries = ini.parse(a, text, &bad) catch return fail(diag, bad, "not a key = value line or [section]");
    var c: Config = .{};
    var pend: std.ArrayList(Pending) = .empty;
    var people: std.ArrayList(Person) = .empty;
    var hub_line: usize = 0;
    var people_line: usize = 0;
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
            } else if (eql(k, "tts")) {
                if (!std.mem.startsWith(u8, v, "tts.") or v.len == "tts.".len) return fail(diag, e.line, "tts: a text-to-speech entity, such as tts.piper");
                c.tts = v;
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
            } else if (eql(k, "color_temp") or eql(k, "colour_temp")) {
                c.color_temp = r;
            } else if (eql(k, "volume")) {
                c.volume = r;
            } else if (eql(k, "speed")) {
                c.speed = r;
            } else return unknown(a, diag, e);
        } else if (eql(e.section, "people")) {
            if (e.name.len > 0) return fail(diag, e.line, "[people] has no name of its own: [people]");
            if (!isName(k)) return fail(diag, e.line, "[people]: a name is letters, digits and _");
            if (!std.mem.startsWith(u8, v, "person.") or v.len == "person.".len)
                return fail(diag, e.line, try std.fmt.allocPrint(a, "[people] {s}: a person entity, such as person.{s}", .{ k, k }));
            for (people.items) |p| if (eql(p.name, k)) return fail(diag, e.line, try std.fmt.allocPrint(a, "[people]: {s} is there twice", .{k}));
            try people.append(a, .{ .name = k, .id = v });
            if (people_line == 0) people_line = e.line;
        } else if (eql(e.section, "device")) {
            if (e.name.len == 0) return fail(diag, e.line, "[device] needs a name: [device hall_light]");
            if (!isName(e.name)) return fail(diag, e.line, "a device name is letters, digits and _");
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
            } else if (eql(k, "room")) {
                d.room = v;
            } else if (eql(k, "alias")) {
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |raw| {
                    const al = std.mem.trim(u8, raw, " \t");
                    if (al.len == 0) continue;
                    var nb: [norm_max]u8 = undefined;
                    if (normalize(&nb, al) == null) return fail(diag, e.line, "an alias is at most 128 characters");
                    try d.aliases.append(a, al);
                }
            } else return unknown(a, diag, e);
        } else return fail(diag, e.line, try std.fmt.allocPrint(a, "unknown section [{s}]", .{e.section}));
    }
    if (c.hub == .homeassistant and c.url.len == 0) return fail(diag, hub_line, "hub = homeassistant needs url = http://...");
    if (people.items.len > 0 and c.hub != .homeassistant) return fail(diag, people_line, "[people] needs hub = homeassistant: people come from its person entities");
    var devs: std.ArrayList(Device) = .empty;
    for (pend.items) |*d| {
        if (d.id.len == 0) return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}] has no id", .{d.name}));
        const kind = model.Kind.parse(d.kind) orelse return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: kind is one of light, switch, plug, climate, cover, lock, alarm, valve, sensor, fan, scene, media, satellite, smoke", .{d.name}));
        // a smoke or CO alarm is only watched: no line may let anything act on it
        if (kind == .smoke and std.mem.trim(u8, d.allow, " \t").len > 0)
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a smoke or CO alarm is only watched: nothing may act on it (no allow line)", .{d.name}));
        if (kind == .smoke and (d.guarded orelse false))
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a smoke or CO alarm is only watched: nothing may act on it (no guarded line)", .{d.name}));
        if (c.hub == .homeassistant and std.mem.indexOfScalar(u8, d.id, '.') == null)
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a Home Assistant id is an entity id, such as light.hall", .{d.name}));
        if (c.hub == .zigbee2mqtt) if (kind.haOnly()) |what|
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: {s} need hub = homeassistant", .{ d.name, what }));
        if (kind == .satellite and !std.mem.startsWith(u8, d.id, "assist_satellite."))
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a satellite is an assist_satellite entity, such as assist_satellite.hall", .{d.name}));
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
        // a media player says a message through Home Assistant's text-to-speech
        if (kind == .media and c.tts.len == 0) for (allow.items) |act| if (act == .announce)
            return fail(diag, d.line, try std.fmt.allocPrint(a, "[device {s}]: a media player announces through Home Assistant's text-to-speech: [home] tts = tts.NAME (yours, such as tts.piper)", .{d.name}));
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
            .room = d.room,
            .aliases = d.aliases.items,
        });
    }
    if (devs.items.len == 0) return fail(diag, 0, "no [device NAME] section");
    // an alias names one device: not another's name, nor an alias before it
    for (devs.items, pend.items, 0..) |d, p, j| {
        var ab: [norm_max]u8 = undefined;
        var ob: [norm_max]u8 = undefined;
        for (d.aliases) |al| {
            const mine = normalize(&ab, al).?;
            for (devs.items, 0..) |other, i| {
                if (i == j) continue;
                var clash = eqlOpt(normalize(&ob, other.name), mine);
                if (i < j) for (other.aliases) |oal| {
                    if (eqlOpt(normalize(&ob, oal), mine)) clash = true;
                };
                if (clash) return fail(diag, p.line, try std.fmt.allocPrint(a, "[device {s}]: the alias \"{s}\" is also {s}'s", .{ d.name, al, other.name }));
            }
        }
    }
    c.devices = devs.items;
    c.people = people.items;
    return c;
}

fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
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

test "rooms, aliases, people and the wider kinds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    const c = try parse(arena.allocator(),
        \\[home]
        \\hub = homeassistant
        \\url = http://127.0.0.1:8123
        \\[limits]
        \\volume = 0 40
        \\color_temp = 2700 5000
        \\[device living_room_light]
        \\id = light.living_room
        \\kind = light
        \\room = Living room
        \\alias = the big light
        \\alias = Lounge lamp, ceiling light
        \\allow = on, off, colour, color_temp
        \\[device ceiling_fan]
        \\id = fan.ceiling
        \\kind = fan
        \\allow = on, off, speed
        \\[device evening]
        \\id = scene.evening
        \\kind = scene
        \\allow = activate
        \\[device speaker]
        \\id = media_player.kitchen
        \\kind = media
        \\allow = play, pause, volume
        \\[people]
        \\anna = person.anna
        \\ben = person.ben
    , &d);
    try t.expectEqualStrings("Living room", c.devices[0].room);
    try t.expectEqual(3, c.devices[0].aliases.len);
    try t.expect(c.devices[0].allows(.color) and c.devices[0].allows(.color_temp));
    try t.expectEqual(40, c.volume.max);
    try t.expectEqual(2700, c.color_temp.min);
    // the names people use: case, spaces, underscores and a leading "the" don't matter
    try t.expectEqual(0, c.device("The Big Light").?);
    try t.expectEqual(0, c.device("ceiling light").?);
    try t.expectEqual(0, c.device("Living room light").?);
    try t.expectEqual(0, c.device("living_room_light").?);
    try t.expectEqual(1, c.device("Ceiling fan").?);
    try t.expect(c.device("kitchen light") == null);
    try t.expect(c.devices[1].allows(.speed) and c.devices[2].allows(.activate) and c.devices[3].allows(.volume));
    try t.expectEqual(2, c.people.len);
    try t.expectEqualStrings("anna", c.people[0].name);
    try t.expectEqualStrings("person.ben", c.people[1].id);
}

test "an alias used twice, and kinds only Home Assistant has, are named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device a]\nid = A\nkind = light\nalias = lamp\n[device b]\nid = B\nkind = light\nalias = The lamp\n", &d));
    try t.expectEqualStrings("[device b]: the alias \"The lamp\" is also a\'s", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device a]\nid = A\nkind = light\n[device b]\nid = B\nkind = light\nalias = a\n", &d));
    try t.expectEqualStrings("[device b]: the alias \"a\" is also a\'s", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device s]\nid = Evening\nkind = scene\nallow = activate\n", &d));
    try t.expectEqualStrings("[device s]: scenes need hub = homeassistant", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device x]\nid = X\nkind = light\n[people]\nanna = person.anna\n", &d));
    try t.expectEqualStrings("[people] needs hub = homeassistant: people come from its person entities", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[home]\nhub = homeassistant\nurl = http://h\n[device x]\nid = light.x\nkind = light\n[people]\nanna = device_tracker.anna\n", &d));
    try t.expectEqualStrings("[people] anna: a person entity, such as person.anna", d.what);
    try t.expectError(error.BadConfig, parse(arena.allocator(), "[device x]\nid = X\nkind = light\nallow = speed\n", &d));
    try t.expectEqualStrings("[device x]: a light can't speed", d.what);
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

test "speakers that may announce" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const c = try parse(a,
        \\[home]
        \\hub = homeassistant
        \\url = http://127.0.0.1:8123
        \\tts = tts.piper
        \\[device hall_voice]
        \\id = assist_satellite.hall_voice
        \\kind = satellite
        \\room = Hall
        \\allow = announce
        \\[device kitchen_speaker]
        \\id = media_player.kitchen_speaker
        \\kind = media
        \\room = Kitchen
        \\allow = play, pause, announce
        \\[device bedroom_speaker]
        \\id = media_player.bedroom
        \\kind = media
        \\allow = play
    , &d);
    try t.expectEqualStrings("tts.piper", c.tts);
    try t.expect(c.devices[0].allows(.announce) and c.devices[1].allows(.announce) and !c.devices[2].allows(.announce));
    // the speakers that may announce, in the file's order
    var buf: [8]usize = undefined;
    const sp = c.speakers(&buf);
    try t.expectEqual(2, sp.len);
    try t.expectEqualStrings("hall_voice", c.devices[sp[0]].name);
    try t.expectEqualStrings("kitchen_speaker", c.devices[sp[1]].name);
    // a satellite is Home Assistant's, an assist_satellite, and only speaks;
    // a media player speaks through a text-to-speech entity
    try t.expectError(error.BadConfig, parse(a, "[device v]\nid = Hall voice\nkind = satellite\nallow = announce\n", &d));
    try t.expectEqualStrings("[device v]: voice satellites need hub = homeassistant", d.what);
    try t.expectError(error.BadConfig, parse(a, "[home]\nhub = homeassistant\nurl = http://h\n[device v]\nid = media_player.hall\nkind = satellite\nallow = announce\n", &d));
    try t.expectEqualStrings("[device v]: a satellite is an assist_satellite entity, such as assist_satellite.hall", d.what);
    try t.expectError(error.BadConfig, parse(a, "[home]\nhub = homeassistant\nurl = http://h\n[device v]\nid = assist_satellite.hall\nkind = satellite\nallow = play\n", &d));
    try t.expectEqualStrings("[device v]: a satellite can't play", d.what);
    try t.expectError(error.BadConfig, parse(a, "[home]\nhub = homeassistant\nurl = http://h\n[device s]\nid = media_player.hall\nkind = media\nallow = announce\n", &d));
    try t.expectEqualStrings("[device s]: a media player announces through Home Assistant's text-to-speech: [home] tts = tts.NAME (yours, such as tts.piper)", d.what);
    try t.expectError(error.BadConfig, parse(a, "[home]\nhub = homeassistant\nurl = http://h\ntts = piper\n[device x]\nid = light.x\nkind = light\n", &d));
    try t.expectEqualStrings("tts: a text-to-speech entity, such as tts.piper", d.what);
}

test "smoke_and_co_alarms_take_no_action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const head = "[home]\nhub = homeassistant\nurl = http://h\n";
    const c = try parse(a, try std.fmt.allocPrint(a, "{s}[device kitchen_smoke_alarm]\nid = binary_sensor.kitchen_smoke\nkind = smoke\nroom = Kitchen\n", .{head}), &d);
    try std.testing.expectEqual(model.Kind.smoke, c.devices[0].kind);
    try std.testing.expectEqual(0, c.devices[0].allow.len);
    try std.testing.expect(!c.devices[0].guarded);
    // a line that would let anything act on one is refused
    try std.testing.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "{s}[device s]\nid = binary_sensor.s\nkind = smoke\nallow = off\n", .{head}), &d));
    try std.testing.expectEqualStrings("[device s]: a smoke or CO alarm is only watched: nothing may act on it (no allow line)", d.what);
    try std.testing.expectError(error.BadConfig, parse(a, try std.fmt.allocPrint(a, "{s}[device s]\nid = binary_sensor.s\nkind = smoke\nguarded = yes\n", .{head}), &d));
    try std.testing.expectEqualStrings("[device s]: a smoke or CO alarm is only watched: nothing may act on it (no guarded line)", d.what);
}

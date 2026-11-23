//! The butler: a home file as homemcp writes it, read in harness's words
//! (devices, rooms, people, what discover left out, what `homemcp check`
//! reads of each), the devices a routine needs, and the routines of
//! `examples/butler/` filled with them. Pure: no I/O.
const std = @import("std");
const files = @import("butler_files");
const config = @import("config.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

/// What a device is, as the home file says it (`kind =`).
pub const Kind = enum { light, @"switch", plug, climate, cover, fan, scene, media, lock, alarm, valve, sensor, other };

pub const Device = struct {
    /// Its name in the home file: `[device NAME]`.
    name: []const u8,
    /// The hub's id (`light.kitchen`, a Zigbee2MQTT friendly name).
    id: []const u8 = "",
    kind: Kind = .other,
    room: []const u8 = "",
    aliases: []const []const u8 = &.{},
    /// What it may do (`allow =`); none: only seen.
    allow: []const []const u8 = &.{},
    /// `guarded = yes` (locks, alarms and valves are guarded anyway).
    guarded: bool = false,
    note: []const u8 = "",
    /// What `homemcp check` read of it now ("closed", "dry", "locked");
    /// "": not known.
    state: []const u8 = "",

    /// Guarded: only `home_guarded` acts on it, asked every time.
    pub fn isGuarded(d: Device) bool {
        return d.guarded or d.kind == .lock or d.kind == .alarm or d.kind == .valve;
    }

    /// It acts when asked, unasked by the gate's rules for the owner.
    pub fn acts(d: Device) bool {
        return !d.isGuarded() and d.allow.len > 0;
    }

    pub fn allows(d: Device, action: []const u8) bool {
        for (d.allow) |x| if (std.mem.eql(u8, x, action)) return true;
        return false;
    }

    /// A switch discover marked by its name as a valve (closed only).
    pub fn valveSwitch(d: Device) bool {
        return d.kind == .@"switch" and std.mem.startsWith(u8, d.note, "a valve");
    }

    /// One harness's setup could not identify: guarded until sorted.
    pub fn unidentified(d: Device) bool {
        return std.mem.startsWith(u8, d.note, unidentified_note);
    }

    /// A leak sensor: it reads dry or a leak, or its name says so.
    pub fn leakSensor(d: Device) bool {
        if (d.kind != .sensor) return false;
        if (d.state.len > 0) return std.ascii.eqlIgnoreCase(d.state, "dry") or std.ascii.findIgnoreCase(d.state, "leak") != null;
        return nameHas(d.name, &.{ "leak", "flood", "moisture" });
    }

    /// A door or window sensor: it reads open or closed, or its name says so.
    pub fn openingSensor(d: Device) bool {
        if (d.kind != .sensor) return false;
        if (d.state.len > 0) return std.ascii.eqlIgnoreCase(d.state, "open") or std.ascii.eqlIgnoreCase(d.state, "closed");
        return nameHas(d.name, &.{ "door", "window", "contact" });
    }
};

/// The note setup gives a switch it could not identify.
pub const unidentified_note = "not identified at setup: asked every time until you sort it";

fn nameHas(name: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.findIgnoreCase(name, w) != null) return true;
    return false;
}

/// Why discover left something out (its comment says).
pub const Why = enum { camera, safety, setting, hidden, unsupported, unknown };

pub const LeftOut = struct { id: []const u8, label: []const u8, why: Why };

pub const Home = struct {
    name: []const u8 = "",
    hub: []const u8 = "",
    /// Home Assistant's address, or Zigbee2MQTT's broker.
    url: []const u8 = "",
    devices: []Device = &.{},
    /// `[people]`: the names presence is about.
    people: []const []const u8 = &.{},
    left: []const LeftOut = &.{},

    pub fn find(h: Home, name: []const u8) ?*Device {
        for (h.devices) |*d| if (sameName(d.name, name)) return d;
        for (h.devices) |*d| for (d.aliases) |al| if (sameName(al, name)) return d;
        return null;
    }

    pub fn rooms(h: Home) usize {
        var n: usize = 0;
        for (h.devices, 0..) |d, i| {
            if (d.room.len == 0) continue;
            const seen = for (h.devices[0..i]) |e| {
                if (std.mem.eql(u8, e.room, d.room)) break true;
            } else false;
            if (!seen) n += 1;
        }
        return n;
    }
};

/// Whether two names are the same as homemcp reads them: case, spaces,
/// `_` and a leading "the" aside.
pub fn sameName(x: []const u8, y: []const u8) bool {
    var bx: [128]u8 = undefined;
    var by: [128]u8 = undefined;
    return std.mem.eql(u8, squash(&bx, x), squash(&by, y));
}

fn squash(buf: *[128]u8, s_in: []const u8) []const u8 {
    var s = std.mem.trim(u8, s_in, " \t");
    if (s.len > 4 and std.ascii.startsWithIgnoreCase(s, "the ")) s = s[4..];
    var n: usize = 0;
    for (s) |ch| {
        if (ch == ' ' or ch == '_' or ch == '\t') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    return buf[0..n];
}

/// A device's name as words: "front_door" → "front door".
pub fn spoken(a: Allocator, name: []const u8) ![]const u8 {
    const out = try a.dupe(u8, name);
    for (out) |*ch| if (ch.* == '_') {
        ch.* = ' ';
    };
    return out;
}

/// `s` with its first letter in upper case.
pub fn capital(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// A comment starts at `;` or `#` at the start of a line or after a space.
fn stripComment(raw: []const u8) []const u8 {
    for (raw, 0..) |c, i| {
        if ((c == ';' or c == '#') and (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) return raw[0..i];
    }
    return raw;
}

fn kindOf(word: []const u8) Kind {
    return std.meta.stringToEnum(Kind, word) orelse .other;
}

fn listOf(a: Allocator, v: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |raw| {
        const x = std.mem.trim(u8, raw, " \t");
        if (x.len > 0) try out.append(a, x);
    }
    return out.items;
}

/// Reads a home file as homemcp writes it (discover's, or one by hand):
/// `[home]`, `[device NAME]` sections, `[people]`, and discover's "Left
/// out, and why" comments. What it can't read it skips: homemcp's own
/// check names a bad line.
pub fn parseHome(a: Allocator, text: []const u8) !Home {
    var h: Home = .{};
    var devices: std.ArrayList(Device) = .empty;
    var people: std.ArrayList([]const u8) = .empty;
    var left: std.ArrayList(LeftOut) = .empty;
    var section: []const u8 = "";
    var in_left = false;
    var why: Why = .unknown;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, raw, " \t");
        // discover's list of what it left out, in comments
        if (std.mem.startsWith(u8, trimmed, ";")) {
            const c = std.mem.trimStart(u8, trimmed[1..], " ");
            if (std.mem.startsWith(u8, c, "Left out, and why:")) {
                in_left = true;
                continue;
            }
            if (!in_left) continue;
            if (std.mem.startsWith(u8, trimmed, ";   ")) {
                const item = std.mem.trim(u8, trimmed[1..], " ");
                // "camera.front_door (Front door camera)" or "Front door camera"
                if (std.mem.indexOf(u8, item, " (")) |p| if (std.mem.endsWith(u8, item, ")")) {
                    try left.append(a, .{ .id = item[0..p], .label = item[p + 2 .. item.len - 1], .why = why });
                    continue;
                };
                try left.append(a, .{ .id = item, .label = item, .why = why });
                continue;
            }
            why = if (std.mem.startsWith(u8, c, "cameras")) .camera else if (std.mem.startsWith(u8, c, "smoke")) .safety else if (std.mem.startsWith(u8, c, "settings")) .setting else if (std.mem.startsWith(u8, c, "hidden")) .hidden else if (std.mem.startsWith(u8, c, "not supported")) .unsupported else .unknown;
            continue;
        }
        const line = std.mem.trim(u8, stripComment(raw), " \t");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = std.mem.trim(u8, line[1..close], " \t");
            if (std.mem.startsWith(u8, section, "device ")) {
                try devices.append(a, .{ .name = std.mem.trim(u8, section["device ".len..], " \t") });
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const eql = std.mem.eql;
        if (eql(u8, section, "home")) {
            if (eql(u8, key, "name")) h.name = v;
            if (eql(u8, key, "hub")) h.hub = v;
            if (eql(u8, key, "url") or eql(u8, key, "mqtt")) h.url = v;
        } else if (eql(u8, section, "people")) {
            try people.append(a, key);
        } else if (std.mem.startsWith(u8, section, "device ") and devices.items.len > 0) {
            const d = &devices.items[devices.items.len - 1];
            if (eql(u8, key, "id")) d.id = v;
            if (eql(u8, key, "kind")) d.kind = kindOf(v);
            if (eql(u8, key, "room")) d.room = v;
            if (eql(u8, key, "alias")) d.aliases = try std.mem.concat(a, []const u8, &.{ d.aliases, try listOf(a, v) });
            if (eql(u8, key, "allow")) d.allow = try listOf(a, v);
            if (eql(u8, key, "guarded")) d.guarded = config.parseBool(v) orelse false;
            if (eql(u8, key, "note")) d.note = v;
        }
    }
    h.devices = devices.items;
    h.people = people.items;
    h.left = left.items;
    return h;
}

/// What `homemcp check` read of each device ("  back_door (…): closed;
/// may: …"), put in `h`'s devices' `state`.
pub fn readCheck(h: *Home, check_out: []const u8) void {
    var it = std.mem.splitScalar(u8, check_out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const paren = std.mem.indexOf(u8, line, " (") orelse continue;
        const colon = std.mem.indexOf(u8, line, "): ") orelse continue;
        if (colon < paren) continue;
        const rest = line[colon + 3 ..];
        const state = rest[0 .. std.mem.indexOf(u8, rest, "; may:") orelse continue];
        for (h.devices) |*d| if (std.mem.eql(u8, d.name, line[0..paren])) {
            d.state = state;
        };
    }
}

// ---- the routines ----

/// What the routines can use, picked from the home and the settings.
pub const Picks = struct {
    lights: usize = 0,
    thermostat: ?Device = null,
    lock: ?Device = null,
    /// The water main: a valve, or a switch discover named a valve.
    valve: ?Device = null,
    leaks: []const Device = &.{},
    /// Doors and windows: contact sensors.
    doors: []const Device = &.{},
    /// `[people]` says who is home: leaving and arriving can run.
    people: bool = false,
    /// mcp.ini has carcloud as `car`.
    car: bool = false,
    /// Search is set up: the morning summary can say the weather.
    search: bool = false,
    /// An MCP server whose name has "calendar"; "": none.
    calendar: []const u8 = "",
    /// Quiet hours, the owner's: the routines' times come from them.
    quiet: ?config.Quiet = null,
    /// Where the weather is read for; "": none said.
    town: []const u8 = "",
    night_temp: u16 = 18,
    away_temp: u16 = 17,
    home_temp: u16 = 21,
};

pub const Settings = struct { car: bool = false, search: bool = false, calendar: []const u8 = "", quiet: ?config.Quiet = null, town: []const u8 = "" };

/// The devices and settings the routines use: every light; the first
/// thermostat; the first lock (a front one first); the water main (a
/// valve, else a switch named one); every leak sensor; every door and
/// window sensor.
pub fn pick(a: Allocator, h: Home, s: Settings) !Picks {
    var p: Picks = .{ .people = h.people.len > 0, .car = s.car, .search = s.search, .calendar = s.calendar, .quiet = s.quiet, .town = s.town };
    var leaks: std.ArrayList(Device) = .empty;
    var doors: std.ArrayList(Device) = .empty;
    for (h.devices) |d| {
        switch (d.kind) {
            .light => p.lights += 1,
            .climate => if (p.thermostat == null and d.allows("temperature")) {
                p.thermostat = d;
            },
            .lock => if (d.allows("lock")) {
                if (p.lock == null or (nameHas(d.name, &.{"front"}) and !nameHas(p.lock.?.name, &.{"front"}))) p.lock = d;
            },
            .valve => if (p.valve == null and d.allows("close")) {
                p.valve = d;
            },
            .sensor => {
                if (d.leakSensor()) try leaks.append(a, d) else if (d.openingSensor()) try doors.append(a, d);
            },
            else => {},
        }
    }
    if (p.valve == null) for (h.devices) |d| if (d.valveSwitch() and d.allows("off")) {
        p.valve = d;
        break;
    };
    p.leaks = leaks.items;
    p.doors = doors.items;
    return p;
}

/// "HH:MM".
fn clock(a: Allocator, minutes: u16) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ minutes / 60, minutes % 60 });
}

fn minusMinutes(m: u16, by: u16) u16 {
    return @intCast(@mod(@as(i32, m) - by, 24 * 60));
}

/// When goodnight runs by itself: 15 minutes before quiet hours (its
/// question would otherwise wait for the morning), else 22:00.
pub fn goodnightAt(p: Picks) u16 {
    return if (p.quiet) |q| minusMinutes(q.start, 15) else 22 * 60;
}

/// The morning summary: as quiet hours end, else 07:00.
pub fn morningAt(p: Picks) u16 {
    return if (p.quiet) |q| q.end else 7 * 60;
}

/// The car's evening check: 90 minutes before quiet hours, else 20:30.
pub fn carAt(p: Picks) u16 {
    return if (p.quiet) |q| minusMinutes(q.start, 90) else 20 * 60 + 30;
}

pub const Routine = enum {
    goodnight,
    leaving,
    arriving,
    @"morning-home",
    leak,
    @"door-open",
    @"car-tomorrow",

    /// The workflow's name (and its file's).
    pub fn name(r: Routine) []const u8 {
        return @tagName(r);
    }

    /// Its name in the owner's words.
    pub fn title(r: Routine) []const u8 {
        return switch (r) {
            .goodnight => "Goodnight",
            .leaving => "Leaving",
            .arriving => "Arriving",
            .@"morning-home" => "Morning summary",
            .leak => "Leak",
            .@"door-open" => "Doors left open",
            .@"car-tomorrow" => "Car for tomorrow",
        };
    }

    /// Whether the home (and the settings) have what it needs.
    pub fn offered(r: Routine, p: Picks) bool {
        return switch (r) {
            .goodnight => p.lights > 0 or p.thermostat != null or p.lock != null,
            .leaving => p.people and (p.lock != null or p.thermostat != null),
            .arriving => p.people and p.thermostat != null,
            .@"morning-home" => true,
            .leak => p.leaks.len > 0,
            .@"door-open" => p.doors.len > 0,
            .@"car-tomorrow" => p.car,
        };
    }

    /// One sentence on what it does, with the owner's devices and times.
    pub fn sentence(r: Routine, a: Allocator, p: Picks) ![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        switch (r) {
            .goodnight => {
                try o.print(a, "Goodnight: when you say goodnight, or at {s}, I ", .{try clock(a, goodnightAt(p))});
                var parts: std.ArrayList([]const u8) = .empty;
                if (p.lights > 0) try parts.append(a, "switch off the lights");
                if (p.thermostat != null) try parts.append(a, try std.fmt.allocPrint(a, "set the heating to {d} °C", .{p.night_temp}));
                if (p.lock) |l| try parts.append(a, try std.fmt.allocPrint(a, "ask with one tap before locking the {s}", .{try spoken(a, l.name)}));
                try o.appendSlice(a, try andList(a, parts.items));
                try o.append(a, '.');
            },
            .leaving => {
                try o.appendSlice(a, "Leaving: when everyone has gone out, I say what is still open or on");
                var parts: std.ArrayList([]const u8) = .empty;
                if (p.lock) |l| try parts.append(a, try std.fmt.allocPrint(a, "locking the {s}", .{try spoken(a, l.name)}));
                if (p.thermostat != null) try parts.append(a, try std.fmt.allocPrint(a, "turning the heating down to {d} °C", .{p.away_temp}));
                if (parts.items.len > 0) try o.print(a, ", and ask with one tap before {s}", .{try andList(a, parts.items)});
                try o.append(a, '.');
            },
            .arriving => try o.print(a, "Arriving: when the first of you comes home, I set the heating back to {d} °C and say so.", .{p.home_temp}),
            .@"morning-home" => {
                try o.print(a, "Morning summary: at {s}, as quiet hours end, {s} in a few lines, after what the night held.", .{ try clock(a, morningAt(p)), try morningParts(a, p, false) });
                if (p.search and p.town.len == 0) try o.appendSlice(a, " For the weather, reply with your town.");
            },
            .leak => {
                try o.print(a, "Leak: when {s} finds water, I tell you at once, even at night", .{try sensorList(a, p.leaks, "a leak sensor")});
                if (p.valve) |v| try o.print(a, ", and one tap closes the {s}", .{try spoken(a, v.name)});
                try o.append(a, '.');
            },
            .@"door-open" => try o.print(a, "Doors left open: when {s} stays open for 10 minutes, I tell you.", .{try sensorList(a, p.doors, "a door or window")}),
            .@"car-tomorrow" => try o.print(a, "Car for tomorrow: at {s}, when the car is under half, I tell you, and ask with one tap to start charging when it's plugged in.", .{try clock(a, carAt(p))}),
        }
        return o.items;
    }
};

/// The routines in the order setup offers them.
pub const all = [_]Routine{ .goodnight, .leaving, .arriving, .@"morning-home", .leak, .@"door-open", .@"car-tomorrow" };

fn andList(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", parts[0 .. parts.len - 1]), parts[parts.len - 1] });
}

fn orList(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    return std.fmt.allocPrint(a, "{s} or {s}", .{ try std.mem.join(a, ", ", parts[0 .. parts.len - 1]), parts[parts.len - 1] });
}

/// "the sink leak", "the back door or the bedroom window", "one of 5 doors
/// and windows".
fn sensorList(a: Allocator, list: []const Device, one_of: []const u8) ![]const u8 {
    if (list.len > 3) return std.fmt.allocPrint(a, "{s} (one of {d})", .{ one_of, list.len });
    var names: std.ArrayList([]const u8) = .empty;
    for (list) |d| try names.append(a, try std.fmt.allocPrint(a, "the {s}", .{try spoken(a, d.name)}));
    return orList(a, names.items);
}

/// What the morning summary reads: "the car, the weather in Kraków and
/// the house"; `tools` adds what each is read with.
fn morningParts(a: Allocator, p: Picks, tools: bool) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (p.car) try parts.append(a, if (tools) "the car (car/car_status)" else "the car");
    if (p.calendar.len > 0) try parts.append(a, if (tools) try std.fmt.allocPrint(a, "today's calendar ({s}/*)", .{p.calendar}) else "today's calendar");
    if (p.search and p.town.len > 0) try parts.append(a, if (tools) try std.fmt.allocPrint(a, "today's weather in {s} (search)", .{p.town}) else try std.fmt.allocPrint(a, "the weather in {s}", .{p.town}));
    try parts.append(a, if (tools) "the house (home/home_state)" else "the house");
    return andList(a, parts.items);
}

/// A label for a text: letters, digits, spaces and plain punctuation;
/// braces, angle brackets and line breaks left out.
fn plainWords(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '{', '}', '<', '>', '\r', '\n', '\t' => {},
        else => try o.append(a, ch),
    };
    return o.items;
}

/// A `<key>` and its value, for `fill`.
pub const Value = struct { key: []const u8, value: []const u8 };

pub const FillError = error{ UnknownPlaceholder, UnbalancedIf, OutOfMemory };

/// `template` with its `#if NAME` / `#if !NAME` … `#end` lines (at any
/// indent) kept or dropped as `flags` say, then each `<key>` replaced by
/// its value (`<Key>`: the value with a capital). A `<…>` that names no
/// value is an error, `missing` saying which.
pub fn fill(a: Allocator, template: []const u8, values: []const Value, flags: []const []const u8, missing: *[]const u8) FillError![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var stack: std.ArrayList(bool) = .empty;
    var it = std.mem.splitScalar(u8, template, '\n');
    var first = true;
    while (it.next()) |line| {
        const tl = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, tl, "#if ")) {
            var cond = std.mem.trim(u8, tl[4..], " \t");
            const neg = cond.len > 0 and cond[0] == '!';
            if (neg) cond = cond[1..];
            var on = false;
            for (flags) |f| if (std.mem.eql(u8, f, cond)) {
                on = true;
            };
            try stack.append(a, on != neg);
            continue;
        }
        if (std.mem.eql(u8, tl, "#end")) {
            if (stack.items.len == 0) return error.UnbalancedIf;
            _ = stack.pop();
            continue;
        }
        const shown = for (stack.items) |x| {
            if (!x) break false;
        } else true;
        if (!shown) continue;
        if (!first) try kept.append(a, '\n');
        first = false;
        try kept.appendSlice(a, line);
    }
    if (stack.items.len != 0) return error.UnbalancedIf;
    var out: std.ArrayList(u8) = .empty;
    const text = kept.items;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') if (std.mem.indexOfScalarPos(u8, text, i, '>')) |close| {
            const key = text[i + 1 .. close];
            if (placeholderKey(key)) {
                const v = valueOf(a, values, key) catch return error.OutOfMemory;
                if (v) |x| {
                    try out.appendSlice(a, x);
                    i = close + 1;
                    continue;
                }
                missing.* = key;
                return error.UnknownPlaceholder;
            }
        };
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

/// A placeholder's key: letters first, then letters, digits, spaces, `-`
/// and `°`; up to 40 bytes.
fn placeholderKey(k: []const u8) bool {
    if (k.len == 0 or k.len > 40 or !std.ascii.isAlphabetic(k[0])) return false;
    for (k) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == ' ' or ch == '-' or ch >= 0x80)) return false;
    return true;
}

fn valueOf(a: Allocator, values: []const Value, key: []const u8) !?[]const u8 {
    for (values) |v| if (std.mem.eql(u8, v.key, key)) return v.value;
    // <Lock label>: <lock label> with a capital
    if (std.ascii.isUpper(key[0])) {
        const lower = try a.dupe(u8, key);
        lower[0] = std.ascii.toLower(lower[0]);
        for (values) |v| if (std.mem.eql(u8, v.key, lower)) return try capital(a, v.value);
    }
    return null;
}

/// A routine's files, filled: its workflow, its triggers.ini sections and
/// its rules lines ("" when it needs none).
pub const Files = struct { workflow: []const u8, triggers: []const u8, rules: []const u8 };

/// The workflow template of `r`.
fn workflowTemplate(r: Routine) []const u8 {
    for (files.workflows) |w| if (std.mem.eql(u8, w.name, r.name())) return w.text;
    unreachable;
}

/// The triggers.ini sections `r` needs, by name (as examples/butler/triggers.ini has them).
fn triggerSections(r: Routine) []const []const u8 {
    return switch (r) {
        .goodnight => &.{"goodnight-at"},
        .leaving => &.{"everyone-left"},
        .arriving => &.{"first-home"},
        .@"morning-home" => &.{"morning-home-at"},
        .leak => &.{"leak-<leak>"},
        .@"door-open" => &.{"door-<door>"},
        .@"car-tomorrow" => &.{"car-evening"},
    };
}

/// The rules group `r` needs, by its comment's first words; null: none.
fn rulesGroup(r: Routine, p: Picks) ?[]const u8 {
    return switch (r) {
        .goodnight => if (p.lights > 0 or p.thermostat != null) "goodnight:" else null,
        .arriving => "arriving:",
        .@"morning-home" => if (p.calendar.len > 0) "the morning summary:" else null,
        else => null,
    };
}

/// A section of an INI text by its header's name: its comment lines just
/// above, its header and lines (to the next blank line or header).
pub fn sectionOf(a: Allocator, text: []const u8, name: []const u8) !?[]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    const header = try std.fmt.allocPrint(a, "[{s}]", .{name});
    for (lines.items, 0..) |l, i| {
        if (!std.mem.eql(u8, std.mem.trim(u8, l, " \t"), header)) continue;
        var start = i;
        while (start > 0 and std.mem.startsWith(u8, lines.items[start - 1], ";")) start -= 1;
        var end = i + 1;
        while (end < lines.items.len) : (end += 1) {
            const x = std.mem.trim(u8, lines.items[end], " \t");
            if (x.len == 0 or x[0] == '[') break;
        }
        return try std.mem.join(a, "\n", lines.items[start..end]);
    }
    return null;
}

/// A group of the rules template: from the comment line starting with
/// `# NAME`, up to the next blank line.
fn groupOf(a: Allocator, text: []const u8, name: []const u8) !?[]const u8 {
    const at = std.mem.indexOf(u8, text, try std.fmt.allocPrint(a, "\n# {s}", .{name})) orelse return null;
    const from = at + 1;
    const end = std.mem.indexOfPos(u8, text, from, "\n\n") orelse text.len;
    return text[from..end];
}

/// The rules lines `/setup home` (or `/setup car`) adds: the home's (or
/// the car's) group of examples/butler/rules.
pub fn setupRules(a: Allocator, what: enum { home, car }) ![]const u8 {
    return (try groupOf(a, files.rules, if (what == .home) "the home:" else "the car:")).?;
}

/// mcp.ini's section for the home or the car: `prog` the program,
/// `file` its home or car file.
pub fn mcpSection(a: Allocator, what: enum { home, car }, prog: []const u8, file: []const u8) ![]const u8 {
    const section = (try sectionOf(a, files.mcp_ini, if (what == .home) "home" else "car")).?;
    var missing: []const u8 = "";
    return fill(a, section, &.{
        .{ .key = "homemcp", .value = prog },
        .{ .key = "home file", .value = file },
        .{ .key = "carcloud", .value = prog },
        .{ .key = "car file", .value = file },
    }, &.{}, &missing);
}

/// The values every routine's template may name, from `p`.
fn commonValues(a: Allocator, p: Picks) ![]Value {
    var v: std.ArrayList(Value) = .empty;
    try v.append(a, .{ .key = "goodnight at", .value = try clock(a, goodnightAt(p)) });
    try v.append(a, .{ .key = "morning at", .value = try clock(a, morningAt(p)) });
    try v.append(a, .{ .key = "car at", .value = try clock(a, carAt(p)) });
    try v.append(a, .{ .key = "night temp", .value = try std.fmt.allocPrint(a, "{d}", .{p.night_temp}) });
    try v.append(a, .{ .key = "away temp", .value = try std.fmt.allocPrint(a, "{d}", .{p.away_temp}) });
    try v.append(a, .{ .key = "home temp", .value = try std.fmt.allocPrint(a, "{d}", .{p.home_temp}) });
    if (p.lock) |l| {
        try v.append(a, .{ .key = "lock", .value = l.name });
        try v.append(a, .{ .key = "lock label", .value = try spoken(a, l.name) });
    }
    if (p.thermostat) |th| {
        try v.append(a, .{ .key = "thermostat", .value = th.name });
        try v.append(a, .{ .key = "thermostat label", .value = try spoken(a, th.name) });
    }
    if (p.valve) |va| {
        try v.append(a, .{ .key = "valve", .value = va.name });
        try v.append(a, .{ .key = "valve label", .value = try spoken(a, va.name) });
        try v.append(a, .{ .key = "valve action", .value = if (va.kind == .valve) "close" else "off" });
        try v.append(a, .{ .key = "valve words", .value = try std.fmt.allocPrint(a, ", and one tap closes the {s}", .{try spoken(a, va.name)}) });
    } else try v.append(a, .{ .key = "valve words", .value = "" });
    // goodnight's words
    try v.append(a, .{ .key = "night heating words", .value = if (p.thermostat != null) try std.fmt.allocPrint(a, ", the heating to {d} °C", .{p.night_temp}) else "" });
    try v.append(a, .{ .key = "night heating instruction", .value = if (p.thermostat) |th| try std.fmt.allocPrint(a, "Set the {s} (device {s}) to {d} °C.", .{ try spoken(a, th.name), th.name, p.night_temp }) else "" });
    try v.append(a, .{ .key = "night lock words", .value = if (p.lock) |l| try std.fmt.allocPrint(a, ", and one tap before the {s} is locked", .{try spoken(a, l.name)}) else "" });
    // leaving's
    var parts: std.ArrayList([]const u8) = .empty;
    if (p.lock) |l| try parts.append(a, try std.fmt.allocPrint(a, "locking the {s}", .{try spoken(a, l.name)}));
    if (p.thermostat != null) try parts.append(a, try std.fmt.allocPrint(a, "turning the heating down to {d} °C", .{p.away_temp}));
    try v.append(a, .{ .key = "leaving words", .value = if (parts.items.len > 0) try std.fmt.allocPrint(a, ", and asks with one tap before {s}", .{try andList(a, parts.items)}) else "" });
    // the morning summary's
    try v.append(a, .{ .key = "morning parts", .value = try morningParts(a, p, false) });
    var tools: std.ArrayList([]const u8) = .empty;
    try tools.append(a, "home/home_state");
    if (p.car) try tools.append(a, "car/car_status");
    if (p.search and p.town.len > 0) try tools.append(a, "search");
    if (p.calendar.len > 0) try tools.append(a, try std.fmt.allocPrint(a, "{s}/*", .{p.calendar}));
    try v.append(a, .{ .key = "morning tools", .value = try std.mem.join(a, ", ", tools.items) });
    // the start lines of the routines a trigger per sensor starts
    var leak_starts: std.ArrayList([]const u8) = .empty;
    for (p.leaks) |d| try leak_starts.append(a, try std.fmt.allocPrint(a, "trigger:{s}", .{try perSensorName(a, "leak-", d.name)}));
    try v.append(a, .{ .key = "leak starts", .value = try std.mem.join(a, ", ", leak_starts.items) });
    var door_starts: std.ArrayList([]const u8) = .empty;
    for (p.doors) |d| try door_starts.append(a, try std.fmt.allocPrint(a, "trigger:{s}", .{try perSensorName(a, "door-", d.name)}));
    try v.append(a, .{ .key = "door starts", .value = try std.mem.join(a, ", ", door_starts.items) });
    return v.items;
}

/// A trigger's name for a sensor: `prefix` and the device's name, at most
/// 64 bytes.
fn perSensorName(a: Allocator, prefix: []const u8, device: []const u8) ![]const u8 {
    const n = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, device });
    return n[0..@min(n.len, 64)];
}

/// The flags the templates' `#if` lines read.
fn flagsOf(a: Allocator, p: Picks) ![]const []const u8 {
    var f: std.ArrayList([]const u8) = .empty;
    if (p.lock != null) try f.append(a, "lock");
    if (p.valve != null) try f.append(a, "valve");
    if (p.thermostat != null) try f.append(a, "thermostat");
    if (p.car) try f.append(a, "car");
    return f.items;
}

/// Routine `r`'s files for the home and settings `p`, under a mark saying
/// setup added them on `date` ("2026-11-23").
pub fn routineFiles(a: Allocator, r: Routine, p: Picks, date: []const u8) !Files {
    const values = try commonValues(a, p);
    const flags = try flagsOf(a, p);
    var missing: []const u8 = "";
    // the template's own comment (how to fill it) goes; setup's mark comes instead
    const wf_tmpl = workflowTemplate(r);
    const head_end = std.mem.indexOf(u8, wf_tmpl, "\nworkflow ") orelse return error.NoSuchSection;
    const wf = try std.fmt.allocPrint(a, "# added by /setup routines {s}: the butler's {s} routine (harness/examples/butler)\n{s}", .{ date, r.title(), try fill(a, wf_tmpl[head_end + 1 ..], values, flags, &missing) });
    // its triggers.ini sections: those naming a sensor once for each
    var trig: std.ArrayList(u8) = .empty;
    for (triggerSections(r)) |sname| {
        const tmpl = (try sectionOf(a, files.triggers_ini, sname)) orelse return error.NoSuchSection;
        // the template's own comment goes; setup's mark comes instead
        const body = tmpl[(std.mem.indexOf(u8, tmpl, "[") orelse 0)..];
        const each: []const Device = if (std.mem.indexOf(u8, sname, "<leak>") != null) p.leaks else if (std.mem.indexOf(u8, sname, "<door>") != null) p.doors else &.{};
        if (each.len == 0) {
            try trig.print(a, "; added by /setup routines {s}: {s}\n{s}\n", .{ date, r.title(), try fill(a, body, values, flags, &missing) });
            continue;
        }
        for (each) |d| {
            var vs: std.ArrayList(Value) = .empty;
            try vs.appendSlice(a, values);
            const label = try capital(a, try plainWords(a, try spoken(a, d.name)));
            const room = try plainWords(a, d.room);
            try vs.append(a, .{ .key = "leak", .value = d.name });
            try vs.append(a, .{ .key = "door", .value = d.name });
            try vs.append(a, .{ .key = "door label", .value = label });
            try vs.append(a, .{ .key = "leak words", .value = if (room.len > 0) try std.fmt.allocPrint(a, "{s}, {s}", .{ label, room }) else label });
            var text = try fill(a, body, vs.items, flags, &missing);
            // the name at most 64 bytes, as the start line says it
            const prefix: []const u8 = if (std.mem.indexOf(u8, sname, "<leak>") != null) "leak-" else "door-";
            text = try std.mem.replaceOwned(u8, a, text, try std.fmt.allocPrint(a, "[{s}{s}]", .{ prefix, d.name }), try std.fmt.allocPrint(a, "[{s}]", .{try perSensorName(a, prefix, d.name)}));
            try trig.print(a, "; added by /setup routines {s}: {s}\n{s}\n", .{ date, r.title(), text });
        }
    }
    var rules: []const u8 = "";
    if (rulesGroup(r, p)) |g| {
        const tmpl = (try groupOf(a, files.rules, g)) orelse return error.NoSuchSection;
        const body = tmpl[(std.mem.indexOfScalar(u8, tmpl, '\n') orelse 0) + 1 ..];
        rules = try std.fmt.allocPrint(a, "# added by /setup routines {s}: {s}\n{s}\n", .{ date, r.title(), try fill(a, body, values, flags, &missing) });
        if (r == .@"morning-home" and p.calendar.len > 0 and !std.mem.eql(u8, p.calendar, "calendar"))
            rules = try std.mem.replaceOwned(u8, a, rules, "mcp calendar/", try std.fmt.allocPrint(a, "mcp {s}/", .{p.calendar}));
    }
    return .{ .workflow = wf, .triggers = trig.items, .rules = rules };
}

// ---- tests ----

const t = std.testing;
const workflows = @import("workflows.zig");
const triggers = @import("triggers.zig");

/// homemcp discover's file for homemcp-sim's flat (as it wrote it, its
/// port made 8123).
pub const sim_home =
    \\; Written by homemcp discover from Home Assistant at http://127.0.0.1:8123.
    \\; Read it through, then: homemcp check FILE
    \\
    \\[home]
    \\name = The flat (made up by homemcp-sim)
    \\hub = homeassistant
    \\url = http://127.0.0.1:8123
    \\
    \\[limits]
    \\temperature = 16 24
    \\brightness = 1 100
    \\
    \\; Living room
    \\
    \\[device living_room_light]
    \\id = light.living_room
    \\kind = light
    \\room = Living room
    \\alias = the big light
    \\allow = on, off, brightness
    \\
    \\[device living_room_temperature]
    \\id = sensor.living_room_temperature
    \\kind = sensor
    \\room = Living room
    \\
    \\; Kitchen
    \\
    \\[device kettle_plug]
    \\id = switch.kettle
    \\kind = plug
    \\room = Kitchen
    \\allow = on, off
    \\
    \\[device back_door]
    \\id = binary_sensor.back_door
    \\kind = sensor
    \\room = Kitchen
    \\
    \\[device water_main]
    \\id = valve.water_main
    \\kind = valve
    \\room = Kitchen
    \\allow = close
    \\
    \\[device kitchen_speaker]
    \\id = media_player.kitchen_speaker
    \\kind = media
    \\room = Kitchen
    \\allow = play, pause, volume
    \\
    \\[device sink_leak]
    \\id = binary_sensor.sink_leak
    \\kind = sensor
    \\room = Kitchen
    \\
    \\; Hall
    \\
    \\[device hall_thermostat]
    \\id = climate.hall
    \\kind = climate
    \\room = Hall
    \\allow = temperature, mode
    \\modes = off, heat, auto
    \\
    \\[device front_door]
    \\id = lock.front_door
    \\kind = lock
    \\room = Hall
    \\allow = lock
    \\
    \\[device hall_motion]
    \\id = binary_sensor.hall_motion
    \\kind = sensor
    \\room = Hall
    \\
    \\; Garage
    \\
    \\[device garage_door]
    \\id = cover.garage_door
    \\kind = cover
    \\room = Garage
    \\allow = close
    \\guarded = yes
    \\
    \\; Bedroom
    \\
    \\[device bedroom_lamp]
    \\id = light.bedroom_lamp
    \\kind = light
    \\room = Bedroom
    \\allow = on, off, brightness, color, color_temp
    \\
    \\[device ceiling_fan]
    \\id = fan.ceiling_fan
    \\kind = fan
    \\room = Bedroom
    \\allow = on, off, speed
    \\
    \\; No room
    \\
    \\[device evening]
    \\id = scene.evening
    \\kind = scene
    \\allow = activate
    \\
    \\[device leaving]
    \\id = scene.leaving
    \\kind = scene
    \\allow = activate
    \\guarded = yes
    \\note = it also sets lock.front_door, so it is asked about every time
    \\
    \\[people]                       ; who is home
    \\anna = person.anna
    \\ben = person.ben
    \\
    \\; Left out, and why:
    \\; cameras: never offered (homemcp has no camera support; what they see is personal)
    \\;   camera.front_door (Front door camera)
    \\; smoke, CO and gas detectors: left out; homemcp is not a safety system, so keep their own alarms
    \\;   binary_sensor.kitchen_smoke (Kitchen smoke alarm)
    \\; settings and diagnostics of devices (a child lock, a LED, a firmware update): not things to switch
    \\;   switch.kettle_child_lock (Kettle child lock)
    \\; kinds homemcp doesn't know (a light, switch or sensor among them can be added by hand)
    \\;   sun.sun (Sun)
    \\
;

/// homemcp check's lines for it.
pub const sim_check =
    \\The flat (made up by homemcp-sim): 15 devices in 5 rooms. Home Assistant at http://127.0.0.1:8123.
    \\Changes come in as they happen (Home Assistant's WebSocket API).
    \\Living room
    \\  living_room_light (light.living_room, light; also called: the big light): off; may: on, off, brightness
    \\  living_room_temperature (sensor.living_room_temperature, sensor): 21.5 °C; may: nothing (only seen)
    \\Kitchen
    \\  kettle_plug (switch.kettle, plug): off, 0 W; may: on, off
    \\  back_door (binary_sensor.back_door, sensor): closed; may: nothing (only seen)
    \\  water_main (valve.water_main, valve, guarded): open; may: close
    \\  kitchen_speaker (media_player.kitchen_speaker, media): idle, volume 20%; may: play, pause, volume
    \\  sink_leak (binary_sensor.sink_leak, sensor): dry; may: nothing (only seen)
    \\Hall
    \\  hall_thermostat (climate.hall, climate): 19.9 °C, set to 20 °C, mode heat, heating; may: temperature, mode
    \\  front_door (lock.front_door, lock, guarded): locked; may: lock
    \\  hall_motion (binary_sensor.hall_motion, sensor): nobody there; may: nothing (only seen)
    \\Garage
    \\  garage_door (cover.garage_door, cover, guarded): closed; may: close
    \\Bedroom
    \\  bedroom_lamp (light.bedroom_lamp, light): off; may: on, off, brightness, color, color_temp
    \\  ceiling_fan (fan.ceiling_fan, fan): off; may: on, off, speed
    \\No room
    \\  evening (scene.evening, scene): not run since Home Assistant started; may: activate
    \\  leaving (scene.leaving, scene, guarded): not run since Home Assistant started; may: activate
    \\People: anna (person.anna) is home, ben (person.ben) is away.
    \\
;

test "the_sims_home_reads" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try parseHome(a, sim_home);
    try t.expectEqualStrings("The flat (made up by homemcp-sim)", h.name);
    try t.expectEqualStrings("homeassistant", h.hub);
    try t.expectEqualStrings("http://127.0.0.1:8123", h.url);
    try t.expectEqual(15, h.devices.len);
    try t.expectEqual(5, h.rooms());
    try t.expectEqual(2, h.people.len);
    try t.expectEqualStrings("ben", h.people[1]);
    // what may act, what is guarded, what is only seen
    const light = h.find("the big light").?;
    try t.expectEqualStrings("living_room_light", light.name);
    try t.expect(light.acts());
    try t.expect(h.find("front_door").?.isGuarded() and !h.find("front_door").?.acts());
    try t.expect(h.find("Garage Door").?.isGuarded());
    try t.expect(h.find("water_main").?.isGuarded());
    try t.expect(h.find("leaving").?.isGuarded());
    try t.expect(!h.find("back_door").?.acts() and !h.find("back_door").?.isGuarded());
    try t.expectEqualStrings("it also sets lock.front_door, so it is asked about every time", h.find("leaving").?.note);
    // left out, with why
    try t.expectEqual(4, h.left.len);
    try t.expectEqualStrings("Front door camera", h.left[0].label);
    try t.expectEqual(Why.camera, h.left[0].why);
    try t.expectEqual(Why.safety, h.left[1].why);
    try t.expectEqualStrings("binary_sensor.kitchen_smoke", h.left[1].id);
    try t.expectEqual(Why.setting, h.left[2].why);
    try t.expectEqual(Why.unknown, h.left[3].why);
    // what check read of each
    readCheck(&h, sim_check);
    try t.expectEqualStrings("dry", h.find("sink_leak").?.state);
    try t.expectEqualStrings("closed", h.find("back_door").?.state);
    try t.expectEqualStrings("19.9 °C, set to 20 °C, mode heat, heating", h.find("hall_thermostat").?.state);
    try t.expect(h.find("sink_leak").?.leakSensor() and h.find("back_door").?.openingSensor());
    try t.expect(!h.find("hall_motion").?.leakSensor() and !h.find("hall_motion").?.openingSensor());
    try t.expect(!h.find("living_room_temperature").?.openingSensor());
    try t.expectEqualStrings("front door", try spoken(a, "front_door"));
}

/// The sim's home, read and checked, picked for with every setting on.
fn simPicks(a: Allocator, s: Settings) !Picks {
    var h = try parseHome(a, sim_home);
    readCheck(&h, sim_check);
    return pick(a, h, s);
}

test "routines_fill_from_the_sims_home" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try simPicks(a, .{ .car = true, .search = true, .calendar = "calendar", .quiet = .{ .start = 22 * 60, .end = 7 * 60 }, .town = "Kraków" });
    try t.expectEqual(2, p.lights);
    try t.expectEqualStrings("front_door", p.lock.?.name);
    try t.expectEqualStrings("water_main", p.valve.?.name);
    try t.expectEqualStrings("hall_thermostat", p.thermostat.?.name);
    try t.expectEqual(1, p.leaks.len);
    try t.expectEqual(1, p.doors.len);
    // every routine's files, together, read as harness reads them
    var trig_all: std.ArrayList(u8) = .empty;
    var wfs: std.ArrayList(workflows.Workflow) = .empty;
    var rules_all: std.ArrayList(u8) = .empty;
    for (all) |r| {
        try t.expect(r.offered(p));
        const f = try routineFiles(a, r, p, "2026-11-23");
        // no <…> left, no unlock, open or disarm, no camera or smoke
        for ([_][]const u8{ f.workflow, f.triggers, f.rules }) |text| {
            for ([_][]const u8{ "\"action\": \"unlock\"", "\"action\": \"open\"", "disarm", "camera", "smoke", "#if", "#end" }) |bad| if (std.mem.indexOf(u8, text, bad) != null) {
                std.debug.print("{s} in {s}:\n{s}\n", .{ bad, r.name(), text });
                return error.TestUnexpectedResult;
            };
        }
        var d: workflows.Diag = .{};
        const w = workflows.parse(a, r.name(), f.workflow, &d) catch |e| {
            std.debug.print("{s}: {s}\n", .{ try workflows.lineProblem(a, r.name(), f.workflow, d), f.workflow });
            return e;
        };
        // a guarded call only right after an approve with yes
        for (w.steps, 0..) |s, i| if (s.action == .tool and std.mem.indexOf(u8, s.action.tool.name, "home_guarded") != null) {
            try t.expect(i > 0 and w.steps[i - 1].action == .approve and w.steps[i - 1].yes.len > 0);
        };
        try wfs.append(a, w);
        try trig_all.appendSlice(a, f.triggers);
        try rules_all.appendSlice(a, f.rules);
    }
    var td: triggers.Diag = .{};
    const tlist = triggers.parse(a, trig_all.items, .triggers, &td) catch |e| {
        std.debug.print("line {d}: {s}\n{s}\n", .{ td.line, td.why, trig_all.items });
        return e;
    };
    try t.expectEqual(7, tlist.len);
    for (wfs.items) |w| {
        var d: workflows.Diag = .{};
        _ = workflows.check(a, w, .{ .triggers = tlist }, &d) catch |e| {
            std.debug.print("{s}: line {d}: {s}\n", .{ w.name, d.line, d.why });
            return e;
        };
    }
    // the rules lines read as rules
    _ = try @import("rules.zig").parse(a, rules_all.items);
    try t.expect(std.mem.indexOf(u8, rules_all.items, "[workflow:arriving/heat]\nallow mcp home/home_set {\"device\":\"hall_thermostat\",\"action\":\"temperature\",\"value\":\"21\"}") != null);
    // what the files say, filled
    const gn = try routineFiles(a, .goodnight, p, "2026-11-23");
    try t.expect(std.mem.indexOf(u8, gn.workflow, "about When you say goodnight (or at 21:45): the lights off, the heating to 18 °C, and one tap before the front door is locked.") != null);
    try t.expect(std.mem.indexOf(u8, gn.workflow, "approve The front door is unlocked.\nyes Lock it\nno Leave it") != null);
    try t.expectEqualStrings("; added by /setup routines 2026-11-23: Goodnight\n[goodnight-at]\nat = 21:45\nstart = workflow goodnight\n", gn.triggers);
    const lk = try routineFiles(a, .leak, p, "2026-11-23");
    try t.expect(std.mem.indexOf(u8, lk.triggers, "[leak-sink_leak]\nmcp = home resource home://device/sink_leak\nmatch = to has leak\nstart = workflow leak Sink leak, Kitchen\nurgent = yes") != null);
    try t.expect(std.mem.indexOf(u8, lk.workflow, "yes Close the water main") != null);
    try t.expect(std.mem.indexOf(u8, lk.workflow, "tool home/home_guarded {\"device\": \"water_main\", \"action\": \"close\"}") != null);
    const mh = try routineFiles(a, .@"morning-home", p, "2026-11-23");
    try t.expect(std.mem.indexOf(u8, mh.workflow, "tools home/home_state, car/car_status, search, calendar/*") != null);
    try t.expect(std.mem.indexOf(u8, mh.workflow, "Read the car, today's calendar, the weather in Kraków and the house") != null);
    // the sentences setup offers them with
    try t.expectEqualStrings("Goodnight: when you say goodnight, or at 21:45, I switch off the lights, set the heating to 18 °C and ask with one tap before locking the front door.", try Routine.goodnight.sentence(a, p));
    try t.expectEqualStrings("Leak: when the sink leak finds water, I tell you at once, even at night, and one tap closes the water main.", try Routine.leak.sentence(a, p));
    try t.expectEqualStrings("Doors left open: when the back door stays open for 10 minutes, I tell you.", try Routine.@"door-open".sentence(a, p));
}

test "a_routine_whose_devices_are_missing_is_not_offered" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a home of two lamps and a leak sensor, no lock, valve, heating or people
    const h = try parseHome(a, "[home]\nname = Flat\nhub = zigbee2mqtt\nmqtt = 127.0.0.1:1883\n[device lamp]\nid = Lamp\nkind = light\nallow = on, off\n[device desk_lamp]\nid = Desk lamp\nkind = light\nallow = on, off\n[device washer_leak]\nid = Washer leak\nkind = sensor\n");
    const p = try pick(a, h, .{});
    try t.expect(Routine.goodnight.offered(p));
    try t.expect(!Routine.leaving.offered(p));
    try t.expect(!Routine.arriving.offered(p));
    try t.expect(Routine.@"morning-home".offered(p));
    try t.expect(Routine.leak.offered(p));
    try t.expect(!Routine.@"door-open".offered(p));
    try t.expect(!Routine.@"car-tomorrow".offered(p));
    // goodnight without a lock or heating: lights only, no question
    const gn = try routineFiles(a, .goodnight, p, "2026-11-23");
    var d: workflows.Diag = .{};
    const w = try workflows.parse(a, "goodnight", gn.workflow, &d);
    for (w.steps) |s| try t.expect(s.action != .approve);
    try t.expectEqualStrings("Goodnight: when you say goodnight, or at 22:00, I switch off the lights.", try Routine.goodnight.sentence(a, p));
    // a leak with no valve: said at once, nothing to close
    const lk = try routineFiles(a, .leak, p, "2026-11-23");
    const lw = try workflows.parse(a, "leak", lk.workflow, &d);
    for (lw.steps) |s| try t.expect(s.action != .tool);
    try t.expectEqualStrings("Leak: when the washer leak finds water, I tell you at once, even at night.", try Routine.leak.sentence(a, p));
    // a placeholder nothing fills is an error, naming it
    var missing: []const u8 = "";
    try t.expectError(error.UnknownPlaceholder, fill(a, "say <lock label>", &.{}, &.{}, &missing));
    try t.expectEqualStrings("lock label", missing);
    try t.expectError(error.UnbalancedIf, fill(a, "#if lock\nsay x", &.{}, &.{}, &missing));
    // a comparison is no placeholder
    try t.expectEqualStrings("if x < 3 goto y", try fill(a, "if x < 3 goto y", &.{}, &.{}, &missing));
}

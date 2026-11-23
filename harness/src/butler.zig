//! The butler: a home file as homemcp writes it, read in harness's words
//! (devices, rooms, people, what discover left out, what `homemcp check`
//! reads of each), the devices a routine needs, and the routines of
//! `examples/butler/` filled with them. Pure: no I/O.
const std = @import("std");
const files = @import("butler_files");
const config = @import("config.zig");
const util = @import("util.zig");
const alerts = @import("alerts.zig");
const Allocator = std.mem.Allocator;

/// What a device is, as the home file says it (`kind =`); `smoke`: a
/// smoke, CO or gas alarm, only watched.
pub const Kind = enum { light, @"switch", plug, climate, cover, fan, scene, media, lock, alarm, valve, sensor, smoke, other };

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

// ---- setup's summary and the owner's changes ----

/// A kind's word in the summary's "I'll switch …" line.
fn kindWord(k: Kind) []const u8 {
    return switch (k) {
        .light => "lights",
        .plug => "plugs",
        .@"switch" => "switches",
        .climate => "the heating",
        .cover => "blinds",
        .fan => "fans",
        .media => "speakers",
        .scene => "scenes",
        else => "other devices",
    };
}

/// "the front door", "the leaving scene".
fn theName(a: Allocator, d: Device) ![]const u8 {
    return std.fmt.allocPrint(a, "the {s}{s}", .{ try spoken(a, d.name), if (d.kind == .scene) " scene" else "" });
}

/// "a, b and c" of at most `max` names, else "N things".
fn someNames(a: Allocator, names: []const []const u8, max: usize, joiner: enum { @"and", @"or" }) ![]const u8 {
    if (names.len > max) return std.fmt.allocPrint(a, "{d} of them (/setup home shows the file)", .{names.len});
    return if (joiner == .@"and") andList(a, names) else orList(a, names);
}

/// What setup says of a home before it writes the file: what harness will
/// switch when asked, what it asks about every time, what it won't touch,
/// what it watches, and what the owner should sort (switches it couldn't
/// identify, plugs that may power a heater).
pub fn homeSummary(a: Allocator, h: Home) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const n = h.devices.len;
    try o.print(a, "I found {d} device{s}", .{ n, if (n == 1) "" else "s" });
    const r = h.rooms();
    if (r > 0) try o.print(a, " in {d} room{s}", .{ r, if (r == 1) "" else "s" });
    if (h.people.len > 0) try o.print(a, ", and {d} {s}", .{ h.people.len, if (h.people.len == 1) "person" else "people" });
    try o.appendSlice(a, ".");
    // what acts when asked, by kind, in this order
    var kinds: std.ArrayList([]const u8) = .empty;
    for ([_]Kind{ .light, .plug, .@"switch", .climate, .cover, .fan, .media, .scene }) |k| {
        for (h.devices) |d| if (d.kind == k and d.acts()) {
            try kinds.append(a, kindWord(k));
            break;
        };
    }
    if (kinds.items.len > 0) try o.print(a, "\nI'll switch {s} when you ask.", .{try andList(a, kinds.items)});
    // guarded, with something allowed: asked every time
    var guarded: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var unknown_names: std.ArrayList([]const u8) = .empty;
    var idle: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var smokes: std.ArrayList([]const u8) = .empty;
    var plugs: std.ArrayList(Device) = .empty;
    for (h.devices) |d| {
        if (d.unidentified()) {
            try unknown.append(a, try theName(a, d));
            try unknown_names.append(a, d.name);
        } else if (d.isGuarded() and d.allow.len > 0) {
            try guarded.append(a, try theName(a, d));
        } else if (d.isGuarded()) {
            try idle.append(a, try std.fmt.allocPrint(a, "{s} (it may do nothing yet)", .{try theName(a, d)}));
        } else if (d.kind == .smoke) {
            // watched for its routine, and never touched
            try smokes.append(a, try theName(a, d));
        } else if (d.allow.len == 0) {
            try seen.append(a, try theName(a, d));
        }
        if (d.kind == .plug and d.acts()) try plugs.append(a, d);
    }
    if (guarded.items.len > 0) try o.print(a, "\nI'll ask you every time before {s}.", .{try someNames(a, guarded.items, 6, .@"and")});
    // never touched: cameras, smoke and CO alarms discover left out, and
    // guarded devices that may do nothing
    var never: std.ArrayList([]const u8) = .empty;
    for (h.left) |l| if (l.why == .camera or l.why == .safety) try never.append(a, try std.fmt.allocPrint(a, "the {s}", .{try lowerFirst(a, l.label)}));
    try never.appendSlice(a, smokes.items);
    try never.appendSlice(a, idle.items);
    if (never.items.len > 0) try o.print(a, "\nI won't touch {s}.", .{try someNames(a, never.items, 6, .@"or")});
    if (seen.items.len > 0) try o.print(a, "\nI'll watch {s}.", .{try someNames(a, seen.items, 6, .@"and")});
    if (unknown.items.len == 1) {
        try o.print(a, "\nI couldn't tell what {s} controls: I'll ask you before switching it until you sort it. If it's a light or a plug, send /setup home allow {s}.", .{ unknown.items[0], unknown_names.items[0] });
    } else if (unknown.items.len > 1) {
        try o.print(a, "\nI couldn't tell what {d} switches control ({s}): I'll ask you before switching them until you sort them. For a light or a plug, send /setup home allow NAME.", .{ unknown.items.len, try andList(a, unknown.items) });
    }
    if (plugs.items.len == 1) {
        try o.print(a, "\nIf {s} powers a kettle or a heater, send /setup home ask {s} and I'll ask you first.", .{ try theName(a, plugs.items[0]), plugs.items[0].name });
    } else if (plugs.items.len > 1) try o.appendSlice(a, "\nIf a plug powers a kettle or a heater, send /setup home ask NAME and I'll ask you first.");
    return o.items;
}

fn lowerFirst(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len > 0) out[0] = std.ascii.toLower(out[0]);
    return out;
}

/// What setup says of the car, from `carcloud check`'s lines.
pub fn carSummary(a: Allocator, check_out: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var age: []const u8 = "";
    var it = std.mem.splitScalar(u8, check_out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const key = line[0..colon];
        const v = line[colon + 2 ..];
        const eql = std.mem.eql;
        if (eql(u8, key, "battery")) try parts.append(a, try std.fmt.allocPrint(a, "battery {s} %", .{std.mem.trimEnd(u8, v, "%")}));
        if (eql(u8, key, "range")) {
            const km = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, v, " km")) catch null;
            try parts.append(a, if (km) |x| try std.fmt.allocPrint(a, "range {d} km", .{@as(i64, @intFromFloat(@round(x)))}) else try std.fmt.allocPrint(a, "range {s}", .{v}));
        }
        if (eql(u8, key, "plugged in")) try parts.append(a, if (eql(u8, v, "yes")) "plugged in" else "not plugged in");
        if (eql(u8, key, "charging")) try parts.append(a, if (eql(u8, v, "yes")) "charging" else "not charging");
        if (eql(u8, key, "charge limit")) try parts.append(a, try std.fmt.allocPrint(a, "charge limit {s} %", .{std.mem.trimEnd(u8, v, "%")}));
        if (eql(u8, key, "data")) age = v;
    }
    // the order a person says it in: battery, range, plug, charging, limit
    var ordered: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "battery", "range", "plugged", "not plugged", "charging", "not charging", "charge limit" }) |w| for (parts.items) |p| if (std.mem.startsWith(u8, p, w) and !(std.mem.eql(u8, w, "charging") and std.mem.startsWith(u8, p, "charge"))) {
        var dup = false;
        for (ordered.items) |q| if (std.mem.eql(u8, q, p)) {
            dup = true;
        };
        if (!dup) try ordered.append(a, p);
    };
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "The car answers: {s}", .{try std.mem.join(a, ", ", ordered.items)});
    if (age.len > 0) try o.print(a, " (data {s})", .{age});
    try o.appendSlice(a, ".\nI'll read it, and start or stop charging and set the charge limit (60–90 %) when you ask. I won't lock or unlock it: car.ini doesn't list them.");
    return o.items;
}

/// A home file's lines, split for editing.
fn linesOf(a: Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(a, l);
    return out;
}

/// Where device `name`'s section is: its header's line, and the line
/// after its last key line.
const Span = struct { head: usize, end: usize };

fn spanOf(lines: []const []const u8, name: []const u8) ?Span {
    for (lines, 0..) |l, i| {
        const tl = std.mem.trim(u8, stripComment(l), " \t\r");
        if (!std.mem.startsWith(u8, tl, "[device ") or !std.mem.endsWith(u8, tl, "]")) continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, tl["[device ".len .. tl.len - 1], " \t"), name)) continue;
        var end = i + 1;
        var last = i + 1;
        while (end < lines.len) : (end += 1) {
            const x = std.mem.trim(u8, lines[end], " \t\r");
            if (x.len > 0 and x[0] == '[') break;
            if (x.len > 0 and x[0] != ';' and x[0] != '#') last = end + 1;
        }
        return .{ .head = i, .end = last };
    }
    return null;
}

/// The section's lines without `key = …`.
fn dropKey(a: Allocator, lines: *std.ArrayList([]const u8), span: *Span, key: []const u8) void {
    _ = a;
    var i = span.head + 1;
    while (i < span.end) {
        const tl = std.mem.trim(u8, lines.items[i], " \t\r");
        const eq = std.mem.indexOfScalar(u8, tl, '=');
        if (eq != null and std.mem.eql(u8, std.mem.trim(u8, tl[0..eq.?], " \t"), key)) {
            _ = lines.orderedRemove(i);
            span.end -= 1;
            continue;
        }
        i += 1;
    }
}

/// Switches discover gave on and off but could not identify (a plain
/// switch, no valve or opener in its name): guarded until the owner sorts
/// them, with a note saying so (the follow-up of homemcp's discover: a
/// misnamed valve on a plain switch would otherwise act like a plug).
pub fn markUnidentified(a: Allocator, text: []const u8) ![]const u8 {
    const h = try parseHome(a, text);
    var lines = try linesOf(a, text);
    for (h.devices) |d| {
        if (d.kind != .@"switch" or d.guarded or d.note.len > 0 or d.allow.len == 0) continue;
        var span = spanOf(lines.items, d.name) orelse continue;
        dropKey(a, &lines, &span, "guarded");
        try lines.insertSlice(a, span.end, &.{ "guarded = yes", "note = " ++ unidentified_note });
    }
    return std.mem.join(a, "\n", lines.items);
}

/// What the owner sorted at setup before, kept over a new discover: a
/// device left out stays out; a switch let act, or one asked every time,
/// stays so.
pub fn carryOver(a: Allocator, fresh: []const u8, live: []const u8) ![]const u8 {
    var text = fresh;
    // left out at setup: "; left out at /setup: NAME (ID)"
    var it = std.mem.splitScalar(u8, live, '\n');
    while (it.next()) |l| {
        const mark = "; left out at /setup: ";
        if (!std.mem.startsWith(u8, l, mark)) continue;
        const rest = l[mark.len..];
        const name = rest[0 .. std.mem.indexOf(u8, rest, " (") orelse rest.len];
        const e = try editHome(a, text, .leave, name);
        if (!e.refused) text = e.text;
    }
    const old = try parseHome(a, live);
    const now = try parseHome(a, text);
    for (now.devices) |d| {
        const was = old.find(d.name) orelse continue;
        if (std.mem.eql(u8, was.name, d.name) and was.kind == d.kind) {
            // let act at setup, or asked every time at setup
            if (d.unidentified() and !was.isGuarded() and !was.unidentified()) {
                const e = try editHome(a, text, .allow, d.name);
                if (!e.refused) text = e.text;
            } else if (!d.isGuarded() and was.guarded and !was.unidentified()) {
                const e = try editHome(a, text, .ask, d.name);
                if (!e.refused) text = e.text;
            }
        }
    }
    return text;
}

pub const Op = enum { leave, ask, allow };

/// What came of a change: the file (as it was, when refused) and what to
/// say.
pub const Edited = struct { text: []const u8, said: []const u8, refused: bool = false };

/// `/setup home leave|ask|allow NAME` on the pending home file: leave it
/// out; ask every time (`guarded = yes`); or let it act when asked (not a
/// lock, an alarm, a valve, a garage door, a gate or a scene that sets one:
/// those are asked every time).
pub fn editHome(a: Allocator, text: []const u8, op: Op, name: []const u8) !Edited {
    const h = try parseHome(a, text);
    const d = (h.find(name) orelse return .{ .text = text, .said = try std.fmt.allocPrint(a, "No device called {s} in the home file.", .{name}), .refused = true }).*;
    const the = try capital(a, try theName(a, d));
    var lines = try linesOf(a, text);
    var span = spanOf(lines.items, d.name) orelse return .{ .text = text, .said = "That device's section can't be found.", .refused = true };
    switch (op) {
        .leave => {
            // its lines, and the blank line after them
            var end = span.end;
            if (end < lines.items.len and std.mem.trim(u8, lines.items[end], " \t\r").len == 0) end += 1;
            try lines.replaceRange(a, span.head, end - span.head, &.{});
            if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
            try lines.append(a, try std.fmt.allocPrint(a, "; left out at /setup: {s} ({s})", .{ d.name, d.id }));
            try lines.append(a, "");
            return .{ .text = try std.mem.join(a, "\n", lines.items), .said = try std.fmt.allocPrint(a, "Left out: {s}.", .{try theName(a, d)}) };
        },
        .ask => {
            if (d.kind == .sensor or d.allow.len == 0) return .{ .text = text, .said = try std.fmt.allocPrint(a, "{s} is a sensor: it is only seen, never switched.", .{the}), .refused = true };
            dropKey(a, &lines, &span, "guarded");
            try lines.insert(a, span.end, "guarded = yes");
            return .{ .text = try std.mem.join(a, "\n", lines.items), .said = try std.fmt.allocPrint(a, "{s}: I'll ask you every time.", .{the}) };
        },
        .allow => {
            const opener = std.mem.startsWith(u8, d.note, "by its name it opens");
            const always = d.kind == .lock or d.kind == .alarm or d.kind == .valve or d.valveSwitch() or opener or (d.kind == .cover and d.guarded) or (d.kind == .scene and d.guarded);
            if (always) return .{ .text = text, .said = try std.fmt.allocPrint(a, "{s} stays asked every time: locks, alarms, valves, garage doors, gates and scenes that set them always are.", .{the}), .refused = true };
            if (d.allow.len == 0) return .{ .text = text, .said = try std.fmt.allocPrint(a, "{s} may do nothing: it is only seen.", .{the}), .refused = true };
            dropKey(a, &lines, &span, "guarded");
            if (d.unidentified()) dropKey(a, &lines, &span, "note");
            return .{ .text = try std.mem.join(a, "\n", lines.items), .said = try std.fmt.allocPrint(a, "{s}: I'll switch it when you ask.", .{the}) };
        },
    }
}

/// Whether `s` reads as a token pasted where an address or a name was
/// asked for: one long word of letters, digits and `._-` (a JWT, an API
/// key), or a masked secret.
pub fn looksLikeToken(s_in: []const u8) bool {
    const s = std.mem.trim(u8, s_in, " \t\r\n");
    if (std.mem.indexOf(u8, s, "[secret:") != null) return true;
    if (s.len < 24 or std.mem.indexOf(u8, s, "://") != null) return false;
    var letters: usize = 0;
    var digits: usize = 0;
    for (s) |ch| {
        if (std.ascii.isAlphabetic(ch)) letters += 1 else if (std.ascii.isDigit(ch)) digits += 1 else if (ch != '.' and ch != '_' and ch != '-') return false;
    }
    return letters > 0 and digits > 0;
}

/// Whether any word of `text` reads as a token (`looksLikeToken`).
pub fn anyTokenLike(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| if (looksLikeToken(w)) return true;
    return false;
}

/// Whether one of `/setup car`'s ids reads as one: letters, digits, `-`
/// and `_`, up to 80.
pub fn plainId(s: []const u8) bool {
    if (s.len == 0 or s.len > 80) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// The car file `/setup car` writes for carcloud: charging and the charge
/// limit only (no lock, no unlock: rules lets the owner's requests act on
/// what this lists, see examples/butler/rules); `api`: another Smartcar
/// address (carcloud-sim's), "" for Smartcar's own.
pub fn carFile(a: Allocator, client: []const u8, vehicle: []const u8, user: []const u8, api: []const u8, date: []const u8, log_path: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "; Written by /setup car {s}: the car, for carcloud (its README: The car file).\n; Its secret is the stored secret smartcar (mcp.ini passes it as\n; SMARTCAR_CLIENT_SECRET). allow lists what harness may ask the car to do:\n; nothing else is sent, and unlock never is.\n\n[car]\nname = The car\nvehicle_id = {s}\nuser_id = {s}\nclient_id = {s}\nallow = charge_start, charge_stop, charge_limit\ncharge_limit = 60 90\ncommands_per_day = 10\nmin_seconds_between = 60\nlocation = no\nlog = {s}\n", .{ date, vehicle, user, client, log_path });
    if (api.len > 0) {
        const base = std.mem.trimEnd(u8, api, "/");
        try o.print(a, "; another Smartcar (carcloud-sim's, for trying without a car)\napi = {s}/v3\ntoken_url = {s}/oauth2/token\n", .{ base, base });
    }
    return o.items;
}

/// Section `name` of an INI text gone: its header, its lines, and the
/// comment lines just above it (its mark).
pub fn dropSection(a: Allocator, text: []const u8, name: []const u8) ![]const u8 {
    var lines = try linesOf(a, text);
    const header = try std.fmt.allocPrint(a, "[{s}]", .{name});
    for (lines.items, 0..) |l, i| {
        if (!std.mem.eql(u8, std.mem.trim(u8, stripComment(l), " \t\r"), header)) continue;
        var start = i;
        while (start > 0 and std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[start - 1], " \t"), ";")) start -= 1;
        var end = i + 1;
        while (end < lines.items.len) : (end += 1) {
            const x = std.mem.trim(u8, lines.items[end], " \t\r");
            if (x.len > 0 and x[0] == '[') break;
            if (x.len > 0 and x[0] == ';') {
                // a comment that belongs to the next section
                var k = end;
                while (k < lines.items.len and std.mem.trim(u8, lines.items[k], " \t\r").len > 0 and std.mem.trim(u8, lines.items[k], " \t\r")[0] == ';') k += 1;
                if (k < lines.items.len and std.mem.trim(u8, lines.items[k], " \t\r").len > 0 and std.mem.trim(u8, lines.items[k], " \t\r")[0] == '[') break;
            }
        }
        // the blank lines it leaves
        while (end < lines.items.len and std.mem.trim(u8, lines.items[end], " \t\r").len == 0) end += 1;
        try lines.replaceRange(a, start, end - start, &.{});
        return std.mem.join(a, "\n", lines.items);
    }
    return error.NotFound;
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
    /// The car server has car_climate (a Tesla through carcloud).
    car_warms: bool = false,
    /// `[butler] warm_below`, °C.
    warm_below: f64 = 5,
    /// Search is set up: the morning summary can say the weather.
    search: bool = false,
    /// An MCP server whose name has "calendar"; "": none.
    calendar: []const u8 = "",
    /// Quiet hours, the owner's: the routines' times come from them.
    quiet: ?config.Quiet = null,
    /// Where the weather is read for; "": none said.
    town: []const u8 = "",
    /// The owner's mailbox is on (/setup mail mine): the Post, bills,
    /// deliveries, flights and invitations.
    mail: bool = false,
    night_temp: u16 = 18,
    away_temp: u16 = 17,
    home_temp: u16 = 21,
    /// The leak's question closes the water main itself when nobody is on
    /// it in 5 minutes (the owner turned it on).
    fallback: bool = false,
    /// Smoke, CO and gas alarms (only watched).
    smokes: []const Device = &.{},
    /// A speaker may announce: urgent routines are said aloud.
    speakers: bool = false,
    /// `[butler] escalate`: who is told when the owner doesn't answer.
    escalate: []const alerts.Step = &.{},
};

pub const Settings = struct { car: bool = false, search: bool = false, calendar: []const u8 = "", quiet: ?config.Quiet = null, town: []const u8 = "", fallback: bool = false, escalate: []const alerts.Step = &.{}, mail: bool = false, car_warms: bool = false, warm_below: f64 = 5 };

/// The devices and settings the routines use: every light; the first
/// thermostat; the first lock (a front one first); the water main (a
/// valve, else a switch named one); every leak sensor; every door and
/// window sensor.
pub fn pick(a: Allocator, h: Home, s: Settings) !Picks {
    var p: Picks = .{ .people = h.people.len > 0, .car = s.car, .search = s.search, .calendar = s.calendar, .quiet = s.quiet, .town = s.town, .fallback = s.fallback, .escalate = s.escalate, .mail = s.mail, .car_warms = s.car and s.car_warms, .warm_below = s.warm_below };
    var leaks: std.ArrayList(Device) = .empty;
    var doors: std.ArrayList(Device) = .empty;
    var smokes: std.ArrayList(Device) = .empty;
    for (h.devices) |d| {
        if (d.allows("announce")) p.speakers = true;
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
            .smoke => try smokes.append(a, d),
            else => {},
        }
    }
    p.smokes = smokes.items;
    if (p.valve == null) for (h.devices) |d| if (d.valveSwitch() and d.allows("off")) {
        p.valve = d;
        break;
    };
    p.leaks = leaks.items;
    p.doors = doors.items;
    return p;
}

/// "5", "-2.5": degrees as said.
fn degrees(a: Allocator, x: f64) ![]const u8 {
    if (@abs(x - @round(x)) < 1e-9) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@round(x)))});
    return std.fmt.allocPrint(a, "{d:.1}", .{x});
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
    smoke,
    @"door-open",
    @"car-tomorrow",
    @"warm-car",
    bill,
    delivery,
    flight,
    invitation,

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
            .smoke => "Smoke alarm",
            .@"door-open" => "Doors left open",
            .@"car-tomorrow" => "Car for tomorrow",
            .@"warm-car" => "Warm the car",
            .bill => "Bills",
            .delivery => "Deliveries",
            .flight => "Flights",
            .invitation => "Invitations",
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
            .smoke => p.smokes.len > 0,
            .@"door-open" => p.doors.len > 0,
            .@"car-tomorrow" => p.car,
            // the leave-by is the diary's: a calendar, and a car that warms
            .@"warm-car" => p.car_warms and p.calendar.len > 0,
            .bill, .delivery => p.mail,
            // the calendar's own tools add the entry: only with one set
            .flight, .invitation => p.mail and p.calendar.len > 0,
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
            .smoke => {
                try o.print(a, "Smoke alarm: when {s} goes off, I tell you at once, even at night", .{try sensorList(a, p.smokes, "a smoke or CO alarm")});
                if (p.speakers) try o.appendSlice(a, ", and say it on every speaker");
                try o.append(a, '.');
                if (p.escalate.len > 0) {
                    const m = p.escalate[0].after_s / 60;
                    try o.print(a, " If you don't answer in {d} minute{s}, I tell ", .{ m, if (m == 1) "" else "s" });
                    for (p.escalate, 0..) |st, i| try o.print(a, "{s}{s}", .{ if (i > 0) ", then " else "", try capital(a, st.member) });
                    try o.append(a, '.');
                }
            },
            .@"door-open" => try o.print(a, "Doors left open: when {s} stays open for 10 minutes, I tell you.", .{try sensorList(a, p.doors, "a door or window")}),
            .@"car-tomorrow" => try o.print(a, "Car for tomorrow: at {s}, when the car is under half, I tell you, and ask with one tap to start charging when it's plugged in.", .{try clock(a, carAt(p))}),
            .@"warm-car" => try o.print(a, "Warm the car: 30 minutes before you leave for a morning event in your calendar, when it's below {s} °C at the car, I ask \"Warm the car for 8:10?\" and one tap warms it.", .{try degrees(a, p.warm_below)}),
            .bill => try o.appendSlice(a, "Bills: 3 days before a bill in your mail is due, I tell you who, how much and when."),
            .delivery => try o.appendSlice(a, "Deliveries: on the day a parcel comes, one line with what and from whom."),
            .flight => {
                try o.appendSlice(a, "Flights: when a flight confirmation comes, I offer its time for the calendar (you're asked first)");
                if (p.people) try o.appendSlice(a, ", and the house goes to away when you've all left for it");
                try o.append(a, '.');
            },
            .invitation => try o.appendSlice(a, "Invitations: when an invitation comes, I offer it for the calendar (you're asked first)."),
        }
        return o.items;
    }
};

/// What is said once routine `r` is on: how to try it, or when it runs.
pub fn onText(a: Allocator, r: Routine, p: Picks) ![]const u8 {
    return switch (r) {
        .goodnight => "Goodnight is on: write goodnight to try it.",
        .leaving => "Leaving is on: it runs when the last of you goes out.",
        .arriving => "Arriving is on: it runs when the first of you comes home.",
        .@"morning-home" => std.fmt.allocPrint(a, "The morning summary is on, at {s}. /workflow start morning-home tries it now.", .{try clock(a, morningAt(p))}),
        .leak => "Leak is on: it comes through quiet hours.",
        .smoke => "Smoke alarm is on: it comes through quiet hours.",
        .@"door-open" => "Doors left open is on.",
        .@"car-tomorrow" => std.fmt.allocPrint(a, "Car for tomorrow is on, at {s}. /workflow start car-tomorrow tries it now.", .{try clock(a, carAt(p))}),
        .@"warm-car" => std.fmt.allocPrint(a, "Warm the car is on: before a morning leave-by when it's below {s} °C at the car; it wakes the car once to read it.", .{try degrees(a, p.warm_below)}),
        .bill => "Bill reminders are on.",
        .delivery => "Delivery lines are on.",
        .flight => "Flights are on.",
        .invitation => "Invitations are on.",
    };
}

/// The routines in the order setup offers them.
pub const all = [_]Routine{ .goodnight, .leaving, .arriving, .@"morning-home", .leak, .smoke, .@"door-open", .@"car-tomorrow", .@"warm-car", .bill, .delivery, .flight, .invitation };

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
    if (p.calendar.len > 0) try parts.append(a, if (tools) try std.fmt.allocPrint(a, "today's calendar ({s}/cal_agenda)", .{p.calendar}) else "today's calendar");
    if (p.search and p.town.len > 0) try parts.append(a, if (tools) try std.fmt.allocPrint(a, "today's weather in {s} (search)", .{p.town}) else try std.fmt.allocPrint(a, "the weather in {s}", .{p.town}));
    try parts.append(a, if (tools) "the house (home/home_state)" else "the house");
    if (p.mail) try parts.append(a, if (tools) "the post (mail/mail_list)" else "the post");
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
pub fn fill(a: Allocator, template_in: []const u8, values: []const Value, flags: []const []const u8, missing: *[]const u8) FillError![]const u8 {
    // a checkout made on Windows may end its lines with \r\n: read as \n
    const template = if (std.mem.indexOf(u8, template_in, "\r\n") == null) template_in else try std.mem.replaceOwned(u8, a, template_in, "\r\n", "\n");
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
        .smoke => &.{"smoke-<smoke>"},
        .@"door-open" => &.{"door-<door>"},
        .@"car-tomorrow" => &.{"car-evening"},
        // harness starts it itself, before the diary's leave-by
        .@"warm-car" => &.{},
        .bill => &.{"bill-due"},
        .delivery => &.{"delivery-today"},
        .flight => &.{"flight-mail"},
        .invitation => &.{"invitation-mail"},
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
    try v.append(a, .{ .key = "warm below", .value = try degrees(a, p.warm_below) });
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
    // the calendar is read, never changed: its changes are not offered to a scheduled step
    if (p.calendar.len > 0) try tools.append(a, try std.fmt.allocPrint(a, "{s}/cal_agenda", .{p.calendar}));
    if (p.mail) try tools.append(a, "mail/mail_list, mail/mail_read");
    try v.append(a, .{ .key = "morning tools", .value = try std.mem.join(a, ", ", tools.items) });
    // the calendar the flight and invitation routines add to
    try v.append(a, .{ .key = "calendar", .value = if (p.calendar.len > 0) p.calendar else "calendar" });
    // the start lines of the routines a trigger per sensor starts
    var leak_starts: std.ArrayList([]const u8) = .empty;
    for (p.leaks) |d| try leak_starts.append(a, try std.fmt.allocPrint(a, "trigger:{s}", .{try perSensorName(a, "leak-", d.name)}));
    try v.append(a, .{ .key = "leak starts", .value = try std.mem.join(a, ", ", leak_starts.items) });
    var door_starts: std.ArrayList([]const u8) = .empty;
    for (p.doors) |d| try door_starts.append(a, try std.fmt.allocPrint(a, "trigger:{s}", .{try perSensorName(a, "door-", d.name)}));
    try v.append(a, .{ .key = "door starts", .value = try std.mem.join(a, ", ", door_starts.items) });
    var smoke_starts: std.ArrayList([]const u8) = .empty;
    for (p.smokes) |d| try smoke_starts.append(a, try std.fmt.allocPrint(a, "trigger:{s}", .{try perSensorName(a, "smoke-", d.name)}));
    try v.append(a, .{ .key = "smoke starts", .value = try std.mem.join(a, ", ", smoke_starts.items) });
    try v.append(a, .{ .key = "smoke speaker words", .value = if (p.speakers) ", and on every speaker" else "" });
    return v.items;
}

/// A trigger's name for a sensor: `prefix` and the device's name, at most
/// 64 bytes.
fn perSensorName(a: Allocator, prefix: []const u8, device: []const u8) ![]const u8 {
    const n = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, device });
    return n[0..@min(n.len, 64)];
}

/// Whether the leak's question may close the water main itself (its
/// fallback): a valve that closes, not a switch whose safe way is off.
pub fn fallbackOffered(p: Picks) bool {
    const v = p.valve orelse return false;
    return v.kind == .valve and v.allows("close");
}

/// The leak's fallback, offered after the leak is on.
pub fn fallbackSentence(a: Allocator, p: Picks) ![]const u8 {
    return std.fmt.allocPrint(a, "If nobody answers the leak's question in 5 minutes, I close the {s} myself, once, and tell you.", .{try spoken(a, p.valve.?.name)});
}

/// Said once the leak's fallback is on.
pub fn fallbackOnText(a: Allocator, p: Picks) ![]const u8 {
    return std.fmt.allocPrint(a, "If nobody answers, I close the {s} after 5 minutes.", .{try spoken(a, p.valve.?.name)});
}

/// The line the fallback adds to the leak's step ask.
pub const fallback_line = "fallback 5m";

/// The flags the templates' `#if` lines read.
fn flagsOf(a: Allocator, p: Picks) ![]const []const u8 {
    var f: std.ArrayList([]const u8) = .empty;
    if (p.lock != null) try f.append(a, "lock");
    if (p.valve != null) try f.append(a, "valve");
    if (p.fallback and fallbackOffered(p)) try f.append(a, "fallback");
    if (p.thermostat != null) try f.append(a, "thermostat");
    if (p.car) try f.append(a, "car");
    if (p.speakers) try f.append(a, "speakers");
    if (p.mail) try f.append(a, "mail");
    if (p.people) try f.append(a, "people");
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
        const each: []const Device = if (std.mem.indexOf(u8, sname, "<leak>") != null) p.leaks else if (std.mem.indexOf(u8, sname, "<door>") != null) p.doors else if (std.mem.indexOf(u8, sname, "<smoke>") != null) p.smokes else &.{};
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
            try vs.append(a, .{ .key = "smoke", .value = d.name });
            try vs.append(a, .{ .key = "smoke words", .value = if (room.len > 0) try std.fmt.allocPrint(a, "{s}, {s}", .{ label, room }) else label });
            var text = try fill(a, body, vs.items, flags, &missing);
            // the name at most 64 bytes, as the start line says it
            const prefix: []const u8 = if (std.mem.indexOf(u8, sname, "<leak>") != null) "leak-" else if (std.mem.indexOf(u8, sname, "<smoke>") != null) "smoke-" else "door-";
            text = try std.mem.replaceOwned(u8, a, text, try std.fmt.allocPrint(a, "[{s}{s}]", .{ prefix, d.name }), try std.fmt.allocPrint(a, "[{s}]", .{try perSensorName(a, prefix, d.name)}));
            try trig.print(a, "; added by /setup routines {s}: {s}\n{s}\n", .{ date, r.title(), text });
        }
    }
    var rules: []const u8 = "";
    if (rulesGroup(r, p)) |g| {
        const tmpl = (try groupOf(a, files.rules, g)) orelse return error.NoSuchSection;
        // its own comment lines go; setup's mark comes instead
        var body = tmpl;
        while (std.mem.startsWith(u8, body, "#")) body = body[(std.mem.indexOfScalar(u8, body, '\n') orelse body.len - 1) + 1 ..];
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
    \\[device kitchen_smoke_alarm]
    \\id = binary_sensor.kitchen_smoke
    \\kind = smoke
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
    \\; settings and diagnostics of devices (a child lock, a LED, a firmware update): not things to switch
    \\;   switch.kettle_child_lock (Kettle child lock)
    \\; kinds homemcp doesn't know (a light, switch or sensor among them can be added by hand)
    \\;   sun.sun (Sun)
    \\
;

/// homemcp check's lines for it.
pub const sim_check =
    \\The flat (made up by homemcp-sim): 16 devices in 5 rooms. Home Assistant at http://127.0.0.1:8123.
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
    \\  kitchen_smoke_alarm (binary_sensor.kitchen_smoke, smoke): clear; may: nothing (only watched)
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
    try t.expectEqual(16, h.devices.len);
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
    // a smoke alarm: only watched
    const smoke = h.find("kitchen_smoke_alarm").?;
    try t.expectEqual(Kind.smoke, smoke.kind);
    try t.expect(!smoke.acts() and !smoke.isGuarded());
    // left out, with why
    try t.expectEqual(3, h.left.len);
    try t.expectEqualStrings("Front door camera", h.left[0].label);
    try t.expectEqual(Why.camera, h.left[0].why);
    try t.expectEqual(Why.setting, h.left[1].why);
    try t.expectEqual(Why.unknown, h.left[2].why);
    // what check read of each
    readCheck(&h, sim_check);
    try t.expectEqualStrings("dry", h.find("sink_leak").?.state);
    try t.expectEqualStrings("clear", h.find("kitchen_smoke_alarm").?.state);
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
    const p = try simPicks(a, .{ .car = true, .car_warms = true, .search = true, .calendar = "calendar", .quiet = .{ .start = 22 * 60, .end = 7 * 60 }, .town = "Kraków" });
    // with the owner's mailbox on, the mail routines too
    var pm = p;
    pm.mail = true;
    try t.expectEqual(2, p.lights);
    try t.expectEqualStrings("front_door", p.lock.?.name);
    try t.expectEqualStrings("water_main", p.valve.?.name);
    try t.expectEqualStrings("hall_thermostat", p.thermostat.?.name);
    try t.expectEqual(1, p.leaks.len);
    try t.expectEqual(1, p.doors.len);
    try t.expectEqual(1, p.smokes.len);
    // every routine's files, together, read as harness reads them
    var trig_all: std.ArrayList(u8) = .empty;
    var wfs: std.ArrayList(workflows.Workflow) = .empty;
    var rules_all: std.ArrayList(u8) = .empty;
    for (all) |r| {
        try t.expect(r.offered(pm));
        const f = try routineFiles(a, r, pm, "2026-11-23");
        // no <…> left, no unlock, open or disarm, no camera; a smoke alarm
        // only in its own routine (which acts on nothing)
        for ([_][]const u8{ f.workflow, f.triggers, f.rules }) |text| {
            for ([_][]const u8{ "\"action\": \"unlock\"", "\"action\": \"open\"", "disarm", "camera", if (r == .smoke) "\ntool " else "smoke", "#if", "#end" }) |bad| if (std.mem.indexOf(u8, text, bad) != null) {
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
    try t.expectEqual(12, tlist.len);
    for (wfs.items) |w| {
        var d: workflows.Diag = .{};
        _ = workflows.check(a, w, .{ .triggers = tlist }, &d) catch |e| {
            std.debug.print("{s}: line {d}: {s}\n", .{ w.name, d.line, d.why });
            return e;
        };
    }
    // the rules lines read as rules
    _ = try @import("rules.zig").parse(a, rules_all.items);
    try t.expect(std.mem.indexOf(u8, rules_all.items, "[workflow:arriving/heat]\nallow mcp home/home_set {\"action\":\"temperature\",\"device\":\"hall_thermostat\",\"value\":\"21\"}") != null);
    // no ask or deny for part of a tool beside an allow for all of it (the
    // gate matches a call's JSON as written: a space or another key order
    // would slip past the narrower line)
    for ([_][]const u8{ try setupRules(a, .home), try setupRules(a, .car), rules_all.items }) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (!(std.mem.startsWith(u8, l, "ask ") or std.mem.startsWith(u8, l, "deny "))) continue;
            std.debug.print("a narrowing line in the butler's rules: {s}\n", .{l});
            return error.TestUnexpectedResult;
        }
    }
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
    // a scheduled step reads the calendar and is given no tool that changes it
    try t.expect(std.mem.indexOf(u8, mh.workflow, "tools home/home_state, car/car_status, search, calendar/cal_agenda\n") != null);
    try t.expect(std.mem.indexOf(u8, mh.rules, "[workflow:morning-home/read]\nallow mcp calendar/cal_agenda *\n[all]") != null);
    try t.expect(std.mem.indexOf(u8, mh.workflow, "every event of today with its time") != null);
    try t.expect(std.mem.indexOf(u8, mh.workflow, "Read the car, today's calendar, the weather in Kraków and the house") != null);
    // the sentences setup offers them with
    try t.expectEqualStrings("Goodnight: when you say goodnight, or at 21:45, I switch off the lights, set the heating to 18 °C and ask with one tap before locking the front door.", try Routine.goodnight.sentence(a, p));
    try t.expectEqualStrings("Leak: when the sink leak finds water, I tell you at once, even at night, and one tap closes the water main.", try Routine.leak.sentence(a, p));
    try t.expectEqualStrings("Doors left open: when the back door stays open for 10 minutes, I tell you.", try Routine.@"door-open".sentence(a, p));
    // smoke: said at once, nothing acted on
    const sm = try routineFiles(a, .smoke, p, "2026-11-23");
    try t.expect(std.mem.indexOf(u8, sm.triggers, "[smoke-kitchen_smoke_alarm]\nmcp = home resource home://device/kitchen_smoke_alarm\nmatch = to is ALARM\nstart = workflow smoke Kitchen smoke alarm, Kitchen\nurgent = yes\n") != null);
    try t.expect(std.mem.indexOf(u8, sm.workflow, "step tell\nsay Smoke alarm: {input}.") != null);
    try t.expectEqualStrings("Smoke alarm: when the kitchen smoke alarm goes off, I tell you at once, even at night.", try Routine.smoke.sentence(a, p));
}

test "the_smoke_routine_fills_for_a_home_with_one" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home =
        \\[home]
        \\name = Flat
        \\hub = homeassistant
        \\url = http://127.0.0.1:8123
        \\[device hall_co_alarm]
        \\id = binary_sensor.hall_co
        \\kind = smoke
        \\room = Hall
        \\[device hall_voice]
        \\id = assist_satellite.hall_voice
        \\kind = satellite
        \\room = Hall
        \\allow = announce
        \\
    ;
    const h = try parseHome(a, home);
    // the household is told when the owner doesn't answer
    const p = try pick(a, h, .{ .escalate = &.{ .{ .after_s = 300, .member = "anna" }, .{ .after_s = 900, .member = "piotr" } } });
    try t.expectEqual(1, p.smokes.len);
    try t.expect(p.speakers);
    try t.expect(Routine.smoke.offered(p));
    try t.expectEqualStrings("Smoke alarm: when the hall co alarm goes off, I tell you at once, even at night, and say it on every speaker. If you don't answer in 5 minutes, I tell Anna, then Piotr.", try Routine.smoke.sentence(a, p));
    const f = try routineFiles(a, .smoke, p, "2026-11-23");
    var d: workflows.Diag = .{};
    const w = try workflows.parse(a, "smoke", f.workflow, &d);
    try t.expect(w.urgent);
    // nothing to close: no tool step, no question, no fallback
    for (w.steps) |s| try t.expect(s.action != .tool and s.action != .approve and s.fallback_s == 0);
    var td: triggers.Diag = .{};
    const tl = try triggers.parse(a, f.triggers, .triggers, &td);
    try t.expectEqual(1, tl.len);
    try t.expect(tl[0].urgent);
    try t.expectEqualStrings("Smoke alarm: Hall co alarm, Hall.", tl[0].announce);
    try t.expectEqual(triggers.Speakers.all, tl[0].speakers);
    // no speakers: nothing to announce with
    const quiet = try pick(a, try parseHome(a, home[0 .. std.mem.indexOf(u8, home, "[device hall_voice]").?]), .{});
    try t.expect(!quiet.speakers);
    const fq = try routineFiles(a, .smoke, quiet, "2026-11-23");
    try t.expect(std.mem.indexOf(u8, fq.triggers, "announce") == null);
    try t.expectEqualStrings("Smoke alarm: when the hall co alarm goes off, I tell you at once, even at night.", try Routine.smoke.sentence(a, quiet));
    // no smoke alarm: not offered
    try t.expect(!Routine.smoke.offered(try pick(a, try parseHome(a, "[home]\nname = F\n[device lamp]\nid = light.l\nkind = light\nallow = on\n"), .{})));
}

test "a_template_with_windows_line_ends_fills_as_with_plain_ones" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a checkout made on Windows may end each line with \r\n
    const plain = "step ask\n#if lock\napprove Lock <lock>\nyes Lock it\n#end\nsay Good night, <Owner>\n";
    const windows = "step ask\r\n#if lock\r\napprove Lock <lock>\r\nyes Lock it\r\n#end\r\nsay Good night, <Owner>\r\n";
    const values = [_]Value{ .{ .key = "lock", .value = "front_door" }, .{ .key = "owner", .value = "anna" } };
    var missing: []const u8 = "";
    const want = try fill(a, plain, &values, &.{"lock"}, &missing);
    try t.expectEqualStrings("step ask\napprove Lock front_door\nyes Lock it\nsay Good night, Anna\n", want);
    try t.expectEqualStrings(want, try fill(a, windows, &values, &.{"lock"}, &missing));
}

test "warm_car_is_offered_when_the_car_can_warm_and_the_diary_is_on" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try parseHome(a, sim_home);
    readCheck(&h, sim_check);
    // a car without climate (Smartcar), or no calendar for the leave-by: not offered
    try t.expect(!Routine.@"warm-car".offered(try pick(a, h, .{ .car = true, .calendar = "calendar" })));
    try t.expect(!Routine.@"warm-car".offered(try pick(a, h, .{ .car = true, .car_warms = true })));
    const p = try pick(a, h, .{ .car = true, .car_warms = true, .calendar = "calendar", .warm_below = 3 });
    try t.expect(Routine.@"warm-car".offered(p));
    try t.expectEqualStrings("Warm the car: 30 minutes before you leave for a morning event in your calendar, when it's below 3 °C at the car, I ask \"Warm the car for 8:10?\" and one tap warms it.", try Routine.@"warm-car".sentence(a, p));
    try t.expectEqualStrings("Warm the car is on: before a morning leave-by when it's below 3 °C at the car; it wakes the car once to read it.", try onText(a, .@"warm-car", p));
    const f = try routineFiles(a, .@"warm-car", p, "2026-11-23");
    // harness starts it itself: no trigger, no rules
    try t.expectEqualStrings("", f.triggers);
    try t.expectEqualStrings("", f.rules);
    try t.expect(std.mem.indexOf(u8, f.workflow, "# added by /setup routines 2026-11-23: the butler's Warm the car routine (harness/examples/butler)\nworkflow warm-car\n") != null);
    try t.expect(std.mem.indexOf(u8, f.workflow, "about Before a morning leave-by when it is below 3 °C at the car: asks with one tap to warm the car.\n") != null);
    try t.expect(std.mem.indexOf(u8, f.workflow, "approve Warm the car for {event.leave}? It's {event.outside} °C at the car.\nyes Warm it\n") != null);
    try t.expect(std.mem.indexOf(u8, f.workflow, "tool car/car_climate {\"state\": \"on\"}\n") != null);
    // it reads as harness reads it, and its start needs no section
    var d: workflows.Diag = .{};
    const w = try workflows.parse(a, "warm-car", f.workflow, &d);
    _ = try workflows.check(a, w, .{}, &d);
    try t.expectEqualStrings("schedule:warm-car", w.start[0]);
    // with \r\n line ends (a Windows checkout) it fills the same
    var missing: []const u8 = "";
    const crlf = try std.mem.replaceOwned(u8, a, workflowTemplate(.@"warm-car"), "\n", "\r\n");
    try t.expectEqualStrings(try fill(a, workflowTemplate(.@"warm-car"), try commonValues(a, p), &.{}, &missing), try fill(a, crlf, try commonValues(a, p), &.{}, &missing));
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

/// homemcp-sim's home with three switches discover can't tell apart from
/// lights or plugs, or knows by name: a plain one, a valve, an opener.
const switches_home = sim_home ++
    \\
    \\[device garden_switch]
    \\id = switch.garden
    \\kind = switch
    \\room = Garden
    \\allow = on, off
    \\
    \\[device boiler_valve]
    \\id = switch.boiler_valve
    \\kind = switch
    \\room = Garden
    \\allow = off
    \\guarded = yes
    \\note = a valve, by its name: it may only be switched off (closed)
    \\
    \\[device gate_opener]
    \\id = switch.gate_opener
    \\kind = switch
    \\room = Garden
    \\guarded = yes
    \\note = by its name it opens or locks something: nothing is allowed until you add it
    \\
;

test "the_summary_says_what_it_switches_asks_and_leaves" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try parseHome(a, sim_home);
    readCheck(&h, sim_check);
    const s = try homeSummary(a, h);
    try t.expectEqualStrings(
        \\I found 16 devices in 5 rooms, and 2 people.
        \\I'll switch lights, plugs, the heating, fans, speakers and scenes when you ask.
        \\I'll ask you every time before the water main, the front door, the garage door and the leaving scene.
        \\I won't touch the front door camera or the kitchen smoke alarm.
        \\I'll watch the living room temperature, the back door, the sink leak and the hall motion.
        \\If the kettle plug powers a kettle or a heater, send /setup home ask kettle_plug and I'll ask you first.
    , s);
    // the car's, from carcloud check's lines
    try t.expectEqualStrings("The car answers: battery 64 %, range 294 km, plugged in, not charging, charge limit 80 % (data from 30 minutes ago).\nI'll read it, and start or stop charging and set the charge limit (60–90 %) when you ask. I won't lock or unlock it: car.ini doesn't list them.", try carSummary(a, "The made-up car:\nbattery: 64%\nrange: 294.4 km\ncharging: no\nplugged in: yes\ncharge limit: 80%\nlocked: yes\nodometer: 18234.6 km\ninside: 14.5 °C\ndata: from 30 minutes ago\ncommands the owner allowed: charge_start, charge_stop, charge_limit\n"));
}

test "unidentified_switches_stay_guarded_until_sorted" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // as discover wrote it, the plain switch may act; setup guards it
    try t.expect((try parseHome(a, switches_home)).find("garden_switch").?.acts());
    const marked = try markUnidentified(a, switches_home);
    var h = try parseHome(a, marked);
    const g = h.find("garden switch").?;
    try t.expect(g.isGuarded() and !g.acts() and g.unidentified());
    // the valve and the opener discover knew by name stay as they were
    try t.expectEqualStrings("a valve, by its name: it may only be switched off (closed)", h.find("boiler_valve").?.note);
    try t.expect(!h.find("gate_opener").?.unidentified());
    // the summary lists it, and how to sort it
    const s = try homeSummary(a, h);
    try t.expect(std.mem.indexOf(u8, s, "I couldn't tell what the garden switch controls: I'll ask you before switching it until you sort it. If it's a light or a plug, send /setup home allow garden_switch.") != null);
    try t.expect(std.mem.indexOf(u8, s, "I won't touch the front door camera, the kitchen smoke alarm or the gate opener (it may do nothing yet).") != null);
    // sorted: it acts
    const sorted = try editHome(a, marked, .allow, "garden_switch");
    try t.expectEqualStrings("The garden switch: I'll switch it when you ask.", sorted.said);
    const h2 = try parseHome(a, sorted.text);
    try t.expect(h2.find("garden_switch").?.acts() and !h2.find("garden_switch").?.unidentified());
    // discover run again: what the owner sorted stays sorted; left out stays out
    const left = try editHome(a, sorted.text, .leave, "kitchen speaker");
    const again = try carryOver(a, try markUnidentified(a, switches_home), left.text);
    const h3 = try parseHome(a, again);
    try t.expect(h3.find("garden_switch").?.acts());
    try t.expect(h3.find("kitchen_speaker") == null);
}

test "edits_leave_ask_allow" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try editHome(a, sim_home, .leave, "Kitchen Speaker");
    try t.expectEqualStrings("Left out: the kitchen speaker.", left.said);
    try t.expect((try parseHome(a, left.text)).find("kitchen_speaker") == null);
    try t.expect(std.mem.indexOf(u8, left.text, "; left out at /setup: kitchen_speaker (media_player.kitchen_speaker)") != null);
    const asked = try editHome(a, left.text, .ask, "ceiling fan");
    try t.expectEqualStrings("The ceiling fan: I'll ask you every time.", asked.said);
    try t.expect((try parseHome(a, asked.text)).find("ceiling_fan").?.isGuarded());
    const allowed = try editHome(a, asked.text, .allow, "ceiling_fan");
    try t.expect((try parseHome(a, allowed.text)).find("ceiling_fan").?.acts());
    // what is never let act alone, and what is only seen
    for ([_][]const u8{ "front_door", "garage_door", "water_main", "leaving" }) |n| {
        const r = try editHome(a, sim_home, .allow, n);
        try t.expect(r.refused);
        try t.expectEqualStrings(sim_home, r.text);
        try t.expect(std.mem.indexOf(u8, r.said, "asked every time") != null);
    }
    const sensor = try editHome(a, sim_home, .ask, "back_door");
    try t.expect(sensor.refused);
    try t.expectEqualStrings("The back door is a sensor: it is only seen, never switched.", sensor.said);
    const none = try editHome(a, sim_home, .ask, "the moon");
    try t.expect(none.refused);
    try t.expectEqualStrings("No device called the moon in the home file.", none.said);
}

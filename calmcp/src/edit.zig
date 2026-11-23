//! Changes to a calendar object's text, line by line, keeping every line
//! it doesn't change (other properties, alarms, the server's own): an
//! event's times moved in their own form (its TZID kept), one occurrence
//! of a series overridden (RECURRENCE-ID) or taken out (EXDATE), the
//! owner's answer (PARTSTAT) set, SEQUENCE raised; written back with CRLF
//! and lines folded at 75 bytes. And a new event's object.
const std = @import("std");
const ics = @import("ics.zig");
const tz = @import("tz.zig");
const Allocator = std.mem.Allocator;

/// A time as the object writes it: in `form`'s kind (a date, UTC, a zone's
/// wall clock, floating), for Unix time `t`; `zone` is the one `form` is
/// read in.
pub fn format(a: Allocator, name: []const u8, form: ics.When, zone: tz.Zone, t: i64) ![]const u8 {
    var b: [16]u8 = undefined;
    return switch (form.kind) {
        .date => std.fmt.allocPrint(a, "{s};VALUE=DATE:{s}", .{ name, dateText(&b, zone.toLocal(t)) }),
        .utc => std.fmt.allocPrint(a, "{s}:{s}Z", .{ name, timeText(&b, t) }),
        .floating => std.fmt.allocPrint(a, "{s}:{s}", .{ name, timeText(&b, zone.toLocal(t)) }),
        .zoned => std.fmt.allocPrint(a, "{s};TZID={s}:{s}", .{ name, try paramValue(a, form.tzid), timeText(&b, zone.toLocal(t)) }),
    };
}

fn dateText(b: *[16]u8, local: i64) []const u8 {
    const c = tz.civil(@divFloor(local, 86400));
    return std.fmt.bufPrint(b, "{d:0>4}{d:0>2}{d:0>2}", .{ @as(u64, @intCast(c.y)), c.m, c.d }) catch unreachable;
}

fn timeText(b: *[16]u8, local: i64) []const u8 {
    const c = tz.civil(@divFloor(local, 86400));
    const sod: u64 = @intCast(@mod(local, 86400));
    return std.fmt.bufPrint(b, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}", .{ @as(u64, @intCast(c.y)), c.m, c.d, sod / 3600, sod / 60 % 60, sod % 60 }) catch unreachable;
}

/// A parameter's value, quoted when it holds : ; or ,.
fn paramValue(a: Allocator, v: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, v, ":;,") == null) return v;
    return std.fmt.allocPrint(a, "\"{s}\"", .{v});
}

/// A content line's property name.
fn nameOf(line: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, line, ";:") orelse line.len;
    return line[0..end];
}

fn isLine(line: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(nameOf(line), name);
}

/// A VEVENT's lines: [begin, end] (its BEGIN and END lines), its UID and
/// RECURRENCE-ID line.
const Block = struct { begin: usize, end: usize, uid: []const u8 = "", rid: ?[]const u8 = null };

fn blocks(a: Allocator, lines: []const []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(lines[i], "BEGIN:VEVENT")) continue;
        var b: Block = .{ .begin = i, .end = i };
        var depth: u32 = 0;
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            if (std.ascii.startsWithIgnoreCase(l, "BEGIN:")) {
                depth += 1;
            } else if (std.ascii.startsWithIgnoreCase(l, "END:")) {
                if (depth == 0) break;
                depth -= 1;
            } else if (depth == 0) {
                if (isLine(l, "UID") and b.uid.len == 0) b.uid = l[std.mem.indexOfScalar(u8, l, ':').? + 1 ..];
                if (isLine(l, "RECURRENCE-ID")) b.rid = l;
            }
        }
        b.end = j;
        try out.append(a, b);
        i = j;
    }
    return out.items;
}

/// The first line of block `b` (its own, not an alarm's) called `name`.
fn propIn(lines: []const []const u8, b: Block, name: []const u8) ?usize {
    var depth: u32 = 0;
    var j = b.begin + 1;
    while (j < b.end) : (j += 1) {
        const l = lines[j];
        if (std.ascii.startsWithIgnoreCase(l, "BEGIN:")) {
            depth += 1;
        } else if (std.ascii.startsWithIgnoreCase(l, "END:")) {
            depth -|= 1;
        } else if (depth == 0 and isLine(l, name)) return j;
    }
    return null;
}

/// Sets property `name` of block `b` to `line` (in place, or right after
/// its BEGIN line); `b`'s end moves with an insertion.
fn setProp(a: Allocator, lines: *std.ArrayList([]const u8), b: *Block, name: []const u8, line: []const u8) !void {
    if (propIn(lines.items, b.*, name)) |j| {
        lines.items[j] = line;
        return;
    }
    try lines.insert(a, b.begin + 1, line);
    b.end += 1;
}

fn dropProp(lines: *std.ArrayList([]const u8), b: *Block, name: []const u8) void {
    while (propIn(lines.items, b.*, name)) |j| {
        _ = lines.orderedRemove(j);
        b.end -= 1;
    }
}

fn stampLine(a: Allocator, name: []const u8, now: i64) ![]const u8 {
    var b: [16]u8 = undefined;
    return std.fmt.allocPrint(a, "{s}:{s}Z", .{ name, timeText(&b, now) });
}

/// SEQUENCE one up, DTSTAMP (and LAST-MODIFIED, when there) now.
fn touched(a: Allocator, lines: *std.ArrayList([]const u8), b: *Block, now: i64) !void {
    const seq: i64 = if (propIn(lines.items, b.*, "SEQUENCE")) |j| std.fmt.parseInt(i64, std.mem.trim(u8, lines.items[j][std.mem.indexOfScalar(u8, lines.items[j], ':').? + 1 ..], " "), 10) catch 0 else 0;
    try setProp(a, lines, b, "SEQUENCE", try std.fmt.allocPrint(a, "SEQUENCE:{d}", .{seq + 1}));
    try setProp(a, lines, b, "DTSTAMP", try stampLine(a, "DTSTAMP", now));
    if (propIn(lines.items, b.*, "LAST-MODIFIED") != null) try setProp(a, lines, b, "LAST-MODIFIED", try stampLine(a, "LAST-MODIFIED", now));
}

fn whenOf(a: Allocator, line: []const u8) !ics.When {
    return ics.parseWhen(try ics.parseLine(a, line));
}

fn ridMatches(a: Allocator, zones: ics.Zones, rid_line: []const u8, recur: i64) bool {
    const w = whenOf(a, rid_line) catch return false;
    if (w.kind == .date) return @divFloor(w.local, 86400) == @divFloor(zones.owner.toLocal(recur), 86400);
    return zones.toUtc(w) == recur;
}

const Doc = struct { lines: std.ArrayList([]const u8), list: []Block };

fn load(a: Allocator, text: []const u8) !Doc {
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.appendSlice(a, try ics.unfold(a, text));
    return .{ .lines = lines, .list = try blocks(a, lines.items) };
}

fn master(d: Doc, uid: []const u8) ?Block {
    for (d.list) |b| if (std.mem.eql(u8, b.uid, uid) and b.rid == null) return b;
    return null;
}

/// Moves event `uid`'s time (an occurrence's when `recur` is given: its
/// override, made if it isn't there) to [`start`, `end`); SEQUENCE + 1.
pub fn move(a: Allocator, text: []const u8, zones: ics.Zones, uid: []const u8, recur: ?i64, start: i64, end: i64, now: i64) ![]const u8 {
    var d = try load(a, text);
    var target: ?Block = null;
    if (recur) |r| {
        for (d.list) |b| if (std.mem.eql(u8, b.uid, uid)) if (b.rid) |rl| if (ridMatches(a, zones, rl, r)) {
            target = b;
        };
        if (target == null) {
            // a new override: the series' lines without its rule and times
            const m = master(d, uid) orelse return error.NoSuchEvent;
            const form = try whenOf(a, d.lines.items[propIn(d.lines.items, m, "DTSTART") orelse return error.NoSuchEvent]);
            const zone = zones.zoneOf(form);
            var copy: std.ArrayList([]const u8) = .empty;
            try copy.append(a, "BEGIN:VEVENT");
            const skip = [_][]const u8{ "RRULE", "RDATE", "EXDATE", "EXRULE", "DTSTART", "DTEND", "DURATION", "RECURRENCE-ID", "SEQUENCE", "DTSTAMP" };
            var depth: u32 = 0;
            for (d.lines.items[m.begin + 1 .. m.end]) |l| {
                if (std.ascii.startsWithIgnoreCase(l, "BEGIN:")) depth += 1;
                const own = depth == 0;
                if (std.ascii.startsWithIgnoreCase(l, "END:")) depth -|= 1;
                if (own) {
                    const dropped = for (skip) |n| {
                        if (isLine(l, n)) break true;
                    } else false;
                    if (dropped) continue;
                }
                try copy.append(a, l);
            }
            const seq: i64 = if (propIn(d.lines.items, m, "SEQUENCE")) |j| std.fmt.parseInt(i64, d.lines.items[j][std.mem.indexOfScalar(u8, d.lines.items[j], ':').? + 1 ..], 10) catch 0 else 0;
            // right after UID: the occurrence, its new times
            const at: usize = for (copy.items, 0..) |l, i| {
                if (isLine(l, "UID")) break i + 1;
            } else 1;
            try copy.insertSlice(a, at, &.{
                try format(a, "RECURRENCE-ID", form, zone, r),
                try format(a, "DTSTART", form, zone, start),
                try format(a, "DTEND", form, zone, end),
                try std.fmt.allocPrint(a, "SEQUENCE:{d}", .{seq + 1}),
                try stampLine(a, "DTSTAMP", now),
            });
            try copy.append(a, "END:VEVENT");
            // after the last VEVENT
            var last: usize = 0;
            for (d.list) |b| last = @max(last, b.end);
            try d.lines.insertSlice(a, last + 1, copy.items);
            return fold(a, d.lines.items);
        }
    } else {
        target = master(d, uid);
        if (target == null) for (d.list) |b| if (std.mem.eql(u8, b.uid, uid)) {
            target = b;
            break;
        };
    }
    var b = target orelse return error.NoSuchEvent;
    const ds = propIn(d.lines.items, b, "DTSTART") orelse return error.NoSuchEvent;
    const form = try whenOf(a, d.lines.items[ds]);
    d.lines.items[ds] = try format(a, "DTSTART", form, zones.zoneOf(form), start);
    if (propIn(d.lines.items, b, "DTEND")) |de| {
        const ef = try whenOf(a, d.lines.items[de]);
        d.lines.items[de] = try format(a, "DTEND", ef, zones.zoneOf(ef), end);
    } else if (propIn(d.lines.items, b, "DURATION")) |du| {
        d.lines.items[du] = try std.fmt.allocPrint(a, "DURATION:PT{d}S", .{end - start});
    } else if (end != start) {
        try d.lines.insert(a, ds + 1, try format(a, "DTEND", form, zones.zoneOf(form), end));
        b.end += 1;
    }
    try touched(a, &d.lines, &b, now);
    return fold(a, d.lines.items);
}

/// Takes occurrence `recur` out of series `uid` (an EXDATE; its override
/// goes too).
pub fn exclude(a: Allocator, text: []const u8, zones: ics.Zones, uid: []const u8, recur: i64, now: i64) ![]const u8 {
    var d = try load(a, text);
    // its override first (from the end, so the series' place holds)
    var i = d.list.len;
    while (i > 0) {
        i -= 1;
        const b = d.list[i];
        if (!std.mem.eql(u8, b.uid, uid)) continue;
        const rl = b.rid orelse continue;
        if (!ridMatches(a, zones, rl, recur)) continue;
        try d.lines.replaceRange(a, b.begin, b.end - b.begin + 1, &.{});
    }
    d.list = try blocks(a, d.lines.items);
    var m = master(d, uid) orelse return error.NoSuchEvent;
    const form = try whenOf(a, d.lines.items[propIn(d.lines.items, m, "DTSTART") orelse return error.NoSuchEvent]);
    try d.lines.insert(a, m.begin + 1, try format(a, "EXDATE", form, zones.zoneOf(form), recur));
    m.end += 1;
    try touched(a, &d.lines, &m, now);
    return fold(a, d.lines.items);
}

/// The owner's (`email`) answer to event `uid` set to `partstat` in each
/// of its VEVENTs; error.NotInvited when no ATTENDEE is the owner.
pub fn answer(a: Allocator, text: []const u8, uid: []const u8, email: []const u8, partstat: []const u8, now: i64) ![]const u8 {
    var d = try load(a, text);
    var found = false;
    var bi: usize = 0;
    while (bi < d.list.len) : (bi += 1) {
        if (!std.mem.eql(u8, d.list[bi].uid, uid)) continue;
        var b = d.list[bi];
        var depth: u32 = 0;
        var j = b.begin + 1;
        while (j < b.end) : (j += 1) {
            const l = d.lines.items[j];
            if (std.ascii.startsWithIgnoreCase(l, "BEGIN:")) {
                depth += 1;
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(l, "END:")) {
                depth -|= 1;
                continue;
            }
            if (depth != 0 or !isLine(l, "ATTENDEE")) continue;
            const p = ics.parseLine(a, l) catch continue;
            if (!std.ascii.eqlIgnoreCase(ics.mailto(p.value), email)) continue;
            var o: std.ArrayList(u8) = .empty;
            try o.appendSlice(a, p.name);
            var set = false;
            for (p.params) |x| {
                if (std.ascii.eqlIgnoreCase(x.name, "PARTSTAT")) {
                    try o.print(a, ";{s}={s}", .{ x.name, partstat });
                    set = true;
                } else try o.print(a, ";{s}={s}", .{ x.name, try paramValue(a, x.value) });
            }
            if (!set) try o.print(a, ";PARTSTAT={s}", .{partstat});
            try o.print(a, ":{s}", .{p.value});
            d.lines.items[j] = o.items;
            found = true;
        }
        try setProp(a, &d.lines, &b, "DTSTAMP", try stampLine(a, "DTSTAMP", now));
        // the insertion moved what follows
        d.list = try blocks(a, d.lines.items);
    }
    if (!found) return error.NotInvited;
    return fold(a, d.lines.items);
}

pub const New = struct {
    uid: []const u8,
    title: []const u8,
    start: i64,
    end: i64,
    /// Whole days from the owner's `start` day (start and end are midnights).
    all_day: bool = false,
    place: []const u8 = "",
    notes: []const u8 = "",
};

/// A new event's object, its times in UTC (dates for all-day ones).
pub fn create(a: Allocator, n: New, zone: tz.Zone, now: i64) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.appendSlice(a, &.{ "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//calmcp//EN", "BEGIN:VEVENT" });
    try lines.append(a, try std.fmt.allocPrint(a, "UID:{s}", .{n.uid}));
    try lines.append(a, try stampLine(a, "DTSTAMP", now));
    const form: ics.When = .{ .kind = if (n.all_day) .date else .utc, .local = 0 };
    try lines.append(a, try format(a, "DTSTART", form, if (n.all_day) zone else .utc, n.start));
    try lines.append(a, try format(a, "DTEND", form, if (n.all_day) zone else .utc, n.end));
    try lines.append(a, try std.fmt.allocPrint(a, "SUMMARY:{s}", .{try ics.escape(a, n.title)}));
    if (n.place.len > 0) try lines.append(a, try std.fmt.allocPrint(a, "LOCATION:{s}", .{try ics.escape(a, n.place)}));
    if (n.notes.len > 0) try lines.append(a, try std.fmt.allocPrint(a, "DESCRIPTION:{s}", .{try ics.escape(a, n.notes)}));
    try lines.appendSlice(a, &.{ "SEQUENCE:0", if (n.all_day) "TRANSP:TRANSPARENT" else "TRANSP:OPAQUE", "STATUS:CONFIRMED", "END:VEVENT", "END:VCALENDAR" });
    return fold(a, lines.items);
}

/// Lines folded at 75 bytes (not inside a UTF-8 character), CRLF.
pub fn fold(a: Allocator, lines: []const []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        var rest = line;
        var width: usize = 75;
        while (rest.len > width) {
            var cut = width;
            while (cut > 1 and (rest[cut] & 0xc0) == 0x80) cut -= 1;
            try o.appendSlice(a, rest[0..cut]);
            try o.appendSlice(a, "\r\n ");
            rest = rest[cut..];
            width = 74;
        }
        try o.appendSlice(a, rest);
        try o.appendSlice(a, "\r\n");
    }
    return o.items;
}

// ---- tests ----

const tt = std.testing;
const sim = @import("sim.zig");

fn utc(y: i64, m: u8, d: u8, hh: i64, mm: i64) i64 {
    return tz.daysFromCivil(y, m, d) * 86400 + hh * 3600 + mm * 60;
}

const now0 = utc(2026, 11, 23, 7, 0);

fn has(text: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, text, want) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    }
}

const dentist = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//x//EN\r\n" ++ sim.vtz_warsaw ++
    "BEGIN:VEVENT\r\nUID:d1\r\nDTSTAMP:20261101T120000Z\r\nDTSTART;TZID=Europe/Warsaw:20261123T103000\r\nDTEND;TZID=Europe/Warsaw:20261123T113000\r\nSUMMARY:Dentist\r\nX-UNKNOWN;P=1:kept as it was\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nSEQUENCE:3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";

fn zonesOf(a: Allocator, text: []const u8) !ics.Zones {
    const owner = tz.lookup("Europe/Warsaw").?;
    return (ics.Zones{ .owner = owner }).of(a, try ics.parse(a, text), owner);
}

test "a_single_event_moves_in_its_own_zone_and_keeps_the_rest" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zones = try zonesOf(a, dentist);
    // to Friday 10:30 Warsaw (09:30 UTC)
    const out = try move(a, dentist, zones, "d1", null, utc(2026, 11, 27, 9, 30), utc(2026, 11, 27, 10, 30), now0);
    try has(out, "DTSTART;TZID=Europe/Warsaw:20261127T103000\r\n");
    try has(out, "DTEND;TZID=Europe/Warsaw:20261127T113000\r\n");
    try has(out, "SEQUENCE:4\r\n");
    try has(out, "DTSTAMP:20261123T070000Z\r\n");
    try has(out, "X-UNKNOWN;P=1:kept as it was\r\n");
    try has(out, "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n");
    try has(out, "TZID:Europe/Warsaw\r\n");
    try tt.expect(std.mem.indexOf(u8, out, "20261123T103000") == null);
    // read again: the new times
    const e = (try ics.events(a, try ics.parse(a, out)))[0];
    try tt.expectEqual(utc(2026, 11, 27, 9, 30), zones.toUtc(e.start));
    try tt.expectError(error.NoSuchEvent, move(a, dentist, zones, "nope", null, 0, 0, now0));
    // forms: UTC, a date, floating
    var b: std.ArrayList(u8) = .empty;
    _ = &b;
    try tt.expectEqualStrings("DTSTART:20261127T093000Z", try format(a, "DTSTART", .{ .kind = .utc, .local = 0 }, .utc, utc(2026, 11, 27, 9, 30)));
    try tt.expectEqualStrings("DTSTART;VALUE=DATE:20261127", try format(a, "DTSTART", .{ .kind = .date, .local = 0 }, zones.owner, utc(2026, 11, 26, 23, 0)));
    try tt.expectEqualStrings("DTEND:20261127T103000", try format(a, "DTEND", .{ .kind = .floating, .local = 0 }, zones.owner, utc(2026, 11, 27, 9, 30)));
}

const series = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" ++ sim.vtz_warsaw ++
    "BEGIN:VEVENT\r\nUID:team\r\nDTSTART;TZID=Europe/Warsaw:20260928T090000\r\nDTEND;TZID=Europe/Warsaw:20260928T093000\r\nRRULE:FREQ=WEEKLY;BYDAY=MO\r\nSUMMARY:Team call\r\nATTENDEE;CN=Owner;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:owner@example.com\r\nATTENDEE;CN=Ewa;PARTSTAT=ACCEPTED:mailto:ewa@example.com\r\nEND:VEVENT\r\n" ++
    "BEGIN:VEVENT\r\nUID:team\r\nRECURRENCE-ID;TZID=Europe/Warsaw:20261116T090000\r\nDTSTART;TZID=Europe/Warsaw:20261116T100000\r\nDTEND;TZID=Europe/Warsaw:20261116T103000\r\nSUMMARY:Team call\r\nATTENDEE;CN=Owner;PARTSTAT=NEEDS-ACTION:mailto:OWNER@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";

test "an_occurrence_is_overridden_or_taken_out_never_the_series" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zones = try zonesOf(a, series);
    // 30 Nov's 09:00 (08:00 UTC) to 11:00: a new override, the series as it was
    const moved = try move(a, series, zones, "team", utc(2026, 11, 30, 8, 0), utc(2026, 11, 30, 10, 0), utc(2026, 11, 30, 10, 30), now0);
    try has(moved, "RRULE:FREQ=WEEKLY;BYDAY=MO\r\n");
    try has(moved, "DTSTART;TZID=Europe/Warsaw:20260928T090000\r\n");
    try has(moved, "RECURRENCE-ID;TZID=Europe/Warsaw:20261130T090000\r\nDTSTART;TZID=Europe/Warsaw:20261130T110000\r\nDTEND;TZID=Europe/Warsaw:20261130T113000\r\n");
    // the override has the series' people and title, no rule
    const evs = try ics.events(a, try ics.parse(a, moved));
    try tt.expectEqual(@as(usize, 3), evs.len);
    try tt.expectEqualStrings("Team call", evs[2].summary);
    try tt.expectEqual(@as(usize, 2), evs[2].attendees.len);
    try tt.expectEqualStrings("", evs[2].rrule);
    // an occurrence that has an override already: that one is moved
    const again = try move(a, series, zones, "team", utc(2026, 11, 16, 8, 0), utc(2026, 11, 16, 12, 0), utc(2026, 11, 16, 12, 30), now0);
    try has(again, "RECURRENCE-ID;TZID=Europe/Warsaw:20261116T090000\r\nDTSTART;TZID=Europe/Warsaw:20261116T130000\r\n");
    try tt.expectEqual(@as(usize, 2), (try ics.events(a, try ics.parse(a, again))).len);
    // taken out: an EXDATE in the series' form; its override gone
    const out = try exclude(a, series, zones, "team", utc(2026, 11, 16, 8, 0), now0);
    try has(out, "EXDATE;TZID=Europe/Warsaw:20261116T090000\r\n");
    try tt.expectEqual(@as(usize, 1), (try ics.events(a, try ics.parse(a, out))).len);
    try has(out, "RRULE:FREQ=WEEKLY;BYDAY=MO\r\n");
    // the owner's answer, in every VEVENT of it, the address's case aside
    const ans = try answer(a, series, "team", "owner@example.com", "ACCEPTED", now0);
    try has(ans, "ATTENDEE;CN=Owner;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:owner@example.com\r\n");
    try has(ans, "ATTENDEE;CN=Owner;PARTSTAT=ACCEPTED:mailto:OWNER@example.com\r\n");
    try has(ans, "ATTENDEE;CN=Ewa;PARTSTAT=ACCEPTED:mailto:ewa@example.com\r\n");
    try tt.expectError(error.NotInvited, answer(a, series, "team", "someone@else.com", "DECLINED", now0));
}

test "a_new_event_and_long_lines_folded" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = tz.lookup("Europe/Warsaw").?;
    const text = try create(a, .{ .uid = "new-1@calmcp", .title = "Dentist, again", .start = utc(2026, 11, 27, 9, 30), .end = utc(2026, 11, 27, 10, 30), .place = "Dental clinic; Kraków", .notes = "line one\nline two" }, owner, now0);
    try has(text, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//calmcp//EN\r\nBEGIN:VEVENT\r\nUID:new-1@calmcp\r\nDTSTAMP:20261123T070000Z\r\nDTSTART:20261127T093000Z\r\nDTEND:20261127T103000Z\r\nSUMMARY:Dentist\\, again\r\nLOCATION:Dental clinic\\; Kraków\r\nDESCRIPTION:line one\\nline two\r\n");
    try has(text, "END:VEVENT\r\nEND:VCALENDAR\r\n");
    const e = (try ics.events(a, try ics.parse(a, text)))[0];
    try tt.expectEqualStrings("Dentist, again", e.summary);
    const day = try create(a, .{ .uid = "d@calmcp", .title = "Away", .start = utc(2026, 11, 26, 23, 0), .end = utc(2026, 11, 28, 23, 0), .all_day = true }, owner, now0);
    try has(day, "DTSTART;VALUE=DATE:20261127\r\nDTEND;VALUE=DATE:20261129\r\n");
    // 75 bytes a line at most, never inside a character; unfolds to what it was
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(a, "DESCRIPTION:");
    for (0..40) |_| try long.appendSlice(a, "zażółć ");
    const folded = try fold(a, &.{long.items});
    var it = std.mem.splitSequence(u8, folded, "\r\n");
    while (it.next()) |l| {
        try tt.expect(l.len <= 75);
        try tt.expect(std.unicode.utf8ValidateSlice(l));
    }
    const back = try ics.unfold(a, folded);
    try tt.expectEqualStrings(long.items, back[0]);
}

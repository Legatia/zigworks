//! One calendar object's events as the times they happen in a window: a
//! recurring event expanded (rrule.zig) in its own zone, its EXDATEs left
//! out, its RDATEs added, an overridden occurrence (RECURRENCE-ID) in
//! place of the one it overrides; all-day events from the owner's
//! midnight to midnight.
const std = @import("std");
const tz = @import("tz.zig");
const ics = @import("ics.zig");
const rrule = @import("rrule.zig");
const Allocator = std.mem.Allocator;

pub const Instance = struct {
    /// Where its title, place and people come from (an override's own).
    ev: *const ics.Event,
    /// Unix seconds.
    start: i64,
    end: i64,
    all_day: bool,
    /// A recurring event's occurrence: its original start (Unix seconds),
    /// as RECURRENCE-ID names it.
    recur: ?i64 = null,
    /// The series' rule ("" for a single event).
    rule: []const u8 = "",
    /// The rule has parts calmcp doesn't expand: only its first time is here.
    unsupported: bool = false,
    /// Its TZID was known (VTIMEZONE or the table); else read as the owner's.
    zone_known: bool = true,
    /// Its TZID ("" for UTC, floating or a date).
    tzid: []const u8 = "",

    pub fn cancelled(i: Instance) bool {
        return std.ascii.eqlIgnoreCase(i.ev.status, "CANCELLED");
    }
};

/// The instances of `evs` (one object's VEVENTs) that overlap [`from`,
/// `to`), by start; at most `max`.
pub fn expand(a: Allocator, evs: []const ics.Event, zones: ics.Zones, from: i64, to: i64, max: usize) ![]Instance {
    var out: std.ArrayList(Instance) = .empty;
    for (evs, 0..) |*e, idx| {
        if (e.recurrence_id != null) {
            // an override whose series is in this object takes its occurrence's place below
            const has_master = for (evs) |m| {
                if (m.recurrence_id == null and std.mem.eql(u8, m.uid, e.uid)) break true;
            } else false;
            if (has_master) {
                const one = instanceOf(e, zones, null);
                var i = one;
                i.recur = zones.toUtc(e.recurrence_id.?);
                const master = for (evs) |m| {
                    if (m.recurrence_id == null and std.mem.eql(u8, m.uid, e.uid)) break m;
                } else unreachable;
                i.rule = master.rrule;
                if (overlaps(i, from, to)) try out.append(a, i);
                continue;
            }
        }
        const repeats = e.rrule.len > 0 or e.rdates.len > 0;
        if (!repeats) {
            const i = instanceOf(e, zones, null);
            if (overlaps(i, from, to)) try out.append(a, i);
            continue;
        }
        try series(a, &out, evs, idx, zones, from, to, max);
    }
    std.mem.sort(Instance, out.items, {}, byStart);
    if (out.items.len > max) out.shrinkRetainingCapacity(max);
    return out.items;
}

fn byStart(_: void, x: Instance, y: Instance) bool {
    if (x.start != y.start) return x.start < y.start;
    return x.end < y.end;
}

fn overlaps(i: Instance, from: i64, to: i64) bool {
    if (i.end > i.start) return i.start < to and i.end > from;
    return i.start >= from and i.start < to;
}

/// How long an event lasts: DTEND - DTSTART, or DURATION, else a day for
/// a date and nothing for a time.
fn lengthOf(e: *const ics.Event, zones: ics.Zones) i64 {
    if (e.end) |end| {
        if (e.start.kind == .date and end.kind == .date) return @max(0, end.local - e.start.local);
        return @max(0, zones.toUtc(end) - zones.toUtc(e.start));
    }
    if (e.duration_s) |d| return @max(0, d);
    return if (e.start.kind == .date) 86400 else 0;
}

/// `e` as one instance; `at`: another start (local seconds in its zone)
/// for an occurrence of a series.
fn instanceOf(e: *const ics.Event, zones: ics.Zones, at: ?i64) Instance {
    var w = e.start;
    if (at) |x| w.local = x;
    const all_day = w.kind == .date;
    const found = if (w.kind == .zoned) zones.zone(w.tzid) else ics.Zones.Found{ .zone = zones.owner, .known = true };
    const start = zones.toUtc(w);
    var end: i64 = undefined;
    if (all_day) {
        // whole days in the owner's zone, midnight to midnight
        const days = @divFloor(lengthOf(e, zones) + 86399, 86400);
        var last = w;
        last.local += @max(days, 1) * 86400;
        end = zones.toUtc(last);
    } else if (at != null and e.end != null and e.end.?.kind == e.start.kind and std.mem.eql(u8, e.end.?.tzid, e.start.tzid)) {
        // an occurrence keeps the wall-clock length in its zone
        var last = e.end.?;
        last.local = w.local + (e.end.?.local - e.start.local);
        end = zones.toUtc(last);
    } else end = start + lengthOf(e, zones);
    return .{ .ev = e, .start = start, .end = end, .all_day = all_day, .zone_known = found.known, .tzid = if (w.kind == .zoned) w.tzid else "" };
}

/// UNTIL as local seconds in the series' zone: a UTC time read there, a
/// date to its end.
fn untilLocal(r: rrule.Rule, e: *const ics.Event, zones: ics.Zones) ?i64 {
    if (r.until.len == 0) return null;
    const w = ics.parseWhenValue(r.until, null, false) catch return null;
    return switch (w.kind) {
        .utc => zones.zoneOf(e.start).toLocal(w.local),
        .date => w.local + 86399,
        else => w.local,
    };
}

/// Whether occurrence `recur` (Unix seconds; `local` its wall-clock
/// time) is one of `e`'s EXDATEs.
fn excluded(e: *const ics.Event, zones: ics.Zones, recur: i64, local: i64) bool {
    for (e.exdates) |x| {
        if (x.kind == .date) {
            if (@divFloor(x.local, 86400) == @divFloor(local, 86400)) return true;
        } else if (zones.toUtc(x) == recur) return true;
    }
    return false;
}

/// A series' occurrences in the window, each replaced by its override.
fn series(a: Allocator, out: *std.ArrayList(Instance), evs: []const ics.Event, idx: usize, zones: ics.Zones, from: i64, to: i64, max: usize) !void {
    const e = &evs[idx];
    const r: rrule.Rule = if (e.rrule.len > 0) rrule.parse(a, e.rrule) catch rrule.Rule{ .unsupported = true } else rrule.Rule{ .unsupported = true };
    const len = lengthOf(e, zones);
    // the window in the series' wall clock, wide enough for any offset and length
    const from_local = from - len - 2 * 86400;
    const to_local = to + 2 * 86400;
    var locals: std.ArrayList(i64) = .empty;
    if (e.rrule.len > 0) {
        try locals.appendSlice(a, try rrule.expand(a, r, e.start.local, untilLocal(r, e, zones), from_local, to_local, max * 4 + 16));
    } else if (e.start.local >= from_local and e.start.local < to_local) try locals.append(a, e.start.local);
    for (e.rdates) |rd| {
        // an RDATE in another form than DTSTART is read on its own
        const local = if (rd.kind == e.start.kind and std.mem.eql(u8, rd.tzid, e.start.tzid)) rd.local else zones.zoneOf(e.start).toLocal(zones.toUtc(rd));
        if (local >= from_local and local < to_local) try locals.append(a, local);
    }
    for (locals.items) |local| {
        var start_w = e.start;
        start_w.local = local;
        const recur = zones.toUtc(start_w);
        if (excluded(e, zones, recur, local)) continue;
        // an override of this occurrence is listed in its own place
        const overridden = for (evs) |o| {
            if (o.recurrence_id) |rid| if (std.mem.eql(u8, o.uid, e.uid) and sameOccurrence(zones, rid, recur, local)) break true;
        } else false;
        if (overridden) continue;
        var i = instanceOf(e, zones, local);
        i.recur = recur;
        i.rule = e.rrule;
        i.unsupported = r.unsupported and e.rrule.len > 0;
        if (overlaps(i, from, to)) try out.append(a, i);
    }
}

fn sameOccurrence(zones: ics.Zones, rid: ics.When, recur: i64, local: i64) bool {
    if (rid.kind == .date) return @divFloor(rid.local, 86400) == @divFloor(local, 86400);
    return zones.toUtc(rid) == recur;
}

// ---- tests ----

const tt = std.testing;

fn utc(y: i64, m: u8, d: u8, hh: i64, mm: i64) i64 {
    return tz.daysFromCivil(y, m, d) * 86400 + hh * 3600 + mm * 60;
}

const vtz_warsaw = "BEGIN:VTIMEZONE\r\nTZID:Europe/Warsaw\r\nBEGIN:STANDARD\r\nDTSTART:19701025T030000\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\nEND:STANDARD\r\nBEGIN:DAYLIGHT\r\nDTSTART:19700329T020000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\n";

/// The team call: Mondays 09:00 Warsaw from 28 Sep; 9 Nov taken out; 16
/// Nov moved to 10:00; 2 Nov moved to Tuesday 3 Nov.
const team_call = "BEGIN:VCALENDAR\r\n" ++ vtz_warsaw ++
    "BEGIN:VEVENT\r\nUID:team\r\nDTSTART;TZID=Europe/Warsaw:20260928T090000\r\nDTEND;TZID=Europe/Warsaw:20260928T093000\r\nSUMMARY:Team call\r\nRRULE:FREQ=WEEKLY;BYDAY=MO\r\nEXDATE;TZID=Europe/Warsaw:20261109T090000\r\nEND:VEVENT\r\n" ++
    "BEGIN:VEVENT\r\nUID:team\r\nRECURRENCE-ID;TZID=Europe/Warsaw:20261116T090000\r\nDTSTART;TZID=Europe/Warsaw:20261116T100000\r\nDTEND;TZID=Europe/Warsaw:20261116T103000\r\nSUMMARY:Team call (later)\r\nEND:VEVENT\r\n" ++
    "BEGIN:VEVENT\r\nUID:team\r\nRECURRENCE-ID;TZID=Europe/Warsaw:20261102T090000\r\nDTSTART;TZID=Europe/Warsaw:20261103T090000\r\nDTEND;TZID=Europe/Warsaw:20261103T093000\r\nSUMMARY:Team call (Tuesday)\r\nEND:VEVENT\r\n" ++
    "END:VCALENDAR\r\n";

test "agenda_across_a_recurrence_and_a_time_zone" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cal = try ics.parse(a, team_call);
    const owner = tz.lookup("Europe/Warsaw").?;
    const zones = try (ics.Zones{ .owner = owner }).of(a, cal, owner);
    const evs = try ics.events(a, cal);
    // 19 Oct to 24 Nov: across the change of 25 Oct
    const got = try expand(a, evs, zones, utc(2026, 10, 19, 0, 0), utc(2026, 11, 24, 0, 0), 100);
    var starts: std.ArrayList(i64) = .empty;
    for (got) |i| try starts.append(a, i.start);
    try tt.expectEqualSlices(i64, &.{
        utc(2026, 10, 19, 7, 0), // 09:00 summer time
        utc(2026, 10, 26, 8, 0), // 09:00 winter time
        utc(2026, 11, 3, 8, 0), // moved to Tuesday
        utc(2026, 11, 16, 9, 0), // moved to 10:00; 9 Nov is gone
        utc(2026, 11, 23, 8, 0),
    }, starts.items);
    try tt.expectEqualStrings("Team call (Tuesday)", got[2].ev.summary);
    try tt.expectEqual(utc(2026, 11, 2, 8, 0), got[2].recur.?);
    try tt.expectEqual(utc(2026, 11, 16, 9, 30), got[3].end);
    try tt.expectEqualStrings("FREQ=WEEKLY;BYDAY=MO", got[4].rule);
    try tt.expectEqual(utc(2026, 11, 23, 8, 0), got[4].recur.?);
    // a window the move took the occurrence out of: 2 Nov alone has nothing
    try tt.expectEqual(@as(usize, 0), (try expand(a, evs, zones, utc(2026, 11, 2, 0, 0), utc(2026, 11, 3, 0, 0), 100)).len);
    // an event that began before the window and goes on into it is in it
    const during = try expand(a, evs, zones, utc(2026, 11, 23, 8, 15), utc(2026, 11, 23, 8, 20), 100);
    try tt.expectEqual(@as(usize, 1), during.len);
}

test "single_all_day_duration_rdate_and_unknown_zone_events" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "BEGIN:VCALENDAR\r\n" ++
        "BEGIN:VEVENT\r\nUID:bday\r\nDTSTART;VALUE=DATE:19901126\r\nDTEND;VALUE=DATE:19901127\r\nRRULE:FREQ=YEARLY\r\nSUMMARY:Anna's birthday\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT\r\n" ++
        "BEGIN:VEVENT\r\nUID:ny\r\nDTSTART;TZID=America/New_York:20261123T090000\r\nDURATION:PT1H\r\nSUMMARY:New York call\r\nEND:VEVENT\r\n" ++
        "BEGIN:VEVENT\r\nUID:mars\r\nDTSTART;TZID=Mars/Olympus:20261123T120000\r\nSUMMARY:Mars\r\nEND:VEVENT\r\n" ++
        "BEGIN:VEVENT\r\nUID:extra\r\nDTSTART:20261101T170000Z\r\nDTEND:20261101T180000Z\r\nRDATE:20261123T170000Z,20261124T170000Z\r\nSUMMARY:Extra\r\nEND:VEVENT\r\n" ++
        "BEGIN:VEVENT\r\nUID:off\r\nDTSTART:20261123T130000Z\r\nDTEND:20261123T140000Z\r\nSTATUS:CANCELLED\r\nSUMMARY:Called off\r\nEND:VEVENT\r\n" ++
        "END:VCALENDAR\r\n";
    const cal = try ics.parse(a, text);
    const owner = tz.lookup("Europe/Warsaw").?;
    const zones = try (ics.Zones{ .owner = owner }).of(a, cal, owner);
    const evs = try ics.events(a, cal);
    // the owner's 23 Nov: 23:00 UTC on the 22nd to 23:00 UTC on the 23rd
    const day = try expand(a, evs, zones, utc(2026, 11, 22, 23, 0), utc(2026, 11, 23, 23, 0), 100);
    var titles: std.ArrayList(u8) = .empty;
    for (day) |i| try titles.print(a, "{s};", .{i.ev.summary});
    try tt.expectEqualStrings("Mars;Called off;New York call;Extra;", titles.items);
    // unknown zone: read as the owner's (12:00 Warsaw = 11:00 UTC), marked
    try tt.expectEqual(utc(2026, 11, 23, 11, 0), day[0].start);
    try tt.expect(!day[0].zone_known);
    try tt.expectEqual(day[0].start, day[0].end);
    try tt.expect(day[1].cancelled());
    // 09:00 New York is 14:00 UTC; an hour long
    try tt.expectEqual(utc(2026, 11, 23, 14, 0), day[2].start);
    try tt.expectEqual(utc(2026, 11, 23, 15, 0), day[2].end);
    try tt.expectEqualStrings("America/New_York", day[2].tzid);
    // an RDATE is an occurrence too
    try tt.expectEqual(utc(2026, 11, 23, 17, 0), day[3].start);
    try tt.expectEqual(utc(2026, 11, 23, 18, 0), day[3].end);
    // the birthday, all day on the owner's 26 Nov
    const bday = try expand(a, evs, zones, utc(2026, 11, 26, 12, 0), utc(2026, 11, 26, 13, 0), 100);
    try tt.expectEqual(@as(usize, 1), bday.len);
    try tt.expect(bday[0].all_day);
    try tt.expectEqual(utc(2026, 11, 25, 23, 0), bday[0].start);
    try tt.expectEqual(utc(2026, 11, 26, 23, 0), bday[0].end);
    try tt.expect(bday[0].ev.transparent);
}

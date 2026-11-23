//! Upkeep: things with an interval (the boiler's service yearly, filters
//! every 3 months, the smoke alarms' test monthly, the car's service by
//! its distance or a date) and documents with an end day (insurance, the
//! car's inspection, warranties), in `state/upkeep` (JSON, written whole).
//! When each falls due, and the words said, are worked out here; harness
//! posts them (core.zig). Days are the owner's day numbers (since
//! 1970-01-01).
const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

pub const Item = struct {
    name: []const u8 = "",
    /// By time: months, or days.
    months: u16 = 0,
    days: u16 = 0,
    /// By the car's distance (km).
    km: u32 = 0,
    /// The day it was last done (or counted from).
    last: i64 = 0,
    /// The car's odometer then (0: its first reading).
    last_km: f64 = 0,
    /// A document's end day (0: no document).
    ends: i64 = 0,
    /// Months a document renews by (0: it doesn't, like a warranty).
    renew: u16 = 0,
    /// The due day the week's line and the day's line were said for.
    said_week: i64 = 0,
    said_day: i64 = 0,
    /// The open line's inbox item (its [Done]); 0: none.
    item: u64 = 0,
};

/// The car's odometer: its first reading and its last (km).
pub const Odo = struct { first_day: i64 = 0, first_km: f64 = 0, last_day: i64 = 0, last_km: f64 = 0 };

pub const State = struct {
    items: []const Item = &.{},
    odo: Odo = .{},
    /// The day the day's pass last ran.
    pass: i64 = 0,
    /// The usual ones still to offer (`/setup upkeep`).
    offers: []const []const u8 = &.{},
};

pub fn parseState(a: Allocator, text: []const u8) !State {
    return std.json.parseFromSliceLeaky(State, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn stateText(a: Allocator, st: State) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, st, .{});
}

pub const max_items = 40;
pub const max_name = 60;

// ---- dates ----

const months_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const months_long = [_][]const u8{ "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };
const days_short = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

fn daysIn(m: u8, y: i64) u8 {
    return switch (m) {
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Day `day` and `n` months on (the 31st on a shorter month's last).
pub fn addMonths(day: i64, n: u16) i64 {
    const c = util.civil(day);
    const total: i64 = c.y * 12 + (c.m - 1) + n;
    const y = @divFloor(total, 12);
    const m: u8 = @intCast(@mod(total, 12) + 1);
    return util.daysFromCivil(y, m, @min(c.d, daysIn(m, y)));
}

/// "Wed 2 Dec", or "Wed 2 Dec 2027" when not this year (`today`'s).
pub fn dayText(a: Allocator, day: i64, today: i64) ![]const u8 {
    const c = util.civil(day);
    const now = util.civil(today);
    if (c.y == now.y) return std.fmt.allocPrint(a, "{s} {d} {s}", .{ days_short[util.weekday(day)], c.d, months_short[c.m - 1] });
    return std.fmt.allocPrint(a, "{s} {d} {s} {d}", .{ days_short[util.weekday(day)], c.d, months_short[c.m - 1], c.y });
}

/// "12 Mar 2027".
pub fn dateText(a: Allocator, day: i64) ![]const u8 {
    const c = util.civil(day);
    return std.fmt.allocPrint(a, "{d} {s} {d}", .{ c.d, months_short[c.m - 1], c.y });
}

/// A date the owner writes: 2027-03-12, 12.03.2027, 12 Mar 2027, 12
/// March 2027, today, yesterday.
pub fn parseDate(text: []const u8, today: i64) ?i64 {
    const s = std.mem.trim(u8, text, " \t.,");
    if (std.ascii.eqlIgnoreCase(s, "today")) return today;
    if (std.ascii.eqlIgnoreCase(s, "yesterday")) return today - 1;
    if (s.len == 10 and s[4] == '-' and s[7] == '-') {
        const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
        const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
        const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
        return checked(y, m, d);
    }
    if (std.mem.count(u8, s, ".") == 2) {
        var it = std.mem.splitScalar(u8, s, '.');
        const d = std.fmt.parseInt(u8, it.next().?, 10) catch return null;
        const m = std.fmt.parseInt(u8, it.next().?, 10) catch return null;
        const y = std.fmt.parseInt(i64, it.next().?, 10) catch return null;
        return checked(y, m, d);
    }
    var it = std.mem.tokenizeAny(u8, s, " ,");
    const d = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const mw = it.next() orelse return null;
    const y = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or mw.len < 3) return null;
    const m: u8 = for (months_long, 0..) |name, i| {
        if (mw.len <= name.len and std.ascii.startsWithIgnoreCase(name, mw)) break @intCast(i + 1);
    } else return null;
    return checked(y, m, d);
}

fn checked(y: i64, m: u8, d: u8) ?i64 {
    if (y < 2000 or y > 2200 or m < 1 or m > 12 or d < 1 or d > daysIn(m, y)) return null;
    return util.daysFromCivil(y, m, d);
}

// ---- the car's distance ----

/// carcloud's `car_status` line "odometer: 18234.6 km" (miles as km).
pub fn odometer(text: []const u8) ?f64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.ascii.startsWithIgnoreCase(l, "odometer:")) continue;
        var w = std.mem.tokenizeScalar(u8, l["odometer:".len..], ' ');
        const v = std.fmt.parseFloat(f64, w.next() orelse return null) catch return null;
        const unit = w.next() orelse "km";
        if (!(v >= 0) or std.math.isInf(v)) return null;
        return if (std.ascii.startsWithIgnoreCase(unit, "mi")) v * 1.609344 else v;
    }
    return null;
}

/// A reading of the odometer on `day`: kept, and a distance item counted
/// from no reading yet counts from this one.
pub fn noteReading(a: Allocator, st: State, day: i64, km: f64) !State {
    var out = st;
    if (out.odo.first_day == 0) out.odo = .{ .first_day = day, .first_km = km };
    out.odo.last_day = day;
    out.odo.last_km = km;
    const items = try a.dupe(Item, st.items);
    for (items) |*it| if (it.km > 0 and it.last_km == 0) {
        it.last_km = km;
    };
    out.items = items;
    return out;
}

/// The car's km a day: from readings at least 7 days apart, else 40.
pub fn rate(o: Odo) f64 {
    const days = o.last_day - o.first_day;
    if (days >= 7 and o.last_km > o.first_km) return (o.last_km - o.first_km) / @as(f64, @floatFromInt(days));
    return 40;
}

fn kmText(a: Allocator, km: f64) ![]const u8 {
    const n: u64 = @intFromFloat(@round(@max(km, 0)));
    if (n < 1000) return std.fmt.allocPrint(a, "{d} km", .{n});
    return std.fmt.allocPrint(a, "{d},{d:0>3} km", .{ n / 1000, n % 1000 });
}

// ---- when it falls due ----

pub const Due = struct {
    /// The day, by time (or a document's end), or estimated from the
    /// distance; whichever comes first.
    day: i64,
    /// Due by the distance first: at this km.
    at_km: ?f64 = null,
};

/// When item `it` falls due; null when it can't say (a distance item
/// before any reading, with no time interval).
pub fn due(it: Item, odo: Odo) ?Due {
    if (it.ends > 0) return .{ .day = it.ends };
    var best: ?Due = null;
    if (it.months > 0) best = .{ .day = addMonths(it.last, it.months) };
    if (it.days > 0) {
        const d = it.last + it.days;
        if (best == null or d < best.?.day) best = .{ .day = d };
    }
    if (it.km > 0 and odo.last_day > 0 and it.last_km > 0) {
        const at = it.last_km + @as(f64, @floatFromInt(it.km));
        const left = at - odo.last_km;
        const d = if (left <= 0) odo.last_day else odo.last_day + @as(i64, @intFromFloat(@ceil(left / rate(odo))));
        if (best == null or d < best.?.day) best = .{ .day = d, .at_km = at };
    }
    return best;
}

pub const Kind = enum { week, day, late };

/// A line to say: item `index`, its due day (what was said is keyed by
/// it), its words and its button ("" none).
pub const Line = struct { index: usize, kind: Kind, due: i64, text: []const u8, button: []const u8 };

/// The lines due on `today`: a week before (or less, for one added late),
/// on the day, or once late, each once per due day.
pub fn lines(a: Allocator, st: State, today: i64) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    for (st.items, 0..) |it, i| {
        const d = due(it, st.odo) orelse continue;
        const button: []const u8 = if (it.ends > 0) (if (it.renew > 0) "Renewed" else "") else "Done";
        // what was said is keyed by the due day, or (by distance) the km, negative
        const key: i64 = if (d.at_km) |at| -@as(i64, @intFromFloat(at)) else d.day;
        const reached = if (d.at_km) |at| st.odo.last_km >= at else today >= d.day;
        if (reached) {
            if (it.said_day == key) continue;
            const kind: Kind = if (today == d.day or d.at_km != null) .day else .late;
            try out.append(a, .{ .index = i, .kind = kind, .due = key, .text = try lineText(a, it, st.odo, d, kind, today), .button = button });
        } else if (d.day - today <= 7) {
            if (it.said_week == key) continue;
            try out.append(a, .{ .index = i, .kind = .week, .due = key, .text = try lineText(a, it, st.odo, d, .week, today), .button = button });
        }
    }
    return out.items;
}

fn lineText(a: Allocator, it: Item, odo: Odo, d: Due, kind: Kind, today: i64) ![]const u8 {
    const name = it.name;
    if (d.at_km) |at| return switch (kind) {
        .week => std.fmt.allocPrint(a, "{s} is due in about {s} (at {s}; the car is at {s}).", .{ name, try kmText(a, at - odo.last_km), try kmText(a, at), try kmText(a, odo.last_km) }),
        else => std.fmt.allocPrint(a, "{s} is due: the car is at {s} (due at {s}).", .{ name, try kmText(a, odo.last_km), try kmText(a, at) }),
    };
    const when = try dayText(a, d.day, today);
    if (it.ends > 0) return switch (kind) {
        .week => if (d.day - today == 7) std.fmt.allocPrint(a, "{s} ends in a week ({s}).", .{ name, when }) else if (d.day - today == 1) std.fmt.allocPrint(a, "{s} ends tomorrow ({s}).", .{ name, when }) else std.fmt.allocPrint(a, "{s} ends in {d} days ({s}).", .{ name, d.day - today, when }),
        .day => std.fmt.allocPrint(a, "{s} ends today.", .{name}),
        .late => std.fmt.allocPrint(a, "{s} ended on {s}.", .{ name, when }),
    };
    return switch (kind) {
        .week => if (d.day - today == 7) std.fmt.allocPrint(a, "{s} is due in a week ({s}).", .{ name, when }) else if (d.day - today == 1) std.fmt.allocPrint(a, "{s} is due tomorrow ({s}).", .{ name, when }) else std.fmt.allocPrint(a, "{s} is due in {d} days ({s}).", .{ name, d.day - today, when }),
        .day => std.fmt.allocPrint(a, "{s} is due today.", .{name}),
        .late => std.fmt.allocPrint(a, "{s} was due on {s}.", .{ name, when }),
    };
}

/// Item `it` done on `day` (the car at `km`, 0 not known): counted from
/// then; a document renewed: its end a renewal on. The lines said are
/// forgotten (the next due day has its own).
pub fn done(it: Item, day: i64, km: f64) Item {
    var out = it;
    out.item = 0;
    if (it.ends > 0) {
        if (it.renew > 0) out.ends = addMonths(it.ends, it.renew);
        return out;
    }
    out.last = day;
    if (it.km > 0 and km > 0) out.last_km = km;
    return out;
}

/// What is said once it is done: "Boiler service done today; next due 23
/// Nov 2027." ("on 12 Mar" for another day).
pub fn doneText(a: Allocator, it: Item, odo: Odo, day: i64, today: i64) ![]const u8 {
    if (it.ends > 0) {
        if (it.renew == 0) return std.fmt.allocPrint(a, "{s}: noted.", .{it.name});
        return std.fmt.allocPrint(a, "{s} renewed: it ends {s}.", .{ it.name, try dateText(a, it.ends) });
    }
    const when = if (day == today) "today" else try std.fmt.allocPrint(a, "on {s}", .{try dateText(a, day)});
    var next: std.ArrayList([]const u8) = .empty;
    if (it.km > 0 and it.last_km > 0) try next.append(a, try std.fmt.allocPrint(a, "at {s}", .{try kmText(a, it.last_km + @as(f64, @floatFromInt(it.km)))}));
    var by_time = it;
    by_time.km = 0;
    if (due(by_time, odo)) |d| try next.append(a, try dateText(a, d.day));
    if (next.items.len == 0) return std.fmt.allocPrint(a, "{s} done {s}.", .{ it.name, when });
    return std.fmt.allocPrint(a, "{s} done {s}; next due {s}.", .{ it.name, when, try std.mem.join(a, " or ", next.items) });
}

/// "yearly", "every 3 months", "every 15,000 km or yearly".
pub fn everyText(a: Allocator, it: Item) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (it.km > 0) try parts.append(a, try std.fmt.allocPrint(a, "every {s}", .{try kmText(a, @floatFromInt(it.km))}));
    if (it.months == 12) try parts.append(a, "yearly") else if (it.months == 1) try parts.append(a, "monthly") else if (it.months > 0) try parts.append(a, try std.fmt.allocPrint(a, "every {d} months", .{it.months}));
    if (it.days == 7) try parts.append(a, "weekly") else if (it.days > 0) try parts.append(a, try std.fmt.allocPrint(a, "every {d} days", .{it.days}));
    return std.mem.join(a, " or ", parts.items);
}

/// A line of `/upkeep`.
pub fn listLine(a: Allocator, it: Item, odo: Odo, today: i64) ![]const u8 {
    if (it.ends > 0) {
        const renews = if (it.renew == 12) " (renews yearly)" else if (it.renew > 0) try std.fmt.allocPrint(a, " (renews every {d} months)", .{it.renew}) else "";
        const verb: []const u8 = if (it.ends < today) "ended" else "ends";
        return std.fmt.allocPrint(a, "{s}: {s} {s}{s}.", .{ it.name, verb, try dateText(a, it.ends), renews });
    }
    const d = due(it, odo) orelse return std.fmt.allocPrint(a, "{s}: {s}; due once the car's odometer is read.", .{ it.name, try everyText(a, it) });
    const when = if (d.at_km) |at| try std.fmt.allocPrint(a, "at {s} (the car is at {s})", .{ try kmText(a, at), try kmText(a, odo.last_km) }) else try dateText(a, d.day);
    const late: []const u8 = if (d.day < today) ", overdue" else if (d.day == today) ", today" else "";
    return std.fmt.allocPrint(a, "{s}: {s}; next {s}{s}.", .{ it.name, try everyText(a, it), when, late });
}

// ---- what the owner writes ----

/// `/upkeep add NAME every N months|years|weeks|days|km [or every …]
/// [last DATE]` and `/upkeep add NAME ends DATE [renews every N
/// months|years]`, read on `today` (`km`: the car now, 0 not known).
pub fn parseAdd(a: Allocator, text: []const u8, today: i64, km: f64) !Item {
    const low = try a.dupe(u8, text);
    for (low) |*ch| ch.* = std.ascii.toLower(ch.*);
    // the name ends at the first " every " or " ends "
    const e1 = std.mem.indexOf(u8, low, " every ");
    const e2 = std.mem.indexOf(u8, low, " ends ");
    const cut = if (e1 != null and e2 != null) @min(e1.?, e2.?) else e1 orelse e2 orelse return error.Bad;
    const name = std.mem.trim(u8, text[0..cut], " \t");
    if (name.len == 0 or name.len > max_name) return error.Bad;
    var it: Item = .{ .name = name, .last = today };
    var words = std.mem.tokenizeAny(u8, low[cut..], " \t,");
    while (words.next()) |w| {
        const eql = std.mem.eql;
        if (eql(u8, w, "or") or eql(u8, w, "and")) continue;
        if (eql(u8, w, "every")) {
            var n: u32 = 1;
            var unit = words.next() orelse return error.Bad;
            if (std.fmt.parseInt(u32, std.mem.trimEnd(u8, unit, "km"), 10)) |x| {
                n = x;
                // "15000km" in one word
                unit = if (std.mem.endsWith(u8, unit, "km")) "km" else words.next() orelse return error.Bad;
            } else |_| {}
            if (n == 0) return error.Bad;
            try every(&it, n, unit);
        } else if (eql(u8, w, "ends")) {
            const rest = std.mem.trim(u8, words.rest(), " ");
            const at_renews = std.mem.indexOf(u8, rest, " renews ");
            it.ends = parseDate(rest[0 .. at_renews orelse rest.len], today) orelse return error.BadDate;
            it.last = 0;
            it.renew = renewsByName(low[0..cut]);
            if (at_renews) |r| {
                var rw = std.mem.tokenizeAny(u8, rest[r + " renews ".len ..], " ");
                if (!std.mem.eql(u8, rw.next() orelse "", "every")) return error.Bad;
                var n: u32 = 1;
                var unit = rw.next() orelse return error.Bad;
                if (std.fmt.parseInt(u32, unit, 10)) |x| {
                    n = x;
                    unit = rw.next() orelse return error.Bad;
                } else |_| {}
                var tmp: Item = .{};
                try every(&tmp, n, unit);
                if (tmp.months == 0) return error.Bad;
                it.renew = tmp.months;
            }
            break;
        } else if (eql(u8, w, "last") or eql(u8, w, "done")) {
            const rest = std.mem.trim(u8, words.rest(), " ");
            it.last = parseDate(rest, today) orelse return error.BadDate;
            break;
        } else return error.Bad;
    }
    if (it.ends == 0 and it.months == 0 and it.days == 0 and it.km == 0) return error.Bad;
    if (it.km > 0) it.last_km = km;
    return it;
}

fn every(it: *Item, n: u32, unit_in: []const u8) !void {
    const unit = std.mem.trimEnd(u8, unit_in, "s");
    const eql = std.mem.eql;
    if (eql(u8, unit, "month")) it.months = @intCast(@min(n, 120)) else if (eql(u8, unit, "year")) it.months = @intCast(@min(n * 12, 120)) else if (eql(u8, unit, "week")) it.days = @intCast(@min(n * 7, 3650)) else if (eql(u8, unit, "day")) it.days = @intCast(@min(n, 3650)) else if (eql(u8, unit, "km")) {
        if (n < 100) return error.Bad;
        it.km = n;
    } else return error.Bad;
}

/// Insurance, an inspection and a registration renew yearly; others
/// (a warranty) don't.
fn renewsByName(low_name: []const u8) u16 {
    for ([_][]const u8{ "insurance", "inspection", "registration", "ubezpieczenie", "przegląd", "oc" }) |w| if (hasWord(low_name, w)) return 12;
    return 0;
}

fn hasWord(low: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, low, " \t,.;:!?()");
    while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// The item `name` names: whole name, else the one whose name starts
/// with it, else the one with it as a word (case aside); null: none, or
/// several.
pub fn find(items: []const Item, name: []const u8) ?usize {
    const n = std.mem.trim(u8, name, " \t");
    if (n.len == 0) return null;
    for (items, 0..) |it, i| if (std.ascii.eqlIgnoreCase(it.name, n)) return i;
    var found: ?usize = null;
    for (items, 0..) |it, i| if (std.ascii.startsWithIgnoreCase(it.name, n)) {
        if (found != null) return null;
        found = i;
    };
    return found;
}

/// Words of a name that say nothing of which one it is.
const generic = [_][]const u8{ "service", "test", "check", "the", "a", "of", "change", "my", "our" };

const done_verbs = [_][]const u8{ "serviced", "replaced", "changed", "cleaned", "tested", "checked", "done", "renewed", "inspected", "fixed" };
const not_done = [_][]const u8{ "will", "tomorrow", "next", "should", "need", "needs", "must", "when", "remind", "not", "isn't", "wasn't", "hasn't", "haven't", "due" };

fn sameWord(x: []const u8, y: []const u8) bool {
    const a1 = std.mem.trimEnd(u8, x, "s");
    const b1 = std.mem.trimEnd(u8, y, "s");
    return a1.len > 1 and std.mem.eql(u8, a1, b1);
}

/// What the owner says they did: "the boiler was serviced today", "changed
/// the filters yesterday", "the car was serviced on 2026-11-20 at 45200
/// km". Null: it says no item done (a question, a future, two items).
pub const Said = struct { index: usize, day: i64, km: f64 = 0 };

pub fn doneWords(a: Allocator, items: []const Item, text: []const u8, today: i64) !?Said {
    if (std.mem.indexOfScalar(u8, text, '?') != null) return null;
    const low = try a.dupe(u8, std.mem.trim(u8, text, " \t\r\n.!"));
    for (low) |*ch| ch.* = std.ascii.toLower(ch.*);
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, low, " \t,;:!");
    while (it.next()) |w| try words.append(a, w);
    if (words.items.len == 0 or words.items.len > 16) return null;
    var verb = false;
    for (words.items) |w| {
        for (not_done) |x| if (std.mem.eql(u8, w, x)) return null;
        for (done_verbs) |x| if (std.mem.eql(u8, w, x)) {
            verb = true;
        };
    }
    if (!verb) return null;
    // the item whose telling words are all there, the most of them
    var best: ?usize = null;
    var best_n: usize = 0;
    var tie = false;
    for (items, 0..) |item, i| {
        var keys: std.ArrayList([]const u8) = .empty;
        var nt = std.mem.tokenizeAny(u8, item.name, " \t");
        while (nt.next()) |w| {
            const lw = try std.ascii.allocLowerString(a, w);
            const is_generic = for (generic) |g| {
                if (std.mem.eql(u8, g, lw)) break true;
            } else false;
            if (!is_generic) try keys.append(a, lw);
        }
        if (keys.items.len == 0) continue;
        const all = for (keys.items) |k| {
            const there = for (words.items) |w| {
                if (sameWord(w, k)) break true;
            } else false;
            if (!there) break false;
        } else true;
        if (!all) continue;
        if (keys.items.len > best_n) {
            best = i;
            best_n = keys.items.len;
            tie = false;
        } else if (keys.items.len == best_n) tie = true;
    }
    const index = best orelse return null;
    if (tie) return null;
    var day = today;
    var km: f64 = 0;
    for (words.items, 0..) |w, i| {
        if (std.mem.eql(u8, w, "yesterday")) day = today - 1;
        if (parseDate(w, today)) |d| {
            if (std.mem.indexOfScalar(u8, w, '-') != null or std.mem.count(u8, w, ".") == 2) day = d;
        }
        // "on 12 march 2026"
        if (std.mem.eql(u8, w, "on") and i + 3 < words.items.len + 1) {
            const three = try std.mem.join(a, " ", words.items[i + 1 .. @min(i + 4, words.items.len)]);
            if (parseDate(three, today)) |d| day = d;
        }
        // "at 45200 km", "at 45,200 km"
        if (std.mem.eql(u8, w, "km") and i > 0) {
            const num = try std.mem.replaceOwned(u8, a, words.items[i - 1], ".", "");
            km = std.fmt.parseFloat(f64, num) catch km;
        }
        if (std.mem.endsWith(u8, w, "km") and w.len > 2) km = std.fmt.parseFloat(f64, w[0 .. w.len - 2]) catch km;
    }
    if (day > today) return null;
    return .{ .index = index, .day = day, .km = km };
}

// ---- the usual ones ----

pub const Usual = struct {
    key: []const u8,
    name: []const u8,
    months: u16 = 0,
    km: u32 = 0,
    /// A document: its end day asked.
    doc: bool = false,
    renew: u16 = 0,
    /// Offered with a car only.
    car: bool = false,
    sentence: []const u8,
};

pub const usual = [_]Usual{
    .{ .key = "boiler", .name = "Boiler service", .months = 12, .sentence = "Boiler service, once a year: I tell you a week before it's due and on the day." },
    .{ .key = "filters", .name = "Filters", .months = 3, .sentence = "Filters (the cooker hood, the air or water filters), every 3 months." },
    .{ .key = "smoke", .name = "Smoke alarm test", .months = 1, .sentence = "Smoke alarm test, monthly: each alarm's test button." },
    .{ .key = "car-service", .name = "Car service", .months = 12, .km = 15000, .car = true, .sentence = "Car service, every 15,000 km or once a year, by the car's odometer." },
    .{ .key = "car-insurance", .name = "Car insurance", .doc = true, .renew = 12, .car = true, .sentence = "Car insurance: reply with the day it ends (like 15 Jan 2027), and I tell you a week before and on the day." },
    .{ .key = "car-inspection", .name = "Car inspection", .doc = true, .renew = 12, .car = true, .sentence = "Car inspection: reply with the day it's due (like 15 Jan 2027), and I tell you a week before and on the day." },
};

pub fn usualOf(key: []const u8) ?Usual {
    for (usual) |u| if (std.mem.eql(u8, u.key, key)) return u;
    return null;
}

/// A usual one as an item, counted from `last` (a document ending then).
pub fn fromUsual(u: Usual, last: i64, km: f64) Item {
    if (u.doc) return .{ .name = u.name, .ends = last, .renew = u.renew };
    return .{ .name = u.name, .months = u.months, .km = u.km, .last = last, .last_km = if (u.km > 0) km else 0 };
}

// ---- tests ----

const t = std.testing;

fn dayOn(y: i64, m: u8, d: u8) i64 {
    return util.daysFromCivil(y, m, d);
}

test "intervals_and_documents_fall_due" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const today = dayOn(2026, 11, 23);
    const boiler = try parseAdd(a, "Boiler service every year last 2025-11-30", today, 0);
    try t.expectEqual(12, boiler.months);
    try t.expectEqual(dayOn(2026, 11, 30), due(boiler, .{}).?.day);
    const filters = try parseAdd(a, "Filters every 3 months", today, 0);
    try t.expectEqual(dayOn(2027, 2, 23), due(filters, .{}).?.day);
    const insurance = try parseAdd(a, "Car insurance ends 15 Jan 2027", today, 0);
    try t.expectEqual(12, insurance.renew);
    try t.expectEqual(dayOn(2027, 1, 15), insurance.ends);
    const warranty = try parseAdd(a, "Dishwasher warranty ends 2026-11-24", today, 0);
    try t.expectEqual(0, warranty.renew);
    const six = try parseAdd(a, "Home insurance ends 1.12.2026 renews every 6 months", today, 0);
    try t.expectEqual(6, six.renew);
    try t.expectEqual(dayOn(2027, 1, 31), addMonths(dayOn(2026, 12, 31), 1));
    try t.expectEqual(dayOn(2027, 2, 28), addMonths(dayOn(2026, 1, 31), 13));
    for ([_][]const u8{ "Boiler", "Boiler every", "Boiler every fortnight", "Boiler ends someday", "every 3 months", "Car every 5 km" }) |x| {
        if (parseAdd(a, x, today, 0)) |_| {
            std.debug.print("read: {s}\n", .{x});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // the lines: a week before (or less), on the day, late once
    const st: State = .{ .items = &.{ boiler, filters, insurance, warranty } };
    const ls = try lines(a, st, today);
    try t.expectEqual(2, ls.len);
    try t.expectEqualStrings("Boiler service is due in a week (Mon 30 Nov).", ls[0].text);
    try t.expectEqualStrings("Done", ls[0].button);
    try t.expectEqualStrings("Dishwasher warranty ends tomorrow (Tue 24 Nov).", ls[1].text);
    try t.expectEqualStrings("", ls[1].button);
    var items = try a.dupe(Item, st.items);
    items[0].said_week = ls[0].due;
    const on_day = try lines(a, .{ .items = items }, dayOn(2026, 11, 30));
    try t.expectEqualStrings("Boiler service is due today.", on_day[0].text);
    items[0].said_day = on_day[0].due;
    try t.expectEqual(0, (try lines(a, .{ .items = items[0..1] }, dayOn(2026, 12, 5))).len);
    // added late: once
    const late = try lines(a, .{ .items = &.{try parseAdd(a, "Chimney sweep every year last 2025-01-10", today, 0)} }, today);
    try t.expectEqualStrings("Chimney sweep was due on Sat 10 Jan.", late[0].text);
    const ins = try lines(a, .{ .items = &.{insurance} }, dayOn(2027, 1, 8));
    try t.expectEqualStrings("Car insurance ends in a week (Fri 15 Jan).", ins[0].text);
    try t.expectEqualStrings("Renewed", ins[0].button);
    // done and renewed
    const b2 = done(boiler, dayOn(2026, 11, 28), 0);
    try t.expectEqual(dayOn(2027, 11, 28), due(b2, .{}).?.day);
    try t.expectEqualStrings("Boiler service done today; next due 28 Nov 2027.", try doneText(a, b2, .{}, dayOn(2026, 11, 28), dayOn(2026, 11, 28)));
    const ins2 = done(insurance, today, 0);
    try t.expectEqual(dayOn(2028, 1, 15), ins2.ends);
    try t.expectEqualStrings("Car insurance renewed: it ends 15 Jan 2028.", try doneText(a, ins2, .{}, today, today));
    try t.expectEqualStrings("Boiler service: yearly; next 30 Nov 2026.", try listLine(a, boiler, .{}, today));
    try t.expectEqualStrings("Car insurance: ends 15 Jan 2027 (renews yearly).", try listLine(a, insurance, .{}, today));
    try t.expectEqual(dayOn(2026, 3, 12), parseDate("12 March 2026", today).?);
    try t.expectEqual(today - 1, parseDate("yesterday", today).?);
    try t.expect(parseDate("31 Feb 2026", today) == null);
}

test "the_cars_distance" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const today = dayOn(2026, 11, 23);
    try t.expectEqual(18234.6, odometer("battery: 64%\r\nodometer: 18234.6 km\r\n").?);
    try t.expectApproxEqAbs(@as(f64, 16093.44), odometer("odometer: 10000 mi").?, 0.01);
    try t.expect(odometer("battery: 64%") == null);
    // added before any reading: counted from the first
    const svc = try parseAdd(a, "Car service every 15000 km or every year", today, 0);
    try t.expectEqual(15000, svc.km);
    try t.expectEqual(12, svc.months);
    var st: State = .{ .items = &.{svc} };
    st = try noteReading(a, st, today, 30000);
    try t.expectEqual(30000, st.items[0].last_km);
    // three weeks on, 50 km a day: 1050 km on
    st = try noteReading(a, st, today + 21, 31050);
    try t.expectEqual(50, rate(st.odo));
    const d = due(st.items[0], st.odo).?;
    try t.expectEqual(45000, d.at_km.?);
    // a week of driving before: 44,650 km
    st = try noteReading(a, st, today + 300, 44600);
    try t.expectEqual(0, (try lines(a, st, today + 300)).len);
    st = try noteReading(a, st, today + 301, 44700);
    const wk = try lines(a, st, today + 301);
    try t.expectEqualStrings("Car service is due in about 300 km (at 45,000 km; the car is at 44,700 km).", wk[0].text);
    var items = try a.dupe(Item, st.items);
    items[0].said_week = wk[0].due;
    st.items = items;
    st = try noteReading(a, st, today + 308, 45120);
    const at = try lines(a, st, today + 308);
    try t.expectEqualStrings("Car service is due: the car is at 45,120 km (due at 45,000 km).", at[0].text);
    // done at the km said
    const s2 = done(st.items[0], today + 309, 45200);
    try t.expectEqualStrings("Car service done today; next due at 60,200 km or 28 Sep 2028.", try doneText(a, s2, st.odo, today + 309, today + 309));
}

test "done_words_are_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const today = dayOn(2026, 11, 23);
    const items = [_]Item{
        .{ .name = "Boiler service", .months = 12, .last = today - 300 },
        .{ .name = "Filters", .months = 3, .last = today - 80 },
        .{ .name = "Smoke alarm test", .months = 1, .last = today - 20 },
        .{ .name = "Car service", .months = 12, .km = 15000, .last = today - 200 },
        .{ .name = "Car insurance", .ends = today + 30, .renew = 12 },
    };
    const b = (try doneWords(a, &items, "The boiler was serviced today.", today)).?;
    try t.expectEqual(0, b.index);
    try t.expectEqual(today, b.day);
    const f = (try doneWords(a, &items, "changed the filter yesterday", today)).?;
    try t.expectEqual(1, f.index);
    try t.expectEqual(today - 1, f.day);
    try t.expectEqual(2, (try doneWords(a, &items, "smoke alarms tested", today)).?.index);
    const car = (try doneWords(a, &items, "the car was serviced on 2026-11-20 at 45200 km", today)).?;
    try t.expectEqual(3, car.index);
    try t.expectEqual(today - 3, car.day);
    try t.expectEqual(45200, car.km);
    try t.expectEqual(4, (try doneWords(a, &items, "car insurance renewed", today)).?.index);
    try t.expectEqual(today - 2, (try doneWords(a, &items, "boiler serviced on 21 November 2026", today)).?.day);
    for ([_][]const u8{ "was the boiler serviced?", "the boiler needs a service", "remind me when the boiler is due", "the boiler will be serviced tomorrow", "hello", "the oven was cleaned today", "done" }) |x| {
        if (try doneWords(a, &items, x, today)) |s| {
            std.debug.print("{s}: {d}\n", .{ x, s.index });
            return error.TestUnexpectedResult;
        }
    }
    try t.expectEqual(0, find(&items, "boiler").?);
    try t.expectEqual(4, find(&items, "car insurance").?);
    try t.expect(find(&items, "car") == null);
}

test "upkeep_round_trips" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st: State = .{ .items = &.{.{ .name = "Boiler service", .months = 12, .last = 20000, .said_week = 20358, .item = 7 }}, .odo = .{ .first_day = 1, .first_km = 2.5, .last_day = 3, .last_km = 4.5 }, .pass = 20001, .offers = &.{"filters"} };
    const back = try parseState(a, try std.mem.replaceOwned(u8, a, try stateText(a, st), ",", ",\r\n"));
    try t.expectEqualStrings("Boiler service", back.items[0].name);
    try t.expectEqual(7, back.items[0].item);
    try t.expectEqual(4.5, back.odo.last_km);
    try t.expectEqualStrings("filters", back.offers[0]);
    const u = usualOf("car-service").?;
    const it = fromUsual(u, 20000, 18234.6);
    try t.expectEqual(15000, it.km);
    try t.expectEqual(18234.6, it.last_km);
    try t.expectEqual(20000, fromUsual(usualOf("car-insurance").?, 20000, 0).ends);
}

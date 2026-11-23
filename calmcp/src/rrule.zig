//! Recurrence rules (RFC 5545 RRULE), the common ones: DAILY, WEEKLY,
//! MONTHLY and YEARLY with INTERVAL, COUNT, UNTIL, BYDAY (with ordinals:
//! 2TU, -1FR), BYMONTHDAY and BYMONTH. Expanded in the event's own wall
//! clock (local seconds), so a weekly 09:00 stays 09:00 when summer time
//! starts or ends; the caller reads each time in the event's zone. Parts it
//! doesn't expand (BYSETPOS, BYWEEKNO, BYYEARDAY, BYHOUR, finer
//! frequencies) mark the rule `unsupported`: only its first time is given.
const std = @import("std");
const tz = @import("tz.zig");
const Allocator = std.mem.Allocator;

pub const Freq = enum { daily, weekly, monthly, yearly };

/// A BYDAY item: the `n`th (0: every) weekday `wd` (0 = Sunday).
pub const Day = struct { n: i8 = 0, wd: u3 };

pub const Rule = struct {
    freq: Freq = .daily,
    interval: u32 = 1,
    count: ?u32 = null,
    /// UNTIL as written ("20261231T225959Z", "20261231"); "": none.
    until: []const u8 = "",
    byday: []const Day = &.{},
    bymonthday: []const i8 = &.{},
    bymonth: []const u8 = &.{},
    /// The first day of the week (WKST), 1 = Monday by default.
    wkst: u3 = 1,
    unsupported: bool = false,
};

const day_names = [_][]const u8{ "SU", "MO", "TU", "WE", "TH", "FR", "SA" };

fn weekdayOf(s: []const u8) ?u3 {
    for (day_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, s)) return @intCast(i);
    return null;
}

pub fn parse(a: Allocator, text: []const u8) error{ BadRule, OutOfMemory }!Rule {
    var r: Rule = .{};
    var have_freq = false;
    var byday: std.ArrayList(Day) = .empty;
    var bymonthday: std.ArrayList(i8) = .empty;
    var bymonth: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.BadRule;
        const k = part[0..eq];
        const v = part[eq + 1 ..];
        const is = std.ascii.eqlIgnoreCase;
        if (is(k, "FREQ")) {
            have_freq = true;
            if (is(v, "DAILY")) r.freq = .daily else if (is(v, "WEEKLY")) r.freq = .weekly else if (is(v, "MONTHLY")) r.freq = .monthly else if (is(v, "YEARLY")) r.freq = .yearly else if (is(v, "HOURLY") or is(v, "MINUTELY") or is(v, "SECONDLY")) r.unsupported = true else return error.BadRule;
        } else if (is(k, "INTERVAL")) {
            r.interval = std.fmt.parseInt(u32, v, 10) catch return error.BadRule;
            if (r.interval == 0) return error.BadRule;
        } else if (is(k, "COUNT")) {
            r.count = std.fmt.parseInt(u32, v, 10) catch return error.BadRule;
        } else if (is(k, "UNTIL")) {
            r.until = v;
        } else if (is(k, "WKST")) {
            r.wkst = weekdayOf(v) orelse return error.BadRule;
        } else if (is(k, "BYDAY")) {
            var days = std.mem.splitScalar(u8, v, ',');
            while (days.next()) |d| {
                if (d.len < 2) return error.BadRule;
                const wd = weekdayOf(d[d.len - 2 ..]) orelse return error.BadRule;
                const n: i8 = if (d.len > 2) std.fmt.parseInt(i8, d[0 .. d.len - 2], 10) catch return error.BadRule else 0;
                if (n > 53 or n < -53) return error.BadRule;
                try byday.append(a, .{ .n = n, .wd = wd });
            }
        } else if (is(k, "BYMONTHDAY")) {
            var days = std.mem.splitScalar(u8, v, ',');
            while (days.next()) |d| {
                const n = std.fmt.parseInt(i8, d, 10) catch return error.BadRule;
                if (n == 0 or n > 31 or n < -31) return error.BadRule;
                try bymonthday.append(a, n);
            }
        } else if (is(k, "BYMONTH")) {
            var ms = std.mem.splitScalar(u8, v, ',');
            while (ms.next()) |m| {
                const n = std.fmt.parseInt(u8, m, 10) catch return error.BadRule;
                if (n == 0 or n > 12) return error.BadRule;
                try bymonth.append(a, n);
            }
        } else {
            // BYSETPOS, BYWEEKNO, BYYEARDAY, BYHOUR, BYMINUTE, BYSECOND, RSCALE, SKIP …
            r.unsupported = true;
        }
    }
    if (!have_freq) return error.BadRule;
    r.byday = byday.items;
    r.bymonthday = bymonthday.items;
    r.bymonth = bymonth.items;
    // an ordinal weekday is of the month (MONTHLY, or YEARLY with BYMONTH); of the year it isn't expanded
    for (r.byday) |d| if (d.n != 0) {
        const of_month = r.freq == .monthly or (r.freq == .yearly and r.bymonth.len > 0);
        if (!of_month) r.unsupported = true;
        if (d.n > 5 or d.n < -5) r.unsupported = true;
    };
    return r;
}

fn hasMonth(r: Rule, m: u8) bool {
    if (r.bymonth.len == 0) return true;
    return std.mem.indexOfScalar(u8, r.bymonth, m) != null;
}

fn hasMonthDay(r: Rule, y: i64, m: u8, d: u8) bool {
    if (r.bymonthday.len == 0) return true;
    const len: i16 = tz.monthDays(y, m);
    for (r.bymonthday) |x| {
        const want: i16 = if (x > 0) x else len + 1 + x;
        if (want == d) return true;
    }
    return false;
}

fn hasWeekday(r: Rule, wd: u3) bool {
    if (r.byday.len == 0) return true;
    for (r.byday) |d| if (d.wd == wd) return true;
    return false;
}

/// The days of month `m` of `y` the rule picks (MONTHLY and YEARLY's
/// months); `dflt`: DTSTART's day of the month.
fn monthDays(a: Allocator, out: *std.ArrayList(i64), r: Rule, y: i64, m: u8, dflt: u8) !void {
    const first = tz.daysFromCivil(y, m, 1);
    const len = tz.monthDays(y, m);
    if (r.bymonthday.len > 0) {
        for (r.bymonthday) |x| {
            const d: i16 = if (x > 0) x else @as(i16, len) + 1 + x;
            if (d < 1 or d > len) continue;
            const day = first + d - 1;
            if (hasWeekday(r, tz.weekday(day))) try out.append(a, day);
        }
        return;
    }
    if (r.byday.len > 0) {
        for (r.byday) |bd| {
            if (bd.n != 0) {
                if (tz.nthWeekday(y, m, bd.n, bd.wd)) |day| try out.append(a, day);
                continue;
            }
            var day = first + @mod(@as(i64, bd.wd) - tz.weekday(first) + 7, 7);
            while (day < first + len) : (day += 7) try out.append(a, day);
        }
        return;
    }
    if (dflt <= len) try out.append(a, first + dflt - 1);
}

fn lessThan(_: void, x: i64, y: i64) bool {
    return x < y;
}

/// The local starts of `r`'s occurrences in [`from`, `to`), at most
/// `max`, the first being `dtstart` itself; `until`: UNTIL as local
/// seconds (the caller read it in the event's zone).
pub fn expand(a: Allocator, r: Rule, dtstart: i64, until: ?i64, from: i64, to: i64, max: usize) ![]i64 {
    var out: std.ArrayList(i64) = .empty;
    // DTSTART is the first occurrence, whether or not the rule picks it
    if (dtstart >= from and dtstart < to and max > 0) try out.append(a, dtstart);
    if (r.unsupported) return out.items;
    const tod = @mod(dtstart, 86400);
    const d0 = @divFloor(dtstart, 86400);
    const c0 = tz.civil(d0);
    var seen: u32 = 1;
    if (r.count) |c| if (c <= 1) return out.items;
    var cands: std.ArrayList(i64) = .empty;
    var k: i64 = 0;
    // the start of a period beyond which nothing can fall in the window
    const last_day = @divFloor(@min(to, until orelse to), 86400) + 1;
    // a period skipped (31 Feb), or many without one, still ends the loop
    while (k < 200_000) : (k += 1) {
        cands.clearRetainingCapacity();
        const step = k * @as(i64, r.interval);
        var period_start: i64 = 0;
        switch (r.freq) {
            .daily => {
                const day = d0 + step;
                period_start = day;
                const c = tz.civil(day);
                if (hasMonth(r, c.m) and hasMonthDay(r, c.y, c.m, c.d) and hasWeekday(r, tz.weekday(day))) try cands.append(a, day);
            },
            .weekly => {
                const ws0 = d0 - @mod(@as(i64, tz.weekday(d0)) - r.wkst + 7, 7);
                const ws = ws0 + step * 7;
                period_start = ws;
                if (r.byday.len == 0) {
                    try cands.append(a, ws + @mod(@as(i64, tz.weekday(d0)) - r.wkst + 7, 7));
                } else for (r.byday) |bd| try cands.append(a, ws + @mod(@as(i64, bd.wd) - r.wkst + 7, 7));
                var i: usize = 0;
                while (i < cands.items.len) {
                    if (!hasMonth(r, tz.civil(cands.items[i]).m)) _ = cands.orderedRemove(i) else i += 1;
                }
            },
            .monthly => {
                const mi = c0.y * 12 + (c0.m - 1) + step;
                const y = @divFloor(mi, 12);
                const m: u8 = @intCast(@mod(mi, 12) + 1);
                period_start = tz.daysFromCivil(y, m, 1);
                if (hasMonth(r, m)) try monthDays(a, &cands, r, y, m, c0.d);
            },
            .yearly => {
                const y = c0.y + step;
                period_start = tz.daysFromCivil(y, 1, 1);
                if (r.bymonth.len == 0) {
                    try monthDays(a, &cands, r, y, c0.m, c0.d);
                } else for (r.bymonth) |m| try monthDays(a, &cands, r, y, m, c0.d);
            },
        }
        if (period_start > last_day) break;
        std.mem.sort(i64, cands.items, {}, lessThan);
        var prev: ?i64 = null;
        for (cands.items) |day| {
            if (prev != null and prev.? == day) continue;
            prev = day;
            const t = day * 86400 + tod;
            if (t <= dtstart) continue;
            if (until) |u| if (t > u) return out.items;
            seen += 1;
            if (r.count) |c| if (seen > c) return out.items;
            if (t >= to) return out.items;
            if (t >= from) {
                if (out.items.len >= max) return out.items;
                try out.append(a, t);
            }
        }
    }
    return out.items;
}

const full_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const ordinals = [_][]const u8{ "first", "second", "third", "fourth", "fifth" };

fn ordinal(a: Allocator, n: i64) ![]const u8 {
    const suffix: []const u8 = if (@mod(n, 100) >= 11 and @mod(n, 100) <= 13) "th" else switch (@mod(n, 10)) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
    return std.fmt.allocPrint(a, "{d}{s}", .{ n, suffix });
}

fn andList(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", parts[0 .. parts.len - 1]), parts[parts.len - 1] });
}

/// "every week on Monday", "every month on the second Tuesday", "every 2
/// days, 10 times".
pub fn describe(a: Allocator, r: Rule, dtstart: i64) ![]const u8 {
    if (r.unsupported) return "repeats in a way calmcp doesn't expand (only its first time is shown)";
    var o: std.ArrayList(u8) = .empty;
    const unit: []const u8 = switch (r.freq) {
        .daily => "day",
        .weekly => "week",
        .monthly => "month",
        .yearly => "year",
    };
    if (r.interval == 1) try o.print(a, "every {s}", .{unit}) else try o.print(a, "every {d} {s}s", .{ r.interval, unit });
    const d0 = @divFloor(dtstart, 86400);
    var days: std.ArrayList([]const u8) = .empty;
    for (r.byday) |bd| {
        if (bd.n == 0) {
            try days.append(a, full_names[bd.wd]);
        } else if (bd.n == -1) {
            try days.append(a, try std.fmt.allocPrint(a, "the last {s}", .{full_names[bd.wd]}));
        } else if (bd.n > 0 and bd.n <= 5) {
            try days.append(a, try std.fmt.allocPrint(a, "the {s} {s}", .{ ordinals[@intCast(bd.n - 1)], full_names[bd.wd] }));
        }
    }
    switch (r.freq) {
        .daily => if (days.items.len > 0) try o.print(a, " on {s}", .{try andList(a, days.items)}),
        .weekly => try o.print(a, " on {s}", .{if (days.items.len > 0) try andList(a, days.items) else full_names[tz.weekday(d0)]}),
        .monthly => {
            if (days.items.len > 0) {
                try o.print(a, " on {s}", .{try andList(a, days.items)});
            } else if (r.bymonthday.len > 0) {
                var ds: std.ArrayList([]const u8) = .empty;
                for (r.bymonthday) |x| try ds.append(a, if (x == -1) "the last day" else if (x > 0) try std.fmt.allocPrint(a, "the {s}", .{try ordinal(a, x)}) else try std.fmt.allocPrint(a, "{d} days from the end", .{-x}));
                try o.print(a, " on {s}", .{try andList(a, ds.items)});
            } else try o.print(a, " on the {s}", .{try ordinal(a, tz.civil(d0).d)});
        },
        .yearly => if (days.items.len > 0) try o.print(a, " on {s}", .{try andList(a, days.items)}),
    }
    if (r.count) |c| try o.print(a, ", {d} times", .{c});
    if (r.until.len >= 8) {
        const y = r.until[0..4];
        const m = std.fmt.parseInt(u8, r.until[4..6], 10) catch 1;
        const d = std.fmt.parseInt(u8, r.until[6..8], 10) catch 1;
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        try o.print(a, ", until {d} {s} {s}", .{ d, months[@min(@max(m, 1), 12) - 1], y });
    }
    return o.items;
}

// ---- tests ----

const tt = std.testing;

fn local(y: i64, m: u8, d: u8, hh: i64, mm: i64) i64 {
    return tz.daysFromCivil(y, m, d) * 86400 + hh * 3600 + mm * 60;
}

fn expectTimes(got: []const i64, want: []const i64) !void {
    if (!std.mem.eql(i64, got, want)) {
        std.debug.print("got:\n", .{});
        for (got) |x| {
            const c = tz.civil(@divFloor(x, 86400));
            std.debug.print("  {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}\n", .{ c.y, c.m, c.d, @divFloor(@mod(x, 86400), 3600), @divFloor(@mod(x, 3600), 60) });
        }
        return error.TestUnexpectedResult;
    }
}

test "weekly_stays_at_nine_across_the_october_change" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a, "FREQ=WEEKLY;BYDAY=MO");
    try tt.expectEqual(Freq.weekly, r.freq);
    const start = local(2026, 9, 28, 9, 0);
    const got = try expand(a, r, start, null, local(2026, 10, 19, 0, 0), local(2026, 11, 3, 0, 0), 100);
    try expectTimes(got, &.{ local(2026, 10, 19, 9, 0), local(2026, 10, 26, 9, 0), local(2026, 11, 2, 9, 0) });
    // read in Warsaw: 07:00 UTC before the change, 08:00 after
    const w = tz.lookup("Europe/Warsaw").?;
    try tt.expectEqual(local(2026, 10, 19, 7, 0), w.toUtc(got[0]));
    try tt.expectEqual(local(2026, 10, 26, 8, 0), w.toUtc(got[1]));
    try tt.expectEqualStrings("every week on Monday", try describe(a, r, start));
}

test "weekly_on_several_days_every_other_week_with_a_count" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a, "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=5");
    const start = local(2026, 11, 3, 18, 30); // a Tuesday
    const got = try expand(a, r, start, null, local(2026, 1, 1, 0, 0), local(2027, 12, 31, 0, 0), 100);
    try expectTimes(got, &.{ local(2026, 11, 3, 18, 30), local(2026, 11, 5, 18, 30), local(2026, 11, 17, 18, 30), local(2026, 11, 19, 18, 30), local(2026, 12, 1, 18, 30) });
    try tt.expectEqualStrings("every 2 weeks on Tuesday and Thursday, 5 times", try describe(a, r, start));
}

test "monthly_second_tuesday_and_last_friday_and_day_of_month" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const second = try parse(a, "FREQ=MONTHLY;BYDAY=2TU");
    const got = try expand(a, second, local(2026, 9, 8, 16, 0), null, local(2026, 11, 1, 0, 0), local(2027, 1, 1, 0, 0), 100);
    try expectTimes(got, &.{ local(2026, 11, 10, 16, 0), local(2026, 12, 8, 16, 0) });
    try tt.expectEqualStrings("every month on the second Tuesday", try describe(a, second, local(2026, 9, 8, 16, 0)));
    const last = try parse(a, "FREQ=MONTHLY;BYDAY=-1FR");
    try expectTimes(try expand(a, last, local(2026, 10, 30, 17, 0), null, local(2026, 11, 1, 0, 0), local(2027, 1, 1, 0, 0), 100), &.{ local(2026, 11, 27, 17, 0), local(2026, 12, 25, 17, 0) });
    try tt.expectEqualStrings("every month on the last Friday", try describe(a, last, local(2026, 10, 30, 17, 0)));
    // the 31st: months without one are passed over
    const day31 = try parse(a, "FREQ=MONTHLY");
    try expectTimes(try expand(a, day31, local(2026, 10, 31, 8, 0), null, local(2026, 11, 1, 0, 0), local(2027, 2, 1, 0, 0), 100), &.{ local(2026, 12, 31, 8, 0), local(2027, 1, 31, 8, 0) });
    try tt.expectEqualStrings("every month on the 31st", try describe(a, day31, local(2026, 10, 31, 8, 0)));
    const neg = try parse(a, "FREQ=MONTHLY;BYMONTHDAY=-1");
    try expectTimes(try expand(a, neg, local(2026, 10, 31, 8, 0), null, local(2027, 2, 1, 0, 0), local(2027, 3, 1, 0, 0), 100), &.{local(2027, 2, 28, 8, 0)});
}

test "yearly_daily_until_and_a_birthday" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // an all-day birthday since 1990
    const bday = try parse(a, "FREQ=YEARLY");
    try expectTimes(try expand(a, bday, local(1990, 11, 26, 0, 0), null, local(2026, 11, 23, 0, 0), local(2026, 12, 1, 0, 0), 100), &.{local(2026, 11, 26, 0, 0)});
    try tt.expectEqualStrings("every year", try describe(a, bday, local(1990, 11, 26, 0, 0)));
    // 29 February: leap years only
    try expectTimes(try expand(a, bday, local(2024, 2, 29, 0, 0), null, local(2025, 1, 1, 0, 0), local(2029, 1, 1, 0, 0), 100), &.{local(2028, 2, 29, 0, 0)});
    // yearly in March and October on the last Sunday
    const two = try parse(a, "FREQ=YEARLY;BYMONTH=3,10;BYDAY=-1SU");
    try expectTimes(try expand(a, two, local(2026, 3, 29, 2, 0), null, local(2026, 4, 1, 0, 0), local(2027, 4, 1, 0, 0), 100), &.{ local(2026, 10, 25, 2, 0), local(2027, 3, 28, 2, 0) });
    // daily until a time: the last one is the until's own
    const daily = try parse(a, "FREQ=DAILY;UNTIL=20261125T090000Z");
    try tt.expectEqualStrings("20261125T090000Z", daily.until);
    try expectTimes(try expand(a, daily, local(2026, 11, 23, 9, 0), local(2026, 11, 25, 9, 0), local(2026, 11, 1, 0, 0), local(2026, 12, 1, 0, 0), 100), &.{ local(2026, 11, 23, 9, 0), local(2026, 11, 24, 9, 0), local(2026, 11, 25, 9, 0) });
    // weekdays only, filtered by BYDAY
    const workdays = try parse(a, "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR");
    try expectTimes(try expand(a, workdays, local(2026, 11, 20, 7, 0), null, local(2026, 11, 20, 0, 0), local(2026, 11, 25, 0, 0), 100), &.{ local(2026, 11, 20, 7, 0), local(2026, 11, 23, 7, 0), local(2026, 11, 24, 7, 0) });
    // a cap on how many are given
    try tt.expectEqual(@as(usize, 2), (try expand(a, workdays, local(2026, 11, 20, 7, 0), null, local(2026, 11, 20, 0, 0), local(2027, 11, 25, 0, 0), 2)).len);
}

test "parts_it_does_not_expand_give_the_first_time_only" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "FREQ=YEARLY;BYWEEKNO=20", "FREQ=HOURLY;INTERVAL=4", "FREQ=YEARLY;BYDAY=20MO", "FREQ=DAILY;BYHOUR=9,17" }) |text| {
        const r = try parse(a, text);
        try tt.expect(r.unsupported);
        try expectTimes(try expand(a, r, local(2026, 11, 2, 9, 0), null, local(2026, 11, 1, 0, 0), local(2027, 1, 1, 0, 0), 100), &.{local(2026, 11, 2, 9, 0)});
    }
    try tt.expectError(error.BadRule, parse(a, "INTERVAL=2"));
    try tt.expectError(error.BadRule, parse(a, "FREQ=WEEKLY;BYDAY=XX"));
    try tt.expectError(error.BadRule, parse(a, "FREQ=WEEKLY;INTERVAL=0"));
}

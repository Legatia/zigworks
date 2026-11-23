//! Time zones: a zone's standard offset and, when it has summer time, the
//! two yearly changes, read from a POSIX TZ string (the built-in table of
//! current IANA rules is kept as those) or from an iCalendar VTIMEZONE
//! (ics.zig); and the calendar arithmetic both need. Times are Unix
//! seconds; "local seconds" are a wall-clock time counted as if it were
//! UTC.
const std = @import("std");

/// A yearly change: the `week`th `weekday` of `month` (week 5 or -1: the
/// last), or day `mday` of it, at `minute` local time (in the offset in
/// force before the change; it may pass midnight, as 26:00).
pub const Rule = struct {
    month: u8,
    week: i8 = 0,
    weekday: u3 = 0,
    mday: u8 = 0,
    minute: i32 = 120,
};

pub const Dst = struct { off: i32, start: Rule, end: Rule };

pub const Zone = struct {
    /// Minutes east of UTC.
    std_off: i32 = 0,
    dst: ?Dst = null,

    pub const utc: Zone = .{};

    /// The offset (minutes east) in force at `t` (Unix seconds).
    pub fn offsetAt(z: Zone, t: i64) i32 {
        const d = z.dst orelse return z.std_off;
        const y = civil(@divFloor(t + @as(i64, z.std_off) * 60, 86400)).y;
        const s = changeLocal(d.start, y) - @as(i64, z.std_off) * 60;
        const e = changeLocal(d.end, y) - @as(i64, d.off) * 60;
        const summer = if (s < e) (t >= s and t < e) else (t >= s or t < e);
        return if (summer) d.off else z.std_off;
    }

    /// The Unix time of wall-clock time `local` here. A time a change skips
    /// (spring forward) is read with the offset before it; one it repeats
    /// (fall back), as the first.
    pub fn toUtc(z: Zone, local: i64) i64 {
        const d = z.dst orelse return local - @as(i64, z.std_off) * 60;
        const u_std = local - @as(i64, z.std_off) * 60;
        const u_dst = local - @as(i64, d.off) * 60;
        const ok_std = z.offsetAt(u_std) == z.std_off;
        const ok_dst = z.offsetAt(u_dst) == d.off;
        if (ok_std and ok_dst) return @min(u_std, u_dst);
        if (ok_dst) return u_dst;
        // the standard reading, or a skipped time read with the offset before it
        return u_std;
    }

    /// The wall-clock time here at Unix time `t`.
    pub fn toLocal(z: Zone, t: i64) i64 {
        return t + @as(i64, z.offsetAt(t)) * 60;
    }
};

// ---- dates ----

/// Days since 1970-01-01 of a date (proleptic Gregorian).
pub fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: u8, d: u8 };

/// The date of day `days` since 1970-01-01.
pub fn civil(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

/// 0 = Sunday … 6 = Saturday.
pub fn weekday(days: i64) u3 {
    return @intCast(@mod(days + 4, 7));
}

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn monthDays(y: i64, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(y)) 29 else 28,
    };
}

/// The day (since 1970-01-01) of the `n`th `wd` of month `m` of `y` (n < 0:
/// from the end; -1 the last); null when there is no such day.
pub fn nthWeekday(y: i64, m: u8, n: i8, wd: u3) ?i64 {
    if (n == 0 or n > 5 or n < -5) return null;
    const first = daysFromCivil(y, m, 1);
    const len: i64 = monthDays(y, m);
    if (n > 0) {
        const d = first + @mod(@as(i64, wd) - weekday(first) + 7, 7) + (@as(i64, n) - 1) * 7;
        return if (d < first + len) d else null;
    }
    const last = first + len - 1;
    const d = last - @mod(@as(i64, weekday(last)) - wd + 7, 7) - (@as(i64, -n) - 1) * 7;
    return if (d >= first) d else null;
}

/// The local seconds of `r`'s change in year `y`.
fn changeLocal(r: Rule, y: i64) i64 {
    const day = if (r.mday > 0)
        daysFromCivil(y, r.month, @min(r.mday, monthDays(y, r.month)))
    else
        // week 5 is "the last", as POSIX says
        nthWeekday(y, r.month, if (r.week >= 5) -1 else r.week, r.weekday) orelse nthWeekday(y, r.month, -1, r.weekday).?;
    return day * 86400 + @as(i64, r.minute) * 60;
}

// ---- POSIX TZ strings ----

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(c: *Cursor) ?u8 {
        return if (c.i < c.s.len) c.s[c.i] else null;
    }

    fn eat(c: *Cursor, ch: u8) bool {
        if (c.peek() == ch) {
            c.i += 1;
            return true;
        }
        return false;
    }

    /// A zone's abbreviation: three or more letters, or `<…>`.
    fn name(c: *Cursor) error{BadZone}!void {
        if (c.eat('<')) {
            const close = std.mem.indexOfScalarPos(u8, c.s, c.i, '>') orelse return error.BadZone;
            c.i = close + 1;
            return;
        }
        const start = c.i;
        while (c.peek()) |ch| {
            if (!std.ascii.isAlphabetic(ch)) break;
            c.i += 1;
        }
        if (c.i - start < 3) return error.BadZone;
    }

    fn number(c: *Cursor, max: u32) error{BadZone}!u32 {
        const start = c.i;
        while (c.peek()) |ch| {
            if (!std.ascii.isDigit(ch)) break;
            c.i += 1;
        }
        if (c.i == start or c.i - start > 3) return error.BadZone;
        const n = std.fmt.parseInt(u32, c.s[start..c.i], 10) catch return error.BadZone;
        if (n > max) return error.BadZone;
        return n;
    }

    /// [+-]hh[:mm[:ss]] as minutes, with its sign.
    fn signedTime(c: *Cursor, max_h: u32) error{BadZone}!i32 {
        var sign: i32 = 1;
        if (c.eat('-')) sign = -1 else _ = c.eat('+');
        var m: i32 = @intCast(try c.number(max_h) * 60);
        if (c.eat(':')) {
            m += @intCast(try c.number(59));
            if (c.eat(':')) _ = try c.number(59);
        }
        return sign * m;
    }

    /// ,Mm.w.d[/time]
    fn rule(c: *Cursor) error{BadZone}!Rule {
        if (!c.eat(',') or !c.eat('M')) return error.BadZone;
        const m = try c.number(12);
        if (m == 0 or !c.eat('.')) return error.BadZone;
        const w = try c.number(5);
        if (w == 0 or !c.eat('.')) return error.BadZone;
        const d = try c.number(6);
        var minute: i32 = 120;
        if (c.eat('/')) minute = try c.signedTime(167);
        return .{ .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(d), .minute = minute };
    }
};

/// "CET-1CEST,M3.5.0,M10.5.0/3", "EST5EDT,M3.2.0,M11.1.0", "<+0530>-5:30".
pub fn parsePosix(s: []const u8) error{BadZone}!Zone {
    var c: Cursor = .{ .s = s };
    try c.name();
    // POSIX counts west as positive
    const std_off = -try c.signedTime(24);
    if (c.peek() == null) return .{ .std_off = std_off };
    try c.name();
    var dst_off = std_off + 60;
    if (c.peek()) |ch| if (ch != ',') {
        dst_off = -try c.signedTime(24);
    };
    const start = try c.rule();
    const end = try c.rule();
    if (c.peek() != null) return error.BadZone;
    return .{ .std_off = std_off, .dst = .{ .off = dst_off, .start = start, .end = end } };
}

// ---- the table ----

const eu_cet = "CET-1CEST,M3.5.0,M10.5.0/3";
const eu_eet = "EET-2EEST,M3.5.0/3,M10.5.0/4";
const eu_wet = "WET0WEST,M3.5.0/1,M10.5.0";
const us_east = "EST5EDT,M3.2.0,M11.1.0";
const us_central = "CST6CDT,M3.2.0,M11.1.0";
const us_mountain = "MST7MDT,M3.2.0,M11.1.0";
const us_pacific = "PST8PDT,M3.2.0,M11.1.0";
const au_east = "AEST-10AEDT,M10.1.0,M4.1.0/3";

const Entry = struct { name: []const u8, posix: []const u8 };

/// Current rules (2026) of the zones people most often have, by their
/// IANA names.
const table = [_]Entry{
    .{ .name = "UTC", .posix = "UTC0" },
    .{ .name = "Etc/UTC", .posix = "UTC0" },
    .{ .name = "Etc/GMT", .posix = "GMT0" },
    .{ .name = "GMT", .posix = "GMT0" },
    .{ .name = "Europe/London", .posix = "GMT0BST,M3.5.0/1,M10.5.0" },
    .{ .name = "Europe/Dublin", .posix = "GMT0IST,M3.5.0/1,M10.5.0" },
    .{ .name = "Europe/Lisbon", .posix = eu_wet },
    .{ .name = "Atlantic/Canary", .posix = eu_wet },
    .{ .name = "Europe/Warsaw", .posix = eu_cet },
    .{ .name = "Europe/Berlin", .posix = eu_cet },
    .{ .name = "Europe/Paris", .posix = eu_cet },
    .{ .name = "Europe/Madrid", .posix = eu_cet },
    .{ .name = "Europe/Rome", .posix = eu_cet },
    .{ .name = "Europe/Amsterdam", .posix = eu_cet },
    .{ .name = "Europe/Brussels", .posix = eu_cet },
    .{ .name = "Europe/Vienna", .posix = eu_cet },
    .{ .name = "Europe/Prague", .posix = eu_cet },
    .{ .name = "Europe/Bratislava", .posix = eu_cet },
    .{ .name = "Europe/Budapest", .posix = eu_cet },
    .{ .name = "Europe/Stockholm", .posix = eu_cet },
    .{ .name = "Europe/Oslo", .posix = eu_cet },
    .{ .name = "Europe/Copenhagen", .posix = eu_cet },
    .{ .name = "Europe/Zurich", .posix = eu_cet },
    .{ .name = "Europe/Luxembourg", .posix = eu_cet },
    .{ .name = "Europe/Belgrade", .posix = eu_cet },
    .{ .name = "Europe/Zagreb", .posix = eu_cet },
    .{ .name = "Europe/Ljubljana", .posix = eu_cet },
    .{ .name = "Europe/Sarajevo", .posix = eu_cet },
    .{ .name = "Europe/Skopje", .posix = eu_cet },
    .{ .name = "Europe/Podgorica", .posix = eu_cet },
    .{ .name = "Europe/Tirane", .posix = eu_cet },
    .{ .name = "Europe/Malta", .posix = eu_cet },
    .{ .name = "Europe/Monaco", .posix = eu_cet },
    .{ .name = "Europe/Andorra", .posix = eu_cet },
    .{ .name = "Europe/Gibraltar", .posix = eu_cet },
    .{ .name = "Europe/Athens", .posix = eu_eet },
    .{ .name = "Europe/Helsinki", .posix = eu_eet },
    .{ .name = "Europe/Kyiv", .posix = eu_eet },
    .{ .name = "Europe/Kiev", .posix = eu_eet },
    .{ .name = "Europe/Riga", .posix = eu_eet },
    .{ .name = "Europe/Tallinn", .posix = eu_eet },
    .{ .name = "Europe/Vilnius", .posix = eu_eet },
    .{ .name = "Europe/Sofia", .posix = eu_eet },
    .{ .name = "Europe/Bucharest", .posix = eu_eet },
    .{ .name = "Europe/Chisinau", .posix = "EET-2EEST,M3.5.0,M10.5.0/3" },
    .{ .name = "Europe/Istanbul", .posix = "<+03>-3" },
    .{ .name = "Europe/Minsk", .posix = "<+03>-3" },
    .{ .name = "Europe/Moscow", .posix = "MSK-3" },
    .{ .name = "Asia/Jerusalem", .posix = "IST-2IDT,M3.4.4/26,M10.5.0" },
    .{ .name = "Asia/Tel_Aviv", .posix = "IST-2IDT,M3.4.4/26,M10.5.0" },
    .{ .name = "Asia/Dubai", .posix = "<+04>-4" },
    .{ .name = "Asia/Riyadh", .posix = "<+03>-3" },
    .{ .name = "Asia/Tehran", .posix = "<+0330>-3:30" },
    .{ .name = "Asia/Karachi", .posix = "PKT-5" },
    .{ .name = "Asia/Kolkata", .posix = "IST-5:30" },
    .{ .name = "Asia/Calcutta", .posix = "IST-5:30" },
    .{ .name = "Asia/Kathmandu", .posix = "<+0545>-5:45" },
    .{ .name = "Asia/Dhaka", .posix = "<+06>-6" },
    .{ .name = "Asia/Bangkok", .posix = "<+07>-7" },
    .{ .name = "Asia/Ho_Chi_Minh", .posix = "<+07>-7" },
    .{ .name = "Asia/Jakarta", .posix = "WIB-7" },
    .{ .name = "Asia/Singapore", .posix = "<+08>-8" },
    .{ .name = "Asia/Kuala_Lumpur", .posix = "<+08>-8" },
    .{ .name = "Asia/Hong_Kong", .posix = "HKT-8" },
    .{ .name = "Asia/Shanghai", .posix = "CST-8" },
    .{ .name = "Asia/Taipei", .posix = "CST-8" },
    .{ .name = "Asia/Manila", .posix = "PST-8" },
    .{ .name = "Asia/Tokyo", .posix = "JST-9" },
    .{ .name = "Asia/Seoul", .posix = "KST-9" },
    .{ .name = "Australia/Perth", .posix = "AWST-8" },
    .{ .name = "Australia/Darwin", .posix = "ACST-9:30" },
    .{ .name = "Australia/Adelaide", .posix = "ACST-9:30ACDT,M10.1.0,M4.1.0/3" },
    .{ .name = "Australia/Brisbane", .posix = "AEST-10" },
    .{ .name = "Australia/Sydney", .posix = au_east },
    .{ .name = "Australia/Melbourne", .posix = au_east },
    .{ .name = "Australia/Canberra", .posix = au_east },
    .{ .name = "Australia/Hobart", .posix = au_east },
    .{ .name = "Pacific/Auckland", .posix = "NZST-12NZDT,M9.5.0,M4.1.0/3" },
    .{ .name = "Pacific/Honolulu", .posix = "HST10" },
    .{ .name = "America/Anchorage", .posix = "AKST9AKDT,M3.2.0,M11.1.0" },
    .{ .name = "America/Los_Angeles", .posix = us_pacific },
    .{ .name = "America/Vancouver", .posix = us_pacific },
    .{ .name = "America/Tijuana", .posix = us_pacific },
    .{ .name = "America/Phoenix", .posix = "MST7" },
    .{ .name = "America/Denver", .posix = us_mountain },
    .{ .name = "America/Edmonton", .posix = us_mountain },
    .{ .name = "America/Boise", .posix = us_mountain },
    .{ .name = "America/Chicago", .posix = us_central },
    .{ .name = "America/Winnipeg", .posix = us_central },
    .{ .name = "America/Mexico_City", .posix = "CST6" },
    .{ .name = "America/New_York", .posix = us_east },
    .{ .name = "America/Toronto", .posix = us_east },
    .{ .name = "America/Detroit", .posix = us_east },
    .{ .name = "America/Montreal", .posix = us_east },
    .{ .name = "America/Halifax", .posix = "AST4ADT,M3.2.0,M11.1.0" },
    .{ .name = "America/St_Johns", .posix = "NST3:30NDT,M3.2.0,M11.1.0" },
    .{ .name = "America/Bogota", .posix = "<-05>5" },
    .{ .name = "America/Lima", .posix = "<-05>5" },
    .{ .name = "America/Caracas", .posix = "<-04>4" },
    .{ .name = "America/Santiago", .posix = "<-04>4<-03>,M9.1.6/24,M4.1.6/24" },
    .{ .name = "America/Sao_Paulo", .posix = "<-03>3" },
    .{ .name = "America/Argentina/Buenos_Aires", .posix = "<-03>3" },
    .{ .name = "America/Buenos_Aires", .posix = "<-03>3" },
    .{ .name = "Africa/Casablanca", .posix = "<+01>-1" },
    .{ .name = "Africa/Lagos", .posix = "WAT-1" },
    .{ .name = "Africa/Cairo", .posix = "EET-2EEST,M4.5.5/0,M10.5.4/24" },
    .{ .name = "Africa/Johannesburg", .posix = "SAST-2" },
    .{ .name = "Africa/Nairobi", .posix = "EAT-3" },
};

/// Other names for the table's zones: old IANA links, and the Windows
/// names Outlook and Exchange write in invitations.
const aliases = [_]Entry{
    .{ .name = "US/Eastern", .posix = "America/New_York" },
    .{ .name = "US/Central", .posix = "America/Chicago" },
    .{ .name = "US/Mountain", .posix = "America/Denver" },
    .{ .name = "US/Pacific", .posix = "America/Los_Angeles" },
    .{ .name = "US/Arizona", .posix = "America/Phoenix" },
    .{ .name = "US/Alaska", .posix = "America/Anchorage" },
    .{ .name = "US/Hawaii", .posix = "Pacific/Honolulu" },
    .{ .name = "Poland", .posix = "Europe/Warsaw" },
    .{ .name = "GB", .posix = "Europe/London" },
    .{ .name = "Etc/Universal", .posix = "UTC" },
    .{ .name = "Z", .posix = "UTC" },
    .{ .name = "Central European Standard Time", .posix = "Europe/Warsaw" },
    .{ .name = "Central Europe Standard Time", .posix = "Europe/Budapest" },
    .{ .name = "W. Europe Standard Time", .posix = "Europe/Berlin" },
    .{ .name = "Romance Standard Time", .posix = "Europe/Paris" },
    .{ .name = "GMT Standard Time", .posix = "Europe/London" },
    .{ .name = "Greenwich Standard Time", .posix = "UTC" },
    .{ .name = "E. Europe Standard Time", .posix = "Europe/Chisinau" },
    .{ .name = "FLE Standard Time", .posix = "Europe/Helsinki" },
    .{ .name = "GTB Standard Time", .posix = "Europe/Bucharest" },
    .{ .name = "Russian Standard Time", .posix = "Europe/Moscow" },
    .{ .name = "Turkey Standard Time", .posix = "Europe/Istanbul" },
    .{ .name = "Israel Standard Time", .posix = "Asia/Jerusalem" },
    .{ .name = "India Standard Time", .posix = "Asia/Kolkata" },
    .{ .name = "China Standard Time", .posix = "Asia/Shanghai" },
    .{ .name = "Tokyo Standard Time", .posix = "Asia/Tokyo" },
    .{ .name = "AUS Eastern Standard Time", .posix = "Australia/Sydney" },
    .{ .name = "New Zealand Standard Time", .posix = "Pacific/Auckland" },
    .{ .name = "Eastern Standard Time", .posix = "America/New_York" },
    .{ .name = "Central Standard Time", .posix = "America/Chicago" },
    .{ .name = "Mountain Standard Time", .posix = "America/Denver" },
    .{ .name = "US Mountain Standard Time", .posix = "America/Phoenix" },
    .{ .name = "Pacific Standard Time", .posix = "America/Los_Angeles" },
    .{ .name = "Alaskan Standard Time", .posix = "America/Anchorage" },
    .{ .name = "Hawaiian Standard Time", .posix = "Pacific/Honolulu" },
    .{ .name = "UTC", .posix = "UTC" },
};

fn tableEntry(name: []const u8) ?Entry {
    for (table) |e| if (std.mem.eql(u8, e.name, name)) return e;
    for (aliases) |al| if (std.mem.eql(u8, al.name, name)) {
        for (table) |e| if (std.mem.eql(u8, e.name, al.posix)) return e;
    };
    return null;
}

/// The IANA name the table keeps for `name` (itself, or the one a Windows
/// name or a path stands for); null when unknown.
pub fn canonical(name_in: []const u8) ?[]const u8 {
    const name = std.mem.trim(u8, name_in, " \t\"");
    if (tableEntry(name)) |e| return e.name;
    // "/mozilla.org/20050126_1/Europe/Warsaw": the last two (or three) parts
    var slashes: usize = 0;
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] != '/') continue;
        slashes += 1;
        if (slashes >= 2) if (tableEntry(name[i + 1 ..])) |e| return e.name;
        if (slashes == 3) break;
    }
    return null;
}

/// The zone of an IANA name (or a Windows one Outlook writes), with its
/// current rules; also a name after a path ("/mozilla.org/…/Europe/Warsaw").
pub fn lookup(name: []const u8) ?Zone {
    const c = canonical(name) orelse return null;
    const e = tableEntry(c).?;
    return parsePosix(e.posix) catch unreachable;
}

test "every_entry_of_the_table_reads" {
    for (table) |e| _ = parsePosix(e.posix) catch |err| {
        std.debug.print("{s}: {s}\n", .{ e.name, e.posix });
        return err;
    };
    for (aliases) |al| try std.testing.expect(tableEntry(al.posix) != null);
}

// ---- tests ----

const tt = std.testing;

fn at(y: i64, m: u8, d: u8, hh: i64, mm: i64) i64 {
    return daysFromCivil(y, m, d) * 86400 + hh * 3600 + mm * 60;
}

test "dates_and_weekdays" {
    try tt.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const d = daysFromCivil(2026, 11, 23);
    try tt.expectEqual(Civil{ .y = 2026, .m = 11, .d = 23 }, civil(d));
    try tt.expectEqual(@as(u3, 1), weekday(d)); // a Monday
    try tt.expectEqual(@as(u8, 29), monthDays(2028, 2));
    try tt.expectEqual(@as(u8, 28), monthDays(2100, 2));
    // the last Sunday of March 2026 is the 29th, of October the 25th
    try tt.expectEqual(daysFromCivil(2026, 3, 29), nthWeekday(2026, 3, -1, 0).?);
    try tt.expectEqual(daysFromCivil(2026, 10, 25), nthWeekday(2026, 10, -1, 0).?);
    // October 2026 has four Sundays: no fifth (POSIX's week 5, "the last", is changeLocal's)
    try tt.expect(nthWeekday(2026, 10, 5, 0) == null);
    // the second Tuesday of December 2026 is the 8th; there is no fifth Monday in February 2027
    try tt.expectEqual(daysFromCivil(2026, 12, 8), nthWeekday(2026, 12, 2, 2).?);
    try tt.expect(nthWeekday(2027, 2, 5, 1) == null);
    try tt.expectEqual(daysFromCivil(2027, 2, 22), nthWeekday(2027, 2, -1, 1).?);
}

test "warsaw_changes_on_the_last_sundays_of_march_and_october" {
    const z = try parsePosix("CET-1CEST,M3.5.0,M10.5.0/3");
    try tt.expectEqual(@as(i32, 60), z.std_off);
    try tt.expectEqual(@as(i32, 120), z.dst.?.off);
    // 25 Oct 2026: 03:00 summer time is 01:00 UTC; after it, winter
    try tt.expectEqual(@as(i32, 120), z.offsetAt(at(2026, 10, 25, 0, 59)));
    try tt.expectEqual(@as(i32, 60), z.offsetAt(at(2026, 10, 25, 1, 0)));
    // 29 Mar 2026: 02:00 winter time is 01:00 UTC
    try tt.expectEqual(@as(i32, 60), z.offsetAt(at(2026, 3, 29, 0, 59)));
    try tt.expectEqual(@as(i32, 120), z.offsetAt(at(2026, 3, 29, 1, 0)));
    // wall clock to UTC: 09:00 in November is 08:00 UTC, in September 07:00
    try tt.expectEqual(at(2026, 11, 23, 8, 0), z.toUtc(at(2026, 11, 23, 9, 0)));
    try tt.expectEqual(at(2026, 9, 28, 7, 0), z.toUtc(at(2026, 9, 28, 9, 0)));
    // 02:30 on 29 Mar doesn't exist: read with the offset before (01:30 UTC, shown 03:30)
    try tt.expectEqual(at(2026, 3, 29, 1, 30), z.toUtc(at(2026, 3, 29, 2, 30)));
    // 02:30 on 25 Oct happens twice: the first (summer time, 00:30 UTC)
    try tt.expectEqual(at(2026, 10, 25, 0, 30), z.toUtc(at(2026, 10, 25, 2, 30)));
    try tt.expectEqual(at(2026, 11, 23, 10, 30), z.toLocal(at(2026, 11, 23, 9, 30)));
}

test "new_york_and_sydney_and_fixed_zones" {
    const ny = try parsePosix("EST5EDT,M3.2.0,M11.1.0");
    try tt.expectEqual(@as(i32, -300), ny.std_off);
    // 1 Nov 2026, 02:00 EDT is 06:00 UTC
    try tt.expectEqual(@as(i32, -240), ny.offsetAt(at(2026, 11, 1, 5, 59)));
    try tt.expectEqual(@as(i32, -300), ny.offsetAt(at(2026, 11, 1, 6, 0)));
    try tt.expectEqual(at(2026, 11, 23, 14, 0), ny.toUtc(at(2026, 11, 23, 9, 0)));
    // the south: summer time across the new year
    const syd = try parsePosix("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try tt.expectEqual(@as(i32, 660), syd.offsetAt(at(2026, 1, 15, 0, 0)));
    try tt.expectEqual(@as(i32, 600), syd.offsetAt(at(2026, 6, 15, 0, 0)));
    try tt.expectEqual(@as(i32, 660), syd.offsetAt(at(2026, 12, 15, 0, 0)));
    const india = try parsePosix("IST-5:30");
    try tt.expectEqual(@as(i32, 330), india.std_off);
    try tt.expect(india.dst == null);
    const quoted = try parsePosix("<+0545>-5:45");
    try tt.expectEqual(@as(i32, 345), quoted.std_off);
    const jerusalem = try parsePosix("IST-2IDT,M3.4.4/26,M10.5.0");
    // the Friday before the last Sunday of March, 02:00: Thursday's 26:00
    try tt.expectEqual(@as(i32, 180), jerusalem.offsetAt(at(2026, 3, 27, 0, 0)));
    try tt.expectEqual(@as(i32, 120), jerusalem.offsetAt(at(2026, 3, 26, 23, 59)));
    try tt.expectError(error.BadZone, parsePosix("Nowhere"));
    try tt.expectError(error.BadZone, parsePosix("CET-1CEST,M13.5.0,M10.5.0"));
}

test "the_table_knows_iana_and_windows_names_and_paths" {
    const w = lookup("Europe/Warsaw").?;
    try tt.expectEqual(@as(i32, 60), w.std_off);
    try tt.expectEqual(@as(i32, 120), w.dst.?.off);
    try tt.expectEqualStrings("Europe/Warsaw", canonical("/freeassociation.sourceforge.net/Tzfile/Europe/Warsaw").?);
    try tt.expectEqualStrings("Europe/Warsaw", canonical("/mozilla.org/20050126_1/Europe/Warsaw").?);
    try tt.expectEqual(@as(i32, -300), lookup("Eastern Standard Time").?.std_off);
    try tt.expectEqualStrings("America/New_York", canonical("US/Eastern").?);
    try tt.expectEqual(@as(i32, 0), lookup("UTC").?.std_off);
    try tt.expectEqual(@as(i32, 0), lookup("Etc/UTC").?.std_off);
    try tt.expect(lookup("Mars/Olympus_Mons") == null);
}

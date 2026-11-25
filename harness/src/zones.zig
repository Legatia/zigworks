//! An IANA time zone's offset from UTC at a moment, from the system's
//! zone files (TZif, RFC 8536) and, past their last change, the POSIX TZ
//! rule they end with. The Hermes import uses this to take a job's time in
//! the job's own zone on the day of the import; `[chat] utc_offset = auto`
//! the computer's own zone (`localNow`). Windows has no zone files: a named
//! zone is null there, and the computer's comes from GetTimeZoneInformation.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const Io = std.Io;

/// Where the zone files usually are (TZDIR, when set, goes first).
pub const default_dirs = [_][]const u8{ "/usr/share/zoneinfo", "/var/db/timezone/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo" };

/// Zone `zone`'s offset from UTC at `at_s`, in minutes east; null when no
/// file in `dirs` holds it, or it does not read. "" is this computer's
/// zone (`/etc/localtime`). UTC, GMT and Etc/UTC need no file.
pub fn offsetAt(io: Io, a: std.mem.Allocator, dirs: []const []const u8, zone: []const u8, at_s: i64) ?i32 {
    for ([_][]const u8{ "UTC", "GMT", "Etc/UTC", "Etc/GMT", "Z", "Zulu", "Etc/Zulu", "UCT" }) |u| if (std.mem.eql(u8, zone, u)) return 0;
    if (zone.len == 0) {
        if (builtin.os.tag == .windows) return null;
        const data = Io.Dir.cwd().readFileAlloc(io, "/etc/localtime", a, .limited(1 << 20)) catch return null;
        return offsetIn(a, data, at_s);
    }
    if (!validZone(zone)) return null;
    for (dirs) |d| {
        const p = std.fs.path.join(a, &.{ d, zone }) catch return null;
        const data = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch continue;
        return offsetIn(a, data, at_s);
    }
    return null;
}

/// The computer's offset from UTC at `now_s`, in minutes east, daylight
/// saving included: its zone file (/etc/localtime) on macOS and Linux,
/// GetTimeZoneInformation on Windows (the offset now); null when it can't
/// be read.
pub fn localNow(io: Io, a: std.mem.Allocator, now_s: i64) ?i32 {
    if (builtin.os.tag == .windows) {
        var tz: win.TimeZoneInformation = undefined;
        const r = win.GetTimeZoneInformation(&tz);
        return windowsOffset(r, tz.Bias, tz.StandardBias, tz.DaylightBias);
    }
    return offsetAt(io, a, &.{}, "", now_s);
}

/// What GetTimeZoneInformation's answer `ret` and biases (minutes west:
/// UTC = local + bias) make the offset now, in minutes east: 0 no daylight
/// saving in the zone, 1 standard time, 2 daylight time; null for an error.
pub fn windowsOffset(ret: u32, bias: i32, std_bias: i32, dst_bias: i32) ?i32 {
    return switch (ret) {
        0 => -bias,
        1 => -(bias + std_bias),
        2 => -(bias + dst_bias),
        else => null,
    };
}

/// kernel32's time zone call, declared here (std has none).
const win = struct {
    const SystemTime = extern struct { year: u16, month: u16, day_of_week: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };
    const TimeZoneInformation = extern struct {
        Bias: i32,
        StandardName: [32]u16,
        StandardDate: SystemTime,
        StandardBias: i32,
        DaylightName: [32]u16,
        DaylightDate: SystemTime,
        DaylightBias: i32,
    };
    extern "kernel32" fn GetTimeZoneInformation(info: *TimeZoneInformation) callconv(.winapi) u32;
};

/// A zone's name as the zone files have it: parts of letters, digits,
/// `_`, `-` and `+`, separated by `/`; nothing that leaves the folder.
fn validZone(zone: []const u8) bool {
    if (zone.len == 0 or zone.len > 64 or zone[0] == '/') return false;
    var it = std.mem.splitScalar(u8, zone, '/');
    while (it.next()) |part| {
        if (part.len == 0 or part[0] == '.') return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '+')) return false;
    }
    return true;
}

/// The offset at `at_s` a TZif file gives, in minutes east.
fn offsetIn(a: std.mem.Allocator, data: []const u8, at_s: i64) ?i32 {
    var r: Io.Reader = .fixed(data);
    var tz = std.tz.Tz.parse(a, &r) catch return null;
    defer tz.deinit();
    if (tz.timetypes.len == 0) return null;
    const tr = tz.transitions;
    if (tr.len == 0 or at_s < tr[0].ts) {
        // past every change, or before the first: the rule, else the first standard type
        if (tr.len == 0) if (tz.footer) |f| if (footerOffset(f, at_s)) |o| return o;
        for (tz.timetypes) |tt| if (!tt.isDst()) return @divTrunc(tt.offset, 60);
        return @divTrunc(tz.timetypes[0].offset, 60);
    }
    var i: usize = tr.len - 1;
    while (tr[i].ts > at_s) i -= 1;
    if (i == tr.len - 1) if (tz.footer) |f| if (footerOffset(f, at_s)) |o| return o;
    return @divTrunc(tr[i].timetype.offset, 60);
}

/// A POSIX TZ rule's offset at `at_s`, in minutes east: `std offset
/// [dst [offset] [,start[/time],end[/time]]]`, the dates `Mm.w.d`, `Jn` or
/// `n`; null when it does not read.
pub fn footerOffset(rule: []const u8, at_s: i64) ?i32 {
    var p: Rule = .{ .s = rule };
    if (!p.name()) return null;
    const std_off = -(p.offset() orelse return null);
    if (p.i == rule.len) return @intCast(@divTrunc(std_off, 60));
    if (!p.name()) return null;
    var dst_off = std_off + 3600;
    if (p.i < rule.len and rule[p.i] != ',') dst_off = -(p.offset() orelse return null);
    // daylight saving named but no dates: POSIX's default is the US rule; Hermes zones always give them
    if (p.i == rule.len or rule[p.i] != ',') return null;
    p.i += 1;
    const start = p.date() orelse return null;
    if (p.i >= rule.len or rule[p.i] != ',') return null;
    p.i += 1;
    const end = p.date() orelse return null;
    if (p.i != rule.len) return null;
    const year = util.civil(@divFloor(at_s + std_off, 86400)).y;
    // the start is in standard time, the end in daylight time
    const start_s = dayOf(start, year) * 86400 + start.time - std_off;
    const end_s = dayOf(end, year) * 86400 + end.time - dst_off;
    const in_dst = if (start_s < end_s) at_s >= start_s and at_s < end_s else !(at_s >= end_s and at_s < start_s);
    return @intCast(@divTrunc(if (in_dst) dst_off else std_off, 60));
}

const Date = struct {
    kind: enum { m, j, n },
    month: u8 = 0,
    week: u8 = 0,
    weekday: u8 = 0,
    day: u16 = 0,
    /// Seconds after local midnight (may be negative, or past a day).
    time: i64 = 7200,
};

/// The day (since 1970) a rule's date falls on in `year`.
fn dayOf(d: Date, year: i64) i64 {
    const jan1 = util.daysFromCivil(year, 1, 1);
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    switch (d.kind) {
        .n => return jan1 + d.day,
        .j => return jan1 + d.day - 1 + @as(i64, if (leap and d.day >= 60) 1 else 0),
        .m => {
            const first = util.daysFromCivil(year, d.month, 1);
            // Sunday = 0 (1970-01-01 was a Thursday)
            const wd: i64 = @mod(first + 4, 7);
            var day = first + @mod(@as(i64, d.weekday) - wd + 7, 7) + 7 * (@as(i64, d.week) - 1);
            const next = if (d.month == 12) util.daysFromCivil(year + 1, 1, 1) else util.daysFromCivil(year, d.month + 1, 1);
            while (day >= next) day -= 7;
            return day;
        },
    }
}

const Rule = struct {
    s: []const u8,
    i: usize = 0,

    /// A zone's abbreviation: three or more letters, or anything in `<>`.
    fn name(p: *Rule) bool {
        if (p.i < p.s.len and p.s[p.i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return false;
            p.i = close + 1;
            return true;
        }
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        return p.i - start >= 3;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, POSIX's sign (west positive).
    fn offset(p: *Rule) ?i64 {
        var sign: i64 = 1;
        if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) {
            if (p.s[p.i] == '-') sign = -1;
            p.i += 1;
        }
        return sign * (p.clock() orelse return null);
    }

    fn clock(p: *Rule) ?i64 {
        var total: i64 = 0;
        var mult: i64 = 3600;
        var parts: u8 = 0;
        while (parts < 3) : (parts += 1) {
            const start = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            if (p.i == start) return if (parts == 0) null else total;
            total += mult * (std.fmt.parseInt(i64, p.s[start..p.i], 10) catch return null);
            mult = @divTrunc(mult, 60);
            if (p.i < p.s.len and p.s[p.i] == ':' and parts < 2) p.i += 1 else break;
        }
        return total;
    }

    fn number(p: *Rule) ?u16 {
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        return std.fmt.parseInt(u16, p.s[start..p.i], 10) catch null;
    }

    fn date(p: *Rule) ?Date {
        var d: Date = undefined;
        if (p.i < p.s.len and p.s[p.i] == 'M') {
            p.i += 1;
            const m = p.number() orelse return null;
            if (p.i >= p.s.len or p.s[p.i] != '.') return null;
            p.i += 1;
            const w = p.number() orelse return null;
            if (p.i >= p.s.len or p.s[p.i] != '.') return null;
            p.i += 1;
            const wd = p.number() orelse return null;
            if (m < 1 or m > 12 or w < 1 or w > 5 or wd > 6) return null;
            d = .{ .kind = .m, .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(wd) };
        } else if (p.i < p.s.len and p.s[p.i] == 'J') {
            p.i += 1;
            const n = p.number() orelse return null;
            if (n < 1 or n > 365) return null;
            d = .{ .kind = .j, .day = n };
        } else {
            const n = p.number() orelse return null;
            if (n > 365) return null;
            d = .{ .kind = .n, .day = n };
        }
        if (p.i < p.s.len and p.s[p.i] == '/') {
            p.i += 1;
            d.time = p.offset() orelse return null;
        }
        return d;
    }
};

const t = std.testing;

/// A TZif file (version 2), for the tests here and the import's: `transitions` with the index of
/// their type, `types` (seconds east of UTC, daylight saving or not), and
/// the POSIX rule after the last transition.
pub fn tzif(a: std.mem.Allocator, transitions: []const struct { at: i64, type: u8 }, types: []const struct { off: i32, dst: bool }, footer: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn int(o: *std.ArrayList(u8), al: std.mem.Allocator, comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .big);
            try o.appendSlice(al, &b);
        }
        fn header(o: *std.ArrayList(u8), al: std.mem.Allocator, timecnt: u32, typecnt: u32, charcnt: u32) !void {
            try o.appendSlice(al, "TZif2");
            try o.appendNTimes(al, 0, 15);
            for ([_]u32{ 0, 0, 0, timecnt, typecnt, charcnt }) |c| try int(o, al, u32, c);
        }
    };
    // the legacy block: one type, nothing else
    try w.header(&out, a, 0, 1, 2);
    try w.int(&out, a, i32, 0);
    try out.appendSlice(a, &.{ 0, 0 });
    try out.appendSlice(a, "Z\x00");
    // the 64-bit block
    try w.header(&out, a, @intCast(transitions.len), @intCast(types.len), @intCast(types.len * 3));
    for (transitions) |tr| try w.int(&out, a, i64, tr.at);
    for (transitions) |tr| try out.append(a, tr.type);
    for (types, 0..) |ty, i| {
        try w.int(&out, a, i32, ty.off);
        try out.append(a, @intFromBool(ty.dst));
        try out.append(a, @intCast(i * 3));
    }
    for (types, 0..) |_, i| try out.appendSlice(a, &.{ 'T', '0' + @as(u8, @intCast(i)), 0 });
    try out.append(a, '\n');
    try out.appendSlice(a, footer);
    try out.append(a, '\n');
    return out.items;
}

fn zoneDir(tmp: *t.TmpDir, a: std.mem.Allocator, name: []const u8, data: []const u8) ![]const u8 {
    if (std.fs.path.dirname(name)) |d| try tmp.dir.createDirPath(t.io, d);
    try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = data });
    return tmp.dir.realPathFileAlloc(t.io, ".", a);
}

fn at(y: i64, m: u8, d: u8, h: i64, mi: i64) i64 {
    return util.daysFromCivil(y, m, d) * 86400 + h * 3600 + mi * 60;
}

test "a_fixed_zone_reads_from_its_footer" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try zoneDir(&tmp, a, "Test/Plus2", try tzif(a, &.{}, &.{.{ .off = 7200, .dst = false }}, "<+02>-2"));
    try t.expectEqual(@as(?i32, 120), offsetAt(t.io, a, &.{dir}, "Test/Plus2", at(2026, 11, 24, 12, 0)));
    // footers on their own: west is positive in POSIX, minutes and names in <>
    try t.expectEqual(@as(?i32, -5 * 60), footerOffset("EST5", 0));
    try t.expectEqual(@as(?i32, 5 * 60 + 30), footerOffset("IST-5:30", 0));
    try t.expectEqual(@as(?i32, -(3 * 60 + 30)), footerOffset("<-0330>3:30", 0));
    try t.expectEqual(@as(?i32, 0), footerOffset("UTC0", 0));
    try t.expect(footerOffset("garbage", 0) == null);
    // UTC needs no file
    try t.expectEqual(@as(?i32, 0), offsetAt(t.io, a, &.{}, "UTC", 0));
}

test "daylight_saving_from_the_footer" {
    // Europe: last Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC
    const eu = "CET-1CEST,M3.5.0,M10.5.0/3";
    try t.expectEqual(@as(?i32, 60), footerOffset(eu, at(2026, 1, 15, 12, 0)));
    try t.expectEqual(@as(?i32, 120), footerOffset(eu, at(2026, 7, 15, 12, 0)));
    try t.expectEqual(@as(?i32, 60), footerOffset(eu, at(2026, 3, 29, 0, 59)));
    try t.expectEqual(@as(?i32, 120), footerOffset(eu, at(2026, 3, 29, 1, 0)));
    try t.expectEqual(@as(?i32, 120), footerOffset(eu, at(2026, 10, 25, 0, 59)));
    try t.expectEqual(@as(?i32, 60), footerOffset(eu, at(2026, 10, 25, 1, 0)));
    // the south: daylight saving across the new year
    const au = "AEST-10AEDT,M10.1.0,M4.1.0/3";
    try t.expectEqual(@as(?i32, 660), footerOffset(au, at(2026, 1, 15, 0, 0)));
    try t.expectEqual(@as(?i32, 600), footerOffset(au, at(2026, 7, 15, 0, 0)));
    // US, Jn and n day forms
    try t.expectEqual(@as(?i32, -240), footerOffset("EST5EDT,M3.2.0,M11.1.0", at(2026, 7, 4, 12, 0)));
    try t.expectEqual(@as(?i32, -300), footerOffset("EST5EDT,M3.2.0,M11.1.0", at(2026, 12, 4, 12, 0)));
    try t.expectEqual(@as(?i32, 120), footerOffset("XST-1XDT,J60,J300", at(2026, 6, 1, 0, 0)));
    try t.expectEqual(@as(?i32, 120), footerOffset("XST-1XDT,59,299", at(2026, 6, 1, 0, 0)));
}

test "transitions_before_the_footer_count" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t1 = at(2000, 1, 1, 0, 0);
    const t2 = at(2010, 1, 1, 0, 0);
    const data = try tzif(a, &.{ .{ .at = t1, .type = 1 }, .{ .at = t2, .type = 0 } }, &.{ .{ .off = 3600, .dst = false }, .{ .off = 7200, .dst = false } }, "<+03>-3");
    const dir = try zoneDir(&tmp, a, "Test/Changes", data);
    // before the first change: the first standard type
    try t.expectEqual(@as(?i32, 60), offsetAt(t.io, a, &.{dir}, "Test/Changes", at(1990, 1, 1, 0, 0)));
    // between the changes: the first change's type
    try t.expectEqual(@as(?i32, 120), offsetAt(t.io, a, &.{dir}, "Test/Changes", at(2005, 1, 1, 0, 0)));
    // after the last one: the footer's rule
    try t.expectEqual(@as(?i32, 180), offsetAt(t.io, a, &.{dir}, "Test/Changes", at(2026, 1, 1, 0, 0)));
}

test "a_missing_zone_is_null" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try zoneDir(&tmp, a, "Bad/Zone", "not a zone file");
    try t.expect(offsetAt(t.io, a, &.{dir}, "Europe/Nowhere", 0) == null);
    try t.expect(offsetAt(t.io, a, &.{dir}, "Bad/Zone", 0) == null);
}

test "zone_names_cannot_leave_the_folder" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixed = try tzif(a, &.{}, &.{.{ .off = 7200, .dst = false }}, "<+02>-2");
    try tmp.dir.createDirPath(t.io, "zi");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "outside", .data = fixed });
    const dir = try tmp.dir.realPathFileAlloc(t.io, "zi", a);
    for ([_][]const u8{ "../outside", "/etc/localtime", "a/../../outside", "a\\b", "a//b" }) |name| {
        try t.expect(offsetAt(t.io, a, &.{dir}, name, 0) == null);
    }
}

test "the_systems_zone_files_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Windows has none; a system without Europe/Warsaw skips
    const winter = offsetAt(t.io, a, &default_dirs, "Europe/Warsaw", at(2026, 11, 24, 12, 0)) orelse return error.SkipZigTest;
    try t.expectEqual(60, winter);
    try t.expectEqual(@as(?i32, 120), offsetAt(t.io, a, &default_dirs, "Europe/Warsaw", at(2026, 7, 1, 12, 0)));
    try t.expectEqual(@as(?i32, 330), offsetAt(t.io, a, &default_dirs, "Asia/Kolkata", at(2026, 7, 1, 12, 0)));
    try t.expectEqual(@as(?i32, -300), offsetAt(t.io, a, &default_dirs, "America/New_York", at(2026, 11, 24, 12, 0)));
}

test "windows_says_the_offset_now_from_its_biases" {
    // Warsaw: bias -60, standard 0, daylight -60
    try t.expectEqual(@as(?i32, 120), windowsOffset(2, -60, 0, -60));
    try t.expectEqual(@as(?i32, 60), windowsOffset(1, -60, 0, -60));
    // a zone with no daylight saving: the bias alone
    try t.expectEqual(@as(?i32, -300), windowsOffset(0, 300, 0, -60));
    // New York in summer
    try t.expectEqual(@as(?i32, -240), windowsOffset(2, 300, 0, -60));
    try t.expectEqual(@as(?i32, null), windowsOffset(0xFFFFFFFF, -60, 0, -60));
}

test "the_computers_zone_reads_where_there_are_zone_files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    // whatever it is, it is what /etc/localtime says (or nothing to read)
    const got = localNow(t.io, arena.allocator(), 1_780_000_000);
    try t.expectEqual(offsetAt(t.io, arena.allocator(), &.{}, "", 1_780_000_000), got);
    if (got) |o| try t.expect(o >= -14 * 60 and o <= 14 * 60);
}

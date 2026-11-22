//! Small helpers shared by the modules: the clock and UTC dates.
const std = @import("std");
const Io = std.Io;

/// Files only the owner can read (POSIX); the default on Windows.
pub const private_file: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);

/// One environment variable.
pub const Var = struct { name: []const u8, value: []const u8 };

/// Variables of the system itself that programs on Windows cannot do
/// without, and that hold no secrets: without SystemRoot name lookups fail
/// (so nothing reaches the network), without PATHEXT and ComSpec commands
/// are not found, and without the profile folders npm, node and others
/// have nowhere to keep their files. Other systems need none.
pub const system_var_names: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{
    "SystemRoot",   "SystemDrive",       "windir",            "ComSpec",
    "PATHEXT",      "TEMP",              "TMP",               "USERPROFILE",
    "HOMEDRIVE",    "HOMEPATH",          "APPDATA",           "LOCALAPPDATA",
    "ProgramData",  "ProgramFiles",      "ProgramFiles(x86)", "ProgramW6432",
    "CommonProgramFiles", "CommonProgramFiles(x86)", "CommonProgramW6432", "USERNAME",
    "USERDOMAIN",   "COMPUTERNAME",      "OS",                "PROCESSOR_ARCHITECTURE",
    "NUMBER_OF_PROCESSORS",
} else &.{};

/// The named variables that are set in `map`, in the order named.
pub fn pickVars(arena: std.mem.Allocator, map: *const std.process.Environ.Map, names: []const []const u8) ![]const Var {
    var out: std.ArrayList(Var) = .empty;
    for (names) |n| {
        if (map.get(n)) |v| try out.append(arena, .{ .name = n, .value = try arena.dupe(u8, v) });
    }
    return out.items;
}

pub fn nowSeconds(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

pub fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// "2026-11-19T08:12:00Z".
pub fn isoTime(buf: *[20]u8, secs: i64) []const u8 {
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
    // Howard Hinnant's civil_from_days
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(std.math.clamp(y, 0, 9999))), @as(u64, @intCast(m)), @as(u64, @intCast(d)), sod / 3600, sod / 60 % 60, sod % 60,
    }) catch unreachable;
}

/// Days since 1970-01-01 → (year, month, day).
pub fn civil(days: i64) struct { y: i64, m: u8, d: u8 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .m = @intCast(m), .d = @intCast(d) };
}

/// (year, month, day) → seconds at midnight UTC.
pub fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Parses "2026-11-19T08:12:00Z" (as written by isoTime) to seconds.
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or se > 60) return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

/// Monday = 0 … Sunday = 6, for a day number since 1970-01-01 (a Thursday).
pub fn weekday(days: i64) u3 {
    return @intCast(@mod(days + 3, 7));
}

/// Appends `s` as a JSON string (with quotes). JSON is UTF-8: bytes that
/// are not go in as U+FFFD, so the result is always valid.
pub fn jsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 0x80) {
            i += try appendUtf8Seq(out, gpa, s[i..]);
            continue;
        }
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0...8, 11, 12, 14...0x1f, 0x7f => try out.print(gpa, "\\u{x:0>4}", .{c}),
            else => try out.append(gpa, c),
        }
        i += 1;
    }
    try out.append(gpa, '"');
}

const replacement = "\u{fffd}";

/// `s` with each run of bytes that is not UTF-8 replaced by U+FFFD; `s`
/// itself when it is valid.
pub fn validUtf8(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, s.len + 16);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            try out.append(arena, s[i]);
            i += 1;
        } else i += try appendUtf8Seq(&out, arena, s[i..]);
    }
    return out.items;
}

/// Appends the sequence `s` starts with (its first byte is 0x80 or more),
/// or U+FFFD for as many bytes as could have begun one (the "maximal
/// subpart"); returns how many bytes of `s` it took.
fn appendUtf8Seq(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !usize {
    const need: usize = switch (s[0]) {
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => {
            try out.appendSlice(gpa, replacement);
            return 1;
        },
    };
    var k: usize = 1;
    while (k < need and k < s.len and isCont(s[k])) : (k += 1) {
        // the second byte's narrower ranges: no overlong forms, no
        // surrogate halves, nothing above U+10FFFF
        if (k == 1) {
            const ok = switch (s[0]) {
                0xe0 => s[1] >= 0xa0,
                0xed => s[1] <= 0x9f,
                0xf0 => s[1] >= 0x90,
                0xf4 => s[1] <= 0x8f,
                else => true,
            };
            if (!ok) break;
        }
    }
    if (k == need) {
        try out.appendSlice(gpa, s[0..k]);
    } else {
        try out.appendSlice(gpa, replacement);
    }
    return k;
}

/// Cuts `s` to at most `max` bytes without splitting a UTF-8 sequence.
/// Where the bytes are not UTF-8 (no sequence starts in the 3 bytes before
/// the cut), it is a hard cut at `max`, so cutting parts off a text always
/// moves on.
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and max - n < 3 and isCont(s[n])) n -= 1;
    if (n == 0 or isCont(s[n])) return s[0..max];
    return s[0..n];
}

fn isCont(c: u8) bool {
    return c & 0xc0 == 0x80;
}

const t = std.testing;

test "systemVars_takes_only_the_named_ones_that_are_set" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var map = std.process.Environ.Map.init(arena.allocator());
    try map.put("SystemRoot", "C:\\Windows");
    try map.put("TEMP", "C:\\Temp");
    try map.put("MY_API_KEY", "secret");
    const got = try pickVars(arena.allocator(), &map, &.{ "SystemRoot", "ComSpec", "TEMP" });
    try t.expectEqual(2, got.len);
    try t.expectEqualStrings("SystemRoot", got[0].name);
    try t.expectEqualStrings("C:\\Windows", got[0].value);
    try t.expectEqualStrings("TEMP", got[1].name);
}

test "dates_round_trip" {
    var buf: [20]u8 = undefined;
    const s = isoTime(&buf, 1795996800 + 86400 + 3723);
    try t.expectEqualStrings("2026-12-01T01:02:03Z", s);
    try t.expectEqual(1795996800 + 86400 + 3723, parseIso(s).?);
    try t.expectEqual(null, parseIso("2026-13-01T00:00:00Z"));
    // 2026-11-19 is a Thursday
    try t.expectEqual(3, weekday(@divFloor(parseIso("2026-11-19T12:00:00Z").?, 86400)));
}

test "json_strings_are_escaped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try jsonString(&out, t.allocator, "a\"b\\c\nd\x01");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", out.items);
    try t.expectEqualStrings("ab", cut("ab\xc3\xa9", 3));
}

test "bytes_that_are_not_utf8_become_replacement_characters" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = "plain, caf\xc3\xa9, \xf0\x9f\x98\x80";
    try t.expectEqual(ok.ptr, (try validUtf8(a, ok)).ptr);
    // a lone continuation byte, an overlong form, a surrogate half, too large, a cut-off sequence
    try t.expectEqualStrings("a\u{fffd}b", try validUtf8(a, "a\x80b"));
    try t.expectEqualStrings("\u{fffd}\u{fffd}x", try validUtf8(a, "\xc0\x80x"));
    try t.expectEqualStrings("\u{fffd}\u{fffd}\u{fffd}", try validUtf8(a, "\xed\xa0\x80"));
    try t.expectEqualStrings("\u{fffd}\u{fffd}\u{fffd}\u{fffd}", try validUtf8(a, "\xf4\x90\x80\x80"));
    try t.expectEqualStrings("ok \u{fffd}", try validUtf8(a, "ok \xf0\x9f\x98"));
    // JSON strings come out valid whatever they were given
    var out: std.ArrayList(u8) = .empty;
    try jsonString(&out, a, "a\x80b\xc3 \xc3\xa9");
    try t.expectEqualStrings("\"a\u{fffd}b\u{fffd} \xc3\xa9\"", out.items);
    try t.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "cut_moves_on_through_bytes_that_are_not_utf8" {
    // no sequence starts anywhere near the cut: a hard cut at the limit
    const junk: [5000]u8 = @splat(0x80);
    try t.expectEqual(4096, cut(&junk, 4096).len);
    // so cutting parts off a text, as telegram.split does, always ends
    var rest: []const u8 = &junk;
    var parts: usize = 0;
    while (rest.len > 4096) : (parts += 1) rest = rest[cut(rest, 4096).len..];
    try t.expectEqual(1, parts);
    // a character is still never split
    try t.expectEqualStrings("a", cut("a\xf0\x9f\x98\x80", 4));
    try t.expectEqualStrings("a\xf0\x9f\x98\x80", cut("a\xf0\x9f\x98\x80b", 5));
}

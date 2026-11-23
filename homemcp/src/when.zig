//! Times as hubs write them (ISO 8601) and as homemcp writes them (UTC,
//! to the second).
const std = @import("std");

/// "2026-11-22T10:01:02Z" for seconds since 1970.
pub fn isoTime(buf: *[20]u8, secs: i64) []const u8 {
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
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
        @as(u64, @intCast(@max(0, y))), @as(u64, @intCast(m)), @as(u64, @intCast(d)), sod / 3600, sod / 60 % 60, sod % 60,
    }) catch unreachable;
}

/// Milliseconds since 1970 of an ISO 8601 time such as
/// 2026-11-22T10:01:02.123456+00:00 or 2026-11-22T10:01:02Z; null when it
/// isn't one.
pub fn parseMs(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var rest = s[19..];
    var ms: i64 = 0;
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        var scale: i64 = 100;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
            ms += @as(i64, rest[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
        rest = rest[i..];
    }
    var offset_s: i64 = 0;
    if (rest.len >= 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const oh = std.fmt.parseInt(i64, rest[1..3], 10) catch return null;
        const om = std.fmt.parseInt(i64, rest[4..6], 10) catch return null;
        offset_s = (oh * 3600 + om * 60) * @as(i64, if (rest[0] == '-') -1 else 1);
    }
    // days from civil (Howard Hinnant)
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = if (mo > 2) mo - 3 else mo + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return (days * 86400 + hh * 3600 + mm * 60 + ss - offset_s) * 1000 + ms;
}

test "times, written and read" {
    var b: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-22T00:00:00Z", isoTime(&b, 1795305600));
    try std.testing.expectEqual(1795305600 * 1000 + 123, parseMs("2026-11-22T00:00:00.123456+00:00").?);
    try std.testing.expectEqual(1795305600 * 1000, parseMs("2026-11-22T01:00:00+01:00").?);
    try std.testing.expectEqual(1795305600 * 1000, parseMs("2026-11-22T00:00:00Z").?);
    try std.testing.expect(parseMs("unknown") == null);
    try std.testing.expect(parseMs("2026-13-22T00:00:00Z") == null);
}

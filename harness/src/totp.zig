//! One-time codes for logins that ask for them (RFC 6238: HMAC-SHA1,
//! 30-second steps, 6 digits), and the base32 their seeds are written in.
const std = @import("std");

pub const step_s = 30;

/// RFC 4648 base32, any case; spaces, dashes and `=` are skipped. Returns
/// the decoded part of `out`.
pub fn base32Decode(out: []u8, in: []const u8) ![]u8 {
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (in) |c| {
        const v: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a',
            '2'...'7' => c - '2' + 26,
            ' ', '=', '-', '\t' => continue,
            else => return error.BadBase32,
        };
        acc = (acc << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            if (n >= out.len) return error.NoSpaceLeft;
            out[n] = @truncate(acc >> bits);
            n += 1;
            acc &= (@as(u32, 1) << bits) - 1;
        }
    }
    return out[0..n];
}

/// The code for `seed` (raw bytes, not base32) at `unix_s`.
pub fn code(seed: []const u8, unix_s: i64) [6]u8 {
    const counter: u64 = @intCast(@divFloor(@max(unix_s, 0), step_s));
    var msg: [8]u8 = undefined;
    std.mem.writeInt(u64, &msg, counter, .big);
    var mac: [20]u8 = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&mac, &msg, seed);
    const off = mac[19] & 0x0f;
    const bin = std.mem.readInt(u32, mac[off..][0..4], .big) & 0x7fff_ffff;
    var out: [6]u8 = undefined;
    var v = bin % 1_000_000;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return out;
}

const t = std.testing;

test "totp_rfc6238_sha1_vectors" {
    const seed = "12345678901234567890";
    try t.expectEqualStrings("287082", &code(seed, 59));
    try t.expectEqualStrings("081804", &code(seed, 1111111109));
    try t.expectEqualStrings("005924", &code(seed, 1234567890));
    try t.expectEqualStrings("279037", &code(seed, 2000000000));
}

test "base32_decodes_any_case_and_skips_padding" {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("Hello!\xde\xad\xbe\xef", try base32Decode(&buf, "JBSWY3DPEHPK3PXP"));
    try t.expectEqualStrings("Hello!\xde\xad\xbe\xef", try base32Decode(&buf, "jbsw y3dp ehpk 3pxp"));
    try t.expectEqualStrings("f", try base32Decode(&buf, "MY======"));
    try t.expectError(error.BadBase32, base32Decode(&buf, "JBSW1"));
}

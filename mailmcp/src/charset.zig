//! Text in the character sets mail is written in, turned into UTF-8.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// `bytes` in `charset` as UTF-8. Unknown or empty charsets are read as
/// UTF-8; bytes that aren't valid there become U+FFFD. US-ASCII text with
/// bytes of 0x80 and up is read as UTF-8 when it is valid UTF-8, else as
/// Windows-1252.
pub fn toUtf8(a: Allocator, charset: []const u8, bytes: []const u8) ![]u8 {
    return switch (identify(charset)) {
        .utf8 => fixUtf8(a, bytes),
        .ascii => if (std.unicode.utf8ValidateSlice(bytes)) a.dupe(u8, bytes) else single(a, &cp1252, bytes),
        .latin1, .cp1252 => single(a, &cp1252, bytes),
        .latin2 => single(a, &latin2, bytes),
        .cp1250 => single(a, &cp1250, bytes),
        .latin9 => single(a, &latin9, bytes),
    };
}

/// Whether `bytes` is valid UTF-8.
pub fn isUtf8Text(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

const Charset = enum { utf8, ascii, latin1, latin2, cp1250, cp1252, latin9 };

const aliases = [_]struct { []const u8, Charset }{
    .{ "utf8", .utf8 },
    .{ "usascii", .ascii },
    .{ "ascii", .ascii },
    .{ "ansix3.41968", .ascii },
    .{ "iso88591", .latin1 },
    .{ "latin1", .latin1 },
    .{ "l1", .latin1 },
    .{ "isoir100", .latin1 },
    .{ "iso88592", .latin2 },
    .{ "latin2", .latin2 },
    .{ "l2", .latin2 },
    .{ "isoir101", .latin2 },
    .{ "windows1250", .cp1250 },
    .{ "cp1250", .cp1250 },
    .{ "xcp1250", .cp1250 },
    .{ "windows1252", .cp1252 },
    .{ "cp1252", .cp1252 },
    .{ "xcp1252", .cp1252 },
    .{ "iso885915", .latin9 },
    .{ "latin9", .latin9 },
    .{ "l9", .latin9 },
};

/// The charset a name stands for, ignoring case, quotes, "-" and "_".
fn identify(name: []const u8) Charset {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (std.mem.trim(u8, name, " \t\r\n\"'")) |c| {
        if (c == '-' or c == '_') continue;
        if (n == buf.len) return .utf8;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    for (aliases) |al| {
        if (std.mem.eql(u8, al[0], buf[0..n])) return al[1];
    }
    return .utf8;
}

/// A single-byte charset through its table for 0x80-0xFF.
fn single(a: Allocator, table: *const [128]u16, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, bytes.len + bytes.len / 2);
    for (bytes) |b| {
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
        } else {
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(table[b - 0x80], &enc) catch unreachable;
            try out.appendSlice(a, enc[0..len]);
        }
    }
    return out.items;
}

const replacement = "\u{FFFD}";

/// UTF-8 with a leading byte order mark dropped and each invalid byte
/// replaced by U+FFFD.
fn fixUtf8(a: Allocator, bytes: []const u8) ![]u8 {
    const s = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    if (std.unicode.utf8ValidateSlice(s)) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len + s.len / 2);
    var i: usize = 0;
    while (i < s.len) {
        const n = seqLen(s[i..]);
        if (n == 0) {
            try out.appendSlice(a, replacement);
            i += 1;
        } else {
            try out.appendSlice(a, s[i .. i + n]);
            i += n;
        }
    }
    return out.items;
}

/// Length of the valid UTF-8 sequence at the start of `s`, or 0.
fn seqLen(s: []const u8) usize {
    const c = s[0];
    if (c < 0x80) return 1;
    const n: usize, const lo: u8, const hi: u8 = switch (c) {
        0xC2...0xDF => .{ 2, 0x80, 0xBF },
        0xE0 => .{ 3, 0xA0, 0xBF },
        0xE1...0xEC, 0xEE, 0xEF => .{ 3, 0x80, 0xBF },
        0xED => .{ 3, 0x80, 0x9F },
        0xF0 => .{ 4, 0x90, 0xBF },
        0xF1...0xF3 => .{ 4, 0x80, 0xBF },
        0xF4 => .{ 4, 0x80, 0x8F },
        else => return 0,
    };
    if (s.len < n or s[1] < lo or s[1] > hi) return 0;
    for (s[2..n]) |b| {
        if (b & 0xC0 != 0x80) return 0;
    }
    return n;
}

// High halves (0x80-0xFF) as code points. 0x80-0x9F in the ISO tables
// follow the Windows table of the same script: those bytes only turn up in
// text written on Windows. Undefined bytes are U+FFFD.

const cp1252 = [128]u16{
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
    0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
    0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
    0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
    0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
    0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
    0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
    0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
    0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
    0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
    0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
    0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
};

const cp1250 = [128]u16{
    0x20AC, 0xFFFD, 0x201A, 0xFFFD, 0x201E, 0x2026, 0x2020, 0x2021,
    0xFFFD, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0xFFFD, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
    0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7,
    0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
    0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
    0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
    0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7,
    0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
    0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7,
    0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
    0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7,
    0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
    0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7,
    0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
};

const latin2 = [128]u16{
    0x20AC, 0xFFFD, 0x201A, 0xFFFD, 0x201E, 0x2026, 0x2020, 0x2021,
    0xFFFD, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0xFFFD, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
    0x00A0, 0x0104, 0x02D8, 0x0141, 0x00A4, 0x013D, 0x015A, 0x00A7,
    0x00A8, 0x0160, 0x015E, 0x0164, 0x0179, 0x00AD, 0x017D, 0x017B,
    0x00B0, 0x0105, 0x02DB, 0x0142, 0x00B4, 0x013E, 0x015B, 0x02C7,
    0x00B8, 0x0161, 0x015F, 0x0165, 0x017A, 0x02DD, 0x017E, 0x017C,
    0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7,
    0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
    0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7,
    0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
    0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7,
    0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
    0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7,
    0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
};

const latin9 = [128]u16{
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x20AC, 0x00A5, 0x0160, 0x00A7,
    0x0161, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
    0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x017D, 0x00B5, 0x00B6, 0x00B7,
    0x017E, 0x00B9, 0x00BA, 0x00BB, 0x0152, 0x0153, 0x0178, 0x00BF,
    0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
    0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
    0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
    0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
    0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
    0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
    0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
    0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
};

const testing = std.testing;

test "polish_letters_in_every_charset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = "ąćęłńóśźż ĄĆĘŁŃÓŚŹŻ";
    try testing.expectEqualStrings(want, try toUtf8(a, "iso-8859-2", "\xB1\xE6\xEA\xB3\xF1\xF3\xB6\xBC\xBF \xA1\xC6\xCA\xA3\xD1\xD3\xA6\xAC\xAF"));
    try testing.expectEqualStrings(want, try toUtf8(a, "windows-1250", "\xB9\xE6\xEA\xB3\xF1\xF3\x9C\x9F\xBF \xA5\xC6\xCA\xA3\xD1\xD3\x8C\x8F\xAF"));
    try testing.expectEqualStrings(want, try toUtf8(a, "utf-8", want));
    // Windows-1250's dash and quotes, as Outlook writes them.
    try testing.expectEqualStrings("„Łódź” – 5 €", try toUtf8(a, "cp1250", "\x84\xA3\xF3d\x9F\x94 \x96 5 \x80"));
}

test "charset_names_are_case_insensitive_with_aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l2 = "\xA3\xF3d\xBC";
    for ([_][]const u8{ "ISO-8859-2", "iso8859-2", "Latin2", "l2", "\"iso-8859-2\"", " iso_8859-2 " }) |name| {
        try testing.expectEqualStrings("Łódź", try toUtf8(a, name, l2));
    }
    for ([_][]const u8{ "Windows-1250", "CP1250", "x-cp1250" }) |name| {
        try testing.expectEqualStrings("Święta", try toUtf8(a, name, "\x8Cwi\xEAta"));
    }
    for ([_][]const u8{ "ISO-8859-1", "latin1", "L1", "windows-1252", "cp1252" }) |name| {
        try testing.expectEqualStrings("Café", try toUtf8(a, name, "Caf\xE9"));
    }
    try testing.expectEqualStrings("Prix: 10 €", try toUtf8(a, "ISO-8859-15", "Prix: 10 \xA4"));
    try testing.expectEqualStrings("zażółć", try toUtf8(a, "UTF8", "zażółć"));
}

test "windows_1252_high_range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("€ “quoted” – ‘it’s’ … ™ Œ ž Ÿ", try toUtf8(a, "windows-1252", "\x80 \x93quoted\x94 \x96 \x91it\x92s\x92 \x85 \x99 \x8C \x9E \x9F"));
    // ISO-8859-1 mail with those bytes was written on Windows.
    try testing.expectEqualStrings("“Hi”", try toUtf8(a, "iso-8859-1", "\x93Hi\x94"));
}

test "ascii_label_with_high_bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("plain text", try toUtf8(a, "us-ascii", "plain text"));
    try testing.expectEqualStrings("Café – ok", try toUtf8(a, "US-ASCII", "Caf\xE9 \x96 ok"));
    // UTF-8 under an ASCII label stays UTF-8.
    try testing.expectEqualStrings("Dzień dobry", try toUtf8(a, "ascii", "Dzień dobry"));
}

test "unknown_charset_is_utf8_and_invalid_bytes_are_replaced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("łódź", try toUtf8(a, "x-unknown-charset", "łódź"));
    try testing.expectEqualStrings("łódź", try toUtf8(a, "", "łódź"));
    try testing.expectEqualStrings("a\u{FFFD}b", try toUtf8(a, "utf-8", "a\xFFb"));
    try testing.expectEqualStrings("end\u{FFFD}", try toUtf8(a, "utf-8", "end\xC5"));
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}/", try toUtf8(a, "utf-8", "\xC0\xAF/"));
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}\u{FFFD}x", try toUtf8(a, "utf-8", "\xED\xA0\x80x"));
    try testing.expectEqualStrings("ok", try toUtf8(a, "utf-8", "\xEF\xBB\xBFok"));
    try testing.expect(isUtf8Text("zażółć"));
    try testing.expect(!isUtf8Text("za\xBF\xF3"));
}

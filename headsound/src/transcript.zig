//! Turning speech into text, around the recogniser: which stretches of a
//! recording to hand it (pieces of at most `max_chunk_s`, cut in pauses), and
//! how to group the words it returns into lines a reader can follow
//! (captions). The recogniser itself is the platform's (macOS: Speech).
const std = @import("std");

pub const Span = struct { start: f64, end: f64 };

pub const Word = struct {
    text: []const u8,
    start: f64,
    end: f64,
    confidence: f64,
    /// False where the language writes words together (Chinese, Japanese).
    space_before: bool = true,
};

pub const Line = struct {
    start: f64,
    end: f64,
    /// Words in `words[first..last]`.
    first: usize,
    last: usize,
};

/// The recogniser is given at most this much at a time.
pub const max_chunk_s = 30.0;
/// Sound kept around each piece, so first and last syllables aren't cut.
const pad_s = 0.25;

/// Speech stretches joined into pieces of at most `max_s`, each cut in a
/// pause; a stretch longer than `max_s` is cut every `max_s`. Each piece is
/// padded by `pad_s` within [0, duration].
pub fn chunks(alloc: std.mem.Allocator, speech: []const Span, duration: f64, max_s: f64) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < speech.len) {
        var cur = speech[i];
        i += 1;
        while (i < speech.len and speech[i].end - cur.start <= max_s) : (i += 1) cur.end = speech[i].end;
        // one stretch longer than max_s: cut it into equal pieces
        const len = cur.end - cur.start;
        const pieces: usize = @max(1, @as(usize, @trunc(@ceil(len / max_s))));
        const step = len / @as(f64, @floatFromInt(pieces));
        for (0..pieces) |p| {
            const s = cur.start + step * @as(f64, @floatFromInt(p));
            const e = if (p + 1 == pieces) cur.end else s + step;
            try out.append(alloc, .{
                .start = @max(0, s - (if (p == 0) pad_s else @as(f64, 0))),
                .end = @min(duration, e + (if (p + 1 == pieces) pad_s else @as(f64, 0))),
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const max_line_chars = 84;
pub const max_line_s = 7.0;
/// A pause this long starts a new line.
const line_gap_s = 0.7;

/// Words grouped into lines: a new line after a pause of `line_gap_s`,
/// before one would pass `max_line_chars` or `max_line_s`, and after a
/// sentence's end once the line has 20 characters or more.
pub fn lines(alloc: std.mem.Allocator, words: []const Word) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < words.len) {
        const first = i;
        var chars = width(words[i].text);
        i += 1;
        while (i < words.len) : (i += 1) {
            const prev = words[i - 1];
            const cur = words[i];
            if (cur.start - prev.end >= line_gap_s) break;
            const add = @intFromBool(cur.space_before) + width(cur.text);
            if (chars + add > max_line_chars) break;
            if (cur.end - words[first].start > max_line_s) break;
            if (chars >= 20 and endsSentence(prev.text)) break;
            chars += add;
        }
        try out.append(alloc, .{ .start = words[first].start, .end = words[i - 1].end, .first = first, .last = i });
    }
    return out.toOwnedSlice(alloc);
}

fn endsSentence(s: []const u8) bool {
    for ([_][]const u8{ ".", "?", "!", "\u{3002}", "\u{FF1F}", "\u{FF01}" }) |e| if (std.mem.endsWith(u8, s, e)) return true;
    return false;
}

/// Characters, not bytes.
fn width(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The words of `l`, with a space where the language puts one.
pub fn text(alloc: std.mem.Allocator, words: []const Word, l: Line) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (words[l.first..l.last], 0..) |x, k| {
        if (k > 0 and x.space_before) try out.append(alloc, ' ');
        try out.appendSlice(alloc, x.text);
    }
    return out.toOwnedSlice(alloc);
}

/// A locale name for --lang: letters, digits, '-' and '_', as "en-US".
pub fn validLocale(s: []const u8) bool {
    if (s.len < 2 or s.len > 32) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

// ---- tests ----

const testing = std.testing;

test "speech_is_cut_into_pieces_in_its_pauses" {
    const sp = [_]Span{
        .{ .start = 1, .end = 10 },
        .{ .start = 11, .end = 25 },
        .{ .start = 26, .end = 40 }, // would make the piece 39 s
        .{ .start = 50, .end = 120 }, // 70 s of talk without a pause
    };
    const cs = try chunks(testing.allocator, &sp, 120.1, 30);
    defer testing.allocator.free(cs);
    try testing.expectEqual(@as(usize, 5), cs.len);
    try testing.expectEqual(@as(f64, 0.75), cs[0].start);
    try testing.expectEqual(@as(f64, 25.25), cs[0].end);
    try testing.expectEqual(@as(f64, 25.75), cs[1].start);
    try testing.expectEqual(@as(f64, 40.25), cs[1].end);
    // 70 s in three pieces of 23.3 s, padded only at the outer ends
    try testing.expectApproxEqAbs(@as(f64, 49.75), cs[2].start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50 + 70.0 / 3.0), cs[2].end, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50 + 140.0 / 3.0), cs[3].end, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 120.1), cs[4].end, 1e-9);
}

fn w(t: []const u8, s: f64, e: f64) Word {
    return .{ .text = t, .start = s, .end = e, .confidence = 0.9 };
}

test "words_are_grouped_into_readable_lines" {
    const ws = [_]Word{
        w("Hello", 0.0, 0.4),
        w("there.", 0.45, 0.8), // a sentence's end, but the line is short
        w("How", 0.9, 1.0),
        w("are", 1.05, 1.2),
        w("you", 1.25, 1.4),
        w("today?", 1.45, 1.9), // ends a line of 20+ characters
        w("Fine", 2.0, 2.3),
        w("thanks", 3.2, 3.6), // after a 0.9 s pause
    };
    const ls = try lines(testing.allocator, &ws);
    defer testing.allocator.free(ls);
    try testing.expectEqual(@as(usize, 3), ls.len);
    const t0 = try text(testing.allocator, &ws, ls[0]);
    defer testing.allocator.free(t0);
    try testing.expectEqualStrings("Hello there. How are you today?", t0);
    try testing.expectEqual(@as(f64, 1.9), ls[0].end);
    try testing.expectEqual(@as(usize, 6), ls[1].first);
    try testing.expectEqual(@as(usize, 7), ls[1].last);
    try testing.expectEqual(@as(f64, 3.2), ls[2].start);
}

test "a_long_run_of_words_is_split_by_time_and_length" {
    var ws: [40]Word = undefined;
    for (&ws, 0..) |*x, k| {
        const s = @as(f64, @floatFromInt(k)) * 0.3;
        x.* = w("word", s, s + 0.25);
    }
    const ls = try lines(testing.allocator, &ws);
    defer testing.allocator.free(ls);
    for (ls) |l| {
        try testing.expect(l.end - l.start <= max_line_s);
        try testing.expect((l.last - l.first) * 5 - 1 <= max_line_chars);
    }
    try testing.expectEqual(@as(usize, 40), ls[ls.len - 1].last);
}

test "words_without_spaces_between_them_are_joined_as_they_were" {
    const ws = [_]Word{
        .{ .text = "你好", .start = 0, .end = 0.4, .confidence = 1, .space_before = false },
        .{ .text = "世界。", .start = 0.4, .end = 0.9, .confidence = 1, .space_before = false },
    };
    const ls = try lines(testing.allocator, &ws);
    defer testing.allocator.free(ls);
    const t = try text(testing.allocator, &ws, ls[0]);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("你好世界。", t);
    // characters, not bytes: 30 four-character words fit in 84 + some
    var many: [30]Word = undefined;
    for (&many, 0..) |*x, k| {
        const s = @as(f64, @floatFromInt(k)) * 0.2;
        x.* = .{ .text = "你好世界", .start = s, .end = s + 0.15, .confidence = 1, .space_before = false };
    }
    const ls2 = try lines(testing.allocator, &many);
    defer testing.allocator.free(ls2);
    try testing.expectEqual(@as(usize, 21), ls2[0].last); // 84 characters
}

test "locale_names" {
    try testing.expect(validLocale("en-US"));
    try testing.expect(validLocale("zh_Hans_CN"));
    try testing.expect(!validLocale("en US"));
    try testing.expect(!validLocale("x"));
}

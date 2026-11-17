//! A streamed answer ("server-sent events") cut into its lines as the bytes
//! arrive, however the network split them.
const std = @import("std");

pub const Splitter = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Where the next unread line begins in `buf`.
    start: usize = 0,

    pub fn deinit(s: *Splitter, gpa: std.mem.Allocator) void {
        s.buf.deinit(gpa);
    }

    /// Adds bytes as they arrived. Lines handed out before are no longer valid.
    pub fn feed(s: *Splitter, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if (s.start > 0) {
            const left = s.buf.items.len - s.start;
            std.mem.copyForwards(u8, s.buf.items[0..left], s.buf.items[s.start..]);
            s.buf.items.len = left;
            s.start = 0;
        }
        try s.buf.appendSlice(gpa, bytes);
    }

    /// The next whole line, without its line end; null when none is complete.
    pub fn next(s: *Splitter) ?[]const u8 {
        const nl = std.mem.indexOfScalarPos(u8, s.buf.items, s.start, '\n') orelse return null;
        var line = s.buf.items[s.start..nl];
        s.start = nl + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }

    /// What is left after the last line end (a stream cut off mid-line).
    pub fn rest(s: *const Splitter) []const u8 {
        return s.buf.items[s.start..];
    }
};

/// The payload of a "data:" line; null for any other line.
pub fn data(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "data:")) return null;
    const rest = line[5..];
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

// ---- tests ----

const testing = std.testing;

test "lines_come_out_whole_however_the_bytes_were_split" {
    var s: Splitter = .{};
    defer s.deinit(testing.allocator);
    try s.feed(testing.allocator, "data: {\"a\"");
    try testing.expect(s.next() == null);
    try s.feed(testing.allocator, ":1}\n\ndata: two\r\n: keep-alive\nda");
    try testing.expectEqualStrings("data: {\"a\":1}", s.next().?);
    try testing.expectEqualStrings("", s.next().?);
    try testing.expectEqualStrings("data: two", s.next().?);
    try testing.expectEqualStrings(": keep-alive", s.next().?);
    try testing.expect(s.next() == null);
    try testing.expectEqualStrings("da", s.rest());
    try s.feed(testing.allocator, "ta: [DONE]\n");
    try testing.expectEqualStrings("data: [DONE]", s.next().?);
    try testing.expectEqualStrings("", s.rest());
}

test "only_data_lines_carry_a_payload" {
    try testing.expectEqualStrings("{\"a\":1}", data("data: {\"a\":1}").?);
    try testing.expectEqualStrings("[DONE]", data("data:[DONE]").?);
    try testing.expectEqualStrings(" x", data("data:  x").?);
    try testing.expect(data(": comment") == null);
    try testing.expect(data("event: message") == null);
    try testing.expect(data("") == null);
}

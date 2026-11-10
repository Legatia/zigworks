//! asciicast v2 recording (https://docs.asciinema.org/manual/asciicast/v2/):
//! a JSON header line, then one `[seconds, "o"|"i"|"r", "data"]` line per
//! event. Playable with `asciinema play`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Recorder = struct {
    gpa: Allocator,
    file: std.fs.File,
    start_ns: i128,
    /// Start of a UTF-8 character split across two PTY reads.
    pending: [3]u8 = undefined,
    pending_len: usize = 0,

    /// Creates (or truncates) `path` and writes the header.
    pub fn create(gpa: Allocator, path: []const u8, cols: usize, rows: usize, argv: []const []const u8) !Recorder {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        errdefer file.close();
        var r: Recorder = .{ .gpa = gpa, .file = file, .start_ns = std.time.nanoTimestamp() };

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const command = try std.mem.join(gpa, " ", argv);
        defer gpa.free(command);
        try std.json.Stringify.value(.{
            .version = 2,
            .width = cols,
            .height = rows,
            .timestamp = @divTrunc(r.start_ns, std.time.ns_per_s),
            .command = command,
            .env = .{ .TERM = "xterm-256color" },
        }, .{}, &out.writer);
        try out.writer.writeByte('\n');
        try r.file.writeAll(out.written());
        return r;
    }

    pub fn deinit(r: *Recorder) void {
        r.file.close();
    }

    /// Program output. Errors are ignored: recording is best effort and must
    /// never disturb the session.
    pub fn output(r: *Recorder, bytes: []const u8) void {
        r.outputImpl(bytes) catch {};
    }

    fn outputImpl(r: *Recorder, bytes: []const u8) !void {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(r.gpa);
        try joined.appendSlice(r.gpa, r.pending[0..r.pending_len]);
        try joined.appendSlice(r.gpa, bytes);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(r.gpa);
        const used = try appendValidUtf8(r.gpa, &text, joined.items, true);
        r.pending_len = joined.items.len - used;
        @memcpy(r.pending[0..r.pending_len], joined.items[used..]);
        if (text.items.len > 0) try r.event("o", text.items);
    }

    /// Input sent to the program with `send`.
    pub fn input(r: *Recorder, bytes: []const u8) void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(r.gpa);
        _ = appendValidUtf8(r.gpa, &text, bytes, false) catch return;
        if (text.items.len > 0) r.event("i", text.items) catch {};
    }

    pub fn resize(r: *Recorder, cols: usize, rows: usize) void {
        var buf: [32]u8 = undefined;
        const size = std.fmt.bufPrint(&buf, "{d}x{d}", .{ cols, rows }) catch return;
        r.event("r", size) catch {};
    }

    fn event(r: *Recorder, kind: []const u8, data: []const u8) !void {
        const elapsed_ns = std.time.nanoTimestamp() - r.start_ns;
        const secs = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / std.time.ns_per_s;
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();
        try out.writer.print("[{d:.6}, \"{s}\", ", .{ secs, kind });
        try std.json.Stringify.encodeJsonString(data, .{}, &out.writer);
        try out.writer.writeAll("]\n");
        try r.file.writeAll(out.written());
    }
};

/// Appends `in` to `out` as valid UTF-8, with invalid bytes as U+FFFD.
/// With `keep_tail`, an incomplete character at the end is not consumed and
/// the returned count stops before it.
fn appendValidUtf8(gpa: Allocator, out: *std.ArrayList(u8), in: []const u8, keep_tail: bool) !usize {
    const replacement = "\u{FFFD}";
    var i: usize = 0;
    while (i < in.len) {
        const b = in[i];
        if (b < 0x80) {
            try out.append(gpa, b);
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            try out.appendSlice(gpa, replacement);
            i += 1;
            continue;
        };
        if (i + len > in.len) {
            const rest = in[i + 1 ..];
            const continuation = for (rest) |c| {
                if (c & 0xC0 != 0x80) break false;
            } else true;
            if (keep_tail and continuation) return i;
            try out.appendSlice(gpa, replacement);
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(in[i..][0..len])) |_| {
            try out.appendSlice(gpa, in[i..][0..len]);
            i += len;
        } else |_| {
            try out.appendSlice(gpa, replacement);
            i += 1;
        }
    }
    return in.len;
}

// ======================================================================
// Tests

const testing = std.testing;

test "asciicast v2: header, events and UTF-8 split across reads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "rec.cast" });
    defer testing.allocator.free(path);

    var r = try Recorder.create(testing.allocator, path, 80, 24, &.{ "vim", "notes.txt" });
    r.output("hello \xe4\xb8"); // "中" split across two reads
    r.output("\xad \"quoted\"\r\n");
    r.output("bad \xff byte");
    r.input("ihi\x1b");
    r.resize(100, 30);
    r.deinit();

    const data = try tmp.dir.readFileAlloc(testing.allocator, "rec.cast", 1 << 20);
    defer testing.allocator.free(data);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, data, "\n"), '\n');

    const header = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer header.deinit();
    const h = header.value.object;
    try testing.expectEqual(@as(i64, 2), h.get("version").?.integer);
    try testing.expectEqual(@as(i64, 80), h.get("width").?.integer);
    try testing.expectEqual(@as(i64, 24), h.get("height").?.integer);
    try testing.expect(h.get("timestamp").?.integer > 1_600_000_000);
    try testing.expectEqualStrings("vim notes.txt", h.get("command").?.string);

    const expected = [_]struct { []const u8, []const u8 }{
        .{ "o", "hello " },
        .{ "o", "中 \"quoted\"\r\n" },
        .{ "o", "bad \u{FFFD} byte" },
        .{ "i", "ihi\x1b" },
        .{ "r", "100x30" },
    };
    var last_time: f64 = 0;
    for (expected) |e| {
        const ev = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
        defer ev.deinit();
        const arr = ev.value.array.items;
        try testing.expectEqual(@as(usize, 3), arr.len);
        const t: f64 = switch (arr[0]) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.TestUnexpectedResult,
        };
        try testing.expect(t >= last_time);
        last_time = t;
        try testing.expectEqualStrings(e[0], arr[1].string);
        try testing.expectEqualStrings(e[1], arr[2].string);
    }
    try testing.expect(lines.next() == null);
}

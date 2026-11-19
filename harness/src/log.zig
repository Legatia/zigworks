//! The action log: one JSON object per line, each carrying the SHA-256 of
//! the line before it, so an edited, removed or reordered line is found by
//! `verify`. Tamper-evident, not tamper-proof: someone who can write the
//! file can rewrite the whole chain.
const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Kind = enum { turn, model, tool, gate, memory, brief, task, chat, config, recovered };

/// Longest string stored in a field.
pub const max_field = 2048;

const zero_hash: [64]u8 = @splat('0');

pub const Log = struct {
    gpa: std.mem.Allocator,
    io: Io,
    file: Io.File,
    offset: u64,
    seq: u64,
    last: [64]u8,
    mutex: Io.Mutex = .init,

    /// Opens (or creates) the log, drops a last line cut off by a crash and
    /// notes that it did.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !Log {
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true, .permissions = .fromMode(0o600) });
        errdefer f.close(io);
        const len = try f.length(io);
        var l: Log = .{ .gpa = gpa, .io = io, .file = f, .offset = len, .seq = 0, .last = zero_hash };
        var torn = false;
        if (len > 0) {
            // the last lines are enough: fields are capped, so a line is short
            const tail_len: usize = @intCast(@min(len, 256 * 1024));
            const tail = try gpa.alloc(u8, tail_len);
            defer gpa.free(tail);
            _ = try f.readPositionalAll(io, tail, len - tail_len);
            var end = tail.len;
            if (tail[end - 1] != '\n') {
                torn = true;
                end = if (std.mem.lastIndexOfScalar(u8, tail, '\n')) |i| i + 1 else 0;
                l.offset = len - tail_len + end;
                try f.setLength(io, l.offset);
            }
            if (end > 0) {
                const body = tail[0 .. end - 1];
                const start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| i + 1 else 0;
                const line = body[start..];
                l.last = hashLine(line);
                l.seq = seqOf(line) orelse 0;
            }
        }
        if (torn) try l.write(.recovered, false, .{ .why = "a line cut off by a crash was removed" });
        return l;
    }

    pub fn close(l: *Log) void {
        l.file.close(l.io);
    }

    pub fn lastHash(l: *Log) [64]u8 {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        return l.last;
    }

    /// Appends one line. `fields` is a struct of strings, integers, bools
    /// and optionals. When `private`, string fields other than `tool`,
    /// `decision` and `why` are stored as their size and SHA-256 only.
    pub fn write(l: *Log, kind: Kind, private: bool, fields: anytype) !void {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(l.gpa);
        const gpa = l.gpa;
        var tbuf: [20]u8 = undefined;
        try line.print(gpa, "{{\"seq\":{d},\"time\":\"{s}\",\"kind\":\"{s}\"", .{ l.seq + 1, util.isoTime(&tbuf, util.nowSeconds(l.io)), @tagName(kind) });
        const T = @TypeOf(fields);
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names) |name| {
            try line.print(gpa, ",\"{s}\":", .{name});
            try value(&line, gpa, name, @field(fields, name), private);
        }
        try line.print(gpa, ",\"prev\":\"{s}\"}}", .{l.last});
        const h = hashLine(line.items);
        try line.append(gpa, '\n');
        try l.file.writePositionalAll(l.io, line.items, l.offset);
        l.offset += line.items.len;
        l.seq += 1;
        l.last = h;
    }
};

fn value(line: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime name: []const u8, v: anytype, private: bool) !void {
    const V = @TypeOf(v);
    switch (@typeInfo(V)) {
        .optional => if (v) |inner| return value(line, gpa, name, inner, private) else return line.appendSlice(gpa, "null"),
        .bool => return line.appendSlice(gpa, if (v) "true" else "false"),
        .int, .comptime_int => return line.print(gpa, "{d}", .{v}),
        .float, .comptime_float => return line.print(gpa, "{d}", .{v}),
        .@"enum", .enum_literal => return util.jsonString(line, gpa, @tagName(v)),
        else => {},
    }
    const s: []const u8 = v;
    const kept = comptime (std.mem.eql(u8, name, "tool") or std.mem.eql(u8, name, "decision") or std.mem.eql(u8, name, "why"));
    if (private and !kept) {
        var d: [32]u8 = undefined;
        Sha256.hash(s, &d, .{});
        return line.print(gpa, "{{\"bytes\":{d},\"sha256\":\"{x}\"}}", .{ s.len, &d });
    }
    if (s.len > max_field) {
        try util.jsonString(line, gpa, util.cut(s, max_field));
        line.items.len -= 1; // reopen the string to add the mark
        return line.appendSlice(gpa, "…\"");
    }
    return util.jsonString(line, gpa, s);
}

fn hashLine(line: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(line, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn seqOf(line: []const u8) ?u64 {
    const key = "{\"seq\":";
    if (!std.mem.startsWith(u8, line, key)) return null;
    const rest = line[key.len..];
    const end = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

fn prevOf(line: []const u8) ?[]const u8 {
    const key = ",\"prev\":\"";
    if (!std.mem.endsWith(u8, line, "\"}") or line.len < key.len + 64 + 2) return null;
    const start = line.len - 2 - 64;
    if (!std.mem.eql(u8, line[start - key.len .. start], key)) return null;
    return line[start .. start + 64];
}

pub const Verdict = struct { lines: u64, broken_at: ?u64, last: [64]u8 };

/// Checks the chain from the first line; `broken_at` is the first line (1-based)
/// whose `prev` does not match the line before or whose seq is out of order.
pub fn verify(io: Io, path: []const u8) !Verdict {
    var f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [256 * 1024]u8 = undefined;
    var r = f.reader(io, &buf);
    var prev: [64]u8 = zero_hash;
    var n: u64 = 0;
    while (true) {
        const raw = (try r.interface.takeDelimiter('\n')) orelse break;
        if (raw.len == 0) break;
        n += 1;
        const line = raw;
        const p = prevOf(line) orelse return .{ .lines = n, .broken_at = n, .last = prev };
        if (!std.mem.eql(u8, p, &prev) or (seqOf(line) orelse 0) != n) return .{ .lines = n, .broken_at = n, .last = prev };
        prev = hashLine(line);
    }
    return .{ .lines = n, .broken_at = null, .last = prev };
}

const t = std.testing;

fn tmpPath(tmp: *t.TmpDir, a: std.mem.Allocator) ![]u8 {
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    return std.fs.path.join(a, &.{ dir, "actions.jsonl" });
}

test "lines_chain_and_verify" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    try l.write(.tool, false, .{ .tool = "shell", .arg = "ls -l", .code = @as(i32, 0) });
    try l.write(.gate, false, .{ .tool = "fetch", .decision = "deny", .why = "rule on line 2", .note = @as(?[]const u8, null) });
    const last = l.lastHash();
    l.close();
    const v = try verify(t.io, path);
    try t.expectEqual(2, v.lines);
    try t.expectEqual(null, v.broken_at);
    try t.expectEqualSlices(u8, &last, &v.last);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "\"seq\":1,") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"arg\":\"ls -l\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"note\":null") != null);
}

test "edited_line_is_found_by_verify" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    for (0..3) |_| try l.write(.tool, false, .{ .arg = "rm -rf build" });
    l.close();
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    const edited = try std.mem.replaceOwned(u8, arena.allocator(), text, "rm -rf build", "ls build    ");
    // only the first occurrence matters for where it breaks: every line was edited,
    // so line 2 is the first whose prev no longer matches
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = edited });
    const v = try verify(t.io, path);
    try t.expectEqual(2, v.broken_at.?);
    // a removed line
    const lines_only = std.mem.indexOfScalar(u8, text, '\n').? + 1;
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = text[lines_only..] });
    try t.expectEqual(1, (try verify(t.io, path)).broken_at.?);
}

test "torn_last_line_is_dropped_and_recovery_logged" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    try l.write(.chat, false, .{ .text = "hello" });
    l.close();
    {
        var f = try Io.Dir.cwd().openFile(t.io, path, .{ .mode = .read_write });
        defer f.close(t.io);
        const len = try f.length(t.io);
        try f.writePositionalAll(t.io, "{\"seq\":2,\"time\":\"2026", len);
    }
    var l2 = try Log.open(t.allocator, t.io, path);
    try l2.write(.chat, false, .{ .text = "after" });
    l2.close();
    const v = try verify(t.io, path);
    try t.expectEqual(null, v.broken_at);
    try t.expectEqual(3, v.lines);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "\"kind\":\"recovered\"") != null);
}

test "private_lines_keep_only_metadata" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    try l.write(.tool, true, .{ .tool = "shell", .decision = "allow", .arg = "cat diary.txt", .output = "dear diary" });
    l.close();
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "diary") == null);
    try t.expect(std.mem.indexOf(u8, text, "\"tool\":\"shell\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"arg\":{\"bytes\":13,\"sha256\":\"") != null);
}

test "long_fields_are_cut_at_2kb" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    const big = try arena.allocator().alloc(u8, 10_000);
    @memset(big, 'x');
    try l.write(.tool, false, .{ .output = big });
    l.close();
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    try t.expect(text.len < 2400);
    try t.expect(std.mem.indexOf(u8, text, "x…\"") != null);
    try t.expectEqual(null, (try verify(t.io, path)).broken_at);
}

test "reopen_continues_seq_and_chain" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    for (0..3) |_| {
        var l = try Log.open(t.allocator, t.io, path);
        try l.write(.turn, false, .{ .n = @as(u8, 1) });
        try l.write(.turn, false, .{ .n = @as(u8, 2) });
        l.close();
    }
    const v = try verify(t.io, path);
    try t.expectEqual(6, v.lines);
    try t.expectEqual(null, v.broken_at);
}

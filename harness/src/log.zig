//! The action log: one JSON object per line, each carrying the SHA-256 of
//! the line before it, so an edited, removed or reordered line is found by
//! `verify`. Tamper-evident, not tamper-proof: someone who can write the
//! file can rewrite the whole chain.
const std = @import("std");
const util = @import("util.zig");
const scrub = @import("scrub.zig");
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
    /// Masks the stored secrets in every string written (`setSecrets`).
    scrubber: ?scrub.Scrubber = null,
    /// The instance's key for the hashes of private lines (`useKey`), so
    /// a guessable text cannot be confirmed from the log alone.
    key: ?[32]u8 = null,

    /// Opens (or creates) the log, drops a last line cut off by a crash and
    /// notes that it did.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !Log {
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true, .permissions = util.private_file });
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
        if (l.scrubber) |*sc| sc.deinit();
        l.file.close(l.io);
    }

    /// Takes the key for private lines' hashes from `path` (hex), making
    /// one there (readable only by the owner) if there is none. Without a
    /// key, private lines keep only sizes.
    pub fn useKey(l: *Log, io: Io, path: []const u8) !void {
        for (0..2) |_| {
            var buf: [80]u8 = undefined;
            if (Io.Dir.cwd().readFile(io, path, &buf)) |got| {
                var k: [32]u8 = undefined;
                const hex = std.mem.trim(u8, got, " \r\n");
                if (hex.len != 64) return error.BadLogKey;
                _ = std.fmt.hexToBytes(&k, hex) catch return error.BadLogKey;
                l.key = k;
                return;
            } else |e| if (e != error.FileNotFound) return e;
            var k: [32]u8 = undefined;
            try io.randomSecure(&k);
            var f = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = util.private_file }) catch |e| switch (e) {
                // made by another process meanwhile: read that one
                error.PathAlreadyExists => continue,
                else => return e,
            };
            defer f.close(io);
            const hex = std.fmt.bytesToHex(k, .lower);
            try f.writeStreamingAll(io, &hex ++ "\n");
            l.key = k;
            return;
        }
        return error.BadLogKey;
    }

    /// From now on every string field written has these values masked as
    /// `[secret:NAME]`; call again when the list changes. The values must
    /// outlive the log.
    pub fn setSecrets(l: *Log, secrets: []const scrub.Secret) !void {
        var sc = try scrub.Scrubber.init(l.gpa, secrets);
        errdefer sc.deinit();
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        if (l.scrubber) |*old| old.deinit();
        l.scrubber = sc;
    }

    /// Whether some line near the end of the log hashes to `h`: the log
    /// only grew since `h` was its last line.
    pub fn contains(l: *Log, h: *const [64]u8) !bool {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        if (std.mem.eql(u8, h, &l.last)) return true;
        const tail_len: usize = @intCast(@min(l.offset, 4 * 1024 * 1024));
        const tail = try l.gpa.alloc(u8, tail_len);
        defer l.gpa.free(tail);
        _ = try l.file.readPositionalAll(l.io, tail, l.offset - tail_len);
        var it = std.mem.splitScalar(u8, tail, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const lh = hashLine(line);
            if (std.mem.eql(u8, &lh, h)) return true;
        }
        return false;
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
        const ctx: Ctx = .{ .private = private, .scrubber = if (l.scrubber) |*x| x else null, .key = if (l.key) |*k| k else null };
        inline for (info.field_names) |name| {
            try line.print(gpa, ",\"{s}\":", .{name});
            try value(&line, gpa, name, @field(fields, name), ctx);
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

/// How a line's fields are written.
const Ctx = struct { private: bool, scrubber: ?*scrub.Scrubber, key: ?*const [32]u8 };

fn value(line: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime name: []const u8, v: anytype, ctx: Ctx) !void {
    const V = @TypeOf(v);
    switch (@typeInfo(V)) {
        .optional => if (v) |inner| return value(line, gpa, name, inner, ctx) else return line.appendSlice(gpa, "null"),
        .bool => return line.appendSlice(gpa, if (v) "true" else "false"),
        .int, .comptime_int => return line.print(gpa, "{d}", .{v}),
        .float, .comptime_float => return line.print(gpa, "{d}", .{v}),
        .@"enum", .enum_literal => return util.jsonString(line, gpa, @tagName(v)),
        else => {},
    }
    const raw: []const u8 = v;
    // a value the owner typed or a tool read never reaches the file
    const masked: ?[]u8 = if (ctx.scrubber) |x| try x.scrubAlloc(gpa, raw) else null;
    defer if (masked) |m| gpa.free(m);
    const s: []const u8 = masked orelse raw;
    const kept = comptime (std.mem.eql(u8, name, "tool") or std.mem.eql(u8, name, "decision") or std.mem.eql(u8, name, "why"));
    if (ctx.private and !kept) {
        const key = ctx.key orelse return line.print(gpa, "{{\"bytes\":{d}}}", .{s.len});
        var d: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&d, s, key);
        return line.print(gpa, "{{\"bytes\":{d},\"hmac\":\"{x}\"}}", .{ s.len, &d });
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
        n += 1;
        // a blank line is only allowed as the very end
        if (raw.len == 0) {
            const more = (try r.interface.takeDelimiter('\n')) orelse return .{ .lines = n - 1, .broken_at = null, .last = prev };
            _ = more;
            return .{ .lines = n, .broken_at = n, .last = prev };
        }
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
    // without the instance key, only the size
    try t.expect(std.mem.indexOf(u8, text, "\"arg\":{\"bytes\":13}") != null);
}

test "private_hashes_are_keyed_with_the_instance_key" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmpPath(&tmp, a);
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const key_path = try std.fs.path.join(a, &.{ dir, "log-key" });
    var hashes: [3][]const u8 = undefined;
    for (0..3) |i| {
        // the third time with another instance's key
        const kp = if (i == 2) try std.fs.path.join(a, &.{ dir, "other-key" }) else key_path;
        var l = try Log.open(t.allocator, t.io, path);
        try l.useKey(t.io, kp);
        try l.write(.tool, true, .{ .arg = "cat diary.txt" });
        l.close();
        const text = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
        const at = std.mem.lastIndexOf(u8, text, "\"arg\":{\"bytes\":13,\"hmac\":\"").? + 29;
        hashes[i] = text[at .. at + 64];
    }
    // keyed: not the plain SHA-256 of the text, the same with the same key
    var d: [32]u8 = undefined;
    Sha256.hash("cat diary.txt", &d, .{});
    try t.expect(!std.mem.eql(u8, hashes[0], &std.fmt.bytesToHex(d, .lower)));
    try t.expectEqualStrings(hashes[0], hashes[1]);
    try t.expect(!std.mem.eql(u8, hashes[0], hashes[2]));
    if (@import("builtin").os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, key_path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    try t.expectEqual(null, (try verify(t.io, path)).broken_at);
}

test "secrets_are_masked_in_every_field" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    try l.setSecrets(&.{.{ .name = "omnigate", .value = "og-secret-value-123" }});
    try l.write(.turn, false, .{ .run = "chat", .text = "my key is og-secret-value-123, keep it", .why = "og-secret-value-123" });
    try l.write(.tool, true, .{ .tool = "og-secret-value-123", .arg = "og-secret-value-123" });
    l.close();
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    try t.expect(std.mem.indexOf(u8, text, "og-secret-value-123") == null);
    try t.expect(std.mem.indexOf(u8, text, "\"text\":\"my key is [secret:omnigate], keep it\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"tool\":\"[secret:omnigate]\"") != null);
    try t.expectEqual(null, (try verify(t.io, path)).broken_at);
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

test "blank_line_inserted_is_found_by_verify" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    for (0..3) |_| try l.write(.tool, false, .{ .arg = "rm -rf build" });
    l.close();
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena.allocator(), .unlimited);
    const first = std.mem.indexOfScalar(u8, text, '\n').? + 1;
    const edited = try std.mem.concat(arena.allocator(), u8, &.{ text[0..first], "\n", try std.mem.replaceOwned(u8, arena.allocator(), text[first..], "rm -rf", "ls -la") });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = edited });
    try t.expectEqual(2, (try verify(t.io, path)).broken_at.?);
}

test "a_log_that_only_grew_contains_the_old_end" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const path = try tmpPath(&tmp, arena.allocator());
    var l = try Log.open(t.allocator, t.io, path);
    try l.write(.chat, false, .{ .text = "a" });
    const mid = l.lastHash();
    try l.write(.chat, false, .{ .text = "b" });
    l.close();
    var l2 = try Log.open(t.allocator, t.io, path);
    defer l2.close();
    try t.expect(try l2.contains(&mid));
    const other: [64]u8 = @splat('f');
    try t.expect(!try l2.contains(&other));
}

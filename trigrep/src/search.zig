//! Scans candidate files for matching lines, in parallel, printing results in order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const query = @import("query.zig");
const index = @import("index.zig");

pub const Mode = enum { lines, files_with_matches, count };

pub const Config = struct {
    prog: *const regex.Program,
    plan: query.Plan,
    mode: Mode = .lines,
    max_count: ?usize = null,
};

pub const Job = struct {
    /// Path to open, relative to the root directory handle.
    path: []const u8,
    /// Path to print.
    display: []const u8,
};

pub const Totals = struct {
    files_scanned: usize = 0,
    files_matched: usize = 0,
    lines_matched: usize = 0,
    bytes_scanned: u64 = 0,
    /// Output stopped at the line limit; there may be more matches.
    truncated: bool = false,
    lines_written: usize = 0,
};

pub fn countNewlines(s: []const u8) usize {
    const V = @Vector(32, u8);
    const nl: V = @splat('\n');
    var n: usize = 0;
    var i: usize = 0;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        n += @popCount(@as(u32, @bitCast(v == nl)));
    }
    while (i < s.len) : (i += 1) n += @intFromBool(s[i] == '\n');
    return n;
}

fn findLiteral(hay: []const u8, start: usize, lit: query.Literal) ?usize {
    if (lit.ignore_case) return std.ascii.indexOfIgnoreCasePos(hay, start, lit.bytes);
    return std.mem.indexOfPos(u8, hay, start, lit.bytes);
}

/// Earliest occurrence of any of several literals, remembering each one's next hit so a
/// literal is only searched again once the scan has passed it.
const MultiFinder = struct {
    lits: []const query.Literal,
    next: [max]?usize = undefined,
    valid: [max]bool = [_]bool{false} ** max,

    const max = 16;

    fn find(f: *MultiFinder, hay: []const u8, start: usize) ?usize {
        var best: ?usize = null;
        for (f.lits, 0..) |lit, i| {
            if (!f.valid[i] or (f.next[i] != null and f.next[i].? < start)) {
                f.next[i] = findLiteral(hay, start, lit);
                f.valid[i] = true;
            }
            if (f.next[i]) |p| {
                if (best == null or p < best.?) best = p;
            }
        }
        return best;
    }
};

/// Searches one file's contents. Appends output to `out` and returns the number of
/// matching lines.
pub fn searchBuffer(
    gpa: Allocator,
    m: *regex.Matcher,
    cfg: Config,
    data: []const u8,
    display: []const u8,
    out: *std.ArrayList(u8),
) !usize {
    var matches: usize = 0;
    var line_no: usize = 1;
    var counted_to: usize = 0;
    var pos: usize = 0;
    const limit = cfg.max_count orelse std.math.maxInt(usize);
    var multi: ?MultiFinder = null;
    if (cfg.plan.required == null) if (cfg.plan.alternatives) |alts| {
        if (alts.len <= MultiFinder.max) multi = .{ .lits = alts };
    };

    while (pos <= data.len and matches < limit) {
        var line_start = pos;
        var line_end: usize = undefined;
        const prefiltered = cfg.plan.required != null or multi != null;
        if (prefiltered) {
            const hit = (if (cfg.plan.required) |lit| findLiteral(data, pos, lit) else multi.?.find(data, pos)) orelse break;
            if (std.mem.lastIndexOfScalar(u8, data[pos..hit], '\n')) |nl| line_start = pos + nl + 1;
            line_end = std.mem.indexOfScalarPos(u8, data, hit, '\n') orelse data.len;
        } else {
            if (pos == data.len and (data.len == 0 or data[data.len - 1] == '\n')) break;
            line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        }
        const line = data[line_start..line_end];
        if ((prefiltered and cfg.plan.pure_literal) or m.isMatch(line)) {
            matches += 1;
            if (cfg.mode == .files_with_matches) break;
            if (cfg.mode == .lines) {
                line_no += countNewlines(data[counted_to..line_start]);
                counted_to = line_start;
                try out.print(gpa, "{s}:{d}:{s}\n", .{ display, line_no, line });
            }
        }
        pos = line_end + 1;
    }
    if (matches > 0) switch (cfg.mode) {
        .files_with_matches => try out.print(gpa, "{s}\n", .{display}),
        .count => try out.print(gpa, "{s}:{d}\n", .{ display, matches }),
        .lines => {},
    };
    return matches;
}

const Result = struct { out: std.ArrayList(u8) = .empty, matches: usize = 0, bytes: u64 = 0, scanned: bool = false };

const Worker = struct {
    gpa: Allocator,
    cfg: Config,
    root: std.fs.Dir,
    jobs: []const Job,
    results: []Result,
    base: usize,
    end: usize,
    next: *std.atomic.Value(usize),
    matcher: regex.Matcher,
    buf: std.ArrayList(u8) = .empty,
    failed: ?anyerror = null,

    fn run(w: *Worker) void {
        while (true) {
            const i = w.next.fetchAdd(1, .monotonic);
            if (i >= w.end) break;
            w.scan(i) catch |err| {
                if (err == error.OutOfMemory) w.failed = err;
            };
        }
    }

    fn scan(w: *Worker, i: usize) !void {
        const job = w.jobs[i];
        const r = &w.results[i - w.base];
        var f = try w.root.openFile(job.path, .{});
        defer f.close();
        const size = (try f.stat()).size;
        try w.buf.resize(w.gpa, @intCast(size));
        const n = try f.readAll(w.buf.items);
        const data = w.buf.items[0..n];
        if (index.isBinary(data)) return;
        r.scanned = true;
        r.bytes = n;
        r.matches = try searchBuffer(w.gpa, &w.matcher, w.cfg, data, job.display, &r.out);
    }
};

/// Scans `jobs` with `threads` workers and writes their output, in job order, to `out`,
/// stopping after `limit` output lines.
pub fn run(gpa: Allocator, root: std.fs.Dir, jobs: []const Job, cfg: Config, threads: usize, limit: ?usize, out: *std.Io.Writer) !Totals {
    var totals = Totals{};
    const n_threads = @max(1, @min(threads, jobs.len));
    if (jobs.len == 0) return totals;

    const chunk = 1024;
    const results = try gpa.alloc(Result, @min(chunk, jobs.len));
    defer gpa.free(results);
    var next = std.atomic.Value(usize).init(0);

    const workers = try gpa.alloc(Worker, n_threads);
    defer gpa.free(workers);
    var made: usize = 0;
    defer for (workers[0..made]) |*w| {
        w.matcher.deinit(gpa);
        w.buf.deinit(gpa);
    };
    for (workers) |*w| {
        w.* = .{
            .gpa = gpa,
            .cfg = cfg,
            .root = root,
            .jobs = jobs,
            .results = results,
            .base = 0,
            .end = 0,
            .next = &next,
            .matcher = try regex.Matcher.init(gpa, cfg.prog),
        };
        made += 1;
    }
    const handles = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(handles);

    var start: usize = 0;
    while (start < jobs.len) : (start += chunk) {
        const end = @min(start + chunk, jobs.len);
        for (results[0 .. end - start]) |*r| r.* = .{};
        next.store(start, .monotonic);
        for (workers) |*w| {
            w.base = start;
            w.end = end;
        }
        if (n_threads == 1) {
            workers[0].run();
        } else {
            for (workers, 0..) |*w, i| handles[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
            for (handles) |h| h.join();
        }
        for (workers) |w| if (w.failed) |err| return err;
        const max_lines = limit orelse std.math.maxInt(usize);
        for (results[0 .. end - start]) |*r| {
            defer r.out.deinit(gpa);
            if (r.scanned) totals.files_scanned += 1;
            totals.bytes_scanned += r.bytes;
            if (r.matches == 0 or totals.truncated) continue;
            totals.files_matched += 1;
            totals.lines_matched += r.matches;
            var text = r.out.items;
            const room = max_lines - totals.lines_written;
            const lines = countNewlines(text);
            if (lines > room) {
                var cut: usize = 0;
                for (0..room) |_| cut = std.mem.indexOfScalarPos(u8, text, cut, '\n').? + 1;
                text = text[0..cut];
                totals.truncated = true;
            }
            totals.lines_written += @min(lines, room);
            try out.writeAll(text);
        }
        if (totals.truncated) break;
    }
    return totals;
}

// ---------------------------------------------------------------------------
// Tests

fn runSearch(pattern: []const u8, opts: regex.Options, mode: Mode, data: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try regex.parse(arena.allocator(), pattern, opts);
    const prog = try regex.compile(arena.allocator(), root);
    const p = try query.plan(arena.allocator(), root);
    var m = try regex.Matcher.init(gpa, &prog);
    defer m.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    _ = try searchBuffer(gpa, &m, .{ .prog = &prog, .plan = p, .mode = mode }, data, "f", &out);
    return out.toOwnedSlice(gpa);
}

test "line numbers with and without a required literal" {
    const gpa = std.testing.allocator;
    const text = "alpha\nbeta gamma\ngamma\n\ndelta gamma";
    const a = try runSearch("gamma", .{}, .lines, text);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("f:2:beta gamma\nf:3:gamma\nf:5:delta gamma\n", a);
    const b = try runSearch("^g\\w+$", .{}, .lines, text);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("f:3:gamma\n", b);
    const c = try runSearch("^$", .{}, .lines, text);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("f:4:\n", c);
}

test "alternation prefilter" {
    const gpa = std.testing.allocator;
    const a = try runSearch("TODO|FIXME", .{}, .lines, "x\nFIXME a\nTODO b\nnone\nTODO\n");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("f:2:FIXME a\nf:3:TODO b\nf:5:TODO\n", a);
    const b = try runSearch("ab|x", .{ .ignore_case = true }, .lines, "AB\nzz\nX\n");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("f:1:AB\nf:3:X\n", b);
}

test "count and files-with-matches" {
    const gpa = std.testing.allocator;
    const a = try runSearch("a", .{}, .count, "a\nb\na\n");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("f:2\n", a);
    const b = try runSearch("B", .{ .ignore_case = true }, .files_with_matches, "a\nb\n");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("f\n", b);
}

test "a match on the first line and the last unterminated line" {
    const gpa = std.testing.allocator;
    const a = try runSearch("x", .{}, .lines, "x1\ny\nx3");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("f:1:x1\nf:3:x3\n", a);
}

test "countNewlines" {
    try std.testing.expectEqual(@as(usize, 0), countNewlines(""));
    try std.testing.expectEqual(@as(usize, 3), countNewlines("a\nb\nc\n"));
    const long = "\n" ** 100;
    try std.testing.expectEqual(@as(usize, 100), countNewlines(long));
}

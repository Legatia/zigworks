//! Scans candidate files for matching lines, in parallel, printing results in order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const query = @import("query.zig");
const index = @import("index.zig");

pub const Mode = enum { lines, files_with_matches, count };

/// Lines of context to print around each match (like rg -B/-A).
pub const Context = struct {
    before: usize = 0,
    after: usize = 0,

    pub fn active(c: Context) bool {
        return c.before > 0 or c.after > 0;
    }
};

/// How text output looks. trigrep's own default is `path:line:text`; in ripgrep mode
/// these follow ripgrep's flags exactly.
pub const TextStyle = struct {
    filename: bool = true,
    line_numbers: bool = true,
    /// Follow every printed path with NUL instead of the usual separator (--null).
    null_after_path: bool = false,
    /// Replace longer lines with ripgrep's "[Omitted long ... line]" (--max-columns).
    max_columns: ?usize = null,
};

pub const Config = struct {
    prog: *const regex.Program,
    plan: query.Plan,
    mode: Mode = .lines,
    max_count: ?usize = null,
    context: Context = .{},
    format: Format = .text,
    style: TextStyle = .{},
    /// Print each match instead of the whole line (-o).
    only_matching: bool = false,
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
    /// Individual matches (with -o or --json).
    matches: usize = 0,
    bytes_printed: usize = 0,
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

pub const Found = struct {
    /// Matching lines.
    lines: usize = 0,
    /// Individual matches (only counted when spans are computed: -o and --json).
    matches: usize = 0,
};

/// Searches one file's contents. Appends output to `out`.
pub fn searchBuffer(
    gpa: Allocator,
    m: *regex.Matcher,
    cfg: Config,
    data: []const u8,
    display: []const u8,
    out: *std.ArrayList(u8),
) !Found {
    var matches: usize = 0;
    var line_no: usize = 1;
    var counted_to: usize = 0;
    var pos: usize = 0;
    const limit = cfg.max_count orelse std.math.maxInt(usize);
    var multi: ?MultiFinder = null;
    if (cfg.plan.required == null) if (cfg.plan.alternatives) |alts| {
        if (alts.len <= MultiFinder.max) multi = .{ .lits = alts };
    };
    // A one- or two-byte required literal (like `-` in `\d+-\d+`) hits nearly every
    // line; scanning with the DFA is faster then.
    const weak_literal = cfg.plan.required != null and cfg.plan.required.?.bytes.len < 3;
    const prefiltered = (cfg.plan.required != null and !weak_literal) or multi != null;
    const one_pass = !prefiltered and m.canScan();
    const with_context = cfg.mode == .lines and cfg.context.active() and !cfg.only_matching;
    var ctx = ContextState{ .n = cfg.context.before };
    var pr = Printer{ .gpa = gpa, .out = out, .cfg = cfg, .display = display, .data = data, .m = m, .t0 = std.time.nanoTimestamp(), .out_start = out.items.len };

    while (pos <= data.len and matches < limit) {
        var line_start = pos;
        var line_end: usize = undefined;
        if (one_pass) {
            // No literal worth jumping to: let the DFA find the next matching line.
            line_start = m.nextMatchingLine(data, pos) orelse break;
            line_end = std.mem.indexOfScalarPos(u8, data, line_start, '\n') orelse data.len;
        } else if (prefiltered) {
            const hit = (if (cfg.plan.required) |lit| findLiteral(data, pos, lit) else multi.?.find(data, pos)) orelse break;
            if (std.mem.lastIndexOfScalar(u8, data[pos..hit], '\n')) |nl| line_start = pos + nl + 1;
            line_end = std.mem.indexOfScalarPos(u8, data, hit, '\n') orelse data.len;
        } else {
            if (pos == data.len and (data.len == 0 or data[data.len - 1] == '\n')) break;
            line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        }
        const line = data[line_start..line_end];
        if (one_pass or (prefiltered and cfg.plan.pure_literal) or m.isMatch(line)) {
            matches += 1;
            if (cfg.mode == .files_with_matches) break;
            if (cfg.mode == .lines) {
                line_no += countNewlines(data[counted_to..line_start]);
                counted_to = line_start;
                if (with_context) try ctx.before(&pr, line_start, line_no);
                try pr.matchLine(line_no, line_start, line_end);
                ctx.printed(line_end, line_no);
                if (with_context and cfg.context.after > 0) {
                    // Print the following lines; any that match restart the count.
                    var left = cfg.context.after;
                    var p = line_end + 1;
                    var no = line_no + 1;
                    while (left > 0 and p < data.len and matches < limit) : (no += 1) {
                        const e = std.mem.indexOfScalarPos(u8, data, p, '\n') orelse data.len;
                        if (m.isMatch(data[p..e])) {
                            matches += 1;
                            try pr.matchLine(no, p, e);
                            left = cfg.context.after;
                        } else {
                            try pr.contextLine(no, p, e);
                            left -= 1;
                        }
                        ctx.printed(e, no);
                        p = e + 1;
                    }
                    counted_to = @min(p, data.len);
                    line_no = no;
                    pos = p;
                    continue;
                }
            }
        }
        pos = line_end + 1;
    }
    if (matches > 0) switch (cfg.mode) {
        .files_with_matches => try out.print(gpa, "{s}{c}", .{ display, @as(u8, if (cfg.style.null_after_path) 0 else '\n') }),
        .count => if (cfg.style.filename)
            try out.print(gpa, "{s}{c}{d}\n", .{ display, @as(u8, if (cfg.style.null_after_path) 0 else ':'), matches })
        else
            try out.print(gpa, "{d}\n", .{matches}),
        .lines => try pr.finish(matches),
    };
    return .{ .lines = matches, .matches = pr.submatches };
}

pub const Format = enum { text, json };

fn writeJsonString(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

/// ripgrep's "arbitrary data" object: {"text": ...} for UTF-8, else {"bytes": base64}.
fn writeJsonData(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(s)) {
        try out.appendSlice(gpa, "{\"text\":");
        try writeJsonString(gpa, out, s);
    } else {
        try out.appendSlice(gpa, "{\"bytes\":\"");
        const enc = std.base64.standard.Encoder;
        const start = out.items.len;
        try out.resize(gpa, start + enc.calcSize(s.len));
        _ = enc.encode(out.items[start..], s);
        try out.append(gpa, '"');
    }
    try out.append(gpa, '}');
}

fn writeElapsed(gpa: Allocator, out: *std.ArrayList(u8), ns: i128) !void {
    const n: u64 = @intCast(@max(ns, 0));
    try out.print(gpa, "{{\"secs\":{d},\"nanos\":{d},\"human\":\"{d:.6}s\"}}", .{ n / std.time.ns_per_s, n % std.time.ns_per_s, @as(f64, @floatFromInt(n)) / 1e9 });
}

/// Writes match and context lines as plain text, only-matching text, or ripgrep's
/// JSON Lines format (begin/match/context/end records).
const Printer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    cfg: Config,
    display: []const u8,
    data: []const u8,
    m: *regex.Matcher,
    t0: i128,
    out_start: usize,
    began: bool = false,
    submatches: usize = 0,

    fn spans(p: *Printer, line: []const u8, list: *std.ArrayList(regex.Matcher.Span)) !void {
        var from: usize = 0;
        while (from <= line.len) {
            const sp = p.m.findSpan(line, from) orelse break;
            if (sp.end > sp.start) try list.append(p.gpa, sp);
            from = if (sp.end > sp.start) sp.end else sp.end + 1;
        }
    }

    fn begin(p: *Printer) !void {
        if (p.began) return;
        p.began = true;
        try p.out.appendSlice(p.gpa, "{\"type\":\"begin\",\"data\":{\"path\":");
        try writeJsonData(p.gpa, p.out, p.display);
        try p.out.appendSlice(p.gpa, "}}\n");
    }

    fn record(p: *Printer, kind: []const u8, no: usize, start: usize, end: usize, found: []const regex.Matcher.Span) !void {
        try p.begin();
        const with_nl = if (end < p.data.len) end + 1 else end;
        try p.out.print(p.gpa, "{{\"type\":\"{s}\",\"data\":{{\"path\":", .{kind});
        try writeJsonData(p.gpa, p.out, p.display);
        try p.out.appendSlice(p.gpa, ",\"lines\":");
        try writeJsonData(p.gpa, p.out, p.data[start..with_nl]);
        try p.out.print(p.gpa, ",\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[", .{ no, start });
        const line = p.data[start..end];
        for (found, 0..) |sp, i| {
            if (i > 0) try p.out.append(p.gpa, ',');
            try p.out.appendSlice(p.gpa, "{\"match\":");
            try writeJsonData(p.gpa, p.out, line[sp.start..sp.end]);
            try p.out.print(p.gpa, ",\"start\":{d},\"end\":{d}}}", .{ sp.start, sp.end });
        }
        try p.out.appendSlice(p.gpa, "]}}\n");
    }

    fn matchLine(p: *Printer, no: usize, start: usize, end: usize) !void {
        const line = p.data[start..end];
        if (p.cfg.format == .text and !p.cfg.only_matching) {
            return p.textLine(':', no, line, "[Omitted long matching line]");
        }
        var found: std.ArrayList(regex.Matcher.Span) = .empty;
        defer found.deinit(p.gpa);
        try p.spans(line, &found);
        p.submatches += found.items.len;
        if (p.cfg.format == .json) return p.record("match", no, start, end, found.items);
        for (found.items) |sp| try p.textLine(':', no, line[sp.start..sp.end], "[Omitted long matching line]");
    }

    fn contextLine(p: *Printer, no: usize, start: usize, end: usize) !void {
        if (p.cfg.format == .json) return p.record("context", no, start, end, &.{});
        try p.textLine('-', no, p.data[start..end], "[Omitted long context line]");
    }

    /// One line of text output: [path sep][line sep]text, per the style.
    fn textLine(p: *Printer, sep: u8, no: usize, text: []const u8, omitted: []const u8) !void {
        const st = p.cfg.style;
        if (st.filename) {
            try p.out.appendSlice(p.gpa, p.display);
            try p.out.append(p.gpa, if (st.null_after_path) 0 else sep);
        }
        if (st.line_numbers) try p.out.print(p.gpa, "{d}{c}", .{ no, sep });
        const long = if (st.max_columns) |m| text.len > m else false;
        try p.out.appendSlice(p.gpa, if (long) omitted else text);
        try p.out.append(p.gpa, '\n');
    }

    fn separator(p: *Printer) !void {
        if (p.cfg.format == .text) try p.out.appendSlice(p.gpa, "--\n");
    }

    fn finish(p: *Printer, matched_lines: usize) !void {
        if (p.cfg.format != .json or !p.began) return;
        const printed = p.out.items.len - p.out_start;
        try p.out.appendSlice(p.gpa, "{\"type\":\"end\",\"data\":{\"path\":");
        try writeJsonData(p.gpa, p.out, p.display);
        try p.out.appendSlice(p.gpa, ",\"binary_offset\":null,\"stats\":{\"elapsed\":");
        try writeElapsed(p.gpa, p.out, std.time.nanoTimestamp() - p.t0);
        try p.out.print(p.gpa, ",\"searches\":1,\"searches_with_match\":1,\"bytes_searched\":{d},\"bytes_printed\":{d},\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{ p.data.len, printed, matched_lines, p.submatches });
    }
};

/// Tracks what has been printed in a file, for context lines and `--` separators.
const ContextState = struct {
    n: usize,
    /// Byte offset just past the last printed line.
    end: usize = 0,
    last_no: usize = 0,
    any: bool = false,

    fn printed(c: *ContextState, line_end: usize, no: usize) void {
        c.end = line_end + 1;
        c.last_no = no;
        c.any = true;
    }

    /// Prints up to `n` lines before the line at `start` (number `no`) that haven't
    /// been printed yet, preceded by `--` if there's a gap since the last group.
    fn before(c: *ContextState, pr: *Printer, start: usize, no: usize) !void {
        const data = pr.data;
        var first = start;
        var count: usize = 0;
        while (count < c.n and first > 0 and first > c.end) {
            const prev = if (std.mem.lastIndexOfScalar(u8, data[0 .. first - 1], '\n')) |nl| nl + 1 else 0;
            if (prev < c.end) break;
            first = prev;
            count += 1;
        }
        const first_no = no - count;
        if (c.any and first_no > c.last_no + 1) try pr.separator();
        var p = first;
        var k = first_no;
        while (p < start) : (k += 1) {
            const e = std.mem.indexOfScalarPos(u8, data, p, '\n').?;
            try pr.contextLine(k, p, e);
            p = e + 1;
        }
    }
};

const Result = struct { out: std.ArrayList(u8) = .empty, matches: usize = 0, submatches: usize = 0, bytes: u64 = 0, scanned: bool = false };

const Shared = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    stop: std.atomic.Value(bool) = .init(false),
    failed: ?anyerror = null,
};

const Worker = struct {
    gpa: Allocator,
    cfg: Config,
    root: std.fs.Dir,
    jobs: []const Job,
    results: []Result,
    done: []std.atomic.Value(bool),
    next: *std.atomic.Value(usize),
    shared: *Shared,
    matcher: regex.Matcher,
    buf: std.ArrayList(u8) = .empty,

    fn run(w: *Worker) void {
        while (!w.shared.stop.load(.monotonic)) {
            const i = w.next.fetchAdd(1, .monotonic);
            if (i >= w.jobs.len) break;
            w.scan(i) catch |err| if (err == error.OutOfMemory) {
                w.shared.mutex.lock();
                w.shared.failed = err;
                w.shared.mutex.unlock();
            };
            w.done[i].store(true, .release);
            w.shared.mutex.lock();
            w.shared.cond.broadcast();
            w.shared.mutex.unlock();
        }
    }

    fn scan(w: *Worker, i: usize) !void {
        const job = w.jobs[i];
        const r = &w.results[i];
        var f = try w.root.openFile(job.path, .{});
        defer f.close();
        const size = (try f.stat()).size;
        try w.buf.resize(w.gpa, @intCast(size));
        const n = try f.readAll(w.buf.items);
        const data = w.buf.items[0..n];
        if (index.isBinary(data)) return;
        r.scanned = true;
        r.bytes = n;
        const found = try searchBuffer(w.gpa, &w.matcher, w.cfg, data, job.display, &r.out);
        r.matches = found.lines;
        r.submatches = found.matches;
    }
};

/// Scans `jobs` with `threads` workers and writes their output, in job order, to `out`,
/// stopping after `limit` output lines.
pub fn run(gpa: Allocator, root: std.fs.Dir, jobs: []const Job, cfg: Config, threads: usize, limit: ?usize, out: *std.Io.Writer) !Totals {
    const t0 = std.time.nanoTimestamp();
    const totals = try runJobs(gpa, root, jobs, cfg, threads, limit, out);
    if (cfg.format == .json and cfg.mode == .lines) {
        // ripgrep ends --json output with a summary record, matches or not.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try buf.appendSlice(gpa, "{\"data\":{\"elapsed_total\":");
        try writeElapsed(gpa, &buf, std.time.nanoTimestamp() - t0);
        try buf.print(gpa, ",\"stats\":{{\"bytes_printed\":{d},\"bytes_searched\":{d},\"elapsed\":", .{ totals.bytes_printed, totals.bytes_scanned });
        try writeElapsed(gpa, &buf, std.time.nanoTimestamp() - t0);
        try buf.print(gpa, ",\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{ totals.lines_matched, totals.matches, totals.files_scanned, totals.files_matched });
        try out.writeAll(buf.items);
    }
    return totals;
}

/// Workers take files in any order and run ahead; this thread prints each file's
/// output, in job order, as soon as it's ready.
fn runJobs(gpa: Allocator, root: std.fs.Dir, jobs: []const Job, cfg: Config, threads: usize, limit: ?usize, out: *std.Io.Writer) !Totals {
    var totals = Totals{};
    if (jobs.len == 0) return totals;
    const n_threads = @max(1, @min(threads, jobs.len));

    const results = try gpa.alloc(Result, jobs.len);
    defer gpa.free(results);
    for (results) |*r| r.* = .{};
    const done = try gpa.alloc(std.atomic.Value(bool), jobs.len);
    defer gpa.free(done);
    for (done) |*d| d.* = .init(false);
    var next = std.atomic.Value(usize).init(0);
    var shared = Shared{};

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
            .done = done,
            .next = &next,
            .shared = &shared,
            .matcher = try regex.Matcher.init(gpa, cfg.prog),
        };
        made += 1;
    }
    const handles = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(handles);
    var spawned: usize = 0;
    if (n_threads == 1) {
        workers[0].run();
    } else {
        for (workers, 0..) |*w, i| {
            handles[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
            spawned += 1;
        }
    }
    var printed: usize = 0;
    defer {
        shared.stop.store(true, .monotonic);
        for (handles[0..spawned]) |h| h.join();
        for (results[printed..]) |*r| r.out.deinit(gpa);
    }

    const max_lines = limit orelse std.math.maxInt(usize);
    while (printed < jobs.len) : (printed += 1) {
        if (!done[printed].load(.acquire)) {
            shared.mutex.lock();
            while (!done[printed].load(.acquire)) shared.cond.wait(&shared.mutex);
            shared.mutex.unlock();
        }
        if (shared.failed) |err| return err;
        const r = &results[printed];
        defer r.out.deinit(gpa);
        if (r.scanned) totals.files_scanned += 1;
        totals.bytes_scanned += r.bytes;
        if (r.matches == 0) continue;
        totals.files_matched += 1;
        totals.lines_matched += r.matches;
        totals.matches += r.submatches;
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
        if (cfg.mode == .lines and cfg.format == .text and cfg.context.active() and !cfg.only_matching and totals.files_matched > 1) try out.writeAll("--\n");
        try out.writeAll(text);
        totals.bytes_printed += text.len;
        if (totals.truncated) {
            printed += 1;
            break;
        }
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

fn runContext(pattern: []const u8, before: usize, after: usize, data: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try regex.parse(arena.allocator(), pattern, .{});
    const prog = try regex.compile(arena.allocator(), root);
    const p = try query.plan(arena.allocator(), root);
    var m = try regex.Matcher.init(gpa, &prog);
    defer m.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    _ = try searchBuffer(gpa, &m, .{ .prog = &prog, .plan = p, .context = .{ .before = before, .after = after } }, data, "f", &out);
    return out.toOwnedSlice(gpa);
}

test "context lines, merged groups and separators" {
    const gpa = std.testing.allocator;
    const text = "l1\nl2 hit\nl3\nl4\nl5\nl6\nl7 hit\nl8 hit\nl9\nl10";
    const a = try runContext("hit", 1, 1, text);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("f-1-l1\nf:2:l2 hit\nf-3-l3\n--\nf-6-l6\nf:7:l7 hit\nf:8:l8 hit\nf-9-l9\n", a);
    const b = try runContext("hit", 3, 0, text);
    defer gpa.free(b);
    // Matches ripgrep: line 3 is outside 7's three lines of context, so a gap.
    try std.testing.expectEqualStrings("f-1-l1\nf:2:l2 hit\n--\nf-4-l4\nf-5-l5\nf-6-l6\nf:7:l7 hit\nf:8:l8 hit\n", b);
    const c = try runContext("l10", 0, 2, text);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("f:10:l10\n", c);
    const d = try runContext("l1$", 2, 0, text);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("f:1:l1\n", d);
}

fn runWith(pattern: []const u8, cfg_in: Config, data: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try regex.parse(arena.allocator(), pattern, .{});
    const prog = try regex.compile(arena.allocator(), root);
    var cfg = cfg_in;
    cfg.prog = &prog;
    cfg.plan = try query.plan(arena.allocator(), root);
    var m = try regex.Matcher.init(gpa, &prog);
    defer m.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    _ = try searchBuffer(gpa, &m, cfg, data, "j.txt", &out);
    return out.toOwnedSlice(gpa);
}

test "only-matching prints each match" {
    const gpa = std.testing.allocator;
    const a = try runWith("fo+", .{ .prog = undefined, .plan = undefined, .only_matching = true }, "one foo two foo\nbar\nfoofoo\n");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("j.txt:1:foo\nj.txt:1:foo\nj.txt:3:foo\nj.txt:3:foo\n", a);
}

test "json records match ripgrep's shape" {
    const gpa = std.testing.allocator;
    const a = try runWith("fo+", .{ .prog = undefined, .plan = undefined, .format = .json }, "one foo two foo\nbar\nfoofoo\n");
    defer gpa.free(a);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, a, "\n"), '\n');
    try std.testing.expectEqualStrings("{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"j.txt\"}}}", lines.next().?);
    try std.testing.expectEqualStrings("{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"j.txt\"},\"lines\":{\"text\":\"one foo two foo\\n\"},\"line_number\":1,\"absolute_offset\":0,\"submatches\":[{\"match\":{\"text\":\"foo\"},\"start\":4,\"end\":7},{\"match\":{\"text\":\"foo\"},\"start\":12,\"end\":15}]}}", lines.next().?);
    try std.testing.expectEqualStrings("{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"j.txt\"},\"lines\":{\"text\":\"foofoo\\n\"},\"line_number\":3,\"absolute_offset\":20,\"submatches\":[{\"match\":{\"text\":\"foo\"},\"start\":0,\"end\":3},{\"match\":{\"text\":\"foo\"},\"start\":3,\"end\":6}]}}", lines.next().?);
    const end = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, end, "{\"type\":\"end\",\"data\":{\"path\":{\"text\":\"j.txt\"},\"binary_offset\":null,\"stats\":{\"elapsed\":"));
    try std.testing.expect(std.mem.endsWith(u8, end, "\"matched_lines\":2,\"matches\":4}}}"));
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, a, "\n"), '\n');
    while (it.next()) |l| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, l, .{});
        parsed.deinit();
    }
}

test "json escapes and non-UTF-8 bytes" {
    const gpa = std.testing.allocator;
    const a = try runWith("x", .{ .prog = undefined, .plan = undefined, .format = .json }, "\"x\"\t\\\n\xffx\n");
    defer gpa.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "{\"text\":\"\\\"x\\\"\\t\\\\\\n\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "{\"bytes\":\"/3gK\"}") != null);
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

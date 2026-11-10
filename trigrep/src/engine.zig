//! The search pipeline shared by the CLI and the MCP server: find or build the index,
//! check freshness, pick candidate files, scan them. Errors come back as an error plus
//! a message in `Diag`, never by exiting the process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const query = @import("query.zig");
const index = @import("index.zig");
const walk = @import("walk.zig");
const search = @import("search.zig");

pub const Diag = struct {
    message: []const u8 = "",
};

pub const Request = struct {
    pattern: []const u8,
    /// As given by the user; printed paths start with it. null = current directory.
    path: ?[]const u8 = null,
    opts: regex.Options = .{},
    mode: search.Mode = .lines,
    max_count: ?usize = null,
    globs: []const []const u8 = &.{},
    hidden: bool = false,
    no_index: bool = false,
    trust_index: bool = false,
    threads: ?usize = null,
    /// Stop after this many output lines.
    limit: ?usize = null,
};

pub const Outcome = struct {
    totals: search.Totals,
    /// Human-readable timings and counts (for --stats).
    stats: []const u8,
    /// Set when this search had to build the index first.
    built_index: ?[]const u8 = null,
    /// Advice worth showing, e.g. "many files changed, reindex".
    note: ?[]const u8 = null,
};

pub fn threadCount(t: ?usize) usize {
    return t orelse (std.Thread.getCpuCount() catch 4);
}

fn ms(since: i128) f64 {
    return @as(f64, @floatFromInt(std.time.nanoTimestamp() - since)) / 1e6;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn failWith(diag: *Diag, arena: Allocator, comptime fmt: []const u8, args: anytype) error{Failed} {
    diag.message = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
    return error.Failed;
}

pub fn gitRoot(arena: Allocator, start: []const u8) !?[]const u8 {
    var dir: []const u8 = start;
    while (true) {
        if (exists(try std.fs.path.join(arena, &.{ dir, ".git" }))) return dir;
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

pub const Found = struct { root: []const u8, path: []const u8 };

/// The closest index covering `target`: target itself or an ancestor.
pub fn findIndex(arena: Allocator, target: []const u8) !?Found {
    var dir: []const u8 = target;
    while (true) {
        const p = try index.pathFor(arena, dir);
        if (exists(p)) return .{ .root = dir, .path = p };
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

pub fn resolve(arena: Allocator, path: ?[]const u8, diag: *Diag) ![]const u8 {
    return std.fs.cwd().realpathAlloc(arena, path orelse ".") catch |err|
        failWith(diag, arena, "{s}: {s}", .{ path orelse ".", @errorName(err) });
}

pub const Built = struct { path: []const u8, stats: index.BuildStats, ms: f64 };

pub fn buildIndex(gpa: Allocator, arena: Allocator, root: []const u8, threads: ?usize) !Built {
    const t0 = std.time.nanoTimestamp();
    const entries = try walk.walk(arena, root, .{});
    const out = try index.pathFor(arena, root);
    const st = try index.build(gpa, root, entries, out, threadCount(threads));
    return .{ .path = out, .stats = st, .ms = ms(t0) };
}

pub fn describeBuild(arena: Allocator, root: []const u8, b: Built) ![]const u8 {
    return std.fmt.allocPrint(arena, "indexed {s}: {d} files ({d} binary), {d:.1} MB, {d} trigrams, index {d:.1} MB, {d:.0} ms", .{
        root,                                    b.stats.files,    b.stats.binary,
        @as(f64, @floatFromInt(b.stats.bytes)) / 1e6, b.stats.trigrams, @as(f64, @floatFromInt(b.stats.index_bytes)) / 1e6,
        b.ms,
    });
}

fn relUnder(root: []const u8, target: []const u8) []const u8 {
    if (target.len == root.len) return "";
    return target[root.len + 1 ..];
}

fn displayPath(arena: Allocator, arg: ?[]const u8, rel_to_target: []const u8) ![]const u8 {
    const p = arg orelse return rel_to_target;
    const trimmed = std.mem.trimRight(u8, p, "/");
    if (trimmed.len == 0) return std.fmt.allocPrint(arena, "/{s}", .{rel_to_target});
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ trimmed, rel_to_target });
}

pub fn patternError(err: anyerror) []const u8 {
    return switch (err) {
        error.BadPattern => "invalid pattern",
        error.Unsupported => "unsupported regex feature (lookaround, backreferences, \\p{..} and non-ASCII ranges aren't supported)",
        error.TooBig => "pattern too large (repetition counts are capped at 1000)",
        else => @errorName(err),
    };
}

/// Runs a search and writes `path:line:text` output to `out`.
pub fn run(gpa: Allocator, arena: Allocator, req: Request, out: *std.Io.Writer, diag: *Diag) !Outcome {
    const t_start = std.time.nanoTimestamp();
    const target = try resolve(arena, req.path, diag);
    const root_node = regex.parse(arena, req.pattern, req.opts) catch |err| return failWith(diag, arena, "{s}", .{patternError(err)});
    const prog = regex.compile(arena, root_node) catch |err| return failWith(diag, arena, "{s}", .{patternError(err)});
    const plan = try query.plan(arena, root_node);
    if (plan.required) |r| if (std.mem.indexOfScalar(u8, r.bytes, '\n') != null)
        return failWith(diag, arena, "the pattern contains a newline; trigrep matches single lines", .{});
    const filter = try walk.Filter.fromGlobs(arena, req.globs);
    const cfg = search.Config{ .prog = &prog, .plan = plan, .mode = req.mode, .max_count = req.max_count };
    const threads = threadCount(req.threads);

    // A single file: just scan it.
    if (std.fs.cwd().statFile(target)) |st| {
        if (st.kind == .file) {
            const job = [_]search.Job{.{ .path = target, .display = req.path orelse target }};
            const totals = try search.run(gpa, std.fs.cwd(), &job, cfg, 1, req.limit, out);
            return .{ .totals = totals, .stats = "single file" };
        }
    } else |_| {}

    var outcome = Outcome{ .totals = .{}, .stats = "" };
    var jobs: std.ArrayList(search.Job) = .empty;
    var root: []const u8 = target;
    const t_walk = std.time.nanoTimestamp();

    if (req.no_index) {
        const entries = try walk.walk(arena, target, .{ .hidden = req.hidden });
        for (entries) |e| {
            if (!filter.allows(e.path)) continue;
            try jobs.append(arena, .{ .path = e.path, .display = try displayPath(arena, req.path, e.path) });
        }
        outcome.stats = try std.fmt.allocPrint(arena, "no index; walk {d:.1} ms, {d} files", .{ ms(t_walk), entries.len });
    } else {
        var found = try findIndex(arena, target);
        if (found == null) {
            const r = (try gitRoot(arena, target)) orelse target;
            const b = buildIndex(gpa, arena, r, req.threads) catch |err|
                return failWith(diag, arena, "indexing {s} failed: {s}", .{ r, @errorName(err) });
            outcome.built_index = try describeBuild(arena, r, b);
            found = .{ .root = r, .path = b.path };
        }
        root = found.?.root;
        const prefix = relUnder(root, target);

        const t_load = std.time.nanoTimestamp();
        var ix = index.Index.open(found.?.path) catch |err|
            return failWith(diag, arena, "can't read index {s}: {s} (run `trigrep index`)", .{ found.?.path, @errorName(err) });
        defer ix.close();
        if (!std.mem.eql(u8, ix.root, root))
            return failWith(diag, arena, "index {s} belongs to {s}; run `trigrep index`", .{ found.?.path, ix.root });
        const cand = try ix.candidates(arena, plan.query);
        const load_ms = ms(t_load);
        const n_cand = if (cand) |c| c.len else ix.file_count;

        var cand_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, ix.file_count);
        if (cand) |ids| {
            for (ids) |id| cand_set.set(id);
        } else cand_set.setRangeValue(.{ .start = 0, .end = ix.file_count }, true);

        const strip = if (prefix.len == 0) 0 else prefix.len + 1;
        if (req.trust_index) {
            var id: u32 = 0;
            while (id < ix.file_count) : (id += 1) {
                if (!cand_set.isSet(id)) continue;
                const rec = ix.file(id);
                if (prefix.len > 0 and !(std.mem.startsWith(u8, rec.path, prefix) and rec.path.len > prefix.len and rec.path[prefix.len] == '/')) continue;
                if (!filter.allows(rec.path[strip..])) continue;
                // Copy: rec.path points into the index mapping, which is closed before the scan.
                const path = try arena.dupe(u8, rec.path);
                try jobs.append(arena, .{ .path = path, .display = try displayPath(arena, req.path, path[strip..]) });
            }
            outcome.stats = try std.fmt.allocPrint(arena, "index {d:.1} ms, {d} candidates, no freshness check", .{ load_ms, n_cand });
        } else {
            const t_fresh = std.time.nanoTimestamp();
            const entries = try walk.walk(arena, root, .{ .hidden = req.hidden, .prefix = prefix });
            var by_path = std.StringHashMapUnmanaged(u32){};
            try by_path.ensureTotalCapacity(arena, ix.file_count);
            var id: u32 = 0;
            while (id < ix.file_count) : (id += 1) by_path.putAssumeCapacity(ix.file(id).path, id);
            var dirty: usize = 0;
            for (entries) |e| {
                var changed = true;
                var candidate = true;
                if (by_path.get(e.path)) |fid| {
                    const rec = ix.file(fid);
                    changed = rec.size != e.size or rec.mtime != e.mtime;
                    candidate = cand_set.isSet(fid);
                }
                if (changed) dirty += 1;
                if (!changed and !candidate) continue;
                const rel = e.path[strip..];
                if (!filter.allows(rel)) continue;
                try jobs.append(arena, .{ .path = e.path, .display = try displayPath(arena, req.path, rel) });
            }
            if (dirty > 200 and dirty * 10 > entries.len)
                outcome.note = try std.fmt.allocPrint(arena, "{d} files changed since indexing; reindexing makes searches fast again", .{dirty});
            outcome.stats = try std.fmt.allocPrint(arena, "index {d:.1} ms, {d} candidates, freshness check {d:.1} ms over {d} files, {d} changed", .{ load_ms, n_cand, ms(t_fresh), entries.len, dirty });
        }
    }

    var root_dir = try std.fs.cwd().openDir(root, .{});
    defer root_dir.close();
    const t_scan = std.time.nanoTimestamp();
    outcome.totals = try search.run(gpa, root_dir, jobs.items, cfg, threads, req.limit, out);
    outcome.stats = try std.fmt.allocPrint(arena, "{s}; scanned {d} files ({d:.1} MB) in {d:.1} ms; {d} lines in {d} files; total {d:.1} ms", .{
        outcome.stats,                    outcome.totals.files_scanned, @as(f64, @floatFromInt(outcome.totals.bytes_scanned)) / 1e6,
        ms(t_scan),                       outcome.totals.lines_matched, outcome.totals.files_matched,
        ms(t_start),
    });
    return outcome;
}

pub const Status = struct {
    root: []const u8,
    index_path: []const u8,
    index_bytes: u64,
    age_s: i64,
    files: u32,
    trigrams: u32,
    modified: usize,
    added: usize,
    deleted: usize,
};

/// Index status for `target`, or null if no index covers it.
pub fn status(arena: Allocator, target: []const u8) !?Status {
    const found = (try findIndex(arena, target)) orelse return null;
    var ix = try index.Index.open(found.path);
    defer ix.close();
    const entries = try walk.walk(arena, found.root, .{});
    var by_path = std.StringHashMapUnmanaged(u32){};
    var id: u32 = 0;
    while (id < ix.file_count) : (id += 1) try by_path.put(arena, ix.file(id).path, id);
    var modified: usize = 0;
    var added: usize = 0;
    for (entries) |e| {
        if (by_path.fetchRemove(e.path)) |kv| {
            const rec = ix.file(kv.value);
            if (rec.size != e.size or rec.mtime != e.mtime) modified += 1;
        } else added += 1;
    }
    const st = try std.fs.cwd().statFile(found.path);
    return .{
        .root = found.root,
        .index_path = found.path,
        .index_bytes = st.size,
        .age_s = @intCast(@divTrunc(std.time.nanoTimestamp() - st.mtime, std.time.ns_per_s)),
        .files = ix.file_count,
        .trigrams = ix.tri_count,
        .modified = modified,
        .added = added,
        .deleted = by_path.count(),
    };
}

pub fn describeStatus(arena: Allocator, s: Status) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\root:     {s}
        \\index:    {s} ({d:.1} MB, built {d} s ago)
        \\files:    {d} indexed, {d} trigrams
        \\changed:  {d} modified, {d} new, {d} deleted
        \\
    , .{ s.root, s.index_path, @as(f64, @floatFromInt(s.index_bytes)) / 1e6, s.age_s, s.files, s.trigrams, s.modified, s.added, s.deleted });
}

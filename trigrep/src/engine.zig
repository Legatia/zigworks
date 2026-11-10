//! The search pipeline shared by the CLI and the MCP server: find or build the index,
//! check freshness, pick candidate files, scan them, and keep the index's delta up to
//! date. Errors come back as an error plus a message in `Diag`, never by exiting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const query = @import("query.zig");
const index = @import("index.zig");
const View = @import("view.zig").View;
const walk = @import("walk.zig");
const search = @import("search.zig");
const watch = @import("watch.zig");

pub const Diag = struct {
    message: []const u8 = "",
};

/// Where searches get the list of changed files from, instead of walking the tree:
/// an in-process watcher (MCP server) or a `trigrep watch` daemon (CLI).
pub const WatchHook = struct {
    ptr: *anyopaque,
    /// Changes under `root` since index state `state_id`; null if nothing watches it.
    changes: *const fn (ptr: *anyopaque, arena: Allocator, root: []const u8, index_path: []const u8, state_id: u64, hidden: bool) ?watch.Changes,
    /// A full walk of `root` just found `changed` to differ from index state
    /// `state_id`. Returns the watcher's sequence number after recording them.
    seeded: *const fn (ptr: *anyopaque, root: []const u8, state_id: u64, hidden: bool, changed: []const []const u8) u64,
    /// The index is now `new_state`, which includes every change up to `seq`.
    rebased: *const fn (ptr: *anyopaque, root: []const u8, seq: u64, new_state: u64) void,
    /// Whether searches may update the index delta themselves (false when a daemon
    /// owns the index).
    auto_update: bool,
};

pub const Request = struct {
    pattern: []const u8,
    /// As given by the user; printed paths start with it. null = current directory.
    path: ?[]const u8 = null,
    opts: regex.Options = .{},
    mode: search.Mode = .lines,
    max_count: ?usize = null,
    context: search.Context = .{},
    globs: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    types_not: []const []const u8 = &.{},
    format: search.Format = .text,
    only_matching: bool = false,
    hidden: bool = false,
    no_index: bool = false,
    trust_index: bool = false,
    threads: ?usize = null,
    /// Stop after this many output lines.
    limit: ?usize = null,
    watch: ?WatchHook = null,
};

pub const Outcome = struct {
    totals: search.Totals,
    /// Human-readable timings and counts (for --stats).
    stats: []const u8,
    /// Set when this search had to build the index first.
    built_index: ?[]const u8 = null,
    /// Set when this search folded changed files into the index delta.
    updated_index: ?[]const u8 = null,
    /// Advice worth showing.
    note: ?[]const u8 = null,
};

/// A search that sees at least this many changed files updates the index delta
/// afterwards, so later searches can use the index for them again.
pub const auto_update_threshold = 300;

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

/// Builds the base index for `root` from scratch and drops any delta.
pub fn buildIndex(gpa: Allocator, arena: Allocator, root: []const u8, threads: ?usize) !Built {
    const t0 = std.time.nanoTimestamp();
    const entries = try walk.walk(arena, root, .{});
    const out = try index.pathFor(arena, root);
    const st = try index.build(gpa, root, entries, out, threadCount(threads), .{});
    std.fs.cwd().deleteFile(try index.deltaPath(arena, out)) catch {};
    return .{ .path = out, .stats = st, .ms = ms(t0) };
}

pub fn describeBuild(arena: Allocator, root: []const u8, b: Built) ![]const u8 {
    return std.fmt.allocPrint(arena, "indexed {s}: {d} files ({d} binary), {d:.1} MB, {d} trigrams, index {d:.1} MB, {d:.0} ms", .{
        root,                                    b.stats.files,    b.stats.binary,
        @as(f64, @floatFromInt(b.stats.bytes)) / 1e6, b.stats.trigrams, @as(f64, @floatFromInt(b.stats.index_bytes)) / 1e6,
        b.ms,
    });
}

pub const Updated = struct {
    /// The new index state id.
    state_id: u64,
    /// Files now in the delta (changed, new or deleted relative to the base).
    delta_files: usize,
    /// The delta grew too large, so the base was rebuilt instead.
    rebuilt: ?Built = null,
    ms: f64,
};

pub fn describeUpdate(arena: Allocator, u: Updated) ![]const u8 {
    if (u.rebuilt) |b| return std.fmt.allocPrint(arena, "many changes, re{s}", .{try describeBuild(arena, "the root", b)});
    return std.fmt.allocPrint(arena, "updated the index: {d} files differ from the base index, {d:.0} ms", .{ u.delta_files, u.ms });
}

/// Rewrites the delta for the index at `index_path` so it covers `changed` (plus
/// whatever the old delta held). Rebuilds the base instead when the delta would hold
/// more than a quarter of the files.
pub fn updateDelta(gpa: Allocator, arena: Allocator, root: []const u8, index_path: []const u8, v: *const View, changed: []const []const u8, threads: ?usize) !Updated {
    const t0 = std.time.nanoTimestamp();
    var paths = std.StringHashMapUnmanaged(void){};
    if (v.delta) |d| {
        var i: u32 = 0;
        while (i < d.file_count) : (i += 1) try paths.put(arena, try arena.dupe(u8, d.file(i).path), {});
    }
    for (changed) |p| try paths.put(arena, p, {});
    if (paths.count() * 4 > v.base_files and paths.count() > 1000) {
        const b = try buildIndex(gpa, arena, root, threads);
        return .{ .state_id = b.stats.build_id, .delta_files = 0, .rebuilt = b, .ms = ms(t0) };
    }

    var base_ids = std.StringHashMapUnmanaged(u32){};
    try base_ids.ensureTotalCapacity(arena, v.base_files);
    var i: u32 = 0;
    while (i < v.base_files) : (i += 1) base_ids.putAssumeCapacity(v.base.file(i).path, i);

    var root_dir = try std.fs.cwd().openDir(root, .{});
    defer root_dir.close();
    var checker = try walk.Checker.init(gpa, root, false);
    defer checker.deinit();
    var entries: std.ArrayList(walk.Entry) = .empty;
    var it = paths.keyIterator();
    while (it.next()) |k| {
        const p = k.*;
        const base_rec = if (base_ids.get(p)) |id| v.base.file(id) else null;
        const st = walk.lstat(root_dir, p);
        const present = st != null and st.?.kind == .file and !(try checker.skipped(p, false));
        if (present) {
            const size = st.?.size;
            const mtime: i64 = @intCast(st.?.mtime);
            if (base_rec) |r| if (r.size == size and r.mtime == mtime) continue; // back to the base version
            try entries.append(arena, .{ .path = p, .size = size, .mtime = mtime });
        } else if (base_rec != null) {
            try entries.append(arena, .{ .path = p, .size = index.tombstone, .mtime = 0 });
        }
    }
    const dp = try index.deltaPath(arena, index_path);
    if (entries.items.len == 0) {
        std.fs.cwd().deleteFile(dp) catch {};
        return .{ .state_id = v.base.build_id, .delta_files = 0, .ms = ms(t0) };
    }
    std.mem.sort(walk.Entry, entries.items, {}, struct {
        fn lt(_: void, a: walk.Entry, b: walk.Entry) bool {
            return walk.pathOrder(a.path, b.path);
        }
    }.lt);
    const st = try index.build(gpa, root, entries.items, dp, threadCount(threads), .{ .base_id = v.base.build_id });
    return .{ .state_id = st.build_id, .delta_files = entries.items.len, .ms = ms(t0) };
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

fn under(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

fn underAny(path: []const u8, dirs: []const []const u8) bool {
    for (dirs) |d| {
        if (std.mem.eql(u8, path, d) or under(path, d)) return true;
    }
    return false;
}

fn jobLess(_: void, a: search.Job, b: search.Job) bool {
    return walk.pathOrder(a.path, b.path);
}

/// Live index files by path.
fn pathMap(arena: Allocator, v: *const View) !std.StringHashMapUnmanaged(u32) {
    var by_path = std.StringHashMapUnmanaged(u32){};
    try by_path.ensureTotalCapacity(arena, v.file_count);
    var id: u32 = 0;
    while (id < v.file_count) : (id += 1) {
        if (v.live(id)) by_path.putAssumeCapacity(v.file(id).path, id);
    }
    return by_path;
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
    var filter = try walk.Filter.fromGlobs(arena, req.globs);
    if (try filter.addTypes(arena, req.types, req.types_not)) |bad|
        return failWith(diag, arena, "unknown file type '{s}' (see `trigrep --type-list`)", .{bad});
    const cfg = search.Config{
        .prog = &prog,
        .plan = plan,
        .mode = req.mode,
        .max_count = req.max_count,
        .context = req.context,
        .format = req.format,
        .only_matching = req.only_matching,
    };
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

    // After the search: fold these changed paths into the index delta.
    var pending_update: ?[]const []const u8 = null;
    var pending_seq: u64 = 0;
    var found_path: []const u8 = "";

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
        found_path = found.?.path;
        const prefix = relUnder(root, target);

        const t_load = std.time.nanoTimestamp();
        var v = View.open(arena, found_path) catch |err| blk: {
            if (err != error.BadIndex)
                return failWith(diag, arena, "can't read index {s}: {s}", .{ found_path, @errorName(err) });
            // Older format or damaged: rebuild it.
            const b = buildIndex(gpa, arena, root, req.threads) catch |e|
                return failWith(diag, arena, "rebuilding index for {s} failed: {s}", .{ root, @errorName(e) });
            outcome.built_index = try describeBuild(arena, root, b);
            break :blk View.open(arena, b.path) catch |e|
                return failWith(diag, arena, "can't read index {s}: {s}", .{ b.path, @errorName(e) });
        };
        defer v.close();
        if (!std.mem.eql(u8, v.root, root))
            return failWith(diag, arena, "index {s} belongs to {s}; run `trigrep index`", .{ found_path, v.root });
        const cand = try v.candidates(arena, plan.query);
        const load_ms = ms(t_load);
        const n_cand = if (cand) |c| c.len else v.liveCount();

        var cand_set = try std.DynamicBitSetUnmanaged.initEmpty(arena, v.file_count);
        if (cand) |ids| {
            for (ids) |id| cand_set.set(id);
        } else {
            var id: u32 = 0;
            while (id < v.file_count) : (id += 1) {
                if (v.live(id)) cand_set.set(id);
            }
        }

        const strip = if (prefix.len == 0) 0 else prefix.len + 1;
        if (req.trust_index) {
            var id: u32 = 0;
            while (id < v.file_count) : (id += 1) {
                if (!cand_set.isSet(id)) continue;
                const rec = v.file(id);
                if (!under(rec.path, prefix)) continue;
                if (!filter.allows(rec.path[strip..])) continue;
                // Copy: rec.path points into the index mapping, which is closed before the scan.
                const path = try arena.dupe(u8, rec.path);
                try jobs.append(arena, .{ .path = path, .display = try displayPath(arena, req.path, path[strip..]) });
            }
            if (v.delta != null) std.mem.sort(search.Job, jobs.items, {}, jobLess);
            outcome.stats = try std.fmt.allocPrint(arena, "index {d:.1} ms, {d} candidates, no freshness check", .{ load_ms, n_cand });
        } else {
            const t_fresh = std.time.nanoTimestamp();
            const ch: ?watch.Changes = if (req.watch) |h| h.changes(h.ptr, arena, root, found_path, v.state_id, req.hidden) else null;
            const may_update = ch == null or (req.watch != null and req.watch.?.auto_update);
            if (ch != null and !ch.?.full) {
                const changed = try watchedJobs(gpa, arena, req, root, prefix, &v, &cand_set, filter, ch.?, &jobs);
                if (may_update and changed.len >= auto_update_threshold) {
                    pending_update = changed;
                    pending_seq = ch.?.seq;
                }
                outcome.stats = try std.fmt.allocPrint(arena, "index {d:.1} ms, {d} candidates, watcher {d:.1} ms: {d} changed files, {d} changed dirs", .{ load_ms, n_cand, ms(t_fresh), ch.?.files.len, ch.?.dirs.len });
            } else {
                const entries = try walk.walk(arena, root, .{ .hidden = req.hidden, .prefix = prefix });
                const by_path = try pathMap(arena, &v);
                var seen = try std.DynamicBitSetUnmanaged.initEmpty(arena, v.file_count);
                var changed_paths: std.ArrayList([]const u8) = .empty;
                for (entries) |e| {
                    var changed = true;
                    var candidate = true;
                    if (by_path.get(e.path)) |fid| {
                        seen.set(fid);
                        const rec = v.file(fid);
                        changed = rec.size != e.size or rec.mtime != e.mtime;
                        candidate = cand_set.isSet(fid);
                    }
                    if (changed) try changed_paths.append(arena, e.path);
                    if (!changed and !candidate) continue;
                    const rel = e.path[strip..];
                    if (!filter.allows(rel)) continue;
                    try jobs.append(arena, .{ .path = e.path, .display = try displayPath(arena, req.path, rel) });
                }
                const dirty = changed_paths.items.len;
                // Deleted files count as changed too, so watched searches and the
                // delta drop them. Only knowable when the walk covered everything.
                if (prefix.len == 0 and !req.hidden) {
                    var id: u32 = 0;
                    while (id < v.file_count) : (id += 1) {
                        if (v.live(id) and !seen.isSet(id)) try changed_paths.append(arena, try arena.dupe(u8, v.file(id).path));
                    }
                    var seq: u64 = 0;
                    if (req.watch) |h| seq = h.seeded(h.ptr, root, v.state_id, req.hidden, changed_paths.items);
                    if (may_update and changed_paths.items.len >= auto_update_threshold) {
                        pending_update = changed_paths.items;
                        pending_seq = seq;
                    }
                }
                outcome.stats = try std.fmt.allocPrint(arena, "index {d:.1} ms, {d} candidates, freshness check {d:.1} ms over {d} files, {d} changed", .{ load_ms, n_cand, ms(t_fresh), entries.len, dirty });
            }
        }

        if (pending_update) |changed| {
            if (updateDelta(gpa, arena, root, found_path, &v, changed, req.threads)) |u| {
                outcome.updated_index = try describeUpdate(arena, u);
                if (req.watch) |h| h.rebased(h.ptr, root, pending_seq, u.state_id);
            } else |err| {
                outcome.note = try std.fmt.allocPrint(arena, "updating the index failed ({s}); searches stay correct, run `trigrep index`", .{@errorName(err)});
            }
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

/// Jobs for a search when a watcher vouches for the list of changes: index
/// candidates that didn't change, plus changed files and changed directories
/// re-checked directly. Returns every changed path (for updating the delta).
fn watchedJobs(
    gpa: Allocator,
    arena: Allocator,
    req: Request,
    root: []const u8,
    prefix: []const u8,
    v: *const View,
    cand_set: *const std.DynamicBitSetUnmanaged,
    filter: walk.Filter,
    ch: watch.Changes,
    jobs: *std.ArrayList(search.Job),
) ![]const []const u8 {
    const strip = if (prefix.len == 0) 0 else prefix.len + 1;
    var dirty = std.StringHashMapUnmanaged(void){};
    for (ch.files) |f| try dirty.put(arena, f, {});
    var changed: std.ArrayList([]const u8) = .empty;
    try changed.appendSlice(arena, ch.files);

    var id: u32 = 0;
    while (id < v.file_count) : (id += 1) {
        if (!v.live(id)) continue;
        const rec = v.file(id);
        const in_dir = ch.dirs.len > 0 and underAny(rec.path, ch.dirs);
        if (in_dir) try changed.append(arena, try arena.dupe(u8, rec.path));
        if (!cand_set.isSet(id) or !under(rec.path, prefix)) continue;
        if (in_dir or dirty.contains(rec.path)) continue;
        if (!filter.allows(rec.path[strip..])) continue;
        const path = try arena.dupe(u8, rec.path);
        try jobs.append(arena, .{ .path = path, .display = try displayPath(arena, req.path, path[strip..]) });
    }

    var root_dir = try std.fs.cwd().openDir(root, .{});
    defer root_dir.close();
    var checker = try walk.Checker.init(gpa, root, req.hidden);
    defer checker.deinit();
    for (ch.files) |f| {
        if (!under(f, prefix) or underAny(f, ch.dirs)) continue;
        const st = walk.lstat(root_dir, f) orelse continue;
        if (st.kind != .file) continue;
        if (try checker.skipped(f, false)) continue;
        if (!filter.allows(f[strip..])) continue;
        try jobs.append(arena, .{ .path = f, .display = try displayPath(arena, req.path, f[strip..]) });
    }

    for (ch.dirs, 0..) |d, i| {
        var nested = false;
        for (ch.dirs, 0..) |other, j| {
            if (i != j and (under(d, other) or (std.mem.eql(u8, d, other) and j < i))) nested = true;
        }
        if (nested) continue;
        // Walk the whole changed directory (for the delta), search the part in the prefix.
        const entries = try walk.walk(arena, root, .{ .hidden = req.hidden, .prefix = d });
        for (entries) |e| {
            try changed.append(arena, e.path);
            if (!under(e.path, prefix)) continue;
            if (!filter.allows(e.path[strip..])) continue;
            try jobs.append(arena, .{ .path = e.path, .display = try displayPath(arena, req.path, e.path[strip..]) });
        }
    }
    std.mem.sort(search.Job, jobs.items, {}, jobLess);
    return changed.items;
}

/// Paths that differ between the index and a full walk: modified, new and deleted.
pub fn diffIndex(arena: Allocator, v: *const View, entries: []const walk.Entry) ![]const []const u8 {
    const by_path = try pathMap(arena, v);
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(arena, v.file_count);
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (by_path.get(e.path)) |fid| {
            seen.set(fid);
            const rec = v.file(fid);
            if (rec.size == e.size and rec.mtime == e.mtime) continue;
        }
        try out.append(arena, e.path);
    }
    var id: u32 = 0;
    while (id < v.file_count) : (id += 1) {
        if (v.live(id) and !seen.isSet(id)) try out.append(arena, try arena.dupe(u8, v.file(id).path));
    }
    return out.items;
}

pub const Status = struct {
    root: []const u8,
    index_path: []const u8,
    index_bytes: u64,
    age_s: i64,
    files: u32,
    trigrams: u32,
    delta_files: u32,
    modified: usize,
    added: usize,
    deleted: usize,
};

/// Index status for `target`, or null if no index covers it.
pub fn status(arena: Allocator, target: []const u8) !?Status {
    const found = (try findIndex(arena, target)) orelse return null;
    var v = try View.open(arena, found.path);
    defer v.close();
    const entries = try walk.walk(arena, found.root, .{});
    var by_path = try pathMap(arena, &v);
    var modified: usize = 0;
    var added: usize = 0;
    for (entries) |e| {
        if (by_path.fetchRemove(e.path)) |kv| {
            const rec = v.file(kv.value);
            if (rec.size != e.size or rec.mtime != e.mtime) modified += 1;
        } else added += 1;
    }
    const st = try std.fs.cwd().statFile(found.path);
    return .{
        .root = found.root,
        .index_path = found.path,
        .index_bytes = st.size,
        .age_s = @intCast(@divTrunc(std.time.nanoTimestamp() - st.mtime, std.time.ns_per_s)),
        .files = v.liveCount(),
        .trigrams = v.base.tri_count,
        .delta_files = if (v.delta) |d| d.file_count else 0,
        .modified = modified,
        .added = added,
        .deleted = by_path.count(),
    };
}

pub fn describeStatus(arena: Allocator, s: Status) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\root:     {s}
        \\index:    {s} ({d:.1} MB, built {d} s ago; {d} files in the delta)
        \\files:    {d} indexed, {d} trigrams
        \\changed:  {d} modified, {d} new, {d} deleted
        \\
    , .{ s.root, s.index_path, @as(f64, @floatFromInt(s.index_bytes)) / 1e6, s.age_s, s.delta_files, s.files, s.trigrams, s.modified, s.added, s.deleted });
}

// ---------------------------------------------------------------------------
// Tests

test "delta updates replace, add and delete files, and searches see them" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("idx");
    try tmp.dir.makePath("repo");
    try tmp.dir.writeFile(.{ .sub_path = "repo/a.txt", .data = "alpha one\n" });
    try tmp.dir.writeFile(.{ .sub_path = "repo/b.txt", .data = "beta one\n" });
    try tmp.dir.writeFile(.{ .sub_path = "repo/c.txt", .data = "gamma one\n" });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const repo = try tmp.dir.realpathAlloc(arena, "repo");
    const idx_dir = try tmp.dir.realpathAlloc(arena, "idx");
    const index_path = try std.fmt.allocPrint(arena, "{s}/x.idx", .{idx_dir});

    const entries = try walk.walk(arena, repo, .{});
    const base = try index.build(gpa, repo, entries, index_path, 2, .{});

    // Change b, delete c, add d.
    try tmp.dir.writeFile(.{ .sub_path = "repo/b.txt", .data = "beta two zebra\n" });
    try tmp.dir.deleteFile("repo/c.txt");
    try tmp.dir.writeFile(.{ .sub_path = "repo/d.txt", .data = "delta zebra\n" });

    var v = try View.open(arena, index_path);
    const now = try walk.walk(arena, repo, .{});
    const changed = try diffIndex(arena, &v, now);
    try std.testing.expectEqual(@as(usize, 3), changed.len);
    const u = try updateDelta(gpa, arena, repo, index_path, &v, changed, 2);
    v.close();
    try std.testing.expectEqual(@as(usize, 3), u.delta_files);
    try std.testing.expect(u.state_id != base.build_id);

    var v2 = try View.open(arena, index_path);
    defer v2.close();
    try std.testing.expectEqual(u.state_id, v2.state_id);
    try std.testing.expectEqual(@as(u32, 3), v2.liveCount()); // a, b(new), d
    // The index now agrees with the tree.
    try std.testing.expectEqual(@as(usize, 0), (try diffIndex(arena, &v2, try walk.walk(arena, repo, .{}))).len);

    const zebra = try query.plan(arena, try regex.parse(arena, "zebra", .{}));
    const ids = (try v2.candidates(arena, zebra.query)).?;
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    for (ids) |id| try std.testing.expect(std.mem.indexOf(u8, v2.file(id).path, "c.txt") == null);
    const gamma = try query.plan(arena, try regex.parse(arena, "gamma", .{}));
    try std.testing.expectEqual(@as(usize, 0), (try v2.candidates(arena, gamma.query)).?.len);
    const beta = try query.plan(arena, try regex.parse(arena, "beta one", .{}));
    try std.testing.expectEqual(@as(usize, 0), (try v2.candidates(arena, beta.query)).?.len);
}

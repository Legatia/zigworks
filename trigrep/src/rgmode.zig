//! ripgrep mode: when trigrep runs under the name `rg` (a symlink), it answers the
//! searches it can reproduce exactly from its index and hands everything else to the
//! real ripgrep. This is how tools that call `rg` themselves, such as Claude Code's
//! Grep tool with USE_BUILTIN_RIPGREP=0, get the index without choosing it.
//!
//! Rules:
//! - Any flag, pattern or path trigrep doesn't reproduce exactly goes to real rg.
//! - With no index yet, real rg answers. If that search was slow (over
//!   TRIGREP_RG_MIN_MS, default 300 ms), an index is built in the background so later
//!   searches in that repository use it. Fast repos never get an index.
//! - A single-file search always goes to real rg (nothing to gain).

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("engine.zig");
const index = @import("index.zig");
const search = @import("search.zig");
const view = @import("view.zig");

pub fn invokedAsRg(argv0: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(argv0), "rg");
}

const Parsed = struct {
    req: engine.Request,
    globs: std.ArrayList([]const u8) = .empty,
    types: std.ArrayList([]const u8) = .empty,
    types_not: std.ArrayList([]const u8) = .empty,
    with_filename_forced: bool = false,
    line_numbers: bool = false,
};

/// Parses the ripgrep flags trigrep reproduces. Null means "let real rg do it".
fn parse(arena: Allocator, args: []const []const u8) !?Parsed {
    var p = Parsed{ .req = .{ .pattern = "" } };
    var explicit: ?[]const u8 = null; // from -e
    var positionals: std.ArrayList([]const u8) = .empty;
    var only_positional = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (only_positional or a.len < 2 or a[0] != '-') {
            try positionals.append(arena, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_positional = true;
            continue;
        }
        // Options with a value, as `--opt value` or `--opt=value`.
        var name = a;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
                name = a[0..eq];
                inline_value = a[eq + 1 ..];
            }
        }
        const valued = [_][]const u8{ "--glob", "-g", "--max-columns", "-C", "--context", "-A", "--after-context", "-B", "--before-context", "-m", "--max-count", "-e", "--regexp", "-t", "--type", "-T", "--type-not" };
        var is_valued = false;
        for (valued) |v| {
            if (std.mem.eql(u8, name, v)) is_valued = true;
        }
        if (is_valued) {
            const value = inline_value orelse blk: {
                i += 1;
                if (i >= args.len) return null;
                break :blk args[i];
            };
            const num = std.fmt.parseInt(usize, value, 10) catch null;
            if (std.mem.eql(u8, name, "--glob") or std.mem.eql(u8, name, "-g")) {
                try p.globs.append(arena, value);
            } else if (std.mem.eql(u8, name, "--max-columns")) {
                p.req.style.max_columns = num orelse return null;
            } else if (std.mem.eql(u8, name, "-C") or std.mem.eql(u8, name, "--context")) {
                const n = num orelse return null;
                p.req.context = .{ .before = n, .after = n };
            } else if (std.mem.eql(u8, name, "-A") or std.mem.eql(u8, name, "--after-context")) {
                p.req.context.after = num orelse return null;
            } else if (std.mem.eql(u8, name, "-B") or std.mem.eql(u8, name, "--before-context")) {
                p.req.context.before = num orelse return null;
            } else if (std.mem.eql(u8, name, "-m") or std.mem.eql(u8, name, "--max-count")) {
                p.req.max_count = num orelse return null;
            } else if (std.mem.eql(u8, name, "-e") or std.mem.eql(u8, name, "--regexp")) {
                if (explicit != null) return null; // several patterns: rg ORs them
                explicit = value;
            } else if (std.mem.eql(u8, name, "-t") or std.mem.eql(u8, name, "--type")) {
                try p.types.append(arena, value);
            } else {
                try p.types_not.append(arena, value);
            }
            continue;
        }
        if (inline_value != null) return null;
        const flags = [_][]const u8{ "--hidden", "-l", "--files-with-matches", "--null", "-0", "-c", "--count", "-H", "--with-filename", "-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-w", "--word-regexp", "-o", "--only-matching", "--json", "--no-heading" };
        var known = false;
        for (flags) |f| {
            if (std.mem.eql(u8, a, f)) known = true;
        }
        if (!known) return null;
        if (std.mem.eql(u8, a, "--hidden")) p.req.hidden = true
        else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--files-with-matches")) p.req.mode = .files_with_matches
        else if (std.mem.eql(u8, a, "--null") or std.mem.eql(u8, a, "-0")) p.req.style.null_after_path = true
        else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--count")) p.req.mode = .count
        else if (std.mem.eql(u8, a, "-H") or std.mem.eql(u8, a, "--with-filename")) p.with_filename_forced = true
        else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--line-number")) p.line_numbers = true
        else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) p.req.opts.ignore_case = true
        else if (std.mem.eql(u8, a, "-F") or std.mem.eql(u8, a, "--fixed-strings")) p.req.opts.fixed_string = true
        else if (std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--word-regexp")) p.req.opts.word = true
        else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--only-matching")) p.req.only_matching = true
        else if (std.mem.eql(u8, a, "--json")) p.req.format = .json;
    }
    // With -e every positional is a path; otherwise the first one is the pattern.
    var paths = positionals.items;
    if (explicit) |e| {
        p.req.pattern = e;
    } else {
        if (paths.len == 0) return null;
        p.req.pattern = paths[0];
        paths = paths[1..];
    }
    if (paths.len > 1) return null;
    if (paths.len == 1) p.req.path = paths[0];
    // JSON and -l/-c combine differently in rg; only reproduce JSON for line output.
    if (p.req.format == .json and p.req.mode != .lines) return null;
    p.req.style.line_numbers = p.line_numbers;
    // A directory search always prints file names (single files go to real rg).
    p.req.style.filename = true;
    p.req.globs = p.globs.items;
    p.req.types = p.types.items;
    p.req.types_not = p.types_not.items;
    return p;
}

/// The real ripgrep: $TRIGREP_REAL_RG, or the first `rg` on PATH that isn't us.
fn realRg(arena: Allocator) ?[]const u8 {
    if (std.posix.getenv("TRIGREP_REAL_RG")) |p| return p;
    const self = std.fs.selfExePathAlloc(arena) catch return null;
    const self_real = std.fs.cwd().realpathAlloc(arena, self) catch self;
    const path = std.posix.getenv("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const cand = std.fs.path.join(arena, &.{ dir, "rg" }) catch continue;
        const real = std.fs.cwd().realpathAlloc(arena, cand) catch continue;
        if (std.mem.eql(u8, real, self_real)) continue;
        if (std.mem.eql(u8, std.fs.path.basename(real), "trigrep")) continue;
        std.posix.access(real, std.posix.X_OK) catch continue;
        return real;
    }
    return null;
}

fn passthrough(arena: Allocator, argv: []const []const u8) noreturn {
    const rg = realRg(arena) orelse {
        std.debug.print("rg (trigrep): no real ripgrep found on PATH; set TRIGREP_REAL_RG\n", .{});
        std.process.exit(2);
    };
    var full = arena.alloc([]const u8, argv.len) catch std.process.exit(2);
    full[0] = rg;
    @memcpy(full[1..], argv[1..]);
    const err = std.process.execv(arena, full);
    std.debug.print("rg (trigrep): can't run {s}: {s}\n", .{ rg, @errorName(err) });
    std.process.exit(2);
}

/// Runs real rg as a child (output goes straight through) and returns its exit
/// code and how long it took.
fn timedRg(gpa: Allocator, arena: Allocator, argv: []const []const u8) !struct { code: u8, ms: i64 } {
    const rg = realRg(arena) orelse return error.NoRealRg;
    var full = try arena.alloc([]const u8, argv.len);
    full[0] = rg;
    @memcpy(full[1..], argv[1..]);
    const t0 = std.time.milliTimestamp();
    var child = std.process.Child.init(full, gpa);
    const term = try child.spawnAndWait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 2,
    };
    return .{ .code = code, .ms = std.time.milliTimestamp() - t0 };
}

/// Starts `trigrep __bg-index ROOT LOCK` detached, unless a build is already running.
fn startBackgroundIndex(gpa: Allocator, arena: Allocator, root: []const u8) void {
    const idx = index.pathFor(arena, root) catch return;
    if (std.fs.path.dirname(idx)) |d| std.fs.cwd().makePath(d) catch return;
    const lock = std.fmt.allocPrint(arena, "{s}.building", .{idx}) catch return;
    if (std.fs.cwd().statFile(lock)) |st| {
        // A build that started under 30 minutes ago is still running (or crashed recently).
        if (std.time.nanoTimestamp() - st.mtime < 30 * 60 * std.time.ns_per_s) return;
    } else |_| {}
    const f = std.fs.cwd().createFile(lock, .{}) catch return;
    f.close();
    const self = std.fs.selfExePathAlloc(arena) catch return;
    var child = std.process.Child.init(&.{ self, "__bg-index", root, lock }, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0; // own process group: not killed with the caller's
    child.spawn() catch {
        std.fs.cwd().deleteFile(lock) catch {};
        return;
    };
}

/// Starts `trigrep watch --idle-exit 30 ROOT` detached if nothing answers on its socket.
fn ensureDaemon(gpa: Allocator, arena: Allocator, root: []const u8, index_path: []const u8) void {
    const watch = @import("watch.zig");
    const sock = watch.socketPath(arena, index_path) catch return;
    if (std.net.connectUnixSocket(sock)) |stream| {
        stream.close();
        return; // already running
    } else |_| {}
    // Don't start a second one while the first is still starting up.
    const lock = std.fmt.allocPrint(arena, "{s}.starting", .{sock}) catch return;
    watch.ensureSocketDir(sock) catch return;
    if (std.fs.cwd().statFile(lock)) |st| {
        if (std.time.nanoTimestamp() - st.mtime < 60 * std.time.ns_per_s) return;
    } else |_| {}
    const f = std.fs.cwd().createFile(lock, .{}) catch return;
    f.close();
    const self = std.fs.selfExePathAlloc(arena) catch return;
    var child = std.process.Child.init(&.{ self, "watch", "--idle-exit", "30", root }, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;
    child.spawn() catch {};
}

/// `trigrep __bg-index ROOT LOCK`: build the index, then remove the lock.
pub fn backgroundIndex(gpa: Allocator, arena: Allocator, root: []const u8, lock: []const u8) void {
    defer std.fs.cwd().deleteFile(lock) catch {};
    _ = engine.buildIndex(gpa, arena, root, null) catch return;
}

pub fn main(gpa: Allocator, arena: Allocator, argv: []const []const u8) !noreturn {
    const parsed = (try parse(arena, argv[1..])) orelse passthrough(arena, argv);
    var req = parsed.req;
    var diag = engine.Diag{};

    const target = engine.resolve(arena, req.path, &diag) catch passthrough(arena, argv);
    const st = std.fs.cwd().statFile(target) catch passthrough(arena, argv);
    if (st.kind != .directory) passthrough(arena, argv);

    const found = try engine.findIndex(arena, target);
    if (found == null or view.stateId(arena, found.?.path) == null) {
        // No usable index: real rg answers; index only if this was slow.
        const r = timedRg(gpa, arena, argv) catch passthrough(arena, argv);
        const min_ms: i64 = if (std.posix.getenv("TRIGREP_RG_MIN_MS")) |s| (std.fmt.parseInt(i64, s, 10) catch 300) else 300;
        if (r.ms >= min_ms) {
            const root = if (found) |f| f.root else ((try engine.gitRoot(arena, target)) orelse target);
            startBackgroundIndex(gpa, arena, root);
        }
        std.process.exit(r.code);
    }

    // A small subtree is faster for rg to scan than for us to load the index and
    // check freshness: hand it over.
    if (found.?.root.len < target.len) {
        const prefix = target[found.?.root.len + 1 ..];
        const min_files: u32 = if (std.posix.getenv("TRIGREP_RG_MIN_FILES")) |s| (std.fmt.parseInt(u32, s, 10) catch 3000) else 3000;
        var ix = index.Index.open(found.?.path) catch passthrough(arena, argv);
        const n = ix.countUnder(prefix);
        ix.close();
        if (n < min_files) passthrough(arena, argv);
    }

    // The daemon keeps freshness cheap; without one, this search walks the tree and a
    // daemon is started for the next ones (it exits after 30 idle minutes).
    req.watch = null;
    if (@import("watch.zig").supported) {
        req.watch = daemonHook();
        ensureDaemon(gpa, arena, found.?.root, found.?.path);
    }

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&out_buf);
    const out = &stdout.interface;
    const outcome = engine.run(gpa, arena, req, out, &diag) catch |err| {
        // Errors before any output (pattern features trigrep lacks, index trouble):
        // let rg handle the whole search.
        if (stdout.interface.end == 0) passthrough(arena, argv);
        out.flush() catch {};
        std.debug.print("rg (trigrep): {s}\n", .{if (err == error.Failed) diag.message else @errorName(err)});
        std.process.exit(2);
    };
    out.flush() catch {};
    std.process.exit(if (outcome.totals.lines_matched > 0) 0 else 1);
}

// The `trigrep watch` daemon, reached through its socket (see main.zig).
fn daemonHook() engine.WatchHook {
    return @import("main.zig").daemonWatchHook();
}

test "parse Claude Code's Grep invocations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "--hidden", "--glob", "!.git", "--glob", "!.svn", "--max-columns", "500" };
    const p1 = (try parse(a, &(base ++ [_][]const u8{ "-l", "--null", "kmem_cache_create", "." }))).?;
    try std.testing.expectEqual(search.Mode.files_with_matches, p1.req.mode);
    try std.testing.expect(p1.req.style.null_after_path);
    try std.testing.expectEqualStrings("kmem_cache_create", p1.req.pattern);
    try std.testing.expectEqualStrings(".", p1.req.path.?);
    try std.testing.expectEqual(@as(usize, 2), p1.req.globs.len);
    const p2 = (try parse(a, &(base ++ [_][]const u8{ "-i", "--json", "-n", "-C", "1", "swappiness", "/x/mm" }))).?;
    try std.testing.expect(p2.req.opts.ignore_case);
    try std.testing.expectEqual(search.Format.json, p2.req.format);
    try std.testing.expectEqual(@as(usize, 1), p2.req.context.after);
    const p3 = (try parse(a, &(base ++ [_][]const u8{ "--json", "-n", "napi_schedule", "--glob", "*.c", "." }))).?;
    try std.testing.expectEqual(@as(usize, 3), p3.req.globs.len);
    // Things real rg should handle.
    try std.testing.expect((try parse(a, &.{"--version"})) == null);
    try std.testing.expect((try parse(a, &.{ "--files", "--hidden" })) == null);
    try std.testing.expect((try parse(a, &.{ "-S", "foo", "." })) == null);
    try std.testing.expect((try parse(a, &.{ "foo", "a", "b" })) == null);
    try std.testing.expect((try parse(a, &.{ "-l", "--json", "foo" })) == null);
    const p4 = (try parse(a, &.{ "-n", "-e", "-weird", "src" })).?;
    try std.testing.expectEqualStrings("-weird", p4.req.pattern);
    try std.testing.expectEqualStrings("src", p4.req.path.?);
}

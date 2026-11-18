//! Walks a directory tree the way ripgrep does by default: honours .gitignore, .ignore
//! and .git/info/exclude, skips hidden files and `.git`, doesn't follow symlinks.
//! Entries come out in a stable order (each directory's names sorted bytewise).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const glob = @import("glob.zig");

pub const Entry = struct {
    /// Relative to the walk root, `/`-separated.
    path: []const u8,
    size: u64,
    mtime: i64,
};

pub const Options = struct {
    hidden: bool = false,
    /// Only report files under this relative path ("" = everything). Ignore files in
    /// the directories leading to it are still read.
    prefix: []const u8 = "",
};

const Rule = struct {
    /// Directory (relative to the root) of the ignore file this rule came from.
    base: []const u8,
    pattern: []const u8,
    negate: bool,
    dir_only: bool,
    /// Contains a `/`: matched against the path relative to `base`, not the basename.
    anchored: bool,
};

pub const Filter = struct {
    includes: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    /// From -t / -T: a file must match one of `type_includes` (if any) and none of
    /// `type_excludes`.
    type_includes: []const []const u8 = &.{},
    type_excludes: []const []const u8 = &.{},

    /// From ripgrep-style `-g` globs; a leading `!` makes it an exclude.
    pub fn fromGlobs(arena: Allocator, globs: []const []const u8) !Filter {
        var inc: std.ArrayList([]const u8) = .empty;
        var exc: std.ArrayList([]const u8) = .empty;
        for (globs) |g| {
            if (g.len > 0 and g[0] == '!') try exc.append(arena, g[1..]) else try inc.append(arena, g);
        }
        return .{ .includes = inc.items, .excludes = exc.items };
    }

    fn hit(pattern: []const u8, path: []const u8) bool {
        const p = std.mem.trimStart(u8, pattern, "/");
        if (std.mem.findScalar(u8, p, '/') != null) return glob.match(p, path);
        const base = if (std.mem.findScalarLast(u8, path, '/')) |i| path[i + 1 ..] else path;
        return glob.match(p, base);
    }

    /// Adds file types by name (see types.zig); returns the first unknown name.
    pub fn addTypes(f: *Filter, arena: Allocator, include: []const []const u8, exclude: []const []const u8) !?[]const u8 {
        const types = @import("types.zig");
        var inc: std.ArrayList([]const u8) = .empty;
        var exc: std.ArrayList([]const u8) = .empty;
        for (include) |n| try inc.appendSlice(arena, (types.find(n) orelse return n).globs);
        for (exclude) |n| try exc.appendSlice(arena, (types.find(n) orelse return n).globs);
        f.type_includes = inc.items;
        f.type_excludes = exc.items;
        return null;
    }

    pub fn allows(f: Filter, path: []const u8) bool {
        for (f.excludes) |e| {
            if (hit(e, path)) return false;
        }
        for (f.type_excludes) |e| {
            if (hit(e, path)) return false;
        }
        if (f.type_includes.len > 0) {
            for (f.type_includes) |t| {
                if (hit(t, path)) break;
            } else return false;
        }
        if (f.includes.len == 0) return true;
        for (f.includes) |i| {
            if (hit(i, path)) return true;
        }
        return false;
    }
};

/// Rules from the ignore files of one directory, chained to its parent's.
const RuleNode = struct {
    parent: ?*const RuleNode,
    rules: []const Rule,
};

fn parseIgnoreFile(arena: Allocator, text: []const u8, base: []const u8, into: *std.ArrayList(Rule)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        line = std.mem.trimEnd(u8, line, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        var negate = false;
        if (line[0] == '!') {
            negate = true;
            line = line[1..];
        } else if (line[0] == '\\' and line.len > 1 and (line[1] == '#' or line[1] == '!')) {
            line = line[1..];
        }
        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (line.len == 0) continue;
        const anchored = std.mem.findScalar(u8, line, '/') != null;
        if (line[0] == '/') line = line[1..];
        try into.append(arena, .{ .base = base, .pattern = line, .negate = negate, .dir_only = dir_only, .anchored = anchored });
    }
}

const Decision = enum { none, ignore, include };

/// Later rules win, and deeper ignore files win over shallower ones, so walk the chain
/// from the leaf up and each node's rules backwards; the first hit decides.
fn decide(node: ?*const RuleNode, rel: []const u8, name: []const u8, is_dir: bool) Decision {
    var n = node;
    while (n) |cur| : (n = cur.parent) {
        var i = cur.rules.len;
        while (i > 0) {
            i -= 1;
            const r = cur.rules[i];
            if (r.dir_only and !is_dir) continue;
            const sub = if (r.base.len == 0)
                rel
            else if (rel.len > r.base.len and std.mem.startsWith(u8, rel, r.base) and rel[r.base.len] == '/')
                rel[r.base.len + 1 ..]
            else
                continue;
            const hit = if (r.anchored) glob.match(r.pattern, sub) else glob.match(r.pattern, name);
            if (hit) return if (r.negate) .include else .ignore;
        }
    }
    return .none;
}

fn ignored(node: ?*const RuleNode, rel: []const u8, name: []const u8, is_dir: bool) bool {
    return decide(node, rel, name, is_dir) == .ignore;
}

/// Like ripgrep: a hidden entry is skipped unless `--hidden`, or an ignore file
/// explicitly re-includes it (e.g. `.*` then `!.mailmap`).
fn skipHidden(hidden: bool, node: ?*const RuleNode, rel: []const u8, name: []const u8, is_dir: bool) bool {
    if (hidden or name.len == 0 or name[0] != '.') return false;
    return decide(node, rel, name, is_dir) != .include;
}

fn under(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return std.mem.eql(u8, path, prefix) or
        (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/');
}

/// Order of a depth-first walk with each directory sorted by name: compare paths
/// bytewise, with `/` below every other byte.
pub fn pathOrder(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x == y) continue;
        const xx: u16 = if (x == '/') 0 else @as(u16, x) + 1;
        const yy: u16 = if (y == '/') 0 else @as(u16, y) + 1;
        return xx < yy;
    }
    return a.len < b.len;
}

fn pathLess(_: void, a: Entry, b: Entry) bool {
    return pathOrder(a.path, b.path);
}

/// Answers "would the walker skip this path?" for single paths, loading ignore files
/// along the way and caching them per directory. Not thread-safe.
pub const Checker = struct {
    arena_state: std.heap.ArenaAllocator,
    io: Io,
    root: Io.Dir,
    hidden: bool,
    nodes: std.StringHashMapUnmanaged(?*const RuleNode) = .empty,

    pub fn init(gpa: Allocator, io: Io, root: []const u8, hidden: bool) !Checker {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .io = io,
            .root = try Io.Dir.cwd().openDir(io, root, .{}),
            .hidden = hidden,
        };
    }

    pub fn deinit(c: *Checker) void {
        c.root.close(c.io);
        c.arena_state.deinit();
    }

    /// Forget cached ignore files (after one of them changed).
    pub fn reset(c: *Checker) void {
        _ = c.arena_state.reset(.free_all);
        c.nodes = .empty;
    }

    fn nodeFor(c: *Checker, dir_rel: []const u8) !?*const RuleNode {
        if (c.nodes.get(dir_rel)) |n| return n;
        const parent: ?*const RuleNode = if (dir_rel.len == 0)
            null
        else
            try c.nodeFor(if (std.mem.findScalarLast(u8, dir_rel, '/')) |i| dir_rel[0..i] else "");
        const arena = c.arena_state.allocator();
        var rules: std.ArrayList(Rule) = .empty;
        const base = try arena.dupe(u8, dir_rel);
        const names = if (dir_rel.len == 0)
            &[_][]const u8{ ".git/info/exclude", ".gitignore", ".ignore" }
        else
            &[_][]const u8{ ".gitignore", ".ignore" };
        for (names) |name| {
            // By path from the root, without opening the directory: on
            // Windows a directory that is deleted while this holds it open
            // only goes away when it is closed, and until then opening a
            // file in it is retried for seconds.
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = if (dir_rel.len == 0) name else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_rel, name }) catch continue;
            const text = c.root.readFileAlloc(c.io, path, arena, ignore_file_limit) catch continue;
            try parseIgnoreFile(arena, text, base, &rules);
        }
        var node = parent;
        if (rules.items.len > 0) {
            const n = try arena.create(RuleNode);
            n.* = .{ .parent = parent, .rules = rules.items };
            node = n;
        }
        try c.nodes.put(arena, base, node);
        return node;
    }

    /// True if the walker would never report `rel` (a file, or a directory when
    /// `is_dir`): hidden, under `.git`, or ignored, itself or through an ancestor.
    pub fn skipped(c: *Checker, rel: []const u8, is_dir: bool) !bool {
        var start: usize = 0;
        while (start < rel.len) {
            const slash = std.mem.findScalarPos(u8, rel, start, '/');
            const end = slash orelse rel.len;
            const name = rel[start..end];
            if (std.mem.eql(u8, name, ".git")) return true;
            const parent_rel = if (start == 0) "" else rel[0 .. start - 1];
            const node = try c.nodeFor(parent_rel);
            const as_dir = slash != null or is_dir;
            if (skipHidden(c.hidden, node, rel[0..end], name, as_dir)) return true;
            if (ignored(node, rel[0..end], name, as_dir)) return true;
            start = end + 1;
        }
        return false;
    }
};

/// True if any component of `rel` starts with a dot.
pub fn hasHiddenComponent(rel: []const u8) bool {
    if (rel.len > 0 and rel[0] == '.') return true;
    return std.mem.find(u8, rel, "/.") != null;
}

/// Stats `rel` under `root` without following a final symlink.
pub fn lstat(io: Io, root: Io.Dir, rel: []const u8) ?Io.File.Stat {
    return root.statFile(io, rel, .{ .follow_symlinks = false }) catch null;
}

/// A file's mtime as the index stores it: nanoseconds since the epoch.
pub fn mtimeNs(st: Io.File.Stat) i64 {
    return @intCast(st.mtime.nanoseconds);
}

/// Ignore files larger than 4 MiB are not read. (`Io.Limit` fails when the limit is
/// reached, so it is one past the largest size accepted.)
const ignore_file_limit: Io.Limit = .limited((4 << 20) + 1);

const Task = struct { rel: []const u8, rules: ?*const RuleNode };

const Shared = struct {
    io: Io,
    root: Io.Dir,
    opts: Options,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Task) = .empty,
    active: usize = 0,
    failed: ?anyerror = null,
};

const Worker = struct {
    shared: *Shared,
    arena_state: std.heap.ArenaAllocator,
    out: std.ArrayList(Entry) = .empty,
    subdirs: std.ArrayList(Task) = .empty,

    fn run(w: *Worker) void {
        const sh = w.shared;
        const io = sh.io;
        while (true) {
            sh.mutex.lockUncancelable(io);
            while (sh.queue.items.len == 0 and sh.active > 0) sh.cond.waitUncancelable(io, &sh.mutex);
            const task = sh.queue.pop() orelse {
                sh.mutex.unlock(io);
                sh.cond.broadcast(io);
                return;
            };
            sh.active += 1;
            sh.mutex.unlock(io);

            w.subdirs.clearRetainingCapacity();
            w.processDir(task) catch |err| {
                sh.mutex.lockUncancelable(io);
                sh.failed = err;
                sh.mutex.unlock(io);
            };

            sh.mutex.lockUncancelable(io);
            sh.queue.appendSlice(std.heap.smp_allocator, w.subdirs.items) catch {
                sh.failed = error.OutOfMemory;
            };
            sh.active -= 1;
            sh.mutex.unlock(io);
            sh.cond.broadcast(io);
        }
    }

    fn processDir(w: *Worker, task: Task) !void {
        const arena = w.arena_state.allocator();
        const sh = w.shared;
        const io = sh.io;
        const dir = if (task.rel.len == 0)
            try sh.root.openDir(io, ".", .{ .iterate = true })
        else
            sh.root.openDir(io, task.rel, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var rules: std.ArrayList(Rule) = .empty;
        const names = if (task.rel.len == 0)
            &[_][]const u8{ ".git/info/exclude", ".gitignore", ".ignore" }
        else
            &[_][]const u8{ ".gitignore", ".ignore" };
        for (names) |name| {
            const text = dir.readFileAlloc(io, name, arena, ignore_file_limit) catch continue;
            try parseIgnoreFile(arena, text, task.rel, &rules);
        }
        var node = task.rules;
        if (rules.items.len > 0) {
            const n = try arena.create(RuleNode);
            n.* = .{ .parent = task.rules, .rules = rules.items };
            node = n;
        }

        var it = dir.iterateAssumeFirstIteration();
        while (it.next(io) catch null) |e| {
            if (std.mem.eql(u8, e.name, ".git")) continue;
            const child = if (task.rel.len == 0)
                try arena.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ task.rel, e.name });
            const name = child[child.len - e.name.len ..];
            const inside = under(child, sh.opts.prefix);
            if (!inside and !under(sh.opts.prefix, child)) continue;
            var kind = e.kind;
            var st: ?Io.File.Stat = null;
            if (kind == .unknown) {
                st = dir.statFile(io, name, .{}) catch continue;
                kind = st.?.kind;
            }
            switch (kind) {
                .directory => {
                    if (skipHidden(sh.opts.hidden, node, child, name, true) or ignored(node, child, name, true)) continue;
                    try w.subdirs.append(arena, .{ .rel = child, .rules = node });
                },
                .file => {
                    if (!inside or skipHidden(sh.opts.hidden, node, child, name, false) or ignored(node, child, name, false)) continue;
                    const s = st orelse (dir.statFile(io, name, .{}) catch continue);
                    try w.out.append(arena, .{ .path = child, .size = s.size, .mtime = mtimeNs(s) });
                },
                else => {},
            }
        }
    }
};

/// Lists the files under `root` in depth-first, name-sorted order, using `threads`
/// workers. The result is allocated in `arena`.
pub fn walkThreads(arena: Allocator, io: Io, root: []const u8, opts: Options, threads: usize) ![]Entry {
    const root_dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    const gpa = std.heap.smp_allocator;
    var sh = Shared{ .io = io, .root = root_dir, .opts = opts };
    defer sh.queue.deinit(gpa);
    try sh.queue.append(gpa, .{ .rel = "", .rules = null });

    const n = @max(1, threads);
    const workers = try gpa.alloc(Worker, n);
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .shared = &sh, .arena_state = std.heap.ArenaAllocator.init(gpa) };
    defer for (workers) |*w| w.arena_state.deinit();

    if (n == 1) {
        workers[0].run();
    } else {
        const handles = try gpa.alloc(std.Thread, n);
        defer gpa.free(handles);
        for (workers, 0..) |*w, i| handles[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
        for (handles) |h| h.join();
    }
    if (sh.failed) |err| return err;

    var total: usize = 0;
    for (workers) |w| total += w.out.items.len;
    const out = try arena.alloc(Entry, total);
    var k: usize = 0;
    for (workers) |w| {
        for (w.out.items) |e| {
            out[k] = .{ .path = try arena.dupe(u8, e.path), .size = e.size, .mtime = e.mtime };
            k += 1;
        }
    }
    std.mem.sort(Entry, out, {}, pathLess);
    return out;
}

pub fn walk(arena: Allocator, io: Io, root: []const u8, opts: Options) ![]Entry {
    return walkThreads(arena, io, root, opts, std.Thread.getCpuCount() catch 4);
}

test "walk honours gitignore, hidden files and prefix" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/gen");
    try d.createDirPath(io, "node_modules/x");
    try d.createDirPath(io, ".hidden");
    try d.writeFile(io, .{ .sub_path = ".gitignore", .data = "node_modules/\n*.log\n/build\n!keep.log\n" });
    try d.writeFile(io, .{ .sub_path = "src/.gitignore", .data = "gen/\n" });
    try d.writeFile(io, .{ .sub_path = "src/main.zig", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "src/gen/out.zig", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "node_modules/x/i.js", .data = "x" });
    try d.writeFile(io, .{ .sub_path = ".hidden/h", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "a.log", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "keep.log", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "build", .data = "x" });
    try d.writeFile(io, .{ .sub_path = "README", .data = "x" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const entries = try walk(arena.allocator(), io, root, .{});
    var got: std.ArrayList(u8) = .empty;
    for (entries) |e| try got.print(arena.allocator(), "{s}\n", .{e.path});
    try std.testing.expectEqualStrings("README\nkeep.log\nsrc/main.zig\n", got.items);

    const sub = try walk(arena.allocator(), io, root, .{ .prefix = "src" });
    try std.testing.expectEqual(@as(usize, 1), sub.len);
    try std.testing.expectEqualStrings("src/main.zig", sub[0].path);
}

test "checker agrees with the walker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "src/gen");
    try d.createDirPath(io, "node_modules/x");
    try d.writeFile(io, .{ .sub_path = ".gitignore", .data = "node_modules/\n*.log\n!keep.log\n" });
    try d.writeFile(io, .{ .sub_path = "src/.gitignore", .data = "gen/\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    var c = try Checker.init(std.testing.allocator, io, root, false);
    defer c.deinit();
    try std.testing.expect(!try c.skipped("src/main.zig", false));
    try std.testing.expect(try c.skipped("src/gen/out.zig", false));
    try std.testing.expect(try c.skipped("node_modules/x/i.js", false));
    try std.testing.expect(try c.skipped("a.log", false));
    try std.testing.expect(!try c.skipped("keep.log", false));
    try std.testing.expect(try c.skipped(".hidden/h", false));
    try std.testing.expect(try c.skipped(".git/HEAD", false));
    try std.testing.expect(try c.skipped("src/gen", true));
    try std.testing.expect(!try c.skipped("src", true));
}

test "hidden files re-included by an ignore file are searched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = ".*\n!.gitignore\n!.mailmap\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".mailmap", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".other", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.c", .data = "x" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const entries = try walk(arena.allocator(), io, root, .{});
    var got: std.ArrayList(u8) = .empty;
    for (entries) |e| try got.print(arena.allocator(), "{s}\n", .{e.path});
    try std.testing.expectEqualStrings(".gitignore\n.mailmap\na.c\n", got.items);
    var c = try Checker.init(std.testing.allocator, io, root, false);
    defer c.deinit();
    try std.testing.expect(!try c.skipped(".mailmap", false));
    try std.testing.expect(try c.skipped(".other", false));
}

test "filter globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try Filter.fromGlobs(arena.allocator(), &.{ "*.zig", "!*_test.zig" });
    try std.testing.expect(f.allows("src/main.zig"));
    try std.testing.expect(!f.allows("src/main_test.zig"));
    try std.testing.expect(!f.allows("README"));

    var t = Filter{};
    try std.testing.expect((try t.addTypes(arena.allocator(), &.{ "rust", "c" }, &.{})) == null);
    try std.testing.expect(t.allows("src/lib.rs"));
    try std.testing.expect(t.allows("kernel/fork.c"));
    try std.testing.expect(!t.allows("README.md"));
    var u = Filter{};
    try std.testing.expect((try u.addTypes(arena.allocator(), &.{}, &.{"md"})) == null);
    try std.testing.expect(!u.allows("docs/README.md"));
    try std.testing.expect(u.allows("main.zig"));
    try std.testing.expectEqualStrings("nope", (try u.addTypes(arena.allocator(), &.{"nope"}, &.{})).?);
}

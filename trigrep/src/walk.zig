//! Walks a directory tree the way ripgrep does by default: honours .gitignore, .ignore
//! and .git/info/exclude, skips hidden files and `.git`, doesn't follow symlinks.
//! Entries come out in a stable order (each directory's names sorted bytewise).

const std = @import("std");
const Allocator = std.mem.Allocator;
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
        const p = std.mem.trimLeft(u8, pattern, "/");
        if (std.mem.indexOfScalar(u8, p, '/') != null) return glob.match(p, path);
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
        return glob.match(p, base);
    }

    pub fn allows(f: Filter, path: []const u8) bool {
        for (f.excludes) |e| {
            if (hit(e, path)) return false;
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
        var line = std.mem.trimRight(u8, raw, "\r");
        line = std.mem.trimRight(u8, line, " \t");
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
        const anchored = std.mem.indexOfScalar(u8, line, '/') != null;
        if (line[0] == '/') line = line[1..];
        try into.append(arena, .{ .base = base, .pattern = line, .negate = negate, .dir_only = dir_only, .anchored = anchored });
    }
}

/// Later rules win, and deeper ignore files win over shallower ones, so walk the chain
/// from the leaf up and each node's rules backwards; the first hit decides.
fn ignored(node: ?*const RuleNode, rel: []const u8, name: []const u8, is_dir: bool) bool {
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
            if (hit) return !r.negate;
        }
    }
    return false;
}

fn under(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    return std.mem.eql(u8, path, prefix) or
        (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/');
}

/// Order of a depth-first walk with each directory sorted by name: compare paths
/// bytewise, with `/` below every other byte.
fn pathLess(_: void, a: Entry, b: Entry) bool {
    const n = @min(a.path.len, b.path.len);
    for (a.path[0..n], b.path[0..n]) |x, y| {
        if (x == y) continue;
        const xx: u16 = if (x == '/') 0 else @as(u16, x) + 1;
        const yy: u16 = if (y == '/') 0 else @as(u16, y) + 1;
        return xx < yy;
    }
    return a.path.len < b.path.len;
}

const Task = struct { rel: []const u8, rules: ?*const RuleNode };

const Shared = struct {
    root: std.fs.Dir,
    opts: Options,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
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
        while (true) {
            sh.mutex.lock();
            while (sh.queue.items.len == 0 and sh.active > 0) sh.cond.wait(&sh.mutex);
            const task = sh.queue.pop() orelse {
                sh.mutex.unlock();
                sh.cond.broadcast();
                return;
            };
            sh.active += 1;
            sh.mutex.unlock();

            w.subdirs.clearRetainingCapacity();
            w.processDir(task) catch |err| {
                sh.mutex.lock();
                sh.failed = err;
                sh.mutex.unlock();
            };

            sh.mutex.lock();
            sh.queue.appendSlice(std.heap.smp_allocator, w.subdirs.items) catch {
                sh.failed = error.OutOfMemory;
            };
            sh.active -= 1;
            sh.mutex.unlock();
            sh.cond.broadcast();
        }
    }

    fn processDir(w: *Worker, task: Task) !void {
        const arena = w.arena_state.allocator();
        const sh = w.shared;
        var dir = if (task.rel.len == 0)
            try sh.root.openDir(".", .{ .iterate = true })
        else
            sh.root.openDir(task.rel, .{ .iterate = true }) catch return;
        defer dir.close();

        var rules: std.ArrayList(Rule) = .empty;
        const names = if (task.rel.len == 0)
            &[_][]const u8{ ".git/info/exclude", ".gitignore", ".ignore" }
        else
            &[_][]const u8{ ".gitignore", ".ignore" };
        for (names) |name| {
            const text = dir.readFileAlloc(arena, name, 4 << 20) catch continue;
            try parseIgnoreFile(arena, text, task.rel, &rules);
        }
        var node = task.rules;
        if (rules.items.len > 0) {
            const n = try arena.create(RuleNode);
            n.* = .{ .parent = task.rules, .rules = rules.items };
            node = n;
        }

        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (std.mem.eql(u8, e.name, ".git")) continue;
            if (!sh.opts.hidden and e.name[0] == '.') continue;
            const child = if (task.rel.len == 0)
                try arena.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ task.rel, e.name });
            const name = child[child.len - e.name.len ..];
            const inside = under(child, sh.opts.prefix);
            if (!inside and !under(sh.opts.prefix, child)) continue;
            var kind = e.kind;
            var st: ?std.fs.File.Stat = null;
            if (kind == .unknown) {
                st = dir.statFile(name) catch continue;
                kind = st.?.kind;
            }
            switch (kind) {
                .directory => {
                    if (ignored(node, child, name, true)) continue;
                    try w.subdirs.append(arena, .{ .rel = child, .rules = node });
                },
                .file => {
                    if (!inside or ignored(node, child, name, false)) continue;
                    const s = st orelse (dir.statFile(name) catch continue);
                    try w.out.append(arena, .{ .path = child, .size = s.size, .mtime = @intCast(s.mtime) });
                },
                else => {},
            }
        }
    }
};

/// Lists the files under `root` in depth-first, name-sorted order, using `threads`
/// workers. The result is allocated in `arena`.
pub fn walkThreads(arena: Allocator, root: []const u8, opts: Options, threads: usize) ![]Entry {
    var root_dir = try std.fs.cwd().openDir(root, .{});
    defer root_dir.close();
    const gpa = std.heap.smp_allocator;
    var sh = Shared{ .root = root_dir, .opts = opts };
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

pub fn walk(arena: Allocator, root: []const u8, opts: Options) ![]Entry {
    return walkThreads(arena, root, opts, std.Thread.getCpuCount() catch 4);
}

test "walk honours gitignore, hidden files and prefix" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.makePath("src/gen");
    try d.makePath("node_modules/x");
    try d.makePath(".hidden");
    try d.writeFile(.{ .sub_path = ".gitignore", .data = "node_modules/\n*.log\n/build\n!keep.log\n" });
    try d.writeFile(.{ .sub_path = "src/.gitignore", .data = "gen/\n" });
    try d.writeFile(.{ .sub_path = "src/main.zig", .data = "x" });
    try d.writeFile(.{ .sub_path = "src/gen/out.zig", .data = "x" });
    try d.writeFile(.{ .sub_path = "node_modules/x/i.js", .data = "x" });
    try d.writeFile(.{ .sub_path = ".hidden/h", .data = "x" });
    try d.writeFile(.{ .sub_path = "a.log", .data = "x" });
    try d.writeFile(.{ .sub_path = "keep.log", .data = "x" });
    try d.writeFile(.{ .sub_path = "build", .data = "x" });
    try d.writeFile(.{ .sub_path = "README", .data = "x" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const entries = try walk(arena.allocator(), root, .{});
    var got: std.ArrayList(u8) = .empty;
    for (entries) |e| try got.print(arena.allocator(), "{s}\n", .{e.path});
    try std.testing.expectEqualStrings("README\nkeep.log\nsrc/main.zig\n", got.items);

    const sub = try walk(arena.allocator(), root, .{ .prefix = "src" });
    try std.testing.expectEqual(@as(usize, 1), sub.len);
    try std.testing.expectEqualStrings("src/main.zig", sub[0].path);
}

test "filter globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try Filter.fromGlobs(arena.allocator(), &.{ "*.zig", "!*_test.zig" });
    try std.testing.expect(f.allows("src/main.zig"));
    try std.testing.expect(!f.allows("src/main_test.zig"));
    try std.testing.expect(!f.allows("README"));
}

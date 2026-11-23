//! A run's own copy of the workspace (environments.ini `workspace = copy`):
//! the workspace's files in a folder of the run's, cloned copy-on-write
//! where the file system can and copied otherwise, with what each file was
//! when copied written beside it (`COPY.base`). What the run changed is what
//! differs from that; applying writes each changed file back whose
//! workspace file is still as it was when copied, and leaves the others.
//! Links are never followed, here or in the workspace. A file is the same
//! when its size and time are; one written within 2 s of the copy is told
//! by its content too (a file system's clock ticks: two writes in one tick
//! leave one time).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const clone = @import("clone.zig");
const gate = @import("gate.zig");
const rules = @import("rules.zig");
const util = @import("util.zig");

const has_exec = builtin.os.tag != .windows;

pub const Options = struct {
    /// The most the workspace may hold; a larger one is not copied.
    max_bytes: u64 = 2048 << 20,
    /// Names and paths (as rules' patterns) left out, folders.ini's `skip`.
    skip: []const []const u8 = &.{},
    clone: ?clone.Fn = clone.platform,
};

pub const Made = struct {
    files: usize = 0,
    bytes: u64 = 0,
    /// Every file shares its source's blocks.
    cloned: bool = false,
};

pub const Error = error{ TooLarge, OutOfMemory };

const Kind = enum { file, link };

const Found = struct { rel: []const u8, kind: Kind, size: u64 = 0, mtime: i128 = 0, perms: Io.File.Permissions = undefined, target: []const u8 = "" };

fn skipped(skip: []const []const u8, rel: []const u8, base: []const u8) bool {
    for (skip) |p| if (rules.glob(p, base) or rules.glob(p, rel)) return true;
    return false;
}

fn slashes(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (std.fs.path.sep == '/') return arena.dupe(u8, p);
    const out = try arena.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// The files and links under `root` (`/` between parts), and its folders.
fn walk(io: Io, arena: std.mem.Allocator, root_path: []const u8, skip: []const []const u8, dirs: ?*std.ArrayList([]const u8)) ![]Found {
    var out: std.ArrayList(Found) = .empty;
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var w = try root.walkSelectively(arena);
    defer w.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const entry = (w.next(io) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        }) orelse break;
        const rel = try slashes(arena, entry.path);
        if (skipped(skip, rel, entry.basename)) continue;
        const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        switch (st.kind) {
            .directory => {
                if (dirs) |d| try d.append(arena, rel);
                w.enter(io, entry) catch {};
            },
            .file => try out.append(arena, .{ .rel = rel, .kind = .file, .size = st.size, .mtime = st.mtime.nanoseconds, .perms = st.permissions }),
            .sym_link => {
                const n = entry.dir.readLink(io, entry.basename, &buf) catch continue;
                try out.append(arena, .{ .rel = rel, .kind = .link, .target = try arena.dupe(u8, buf[0..n]) });
            },
            else => {},
        }
    }
    return out.items;
}

/// A file written this close before the copy is also told by its content.
const window_ns: i128 = 2 * std.time.ns_per_s;

const Sha = [64]u8;

fn hashFile(io: Io, path: []const u8) !Sha {
    var f = try Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false, .allow_directory = false });
    defer f.close(io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const got = f.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => return e,
        };
        if (got == 0) break;
        h.update(buf[0..got]);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn basePath(arena: std.mem.Allocator, dst: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.base", .{std.mem.trimEnd(u8, dst, "/\\")});
}

/// Copies the workspace `src` into the new folder `dst` and writes what each
/// file was beside it. Too large (before anything is copied): TooLarge.
pub fn make(io: Io, arena: std.mem.Allocator, src: []const u8, dst: []const u8, opts: Options) !Made {
    var dirs: std.ArrayList([]const u8) = .empty;
    const found = try walk(io, arena, src, opts.skip, &dirs);
    var total: u64 = 0;
    for (found) |f| total += f.size;
    if (total > opts.max_bytes) return error.TooLarge;
    try Io.Dir.cwd().createDirPath(io, dst);
    errdefer drop(io, arena, dst);
    for (dirs.items) |d| try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ dst, d }));
    var base: std.ArrayList(u8) = .empty;
    var made: Made = .{ .bytes = total };
    const now_ns: i128 = @as(i128, util.nowMs(io)) * std.time.ns_per_ms;
    var cloning = opts.clone != null;
    var all_cloned = cloning;
    for (found) |f| {
        const from = try std.fs.path.join(arena, &.{ src, f.rel });
        const to = try std.fs.path.join(arena, &.{ dst, f.rel });
        switch (f.kind) {
            .link => {
                // as it is, never what it points to (Windows: left out)
                if (builtin.os.tag == .windows) continue;
                Io.Dir.cwd().symLink(io, f.target, to, .{}) catch continue;
                try base.print(arena, "l\t0\t0\t0\t-\t{s}\n", .{f.rel});
            },
            .file => {
                var done = false;
                if (cloning) {
                    done = opts.clone.?(io, from, to) catch false;
                    // the file system can't: no use asking for each file
                    if (!done) cloning = false;
                }
                if (!done) {
                    all_cloned = false;
                    Io.Dir.cwd().copyFile(from, Io.Dir.cwd(), to, io, .{}) catch continue;
                } else if (has_exec) Io.Dir.cwd().setFilePermissions(io, to, f.perms, .{}) catch {};
                // its source's time: only what was written just before the
                // copy needs its content looked at
                setModified(io, to, f.mtime);
                const st = Io.Dir.cwd().statFile(io, to, .{ .follow_symlinks = false }) catch continue;
                const recent = now_ns - st.mtime.nanoseconds < window_ns or now_ns - f.mtime < window_ns;
                const sha: ?Sha = if (recent) hashFile(io, to) catch null else null;
                try base.print(arena, "f\t{d}\t{d}\t{d}\t{s}\t{s}\n", .{ f.size, st.mtime.nanoseconds, f.mtime, if (sha) |*x| @as([]const u8, x) else "-", f.rel });
                made.files += 1;
            },
        }
    }
    made.cloned = all_cloned and made.files > 0;
    try util.writeReplace(io, try basePath(arena, dst), base.items);
    return made;
}

fn setModified(io: Io, path: []const u8, mtime: i128) void {
    var file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .follow_symlinks = false }) catch return;
    defer file.close(io);
    file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(mtime) } } }) catch {};
}

/// Removes a copy and what was written beside it.
pub fn drop(io: Io, arena: std.mem.Allocator, dst: []const u8) void {
    Io.Dir.cwd().deleteTree(io, dst) catch {};
    if (basePath(arena, dst)) |p| Io.Dir.cwd().deleteFile(io, p) catch {} else |_| {}
}

pub const What = enum { added, changed, removed };

pub const Change = struct {
    rel: []const u8,
    what: What,
    /// Its size in the copy now (0 when removed).
    size: u64 = 0,
    /// What the workspace's file was when copied (changed, removed).
    src_size: u64 = 0,
    src_mtime: i128 = 0,
    /// Its content then, when it was written just before the copy.
    src_sha: ?Sha = null,
};

const Base = struct { kind: Kind, size: u64, mtime: i128, src_mtime: i128, sha: ?Sha = null, seen: bool = false };

fn readBase(io: Io, arena: std.mem.Allocator, dst: []const u8) !std.StringHashMapUnmanaged(Base) {
    var map: std.StringHashMapUnmanaged(Base) = .empty;
    const text = try Io.Dir.cwd().readFileAlloc(io, try basePath(arena, dst), arena, .limited(256 << 20));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const k = parts.next() orelse continue;
        if (k.len != 1) continue;
        const size = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
        const mtime = std.fmt.parseInt(i128, parts.next() orelse continue, 10) catch continue;
        const src_mtime = std.fmt.parseInt(i128, parts.next() orelse continue, 10) catch continue;
        const sha_text = parts.next() orelse continue;
        const rel = parts.rest();
        if (rel.len == 0) continue;
        try map.put(arena, rel, .{ .kind = if (k[0] == 'l') .link else .file, .size = size, .mtime = mtime, .src_mtime = src_mtime, .sha = if (sha_text.len == 64) sha_text[0..64].* else null });
    }
    return map;
}

/// The files of the copy `dst` that differ from the workspace as it was
/// when copied: new ones, changed ones, ones removed. Links the run made
/// are not among them (they are never applied).
pub fn changes(io: Io, arena: std.mem.Allocator, dst: []const u8) ![]Change {
    var base = try readBase(io, arena, dst);
    var out: std.ArrayList(Change) = .empty;
    for (try walk(io, arena, dst, &.{}, null)) |f| {
        const b = base.getPtr(f.rel);
        if (b) |x| x.seen = true;
        if (f.kind != .file) {
            // a file turned into a link: the file is gone
            if (b) |x| if (x.kind == .file) try out.append(arena, .{ .rel = f.rel, .what = .removed, .src_size = x.size, .src_mtime = x.src_mtime, .src_sha = x.sha });
            continue;
        }
        if (b) |x| {
            if (x.kind == .file and x.size == f.size and x.mtime == f.mtime) {
                // written just before the copy: the same only if its content is
                const was = x.sha orelse continue;
                const is = hashFile(io, try std.fs.path.join(arena, &.{ dst, f.rel })) catch continue;
                if (std.mem.eql(u8, &was, &is)) continue;
            }
            if (x.kind == .file) {
                try out.append(arena, .{ .rel = f.rel, .what = .changed, .size = f.size, .src_size = x.size, .src_mtime = x.src_mtime, .src_sha = x.sha });
                continue;
            }
        }
        try out.append(arena, .{ .rel = f.rel, .what = .added, .size = f.size });
    }
    var it = base.iterator();
    while (it.next()) |e| if (!e.value_ptr.seen and e.value_ptr.kind == .file)
        try out.append(arena, .{ .rel = e.key_ptr.*, .what = .removed, .src_size = e.value_ptr.size, .src_mtime = e.value_ptr.src_mtime, .src_sha = e.value_ptr.sha });
    std.mem.sort(Change, out.items, {}, struct {
        fn less(_: void, x: Change, y: Change) bool {
            return std.mem.lessThan(u8, x.rel, y.rel);
        }
    }.less);
    return out.items;
}

/// "4 files: + notes/new.md (120 bytes), ~ a.txt (9 bytes), - old.txt".
pub fn listText(arena: std.mem.Allocator, list: []const Change, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |ch, i| {
        if (i == max) {
            try out.print(arena, "… and {d} more\n", .{list.len - max});
            break;
        }
        switch (ch.what) {
            .added => try out.print(arena, "+ {s} ({d} bytes)\n", .{ ch.rel, ch.size }),
            .changed => try out.print(arena, "~ {s} ({d} bytes, was {d})\n", .{ ch.rel, ch.size, ch.src_size }),
            .removed => try out.print(arena, "- {s}\n", .{ch.rel}),
        }
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

/// The workspace's file `rel` is as it was when copied (for a new file:
/// still not there).
fn untouched(io: Io, src_path: []const u8, ch: Change) bool {
    const st = Io.Dir.cwd().statFile(io, src_path, .{ .follow_symlinks = false }) catch |e| return ch.what == .added and e == error.FileNotFound;
    if (ch.what == .added) return false;
    if (st.kind != .file or st.size != ch.src_size or st.mtime.nanoseconds != ch.src_mtime) return false;
    const was = ch.src_sha orelse return true;
    const is = hashFile(io, src_path) catch return false;
    return std.mem.eql(u8, &was, &is);
}

pub const Applied = struct {
    written: usize = 0,
    removed: usize = 0,
    /// Changed in the workspace since the copy was made (or not writable):
    /// left as they are.
    left: []const []const u8 = &.{},
};

/// Writes the copy's changes into the workspace `src`: each file whose
/// workspace file is still as it was when copied; the others are left and
/// named. Nothing is written through a link, in the copy or the workspace.
pub fn apply(io: Io, arena: std.mem.Allocator, src: []const u8, dst: []const u8, list: []const Change) !Applied {
    var out: Applied = .{};
    var left: std.ArrayList([]const u8) = .empty;
    for (list) |ch| {
        // inside the workspace, no link on the way
        const to = gate.confine(arena, io, src, ch.rel) catch {
            try left.append(arena, ch.rel);
            continue;
        };
        if (!untouched(io, to, ch)) {
            try left.append(arena, ch.rel);
            continue;
        }
        if (ch.what == .removed) {
            Io.Dir.cwd().deleteFile(io, to) catch {
                try left.append(arena, ch.rel);
                continue;
            };
            out.removed += 1;
            continue;
        }
        const from = try std.fs.path.join(arena, &.{ dst, ch.rel });
        const st = Io.Dir.cwd().statFile(io, from, .{ .follow_symlinks = false }) catch {
            try left.append(arena, ch.rel);
            continue;
        };
        if (st.kind != .file) {
            try left.append(arena, ch.rel);
            continue;
        }
        if (std.fs.path.dirname(to)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
        Io.Dir.cwd().copyFile(from, Io.Dir.cwd(), to, io, .{}) catch {
            try left.append(arena, ch.rel);
            continue;
        };
        out.written += 1;
    }
    out.left = left.items;
    return out;
}

fn readText(io: Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) return null;
    return data;
}

/// What changed, for the owner: per file its lines that went (`-`) and came
/// (`+`), between the lines both have at the start and the end; at most
/// `per_file` bytes each. Files that are not text, or over 1 MB, by size.
pub fn diffText(io: Io, arena: std.mem.Allocator, src: []const u8, dst: []const u8, list: []const Change, per_file: usize, max_total: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |ch, i| {
        if (out.items.len >= max_total) {
            try out.print(arena, "… and {d} more files\n", .{list.len - i});
            break;
        }
        const mark: []const u8 = switch (ch.what) {
            .added => "new",
            .changed => "changed",
            .removed => "removed",
        };
        try out.print(arena, "{s} ({s})\n", .{ ch.rel, mark });
        if (ch.what == .removed) continue;
        const new = readText(io, arena, try std.fs.path.join(arena, &.{ dst, ch.rel })) orelse {
            try out.print(arena, "  {d} bytes, not text\n", .{ch.size});
            continue;
        };
        const old: []const u8 = if (ch.what == .added) "" else readText(io, arena, try std.fs.path.join(arena, &.{ src, ch.rel })) orelse "";
        const start = out.items.len;
        var ol = try linesOf(arena, old);
        var nl = try linesOf(arena, new);
        while (ol.len > 0 and nl.len > 0 and std.mem.eql(u8, ol[0], nl[0])) {
            ol = ol[1..];
            nl = nl[1..];
        }
        while (ol.len > 0 and nl.len > 0 and std.mem.eql(u8, ol[ol.len - 1], nl[nl.len - 1])) {
            ol = ol[0 .. ol.len - 1];
            nl = nl[0 .. nl.len - 1];
        }
        for (ol) |l| try out.print(arena, "- {s}\n", .{l});
        for (nl) |l| try out.print(arena, "+ {s}\n", .{l});
        if (out.items.len - start > per_file) {
            out.shrinkRetainingCapacity(start + util.cut(out.items[start..], per_file).len);
            try out.appendSlice(arena, "\n  …\n");
        }
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn linesOf(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (text.len == 0) return out.items;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| try out.append(arena, std.mem.trimEnd(u8, l, "\r"));
    return out.items;
}

// ---- tests ----

const t = std.testing;

const Fix = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    root: []const u8,
    ws: []const u8,
    copy: []const u8,

    fn init(f: *Fix) !void {
        f.tmp = t.tmpDir(.{});
        f.arena_state = .init(t.allocator);
        f.a = f.arena_state.allocator();
        try f.tmp.dir.createDirPath(t.io, "ws/notes");
        f.root = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.a);
        f.ws = try std.fs.path.join(f.a, &.{ f.root, "ws" });
        f.copy = try std.fs.path.join(f.a, &.{ f.root, "copies", "41" });
        try f.put("ws/a.txt", "one\ntwo\nthree\n");
        try f.put("ws/notes/b.md", "keep\n");
        try f.put("ws/gone.txt", "going\n");
    }

    fn deinit(f: *Fix) void {
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    fn put(f: *Fix, rel: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    fn get(f: *Fix, rel: []const u8) ![]const u8 {
        return f.tmp.dir.readFileAlloc(t.io, rel, f.a, .unlimited);
    }

    /// What a run does in its copy: a change, a new file, a removal.
    fn work(f: *Fix) !void {
        try f.put("copies/41/a.txt", "one\n2\nthree\n");
        try f.tmp.dir.createDirPath(t.io, "copies/41/new");
        try f.put("copies/41/new/c.txt", "made\n");
        try f.tmp.dir.deleteFile(t.io, "copies/41/gone.txt");
    }
};

test "a_runs_writes_stay_in_its_copy" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const made = try make(t.io, f.a, f.ws, f.copy, .{});
    try t.expectEqual(3, made.files);
    try t.expectEqual(25, made.bytes);
    try t.expectEqualStrings("keep\n", try f.get("copies/41/notes/b.md"));
    // nothing changed yet
    try t.expectEqual(0, (try changes(t.io, f.a, f.copy)).len);
    try f.work();
    // the workspace is as it was
    try t.expectEqualStrings("one\ntwo\nthree\n", try f.get("ws/a.txt"));
    try t.expectEqualStrings("going\n", try f.get("ws/gone.txt"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "ws/new/c.txt", .{}));
    const list = try changes(t.io, f.a, f.copy);
    try t.expectEqualStrings("~ a.txt (12 bytes, was 14)\n- gone.txt\n+ new/c.txt (5 bytes)", try listText(f.a, list, 20));
    try t.expectEqualStrings("a.txt (changed)\n- two\n+ 2\ngone.txt (removed)\nnew/c.txt (new)\n+ made", try diffText(t.io, f.a, f.ws, f.copy, list, 2048, 16 << 10));
    // dropped: nothing left of it
    drop(t.io, f.a, f.copy);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "copies/41", .{}));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "copies/41.base", .{}));
}

test "apply_writes_only_files_unchanged_since" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    _ = try make(t.io, f.a, f.ws, f.copy, .{});
    try f.work();
    try f.put("copies/41/notes/b.md", "the run's\n");
    // the owner changed one meanwhile, and made a file where the run made one
    try f.put("ws/notes/b.md", "the owner's, longer\n");
    try f.tmp.dir.createDirPath(t.io, "ws/new");
    try f.put("ws/new/c.txt", "mine\n");
    const list = try changes(t.io, f.a, f.copy);
    try t.expectEqual(4, list.len);
    const done = try apply(t.io, f.a, f.ws, f.copy, list);
    try t.expectEqual(1, done.written);
    try t.expectEqual(1, done.removed);
    try t.expectEqual(2, done.left.len);
    try t.expectEqualStrings("new/c.txt", done.left[0]);
    try t.expectEqualStrings("notes/b.md", done.left[1]);
    try t.expectEqualStrings("one\n2\nthree\n", try f.get("ws/a.txt"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "ws/gone.txt", .{}));
    try t.expectEqualStrings("the owner's, longer\n", try f.get("ws/notes/b.md"));
    try t.expectEqualStrings("mine\n", try f.get("ws/new/c.txt"));
}

test "copy_mb_refuses_before_the_run" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try t.expectError(error.TooLarge, make(t.io, f.a, f.ws, f.copy, .{ .max_bytes = 24 }));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "copies/41", .{}));
    // what folders.ini skips is neither counted nor copied
    try f.tmp.dir.createDirPath(t.io, "ws/node_modules");
    try f.put("ws/node_modules/big.js", &@as([4096]u8, @splat('x')));
    const made = try make(t.io, f.a, f.ws, f.copy, .{ .max_bytes = 25, .skip = &.{"node_modules"} });
    try t.expectEqual(3, made.files);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "copies/41/node_modules", .{}));
}

test "a_link_the_run_made_is_never_followed_into_the_workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.put("outside.txt", "the owner's own\n");
    _ = try make(t.io, f.a, f.ws, f.copy, .{});
    // a file swapped for a link out of the copy, and a new link
    try f.tmp.dir.deleteFile(t.io, "copies/41/a.txt");
    try f.tmp.dir.symLink(t.io, "../../outside.txt", "copies/41/a.txt", .{});
    try f.tmp.dir.symLink(t.io, "../../outside.txt", "copies/41/leak.txt", .{});
    const list = try changes(t.io, f.a, f.copy);
    try t.expectEqualStrings("- a.txt", try listText(f.a, list, 20));
    _ = try apply(t.io, f.a, f.ws, f.copy, list);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "ws/leak.txt", .{}));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "ws/a.txt", .{ .follow_symlinks = false }));
    try t.expectEqualStrings("the owner's own\n", try f.get("outside.txt"));
}

test "copy_is_a_clone_where_it_can_be" {
    // HARNESS_TEST_COW_DIRS: folders on file systems that clone (as clone.zig's tests)
    const dirs = t.environ.getAlloc(t.allocator, "HARNESS_TEST_COW_DIRS") catch return error.SkipZigTest;
    defer t.allocator.free(dirs);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var it = std.mem.tokenizeScalar(u8, dirs, ';');
    var n: usize = 0;
    while (it.next()) |dir| {
        n += 1;
        const root = try std.fs.path.join(a, &.{ dir, "harness-copy-test" });
        Io.Dir.cwd().deleteTree(t.io, root) catch {};
        defer Io.Dir.cwd().deleteTree(t.io, root) catch {};
        const ws = try std.fs.path.join(a, &.{ root, "ws" });
        try Io.Dir.cwd().createDirPath(t.io, ws);
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ ws, "big.bin" }), .data = &@as([256 << 10]u8, @splat('z')) });
        const copy = try std.fs.path.join(a, &.{ root, "copy" });
        const made = try make(t.io, a, ws, copy, .{});
        try t.expect(made.cloned);
        try t.expectEqual(0, (try changes(t.io, a, copy)).len);
    }
    if (n == 0) return error.SkipZigTest;
}

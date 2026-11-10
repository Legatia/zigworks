//! Keeps a list of paths changed since an index was built, from OS file events
//! (FSEvents on macOS, inotify on Linux), so a search can re-check only those instead
//! of stat-ing every file.
//!
//! Correctness rule: whenever the watcher can't vouch for its list (dropped events, an
//! ignore file changed, the index was rebuilt elsewhere, no backend on this OS) it
//! reports `full`, and the caller walks the tree as usual and re-seeds it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const walk = @import("walk.zig");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

pub const Changes = struct {
    /// The caller must walk the whole tree; `files` and `dirs` are empty.
    full: bool,
    /// Files that may have changed, been created or deleted.
    files: []const []const u8,
    /// Directories whose whole subtree must be re-walked (created, removed, renamed,
    /// or the OS asked for a rescan).
    dirs: []const []const u8,
    /// The watcher's sequence number when this list was taken (for `rebased`).
    seq: u64 = 0,
};

pub const Watcher = struct {
    gpa: Allocator,
    /// When a search last asked (ms since epoch), for `trigrep watch --idle-exit`.
    last_query_ms: std.atomic.Value(i64) = .init(0),
    root: []const u8,
    hidden: bool,
    mutex: std.Thread.Mutex = .{},
    files: std.StringHashMapUnmanaged(u64) = .empty,
    dirs: std.StringHashMapUnmanaged(u64) = .empty,
    seq: u64 = 0,
    full: bool = true,
    base_id: u64 = 0,
    checker: walk.Checker,
    backend: Backend = .{},
    /// The backend couldn't start or broke: always report `full`.
    failed: bool = false,
    /// Cookie files (macOS): `sync` creates one and waits for its event, which proves
    /// every earlier change has been delivered.
    cookie_dir: []const u8 = "",
    cookie_prefix: []const u8 = "",
    cookie_sent: u64 = 0,
    cookie_seen: u64 = 0,
    cookie_cond: std.Thread.Condition = .{},

    /// Starts watching `root` (absolute). The watcher reports `full` until `seed`.
    pub fn create(gpa: Allocator, root: []const u8, hidden: bool) !*Watcher {
        const w = try gpa.create(Watcher);
        errdefer gpa.destroy(w);
        w.* = .{
            .gpa = gpa,
            .root = try gpa.dupe(u8, root),
            .hidden = hidden,
            .checker = try walk.Checker.init(gpa, root, hidden),
        };
        // Cookies go in .git when it's a directory (git ignores unknown files there).
        const git = try std.fmt.allocPrint(gpa, "{s}/.git", .{root});
        defer gpa.free(git);
        const in_git = if (std.fs.cwd().statFile(git)) |st| st.kind == .directory else |_| false;
        w.cookie_dir = try gpa.dupe(u8, if (in_git) git else root);
        w.cookie_prefix = try std.fmt.allocPrint(gpa, "{s}.trigrep-cookie-{d}-", .{ if (in_git) ".git/" else "", std.c.getpid() });
        w.backend.start(w) catch |err| {
            std.debug.print("trigrep: can't watch {s} ({s}); searches will walk the tree\n", .{ root, @errorName(err) });
            w.failed = true;
        };
        return w;
    }

    pub fn destroy(w: *Watcher) void {
        w.backend.stop();
        w.mutex.lock();
        w.clearLocked();
        w.files.deinit(w.gpa);
        w.dirs.deinit(w.gpa);
        w.checker.deinit();
        w.mutex.unlock();
        w.gpa.free(w.cookie_dir);
        w.gpa.free(w.cookie_prefix);
        w.gpa.free(w.root);
        w.gpa.destroy(w);
    }

    fn clearLocked(w: *Watcher) void {
        var it = w.files.keyIterator();
        while (it.next()) |k| w.gpa.free(k.*);
        w.files.clearRetainingCapacity();
        var dt = w.dirs.keyIterator();
        while (dt.next()) |k| w.gpa.free(k.*);
        w.dirs.clearRetainingCapacity();
    }

    fn insertLocked(w: *Watcher, rel: []const u8, is_dir: bool) void {
        w.seq += 1;
        const map = if (is_dir) &w.dirs else &w.files;
        const gop = map.getOrPut(w.gpa, rel) catch {
            w.full = true;
            return;
        };
        if (!gop.found_existing) {
            gop.key_ptr.* = w.gpa.dupe(u8, rel) catch {
                map.removeByPtr(gop.key_ptr);
                w.full = true;
                return;
            };
        }
        gop.value_ptr.* = w.seq;
    }

    /// Called by backends with the mutex held, `rel` relative to the root.
    fn record(w: *Watcher, rel: []const u8, is_dir: bool) void {
        if (rel.len == 0) return;
        if (std.mem.startsWith(u8, rel, w.cookie_prefix)) {
            const n = std.fmt.parseInt(u64, rel[w.cookie_prefix.len..], 10) catch return;
            if (n > w.cookie_seen) w.cookie_seen = n;
            w.cookie_cond.broadcast();
            return;
        }
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
        if (std.mem.eql(u8, rel, ".git/info/exclude") or std.mem.eql(u8, base, ".gitignore") or std.mem.eql(u8, base, ".ignore")) {
            // Ignore rules changed: what the walker returns may change anywhere.
            w.checker.reset();
            w.full = true;
            return;
        }
        const skip = w.checker.skipped(rel, is_dir) catch false;
        if (skip) return;
        w.insertLocked(rel, is_dir);
    }

    /// Makes sure every change made before this call has been recorded. False if that
    /// can't be confirmed (the caller must then walk).
    fn sync(w: *Watcher) bool {
        if (builtin.os.tag != .macos) {
            w.backend.flush(w);
            return true;
        }
        if (w.failed) return false;
        w.mutex.lock();
        w.cookie_sent += 1;
        const n = w.cookie_sent;
        w.mutex.unlock();
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const base = std.fs.path.basename(w.cookie_prefix);
        const path = std.fmt.bufPrint(&name_buf, "{s}/{s}{d}", .{ w.cookie_dir, base, n }) catch return false;
        const f = std.fs.cwd().createFile(path, .{}) catch return false;
        f.close();
        defer std.fs.cwd().deleteFile(path) catch {};
        w.mutex.lock();
        defer w.mutex.unlock();
        const deadline = std.time.nanoTimestamp() + std.time.ns_per_s;
        while (w.cookie_seen < n) {
            const left = deadline - std.time.nanoTimestamp();
            if (left <= 0) {
                // Events aren't arriving (e.g. a network filesystem): stop relying on them.
                w.failed = true;
                std.debug.print("trigrep: file events for {s} aren't arriving; searches will walk the tree\n", .{w.root});
                return false;
            }
            w.cookie_cond.timedWait(&w.mutex, @intCast(left)) catch {};
        }
        return true;
    }

    /// Changes since the index `build_id` was built. Copies into `arena`.
    pub fn changes(w: *Watcher, arena: Allocator, build_id: u64) !Changes {
        if (!w.sync()) return .{ .full = true, .files = &.{}, .dirs = &.{} };
        w.mutex.lock();
        defer w.mutex.unlock();
        if (w.failed or w.full or w.base_id != build_id or build_id == 0)
            return .{ .full = true, .files = &.{}, .dirs = &.{} };
        const files = try arena.alloc([]const u8, w.files.count());
        var i: usize = 0;
        var it = w.files.keyIterator();
        while (it.next()) |k| : (i += 1) files[i] = try arena.dupe(u8, k.*);
        const dirs = try arena.alloc([]const u8, w.dirs.count());
        i = 0;
        var dt = w.dirs.keyIterator();
        while (dt.next()) |k| : (i += 1) dirs[i] = try arena.dupe(u8, k.*);
        return .{ .full = false, .files = files, .dirs = dirs, .seq = w.seq };
    }

    /// Call right before walking the tree for a re-seed: forgets what was recorded so
    /// far. Events from now on are kept, so nothing that happens during the walk is lost.
    pub fn beginSeed(w: *Watcher) void {
        _ = w.sync();
        w.mutex.lock();
        defer w.mutex.unlock();
        w.clearLocked();
        w.full = false;
        w.base_id = 0;
    }

    /// After that walk: `changed` are the paths the walk found to differ from index
    /// `build_id`. Unless something forced `full` meanwhile, the watcher is now current.
    pub fn seed(w: *Watcher, build_id: u64, changed: []const []const u8) u64 {
        w.mutex.lock();
        defer w.mutex.unlock();
        for (changed) |p| w.insertLocked(p, false);
        w.base_id = build_id;
        return w.seq;
    }

    /// Before rebuilding the index: a mark to pass to `rebased` afterwards.
    pub fn mark(w: *Watcher) u64 {
        _ = w.sync();
        w.mutex.lock();
        defer w.mutex.unlock();
        return w.seq;
    }

    /// The index was rebuilt as `new_id` after `mark`: drop changes the rebuild saw.
    pub fn rebased(w: *Watcher, at: u64, new_id: u64) void {
        w.mutex.lock();
        defer w.mutex.unlock();
        for ([_]*std.StringHashMapUnmanaged(u64){ &w.files, &w.dirs }) |map| {
            var stale: std.ArrayList([]const u8) = .empty;
            defer stale.deinit(w.gpa);
            var it = map.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* <= at) stale.append(w.gpa, e.key_ptr.*) catch {
                    w.full = true;
                    return;
                };
            }
            for (stale.items) |k| {
                _ = map.remove(k);
                w.gpa.free(k);
            }
        }
        w.base_id = new_id;
    }

    /// Number of recorded changes, and whether the watcher needs a re-seed.
    pub fn pending(w: *Watcher) struct { count: usize, needs_seed: bool } {
        w.mutex.lock();
        defer w.mutex.unlock();
        return .{ .count = w.files.count() + w.dirs.count(), .needs_seed = w.failed or w.full or w.base_id == 0 };
    }
};

// ---------------------------------------------------------------------------
// Backends

const Backend = switch (builtin.os.tag) {
    .macos => FsEvents,
    .linux => Inotify,
    else => Unsupported,
};

const Unsupported = struct {
    fn start(_: *Unsupported, _: *Watcher) !void {
        return error.Unsupported;
    }
    fn stop(_: *Unsupported) void {}
    fn flush(_: *Unsupported, _: *Watcher) void {}
};

const FsEvents = struct {
    stream: ?*anyopaque = null,
    queue: ?*anyopaque = null,

    const CFIndex = isize;
    const Context = extern struct {
        version: CFIndex = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };
    const Callback = *const fn (?*anyopaque, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;

    extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: u8) ?*anyopaque;
    extern "c" fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*const anyopaque, len: CFIndex, callbacks: ?*const anyopaque) ?*anyopaque;
    extern "c" fn CFRelease(obj: ?*const anyopaque) void;
    extern "c" const kCFTypeArrayCallBacks: u8;
    extern "c" fn FSEventStreamCreate(alloc: ?*anyopaque, cb: Callback, ctx: *const Context, paths: ?*anyopaque, since: u64, latency: f64, flags: u32) ?*anyopaque;
    extern "c" fn FSEventStreamSetDispatchQueue(stream: ?*anyopaque, queue: ?*anyopaque) void;
    extern "c" fn FSEventStreamStart(stream: ?*anyopaque) u8;
    extern "c" fn FSEventStreamFlushSync(stream: ?*anyopaque) void;
    extern "c" fn FSEventStreamStop(stream: ?*anyopaque) void;
    extern "c" fn FSEventStreamInvalidate(stream: ?*anyopaque) void;
    extern "c" fn FSEventStreamRelease(stream: ?*anyopaque) void;
    extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
    extern "c" fn dispatch_release(obj: ?*anyopaque) void;

    const utf8: u32 = 0x08000100;
    const since_now: u64 = 0xFFFFFFFFFFFFFFFF;
    const flag_no_defer: u32 = 0x02;
    const flag_watch_root: u32 = 0x04;
    const flag_file_events: u32 = 0x10;

    const ev_must_scan_subdirs: u32 = 0x01;
    const ev_user_dropped: u32 = 0x02;
    const ev_kernel_dropped: u32 = 0x04;
    const ev_root_changed: u32 = 0x20;
    const ev_created: u32 = 0x100;
    const ev_removed: u32 = 0x200;
    const ev_renamed: u32 = 0x800;
    const ev_is_file: u32 = 0x10000;
    const ev_is_dir: u32 = 0x20000;
    const ev_is_symlink: u32 = 0x40000;
    const ev_is_hardlink: u32 = 0x100000;

    fn start(f: *FsEvents, w: *Watcher) !void {
        const path = CFStringCreateWithBytes(null, w.root.ptr, @intCast(w.root.len), utf8, 0) orelse return error.SystemResources;
        defer CFRelease(path);
        const values = [_]?*const anyopaque{path};
        const array = CFArrayCreate(null, &values, 1, &kCFTypeArrayCallBacks) orelse return error.SystemResources;
        defer CFRelease(array);
        const ctx = Context{ .info = w };
        const stream = FSEventStreamCreate(null, callback, &ctx, array, since_now, 0.01, flag_no_defer | flag_watch_root | flag_file_events) orelse return error.SystemResources;
        const queue = dispatch_queue_create("trigrep.watch", null) orelse {
            FSEventStreamRelease(stream);
            return error.SystemResources;
        };
        FSEventStreamSetDispatchQueue(stream, queue);
        if (FSEventStreamStart(stream) == 0) {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            dispatch_release(queue);
            return error.Unexpected;
        }
        f.* = .{ .stream = stream, .queue = queue };
    }

    fn stop(f: *FsEvents) void {
        const s = f.stream orelse return;
        FSEventStreamStop(s);
        FSEventStreamInvalidate(s);
        FSEventStreamRelease(s);
        dispatch_release(f.queue);
        f.stream = null;
    }

    fn flush(f: *FsEvents, _: *Watcher) void {
        if (f.stream) |s| FSEventStreamFlushSync(s);
    }

    fn callback(_: ?*anyopaque, info: ?*anyopaque, n: usize, raw_paths: ?*anyopaque, flags: [*]const u32, _: [*]const u64) callconv(.c) void {
        const w: *Watcher = @ptrCast(@alignCast(info.?));
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(raw_paths.?));
        w.mutex.lock();
        defer w.mutex.unlock();
        for (0..n) |i| {
            const fl = flags[i];
            const p = std.mem.span(paths[i]);
            if (fl & (ev_user_dropped | ev_kernel_dropped | ev_root_changed) != 0) {
                w.full = true;
                continue;
            }
            const rel = relativeTo(w.root, p) orelse {
                if (std.mem.eql(u8, p, w.root) and fl & ev_must_scan_subdirs != 0) w.full = true;
                continue;
            };
            if (fl & ev_must_scan_subdirs != 0) {
                w.record(rel, true);
            } else if (fl & ev_is_dir != 0) {
                if (fl & (ev_created | ev_removed | ev_renamed) != 0) w.record(rel, true);
            } else if (fl & (ev_is_file | ev_is_symlink | ev_is_hardlink) != 0) {
                w.record(rel, false);
            } else {
                // No item type: treat it as a directory-level change.
                w.record(rel, true);
            }
        }
    }
};

fn relativeTo(root: []const u8, p: []const u8) ?[]const u8 {
    if (p.len <= root.len + 1 or !std.mem.startsWith(u8, p, root) or p[root.len] != '/') return null;
    return p[root.len + 1 ..];
}

const Inotify = struct {
    fd: i32 = -1,
    wds: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    owner: ?*Watcher = null,

    const linux = std.os.linux;
    const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE |
        linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR | linux.IN.EXCL_UNLINK;

    fn start(in: *Inotify, w: *Watcher) !void {
        in.fd = try std.posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        in.owner = w;
        w.mutex.lock();
        defer w.mutex.unlock();
        try in.addTree(w, "");
        in.thread = try std.Thread.spawn(.{}, loop, .{in});
    }

    fn stop(in: *Inotify) void {
        if (in.fd < 0) return;
        in.stopping.store(true, .release);
        if (in.thread) |t| t.join();
        std.posix.close(in.fd);
        in.fd = -1;
        const gpa = in.owner.?.gpa;
        var it = in.wds.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        in.wds.deinit(gpa);
    }

    /// Watches `rel` and every directory under it the walker would enter.
    fn addTree(in: *Inotify, w: *Watcher, rel: []const u8) !void {
        const abs = if (rel.len == 0)
            try w.gpa.dupe(u8, w.root)
        else
            try std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ w.root, rel });
        defer w.gpa.free(abs);
        const wd = std.posix.inotify_add_watch(in.fd, abs, mask) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.NotDir => return,
            else => return err, // e.g. watch limit reached
        };
        const gop = try in.wds.getOrPut(w.gpa, wd);
        if (gop.found_existing) w.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = try w.gpa.dupe(u8, rel);

        var dir = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .directory) continue;
            const child = if (rel.len == 0)
                try w.gpa.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ rel, e.name });
            defer w.gpa.free(child);
            if (w.checker.skipped(child, true) catch true) continue;
            try in.addTree(w, child);
        }
    }

    fn loop(in: *Inotify) void {
        while (!in.stopping.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = in.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&fds, 200) catch 0;
            in.flush(in.owner.?);
        }
    }

    fn flush(in: *Inotify, w: *Watcher) void {
        if (in.fd < 0) return;
        w.mutex.lock();
        defer w.mutex.unlock();
        var buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = std.posix.read(in.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    w.full = true;
                    return;
                },
            };
            if (n == 0) return;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name_bytes = buf[off + @sizeOf(linux.inotify_event) ..][0..ev.len];
                off += @sizeOf(linux.inotify_event) + ev.len;
                in.handle(w, ev, std.mem.sliceTo(name_bytes, 0));
            }
        }
    }

    fn handle(in: *Inotify, w: *Watcher, ev: *const linux.inotify_event, name: []const u8) void {
        if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
            w.full = true;
            return;
        }
        if (ev.mask & linux.IN.IGNORED != 0) {
            if (in.wds.fetchRemove(ev.wd)) |kv| w.gpa.free(kv.value);
            return;
        }
        const dir_rel = in.wds.get(ev.wd) orelse return;
        if (ev.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            if (dir_rel.len == 0) w.full = true else w.record(dir_rel, true);
            return;
        }
        if (name.len == 0) return;
        const rel = if (dir_rel.len == 0)
            w.gpa.dupe(u8, name) catch {
                w.full = true;
                return;
            }
        else
            std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ dir_rel, name }) catch {
                w.full = true;
                return;
            };
        defer w.gpa.free(rel);
        if (ev.mask & linux.IN.ISDIR != 0) {
            if (ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
                if (!(w.checker.skipped(rel, true) catch true)) in.addTree(w, rel) catch {
                    w.full = true;
                };
            }
            if (ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO | linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) w.record(rel, true);
            return;
        }
        w.record(rel, false);
    }
};

// ---------------------------------------------------------------------------
// Daemon protocol: `trigrep watch` serves the list over a Unix socket; searches ask it.
//
//   request:  "changes <build_id hex>\n"
//   reply:    "full\n"  or  "ok\n" then "f <path>\n" / "d <path>\n" lines, then "end\n"

/// Socket for the index at `index_path`: /tmp/trigrep-<uid>/<index name>.sock
/// (short, because Unix socket paths are limited to ~104 bytes).
pub fn socketPath(arena: Allocator, index_path: []const u8) ![]const u8 {
    const base = std.fs.path.stem(index_path);
    return std.fmt.allocPrint(arena, "/tmp/trigrep-{d}/{s}.sock", .{ std.posix.getuid(), base });
}

/// Creates the socket directory, mode 0700, and refuses one owned by someone else.
pub fn ensureSocketDir(sock: []const u8) !void {
    const dir = std.fs.path.dirname(sock).?;
    std.posix.mkdir(dir, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const st = try std.posix.fstatat(std.fs.cwd().fd, dir, std.posix.AT.SYMLINK_NOFOLLOW);
    if (st.uid != std.posix.getuid() or (st.mode & 0o077) != 0) return error.InsecureSocketDir;
}

/// Asks a running `trigrep watch`. Returns null if none is listening.
pub fn query(arena: Allocator, sock: []const u8, build_id: u64) ?Changes {
    var stream = std.net.connectUnixSocket(sock) catch return null;
    defer stream.close();
    var req_buf: [64]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "changes {x}\n", .{build_id}) catch return null;
    stream.writeAll(req) catch return null;
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(&rbuf);
    const r = reader.interface();
    const first = r.takeDelimiterExclusive('\n') catch return null;
    if (std.mem.eql(u8, first, "full")) return .{ .full = true, .files = &.{}, .dirs = &.{} };
    if (!std.mem.eql(u8, first, "ok")) return null;
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    while (true) {
        const line = r.takeDelimiterExclusive('\n') catch return null;
        if (std.mem.eql(u8, line, "end")) break;
        if (line.len < 3) return null;
        const p = arena.dupe(u8, line[2..]) catch return null;
        switch (line[0]) {
            'f' => files.append(arena, p) catch return null,
            'd' => dirs.append(arena, p) catch return null,
            else => return null,
        }
    }
    return .{ .full = false, .files = files.items, .dirs = dirs.items };
}

/// Answers `query` requests for `w` forever (run it on its own thread).
pub fn serve(w: *Watcher, sock: []const u8) !void {
    try ensureSocketDir(sock);
    std.fs.cwd().deleteFile(sock) catch {};
    const addr = try std.net.Address.initUnix(sock);
    var server = try addr.listen(.{});
    defer server.deinit();
    while (true) {
        var conn = server.accept() catch continue;
        answer(w, conn.stream) catch {};
        conn.stream.close();
    }
}

fn answer(w: *Watcher, stream: std.net.Stream) !void {
    var rbuf: [256]u8 = undefined;
    var reader = stream.reader(&rbuf);
    const line = try reader.interface().takeDelimiterExclusive('\n');
    if (!std.mem.startsWith(u8, line, "changes ")) return error.BadRequest;
    const id = try std.fmt.parseInt(u64, line["changes ".len..], 16);
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    w.last_query_ms.store(std.time.milliTimestamp(), .monotonic);
    const ch = try w.changes(arena.allocator(), id);
    var wbuf: [64 * 1024]u8 = undefined;
    var writer = stream.writer(&wbuf);
    const out = &writer.interface;
    var full = ch.full;
    if (!full) for (ch.files) |p| {
        if (std.mem.indexOfScalar(u8, p, '\n') != null) full = true;
    };
    if (!full) for (ch.dirs) |p| {
        if (std.mem.indexOfScalar(u8, p, '\n') != null) full = true;
    };
    if (full) {
        try out.writeAll("full\n");
    } else {
        try out.writeAll("ok\n");
        for (ch.files) |p| try out.print("f {s}\n", .{p});
        for (ch.dirs) |p| try out.print("d {s}\n", .{p});
        try out.writeAll("end\n");
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Tests

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

test "watcher records edits, creations and ignores ignored files" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/a.txt", .data = "one\n" });
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);

    const w = try Watcher.create(gpa, root, false);
    defer w.destroy();
    try std.testing.expect(!w.failed);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expect((try w.changes(arena.allocator(), 7)).full);
    w.beginSeed();
    _ = w.seed(7, &.{});
    // FSEvents may deliver events from before the stream started; let them settle.
    std.Thread.sleep(200 * std.time.ns_per_ms);
    w.beginSeed();
    _ = w.seed(7, &.{});

    try tmp.dir.writeFile(.{ .sub_path = "src/a.txt", .data = "two\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "new\n" });
    try tmp.dir.writeFile(.{ .sub_path = "x.log", .data = "ignored\n" });
    try tmp.dir.makePath("newdir");

    const ch = try w.changes(arena.allocator(), 7);
    try std.testing.expect(!ch.full);
    try std.testing.expect(contains(ch.files, "src/a.txt"));
    try std.testing.expect(contains(ch.files, "b.txt"));
    try std.testing.expect(!contains(ch.files, "x.log"));
    try std.testing.expect(contains(ch.dirs, "newdir"));
    // A different index build is never answered from this list.
    try std.testing.expect((try w.changes(arena.allocator(), 8)).full);

    // Changing an ignore file forces a full walk.
    try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "*.log\n*.tmp\n" });
    try std.testing.expect((try w.changes(arena.allocator(), 7)).full);
}

test "rebased drops changes the rebuild saw" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const w = try Watcher.create(gpa, root, false);
    defer w.destroy();
    w.beginSeed();
    _ = w.seed(1, &.{ "a", "b" });
    const at = w.mark();
    w.mutex.lock();
    w.insertLocked("c", false);
    w.mutex.unlock();
    w.rebased(at, 2);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ch = try w.changes(arena.allocator(), 2);
    try std.testing.expect(!ch.full);
    try std.testing.expectEqual(@as(usize, 1), ch.files.len);
    try std.testing.expectEqualStrings("c", ch.files[0]);
}

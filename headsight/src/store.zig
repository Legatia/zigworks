//! Crop files and named references under $TMPDIR/headsight. Crops older than
//! a day and references older than an hour are removed when a store opens.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const frame = @import("frame.zig");
const args = @import("args.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;

pub const crop_max_age_s: i64 = 86_400;
pub const ref_max_age_s: i64 = 3_600;
const magic = "HSREF001";

pub const RefMeta = struct {
    source: args.Source,
    window_id: u32 = 0,
    region: Rect,
    created_s: i64,
    src_w: u32,
    src_h: u32,
};

pub const Ref = struct {
    meta: RefMeta,
    /// The region's pixels, tight stride.
    frame: Frame,
    buf: []u8,

    pub fn deinit(r: *Ref, alloc: std.mem.Allocator) void {
        alloc.free(r.buf);
    }
};

pub const Error = error{ BadName, NoSuchRef, RefExpired, BadRef };

/// Where crops and references live: $TMPDIR/headsight (per user on macOS), or
/// /tmp/headsight-UID when TMPDIR is unset, so users never share a folder.
pub fn baseDir(alloc: std.mem.Allocator, tmpdir: ?[]const u8, uid: u32) ![]u8 {
    if (tmpdir) |t| return std.Io.Dir.path.join(alloc, &.{ t, "headsight" });
    return alloc.print("/tmp/headsight-{d}", .{uid});
}

pub const Store = struct {
    alloc: std.mem.Allocator,
    io: Io,
    base: []const u8,
    dir: Io.Dir,
    counter: u32 = 0,

    /// Opens (creating it private, mode 0700) the folder for crops and references.
    /// Refuses a folder that isn't this user's or that others can write to.
    pub fn open(alloc: std.mem.Allocator, io: Io, base: []const u8, now_s: i64) !Store {
        const cwd = Io.Dir.cwd();
        if (std.Io.Dir.path.dirname(base)) |parent| _ = try cwd.createDirPathStatus(io, parent, dir_mode);
        cwd.createDir(io, base, .fromMode(0o700)) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        // A symlink planted where the folder belongs (shared /tmp) is refused,
        // not followed.
        const lst = try cwd.statFile(io, base, .{ .follow_symlinks = false });
        if (lst.kind == .sym_link) return error.UnsafeStore;
        var dir = cwd.openDir(io, base, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
            error.SymLinkLoop => return error.UnsafeStore,
            else => return e,
        };
        errdefer dir.close(io);
        const own = try ownerOf(dir.handle);
        if (own.uid != std.posix.system.getuid() or own.mode & 0o022 != 0) return error.UnsafeStore;
        var s = Store{ .alloc = alloc, .io = io, .base = try alloc.dupe(u8, base), .dir = dir };
        s.cleanup(now_s);
        return s;
    }

    fn cleanup(s: *Store, now_s: i64) void {
        const io = s.io;
        var it = s.dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".png")) continue;
            const st = s.dir.statFile(io, e.name, .{}) catch continue;
            if (now_s - mtimeS(st) > crop_max_age_s)
                s.dir.deleteFile(io, e.name) catch {};
        }
        var refs = s.dir.openDir(io, "ref", .{ .iterate = true }) catch return;
        defer refs.close(io);
        var rit = refs.iterate();
        while (rit.next(io) catch null) |e| {
            if (e.kind != .file) continue;
            const created = if (std.mem.endsWith(u8, e.name, ".ref")) createdOf(io, refs, e.name) else blk: {
                const st = refs.statFile(io, e.name, .{}) catch continue;
                break :blk mtimeS(st);
            };
            if (now_s - created > ref_max_age_s) refs.deleteFile(io, e.name) catch {};
        }
    }

    pub fn close(s: *Store) void {
        s.dir.close(s.io);
        s.alloc.free(s.base);
    }

    /// A new crop file path, owned by the caller.
    pub fn cropPath(s: *Store) ![]const u8 {
        s.counter += 1;
        return s.alloc.print("{s}/{x}-{d}.png", .{ s.base, @as(u32, @intCast(std.c.getpid())), s.counter });
    }

    pub fn saveRef(s: *Store, name: []const u8, meta: RefMeta, f: Frame) !void {
        if (!args.validName(name)) return error.BadName;
        std.debug.assert(f.full().contains(meta.region));
        const io = s.io;
        var refs = try s.dir.createDirPathOpen(io, "ref", .{ .permissions = dir_mode });
        defer refs.close(io);
        var tmp_buf: [80]u8 = undefined;
        const tmp = try std.mem.print(&tmp_buf, ".{s}.tmp", .{name});
        var final_buf: [80]u8 = undefined;
        const final = try std.mem.print(&final_buf, "{s}.ref", .{name});

        var file = try refs.createFile(io, tmp, .{ .permissions = .fromMode(0o600), .truncate = true });
        errdefer refs.deleteFile(io, tmp) catch {};
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o600));
        const label: []const u8 = switch (meta.source) {
            .screen => "",
            .window => |t| t,
            .camera => |n| n orelse "",
        };
        var hdr: [header_len]u8 = undefined;
        @memcpy(hdr[0..8], magic);
        const fields = [_]u32{ meta.src_w, meta.src_h, meta.region.x, meta.region.y, meta.region.w, meta.region.h, meta.window_id, @backingInt(meta.source) };
        for (fields, 0..) |v, i| std.mem.writeInt(u32, hdr[8 + i * 4 ..][0..4], v, .little);
        std.mem.writeInt(i64, hdr[40..48], meta.created_s, .little);
        std.mem.writeInt(u16, hdr[48..50], @intCast(@min(label.len, 4096)), .little);
        try file.writeStreamingAll(io, &hdr);
        try file.writeStreamingAll(io, label[0..@min(label.len, 4096)]);
        const r = meta.region;
        var y = r.y;
        while (y < r.bottom()) : (y += 1)
            try file.writeStreamingAll(io, f.px[@as(usize, y) * f.stride + @as(usize, r.x) * 4 ..][0 .. @as(usize, r.w) * 4]);
        try refs.rename(tmp, refs, final, io);
    }

    pub fn loadRef(s: *Store, name: []const u8, now_s: i64) !Ref {
        if (!args.validName(name)) return error.BadName;
        var path_buf: [96]u8 = undefined;
        const path = try std.mem.print(&path_buf, "ref/{s}.ref", .{name});
        const buf = s.dir.readFileAlloc(s.io, path, s.alloc, .limited(1 << 31)) catch |e| switch (e) {
            error.FileNotFound => return error.NoSuchRef,
            else => return e,
        };
        errdefer s.alloc.free(buf);
        if (buf.len < header_len or !std.mem.eql(u8, buf[0..8], magic)) return error.BadRef;
        var v: [8]u32 = undefined;
        for (&v, 0..) |*x, i| x.* = std.mem.readInt(u32, buf[8 + i * 4 ..][0..4], .little);
        const created = std.mem.readInt(i64, buf[40..48], .little);
        const label_len = std.mem.readInt(u16, buf[48..50], .little);
        if (now_s - created > ref_max_age_s) {
            s.dir.deleteFile(s.io, path) catch {};
            return error.RefExpired;
        }
        const region = Rect{ .x = v[2], .y = v[3], .w = v[4], .h = v[5] };
        const px_start = header_len + @as(usize, label_len);
        if (buf.len != px_start + @as(usize, region.w) * region.h * 4) return error.BadRef;
        const label = buf[header_len..px_start];
        const source: args.Source = switch (v[7]) {
            0 => .screen,
            1 => .{ .window = label },
            2 => .{ .camera = if (label.len == 0) null else label },
            else => return error.BadRef,
        };
        return .{
            .meta = .{ .source = source, .window_id = v[6], .region = region, .created_s = created, .src_w = v[0], .src_h = v[1] },
            .frame = .{ .px = buf[px_start..], .w = region.w, .h = region.h, .stride = region.w * 4 },
            .buf = buf,
        };
    }

    pub fn dropRef(s: *Store, name: []const u8) !bool {
        if (!args.validName(name)) return error.BadName;
        var path_buf: [96]u8 = undefined;
        const path = try std.mem.print(&path_buf, "ref/{s}.ref", .{name});
        s.dir.deleteFile(s.io, path) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        return true;
    }
};

pub fn checkSize(ref: Ref, src_w: u32, src_h: u32) error{SizeChanged}!void {
    if (ref.meta.src_w != src_w or ref.meta.src_h != src_h) return error.SizeChanged;
}

const header_len = 8 + 8 * 4 + 8 + 2;

fn createdOf(io: Io, dir: Io.Dir, name: []const u8) i64 {
    var f = dir.openFile(io, name, .{}) catch return 0;
    defer f.close(io);
    var hdr: [header_len]u8 = undefined;
    const n = f.readPositionalAll(io, &hdr, 0) catch return 0;
    if (n < header_len or !std.mem.eql(u8, hdr[0..8], magic)) return 0;
    return std.mem.readInt(i64, hdr[40..48], .little);
}

/// Folders the store makes besides its own (which is 0700): rwxr-xr-x before the umask.
const dir_mode: Io.File.Permissions = .fromMode(0o755);

fn mtimeS(st: Io.File.Stat) i64 {
    return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
}

const Owner = struct { uid: std.posix.uid_t, mode: u32 };

/// Who owns an open folder and its mode bits, from one fstat. `std.Io` reports
/// the mode but not the owner, so this asks the system directly.
fn ownerOf(fd: std.posix.fd_t) !Owner {
    if (builtin.os.tag == .linux) {
        // Linux has no fstat in std; statx on the handle itself is the same call
        // std.Io makes for its own stat.
        const linux = std.os.linux;
        var stx = std.mem.zeroes(linux.Statx);
        while (true) switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true }, &stx))) {
            .SUCCESS => break,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOMEM => return error.SystemResources,
            else => |e| return std.posix.unexpectedErrno(e),
        };
        if (!stx.mask.MODE or !stx.mask.UID) return error.Unexpected;
        return .{ .uid = stx.uid, .mode = stx.mode };
    }
    var st = std.mem.zeroes(std.c.Stat);
    while (true) switch (std.c.errno(std.c.fstat(fd, &st))) {
        .SUCCESS => break,
        .INTR => continue,
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.SystemResources,
        else => |e| return std.posix.unexpectedErrno(e),
    };
    return .{ .uid = st.uid, .mode = st.mode };
}

// ---- tests ----

const testing = std.testing;

const T = struct {
    tmp: std.testing.TmpDir,
    base: []const u8,

    fn init() !T {
        var tmp = std.testing.tmpDir(.{});
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        return .{ .tmp = tmp, .base = try std.Io.Dir.path.join(testing.allocator, &.{ root, "headsight" }) };
    }
    fn deinit(t: *T) void {
        testing.allocator.free(t.base);
        t.tmp.cleanup();
    }
};

fn pattern(w: u32, h: u32) ![]u8 {
    const px = try testing.allocator.alloc(u8, w * h * 4);
    for (px, 0..) |*p, i| p.* = @truncate(i *% 7);
    return px;
}

fn nowS() i64 {
    return Io.Timestamp.now(testing.io, .real).toSeconds();
}

fn testMeta(created: i64) RefMeta {
    return .{ .source = .{ .window = "Safari" }, .window_id = 42, .region = .{ .x = 5, .y = 5, .w = 20, .h = 10 }, .created_s = created, .src_w = 40, .src_h = 30 };
}

test "base_dir_is_per_user_without_tmpdir" {
    const a = try baseDir(testing.allocator, null, 501);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/tmp/headsight-501", a);
    const b = try baseDir(testing.allocator, "/var/folders/x/T/", 501);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/var/folders/x/T/headsight", b);
}

test "open_makes_a_private_dir_and_refuses_a_shared_one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const mine = try std.Io.Dir.path.join(testing.allocator, &.{ root, "mine" });
    defer testing.allocator.free(mine);
    var s = try Store.open(testing.allocator, testing.io, mine, 0);
    s.close();
    const st = try cwd.statFile(io, mine, .{});
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));

    const shared = try std.Io.Dir.path.join(testing.allocator, &.{ root, "shared" });
    defer testing.allocator.free(shared);
    try cwd.createDir(io, shared, dir_mode);
    // .iterate opens a real handle; on Linux the default is path-only, which chmod refuses
    var d = try cwd.openDir(io, shared, .{ .iterate = true });
    try d.setPermissions(io, .fromMode(0o777));
    d.close(io);
    try testing.expectError(error.UnsafeStore, Store.open(testing.allocator, testing.io, shared, 0));

    // a symlink planted where the folder should be is refused
    const link = try std.Io.Dir.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link);
    try cwd.symLink(io, mine, link, .{ .is_directory = true });
    try testing.expectError(error.UnsafeStore, Store.open(testing.allocator, testing.io, link, 0));

    const file = try std.Io.Dir.path.join(testing.allocator, &.{ root, "file" });
    defer testing.allocator.free(file);
    (try cwd.createFile(io, file, .{})).close(io);
    try testing.expectError(error.NotDir, Store.open(testing.allocator, testing.io, file, 0));
}

test "ref_roundtrip" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    const now = nowS();
    try s.saveRef("before", testMeta(now), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    var r = try s.loadRef("before", now + 10);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("Safari", r.meta.source.window);
    try testing.expectEqual(@as(u32, 42), r.meta.window_id);
    try testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 20, .h = 10 }, r.meta.region);
    try testing.expectEqual(@as(u32, 20), r.frame.w);
    try testing.expectEqual(@as(u32, 10), r.frame.h);
    // row 0 of the reference is row 5 of the source from column 5
    try testing.expectEqualSlices(u8, px[(5 * 40 + 5) * 4 ..][0 .. 20 * 4], r.frame.px[0 .. 20 * 4]);
    try testing.expectEqualSlices(u8, px[(14 * 40 + 5) * 4 ..][0 .. 20 * 4], r.frame.px[9 * 80 ..][0 .. 20 * 4]);
}

test "ref_mode_0600" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("m", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    const st = try s.dir.statFile(testing.io, "ref/m.ref", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "ref_expires_after_hour" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    const now = nowS();
    try s.saveRef("old", testMeta(now), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    try testing.expectError(error.RefExpired, s.loadRef("old", now + 3601));
    try testing.expectError(error.FileNotFound, s.dir.statFile(testing.io, "ref/old.ref", .{}));
}

test "drop_ref" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("d", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    try testing.expect(try s.dropRef("d"));
    try testing.expect(!(try s.dropRef("d")));
    try testing.expectError(error.NoSuchRef, s.loadRef("d", nowS()));
}

test "cleanup_old_crops" {
    var t = try T.init();
    defer t.deinit();
    {
        var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
        defer s.close();
        const p = try s.cropPath();
        defer testing.allocator.free(p);
        (try Io.Dir.cwd().createFile(testing.io, p, .{})).close(testing.io);
        var s2 = try Store.open(testing.allocator, testing.io, t.base, nowS() + 3600);
        s2.close();
        try Io.Dir.cwd().access(testing.io, p, .{});
        var s3 = try Store.open(testing.allocator, testing.io, t.base, nowS() + 25 * 3600);
        s3.close();
        try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, p, .{}));
    }
}

test "old_refs_removed_on_open" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("r", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    var s2 = try Store.open(testing.allocator, testing.io, t.base, nowS() + 3700);
    s2.close();
    try testing.expectError(error.FileNotFound, s.dir.statFile(testing.io, "ref/r.ref", .{}));
}

test "size_mismatch_reported" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try s.saveRef("z", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 });
    var r = try s.loadRef("z", nowS());
    defer r.deinit(testing.allocator);
    try testing.expectError(error.SizeChanged, checkSize(r, 41, 30));
    try checkSize(r, 40, 30);
}

test "bad_names_rejected" {
    var t = try T.init();
    defer t.deinit();
    var s = try Store.open(testing.allocator, testing.io, t.base, nowS());
    defer s.close();
    const px = try pattern(40, 30);
    defer testing.allocator.free(px);
    try testing.expectError(error.BadName, s.saveRef("../x", testMeta(nowS()), .{ .px = px, .w = 40, .h = 30, .stride = 160 }));
    try testing.expectError(error.BadName, s.loadRef("../x", nowS()));
    try testing.expectError(error.FileNotFound, s.dir.statFile(testing.io, "x.ref", .{}));
}

//! The folder for recordings from 'listen': $TMPDIR/headsound, or
//! /tmp/headsound-UID without TMPDIR (on Windows %TEMP%\headsound, which is
//! already the user's own). Private (0700); recordings older than a day are
//! removed when it opens.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;

const windows = builtin.target.os.tag == .windows;

pub const max_age_s: i64 = 86_400;

pub fn baseDir(alloc: std.mem.Allocator, tmpdir: ?[]const u8, uid: u32) ![]u8 {
    if (tmpdir) |t| return Dir.path.join(alloc, &.{ t, "headsound" });
    return alloc.print("/tmp/headsound-{d}", .{uid});
}

/// The folder for this user and system.
pub fn defaultDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (windows) {
        const t = env.get("TEMP") orelse env.get("TMP") orelse return error.EnvironmentVariableNotFound;
        return Dir.path.join(alloc, &.{ t, "headsound" });
    }
    return baseDir(alloc, env.get("TMPDIR"), std.c.getuid());
}

/// Opens (creating it, mode 0700) the folder. Refuses a symlink, a folder of
/// another user, or one others can write to.
pub fn open(io: Io, base: []const u8, now_s: i64) !Dir {
    if (windows) {
        // %TEMP% is in the user's profile, which other users can't read.
        try Dir.cwd().createDirPath(io, base);
        var dir = try Dir.cwd().openDir(io, base, .{ .iterate = true });
        errdefer dir.close(io);
        removeOld(io, dir, now_s);
        return dir;
    }
    if (Dir.path.dirname(base)) |parent| try Dir.cwd().createDirPath(io, parent);
    Dir.cwd().createDir(io, base, .fromMode(0o700)) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const lst = try Dir.cwd().statFile(io, base, .{ .follow_symlinks = false });
    if (lst.kind == .sym_link) return error.UnsafeStore;
    var dir = Dir.cwd().openDir(io, base, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
        error.SymLinkLoop => return error.UnsafeStore,
        else => return e,
    };
    errdefer dir.close(io);
    const st = try ownerAndMode(dir);
    if (st.uid != std.c.getuid() or st.mode & 0o022 != 0) return error.UnsafeStore;
    removeOld(io, dir, now_s);
    return dir;
}

const OwnerAndMode = struct { uid: u32, mode: u32 };

/// Who owns the open folder, and its mode bits. std.Io's stat leaves the
/// owner out, so this asks the system: statx on Linux (which has no fstat in
/// std.c), fstat elsewhere.
fn ownerAndMode(dir: Dir) !OwnerAndMode {
    if (builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        while (true) {
            switch (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &stx))) {
                .SUCCESS => break,
                .INTR => continue,
                .ACCES => return error.AccessDenied,
                .NOMEM => return error.SystemResources,
                else => return error.Unexpected,
            }
        }
        if (!stx.mask.UID or !stx.mask.MODE) return error.Unexpected;
        return .{ .uid = stx.uid, .mode = stx.mode };
    }
    var st: std.c.Stat = undefined;
    while (true) {
        switch (std.c.errno(std.c.fstat(dir.handle, &st))) {
            .SUCCESS => break,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    return .{ .uid = st.uid, .mode = st.mode };
}

fn removeOld(io: Io, dir: Dir, now_s: i64) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".wav")) continue;
        const fst = dir.statFile(io, e.name, .{}) catch continue;
        if (now_s - @as(i64, @intCast(@divFloor(fst.mtime.nanoseconds, std.time.ns_per_s))) > max_age_s) dir.deleteFile(io, e.name) catch {};
    }
}

/// Permissions for a new recording: only its owner reads it.
pub const file_permissions: Io.File.Permissions = if (windows) .default_file else .fromMode(0o600);

const testing = std.testing;

test "base_dir_is_per_user_without_tmpdir" {
    const a = try baseDir(testing.allocator, "/var/x", 501);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/var/x" ++ Dir.path.sep_str ++ "headsound", a);
    const b = try baseDir(testing.allocator, null, 501);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/headsound-501", b);
}

test "open_makes_a_private_dir_and_refuses_a_shared_one" {
    if (windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const base = try Dir.path.join(testing.allocator, &.{ root, "headsound" });
    defer testing.allocator.free(base);
    var d = try open(io, base, Io.Timestamp.now(io, .real).toSeconds());
    const st = try ownerAndMode(d);
    try testing.expectEqual(@as(u32, 0o700), st.mode & 0o777);
    d.close(io);

    const shared = try Dir.path.join(testing.allocator, &.{ root, "shared" });
    defer testing.allocator.free(shared);
    try Dir.cwd().createDir(io, shared, .fromMode(0o700));
    var sd = try Dir.cwd().openDir(io, shared, .{ .iterate = true });
    try sd.setPermissions(io, .fromMode(0o777));
    sd.close(io);
    try testing.expectError(error.UnsafeStore, open(io, shared, 0));

    const link = try Dir.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link);
    try Dir.cwd().symLink(io, base, link, .{});
    try testing.expectError(error.UnsafeStore, open(io, link, 0));
}

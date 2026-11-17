//! The folder for recordings from 'listen': $TMPDIR/headsound, or
//! /tmp/headsound-UID without TMPDIR (on Windows %TEMP%\headsound, which is
//! already the user's own). Private (0700); recordings older than a day are
//! removed when it opens.
const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

pub const max_age_s: i64 = 86_400;

pub fn baseDir(alloc: std.mem.Allocator, tmpdir: ?[]const u8, uid: u32) ![]u8 {
    if (tmpdir) |t| return std.fs.path.join(alloc, &.{ t, "headsound" });
    return std.fmt.allocPrint(alloc, "/tmp/headsound-{d}", .{uid});
}

/// The folder for this user and system.
pub fn defaultDir(alloc: std.mem.Allocator) ![]u8 {
    if (windows) {
        const t = std.process.getEnvVarOwned(alloc, "TEMP") catch try std.process.getEnvVarOwned(alloc, "TMP");
        defer alloc.free(t);
        return std.fs.path.join(alloc, &.{ t, "headsound" });
    }
    return baseDir(alloc, std.posix.getenv("TMPDIR"), std.posix.getuid());
}

/// Opens (creating it, mode 0700) the folder. Refuses a symlink, a folder of
/// another user, or one others can write to.
pub fn open(base: []const u8, now_s: i64) !std.fs.Dir {
    if (windows) {
        // %TEMP% is in the user's profile, which other users can't read.
        try std.fs.cwd().makePath(base);
        var dir = try std.fs.cwd().openDir(base, .{ .iterate = true });
        errdefer dir.close();
        removeOld(dir, now_s);
        return dir;
    }
    if (std.fs.path.dirname(base)) |parent| try std.fs.cwd().makePath(parent);
    std.posix.mkdir(base, 0o700) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const lst = try std.posix.fstatat(std.fs.cwd().fd, base, std.posix.AT.SYMLINK_NOFOLLOW);
    if (lst.mode & std.posix.S.IFMT == std.posix.S.IFLNK) return error.UnsafeStore;
    var dir = std.fs.cwd().openDir(base, .{ .iterate = true, .no_follow = true }) catch |e| switch (e) {
        error.SymLinkLoop => return error.UnsafeStore,
        else => return e,
    };
    errdefer dir.close();
    const st = try std.posix.fstat(dir.fd);
    if (st.uid != std.posix.getuid() or st.mode & 0o022 != 0) return error.UnsafeStore;
    removeOld(dir, now_s);
    return dir;
}

fn removeOld(dir: std.fs.Dir, now_s: i64) void {
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".wav")) continue;
        const fst = dir.statFile(e.name) catch continue;
        if (now_s - @as(i64, @intCast(@divFloor(fst.mtime, std.time.ns_per_s))) > max_age_s) dir.deleteFile(e.name) catch {};
    }
}

/// Mode for a new recording: only its owner reads it.
pub const file_mode: std.fs.File.Mode = if (windows) 0 else 0o600;

const testing = std.testing;

test "base_dir_is_per_user_without_tmpdir" {
    const a = try baseDir(testing.allocator, "/var/x", 501);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/var/x/headsound", a);
    const b = try baseDir(testing.allocator, null, 501);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/headsound-501", b);
}

test "open_makes_a_private_dir_and_refuses_a_shared_one" {
    if (windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const base = try std.fs.path.join(testing.allocator, &.{ root, "headsound" });
    defer testing.allocator.free(base);
    var d = try open(base, std.time.timestamp());
    const st = try std.posix.fstat(d.fd);
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.mode & 0o777)));
    d.close();

    const shared = try std.fs.path.join(testing.allocator, &.{ root, "shared" });
    defer testing.allocator.free(shared);
    try std.posix.mkdir(shared, 0o700);
    var sd = try std.fs.cwd().openDir(shared, .{ .iterate = true });
    try std.posix.fchmod(sd.fd, 0o777);
    sd.close();
    try testing.expectError(error.UnsafeStore, open(shared, 0));

    const link = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link);
    try std.posix.symlink(base, link);
    try testing.expectError(error.UnsafeStore, open(link, 0));
}

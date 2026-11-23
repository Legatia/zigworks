//! Copy-on-write clones for the snapshot store (snapshots.CloneFn): a new
//! file that shares an existing one's blocks, where the file system can,
//! so a snapshot of a large folder costs no space until its files change.
//! Linux: FICLONE (btrfs; XFS made with reflink, the default since 2019).
//! Windows: block cloning (FSCTL_DUPLICATE_EXTENTS_TO_FILE) on ReFS and
//! Dev Drives. macOS: clonefile on APFS. Where the file system can't, a
//! helper says false and leaves nothing behind: the store then copies.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

/// The signature of snapshots.CloneFn.
pub const Fn = *const fn (io: Io, src: []const u8, dst: []const u8) anyerror!bool;

/// This system's helper; null where none is built here.
pub const platform: ?Fn = switch (builtin.os.tag) {
    .linux => linuxClone,
    .windows => windowsClone,
    .macos => macClone,
    else => null,
};

/// clonefile: `dst`, made now, shares `src`'s blocks (APFS). A clone takes
/// its source's mode and flags, so it is made the owner's alone, as a
/// copied object is, and a file made unchangeable (chflags) is copied
/// instead: its clone could be neither renamed nor deleted.
fn macClone(io: Io, src: []const u8, dst: []const u8) anyerror!bool {
    if (builtin.os.tag != .macos) return false;
    _ = io;
    const c = std.c;
    const s = try std.posix.toPosixPath(src);
    const d = try std.posix.toPosixPath(dst);
    var st: c.Stat = undefined;
    const rc = c.fstatat(c.AT.FDCWD, &s, &st, c.AT.SYMLINK_NOFOLLOW);
    if (rc != 0) return failed(std.posix.errno(rc));
    if (st.flags & no_clone_flags != 0) return false;
    const cl = clonefile(&s, &d, clone_nofollow);
    if (cl != 0) {
        const e = std.posix.errno(cl);
        // the file system can't (HFS+, exFAT, a network share; EOPNOTSUPP
        // is 102 beside ENOTSUP), or another volume: the store copies
        if (e == .OPNOTSUPP or e == .XDEV or @backingInt(e) == 102) return false;
        return failed(e);
    }
    if (c.chmod(&d, 0o600) != 0) {
        _ = c.unlink(&d);
        return false;
    }
    return true;
}

const clone_nofollow: u32 = 0x1;
/// UF_IMMUTABLE, UF_APPEND, SF_IMMUTABLE, SF_APPEND, SF_RESTRICTED,
/// SF_NOUNLINK: what keeps a file from being renamed or deleted.
const no_clone_flags: u32 = 0x2 | 0x4 | 0x20000 | 0x40000 | 0x80000 | 0x100000;
extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;

/// An errno from clonefile or stat as an error; EEXIST: `dst` is there and
/// is never overwritten.
fn failed(e: std.posix.E) anyerror {
    return switch (e) {
        .EXIST => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOSPC => error.NoSpaceLeft,
        .NAMETOOLONG => error.NameTooLong,
        else => std.posix.unexpectedErrno(e),
    };
}

/// FICLONE: `dst`, made now, shares `src`'s extents.
fn linuxClone(io: Io, src: []const u8, dst: []const u8) anyerror!bool {
    if (builtin.os.tag != .linux) return false;
    const linux = std.os.linux;
    const s = try Io.Dir.cwd().openFile(io, src, .{});
    defer s.close(io);
    const d = try Io.Dir.cwd().createFile(io, dst, .{ .exclusive = true });
    var cloned = false;
    defer {
        d.close(io);
        if (!cloned) Io.Dir.cwd().deleteFile(io, dst) catch {};
    }
    // _IOW(0x94, 9, int)
    const FICLONE: u32 = 0x40049409;
    const rc = linux.ioctl(d.handle, FICLONE, @as(usize, @intCast(s.handle)));
    // EOPNOTSUPP (ext4, tmpfs), EXDEV (another file system), EINVAL...: copy
    if (linux.errno(rc) != .SUCCESS) return false;
    cloned = true;
    return true;
}

/// Block cloning: `dst`, made now with `src`'s size (and integrity
/// setting), gets `src`'s clusters by reference, a cluster-aligned range
/// at a time. Only where the volume counts block references (ReFS, Dev
/// Drives); NTFS says false at once.
fn windowsClone(io: Io, src: []const u8, dst: []const u8) anyerror!bool {
    if (builtin.os.tag != .windows) return false;
    var src_buf: [windows.PATH_MAX_WIDE + 8]u16 = undefined;
    var dst_buf: [windows.PATH_MAX_WIDE + 8]u16 = undefined;
    const s = win.CreateFileW(try longPath(&src_buf, src), win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, 0, null);
    if (s == windows.INVALID_HANDLE_VALUE) return error.FileNotFound;
    defer windows.CloseHandle(s);
    var flags: u32 = 0;
    if (!win.GetVolumeInformationByHandleW(s, null, 0, null, null, &flags, null, 0).toBool()) return false;
    if (flags & win.FILE_SUPPORTS_BLOCK_REFCOUNTING == 0) return false;
    var integrity: win.IntegrityInfo = .{};
    var ret: u32 = 0;
    if (!win.DeviceIoControl(s, win.FSCTL_GET_INTEGRITY_INFORMATION, null, 0, &integrity, @sizeOf(win.IntegrityInfo), &ret, null).toBool()) return false;
    const cluster: u64 = integrity.cluster_size;
    if (cluster == 0) return false;
    var size: i64 = 0;
    if (!win.GetFileSizeEx(s, &size).toBool()) return false;

    const d = win.CreateFileW(try longPath(&dst_buf, dst), win.GENERIC_READ | win.GENERIC_WRITE | win.DELETE, 0, null, win.CREATE_NEW, 0, null);
    if (d == windows.INVALID_HANDLE_VALUE) return error.PathAlreadyExists;
    var cloned = false;
    defer {
        windows.CloseHandle(d);
        if (!cloned) Io.Dir.cwd().deleteFile(io, dst) catch {};
    }
    // a file with integrity streams clones only into one that has them too
    if (integrity.checksum_algorithm != 0) {
        var set: win.SetIntegrity = .{ .checksum_algorithm = integrity.checksum_algorithm, .flags = integrity.flags };
        if (!win.DeviceIoControl(d, win.FSCTL_SET_INTEGRITY_INFORMATION, &set, @sizeOf(win.SetIntegrity), null, 0, &ret, null).toBool()) return false;
    }
    var eof: i64 = size;
    if (!win.SetFileInformationByHandle(d, win.FileEndOfFileInfo, &eof, @sizeOf(i64)).toBool()) return false;
    const total: u64 = @intCast(size);
    // a call takes under 4 GiB; a range is whole clusters, the last one
    // rounded up past the end of the file
    const step: u64 = (1 << 30);
    var off: u64 = 0;
    while (off < total) {
        const left = std.mem.alignForward(u64, total - off, cluster);
        const count = @min(step, left);
        var data: win.DuplicateExtents = .{ .file = s, .source_offset = @intCast(off), .target_offset = @intCast(off), .byte_count = @intCast(count) };
        if (!win.DeviceIoControl(d, win.FSCTL_DUPLICATE_EXTENTS_TO_FILE, &data, @sizeOf(win.DuplicateExtents), null, 0, &ret, null).toBool()) return false;
        off += count;
    }
    cloned = true;
    return true;
}

/// `path` for the wide APIs, `\\?\` before a drive path so long ones work.
fn longPath(buf: []u16, path: []const u8) ![*:0]const u16 {
    var n: usize = 0;
    const drive = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    if (drive) {
        for ("\\\\?\\") |c| {
            buf[n] = c;
            n += 1;
        }
    }
    const len = try std.unicode.utf8ToUtf16Le(buf[n .. buf.len - 1], path);
    for (buf[n .. n + len]) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    n += len;
    buf[n] = 0;
    return buf[0..n :0];
}

const win = struct {
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const DELETE: u32 = 0x00010000;
    const FILE_SHARE_READ: u32 = 0x1;
    const OPEN_EXISTING: u32 = 3;
    const CREATE_NEW: u32 = 1;
    const FILE_SUPPORTS_BLOCK_REFCOUNTING: u32 = 0x08000000;
    const FSCTL_GET_INTEGRITY_INFORMATION: u32 = 0x9027C;
    const FSCTL_SET_INTEGRITY_INFORMATION: u32 = 0x9C280;
    const FSCTL_DUPLICATE_EXTENTS_TO_FILE: u32 = 0x98344;
    const FileEndOfFileInfo: c_int = 6;

    const IntegrityInfo = extern struct {
        checksum_algorithm: u16 = 0,
        reserved: u16 = 0,
        flags: u32 = 0,
        checksum_chunk_size: u32 = 0,
        cluster_size: u32 = 0,
    };
    const SetIntegrity = extern struct {
        checksum_algorithm: u16 = 0,
        reserved: u16 = 0,
        flags: u32 = 0,
    };
    const DuplicateExtents = extern struct {
        file: windows.HANDLE,
        source_offset: i64,
        target_offset: i64,
        byte_count: i64,
    };

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetVolumeInformationByHandleW(file: windows.HANDLE, name: ?[*]u16, name_size: u32, serial: ?*u32, max_component: ?*u32, flags: *u32, fs_name: ?[*]u16, fs_name_size: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeviceIoControl(dev: windows.HANDLE, code: u32, in: ?*const anyopaque, in_size: u32, out: ?*anyopaque, out_size: u32, ret: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileSizeEx(file: windows.HANDLE, size: *i64) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetFileInformationByHandle(file: windows.HANDLE, class: c_int, info: *const anyopaque, size: u32) callconv(.winapi) windows.BOOL;
};

// ---- tests ----

const t = std.testing;

/// A file of `n` bytes, not all alike.
fn fill(a: std.mem.Allocator, n: usize) ![]u8 {
    const out = try a.alloc(u8, n);
    for (out, 0..) |*b, i| b.* = @truncate(i *% 131 +% i / 977);
    return out;
}

test "a_clone_is_whole_where_the_file_system_can_and_nothing_where_it_cannot" {
    const clone = platform orelse return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const src = try std.fs.path.join(a, &.{ root, "src.bin" });
    const dst = try std.fs.path.join(a, &.{ root, "dst.bin" });
    const content = try fill(a, 300 * 1024 + 7);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src.bin", .data = content });
    if (try clone(t.io, src, dst)) {
        try t.expectEqualSlices(u8, content, try tmp.dir.readFileAlloc(t.io, "dst.bin", a, .unlimited));
    } else {
        // the store copies then: no half file in the way
        try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "dst.bin", .{}));
    }
    // a file that is there already is never overwritten
    try tmp.dir.writeFile(t.io, .{ .sub_path = "taken.bin", .data = "mine" });
    const taken = try std.fs.path.join(a, &.{ root, "taken.bin" });
    if (clone(t.io, src, taken)) |ok| try t.expect(!ok) else |_| {}
    try t.expectEqualStrings("mine", try tmp.dir.readFileAlloc(t.io, "taken.bin", a, .limited(16)));
}

test "clones_share_blocks_on_copy_on_write_file_systems" {
    // folders on btrfs, XFS (reflink), ReFS or a Dev Drive, `;`-separated
    // (made for the test; this machine's own file systems usually can't);
    // on macOS without them, the test's own folder when it is on APFS
    const clone = platform orelse return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try t.environ.createMap(a);
    const dirs = env.get("HARNESS_TEST_COW_DIRS") orelse blk: {
        if (builtin.os.tag != .macos) return error.SkipZigTest;
        const own = try tmp.dir.realPathFileAlloc(t.io, ".", a);
        if (!try onApfs(own)) return error.SkipZigTest;
        break :blk own;
    };
    var it = std.mem.tokenizeScalar(u8, dirs, ';');
    var tried: usize = 0;
    while (it.next()) |dir| {
        tried += 1;
        const src = try std.fs.path.join(a, &.{ dir, "clone-src.bin" });
        const dst = try std.fs.path.join(a, &.{ dir, "clone-dst.bin" });
        Io.Dir.cwd().deleteFile(t.io, src) catch {};
        Io.Dir.cwd().deleteFile(t.io, dst) catch {};
        defer Io.Dir.cwd().deleteFile(t.io, src) catch {};
        defer Io.Dir.cwd().deleteFile(t.io, dst) catch {};
        const content = try fill(a, 5 * 1024 * 1024 + 123);
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = src, .data = content });
        if (!try clone(t.io, src, dst)) {
            std.debug.print("{s}: not cloned\n", .{dir});
            return error.TestUnexpectedResult;
        }
        try t.expectEqualSlices(u8, content, try Io.Dir.cwd().readFileAlloc(t.io, dst, a, .unlimited));
        // the clone is its own file: changing it leaves the original
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = dst, .data = "changed" });
        try t.expectEqualSlices(u8, content, try Io.Dir.cwd().readFileAlloc(t.io, src, a, .unlimited));
    }
    try t.expect(tried > 0);
}

/// macOS: whether the folder `path` is on APFS, which clones.
fn onApfs(path: []const u8) !bool {
    if (builtin.os.tag != .macos) return false;
    const p = try std.posix.toPosixPath(path);
    var st: Statfs = undefined;
    if (statfs(&p, &st) != 0) return false;
    return std.mem.eql(u8, std.mem.sliceTo(&st.fstypename, 0), "apfs");
}

/// macOS's struct statfs (64-bit inodes).
const Statfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

/// x86_64 Macs keep the 64-bit-inode struct under another name.
const statfs = @extern(*const fn ([*:0]const u8, *Statfs) callconv(.c) c_int, .{ .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs" });

test "an_apfs_clone_is_owner_only_and_an_unchangeable_file_is_copied_instead" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    if (!try onApfs(root)) return error.SkipZigTest;
    const src = try std.fs.path.join(a, &.{ root, "src.bin" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src.bin", .data = "shared\n", .flags = .{ .permissions = .fromMode(0o755) } });
    // a clone keeps its source's mode; an object is the owner's alone, as
    // a copied one is
    const dst = try std.fs.path.join(a, &.{ root, "dst.bin" });
    try t.expect(try macClone(t.io, src, dst));
    try t.expectEqual(@as(u32, 0o600), (try tmp.dir.statFile(t.io, "dst.bin", .{})).permissions.toMode() & 0o7777);
    // a file made unchangeable (chflags uchg) would be cloned so too, and
    // the store could neither rename nor delete it: copied instead
    const p = try std.posix.toPosixPath(src);
    try t.expectEqual(@as(c_int, 0), chflags(&p, uf_immutable));
    defer _ = chflags(&p, 0);
    const locked = try std.fs.path.join(a, &.{ root, "locked.bin" });
    const lp = try std.posix.toPosixPath(locked);
    defer _ = chflags(&lp, 0);
    try t.expect(!try macClone(t.io, src, locked));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "locked.bin", .{}));
}

extern "c" fn chflags(path: [*:0]const u8, flags: u32) c_int;
const uf_immutable: u32 = 0x2;

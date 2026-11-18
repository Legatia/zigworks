//! What differs between Windows and the rest: environment lookup, reading an
//! index into memory, and the names of things on PATH.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const windows = builtin.os.tag == .windows;

/// The value of environment variable `key`, or null when it isn't set.
/// On Windows the value is allocated from `arena`.
pub fn getenv(arena: Allocator, env: std.process.Environ, key: []const u8) ?[]const u8 {
    if (!windows) return env.getPosix(key);
    return env.getAlloc(arena, key) catch null;
}

/// The user's home directory.
pub fn home(arena: Allocator, env: std.process.Environ) ?[]const u8 {
    return getenv(arena, env, if (windows) "USERPROFILE" else "HOME");
}

/// `path` with Windows' backslashes turned into forward slashes, in place.
pub fn slashes(path: []u8) []u8 {
    if (windows) std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}

/// The name a program has in a PATH directory.
pub fn exeName(comptime name: []const u8) []const u8 {
    return if (windows) name ++ ".exe" else name;
}

/// `name` without the `.exe` Windows adds.
pub fn stripExe(name: []const u8) []const u8 {
    if (windows and std.ascii.endsWithIgnoreCase(name, ".exe")) return name[0 .. name.len - 4];
    return name;
}

pub const Mapped = []align(std.heap.page_size_min) const u8;

/// The first `size` bytes of `file`, read-only. Mapped where that leaves the
/// file free to be replaced (everywhere but Windows, where a mapped file
/// can't be renamed over or deleted, and an index is replaced on every
/// update); read into memory there.
pub fn mapFile(io: Io, file: Io.File, size: usize) !Mapped {
    if (!windows) return std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    const buf = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), size);
    errdefer std.heap.page_allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != size) return error.BadIndex;
    return buf;
}

pub fn unmapFile(data: Mapped) void {
    if (!windows) return std.posix.munmap(data);
    std.heap.page_allocator.free(data);
}

test "exe names" {
    try std.testing.expectEqualStrings(if (windows) "rg.exe" else "rg", exeName("rg"));
    try std.testing.expectEqualStrings("rg", stripExe(exeName("rg")));
    try std.testing.expectEqualStrings("trigrep", stripExe("trigrep"));
}

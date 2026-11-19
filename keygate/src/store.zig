//! Where secret values are kept: the macOS Keychain, the Windows
//! Credential Manager, or (elsewhere, and in tests) one file per secret in
//! a directory only the user can read.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Error = error{ StoreFailed, OutOfMemory };

pub const Store = union(enum) {
    /// A directory; each secret is a file in it, readable by the user only.
    dir: []const u8,
    keychain,
    wincred,

    pub fn describe(s: Store) []const u8 {
        return switch (s) {
            .dir => "a file per secret, readable only by you",
            .keychain => "the macOS Keychain",
            .wincred => "the Windows Credential Manager",
        };
    }

    pub fn put(s: Store, io: Io, name: []const u8, value: []const u8) Error!void {
        switch (s) {
            .dir => |d| dirPut(io, d, name, value) catch return error.StoreFailed,
            .keychain => if (is_mac) try mac.put(name, value) else unreachable,
            .wincred => if (is_windows) try win.put(name, value) else unreachable,
        }
    }

    /// The value, or null if none is stored. Caller frees.
    pub fn get(s: Store, io: Io, gpa: std.mem.Allocator, name: []const u8) Error!?[]u8 {
        return switch (s) {
            .dir => |d| dirGet(io, gpa, d, name),
            .keychain => if (is_mac) mac.get(gpa, name) else unreachable,
            .wincred => if (is_windows) win.get(gpa, name) else unreachable,
        };
    }

    /// False if there was nothing to remove.
    pub fn remove(s: Store, io: Io, name: []const u8) Error!bool {
        return switch (s) {
            .dir => |d| {
                var dir = Io.Dir.cwd().openDir(io, d, .{}) catch |e| switch (e) {
                    error.FileNotFound => return false,
                    else => return error.StoreFailed,
                };
                defer dir.close(io);
                dir.deleteFile(io, name) catch |e| switch (e) {
                    error.FileNotFound => return false,
                    else => return error.StoreFailed,
                };
                return true;
            },
            .keychain => if (is_mac) mac.remove(name) else unreachable,
            .wincred => if (is_windows) win.remove(name) else unreachable,
        };
    }
};

const is_mac = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

/// The system's store, unless `override` names a directory.
pub fn default(override: ?[]const u8, data_dir: ?[]const u8) Store {
    if (override) |d| return .{ .dir = d };
    if (is_mac) return .keychain;
    if (is_windows) return .wincred;
    return .{ .dir = data_dir orelse "keygate-secrets" };
}

fn dirPut(io: Io, path: []const u8, name: []const u8, value: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
    // iterate: on Linux a plain open is O_PATH, and fchmod on it fails with EBADF
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    if (!is_windows) {
        // the directory too: nobody else may list it
        try dir.setPermissions(io, .fromMode(0o700));
    }
    // a new file each time, so its permissions are ours from the start
    dir.deleteFile(io, name) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    var f = try dir.createFile(io, name, .{
        .exclusive = true,
        .permissions = if (is_windows) .default_file else .fromMode(0o600),
    });
    defer f.close(io);
    try f.writeStreamingAll(io, value);
}

fn dirGet(io: Io, gpa: std.mem.Allocator, path: []const u8, name: []const u8) Error!?[]u8 {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return error.StoreFailed,
    };
    defer dir.close(io);
    return dir.readFileAlloc(io, name, gpa, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => error.StoreFailed,
    };
}

const service = "keygate";

const mac = struct {
    const OSStatus = i32;
    const errSecItemNotFound: OSStatus = -25300;
    extern "Security" fn SecKeychainAddGenericPassword(keychain: ?*anyopaque, service_len: u32, service_name: [*]const u8, account_len: u32, account: [*]const u8, password_len: u32, password: [*]const u8, item: ?*?*anyopaque) OSStatus;
    extern "Security" fn SecKeychainFindGenericPassword(keychain: ?*anyopaque, service_len: u32, service_name: [*]const u8, account_len: u32, account: [*]const u8, password_len: ?*u32, password: ?*?[*]u8, item: ?*?*anyopaque) OSStatus;
    extern "Security" fn SecKeychainItemModifyAttributesAndData(item: *anyopaque, attrs: ?*anyopaque, len: u32, data: [*]const u8) OSStatus;
    extern "Security" fn SecKeychainItemFreeContent(attrs: ?*anyopaque, data: ?*anyopaque) OSStatus;
    extern "Security" fn SecKeychainItemDelete(item: *anyopaque) OSStatus;
    extern "CoreFoundation" fn CFRelease(cf: *anyopaque) void;

    fn find(name: []const u8, item: *?*anyopaque, len: ?*u32, data: ?*?[*]u8) OSStatus {
        return SecKeychainFindGenericPassword(null, service.len, service, @intCast(name.len), name.ptr, len, data, item);
    }

    fn put(name: []const u8, value: []const u8) Error!void {
        var item: ?*anyopaque = null;
        const st = find(name, &item, null, null);
        if (st == 0) {
            defer CFRelease(item.?);
            if (SecKeychainItemModifyAttributesAndData(item.?, null, @intCast(value.len), value.ptr) != 0) return error.StoreFailed;
            return;
        }
        if (st != errSecItemNotFound) return error.StoreFailed;
        if (SecKeychainAddGenericPassword(null, service.len, service, @intCast(name.len), name.ptr, @intCast(value.len), value.ptr, null) != 0) return error.StoreFailed;
    }

    fn get(gpa: std.mem.Allocator, name: []const u8) Error!?[]u8 {
        var len: u32 = 0;
        var data: ?[*]u8 = null;
        const st = SecKeychainFindGenericPassword(null, service.len, service, @intCast(name.len), name.ptr, &len, &data, null);
        if (st == errSecItemNotFound) return null;
        if (st != 0) return error.StoreFailed;
        defer _ = SecKeychainItemFreeContent(null, data);
        const out = try gpa.alloc(u8, len);
        @memcpy(out, data.?[0..len]);
        return out;
    }

    fn remove(name: []const u8) Error!bool {
        var item: ?*anyopaque = null;
        const st = find(name, &item, null, null);
        if (st == errSecItemNotFound) return false;
        if (st != 0) return error.StoreFailed;
        defer CFRelease(item.?);
        if (SecKeychainItemDelete(item.?) != 0) return error.StoreFailed;
        return true;
    }
};

const win = struct {
    const windows = std.os.windows;
    const BOOL = windows.BOOL;
    const FILETIME = extern struct { lo: u32, hi: u32 };
    const CREDENTIALW = extern struct {
        Flags: u32 = 0,
        Type: u32,
        TargetName: [*:0]const u16,
        Comment: ?[*:0]const u16 = null,
        LastWritten: FILETIME = .{ .lo = 0, .hi = 0 },
        CredentialBlobSize: u32,
        CredentialBlob: ?[*]const u8,
        Persist: u32,
        AttributeCount: u32 = 0,
        Attributes: ?*anyopaque = null,
        TargetAlias: ?[*:0]const u16 = null,
        UserName: ?[*:0]const u16 = null,
    };
    const CRED_TYPE_GENERIC = 1;
    const CRED_PERSIST_LOCAL_MACHINE = 2;
    const ERROR_NOT_FOUND = 1168;
    extern "advapi32" fn CredWriteW(cred: *const CREDENTIALW, flags: u32) callconv(.winapi) BOOL;
    extern "advapi32" fn CredReadW(target: [*:0]const u16, typ: u32, flags: u32, cred: *?*CREDENTIALW) callconv(.winapi) BOOL;
    extern "advapi32" fn CredDeleteW(target: [*:0]const u16, typ: u32, flags: u32) callconv(.winapi) BOOL;
    extern "advapi32" fn CredFree(buf: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    fn target(buf: *[128]u16, name: []const u8) [*:0]const u16 {
        var i: usize = 0;
        for (service ++ ":") |c| {
            buf[i] = c;
            i += 1;
        }
        for (name) |c| {
            buf[i] = c;
            i += 1;
        }
        buf[i] = 0;
        return buf[0..i :0].ptr;
    }

    fn put(name: []const u8, value: []const u8) Error!void {
        var tb: [128]u16 = undefined;
        const cred: CREDENTIALW = .{
            .Type = CRED_TYPE_GENERIC,
            .TargetName = target(&tb, name),
            .CredentialBlobSize = @intCast(value.len),
            .CredentialBlob = value.ptr,
            .Persist = CRED_PERSIST_LOCAL_MACHINE,
        };
        if (CredWriteW(&cred, 0) == .FALSE) return error.StoreFailed;
    }

    fn get(gpa: std.mem.Allocator, name: []const u8) Error!?[]u8 {
        var tb: [128]u16 = undefined;
        var cred: ?*CREDENTIALW = null;
        if (CredReadW(target(&tb, name), CRED_TYPE_GENERIC, 0, &cred) == .FALSE) {
            if (GetLastError() == ERROR_NOT_FOUND) return null;
            return error.StoreFailed;
        }
        defer CredFree(cred.?);
        const c = cred.?;
        const out = try gpa.alloc(u8, c.CredentialBlobSize);
        if (c.CredentialBlobSize > 0) @memcpy(out, c.CredentialBlob.?[0..c.CredentialBlobSize]);
        return out;
    }

    fn remove(name: []const u8) Error!bool {
        var tb: [128]u16 = undefined;
        if (CredDeleteW(target(&tb, name), CRED_TYPE_GENERIC, 0) == .FALSE) {
            if (GetLastError() == ERROR_NOT_FOUND) return false;
            return error.StoreFailed;
        }
        return true;
    }
};

const t = std.testing;

test "the directory store keeps, replaces and removes values" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(path);
    const sub = try std.fs.path.join(t.allocator, &.{ path, "secrets" });
    defer t.allocator.free(sub);
    const s: Store = .{ .dir = sub };

    try t.expectEqual(null, try s.get(io, t.allocator, "gh"));
    try s.put(io, "gh", "first-value-123");
    try s.put(io, "gh", "second-value-456");
    const got = (try s.get(io, t.allocator, "gh")).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("second-value-456", got);

    if (!is_windows) {
        const st = try Io.Dir.cwd().statFile(io, sub, .{});
        try t.expectEqual(0o700, st.permissions.toMode() & 0o777);
        var d = try Io.Dir.cwd().openDir(io, sub, .{});
        defer d.close(io);
        const fst = try d.statFile(io, "gh", .{});
        try t.expectEqual(0o600, fst.permissions.toMode() & 0o777);
    }

    try t.expect(try s.remove(io, "gh"));
    try t.expect(!try s.remove(io, "gh"));
    try t.expectEqual(null, try s.get(io, t.allocator, "gh"));
}

//! Where secret values are kept: the macOS Keychain, the Windows
//! Credential Manager, or (elsewhere, and in tests) one file per secret in
//! a directory only the user can read. In the system's stores each data
//! folder has a namespace of its own (`namespace`), so one instance never
//! reads, replaces or removes another's secrets.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Error = error{
    StoreFailed,
    OutOfMemory,
    /// Longer than the store keeps (`maxValue`).
    ValueTooLong,
    /// Not a name the store can use (too long, or not printable ASCII).
    BadName,
};

/// The Credential Manager keeps at most this much of a value
/// (CRED_MAX_CREDENTIAL_BLOB_SIZE).
pub const wincred_max_value = 5 * 512;

pub const Store = union(enum) {
    /// A directory; each secret is a file in it, readable by the user only.
    dir: []const u8,
    /// The macOS Keychain; the namespace is the items' service.
    keychain: []const u8,
    /// The Windows Credential Manager; targets are "NAMESPACE:NAME".
    wincred: []const u8,

    pub fn describe(s: Store) []const u8 {
        return switch (s) {
            .dir => "a file per secret, readable only by you",
            .keychain => "the macOS Keychain",
            .wincred => "the Windows Credential Manager",
        };
    }

    /// The longest value it keeps, if it has a limit: 2560 bytes in the
    /// Credential Manager, 64 KiB in the directory store (what `get` reads).
    pub fn maxValue(s: Store) ?usize {
        return switch (s) {
            .dir => 64 * 1024,
            .keychain => null,
            .wincred => wincred_max_value,
        };
    }

    pub fn put(s: Store, io: Io, name: []const u8, value: []const u8) Error!void {
        if (s.maxValue()) |m| if (value.len > m) return error.ValueTooLong;
        switch (s) {
            .dir => |d| dirPut(io, d, name, value) catch return error.StoreFailed,
            .keychain => |ns| if (is_mac) try mac.put(ns, name, value) else unreachable,
            .wincred => |ns| if (is_windows) try win.put(ns, name, value) else unreachable,
        }
    }

    /// The value, or null if none is stored. Caller frees.
    pub fn get(s: Store, io: Io, gpa: std.mem.Allocator, name: []const u8) Error!?[]u8 {
        return switch (s) {
            .dir => |d| dirGet(io, gpa, d, name),
            .keychain => |ns| if (is_mac) mac.get(gpa, ns, name) else unreachable,
            .wincred => |ns| if (is_windows) win.get(gpa, ns, name) else unreachable,
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
            .keychain => |ns| if (is_mac) mac.remove(ns, name) else unreachable,
            .wincred => |ns| if (is_windows) win.remove(ns, name) else unreachable,
        };
    }
};

const is_mac = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

/// Where the secrets of the data folder `home` are kept on `os`:
/// HARNESS_STORE=DIR (`store_env`) as given; on macOS the Keychain and on
/// Windows the Credential Manager, under the folder's namespace
/// (`namespace`; `is_default`: the built-in folder); elsewhere a file per
/// secret in DATA/secrets.
pub fn forFolder(io: Io, a: std.mem.Allocator, os: std.Target.Os.Tag, store_env: ?[]const u8, home: []const u8, is_default: bool) !Store {
    if (store_env) |d| if (d.len > 0) return .{ .dir = d };
    return switch (os) {
        .macos => .{ .keychain = try namespace(io, a, home, is_default) },
        .windows => .{ .wincred = try namespace(io, a, home, is_default) },
        else => .{ .dir = try std.fs.path.join(a, &.{ home, "secrets" }) },
    };
}

/// For `harness init`, before it writes the folder's files: on macOS and
/// Windows the folder's namespace is made now, so a folder made by this
/// harness is never taken for one an earlier harness used.
pub fn claimNamespace(io: Io, a: std.mem.Allocator, os: std.Target.Os.Tag, home: []const u8, is_default: bool) !void {
    if (os == .macos or os == .windows) _ = try namespace(io, a, home, is_default);
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

/// Where every harness before this one kept every folder's secrets.
pub const legacy_namespace = "harness";

/// The namespace a data folder's secrets are kept under in the system's
/// store: "harness" for the built-in folder (`is_default`) and for any
/// folder an earlier harness used (it has settings or a log, but no
/// store-id), since every harness before this one kept all secrets there,
/// so they keep working; "harness-" and 16 random hex digits for a new
/// folder. Made once and kept in DATA/state/store-id: a folder moved or
/// copied keeps its secrets, two folders made apart never share them (init
/// makes the id before the folder's files: `claimNamespace`). A damaged id
/// is error.BadStoreId, never a guess.
pub fn namespace(io: Io, a: std.mem.Allocator, home: []const u8, is_default: bool) ![]const u8 {
    const state = try std.fs.path.join(a, &.{ home, "state" });
    const path = try std.fs.path.join(a, &.{ state, "store-id" });
    var tries: u32 = 0;
    while (tries < 20) : (tries += 1) {
        var buf: [64]u8 = undefined;
        if (Io.Dir.cwd().readFile(io, path, &buf)) |got| {
            const ns = std.mem.trim(u8, got, " \t\r\n");
            if (validNamespace(ns)) return a.dupe(u8, ns);
            if (ns.len > 0) return error.BadStoreId;
            // empty: being written by another harness right now, or left by
            // one that died before it wrote (so nothing was stored under it)
            if (tries >= 5) Io.Dir.cwd().deleteFile(io, path) catch {};
            io.sleep(.fromMilliseconds(20), .awake) catch {};
            continue;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        var made: [legacy_namespace.len + 1 + 16]u8 = undefined;
        const ns: []const u8 = if (is_default or usedBefore(io, a, home)) legacy_namespace else blk: {
            var raw: [8]u8 = undefined;
            try io.randomSecure(&raw);
            break :blk std.fmt.bufPrint(&made, "{s}-{s}", .{ legacy_namespace, &std.fmt.bytesToHex(raw, .lower) }) catch unreachable;
        };
        try Io.Dir.cwd().createDirPath(io, state);
        var f = Io.Dir.cwd().createFile(io, path, .{
            .exclusive = true,
            .permissions = if (is_windows) .default_file else .fromMode(0o600),
        }) catch |e| switch (e) {
            // another harness made it first: use that one
            error.PathAlreadyExists => continue,
            else => return e,
        };
        defer f.close(io);
        var line: [made.len + 1]u8 = undefined;
        try f.writeStreamingAll(io, std.fmt.bufPrint(&line, "{s}\n", .{ns}) catch unreachable);
        return a.dupe(u8, ns);
    }
    return error.BadStoreId;
}

/// Whether a harness used `home` before it had a store-id: it has the
/// settings init writes, or the log every start writes.
fn usedBefore(io: Io, a: std.mem.Allocator, home: []const u8) bool {
    for ([_][]const []const u8{ &.{ home, "config.ini" }, &.{ home, "log", "actions.jsonl" } }) |parts| {
        const p = std.fs.path.join(a, parts) catch return true;
        if (Io.Dir.cwd().access(io, p, .{})) |_| return true else |e| switch (e) {
            error.FileNotFound => {},
            // can't tell: the old namespace loses nothing that was stored
            else => return true,
        }
    }
    return false;
}

/// "harness", or "harness-" and 16 lowercase hex digits.
pub fn validNamespace(ns: []const u8) bool {
    if (std.mem.eql(u8, ns, legacy_namespace)) return true;
    const pre = legacy_namespace ++ "-";
    if (ns.len != pre.len + 16 or !std.mem.startsWith(u8, ns, pre)) return false;
    for (ns[pre.len..]) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

const mac = struct {
    const OSStatus = i32;
    const errSecItemNotFound: OSStatus = -25300;
    extern "Security" fn SecKeychainAddGenericPassword(keychain: ?*anyopaque, service_len: u32, service_name: [*]const u8, account_len: u32, account: [*]const u8, password_len: u32, password: [*]const u8, item: ?*?*anyopaque) OSStatus;
    extern "Security" fn SecKeychainFindGenericPassword(keychain: ?*anyopaque, service_len: u32, service_name: [*]const u8, account_len: u32, account: [*]const u8, password_len: ?*u32, password: ?*?[*]u8, item: ?*?*anyopaque) OSStatus;
    extern "Security" fn SecKeychainItemModifyAttributesAndData(item: *anyopaque, attrs: ?*anyopaque, len: u32, data: [*]const u8) OSStatus;
    extern "Security" fn SecKeychainItemFreeContent(attrs: ?*anyopaque, data: ?*anyopaque) OSStatus;
    extern "Security" fn SecKeychainItemDelete(item: *anyopaque) OSStatus;
    extern "CoreFoundation" fn CFRelease(cf: *anyopaque) void;

    fn find(service: []const u8, name: []const u8, item: ?*?*anyopaque, len: ?*u32, data: ?*?[*]u8) OSStatus {
        return SecKeychainFindGenericPassword(null, @intCast(service.len), service.ptr, @intCast(name.len), name.ptr, len, data, item);
    }

    fn put(service: []const u8, name: []const u8, value: []const u8) Error!void {
        var item: ?*anyopaque = null;
        const st = find(service, name, &item, null, null);
        if (st == 0) {
            defer CFRelease(item.?);
            if (SecKeychainItemModifyAttributesAndData(item.?, null, @intCast(value.len), value.ptr) != 0) return error.StoreFailed;
            return;
        }
        if (st != errSecItemNotFound) return error.StoreFailed;
        if (SecKeychainAddGenericPassword(null, @intCast(service.len), service.ptr, @intCast(name.len), name.ptr, @intCast(value.len), value.ptr, null) != 0) return error.StoreFailed;
    }

    fn get(gpa: std.mem.Allocator, service: []const u8, name: []const u8) Error!?[]u8 {
        var len: u32 = 0;
        var data: ?[*]u8 = null;
        const st = find(service, name, null, &len, &data);
        if (st == errSecItemNotFound) return null;
        if (st != 0) return error.StoreFailed;
        defer _ = SecKeychainItemFreeContent(null, data);
        const out = try gpa.alloc(u8, len);
        @memcpy(out, data.?[0..len]);
        return out;
    }

    fn remove(service: []const u8, name: []const u8) Error!bool {
        var item: ?*anyopaque = null;
        const st = find(service, name, &item, null, null);
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

    fn put(ns: []const u8, name: []const u8, value: []const u8) Error!void {
        var tb: [256]u16 = undefined;
        const cred: CREDENTIALW = .{
            .Type = CRED_TYPE_GENERIC,
            .TargetName = (try targetName(&tb, ns, name)).ptr,
            .CredentialBlobSize = @intCast(value.len),
            .CredentialBlob = value.ptr,
            .Persist = CRED_PERSIST_LOCAL_MACHINE,
        };
        if (CredWriteW(&cred, 0) == .FALSE) return error.StoreFailed;
    }

    fn get(gpa: std.mem.Allocator, ns: []const u8, name: []const u8) Error!?[]u8 {
        var tb: [256]u16 = undefined;
        var cred: ?*CREDENTIALW = null;
        if (CredReadW((try targetName(&tb, ns, name)).ptr, CRED_TYPE_GENERIC, 0, &cred) == .FALSE) {
            if (GetLastError() == ERROR_NOT_FOUND) return null;
            return error.StoreFailed;
        }
        defer CredFree(cred.?);
        const c = cred.?;
        const out = try gpa.alloc(u8, c.CredentialBlobSize);
        if (c.CredentialBlobSize > 0) @memcpy(out, c.CredentialBlob.?[0..c.CredentialBlobSize]);
        return out;
    }

    fn remove(ns: []const u8, name: []const u8) Error!bool {
        var tb: [256]u16 = undefined;
        if (CredDeleteW((try targetName(&tb, ns, name)).ptr, CRED_TYPE_GENERIC, 0) == .FALSE) {
            if (GetLastError() == ERROR_NOT_FOUND) return false;
            return error.StoreFailed;
        }
        return true;
    }
};

/// The Credential Manager's target for a secret, "NAMESPACE:NAME" (for
/// the default folder "harness:NAME", as before), in `buf`; a name that
/// doesn't fit, or isn't printable ASCII, is refused (mcp.ini's secret
/// names come straight from the file).
pub fn targetName(buf: []u16, ns: []const u8, name: []const u8) error{BadName}![:0]const u16 {
    if (name.len == 0 or ns.len + 1 + name.len + 1 > buf.len) return error.BadName;
    var i: usize = 0;
    for ([_][]const u8{ ns, ":", name }) |part| for (part) |c| {
        if (c < 0x21 or c > 0x7e) return error.BadName;
        buf[i] = c;
        i += 1;
    };
    buf[i] = 0;
    return buf[0..i :0];
}

const t = std.testing;

test "credential_manager_targets_are_bounded_and_values_capped" {
    var buf: [128]u16 = undefined;
    // the target an existing secret has (the Windows session may have stored some)
    const want = std.unicode.utf8ToUtf16LeStringLiteral("harness:omnigate");
    try t.expectEqualSlices(u16, want, try targetName(&buf, legacy_namespace, "omnigate"));
    // an mcp.ini secret name longer than the buffer is refused, not written past it
    const long: [200]u8 = @splat('x');
    try t.expectError(error.BadName, targetName(&buf, legacy_namespace, &long));
    try t.expectError(error.BadName, targetName(&buf, legacy_namespace, "caf\xc3\xa9"));
    // it keeps at most 2560 bytes of a value: a longer one is refused up
    // front, with a reason `secret add` can give
    const wc: Store = .{ .wincred = legacy_namespace };
    try t.expectEqual(2560, wc.maxValue().?);
    const big: [2561]u8 = @splat('v');
    try t.expectError(error.ValueTooLong, wc.put(t.io, "big", &big));
}

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

test "a_folder_from_before_namespaces_keeps_the_old_one_and_only_a_new_folder_gets_its_own" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    // made and used by a harness before namespaces: its settings, or its
    // log, and no state/store-id
    try tmp.dir.createDirPath(io, "old-settings");
    try tmp.dir.writeFile(io, .{ .sub_path = "old-settings/config.ini", .data = "[model]\n" });
    try tmp.dir.createDirPath(io, "old-log/log");
    try tmp.dir.writeFile(io, .{ .sub_path = "old-log/log/actions.jsonl", .data = "{}\n" });
    for ([_][]const u8{ "old-settings", "old-log" }) |name| {
        const home = try std.fs.path.join(a, &.{ root, name });
        // its secrets were stored under "harness": they keep being found
        try t.expectEqualStrings(legacy_namespace, try namespace(io, a, home, false));
        // and that is what it keeps from now on
        try t.expectEqualStrings("harness\n", try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ home, "state", "store-id" }), a, .limited(64)));
        try t.expectEqualStrings(legacy_namespace, try namespace(io, a, home, false));
    }
    // a folder not made yet, or still empty, gets one of its own
    try tmp.dir.createDirPath(io, "empty");
    for ([_][]const u8{ "new", "empty" }) |name| {
        const ns = try namespace(io, a, try std.fs.path.join(a, &.{ root, name }), false);
        try t.expect(validNamespace(ns));
        try t.expect(!std.mem.eql(u8, ns, legacy_namespace));
    }
}

test "init_makes_a_new_folders_namespace_before_its_files" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    // what init does: the namespace first, then the settings files
    const home = try std.fs.path.join(a, &.{ root, "made-by-init" });
    try claimNamespace(io, a, .macos, home, false);
    try Io.Dir.cwd().createDirPath(io, home);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ home, "config.ini" }), .data = "[model]\n" });
    // so with its settings in place it is still a new folder, not an old one
    const ns = try namespace(io, a, home, false);
    try t.expect(validNamespace(ns));
    try t.expect(!std.mem.eql(u8, ns, legacy_namespace));
    // where the system's store is not used, nothing is written
    const lin = try std.fs.path.join(a, &.{ root, "linux" });
    try claimNamespace(io, a, .linux, lin, false);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ lin, "state", "store-id" }), .{}));
}

test "the_store_a_folder_uses_and_the_names_its_secrets_get_there" {
    // only which store and under which names: the Keychain and the
    // Credential Manager themselves are never touched
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const def = try std.fs.path.join(a, &.{ root, "default" });
    const other = try std.fs.path.join(a, &.{ root, "other" });
    const old = try std.fs.path.join(a, &.{ root, "old" });
    try Io.Dir.cwd().createDirPath(io, old);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ old, "config.ini" }), .data = "[model]\n" });
    // HARNESS_STORE=DIR is used as given, on every system
    for ([_]std.Target.Os.Tag{ .macos, .windows, .linux }) |os| {
        const s = try forFolder(io, a, os, "/srv/harness-secrets", other, false);
        try t.expect(s == .dir);
        try t.expectEqualStrings("/srv/harness-secrets", s.dir);
    }
    // macOS: the Keychain, the folder's namespace as the items' service
    // (their account is the secret's name)
    const k_def = try forFolder(io, a, .macos, null, def, true);
    try t.expect(k_def == .keychain);
    try t.expectEqualStrings(legacy_namespace, k_def.keychain);
    const k_other = try forFolder(io, a, .macos, null, other, false);
    try t.expect(validNamespace(k_other.keychain));
    try t.expect(!std.mem.eql(u8, k_other.keychain, legacy_namespace));
    try t.expectEqualStrings(legacy_namespace, (try forFolder(io, a, .macos, null, old, false)).keychain);
    // Windows: the Credential Manager, targets NAMESPACE:NAME; the same
    // folder has the same namespace
    const w_other = try forFolder(io, a, .windows, null, other, false);
    try t.expect(w_other == .wincred);
    try t.expectEqualStrings(k_other.keychain, w_other.wincred);
    var buf: [256]u16 = undefined;
    const want = try std.unicode.utf8ToUtf16LeAlloc(a, try std.fmt.allocPrint(a, "{s}:login-bot-password", .{w_other.wincred}));
    try t.expectEqualSlices(u16, want, try targetName(&buf, w_other.wincred, "login-bot-password"));
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("harness:omnigate"), try targetName(&buf, (try forFolder(io, a, .windows, null, def, true)).wincred, "omnigate"));
    // elsewhere: a file per secret in DATA/secrets
    const l_other = try forFolder(io, a, .linux, null, other, false);
    try t.expect(l_other == .dir);
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ other, "secrets" }), l_other.dir);
}

test "each_data_folder_keeps_its_secrets_under_a_namespace_of_its_own" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const def = try std.fs.path.join(a, &.{ root, "default" });
    const one = try std.fs.path.join(a, &.{ root, "one" });
    const two = try std.fs.path.join(a, &.{ root, "two" });
    // the default folder keeps the secrets every harness stored so far
    try t.expectEqualStrings(legacy_namespace, try namespace(io, a, def, true));
    try t.expectEqualStrings(legacy_namespace, try namespace(io, a, def, true));
    // another folder gets one of its own, kept
    const n1 = try namespace(io, a, one, false);
    try t.expect(validNamespace(n1));
    try t.expect(!std.mem.eql(u8, n1, legacy_namespace));
    try t.expectEqualStrings(n1, try namespace(io, a, one, false));
    const n2 = try namespace(io, a, two, false);
    try t.expect(!std.mem.eql(u8, n1, n2));
    // a folder copied (or moved) keeps its secrets: the namespace is in it
    for ([_][2][]const u8{ .{ one, n1 }, .{ def, legacy_namespace } }, 0..) |pair, i| {
        const copy = try std.fs.path.join(a, &.{ root, if (i == 0) "copy-one" else "copy-default" });
        const id = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ pair[0], "state", "store-id" }), a, .limited(64));
        try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ copy, "state" }));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ copy, "state", "store-id" }), .data = id });
        try t.expectEqualStrings(pair[1], try namespace(io, a, copy, false));
    }
    // a damaged id is refused, not guessed
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ two, "state", "store-id" }), .data = "harness-../../x\n" });
    try t.expectError(error.BadStoreId, namespace(io, a, two, false));
    // what the system stores are given: the Keychain's service is the
    // namespace, the Credential Manager's target NAMESPACE:NAME
    var buf: [256]u16 = undefined;
    try t.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("harness:omnigate"), try targetName(&buf, legacy_namespace, "omnigate"));
    const want = try std.unicode.utf8ToUtf16LeAlloc(a, try std.fmt.allocPrint(a, "{s}:omnigate", .{n1}));
    try t.expectEqualSlices(u16, want, try targetName(&buf, n1, "omnigate"));
    const ks: Store = .{ .keychain = n1 };
    try t.expectEqualStrings(n1, ks.keychain);
}

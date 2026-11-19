//! The Windows side of sys.zig, on the Win32 API and Winsock.
//!
//! Sessions are reached over Unix-domain stream sockets, as on macOS and
//! Linux (Windows 10 version 1803 and later have them), so the protocol
//! and the session directory work the same way. Error names are part of
//! the command-line output, so they match the ones sys_posix.zig gives for
//! the same failure.

const std = @import("std");
const w = @import("win32.zig");

pub const pid_t = u32;

/// A handle with what it is: files and pipes are read with ReadFile,
/// sockets with recv, and events and processes can only be waited for.
pub const fd_t = struct {
    raw: usize,
    kind: Kind,

    pub const Kind = enum { file, socket, waitable };

    pub fn init(h: w.HANDLE, kind: Kind) fd_t {
        return .{ .raw = @intFromPtr(h), .kind = kind };
    }

    pub fn handle(fd: fd_t) w.HANDLE {
        return @ptrFromInt(fd.raw);
    }
};

/// Nothing to prepare: there is no SIGPIPE, a write to a closed pipe
/// fails with BrokenPipe by itself.
pub fn initProcess() void {}

pub fn exit(status: u8) noreturn {
    std.process.exit(status);
}

pub fn getpid() pid_t {
    return w.GetCurrentProcessId();
}

/// A copy of variable `name` in `buf`; null if it is unset or does not fit.
pub fn getenvBuf(buf: []u8, name: []const u8) ?[]const u8 {
    var name_buf: [64]u16 = undefined;
    const name_w = w.toWide(&name_buf, name) catch return null;
    var value: w.PathBuf = undefined;
    const n = w.GetEnvironmentVariableW(name_w, &value, value.len);
    if (n == 0 or n >= value.len) return null;
    return w.fromWide(buf, value[0..n]);
}

/// Sets variable `name` for this process and the programs it starts; null
/// removes it.
pub fn setEnv(name: []const u8, value: ?[]const u8) void {
    var name_buf: [64]u16 = undefined;
    const name_w = w.toWide(&name_buf, name) catch return;
    var value_buf: w.PathBuf = undefined;
    const value_w: ?[*:0]const u16 = if (value) |v| (w.toWide(&value_buf, v) catch return).ptr else null;
    _ = w.SetEnvironmentVariableW(name_w, value_w);
}

/// Wall-clock nanoseconds since the Unix epoch.
pub fn nanoTimestamp() i128 {
    var ft: w.FILETIME = undefined;
    w.GetSystemTimeAsFileTime(&ft);
    // FILETIME counts 100 ns steps from 1601-01-01.
    const ticks = (@as(i128, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return (ticks - 116_444_736_000_000_000) * 100;
}

/// Wall-clock milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

fn stdHandle(which: w.DWORD) fd_t {
    // Without a handle (a detached process), reads and writes just fail.
    return .init(w.GetStdHandle(which) orelse w.INVALID_HANDLE_VALUE, .file);
}

pub fn stdin() fd_t {
    return stdHandle(w.STD_INPUT_HANDLE);
}

pub fn stdout() fd_t {
    return stdHandle(w.STD_OUTPUT_HANDLE);
}

pub fn stderr() fd_t {
    return stdHandle(w.STD_ERROR_HANDLE);
}

pub fn close(fd: fd_t) void {
    switch (fd.kind) {
        .socket => _ = w.closesocket(fd.raw),
        .file, .waitable => _ = w.CloseHandle(fd.handle()),
    }
}

pub const ReadError = error{
    WouldBlock,
    NotOpenForReading,
    SocketNotConnected,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    Unexpected,
};

/// The most bytes one call transfers; the Win32 counts are 32 bits wide.
const max_rw_count = std.math.maxInt(i32);

/// Returns 0 at end of file.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;
    const len: u31 = @intCast(@min(buf.len, max_rw_count));
    switch (fd.kind) {
        .socket => {
            try awaitInput(fd.raw);
            const rc = w.recv(fd.raw, buf.ptr, len, 0);
            if (rc >= 0) return @intCast(rc);
            return switch (w.WSAGetLastError()) {
                w.Err.WSAEWOULDBLOCK => error.WouldBlock,
                w.Err.WSAECONNRESET, w.Err.WSAECONNABORTED => error.ConnectionResetByPeer,
                w.Err.WSAETIMEDOUT => error.ConnectionTimedOut,
                w.Err.WSAENOTCONN => error.SocketNotConnected,
                w.Err.WSAESHUTDOWN => 0,
                else => error.Unexpected,
            };
        },
        .file => {
            var n: w.DWORD = 0;
            if (w.ReadFile(fd.handle(), buf.ptr, len, &n, null) != 0) return n;
            return switch (w.GetLastError()) {
                // The writing side of the pipe is gone: that is its end.
                w.Err.BROKEN_PIPE, w.Err.HANDLE_EOF, w.Err.PIPE_NOT_CONNECTED => 0,
                w.Err.ACCESS_DENIED => error.NotOpenForReading,
                else => error.Unexpected,
            };
        },
        .waitable => return error.NotOpenForReading,
    }
}

/// Waits until `recv` on `s` will not block, or fails with
/// `ConnectionTimedOut` after the socket's receive timeout.
///
/// A `recv` that is already waiting when the other side closes a Unix
/// socket is sometimes never woken (seen on Windows 11 25H2 in about one
/// of fifty such closes), while `select` does see the close. So input is
/// waited for with `select`, and in short pieces, to be safe against a
/// wake-up lost there too.
fn awaitInput(s: w.SOCKET) error{ ConnectionTimedOut, Unexpected }!void {
    var limit_ms: w.DWORD = 0;
    var limit_len: c_int = @sizeOf(w.DWORD);
    _ = w.getsockopt(s, w.SOL_SOCKET, w.SO_RCVTIMEO, std.mem.asBytes(&limit_ms), &limit_len);
    const piece_ms = 100;
    var waited_ms: w.DWORD = 0;
    while (limit_ms == 0 or waited_ms < limit_ms) : (waited_ms += piece_ms) {
        var set: w.fd_set = .{};
        set.sockets[0] = s;
        set.count = 1;
        const rc = w.select(0, &set, null, null, &.{ .sec = 0, .usec = piece_ms * 1000 });
        if (rc > 0) return;
        if (rc < 0) return error.Unexpected;
    }
    return error.ConnectionTimedOut;
}

pub const WriteError = error{
    WouldBlock,
    NotOpenForWriting,
    NoSpaceLeft,
    BrokenPipe,
    ConnectionResetByPeer,
    Unexpected,
};

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    const len: u31 = @intCast(@min(bytes.len, max_rw_count));
    switch (fd.kind) {
        .socket => {
            const rc = w.send(fd.raw, bytes.ptr, len, 0);
            if (rc >= 0) return @intCast(rc);
            return switch (w.WSAGetLastError()) {
                w.Err.WSAEWOULDBLOCK => error.WouldBlock,
                w.Err.WSAECONNRESET, w.Err.WSAECONNABORTED => error.ConnectionResetByPeer,
                w.Err.WSAESHUTDOWN, w.Err.WSAENOTCONN => error.BrokenPipe,
                else => error.Unexpected,
            };
        },
        .file => {
            if (writeConsole(fd.handle(), bytes[0..len])) return len;
            var n: w.DWORD = 0;
            if (w.WriteFile(fd.handle(), bytes.ptr, len, &n, null) != 0) return n;
            return switch (w.GetLastError()) {
                w.Err.BROKEN_PIPE, w.Err.NO_DATA, w.Err.PIPE_NOT_CONNECTED => error.BrokenPipe,
                w.Err.ACCESS_DENIED => error.NotOpenForWriting,
                w.Err.DISK_FULL => error.NoSpaceLeft,
                else => error.Unexpected,
            };
        },
        .waitable => return error.NotOpenForWriting,
    }
}

/// Writes UTF-8 text to a console as UTF-16, so it shows correctly in any
/// code page. False if `h` is no console or `bytes` is not whole UTF-8
/// text; the bytes then go out unchanged.
fn writeConsole(h: w.HANDLE, bytes: []const u8) bool {
    var mode: w.DWORD = 0;
    if (w.GetConsoleMode(h, &mode) == 0) return false;
    var wide: [4096]u16 = undefined;
    var rest = bytes;
    if (!std.unicode.utf8ValidateSlice(rest)) return false;
    while (rest.len > 0) {
        // A piece that ends between two characters.
        var end = @min(rest.len, wide.len);
        while (end < rest.len and rest[end] & 0xC0 == 0x80) end -= 1;
        const n = std.unicode.wtf8ToWtf16Le(&wide, rest[0..end]) catch return false;
        if (w.WriteConsoleW(h, &wide, @intCast(n), null, null) == 0) return false;
        rest = rest[end..];
    }
    return true;
}

pub fn writeAll(fd: fd_t, bytes: []const u8) WriteError!void {
    var off: usize = 0;
    while (off < bytes.len) off += try write(fd, bytes[off..]);
}

pub const OpenError = error{
    NameTooLong,
    BadPathName,
    AccessDenied,
    FileNotFound,
    FileBusy,
    IsDir,
    Unexpected,
};

pub const WriteMode = enum { truncate, append };

/// Opens `path` for writing, creating it if it does not exist. The
/// permission bits of the other systems mean nothing here: the file gets
/// the access rights of its directory.
pub fn openForWrite(path: []const u8, mode: WriteMode, perm: u32) OpenError!fd_t {
    _ = perm;
    var path_buf: w.PathBuf = undefined;
    const path_w = try w.toWide(&path_buf, path);
    const h = w.CreateFileW(
        path_w,
        if (mode == .append) w.FILE_APPEND_DATA else w.GENERIC_WRITE,
        w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
        null,
        if (mode == .append) w.OPEN_ALWAYS else w.CREATE_ALWAYS,
        w.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h != w.INVALID_HANDLE_VALUE) return .init(h, .file);
    return switch (w.GetLastError()) {
        w.Err.FILE_NOT_FOUND, w.Err.PATH_NOT_FOUND => error.FileNotFound,
        // Creating a file over a directory is refused like this.
        w.Err.ACCESS_DENIED => if (isDir(path_w)) error.IsDir else error.AccessDenied,
        w.Err.SHARING_VIOLATION => error.FileBusy,
        w.Err.INVALID_NAME => error.BadPathName,
        else => error.Unexpected,
    };
}

fn isDir(path_w: [*:0]const u16) bool {
    const attrs = w.GetFileAttributesW(path_w);
    return attrs != w.INVALID_FILE_ATTRIBUTES and attrs & w.FILE_ATTRIBUTE_DIRECTORY != 0;
}

pub const UnlinkError = error{ NameTooLong, AccessDenied, FileBusy, FileNotFound, Unexpected };

pub fn unlink(path: []const u8) UnlinkError!void {
    var path_buf: w.PathBuf = undefined;
    if (w.DeleteFileW(try w.toWide(&path_buf, path)) != 0) return;
    return switch (w.GetLastError()) {
        w.Err.FILE_NOT_FOUND, w.Err.PATH_NOT_FOUND => error.FileNotFound,
        w.Err.ACCESS_DENIED => error.AccessDenied,
        w.Err.SHARING_VIOLATION => error.FileBusy,
        else => error.Unexpected,
    };
}

/// What to do about a socket path that is too long.
pub const session_dir_hint = "set XDG_RUNTIME_DIR to a shorter directory";

/// `%XDG_RUNTIME_DIR%\headterm` if that is set (as on the other systems),
/// else `%TEMP%\headterm`. The temporary directory belongs to one user, so
/// the name carries no user id. Not under `%LOCALAPPDATA%`: a program that
/// was installed as a package (and what it starts, such as an agent's
/// shell) gets a private copy of that directory, in which Unix sockets do
/// not work and which other programs do not see.
pub fn sessionDir(buf: []u8) ![]const u8 {
    var value: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "XDG_RUNTIME_DIR", "TEMP", "TMP" }) |name| {
        const base = std.mem.trimEnd(u8, getenvBuf(&value, name) orelse continue, "/\\");
        if (base.len > 0) return std.fmt.bufPrint(buf, "{s}\\headterm", .{base});
    }
    return error.NoSessionDirectory;
}

pub const DirError = error{ NameTooLong, NotADirectory, AccessDenied, FileNotFound, Unexpected };

/// Creates the session directory. It inherits the access rights of its
/// parent, which for the directories `sessionDir` picks is this user only.
pub fn ensureSessionDir(dir: []const u8) DirError!void {
    var path_buf: w.PathBuf = undefined;
    const dir_w = try w.toWide(&path_buf, dir);
    if (w.CreateDirectoryW(dir_w, null) != 0) return;
    return switch (w.GetLastError()) {
        w.Err.ALREADY_EXISTS => if (isDir(dir_w)) {} else error.NotADirectory,
        w.Err.PATH_NOT_FOUND => error.FileNotFound,
        w.Err.ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
}

// Unix-domain stream sockets.

pub const UnixAddressError = error{NameTooLong};

/// Fails if `path` does not fit `sun_path` with its terminating 0
/// (108 bytes).
pub fn unixAddress(path: []const u8) UnixAddressError!w.sockaddr_un {
    var addr: w.sockaddr_un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub const SocketError = error{ AddressFamilyNotSupported, ProcessFdQuotaExceeded, SystemResources, Unexpected };

var winsock_started = false;

fn unixSocket() SocketError!w.SOCKET {
    if (!winsock_started) {
        var data: [512]u8 = undefined;
        if (w.WSAStartup(0x0202, &data) != 0) return error.Unexpected;
        winsock_started = true;
    }
    const s = w.socket(w.AF_UNIX, w.SOCK_STREAM, 0);
    if (s != w.INVALID_SOCKET) return s;
    return switch (w.WSAGetLastError()) {
        // Windows before 10 version 1803.
        w.Err.WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
        w.Err.WSAEMFILE => error.ProcessFdQuotaExceeded,
        w.Err.WSAENOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

pub const ConnectError = SocketError || UnixAddressError || error{
    AccessDenied,
    ConnectionRefused,
    FileNotFound,
};

/// Connects to the socket at `path`. `ConnectionRefused` means the socket
/// file exists but nobody listens on it.
pub fn connectUnix(path: []const u8) ConnectError!fd_t {
    const addr = try unixAddress(path);
    const s = try unixSocket();
    errdefer _ = w.closesocket(s);
    if (w.connect(s, &addr, @sizeOf(w.sockaddr_un)) == 0) return .{ .raw = s, .kind = .socket };
    const err = w.WSAGetLastError();
    // A missing socket file is refused like a dead one.
    var path_buf: w.PathBuf = undefined;
    const path_w = w.toWide(&path_buf, path) catch return error.NameTooLong;
    if (w.GetFileAttributesW(path_w) == w.INVALID_FILE_ATTRIBUTES) return error.FileNotFound;
    return switch (err) {
        w.Err.WSAECONNREFUSED => error.ConnectionRefused,
        w.Err.WSAEACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

pub const ListenError = SocketError || UnixAddressError || error{
    AccessDenied,
    AddressInUse,
    FileNotFound,
};

/// Binds a new socket to `path` and listens on it. `AddressInUse` means
/// the path already exists.
pub fn listenUnix(path: []const u8) ListenError!fd_t {
    const addr = try unixAddress(path);
    const s = try unixSocket();
    errdefer _ = w.closesocket(s);
    if (w.bind(s, &addr, @sizeOf(w.sockaddr_un)) != 0) {
        return switch (w.WSAGetLastError()) {
            w.Err.WSAEADDRINUSE => error.AddressInUse,
            w.Err.WSAEACCES => error.AccessDenied,
            // The directory does not exist.
            w.Err.WSAENETDOWN, w.Err.WSAEINVAL => error.FileNotFound,
            else => error.Unexpected,
        };
    }
    if (w.listen(s, 128) != 0) return error.Unexpected;
    return .{ .raw = s, .kind = .socket };
}

pub const AcceptError = error{ WouldBlock, ConnectionAborted, SystemResources, Unexpected };

/// Accepts one connection.
pub fn accept(listen_fd: fd_t) AcceptError!fd_t {
    const s = w.accept(listen_fd.raw, null, null);
    if (s != w.INVALID_SOCKET) return .{ .raw = s, .kind = .socket };
    return switch (w.WSAGetLastError()) {
        w.Err.WSAEWOULDBLOCK => error.WouldBlock,
        w.Err.WSAECONNRESET => error.ConnectionAborted,
        w.Err.WSAEMFILE, w.Err.WSAENOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Gives up a blocking read on socket `fd` after `seconds`.
pub fn setReceiveTimeout(fd: fd_t, seconds: u31) void {
    const ms: w.DWORD = @as(w.DWORD, seconds) * 1000;
    _ = w.setsockopt(fd.raw, w.SOL_SOCKET, w.SO_RCVTIMEO, std.mem.asBytes(&ms), @sizeOf(w.DWORD));
}

// Waiting.

pub const PollError = error{ NetworkDown, SystemResources, Unexpected };

/// WaitForMultipleObjects takes no more handles than this.
pub const max_poll_items: ?usize = w.MAXIMUM_WAIT_OBJECTS;

/// One descriptor to wait on with `poll`.
pub const PollItem = struct {
    fd: fd_t,
    out: bool,
    readable: bool = false,
    writable: bool = false,
};

/// Waits for `fd` to have input, and with `out` also for room to write.
pub fn pollItem(fd: fd_t, out: bool) PollItem {
    return .{ .fd = fd, .out = out };
}

/// A read will not block: there is input, the other side is gone, or (for
/// an event or a process) it is signaled.
pub fn readable(item: PollItem) bool {
    return item.readable;
}

pub fn writable(item: PollItem) bool {
    return item.writable;
}

/// A pipe or a console that was not opened by this process cannot be
/// waited for with the rest; it is looked at this often instead.
const peek_interval_ms = 20;

/// Waits until one of `items` is ready, for at most `timeout_ms`
/// milliseconds (-1: no limit). Writes never wait on Windows, so an item
/// with `out` is ready at once.
pub fn poll(items: []PollItem, timeout_ms: i32) PollError!void {
    var handles: [w.MAXIMUM_WAIT_OBJECTS]w.HANDLE = undefined;
    var owners: [w.MAXIMUM_WAIT_OBJECTS]usize = undefined;
    var count: usize = 0;
    // A socket becomes waitable through an event that lives for this call.
    defer for (handles[0..count], owners[0..count]) |h, i| {
        if (items[i].fd.kind == .socket) releaseSocketEvent(items[i].fd.raw, h);
    };

    var ready = false;
    var peeking = false;
    for (items, 0..) |*item, i| {
        item.readable = false;
        item.writable = item.out;
        if (item.out) ready = true;
        switch (item.fd.kind) {
            .file => peeking = true,
            .socket, .waitable => {
                if (count == handles.len) return error.SystemResources;
                handles[count] = if (item.fd.kind == .socket) try socketEvent(item.fd.raw) else item.fd.handle();
                owners[count] = i;
                count += 1;
            },
        }
    }

    const deadline: ?i64 = if (timeout_ms < 0) null else milliTimestamp() + timeout_ms;
    while (true) {
        if (peeking) {
            for (items) |*item| {
                if (item.fd.kind == .file and fileHasInput(item.fd.handle())) {
                    item.readable = true;
                    ready = true;
                }
            }
        }
        var wait_ms: w.DWORD = w.INFINITE;
        if (deadline) |d| wait_ms = @intCast(std.math.clamp(d - milliTimestamp(), 0, std.math.maxInt(i32)));
        if (peeking) wait_ms = @min(wait_ms, peek_interval_ms);
        if (ready) wait_ms = 0;
        if (count == 0) {
            w.Sleep(wait_ms);
        } else switch (w.WaitForMultipleObjects(@intCast(count), &handles, 0, wait_ms)) {
            w.WAIT_TIMEOUT => {},
            w.WAIT_FAILED => return error.Unexpected,
            // One is signaled; look at each, as more than one may be.
            else => for (handles[0..count], owners[0..count]) |h, i| {
                if (w.WaitForSingleObject(h, 0) == w.WAIT_OBJECT_0) {
                    items[i].readable = true;
                    ready = true;
                }
            },
        }
        if (ready) return;
        if (deadline) |d| if (milliTimestamp() >= d) return;
    }
}

fn socketEvent(s: w.SOCKET) PollError!w.HANDLE {
    const event = w.WSACreateEvent() orelse return error.SystemResources;
    // Selecting reports what is already there: waiting input, a pending
    // connection or a closed peer.
    if (w.WSAEventSelect(s, event, w.FD_READ | w.FD_ACCEPT | w.FD_CLOSE) != 0) {
        _ = w.CloseHandle(event);
        return error.Unexpected;
    }
    return event;
}

/// Undoes `socketEvent`: selecting also made the socket non-blocking.
fn releaseSocketEvent(s: w.SOCKET, event: w.HANDLE) void {
    _ = w.WSAEventSelect(s, null, 0);
    var blocking: c_ulong = 0;
    _ = w.ioctlsocket(s, w.FIONBIO, &blocking);
    _ = w.CloseHandle(event);
}

fn fileHasInput(h: w.HANDLE) bool {
    switch (w.GetFileType(h)) {
        w.FILE_TYPE_PIPE => {
            var avail: w.DWORD = 0;
            // A broken pipe counts: reading it gives the end of input.
            return w.PeekNamedPipe(h, null, 0, null, &avail, null) == 0 or avail > 0;
        },
        w.FILE_TYPE_CHAR => return w.WaitForSingleObject(h, 0) == w.WAIT_OBJECT_0,
        else => return true,
    }
}

fn testPath(buf: []u8, name: []const u8) ![]const u8 {
    var tmp: [200]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}\\headterm-sys-{d}-{s}", .{ getenvBuf(&tmp, "TEMP") orelse return error.SkipZigTest, getpid(), name });
}

test "unix sockets: listen, connect, accept, path limit" {
    var path_buf: [300]u8 = undefined;
    const path = try testPath(&path_buf, "a.sock");
    unlink(path) catch {};
    const listener = try listenUnix(path);
    defer unlink(path) catch {};
    try std.testing.expectError(error.AddressInUse, listenUnix(path));

    const client = try connectUnix(path);
    defer close(client);
    const served = try accept(listener);
    defer close(served);
    try writeAll(client, "hi");
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("hi", buf[0..try read(served, &buf)]);

    // A socket file nobody listens on refuses; a missing one is not found.
    close(listener);
    try std.testing.expectError(error.ConnectionRefused, connectUnix(path));
    var missing_buf: [300]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, connectUnix(try testPath(&missing_buf, "missing.sock")));

    const long: [115]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, connectUnix(&long));
    try std.testing.expectError(error.NameTooLong, listenUnix(&long));
}

test "poll: sockets, timeouts, and a socket stays blocking afterwards" {
    var path_buf: [300]u8 = undefined;
    const path = try testPath(&path_buf, "p.sock");
    unlink(path) catch {};
    const listener = try listenUnix(path);
    defer close(listener);
    defer unlink(path) catch {};

    var items = [_]PollItem{pollItem(listener, false)};
    const t0 = milliTimestamp();
    try poll(&items, 50);
    try std.testing.expect(!readable(items[0]));
    try std.testing.expect(milliTimestamp() - t0 >= 40);

    const client = try connectUnix(path);
    try poll(&items, 1000);
    try std.testing.expect(readable(items[0]));
    const served = try accept(listener);
    defer close(served);

    // Input that arrived before the wait began, and room to write.
    try writeAll(client, "x");
    var both = [_]PollItem{ pollItem(listener, false), pollItem(served, true) };
    try poll(&both, 1000);
    try std.testing.expect(!readable(both[0]));
    try std.testing.expect(readable(both[1]) and writable(both[1]));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(1, try read(served, &buf));

    // A peer that is gone reads as the end of input, not as a timeout.
    setReceiveTimeout(served, 1);
    close(client);
    var one = [_]PollItem{pollItem(served, false)};
    try poll(&one, 1000);
    try std.testing.expect(readable(one[0]));
    try std.testing.expectEqual(0, read(served, &buf) catch 0);
}

test "poll: a pipe is looked at, an event is waited for" {
    var pipe_read: w.HANDLE = undefined;
    var pipe_write: w.HANDLE = undefined;
    try std.testing.expect(w.CreatePipe(&pipe_read, &pipe_write, null, 0) != 0);
    const reader: fd_t = .init(pipe_read, .file);
    const writer: fd_t = .init(pipe_write, .file);
    defer close(reader);

    const event: fd_t = .init(w.CreateEventW(null, 1, 0, null).?, .waitable);
    defer close(event);
    var items = [_]PollItem{ pollItem(reader, false), pollItem(event, false) };
    try poll(&items, 30);
    try std.testing.expect(!readable(items[0]) and !readable(items[1]));

    try writeAll(writer, "ab");
    try poll(&items, 1000);
    try std.testing.expect(readable(items[0]) and !readable(items[1]));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(2, try read(reader, &buf));

    close(writer);
    try poll(&items, 1000);
    try std.testing.expect(readable(items[0]));
    try std.testing.expectEqual(0, try read(reader, &buf));
}

test "openForWrite truncates or appends; unlink" {
    var path_buf: [300]u8 = undefined;
    const path = try testPath(&path_buf, "f.txt");
    defer unlink(path) catch {};
    for ([_]WriteMode{ .truncate, .append, .append }) |mode| {
        const fd = try openForWrite(path, mode, 0o600);
        defer close(fd);
        try writeAll(fd, "ab");
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("ababab", data);

    var missing_buf: [300]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, unlink(try testPath(&missing_buf, "missing")));
    try std.testing.expectError(error.FileNotFound, openForWrite(try testPath(&missing_buf, "no-dir\\x"), .append, 0o600));
}

test "environment and session directory" {
    var old_buf: [300]u8 = undefined;
    const old = getenvBuf(&old_buf, "XDG_RUNTIME_DIR");
    defer setEnv("XDG_RUNTIME_DIR", old);

    setEnv("XDG_RUNTIME_DIR", "C:\\some dir\\");
    var buf: [300]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\some dir\\headterm", try sessionDir(&buf));
    setEnv("XDG_RUNTIME_DIR", null);
    try std.testing.expect(getenvBuf(&buf, "XDG_RUNTIME_DIR") == null);
    try std.testing.expect(std.mem.endsWith(u8, try sessionDir(&buf), "\\headterm"));
}

test "timestamps are wall-clock" {
    const ms = milliTimestamp();
    try std.testing.expect(ms > 1_600_000_000_000);
    const ns_as_ms: i64 = @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
    try std.testing.expect(ns_as_ms >= ms and ns_as_ms - ms < 1000);
}

test {
    _ = w;
}

//! The libc calls headterm makes directly, with errno mapped to errors.
//!
//! The session server is a forked daemon and the program it starts is a
//! forked child, so these paths cannot go through `std.Io`: after `fork`
//! only the calling thread exists and only plain system calls are safe.
//! The client side uses the same wrappers for the descriptors it shares
//! with `poll`. Error names are part of the command-line output (they end
//! up in messages such as `exec foo: FileNotFound`), so each mapping is
//! spelled out here.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

const is_linux = builtin.os.tag == .linux;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const uid_t = posix.uid_t;
pub const mode_t = posix.mode_t;
pub const O = posix.O;

pub fn close(fd: fd_t) void {
    // EINTR still closes the descriptor; nothing else is actionable.
    _ = c.close(fd);
}

/// The largest count one `read` or `write` accepts.
const max_rw_count = switch (builtin.os.tag) {
    .linux => 0x7ffff000,
    .macos => std.math.maxInt(i32),
    else => std.math.maxInt(isize),
};

pub const ReadError = error{
    WouldBlock,
    Canceled,
    NotOpenForReading,
    InputOutput,
    IsDir,
    SystemResources,
    SocketNotConnected,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    ProcessNotFound,
    Unexpected,
};

/// Returns 0 at end of file.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;
    while (true) {
        const rc = c.read(fd, buf.ptr, @min(buf.len, max_rw_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => return error.Unexpected,
        }
    }
}

pub const WriteError = error{
    InvalidArgument,
    ProcessNotFound,
    WouldBlock,
    NotOpenForWriting,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    DeviceBusy,
    NoDevice,
    MessageTooBig,
    Unexpected,
};

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    while (true) {
        const rc = c.write(fd, bytes.ptr, @min(bytes.len, max_rw_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            else => return error.Unexpected,
        }
    }
}

pub fn writeAll(fd: fd_t, bytes: []const u8) WriteError!void {
    var off: usize = 0;
    while (off < bytes.len) off += try write(fd, bytes[off..]);
}

pub const OpenError = error{
    BadPathName,
    AccessDenied,
    FileTooBig,
    IsDir,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    NameTooLong,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,
    ProcessNotFound,
    SystemResources,
    NoSpaceLeft,
    NotDir,
    PermissionDenied,
    PathAlreadyExists,
    DeviceBusy,
    Unexpected,
};

pub fn open(path: []const u8, flags: O, mode: mode_t) OpenError!fd_t {
    const path_z = try posix.toPosixPath(path);
    return openZ(&path_z, flags, mode);
}

pub fn openZ(path: [*:0]const u8, flags: O, mode: mode_t) OpenError!fd_t {
    while (true) {
        const rc = c.open(path, flags, @as(c_uint, mode));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            else => return error.Unexpected,
        }
    }
}

pub const MakeDirError = error{
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    NotDir,
    ReadOnlyFileSystem,
    Unexpected,
};

pub fn mkdir(path: []const u8, mode: mode_t) MakeDirError!void {
    const path_z = try posix.toPosixPath(path);
    switch (posix.errno(c.mkdir(&path_z, mode))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .DQUOT => return error.DiskQuota,
        .EXIST => return error.PathAlreadyExists,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        else => return error.Unexpected,
    }
}

pub const UnlinkError = error{
    AccessDenied,
    PermissionDenied,
    FileBusy,
    FileSystem,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,
    Unexpected,
};

pub fn unlink(path: []const u8) UnlinkError!void {
    const path_z = try posix.toPosixPath(path);
    switch (posix.errno(c.unlink(&path_z))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY => return error.FileBusy,
        .IO => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .ROFS => return error.ReadOnlyFileSystem,
        else => return error.Unexpected,
    }
}

pub const Owner = struct {
    uid: uid_t,
    /// File type and permission bits.
    mode: u32,
};

pub const FStatError = error{ SystemResources, AccessDenied, Unexpected };

/// Owner and mode of an open file. Linux has no stable `struct stat` across
/// libcs and architectures, so it is asked with `statx`.
pub fn fstatOwner(fd: fd_t) FStatError!Owner {
    if (is_linux) {
        const linux = std.os.linux;
        var stx = std.mem.zeroes(linux.Statx);
        while (true) {
            switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &stx))) {
                .SUCCESS => return .{ .uid = stx.uid, .mode = stx.mode },
                .INTR => continue,
                .NOMEM => return error.SystemResources,
                .ACCES => return error.AccessDenied,
                else => return error.Unexpected,
            }
        }
    }
    var st: c.Stat = undefined;
    switch (posix.errno(c.fstat(fd, &st))) {
        .SUCCESS => return .{ .uid = st.uid, .mode = st.mode },
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        else => return error.Unexpected,
    }
}

pub const FChmodError = error{
    AccessDenied,
    InputOutput,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    PermissionDenied,
    ReadOnlyFileSystem,
    Unexpected,
};

pub fn fchmod(fd: fd_t, mode: mode_t) FChmodError!void {
    while (true) {
        switch (posix.errno(c.fchmod(fd, mode))) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .IO => return error.InputOutput,
            .LOOP => return error.SymLinkLoop,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.FileNotFound,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.Unexpected,
        }
    }
}

/// The live environment: unlike `std.process.Init.environ_map` it sees
/// later `setenv` calls.
pub fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return std.mem.span(c.getenv(name) orelse return null);
}

pub fn getuid() uid_t {
    return c.getuid();
}

pub fn getpid() pid_t {
    return c.getpid();
}

/// Flushes stdio and runs `atexit` handlers, like returning from `main`.
pub fn exit(status: u8) noreturn {
    c.exit(status);
}

fn setCloexecRaw(fd: fd_t) c_int {
    return c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
}

pub fn setCloexec(fd: fd_t) void {
    _ = setCloexecRaw(fd);
}

/// Replaces the file status flags with `O_NONBLOCK`.
pub fn setNonblock(fd: fd_t) error{Unexpected}!void {
    const flags: u32 = @bitCast(O{ .NONBLOCK = true });
    while (true) {
        switch (posix.errno(c.fcntl(fd, posix.F.SETFL, @as(c_int, @bitCast(flags))))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

pub const PipeError = error{ SystemFdQuotaExceeded, ProcessFdQuotaExceeded, Unexpected };

pub const PipeFlags = struct {
    cloexec: bool = false,
    nonblock: bool = false,
};

/// A pipe as `[read end, write end]`. macOS has no `pipe2`, so there the
/// flags are set with `fcntl` after the fact.
pub fn pipe2(flags: PipeFlags) PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (@TypeOf(c.pipe2) != void) {
        switch (posix.errno(c.pipe2(&fds, .{ .CLOEXEC = flags.cloexec, .NONBLOCK = flags.nonblock }))) {
            .SUCCESS => return fds,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
    switch (posix.errno(c.pipe(&fds))) {
        .SUCCESS => {},
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => return error.Unexpected,
    }
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    for (fds) |fd| {
        if (flags.cloexec and setCloexecRaw(fd) != 0) return error.Unexpected;
        if (flags.nonblock) try setNonblock(fd);
    }
    return fds;
}

pub const ForkError = error{ SystemResources, Unexpected };

/// Returns 0 in the child. The child must restrict itself to
/// async-signal-safe calls if the parent had other threads.
pub fn fork() ForkError!pid_t {
    const rc = c.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

pub fn setsid() void {
    _ = c.setsid();
}

pub const Dup2Error = error{ ProcessFdQuotaExceeded, Unexpected };

pub fn dup2(old_fd: fd_t, new_fd: fd_t) Dup2Error!void {
    while (true) {
        switch (posix.errno(c.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .BUSY, .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

pub const WaitPidResult = struct {
    /// 0 when `W.NOHANG` was given and the child has not changed state.
    pid: pid_t,
    status: u32,
};

/// Only for children this process forked itself and has not reaped yet.
pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, @intCast(flags));
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .pid = @intCast(rc), .status = @bitCast(status) },
            .INTR => continue,
            else => unreachable,
        }
    }
}

pub const ExecError = error{
    SystemResources,
    AccessDenied,
    PermissionDenied,
    InvalidExe,
    FileSystem,
    IsDir,
    FileNotFound,
    NotDir,
    FileBusy,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NameTooLong,
    Unexpected,
};

/// Returns only on failure. Does not search PATH.
pub fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError {
    switch (posix.errno(c.execve(path, argv, envp))) {
        .@"2BIG" => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .INVAL => return error.InvalidExe,
        .NOEXEC => return error.InvalidExe,
        .IO => return error.FileSystem,
        .LOOP => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .TXTBSY => return error.FileBusy,
        else => |err| switch (builtin.os.tag) {
            .macos => switch (err) {
                .BADEXEC, .BADARCH => return error.InvalidExe,
                else => return error.Unexpected,
            },
            .linux => switch (err) {
                .LIBBAD => return error.InvalidExe,
                else => return error.Unexpected,
            },
            else => return error.Unexpected,
        },
    }
}

/// Returns only on failure. A `file` without a slash is looked up in each
/// directory of `$PATH`; the error of the last attempt is returned, or
/// `AccessDenied` if any candidate existed but could not be executed.
/// Uses no heap, so it is safe between `fork` and exec.
pub fn execvpe(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError {
    const file_slice = std.mem.sliceTo(file, 0);
    if (std.mem.findScalar(u8, file_slice, '/') != null) return execve(file, argv, envp);

    const PATH: []const u8 = getenv("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, ':');
    var seen_eacces = false;
    var err: ExecError = error.FileNotFound;
    while (it.next()) |search_path| {
        const path_len = search_path.len + file_slice.len + 1;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = '/';
        @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
        path_buf[path_len] = 0;
        err = execve(path_buf[0..path_len :0].ptr, argv, envp);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }
    if (seen_eacces) return error.AccessDenied;
    return err;
}

/// Wall-clock nanoseconds since the Unix epoch; 0 if the clock is unreadable.
pub fn nanoTimestamp() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Wall-clock milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

// Unix-domain stream sockets.

pub const UnixAddressError = error{NameTooLong};

/// Fails if `path` does not fit `sun_path` with its terminating 0
/// (104 bytes on macOS, 108 on Linux).
pub fn unixAddress(path: []const u8) UnixAddressError!posix.sockaddr.un {
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    Unexpected,
};

/// A close-on-exec Unix stream socket. macOS has no `SOCK_CLOEXEC`.
fn unixSocket() SocketError!fd_t {
    const have_sock_flags = is_linux;
    const sock_type: c_uint = if (have_sock_flags) posix.SOCK.STREAM | posix.SOCK.CLOEXEC else posix.SOCK.STREAM;
    const rc = c.socket(posix.AF.UNIX, sock_type, 0);
    switch (posix.errno(rc)) {
        .SUCCESS => {
            const fd: fd_t = @intCast(rc);
            if (!have_sock_flags) setCloexec(fd);
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => return error.Unexpected,
    }
}

pub const ConnectError = SocketError || UnixAddressError || error{
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    WouldBlock,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    NetworkUnreachable,
    ConnectionTimedOut,
    FileNotFound,
};

/// Connects to the socket at `path`. `ConnectionRefused` means the socket
/// file exists but nobody listens on it.
pub fn connectUnix(path: []const u8) ConnectError!fd_t {
    const fd = try unixSocket();
    errdefer close(fd);
    const addr = try unixAddress(path);
    while (true) {
        switch (posix.errno(c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)))) {
            .SUCCESS => return fd,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            else => return error.Unexpected,
        }
    }
}

pub const ListenError = SocketError || UnixAddressError || error{
    AddressInUse,
    AddressNotAvailable,
    SymLinkLoop,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    FileDescriptorNotASocket,
    OperationNotSupported,
};

/// Binds a new socket to `path` and listens on it. `AddressInUse` means
/// the path already exists.
pub fn listenUnix(path: []const u8) ListenError!fd_t {
    const addr = try unixAddress(path);
    const fd = try unixSocket();
    errdefer close(fd);
    switch (posix.errno(c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)))) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        else => return error.Unexpected,
    }
    switch (posix.errno(c.listen(fd, 128))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => return error.Unexpected,
    }
    return fd;
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    SocketNotListening,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolFailure,
    BlockedByFirewall,
    Unexpected,
};

/// Accepts one connection as a close-on-exec descriptor. macOS has no
/// `accept4`.
pub fn accept(listen_fd: fd_t) AcceptError!fd_t {
    const have_accept4 = is_linux;
    while (true) {
        const rc = if (have_accept4)
            c.accept4(listen_fd, null, null, posix.SOCK.CLOEXEC)
        else
            c.accept(listen_fd, null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: fd_t = @intCast(rc);
                if (!have_accept4) setCloexec(fd);
                return fd;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => return error.Unexpected,
        }
    }
}

test "pipe2 sets the requested flags" {
    const fds = try pipe2(.{ .cloexec = true, .nonblock = true });
    defer close(fds[0]);
    defer close(fds[1]);
    for (fds) |fd| {
        try std.testing.expect(c.fcntl(fd, posix.F.GETFD) & posix.FD_CLOEXEC != 0);
        const nonblock: u32 = @bitCast(O{ .NONBLOCK = true });
        try std.testing.expect(@as(u32, @bitCast(c.fcntl(fd, posix.F.GETFL))) & nonblock != 0);
    }
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, read(fds[0], &buf));
    try writeAll(fds[1], "ab");
    try std.testing.expectEqual(2, try read(fds[0], &buf));
}

test "unix sockets: listen, connect, accept, path limit" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/headterm-sys-{d}.sock", .{getpid()});
    unlink(path) catch {};
    const listener = try listenUnix(path);
    defer unlink(path) catch {};
    try std.testing.expectError(error.AddressInUse, listenUnix(path));

    const client = try connectUnix(path);
    defer close(client);
    const served = try accept(listener);
    defer close(served);
    try std.testing.expect(c.fcntl(served, posix.F.GETFD) & posix.FD_CLOEXEC != 0);
    try writeAll(client, "hi");
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("hi", buf[0..try read(served, &buf)]);

    // A socket file nobody listens on refuses; a missing one is not found.
    close(listener);
    try std.testing.expectError(error.ConnectionRefused, connectUnix(path));
    try std.testing.expectError(error.FileNotFound, connectUnix("/tmp/headterm-sys-missing.sock"));

    var long: [115]u8 = @splat('x');
    long[0..5].* = "/tmp/".*;
    try std.testing.expectError(error.NameTooLong, connectUnix(&long));
    try std.testing.expectError(error.NameTooLong, listenUnix(&long));
}

test "mkdir, fstatOwner and fchmod on a directory" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/headterm-sys-{d}.d", .{getpid()});
    try mkdir(path, 0o755);
    defer _ = c.rmdir(&(posix.toPosixPath(path) catch unreachable));
    try std.testing.expectError(error.PathAlreadyExists, mkdir(path, 0o755));

    const fd = try open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer close(fd);
    try std.testing.expectEqual(getuid(), (try fstatOwner(fd)).uid);
    try fchmod(fd, 0o700);
    try std.testing.expectEqual(0o700, (try fstatOwner(fd)).mode & 0o777);
    try fchmod(fd, 0o750);
    try std.testing.expectEqual(0o750, (try fstatOwner(fd)).mode & 0o777);

    try std.testing.expectError(error.FileNotFound, open("/tmp/headterm-sys-missing/x", .{ .ACCMODE = .RDONLY }, 0));
}

test "timestamps are wall-clock" {
    const ms = milliTimestamp();
    try std.testing.expect(ms > 1_600_000_000_000);
    const ns_as_ms: i64 = @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
    try std.testing.expect(ns_as_ms >= ms and ns_as_ms - ms < 1000);
}

//! The Linux system calls headdesk makes, with errno mapped to errors. No
//! libc: everything goes through std.os.linux.
const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;
pub const pid_t = linux.pid_t;

pub const Error = error{ WouldBlock, Closed, NotFound, Exists, AddressInUse, Refused, TooLong, NoMemory, Interrupted, System };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .PIPE, .CONNRESET => error.Closed,
        .NOENT => error.NotFound,
        .EXIST => error.Exists,
        .ADDRINUSE => error.AddressInUse,
        .CONNREFUSED => error.Refused,
        .NAMETOOLONG => error.TooLong,
        .NOMEM => error.NoMemory,
        else => error.System,
    };
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// Milliseconds on the monotonic clock.
pub fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Microseconds on the realtime clock (for the event log).
pub fn wallMicros() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    while (true) {
        return check(linux.write(fd, bytes.ptr, bytes.len)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => |e| return e,
        };
    }
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var done: usize = 0;
    while (done < bytes.len) {
        done += write(fd, bytes[done..]) catch |err| switch (err) {
            error.WouldBlock => {
                var p = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT }};
                _ = linux.poll(&p, 1, 1000);
                continue;
            },
            else => |e| return e,
        };
    }
}

/// Bytes read; 0 at the end of the stream.
pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        return check(linux.read(fd, buf.ptr, buf.len)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => |e| return e,
        };
    }
}

pub fn unlink(path: [:0]const u8) void {
    _ = linux.unlink(path.ptr);
}

/// Creates `path` with mode 0700 if it is not there.
pub fn mkdir(path: [:0]const u8) Error!void {
    _ = check(linux.mkdir(path.ptr, 0o700)) catch |err| switch (err) {
        error.Exists => return,
        else => |e| return e,
    };
}

pub fn openRead(path: [:0]const u8) Error!fd_t {
    return @intCast(try check(linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)));
}

/// Opens `path` for writing from the start, creating it.
pub fn create(path: [:0]const u8) Error!fd_t {
    return @intCast(try check(linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644)));
}

/// Opens `path` for appending, creating it.
pub fn openAppend(path: [:0]const u8) Error!fd_t {
    return @intCast(try check(linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644)));
}

fn unixAddr(path: []const u8) Error!linux.sockaddr.un {
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= addr.path.len) return error.TooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// A listening Unix stream socket at `path` (an old socket file there is
/// replaced), non-blocking.
pub fn listenUnix(path: []const u8) Error!fd_t {
    const addr = try unixAddr(path);
    const fd: fd_t = @intCast(try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer close(fd);
    _ = linux.unlink(@ptrCast(&addr.path));
    _ = try check(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    _ = try check(linux.listen(fd, 16));
    return fd;
}

/// A connected Unix stream socket, blocking.
pub fn connectUnix(path: []const u8) Error!fd_t {
    const addr = try unixAddr(path);
    const fd: fd_t = @intCast(try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer close(fd);
    _ = try check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    return fd;
}

/// The next waiting connection, non-blocking; null when there is none.
pub fn accept(fd: fd_t) ?fd_t {
    const rc = check(linux.accept4(fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK)) catch return null;
    return @intCast(rc);
}

pub const max_fds = 28;
const cmsg_space = cmsgSpace(max_fds * @sizeOf(fd_t));

fn cmsgAlign(n: usize) usize {
    return (n + linux.cmsg_align - 1) & ~@as(usize, linux.cmsg_align - 1);
}

fn cmsgSpace(comptime n: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(n);
}

pub const Received = struct { bytes: usize, fds: usize };

/// Reads bytes and any file descriptors passed with them. `bytes == 0`
/// means the peer closed.
pub fn recvWithFds(fd: fd_t, buf: []u8, fds: []fd_t) Error!Received {
    var control: [cmsg_space]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const n = while (true) {
        break check(linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => |e| return e,
        };
    };
    var got: usize = 0;
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
        const hdr: *const linux.cmsghdr = @ptrCast(@alignCast(&control[off]));
        if (hdr.len < @sizeOf(linux.cmsghdr)) break;
        if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
            const data = control[off + cmsgAlign(@sizeOf(linux.cmsghdr)) .. off + hdr.len];
            var i: usize = 0;
            while (i + @sizeOf(fd_t) <= data.len) : (i += @sizeOf(fd_t)) {
                const one = std.mem.readInt(fd_t, data[i..][0..@sizeOf(fd_t)], .native);
                if (got < fds.len) {
                    fds[got] = one;
                    got += 1;
                } else close(one);
            }
        }
        off += cmsgAlign(hdr.len);
    }
    return .{ .bytes = n, .fds = got };
}

/// Sends all of `bytes`, with `fds` attached to the first byte.
pub fn sendWithFds(fd: fd_t, bytes: []const u8, fds: []const fd_t) Error!void {
    if (fds.len == 0) return writeAll(fd, bytes);
    var control: [cmsg_space]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    @memset(&control, 0);
    const data_len = fds.len * @sizeOf(fd_t);
    const hdr: *linux.cmsghdr = @ptrCast(&control);
    hdr.* = .{ .len = cmsgAlign(@sizeOf(linux.cmsghdr)) + data_len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    @memcpy(control[cmsgAlign(@sizeOf(linux.cmsghdr))..][0..data_len], std.mem.sliceAsBytes(fds));
    var iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(data_len),
        .flags = 0,
    };
    const sent = while (true) {
        break check(linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL)) catch |err| switch (err) {
            error.Interrupted => continue,
            error.WouldBlock => {
                var p = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT }};
                _ = linux.poll(&p, 1, 1000);
                continue;
            },
            else => |e| return e,
        };
    };
    if (sent < bytes.len) try writeAll(fd, bytes[sent..]);
}

/// An anonymous file in memory holding `bytes`.
pub fn memfdWith(name: [:0]const u8, bytes: []const u8) Error!fd_t {
    const fd = try memfd(name, bytes.len);
    errdefer close(fd);
    const map = try mapShared(fd, bytes.len, true);
    @memcpy(map, bytes);
    unmap(map);
    return fd;
}

/// An anonymous file in memory of `size` bytes.
pub fn memfd(name: [:0]const u8, size: usize) Error!fd_t {
    const fd: fd_t = @intCast(try check(linux.memfd_create(name.ptr, linux.MFD.CLOEXEC)));
    errdefer close(fd);
    _ = try check(linux.ftruncate(fd, @intCast(size)));
    return fd;
}

pub const Mapping = []align(std.heap.page_size_min) u8;

pub fn mapShared(fd: fd_t, size: usize, writable: bool) Error!Mapping {
    if (size == 0) return error.System;
    const rc = try check(linux.mmap(null, size, .{ .READ = true, .WRITE = writable }, .{ .TYPE = .SHARED }, fd, 0));
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    return ptr[0..size];
}

pub fn unmap(m: Mapping) void {
    _ = linux.munmap(m.ptr, m.len);
}

/// The size of the file behind `fd`.
pub fn fileSize(fd: fd_t) Error!usize {
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    _ = try check(@intCast(end));
    return @intCast(end);
}

pub const PollItem = linux.pollfd;

pub fn pollIn(fd: fd_t) PollItem {
    return .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
}

pub fn readable(item: PollItem) bool {
    return item.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0;
}

/// Waits up to `timeout_ms` (-1: for ever) for any of `items`.
pub fn poll(items: []PollItem, timeout_ms: i32) void {
    _ = linux.poll(items.ptr, items.len, timeout_ms);
}

pub fn getpid() pid_t {
    return linux.getpid();
}

pub fn getuid() u32 {
    return linux.getuid();
}

pub fn exit(code: u8) noreturn {
    linux.exit_group(code);
}

/// Something to do in the new process before it becomes the program.
pub const Hook = struct {
    ctx: *const anyopaque,
    run: *const fn (*const anyopaque) void,
};

/// A pipe: `[0]` to read from, `[1]` to write to.
pub fn pipe() Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

/// Starts `argv` with environment `envp` in a new session, stdin from
/// /dev/null, stdout and stderr to `log_fd` (or /dev/null). `hook` runs in
/// the new process first. Returns its pid.
pub fn spawn(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, log_fd: ?fd_t, hook: ?Hook) Error!pid_t {
    const rc = try check(linux.fork());
    if (rc != 0) return @intCast(rc);
    // the child: only system calls from here on
    _ = linux.setsid();
    const null_fd: fd_t = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
    _ = linux.dup2(null_fd, 0);
    _ = linux.dup2(log_fd orelse null_fd, 1);
    _ = linux.dup2(log_fd orelse null_fd, 2);
    if (hook) |h| h.run(h.ctx);
    if (cwd) |d| _ = linux.chdir(d);
    execvpe(argv, envp);
    linux.exit_group(127);
}

/// execve, trying each PATH directory when the program name has no slash.
fn execvpe(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
    const name = std.mem.span(argv[0].?);
    if (std.mem.findScalar(u8, name, '/') != null) {
        _ = linux.execve(argv[0].?, argv, envp);
        return;
    }
    var path: []const u8 = "/usr/local/bin:/usr/bin:/bin";
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (std.mem.startsWith(u8, e, "PATH=")) path = e[5..];
    }
    var it = std.mem.tokenizeScalar(u8, path, ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        _ = linux.execve(full.ptr, argv, envp);
    }
}

/// Becomes a background process: the parent returns the child's pid, the
/// child (in its own session) returns 0.
pub fn forkDetached() Error!pid_t {
    const rc = try check(linux.fork());
    if (rc == 0) _ = linux.setsid();
    return @intCast(rc);
}

pub const Exit = union(enum) { running, code: u8, signal: u8 };

/// Whether child `pid` has ended, without waiting.
pub fn reap(pid: pid_t) Exit {
    var status: i32 = 0;
    const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return .running;
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return .{ .code = @intCast((s >> 8) & 0xff) };
    return .{ .signal = @intCast(s & 0x7f) };
}

pub fn killGroup(pid: pid_t, sig: linux.SIG) void {
    _ = linux.kill(-pid, sig);
}

pub fn alive(pid: pid_t) bool {
    return linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))) == .SUCCESS;
}

pub fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

/// Ignores SIGPIPE, so that a write to a closed socket fails instead of
/// ending the process.
pub fn ignoreSigpipe() void {
    var act: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.PIPE, &act, null);
}

test "a memfd holds what was written and is passed over a socket" {
    var pair: [2]fd_t = undefined;
    _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair));
    defer close(pair[0]);
    defer close(pair[1]);
    const mem = try memfdWith("test", "hello");
    defer close(mem);
    try sendWithFds(pair[0], "abcd", &.{mem});
    var buf: [16]u8 = undefined;
    var fds: [4]fd_t = undefined;
    const got = try recvWithFds(pair[1], &buf, &fds);
    try std.testing.expectEqual(@as(usize, 4), got.bytes);
    try std.testing.expectEqual(@as(usize, 1), got.fds);
    defer close(fds[0]);
    try std.testing.expectEqual(@as(usize, 5), try fileSize(fds[0]));
    const map = try mapShared(fds[0], 5, false);
    defer unmap(map);
    try std.testing.expectEqualStrings("hello", map);
}

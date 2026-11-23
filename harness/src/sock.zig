//! A TCP connection on which opening, every read and every write has a time
//! limit. The socket is non-blocking; each operation waits with poll, so a
//! server that stops answering is noticed instead of waited on forever.
//!
//! The sockets are the system's own, reached directly: std's network layer
//! can't yet open a connection with a time limit, nor read with one on
//! Windows.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const net = std.Io.net;
const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

/// A socket as the system knows it.
pub const Handle = if (is_windows) usize else posix.fd_t;

pub const Error = error{
    WouldBlock,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NetworkUnreachable,
    BrokenPipe,
    AddressInUse,
    AccessDenied,
    Unexpected,
};

pub const Socket = struct {
    io: Io,
    handle: Handle,
    reader: Io.Reader,
    writer: Io.Writer,
    /// Longest wait for one read or write to make progress.
    idle_ms: u32,
    /// Time (`nowNs`) after which every wait fails.
    until_ns: ?i128 = null,
    /// Set: every wait ends soon after it is (error.Stopped).
    stop: ?*const std.atomic.Value(bool) = null,
    timed_out: bool = false,
    /// Why the last read or write failed.
    err: ?anyerror = null,

    /// `s` must not move afterwards: reader and writer point into it.
    pub fn init(s: *Socket, io: Io, handle: Handle, read_buf: []u8, write_buf: []u8, idle_ms: u32) void {
        s.* = .{
            .io = io,
            .handle = handle,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = read_buf, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = write_buf },
            .idle_ms = idle_ms,
        };
    }

    pub fn close(s: *Socket) void {
        closeHandle(s.handle);
    }

    /// Sets the limits for the request about to start.
    pub fn setLimits(s: *Socket, idle_ms: u32, total_ms: ?u32, stop: ?*const std.atomic.Value(bool)) void {
        s.idle_ms = idle_ms;
        s.until_ns = if (total_ms) |t| nowNs(s.io) + @as(i128, t) * std.time.ns_per_ms else null;
        s.stop = stop;
        s.timed_out = false;
        s.err = null;
    }

    fn wait(s: *Socket, what: Ready) !void {
        var end = nowNs(s.io) + @as(i128, s.idle_ms) * std.time.ns_per_ms;
        if (s.until_ns) |u| end = @min(end, u);
        while (true) {
            const left: i64 = @intCast(@divFloor(end - nowNs(s.io), std.time.ns_per_ms));
            if (left <= 0) {
                s.timed_out = true;
                return error.Timeout;
            }
            if (try sys.poll(s.handle, what, @intCast(@max(stopSlice(s.stop, left), 1)))) return;
            if (stopped(s.stop)) return error.Stopped;
        }
    }

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const s: *Socket = @alignCast(@fieldParentPtr("reader", io_r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        while (true) {
            s.wait(.in) catch |e| {
                s.err = e;
                return error.ReadFailed;
            };
            const n = sys.recv(s.handle, dest) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => {
                    s.err = e;
                    return error.ReadFailed;
                },
            };
            if (n == 0) return error.EndOfStream;
            w.advance(n);
            return n;
        }
    }

    fn sendAll(s: *Socket, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = sys.send(s.handle, rest) catch |e| switch (e) {
                error.WouldBlock => {
                    try s.wait(.out);
                    continue;
                },
                else => return e,
            };
            rest = rest[n..];
        }
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const s: *Socket = @alignCast(@fieldParentPtr("writer", io_w));
        s.drainInner(io_w, data, splat) catch |e| {
            s.err = e;
            return error.WriteFailed;
        };
        return Io.Writer.countSplat(data, splat);
    }

    fn drainInner(s: *Socket, io_w: *Io.Writer, data: []const []const u8, splat: usize) !void {
        try s.sendAll(io_w.buffered());
        io_w.end = 0;
        for (data[0 .. data.len - 1]) |d| try s.sendAll(d);
        for (0..splat) |_| try s.sendAll(data[data.len - 1]);
    }
};

/// A clock that only moves forward, in nanoseconds.
pub fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// How long one poll waits of `left` ms: with a stop flag at most 100 ms,
/// so that a stop is noticed.
fn stopSlice(stop: ?*const std.atomic.Value(bool), left: i64) i64 {
    return if (stop != null) @min(left, 100) else left;
}

fn stopped(stop: ?*const std.atomic.Value(bool)) bool {
    const f = stop orelse return false;
    return f.load(.acquire);
}

/// Measures time from when it was started.
pub const Timer = struct {
    io: Io,
    from: i128,

    pub fn start(io: Io) Timer {
        return .{ .io = io, .from = nowNs(io) };
    }

    /// Nanoseconds since the start.
    pub fn read(t: Timer) u64 {
        return @intCast(@max(0, nowNs(t.io) - t.from));
    }
};

pub fn closeHandle(h: Handle) void {
    sys.close(h);
}

/// Stops both directions of a connection: whoever waits on it wakes up.
pub fn shutdown(h: Handle) void {
    sys.shutdown(h);
}

/// Opens a TCP connection to `host`, trying each of its addresses for at most
/// `timeout_ms`. The socket returned is non-blocking.
pub fn connect(io: Io, host: []const u8, port: u16, timeout_ms: u32) !Handle {
    return connectUnless(io, host, port, timeout_ms, null);
}

/// `connect`, given up soon after `stop` is set (error.Stopped).
pub fn connectUnless(io: Io, host: []const u8, port: u16, timeout_ms: u32, stop: ?*const std.atomic.Value(bool)) !Handle {
    var addrs: [16]net.IpAddress = undefined;
    const n = try resolve(io, host, port, &addrs);
    var last: anyerror = error.UnknownHostName;
    for (addrs[0..n]) |*ip| {
        const addr: Addr = .from(ip);
        const h = sys.socket(addr.family(), true) catch |e| {
            last = e;
            continue;
        };
        if (connectOne(io, h, &addr, timeout_ms, stop)) {
            sys.setOption(h, sys.IPPROTO_TCP, sys.TCP_NODELAY, 1) catch {};
            return h;
        } else |e| {
            last = e;
            sys.close(h);
            if (e == error.Stopped) return e;
        }
    }
    return last;
}

fn connectOne(io: Io, h: Handle, addr: *const Addr, timeout_ms: u32, stop: ?*const std.atomic.Value(bool)) !void {
    sys.connect(h, addr) catch |e| switch (e) {
        error.WouldBlock => {
            const end = nowNs(io) + @as(i128, timeout_ms) * std.time.ns_per_ms;
            while (true) {
                const left: i64 = @intCast(@divFloor(end - nowNs(io), std.time.ns_per_ms));
                if (left <= 0) return error.ConnectionTimedOut;
                if (try sys.poll(h, .out, @intCast(@max(stopSlice(stop, left), 1)))) break;
                if (stopped(stop)) return error.Stopped;
            }
            try sys.pendingError(h);
        },
        else => return e,
    };
}

/// The addresses of `host`: itself when it is written as one, else what the
/// system's name lookup says.
fn resolve(io: Io, host: []const u8, port: u16, out: []net.IpAddress) !usize {
    if (net.IpAddress.parse(host, port)) |ip| {
        out[0] = ip;
        return 1;
    } else |_| {}
    const name = net.HostName.init(host) catch return error.UnknownHostName;
    var results: [32]net.HostName.LookupResult = undefined;
    var queue: Io.Queue(net.HostName.LookupResult) = .init(&results);
    var lookup = io.async(net.HostName.lookup, .{ name, io, &queue, .{ .port = port } });
    var n: usize = 0;
    while (queue.getOne(io)) |result| switch (result) {
        .address => |ip| if (n < out.len) {
            out[n] = ip;
            n += 1;
        },
        .canonical_name => {},
    } else |e| switch (e) {
        error.Closed => {},
        error.Canceled => {
            lookup.cancel(io) catch {};
            return error.Canceled;
        },
    }
    try lookup.await(io);
    if (n == 0) return error.UnknownHostName;
    return n;
}

/// A listening socket on this machine only (127.0.0.1).
pub const Listener = struct {
    handle: Handle,
    port: u16,

    /// `port` 0 takes a free one.
    pub fn open(port: u16) !Listener {
        const ip: net.IpAddress = .{ .ip4 = .loopback(port) };
        var addr: Addr = .from(&ip);
        const h = try sys.socket(addr.family(), false);
        errdefer sys.close(h);
        try sys.setOption(h, sys.SOL_SOCKET, sys.SO_REUSEADDR, 1);
        if (sys.SO_REUSEPORT) |reuse_port| try sys.setOption(h, sys.SOL_SOCKET, reuse_port, 1);
        try sys.bind(h, &addr);
        try sys.listen(h, 128);
        try sys.localAddress(h, &addr);
        return .{ .handle = h, .port = std.mem.bigToNative(u16, addr.in.port) };
    }

    /// A listener whose port no other program can take while it is open
    /// (the app server's): on Windows SO_EXCLUSIVEADDRUSE, where
    /// SO_REUSEADDR would let another program bind the same port; elsewhere
    /// no SO_REUSEPORT. `port` 0 takes a free one.
    pub fn openExclusive(port: u16) !Listener {
        const ip: net.IpAddress = .{ .ip4 = .loopback(port) };
        var addr: Addr = .from(&ip);
        const h = try sys.socket(addr.family(), false);
        errdefer sys.close(h);
        if (is_windows) try sys.setOption(h, sys.SOL_SOCKET, sys.SO_EXCLUSIVEADDRUSE, 1) else try sys.setOption(h, sys.SOL_SOCKET, sys.SO_REUSEADDR, 1);
        try sys.bind(h, &addr);
        try sys.listen(h, 128);
        try sys.localAddress(h, &addr);
        return .{ .handle = h, .port = std.mem.bigToNative(u16, addr.in.port) };
    }

    /// Waits for the next connection. Its socket is a blocking one, and
    /// sends each write at once, as model servers do for a stream of tokens.
    pub fn accept(l: Listener) !Handle {
        const h = try sys.accept(l.handle);
        sys.setOption(h, sys.IPPROTO_TCP, sys.TCP_NODELAY, 1) catch {};
        return h;
    }

    pub fn close(l: Listener) void {
        sys.close(l.handle);
    }
};

const Ready = enum { in, out };

/// An address the way the system calls take it.
const Addr = extern union {
    in: sys.In,
    in6: sys.In6,

    fn from(ip: *const net.IpAddress) Addr {
        return switch (ip.*) {
            .ip4 => |a| .{ .in = .{
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            } },
            .ip6 => |a| .{ .in6 = .{
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            } },
        };
    }

    fn family(a: *const Addr) u32 {
        return a.in.family;
    }

    fn len(a: *const Addr) u32 {
        return if (a.in.family == sys.AF_INET6) @sizeOf(sys.In6) else @sizeOf(sys.In);
    }
};

const sys = if (is_windows) winsock else unix;

// ---- Linux and macOS ----

const unix = struct {
    const linux = std.os.linux;
    const c = std.c;

    const In = posix.sockaddr.in;
    const In6 = posix.sockaddr.in6;
    const AF_INET6: u32 = posix.AF.INET6;

    const IPPROTO_TCP: i32 = posix.IPPROTO.TCP;
    const TCP_NODELAY: u32 = posix.TCP.NODELAY;
    const SOL_SOCKET: i32 = posix.SOL.SOCKET;
    const SO_REUSEADDR: u32 = posix.SO.REUSEADDR;
    const SO_REUSEPORT: ?u32 = posix.SO.REUSEPORT;
    /// macOS: a write to a connection the other side closed is an error, not
    /// a signal. (Linux says so per send.)
    const SO_NOSIGPIPE: u32 = 0x1022;
    const send_flags: u32 = if (is_linux) posix.MSG.NOSIGNAL else 0;

    /// What a call gave back: a number, or why it failed.
    fn result(rc: anytype) Err!usize {
        const e: posix.E = if (is_linux) linux.errno(rc) else c.errno(rc);
        return switch (e) {
            .SUCCESS => @intCast(rc),
            .AGAIN, .INPROGRESS, .ALREADY => error.WouldBlock,
            .INTR => error.Interrupted,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET, .CONNABORTED, .NETRESET => error.ConnectionResetByPeer,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NETUNREACH, .HOSTUNREACH, .NETDOWN, .HOSTDOWN => error.NetworkUnreachable,
            .PIPE, .NOTCONN => error.BrokenPipe,
            .ADDRINUSE => error.AddressInUse,
            .ACCES, .PERM => error.AccessDenied,
            else => error.Unexpected,
        };
    }

    fn socket(fam: u32, non_blocking: bool) Err!Handle {
        if (is_linux) {
            const kind: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | (if (non_blocking) @as(u32, posix.SOCK.NONBLOCK) else 0);
            return @intCast(try result(linux.socket(fam, kind, posix.IPPROTO.TCP)));
        }
        const fd: Handle = @intCast(try result(c.socket(fam, posix.SOCK.STREAM, posix.IPPROTO.TCP)));
        errdefer close(fd);
        try prepare(fd);
        if (non_blocking) {
            const flags = try result(c.fcntl(fd, posix.F.GETFL, @as(c_int, 0)));
            const with: c_int = @intCast(flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK")));
            _ = try result(c.fcntl(fd, posix.F.SETFL, with));
        }
        return fd;
    }

    /// macOS has no flags for these at the time a socket is made.
    fn prepare(fd: Handle) Err!void {
        _ = try result(c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)));
        try setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1);
    }

    fn close(fd: Handle) void {
        _ = if (is_linux) linux.close(fd) else c.close(fd);
    }

    fn shutdown(fd: Handle) void {
        _ = if (is_linux) linux.shutdown(fd, posix.SHUT.RDWR) else c.shutdown(fd, posix.SHUT.RDWR);
    }

    fn connect(fd: Handle, addr: *const Addr) Err!void {
        while (true) {
            const rc = if (is_linux) linux.connect(fd, addr, addr.len()) else c.connect(fd, @ptrCast(addr), addr.len());
            _ = result(rc) catch |e| switch (e) {
                // the connect goes on by itself: its outcome is polled for
                error.Interrupted => return error.WouldBlock,
                else => |other| return other,
            };
            return;
        }
    }

    fn recv(fd: Handle, dest: []u8) Err!usize {
        while (true) {
            const rc = if (is_linux) linux.recvfrom(fd, dest.ptr, dest.len, 0, null, null) else c.recv(fd, dest.ptr, dest.len, 0);
            return result(rc) catch |e| switch (e) {
                error.Interrupted => continue,
                else => |other| return other,
            };
        }
    }

    fn send(fd: Handle, bytes: []const u8) Err!usize {
        while (true) {
            const rc = if (is_linux) linux.sendto(fd, bytes.ptr, bytes.len, send_flags, null, 0) else c.send(fd, bytes.ptr, bytes.len, send_flags);
            return result(rc) catch |e| switch (e) {
                error.Interrupted => continue,
                else => |other| return other,
            };
        }
    }

    /// Whether `fd` became ready within `timeout_ms`. A broken connection
    /// counts as ready: the read or write that follows says what happened.
    fn poll(fd: Handle, what: Ready, timeout_ms: i32) Err!bool {
        var fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = switch (what) {
                .in => posix.POLL.IN,
                .out => posix.POLL.OUT,
            },
            .revents = 0,
        }};
        while (true) {
            const rc = if (is_linux) linux.poll(&fds, 1, timeout_ms) else c.poll(&fds, 1, timeout_ms);
            const n = result(rc) catch |e| switch (e) {
                error.Interrupted => continue,
                else => |other| return other,
            };
            return n != 0;
        }
    }

    /// The outcome of a connect that was still in progress.
    fn pendingError(fd: Handle) Err!void {
        var code: c_int = 0;
        var size: posix.socklen_t = @sizeOf(c_int);
        const rc = if (is_linux)
            linux.getsockopt(fd, SOL_SOCKET, posix.SO.ERROR, @ptrCast(&code), &size)
        else
            c.getsockopt(fd, SOL_SOCKET, posix.SO.ERROR, &code, &size);
        _ = try result(rc);
        if (code == 0) return;
        const e: posix.E = @fromBackingInt(@intCast(code));
        return switch (e) {
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET, .CONNABORTED => error.ConnectionResetByPeer,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NETUNREACH, .HOSTUNREACH, .NETDOWN, .HOSTDOWN => error.NetworkUnreachable,
            .ACCES, .PERM => error.AccessDenied,
            else => error.Unexpected,
        };
    }

    fn setOption(fd: Handle, level: i32, name: u32, value: c_int) Err!void {
        const rc = if (is_linux)
            linux.setsockopt(fd, level, name, @ptrCast(&value), @sizeOf(c_int))
        else
            c.setsockopt(fd, level, name, &value, @sizeOf(c_int));
        _ = try result(rc);
    }

    fn getOption(fd: Handle, level: i32, name: u32) Err!c_int {
        var value: c_int = 0;
        var size: posix.socklen_t = @sizeOf(c_int);
        const rc = if (is_linux)
            linux.getsockopt(fd, level, name, @ptrCast(&value), &size)
        else
            c.getsockopt(fd, level, name, &value, &size);
        _ = try result(rc);
        return value;
    }

    fn bind(fd: Handle, addr: *const Addr) Err!void {
        const rc = if (is_linux) linux.bind(fd, @ptrCast(addr), addr.len()) else c.bind(fd, @ptrCast(addr), addr.len());
        _ = try result(rc);
    }

    fn listen(fd: Handle, backlog: u31) Err!void {
        _ = try result(if (is_linux) linux.listen(fd, backlog) else c.listen(fd, backlog));
    }

    fn localAddress(fd: Handle, addr: *Addr) Err!void {
        var size: posix.socklen_t = @sizeOf(Addr);
        const rc = if (is_linux) linux.getsockname(fd, @ptrCast(addr), &size) else c.getsockname(fd, @ptrCast(addr), &size);
        _ = try result(rc);
    }

    fn accept(fd: Handle) Err!Handle {
        while (true) {
            const rc = if (is_linux) linux.accept4(fd, null, null, posix.SOCK.CLOEXEC) else c.accept(fd, null, null);
            const got: Handle = @intCast(result(rc) catch |e| switch (e) {
                error.Interrupted => continue,
                else => |other| return other,
            });
            if (!is_linux) prepare(got) catch {};
            return got;
        }
    }

    const Err = Error || error{Interrupted};
};

// ---- Windows ----

const winsock = struct {
    const In = std.os.windows.ws2_32.sockaddr.in;
    const In6 = std.os.windows.ws2_32.sockaddr.in6;
    const AF_INET6: u32 = 23;
    const SOCK_STREAM = 1;
    const IPPROTO_TCP: i32 = 6;
    const TCP_NODELAY: u32 = 1;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_REUSEADDR: u32 = 4;
    const SO_REUSEPORT: ?u32 = null;
    /// ~SO_REUSEADDR
    const SO_EXCLUSIVEADDRUSE: u32 = 0xfffffffb;
    const SO_ERROR = 0x1007;
    const SD_BOTH = 2;
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
    const INVALID_SOCKET = ~@as(usize, 0);

    const POLLRDNORM = 0x0100;
    const POLLRDBAND = 0x0200;
    const POLLWRNORM = 0x0010;
    const PollFd = extern struct { fd: usize, events: i16, revents: i16 };

    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAPoll(fds: [*]PollFd, n: u32, timeout: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn ioctlsocket(s: usize, cmd: i32, arg: *u32) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
    const ws = struct {
        extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) usize;
        extern "ws2_32" fn connect(s: usize, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getsockopt(s: usize, level: c_int, name: c_int, value: [*]u8, len: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn setsockopt(s: usize, level: c_int, name: c_int, value: [*]const u8, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn bind(s: usize, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn listen(s: usize, backlog: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn accept(s: usize, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.winapi) usize;
        extern "ws2_32" fn getsockname(s: usize, name: *anyopaque, namelen: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn shutdown(s: usize, how: c_int) callconv(.winapi) c_int;
    };

    var started: std.atomic.Value(bool) = .init(false);

    /// Winsock wants to be asked for before its first use.
    fn startup() void {
        if (started.load(.acquire)) return;
        var data: [512]u8 align(8) = undefined;
        _ = WSAStartup(0x0202, &data);
        started.store(true, .release);
    }

    fn lastError() Error {
        return switch (WSAGetLastError()) {
            10035, 10036, 10037 => error.WouldBlock, // WSAEWOULDBLOCK, EINPROGRESS, EALREADY
            10061 => error.ConnectionRefused,
            // WSAENETRESET, ECONNABORTED, ECONNRESET, ESHUTDOWN
            10052, 10053, 10054, 10058 => error.ConnectionResetByPeer,
            10060 => error.ConnectionTimedOut,
            10050, 10051, 10064, 10065 => error.NetworkUnreachable,
            10048 => error.AddressInUse,
            10013 => error.AccessDenied,
            else => error.Unexpected,
        };
    }

    fn check(rc: c_int) Error!void {
        if (rc != 0) return lastError();
    }

    fn socket(fam: u32, non_blocking: bool) Error!Handle {
        startup();
        const s = ws.socket(@intCast(fam), SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return lastError();
        errdefer close(s);
        if (non_blocking) {
            var on: u32 = 1;
            try check(ioctlsocket(s, FIONBIO, &on));
        }
        return s;
    }

    fn close(s: Handle) void {
        _ = closesocket(s);
    }

    fn shutdown(s: Handle) void {
        _ = ws.shutdown(s, SD_BOTH);
    }

    fn connect(s: Handle, addr: *const Addr) Error!void {
        try check(ws.connect(s, addr, @intCast(addr.len())));
    }

    fn recv(s: Handle, dest: []u8) Error!usize {
        const rc = ws.recv(s, dest.ptr, @intCast(@min(dest.len, std.math.maxInt(i32))), 0);
        if (rc < 0) return lastError();
        return @intCast(rc);
    }

    fn send(s: Handle, bytes: []const u8) Error!usize {
        const rc = ws.send(s, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(i32))), 0);
        if (rc < 0) return lastError();
        return @intCast(rc);
    }

    fn poll(s: Handle, what: Ready, timeout_ms: i32) Error!bool {
        var fds = [_]PollFd{.{
            .fd = s,
            .events = switch (what) {
                .in => POLLRDNORM | POLLRDBAND,
                .out => POLLWRNORM,
            },
            .revents = 0,
        }};
        const n = WSAPoll(&fds, 1, timeout_ms);
        if (n < 0) return lastError();
        return n != 0;
    }

    /// The outcome of a connect that was still in progress.
    fn pendingError(s: Handle) Error!void {
        var code: c_int = 0;
        var size: c_int = @sizeOf(c_int);
        if (ws.getsockopt(s, SOL_SOCKET, SO_ERROR, @ptrCast(&code), &size) != 0) return error.ConnectionRefused;
        if (code != 0) return error.ConnectionRefused;
    }

    fn setOption(s: Handle, level: i32, name: u32, value: c_int) Error!void {
        // bits as they are: SO_EXCLUSIVEADDRUSE is a negative int
        try check(ws.setsockopt(s, level, @bitCast(name), @ptrCast(&value), @sizeOf(c_int)));
    }

    fn getOption(s: Handle, level: i32, name: u32) Error!c_int {
        var value: c_int = 0;
        var size: c_int = @sizeOf(c_int);
        try check(ws.getsockopt(s, level, @intCast(name), @ptrCast(&value), &size));
        return value;
    }

    fn bind(s: Handle, addr: *const Addr) Error!void {
        try check(ws.bind(s, addr, @intCast(addr.len())));
    }

    fn listen(s: Handle, backlog: u31) Error!void {
        try check(ws.listen(s, backlog));
    }

    fn localAddress(s: Handle, addr: *Addr) Error!void {
        var size: c_int = @sizeOf(Addr);
        try check(ws.getsockname(s, addr, &size));
    }

    fn accept(s: Handle) Error!Handle {
        const got = ws.accept(s, null, null);
        if (got == INVALID_SOCKET) return lastError();
        return got;
    }
};

test "an_accepted_connection_sends_small_writes_at_once" {
    // A stream of tokens is many small writes. Held back until the other
    // side confirms the one before, each can arrive tens of ms late.
    const l = try Listener.open(0);
    defer l.close();
    const there = try connect(std.testing.io, "127.0.0.1", l.port, 1000);
    defer closeHandle(there);
    const here = try l.accept();
    defer closeHandle(here);
    try std.testing.expect(try sys.getOption(here, sys.IPPROTO_TCP, sys.TCP_NODELAY) != 0);
    try std.testing.expect(try sys.getOption(there, sys.IPPROTO_TCP, sys.TCP_NODELAY) != 0);
}

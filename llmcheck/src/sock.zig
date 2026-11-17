//! A TCP connection on which opening, every read and every write has a time
//! limit. The socket is non-blocking; each operation waits with poll, so a
//! server that stops answering is noticed instead of waited on forever.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const is_windows = builtin.os.tag == .windows;

pub const Socket = struct {
    handle: posix.socket_t,
    reader: Io.Reader,
    writer: Io.Writer,
    /// Longest wait for one read or write to make progress.
    idle_ms: u32,
    /// Time (std.time.nanoTimestamp) after which every wait fails.
    until_ns: ?i128 = null,
    timed_out: bool = false,
    /// Why the last read or write failed.
    err: ?anyerror = null,

    /// `s` must not move afterwards: reader and writer point into it.
    pub fn init(s: *Socket, handle: posix.socket_t, read_buf: []u8, write_buf: []u8, idle_ms: u32) void {
        s.* = .{
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
    pub fn setLimits(s: *Socket, idle_ms: u32, total_ms: ?u32) void {
        s.idle_ms = idle_ms;
        s.until_ns = if (total_ms) |t| std.time.nanoTimestamp() + @as(i128, t) * std.time.ns_per_ms else null;
        s.timed_out = false;
        s.err = null;
    }

    fn wait(s: *Socket, events: i16) !void {
        var ms: i64 = s.idle_ms;
        if (s.until_ns) |u| {
            const left: i64 = @intCast(@divFloor(u - std.time.nanoTimestamp(), std.time.ns_per_ms));
            if (left <= 0) {
                s.timed_out = true;
                return error.Timeout;
            }
            ms = @min(ms, left);
        }
        var fds = [_]posix.pollfd{.{ .fd = s.handle, .events = events, .revents = 0 }};
        const n = try posix.poll(&fds, @intCast(@max(ms, 1)));
        if (n == 0) {
            s.timed_out = true;
            return error.Timeout;
        }
    }

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const s: *Socket = @alignCast(@fieldParentPtr("reader", io_r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        while (true) {
            s.wait(posix.POLL.IN) catch |e| {
                s.err = e;
                return error.ReadFailed;
            };
            const n = recvSome(s.handle, dest) catch |e| switch (e) {
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
            const n = sendSome(s.handle, rest) catch |e| switch (e) {
                error.WouldBlock => {
                    try s.wait(posix.POLL.OUT);
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

// On Windows std's recv needs libc and its send treats some Winsock errors
// as impossible, so both go to Winsock directly there.
fn recvSome(h: posix.socket_t, dest: []u8) !usize {
    if (!is_windows) return posix.recv(h, dest, 0);
    const ws = std.os.windows.ws2_32;
    const rc = ws.recv(h, dest.ptr, @intCast(@min(dest.len, std.math.maxInt(i32))), 0);
    if (rc != ws.SOCKET_ERROR) return @intCast(rc);
    return winsockError();
}

fn sendSome(h: posix.socket_t, bytes: []const u8) !usize {
    if (!is_windows) return posix.send(h, bytes, 0);
    const ws = std.os.windows.ws2_32;
    const rc = ws.send(h, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(i32))), 0);
    if (rc != ws.SOCKET_ERROR) return @intCast(rc);
    return winsockError();
}

fn winsockError() error{ WouldBlock, ConnectionResetByPeer, ConnectionTimedOut, Unexpected } {
    return switch (std.os.windows.ws2_32.WSAGetLastError()) {
        .WSAEWOULDBLOCK => error.WouldBlock,
        .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET, .WSAESHUTDOWN => error.ConnectionResetByPeer,
        .WSAETIMEDOUT => error.ConnectionTimedOut,
        else => error.Unexpected,
    };
}

pub fn closeHandle(h: posix.socket_t) void {
    if (is_windows) std.os.windows.closesocket(h) catch {} else posix.close(h);
}

/// Opens a TCP connection to `host`, trying each of its addresses for at most
/// `timeout_ms`. The socket returned is non-blocking.
pub fn connect(gpa: std.mem.Allocator, host: []const u8, port: u16, timeout_ms: u32) !posix.socket_t {
    const list = try std.net.getAddressList(gpa, host, port);
    defer list.deinit();
    var last: anyerror = error.UnknownHostName;
    for (list.addrs) |addr| {
        const flags = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | (if (is_windows) 0 else posix.SOCK.CLOEXEC);
        const fd = posix.socket(addr.any.family, flags, posix.IPPROTO.TCP) catch |e| {
            last = e;
            continue;
        };
        if (connectOne(fd, addr, timeout_ms)) {
            noDelay(fd);
            return fd;
        } else |e| {
            last = e;
            closeHandle(fd);
        }
    }
    return last;
}

fn connectOne(fd: posix.socket_t, addr: std.net.Address, timeout_ms: u32) !void {
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |e| switch (e) {
        error.WouldBlock => {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            const n = try posix.poll(&fds, @intCast(@max(timeout_ms, 1)));
            if (n == 0) return error.ConnectionTimedOut;
            try pendingError(fd);
        },
        else => return e,
    };
}

/// The outcome of a connect that was still in progress.
fn pendingError(fd: posix.socket_t) !void {
    if (is_windows) {
        const ws = std.os.windows.ws2_32;
        var code: i32 = 0;
        var len: i32 = @sizeOf(i32);
        if (ws.getsockopt(fd, ws.SOL.SOCKET, ws.SO.ERROR, @ptrCast(&code), &len) != 0) return error.ConnectionRefused;
        if (code != 0) return error.ConnectionRefused;
    } else {
        try posix.getsockoptError(fd);
    }
}

/// Small requests and answers shouldn't wait for more data to batch with.
fn noDelay(fd: posix.socket_t) void {
    const on: c_int = 1;
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&on)) catch {};
}

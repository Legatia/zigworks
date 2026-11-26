//! Whether harness answers on its port: `GET /alive`, a 200 that says
//! `harness`, within a time limit (another program on the port, which
//! answers 200 to anything, isn't harness). The socket is the system's own, non-blocking, waited on with poll
//! (Windows: Winsock's, waited on with WSAPoll): std's connect can't yet
//! take a time limit (harness's sock.zig says the same).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const posix = std.posix;
const c = std.c;

/// True when harness answers `GET /alive` on 127.0.0.1:`port` with a 200
/// and its mark within `timeout_ms` (connecting, sending and reading).
pub fn check(port: u16, timeout_ms: u32) bool {
    return checkOrFail(port, timeout_ms) catch false;
}

const is_windows = builtin.os.tag == .windows;

/// Winsock, as much of it as one request needs.
const ws = struct {
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
    const AF_INET: c_int = 2;
    const SOCK_STREAM: c_int = 1;
    const IPPROTO_TCP: c_int = 6;
    const FIONBIO: c_long = @bitCast(@as(c_ulong, 0x8004667e));
    const SOL_SOCKET: c_int = 0xffff;
    const SO_ERROR: c_int = 0x1007;
    const WSAEWOULDBLOCK: c_int = 10035;
    const WSAEINPROGRESS: c_int = 10036;
    const POLLRDNORM: i16 = 0x0100;
    const POLLWRNORM: i16 = 0x0010;
    const sockaddr_in = extern struct { family: u16 = 2, port: u16, addr: u32, zero: [8]u8 = @splat(0) };
    const pollfd = extern struct { fd: SOCKET, events: i16, revents: i16 };
    const WSADATA = extern struct { bytes: [512]u8 };
    extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn socket(af: c_int, kind: c_int, proto: c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, arg: *c_ulong) callconv(.winapi) c_int;
    extern "ws2_32" fn connect(s: SOCKET, addr: *const sockaddr_in, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockopt(s: SOCKET, level: c_int, name: c_int, value: *c_int, len: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAPoll(fds: [*]pollfd, n: c_ulong, timeout_ms: c_int) callconv(.winapi) c_int;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

    var started: std.atomic.Value(bool) = .init(false);

    fn ready(s: SOCKET, events: i16, deadline: i64) bool {
        const left = deadline - nowMs();
        if (left <= 0) return false;
        var fds = [_]pollfd{.{ .fd = s, .events = events, .revents = 0 }};
        return WSAPoll(&fds, 1, @intCast(left)) > 0;
    }
};

/// The same request over Winsock.
fn checkWindows(port: u16, timeout_ms: u32) !bool {
    const deadline = nowMs() + timeout_ms;
    if (!ws.started.load(.acquire)) {
        var data: ws.WSADATA = undefined;
        if (ws.WSAStartup(0x0202, &data) != 0) return error.NoSocket;
        ws.started.store(true, .release);
    }
    // (a socket made by socket() is not inherited by what the app starts
    // unless handed over, so there is no close-on-exec to set)
    const s = ws.socket(ws.AF_INET, ws.SOCK_STREAM, ws.IPPROTO_TCP);
    if (s == ws.INVALID_SOCKET) return error.NoSocket;
    defer _ = ws.closesocket(s);
    var on: c_ulong = 1;
    if (ws.ioctlsocket(s, ws.FIONBIO, &on) != 0) return error.Fcntl;

    const addr: ws.sockaddr_in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (ws.connect(s, &addr, @sizeOf(ws.sockaddr_in)) != 0) {
        switch (ws.WSAGetLastError()) {
            ws.WSAEWOULDBLOCK, ws.WSAEINPROGRESS => {},
            else => return false,
        }
        // (a refused connection ends the wait with an error flag, and
        // SO_ERROR says which)
        if (!ws.ready(s, ws.POLLWRNORM, deadline)) return false;
        var code: c_int = 0;
        var size: c_int = @sizeOf(c_int);
        if (ws.getsockopt(s, ws.SOL_SOCKET, ws.SO_ERROR, &code, &size) != 0 or code != 0) return false;
    }

    var req_buf: [128]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /alive HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{port});
    var sent: usize = 0;
    while (sent < req.len) {
        const n = ws.send(s, req[sent..].ptr, @intCast(req.len - sent), 0);
        if (n < 0) {
            if (ws.WSAGetLastError() != ws.WSAEWOULDBLOCK) return false;
            if (!ws.ready(s, ws.POLLWRNORM, deadline)) return false;
            continue;
        }
        sent += @intCast(n);
    }

    var resp: [2048]u8 = undefined;
    var got: usize = 0;
    while (got < resp.len) {
        switch (answer(resp[0..got])) {
            .yes => return true,
            .no => return false,
            .more => {},
        }
        if (!ws.ready(s, ws.POLLRDNORM, deadline)) return false;
        const n = ws.recv(s, resp[got..].ptr, @intCast(resp.len - got), 0);
        if (n < 0) {
            if (ws.WSAGetLastError() == ws.WSAEWOULDBLOCK) continue;
            return false;
        }
        if (n == 0) break;
        got += @intCast(n);
    }
    return answer(resp[0..got]) == .yes;
}

/// What harness's `/alive` answers with, after its headers.
pub const mark = "harness";

const Answer = enum { more, yes, no };

/// What the answer read so far says: a 200 whose body starts with the mark
/// is harness.
fn answer(resp: []const u8) Answer {
    if (resp.len < 13) return .more;
    if (!is200(resp)) return .no;
    const end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return .more;
    const body = resp[end + 4 ..];
    if (body.len < mark.len) return if (std.mem.startsWith(u8, mark, body)) .more else .no;
    return if (std.mem.startsWith(u8, body, mark)) .yes else .no;
}

/// "HTTP/1.x 200 …"
fn is200(line: []const u8) bool {
    return (std.mem.startsWith(u8, line, "HTTP/1.1 200") or std.mem.startsWith(u8, line, "HTTP/1.0 200")) and
        line.len > 12 and (line[12] == ' ' or line[12] == '\r');
}

fn checkOrFail(port: u16, timeout_ms: u32) !bool {
    if (is_windows) return checkWindows(port, timeout_ms);
    const deadline = nowMs() + timeout_ms;
    const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    if (fd < 0) return error.NoSocket;
    defer _ = c.close(fd);
    _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    const flags = c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.Fcntl;
    if (c.fcntl(fd, posix.F.SETFL, flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK"))) < 0) return error.Fcntl;
    if (builtin.os.tag.isDarwin()) {
        // a write to a closed connection is an error, not a signal
        const on: c_int = 1;
        _ = c.setsockopt(fd, posix.SOL.SOCKET, 0x1022, &on, @sizeOf(c_int));
    }

    var addr: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) {
        switch (posix.errno(@as(c_int, -1))) {
            .INPROGRESS, .AGAIN, .INTR => {},
            else => return false,
        }
        if (!try ready(fd, posix.POLL.OUT, deadline)) return false;
        var code: c_int = 0;
        var size: posix.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&code), &size) != 0 or code != 0) return false;
    }

    var req_buf: [128]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /alive HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{port});
    const send_flags: c_uint = if (builtin.os.tag == .linux) posix.MSG.NOSIGNAL else 0;
    var sent: usize = 0;
    while (sent < req.len) {
        const n = c.send(fd, req[sent..].ptr, req.len - sent, @bitCast(send_flags));
        if (n < 0) {
            switch (posix.errno(n)) {
                .AGAIN, .INTR => if (!try ready(fd, posix.POLL.OUT, deadline)) return false,
                else => return false,
            }
            continue;
        }
        sent += @intCast(n);
    }

    var resp: [2048]u8 = undefined;
    var got: usize = 0;
    while (got < resp.len) {
        switch (answer(resp[0..got])) {
            .yes => return true,
            .no => return false,
            .more => {},
        }
        if (!try ready(fd, posix.POLL.IN, deadline)) return false;
        const n = c.recv(fd, resp[got..].ptr, resp.len - got, 0);
        if (n < 0) {
            switch (posix.errno(n)) {
                .AGAIN, .INTR => continue,
                else => return false,
            }
        }
        if (n == 0) break;
        got += @intCast(n);
    }
    return answer(resp[0..got]) == .yes;
}

/// Whether `fd` became ready for `events` before `deadline`.
fn ready(fd: posix.fd_t, events: i16, deadline: i64) !bool {
    while (true) {
        const left = deadline - nowMs();
        if (left <= 0) return false;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = c.poll(&fds, 1, @intCast(left));
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.Poll;
        }
        return n > 0;
    }
}

fn nowMs() i64 {
    if (is_windows) return @intCast(ws.GetTickCount64());
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const t = std.testing;

/// A server for one connection on 127.0.0.1, answering with `reply`
/// (nothing, when null) and keeping the request it was sent.
const OneShot = struct {
    server: net.Server,
    port: u16,
    reply: ?[]const u8,
    hold_ms: u32 = 0,
    request: [1024]u8 = undefined,
    request_len: usize = 0,
    thread: ?std.Thread = null,

    fn start(s: *OneShot) !void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        s.server = try addr.listen(t.io, .{ .reuse_address = true });
        s.port = s.server.socket.address.getPort();
        s.thread = try std.Thread.spawn(.{}, serve, .{s});
    }

    fn serve(s: *OneShot) void {
        const conn = s.server.accept(t.io) catch return;
        defer conn.close(t.io);
        var rbuf: [1024]u8 = undefined;
        var r = conn.reader(t.io, &rbuf);
        while (s.request_len < s.request.len) {
            const b = r.interface.takeByte() catch break;
            s.request[s.request_len] = b;
            s.request_len += 1;
            if (std.mem.endsWith(u8, s.request[0..s.request_len], "\r\n\r\n")) break;
        }
        if (s.hold_ms > 0) t.io.sleep(.fromMilliseconds(s.hold_ms), .awake) catch {};
        if (s.reply) |reply| {
            var wbuf: [256]u8 = undefined;
            var w = conn.writer(t.io, &wbuf);
            w.interface.writeAll(reply) catch {};
            w.interface.flush() catch {};
        }
    }

    fn finish(s: *OneShot) void {
        if (s.thread) |th| th.join();
        s.server.deinit(t.io);
    }
};

test "alive_is_harness_saying_so" {
    var ok: OneShot = .{ .server = undefined, .port = 0, .reply = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nharness" };
    try ok.start();
    try t.expect(check(ok.port, 2000));
    ok.finish();

    // another program on the port, answering every path with a page
    var other: OneShot = .{ .server = undefined, .port = 0, .reply = "HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n<!doctype html>" };
    try other.start();
    try t.expect(!check(other.port, 2000));
    other.finish();

    var empty: OneShot = .{ .server = undefined, .port = 0, .reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" };
    try empty.start();
    try t.expect(!check(empty.port, 2000));
    empty.finish();

    var missing: OneShot = .{ .server = undefined, .port = 0, .reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 7\r\n\r\nharness" };
    try missing.start();
    try t.expect(!check(missing.port, 2000));
    missing.finish();

    var junk: OneShot = .{ .server = undefined, .port = 0, .reply = "SSH-2.0-OpenSSH\r\n" };
    try junk.start();
    try t.expect(!check(junk.port, 2000));
    junk.finish();
}

test "the_answer_is_read_as_it_comes" {
    try t.expectEqual(Answer.more, answer(""));
    try t.expectEqual(Answer.more, answer("HTTP/1.1 200 OK\r\nx: y\r\n"));
    try t.expectEqual(Answer.more, answer("HTTP/1.1 200 OK\r\nx: y\r\n\r\nharn"));
    try t.expectEqual(Answer.yes, answer("HTTP/1.1 200 OK\r\nx: y\r\n\r\nharness"));
    try t.expectEqual(Answer.yes, answer("HTTP/1.0 200 OK\r\n\r\nharness\n"));
    try t.expectEqual(Answer.no, answer("HTTP/1.1 200 OK\r\nx: y\r\n\r\nharmless"));
    try t.expectEqual(Answer.no, answer("HTTP/1.1 204 No Content\r\n"));
    try t.expectEqual(Answer.no, answer("HTTP/1.1 2000 OK\r\n"));
    // the word in a header is not the answer
    try t.expectEqual(Answer.more, answer("HTTP/1.1 200 OK\r\nserver: harness\r\n"));
}

test "nothing_listening_is_not_alive" {
    const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(t.io, .{});
    const port = server.socket.address.getPort();
    server.deinit(t.io);
    try t.expect(!check(port, 2000));
}

test "a_server_that_never_answers_is_not_alive_within_the_time" {
    var silent: OneShot = .{ .server = undefined, .port = 0, .reply = null, .hold_ms = 1500 };
    try silent.start();
    const started = Io.Clock.awake.now(t.io);
    try t.expect(!check(silent.port, 300));
    const took = started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds();
    try t.expect(took < 1200);
    silent.finish();
}

test "the_request_names_alive_and_the_host" {
    var ok: OneShot = .{ .server = undefined, .port = 0, .reply = "HTTP/1.0 200 OK\r\n\r\nharness" };
    try ok.start();
    try t.expect(check(ok.port, 2000));
    ok.finish();
    const req = ok.request[0..ok.request_len];
    try t.expect(std.mem.startsWith(u8, req, "GET /alive HTTP/1.1\r\n"));
    var host_buf: [64]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "\r\nHost: 127.0.0.1:{d}\r\n", .{ok.port});
    try t.expect(std.mem.indexOf(u8, req, host) != null);
}

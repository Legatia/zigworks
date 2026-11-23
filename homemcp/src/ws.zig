//! A WebSocket client (RFC 6455), as much as Home Assistant's API needs:
//! the upgrade (key and accept), text messages out (masked, as a client
//! must) and in (in fragments too, pings answered, close noticed), over
//! http.zig's connections, so http and https alike. No extensions: nothing
//! is compressed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");

pub const Error = error{
    /// The other side closed the WebSocket, or the connection ended.
    Closed,
    /// A frame no server should send.
    Protocol,
    /// A message longer than the caller takes.
    TooBig,
    /// The answer to the upgrade wasn't one.
    NotWebSocket,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

pub const Opcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10, _ };

/// What a client masks its frames with.
pub const Masks = union(enum) {
    fixed: [4]u8,
    random: std.Random.DefaultPrng,

    fn next(m: *Masks) [4]u8 {
        return switch (m.*) {
            .fixed => |f| f,
            .random => |*r| blk: {
                var b: [4]u8 = undefined;
                r.random().bytes(&b);
                break :blk b;
            },
        };
    }
};

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// What the server answers to Sec-WebSocket-Key `key`.
pub fn acceptKey(buf: *[28]u8, key: []const u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(buf, &digest);
}

/// One whole frame, masked with `mask`, as a client sends it.
pub fn writeFrame(w: *Io.Writer, op: Opcode, payload: []const u8, mask: [4]u8) Io.Writer.Error!void {
    try w.writeByte(0x80 | @as(u8, @intFromEnum(op)));
    if (payload.len <= 125) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    var chunk: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < payload.len) {
        const n = @min(chunk.len, payload.len - i);
        for (chunk[0..n], payload[i..][0..n], 0..) |*c, p, j| c.* = p ^ mask[(i + j) % 4];
        try w.writeAll(chunk[0..n]);
        i += n;
    }
}

fn take(r: *Io.Reader) Error!u8 {
    return r.takeByte() catch |e| switch (e) {
        error.EndOfStream => error.Closed,
        error.ReadFailed => error.ReadFailed,
    };
}

fn fill(r: *Io.Reader, dest: []u8) Error!void {
    r.readSliceAll(dest) catch |e| return switch (e) {
        error.EndOfStream => error.Closed,
        error.ReadFailed => error.ReadFailed,
    };
}

/// The next text or binary message, put together from its fragments into
/// `out` (at most `max` bytes). A ping between is answered on `w`, a pong
/// skipped; a close is answered and ends it with error.Closed.
pub fn readMessage(r: *Io.Reader, w: *Io.Writer, out: *std.ArrayList(u8), gpa: Allocator, max: usize, masks: *Masks) Error!void {
    out.clearRetainingCapacity();
    var started = false;
    while (true) {
        const b0 = try take(r);
        const b1 = try take(r);
        // no extension was agreed, and a server's frames are never masked
        if (b0 & 0x70 != 0 or b1 & 0x80 != 0) return error.Protocol;
        const fin = b0 & 0x80 != 0;
        const op: Opcode = @enumFromInt(b0 & 0x0f);
        var len: u64 = b1 & 0x7f;
        if (len == 126) {
            var b: [2]u8 = undefined;
            try fill(r, &b);
            len = std.mem.readInt(u16, &b, .big);
        } else if (len == 127) {
            var b: [8]u8 = undefined;
            try fill(r, &b);
            len = std.mem.readInt(u64, &b, .big);
        }
        switch (op) {
            .ping, .pong, .close => {
                if (!fin or len > 125) return error.Protocol;
                var ctl: [125]u8 = undefined;
                const body = ctl[0..@intCast(len)];
                try fill(r, body);
                if (op == .ping) {
                    try writeFrame(w, .pong, body, masks.next());
                    try w.flush();
                } else if (op == .close) {
                    writeFrame(w, .close, body[0..@min(body.len, 2)], masks.next()) catch {};
                    w.flush() catch {};
                    return error.Closed;
                }
                continue;
            },
            .text, .binary => {
                if (started) return error.Protocol;
                started = true;
            },
            .continuation => if (!started) return error.Protocol,
            _ => return error.Protocol,
        }
        if (len > max - out.items.len) return error.TooBig;
        const old = out.items.len;
        try out.resize(gpa, old + @as(usize, @intCast(len)));
        try fill(r, out.items[old..]);
        if (fin) return;
    }
}

/// A WebSocket to a server at an http or https address.
pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    client: http.Client,
    raw: *http.Conn,
    msg: std.ArrayList(u8) = .empty,
    masks: Masks,
    /// The longest message taken.
    max: usize = 64 << 20,

    /// Connects to `url` and upgrades `path` (as "/api/websocket"), each
    /// step within `timeout_ms`.
    pub fn open(gpa: Allocator, io: Io, url: []const u8, path: []const u8, timeout_ms: u32) !*Conn {
        const target = http.Target.parse(url) catch return error.BadUrl;
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        var seed: [8]u8 = undefined;
        io.randomSecure(&seed) catch {};
        c.* = .{ .gpa = gpa, .io = io, .client = .init(gpa, io, target), .raw = undefined, .masks = .{ .random = .init(std.mem.readInt(u64, &seed, .little)) } };
        c.client.user_agent = "homemcp";
        errdefer c.client.deinit();
        c.raw = try c.client.openRaw(.{ .idle_ms = timeout_ms, .total_ms = timeout_ms * 2 });
        errdefer c.client.closeRaw(c.raw);
        var nonce: [16]u8 = undefined;
        io.randomSecure(&nonce) catch c.masks.random.random().bytes(&nonce);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &nonce);
        const w = c.raw.out();
        w.print("GET {s}{s} HTTP/1.1\r\n", .{ target.prefix, path }) catch return error.Closed;
        http.writeHost(w, target) catch return error.Closed;
        w.print("\r\nUser-Agent: homemcp\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{key}) catch return error.Closed;
        c.raw.flush() catch return error.Closed;
        const head_bytes = c.raw.reader.receiveHead() catch |e| return switch (e) {
            error.HttpHeadersOversize => error.NotWebSocket,
            else => if (c.raw.s.timed_out) error.Timeout else error.Closed,
        };
        const head = std.http.Client.Response.Head.parse(head_bytes) catch return error.NotWebSocket;
        if (head.status != .switching_protocols) return error.NotWebSocket;
        var want_buf: [28]u8 = undefined;
        const want = acceptKey(&want_buf, key);
        var accepted = false;
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-accept")) accepted = std.mem.eql(u8, std.mem.trim(u8, h.value, " "), want);
        }
        if (!accepted) return error.NotWebSocket;
        return c;
    }

    /// Says goodbye (a close frame), then closes.
    pub fn close(c: *Conn) void {
        writeFrame(c.raw.out(), .close, &.{ 0x03, 0xe8 }, c.masks.next()) catch {};
        c.raw.flush() catch {};
        c.client.closeRaw(c.raw);
        c.client.deinit();
        c.msg.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    pub fn send(c: *Conn, text: []const u8) !void {
        c.raw.s.setLimits(30_000, null);
        writeFrame(c.raw.out(), .text, text, c.masks.next()) catch return error.Closed;
        c.raw.flush() catch return error.Closed;
    }

    /// The next message, waiting at most `wait_ms` for it to begin; null
    /// when none did. Valid until the next call. Once it began, each read
    /// of it may take 30 s.
    pub fn next(c: *Conn, wait_ms: u32) !?[]const u8 {
        if (!(c.raw.readable(wait_ms) catch return error.Closed)) return null;
        c.raw.s.setLimits(30_000, null);
        readMessage(c.raw.in(), c.raw.out(), &c.msg, c.gpa, c.max, &c.masks) catch |e| {
            if (c.raw.s.timed_out) return error.Timeout;
            return e;
        };
        c.raw.flush() catch return error.Closed;
        return c.msg.items;
    }
};

const t = std.testing;

test "the accept key, as in RFC 6455" {
    var b: [28]u8 = undefined;
    try t.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", acceptKey(&b, "dGhlIHNhbXBsZSBub25jZQ=="));
}

test "a client's frames are masked; lengths take 7, 16 or 64 bits" {
    var buf: [80_000]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeFrame(&w, .text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    // RFC 6455, 5.7: a single-frame masked text message
    try t.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());
    w = .fixed(&buf);
    try writeFrame(&w, .text, &@as([300]u8, @splat('x')), .{ 0, 0, 0, 0 });
    try t.expectEqualSlices(u8, &.{ 0x81, 0x80 | 126, 0x01, 0x2c }, w.buffered()[0..4]);
    w = .fixed(&buf);
    try writeFrame(&w, .binary, &@as([70_000]u8, @splat('y')), .{ 0, 0, 0, 0 });
    try t.expectEqualSlices(u8, &.{ 0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70 }, w.buffered()[0..10]);
}

test "a message in fragments, a ping between them answered" {
    // from a server: never masked
    const zs: [126]u8 = @splat('z');
    const in_bytes = [_]u8{ 0x01, 0x03, 'H', 'e', 'l' } ++ [_]u8{ 0x89, 0x01, 'x' } ++ [_]u8{ 0x80, 0x02, 'l', 'o' } ++
        [_]u8{ 0x81, 126, 0x00, 0x7e } ++ zs ++ [_]u8{ 0x88, 0x02, 0x03, 0xe8 };
    var r: Io.Reader = .fixed(&in_bytes);
    var out_buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out_buf);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(t.allocator);
    var masks: Masks = .{ .fixed = .{ 1, 2, 3, 4 } };
    try readMessage(&r, &w, &msg, t.allocator, 1 << 20, &masks);
    try t.expectEqualStrings("Hello", msg.items);
    // the pong carries the ping's data, masked
    try t.expectEqualSlices(u8, &.{ 0x8a, 0x81, 1, 2, 3, 4, 'x' ^ 1 }, w.buffered());
    try readMessage(&r, &w, &msg, t.allocator, 1 << 20, &masks);
    try t.expectEqual(126, msg.items.len);
    try t.expectError(error.Closed, readMessage(&r, &w, &msg, t.allocator, 1 << 20, &masks));
    // too big for what the caller takes
    var r2: Io.Reader = .fixed(&([_]u8{ 0x81, 126, 0x00, 0x7e } ++ zs));
    try t.expectError(error.TooBig, readMessage(&r2, &w, &msg, t.allocator, 100, &masks));
    // a server must not mask
    var r3: Io.Reader = .fixed(&[_]u8{ 0x81, 0x81, 1, 2, 3, 4, 'a' });
    try t.expectError(error.Protocol, readMessage(&r3, &w, &msg, t.allocator, 100, &masks));
}

test "talks to homemcp-sim's Home Assistant: upgrade, auth, a command" {
    const sim = try @import("sim.zig").HaSim.start(std.heap.page_allocator, t.io, 0, "sim-token");
    defer sim.stop();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{sim.port});
    const c = try Conn.open(t.allocator, t.io, url, "/api/websocket", 5000);
    defer c.close();
    try t.expect(std.mem.indexOf(u8, (try c.next(5000)).?, "\"auth_required\"") != null);
    try c.send("{\"type\":\"auth\",\"access_token\":\"sim-token\"}");
    try t.expect(std.mem.indexOf(u8, (try c.next(5000)).?, "\"auth_ok\"") != null);
    // nothing comes unasked: a short wait ends empty
    try t.expect((try c.next(50)) == null);
    try c.send("{\"id\":1,\"type\":\"ping\"}");
    try t.expectEqualStrings("{\"id\":1,\"type\":\"pong\"}", (try c.next(5000)).?);
    // a long message, in one piece
    try c.send("{\"id\":2,\"type\":\"get_states\"}");
    const states = (try c.next(5000)).?;
    try t.expect(states.len > 4000 and std.mem.indexOf(u8, states, "person.anna") != null);
}

test "a server that doesn't switch protocols is named" {
    const sim = try @import("sim.zig").HaSim.start(std.heap.page_allocator, t.io, 0, "sim-token");
    defer sim.stop();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{sim.port});
    try t.expectError(error.NotWebSocket, Conn.open(t.allocator, t.io, url, "/api/nothing-here", 5000));
}

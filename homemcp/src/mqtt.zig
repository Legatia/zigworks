//! A small MQTT 3.1.1 client: connect, subscribe and publish at QoS 0,
//! keep-alive pings, and the messages the broker sends. One thread reads;
//! any thread may publish (writes are serialised).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sock = @import("sock.zig");

pub const Message = struct { topic: []const u8, payload: []const u8, retained: bool };

pub const max_packet = 8 << 20;

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    s: sock.Socket,
    rbuf: [16 * 1024]u8,
    wbuf: [16 * 1024]u8,
    write_lock: Io.Mutex,
    next_id: u16,
    /// the body of the last packet read
    body: std.ArrayList(u8),
    keepalive_s: u16,
    last_write_ns: i128,

    /// Connects and logs in. `c` must not move afterwards.
    pub fn connect(c: *Client, gpa: Allocator, io: Io, host: []const u8, port: u16, client_id: []const u8, user: ?[]const u8, pass: ?[]const u8, keepalive_s: u16) !void {
        const h = sock.connect(io, host, port, 5000) catch return error.ConnectFailed;
        c.* = .{
            .gpa = gpa,
            .io = io,
            .s = undefined,
            .rbuf = undefined,
            .wbuf = undefined,
            .write_lock = .init,
            .next_id = 1,
            .body = .empty,
            .keepalive_s = keepalive_s,
            .last_write_ns = 0,
        };
        c.s.init(io, h, &c.rbuf, &c.wbuf, 10_000);
        errdefer c.close();
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(gpa);
        try putStr(&p, gpa, "MQTT");
        try p.append(gpa, 4); // protocol level: 3.1.1
        var flags: u8 = 0x02; // clean session
        if (user != null) flags |= 0x80;
        if (pass != null) flags |= 0x40;
        try p.append(gpa, flags);
        try putU16(&p, gpa, keepalive_s);
        try putStr(&p, gpa, client_id);
        if (user) |u| try putStr(&p, gpa, u);
        if (pass) |pw| try putStr(&p, gpa, pw);
        try c.send(0x10, p.items);
        if (!try c.s.readable(5000)) return error.NoConnack;
        const pkt = try c.readPacket();
        if (pkt.kind != 2 or pkt.body.len < 2) return error.NoConnack;
        if (pkt.body[1] != 0) return switch (pkt.body[1]) {
            4, 5 => error.NotAuthorized,
            else => error.Refused,
        };
    }

    pub fn close(c: *Client) void {
        c.s.close();
        c.body.deinit(c.gpa);
    }

    /// Says goodbye (DISCONNECT); close() still has to follow.
    pub fn bye(c: *Client) void {
        c.send(0xE0, &.{}) catch {};
    }

    pub fn subscribe(c: *Client, filter: []const u8) !void {
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(c.gpa);
        try putU16(&p, c.gpa, c.takeId());
        try putStr(&p, c.gpa, filter);
        try p.append(c.gpa, 0); // QoS 0
        try c.send(0x82, p.items);
    }

    pub fn publish(c: *Client, topic: []const u8, payload: []const u8, retain: bool) !void {
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(c.gpa);
        try putStr(&p, c.gpa, topic);
        try p.appendSlice(c.gpa, payload);
        try c.send(0x30 | @as(u8, if (retain) 1 else 0), p.items);
    }

    /// A PINGREQ when nothing has been sent for half the keep-alive time.
    pub fn keepAlive(c: *Client) !void {
        if (c.keepalive_s == 0) return;
        const now = sock.nowNs(c.io);
        if (now - c.last_write_ns >= @divTrunc(@as(i128, c.keepalive_s) * std.time.ns_per_s, 2)) try c.send(0xC0, &.{});
    }

    /// The next message, waiting up to `timeout_ms`; null when none came
    /// (or the packet was not a message). Valid until the next call.
    pub fn next(c: *Client, timeout_ms: u32) !?Message {
        if (!try c.s.readable(timeout_ms)) return null;
        const pkt = try c.readPacket();
        if (pkt.kind != 3) return null; // SUBACK, PINGRESP
        const b = pkt.body;
        if (b.len < 2) return error.BadPacket;
        const tlen = std.mem.readInt(u16, b[0..2], .big);
        if (2 + tlen > b.len) return error.BadPacket;
        var rest = b[2 + tlen ..];
        const qos = (pkt.flags >> 1) & 3;
        if (qos > 0) {
            if (rest.len < 2) return error.BadPacket;
            const id = std.mem.readInt(u16, rest[0..2], .big);
            rest = rest[2..];
            if (qos == 1) {
                var ack: [2]u8 = undefined;
                std.mem.writeInt(u16, &ack, id, .big);
                try c.send(0x40, &ack); // PUBACK
            }
        }
        return .{ .topic = b[2 .. 2 + tlen], .payload = rest, .retained = pkt.flags & 1 != 0 };
    }

    const Packet = struct { kind: u8, flags: u8, body: []u8 };

    fn readPacket(c: *Client) !Packet {
        const r = &c.s.reader;
        const h = r.takeByte() catch return error.ConnectionClosed;
        var len: usize = 0;
        var shift: u5 = 0;
        while (true) {
            const b = r.takeByte() catch return error.ConnectionClosed;
            len |= @as(usize, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            if (shift == 21) return error.BadPacket;
            shift += 7;
        }
        if (len > max_packet) return error.PacketTooBig;
        try c.body.resize(c.gpa, len);
        r.readSliceAll(c.body.items) catch return error.ConnectionClosed;
        return .{ .kind = h >> 4, .flags = h & 0x0f, .body = c.body.items };
    }

    fn send(c: *Client, header: u8, body: []const u8) !void {
        c.write_lock.lockUncancelable(c.io);
        defer c.write_lock.unlock(c.io);
        var hdr: [5]u8 = undefined;
        hdr[0] = header;
        const n = encodeLength(hdr[1..], body.len);
        const w = &c.s.writer;
        w.writeAll(hdr[0 .. 1 + n]) catch return error.ConnectionClosed;
        w.writeAll(body) catch return error.ConnectionClosed;
        w.flush() catch return error.ConnectionClosed;
        c.last_write_ns = sock.nowNs(c.io);
    }

    fn takeId(c: *Client) u16 {
        const id = c.next_id;
        c.next_id +%= 1;
        if (c.next_id == 0) c.next_id = 1;
        return id;
    }
};

/// MQTT's remaining length: 7 bits a byte, the high bit saying more follow.
pub fn encodeLength(out: []u8, len: usize) usize {
    var x = len;
    var i: usize = 0;
    while (true) {
        var b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x > 0) b |= 0x80;
        out[i] = b;
        i += 1;
        if (x == 0) return i;
    }
}

fn putU16(p: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try p.appendSlice(gpa, &b);
}

fn putStr(p: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try putU16(p, gpa, @intCast(s.len));
    try p.appendSlice(gpa, s);
}

/// Whether `topic` matches `filter` (with + and # wildcards).
pub fn matches(filter: []const u8, topic: []const u8) bool {
    var fi = std.mem.splitScalar(u8, filter, '/');
    var ti = std.mem.splitScalar(u8, topic, '/');
    while (fi.next()) |f| {
        if (std.mem.eql(u8, f, "#")) return true;
        const t = ti.next() orelse return false;
        if (!std.mem.eql(u8, f, "+") and !std.mem.eql(u8, f, t)) return false;
    }
    return ti.next() == null;
}

test "remaining length, as in the MQTT spec's examples" {
    var b: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x00}, b[0..encodeLength(&b, 0)]);
    try std.testing.expectEqualSlices(u8, &.{0x7f}, b[0..encodeLength(&b, 127)]);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, b[0..encodeLength(&b, 128)]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x7f }, b[0..encodeLength(&b, 16_383)]);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, b[0..encodeLength(&b, 16_384)]);
}

test "topic filters" {
    try std.testing.expect(matches("zigbee2mqtt/#", "zigbee2mqtt/Hall light/set"));
    try std.testing.expect(matches("zigbee2mqtt/+/set", "zigbee2mqtt/Hall light/set"));
    try std.testing.expect(!matches("zigbee2mqtt/+/set", "zigbee2mqtt/a/b/set"));
    try std.testing.expect(!matches("zigbee2mqtt/+", "zigbee2mqtt/a/b"));
    try std.testing.expect(matches("a/b", "a/b"));
}

//! A small D-Bus client: enough to call methods on the accessibility bus
//! and read what they answer. Little-endian only, one call at a time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");

pub const Error = error{ Refused, Timeout, Malformed, Remote, Closed, OutOfMemory };

/// Builds the arguments of a call. Everything is aligned as D-Bus wants,
/// counted from the start of the body.
pub const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    pub fn deinit(w: *Writer) void {
        w.bytes.deinit(w.gpa);
    }

    fn pad(w: *Writer, to: usize) !void {
        while (w.bytes.items.len % to != 0) try w.bytes.append(w.gpa, 0);
    }

    pub fn u32_(w: *Writer, v: u32) !void {
        try w.pad(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.bytes.appendSlice(w.gpa, &b);
    }

    pub fn i32_(w: *Writer, v: i32) !void {
        try w.u32_(@bitCast(v));
    }

    pub fn string(w: *Writer, s: []const u8) !void {
        try w.u32_(@intCast(s.len));
        try w.bytes.appendSlice(w.gpa, s);
        try w.bytes.append(w.gpa, 0);
    }

    fn signature(w: *Writer, s: []const u8) !void {
        try w.bytes.append(w.gpa, @intCast(s.len));
        try w.bytes.appendSlice(w.gpa, s);
        try w.bytes.append(w.gpa, 0);
    }

    fn byte(w: *Writer, b: u8) !void {
        try w.bytes.append(w.gpa, b);
    }
};

/// Reads the body of an answer.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn pad(r: *Reader, to: usize) void {
        r.pos = (r.pos + to - 1) / to * to;
    }

    pub fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.data.len) return error.Malformed;
        defer r.pos += 1;
        return r.data[r.pos];
    }

    pub fn uint(r: *Reader) Error!u32 {
        r.pad(4);
        if (r.pos + 4 > r.data.len) return error.Malformed;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
    }

    pub fn int(r: *Reader) Error!i32 {
        return @bitCast(try r.uint());
    }

    /// A string or an object path.
    pub fn string(r: *Reader) Error![]const u8 {
        const len = try r.uint();
        if (r.pos + len + 1 > r.data.len) return error.Malformed;
        defer r.pos += len + 1;
        return r.data[r.pos..][0..len];
    }

    pub fn signature(r: *Reader) Error![]const u8 {
        const len = try r.byte();
        if (r.pos + len + 1 > r.data.len) return error.Malformed;
        defer r.pos += @as(usize, len) + 1;
        return r.data[r.pos..][0..len];
    }

    /// The start of an array whose elements are aligned to `elem_align`:
    /// returns where the array ends.
    pub fn array(r: *Reader, elem_align: usize) Error!usize {
        const len = try r.uint();
        r.pad(elem_align);
        if (r.pos + len > r.data.len) return error.Malformed;
        return r.pos + len;
    }

    /// The start of a struct.
    pub fn structure(r: *Reader) void {
        r.pad(8);
    }
};

pub const Reply = struct {
    body: []u8,
    signature: []u8,

    pub fn deinit(rep: Reply, gpa: Allocator) void {
        gpa.free(rep.body);
        gpa.free(rep.signature);
    }

    pub fn reader(rep: *const Reply) Reader {
        return .{ .data = rep.body };
    }
};

pub const Conn = struct {
    gpa: Allocator,
    fd: sys.fd_t,
    serial: u32 = 0,
    timeout_ms: i32 = 3000,

    /// Connects to the bus at socket `path` as user `uid` (as the bus's own
    /// side sees the caller) and says hello.
    pub fn connect(gpa: Allocator, path: []const u8, uid: u32) Error!Conn {
        const fd = sys.connectUnix(path) catch return error.Refused;
        var c: Conn = .{ .gpa = gpa, .fd = fd };
        errdefer c.close();
        // "AUTH EXTERNAL" with the uid's digits in hex
        var digits: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{uid}) catch unreachable;
        var line: [96]u8 = undefined;
        var len: usize = 0;
        const head = "\x00AUTH EXTERNAL ";
        @memcpy(line[0..head.len], head);
        len = head.len;
        for (text) |ch| {
            _ = std.fmt.bufPrint(line[len..], "{x:0>2}", .{ch}) catch unreachable;
            len += 2;
        }
        line[len] = '\r';
        line[len + 1] = '\n';
        sys.writeAll(fd, line[0 .. len + 2]) catch return error.Closed;
        var answer: [256]u8 = undefined;
        const n = try c.readSome(&answer);
        if (!std.mem.startsWith(u8, answer[0..n], "OK ")) return error.Refused;
        sys.writeAll(fd, "BEGIN\r\n") catch return error.Closed;
        const hello = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", "");
        hello.deinit(gpa);
        return c;
    }

    pub fn close(c: *Conn) void {
        sys.close(c.fd);
    }

    fn readSome(c: *Conn, buf: []u8) Error!usize {
        var items = [_]sys.PollItem{sys.pollIn(c.fd)};
        sys.poll(&items, c.timeout_ms);
        if (!sys.readable(items[0])) return error.Timeout;
        const n = sys.read(c.fd, buf) catch return error.Closed;
        if (n == 0) return error.Closed;
        return n;
    }

    fn readExact(c: *Conn, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) got += try c.readSome(buf[got..]);
    }

    /// Calls a method and returns what it answered. `signature` and `body`
    /// are the arguments (see `Writer`); both empty for none. An error
    /// answer is `error.Remote`.
    pub fn call(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) Error!Reply {
        c.serial += 1;
        const serial = c.serial;
        var w: Writer = .{ .gpa = c.gpa };
        defer w.deinit();
        try w.bytes.appendSlice(c.gpa, &.{ 'l', 1, 0, 1 });
        try w.u32_(@intCast(body.len));
        try w.u32_(serial);
        try w.u32_(0); // the length of the fields, filled in below
        const fields_start = w.bytes.items.len;
        const strings = [_]struct { code: u8, sig: u8, value: []const u8 }{
            .{ .code = 1, .sig = 'o', .value = path },
            .{ .code = 2, .sig = 's', .value = iface },
            .{ .code = 3, .sig = 's', .value = member },
            .{ .code = 6, .sig = 's', .value = dest },
        };
        for (strings) |f| {
            try w.pad(8);
            try w.byte(f.code);
            try w.signature(&.{f.sig});
            try w.string(f.value);
        }
        if (signature.len > 0) {
            try w.pad(8);
            try w.byte(8);
            try w.signature("g");
            try w.signature(signature);
        }
        std.mem.writeInt(u32, w.bytes.items[12..16], @intCast(w.bytes.items.len - fields_start), .little);
        try w.pad(8);
        try w.bytes.appendSlice(c.gpa, body);
        sys.writeAll(c.fd, w.bytes.items) catch return error.Closed;

        // answers to other things and signals go by until ours comes
        while (true) {
            var head: [16]u8 = undefined;
            try c.readExact(&head);
            if (head[0] != 'l') return error.Malformed;
            const kind = head[1];
            const body_len = std.mem.readInt(u32, head[4..8], .little);
            const fields_len = std.mem.readInt(u32, head[12..16], .little);
            if (fields_len > 1 << 20 or body_len > 64 << 20) return error.Malformed;
            const padded = (fields_len + 7) / 8 * 8;
            const rest = try c.gpa.alloc(u8, padded + body_len);
            defer c.gpa.free(rest);
            try c.readExact(rest);
            // the fields are aligned from the start of the message
            var reply_serial: u32 = 0;
            var sig: []const u8 = "";
            var r: Reader = .{ .data = rest[0..fields_len], .pos = 0 };
            while (r.pos < fields_len) {
                r.pad(8);
                if (r.pos >= fields_len) break;
                const code = try r.byte();
                const vsig = try r.signature();
                if (vsig.len != 1) return error.Malformed;
                switch (vsig[0]) {
                    's', 'o' => _ = try r.string(),
                    'g' => {
                        const g = try r.signature();
                        if (code == 8) sig = g;
                    },
                    'u' => {
                        const v = try r.uint();
                        if (code == 5) reply_serial = v;
                    },
                    else => return error.Malformed,
                }
            }
            if ((kind != 2 and kind != 3) or reply_serial != serial) continue;
            if (kind == 3) return error.Remote;
            const out_body = try c.gpa.dupe(u8, rest[padded..]);
            errdefer c.gpa.free(out_body);
            return .{ .body = out_body, .signature = try c.gpa.dupe(u8, sig) };
        }
    }
};

const testing = std.testing;

test "arguments are aligned and read back" {
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.string("abc");
    try w.u32_(7);
    try w.string("");
    try w.i32_(-2);
    // "abc": 4 + 3 + 1 = 8; 7 at 8; "": length at 12, zero at 16; -2 after padding at 20
    try testing.expectEqual(@as(usize, 24), w.bytes.items.len);
    var r: Reader = .{ .data = w.bytes.items };
    try testing.expectEqualStrings("abc", try r.string());
    try testing.expectEqual(@as(u32, 7), try r.uint());
    try testing.expectEqualStrings("", try r.string());
    try testing.expectEqual(@as(i32, -2), try r.int());
    try testing.expectError(error.Malformed, r.uint());
}

test "an array of structs of two strings, as GetChildren answers" {
    // a(so) with one element (":1.0", "/a"): length, padding to 8, then the struct
    var w: Writer = .{ .gpa = testing.allocator };
    defer w.deinit();
    try w.u32_(0);
    try w.pad(8);
    const start = w.bytes.items.len;
    try w.string(":1.0");
    try w.string("/a");
    std.mem.writeInt(u32, w.bytes.items[0..4], @intCast(w.bytes.items.len - start), .little);
    var r: Reader = .{ .data = w.bytes.items };
    const end = try r.array(8);
    try testing.expectEqual(w.bytes.items.len, end);
    r.structure();
    try testing.expectEqualStrings(":1.0", try r.string());
    try testing.expectEqualStrings("/a", try r.string());
    try testing.expectEqual(end, r.pos);
}

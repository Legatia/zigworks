//! The Wayland wire format: a message is an object id, a word holding its
//! size and opcode, and arguments in 32-bit words. File descriptors travel
//! beside the bytes, not in them.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const header_len = 8;
pub const max_message = 4096 * 4;

pub const Header = struct {
    object: u32,
    opcode: u16,
    /// Whole message, header included.
    size: u16,
};

/// The header at the start of `bytes`, or null if fewer than 8 are there.
pub fn header(bytes: []const u8) ?Header {
    if (bytes.len < header_len) return null;
    const second = std.mem.readInt(u32, bytes[4..8], .little);
    return .{
        .object = std.mem.readInt(u32, bytes[0..4], .little),
        .opcode = @truncate(second),
        .size = @truncate(second >> 16),
    };
}

/// A 24.8 fixed-point number.
pub const Fixed = struct {
    raw: i32,

    pub fn from(v: f64) Fixed {
        return .{ .raw = @intFromFloat(@round(v * 256.0)) };
    }

    pub fn toFloat(f: Fixed) f64 {
        return @as(f64, @floatFromInt(f.raw)) / 256.0;
    }
};

/// An array argument.
pub const Array = struct { bytes: []const u8 };

/// A file descriptor argument: goes into the side list.
pub const Fd = struct { fd: i32 };

pub const ReadError = error{Malformed};

/// Reads the arguments of one message (the part after the header).
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn uint(r: *Reader) ReadError!u32 {
        if (r.pos + 4 > r.data.len) return error.Malformed;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
    }

    pub fn int(r: *Reader) ReadError!i32 {
        return @bitCast(try r.uint());
    }

    pub fn fixed(r: *Reader) ReadError!Fixed {
        return .{ .raw = try r.int() };
    }

    /// A string without its closing zero; null for the null string.
    pub fn string(r: *Reader) ReadError!?[]const u8 {
        const len = try r.uint();
        if (len == 0) return null;
        const padded = (len + 3) & ~@as(u32, 3);
        if (r.pos + padded > r.data.len) return error.Malformed;
        defer r.pos += padded;
        return r.data[r.pos..][0 .. len - 1];
    }

    pub fn array(r: *Reader) ReadError![]const u8 {
        const len = try r.uint();
        const padded = (len + 3) & ~@as(u32, 3);
        if (r.pos + padded > r.data.len) return error.Malformed;
        defer r.pos += padded;
        return r.data[r.pos..][0..len];
    }
};

/// Messages waiting to be sent to one peer, and the descriptors that go
/// with them.
pub const Out = struct {
    bytes: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(i32) = .empty,
    /// Set when memory ran out: the peer is to be dropped.
    failed: bool = false,

    pub fn deinit(o: *Out, gpa: Allocator) void {
        o.bytes.deinit(gpa);
        o.fds.deinit(gpa);
    }

    /// Appends one message. `args` is a tuple of u32, i32, Fixed,
    /// []const u8 (a string), ?[]const u8, Array and Fd.
    pub fn msg(o: *Out, gpa: Allocator, object: u32, opcode: u16, args: anytype) void {
        o.tryMsg(gpa, object, opcode, args) catch {
            o.failed = true;
        };
    }

    fn tryMsg(o: *Out, gpa: Allocator, object: u32, opcode: u16, args: anytype) !void {
        const start = o.bytes.items.len;
        errdefer o.bytes.shrinkRetainingCapacity(start);
        try o.word(gpa, object);
        try o.word(gpa, 0);
        inline for (args) |arg| {
            switch (@TypeOf(arg)) {
                u32 => try o.word(gpa, arg),
                i32 => try o.word(gpa, @bitCast(arg)),
                Fixed => try o.word(gpa, @bitCast(arg.raw)),
                Fd => try o.fds.append(gpa, arg.fd),
                Array => try o.padded(gpa, arg.bytes, false),
                ?[]const u8 => if (arg) |s| try o.padded(gpa, s, true) else try o.word(gpa, 0),
                else => try o.padded(gpa, arg, true),
            }
        }
        const size = o.bytes.items.len - start;
        if (size > max_message) return error.TooBig;
        std.mem.writeInt(u32, o.bytes.items[start + 4 ..][0..4], (@as(u32, @intCast(size)) << 16) | opcode, .little);
    }

    fn word(o: *Out, gpa: Allocator, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try o.bytes.appendSlice(gpa, &b);
    }

    fn padded(o: *Out, gpa: Allocator, bytes: []const u8, zero: bool) !void {
        const len = bytes.len + @intFromBool(zero);
        try o.word(gpa, @intCast(len));
        try o.bytes.appendSlice(gpa, bytes);
        const total = (len + 3) & ~@as(usize, 3);
        try o.bytes.appendNTimes(gpa, 0, total - bytes.len);
    }
};

const testing = std.testing;

test "a message round trip: header, numbers, strings, arrays" {
    var out: Out = .{};
    defer out.deinit(testing.allocator);
    out.msg(testing.allocator, 3, 7, .{ @as(u32, 42), @as(i32, -5), Fixed.from(1.5), @as([]const u8, "hey"), Array{ .bytes = &.{ 1, 2, 3, 4, 5 } }, @as(?[]const u8, null) });
    try testing.expect(!out.failed);
    const h = header(out.bytes.items).?;
    try testing.expectEqual(@as(u32, 3), h.object);
    try testing.expectEqual(@as(u16, 7), h.opcode);
    try testing.expectEqual(out.bytes.items.len, h.size);
    try testing.expectEqual(@as(usize, 0), h.size % 4);
    var r: Reader = .{ .data = out.bytes.items[header_len..] };
    try testing.expectEqual(@as(u32, 42), try r.uint());
    try testing.expectEqual(@as(i32, -5), try r.int());
    try testing.expectEqual(@as(f64, 1.5), (try r.fixed()).toFloat());
    try testing.expectEqualStrings("hey", (try r.string()).?);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, try r.array());
    try testing.expectEqual(@as(?[]const u8, null), try r.string());
    try testing.expectEqual(r.data.len, r.pos);
    try testing.expectError(error.Malformed, r.uint());
}

test "a string that fills its last word still gets a closing zero" {
    var out: Out = .{};
    defer out.deinit(testing.allocator);
    out.msg(testing.allocator, 1, 0, .{@as([]const u8, "abcd")});
    // header 8 + length 4 + "abcd\0" padded to 8
    try testing.expectEqual(@as(usize, 20), out.bytes.items.len);
    var r: Reader = .{ .data = out.bytes.items[header_len..] };
    try testing.expectEqualStrings("abcd", (try r.string()).?);
}

test "descriptors go to the side list and a cut message is refused" {
    var out: Out = .{};
    defer out.deinit(testing.allocator);
    out.msg(testing.allocator, 5, 0, .{ @as(u32, 1), Fd{ .fd = 9 }, @as(u32, 2) });
    try testing.expectEqual(@as(usize, 16), out.bytes.items.len);
    try testing.expectEqualSlices(i32, &.{9}, out.fds.items);
    var r: Reader = .{ .data = &.{ 9, 0, 0, 0, 1, 2 } };
    try testing.expectError(error.Malformed, r.string());
    try testing.expectEqual(@as(?Header, null), header(&.{ 1, 2, 3 }));
}

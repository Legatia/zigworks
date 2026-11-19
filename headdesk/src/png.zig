//! Writes a picture as a PNG file. The pixel data is run-length packed by
//! hand into fixed-Huffman deflate blocks: no general compressor, but flat
//! areas (most of a desktop) shrink to almost nothing.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// `pixels` are 0xAARRGGBB, `width * height` of them; alpha is dropped.
pub fn encode(gpa: Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 }; // 8 bits, RGB, deflate, no filter set, not interlaced
    try chunk(gpa, &out, "IHDR", &ihdr);

    // Each row: filter type 2 (difference to the row above), then RGB.
    // Rows that repeat become runs of zeros.
    const stride = @as(usize, width) * 3 + 1;
    const raw = try gpa.alloc(u8, stride * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const row = raw[y * stride ..][0..stride];
        row[0] = 2;
        for (0..width) |x| {
            const p = pixels[y * width + x];
            const above: u32 = if (y == 0) 0 else pixels[(y - 1) * width + x];
            row[1 + x * 3] = @as(u8, @truncate(p >> 16)) -% @as(u8, @truncate(above >> 16));
            row[2 + x * 3] = @as(u8, @truncate(p >> 8)) -% @as(u8, @truncate(above >> 8));
            row[3 + x * 3] = @as(u8, @truncate(p)) -% @as(u8, @truncate(above));
        }
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    try deflate(gpa, &z, raw);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

const Bits = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    acc: u64 = 0,
    n: u6 = 0,

    /// `count` bits of `value`, lowest first.
    fn put(b: *Bits, value: u32, count: u6) !void {
        b.acc |= @as(u64, value) << b.n;
        b.n += count;
        while (b.n >= 8) {
            try b.out.append(b.gpa, @truncate(b.acc));
            b.acc >>= 8;
            b.n -= 8;
        }
    }

    /// A Huffman code: `count` bits, highest first.
    fn code(b: *Bits, value: u32, count: u6) !void {
        var rev: u32 = 0;
        for (0..count) |i| rev |= ((value >> @intCast(i)) & 1) << @intCast(count - 1 - i);
        try b.put(rev, count);
    }

    /// A literal byte or a length symbol (0..287) in the fixed code.
    fn symbol(b: *Bits, s: u32) !void {
        if (s < 144) return b.code(0x30 + s, 8);
        if (s < 256) return b.code(0x190 + (s - 144), 9);
        if (s < 280) return b.code(s - 256, 7);
        return b.code(0xC0 + (s - 280), 8);
    }

    fn flush(b: *Bits) !void {
        if (b.n > 0) try b.out.append(b.gpa, @truncate(b.acc));
        b.acc = 0;
        b.n = 0;
    }
};

/// One fixed-Huffman block. The only matches used are runs: a byte
/// repeated (distance 1) or a pixel repeated (distance 3).
fn deflate(gpa: Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    var b: Bits = .{ .gpa = gpa, .out = out };
    try b.put(1, 1); // last block
    try b.put(1, 2); // fixed codes
    var i: usize = 0;
    while (i < data.len) {
        var best: usize = 0;
        var dist: u32 = 0;
        for ([_]usize{ 1, 3 }) |d| {
            if (i < d) continue;
            var n: usize = 0;
            while (n < 258 and i + n < data.len and data[i + n] == data[i + n - d]) n += 1;
            if (n > best) {
                best = n;
                dist = @intCast(d);
            }
        }
        if (best >= 3) {
            try lengthCode(&b, @intCast(best));
            // distance codes are 5 bits: 1 is code 0, 3 is code 2
            try b.code(dist - 1, 5);
            i += best;
        } else {
            try b.symbol(data[i]);
            i += 1;
        }
    }
    try b.symbol(256);
    try b.flush();
}

fn lengthCode(b: *Bits, len: u32) !void {
    const bases = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const extra = [_]u3{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    var k: usize = bases.len - 1;
    while (bases[k] > len) k -= 1;
    try b.symbol(@intCast(257 + k));
    if (extra[k] > 0) try b.put(len - bases[k], extra[k]);
}

const testing = std.testing;

/// Inflates fixed-Huffman data made by `deflate` (test only).
fn inflate(gpa: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 3; // past the block header bits
    const bit = struct {
        fn get(d: []const u8, p: *usize) u32 {
            const v = (d[p.* / 8] >> @intCast(p.* % 8)) & 1;
            p.* += 1;
            return v;
        }
    }.get;
    const bases = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const extra = [_]u3{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    while (true) {
        var c: u32 = 0;
        for (0..7) |_| c = (c << 1) | bit(data, &pos);
        var sym: u32 = undefined;
        if (c <= 0x17) {
            sym = 256 + c;
        } else {
            c = (c << 1) | bit(data, &pos);
            if (c >= 0x30 and c <= 0xBF) {
                sym = c - 0x30;
            } else if (c >= 0xC0 and c <= 0xC7) {
                sym = 280 + (c - 0xC0);
            } else {
                c = (c << 1) | bit(data, &pos);
                sym = 144 + (c - 0x190);
            }
        }
        if (sym == 256) break;
        if (sym < 256) {
            try out.append(gpa, @intCast(sym));
            continue;
        }
        const k = sym - 257;
        var len: u32 = bases[k];
        for (0..extra[k]) |i| len += bit(data, &pos) << @intCast(i);
        var dc: u32 = 0;
        for (0..5) |_| dc = (dc << 1) | bit(data, &pos);
        const dist = dc + 1;
        for (0..len) |_| try out.append(gpa, out.items[out.items.len - dist]);
    }
    return out.toOwnedSlice(gpa);
}

test "the packed data inflates back to the rows" {
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(testing.allocator);
    var data: [3000]u8 = undefined;
    for (&data, 0..) |*d, i| d.* = if (i < 1000) 7 else if (i < 2000) @truncate(i % 3 * 40) else @truncate(i *% 2654435761 >> 7);
    try deflate(testing.allocator, &z, &data);
    const back = try inflate(testing.allocator, z.items);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, &data, back);
    // the flat and the repeating thirds pack well
    try testing.expect(z.items.len < 1400);
}

test "a PNG has its signature, size and three chunks, and flat pictures are small" {
    const w = 200;
    const h = 100;
    const px = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(px);
    @memset(px, 0xff336699);
    px[w * 50 + 7] = 0xffffffff;
    const file = try encode(testing.allocator, px, w, h);
    defer testing.allocator.free(file);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", file[0..8]);
    try testing.expectEqualSlices(u8, "IHDR", file[12..16]);
    try testing.expectEqual(@as(u32, w), std.mem.readInt(u32, file[16..20], .big));
    try testing.expectEqual(@as(u32, h), std.mem.readInt(u32, file[20..24], .big));
    try testing.expectEqualSlices(u8, "IEND", file[file.len - 8 .. file.len - 4]);
    try testing.expect(file.len < 2000);
}

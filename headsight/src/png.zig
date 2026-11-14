//! PNG writing without platform libraries (used where there is no ImageIO):
//! a region of a BGRA frame, box-downscaled so its long side is at most
//! `max_side`, written as 8-bit RGB with stored (uncompressed) deflate blocks.
const std = @import("std");
const frame = @import("frame.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;

/// Output size and scale for a w x h region whose long side must fit in max_side.
pub fn fitSize(w: u32, h: u32, max_side: u32) struct { w: u32, h: u32, scale: f64 } {
    const long = @max(w, h);
    if (long <= max_side or long == 0) return .{ .w = w, .h = h, .scale = 1 };
    const scale = @as(f64, @floatFromInt(max_side)) / @as(f64, @floatFromInt(long));
    const ow: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale))));
    const oh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale))));
    return .{ .w = ow, .h = oh, .scale = scale };
}

/// Writes `r` of `f` to `path`. Returns the scale (output pixels per source pixel).
pub fn write(alloc: std.mem.Allocator, path: []const u8, f: Frame, r: Rect, max_side: u32) !f64 {
    if (r.w == 0 or r.h == 0 or r.right() > f.w or r.bottom() > f.h) return error.BadRegion;
    const fit = fitSize(r.w, r.h, max_side);
    const row_len = fit.w * 3 + 1;
    const raw = try alloc.alloc(u8, @as(usize, row_len) * fit.h);
    defer alloc.free(raw);
    for (0..fit.h) |oy| {
        const row = raw[oy * row_len ..][0..row_len];
        row[0] = 0; // filter: none
        const y0 = oy * r.h / fit.h;
        const y1 = @max(y0 + 1, (oy + 1) * r.h / fit.h);
        for (0..fit.w) |ox| {
            const x0 = ox * r.w / fit.w;
            const x1 = @max(x0 + 1, (ox + 1) * r.w / fit.w);
            var sum = [3]u64{ 0, 0, 0 };
            for (y0..y1) |y| {
                const line = f.px[(r.y + y) * f.stride ..];
                for (x0..x1) |x| {
                    const p = line[(r.x + x) * 4 ..][0..4]; // B G R A
                    sum[0] += p[2];
                    sum[1] += p[1];
                    sum[2] += p[0];
                }
            }
            const n: u64 = (y1 - y0) * (x1 - x0);
            for (0..3) |i| row[1 + ox * 3 + i] = @intCast((sum[i] + n / 2) / n);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], fit.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], fit.h, .big);
    ihdr[8..13].* = .{ 8, 2, 0, 0, 0 };
    try chunk(alloc, &out, "IHDR", &ihdr);

    // zlib stream of stored deflate blocks
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(alloc);
    try z.appendSlice(alloc, &.{ 0x78, 0x01 });
    var rest: []const u8 = raw;
    while (true) {
        const n = @min(rest.len, 65535);
        const last = n == rest.len;
        try z.append(alloc, @intFromBool(last));
        var lens: [4]u8 = undefined;
        std.mem.writeInt(u16, lens[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(n)), .little);
        try z.appendSlice(alloc, &lens);
        try z.appendSlice(alloc, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(alloc, &adler);
    try chunk(alloc, &out, "IDAT", z.items);
    try chunk(alloc, &out, "IEND", "");

    var file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(out.items);
    return fit.scale;
}

fn chunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try out.appendSlice(alloc, &len);
    const start = out.items.len;
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, body);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(alloc, &crc);
}

// ---- tests ----

const testing = std.testing;

test "fit_size_keeps_aspect" {
    const a = fitSize(2000, 500, 1024);
    try testing.expectEqual(@as(u32, 1024), a.w);
    try testing.expectEqual(@as(u32, 256), a.h);
    try testing.expectApproxEqAbs(@as(f64, 0.512), a.scale, 1e-9);
    const b = fitSize(300, 200, 1024);
    try testing.expectEqual(@as(u32, 300), b.w);
    try testing.expectEqual(@as(f64, 1), b.scale);
    const c = fitSize(5000, 3, 1024);
    try testing.expect(c.h >= 1);
}

fn readPng(alloc: std.mem.Allocator, bytes: []const u8) !struct { w: u32, h: u32, rgb: []u8 } {
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", bytes[0..8]);
    var pos: usize = 8;
    var w: u32 = 0;
    var h: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);
    while (pos < bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        const body = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        try testing.expectEqual(std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]), crc);
        if (std.mem.eql(u8, kind, "IHDR")) {
            w = std.mem.readInt(u32, body[0..4], .big);
            h = std.mem.readInt(u32, body[4..8], .big);
            try testing.expectEqualSlices(u8, &.{ 8, 2, 0, 0, 0 }, body[8..13]); // 8-bit RGB
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(alloc, body);
        }
        pos += 12 + len;
    }
    var in: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const raw = try dec.reader.allocRemaining(alloc, .unlimited);
    defer alloc.free(raw);
    try testing.expectEqual(@as(usize, (w * 3 + 1) * h), raw.len);
    const rgb = try alloc.alloc(u8, w * h * 3);
    for (0..h) |y| {
        try testing.expectEqual(@as(u8, 0), raw[y * (w * 3 + 1)]); // filter: none
        @memcpy(rgb[y * w * 3 ..][0 .. w * 3], raw[y * (w * 3 + 1) + 1 ..][0 .. w * 3]);
    }
    return .{ .w = w, .h = h, .rgb = rgb };
}

test "png_pixels_roundtrip" {
    // 3x2 BGRA with a stride wider than the row; the region is the right 2x2.
    const px = [_]u8{
        9, 9, 9, 255, 0,  0,  255, 255, 0, 255, 0,  255, 7, 7, 7, 7,
        9, 9, 9, 255, 255, 0, 0,   255, 1, 2,   3,  255, 7, 7, 7, 7,
    };
    const f = Frame{ .px = &px, .w = 3, .h = 2, .stride = 16 };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "a.png" });
    defer testing.allocator.free(path);
    const scale = try write(testing.allocator, path, f, .{ .x = 1, .y = 0, .w = 2, .h = 2 }, 1024);
    try testing.expectEqual(@as(f64, 1), scale);
    const bytes = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(bytes);
    const img = try readPng(testing.allocator, bytes);
    defer testing.allocator.free(img.rgb);
    try testing.expectEqual(@as(u32, 2), img.w);
    try testing.expectEqual(@as(u32, 2), img.h);
    // red, green / blue, (r=3,g=2,b=1)
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 3, 2, 1 }, img.rgb);
}

test "png_downscale_averages_and_spans_blocks" {
    // 400x300 of a left-white / right-black split, downscaled to 100x75:
    // 90,000 raw bytes need two stored deflate blocks.
    const w: u32 = 400;
    const h: u32 = 300;
    const px = try testing.allocator.alloc(u8, w * h * 4);
    defer testing.allocator.free(px);
    for (0..h) |y| for (0..w) |x| {
        const v: u8 = if (x < 200) 255 else 0;
        @memset(px[(y * w + x) * 4 ..][0..4], v);
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "b.png" });
    defer testing.allocator.free(path);
    const big = try write(testing.allocator, path, .{ .px = px, .w = w, .h = h, .stride = w * 4 }, .{ .x = 0, .y = 0, .w = w, .h = h }, 1024);
    try testing.expectEqual(@as(f64, 1), big);
    const scale = try write(testing.allocator, path, .{ .px = px, .w = w, .h = h, .stride = w * 4 }, .{ .x = 0, .y = 0, .w = w, .h = h }, 100);
    try testing.expectApproxEqAbs(@as(f64, 0.25), scale, 1e-9);
    const bytes = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(bytes);
    const img = try readPng(testing.allocator, bytes);
    defer testing.allocator.free(img.rgb);
    try testing.expectEqual(@as(u32, 100), img.w);
    try testing.expectEqual(@as(u32, 75), img.h);
    try testing.expectEqual(@as(u8, 255), img.rgb[(10 * 100 + 10) * 3]);
    try testing.expectEqual(@as(u8, 0), img.rgb[(10 * 100 + 90) * 3]);
}

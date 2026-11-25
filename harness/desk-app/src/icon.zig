//! The app's icon, drawn when the app is built: a dark rounded square with
//! a hairline edge, the desk's cyan corner brackets, and a plain head and
//! shoulders. Written as `harness.icns` (PNG images, 16 to 1024 px).
const std = @import("std");
const flate = std.compress.flate;

const V = @Vector(2, f32);

const body_color = rgb(0x0E, 0x0F, 0x1A);
const edge_color = rgb(0x3A, 0x3D, 0x5C);
const cyan = rgb(0x22, 0xE5, 0xFF);
const light = rgb(0xE8, 0xE9, 0xF3);

fn rgb(r: u8, g: u8, b: u8) [3]f32 {
    return .{ @as(f32, @floatFromInt(r)) / 255, @as(f32, @floatFromInt(g)) / 255, @as(f32, @floatFromInt(b)) / 255 };
}

// The shapes on a 1024 canvas (Apple's icon grid: an 824 square), as
// fractions of the side.
const body_half = 412.0 / 1024.0;
const body_radius = 185.0 / 1024.0;
const edge_width = 8.0 / 1024.0;
const bracket_reach = 250.0 / 1024.0; // from the middle to a bracket's corner
const bracket_arm = 110.0 / 1024.0;
const bracket_width = 28.0 / 1024.0;
const head_at: V = .{ 0.5, 450.0 / 1024.0 };
const head_radius = 108.0 / 1024.0;
const shoulders_at: V = .{ 0.5, 752.0 / 1024.0 };
const shoulders_radii: V = .{ 205.0 / 1024.0, 154.0 / 1024.0 };
const shoulders_cut = 706.0 / 1024.0;

fn length(v: V) f32 {
    return @sqrt(@reduce(.Add, v * v));
}

/// Signed distance to a box (centre, half sides) with rounded corners.
fn roundBox(p: V, c: V, half: V, r: f32) f32 {
    const q = @abs(p - c) - (half - @as(V, @splat(r)));
    return length(@max(q, @as(V, @splat(0)))) + @min(@max(q[0], q[1]), 0) - r;
}

fn box(p: V, c: V, half: V) f32 {
    return roundBox(p, c, half, 0);
}

fn brackets(p: V) f32 {
    var d: f32 = std.math.inf(f32);
    for ([_]f32{ -1, 1 }) |sx| for ([_]f32{ -1, 1 }) |sy| {
        const corner: V = .{ 0.5 + sx * bracket_reach, 0.5 + sy * bracket_reach };
        const s: V = .{ sx, sy };
        const along: V = .{ bracket_arm / 2.0, bracket_width / 2.0 };
        const down: V = .{ bracket_width / 2.0, bracket_arm / 2.0 };
        d = @min(d, box(p, corner - s * along, along));
        d = @min(d, box(p, corner - s * down, down));
    };
    return d;
}

fn shoulders(p: V) f32 {
    const k = length((p - shoulders_at) / shoulders_radii);
    const ellipse = (k - 1) * @min(shoulders_radii[0], shoulders_radii[1]);
    return @max(ellipse, p[1] - shoulders_cut);
}

/// Draws the icon at `size` into `rgba` (size × size × 4, straight alpha).
pub fn draw(size: u32, rgba: []u8) void {
    const side: f32 = @floatFromInt(size);
    // at least a pixel wide at small sizes
    const edge = @max(edge_width, 1 / side);
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const p: V = .{ (@as(f32, @floatFromInt(x)) + 0.5) / side, (@as(f32, @floatFromInt(y)) + 0.5) / side };
            const d_body = roundBox(p, .{ 0.5, 0.5 }, .{ body_half, body_half }, body_radius);
            // premultiplied colour and alpha
            var acc: [4]f32 = .{ 0, 0, 0, 0 };
            layer(&acc, body_color, cover(d_body, side));
            layer(&acc, edge_color, cover(@max(d_body, -(d_body + edge)), side));
            layer(&acc, cyan, cover(brackets(p), side));
            layer(&acc, light, cover(length(p - head_at) - head_radius, side));
            layer(&acc, light, cover(shoulders(p), side));
            const o = rgba[(y * size + x) * 4 ..][0..4];
            const a = acc[3];
            for (0..3) |i| o[i] = if (a > 0) toByte(acc[i] / a) else 0;
            o[3] = toByte(a);
        }
    }
}

/// How much of a pixel a shape `d` (signed distance, in sides) covers.
fn cover(d: f32, side: f32) f32 {
    return std.math.clamp(0.5 - d * side, 0, 1);
}

fn layer(acc: *[4]f32, color: [3]f32, alpha: f32) void {
    for (0..3) |i| acc[i] = color[i] * alpha + acc[i] * (1 - alpha);
    acc[3] = alpha + acc[3] * (1 - alpha);
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The icon at `size` as a PNG (8-bit RGBA, zlib-compressed).
pub fn png(a: std.mem.Allocator, size: u32) ![]u8 {
    const px = try a.alloc(u8, size * size * 4);
    defer a.free(px);
    draw(size, px);
    const raw = try a.alloc(u8, size * (1 + size * 4));
    defer a.free(raw);
    for (0..size) |row| {
        raw[row * (1 + size * 4)] = 0; // no filter
        @memcpy(raw[row * (1 + size * 4) + 1 ..][0 .. size * 4], px[row * size * 4 ..][0 .. size * 4]);
    }
    var z: std.Io.Writer.Allocating = try .initCapacity(a, 64 * 1024);
    defer z.deinit();
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    const comp = try a.create(flate.Compress);
    defer a.destroy(comp);
    comp.* = try .init(&z.writer, window, .zlib, .best);
    try comp.writer.writeAll(raw);
    try comp.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], size, .big);
    std.mem.writeInt(u32, ihdr[4..8], size, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(&out, a, "IHDR", &ihdr);
    try chunk(&out, a, "IDAT", z.written());
    try chunk(&out, a, "IEND", "");
    return out.toOwnedSlice(a);
}

fn chunk(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(data.len), .big);
    try out.appendSlice(a, &n);
    const start = out.items.len;
    try out.appendSlice(a, kind);
    try out.appendSlice(a, data);
    std.mem.writeInt(u32, &n, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(a, &n);
}

/// Every size macOS asks for, as `harness.icns`.
pub fn icns(a: std.mem.Allocator) ![]u8 {
    const entries = [_]struct { *const [4]u8, u32 }{
        .{ "icp4", 16 },  .{ "icp5", 32 },  .{ "ic07", 128 }, .{ "ic08", 256 },
        .{ "ic09", 512 }, .{ "ic10", 1024 }, .{ "ic11", 32 },  .{ "ic12", 64 },
        .{ "ic13", 256 }, .{ "ic14", 512 },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "icns\x00\x00\x00\x00");
    for (entries) |e| {
        const p = try png(a, e[1]);
        defer a.free(p);
        try out.appendSlice(a, e[0]);
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, @intCast(p.len + 8), .big);
        try out.appendSlice(a, &n);
        try out.appendSlice(a, p);
    }
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len), .big);
    return out.toOwnedSlice(a);
}

/// `icon OUT.icns`
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.Usage;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = try icns(a) });
}

const t = std.testing;

fn pngSize(png_bytes: []const u8) [2]u32 {
    return .{ std.mem.readInt(u32, png_bytes[16..20], .big), std.mem.readInt(u32, png_bytes[20..24], .big) };
}

test "png_is_valid_and_inflates_to_the_size" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try png(a, 32);
    try t.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", p[0..8]);
    // IHDR: 13 bytes, 32×32, 8 bits, RGBA
    try t.expectEqual(@as(u32, 13), std.mem.readInt(u32, p[8..12], .big));
    try t.expectEqualStrings("IHDR", p[12..16]);
    try t.expectEqual([2]u32{ 32, 32 }, pngSize(p));
    try t.expectEqual(@as(u8, 8), p[24]);
    try t.expectEqual(@as(u8, 6), p[25]);
    try t.expectEqual(std.hash.Crc32.hash(p[12..29]), std.mem.readInt(u32, p[29..33], .big));
    // IDAT inflates to one filter byte and 32 pixels a row
    try t.expectEqualStrings("IDAT", p[37..41]);
    const n = std.mem.readInt(u32, p[33..37], .big);
    var in: std.Io.Reader = .fixed(p[41 .. 41 + n]);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &window);
    const raw = try d.reader.allocRemaining(a, .unlimited);
    try t.expectEqual(@as(usize, 32 * (1 + 32 * 4)), raw.len);
    try t.expectEqualSlices(u8, "\x00\x00\x00\x00IEND\xae\x42\x60\x82", p[p.len - 12 ..]);
}

test "icns_lengths_add_up" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data = try icns(arena.allocator());
    try t.expectEqualStrings("icns", data[0..4]);
    try t.expectEqual(@as(u32, @intCast(data.len)), std.mem.readInt(u32, data[4..8], .big));
    const want = [_]struct { []const u8, u32 }{
        // the sizes of a standard iconset (icp6 is 48 px: not one of them)
        .{ "icp4", 16 },  .{ "icp5", 32 },  .{ "ic07", 128 }, .{ "ic08", 256 },
        .{ "ic09", 512 }, .{ "ic10", 1024 }, .{ "ic11", 32 },  .{ "ic12", 64 },
        .{ "ic13", 256 }, .{ "ic14", 512 },
    };
    var at: usize = 8;
    for (want) |w| {
        try t.expectEqualStrings(w[0], data[at .. at + 4]);
        const len = std.mem.readInt(u32, data[at + 4 ..][0..4], .big);
        const body = data[at + 8 .. at + len];
        try t.expectEqualSlices(u8, "\x89PNG", body[0..4]);
        try t.expectEqual([2]u32{ w[1], w[1] }, pngSize(body));
        at += len;
    }
    try t.expectEqual(data.len, at);
}

test "the_corners_are_clear_and_the_middle_is_not" {
    const size = 128;
    var px: [size * size * 4]u8 = undefined;
    draw(size, &px);
    const at = struct {
        fn f(buf: []const u8, x: usize, y: usize) [4]u8 {
            return buf[(y * size + x) * 4 ..][0..4].*;
        }
    }.f;
    // outside the rounded square: nothing
    try t.expectEqual(@as(u8, 0), at(&px, 0, 0)[3]);
    try t.expectEqual(@as(u8, 0), at(&px, 127, 127)[3]);
    try t.expectEqual(@as(u8, 0), at(&px, 16, 16)[3]);
    // the head: light and solid
    const head = at(&px, 64, 56);
    try t.expectEqual(@as(u8, 255), head[3]);
    try t.expect(head[0] > 200 and head[1] > 200 and head[2] > 200);
    // the square between: dark and solid
    const body = at(&px, 64, 20);
    try t.expectEqual(@as(u8, 255), body[3]);
    try t.expect(body[0] < 40 and body[1] < 40 and body[2] < 60);
    // a bracket's corner: cyan
    const bracket = at(&px, 34, 34);
    try t.expect(bracket[0] < 80 and bracket[1] > 180 and bracket[2] > 200);
}

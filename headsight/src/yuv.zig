//! YUYV (YUY2, 4:2:2, BT.601 limited range), the format nearly every USB
//! camera offers uncompressed, to the BGRA frames the rest of headsight uses.
//! Exported for the Linux V4L2 layer (src/linux/capture.c).
const std = @import("std");
const builtin = @import("builtin");

/// Converts a w x h YUYV image (src_stride bytes per row) into BGRA (w * 4 bytes per row).
pub fn yuyvToBgra(src: []const u8, w: u32, h: u32, src_stride: u32, dst: []u8) void {
    for (0..h) |y| {
        const in = src[y * src_stride ..];
        const out = dst[y * w * 4 ..];
        var x: usize = 0;
        while (x < w) : (x += 2) {
            const q = in[x * 2 ..][0..4]; // Y0 U Y1 V
            const u: i32 = @as(i32, q[1]) - 128;
            const v: i32 = @as(i32, q[3]) - 128;
            pixel(out[x * 4 ..][0..4], q[0], u, v);
            if (x + 1 < w) pixel(out[(x + 1) * 4 ..][0..4], q[2], u, v);
        }
    }
}

// BT.601 limited range, 8.8 fixed point.
fn pixel(o: *[4]u8, y8: u8, u: i32, v: i32) void {
    const c: i32 = 298 * (@as(i32, y8) - 16) + 128;
    o[0] = clamp((c + 516 * u) >> 8);
    o[1] = clamp((c - 100 * u - 208 * v) >> 8);
    o[2] = clamp((c + 409 * v) >> 8);
    o[3] = 255;
}

fn clamp(x: i32) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}

fn exported(src: [*]const u8, w: c_int, h: c_int, src_stride: c_int, dst: [*]u8) callconv(.c) void {
    const wu: u32 = @intCast(w);
    const hu: u32 = @intCast(h);
    const su: u32 = @intCast(src_stride);
    yuyvToBgra(src[0 .. su * hu], wu, hu, su, dst[0 .. wu * hu * 4]);
}

comptime {
    if (builtin.os.tag == .linux) @export(&exported, .{ .name = "hs_yuyv_to_bgra" });
}

// ---- tests ----

const testing = std.testing;

fn one(y: u8, u: u8, v: u8) [4]u8 {
    const src = [_]u8{ y, u, y, v };
    var dst: [8]u8 = undefined;
    yuyvToBgra(&src, 2, 1, 4, &dst);
    return dst[0..4].*;
}

fn near(want: [3]u8, got: [4]u8) !void {
    // got is B G R A
    const rgb = [3]u8{ got[2], got[1], got[0] };
    for (want, rgb) |a, b| try testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
    try testing.expectEqual(@as(u8, 255), got[3]);
}

test "yuyv_white_black_red" {
    try near(.{ 255, 255, 255 }, one(235, 128, 128));
    try near(.{ 0, 0, 0 }, one(16, 128, 128));
    try near(.{ 255, 0, 0 }, one(81, 90, 240));
    try near(.{ 0, 0, 255 }, one(41, 240, 110));
}

test "yuyv_pairs_share_chroma_and_stride_is_respected" {
    // 2x2 image, row stride 8 (2 pixels = 4 bytes, plus 4 padding bytes)
    const src = [_]u8{
        16,  128, 235, 128, 0, 0, 0, 0,
        235, 128, 16,  128, 9, 9, 9, 9,
    };
    var dst: [16]u8 = undefined;
    yuyvToBgra(&src, 2, 2, 8, &dst);
    try near(.{ 0, 0, 0 }, dst[0..4].*);
    try near(.{ 255, 255, 255 }, dst[4..8].*);
    try near(.{ 255, 255, 255 }, dst[8..12].*);
    try near(.{ 0, 0, 0 }, dst[12..16].*);
}

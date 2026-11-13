//! Block comparison of two frames. A block is B x B pixels; its score is the
//! mean absolute difference per byte, times 100.
const std = @import("std");
const frame = @import("frame.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;

pub const B: u32 = 16;

pub const Grid = struct {
    bw: u32,
    bh: u32,
    region: Rect,
    scores: []u16,

    pub fn init(alloc: std.mem.Allocator, region: Rect) !Grid {
        const bw = (region.w + B - 1) / B;
        const bh = (region.h + B - 1) / B;
        const scores = try alloc.alloc(u16, @as(usize, bw) * bh);
        @memset(scores, 0);
        return .{ .bw = bw, .bh = bh, .region = region, .scores = scores };
    }

    pub fn deinit(g: *Grid, alloc: std.mem.Allocator) void {
        alloc.free(g.scores);
    }

    /// The block's rectangle in source coordinates (edge blocks are smaller).
    pub fn blockRect(g: Grid, bx: u32, by: u32) Rect {
        const x = g.region.x + bx * B;
        const y = g.region.y + by * B;
        return .{ .x = x, .y = y, .w = @min(B, g.region.right() - x), .h = @min(B, g.region.bottom() - y) };
    }
};

/// Fills `g.scores` for every block of `g.region`. Both frames must have the
/// same size and contain the region.
pub fn score(g: *Grid, prev: Frame, cur: Frame) void {
    std.debug.assert(prev.w == cur.w and prev.h == cur.h);
    std.debug.assert(prev.full().contains(g.region));
    const V = @Vector(B * 4, u8);
    const W = @Vector(B * 4, u16);
    var by: u32 = 0;
    while (by < g.bh) : (by += 1) {
        var bx: u32 = 0;
        while (bx < g.bw) : (bx += 1) {
            const r = g.blockRect(bx, by);
            var sum: u32 = 0;
            var y = r.y;
            while (y < r.bottom()) : (y += 1) {
                const pa = prev.px[@as(usize, y) * prev.stride + @as(usize, r.x) * 4 ..];
                const pb = cur.px[@as(usize, y) * cur.stride + @as(usize, r.x) * 4 ..];
                if (r.w == B) {
                    const a: V = pa[0 .. B * 4].*;
                    const b: V = pb[0 .. B * 4].*;
                    sum += @reduce(.Add, @as(W, @max(a, b) - @min(a, b)));
                } else {
                    for (pa[0 .. @as(usize, r.w) * 4], pb[0 .. @as(usize, r.w) * 4]) |x, z|
                        sum += if (x > z) x - z else z - x;
                }
            }
            g.scores[@as(usize, by) * g.bw + bx] = @intCast(sum * 100 / (r.w * r.h * 4));
        }
    }
}

/// Marks blocks whose score is above `thresh`; returns how many.
pub fn changedUniform(g: Grid, thresh: u16, out: []bool) u32 {
    var n: u32 = 0;
    for (g.scores, out) |s, *o| {
        o.* = s > thresh;
        n += @intFromBool(o.*);
    }
    return n;
}

/// Marks blocks whose score is above max(floor + margin, min); returns how many.
pub fn changedPerBlock(g: Grid, floor: []const u16, margin: u16, min: u16, out: []bool) u32 {
    var n: u32 = 0;
    for (g.scores, floor, out) |s, f, *o| {
        o.* = s > @max(f +| margin, min);
        n += @intFromBool(o.*);
    }
    return n;
}

/// Unmarks blocks that overlap any of `rects` (in source coordinates); returns
/// how many blocks stay marked.
pub fn clearRects(g: Grid, mask: []bool, rects: []const Rect) u32 {
    var n: u32 = 0;
    for (mask, 0..) |*m, i| {
        if (!m.*) continue;
        const r = g.blockRect(@intCast(i % g.bw), @intCast(i / g.bw));
        for (rects) |o| {
            if (r.x < o.right() and o.x < r.right() and r.y < o.bottom() and o.y < r.bottom()) {
                m.* = false;
                break;
            }
        }
        n += @intFromBool(m.*);
    }
    return n;
}

/// Per-block maximum score seen while the scene is assumed still.
pub const NoiseFloor = struct {
    max: []u16,

    pub fn init(alloc: std.mem.Allocator, blocks: usize) !NoiseFloor {
        const m = try alloc.alloc(u16, blocks);
        @memset(m, 0);
        return .{ .max = m };
    }
    pub fn deinit(nf: *NoiseFloor, alloc: std.mem.Allocator) void {
        alloc.free(nf.max);
    }
    pub fn observe(nf: *NoiseFloor, g: Grid) void {
        for (nf.max, g.scores) |*m, s| m.* = @max(m.*, s);
    }
};

// ---- tests ----

const testing = std.testing;

fn solid(alloc: std.mem.Allocator, w: u32, h: u32, v: u8) ![]u8 {
    const px = try alloc.alloc(u8, @as(usize, w) * h * 4);
    @memset(px, v);
    return px;
}

fn fr(px: []const u8, w: u32, h: u32) Frame {
    return .{ .px = px, .w = w, .h = h, .stride = w * 4 };
}

fn setRect(px: []u8, w: u32, r: Rect, v: u8) void {
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        const row = px[(@as(usize, y) * w + r.x) * 4 ..][0 .. @as(usize, r.w) * 4];
        @memset(row, v);
    }
}

fn countChanged(g: Grid, thresh: u16) !u32 {
    const out = try testing.allocator.alloc(bool, g.scores.len);
    defer testing.allocator.free(out);
    return changedUniform(g, thresh, out);
}

test "identical_frames_no_change" {
    const a = try solid(testing.allocator, 200, 100, 77);
    defer testing.allocator.free(a);
    var g = try Grid.init(testing.allocator, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    defer g.deinit(testing.allocator);
    score(&g, fr(a, 200, 100), fr(a, 200, 100));
    try testing.expectEqual(@as(u32, 0), try countChanged(g, 50));
}

test "small_patch_found" {
    const w: u32 = 3024;
    const h: u32 = 1964;
    const a = try solid(testing.allocator, w, h, 40);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    setRect(b, w, .{ .x = 1001, .y = 503, .w = 6, .h = 6 }, 215);
    var g = try Grid.init(testing.allocator, .{ .x = 0, .y = 0, .w = w, .h = h });
    defer g.deinit(testing.allocator);
    score(&g, fr(a, w, h), fr(b, w, h));
    const out = try testing.allocator.alloc(bool, g.scores.len);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u32, 1), changedUniform(g, 50, out));
    const idx = std.mem.indexOfScalar(bool, out, true).?;
    const bx: u32 = @intCast(idx % g.bw);
    const by: u32 = @intCast(idx / g.bw);
    try testing.expectEqual(Rect{ .x = 992, .y = 496, .w = 16, .h = 16 }, g.blockRect(bx, by));
}

test "region_limits_scoring" {
    const a = try solid(testing.allocator, 200, 200, 10);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    setRect(b, 200, .{ .x = 150, .y = 150, .w = 20, .h = 20 }, 250);
    var g = try Grid.init(testing.allocator, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    defer g.deinit(testing.allocator);
    score(&g, fr(a, 200, 200), fr(b, 200, 200));
    try testing.expectEqual(@as(u32, 0), try countChanged(g, 50));
    var g2 = try Grid.init(testing.allocator, .{ .x = 140, .y = 140, .w = 60, .h = 60 });
    defer g2.deinit(testing.allocator);
    score(&g2, fr(a, 200, 200), fr(b, 200, 200));
    try testing.expect(try countChanged(g2, 50) > 0);
}

test "edge_blocks_scored" {
    const a = try solid(testing.allocator, 1000, 1000, 10);
    defer testing.allocator.free(a);
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    setRect(b, 1000, .{ .x = 995, .y = 995, .w = 3, .h = 3 }, 250);
    var g = try Grid.init(testing.allocator, .{ .x = 0, .y = 0, .w = 1000, .h = 1000 });
    defer g.deinit(testing.allocator);
    score(&g, fr(a, 1000, 1000), fr(b, 1000, 1000));
    const out = try testing.allocator.alloc(bool, g.scores.len);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u32, 1), changedUniform(g, 50, out));
    try testing.expect(out[62 * g.bw + 62]);
    try testing.expectEqual(Rect{ .x = 992, .y = 992, .w = 8, .h = 8 }, g.blockRect(62, 62));
}

test "clear_rects_unmarks_blocks" {
    var g = try Grid.init(testing.allocator, .{ .x = 100, .y = 100, .w = 64, .h = 64 });
    defer g.deinit(testing.allocator);
    const mask = try testing.allocator.alloc(bool, g.scores.len);
    defer testing.allocator.free(mask);
    @memset(mask, true);
    // overlaps the top row of blocks (y 100..116) only
    try testing.expectEqual(@as(u32, 12), clearRects(g, mask, &.{.{ .x = 0, .y = 0, .w = 500, .h = 105 }}));
    try testing.expect(!mask[0] and !mask[3] and mask[4]);
}

test "per_block_floor" {
    const w: u32 = 64;
    const h: u32 = 64;
    const base = try solid(testing.allocator, w, h, 100);
    defer testing.allocator.free(base);
    const noisy = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(noisy);
    for (noisy, 0..) |*p, i| p.* = if (i % 2 == 0) 106 else 94; // abs diff 6 on every byte
    var g = try Grid.init(testing.allocator, .{ .x = 0, .y = 0, .w = w, .h = h });
    defer g.deinit(testing.allocator);
    var nf = try NoiseFloor.init(testing.allocator, g.scores.len);
    defer nf.deinit(testing.allocator);
    score(&g, fr(base, w, h), fr(noisy, w, h));
    nf.observe(g);
    try testing.expectEqual(@as(u16, 600), nf.max[0]);
    const out = try testing.allocator.alloc(bool, g.scores.len);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u32, 0), changedPerBlock(g, nf.max, 400, 800, out));
    const patched = try testing.allocator.dupe(u8, noisy);
    defer testing.allocator.free(patched);
    setRect(patched, w, .{ .x = 16, .y = 16, .w = 16, .h = 16 }, 140); // +40
    score(&g, fr(base, w, h), fr(patched, w, h));
    try testing.expectEqual(@as(u32, 1), changedPerBlock(g, nf.max, 400, 800, out));
    try testing.expect(out[1 * g.bw + 1]);
}

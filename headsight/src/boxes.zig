//! Changed blocks to boxes: blocks within one block of each other (a gap of at
//! most one block) form one box. Boxes are in source coordinates, clipped to
//! the region, largest first.
const std = @import("std");
const frame = @import("frame.zig");
const diff = @import("diff.zig");
const Rect = frame.Rect;

pub const Result = struct {
    boxes: []Rect,
    total: u32,

    pub fn deinit(r: *Result, alloc: std.mem.Allocator) void {
        alloc.free(r.boxes);
    }
};

pub fn find(alloc: std.mem.Allocator, g: diff.Grid, mask: []const bool, max_boxes: u32) !Result {
    const seen = try alloc.alloc(bool, mask.len);
    defer alloc.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(alloc);
    var all: std.ArrayList(Rect) = .empty;
    defer all.deinit(alloc);

    for (mask, 0..) |m, start| {
        if (!m or seen[start]) continue;
        seen[start] = true;
        try stack.append(alloc, @intCast(start));
        var x0: u32 = std.math.maxInt(u32);
        var y0: u32 = std.math.maxInt(u32);
        var x1: u32 = 0;
        var y1: u32 = 0;
        while (stack.pop()) |i| {
            const bx = i % g.bw;
            const by = i / g.bw;
            x0 = @min(x0, bx);
            y0 = @min(y0, by);
            x1 = @max(x1, bx);
            y1 = @max(y1, by);
            // neighbours within two blocks: a gap of one block still joins
            const ny0 = by -| 2;
            const ny1 = @min(by + 2, g.bh - 1);
            const nx0 = bx -| 2;
            const nx1 = @min(bx + 2, g.bw - 1);
            var ny = ny0;
            while (ny <= ny1) : (ny += 1) {
                var nx = nx0;
                while (nx <= nx1) : (nx += 1) {
                    const j = ny * g.bw + nx;
                    if (mask[j] and !seen[j]) {
                        seen[j] = true;
                        try stack.append(alloc, j);
                    }
                }
            }
        }
        const a = g.blockRect(x0, y0);
        const b = g.blockRect(x1, y1);
        try all.append(alloc, .{ .x = a.x, .y = a.y, .w = b.right() - a.x, .h = b.bottom() - a.y });
    }

    std.mem.sort(Rect, all.items, {}, larger);
    const keep = @min(all.items.len, max_boxes);
    return .{ .boxes = try alloc.dupe(Rect, all.items[0..keep]), .total = @intCast(all.items.len) };
}

fn larger(_: void, a: Rect, b: Rect) bool {
    const aa = @as(u64, a.w) * a.h;
    const ab = @as(u64, b.w) * b.h;
    if (aa != ab) return aa > ab;
    if (a.y != b.y) return a.y < b.y;
    return a.x < b.x;
}

/// Bounding rectangle of all boxes; zero rect for none.
pub fn unionOf(bs: []const Rect) Rect {
    if (bs.len == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var x0: u32 = bs[0].x;
    var y0: u32 = bs[0].y;
    var x1: u32 = bs[0].right();
    var y1: u32 = bs[0].bottom();
    for (bs[1..]) |b| {
        x0 = @min(x0, b.x);
        y0 = @min(y0, b.y);
        x1 = @max(x1, b.right());
        y1 = @max(y1, b.bottom());
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

// ---- tests ----

const testing = std.testing;

fn grid(region: Rect) !diff.Grid {
    return diff.Grid.init(testing.allocator, region);
}

fn mark(g: diff.Grid, mask: []bool, bx: u32, by: u32) void {
    mask[@as(usize, by) * g.bw + bx] = true;
}

fn run(region: Rect, cells: []const [2]u32, max: u32) !Result {
    var g = try grid(region);
    defer g.deinit(testing.allocator);
    const mask = try testing.allocator.alloc(bool, g.scores.len);
    defer testing.allocator.free(mask);
    @memset(mask, false);
    for (cells) |c| mark(g, mask, c[0], c[1]);
    return find(testing.allocator, g, mask, max);
}

test "single_block" {
    var r = try run(.{ .x = 100, .y = 50, .w = 160, .h = 160 }, &.{.{ 1, 2 }}, 8);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.total);
    try testing.expectEqual(Rect{ .x = 116, .y = 82, .w = 16, .h = 16 }, r.boxes[0]);
}

test "adjacent_merge" {
    var r = try run(.{ .x = 0, .y = 0, .w = 160, .h = 160 }, &.{ .{ 2, 2 }, .{ 3, 2 } }, 8);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.total);
    try testing.expectEqual(Rect{ .x = 32, .y = 32, .w = 32, .h = 16 }, r.boxes[0]);
}

test "gap_of_one_block_merges" {
    var r = try run(.{ .x = 0, .y = 0, .w = 160, .h = 160 }, &.{ .{ 2, 2 }, .{ 4, 2 } }, 8);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), r.total);
    try testing.expectEqual(Rect{ .x = 32, .y = 32, .w = 48, .h = 16 }, r.boxes[0]);
}

test "far_apart_separate" {
    var r = try run(.{ .x = 0, .y = 0, .w = 320, .h = 320 }, &.{ .{ 0, 0 }, .{ 10, 10 }, .{ 11, 10 } }, 8);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), r.total);
    try testing.expectEqual(Rect{ .x = 160, .y = 160, .w = 32, .h = 16 }, r.boxes[0]);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 16, .h = 16 }, r.boxes[1]);
}

test "cap_keeps_largest" {
    var cells: [21][2]u32 = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        cells[n] = .{ i * 3, 0 };
        n += 1;
    }
    for (20..23) |y| for (10..13) |x| {
        cells[n] = .{ @intCast(x), @intCast(y) };
        n += 1;
    };
    var r = try run(.{ .x = 0, .y = 0, .w = 640, .h = 640 }, cells[0..n], 8);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 13), r.total);
    try testing.expectEqual(@as(usize, 8), r.boxes.len);
    try testing.expectEqual(Rect{ .x = 160, .y = 320, .w = 48, .h = 48 }, r.boxes[0]);
}

test "edge_box_clipped" {
    var r = try run(.{ .x = 0, .y = 0, .w = 100, .h = 40 }, &.{.{ 6, 0 }}, 8);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(Rect{ .x = 96, .y = 0, .w = 4, .h = 16 }, r.boxes[0]);
}

test "union_of_boxes" {
    const u = unionOf(&.{ .{ .x = 10, .y = 10, .w = 5, .h = 5 }, .{ .x = 40, .y = 2, .w = 10, .h = 3 } });
    try testing.expectEqual(Rect{ .x = 10, .y = 2, .w = 40, .h = 13 }, u);
}

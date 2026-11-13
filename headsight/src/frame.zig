//! Frames (BGRA, 4 bytes per pixel) and rectangles in source pixel coordinates,
//! origin top left.
const std = @import("std");

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn right(r: Rect) u32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) u32 {
        return r.y + r.h;
    }

    /// True when `inner` lies entirely inside `outer`.
    pub fn contains(outer: Rect, inner: Rect) bool {
        return inner.x >= outer.x and inner.y >= outer.y and
            inner.right() <= outer.right() and inner.bottom() <= outer.bottom();
    }

    /// The part of `r` inside a w x h source.
    pub fn clamp(r: Rect, w: u32, h: u32) Rect {
        const x = @min(r.x, w);
        const y = @min(r.y, h);
        return .{ .x = x, .y = y, .w = @min(r.right(), w) -| x, .h = @min(r.bottom(), h) -| y };
    }

    /// `r` grown by `by` on every side, then clamped to a w x h source.
    pub fn pad(r: Rect, by: u32, w: u32, h: u32) Rect {
        const x = r.x -| by;
        const y = r.y -| by;
        return (Rect{ .x = x, .y = y, .w = r.right() + by - x, .h = r.bottom() + by - y }).clamp(w, h);
    }
};

pub const Frame = struct {
    px: []const u8,
    w: u32,
    h: u32,
    stride: u32,

    pub fn full(f: Frame) Rect {
        return .{ .x = 0, .y = 0, .w = f.w, .h = f.h };
    }

    /// A view of region `r` (inside the frame), sharing the pixels.
    pub fn sub(f: Frame, r: Rect) Frame {
        std.debug.assert(f.full().contains(r));
        const off = @as(usize, r.y) * f.stride + @as(usize, r.x) * 4;
        return .{ .px = f.px[off..], .w = r.w, .h = r.h, .stride = f.stride };
    }
};

test "sub_frame_view" {
    var px: [8 * 4 * 4]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i);
    const f = Frame{ .px = &px, .w = 8, .h = 4, .stride = 32 };
    const s = f.sub(.{ .x = 2, .y = 1, .w = 3, .h = 2 });
    try std.testing.expectEqual(@as(u32, 3), s.w);
    try std.testing.expectEqual(@as(u32, 2), s.h);
    try std.testing.expectEqual(@as(u32, 32), s.stride);
    try std.testing.expectEqual(@as(u8, 32 + 8), s.px[0]);
    try std.testing.expectEqual(@as(u8, 64 + 8), s.px[32]);
}

test "rect_clamp_and_pad" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expectEqual(Rect{ .x = 0, .y = 4, .w = 56, .h = 72 }, r.pad(16, 100, 100));
    try std.testing.expectEqual(Rect{ .x = 90, .y = 90, .w = 10, .h = 10 }, (Rect{ .x = 90, .y = 90, .w = 50, .h = 50 }).clamp(100, 100));
    try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 0, .h = 10 }, (Rect{ .x = 120, .y = 0, .w = 5, .h = 10 }).clamp(100, 100));
    try std.testing.expect((Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }).contains(r));
    try std.testing.expect(!(Rect{ .x = 0, .y = 0, .w = 30, .h = 100 }).contains(r));
}

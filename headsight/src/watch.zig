//! The wait state machine: fed frames (or idle ticks) with timestamps, it
//! decides when a region changed, went still, or shows some text.
const std = @import("std");
const frame = @import("frame.zig");
const diff = @import("diff.zig");
const boxes = @import("boxes.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;

pub const Mode = union(enum) { change, still: u32, text: []const u8 };

pub const Opts = struct {
    mode: Mode,
    region: Rect,
    ignore: []const Rect = &.{},
    timeout_ms: u32 = 120_000,
    camera: bool = false,
    max_boxes: u32 = 8,
};

pub const TextLine = struct { text: []const u8, box: Rect, confidence: f32 };

/// Reads text in region `r` of `f`, appending lines whose `text` is allocated with `alloc`.
pub const OcrFn = *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, f: Frame, r: Rect, out: *std.ArrayList(TextLine)) anyerror!void;

pub const Event = union(enum) {
    changed: struct { at_ms: u64, boxes: []const Rect, total: u32 },
    still: struct { at_ms: u64 },
    text: struct { at_ms: u64, line: TextLine },
    size_changed: struct { at_ms: u64, w: u32, h: u32 },
    timeout: struct { at_ms: u64 },
    source_gone: struct { at_ms: u64 },
};

pub const screen_thresh: u16 = 50;
pub const camera_warmup: u32 = 15;
pub const camera_calibrate: u32 = 30;
pub const camera_margin: u16 = 400;
pub const camera_min: u16 = 800;
pub const camera_debounce: u32 = 3;

pub const Watch = struct {
    alloc: std.mem.Allocator,
    opts: Opts,
    ocr: ?OcrFn,
    ocr_ctx: ?*anyopaque,
    /// What a frame is compared with: the reference for `change` (fixed once
    /// set), the previous frame for `still` and `text`.
    base: ?[]u8 = null,
    base_w: u32 = 0,
    base_h: u32 = 0,
    /// Most recent complete frame, tight stride.
    recent: ?[]u8 = null,
    recent_w: u32 = 0,
    recent_h: u32 = 0,
    grid: diff.Grid,
    mask: []bool,
    floor: ?diff.NoiseFloor = null,
    frames: u32 = 0,
    streak: u32 = 0,
    last_change_ms: ?u64 = null,
    result: ?boxes.Result = null,
    found: ?TextLine = null,

    pub fn init(alloc: std.mem.Allocator, opts: Opts, ocr: ?OcrFn, ocr_ctx: ?*anyopaque, reference: ?Frame) !Watch {
        var g = try diff.Grid.init(alloc, opts.region);
        errdefer g.deinit(alloc);
        const mask = try alloc.alloc(bool, g.scores.len);
        errdefer alloc.free(mask);
        var w = Watch{ .alloc = alloc, .opts = opts, .ocr = ocr, .ocr_ctx = ocr_ctx, .grid = g, .mask = mask };
        if (opts.camera) w.floor = try diff.NoiseFloor.init(alloc, g.scores.len);
        if (reference) |r| try copyInto(alloc, &w.base, &w.base_w, &w.base_h, r);
        return w;
    }

    pub fn deinit(w: *Watch) void {
        if (w.base) |b| w.alloc.free(b);
        if (w.recent) |b| w.alloc.free(b);
        if (w.floor) |*f| f.deinit(w.alloc);
        if (w.result) |*r| r.deinit(w.alloc);
        if (w.found) |l| w.alloc.free(l.text);
        w.grid.deinit(w.alloc);
        w.alloc.free(w.mask);
    }

    /// `f == null` is an idle tick: time passed, no new pixels.
    pub fn feed(w: *Watch, f: ?Frame, now_ms: u64) !?Event {
        const cur = f orelse return w.tick(now_ms);
        if (w.base) |_| {
            if (cur.w != w.base_w or cur.h != w.base_h)
                return .{ .size_changed = .{ .at_ms = now_ms, .w = cur.w, .h = cur.h } };
        }
        w.frames += 1;
        defer copyInto(w.alloc, &w.recent, &w.recent_w, &w.recent_h, cur) catch {};

        if (w.opts.camera) {
            if (w.frames <= camera_warmup) return null;
            if (w.frames <= camera_warmup + camera_calibrate) {
                if (w.recent) |prev| {
                    diff.score(&w.grid, w.frameOf(prev, w.recent_w, w.recent_h), cur);
                    w.floor.?.observe(w.grid);
                }
                if (w.frames == camera_warmup + camera_calibrate) return w.firstFrame(cur, now_ms);
                return null;
            }
        } else if (w.frames == 1) {
            if (w.base == null or w.opts.mode != .change) return w.firstFrame(cur, now_ms);
        }

        const base = w.base orelse return w.firstFrame(cur, now_ms);
        diff.score(&w.grid, w.frameOf(base, w.base_w, w.base_h), cur);
        var n = if (w.floor) |fl|
            diff.changedPerBlock(w.grid, fl.max, camera_margin, camera_min, w.mask)
        else
            diff.changedUniform(w.grid, screen_thresh, w.mask);
        n = w.applyIgnore(n);
        const changed = if (n == 0) blk: {
            w.streak = 0;
            break :blk false;
        } else blk: {
            w.streak += 1;
            break :blk w.streak >= (if (w.opts.camera) camera_debounce else 1);
        };

        switch (w.opts.mode) {
            .change => {
                if (!changed) return null;
                if (w.result) |*r| r.deinit(w.alloc);
                w.result = try boxes.find(w.alloc, w.grid, w.mask, w.opts.max_boxes);
                return .{ .changed = .{ .at_ms = now_ms, .boxes = w.result.?.boxes, .total = w.result.?.total } };
            },
            .still => |ms| {
                try copyInto(w.alloc, &w.base, &w.base_w, &w.base_h, cur);
                if (changed) w.last_change_ms = now_ms;
                return w.stillCheck(ms, now_ms);
            },
            .text => {
                try copyInto(w.alloc, &w.base, &w.base_w, &w.base_h, cur);
                if (!changed) return null;
                return w.readText(cur, now_ms);
            },
        }
    }

    fn firstFrame(w: *Watch, cur: Frame, now_ms: u64) !?Event {
        if (w.opts.mode != .change or w.base == null)
            try copyInto(w.alloc, &w.base, &w.base_w, &w.base_h, cur);
        switch (w.opts.mode) {
            .change => return null,
            .still => |ms| {
                w.last_change_ms = now_ms;
                return w.stillCheck(ms, now_ms);
            },
            .text => return w.readText(cur, now_ms),
        }
    }

    fn tick(w: *Watch, now_ms: u64) ?Event {
        return switch (w.opts.mode) {
            .still => |ms| w.stillCheck(ms, now_ms),
            else => null,
        };
    }

    fn stillCheck(w: *Watch, ms: u32, now_ms: u64) ?Event {
        const since = w.last_change_ms orelse return null;
        if (now_ms - since >= ms) return .{ .still = .{ .at_ms = now_ms } };
        return null;
    }

    fn readText(w: *Watch, cur: Frame, now_ms: u64) !?Event {
        const read = w.ocr orelse return null;
        var lines: std.ArrayList(TextLine) = .empty;
        defer {
            for (lines.items) |l| w.alloc.free(l.text);
            lines.deinit(w.alloc);
        }
        try read(w.ocr_ctx, w.alloc, cur, w.opts.region, &lines);
        for (lines.items, 0..) |l, i| {
            if (std.ascii.indexOfIgnoreCase(l.text, w.opts.mode.text) != null) {
                _ = lines.swapRemove(i);
                if (w.found) |old| w.alloc.free(old.text);
                w.found = l;
                return .{ .text = .{ .at_ms = now_ms, .line = l } };
            }
        }
        return null;
    }

    fn applyIgnore(w: *Watch, n: u32) u32 {
        if (w.opts.ignore.len == 0 or n == 0) return n;
        return diff.clearRects(w.grid, w.mask, w.opts.ignore);
    }

    fn frameOf(_: *Watch, px: []const u8, fw: u32, fh: u32) Frame {
        return .{ .px = px, .w = fw, .h = fh, .stride = fw * 4 };
    }

    pub fn timedOut(_: *Watch, now_ms: u64) Event {
        return .{ .timeout = .{ .at_ms = now_ms } };
    }

    pub fn sourceGone(_: *Watch, now_ms: u64) Event {
        return .{ .source_gone = .{ .at_ms = now_ms } };
    }

    /// The most recent complete frame (tight stride), for the crop.
    pub fn last(w: *Watch) ?Frame {
        const px = w.recent orelse return null;
        return .{ .px = px, .w = w.recent_w, .h = w.recent_h, .stride = w.recent_w * 4 };
    }
};

fn copyInto(alloc: std.mem.Allocator, dst: *?[]u8, dw: *u32, dh: *u32, f: Frame) !void {
    const need = @as(usize, f.w) * f.h * 4;
    if (dst.*) |d| {
        if (d.len != need) {
            alloc.free(d);
            dst.* = null;
        }
    }
    const buf = dst.* orelse try alloc.alloc(u8, need);
    dst.* = buf;
    dw.* = f.w;
    dh.* = f.h;
    const row = @as(usize, f.w) * 4;
    for (0..f.h) |y| @memcpy(buf[y * row ..][0..row], f.px[y * @as(usize, f.stride) ..][0..row]);
}

// ---- tests ----

const testing = std.testing;
const W: u32 = 64;
const H: u32 = 64;

fn solid(v: u8) ![]u8 {
    const px = try testing.allocator.alloc(u8, W * H * 4);
    @memset(px, v);
    return px;
}

fn patched(base: []const u8, r: Rect, v: u8) ![]u8 {
    const px = try testing.allocator.dupe(u8, base);
    var y = r.y;
    while (y < r.bottom()) : (y += 1) @memset(px[(y * W + r.x) * 4 ..][0 .. r.w * 4], v);
    return px;
}

fn fr(px: []const u8) Frame {
    return .{ .px = px, .w = W, .h = H, .stride = W * 4 };
}

const full = Rect{ .x = 0, .y = 0, .w = W, .h = H };

test "change_detected_with_boxes" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    const b = try patched(a, .{ .x = 16, .y = 16, .w = 16, .h = 16 }, 200);
    defer testing.allocator.free(b);
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full }, null, null, null);
    defer w.deinit();
    try testing.expect((try w.feed(fr(a), 0)) == null);
    try testing.expect((try w.feed(fr(a), 33)) == null);
    const ev = (try w.feed(fr(b), 66)).?;
    try testing.expectEqual(@as(u64, 66), ev.changed.at_ms);
    try testing.expectEqual(@as(u32, 1), ev.changed.total);
    try testing.expectEqual(Rect{ .x = 16, .y = 16, .w = 16, .h = 16 }, ev.changed.boxes[0]);
}

test "ignore_rect_suppresses" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    const b = try patched(a, .{ .x = 16, .y = 16, .w = 16, .h = 16 }, 200);
    defer testing.allocator.free(b);
    const c = try patched(b, .{ .x = 48, .y = 48, .w = 8, .h = 8 }, 200);
    defer testing.allocator.free(c);
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full, .ignore = &.{.{ .x = 10, .y = 10, .w = 30, .h = 30 }} }, null, null, null);
    defer w.deinit();
    _ = try w.feed(fr(a), 0);
    try testing.expect((try w.feed(fr(b), 33)) == null);
    const ev = (try w.feed(fr(c), 66)).?;
    try testing.expectEqual(Rect{ .x = 48, .y = 48, .w = 16, .h = 16 }, ev.changed.boxes[0]);
}

test "still_after_quiet_period" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    const b = try solid(90);
    defer testing.allocator.free(b);
    var w = try Watch.init(testing.allocator, .{ .mode = .{ .still = 1000 }, .region = full }, null, null, null);
    defer w.deinit();
    try testing.expect((try w.feed(fr(a), 0)) == null);
    try testing.expect((try w.feed(fr(b), 100)) == null);
    try testing.expect((try w.feed(fr(a), 200)) == null); // last change at 200
    var t: u64 = 300;
    while (t < 1200) : (t += 100) try testing.expect((try w.feed(fr(a), t)) == null);
    const ev = (try w.feed(fr(a), 1200)).?;
    try testing.expectEqual(@as(u64, 1200), ev.still.at_ms);
}

test "still_with_idle_ticks" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    var w = try Watch.init(testing.allocator, .{ .mode = .{ .still = 800 }, .region = full }, null, null, null);
    defer w.deinit();
    try testing.expect((try w.feed(fr(a), 0)) == null);
    var t: u64 = 100;
    while (t < 800) : (t += 100) try testing.expect((try w.feed(null, t)) == null);
    const ev = (try w.feed(null, 800)).?;
    try testing.expectEqual(@as(u64, 800), ev.still.at_ms);
    try testing.expect(w.last() != null);
}

const FakeOcr = struct {
    calls: u32 = 0,
    text: []const u8,

    fn read(ctx: ?*anyopaque, alloc: std.mem.Allocator, f: Frame, r: Rect, out: *std.ArrayList(TextLine)) anyerror!void {
        _ = f;
        const self: *FakeOcr = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        try out.append(alloc, .{ .text = try alloc.dupe(u8, self.text), .box = .{ .x = r.x + 4, .y = r.y + 4, .w = 20, .h = 8 }, .confidence = 1 });
    }
};

test "text_already_present" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    var ocr = FakeOcr{ .text = "Export Done: 42 files" };
    var w = try Watch.init(testing.allocator, .{ .mode = .{ .text = "export done" }, .region = full }, FakeOcr.read, &ocr, null);
    defer w.deinit();
    const ev = (try w.feed(fr(a), 0)).?;
    try testing.expectEqual(@as(u64, 0), ev.text.at_ms);
    try testing.expectEqualStrings("Export Done: 42 files", ev.text.line.text);
}

test "text_only_ocrs_on_change" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    const b = try patched(a, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, 200);
    defer testing.allocator.free(b);
    var ocr = FakeOcr{ .text = "Exporting..." };
    var w = try Watch.init(testing.allocator, .{ .mode = .{ .text = "Done" }, .region = full }, FakeOcr.read, &ocr, null);
    defer w.deinit();
    try testing.expect((try w.feed(fr(a), 0)) == null);
    try testing.expectEqual(@as(u32, 1), ocr.calls);
    _ = try w.feed(fr(a), 33);
    _ = try w.feed(fr(a), 66);
    _ = try w.feed(null, 99);
    try testing.expectEqual(@as(u32, 1), ocr.calls);
    _ = try w.feed(fr(b), 132);
    try testing.expectEqual(@as(u32, 2), ocr.calls);
}

test "reference_given_detects_prior_change" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    const b = try patched(a, .{ .x = 32, .y = 0, .w = 16, .h = 16 }, 200);
    defer testing.allocator.free(b);
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full }, null, null, fr(a));
    defer w.deinit();
    const ev = (try w.feed(fr(b), 0)).?;
    try testing.expectEqual(Rect{ .x = 32, .y = 0, .w = 16, .h = 16 }, ev.changed.boxes[0]);
}

test "size_change_reported" {
    const a = try solid(50);
    defer testing.allocator.free(a);
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = .{ .x = 0, .y = 0, .w = 32, .h = 32 } }, null, null, null);
    defer w.deinit();
    _ = try w.feed(fr(a), 0);
    const small = Frame{ .px = a, .w = 32, .h = 32, .stride = W * 4 };
    const ev = (try w.feed(small, 40)).?;
    try testing.expectEqual(@as(u32, 32), ev.size_changed.w);
    try testing.expectEqual(@as(u32, 32), ev.size_changed.h);
}

fn noisy(rng: std.Random, base: u8) ![]u8 {
    const px = try testing.allocator.alloc(u8, W * H * 4);
    for (px) |*p| p.* = base - 6 + rng.uintAtMost(u8, 12);
    return px;
}

test "camera_noise_ignored" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full, .camera = true }, null, null, null);
    defer w.deinit();
    var t: u64 = 0;
    for (0..100) |_| {
        const px = try noisy(rng, 100);
        defer testing.allocator.free(px);
        try testing.expect((try w.feed(fr(px), t)) == null);
        t += 33;
    }
    var ev: ?Event = null;
    for (0..3) |_| {
        const n = try noisy(rng, 100);
        defer testing.allocator.free(n);
        const px = try patched(n, .{ .x = 16, .y = 16, .w = 16, .h = 16 }, 160);
        defer testing.allocator.free(px);
        ev = try w.feed(fr(px), t);
        t += 33;
    }
    try testing.expect(ev != null);
    try testing.expectEqual(Rect{ .x = 16, .y = 16, .w = 16, .h = 16 }, ev.?.changed.boxes[0]);
}

test "camera_flicker_debounced" {
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full, .camera = true }, null, null, null);
    defer w.deinit();
    var t: u64 = 0;
    for (0..60) |i| {
        const n = try noisy(rng, 100);
        defer testing.allocator.free(n);
        const flick = i == 50 or i == 51;
        const px = if (flick) try patched(n, .{ .x = 16, .y = 16, .w = 16, .h = 16 }, 160) else try testing.allocator.dupe(u8, n);
        defer testing.allocator.free(px);
        try testing.expect((try w.feed(fr(px), t)) == null);
        t += 33;
    }
}

test "timeout_without_frames" {
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full }, null, null, null);
    defer w.deinit();
    try testing.expectEqual(@as(u64, 5000), w.timedOut(5000).timeout.at_ms);
}

test "stream_error_ends_wait" {
    var w = try Watch.init(testing.allocator, .{ .mode = .change, .region = full }, null, null, null);
    defer w.deinit();
    try testing.expectEqual(@as(u64, 4200), w.sourceGone(4200).source_gone.at_ms);
}

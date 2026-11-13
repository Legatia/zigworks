//! Zig side of the Apple layer (src/mac/capture.h). On other platforms every
//! function reports error.Unsupported.
const std = @import("std");
const builtin = @import("builtin");
const frame = @import("frame.zig");
const watch = @import("watch.zig");
const Rect = frame.Rect;
const Frame = frame.Frame;

pub const supported = builtin.os.tag == .macos;

pub const OK = 0;
pub const TIMEOUT = 1;
pub const PERMISSION = 3;
pub const FAIL = 4;
pub const GONE = 5;
pub const NO_HOST = 6;
pub const NOT_FOUND = 8;

pub const HsFrame = extern struct { px: ?[*]const u8, w: c_int, h: c_int, stride: c_int, scale: f32 = 1 };
pub const HsSource = extern struct { kind: c_int, window_id: u32, camera_name: ?[*:0]const u8, fps: c_int };
pub const WindowCb = *const fn (?*anyopaque, u32, [*:0]const u8, [*:0]const u8, c_int, c_int, c_int, c_int) callconv(.c) void;
pub const FrameCb = *const fn (?*anyopaque, ?*const HsFrame) callconv(.c) c_int;
pub const TextCb = *const fn (?*anyopaque, [*:0]const u8, f32, c_int, c_int, c_int, c_int) callconv(.c) void;

const c = struct {
    extern fn hs_host_app(buf: [*]u8, len: c_int) c_int;
    extern fn hs_screen_access(request: c_int) c_int;
    extern fn hs_camera_access() c_int;
    extern fn hs_screen_locked() c_int;
    extern fn hs_windows(cb: WindowCb, ctx: ?*anyopaque) c_int;
    extern fn hs_shot(src: *const HsSource, px: *?[*]u8, w: *c_int, h: *c_int, stride: *c_int, pixel_scale: *f64) c_int;
    extern fn hs_stream(src: *const HsSource, timeout_ms: c_int, cb: FrameCb, ctx: ?*anyopaque) c_int;
    extern fn hs_ocr(f: *const HsFrame, x: c_int, y: c_int, w: c_int, h: c_int, accurate: c_int, cb: TextCb, ctx: ?*anyopaque) c_int;
    extern fn hs_write_png(path: [*:0]const u8, f: *const HsFrame, x: c_int, y: c_int, w: c_int, h: c_int, max_side: c_int, scale_out: *f64) c_int;
    extern fn hs_free(p: ?*anyopaque) void;
    extern fn hs_test_render_text(w: c_int, h: c_int, text: [*:0]const u8) ?[*]u8;
};

pub const Error = error{ Unsupported, Failed, Permission, Gone, NotFound };

fn hsFrame(f: Frame) HsFrame {
    return .{ .px = f.px.ptr, .w = @intCast(f.w), .h = @intCast(f.h), .stride = @intCast(f.stride) };
}

fn ci(v: u32) c_int {
    return @intCast(v);
}

/// Name of the app that started this process, or null (ssh, launchd).
pub fn hostApp(buf: []u8) ?[]const u8 {
    if (!supported) return null;
    if (c.hs_host_app(buf.ptr, @intCast(buf.len)) != 1) return null;
    return std.mem.sliceTo(buf, 0);
}

pub fn screenAccess(request: bool) bool {
    if (!supported) return false;
    return c.hs_screen_access(@intFromBool(request)) == 1;
}

/// True while the Mac shows the login screen; windows are not redrawn then.
pub fn screenLocked() bool {
    if (!supported) return false;
    return c.hs_screen_locked() == 1;
}

pub fn cameraAccess() c_int {
    if (!supported) return FAIL;
    return c.hs_camera_access();
}

pub fn windows(cb: WindowCb, ctx: ?*anyopaque) Error!void {
    if (!supported) return error.Unsupported;
    if (c.hs_windows(cb, ctx) != OK) return error.Failed;
}

pub const Shot = struct {
    frame: Frame,
    pixel_scale: f64,
    raw: [*]u8,

    pub fn deinit(s: *Shot) void {
        if (supported) c.hs_free(s.raw);
    }
};

pub fn shot(src: HsSource) Error!Shot {
    if (!supported) return error.Unsupported;
    var px: ?[*]u8 = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var stride: c_int = 0;
    var scale: f64 = 1;
    switch (c.hs_shot(&src, &px, &w, &h, &stride, &scale)) {
        OK => {},
        PERMISSION => return error.Permission,
        GONE, NOT_FOUND => return error.Gone,
        else => return error.Failed,
    }
    const p = px orelse return error.Failed;
    const wu: u32 = @intCast(w);
    const hu: u32 = @intCast(h);
    const su: u32 = @intCast(stride);
    return .{ .frame = .{ .px = p[0 .. @as(usize, su) * hu], .w = wu, .h = hu, .stride = su }, .pixel_scale = scale, .raw = p };
}

/// Runs the source until `cb` returns 1, the timeout passes, or the source goes away.
/// Returns OK, TIMEOUT, GONE, PERMISSION or FAIL.
pub fn stream(src: HsSource, timeout_ms: u32, cb: FrameCb, ctx: ?*anyopaque) Error!c_int {
    if (!supported) return error.Unsupported;
    return c.hs_stream(&src, ci(timeout_ms), cb, ctx);
}

pub fn toFrame(f: *const HsFrame) Frame {
    const w: u32 = @intCast(f.w);
    const h: u32 = @intCast(f.h);
    const s: u32 = @intCast(f.stride);
    return .{ .px = f.px.?[0 .. @as(usize, s) * h], .w = w, .h = h, .stride = s };
}

const OcrCtx = struct { alloc: std.mem.Allocator, out: *std.ArrayList(watch.TextLine), err: ?anyerror = null };

fn onText(ctx: ?*anyopaque, text: [*:0]const u8, conf: f32, x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
    const o: *OcrCtx = @ptrCast(@alignCast(ctx.?));
    if (o.err != null) return;
    const t = o.alloc.dupe(u8, std.mem.span(text)) catch |e| {
        o.err = e;
        return;
    };
    const clampU = struct {
        fn f(v: c_int) u32 {
            return @intCast(@max(v, 0));
        }
    }.f;
    o.out.append(o.alloc, .{ .text = t, .box = .{ .x = clampU(x), .y = clampU(y), .w = clampU(w), .h = clampU(h) }, .confidence = conf }) catch |e| {
        o.alloc.free(t);
        o.err = e;
    };
}

/// Reads text in `r` of `f`; line boxes are in the frame's coordinates.
pub fn ocr(alloc: std.mem.Allocator, f: Frame, r: Rect, accurate: bool, out: *std.ArrayList(watch.TextLine)) !void {
    if (!supported) return error.Unsupported;
    var ctx = OcrCtx{ .alloc = alloc, .out = out };
    const hf = hsFrame(f);
    if (c.hs_ocr(&hf, ci(r.x), ci(r.y), ci(r.w), ci(r.h), @intFromBool(accurate), onText, &ctx) != OK) return error.Failed;
    if (ctx.err) |e| return e;
}

/// Writes `r` of `f` as a PNG, downscaled so the long side is at most `max_side`. Returns the scale.
pub fn writePng(path: [:0]const u8, f: Frame, r: Rect, max_side: u32) Error!f64 {
    if (!supported) return error.Unsupported;
    var scale: f64 = 1;
    const hf = hsFrame(f);
    if (c.hs_write_png(path.ptr, &hf, ci(r.x), ci(r.y), ci(r.w), ci(r.h), ci(max_side), &scale) != OK) return error.Failed;
    return scale;
}

// ---- tests (macOS; none needs Screen Recording or the camera) ----

const testing = std.testing;

test "png_roundtrip_size" {
    if (!supported) return error.SkipZigTest;
    const w: u32 = 2000;
    const h: u32 = 500;
    const px = try testing.allocator.alloc(u8, w * h * 4);
    defer testing.allocator.free(px);
    @memset(px, 128);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/a.png", .{dir}, 0);
    defer testing.allocator.free(path);
    const scale = try writePng(path, .{ .px = px, .w = w, .h = h, .stride = w * 4 }, .{ .x = 0, .y = 0, .w = w, .h = h }, 1024);
    try testing.expectApproxEqAbs(@as(f64, 0.512), scale, 0.001);
    const st = try std.fs.cwd().statFile(path);
    try testing.expect(st.size > 0);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var hdr: [24]u8 = undefined;
    _ = try f.readAll(&hdr);
    try testing.expectEqualSlices(u8, "\x89PNG", hdr[0..4]);
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, hdr[16..20], .big));
    try testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, hdr[20..24], .big));
}

test "ocr_synthetic" {
    if (!supported) return error.SkipZigTest;
    const w: u32 = 1200;
    const h: u32 = 300;
    const raw = c.hs_test_render_text(ci(w), ci(h), "Export Done 42") orelse return error.TestUnexpectedResult;
    defer c.hs_free(raw);
    const f = Frame{ .px = raw[0 .. w * h * 4], .w = w, .h = h, .stride = w * 4 };
    var lines: std.ArrayList(watch.TextLine) = .empty;
    defer {
        for (lines.items) |l| testing.allocator.free(l.text);
        lines.deinit(testing.allocator);
    }
    try ocr(testing.allocator, f, .{ .x = 0, .y = 0, .w = w, .h = h }, false, &lines);
    var found = false;
    for (lines.items) |l| {
        if (std.ascii.indexOfIgnoreCase(l.text, "Export Done") != null) {
            found = true;
            try testing.expect(l.box.w > 100 and l.box.x < w and l.box.y < h);
        }
    }
    try testing.expect(found);
    // a region that excludes the text finds nothing
    for (lines.items) |l| testing.allocator.free(l.text);
    lines.clearRetainingCapacity();
    try ocr(testing.allocator, f, .{ .x = 0, .y = 0, .w = 100, .h = 40 }, false, &lines);
    try testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "host_app_found_from_a_terminal" {
    if (!supported) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const name = hostApp(&buf);
    if (name) |n| try testing.expect(n.len > 0);
    // Set HEADSIGHT_EXPECT_HOST=1 when running the tests from a terminal app;
    // the parent chain goes through root-owned `login`.
    if (std.posix.getenv("HEADSIGHT_EXPECT_HOST") != null) try testing.expect(name != null);
}

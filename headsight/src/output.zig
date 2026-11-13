//! Result lines (key=value, like headterm) and their --json form.
const std = @import("std");
const frame = @import("frame.zig");
const watch = @import("watch.zig");
const Rect = frame.Rect;
const Writer = std.Io.Writer;

pub const CropInfo = struct { path: []const u8, origin_x: u32, origin_y: u32, scale: f32 };
pub const SnapInfo = struct { source: []const u8, src_w: u32, src_h: u32, pixel_scale: f32, region: Rect, crop: CropInfo, ref: ?[]const u8 = null };
pub const WindowInfo = struct { id: u32, app: []const u8, title: []const u8, x: i32, y: i32, w: u32, h: u32 };

pub const Out = struct {
    w: *Writer,
    json: bool = false,

    pub fn snap(o: Out, s: SnapInfo) !void {
        const w = o.w;
        if (o.json) {
            try w.writeAll("{\"event\":\"snap\",\"source\":");
            try quote(w, s.source);
            try w.print(",\"size\":[{d},{d}],\"pixel_scale\":", .{ s.src_w, s.src_h });
            try num(w, s.pixel_scale);
            try w.writeAll(",\"region\":");
            try rectJson(w, s.region);
            try cropJson(w, s.crop);
            try w.writeAll(",\"ref\":");
            if (s.ref) |r| try quote(w, r) else try w.writeAll("null");
            return w.writeAll("}\n");
        }
        try w.print("snap source={s} size={d}x{d} pixel_scale=", .{ s.source, s.src_w, s.src_h });
        try num(w, s.pixel_scale);
        try w.print(" region={d},{d},{d},{d}", .{ s.region.x, s.region.y, s.region.w, s.region.h });
        try cropText(w, s.crop);
        if (s.ref) |r| try w.print(" ref={s}", .{r});
        try w.writeAll("\n");
    }

    pub fn event(o: Out, ev: watch.Event, crop: ?CropInfo, gone: []const u8) !void {
        const w = o.w;
        if (o.json) {
            try w.print("{{\"event\":\"{s}\",\"after_s\":", .{@tagName(ev)});
            try secs(w, atMs(ev));
            switch (ev) {
                .changed => |c| {
                    try w.writeAll(",\"boxes\":[");
                    for (c.boxes, 0..) |b, i| {
                        if (i > 0) try w.writeAll(",");
                        try rectJson(w, b);
                    }
                    try w.print("],\"total\":{d}", .{c.total});
                },
                .text => |t| {
                    try w.writeAll(",\"found\":");
                    try quote(w, t.line.text);
                    try w.writeAll(",\"box\":");
                    try rectJson(w, t.line.box);
                },
                .size_changed => |sc| try w.print(",\"size\":[{d},{d}]", .{ sc.w, sc.h }),
                .source_gone => {
                    try w.writeAll(",\"what\":");
                    try quote(w, gone);
                },
                .still, .timeout => {},
            }
            if (crop) |c| try cropJson(w, c);
            return w.writeAll("}\n");
        }
        switch (ev) {
            .changed => try w.writeAll("changed after="),
            .still => try w.writeAll("still after="),
            .text => try w.writeAll("text after="),
            .size_changed => try w.writeAll("size changed after="),
            .source_gone => try w.print("{s} after=", .{gone}),
            .timeout => try w.writeAll("timeout after="),
        }
        try secs(w, atMs(ev));
        try w.writeAll("s");
        switch (ev) {
            .changed => |c| try w.print(" boxes={d}", .{c.total}),
            .text => |t| {
                try w.writeAll(" found=");
                try quote(w, t.line.text);
                try w.print(" box={d},{d},{d},{d}", .{ t.line.box.x, t.line.box.y, t.line.box.w, t.line.box.h });
            },
            .size_changed => |sc| try w.print(" size={d}x{d}", .{ sc.w, sc.h }),
            else => {},
        }
        if (crop) |c| try cropText(w, c);
        try w.writeAll("\n");
        if (ev == .changed) {
            const c = ev.changed;
            for (c.boxes) |b| try w.print("  box {d},{d},{d},{d}\n", .{ b.x, b.y, b.w, b.h });
            if (c.total > c.boxes.len) try w.print("  ({d} more not shown)\n", .{c.total - c.boxes.len});
        }
    }

    pub fn diffResult(o: Out, name: []const u8, age_s: i64, bs: []const Rect, total: u32, crops: []const CropInfo) !void {
        const w = o.w;
        if (o.json) {
            try w.writeAll("{\"event\":\"diff\",\"since\":");
            try quote(w, name);
            try w.print(",\"age_s\":{d},\"total\":{d},\"boxes\":[", .{ age_s, total });
            for (bs, 0..) |b, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("{\"box\":");
                try rectJson(w, b);
                if (i < crops.len) try cropJson(w, crops[i]);
                try w.writeAll("}");
            }
            return w.writeAll("]}\n");
        }
        try w.print("diff since={s} age={d}s boxes={d}\n", .{ name, age_s, total });
        for (bs, 0..) |b, i| {
            try w.print("  box {d},{d},{d},{d}", .{ b.x, b.y, b.w, b.h });
            if (i < crops.len) try cropText(w, crops[i]);
            try w.writeAll("\n");
        }
        if (total > bs.len) try w.print("  ({d} more not shown)\n", .{total - bs.len});
    }

    pub fn textLines(o: Out, lines: []const watch.TextLine) !void {
        const w = o.w;
        if (o.json) {
            try w.writeAll("{\"lines\":[");
            for (lines, 0..) |l, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("{\"text\":");
                try quote(w, l.text);
                try w.writeAll(",\"box\":");
                try rectJson(w, l.box);
                try w.writeAll(",\"confidence\":");
                try num(w, l.confidence);
                try w.writeAll("}");
            }
            return w.writeAll("]}\n");
        }
        if (lines.len == 0) return w.writeAll("(no text)\n");
        for (lines) |l| {
            try w.writeAll("  ");
            try quote(w, l.text);
            try w.print(" box={d},{d},{d},{d}\n", .{ l.box.x, l.box.y, l.box.w, l.box.h });
        }
    }

    pub fn windows(o: Out, ws: []const WindowInfo) !void {
        const w = o.w;
        if (o.json) {
            try w.writeAll("{\"windows\":[");
            for (ws, 0..) |x, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"id\":{d},\"app\":", .{x.id});
                try quote(w, x.app);
                try w.writeAll(",\"title\":");
                try quote(w, x.title);
                try w.print(",\"size\":[{d},{d}],\"at\":[{d},{d}]}}", .{ x.w, x.h, x.x, x.y });
            }
            return w.writeAll("]}\n");
        }
        if (ws.len == 0) return w.writeAll("(no windows)\n");
        for (ws) |x| {
            try w.print("id={d} app=", .{x.id});
            try quote(w, x.app);
            try w.writeAll(" title=");
            try quote(w, x.title);
            try w.print(" size={d}x{d} at={d},{d}\n", .{ x.w, x.h, x.x, x.y });
        }
    }
};

fn atMs(ev: watch.Event) u64 {
    return switch (ev) {
        inline else => |v| v.at_ms,
    };
}

fn secs(w: *Writer, ms: u64) !void {
    try w.print("{d:.1}", .{@as(f64, @floatFromInt(ms)) / 1000.0});
}

/// 2 -> "2", 0.5 -> "0.5", 0.3386 -> "0.34".
fn num(w: *Writer, v: f32) !void {
    const r = @round(v);
    if (@abs(v - r) < 0.005) return w.print("{d}", .{@as(i64, @intFromFloat(r))});
    var buf: [32]u8 = undefined;
    var s = try std.fmt.bufPrint(&buf, "{d:.2}", .{v});
    while (s.len > 0 and s[s.len - 1] == '0') s = s[0 .. s.len - 1];
    try w.writeAll(s);
}

fn quote(w: *Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

fn rectJson(w: *Writer, r: Rect) !void {
    try w.print("[{d},{d},{d},{d}]", .{ r.x, r.y, r.w, r.h });
}

fn cropText(w: *Writer, c: CropInfo) !void {
    try w.print(" crop={s} origin={d},{d} scale=", .{ c.path, c.origin_x, c.origin_y });
    try num(w, c.scale);
}

fn cropJson(w: *Writer, c: CropInfo) !void {
    try w.writeAll(",\"crop\":");
    try quote(w, c.path);
    try w.print(",\"origin\":[{d},{d}],\"scale\":", .{ c.origin_x, c.origin_y });
    try num(w, c.scale);
}

pub const What = enum { screen, camera };

pub fn permission(w: *Writer, what: What, app: []const u8) !void {
    const name = switch (what) {
        .screen => "Screen Recording",
        .camera => "Camera",
    };
    try w.print("permission: {s} is off for \"{s}\". System Settings > Privacy & Security > {s}.\n", .{ name, app, name });
}

pub fn noGuiHost(w: *Writer) !void {
    try w.writeAll("permission: no app on this Mac started this process (ssh or launchd?), so macOS has nowhere to grant Screen Recording. Run the agent from a terminal app on this Mac.\n");
}

pub fn unsupported(w: *Writer) !void {
    try w.writeAll("headsight: screen and camera capture need macOS 14 or later; this platform is not supported yet.\n");
}

// ---- tests ----

const testing = std.testing;

fn expectOut(comptime f: anytype, a: anytype, want: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try @call(.auto, f, .{Out{ .w = &w }} ++ a);
    try testing.expectEqualStrings(want, w.buffered());
}

const test_crop = CropInfo{ .path = "/tmp/hs/1-1.png", .origin_x = 796, .origin_y = 424, .scale = 1 };

test "snap_line" {
    try expectOut(Out.snap, .{SnapInfo{ .source = "screen", .src_w = 3024, .src_h = 1964, .pixel_scale = 2, .region = .{ .x = 0, .y = 0, .w = 3024, .h = 1964 }, .crop = .{ .path = "/tmp/hs/1-1.png", .origin_x = 0, .origin_y = 0, .scale = 0.3386 }, .ref = "before" }}, "snap source=screen size=3024x1964 pixel_scale=2 region=0,0,3024,1964 crop=/tmp/hs/1-1.png origin=0,0 scale=0.34 ref=before\n");
}

test "changed_line" {
    const bs = [_]Rect{.{ .x = 812, .y = 440, .w = 388, .h = 96 }};
    try expectOut(Out.event, .{ watch.Event{ .changed = .{ .at_ms = 12_400, .boxes = &bs, .total = 1 } }, test_crop, "window closed" }, "changed after=12.4s boxes=1 crop=/tmp/hs/1-1.png origin=796,424 scale=1\n  box 812,440,388,96\n");
}

test "changed_more_than_shown" {
    const bs = [_]Rect{.{ .x = 1, .y = 2, .w = 3, .h = 4 }};
    try expectOut(Out.event, .{ watch.Event{ .changed = .{ .at_ms = 500, .boxes = &bs, .total = 3 } }, test_crop, "" }, "changed after=0.5s boxes=3 crop=/tmp/hs/1-1.png origin=796,424 scale=1\n  box 1,2,3,4\n  (2 more not shown)\n");
}

test "still_line" {
    try expectOut(Out.event, .{ watch.Event{ .still = .{ .at_ms = 2100 } }, CropInfo{ .path = "/p.png", .origin_x = 0, .origin_y = 0, .scale = 0.5 }, "" }, "still after=2.1s crop=/p.png origin=0,0 scale=0.5\n");
}

test "text_line" {
    const line = watch.TextLine{ .text = "Export \"Done\": 42 files", .box = .{ .x = 402, .y = 310, .w = 520, .h = 48 }, .confidence = 1 };
    try expectOut(Out.event, .{ watch.Event{ .text = .{ .at_ms = 31_000, .line = line } }, CropInfo{ .path = "/p.png", .origin_x = 386, .origin_y = 294, .scale = 1 }, "" }, "text after=31.0s found=\"Export \\\"Done\\\": 42 files\" box=402,310,520,48 crop=/p.png origin=386,294 scale=1\n");
}

test "size_gone_timeout_lines" {
    try expectOut(Out.event, .{ watch.Event{ .size_changed = .{ .at_ms = 3000, .w = 1200, .h = 800 } }, null, "" }, "size changed after=3.0s size=1200x800\n");
    try expectOut(Out.event, .{ watch.Event{ .source_gone = .{ .at_ms = 4200 } }, null, "window closed" }, "window closed after=4.2s\n");
    try expectOut(Out.event, .{ watch.Event{ .timeout = .{ .at_ms = 120_000 } }, null, "" }, "timeout after=120.0s\n");
}

test "diff_lines" {
    const bs = [_]Rect{ .{ .x = 10, .y = 10, .w = 100, .h = 40 }, .{ .x = 300, .y = 5, .w = 16, .h = 16 } };
    const cs = [_]CropInfo{ .{ .path = "/a.png", .origin_x = 0, .origin_y = 0, .scale = 1 }, .{ .path = "/b.png", .origin_x = 284, .origin_y = 0, .scale = 1 } };
    try expectOut(Out.diffResult, .{ "before", @as(i64, 42), &bs, @as(u32, 2), &cs }, "diff since=before age=42s boxes=2\n  box 10,10,100,40 crop=/a.png origin=0,0 scale=1\n  box 300,5,16,16 crop=/b.png origin=284,0 scale=1\n");
    try expectOut(Out.diffResult, .{ "before", @as(i64, 3), &[_]Rect{}, @as(u32, 0), &[_]CropInfo{} }, "diff since=before age=3s boxes=0\n");
}

test "text_lines" {
    const ls = [_]watch.TextLine{.{ .text = "Invoice 2026-118", .box = .{ .x = 120, .y = 80, .w = 410, .h = 40 }, .confidence = 0.9 }};
    try expectOut(Out.textLines, .{&ls}, "  \"Invoice 2026-118\" box=120,80,410,40\n");
    try expectOut(Out.textLines, .{&[_]watch.TextLine{}}, "(no text)\n");
}

test "windows_line" {
    const ws = [_]WindowInfo{.{ .id = 4512, .app = "Safari", .title = "Fixture", .x = 0, .y = 25, .w = 1440, .h = 900 }};
    try expectOut(Out.windows, .{&ws}, "id=4512 app=\"Safari\" title=\"Fixture\" size=1440x900 at=0,25\n");
}

test "crop_line_has_origin_and_scale" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try (Out{ .w = &w }).event(.{ .still = .{ .at_ms = 1 } }, .{ .path = "/c.png", .origin_x = 7, .origin_y = 9, .scale = 0.25 }, "");
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "origin=7,9 scale=0.25") != null);
}

test "json_changed_event" {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const bs = [_]Rect{.{ .x = 812, .y = 440, .w = 388, .h = 96 }};
    try (Out{ .w = &w, .json = true }).event(.{ .changed = .{ .at_ms = 12_400, .boxes = &bs, .total = 1 } }, test_crop, "");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("changed", o.get("event").?.string);
    try testing.expectEqual(@as(f64, 12.4), o.get("after_s").?.float);
    try testing.expectEqual(@as(i64, 388), o.get("boxes").?.array.items[0].array.items[2].integer);
    try testing.expectEqualStrings("/tmp/hs/1-1.png", o.get("crop").?.string);
    try testing.expectEqual(@as(i64, 796), o.get("origin").?.array.items[0].integer);
}

test "messages" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try permission(&w, .screen, "Terminal");
    try testing.expectEqualStrings("permission: Screen Recording is off for \"Terminal\". System Settings > Privacy & Security > Screen Recording.\n", w.buffered());
    w = .fixed(&buf);
    try permission(&w, .camera, "iTerm2");
    try testing.expectEqualStrings("permission: Camera is off for \"iTerm2\". System Settings > Privacy & Security > Camera.\n", w.buffered());
    w = .fixed(&buf);
    try noGuiHost(&w);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "permission: no app on this Mac started this process (ssh or launchd?)"));
    w = .fixed(&buf);
    try unsupported(&w);
    try testing.expectEqualStrings("headsight: screen and camera capture need macOS 14 or later; this platform is not supported yet.\n", w.buffered());
}

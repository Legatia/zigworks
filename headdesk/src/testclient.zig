//! A small Wayland client for the tests: what an app does, without an app.
//!
//! It opens one window (blue) with a button (red, at 20,20, 100x40). A
//! left click on the button opens a menu below it (green, 120x80, a popup
//! with a grab); a click in the menu closes it and turns the button
//! yellow. A key press paints a white bar along the top, one notch wider
//! per key. `--frames` makes it move a marker along the bottom on every
//! frame the server lets through. Everything it is told is printed, one line each.
const std = @import("std");
const sys = @import("sys.zig");
const wire = @import("wire.zig");

const gpa = std.heap.page_allocator;

var fd: sys.fd_t = undefined;
var out: wire.Out = .{};
var next_id: u32 = 3;

var compositor: u32 = 0;
var shm: u32 = 0;
var seat: u32 = 0;
var wm_base: u32 = 0;
var pointer: u32 = 0;
var keyboard: u32 = 0;

var surface: u32 = 0;
var xdg_surface: u32 = 0;
var toplevel: u32 = 0;
var width: i32 = 400;
var height: i32 = 300;
var button_yellow = false;
var keys_seen: u32 = 0;
var frames_seen: u32 = 0;
var animate = false;
var frame_cb: u32 = 0;
var last_frame_at: u32 = 0;

var popup_surface: u32 = 0;
var popup_xdg: u32 = 0;
var popup: u32 = 0;

var pointer_surface: u32 = 0;
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var last_serial: u32 = 0;

const Buf = struct { id: u32 = 0, map: ?sys.Mapping = null, w: i32 = 0, h: i32 = 0 };
var window_buf: Buf = .{};
var popup_buf: Buf = .{};

fn say(comptime fmt: []const u8, args: anytype) void {
    var b: [256]u8 = undefined;
    sys.writeAll(1, std.fmt.bufPrint(&b, fmt ++ "\n", args) catch return) catch {};
}

fn newId() u32 {
    defer next_id += 1;
    return next_id;
}

fn send(object: u32, opcode: u16, args: anytype) void {
    out.msg(gpa, object, opcode, args);
}

fn flush() void {
    if (out.bytes.items.len == 0) return;
    sys.sendWithFds(fd, out.bytes.items, out.fds.items) catch sys.exit(3);
    for (out.fds.items) |f| sys.close(f);
    out.bytes.clearRetainingCapacity();
    out.fds.clearRetainingCapacity();
}

/// A fresh shared-memory buffer of `w` x `h`, replacing `b`.
fn makeBuffer(b: *Buf, w: i32, h: i32) void {
    if (b.id != 0) send(b.id, 0, .{});
    if (b.map) |m| sys.unmap(m);
    const size: usize = @intCast(w * h * 4);
    const mem = sys.memfd("testclient", size) catch sys.exit(3);
    b.map = sys.mapShared(mem, size, true) catch sys.exit(3);
    const pool = newId();
    send(shm, 0, .{ pool, wire.Fd{ .fd = mem }, @as(i32, @intCast(size)) });
    b.id = newId();
    send(pool, 0, .{ b.id, @as(i32, 0), w, h, w * 4, @as(u32, 1) });
    send(pool, 1, .{});
    b.w = w;
    b.h = h;
}

fn fill(b: *Buf, x0: i32, y0: i32, w: i32, h: i32, color: u32) void {
    const px: []u32 = @alignCast(std.mem.bytesAsSlice(u32, b.map.?));
    var y = @max(0, y0);
    while (y < @min(b.h, y0 + h)) : (y += 1) {
        var x = @max(0, x0);
        while (x < @min(b.w, x0 + w)) : (x += 1) px[@intCast(y * b.w + x)] = color;
    }
}

/// Paints over what is there, part by part: the buffer is shared with the
/// server, which must never read a half-painted picture.
fn drawWindow() void {
    if (window_buf.w != width or window_buf.h != height) {
        makeBuffer(&window_buf, width, height);
        fill(&window_buf, 0, 0, width, height, 0xff2040c0);
    }
    fill(&window_buf, 20, 20, 100, 40, if (button_yellow) 0xffe0d020 else 0xffc02020);
    fill(&window_buf, 0, 0, @intCast(@min(@as(u32, @intCast(width)), keys_seen * 10)), 6, 0xffffffff);
    // a marker that moves one notch per frame, round and round
    const notches: u32 = @intCast(@divTrunc(width, 10));
    if (frames_seen > 0) fill(&window_buf, @intCast(((frames_seen - 1) % notches) * 10), height - 6, 10, 6, 0xff2040c0);
    fill(&window_buf, @intCast((frames_seen % notches) * 10), height - 6, 10, 6, 0xff20e0e0);
    send(surface, 1, .{ window_buf.id, @as(i32, 0), @as(i32, 0) });
    send(surface, 2, .{ @as(i32, 0), @as(i32, 0), width, height });
    if (animate) {
        frame_cb = newId();
        send(surface, 3, .{frame_cb});
    }
    send(surface, 6, .{});
}

fn openPopup() void {
    if (popup != 0) return;
    const positioner = newId();
    send(wm_base, 1, .{positioner});
    send(positioner, 1, .{ @as(i32, 120), @as(i32, 80) });
    send(positioner, 2, .{ @as(i32, 20), @as(i32, 20), @as(i32, 100), @as(i32, 40) });
    send(positioner, 3, .{@as(u32, 6)}); // anchor: bottom left
    send(positioner, 4, .{@as(u32, 8)}); // gravity: bottom right
    popup_surface = newId();
    send(compositor, 0, .{popup_surface});
    popup_xdg = newId();
    send(wm_base, 2, .{ popup_xdg, popup_surface });
    popup = newId();
    send(popup_xdg, 2, .{ popup, xdg_surface, positioner });
    send(popup, 1, .{ seat, last_serial });
    send(positioner, 0, .{});
    send(popup_surface, 6, .{});
    say("popup asked", .{});
}

fn closePopup() void {
    if (popup == 0) return;
    send(popup, 0, .{});
    send(popup_xdg, 0, .{});
    send(popup_surface, 0, .{});
    popup = 0;
    popup_xdg = 0;
    popup_surface = 0;
    say("popup closed", .{});
}

fn event(object: u32, opcode: u16, r: *wire.Reader) !void {
    if (object == 1) {
        if (opcode == 0) {
            _ = try r.uint();
            _ = try r.uint();
            say("error from the server: {s}", .{(try r.string()) orelse ""});
            flush();
            sys.exit(3);
        }
        return; // delete_id
    }
    if (object == 2) {
        if (opcode != 0) return;
        const name = try r.uint();
        const iface = (try r.string()) orelse "";
        const version = try r.uint();
        const want = [_]struct { n: []const u8, v: u32, id: *u32 }{
            .{ .n = "wl_compositor", .v = 4, .id = &compositor },
            .{ .n = "wl_shm", .v = 1, .id = &shm },
            .{ .n = "wl_seat", .v = 5, .id = &seat },
            .{ .n = "xdg_wm_base", .v = 2, .id = &wm_base },
        };
        for (want) |w| {
            if (!std.mem.eql(u8, iface, w.n)) continue;
            w.id.* = newId();
            send(2, 0, .{ name, w.n, @min(version, w.v), w.id.* });
        }
        return;
    }
    if (object == wm_base) {
        if (opcode == 0) send(wm_base, 3, .{try r.uint()});
        return;
    }
    if (object == seat) {
        if (opcode == 0) {
            const caps = try r.uint();
            if (caps & 1 != 0 and pointer == 0) {
                pointer = newId();
                send(seat, 0, .{pointer});
            }
            if (caps & 2 != 0 and keyboard == 0) {
                keyboard = newId();
                send(seat, 1, .{keyboard});
            }
        }
        return;
    }
    if (object == toplevel) {
        switch (opcode) {
            0 => {
                const w = try r.int();
                const h = try r.int();
                if (w > 0 and h > 0) {
                    width = w;
                    height = h;
                }
                say("configure {d}x{d}", .{ w, h });
            },
            1 => {
                say("close", .{});
                flush();
                sys.exit(0);
            },
            else => {},
        }
        return;
    }
    if (object == xdg_surface) {
        if (opcode == 0) {
            send(xdg_surface, 4, .{try r.uint()});
            drawWindow();
        }
        return;
    }
    if (popup != 0 and object == popup) {
        switch (opcode) {
            0 => say("popup configure {d},{d} {d}x{d}", .{ try r.int(), try r.int(), try r.int(), try r.int() }),
            1 => {
                say("popup done", .{});
                closePopup();
            },
            else => {},
        }
        return;
    }
    if (popup_xdg != 0 and object == popup_xdg) {
        if (opcode == 0) {
            send(popup_xdg, 4, .{try r.uint()});
            if (popup_buf.w != 120) makeBuffer(&popup_buf, 120, 80);
            fill(&popup_buf, 0, 0, 120, 80, 0xff20a040);
            send(popup_surface, 1, .{ popup_buf.id, @as(i32, 0), @as(i32, 0) });
            send(popup_surface, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, 120), @as(i32, 80) });
            send(popup_surface, 6, .{});
            say("popup drawn", .{});
        }
        return;
    }
    if (frame_cb != 0 and object == frame_cb) {
        frame_cb = 0;
        frames_seen += 1;
        const at = try r.uint();
        say("frame {d} +{d}", .{ frames_seen, if (frames_seen == 1) 0 else at -% last_frame_at });
        last_frame_at = at;
        drawWindow();
        return;
    }
    if (object == pointer) {
        switch (opcode) {
            0 => {
                last_serial = try r.uint();
                pointer_surface = try r.uint();
                pointer_x = @intFromFloat((try r.fixed()).toFloat());
                pointer_y = @intFromFloat((try r.fixed()).toFloat());
                say("enter {s} {d},{d}", .{ if (pointer_surface == surface) "window" else "popup", pointer_x, pointer_y });
            },
            1 => {
                say("leave", .{});
                pointer_surface = 0;
            },
            2 => {
                _ = try r.uint();
                pointer_x = @intFromFloat((try r.fixed()).toFloat());
                pointer_y = @intFromFloat((try r.fixed()).toFloat());
            },
            3 => {
                last_serial = try r.uint();
                _ = try r.uint();
                const button = try r.uint();
                const state = try r.uint();
                say("button 0x{x} {s} at {d},{d}", .{ button, if (state == 1) "down" else "up", pointer_x, pointer_y });
                if (state != 1 or button != 0x110) return;
                if (popup != 0 and pointer_surface == popup_surface) {
                    closePopup();
                    button_yellow = true;
                    drawWindow();
                } else if (popup != 0) {
                    closePopup();
                } else if (pointer_surface == surface and pointer_x >= 20 and pointer_x < 120 and pointer_y >= 20 and pointer_y < 60) {
                    openPopup();
                }
            },
            4 => {
                _ = try r.uint();
                const axis = try r.uint();
                say("scroll axis {d} by {d}", .{ axis, @as(i32, @intFromFloat((try r.fixed()).toFloat())) });
            },
            else => {},
        }
        return;
    }
    if (object == keyboard) {
        switch (opcode) {
            0 => {
                const format = try r.uint();
                const size = try r.uint();
                say("keymap format {d}, {d} bytes", .{ format, size });
            },
            1 => say("keyboard enter", .{}),
            2 => say("keyboard leave", .{}),
            3 => {
                _ = try r.uint();
                _ = try r.uint();
                const code = try r.uint();
                const state = try r.uint();
                say("key {d} {s}", .{ code, if (state == 1) "down" else "up" });
                if (state == 1) {
                    keys_seen += 1;
                    drawWindow();
                }
            },
            4 => {
                _ = try r.uint();
                say("modifiers {d}", .{try r.uint()});
            },
            else => {},
        }
        return;
    }
    // buffer releases, surface enter, callbacks of sync: nothing to do
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var runtime: []const u8 = "";
    var display: []const u8 = "wayland-0";
    for (init.environ.block.slice) |entry| {
        const e = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, e, "XDG_RUNTIME_DIR=")) runtime = e["XDG_RUNTIME_DIR=".len..];
        if (std.mem.startsWith(u8, e, "WAYLAND_DISPLAY=")) display = e["WAYLAND_DISPLAY=".len..];
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const args = init.args.toSlice(arena_state.allocator()) catch return 3;
    var title: []const u8 = "testclient";
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--frames")) animate = true else title = a;
    }
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ runtime, display }) catch return 3;
    fd = sys.connectUnix(path) catch {
        say("can't connect to {s}", .{path});
        return 3;
    };
    send(1, 1, .{@as(u32, 2)}); // get_registry

    var in: [wire.max_message * 2]u8 = undefined;
    var in_len: usize = 0;
    var fds: [sys.max_fds]sys.fd_t = undefined;
    var started = false;
    while (true) {
        if (!started and compositor != 0 and shm != 0 and wm_base != 0 and seat != 0) {
            started = true;
            surface = newId();
            send(compositor, 0, .{surface});
            xdg_surface = newId();
            send(wm_base, 2, .{ xdg_surface, surface });
            toplevel = newId();
            send(xdg_surface, 1, .{toplevel});
            send(toplevel, 2, .{title});
            send(toplevel, 3, .{@as([]const u8, "headdesk.testclient")});
            send(surface, 6, .{});
        }
        flush();
        var items = [_]sys.PollItem{sys.pollIn(fd)};
        sys.poll(&items, -1);
        const got = sys.recvWithFds(fd, in[in_len..], &fds) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return 3,
        };
        for (fds[0..got.fds]) |f| sys.close(f);
        if (got.bytes == 0) {
            say("the server went away", .{});
            return 0;
        }
        in_len += got.bytes;
        var pos: usize = 0;
        while (wire.header(in[pos..in_len])) |h| {
            if (h.size < wire.header_len or pos + h.size > in_len) break;
            var r: wire.Reader = .{ .data = in[pos + wire.header_len .. pos + h.size] };
            event(h.object, h.opcode, &r) catch return 3;
            pos += h.size;
        }
        std.mem.copyForwards(u8, in[0 .. in_len - pos], in[pos..in_len]);
        in_len -= pos;
    }
}

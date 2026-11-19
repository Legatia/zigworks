//! The display server: Wayland clients, their surfaces and windows, the
//! picture they add up to, and the input that is handed to them. One
//! thread; everything happens between two polls.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const wire = @import("wire.zig");
const keymap = @import("keymap.zig");

const Iface = enum {
    display,
    registry,
    compositor,
    region,
    shm,
    shm_pool,
    buffer,
    surface,
    seat,
    pointer,
    keyboard,
    touch,
    output,
    data_device_manager,
    data_source,
    data_device,
    subcompositor,
    subsurface,
    wm_base,
    positioner,
    xdg_surface,
    toplevel,
    popup,
    viewporter,
    viewport,
};

const Global = struct { iface: Iface, name: []const u8, version: u32 };

/// What apps can bind, in the order they are announced. The versions are
/// the highest whose every event this server sends.
const globals = [_]Global{
    .{ .iface = .compositor, .name = "wl_compositor", .version = 5 },
    .{ .iface = .subcompositor, .name = "wl_subcompositor", .version = 1 },
    .{ .iface = .shm, .name = "wl_shm", .version = 1 },
    .{ .iface = .seat, .name = "wl_seat", .version = 7 },
    .{ .iface = .output, .name = "wl_output", .version = 4 },
    .{ .iface = .data_device_manager, .name = "wl_data_device_manager", .version = 3 },
    .{ .iface = .wm_base, .name = "xdg_wm_base", .version = 3 },
    .{ .iface = .viewporter, .name = "wp_viewporter", .version = 1 },
};

const Object = struct { iface: Iface, version: u32, data: usize = 0 };

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }

    /// The smallest rectangle holding both; an empty one counts for nothing.
    pub fn join(a: Rect, b: Rect) Rect {
        if (a.w <= 0 or a.h <= 0) return b;
        if (b.w <= 0 or b.h <= 0) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
    }
};

const Pool = struct {
    fd: sys.fd_t,
    map: ?sys.Mapping,
    refs: u32 = 1,

    fn unref(p: *Pool, gpa: Allocator) void {
        p.refs -= 1;
        if (p.refs > 0) return;
        if (p.map) |m| sys.unmap(m);
        sys.close(p.fd);
        gpa.destroy(p);
    }
};

const Buffer = struct {
    id: u32,
    pool: *Pool,
    offset: i32,
    w: i32,
    h: i32,
    stride: i32,
    format: u32,
};

/// A wl_region: rectangles added and taken away, in order.
const Region = struct {
    const Op = struct { rect: Rect, add: bool };
    ops: std.ArrayList(Op) = .empty,

    /// Whether a point is in a region made of `ops`: the last rectangle
    /// that holds it decides.
    fn holds(ops: []const Op, x: i32, y: i32) bool {
        var i = ops.len;
        while (i > 0) {
            i -= 1;
            if (ops[i].rect.contains(x, y)) return ops[i].add;
        }
        return false;
    }
};

const Positioner = struct {
    w: i32 = 0,
    h: i32 = 0,
    anchor_rect: Rect = .{},
    anchor: u32 = 0,
    gravity: u32 = 0,
    off_x: i32 = 0,
    off_y: i32 = 0,

    /// Where the popup goes, relative to its parent's window.
    fn place(p: Positioner) Rect {
        const left = p.anchor == 3 or p.anchor == 5 or p.anchor == 6;
        const right = p.anchor == 4 or p.anchor == 7 or p.anchor == 8;
        const top = p.anchor == 1 or p.anchor == 5 or p.anchor == 7;
        const bottom = p.anchor == 2 or p.anchor == 6 or p.anchor == 8;
        var x = p.anchor_rect.x + (if (left) 0 else if (right) p.anchor_rect.w else @divTrunc(p.anchor_rect.w, 2)) + p.off_x;
        var y = p.anchor_rect.y + (if (top) 0 else if (bottom) p.anchor_rect.h else @divTrunc(p.anchor_rect.h, 2)) + p.off_y;
        const g_left = p.gravity == 3 or p.gravity == 5 or p.gravity == 6;
        const g_right = p.gravity == 4 or p.gravity == 7 or p.gravity == 8;
        const g_top = p.gravity == 1 or p.gravity == 5 or p.gravity == 7;
        const g_bottom = p.gravity == 2 or p.gravity == 6 or p.gravity == 8;
        if (g_left) x -= p.w else if (!g_right) x -= @divTrunc(p.w, 2);
        if (g_top) y -= p.h else if (!g_bottom) y -= @divTrunc(p.h, 2);
        return .{ .x = x, .y = y, .w = p.w, .h = p.h };
    }
};

pub const Role = enum { none, toplevel, popup, subsurface, cursor };

pub const Surface = struct {
    client: *Client,
    id: u32,
    role: Role = .none,
    xdg: ?*Xdg = null,
    /// A subsurface's parent and its place in it.
    parent: ?*Surface = null,
    sub_x: i32 = 0,
    sub_y: i32 = 0,

    // asked for, in force from the next commit
    pending_attach: bool = false,
    pending_buffer: ?*Buffer = null,
    pending_scale: i32 = 1,
    pending_frames: std.ArrayList(u32) = .empty,
    /// Set by set_input_region: the new region, null for "all of it".
    pending_input: ?[]Region.Op = null,
    pending_input_set: bool = false,
    scale: i32 = 1,
    view_dst: ?[2]i32 = null,
    view_src: ?[4]f64 = null,

    // in force
    pixels: []u32 = &.{},
    w: i32 = 0,
    h: i32 = 0,
    frames: std.ArrayList(u32) = .empty,
    /// Where the surface takes pointer input; null: everywhere on it.
    input: ?[]Region.Op = null,
    /// Top left corner on the desktop, set by `layout`.
    x: i32 = 0,
    y: i32 = 0,
    commits: u64 = 0,

    fn hasContent(s: *const Surface) bool {
        return s.pixels.len > 0;
    }
};

pub const Kind = enum { none, toplevel, popup };

pub const Xdg = struct {
    surface: *Surface,
    /// The xdg_surface object, and the xdg_toplevel or xdg_popup.
    id: u32,
    role_id: u32 = 0,
    kind: Kind = .none,
    /// The number the agent knows this window by.
    win: u32,
    /// The part of the surface that is the window (the rest is shadow).
    geom: ?Rect = null,
    title: []u8 = &.{},
    app_id: []u8 = &.{},
    parent: ?*Xdg = null,
    /// A popup's place relative to its parent's window.
    popup_rect: Rect = .{},
    grab: bool = false,
    configured: bool = false,
    mapped: bool = false,
    /// A toplevel's window corner on the desktop.
    place_x: i32 = 0,
    place_y: i32 = 0,

    pub fn geometry(x: *const Xdg) Rect {
        return x.geom orelse .{ .x = 0, .y = 0, .w = x.surface.w, .h = x.surface.h };
    }
};

pub const Client = struct {
    fd: sys.fd_t,
    num: u32,
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    in: [wire.max_message * 2]u8 = undefined,
    in_len: usize = 0,
    in_fds: std.ArrayList(sys.fd_t) = .empty,
    out: wire.Out = .{},
    dead: bool = false,
};

pub const Change = struct { ms: u64, win: u32, rect: Rect };

pub const Server = struct {
    gpa: Allocator,
    width: i32,
    height: i32,
    clients: std.ArrayList(*Client) = .empty,
    surfaces: std.ArrayList(*Surface) = .empty,
    /// Toplevels and popups, the topmost last.
    windows: std.ArrayList(*Xdg) = .empty,
    serial: u32 = 0,
    next_client: u32 = 1,
    next_win: u32 = 1,
    keymap_fd: sys.fd_t,
    keymap_size: u32,
    start_ms: u64,

    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_focus: ?*Surface = null,
    keyboard_focus: ?*Surface = null,
    mods: u32 = 0,

    /// Apps get no frame callbacks while frozen, except `step_budget` rounds.
    frozen: bool = false,
    step_budget: u32 = 0,
    /// Counts every commit that changed a surface's picture.
    changes: u64 = 0,
    last_change_ms: u64 = 0,
    /// Where pictures changed since `clearChanged`, on the desktop.
    changed: Rect = .{},

    log: std.ArrayList([]u8) = .empty,
    log_base: u64 = 0,
    /// Requests and interfaces this server does not know, once each.
    unknown: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: Allocator, width: i32, height: i32) !Server {
        const text = try keymap.text(gpa);
        defer gpa.free(text);
        const fd = try sys.memfdWith("headdesk-keymap", text);
        const now = sys.nowMs();
        return .{ .gpa = gpa, .width = width, .height = height, .keymap_fd = fd, .keymap_size = @intCast(text.len), .start_ms = now, .last_change_ms = now };
    }

    // -----------------------------------------------------------------
    // The log

    pub fn note(s: *Server, comptime fmt: []const u8, args: anytype) void {
        const max_lines = 20000;
        if (s.log.items.len >= max_lines) {
            const drop = max_lines / 4;
            for (s.log.items[0..drop]) |l| s.gpa.free(l);
            std.mem.copyForwards([]u8, s.log.items[0 .. s.log.items.len - drop], s.log.items[drop..]);
            s.log.shrinkRetainingCapacity(s.log.items.len - drop);
            s.log_base += drop;
        }
        const seq = s.log_base + s.log.items.len + 1;
        const line = std.fmt.allocPrint(s.gpa, "{d} {d}ms " ++ fmt, .{ seq, sys.nowMs() - s.start_ms } ++ args) catch return;
        s.log.append(s.gpa, line) catch s.gpa.free(line);
    }

    fn complain(s: *Server, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(s.gpa, fmt, args) catch return;
        for (s.unknown.items) |u| {
            if (std.mem.eql(u8, u, line)) {
                s.gpa.free(line);
                return;
            }
        }
        s.note("unknown {s}", .{line});
        s.unknown.append(s.gpa, line) catch s.gpa.free(line);
    }

    // -----------------------------------------------------------------
    // Clients

    pub fn addClient(s: *Server, fd: sys.fd_t) !void {
        const c = try s.gpa.create(Client);
        errdefer s.gpa.destroy(c);
        c.* = .{ .fd = fd, .num = s.next_client };
        s.next_client += 1;
        try c.objects.put(s.gpa, 1, .{ .iface = .display, .version = 1 });
        try s.clients.append(s.gpa, c);
        s.note("client {d} connected", .{c.num});
    }

    /// Reads what `c` sent and acts on every whole message.
    pub fn readClient(s: *Server, c: *Client) void {
        var fds: [sys.max_fds]sys.fd_t = undefined;
        const got = sys.recvWithFds(c.fd, c.in[c.in_len..], &fds) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                c.dead = true;
                return;
            },
        };
        for (fds[0..got.fds]) |fd| c.in_fds.append(s.gpa, fd) catch sys.close(fd);
        if (got.bytes == 0) {
            c.dead = true;
            return;
        }
        c.in_len += got.bytes;
        var pos: usize = 0;
        while (wire.header(c.in[pos..c.in_len])) |h| {
            if (h.size < wire.header_len or h.size > wire.max_message) {
                c.dead = true;
                return;
            }
            if (pos + h.size > c.in_len) break;
            var r: wire.Reader = .{ .data = c.in[pos + wire.header_len .. pos + h.size] };
            s.dispatch(c, h.object, h.opcode, &r) catch |err| switch (err) {
                error.Malformed => {
                    s.note("client {d}: a message that does not parse (object {d}, request {d})", .{ c.num, h.object, h.opcode });
                    c.dead = true;
                },
                error.OutOfMemory => c.dead = true,
            };
            if (c.dead) return;
            pos += h.size;
        }
        std.mem.copyForwards(u8, c.in[0 .. c.in_len - pos], c.in[pos..c.in_len]);
        c.in_len -= pos;
    }

    /// Sends what is waiting for every client and drops the dead ones.
    pub fn flush(s: *Server) void {
        var i: usize = 0;
        while (i < s.clients.items.len) {
            const c = s.clients.items[i];
            if (!c.dead and c.out.bytes.items.len > 0) {
                sys.sendWithFds(c.fd, c.out.bytes.items, c.out.fds.items) catch {
                    c.dead = true;
                };
                c.out.bytes.clearRetainingCapacity();
                c.out.fds.clearRetainingCapacity();
            }
            if (c.out.failed) c.dead = true;
            if (c.dead) {
                s.dropClient(c);
                _ = s.clients.orderedRemove(i);
            } else i += 1;
        }
    }

    fn dropClient(s: *Server, c: *Client) void {
        s.note("client {d} gone", .{c.num});
        var i: usize = s.surfaces.items.len;
        while (i > 0) {
            i -= 1;
            if (s.surfaces.items[i].client == c) s.destroySurface(s.surfaces.items[i]);
        }
        var it = c.objects.iterator();
        while (it.next()) |e| switch (e.value_ptr.iface) {
            .shm_pool => @as(*Pool, @ptrFromInt(e.value_ptr.data)).unref(s.gpa),
            .buffer => {
                const b: *Buffer = @ptrFromInt(e.value_ptr.data);
                b.pool.unref(s.gpa);
                s.gpa.destroy(b);
            },
            .positioner => s.gpa.destroy(@as(*Positioner, @ptrFromInt(e.value_ptr.data))),
            .region => {
                const region: *Region = @ptrFromInt(e.value_ptr.data);
                region.ops.deinit(s.gpa);
                s.gpa.destroy(region);
            },
            else => {},
        };
        c.objects.deinit(s.gpa);
        for (c.in_fds.items) |fd| sys.close(fd);
        c.in_fds.deinit(s.gpa);
        c.out.deinit(s.gpa);
        sys.close(c.fd);
        s.gpa.destroy(c);
    }

    fn nextSerial(s: *Server) u32 {
        s.serial +%= 1;
        return s.serial;
    }

    fn timeMs(s: *Server) u32 {
        return @truncate(sys.nowMs() - s.start_ms);
    }

    fn send(s: *Server, c: *Client, object: u32, opcode: u16, args: anytype) void {
        c.out.msg(s.gpa, object, opcode, args);
    }

    fn add(s: *Server, c: *Client, id: u32, iface: Iface, version: u32, data: usize) !void {
        try c.objects.put(s.gpa, id, .{ .iface = iface, .version = version, .data = data });
    }

    /// Forgets object `id` and tells the client its number is free again.
    fn remove(s: *Server, c: *Client, id: u32) void {
        _ = c.objects.remove(id);
        s.send(c, 1, 1, .{id});
    }

    fn takeFd(c: *Client) ?sys.fd_t {
        if (c.in_fds.items.len == 0) return null;
        return c.in_fds.orderedRemove(0);
    }

    fn surfaceOf(c: *Client, id: u32) ?*Surface {
        const o = c.objects.get(id) orelse return null;
        if (o.iface != .surface) return null;
        return @ptrFromInt(o.data);
    }

    // -----------------------------------------------------------------
    // Requests

    const DispatchError = error{ Malformed, OutOfMemory };

    fn dispatch(s: *Server, c: *Client, object: u32, opcode: u16, r: *wire.Reader) DispatchError!void {
        const o = c.objects.get(object) orelse return; // a request to an object just destroyed
        switch (o.iface) {
            .display => switch (opcode) {
                0 => {
                    const cb = try r.uint();
                    s.send(c, cb, 0, .{s.nextSerial()});
                    s.send(c, 1, 1, .{cb});
                },
                1 => {
                    const id = try r.uint();
                    try s.add(c, id, .registry, 1, 0);
                    for (globals, 1..) |g, name| s.send(c, id, 0, .{ @as(u32, @intCast(name)), g.name, g.version });
                },
                else => s.complain("wl_display request {d}", .{opcode}),
            },
            .registry => {
                const name = try r.uint();
                const iface = (try r.string()) orelse return error.Malformed;
                const version = try r.uint();
                const id = try r.uint();
                if (name == 0 or name > globals.len) return s.complain("bind of global {d} ({s})", .{ name, iface });
                const g = globals[name - 1];
                const v = @min(version, g.version);
                try s.add(c, id, g.iface, v, 0);
                s.note("client {d} binds {s} v{d}", .{ c.num, g.name, v });
                switch (g.iface) {
                    .shm => {
                        s.send(c, id, 0, .{@as(u32, 0)}); // argb8888
                        s.send(c, id, 0, .{@as(u32, 1)}); // xrgb8888
                    },
                    .seat => {
                        s.send(c, id, 0, .{@as(u32, 3)}); // pointer and keyboard
                        if (v >= 2) s.send(c, id, 1, .{@as([]const u8, "seat0")});
                    },
                    .output => {
                        s.send(c, id, 0, .{ @as(i32, 0), @as(i32, 0), @divTrunc(s.width * 254, 960), @divTrunc(s.height * 254, 960), @as(i32, 0), @as([]const u8, "headdesk"), @as([]const u8, "virtual"), @as(i32, 0) });
                        s.send(c, id, 1, .{ @as(u32, 3), s.width, s.height, @as(i32, 60000) });
                        if (v >= 2) s.send(c, id, 3, .{@as(i32, 1)});
                        if (v >= 4) {
                            s.send(c, id, 4, .{@as([]const u8, "HEADDESK-1")});
                            s.send(c, id, 5, .{@as([]const u8, "headdesk virtual output")});
                        }
                        if (v >= 2) s.send(c, id, 2, .{});
                    },
                    else => {},
                }
            },
            .compositor => switch (opcode) {
                0 => {
                    const id = try r.uint();
                    const surf = try s.gpa.create(Surface);
                    errdefer s.gpa.destroy(surf);
                    surf.* = .{ .client = c, .id = id };
                    try s.surfaces.append(s.gpa, surf);
                    try s.add(c, id, .surface, o.version, @intFromPtr(surf));
                },
                1 => {
                    const region = try s.gpa.create(Region);
                    region.* = .{};
                    try s.add(c, try r.uint(), .region, 1, @intFromPtr(region));
                },
                else => s.complain("wl_compositor request {d}", .{opcode}),
            },
            .region => {
                const region: *Region = @ptrFromInt(o.data);
                switch (opcode) {
                    0 => {
                        region.ops.deinit(s.gpa);
                        s.gpa.destroy(region);
                        s.remove(c, object);
                    },
                    1, 2 => try region.ops.append(s.gpa, .{ .rect = .{ .x = try r.int(), .y = try r.int(), .w = try r.int(), .h = try r.int() }, .add = opcode == 1 }),
                    else => s.complain("wl_region request {d}", .{opcode}),
                }
            },
            .shm => switch (opcode) {
                0 => {
                    const id = try r.uint();
                    const fd = takeFd(c) orelse return error.Malformed;
                    const size = try r.int();
                    const pool = try s.gpa.create(Pool);
                    pool.* = .{ .fd = fd, .map = if (size > 0) sys.mapShared(fd, @intCast(size), false) catch null else null };
                    try s.add(c, id, .shm_pool, 1, @intFromPtr(pool));
                },
                else => s.remove(c, object),
            },
            .shm_pool => {
                const pool: *Pool = @ptrFromInt(o.data);
                switch (opcode) {
                    0 => {
                        const id = try r.uint();
                        const b = try s.gpa.create(Buffer);
                        b.* = .{ .id = id, .pool = pool, .offset = try r.int(), .w = try r.int(), .h = try r.int(), .stride = try r.int(), .format = try r.uint() };
                        pool.refs += 1;
                        try s.add(c, id, .buffer, 1, @intFromPtr(b));
                    },
                    1 => {
                        pool.unref(s.gpa);
                        s.remove(c, object);
                    },
                    2 => {
                        const size = try r.int();
                        if (pool.map) |m| sys.unmap(m);
                        pool.map = if (size > 0) sys.mapShared(pool.fd, @intCast(size), false) catch null else null;
                    },
                    else => s.complain("wl_shm_pool request {d}", .{opcode}),
                }
            },
            .buffer => if (opcode == 0) {
                const b: *Buffer = @ptrFromInt(o.data);
                for (s.surfaces.items) |surf| {
                    if (surf.pending_buffer == b) surf.pending_buffer = null;
                }
                b.pool.unref(s.gpa);
                s.gpa.destroy(b);
                s.remove(c, object);
            },
            .surface => try s.surfaceRequest(c, @ptrFromInt(o.data), opcode, r),
            .seat => switch (opcode) {
                0 => try s.add(c, try r.uint(), .pointer, o.version, 0),
                1 => {
                    const id = try r.uint();
                    try s.add(c, id, .keyboard, o.version, 0);
                    s.send(c, id, 0, .{ @as(u32, 1), wire.Fd{ .fd = s.keymap_fd }, s.keymap_size });
                    if (o.version >= 4) s.send(c, id, 5, .{ @as(i32, 25), @as(i32, 600) });
                    if (s.keyboard_focus) |f| {
                        if (f.client == c) {
                            s.send(c, id, 1, .{ s.nextSerial(), f.id, wire.Array{ .bytes = "" } });
                            s.send(c, id, 4, .{ s.nextSerial(), s.mods, @as(u32, 0), @as(u32, 0), @as(u32, 0) });
                        }
                    }
                },
                2 => try s.add(c, try r.uint(), .touch, o.version, 0),
                3 => s.remove(c, object),
                else => s.complain("wl_seat request {d}", .{opcode}),
            },
            .pointer => switch (opcode) {
                0 => {
                    _ = try r.uint();
                    if (surfaceOf(c, try r.uint())) |surf| {
                        if (surf.role == .none) surf.role = .cursor;
                    }
                },
                else => s.remove(c, object),
            },
            .keyboard, .touch => s.remove(c, object),
            .output => if (opcode == 0) s.remove(c, object),
            .data_device_manager => switch (opcode) {
                0 => try s.add(c, try r.uint(), .data_source, o.version, 0),
                1 => try s.add(c, try r.uint(), .data_device, o.version, 0),
                else => s.complain("wl_data_device_manager request {d}", .{opcode}),
            },
            .data_source => if (opcode == 1) s.remove(c, object),
            .data_device => if (opcode == 2) s.remove(c, object),
            .subcompositor => switch (opcode) {
                0 => s.remove(c, object),
                1 => {
                    const id = try r.uint();
                    const surf = surfaceOf(c, try r.uint()) orelse return error.Malformed;
                    const parent = surfaceOf(c, try r.uint()) orelse return error.Malformed;
                    surf.role = .subsurface;
                    surf.parent = parent;
                    try s.add(c, id, .subsurface, 1, @intFromPtr(surf));
                },
                else => s.complain("wl_subcompositor request {d}", .{opcode}),
            },
            .subsurface => {
                const surf: *Surface = @ptrFromInt(o.data);
                switch (opcode) {
                    0 => {
                        if (s.alive(surf)) {
                            surf.parent = null;
                            s.touch(surf);
                        }
                        s.remove(c, object);
                    },
                    1 => if (s.alive(surf)) {
                        surf.sub_x = try r.int();
                        surf.sub_y = try r.int();
                    },
                    else => {}, // stacking order and sync mode: every commit applies at once
                }
            },
            .wm_base => switch (opcode) {
                0 => s.remove(c, object),
                1 => {
                    const p = try s.gpa.create(Positioner);
                    p.* = .{};
                    try s.add(c, try r.uint(), .positioner, o.version, @intFromPtr(p));
                },
                2 => {
                    const id = try r.uint();
                    const surf = surfaceOf(c, try r.uint()) orelse return error.Malformed;
                    const x = try s.gpa.create(Xdg);
                    x.* = .{ .surface = surf, .id = id, .win = 0 };
                    surf.xdg = x;
                    try s.add(c, id, .xdg_surface, o.version, @intFromPtr(x));
                },
                3 => {},
                else => s.complain("xdg_wm_base request {d}", .{opcode}),
            },
            .positioner => {
                const p: *Positioner = @ptrFromInt(o.data);
                switch (opcode) {
                    0 => {
                        s.gpa.destroy(p);
                        s.remove(c, object);
                    },
                    1 => {
                        p.w = try r.int();
                        p.h = try r.int();
                    },
                    2 => p.anchor_rect = .{ .x = try r.int(), .y = try r.int(), .w = try r.int(), .h = try r.int() },
                    3 => p.anchor = try r.uint(),
                    4 => p.gravity = try r.uint(),
                    6 => {
                        p.off_x = try r.int();
                        p.off_y = try r.int();
                    },
                    else => {}, // constraint adjustment, reactive, parent size: popups are always slid onto the desktop
                }
            },
            .xdg_surface => try s.xdgRequest(c, object, @ptrFromInt(o.data), opcode, r),
            .toplevel => {
                const x: *Xdg = @ptrFromInt(o.data);
                switch (opcode) {
                    0 => {
                        s.unrole(x);
                        s.remove(c, object);
                    },
                    1 => {
                        const parent_id = try r.uint();
                        x.parent = if (c.objects.get(parent_id)) |po| (if (po.iface == .toplevel) @as(*Xdg, @ptrFromInt(po.data)) else null) else null;
                    },
                    2 => {
                        const title = (try r.string()) orelse "";
                        s.gpa.free(x.title);
                        x.title = try s.gpa.dupe(u8, title);
                        if (x.mapped) s.note("window {d} title \"{s}\"", .{ x.win, x.title });
                    },
                    3 => {
                        const app = (try r.string()) orelse "";
                        s.gpa.free(x.app_id);
                        x.app_id = try s.gpa.dupe(u8, app);
                    },
                    else => {}, // move, resize, maximize, minimize, size limits: a window fills the desktop
                }
            },
            .popup => {
                const x: *Xdg = @ptrFromInt(o.data);
                switch (opcode) {
                    0 => {
                        s.unrole(x);
                        s.remove(c, object);
                    },
                    1 => x.grab = true,
                    2 => {
                        const po = c.objects.get(try r.uint()) orelse return error.Malformed;
                        if (po.iface != .positioner) return error.Malformed;
                        const token = try r.uint();
                        x.popup_rect = s.popupRect(x, @as(*Positioner, @ptrFromInt(po.data)).*);
                        s.send(c, object, 2, .{token});
                        s.sendConfigure(x);
                    },
                    else => s.complain("xdg_popup request {d}", .{opcode}),
                }
            },
            .viewporter => switch (opcode) {
                0 => s.remove(c, object),
                1 => {
                    const id = try r.uint();
                    const surf = surfaceOf(c, try r.uint()) orelse return error.Malformed;
                    try s.add(c, id, .viewport, 1, @intFromPtr(surf));
                },
                else => s.complain("wp_viewporter request {d}", .{opcode}),
            },
            .viewport => {
                const surf: *Surface = @ptrFromInt(o.data);
                const live = s.alive(surf);
                switch (opcode) {
                    0 => {
                        if (live) {
                            surf.view_dst = null;
                            surf.view_src = null;
                        }
                        s.remove(c, object);
                    },
                    1 => {
                        const v = [4]f64{ (try r.fixed()).toFloat(), (try r.fixed()).toFloat(), (try r.fixed()).toFloat(), (try r.fixed()).toFloat() };
                        if (live) surf.view_src = if (v[2] < 0 or v[3] < 0) null else v;
                    },
                    2 => {
                        const w = try r.int();
                        const h = try r.int();
                        if (live) surf.view_dst = if (w <= 0 or h <= 0) null else .{ w, h };
                    },
                    else => s.complain("wp_viewport request {d}", .{opcode}),
                }
            },
        }
    }

    /// Whether `surf` still exists (a subsurface or viewport object can
    /// outlive its surface).
    fn alive(s: *Server, surf: *Surface) bool {
        return std.mem.findScalar(*Surface, s.surfaces.items, surf) != null;
    }

    fn surfaceRequest(s: *Server, c: *Client, surf: *Surface, opcode: u16, r: *wire.Reader) DispatchError!void {
        switch (opcode) {
            0 => {
                const id = surf.id;
                s.destroySurface(surf);
                s.remove(c, id);
            },
            1 => {
                const id = try r.uint();
                surf.pending_attach = true;
                surf.pending_buffer = if (c.objects.get(id)) |bo| (if (bo.iface == .buffer) @as(*Buffer, @ptrFromInt(bo.data)) else null) else null;
            },
            3 => try surf.pending_frames.append(s.gpa, try r.uint()),
            5 => {
                const id = try r.uint();
                if (surf.pending_input) |old| s.gpa.free(old);
                surf.pending_input = null;
                surf.pending_input_set = true;
                if (c.objects.get(id)) |ro| {
                    if (ro.iface == .region) surf.pending_input = try s.gpa.dupe(Region.Op, @as(*Region, @ptrFromInt(ro.data)).ops.items);
                }
            },
            6 => try s.commit(surf),
            8 => surf.pending_scale = @max(1, try r.int()),
            else => {}, // damage, opaque region, transform, offset: the whole surface is taken on every commit
        }
    }

    fn xdgRequest(s: *Server, c: *Client, object: u32, x: *Xdg, opcode: u16, r: *wire.Reader) DispatchError!void {
        switch (opcode) {
            0 => {
                s.unrole(x);
                if (s.alive(x.surface) and x.surface.xdg == x) x.surface.xdg = null;
                s.gpa.free(x.title);
                s.gpa.free(x.app_id);
                // a child keeps no pointer to a parent that is gone
                for (s.windows.items) |w| {
                    if (w.parent == x) w.parent = null;
                }
                s.gpa.destroy(x);
                s.remove(c, object);
            },
            1 => {
                const id = try r.uint();
                x.kind = .toplevel;
                x.role_id = id;
                x.surface.role = .toplevel;
                x.win = s.next_win;
                s.next_win += 1;
                try s.windows.append(s.gpa, x);
                try s.add(c, id, .toplevel, 1, @intFromPtr(x));
            },
            2 => {
                const id = try r.uint();
                const parent_id = try r.uint();
                const po = c.objects.get(try r.uint()) orelse return error.Malformed;
                if (po.iface != .positioner) return error.Malformed;
                x.kind = .popup;
                x.role_id = id;
                x.surface.role = .popup;
                x.win = s.next_win;
                s.next_win += 1;
                x.parent = if (c.objects.get(parent_id)) |parent| (if (parent.iface == .xdg_surface) @as(*Xdg, @ptrFromInt(parent.data)) else null) else null;
                x.popup_rect = s.popupRect(x, @as(*Positioner, @ptrFromInt(po.data)).*);
                try s.windows.append(s.gpa, x);
                try s.add(c, id, .popup, 1, @intFromPtr(x));
            },
            3 => x.geom = .{ .x = try r.int(), .y = try r.int(), .w = try r.int(), .h = try r.int() },
            4 => {},
            else => s.complain("xdg_surface request {d}", .{opcode}),
        }
    }

    /// A popup's place from its positioner, slid so that it lies on the desktop.
    fn popupRect(s: *Server, x: *Xdg, p: Positioner) Rect {
        var rect = p.place();
        const parent = x.parent orelse return rect;
        const base = s.origin(parent);
        const ax = std.math.clamp(base.x + rect.x, 0, @max(0, s.width - rect.w));
        const ay = std.math.clamp(base.y + rect.y, 0, @max(0, s.height - rect.h));
        rect.x = ax - base.x;
        rect.y = ay - base.y;
        return rect;
    }

    /// The desktop position of the top left corner of `x`'s window.
    fn origin(s: *Server, x: *const Xdg) struct { x: i32, y: i32 } {
        if (x.kind == .popup) {
            if (x.parent) |parent| {
                const o = s.origin(parent);
                return .{ .x = o.x + x.popup_rect.x, .y = o.y + x.popup_rect.y };
            }
        }
        return .{ .x = x.place_x, .y = x.place_y };
    }

    fn sendConfigure(s: *Server, x: *Xdg) void {
        const c = x.surface.client;
        switch (x.kind) {
            .toplevel => {
                // A window with a parent (a dialog) chooses its own size;
                // any other fills the desktop.
                var states: [8]u8 = undefined;
                std.mem.writeInt(u32, states[0..4], 4, .little); // activated
                std.mem.writeInt(u32, states[4..8], 1, .little); // maximized
                if (x.parent != null) {
                    s.send(c, x.role_id, 0, .{ @as(i32, 0), @as(i32, 0), wire.Array{ .bytes = states[0..4] } });
                } else {
                    s.send(c, x.role_id, 0, .{ s.width, s.height, wire.Array{ .bytes = &states } });
                }
            },
            .popup => s.send(c, x.role_id, 0, .{ x.popup_rect.x, x.popup_rect.y, x.popup_rect.w, x.popup_rect.h }),
            .none => return,
        }
        s.send(c, x.id, 0, .{s.nextSerial()});
        x.configured = true;
    }

    fn commit(s: *Server, surf: *Surface) !void {
        // the part of the surface whose picture is different now
        var changed: Rect = .{};
        surf.scale = surf.pending_scale;
        if (surf.pending_attach) {
            surf.pending_attach = false;
            const before = s.surfaceRect(surf);
            if (surf.pending_buffer) |b| {
                changed = s.takePixels(surf, b) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadBuffer => blk: {
                        s.note("client {d}: a buffer that does not fit its pool", .{surf.client.num});
                        break :blk Rect{};
                    },
                };
                s.send(surf.client, b.id, 0, .{});
                // another size: the old place changed too
                if (before.w != surf.w or before.h != surf.h) s.changed = s.changed.join(before);
            } else if (surf.hasContent()) {
                s.gpa.free(surf.pixels);
                surf.pixels = &.{};
                surf.w = 0;
                surf.h = 0;
                s.changed = s.changed.join(before);
                s.changes += 1;
                s.last_change_ms = sys.nowMs();
            }
            surf.pending_buffer = null;
        }
        try surf.frames.appendSlice(s.gpa, surf.pending_frames.items);
        surf.pending_frames.clearRetainingCapacity();
        surf.commits += 1;
        if (surf.pending_input_set) {
            if (surf.input) |old| s.gpa.free(old);
            surf.input = surf.pending_input;
            surf.pending_input = null;
            surf.pending_input_set = false;
        }

        if (surf.xdg) |x| {
            if (x.kind != .none and !x.configured) {
                s.sendConfigure(x);
            } else if (x.kind != .none) {
                const now_mapped = surf.hasContent();
                if (now_mapped and !x.mapped) s.mapped(x);
                if (!now_mapped and x.mapped) {
                    s.unmapped(x);
                    x.configured = false;
                }
            }
        }
        if (changed.w > 0) s.drew(surf, changed);
    }

    /// Records that part `local` of `surf`'s picture changed.
    fn drew(s: *Server, surf: *Surface, local: Rect) void {
        if (surf.role == .cursor or surf.role == .none) return;
        s.changes += 1;
        s.last_change_ms = sys.nowMs();
        s.layout();
        const whole = s.surfaceRect(surf);
        const x0 = @max(whole.x, surf.x + local.x);
        const y0 = @max(whole.y, surf.y + local.y);
        const x1 = @min(whole.x + whole.w, surf.x + local.x + local.w);
        const y1 = @min(whole.y + whole.h, surf.y + local.y + local.h);
        if (x1 > x0 and y1 > y0) s.changed = s.changed.join(.{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 });
        var root = surf;
        while (root.parent) |p| root = p;
        const win: u32 = if (root.xdg) |x| x.win else 0;
        s.note("draw window {d} surface {d} {d}x{d} changed {d},{d} {d}x{d}", .{ win, surf.id, surf.w, surf.h, local.x, local.y, local.w, local.h });
    }

    /// Records that `surf` came, went or moved as a whole.
    fn touch(s: *Server, surf: *Surface) void {
        s.changes += 1;
        s.last_change_ms = sys.nowMs();
        s.layout();
        s.changed = s.changed.join(s.surfaceRect(surf));
    }

    fn surfaceRect(s: *Server, surf: *const Surface) Rect {
        if (!surf.hasContent() or surf.role == .cursor or surf.role == .none) return .{};
        const r: Rect = .{ .x = surf.x, .y = surf.y, .w = surf.w, .h = surf.h };
        const x0 = @max(r.x, 0);
        const y0 = @max(r.y, 0);
        const x1 = @min(r.x + r.w, s.width);
        const y1 = @min(r.y + r.h, s.height);
        if (x1 <= x0 or y1 <= y0) return .{};
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Copies the buffer's picture into the surface, through its scale
    /// and viewport. Returns the part of the surface that is different
    /// from before: empty when the app drew the same picture again.
    fn takePixels(s: *Server, surf: *Surface, b: *Buffer) error{ OutOfMemory, BadBuffer }!Rect {
        const map = b.pool.map orelse return error.BadBuffer;
        if (b.w <= 0 or b.h <= 0 or b.stride < b.w * 4 or b.offset < 0) return error.BadBuffer;
        const need = @as(usize, @intCast(b.offset)) + @as(usize, @intCast(b.stride)) * @as(usize, @intCast(b.h - 1)) + @as(usize, @intCast(b.w)) * 4;
        if (need > map.len) return error.BadBuffer;
        if (b.format > 1) return error.BadBuffer;

        const scale: f64 = @floatFromInt(surf.scale);
        // the part of the buffer shown, in buffer pixels
        var sx: f64 = 0;
        var sy: f64 = 0;
        var sw: f64 = @floatFromInt(b.w);
        var sh: f64 = @floatFromInt(b.h);
        if (surf.view_src) |v| {
            sx = v[0] * scale;
            sy = v[1] * scale;
            sw = v[2] * scale;
            sh = v[3] * scale;
        }
        var dw: i32 = @intFromFloat(@ceil(sw / scale));
        var dh: i32 = @intFromFloat(@ceil(sh / scale));
        if (surf.view_dst) |d| {
            dw = d[0];
            dh = d[1];
        }
        if (dw <= 0 or dh <= 0 or dw > 16384 or dh > 16384) return error.BadBuffer;

        const count = @as(usize, @intCast(dw)) * @as(usize, @intCast(dh));
        const resized = surf.w != dw or surf.h != dh;
        if (surf.pixels.len != count) {
            const fresh = try s.gpa.alloc(u32, count);
            s.gpa.free(surf.pixels);
            surf.pixels = fresh;
        }
        surf.w = dw;
        surf.h = dh;
        var min_x: usize = std.math.maxInt(usize);
        var max_x: usize = 0;
        var min_y: usize = std.math.maxInt(usize);
        var max_y: usize = 0;
        const opaque_mask: u32 = if (b.format == 1) 0xff000000 else 0;
        const bw: usize = @intCast(b.w);
        const bh: usize = @intCast(b.h);
        const base: usize = @intCast(b.offset);
        const stride: usize = @intCast(b.stride);
        const udw: usize = @intCast(dw);
        const same = sx == 0 and sy == 0 and @as(i32, @intFromFloat(sw)) == dw and @as(i32, @intFromFloat(sh)) == dh;
        for (0..@intCast(dh)) |y| {
            const by: usize = if (same) y else @min(bh - 1, @as(usize, @intFromFloat(@max(0, sy + (@as(f64, @floatFromInt(y)) + 0.5) * sh / @as(f64, @floatFromInt(dh))))));
            const row = map[base + by * stride ..];
            const dst = surf.pixels[y * udw ..][0..udw];
            var first: usize = udw;
            var last: usize = 0;
            for (dst, 0..) |*d, x| {
                const bx: usize = if (same) x else @min(bw - 1, @as(usize, @intFromFloat(@max(0, sx + (@as(f64, @floatFromInt(x)) + 0.5) * sw / @as(f64, @floatFromInt(dw))))));
                const v = std.mem.readInt(u32, row[bx * 4 ..][0..4], .little) | opaque_mask;
                if (d.* != v) {
                    d.* = v;
                    if (first == udw) first = x;
                    last = x;
                }
            }
            if (first != udw) {
                min_x = @min(min_x, first);
                max_x = @max(max_x, last);
                min_y = @min(min_y, y);
                max_y = y;
            }
        }
        if (resized) return .{ .x = 0, .y = 0, .w = dw, .h = dh };
        if (min_y > max_y) return .{};
        return .{ .x = @intCast(min_x), .y = @intCast(min_y), .w = @intCast(max_x - min_x + 1), .h = @intCast(max_y - min_y + 1) };
    }

    fn mapped(s: *Server, x: *Xdg) void {
        x.mapped = true;
        const c = x.surface.client;
        // the surface is on the one output
        var it = c.objects.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.iface == .output) s.send(c, x.surface.id, 0, .{e.key_ptr.*});
        }
        s.layout();
        const g = x.geometry();
        const o = s.origin(x);
        s.note("window {d} opens: {s} \"{s}\" at {d},{d} size {d}x{d}", .{ x.win, @tagName(x.kind), x.title, o.x, o.y, g.w, g.h });
        if (x.kind == .toplevel or x.grab) s.focusKeyboard(x.surface);
        s.repick();
    }

    fn unmapped(s: *Server, x: *Xdg) void {
        if (!x.mapped) return;
        x.mapped = false;
        s.changed = s.changed.join(s.surfaceRect(x.surface));
        s.changes += 1;
        s.last_change_ms = sys.nowMs();
        s.note("window {d} closes", .{x.win});
        if (s.keyboard_focus == x.surface) {
            // back to the window it belonged to, or the topmost one left
            var next: ?*Surface = null;
            if (x.parent) |p| {
                if (p.mapped) next = p.surface;
            }
            if (next == null) {
                var i = s.windows.items.len;
                while (i > 0) {
                    i -= 1;
                    const w = s.windows.items[i];
                    if (w != x and w.mapped and w.kind == .toplevel) {
                        next = w.surface;
                        break;
                    }
                }
            }
            s.focusKeyboard(next);
        }
        s.repick();
    }

    /// The window role ends: the window is gone from the desktop.
    fn unrole(s: *Server, x: *Xdg) void {
        s.unmapped(x);
        if (std.mem.findScalar(*Xdg, s.windows.items, x)) |i| _ = s.windows.orderedRemove(i);
        x.kind = .none;
        x.configured = false;
        x.grab = false;
        if (s.alive(x.surface)) x.surface.role = .none;
    }

    fn destroySurface(s: *Server, surf: *Surface) void {
        if (surf.xdg) |x| {
            s.unrole(x);
        }
        s.changed = s.changed.join(s.surfaceRect(surf));
        if (s.pointer_focus == surf) s.pointer_focus = null;
        if (s.keyboard_focus == surf) s.keyboard_focus = null;
        for (s.surfaces.items) |other| {
            if (other.parent == surf) other.parent = null;
        }
        if (std.mem.findScalar(*Surface, s.surfaces.items, surf)) |i| _ = s.surfaces.orderedRemove(i);
        if (surf.xdg) |x| {
            // nothing may reach the freed surface through the window
            if (std.mem.findScalar(*Xdg, s.windows.items, x)) |i| _ = s.windows.orderedRemove(i);
        }
        s.gpa.free(surf.pixels);
        if (surf.input) |ops| s.gpa.free(ops);
        if (surf.pending_input) |ops| s.gpa.free(ops);
        surf.pending_frames.deinit(s.gpa);
        surf.frames.deinit(s.gpa);
        s.gpa.destroy(surf);
    }

    // -----------------------------------------------------------------
    // Frames

    /// Tells apps that asked that it is time to draw again. Returns
    /// whether anyone was told.
    pub fn frameTick(s: *Server) bool {
        if (s.frozen) {
            if (s.step_budget == 0) return false;
        }
        var any = false;
        const t = s.timeMs();
        for (s.surfaces.items) |surf| {
            if (surf.frames.items.len == 0) continue;
            any = true;
            for (surf.frames.items) |cb| {
                s.send(surf.client, cb, 0, .{t});
                s.send(surf.client, 1, 1, .{cb});
            }
            surf.frames.clearRetainingCapacity();
        }
        if (any and s.frozen) {
            s.step_budget -= 1;
            s.note("step: one frame let through", .{});
        }
        return any;
    }

    /// Whether any app waits to be told to draw.
    pub fn framesWaiting(s: *const Server) bool {
        for (s.surfaces.items) |surf| {
            if (surf.frames.items.len > 0) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------
    // The picture

    /// Gives every surface its place on the desktop.
    pub fn layout(s: *Server) void {
        for (s.windows.items) |x| {
            if (x.kind == .toplevel) {
                const g = x.geometry();
                if (x.parent != null) {
                    x.place_x = @max(0, @divTrunc(s.width - g.w, 2));
                    x.place_y = @max(0, @divTrunc(s.height - g.h, 2));
                } else {
                    x.place_x = 0;
                    x.place_y = 0;
                }
            }
        }
        for (s.windows.items) |x| {
            const g = x.geometry();
            const o = s.origin(x);
            x.surface.x = o.x - g.x;
            x.surface.y = o.y - g.y;
        }
        // subsurfaces follow their parents; parents are created first
        for (s.surfaces.items) |surf| {
            if (surf.role == .subsurface) {
                if (surf.parent) |p| {
                    surf.x = p.x + surf.sub_x;
                    surf.y = p.y + surf.sub_y;
                }
            }
        }
    }

    pub const background: u32 = 0xff2b2b2b;

    /// The whole desktop, `width * height` pixels of 0xAARRGGBB.
    pub fn render(s: *Server, gpa: Allocator) ![]u32 {
        s.layout();
        const out = try gpa.alloc(u32, @as(usize, @intCast(s.width)) * @as(usize, @intCast(s.height)));
        @memset(out, background);
        for ([_]Kind{ .toplevel, .popup }) |kind| {
            for (s.windows.items) |x| {
                if (x.kind == kind and x.mapped) s.drawTree(out, s.width, s.height, x.surface, 0, 0);
            }
        }
        return out;
    }

    /// One window alone, cut to its window rectangle, whatever covers it.
    pub fn renderWindow(s: *Server, gpa: Allocator, x: *Xdg) !struct { pixels: []u32, w: i32, h: i32 } {
        s.layout();
        const g = x.geometry();
        if (g.w <= 0 or g.h <= 0) return error.Empty;
        const out = try gpa.alloc(u32, @as(usize, @intCast(g.w)) * @as(usize, @intCast(g.h)));
        @memset(out, background);
        const o = s.origin(x);
        s.drawTree(out, g.w, g.h, x.surface, -o.x, -o.y);
        return .{ .pixels = out, .w = g.w, .h = g.h };
    }

    fn drawTree(s: *Server, out: []u32, ow: i32, oh: i32, surf: *Surface, dx: i32, dy: i32) void {
        blit(out, ow, oh, surf, surf.x + dx, surf.y + dy);
        for (s.surfaces.items) |child| {
            if (child.role == .subsurface and child.parent == surf) s.drawTree(out, ow, oh, child, dx, dy);
        }
    }

    fn blit(out: []u32, ow: i32, oh: i32, surf: *const Surface, px: i32, py: i32) void {
        if (!surf.hasContent()) return;
        const x0 = @max(px, 0);
        const y0 = @max(py, 0);
        const x1 = @min(px + surf.w, ow);
        const y1 = @min(py + surf.h, oh);
        if (x1 <= x0 or y1 <= y0) return;
        var y = y0;
        while (y < y1) : (y += 1) {
            const src = surf.pixels[@as(usize, @intCast(y - py)) * @as(usize, @intCast(surf.w)) ..];
            const dst = out[@as(usize, @intCast(y)) * @as(usize, @intCast(ow)) ..];
            var x = x0;
            while (x < x1) : (x += 1) {
                const sp = src[@intCast(x - px)];
                const a = sp >> 24;
                const d = &dst[@intCast(x)];
                if (a == 255) {
                    d.* = sp;
                } else if (a != 0) {
                    // the app's colours are already multiplied by alpha
                    const inv = 255 - a;
                    const r: u32 = @min(255, ((sp >> 16) & 0xff) + ((d.* >> 16) & 0xff) * inv / 255);
                    const g: u32 = @min(255, ((sp >> 8) & 0xff) + ((d.* >> 8) & 0xff) * inv / 255);
                    const b: u32 = @min(255, (sp & 0xff) + (d.* & 0xff) * inv / 255);
                    d.* = 0xff000000 | (r << 16) | (g << 8) | b;
                }
            }
        }
    }

    pub fn clearChanged(s: *Server) void {
        s.changed = .{};
    }

    // -----------------------------------------------------------------
    // Windows, for the agent

    pub fn window(s: *Server, win: u32) ?*Xdg {
        for (s.windows.items) |x| {
            if (x.win == win) return x;
        }
        return null;
    }

    pub fn windowRect(s: *Server, x: *const Xdg) Rect {
        const g = x.geometry();
        const o = s.origin(x);
        return .{ .x = o.x, .y = o.y, .w = g.w, .h = g.h };
    }

    /// Brings a toplevel to the front and gives it the keyboard.
    pub fn raise(s: *Server, x: *Xdg) void {
        if (x.kind != .toplevel) return;
        if (x.mapped) s.focusKeyboard(x.surface);
        var top: ?*Xdg = null;
        for (s.windows.items) |w| {
            if (w.kind == .toplevel and w.mapped) top = w;
        }
        if (top == x) return;
        if (std.mem.findScalar(*Xdg, s.windows.items, x)) |i| {
            _ = s.windows.orderedRemove(i);
            s.windows.appendAssumeCapacity(x);
        }
        s.note("window {d} to the front", .{x.win});
        s.changes += 1;
        s.last_change_ms = sys.nowMs();
        s.changed = s.changed.join(s.windowRect(x));
    }

    /// Asks a toplevel to close, as a close button would.
    pub fn askClose(s: *Server, x: *Xdg) void {
        if (x.kind == .toplevel) s.send(x.surface.client, x.role_id, 1, .{});
        if (x.kind == .popup) s.send(x.surface.client, x.role_id, 1, .{});
        s.note("ask window {d} to close", .{x.win});
    }

    // -----------------------------------------------------------------
    // Input

    const Hit = struct { surface: *Surface, x: f64, y: f64 };

    fn hitTree(s: *Server, surf: *Surface, px: i32, py: i32) ?*Surface {
        var i = s.surfaces.items.len;
        while (i > 0) {
            i -= 1;
            const child = s.surfaces.items[i];
            if (child.role == .subsurface and child.parent == surf) {
                if (s.hitTree(child, px, py)) |h| return h;
            }
        }
        if (!surf.hasContent()) return null;
        const r: Rect = .{ .x = surf.x, .y = surf.y, .w = surf.w, .h = surf.h };
        if (!r.contains(px, py)) return null;
        // a surface can leave input to what lies under it
        if (surf.input) |ops| {
            if (!Region.holds(ops, px - surf.x, py - surf.y)) return null;
        }
        return surf;
    }

    /// The surface under a desktop point: popups before windows, the
    /// topmost first.
    fn pick(s: *Server, fx: f64, fy: f64) ?Hit {
        s.layout();
        const px: i32 = @intFromFloat(@floor(fx));
        const py: i32 = @intFromFloat(@floor(fy));
        for ([_]Kind{ .popup, .toplevel }) |kind| {
            var i = s.windows.items.len;
            while (i > 0) {
                i -= 1;
                const x = s.windows.items[i];
                if (x.kind != kind or !x.mapped) continue;
                if (s.hitTree(x.surface, px, py)) |surf| {
                    return .{ .surface = surf, .x = fx - @as(f64, @floatFromInt(surf.x)), .y = fy - @as(f64, @floatFromInt(surf.y)) };
                }
            }
        }
        return null;
    }

    fn eachObject(s: *Server, c: *Client, iface: Iface, opcode: u16, min_version: u32, args: anytype) void {
        var it = c.objects.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.iface == iface and e.value_ptr.version >= min_version) s.send(c, e.key_ptr.*, opcode, args);
        }
    }

    /// Looks again at what is under the pointer (windows came or went).
    fn repick(s: *Server) void {
        s.pointerTo(s.pointer_x, s.pointer_y, false);
    }

    /// Moves the pointer to a desktop point and tells the apps.
    pub fn pointerMove(s: *Server, x: f64, y: f64) void {
        s.note("pointer to {d},{d}", .{ @as(i32, @intFromFloat(x)), @as(i32, @intFromFloat(y)) });
        s.pointerTo(x, y, true);
    }

    fn pointerTo(s: *Server, x: f64, y: f64, moved: bool) void {
        s.pointer_x = x;
        s.pointer_y = y;
        const hit = s.pick(x, y);
        const target: ?*Surface = if (hit) |h| h.surface else null;
        if (target != s.pointer_focus) {
            if (s.pointer_focus) |old| {
                s.eachObject(old.client, .pointer, 1, 1, .{ s.nextSerial(), old.id });
                s.eachObject(old.client, .pointer, 5, 5, .{});
            }
            s.pointer_focus = target;
            if (hit) |h| {
                s.eachObject(h.surface.client, .pointer, 0, 1, .{ s.nextSerial(), h.surface.id, wire.Fixed.from(h.x), wire.Fixed.from(h.y) });
                s.eachObject(h.surface.client, .pointer, 5, 5, .{});
            }
        } else if (moved) {
            if (hit) |h| {
                s.eachObject(h.surface.client, .pointer, 2, 1, .{ s.timeMs(), wire.Fixed.from(h.x), wire.Fixed.from(h.y) });
                s.eachObject(h.surface.client, .pointer, 5, 5, .{});
            }
        }
    }

    pub const Button = enum(u32) { left = 0x110, right = 0x111, middle = 0x112 };

    /// Presses or lets go of a mouse button where the pointer is.
    pub fn pointerButton(s: *Server, button: Button, pressed: bool) void {
        s.note("button {s} {s}", .{ @tagName(button), if (pressed) "down" else "up" });
        const target = s.pointer_focus;
        if (pressed) {
            // A press outside the app that holds a menu open closes the menu.
            for (s.windows.items) |x| {
                if (x.kind == .popup and x.mapped and x.grab and (target == null or target.?.client != x.surface.client)) {
                    s.send(x.surface.client, x.role_id, 1, .{});
                }
            }
            if (target) |t| {
                var root = t;
                while (root.parent) |p| root = p;
                if (root.xdg) |x| {
                    if (x.kind == .toplevel) s.raise(x);
                }
            }
        }
        const t = target orelse return;
        s.eachObject(t.client, .pointer, 3, 1, .{ s.nextSerial(), s.timeMs(), @backingInt(button), @as(u32, @intFromBool(pressed)) });
        s.eachObject(t.client, .pointer, 5, 5, .{});
    }

    /// Turns the wheel: `steps` notches down (negative: up).
    pub fn pointerScroll(s: *Server, steps: i32) void {
        s.note("scroll {d}", .{steps});
        const t = s.pointer_focus orelse return;
        s.eachObject(t.client, .pointer, 6, 5, .{@as(u32, 0)}); // source: wheel
        s.eachObject(t.client, .pointer, 8, 5, .{ @as(u32, 0), steps }); // discrete steps
        s.eachObject(t.client, .pointer, 4, 1, .{ s.timeMs(), @as(u32, 0), wire.Fixed.from(@as(f64, @floatFromInt(steps)) * 15.0) });
        s.eachObject(t.client, .pointer, 5, 5, .{});
    }

    fn focusKeyboard(s: *Server, target: ?*Surface) void {
        if (s.keyboard_focus == target) return;
        if (s.keyboard_focus) |old| s.eachObject(old.client, .keyboard, 2, 1, .{ s.nextSerial(), old.id });
        s.keyboard_focus = target;
        if (target) |t| {
            s.eachObject(t.client, .keyboard, 1, 1, .{ s.nextSerial(), t.id, wire.Array{ .bytes = "" } });
            s.eachObject(t.client, .keyboard, 4, 1, .{ s.nextSerial(), s.mods, @as(u32, 0), @as(u32, 0), @as(u32, 0) });
        }
    }

    /// One key down or up, by its Linux input code. False if no window
    /// has the keyboard.
    pub fn key(s: *Server, code: u8, pressed: bool) bool {
        const t = s.keyboard_focus orelse return false;
        s.eachObject(t.client, .keyboard, 3, 1, .{ s.nextSerial(), s.timeMs(), @as(u32, code), @as(u32, @intFromBool(pressed)) });
        return true;
    }

    /// Tells the app which modifiers are held.
    pub fn setMods(s: *Server, mods: u32) void {
        if (s.mods == mods) return;
        s.mods = mods;
        if (s.keyboard_focus) |t| s.eachObject(t.client, .keyboard, 4, 1, .{ s.nextSerial(), mods, @as(u32, 0), @as(u32, 0), @as(u32, 0) });
    }

    /// A key with its modifiers, pressed and let go: "ctrl+a", "Return".
    pub fn pressCombo(s: *Server, combo: keymap.Combo) bool {
        if (s.keyboard_focus == null) return false;
        for (combo.mod_codes[0..combo.mod_count]) |m| _ = s.key(m, true);
        s.setMods(combo.mods);
        _ = s.key(combo.key.code, true);
        _ = s.key(combo.key.code, false);
        var i = combo.mod_count;
        while (i > 0) {
            i -= 1;
            _ = s.key(combo.mod_codes[i], false);
        }
        s.setMods(0);
        return true;
    }

    /// Types ASCII text key by key. Returns the first byte that has no
    /// key, or null when all was typed.
    pub fn typeText(s: *Server, text: []const u8) ?u8 {
        for (text) |ch| {
            const t = keymap.forChar(ch) orelse return ch;
            if (t.shift) {
                _ = s.key(42, true);
                s.setMods(keymap.Mods.shift);
            }
            _ = s.key(t.code, true);
            _ = s.key(t.code, false);
            if (t.shift) {
                _ = s.key(42, false);
                s.setMods(0);
            }
        }
        return null;
    }
};

const testing = std.testing;

test "a popup is placed by its anchor and gravity" {
    // below the bottom left corner of a 100x30 button at 10,20
    const p: Positioner = .{ .w = 120, .h = 80, .anchor_rect = .{ .x = 10, .y = 20, .w = 100, .h = 30 }, .anchor = 6, .gravity = 8 };
    try testing.expectEqual(Rect{ .x = 10, .y = 50, .w = 120, .h = 80 }, p.place());
    // centred above the button
    const q: Positioner = .{ .w = 40, .h = 10, .anchor_rect = .{ .x = 10, .y = 20, .w = 100, .h = 30 }, .anchor = 1, .gravity = 1, .off_y = -2 };
    try testing.expectEqual(Rect{ .x = 40, .y = 8, .w = 40, .h = 10 }, q.place());
}

test "a region is its rectangles in order, and an empty one holds nothing" {
    const ops = [_]Region.Op{
        .{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .add = true },
        .{ .rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 }, .add = false },
        .{ .rect = .{ .x = 15, .y = 15, .w = 5, .h = 5 }, .add = true },
    };
    try testing.expect(Region.holds(&ops, 5, 5));
    try testing.expect(!Region.holds(&ops, 12, 12));
    try testing.expect(Region.holds(&ops, 16, 16));
    try testing.expect(!Region.holds(&ops, 100, 5));
    try testing.expect(!Region.holds(&.{}, 0, 0));
}

test "rectangles join and know what they hold" {
    const a: Rect = .{ .x = 10, .y = 10, .w = 5, .h = 5 };
    const b: Rect = .{ .x = 0, .y = 12, .w = 4, .h = 10 };
    try testing.expectEqual(Rect{ .x = 0, .y = 10, .w = 15, .h = 12 }, a.join(b));
    try testing.expectEqual(a, a.join(.{}));
    try testing.expect(a.contains(14, 14));
    try testing.expect(!a.contains(15, 14));
}

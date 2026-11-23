//! The latest frame of every id on a bus (and of every page of a
//! multiplexed message), and how lively the bus is.
const std = @import("std");
const can = @import("can.zig");
const dbc = @import("dbc.zig");

pub const Slot = struct {
    data: [64]u8 = @splat(0),
    len: u8 = 0,
    at_ns: i128 = 0,
    count: u64 = 0,
};

/// A slot's key: the message key (dbc.Message.key), and for one page of a
/// multiplexed message also the page.
pub fn slotKey(key: u32, page: ?u64) u64 {
    return if (page) |p| @as(u64, key) | ((p + 1) << 32) else key;
}

pub const Bus = struct {
    slots: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    frames: u64 = 0,
    /// frames in the last whole second
    rate: u64 = 0,
    window_frames: u64 = 0,
    window_start_ns: i128 = 0,
    /// 0: no frame yet
    last_ns: i128 = 0,
    bus_off: u32 = 0,
    error_passive: u32 = 0,
    other_errors: u32 = 0,
    last_error_ns: i128 = 0,
    /// why the interface is not open, when it is not
    problem: []const u8 = "",

    pub fn deinit(b: *Bus, gpa: std.mem.Allocator) void {
        b.slots.deinit(gpa);
    }

    /// The message key a frame carries (dbc.Message.key).
    pub fn keyOf(f: *const can.Frame) u32 {
        return if (f.id & can.eff_flag != 0) (f.id & can.eff_mask) | dbc.extended_bit else f.id & can.sff_mask;
    }

    /// Records a frame. `page` is the multiplexer's value when the
    /// frame's message is multiplexed.
    pub fn put(b: *Bus, gpa: std.mem.Allocator, f: *const can.Frame, kind: can.Kind, page: ?u64, now_ns: i128) !void {
        if (kind == .err) {
            switch (can.trouble(f) orelse .other) {
                .bus_off => b.bus_off += 1,
                .error_passive => b.error_passive += 1,
                .other => b.other_errors += 1,
            }
            b.last_error_ns = now_ns;
            return;
        }
        if (f.id & can.rtr_flag != 0) return;
        const key = keyOf(f);
        try b.save(gpa, slotKey(key, null), f, now_ns);
        if (page != null) try b.save(gpa, slotKey(key, page), f, now_ns);
        b.frames += 1;
        b.window_frames += 1;
        b.last_ns = now_ns;
    }

    fn save(b: *Bus, gpa: std.mem.Allocator, k: u64, f: *const can.Frame, now_ns: i128) !void {
        const gop = try b.slots.getOrPut(gpa, k);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const n: u8 = @min(f.len, 64);
        @memcpy(gop.value_ptr.data[0..n], f.data[0..n]);
        gop.value_ptr.len = n;
        gop.value_ptr.at_ns = now_ns;
        gop.value_ptr.count += 1;
    }

    /// Call often: keeps `rate` current.
    pub fn tick(b: *Bus, now_ns: i128) void {
        if (b.window_start_ns == 0) b.window_start_ns = now_ns;
        const elapsed = now_ns - b.window_start_ns;
        if (elapsed >= std.time.ns_per_s) {
            b.rate = @intCast(@divTrunc(@as(i128, b.window_frames) * std.time.ns_per_s, elapsed));
            b.window_frames = 0;
            b.window_start_ns = now_ns;
        }
    }

    /// Frames a second: the last whole second's, or before the first whole
    /// second has passed, the count so far.
    pub fn rateAt(b: *const Bus, now_ns: i128) u64 {
        if (b.rate > 0 or b.window_start_ns == 0) return b.rate;
        const elapsed = now_ns - b.window_start_ns;
        if (elapsed <= std.time.ns_per_ms * 100) return b.rate;
        return @intCast(@divTrunc(@as(i128, b.window_frames) * std.time.ns_per_s, elapsed));
    }

    pub fn ids(b: *const Bus) usize {
        var n: usize = 0;
        var it = b.slots.keyIterator();
        while (it.next()) |k| {
            if (k.* >> 32 == 0) n += 1;
        }
        return n;
    }
};

test "latest frame per id, pages of multiplexed messages, error counts" {
    const gpa = std.testing.allocator;
    var b: Bus = .{};
    defer b.deinit(gpa);
    var f: can.Frame = .{ .id = 0x123, .len = 2 };
    f.data[0] = 1;
    try b.put(gpa, &f, .classic, 1, 10);
    f.data[0] = 2;
    try b.put(gpa, &f, .classic, 2, 20);
    try std.testing.expectEqual(2, b.slots.get(slotKey(0x123, null)).?.data[0]);
    try std.testing.expectEqual(1, b.slots.get(slotKey(0x123, 1)).?.data[0]);
    try std.testing.expectEqual(1, b.ids());
    var e: can.Frame = .{ .id = can.err_flag | 0x40, .len = 8 };
    try b.put(gpa, &e, .err, null, 30);
    try std.testing.expectEqual(1, b.bus_off);
    try std.testing.expectEqual(2, b.frames);
    const x: can.Frame = .{ .id = 0x18FF1234 | can.eff_flag, .len = 0 };
    try std.testing.expectEqual(0x18FF1234 | dbc.extended_bit, Bus.keyOf(&x));
}

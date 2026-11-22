//! `canmcp decode PROFILE LOG [SECONDS]`: the profile's readings through a
//! candump log (`(time) iface id#data`, or `id##Fdata` for CAN FD), one
//! line every SECONDS of log time. For checking a profile without a bus.
const std = @import("std");
const Allocator = std.mem.Allocator;
const can = @import("can.zig");
const profile = @import("profile.zig");
const server = @import("server.zig");

pub const Line = struct { ts: f64, iface: []const u8, frame: can.Frame, fd: bool };

/// One candump log line; null for anything else (and for remote requests).
pub fn parseLine(raw: []const u8) ?Line {
    const l = std.mem.trim(u8, raw, " \t\r");
    if (l.len < 4 or l[0] != '(') return null;
    const close = std.mem.indexOfScalar(u8, l, ')') orelse return null;
    const ts = std.fmt.parseFloat(f64, l[1..close]) catch return null;
    var rest = std.mem.trimStart(u8, l[close + 1 ..], " ");
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const iface = rest[0..sp];
    rest = std.mem.trimStart(u8, rest[sp + 1 ..], " ");
    const hash = std.mem.indexOfScalar(u8, rest, '#') orelse return null;
    const id_hex = rest[0..hash];
    if (id_hex.len == 0 or id_hex.len > 8) return null;
    const id = std.fmt.parseInt(u32, id_hex, 16) catch return null;
    var f: can.Frame = .{ .id = if (id_hex.len > 3) (id & can.eff_mask) | can.eff_flag else id, .len = 0 };
    var data = rest[hash + 1 ..];
    var fd = false;
    if (data.len > 0 and data[0] == '#') {
        if (data.len < 2) return null;
        fd = true;
        data = data[2..]; // the flags nibble
    }
    if (data.len > 0 and (data[0] == 'R' or data[0] == 'r')) return null;
    if (data.len % 2 != 0 or data.len / 2 > 64) return null;
    for (0..data.len / 2) |i| f.data[i] = std.fmt.parseInt(u8, data[i * 2 .. i * 2 + 2], 16) catch return null;
    f.len = @intCast(data.len / 2);
    return .{ .ts = ts, .iface = iface, .frame = f, .fd = fd };
}

/// Runs the log through `s` (made for `prof`); one snapshot line every
/// `every_s` seconds of log time into `out`, then a summary.
pub fn run(a: Allocator, s: *server.Server, prof: *const profile.Profile, log: []const u8, every_s: f64, out: *std.ArrayList(u8)) !void {
    var frames: u64 = 0;
    var other: u64 = 0;
    var first: ?f64 = null;
    var next_print: f64 = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |raw| {
        const l = parseLine(raw) orelse continue;
        const bus = for (prof.buses, 0..) |b, i| {
            if (std.mem.eql(u8, b.log, l.iface)) break i;
        } else {
            other += 1;
            continue;
        };
        const t0 = first orelse blk: {
            first = l.ts;
            next_print = l.ts + every_s;
            break :blk l.ts;
        };
        const ns: i128 = @intFromFloat((l.ts - t0) * std.time.ns_per_s);
        s.now_override = ns;
        try s.onFrame(bus, &l.frame, if (l.fd) .fd else .classic, ns);
        frames += 1;
        if (l.ts >= next_print) {
            try out.appendSlice(a, try std.fmt.allocPrint(a, "t={d:.1} {s}\n", .{ l.ts - t0, try s.snapshot(a) }));
            next_print += every_s;
            if (next_print <= l.ts) next_print = l.ts + every_s;
        }
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a, "end: {s}\n{d} frames on the profile's buses, {d} on other interfaces\n", .{ try s.snapshot(a), frames, other }));
}

test "candump lines: classic, CAN FD, 29-bit, and not ones" {
    const c = parseLine("(1216.673121) can0 257#EFC7320F04701901").?;
    try std.testing.expectEqualStrings("can0", c.iface);
    try std.testing.expectEqual(0x257, c.frame.id);
    try std.testing.expectEqual(8, c.frame.len);
    try std.testing.expectEqual(0xEF, c.frame.data[0]);
    try std.testing.expect(!c.fd);
    const fd = parseLine("(1609.652959) can1 1AA##04B7FE740705000000028008000000000").?;
    try std.testing.expect(fd.fd);
    try std.testing.expectEqual(16, fd.frame.len);
    try std.testing.expectEqual(0x4B, fd.frame.data[0]);
    const ext = parseLine("(1.0) can0 18FF1234#01").?;
    try std.testing.expectEqual(0x18FF1234 | can.eff_flag, ext.frame.id);
    try std.testing.expect(parseLine("(1.0) can0 123#R") == null);
    try std.testing.expect(parseLine("not a log line") == null);
    try std.testing.expect(parseLine("(1.0) can0 123#ABC") == null);
}

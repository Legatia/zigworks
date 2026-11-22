//! The poller against uds-server-simulator, which does ISO-TP itself rather
//! than through the kernel. Needs it running on vcan0 as the made-up battery
//! ECU (../cansim: `/opt/cansim/bin/uds-ecu`); run with `zig build test-uds-sim`.
//! The simulator answers only frames padded to 8 bytes, as many real ECUs do.
const std = @import("std");
const t = std.testing;
const isotp = @import("isotp.zig");

const Bms = isotp.Poller(&.{
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0xf1, 0x8b } }, // 13-byte answer: 2 frames
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0x01, 0x01 } }, // 51-byte answer: 8 frames
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x19, 0x02, 0xff } }, // not configured there
});

test "padded: one-frame-plus and many-frame answers, and a refusal" {
    var p = try Bms.open("vcan0", .{ .pad = 0xaa });
    defer p.close();
    var reply: [4095]u8 = undefined;
    const a = (try p.ask(0, &reply, 1000)) orelse return error.NoAnswerIsTheSimulatorRunning;
    try t.expect(isotp.positive(&.{0x22}, a));
    try t.expectEqualStrings("2026.11.22", a[3..]);
    const b = (try p.ask(1, &reply, 1000)) orelse return error.NoAnswer;
    try t.expect(isotp.positive(&.{0x22}, b));
    try t.expectEqualStrings("made-up battery data: SOC 67.5%, SOH 98.2%, 22 C", b[3..]);
    const c = (try p.ask(2, &reply, 1000)) orelse return error.NoAnswer;
    try t.expectEqualSlices(u8, &.{ 0x7f, 0x19, 0x11 }, c); // service not supported
}

test "unpadded: no answer from this simulator" {
    var p = try Bms.open("vcan0", .{});
    defer p.close();
    var reply: [4095]u8 = undefined;
    try t.expect(try p.ask(0, &reply, 500) == null);
}

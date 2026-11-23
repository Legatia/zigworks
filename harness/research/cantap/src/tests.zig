//! Tests. The bus tests need a virtual CAN interface, made as root:
//!   modprobe vcan && ip link add dev vcan0 type vcan && ip link set up vcan0
//! and are skipped without one.
const std = @import("std");
const linux = std.os.linux;
const t = std.testing;
const can = @import("can.zig");
const isotp = @import("isotp.zig");
const notify = @import("notify.zig").notify;

const bus = "vcan0";

test {
    _ = can;
    _ = isotp;
}

fn needBus() !void {
    const fd = can.socket(linux.SOCK.RAW, 1) catch return error.SkipZigTest;
    defer _ = linux.close(fd);
    _ = can.interfaceIndex(fd, bus) catch return error.SkipZigTest;
}

fn frameOf(id: u32, bytes: []const u8) can.Frame {
    var f: can.Frame = .{ .id = id, .len = @intCast(bytes.len) };
    @memcpy(f.data[0..bytes.len], bytes);
    return f;
}

/// A sender, for the tests only: the tap has none.
fn send(frame: can.Frame, fd_frame: bool) !void {
    const fd = try can.socket(linux.SOCK.RAW, 1);
    defer _ = linux.close(fd);
    const on: i32 = 1;
    if (fd_frame) try can.setOption(fd, 101, 5, std.mem.asBytes(&on));
    try can.bind(fd, .{ .ifindex = try can.interfaceIndex(fd, bus) });
    const size: usize = if (fd_frame) @sizeOf(can.Frame) else can.classic_size;
    try can.ok(linux.write(fd, std.mem.asBytes(&frame), size));
}

test "the tap gets only the ids it asked for" {
    try needBus();
    const tap = try can.Tap.open(bus, .{ .filters = &.{.exact(0x261)} });
    defer tap.close();
    try send(frameOf(0x123, &.{0xaa}), false);
    try send(frameOf(0x261 | can.eff_flag, &.{0xbb}), false); // 29-bit, same low bits
    try send(frameOf(0x261, &.{ 0x01, 0x02 }), false);
    var f: can.Frame = undefined;
    try t.expectEqual(can.Kind.classic, (try tap.read(&f, 1000)).?);
    try t.expectEqual(0x261, f.ident());
    try t.expectEqualSlices(u8, &.{ 0x01, 0x02 }, f.payload());
    try t.expect(try tap.read(&f, 200) == null);
}

test "with fd_frames on, a 64-byte CAN FD frame comes through whole" {
    try needBus();
    const tap = try can.Tap.open(bus, .{ .filters = &.{.exact(0x3a0)}, .fd_frames = true });
    defer tap.close();
    var bytes: [64]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    try send(frameOf(0x3a0, &bytes), true);
    var f: can.Frame = undefined;
    try t.expectEqual(can.Kind.fd, (try tap.read(&f, 1000)).?);
    try t.expectEqualSlices(u8, &bytes, f.payload());
}

test "error frames say bus-off and error-passive" {
    var f: can.Frame = .{ .id = can.err_flag | 0x40, .len = 8 };
    try t.expectEqual(can.Trouble.bus_off, can.trouble(&f).?);
    f = .{ .id = can.err_flag | 0x04, .len = 8 };
    f.data[1] = 0x20;
    try t.expectEqual(can.Trouble.error_passive, can.trouble(&f).?);
    f = .{ .id = 0x123, .len = 0 };
    try t.expect(can.trouble(&f) == null);
}

test "a missing interface is an error" {
    try needBus();
    try t.expectError(error.NoSuchInterface, can.Tap.open("nosuchcan9", .{}));
}

// ---- ISO-TP ----

const Bms = isotp.Poller(&.{
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0x01, 0x01 } },
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x19, 0x02, 0xff } },
});

/// The other end, for the tests: an "ECU" on 0x7e4 that answers on 0x7ec
/// with each of `answers` in turn, after reading one request.
const Ecu = struct {
    fd: linux.fd_t,
    answers: []const []const u8,
    got: [64]u8 = undefined,
    got_len: usize = 0,

    fn open(answers: []const []const u8) !Ecu {
        const fd = try can.socket(linux.SOCK.DGRAM, 6);
        errdefer _ = linux.close(fd);
        try can.bind(fd, .{ .ifindex = try can.interfaceIndex(fd, bus), .tx_id = 0x7ec, .rx_id = 0x7e4 });
        return .{ .fd = fd, .answers = answers };
    }

    fn serve(e: *Ecu) void {
        if (!(can.readable(e.fd, 3000) catch false)) return;
        e.got_len = linux.read(e.fd, &e.got, e.got.len);
        for (e.answers) |a| _ = linux.write(e.fd, a.ptr, a.len);
    }
};

fn askWith(answers: []const []const u8, comptime i: usize, reply: []u8) !?[]u8 {
    var e = try Ecu.open(answers);
    defer _ = linux.close(e.fd);
    var p = try Bms.open(bus, .{ .pad = 0xaa });
    defer p.close();
    const th = try std.Thread.spawn(.{}, Ecu.serve, .{&e});
    defer th.join();
    return p.ask(i, reply, 2000);
}

test "a reply of many frames arrives as one read" {
    try needBus();
    var long: [63]u8 = undefined;
    long[0..3].* = .{ 0x62, 0x01, 0x01 };
    for (long[3..], 0..) |*b, i| b.* = @intCast(i);
    var reply: [4095]u8 = undefined;
    const r = (try askWith(&.{&long}, 0, &reply)).?;
    try t.expectEqualSlices(u8, &long, r);
    try t.expect(isotp.positive(&.{ 0x22, 0x01, 0x01 }, r));
}

test "a 'response pending' is waited out" {
    try needBus();
    var reply: [64]u8 = undefined;
    const r = (try askWith(&.{ &.{ 0x7f, 0x19, 0x78 }, &.{ 0x59, 0x02, 0xff } }, 1, &reply)).?;
    try t.expectEqualSlices(u8, &.{ 0x59, 0x02, 0xff }, r);
}

test "a negative answer is returned, and is not positive" {
    try needBus();
    var reply: [64]u8 = undefined;
    const r = (try askWith(&.{&.{ 0x7f, 0x22, 0x31 }}, 0, &reply)).?;
    try t.expect(!isotp.positive(&.{ 0x22, 0x01, 0x01 }, r));
}

/// The usage example in agent-beside-the-car.md, compiled but not run
/// (there is no can0 here).
fn researchExample() !void {
    const Example = isotp.Poller(&.{
        .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0x01, 0x01 } }, // ReadDataByIdentifier
        .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x19, 0x02, 0xff } }, // ReadDTCInformation
    });
    var bms = try Example.open("can0", .{ .pad = 0xaa });
    defer bms.close();
    var reply: [4095]u8 = undefined;
    const answer = try bms.ask(0, &reply, 1000); // null: no answer within 1 s
    _ = answer;
}

test "the research's example compiles" {
    _ = &researchExample;
}

test "no ECU: no answer, not a hang" {
    try needBus();
    var p = try Bms.open(bus, .{});
    defer p.close();
    var reply: [64]u8 = undefined;
    try t.expect(try p.ask(0, &reply, 300) == null);
}

// ---- systemd ----

test "notify sends one datagram to the socket systemd names" {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "@cantap-test-{d}", .{linux.getpid()});
    const fd: linux.fd_t = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM, 0));
    defer _ = linux.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[1..name.len], name[1..]);
    try can.ok(linux.bind(fd, @ptrCast(&addr), @intCast(@offsetOf(linux.sockaddr.un, "path") + name.len)));
    try notify(name, "WATCHDOG=1");
    var buf: [64]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    try t.expectEqualStrings("WATCHDOG=1", buf[0..n]);
    try notify(null, "READY=1"); // not started by systemd: nothing is sent
    try t.expectError(error.BadNotifySocket, notify("relative", "READY=1"));
}

//! Reading a CAN bus through SocketCAN, without libc (from
//! harness/research/cantap). Nothing in this file sends a frame.
const std = @import("std");
const linux = std.os.linux;

pub const eff_flag: u32 = 0x8000_0000; // a 29-bit id
pub const rtr_flag: u32 = 0x4000_0000; // a remote request
pub const err_flag: u32 = 0x2000_0000; // an error frame, made by the driver
pub const sff_mask: u32 = 0x0000_07ff;
pub const eff_mask: u32 = 0x1fff_ffff;
const err_mask: u32 = 0x1fff_ffff; // every error class

const can_raw = 1; // CAN_RAW
const sol_can_raw = 101; // SOL_CAN_BASE + CAN_RAW
const raw_filter = 1; // CAN_RAW_FILTER
const raw_err_filter = 2; // CAN_RAW_ERR_FILTER
const raw_fd_frames = 5; // CAN_RAW_FD_FRAMES

/// struct canfd_frame. A classic frame (struct can_frame, 16 bytes) has the
/// same layout up to its 8 data bytes.
pub const Frame = extern struct {
    id: u32,
    len: u8,
    flags: u8 = 0,
    res0: u8 = 0,
    res1: u8 = 0,
    data: [64]u8 align(8) = @splat(0),

    pub fn payload(f: *const Frame) []const u8 {
        return f.data[0..@min(f.len, f.data.len)];
    }
};
pub const classic_size = 16; // CAN_MTU
comptime {
    std.debug.assert(@sizeOf(Frame) == 72); // CANFD_MTU
    std.debug.assert(@offsetOf(Frame, "data") == 8);
}

pub const Kind = enum { classic, fd, err };

/// struct can_filter
pub const Filter = extern struct { id: u32, mask: u32 };

/// What an error frame says (<linux/can/error.h>).
pub const Trouble = enum { bus_off, error_passive, other };

pub fn trouble(f: *const Frame) ?Trouble {
    if (f.id & err_flag == 0) return null;
    if (f.id & 0x40 != 0) return .bus_off; // CAN_ERR_BUSOFF
    if (f.id & 0x04 != 0 and f.data[1] & (0x10 | 0x20) != 0) return .error_passive; // CAN_ERR_CRTL, RX/TX passive
    return .other;
}

/// A raw CAN socket that only reads.
pub const Tap = struct {
    fd: linux.fd_t,

    pub const Options = struct {
        filters: []const Filter = &.{},
        errors: bool = true,
        fd_frames: bool = false,
        /// reads return at once (readNow) instead of waiting
        nonblock: bool = false,
    };

    pub fn open(ifname: []const u8, opts: Options) !Tap {
        const fd = try socket(linux.SOCK.RAW | (if (opts.nonblock) @as(u32, linux.SOCK.NONBLOCK) else 0), can_raw);
        errdefer _ = linux.close(fd);
        if (opts.filters.len > 0) try setOption(fd, sol_can_raw, raw_filter, std.mem.sliceAsBytes(opts.filters));
        if (opts.errors) try setOption(fd, sol_can_raw, raw_err_filter, std.mem.asBytes(&err_mask));
        const on: i32 = 1;
        if (opts.fd_frames) try setOption(fd, sol_can_raw, raw_fd_frames, std.mem.asBytes(&on));
        try bind(fd, .{ .ifindex = try interfaceIndex(fd, ifname) });
        return .{ .fd = fd };
    }

    /// The next frame if one is waiting (a tap opened with `nonblock`).
    pub fn readNow(t: Tap, frame: *Frame) !?Kind {
        const n = linux.read(t.fd, std.mem.asBytes(frame), @sizeOf(Frame));
        if (linux.errno(n) == .AGAIN) return null;
        try ok(n);
        if (frame.id & err_flag != 0) return .err;
        return switch (n) {
            classic_size => .classic,
            @sizeOf(Frame) => .fd,
            else => error.ShortFrame,
        };
    }

    pub fn close(t: Tap) void {
        _ = linux.close(t.fd);
    }
};

/// struct sockaddr_can (24 bytes). The two ids are for ISO-TP sockets.
pub const Address = extern struct {
    family: linux.sa_family_t = linux.AF.CAN,
    ifindex: i32,
    rx_id: u32 = 0,
    tx_id: u32 = 0,
    rest: [8]u8 = @splat(0),
};
comptime {
    std.debug.assert(@sizeOf(Address) == 24);
    std.debug.assert(@offsetOf(Address, "rx_id") == 8);
}

pub fn socket(kind: u32, protocol: u32) !linux.fd_t {
    const rc = linux.socket(linux.AF.CAN, kind | linux.SOCK.CLOEXEC, protocol);
    try ok(rc);
    return @intCast(rc);
}

pub fn bind(fd: linux.fd_t, addr: Address) !void {
    try ok(linux.bind(fd, @ptrCast(&addr), @sizeOf(Address)));
}

pub fn interfaceIndex(fd: linux.fd_t, name: []const u8) !i32 {
    if (name.len == 0 or name.len >= linux.IFNAMESIZE) return error.NoSuchInterface;
    var req: linux.ifreq = undefined;
    @memset(std.mem.asBytes(&req), 0);
    @memcpy(req.ifrn.name[0..name.len], name);
    try ok(linux.ioctl(fd, linux.SIOCGIFINDEX, @intFromPtr(&req)));
    return req.ifru.ivalue;
}

pub fn setOption(fd: linux.fd_t, level: i32, name: u32, value: []const u8) !void {
    try ok(linux.setsockopt(fd, level, name, value.ptr, @intCast(value.len)));
}

/// Whether `fd` has something to read within `timeout_ms`.
pub fn readable(fd: linux.fd_t, timeout_ms: i32) !bool {
    var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};
    const n = linux.poll(&pfd, 1, timeout_ms);
    if (linux.errno(n) == .INTR) return false;
    try ok(n);
    return n > 0;
}

pub fn ok(rc: usize) !void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NODEV => error.NoSuchInterface,
        .NETDOWN => error.InterfaceDown,
        .AFNOSUPPORT, .PROTONOSUPPORT => error.NoSocketCan,
        .NOBUFS, .AGAIN => error.Busy,
        .COMM => error.NoAnswer,
        .ILSEQ, .BADMSG => error.BadFrames,
        else => error.Unexpected,
    };
}

test "error frames say bus-off and error-passive" {
    var f: Frame = .{ .id = err_flag | 0x40, .len = 8 };
    try std.testing.expectEqual(Trouble.bus_off, trouble(&f).?);
    f = .{ .id = err_flag | 0x04, .len = 8 };
    f.data[1] = 0x20;
    try std.testing.expectEqual(Trouble.error_passive, trouble(&f).?);
    f = .{ .id = 0x123, .len = 0 };
    try std.testing.expect(trouble(&f) == null);
}

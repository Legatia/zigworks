//! Reading a CAN bus through SocketCAN on Linux, without libc. Zig 0.17.1.
//!
//! Nothing in this file sends a frame, so a tap built from it cannot
//! transmit, whatever the rest of the program does. Constants and layouts
//! come from <linux/can.h> and <linux/can/raw.h>; check_abi.c holds them
//! against the kernel headers, and the comptime blocks hold the sizes.
const std = @import("std");
const linux = std.os.linux;

/// Flags in a frame's id.
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
/// same layout up to its 8 data bytes; `Tap.read` says which kind came in.
pub const Frame = extern struct {
    id: u32,
    len: u8,
    flags: u8 = 0, // CAN FD only: bit-rate switch, error state
    res0: u8 = 0,
    res1: u8 = 0, // len8_dlc in a classic frame
    data: [64]u8 align(8) = @splat(0),

    /// The 11- or 29-bit id, without the flags.
    pub fn ident(f: *const Frame) u32 {
        return if (f.id & eff_flag != 0) f.id & eff_mask else f.id & sff_mask;
    }

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

/// struct can_filter: a frame passes when `frame.id & mask == id & mask`.
pub const Filter = extern struct {
    id: u32,
    mask: u32,

    /// Exactly one 11-bit id: not the 29-bit id with the same low bits,
    /// and not a remote request.
    pub fn exact(id: u11) Filter {
        return .{ .id = id, .mask = eff_flag | rtr_flag | sff_mask };
    }
};
comptime {
    std.debug.assert(@sizeOf(Filter) == 8);
}

/// What an error frame says. The classes are bits in its id
/// (<linux/can/error.h>); the controller's state is in data[1].
pub const Trouble = enum { bus_off, error_passive, other };

pub fn trouble(f: *const Frame) ?Trouble {
    if (f.id & err_flag == 0) return null;
    if (f.id & 0x40 != 0) return .bus_off; // CAN_ERR_BUSOFF
    // CAN_ERR_CRTL with CAN_ERR_CRTL_RX_PASSIVE or CAN_ERR_CRTL_TX_PASSIVE
    if (f.id & 0x04 != 0 and f.data[1] & (0x10 | 0x20) != 0) return .error_passive;
    return .other;
}

/// A raw CAN socket that only reads.
pub const Tap = struct {
    fd: linux.fd_t,

    pub const Options = struct {
        /// Frames that match any of these; empty: every frame.
        filters: []const Filter = &.{},
        /// Error frames too (bus-off, error-passive); a tap should watch them.
        errors: bool = true,
        /// CAN FD frames too.
        fd_frames: bool = false,
    };

    pub fn open(ifname: []const u8, opts: Options) !Tap {
        const fd = try socket(linux.SOCK.RAW, can_raw);
        errdefer _ = linux.close(fd);
        if (opts.filters.len > 0) try setOption(fd, sol_can_raw, raw_filter, std.mem.sliceAsBytes(opts.filters));
        if (opts.errors) try setOption(fd, sol_can_raw, raw_err_filter, std.mem.asBytes(&err_mask));
        const on: i32 = 1;
        if (opts.fd_frames) try setOption(fd, sol_can_raw, raw_fd_frames, std.mem.asBytes(&on));
        try bind(fd, .{ .ifindex = try interfaceIndex(fd, ifname) });
        return .{ .fd = fd };
    }

    /// The next frame, waiting up to `timeout_ms` (-1: no limit).
    /// null: nothing came in time.
    pub fn read(t: Tap, frame: *Frame, timeout_ms: i32) !?Kind {
        if (!try readable(t.fd, timeout_ms)) return null;
        const n = linux.read(t.fd, std.mem.asBytes(frame), @sizeOf(Frame));
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

// ---- also used by isotp.zig ----

/// struct sockaddr_can (24 bytes). The two ids are for ISO-TP sockets.
pub const Address = extern struct {
    family: linux.sa_family_t = linux.AF.CAN,
    ifindex: i32,
    rx_id: u32 = 0,
    tx_id: u32 = 0,
    rest: [8]u8 = @splat(0), // the union's larger J1939 member
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

/// The index of a network interface such as "can0".
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
        .COMM => error.NoAnswer, // ISO-TP: the ECU sent no flow control
        .ILSEQ, .BADMSG => error.BadFrames, // ISO-TP: out of sequence, bad padding
        else => error.Unexpected,
    };
}

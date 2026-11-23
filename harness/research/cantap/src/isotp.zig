//! Read-only diagnostic requests over the kernel's ISO-TP (Stage 4).
//!
//! The requests are a table fixed when the program is compiled. An entry
//! that is not a read-only service does not compile, and `ask` takes the
//! entry's index, so there is no way to send any other bytes.
const std = @import("std");
const linux = std.os.linux;
const can = @import("can.zig");

const can_isotp = 6; // CAN_ISOTP
const sol_can_isotp = 106; // SOL_CAN_BASE + CAN_ISOTP
const isotp_opts = 1; // CAN_ISOTP_OPTS
const tx_padding: u32 = 0x4; // CAN_ISOTP_TX_PADDING

/// struct can_isotp_options
const Opts = extern struct {
    flags: u32,
    frame_txtime: u32 = 0, // 0: keep the kernel's
    ext_address: u8 = 0,
    txpad_content: u8,
    rxpad_content: u8 = 0xcc,
    rx_ext_address: u8 = 0,
};
comptime {
    std.debug.assert(@sizeOf(Opts) == 12);
}

pub const Request = struct {
    /// The id the ECU listens on, and the id it answers on.
    tx_id: u32,
    rx_id: u32,
    /// The whole request.
    bytes: []const u8,
};

pub const Options = struct {
    /// Fill short frames up to 8 bytes with this byte (many ECUs want it).
    pad: ?u8 = null,
};

pub fn Poller(comptime table: []const Request) type {
    comptime for (table) |r| readOnly(r);
    return struct {
        const Self = @This();
        fds: [table.len]linux.fd_t,

        pub fn open(ifname: []const u8, opts: Options) !Self {
            var self: Self = .{ .fds = @splat(-1) };
            errdefer self.close();
            inline for (table, &self.fds) |r, *fd| {
                fd.* = try can.socket(linux.SOCK.DGRAM, can_isotp);
                if (opts.pad) |pad| {
                    const o: Opts = .{ .flags = tx_padding, .txpad_content = pad };
                    try can.setOption(fd.*, sol_can_isotp, isotp_opts, std.mem.asBytes(&o));
                }
                try can.bind(fd.*, .{ .ifindex = try can.interfaceIndex(fd.*, ifname), .tx_id = r.tx_id, .rx_id = r.rx_id });
            }
            return self;
        }

        /// Sends entry `i` of the table and waits up to `timeout_ms` for the
        /// whole answer, however many frames it took. null: no answer.
        pub fn ask(self: *Self, comptime i: usize, reply: []u8, timeout_ms: i32) !?[]u8 {
            const fd = self.fds[i];
            const req = table[i].bytes;
            // a late answer to an earlier request is not this one's
            while (try can.readable(fd, 0)) _ = linux.read(fd, reply.ptr, reply.len);
            try can.ok(linux.write(fd, req.ptr, req.len));
            var waits: u32 = 0;
            while (waits < 10) : (waits += 1) {
                if (!try can.readable(fd, timeout_ms)) return null;
                const n = linux.read(fd, reply.ptr, reply.len);
                try can.ok(n);
                const r = reply[0..n];
                // 7f <service> 78: "received, the answer is coming"
                if (r.len == 3 and r[0] == 0x7f and r[2] == 0x78) continue;
                return r;
            }
            return null;
        }

        pub fn close(self: *Self) void {
            for (self.fds) |fd| {
                if (fd >= 0) _ = linux.close(fd);
            }
        }
    };
}

/// Whether `reply` is a positive answer to `request`: its service plus 0x40.
/// A negative answer starts with 0x7f and has the reason in its third byte.
pub fn positive(request: []const u8, reply: []const u8) bool {
    return request.len > 0 and reply.len > 0 and @as(u16, reply[0]) == @as(u16, request[0]) + 0x40;
}

const read_data_by_identifier = 0x22;
const read_dtc_information = 0x19;

/// Only the two services that read. Everything else (sessions, security
/// access, writing, IO control, routines, clearing codes, reset, flashing)
/// stops the build.
fn readOnly(comptime r: Request) void {
    if (r.bytes.len == 0) @compileError("empty request");
    switch (r.bytes[0]) {
        read_data_by_identifier => if (r.bytes.len < 3 or r.bytes.len % 2 != 1)
            @compileError("0x22 takes one or more two-byte identifiers"),
        read_dtc_information => if (r.bytes.len < 2)
            @compileError("0x19 needs a sub-function"),
        else => @compileError(std.fmt.comptimePrint("service 0x{x:0>2} is not read-only", .{r.bytes[0]})),
    }
}

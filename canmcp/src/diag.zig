//! The diagnostic reads compiled into this build: `zig build -Ddiag=...`.
//! With `none` (the default) there are none, nothing imports isotp.zig,
//! and the binary contains no code that transmits on a bus. Every table
//! entry must be a read-only service (isotp.zig refuses anything else at
//! compile time), and a request is picked by name from the table: no
//! argument reaches the bus.
const std = @import("std");
const build_options = @import("build_options");

pub const Entry = struct {
    name: []const u8,
    about: []const u8,
    tx_id: u32,
    rx_id: u32,
    bytes: []const u8,
};

/// The made-up battery ECU of uds-server-simulator, as set up by
/// harness/research/cansim (uds-ecu.json, `/opt/cansim/bin/uds-ecu`).
const sim = [_]Entry{
    .{ .name = "ecu_date", .about = "the ECU's software date (22 F1 8B)", .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0xf1, 0x8b } },
    .{ .name = "battery", .about = "the battery data record (22 01 01)", .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0x01, 0x01 } },
    .{ .name = "trouble_codes", .about = "stored trouble codes (19 02 FF)", .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x19, 0x02, 0xff } },
};

pub const enabled = !std.mem.eql(u8, build_options.diag, "none");

pub const table: []const Entry = if (std.mem.eql(u8, build_options.diag, "sim"))
    &sim
else if (enabled)
    @compileError("unknown -Ddiag=" ++ build_options.diag ++ " (none or sim)")
else
    &.{};

const isotp = if (enabled) @import("isotp.zig") else struct {};

const requests = if (enabled) blk: {
    var r: [table.len]isotp.Request = undefined;
    for (table, 0..) |e, i| r[i] = .{ .tx_id = e.tx_id, .rx_id = e.rx_id, .bytes = e.bytes };
    const out = r;
    break :blk out;
} else {};

pub const Poller = if (enabled) isotp.Poller(&requests) else void;

pub const Options = if (enabled) isotp.Options else void;

/// Sends the table's request `name`; the answer, or null if none came.
pub fn ask(p: *Poller, name: []const u8, reply: []u8, timeout_ms: i32) !?[]u8 {
    if (!enabled) return error.NoDiagnostics;
    inline for (table, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return p.ask(i, reply, timeout_ms);
    }
    return error.UnknownRequest;
}

pub fn positive(request: []const u8, reply: []const u8) bool {
    return request.len > 0 and reply.len > 0 and @as(u16, reply[0]) == @as(u16, request[0]) + 0x40;
}

/// ISO 14229 negative response codes, the common ones.
pub fn nrcName(code: u8) []const u8 {
    return switch (code) {
        0x10 => "general reject",
        0x11 => "service not supported",
        0x12 => "sub-function not supported",
        0x13 => "incorrect message length or format",
        0x14 => "response too long",
        0x21 => "busy, repeat request",
        0x22 => "conditions not correct",
        0x24 => "request sequence error",
        0x31 => "request out of range",
        0x33 => "security access denied",
        0x35 => "invalid key",
        0x7e => "sub-function not supported in active session",
        0x7f => "service not supported in active session",
        else => "unknown reason",
    };
}

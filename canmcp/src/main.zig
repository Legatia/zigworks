//! canmcp: a car's CAN bus as named, read-only tools for an AI agent, over
//! MCP on stdio. Linux only (SocketCAN).
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const build_options = @import("build_options");
const profile = @import("profile.zig");
const server = @import("server.zig");
const decode = @import("decode.zig");
const diag = @import("diag.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("canmcp needs Linux: it reads CAN through SocketCAN");
}

const usage =
    \\usage: canmcp PROFILE.ini         serve MCP on stdin and stdout (what an agent starts)
    \\       canmcp check PROFILE.ini   read the profile and its DBC files; list buses and readings
    \\       canmcp decode PROFILE.ini LOG [SECONDS]
    \\                                  the readings through a candump log, every SECONDS (1)
    \\       canmcp version
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(usage, 2);
    const cmd = args[1];
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        out(try std.fmt.allocPrint(a, "canmcp {s} (diagnostic reads: {s})\n", .{ build_options.version, build_options.diag }));
        return 0;
    }
    if (eql(cmd, "check") and args.len == 3) {
        const p = load(a, io, args[2]) orelse return 1;
        out(try checkText(a, &p));
        return 0;
    }
    if (eql(cmd, "decode") and (args.len == 4 or args.len == 5)) {
        const p = load(a, io, args[2]) orelse return 1;
        const every = if (args.len == 5) std.fmt.parseFloat(f64, args[4]) catch return fail("SECONDS: a number\n", 2) else 1.0;
        if (every <= 0) return fail("SECONDS: more than 0\n", 2);
        const log = std.Io.Dir.cwd().readFileAlloc(io, args[3], a, .unlimited) catch |e| {
            err(try std.fmt.allocPrint(a, "canmcp: can't read {s}: {s}\n", .{ args[3], @errorName(e) }));
            return 1;
        };
        var s = try server.Server.init(init.gpa, io, &p);
        defer s.deinit();
        var text: std.ArrayList(u8) = .empty;
        try decode.run(a, &s, &p, log, every, &text);
        out(text.items);
        return 0;
    }
    if (args.len == 2 and cmd.len > 0 and cmd[0] != '-') {
        const p = load(a, io, cmd) orelse return 1;
        try server.run(init.gpa, io, &p);
        return 0;
    }
    return fail(usage, 2);
}

fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) ?profile.Profile {
    var d: profile.Diag = .{};
    return profile.load(a, io, path, &d) catch {
        const where = if (d.line > 0) std.fmt.allocPrint(a, " line {d}", .{d.line}) catch "" else "";
        err(std.fmt.allocPrint(a, "canmcp: {s}{s}: {s}\n", .{ path, where, d.what }) catch "canmcp: bad profile\n");
        return null;
    };
}

fn checkText(a: std.mem.Allocator, p: *const profile.Profile) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {d} bus{s}, {d} readings\n", .{ p.name, p.buses.len, if (p.buses.len == 1) "" else "es", p.readings.len }));
    for (p.buses) |b| {
        try o.appendSlice(a, try std.fmt.allocPrint(a, "bus {s}: {s} (in logs: {s}){s}, {s}: {d} messages, {d} signals\n", .{ b.name, b.interface, b.log, if (b.fd) ", CAN FD" else "", std.fs.path.basename(b.dbc_path), b.db.messages.len, b.db.signalCount() }));
    }
    for (p.readings) |r| {
        try o.appendSlice(a, try std.fmt.allocPrint(a, "reading {s}: {s} {s}.{s}{s}{s}{s}\n", .{ r.name, p.buses[r.bus].name, r.msg.name, r.sig.name, if (r.unit.len > 0) " in " else "", r.unit, if (r.sig.values.len > 0) " (named values)" else "" }));
    }
    if (diag.enabled) {
        try o.appendSlice(a, try std.fmt.allocPrint(a, "diagnostic reads ({s}): {d}, on {s}", .{ build_options.diag, diag.table.len, if (p.diag_interface.len > 0) p.diag_interface else p.buses[0].interface }));
        if (p.diag_pad) |pad| try o.appendSlice(a, try std.fmt.allocPrint(a, ", padded with 0x{X:0>2}", .{pad}));
        try o.append(a, '\n');
    } else try o.appendSlice(a, "diagnostic reads: none in this build (it cannot transmit)\n");
    return o.items;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn out(s: []const u8) void {
    server.writeAll(1, s) catch {};
}

fn err(s: []const u8) void {
    server.writeAll(2, s) catch {};
}

fn fail(msg: []const u8, code: u8) u8 {
    err(msg);
    return code;
}

test {
    _ = @import("can.zig");
    _ = @import("dbc.zig");
    _ = @import("ini.zig");
    _ = @import("store.zig");
    _ = @import("profile.zig");
    _ = @import("server.zig");
    _ = @import("decode.zig");
    if (diag.enabled) _ = @import("isotp.zig");
}

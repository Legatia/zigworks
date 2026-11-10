const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const client = @import("client.zig");
const server = @import("server.zig");
const mcp = @import("mcp.zig");

const usage_text =
    \\usage:
    \\  headterm start <name> [--cols N] [--rows N] [--cwd DIR] [--log FILE] -- <cmd> [args...]
    \\  headterm screen <name> [--json] [--diff] [--styles] [--trim] [--scrollback N]
    \\  headterm send <name> [--literal] [--paste] [--esc-delay MS] [--] <text | <Key>>...
    \\  headterm wait <name> (--text STR | --idle MS | --exit) [--timeout MS] [--json] [--diff]
    \\                [--styles] [--trim] [--scrollback N]
    \\  headterm resize <name> <cols> <rows>
    \\  headterm kill <name>
    \\  headterm list [--json]
    \\  headterm mcp                 (MCP server on stdin/stdout)
    \\  headterm version
    \\
    \\keys: <Enter> <Tab> <Esc> <Backspace> <Space> <Up> <Down> <Left> <Right>
    \\      <Home> <End> <PageUp> <PageDown> <Insert> <Delete> <F1>..<F12> <lt>
    \\      modifiers: <C-x> (Ctrl) <M-x> (Meta/Alt) <S-x> (Shift), combinable
    \\
    \\exit codes: 0 ok, 1 wait not satisfied (timeout), 2 error
    \\
;

pub fn main() u8 {
    const gpa = std.heap.c_allocator;
    const args = std.process.argsAlloc(gpa) catch return fail("out of memory", .{});
    defer std.process.argsFree(gpa, args);
    return run(gpa, args[1..]) catch |err| fail("{s}", .{@errorName(err)});
}

fn run(gpa: Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try writeStderr(usage_text);
        return 2;
    }
    const cmd = args[0];
    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) {
        try writeStdout(usage_text);
        return 0;
    }
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try writeStdout("headterm " ++ server.version ++ "\n");
        return 0;
    }

    if (eql(cmd, "list")) return list(gpa, args[1..]);
    if (eql(cmd, "mcp")) {
        if (args.len > 1) return fail("mcp takes no arguments", .{});
        try mcp.serve(gpa);
        return 0;
    }

    const known = [_][]const u8{ "start", "screen", "send", "wait", "resize", "kill" };
    for (known) |k| {
        if (eql(cmd, k)) break;
    } else return fail("unknown command '{s}' (try 'headterm help')", .{cmd});

    if (args.len < 2) return fail("{s}: missing session name", .{cmd});
    const name = args[1];
    if (!client.validName(name)) return fail("invalid session name '{s}' (use letters, digits, '.', '_', '-')", .{name});
    if (eql(cmd, "start")) return start(gpa, name, args[2..]);

    // Everything else is forwarded to the session server as-is.
    var fwd: std.ArrayList([]const u8) = .empty;
    defer fwd.deinit(gpa);
    try fwd.append(gpa, cmd);
    try fwd.appendSlice(gpa, args[2..]);
    const resp = client.call(gpa, name, fwd.items) catch |err| {
        var buf: [256]u8 = undefined;
        return fail("{s}", .{client.describeError(&buf, err, name)});
    };
    defer gpa.free(resp.body);
    switch (resp.status) {
        .ok => {
            try writeStdout(resp.body);
            return 0;
        },
        .timeout => {
            try writeStdout(resp.body);
            return 1;
        },
        .@"error" => {
            try writeStderr("headterm: ");
            try writeStderr(resp.body);
            return 2;
        },
    }
}

fn start(gpa: Allocator, name: []const u8, args: []const []const u8) !u8 {
    var opts: client.StartOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, a, "--")) break;
        if (i + 1 >= args.len) return fail("start: {s} needs a value", .{a});
        const v = args[i + 1];
        i += 1;
        if (eql(a, "--cols")) {
            opts.cols = std.fmt.parseInt(u16, v, 10) catch return fail("start: bad --cols '{s}'", .{v});
        } else if (eql(a, "--rows")) {
            opts.rows = std.fmt.parseInt(u16, v, 10) catch return fail("start: bad --rows '{s}'", .{v});
        } else if (eql(a, "--cwd")) {
            opts.cwd = v;
        } else if (eql(a, "--log")) {
            opts.log_path = v;
        } else {
            return fail("start: unknown option {s}", .{a});
        }
    }
    const argv = args[i..];
    if (argv.len == 0) return fail("start: missing command (headterm start <name> -- <cmd> [args...])", .{});

    var msg: [256]u8 = undefined;
    const pid = client.startSession(gpa, name, argv, opts, &msg) catch
        return fail("start: {s}", .{std.mem.sliceTo(&msg, 0)});
    var buf: [128]u8 = undefined;
    try writeStdout(try std.fmt.bufPrint(&buf, "started {s} pid={d}\n", .{ name, pid }));
    return 0;
}

fn list(gpa: Allocator, args: []const []const u8) !u8 {
    var json = false;
    for (args) |a| {
        if (eql(a, "--json")) json = true else return fail("list: unknown option {s}", .{a});
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = try client.listSessions(arena_state.allocator());

    var out_buf: [4096]u8 = undefined;
    // Streaming, not the default positional mode: with stdout redirected to
    // a file, positional writes would start at offset 0 and clobber it.
    var fw = std.fs.File.stdout().writerStreaming(&out_buf);
    const out = &fw.interface;
    if (json) {
        try out.writeByte('[');
        for (sessions.raw, 0..) |r, i| {
            if (i > 0) try out.writeByte(',');
            try out.writeAll(r);
        }
        try out.writeAll("]\n");
    } else {
        try client.writeSessionTable(out, sessions.infos);
    }
    try out.flush();
    return 0;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeStdout(bytes: []const u8) !void {
    try std.fs.File.stdout().writeAll(bytes);
}

fn writeStderr(bytes: []const u8) !void {
    try std.fs.File.stderr().writeAll(bytes);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "headterm: " ++ fmt ++ "\n", args) catch "headterm: error\n";
    std.fs.File.stderr().writeAll(msg) catch {};
    return 2;
}

test {
    _ = @import("vt.zig");
    _ = @import("keys.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
    _ = @import("pty.zig");
    _ = @import("mcp.zig");
}

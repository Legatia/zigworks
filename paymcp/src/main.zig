//! paymcp: a business's billing account read for what customers should be
//! paying and are not, as two tools for an AI agent over MCP on stdio, or
//! as a report on the command line. It only reads.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const stripe = @import("stripe.zig");
const server = @import("server.zig");
const report = @import("report.zig");
const job = @import("job.zig");

const usage =
    \\usage: paymcp PAY.ini                 serve MCP on stdin and stdout (what an agent starts)
    \\       paymcp check PAY.ini           read the pay file and the account, and say what was read
    \\       paymcp audit PAY.ini [--json]  the billing audit, as text or as data
    \\       paymcp version
    \\
    \\The key comes from the environment, never from the file: STRIPE_KEY, a
    \\restricted key that can only read (rk_test_... for a sandbox). A live
    \\account's secret key (sk_live_...) is refused; a sandbox's (sk_test_...)
    \\is taken, with a note.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(io, usage, 2);
    const cmd = args[1];
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try out(io, "paymcp " ++ build_options.version ++ "\n");
        return 0;
    }
    const check = eql(cmd, "check") and args.len == 3;
    const as_json = eql(cmd, "audit") and args.len == 4 and eql(args[3], "--json");
    const audit_cmd = (eql(cmd, "audit") and args.len == 3) or as_json;
    const serve = args.len == 2 and cmd.len > 0 and cmd[0] != '-' and !eql(cmd, "check") and !eql(cmd, "audit");
    if (!check and !audit_cmd and !serve) return fail(io, usage, 2);
    const path = if (serve) cmd else args[2];
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    const key = init.environ_map.get("STRIPE_KEY") orelse "";
    if (config.keyProblem(&cfg, key)) |why| return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
    // (on stderr: stdout is the report, or MCP)
    if (config.keyNote(key)) |note| Io.File.stderr().writeStreamingAll(io, note) catch {};
    var client = stripe.Client.init(init.gpa, io, &cfg, key) catch return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}: url isn't an address paymcp can reach\n", .{path}), 1);
    defer client.deinit();
    if (serve) {
        try server.run(init.gpa, io, &cfg, &client);
        return 0;
    }
    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    var why: []const u8 = "";
    const r = job.read(a, io, &cfg, &client, now, &why) catch |e| {
        if (e != error.Failed) return e;
        return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
    };
    if (check) {
        try out(io, try std.fmt.allocPrint(a, "{s}{d} requests, every one a GET. The key works and nothing was changed.\n", .{ try report.readText(a, r, &cfg), r.requests }));
        return 0;
    }
    try out(io, if (as_json) try report.json(a, r, &cfg) else try report.text(a, r, &cfg, .{}));
    if (as_json) try out(io, "\n");
    return 0;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn out(io: Io, s: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, s);
}

fn fail(io: Io, msg: []const u8, code: u8) u8 {
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return code;
}

test {
    _ = @import("model.zig");
    _ = @import("who.zig");
    _ = @import("audit.zig");
    _ = @import("config.zig");
    _ = @import("stripe.zig");
    _ = @import("sim.zig");
    _ = @import("report.zig");
    _ = @import("job.zig");
    _ = @import("server.zig");
    _ = @import("jv.zig");
    _ = @import("ini.zig");
    _ = @import("http.zig");
}

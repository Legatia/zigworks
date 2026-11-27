//! paymcp: a business's billing account read for what customers should be
//! paying and are not, as tools for an AI agent over MCP on stdio, or as a
//! report on the command line. It only reads the account; what it writes
//! is its own record of readings and of a person's decisions.
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const config = @import("config.zig");
const stripe = @import("stripe.zig");
const server = @import("server.zig");
const report = @import("report.zig");
const record = @import("record.zig");
const job = @import("job.zig");

const usage =
    \\usage: paymcp PAY.ini                        serve MCP on stdin and stdout (what an agent starts)
    \\       paymcp check PAY.ini                  read the pay file and the account, and say what was read
    \\       paymcp audit PAY.ini [--json] [--all] the billing audit, as text or as data
    \\       paymcp decide PAY.ini KEY intended|asked|open [REASON]
    \\                                             a person's decision about one finding, into paymcp's record
    \\       paymcp record PAY.ini                 the record: what is open, dismissed, and no longer found
    \\       paymcp version
    \\
    \\The key comes from the environment, never from the file: STRIPE_KEY, a
    \\restricted key that can only read (rk_test_... for a sandbox). A live
    \\account's secret key (sk_live_...) is refused; a sandbox's (sk_test_...)
    \\is taken, with a note. decide and record need no key: they read and
    \\write only paymcp's own record.
    \\
;

const Cmd = enum { serve, check, audit, decide, record };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return fail(io, usage, 2);
    const word = args[1];
    if (eql(word, "version") or eql(word, "--version")) {
        try out(io, "paymcp " ++ build_options.version ++ "\n");
        return 0;
    }
    var as_json = false;
    var all = false;
    const cmd: Cmd = blk: {
        if (eql(word, "check")) break :blk if (args.len == 3) .check else return fail(io, usage, 2);
        if (eql(word, "record")) break :blk if (args.len == 3) .record else return fail(io, usage, 2);
        if (eql(word, "decide")) break :blk if (args.len >= 5) .decide else return fail(io, usage, 2);
        if (eql(word, "audit")) {
            if (args.len < 3) return fail(io, usage, 2);
            for (args[3..]) |flag| {
                if (eql(flag, "--json")) as_json = true else if (eql(flag, "--all")) all = true else return fail(io, usage, 2);
            }
            break :blk .audit;
        }
        if (args.len == 2 and word.len > 0 and word[0] != '-') break :blk .serve;
        return fail(io, usage, 2);
    };
    const path = if (cmd == .serve) word else args[2];
    var d: config.Diag = .{};
    const cfg = config.load(a, io, path, &d) catch {
        const where = if (d.line > 0) try std.fmt.allocPrint(a, " line {d}", .{d.line}) else "";
        return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}{s}: {s}\n", .{ path, where, d.what }), 1);
    };
    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));

    if (cmd == .decide or cmd == .record) {
        if (cfg.record_path.len == 0) return fail(io, try std.fmt.allocPrint(a, "paymcp: {s} says record = none: no record is kept, so there is nothing to read or to write a decision into\n", .{path}), 1);
        var kept = try record.open(a, io, cfg.record_path);
        if (kept.problem) |why| return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
        const book = &kept.book.?;
        if (cmd == .record) {
            try out(io, try record.text(a, book, cfg.record_path));
            return 0;
        }
        const decision = std.meta.stringToEnum(record.Decision, args[4]) orelse return fail(io, "paymcp: a decision is intended (dismissed, with the reason), asked (waiting for an answer) or open (back on the list)\n", 2);
        const got = try record.decide(a, book, args[3], decision, try std.mem.join(a, " ", args[5..]), now);
        switch (got) {
            .refused => |why| return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1),
            .line => |line| {
                if (try record.save(a, io, cfg.record_path, book, line)) |why| return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
                try out(io, try record.decidedText(a, book, args[3]));
                return 0;
            },
        }
    }

    const key = init.environ_map.get("STRIPE_KEY") orelse "";
    if (config.keyProblem(&cfg, key)) |why| return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
    // (on stderr: stdout is the report, or MCP)
    if (config.keyNote(key)) |note| Io.File.stderr().writeStreamingAll(io, note) catch {};
    var client = stripe.Client.init(init.gpa, io, &cfg, key) catch return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}: url isn't an address paymcp can reach\n", .{path}), 1);
    defer client.deinit();
    if (cmd == .serve) {
        try server.run(init.gpa, io, &cfg, &client);
        return 0;
    }
    var why: []const u8 = "";
    const r = job.read(a, io, &cfg, &client, now, &why) catch |e| {
        if (e != error.Failed) return e;
        return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
    };
    if (cmd == .check) {
        try out(io, try std.fmt.allocPrint(a, "{s}{d} requests, every one a GET. The key works and nothing was changed.\n", .{ try report.readText(a, r, &cfg), r.requests }));
        return 0;
    }
    var kept = try record.keep(a, io, cfg.record_path, job.forRecord(r));
    const book: ?*const record.Book = if (kept.book) |*b| b else null;
    try out(io, if (as_json) try report.json(a, r, &cfg, book) else try report.text(a, r, &cfg, .{ .book = book, .all = all, .record_problem = kept.problem }));
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
    _ = @import("record.zig");
    _ = @import("server.zig");
    _ = @import("jv.zig");
    _ = @import("ini.zig");
    _ = @import("http.zig");
}

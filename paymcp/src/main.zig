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
const dispute = @import("dispute.zig");
const change = @import("change.zig");
const payrun_cmd = @import("payrun_cmd.zig");
const bills_cmd = @import("bills_cmd.zig");
const cloud = @import("cloud.zig");
const ledger = @import("ledger.zig");

const usage =
    \\usage: paymcp PAY.ini                        serve MCP on stdin and stdout (what an agent starts)
    \\       paymcp check PAY.ini                  read the pay file and the account, and say what was read
    \\       paymcp audit PAY.ini [--json] [--all] the billing audit, as text or as data
    \\       paymcp decide PAY.ini KEY intended|asked|open [REASON]
    \\                                             a person's decision about one finding, into paymcp's record
    \\       paymcp record PAY.ini                 the record: what is open, dismissed, and no longer found
    \\       paymcp draft PAY.ini KEY              the draft of a message to the customer about one finding
    \\       paymcp evidence PAY.ini KEY           what the account already shows against one card dispute
    \\       paymcp change PAY.ini KEY [--yes]     what paymcp can do about one finding at the provider; with
    \\                                             --yes, do it (needs [changes] allow = yes and STRIPE_WRITE_KEY)
    \\       paymcp stage PAY.ini KEY [--yes]      keep the evidence for one dispute at the provider, not sent
    \\       paymcp payrun PAY.ini check BATCH.csv   a batch of payments to suppliers, before it is paid
    \\       paymcp payrun PAY.ini paid BATCH.csv    write down that the batch, as it was checked, was paid
    \\       paymcp payrun PAY.ini history FILE.csv  give paymcp past payments, and search them for payments made twice
    \\       paymcp payrun PAY.ini lookback          search the past payments again
    \\       paymcp payrun PAY.ini draft KEY         the draft of a message to the supplier about a payment made twice
    \\       paymcp payrun PAY.ini books             the same check from the books (Xero): the bills awaiting payment
    \\       paymcp bills PAY.ini                  the bill watch: what cloud services and AI models cost, and what moved
    \\       paymcp version
    \\
    \\The key comes from the environment, never from the file: STRIPE_KEY, a
    \\restricted key that can only read (rk_test_... for a sandbox). A live
    \\account's secret key (sk_live_...) is refused; a sandbox's (sk_test_...)
    \\is taken, with a note. decide, record and payrun need no key: they read
    \\and write only files on this computer. The bill watch has keys of its
    \\own: ANTHROPIC_ADMIN_KEY, OPENAI_ADMIN_KEY, and for AWS
    \\AWS_ACCESS_KEY_ID with AWS_SECRET_ACCESS_KEY. The books are read with
    \\XERO_CLIENT_ID and XERO_CLIENT_SECRET.
    \\
;

const Cmd = enum { serve, check, audit, decide, record, draft, evidence, change, stage, payrun, bills };

/// The id and secret of the business's own app at its accounting program.
fn ledgerKeys(env: *const std.process.Environ.Map) ledger.Keys {
    return .{ .id = env.get("XERO_CLIENT_ID") orelse "", .secret = env.get("XERO_CLIENT_SECRET") orelse "" };
}

/// The bill watch's keys, from the environment.
fn cloudKeys(env: *const std.process.Environ.Map) cloud.Keys {
    return .{
        .anthropic = env.get("ANTHROPIC_ADMIN_KEY") orelse "",
        .openai = env.get("OPENAI_ADMIN_KEY") orelse "",
        .aws_id = env.get("AWS_ACCESS_KEY_ID") orelse "",
        .aws_secret = env.get("AWS_SECRET_ACCESS_KEY") orelse "",
        .aws_token = env.get("AWS_SESSION_TOKEN") orelse "",
    };
}

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
    var yes = false;
    const cmd: Cmd = blk: {
        if (eql(word, "check")) break :blk if (args.len == 3) .check else return fail(io, usage, 2);
        if (eql(word, "record")) break :blk if (args.len == 3) .record else return fail(io, usage, 2);
        if (eql(word, "bills")) break :blk if (args.len == 3) .bills else return fail(io, usage, 2);
        if (eql(word, "decide")) break :blk if (args.len >= 5) .decide else return fail(io, usage, 2);
        if (eql(word, "draft")) break :blk if (args.len == 4) .draft else return fail(io, usage, 2);
        if (eql(word, "evidence")) break :blk if (args.len == 4) .evidence else return fail(io, usage, 2);
        if (eql(word, "payrun")) break :blk if (args.len >= 4) .payrun else return fail(io, usage, 2);
        if (eql(word, "change") or eql(word, "stage")) {
            if (args.len == 5 and eql(args[4], "--yes")) yes = true else if (args.len != 4) return fail(io, usage, 2);
            break :blk if (eql(word, "change")) .change else .stage;
        }
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

    if (cmd == .payrun and eql(args[3], "books")) {
        if (args.len != 4) return fail(io, usage, 2);
        const got = try payrun_cmd.books(a, io, &cfg, ledgerKeys(init.environ_map), now);
        if (!got.ok) return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{got.text}), 1);
        try out(io, got.text);
        return 0;
    }
    if (cmd == .payrun) {
        const verb = std.meta.stringToEnum(payrun_cmd.Verb, args[3]) orelse return fail(io, usage, 2);
        const rest = args[4..];
        var anyway = false;
        var file: []const u8 = "";
        for (rest) |x| {
            if (eql(x, "--anyway") and verb == .paid) anyway = true else if (file.len == 0 and x.len > 0 and x[0] != '-') file = x else return fail(io, usage, 2);
        }
        if ((verb == .lookback) != (file.len == 0)) return fail(io, usage, 2);
        const got = try payrun_cmd.run(a, io, &cfg, verb, file, anyway, now);
        if (!got.ok) return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}{s}", .{ got.text, if (std.mem.endsWith(u8, got.text, "\n")) "" else "\n" }), 1);
        try out(io, got.text);
        return 0;
    }
    if (cmd == .bills) {
        const got = try bills_cmd.run(init.gpa, a, io, &cfg, cloudKeys(init.environ_map), now, 1000);
        if (!got.ok) return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{got.text}), 1);
        try out(io, got.text);
        return 0;
    }
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
    if (cmd == .serve and key.len == 0 and (cfg.payrun_on or cfg.bills_on or cfg.ledger_on)) {
        // a pay file for the payment-run check or the bill watch only: no account is read
        var none = stripe.Client.init(init.gpa, io, &cfg, "") catch return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}: url isn't an address paymcp can reach\n", .{path}), 1);
        defer none.deinit();
        try server.runWith(init.gpa, io, &cfg, &none, false, cloudKeys(init.environ_map), ledgerKeys(init.environ_map));
        return 0;
    }
    if (config.keyProblem(&cfg, key)) |why| return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{why}), 1);
    // (on stderr: stdout is the report, or MCP)
    if (config.keyNote(key)) |note| Io.File.stderr().writeStreamingAll(io, note) catch {};
    var client = stripe.Client.init(init.gpa, io, &cfg, key) catch return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}: url isn't an address paymcp can reach\n", .{path}), 1);
    defer client.deinit();
    // the second key, only where the pay file allows changes; a second
    // key that can't be used is said, and nothing is changed with it
    if (cfg.changes) {
        const second = init.environ_map.get("STRIPE_WRITE_KEY") orelse "";
        if (second.len > 0) {
            if (config.writeKeyProblem(&cfg, second)) |why| {
                Io.File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(a, "paymcp: {s}. Nothing will be changed.\n", .{why})) catch {};
            } else client.write_key = second;
        }
    }
    if (cmd == .serve) {
        try server.runWith(init.gpa, io, &cfg, &client, true, cloudKeys(init.environ_map), ledgerKeys(init.environ_map));
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
    if (cmd == .change or cmd == .stage) {
        const wanted = std.mem.trim(u8, args[3], " \t[]");
        const f = for (r.findings) |x| {
            if (eql(x.key, wanted)) break x;
        } else return fail(io, try std.fmt.allocPrint(a, "paymcp: no finding has the key {s} now: paymcp audit lists the keys there are\n", .{wanted}), 1);
        const dp = dispute.find(r.data, wanted);
        if (cmd == .stage and dp == null) return fail(io, try std.fmt.allocPrint(a, "paymcp: {s} is not a card dispute to answer\n", .{wanted}), 1);
        if (cmd == .change and f.change == null) return fail(io, try std.fmt.allocPrint(a, "paymcp: there is nothing paymcp can do about {s}. What is proposed is for a person: {s}\n", .{ wanted, f.proposal }), 1);
        const would = if (cmd == .stage) "Keep what the account shows against this dispute at the provider, as evidence not yet sent (paymcp evidence shows it). Nothing goes to the bank." else f.does;
        if (!yes) {
            try out(io, try std.fmt.allocPrint(a, "{s}{s}\nNothing was changed. To do exactly this, run it again with --yes.\n", .{ try report.one(a, f, null, false), would }));
            return 0;
        }
        if (!cfg.changes) return fail(io, try std.fmt.allocPrint(a, "paymcp: nothing was changed: {s} doesn't say [changes] allow = yes\n", .{path}), 1);
        if (config.writeKeyProblem(&cfg, client.write_key)) |problem| return fail(io, try std.fmt.allocPrint(a, "paymcp: nothing was changed: {s}\n", .{problem}), 1);
        if (cmd == .change and f.per != .unknown and cfg.max_change > 0 and f.amount > cfg.max_change) return fail(io, try std.fmt.allocPrint(a, "paymcp: nothing was changed: this is above the most one change may be worth here ([changes] max_amount)\n", .{}), 1);
        const got = if (cmd == .stage) try change.stage(a, &client, r.data, dp.?, now) else try change.apply(a, &client, f, now);
        if (got.done and cfg.record_path.len > 0) {
            var kept = try record.open(a, io, cfg.record_path);
            if (kept.book) |*b| if (try record.changed(a, b, wanted, got.note, now)) |line| {
                _ = try record.save(a, io, cfg.record_path, b, line);
            };
        }
        if (!got.done) return fail(io, try std.fmt.allocPrint(a, "paymcp: {s}\n", .{got.text}), 1);
        try out(io, try std.fmt.allocPrint(a, "{s}\n", .{got.text}));
        return 0;
    }
    if (cmd == .evidence) {
        const wanted = std.mem.trim(u8, args[3], " \t[]");
        const dp = dispute.find(r.data, wanted) orelse return fail(io, try std.fmt.allocPrint(a, "paymcp: no card dispute to answer has the key {s} now: paymcp audit lists them (dispute:du_...)\n", .{wanted}), 1);
        try out(io, try dispute.text(a, r.data, dp, r.now));
        return 0;
    }
    if (cmd == .draft) {
        // (a reading for a draft is not one for the record: the audit is)
        const wanted = std.mem.trim(u8, args[3], " \t[]");
        for (r.findings) |f| if (eql(f.key, wanted)) {
            try out(io, try report.letterText(a, f, &cfg));
            return 0;
        };
        return fail(io, try std.fmt.allocPrint(a, "paymcp: no finding has the key {s} now: paymcp audit lists the keys there are\n", .{wanted}), 1);
    }
    var kept = try record.keep(a, io, cfg.record_path, job.forRecord(r));
    const book: ?*const record.Book = if (kept.book) |*b| b else null;
    try out(io, if (as_json) try report.json(a, r, &cfg, book) else try report.text(a, r, &cfg, .{ .book = book, .all = all, .record_problem = kept.problem, .can_change = cfg.changes and client.write_key.len > 0 }));
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
    _ = @import("dispute.zig");
    _ = @import("change.zig");
    _ = @import("payrun.zig");
    _ = @import("payrun_cmd.zig");
    _ = @import("ksef.zig");
    _ = @import("ledger.zig");
    _ = @import("whitelist.zig");
    _ = @import("bills.zig");
    _ = @import("cloud.zig");
    _ = @import("bills_cmd.zig");
    _ = @import("server.zig");
    _ = @import("jv.zig");
    _ = @import("ini.zig");
    _ = @import("http.zig");
}

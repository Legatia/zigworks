//! The bill watch on the command line and for the MCP server: one reading
//! of what the providers say was spent, the rules over it, and what was
//! found as a person reads it. What it writes: the findings into paymcp's
//! record, so that a person can decide about them. Nothing at a provider.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const bills = @import("bills.zig");
const cloud = @import("cloud.zig");
const model = @import("model.zig");
const record = @import("record.zig");
const report = @import("report.zig");

pub const Out = struct {
    text: []const u8,
    /// False: nothing was read, and `text` says why.
    ok: bool = true,
};

fn list(a: Allocator, names: []const []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| try o.print(a, "{s}{s}", .{ if (i == 0) "" else if (i + 1 == names.len) " and " else ", ", bills.label(n) });
    return o.items;
}

pub fn run(gpa: Allocator, a: Allocator, io: Io, cfg: *const config.Config, keys: cloud.Keys, now: i64, wait_ms: u32) !Out {
    if (!cfg.bills_on) return .{ .ok = false, .text = "The pay file has no [bills] section: the bill watch isn't set up here." };
    var why: []const u8 = "";
    const r = cloud.read(gpa, a, io, cfg, keys, now, wait_ms, &why) catch |e| {
        if (e != error.Failed) return e;
        return .{ .ok = false, .text = try std.fmt.allocPrint(a, "The bill watch read nothing: {s}. The keys come from the environment (README, The bill watch).", .{why}) };
    };
    const fs = try bills.check(a, r.costs, cfg.bills, r.first, now);
    var kept = try record.keep(a, io, cfg.record_path, .{ .findings = fs, .now = now, .payrun = true });
    const book: ?*const record.Book = if (kept.book) |*b| b else null;
    const today = @divFloor(now, bills.day_s) * bills.day_s;

    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "Bill watch, read {s}: {s}, the {d} days from {s}. Nothing was changed: paymcp only read what was spent ({d} request{s}).\n", .{ try model.day(a, now), try list(a, r.read), cfg.bills.days, try model.day(a, r.first), r.requests, if (r.requests == 1) "" else "s" });
    try o.appendSlice(a, "Today is not counted: a day's figures come in late.\n");
    const o_look = try bills.outlook(a, r.costs, cfg.bills, r.first, now);
    for (try bills.pairs(a, r.costs)) |p| {
        try o.print(a, "{s}: {s} in those days", .{ bills.label(p.provider), try bills.money(a, bills.spent(r.costs, p.provider, p.currency, r.first, today - bills.day_s), p.currency) });
        if (std.mem.eql(u8, p.currency, cfg.bills.currency)) {
            try o.print(a, ", {s} of it in {s}", .{ try bills.money(a, bills.monthSoFar(a, r.costs, p.provider, p.currency, r.first, now) catch 0, p.currency), o_look.month });
        } else try o.print(a, " (not in {s}: left out of the month's sum and the budget)", .{try std.ascii.allocUpperString(a, cfg.bills.currency)});
        try o.appendSlice(a, ".\n");
    }
    for (r.read) |p| {
        for (r.costs) |c| {
            if (std.mem.eql(u8, c.provider, p)) break;
        } else try o.print(a, "{s}: nothing was spent in those days.\n", .{bills.label(p)});
    }
    for (r.gaps) |g| try o.print(a, "{s}.\n", .{g});
    try o.print(a, "{s} so far: {s}.", .{ o_look.month, try bills.money(a, o_look.so_far, cfg.bills.currency) });
    if (o_look.a_day) |per| try o.print(a, " The last 7 days cost {s} a day; at that rate the month ends at {s}", .{ try bills.money(a, per, cfg.bills.currency), try bills.money(a, o_look.ends_at.?, cfg.bills.currency) });
    if (cfg.bills.budget > 0) {
        try o.print(a, "{s}budget: {s}{s}", .{ if (o_look.a_day != null) " (" else " The ", try model.money(a, cfg.bills.budget, cfg.bills.currency), if (o_look.a_day != null) ")." else "." });
    } else if (o_look.a_day != null) try o.appendSlice(a, ". No budget is set ([bills] budget).");
    try o.append(a, '\n');

    var hidden: usize = 0;
    var body: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (fs) |f| {
        if (book) |b| if (b.mark(f.key) == .intended) {
            hidden += 1;
            continue;
        };
        n += 1;
        try body.append(a, '\n');
        try report.block(a, &body, f, try std.fmt.allocPrint(a, "{d}. ", .{n}), book, false);
    }
    if (n == 0) {
        try o.appendSlice(a, "\nNothing to look at by these rules.\n");
    } else try o.print(a, "\n{d} thing{s} to look at. Each is a question, not a mistake found.\n", .{ n, if (n == 1) "" else "s" });
    try o.appendSlice(a, body.items);
    if (hidden > 0) try o.print(a, "\n{d} dismissed as intended {s} not listed.\n", .{ hidden, if (hidden == 1) "is" else "are" });
    if (kept.problem) |p| try o.print(a, "\n{s}: a decision about these can't be written down.\n", .{p});
    return .{ .text = o.items };
}

//! The payment-run check on the command line and for the MCP server:
//! reading the files the pay file's [payrun] names, and saying what was
//! found as a person reads it. What it writes: paymcp's own list of past
//! payments and of batches checked, and (through record.zig) the findings
//! a person may decide about. Nothing else, and nothing outside this
//! computer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const payrun = @import("payrun.zig");
const audit = @import("audit.zig");
const model = @import("model.zig");
const record = @import("record.zig");
const report = @import("report.zig");
const ksef = @import("ksef.zig");
const whitelist = @import("whitelist.zig");
const ledger = @import("ledger.zig");

pub const Verb = enum { check, paid, history, lookback, draft };

pub const Out = struct {
    text: []const u8,
    /// False: nothing was done, and `text` says why.
    ok: bool = true,
};

fn stop(a: Allocator, comptime fmt: []const u8, args: anytype) !Out {
    return .{ .ok = false, .text = try std.fmt.allocPrint(a, fmt, args) };
}

fn readFile(a: Allocator, io: Io, path: []const u8) !?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => e,
    };
}

const Loaded = struct { sups: []const payrun.Supplier = &.{}, hist: payrun.History = .{}, raw: []const u8 = "", problem: ?[]const u8 = null };

/// The suppliers file (when one is named) and paymcp's list of past payments.
fn load(a: Allocator, io: Io, cfg: *const config.Config) !Loaded {
    var l: Loaded = .{};
    var d: payrun.Diag = .{};
    if (cfg.payrun_suppliers.len > 0) {
        const text = (readFile(a, io, cfg.payrun_suppliers) catch null) orelse {
            l.problem = try std.fmt.allocPrint(a, "can't read the suppliers file {s}", .{cfg.payrun_suppliers});
            return l;
        };
        l.sups = payrun.suppliers(a, text, &d) catch |e| {
            if (e == error.OutOfMemory) return e;
            l.problem = try std.fmt.allocPrint(a, "{s} line {d}: {s}", .{ cfg.payrun_suppliers, d.line, d.what });
            return l;
        };
    }
    if (readFile(a, io, cfg.payrun_history) catch null) |text| {
        l.raw = text;
        l.hist = payrun.history(a, text, &d) catch |e| {
            if (e == error.OutOfMemory) return e;
            l.problem = try std.fmt.allocPrint(a, "paymcp's list of past payments {s} line {d} {s}: it was left as it is", .{ cfg.payrun_history, d.line, d.what });
            return l;
        };
    }
    return l;
}

fn append(a: Allocator, io: Io, path: []const u8, raw: []const u8, lines: []const u8) !?[]const u8 {
    if (lines.len == 0) return null;
    const sep: []const u8 = if (raw.len > 0 and raw[raw.len - 1] != '\n') "\n" else "";
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.mem.concat(a, u8, &.{ raw, sep, lines }) }) catch |e|
        return try std.fmt.allocPrint(a, "paymcp's list of past payments {s} couldn't be written ({s})", .{ path, @errorName(e) });
    return null;
}

/// "18400.00 EUR" (a currency each, joined by " and ").
fn sums(a: Allocator, list: []const payrun.Row) ![]const u8 {
    var cur: std.ArrayList([]const u8) = .empty;
    var tot: std.ArrayList(i64) = .empty;
    for (list) |r| {
        const i = for (cur.items, 0..) |c, n| {
            if (std.mem.eql(u8, c, r.currency)) break n;
        } else blk: {
            try cur.append(a, r.currency);
            try tot.append(a, 0);
            break :blk cur.items.len - 1;
        };
        tot.items[i] += r.amount;
    }
    var parts: std.ArrayList([]const u8) = .empty;
    for (cur.items, tot.items) |c, n| try parts.append(a, try model.money(a, n, c));
    return std.mem.join(a, " and ", parts.items);
}

fn findingSums(a: Allocator, fs: []const audit.Finding) ![]const u8 {
    // (a payment with two findings counts once: by its supplier and amount)
    var seen: std.ArrayList(payrun.Row) = .empty;
    for (fs) |f| {
        for (seen.items) |s| {
            if (std.mem.eql(u8, s.id, f.customer) and s.amount == f.amount and std.mem.eql(u8, s.currency, f.currency)) break;
        } else try seen.append(a, .{ .id = f.customer, .amount = f.amount, .currency = f.currency });
    }
    return sums(a, seen.items);
}

fn count(a: Allocator, n: usize, noun: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{d} {s}{s}", .{ n, noun, if (n == 1) "" else "s" });
}

/// Writes the findings into paymcp's record, so that a person can decide
/// about them, and gives the book back for the report's marks.
fn keep(a: Allocator, io: Io, cfg: *const config.Config, fs: []const audit.Finding, now: i64) !record.Kept {
    return record.keep(a, io, cfg.record_path, .{ .findings = fs, .now = now, .payrun = true });
}

fn blocks(a: Allocator, o: *std.ArrayList(u8), fs: []const audit.Finding, book: ?*const record.Book, hidden: *usize) !void {
    var n: usize = 0;
    for (fs) |f| {
        if (book) |b| if (b.mark(f.key) == .intended) {
            hidden.* += 1;
            continue;
        };
        n += 1;
        try o.append(a, '\n');
        try report.block(a, o, f, try std.fmt.allocPrint(a, "{d}. ", .{n}), book, false);
    }
}

const Invoices = struct { list: []const ksef.Invoice = &.{}, files: usize = 0, unread: usize = 0, first_problem: []const u8 = "", problem: ?[]const u8 = null };

/// Every KSeF invoice file (*.xml) in `folder`. A file that isn't one is
/// counted and the first is named: the rest are still read.
fn loadInvoices(a: Allocator, io: Io, folder: []const u8) !Invoices {
    var got: Invoices = .{};
    var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |e| {
        got.problem = try std.fmt.allocPrint(a, "can't open the invoices folder {s} ({s})", .{ folder, @errorName(e) });
        return got;
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".xml")) continue;
        if (names.items.len >= 20_000) break;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    // (in the names' order, so that two readings say the same)
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.f);
    var list: std.ArrayList(ksef.Invoice) = .empty;
    for (names.items) |name| {
        got.files += 1;
        var d: ksef.Diag = .{};
        const text = dir.readFileAlloc(io, name, a, .limited(8 << 20)) catch {
            d.what = "can't be read (or is larger than 8 MB)";
            got.unread += 1;
            if (got.first_problem.len == 0) got.first_problem = try std.fmt.allocPrint(a, "{s} {s}", .{ name, d.what });
            continue;
        };
        const inv = ksef.parse(a, text, name, &d) catch |e| {
            if (e == error.OutOfMemory) return e;
            got.unread += 1;
            if (got.first_problem.len == 0) got.first_problem = try std.fmt.allocPrint(a, "{s} {s}", .{ name, d.what });
            continue;
        };
        try list.append(a, inv);
    }
    got.list = list.items;
    return got;
}

/// A file a tool names, inside the pay file's folder: a plain path with
/// no way up or out; null when it isn't.
pub fn inFolder(a: Allocator, cfg: *const config.Config, name: []const u8) !?[]const u8 {
    if (name.len == 0 or name.len > 300 or std.fs.path.isAbsolute(name) or name[0] == '/' or name[0] == '\\') return null;
    if (std.mem.indexOfScalar(u8, name, ':') != null or std.mem.indexOfScalar(u8, name, 0) != null) return null;
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return null;
    return try std.fs.path.join(a, &.{ cfg.dir, name });
}

/// The payment-run check from the books: the bills awaiting payment as
/// the batch, the books' suppliers, and the payments on bills added to
/// paymcp's list. And what changed in a supplier's bank details since the
/// reading before.
pub fn books(a: Allocator, io: Io, cfg: *const config.Config, keys: ledger.Keys, now: i64) !Out {
    if (!cfg.ledger_on) return stop(a, "The pay file has no [ledger] section: the books aren't read here.", .{});
    var l = try load(a, io, cfg);
    if (l.problem) |why| return stop(a, "{s}", .{why});
    var why: []const u8 = "";
    const b = ledger.read(a, a, io, cfg.ledger, keys, now, &why) catch |e| {
        if (e != error.Failed) return e;
        return stop(a, "The books weren't read: {s}. Nothing was checked.", .{why});
    };
    var added: usize = 0;
    const paid_lines = try payrun.paidLines(a, l.hist, "the books", b.paid, now, &added);
    const ch = try ledger.changes(a, b, l.hist, cfg.ledger, now);
    if (try append(a, io, cfg.payrun_history, l.raw, try std.mem.concat(a, u8, &.{ paid_lines, ch.lines }))) |problem| return stop(a, "{s}", .{problem});
    l = try load(a, io, cfg);
    if (l.problem) |problem| return stop(a, "{s}", .{problem});
    var all: std.ArrayList(audit.Finding) = .empty;
    try all.appendSlice(a, try payrun.check(a, b.bills, b.suppliers, l.hist, cfg.payrun, "books", now));
    try all.appendSlice(a, ch.findings);
    std.mem.sort(audit.Finding, all.items, {}, payrun.larger);
    const fs = all.items;
    var kept = try keep(a, io, cfg, fs, now);
    const book: ?*const record.Book = if (kept.book) |*x| x else null;

    var with_details: usize = 0;
    for (b.suppliers) |s| {
        if (s.account.len > 0) with_details += 1;
    }
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "The books (Xero), read {s}. Nothing was paid and nothing was changed: paymcp read suppliers, bills and payments ({d} requests), and asked no bank.\n", .{ try model.day(a, now), b.requests });
    try o.print(a, "Read: {s}, {d} of them suppliers ({d} with bank details); {s} awaiting payment{s}{s}; {s} on bills since {s}, {d} new to paymcp's list.\n", .{
        try count(a, b.contacts, "contact"),
        b.suppliers.len,
        with_details,
        try count(a, b.bills.len, "bill"),
        if (b.bills.len > 0) ", " else "",
        if (b.bills.len > 0) try sums(a, b.bills) else "",
        try count(a, b.paid.len, "payment"),
        try model.day(a, now - @as(i64, cfg.ledger.history_days) * 86400),
        added,
    });
    if (ch.first_seen > 0) try o.print(a, "The bank details of {s} were written down for the first time: a change is found from the next reading on.\n", .{try count(a, ch.first_seen, "supplier")});
    var hidden: usize = 0;
    var body: std.ArrayList(u8) = .empty;
    try blocks(a, &body, fs, book, &hidden);
    const open_n = fs.len - hidden;
    if (open_n == 0) {
        try o.appendSlice(a, "\nNothing to look at by these rules.");
    } else try o.print(a, "\n{s} to look at before paying. Each is a question, not a mistake found.\n", .{try count(a, open_n, "thing")});
    try o.appendSlice(a, body.items);
    if (hidden > 0) try o.print(a, "\n{d} dismissed as intended {s} not listed.", .{ hidden, if (hidden == 1) "is" else "are" });
    try o.appendSlice(a, "\nThat is no promise the rest is right: the books don't say which account a past payment went to, paymcp can't tell who owns an account, and it can't stop a payment at the bank.\n");
    return .{ .text = o.items };
}

pub fn run(a: Allocator, io: Io, cfg: *const config.Config, verb: Verb, file: []const u8, anyway: bool, now: i64) !Out {
    var l = try load(a, io, cfg);
    if (l.problem) |why| return stop(a, "{s}", .{why});
    var d: payrun.Diag = .{};
    const day = try model.day(a, now);
    var o: std.ArrayList(u8) = .empty;

    if (verb == .draft) {
        // (`file` is a finding's key here: a payment made twice)
        const wanted = std.mem.trim(u8, file, " \t[]");
        for (try payrun.lookback(a, l.hist, l.sups, cfg.payrun)) |f| if (std.mem.eql(u8, f.key, wanted)) return .{ .text = try report.letterText(a, f, cfg) };
        return stop(a, "no payment made twice has the key {s} now: \"paymcp payrun PAY.ini lookback\" lists them", .{wanted});
    }
    if (verb == .lookback or verb == .history) {
        if (verb == .history) {
            const text = (readFile(a, io, file) catch null) orelse return stop(a, "can't read {s}", .{file});
            const past = payrun.rows(a, text, cfg.payrun, &d) catch |e| {
                if (e == error.OutOfMemory) return e;
                return stop(a, "{s} line {d}: {s}", .{ file, d.line, d.what });
            };
            var added: usize = 0;
            const lines = try payrun.paidLines(a, l.hist, std.fs.path.basename(file), past, now, &added);
            if (try append(a, io, cfg.payrun_history, l.raw, lines)) |why| return stop(a, "{s}", .{why});
            try o.print(a, "Read {s}: {s}, {s}. {d} added to paymcp's list of past payments ({s}); {d} were in it already.\n", .{ file, try count(a, past.len, "payment"), try sums(a, past), added, cfg.payrun_history, past.len - added });
            l = try load(a, io, cfg);
            if (l.problem) |why| return stop(a, "{s}", .{why});
        }
        const fs = try payrun.lookback(a, l.hist, l.sups, cfg.payrun);
        var kept = try keep(a, io, cfg, fs, now);
        const book: ?*const record.Book = if (kept.book) |*b| b else null;
        try o.print(a, "Past payments searched on {s}: {s} in paymcp's list. Nothing was changed, and no bank or supplier was asked.\n", .{ day, try count(a, l.hist.paid.len, "payment") });
        if (l.hist.paid.len == 0) {
            try o.appendSlice(a, "The list is empty: give it your payments of the last year or two with \"paymcp payrun PAY.ini history FILE.csv\".\n");
            return .{ .text = o.items };
        }
        if (fs.len == 0) {
            try o.appendSlice(a, "No payment looks made twice by these rules (the same supplier and amount, with the same bill number or one a character away).\n");
            return .{ .text = o.items };
        }
        try o.print(a, "\n{s} made twice, by the look of it: {s}. Each is a question: two bills of the same amount are common.\n", .{ try count(a, fs.len, "payment"), try findingSums(a, fs) });
        var hidden: usize = 0;
        try blocks(a, &o, fs, book, &hidden);
        if (hidden > 0) try o.print(a, "\n{d} dismissed as intended {s} not listed.\n", .{ hidden, if (hidden == 1) "is" else "are" });
        return .{ .text = o.items };
    }

    const text = (readFile(a, io, file) catch null) orelse return stop(a, "can't read {s}", .{file});
    const list = payrun.rows(a, text, cfg.payrun, &d) catch |e| {
        if (e == error.OutOfMemory) return e;
        return stop(a, "{s} line {d}: {s}. Nothing was checked: a file half understood would be a wrong check.", .{ file, d.line, d.what });
    };
    const batch = std.fs.path.basename(file);
    if (list.len == 0) return stop(a, "{s} has no payments in it.", .{file});

    if (verb == .paid) {
        const was = l.hist.checkOf(batch) orelse return stop(a, "{s} was never checked: run \"paymcp payrun PAY.ini check {s}\" first. Nothing was written down.", .{ batch, file });
        const dr = try payrun.drift(a, was, list);
        if (dr.changed.len > 0 or dr.missing > 0) {
            try o.print(a, "The file is not what was checked on {s}: {d} row{s} new or altered, {d} checked row{s} no longer there.\n", .{ try model.day(a, was.at), dr.changed.len, if (dr.changed.len == 1) " is" else "s are", dr.missing, if (dr.missing == 1) " is" else "s are" });
            for (dr.changed) |r| try o.print(a, "   - line {d}: {s}{s}, {s}{s}\n", .{ r.line, r.supplier, if (r.bill.len > 0) try std.fmt.allocPrint(a, ", bill {s}", .{r.bill}) else "", try model.money(a, r.amount, r.currency), if (r.account.len > 0) try std.fmt.allocPrint(a, ", to account {s}", .{r.account}) else "" });
            if (!anyway) {
                try o.appendSlice(a, "Nothing was written down. Check the file again as it is now; a row altered between the check and the bank is how a checked payment is stolen. (If you paid it like this and know why, --anyway writes it down.)\n");
                return .{ .ok = false, .text = o.items };
            }
        }
        var added: usize = 0;
        var stamped: std.ArrayList(payrun.Row) = .empty;
        for (list) |r| {
            var x = r;
            if (x.date == null) x.date = @divFloor(now, 86400) * 86400;
            try stamped.append(a, x);
        }
        const lines = try payrun.paidLines(a, l.hist, batch, stamped.items, now, &added);
        if (try append(a, io, cfg.payrun_history, l.raw, lines)) |why| return stop(a, "{s}", .{why});
        if (added == 0) {
            try o.print(a, "All {s} of {s} were written down as paid already. Nothing was added.\n", .{ try count(a, list.len, "payment"), batch });
        } else try o.print(a, "Written down: {s} of {s}, {s}, as paid. The next check knows them. (paymcp paid nothing: it only keeps the list.)\n", .{ try count(a, added, "payment"), batch, try sums(a, list) });
        return .{ .text = o.items };
    }

    // check
    var all: std.ArrayList(audit.Finding) = .empty;
    try all.appendSlice(a, try payrun.check(a, list, l.sups, l.hist, cfg.payrun, batch, now));
    // Poland: each payment beside its KSeF invoice, and each account asked about at the tax office's list
    var notes: std.ArrayList(u8) = .empty;
    if (cfg.payrun_invoices.len > 0) {
        const inv = try loadInvoices(a, io, cfg.payrun_invoices);
        if (inv.problem) |why| return stop(a, "{s}. Nothing was checked.", .{why});
        const cmp = try ksef.compare(a, list, inv.list, batch);
        try all.appendSlice(a, cmp.findings);
        try notes.print(a, "KSeF invoices: {s} in the folder {s}; {d} of the {s} {s} invoice among them.", .{ try count(a, inv.list.len, "invoice"), std.fs.path.basename(cfg.payrun_invoices), cmp.matched, try count(a, list.len, "payment"), if (cmp.matched == 1) "has its" else "have their" });
        if (inv.unread > 0) try notes.print(a, " {s} there {s} read as an invoice (the first: {s}).", .{ try count(a, inv.unread, "file"), if (inv.unread == 1) "wasn't" else "weren't", inv.first_problem });
        try notes.append(a, '\n');
    }
    var listed: []const u8 = "";
    if (cfg.payrun_whitelist) {
        const wl = try whitelist.check(a, a, io, cfg.whitelist_url, list, batch, now);
        try all.appendSlice(a, wl.findings);
        listed = wl.lines;
        try notes.print(a, "The tax office's list of VAT payers, asked {s}: {s}, {d} registered to the supplier's tax number and {d} not.", .{ day, try count(a, wl.asked, "account"), wl.assigned, wl.findings.len });
        if (wl.asked > 0) try notes.appendSlice(a, " Each answer's confirmation number is kept in paymcp's list.");
        if (wl.skipped > 0) try notes.print(a, " {s} with no Polish tax number or no 26-digit account {s} not asked about.", .{ try count(a, wl.skipped, "payment"), if (wl.skipped == 1) "was" else "were" });
        try notes.append(a, '\n');
        for (wl.gaps) |g| try notes.print(a, "{s}.\n", .{g});
    }
    std.mem.sort(audit.Finding, all.items, {}, payrun.larger);
    const fs = all.items;
    var kept = try keep(a, io, cfg, fs, now);
    const book: ?*const record.Book = if (kept.book) |*b| b else null;
    if (try append(a, io, cfg.payrun_history, l.raw, try std.mem.concat(a, u8, &.{ try payrun.checkedLine(a, batch, list, now), listed }))) |why| return stop(a, "{s}", .{why});
    try o.print(a, "Payment run {s}, checked {s}. Nothing was paid and nothing was changed: paymcp read these files{s}, and asked no bank.\n", .{ batch, day, if (cfg.payrun_whitelist) " and asked the tax office's list" else "" });
    try o.print(a, "Read: {s}, {s}", .{ try count(a, list.len, "payment"), try sums(a, list) });
    if (cfg.payrun_suppliers.len > 0) try o.print(a, "; {s} in your suppliers file", .{try count(a, l.sups.len, "supplier")});
    try o.print(a, "; {s} in paymcp's list", .{try count(a, l.hist.paid.len, "past payment")});
    var first: ?i64 = null;
    for (l.hist.paid) |pr| if (pr.date) |t_s| {
        if (first == null or t_s < first.?) first = t_s;
    };
    if (first) |t_s| try o.print(a, ", the first of {s}", .{try model.day(a, t_s)});
    try o.appendSlice(a, ".\n");
    if (l.hist.paid.len == 0) try o.appendSlice(a, "No past payments are known yet, so nothing here can be called new, a duplicate or out of line: give paymcp the last year or two (\"paymcp payrun PAY.ini history FILE.csv\") and mark each run as paid.\n");
    if (cfg.payrun_suppliers.len == 0) try o.appendSlice(a, "Your suppliers file isn't given ([payrun] suppliers): accounts are compared with past payments only, and no phone number can be shown.\n");
    try o.appendSlice(a, notes.items);
    var hidden: usize = 0;
    var body: std.ArrayList(u8) = .empty;
    try blocks(a, &body, fs, book, &hidden);
    const open_n = fs.len - hidden;
    if (open_n == 0) {
        try o.appendSlice(a, "\nNothing to look at by these rules.");
    } else try o.print(a, "\n{s} to look at before paying. Each is a question, not a mistake found.\n", .{try count(a, open_n, "thing")});
    try o.appendSlice(a, body.items);
    if (hidden > 0) try o.print(a, "\n{d} dismissed as intended {s} not listed.", .{ hidden, if (hidden == 1) "is" else "are" });
    try o.print(a, "\nThat is no promise the rest is right: paymcp can't read a bill on paper or in a PDF, can't tell who owns an account, and can't stop a payment at the bank.\nWhen you have paid it: paymcp payrun PAY.ini paid {s}\n", .{file});
    return .{ .text = o.items };
}

//! The payment-run check: a batch of payments to suppliers, read from the
//! file a person exports before paying, set against the business's list
//! of suppliers and paymcp's own list of what was paid before. It finds
//! what should be looked at before the money leaves: bank details that
//! changed, a supplier never paid before, a bill that looks paid already,
//! an amount out of line, an account two suppliers share. And once, over
//! past payments: those made twice, which can be asked back.
//!
//! Everything here is files on this computer: nothing is sent anywhere,
//! no bank is asked, and nothing is paid or stopped. A cell in a file is
//! data, whatever it says.
const std = @import("std");
const Allocator = std.mem.Allocator;
const audit = @import("audit.zig");
const model = @import("model.zig");
const who = @import("who.zig");

pub const Rules = struct {
    /// The same supplier and amount again within this many days is asked about.
    duplicate_days: u32 = 45,
    /// An amount this many times the largest paid to the supplier before.
    out_of_line: u32 = 3,
    /// The currency of a file that has no currency column.
    currency: []const u8 = "eur",
};

pub const Diag = who.Diag;

/// One payment: about to be made (a batch's row) or made (a past one).
pub const Row = struct {
    line: usize = 0,
    /// The supplier as the file names it.
    supplier: []const u8 = "",
    /// The supplier as matched: its tax number where the file gives one,
    /// else its name in lower case with spaces drawn together.
    id: []const u8 = "",
    bill: []const u8 = "",
    /// In the currency's smallest unit.
    amount: i64 = 0,
    currency: []const u8 = "",
    /// The payment's day (seconds, UTC); null: the file doesn't say.
    date: ?i64 = null,
    account: []const u8 = "",
    /// SHA-256 of what is paid to whom, in hex: the row's fingerprint.
    sha: []const u8 = "",
    /// Which batch it was paid in (past payments).
    batch: []const u8 = "",
};

pub const Supplier = struct {
    line: usize = 0,
    name: []const u8 = "",
    id: []const u8 = "",
    account: []const u8 = "",
    phone: []const u8 = "",
    email: []const u8 = "",
};

const Col = enum { supplier, tax_id, bill, amount, currency, date, account, phone, email };

fn colOf(name: []const u8) ?Col {
    const names = [_]struct { c: Col, words: []const []const u8 }{
        .{ .c = .supplier, .words = &.{ "supplier", "vendor", "name", "payee", "beneficiary", "contact", "supplier name", "vendor name" } },
        .{ .c = .tax_id, .words = &.{ "tax_id", "tax id", "tax number", "vat", "vat id", "vat number", "nip", "tin" } },
        .{ .c = .bill, .words = &.{ "bill", "invoice", "invoice number", "bill number", "number", "reference", "ref", "document" } },
        .{ .c = .amount, .words = &.{ "amount", "total", "gross", "sum", "value" } },
        .{ .c = .currency, .words = &.{ "currency", "ccy", "cur" } },
        .{ .c = .date, .words = &.{ "date", "payment date", "paid", "paid on", "due", "due date" } },
        .{ .c = .account, .words = &.{ "account", "iban", "bank account", "account number", "bank_account" } },
        .{ .c = .phone, .words = &.{ "phone", "telephone", "tel" } },
        .{ .c = .email, .words = &.{ "email", "e-mail", "mail" } },
    };
    var buf: [40]u8 = undefined;
    const trimmed = std.mem.trim(u8, name, " \t");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    const low = std.ascii.lowerString(buf[0..trimmed.len], trimmed);
    for (names) |n| for (n.words) |w| if (std.mem.eql(u8, low, w)) return n.c;
    return null;
}

/// A supplier's name as matched: lower case, spaces drawn together.
pub fn nameId(a: Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    for (std.mem.trim(u8, name, " \t")) |ch| {
        if (ch == ' ' or ch == '\t') {
            gap = true;
            continue;
        }
        if (gap and out.items.len > 0) try out.append(a, ' ');
        gap = false;
        try out.append(a, std.ascii.toLower(ch));
    }
    return out.items;
}

/// Letters and digits only, upper case: an account or a tax number as compared.
pub fn compact(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (v) |ch| if (std.ascii.isAlphanumeric(ch)) try out.append(a, std.ascii.toUpper(ch));
    return out.items;
}

/// A tax number as compared: letters and digits, upper case, without the
/// two letters of a country before it ("PL5260001246" and "5260001246"
/// are one supplier's).
pub fn taxId(a: Allocator, v: []const u8) ![]const u8 {
    const c = try compact(a, v);
    if (c.len > 4 and std.ascii.isAlphabetic(c[0]) and std.ascii.isAlphabetic(c[1]) and std.ascii.isDigit(c[2])) return c[2..];
    return c;
}

/// A supplier's id from paymcp's list, as compared now: a tax number
/// (upper case, no spaces) loses its country letters; a name stays.
fn idAgain(a: Allocator, id: []const u8) ![]const u8 {
    for (id) |ch| if (!std.ascii.isDigit(ch) and !std.ascii.isUpper(ch)) return id;
    return taxId(a, id);
}

/// An account as compared: letters and digits, upper case; and a Polish
/// IBAN ("PL" and 26 digits) as its 26 digits, since both are written
/// for one account.
pub fn accountId(a: Allocator, v: []const u8) ![]const u8 {
    const c = try compact(a, v);
    if (c.len == 28 and std.mem.startsWith(u8, c, "PL")) {
        for (c[2..]) |ch| {
            if (!std.ascii.isDigit(ch)) break;
        } else return c[2..];
    }
    return c;
}

/// A bill's number as compared: letters and digits, lower case, leading zeros off.
pub fn billId(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (v) |ch| if (std.ascii.isAlphanumeric(ch)) try out.append(a, std.ascii.toLower(ch));
    return std.mem.trimStart(u8, out.items, "0");
}

fn decimalsOf(currency: []const u8) u8 {
    // (as model.money writes them)
    for ([_][]const u8{ "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf" }) |c| if (std.ascii.eqlIgnoreCase(c, currency)) return 0;
    for ([_][]const u8{ "bhd", "jod", "kwd", "omr", "tnd" }) |c| if (std.ascii.eqlIgnoreCase(c, currency)) return 3;
    return 2;
}

/// An amount as people write it ("1 234,56", "1,234.56", "1234.5", "980")
/// in the currency's smallest unit; null when it can't be read for sure.
/// With "." and "," both, the last is the decimal mark. With one of them,
/// it is the decimal mark unless exactly three digits follow it.
pub fn amountOf(v_in: []const u8, currency: []const u8) ?i64 {
    var buf: [48]u8 = undefined;
    var n: usize = 0;
    for (std.mem.trim(u8, v_in, " \t")) |ch| {
        // spaces (and the narrow ones, as bytes above 0x7f) group thousands
        if (ch == ' ' or ch == '\'' or ch >= 0x80) continue;
        if (n == buf.len) return null;
        buf[n] = ch;
        n += 1;
    }
    var v: []const u8 = buf[0..n];
    var negative = false;
    if (v.len > 0 and v[0] == '-') {
        negative = true;
        v = v[1..];
    }
    if (v.len == 0) return null;
    const last_dot = std.mem.lastIndexOfScalar(u8, v, '.');
    const last_comma = std.mem.lastIndexOfScalar(u8, v, ',');
    var mark: ?usize = null;
    if (last_dot != null and last_comma != null) {
        mark = @max(last_dot.?, last_comma.?);
    } else if (last_dot orelse last_comma) |i| {
        const once = std.mem.indexOfScalar(u8, v, v[i]).? == i;
        if (once and v.len - i - 1 != 3) mark = i;
    }
    const whole_part = v[0 .. mark orelse v.len];
    const frac_part = if (mark) |m| v[m + 1 ..] else "";
    const dec = decimalsOf(currency);
    // the whole part: digits, or digits in groups of three behind one kind of mark
    var whole: i64 = 0;
    var group_mark: u8 = 0;
    var groups: usize = 0;
    var in_group: usize = 0;
    for (whole_part) |ch| {
        if (ch == '.' or ch == ',') {
            if (group_mark != 0 and ch != group_mark) return null;
            if (mark != null and ch == v[mark.?]) return null;
            if (in_group == 0 or (groups == 0 and in_group > 3) or (groups > 0 and in_group != 3)) return null;
            group_mark = ch;
            groups += 1;
            in_group = 0;
            continue;
        }
        if (ch < '0' or ch > '9') return null;
        in_group += 1;
        whole = std.math.mul(i64, whole, 10) catch return null;
        whole = std.math.add(i64, whole, ch - '0') catch return null;
    }
    if (in_group == 0 or (groups > 0 and in_group != 3)) return null;
    if (frac_part.len > dec or (mark != null and frac_part.len == 0)) return null;
    var frac: i64 = 0;
    for (frac_part) |ch| {
        if (ch < '0' or ch > '9') return null;
        frac = frac * 10 + (ch - '0');
    }
    var scale: i64 = 1;
    var d: u8 = 0;
    while (d < dec) : (d += 1) {
        scale *= 10;
        if (d >= frac_part.len) frac *= 10;
    }
    const total = std.math.add(i64, std.math.mul(i64, whole, scale) catch return null, frac) catch return null;
    return if (negative) -total else total;
}

/// A day: 2026-11-27 or 27.11.2026.
fn dayOf(v: []const u8) ?i64 {
    if (model.dayStart(v)) |t_s| return t_s;
    if (v.len == 10 and v[2] == '.' and v[5] == '.') {
        var iso: [10]u8 = undefined;
        @memcpy(iso[0..4], v[6..10]);
        iso[4] = '-';
        @memcpy(iso[5..7], v[3..5]);
        iso[7] = '-';
        @memcpy(iso[8..10], v[0..2]);
        return model.dayStart(&iso);
    }
    return null;
}

fn fail(diag: *Diag, line: usize, what: []const u8) error{BadFile} {
    diag.* = .{ .line = line, .what = what };
    return error.BadFile;
}

const Table = struct {
    lines: who.Lines,
    cols: [64]?Col,
    has: [9]bool,
};

fn open(a: Allocator, text_in: []const u8, diag: *Diag) !Table {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text = text[3..];
    // a file with ";" between its cells (as spreadsheets write them where "," is the decimal mark)
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const sep: u8 = if (std.mem.indexOfScalar(u8, text[0..first_end], ';') != null and std.mem.indexOfScalar(u8, text[0..first_end], ',') == null) ';' else ',';
    var tb: Table = .{ .lines = .{ .text = text, .sep = sep }, .cols = @splat(null), .has = @splat(false) };
    const head = (try tb.lines.next(a)) orelse return fail(diag, 1, "the file is empty: it needs a heading row");
    if (head.len > tb.cols.len) return fail(diag, 1, "more than 64 columns");
    for (head, 0..) |h, i| {
        const c = colOf(h) orelse continue;
        if (tb.has[@intFromEnum(c)]) return fail(diag, 1, try std.fmt.allocPrint(a, "two columns can be read as {s}: rename one, so that nothing is guessed", .{@tagName(c)}));
        tb.has[@intFromEnum(c)] = true;
        tb.cols[i] = c;
    }
    return tb;
}

fn sha(a: Allocator, r: Row) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ r.id, r.bill, r.currency, r.account }) |part| {
        h.update(part);
        h.update("\x1f");
    }
    var num: [24]u8 = undefined;
    h.update(std.fmt.bufPrint(&num, "{d}", .{r.amount}) catch unreachable);
    var out: [32]u8 = undefined;
    h.final(&out);
    return a.dupe(u8, &std.fmt.bytesToHex(out, .lower));
}

/// The payments in a file: a batch about to be paid, or past payments.
pub fn rows(a: Allocator, text: []const u8, rules: Rules, diag: *Diag) ![]Row {
    var tb = try open(a, text, diag);
    if (!tb.has[@intFromEnum(Col.supplier)] and !tb.has[@intFromEnum(Col.tax_id)]) return fail(diag, 1, "no column says who is paid: supplier (or vendor, name, payee), or tax_id");
    if (!tb.has[@intFromEnum(Col.amount)]) return fail(diag, 1, "no column called amount (or total, gross)");
    var out: std.ArrayList(Row) = .empty;
    while (try tb.lines.next(a)) |cells| {
        if (cells.len == 1 and std.mem.trim(u8, cells[0], " \t").len == 0) continue;
        const line = tb.lines.line;
        var r: Row = .{ .line = line, .currency = rules.currency };
        var amount_text: []const u8 = "";
        var tax: []const u8 = "";
        for (cells, 0..) |cell, i| {
            if (i >= tb.cols.len) break;
            const c = tb.cols[i] orelse continue;
            const v = std.mem.trim(u8, cell, " \t");
            if (v.len == 0) continue;
            switch (c) {
                .supplier => r.supplier = v,
                .tax_id => tax = try taxId(a, v),
                .bill => r.bill = v,
                .amount => amount_text = v,
                .currency => r.currency = try std.ascii.allocLowerString(a, v),
                .date => r.date = dayOf(v) orelse return fail(diag, line, try std.fmt.allocPrint(a, "the date is \"{s}\": a day is written 2026-11-27 or 27.11.2026", .{v})),
                .account => r.account = try accountId(a, v),
                .phone, .email => {},
            }
        }
        if (r.supplier.len == 0 and tax.len == 0) return fail(diag, line, "the row doesn't say who is paid");
        if (amount_text.len == 0) return fail(diag, line, "the row has no amount");
        r.amount = amountOf(amount_text, r.currency) orelse return fail(diag, line, try std.fmt.allocPrint(a, "the amount is \"{s}\": it can't be read for sure", .{amount_text}));
        if (r.amount <= 0) return fail(diag, line, try std.fmt.allocPrint(a, "the amount is \"{s}\": a payment is above zero", .{amount_text}));
        r.id = if (tax.len > 0) tax else try nameId(a, r.supplier);
        if (r.supplier.len == 0) r.supplier = tax;
        r.sha = try sha(a, r);
        try out.append(a, r);
    }
    return out.items;
}

/// The business's list of its suppliers.
pub fn suppliers(a: Allocator, text: []const u8, diag: *Diag) ![]Supplier {
    var tb = try open(a, text, diag);
    if (!tb.has[@intFromEnum(Col.supplier)]) return fail(diag, 1, "no column called supplier (or vendor, name)");
    var out: std.ArrayList(Supplier) = .empty;
    while (try tb.lines.next(a)) |cells| {
        if (cells.len == 1 and std.mem.trim(u8, cells[0], " \t").len == 0) continue;
        var s: Supplier = .{ .line = tb.lines.line };
        var tax: []const u8 = "";
        for (cells, 0..) |cell, i| {
            if (i >= tb.cols.len) break;
            const c = tb.cols[i] orelse continue;
            const v = std.mem.trim(u8, cell, " \t");
            if (v.len == 0) continue;
            switch (c) {
                .supplier => s.name = v,
                .tax_id => tax = try taxId(a, v),
                .account => s.account = try accountId(a, v),
                .phone => s.phone = v,
                .email => s.email = v,
                else => {},
            }
        }
        if (s.name.len == 0) return fail(diag, tb.lines.line, "the row has no supplier's name");
        s.id = if (tax.len > 0) tax else try nameId(a, s.name);
        try out.append(a, s);
    }
    return out.items;
}

// ---- paymcp's own list of what was paid, and of what was checked ----

pub const History = struct {
    paid: []const Row = &.{},
    /// The rows (by fingerprint) of each batch as it was last checked.
    checks: []const Check = &.{},
    /// Each supplier's bank details as the books had them, whenever a
    /// reading of the books found them new or changed (ledger.zig).
    seen: []const Seen = &.{},

    pub const Check = struct { batch: []const u8, at: i64, shas: []const []const u8 };
    pub const Seen = struct { id: []const u8, supplier: []const u8, account: []const u8, at: i64 };

    pub fn checkOf(h: History, batch: []const u8) ?Check {
        var found: ?Check = null;
        for (h.checks) |c| if (std.mem.eql(u8, c.batch, batch)) {
            found = c;
        };
        return found;
    }

    fn has(h: History, fingerprint: []const u8, date: ?i64) bool {
        for (h.paid) |p| if (std.mem.eql(u8, p.sha, fingerprint) and p.date == date) return true;
        return false;
    }
};

const jv = @import("jv.zig");

/// The list read back. A line that isn't paymcp's stops it, with its number.
pub fn history(a: Allocator, text: []const u8, diag: *Diag) !History {
    var paid: std.ArrayList(Row) = .empty;
    var checks: std.ArrayList(History.Check) = .empty;
    var seen: std.ArrayList(History.Seen) = .empty;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = jv.parse(a, line) orelse return fail(diag, n, "isn't a line paymcp wrote");
        const event = jv.str(jv.get(v, "event")) orelse return fail(diag, n, "isn't a line paymcp wrote");
        if (std.mem.eql(u8, event, "paid")) {
            try paid.append(a, .{
                .supplier = jv.str(jv.get(v, "supplier")) orelse "",
                .id = try idAgain(a, jv.str(jv.get(v, "id")) orelse return fail(diag, n, "isn't a line paymcp wrote")),
                .bill = jv.str(jv.get(v, "bill")) orelse "",
                .amount = jv.int(jv.get(v, "amount")) orelse return fail(diag, n, "isn't a line paymcp wrote"),
                .currency = jv.str(jv.get(v, "currency")) orelse "",
                .date = jv.int(jv.get(v, "date")),
                // (as compared now: a list from before Polish IBANs were read as their 26 digits)
                .account = try accountId(a, jv.str(jv.get(v, "account")) orelse ""),
                .sha = jv.str(jv.get(v, "sha")) orelse "",
                .batch = jv.str(jv.get(v, "batch")) orelse "",
            });
        } else if (std.mem.eql(u8, event, "checked")) {
            var shas: std.ArrayList([]const u8) = .empty;
            for (jv.arr(jv.get(v, "rows")) orelse &.{}) |x| try shas.append(a, jv.str(x) orelse "");
            try checks.append(a, .{ .batch = jv.str(jv.get(v, "batch")) orelse "", .at = jv.int(jv.get(v, "at")) orelse 0, .shas = shas.items });
        } else if (std.mem.eql(u8, event, "seen")) {
            try seen.append(a, .{
                .id = jv.str(jv.get(v, "id")) orelse return fail(diag, n, "isn't a line paymcp wrote"),
                .supplier = jv.str(jv.get(v, "supplier")) orelse "",
                .account = jv.str(jv.get(v, "account")) orelse "",
                .at = jv.int(jv.get(v, "at")) orelse 0,
            });
        } else if (std.mem.eql(u8, event, "whitelist")) {
            // (an answer of the tax office's list, kept for its confirmation number: nothing is read from it)
        } else return fail(diag, n, "isn't a line paymcp wrote");
    }
    return .{ .paid = paid.items, .checks = checks.items, .seen = seen.items };
}

/// The line that says a batch was checked as it is now.
pub fn checkedLine(a: Allocator, batch: []const u8, list: []const Row, now: i64) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "{{\"at\":{d},\"event\":\"checked\",\"batch\":{f},\"rows\":[", .{ now, std.json.fmt(batch, .{}) });
    for (list, 0..) |r, i| try o.print(a, "{s}\"{s}\"", .{ if (i > 0) "," else "", r.sha });
    try o.appendSlice(a, "]}\n");
    return o.items;
}

/// The lines that say these payments were made; those the list already
/// has (the same fingerprint on the same day) are left out. `count` gets
/// how many were added.
pub fn paidLines(a: Allocator, h: History, batch: []const u8, list: []const Row, now: i64, count: *usize) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    count.* = 0;
    for (list) |r| {
        if (h.has(r.sha, r.date)) continue;
        count.* += 1;
        try o.print(a, "{{\"at\":{d},\"event\":\"paid\",\"batch\":{f},\"supplier\":{f},\"id\":{f},\"bill\":{f},\"amount\":{d},\"currency\":{f},\"date\":{f},\"account\":{f},\"sha\":\"{s}\"}}\n", .{
            now,                             std.json.fmt(batch, .{}),      std.json.fmt(r.supplier, .{}), std.json.fmt(r.id, .{}),
            std.json.fmt(r.bill, .{}),       r.amount,                      std.json.fmt(r.currency, .{}), std.json.fmt(r.date, .{}),
            std.json.fmt(r.account, .{}),    r.sha,
        });
    }
    return o.items;
}

/// What differs between a batch now and the batch as it was checked: the
/// rows that are new or altered (by line), and how many checked rows are
/// no longer there.
pub const Drift = struct { changed: []const Row, missing: usize };

pub fn drift(a: Allocator, was: History.Check, list: []const Row) !Drift {
    var changed: std.ArrayList(Row) = .empty;
    var used = try a.alloc(bool, was.shas.len);
    @memset(used, false);
    for (list) |r| {
        const hit = for (was.shas, 0..) |s, i| {
            if (!used[i] and std.mem.eql(u8, s, r.sha)) break i;
        } else null;
        if (hit) |i| used[i] = true else try changed.append(a, r);
    }
    var missing: usize = 0;
    for (used) |u| {
        if (!u) missing += 1;
    }
    return .{ .changed = changed.items, .missing = missing };
}

// ---- the rules ----

const day_s: i64 = 86400;

const Ctx = struct {
    a: Allocator,
    rules: Rules,
    hist: History,
    sups: []const Supplier,
    batch: []const u8,
    now: i64,
    out: std.ArrayList(audit.Finding) = .empty,

    fn p(c: *Ctx, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.a, fmt, args);
    }

    fn money(c: *Ctx, r: Row) ![]const u8 {
        return model.money(c.a, r.amount, r.currency);
    }

    fn supplierOf(c: *Ctx, id: []const u8) ?Supplier {
        for (c.sups) |s| if (std.mem.eql(u8, s.id, id)) return s;
        return null;
    }

    fn when(c: *Ctx, r: Row) ![]const u8 {
        return if (r.date) |d| try model.day(c.a, d) else "a day the list doesn't say";
    }
};

/// One character added, dropped or changed between two bill numbers as
/// compared: a slip of the hand. Not one digit changed for another: bills
/// numbered in a row (10/2025, 11/2025) for the same monthly amount are
/// two bills.
fn oneAway(x: []const u8, y: []const u8) bool {
    if (x.len == y.len) {
        var diff: usize = 0;
        var digits = false;
        for (x, y) |cx, cy| {
            if (cx == cy) continue;
            diff += 1;
            digits = std.ascii.isDigit(cx) and std.ascii.isDigit(cy);
        }
        return diff == 1 and !digits;
    }
    const long = if (x.len > y.len) x else y;
    const short = if (x.len > y.len) y else x;
    if (long.len - short.len != 1 or short.len < 3) return false;
    var i: usize = 0;
    while (i < short.len and long[i] == short[i]) i += 1;
    return std.mem.eql(u8, long[i + 1 ..], short[i..]);
}

/// What to look at in a batch before it is paid.
pub fn check(a: Allocator, list: []const Row, sups: []const Supplier, hist: History, rules: Rules, batch: []const u8, now: i64) ![]audit.Finding {
    var c: Ctx = .{ .a = a, .rules = rules, .hist = hist, .sups = sups, .batch = batch, .now = now };
    for (list, 0..) |r, index| {
        const src = try c.p("{s}, line {d}", .{ batch, r.line });
        const row_text = try c.p("{s}{s}, {s}{s}", .{ r.supplier, if (r.bill.len > 0) try c.p(", bill {s}", .{r.bill}) else "", try c.money(r), if (r.account.len > 0) try c.p(", to account {s}", .{r.account}) else "" });
        // what this supplier was paid before, the last payment last
        var past: std.ArrayList(Row) = .empty;
        for (hist.paid) |pr| if (std.mem.eql(u8, pr.id, r.id)) try past.append(a, pr);
        const sup = c.supplierOf(r.id);

        // bank details: against the last payment, else against the suppliers file
        var last_account: []const u8 = "";
        var last: ?Row = null;
        for (past.items) |pr| if (pr.account.len > 0) {
            if (last == null or (pr.date orelse 0) >= (last.?.date orelse 0)) last = pr;
        };
        if (last) |l| last_account = l.account;
        const file_account: []const u8 = if (sup) |s| s.account else "";
        if (r.account.len > 0 and ((last_account.len > 0 and !std.mem.eql(u8, last_account, r.account)) or (last_account.len == 0 and file_account.len > 0 and !std.mem.eql(u8, file_account, r.account)))) {
            var ev: std.ArrayList(audit.Row) = .empty;
            try ev.append(a, .{ .source = src, .value = row_text });
            if (last) |l| {
                var to_old: usize = 0;
                for (past.items) |pr| {
                    if (std.mem.eql(u8, pr.account, l.account)) to_old += 1;
                }
                try ev.append(a, .{ .source = "paymcp's list of past payments", .value = try c.p("last paid on {s} to account {s}; {d} payment{s} went to that account", .{ try c.when(l), l.account, to_old, if (to_old == 1) "" else "s" }) });
            }
            if (sup) |s| try ev.append(a, .{ .source = try c.p("your suppliers file, line {d}", .{s.line}), .value = try c.p("account {s}{s}", .{ if (s.account.len > 0) s.account else "not given", if (s.phone.len > 0) try c.p(", phone {s}", .{s.phone}) else "" }) });
            try c.out.append(a, .{
                .kind = .account_changed,
                .key = try c.p("account_changed:{s}:{s}", .{ batch, r.id }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = if (last_account.len > 0)
                    try c.p("{s} is to be paid {s} to account {s}; the last payment to them went to {s}.", .{ r.supplier, try c.money(r), r.account, last_account })
                else
                    try c.p("{s} is to be paid {s} to account {s}; your suppliers file has {s}.", .{ r.supplier, try c.money(r), r.account, file_account }),
                .rows = ev.items,
                .proposal = try c.p("Before paying, call the supplier on a number you had before this change{s}, never one from the message that announced the new account, and ask whether the account is theirs. Then write down who you called and what they said (decide ... intended). A changed account is the commonest way a payment is stolen.", .{if (sup != null and sup.?.phone.len > 0) try c.p(" (your suppliers file has {s})", .{sup.?.phone}) else ""}),
            });
        } else if (past.items.len == 0 and hist.paid.len > 0) {
            try c.out.append(a, .{
                .kind = .new_supplier,
                .key = try c.p("new_supplier:{s}:{s}", .{ batch, r.id }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = try c.p("{s} is to be paid {s} and was never paid before.", .{ r.supplier, try c.money(r) }),
                .rows = try a.dupe(audit.Row, &.{
                    .{ .source = src, .value = row_text },
                    .{ .source = "paymcp's list of past payments", .value = try c.p("{d} payments, none to this supplier", .{hist.paid.len}) },
                    .{ .source = "your suppliers file", .value = if (sup) |s| try c.p("line {d}: account {s}", .{ s.line, if (s.account.len > 0) s.account else "not given" }) else "no supplier of this name or tax number" },
                }),
                .proposal = "Check who asked for this supplier to be set up and that the account is theirs, before the first payment. If it is a known supplier under a new name, say so (decide ... intended).",
            });
        }

        // a bill that looks paid already: in the list of past payments, or twice in this batch
        const bill = try billId(a, r.bill);
        var dup: ?Row = null;
        var why: []const u8 = "";
        for (past.items) |pr| {
            const pb = try billId(a, pr.bill);
            if (bill.len > 0 and std.mem.eql(u8, pb, bill)) {
                dup = pr;
                why = "the same bill number";
                break;
            }
            if (!std.mem.eql(u8, pr.currency, r.currency)) continue;
            const near = if (pr.date != null) @abs((r.date orelse now) - pr.date.?) <= @as(i64, rules.duplicate_days) * day_s else false;
            if (pr.amount == r.amount and near and (bill.len == 0 or pb.len == 0 or oneAway(bill, pb))) {
                dup = pr;
                why = if (bill.len > 0 and pb.len > 0) "the same amount, and a bill number one character away" else "the same amount, and no bill number to tell them apart";
            } else if (dup == null and bill.len > 0 and pb.len > 0 and oneAway(bill, pb) and pr.amount == r.amount) {
                dup = pr;
                why = "the same amount, and a bill number one character away";
            }
        }
        var twice_here: ?Row = null;
        for (list[0..index]) |other| {
            if (!std.mem.eql(u8, other.id, r.id) or !std.mem.eql(u8, other.currency, r.currency)) continue;
            const ob = try billId(a, other.bill);
            if ((bill.len > 0 and std.mem.eql(u8, ob, bill)) or (other.amount == r.amount and (bill.len == 0 or ob.len == 0 or oneAway(bill, ob)))) twice_here = other;
        }
        if (dup != null or twice_here != null) {
            var ev: std.ArrayList(audit.Row) = .empty;
            try ev.append(a, .{ .source = src, .value = row_text });
            if (dup) |d| try ev.append(a, .{ .source = "paymcp's list of past payments", .value = try c.p("paid {s} on {s}{s}{s}", .{ try c.money(d), try c.when(d), if (d.bill.len > 0) try c.p(", bill {s}", .{d.bill}) else "", if (d.batch.len > 0) try c.p(", in {s}", .{d.batch}) else "" }) });
            if (twice_here) |o| try ev.append(a, .{ .source = try c.p("{s}, line {d}", .{ batch, o.line }), .value = try c.p("{s}{s}, {s}", .{ o.supplier, if (o.bill.len > 0) try c.p(", bill {s}", .{o.bill}) else "", try c.money(o) }) });
            try c.out.append(a, .{
                .kind = .duplicate_payment,
                .key = try c.p("duplicate_payment:{s}:{s}:{s}", .{ batch, r.id, if (bill.len > 0) bill else try c.p("line{d}", .{r.line}) }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = if (dup) |d|
                    try c.p("{s} for {s} looks paid already: {s} as a payment of {s}.", .{ if (r.bill.len > 0) try c.p("Bill {s} of {s}", .{ r.bill, r.supplier }) else try c.p("A payment to {s}", .{r.supplier}), try c.money(r), why, try c.when(d) })
                else
                    try c.p("{s} is in this batch twice, for {s} each.", .{ if (r.bill.len > 0) try c.p("Bill {s} of {s}", .{ r.bill, r.supplier }) else try c.p("A payment to {s}", .{r.supplier}), try c.money(r) }),
                .rows = ev.items,
                .proposal = "Look at both bills. If it is one bill, take this row out of the batch. If they are two (a monthly fee of the same amount), say so (decide ... intended) and it is not asked again for this batch.",
            });
        }

        // an amount far above what this supplier was ever paid
        var most: i64 = 0;
        var counted: usize = 0;
        for (past.items) |pr| if (std.mem.eql(u8, pr.currency, r.currency)) {
            most = @max(most, pr.amount);
            counted += 1;
        };
        if (counted >= 3 and rules.out_of_line > 0 and r.amount > most * @as(i64, rules.out_of_line)) {
            try c.out.append(a, .{
                .kind = .out_of_line,
                .key = try c.p("out_of_line:{s}:{s}:{d}", .{ batch, r.id, r.line }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = try c.p("{s} is to be paid {s}; the most they were paid before is {s}.", .{ r.supplier, try c.money(r), try model.money(a, most, r.currency) }),
                .rows = try a.dupe(audit.Row, &.{
                    .{ .source = src, .value = row_text },
                    .{ .source = "paymcp's list of past payments", .value = try c.p("{d} payments to this supplier, the largest {s}", .{ counted, try model.money(a, most, r.currency) }) },
                }),
                .proposal = "Check the amount against the bill itself: a slipped decimal mark and a bill for a year instead of a month both look like this.",
            });
        }

        // an account that is another supplier's
        if (r.account.len > 0) {
            var other: []const u8 = "";
            for (sups) |s| if (!std.mem.eql(u8, s.id, r.id) and std.mem.eql(u8, s.account, r.account)) {
                other = s.name;
            };
            if (other.len == 0) for (hist.paid) |pr| if (!std.mem.eql(u8, pr.id, r.id) and std.mem.eql(u8, pr.account, r.account)) {
                other = pr.supplier;
            };
            if (other.len > 0) try c.out.append(a, .{
                .kind = .shared_account,
                .key = try c.p("shared_account:{s}:{s}", .{ batch, r.id }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = try c.p("{s} is to be paid to account {s}, which is also {s}'s.", .{ r.supplier, r.account, other }),
                .rows = try a.dupe(audit.Row, &.{.{ .source = src, .value = row_text }}),
                .proposal = "Two suppliers on one account can be one company under two names, or a mistake, or worse. Ask before paying; if it is as it should be, say so (decide ... intended).",
            });
        }
    }
    std.mem.sort(audit.Finding, c.out.items, {}, larger);
    return c.out.items;
}

fn atStake(k: audit.Kind) bool {
    return k == .account_changed or k == .invoice_account or k == .account_unregistered or k == .details_changed;
}

pub fn larger(_: void, x: audit.Finding, y: audit.Finding) bool {
    // bank details first: there the whole payment is at stake
    const xa = atStake(x.kind);
    const ya = atStake(y.kind);
    if (xa != ya) return xa;
    if (x.amount != y.amount) return x.amount > y.amount;
    return std.mem.lessThan(u8, x.key, y.key);
}

/// Over the past payments: those that look made twice. Each is the later
/// payment of a pair, with the earlier one beside it.
pub fn lookback(a: Allocator, hist: History, sups: []const Supplier, rules: Rules) ![]audit.Finding {
    var out: std.ArrayList(audit.Finding) = .empty;
    for (hist.paid, 0..) |r, i| {
        const bill = try billId(a, r.bill);
        for (hist.paid[0..i]) |pr| {
            if (!std.mem.eql(u8, pr.id, r.id) or !std.mem.eql(u8, pr.currency, r.currency) or pr.amount != r.amount) continue;
            const pb = try billId(a, pr.bill);
            const same_bill = bill.len > 0 and std.mem.eql(u8, pb, bill);
            const near = r.date != null and pr.date != null and @abs(r.date.? - pr.date.?) <= @as(i64, rules.duplicate_days) * day_s;
            const close = near and bill.len > 0 and pb.len > 0 and oneAway(bill, pb);
            if (!same_bill and !close) continue;
            var email: []const u8 = "";
            for (sups) |s| if (std.mem.eql(u8, s.id, r.id)) {
                email = s.email;
            };
            const sum = try model.money(a, r.amount, r.currency);
            const d1 = if (pr.date) |d| try model.day(a, d) else "an unknown day";
            const d2 = if (r.date) |d| try model.day(a, d) else "an unknown day";
            try out.append(a, .{
                .kind = .paid_twice,
                .key = try std.fmt.allocPrint(a, "paid_twice:{s}:{s}:{s}", .{ r.id, if (bill.len > 0) bill else "nobill", d2 }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = if (same_bill)
                    try std.fmt.allocPrint(a, "Bill {s} of {s} for {s} was paid on {s} and again on {s}.", .{ r.bill, r.supplier, sum, d1, d2 })
                else
                    try std.fmt.allocPrint(a, "{s} was paid {s} on {s} for bill {s} and on {s} for bill {s}: one character apart.", .{ r.supplier, sum, d1, pr.bill, d2, r.bill }),
                .rows = try a.dupe(audit.Row, &.{
                    .{ .source = "paymcp's list of past payments", .value = try std.fmt.allocPrint(a, "{s}, bill {s}, {s}{s}", .{ d1, pr.bill, sum, if (pr.batch.len > 0) try std.fmt.allocPrint(a, ", in {s}", .{pr.batch}) else "" }) },
                    .{ .source = "paymcp's list of past payments", .value = try std.fmt.allocPrint(a, "{s}, bill {s}, {s}{s}", .{ d2, r.bill, sum, if (r.batch.len > 0) try std.fmt.allocPrint(a, ", in {s}", .{r.batch}) else "" }) },
                }),
                .proposal = "Look at both payments in your bank statement. If the bill was paid twice, ask the supplier to send the second payment back or set it against the next bill. If these were two bills, say so (decide ... intended).",
                .letter = .{
                    .to = email,
                    .subject = try std.fmt.allocPrint(a, "A payment we made twice{s}", .{if (r.bill.len > 0) try std.fmt.allocPrint(a, ": {s}", .{r.bill}) else ""}),
                    .body = try std.fmt.allocPrint(a, "Hello,\n\nGoing through our payments we found that we paid you {s} twice{s}: on {s} and again on {s}.\n\nCould you check it on your side? If you received both, please send the second payment back to the account it came from, or tell us that you will set it against your next bill.", .{ sum, if (r.bill.len > 0) try std.fmt.allocPrint(a, " for bill {s}", .{r.bill}) else "", d1, d2 }),
                },
            });
            break;
        }
    }
    std.mem.sort(audit.Finding, out.items, {}, larger);
    return out.items;
}

const t = std.testing;

test "amounts_as_people_write_them" {
    try t.expectEqual(@as(?i64, 123456), amountOf("1 234,56", "eur"));
    try t.expectEqual(@as(?i64, 123456), amountOf("1,234.56", "eur"));
    try t.expectEqual(@as(?i64, 123456), amountOf("1.234,56", "pln"));
    try t.expectEqual(@as(?i64, 123450), amountOf("1234.5", "eur"));
    try t.expectEqual(@as(?i64, 98000), amountOf("980", "eur"));
    try t.expectEqual(@as(?i64, 1250), amountOf("12,50", "eur"));
    // three digits after one mark: thousands, not a third decimal
    try t.expectEqual(@as(?i64, 123400), amountOf("1,234", "eur"));
    try t.expectEqual(@as(?i64, 123400), amountOf("1.234", "eur"));
    try t.expectEqual(@as(?i64, 123456700), amountOf("1,234,567", "eur"));
    try t.expectEqual(@as(?i64, 1200), amountOf("1200", "jpy"));
    try t.expectEqual(@as(?i64, -500), amountOf("-5.00", "eur"));
    // what can't be read for sure is not guessed
    try t.expect(amountOf("12.345.67", "eur") == null);
    try t.expect(amountOf("12,5,0", "eur") == null);
    try t.expect(amountOf("1.2345", "eur") == null);
    try t.expect(amountOf("12.50 EUR", "eur") == null);
    try t.expect(amountOf("", "eur") == null);
    try t.expect(amountOf("12.5", "jpy") == null);
    try t.expectEqual(@as(?i64, 1763164800), dayOf("15.11.2025"));
    try t.expectEqual(dayOf("2025-11-15"), dayOf("15.11.2025"));
    try t.expect(dayOf("11/15/2025") == null);
}

const sup_csv =
    \\supplier,tax_id,account,phone,email
    \\Nordlys Print,PL5260001246,PL61 1090 1014 0000 0712 1981 2874,+48 22 555 01 01,billing@nordlys.example
    \\Kestrel Hosting,,DE89370400440532013000,+49 30 5550 199,accounts@kestrel.example
    \\Mirela Cleaning,,PL27114020040000300201355387,,
    \\
;

const past_csv =
    \\vendor;invoice;total;date;iban;vat
    \\Nordlys Print;NP/2025/101;1 230,00;2025-08-04;PL61109010140000071219812874;PL5260001246
    \\Nordlys Print;NP/2025/118;1 230,00;2025-09-03;PL61109010140000071219812874;PL5260001246
    \\Nordlys Print;NP/2025/131;984,00;2025-10-02;PL61109010140000071219812874;PL5260001246
    \\Kestrel Hosting;KH-5521;149,00;2025-09-10;DE89370400440532013000;
    \\Kestrel Hosting;KH-5521;149,00;2025-09-24;DE89370400440532013000;
    \\Kestrel Hosting;KH-5604;149,00;2025-10-10;DE89370400440532013000;
    \\
;

fn load(a: Allocator) !History {
    var d: Diag = .{};
    const past = try rows(a, past_csv, .{}, &d);
    var n: usize = 0;
    const lines = try paidLines(a, .{}, "payments-2025.csv", past, 1000, &n);
    try t.expectEqual(@as(usize, 6), n);
    return history(a, lines, &d);
}

test "a_batch_checked_before_it_is_paid" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const hist = try load(a);
    const sups = try suppliers(a, sup_csv, &d);
    try t.expectEqual(@as(usize, 3), sups.len);
    try t.expectEqualStrings("5260001246", sups[0].id);
    try t.expectEqualStrings("kestrel hosting", sups[1].id);
    const now: i64 = 1763164800; // 2025-11-15
    const batch = try rows(a,
        \\supplier,tax_id,bill,amount,currency,date,account
        \\Nordlys Print,PL5260001246,NP/2025/140,"1,230.00",EUR,2025-11-17,PL44 1140 2004 0000 3102 7654 3210
        \\Kestrel  hosting,,KH-5604,149.00,EUR,2025-11-17,DE89370400440532013000
        \\Kestrel Hosting,,KH-5699,1490.00,EUR,2025-11-17,DE89370400440532013000
        \\Mirela Cleaning,,11/2025,300.00,EUR,2025-11-17,PL27114020040000300201355387
        \\Quillon Supplies,,Q-77,512.40,EUR,2025-11-17,DE89370400440532013000
        \\
    , .{}, &d);
    try t.expectEqual(@as(usize, 5), batch.len);
    const fs = try check(a, batch, sups, hist, .{}, "run-2025-11-17.csv", now);
    var kinds: std.ArrayList(u8) = .empty;
    for (fs) |f| try kinds.print(a, "{s} {s} {d}\n", .{ @tagName(f.kind), f.name, f.amount });
    try t.expectEqualStrings(
        \\account_changed Nordlys Print 123000
        \\out_of_line Kestrel Hosting 149000
        \\new_supplier Quillon Supplies 51240
        \\shared_account Quillon Supplies 51240
        \\new_supplier Mirela Cleaning 30000
        \\duplicate_payment Kestrel  hosting 14900
        \\
    , kinds.items);
    // bank details first, with the account before and the phone held before the change
    try t.expectEqualStrings("Nordlys Print is to be paid 1230.00 EUR to account 44114020040000310276543210; the last payment to them went to 61109010140000071219812874.", fs[0].what);
    try t.expectEqualStrings("last paid on 2025-10-02 to account 61109010140000071219812874; 3 payments went to that account", fs[0].rows[1].value);
    try t.expect(std.mem.indexOf(u8, fs[0].proposal, "(your suppliers file has +48 22 555 01 01)") != null);
    try t.expectEqualStrings("account_changed:run-2025-11-17.csv:5260001246", fs[0].key);
    // the bill paid in October, found though the name is spelled with two spaces
    try t.expectEqualStrings("Bill KH-5604 of Kestrel  hosting for 149.00 EUR looks paid already: the same bill number as a payment of 2025-10-10.", fs[5].what);
    try t.expectEqualStrings("Kestrel Hosting is to be paid 1490.00 EUR; the most they were paid before is 149.00 EUR.", fs[1].what);
    try t.expectEqualStrings("Quillon Supplies is to be paid to account DE89370400440532013000, which is also Kestrel Hosting's.", fs[3].what);
    // with no past payments at all, nobody is "new": there is nothing to know them by
    const bare = try check(a, batch, sups, .{}, .{}, "run.csv", now);
    for (bare) |f| try t.expect(f.kind != .new_supplier and f.kind != .duplicate_payment and f.kind != .out_of_line);
    // ...but the suppliers file still shows the changed account
    try t.expectEqual(audit.Kind.account_changed, bare[0].kind);
    try t.expectEqualStrings("Nordlys Print is to be paid 1230.00 EUR to account 44114020040000310276543210; your suppliers file has 61109010140000071219812874.", bare[0].what);
}

test "what_was_checked_is_what_is_paid_and_the_past_is_searched_once" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const hist = try load(a);
    // the look-back: Kestrel's bill KH-5521 was paid twice, two weeks apart
    const twice = try lookback(a, hist, try suppliers(a, sup_csv, &d), .{});
    try t.expectEqual(@as(usize, 1), twice.len);
    try t.expectEqualStrings("Bill KH-5521 of Kestrel Hosting for 149.00 EUR was paid on 2025-09-10 and again on 2025-09-24.", twice[0].what);
    try t.expectEqualStrings("accounts@kestrel.example", twice[0].letter.?.to);
    try t.expect(std.mem.indexOf(u8, twice[0].letter.?.body, "we paid you 149.00 EUR twice for bill KH-5521: on 2025-09-10 and again on 2025-09-24.") != null);
    // importing the same file again adds nothing
    var n: usize = 0;
    _ = try paidLines(a, hist, "payments-2025.csv", try rows(a, past_csv, .{}, &d), 2000, &n);
    try t.expectEqual(@as(usize, 0), n);
    // a batch as checked, then altered before paying: an account swapped, a row added
    const before = try rows(a, "supplier,bill,amount,account\nNordlys Print,NP/1,100.00,PL61109010140000071219812874\nKestrel Hosting,KH-1,149.00,DE89370400440532013000\n", .{}, &d);
    const h2 = try history(a, try checkedLine(a, "run.csv", before, 3000), &d);
    const after = try rows(a, "supplier,bill,amount,account\nNordlys Print,NP/1,100.00,PL44114020040000310276543210\nKestrel Hosting,KH-1,149.00,DE89370400440532013000\nQuillon Supplies,Q-1,900.00,DE00\n", .{}, &d);
    const dr = try drift(a, h2.checkOf("run.csv").?, after);
    try t.expectEqual(@as(usize, 2), dr.changed.len);
    try t.expectEqual(@as(usize, 1), dr.missing);
    try t.expectEqual(@as(usize, 2), dr.changed[0].line);
    const same = try drift(a, h2.checkOf("run.csv").?, before);
    try t.expect(same.changed.len == 0 and same.missing == 0);
    // bills numbered in a row for the same amount are two bills; a slipped letter is one
    try t.expect(!oneAway("102025", "112025") and !oneAway("kh5604", "kh5605"));
    try t.expect(oneAway("np2025l31", "np2025131") and oneAway("kh5604", "kh5604a") and !oneAway("ab", "abc"));
    // files that can't be used say where
    try t.expectError(error.BadFile, rows(a, "supplier,amount\nNordlys,12.345.67\n", .{}, &d));
    try t.expectEqual(@as(usize, 2), d.line);
    try t.expectError(error.BadFile, rows(a, "who,how much\nNordlys,12\n", .{}, &d));
    try t.expectError(error.BadFile, rows(a, "supplier,vendor,amount\nA,B,1\n", .{}, &d));
    try t.expect(std.mem.indexOf(u8, d.what, "two columns can be read as supplier") != null);
    try t.expectError(error.BadFile, history(a, "not a line\n", &d));
}

test "a_tax_number_and_an_account_written_two_ways_are_one" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const sups = try suppliers(a, "supplier,tax_id,account\nMirela Sprzatanie,PL 185-451-08-77,PL27 1140 2004 0000 3002 0135 5387\nKestrel Hosting,DE811907980,DE89 3704 0044 0532 0130 00\n", &d);
    try t.expectEqualStrings("1854510877", sups[0].id);
    try t.expectEqualStrings("27114020040000300201355387", sups[0].account);
    // (only a Polish IBAN is its national number with two letters before it)
    try t.expectEqualStrings("DE89370400440532013000", sups[1].account);
    const list = try rows(a, "supplier;nip;invoice;amount;account\nMirela Sprzatanie;1854510877;11/2026;300,00;27 1140 2004 0000 3002 0135 5387\n", .{ .currency = "pln" }, &d);
    try t.expectEqualStrings("1854510877", list[0].id);
    // the same supplier on the same account: nothing changed, and nobody shares it
    const fs = try check(a, list, sups, .{}, .{}, "run.csv", 1795392000);
    try t.expectEqual(@as(usize, 0), fs.len);
    // a list written before, with the country's letters, is read as the same supplier
    const h = try history(a, "{\"at\":1,\"event\":\"paid\",\"batch\":\"b\",\"supplier\":\"Mirela Sprzatanie\",\"id\":\"PL1854510877\",\"bill\":\"10/2026\",\"amount\":30000,\"currency\":\"pln\",\"date\":1793000000,\"account\":\"PL27114020040000300201355387\",\"sha\":\"x\"}\n{\"at\":2,\"event\":\"whitelist\",\"batch\":\"b\",\"nip\":\"1854510877\",\"account\":\"27114020040000300201355387\",\"assigned\":true,\"id\":\"c-1\",\"when\":\"\"}\n", &d);
    try t.expectEqualStrings("1854510877", h.paid[0].id);
    try t.expectEqualStrings("27114020040000300201355387", h.paid[0].account);
    const again = try check(a, list, sups, h, .{}, "run.csv", 1795392000);
    try t.expectEqual(@as(usize, 0), again.len);
    try t.expectEqualStrings("a b ltd", try idAgain(a, "a b ltd"));
}

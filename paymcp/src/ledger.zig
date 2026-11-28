//! Reading the books for the payment-run check, so that nothing has to be
//! exported: the suppliers with their bank details, the bills awaiting
//! payment, and the payments made on bills. Xero's accounting API, with
//! an app of the business's own (a "custom connection": a client id and
//! secret that stand for one organisation, no browser).
//!
//! It only reads: one POST for the token (which is how a token is asked
//! for), then GETs. The scopes it asks for are the three that read:
//! accounting.contacts.read, accounting.invoices.read,
//! accounting.payments.read.
//!
//! What the books don't give: the account a past payment went to. So a
//! change of a supplier's bank details is found by remembering what the
//! books said at each reading (payrun.History.seen), not from payments.
//!
//! Written from Xero's documentation as read on 2026-11-27, and tried
//! against the stand-in only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");
const jv = @import("jv.zig");
const model = @import("model.zig");
const audit = @import("audit.zig");
const payrun = @import("payrun.zig");

pub const scopes = "accounting.contacts.read accounting.invoices.read accounting.payments.read";

pub const Keys = struct {
    id: []const u8 = "",
    secret: []const u8 = "",
};

pub const Settings = struct {
    url: []const u8 = "https://api.xero.com",
    token_url: []const u8 = "https://identity.xero.com",
    /// How far back payments on bills are read.
    history_days: u32 = 730,
    /// A change of bank details in the books is asked about for this long.
    changed_days: u32 = 90,
};

pub const Books = struct {
    suppliers: []const payrun.Supplier = &.{},
    /// When each supplier's contact was last edited in the books (seconds; 0: not said).
    edited: []const i64 = &.{},
    /// How many contacts there are in all.
    contacts: usize = 0,
    /// The bills awaiting payment, as a batch.
    bills: []const payrun.Row = &.{},
    /// The payments made on bills.
    paid: []const payrun.Row = &.{},
    requests: u32 = 0,
};

/// Waits between tries, in ms (tests: none).
pub var wait_ms: u32 = 1000;

const Ctx = struct {
    a: Allocator,
    io: Io,
    requests: u32 = 0,
    why: []const u8 = "",

    fn ask(c: *Ctx, hc: *http.Client, req: http.Request) !jv.Value {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            c.requests += 1;
            const ans = http.fetch(hc, c.a, req) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (tries < 2) {
                    c.pause(tries);
                    continue;
                }
                c.why = try std.fmt.allocPrint(c.a, "Xero couldn't be reached ({s})", .{@errorName(e)});
                return error.Provider;
            };
            if (ans.status == 200) return jv.parse(c.a, ans.body) orelse {
                c.why = "Xero's answer wasn't JSON";
                return error.Provider;
            };
            if ((ans.status == 429 or ans.status >= 500) and tries < 3) {
                c.pause(tries);
                continue;
            }
            const v = jv.parse(c.a, ans.body);
            const msg = std.mem.trimEnd(u8, jv.str(jv.get(v, "Detail")) orelse jv.str(jv.get(v, "Message")) orelse jv.str(jv.get(v, "error")) orelse "", ". \r\n");
            c.why = switch (ans.status) {
                400, 401 => try std.fmt.allocPrint(c.a, "Xero refused the app's id and secret ({d}{s}{s})", .{ ans.status, if (msg.len > 0) ": " else "", msg }),
                403 => try std.fmt.allocPrint(c.a, "the app may not read this in Xero (403){s}{s}: it needs the scopes {s}", .{ if (msg.len > 0) ": " else "", msg, scopes }),
                429 => "Xero is still saying too many requests (429): its limit is 60 a minute",
                else => try std.fmt.allocPrint(c.a, "Xero answered {d}{s}{s}", .{ ans.status, if (msg.len > 0) ": " else "", if (msg.len > 200) msg[0..200] else msg }),
            };
            return error.Provider;
        }
    }

    fn pause(c: *Ctx, tries: u32) void {
        if (wait_ms == 0) return;
        c.io.sleep(.fromMilliseconds(@as(i64, wait_ms) << @intCast(@min(tries, 4))), .awake) catch {};
    }

    /// Every item of a paged list (`name` is the array's name), page by page.
    fn pages(c: *Ctx, hc: *http.Client, token: []const u8, path: []const u8, name: []const u8, out: *std.ArrayList(jv.Value)) !void {
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";
        var page: i64 = 1;
        while (page <= 500) : (page += 1) {
            const v = try c.ask(hc, .{ .method = .GET, .path = try std.fmt.allocPrint(c.a, "{s}{s}page={d}", .{ path, sep, page }), .key = token, .accept = "application/json", .limits = limits });
            const items = jv.arr(jv.get(v, name)) orelse {
                c.why = try std.fmt.allocPrint(c.a, "Xero's answer had no {s}", .{name});
                return error.Provider;
            };
            for (items) |x| try out.append(c.a, x);
            // the answer says how many pages there are; without that, a page that isn't full is the last
            if (jv.int(jv.at(v, &.{ "pagination", "pageCount" }))) |n| {
                if (page >= n) return;
            } else if (items.len < 100) return;
        }
    }
};

const limits: http.Limits = .{ .idle_ms = 20_000, .total_ms = 60_000 };

/// "/Date(1518685950940+0000)/" (milliseconds), or "2009-05-27T00:00:00": the day's first second.
pub fn dayOf(v: ?jv.Value) ?i64 {
    const s = jv.str(v) orelse return null;
    if (std.mem.indexOf(u8, s, "Date(")) |at| {
        var end = at + 5;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        const ms = std.fmt.parseInt(i64, s[at + 5 .. end], 10) catch return null;
        return @divFloor(@divFloor(ms, 1000), 86400) * 86400;
    }
    if (s.len >= 10) return model.dayStart(s[0..10]);
    return null;
}

fn timeOf(v: ?jv.Value) i64 {
    const s = jv.str(v) orelse return 0;
    const at = std.mem.indexOf(u8, s, "Date(") orelse return 0;
    var end = at + 5;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    return @divFloor(std.fmt.parseInt(i64, s[at + 5 .. end], 10) catch return 0, 1000);
}

/// An amount the books give as a number or as a string ("2025.00"), in
/// the currency's smallest unit.
pub fn amountOf(v: ?jv.Value, currency: []const u8) ?i64 {
    const val = v orelse return null;
    if (val == .string) {
        for (val.string) |ch| if (!std.ascii.isDigit(ch) and ch != '.' and ch != '-') return null;
        if (std.mem.indexOfScalar(u8, val.string, '.')) |dot| if (val.string.len - dot - 1 > 2) {
            // (more digits than the currency has: as a number)
            const f = std.fmt.parseFloat(f64, val.string) catch return null;
            return scaled(f, currency);
        };
        return payrun.amountOf(val.string, currency);
    }
    return scaled(jv.num(val) orelse return null, currency);
}

fn scaled(f: f64, currency: []const u8) ?i64 {
    // (as model.money writes them)
    var scale: f64 = 100;
    for ([_][]const u8{ "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf" }) |c| if (std.ascii.eqlIgnoreCase(c, currency)) {
        scale = 1;
    };
    for ([_][]const u8{ "bhd", "jod", "kwd", "omr", "tnd" }) |c| if (std.ascii.eqlIgnoreCase(c, currency)) {
        scale = 1000;
    };
    const x = @round(f * scale);
    if (!(x > -9.0e15 and x < 9.0e15)) return null;
    return @intFromFloat(x);
}

fn base64(a: Allocator, v: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(v.len));
    return enc.encode(out, v);
}

const Contact = struct { id: []const u8, sup: payrun.Supplier };

/// The books as they are now. error.Failed with `why` set.
pub fn read(gpa: Allocator, a: Allocator, io: Io, set: Settings, keys: Keys, now: i64, why: *[]const u8) !Books {
    var c: Ctx = .{ .a = a, .io = io };
    return readWith(&c, gpa, set, keys, now) catch |e| {
        if (e != error.Provider) return e;
        why.* = c.why;
        return error.Failed;
    };
}

fn readWith(c: *Ctx, gpa: Allocator, set: Settings, keys: Keys, now: i64) !Books {
    const a = c.a;
    if (keys.id.len == 0 or keys.secret.len == 0) {
        c.why = "XERO_CLIENT_ID and XERO_CLIENT_SECRET aren't set: the id and secret of your own Xero app (README, The books)";
        return error.Provider;
    }
    // the token: asked for with the app's id and secret, good for half an hour
    var tc: http.Client = .init(gpa, c.io, http.Target.parse(set.token_url) catch {
        c.why = try std.fmt.allocPrint(a, "{s} isn't an address paymcp can reach", .{set.token_url});
        return error.Provider;
    });
    defer tc.deinit();
    tc.user_agent = "paymcp";
    const basic = try std.fmt.allocPrint(a, "Basic {s}", .{try base64(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ keys.id, keys.secret }))});
    const tv = try c.ask(&tc, .{
        .method = .POST,
        .path = "/connect/token",
        .body = "grant_type=client_credentials&scope=accounting.contacts.read%20accounting.invoices.read%20accounting.payments.read",
        .content_type = "application/x-www-form-urlencoded",
        .accept = "application/json",
        .headers = &.{.{ .name = "Authorization", .value = basic }},
        .limits = limits,
    });
    const token = jv.str(jv.get(tv, "access_token")) orelse {
        c.why = "Xero gave no token";
        return error.Provider;
    };

    var hc: http.Client = .init(gpa, c.io, http.Target.parse(set.url) catch {
        c.why = try std.fmt.allocPrint(a, "{s} isn't an address paymcp can reach", .{set.url});
        return error.Provider;
    });
    defer hc.deinit();
    hc.user_agent = "paymcp";

    // contacts: a supplier is one with bills entered against it, or with bank details
    var raw: std.ArrayList(jv.Value) = .empty;
    try c.pages(&hc, token, "/api.xro/2.0/Contacts", "Contacts", &raw);
    var contacts: std.ArrayList(Contact) = .empty;
    var sups: std.ArrayList(payrun.Supplier) = .empty;
    var edited: std.ArrayList(i64) = .empty;
    for (raw.items, 0..) |v, i| {
        const name = jv.str(jv.get(v, "Name")) orelse continue;
        const status = jv.str(jv.get(v, "ContactStatus")) orelse "ACTIVE";
        const tax = try payrun.taxId(a, jv.str(jv.get(v, "TaxNumber")) orelse "");
        var s: payrun.Supplier = .{
            .line = i + 1,
            .name = name,
            .id = if (tax.len > 0) tax else try payrun.nameId(a, name),
            .account = try payrun.accountId(a, jv.str(jv.get(v, "BankAccountDetails")) orelse ""),
            .email = jv.str(jv.get(v, "EmailAddress")) orelse "",
        };
        for (jv.arr(jv.get(v, "Phones")) orelse &.{}) |ph| {
            const number = jv.str(jv.get(ph, "PhoneNumber")) orelse "";
            if (number.len == 0 or s.phone.len > 0) continue;
            const country = jv.str(jv.get(ph, "PhoneCountryCode")) orelse "";
            const area = jv.str(jv.get(ph, "PhoneAreaCode")) orelse "";
            s.phone = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (country.len > 0) "+" else "", country, if (country.len > 0) " " else "", if (area.len > 0) try std.fmt.allocPrint(a, "{s} ", .{area}) else "", number });
        }
        try contacts.append(a, .{ .id = jv.str(jv.get(v, "ContactID")) orelse "", .sup = s });
        if (!std.mem.eql(u8, status, "ACTIVE")) continue;
        if (!(jv.boolean(jv.get(v, "IsSupplier")) orelse false) and s.account.len == 0) continue;
        try sups.append(a, s);
        try edited.append(a, timeOf(jv.get(v, "UpdatedDateUTC")));
    }

    // bills awaiting payment
    raw = .empty;
    try c.pages(&hc, token, "/api.xro/2.0/Invoices?where=Type%3d%3d%22ACCPAY%22+AND+Status%3d%3d%22AUTHORISED%22", "Invoices", &raw);
    var bills: std.ArrayList(payrun.Row) = .empty;
    for (raw.items, 0..) |v, i| {
        var r = rowOf(a, contacts.items, jv.get(v, "Contact"), jv.str(jv.get(v, "InvoiceNumber")) orelse "", jv.str(jv.get(v, "CurrencyCode")) orelse "") catch continue;
        r.line = i + 1;
        r.amount = amountOf(jv.get(v, "AmountDue") orelse jv.get(v, "Total"), r.currency) orelse continue;
        if (r.amount <= 0) continue;
        r.date = dayOf(jv.get(v, "DueDateString")) orelse dayOf(jv.get(v, "DueDate"));
        r.sha = try fingerprint(a, r);
        try bills.append(a, r);
    }

    // payments made on bills, as far back as the settings say
    raw = .empty;
    const since = try model.day(a, now - @as(i64, set.history_days) * 86400);
    try c.pages(&hc, token, try std.fmt.allocPrint(a, "/api.xro/2.0/Payments?where=PaymentType%3d%3d%22ACCPAYPAYMENT%22+AND+Status%3d%3d%22AUTHORISED%22+AND+Date%3e%3dDateTime({s}%2c{s}%2c{s})", .{ since[0..4], since[5..7], since[8..10] }), "Payments", &raw);
    var paid: std.ArrayList(payrun.Row) = .empty;
    for (raw.items) |v| {
        const inv = jv.get(v, "Invoice");
        var r = rowOf(a, contacts.items, jv.get(inv, "Contact"), jv.str(jv.get(inv, "InvoiceNumber")) orelse "", jv.str(jv.get(inv, "CurrencyCode")) orelse "") catch continue;
        r.amount = amountOf(jv.get(v, "Amount"), r.currency) orelse continue;
        if (r.amount <= 0) continue;
        r.date = dayOf(jv.get(v, "Date"));
        // (the books don't say which account a payment went to)
        r.account = "";
        r.batch = "the books";
        r.sha = try fingerprint(a, r);
        try paid.append(a, r);
    }
    return .{ .suppliers = sups.items, .edited = edited.items, .contacts = contacts.items.len, .bills = bills.items, .paid = paid.items, .requests = c.requests };
}

fn rowOf(a: Allocator, contacts: []const Contact, contact: ?jv.Value, bill: []const u8, currency: []const u8) !payrun.Row {
    const cid = jv.str(jv.get(contact, "ContactID")) orelse "";
    var r: payrun.Row = .{ .bill = bill, .currency = if (currency.len > 0) try std.ascii.allocLowerString(a, currency) else "" };
    for (contacts) |c| if (cid.len > 0 and std.mem.eql(u8, c.id, cid)) {
        r.supplier = c.sup.name;
        r.id = c.sup.id;
        r.account = c.sup.account;
        return r;
    };
    r.supplier = jv.str(jv.get(contact, "Name")) orelse return error.NoSupplier;
    r.id = try payrun.nameId(a, r.supplier);
    return r;
}

fn fingerprint(a: Allocator, r: payrun.Row) ![]const u8 {
    return payrun.sha(a, r);
}

// ---- bank details that changed in the books ----

pub const Changes = struct {
    findings: []audit.Finding = &.{},
    /// Lines for paymcp's list: each supplier's details as first seen, or as changed.
    lines: []const u8 = "",
    /// Suppliers whose details were written down for the first time.
    first_seen: usize = 0,
};

/// Sets each supplier's bank details beside what paymcp saw at readings
/// before (`hist.seen`). Details seen for the first time are written
/// down and nothing is said; details that differ from the last seen are
/// written down as changed, and asked about for `changed_days`.
pub fn changes(a: Allocator, books: Books, hist: payrun.History, set: Settings, now: i64) !Changes {
    var out: std.ArrayList(audit.Finding) = .empty;
    var lines: std.ArrayList(u8) = .empty;
    var res: Changes = .{};
    for (books.suppliers, 0..) |s, index| {
        // what was seen before, the last two
        var last: ?payrun.History.Seen = null;
        var before: ?payrun.History.Seen = null;
        for (hist.seen) |x| if (std.mem.eql(u8, x.id, s.id)) {
            before = last;
            last = x;
        };
        var was: ?payrun.History.Seen = null;
        var changed_at: i64 = 0;
        if (last == null or !std.mem.eql(u8, last.?.account, s.account)) {
            try lines.print(a, "{{\"at\":{d},\"event\":\"seen\",\"id\":{f},\"supplier\":{f},\"account\":{f},\"phone\":{f}}}\n", .{ now, std.json.fmt(s.id, .{}), std.json.fmt(s.name, .{}), std.json.fmt(s.account, .{}), std.json.fmt(s.phone, .{}) });
            if (last == null) {
                res.first_seen += 1;
                continue;
            }
            was = last;
            changed_at = now;
        } else if (before) |b| {
            // seen changed at an earlier reading: still asked about for a while
            was = b;
            changed_at = last.?.at;
        }
        const old = was orelse continue;
        if (now - changed_at > @as(i64, set.changed_days) * 86400) continue;
        var due: i64 = 0;
        var n: usize = 0;
        var currency: []const u8 = "";
        for (books.bills) |b| if (std.mem.eql(u8, b.id, s.id) and (currency.len == 0 or std.mem.eql(u8, currency, b.currency))) {
            due += b.amount;
            n += 1;
            currency = b.currency;
        };
        var ev: std.ArrayList(audit.Row) = .empty;
        try ev.append(a, .{ .source = try std.fmt.allocPrint(a, "the books, as read {s}", .{try model.day(a, old.at)}), .value = try std.fmt.allocPrint(a, "account {s}{s}", .{ if (old.account.len > 0) old.account else "none", if (old.phone.len > 0) try std.fmt.allocPrint(a, ", phone {s}", .{old.phone}) else "" }) });
        try ev.append(a, .{ .source = try std.fmt.allocPrint(a, "the books, as read {s}", .{try model.day(a, changed_at)}), .value = try std.fmt.allocPrint(a, "account {s}{s}", .{ if (s.account.len > 0) s.account else "none", if (s.phone.len > 0) try std.fmt.allocPrint(a, ", phone {s}", .{s.phone}) else "" }) });
        if (index < books.edited.len and books.edited[index] > 0) try ev.append(a, .{ .source = "the books", .value = try std.fmt.allocPrint(a, "the supplier's record was last edited on {s} (any edit, not only this one)", .{try model.day(a, books.edited[index])}) });
        if (n > 0) try ev.append(a, .{ .source = "bills awaiting payment", .value = try std.fmt.allocPrint(a, "{d} to this supplier, {s}", .{ n, try model.money(a, due, currency) }) });
        try out.append(a, .{
            .kind = .details_changed,
            .key = try std.fmt.allocPrint(a, "details_changed:{s}:{s}", .{ s.id, if (s.account.len > 0) s.account else "none" }),
            .customer = s.id,
            .name = s.name,
            .amount = due,
            .currency = currency,
            .per = if (n > 0) .once else .unknown,
            .what = try std.fmt.allocPrint(a, "{s}'s bank details in the books changed from {s} to {s}: paymcp read the one on {s} and the other on {s}.", .{ s.name, if (old.account.len > 0) old.account else "none", if (s.account.len > 0) s.account else "none", try model.day(a, old.at), try model.day(a, changed_at) }),
            .rows = ev.items,
            .proposal = "Find out who changed it and why, before the next payment to this supplier. Call the supplier on a number you had before the change (the first row has the one the books had then), never one from the message that asked for it, and ask whether the account is theirs. Then write down who you called and what they said (decide ... intended). A changed account is the commonest way a payment is stolen.",
        });
    }
    res.findings = out.items;
    res.lines = lines.items;
    return res;
}

const t = std.testing;

test "dates_and_amounts_as_the_books_write_them" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = jv.parse(a, "{\"a\":\"\\/Date(1795392000000+0000)\\/\",\"b\":\"2026-11-23T00:00:00\",\"c\":\"2025.00\",\"d\":500.0,\"e\":90,\"f\":\"12.3456\"}").?;
    try t.expectEqual(@as(?i64, 1795392000), dayOf(jv.get(v, "a")));
    try t.expectEqual(@as(?i64, 1795392000), dayOf(jv.get(v, "b")));
    try t.expectEqual(@as(?i64, 202500), amountOf(jv.get(v, "c"), "eur"));
    try t.expectEqual(@as(?i64, 50000), amountOf(jv.get(v, "d"), "eur"));
    try t.expectEqual(@as(?i64, 90), amountOf(jv.get(v, "e"), "jpy"));
    try t.expectEqual(@as(?i64, 1235), amountOf(jv.get(v, "f"), "eur"));
    try t.expectEqualStrings("YTpi", try base64(a, "a:b"));
}

test "bank_details_that_changed_between_two_readings_of_the_books" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day0: i64 = 1795392000;
    var d: payrun.Diag = .{};
    const nordlys: payrun.Supplier = .{ .name = "Nordlys Print", .id = "5260001246", .account = "61109010140000071219812874", .phone = "+48 22 5550101" };
    var books: Books = .{ .suppliers = &.{nordlys}, .edited = &.{day0 - 86400}, .bills = &.{.{ .supplier = "Nordlys Print", .id = "5260001246", .bill = "NP/1", .amount = 123000, .currency = "eur" }} };
    // the first reading writes the details down and says nothing
    const first = try changes(a, books, .{}, .{}, day0);
    try t.expectEqual(@as(usize, 0), first.findings.len);
    try t.expectEqual(@as(usize, 1), first.first_seen);
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, first.lines);
    // the same details a week later: nothing new, nothing written
    const same = try changes(a, books, try payrun.history(a, raw.items, &d), .{}, day0 + 7 * 86400);
    try t.expectEqual(@as(usize, 0), same.findings.len);
    try t.expectEqual(@as(usize, 0), same.lines.len);
    // another account in the books: asked about, with the money waiting to go there
    var moved = nordlys;
    moved.account = "44114020040000310276543210";
    books.suppliers = &.{moved};
    const changed = try changes(a, books, try payrun.history(a, raw.items, &d), .{}, day0 + 14 * 86400);
    try t.expectEqual(@as(usize, 1), changed.findings.len);
    const f = changed.findings[0];
    try t.expectEqualStrings("details_changed:5260001246:44114020040000310276543210", f.key);
    try t.expectEqual(@as(i64, 123000), f.amount);
    try t.expectEqualStrings("Nordlys Print's bank details in the books changed from 61109010140000071219812874 to 44114020040000310276543210: paymcp read the one on 2026-11-23 and the other on 2026-12-07.", f.what);
    try t.expectEqualStrings("account 61109010140000071219812874, phone +48 22 5550101", f.rows[0].value);
    try raw.appendSlice(a, changed.lines);
    // it stays asked about at later readings, with the same key, until it is old
    const later = try changes(a, books, try payrun.history(a, raw.items, &d), .{}, day0 + 30 * 86400);
    try t.expectEqual(@as(usize, 1), later.findings.len);
    try t.expectEqualStrings(f.key, later.findings[0].key);
    try t.expectEqual(@as(usize, 0), later.lines.len);
    const old = try changes(a, books, try payrun.history(a, raw.items, &d), .{}, day0 + 200 * 86400);
    try t.expectEqual(@as(usize, 0), old.findings.len);
}

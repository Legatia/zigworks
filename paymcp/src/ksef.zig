//! Poland's structured invoices (KSeF) set beside a batch of payments.
//! Since 2026 a Polish supplier's invoice exists as data at the tax
//! office: an XML file (the FA(2) and FA(3) layouts) that names the
//! seller, the number, the sum and the account to pay to. A folder of
//! those files, as the taxpayer's application or the accounting program
//! saves them, is read here, and each payment of a batch is compared with
//! its invoice: the account the batch pays to against the account on the
//! invoice, and the amount against the invoice's sum.
//!
//! Files on this computer only: KSeF itself is not asked. What a file
//! says is data, whatever it says. A file with a DOCTYPE is refused.
//!
//! Written from the published layouts (crd.gov.pl, read 2026-11-27) and
//! tried on the Ministry's own example file and on made-up ones.
const std = @import("std");
const Allocator = std.mem.Allocator;
const audit = @import("audit.zig");
const model = @import("model.zig");
const payrun = @import("payrun.zig");

pub const Invoice = struct {
    /// The file's name.
    file: []const u8 = "",
    seller_nip: []const u8 = "",
    seller_name: []const u8 = "",
    buyer_nip: []const u8 = "",
    /// P_2: the number the seller gave it.
    number: []const u8 = "",
    /// P_1: the day it was issued, as written.
    date: []const u8 = "",
    currency: []const u8 = "pln",
    /// P_15: what is to be paid, in the currency's smallest unit (for a
    /// correction: the difference, which can be below zero).
    total: i64 = 0,
    /// VAT, KOR, ZAL, ROZ, UPR, KOR_ZAL, KOR_ROZ.
    kind: []const u8 = "VAT",
    /// The accounts to pay to, letters and digits only; a factor's apart.
    accounts: []const []const u8 = &.{},
    factor_accounts: []const []const u8 = &.{},
    /// The invoices a correction corrects, by their numbers.
    corrects: []const []const u8 = &.{},
    /// The invoice says it was paid when it was issued, and on which day ("": not said).
    paid: bool = false,
    paid_on: []const u8 = "",

    pub fn correction(i: Invoice) bool {
        return std.mem.startsWith(u8, i.kind, "KOR");
    }
};

pub const Diag = struct { what: []const u8 = "" };

fn fail(diag: *Diag, what: []const u8) error{NotAnInvoice} {
    diag.what = what;
    return error.NotAnInvoice;
}

// ---- a small reader of XML: every element that holds text, by its path ----

const Leaf = struct { path: []const u8, text: []const u8 };

fn decodeText(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(a, raw[i]);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.BadXml;
        const name = raw[i + 1 .. end];
        if (std.mem.eql(u8, name, "amp")) {
            try out.append(a, '&');
        } else if (std.mem.eql(u8, name, "lt")) {
            try out.append(a, '<');
        } else if (std.mem.eql(u8, name, "gt")) {
            try out.append(a, '>');
        } else if (std.mem.eql(u8, name, "quot")) {
            try out.append(a, '"');
        } else if (std.mem.eql(u8, name, "apos")) {
            try out.append(a, '\'');
        } else if (name.len > 1 and name[0] == '#') {
            const cp = (if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) else std.fmt.parseInt(u21, name[1..], 10)) catch return error.BadXml;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadXml;
            try out.appendSlice(a, buf[0..n]);
        } else return error.BadXml;
        i = end + 1;
    }
    return out.items;
}

const max_depth = 32;
const max_leaves = 200_000;

/// The elements of `text` that hold text and no elements, in the file's
/// order: "Faktura/Fa/P_2" and what is in it. Prefixes of names are left
/// off; attributes are not read.
fn leaves(a: Allocator, text_in: []const u8) ![]Leaf {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text = text[3..];
    var out: std.ArrayList(Leaf) = .empty;
    var stack: [max_depth][]const u8 = undefined;
    var has_child: [max_depth]bool = undefined;
    var depth: usize = 0;
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const lt = std.mem.indexOfScalarPos(u8, text, i, '<') orelse break;
        if (depth > 0) try cur.appendSlice(a, text[i..lt]);
        const rest = text[lt..];
        if (std.mem.startsWith(u8, rest, "<?")) {
            i = lt + 2 + (std.mem.indexOf(u8, rest[2..], "?>") orelse return error.BadXml) + 2;
        } else if (std.mem.startsWith(u8, rest, "<!--")) {
            i = lt + 4 + (std.mem.indexOf(u8, rest[4..], "-->") orelse return error.BadXml) + 3;
        } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const end = std.mem.indexOf(u8, rest[9..], "]]>") orelse return error.BadXml;
            // (kept as written: what is in it is text, never markup)
            if (depth > 0) for (rest[9 .. 9 + end]) |ch| {
                if (ch == '&') try cur.appendSlice(a, "&amp;") else try cur.append(a, ch);
            };
            i = lt + 9 + end + 3;
        } else if (std.mem.startsWith(u8, rest, "<!")) {
            return error.BadXml;
        } else if (std.mem.startsWith(u8, rest, "</")) {
            const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return error.BadXml;
            if (depth == 0) return error.BadXml;
            if (!has_child[depth - 1]) {
                if (out.items.len >= max_leaves) return error.BadXml;
                try out.append(a, .{ .path = try std.mem.join(a, "/", stack[0..depth]), .text = try a.dupe(u8, std.mem.trim(u8, try decodeText(a, cur.items), " \t\r\n")) });
            }
            depth -= 1;
            cur.clearRetainingCapacity();
            i = lt + gt + 1;
        } else {
            // an element opens: its name ends at a space, "/" or ">"; its
            // end is the first ">" outside a quoted attribute
            var j: usize = 1;
            var quote: u8 = 0;
            while (j < rest.len) : (j += 1) {
                const ch = rest[j];
                if (quote != 0) {
                    if (ch == quote) quote = 0;
                } else if (ch == '"' or ch == '\'') {
                    quote = ch;
                } else if (ch == '>') break;
            }
            if (j >= rest.len) return error.BadXml;
            const inner = rest[1..j];
            const closed = inner.len > 0 and inner[inner.len - 1] == '/';
            var name = inner[0 .. std.mem.indexOfAny(u8, inner, " \t\r\n/") orelse inner.len];
            if (std.mem.indexOfScalar(u8, name, ':')) |colon| name = name[colon + 1 ..];
            if (name.len == 0 or depth >= max_depth) return error.BadXml;
            if (depth > 0) has_child[depth - 1] = true;
            stack[depth] = name;
            has_child[depth] = false;
            depth += 1;
            cur.clearRetainingCapacity();
            if (closed) depth -= 1;
            i = lt + j + 1;
        }
    }
    if (depth != 0) return error.BadXml;
    return out.items;
}

/// An account as compared (payrun.accountId): a Polish IBAN as its 26 digits.
pub fn nrb(a: Allocator, v: []const u8) ![]const u8 {
    return payrun.accountId(a, v);
}

/// A Polish tax number in what a file gives as one ("PL 526-000-12-46"): its ten digits, or "".
pub fn nipOf(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (v) |ch| if (std.ascii.isAlphanumeric(ch)) try out.append(a, std.ascii.toUpper(ch));
    var s: []const u8 = out.items;
    if (std.mem.startsWith(u8, s, "PL")) s = s[2..];
    if (s.len != 10) return "";
    for (s) |ch| if (!std.ascii.isDigit(ch)) return "";
    return s;
}

/// One invoice file read. error.NotAnInvoice with `diag.what` when it
/// isn't one this reader knows.
pub fn parse(a: Allocator, text: []const u8, file: []const u8, diag: *Diag) !Invoice {
    const all = leaves(a, text) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return fail(diag, "isn't XML this reader takes (a DOCTYPE is refused)");
    };
    var inv: Invoice = .{ .file = file };
    var accounts: std.ArrayList([]const u8) = .empty;
    var factor: std.ArrayList([]const u8) = .empty;
    var corrects: std.ArrayList([]const u8) = .empty;
    var total_text: []const u8 = "";
    var is_invoice = false;
    for (all) |l| {
        if (!std.mem.startsWith(u8, l.path, "Faktura/")) continue;
        is_invoice = true;
        const p = l.path["Faktura/".len..];
        if (std.mem.eql(u8, p, "Podmiot1/DaneIdentyfikacyjne/NIP")) {
            inv.seller_nip = l.text;
        } else if (std.mem.eql(u8, p, "Podmiot1/DaneIdentyfikacyjne/Nazwa")) {
            inv.seller_name = l.text;
        } else if (std.mem.eql(u8, p, "Podmiot2/DaneIdentyfikacyjne/NIP")) {
            inv.buyer_nip = l.text;
        } else if (std.mem.eql(u8, p, "Fa/KodWaluty")) {
            inv.currency = try std.ascii.allocLowerString(a, l.text);
        } else if (std.mem.eql(u8, p, "Fa/P_1")) {
            inv.date = l.text;
        } else if (std.mem.eql(u8, p, "Fa/P_2")) {
            inv.number = l.text;
        } else if (std.mem.eql(u8, p, "Fa/P_15")) {
            total_text = l.text;
        } else if (std.mem.eql(u8, p, "Fa/RodzajFaktury")) {
            inv.kind = l.text;
        } else if (std.mem.eql(u8, p, "Fa/Platnosc/Zaplacono")) {
            inv.paid = std.mem.eql(u8, l.text, "1");
        } else if (std.mem.eql(u8, p, "Fa/Platnosc/DataZaplaty")) {
            inv.paid_on = l.text;
        } else if (std.mem.eql(u8, p, "Fa/Platnosc/RachunekBankowy/NrRB")) {
            try accounts.append(a, try nrb(a, l.text));
        } else if (std.mem.eql(u8, p, "Fa/Platnosc/RachunekBankowyFaktora/NrRB")) {
            try factor.append(a, try nrb(a, l.text));
        } else if (std.mem.eql(u8, p, "Fa/DaneFaKorygowanej/NrFaKorygowanej")) {
            try corrects.append(a, l.text);
        }
    }
    if (!is_invoice) return fail(diag, "isn't a KSeF invoice (its first element isn't Faktura)");
    if (inv.seller_nip.len == 0) return fail(diag, "names no seller's tax number (Podmiot1, NIP)");
    if (inv.number.len == 0) return fail(diag, "has no invoice number (P_2)");
    // (the layout writes a sum with a point and at most two digits after it)
    if (total_text.len == 0) return fail(diag, "has no sum to pay (P_15)");
    inv.total = sumOf(total_text, inv.currency) orelse return fail(diag, "has a sum to pay (P_15) that can't be read");
    inv.accounts = accounts.items;
    inv.factor_accounts = factor.items;
    inv.corrects = corrects.items;
    return inv;
}

/// "2460", "2460.5", "-123.45" in the currency's smallest unit.
fn sumOf(v: []const u8, currency: []const u8) ?i64 {
    for (v) |ch| if (!std.ascii.isDigit(ch) and ch != '.' and ch != '-') return null;
    if (std.mem.indexOfScalar(u8, v, '.')) |dot| if (v.len - dot - 1 > 2 or v.len - dot - 1 == 0) return null;
    return payrun.amountOf(v, currency);
}

// ---- a batch beside its invoices ----

pub const Compared = struct {
    findings: []audit.Finding = &.{},
    /// Payments whose invoice is among the files.
    matched: usize = 0,
};

fn joined(a: Allocator, list: []const []const u8) ![]const u8 {
    return std.mem.join(a, " and ", list);
}

/// Each payment of `list` set beside its invoice, where one of `invoices`
/// is from the same seller (by tax number, else by name) with the same number.
pub fn compare(a: Allocator, list: []const payrun.Row, invoices: []const Invoice, batch: []const u8) !Compared {
    var out: std.ArrayList(audit.Finding) = .empty;
    var matched: usize = 0;
    for (list) |r| {
        const bill = try payrun.billId(a, r.bill);
        if (bill.len == 0) continue;
        const nip = try nipOf(a, r.id);
        var found: ?Invoice = null;
        var corrections: i64 = 0;
        var correction_names: std.ArrayList([]const u8) = .empty;
        var correction_numbers: std.ArrayList([]const u8) = .empty;
        for (invoices) |inv| {
            const same_seller = (nip.len > 0 and std.mem.eql(u8, nip, inv.seller_nip)) or std.mem.eql(u8, try payrun.nameId(a, inv.seller_name), r.id);
            if (!same_seller) continue;
            if (inv.correction()) {
                for (inv.corrects) |n| if (std.mem.eql(u8, try payrun.billId(a, n), bill) and std.mem.eql(u8, inv.currency, r.currency)) {
                    // (one correction saved twice under two file names counts once)
                    const counted = for (correction_numbers.items) |c| {
                        if (std.mem.eql(u8, c, inv.number)) break true;
                    } else false;
                    if (counted) continue;
                    try correction_numbers.append(a, inv.number);
                    corrections += inv.total;
                    try correction_names.append(a, try std.fmt.allocPrint(a, "{s} ({s}, in {s})", .{ inv.number, try model.money(a, inv.total, inv.currency), inv.file }));
                };
            } else if (found == null and std.mem.eql(u8, try payrun.billId(a, inv.number), bill)) found = inv;
        }
        const inv = found orelse continue;
        matched += 1;
        const src = try std.fmt.allocPrint(a, "{s}, line {d}", .{ batch, r.line });
        const row_text = try std.fmt.allocPrint(a, "{s}, bill {s}, {s}{s}", .{ r.supplier, r.bill, try model.money(a, r.amount, r.currency), if (r.account.len > 0) try std.fmt.allocPrint(a, ", to account {s}", .{r.account}) else "" });
        const inv_text = try std.fmt.allocPrint(a, "invoice {s} of {s}, {s}, seller's tax number {s}{s}{s}", .{
            inv.number,
            inv.date,
            try model.money(a, inv.total, inv.currency),
            inv.seller_nip,
            if (inv.accounts.len > 0) try std.fmt.allocPrint(a, ", to be paid to {s}", .{try joined(a, inv.accounts)}) else ", no account named",
            if (inv.factor_accounts.len > 0) try std.fmt.allocPrint(a, " (a factor's account: {s})", .{try joined(a, inv.factor_accounts)}) else "",
        });

        // the account the batch pays to against the invoice's
        const pays_to = try nrb(a, r.account);
        if (pays_to.len > 0 and inv.accounts.len + inv.factor_accounts.len > 0) {
            const on_invoice = for (inv.accounts) |x| {
                if (std.mem.eql(u8, x, pays_to)) break true;
            } else for (inv.factor_accounts) |x| {
                if (std.mem.eql(u8, x, pays_to)) break true;
            } else false;
            if (!on_invoice) try out.append(a, .{
                .kind = .invoice_account,
                .key = try std.fmt.allocPrint(a, "invoice_account:{s}:{s}:{s}", .{ batch, r.id, bill }),
                .customer = r.id,
                .name = r.supplier,
                .amount = r.amount,
                .currency = r.currency,
                .per = .once,
                .what = try std.fmt.allocPrint(a, "{s} is to be paid {s} to account {s}; invoice {s} as issued through KSeF names {s}.", .{ r.supplier, try model.money(a, r.amount, r.currency), r.account, inv.number, try joined(a, if (inv.accounts.len > 0) inv.accounts else inv.factor_accounts) }),
                .rows = try a.dupe(audit.Row, &.{
                    .{ .source = src, .value = row_text },
                    .{ .source = inv.file, .value = inv_text },
                }),
                .proposal = "The invoice file is what the supplier issued through the tax office's system. An account that differs from it was changed on the way: in your supplier record, in the batch, or by a message asking you to pay elsewhere. Call the supplier on a number you had before, and pay to the invoice's account unless they confirm the other. If they did ask for it (a new bank, a factor), say so (decide ... intended).",
            });
        }

        // an invoice marked as paid when it was issued (cash, a card), about to be paid again
        if (inv.paid) try out.append(a, .{
            .kind = .invoice_paid,
            .key = try std.fmt.allocPrint(a, "invoice_paid:{s}:{s}:{s}", .{ batch, r.id, bill }),
            .customer = r.id,
            .name = r.supplier,
            .amount = r.amount,
            .currency = r.currency,
            .per = .once,
            .what = try std.fmt.allocPrint(a, "{s} is to be paid {s} for invoice {s}; the invoice says it was paid already{s}.", .{ r.supplier, try model.money(a, r.amount, r.currency), inv.number, if (inv.paid_on.len > 0) try std.fmt.allocPrint(a, ", on {s}", .{inv.paid_on}) else "" }),
            .rows = try a.dupe(audit.Row, &.{
                .{ .source = src, .value = row_text },
                .{ .source = inv.file, .value = try std.fmt.allocPrint(a, "{s}; marked as paid{s}", .{ inv_text, if (inv.paid_on.len > 0) try std.fmt.allocPrint(a, " on {s}", .{inv.paid_on}) else "" }) },
            }),
            .proposal = "Look for that payment before paying again: an invoice paid by card or in cash when it was issued is marked so by the seller. If it was not paid and the mark is the seller's mistake, say so (decide ... intended).",
        });

        // the amount against the invoice's sum, less its corrections
        if (std.mem.eql(u8, r.currency, inv.currency)) {
            const owed = inv.total + corrections;
            if (r.amount > owed) {
                var ev: std.ArrayList(audit.Row) = .empty;
                try ev.append(a, .{ .source = src, .value = row_text });
                try ev.append(a, .{ .source = inv.file, .value = inv_text });
                for (correction_names.items) |n| try ev.append(a, .{ .source = "a correction among the files", .value = n });
                try out.append(a, .{
                    .kind = .invoice_amount,
                    .key = try std.fmt.allocPrint(a, "invoice_amount:{s}:{s}:{s}", .{ batch, r.id, bill }),
                    .customer = r.id,
                    .name = r.supplier,
                    .amount = r.amount - owed,
                    .currency = r.currency,
                    .per = .once,
                    .what = if (corrections != 0)
                        try std.fmt.allocPrint(a, "{s} is to be paid {s} for invoice {s}; the invoice is for {s} and its corrections bring it to {s}.", .{ r.supplier, try model.money(a, r.amount, r.currency), inv.number, try model.money(a, inv.total, inv.currency), try model.money(a, owed, inv.currency) })
                    else
                        try std.fmt.allocPrint(a, "{s} is to be paid {s} for invoice {s}; the invoice is for {s}.", .{ r.supplier, try model.money(a, r.amount, r.currency), inv.number, try model.money(a, inv.total, inv.currency) }),
                    .rows = ev.items,
                    .proposal = "Check the amount against the invoice before paying: the batch pays more than was invoiced. If the row pays two invoices at once, say so (decide ... intended).",
                });
            }
        }
    }
    return .{ .findings = out.items, .matched = matched };
}

const t = std.testing;

const sample =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!-- made up, in the FA(3) layout -->
    \\<Faktura xmlns="http://crd.gov.pl/wzor/2025/06/25/13775/">
    \\  <Naglowek><KodFormularza kodSystemowy="FA (3)" wersjaSchemy="1-0E">FA</KodFormularza><WariantFormularza>3</WariantFormularza></Naglowek>
    \\  <Podmiot1><DaneIdentyfikacyjne><NIP>3245174504</NIP><Nazwa>Nordlys Print &amp; Co sp. z o.o.</Nazwa></DaneIdentyfikacyjne></Podmiot1>
    \\  <Podmiot2><DaneIdentyfikacyjne><NIP>1854510877</NIP><Nazwa>Fernhill sp. z o.o.</Nazwa></DaneIdentyfikacyjne></Podmiot2>
    \\  <Fa>
    \\    <KodWaluty>PLN</KodWaluty><P_1>2026-11-03</P_1><P_2>NP/2026/140</P_2>
    \\    <P_13_1>1000</P_13_1><P_14_1>230</P_14_1><P_15>1230.5</P_15>
    \\    <RodzajFaktury>VAT</RodzajFaktury>
    \\    <Platnosc>
    \\      <TerminPlatnosci><Termin>2026-11-17</Termin></TerminPlatnosci>
    \\      <FormaPlatnosci>6</FormaPlatnosci>
    \\      <RachunekBankowy><NrRB>61 1090 1014 0000 0712 1981 2874</NrRB><NazwaBanku>Bank &#x41;</NazwaBanku></RachunekBankowy>
    \\    </Platnosc>
    \\  </Fa>
    \\</Faktura>
    \\
;

test "an_invoice_file_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const inv = try parse(a, sample, "a.xml", &d);
    try t.expectEqualStrings("3245174504", inv.seller_nip);
    try t.expectEqualStrings("Nordlys Print & Co sp. z o.o.", inv.seller_name);
    try t.expectEqualStrings("NP/2026/140", inv.number);
    try t.expectEqualStrings("pln", inv.currency);
    try t.expectEqual(@as(i64, 123050), inv.total);
    try t.expectEqual(@as(usize, 1), inv.accounts.len);
    try t.expectEqualStrings("61109010140000071219812874", inv.accounts[0]);
    try t.expect(!inv.paid and !inv.correction());
    // a prefix on every name reads the same
    const prefixed = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, sample, "</", "</tns:"), "<", "<tns:");
    const fixed = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, prefixed, "<tns:/tns:", "</tns:"), "<tns:?xml", "<?xml"), "<tns:!--", "<!--");
    const inv2 = try parse(a, fixed, "b.xml", &d);
    try t.expectEqualStrings("NP/2026/140", inv2.number);
    try t.expectEqual(@as(i64, 123050), inv2.total);
    // what isn't an invoice says what it lacks, and a DOCTYPE is refused
    try t.expectError(error.NotAnInvoice, parse(a, "<Order><No>1</No></Order>", "c.xml", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "isn't a KSeF invoice") != null);
    try t.expectError(error.NotAnInvoice, parse(a, "<!DOCTYPE x [<!ENTITY e \"1\">]><Faktura><Fa><P_2>&e;</P_2></Fa></Faktura>", "d.xml", &d));
    try t.expectError(error.NotAnInvoice, parse(a, "<Faktura><Fa><P_2>1</P_2></Fa>", "e.xml", &d));
    try t.expectError(error.NotAnInvoice, parse(a, "<Faktura><Podmiot1><DaneIdentyfikacyjne><NIP>1</NIP></DaneIdentyfikacyjne></Podmiot1><Fa><P_2>1</P_2><P_15>12.345</P_15></Fa></Faktura>", "f.xml", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "can't be read") != null);
    try t.expectEqualStrings("5260001246", try nipOf(a, "PL 526-000-12-46"));
    try t.expectEqualStrings("", try nipOf(a, "DE811907980"));
}

test "a_batch_beside_its_invoices" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const inv = try parse(a, sample, "NP-2026-140.xml", &d);
    const kor = try parse(a, "<Faktura><Podmiot1><DaneIdentyfikacyjne><NIP>3245174504</NIP><Nazwa>Nordlys Print</Nazwa></DaneIdentyfikacyjne></Podmiot1><Fa><KodWaluty>PLN</KodWaluty><P_1>2026-11-10</P_1><P_2>NP/2026/K7</P_2><P_15>-230.50</P_15><RodzajFaktury>KOR</RodzajFaktury><DaneFaKorygowanej><DataWystFaKorygowanej>2026-11-03</DataWystFaKorygowanej><NrFaKorygowanej>NP/2026/140</NrFaKorygowanej></DaneFaKorygowanej></Fa></Faktura>", "NP-2026-K7.xml", &d);
    try t.expect(kor.correction());
    try t.expectEqual(@as(i64, -23050), kor.total);
    var pd: payrun.Diag = .{};
    const list = try payrun.rows(a,
        \\supplier,tax_id,bill,amount,currency,account
        \\Nordlys Print,PL3245174504,NP/2026/140,"1230,50",PLN,PL61 1090 1014 0000 0712 1981 2874
        \\Nordlys Print,PL3245174504,NP/2026/140,"1230,50",PLN,PL44 1140 2004 0000 3102 7654 3210
        \\Somebody Else,,X-1,10.00,PLN,PL44 1140 2004 0000 3102 7654 3210
        \\
    , .{ .currency = "pln" }, &pd);
    // the invoice alone: the first row is as invoiced, the second pays to another account
    const one = try compare(a, list, &.{inv}, "run.csv");
    try t.expectEqual(@as(usize, 2), one.matched);
    try t.expectEqual(@as(usize, 1), one.findings.len);
    try t.expect(one.findings[0].kind == .invoice_account);
    try t.expectEqualStrings("invoice_account:run.csv:3245174504:np2026140", one.findings[0].key);
    try t.expect(std.mem.indexOf(u8, one.findings[0].what, "to account 44114020040000310276543210; invoice NP/2026/140 as issued through KSeF names 61109010140000071219812874.") != null);
    // with its correction among the files, both rows pay more than is owed
    const two = try compare(a, list, &.{ inv, kor, kor }, "run.csv");
    try t.expectEqual(@as(usize, 3), two.findings.len);
    var over: ?audit.Finding = null;
    for (two.findings) |f| if (f.kind == .invoice_amount) {
        over = f;
    };
    try t.expectEqual(@as(i64, 23050), over.?.amount);
    // an invoice the seller marked as paid when issuing it
    const cash = try parse(a, "<Faktura><Podmiot1><DaneIdentyfikacyjne><NIP>3245174504</NIP><Nazwa>Nordlys Print</Nazwa></DaneIdentyfikacyjne></Podmiot1><Fa><KodWaluty>PLN</KodWaluty><P_1>2026-11-03</P_1><P_2>NP/2026/140</P_2><P_15>1230.50</P_15><RodzajFaktury>VAT</RodzajFaktury><Platnosc><Zaplacono>1</Zaplacono><DataZaplaty>2026-11-03</DataZaplaty><FormaPlatnosci>2</FormaPlatnosci></Platnosc></Fa></Faktura>", "paid.xml", &d);
    try t.expect(cash.paid);
    const again = try compare(a, list[0..1], &.{cash}, "run.csv");
    try t.expectEqual(@as(usize, 1), again.findings.len);
    try t.expect(again.findings[0].kind == .invoice_paid);
    try t.expectEqualStrings("Nordlys Print is to be paid 1230.50 PLN for invoice NP/2026/140; the invoice says it was paid already, on 2026-11-03.", again.findings[0].what);
    try t.expect(std.mem.indexOf(u8, over.?.what, "the invoice is for 1230.50 PLN and its corrections bring it to 1000.00 PLN") != null);
}

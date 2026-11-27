//! The stand-in's part for the books: a made-up business's suppliers,
//! bills awaiting payment and payments on bills, answered in the shapes
//! of Xero's accounting API as documented (read 2026-11-27): a token for
//! an app's id and secret, lists in pages with their count, dates as
//! "/Date(ms+0000)/", amounts as strings on bills and as numbers on
//! payments. A request that doesn't ask for JSON gets XML, as there.
//!
//! What is in it: one bill whose number was paid before, one far above
//! anything its supplier was paid, and a supplier whose bank details are
//! different from the second token on (so that two readings show a change).
const std = @import("std");
const Allocator = std.mem.Allocator;
const sim = @import("sim.zig");

pub const client_id = "xero_sim_app";
const token = "xero_sim_token";
const day_s: i64 = 86400;
/// Items a page (the real API: 100).
const page_size = 3;

pub fn handles(req: sim.Req) bool {
    return std.mem.eql(u8, req.path, "/connect/token") or std.mem.startsWith(u8, req.path, "/api.xro/2.0/");
}

fn res(a: Allocator, status: u16, comptime fmt: []const u8, args: anytype) !sim.Res {
    return .{ .status = status, .body = try std.fmt.allocPrint(a, fmt, args) };
}

fn date(a: Allocator, now: i64, days_ago: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "\\/Date({d}+0000)\\/", .{(@divFloor(now, day_s) * day_s - days_ago * day_s) * 1000});
}

const Contact = struct { id: []const u8, name: []const u8, tax: []const u8 = "", account: []const u8 = "", supplier: bool = true, status: []const u8 = "ACTIVE" };

fn contacts(changed: bool) [6]Contact {
    return .{
        .{ .id = "c-nordlys", .name = "Nordlys Print", .tax = "PL5260001246", .account = if (changed) "PL44 1140 2004 0000 3102 7654 3210" else "PL61 1090 1014 0000 0712 1981 2874" },
        .{ .id = "c-kestrel", .name = "Kestrel Hosting", .account = "DE89 3704 0044 0532 0130 00" },
        .{ .id = "c-mirela", .name = "Mirela Cleaning", .account = "PL27114020040000300201355387" },
        .{ .id = "c-juniper", .name = "Juniper Ltd", .supplier = false },
        .{ .id = "c-quillon", .name = "Quillon Supplies" },
        .{ .id = "c-old", .name = "Old Supplier", .account = "DE02120300000000202051", .status = "ARCHIVED" },
    };
}

const Bill = struct { contact: usize, number: []const u8, due: []const u8, in_days: i64 };
const bills = [_]Bill{
    .{ .contact = 0, .number = "NP/2026/140", .due = "1230.00", .in_days = 3 },
    .{ .contact = 1, .number = "KH-5604", .due = "149.00", .in_days = 3 },
    .{ .contact = 1, .number = "KH-5699", .due = "1490.00", .in_days = 5 },
    .{ .contact = 2, .number = "11/2026", .due = "300.00", .in_days = 7 },
};

const Paid = struct { contact: usize, number: []const u8, amount: []const u8, days_ago: i64 };
const payments = [_]Paid{
    .{ .contact = 0, .number = "NP/2026/101", .amount = "1230.00", .days_ago = 110 },
    .{ .contact = 0, .number = "NP/2026/118", .amount = "1230.00", .days_ago = 80 },
    .{ .contact = 0, .number = "NP/2026/131", .amount = "984.00", .days_ago = 50 },
    .{ .contact = 1, .number = "KH-5521", .amount = "149.00", .days_ago = 95 },
    .{ .contact = 1, .number = "KH-5560", .amount = "149.00", .days_ago = 65 },
    .{ .contact = 1, .number = "KH-5604", .amount = "149.00", .days_ago = 35 },
    .{ .contact = 2, .number = "9/2026", .amount = "300.00", .days_ago = 70 },
    .{ .contact = 2, .number = "10/2026", .amount = "300.00", .days_ago = 40 },
};

/// `tokens`: how many tokens were given out so far (the caller counts).
pub fn handle(a: Allocator, secret: []const u8, now: i64, tokens: *u32, req: sim.Req) !sim.Res {
    if (std.mem.eql(u8, req.path, "/connect/token")) {
        if (!std.mem.eql(u8, req.method, "POST")) return res(a, 405, "{{\"error\":\"invalid_request\"}}", .{});
        const enc = std.base64.standard.Encoder;
        const pair = try std.fmt.allocPrint(a, "{s}:{s}", .{ client_id, secret });
        const want = try std.fmt.allocPrint(a, "Basic {s}", .{enc.encode(try a.alloc(u8, enc.calcSize(pair.len)), pair)});
        if (!std.mem.eql(u8, req.auth, want)) return res(a, 400, "{{\"error\":\"invalid_client\"}}", .{});
        if (std.mem.indexOf(u8, req.body, "grant_type=client_credentials") == null) return res(a, 400, "{{\"error\":\"unsupported_grant_type\"}}", .{});
        if (std.mem.indexOf(u8, req.body, "accounting.contacts.read") == null) return res(a, 400, "{{\"error\":\"invalid_scope\"}}", .{});
        tokens.* += 1;
        return res(a, 200, "{{\"access_token\":\"{s}\",\"expires_in\":1800,\"token_type\":\"Bearer\",\"scope\":\"accounting.contacts.read accounting.invoices.read accounting.payments.read\"}}", .{token});
    }
    if (!std.mem.startsWith(u8, req.auth, "Bearer ") or !std.mem.eql(u8, req.auth[7..], token))
        return res(a, 401, "{{\"Type\":null,\"Title\":\"Unauthorized\",\"Status\":401,\"Detail\":\"AuthenticationUnsuccessful\"}}", .{});
    if (!std.mem.eql(u8, req.method, "GET")) return res(a, 403, "{{\"Type\":null,\"Title\":\"Forbidden\",\"Status\":403,\"Detail\":\"The stand-in's token only reads.\"}}", .{});
    // (without "Accept: application/json" the API answers XML)
    if (std.mem.indexOf(u8, req.header("accept"), "application/json") == null or std.mem.indexOf(u8, req.header("accept"), "*/*") != null)
        return .{ .status = 200, .body = "<Response><Status>OK</Status></Response>" };
    const page_n = std.fmt.parseInt(usize, try sim.param(a, req.query, "page"), 10) catch 1;
    const where = try sim.param(a, req.query, "where");
    const what = req.path["/api.xro/2.0/".len..];
    const all = contacts(tokens.* >= 2);
    var o: std.ArrayList(u8) = .empty;
    var total: usize = 0;
    const from = (@max(page_n, 1) - 1) * page_size;
    if (std.mem.eql(u8, what, "Contacts")) {
        try o.appendSlice(a, "{\"Contacts\":[");
        total = all.len;
        for (all, 0..) |c, i| {
            if (i < from or i >= from + page_size) continue;
            if (i > from) try o.append(a, ',');
            try o.print(a, "{{\"ContactID\":\"{s}\",\"ContactStatus\":\"{s}\",\"Name\":{f},\"EmailAddress\":\"\"{s}{s},\"Phones\":[{{\"PhoneType\":\"DEFAULT\",\"PhoneNumber\":\"{s}\",\"PhoneAreaCode\":\"22\",\"PhoneCountryCode\":\"48\"}},{{\"PhoneType\":\"FAX\"}}],\"UpdatedDateUTC\":\"{s}\",\"IsSupplier\":{},\"IsCustomer\":{}}}", .{
                c.id,
                c.status,
                std.json.fmt(c.name, .{}),
                if (c.account.len > 0) try std.fmt.allocPrint(a, ",\"BankAccountDetails\":\"{s}\"", .{c.account}) else "",
                if (c.tax.len > 0) try std.fmt.allocPrint(a, ",\"TaxNumber\":\"{s}\"", .{c.tax}) else "",
                if (i == 0) "5550101" else "",
                try date(a, now, if (i == 0 and tokens.* >= 2) 0 else 200),
                c.supplier,
                !c.supplier,
            });
        }
    } else if (std.mem.eql(u8, what, "Invoices")) {
        if (std.mem.indexOf(u8, where, "Type==\"ACCPAY\"") == null or std.mem.indexOf(u8, where, "Status==\"AUTHORISED\"") == null) return res(a, 400, "{{\"Type\":\"QueryParseException\",\"Message\":\"The stand-in lists bills awaiting payment only: where=Type==\\\"ACCPAY\\\" AND Status==\\\"AUTHORISED\\\"\"}}", .{});
        try o.appendSlice(a, "{\"Invoices\":[");
        total = bills.len;
        for (bills, 0..) |b, i| {
            if (i < from or i >= from + page_size) continue;
            if (i > from) try o.append(a, ',');
            try o.print(a, "{{\"Type\":\"ACCPAY\",\"InvoiceID\":\"inv-{d}\",\"InvoiceNumber\":\"{s}\",\"Contact\":{{\"ContactID\":\"{s}\",\"Name\":{f}}},\"Date\":\"{s}\",\"DueDate\":\"{s}\",\"Status\":\"AUTHORISED\",\"SubTotal\":\"{s}\",\"TotalTax\":\"0.00\",\"Total\":\"{s}\",\"AmountDue\":\"{s}\",\"AmountPaid\":\"0.00\",\"CurrencyCode\":\"EUR\"}}", .{ i, b.number, all[b.contact].id, std.json.fmt(all[b.contact].name, .{}), try date(a, now, 20), try date(a, now, -b.in_days), b.due, b.due, b.due });
        }
    } else if (std.mem.eql(u8, what, "Payments")) {
        if (std.mem.indexOf(u8, where, "PaymentType==\"ACCPAYPAYMENT\"") == null or std.mem.indexOf(u8, where, "Date>=DateTime(") == null) return res(a, 400, "{{\"Type\":\"QueryParseException\",\"Message\":\"The stand-in lists payments on bills since a day only.\"}}", .{});
        try o.appendSlice(a, "{\"Payments\":[");
        total = payments.len;
        for (payments, 0..) |p, i| {
            if (i < from or i >= from + page_size) continue;
            if (i > from) try o.append(a, ',');
            try o.print(a, "{{\"PaymentID\":\"pay-{d}\",\"Date\":\"{s}\",\"BankAmount\":{s},\"Amount\":{s},\"Reference\":\"\",\"PaymentType\":\"ACCPAYPAYMENT\",\"Status\":\"AUTHORISED\",\"HasAccount\":true,\"Account\":{{\"AccountID\":\"acc-1\",\"Code\":\"090\"}},\"Invoice\":{{\"Type\":\"ACCPAY\",\"InvoiceID\":\"old-{d}\",\"InvoiceNumber\":\"{s}\",\"Payments\":[],\"Contact\":{{\"ContactID\":\"{s}\",\"Name\":{f},\"Phones\":[]}},\"LineItems\":[],\"CurrencyCode\":\"EUR\"}}}}", .{ i, try date(a, now, p.days_ago), p.amount, p.amount, i, p.number, all[p.contact].id, std.json.fmt(all[p.contact].name, .{}) });
        }
    } else return res(a, 404, "{{\"Type\":null,\"Title\":\"Not Found\",\"Status\":404}}", .{});
    try o.print(a, "],\"pagination\":{{\"page\":{d},\"pageSize\":{d},\"pageCount\":{d},\"itemCount\":{d}}}}}", .{ page_n, page_size, (total + page_size - 1) / page_size, total });
    return .{ .status = 200, .body = o.items };
}

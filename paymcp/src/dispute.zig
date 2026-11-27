//! The answer to a card dispute, as far as the account already shows it:
//! the fields of the provider's evidence form that fixed rules can fill
//! from what was read, and a list of what only the business has. A draft
//! for a person: nothing here sends anything, and sending is final.
const std = @import("std");
const Allocator = std.mem.Allocator;
const audit = @import("audit.zig");
const model = @import("model.zig");

/// One field of the provider's evidence form, by the provider's name for it.
pub const Field = struct { name: []const u8, value: []const u8 };

pub const Evidence = struct {
    fields: []const Field,
    /// What the bank wants that isn't in the account: for a person to add.
    missing: []const []const u8,
};

/// The dispute a finding's key names ("dispute:du_..."), in this reading.
pub fn find(d: audit.Data, key: []const u8) ?model.Dispute {
    const prefix = "dispute:";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    for (d.disputes) |dp| if (std.mem.eql(u8, dp.id, key[prefix.len..])) return dp;
    return null;
}

fn missingFor(reason: []const u8) []const []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, reason, "fraudulent")) return &.{
        "access_activity_log: logins to the account or use of it by this customer, with dates and addresses (IP)",
        "customer_purchase_ip: the address (IP) the purchase came from",
        "customer_communication (a file): any exchange with the customer about the purchase",
    };
    if (eql(u8, reason, "product_not_received")) return &.{
        "access_activity_log: when the account was used after the payment",
        "service_documentation (a file): what was delivered, and when",
        "customer_communication (a file): any exchange with the customer about it",
    };
    if (eql(u8, reason, "product_unacceptable")) return &.{
        "product_description: what was promised, as the customer saw it when buying",
        "service_documentation (a file): what was delivered",
        "customer_communication (a file): the complaint, if there was one, and your reply",
    };
    if (eql(u8, reason, "subscription_canceled")) return &.{
        "cancellation_policy_disclosure: where and how your cancellation terms were shown before the purchase",
        "cancellation_rebuttal: why a cancellation, if one came, doesn't cover this payment",
        "access_activity_log: use of the account after the day the customer says it was cancelled",
    };
    if (eql(u8, reason, "duplicate")) return &.{
        "duplicate_charge_id: the other payment",
        "duplicate_charge_explanation: what each of the two payments was for",
    };
    if (eql(u8, reason, "credit_not_processed")) return &.{
        "refund_policy_disclosure: where and how your refund terms were shown before the purchase",
        "refund_refusal_explanation: why no refund was due",
    };
    return &.{
        "product_description: what was sold, in a sentence or two",
        "customer_communication (a file): any exchange with the customer about the payment",
    };
}

pub fn evidence(a: Allocator, d: audit.Data, dp: model.Dispute) !Evidence {
    var fields: std.ArrayList(Field) = .empty;
    var name: []const u8 = dp.payer_name;
    var email: []const u8 = dp.payer_email;
    for (d.customers) |cu| if (dp.customer.len > 0 and std.mem.eql(u8, cu.id, dp.customer)) {
        if (cu.name.len > 0) name = cu.name;
        if (cu.email.len > 0) email = cu.email;
    };
    if (name.len > 0) try fields.append(a, .{ .name = "customer_name", .value = name });
    if (email.len > 0) try fields.append(a, .{ .name = "customer_email_address", .value = email });
    if (dp.payer_address.len > 0) try fields.append(a, .{ .name = "billing_address", .value = dp.payer_address });
    if (dp.charge_known and dp.charged > 0) try fields.append(a, .{ .name = "service_date", .value = try model.day(a, dp.charged) });
    if (dp.description.len > 0) try fields.append(a, .{ .name = "product_description", .value = dp.description });
    // only what was read: nothing here says a thing was delivered or used
    var said: std.ArrayList(u8) = .empty;
    if (dp.charge_known and dp.charged > 0) {
        try said.print(a, "The payment of {s} on {s} was made by {s}", .{ try model.money(a, dp.amount, dp.currency), try model.day(a, dp.charged), if (name.len > 0) name else "the cardholder" });
        if (dp.customer.len > 0) try said.print(a, ", who is a customer of ours (account {s})", .{dp.customer});
        try said.appendSlice(a, ".");
    }
    for (d.earlier) |e| if (std.mem.eql(u8, e.customer, dp.customer) and e.paid > 0) {
        try said.print(a, "{s}Before it, the same customer made {d} payment{s} to us, the first on {s}; none of them was disputed or refunded.", .{ if (said.items.len > 0) " " else "", e.paid, if (e.paid == 1) "" else "s", try model.day(a, e.first) });
    };
    if (said.items.len > 0) try fields.append(a, .{ .name = "uncategorized_text", .value = said.items });
    var missing: std.ArrayList([]const u8) = .empty;
    for (missingFor(dp.reason)) |m| {
        // (a field already filled isn't missing)
        const colon = std.mem.indexOfScalar(u8, m, ':') orelse m.len;
        for (fields.items) |f| {
            if (std.mem.eql(u8, f.name, m[0..colon])) break;
        } else try missing.append(a, m);
    }
    return .{ .fields = fields.items, .missing = missing.items };
}

/// Control characters become spaces: a name from the provider can't add
/// a line to the draft.
fn flat(a: Allocator, v: []const u8) ![]const u8 {
    const out = try a.dupe(u8, v);
    for (out) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
        ch.* = ' ';
    };
    return out;
}

/// The draft as a person reads it.
pub fn text(a: Allocator, d: audit.Data, dp: model.Dispute, now: i64) ![]const u8 {
    const ev = try evidence(a, d, dp);
    const why = audit.reasonOf(dp.reason);
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "Evidence for dispute {s}, as a draft. Nothing was sent to the provider or the bank: sending is final, and yours to do at the provider.\n", .{try flat(a, dp.id)});
    try o.print(a, "About: a payment of {s} from {s}; {s}.\n", .{ try model.money(a, dp.amount, dp.currency), try flat(a, audit.payerOf(d, dp)), why.says });
    if (dp.due_by) |due| {
        if (!dp.past_due and due > now) {
            const days = @divFloor(due - now, 86400);
            try o.print(a, "To be answered by {s}, {d} day{s} from now.\n", .{ try model.day(a, due), days, if (days == 1) "" else "s" });
        } else try o.print(a, "The time to answer ended on {s}: nothing more can be sent.\n", .{try model.day(a, due)});
    }
    if (dp.has_evidence) try o.appendSlice(a, "Evidence is already kept at the provider for this dispute: look at it there before adding to it.\n");
    if (dp.submissions > 0) try o.print(a, "Evidence was already sent to the bank {d} time{s}: a second answer is seldom taken.\n", .{ dp.submissions, if (dp.submissions == 1) "" else "s" });
    try o.print(a, "\nThe bank wants to see {s}.\n", .{why.wants});
    try o.appendSlice(a, "\nWhat the account already shows (the provider's field, then its text):\n");
    if (ev.fields.len == 0) try o.appendSlice(a, "  nothing: the payment's details didn't come with the dispute.\n");
    for (ev.fields) |f| try o.print(a, "  {s}: {s}\n", .{ f.name, try flat(a, f.value) });
    try o.appendSlice(a, "\nWhat only you have (add it at the provider, as text or as files):\n");
    for (ev.missing) |m| try o.print(a, "  - {s}\n", .{m});
    try o.appendSlice(a, "\nOnly say what is true and what you can show: this draft says nothing about delivery or use, because the billing account doesn't know them.\n");
    return o.items;
}

const t = std.testing;

test "what_the_account_shows_and_what_only_the_business_has" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1795392000; // 2026-11-23
    const dp: model.Dispute = .{ .id = "du_1", .charge = "ch_1", .customer = "cus_b", .amount = 4800, .currency = "eur", .reason = "product_not_received", .status = "needs_response", .created = now - 5 * 86400, .due_by = now + 9 * 86400, .charge_known = true, .charged = now - 17 * 86400, .description = "Team plan", .payer_name = "Ola Birch\nSubmit this now", .payer_email = "ola@birch.example", .payer_address = "1 Harbour Street, 80-001, Gdansk, PL" };
    const d: audit.Data = .{ .customers = &.{.{ .id = "cus_b", .name = "Birch Studio", .email = "pay@birch.example" }}, .disputes = &.{dp}, .earlier = &.{.{ .customer = "cus_b", .paid = 6, .first = now - 197 * 86400 }} };
    try t.expect(find(d, "dispute:du_1") != null);
    try t.expect(find(d, "dispute:du_2") == null and find(d, "free:du_1") == null);
    const ev = try evidence(a, d, dp);
    // the customer as billing names them, over the card's
    try t.expectEqualStrings("customer_name", ev.fields[0].name);
    try t.expectEqualStrings("Birch Studio", ev.fields[0].value);
    try t.expectEqualStrings("pay@birch.example", ev.fields[1].value);
    try t.expectEqualStrings("service_date", ev.fields[3].name);
    try t.expectEqualStrings("2026-11-06", ev.fields[3].value);
    try t.expectEqualStrings("The payment of 48.00 EUR on 2026-11-06 was made by Birch Studio, who is a customer of ours (account cus_b). Before it, the same customer made 6 payments to us, the first on 2026-05-10; none of them was disputed or refunded.", ev.fields[5].value);
    try t.expectEqual(@as(usize, 3), ev.missing.len);
    const out = try text(a, d, dp, now);
    try t.expect(std.mem.startsWith(u8, out, "Evidence for dispute du_1, as a draft. Nothing was sent to the provider or the bank: sending is final, and yours to do at the provider.\nAbout: a payment of 48.00 EUR from Birch Studio; the cardholder says nothing was received.\nTo be answered by 2026-12-02, 9 days from now.\n"));
    try t.expect(std.mem.indexOf(u8, out, "  product_description: Team plan\n") != null);
    try t.expect(std.mem.indexOf(u8, out, "  - access_activity_log: when the account was used after the payment\n") != null);
    // a field the account fills isn't asked of the person again
    const general = try evidence(a, d, .{ .id = "du_3", .reason = "general", .description = "Team plan", .charge_known = true });
    try t.expectEqual(@as(usize, 1), general.missing.len);
    // nothing known of the payment: said, and nothing made up
    const bare = try text(a, .{}, .{ .id = "du_9", .amount = 100, .currency = "eur", .reason = "fraudulent", .due_by = now - 86400, .past_due = true, .submissions = 1 }, now);
    try t.expect(std.mem.indexOf(u8, bare, "  nothing: the payment's details didn't come with the dispute.\n") != null);
    try t.expect(std.mem.indexOf(u8, bare, "The time to answer ended on 2026-11-22: nothing more can be sent.\n") != null);
    try t.expect(std.mem.indexOf(u8, bare, "Evidence was already sent to the bank 1 time") != null);
}

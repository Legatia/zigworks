//! The few things paymcp can change at the billing provider, one at a
//! time, and only when the pay file allows changes, a second key is given
//! and a person has said so (in harness: the gate asks every time).
//!
//! Each change reads the record first and stops if it is no longer as the
//! finding said; then sends one POST (with an idempotency key, so that a
//! request sent twice is made once); then reads the record back and says
//! what the provider now shows. Each is for from now on: nothing here
//! charges for time already invoiced, takes a payment, refunds, deletes,
//! or sends evidence to a bank.
const std = @import("std");
const Allocator = std.mem.Allocator;
const stripe = @import("stripe.zig");
const audit = @import("audit.zig");
const model = @import("model.zig");
const dispute = @import("dispute.zig");
const jv = @import("jv.zig");

pub const Outcome = struct {
    /// The change was made (and seen at the provider afterwards).
    done: bool,
    /// What happened, for a person.
    text: []const u8,
    /// For the record: a few words.
    note: []const u8 = "",
};

fn stopped(a: Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .done = false, .text = try std.fmt.allocPrint(a, "Nothing was changed: " ++ fmt, args) };
}

/// The provider's own sentence, when a request failed before anything
/// was sent or was refused.
fn failed(a: Allocator, c: *stripe.Client) !Outcome {
    return stopped(a, "{s}.", .{c.why});
}

/// After a POST the provider took: reading back failed, so what it shows
/// now isn't known here.
fn unseen(a: Allocator, c: *stripe.Client, what: []const u8) !Outcome {
    return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "The provider took the change ({s}), and reading it back failed: {s}. Look at it at the provider.", .{ what, c.why }) };
}

fn idem(a: Allocator, key: []const u8, now: i64, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "paymcp-{d}-{d}-", .{ now, n });
    for (key) |ch| {
        if (out.items.len >= 200) break;
        try out.append(a, if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '.');
    }
    return out.items;
}

/// Does what finding `f` says paymcp can do (`f.change`), at time `now`.
pub fn apply(a: Allocator, c: *stripe.Client, f: audit.Finding, now: i64) !Outcome {
    const ch = f.change orelse return stopped(a, "there is nothing paymcp can do about {s}: what is proposed is for a person.", .{f.key});
    switch (ch) {
        .end_discount => |x| {
            const path = try std.fmt.allocPrint(a, "/v1/subscriptions/{s}", .{x.subscription});
            const before = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            var keep: std.ArrayList([2][]const u8) = .empty;
            var found = false;
            for (jv.arr(jv.get(before, "discounts")) orelse &.{}) |dv| {
                const id = jv.str(dv) orelse jv.str(jv.get(dv, "id")) orelse "";
                if (std.mem.eql(u8, id, x.discount)) {
                    found = true;
                } else try keep.append(a, .{ try std.fmt.allocPrint(a, "discounts[{d}][discount]", .{keep.items.len}), id });
            }
            if (!found) return stopped(a, "subscription {s} no longer has the discount {s}. Read the account again.", .{ x.subscription, x.discount });
            // (an empty array would leave them as they are: "" clears them)
            if (keep.items.len == 0) try keep.append(a, .{ "discounts", "" });
            _ = c.post(a, path, keep.items, try idem(a, f.key, now, 0)) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const what = try std.fmt.allocPrint(a, "ended discount {s} on subscription {s}", .{ x.discount, x.subscription });
            const after = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else unseen(a, c, what);
            for (jv.arr(jv.get(after, "discounts")) orelse &.{}) |dv| {
                const id = jv.str(dv) orelse jv.str(jv.get(dv, "id")) orelse "";
                if (std.mem.eql(u8, id, x.discount)) return .{ .done = false, .text = try std.fmt.allocPrint(a, "The provider answered the change without an error, and subscription {s} still shows the discount {s}. Look at it at the provider.", .{ x.subscription, x.discount }) };
            }
            return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Done: subscription {s} no longer has the discount {s}. Its next invoice is for the full price; nothing was charged now.", .{ x.subscription, x.discount }) };
        },
        .set_quantity => |x| {
            const path = try std.fmt.allocPrint(a, "/v1/subscription_items/{s}", .{x.item});
            const before = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const has = jv.int(jv.get(before, "quantity")) orelse 1;
            if (has != x.was) return stopped(a, "subscription item {s} now has the quantity {d}, not {d} as when it was found. Read the account again.", .{ x.item, has, x.was });
            _ = c.post(a, path, &.{ .{ "quantity", try std.fmt.allocPrint(a, "{d}", .{x.to}) }, .{ "proration_behavior", "none" } }, try idem(a, f.key, now, 0)) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const what = try std.fmt.allocPrint(a, "set the quantity of {s} from {d} to {d}", .{ x.item, x.was, x.to });
            const after = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else unseen(a, c, what);
            const now_has = jv.int(jv.get(after, "quantity")) orelse 1;
            if (now_has != x.to) return .{ .done = false, .text = try std.fmt.allocPrint(a, "The provider answered the change without an error, and subscription item {s} shows the quantity {d}, not {d}. Look at it at the provider.", .{ x.item, now_has, x.to }) };
            return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Done: subscription item {s} has the quantity {d} (it was {d}). Its next invoice is for {d}; nothing was charged for the time already invoiced.", .{ x.item, x.to, x.was, x.to }) };
        },
        .set_price => |x| {
            const path = try std.fmt.allocPrint(a, "/v1/subscription_items/{s}", .{x.item});
            const before = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const has = jv.str(jv.at(before, &.{ "price", "id" })) orelse "";
            if (!std.mem.eql(u8, has, x.was)) return stopped(a, "subscription item {s} is now on the price {s}, not {s} as when it was found. Read the account again.", .{ x.item, has, x.was });
            var fields: std.ArrayList([2][]const u8) = .empty;
            try fields.append(a, .{ "price", x.to });
            // (a new price alone would set the quantity to 1)
            if (jv.int(jv.get(before, "quantity"))) |q| try fields.append(a, .{ "quantity", try std.fmt.allocPrint(a, "{d}", .{q}) });
            try fields.append(a, .{ "proration_behavior", "none" });
            _ = c.post(a, path, fields.items, try idem(a, f.key, now, 0)) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const what = try std.fmt.allocPrint(a, "moved {s} from price {s} to {s}", .{ x.item, x.was, x.to });
            const after = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else unseen(a, c, what);
            const now_on = jv.str(jv.at(after, &.{ "price", "id" })) orelse "";
            if (!std.mem.eql(u8, now_on, x.to) or jv.int(jv.get(after, "quantity")) != jv.int(jv.get(before, "quantity")))
                return .{ .done = false, .text = try std.fmt.allocPrint(a, "The provider answered the change without an error, and subscription item {s} doesn't show the price {s} with its quantity as before. Look at it at the provider.", .{ x.item, x.to }) };
            return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Done: subscription item {s} is on the price {s} (it was {s}), with its quantity as before. Its next invoice is at the new price; nothing was charged for the time already invoiced.", .{ x.item, x.to, x.was }) };
        },
        .unpause => |x| {
            const path = try std.fmt.allocPrint(a, "/v1/subscriptions/{s}", .{x.subscription});
            const before = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const paused = jv.get(before, "pause_collection");
            if (paused == null or paused.? == .null) return stopped(a, "collection on subscription {s} is no longer paused. Read the account again.", .{x.subscription});
            _ = c.post(a, path, &.{.{ "pause_collection", "" }}, try idem(a, f.key, now, 0)) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const what = try std.fmt.allocPrint(a, "resumed collection on subscription {s}", .{x.subscription});
            const after = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else unseen(a, c, what);
            const still = jv.get(after, "pause_collection");
            if (still != null and still.? != .null) return .{ .done = false, .text = try std.fmt.allocPrint(a, "The provider answered the change without an error, and subscription {s} still shows collection paused. Look at it at the provider.", .{x.subscription}) };
            return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Done: collection on subscription {s} is no longer paused. Its next invoice is collected again; invoices made while it was paused stay as they are.", .{x.subscription}) };
        },
        .finalize => |x| {
            const path = try std.fmt.allocPrint(a, "/v1/invoices/{s}", .{x.invoice});
            const before = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            const inv = model.invoice(before);
            if (inv.status != .draft) return stopped(a, "invoice {s} is no longer a draft (it is {s}). Read the account again.", .{ x.invoice, @tagName(inv.status) });
            if (inv.total != f.amount) return stopped(a, "invoice {s} is now for {s}, not {s} as when it was found. Read the account again.", .{ x.invoice, try model.money(a, inv.total, inv.currency), try model.money(a, f.amount, f.currency) });
            if (inv.collects_itself == x.by_hand) return stopped(a, "how invoice {s} is collected has changed since it was found. Read the account again.", .{x.invoice});
            _ = c.post(a, try std.fmt.allocPrint(a, "{s}/finalize", .{path}), &.{.{ "auto_advance", "true" }}, try idem(a, f.key, now, 0)) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
            var what = try std.fmt.allocPrint(a, "finalised invoice {s}", .{x.invoice});
            var sent_note: []const u8 = "The provider now charges the payment method on file by itself. If the customer has none, or it is refused, the invoice stays open and a later reading says so.";
            if (x.by_hand) {
                _ = c.post(a, try std.fmt.allocPrint(a, "{s}/send", .{path}), &.{}, try idem(a, f.key, now, 1)) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Invoice {s} is finalised, and sending it to the customer failed: {s}. Send it from the provider's page.", .{ x.invoice, c.why }) };
                };
                what = try std.fmt.allocPrint(a, "finalised and sent invoice {s}", .{x.invoice});
                sent_note = "The provider sent it to the customer to pay (a sandbox sends no mail).";
            }
            const after = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else unseen(a, c, what);
            const now_inv = model.invoice(after);
            if (now_inv.status == .draft) return .{ .done = false, .text = try std.fmt.allocPrint(a, "The provider answered without an error, and invoice {s} is still a draft. Look at it at the provider.", .{x.invoice}) };
            return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Done: invoice {s} for {s} is finalised, as {s} ({s}). {s}", .{ x.invoice, try model.money(a, now_inv.total, now_inv.currency), now_inv.label(), @tagName(now_inv.status), sent_note }) };
        },
        .remind => |x| {
            // each still open and still owing, or nothing is sent at all
            for (x.invoices) |id| {
                const v = c.get(a, try std.fmt.allocPrint(a, "/v1/invoices/{s}", .{id})) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
                const inv = model.invoice(v);
                if (inv.status != .open or inv.amount_remaining <= 0) return stopped(a, "invoice {s} is no longer open and owing (it is {s}). Read the account again.", .{ inv.label(), @tagName(inv.status) });
            }
            var sent: usize = 0;
            for (x.invoices, 0..) |id, i| {
                _ = c.post(a, try std.fmt.allocPrint(a, "/v1/invoices/{s}/send", .{id}), &.{}, try idem(a, f.key, now, i)) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    if (sent == 0) return failed(a, c);
                    return .{ .done = true, .note = try std.fmt.allocPrint(a, "had {d} of {d} invoices sent again", .{ sent, x.invoices.len }), .text = try std.fmt.allocPrint(a, "{d} of {d} invoices were sent again; then the provider refused: {s}.", .{ sent, x.invoices.len, c.why }) };
                };
                sent += 1;
            }
            return .{ .done = true, .note = try std.fmt.allocPrint(a, "had {d} invoice{s} sent again", .{ sent, if (sent == 1) "" else "s" }), .text = try std.fmt.allocPrint(a, "Done: the provider sent {d} invoice{s} to the customer again, with the link to pay (a sandbox sends no mail). Nothing else was changed.", .{ sent, if (sent == 1) "" else "s" }) };
        },
    }
}

/// Keeps what the account already shows against a dispute at the
/// provider, as evidence not yet sent: `submit=false`, always. Sending to
/// the bank is final and is never done from here.
pub fn stage(a: Allocator, c: *stripe.Client, d: audit.Data, dp: model.Dispute, now: i64) !Outcome {
    const path = try std.fmt.allocPrint(a, "/v1/disputes/{s}", .{dp.id});
    const before = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
    const was = try model.dispute(a, before);
    if (!was.needsAnswer()) return stopped(a, "dispute {s} no longer waits for an answer (it is {s}). Read the account again.", .{ dp.id, was.status });
    if (was.has_evidence) return stopped(a, "dispute {s} already has evidence kept at the provider. paymcp doesn't write over it: look at it there.", .{dp.id});
    const ev = try dispute.evidence(a, d, dp);
    if (ev.fields.len == 0) return stopped(a, "the account shows nothing to keep as evidence for dispute {s}.", .{dp.id});
    var fields: std.ArrayList([2][]const u8) = .empty;
    for (ev.fields) |f| try fields.append(a, .{ try std.fmt.allocPrint(a, "evidence[{s}]", .{f.name}), f.value });
    // (without this line the provider would send it to the bank)
    try fields.append(a, .{ "submit", "false" });
    _ = c.post(a, path, fields.items, try idem(a, dp.id, now, 0)) catch |e| return if (e == error.OutOfMemory) e else failed(a, c);
    const what = try std.fmt.allocPrint(a, "kept {d} fields of evidence at the provider for dispute {s}, not sent", .{ ev.fields.len, dp.id });
    const after_v = c.get(a, path) catch |e| return if (e == error.OutOfMemory) e else unseen(a, c, what);
    const after = try model.dispute(a, after_v);
    if (after.submissions != was.submissions or !after.needsAnswer())
        return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "The evidence was kept, and dispute {s} now shows the status {s}, sent to the bank {d} time{s}: that is not what was asked for. Look at it at the provider now.", .{ dp.id, after.status, after.submissions, if (after.submissions == 1) "" else "s" }) };
    var names: std.ArrayList([]const u8) = .empty;
    for (ev.fields) |f| try names.append(a, f.name);
    return .{ .done = true, .note = what, .text = try std.fmt.allocPrint(a, "Done: {d} fields are kept at the provider as evidence for dispute {s} ({s}). Nothing was sent to the bank. Add what only you have there, read it all, and send it yourself: sending is final.", .{ ev.fields.len, dp.id, try std.mem.join(a, ", ", names.items) }) };
}

const t = std.testing;
const sim = @import("sim.zig");
const config = @import("config.zig");

const day0: i64 = 1795392000; // 2026-11-23

const Fx = struct {
    arena: std.heap.ArenaAllocator,
    s: *sim.Sim,
    cfg: config.Config,
    c: stripe.Client,
    d: audit.Data,
    fs: []audit.Finding,

    fn init(fx: *Fx) !void {
        fx.arena = .init(t.allocator);
        const a = fx.arena.allocator();
        fx.s = try sim.start(std.heap.page_allocator, t.io, .{ .key = "rk_test_sim", .write_key = "rk_test_writes", .now = day0, .disputes = .some });
        var diag: config.Diag = .{};
        fx.cfg = try config.parse(a, try std.fmt.allocPrint(a, "[stripe]\nurl = http://127.0.0.1:{d}\n[plans]\nteam = team_monthly\npro = pro_monthly\n", .{fx.s.port}), &diag);
        fx.c = try stripe.Client.init(t.allocator, t.io, &fx.cfg, "rk_test_sim");
        fx.c.wait_ms = 0;
        fx.c.write_key = "rk_test_writes";
        try fx.read();
    }

    fn read(fx: *Fx) !void {
        const a = fx.arena.allocator();
        var wd: @import("who.zig").Diag = .{};
        fx.d = try fx.c.load(a, &fx.cfg, try @import("who.zig").parse(a, sim.who_csv, &wd), day0);
        fx.fs = try audit.run(a, fx.d, fx.cfg.rules, day0);
    }

    fn finding(fx: *Fx, key: []const u8) ?audit.Finding {
        for (fx.fs) |f| if (std.mem.eql(u8, f.key, key)) return f;
        return null;
    }

    fn deinit(fx: *Fx) void {
        fx.c.deinit();
        fx.arena.deinit();
    }
};

fn expectIn(text: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, text, want) == null) {
        std.debug.print("\n--- wanted ---\n{s}\n--- in ---\n{s}\n", .{ want, text });
        return error.TestExpectedIn;
    }
}

test "each_change_is_made_once_and_the_next_reading_no_longer_finds_it" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.arena.allocator();
    const keys = [_]struct { key: []const u8, says: []const u8 }{
        .{ .key = "discount_no_end:sub_alder:di_alder", .says = "Done: subscription sub_alder no longer has the discount di_alder." },
        .{ .key = "free:sub_elm", .says = "Done: subscription sub_elm no longer has the discount di_elm." },
        .{ .key = "more_seats:sub_alder:si_alder_1", .says = "Done: subscription item si_alder_1 has the quantity 9 (it was 5)." },
        .{ .key = "higher_plan:sub_birch", .says = "Done: subscription item si_birch_1 is on the price price_pro (it was price_team), with its quantity as before." },
        .{ .key = "old_price:sub_dogwood:si_dogwood_1", .says = "Done: subscription item si_dogwood_1 is on the price price_team (it was price_team_2023), with its quantity as before." },
        .{ .key = "paused:sub_gorse", .says = "Done: collection on subscription sub_gorse is no longer paused." },
        .{ .key = "draft_invoice:in_gorse_draft", .says = "Done: invoice in_gorse_draft for 480.00 EUR is finalised, as FH-" },
        .{ .key = "overdue:cus_dogwood:eur", .says = "Done: the provider sent 1 invoice to the customer again" },
    };
    for (keys) |k| {
        const f = fx.finding(k.key) orelse {
            std.debug.print("no finding {s}\n", .{k.key});
            return error.TestNoFinding;
        };
        try t.expect(f.change != null and f.does.len > 0);
        const got = try apply(a, &fx.c, f, day0);
        try expectIn(got.text, k.says);
        try t.expect(got.done and got.note.len > 0);
    }
    // what paymcp can't do says so and sends nothing
    const posts = fx.c.posts;
    const none = try apply(a, &fx.c, fx.finding("written_off:cus_ivy:eur").?, day0);
    try t.expect(!none.done);
    try expectIn(none.text, "Nothing was changed: there is nothing paymcp can do about written_off:cus_ivy:eur");
    try t.expectEqual(posts, fx.c.posts);
    // the same change again, from the old reading: the record is no longer as it was found
    const stale = try apply(a, &fx.c, fx.finding("more_seats:sub_alder:si_alder_1").?, day0);
    try t.expect(!stale.done);
    try expectIn(stale.text, "Nothing was changed: subscription item si_alder_1 now has the quantity 9, not 5 as when it was found.");
    const stale2 = try apply(a, &fx.c, fx.finding("paused:sub_gorse").?, day0);
    try expectIn(stale2.text, "Nothing was changed: collection on subscription sub_gorse is no longer paused.");
    try t.expectEqual(posts, fx.c.posts);
    // the next reading: all eight are gone, and nothing new came of them
    // but the invoice that is now open and was never charged
    try fx.read();
    for (keys[0..7]) |k| try t.expect(fx.finding(k.key) == null);
    try t.expect(fx.finding("unsent_invoice:in_gorse_draft") == null); // (finalised a moment ago: not yet old)
    // Birch moved to pro kept its four seats; Dogwood's ten moved with it
    for (fx.d.subscriptions) |sub| {
        if (std.mem.eql(u8, sub.id, "sub_birch")) try t.expectEqual(@as(?i64, 4), sub.items[0].quantity);
        if (std.mem.eql(u8, sub.id, "sub_dogwood")) try t.expectEqual(@as(?i64, 10), sub.items[0].quantity);
    }
    // the reading key was never used to change anything, and nothing went to a bank
    try t.expectEqual(@as(u32, 0), fx.s.refused);
    try t.expectEqual(@as(u32, 0), fx.s.submitted);
}

test "evidence_is_kept_at_the_provider_and_never_sent" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.arena.allocator();
    const dp = dispute.find(fx.d, "dispute:du_birch").?;
    const got = try stage(a, &fx.c, fx.d, dp, day0);
    try t.expect(got.done);
    try expectIn(got.text, "Done: 6 fields are kept at the provider as evidence for dispute du_birch (customer_name, customer_email_address, billing_address, service_date, product_description, uncategorized_text). Nothing was sent to the bank.");
    try t.expectEqual(@as(u32, 0), fx.s.submitted);
    // once kept, it isn't written over
    const again = try stage(a, &fx.c, fx.d, dp, day0);
    try t.expect(!again.done);
    try expectIn(again.text, "already has evidence kept at the provider");
    // one that was lost takes nothing
    var lost = dp;
    lost.id = "du_ivy_lost";
    try expectIn((try stage(a, &fx.c, fx.d, lost, day0)).text, "Nothing was changed: dispute du_ivy_lost no longer waits for an answer (it is lost).");
}

test "without_the_second_key_nothing_is_sent" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const a = fx.arena.allocator();
    fx.c.write_key = "";
    const got = try apply(a, &fx.c, fx.finding("paused:sub_gorse").?, day0);
    try t.expect(!got.done);
    try expectIn(got.text, "Nothing was changed: there is no key that may change things (STRIPE_WRITE_KEY).");
    try t.expectEqual(@as(u32, 0), fx.c.posts);
    // the reading key in the second key's place: the provider refuses, and it is said
    fx.c.write_key = "rk_test_sim";
    const refused = try apply(a, &fx.c, fx.finding("paused:sub_gorse").?, day0);
    try t.expect(!refused.done);
    try expectIn(refused.text, "Nothing was changed: the second key may not change this (403)");
    try t.expectEqual(@as(u32, 1), fx.s.refused);
    try t.expectEqual(@as(u32, 0), fx.s.changes);
}

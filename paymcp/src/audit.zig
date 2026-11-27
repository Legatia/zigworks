//! The billing audit: what customers should be paying and are not, found
//! by fixed rules over what the billing provider holds and, where the
//! business gave it, its own "who has what" file. Every finding has an
//! amount (or says the amount isn't known), the rows it rests on, and what
//! is proposed. Nothing here reads the network or changes anything.
//!
//! Not every finding is a mistake: a discount may be meant to last, an old
//! price may be a promise. Each is a question for a person.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const who = @import("who.zig");

pub const Plan = struct { name: []const u8, price: []const u8 };

pub const Rules = struct {
    /// A discount with no end, older than this, is asked about.
    old_discount_days: u32 = 365,
    /// A subscription that costs nothing, older than this.
    free_days: u32 = 90,
    /// A draft invoice older than this was never sent. One the provider
    /// will send itself (auto_advance) is given a day whatever this says:
    /// a subscription's invoice is a draft for about an hour first.
    draft_days: u32 = 7,
    /// An invoice the provider should have charged, not tried for this long.
    unsent_days: u32 = 3,
    /// An invoice sent to be paid by hand, this long past its due date.
    overdue_days: u32 = 7,
    /// How far back written-off invoices are counted.
    written_off_days: u32 = 365,
    /// Written-off invoices below this sum (a customer, smallest unit) are left out.
    written_off_above: i64 = 0,
    /// The price list now: price ids or lookup keys. Empty: every active price.
    current: []const []const u8 = &.{},
    /// A plan's name in the business's file, and the price it means.
    plans: []const Plan = &.{},
    /// Use in the product may exceed use reported by this much before it is asked about.
    usage_margin_percent: u32 = 1,
    /// Whether card disputes are read.
    disputes: bool = true,
    /// How far back disputes are read, and lost ones counted.
    dispute_days: u32 = 180,
};

/// What a customer paid before a disputed payment, and never took back:
/// what a bank weighs most against "it wasn't me".
pub const Earlier = struct { customer: []const u8, paid: u32 = 0, first: i64 = 0 };

/// Use the provider was told of, for one metered subscription item in its
/// current period.
pub const Usage = struct { item: []const u8, value: f64 };

pub const Data = struct {
    customers: []const model.Customer = &.{},
    subscriptions: []const model.Subscription = &.{},
    prices: []const model.Price = &.{},
    invoices: []const model.Invoice = &.{},
    rows: []const who.Row = &.{},
    usage: []const Usage = &.{},
    disputes: []const model.Dispute = &.{},
    earlier: []const Earlier = &.{},
    /// The disputes could be read (false: none are known, not none exist).
    disputes_read: bool = true,
    /// Something could not be read whole (a page limit, a permission): said
    /// with the findings, since what wasn't read can't be found.
    gaps: []const []const u8 = &.{},
    /// No list was cut at the page limit.
    whole: bool = true,
    /// Use reported to the meters could be read.
    usage_read: bool = true,
};

pub const Kind = enum {
    discount_no_end,
    free,
    draft_invoice,
    unsent_invoice,
    written_off,
    overdue,
    failed_payment,
    old_price,
    paused,
    more_seats,
    higher_plan,
    not_paying,
    usage_not_reported,
    no_customer,
    dispute,
    disputes_unanswered,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .discount_no_end => "A discount with no end",
            .free => "Free, and has been for a while",
            .draft_invoice => "An invoice never sent",
            .unsent_invoice => "An invoice never charged",
            .written_off => "Invoices written off",
            .overdue => "Invoices past due",
            .failed_payment => "Payments that failed",
            .old_price => "A price no longer sold",
            .paused => "Collection paused",
            .more_seats => "More seats than paid for",
            .higher_plan => "A higher plan than paid for",
            .not_paying => "Using the product, not paying",
            .usage_not_reported => "Use that was never reported",
            .no_customer => "Using the product, not in billing at all",
            .dispute => "A card dispute to answer",
            .disputes_unanswered => "Disputes lost without an answer",
        };
    }
};

pub const Per = enum { month, once, unknown };

pub const Row = struct { source: []const u8, value: []const u8 };

/// A message to the customer about a finding, where the change is theirs
/// to see: a draft for a person to read, change and send from their own
/// mail. Nothing here sends anything.
pub const Letter = struct {
    /// The customer's address as billing has it; "": not known.
    to: []const u8 = "",
    subject: []const u8,
    /// From the greeting to the last sentence; the sender's name is added
    /// when it is written out.
    body: []const u8,
};

/// The one thing paymcp can do about a finding at the provider, where the
/// pay file allows changes and a person says so. Each is for from now on:
/// nothing here charges for the past.
pub const Change = union(enum) {
    end_discount: struct { subscription: []const u8, discount: []const u8 },
    set_quantity: struct { item: []const u8, to: i64, was: i64 },
    set_price: struct { item: []const u8, to: []const u8, was: []const u8 },
    unpause: struct { subscription: []const u8 },
    /// `by_hand`: the customer pays it themselves; else the provider
    /// charges the payment method on file.
    finalize: struct { invoice: []const u8, by_hand: bool },
    remind: struct { invoices: []const []const u8 },
};

pub const Finding = struct {
    kind: Kind,
    /// The same thing gets the same key at every reading.
    key: []const u8,
    customer: []const u8,
    /// The customer as a person knows them.
    name: []const u8,
    /// In the currency's smallest unit; 0 with `per = .unknown`.
    amount: i64 = 0,
    currency: []const u8 = "",
    per: Per = .unknown,
    /// One sentence saying what was found.
    what: []const u8,
    rows: []const Row,
    proposal: []const u8,
    /// Null where nothing about it is the customer's to see.
    letter: ?Letter = null,
    /// A day by which someone must act (a dispute's answer), in seconds.
    due: ?i64 = null,
    /// What paymcp can do about it, and that in a sentence; null: nothing.
    change: ?Change = null,
    does: []const u8 = "",
};

const day_s: i64 = 86400;

const Ctx = struct {
    a: Allocator,
    d: Data,
    r: Rules,
    now: i64,
    out: std.ArrayList(Finding) = .empty,

    fn nameOf(c: *Ctx, customer: []const u8) []const u8 {
        for (c.d.customers) |cu| if (std.mem.eql(u8, cu.id, customer)) return cu.label();
        return customer;
    }

    fn emailOf(c: *Ctx, customer: []const u8) []const u8 {
        for (c.d.customers) |cu| if (std.mem.eql(u8, cu.id, customer)) return cu.email;
        return "";
    }

    fn add(c: *Ctx, f: Finding) !void {
        try c.out.append(c.a, f);
    }

    /// A draft to the customer: "Hello,", then what `fmt` says.
    fn letter(c: *Ctx, customer: []const u8, subject: []const u8, comptime fmt: []const u8, args: anytype) !Letter {
        return .{ .to = c.emailOf(customer), .subject = subject, .body = try std.fmt.allocPrint(c.a, "Hello,\n\n" ++ fmt, args) };
    }

    fn rows(c: *Ctx, list: []const Row) ![]const Row {
        return c.a.dupe(Row, list);
    }

    fn p(c: *Ctx, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.a, fmt, args);
    }

    fn money(c: *Ctx, amount: i64, currency: []const u8) ![]const u8 {
        return model.money(c.a, amount, currency);
    }

    fn date(c: *Ctx, t_s: i64) ![]const u8 {
        return model.day(c.a, t_s);
    }
};

/// The findings, the largest monthly amount first, then one-off amounts,
/// then those whose amount isn't known.
pub fn run(a: Allocator, d: Data, r: Rules, now: i64) ![]Finding {
    var c: Ctx = .{ .a = a, .d = d, .r = r, .now = now };
    for (d.subscriptions) |sub| {
        if (!sub.live()) continue;
        try discounts(&c, sub);
        try free(&c, sub);
        try oldPrices(&c, sub);
        try paused(&c, sub);
    }
    try invoices(&c);
    try writtenOff(&c);
    try late(&c);
    try whoRows(&c);
    try disputes(&c);
    std.mem.sort(Finding, c.out.items, {}, lessThan);
    return c.out.items;
}

fn lessThan(_: void, x: Finding, y: Finding) bool {
    // what has a last day comes first, the nearest day first
    if (x.due != null or y.due != null) {
        if (x.due == null) return false;
        if (y.due == null) return true;
        if (x.due.? != y.due.?) return x.due.? < y.due.?;
    }
    if (x.per != y.per) return @intFromEnum(x.per) < @intFromEnum(y.per);
    if (x.amount != y.amount) return x.amount > y.amount;
    return std.mem.lessThan(u8, x.key, y.key);
}

/// What a discount takes off a month; null when it can't be worked out.
fn discountMonthly(sub: model.Subscription, d: model.Discount) ?i64 {
    if (!d.coupon_known) return null;
    const list = sub.listMonthly();
    if (d.coupon.percent_bp) |bp| {
        const l = list orelse return null;
        return model.divRound(l * bp, 10000);
    }
    if (d.coupon.amount_off) |off| {
        for (sub.items) |it| {
            if (it.price.metered or !it.price.recurring) continue;
            const m = model.perMonth(off, it.price.interval, it.price.interval_count);
            return if (list) |l| @min(m, l) else m;
        }
    }
    return null;
}

fn fullDiscount(sub: model.Subscription) ?model.Discount {
    for (sub.discounts) |d| {
        if (d.coupon_known and d.coupon.percent_bp != null and d.coupon.percent_bp.? >= 10000 and d.end == null) return d;
    }
    return null;
}

fn discounts(c: *Ctx, sub: model.Subscription) !void {
    for (sub.discounts) |d| {
        if (d.end != null) continue;
        // (everything off is the next rule's: "free")
        if (d.coupon_known and d.coupon.percent_bp != null and d.coupon.percent_bp.? >= 10000) continue;
        if (d.coupon_known and d.coupon.duration != .forever) continue;
        const age_days = @divFloor(c.now - d.start, day_s);
        if (age_days < c.r.old_discount_days) continue;
        const amount = discountMonthly(sub, d);
        const off: []const u8 = if (!d.coupon_known)
            "its coupon wasn't read"
        else if (d.coupon.percent_bp) |bp|
            try c.p("{d}.{d:0>2}% off", .{ @divFloor(bp, 100), @as(u64, @intCast(@mod(bp, 100))) })
        else if (d.coupon.amount_off) |x|
            try c.p("{s} off each period", .{try c.money(x, if (d.coupon.currency.len > 0) d.coupon.currency else sub.currency)})
        else
            "an amount this audit couldn't read";
        try c.add(.{
            .kind = .discount_no_end,
            .key = try c.p("discount_no_end:{s}:{s}", .{ sub.id, d.id }),
            .customer = sub.customer,
            .name = c.nameOf(sub.customer),
            .amount = amount orelse 0,
            .currency = sub.currency,
            .per = if (amount != null) .month else .unknown,
            .what = try c.p("{s} has had the discount \"{s}\" ({s}) since {s}, and it has no end.", .{ c.nameOf(sub.customer), d.coupon.label(), off, try c.date(d.start) }),
            .rows = try c.rows(&.{
                .{ .source = try c.p("subscription {s}", .{sub.id}), .value = try c.p("status {s}, list price {s} a month", .{ @tagName(sub.status), if (sub.listMonthly()) |l| try c.money(l, sub.currency) else "not one amount" }) },
                .{ .source = try c.p("discount {s}", .{d.id}), .value = try c.p("coupon {s}, start {s}, end none", .{ d.coupon.id, try c.date(d.start) }) },
            }),
            .proposal = "If it was meant to end, end it from the next period and tell the customer first. If it was meant to last, dismiss this as intended.",
            .change = .{ .end_discount = .{ .subscription = sub.id, .discount = d.id } },
            .does = try c.p("End the discount \"{s}\" on subscription {s}: the next invoice is for the full price. Nothing is charged for the time already invoiced.", .{ d.coupon.label(), sub.id }),
            .letter = if (!d.coupon_known) null else try c.letter(sub.customer, "Your discount", "Your subscription with us has had the discount \"{s}\" ({s}) since {s}. It was meant to run for a limited time, and we would like to end it from your next billing period{s}.\n\nIf it was agreed to last longer, reply to this message and we will keep to what was agreed.", .{
                d.coupon.label(),
                off,
                try c.date(d.start),
                if (sub.listMonthly()) |l| try c.p("; your subscription is then {s} a month", .{try c.money(l, sub.currency)}) else "",
            }),
        });
    }
}

fn free(c: *Ctx, sub: model.Subscription) !void {
    if (@divFloor(c.now - sub.created, day_s) < c.r.free_days) return;
    if (sub.status == .trialing) return;
    const list = sub.listMonthly();
    if (fullDiscount(sub)) |d| {
        try c.add(.{
            .kind = .free,
            .key = try c.p("free:{s}", .{sub.id}),
            .customer = sub.customer,
            .name = c.nameOf(sub.customer),
            .amount = list orelse 0,
            .currency = sub.currency,
            .per = if (list != null and list.? > 0) .month else .unknown,
            .what = try c.p("{s} pays nothing: the discount \"{s}\" takes everything off, with no end, since {s}.", .{ c.nameOf(sub.customer), d.coupon.label(), try c.date(d.start) }),
            .rows = try c.rows(&.{
                .{ .source = try c.p("subscription {s}", .{sub.id}), .value = try c.p("created {s}, list price {s} a month", .{ try c.date(sub.created), if (list) |l| try c.money(l, sub.currency) else "not one amount" }) },
                .{ .source = try c.p("discount {s}", .{d.id}), .value = try c.p("coupon {s}, 100% off, end none", .{d.coupon.id}) },
            }),
            .proposal = "If this is a gift that should last, dismiss it as intended. Otherwise end the discount from the next period and tell the customer first.",
            .change = .{ .end_discount = .{ .subscription = sub.id, .discount = d.id } },
            .does = try c.p("End the discount \"{s}\" on subscription {s}: the next invoice is for the full price. Nothing is charged for the time already invoiced.", .{ d.coupon.label(), sub.id }),
            .letter = try c.letter(sub.customer, "Your subscription", "Your subscription with us has been free of charge since {s}, through the discount \"{s}\". We would like to end that from your next billing period{s}.\n\nIf it was agreed to stay free, reply to this message and we will keep to what was agreed.", .{
                try c.date(d.start),
                d.coupon.label(),
                if (list != null and list.? > 0) try c.p("; your subscription is then {s} a month", .{try c.money(list.?, sub.currency)}) else "",
            }),
        });
        return;
    }
    // every fixed item at a price of zero, and nothing metered
    if (sub.items.len == 0 or sub.hasMetered()) return;
    for (sub.items) |it| if (it.price.unit_amount == null or it.price.unit_amount.? != 0) return;
    try c.add(.{
        .kind = .free,
        .key = try c.p("free:{s}", .{sub.id}),
        .customer = sub.customer,
        .name = c.nameOf(sub.customer),
        .currency = sub.currency,
        .what = try c.p("{s} has been on a price of zero ({s}) since {s}.", .{ c.nameOf(sub.customer), sub.items[0].price.label(), try c.date(sub.created) }),
        .rows = try c.rows(&.{
            .{ .source = try c.p("subscription {s}", .{sub.id}), .value = try c.p("created {s}, status {s}", .{ try c.date(sub.created), @tagName(sub.status) }) },
            .{ .source = try c.p("price {s}", .{sub.items[0].price.id}), .value = "unit amount 0" },
        }),
        .proposal = "What it should pay is yours to say: this audit can't know. If it is a free plan as intended, dismiss it.",
    });
}

fn isCurrent(c: *Ctx, pr: model.Price) bool {
    if (!pr.active) return false;
    if (c.r.current.len == 0) return true;
    for (c.r.current) |name| if (pr.is(name)) return true;
    return false;
}

/// The price sold now for the same product and billing interval.
fn currentFor(c: *Ctx, old: model.Price) ?model.Price {
    var found: ?model.Price = null;
    for (c.d.prices) |pr| {
        if (std.mem.eql(u8, pr.id, old.id)) continue;
        if (!std.mem.eql(u8, pr.product, old.product) or pr.product.len == 0) continue;
        if (!pr.recurring or pr.metered != old.metered or pr.interval != old.interval or pr.interval_count != old.interval_count) continue;
        if (!std.mem.eql(u8, pr.currency, old.currency)) continue;
        if (!isCurrent(c, pr)) continue;
        // two current prices for one product and interval: not this audit's to choose
        if (found != null) return null;
        found = pr;
    }
    return found;
}

fn oldPrices(c: *Ctx, sub: model.Subscription) !void {
    for (sub.items) |it| {
        if (isCurrent(c, it.price)) continue;
        const now_price = currentFor(c, it.price);
        var amount: ?i64 = null;
        if (now_price) |np| {
            if (np.monthly()) |new_m| if (it.price.monthly()) |old_m| {
                if (!it.price.metered) amount = (new_m - old_m) * (it.quantity orelse 1);
            };
        }
        // an old price that costs more than today's is no loss
        if (amount != null and amount.? <= 0) continue;
        try c.add(.{
            .kind = .old_price,
            .key = try c.p("old_price:{s}:{s}", .{ sub.id, it.id }),
            .customer = sub.customer,
            .name = c.nameOf(sub.customer),
            .amount = amount orelse 0,
            .currency = sub.currency,
            .per = if (amount != null) .month else .unknown,
            .what = if (now_price) |np|
                try c.p("{s} is on {s}, which is no longer sold; the price now is {s}.", .{ c.nameOf(sub.customer), it.price.label(), np.label() })
            else
                try c.p("{s} is on {s}, which is no longer sold, and no one price replaces it.", .{ c.nameOf(sub.customer), it.price.label() }),
            .rows = try c.rows(&.{
                .{ .source = try c.p("subscription item {s}", .{it.id}), .value = try c.p("price {s}, quantity {d}, {s} a unit a month", .{ it.price.id, it.quantity orelse 1, if (it.price.monthly()) |m| try c.money(m, sub.currency) else "not one amount" }) },
                .{ .source = if (now_price) |np| try c.p("price {s}", .{np.id}) else "the price list", .value = if (now_price) |np| try c.p("active, {s} a unit a month", .{if (np.monthly()) |m| try c.money(m, sub.currency) else "not one amount"}) else "no single current price for this product and interval" },
            }),
            .proposal = "Old customers often keep old prices on purpose: if so, dismiss this as intended. Otherwise move the subscription to the price sold now from the next period, with notice.",
            .change = if (now_price != null and amount != null) .{ .set_price = .{ .item = it.id, .to = now_price.?.id, .was = it.price.id } } else null,
            .does = if (now_price != null and amount != null) try c.p("Move subscription item {s} from {s} to {s}, keeping its quantity: the next invoice is at the new price. Nothing is charged for the time already invoiced.", .{ it.id, it.price.label(), now_price.?.label() }) else "",
            .letter = blk: {
                const np = now_price orelse break :blk null;
                const new_m = np.monthly() orelse break :blk null;
                const old_m = it.price.monthly() orelse break :blk null;
                if (amount == null) break :blk null;
                break :blk try c.letter(sub.customer, "The price of your subscription", "Your subscription is on {s}, which we no longer sell. From your next billing period we would like to move it to the price we sell now, {s}: {s} instead of {s} a unit a month.\n\nIf you were promised the old price, reply to this message and we will keep to that.", .{ it.price.label(), np.label(), try c.money(new_m, sub.currency), try c.money(old_m, sub.currency) });
            },
        });
    }
}

fn paused(c: *Ctx, sub: model.Subscription) !void {
    const pause = sub.pause orelse return;
    if (pause.resumes_at) |at| if (at > c.now) return;
    const list = sub.listMonthly();
    try c.add(.{
        .kind = .paused,
        .key = try c.p("paused:{s}", .{sub.id}),
        .customer = sub.customer,
        .name = c.nameOf(sub.customer),
        .amount = list orelse 0,
        .currency = sub.currency,
        .per = if (list != null and list.? > 0) .month else .unknown,
        .what = if (pause.resumes_at) |at|
            try c.p("Collection from {s} is paused and was to resume on {s}.", .{ c.nameOf(sub.customer), try c.date(at) })
        else
            try c.p("Collection from {s} is paused, with no date to resume.", .{c.nameOf(sub.customer)}),
        .rows = try c.rows(&.{
            .{ .source = try c.p("subscription {s}", .{sub.id}), .value = try c.p("status {s}, pause_collection.behavior {s}, resumes_at {s}", .{ @tagName(sub.status), pause.behavior, if (pause.resumes_at) |at| try c.date(at) else "none" }) },
        }),
        .proposal = "If the pause is over, resume collection. If the customer is still away, set a date, or dismiss this as intended.",
        .change = .{ .unpause = .{ .subscription = sub.id } },
        .does = try c.p("Resume collection on subscription {s}: its next invoice is collected again. Invoices made while it was paused stay as they are.", .{sub.id}),
    });
}

fn invoices(c: *Ctx) !void {
    for (c.d.invoices) |inv| {
        if (inv.total <= 0) continue;
        const age_days = @divFloor(c.now - inv.created, day_s);
        const draft_days = if (inv.auto_advance) @max(c.r.draft_days, 1) else c.r.draft_days;
        if (inv.status == .draft and age_days >= draft_days) {
            try c.add(.{
                .kind = .draft_invoice,
                .key = try c.p("draft_invoice:{s}", .{inv.id}),
                .customer = inv.customer,
                .name = c.nameOf(inv.customer),
                .amount = inv.total,
                .currency = inv.currency,
                .per = .once,
                .what = try c.p("An invoice to {s} for {s} has been a draft since {s}.", .{ c.nameOf(inv.customer), try c.money(inv.total, inv.currency), try c.date(inv.created) }),
                .rows = try c.rows(&.{
                    .{ .source = try c.p("invoice {s}", .{inv.id}), .value = try c.p("status draft, created {s}, total {s}, auto_advance {}", .{ try c.date(inv.created), try c.money(inv.total, inv.currency), inv.auto_advance }) },
                }),
                .proposal = "Look at it, then send it or delete it. A draft that should not go out is better deleted than left.",
                .change = .{ .finalize = .{ .invoice = inv.id, .by_hand = !inv.collects_itself } },
                .does = if (inv.collects_itself)
                    try c.p("Finalise the draft invoice {s} for {s}: the provider then charges the payment method {s} has on file, by itself (with none on file it stays open).", .{ inv.id, try c.money(inv.total, inv.currency), c.nameOf(inv.customer) })
                else
                    try c.p("Finalise the draft invoice {s} for {s} and have the provider send it to {s} to pay.", .{ inv.id, try c.money(inv.total, inv.currency), c.nameOf(inv.customer) }),
            });
        } else if (inv.status == .open and inv.collects_itself and !inv.attempted and @divFloor(c.now - (inv.finalized_at orelse inv.created), day_s) >= c.r.unsent_days) {
            try c.add(.{
                .kind = .unsent_invoice,
                .key = try c.p("unsent_invoice:{s}", .{inv.id}),
                .customer = inv.customer,
                .name = c.nameOf(inv.customer),
                .amount = inv.amount_remaining,
                .currency = inv.currency,
                .per = .once,
                .what = try c.p("Invoice {s} to {s} for {s} is open since {s} and no payment was ever tried.", .{ inv.label(), c.nameOf(inv.customer), try c.money(inv.amount_remaining, inv.currency), try c.date(inv.created) }),
                .rows = try c.rows(&.{
                    .{ .source = try c.p("invoice {s}", .{inv.id}), .value = try c.p("status open, collection charge_automatically, attempted false, remaining {s}", .{try c.money(inv.amount_remaining, inv.currency)}) },
                }),
                .proposal = "The customer likely has no payment method on file. Ask them for one, or send the invoice to be paid by hand.",
                .letter = try c.letter(inv.customer, try c.p("Invoice {s}", .{inv.label()}), "Invoice {s} for {s} is open, and we have no payment method on file to charge it. Could you add one on the invoice's page, or tell us how you would like to pay?", .{ inv.label(), try c.money(inv.amount_remaining, inv.currency) }),
            });
        }
    }
}

fn writtenOff(c: *Ctx) !void {
    const since = c.now - @as(i64, c.r.written_off_days) * day_s;
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (c.d.invoices) |first| {
        if (!isWrittenOff(first, since)) continue;
        const gop = try done.getOrPut(c.a, try c.p("{s}/{s}", .{ first.customer, first.currency }));
        if (gop.found_existing) continue;
        var sum: i64 = 0;
        var list: std.ArrayList(Row) = .empty;
        for (c.d.invoices) |inv| {
            if (!isWrittenOff(inv, since)) continue;
            if (!std.mem.eql(u8, inv.customer, first.customer) or !std.mem.eql(u8, inv.currency, first.currency)) continue;
            sum += inv.total;
            try list.append(c.a, .{ .source = try c.p("invoice {s}", .{inv.id}), .value = try c.p("{s}, {s}, created {s}", .{ @tagName(inv.status), try c.money(inv.total, inv.currency), try c.date(inv.created) }) });
        }
        if (sum <= c.r.written_off_above) continue;
        try c.add(.{
            .kind = .written_off,
            .key = try c.p("written_off:{s}:{s}", .{ first.customer, first.currency }),
            .customer = first.customer,
            .name = c.nameOf(first.customer),
            .amount = sum,
            .currency = first.currency,
            .per = .once,
            .what = try c.p("{d} invoice{s} to {s}, {s} together, {s} marked uncollectible or voided after being sent in the last {d} days.", .{ list.items.len, if (list.items.len == 1) "" else "s", c.nameOf(first.customer), try c.money(sum, first.currency), if (list.items.len == 1) "was" else "were", c.r.written_off_days }),
            .rows = list.items,
            .proposal = "Check each was given up on purpose. One written off by a rule (after failed payments, or on a pause) can still be asked for.",
        });
    }
}

fn isLate(c: *Ctx, inv: model.Invoice, kind: Kind) bool {
    if (inv.status != .open or inv.amount_remaining <= 0) return false;
    if (kind == .overdue) {
        const due = inv.due_date orelse return false;
        return !inv.collects_itself and c.now - due >= @as(i64, c.r.overdue_days) * day_s;
    }
    return inv.collects_itself and inv.attempted;
}

/// Money owed now and late: invoices sent to be paid by hand and past
/// their due date, and invoices the provider tried to charge and couldn't.
/// One sum for each customer, as a person would ask for it.
fn late(c: *Ctx) !void {
    for ([_]Kind{ .overdue, .failed_payment }) |kind| {
        var done: std.StringHashMapUnmanaged(void) = .empty;
        for (c.d.invoices) |first| {
            if (!isLate(c, first, kind)) continue;
            const gop = try done.getOrPut(c.a, try c.p("{s}/{s}", .{ first.customer, first.currency }));
            if (gop.found_existing) continue;
            var sum: i64 = 0;
            var oldest: i64 = std.math.maxInt(i64);
            var stopped: usize = 0;
            var list: std.ArrayList(Row) = .empty;
            // the invoices as a letter lists them
            var lines: std.ArrayList(u8) = .empty;
            var one_label: []const u8 = "";
            var ids: std.ArrayList([]const u8) = .empty;
            for (c.d.invoices) |inv| {
                if (!isLate(c, inv, kind)) continue;
                if (!std.mem.eql(u8, inv.customer, first.customer) or !std.mem.eql(u8, inv.currency, first.currency)) continue;
                sum += inv.amount_remaining;
                const left = try c.money(inv.amount_remaining, inv.currency);
                one_label = inv.label();
                try ids.append(c.a, inv.id);
                if (kind == .overdue) {
                    try lines.print(c.a, "- {s}: {s}, due {s}\n", .{ inv.label(), left, try c.date(inv.due_date.?) });
                } else try lines.print(c.a, "- {s}: {s}\n", .{ inv.label(), left });
                if (kind == .overdue) {
                    const due = inv.due_date.?;
                    oldest = @min(oldest, due);
                    try list.append(c.a, .{ .source = try c.p("invoice {s}", .{inv.label()}), .value = try c.p("due {s}, {d} days ago, remaining {s}", .{ try c.date(due), @divFloor(c.now - due, day_s), left }) });
                } else {
                    if (inv.next_attempt == null) stopped += 1;
                    try list.append(c.a, .{ .source = try c.p("invoice {s}", .{inv.label()}), .value = try c.p("remaining {s}, tried {d} time{s}, {s}", .{
                        left,
                        inv.attempts,
                        if (inv.attempts == 1) "" else "s",
                        if (inv.next_attempt) |at| try c.p("next try {s}", .{try c.date(at)}) else "no further try planned",
                    }) });
                }
            }
            const n = list.items.len;
            const name = c.nameOf(first.customer);
            const total = try c.money(sum, first.currency);
            const what = if (kind == .overdue)
                (if (n == 1)
                    try c.p("An invoice to {s} for {s} has been past due since {s}.", .{ name, total, try c.date(oldest) })
                else
                    try c.p("{d} invoices to {s}, {s} together, are past due; the oldest was due {s}.", .{ n, name, total, try c.date(oldest) }))
            else blk: {
                const head = if (n == 1)
                    try c.p("A payment of {s} from {s} failed, and the invoice is still open.", .{ total, name })
                else
                    try c.p("{d} payments from {s} failed: {s} is still owed.", .{ n, name, total });
                if (stopped == 0) break :blk head;
                break :blk if (n == 1)
                    try c.p("{s} No further try is planned.", .{head})
                else
                    try c.p("{s} No further try is planned for {d} of them.", .{ head, stopped });
            };
            try c.add(.{
                .kind = kind,
                .key = try c.p("{s}:{s}:{s}", .{ @tagName(kind), first.customer, first.currency }),
                .customer = first.customer,
                .name = name,
                .amount = sum,
                .currency = first.currency,
                .per = .once,
                .what = what,
                .rows = list.items,
                .proposal = if (kind == .overdue)
                    "Remind the customer, with the invoice's own link to pay. If they dispute it or can't pay, settle that on purpose: an invoice left open is neither collected nor written off."
                else
                    "The payment method on file was refused. Ask the customer for a new one (the invoice's own page takes it). Where no further try is planned, nothing more will be collected unless someone acts.",
                // (more than a few at once is a talk with the customer, not a button)
                .change = if (kind == .overdue and n <= 5) .{ .remind = .{ .invoices = ids.items } } else null,
                .does = if (kind == .overdue and n <= 5) try c.p("Have the provider send {s} to {s} again, with its link to pay.", .{ if (n == 1) try c.p("invoice {s}", .{one_label}) else try c.p("the {d} invoices", .{n}), name }) else "",
                .letter = if (kind == .overdue)
                    (if (n == 1)
                        try c.letter(first.customer, try c.p("Invoice {s}", .{one_label}), "Invoice {s} for {s} was due on {s} and is still open. Could you pay it, or tell us if something about it is not right?", .{ one_label, total, try c.date(oldest) })
                    else
                        try c.letter(first.customer, "Invoices past their due date", "{d} invoices, {s} together, are past their due date:\n\n{s}\nCould you pay them, or tell us if something about them is not right?", .{ n, total, lines.items }))
                else if (n == 1)
                    try c.letter(first.customer, try c.p("Invoice {s}: the payment did not go through", .{one_label}), "We could not take the payment of {s} for invoice {s}: the payment method on file was refused. Could you update it on the invoice's page? Once it is updated we will try again.", .{ total, one_label })
                else
                    try c.letter(first.customer, "Payments that did not go through", "We could not take {d} payments, {s} together: the payment method on file was refused.\n\n{s}\nCould you update it on an invoice's page? Once it is updated we will try again.", .{ n, total, lines.items }),
            });
        }
    }
}

fn isWrittenOff(inv: model.Invoice, since: i64) bool {
    if (inv.total <= 0 or inv.created < since) return false;
    if (inv.status == .uncollectible) return true;
    // a void counts only if the invoice had been sent
    return inv.status == .void and inv.finalized_at != null;
}

// ---- card disputes ----

pub const Reason = struct {
    /// What the cardholder says, in a few words.
    says: []const u8,
    /// What a bank wants to see against it.
    wants: []const u8,
};

/// The provider's reasons in plain words, and what answers each.
pub fn reasonOf(reason: []const u8) Reason {
    const eql = std.mem.eql;
    if (eql(u8, reason, "fraudulent")) return .{ .says = "the cardholder says they didn't make it", .wants = "that the person who paid is your customer: the name and address on the account against the card's, earlier payments from them that were never disputed, and logins or use after the payment" };
    if (eql(u8, reason, "product_not_received")) return .{ .says = "the cardholder says nothing was received", .wants = "that it was delivered: when the account was used after the payment, and what was delivered and when" };
    if (eql(u8, reason, "product_unacceptable")) return .{ .says = "the cardholder says it was not as described", .wants = "what was promised and what was delivered, and your reply to any complaint" };
    if (eql(u8, reason, "subscription_canceled")) return .{ .says = "the cardholder says the subscription was cancelled", .wants = "that it was not cancelled before this payment, or that your terms were shown: the cancellation terms, when a cancellation came in if one did, and use after it" };
    if (eql(u8, reason, "duplicate")) return .{ .says = "the cardholder says it was charged twice", .wants = "that the two payments are for different things: the other payment and what each paid for. If it was charged twice, refund it" };
    if (eql(u8, reason, "credit_not_processed")) return .{ .says = "the cardholder says a refund was promised and not given", .wants = "your refund terms and why no refund was due; if one was due, refund it" };
    if (eql(u8, reason, "unrecognized")) return .{ .says = "the cardholder doesn't recognise the payment", .wants = "what the payment was for and the name it has on a statement; a note to the customer often settles it" };
    return .{ .says = "no closer reason is given", .wants = "what was sold, that it was delivered, and any exchange with the customer about it" };
}

fn earlierOf(c: *Ctx, customer: []const u8) ?Earlier {
    if (customer.len == 0) return null;
    for (c.d.earlier) |e| if (std.mem.eql(u8, e.customer, customer)) return e;
    return null;
}

/// Who a dispute's payment came from, as a person knows them.
pub fn payerOf(d: Data, dp: model.Dispute) []const u8 {
    for (d.customers) |cu| if (dp.customer.len > 0 and std.mem.eql(u8, cu.id, dp.customer)) return cu.label();
    if (dp.payer_name.len > 0) return dp.payer_name;
    if (dp.payer_email.len > 0) return dp.payer_email;
    if (dp.customer.len > 0) return dp.customer;
    return "a payer billing doesn't name";
}

/// Disputes waiting for an answer, each with its last day; and, as one
/// sum, those lost in the last months with no answer ever sent.
fn disputes(c: *Ctx) !void {
    const since = c.now - @as(i64, c.r.dispute_days) * day_s;
    var lost: std.StringArrayHashMapUnmanaged(struct { sum: i64 = 0, rows: std.ArrayList(Row) = .empty }) = .empty;
    for (c.d.disputes) |dp| {
        const name = payerOf(c.d, dp);
        const sum = try c.money(dp.amount, dp.currency);
        if (std.mem.eql(u8, dp.status, "lost") and dp.submissions == 0 and dp.created >= since) {
            const gop = try lost.getOrPut(c.a, dp.currency);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.sum += dp.amount;
            try gop.value_ptr.rows.append(c.a, .{ .source = try c.p("dispute {s}", .{dp.id}), .value = try c.p("lost, {s}, {s}, opened {s}, no evidence was ever sent", .{ sum, name, try c.date(dp.created) }) });
            continue;
        }
        if (!dp.needsAnswer()) continue;
        const why = reasonOf(dp.reason);
        const paid_on = if (dp.charge_known and dp.charged > 0) try c.p(" made on {s}", .{try c.date(dp.charged)}) else "";
        const open = dp.due_by != null and !dp.past_due and dp.due_by.? > c.now;
        const until = if (dp.due_by) |due|
            (if (open)
                try c.p("It can be answered until {s}, {d} day{s} from now.", .{ try c.date(due), @divFloor(due - c.now, day_s), if (@divFloor(due - c.now, day_s) == 1) "" else "s" })
            else
                try c.p("The time to answer ended on {s}.", .{try c.date(due)}))
        else
            "The provider gives no day to answer by.";
        const what = if (dp.inquiry())
            try c.p("The bank of {s} asks about a payment of {s}{s}: {s}. It is an inquiry, not yet money taken back. {s}", .{ name, sum, paid_on, why.says, until })
        else if (std.mem.eql(u8, dp.status, "appeal_needs_response"))
            try c.p("The dispute over a payment of {s}{s} from {s} is in appeal ({s}). {s}", .{ sum, paid_on, name, why.says, until })
        else
            try c.p("The bank of {s} took back a payment of {s}{s}: {s}. {s}", .{ name, sum, paid_on, why.says, until });
        var rows: std.ArrayList(Row) = .empty;
        try rows.append(c.a, .{ .source = try c.p("dispute {s}", .{dp.id}), .value = try c.p("status {s}, reason {s}{s}, opened {s}, evidence kept at the provider {s}, sent to the bank {d} time{s}", .{
            dp.status,
            if (dp.reason.len > 0) dp.reason else "not given",
            if (dp.code.len > 0) try c.p(" ({s} code {s})", .{ if (dp.brand.len > 0) dp.brand else "network", dp.code }) else "",
            try c.date(dp.created),
            if (dp.has_evidence) "yes" else "no",
            dp.submissions,
            if (dp.submissions == 1) "" else "s",
        }) });
        if (dp.charge_known) try rows.append(c.a, .{ .source = try c.p("charge {s}", .{dp.charge}), .value = try c.p("{s}{s}{s}{s}", .{
            if (dp.charged > 0) try c.p("paid {s}", .{try c.date(dp.charged)}) else "paid",
            if (dp.description.len > 0) try c.p(", for \"{s}\"", .{dp.description}) else "",
            if (dp.payer_name.len > 0) try c.p(", card of {s}", .{dp.payer_name}) else "",
            if (dp.payer_email.len > 0) try c.p(" <{s}>", .{dp.payer_email}) else "",
        }) });
        if (earlierOf(c, dp.customer)) |e| {
            try rows.append(c.a, .{ .source = try c.p("customer {s}", .{dp.customer}), .value = if (e.paid > 0)
                try c.p("{d} earlier payment{s} since {s}, none disputed or refunded", .{ e.paid, if (e.paid == 1) "" else "s", try c.date(e.first) })
            else
                "no earlier payment that was neither disputed nor refunded" });
        }
        const email = if (c.emailOf(dp.customer).len > 0) c.emailOf(dp.customer) else dp.payer_email;
        try c.add(.{
            .kind = .dispute,
            .key = try c.p("dispute:{s}", .{dp.id}),
            .customer = dp.customer,
            .name = name,
            .amount = dp.amount,
            .currency = dp.currency,
            .per = .once,
            .what = what,
            .rows = rows.items,
            .due = if (open) dp.due_by else null,
            .proposal = if (!open and dp.due_by != null)
                "Nothing more can be sent to the bank. If the payment was right, the customer can still be asked to pay again."
            else if (dp.inquiry())
                try c.p("Answer the bank, or refund the payment: either can end it before it becomes a dispute with a fee. The bank wants to see {s}. The evidence draft has what the account already shows; sending it is final, and yours to do at the provider.", .{why.wants})
            else
                try c.p("Answer once, and in time: an answer is taken one time only. The bank wants to see {s}. The evidence draft has what the account already shows; sending it is final, and yours to do at the provider. If the cardholder is right, accept it there instead.", .{why.wants}),
            .letter = if (email.len == 0 or !open) null else .{
                .to = email,
                .subject = "A question from your bank about a payment to us",
                .body = try c.p("Hello,\n\nYour bank has asked us about a payment to us of {s}{s}{s}. If you did not recognise it, that is what it was.\n\nIf something about it is not right, reply to this message and we will put it right with you directly, which is quicker than through the bank. If it was a mistake at the bank's end, telling them the payment is yours ends it.", .{ sum, paid_on, if (dp.description.len > 0) try c.p(": it was for \"{s}\"", .{dp.description}) else "" }),
            },
        });
    }
    var it = lost.iterator();
    while (it.next()) |kv| {
        const n = kv.value_ptr.rows.items.len;
        try c.add(.{
            .kind = .disputes_unanswered,
            .key = try c.p("disputes_unanswered:{s}", .{kv.key_ptr.*}),
            .customer = "",
            .name = try c.p("{d} dispute{s}", .{ n, if (n == 1) "" else "s" }),
            .amount = kv.value_ptr.sum,
            .currency = kv.key_ptr.*,
            .per = .once,
            .what = try c.p("{d} dispute{s} in the last {d} days, {s} together, {s} lost without an answer ever being sent to the bank.", .{ n, if (n == 1) "" else "s", c.r.dispute_days, try c.money(kv.value_ptr.sum, kv.key_ptr.*), if (n == 1) "was" else "were" }),
            .rows = kv.value_ptr.rows.items,
            .proposal = "Nothing brings these back, and this is a count, not money to collect. It is what not answering cost: a reading every week shows the next dispute while there is still time. Dismiss it once you have seen it.",
        });
    }
}

// ---- with the business's own file ----

fn customerOf(c: *Ctx, row: who.Row) ?model.Customer {
    if (row.customer.len > 0) {
        for (c.d.customers) |cu| if (std.mem.eql(u8, cu.id, row.customer)) return cu;
        // an id the customer list didn't have may still have subscriptions
        for (c.d.subscriptions) |sub| if (std.mem.eql(u8, sub.customer, row.customer)) return .{ .id = row.customer };
        return null;
    }
    var found: ?model.Customer = null;
    for (c.d.customers) |cu| {
        if (cu.email.len > 0 and std.ascii.eqlIgnoreCase(cu.email, row.email)) {
            // two customers with one address: the first with a live subscription
            if (found == null or liveSub(c, cu.id) != null and liveSub(c, found.?.id) == null) found = cu;
        }
    }
    return found;
}

fn liveSub(c: *Ctx, customer: []const u8) ?model.Subscription {
    for (c.d.subscriptions) |sub| if (sub.live() and std.mem.eql(u8, sub.customer, customer)) return sub;
    return null;
}

pub const Hit = struct { item: model.Item, customer: []const u8 };

/// The one metered item of the live subscription of the customer a row of
/// the business's file names: where its use is reported. Null when the
/// customer isn't found, has no live subscription, or has no single meter.
pub fn meteredItem(d: Data, row: who.Row) ?Hit {
    var c: Ctx = .{ .a = undefined, .d = d, .r = .{}, .now = 0 };
    const cu = customerOf(&c, row) orelse return null;
    const sub = liveSub(&c, cu.id) orelse return null;
    var found: ?model.Item = null;
    for (sub.items) |it| if (it.price.metered) {
        if (found != null) return null;
        found = it;
    };
    return .{ .item = found orelse return null, .customer = cu.id };
}

fn planPrice(c: *Ctx, plan: []const u8) ?model.Price {
    for (c.r.plans) |pl| {
        if (!std.ascii.eqlIgnoreCase(pl.name, plan)) continue;
        for (c.d.prices) |pr| if (pr.is(pl.price)) return pr;
    }
    return null;
}

fn whoLabel(row: who.Row) []const u8 {
    return if (row.customer.len > 0) row.customer else row.email;
}

fn whoRows(c: *Ctx) !void {
    for (c.d.rows) |row| {
        if (!row.active) continue;
        const src = try c.p("the business's file, line {d}", .{row.line});
        const plan_price = if (row.plan.len > 0) planPrice(c, row.plan) else null;
        const wanted: ?i64 = if (plan_price) |pp| (if (pp.monthly()) |m| m * (row.seats orelse 1) else null) else null;
        const cu = customerOf(c, row) orelse {
            try c.add(.{
                .kind = .no_customer,
                .key = try c.p("no_customer:{s}", .{whoLabel(row)}),
                .customer = row.customer,
                .name = whoLabel(row),
                .amount = wanted orelse 0,
                .currency = if (plan_price) |pp| pp.currency else "",
                .per = if (wanted != null and wanted.? > 0) .month else .unknown,
                .what = try c.p("{s} is active in the product and is not a customer in billing.", .{whoLabel(row)}),
                .rows = try c.rows(&.{
                    .{ .source = src, .value = try c.p("active yes, plan {s}, seats {s}", .{ if (row.plan.len > 0) row.plan else "not given", if (row.seats) |n| try c.p("{d}", .{n}) else "not given" }) },
                    .{ .source = "the billing provider", .value = "no customer with this id or address" },
                }),
                .proposal = "Check the id or address in your file first. If it is right, this account was never set up to be billed.",
            });
            continue;
        };
        const sub = liveSub(c, cu.id) orelse {
            var state: []const u8 = "no subscription";
            for (c.d.subscriptions) |x| if (std.mem.eql(u8, x.customer, cu.id)) {
                state = try c.p("subscription {s} is {s}", .{ x.id, @tagName(x.status) });
            };
            try c.add(.{
                .kind = .not_paying,
                .key = try c.p("not_paying:{s}", .{cu.id}),
                .customer = cu.id,
                .name = cu.label(),
                .amount = wanted orelse 0,
                .currency = if (plan_price) |pp| pp.currency else "",
                .per = if (wanted != null and wanted.? > 0) .month else .unknown,
                .what = try c.p("{s} is active in the product, and in billing {s}.", .{ cu.label(), state }),
                .rows = try c.rows(&.{
                    .{ .source = src, .value = try c.p("active yes, plan {s}", .{if (row.plan.len > 0) row.plan else "not given"}) },
                    .{ .source = try c.p("customer {s}", .{cu.id}), .value = state },
                }),
                .proposal = "Either the product should have closed this account, or billing should have kept it. Decide which, and ask the customer before anything is charged.",
                .letter = try c.letter(cu.id, "Your account", "Your account with us is still active, and it has no running subscription. Would you like to keep using it? If so we will set the subscription up again; if not, we will close the account.\n\nNothing is charged before you answer.", .{}),
            });
            continue;
        };
        try seatsAndPlan(c, row, cu, sub, src, plan_price);
        try usage(c, row, cu, sub, src);
    }
}

fn seatsAndPlan(c: *Ctx, row: who.Row, cu: model.Customer, sub: model.Subscription, src: []const u8, plan_price: ?model.Price) !void {
    // the item the seats are billed on: the plan's own price if the
    // subscription has it, else its only fixed-quantity item
    var item: ?model.Item = null;
    var fixed: usize = 0;
    for (sub.items) |it| {
        if (it.price.metered) continue;
        fixed += 1;
        if (plan_price) |pp| if (std.mem.eql(u8, it.price.id, pp.id)) {
            item = it;
        };
    }
    if (item == null and fixed == 1) {
        for (sub.items) |it| if (!it.price.metered) {
            item = it;
        };
    }
    const it = item orelse return;
    const qty = it.quantity orelse 1;
    if (plan_price) |pp| {
        // another price of the same product (paid by the year, or an old
        // price) is the same plan
        const same_plan = std.mem.eql(u8, pp.id, it.price.id) or (pp.product.len > 0 and std.mem.eql(u8, pp.product, it.price.product));
        if (!same_plan) {
            const new_m = pp.monthly();
            const old_m = it.price.monthly();
            if (new_m != null and old_m != null and new_m.? > old_m.?) {
                const seats = row.seats orelse qty;
                try c.add(.{
                    .kind = .higher_plan,
                    .key = try c.p("higher_plan:{s}", .{sub.id}),
                    .customer = cu.id,
                    .name = cu.label(),
                    .amount = (new_m.? - old_m.?) * seats,
                    .currency = sub.currency,
                    .per = .month,
                    .what = try c.p("{s} has the plan \"{s}\" in the product and is billed for {s}.", .{ cu.label(), row.plan, it.price.label() }),
                    .rows = try c.rows(&.{
                        .{ .source = src, .value = try c.p("plan {s} (price {s}, {s} a unit a month)", .{ row.plan, pp.id, try c.money(new_m.?, sub.currency) }) },
                        .{ .source = try c.p("subscription item {s}", .{it.id}), .value = try c.p("price {s}, {s} a unit a month, quantity {d}", .{ it.price.id, try c.money(old_m.?, sub.currency), qty }) },
                    }),
                    .proposal = "Move the subscription to the plan the customer has, from the next period, and tell them first. Or put the product back to the plan they pay for.",
                    .change = .{ .set_price = .{ .item = it.id, .to = pp.id, .was = it.price.id } },
                    .does = try c.p("Move subscription item {s} from {s} to {s}, keeping its quantity: the next invoice is at the new price. Nothing is charged for the time already invoiced.", .{ it.id, it.price.label(), pp.label() }),
                    .letter = try c.letter(cu.id, "Your plan", "Your account has the plan \"{s}\", and your subscription is for {s}. From your next billing period we would like to bill the plan you have: {s} instead of {s} a unit a month.\n\nIf you would rather go back to {s}, reply to this message and we will change the account instead.", .{ row.plan, it.price.label(), try c.money(new_m.?, sub.currency), try c.money(old_m.?, sub.currency), it.price.label() }),
                });
                // the seats are judged on the plan they should be on, once
                return;
            }
        }
    }
    const seats = row.seats orelse return;
    if (seats <= qty) return;
    const unit = it.price.monthly();
    try c.add(.{
        .kind = .more_seats,
        .key = try c.p("more_seats:{s}:{s}", .{ sub.id, it.id }),
        .customer = cu.id,
        .name = cu.label(),
        .amount = if (unit) |u| u * (seats - qty) else 0,
        .currency = sub.currency,
        .per = if (unit != null) .month else .unknown,
        .what = try c.p("{s} has {d} seats in the product and pays for {d}.", .{ cu.label(), seats, qty }),
        .rows = try c.rows(&.{
            .{ .source = src, .value = try c.p("seats {d}", .{seats}) },
            .{ .source = try c.p("subscription item {s}", .{it.id}), .value = try c.p("price {s}, quantity {d}, {s} a unit a month", .{ it.price.id, qty, if (unit) |u| try c.money(u, sub.currency) else "not one amount" }) },
        }),
        .proposal = "Set the quantity to the seats in use from the next period, and tell the customer first.",
        .change = .{ .set_quantity = .{ .item = it.id, .to = seats, .was = qty } },
        .does = try c.p("Set the quantity of subscription item {s} from {d} to {d}: the next invoice is for {d}. Nothing is charged for the time already invoiced.", .{ it.id, qty, seats, seats }),
        .letter = try c.letter(cu.id, "The seats on your subscription", "Your account has {d} seats in use, and your subscription covers {d}. From your next billing period we would like to set it to {d} seats{s}.\n\nIf some of those seats should not be there, tell us before then and we will take them off.", .{ seats, qty, seats, if (unit) |u| try c.p(" ({s} a seat a month)", .{try c.money(u, sub.currency)}) else "" }),
    });
}

fn usage(c: *Ctx, row: who.Row, cu: model.Customer, sub: model.Subscription, src: []const u8) !void {
    const used = row.usage orelse return;
    if (used <= 0) return;
    var metered: ?model.Item = null;
    var count: usize = 0;
    for (sub.items) |it| if (it.price.metered) {
        metered = it;
        count += 1;
    };
    if (count == 0) {
        try c.add(.{
            .kind = .usage_not_reported,
            .key = try c.p("usage_not_reported:{s}", .{sub.id}),
            .customer = cu.id,
            .name = cu.label(),
            .currency = sub.currency,
            .what = try c.p("{s} used {d} this period in the product, and nothing on its subscription is billed by use.", .{ cu.label(), used }),
            .rows = try c.rows(&.{
                .{ .source = src, .value = try c.p("usage {d}", .{used}) },
                .{ .source = try c.p("subscription {s}", .{sub.id}), .value = "no item with a metered price" },
            }),
            .proposal = "If use is included in the plan, dismiss this as intended. Otherwise the subscription lacks its metered price.",
        });
        return;
    }
    // more than one meter: which the file's number belongs to isn't known
    if (count != 1) return;
    const it = metered.?;
    var reported: ?f64 = null;
    for (c.d.usage) |u| if (std.mem.eql(u8, u.item, it.id)) {
        reported = u.value;
    };
    const told = reported orelse return;
    const margin = told * @as(f64, @floatFromInt(c.r.usage_margin_percent)) / 100.0;
    if (used <= told + margin) return;
    const missing = used - told;
    var amount: ?i64 = null;
    if (it.price.unit_amount) |ua| if (!it.price.tiered) {
        amount = @intFromFloat(@round(missing * @as(f64, @floatFromInt(ua))));
    };
    try c.add(.{
        .kind = .usage_not_reported,
        .key = try c.p("usage_not_reported:{s}:{s}", .{ sub.id, it.id }),
        .customer = cu.id,
        .name = cu.label(),
        .amount = amount orelse 0,
        .currency = sub.currency,
        .per = if (amount != null) .once else .unknown,
        .what = try c.p("{s} used {d} this period in the product; billing was told of {d}.", .{ cu.label(), used, told }),
        .rows = try c.rows(&.{
            .{ .source = src, .value = try c.p("usage {d}", .{used}) },
            .{ .source = try c.p("meter {s}, subscription item {s}", .{ it.price.meter, it.id }), .value = try c.p("reported {d} from {s} to now, {s} a unit", .{ told, try c.date(it.period_start), if (it.price.unit_amount) |ua| try c.money(ua, sub.currency) else "not one amount" }) },
        }),
        .proposal = "Find why the use wasn't reported (a job that stopped, a customer id that doesn't match) before the period closes; use reported in time is billed with no correction to make.",
    });
}

/// The sums a report opens with, per currency.
pub const Total = struct { currency: []const u8, monthly: i64 = 0, once: i64 = 0 };

pub fn totals(a: Allocator, findings: []const Finding) ![]Total {
    var out: std.ArrayList(Total) = .empty;
    for (findings) |f| {
        if (f.per == .unknown) continue;
        const slot = for (out.items) |*x| {
            if (std.ascii.eqlIgnoreCase(x.currency, f.currency)) break x;
        } else blk: {
            try out.append(a, .{ .currency = f.currency });
            break :blk &out.items[out.items.len - 1];
        };
        if (f.per == .month) slot.monthly += f.amount else slot.once += f.amount;
    }
    return out.items;
}

// ---- tests ----

const t = std.testing;
const now_t: i64 = 1795392000; // 2026-11-23

fn daysAgo(n: i64) i64 {
    return now_t - n * day_s;
}

const team: model.Price = .{ .id = "price_team", .product = "prod_team", .currency = "eur", .unit_amount = 1200, .recurring = true, .lookup_key = "team_monthly" };
const pro: model.Price = .{ .id = "price_pro", .product = "prod_pro", .currency = "eur", .unit_amount = 2900, .recurring = true, .lookup_key = "pro_monthly" };
const team_2023: model.Price = .{ .id = "price_team_2023", .product = "prod_team", .active = false, .currency = "eur", .unit_amount = 900, .recurring = true, .nickname = "Team 2023" };
const api: model.Price = .{ .id = "price_api", .product = "prod_api", .currency = "eur", .unit_amount = 2, .recurring = true, .metered = true, .meter = "mtr_calls" };
const launch: model.Coupon = .{ .id = "co_launch", .name = "Launch", .percent_bp = 2500, .duration = .forever };
const friend: model.Coupon = .{ .id = "co_friend", .name = "Friends", .percent_bp = 10000, .duration = .forever };

fn find(fs: []const Finding, kind: Kind, customer: []const u8) ?Finding {
    for (fs) |f| if (f.kind == kind and std.mem.eql(u8, f.customer, customer)) return f;
    return null;
}

test "a_discount_with_no_end_is_asked_about_once_it_is_old" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subs = [_]model.Subscription{
        // 25% off five seats of 12.00, for two years: 15.00 a month
        .{ .id = "sub_old", .customer = "cus_a", .status = .active, .created = daysAgo(800), .currency = "eur", .items = &.{.{ .id = "si_1", .price = team, .quantity = 5 }}, .discounts = &.{.{ .id = "di_1", .coupon = launch, .coupon_known = true, .start = daysAgo(800) }} },
        // the same discount, three months old: not yet
        .{ .id = "sub_new", .customer = "cus_b", .status = .active, .created = daysAgo(90), .currency = "eur", .items = &.{.{ .id = "si_2", .price = team, .quantity = 5 }}, .discounts = &.{.{ .id = "di_2", .coupon = launch, .coupon_known = true, .start = daysAgo(90) }} },
        // one that ends, however old: not this rule's
        .{ .id = "sub_ends", .customer = "cus_c", .status = .active, .created = daysAgo(800), .currency = "eur", .items = &.{.{ .id = "si_3", .price = team, .quantity = 5 }}, .discounts = &.{.{ .id = "di_3", .coupon = launch, .coupon_known = true, .start = daysAgo(800), .end = now_t + 30 * day_s }} },
        // cancelled: nothing to ask
        .{ .id = "sub_gone", .customer = "cus_d", .status = .canceled, .created = daysAgo(800), .currency = "eur", .items = &.{.{ .id = "si_4", .price = team, .quantity = 5 }}, .discounts = &.{.{ .id = "di_4", .coupon = launch, .coupon_known = true, .start = daysAgo(800) }} },
        // a discount whose coupon wasn't read: found, its amount not known
        .{ .id = "sub_dim", .customer = "cus_e", .status = .active, .created = daysAgo(800), .currency = "eur", .items = &.{.{ .id = "si_5", .price = team, .quantity = 5 }}, .discounts = &.{.{ .id = "di_5", .start = daysAgo(800) }} },
    };
    const fs = try run(a, .{ .subscriptions = &subs, .customers = &.{.{ .id = "cus_a", .name = "Alder Works" }}, .prices = &.{team} }, .{}, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    const f = find(fs, .discount_no_end, "cus_a").?;
    try t.expectEqual(@as(i64, 1500), f.amount);
    try t.expect(f.per == .month);
    try t.expectEqualStrings("discount_no_end:sub_old:di_1", f.key);
    try t.expect(std.mem.indexOf(u8, f.what, "Alder Works") != null);
    try t.expect(std.mem.indexOf(u8, f.what, "25.00% off") != null);
    try t.expect(std.mem.indexOf(u8, f.rows[0].value, "60.00 EUR") != null);
    const dim = find(fs, .discount_no_end, "cus_e").?;
    try t.expect(dim.per == .unknown and dim.amount == 0);
    // the one with an amount comes first
    try t.expectEqualStrings("cus_a", fs[0].customer);
}

test "free_for_a_long_time_by_a_full_discount_or_a_price_of_zero" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero: model.Price = .{ .id = "price_zero", .product = "prod_pro", .currency = "eur", .unit_amount = 0, .recurring = true, .nickname = "Pro, comped" };
    const subs = [_]model.Subscription{
        .{ .id = "sub_friend", .customer = "cus_a", .status = .active, .created = daysAgo(400), .currency = "eur", .items = &.{.{ .id = "si_1", .price = pro, .quantity = 3 }}, .discounts = &.{.{ .id = "di_1", .coupon = friend, .coupon_known = true, .start = daysAgo(400) }} },
        .{ .id = "sub_zero", .customer = "cus_b", .status = .active, .created = daysAgo(400), .currency = "eur", .items = &.{.{ .id = "si_2", .price = zero, .quantity = 1 }} },
        // new, or in trial: not yet
        .{ .id = "sub_young", .customer = "cus_c", .status = .active, .created = daysAgo(10), .currency = "eur", .items = &.{.{ .id = "si_3", .price = zero, .quantity = 1 }} },
        .{ .id = "sub_trial", .customer = "cus_d", .status = .trialing, .created = daysAgo(400), .currency = "eur", .items = &.{.{ .id = "si_4", .price = zero, .quantity = 1 }} },
    };
    const fs = try run(a, .{ .subscriptions = &subs, .prices = &.{ pro, zero } }, .{}, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    // the full discount is one finding, not also "a discount with no end"
    const gift = find(fs, .free, "cus_a").?;
    try t.expectEqual(@as(i64, 8700), gift.amount);
    try t.expect(gift.per == .month);
    try t.expect(find(fs, .discount_no_end, "cus_a") == null);
    // a price of zero: what it should cost is not this audit's to say
    const z = find(fs, .free, "cus_b").?;
    try t.expect(z.per == .unknown);
    try t.expect(std.mem.indexOf(u8, z.proposal, "yours to say") != null);
}

test "invoices_never_sent_never_charged_and_written_off" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invs = [_]model.Invoice{
        .{ .id = "in_draft", .customer = "cus_a", .status = .draft, .created = daysAgo(20), .total = 48000, .amount_due = 48000, .amount_remaining = 48000, .currency = "eur" },
        .{ .id = "in_fresh", .customer = "cus_a", .status = .draft, .created = daysAgo(1), .total = 1000, .currency = "eur" },
        .{ .id = "in_zero", .customer = "cus_a", .status = .draft, .created = daysAgo(50), .total = 0, .currency = "eur" },
        .{ .id = "in_open", .number = "A-0042", .customer = "cus_b", .status = .open, .created = daysAgo(9), .total = 2900, .amount_remaining = 2900, .currency = "eur", .finalized_at = daysAgo(9) },
        // sent to be paid by hand, with no due date read: nothing to say
        .{ .id = "in_byhand", .customer = "cus_b", .status = .open, .created = daysAgo(9), .total = 2900, .amount_remaining = 2900, .currency = "eur", .collects_itself = false },
        .{ .id = "in_tried", .customer = "cus_b", .status = .open, .created = daysAgo(9), .total = 2900, .amount_remaining = 2900, .currency = "eur", .attempted = true },
        .{ .id = "in_bad1", .customer = "cus_c", .status = .uncollectible, .created = daysAgo(100), .total = 6000, .currency = "eur", .finalized_at = daysAgo(100) },
        .{ .id = "in_bad2", .customer = "cus_c", .status = .void, .created = daysAgo(40), .total = 6000, .currency = "eur", .finalized_at = daysAgo(40) },
        // voided as a draft: never sent, nothing given up
        .{ .id = "in_void_draft", .customer = "cus_c", .status = .void, .created = daysAgo(40), .total = 9900, .currency = "eur" },
        // too long ago
        .{ .id = "in_ancient", .customer = "cus_c", .status = .uncollectible, .created = daysAgo(900), .total = 6000, .currency = "eur", .finalized_at = daysAgo(900) },
    };
    const fs = try run(a, .{ .invoices = &invs }, .{}, now_t);
    // (the fourth: in_tried, a payment that failed)
    try t.expectEqual(@as(usize, 4), fs.len);
    const d = find(fs, .draft_invoice, "cus_a").?;
    try t.expectEqual(@as(i64, 48000), d.amount);
    try t.expect(d.per == .once);
    const o = find(fs, .unsent_invoice, "cus_b").?;
    try t.expect(std.mem.indexOf(u8, o.what, "A-0042") != null);
    const w = find(fs, .written_off, "cus_c").?;
    try t.expectEqual(@as(i64, 12000), w.amount);
    try t.expectEqual(@as(usize, 2), w.rows.len);
    try t.expectEqualStrings("written_off:cus_c:eur", w.key);
    // largest first among one-off amounts
    try t.expectEqualStrings("in_draft", fs[0].key["draft_invoice:".len..]);
    // a sum below the owner's line is left out
    const fewer = try run(a, .{ .invoices = &invs }, .{ .written_off_above = 12000 }, now_t);
    try t.expect(find(fewer, .written_off, "cus_c") == null);
}

test "money_owed_and_late_is_summed_for_each_customer" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = [_]model.Customer{.{ .id = "cus_a", .name = "Alder Works" }};
    const invs = [_]model.Invoice{
        // sent to be paid by hand: two past due, one not yet, one only just
        .{ .id = "in_1", .number = "A-1", .customer = "cus_a", .status = .open, .created = daysAgo(60), .total = 30000, .amount_remaining = 30000, .currency = "eur", .collects_itself = false, .due_date = daysAgo(30) },
        .{ .id = "in_2", .number = "A-2", .customer = "cus_a", .status = .open, .created = daysAgo(40), .total = 5000, .amount_remaining = 4000, .currency = "eur", .collects_itself = false, .due_date = daysAgo(10) },
        .{ .id = "in_3", .customer = "cus_a", .status = .open, .created = daysAgo(5), .total = 9900, .amount_remaining = 9900, .currency = "eur", .collects_itself = false, .due_date = now_t + 25 * day_s },
        .{ .id = "in_4", .customer = "cus_a", .status = .open, .created = daysAgo(33), .total = 700, .amount_remaining = 700, .currency = "eur", .collects_itself = false, .due_date = daysAgo(3) },
        // paid late is paid
        .{ .id = "in_5", .customer = "cus_a", .status = .paid, .created = daysAgo(90), .total = 30000, .currency = "eur", .collects_itself = false, .due_date = daysAgo(60) },
        // charged by the provider, and the card refused: one still being tried, one given up on
        .{ .id = "in_6", .number = "B-6", .customer = "cus_b", .status = .open, .created = daysAgo(4), .total = 2900, .amount_remaining = 2900, .currency = "eur", .attempted = true, .attempts = 2, .next_attempt = now_t + 3 * day_s },
        .{ .id = "in_7", .number = "B-7", .customer = "cus_b", .status = .open, .created = daysAgo(34), .total = 2900, .amount_remaining = 2900, .currency = "eur", .attempted = true, .attempts = 4 },
    };
    const fs = try run(a, .{ .customers = &cs, .invoices = &invs }, .{}, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    const o = find(fs, .overdue, "cus_a").?;
    try t.expectEqual(@as(i64, 34000), o.amount);
    try t.expect(o.per == .once);
    try t.expectEqualStrings("overdue:cus_a:eur", o.key);
    try t.expectEqualStrings("2 invoices to Alder Works, 340.00 EUR together, are past due; the oldest was due 2026-10-24.", o.what);
    try t.expectEqualStrings("due 2026-11-13, 10 days ago, remaining 40.00 EUR", o.rows[1].value);
    const f = find(fs, .failed_payment, "cus_b").?;
    try t.expectEqual(@as(i64, 5800), f.amount);
    try t.expectEqualStrings("2 payments from cus_b failed: 58.00 EUR is still owed. No further try is planned for 1 of them.", f.what);
    try t.expectEqualStrings("remaining 29.00 EUR, tried 2 times, next try 2026-11-26", f.rows[0].value);
    try t.expectEqualStrings("remaining 29.00 EUR, tried 4 times, no further try planned", f.rows[1].value);
    // the owner's own patience
    const strict = try run(a, .{ .customers = &cs, .invoices = &invs }, .{ .overdue_days = 0 }, now_t);
    try t.expectEqual(@as(i64, 34700), find(strict, .overdue, "cus_a").?.amount);
    const one = try run(a, .{ .customers = &cs, .invoices = invs[0..1] }, .{}, now_t);
    try t.expectEqualStrings("An invoice to Alder Works for 300.00 EUR has been past due since 2026-10-24.", one[0].what);
}

test "a_draft_the_provider_will_send_itself_is_given_a_day" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // seen at Stripe: a subscription's first invoice is a draft for about
    // an hour, then sent; a cancelled subscription's stays a draft
    const invs = [_]model.Invoice{
        .{ .id = "in_on_its_way", .customer = "cus_a", .status = .draft, .created = now_t - 600, .total = 4500, .currency = "eur", .auto_advance = true },
        .{ .id = "in_left", .customer = "cus_b", .status = .draft, .created = now_t - 600, .total = 5800, .currency = "eur" },
        .{ .id = "in_stuck", .customer = "cus_c", .status = .draft, .created = daysAgo(2), .total = 2900, .currency = "eur", .auto_advance = true },
    };
    const fs = try run(a, .{ .invoices = &invs }, .{ .draft_days = 0 }, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    try t.expect(find(fs, .draft_invoice, "cus_a") == null);
    try t.expect(find(fs, .draft_invoice, "cus_b") != null);
    try t.expect(find(fs, .draft_invoice, "cus_c") != null);
}

test "a_price_no_longer_sold_with_the_difference_when_one_price_replaces_it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const orphan: model.Price = .{ .id = "price_orphan", .product = "prod_gone", .active = false, .currency = "eur", .unit_amount = 500, .recurring = true };
    const dear: model.Price = .{ .id = "price_dear", .product = "prod_pro", .active = false, .currency = "eur", .unit_amount = 4900, .recurring = true };
    const subs = [_]model.Subscription{
        .{ .id = "sub_1", .customer = "cus_a", .status = .active, .created = daysAgo(900), .currency = "eur", .items = &.{.{ .id = "si_1", .price = team_2023, .quantity = 10 }} },
        .{ .id = "sub_2", .customer = "cus_b", .status = .active, .created = daysAgo(900), .currency = "eur", .items = &.{.{ .id = "si_2", .price = orphan, .quantity = 1 }} },
        // an old price that costs more than today's: no loss, not asked
        .{ .id = "sub_3", .customer = "cus_c", .status = .active, .created = daysAgo(900), .currency = "eur", .items = &.{.{ .id = "si_3", .price = dear, .quantity = 1 }} },
        .{ .id = "sub_4", .customer = "cus_d", .status = .active, .created = daysAgo(30), .currency = "eur", .items = &.{.{ .id = "si_4", .price = team, .quantity = 2 }} },
    };
    const prices = [_]model.Price{ team, pro, team_2023, orphan, dear };
    const fs = try run(a, .{ .subscriptions = &subs, .prices = &prices }, .{}, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    const f = find(fs, .old_price, "cus_a").?;
    // (12.00 - 9.00) x 10 seats
    try t.expectEqual(@as(i64, 3000), f.amount);
    try t.expect(std.mem.indexOf(u8, f.what, "Team 2023") != null and std.mem.indexOf(u8, f.what, "team_monthly") != null);
    const g = find(fs, .old_price, "cus_b").?;
    try t.expect(g.per == .unknown);
    // the owner's own price list: an active price left off it is old too
    const listed = try run(a, .{ .subscriptions = &subs, .prices = &prices }, .{ .current = &.{"pro_monthly"} }, now_t);
    try t.expect(find(listed, .old_price, "cus_d") != null);
}

test "collection_paused_past_its_date_or_with_none" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subs = [_]model.Subscription{
        .{ .id = "sub_1", .customer = "cus_a", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_1", .price = pro, .quantity = 1 }}, .pause = .{ .behavior = "void" } },
        .{ .id = "sub_2", .customer = "cus_b", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_2", .price = pro, .quantity = 1 }}, .pause = .{ .behavior = "void", .resumes_at = daysAgo(12) } },
        .{ .id = "sub_3", .customer = "cus_c", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_3", .price = pro, .quantity = 1 }}, .pause = .{ .behavior = "void", .resumes_at = now_t + 12 * day_s } },
    };
    const fs = try run(a, .{ .subscriptions = &subs, .prices = &.{pro} }, .{}, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    try t.expectEqual(@as(i64, 2900), find(fs, .paused, "cus_a").?.amount);
    try t.expect(std.mem.indexOf(u8, find(fs, .paused, "cus_b").?.what, "was to resume on 2026-11-11") != null);
}

test "the_business_file_shows_seats_plans_and_accounts_billing_cant_see" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const customers = [_]model.Customer{
        .{ .id = "cus_a", .name = "Alder Works", .email = "billing@alder.example" },
        .{ .id = "cus_b", .email = "ola@birch.example" },
        .{ .id = "cus_c", .name = "Cedar Co" },
        .{ .id = "cus_d", .name = "Dogwood" },
    };
    const subs = [_]model.Subscription{
        .{ .id = "sub_a", .customer = "cus_a", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_a", .price = team, .quantity = 5 }} },
        .{ .id = "sub_b", .customer = "cus_b", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_b", .price = team, .quantity = 4 }} },
        .{ .id = "sub_c", .customer = "cus_c", .status = .canceled, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_c", .price = pro, .quantity = 1 }} },
        .{ .id = "sub_d", .customer = "cus_d", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_d", .price = team, .quantity = 8 }} },
    };
    const rows = [_]who.Row{
        .{ .customer = "cus_a", .plan = "team", .seats = 9, .line = 2 },
        // found by address; on Pro in the product, billed for Team
        .{ .email = "OLA@birch.example", .plan = "pro", .seats = 4, .line = 3 },
        .{ .customer = "cus_c", .plan = "pro", .seats = 2, .line = 4 },
        // fewer seats in use than paid for: the customer's to notice, not ours
        .{ .customer = "cus_d", .plan = "team", .seats = 6, .line = 5 },
        .{ .email = "nobody@elm.example", .plan = "pro", .seats = 1, .line = 6 },
        // closed in the product: nothing to say whatever billing shows
        .{ .customer = "cus_zzz", .active = false, .line = 7 },
    };
    const rules: Rules = .{ .plans = &.{ .{ .name = "team", .price = "team_monthly" }, .{ .name = "pro", .price = "price_pro" } } };
    const fs = try run(a, .{ .customers = &customers, .subscriptions = &subs, .prices = &.{ team, pro }, .rows = &rows }, rules, now_t);
    try t.expectEqual(@as(usize, 4), fs.len);
    const seats = find(fs, .more_seats, "cus_a").?;
    try t.expectEqual(@as(i64, 4800), seats.amount);
    try t.expect(std.mem.indexOf(u8, seats.what, "9 seats in the product and pays for 5") != null);
    try t.expect(std.mem.indexOf(u8, seats.rows[0].source, "line 2") != null);
    const plan = find(fs, .higher_plan, "cus_b").?;
    // (29.00 - 12.00) x 4
    try t.expectEqual(@as(i64, 6800), plan.amount);
    const gone = find(fs, .not_paying, "cus_c").?;
    try t.expectEqual(@as(i64, 5800), gone.amount);
    try t.expect(std.mem.indexOf(u8, gone.what, "sub_c is canceled") != null);
    const none = find(fs, .no_customer, "").?;
    try t.expectEqual(@as(i64, 2900), none.amount);
    try t.expectEqualStrings("no_customer:nobody@elm.example", none.key);
    try t.expect(find(fs, .more_seats, "cus_d") == null);
    // the same plan paid by the year is not a higher plan
    const pro_year: model.Price = .{ .id = "price_pro_year", .product = "prod_pro", .currency = "eur", .unit_amount = 29000, .recurring = true, .interval = .year };
    const yearly = try run(a, .{
        .subscriptions = &.{.{ .id = "sub_y", .customer = "cus_y", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_y", .price = pro_year, .quantity = 1 }} }},
        .prices = &.{ pro, pro_year },
        .rows = &.{.{ .customer = "cus_y", .plan = "pro", .seats = 1, .line = 2 }},
    }, rules, now_t);
    try t.expectEqual(@as(usize, 0), yearly.len);
    // largest a month first
    try t.expect(fs[0].kind == .higher_plan);
    const sums = try totals(a, fs);
    try t.expectEqual(@as(usize, 1), sums.len);
    try t.expectEqual(@as(i64, 4800 + 6800 + 5800 + 2900), sums[0].monthly);
}

test "use_in_the_product_above_what_billing_was_told" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subs = [_]model.Subscription{
        .{ .id = "sub_a", .customer = "cus_a", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{ .{ .id = "si_a1", .price = team, .quantity = 5 }, .{ .id = "si_a2", .price = api, .period_start = daysAgo(20) } } },
        .{ .id = "sub_b", .customer = "cus_b", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{ .{ .id = "si_b1", .price = team, .quantity = 5 }, .{ .id = "si_b2", .price = api, .period_start = daysAgo(20) } } },
        .{ .id = "sub_c", .customer = "cus_c", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_c1", .price = team, .quantity = 5 }} },
        .{ .id = "sub_d", .customer = "cus_d", .status = .active, .created = daysAgo(300), .currency = "eur", .items = &.{.{ .id = "si_d2", .price = api, .period_start = daysAgo(20) }} },
    };
    const rows = [_]who.Row{
        .{ .customer = "cus_a", .usage = 15300, .line = 2 },
        // within one percent: a meter that lags a little is not a finding
        .{ .customer = "cus_b", .usage = 1005, .line = 3 },
        .{ .customer = "cus_c", .usage = 400, .line = 4 },
        // what was reported couldn't be read: nothing is claimed
        .{ .customer = "cus_d", .usage = 400, .line = 5 },
    };
    const reported = [_]Usage{ .{ .item = "si_a2", .value = 9000 }, .{ .item = "si_b2", .value = 1000 } };
    const fs = try run(a, .{ .subscriptions = &subs, .prices = &.{ team, api }, .rows = &rows, .usage = &reported }, .{}, now_t);
    try t.expectEqual(@as(usize, 2), fs.len);
    const f = find(fs, .usage_not_reported, "cus_a").?;
    // 6300 units at 0.02
    try t.expectEqual(@as(i64, 12600), f.amount);
    try t.expect(f.per == .once);
    try t.expect(std.mem.indexOf(u8, f.what, "used 15300") != null and std.mem.indexOf(u8, f.what, "told of 9000") != null);
    const n = find(fs, .usage_not_reported, "cus_c").?;
    try t.expect(n.per == .unknown);
    try t.expect(std.mem.indexOf(u8, n.rows[1].value, "no item with a metered price") != null);
}

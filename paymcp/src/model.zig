//! What the billing audit reads from the billing provider, as Stripe's API
//! has it in version 2026-11-18.endive (pinned on every request): the
//! billing period on each subscription item, `discounts` as a list with the
//! coupon under `source.coupon`, an invoice's subscription under
//! `parent.subscription_details`. Only the fields the audit uses are kept.
//! Strings point into the parsed answer (an arena's).
const std = @import("std");
const jv = @import("jv.zig");

pub const api_version = "2026-11-18.endive";

pub const Interval = enum { day, week, month, year };

/// `amount` every `count` intervals, as an amount a month (half up).
pub fn perMonth(amount: i64, interval: Interval, count: u32) i64 {
    const n: i64 = @max(count, 1);
    return switch (interval) {
        .month => divRound(amount, n),
        .year => divRound(amount, 12 * n),
        .week => divRound(amount * 52, 12 * n),
        .day => divRound(amount * 365, 12 * n),
    };
}

/// a / b to the nearest whole, halves away from zero; b > 0.
pub fn divRound(a: i64, b: i64) i64 {
    if (a >= 0) return @divFloor(2 * a + b, 2 * b);
    return -@divFloor(2 * (-a) + b, 2 * b);
}

pub const Price = struct {
    id: []const u8 = "",
    product: []const u8 = "",
    active: bool = true,
    currency: []const u8 = "",
    /// In the currency's smallest unit; null where the price doesn't have
    /// one amount (tiers, a customer-chosen amount).
    unit_amount: ?i64 = null,
    recurring: bool = false,
    interval: Interval = .month,
    interval_count: u32 = 1,
    /// Billed by use reported to a meter, not by quantity.
    metered: bool = false,
    meter: []const u8 = "",
    lookup_key: []const u8 = "",
    nickname: []const u8 = "",
    tiered: bool = false,

    /// What one unit costs a month; null when the price doesn't say.
    pub fn monthly(p: Price) ?i64 {
        const u = p.unit_amount orelse return null;
        if (p.tiered or !p.recurring) return null;
        return perMonth(u, p.interval, p.interval_count);
    }

    /// The name a person knows it by: its lookup key, its nickname, its id.
    pub fn label(p: Price) []const u8 {
        if (p.lookup_key.len > 0) return p.lookup_key;
        if (p.nickname.len > 0) return p.nickname;
        return p.id;
    }

    /// Whether `name` (an id or a lookup key) is this price.
    pub fn is(p: Price, name: []const u8) bool {
        return std.mem.eql(u8, p.id, name) or (p.lookup_key.len > 0 and std.mem.eql(u8, p.lookup_key, name));
    }
};

pub const Duration = enum { forever, once, repeating, other };

pub const Coupon = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    /// Hundredths of a percent (2550: 25.5%).
    percent_bp: ?i64 = null,
    amount_off: ?i64 = null,
    currency: []const u8 = "",
    duration: Duration = .other,
    duration_in_months: ?i64 = null,

    pub fn label(c: Coupon) []const u8 {
        return if (c.name.len > 0) c.name else c.id;
    }
};

pub const Discount = struct {
    id: []const u8 = "",
    coupon: Coupon = .{},
    /// False when the answer gave the coupon's id only (not expanded).
    coupon_known: bool = false,
    start: i64 = 0,
    /// When it stops applying; null: never.
    end: ?i64 = null,
};

pub const Item = struct {
    id: []const u8 = "",
    price: Price = .{},
    /// Null for a metered price.
    quantity: ?i64 = null,
    period_start: i64 = 0,
    period_end: i64 = 0,
};

pub const Status = enum { incomplete, incomplete_expired, trialing, active, past_due, canceled, unpaid, paused, other };

pub const Pause = struct { behavior: []const u8 = "", resumes_at: ?i64 = null };

pub const Subscription = struct {
    id: []const u8 = "",
    customer: []const u8 = "",
    status: Status = .other,
    created: i64 = 0,
    currency: []const u8 = "",
    items: []const Item = &.{},
    discounts: []const Discount = &.{},
    pause: ?Pause = null,
    cancel_at_period_end: bool = false,
    trial_end: ?i64 = null,

    /// Being billed, or about to be: active, in trial, or behind on a payment.
    pub fn live(s: Subscription) bool {
        return s.status == .active or s.status == .trialing or s.status == .past_due;
    }

    /// What its fixed-quantity items cost a month at their prices, before
    /// any discount; null when some item's price doesn't have one amount.
    pub fn listMonthly(s: Subscription) ?i64 {
        var sum: i64 = 0;
        for (s.items) |it| {
            if (it.price.metered) continue;
            const m = it.price.monthly() orelse return null;
            sum += m * (it.quantity orelse 1);
        }
        return sum;
    }

    pub fn hasMetered(s: Subscription) bool {
        for (s.items) |it| if (it.price.metered) return true;
        return false;
    }
};

pub const InvoiceStatus = enum { draft, open, paid, uncollectible, void, other };

pub const Invoice = struct {
    id: []const u8 = "",
    number: []const u8 = "",
    customer: []const u8 = "",
    status: InvoiceStatus = .other,
    created: i64 = 0,
    total: i64 = 0,
    amount_due: i64 = 0,
    amount_remaining: i64 = 0,
    currency: []const u8 = "",
    /// charge_automatically or send_invoice.
    collects_itself: bool = true,
    auto_advance: bool = false,
    attempted: bool = false,
    subscription: []const u8 = "",
    finalized_at: ?i64 = null,

    pub fn label(i: Invoice) []const u8 {
        return if (i.number.len > 0) i.number else i.id;
    }
};

pub const Customer = struct {
    id: []const u8 = "",
    email: []const u8 = "",
    name: []const u8 = "",

    pub fn label(c: Customer) []const u8 {
        if (c.name.len > 0) return c.name;
        if (c.email.len > 0) return c.email;
        return c.id;
    }
};

// ---- from the provider's JSON ----

fn strOf(v: ?jv.Value, key: []const u8) []const u8 {
    return jv.str(jv.get(v, key)) orelse "";
}

/// A field that is an id, or the whole object when it was expanded.
fn idOf(v: ?jv.Value) []const u8 {
    if (jv.str(v)) |id| return id;
    return strOf(v, "id");
}

pub fn price(v: ?jv.Value) Price {
    var p: Price = .{
        .id = strOf(v, "id"),
        .product = idOf(jv.get(v, "product")),
        .active = jv.boolean(jv.get(v, "active")) orelse true,
        .currency = strOf(v, "currency"),
        .unit_amount = jv.int(jv.get(v, "unit_amount")),
        .lookup_key = strOf(v, "lookup_key"),
        .nickname = strOf(v, "nickname"),
        .tiered = std.mem.eql(u8, strOf(v, "billing_scheme"), "tiered"),
    };
    if (jv.get(v, "recurring")) |r| {
        p.recurring = true;
        p.interval = std.meta.stringToEnum(Interval, strOf(r, "interval")) orelse .month;
        p.interval_count = @intCast(std.math.clamp(jv.int(jv.get(r, "interval_count")) orelse 1, 1, 1000));
        p.metered = std.mem.eql(u8, strOf(r, "usage_type"), "metered");
        p.meter = strOf(r, "meter");
    }
    return p;
}

pub fn coupon(v: ?jv.Value) Coupon {
    var c: Coupon = .{
        .id = strOf(v, "id"),
        .name = strOf(v, "name"),
        .amount_off = jv.int(jv.get(v, "amount_off")),
        .currency = strOf(v, "currency"),
        .duration = std.meta.stringToEnum(Duration, strOf(v, "duration")) orelse .other,
        .duration_in_months = jv.int(jv.get(v, "duration_in_months")),
    };
    if (jv.num(jv.get(v, "percent_off"))) |pct| {
        if (pct >= 0 and pct <= 100) c.percent_bp = @intFromFloat(@round(pct * 100));
    }
    return c;
}

pub fn discount(v: ?jv.Value) Discount {
    var d: Discount = .{
        .id = idOf(v),
        .start = jv.int(jv.get(v, "start")) orelse 0,
        .end = jv.int(jv.get(v, "end")),
    };
    const src = jv.at(v, &.{ "source", "coupon" });
    if (src) |c| {
        if (c == .object) {
            d.coupon = coupon(c);
            d.coupon_known = true;
        } else d.coupon.id = jv.str(c) orelse "";
    }
    return d;
}

pub fn subscription(a: std.mem.Allocator, v: ?jv.Value) !Subscription {
    var sub: Subscription = .{
        .id = strOf(v, "id"),
        .customer = idOf(jv.get(v, "customer")),
        .status = std.meta.stringToEnum(Status, strOf(v, "status")) orelse .other,
        .created = jv.int(jv.get(v, "created")) orelse 0,
        .currency = strOf(v, "currency"),
        .cancel_at_period_end = jv.boolean(jv.get(v, "cancel_at_period_end")) orelse false,
        .trial_end = jv.int(jv.get(v, "trial_end")),
    };
    if (jv.get(v, "pause_collection")) |p| sub.pause = .{ .behavior = strOf(p, "behavior"), .resumes_at = jv.int(jv.get(p, "resumes_at")) };
    var items: std.ArrayList(Item) = .empty;
    for (jv.arr(jv.at(v, &.{ "items", "data" })) orelse &.{}) |it| {
        try items.append(a, .{
            .id = strOf(it, "id"),
            .price = price(jv.get(it, "price")),
            .quantity = jv.int(jv.get(it, "quantity")),
            .period_start = jv.int(jv.get(it, "current_period_start")) orelse 0,
            .period_end = jv.int(jv.get(it, "current_period_end")) orelse 0,
        });
    }
    sub.items = items.items;
    var ds: std.ArrayList(Discount) = .empty;
    for (jv.arr(jv.get(v, "discounts")) orelse &.{}) |d| try ds.append(a, discount(d));
    sub.discounts = ds.items;
    return sub;
}

pub fn invoice(v: ?jv.Value) Invoice {
    return .{
        .id = strOf(v, "id"),
        .number = strOf(v, "number"),
        .customer = idOf(jv.get(v, "customer")),
        .status = std.meta.stringToEnum(InvoiceStatus, strOf(v, "status")) orelse .other,
        .created = jv.int(jv.get(v, "created")) orelse 0,
        .total = jv.int(jv.get(v, "total")) orelse 0,
        .amount_due = jv.int(jv.get(v, "amount_due")) orelse 0,
        .amount_remaining = jv.int(jv.get(v, "amount_remaining")) orelse 0,
        .currency = strOf(v, "currency"),
        .collects_itself = !std.mem.eql(u8, strOf(v, "collection_method"), "send_invoice"),
        .auto_advance = jv.boolean(jv.get(v, "auto_advance")) orelse false,
        .attempted = jv.boolean(jv.get(v, "attempted")) orelse false,
        .subscription = idOf(jv.at(v, &.{ "parent", "subscription_details", "subscription" })),
        .finalized_at = jv.int(jv.at(v, &.{ "status_transitions", "finalized_at" })),
    };
}

pub fn customer(v: ?jv.Value) Customer {
    return .{ .id = strOf(v, "id"), .email = strOf(v, "email"), .name = strOf(v, "name") };
}

// ---- amounts and days, as a person reads them ----

const zero_decimal = [_][]const u8{ "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf" };
const three_decimal = [_][]const u8{ "bhd", "jod", "kwd", "omr", "tnd" };

fn decimals(currency: []const u8) u8 {
    for (zero_decimal) |c| if (std.ascii.eqlIgnoreCase(c, currency)) return 0;
    for (three_decimal) |c| if (std.ascii.eqlIgnoreCase(c, currency)) return 3;
    return 2;
}

/// "12.50 EUR", "1200 JPY", "-3.00 USD": the amount in the currency's
/// smallest unit, written whole, never rounded.
pub fn money(a: std.mem.Allocator, amount: i64, currency: []const u8) ![]const u8 {
    var cur: [8]u8 = undefined;
    const n = @min(currency.len, cur.len);
    const up = std.ascii.upperString(cur[0..n], currency[0..n]);
    const d = decimals(currency);
    const sign: []const u8 = if (amount < 0) "-" else "";
    const abs: u64 = @abs(amount);
    if (d == 0) return std.fmt.allocPrint(a, "{s}{d} {s}", .{ sign, abs, up });
    const scale: u64 = if (d == 3) 1000 else 100;
    if (d == 3) return std.fmt.allocPrint(a, "{s}{d}.{d:0>3} {s}", .{ sign, abs / scale, abs % scale, up });
    return std.fmt.allocPrint(a, "{s}{d}.{d:0>2} {s}", .{ sign, abs / scale, abs % scale, up });
}

/// "2026-11-23" (UTC) of a time in seconds.
pub fn day(a: std.mem.Allocator, t: i64) ![]const u8 {
    const days = @divFloor(t, 86400);
    // civil from days (Howard Hinnant's algorithm)
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const dd = doy - @divFloor(153 * mp + 2, 5) + 1;
    const mm = if (mp < 10) mp + 3 else mp - 9;
    const yy = yoe + era * 400 + @as(i64, if (mm <= 2) 1 else 0);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(yy)), @as(u64, @intCast(mm)), @as(u64, @intCast(dd)) });
}

/// The first second (UTC) of "2026-11-23"; null when it isn't a day.
pub fn dayStart(v: []const u8) ?i64 {
    if (v.len != 10 or v[4] != '-' or v[7] != '-') return null;
    const y0 = std.fmt.parseInt(i64, v[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, v[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, v[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    // days from civil (Howard Hinnant's algorithm)
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400;
}

const tt = std.testing;

test "a_day_and_its_first_second" {
    try tt.expectEqual(@as(?i64, 1795392000), dayStart("2026-11-23"));
    try tt.expectEqual(@as(?i64, 0), dayStart("1970-01-01"));
    try tt.expectEqual(@as(?i64, 1709164800), dayStart("2024-02-29"));
    try tt.expect(dayStart("2026-13-01") == null and dayStart("yesterday") == null);
}

test "an_amount_a_month_from_any_interval" {
    try tt.expectEqual(@as(i64, 2900), perMonth(2900, .month, 1));
    try tt.expectEqual(@as(i64, 2400), perMonth(28800, .year, 1));
    try tt.expectEqual(@as(i64, 1000), perMonth(3000, .month, 3));
    // 52 weeks over 12 months
    try tt.expectEqual(@as(i64, 4333), perMonth(1000, .week, 1));
    try tt.expectEqual(@as(i64, 3042), perMonth(100, .day, 1));
    try tt.expectEqual(@as(i64, 1), divRound(1, 2));
    try tt.expectEqual(@as(i64, -1), divRound(-1, 2));
    try tt.expectEqual(@as(i64, 0), divRound(1, 3));
}

test "a_subscription_as_the_current_api_gives_it" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"id":"sub_1","object":"subscription","customer":"cus_1","status":"active","created":1700000000,"currency":"eur",
        \\ "cancel_at_period_end":false,"trial_end":null,"pause_collection":{"behavior":"void","resumes_at":null},
        \\ "items":{"object":"list","data":[
        \\   {"id":"si_1","quantity":5,"current_period_start":1763000000,"current_period_end":1765600000,
        \\    "price":{"id":"price_team","product":"prod_team","active":true,"currency":"eur","unit_amount":1200,
        \\             "billing_scheme":"per_unit","lookup_key":"team_monthly","recurring":{"interval":"month","interval_count":1,"usage_type":"licensed","meter":null}}},
        \\   {"id":"si_2","quantity":null,"current_period_start":1763000000,"current_period_end":1765600000,
        \\    "price":{"id":"price_api","product":{"id":"prod_api","name":"API"},"active":true,"currency":"eur","unit_amount":2,
        \\             "billing_scheme":"per_unit","recurring":{"interval":"month","interval_count":1,"usage_type":"metered","meter":"mtr_1"}}}]},
        \\ "discounts":[{"id":"di_1","start":1700000000,"end":null,"source":{"type":"coupon","coupon":{"id":"co_1","name":"Launch","percent_off":25.5,"duration":"forever"}}},
        \\              "di_2"]}
    ;
    const sub = try subscription(a, jv.parse(a, text));
    try tt.expectEqualStrings("sub_1", sub.id);
    try tt.expectEqualStrings("cus_1", sub.customer);
    try tt.expect(sub.live());
    try tt.expect(sub.pause != null and sub.pause.?.resumes_at == null);
    try tt.expectEqual(@as(usize, 2), sub.items.len);
    try tt.expectEqual(@as(?i64, 5), sub.items[0].quantity);
    try tt.expectEqual(@as(i64, 1765600000), sub.items[0].period_end);
    try tt.expectEqualStrings("team_monthly", sub.items[0].price.label());
    try tt.expect(sub.items[1].price.metered);
    try tt.expectEqualStrings("mtr_1", sub.items[1].price.meter);
    try tt.expectEqualStrings("prod_api", sub.items[1].price.product);
    // the metered item isn't in the fixed monthly sum
    try tt.expectEqual(@as(?i64, 6000), sub.listMonthly());
    try tt.expect(sub.hasMetered());
    try tt.expectEqual(@as(usize, 2), sub.discounts.len);
    try tt.expect(sub.discounts[0].coupon_known);
    try tt.expectEqual(@as(?i64, 2550), sub.discounts[0].coupon.percent_bp);
    try tt.expect(sub.discounts[0].coupon.duration == .forever);
    try tt.expect(sub.discounts[0].end == null);
    // a discount given as an id only: known to be there, its coupon not read
    try tt.expectEqualStrings("di_2", sub.discounts[1].id);
    try tt.expect(!sub.discounts[1].coupon_known);
}

test "an_invoice_names_its_subscription_under_parent" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inv = invoice(jv.parse(a,
        \\{"id":"in_1","number":"A-0007","customer":"cus_1","status":"draft","created":1763000000,"total":6000,"amount_due":6000,
        \\ "amount_remaining":6000,"currency":"eur","collection_method":"charge_automatically","auto_advance":false,"attempted":false,
        \\ "parent":{"type":"subscription_details","subscription_details":{"subscription":"sub_1"}},"status_transitions":{"finalized_at":null}}
    ));
    try tt.expect(inv.status == .draft);
    try tt.expectEqualStrings("sub_1", inv.subscription);
    try tt.expectEqualStrings("A-0007", inv.label());
    try tt.expect(inv.collects_itself and !inv.attempted and inv.finalized_at == null);
    // a tiered price has no one amount
    const tiered = price(jv.parse(a, "{\"id\":\"price_t\",\"unit_amount\":null,\"billing_scheme\":\"tiered\",\"recurring\":{\"interval\":\"month\",\"interval_count\":1,\"usage_type\":\"licensed\"}}"));
    try tt.expect(tiered.monthly() == null);
}

test "amounts_and_days_are_written_whole" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tt.expectEqualStrings("12.50 EUR", try money(a, 1250, "eur"));
    try tt.expectEqualStrings("0.05 USD", try money(a, 5, "usd"));
    try tt.expectEqualStrings("1200 JPY", try money(a, 1200, "jpy"));
    try tt.expectEqualStrings("1.250 KWD", try money(a, 1250, "kwd"));
    try tt.expectEqualStrings("-3.00 PLN", try money(a, -300, "pln"));
    try tt.expectEqualStrings("2026-11-23", try day(a, 1795392000));
    try tt.expectEqualStrings("1970-01-01", try day(a, 0));
    try tt.expectEqualStrings("2024-02-29", try day(a, 1709164800));
}

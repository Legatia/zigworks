//! Reading the billing provider: GET requests only, with a key that can
//! only read, the API version pinned on each, lists followed to their end
//! (or to a limit, which is then said), and a short wait and another try
//! when the provider says it is busy. Nothing here sends anything but GET.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");
const jv = @import("jv.zig");
const model = @import("model.zig");
const config = @import("config.zig");
const audit = @import("audit.zig");
const who = @import("who.zig");

/// The most pages of one list that are read (200 x 100 records).
pub const max_pages = 200;

pub const Error = error{ Provider, OutOfMemory };

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    hc: http.Client,
    key: []const u8,
    page: u8,
    /// Why the last request failed, in a sentence.
    why: []const u8 = "",
    /// GETs sent.
    requests: u32 = 0,
    /// Waits between tries, in ms (tests: none).
    wait_ms: u32 = 1000,

    pub fn init(gpa: Allocator, io: Io, cfg: *const config.Config, key: []const u8) !Client {
        const target = http.Target.parse(cfg.url) catch return error.BadUrl;
        var hc: http.Client = .init(gpa, io, target);
        hc.user_agent = "paymcp";
        return .{ .gpa = gpa, .io = io, .hc = hc, .key = key, .page = cfg.page };
    }

    pub fn deinit(c: *Client) void {
        c.hc.deinit();
    }

    /// One GET; the parsed answer. `path` starts with /v1/.
    fn get(c: *Client, a: Allocator, path: []const u8) Error!jv.Value {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            c.requests += 1;
            const ans = http.fetch(&c.hc, a, .{
                .method = .GET,
                .path = path,
                .key = c.key,
                .headers = &.{.{ .name = "Stripe-Version", .value = model.api_version }},
                .limits = .{ .idle_ms = 20_000, .total_ms = 60_000 },
            }) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (tries < 2) {
                    c.pause(tries);
                    continue;
                }
                c.why = try std.fmt.allocPrint(a, "the billing provider couldn't be reached ({s})", .{@errorName(e)});
                return error.Provider;
            };
            if (ans.status == 200) {
                return jv.parse(a, ans.body) orelse {
                    c.why = "the billing provider's answer wasn't JSON";
                    return error.Provider;
                };
            }
            // busy, or its own trouble: a short wait, then again
            if ((ans.status == 429 or ans.status >= 500) and tries < 3) {
                c.pause(tries);
                continue;
            }
            const msg = std.mem.trimEnd(u8, jv.str(jv.at(jv.parse(a, ans.body), &.{ "error", "message" })) orelse "", ". \r\n");
            c.why = switch (ans.status) {
                401 => "the billing provider refused the key (401): it is wrong, was deleted, or is for another account",
                403 => try std.fmt.allocPrint(a, "the key may not read this (403){s}{s}", .{ if (msg.len > 0) ": " else "", msg }),
                429 => "the billing provider is still saying too many requests (429)",
                else => try std.fmt.allocPrint(a, "the billing provider answered {d}{s}{s}", .{ ans.status, if (msg.len > 0) ": " else "", msg }),
            };
            return error.Provider;
        }
    }

    fn pause(c: *Client, tries: u32) void {
        if (c.wait_ms == 0) return;
        c.io.sleep(.fromMilliseconds(@as(i64, c.wait_ms) << @intCast(@min(tries, 4))), .awake) catch {};
    }

    /// Every record of a list, newest first as the provider gives them.
    /// `complete` is false when the page limit cut it short.
    pub fn list(c: *Client, a: Allocator, path: []const u8, out: *std.ArrayList(jv.Value), complete: *bool) Error!void {
        complete.* = true;
        var after: []const u8 = "";
        var pages: u32 = 0;
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, path, '?') != null) "&" else "?";
        while (true) {
            const url = if (after.len > 0)
                try std.fmt.allocPrint(a, "{s}{s}limit={d}&starting_after={s}", .{ path, sep, c.page, after })
            else
                try std.fmt.allocPrint(a, "{s}{s}limit={d}", .{ path, sep, c.page });
            const v = try c.get(a, url);
            const data = jv.arr(jv.get(v, "data")) orelse {
                c.why = "the billing provider's answer wasn't a list";
                return error.Provider;
            };
            for (data) |x| try out.append(a, x);
            pages += 1;
            if (!(jv.boolean(jv.get(v, "has_more")) orelse false) or data.len == 0) return;
            after = jv.str(jv.get(data[data.len - 1], "id")) orelse return;
            if (pages >= max_pages) {
                complete.* = false;
                return;
            }
        }
    }

    /// Everything the audit reads. A part the key may not read (the meters)
    /// becomes a gap that is said; the lists the audit can't do without
    /// fail it.
    pub fn load(c: *Client, a: Allocator, cfg: *const config.Config, rows: []const who.Row, now: i64) Error!audit.Data {
        var gaps: std.ArrayList([]const u8) = .empty;
        var complete = true;

        var raw: std.ArrayList(jv.Value) = .empty;
        try c.list(a, "/v1/customers", &raw, &complete);
        if (!complete) try gaps.append(a, "the customer list was cut at the page limit");
        var customers: std.ArrayList(model.Customer) = .empty;
        for (raw.items) |v| try customers.append(a, model.customer(v));

        // prices sold now and prices withdrawn, asked for apart so that
        // neither depends on what the provider leaves out by default
        var prices: std.ArrayList(model.Price) = .empty;
        for ([_][]const u8{ "/v1/prices?active=true", "/v1/prices?active=false" }) |path| {
            raw = .empty;
            try c.list(a, path, &raw, &complete);
            if (!complete) try gaps.append(a, "the price list was cut at the page limit");
            for (raw.items) |v| try prices.append(a, model.price(v));
        }

        raw = .empty;
        try c.list(a, "/v1/subscriptions?status=all&expand%5B%5D=data.discounts.source.coupon", &raw, &complete);
        if (!complete) try gaps.append(a, "the subscription list was cut at the page limit");
        var subs: std.ArrayList(model.Subscription) = .empty;
        for (raw.items) |v| try subs.append(a, try model.subscription(a, v));

        var invoices: std.ArrayList(model.Invoice) = .empty;
        const since = now - @as(i64, cfg.rules.written_off_days) * 86400;
        const invoice_lists = [_][]const u8{
            "/v1/invoices?status=draft",
            "/v1/invoices?status=open",
            try std.fmt.allocPrint(a, "/v1/invoices?status=uncollectible&created%5Bgte%5D={d}", .{since}),
            try std.fmt.allocPrint(a, "/v1/invoices?status=void&created%5Bgte%5D={d}", .{since}),
        };
        for (invoice_lists) |path| {
            raw = .empty;
            try c.list(a, path, &raw, &complete);
            if (!complete) try gaps.append(a, "an invoice list was cut at the page limit");
            for (raw.items) |v| try invoices.append(a, model.invoice(v));
        }

        var data: audit.Data = .{
            .customers = customers.items,
            .subscriptions = subs.items,
            .prices = prices.items,
            .invoices = invoices.items,
            .rows = rows,
        };

        // use the provider was told of, for the customers whose own use the
        // business's file gives
        var usage: std.ArrayList(audit.Usage) = .empty;
        var meters_refused = false;
        for (rows) |row| {
            if (row.usage == null or !row.active or meters_refused) continue;
            const hit = audit.meteredItem(data, row) orelse continue;
            if (hit.item.price.meter.len == 0) continue;
            // both ends on a whole minute, as the provider wants them
            const start = @divFloor(hit.item.period_start, 60) * 60;
            const end = @divFloor(now, 60) * 60;
            if (end <= start) continue;
            raw = .empty;
            c.list(a, try std.fmt.allocPrint(a, "/v1/billing/meters/{s}/event_summaries?customer={s}&start_time={d}&end_time={d}", .{ hit.item.price.meter, hit.customer, start, end }), &raw, &complete) catch |e| {
                if (e == error.OutOfMemory) return e;
                try gaps.append(a, try std.fmt.allocPrint(a, "use reported to the meters wasn't read: {s}. \"Use that was never reported\" isn't checked", .{c.why}));
                meters_refused = true;
                continue;
            };
            var sum: f64 = 0;
            for (raw.items) |v| sum += jv.num(jv.get(v, "aggregated_value")) orelse 0;
            try usage.append(a, .{ .item = hit.item.id, .value = sum });
        }
        data.usage = usage.items;
        data.gaps = gaps.items;
        return data;
    }
};

const t = std.testing;
const sim = @import("sim.zig");

const day0: i64 = 1795392000; // 2026-11-23

const Fx = struct {
    arena: std.heap.ArenaAllocator,
    s: *sim.Sim,
    cfg: config.Config,
    c: Client,

    fn init(fx: *Fx, opts: sim.Options, page: u8) !void {
        fx.arena = .init(t.allocator);
        const a = fx.arena.allocator();
        fx.s = try sim.start(std.heap.page_allocator, t.io, opts);
        fx.cfg = .{ .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{fx.s.port}), .page = page };
        fx.c = try Client.init(t.allocator, t.io, &fx.cfg, opts.key);
        fx.c.wait_ms = 0;
    }

    fn deinit(fx: *Fx) void {
        fx.c.deinit();
        fx.arena.deinit();
    }
};

test "every_list_is_read_to_its_end_whatever_the_page" {
    var fx: Fx = undefined;
    try fx.init(.{ .key = "rk_test_sim", .now = day0 }, 2);
    defer fx.deinit();
    const a = fx.arena.allocator();
    const d = try fx.c.load(a, &fx.cfg, &.{}, day0);
    try t.expectEqual(@as(usize, sim.customer_count), d.customers.len);
    try t.expectEqual(@as(usize, sim.subscription_count), d.subscriptions.len);
    try t.expectEqual(@as(usize, sim.price_count), d.prices.len);
    try t.expectEqual(@as(usize, 0), d.gaps.len);
    // two a page: many requests, each a GET with the version pinned
    try t.expect(fx.c.requests > 12);
    try t.expectEqual(@as(u32, 0), fx.s.refused);
    // the discount's coupon came expanded
    var with_coupon = false;
    for (d.subscriptions) |sub| for (sub.discounts) |di| {
        if (di.coupon_known and di.coupon.percent_bp != null) with_coupon = true;
    };
    try t.expect(with_coupon);
    // one request with the largest page reads the same
    var big: Fx = undefined;
    try big.init(.{ .key = "rk_test_sim", .now = day0 }, 100);
    defer big.deinit();
    const d2 = try big.c.load(big.arena.allocator(), &big.cfg, &.{}, day0);
    try t.expectEqual(d.subscriptions.len, d2.subscriptions.len);
    try t.expectEqual(d.invoices.len, d2.invoices.len);
}

test "a_wrong_key_and_a_busy_provider" {
    var fx: Fx = undefined;
    try fx.init(.{ .key = "rk_test_sim", .now = day0 }, 100);
    defer fx.deinit();
    const a = fx.arena.allocator();
    // busy twice, then an answer: the read goes through
    fx.s.busy = 2;
    const d = try fx.c.load(a, &fx.cfg, &.{}, day0);
    try t.expect(d.customers.len > 0);
    // busy for good: said, not waited on for ever
    fx.s.busy = 1000;
    try t.expectError(error.Provider, fx.c.load(a, &fx.cfg, &.{}, day0));
    try t.expect(std.mem.indexOf(u8, fx.c.why, "429") != null);
    fx.s.busy = 0;
    fx.c.key = "rk_test_other";
    try t.expectError(error.Provider, fx.c.load(a, &fx.cfg, &.{}, day0));
    try t.expect(std.mem.indexOf(u8, fx.c.why, "refused the key") != null);
}

test "meters_the_key_may_not_read_are_a_gap_that_is_said" {
    var fx: Fx = undefined;
    try fx.init(.{ .key = "rk_test_sim", .now = day0, .meters = false }, 100);
    defer fx.deinit();
    const a = fx.arena.allocator();
    var diag: who.Diag = .{};
    const rows = try who.parse(a, sim.who_csv, &diag);
    const d = try fx.c.load(a, &fx.cfg, rows, day0);
    try t.expectEqual(@as(usize, 1), d.gaps.len);
    try t.expect(std.mem.indexOf(u8, d.gaps[0], "isn't checked") != null);
    try t.expectEqual(@as(usize, 0), d.usage.len);
    // with the permission, the use reported is read for the rows that give use
    var ok: Fx = undefined;
    try ok.init(.{ .key = "rk_test_sim", .now = day0 }, 100);
    defer ok.deinit();
    const d2 = try ok.c.load(ok.arena.allocator(), &ok.cfg, rows, day0);
    try t.expectEqual(@as(usize, 0), d2.gaps.len);
    try t.expect(d2.usage.len >= 1);
}

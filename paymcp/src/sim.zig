//! A stand-in for the billing provider's API, for trying paymcp and for
//! its tests: a made-up software business with twelve customers, most of
//! them with something the audit should find and three with nothing. It
//! answers the GETs paymcp sends, in the shapes of API version
//! 2026-11-18.endive, with lists in pages, `expand[]` honoured for a
//! discount's coupon, and the errors a real key meets: 401 for a wrong
//! key, 403 for anything but a GET (and for the meters, when told to), 429
//! when told to be busy. A request that doesn't pin the version is
//! refused, so that a client that forgets is found out here.
//!
//! Written from the provider's public documentation, not from its answers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sock = @import("sock.zig");
const model = @import("model.zig");

pub const Options = struct {
    port: u16 = 0,
    /// The one key it takes.
    key: []const u8,
    /// The time its records are placed around (seconds).
    now: i64,
    /// Whether the key may read the meters.
    meters: bool = true,
};

pub const customer_count = 12;
pub const subscription_count = 12;
pub const price_count = 6;

/// The business's own "who has what" file that goes with these records.
pub const who_csv =
    \\customer,email,plan,seats,usage,active
    \\cus_alder,,team,9,,yes
    \\,ola@birch.example,pro,4,,yes
    \\cus_cedar,,pro,2,,yes
    \\cus_fir,,team,5,15300,yes
    \\cus_juniper,,pro,1,,yes
    \\,nobody@maple.example,team,3,,yes
    \\cus_old,,team,2,,no
    \\
;

const Obj = struct {
    id: []const u8,
    json: []const u8,
    /// With the discounts' coupons written out (subscriptions).
    expanded: []const u8 = "",
    status: []const u8 = "",
    active: bool = true,
    created: i64 = 0,
};

pub const Sim = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    port: u16 = 0,
    lock: Io.Mutex = .init,
    customers: std.ArrayList(Obj) = .empty,
    prices: std.ArrayList(Obj) = .empty,
    subscriptions: std.ArrayList(Obj) = .empty,
    invoices: std.ArrayList(Obj) = .empty,
    /// Requests refused for what they were (not a GET, no pinned version).
    refused: u32 = 0,
    /// Answer 429 to this many requests before answering again.
    busy: u32 = 0,
    listener: sock.Listener = undefined,
};

/// Starts the sim on a thread of its own; it serves until the process ends.
pub fn start(gpa: Allocator, io: Io, opts: Options) !*Sim {
    const s = try gpa.create(Sim);
    s.* = .{ .gpa = gpa, .io = io, .opts = opts };
    try seed(s);
    s.listener = try sock.Listener.open(opts.port);
    s.port = s.listener.port;
    const th = try std.Thread.spawn(.{}, acceptLoop, .{s});
    th.detach();
    return s;
}

/// Serves on this thread (paymcp-sim).
pub fn run(gpa: Allocator, io: Io, opts: Options) !void {
    const s = try start(gpa, io, opts);
    std.log.info("billing stand-in on 127.0.0.1:{d}", .{s.port});
    while (true) io.sleep(.fromSeconds(3600), .awake) catch {};
}

fn acceptLoop(s: *Sim) void {
    while (true) {
        const conn = s.listener.accept() catch continue;
        const th = std.Thread.spawn(.{}, serve, .{ s, conn }) catch {
            sock.closeHandle(conn);
            continue;
        };
        th.detach();
    }
}

// ---- the made-up business ----

const day: i64 = 86400;

fn priceJson(a: Allocator, id: []const u8, product: []const u8, amount: i64, interval: []const u8, active: bool, lookup: []const u8, nick: []const u8, meter: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"id":"{s}","object":"price","active":{},"billing_scheme":"per_unit","created":1700000000,"currency":"eur","livemode":false,"lookup_key":{s},"nickname":{s},"product":"{s}","recurring":{{"interval":"{s}","interval_count":1,"meter":{s},"usage_type":"{s}"}},"tiers_mode":null,"type":"recurring","unit_amount":{d},"unit_amount_decimal":"{d}"}}
    , .{ id, active, try q(a, lookup), try q(a, nick), product, interval, try q(a, meter), if (meter.len > 0) "metered" else "licensed", amount, amount });
}

/// A JSON string, or null for "".
fn q(a: Allocator, v: []const u8) ![]const u8 {
    if (v.len == 0) return "null";
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(v, .{})});
}

const P = struct { id: []const u8, json: []const u8 };

const Sub = struct {
    id: []const u8,
    customer: []const u8,
    status: []const u8 = "active",
    age_days: i64,
    /// price, quantity (0: metered, no quantity)
    items: []const struct { price: usize, quantity: i64 },
    discount: ?struct { id: []const u8, coupon: []const u8, name: []const u8, percent: []const u8, age_days: i64, ends_in_days: ?i64 = null } = null,
    /// "none", "date:-12" (days from now) or "": not paused
    pause: []const u8 = "",
};

fn seed(s: *Sim) !void {
    const a = s.gpa;
    const now = s.opts.now;
    const customers = [customer_count][3][]const u8{
        .{ "cus_alder", "Alder Works", "billing@alder.example" },
        .{ "cus_birch", "Birch Studio", "ola@birch.example" },
        .{ "cus_cedar", "Cedar Co", "accounts@cedar.example" },
        .{ "cus_dogwood", "Dogwood Labs", "finance@dogwood.example" },
        .{ "cus_elm", "Elm & Sons", "office@elm.example" },
        .{ "cus_fir", "Fir Analytics", "ap@fir.example" },
        .{ "cus_gorse", "Gorse Ltd", "pay@gorse.example" },
        .{ "cus_hazel", "Hazel Design", "hello@hazel.example" },
        .{ "cus_ivy", "Ivy Partners", "ivy@ivy.example" },
        .{ "cus_juniper", "Juniper", "team@juniper.example" },
        .{ "cus_kapok", "Kapok", "kapok@kapok.example" },
        .{ "cus_larch", "Larch", "larch@larch.example" },
    };
    for (customers, 0..) |c, i| {
        const created = now - (900 - @as(i64, @intCast(i))) * day;
        try s.customers.append(a, .{ .id = c[0], .created = created, .json = try std.fmt.allocPrint(a,
            \\{{"id":"{s}","object":"customer","created":{d},"email":{f},"livemode":false,"name":{f}}}
        , .{ c[0], created, std.json.fmt(c[2], .{}), std.json.fmt(c[1], .{}) }) });
    }

    const prices = [price_count]P{
        .{ .id = "price_team", .json = try priceJson(a, "price_team", "prod_team", 1200, "month", true, "team_monthly", "", "") },
        .{ .id = "price_pro", .json = try priceJson(a, "price_pro", "prod_pro", 2900, "month", true, "pro_monthly", "", "") },
        .{ .id = "price_pro_year", .json = try priceJson(a, "price_pro_year", "prod_pro", 29000, "year", true, "pro_yearly", "", "") },
        .{ .id = "price_api", .json = try priceJson(a, "price_api", "prod_api", 2, "month", true, "", "API calls", "mtr_calls") },
        .{ .id = "price_team_2023", .json = try priceJson(a, "price_team_2023", "prod_team", 900, "month", false, "", "Team 2023", "") },
        .{ .id = "price_comped", .json = try priceJson(a, "price_comped", "prod_comped", 0, "month", true, "", "Pro, comped", "") },
    };
    for (prices, 0..) |p, i| try s.prices.append(a, .{ .id = p.id, .json = p.json, .active = i != 4 });

    const subs = [subscription_count]Sub{
        // 25% off for two years with no end; nine seats in the product, five paid
        .{ .id = "sub_alder", .customer = "cus_alder", .age_days = 800, .items = &.{.{ .price = 0, .quantity = 5 }}, .discount = .{ .id = "di_alder", .coupon = "co_launch", .name = "Launch", .percent = "25.0", .age_days = 800 } },
        // on Pro in the product, billed for Team
        .{ .id = "sub_birch", .customer = "cus_birch", .age_days = 300, .items = &.{.{ .price = 0, .quantity = 4 }} },
        // cancelled here, still active in the product
        .{ .id = "sub_cedar", .customer = "cus_cedar", .status = "canceled", .age_days = 500, .items = &.{.{ .price = 1, .quantity = 2 }} },
        // on a price withdrawn in 2024
        .{ .id = "sub_dogwood", .customer = "cus_dogwood", .age_days = 900, .items = &.{.{ .price = 4, .quantity = 10 }} },
        // everything off, for good
        .{ .id = "sub_elm", .customer = "cus_elm", .age_days = 400, .items = &.{.{ .price = 1, .quantity = 3 }}, .discount = .{ .id = "di_elm", .coupon = "co_friends", .name = "Friends", .percent = "100.0", .age_days = 400 } },
        // metered: used 15300, reported 9000
        .{ .id = "sub_fir", .customer = "cus_fir", .age_days = 350, .items = &.{ .{ .price = 0, .quantity = 5 }, .{ .price = 3, .quantity = 0 } } },
        // collection paused, with no date to resume
        .{ .id = "sub_gorse", .customer = "cus_gorse", .age_days = 600, .items = &.{.{ .price = 1, .quantity = 1 }}, .pause = "none" },
        .{ .id = "sub_hazel", .customer = "cus_hazel", .age_days = 200, .items = &.{.{ .price = 1, .quantity = 1 }} },
        .{ .id = "sub_ivy", .customer = "cus_ivy", .status = "canceled", .age_days = 700, .items = &.{.{ .price = 1, .quantity = 2 }} },
        // nothing to find: a yearly plan with a discount that ends
        .{ .id = "sub_juniper", .customer = "cus_juniper", .age_days = 450, .items = &.{.{ .price = 2, .quantity = 1 }}, .discount = .{ .id = "di_juniper", .coupon = "co_welcome", .name = "Welcome", .percent = "10.0", .age_days = 450, .ends_in_days = 60 } },
        // nothing to find: in trial
        .{ .id = "sub_kapok", .customer = "cus_kapok", .status = "trialing", .age_days = 5, .items = &.{.{ .price = 0, .quantity = 2 }} },
        // nothing to find yet: a price of zero, ten days old
        .{ .id = "sub_larch", .customer = "cus_larch", .age_days = 10, .items = &.{.{ .price = 5, .quantity = 1 }} },
    };
    for (subs) |sub| {
        const created = now - sub.age_days * day;
        const period_start = now - 20 * day;
        const period_end = now + 10 * day;
        var items: std.ArrayList(u8) = .empty;
        for (sub.items, 0..) |it, i| {
            if (i > 0) try items.append(a, ',');
            try items.print(a,
                \\{{"id":"si_{s}_{d}","object":"subscription_item","created":{d},"current_period_end":{d},"current_period_start":{d},"discounts":[],"price":{s},"quantity":{s},"subscription":"{s}"}}
            , .{ sub.id[4..], i + 1, created, period_end, period_start, prices[it.price].json, if (it.quantity == 0) "null" else try std.fmt.allocPrint(a, "{d}", .{it.quantity}), sub.id });
        }
        var ids: []const u8 = "[]";
        var full: []const u8 = "[]";
        if (sub.discount) |d| {
            const start_t = now - d.age_days * day;
            const end_t: []const u8 = if (d.ends_in_days) |n| try std.fmt.allocPrint(a, "{d}", .{now + n * day}) else "null";
            ids = try std.fmt.allocPrint(a, "[\"{s}\"]", .{d.id});
            full = try std.fmt.allocPrint(a,
                \\[{{"id":"{s}","object":"discount","customer":"{s}","end":{s},"promotion_code":null,"source":{{"coupon":{{"id":"{s}","object":"coupon","amount_off":null,"currency":null,"duration":"{s}","duration_in_months":{s},"name":"{s}","percent_off":{s},"valid":true}},"type":"coupon"}},"start":{d},"subscription":"{s}"}}]
            , .{ d.id, sub.customer, end_t, d.coupon, if (d.ends_in_days == null) "forever" else "repeating", if (d.ends_in_days == null) "null" else "17", d.name, d.percent, start_t, sub.id });
        }
        var pause: []const u8 = "null";
        if (std.mem.eql(u8, sub.pause, "none")) pause = "{\"behavior\":\"void\",\"resumes_at\":null}";
        const head = try std.fmt.allocPrint(a,
            \\{{"id":"{s}","object":"subscription","billing_mode":{{"type":"flexible"}},"cancel_at_period_end":false,"collection_method":"charge_automatically","created":{d},"currency":"eur","customer":"{s}","items":{{"object":"list","data":[{s}],"has_more":false,"url":"/v1/subscription_items?subscription={s}"}},"livemode":false,"pause_collection":{s},"status":"{s}","trial_end":null,"discounts":
        , .{ sub.id, created, sub.customer, items.items, sub.id, pause, sub.status });
        try s.subscriptions.append(a, .{
            .id = sub.id,
            .status = sub.status,
            .created = created,
            .json = try std.fmt.allocPrint(a, "{s}{s}}}", .{ head, ids }),
            .expanded = try std.fmt.allocPrint(a, "{s}{s}}}", .{ head, full }),
        });
    }

    const Inv = struct { id: []const u8, number: []const u8, customer: []const u8, status: []const u8, age_days: i64, total: i64, finalized: bool, attempted: bool = false, sub: []const u8 = "" };
    const invoices = [_]Inv{
        .{ .id = "in_gorse_draft", .number = "", .customer = "cus_gorse", .status = "draft", .age_days = 20, .total = 48000, .finalized = false },
        .{ .id = "in_hazel_open", .number = "FH-0412", .customer = "cus_hazel", .status = "open", .age_days = 9, .total = 2900, .finalized = true, .sub = "sub_hazel" },
        .{ .id = "in_ivy_bad", .number = "FH-0371", .customer = "cus_ivy", .status = "uncollectible", .age_days = 100, .total = 6000, .finalized = true, .attempted = true, .sub = "sub_ivy" },
        .{ .id = "in_ivy_void", .number = "FH-0398", .customer = "cus_ivy", .status = "void", .age_days = 40, .total = 6000, .finalized = true, .attempted = true, .sub = "sub_ivy" },
        // voided while still a draft: never sent, nothing given up
        .{ .id = "in_ivy_never", .number = "", .customer = "cus_ivy", .status = "void", .age_days = 40, .total = 9900, .finalized = false },
        .{ .id = "in_alder_paid", .number = "FH-0420", .customer = "cus_alder", .status = "paid", .age_days = 12, .total = 4500, .finalized = true, .attempted = true, .sub = "sub_alder" },
    };
    for (invoices) |inv| {
        const created = now - inv.age_days * day;
        const open = std.mem.eql(u8, inv.status, "open") or std.mem.eql(u8, inv.status, "draft");
        try s.invoices.append(a, .{ .id = inv.id, .status = inv.status, .created = created, .json = try std.fmt.allocPrint(a,
            \\{{"id":"{s}","object":"invoice","amount_due":{d},"amount_paid":{d},"amount_remaining":{d},"attempt_count":{d},"attempted":{},"auto_advance":false,"collection_method":"charge_automatically","created":{d},"currency":"eur","customer":"{s}","due_date":null,"livemode":false,"number":{s},"parent":{s},"status":"{s}","status_transitions":{{"finalized_at":{s},"marked_uncollectible_at":null,"paid_at":null,"voided_at":null}},"total":{d}}}
        , .{
            inv.id,                                                                                                                                                                                                         inv.total,
            if (std.mem.eql(u8, inv.status, "paid")) inv.total else 0,                                                                                                                                                       if (open) inv.total else 0,
            @as(u8, if (inv.attempted) 1 else 0),                                                                                                                                                                            inv.attempted,
            created,                                                                                                                                                                                                         inv.customer,
            try q(a, inv.number),                                                                                                                                                                                            if (inv.sub.len > 0) try std.fmt.allocPrint(a, "{{\"type\":\"subscription_details\",\"quote_details\":null,\"subscription_details\":{{\"metadata\":{{}},\"subscription\":\"{s}\"}}}}", .{inv.sub}) else "null",
            inv.status,                                                                                                                                                                                                      if (inv.finalized) try std.fmt.allocPrint(a, "{d}", .{created}) else "null",
            inv.total,
        }) });
    }
}

/// Use reported to the meter in the current period, a customer.
fn reported(customer: []const u8) f64 {
    if (std.mem.eql(u8, customer, "cus_fir")) return 9000;
    return 0;
}

// ---- HTTP ----

const Req = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    auth: []const u8 = "",
    version: []const u8 = "",
};

const Res = struct { status: u16, body: []const u8 = "" };

fn serve(s: *Sim, conn: sock.Handle) void {
    defer sock.closeHandle(conn);
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(s.io, conn, &rbuf, &wbuf, 60_000);
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const req = readRequest(a, &sk.reader) catch return orelse return;
        const res = blk: {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            break :blk handle(s, a, req) catch Res{ .status = 500, .body = "{\"error\":{\"type\":\"api_error\",\"message\":\"sim error\"}}" };
        };
        writeResponse(&sk.writer, res) catch return;
        sk.writer.flush() catch return;
    }
}

fn readRequest(a: Allocator, r: *Io.Reader) !?Req {
    const line = (try r.takeDelimiter('\n')) orelse return null;
    const first = std.mem.trimEnd(u8, line, "\r");
    if (first.len == 0) return null;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = try a.dupe(u8, parts.next() orelse return error.BadRequest);
    const target = try a.dupe(u8, parts.next() orelse return error.BadRequest);
    const qm = std.mem.indexOfScalar(u8, target, '?');
    var req: Req = .{ .method = method, .path = target[0 .. qm orelse target.len], .query = if (qm) |i| target[i + 1 ..] else "" };
    var length: usize = 0;
    while (true) {
        const h = std.mem.trimEnd(u8, (try r.takeDelimiter('\n')) orelse return error.BadRequest, "\r");
        if (h.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        const name = std.mem.trim(u8, h[0..colon], " ");
        const value = try a.dupe(u8, std.mem.trim(u8, h[colon + 1 ..], " \t"));
        if (std.ascii.eqlIgnoreCase(name, "content-length")) length = std.fmt.parseInt(usize, value, 10) catch 0;
        if (std.ascii.eqlIgnoreCase(name, "authorization")) req.auth = value;
        if (std.ascii.eqlIgnoreCase(name, "stripe-version")) req.version = value;
    }
    if (length > 1 << 20) return error.BadRequest;
    if (length > 0) {
        const body = try a.alloc(u8, length);
        try r.readSliceAll(body);
    }
    return req;
}

fn writeResponse(w: *Io.Writer, res: Res) !void {
    const reason: []const u8 = switch (res.status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        429 => "Too Many Requests",
        else => "Status",
    };
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\n", .{ res.status, reason, res.body.len });
    if (res.status == 429) try w.writeAll("Stripe-Should-Retry: true\r\nStripe-Rate-Limited-Reason: global-rate\r\n");
    try w.writeAll("\r\n");
    try w.writeAll(res.body);
}

fn err(a: Allocator, status: u16, kind: []const u8, code: []const u8, message: []const u8) !Res {
    return .{ .status = status, .body = try std.fmt.allocPrint(a, "{{\"error\":{{\"type\":\"{s}\",\"code\":{s},\"message\":{f}}}}}", .{ kind, try q(a, code), std.json.fmt(message, .{}) }) };
}

/// The value of `key` in a query string, percent-decoded ("" when absent).
fn param(a: Allocator, query: []const u8, key: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = try decode(a, kv[0..eq]);
        if (std.mem.eql(u8, k, key)) return decode(a, kv[eq + 1 ..]);
    }
    return "";
}

fn hasParam(a: Allocator, query: []const u8, key: []const u8, value: []const u8) !bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, try decode(a, kv[0..eq]), key) and std.mem.eql(u8, try decode(a, kv[eq + 1 ..]), value)) return true;
    }
    return false;
}

fn decode(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] == '%' and i + 2 < v.len) {
            const byte = std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16) catch {
                try out.append(a, v[i]);
                continue;
            };
            try out.append(a, byte);
            i += 2;
        } else if (v[i] == '+') {
            try out.append(a, ' ');
        } else try out.append(a, v[i]);
    }
    return out.items;
}

fn handle(s: *Sim, a: Allocator, req: Req) !Res {
    if (!std.mem.startsWith(u8, req.auth, "Bearer ") or !std.mem.eql(u8, req.auth[7..], s.opts.key))
        return err(a, 401, "invalid_request_error", "", "Invalid API Key provided.");
    if (!std.mem.eql(u8, req.method, "GET")) {
        s.refused += 1;
        return err(a, 403, "invalid_request_error", "", "The provided key does not have the required permissions for this endpoint. This key can only read.");
    }
    if (!std.mem.eql(u8, req.version, model.api_version)) {
        s.refused += 1;
        return err(a, 400, "invalid_request_error", "", "The stand-in answers version " ++ model.api_version ++ " only: pin it with the Stripe-Version header.");
    }
    if (s.busy > 0) {
        s.busy -= 1;
        return err(a, 429, "invalid_request_error", "rate_limit", "Too many requests hit the API too quickly.");
    }
    const p = req.path;
    if (std.mem.eql(u8, p, "/v1/customers")) return page(s, a, req, s.customers.items, "/v1/customers", .any);
    if (std.mem.eql(u8, p, "/v1/prices")) return page(s, a, req, s.prices.items, "/v1/prices", .active);
    if (std.mem.eql(u8, p, "/v1/subscriptions")) return page(s, a, req, s.subscriptions.items, "/v1/subscriptions", .subscription);
    if (std.mem.eql(u8, p, "/v1/invoices")) return page(s, a, req, s.invoices.items, "/v1/invoices", .invoice);
    const meters = "/v1/billing/meters/";
    if (std.mem.startsWith(u8, p, meters) and std.mem.endsWith(u8, p, "/event_summaries")) {
        if (!s.opts.meters) return err(a, 403, "invalid_request_error", "", "The provided key does not have the required permissions for this endpoint. Having the 'billing_meter_event_read' permission would allow this request to continue.");
        const meter = p[meters.len .. p.len - "/event_summaries".len];
        if (!std.mem.eql(u8, meter, "mtr_calls")) return err(a, 404, "invalid_request_error", "resource_missing", "No such billing meter.");
        const customer = try param(a, req.query, "customer");
        const st = std.fmt.parseInt(i64, try param(a, req.query, "start_time"), 10) catch return err(a, 400, "invalid_request_error", "", "start_time is required.");
        const en = std.fmt.parseInt(i64, try param(a, req.query, "end_time"), 10) catch return err(a, 400, "invalid_request_error", "", "end_time is required.");
        if (customer.len == 0) return err(a, 400, "invalid_request_error", "", "customer is required.");
        if (@mod(st, 60) != 0 or @mod(en, 60) != 0) return err(a, 400, "invalid_request_error", "", "start_time and end_time must align with minute boundaries.");
        const used = reported(customer);
        const data: []const u8 = if (used > 0) try std.fmt.allocPrint(a, "{{\"id\":\"mtrusg_1\",\"object\":\"billing.meter_event_summary\",\"aggregated_value\":{d},\"end_time\":{d},\"livemode\":false,\"meter\":\"mtr_calls\",\"start_time\":{d}}}", .{ used, en, st }) else "";
        return .{ .status = 200, .body = try std.fmt.allocPrint(a, "{{\"object\":\"list\",\"data\":[{s}],\"has_more\":false,\"url\":\"{s}\"}}", .{ data, p }) };
    }
    return err(a, 404, "invalid_request_error", "", "Unrecognized request URL.");
}

const Filter = enum { any, active, subscription, invoice };

fn page(s: *Sim, a: Allocator, req: Req, all: []const Obj, url: []const u8, filter: Filter) !Res {
    _ = s;
    var limit: usize = 10;
    const lim = try param(a, req.query, "limit");
    if (lim.len > 0) {
        limit = std.fmt.parseInt(usize, lim, 10) catch 0;
        if (limit < 1 or limit > 100) return err(a, 400, "invalid_request_error", "", "limit must be between 1 and 100.");
    }
    const status = try param(a, req.query, "status");
    const active = try param(a, req.query, "active");
    const since = std.fmt.parseInt(i64, try param(a, req.query, "created[gte]"), 10) catch std.math.minInt(i64);
    const expand = try hasParam(a, req.query, "expand[]", "data.discounts.source.coupon");
    const after = try param(a, req.query, "starting_after");
    var out: std.ArrayList(u8) = .empty;
    var started = after.len == 0;
    var count: usize = 0;
    var more = false;
    var found_after = after.len == 0;
    for (all) |o| {
        if (!started) {
            if (std.mem.eql(u8, o.id, after)) {
                started = true;
                found_after = true;
            }
            continue;
        }
        if (o.created < since) continue;
        switch (filter) {
            .any => {},
            .active => if (active.len > 0 and (o.active != std.mem.eql(u8, active, "true"))) continue,
            .subscription => {
                // with no status asked for, cancelled ones are left out
                if (status.len == 0 and std.mem.eql(u8, o.status, "canceled")) continue;
                if (status.len > 0 and !std.mem.eql(u8, status, "all") and !std.mem.eql(u8, status, o.status)) continue;
            },
            .invoice => if (status.len > 0 and !std.mem.eql(u8, status, o.status)) continue,
        }
        if (count == limit) {
            more = true;
            break;
        }
        if (count > 0) try out.append(a, ',');
        try out.appendSlice(a, if (expand and o.expanded.len > 0) o.expanded else o.json);
        count += 1;
    }
    if (!found_after) return err(a, 400, "invalid_request_error", "resource_missing", "No such object for starting_after.");
    return .{ .status = 200, .body = try std.fmt.allocPrint(a, "{{\"object\":\"list\",\"data\":[{s}],\"has_more\":{},\"url\":\"{s}\"}}", .{ out.items, more, url }) };
}

const t = std.testing;

test "queries_are_decoded" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("100", try param(a, "status=all&created%5Bgte%5D=100&limit=2", "created[gte]"));
    try t.expect(try hasParam(a, "expand%5B%5D=data.customer&expand%5B%5D=data.discounts.source.coupon", "expand[]", "data.discounts.source.coupon"));
    try t.expectEqualStrings("", try param(a, "limit=2", "starting_after"));
    try t.expectEqualStrings("a b%", try decode(a, "a+b%"));
}

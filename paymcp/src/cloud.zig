//! Reading what was spent, day by day, for the bill watch: Anthropic's and
//! OpenAI's cost reports (an organisation's admin key each) and AWS's Cost
//! Explorer (an access key that may call GetCostAndUsage and nothing
//! else). Each is asked for whole days before today, a line at a time: a
//! model, a line of the bill, a service.
//!
//! It only reads. Anthropic and OpenAI get GETs to their cost reports; AWS
//! gets one signed POST, which is how its reads are sent (and which AWS
//! charges USD 0.01 for). A provider that can't be read is a gap that is
//! said, not a failure of the rest.
//!
//! Written from the providers' documentation as read on 2026-11-27, and
//! tried against the stand-in only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");
const jv = @import("jv.zig");
const model = @import("model.zig");
const config = @import("config.zig");
const bills = @import("bills.zig");

pub const anthropic_version = "2023-06-01";
pub const aws_target = "AWSInsightsIndexService.GetCostAndUsage";
pub const aws_content_type = "application/x-amz-json-1.1";

/// The keys, from the environment: never from the pay file.
pub const Keys = struct {
    anthropic: []const u8 = "",
    openai: []const u8 = "",
    aws_id: []const u8 = "",
    aws_secret: []const u8 = "",
    aws_token: []const u8 = "",

    pub fn any(k: Keys) bool {
        return k.anthropic.len > 0 or k.openai.len > 0 or (k.aws_id.len > 0 and k.aws_secret.len > 0);
    }
};

pub const Reading = struct {
    costs: []const bills.Cost = &.{},
    /// The first day read; today is not read.
    first: i64 = 0,
    now: i64 = 0,
    /// The providers that were read.
    read: []const []const u8 = &.{},
    /// What wasn't read, and why.
    gaps: []const []const u8 = &.{},
    requests: u32 = 0,
};

pub const providers = [_][]const u8{ "anthropic", "openai", "aws" };

const day_s = bills.day_s;

const Ctx = struct {
    gpa: Allocator,
    a: Allocator,
    io: Io,
    out: std.ArrayList(bills.Cost) = .empty,
    requests: u32 = 0,
    /// Waits between tries, in ms (tests: none).
    wait_ms: u32 = 1000,
    why: []const u8 = "",

    /// One request; the parsed answer, or error.Provider with `why` set.
    fn ask(c: *Ctx, hc: *http.Client, who: []const u8, req: http.Request) !jv.Value {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            c.requests += 1;
            const ans = http.fetch(hc, c.a, req) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (tries < 2) {
                    c.pause(tries);
                    continue;
                }
                c.why = try std.fmt.allocPrint(c.a, "{s} couldn't be reached ({s})", .{ who, @errorName(e) });
                return error.Provider;
            };
            if (ans.status == 200) return jv.parse(c.a, ans.body) orelse {
                c.why = try std.fmt.allocPrint(c.a, "{s}'s answer wasn't JSON", .{who});
                return error.Provider;
            };
            if ((ans.status == 429 or ans.status >= 500) and tries < 3) {
                c.pause(tries);
                continue;
            }
            const v = jv.parse(c.a, ans.body);
            const msg = std.mem.trimEnd(u8, jv.str(jv.at(v, &.{ "error", "message" })) orelse jv.str(jv.get(v, "message")) orelse jv.str(jv.get(v, "Message")) orelse "", ". \r\n");
            c.why = switch (ans.status) {
                401 => try std.fmt.allocPrint(c.a, "{s} refused the key (401): it is wrong, was deleted, or is not the kind that reads an organisation's costs", .{who}),
                403 => try std.fmt.allocPrint(c.a, "the key may not read {s}'s costs (403){s}{s}", .{ who, if (msg.len > 0) ": " else "", msg }),
                else => try std.fmt.allocPrint(c.a, "{s} answered {d}{s}{s}", .{ who, ans.status, if (msg.len > 0) ": " else "", if (msg.len > 200) msg[0..200] else msg }),
            };
            return error.Provider;
        }
    }

    fn pause(c: *Ctx, tries: u32) void {
        if (c.wait_ms == 0) return;
        c.io.sleep(.fromMilliseconds(@as(i64, c.wait_ms) << @intCast(@min(tries, 4))), .awake) catch {};
    }

    fn add(c: *Ctx, day: i64, provider: []const u8, line: []const u8, amount: f64, currency: []const u8) !void {
        if (amount == 0 or !std.math.isFinite(amount)) return;
        // (a line of one day in several parts, as input and output tokens, is one line)
        for (c.out.items) |*x| if (x.day == day and std.mem.eql(u8, x.provider, provider) and std.mem.eql(u8, x.line, line) and std.mem.eql(u8, x.currency, currency)) {
            x.amount += amount;
            return;
        };
        try c.out.append(c.a, .{ .day = day, .provider = provider, .line = try c.a.dupe(u8, line), .amount = amount, .currency = try std.ascii.allocLowerString(c.a, currency) });
    }
};

fn client(c: *Ctx, url: []const u8) !http.Client {
    const target = http.Target.parse(url) catch {
        c.why = try std.fmt.allocPrint(c.a, "{s} isn't an address paymcp can reach", .{url});
        return error.Provider;
    };
    var hc: http.Client = .init(c.gpa, c.io, target);
    hc.user_agent = "paymcp";
    return hc;
}

const limits: http.Limits = .{ .idle_ms = 20_000, .total_ms = 60_000 };

fn anthropic(c: *Ctx, url: []const u8, key: []const u8, first: i64, today: i64) !void {
    var hc = try client(c, url);
    defer hc.deinit();
    var page: []const u8 = "";
    var pages: u32 = 0;
    while (pages < 20) : (pages += 1) {
        const path = try std.fmt.allocPrint(c.a, "/v1/organizations/cost_report?starting_at={s}T00:00:00Z&ending_at={s}T00:00:00Z&group_by%5B%5D=description&limit=31{s}{s}", .{ try model.day(c.a, first), try model.day(c.a, today), if (page.len > 0) "&page=" else "", page });
        const v = try c.ask(&hc, "Anthropic", .{ .method = .GET, .path = path, .headers = &.{ .{ .name = "x-api-key", .value = key }, .{ .name = "anthropic-version", .value = anthropic_version } }, .limits = limits });
        const data = jv.arr(jv.get(v, "data")) orelse {
            c.why = "Anthropic's answer wasn't a cost report";
            return error.Provider;
        };
        for (data) |bucket| {
            const start = jv.str(jv.get(bucket, "starting_at")) orelse continue;
            const day = model.dayStart(start[0..@min(start.len, 10)]) orelse continue;
            for (jv.arr(jv.get(bucket, "results")) orelse &.{}) |r| {
                // the amount is a decimal string in cents
                const amount = std.fmt.parseFloat(f64, jv.str(jv.get(r, "amount")) orelse continue) catch continue;
                const line = jv.str(jv.get(r, "model")) orelse jv.str(jv.get(r, "description")) orelse jv.str(jv.get(r, "cost_type")) orelse "other";
                try c.add(day, "anthropic", line, amount, jv.str(jv.get(r, "currency")) orelse "usd");
            }
        }
        if (!(jv.boolean(jv.get(v, "has_more")) orelse false)) return;
        page = jv.str(jv.get(v, "next_page")) orelse return;
    }
}

fn openai(c: *Ctx, url: []const u8, key: []const u8, first: i64, today: i64) !void {
    var hc = try client(c, url);
    defer hc.deinit();
    var page: []const u8 = "";
    var pages: u32 = 0;
    while (pages < 20) : (pages += 1) {
        const path = try std.fmt.allocPrint(c.a, "/v1/organization/costs?start_time={d}&end_time={d}&bucket_width=1d&group_by=line_item&limit=180{s}{s}", .{ first, today, if (page.len > 0) "&page=" else "", page });
        const v = try c.ask(&hc, "OpenAI", .{ .method = .GET, .path = path, .key = key, .limits = limits });
        const data = jv.arr(jv.get(v, "data")) orelse {
            c.why = "OpenAI's answer wasn't a cost report";
            return error.Provider;
        };
        for (data) |bucket| {
            const start = jv.int(jv.get(bucket, "start_time")) orelse continue;
            const day = @divFloor(start, day_s) * day_s;
            for (jv.arr(jv.get(bucket, "results")) orelse &.{}) |r| {
                // the value is a number in the currency itself (0.06 usd); here: its smallest unit
                const value = jv.num(jv.at(r, &.{ "amount", "value" })) orelse continue;
                try c.add(day, "openai", jv.str(jv.get(r, "line_item")) orelse "other", value * 100, jv.str(jv.at(r, &.{ "amount", "currency" })) orelse "usd");
            }
        }
        if (!(jv.boolean(jv.get(v, "has_more")) orelse false)) return;
        page = jv.str(jv.get(v, "next_page")) orelse return;
    }
}

fn aws(c: *Ctx, url: []const u8, keys: Keys, first: i64, today: i64, now: i64) !void {
    var hc = try client(c, url);
    defer hc.deinit();
    const target = http.Target.parse(url) catch unreachable;
    const host = if (target.port != @as(u16, if (target.https) 443 else 80)) try std.fmt.allocPrint(c.a, "{s}:{d}", .{ target.host, target.port }) else target.host;
    var token: []const u8 = "";
    var pages: u32 = 0;
    while (pages < 20) : (pages += 1) {
        const body = try std.fmt.allocPrint(c.a, "{{\"TimePeriod\":{{\"Start\":\"{s}\",\"End\":\"{s}\"}},\"Granularity\":\"DAILY\",\"Metrics\":[\"UnblendedCost\"],\"GroupBy\":[{{\"Type\":\"DIMENSION\",\"Key\":\"SERVICE\"}}]{s}}}", .{ try model.day(c.a, first), try model.day(c.a, today), if (token.len > 0) try std.fmt.allocPrint(c.a, ",\"NextPageToken\":{f}", .{std.json.fmt(token, .{})}) else "" });
        const stamp = try amzDate(c.a, now);
        var signed: std.ArrayList([2][]const u8) = .empty;
        try signed.append(c.a, .{ "content-type", aws_content_type });
        try signed.append(c.a, .{ "host", host });
        try signed.append(c.a, .{ "x-amz-date", stamp });
        if (keys.aws_token.len > 0) try signed.append(c.a, .{ "x-amz-security-token", keys.aws_token });
        try signed.append(c.a, .{ "x-amz-target", aws_target });
        const auth = try sigv4(c.a, .{ .method = "POST", .path = "/", .headers = signed.items, .payload = body, .stamp = stamp, .region = "us-east-1", .service = "ce", .id = keys.aws_id, .secret = keys.aws_secret });
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(c.a, .{ .name = "X-Amz-Date", .value = stamp });
        try headers.append(c.a, .{ .name = "X-Amz-Target", .value = aws_target });
        if (keys.aws_token.len > 0) try headers.append(c.a, .{ .name = "X-Amz-Security-Token", .value = keys.aws_token });
        try headers.append(c.a, .{ .name = "Authorization", .value = auth });
        const v = try c.ask(&hc, "AWS", .{ .method = .POST, .path = "/", .body = body, .content_type = aws_content_type, .headers = headers.items, .limits = limits });
        const data = jv.arr(jv.get(v, "ResultsByTime")) orelse {
            c.why = "AWS's answer wasn't a cost report";
            return error.Provider;
        };
        for (data) |bucket| {
            const day = model.dayStart(jv.str(jv.at(bucket, &.{ "TimePeriod", "Start" })) orelse continue) orelse continue;
            for (jv.arr(jv.get(bucket, "Groups")) orelse &.{}) |g| {
                const names = jv.arr(jv.get(g, "Keys")) orelse continue;
                if (names.len == 0) continue;
                // the amount is a decimal string in the currency itself
                const amount = std.fmt.parseFloat(f64, jv.str(jv.at(g, &.{ "Metrics", "UnblendedCost", "Amount" })) orelse continue) catch continue;
                try c.add(day, "aws", jv.str(names[0]) orelse "other", amount * 100, jv.str(jv.at(g, &.{ "Metrics", "UnblendedCost", "Unit" })) orelse "usd");
            }
        }
        token = jv.str(jv.get(v, "NextPageToken")) orelse return;
        if (token.len == 0) return;
    }
}

/// What the providers named in the pay file cost on each whole day of the
/// last `rules.days`. A provider with no key, or one that can't be read,
/// is a gap. error.Failed with `why` set when nothing at all was read.
pub fn read(gpa: Allocator, a: Allocator, io: Io, cfg: *const config.Config, keys: Keys, now: i64, wait_ms: u32, why: *[]const u8) !Reading {
    var c: Ctx = .{ .gpa = gpa, .a = a, .io = io, .wait_ms = wait_ms };
    const today = @divFloor(now, day_s) * day_s;
    const first = today - @as(i64, cfg.bills.days) * day_s;
    var done: std.ArrayList([]const u8) = .empty;
    var gaps: std.ArrayList([]const u8) = .empty;
    for (cfg.bills_read) |p| {
        const who = bills.label(p);
        const got: anyerror!void = if (std.mem.eql(u8, p, "anthropic"))
            (if (keys.anthropic.len == 0) missing(&c, "ANTHROPIC_ADMIN_KEY") else anthropic(&c, cfg.anthropic_url, keys.anthropic, first, today))
        else if (std.mem.eql(u8, p, "openai"))
            (if (keys.openai.len == 0) missing(&c, "OPENAI_ADMIN_KEY") else openai(&c, cfg.openai_url, keys.openai, first, today))
        else
            (if (keys.aws_id.len == 0 or keys.aws_secret.len == 0) missing(&c, "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY") else aws(&c, cfg.aws_url, keys, first, today, now));
        if (got) |_| {
            try done.append(a, p);
        } else |e| {
            if (e != error.Provider) return e;
            // (what a provider gave before it failed is not half a reading: it is left out)
            var kept: std.ArrayList(bills.Cost) = .empty;
            for (c.out.items) |x| if (!std.mem.eql(u8, x.provider, p)) try kept.append(a, x);
            c.out = kept;
            try gaps.append(a, try std.fmt.allocPrint(a, "{s} wasn't read: {s}", .{ who, c.why }));
        }
    }
    if (done.items.len == 0) {
        why.* = if (gaps.items.len > 0) try std.mem.join(a, "; ", gaps.items) else "the pay file's [bills] read names no provider";
        return error.Failed;
    }
    return .{ .costs = c.out.items, .first = first, .now = now, .read = done.items, .gaps = gaps.items, .requests = c.requests };
}

fn missing(c: *Ctx, name: []const u8) !void {
    c.why = try std.fmt.allocPrint(c.a, "{s} isn't set", .{name});
    return error.Provider;
}

// ---- AWS's request signing (Signature Version 4) ----

/// "20261127T101500Z" of a time in seconds.
pub fn amzDate(a: Allocator, now: i64) ![]const u8 {
    const d = try model.day(a, now);
    const s: u64 = @intCast(@mod(now, day_s));
    return std.fmt.allocPrint(a, "{s}{s}{s}T{d:0>2}{d:0>2}{d:0>2}Z", .{ d[0..4], d[5..7], d[8..10], s / 3600, (s / 60) % 60, s % 60 });
}

pub const Signing = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8 = "",
    /// The headers that are signed: names in lower case, in the names'
    /// order, "host" and "x-amz-date" among them.
    headers: []const [2][]const u8,
    payload: []const u8,
    /// As amzDate gives it.
    stamp: []const u8,
    region: []const u8,
    service: []const u8,
    id: []const u8,
    secret: []const u8,
};

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

fn hexOf(a: Allocator, bytes: [32]u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

/// The value of the Authorization header for a request.
pub fn sigv4(a: Allocator, s: Signing) ![]const u8 {
    var canonical: std.ArrayList(u8) = .empty;
    try canonical.print(a, "{s}\n{s}\n{s}\n", .{ s.method, s.path, s.query });
    var names: std.ArrayList(u8) = .empty;
    for (s.headers, 0..) |h, i| {
        try canonical.print(a, "{s}:{s}\n", .{ h[0], std.mem.trim(u8, h[1], " ") });
        try names.print(a, "{s}{s}", .{ if (i > 0) ";" else "", h[0] });
    }
    var digest: [32]u8 = undefined;
    Sha256.hash(s.payload, &digest, .{});
    try canonical.print(a, "\n{s}\n{s}", .{ names.items, try hexOf(a, digest) });
    Sha256.hash(canonical.items, &digest, .{});
    const date = s.stamp[0..8];
    const scope = try std.fmt.allocPrint(a, "{s}/{s}/{s}/aws4_request", .{ date, s.region, s.service });
    const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ s.stamp, scope, try hexOf(a, digest) });
    var k1: [32]u8 = undefined;
    var k2: [32]u8 = undefined;
    Hmac.create(&k1, date, try std.fmt.allocPrint(a, "AWS4{s}", .{s.secret}));
    Hmac.create(&k2, s.region, &k1);
    Hmac.create(&k1, s.service, &k2);
    Hmac.create(&k2, "aws4_request", &k1);
    var sig: [32]u8 = undefined;
    Hmac.create(&sig, to_sign, &k2);
    return std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ s.id, scope, names.items, try hexOf(a, sig) });
}

const t = std.testing;

test "a_request_signed_as_aws_documents_it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the example of AWS's own documentation of Signature Version 4
    const auth = try sigv4(a, .{
        .method = "GET",
        .path = "/",
        .query = "Action=ListUsers&Version=2010-05-08",
        .headers = &.{ .{ "content-type", "application/x-www-form-urlencoded; charset=utf-8" }, .{ "host", "iam.amazonaws.com" }, .{ "x-amz-date", "20150830T123600Z" } },
        .payload = "",
        .stamp = "20150830T123600Z",
        .region = "us-east-1",
        .service = "iam",
        .id = "AKIDEXAMPLE",
        .secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    });
    try t.expectEqualStrings("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7", auth);
    try t.expectEqualStrings("20261127T101505Z", try amzDate(a, 1795737600 + 10 * 3600 + 15 * 60 + 5));
}

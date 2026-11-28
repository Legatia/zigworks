//! The bill watch: what cloud services and AI models cost, day by day, set
//! against the days before by fixed rules. It finds a day far above the
//! usual for its weekday (and above the days around it: a rise that stays
//! is the next rule's), a line (a model, a service) whose week cost twice
//! the week before, and a month on its way past the budget.
//!
//! Everything here is sums over what was read (cloud.zig reads it): no
//! limit is lowered, no key withdrawn and nothing stopped. Today is never
//! counted: the providers' figures for a day come in late.
const std = @import("std");
const Allocator = std.mem.Allocator;
const audit = @import("audit.zig");
const model = @import("model.zig");

pub const Rules = struct {
    /// How many days back are read (the rules want five weeks).
    days: u32 = 35,
    /// A day this many times the usual for its weekday is asked about; 0: not looked for.
    jump: u32 = 3,
    /// ...when it is also this much above it, in the currency's smallest unit.
    jump_above: i64 = 500,
    /// A line whose week cost twice the week before, by at least this much; 0: not looked for.
    doubled_above: i64 = 1000,
    /// The month's budget for everything read, in the smallest unit; 0: none.
    budget: i64 = 0,
    /// The currency the budget is in; costs in another are left out of it.
    currency: []const u8 = "usd",
};

/// What one line cost on one day.
pub const Cost = struct {
    /// The day's first second (UTC).
    day: i64,
    /// anthropic, openai or aws.
    provider: []const u8,
    /// A model, a service, a line of the bill: as the provider names it.
    line: []const u8,
    /// In the currency's smallest unit; a day's line can be a part of one.
    amount: f64,
    currency: []const u8,
};

pub const day_s: i64 = 86400;

/// The provider as a person knows it.
pub fn label(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "anthropic")) return "Anthropic";
    if (std.mem.eql(u8, provider, "openai")) return "OpenAI";
    if (std.mem.eql(u8, provider, "aws")) return "AWS";
    return provider;
}

/// An amount to the smallest unit, as a person reads it.
pub fn money(a: Allocator, amount: f64, currency: []const u8) ![]const u8 {
    return model.money(a, cents(amount), currency);
}

fn cents(amount: f64) i64 {
    if (!(amount > -9.0e15 and amount < 9.0e15)) return 0;
    return @intFromFloat(@round(amount));
}

const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };

/// The weekday of a day (1970-01-01 was a Thursday).
pub fn weekday(day: i64) []const u8 {
    return weekdays[@intCast(@mod(@divFloor(day, day_s), 7))];
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// What `provider` cost on `day` in `currency`, all lines or one.
fn sumOf(costs: []const Cost, provider: []const u8, currency: []const u8, line: ?[]const u8, from: i64, to: i64) f64 {
    var sum: f64 = 0;
    for (costs) |c| {
        if (c.day < from or c.day > to) continue;
        if (provider.len > 0 and !eql(c.provider, provider)) continue;
        if (!eql(c.currency, currency)) continue;
        if (line) |l| if (!eql(c.line, l)) continue;
        sum += c.amount;
    }
    return sum;
}

/// What `provider` cost from day `from` to day `to`, in `currency`.
pub fn spent(costs: []const Cost, provider: []const u8, currency: []const u8, from: i64, to: i64) f64 {
    return sumOf(costs, provider, currency, null, from, to);
}

/// What `provider` cost in the month `now` is in, before today.
pub fn monthSoFar(a: Allocator, costs: []const Cost, provider: []const u8, currency: []const u8, first: i64, now: i64) !f64 {
    const today = @divFloor(now, day_s) * day_s;
    const mo = try monthOf(a, today);
    return sumOf(costs, provider, currency, null, @max(mo.start, first), today - day_s);
}

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const n = values.len;
    if (n == 0) return 0;
    return if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2;
}

pub const Pair = struct { provider: []const u8, currency: []const u8 };
const Line = struct { provider: []const u8, currency: []const u8, line: []const u8 };

pub fn pairs(a: Allocator, costs: []const Cost) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    for (costs) |c| {
        for (out.items) |p| {
            if (eql(p.provider, c.provider) and eql(p.currency, c.currency)) break;
        } else try out.append(a, .{ .provider = c.provider, .currency = c.currency });
    }
    return out.items;
}

fn lines(a: Allocator, costs: []const Cost) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    for (costs) |c| {
        for (out.items) |p| {
            if (eql(p.provider, c.provider) and eql(p.currency, c.currency) and eql(p.line, c.line)) break;
        } else try out.append(a, .{ .provider = c.provider, .currency = c.currency, .line = c.line });
    }
    return out.items;
}

/// A day's first second, the month it is in ("2026-11"), and how many
/// days that month has left from that day on (the day itself counted).
const Month = struct { name: []const u8, start: i64, days_left: i64 };

fn monthOf(a: Allocator, day: i64) !Month {
    const text = try model.day(a, day);
    const y = std.fmt.parseInt(i64, text[0..4], 10) catch 1970;
    const m = std.fmt.parseInt(i64, text[5..7], 10) catch 1;
    const start = model.dayStart(try std.fmt.allocPrint(a, "{s}-01", .{text[0..7]})) orelse day;
    const next = model.dayStart(try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-01", .{ @as(u64, @intCast(if (m == 12) y + 1 else y)), @as(u64, @intCast(if (m == 12) 1 else m + 1)) })) orelse day + day_s;
    return .{ .name = text[0..7], .start = start, .days_left = @divFloor(next - day, day_s) };
}

/// What the month looks like, for the report and for the budget's rule.
pub const Outlook = struct {
    month: []const u8,
    /// Spent this month before today.
    so_far: f64 = 0,
    /// A day of the last seven, on average; null: fewer than three days to go by.
    a_day: ?f64 = null,
    /// Where the month ends at that rate.
    ends_at: ?f64 = null,
};

/// `first`: the first day that was read. Days before it are not known, not zero.
pub fn outlook(a: Allocator, costs: []const Cost, rules: Rules, first: i64, now: i64) !Outlook {
    const today = @divFloor(now, day_s) * day_s;
    const mo = try monthOf(a, today);
    var o: Outlook = .{ .month = mo.name };
    o.so_far = sumOf(costs, "", rules.currency, null, @max(mo.start, first), today - day_s);
    const from = @max(today - 7 * day_s, first);
    const n = @divFloor(today - from, day_s);
    if (n >= 3) {
        const per = sumOf(costs, "", rules.currency, null, from, today - day_s) / @as(f64, @floatFromInt(n));
        o.a_day = per;
        o.ends_at = o.so_far + per * @as(f64, @floatFromInt(mo.days_left));
    }
    return o;
}

/// What to look at in what was spent. `first` is the first day read.
pub fn check(a: Allocator, costs: []const Cost, rules: Rules, first: i64, now: i64) ![]audit.Finding {
    var out: std.ArrayList(audit.Finding) = .empty;
    const today = @divFloor(now, day_s) * day_s;

    // a day far above the usual for its weekday, in the last seven days
    if (rules.jump > 0) for (try pairs(a, costs)) |p| {
        var back: i64 = 1;
        while (back <= 7) : (back += 1) {
            const day = today - back * day_s;
            if (day < first) break;
            var earlier: std.ArrayList(f64) = .empty;
            var rows: std.ArrayList(audit.Row) = .empty;
            var weeks: i64 = 1;
            while (day - weeks * 7 * day_s >= first) : (weeks += 1) {
                const d = day - weeks * 7 * day_s;
                const v = sumOf(costs, p.provider, p.currency, null, d, d);
                try earlier.append(a, v);
                try rows.append(a, .{ .source = try std.fmt.allocPrint(a, "{s}, {s}", .{ label(p.provider), try model.day(a, d) }), .value = try money(a, v, p.currency) });
            }
            if (earlier.items.len < 3) continue;
            const total = sumOf(costs, p.provider, p.currency, null, day, day);
            const usual = median(try a.dupe(f64, earlier.items));
            if (total < usual * @as(f64, @floatFromInt(rules.jump)) or total - usual < @as(f64, @floatFromInt(rules.jump_above))) continue;
            // ...and far above the other days of its own week: a rise that
            // came and stayed is a cost that doubled, not seven jumps
            var around: std.ArrayList(f64) = .empty;
            var other: i64 = 1;
            while (other <= 7) : (other += 1) {
                const d = today - other * day_s;
                if (d != day and d >= first) try around.append(a, sumOf(costs, p.provider, p.currency, null, d, d));
            }
            if (around.items.len >= 3 and total < median(around.items) * @as(f64, @floatFromInt(rules.jump))) continue;
            // the lines that carry it, the largest rise first (three at most)
            const Rise = struct { line: []const u8, that_day: f64, usual: f64 };
            var rises: std.ArrayList(Rise) = .empty;
            for (try lines(a, costs)) |l| {
                if (!eql(l.provider, p.provider) or !eql(l.currency, p.currency)) continue;
                const that_day = sumOf(costs, l.provider, l.currency, l.line, day, day);
                var before: std.ArrayList(f64) = .empty;
                var w: i64 = 1;
                while (day - w * 7 * day_s >= first) : (w += 1) try before.append(a, sumOf(costs, l.provider, l.currency, l.line, day - w * 7 * day_s, day - w * 7 * day_s));
                const was = median(before.items);
                if (that_day - was > 0) try rises.append(a, .{ .line = l.line, .that_day = that_day, .usual = was });
            }
            std.mem.sort(Rise, rises.items, {}, struct {
                fn f(_: void, x: Rise, y: Rise) bool {
                    return x.that_day - x.usual > y.that_day - y.usual;
                }
            }.f);
            var ev: std.ArrayList(audit.Row) = .empty;
            try ev.append(a, .{ .source = try std.fmt.allocPrint(a, "{s}, {s}", .{ label(p.provider), try model.day(a, day) }), .value = try money(a, total, p.currency) });
            try ev.appendSlice(a, rows.items);
            for (rises.items[0..@min(rises.items.len, 3)]) |r| try ev.append(a, .{ .source = try std.fmt.allocPrint(a, "{s}, {s}", .{ label(p.provider), r.line }), .value = try std.fmt.allocPrint(a, "{s} that day; {s} on the {s}s before", .{ try money(a, r.that_day, p.currency), try money(a, r.usual, p.currency), weekday(day) }) });
            try out.append(a, .{
                .kind = .cost_jump,
                .key = try std.fmt.allocPrint(a, "cost_jump:{s}:{s}", .{ p.provider, try model.day(a, day) }),
                .customer = p.provider,
                .name = label(p.provider),
                .amount = cents(total - usual),
                .currency = p.currency,
                .per = .once,
                .what = try std.fmt.allocPrint(a, "{s} cost {s} on {s} {s}; a {s} usually costs {s} (the middle of the {d} before).", .{ label(p.provider), try money(a, total, p.currency), weekday(day), try model.day(a, day), weekday(day), try money(a, usual, p.currency), earlier.items.len }),
                .rows = ev.items,
                .proposal = "Look at what ran that day under the lines above: a job left running, a loop that tries again and again, a new feature's traffic. If it was meant (a batch you ran once), say so (decide ... intended).",
            });
        }
    };

    // a line whose last seven days cost twice the seven before
    if (rules.doubled_above > 0 and today - 14 * day_s >= first) for (try lines(a, costs)) |l| {
        const last = sumOf(costs, l.provider, l.currency, l.line, today - 7 * day_s, today - day_s);
        const prev = sumOf(costs, l.provider, l.currency, l.line, today - 14 * day_s, today - 8 * day_s);
        if (last < prev * 2 or last - prev < @as(f64, @floatFromInt(rules.doubled_above))) continue;
        var by_day: std.ArrayList(u8) = .empty;
        var back: i64 = 7;
        while (back >= 1) : (back -= 1) {
            const d = today - back * day_s;
            const text = try money(a, sumOf(costs, l.provider, l.currency, l.line, d, d), l.currency);
            // (the currency once, at the end)
            try by_day.print(a, "{s}{s}", .{ if (back < 7) ", " else "", text[0 .. std.mem.lastIndexOfScalar(u8, text, ' ') orelse text.len] });
        }
        try out.append(a, .{
            .kind = .cost_doubled,
            .key = try std.fmt.allocPrint(a, "cost_doubled:{s}:{s}", .{ l.provider, l.line }),
            .customer = l.provider,
            .name = try std.fmt.allocPrint(a, "{s}, {s}", .{ label(l.provider), l.line }),
            // what it is worth a month if it stays so
            .amount = cents((last - prev) * 30 / 7),
            .currency = l.currency,
            .per = .month,
            .what = if (prev > 0)
                try std.fmt.allocPrint(a, "{s} at {s} cost {s} in the last 7 days and {s} in the 7 before.", .{ l.line, label(l.provider), try money(a, last, l.currency), try money(a, prev, l.currency) })
            else
                try std.fmt.allocPrint(a, "{s} at {s} cost {s} in the last 7 days and nothing in the 7 before.", .{ l.line, label(l.provider), try money(a, last, l.currency) }),
            .rows = try a.dupe(audit.Row, &.{
                .{ .source = try std.fmt.allocPrint(a, "{s}, {s} to {s}", .{ label(l.provider), try model.day(a, today - 14 * day_s), try model.day(a, today - 8 * day_s) }), .value = try money(a, prev, l.currency) },
                .{ .source = try std.fmt.allocPrint(a, "{s}, {s} to {s}", .{ label(l.provider), try model.day(a, today - 7 * day_s), try model.day(a, today - day_s) }), .value = try money(a, last, l.currency) },
                .{ .source = "the last 7 days, day by day", .value = try std.fmt.allocPrint(a, "{s} {s}", .{ by_day.items, try std.ascii.allocUpperString(a, l.currency) }) },
            }),
            .proposal = "If this is growth you expected, say so (decide ... intended). If not, see at the provider which key or project sends this traffic, and whether a smaller model or a cheaper kind of the service would do the same work. The amount is what the rise is worth a month if it stays.",
        });
    };

    // the month, at the rate of the last seven days, against the budget
    if (rules.budget > 0) {
        const o = try outlook(a, costs, rules, first, now);
        const budget: f64 = @floatFromInt(rules.budget);
        const past = o.so_far > budget;
        if (past or (o.ends_at != null and o.ends_at.? > budget)) {
            var ev: std.ArrayList(audit.Row) = .empty;
            const mo = try monthOf(a, today);
            for (try pairs(a, costs)) |p| {
                if (!eql(p.currency, rules.currency)) continue;
                try ev.append(a, .{ .source = try std.fmt.allocPrint(a, "{s}, {s} so far", .{ label(p.provider), o.month }), .value = try money(a, sumOf(costs, p.provider, p.currency, null, @max(mo.start, first), today - day_s), p.currency) });
            }
            if (o.a_day) |per| try ev.append(a, .{ .source = "a day of the last 7, on average", .value = try money(a, per, rules.currency) });
            try ev.append(a, .{ .source = "the budget ([bills] budget)", .value = try model.money(a, rules.budget, rules.currency) });
            const over = if (past and o.ends_at == null) o.so_far - budget else (o.ends_at orelse o.so_far) - budget;
            try out.append(a, .{
                .kind = .over_budget,
                .key = try std.fmt.allocPrint(a, "over_budget:{s}", .{o.month}),
                .customer = "all",
                .name = try std.fmt.allocPrint(a, "{s}, everything read", .{o.month}),
                .amount = cents(over),
                .currency = rules.currency,
                .per = .once,
                .what = if (past)
                    try std.fmt.allocPrint(a, "{s} has cost {s} so far: past the budget of {s}{s}.", .{ o.month, try money(a, o.so_far, rules.currency), try model.money(a, rules.budget, rules.currency), if (o.ends_at) |e| try std.fmt.allocPrint(a, ", and on the way to {s}", .{try money(a, e, rules.currency)}) else "" })
                else
                    try std.fmt.allocPrint(a, "{s} has cost {s} so far and, at the rate of the last 7 days, ends at {s}: past the budget of {s}.", .{ o.month, try money(a, o.so_far, rules.currency), try money(a, o.ends_at.?, rules.currency), try model.money(a, rules.budget, rules.currency) }),
                .rows = ev.items,
                .proposal = "See which line grew (the other findings name it, if a rule caught it) and decide: lower it, or raise the budget in the pay file. A limit at the provider is yours to set there: paymcp sets none.",
            });
        }
    }

    std.mem.sort(audit.Finding, out.items, {}, struct {
        fn f(_: void, x: audit.Finding, y: audit.Finding) bool {
            if (x.amount != y.amount) return x.amount > y.amount;
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.f);
    return out.items;
}

const t = std.testing;
const day0: i64 = 1795651200; // 2026-11-26 (a Thursday)

/// Thirty-five days of two lines at one provider, the same every day.
fn steady(a: Allocator, list: *std.ArrayList(Cost), provider: []const u8, line: []const u8, a_day: f64) !void {
    var back: i64 = 35;
    while (back >= 1) : (back -= 1) try list.append(a, .{ .day = day0 - back * day_s, .provider = provider, .line = line, .amount = a_day, .currency = "usd" });
}

fn find(fs: []const audit.Finding, kind: audit.Kind) ?audit.Finding {
    for (fs) |f| if (f.kind == kind) return f;
    return null;
}

test "steady_spending_is_nothing_to_look_at" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Cost) = .empty;
    try steady(a, &list, "anthropic", "claude-sonnet-5-5", 1200);
    try steady(a, &list, "openai", "gpt, input", 300.4);
    const fs = try check(a, list.items, .{ .budget = 60_000 }, day0 - 35 * day_s, day0 + 3600);
    try t.expectEqual(@as(usize, 0), fs.len);
    // the month so far (25 days of November), and where it ends at this rate
    const o = try outlook(a, list.items, .{}, day0 - 35 * day_s, day0 + 3600);
    try t.expectEqualStrings("2026-11", o.month);
    try t.expectEqual(@as(i64, 37510), cents(o.so_far));
    try t.expectEqual(@as(i64, 1500), cents(o.a_day.?));
    try t.expectEqual(@as(i64, 45012), cents(o.ends_at.?));
    try t.expectEqualStrings("Thursday", weekday(day0));
}

test "a_day_far_above_its_weekday_is_asked_about_with_the_line_that_carries_it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Cost) = .empty;
    try steady(a, &list, "anthropic", "claude-sonnet-5-5", 1200);
    try steady(a, &list, "anthropic", "claude-haiku-5-5", 100);
    // two days ago (a Tuesday) one model ran away
    try list.append(a, .{ .day = day0 - 2 * day_s, .provider = "anthropic", .line = "claude-sonnet-5-5", .amount = 7200, .currency = "usd" });
    const fs = try check(a, list.items, .{ .doubled_above = 0 }, day0 - 35 * day_s, day0);
    try t.expectEqual(@as(usize, 1), fs.len);
    const f = fs[0];
    try t.expect(f.kind == .cost_jump);
    try t.expectEqualStrings("cost_jump:anthropic:2026-11-24", f.key);
    try t.expectEqual(@as(i64, 7200), f.amount);
    try t.expect(std.mem.indexOf(u8, f.what, "Anthropic cost 85.00 USD on Tuesday 2026-11-24; a Tuesday usually costs 13.00 USD (the middle of the 4 before).") != null);
    // the day, the four Tuesdays before, and the one line that rose
    try t.expectEqual(@as(usize, 6), f.rows.len);
    try t.expectEqualStrings("Anthropic, claude-sonnet-5-5", f.rows[5].source);
    try t.expect(std.mem.indexOf(u8, f.rows[5].value, "84.00 USD that day; 12.00 USD on the Tuesdays before") != null);
    // a rise below the least that is asked about is left alone
    const quiet = try check(a, list.items, .{ .doubled_above = 0, .jump_above = 10_000 }, day0 - 35 * day_s, day0);
    try t.expectEqual(@as(usize, 0), quiet.len);
    // with two weeks read, a weekday has too few days before it to judge by
    const short = try check(a, list.items, .{ .doubled_above = 0 }, day0 - 14 * day_s, day0);
    try t.expectEqual(@as(usize, 0), short.len);
}

test "a_line_that_doubled_and_a_month_on_its_way_past_the_budget" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Cost) = .empty;
    try steady(a, &list, "aws", "Amazon Elastic Compute Cloud - Compute", 2000);
    // a line that began a week ago, and one that tripled
    var back: i64 = 7;
    while (back >= 1) : (back -= 1) {
        try list.append(a, .{ .day = day0 - back * day_s, .provider = "aws", .line = "Amazon Bedrock", .amount = 900, .currency = "usd" });
        try list.append(a, .{ .day = day0 - back * day_s, .provider = "aws", .line = "Amazon Elastic Compute Cloud - Compute", .amount = 4000, .currency = "usd" });
    }
    const fs = try check(a, list.items, .{ .jump = 0, .budget = 100_000 }, day0 - 35 * day_s, day0);
    try t.expectEqual(@as(usize, 3), fs.len);
    const ec2 = fs[0];
    try t.expect(ec2.kind == .cost_doubled);
    try t.expectEqualStrings("cost_doubled:aws:Amazon Elastic Compute Cloud - Compute", ec2.key);
    // 420.00 against 140.00 a week: 280.00 more a week, 1200.00 a month
    try t.expectEqual(@as(i64, 120_000), ec2.amount);
    try t.expect(ec2.per == .month);
    try t.expect(std.mem.indexOf(u8, ec2.what, "cost 420.00 USD in the last 7 days and 140.00 USD in the 7 before") != null);
    try t.expectEqualStrings("60.00, 60.00, 60.00, 60.00, 60.00, 60.00, 60.00 USD", ec2.rows[2].value);
    var new_line: ?audit.Finding = null;
    for (fs) |f| if (std.mem.eql(u8, f.key, "cost_doubled:aws:Amazon Bedrock")) {
        new_line = f;
    };
    try t.expect(std.mem.indexOf(u8, new_line.?.what, "nothing in the 7 before") != null);
    // November so far: 18 days at 20.00 and 7 at 69.00 = 843.00; five days left at 69.00
    const over = find(fs, .over_budget).?;
    try t.expectEqualStrings("over_budget:2026-11", over.key);
    try t.expect(std.mem.indexOf(u8, over.what, "has cost 843.00 USD so far and, at the rate of the last 7 days, ends at 1188.00 USD: past the budget of 1000.00 USD") != null);
    try t.expectEqual(@as(i64, 18_800), over.amount);
    // a budget already passed is said as passed
    const past = try check(a, list.items, .{ .jump = 0, .doubled_above = 0, .budget = 50_000 }, day0 - 35 * day_s, day0);
    try t.expect(std.mem.indexOf(u8, past[0].what, "past the budget of 500.00 USD, and on the way to 1188.00 USD") != null);
}

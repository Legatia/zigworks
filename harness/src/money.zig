//! Money from automation, within a budget: what a budget for a server is,
//! the month a day is in, amounts as the owner reads them, and the words
//! harness says about it. Transport-free; agent.zig decides each call
//! (`moneyCheck`, `MoneyLedger`), core.zig says and asks.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The month day `day` (days since 1970-01-01, in the owner's time) is in:
/// year × 12 + month − 1, so months count on across years.
pub fn monthOf(day: i64) i64 {
    if (day < 0) return 1970 * 12 - 1;
    const yd = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
    const md = yd.calculateMonthDay();
    return @as(i64, yd.year) * 12 + @as(i64, md.month.numeric()) - 1;
}

const t = std.testing;

test "a_day_is_in_its_month" {
    // 2026-11-24 is day 20781
    try t.expectEqual(2026 * 12 + 10, monthOf(20781));
    // 2026-11-30 and 2026-12-01
    try t.expectEqual(2026 * 12 + 10, monthOf(20787));
    try t.expectEqual(2026 * 12 + 11, monthOf(20788));
    // 2026-12-31 and 2027-01-01: months count on
    try t.expectEqual(2026 * 12 + 11, monthOf(20818));
    try t.expectEqual(2027 * 12 + 0, monthOf(20819));
    // 2028-02-29
    try t.expectEqual(2028 * 12 + 1, monthOf(21243));
    try t.expectEqual(1970 * 12, monthOf(0));
}

/// What automation may spend at one server: its own budget keys (mcp.ini)
/// over config.ini's [money], key by key.
pub const Budget = struct {
    /// 0: no limit of its own for that period.
    day: u32 = 0,
    month: u32 = 0,
    /// The server's `none`: automation spends nothing there.
    none: bool = false,

    /// Some budget above 0 lets automation spend.
    pub fn any(b: Budget) bool {
        return !b.none and (b.day > 0 or b.month > 0);
    }
};

/// The budget at a server whose own keys are `day` and `month` (null:
/// config.ini's; 0: `none`), `money` config.ini's [money].
pub fn budgetFor(money: anytype, day: ?u32, month: ?u32) Budget {
    const none = (day != null and day.? == 0) or (month != null and month.? == 0);
    if (none) return .{ .none = true };
    return .{ .day = day orelse money.budget_per_day, .month = month orelse money.budget_per_month };
}

/// An amount as the owner reads it: whole, or with two decimals ("40",
/// "12.50").
pub fn amountText(a: Allocator, x: f64) ![]const u8 {
    if (x == @floor(x) and @abs(x) < 1e15) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(x))});
    return std.fmt.allocPrint(a, "{d:.2}", .{x});
}

/// One automated spend, as the owner is told of it.
pub const Spent = struct {
    server: []const u8,
    tool: []const u8,
    /// What started the run (`schedule:NAME`, `trigger:NAME`, …).
    by: []const u8,
    amount: f64,
    /// Automation's at that server after it, today and this month.
    day_spent: f64,
    month_spent: f64,
    budget: Budget,
    /// The call came back an error (it stays counted all the same).
    failed: bool = false,
};

/// The line said in main after each automated spend: "Spent 12.50 on
/// shop/order for the weekly-groceries task. Today 12.50 of 30; this month
/// 40 of 200."
pub fn toldLine(a: Allocator, s: Spent) ![]const u8 {
    const of_day = if (s.budget.day > 0) try std.fmt.allocPrint(a, " of {d}", .{s.budget.day}) else "";
    const of_month = if (s.budget.month > 0) try std.fmt.allocPrint(a, " of {d}", .{s.budget.month}) else "";
    return std.fmt.allocPrint(a, "Spent {s} on {s}/{s} for {s}. Today {s}{s}; this month {s}{s}.{s}", .{
        try amountText(a, s.amount),                                  s.server, s.tool, try ranFor(a, s.by),
        try amountText(a, s.day_spent),                               of_day,   try amountText(a, s.month_spent), of_month,
        if (s.failed) " The server said it failed; it stays counted." else "",
    });
}

/// What started a run, as a line names it: "the NAME task", "the NAME
/// trigger", "the NAME workflow", "the reorder".
pub fn ranFor(a: Allocator, by: []const u8) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, by, ':') orelse return std.fmt.allocPrint(a, "{s}", .{by});
    const kind = by[0..colon];
    var name = by[colon + 1 ..];
    if (std.mem.eql(u8, kind, "harness")) return std.fmt.allocPrint(a, "the {s}", .{name});
    if (std.mem.eql(u8, kind, "workflow")) name = name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len];
    const word = if (std.mem.eql(u8, kind, "schedule")) "task" else kind;
    return std.fmt.allocPrint(a, "the {s} {s}", .{ name, word });
}

/// `/money budget N a day|a month` (also "per day", "per month").
pub const BudgetWords = struct { n: u32, period: enum { day, month } };

pub fn parseBudget(words: []const u8) ?BudgetWords {
    var it = std.mem.tokenizeAny(u8, words, " \t");
    const n_text = it.next() orelse return null;
    for (n_text) |ch| if (!std.ascii.isDigit(ch)) return null;
    const n = std.fmt.parseInt(u32, n_text, 10) catch return null;
    const a_word = it.next() orelse return null;
    if (!std.mem.eql(u8, a_word, "a") and !std.mem.eql(u8, a_word, "per")) return null;
    const p = it.next() orelse return null;
    if (it.next() != null) return null;
    if (std.mem.eql(u8, p, "day")) return .{ .n = n, .period = .day };
    if (std.mem.eql(u8, p, "month")) return .{ .n = n, .period = .month };
    return null;
}

test "budgets_resolve_per_key_and_none" {
    const M = struct { budget_per_day: u32 = 30, budget_per_month: u32 = 200 };
    try t.expectEqual(Budget{ .day = 30, .month = 200 }, budgetFor(M{}, null, null));
    try t.expectEqual(Budget{ .day = 10, .month = 200 }, budgetFor(M{}, 10, null));
    try t.expectEqual(Budget{ .day = 30, .month = 50 }, budgetFor(M{}, null, 50));
    // none on either key: nothing spends there
    try t.expect(budgetFor(M{}, 0, null).none);
    try t.expect(budgetFor(M{}, 10, 0).none);
    try t.expect(!budgetFor(M{}, null, 0).any());
    try t.expect(!budgetFor(M{ .budget_per_day = 0, .budget_per_month = 0 }, null, null).any());
    try t.expect(budgetFor(M{ .budget_per_day = 0, .budget_per_month = 5 }, null, null).any());
}

test "amounts_read_plainly" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("40", try amountText(a, 40));
    try t.expectEqualStrings("12.50", try amountText(a, 12.5));
    try t.expectEqualStrings("0.10", try amountText(a, 0.1));
    try t.expectEqualStrings("0", try amountText(a, 0));
}

test "the_told_line_reads_as_the_spec" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "Spent 12.50 on shop/order for the weekly-groceries task. Today 12.50 of 30; this month 40 of 200.",
        try toldLine(a, .{ .server = "shop", .tool = "order", .by = "schedule:weekly-groceries", .amount = 12.5, .day_spent = 12.5, .month_spent = 40, .budget = .{ .day = 30, .month = 200 } }),
    );
    // a budget only a month: today's is the spent alone
    try t.expectEqualStrings(
        "Spent 5 on frisco/shop_order for the reorder. Today 5; this month 45 of 200. The server said it failed; it stays counted.",
        try toldLine(a, .{ .server = "frisco", .tool = "shop_order", .by = "harness:reorder", .amount = 5, .day_spent = 5, .month_spent = 45, .budget = .{ .month = 200 }, .failed = true }),
    );
    try t.expectEqualStrings("the btc trigger", try ranFor(a, "trigger:btc"));
    try t.expectEqualStrings("the shop workflow", try ranFor(a, "workflow:shop/buy"));
    try t.expectEqualStrings("the weekly-groceries task", try ranFor(a, "schedule:weekly-groceries"));
}

test "budget_words_read" {
    try t.expectEqual(BudgetWords{ .n = 30, .period = .day }, parseBudget("30 a day").?);
    try t.expectEqual(BudgetWords{ .n = 200, .period = .month }, parseBudget("200  a  month").?);
    try t.expectEqual(BudgetWords{ .n = 0, .period = .day }, parseBudget("0 a day").?);
    try t.expectEqual(BudgetWords{ .n = 50, .period = .day }, parseBudget("50 per day").?);
    for ([_][]const u8{ "", "30", "a day", "30 a week", "-1 a day", "2.5 a day", "30 a day extra", "lots a day" }) |w| try t.expectEqual(null, parseBudget(w));
}

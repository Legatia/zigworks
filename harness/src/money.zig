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

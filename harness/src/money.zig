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

//! Money from automation, within a budget: what a budget for a server is,
//! the month a day is in, amounts as the owner reads them, and the words
//! harness says about it. Transport-free; agent.zig decides each call
//! (`moneyCheck`, `MoneyLedger`), core.zig says and asks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const mail_mod = @import("mail.zig");

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

/// An amount as the owner reads it: whole, with two decimals from 1 up
/// ("40", "12.50"), and below 1 as it is, up to 8 decimals ("0.0015"), so
/// a coin's fraction never reads as 0.
pub fn amountText(a: Allocator, x: f64) ![]const u8 {
    if (x == @floor(x) and @abs(x) < 1e15) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(x))});
    if (@abs(x) >= 1) return std.fmt.allocPrint(a, "{d:.2}", .{x});
    const full = try std.fmt.allocPrint(a, "{d:.8}", .{x});
    const trimmed = std.mem.trimEnd(u8, full, "0");
    return if (std.mem.endsWith(u8, trimmed, ".")) full else trimmed;
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

/// What the first start after budgets writes for an install that spent
/// before: config.ini and mcp.ini as they become (null: unchanged), and
/// the line said once in main.
pub const Upgraded = struct {
    config: ?[]const u8 = null,
    mcp: ?[]const u8 = null,
    line: []const u8,
    /// What config.ini's [money] gets: its budget a day, and its trigger
    /// and workflow switches written off (they were off without a line).
    budget_per_day: ?u32 = null,
    triggers_off: bool = false,
    workflows_off: bool = false,
};

/// An install spent unattended before budgets when config.ini's own
/// `[money]` says `scheduled = on` (not the default, which is on now) and
/// says no budget: its budget a day is set from its cap a day where that
/// is (`[money]`'s `max_per_day`, and a money server's own in mcp.ini
/// that says no budget). Null: nothing to do.
pub fn upgradeTexts(a: Allocator, config_text: []const u8, mcp_text: []const u8) !?Upgraded {
    const cl = config.lines(a, config_text) catch return null;
    var scheduled = false;
    var budgeted = false;
    var day_cap: u32 = 0;
    var call_cap: u32 = 0;
    var has_triggers = false;
    var has_workflows = false;
    for (cl) |l| {
        if (!std.mem.eql(u8, l.section, "money")) continue;
        if (std.mem.eql(u8, l.key, "scheduled")) scheduled = config.parseBool(l.value) orelse false;
        if (std.mem.eql(u8, l.key, "budget_per_day") or std.mem.eql(u8, l.key, "budget_per_month")) budgeted = true;
        if (std.mem.eql(u8, l.key, "max_per_day")) day_cap = std.fmt.parseInt(u32, l.value, 10) catch 0;
        if (std.mem.eql(u8, l.key, "max_per_call")) call_cap = std.fmt.parseInt(u32, l.value, 10) catch 0;
        if (std.mem.eql(u8, l.key, "triggers")) has_triggers = true;
        if (std.mem.eql(u8, l.key, "workflows")) has_workflows = true;
    }
    if (!scheduled or budgeted) return null;
    var out: Upgraded = .{ .line = "" };
    var conf: []const u8 = config_text;
    var set: std.ArrayList(u8) = .empty;
    if (day_cap > 0) {
        conf = try mail_mod.setKey(a, conf, "money", "budget_per_day", try std.fmt.allocPrint(a, "{d}", .{day_cap}));
        out.budget_per_day = day_cap;
        try set.print(a, "{d} in config.ini's [money]", .{day_cap});
    }
    // before budgets a missing line was off: kept off, not the new default
    if (!has_triggers) {
        conf = try mail_mod.setKey(a, conf, "money", "triggers", "off");
        out.triggers_off = true;
    }
    if (!has_workflows) {
        conf = try mail_mod.setKey(a, conf, "money", "workflows", "off");
        out.workflows_off = true;
    }
    if (conf.ptr != config_text.ptr) out.config = conf;
    // each money server that says no budget: its own day cap becomes its
    // budget; one whose caps were all off (its own `none`, and [money]'s
    // none) never spent unattended, so nothing spends there
    const ml = config.lines(a, mcp_text) catch &.{};
    var mcp_new: []const u8 = mcp_text;
    var none: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < ml.len) {
        const sec = ml[i].section;
        var money = false;
        var own_budget = false;
        var day: ?u32 = null;
        var call: ?u32 = null;
        while (i < ml.len and std.mem.eql(u8, ml[i].section, sec)) : (i += 1) {
            const l = ml[i];
            if (std.mem.eql(u8, l.key, "money") and l.value.len > 0) money = true;
            if (std.mem.eql(u8, l.key, "budget_per_day") or std.mem.eql(u8, l.key, "budget_per_month")) own_budget = true;
            // `none` (no cap there): 0
            if (std.mem.eql(u8, l.key, "max_per_day")) day = std.fmt.parseInt(u32, l.value, 10) catch 0;
            if (std.mem.eql(u8, l.key, "max_per_call")) call = std.fmt.parseInt(u32, l.value, 10) catch 0;
        }
        if (!money or own_budget or sec.len == 0) continue;
        if (day) |n| if (n > 0) {
            mcp_new = try mail_mod.setKey(a, mcp_new, sec, "budget_per_day", try std.fmt.allocPrint(a, "{d}", .{n}));
            try set.print(a, "{s}{d} for {s} in mcp.ini", .{ if (set.items.len > 0) ", " else "", n, sec });
            continue;
        };
        if ((day orelse day_cap) == 0 and (call orelse call_cap) == 0) {
            mcp_new = try mail_mod.setKey(a, mcp_new, sec, "budget_per_day", "none");
            try none.print(a, "{s}{s}", .{ if (none.items.len > 0) ", " else "", sec });
        }
    }
    if (mcp_new.ptr != mcp_text.ptr) out.mcp = mcp_new;
    var line: std.ArrayList(u8) = .empty;
    if (set.items.len > 0)
        try line.print(a, "Routines now spend within a budget of their own, and what they spent before goes on: budget_per_day is set from max_per_day ({s}).", .{set.items})
    else
        try line.appendSlice(a, "Routines now spend only within a budget of their own, and none is set (no max_per_day to take it from): they spend nothing without asking you until /money budget N a day sets one at each money server.");
    if (none.items.len > 0) try line.print(a, " {s} had no cap, so routines spend nothing there (budget_per_day = none in mcp.ini).", .{none.items});
    if (out.triggers_off or out.workflows_off) {
        const both = out.triggers_off and out.workflows_off;
        try line.print(a, " {s} {s} off, as {s} ([money] {s} in config.ini).", .{
            if (both) "Triggers and workflows" else if (out.triggers_off) "Triggers" else "Workflows",
            if (both) "stay" else "stays",
            if (both) "they were" else "it was",
            if (both) "triggers = off, workflows = off" else if (out.triggers_off) "triggers = off" else "workflows = off",
        });
    }
    if (set.items.len > 0) try line.appendSlice(a, " /money shows it; /money pause stops it.");
    out.line = line.items;
    return out;
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
    // below 1: the amount as it is (a coin's fractions), up to 8 decimals
    try t.expectEqualStrings("0.1", try amountText(a, 0.1));
    try t.expectEqualStrings("0.0015", try amountText(a, 0.0015));
    try t.expectEqualStrings("0.00000001", try amountText(a, 0.00000001));
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

test "upgrade_texts_set_the_budget_where_the_cap_is" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mcp_ini = "[frisco]\r\ncommand = x\r\nmoney = shop_order\r\namount = shop_order:total\r\nmax_per_day = 20   ; its own\r\n[broker]\r\ncommand = y\r\nmoney = buy\r\namount = notional_usd\r\nmax_per_day = none\r\n[other]\r\ncommand = z\r\nmoney = pay\r\nmax_per_day = 9\r\nbudget_per_month = 30\r\n[plain]\r\ncommand = w\r\nmoney = pay\r\namount = sum\r\n[tools]\r\ncommand = v\r\n";
    // spent before: scheduled on (the file's own line) and a day cap
    const u = (try upgradeTexts(a, "[chat]\napi = x\n[money]\nmax_per_day = 50\nscheduled = on   ; mine\n", mcp_ini)).?;
    // triggers and workflows were off when their lines were missing: kept so
    try t.expectEqualStrings("[chat]\napi = x\n[money]\nmax_per_day = 50\nscheduled = on   ; mine\nbudget_per_day = 50\ntriggers = off\nworkflows = off\n", u.config.?);
    try t.expectEqual(50, u.budget_per_day.?);
    try t.expect(u.triggers_off and u.workflows_off);
    // a server's own day cap: its own budget (CRLF kept); one with no cap
    // at all (none, and no cap a call) couldn't spend unattended: none
    // there; its own budget, or [money]'s cap to go by: left
    try t.expectEqualStrings("[frisco]\r\ncommand = x\r\nmoney = shop_order\r\namount = shop_order:total\r\nmax_per_day = 20   ; its own\r\nbudget_per_day = 20\r\n[broker]\r\ncommand = y\r\nmoney = buy\r\namount = notional_usd\r\nmax_per_day = none\r\nbudget_per_day = none\r\n[other]\r\ncommand = z\r\nmoney = pay\r\nmax_per_day = 9\r\nbudget_per_month = 30\r\n[plain]\r\ncommand = w\r\nmoney = pay\r\namount = sum\r\n[tools]\r\ncommand = v\r\n", u.mcp.?);
    try t.expectEqualStrings("Routines now spend within a budget of their own, and what they spent before goes on: budget_per_day is set from max_per_day (50 in config.ini's [money], 20 for frisco in mcp.ini). broker had no cap, so routines spend nothing there (budget_per_day = none in mcp.ini). Triggers and workflows stay off, as they were ([money] triggers = off, workflows = off in config.ini). /money shows it; /money pause stops it.", u.line);
    // only a per-call cap: nothing to take a day's budget from
    const v = (try upgradeTexts(a, "[money]\nmax_per_call = 10\nscheduled = yes\ntriggers = on\nworkflows = on\n", "")).?;
    try t.expectEqual(null, v.config);
    try t.expectEqual(null, v.mcp);
    try t.expect(!v.triggers_off and !v.workflows_off);
    try t.expectEqualStrings("Routines now spend only within a budget of their own, and none is set (no max_per_day to take it from): they spend nothing without asking you until /money budget N a day sets one at each money server.", v.line);
    // never spent: no line scheduled = on, or off, or a budget already set
    try t.expectEqual(null, try upgradeTexts(a, "[money]\nmax_per_day = 50\n", mcp_ini));
    try t.expectEqual(null, try upgradeTexts(a, "[money]\nmax_per_day = 50\nscheduled = off\n", mcp_ini));
    try t.expectEqual(null, try upgradeTexts(a, "[money]\nmax_per_day = 50\nscheduled = on\nbudget_per_month = 0\n", mcp_ini));
    try t.expectEqual(null, try upgradeTexts(a, "", ""));
}

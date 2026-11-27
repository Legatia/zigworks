//! The pay file: which billing provider account, and what the audit counts
//! as old. An INI file:
//!
//!   [stripe]
//!   url = https://api.stripe.com    ; (the stand-in: http://127.0.0.1:PORT)
//!   mode = sandbox                  ; sandbox: the key begins rk_test_ (or sk_test_); live: rk_live_
//!   page = 100                      ; records a request, 1 to 100
//!
//!   [billing]
//!   who = who.csv                   ; the business's own file (optional; relative: to this file)
//!   old_discount_days = 365         ; a discount with no end is asked about from this age
//!   free_days = 90                  ; a subscription that costs nothing, from this age
//!   draft_days = 7                  ; a draft invoice never sent
//!   unsent_days = 3                 ; an open invoice never charged
//!   written_off_days = 365          ; how far back written-off invoices count
//!   written_off_above = 0           ; ...and above which sum a customer, in the currency's smallest unit
//!   overdue_days = 7                ; an invoice sent to be paid by hand, this long past due
//!   usage_margin_percent = 1        ; use may exceed reported use by this much
//!   record = pay.record.jsonl       ; paymcp's own record of readings and decisions (the default:
//!                                   ; beside this file, named after it); none: keep no record
//!   current = team_monthly, pro_monthly   ; the price list now (ids or lookup keys); none: every active price
//!
//!   [plans]                         ; a plan's name in the business's file = the price it means
//!   team = team_monthly
//!   pro = price_1Qx...
//!
//!   [disputes]
//!   read = yes                      ; card disputes: those to answer, and those lost unanswered
//!   days = 180                      ; how far back
//!
//!   [letters]
//!   from = Ola at Fernhill          ; who a drafted message to a customer is from
//!
//! The key is never in the file: STRIPE_KEY in the environment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");
const audit = @import("audit.zig");

pub const Mode = enum { sandbox, live };

pub const Config = struct {
    url: []const u8 = "https://api.stripe.com",
    mode: Mode = .sandbox,
    page: u8 = 100,
    who_path: []const u8 = "",
    /// paymcp's own record of readings and decisions; "": none is kept.
    record_path: []const u8 = "",
    record_off: bool = false,
    /// Who a drafted message to a customer is from; "": a place left to fill in.
    letter_from: []const u8 = "",
    rules: audit.Rules = .{},
};

pub const Diag = struct { line: usize = 0, what: []const u8 = "" };

pub fn load(a: Allocator, io: Io, path: []const u8, diag: *Diag) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| {
        diag.* = .{ .what = try std.fmt.allocPrint(a, "can't read {s}: {s}", .{ path, @errorName(e) }) };
        return error.BadConfig;
    };
    var c = try parse(a, text, diag);
    const dir = std.fs.path.dirname(path) orelse ".";
    if (c.who_path.len > 0 and !std.fs.path.isAbsolute(c.who_path))
        c.who_path = try std.fs.path.join(a, &.{ dir, c.who_path });
    if (c.record_off) {
        c.record_path = "";
    } else if (c.record_path.len == 0) {
        c.record_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "{s}.record.jsonl", .{std.fs.path.stem(path)}) });
    } else if (!std.fs.path.isAbsolute(c.record_path)) {
        c.record_path = try std.fs.path.join(a, &.{ dir, c.record_path });
    }
    return c;
}

fn bad(diag: *Diag, line: usize, what: []const u8) error{BadConfig} {
    diag.* = .{ .line = line, .what = what };
    return error.BadConfig;
}

fn days(a: Allocator, diag: *Diag, e: ini.Entry) !u32 {
    return std.fmt.parseInt(u32, e.value, 10) catch return bad(diag, e.line, try std.fmt.allocPrint(a, "{s} takes a whole number of days", .{e.key}));
}

pub fn parse(a: Allocator, text: []const u8, diag: *Diag) !Config {
    var bad_line: usize = 0;
    const entries = ini.parse(a, text, &bad_line) catch return bad(diag, bad_line, "not a [section] or a key = value line");
    var c: Config = .{};
    var plans: std.ArrayList(audit.Plan) = .empty;
    for (entries) |e| {
        if (eql(e.section, "stripe")) {
            if (eql(e.key, "url")) {
                if (!std.mem.startsWith(u8, e.value, "https://") and !std.mem.startsWith(u8, e.value, "http://127.0.0.1") and !std.mem.startsWith(u8, e.value, "http://localhost"))
                    return bad(diag, e.line, "url is https://..., or http:// on this computer only (the stand-in): a key isn't sent in the clear");
                c.url = e.value;
            } else if (eql(e.key, "mode")) {
                c.mode = std.meta.stringToEnum(Mode, e.value) orelse return bad(diag, e.line, "mode is sandbox or live");
            } else if (eql(e.key, "page")) {
                const n = std.fmt.parseInt(u8, e.value, 10) catch 0;
                if (n < 1 or n > 100) return bad(diag, e.line, "page is 1 to 100");
                c.page = n;
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[stripe] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "billing")) {
            if (eql(e.key, "who")) {
                c.who_path = e.value;
            } else if (eql(e.key, "record")) {
                if (e.value.len == 0) return bad(diag, e.line, "record is a file's name, or none");
                c.record_off = eql(e.value, "none");
                c.record_path = if (c.record_off) "" else e.value;
            } else if (eql(e.key, "old_discount_days")) {
                c.rules.old_discount_days = try days(a, diag, e);
            } else if (eql(e.key, "free_days")) {
                c.rules.free_days = try days(a, diag, e);
            } else if (eql(e.key, "draft_days")) {
                c.rules.draft_days = try days(a, diag, e);
            } else if (eql(e.key, "unsent_days")) {
                c.rules.unsent_days = try days(a, diag, e);
            } else if (eql(e.key, "overdue_days")) {
                c.rules.overdue_days = try days(a, diag, e);
            } else if (eql(e.key, "written_off_days")) {
                c.rules.written_off_days = try days(a, diag, e);
            } else if (eql(e.key, "written_off_above")) {
                c.rules.written_off_above = std.fmt.parseInt(i64, e.value, 10) catch return bad(diag, e.line, "written_off_above takes a whole number, in the currency's smallest unit");
                if (c.rules.written_off_above < 0) return bad(diag, e.line, "written_off_above is zero or more");
            } else if (eql(e.key, "usage_margin_percent")) {
                const n = std.fmt.parseInt(u32, e.value, 10) catch 101;
                if (n > 100) return bad(diag, e.line, "usage_margin_percent is 0 to 100");
                c.rules.usage_margin_percent = n;
            } else if (eql(e.key, "current")) {
                var list: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, e.value, ',');
                while (it.next()) |raw| {
                    const v = std.mem.trim(u8, raw, " \t");
                    if (v.len > 0) try list.append(a, v);
                }
                c.rules.current = list.items;
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[billing] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "disputes")) {
            if (eql(e.key, "read")) {
                if (!eql(e.value, "yes") and !eql(e.value, "no")) return bad(diag, e.line, "read is yes or no");
                c.rules.disputes = eql(e.value, "yes");
            } else if (eql(e.key, "days")) {
                c.rules.dispute_days = try days(a, diag, e);
                if (c.rules.dispute_days < 1) return bad(diag, e.line, "days is 1 or more");
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[disputes] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "letters")) {
            if (eql(e.key, "from")) {
                c.letter_from = e.value;
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[letters] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "plans")) {
            if (e.value.len == 0) return bad(diag, e.line, "a plan needs the price it means: NAME = a price's id or lookup key");
            try plans.append(a, .{ .name = e.key, .price = e.value });
        } else return bad(diag, e.line, try std.fmt.allocPrint(a, "no section [{s}]: the file has [stripe], [billing], [plans], [disputes] and [letters]", .{e.section}));
    }
    c.rules.plans = plans.items;
    return c;
}

/// Why `key` can't be used with this file, or null. A key is refused when
/// it can do more than the audit needs to tell: a live account's secret key
/// does everything, and a live key is taken only where the file says live.
/// A sandbox's secret key is taken, with `keyNote` said: it is one of the
/// two keys a new sandbox shows, and all it can reach is made-up data.
pub fn keyProblem(c: *const Config, key: []const u8) ?[]const u8 {
    if (key.len == 0) return "STRIPE_KEY isn't set: a restricted key that can only read (README, The key)";
    if (std.mem.startsWith(u8, key, "sk_test_")) {
        if (c.mode == .live) return "STRIPE_KEY is a sandbox key and the file says mode = live";
        return null;
    }
    if (std.mem.startsWith(u8, key, "sk_")) return "STRIPE_KEY is a secret key, which can do everything. Make a restricted key that can only read (README, The key)";
    if (std.mem.startsWith(u8, key, "pk_")) return "STRIPE_KEY is a publishable key, which reads nothing. Make a restricted key that can only read (README, The key)";
    const test_key = std.mem.startsWith(u8, key, "rk_test_");
    const live_key = std.mem.startsWith(u8, key, "rk_live_");
    if (!test_key and !live_key) return "STRIPE_KEY doesn't look like a restricted key (rk_test_... or rk_live_...)";
    if (c.mode == .sandbox and live_key) return "STRIPE_KEY is a live key and the file says mode = sandbox. To audit the live account, say mode = live";
    if (c.mode == .live and test_key) return "STRIPE_KEY is a sandbox key and the file says mode = live";
    return null;
}

/// What is said, once, about a key that is taken but isn't the kind to
/// keep using; or null.
pub fn keyNote(key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, key, "sk_test_")) return "paymcp: STRIPE_KEY is the sandbox's secret key. Fine for trying paymcp on made-up data; a live account is read only with a restricted key that can only read (README, The key).\n";
    return null;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

const t = std.testing;

test "the_pay_file_with_its_rules_and_plans" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const c = try parse(a,
        \\[stripe]
        \\url = http://127.0.0.1:8743
        \\page = 2
        \\[billing]
        \\who = who.csv
        \\old_discount_days = 180
        \\written_off_above = 5000
        \\current = team_monthly, pro_monthly ,
        \\[plans]
        \\team = team_monthly
        \\pro = price_pro
        \\
    , &d);
    try t.expectEqualStrings("http://127.0.0.1:8743", c.url);
    try t.expect(c.mode == .sandbox and c.page == 2);
    try t.expectEqual(@as(u32, 180), c.rules.old_discount_days);
    try t.expectEqual(@as(u32, 90), c.rules.free_days);
    try t.expectEqual(@as(i64, 5000), c.rules.written_off_above);
    try t.expectEqual(@as(usize, 2), c.rules.current.len);
    try t.expectEqualStrings("pro_monthly", c.rules.current[1]);
    try t.expectEqualStrings("price_pro", c.rules.plans[1].price);
    // an empty file is the provider's own address, a sandbox, the defaults
    const e = try parse(a, "", &d);
    try t.expectEqualStrings("https://api.stripe.com", e.url);
}

test "a_setting_the_file_doesnt_have_is_refused_with_its_line" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    try t.expectError(error.BadConfig, parse(a, "[stripe]\nkey = rk_test_abc\n", &d));
    try t.expectEqual(@as(usize, 2), d.line);
    try t.expectError(error.BadConfig, parse(a, "[stripe]\nurl = http://example.com\n", &d));
    try t.expect(std.mem.indexOf(u8, d.what, "in the clear") != null);
    try t.expectError(error.BadConfig, parse(a, "[stripe]\nmode = test\n", &d));
    try t.expectError(error.BadConfig, parse(a, "[stripe]\npage = 500\n", &d));
    try t.expectError(error.BadConfig, parse(a, "[billing]\nfree_days = soon\n", &d));
    try t.expectError(error.BadConfig, parse(a, "[disputes]\nx = 1\n", &d));
}

test "a_key_that_can_do_more_than_read_or_is_for_the_other_account_is_refused" {
    const sandbox: Config = .{};
    const live: Config = .{ .mode = .live };
    try t.expect(keyProblem(&sandbox, "rk_test_abc") == null);
    try t.expect(keyProblem(&live, "rk_live_abc") == null);
    try t.expect(std.mem.indexOf(u8, keyProblem(&sandbox, "").?, "isn't set") != null);
    // a sandbox's secret key is taken, with a note; never for a live file
    try t.expect(keyProblem(&sandbox, "sk_test_abc") == null);
    try t.expect(std.mem.indexOf(u8, keyNote("sk_test_abc").?, "sandbox's secret key") != null);
    try t.expect(keyNote("rk_test_abc") == null);
    try t.expect(std.mem.indexOf(u8, keyProblem(&live, "sk_test_abc").?, "mode = live") != null);
    try t.expect(std.mem.indexOf(u8, keyProblem(&sandbox, "sk_live_abc").?, "can do everything") != null);
    try t.expect(std.mem.indexOf(u8, keyProblem(&live, "sk_live_abc").?, "can do everything") != null);
    try t.expect(keyProblem(&sandbox, "pk_test_abc") != null);
    try t.expect(std.mem.indexOf(u8, keyProblem(&sandbox, "rk_live_abc").?, "mode = live") != null);
    try t.expect(keyProblem(&live, "rk_test_abc") != null);
    try t.expect(keyProblem(&sandbox, "whatever") != null);
}

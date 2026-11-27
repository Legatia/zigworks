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
//!   [changes]
//!   allow = no                      ; yes: paymcp gets tools that change one thing at the provider at a
//!                                   ; time, with a second key (STRIPE_WRITE_KEY), when a person says so
//!   max_amount = 0                  ; the most one change may be worth (smallest unit); 0: no limit here
//!
//!   [payrun]                        ; the payment-run check (needs no key: it reads files)
//!   suppliers = suppliers.csv       ; your suppliers: name, tax number, bank account, phone
//!   history = pay.payments.jsonl    ; paymcp's own list of past payments (the default: beside this file)
//!   duplicate_days = 45             ; the same supplier and amount again within this many days
//!   out_of_line = 3                 ; an amount this many times the largest paid to that supplier
//!   currency = eur                  ; of a file with no currency column
//!   invoices = ksef                 ; Poland: a folder of KSeF invoice files (XML), to set each payment beside
//!   whitelist = no                  ; Poland: yes asks the tax office's list of VAT payers about each account
//!
//!   [ledger]                        ; the books, read for the payment-run check (nothing is exported)
//!   provider = xero                 ; the one there is
//!   history_days = 730              ; how far back payments on bills are read
//!   changed_days = 90               ; a change of bank details in the books is asked about for this long
//!
//!   [bills]                         ; the bill watch: what cloud services and AI models cost
//!   read = anthropic, openai, aws   ; which are read (the default: all three; one with no key is said)
//!   days = 35                       ; how far back (14 to 90)
//!   jump = 3                        ; a day this many times the usual for its weekday (0: not looked for)
//!   jump_above = 500                ; ...and this much above it, in the currency's smallest unit
//!   doubled_above = 1000            ; a line whose week cost twice the week before, by this much (0: not)
//!   budget = 50000                  ; the month's budget for everything read (0: none)
//!   currency = usd                  ; of the budget
//!
//! The keys are never in the file: STRIPE_KEY in the environment; for the
//! bill watch ANTHROPIC_ADMIN_KEY, OPENAI_ADMIN_KEY, AWS_ACCESS_KEY_ID and
//! AWS_SECRET_ACCESS_KEY; for the books XERO_CLIENT_ID and XERO_CLIENT_SECRET.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ini = @import("ini.zig");
const audit = @import("audit.zig");
const payrun = @import("payrun.zig");
const bills = @import("bills.zig");
const ledger = @import("ledger.zig");

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
    /// Whether paymcp may change anything at the provider at all (with
    /// the second key, one thing at a time, when a person says so).
    changes: bool = false,
    /// The most one change may be worth, in the currency's smallest unit; 0: no limit here.
    max_change: i64 = 0,
    /// The payment-run check: the business's list of suppliers ("": none
    /// given), paymcp's own list of past payments, and its rules.
    /// The pay file has a [payrun] section.
    payrun_on: bool = false,
    /// The pay file's folder: the files a tool is given are looked for here.
    dir: []const u8 = ".",
    payrun_suppliers: []const u8 = "",
    payrun_history: []const u8 = "",
    payrun: payrun.Rules = .{},
    /// Poland: a folder of KSeF invoice files ("": none), and whether the
    /// tax office's list of VAT payers is asked about each account (the one
    /// thing of the payment-run check that leaves this computer).
    payrun_invoices: []const u8 = "",
    payrun_whitelist: bool = false,
    whitelist_url: []const u8 = "https://wykazpodatnikowvat.mf.gov.pl",
    /// The books: the pay file has a [ledger] section.
    ledger_on: bool = false,
    ledger: ledger.Settings = .{},
    /// The bill watch: the pay file has a [bills] section; which providers
    /// are read, where they are (the stand-in: on this computer), the rules.
    bills_on: bool = false,
    bills_read: []const []const u8 = &.{ "anthropic", "openai", "aws" },
    bills: bills.Rules = .{},
    anthropic_url: []const u8 = "https://api.anthropic.com",
    openai_url: []const u8 = "https://api.openai.com",
    aws_url: []const u8 = "https://ce.us-east-1.amazonaws.com",
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
    c.dir = dir;
    if (c.who_path.len > 0 and !std.fs.path.isAbsolute(c.who_path))
        c.who_path = try std.fs.path.join(a, &.{ dir, c.who_path });
    if (c.record_off) {
        c.record_path = "";
    } else if (c.record_path.len == 0) {
        c.record_path = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "{s}.record.jsonl", .{std.fs.path.stem(path)}) });
    } else if (!std.fs.path.isAbsolute(c.record_path)) {
        c.record_path = try std.fs.path.join(a, &.{ dir, c.record_path });
    }
    if (c.payrun_suppliers.len > 0 and !std.fs.path.isAbsolute(c.payrun_suppliers))
        c.payrun_suppliers = try std.fs.path.join(a, &.{ dir, c.payrun_suppliers });
    if (c.payrun_invoices.len > 0 and !std.fs.path.isAbsolute(c.payrun_invoices))
        c.payrun_invoices = try std.fs.path.join(a, &.{ dir, c.payrun_invoices });
    if (c.payrun_history.len == 0) {
        c.payrun_history = try std.fs.path.join(a, &.{ dir, try std.fmt.allocPrint(a, "{s}.payments.jsonl", .{std.fs.path.stem(path)}) });
    } else if (!std.fs.path.isAbsolute(c.payrun_history)) {
        c.payrun_history = try std.fs.path.join(a, &.{ dir, c.payrun_history });
    }
    return c;
}

fn bad(diag: *Diag, line: usize, what: []const u8) error{BadConfig} {
    diag.* = .{ .line = line, .what = what };
    return error.BadConfig;
}

/// An address a key may be sent to: https, or this computer (a stand-in).
fn safeUrl(v: []const u8) bool {
    return std.mem.startsWith(u8, v, "https://") or std.mem.startsWith(u8, v, "http://127.0.0.1") or std.mem.startsWith(u8, v, "http://localhost");
}

fn amount(a: Allocator, diag: *Diag, e: ini.Entry) !i64 {
    const n = std.fmt.parseInt(i64, e.value, 10) catch -1;
    if (n < 0) return bad(diag, e.line, try std.fmt.allocPrint(a, "{s} takes a whole number, zero or more, in the currency's smallest unit", .{e.key}));
    return n;
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
        } else if (eql(e.section, "payrun")) {
            c.payrun_on = true;
            if (eql(e.key, "suppliers")) {
                c.payrun_suppliers = e.value;
            } else if (eql(e.key, "history")) {
                if (e.value.len == 0) return bad(diag, e.line, "history is a file's name");
                c.payrun_history = e.value;
            } else if (eql(e.key, "duplicate_days")) {
                c.payrun.duplicate_days = try days(a, diag, e);
            } else if (eql(e.key, "out_of_line")) {
                c.payrun.out_of_line = std.fmt.parseInt(u32, e.value, 10) catch return bad(diag, e.line, "out_of_line takes a whole number: how many times the largest payment before (0: not looked for)");
            } else if (eql(e.key, "currency")) {
                if (e.value.len != 3) return bad(diag, e.line, "currency is three letters, as eur");
                c.payrun.currency = try std.ascii.allocLowerString(a, e.value);
            } else if (eql(e.key, "invoices")) {
                if (e.value.len == 0) return bad(diag, e.line, "invoices is a folder's name");
                c.payrun_invoices = e.value;
            } else if (eql(e.key, "whitelist")) {
                if (!eql(e.value, "yes") and !eql(e.value, "no")) return bad(diag, e.line, "whitelist is yes or no");
                c.payrun_whitelist = eql(e.value, "yes");
            } else if (eql(e.key, "whitelist_url")) {
                if (!safeUrl(e.value)) return bad(diag, e.line, "whitelist_url is https://..., or http:// on this computer only (the stand-in)");
                c.whitelist_url = e.value;
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[payrun] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "ledger")) {
            c.ledger_on = true;
            if (eql(e.key, "provider")) {
                if (!eql(e.value, "xero")) return bad(diag, e.line, "provider is xero: the one accounting program paymcp reads");
            } else if (eql(e.key, "url") or eql(e.key, "token_url")) {
                if (!safeUrl(e.value)) return bad(diag, e.line, "an address is https://..., or http:// on this computer only (the stand-in): a secret isn't sent in the clear");
                if (eql(e.key, "url")) c.ledger.url = e.value else c.ledger.token_url = e.value;
            } else if (eql(e.key, "history_days")) {
                c.ledger.history_days = try days(a, diag, e);
                if (c.ledger.history_days < 30 or c.ledger.history_days > 3650) return bad(diag, e.line, "history_days is 30 to 3650");
            } else if (eql(e.key, "changed_days")) {
                c.ledger.changed_days = try days(a, diag, e);
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[ledger] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "bills")) {
            c.bills_on = true;
            if (eql(e.key, "read")) {
                var list: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, e.value, ',');
                while (it.next()) |raw| {
                    const v = std.mem.trim(u8, raw, " \t");
                    if (v.len == 0) continue;
                    if (!eql(v, "anthropic") and !eql(v, "openai") and !eql(v, "aws")) return bad(diag, e.line, "read names anthropic, openai and aws, with commas between");
                    try list.append(a, v);
                }
                if (list.items.len == 0) return bad(diag, e.line, "read names anthropic, openai and aws, with commas between");
                c.bills_read = list.items;
            } else if (eql(e.key, "days")) {
                c.bills.days = try days(a, diag, e);
                if (c.bills.days < 14 or c.bills.days > 90) return bad(diag, e.line, "days is 14 to 90");
            } else if (eql(e.key, "jump")) {
                c.bills.jump = std.fmt.parseInt(u32, e.value, 10) catch return bad(diag, e.line, "jump takes a whole number: how many times the usual (0: not looked for)");
                if (c.bills.jump == 1) return bad(diag, e.line, "jump is 2 or more, or 0: once the usual is every day");
            } else if (eql(e.key, "jump_above")) {
                c.bills.jump_above = try amount(a, diag, e);
            } else if (eql(e.key, "doubled_above")) {
                c.bills.doubled_above = try amount(a, diag, e);
            } else if (eql(e.key, "budget")) {
                c.bills.budget = try amount(a, diag, e);
            } else if (eql(e.key, "currency")) {
                if (e.value.len != 3) return bad(diag, e.line, "currency is three letters, as usd");
                c.bills.currency = try std.ascii.allocLowerString(a, e.value);
            } else if (eql(e.key, "anthropic_url") or eql(e.key, "openai_url") or eql(e.key, "aws_url")) {
                if (!safeUrl(e.value)) return bad(diag, e.line, "an address is https://..., or http:// on this computer only (the stand-in): a key isn't sent in the clear");
                if (eql(e.key, "anthropic_url")) c.anthropic_url = e.value else if (eql(e.key, "openai_url")) c.openai_url = e.value else c.aws_url = e.value;
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[bills] has no setting {s}", .{e.key}));
        } else if (eql(e.section, "changes")) {
            if (eql(e.key, "allow")) {
                if (!eql(e.value, "yes") and !eql(e.value, "no")) return bad(diag, e.line, "allow is yes or no");
                c.changes = eql(e.value, "yes");
            } else if (eql(e.key, "max_amount")) {
                c.max_change = std.fmt.parseInt(i64, e.value, 10) catch return bad(diag, e.line, "max_amount takes a whole number, in the currency's smallest unit");
                if (c.max_change < 0) return bad(diag, e.line, "max_amount is zero or more");
            } else return bad(diag, e.line, try std.fmt.allocPrint(a, "[changes] has no setting {s}", .{e.key}));
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
        } else return bad(diag, e.line, try std.fmt.allocPrint(a, "no section [{s}]: the file has [stripe], [billing], [plans], [disputes], [letters], [changes], [payrun], [ledger] and [bills]", .{e.section}));
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

/// Why the second key (STRIPE_WRITE_KEY) can't be used, or null. It is
/// the key that may change things: a restricted key with Write on what
/// paymcp changes (subscriptions, invoices, disputes) and nothing else. A
/// live account's secret key is refused here too.
pub fn writeKeyProblem(c: *const Config, key: []const u8) ?[]const u8 {
    if (key.len == 0) return "STRIPE_WRITE_KEY isn't set: the second key, which may change subscriptions, invoices and disputes (README, Changing things)";
    if (std.mem.startsWith(u8, key, "sk_test_")) return if (c.mode == .live) "STRIPE_WRITE_KEY is a sandbox key and the file says mode = live" else null;
    if (std.mem.startsWith(u8, key, "sk_")) return "STRIPE_WRITE_KEY is a secret key, which can do everything. Make a restricted key with Write on subscriptions, invoices and disputes only (README, Changing things)";
    const test_key = std.mem.startsWith(u8, key, "rk_test_");
    const live_key = std.mem.startsWith(u8, key, "rk_live_");
    if (!test_key and !live_key) return "STRIPE_WRITE_KEY doesn't look like a restricted key (rk_test_... or rk_live_...)";
    if (c.mode == .sandbox and live_key) return "STRIPE_WRITE_KEY is a live key and the file says mode = sandbox";
    if (c.mode == .live and test_key) return "STRIPE_WRITE_KEY is a sandbox key and the file says mode = live";
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

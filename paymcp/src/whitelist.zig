//! Poland's list of VAT payers ("the white list"), asked whether each
//! account a batch pays to is registered to the supplier's tax number.
//! The tax office publishes it and takes questions without a key:
//!
//!   GET /api/check/nip/{NIP}/bank-account/{26 digits}?date=YYYY-MM-DD
//!   -> {"result":{"accountAssigned":"TAK","requestId":"...","requestDateTime":"..."}}
//!
//! It is the one part of the payment-run check that reaches outside this
//! computer, and only when the pay file says so: each question sends one
//! supplier's tax number and account to the tax office, as paying them by
//! the rules already requires looking it up. The answer's confirmation
//! number is kept: it is what shows the account was checked on that day.
//!
//! Written from the service's documentation (version 1.6.2, read
//! 2026-11-27) and tried against the stand-in only.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = @import("http.zig");
const jv = @import("jv.zig");
const audit = @import("audit.zig");
const model = @import("model.zig");
const payrun = @import("payrun.zig");
const ksef = @import("ksef.zig");

pub const default_url = "https://wykazpodatnikowvat.mf.gov.pl";
/// The most questions one check asks (the service allows 5000 a day).
pub const max_asked = 300;

/// Waits between tries, in ms (tests: none).
pub var wait_ms: u32 = 1000;

pub const Result = struct {
    findings: []audit.Finding = &.{},
    /// Lines for paymcp's list: each answer with its confirmation number.
    lines: []const u8 = "",
    asked: usize = 0,
    assigned: usize = 0,
    /// Payments with no Polish tax number or no 26-digit account: not asked about.
    skipped: usize = 0,
    /// What wasn't answered, and why.
    gaps: []const []const u8 = &.{},
};

const Answer = union(enum) {
    assigned: struct { yes: bool, id: []const u8, when: []const u8 },
    /// The list refused the question (a number it calls invalid): why.
    refused: []const u8,
    /// The day's limit is used up, or the list can't be reached: why.
    stopped: []const u8,
};

fn meaning(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "WL-115")) return "it calls the tax number invalid";
    if (std.mem.eql(u8, code, "WL-111")) return "it calls the account number invalid";
    if (std.mem.eql(u8, code, "WL-113") or std.mem.eql(u8, code, "WL-114")) return "the tax number isn't ten digits";
    if (std.mem.eql(u8, code, "WL-109") or std.mem.eql(u8, code, "WL-110")) return "the account isn't 26 digits";
    if (std.mem.eql(u8, code, "WL-195") or std.mem.eql(u8, code, "WL-196")) return "the list is being updated: ask again in a while";
    return "it refused the question";
}

fn ask(a: Allocator, io: Io, hc: *http.Client, nip: []const u8, account: []const u8, day: []const u8) !Answer {
    const path = try std.fmt.allocPrint(a, "/api/check/nip/{s}/bank-account/{s}?date={s}", .{ nip, account, day });
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const ans = http.fetch(hc, a, .{ .method = .GET, .path = path, .limits = .{ .idle_ms = 20_000, .total_ms = 40_000 } }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            if (tries < 2) {
                if (wait_ms > 0) io.sleep(.fromMilliseconds(@as(i64, wait_ms) << @intCast(tries)), .awake) catch {};
                continue;
            }
            return .{ .stopped = try std.fmt.allocPrint(a, "the list couldn't be reached ({s})", .{@errorName(e)}) };
        };
        const v = jv.parse(a, ans.body);
        if (ans.status == 200) {
            const said = jv.str(jv.at(v, &.{ "result", "accountAssigned" })) orelse return .{ .stopped = "the list's answer wasn't one this reader knows" };
            const yes = std.mem.eql(u8, said, "TAK");
            if (!yes and !std.mem.eql(u8, said, "NIE")) return .{ .stopped = "the list's answer wasn't one this reader knows" };
            return .{ .assigned = .{ .yes = yes, .id = jv.str(jv.at(v, &.{ "result", "requestId" })) orelse "", .when = jv.str(jv.at(v, &.{ "result", "requestDateTime" })) orelse "" } };
        }
        const code = jv.str(jv.get(v, "code")) orelse "";
        if (ans.status == 429 or std.mem.eql(u8, code, "WL-191")) return .{ .stopped = "the list's limit of questions for today from this address is used up (WL-191)" };
        if (ans.status >= 500 and tries < 2) {
            if (wait_ms > 0) io.sleep(.fromMilliseconds(@as(i64, wait_ms) << @intCast(tries)), .awake) catch {};
            continue;
        }
        if (ans.status == 400 and code.len > 0) return .{ .refused = try std.fmt.allocPrint(a, "{s} ({s})", .{ meaning(code), code }) };
        return .{ .stopped = try std.fmt.allocPrint(a, "the list answered {d}{s}{s}", .{ ans.status, if (code.len > 0) " " else "", code }) };
    }
}

/// Asks the list about each tax number and account of `list` (a pair
/// once). `gpa` holds the connection while it runs.
pub fn check(gpa: Allocator, a: Allocator, io: Io, url: []const u8, list: []const payrun.Row, batch: []const u8, now: i64) !Result {
    var res: Result = .{};
    var out: std.ArrayList(audit.Finding) = .empty;
    var lines: std.ArrayList(u8) = .empty;
    var gaps: std.ArrayList([]const u8) = .empty;
    const target = http.Target.parse(url) catch {
        try gaps.append(a, try std.fmt.allocPrint(a, "The tax office's list wasn't asked: {s} isn't an address paymcp can reach", .{url}));
        res.gaps = gaps.items;
        return res;
    };
    var hc: http.Client = .init(gpa, io, target);
    defer hc.deinit();
    hc.user_agent = "paymcp";
    const day = try model.day(a, now);
    const Pair = struct { nip: []const u8, account: []const u8 };
    var seen: std.ArrayList(Pair) = .empty;
    var stopped: ?[]const u8 = null;
    var unasked: usize = 0;
    for (list) |r| {
        const nip = try ksef.nipOf(a, r.id);
        const account = try ksef.nrb(a, r.account);
        var digits = account.len == 26;
        for (account) |ch| {
            if (!std.ascii.isDigit(ch)) digits = false;
        }
        if (nip.len == 0 or !digits) {
            res.skipped += 1;
            continue;
        }
        const again = for (seen.items) |p| {
            if (std.mem.eql(u8, p.nip, nip) and std.mem.eql(u8, p.account, account)) break true;
        } else false;
        if (again) continue;
        try seen.append(a, .{ .nip = nip, .account = account });
        if (stopped != null or res.asked >= max_asked) {
            unasked += 1;
            continue;
        }
        switch (try ask(a, io, &hc, nip, account, day)) {
            .stopped => |why| {
                stopped = why;
                unasked += 1;
            },
            .refused => |why| {
                res.asked += 1;
                try gaps.append(a, try std.fmt.allocPrint(a, "The tax office's list gave no answer for {s} (tax number {s}, account {s}): {s}", .{ r.supplier, nip, account, why }));
            },
            .assigned => |got| {
                res.asked += 1;
                if (got.yes) res.assigned += 1;
                try lines.print(a, "{{\"at\":{d},\"event\":\"whitelist\",\"batch\":{f},\"nip\":\"{s}\",\"account\":\"{s}\",\"assigned\":{},\"id\":{f},\"when\":{f}}}\n", .{ now, std.json.fmt(batch, .{}), nip, account, got.yes, std.json.fmt(got.id, .{}), std.json.fmt(got.when, .{}) });
                if (!got.yes) try out.append(a, .{
                    .kind = .account_unregistered,
                    .key = try std.fmt.allocPrint(a, "account_unregistered:{s}:{s}:{s}", .{ batch, nip, account }),
                    .customer = r.id,
                    .name = r.supplier,
                    .amount = r.amount,
                    .currency = r.currency,
                    .per = .once,
                    .what = try std.fmt.allocPrint(a, "{s} is to be paid {s} to account {s}, which the tax office's list does not have for tax number {s} on {s}.", .{ r.supplier, try model.money(a, r.amount, r.currency), account, nip, day }),
                    .rows = try a.dupe(audit.Row, &.{
                        .{ .source = try std.fmt.allocPrint(a, "{s}, line {d}", .{ batch, r.line }), .value = try std.fmt.allocPrint(a, "{s}{s}, {s}, to account {s}", .{ r.supplier, if (r.bill.len > 0) try std.fmt.allocPrint(a, ", bill {s}", .{r.bill}) else "", try model.money(a, r.amount, r.currency), r.account }) },
                        .{ .source = "the tax office's list of VAT payers", .value = try std.fmt.allocPrint(a, "not assigned to tax number {s}; asked {s}, confirmation {s}", .{ nip, if (got.when.len > 0) got.when else day, if (got.id.len > 0) got.id else "not given" }) },
                    }),
                    .proposal = "Don't pay to this account until the supplier has explained it. An account can be missing because it is new and not yet reported, because it is a collective account the list shows only in its own search, or because it isn't theirs. Polish tax rules attach consequences to paying larger invoices to an account that is not on the list: ask your accountant before you do. If it is as it should be, say so (decide ... intended).",
                });
            },
        }
    }
    if (stopped) |why| try gaps.append(a, try std.fmt.allocPrint(a, "The tax office's list stopped answering: {s}. {d} account{s} answered", .{ why, unasked, if (unasked == 1) " asked about wasn't" else "s asked about weren't" }));
    if (stopped == null and unasked > 0) try gaps.append(a, try std.fmt.allocPrint(a, "The tax office's list was asked about the first {d} accounts; {d} more weren't asked about", .{ max_asked, unasked }));
    res.findings = out.items;
    res.lines = lines.items;
    res.gaps = gaps.items;
    return res;
}

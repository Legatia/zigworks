//! Deliveries: parcels the owner waits for, in `state/deliveries` (JSON,
//! written whole). Their tracking numbers and carriers are found here, in
//! a mail's text or the owner's message, by this code, never by a model;
//! a carrier's page is read from this file's own table of addresses (never
//! a link from a mail) and only its status is kept. What is said, and
//! when, is harness's (core.zig): this file never posts, logs or fetches.
const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A carrier: its key, its name as said, its tracking page (`{n}` the
/// number), the words that name it in a text and its mail's domains.
pub const Carrier = struct {
    key: []const u8,
    name: []const u8,
    url: []const u8,
    words: []const []const u8,
    domains: []const []const u8,
    /// Its parcels may wait in a parcel locker.
    lockers: bool = false,
};

pub const carriers = [_]Carrier{
    .{ .key = "inpost", .name = "InPost", .url = "https://api-shipx-pl.easypack24.net/v1/tracking/{n}", .words = &.{ "inpost", "paczkomat", "paczkomatu", "paczkomacie" }, .domains = &.{ "inpost.pl", "inpost.eu" }, .lockers = true },
    .{ .key = "dpd", .name = "DPD", .url = "https://tracktrace.dpd.com.pl/parcelDetails?typ=1&p1={n}", .words = &.{"dpd"}, .domains = &.{ "dpd.com.pl", "dpd.pl", "dpd.com", "dpd.de" } },
    .{ .key = "gls", .name = "GLS", .url = "https://gls-group.com/app/service/open/rest/PL/pl/rstt001?match={n}", .words = &.{"gls"}, .domains = &.{ "gls-poland.com", "gls-group.eu", "gls-group.com" } },
    .{ .key = "dhl", .name = "DHL", .url = "https://www.dhl.com/pl-pl/home/tracking/tracking-parcel.html?submit=1&tracking-id={n}", .words = &.{"dhl"}, .domains = &.{ "dhl.com", "dhl.pl", "dhl.de" } },
    .{ .key = "ups", .name = "UPS", .url = "https://www.ups.com/track?tracknum={n}", .words = &.{"ups"}, .domains = &.{"ups.com"} },
    .{ .key = "poczta", .name = "Poczta Polska", .url = "https://emonitoring.poczta-polska.pl/?numer={n}", .words = &.{ "poczta polska", "pocztex", "poczty polskiej" }, .domains = &.{"poczta-polska.pl"} },
    .{ .key = "fedex", .name = "FedEx", .url = "https://www.fedex.com/fedextrack/?trknbr={n}", .words = &.{"fedex"}, .domains = &.{"fedex.com"} },
};

pub fn carrier(key: []const u8) ?Carrier {
    for (carriers) |c| if (std.mem.eql(u8, c.key, key)) return c;
    return null;
}

/// A tracking number, and its carrier's key ("" not known).
pub const Found = struct { number: []const u8, carrier: []const u8 = "" };

/// Words that say a run of digits near them is a parcel's number.
const labels = [_][]const u8{ "tracking", "track", "numer przesyłki", "nr przesyłki", "numer paczki", "nr paczki", "przesyłka", "przesyłki", "paczka", "paczki", "parcel", "package", "shipment", "sendung", "awb", "waybill", "list przewozowy", "śledź" };

/// What the owner says of a parcel ("track", "my DPD parcel").
const intents = [_][]const u8{ "track", "tracking", "parcel", "package", "paczka", "paczkę", "przesyłka", "przesyłkę", "śledź", "delivery", "shipment" };

fn isWordAt(low: []const u8, at: usize, len: usize) bool {
    const before = at == 0 or !std.ascii.isAlphanumeric(low[at - 1]);
    const after = at + len >= low.len or !std.ascii.isAlphanumeric(low[at + len]);
    return before and after;
}

fn hasWord(low: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, low, from, word)) |at| : (from = at + 1) {
        if (isWordAt(low, at, word.len)) return true;
    }
    return false;
}

fn lower(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

/// The carriers a text names (words) or its sender's address is of.
fn named(low: []const u8, sender: []const u8) [carriers.len]bool {
    var out: [carriers.len]bool = @splat(false);
    for (carriers, 0..) |c, i| {
        for (c.words) |w| if (hasWord(low, w)) {
            out[i] = true;
        };
        const at = std.mem.lastIndexOfScalar(u8, sender, '@') orelse continue;
        const dom = std.mem.trimEnd(u8, sender[at + 1 ..], "> \t");
        for (c.domains) |d| if (std.ascii.eqlIgnoreCase(dom, d) or (dom.len > d.len and std.ascii.endsWithIgnoreCase(dom, d) and dom[dom.len - d.len - 1] == '.')) {
            out[i] = true;
        };
    }
    return out;
}

fn onlyNamed(n: [carriers.len]bool) []const u8 {
    var key: []const u8 = "";
    for (n, 0..) |x, i| if (x) {
        if (key.len > 0) return "";
        key = carriers[i].key;
    };
    return key;
}

fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return s.len > 0;
}

fn allAlpha(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isAlphabetic(ch)) return false;
    return s.len > 0;
}

/// A number's carrier by its shape alone; null: its shape says nothing,
/// "" a parcel number of no carrier known (a postal one not Polish).
fn byShape(tok: []const u8) ?[]const u8 {
    if (tok.len == 18 and std.ascii.startsWithIgnoreCase(tok, "1z")) return "ups";
    if (tok.len >= 12 and tok.len <= 26 and std.ascii.startsWithIgnoreCase(tok, "jjd") and allDigits(tok[3..])) return "dhl";
    if (tok.len == 13 and allAlpha(tok[0..2]) and allDigits(tok[2..11]) and allAlpha(tok[11..13])) return if (std.ascii.eqlIgnoreCase(tok[11..13], "pl")) "poczta" else "";
    if (tok.len == 14 and allDigits(tok[0..13]) and (tok[13] == 'U' or tok[13] == 'u')) return "dpd";
    return null;
}

/// Tracking numbers in a mail (`text` its subject and text, `sender` its
/// From): the shapes that are one alone, and runs of 10–30 digits within
/// 60 bytes after a tracking word; the carrier from the shape, else the
/// one carrier the mail names, else a 24-digit run is InPost's.
pub fn find(a: Allocator, text: []const u8, sender: []const u8) ![]const Found {
    return scan(a, text, sender, false);
}

/// The parcel in the owner's message, when it says one ("track
/// 1Z999AA10123456784", "my DPD parcel 1000123456789U"): a number and a
/// carrier's name or a word like track, parcel, package, paczka.
pub fn fromMessage(a: Allocator, text: []const u8) !?Found {
    const low = try lower(a, text);
    var intent = false;
    for (intents) |w| if (hasWord(low, w)) {
        intent = true;
    };
    const n = named(low, "");
    for (n) |x| if (x) {
        intent = true;
    };
    if (!intent) return null;
    const got = try scan(a, text, "", true);
    if (got.len != 1) return null;
    return got[0];
}

fn scan(a: Allocator, text: []const u8, sender: []const u8, any_digits: bool) ![]const Found {
    const low = try lower(a, text);
    const n = named(low, sender);
    const only = onlyNamed(n);
    var out: std.ArrayList(Found) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isAlphanumeric(text[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and std.ascii.isAlphanumeric(text[j])) j += 1;
        const tok = text[i..j];
        const at = i;
        i = j;
        if (tok.len < 10 or tok.len > 30) continue;
        var key: []const u8 = undefined;
        if (byShape(tok)) |k| {
            key = if (k.len > 0) k else only;
        } else if (allDigits(tok)) {
            if (!any_digits) {
                const from = at -| 60;
                const near = low[from..at];
                const labelled = for (labels) |l| {
                    if (std.mem.indexOf(u8, near, l) != null) break true;
                } else false;
                if (!labelled) continue;
            }
            key = if (only.len > 0) only else if (tok.len == 24) "inpost" else "";
        } else continue;
        const number = try std.ascii.allocUpperString(a, tok);
        const seen = for (out.items) |f| {
            if (std.mem.eql(u8, f.number, number)) break true;
        } else false;
        if (!seen) try out.append(a, .{ .number = number, .carrier = key });
    }
    return out.items;
}

/// A tracking number as harness puts it in an address: letters and digits,
/// up to 40.
pub fn validNumber(s: []const u8) bool {
    if (s.len < 6 or s.len > 40) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

/// Carrier `key`'s tracking page for `number` (`base` set: the tests'
/// stand-in, `BASEKEY-NUMBER`).
pub fn pageUrl(a: Allocator, key: []const u8, number: []const u8, base: []const u8) !?[]const u8 {
    if (!validNumber(number)) return null;
    if (base.len > 0) return try std.fmt.allocPrint(a, "{s}{s}-{s}", .{ base, key, number });
    const c = carrier(key) orelse return null;
    return try std.mem.replaceOwned(u8, a, c.url, "{n}", number);
}

// ---- a page's status ----

pub const Status = enum {
    unknown,
    transit,
    out,
    ready,
    delivered,

    fn rank(s: Status) u8 {
        return @backingInt(s);
    }
};

const delivered_words = [_][]const u8{ "delivered", "doręczona", "doręczono", "dostarczona", "dostarczono", "odebrana", "odebrano", "zugestellt" };
const out_words = [_][]const u8{ "out for delivery", "out_for_delivery", "wydana do doręczenia", "wydanie przesyłki do doręczenia", "przekazana do doręczenia", "przekazano do doręczenia", "w doręczeniu", "in zustellung" };
const ready_words = [_][]const u8{ "ready for pickup", "ready to pick up", "ready to pickup", "ready_to_pickup", "ready for collection", "gotowa do odbioru", "czeka na odbiór", "w paczkomacie" };
/// A line with one of these says what may come, or what didn't.
const not_yet = [_][]const u8{ "not ", "undelivered", "will be", "to be ", "estimated", "expected", "scheduled", "attempt", "failed", "nie ", "niedoręcz", "przewidywan", "planowan", "zostanie", "can be", "may be" };

/// The status a line says, null for none (or one only foreseen).
fn lineStatus(line: []const u8) ?Status {
    if (line.len == 0 or line.len > 160) return null;
    for (not_yet) |w| if (std.mem.indexOf(u8, line, w) != null) return null;
    for (delivered_words) |w| if (hasWord(line, w)) return .delivered;
    for (ready_words) |w| if (std.mem.indexOf(u8, line, w) != null) return .ready;
    for (out_words) |w| if (std.mem.indexOf(u8, line, w) != null) return .out;
    return null;
}

/// The furthest a page (`text`: JSON as it came, or a page's readable
/// text) says a parcel got: JSON's first value of a key with "status" in
/// it, else line by line.
pub fn statusOf(a: Allocator, text: []const u8) Status {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{})) |v| {
            if (jsonStatus(v)) |s| {
                const low = lower(a, s) catch return .unknown;
                const sp = std.mem.replaceOwned(u8, a, low, "_", " ") catch return .unknown;
                return lineStatus(sp) orelse .transit;
            }
            return .unknown;
        } else |_| {}
    }
    const low = lower(a, text) catch return .unknown;
    var best: Status = .unknown;
    var it = std.mem.splitScalar(u8, low, '\n');
    while (it.next()) |l| {
        const s = lineStatus(std.mem.trim(u8, l, " \t\r")) orelse continue;
        if (s.rank() > best.rank()) best = s;
    }
    return best;
}

fn jsonStatus(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| if (std.ascii.findIgnoreCase(e.key_ptr.*, "status") != null and e.value_ptr.* == .string) return e.value_ptr.string;
            var it2 = o.iterator();
            while (it2.next()) |e| if (jsonStatus(e.value_ptr.*)) |s| return s;
        },
        .array => |l| for (l.items) |x| if (jsonStatus(x)) |s| return s,
        else => {},
    }
    return null;
}

// ---- state/deliveries ----

pub const Parcel = struct {
    number: []const u8 = "",
    carrier: []const u8 = "",
    /// Who sent it (the mail's sender's name), "" not known.
    from: []const u8 = "",
    /// The owner's day it is due (mailmcp's `day`), 0 not known.
    day: i64 = 0,
    added: i64 = 0,
    status: Status = .unknown,
    /// Its first read only notes what the page says (a parcel from mail).
    quiet: bool = false,
    next_read: i64 = 0,
    /// When it was delivered (or reached a locker), 0 not yet.
    done_at: i64 = 0,
    said_out: bool = false,
    said_ready: bool = false,
    said_delivered: bool = false,
};

pub const File = struct {
    parcels: []const Parcel = &.{},
    /// The ids of the delivery mails already read.
    mail_seen: []const []const u8 = &.{},
    /// When the mail is read next.
    mail_next: i64 = 0,
};

pub fn parseFile(a: Allocator, text: []const u8) !File {
    return std.json.parseFromSliceLeaky(File, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn fileText(a: Allocator, f: File) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, f, .{});
}

/// At most, parcels kept.
pub const max_parcels = 50;
/// At most, mail ids kept.
pub const max_seen = 500;

/// `f` with parcel `p` added (or its carrier and sender filled in when it
/// is there); `added` false when it was there.
pub fn add(a: Allocator, f: File, p: Parcel) !struct { file: File, added: bool } {
    var list: std.ArrayList(Parcel) = .empty;
    try list.appendSlice(a, f.parcels);
    for (list.items) |*x| if (std.mem.eql(u8, x.number, p.number)) {
        if (x.carrier.len == 0) x.carrier = p.carrier;
        if (x.from.len == 0) x.from = p.from;
        if (x.day == 0) x.day = p.day;
        var out = f;
        out.parcels = list.items;
        return .{ .file = out, .added = false };
    };
    if (list.items.len >= max_parcels) _ = list.orderedRemove(0);
    try list.append(a, p);
    var out = f;
    out.parcels = list.items;
    return .{ .file = out, .added = true };
}

/// Parcels dropped: delivered over 2 days ago, or added over 30 days ago.
pub fn prune(a: Allocator, f: File, now_s: i64) !File {
    var list: std.ArrayList(Parcel) = .empty;
    for (f.parcels) |p| {
        if (p.done_at > 0 and now_s - p.done_at > 2 * 86400) continue;
        if (now_s - p.added > 30 * 86400) continue;
        try list.append(a, p);
    }
    var out = f;
    out.parcels = list.items;
    return out;
}

/// When a parcel is read next, after a read at `now_s`: every 30 minutes
/// once it is out for delivery, else every 2 hours; never once delivered
/// or at a locker. (Reads happen 08:00–20:00, harness's side.)
pub fn nextRead(s: Status, now_s: i64) i64 {
    return switch (s) {
        .delivered, .ready => std.math.maxInt(i64),
        .out => now_s + 30 * 60,
        else => now_s + 2 * 3600,
    };
}

/// "DPD", or "" for a carrier not known.
pub fn carrierName(key: []const u8) []const u8 {
    return if (carrier(key)) |c| c.name else "";
}

/// "your DPD parcel from Zalando", "your parcel …4567".
fn parcelWords(a: Allocator, p: Parcel) ![]const u8 {
    const name = carrierName(p.carrier);
    const sp: []const u8 = if (name.len > 0) " " else "";
    if (p.from.len > 0) return std.fmt.allocPrint(a, "Your {s}{s}parcel from {s}", .{ name, sp, util.cut(p.from, 60) });
    return std.fmt.allocPrint(a, "Your {s}{s}parcel {s}", .{ name, sp, p.number });
}

/// The line for parcel `p` now at `s`; null: nothing to say.
pub fn lineFor(a: Allocator, p: Parcel, s: Status) !?[]const u8 {
    const who = try parcelWords(a, p);
    return switch (s) {
        .out => try std.fmt.allocPrint(a, "{s} is out for delivery.", .{who}),
        .ready => if ((carrier(p.carrier) orelse carriers[1]).lockers) try std.fmt.allocPrint(a, "{s} is waiting at the parcel locker.", .{who}) else try std.fmt.allocPrint(a, "{s} is ready to collect.", .{who}),
        .delivered => try std.fmt.allocPrint(a, "{s} was delivered.", .{who}),
        else => null,
    };
}

/// A parcel in `/deliveries`: "DPD 1000123456789U from Zalando: out for delivery."
pub fn listLine(a: Allocator, p: Parcel) ![]const u8 {
    const name = carrierName(p.carrier);
    const state: []const u8 = switch (p.status) {
        .unknown => "not read yet",
        .transit => "on its way",
        .out => "out for delivery",
        .ready => "ready to collect",
        .delivered => "delivered",
    };
    const from = if (p.from.len > 0) try std.fmt.allocPrint(a, " from {s}", .{util.cut(p.from, 60)}) else "";
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}: {s}.", .{ name, if (name.len > 0) " " else "", p.number, from, state });
}

/// The doorbell's hint: "probably the DPD parcel" when one is out for
/// delivery or due today (`today` the owner's day) and not delivered or at
/// a locker; "probably the DPD or the InPost parcel" for two; "probably a
/// parcel" for more, or one of no carrier known. Null: none expected.
pub fn hint(a: Allocator, parcels: []const Parcel, today: i64) !?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var unknown = false;
    for (parcels) |p| {
        if (p.status == .delivered or p.status == .ready) continue;
        if (p.status != .out and p.day != today) continue;
        const n = carrierName(p.carrier);
        if (n.len == 0) {
            unknown = true;
            continue;
        }
        const seen = for (names.items) |x| {
            if (std.mem.eql(u8, x, n)) break true;
        } else false;
        if (!seen) try names.append(a, n);
    }
    if (names.items.len == 0 and !unknown) return null;
    if (unknown or names.items.len > 2) return "probably a parcel";
    if (names.items.len == 1) return try std.fmt.allocPrint(a, "probably the {s} parcel", .{names.items[0]});
    return try std.fmt.allocPrint(a, "probably the {s} or the {s} parcel", .{ names.items[0], names.items[1] });
}

/// mailmcp's `mail_list` items as deliveries read them.
pub const MailItem = struct { id: []const u8 = "", uid: i64 = 0, from: []const u8 = "", from_addr: []const u8 = "", subject: []const u8 = "", day: []const u8 = "" };

pub fn mailItems(a: Allocator, text: []const u8) []const MailItem {
    return std.json.parseFromSliceLeaky([]const MailItem, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch &.{};
}

/// A read mail (mailmcp's `mail_read` with `format: json`): its subject
/// and text, its sender.
pub const MailRead = struct { from: []const u8 = "", from_addr: []const u8 = "", subject: []const u8 = "", text: []const u8 = "" };

pub fn mailRead(a: Allocator, text: []const u8) ?MailRead {
    return std.json.parseFromSliceLeaky(MailRead, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// "Zalando" for "Zalando <noreply@zalando.pl>".
pub fn senderName(from: []const u8) []const u8 {
    const lt = std.mem.indexOfScalar(u8, from, '<') orelse return if (std.mem.indexOfScalar(u8, from, '@') != null) "" else std.mem.trim(u8, from, " \"");
    return std.mem.trim(u8, from[0..lt], " \"");
}

/// "2026-11-24" as a day number; 0 for anything else.
pub fn dayOf(s: []const u8) i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return 0;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return 0;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return 0;
    if (m < 1 or m > 12 or d < 1 or d > 31) return 0;
    return util.daysFromCivil(y, m, d);
}

// ---- tests ----

const t = std.testing;

fn expectFound(got: []const Found, want: []const Found) !void {
    if (got.len != want.len) {
        for (got) |g| std.debug.print("found {s} {s}\n", .{ g.number, g.carrier });
        return error.TestUnexpectedResult;
    }
    for (got, want) |g, w| {
        try t.expectEqualStrings(w.number, g.number);
        try t.expectEqualStrings(w.carrier, g.carrier);
    }
}

test "tracking_numbers_in_mail" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFound(try find(a, "Twoja przesyłka jest w drodze\nNumer przesyłki: 1000123456789U\nDPD Polska", "DPD Polska <powiadomienia@dpd.com.pl>"), &.{.{ .number = "1000123456789U", .carrier = "dpd" }});
    try expectFound(try find(a, "Twoja paczka 602677439331630337653846 jest w drodze do Paczkomatu KRA01M", "InPost <powiadomienia@inpost.pl>"), &.{.{ .number = "602677439331630337653846", .carrier = "inpost" }});
    try expectFound(try find(a, "Your package 1z999aa10123456784 has shipped.", "UPS <mcinfo@ups.com>"), &.{.{ .number = "1Z999AA10123456784", .carrier = "ups" }});
    // the shop's mail: its order number is no parcel; the one carrier it names
    try expectFound(try find(a, "Your order 1234567890 has shipped with DHL.\nTracking number: 00340434161094015902\nCall us: +48 600 100 200", "Zalando <info@service-mail.zalando.pl>"), &.{.{ .number = "00340434161094015902", .carrier = "dhl" }});
    try expectFound(try find(a, "Przesyłka polecona RR123456789PL została nadana.", "Poczta Polska <noreply@poczta-polska.pl>"), &.{.{ .number = "RR123456789PL", .carrier = "poczta" }});
    // two carriers named: an unlabelled shape is still its own; a labelled run of digits has none
    try expectFound(try find(a, "DPD or GLS will bring it. Tracking: 12345678901", "shop@example.com"), &.{.{ .number = "12345678901", .carrier = "" }});
    try expectFound(try find(a, "Thanks for your order 123456789012.", "shop@example.com"), &.{});
    // Windows line ends read the same
    try expectFound(try find(a, "Numer przesyłki:\r\n1000123456789U\r\n", "DPD <x@dpd.com.pl>"), &.{.{ .number = "1000123456789U", .carrier = "dpd" }});
}

test "an_owners_message_names_a_parcel" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ups = (try fromMessage(a, "track 1Z999AA10123456784")).?;
    try t.expectEqualStrings("ups", ups.carrier);
    try t.expectEqualStrings("dpd", (try fromMessage(a, "my DPD parcel 1000123456789U")).?.carrier);
    try t.expectEqualStrings("inpost", (try fromMessage(a, "InPost 602677439331630337653846")).?.carrier);
    try t.expectEqualStrings("dhl", (try fromMessage(a, "DHL 1234567890")).?.carrier);
    const unknown = (try fromMessage(a, "track my package 1234567890")).?;
    try t.expectEqualStrings("", unknown.carrier);
    try t.expectEqualStrings("1234567890", unknown.number);
    for ([_][]const u8{ "call 600100200 please", "order 123456789012 from allegro", "the parcel is late", "hello" }) |x| {
        if (try fromMessage(a, x)) |f| {
            std.debug.print("{s}: {s}\n", .{ x, f.number });
            return error.TestUnexpectedResult;
        }
    }
    try t.expect(validNumber("1000123456789U"));
    try t.expect(!validNumber("12/../x"));
    try t.expectEqualStrings("https://tracktrace.dpd.com.pl/parcelDetails?typ=1&p1=1000123456789U", (try pageUrl(a, "dpd", "1000123456789U", "")).?);
    try t.expectEqualStrings("http://127.0.0.1:9/page/track-dpd-1000123456789U", (try pageUrl(a, "dpd", "1000123456789U", "http://127.0.0.1:9/page/track-")).?);
    try t.expect((try pageUrl(a, "nosuch", "1000123456789U", "")) == null);
}

test "a_pages_status" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(Status.out, statusOf(a, "{\"tracking_number\":\"602677439331630337653846\",\"status\":\"out_for_delivery\",\"tracking_details\":[{\"status\":\"sent_from_source_branch\"}]}"));
    try t.expectEqual(Status.delivered, statusOf(a, "{\"status\":\"delivered\"}"));
    try t.expectEqual(Status.ready, statusOf(a, "{\"status\":\"ready_to_pickup\"}"));
    try t.expectEqual(Status.transit, statusOf(a, "{\"status\":\"confirmed\"}"));
    try t.expectEqual(Status.delivered, statusOf(a, "{\"tuStatus\":[{\"progressBar\":{\"statusInfo\":\"DELIVERED\"}}]}"));
    try t.expectEqual(Status.unknown, statusOf(a, "{\"error\":\"not found\"}"));
    try t.expectEqual(Status.delivered, statusOf(a, "Śledzenie przesyłki\n23.11.2026 14:10 Przesyłka doręczona do odbiorcy\n23.11.2026 08:02 Wydanie przesyłki do doręczenia"));
    try t.expectEqual(Status.out, statusOf(a, "Out for delivery\r\nYour parcel will be delivered today"));
    try t.expectEqual(Status.unknown, statusOf(a, "Estimated delivery: Thursday\nIn transit"));
    try t.expectEqual(Status.unknown, statusOf(a, "Parcel not delivered: nobody was home"));
}

test "parcels_round_trip_and_lines" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1_800_000_000;
    var f: File = .{};
    const r1 = try add(a, f, .{ .number = "1000123456789U", .carrier = "dpd", .added = now });
    try t.expect(r1.added);
    const r2 = try add(a, r1.file, .{ .number = "1000123456789U", .carrier = "dpd", .from = "Zalando", .added = now });
    try t.expect(!r2.added);
    f = r2.file;
    try t.expectEqualStrings("Zalando", f.parcels[0].from);
    var back = try parseFile(a, try fileText(a, f));
    try t.expectEqual(1, back.parcels.len);
    try t.expectEqualStrings("Your DPD parcel from Zalando is out for delivery.", (try lineFor(a, back.parcels[0], .out)).?);
    try t.expectEqualStrings("Your DPD parcel from Zalando was delivered.", (try lineFor(a, back.parcels[0], .delivered)).?);
    try t.expectEqualStrings("Your InPost parcel 602677439331630337653846 is waiting at the parcel locker.", (try lineFor(a, .{ .number = "602677439331630337653846", .carrier = "inpost" }, .ready)).?);
    try t.expect((try lineFor(a, back.parcels[0], .transit)) == null);
    try t.expectEqualStrings("DPD 1000123456789U from Zalando: not read yet.", try listLine(a, back.parcels[0]));
    try t.expectEqual(now + 1800, nextRead(.out, now));
    try t.expectEqual(now + 7200, nextRead(.transit, now));
    // delivered over 2 days ago, added over 30 days ago: dropped
    back.parcels = &.{ .{ .number = "A1234567890", .added = now, .done_at = now - 3 * 86400 }, .{ .number = "B1234567890", .added = now - 31 * 86400 }, .{ .number = "C1234567890", .added = now } };
    const kept = try prune(a, back, now);
    try t.expectEqual(1, kept.parcels.len);
    try t.expectEqualStrings("C1234567890", kept.parcels[0].number);
    try t.expectEqualStrings("Zalando", senderName("Zalando <info@zalando.pl>"));
    try t.expectEqualStrings("", senderName("info@zalando.pl"));
    try t.expectEqual(util.daysFromCivil(2026, 11, 24), dayOf("2026-11-24"));
}

test "the_hint" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const today: i64 = 20000;
    try t.expect((try hint(a, &.{}, today)) == null);
    try t.expect((try hint(a, &.{.{ .number = "x", .carrier = "dpd", .status = .transit, .day = today + 1 }}, today)) == null);
    try t.expectEqualStrings("probably the DPD parcel", (try hint(a, &.{.{ .number = "x", .carrier = "dpd", .status = .out }}, today)).?);
    try t.expectEqualStrings("probably the DHL parcel", (try hint(a, &.{.{ .number = "x", .carrier = "dhl", .day = today }}, today)).?);
    try t.expectEqualStrings("probably the DPD or the InPost parcel", (try hint(a, &.{ .{ .number = "x", .carrier = "dpd", .status = .out }, .{ .number = "y", .carrier = "inpost", .day = today } }, today)).?);
    // delivered, or in a locker: not at the door
    try t.expect((try hint(a, &.{ .{ .number = "x", .carrier = "dpd", .status = .delivered, .day = today }, .{ .number = "y", .carrier = "inpost", .status = .ready, .day = today } }, today)) == null);
    try t.expectEqualStrings("probably a parcel", (try hint(a, &.{.{ .number = "x", .status = .out }}, today)).?);
}

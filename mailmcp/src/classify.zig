//! What a mail is about (bill, delivery, travel, invitation) and the
//! amount and dates it gives, in English and Polish.
const std = @import("std");
const Allocator = std.mem.Allocator;
const mime = @import("mime.zig");

pub const Kind = enum { bill, delivery, travel, invitation, other };

pub const Found = struct {
    kind: Kind = .other,
    /// Bills: "1234.50 PLN"; "" when none is found.
    amount: []const u8 = "",
    /// Bills: the due date, "YYYY-MM-DD".
    due: []const u8 = "",
    /// Deliveries: the day it comes, "YYYY-MM-DD".
    day: []const u8 = "",
};

/// What `m` is about, from its subject and the first 8 KB of its text.
/// Invitations come first, then travel, bills and deliveries; a word in
/// the subject counts before any in the body. Bills get an amount and a
/// due date, deliveries a day, when the mail gives them. `utc_offset_min`
/// is the reader's zone, for "today".
pub fn classify(a: Allocator, m: *const mime.Mail, utc_offset_min: i32) !Found {
    if (isInvitation(m)) return .{ .kind = .invitation };
    const subject = try fold(a, m.subject);
    const body = try fold(a, m.text[0..@min(m.text.len, 8192)]);
    const all = try std.mem.concat(a, u8, &.{ subject, " | ", body });

    const order = [_]Kind{ .travel, .bill, .delivery };
    var kind: Kind = .other;
    for ([_][]const u8{ subject, body }) |part| {
        for (order) |k| {
            if (hasAny(part, wordsFor(k))) {
                kind = k;
                break;
            }
        }
        if (kind != .other) break;
    }

    const when: When = .{ .mail_s = m.date_s, .offset_min = utc_offset_min };
    var f: Found = .{ .kind = kind };
    switch (kind) {
        .bill => {
            if (try moneyNear(a, all, &amount_words)) |money| f.amount = money;
            if (try dateNear(a, all, &due_words, when)) |d| f.due = d;
        },
        .delivery => {
            if (try dateNear(a, all, &day_words, when)) |d| {
                f.day = d;
            } else if (m.date_s != null and hasAny(all, &today_words)) {
                var buf: [10]u8 = undefined;
                f.day = try a.dupe(u8, localDate(&buf, m.date_s.?, utc_offset_min));
            }
        },
        else => {},
    }
    return f;
}

/// "YYYY-MM-DD" of `secs` (since 1970 UTC) in a zone `utc_offset_min`
/// east of UTC.
pub fn localDate(buf: *[10]u8, secs: i64, utc_offset_min: i32) []const u8 {
    const c = mime.civilFromDays(@divFloor(secs + @as(i64, utc_offset_min) * 60, 86400));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(c.y, 0))), c.m, c.d }) catch buf[0..0];
}

pub const daysFromCivil = mime.daysFromCivil;

fn isInvitation(m: *const mime.Mail) bool {
    if (m.invite) |inv| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, inv.method, " "), "REQUEST")) return true;
    }
    const s = std.mem.trim(u8, m.subject, " ");
    for ([_][]const u8{ "Invitation:", "Updated invitation", "Zaproszenie:", "Zaktualizowane zaproszenie" }) |p| {
        if (std.ascii.startsWithIgnoreCase(s, p)) return true;
    }
    return false;
}

// Words are matched in folded text (see `fold`). A trailing "*" matches
// any ending (Polish cases: "faktur*" is faktura, faktury, fakturę).

const travel_words = [_][]const u8{
    "flight",            "flights",            "boarding pass",        "boarding passes",
    "itinerary",         "e-ticket",           "e-tickets",            "eticket",
    "booking reference", "booking confirmed",  "booking confirmation", "check-in",
    "your trip",         "gate",               "pnr",                  "hotel reservation",
    "hotel booking",     "hotel confirmation", "your stay",            "lot",
    "lotu",              "loty",               "lotem",                "locie",
    "wylot",             "wylotu",             "wylotem",              "przylot",
    "przylotu",          "pokladow*",          "lotnicz*",             "lotnisk*",
    "odpraw*",           "rezerwacja hotelu",  "rezerwacji hotelu",    "twoj pobyt",
    "twoja podroz",      "twojej podrozy",
};

const bill_words = [_][]const u8{
    "invoice*",           "bill",              "bills",               "your statement",
    "statement is ready", "statement balance", "account statement",   "monthly statement",
    "e-statement",        "payment due",       "amount due",          "amount to pay",
    "balance due",        "faktur*",           "rachunek",            "do zaplaty",
    "termin platnosci",   "kwota do zaplaty",  "wezwanie do zaplaty", "platnosc",
    "platnosci",
};

const delivery_words = [_][]const u8{
    "shipped",         "out for delivery", "your package",       "your parcel",
    "tracking number", "delivered",        "arriving today",     "arriving tomorrow",
    "przesylk*",       "paczk*",           "kurier*",            "inpost",
    "dpd",             "dhl",              "ups",                "fedex",
    "gls",             "w drodze",         "zostanie doreczona", "zostanie dostarczona",
    "do odbioru",
};

const amount_words = [_][]const u8{ "amount due", "total", "do zaplaty", "kwota", "suma", "razem", "to pay" };
const due_words = [_][]const u8{ "due", "due date", "pay by", "payment due", "termin platnosci", "zaplac do", "platne do", "do dnia", "termin" };
const day_words = [_][]const u8{ "delivery", "arrives", "arriving", "doreczeni*", "dostaw*", "dostarcz*", "odbioru" };
const today_words = [_][]const u8{ "today", "out for delivery", "dzis", "dzisiaj" };

fn wordsFor(k: Kind) []const []const u8 {
    return switch (k) {
        .travel => &travel_words,
        .bill => &bill_words,
        .delivery => &delivery_words,
        else => &.{},
    };
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Where `pat` first occurs in `hay` at or after `from` as a whole word.
fn findWord(hay: []const u8, pat: []const u8, from: usize) ?usize {
    const stem = pat.len > 0 and pat[pat.len - 1] == '*';
    const p = if (stem) pat[0 .. pat.len - 1] else pat;
    var pos = from;
    while (std.mem.indexOfPos(u8, hay, pos, p)) |i| {
        const end = i + p.len;
        if ((i == 0 or !isWordByte(hay[i - 1])) and (stem or end == hay.len or !isWordByte(hay[end]))) return i;
        pos = i + 1;
    }
    return null;
}

fn hasAny(hay: []const u8, pats: []const []const u8) bool {
    for (pats) |p| {
        if (findWord(hay, p, 0) != null) return true;
    }
    return false;
}

/// Lowercase ASCII with Polish (and common Latin) letters reduced to
/// their base letter and every run of whitespace, no-break spaces
/// included, made one space.
fn fold(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var space = false;
    var lower: [1]u8 = undefined;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        lower[0] = std.ascii.toLower(c);
        var n: usize = 1;
        var cp: u21 = c;
        if (c >= 0x80) {
            n = std.unicode.utf8ByteSequenceLength(c) catch 1;
            cp = if (i + n <= s.len) std.unicode.utf8Decode(s[i .. i + n]) catch 0xFFFD else 0xFFFD;
            if (cp == 0xFFFD) n = 1;
        }
        const base: ?[]const u8 = switch (cp) {
            ' ', '\t', '\r', '\n', 0x0C, 0xA0, 0x2007, 0x2009, 0x202F => null,
            'A'...'Z' => &lower,
            0x104, 0x105, 0xC0...0xC5, 0xE0...0xE5 => "a",
            0x106, 0x107, 0xC7, 0xE7, 0x10C, 0x10D => "c",
            0x118, 0x119, 0xC8...0xCB, 0xE8...0xEB, 0x11A, 0x11B => "e",
            0xCC...0xCF, 0xEC...0xEF => "i",
            0x141, 0x142 => "l",
            0x143, 0x144, 0xD1, 0xF1 => "n",
            0xD2...0xD6, 0xF2...0xF6 => "o",
            0x15A, 0x15B, 0x160, 0x161 => "s",
            0xD9...0xDC, 0xF9...0xFC => "u",
            0x179...0x17E => "z",
            0xDF => "ss",
            else => s[i .. i + n],
        };
        i += n;
        if (base) |b| {
            if (space and out.items.len > 0) try out.append(a, ' ');
            space = false;
            try out.appendSlice(a, b);
        } else {
            space = true;
        }
    }
    return out.items;
}

const Hit = struct { start: usize, end: usize };

/// Every whole-word occurrence of any of `pats`, by position.
fn hits(a: Allocator, hay: []const u8, pats: []const []const u8) ![]Hit {
    var list: std.ArrayList(Hit) = .empty;
    for (pats) |pat| {
        const len = if (pat[pat.len - 1] == '*') pat.len - 1 else pat.len;
        var pos: usize = 0;
        while (findWord(hay, pat, pos)) |i| {
            try list.append(a, .{ .start = i, .end = i + len });
            pos = i + 1;
        }
    }
    std.mem.sort(Hit, list.items, {}, struct {
        fn less(_: void, x: Hit, y: Hit) bool {
            return x.start < y.start;
        }
    }.less);
    return list.items;
}

/// Bytes after a keyword in which its amount or date is looked for.
const reach = 100;

// ---------------------------------------------------------------- money

const Money = struct { start: usize, end: usize, text: []const u8 };

/// The first amount within reach after one of `pats`, else the first
/// amount anywhere, as "1234.50 PLN".
fn moneyNear(a: Allocator, t: []const u8, pats: []const []const u8) !?[]const u8 {
    var all: std.ArrayList(Money) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        if (std.ascii.isDigit(t[i]) and (i == 0 or !(std.ascii.isDigit(t[i - 1]) or t[i - 1] == '.' or t[i - 1] == ','))) {
            if (numberAt(t, i)) |num| {
                if (currencyBefore(t[0..i]) orelse currencyAfter(t[num.end..])) |cur| {
                    const text = try std.fmt.allocPrint(a, "{s}.{s} {s}", .{ try wholeDigits(a, t[i..num.int_end]), &num.frac, cur });
                    try all.append(a, .{ .start = i, .end = num.end, .text = text });
                }
                i = num.end;
                continue;
            }
        }
        i += 1;
    }
    if (all.items.len == 0) return null;
    for (try hits(a, t, pats)) |h| {
        for (all.items) |mo| {
            if (mo.start >= h.end and mo.start < h.end + reach) return mo.text;
        }
    }
    return all.items[0].text;
}

/// A number written with thousands separators (space, ".", ",") and a
/// decimal point or comma, starting at `t[i]`: where its whole part ends,
/// its two decimals, and where it ends.
fn numberAt(t: []const u8, i: usize) ?struct { int_end: usize, frac: [2]u8, end: usize } {
    var j = i;
    while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
    if (j - i > 15) return null;
    var sep: u8 = 0;
    if (j - i <= 3) {
        var groups: usize = 0;
        while (groups < 5 and j < t.len and (t[j] == ' ' or t[j] == '.' or t[j] == ',') and
            (sep == 0 or t[j] == sep) and threeDigits(t, j + 1))
        {
            sep = t[j];
            j += 4;
            groups += 1;
        }
    }
    const int_end = j;
    var frac: [2]u8 = .{ '0', '0' };
    if (j + 1 < t.len and (t[j] == '.' or t[j] == ',') and t[j] != sep and std.ascii.isDigit(t[j + 1])) {
        var k = j + 1;
        while (k < t.len and std.ascii.isDigit(t[k])) k += 1;
        if (k - (j + 1) <= 2) {
            frac[0] = t[j + 1];
            if (k - (j + 1) == 2) frac[1] = t[j + 2];
            j = k;
        }
    }
    return .{ .int_end = int_end, .frac = frac, .end = j };
}

/// The digits of `s` without separators or leading zeros.
fn wholeDigits(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (!std.ascii.isDigit(c) or (c == '0' and out.items.len == 0)) continue;
        try out.append(a, c);
    }
    return if (out.items.len == 0) "0" else out.items;
}

fn threeDigits(t: []const u8, k: usize) bool {
    if (k + 3 > t.len) return false;
    for (t[k .. k + 3]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return k + 3 == t.len or !std.ascii.isDigit(t[k + 3]);
}

const currencies = [_]struct { []const u8, []const u8 }{
    .{ "zlotych", "PLN" },  .{ "zloty", "PLN" },  .{ "zl", "PLN" },  .{ "pln", "PLN" },
    .{ "\u{20AC}", "EUR" }, .{ "euro", "EUR" },   .{ "eur", "EUR" }, .{ "$", "USD" },
    .{ "usd", "USD" },      .{ "\u{A3}", "GBP" }, .{ "gbp", "GBP" },
};

/// The currency written right before a number (one space allowed).
fn currencyBefore(t: []const u8) ?[]const u8 {
    const s = if (std.mem.endsWith(u8, t, " ")) t[0 .. t.len - 1] else t;
    for (currencies) |c| {
        if (!std.mem.endsWith(u8, s, c[0])) continue;
        const at = s.len - c[0].len;
        if (std.ascii.isAlphabetic(c[0][0]) and at > 0 and isWordByte(s[at - 1])) continue;
        return c[1];
    }
    return null;
}

/// The currency written right after a number (one space allowed).
fn currencyAfter(t: []const u8) ?[]const u8 {
    const s = if (std.mem.startsWith(u8, t, " ")) t[1..] else t;
    for (currencies) |c| {
        if (!std.mem.startsWith(u8, s, c[0])) continue;
        if (std.ascii.isAlphabetic(c[0][0]) and c[0].len < s.len and isWordByte(s[c[0].len])) continue;
        return c[1];
    }
    return null;
}

// ---------------------------------------------------------------- dates

const When = struct { mail_s: ?i64, offset_min: i32 };

const month_words = [_]struct { []const u8, u32 }{
    .{ "january", 1 },   .{ "february", 2 },      .{ "march", 3 },      .{ "april", 4 },
    .{ "may", 5 },       .{ "june", 6 },          .{ "july", 7 },       .{ "august", 8 },
    .{ "september", 9 }, .{ "october", 10 },      .{ "november", 11 },  .{ "december", 12 },
    .{ "jan", 1 },       .{ "feb", 2 },           .{ "mar", 3 },        .{ "apr", 4 },
    .{ "jun", 6 },       .{ "jul", 7 },           .{ "aug", 8 },        .{ "sep", 9 },
    .{ "sept", 9 },      .{ "oct", 10 },          .{ "nov", 11 },       .{ "dec", 12 },
    .{ "stycznia", 1 },  .{ "lutego", 2 },        .{ "marca", 3 },      .{ "kwietnia", 4 },
    .{ "maja", 5 },      .{ "czerwca", 6 },       .{ "lipca", 7 },      .{ "sierpnia", 8 },
    .{ "wrzesnia", 9 },  .{ "pazdziernika", 10 }, .{ "listopada", 11 }, .{ "grudnia", 12 },
};

/// The month named by the word at `t[i]`, and where the word ends.
fn monthAt(t: []const u8, i: usize) ?struct { m: u32, end: usize } {
    if (i > 0 and isWordByte(t[i - 1])) return null;
    var j = i;
    while (j < t.len and std.ascii.isAlphabetic(t[j])) j += 1;
    if (j < t.len and isWordByte(t[j])) return null;
    for (month_words) |mw| {
        if (std.mem.eql(u8, t[i..j], mw[0])) return .{ .m = mw[1], .end = if (j < t.len and t[j] == '.') j + 1 else j };
    }
    return null;
}

/// Digits at `t[i]` (at most `max`, not followed by another digit).
fn digitsAt(t: []const u8, i: usize, min: usize, max: usize) ?struct { v: u32, end: usize } {
    var j = i;
    var v: u32 = 0;
    while (j < t.len and std.ascii.isDigit(t[j])) : (j += 1) {
        if (j - i == max) return null;
        v = v * 10 + (t[j] - '0');
    }
    if (j - i < min) return null;
    return .{ .v = v, .end = j };
}

/// The date written at `t[i]` as "YYYY-MM-DD".
fn dateAt(a: Allocator, t: []const u8, i: usize, when: When) !?[]const u8 {
    var y: ?i64 = null;
    var mo: u32 = 0;
    var d: u32 = 0;
    if (std.ascii.isDigit(t[i])) {
        if (i > 0 and (std.ascii.isDigit(t[i - 1]) or t[i - 1] == '.' or t[i - 1] == '/' or t[i - 1] == '-')) return null;
        const first = digitsAt(t, i, 1, 4) orelse return null;
        const j = first.end;
        if (first.end - i == 4) {
            // 2026-12-01
            if (j + 1 >= t.len or t[j] != '-') return null;
            const m2 = digitsAt(t, j + 1, 1, 2) orelse return null;
            if (m2.end + 1 >= t.len or t[m2.end] != '-') return null;
            const d2 = digitsAt(t, m2.end + 1, 1, 2) orelse return null;
            y = first.v;
            mo = m2.v;
            d = d2.v;
        } else if (first.end - i <= 2 and j + 1 < t.len and (t[j] == '.' or t[j] == '/' or t[j] == '-') and std.ascii.isDigit(t[j + 1])) {
            // 01.12.2026, 1/12/2026: day first
            const sep = t[j];
            const m2 = digitsAt(t, j + 1, 1, 2) orelse return null;
            if (m2.end + 1 >= t.len or t[m2.end] != sep) return null;
            const y2 = digitsAt(t, m2.end + 1, 4, 4) orelse return null;
            y = y2.v;
            mo = m2.v;
            d = first.v;
        } else if (first.end - i <= 2) {
            // 1 December 2026, 1 grudnia, 1. grudnia
            var k = j;
            if (k < t.len and t[k] == '.') k += 1;
            if (k < t.len and t[k] == ' ') k += 1;
            const mon = (if (k < t.len) monthAt(t, k) else null) orelse return null;
            d = first.v;
            mo = mon.m;
            if (mon.end + 1 < t.len and t[mon.end] == ' ') {
                if (digitsAt(t, mon.end + 1, 4, 4)) |y2| y = y2.v;
            }
        } else return null;
    } else if (std.ascii.isAlphabetic(t[i])) {
        // December 1, 2026; Dec 1
        const mon = monthAt(t, i) orelse return null;
        if (mon.end + 1 >= t.len or t[mon.end] != ' ') return null;
        const d2 = digitsAt(t, mon.end + 1, 1, 2) orelse return null;
        var k = d2.end;
        if (k < t.len and t[k] == ',') k += 1;
        if (k + 1 < t.len and t[k] == ' ') {
            if (digitsAt(t, k + 1, 4, 4)) |y2| y = y2.v;
        }
        mo = mon.m;
        d = d2.v;
    } else return null;

    if (mo < 1 or mo > 12) return null;
    const year = y orelse blk: {
        const mail_s = when.mail_s orelse return null;
        const local_days = @divFloor(mail_s + @as(i64, when.offset_min) * 60, 86400);
        const this = mime.civilFromDays(local_days).y;
        if (d < 1 or d > mime.daysInMonth(this, mo)) return null;
        break :blk if (mime.daysFromCivil(this, mo, d) < local_days - 60) this + 1 else this;
    };
    if (year < 1970 or year > 9999 or d < 1 or d > mime.daysInMonth(year, mo)) return null;
    return try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), mo, d });
}

/// The first date within reach after one of `pats`.
fn dateNear(a: Allocator, t: []const u8, pats: []const []const u8, when: When) !?[]const u8 {
    for (try hits(a, t, pats)) |h| {
        var i = h.end;
        while (i < @min(t.len, h.end + reach)) : (i += 1) {
            if (try dateAt(a, t, i, when)) |d| return d;
        }
    }
    return null;
}

const testing = std.testing;

/// 2026-11-25 09:00 UTC.
const nov25: i64 = 1795597200;
const day_s: i64 = 86400;

fn expectFound(want: Found, m: mime.Mail, utc_offset_min: i32) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try classify(arena.allocator(), &m, utc_offset_min);
    testing.expectEqual(want.kind, got.kind) catch |e| {
        std.debug.print("subject: {s}\n", .{m.subject});
        return e;
    };
    try testing.expectEqualStrings(want.amount, got.amount);
    try testing.expectEqualStrings(want.due, got.due);
    try testing.expectEqualStrings(want.day, got.day);
}

test "a_bill_with_amount_and_due_date" {
    try expectFound(.{ .kind = .bill, .amount = "249.99 PLN", .due = "2026-12-05" }, .{
        .subject = "Faktura VAT nr 12/2026 za listopad",
        .text = "Dzień dobry,\n\nw załączeniu przesyłamy fakturę VAT nr 12/2026 za usługi telekomunikacyjne.\n\n" ++
            "Do zapłaty: 249,99 zł\nTermin płatności: 05.12.2026\nNumer rachunku do wpłaty: 12 3456 7890 1234 5678 9012 3456\n\n" ++
            "Pozdrawiamy\nZespół Obsługi Klienta",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .bill, .amount = "1045.20 GBP", .due = "2026-12-12" }, .{
        .subject = "Your bill is ready",
        .text = "Hello Jan,\n\nYour latest bill is now available.\nAmount due: £1,045.20\n" ++
            "We'll collect it by Direct Debit on or after 12 December 2026.\nDue date: 12 December 2026\n",
        .date_s = nov25,
    }, 0);
    try expectFound(.{ .kind = .bill, .amount = "1234.56 USD", .due = "2026-12-15" }, .{
        .subject = "Your Visa statement is ready",
        .text = "Statement balance: $1,234.56\nMinimum payment: $35.00\nPayment due date: Dec 15, 2026\n",
        .date_s = nov25,
    }, -300);
    try expectFound(.{ .kind = .bill, .amount = "1234.50 PLN", .due = "2027-01-03" }, .{
        .subject = "Wezwanie do zapłaty",
        .text = "Szanowny Panie,\nkwota do zapłaty: 1 234,50 zł. Prosimy o wpłatę do dnia 3 stycznia.",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .bill, .amount = "1299.00 EUR", .due = "2026-12-01" }, .{
        .subject = "Invoice INV-2026-0042",
        .text = "Invoice INV-2026-0042\nItems: 3\nTotal: 1.299,00 €\nPay by: 2026-12-01\n",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .bill, .amount = "99.00 PLN" }, .{
        .subject = "Rachunek za prąd",
        .text = "Razem do zapłaty: PLN 99.00",
        .date_s = nov25,
    }, 60);
    // The amount after the keyword wins over an earlier one.
    try expectFound(.{ .kind = .bill, .amount = "60.00 EUR" }, .{
        .subject = "Your invoice",
        .text = "Subscription €50.00, tax €10.00.\nAmount to pay: €60.00",
        .date_s = nov25,
    }, 60);

    const dues = [_][]const u8{
        "Termin płatności: 1.12.2026",
        "Termin płatności: 01/12/2026",
        "Termin płatności: 1 grudnia 2026",
        "Termin platnosci: 1 grudnia 2026 r.",
        "Zapłać do 1 grudnia",
        "Płatne do: 2026-12-01",
        "Due date: December 1, 2026",
        "Pay by Dec 1, 2026",
        "Payment due: 1 Dec 2026",
        "Due: 1 December",
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (dues) |d| {
        const text = try std.fmt.allocPrint(arena.allocator(), "Faktura nr 7/2026\nDo zapłaty: 10,00 zł\n{s}\n", .{d});
        expectFound(.{ .kind = .bill, .amount = "10.00 PLN", .due = "2026-12-01" }, .{
            .subject = "Faktura",
            .text = text,
            .date_s = nov25 - 5 * day_s,
        }, 60) catch |e| {
            std.debug.print("due line: {s}\n", .{d});
            return e;
        };
    }
}

test "a_delivery_today" {
    // 2026-11-23 06:12 UTC, 07:12 in Warsaw.
    const mon_morning: i64 = 1795458600 - 12 * 3600 + 42 * 60;
    try expectFound(.{ .kind = .delivery, .day = "2026-11-23" }, .{
        .subject = "Twoja paczka jest w drodze!",
        .text = "Paczka nr 620111222333444555666777 zostanie doręczona dzisiaj przez kuriera InPost.",
        .date_s = mon_morning,
    }, 60);
    // 23:30 UTC is already the next day in Warsaw.
    try expectFound(.{ .kind = .delivery, .day = "2026-11-24" }, .{
        .subject = "Out for delivery: \"Anker USB-C Charger\" and 1 more item",
        .text = "Your package will arrive by 9 PM.\nTrack package",
        .date_s = 1795458600 + 5 * 3600,
    }, 60);
    try expectFound(.{ .kind = .delivery, .day = "2026-11-26" }, .{
        .subject = "DPD Polska: Twoja przesyłka",
        .text = "Planowane doręczenie: 26.11.2026 między 10:00 a 13:00.\nKwota pobrania: 0,00 zł",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .delivery, .day = "2026-11-26" }, .{
        .subject = "Your parcel has shipped",
        .text = "Good news! Estimated delivery: Thursday, November 26\nTracking number: 1Z999AA10123456784",
        .date_s = nov25 - day_s,
    }, 0);
    try expectFound(.{ .kind = .delivery, .day = "2026-11-27" }, .{
        .subject = "Paczka czeka w Paczkomacie WAW123M",
        .text = "Twoja paczka jest do odbioru do 27.11.2026, godz. 08:15. Kod odbioru: 123456.",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .delivery }, .{
        .subject = "Your order has shipped",
        .text = "Track it here: https://example.com/track",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .delivery, .day = "2026-11-25" }, .{
        .subject = "Kurier dostarczy przesyłkę dziś",
        .text = "Przygotuj kod.",
        .date_s = nov25,
    }, 60);
}

test "a_flight_is_travel" {
    try expectFound(.{ .kind = .travel }, .{
        .subject = "Potwierdzenie rezerwacji – lot LO 3923 Warszawa – Kraków",
        .text = "Dziękujemy za rezerwację. Odprawa online rozpocznie się 24 godziny przed wylotem. Cena: 459,00 PLN",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .travel }, .{
        .subject = "Your Ryanair booking confirmation",
        .text = "Booking reference: ABC123\nFlight FR 1234 Kraków – London Stansted\nTotal paid: 89.99 GBP",
        .date_s = nov25,
    }, 60);
    try expectFound(.{ .kind = .travel }, .{ .subject = "Your boarding pass for KRK-STN", .text = "Gate closes 30 minutes before departure." }, 0);
    try expectFound(.{ .kind = .travel }, .{ .subject = "Booking confirmation – Hotel Bristol", .text = "Your stay: 10–12 December 2026" }, 0);
    try expectFound(.{ .kind = .travel }, .{ .subject = "Karta pokładowa – LO 3923", .text = "W załączniku karta pokładowa." }, 0);
    try expectFound(.{ .kind = .travel }, .{ .subject = "E-ticket receipt and invoice", .text = "Invoice attached." }, 0);
    try expectFound(.{ .kind = .travel }, .{ .subject = "Twoja podróż", .text = "Twój lot LO 3923 jest opóźniony. Nowa godzina wylotu: 18:40." }, 0);
}

test "an_invitation_is_an_invitation" {
    try expectFound(.{ .kind = .invitation }, .{ .subject = "Spotkanie", .invite = .{ .method = "REQUEST", .summary = "Spotkanie" } }, 0);
    try expectFound(.{ .kind = .invitation }, .{ .subject = "Invitation: Weekly sync @ Wed Dec 2, 2026 10am - 11am (CET)" }, 0);
    try expectFound(.{ .kind = .invitation }, .{ .subject = "Updated invitation: Weekly sync" }, 0);
    try expectFound(.{ .kind = .invitation }, .{ .subject = "Zaproszenie: Przegląd kwartalny @ wt., 1 gru 2026 09:30 – 10:30" }, 0);
    try expectFound(.{ .kind = .invitation }, .{ .subject = "Faktura – omówienie", .invite = .{ .method = "request" } }, 0);
    try expectFound(.{ .kind = .other }, .{ .subject = "Canceled event: Weekly sync", .invite = .{ .method = "CANCEL" } }, 0);
}

test "others_are_other" {
    try expectFound(.{}, .{ .subject = "Sobota", .text = "Hej, co słychać? Widzimy się w sobotę na obiedzie u rodziców?", .date_s = nov25 }, 60);
    try expectFound(.{}, .{ .subject = "Nowości w naszym sklepie – grudzień", .text = "Sprawdź nowe produkty w naszej ofercie. Rabat 20% na wszystko!", .date_s = nov25 }, 60);
    try expectFound(.{}, .{ .subject = "Re: Projekt", .text = "Przesyłam poprawki do projektu. Dzisiaj wieczorem dokończę resztę.", .date_s = nov25 }, 60);
    try expectFound(.{}, .{}, 0);
}

test "words_not_inside_words" {
    try expectFound(.{}, .{ .subject = "Community update", .text = "The allotment garden and the pilot program were discussed." }, 0);
    try expectFound(.{}, .{ .subject = "Newsletter", .text = "Our startups and user groups navigate billions of rows, billing aside." }, 0);
    try expectFound(.{}, .{ .subject = "Pilotaż programu", .text = "Flota samochodów i zlot fanów." }, 0);
    try expectFound(.{ .kind = .bill }, .{ .subject = "WEZWANIE DO ZAPŁATY", .text = "" }, 0);
    try expectFound(.{ .kind = .bill }, .{ .subject = "Wezwanie do zaplaty", .text = "" }, 0);
    try expectFound(.{ .kind = .delivery }, .{ .subject = "UPS Update: Package Scheduled for Delivery Tomorrow", .text = "" }, 0);
    // A delivery word in the subject beats a bill word only in the body.
    try expectFound(.{ .kind = .delivery }, .{ .subject = "Twoja przesyłka została nadana", .text = "Faktura do zamówienia jest w załączniku." }, 0);
    try expectFound(.{ .kind = .bill }, .{ .subject = "Faktura do zamówienia", .text = "Przesyłka zostanie nadana jutro." }, 0);
}

test "local_dates" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", localDate(&buf, 0, 0));
    try testing.expectEqualStrings("1969-12-31", localDate(&buf, 0, -60));
    try testing.expectEqualStrings("2026-11-23", localDate(&buf, 1795458600, 60));
    try testing.expectEqualStrings("2026-11-24", localDate(&buf, 1795458600 + 5 * 3600, 60));
    try testing.expectEqualStrings("2028-02-29", localDate(&buf, 1835438400, 0));
    try testing.expectEqual(@as(i64, 20788), daysFromCivil(2026, 12, 1));
}

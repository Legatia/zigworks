//! Trips (the household spec, section 1): flights, trains and hotels from
//! the calendar and from travel mail, grouped into trips and kept in
//! `state/trips/` (a file each, `NAME.trip`, written whole); what they make:
//! a check-in line 24 hours before a flight (with the airline's own link),
//! the evening before the trip, the way home for away mode; /trips. Times
//! are kept in UTC with each place's zone where the itinerary gave it.
//! Pure but for `Store`'s files.
const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Who trips' own work is, to the gate, the log and rules (trips.wf's
/// start line names it too). One place, to be renamed together.
pub const who = "schedule:trips";

pub const Kind = enum { flight, train, hotel };

/// One leg: a flight, a train, a hotel stay. Times in UTC; a zone
/// (minutes east) only where the itinerary gave it.
pub const Leg = struct {
    kind: Kind = .flight,
    /// "LO 3921" ("" for a hotel, or a train without one).
    number: []const u8 = "",
    /// "Kraków (KRK)"; a hotel: "".
    from: []const u8 = "",
    /// "Lisbon (LIS)"; a hotel: its name and town.
    to: []const u8 = "",
    start: i64 = 0,
    start_zone: ?i32 = null,
    end: i64 = 0,
    end_zone: ?i32 = null,
    /// The check-in page the mail gave, kept only on the airline's own
    /// domain.
    link: []const u8 = "",
    /// "mail" or "calendar".
    source: []const u8 = "mail",
    /// The mail's uid or the event's id.
    ref: []const u8 = "",
};

pub const Trip = struct {
    v: u32 = 1,
    /// "2026-12-04-lisbon": the file's name.
    name: []const u8 = "",
    /// Where to: "Lisbon".
    place: []const u8 = "",
    legs: []const Leg = &.{},

    pub fn start(tr: Trip) i64 {
        return if (tr.legs.len > 0) tr.legs[0].start else 0;
    }

    /// When the last leg ends (a flight home lands, a hotel's check-out).
    pub fn end(tr: Trip) i64 {
        var e: i64 = 0;
        for (tr.legs) |l| e = @max(e, l.end);
        return e;
    }
};

// ---- calendar events and mail into legs ----

/// A calendar event as trips reads it (Core gives it from the diary's).
pub const CalEvent = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    place: []const u8 = "",
    start: i64 = 0,
    end: i64 = 0,
    all_day: bool = false,
    cancelled: bool = false,
};

/// A flight number in `text` ("LO 3921", "FR1234"): two letters or a letter
/// and a digit, then 1 to 4 digits; null when there is none.
pub fn flightNumber(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 3 <= text.len) : (i += 1) {
        if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) continue;
        const a0 = text[i];
        const a1 = text[i + 1];
        if (!(std.ascii.isUpper(a0) or std.ascii.isDigit(a0)) or !(std.ascii.isUpper(a1) or std.ascii.isDigit(a1))) continue;
        if (!std.ascii.isUpper(a0) and !std.ascii.isUpper(a1)) continue;
        var j = i + 2;
        if (j < text.len and text[j] == ' ') j += 1;
        const d0 = j;
        while (j < text.len and std.ascii.isDigit(text[j]) and j - d0 < 5) j += 1;
        if (j - d0 < 1 or j - d0 > 4) continue;
        if (j < text.len and std.ascii.isAlphanumeric(text[j])) continue;
        return text[i..j];
    }
    return null;
}

fn startsWithWord(text: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.startsWithIgnoreCase(text, w)) return true;
    return false;
}

fn hasWord(text: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.findIgnoreCase(text, w) != null) return true;
    return false;
}

/// Whether a calendar event is a flight: its title says so ("Flight …",
/// "Lot …"), or has a flight number and its place is an airport.
pub fn isFlight(title: []const u8, place: []const u8) bool {
    if (startsWithWord(title, &.{ "flight ", "lot " })) return true;
    return flightNumber(title) != null and hasWord(place, &.{ "airport", "lotnisko", "port lotniczy", "aeroport", "flughafen" });
}

/// "Kraków" of "Kraków (KRK)" or "Kraków Airport, …".
pub fn city(s: []const u8) []const u8 {
    var c = std.mem.trim(u8, s, " ");
    if (std.mem.indexOf(u8, c, " (")) |i| c = c[0..i];
    if (std.mem.indexOfScalar(u8, c, ',')) |i| c = c[0..i];
    // an airport's name: its town is its first word ("Warsaw Chopin Airport")
    if (std.ascii.findIgnoreCase(c, " airport") != null) c = c[0 .. std.mem.indexOfScalar(u8, c, ' ') orelse c.len];
    return std.mem.trim(u8, c, " ");
}

/// "A – B" (or -, →, "to") after a flight's number: its two places.
fn fromTo(rest: []const u8) struct { from: []const u8, to: []const u8 } {
    for ([_][]const u8{ " – ", " - ", " → ", " -> ", " to " }) |sep| if (std.mem.indexOf(u8, rest, sep)) |i| {
        return .{ .from = std.mem.trim(u8, rest[0..i], " "), .to = std.mem.trim(u8, rest[i + sep.len ..], " ") };
    };
    return .{ .from = "", .to = std.mem.trim(u8, rest, " ") };
}

/// The flights, trains and hotel stays among calendar events (data):
/// "Flight LO 3921 Kraków – Lisbon" at an airport, "Train …", "Hotel …".
pub fn fromEvents(a: Allocator, evs: []const CalEvent) ![]Leg {
    var out: std.ArrayList(Leg) = .empty;
    for (evs) |e| {
        if (e.cancelled) continue;
        const title = plainText(e.title);
        const place = plainText(e.place);
        if (isFlight(title, place)) {
            const number = flightNumber(title) orelse "";
            const after = if (number.len > 0) title[(std.mem.indexOf(u8, title, number).? + number.len)..] else title[(std.mem.indexOfScalar(u8, title, ' ') orelse title.len)..];
            const ft = fromTo(after);
            try out.append(a, .{ .kind = .flight, .number = number, .from = if (ft.from.len > 0) ft.from else city(place), .to = ft.to, .start = e.start, .end = @max(e.end, e.start), .source = "calendar", .ref = e.id });
        } else if (startsWithWord(title, &.{ "train ", "pociąg " })) {
            const ft = fromTo(title[(std.mem.indexOfScalar(u8, title, ' ') orelse title.len)..]);
            try out.append(a, .{ .kind = .train, .from = if (ft.from.len > 0) ft.from else city(place), .to = ft.to, .start = e.start, .end = @max(e.end, e.start), .source = "calendar", .ref = e.id });
        } else if (startsWithWord(title, &.{ "hotel ", "stay at ", "airbnb", "nocleg" }) or (e.end - e.start >= 86400 and hasWord(title, &.{ "hotel", "airbnb" }))) {
            const to = if (place.len > 0 and std.mem.indexOf(u8, title, place) == null) try std.fmt.allocPrint(a, "{s}, {s}", .{ title, place }) else title;
            try out.append(a, .{ .kind = .hotel, .to = to, .start = e.start, .end = @max(e.end, e.start), .source = "calendar", .ref = e.id });
        }
    }
    return out.items;
}

/// A text from the mail or calendar made one plain line: control
/// characters, braces and angle brackets out, at most 120 bytes.
fn plainText(s: []const u8) []const u8 {
    const t0 = std.mem.trim(u8, s, " \t\r\n");
    for (t0, 0..) |ch, i| if (ch < 0x20 or ch == '{' or ch == '}' or ch == '<' or ch == '>') return std.mem.trim(u8, t0[0..i], " ");
    return t0[0..@min(t0.len, 120)];
}

/// "+01:00" → 60; null when not one.
pub fn parseZone(v: []const u8) ?i32 {
    if (v.len != 6 or (v[0] != '+' and v[0] != '-') or v[3] != ':') return null;
    const h = std.fmt.parseInt(i32, v[1..3], 10) catch return null;
    const m = std.fmt.parseInt(i32, v[4..6], 10) catch return null;
    if (h > 14 or m > 59) return null;
    return if (v[0] == '-') -(h * 60 + m) else h * 60 + m;
}

/// "2026-12-04 07:15" at `zone` (minutes east) → Unix seconds.
pub fn parseLocal(v: []const u8, zone: i32) ?i64 {
    const s = std.mem.trim(u8, v, " ");
    if (s.len < 16 or s[4] != '-' or s[7] != '-' or (s[10] != ' ' and s[10] != 'T') or s[13] != ':') return null;
    const iso = std.fmt.allocPrint(std.heap.page_allocator, "{s}T{s}:00Z", .{ s[0..10], s[11..16] }) catch return null;
    defer std.heap.page_allocator.free(iso);
    const utc = util.parseIso(iso) orelse return null;
    return utc - @as(i64, zone) * 60;
}

const MailLeg = struct {
    kind: []const u8 = "",
    number: []const u8 = "",
    from: []const u8 = "",
    to: []const u8 = "",
    start: []const u8 = "",
    start_zone: []const u8 = "",
    end: []const u8 = "",
    end_zone: []const u8 = "",
    link: []const u8 = "",
};

/// The legs a model read from a travel mail (its JSON answer, `{"legs":
/// […]}`): times in each place's own time, the owner's (`owner_offset`)
/// where it gave no zone; a check-in link kept only on the airline's own
/// domain. error.NotLegs: the answer isn't that JSON.
pub fn fromMail(a: Allocator, answer: []const u8, ref: []const u8, owner_offset: i32) ![]Leg {
    const open = std.mem.indexOfScalar(u8, answer, '{') orelse return error.NotLegs;
    const close = std.mem.lastIndexOfScalar(u8, answer, '}') orelse return error.NotLegs;
    if (close < open) return error.NotLegs;
    const F = struct { legs: []const MailLeg = &.{} };
    const f = std.json.parseFromSliceLeaky(F, a, answer[open .. close + 1], .{ .ignore_unknown_fields = true }) catch return error.NotLegs;
    var out: std.ArrayList(Leg) = .empty;
    for (f.legs) |m| {
        const kind = std.meta.stringToEnum(Kind, m.kind) orelse continue;
        const sz = parseZone(m.start_zone);
        const ez = parseZone(m.end_zone);
        const start = parseLocal(m.start, sz orelse owner_offset) orelse continue;
        const end = parseLocal(m.end, ez orelse owner_offset) orelse start;
        var leg: Leg = .{ .kind = kind, .number = plainText(m.number), .from = plainText(m.from), .to = plainText(m.to), .start = start, .start_zone = sz, .end = @max(end, start), .end_zone = ez, .source = "mail", .ref = ref };
        if (kind == .flight) {
            if (flightNumber(leg.number)) |n| leg.number = n;
            if (airlineOf(leg.number)) |al| if (linkOk(m.link, al)) {
                leg.link = m.link;
            };
        }
        if (leg.to.len == 0) continue;
        try out.append(a, leg);
    }
    return out.items;
}

// ---- legs into trips ----

fn sameLeg(x: Leg, y: Leg) bool {
    if (x.kind != y.kind) return false;
    if (x.kind == .hotel) return std.ascii.eqlIgnoreCase(city(x.to), city(y.to)) and @abs(x.start - y.start) < 86400;
    if (x.number.len > 0 and y.number.len > 0) return std.mem.eql(u8, squash(x.number), squash(y.number)) and @abs(x.start - y.start) < 12 * 3600;
    return std.ascii.eqlIgnoreCase(city(x.to), city(y.to)) and @abs(x.start - y.start) < 3600;
}

/// "LO3921" of "LO 3921", in a small static buffer ring.
fn squash(s: []const u8) []const u8 {
    const S = struct {
        var bufs: [4][16]u8 = undefined;
        var i: usize = 0;
    };
    S.i = (S.i + 1) % S.bufs.len;
    var n: usize = 0;
    for (s) |ch| if (ch != ' ' and n < 16) {
        S.bufs[S.i][n] = ch;
        n += 1;
    };
    return S.bufs[S.i][0..n];
}

fn sameCity(x: []const u8, y: []const u8) bool {
    return x.len > 0 and std.ascii.eqlIgnoreCase(city(x), city(y));
}

/// A file's name of a trip: its first day and where to.
fn nameOf(a: Allocator, first: i64, place: []const u8) ![]const u8 {
    var tb: [20]u8 = undefined;
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, util.isoTime(&tb, first)[0..10]);
    try o.append(a, '-');
    var dash = false;
    for (place) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try o.append(a, std.ascii.toLower(ch));
            dash = false;
        } else if (!dash and o.items.len > 11 and ch < 0x80) {
            try o.append(a, '-');
            dash = true;
        }
    }
    const s = std.mem.trimEnd(u8, o.items, "-");
    return if (s.len <= 11) std.fmt.allocPrint(a, "{s}trip", .{s}) else s[0..@min(s.len, 64)];
}

/// Where a trip goes: its first flight's or train's destination, else
/// its first hotel's town.
fn placeOf(legs: []const Leg) []const u8 {
    for (legs) |l| if (l.kind != .hotel) return city(l.to);
    for (legs) |l| {
        if (std.mem.lastIndexOf(u8, l.to, ", ")) |i| return l.to[i + 2 ..];
        return l.to;
    }
    return "";
}

/// The trips with `legs` added: the same leg again (a change, a copy in
/// the calendar) replaces it (the mail's kept over the calendar's), a
/// calendar leg by its event's id; legs ended over two days before `now`
/// go. Grouped in order: a leg within 36 hours of the trip so far joins
/// it, and so does the way back to where it began (within 30 days); a
/// trip ends once it is back.
pub fn merge(a: Allocator, trips: []const Trip, legs: []const Leg, now: i64) ![]Trip {
    var all: std.ArrayList(Leg) = .empty;
    for (trips) |tr| try all.appendSlice(a, tr.legs);
    for (legs) |l| {
        var replaced = false;
        for (all.items) |*x| {
            const same_ref = std.mem.eql(u8, x.source, "calendar") and std.mem.eql(u8, l.source, "calendar") and std.mem.eql(u8, x.ref, l.ref);
            if (!same_ref and !sameLeg(x.*, l)) continue;
            // a calendar copy never overrides what the mail said
            if (!(std.mem.eql(u8, l.source, "calendar") and std.mem.eql(u8, x.source, "mail"))) x.* = l;
            replaced = true;
            break;
        }
        if (!replaced) try all.append(a, l);
    }
    var kept: std.ArrayList(Leg) = .empty;
    for (all.items) |l| if (l.end + 2 * 86400 >= now) try kept.append(a, l);
    std.mem.sort(Leg, kept.items, {}, struct {
        fn lt(_: void, x: Leg, y: Leg) bool {
            return x.start < y.start;
        }
    }.lt);
    var out: std.ArrayList(Trip) = .empty;
    var cur: std.ArrayList(Leg) = .empty;
    var cur_end: i64 = 0;
    var closed = false;
    for (kept.items) |l| {
        if (cur.items.len > 0) {
            const origin = cur.items[0].from;
            const back_home = l.kind != .hotel and sameCity(origin, l.to) and l.start <= cur.items[0].start + 30 * 86400;
            const near = l.start <= cur_end + 36 * 3600;
            if (closed or !(near or back_home)) {
                try out.append(a, try tripOf(a, cur.items));
                cur = .empty;
                closed = false;
            } else if (back_home) closed = true;
        }
        if (cur.items.len == 0) cur_end = 0;
        try cur.append(a, l);
        cur_end = @max(cur_end, l.end);
    }
    if (cur.items.len > 0) try out.append(a, try tripOf(a, cur.items));
    return out.items;
}

fn tripOf(a: Allocator, legs: []const Leg) !Trip {
    const place = placeOf(legs);
    return .{ .name = try nameOf(a, legs[0].start, place), .place = place, .legs = try a.dupe(Leg, legs) };
}

/// When you are home again: the last leg's end, and the way home when it
/// ends with a flight or a train.
pub fn backOf(tr: Trip, travel_s: i64) i64 {
    if (tr.legs.len == 0) return 0;
    const last = tr.legs[tr.legs.len - 1];
    return tr.end() + if (last.kind == .hotel) 0 else travel_s;
}

// ---- airlines ----

pub const Airline = struct { code: []const u8, name: []const u8, domain: []const u8 };

const airlines = [_]Airline{
    .{ .code = "LO", .name = "LOT", .domain = "lot.com" },
    .{ .code = "FR", .name = "Ryanair", .domain = "ryanair.com" },
    .{ .code = "W6", .name = "Wizz Air", .domain = "wizzair.com" },
    .{ .code = "LH", .name = "Lufthansa", .domain = "lufthansa.com" },
    .{ .code = "BA", .name = "British Airways", .domain = "britishairways.com" },
    .{ .code = "KL", .name = "KLM", .domain = "klm.com" },
    .{ .code = "AF", .name = "Air France", .domain = "airfrance.com" },
    .{ .code = "U2", .name = "easyJet", .domain = "easyjet.com" },
    .{ .code = "SK", .name = "SAS", .domain = "flysas.com" },
    .{ .code = "AY", .name = "Finnair", .domain = "finnair.com" },
    .{ .code = "OS", .name = "Austrian", .domain = "austrian.com" },
    .{ .code = "LX", .name = "Swiss", .domain = "swiss.com" },
    .{ .code = "IB", .name = "Iberia", .domain = "iberia.com" },
    .{ .code = "TP", .name = "TAP", .domain = "flytap.com" },
    .{ .code = "EW", .name = "Eurowings", .domain = "eurowings.com" },
    .{ .code = "DY", .name = "Norwegian", .domain = "norwegian.com" },
    .{ .code = "VY", .name = "Vueling", .domain = "vueling.com" },
    .{ .code = "AZ", .name = "ITA Airways", .domain = "ita-airways.com" },
    .{ .code = "TK", .name = "Turkish Airlines", .domain = "turkishairlines.com" },
    .{ .code = "EK", .name = "Emirates", .domain = "emirates.com" },
    .{ .code = "QR", .name = "Qatar Airways", .domain = "qatarairways.com" },
    .{ .code = "UA", .name = "United", .domain = "united.com" },
    .{ .code = "DL", .name = "Delta", .domain = "delta.com" },
    .{ .code = "AA", .name = "American Airlines", .domain = "aa.com" },
};

/// The airline of a flight number, from its two-character code.
pub fn airlineOf(number: []const u8) ?Airline {
    if (number.len < 2) return null;
    for (airlines) |al| if (std.ascii.eqlIgnoreCase(number[0..2], al.code)) return al;
    return null;
}

/// Whether `link` is an https address on the airline's own domain (or a
/// subdomain of it): a mail's link anywhere else is never passed on.
pub fn linkOk(link: []const u8, al: Airline) bool {
    const p = "https://";
    if (!std.ascii.startsWithIgnoreCase(link, p)) return false;
    const rest = link[p.len..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..host_end];
    if (std.mem.indexOfAny(u8, host, "@:") != null) return false;
    for (link) |ch| if (ch <= 0x20 or ch == '"' or ch == '<' or ch == '>') return false;
    if (std.ascii.eqlIgnoreCase(host, al.domain)) return true;
    return host.len > al.domain.len + 1 and std.ascii.endsWithIgnoreCase(host, al.domain) and host[host.len - al.domain.len - 1] == '.';
}

// ---- what is said ----

const short_days = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const short_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The date of day number `day` (from 1970-01-01).
fn dateOf(day: i64) struct { m: u32, d: u32 } {
    const z = day + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    return .{ .d = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1), .m = @intCast(if (mp < 10) mp + 3 else mp - 9) };
}

/// "Fri 4 Dec" of `at` at `zone`.
pub fn dayText(a: Allocator, at: i64, zone: i32) ![]const u8 {
    const day = @divFloor(at + @as(i64, zone) * 60, 86400);
    const dt = dateOf(day);
    return std.fmt.allocPrint(a, "{s} {d} {s}", .{ short_days[@intCast(@mod(day + 3, 7))], dt.d, short_months[dt.m - 1] });
}

/// "07:15" of `at` at `zone`.
pub fn clock(a: Allocator, at: i64, zone: i32) ![]const u8 {
    const sod: u64 = @intCast(@mod(at + @as(i64, zone) * 60, 86400));
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ sod / 3600, sod / 60 % 60 });
}

/// "07:15", or "11:30 Lisbon time" where the place's zone isn't yours.
fn placeClock(a: Allocator, at: i64, zone: ?i32, place: []const u8, owner: i32) ![]const u8 {
    const z = zone orelse owner;
    const c = try clock(a, at, z);
    if (z == owner or city(place).len == 0) return c;
    return std.fmt.allocPrint(a, "{s} {s} time", .{ c, city(place) });
}

/// One leg in a line, in each place's own time where known: "Fri 4 Dec
/// 07:15 LO 3921 Kraków → Lisbon, arrives 10:40 Lisbon time".
pub fn legText(a: Allocator, l: Leg, owner: i32) ![]const u8 {
    if (l.kind == .hotel) return std.fmt.allocPrint(a, "{s}: {s} – {s}", .{ l.to, try dayText(a, l.start, l.start_zone orelse owner), try dayText(a, l.end, l.end_zone orelse owner) });
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "{s} {s} ", .{ try dayText(a, l.start, l.start_zone orelse owner), try placeClock(a, l.start, l.start_zone, l.from, owner) });
    if (l.number.len > 0) try o.print(a, "{s} ", .{l.number}) else if (l.kind == .train) try o.appendSlice(a, "train ");
    try o.print(a, "{s} → {s}, arrives {s}", .{ city(l.from), city(l.to), try placeClock(a, l.end, l.end_zone, l.to, owner) });
    return o.items;
}

/// `/trips`: each trip coming or under way, its legs a line each.
pub fn listText(a: Allocator, trips: []const Trip, now: i64, owner: i32) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (trips) |tr| {
        if (tr.legs.len == 0 or tr.end() < now) continue;
        if (o.items.len > 0) try o.appendSlice(a, "\n\n");
        try o.print(a, "{s}, {s} – {s}:", .{ tr.place, try dayText(a, tr.start(), owner), try dayText(a, tr.end(), owner) });
        for (tr.legs) |l| try o.print(a, "\n{s}", .{try legText(a, l, owner)});
    }
    if (o.items.len == 0) return "No trips. They come from your calendar (flights, trains, hotels) and from travel mail.";
    return o.items;
}

/// "today", "tomorrow", or "Fri 4 Dec", of `at` from `now`.
fn dayWord(a: Allocator, at: i64, now: i64, zone: i32) ![]const u8 {
    const d = @divFloor(at + @as(i64, zone) * 60, 86400);
    const today = @divFloor(now + @as(i64, zone) * 60, 86400);
    if (d == today) return "today";
    if (d == today + 1) return "tomorrow";
    return dayText(a, at, zone);
}

/// The check-in line: "Check-in for LO 3921 Kraków → Lisbon (tomorrow
/// 07:15) is open: LINK", the link only on the airline's own domain.
pub fn checkinText(a: Allocator, l: Leg, now: i64, owner: i32) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "Check-in for {s} {s} → {s} ({s} {s}) is open: ", .{ l.number, city(l.from), city(l.to), try dayWord(a, l.start, now, l.start_zone orelse owner), try placeClock(a, l.start, l.start_zone, l.from, owner) });
    if (airlineOf(l.number)) |al| {
        if (l.link.len > 0 and linkOk(l.link, al)) try o.appendSlice(a, l.link) else try o.print(a, "on {s}'s site or app.", .{al.name});
    } else try o.appendSlice(a, "on the airline's site or app.");
    return o.items;
}

/// What to pack for `nights` (the trip's length): clothes for its days,
/// the papers, the chargers; a list the weather can add to.
pub fn packing(a: Allocator, nights: i64, flight: bool) ![]const u8 {
    if (nights <= 0) return if (flight) "your ID or passport, your boarding pass, a charger" else "your ID or passport, a charger";
    return std.fmt.allocPrint(a, "clothes for {d} days, toiletries, your ID or passport{s}, chargers", .{ nights + 1, if (flight) ", your boarding pass" else "" });
}

/// Nights between a trip's first day and its last (the owner's days).
pub fn nightsOf(tr: Trip, owner: i32) i64 {
    const o = @as(i64, owner) * 60;
    return @divFloor(tr.end() + o, 86400) - @divFloor(tr.start() + o, 86400);
}

/// The evening before's first line: "Tomorrow: Lisbon, 3 nights. LO 3921
/// leaves Kraków at 07:15; leave home by 04:45."
pub fn eveningText(a: Allocator, tr: Trip, owner: i32, airport_min: i64, travel_min: i64) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const n = nightsOf(tr, owner);
    try o.print(a, "Tomorrow: {s}", .{tr.place});
    if (n > 0) try o.print(a, ", {d} night{s}", .{ n, if (n == 1) "" else "s" });
    try o.append(a, '.');
    const first = tr.legs[0];
    if (first.kind != .hotel) {
        const lead = (if (first.kind == .flight) airport_min else 0) + travel_min;
        try o.print(a, " {s} leaves {s} at {s}; leave home by {s}.", .{ if (first.number.len > 0) first.number else "The train", city(first.from), try placeClock(a, first.start, first.start_zone, first.from, owner), try clock(a, first.start - lead * 60, owner) });
    }
    return o.items;
}

/// A line due: a flight's check-in, a trip's evening before.
pub const Due = struct { key: []const u8, kind: enum { checkin, evening }, trip: usize, leg: usize };

/// The lines due at `now` not yet `said` (their keys): each flight's
/// check-in from 24 hours before it until 3 hours before; each trip's
/// evening before from `evening` (minutes, the owner's time) on the day
/// before it begins, until it does.
pub fn due(a: Allocator, trips: []const Trip, now: i64, owner: i32, evening: u16, said: []const []const u8) ![]Due {
    var out: std.ArrayList(Due) = .empty;
    const o = @as(i64, owner) * 60;
    for (trips, 0..) |tr, ti| {
        if (tr.legs.len == 0) continue;
        for (tr.legs, 0..) |l, li| if (l.kind == .flight and l.number.len > 0 and now >= l.start - 24 * 3600 and now < l.start - 3 * 3600) {
            const key = try std.fmt.allocPrint(a, "checkin:{s}@{d}", .{ squash(l.number), l.start });
            if (!has(said, key)) try out.append(a, .{ .key = key, .kind = .checkin, .trip = ti, .leg = li });
        };
        const eve = (@divFloor(tr.start() + o, 86400) - 1) * 86400 + @as(i64, evening) * 60 - o;
        if (now >= eve and now < tr.start()) {
            const key = try std.fmt.allocPrint(a, "evening:{s}", .{tr.name});
            if (!has(said, key)) try out.append(a, .{ .key = key, .kind = .evening, .trip = ti, .leg = 0 });
        }
    }
    return out.items;
}

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

// ---- state/trips/ ----

/// What trips keeps beside the trips: the lines said, the mails read,
/// each flight's last status.
pub const Kept = struct {
    v: u32 = 1,
    said: []const Said = &.{},
    mail: []const []const u8 = &.{},
    status: []const Status = &.{},

    pub const Said = struct { key: []const u8, at: i64 };
    /// A flight's status as its source said it last, and when it was asked.
    pub const Status = struct { key: []const u8, text: []const u8, at: i64 = 0 };
};

/// `state/trips/`: a file per trip (`NAME.trip`) and `state.json`.
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dir: []const u8,
    mutex: Io.Mutex = .init,
    job: std.atomic.Value(bool) = .init(false),
    last_job: std.atomic.Value(i64) = .init(std.math.minInt(i64) / 2),
    /// The owner's new mail to read for travel (mailmcp said it changed).
    mail_due: std.atomic.Value(bool) = .init(true),
    next_mail: std.atomic.Value(i64) = .init(0),

    pub fn init(gpa: Allocator, io: Io, dir: []const u8) Store {
        return .{ .gpa = gpa, .io = io, .dir = dir };
    }

    /// Every trip, in `a`, in order.
    pub fn load(s: *Store, a: Allocator) ![]Trip {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.ArrayList(Trip) = .empty;
        var d = Io.Dir.cwd().openDir(s.io, s.dir, .{ .iterate = true }) catch return out.items;
        defer d.close(s.io);
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".trip")) continue;
            const text = d.readFileAlloc(s.io, e.name, a, .limited(1 << 20)) catch continue;
            const tr = std.json.parseFromSliceLeaky(Trip, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
            try out.append(a, tr);
        }
        std.mem.sort(Trip, out.items, {}, struct {
            fn lt(_: void, x: Trip, y: Trip) bool {
                return x.start() < y.start();
            }
        }.lt);
        return out.items;
    }

    /// The trips as `trips` says, each file written whole; files of trips
    /// no longer there removed.
    pub fn save(s: *Store, a: Allocator, trips: []const Trip) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try Io.Dir.cwd().createDirPath(s.io, s.dir);
        for (trips) |tr| {
            const text = try std.json.Stringify.valueAlloc(a, tr, .{});
            try util.writeReplace(s.io, try std.fs.path.join(a, &.{ s.dir, try std.fmt.allocPrint(a, "{s}.trip", .{tr.name}) }), try std.fmt.allocPrint(a, "{s}\n", .{text}));
        }
        var d = Io.Dir.cwd().openDir(s.io, s.dir, .{ .iterate = true }) catch return;
        defer d.close(s.io);
        var gone: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".trip")) continue;
            const name = e.name[0 .. e.name.len - ".trip".len];
            const stays = for (trips) |tr| {
                if (std.mem.eql(u8, tr.name, name)) break true;
            } else false;
            if (!stays) try gone.append(a, try a.dupe(u8, e.name));
        }
        for (gone.items) |n| d.deleteFile(s.io, n) catch {};
    }

    pub fn kept(s: *Store, a: Allocator) Kept {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const text = Io.Dir.cwd().readFileAlloc(s.io, std.fs.path.join(a, &.{ s.dir, "state.json" }) catch return .{}, a, .limited(1 << 20)) catch return .{};
        return std.json.parseFromSliceLeaky(Kept, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
    }

    pub fn keep(s: *Store, a: Allocator, k: Kept) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try Io.Dir.cwd().createDirPath(s.io, s.dir);
        const text = try std.json.Stringify.valueAlloc(a, k, .{});
        try util.writeReplace(s.io, try std.fs.path.join(a, &.{ s.dir, "state.json" }), try std.fmt.allocPrint(a, "{s}\n", .{text}));
    }
};

// ---- tests ----

const t = std.testing;

/// 2026-12-04 00:00 UTC.
const dec4: i64 = 1_796_342_400;

test "legs_from_calendar_flights_and_hotels" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legs = try fromEvents(a, &.{
        .{ .id = "personal/f1", .title = "Flight LO 3921 Kraków – Lisbon", .place = "Kraków Airport (KRK)", .start = dec4 + 6 * 3600 + 15 * 60, .end = dec4 + 10 * 3600 + 40 * 60 },
        .{ .id = "personal/h1", .title = "Hotel Avenida", .place = "Lisbon", .start = dec4, .end = dec4 + 3 * 86400, .all_day = true },
        .{ .id = "work/d1", .title = "Dentist", .place = "Dental clinic", .start = dec4, .end = dec4 + 3600 },
        .{ .id = "work/x", .title = "LH 1623 to Munich", .place = "Warsaw Chopin Airport", .start = dec4, .end = dec4 + 7200 },
        .{ .id = "work/c", .title = "Flight LO 1 Kraków – Oslo", .place = "KRK", .start = dec4, .end = dec4, .cancelled = true },
    });
    try t.expectEqual(3, legs.len);
    try t.expectEqual(Kind.flight, legs[0].kind);
    try t.expectEqualStrings("LO 3921", legs[0].number);
    try t.expectEqualStrings("Kraków", legs[0].from);
    try t.expectEqualStrings("Lisbon", legs[0].to);
    try t.expectEqualStrings("calendar", legs[0].source);
    try t.expectEqualStrings("personal/f1", legs[0].ref);
    try t.expectEqual(Kind.hotel, legs[1].kind);
    try t.expectEqualStrings("Hotel Avenida, Lisbon", legs[1].to);
    try t.expectEqualStrings("LH 1623", legs[2].number);
    try t.expectEqualStrings("Munich", legs[2].to);
    try t.expectEqualStrings("Warsaw", legs[2].from);
    try t.expect(isFlight("Lot LO 3923 do Gdańska", ""));
    try t.expect(!isFlight("Call with LO 3921 team", "Video call"));
}

const lisbon_mail =
    \\{"legs": [
    \\ {"kind": "flight", "number": "LO 3921", "from": "Kraków (KRK)", "to": "Lisbon (LIS)", "start": "2026-12-04 07:15", "start_zone": "+01:00", "end": "2026-12-04 10:40", "end_zone": "+00:00", "link": "https://www.lot.com/checkin?pnr=X1"},
    \\ {"kind": "flight", "number": "LO 3922", "from": "Lisbon (LIS)", "to": "Kraków (KRK)", "start": "2026-12-07 11:30", "start_zone": "+00:00", "end": "2026-12-07 17:45", "end_zone": "+01:00"}
    \\]}
;

test "mail_legs_merge_into_one_trip" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = dec4 - 11 * 86400;
    const legs = try fromMail(a, lisbon_mail, "7", 60);
    try t.expectEqual(2, legs.len);
    try t.expectEqual(dec4 + 6 * 3600 + 15 * 60, legs[0].start);
    try t.expectEqual(@as(?i32, 0), legs[0].end_zone);
    try t.expectEqualStrings("https://www.lot.com/checkin?pnr=X1", legs[0].link);
    var trips = try merge(a, &.{}, legs, now);
    try t.expectEqual(1, trips.len);
    try t.expectEqualStrings("2026-12-04-lisbon", trips[0].name);
    try t.expectEqualStrings("Lisbon", trips[0].place);
    // the hotel's mail joins it
    trips = try merge(a, trips, try fromMail(a, "Here it is: {\"legs\": [{\"kind\": \"hotel\", \"to\": \"Hotel Avenida, Lisbon\", \"start\": \"2026-12-04 15:00\", \"start_zone\": \"+00:00\", \"end\": \"2026-12-07 11:00\", \"end_zone\": \"+00:00\"}]}", "8", 60), now);
    try t.expectEqual(1, trips.len);
    try t.expectEqual(3, trips[0].legs.len);
    // a change (a new time) replaces its leg; the calendar's copy adds nothing
    trips = try merge(a, trips, try fromMail(a, "{\"legs\": [{\"kind\": \"flight\", \"number\": \"LO3921\", \"from\": \"Kraków (KRK)\", \"to\": \"Lisbon (LIS)\", \"start\": \"2026-12-04 08:05\", \"start_zone\": \"+01:00\", \"end\": \"2026-12-04 11:30\", \"end_zone\": \"+00:00\"}]}", "9", 60), now);
    trips = try merge(a, trips, &.{.{ .kind = .flight, .number = "LO 3921", .from = "Kraków", .to = "Lisbon", .start = dec4 + 7 * 3600 + 5 * 60, .end = dec4 + 11 * 3600, .source = "calendar", .ref = "personal/f1" }}, now);
    try t.expectEqual(1, trips.len);
    try t.expectEqual(3, trips[0].legs.len);
    try t.expectEqual(dec4 + 7 * 3600 + 5 * 60, trips[0].legs[0].start);
    try t.expectEqualStrings("mail", trips[0].legs[0].source);
    // a January trip is another
    trips = try merge(a, trips, try fromMail(a, "{\"legs\": [{\"kind\": \"train\", \"from\": \"Kraków\", \"to\": \"Gdańsk\", \"start\": \"2027-01-15 08:00\", \"end\": \"2027-01-15 13:30\"}]}", "10", 60), now);
    try t.expectEqual(2, trips.len);
    // home again: the last landing and the way home
    try t.expectEqual(dec4 + 3 * 86400 + 16 * 3600 + 45 * 60 + 1800, backOf(trips[0], 1800));
    // nothing confirmed; not the JSON asked for
    try t.expectEqual(0, (try fromMail(a, "{\"legs\": []}", "11", 60)).len);
    try t.expectError(error.NotLegs, fromMail(a, "I couldn't read it.", "12", 60));
    // past trips go two days after they end
    try t.expectEqual(1, (try merge(a, trips, &.{}, dec4 + 10 * 86400)).len);
}

test "times_in_the_places_zone" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const trips = try merge(a, &.{}, try fromMail(a, lisbon_mail, "7", 60), dec4 - 86400);
    try t.expectEqualStrings(
        \\Lisbon, Fri 4 Dec – Mon 7 Dec:
        \\Fri 4 Dec 07:15 LO 3921 Kraków → Lisbon, arrives 10:40 Lisbon time
        \\Mon 7 Dec 11:30 Lisbon time LO 3922 Lisbon → Kraków, arrives 17:45
    , try listText(a, trips, dec4 - 86400, 60));
    try t.expectEqualStrings("No trips. They come from your calendar (flights, trains, hotels) and from travel mail.", try listText(a, &.{}, dec4, 60));
    // a calendar leg has no zones: your time, no label
    try t.expectEqualStrings("Fri 4 Dec 07:15 LO 3921 Kraków → Lisbon, arrives 11:40", try legText(a, .{ .number = "LO 3921", .from = "Kraków", .to = "Lisbon", .start = dec4 + 6 * 3600 + 15 * 60, .end = dec4 + 10 * 3600 + 40 * 60 }, 60));
    try t.expectEqualStrings("Tomorrow: Lisbon, 3 nights. LO 3921 leaves Kraków at 07:15; leave home by 04:45.", try eveningText(a, trips[0], 60, 120, 30));
}

test "packing_from_the_trips_length" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("clothes for 4 days, toiletries, your ID or passport, your boarding pass, chargers", try packing(a, 3, true));
    try t.expectEqualStrings("clothes for 2 days, toiletries, your ID or passport, chargers", try packing(a, 1, false));
    try t.expectEqualStrings("your ID or passport, your boarding pass, a charger", try packing(a, 0, true));
}

test "a_check_in_link_off_the_airlines_domain_is_not_shown" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lo = airlineOf("LO 3921").?;
    try t.expect(linkOk("https://www.lot.com/checkin?pnr=X1", lo));
    try t.expect(linkOk("https://checkin.lot.com/", lo));
    for ([_][]const u8{ "http://www.lot.com/checkin", "https://lot-checkin.example/x", "https://lot.com.evil.example/x", "https://evil.example/@lot.com", "https://user@lot.com/", "https://www.lot.com/a b" }) |bad| try t.expect(!linkOk(bad, lo));
    // a mail's link elsewhere is dropped as it is read
    const legs = try fromMail(a, "{\"legs\": [{\"kind\": \"flight\", \"number\": \"LO 3921\", \"from\": \"Kraków (KRK)\", \"to\": \"Lisbon (LIS)\", \"start\": \"2026-12-04 07:15\", \"start_zone\": \"+01:00\", \"end\": \"2026-12-04 10:40\", \"end_zone\": \"+00:00\", \"link\": \"https://lot-checkin.example/phish\"}]}", "7", 60);
    try t.expectEqualStrings("", legs[0].link);
    const now = dec4 + 6 * 3600 + 15 * 60 - 24 * 3600;
    try t.expectEqualStrings("Check-in for LO 3921 Kraków → Lisbon (tomorrow 07:15) is open: on LOT's site or app.", try checkinText(a, legs[0], now, 60));
    var with_link = legs[0];
    with_link.link = "https://www.lot.com/checkin?pnr=X1";
    try t.expectEqualStrings("Check-in for LO 3921 Kraków → Lisbon (tomorrow 07:15) is open: https://www.lot.com/checkin?pnr=X1", try checkinText(a, with_link, now, 60));
    var other = legs[0];
    other.number = "XQ 12";
    try t.expectEqualStrings("Check-in for XQ 12 Kraków → Lisbon (tomorrow 07:15) is open: on the airline's site or app.", try checkinText(a, other, now, 60));
}

test "check_in_and_the_evening_before_come_due_once" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const trips = try merge(a, &.{}, try fromMail(a, lisbon_mail, "7", 60), dec4 - 86400);
    const dep = dec4 + 6 * 3600 + 15 * 60;
    try t.expectEqual(0, (try due(a, trips, dep - 24 * 3600 - 60, 60, 19 * 60, &.{})).len);
    const at = try due(a, trips, dep - 24 * 3600, 60, 19 * 60, &.{});
    try t.expectEqual(1, at.len);
    try t.expectEqualStrings("checkin:LO3921@1796364900", at[0].key);
    try t.expectEqual(0, (try due(a, trips, dep - 24 * 3600, 60, 19 * 60, &.{at[0].key})).len);
    // the evening before: 19:00 your time on 3 Dec (18:00 UTC)
    const eve = dec4 - 6 * 3600;
    try t.expectEqual(0, (try due(a, trips, eve - 60, 60, 19 * 60, &.{at[0].key})).len);
    const e = try due(a, trips, eve, 60, 19 * 60, &.{at[0].key});
    try t.expectEqual(1, e.len);
    try t.expectEqualStrings("evening:2026-12-04-lisbon", e[0].key);
    // too late for check-in: none
    try t.expectEqual(0, (try due(a, trips, dep - 2 * 3600, 60, 19 * 60, &.{"evening:2026-12-04-lisbon"})).len);
}

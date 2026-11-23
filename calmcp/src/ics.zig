//! iCalendar (RFC 5545), the parts a calendar's events need: lines
//! unfolded, properties with their parameters, components nested
//! (VCALENDAR, VEVENT, VTIMEZONE …), text unescaped, dates and times with
//! their zones, and each VEVENT read into an `Event`.
const std = @import("std");
const tz = @import("tz.zig");
const Allocator = std.mem.Allocator;

pub const Param = struct { name: []const u8, value: []const u8 };

pub const Prop = struct {
    name: []const u8,
    params: []const Param = &.{},
    value: []const u8,

    /// A parameter's value (names in upper case), quotes taken off.
    pub fn param(p: Prop, name: []const u8) ?[]const u8 {
        for (p.params) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
        return null;
    }
};

pub const Comp = struct {
    name: []const u8,
    props: []const Prop = &.{},
    subs: []const Comp = &.{},

    pub fn prop(c: Comp, name: []const u8) ?Prop {
        for (c.props) |p| if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
        return null;
    }

    pub fn value(c: Comp, name: []const u8) ?[]const u8 {
        return if (c.prop(name)) |p| p.value else null;
    }
};

/// The lines of `text` with folded lines joined (a line starting with a
/// space or a tab goes on the one before); \r\n or \n.
pub fn unfold(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var have = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            try cur.appendSlice(a, line[1..]);
            continue;
        }
        if (have and cur.items.len > 0) try out.append(a, try cur.toOwnedSlice(a));
        cur = .empty;
        try cur.appendSlice(a, line);
        have = true;
    }
    if (have and cur.items.len > 0) try out.append(a, try cur.toOwnedSlice(a));
    return out.items;
}

/// One content line: NAME;PARAM=VALUE;…:VALUE.
pub fn parseLine(a: Allocator, line: []const u8) !Prop {
    var i: usize = 0;
    while (i < line.len and line[i] != ';' and line[i] != ':') i += 1;
    if (i == 0 or i == line.len) return error.BadLine;
    const name = line[0..i];
    var params: std.ArrayList(Param) = .empty;
    while (i < line.len and line[i] == ';') {
        i += 1;
        const ns = i;
        while (i < line.len and line[i] != '=' and line[i] != ':' and line[i] != ';') i += 1;
        if (i == line.len or line[i] != '=') return error.BadLine;
        const pname = line[ns..i];
        i += 1;
        // a value: quoted, or up to ; or : (several, comma-separated, kept whole)
        var val: std.ArrayList(u8) = .empty;
        while (i < line.len and line[i] != ';' and line[i] != ':') {
            if (line[i] == '"') {
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, '"') orelse return error.BadLine;
                try val.appendSlice(a, line[i + 1 .. close]);
                i = close + 1;
            } else {
                try val.append(a, line[i]);
                i += 1;
            }
        }
        try params.append(a, .{ .name = pname, .value = val.items });
    }
    if (i >= line.len or line[i] != ':') return error.BadLine;
    return .{ .name = name, .params = params.items, .value = line[i + 1 ..] };
}

/// The first component of `text` (a VCALENDAR), with what it holds.
pub fn parse(a: Allocator, text: []const u8) !Comp {
    const lines = try unfold(a, text);
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const p = parseLine(a, lines[i]) catch continue;
        if (std.ascii.eqlIgnoreCase(p.name, "BEGIN")) {
            i += 1;
            return try comp(a, lines, &i, p.value, 0);
        }
    }
    return error.NoCalendar;
}

/// The component `name` whose BEGIN was the line before `i.*`: up to its END.
fn comp(a: Allocator, lines: []const []const u8, i: *usize, name: []const u8, depth: u32) !Comp {
    if (depth > 8) return error.TooDeep;
    var props: std.ArrayList(Prop) = .empty;
    var subs: std.ArrayList(Comp) = .empty;
    while (i.* < lines.len) {
        const line = lines[i.*];
        i.* += 1;
        if (line.len == 0) continue;
        // a line that doesn't read is passed over, as calendars do
        const p = parseLine(a, line) catch continue;
        if (std.ascii.eqlIgnoreCase(p.name, "BEGIN")) {
            try subs.append(a, try comp(a, lines, i, p.value, depth + 1));
        } else if (std.ascii.eqlIgnoreCase(p.name, "END")) {
            return .{ .name = name, .props = props.items, .subs = subs.items };
        } else try props.append(a, p);
    }
    return error.Unterminated;
}

/// TEXT as written: `\n` a line break, `\,` `\;` `\\` themselves.
pub fn unescape(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try o.append(a, switch (s[i]) {
                'n', 'N' => '\n',
                else => s[i],
            });
        } else try o.append(a, s[i]);
    }
    return o.items;
}

/// TEXT for writing: the reverse of `unescape` (a \r dropped).
pub fn escape(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '\\' => try o.appendSlice(a, "\\\\"),
        ',' => try o.appendSlice(a, "\\,"),
        ';' => try o.appendSlice(a, "\\;"),
        '\n' => try o.appendSlice(a, "\\n"),
        '\r' => {},
        else => try o.append(a, ch),
    };
    return o.items;
}

// ---- dates and times ----

/// A DATE or DATE-TIME as written: a date (all day), a UTC time (`Z`), a
/// time in a zone (`TZID=`), or a floating time (the owner's).
pub const When = struct {
    kind: Kind,
    /// The wall-clock time, as local seconds (a date: its midnight).
    local: i64,
    tzid: []const u8 = "",

    pub const Kind = enum { date, utc, floating, zoned };
};

fn digits(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// "20261123", "20261123T103000", "20261123T093000Z".
pub fn parseWhenValue(v_in: []const u8, tzid: ?[]const u8, date_only: bool) error{BadTime}!When {
    const v = std.mem.trim(u8, v_in, " \t");
    if (v.len < 8) return error.BadTime;
    const y = digits(v[0..4]) orelse return error.BadTime;
    const m = digits(v[4..6]) orelse return error.BadTime;
    const d = digits(v[6..8]) orelse return error.BadTime;
    if (m < 1 or m > 12 or d < 1 or d > tz.monthDays(y, @intCast(m))) return error.BadTime;
    const day = tz.daysFromCivil(y, @intCast(m), @intCast(d));
    if (v.len == 8) return .{ .kind = .date, .local = day * 86400 };
    if (date_only) return error.BadTime;
    if (v.len < 15 or v[8] != 'T') return error.BadTime;
    const hh = digits(v[9..11]) orelse return error.BadTime;
    const mi = digits(v[11..13]) orelse return error.BadTime;
    const ss = digits(v[13..15]) orelse return error.BadTime;
    if (hh > 23 or mi > 59 or ss > 60) return error.BadTime;
    const local = day * 86400 + hh * 3600 + mi * 60 + @min(ss, 59);
    if (v.len == 16 and (v[15] == 'Z' or v[15] == 'z')) return .{ .kind = .utc, .local = local };
    if (v.len != 15) return error.BadTime;
    if (tzid) |z| if (z.len > 0) return .{ .kind = .zoned, .local = local, .tzid = z };
    return .{ .kind = .floating, .local = local };
}

pub fn parseWhen(p: Prop) error{BadTime}!When {
    const is_date = if (p.param("VALUE")) |v| std.ascii.eqlIgnoreCase(v, "DATE") else false;
    return parseWhenValue(p.value, p.param("TZID"), is_date);
}

/// "PT1H30M", "P1D", "-PT15M" as seconds.
pub fn parseDuration(s_in: []const u8) ?i64 {
    var s = std.mem.trim(u8, s_in, " \t");
    var sign: i64 = 1;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        if (s[0] == '-') sign = -1;
        s = s[1..];
    }
    if (s.len < 2 or s[0] != 'P') return null;
    var total: i64 = 0;
    var in_time = false;
    var n: ?i64 = null;
    for (s[1..]) |ch| {
        if (std.ascii.isDigit(ch)) {
            n = (n orelse 0) * 10 + (ch - '0');
            continue;
        }
        if (ch == 'T') {
            if (n != null) return null;
            in_time = true;
            continue;
        }
        const x = n orelse return null;
        total += x * switch (ch) {
            'W' => if (in_time) return null else @as(i64, 7 * 86400),
            'D' => if (in_time) return null else @as(i64, 86400),
            'H' => if (in_time) @as(i64, 3600) else return null,
            'M' => if (in_time) @as(i64, 60) else return null,
            'S' => if (in_time) @as(i64, 1) else return null,
            else => return null,
        };
        n = null;
    }
    if (n != null) return null;
    return sign * total;
}

/// "+0100", "-0500" as minutes east.
pub fn parseOffset(s_in: []const u8) ?i32 {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len != 5 and s.len != 7) return null;
    const sign: i32 = if (s[0] == '-') -1 else if (s[0] == '+') 1 else return null;
    const h = digits(s[1..3]) orelse return null;
    const m = digits(s[3..5]) orelse return null;
    if (h > 23 or m > 59) return null;
    return sign * @as(i32, @intCast(h * 60 + m));
}

/// RRULE parts a VTIMEZONE's change needs: BYMONTH, BYDAY ([n]WD),
/// BYMONTHDAY (the old "8..14 with SU" form of "the second Sunday"),
/// whether it has an UNTIL.
fn ruleOf(rrule: []const u8, local_start: i64) ?struct { rule: tz.Rule, ends: bool } {
    var month: ?u8 = null;
    var week: i8 = 0;
    var wd: ?u3 = null;
    var first_mday: ?i64 = null;
    var ends = false;
    var it = std.mem.splitScalar(u8, rrule, ';');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const k = part[0..eq];
        const v = part[eq + 1 ..];
        if (std.ascii.eqlIgnoreCase(k, "BYMONTH")) {
            month = @intCast(std.math.clamp(digits(v) orelse return null, 1, 12));
        } else if (std.ascii.eqlIgnoreCase(k, "UNTIL") or std.ascii.eqlIgnoreCase(k, "COUNT")) {
            ends = true;
        } else if (std.ascii.eqlIgnoreCase(k, "BYMONTHDAY")) {
            var days = std.mem.splitScalar(u8, v, ',');
            const first = std.fmt.parseInt(i64, days.first(), 10) catch return null;
            first_mday = first;
        } else if (std.ascii.eqlIgnoreCase(k, "BYDAY")) {
            if (v.len < 2) return null;
            wd = weekdayOf(v[v.len - 2 ..]) orelse return null;
            if (v.len > 2) week = std.fmt.parseInt(i8, v[0 .. v.len - 2], 10) catch return null;
        }
    }
    const day = @divFloor(local_start, 86400);
    const m = month orelse tz.civil(day).m;
    const minute: i32 = @intCast(@divFloor(@mod(local_start, 86400), 60));
    const w = wd orelse {
        // a fixed day of the month
        return .{ .rule = .{ .month = m, .mday = tz.civil(day).d, .minute = minute }, .ends = ends };
    };
    if (week == 0) {
        // "BYMONTHDAY=8,…,14;BYDAY=SU": the week the first of those days is in
        week = if (first_mday) |f| (if (f < 0) -1 else @intCast(@divFloor(f - 1, 7) + 1)) else 1;
    }
    return .{ .rule = .{ .month = m, .week = week, .weekday = w, .minute = minute }, .ends = ends };
}

pub fn weekdayOf(s: []const u8) ?u3 {
    const names = [_][]const u8{ "SU", "MO", "TU", "WE", "TH", "FR", "SA" };
    for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, s)) return @intCast(i);
    return null;
}

/// A VTIMEZONE's current rules: the STANDARD and DAYLIGHT parts in force
/// now (a yearly RRULE without UNTIL, the latest); null when it has none
/// it can read.
pub fn zoneOfVtimezone(c: Comp) ?tz.Zone {
    const Part = struct { start: i64, to: i32, rule: ?tz.Rule, open: bool };
    var std_part: ?Part = null;
    var dst_part: ?Part = null;
    for (c.subs) |s| {
        const is_std = std.ascii.eqlIgnoreCase(s.name, "STANDARD");
        if (!is_std and !std.ascii.eqlIgnoreCase(s.name, "DAYLIGHT")) continue;
        const start = (parseWhenValue(s.value("DTSTART") orelse continue, null, false) catch continue).local;
        const to = parseOffset(s.value("TZOFFSETTO") orelse continue) orelse continue;
        var part: Part = .{ .start = start, .to = to, .rule = null, .open = true };
        if (s.value("RRULE")) |rr| {
            const r = ruleOf(rr, start) orelse continue;
            part.rule = r.rule;
            part.open = !r.ends;
        }
        const slot = if (is_std) &std_part else &dst_part;
        // the one in force now: an open rule beats an ended one, then the latest
        if (slot.*) |old| {
            const better = (part.open and !old.open) or (part.open == old.open and part.start > old.start);
            if (!better) continue;
        }
        slot.* = part;
    }
    const st = std_part orelse {
        const d = dst_part orelse return null;
        return .{ .std_off = d.to };
    };
    const ds = dst_part orelse return .{ .std_off = st.to };
    // summer time that has ended (no open rule on either side): the standard offset
    if (!ds.open or !st.open or ds.rule == null or st.rule == null) return .{ .std_off = st.to };
    return .{ .std_off = st.to, .dst = .{ .off = ds.to, .start = ds.rule.?, .end = st.rule.? } };
}

/// How one calendar object's times are read: its VTIMEZONEs first, then
/// tz.zig's table, then — a name neither knows — the owner's zone.
pub const Zones = struct {
    owner: tz.Zone,
    own: []const Own = &.{},

    pub const Own = struct { id: []const u8, zone: tz.Zone };
    pub const Found = struct { zone: tz.Zone, known: bool };

    /// The zones `cal` defines, beside the owner's.
    pub fn of(z: Zones, a: Allocator, cal: Comp, owner: tz.Zone) !Zones {
        _ = z;
        var list: std.ArrayList(Own) = .empty;
        for (cal.subs) |s| {
            if (!std.ascii.eqlIgnoreCase(s.name, "VTIMEZONE")) continue;
            const id = s.value("TZID") orelse continue;
            // a VTIMEZONE with summer time that has ended, or none, gives way
            // to the table when the table knows the name
            const own = zoneOfVtimezone(s);
            const table = tz.lookup(id);
            const found = if (own) |o| (if (o.dst == null and table != null) table.? else o) else table orelse continue;
            try list.append(a, .{ .id = id, .zone = found });
        }
        return .{ .owner = owner, .own = list.items };
    }

    pub fn zone(z: Zones, tzid: []const u8) Found {
        for (z.own) |o| if (std.mem.eql(u8, o.id, tzid)) return .{ .zone = o.zone, .known = true };
        if (tz.lookup(tzid)) |x| return .{ .zone = x, .known = true };
        return .{ .zone = z.owner, .known = false };
    }

    /// The zone `w` is read in.
    pub fn zoneOf(z: Zones, w: When) tz.Zone {
        return switch (w.kind) {
            .utc => .utc,
            .zoned => z.zone(w.tzid).zone,
            .date, .floating => z.owner,
        };
    }

    /// The Unix time of `w`; a date is its midnight in the owner's zone.
    pub fn toUtc(z: Zones, w: When) i64 {
        return z.zoneOf(w).toUtc(w.local);
    }
};

// ---- events ----

pub const Person = struct {
    email: []const u8 = "",
    name: []const u8 = "",
    /// ACCEPTED, DECLINED, TENTATIVE, NEEDS-ACTION …
    partstat: []const u8 = "",
};

pub const Event = struct {
    uid: []const u8 = "",
    summary: []const u8 = "",
    location: []const u8 = "",
    description: []const u8 = "",
    url: []const u8 = "",
    /// CONFIRMED, TENTATIVE, CANCELLED, or "".
    status: []const u8 = "",
    /// Shown as free (TRANSP:TRANSPARENT).
    transparent: bool = false,
    organizer: ?Person = null,
    attendees: []const Person = &.{},
    start: When,
    end: ?When = null,
    duration_s: ?i64 = null,
    rrule: []const u8 = "",
    rdates: []const When = &.{},
    exdates: []const When = &.{},
    /// An overridden occurrence of a recurring event: which one.
    recurrence_id: ?When = null,
    sequence: i64 = 0,
};

fn person(a: Allocator, p: Prop) !Person {
    return .{
        .email = mailto(p.value),
        .name = try unescape(a, p.param("CN") orelse ""),
        .partstat = p.param("PARTSTAT") orelse "NEEDS-ACTION",
    };
}

/// The dates of an RDATE or EXDATE line (a list, comma-separated).
fn whenList(a: Allocator, list: *std.ArrayList(When), p: Prop) !void {
    const is_date = if (p.param("VALUE")) |v| std.ascii.eqlIgnoreCase(v, "DATE") else false;
    var it = std.mem.splitScalar(u8, p.value, ',');
    while (it.next()) |v| {
        const w = parseWhenValue(v, p.param("TZID"), is_date) catch continue;
        try list.append(a, w);
    }
}

/// The VEVENTs of a VCALENDAR; one without a start it can read is left out.
pub fn events(a: Allocator, cal: Comp) ![]Event {
    var out: std.ArrayList(Event) = .empty;
    for (cal.subs) |s| {
        if (!std.ascii.eqlIgnoreCase(s.name, "VEVENT")) continue;
        const start = parseWhen(s.prop("DTSTART") orelse continue) catch continue;
        var e: Event = .{ .start = start };
        var attendees: std.ArrayList(Person) = .empty;
        var rdates: std.ArrayList(When) = .empty;
        var exdates: std.ArrayList(When) = .empty;
        for (s.props) |p| {
            const n = p.name;
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(n, "UID")) e.uid = p.value else if (eq(n, "SUMMARY")) e.summary = try unescape(a, p.value) else if (eq(n, "LOCATION")) e.location = try unescape(a, p.value) else if (eq(n, "DESCRIPTION")) e.description = try unescape(a, p.value) else if (eq(n, "URL")) e.url = p.value else if (eq(n, "STATUS")) e.status = p.value else if (eq(n, "TRANSP")) e.transparent = eq(p.value, "TRANSPARENT") else if (eq(n, "ORGANIZER")) e.organizer = try person(a, p) else if (eq(n, "ATTENDEE")) try attendees.append(a, try person(a, p)) else if (eq(n, "DTEND")) e.end = parseWhen(p) catch null else if (eq(n, "DURATION")) e.duration_s = parseDuration(p.value) else if (eq(n, "RRULE")) e.rrule = p.value else if (eq(n, "RDATE")) try whenList(a, &rdates, p) else if (eq(n, "EXDATE")) try whenList(a, &exdates, p) else if (eq(n, "RECURRENCE-ID")) e.recurrence_id = parseWhen(p) catch null else if (eq(n, "SEQUENCE")) e.sequence = std.fmt.parseInt(i64, p.value, 10) catch 0;
        }
        e.attendees = attendees.items;
        e.rdates = rdates.items;
        e.exdates = exdates.items;
        try out.append(a, e);
    }
    return out.items;
}

/// "mailto:anna@example.com" → "anna@example.com".
pub fn mailto(v: []const u8) []const u8 {
    if (v.len >= 7 and std.ascii.eqlIgnoreCase(v[0..7], "mailto:")) return v[7..];
    return v;
}

// ---- tests ----

const tt = std.testing;

/// A calendar object as Fastmail and iCloud send one: CRLF lines, a folded
/// description, escaped text, a VTIMEZONE for its TZID.
pub const sample =
    "BEGIN:VCALENDAR\r\n" ++
    "VERSION:2.0\r\n" ++
    "PRODID:-//Example//Calendar//EN\r\n" ++
    "BEGIN:VTIMEZONE\r\n" ++
    "TZID:Europe/Warsaw\r\n" ++
    "BEGIN:STANDARD\r\n" ++
    "DTSTART:19701025T030000\r\n" ++
    "TZOFFSETFROM:+0200\r\n" ++
    "TZOFFSETTO:+0100\r\n" ++
    "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\r\n" ++
    "END:STANDARD\r\n" ++
    "BEGIN:DAYLIGHT\r\n" ++
    "DTSTART:19700329T020000\r\n" ++
    "TZOFFSETFROM:+0100\r\n" ++
    "TZOFFSETTO:+0200\r\n" ++
    "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\r\n" ++
    "END:DAYLIGHT\r\n" ++
    "END:VTIMEZONE\r\n" ++
    "BEGIN:VEVENT\r\n" ++
    "UID:dentist-1@example.com\r\n" ++
    "DTSTAMP:20261101T120000Z\r\n" ++
    "DTSTART;TZID=Europe/Warsaw:20261123T103000\r\n" ++
    "DTEND;TZID=Europe/Warsaw:20261123T113000\r\n" ++
    "SUMMARY:Dentist\r\n" ++
    "LOCATION:Dental clinic\\, ul. Długa 5\\, Kraków\r\n" ++
    "DESCRIPTION:Bring the X-ray.\\nParking behind the building: https://ma\r\n" ++
    " ps.example.com/clinic\r\n" ++
    "ORGANIZER;CN=\"Nowak, Piotr\":mailto:piotr@example.com\r\n" ++
    "ATTENDEE;CN=Anna Kowalska;PARTSTAT=ACCEPTED:mailto:anna@example.com\r\n" ++
    "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:MAILTO:Owner@Example.com\r\n" ++
    "SEQUENCE:2\r\n" ++
    "END:VEVENT\r\n" ++
    "END:VCALENDAR\r\n";

test "lines_unfold_and_properties_read_with_their_parameters" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try unfold(a, "A:one\r\n two\r\nB;X=\"a:b;c\":v:w\n\tthree\nC:\n");
    try tt.expectEqual(@as(usize, 3), lines.len);
    try tt.expectEqualStrings("A:onetwo", lines[0]);
    try tt.expectEqualStrings("B;X=\"a:b;c\":v:wthree", lines[1]);
    const p = try parseLine(a, lines[1]);
    try tt.expectEqualStrings("B", p.name);
    try tt.expectEqualStrings("a:b;c", p.param("x").?);
    try tt.expectEqualStrings("v:wthree", p.value);
    try tt.expectError(error.BadLine, parseLine(a, "no colon here"));
    try tt.expectEqualStrings("a, b; c\\d\ne", try unescape(a, "a\\, b\\; c\\\\d\\ne"));
    try tt.expectEqualStrings("a\\, b\\; c\\\\d\\ne", try escape(a, "a, b; c\\d\ne"));
}

test "a_calendar_object_reads_into_its_event" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cal = try parse(a, sample);
    try tt.expectEqualStrings("VCALENDAR", cal.name);
    try tt.expectEqual(@as(usize, 2), cal.subs.len);
    const evs = try events(a, cal);
    try tt.expectEqual(@as(usize, 1), evs.len);
    const e = evs[0];
    try tt.expectEqualStrings("dentist-1@example.com", e.uid);
    try tt.expectEqualStrings("Dentist", e.summary);
    try tt.expectEqualStrings("Dental clinic, ul. Długa 5, Kraków", e.location);
    try tt.expectEqualStrings("Bring the X-ray.\nParking behind the building: https://maps.example.com/clinic", e.description);
    try tt.expectEqualStrings("Nowak, Piotr", e.organizer.?.name);
    try tt.expectEqualStrings("piotr@example.com", e.organizer.?.email);
    try tt.expectEqual(@as(usize, 2), e.attendees.len);
    try tt.expectEqualStrings("ACCEPTED", e.attendees[0].partstat);
    try tt.expectEqualStrings("Owner@Example.com", e.attendees[1].email);
    try tt.expectEqual(@as(i64, 2), e.sequence);
    try tt.expectEqual(When.Kind.zoned, e.start.kind);
    try tt.expectEqualStrings("Europe/Warsaw", e.start.tzid);
    // its zone from its own VTIMEZONE: 10:30 in Warsaw in November is 09:30 UTC
    const zones = try (Zones{ .owner = .utc }).of(a, cal, .utc);
    try tt.expect(zones.zone("Europe/Warsaw").known);
    try tt.expectEqual(tz.daysFromCivil(2026, 11, 23) * 86400 + 9 * 3600 + 30 * 60, zones.toUtc(e.start));
    try tt.expectEqual(tz.daysFromCivil(2026, 11, 23) * 86400 + 10 * 3600 + 30 * 60, zones.toUtc(e.end.?));
}

test "dates_times_durations_and_offsets" {
    const d = try parseWhenValue("20261123", null, true);
    try tt.expectEqual(When.Kind.date, d.kind);
    try tt.expectEqual(tz.daysFromCivil(2026, 11, 23) * 86400, d.local);
    try tt.expectEqual(When.Kind.date, (try parseWhenValue("20261123", null, false)).kind);
    const u = try parseWhenValue("20261123T093000Z", null, false);
    try tt.expectEqual(When.Kind.utc, u.kind);
    const f = try parseWhenValue("20261123T093000", null, false);
    try tt.expectEqual(When.Kind.floating, f.kind);
    const z = try parseWhenValue("20261123T093000", "America/New_York", false);
    try tt.expectEqual(When.Kind.zoned, z.kind);
    try tt.expectError(error.BadTime, parseWhenValue("2026-11-23", null, false));
    try tt.expectError(error.BadTime, parseWhenValue("20261323T093000", null, false));
    try tt.expectEqual(@as(i64, 5400), parseDuration("PT1H30M").?);
    try tt.expectEqual(@as(i64, 86400), parseDuration("P1D").?);
    try tt.expectEqual(@as(i64, 7 * 86400), parseDuration("P1W").?);
    try tt.expectEqual(@as(i64, -900), parseDuration("-PT15M").?);
    try tt.expect(parseDuration("1H") == null);
    try tt.expectEqual(@as(i32, 60), parseOffset("+0100").?);
    try tt.expectEqual(@as(i32, -570), parseOffset("-0930").?);
    try tt.expectEqualStrings("anna@example.com", mailto("mailto:anna@example.com"));
    try tt.expectEqualStrings("Owner@Example.com", mailto("MAILTO:Owner@Example.com"));
}

test "a_zone_neither_the_object_nor_the_table_knows_is_the_owners" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = tz.lookup("Europe/Warsaw").?;
    const cal = try parse(a, "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=Mars/Olympus:20261123T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");
    const zones = try (Zones{ .owner = owner }).of(a, cal, owner);
    const found = zones.zone("Mars/Olympus");
    try tt.expect(!found.known);
    const e = (try events(a, cal))[0];
    try tt.expectEqual(tz.daysFromCivil(2026, 11, 23) * 86400 + 9 * 3600, zones.toUtc(e.start));
    // a zone the table knows, without a VTIMEZONE: New York's 09:00 is 14:00 UTC
    try tt.expect(zones.zone("America/New_York").known);
    try tt.expectEqual(tz.daysFromCivil(2026, 11, 23) * 86400 + 14 * 3600, zones.toUtc(try parseWhenValue("20261123T090000", "America/New_York", false)));
    // floating times and dates are the owner's
    try tt.expectEqual(tz.daysFromCivil(2026, 11, 23) * 86400 - 3600, zones.toUtc(try parseWhenValue("20261123", null, true)));
}

test "an_old_style_vtimezone_with_bymonthday_reads" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the second Sunday of March written as BYMONTHDAY=8..14;BYDAY=SU, and an older part that ended
    const text =
        "BEGIN:VTIMEZONE\r\nTZID:Eastern\r\n" ++
        "BEGIN:DAYLIGHT\r\nDTSTART:19870405T020000\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nRRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU;UNTIL=20060402T070000Z\r\nEND:DAYLIGHT\r\n" ++
        "BEGIN:DAYLIGHT\r\nDTSTART:20070311T020000\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=8,9,10,11,12,13,14;BYDAY=SU\r\nEND:DAYLIGHT\r\n" ++
        "BEGIN:STANDARD\r\nDTSTART:20071104T020000\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\r\nEND:STANDARD\r\n" ++
        "END:VTIMEZONE\r\n";
    const z = zoneOfVtimezone(try parse(a, text)).?;
    try tt.expectEqual(@as(i32, -300), z.std_off);
    try tt.expectEqual(@as(i32, -240), z.dst.?.off);
    // 8 Mar 2026 is the second Sunday: 02:00 EST is 07:00 UTC
    const at = tz.daysFromCivil(2026, 3, 8) * 86400 + 7 * 3600;
    try tt.expectEqual(@as(i32, -300), z.offsetAt(at - 60));
    try tt.expectEqual(@as(i32, -240), z.offsetAt(at));
    // a zone without summer time: one STANDARD part
    const fixed = zoneOfVtimezone(try parse(a, "BEGIN:VTIMEZONE\r\nTZID:Asia/Kolkata\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0530\r\nTZOFFSETTO:+0530\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n")).?;
    try tt.expectEqual(@as(i32, 330), fixed.std_off);
    try tt.expect(fixed.dst == null);
}

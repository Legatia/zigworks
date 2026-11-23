//! People the owner deals with: a small file each in `state/people/`
//! (`ID.txt`, `key = value` lines, written whole), filled from what the
//! owner says in their own conversations (the memory writer), calendar
//! attendees, and contacts files (vCard 3 and 4). What is due on a day (a
//! birthday a week ahead and on the day, keeping in touch) is worked out
//! here; harness posts it (core.zig). Who may see any of it is harness's
//! to decide: this file never posts, logs or calls a model.
const std = @import("std");
const util = @import("util.zig");
const jv = @import("jv.zig");
const model = @import("model.zig");
const who_mod = @import("who.zig");
const Io = std.Io;

/// A person's file, at most.
pub const max_file = 16 * 1024;
/// One value, at most (bytes).
pub const max_value = 200;
/// Values of one kind a person keeps (called, preferences, …).
pub const max_values = 16;
/// People a book holds; an import stops there.
pub const max_people = 5000;
/// The minute of the day (the owner's) from which the day's lines go.
pub const day_minute = 9 * 60;
/// A file's id, at most (bytes).
const max_id = 48;

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const day_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

fn leap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn daysIn(m: u8, y: i64) u8 {
    return switch (m) {
        2 => if (leap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn digits2(s: []const u8) ?u8 {
    if (s.len != 2 or !allDigits(s)) return null;
    return std.fmt.parseInt(u8, s, 10) catch null;
}

/// A date of the calendar, with or without its year.
pub const Date = struct {
    /// 0: no year.
    y: u16 = 0,
    m: u8,
    d: u8,

    /// `YYYY-MM-DD`, `YYYYMMDD`, `MM-DD`, `--MM-DD`, `--MMDD` (vCard's
    /// without a year), a time after a `T` left out. A year before 1900 is
    /// read as none (Apple's contacts write 1604 for "no year").
    pub fn parse(s_in: []const u8) ?Date {
        var s = std.mem.trim(u8, s_in, " \t");
        if (std.mem.indexOfScalar(u8, s, 'T')) |i| s = s[0..i];
        var y: u16 = 0;
        var m: u8 = 0;
        var d: u8 = 0;
        if (std.mem.startsWith(u8, s, "--")) {
            const r = s[2..];
            if (r.len == 4 and allDigits(r)) {
                m = digits2(r[0..2]).?;
                d = digits2(r[2..4]).?;
            } else if (r.len == 5 and r[2] == '-') {
                m = digits2(r[0..2]) orelse return null;
                d = digits2(r[3..5]) orelse return null;
            } else return null;
        } else if (s.len == 10 and s[4] == '-' and s[7] == '-') {
            if (!allDigits(s[0..4])) return null;
            y = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
            m = digits2(s[5..7]) orelse return null;
            d = digits2(s[8..10]) orelse return null;
        } else if (s.len == 8 and allDigits(s)) {
            y = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
            m = digits2(s[4..6]).?;
            d = digits2(s[6..8]).?;
        } else if (s.len == 5 and s[2] == '-') {
            m = digits2(s[0..2]) orelse return null;
            d = digits2(s[3..5]) orelse return null;
        } else return null;
        if (m < 1 or m > 12 or d < 1) return null;
        if (y != 0 and y < 1900) y = 0;
        // no year: a leap year's days
        if (d > daysIn(m, if (y == 0) 2000 else y)) return null;
        return .{ .y = y, .m = m, .d = d };
    }

    /// As a file holds it: `1989-11-28`, or `11-28`.
    pub fn text(dt: Date, buf: *[10]u8) []const u8 {
        if (dt.y == 0) return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2}", .{ dt.m, dt.d }) catch unreachable;
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ dt.y, dt.m, dt.d }) catch unreachable;
    }

    /// "28 November 1989", or "28 November".
    pub fn words(dt: Date, a: std.mem.Allocator) ![]const u8 {
        if (dt.y == 0) return std.fmt.allocPrint(a, "{d} {s}", .{ dt.d, month_names[dt.m - 1] });
        return std.fmt.allocPrint(a, "{d} {s} {d}", .{ dt.d, month_names[dt.m - 1], dt.y });
    }

    /// Its day in year `y` (28 February for 29 February in other years).
    pub fn inYear(dt: Date, y: i64) i64 {
        const d = @min(dt.d, daysIn(dt.m, y));
        return util.daysFromCivil(y, dt.m, d);
    }
};

/// A date with its year as a day number (days since 1970-01-01).
fn dayFromDate(dt: Date) ?i64 {
    if (dt.y == 0) return null;
    return util.daysFromCivil(dt.y, dt.m, dt.d);
}

fn dateOfDay(day: i64) Date {
    const c = util.civil(day);
    return .{ .y = @intCast(std.math.clamp(c.y, 0, 9999)), .m = c.m, .d = c.d };
}

/// "28 November 2026".
pub fn dayWords(a: std.mem.Allocator, day: i64) ![]const u8 {
    return dateOfDay(day).words(a);
}

/// "Saturday 28 November".
fn weekdayWords(a: std.mem.Allocator, day: i64) ![]const u8 {
    const c = util.civil(day);
    return std.fmt.allocPrint(a, "{s} {d} {s}", .{ day_names[util.weekday(day)], c.d, month_names[c.m - 1] });
}

pub const Unit = enum { day, week, month, year };

/// How often the owner wants to be in touch.
pub const Interval = struct {
    n: u16,
    unit: Unit,

    /// "3 months", "every 3 months", "a month", "year", "2 weeks", "10
    /// days"; at most ten years.
    pub fn parse(s_in: []const u8) ?Interval {
        var buf: [40]u8 = undefined;
        const s0 = std.mem.trim(u8, s_in, " \t");
        if (s0.len == 0 or s0.len > buf.len) return null;
        var s: []const u8 = std.ascii.lowerString(&buf, s0);
        if (std.mem.startsWith(u8, s, "every ")) s = std.mem.trim(u8, s[6..], " ");
        var it = std.mem.tokenizeScalar(u8, s, ' ');
        const first = it.next() orelse return null;
        const second = it.next();
        if (it.next() != null) return null;
        var n: u16 = 1;
        var unit_word = first;
        if (second) |u| {
            unit_word = u;
            if (std.mem.eql(u8, first, "a") or std.mem.eql(u8, first, "an")) {
                n = 1;
            } else n = std.fmt.parseInt(u16, first, 10) catch return null;
        }
        if (n == 0) return null;
        const unit: Unit = for ([_]struct { []const u8, Unit }{
            .{ "day", .day },     .{ "days", .day },     .{ "week", .week }, .{ "weeks", .week },
            .{ "month", .month }, .{ "months", .month }, .{ "year", .year }, .{ "years", .year },
        }) |x| {
            if (std.mem.eql(u8, unit_word, x[0])) break x[1];
        } else return null;
        const days: u32 = @as(u32, n) * switch (unit) {
            .day => @as(u32, 1),
            .week => 7,
            .month => 31,
            .year => 366,
        };
        if (days > 3660) return null;
        return .{ .n = n, .unit = unit };
    }

    /// As a file holds it: "3 months", "1 month".
    pub fn text(iv: Interval, buf: *[24]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d} {s}{s}", .{ iv.n, @tagName(iv.unit), if (iv.n == 1) "" else "s" }) catch unreachable;
    }

    /// "3 months", "a month".
    pub fn span(iv: Interval, a: std.mem.Allocator) ![]const u8 {
        if (iv.n == 1) return std.fmt.allocPrint(a, "a {s}", .{@tagName(iv.unit)});
        return std.fmt.allocPrint(a, "{d} {s}s", .{ iv.n, @tagName(iv.unit) });
    }

    /// "every 3 months", "every month".
    pub fn every(iv: Interval, a: std.mem.Allocator) ![]const u8 {
        if (iv.n == 1) return std.fmt.allocPrint(a, "every {s}", .{@tagName(iv.unit)});
        return std.fmt.allocPrint(a, "every {d} {s}s", .{ iv.n, @tagName(iv.unit) });
    }

    /// The day `iv` after `day`: a month later is the same day of the
    /// month, or the month's last.
    pub fn after(iv: Interval, day: i64) i64 {
        const months: i64 = switch (iv.unit) {
            .day => return day + iv.n,
            .week => return day + 7 * @as(i64, iv.n),
            .month => iv.n,
            .year => 12 * @as(i64, iv.n),
        };
        const c = util.civil(day);
        const total = @as(i64, c.m) - 1 + months;
        const y = c.y + @divFloor(total, 12);
        const m: u8 = @intCast(@mod(total, 12) + 1);
        return util.daysFromCivil(y, m, @min(c.d, daysIn(m, y)));
    }
};

pub const Dated = struct { label: []const u8, date: Date };

/// "name day 06-24": the label, then the date.
fn parseDated(v: []const u8) ?Dated {
    const sp = std.mem.lastIndexOfScalar(u8, v, ' ') orelse return null;
    const label = std.mem.trimEnd(u8, std.mem.trim(u8, v[0..sp], " \t"), ":");
    if (label.len == 0) return null;
    const date = Date.parse(v[sp + 1 ..]) orelse return null;
    return .{ .label = label, .date = date };
}

/// What a file says of a person. Its strings and lists live in the
/// arena it was made in.
pub const Person = struct {
    /// Its file's name without `.txt`.
    id: []const u8,
    name: []const u8 = "",
    called: std.ArrayList([]const u8) = .empty,
    relation: []const u8 = "",
    birthday: ?Date = null,
    anniversary: ?Date = null,
    dates: std.ArrayList(Dated) = .empty,
    preferences: std.ArrayList([]const u8) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    emails: std.ArrayList([]const u8) = .empty,
    phones: std.ArrayList([]const u8) = .empty,
    /// Day numbers (days since 1970-01-01).
    in_touch: ?i64 = null,
    keep: ?Interval = null,
    added: ?i64 = null,
    /// Lines harness doesn't read, kept as they are.
    other: std.ArrayList([]const u8) = .empty,

    /// A file's text (`\r\n` or `\n`); a line it can't read is kept.
    pub fn parse(a: std.mem.Allocator, id: []const u8, text_in: []const u8) !Person {
        var p: Person = .{ .id = try a.dupe(u8, id) };
        var lines = std.mem.splitScalar(u8, text_in, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                try p.other.append(a, try a.dupe(u8, line));
                continue;
            };
            var kb: [32]u8 = undefined;
            const key = keyOf(&kb, line[0..eq]);
            const v = try a.dupe(u8, util.cut(std.mem.trim(u8, line[eq + 1 ..], " \t"), max_value));
            const took = took: {
                if (std.mem.eql(u8, key, "name")) {
                    if (v.len == 0) break :took false;
                    p.name = v;
                } else if (std.mem.eql(u8, key, "relation")) {
                    p.relation = v;
                } else if (std.mem.eql(u8, key, "birthday")) {
                    p.birthday = Date.parse(v) orelse break :took false;
                } else if (std.mem.eql(u8, key, "anniversary")) {
                    p.anniversary = Date.parse(v) orelse break :took false;
                } else if (std.mem.eql(u8, key, "date")) {
                    if (p.dates.items.len >= max_values) break :took false;
                    try p.dates.append(a, parseDated(v) orelse break :took false);
                } else if (std.mem.eql(u8, key, "in touch")) {
                    p.in_touch = dayFromDate(Date.parse(v) orelse break :took false) orelse break :took false;
                } else if (std.mem.eql(u8, key, "keep in touch")) {
                    p.keep = Interval.parse(v) orelse break :took false;
                } else if (std.mem.eql(u8, key, "added")) {
                    p.added = dayFromDate(Date.parse(v) orelse break :took false) orelse break :took false;
                } else if (p.listOf(key)) |list| {
                    if (v.len == 0 or list.items.len >= max_values) break :took false;
                    try list.append(a, v);
                } else break :took false;
                break :took true;
            };
            if (!took) try p.other.append(a, try a.dupe(u8, line));
        }
        if (p.name.len == 0) p.name = p.id;
        return p;
    }

    fn listOf(p: *Person, key: []const u8) ?*std.ArrayList([]const u8) {
        if (std.mem.eql(u8, key, "called")) return &p.called;
        if (std.mem.eql(u8, key, "preference")) return &p.preferences;
        if (std.mem.eql(u8, key, "note")) return &p.notes;
        if (std.mem.eql(u8, key, "email")) return &p.emails;
        if (std.mem.eql(u8, key, "phone")) return &p.phones;
        return null;
    }

    /// The file's text, a fact a line, in a fixed order.
    pub fn render(p: *const Person, a: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var db: [10]u8 = undefined;
        try out.print(a, "name = {s}\n", .{p.name});
        for (p.called.items) |x| try out.print(a, "called = {s}\n", .{x});
        if (p.relation.len > 0) try out.print(a, "relation = {s}\n", .{p.relation});
        if (p.birthday) |d| try out.print(a, "birthday = {s}\n", .{d.text(&db)});
        if (p.anniversary) |d| try out.print(a, "anniversary = {s}\n", .{d.text(&db)});
        for (p.dates.items) |x| try out.print(a, "date = {s} {s}\n", .{ x.label, x.date.text(&db) });
        for (p.preferences.items) |x| try out.print(a, "preference = {s}\n", .{x});
        for (p.notes.items) |x| try out.print(a, "note = {s}\n", .{x});
        for (p.emails.items) |x| try out.print(a, "email = {s}\n", .{x});
        for (p.phones.items) |x| try out.print(a, "phone = {s}\n", .{x});
        if (p.in_touch) |d| try out.print(a, "in touch = {s}\n", .{dateOfDay(d).text(&db)});
        if (p.keep) |iv| {
            var ib: [24]u8 = undefined;
            try out.print(a, "keep in touch = {s}\n", .{iv.text(&ib)});
        }
        if (p.added) |d| try out.print(a, "added = {s}\n", .{dateOfDay(d).text(&db)});
        for (p.other.items) |x| try out.print(a, "{s}\n", .{x});
        return out.items;
    }

    /// What the owner calls them in a line: a name they are called by
    /// ("Ola", "Mum"), else the whole name.
    pub fn short(p: *const Person) []const u8 {
        for (p.called.items) |c| {
            if (std.ascii.startsWithIgnoreCase(c, "my ")) continue;
            return c;
        }
        return p.name;
    }

    /// "Ola Kowalska (sister)".
    fn title(p: *const Person, a: std.mem.Allocator) ![]const u8 {
        if (p.relation.len == 0) return p.name;
        return std.fmt.allocPrint(a, "{s} ({s})", .{ p.name, p.relation });
    }

    /// How to reach them, in a few words ("Phone +48 600 100 200"); "".
    fn reach(p: *const Person, a: std.mem.Allocator) ![]const u8 {
        if (p.phones.items.len > 0) return std.fmt.allocPrint(a, "Phone {s}", .{p.phones.items[0]});
        if (p.emails.items.len > 0) return std.fmt.allocPrint(a, "Email {s}", .{p.emails.items[0]});
        return "";
    }

    /// A deep copy, in `a`.
    fn clone(p: *const Person, a: std.mem.Allocator) !Person {
        var c: Person = .{ .id = try a.dupe(u8, p.id), .name = try a.dupe(u8, p.name), .relation = try a.dupe(u8, p.relation), .birthday = p.birthday, .anniversary = p.anniversary, .in_touch = p.in_touch, .keep = p.keep, .added = p.added };
        for ([_]struct { *const std.ArrayList([]const u8), *std.ArrayList([]const u8) }{
            .{ &p.called, &c.called }, .{ &p.preferences, &c.preferences }, .{ &p.notes, &c.notes },
            .{ &p.emails, &c.emails }, .{ &p.phones, &c.phones },     .{ &p.other, &c.other },
        }) |x| for (x[0].items) |s| try x[1].append(a, try a.dupe(u8, s));
        for (p.dates.items) |x| try c.dates.append(a, .{ .label = try a.dupe(u8, x.label), .date = x.date });
        return c;
    }
};

/// A key as `parse` compares it: lower case, one space between words.
fn keyOf(buf: *[32]u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |w| {
        if (n > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        for (w) |c| {
            if (n == buf.len) break;
            buf[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return buf[0..n];
}

/// The ASCII letter a Latin letter is written as in a file's name; null
/// for anything else.
fn asciiOf(cp: u21) ?u8 {
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else null;
    }
    const latin1 = "aaaaaaaceeeeiiiidnooooo\x00ouuuuyts";
    if (cp >= 0xC0 and cp <= 0xDF) return if (latin1[cp - 0xC0] == 0) null else latin1[cp - 0xC0];
    if (cp >= 0xE0 and cp <= 0xFF) {
        if (cp == 0xF7) return null;
        if (cp == 0xFF) return 'y';
        return latin1[cp - 0xE0];
    }
    const ranges = [_]struct { u21, u21, u8 }{
        .{ 0x100, 0x105, 'a' }, .{ 0x106, 0x10D, 'c' }, .{ 0x10E, 0x111, 'd' }, .{ 0x112, 0x11B, 'e' },
        .{ 0x11C, 0x123, 'g' }, .{ 0x124, 0x127, 'h' }, .{ 0x128, 0x133, 'i' }, .{ 0x134, 0x135, 'j' },
        .{ 0x136, 0x138, 'k' }, .{ 0x139, 0x142, 'l' }, .{ 0x143, 0x14B, 'n' }, .{ 0x14C, 0x153, 'o' },
        .{ 0x154, 0x159, 'r' }, .{ 0x15A, 0x161, 's' }, .{ 0x162, 0x167, 't' }, .{ 0x168, 0x173, 'u' },
        .{ 0x174, 0x175, 'w' }, .{ 0x176, 0x178, 'y' }, .{ 0x179, 0x17E, 'z' }, .{ 0x17F, 0x17F, 's' },
    };
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return r[2];
    return null;
}

/// A file's id from a name: lower-case letters and digits, `-` between
/// words, Latin letters without their marks ("Łukasz Żółć" →
/// `lukasz-zolc`); `person` when none is left.
pub fn slug(buf: []u8, name: []const u8) []const u8 {
    const max = @min(buf.len, max_id);
    var n: usize = 0;
    var gap = false;
    var i: usize = 0;
    while (i < name.len and n < max) {
        const len: usize = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        const cp: u21 = if (i + len <= name.len) std.unicode.utf8Decode(name[i .. i + len]) catch 0xFFFD else 0xFFFD;
        i += if (i + len <= name.len) len else 1;
        const c = asciiOf(cp) orelse {
            gap = true;
            continue;
        };
        if (gap and n > 0) {
            if (n + 1 >= max) break;
            buf[n] = '-';
            n += 1;
        }
        gap = false;
        buf[n] = c;
        n += 1;
    }
    if (n == 0) return "person";
    return buf[0..n];
}

/// An id that names a file in the folder and nothing else.
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64 or std.mem.indexOf(u8, id, "..") != null) return false;
    for (id) |c| if (c == '/' or c == '\\' or c == ':' or c < ' ' or c == 0x7f) return false;
    return true;
}

/// `text` in lower case (letters beyond ASCII too), trimmed, one space
/// between words, without a leading "my ".
fn norm(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(a, ' ');
        var i: usize = 0;
        while (i < w.len) {
            const len: usize = std.unicode.utf8ByteSequenceLength(w[i]) catch 1;
            if (i + len > w.len) {
                try out.append(a, w[i]);
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(w[i .. i + len]) catch {
                try out.append(a, w[i]);
                i += 1;
                continue;
            };
            var eb: [4]u8 = undefined;
            const el = std.unicode.utf8Encode(who_mod.lowerLetter(cp), &eb) catch 0;
            try out.appendSlice(a, eb[0..el]);
            i += len;
        }
    }
    const s2 = out.items;
    if (std.mem.startsWith(u8, s2, "my ")) return s2[3..];
    return s2;
}

/// The words of `s` (letters and digits, bytes beyond ASCII among them).
fn wordsOf(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and !wordByte(s[i])) i += 1;
        const start = i;
        while (i < s.len and wordByte(s[i])) i += 1;
        if (i > start) try out.append(a, s[start..i]);
    }
    return out.items;
}

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '@' or c == '.' or c == '+';
}

/// A value as a file can hold it: one line, trimmed, cut.
fn clean(a: std.mem.Allocator, v: []const u8) ![]const u8 {
    const one = try a.dupe(u8, v);
    for (one) |*c| if (c.* == '\r' or c.* == '\n' or c.* == '\t') {
        c.* = ' ';
    };
    return util.cut(std.mem.trim(u8, one, " "), max_value);
}

/// The facts the tool and the memory writer note.
pub const Field = enum {
    called,
    relation,
    birthday,
    anniversary,
    date,
    preference,
    note,
    email,
    phone,
    in_touch,
    keep_in_touch,

    pub fn of(s: []const u8) ?Field {
        var kb: [32]u8 = undefined;
        const k = keyOf(&kb, s);
        for (std.enums.values(Field)) |f| {
            var nb: [32]u8 = undefined;
            const name = nb[0..@tagName(f).len];
            @memcpy(name, @tagName(f));
            std.mem.replaceScalar(u8, name, '_', ' ');
            if (std.mem.eql(u8, k, name) or std.mem.eql(u8, k, @tagName(f))) return f;
        }
        if (std.mem.eql(u8, k, "nickname")) return .called;
        if (std.mem.eql(u8, k, "likes") or std.mem.eql(u8, k, "preferences")) return .preference;
        return null;
    }
};

const fields_text = "called, relation, birthday, anniversary, date, preference, note, email, phone, in touch, keep in touch";

/// What a change to a person came to.
const Change = union(enum) {
    /// Its words ("birthday 28 November 1989").
    added: []const u8,
    same,
    bad: []const u8,
};

fn hasText(list: []const []const u8, v: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, v)) return true;
    return false;
}

fn digitsOf(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| if (std.ascii.isDigit(c) and n < buf.len) {
        buf[n] = c;
        n += 1;
    };
    return buf[0..n];
}

fn hasPhone(list: []const []const u8, v: []const u8) bool {
    var vb: [40]u8 = undefined;
    const vd = digitsOf(&vb, v);
    for (list) |x| {
        var xb: [40]u8 = undefined;
        if (std.mem.eql(u8, digitsOf(&xb, x), vd)) return true;
    }
    return false;
}

fn validEmail(v: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, v, '@') orelse return false;
    return at > 0 and at + 1 < v.len and std.mem.indexOfAny(u8, v, " \t<>,;") == null;
}

fn validPhone(v: []const u8) bool {
    var nd: usize = 0;
    for (v) |c| {
        if (std.ascii.isDigit(c)) {
            nd += 1;
        } else if (std.mem.indexOfScalar(u8, "+-() ./", c) == null) return false;
    }
    return nd >= 3;
}

/// Sets `field` to `v` (cleaned) on `p` (its strings in `pa`); `today`
/// for "today" and a first `added`.
fn apply(p: *Person, pa: std.mem.Allocator, a: std.mem.Allocator, field: Field, v: []const u8, today: i64) !Change {
    switch (field) {
        .called, .preference, .note, .email, .phone => {
            const list: *std.ArrayList([]const u8) = switch (field) {
                .called => &p.called,
                .preference => &p.preferences,
                .note => &p.notes,
                .email => &p.emails,
                else => &p.phones,
            };
            if (field == .email and !validEmail(v)) return .{ .bad = "That is not an email address." };
            if (field == .phone and !validPhone(v)) return .{ .bad = "That is not a phone number." };
            if (field == .phone) {
                if (hasPhone(list.items, v)) return .same;
            } else if (hasText(list.items, v)) return .same;
            if (field == .called and std.ascii.eqlIgnoreCase(v, p.name)) return .same;
            if (list.items.len >= max_values) return .{ .bad = try std.fmt.allocPrint(a, "{s} has {d} of those already; edit state/people/{s}.txt.", .{ p.name, max_values, p.id }) };
            try list.append(pa, try pa.dupe(u8, v));
            return .{ .added = if (field == .called) try std.fmt.allocPrint(a, "called {s}", .{v}) else v };
        },
        .relation => {
            if (std.ascii.eqlIgnoreCase(p.relation, v)) return .same;
            p.relation = try pa.dupe(u8, v);
            return .{ .added = try std.fmt.allocPrint(a, "relation {s}", .{v}) };
        },
        .birthday, .anniversary => {
            const d = Date.parse(v) orelse return .{ .bad = if (field == .birthday) "A birthday is a date: YYYY-MM-DD, or MM-DD without the year." else "An anniversary is a date: YYYY-MM-DD, or MM-DD without the year." };
            const slot = if (field == .birthday) &p.birthday else &p.anniversary;
            if (slot.*) |old| if (std.meta.eql(old, d)) return .same;
            slot.* = d;
            return .{ .added = try std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(field), try d.words(a) }) };
        },
        .date => {
            const x = parseDated(v) orelse return .{ .bad = "A date is a label and a date: name day 06-24." };
            for (p.dates.items) |*old| if (std.ascii.eqlIgnoreCase(old.label, x.label)) {
                if (std.meta.eql(old.date, x.date)) return .same;
                old.date = x.date;
                return .{ .added = try std.fmt.allocPrint(a, "{s} {s}", .{ x.label, try x.date.words(a) }) };
            };
            if (p.dates.items.len >= max_values) return .{ .bad = try std.fmt.allocPrint(a, "{s} has {d} dates already; edit state/people/{s}.txt.", .{ p.name, max_values, p.id }) };
            try p.dates.append(pa, .{ .label = try pa.dupe(u8, x.label), .date = x.date });
            return .{ .added = try std.fmt.allocPrint(a, "{s} {s}", .{ x.label, try x.date.words(a) }) };
        },
        .in_touch => {
            const no_day: Change = .{ .bad = "In touch takes a date with its year (YYYY-MM-DD) or today." };
            const day: i64 = blk: {
                if (std.ascii.eqlIgnoreCase(v, "today") or std.ascii.eqlIgnoreCase(v, "yes")) break :blk today;
                if (std.ascii.eqlIgnoreCase(v, "yesterday")) break :blk today - 1;
                const d = Date.parse(v) orelse return no_day;
                break :blk dayFromDate(d) orelse return no_day;
            };
            if (day > today) return .{ .bad = "In touch takes a day that has come: today or before." };
            if (p.in_touch) |old| if (old >= day) return .same;
            p.in_touch = day;
            return .{ .added = try std.fmt.allocPrint(a, "in touch {s}", .{try dayWords(a, day)}) };
        },
        .keep_in_touch => {
            const off = for ([_][]const u8{ "off", "no", "never", "stop", "none" }) |w| {
                if (std.ascii.eqlIgnoreCase(v, w)) break true;
            } else false;
            if (off) {
                if (p.keep == null) return .same;
                p.keep = null;
                return .{ .added = "keep in touch off" };
            }
            const iv = Interval.parse(v) orelse return .{ .bad = "Keep in touch takes a time like 3 months, 2 weeks or a year; off stops it." };
            if (p.keep) |old| if (std.meta.eql(old, iv)) return .same;
            p.keep = iv;
            // counted from today when no day in touch is known
            if (p.in_touch == null) p.added = today;
            return .{ .added = try std.fmt.allocPrint(a, "keep in touch {s}", .{try iv.every(a)}) };
        },
    }
}

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    p: Person,
};

/// Who a name, an email or a relation finds.
const Found = union(enum) {
    one: *Entry,
    none,
    several: []*Entry,
};

/// The people of one data folder, and what of them was said on which
/// day. Every public call takes the lock and answers in its own arena.
pub const Book = struct {
    gpa: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    told_path: []const u8,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(*Entry) = .empty,
    /// The last day planned (`planDay`), and each line said: its key and
    /// the day (`state/people-told`).
    told_day: i64 = 0,
    told: std.StringArrayHashMapUnmanaged(i64) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, dir: []const u8, told_path: []const u8) Book {
        return .{ .gpa = gpa, .io = io, .dir = dir, .told_path = told_path };
    }

    pub fn deinit(b: *Book) void {
        for (b.entries.items) |e| b.freeEntry(e);
        b.entries.deinit(b.gpa);
        b.entries = .empty;
        for (b.told.keys()) |k| b.gpa.free(k);
        b.told.deinit(b.gpa);
        b.told = .empty;
    }

    fn freeEntry(b: *Book, e: *Entry) void {
        e.arena.deinit();
        b.gpa.destroy(e);
    }

    /// Reads the folder (made, only the owner's, when missing): every
    /// `ID.txt` file; others (a write's temp file among them) are left.
    pub fn load(b: *Book) !void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        try Io.Dir.cwd().createDirPath(b.io, b.dir);
        var d = try Io.Dir.cwd().openDir(b.io, b.dir, .{ .iterate = true });
        defer d.close(b.io);
        if (@import("builtin").os.tag != .windows) d.setPermissions(b.io, .fromMode(0o700)) catch {};
        var it = d.iterate();
        while (try it.next(b.io)) |f| {
            if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".txt")) continue;
            const id = f.name[0 .. f.name.len - 4];
            if (!validId(id)) continue;
            const e = try b.gpa.create(Entry);
            e.* = .{ .arena = .init(b.gpa), .p = undefined };
            const ea = e.arena.allocator();
            const text = d.readFileAlloc(b.io, f.name, ea, .limited(max_file)) catch {
                b.freeEntry(e);
                continue;
            };
            e.p = Person.parse(ea, id, text) catch {
                b.freeEntry(e);
                continue;
            };
            b.entries.append(b.gpa, e) catch |err| {
                b.freeEntry(e);
                return err;
            };
        }
        b.sort();
        try b.loadTold();
    }

    /// `state/people-told`: `day N`, then `DAY KEY` a line.
    fn loadTold(b: *Book) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const text = Io.Dir.cwd().readFileAlloc(b.io, b.told_path, arena.allocator(), .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const rest = std.mem.trim(u8, line[sp + 1 ..], " ");
            if (std.mem.eql(u8, line[0..sp], "day")) {
                b.told_day = std.fmt.parseInt(i64, rest, 10) catch 0;
                continue;
            }
            const day = std.fmt.parseInt(i64, line[0..sp], 10) catch continue;
            if (rest.len == 0) continue;
            const gop = try b.told.getOrPut(b.gpa, rest);
            if (!gop.found_existing) gop.key_ptr.* = try b.gpa.dupe(u8, rest);
            gop.value_ptr.* = day;
        }
    }

    fn sort(b: *Book) void {
        std.mem.sort(*Entry, b.entries.items, {}, struct {
            fn lt(_: void, x: *Entry, y: *Entry) bool {
                return std.ascii.lessThanIgnoreCase(x.p.name, y.p.name) or (std.ascii.eqlIgnoreCase(x.p.name, y.p.name) and std.mem.order(u8, x.p.id, y.p.id) == .lt);
            }
        }.lt);
    }

    pub fn count(b: *Book) usize {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return b.entries.items.len;
    }

    /// How well `q` (normed) names `e`: 3 the whole name, what the owner
    /// calls them, the relation, an email or the file's id; 2 the first
    /// name; 1 every word of it among theirs; 0 not.
    fn score(a: std.mem.Allocator, e: *const Entry, q: []const u8) !u8 {
        if (q.len == 0) return 0;
        const p = &e.p;
        if (std.mem.eql(u8, try norm(a, p.name), q) or std.mem.eql(u8, try norm(a, p.relation), q) or std.mem.eql(u8, p.id, q)) return 3;
        for (p.called.items) |c| if (std.mem.eql(u8, try norm(a, c), q)) return 3;
        for (p.emails.items) |m| if (std.ascii.eqlIgnoreCase(m, q)) return 3;
        const name_n = try norm(a, p.name);
        if (std.mem.indexOfScalar(u8, q, ' ') == null and std.mem.eql(u8, name_n[0 .. std.mem.indexOfScalar(u8, name_n, ' ') orelse name_n.len], q)) return 2;
        const theirs = try wordsOf(a, try norm(a, try std.mem.join(a, " ", &.{ p.name, try std.mem.join(a, " ", p.called.items), p.relation })));
        const ours = try wordsOf(a, q);
        if (ours.len == 0) return 0;
        for (ours) |w| {
            for (theirs) |x| {
                if (std.mem.eql(u8, w, x)) break;
            } else return 0;
        }
        return 1;
    }

    const Hit = struct { e: *Entry, score: u8 };

    /// Everyone `query` names, best first (the book's order within a score).
    fn hits(b: *Book, a: std.mem.Allocator, query: []const u8) ![]Hit {
        const q = try norm(a, query);
        var out: std.ArrayList(Hit) = .empty;
        for (b.entries.items) |e| {
            const s = try score(a, e, q);
            if (s > 0) try out.append(a, .{ .e = e, .score = s });
        }
        std.mem.sort(Hit, out.items, {}, struct {
            fn lt(_: void, x: Hit, y: Hit) bool {
                return x.score > y.score;
            }
        }.lt);
        return out.items;
    }

    fn resolve(b: *Book, a: std.mem.Allocator, query: []const u8) !Found {
        const hs = try b.hits(a, query);
        if (hs.len == 0) return .none;
        var n: usize = 1;
        while (n < hs.len and hs[n].score == hs[0].score) n += 1;
        if (n == 1) return .{ .one = hs[0].e };
        const list = try a.alloc(*Entry, n);
        for (hs[0..n], 0..) |h, i| list[i] = h.e;
        return .{ .several = list };
    }

    /// A copy of the person `query` names alone, in `a`; null: none or several.
    pub fn get(b: *Book, a: std.mem.Allocator, query: []const u8) !?Person {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return switch (try b.resolve(a, query)) {
            .one => |e| try e.p.clone(a),
            else => null,
        };
    }

    /// The tool's find: a line each, best first; empty words list everyone.
    pub fn findText(b: *Book, a: std.mem.Allocator, query: []const u8) ![]const u8 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        if (b.entries.items.len == 0) return "No people yet.";
        var out: std.ArrayList(u8) = .empty;
        const max = 30;
        if (std.mem.trim(u8, query, " \t").len == 0) {
            for (b.entries.items[0..@min(max, b.entries.items.len)]) |e| try out.print(a, "{s}\n", .{try e.p.title(a)});
            if (b.entries.items.len > max) try out.print(a, "…and {d} more; give a name.\n", .{b.entries.items.len - max});
            return out.items;
        }
        const hs = try b.hits(a, query);
        if (hs.len == 0) return std.fmt.allocPrint(a, "No one matches {s}.", .{query});
        for (hs[0..@min(max, hs.len)]) |h| try out.print(a, "{s}\n", .{try h.e.p.title(a)});
        return out.items;
    }

    fn several(a: std.mem.Allocator, query: []const u8, list: []*Entry) ![]const u8 {
        var names: std.ArrayList(u8) = .empty;
        for (list, 0..) |e, i| try names.print(a, "{s}{s}", .{ if (i > 0) ", " else "", e.p.name });
        return std.fmt.allocPrint(a, "Several people match {s}: {s}. The whole name says which.", .{ query, names.items });
    }

    /// `/person NAME`, the tool's show: all that is known of one person.
    pub fn cardText(b: *Book, a: std.mem.Allocator, query: []const u8) ![]const u8 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return switch (try b.resolve(a, query)) {
            .none => std.fmt.allocPrint(a, "No one called {s}. /people lists everyone.", .{query}),
            .several => |list| several(a, query, list),
            .one => |e| card(a, &e.p),
        };
    }

    /// `/people`: a line each, at most `max`.
    pub fn listing(b: *Book, a: std.mem.Allocator, max: usize) ![]const u8 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const all = b.entries.items;
        if (all.len == 0) return "No people yet. They come from what you tell me in your own conversations, from your calendar's invitations, and from harness people import FILE.vcf.";
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{d} {s}:\n", .{ all.len, if (all.len == 1) "person" else "people" });
        for (all[0..@min(max, all.len)]) |e| {
            const p = &e.p;
            try out.appendSlice(a, try p.title(a));
            var sep: []const u8 = ": ";
            if (p.birthday) |d| {
                try out.print(a, "{s}birthday {s}", .{ sep, try (Date{ .m = d.m, .d = d.d }).words(a) });
                sep = "; ";
            }
            if (p.keep) |iv| try out.print(a, "{s}keep in touch {s}", .{ sep, try iv.every(a) });
            try out.append(a, '\n');
        }
        if (all.len > max) try out.print(a, "…and {d} more (harness people list shows all).\n", .{all.len - max});
        return out.items;
    }

    pub const Noted = struct { text: []const u8, ok: bool, saved: bool = false };

    /// A fact noted about `name_in` (someone new when no one has that
    /// name); its file written whole.
    pub fn note(b: *Book, a: std.mem.Allocator, name_in: []const u8, field_s: []const u8, value: []const u8, today: i64) !Noted {
        const field = Field.of(field_s) orelse return .{ .ok = false, .text = try std.fmt.allocPrint(a, "No such fact: {s}. One of: {s}.", .{ field_s, fields_text }) };
        const v = try clean(a, value);
        const name = try clean(a, name_in);
        if (name.len == 0) return .{ .ok = false, .text = "Say who." };
        if (v.len == 0) return .{ .ok = false, .text = "Say what to note." };
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const e = switch (try b.resolve(a, name)) {
            .one => |e| e,
            .several => |list| return .{ .ok = false, .text = try several(a, name, list) },
            .none => null,
        };
        if (e) |x| return b.change(a, x, field, v, today);
        if (b.entries.items.len >= max_people) return .{ .ok = false, .text = "The book is full (5,000 people)." };
        const x = try b.newEntry(name, today);
        const res = try b.change(a, x, field, v, today);
        if (!res.saved) b.dropEntry(x);
        return res;
    }

    fn change(b: *Book, a: std.mem.Allocator, e: *Entry, field: Field, v: []const u8, today: i64) !Noted {
        const ch = try apply(&e.p, e.arena.allocator(), a, field, v, today);
        switch (ch) {
            .bad => |why| return .{ .ok = false, .text = why },
            .same => return .{ .ok = true, .text = try std.fmt.allocPrint(a, "Already known of {s}: {s}.", .{ e.p.name, v }) },
            .added => |words| {
                try b.save(a, &e.p);
                return .{ .ok = true, .saved = true, .text = try std.fmt.allocPrint(a, "Noted for {s}: {s}.", .{ e.p.name, words }) };
            },
        }
    }

    /// Someone new, in the book (not written yet): an id of their own.
    fn newEntry(b: *Book, name: []const u8, today: i64) !*Entry {
        const e = try b.gpa.create(Entry);
        e.* = .{ .arena = .init(b.gpa), .p = undefined };
        errdefer b.freeEntry(e);
        const ea = e.arena.allocator();
        var sb: [64]u8 = undefined;
        const base = slug(&sb, name);
        var id = try ea.dupe(u8, base);
        var n: u32 = 2;
        while (b.hasId(id)) : (n += 1) id = try std.fmt.allocPrint(ea, "{s}-{d}", .{ base, n });
        e.p = .{ .id = id, .name = try ea.dupe(u8, name), .added = today };
        try b.entries.append(b.gpa, e);
        b.sort();
        return e;
    }

    fn hasId(b: *Book, id: []const u8) bool {
        for (b.entries.items) |e| if (std.ascii.eqlIgnoreCase(e.p.id, id)) return true;
        return false;
    }

    fn dropEntry(b: *Book, e: *Entry) void {
        for (b.entries.items, 0..) |x, i| if (x == e) {
            _ = b.entries.orderedRemove(i);
            break;
        };
        b.freeEntry(e);
    }

    /// Writes a person's file whole.
    fn save(b: *Book, a: std.mem.Allocator, p: *const Person) !void {
        if (!validId(p.id)) return error.BadId;
        try Io.Dir.cwd().createDirPath(b.io, b.dir);
        const path = try std.fs.path.join(a, &.{ b.dir, try std.fmt.allocPrint(a, "{s}.txt", .{p.id}) });
        try util.writeReplace(b.io, path, try p.render(a));
    }

    pub const Imported = struct { new: usize = 0, updated: usize = 0, same: usize = 0, skipped: usize = 0, full: bool = false };

    /// A contacts file (vCard 3 or 4) into the book: a card is the person
    /// with one of its emails, or its whole name, or (someone known by a
    /// first name alone) its first name; else someone new. What a person
    /// has is kept; a card adds what is missing.
    pub fn importVcf(b: *Book, a: std.mem.Allocator, text: []const u8, today: i64) !Imported {
        const cards = try parseVcards(a, text);
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var got: Imported = .{};
        for (cards) |c| {
            if (c.name.len == 0) {
                got.skipped += 1;
                continue;
            }
            var renamed = false;
            const known = try b.cardMatch(a, &c, &renamed);
            const e = known orelse blk: {
                if (b.entries.items.len >= max_people) {
                    got.full = true;
                    break;
                }
                break :blk try b.newEntry(c.name, today);
            };
            var changed = renamed;
            const ea = e.arena.allocator();
            for (c.nicknames) |x| if ((try apply(&e.p, ea, a, .called, x, today)) == .added) {
                changed = true;
            };
            if (c.bday) |d| if (e.p.birthday == null) {
                e.p.birthday = d;
                changed = true;
            };
            if (c.anniversary) |d| if (e.p.anniversary == null) {
                e.p.anniversary = d;
                changed = true;
            };
            for (c.emails) |x| if ((try apply(&e.p, ea, a, .email, x, today)) == .added) {
                changed = true;
            };
            for (c.phones) |x| if ((try apply(&e.p, ea, a, .phone, x, today)) == .added) {
                changed = true;
            };
            if (known == null) {
                try b.save(a, &e.p);
                got.new += 1;
            } else if (changed) {
                try b.save(a, &e.p);
                got.updated += 1;
            } else got.same += 1;
        }
        return got;
    }

    /// What day `day` brings (see `Plan`); null when it was planned
    /// already. A week line not said by the day before is not said: the
    /// day's own line follows.
    pub fn planDay(b: *Book, a: std.mem.Allocator, day: i64) !?Plan {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        if (b.told_day >= day) return null;
        var days: std.ArrayList(Line) = .empty;
        var weeks: std.ArrayList(Line) = .empty;
        var touches: std.ArrayList(struct { line: Line, due: i64 }) = .empty;
        for (b.entries.items) |e| {
            const p = &e.p;
            const who = try a.dupe(u8, p.short());
            const reach_s = try p.reach(a);
            for ([_]struct { ?Date, Occasion }{ .{ p.birthday, .birthday }, .{ p.anniversary, .anniversary } }) |o| {
                const date = o[0] orelse continue;
                const occ = nextOn(date, day);
                const in_days = occ - day;
                if (in_days > 7) continue;
                const y = util.civil(occ).y;
                const kind: Kind = if (in_days == 0) .day else .week;
                const key = try std.fmt.allocPrint(a, "{s} {s} {s} {d}", .{ @tagName(kind), @tagName(o[1]), p.id, y });
                if (b.told.contains(key)) continue;
                var l: Line = .{ .kind = kind, .key = key, .id = try a.dupe(u8, p.id), .who = who, .occasion = o[1], .on = occ, .in_days = in_days, .reach = reach_s };
                if (date.y != 0 and y > date.y) l.years = y - date.y;
                if (kind == .week) {
                    var prefs: std.ArrayList([]const u8) = .empty;
                    for (p.preferences.items) |x| try prefs.append(a, try a.dupe(u8, x));
                    l.preferences = prefs.items;
                    if (interestOf(prefs.items)) |i| l.interest = i;
                    try weeks.append(a, l);
                } else try days.append(a, l);
            }
            const keep = p.keep orelse continue;
            const since = p.in_touch orelse p.added orelse continue;
            const key = try std.fmt.allocPrint(a, "touch {s}", .{p.id});
            const due = keep.after(@max(since, b.told.get(key) orelse since));
            if (day < due) continue;
            try touches.append(a, .{ .due = due, .line = .{ .kind = .touch, .key = key, .id = try a.dupe(u8, p.id), .who = who, .on = since, .reach = reach_s, .keep = keep, .from_touch = p.in_touch != null } });
        }
        if (days.items.len > 0) return .{ .day = day, .lines = days.items };
        if (weeks.items.len > 0) {
            var best = weeks.items[0];
            for (weeks.items[1..]) |l| if (l.in_days < best.in_days) {
                best = l;
            };
            return .{ .day = day, .lines = try a.dupe(Line, &.{best}) };
        }
        if (touches.items.len > 0) {
            var best = touches.items[0];
            for (touches.items[1..]) |x| if (x.due < best.due) {
                best = x;
            };
            return .{ .day = day, .lines = try a.dupe(Line, &.{best.line}) };
        }
        return .{ .day = day, .lines = &.{} };
    }

    /// Plan `plan` was said: kept in `state/people-told`, written whole
    /// (what was said over two years before it is let go).
    pub fn markTold(b: *Book, plan: Plan) !void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.told_day = @max(b.told_day, plan.day);
        for (plan.lines) |l| {
            const gop = try b.told.getOrPut(b.gpa, l.key);
            if (!gop.found_existing) gop.key_ptr.* = try b.gpa.dupe(u8, l.key);
            gop.value_ptr.* = plan.day;
        }
        var i: usize = 0;
        while (i < b.told.count()) {
            if (b.told.values()[i] < plan.day - 800) {
                const k = b.told.keys()[i];
                b.told.swapRemoveAt(i);
                b.gpa.free(k);
            } else i += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.gpa);
        try out.print(b.gpa, "day {d}\n", .{b.told_day});
        for (b.told.keys(), b.told.values()) |k, v| try out.print(b.gpa, "{d} {s}\n", .{ v, k });
        try util.writeReplace(b.io, b.told_path, out.items);
    }

    /// The person a card is: by email, by the whole name, or someone
    /// known only by the card's first name (then named by the card, the
    /// old name kept as what the owner calls them: `renamed`).
    fn cardMatch(b: *Book, a: std.mem.Allocator, c: *const Card, renamed: *bool) !?*Entry {
        for (b.entries.items) |e| for (e.p.emails.items) |m| for (c.emails) |x| if (std.ascii.eqlIgnoreCase(m, x)) return e;
        const whole = try norm(a, c.name);
        var found: ?*Entry = null;
        var n: usize = 0;
        for (b.entries.items) |e| if (std.mem.eql(u8, try norm(a, e.p.name), whole)) {
            found = e;
            n += 1;
        };
        if (n == 1) return found;
        if (n > 1) return null;
        const first = try norm(a, if (c.given.len > 0) c.given else c.name[0 .. std.mem.indexOfScalar(u8, c.name, ' ') orelse c.name.len]);
        if (first.len == 0 or std.mem.eql(u8, first, whole)) return null;
        n = 0;
        for (b.entries.items) |e| if (std.mem.eql(u8, try norm(a, e.p.name), first)) {
            found = e;
            n += 1;
        };
        if (n != 1) return null;
        const e = found.?;
        const ea = e.arena.allocator();
        const old = e.p.name;
        e.p.name = try ea.dupe(u8, c.name);
        if (!hasText(e.p.called.items, old)) try e.p.called.insert(ea, 0, old);
        renamed.* = true;
        return e;
    }
};

/// All that is known of one person, a fact a line.
fn card(a: std.mem.Allocator, p: *const Person) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}\n", .{try p.title(a)});
    if (p.called.items.len > 0) try out.print(a, "Called: {s}\n", .{try std.mem.join(a, ", ", p.called.items)});
    if (p.birthday) |d| try out.print(a, "Birthday: {s}\n", .{try d.words(a)});
    if (p.anniversary) |d| try out.print(a, "Anniversary: {s}\n", .{try d.words(a)});
    for (p.dates.items) |x| {
        const label = try a.dupe(u8, x.label);
        label[0] = std.ascii.toUpper(label[0]);
        try out.print(a, "{s}: {s}\n", .{ label, try x.date.words(a) });
    }
    if (p.preferences.items.len > 0) try out.print(a, "Preferences: {s}\n", .{try std.mem.join(a, "; ", p.preferences.items)});
    if (p.notes.items.len > 0) try out.print(a, "Notes: {s}\n", .{try std.mem.join(a, "; ", p.notes.items)});
    if (p.emails.items.len > 0) try out.print(a, "Email: {s}\n", .{try std.mem.join(a, ", ", p.emails.items)});
    if (p.phones.items.len > 0) try out.print(a, "Phone: {s}\n", .{try std.mem.join(a, ", ", p.phones.items)});
    if (p.in_touch) |d| try out.print(a, "Last in touch: {s}\n", .{try dayWords(a, d)});
    if (p.keep) |iv| try out.print(a, "Keep in touch: {s}\n", .{try iv.every(a)});
    try out.print(a, "File: state/people/{s}.txt", .{p.id});
    return out.items;
}

// ---- vCard ----

/// What a contacts file's card says that a person keeps.
const Card = struct {
    name: []const u8 = "",
    given: []const u8 = "",
    nicknames: []const []const u8 = &.{},
    bday: ?Date = null,
    anniversary: ?Date = null,
    emails: []const []const u8 = &.{},
    phones: []const []const u8 = &.{},
};

/// The logical lines of a vCard file: a line starting with a space or a
/// tab goes on the one before it (RFC 6350 3.2), `\r\n` or `\n`.
fn unfold(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList(std.ArrayList(u8)) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t') and out.items.len > 0) {
            try out.items[out.items.len - 1].appendSlice(a, line[1..]);
            continue;
        }
        var l: std.ArrayList(u8) = .empty;
        try l.appendSlice(a, line);
        try out.append(a, l);
    }
    const lines = try a.alloc([]const u8, out.items.len);
    for (out.items, 0..) |l, i| lines[i] = l.items;
    return lines;
}

/// A vCard text value: `\,` `\;` `\\` as themselves, `\n` a space.
fn unescapeV(a: std.mem.Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] == '\\' and i + 1 < v.len) {
            i += 1;
            try out.append(a, if (v[i] == 'n' or v[i] == 'N') ' ' else v[i]);
        } else try out.append(a, v[i]);
    }
    return std.mem.trim(u8, out.items, " ");
}

/// `v` split at `sep` where it is not escaped, each part unescaped.
fn splitV(a: std.mem.Allocator, v: []const u8, sep: u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= v.len) : (i += 1) {
        if (i < v.len and v[i] == '\\') {
            i += 1;
            continue;
        }
        if (i == v.len or v[i] == sep) {
            try out.append(a, try unescapeV(a, v[start..@min(i, v.len)]));
            start = i + 1;
        }
    }
    return out.items;
}

fn parseVcards(a: std.mem.Allocator, text: []const u8) ![]const Card {
    var cards: std.ArrayList(Card) = .empty;
    var cur: ?Card = null;
    var nick: std.ArrayList([]const u8) = .empty;
    var mails: std.ArrayList([]const u8) = .empty;
    var tels: std.ArrayList([]const u8) = .empty;
    var n_name: []const u8 = "";
    for (try unfold(a, text)) |line| {
        // the value starts after the first colon outside double quotes
        var quoted = false;
        const colon = for (line, 0..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (c == ':' and !quoted) break i;
        } else continue;
        const head = line[0..colon];
        const value = line[colon + 1 ..];
        var prop = head[0 .. std.mem.indexOfScalar(u8, head, ';') orelse head.len];
        if (std.mem.lastIndexOfScalar(u8, prop, '.')) |dot| prop = prop[dot + 1 ..];
        const is = struct {
            fn f(p: []const u8, name: []const u8) bool {
                return std.ascii.eqlIgnoreCase(p, name);
            }
        }.f;
        if (is(prop, "BEGIN") and std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " "), "VCARD")) {
            cur = .{};
            nick = .empty;
            mails = .empty;
            tels = .empty;
            n_name = "";
            continue;
        }
        if (cur == null) continue;
        const c = &cur.?;
        if (is(prop, "END")) {
            if (c.name.len == 0) c.name = n_name;
            c.nicknames = nick.items;
            c.emails = mails.items;
            c.phones = tels.items;
            try cards.append(a, c.*);
            cur = null;
        } else if (is(prop, "FN")) {
            c.name = try clean(a, try unescapeV(a, value));
        } else if (is(prop, "N")) {
            const parts = try splitV(a, value, ';');
            const family = if (parts.len > 0) parts[0] else "";
            const given = if (parts.len > 1) parts[1] else "";
            c.given = try clean(a, given);
            n_name = try clean(a, std.mem.trim(u8, try std.fmt.allocPrint(a, "{s} {s}", .{ given, family }), " "));
        } else if (is(prop, "NICKNAME")) {
            for (try splitV(a, value, ',')) |x| if (x.len > 0) try nick.append(a, try clean(a, x));
        } else if (is(prop, "BDAY")) {
            c.bday = Date.parse(value);
        } else if (is(prop, "ANNIVERSARY")) {
            c.anniversary = Date.parse(value);
        } else if (is(prop, "EMAIL")) {
            const m = try clean(a, try unescapeV(a, value));
            if (validEmail(m)) try mails.append(a, m);
        } else if (is(prop, "TEL")) {
            var v = try unescapeV(a, value);
            if (std.ascii.startsWithIgnoreCase(v, "tel:")) v = v[4..];
            v = v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse v.len];
            const p = try clean(a, v);
            if (validPhone(p)) try tels.append(a, p);
        }
    }
    return cards.items;
}

// ---- occasions and keeping in touch ----

pub const Kind = enum { day, week, touch };
pub const Occasion = enum { birthday, anniversary };

/// One line due on a day, with what its words need.
pub const Line = struct {
    kind: Kind,
    /// What `Told` keeps of it once it is said.
    key: []const u8,
    id: []const u8,
    /// What the owner calls them.
    who: []const u8,
    occasion: Occasion = .birthday,
    /// The occasion's day (day, week); the day counted from (touch).
    on: i64 = 0,
    in_days: i64 = 0,
    /// Their age, or the years since the anniversary.
    years: ?i64 = null,
    /// "Phone +48 600 100 200"; "".
    reach: []const u8 = "",
    /// The one preference a gift search may look for; null: none.
    interest: ?[]const u8 = null,
    preferences: []const []const u8 = &.{},
    keep: ?Interval = null,
    /// touch: counted from a day they were in touch (else from when the
    /// owner asked to keep in touch).
    from_touch: bool = false,
};

/// What a day brings: every birthday and anniversary of the day, else the
/// one line most due (a week ahead, then keeping in touch).
pub const Plan = struct { day: i64, lines: []const Line };

/// The preference a gift search may carry: the first that says what they
/// like ("likes Polish poetry"); never an allergy, a diet or anything else.
pub fn interestOf(prefs: []const []const u8) ?[]const u8 {
    const likes = [_][]const u8{ "likes ", "loves ", "enjoys ", "is into ", "into ", "fan of ", "a fan of ", "is a fan of ", "collects ", "reads ", "plays ", "listens to ", "watches ", "follows " };
    for (prefs) |p| for (likes) |w| if (std.ascii.startsWithIgnoreCase(p, w) and p.len > w.len) return p;
    return null;
}

/// The words searched for a gift: the interest alone.
pub fn giftQuery(a: std.mem.Allocator, interest: []const u8) ![]const u8 {
    const low = try a.dupe(u8, interest);
    if (low.len > 0) low[0] = std.ascii.toLower(low[0]);
    for ([_][]const u8{ "is a fan of ", "a fan of ", "fan of " }) |w| if (std.ascii.startsWithIgnoreCase(low, w))
        return std.fmt.allocPrint(a, "gift ideas for a fan of {s}", .{low[w.len..]});
    return std.fmt.allocPrint(a, "gift ideas for someone who {s}", .{low});
}

/// The day of `date` on or after `day`.
fn nextOn(date: Date, day: i64) i64 {
    const y = util.civil(day).y;
    const o = date.inYear(y);
    return if (o >= day) o else date.inYear(y + 1);
}

/// The line the owner reads; `idea`: the gift idea found for a week line.
pub fn lineText(a: std.mem.Allocator, l: Line, idea: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const occ = @tagName(l.occasion);
    switch (l.kind) {
        .week => {
            const when = if (l.in_days == 1) try a.dupe(u8, "tomorrow") else if (l.in_days == 7) try a.dupe(u8, "in a week") else try std.fmt.allocPrint(a, "in {d} days", .{l.in_days});
            try out.print(a, "{s}'s {s} is {s}, on {s}", .{ l.who, occ, when, try weekdayWords(a, l.on) });
            if (l.years) |y| {
                if (l.occasion == .birthday) try out.print(a, " (turns {d})", .{y}) else try out.print(a, " ({d} year{s})", .{ y, if (y == 1) "" else "s" });
            }
            try out.append(a, '.');
            if (idea) |x| try out.print(a, " Gift idea: {s}", .{x});
            return out.items;
        },
        .day => {
            try out.print(a, "Today is {s}'s {s}", .{ l.who, occ });
            if (l.years) |y| {
                if (l.occasion == .birthday) try out.print(a, " ({d})", .{y}) else try out.print(a, " ({d} year{s})", .{ y, if (y == 1) "" else "s" });
            }
            try out.append(a, '.');
        },
        .touch => {
            const keep = l.keep orelse Interval{ .n = 1, .unit = .month };
            const c = util.civil(l.on);
            const since = if (keep.unit == .year) try dayWords(a, l.on) else try std.fmt.allocPrint(a, "{d} {s}", .{ c.d, month_names[c.m - 1] });
            if (l.from_touch)
                try out.print(a, "It's been {s} since you were last in touch with {s} ({s}).", .{ try keep.span(a), l.who, since })
            else
                try out.print(a, "It's been {s} since you asked to keep in touch with {s} ({s}).", .{ try keep.span(a), l.who, since });
        },
    }
    if (l.reach.len > 0) try out.print(a, " {s}.", .{l.reach});
    return out.items;
}

const t = std.testing;

/// A day number from a date.
fn dayOf(y: i64, m: u8, d: u8) i64 {
    return util.daysFromCivil(y, m, d);
}

const BookFix = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    book: Book,
    dir: []const u8,

    fn init(f: *BookFix) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        const a = f.arena.allocator();
        const root = try f.tmp.dir.realPathFileAlloc(t.io, ".", a);
        f.dir = try std.fs.path.join(a, &.{ root, "people" });
        f.book = .init(t.allocator, t.io, f.dir, try std.fs.path.join(a, &.{ root, "people-told" }));
        try f.book.load();
    }

    fn deinit(f: *BookFix) void {
        f.book.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn file(f: *BookFix, id: []const u8) ![]const u8 {
        const a = f.arena.allocator();
        return Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(a, &.{ f.dir, try std.fmt.allocPrint(a, "{s}.txt", .{id}) }), a, .limited(max_file));
    }

    fn reload(f: *BookFix) !void {
        f.book.deinit();
        f.book = .init(t.allocator, t.io, f.book.dir, f.book.told_path);
        try f.book.load();
    }
};

const ola_file =
    \\name = Ola Kowalska
    \\called = Ola
    \\called = my sister
    \\relation = sister
    \\birthday = 1989-11-28
    \\anniversary = 2015-06-20
    \\date = name day 06-24
    \\preference = likes Polish poetry
    \\preference = allergic to nuts
    \\note = works nights at the hospital
    \\email = ola@example.com
    \\phone = +48 600 100 200
    \\in touch = 2026-08-02
    \\keep in touch = 3 months
    \\added = 2026-01-10
    \\colour = green
    \\
;

test "a_person_file_round_trips" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Person.parse(a, "ola-kowalska", ola_file);
    try t.expectEqualStrings("Ola Kowalska", p.name);
    try t.expectEqual(2, p.called.items.len);
    try t.expectEqualStrings("my sister", p.called.items[1]);
    try t.expectEqualStrings("sister", p.relation);
    try t.expectEqual(Date{ .y = 1989, .m = 11, .d = 28 }, p.birthday.?);
    try t.expectEqual(Date{ .y = 2015, .m = 6, .d = 20 }, p.anniversary.?);
    try t.expectEqualStrings("name day", p.dates.items[0].label);
    try t.expectEqual(Date{ .m = 6, .d = 24 }, p.dates.items[0].date);
    try t.expectEqual(2, p.preferences.items.len);
    try t.expectEqualStrings("works nights at the hospital", p.notes.items[0]);
    try t.expectEqualStrings("ola@example.com", p.emails.items[0]);
    try t.expectEqualStrings("+48 600 100 200", p.phones.items[0]);
    try t.expectEqual(dayOf(2026, 8, 2), p.in_touch.?);
    try t.expectEqual(Interval{ .n = 3, .unit = .month }, p.keep.?);
    try t.expectEqual(dayOf(2026, 1, 10), p.added.?);
    // a line harness doesn't read is kept
    try t.expectEqualStrings(ola_file, try p.render(a));
    // Windows line ends, as Notepad writes them: the same person
    const crlf = try std.mem.replaceOwned(u8, a, ola_file, "\n", "\r\n");
    try t.expectEqualStrings(ola_file, try (try Person.parse(a, "ola-kowalska", crlf)).render(a));
    // no name line: the file's id is its name
    try t.expectEqualStrings("anna", (try Person.parse(a, "anna", "relation = neighbour\n")).name);
}

test "dates_and_intervals_read" {
    try t.expectEqual(Date{ .y = 1989, .m = 11, .d = 28 }, Date.parse("1989-11-28").?);
    try t.expectEqual(Date{ .y = 1989, .m = 11, .d = 28 }, Date.parse("19891128").?);
    try t.expectEqual(Date{ .y = 1989, .m = 11, .d = 28 }, Date.parse("1989-11-28T00:00:00Z").?);
    try t.expectEqual(Date{ .m = 4, .d = 12 }, Date.parse("04-12").?);
    try t.expectEqual(Date{ .m = 4, .d = 12 }, Date.parse("--04-12").?);
    try t.expectEqual(Date{ .m = 4, .d = 12 }, Date.parse("--0412").?);
    try t.expectEqual(Date{ .m = 2, .d = 29 }, Date.parse("02-29").?);
    for ([_][]const u8{ "", "1989-13-01", "1989-02-30", "2026-02-29", "12", "tomorrow", "1989-11-28x" }) |bad| try t.expect(Date.parse(bad) == null);
    try t.expectEqual(Interval{ .n = 3, .unit = .month }, Interval.parse("3 months").?);
    try t.expectEqual(Interval{ .n = 3, .unit = .month }, Interval.parse("every 3 months").?);
    try t.expectEqual(Interval{ .n = 1, .unit = .month }, Interval.parse("a month").?);
    try t.expectEqual(Interval{ .n = 1, .unit = .year }, Interval.parse("year").?);
    try t.expectEqual(Interval{ .n = 2, .unit = .week }, Interval.parse("2 weeks").?);
    try t.expectEqual(Interval{ .n = 10, .unit = .day }, Interval.parse("10 days").?);
    for ([_][]const u8{ "", "0 months", "3", "months 3", "3 fortnights", "100000 days" }) |bad| try t.expect(Interval.parse(bad) == null);
}

test "find_by_name_what_the_owner_calls_them_and_relation" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const today = dayOf(2026, 11, 23);
    _ = try f.book.note(a, "Ola Kowalska", "called", "my sister", today);
    _ = try f.book.note(a, "Ola Kowalska", "relation", "sister", today);
    _ = try f.book.note(a, "Ola Nowak", "relation", "colleague", today);
    _ = try f.book.note(a, "Łukasz Żółć", "email", "lukasz@example.com", today);
    // by the whole name, any case
    try t.expectEqualStrings("Ola Kowalska", (try f.book.get(a, "ola kowalska")).?.name);
    // by what the owner calls her, with or without "my"
    try t.expectEqualStrings("Ola Kowalska", (try f.book.get(a, "my sister")).?.name);
    try t.expectEqualStrings("Ola Kowalska", (try f.book.get(a, "sister")).?.name);
    // a letter's case beyond ASCII
    try t.expectEqualStrings("Łukasz Żółć", (try f.book.get(a, "łukasz")).?.name);
    try t.expectEqualStrings("Łukasz Żółć", (try f.book.get(a, "lukasz@example.com")).?.name);
    // a first name two people share names no one alone
    try t.expect((try f.book.get(a, "Ola")) == null);
    const found = try f.book.findText(a, "ola");
    try t.expect(std.mem.indexOf(u8, found, "Ola Kowalska (sister)") != null);
    try t.expect(std.mem.indexOf(u8, found, "Ola Nowak (colleague)") != null);
    try t.expect(std.mem.indexOf(u8, try f.book.cardText(a, "ola"), "Several people match ola: Ola Kowalska, Ola Nowak.") != null);
    try t.expectEqualStrings("No one called Basia. /people lists everyone.", try f.book.cardText(a, "Basia"));
    try t.expectEqualStrings("No one matches basia.", try f.book.findText(a, "basia"));
}

test "note_adds_and_replaces_facts" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const today = dayOf(2026, 11, 23);
    var n = try f.book.note(a, "Ola", "birthday", "1989-11-28", today);
    try t.expect(n.ok);
    try t.expectEqualStrings("Noted for Ola: birthday 28 November 1989.", n.text);
    n = try f.book.note(a, "Ola", "preference", "likes Polish poetry", today);
    try t.expectEqualStrings("Noted for Ola: likes Polish poetry.", n.text);
    // the same again: nothing new
    n = try f.book.note(a, "ola", "preference", "Likes Polish poetry", today);
    try t.expectEqualStrings("Already known of Ola: Likes Polish poetry.", n.text);
    // one-valued facts are replaced; a date needs a date
    _ = try f.book.note(a, "Ola", "relation", "friend", today);
    _ = try f.book.note(a, "Ola", "relation", "sister", today);
    n = try f.book.note(a, "Ola", "birthday", "soon", today);
    try t.expect(!n.ok);
    try t.expectEqualStrings("A birthday is a date: YYYY-MM-DD, or MM-DD without the year.", n.text);
    n = try f.book.note(a, "Ola", "keep in touch", "3 months", today);
    try t.expectEqualStrings("Noted for Ola: keep in touch every 3 months.", n.text);
    n = try f.book.note(a, "Ola", "in touch", "today", today);
    try t.expectEqualStrings("Noted for Ola: in touch 23 November 2026.", n.text);
    n = try f.book.note(a, "Ola", "shoe size", "38", today);
    try t.expect(!n.ok);
    try t.expect(std.mem.startsWith(u8, n.text, "No such fact: shoe size. One of: called, relation, birthday"));
    // written whole, and read back
    try f.reload();
    const p = (try f.book.get(a, "Ola")).?;
    try t.expectEqualStrings("sister", p.relation);
    try t.expectEqual(dayOf(2026, 11, 23), p.in_touch.?);
    try t.expectEqual(dayOf(2026, 11, 23), p.added.?);
    try t.expectEqualStrings("name = Ola\nrelation = sister\nbirthday = 1989-11-28\npreference = likes Polish poetry\nin touch = 2026-11-23\nkeep in touch = 3 months\nadded = 2026-11-23\n", try f.file("ola"));
    // a value's line ends are spaces: one value never makes two lines
    _ = try f.book.note(a, "Ola", "note", "line one\r\nrelation = enemy", today);
    try f.reload();
    try t.expectEqualStrings("sister", (try f.book.get(a, "Ola")).?.relation);
}

const contacts =
    "BEGIN:VCARD\r\n" ++
    "VERSION:3.0\r\n" ++
    "FN:Ola Kowalska\r\n" ++
    "N:Kowalska;Ola;;;\r\n" ++
    "NICKNAME:Olka,Sis\r\n" ++
    "BDAY:1989-11-28\r\n" ++
    "EMAIL;TYPE=INTERNET,HOME:ola@example.com\r\n" ++
    "TEL;TYPE=CELL:+48 600 100 200\r\n" ++
    "NOTE:Loves Polish poetry and long\r\n" ++
    "  walks\r\n" ++
    "PHOTO;ENCODING=b;TYPE=JPEG:MIICajCCAdOgAwIBAgICBEUwDQYJKoZIhvcNAQEEBQAwdzELMAkGA1UEBhMCVVMxLDAqBgNVBAoTI05l\r\n" ++
    " dHNjYXBlIENvbW11bmljYXRpb25zIENvcnBvcmF0aW9uMRwwGgYDVQQLExNJbmZvcm1hdGlvbiBT\r\n" ++
    "END:VCARD\r\n" ++
    "BEGIN:VCARD\r\n" ++
    "VERSION:4.0\r\n" ++
    "N:Nowak;Marek;;;\r\n" ++
    "BDAY:--0412\r\n" ++
    "ANNIVERSARY:20150620\r\n" ++
    "EMAIL:marek@example.com\r\n" ++
    "TEL;VALUE=uri;TYPE=\"voice,cell\":tel:+48-601-200-300\r\n" ++
    "item1.EMAIL;type=INTERNET:marek.work@exam\r\n" ++
    " ple.com\r\n" ++
    "END:VCARD\r\n" ++
    "BEGIN:VCARD\r\n" ++
    "VERSION:3.0\r\n" ++
    "FN:Anna\\, the neighbour\r\n" ++
    "BDAY;VALUE=date:1970-01-01\r\n" ++
    "END:VCARD\r\n" ++
    "BEGIN:VCARD\r\n" ++
    "VERSION:3.0\r\n" ++
    "EMAIL:nobody@example.com\r\n" ++
    "END:VCARD\r\n";

test "vcard_3_and_4_import" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const today = dayOf(2026, 11, 23);
    // the owner said "my sister Ola" before: the card fills her in
    _ = try f.book.note(a, "Ola", "relation", "sister", today);
    const got = try f.book.importVcf(a, contacts, today);
    try t.expectEqual(2, got.new);
    try t.expectEqual(1, got.updated);
    try t.expectEqual(1, got.skipped);
    try t.expectEqual(3, f.book.count());
    const ola = (try f.book.get(a, "Ola Kowalska")).?;
    try t.expectEqualStrings("ola", ola.id);
    try t.expectEqualStrings("sister", ola.relation);
    try t.expectEqual(Date{ .y = 1989, .m = 11, .d = 28 }, ola.birthday.?);
    try t.expectEqual(3, ola.called.items.len); // Ola (the name she had), Olka, Sis
    try t.expectEqualStrings("ola@example.com", ola.emails.items[0]);
    try t.expectEqualStrings("+48 600 100 200", ola.phones.items[0]);
    // a card's note is not read
    try t.expectEqual(0, ola.notes.items.len);
    const marek = (try f.book.get(a, "marek@example.com")).?;
    try t.expectEqualStrings("Marek Nowak", marek.name);
    try t.expectEqualStrings("marek-nowak", marek.id);
    try t.expectEqual(Date{ .m = 4, .d = 12 }, marek.birthday.?);
    try t.expectEqual(Date{ .y = 2015, .m = 6, .d = 20 }, marek.anniversary.?);
    try t.expectEqualStrings("+48-601-200-300", marek.phones.items[0]);
    try t.expectEqualStrings("marek.work@example.com", marek.emails.items[1]);
    try t.expectEqualStrings("Anna, the neighbour", (try f.book.get(a, "Anna, the neighbour")).?.name);
    // again: nothing new
    const again = try f.book.importVcf(a, contacts, today);
    try t.expectEqual(0, again.new);
    try t.expectEqual(0, again.updated);
    try t.expectEqual(3, again.same);
    // line ends of \n alone read the same
    var f2: BookFix = undefined;
    try f2.init();
    defer f2.deinit();
    const lf = try std.mem.replaceOwned(u8, a, contacts, "\r\n", "\n");
    try t.expectEqual(3, (try f2.book.importVcf(a, lf, today)).new);
    try t.expectEqualStrings("marek.work@example.com", (try f2.book.get(a, "Marek Nowak")).?.emails.items[1]);
}

test "file_names_stay_in_the_folder" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("ola-kowalska", slug(&buf, "Ola Kowalska"));
    try t.expectEqualStrings("lukasz-zolc", slug(&buf, "Łukasz Żółć"));
    try t.expectEqualStrings("etc-passwd", slug(&buf, "../../etc/passwd"));
    try t.expectEqualStrings("person", slug(&buf, "李"));
    try t.expectEqualStrings("person", slug(&buf, ".."));
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const today = dayOf(2026, 11, 23);
    _ = try f.book.note(a, "Zoe Smith", "relation", "friend", today);
    _ = try f.book.note(a, "Zoë Smith", "relation", "cousin", today);
    try t.expectEqualStrings("cousin", (try f.book.get(a, "Zoë Smith")).?.relation);
    try t.expectEqualStrings("zoe-smith-2", (try f.book.get(a, "Zoë Smith")).?.id);
    try t.expectEqualStrings("friend", (try f.book.get(a, "Zoe Smith")).?.relation);
    _ = try f.book.note(a, "../../x", "relation", "none", today);
    // a temp file left by a write, a file by another name, a planted name
    var d = try Io.Dir.cwd().openDir(t.io, f.dir, .{});
    defer d.close(t.io);
    try d.writeFile(t.io, .{ .sub_path = "zoe-smith.txt.tmp-0a1b2c", .data = "name = Half Written\n" });
    try d.writeFile(t.io, .{ .sub_path = "notes.md", .data = "name = Not A Person\n" });
    try d.writeFile(t.io, .{ .sub_path = "zosia.txt", .data = "name = Zosia\r\nrelation = niece\r\n" });
    try f.reload();
    try t.expectEqual(4, f.book.count());
    try t.expect((try f.book.get(a, "Half Written")) == null);
    try t.expectEqualStrings("niece", (try f.book.get(a, "Zosia")).?.relation);
    // nothing outside the folder
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, try std.fs.path.join(a, &.{ f.dir, "..", "x.txt" }), .{}));
}

fn note3(f: *BookFix, name: []const u8, facts: []const [2][]const u8, day: i64) !void {
    for (facts) |x| {
        const n = try f.book.note(f.arena.allocator(), name, x[0], x[1], day);
        if (!n.ok) {
            std.debug.print("note {s} {s}: {s}\n", .{ name, x[0], n.text });
            return error.NotNoted;
        }
    }
}

fn planOf(f: *BookFix, day: i64) !Plan {
    const p = (try f.book.planDay(f.arena.allocator(), day)) orelse return error.PlannedAlready;
    try f.book.markTold(p);
    return p;
}

test "a_birthday_a_week_before_and_on_the_day" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try note3(&f, "Ola Kowalska", &.{ .{ "called", "Ola" }, .{ "called", "my sister" }, .{ "birthday", "1989-11-28" }, .{ "preference", "allergic to nuts" }, .{ "preference", "likes Polish poetry" }, .{ "phone", "+48 600 100 200" } }, dayOf(2026, 1, 10));
    // an ordinary day brings nothing, once
    try t.expectEqual(0, (try planOf(&f, dayOf(2026, 11, 20))).lines.len);
    try t.expect((try f.book.planDay(a, dayOf(2026, 11, 20))) == null);
    // a week before: one line, with the one interest a search may carry
    const wk = try planOf(&f, dayOf(2026, 11, 21));
    try t.expectEqual(1, wk.lines.len);
    const w = wk.lines[0];
    try t.expectEqual(Kind.week, w.kind);
    try t.expectEqual(7, w.in_days);
    try t.expectEqual(37, w.years.?);
    try t.expectEqualStrings("likes Polish poetry", w.interest.?);
    try t.expectEqualStrings("Ola's birthday is in a week, on Saturday 28 November (turns 37).", try lineText(a, w, null));
    try t.expectEqualStrings("Ola's birthday is in a week, on Saturday 28 November (turns 37). Gift idea: a Szymborska collection, https://example.com/s", try lineText(a, w, "a Szymborska collection, https://example.com/s"));
    // said: not again the next days
    try t.expectEqual(0, (try planOf(&f, dayOf(2026, 11, 22))).lines.len);
    try t.expectEqual(0, (try planOf(&f, dayOf(2026, 11, 27))).lines.len);
    // on the day, with how to reach her
    const on = try planOf(&f, dayOf(2026, 11, 28));
    try t.expectEqual(1, on.lines.len);
    try t.expectEqualStrings("Today is Ola's birthday (37). Phone +48 600 100 200.", try lineText(a, on.lines[0], null));
    // what was said is kept across a restart
    try f.reload();
    try t.expect((try f.book.planDay(a, dayOf(2026, 11, 28))) == null);
    try t.expectEqual(0, (try planOf(&f, dayOf(2026, 11, 29))).lines.len);
}

test "keep_in_touch_after_the_interval" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try note3(&f, "Marek", &.{ .{ "keep in touch", "3 months" }, .{ "in touch", "2026-08-02" } }, dayOf(2026, 8, 5));
    try t.expectEqual(0, (try planOf(&f, dayOf(2026, 11, 1))).lines.len);
    const due = try planOf(&f, dayOf(2026, 11, 2));
    try t.expectEqual(1, due.lines.len);
    try t.expectEqual(Kind.touch, due.lines[0].kind);
    try t.expectEqualStrings("It's been 3 months since you were last in touch with Marek (2 August).", try lineText(a, due.lines[0], null));
    // said once, then again after another three months
    try t.expectEqual(0, (try planOf(&f, dayOf(2026, 11, 3))).lines.len);
    try t.expectEqual(0, (try planOf(&f, dayOf(2027, 2, 1))).lines.len);
    try t.expectEqual(1, (try planOf(&f, dayOf(2027, 2, 2))).lines.len);
    // being in touch moves it on
    try note3(&f, "Marek", &.{.{ "in touch", "2027-02-03" }}, dayOf(2027, 2, 3));
    try t.expectEqual(0, (try planOf(&f, dayOf(2027, 5, 2))).lines.len);
    try t.expectEqual(1, (try planOf(&f, dayOf(2027, 5, 3))).lines.len);
    // never in touch: counted from when the owner asked
    try note3(&f, "Basia", &.{ .{ "phone", "601 200 300" }, .{ "keep in touch", "2 weeks" } }, dayOf(2027, 5, 10));
    const b = try planOf(&f, dayOf(2027, 5, 24));
    try t.expectEqualStrings("It's been 2 weeks since you asked to keep in touch with Basia (10 May). Phone 601 200 300.", try lineText(a, b.lines[0], null));
}

test "one_line_a_day_the_rest_the_next_day" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const d0 = dayOf(2026, 10, 1);
    try note3(&f, "Adam", &.{.{ "birthday", "12-05" }}, d0);
    try note3(&f, "Dora", &.{.{ "birthday", "1990-12-05" }}, d0);
    try note3(&f, "Beata", &.{.{ "birthday", "12-07" }}, d0);
    try note3(&f, "Celina", &.{ .{ "keep in touch", "a month" }, .{ "in touch", "2026-10-01" } }, d0);
    var said: std.ArrayList(u8) = .empty;
    var day = dayOf(2026, 12, 1);
    while (day <= dayOf(2026, 12, 7)) : (day += 1) {
        const p = try planOf(&f, day);
        for (p.lines) |l| try said.print(a, "{d}: {s}\n", .{ util.civil(day).d, try lineText(a, l, null) });
    }
    try t.expectEqualStrings(
        \\1: Adam's birthday is in 4 days, on Saturday 5 December.
        \\2: Dora's birthday is in 3 days, on Saturday 5 December (turns 36).
        \\3: Beata's birthday is in 4 days, on Monday 7 December.
        \\4: It's been a month since you were last in touch with Celina (1 October).
        \\5: Today is Adam's birthday.
        \\5: Today is Dora's birthday (36).
        \\7: Today is Beata's birthday.
        \\
    , said.items);
}

test "feb_29_and_the_years_turn" {
    var f: BookFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const d0 = dayOf(2026, 10, 1);
    try note3(&f, "Ewa", &.{.{ "birthday", "2000-02-29" }}, d0);
    try note3(&f, "Filip", &.{.{ "birthday", "01-03" }}, d0);
    try note3(&f, "Gosia", &.{ .{ "anniversary", "2015-06-20" }, .{ "email", "gosia@example.com" } }, d0);
    const ny = try planOf(&f, dayOf(2026, 12, 27));
    try t.expectEqualStrings("Filip's birthday is in a week, on Sunday 3 January.", try lineText(a, ny.lines[0], null));
    try t.expectEqualStrings("Filip's birthday is tomorrow, on Sunday 3 January.", try lineText(a, .{ .kind = .week, .key = "", .id = "filip", .who = "Filip", .on = dayOf(2027, 1, 3), .in_days = 1 }, null));
    // not a leap year: the day before 1 March
    const leapless = try planOf(&f, dayOf(2027, 2, 28));
    try t.expectEqualStrings("Today is Ewa's birthday (27).", try lineText(a, leapless.lines[0], null));
    const ann = try planOf(&f, dayOf(2027, 6, 20));
    try t.expectEqualStrings("Today is Gosia's anniversary (12 years). Email gosia@example.com.", try lineText(a, ann.lines[0], null));
}

test "the_gift_search_carries_one_interest_only" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Likes Polish poetry", interestOf(&.{ "allergic to nuts", "diabetic", "Likes Polish poetry", "loves jazz" }).?);
    try t.expect(interestOf(&.{ "allergic to nuts", "vegetarian", "doesn't drink" }) == null);
    try t.expectEqualStrings("gift ideas for someone who likes Polish poetry", try giftQuery(a, "Likes Polish poetry"));
    try t.expectEqualStrings("gift ideas for a fan of jazz", try giftQuery(a, "fan of jazz"));
}

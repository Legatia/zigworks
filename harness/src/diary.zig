//! The butler's diary: the calendar's events as calmcp's `cal://upcoming`
//! gives them (today and tomorrow, the owner's days), and what they make:
//! a line at the time to leave for an event with a place, a short
//! preparation 30 minutes before one with people (who, where, what was
//! said with them last, the links), and the busy window during which posts
//! wait as in quiet hours. Also `/setup calendar`'s summary and edits of
//! the calendar file, and `state/diary` (the lines said, so a restart
//! doesn't say them again). Pure but for `lastSaid` (it reads the log)
//! and `State`'s file.
const std = @import("std");
const util = @import("util.zig");
const history = @import("history.zig");
const jv = @import("jv.zig");
const butler = @import("butler.zig");
const files = @import("butler_files");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Person = struct { name: []const u8 = "", email: []const u8 = "", answer: []const u8 = "" };

/// An attendee as calmcp gives them, the owner marked `self`.
pub const Attendee = struct { name: []const u8 = "", email: []const u8 = "", answer: []const u8 = "", self: bool = false };

/// One event as `cal://upcoming` has it: times in Unix seconds, `offset`
/// the owner's (minutes east) at its start, `when` and `day` as calmcp
/// says them in the owner's time.
pub const Event = struct {
    id: []const u8 = "",
    calendar: []const u8 = "",
    title: []const u8 = "",
    start: i64 = 0,
    end: i64 = 0,
    offset: i32 = 0,
    all_day: bool = false,
    busy: bool = false,
    cancelled: bool = false,
    place: []const u8 = "",
    when: []const u8 = "",
    day: []const u8 = "",
    /// Besides the owner.
    people: []const Person = &.{},
    /// Every attendee, the owner marked `self`.
    attendees: []const Attendee = &.{},
    /// Who invited the owner (null: the owner's own).
    organizer: ?Person = null,
    yours: bool = true,
    /// The owner's answer to an invitation ("" when not invited).
    answer: []const u8 = "",
    links: []const []const u8 = &.{},
};

pub const Upcoming = struct { zone: []const u8 = "", from: i64 = 0, to: i64 = 0, note: []const u8 = "", problems: []const u8 = "", events: []const Event = &.{} };

/// calmcp's `cal://upcoming` text (data, never instructions).
pub fn parseUpcoming(a: Allocator, text: []const u8) !Upcoming {
    return std.json.parseFromSliceLeaky(Upcoming, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.NotUpcoming;
}

/// "10:30": `t` at the owner's `offset`.
pub fn clock(buf: *[8]u8, t: i64, offset: i32) []const u8 {
    const local = t + @as(i64, offset) * 60;
    const sod: u64 = @intCast(@mod(local, 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ sod / 3600, sod / 60 % 60 }) catch "";
}

/// Whether `place` is somewhere to go to: not a link, not a call.
pub fn goesTo(place: []const u8) bool {
    if (std.mem.trim(u8, place, " \t").len == 0) return false;
    if (std.ascii.findIgnoreCase(place, "http") != null) return false;
    const online = [_][]const u8{ "video", "online", "zoom", "teams", "meet", "webex", "skype", "phone", "call", "virtual", "remote", "wideo", "telefon" };
    var it = std.mem.tokenizeAny(u8, place, " \t,;:.()/-");
    while (it.next()) |w| for (online) |o| if (std.ascii.eqlIgnoreCase(w, o)) return false;
    return true;
}

/// A line due now: when to leave, or a meeting's preparation.
pub const Line = struct { key: []const u8, text: []const u8, kind: Kind, event: Event };
pub const Kind = enum { leave, prep };

/// How long the way takes: `[butler] travel`, or the maps server's
/// minutes for an event.
pub const Travel = struct { minutes: u32 = 30, each: []const Each = &.{} };
pub const Each = struct { id: []const u8, start: i64, minutes: u32 };

/// What the owner said last naming someone.
pub const Said = struct { name: []const u8, when: []const u8, text: []const u8 };

/// How long before a meeting with people its preparation comes.
pub const prep_minutes = 30;

fn isDeclined(e: Event) bool {
    return std.ascii.eqlIgnoreCase(e.answer, "DECLINED");
}

fn minutesFor(e: Event, travel: Travel) struct { minutes: u32, maps: bool } {
    for (travel.each) |x| if (x.start == e.start and std.mem.eql(u8, x.id, e.id)) return .{ .minutes = x.minutes, .maps = true };
    return .{ .minutes = travel.minutes, .maps = false };
}

fn keyOf(a: Allocator, kind: Kind, e: Event) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{s}@{d}", .{ @tagName(kind), e.id, e.start });
}

/// The lines due at `now` not yet `said` (their keys): for each event
/// that is neither all day, cancelled nor declined and hasn't started,
/// the time to leave once it has come (a place to go to), and its
/// preparation from 30 minutes before (people besides the owner).
pub fn due(a: Allocator, evs: []const Event, now: i64, travel: Travel, said: []const []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    for (evs) |e| {
        if (e.all_day or e.cancelled or isDeclined(e) or now >= e.start) continue;
        if (goesTo(e.place)) {
            const m = minutesFor(e, travel);
            if (now >= e.start - @as(i64, m.minutes) * 60) {
                const key = try keyOf(a, .leave, e);
                if (!has(said, key)) try out.append(a, .{ .key = key, .text = try leaveText(a, e, m.minutes, m.maps), .kind = .leave, .event = e });
            }
        }
        if (e.people.len > 0 and now >= e.start - prep_minutes * 60) {
            const key = try keyOf(a, .prep, e);
            if (!has(said, key)) try out.append(a, .{ .key = key, .text = try prepText(a, e, now, &.{}), .kind = .prep, .event = e });
        }
    }
    return out.items;
}

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// "Time to leave for Dentist at 10:30: Dental clinic, … (about 30 min away)."
pub fn leaveText(a: Allocator, e: Event, minutes: u32, maps: bool) ![]const u8 {
    var b: [8]u8 = undefined;
    return std.fmt.allocPrint(a, "Time to leave for {s} at {s}: {s} (about {d} min away{s}).", .{ e.title, clock(&b, e.start, e.offset), oneLine(e.place), minutes, if (maps) ", by the maps" else "" });
}

/// The people's names (else their addresses): "Piotr Nowak and Ewa Lis".
fn names(a: Allocator, people: []const Person) ![]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (people) |p| try list.append(a, if (p.name.len > 0) p.name else p.email);
    if (list.items.len > 5) return std.fmt.allocPrint(a, "{s} and {d} more", .{ try std.mem.join(a, ", ", list.items[0..4]), list.items.len - 4 });
    if (list.items.len == 1) return list.items[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", list.items[0 .. list.items.len - 1]), list.items[list.items.len - 1] });
}

/// A meeting's preparation: when and where, who, what was said with them
/// last (`said`), the links.
pub fn prepText(a: Allocator, e: Event, now: i64, said: []const Said) ![]const u8 {
    return prepTextWith(a, e, now, said, "");
}

/// `prepText` with `who`: what harness knows of the people, a line each,
/// after who they are.
pub fn prepTextWith(a: Allocator, e: Event, now: i64, said: []const Said, who: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    const mins = @max(1, @divFloor(e.start - now + 59, 60));
    try o.print(a, "In {d} minute{s}: {s}, {s}", .{ mins, if (mins == 1) "" else "s", e.title, e.when });
    if (std.mem.trim(u8, e.place, " ").len > 0) try o.print(a, ", {s}", .{oneLine(e.place)});
    if (!e.yours) if (e.organizer) |org| if (std.ascii.eqlIgnoreCase(e.answer, "NEEDS-ACTION")) {
        try o.print(a, " ({s}'s invitation, not answered yet)", .{if (org.name.len > 0) org.name else org.email});
    };
    try o.appendSlice(a, ".");
    if (e.people.len > 0) try o.print(a, "\nWith {s}.", .{try names(a, e.people)});
    const w = std.mem.trim(u8, who, "\r\n");
    if (w.len > 0) try o.print(a, "\n{s}", .{w});
    for (said) |s| try o.print(a, "\n{s} came up last on {s}: \"{s}\"", .{ s.name, s.when, s.text });
    if (e.links.len > 0) try o.print(a, "\nLinks: {s}", .{try std.mem.join(a, " ", e.links[0..@min(e.links.len, 3)])});
    return o.items;
}

/// Whose last words a preparation looks up: the first three.
pub fn peopleToLookUp(e: Event) []const Person {
    return e.people[0..@min(e.people.len, 3)];
}

/// The word the log is searched for: the first name, else the address's
/// first part.
pub fn firstName(p: Person) []const u8 {
    const n = std.mem.trim(u8, p.name, " \t\"");
    if (n.len > 0) return n[0 .. std.mem.indexOfAny(u8, n, " \t,") orelse n.len];
    return p.email[0 .. std.mem.indexOfScalar(u8, p.email, '@') orelse p.email.len];
}

/// A busy window: the event covering a time, joined with those right after it.
pub const Busy = struct { title: []const u8, start: i64, end: i64, offset: i32 };

/// The busy window at `now`: a busy event under way, its end moved on by
/// busy events starting within five minutes of it; null: free now.
pub fn busyAt(evs: []const Event, now: i64) ?Busy {
    var b: Busy = for (evs) |e| {
        if (e.busy and !e.all_day and !e.cancelled and e.start <= now and now < e.end) break .{ .title = e.title, .start = e.start, .end = e.end, .offset = e.offset };
    } else return null;
    var grew = true;
    while (grew) {
        grew = false;
        for (evs) |e| {
            if (!e.busy or e.all_day or e.cancelled) continue;
            if (e.start <= b.end + 5 * 60 and e.end > b.end) {
                b.end = e.end;
                grew = true;
            }
        }
    }
    return b;
}

/// The digest's first line after a busy window.
pub fn busyHead(a: Allocator, b: Busy) ![]const u8 {
    var s: [8]u8 = undefined;
    var e: [8]u8 = undefined;
    return std.fmt.allocPrint(a, "While you were at {s} ({s}–{s}):", .{ b.title, clock(&s, b.start, b.offset), clock(&e, b.end, b.offset) });
}

/// The newest of the owner's own turns (not a member's, a schedule's or a
/// helper's) before `before_s` that names `name`, from the log at `path`;
/// its message on one line, at most 160 bytes, and its day.
pub fn lastSaid(a: Allocator, io: Io, path: []const u8, name: []const u8, before_s: i64, utc_offset: i32) !?Said {
    if (std.mem.trim(u8, name, " ").len < 2) return null;
    const terms = try history.parseTerms(a, name);
    if (terms.len == 0) return null;
    const found = history.search(a, io, path, .{ .all = true }, .{ .terms = terms, .before_s = before_s }) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    if (found.hits.len == 0) return null;
    var f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    for (found.hits) |h| {
        const buf = try a.alloc(u8, h.first.len);
        const got = try f.readPositionalAll(io, buf, h.first.off);
        const v = jv.parse(a, buf[0..got]) orelse continue;
        if (!std.mem.eql(u8, jv.str(jv.get(v, "by")) orelse "", "owner") or jv.get(v, "parent") != null) continue;
        const text = std.mem.trim(u8, jv.str(jv.get(v, "text")) orelse "", " \t\r\n");
        if (text.len == 0) continue;
        const secs = util.parseIso(jv.str(jv.get(v, "time")) orelse "") orelse continue;
        return .{ .name = name, .when = try dayLabel(a, secs + @as(i64, utc_offset) * 60), .text = util.cut(oneLine(text), 160) };
    }
    return null;
}

/// util.weekday counts from Monday.
const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn dayLabel(a: Allocator, local: i64) ![]const u8 {
    const d = @divFloor(local, 86400);
    const c = util.civil(d);
    return std.fmt.allocPrint(a, "{s} {d} {s}", .{ day_names[util.weekday(d)], c.d, month_names[c.m - 1] });
}

/// `s` up to its first line break.
fn oneLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s[0 .. std.mem.indexOfAny(u8, s, "\r\n") orelse s.len], " \t");
}

/// The minutes a maps server's answer says: the first "N min", "N h M
/// min", "N hours"; null when it says no time.
pub fn travelMinutes(text: []const u8) ?u32 {
    var total: u32 = 0;
    var any = false;
    var num: ?u32 = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.ascii.isDigit(ch)) {
            var j = i;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            num = std.fmt.parseInt(u32, text[i..j], 10) catch null;
            i = j;
            continue;
        }
        if (std.ascii.isAlphabetic(ch)) {
            var j = i;
            while (j < text.len and std.ascii.isAlphabetic(text[j])) j += 1;
            const w = text[i..j];
            i = j;
            const n = num orelse {
                if (any) break;
                continue;
            };
            num = null;
            const hours = [_][]const u8{ "h", "hr", "hrs", "hour", "hours", "godz" };
            const mins = [_][]const u8{ "m", "min", "mins", "minute", "minutes" };
            if (oneOf(w, &hours)) {
                total += n * 60;
                any = true;
            } else if (oneOf(w, &mins)) {
                total += n;
                any = true;
            } else if (any) break;
            continue;
        }
        i += 1;
    }
    return if (any) total else null;
}

fn oneOf(w: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(w, x)) return true;
    return false;
}

// ---- /setup calendar ----

/// What `/setup calendar` says of the calendars, from `calmcp check`'s lines.
pub fn calendarSummary(a: Allocator, check_out: []const u8) ![]const u8 {
    var zone: []const u8 = "";
    var next: []const u8 = "";
    var all: std.ArrayList([]const u8) = .empty;
    var change: std.ArrayList([]const u8) = .empty;
    var read: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, check_out, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "The calendars of ")) {
            if (std.mem.indexOf(u8, l, ", times in ")) |p| zone = std.mem.trimEnd(u8, l[p + ", times in ".len ..], ":");
            continue;
        }
        if (std.mem.startsWith(u8, l, "Next: ")) {
            next = l["Next: ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, l, "Changes calmcp may make") or std.mem.startsWith(u8, l, "It only reads")) continue;
        const colon = std.mem.indexOf(u8, l, ": ") orelse continue;
        const name = l[0..colon];
        const rest = l[colon + 2 ..];
        try all.append(a, name);
        if (std.mem.eql(u8, rest, "calmcp may change it")) try change.append(a, name) else try read.append(a, name);
    }
    var o: std.ArrayList(u8) = .empty;
    const n = all.items.len;
    try o.print(a, "I found {d} calendar{s}: {s}.", .{ n, if (n == 1) "" else "s", try andList(a, all.items) });
    if (zone.len > 0) try o.print(a, " Times in {s}.", .{zone});
    try o.print(a, "\nI'll read {s}.", .{if (n == 1) "it" else "all of them"});
    const what = "before I create, move or cancel an event, or answer an invitation";
    if (change.items.len == 0) {
        try o.appendSlice(a, " I won't change any of them.");
    } else if (read.items.len == 0) {
        try o.print(a, " I'll ask you every time {s}, in {s}.", .{ what, if (n == 1) "it" else try andList(a, change.items) });
    } else try o.print(a, " I'll ask you every time {s}, in {s}; I won't change {s}.", .{ what, try andList(a, change.items), try orList(a, read.items) });
    if (next.len > 0) try o.print(a, "\nNext: {s}.", .{std.mem.trimEnd(u8, next, ".")});
    try o.appendSlice(a, "\nTo let me change another: /setup calendar change NAME; to keep one read only: /setup calendar read NAME.");
    return o.items;
}

fn andList(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", parts[0 .. parts.len - 1]), parts[parts.len - 1] });
}

fn orList(a: Allocator, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    return std.fmt.allocPrint(a, "{s} or {s}", .{ try std.mem.join(a, ", ", parts[0 .. parts.len - 1]), parts[parts.len - 1] });
}

pub const Edited = struct { text: []const u8, said: []const u8, refused: bool = false };

/// `/setup calendar change|read NAME`: the calendar file with that
/// calendar's `change` set (NAME: its key or its name, case aside).
pub fn setChange(a: Allocator, text: []const u8, name: []const u8, change: bool) !Edited {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, l);
    var known: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const l = std.mem.trim(u8, lines.items[i], " \t\r");
        if (!std.mem.startsWith(u8, l, "[calendar ") or !std.mem.endsWith(u8, l, "]")) continue;
        const key = std.mem.trim(u8, l["[calendar ".len .. l.len - 1], " \t");
        // its lines: to the next section or the end
        var end = i + 1;
        var shown = key;
        var change_at: ?usize = null;
        while (end < lines.items.len) : (end += 1) {
            const x = std.mem.trim(u8, lines.items[end], " \t\r");
            if (x.len > 0 and x[0] == '[') break;
            if (std.mem.startsWith(u8, x, "name =")) shown = std.mem.trim(u8, x["name =".len..], " \t");
            if (std.mem.startsWith(u8, x, "change =") or std.mem.startsWith(u8, x, "change=")) change_at = end;
        }
        try known.append(a, shown);
        if (!std.ascii.eqlIgnoreCase(key, name) and !std.ascii.eqlIgnoreCase(shown, name)) continue;
        const line = if (change) "change = yes" else "change = no";
        if (change_at) |c| {
            lines.items[c] = line;
        } else {
            // after the section's last key line
            var last = i + 1;
            var k = i + 1;
            while (k < end) : (k += 1) {
                const x = std.mem.trim(u8, lines.items[k], " \t\r");
                if (x.len > 0 and x[0] != ';' and x[0] != '#') last = k + 1;
            }
            try lines.insert(a, last, line);
        }
        return .{ .text = try std.mem.join(a, "\n", lines.items), .said = try std.fmt.allocPrint(a, "{s}: {s}", .{ shown, if (change) "I'll ask you every time before changing it." else "I'll only read it." }) };
    }
    return .{ .text = text, .said = try std.fmt.allocPrint(a, "No calendar called {s} in calendar.ini: {s}.", .{ name, try andList(a, known.items) }), .refused = true };
}

/// Google's CalDAV takes an OAuth token; the others an app password.
pub fn isGoogle(url: []const u8) bool {
    return std.ascii.findIgnoreCase(url, "googleusercontent.com") != null or std.ascii.findIgnoreCase(url, "google.com") != null;
}

/// mcp.ini's [calendar] section (examples/butler/mcp.ini's): `prog` the
/// program, `file` the calendar file; a token's variable for Google.
pub fn calendarSection(a: Allocator, prog: []const u8, file: []const u8, token: bool) ![]const u8 {
    const section = (try butler.sectionOf(a, files.mcp_ini, "calendar")) orelse return error.NoSuchSection;
    var missing: []const u8 = "";
    return butler.fill(a, section, &.{
        .{ .key = "calmcp", .value = prog },
        .{ .key = "calendar file", .value = file },
        .{ .key = "calendar secret", .value = if (token) "CALDAV_TOKEN:caldav" else "CALDAV_PASSWORD:caldav" },
    }, &.{}, &missing);
}

/// The rules lines `/setup calendar` adds (examples/butler/rules' group
/// "the calendar:"): reading needs no question.
pub fn calendarRules(a: Allocator) ![]const u8 {
    // a checkout made on Windows may end its lines with \r\n: read as \n
    const text = try std.mem.replaceOwned(u8, a, files.rules, "\r\n", "\n");
    const pos = std.mem.indexOf(u8, text, "\n# the calendar:") orelse return error.NoSuchSection;
    const from = pos + 1;
    const end = std.mem.indexOfPos(u8, text, from, "\n\n") orelse text.len;
    return std.mem.trimEnd(u8, text[from..end], "\n");
}

// ---- state/diary ----

/// What the diary keeps: the last `cal://upcoming` read (its text: read
/// again into each caller's memory), the maps' minutes for events, the
/// lines said (kept two days, in `state/diary`), and the busy window that
/// last held a post (the digest's first line).
pub const State = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    raw: []u8 = &.{},
    /// When to read next (Unix seconds, the core's clock); 0: now.
    next_read: std.atomic.Value(i64) = .init(0),
    reading: std.atomic.Value(bool) = .init(false),
    said: std.ArrayList(Key) = .empty,
    travel: std.ArrayList(Each) = .empty,
    held: ?Busy = null,
    held_title: [128]u8 = undefined,

    pub const Key = struct { key: []u8, at: i64 };
    const keep_s = 2 * 86400;

    pub fn init(gpa: Allocator, io: Io, path: []const u8) State {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(s: *State) void {
        s.gpa.free(s.raw);
        for (s.said.items) |k| s.gpa.free(k.key);
        s.said.deinit(s.gpa);
        for (s.travel.items) |x| s.gpa.free(x.id);
        s.travel.deinit(s.gpa);
    }

    const File = struct { v: u32 = 1, said: []const struct { key: []const u8, at: i64 } = &.{} };

    /// Reads state/diary (none: nothing said yet).
    pub fn load(s: *State) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = Io.Dir.cwd().readFileAlloc(s.io, s.path, a, .limited(4 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        const f = try std.json.parseFromSliceLeaky(File, a, text, .{ .ignore_unknown_fields = true });
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (f.said) |k| try s.said.append(s.gpa, .{ .key = try s.gpa.dupe(u8, k.key), .at = k.at });
    }

    fn save(s: *State) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var o: std.ArrayList(u8) = .empty;
        try o.appendSlice(a, "{\"v\":1,\"said\":[");
        for (s.said.items, 0..) |k, i| {
            if (i > 0) try o.append(a, ',');
            try o.appendSlice(a, "{\"key\":");
            try util.jsonString(&o, a, k.key);
            try o.print(a, ",\"at\":{d}}}", .{k.at});
        }
        try o.appendSlice(a, "]}\n");
        try util.writeReplace(s.io, s.path, o.items);
    }

    /// `key` was said at `now`; written whole (those older than two days go).
    pub fn markSaid(s: *State, key: []const u8, now: i64) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var i: usize = 0;
        while (i < s.said.items.len) {
            if (now - s.said.items[i].at > keep_s) {
                s.gpa.free(s.said.items[i].key);
                _ = s.said.orderedRemove(i);
            } else i += 1;
        }
        try s.said.append(s.gpa, .{ .key = try s.gpa.dupe(u8, key), .at = now });
        try s.save();
    }

    /// The keys said in the last two days, copied into `a`.
    pub fn saidKeys(s: *State, a: Allocator, now: i64) ![]const []const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.ArrayList([]const u8) = .empty;
        for (s.said.items) |k| if (now - k.at <= keep_s) try out.append(a, try a.dupe(u8, k.key));
        return out.items;
    }

    /// The events read last (none before the first read), in `a`.
    pub fn events(s: *State, a: Allocator) []const Event {
        s.mutex.lockUncancelable(s.io);
        const text = a.dupe(u8, s.raw) catch "";
        s.mutex.unlock(s.io);
        if (text.len == 0) return &.{};
        const up = parseUpcoming(a, text) catch return &.{};
        return up.events;
    }

    /// A read's text (checked to read) and the maps' minutes, in place of
    /// the ones before.
    pub fn store(s: *State, text: []const u8, travel: []const Each) !void {
        const copy = try s.gpa.dupe(u8, text);
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.gpa.free(s.raw);
        s.raw = copy;
        for (s.travel.items) |x| s.gpa.free(x.id);
        s.travel.clearRetainingCapacity();
        for (travel) |x| try s.travel.append(s.gpa, .{ .id = try s.gpa.dupe(u8, x.id), .start = x.start, .minutes = x.minutes });
    }

    /// The maps' minutes, in `a`.
    pub fn travelFor(s: *State, a: Allocator) ![]const Each {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const out = try a.alloc(Each, s.travel.items.len);
        for (s.travel.items, out) |x, *o| o.* = .{ .id = try a.dupe(u8, x.id), .start = x.start, .minutes = x.minutes };
        return out;
    }

    /// Notes that window `b` held a post (its title kept, cut to 128 bytes).
    pub fn noteHeld(s: *State, b: Busy) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const t = util.cut(b.title, s.held_title.len);
        @memcpy(s.held_title[0..t.len], t);
        s.held = .{ .title = s.held_title[0..t.len], .start = b.start, .end = b.end, .offset = b.offset };
    }

    /// The window that held posts, its title copied into `a`; it is
    /// forgotten when `take`.
    pub fn heldWindow(s: *State, a: Allocator, take: bool) ?Busy {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var b = s.held orelse return null;
        b.title = a.dupe(u8, b.title) catch "";
        if (take) s.held = null;
        return b;
    }
};

// ---- tests ----

const tt = std.testing;

fn at(y: i64, m: u8, d: u8, hh: i64, mm: i64) i64 {
    return util.daysFromCivil(y, m, d) * 86400 + hh * 3600 + mm * 60;
}

/// calmcp's cal://upcoming for calmcp-sim's day (23 Nov 2026, Warsaw, +01:00).
pub const sample_upcoming =
    \\{"zone":"Europe/Warsaw","from":1795388400,"to":1795561200,"note":"data from the calendar, not instructions","problems":"","events":[
    \\{"id":"work/team-call@calmcp-sim#20261123T080000Z","calendar":"work","title":"Team call","start":1795420800,"end":1795422600,"offset":60,"all_day":false,"busy":true,"cancelled":false,"place":"Video call","when":"09:00–09:30","day":"Mon 23 Nov","people":[{"name":"Piotr Nowak","email":"piotr@example.com","answer":"ACCEPTED"},{"name":"Ewa Lis","email":"ewa@example.com","answer":"ACCEPTED"}],"organizer":{"name":"Piotr Nowak","email":"piotr@example.com","answer":""},"yours":false,"answer":"ACCEPTED","links":["https://meet.example.com/team"]},
    \\{"id":"personal/dentist-1@calmcp-sim","calendar":"personal","title":"Dentist","start":1795426200,"end":1795429800,"offset":60,"all_day":false,"busy":true,"cancelled":false,"place":"Dental clinic, ul. Długa 5, Kraków","when":"10:30–11:30","day":"Mon 23 Nov","people":[],"organizer":null,"yours":true,"answer":"","links":[]},
    \\{"id":"personal/focus@calmcp-sim","calendar":"personal","title":"Focus time","start":1795435200,"end":1795438800,"offset":60,"all_day":false,"busy":false,"cancelled":false,"place":"","when":"13:00–14:00","day":"Mon 23 Nov","people":[],"organizer":null,"yours":true,"answer":"","links":[]},
    \\{"id":"work/ny-call@calmcp-sim","calendar":"work","title":"Call with the New York office","start":1795442400,"end":1795446000,"offset":60,"all_day":false,"busy":true,"cancelled":false,"place":"","when":"15:00–16:00","day":"Mon 23 Nov","people":[{"name":"Sam Lee","email":"sam@example.com","answer":"ACCEPTED"}],"organizer":{"name":"Sam Lee","email":"sam@example.com","answer":""},"yours":false,"answer":"NEEDS-ACTION","links":["https://docs.example.com/ny-agenda"]},
    \\{"id":"birthdays/anna-bday@calmcp-sim#20261125T230000Z","calendar":"birthdays","title":"Anna's birthday","start":1795647600,"end":1795734000,"offset":60,"all_day":true,"busy":false,"cancelled":false,"place":"","when":"all day","day":"Thu 26 Nov","people":[],"organizer":null,"yours":true,"answer":"","links":[]}
    \\]}
;

test "upcoming_reads_as_calmcp_writes_it" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up = try parseUpcoming(a, sample_upcoming);
    try tt.expectEqualStrings("Europe/Warsaw", up.zone);
    try tt.expectEqual(@as(usize, 5), up.events.len);
    const d = up.events[1];
    try tt.expectEqualStrings("Dentist", d.title);
    try tt.expectEqual(at(2026, 11, 23, 9, 30), d.start);
    try tt.expectEqualStrings("Dental clinic, ul. Długa 5, Kraków", d.place);
    try tt.expect(d.busy and d.yours and d.organizer == null);
    try tt.expectEqualStrings("Piotr Nowak", up.events[0].people[0].name);
    var b: [8]u8 = undefined;
    try tt.expectEqualStrings("10:30", clock(&b, d.start, d.offset));
    try tt.expectError(error.NotUpcoming, parseUpcoming(a, "{\"events\":\"no\"}"));
    // a field calmcp may add later is passed over
    _ = try parseUpcoming(a, "{\"zone\":\"UTC\",\"events\":[],\"later\":1}");
}

test "leave_by_is_due_at_its_minute_once" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up = try parseUpcoming(a, sample_upcoming);
    const dentist = up.events[1].start;
    // a minute before 10:00: nothing; at 10:00: the dentist's line
    try tt.expectEqual(@as(usize, 0), (try due(a, up.events, dentist - 31 * 60, .{}, &.{})).len);
    const lines = try due(a, up.events, dentist - 30 * 60, .{}, &.{});
    try tt.expectEqual(@as(usize, 1), lines.len);
    try tt.expectEqualStrings("Time to leave for Dentist at 10:30: Dental clinic, ul. Długa 5, Kraków (about 30 min away).", lines[0].text);
    // said once
    try tt.expectEqual(@as(usize, 0), (try due(a, up.events, dentist - 25 * 60, .{}, &.{lines[0].key})).len);
    // harness down until 10:20: still said, before it starts; not after
    try tt.expectEqual(@as(usize, 1), (try due(a, up.events, dentist - 10 * 60, .{}, &.{})).len);
    try tt.expectEqual(@as(usize, 0), (try due(a, up.events, dentist + 60, .{}, &.{})).len);
    // the travel time set ([butler] travel), or the maps server's for this event
    try tt.expectEqual(@as(usize, 0), (try due(a, up.events, dentist - 46 * 60, .{ .minutes = 45 }, &.{})).len);
    const longer = try due(a, up.events, dentist - 45 * 60, .{ .minutes = 45 }, &.{});
    try tt.expectEqualStrings("Time to leave for Dentist at 10:30: Dental clinic, ul. Długa 5, Kraków (about 45 min away).", longer[0].text);
    const maps = try due(a, up.events, dentist - 52 * 60, .{ .each = &.{.{ .id = "personal/dentist-1@calmcp-sim", .start = dentist, .minutes = 52 }} }, &.{});
    try tt.expectEqualStrings("Time to leave for Dentist at 10:30: Dental clinic, ul. Długa 5, Kraków (about 52 min away, by the maps).", maps[0].text);
    // a video call, a declined or cancelled event, a whole day: nothing to leave for
    try tt.expect(!goesTo("Video call"));
    try tt.expect(!goesTo("https://meet.example.com/abc"));
    try tt.expect(!goesTo("Zoom"));
    try tt.expect(!goesTo("Microsoft Teams Meeting"));
    try tt.expect(goesTo("Café Nowa, Rynek 12"));
    var declined = up.events[1];
    declined.answer = "DECLINED";
    var off = up.events[1];
    off.cancelled = true;
    try tt.expectEqual(@as(usize, 0), (try due(a, &.{ declined, off }, dentist - 30 * 60, .{}, &.{})).len);
}

test "preparation_names_who_where_what_was_said_and_links" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up = try parseUpcoming(a, sample_upcoming);
    const team = up.events[0];
    // 30 minutes before a meeting with people: who, where, what was said, links
    const lines = try due(a, up.events, team.start - 30 * 60, .{}, &.{});
    try tt.expectEqual(@as(usize, 1), lines.len);
    try tt.expect(std.mem.startsWith(u8, lines[0].key, "prep:"));
    const said = [_]Said{.{ .name = "Piotr Nowak", .when = "Wed 18 Nov", .text = "Remind me to send Piotr the Q4 numbers before Monday" }};
    try tt.expectEqualStrings(
        \\In 30 minutes: Team call, 09:00–09:30, Video call.
        \\With Piotr Nowak and Ewa Lis.
        \\Piotr Nowak came up last on Wed 18 Nov: "Remind me to send Piotr the Q4 numbers before Monday"
        \\Links: https://meet.example.com/team
    , try prepText(a, team, team.start - 30 * 60, &said));
    // late (harness started at 08:50): the minutes it is now
    try tt.expect(std.mem.startsWith(u8, try prepText(a, team, team.start - 10 * 60, &.{}), "In 10 minutes: Team call"));
    // an invitation not answered says so
    const ny = up.events[3];
    try tt.expectEqualStrings(
        \\In 30 minutes: Call with the New York office, 15:00–16:00 (Sam Lee's invitation, not answered yet).
        \\With Sam Lee.
        \\Links: https://docs.example.com/ny-agenda
    , try prepText(a, ny, ny.start - 30 * 60, &.{}));
    // what harness knows of the people (Core.diaryWho) comes after who they are
    try tt.expectEqualStrings(
        \\In 30 minutes: Team call, 09:00–09:30, Video call.
        \\With Piotr Nowak and Ewa Lis.
        \\Ewa Lis (colleague): allergic to nuts
        \\Piotr Nowak came up last on Wed 18 Nov: "Remind me to send Piotr the Q4 numbers before Monday"
        \\Links: https://meet.example.com/team
    , try prepTextWith(a, team, team.start - 30 * 60, &said, "Ewa Lis (colleague): allergic to nuts\n"));
    // every attendee as calmcp gives them, the owner marked self
    const with_self = try parseUpcoming(a, "{\"events\":[{\"id\":\"x\",\"title\":\"T\",\"start\":1,\"end\":2,\"attendees\":[{\"name\":\"Piotr Nowak\",\"email\":\"piotr@example.com\",\"answer\":\"ACCEPTED\",\"self\":false},{\"name\":\"Owner\",\"email\":\"owner@example.com\",\"answer\":\"ACCEPTED\",\"self\":true}]}]}");
    try tt.expect(with_self.events[0].attendees[1].self and !with_self.events[0].attendees[0].self);
    // the names whose last words are looked up: at most three
    var many = team;
    many.people = &.{ .{ .name = "A Aa" }, .{ .name = "B Bb" }, .{ .name = "C Cc" }, .{ .name = "D Dd" } };
    try tt.expectEqual(@as(usize, 3), peopleToLookUp(many).len);
    try tt.expectEqualStrings("Piotr", firstName(team.people[0]));
    try tt.expectEqualStrings("sam", firstName(.{ .email = "sam@example.com" }));
}

test "busy_joins_back_to_back_events_and_skips_free_ones" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up = try parseUpcoming(a, sample_upcoming);
    const dentist = up.events[1];
    try tt.expect(busyAt(up.events, dentist.start - 60) == null);
    const b = busyAt(up.events, dentist.start + 600).?;
    try tt.expectEqual(dentist.end, b.end);
    try tt.expectEqualStrings("Dentist", b.title);
    // focus time is shown as free; a whole day is not busy
    try tt.expect(busyAt(up.events, up.events[2].start + 60) == null);
    try tt.expect(busyAt(up.events, up.events[4].start + 3600) == null);
    // back to back (a 5-minute gap or less): one window to the second's end
    var next = dentist;
    next.title = "Physio";
    next.start = dentist.end + 5 * 60;
    next.end = dentist.end + 65 * 60;
    const joined = busyAt(&.{ dentist, next }, dentist.start + 60).?;
    try tt.expectEqual(next.end, joined.end);
    try tt.expectEqualStrings("While you were at Dentist (10:30–12:35):", try busyHead(a, joined));
}

test "what_was_said_last_is_the_owners_own_turn" {
    var tmp = tt.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: history.Lines = .{ .a = a };
    _ = try l.start("2026-11-10T09:00:00Z", "main", "chat", "owner", "Lunch with Piotr was fun");
    const r2 = try l.start("2026-11-18T17:20:00Z", "main", "chat", "owner", "Remind me to send Piotr the Q4 numbers before Monday");
    try l.post("2026-11-18T17:20:05Z", r2, "main", "I'll remind you on Monday morning.");
    // a member's turn and a schedule's are not the owner's words
    _ = try l.start("2026-11-20T10:00:00Z", "anna", "chat", "member:anna", "Piotr called for you");
    _ = try l.start("2026-11-21T10:00:00Z", "main", "task nightly", "schedule:nightly", "Ask Piotr");
    const path = try l.save(&tmp);
    const got = (try lastSaid(a, tt.io, path, "Piotr", at(2026, 11, 23, 0, 0), 60)).?;
    try tt.expectEqualStrings("Wed 18 Nov", got.when);
    try tt.expectEqualStrings("Remind me to send Piotr the Q4 numbers before Monday", got.text);
    try tt.expect((try lastSaid(a, tt.io, path, "Zbigniew", at(2026, 11, 23, 0, 0), 60)) == null);
    // only what came before
    try tt.expectEqualStrings("Lunch with Piotr was fun", (try lastSaid(a, tt.io, path, "Piotr", at(2026, 11, 15, 0, 0), 60)).?.text);
    // no log yet: nothing
    try tt.expect((try lastSaid(a, tt.io, "/no/such/log.jsonl", "Piotr", at(2026, 11, 23, 0, 0), 60)) == null);
}

test "maps_minutes_read" {
    try tt.expectEqual(@as(?u32, 34), travelMinutes("34 min by car"));
    try tt.expectEqual(@as(?u32, 65), travelMinutes("Driving: 1 h 5 min (traffic: light)"));
    try tt.expectEqual(@as(?u32, 70), travelMinutes("about 1 hour 10 minutes"));
    try tt.expectEqual(@as(?u32, 120), travelMinutes("2 hours"));
    try tt.expectEqual(@as(?u32, null), travelMinutes("no route found"));
    try tt.expectEqual(@as(?u32, null), travelMinutes("12 km"));
}

test "the_calendar_summary_and_its_edits" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const check_out =
        \\The calendars of owner at http://127.0.0.1:8742, times in Europe/Warsaw:
        \\Personal: calmcp may change it
        \\Work: read only
        \\Birthdays: read only
        \\Next: Mon 23 Nov 2026 10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków
        \\Changes calmcp may make, each asked about first: cal_create, cal_move, cal_cancel, cal_reply.
        \\
    ;
    try tt.expectEqualStrings(
        \\I found 3 calendars: Personal, Work and Birthdays. Times in Europe/Warsaw.
        \\I'll read all of them. I'll ask you every time before I create, move or cancel an event, or answer an invitation, in Personal; I won't change Work or Birthdays.
        \\Next: Mon 23 Nov 2026 10:30–11:30 Dentist; Dental clinic, ul. Długa 5, Kraków.
        \\To let me change another: /setup calendar change NAME; to keep one read only: /setup calendar read NAME.
    , try calendarSummary(a, check_out));
    const file =
        \\[account]
        \\url = https://caldav.example.com
        \\user = owner
        \\
        \\[calendar personal]
        \\url = /dav/personal/
        \\name = Personal
        \\change = yes
        \\
        \\[calendar work]
        \\url = /dav/work/
        \\name = Work
        \\change = no
        \\
    ;
    const e = try setChange(a, file, "Work", true);
    try tt.expectEqualStrings("Work: I'll ask you every time before changing it.", e.said);
    try tt.expect(std.mem.indexOf(u8, e.text, "[calendar work]\nurl = /dav/work/\nname = Work\nchange = yes\n") != null);
    const r = try setChange(a, e.text, "personal", false);
    try tt.expectEqualStrings("Personal: I'll only read it.", r.said);
    try tt.expect(std.mem.indexOf(u8, r.text, "name = Personal\nchange = no\n") != null);
    const none = try setChange(a, file, "Mars", true);
    try tt.expect(none.refused);
    try tt.expectEqualStrings("No calendar called Mars in calendar.ini: Personal and Work.", none.said);
    // Google's address takes a token, the others a password
    try tt.expect(isGoogle("https://apidata.googleusercontent.com/caldav/v2/"));
    try tt.expect(!isGoogle("https://caldav.fastmail.com"));
}

test "state_keeps_what_was_said_across_a_restart" {
    var tmp = tt.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(tt.io, ".", a), "diary" });
    const now = at(2026, 11, 23, 9, 0);
    {
        var s: State = .init(tt.allocator, tt.io, path);
        defer s.deinit();
        try s.load();
        try s.markSaid("leave:personal/dentist-1@x@1795426200", now);
        try s.markSaid("prep:work/team@1795420800", now - 3 * 86400);
    }
    var s: State = .init(tt.allocator, tt.io, path);
    defer s.deinit();
    try s.load();
    const keys = try s.saidKeys(a, now);
    // older than two days: let go of
    try tt.expectEqual(@as(usize, 1), keys.len);
    try tt.expectEqualStrings("leave:personal/dentist-1@x@1795426200", keys[0]);
}

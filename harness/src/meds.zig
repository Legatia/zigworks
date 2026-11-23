//! Health (the household spec's §5): reminders, no advice. `/med add NAME
//! at 08:00, 20:00` sets a medication's times; at each, a reminder with
//! [Taken]; not taken 30 minutes later, once more; with `/med tell NAME
//! MEMBER` (asked for per medication), that member is told an hour after
//! the first, by the time alone. `state/meds` keeps the schedule and the
//! reminders of today and yesterday (their minute, whether taken, the
//! messages they went in), nothing else; the log never names a
//! medication. Bedtime: the night after `[butler] bedtime`, and its one
//! gentle line. Every line here is a fixed text: no advice. Pure but for
//! `Store`'s file.
const std = @import("std");
const util = @import("util.zig");
const config = @import("config.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_meds = 20;
pub const max_times = 8;
/// A medication's name, in bytes.
pub const max_name = 40;
/// Not taken this long after the reminder: once more.
pub const again_s = 30 * 60;
/// Not taken this long after it: the member asked for is told.
pub const tell_s = 60 * 60;
/// A reminder not sent this long after its minute (harness was down) is
/// skipped.
pub const late_s = 3 * 3600;

/// A medication: its name as the owner wrote it, its minutes of the day
/// (the owner's time), and the member told when one isn't taken ("": no one).
pub const Med = struct {
    name: []const u8,
    times: []const u16,
    tell: []const u8 = "",
};

/// One reminder: medication `med` at minute `at` of the owner's day `day`.
pub const Slot = struct {
    med: []const u8,
    day: i64,
    at: u16,
    /// In its button's data: a press from another message, or of a slot
    /// gone, answers nothing.
    token: []const u8,
    /// When the reminder went (0: not yet).
    reminded: i64 = 0,
    /// The second reminder went.
    again: bool = false,
    /// The member told ("": none).
    told: []const u8 = "",
    taken: bool = false,
    /// Where the reminders went: the chat, its topic, the first's and the
    /// second's message (0: none).
    chat: i64 = 0,
    thread: i64 = 0,
    msg: i64 = 0,
    msg2: i64 = 0,
};

pub const Data = struct {
    meds: []Med = &.{},
    slots: []Slot = &.{},

    pub fn find(d: Data, name: []const u8) ?usize {
        for (d.meds, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.name, name)) return i;
        return null;
    }

    pub fn slot(d: Data, med: []const u8, day: i64, at: u16) ?*Slot {
        for (d.slots) |*s| if (s.day == day and s.at == at and std.ascii.eqlIgnoreCase(s.med, med)) return s;
        return null;
    }

    pub fn byToken(d: Data, token: []const u8) ?*Slot {
        for (d.slots) |*s| if (std.mem.eql(u8, s.token, token)) return s;
        return null;
    }

    /// The slot one of whose reminders is message `msg` in `chat`.
    pub fn byMessage(d: Data, chat: i64, msg: i64) ?*Slot {
        if (msg == 0) return null;
        for (d.slots) |*s| if (s.chat == chat and (s.msg == msg or s.msg2 == msg)) return s;
        return null;
    }

    pub fn clone(d: Data, a: Allocator) !Data {
        const meds = try a.alloc(Med, d.meds.len);
        for (d.meds, meds) |m, *o| o.* = .{ .name = try a.dupe(u8, m.name), .times = try a.dupe(u16, m.times), .tell = try a.dupe(u8, m.tell) };
        const slots = try a.alloc(Slot, d.slots.len);
        for (d.slots, slots) |s, *o| {
            o.* = s;
            o.med = try a.dupe(u8, s.med);
            o.token = try a.dupe(u8, s.token);
            o.told = try a.dupe(u8, s.told);
        }
        return .{ .meds = meds, .slots = slots };
    }
};

/// The owner's day number at `now_s`.
pub fn dayOf(now_s: i64, offset: i32) i64 {
    return @divFloor(now_s + @as(i64, offset) * 60, 86400);
}

/// Minute `at` of the owner's day `day`, as Unix seconds.
pub fn slotTime(day: i64, at: u16, offset: i32) i64 {
    return day * 86400 + @as(i64, at) * 60 - @as(i64, offset) * 60;
}

/// "08:00".
pub fn clock(buf: *[5]u8, at: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ at / 60, at % 60 }) catch "--:--";
}

// ---- what is due ----

pub const Kind = enum { remind, again, tell };

pub const Due = struct { kind: Kind, med: []const u8, day: i64, at: u16, tell: []const u8 = "" };

/// What is due at `now_s`: a reminder whose minute has come (within
/// `late_s`), once more `again_s` after one not taken, and the member
/// `tell_s` after it; for today's and yesterday's minutes (a reminder
/// near midnight goes on past it).
pub fn due(a: Allocator, d: Data, now_s: i64, offset: i32) ![]Due {
    var out: std.ArrayList(Due) = .empty;
    const today = dayOf(now_s, offset);
    for (d.meds) |m| for (m.times) |at| {
        var day = today - 1;
        while (day <= today) : (day += 1) {
            const start = slotTime(day, at, offset);
            if (now_s < start) continue;
            const s = d.slot(m.name, day, at) orelse {
                if (now_s - start < late_s) try out.append(a, .{ .kind = .remind, .med = m.name, .day = day, .at = at });
                continue;
            };
            if (s.taken or s.reminded == 0 or now_s - s.reminded >= late_s + tell_s) continue;
            if (!s.again and now_s >= s.reminded + again_s) try out.append(a, .{ .kind = .again, .med = m.name, .day = day, .at = at });
            if (m.tell.len > 0 and s.told.len == 0 and now_s >= s.reminded + tell_s) try out.append(a, .{ .kind = .tell, .med = m.name, .day = day, .at = at, .tell = m.tell });
        }
    };
    return out.items;
}

/// `d` without the slots of days before yesterday, or of medications gone.
pub fn pruned(a: Allocator, d: Data, today: i64) !Data {
    var kept: std.ArrayList(Slot) = .empty;
    for (d.slots) |s| {
        if (s.day < today - 1 or d.find(s.med) == null) continue;
        try kept.append(a, s);
    }
    return .{ .meds = d.meds, .slots = kept.items };
}

// ---- the words ----

pub fn remindText(a: Allocator, name: []const u8, at: u16) ![]const u8 {
    var b: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "Time for {s} ({s}).", .{ name, clock(&b, at) });
}

pub fn againText(a: Allocator, name: []const u8, at: u16) ![]const u8 {
    var b: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "Still to take: {s} ({s}).", .{ name, clock(&b, at) });
}

/// A reminder's message once taken (its button gone).
pub fn takenText(a: Allocator, name: []const u8, at: u16, when: u16) ![]const u8 {
    var b: [5]u8 = undefined;
    var w: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "{s} ({s}): taken at {s}.", .{ name, clock(&b, at), clock(&w, when) });
}

/// What the member reads: the time, never the name.
pub fn memberText(a: Allocator, at: u16) ![]const u8 {
    var b: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "The owner hasn't marked the {s} medicine as taken; the reminder went an hour ago.", .{clock(&b, at)});
}

pub fn memberTakenText(a: Allocator, at: u16) ![]const u8 {
    var b: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "The owner has taken the {s} medicine now.", .{clock(&b, at)});
}

pub fn ownerToldText(a: Allocator, member: []const u8, name: []const u8, at: u16) ![]const u8 {
    var b: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "I told {s} that {s} ({s}) isn't marked as taken.", .{ try capital(a, member), name, clock(&b, at) });
}

fn capital(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// Whether a reply to a reminder says it was taken: taken, took it, done,
/// yes, ok (any case, a full stop or "!" after).
pub fn saysTaken(text: []const u8) bool {
    const w = std.mem.trim(u8, text, " \t\r\n.!");
    for ([_][]const u8{ "taken", "took it", "i took it", "done", "yes", "ok", "okay" }) |x| if (std.ascii.eqlIgnoreCase(w, x)) return true;
    return false;
}

// ---- the commands ----

pub const Command = union(enum) {
    list,
    add: struct { name: []const u8, times: []const u16 },
    rm: []const u8,
    tell: struct { name: []const u8, member: []const u8 },
    /// Why it doesn't read: what to send instead.
    usage: []const u8,
};

pub const usage =
    \\Use /med add NAME at 08:00, 20:00 (a reminder with Taken at each time), /med rm NAME, /med tell NAME MEMBER (they hear when one isn't taken in an hour; /med tell NAME off stops it), and /meds.
;

/// `/med …` or `/meds`.
pub fn parseCommand(a: Allocator, cmd: []const u8, rest_in: []const u8) !Command {
    const rest = std.mem.trim(u8, rest_in, " \t\r\n");
    if (std.mem.eql(u8, cmd, "/meds")) return if (rest.len == 0) .list else .{ .usage = usage };
    if (rest.len == 0) return .list;
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const op = rest[0..sp];
    const arg = std.mem.trim(u8, rest[sp..], " \t");
    if (std.ascii.eqlIgnoreCase(op, "add")) {
        const at = lastAt(arg) orelse return .{ .usage = "Say the times after at: /med add NAME at 08:00, 20:00." };
        const name = std.mem.trim(u8, arg[0..at], " \t");
        if (nameProblem(name)) |why| return .{ .usage = why };
        const times = parseTimes(a, arg[at + 4 ..]) catch |e| return .{ .usage = switch (e) {
            error.TooManyTimes => "At most 8 times a day.",
            error.NoTimes => "Say the times after at: /med add NAME at 08:00, 20:00.",
            else => "Times are like 08:00 or 8:00, separated by commas.",
        } };
        return .{ .add = .{ .name = name, .times = times } };
    }
    if (std.ascii.eqlIgnoreCase(op, "rm")) {
        if (arg.len == 0) return .{ .usage = "Use /med rm NAME." };
        return .{ .rm = arg };
    }
    if (std.ascii.eqlIgnoreCase(op, "tell")) {
        const last = std.mem.lastIndexOfAny(u8, arg, " \t") orelse return .{ .usage = "Use /med tell NAME MEMBER, or /med tell NAME off." };
        const name = std.mem.trim(u8, arg[0..last], " \t");
        const member = std.mem.trim(u8, arg[last + 1 ..], " \t");
        if (name.len == 0 or member.len == 0) return .{ .usage = "Use /med tell NAME MEMBER, or /med tell NAME off." };
        return .{ .tell = .{ .name = name, .member = if (std.ascii.eqlIgnoreCase(member, "off")) "" else member } };
    }
    return .{ .usage = usage };
}

/// Where the last " at " of `s` is (any case).
fn lastAt(s: []const u8) ?usize {
    var i = s.len;
    while (i >= 4) : (i -= 1) {
        const w = s[i - 4 .. i];
        if (std.ascii.eqlIgnoreCase(w, " at ")) return i - 4;
    }
    return null;
}

/// Why `name` can't be a medication's name; null: it can.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "Name the medication: /med add NAME at 08:00.";
    if (name.len > max_name) return "A name of at most 40 letters, please.";
    if (name[0] == '/') return "Name the medication: /med add NAME at 08:00.";
    for (name) |ch| if (ch < 0x20 or ch == 0x7f or ch == '"' or ch == '\\') return "A name in plain words, please.";
    return null;
}

/// "08:00, 20:00", "8:00 and 20:00" → sorted minutes, each once.
pub fn parseTimes(a: Allocator, s: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    var it = std.mem.tokenizeAny(u8, s, ", \t");
    while (it.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, "and")) continue;
        const m = clockOf(w) orelse return error.BadTime;
        if (std.mem.indexOfScalar(u16, out.items, m) != null) continue;
        if (out.items.len == max_times) return error.TooManyTimes;
        try out.append(a, m);
    }
    if (out.items.len == 0) return error.NoTimes;
    std.mem.sort(u16, out.items, {}, std.sort.asc(u16));
    return out.items;
}

/// "8:00" or "08:00" → minutes.
fn clockOf(w: []const u8) ?u16 {
    if (w.len == 4 and w[1] == ':') {
        var b: [5]u8 = undefined;
        b[0] = '0';
        @memcpy(b[1..], w);
        return config.parseClock(&b) catch null;
    }
    return config.parseClock(w) catch null;
}

/// `/med`'s words as the log keeps them: the first, never a name.
pub fn loggedArgs(rest: []const u8) []const u8 {
    const r = std.mem.trim(u8, rest, " \t");
    if (r.len == 0) return "";
    const sp = std.mem.indexOfAny(u8, r, " \t") orelse return if (std.ascii.eqlIgnoreCase(r, "add") or std.ascii.eqlIgnoreCase(r, "rm") or std.ascii.eqlIgnoreCase(r, "tell")) r else "(withheld)";
    const op = r[0..sp];
    if (std.ascii.eqlIgnoreCase(op, "add")) return "add (withheld)";
    if (std.ascii.eqlIgnoreCase(op, "rm")) return "rm (withheld)";
    if (std.ascii.eqlIgnoreCase(op, "tell")) return "tell (withheld)";
    return "(withheld)";
}

/// "08:00 and 20:00".
pub fn timesText(a: Allocator, times: []const u16) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (times) |m| {
        var b: [5]u8 = undefined;
        try parts.append(a, try a.dupe(u8, clock(&b, m)));
    }
    if (parts.items.len == 1) return parts.items[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", parts.items[0 .. parts.items.len - 1]), parts.items[parts.items.len - 1] });
}

/// `/meds`: each medication's times, today's taken or not, and who is told.
pub fn listText(a: Allocator, d: Data, today: i64) ![]const u8 {
    if (d.meds.len == 0) return "No medication reminders. /med add NAME at 08:00, 20:00 sets one, with Taken each time.";
    var o: std.ArrayList(u8) = .empty;
    for (d.meds, 0..) |m, i| {
        if (i > 0) try o.append(a, '\n');
        try o.print(a, "{s}: ", .{m.name});
        for (m.times, 0..) |at, j| {
            var b: [5]u8 = undefined;
            try o.print(a, "{s}{s}", .{ if (j > 0) ", " else "", clock(&b, at) });
            if (d.slot(m.name, today, at)) |s| {
                if (s.taken) try o.appendSlice(a, " (taken)") else if (s.reminded != 0) try o.appendSlice(a, " (not taken)");
            }
        }
        try o.append(a, '.');
        if (m.tell.len > 0) try o.print(a, " {s} hears if one isn't taken in an hour.", .{try capital(a, m.tell)});
    }
    return o.items;
}

// ---- state/meds ----

/// The schedule and today's and yesterday's reminders, as `state/meds`
/// keeps them: a JSON line each, written whole on every change. Callers
/// hold `mutex` around `data` and `put`.
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    data: Data = .{},

    pub fn init(gpa: Allocator, io: Io, path: []const u8) Store {
        return .{ .gpa = gpa, .io = io, .path = path, .arena = .init(gpa) };
    }

    pub fn deinit(s: *Store) void {
        s.arena.deinit();
    }

    /// Reads `state/meds`; none: nothing set. A line that doesn't read is
    /// left out.
    pub fn load(s: *Store) !void {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const text = Io.Dir.cwd().readFileAlloc(s.io, s.path, scratch.allocator(), .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        const d = try parse(scratch.allocator(), text);
        try s.replace(d);
    }

    /// Writes `d` whole, then keeps it.
    pub fn put(s: *Store, d: Data) !void {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        try util.writeReplace(s.io, s.path, try render(scratch.allocator(), d));
        try s.replace(d);
    }

    fn replace(s: *Store, d: Data) !void {
        var fresh: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer fresh.deinit();
        const copy = try d.clone(fresh.allocator());
        s.arena.deinit();
        s.arena = fresh;
        s.data = copy;
    }
};

/// `state/meds`'s text: the medications, then the reminders.
pub fn render(a: Allocator, d: Data) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (d.meds) |m| {
        try o.appendSlice(a, "{\"med\":");
        try util.jsonString(&o, a, m.name);
        try o.appendSlice(a, ",\"times\":[");
        for (m.times, 0..) |at, i| {
            var b: [5]u8 = undefined;
            try o.print(a, "{s}\"{s}\"", .{ if (i > 0) "," else "", clock(&b, at) });
        }
        try o.appendSlice(a, "],\"tell\":");
        try util.jsonString(&o, a, m.tell);
        try o.appendSlice(a, "}\n");
    }
    for (d.slots) |x| {
        var b: [5]u8 = undefined;
        try o.appendSlice(a, "{\"slot\":");
        try util.jsonString(&o, a, x.med);
        try o.print(a, ",\"day\":{d},\"at\":\"{s}\",\"token\":", .{ x.day, clock(&b, x.at) });
        try util.jsonString(&o, a, x.token);
        try o.print(a, ",\"reminded\":{d},\"again\":{},\"told\":", .{ x.reminded, x.again });
        try util.jsonString(&o, a, x.told);
        try o.print(a, ",\"taken\":{},\"chat\":{d},\"thread\":{d},\"msg\":{d},\"msg2\":{d}}}\n", .{ x.taken, x.chat, x.thread, x.msg, x.msg2 });
    }
    return o.items;
}

pub fn parse(a: Allocator, text: []const u8) !Data {
    var meds: std.ArrayList(Med) = .empty;
    var slots: std.ArrayList(Slot) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        if (str(o, "med")) |name| {
            var times: std.ArrayList(u16) = .empty;
            if (o.get("times")) |tv| if (tv == .array) for (tv.array.items) |x| {
                if (x != .string) continue;
                const m = config.parseClock(x.string) catch continue;
                try times.append(a, m);
            };
            if (times.items.len == 0 or nameProblem(name) != null) continue;
            try meds.append(a, .{ .name = name, .times = times.items, .tell = str(o, "tell") orelse "" });
        } else if (str(o, "slot")) |name| {
            const at = config.parseClock(str(o, "at") orelse continue) catch continue;
            try slots.append(a, .{
                .med = name,
                .day = int(o, "day") orelse continue,
                .at = at,
                .token = str(o, "token") orelse continue,
                .reminded = int(o, "reminded") orelse 0,
                .again = boolean(o, "again"),
                .told = str(o, "told") orelse "",
                .taken = boolean(o, "taken"),
                .chat = int(o, "chat") orelse 0,
                .thread = int(o, "thread") orelse 0,
                .msg = int(o, "msg") orelse 0,
                .msg2 = int(o, "msg2") orelse 0,
            });
        }
    }
    return .{ .meds = meds.items, .slots = slots.items };
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn boolean(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

// ---- bedtime ----

/// When the night ends: as quiet hours end, else 06:00.
pub fn nightEnd(quiet: ?config.Quiet) u16 {
    return if (quiet) |q| q.end else 6 * 60;
}

/// Whether minute `m` of the owner's day is in the night: from `bedtime`
/// to `end`.
pub fn inNight(bedtime: u16, end: u16, m: u16) bool {
    if (bedtime == end) return false;
    return (config.Quiet{ .start = bedtime, .end = end }).inside(m);
}

/// The night `now_s` is in, as a number: its evening's day (a night that
/// ends at `end`).
pub fn nightOf(now_s: i64, offset: i32, end: u16) i64 {
    return @divFloor(now_s + @as(i64, offset) * 60 - @as(i64, end) * 60, 86400);
}

/// "It's past half eleven.", "It's past eleven.", "It's past midnight.",
/// "It's past 23:40.".
pub fn pastText(a: Allocator, bedtime: u16) ![]const u8 {
    const names = [_][]const u8{ "twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven" };
    const h = bedtime / 60;
    const m = bedtime % 60;
    if (bedtime == 0) return "It's past midnight.";
    if (bedtime == 12 * 60) return "It's past noon.";
    return switch (m) {
        0 => std.fmt.allocPrint(a, "It's past {s}.", .{names[h % 12]}),
        15 => std.fmt.allocPrint(a, "It's past quarter past {s}.", .{names[h % 12]}),
        30 => std.fmt.allocPrint(a, "It's past half {s}.", .{names[h % 12]}),
        45 => std.fmt.allocPrint(a, "It's past quarter to {s}.", .{names[(h + 1) % 12]}),
        else => blk: {
            var b: [5]u8 = undefined;
            break :blk std.fmt.allocPrint(a, "It's past {s}.", .{clock(&b, bedtime)});
        },
    };
}

/// `state/bedtime`: the night its line was said.
pub fn readNight(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

// ---- tests ----

const t = std.testing;

test "med_add_reads_names_and_times" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parseCommand(a, "/med", "add Vitamin D at 8:00, 20:00 and 08:00");
    try t.expectEqualStrings("Vitamin D", c.add.name);
    try t.expectEqualSlices(u16, &.{ 8 * 60, 20 * 60 }, c.add.times);
    // a name with "at" in it: the last " at " counts
    try t.expectEqualStrings("Take at night drops", (try parseCommand(a, "/med", "add Take at night drops AT 22:30")).add.name);
    try t.expect((try parseCommand(a, "/meds", "")) == .list);
    try t.expect((try parseCommand(a, "/med", "")) == .list);
    try t.expectEqualStrings("Vitamin D", (try parseCommand(a, "/med", "rm Vitamin D")).rm);
    const tell = try parseCommand(a, "/med", "tell Vitamin D anna");
    try t.expectEqualStrings("Vitamin D", tell.tell.name);
    try t.expectEqualStrings("anna", tell.tell.member);
    try t.expectEqualStrings("", (try parseCommand(a, "/med", "tell Vitamin D off")).tell.member);
    for ([_][]const u8{ "add Vitamin D", "add Vitamin D at", "add Vitamin D at 25:00", "add at 08:00", "add Vitamin D at 1:00 2:00 3:00 4:00 5:00 6:00 7:00 8:00 9:00", "add \"x at 08:00", "dose 2", "tell x" }) |w| {
        try t.expect((try parseCommand(a, "/med", w)) == .usage);
    }
    // the log keeps the first word alone
    try t.expectEqualStrings("add (withheld)", loggedArgs("add Metformin at 08:00"));
    try t.expectEqualStrings("tell (withheld)", loggedArgs(" tell Metformin anna"));
    try t.expectEqualStrings("(withheld)", loggedArgs("Metformin"));
    try t.expectEqualStrings("", loggedArgs(""));
    try t.expect(saysTaken("Taken.") and saysTaken("took it") and saysTaken(" OK! ") and !saysTaken("not yet") and !saysTaken("I'll take it later"));
}

fn sample(a: Allocator) !Data {
    var meds = try a.alloc(Med, 1);
    meds[0] = .{ .name = "Metformin", .times = try a.dupe(u16, &.{ 8 * 60, 20 * 60 }), .tell = "anna" };
    return .{ .meds = meds, .slots = &.{} };
}

test "meds_round_trip_with_windows_line_ends" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try sample(a);
    var slots = try a.alloc(Slot, 1);
    slots[0] = .{ .med = "Metformin", .day = 20415, .at = 8 * 60, .token = "0123456789abcdef", .reminded = 1763884800, .again = true, .taken = true, .chat = 42, .msg = 101, .msg2 = 102 };
    d.slots = slots;
    const text = try render(a, d);
    try t.expectEqualStrings(
        \\{"med":"Metformin","times":["08:00","20:00"],"tell":"anna"}
        \\{"slot":"Metformin","day":20415,"at":"08:00","token":"0123456789abcdef","reminded":1763884800,"again":true,"told":"","taken":true,"chat":42,"thread":0,"msg":101,"msg2":102}
        \\
    , text);
    const crlf = try std.mem.replaceOwned(u8, a, text, "\n", "\r\n");
    for ([_][]const u8{ text, crlf }) |x| {
        const back = try parse(a, x);
        try t.expectEqualStrings(text, try render(a, back));
    }
    // a line that doesn't read is left out
    try t.expectEqual(1, (try parse(a, "not json\n{\"med\":\"A\",\"times\":[\"09:00\"],\"tell\":\"\"}\n{\"med\":\"B\",\"times\":[]}\n")).meds.len);
}

test "a_reminder_once_more_after_30_minutes_and_the_member_after_an_hour" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try sample(a);
    const day: i64 = 20415;
    const off: i32 = 60;
    const t0 = slotTime(day, 8 * 60, off);
    try t.expectEqual(day * 86400 + 7 * 3600, t0);
    // a minute early: nothing; at the minute: the reminder
    try t.expectEqual(0, (try due(a, d, t0 - 60, off)).len);
    const first = try due(a, d, t0, off);
    try t.expectEqual(1, first.len);
    try t.expectEqual(Kind.remind, first[0].kind);
    try t.expectEqual(day, first[0].day);
    var slots = try a.alloc(Slot, 1);
    slots[0] = .{ .med = "Metformin", .day = day, .at = 8 * 60, .token = "t", .reminded = t0 + 5 };
    d.slots = slots;
    try t.expectEqual(0, (try due(a, d, t0 + 30 * 60, off)).len);
    const again = try due(a, d, t0 + 30 * 60 + 5, off);
    try t.expectEqual(1, again.len);
    try t.expectEqual(Kind.again, again[0].kind);
    slots[0].again = true;
    try t.expectEqual(0, (try due(a, d, t0 + 60 * 60, off)).len);
    const tell = try due(a, d, t0 + 60 * 60 + 5, off);
    try t.expectEqual(Kind.tell, tell[0].kind);
    try t.expectEqualStrings("anna", tell[0].tell);
    slots[0].told = "anna";
    try t.expectEqual(0, (try due(a, d, t0 + 2 * 3600, off)).len);
    // taken: nothing more, and no member without one asked for
    slots[0] = .{ .med = "Metformin", .day = day, .at = 8 * 60, .token = "t", .reminded = t0, .taken = true };
    try t.expectEqual(0, (try due(a, d, t0 + 2 * 3600, off)).len);
    d.meds[0].tell = "";
    slots[0].taken = false;
    slots[0].again = true;
    try t.expectEqual(0, (try due(a, d, t0 + 2 * 3600, off)).len);
    // 23:50, once more after midnight, by yesterday's slot
    d.meds[0].times = try a.dupe(u16, &.{23 * 60 + 50});
    const late = slotTime(day, 23 * 60 + 50, off);
    slots[0] = .{ .med = "Metformin", .day = day, .at = 23 * 60 + 50, .token = "t", .reminded = late };
    const next = try due(a, d, late + 31 * 60, off);
    try t.expectEqual(1, next.len);
    try t.expectEqual(Kind.again, next[0].kind);
    try t.expectEqual(day, next[0].day);
}

test "a_late_reminder_is_skipped_after_3_hours" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try sample(a);
    const t0 = slotTime(20415, 8 * 60, 0);
    try t.expectEqual(1, (try due(a, d, t0 + late_s - 1, 0)).len);
    try t.expectEqual(0, (try due(a, d, t0 + late_s, 0)).len);
}

test "meds_keep_the_schedule_and_taken_only" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try sample(a);
    var slots = try a.alloc(Slot, 4);
    slots[0] = .{ .med = "Metformin", .day = 20413, .at = 8 * 60, .token = "a", .taken = true };
    slots[1] = .{ .med = "Metformin", .day = 20414, .at = 8 * 60, .token = "b", .taken = true };
    slots[2] = .{ .med = "Metformin", .day = 20415, .at = 8 * 60, .token = "c" };
    slots[3] = .{ .med = "Aspirin", .day = 20415, .at = 8 * 60, .token = "d" };
    d.slots = slots;
    const p = try pruned(a, d, 20415);
    // yesterday's and today's, of medications still set
    try t.expectEqual(2, p.slots.len);
    try t.expectEqualStrings("b", p.slots[0].token);
    try t.expectEqualStrings("c", p.slots[1].token);
    // what a line holds: the schedule's fields, and a reminder's own
    const text = try render(a, p);
    for ([_][]const u8{ "dose", "note", "why", "advice" }) |w| try t.expect(std.mem.indexOf(u8, text, w) == null);
    try t.expectEqualStrings("Metformin: 08:00 (not taken), 20:00. Anna hears if one isn't taken in an hour.", try listText(a, .{ .meds = d.meds, .slots = blk: {
        var s = try a.alloc(Slot, 1);
        s[0] = .{ .med = "metformin", .day = 20415, .at = 8 * 60, .token = "c", .reminded = 1 };
        break :blk s;
    } }, 20415));
    try t.expectEqualStrings("No medication reminders. /med add NAME at 08:00, 20:00 sets one, with Taken each time.", try listText(a, .{}, 20415));
    // the member reads the time, never the name
    const m = try memberText(a, 8 * 60);
    try t.expectEqualStrings("The owner hasn't marked the 08:00 medicine as taken; the reminder went an hour ago.", m);
    try t.expectEqualStrings("Time for Metformin (08:00).", try remindText(a, "Metformin", 8 * 60));
    try t.expectEqualStrings("Still to take: Metformin (08:00).", try againText(a, "Metformin", 8 * 60));
    try t.expectEqualStrings("Metformin (08:00): taken at 08:05.", try takenText(a, "Metformin", 8 * 60, 8 * 60 + 5));
    try t.expectEqualStrings("I told Anna that Metformin (08:00) isn't marked as taken.", try ownerToldText(a, "anna", "Metformin", 8 * 60));
}

test "bedtime_words_and_the_night" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("It's past half eleven.", try pastText(a, 23 * 60 + 30));
    try t.expectEqualStrings("It's past eleven.", try pastText(a, 23 * 60));
    try t.expectEqualStrings("It's past quarter past ten.", try pastText(a, 22 * 60 + 15));
    try t.expectEqualStrings("It's past quarter to twelve.", try pastText(a, 23 * 60 + 45));
    try t.expectEqualStrings("It's past midnight.", try pastText(a, 0));
    try t.expectEqualStrings("It's past half twelve.", try pastText(a, 30));
    try t.expectEqualStrings("It's past 23:40.", try pastText(a, 23 * 60 + 40));
    // from bedtime to quiet hours' end (else 06:00)
    try t.expectEqual(@as(u16, 7 * 60), nightEnd(.{ .start = 22 * 60, .end = 7 * 60 }));
    try t.expectEqual(@as(u16, 6 * 60), nightEnd(null));
    const bt: u16 = 23 * 60 + 30;
    try t.expect(!inNight(bt, 7 * 60, 23 * 60 + 29));
    try t.expect(inNight(bt, 7 * 60, 23 * 60 + 30));
    try t.expect(inNight(bt, 7 * 60, 3 * 60));
    try t.expect(!inNight(bt, 7 * 60, 7 * 60));
    try t.expect(inNight(60, 6 * 60, 2 * 60) and !inNight(60, 6 * 60, 23 * 60));
    // 23:45 and 02:00 the next day are one night; the next evening another
    const day: i64 = 20415;
    const n = nightOf(day * 86400 + 23 * 3600 + 45 * 60, 0, 7 * 60);
    try t.expectEqual(n, nightOf((day + 1) * 86400 + 2 * 3600, 0, 7 * 60));
    try t.expectEqual(n + 1, nightOf((day + 1) * 86400 + 23 * 3600 + 45 * 60, 0, 7 * 60));
    try t.expectEqual(@as(?i64, 20415), readNight("20415\r\n"));
}

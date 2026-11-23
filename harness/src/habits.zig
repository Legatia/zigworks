//! Habits (the household spec's §6): once a week, what the owner asked
//! the home to do, read from the log: the same `home_set` call (device,
//! action, value) at about the same time (within 20 minutes) on at least
//! 4 days of the last 14 is a pattern, said as one question ("You switch
//! the coffee machine on at about 6:45 on weekdays. Shall I do that?"
//! [Yes] [No, and don't ask again]). Only the owner's own runs count,
//! only calls that worked, only devices home.ini has that aren't guarded.
//! Yes writes a routine of three parts (a workflow with that one call, a
//! schedule in triggers.ini, the rules line allowing that call for that
//! step alone). `state/habits` keeps when the last pass was and what was
//! offered and answered. Pure but for reading the log and `State`'s file.
const std = @import("std");
const util = @import("util.zig");
const butler = @import("butler.zig");
const history = @import("history.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Calls at most this many minutes apart are "about the same time".
pub const window_min = 20;
/// On at least this many days …
pub const min_days = 4;
/// … of the last this many.
pub const span_days = 14;
/// A suggestion nobody answered may come again after this many days.
pub const again_days = 28;
/// The weekly pass: from this minute of the owner's day …
pub const pass_minute = 10 * 60;
/// … this many days after the last.
pub const pass_every_days = 7;
/// A suggestion's item waits this long.
pub const expires_s = 7 * 86400;

/// Who the week's look is, as its item says (quiet hours hold it as a
/// schedule's): the one place this value is.
pub const who = "schedule:habits";
/// The routine's names: `habit-…` for its workflow and its trigger, and
/// its one step; its rules section is `[workflow:NAME/act]`
/// (`rulesSection`).
pub const name_prefix = "habit";
pub const step = "act";

/// The rules section of routine `name`'s one step.
pub fn rulesSection(a: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "[workflow:{s}/{s}]", .{ name, step });
}

/// One `home_set` call of the owner's that worked.
pub const Call = struct {
    /// The owner's day number and minute.
    day: i64,
    minute: u16,
    server: []const u8,
    device: []const u8,
    action: []const u8,
    value: []const u8 = "",
};

// ---- reading the log ----

/// The owner's own `home_set` calls that worked, from `from_s` to `to_s`,
/// in the log at `path`: tool lines whose run's first line says `by`
/// owner (members', the house's speech, schedules', triggers' and
/// workflows' runs never), whose argument is readable (a private run's
/// is kept as its size alone) and that didn't fail. In `a`.
pub fn scan(a: Allocator, io: Io, path: []const u8, from_s: i64, to_s: i64, offset: i32) ![]Call {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer f.close(io);
    const len = try f.length(io);
    var pos = try history.seekLine(io, f, len, from_s, history.timeKey);
    var owners: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var out: std.ArrayList(Call) = .empty;
    const buf = try a.alloc(u8, 1 << 20);
    defer a.free(buf);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    while (pos < len) {
        const got = try f.readPositionalAll(io, buf, pos);
        if (got == 0) break;
        const w = buf[0..got];
        const end = std.mem.lastIndexOfScalar(u8, w, '\n') orelse {
            // a line longer than the buffer: not one harness writes
            if (got < buf.len) break;
            pos += got;
            continue;
        };
        var it = std.mem.splitScalar(u8, w[0..end], '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const at = history.timeKey(line) orelse continue;
            if (at >= to_s) return out.items;
            if (std.mem.indexOf(u8, line, ",\"by\":\"owner\"") != null) if (intField(line, "rid")) |rid| try owners.put(a, rid, {});
            if (std.mem.indexOf(u8, line, ",\"kind\":\"tool\"") == null or std.mem.indexOf(u8, line, "/home_set ") == null) continue;
            const rid = intField(line, "rid") orelse continue;
            if (!owners.contains(rid)) continue;
            _ = scratch.reset(.retain_capacity);
            if (try callOf(a, scratch.allocator(), line, at, offset)) |c| try out.append(a, c);
        }
        pos += end + 1;
    }
    return out.items;
}

/// A tool line's `home_set` call, if it worked: `arg` is
/// "SERVER/home_set {json}".
fn callOf(a: Allocator, scratch: Allocator, line: []const u8, at: i64, offset: i32) !?Call {
    const v = std.json.parseFromSliceLeaky(std.json.Value, scratch, line, .{}) catch return null;
    if (v != .object) return null;
    const o = v.object;
    const failed = o.get("is_error") orelse return null;
    if (failed != .bool or failed.bool) return null;
    const arg_v = o.get("arg") orelse return null;
    if (arg_v != .string) return null;
    const arg = arg_v.string;
    const slash = std.mem.indexOfScalar(u8, arg, '/') orelse return null;
    const sp = std.mem.indexOfScalarPos(u8, arg, slash, ' ') orelse return null;
    if (!std.mem.eql(u8, arg[slash + 1 .. sp], "home_set")) return null;
    const input = std.json.parseFromSliceLeaky(std.json.Value, scratch, arg[sp + 1 ..], .{}) catch return null;
    if (input != .object) return null;
    const device = strOf(input.object.get("device")) orelse return null;
    const action = strOf(input.object.get("action")) orelse return null;
    var value: []const u8 = "";
    if (input.object.get("value")) |x| value = switch (x) {
        .string => |s| std.mem.trim(u8, s, " \t"),
        .integer => |n| try std.fmt.allocPrint(scratch, "{d}", .{n}),
        .float => |n| try std.fmt.allocPrint(scratch, "{d}", .{n}),
        .number_string => |s| s,
        else => return null,
    };
    const local = at + @as(i64, offset) * 60;
    return .{
        .day = @divFloor(local, 86400),
        .minute = @intCast(@divFloor(@mod(local, 86400), 60)),
        .server = try a.dupe(u8, arg[0..slash]),
        .device = try a.dupe(u8, device),
        .action = try std.ascii.allocLowerString(a, action),
        .value = try a.dupe(u8, value),
    };
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn intField(line: []const u8, comptime name: []const u8) ?u64 {
    const key = ",\"" ++ name ++ "\":";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const s = line[at + key.len ..];
    var n: u64 = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i]) and i < 19) : (i += 1) n = n * 10 + (s[i] - '0');
    return if (i == 0) null else n;
}

// ---- the pattern ----

pub const Days = enum {
    weekdays,
    weekends,
    every,

    pub fn words(d: Days) []const u8 {
        return switch (d) {
            .weekdays => "on weekdays",
            .weekends => "at weekends",
            .every => "every day",
        };
    }

    /// triggers.ini's `days =`; "": every day.
    pub fn line(d: Days) []const u8 {
        return switch (d) {
            .weekdays => "mon, tue, wed, thu, fri",
            .weekends => "sat, sun",
            .every => "",
        };
    }
};

pub const Pattern = struct {
    server: []const u8,
    /// home.ini's name for it.
    device: []const u8,
    action: []const u8,
    value: []const u8 = "",
    /// When the routine does it: the middle of the calls, to 5 minutes.
    minute: u16,
    days: Days,
    /// On how many days of the 14.
    count: u32,

    /// What the owner's answers are kept by.
    pub fn key(p: Pattern, a: Allocator) ![]const u8 {
        return keyOf(a, p.server, p.device, p.action, p.value);
    }

    /// The routine's name (its workflow, its trigger): `habit-` and the
    /// device, action and value in a-z, 0-9 and `-`, at most 64.
    pub fn name(p: Pattern, a: Allocator) ![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        try o.appendSlice(a, name_prefix);
        for ([_][]const u8{ p.device, p.action, p.value }) |part| {
            if (part.len == 0) continue;
            try o.append(a, '-');
            for (part) |ch| {
                const c = std.ascii.toLower(ch);
                if (std.ascii.isAlphanumeric(c)) {
                    try o.append(a, c);
                } else if (o.items[o.items.len - 1] != '-') try o.append(a, '-');
            }
        }
        var n = o.items[0..@min(o.items.len, 64)];
        while (n.len > 0 and n[n.len - 1] == '-') n = n[0 .. n.len - 1];
        return n;
    }
};

pub fn keyOf(a: Allocator, server: []const u8, device: []const u8, action: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}|{s}|{s}", .{ server, device, action, value });
}

/// Whether the routine may do `action` on `d` by itself: a light, plug,
/// switch, heating, blind, fan, scene or speaker home.ini lets act,
/// allowing that action; never one guarded (a lock, an alarm, a valve,
/// `guarded = yes`), a switch setup couldn't place or one named a valve.
pub fn eligible(d: butler.Device, action: []const u8) bool {
    if (d.isGuarded() or d.unidentified() or d.valveSwitch()) return false;
    switch (d.kind) {
        .light, .@"switch", .plug, .climate, .cover, .fan, .scene, .media => {},
        else => return false,
    }
    return d.allows(action);
}

/// A value the routine's file can hold as it is: up to 32 letters,
/// digits, spaces and `.,#%-_`.
fn plainValue(v: []const u8) bool {
    if (v.len > 32) return false;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, " .,#%-_", ch) != null)) return false;
    return true;
}

const Seen = struct { day: i64, minute: u16 };

const Group = struct { key: []const u8, server: []const u8, device: []const u8, action: []const u8, value: []const u8, seen: std.ArrayList(Seen) = .empty };

/// The best pattern in `calls`, devices as `home` has them, leaving out
/// the keys in `skip`; null: none on at least 4 days.
pub fn find(a: Allocator, calls: []const Call, home: butler.Home, skip: []const []const u8) !?Pattern {
    var groups: std.ArrayList(Group) = .empty;
    for (calls) |cl| {
        const d = home.find(cl.device) orelse continue;
        if (!eligible(d.*, cl.action) or !plainValue(cl.value)) continue;
        const k = try keyOf(a, cl.server, d.name, cl.action, cl.value);
        if (has(skip, k)) continue;
        const g = for (groups.items) |*g| {
            if (std.mem.eql(u8, g.key, k)) break g;
        } else blk: {
            try groups.append(a, .{ .key = k, .server = cl.server, .device = d.name, .action = cl.action, .value = cl.value });
            break :blk &groups.items[groups.items.len - 1];
        };
        try g.seen.append(a, .{ .day = cl.day, .minute = cl.minute });
    }
    var best: ?Pattern = null;
    var best_key: []const u8 = "";
    for (groups.items) |*g| {
        const w = (try bestWindow(a, g.seen.items)) orelse continue;
        const p: Pattern = .{ .server = g.server, .device = g.device, .action = g.action, .value = g.value, .minute = w.minute, .days = w.days, .count = w.count };
        if (best) |b| {
            if (p.count < b.count) continue;
            if (p.count == b.count and std.mem.order(u8, g.key, best_key) != .lt) continue;
        }
        best = p;
        best_key = g.key;
    }
    return best;
}

const Window = struct { minute: u16, days: Days, count: u32 };

/// The 20 minutes with calls on the most days (at least 4; the narrower,
/// then the earlier, on a tie).
fn bestWindow(a: Allocator, seen_in: []const Seen) !?Window {
    const seen = try a.dupe(Seen, seen_in);
    std.mem.sort(Seen, seen, {}, struct {
        fn lt(_: void, x: Seen, y: Seen) bool {
            return x.minute < y.minute or (x.minute == y.minute and x.day < y.day);
        }
    }.lt);
    var best_i: usize = 0;
    var best_j: usize = 0;
    var best_n: usize = 0;
    for (seen, 0..) |s, i| {
        var j = i;
        while (j + 1 < seen.len and seen[j + 1].minute - s.minute <= window_min) j += 1;
        const n = (try firstEach(a, seen[i .. j + 1])).len;
        const spread = seen[j].minute - s.minute;
        if (n > best_n or (n == best_n and n > 0 and spread < seen[best_j].minute - seen[best_i].minute)) {
            best_i = i;
            best_j = j;
            best_n = n;
        }
    }
    if (best_n < min_days) return null;
    const each = try firstEach(a, seen[best_i .. best_j + 1]);
    var minutes = try a.alloc(u16, each.len);
    var weekdays: usize = 0;
    var weekend: usize = 0;
    for (each, 0..) |s, k| {
        minutes[k] = s.minute;
        if (util.weekday(s.day) < 5) weekdays += 1 else weekend += 1;
    }
    std.mem.sort(u16, minutes, {}, std.sort.asc(u16));
    const n = minutes.len;
    const mid: u32 = if (n % 2 == 1) minutes[n / 2] else (@as(u32, minutes[n / 2 - 1]) + minutes[n / 2]) / 2;
    const rounded: u16 = @intCast(@min((mid + 2) / 5 * 5, 24 * 60 - 5));
    return .{ .minute = rounded, .days = if (weekend == 0) .weekdays else if (weekdays == 0) .weekends else .every, .count = @intCast(n) };
}

/// The first call of each day in `seen` (sorted by minute).
fn firstEach(a: Allocator, seen: []const Seen) ![]const Seen {
    var out: std.ArrayList(Seen) = .empty;
    for (seen) |s| {
        for (out.items) |o| {
            if (o.day == s.day) break;
        } else try out.append(a, s);
    }
    return out.items;
}

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

// ---- the words and the routine ----

/// What it does, as the owner would ask it: "switch the coffee machine
/// on", "set the hall thermostat to 21 °C", "open the bedroom blind".
pub fn phrase(a: Allocator, p: Pattern) ![]const u8 {
    const label = try butler.spoken(a, p.device);
    const eql = std.mem.eql;
    if (eql(u8, p.action, "on") or eql(u8, p.action, "off")) return std.fmt.allocPrint(a, "switch the {s} {s}", .{ label, p.action });
    if (eql(u8, p.action, "temperature")) return std.fmt.allocPrint(a, "set the {s} to {s} °C", .{ label, p.value });
    if (eql(u8, p.action, "brightness") or eql(u8, p.action, "position")) return std.fmt.allocPrint(a, "set the {s} to {s} %", .{ label, p.value });
    if (p.value.len == 0) return std.fmt.allocPrint(a, "{s} the {s}", .{ p.action, label });
    return std.fmt.allocPrint(a, "set the {s}'s {s} to {s}", .{ label, try butler.spoken(a, p.action), p.value });
}

/// "6:45".
fn spokenClock(buf: *[5]u8, m: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m / 60, m % 60 }) catch "";
}

/// "06:45".
fn fileClock(buf: *[5]u8, m: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ m / 60, m % 60 }) catch "";
}

/// "You switch the coffee machine on at about 6:45 on weekdays. Shall I
/// do that?"
pub fn question(a: Allocator, p: Pattern) ![]const u8 {
    var b: [5]u8 = undefined;
    return std.fmt.allocPrint(a, "You {s} at about {s} {s}. Shall I do that?", .{ try phrase(a, p), spokenClock(&b, p.minute), p.days.words() });
}

/// What Yes says once the routine is written.
pub fn onText(a: Allocator, p: Pattern) ![]const u8 {
    var b: [5]u8 = undefined;
    const ph = try butler.capital(a, try phrase(a, p));
    return std.fmt.allocPrint(a, "Done: I'll {s} at {s} {s}. /workflow rm {s} stops it.", .{ try lowerFirst(a, ph), fileClock(&b, p.minute), p.days.words(), try p.name(a) });
}

fn lowerFirst(a: Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len > 0) out[0] = std.ascii.toLower(out[0]);
    return out;
}

pub const Files = struct { workflow: []const u8, triggers: []const u8, rules: []const u8 };

/// The routine Yes writes, marked with `date`: a workflow with the one
/// call (a line only when it didn't take), its schedule, and the rules
/// line allowing exactly that call for that step.
pub fn routineFiles(a: Allocator, p: Pattern, date: []const u8) !Files {
    const name = try p.name(a);
    var cb: [5]u8 = undefined;
    const at = fileClock(&cb, p.minute);
    const ph = try phrase(a, p);
    // the call: its keys in order, as the gate reads JSON
    var input: std.ArrayList(u8) = .empty;
    try input.appendSlice(a, "{\"action\":");
    try util.jsonString(&input, a, p.action);
    try input.appendSlice(a, ",\"device\":");
    try util.jsonString(&input, a, p.device);
    if (p.value.len > 0) {
        try input.appendSlice(a, ",\"value\":");
        try util.jsonString(&input, a, p.value);
    }
    try input.append(a, '}');
    const workflow = try std.fmt.allocPrint(a,
        \\# added by habits {s}: you said yes to {s} at {s} {s}
        \\workflow {s}
        \\about At {s} {s}: {s}.
        \\start schedule:{s}
        \\tag no
        \\limits steps 5, days 1
        \\
        \\step {s}
        \\tool {s}/home_set {s}
        \\on fail goto failed
        \\if {s} starts done goto done
        \\
        \\step unsure
        \\say At {s} I asked to {s}; it hasn't confirmed: {{{s}}}
        \\end
        \\
        \\step done
        \\end
        \\
        \\step failed
        \\say At {s} I couldn't {s}: {{{s}.error}}
        \\
    , .{ date, ph, at, p.days.words(), name, at, p.days.words(), ph, name, step, p.server, input.items, step, at, ph, step, at, ph, step });
    var trig: std.ArrayList(u8) = .empty;
    try trig.print(a, "; added by habits {s}: {s} at {s} {s}\n[{s}]\nat = {s}\n", .{ date, ph, at, p.days.words(), name, at });
    if (p.days.line().len > 0) try trig.print(a, "days = {s}\n", .{p.days.line()});
    try trig.print(a, "start = workflow {s}\n", .{name});
    const rules = try std.fmt.allocPrint(a, "# added by habits {s}: {s} at {s}, this call alone\n{s}\nallow mcp {s}/home_set {s}\n[all]\n", .{ date, ph, at, try rulesSection(a, name), p.server, input.items });
    return .{ .workflow = workflow, .triggers = trig.items, .rules = rules };
}

// ---- state/habits ----

/// A suggestion made: its pattern, the day, and the answer ("" none yet,
/// "yes", "no").
pub const Offer = struct {
    pattern: Pattern,
    day: i64,
    said: []const u8 = "",
};

pub const Data = struct {
    /// The owner's day of the last pass (0: none yet).
    pass: i64 = 0,
    offers: []Offer = &.{},

    pub fn clone(d: Data, a: Allocator) !Data {
        const offers = try a.alloc(Offer, d.offers.len);
        for (d.offers, offers) |o, *n| n.* = try cloneOffer(a, o);
        return .{ .pass = d.pass, .offers = offers };
    }

    /// `d` with `o` offered after the others.
    pub fn with(d: Data, a: Allocator, o: Offer) !Data {
        const offers = try a.alloc(Offer, d.offers.len + 1);
        @memcpy(offers[0..d.offers.len], d.offers);
        offers[d.offers.len] = o;
        return .{ .pass = d.pass, .offers = offers };
    }

    pub fn byName(d: Data, a: Allocator, name: []const u8) !?*Offer {
        for (d.offers) |*o| if (std.mem.eql(u8, try o.pattern.name(a), name)) return o;
        return null;
    }

    /// The keys not to suggest on `today`: answered, or offered less than
    /// 28 days ago.
    pub fn skip(d: Data, a: Allocator, today: i64) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (d.offers) |o| if (o.said.len > 0 or today - o.day < again_days) try out.append(a, try o.pattern.key(a));
        return out.items;
    }

    /// A suggestion still waiting for its answer (offered less than 7
    /// days ago, unanswered).
    pub fn waiting(d: Data, today: i64) bool {
        for (d.offers) |o| if (o.said.len == 0 and today - o.day < expires_s / 86400) return true;
        return false;
    }
};

/// Whether the weekly pass is due at `now_s`: from 10:00, 7 days after the last.
pub fn passDue(pass: i64, now_s: i64, offset: i32) bool {
    const local = now_s + @as(i64, offset) * 60;
    if (@divFloor(@mod(local, 86400), 60) < pass_minute) return false;
    return pass == 0 or @divFloor(local, 86400) - pass >= pass_every_days;
}

/// `state/habits`, written whole on every change; callers hold `mutex`.
pub const State = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    data: Data = .{},

    pub fn init(gpa: Allocator, io: Io, path: []const u8) State {
        return .{ .gpa = gpa, .io = io, .path = path, .arena = .init(gpa) };
    }

    pub fn deinit(s: *State) void {
        s.arena.deinit();
    }

    pub fn load(s: *State) !void {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const text = Io.Dir.cwd().readFileAlloc(s.io, s.path, scratch.allocator(), .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        try s.replace(try parse(scratch.allocator(), text));
    }

    pub fn put(s: *State, d: Data) !void {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        try util.writeReplace(s.io, s.path, try render(scratch.allocator(), d));
        try s.replace(d);
    }

    fn replace(s: *State, d: Data) !void {
        var fresh: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer fresh.deinit();
        const copy = try d.clone(fresh.allocator());
        s.arena.deinit();
        s.arena = fresh;
        s.data = copy;
    }
};

pub fn cloneOffer(a: Allocator, o: Offer) !Offer {
    var n = o;
    inline for (.{ "server", "device", "action", "value" }) |f| @field(n.pattern, f) = try a.dupe(u8, @field(o.pattern, f));
    n.said = try a.dupe(u8, o.said);
    return n;
}

pub fn render(a: Allocator, d: Data) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "{{\"pass\":{d}}}\n", .{d.pass});
    for (d.offers) |x| {
        const p = x.pattern;
        try o.appendSlice(a, "{\"server\":");
        try util.jsonString(&o, a, p.server);
        try o.appendSlice(a, ",\"device\":");
        try util.jsonString(&o, a, p.device);
        try o.appendSlice(a, ",\"action\":");
        try util.jsonString(&o, a, p.action);
        try o.appendSlice(a, ",\"value\":");
        try util.jsonString(&o, a, p.value);
        var b: [5]u8 = undefined;
        try o.print(a, ",\"at\":\"{s}\",\"days\":\"{s}\",\"count\":{d},\"day\":{d},\"said\":", .{ fileClock(&b, p.minute), @tagName(p.days), p.count, x.day });
        try util.jsonString(&o, a, x.said);
        try o.appendSlice(a, "}\n");
    }
    return o.items;
}

pub fn parse(a: Allocator, text: []const u8) !Data {
    var d: Data = .{};
    var offers: std.ArrayList(Offer) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        if (o.get("pass")) |p| {
            if (p == .integer) d.pass = p.integer;
            continue;
        }
        const at = @import("config.zig").parseClock(strOf(o.get("at")) orelse continue) catch continue;
        const day_v = o.get("day") orelse continue;
        const count_v = o.get("count") orelse continue;
        if (day_v != .integer or count_v != .integer) continue;
        try offers.append(a, .{
            .pattern = .{
                .server = strOf(o.get("server")) orelse continue,
                .device = strOf(o.get("device")) orelse continue,
                .action = strOf(o.get("action")) orelse continue,
                .value = strOf(o.get("value")) orelse "",
                .minute = at,
                .days = std.meta.stringToEnum(Days, strOf(o.get("days")) orelse continue) orelse continue,
                .count = @intCast(@max(0, @min(count_v.integer, 99))),
            },
            .day = day_v.integer,
            .said = strOf(o.get("said")) orelse "",
        });
    }
    d.offers = offers.items;
    return d;
}

// ---- tests ----

const t = std.testing;

/// A home with a coffee machine, a lamp, the heating, a lock and a switch
/// setup couldn't place.
pub const test_home =
    \\[home]
    \\name = Test flat
    \\[device coffee_machine]
    \\kind = plug
    \\room = Kitchen
    \\alias = the coffee maker
    \\allow = on, off
    \\[device hall_thermostat]
    \\kind = climate
    \\allow = temperature
    \\[device front_door]
    \\kind = lock
    \\allow = lock
    \\[device garage_door]
    \\kind = cover
    \\guarded = yes
    \\allow = close
    \\[device mystery_switch]
    \\kind = switch
    \\allow = on, off
    \\note = not identified at setup: asked every time until you sort it
    \\[device bedroom_lamp]
    \\kind = light
    \\allow = on, off, brightness
    \\
;

/// A log line as harness writes it (enough of one): `time` and the rest.
pub fn logLine(a: Allocator, seq: u64, at: i64, rest: []const u8) ![]const u8 {
    var b: [20]u8 = undefined;
    return std.fmt.allocPrint(a, "{{\"seq\":{d},\"time\":\"{s}\",\"kind\":{s},\"prev\":\"0\"}}\n", .{ seq, util.isoTime(&b, at), rest });
}

/// A run of `by` at `at` that calls `server`/home_set with `input`
/// (`private`: its argument kept as its size).
pub fn runLines(a: Allocator, out: *std.ArrayList(u8), seq: *u64, at: i64, by: []const u8, server: []const u8, input: []const u8, ok: bool, private: bool) !void {
    seq.* += 1;
    const rid = seq.*;
    try out.appendSlice(a, try logLine(a, rid, at, try std.fmt.allocPrint(a, "\"turn\",\"rid\":{d},\"conversation\":\"main\",\"run\":\"chat\",\"by\":\"{s}\",\"agent\":\"main\",\"text\":\"switch it\"", .{ rid, by })));
    seq.* += 1;
    var arg: std.ArrayList(u8) = .empty;
    if (private) try arg.appendSlice(a, "{\"bytes\":40,\"hmac\":\"ab\"}") else try util.jsonString(&arg, a, try std.fmt.allocPrint(a, "{s}/home_set {s}", .{ server, input }));
    try out.appendSlice(a, try logLine(a, seq.*, at + 2, try std.fmt.allocPrint(a, "\"tool\",\"rid\":{d},\"conversation\":\"main\",\"run\":\"chat\",\"agent\":\"main\",\"tool\":\"{s}__home_set\",\"arg\":{s},\"is_error\":{},\"output\":\"done\",\"bytes\":4", .{ rid, server, arg.items, !ok })));
}

fn writeLog(dir: []const u8, name: []const u8, text: []const u8) ![]const u8 {
    const path = try std.fs.path.join(t.allocator, &.{ dir, name });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = text });
    return path;
}

/// 00:00 UTC of Monday 2026-11-09.
const monday: i64 = 20766 * 86400;

test "the_owners_home_set_calls_are_read_from_the_log" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(u3, 0), util.weekday(20766));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var log: std.ArrayList(u8) = .empty;
    var seq: u64 = 0;
    const at = monday + 5 * 3600 + 45 * 60; // 06:45 at +01:00
    try runLines(a, &log, &seq, at, "owner", "home", "{\"device\": \"coffee machine\", \"action\": \"On\"}", true, false);
    try runLines(a, &log, &seq, at + 60, "owner", "home", "{\"device\":\"hall_thermostat\",\"action\":\"temperature\",\"value\":21}", true, false);
    // not the owner's own, failed, private, or another tool: none
    try runLines(a, &log, &seq, at + 120, "member:anna", "home", "{\"device\":\"coffee_machine\",\"action\":\"on\"}", true, false);
    try runLines(a, &log, &seq, at + 180, "room:kitchen", "home", "{\"device\":\"coffee_machine\",\"action\":\"on\"}", true, false);
    try runLines(a, &log, &seq, at + 240, "workflow:habit-coffee-machine-on/act", "home", "{\"device\":\"coffee_machine\",\"action\":\"on\"}", true, false);
    try runLines(a, &log, &seq, at + 300, "owner", "home", "{\"device\":\"coffee_machine\",\"action\":\"on\"}", false, false);
    try runLines(a, &log, &seq, at + 360, "owner", "home", "{\"device\":\"coffee_machine\",\"action\":\"on\"}", true, true);
    // a line with Windows' line end reads the same
    const crlf = try std.mem.replaceOwned(u8, a, log.items, "\n", "\r\n");
    const path = try writeLog(dir, "log", crlf);
    defer t.allocator.free(path);
    const calls = try scan(a, t.io, path, monday, monday + 86400, 60);
    try t.expectEqual(2, calls.len);
    try t.expectEqual(@as(i64, 20766), calls[0].day);
    try t.expectEqual(@as(u16, 6 * 60 + 45), calls[0].minute);
    try t.expectEqualStrings("coffee machine", calls[0].device);
    try t.expectEqualStrings("on", calls[0].action);
    try t.expectEqualStrings("21", calls[1].value);
    // the window: from and to
    try t.expectEqual(0, (try scan(a, t.io, path, monday + 86400, monday + 2 * 86400, 60)).len);
    try t.expectEqual(0, (try scan(a, t.io, path, monday, at, 60)).len);
    try t.expectEqual(0, (try scan(a, t.io, "/nonexistent/harness-log", 0, monday, 0)).len);
}

/// The owner's coffee machine on at `minutes` (one each, the owner's
/// time at +00:00) on the days `days` after Monday 2026-11-09.
fn coffee(a: Allocator, days: []const i64, minutes: []const u16) ![]Call {
    var out: std.ArrayList(Call) = .empty;
    for (days, minutes) |d, m| try out.append(a, .{ .day = 20766 + d, .minute = m, .server = "home", .device = "the coffee maker", .action = "on" });
    return out.items;
}

test "four_days_within_20_minutes_make_a_pattern" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try butler.parseHome(a, test_home);
    // Mon, Tue, Thu, Fri of one week, 06:40 to 06:55; and a stray one at 09:00
    const calls = try coffee(a, &.{ 0, 1, 3, 4, 2 }, &.{ 6 * 60 + 40, 6 * 60 + 55, 6 * 60 + 45, 6 * 60 + 50, 9 * 60 });
    const p = (try find(a, calls, home, &.{})).?;
    try t.expectEqualStrings("coffee_machine", p.device);
    try t.expectEqual(@as(u32, 4), p.count);
    // the middle of 06:40–06:55, to 5 minutes
    try t.expectEqual(@as(u16, 6 * 60 + 45), p.minute);
    try t.expectEqual(Days.weekdays, p.days);
    try t.expectEqualStrings("home/coffee_machine|on|", try p.key(a));
    try t.expectEqualStrings("habit-coffee-machine-on", try p.name(a));
    // a weekend's: at weekends; mixed: every day
    try t.expectEqual(Days.weekends, (try find(a, try coffee(a, &.{ 5, 6, 12, 13 }, &.{ 480, 485, 490, 480 }), home, &.{})).?.days);
    try t.expectEqual(Days.every, (try find(a, try coffee(a, &.{ 0, 5, 6, 7 }, &.{ 480, 485, 490, 480 }), home, &.{})).?.days);
    // a key answered before: not again
    try t.expect((try find(a, calls, home, &.{"home/coffee_machine|on|"})) == null);
}

test "three_days_or_a_wider_window_make_none" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try butler.parseHome(a, test_home);
    try t.expect((try find(a, try coffee(a, &.{ 0, 1, 2 }, &.{ 400, 405, 410 }), home, &.{})) == null);
    // four days, 21 minutes apart at the ends
    try t.expect((try find(a, try coffee(a, &.{ 0, 1, 2, 3 }, &.{ 400, 405, 410, 421 }), home, &.{})) == null);
    // four calls on three days
    try t.expect((try find(a, try coffee(a, &.{ 0, 0, 1, 2 }, &.{ 400, 405, 410, 415 }), home, &.{})) == null);
    // another value is another action
    const calls = try coffee(a, &.{ 0, 1, 2, 3 }, &.{ 400, 405, 410, 415 });
    for (calls[0..2]) |*c| c.device = "bedroom_lamp";
    for (calls) |*c| c.action = "brightness";
    calls[0].value = "30";
    calls[1].value = "30";
    calls[2].device = "bedroom_lamp";
    calls[2].value = "80";
    calls[3].device = "bedroom_lamp";
    calls[3].value = "30";
    try t.expect((try find(a, calls, home, &.{})) == null);
}

test "habits_never_suggest_guarded_devices" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try butler.parseHome(a, test_home);
    for ([_][2][]const u8{ .{ "front_door", "lock" }, .{ "garage_door", "close" }, .{ "mystery_switch", "on" }, .{ "a_device_home_ini_lacks", "on" }, .{ "coffee_machine", "brightness" } }) |x| {
        const calls = try coffee(a, &.{ 0, 1, 2, 3, 4 }, &.{ 1320, 1321, 1322, 1323, 1324 });
        for (calls) |*c| {
            c.device = x[0];
            c.action = x[1];
        }
        try t.expect((try find(a, calls, home, &.{})) == null);
    }
    // a lock home.ini forgot to guard is guarded all the same
    try t.expect(!eligible(.{ .name = "door", .kind = .lock, .allow = &.{"lock"} }, "lock"));
    try t.expect(eligible(.{ .name = "lamp", .kind = .light, .allow = &.{"on"} }, "on"));
}

test "the_question_and_the_routine_read" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: Pattern = .{ .server = "home", .device = "coffee_machine", .action = "on", .minute = 6 * 60 + 45, .days = .weekdays, .count = 5 };
    try t.expectEqualStrings("You switch the coffee machine on at about 6:45 on weekdays. Shall I do that?", try question(a, p));
    try t.expectEqualStrings("You set the hall thermostat to 21 °C at about 18:30 every day. Shall I do that?", try question(a, .{ .server = "home", .device = "hall_thermostat", .action = "temperature", .value = "21", .minute = 18 * 60 + 30, .days = .every, .count = 4 }));
    try t.expectEqualStrings("You open the bedroom blind at about 8:00 at weekends. Shall I do that?", try question(a, .{ .server = "home", .device = "bedroom_blind", .action = "open", .minute = 8 * 60, .days = .weekends, .count = 4 }));
    try t.expectEqualStrings("Done: I'll switch the coffee machine on at 06:45 on weekdays. /workflow rm habit-coffee-machine-on stops it.", try onText(a, p));
    const f = try routineFiles(a, p, "2026-11-23");
    try t.expectEqualStrings(
        \\# added by habits 2026-11-23: you said yes to switch the coffee machine on at 06:45 on weekdays
        \\workflow habit-coffee-machine-on
        \\about At 06:45 on weekdays: switch the coffee machine on.
        \\start schedule:habit-coffee-machine-on
        \\tag no
        \\limits steps 5, days 1
        \\
        \\step act
        \\tool home/home_set {"action":"on","device":"coffee_machine"}
        \\on fail goto failed
        \\if act starts done goto done
        \\
        \\step unsure
        \\say At 06:45 I asked to switch the coffee machine on; it hasn't confirmed: {act}
        \\end
        \\
        \\step done
        \\end
        \\
        \\step failed
        \\say At 06:45 I couldn't switch the coffee machine on: {act.error}
        \\
    , f.workflow);
    try t.expectEqualStrings("; added by habits 2026-11-23: switch the coffee machine on at 06:45 on weekdays\n[habit-coffee-machine-on]\nat = 06:45\ndays = mon, tue, wed, thu, fri\nstart = workflow habit-coffee-machine-on\n", f.triggers);
    try t.expectEqualStrings("# added by habits 2026-11-23: switch the coffee machine on at 06:45, this call alone\n[workflow:habit-coffee-machine-on/act]\nallow mcp home/home_set {\"action\":\"on\",\"device\":\"coffee_machine\"}\n[all]\n", f.rules);
    // every day: no days line
    const e = try routineFiles(a, .{ .server = "home", .device = "hall_thermostat", .action = "temperature", .value = "21", .minute = 18 * 60 + 30, .days = .every, .count = 4 }, "2026-11-23");
    try t.expect(std.mem.indexOf(u8, e.triggers, "days") == null);
    try t.expect(std.mem.indexOf(u8, e.rules, "{\"action\":\"temperature\",\"device\":\"hall_thermostat\",\"value\":\"21\"}") != null);
}

test "habits_state_round_trips" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var offers = try a.alloc(Offer, 2);
    offers[0] = .{ .pattern = .{ .server = "home", .device = "coffee_machine", .action = "on", .minute = 405, .days = .weekdays, .count = 5 }, .day = 20410, .said = "no" };
    offers[1] = .{ .pattern = .{ .server = "home", .device = "hall_thermostat", .action = "temperature", .value = "21", .minute = 1110, .days = .every, .count = 4 }, .day = 20417 };
    const d: Data = .{ .pass = 20417, .offers = offers };
    const text = try render(a, d);
    const crlf = try std.mem.replaceOwned(u8, a, text, "\n", "\r\n");
    for ([_][]const u8{ text, crlf }) |x| try t.expectEqualStrings(text, try render(a, try parse(a, x)));
    // answered: never again; unanswered: again after 28 days
    try t.expectEqual(2, (try d.skip(a, 20420)).len);
    try t.expectEqual(1, (try d.skip(a, 20417 + again_days)).len);
    try t.expect(d.waiting(20420) and !d.waiting(20424));
    try t.expectEqualStrings("hall_thermostat", (try d.byName(a, "habit-hall-thermostat-temperature-21")).?.pattern.device);
    // the pass: from 10:00, a week after the last
    try t.expect(!passDue(0, monday + 9 * 3600 + 59 * 60, 0));
    try t.expect(passDue(0, monday + 10 * 3600, 0));
    try t.expect(!passDue(20766, monday + 6 * 86400 + 12 * 3600, 0));
    try t.expect(passDue(20766, monday + 7 * 86400 + 10 * 3600, 0));
}

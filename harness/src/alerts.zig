//! Emergencies: an urgent alert nobody has answered goes to household
//! members in order (`[butler] escalate = 5m anna, 15m piotr`, or a
//! trigger's or workflow's own `escalate`), until someone says they are on
//! it; an urgent routine's question may make its safe call itself
//! (`fallback`). Here: the escalation line, and `state/alerts` (what is
//! open, who was told, what is due).
const std = @import("std");
const util = @import("util.zig");
const jv = @import("jv.zig");
const household = @import("household.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A step of escalation: `member` is told when nobody acknowledged the
/// alert `after_s` seconds after its first message.
pub const Step = struct { after_s: u32, member: []const u8 };

/// Steps of one escalation, at most.
pub const max_steps = 5;

pub const ParseError = error{ BadEscalate, OutOfMemory };

const shape = "escalate = DURATION MEMBER, DURATION MEMBER (like 5m anna, 15m piotr), or no";

/// `5m anna, 15m piotr` → its steps; `no` or `off` → none. A line that
/// doesn't read says why in `why`.
pub fn parseEscalate(a: Allocator, text_in: []const u8, why: *[]const u8) ParseError![]const Step {
    const text = std.mem.trim(u8, text_in, " \t\r");
    if (std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off")) return &.{};
    var out: std.ArrayList(Step) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        var words = std.mem.tokenizeAny(u8, part, " \t");
        const d = words.next() orelse return bad(why, shape);
        const name = words.next() orelse return bad(why, shape);
        if (words.next() != null) return bad(why, shape);
        const secs = duration(d) orelse return bad(why, "each step is a duration like 5m or 1h, then a member's name");
        if (secs < 60 or secs > 86400) return bad(why, "a step comes from 1 minute to 24 hours after the alert");
        if (!household.validName(name)) return bad(why, "a step names a member: a member's name as /members lists it (a-z, 0-9, - and _)");
        for (out.items) |o| if (std.mem.eql(u8, o.member, name)) {
            why.* = try std.fmt.allocPrint(a, "{s} comes twice: a member is told once", .{name});
            return error.BadEscalate;
        };
        if (out.items.len > 0 and secs <= out.items[out.items.len - 1].after_s) return bad(why, "steps come each later than the one before");
        if (out.items.len == max_steps) return bad(why, "at most 5 steps");
        try out.append(a, .{ .after_s = secs, .member = name });
    }
    if (out.items.len == 0) return bad(why, shape);
    return out.items;
}

fn bad(why: *[]const u8, text: []const u8) error{BadEscalate} {
    why.* = text;
    return error.BadEscalate;
}

/// "30s", "5m", "2h" → seconds; null when it isn't one.
fn duration(v: []const u8) ?u32 {
    if (v.len < 2) return null;
    const n = std.fmt.parseInt(u32, v[0 .. v.len - 1], 10) catch return null;
    const unit: u32 = switch (v[v.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        else => return null,
    };
    return std.math.mul(u32, n, unit) catch null;
}

/// "5 min", "1 h 30 min".
pub fn minutesText(a: Allocator, secs: u32) ![]const u8 {
    const m = secs / 60;
    if (m < 60) return std.fmt.allocPrint(a, "{d} min", .{m});
    if (m % 60 == 0) return std.fmt.allocPrint(a, "{d} h", .{m / 60});
    return std.fmt.allocPrint(a, "{d} h {d} min", .{ m / 60, m % 60 });
}

/// "anna after 5 min, then piotr after 15 min", as readings say steps.
pub fn stepsText(a: Allocator, steps: []const Step) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (steps, 0..) |s, i| try out.print(a, "{s}{s} after {s}", .{ if (i > 0) ", then " else "", s.member, try minutesText(a, s.after_s) });
    return out.items;
}

/// What a reading says of an escalation: its steps, none (`no`), or
/// nothing at all when it is `[butler]`'s (null).
pub fn readingWords(a: Allocator, steps: ?[]const Step) ![]const u8 {
    const s = steps orelse return "";
    if (s.len == 0) return "; it goes to no one else";
    return std.fmt.allocPrint(a, "; if you don't answer: {s}", .{try stepsText(a, s)});
}

/// A copy whose every slice is in `a`.
pub fn dupeSteps(a: Allocator, steps: []const Step) ![]const Step {
    const out = try a.alloc(Step, steps.len);
    for (steps, out) |x, *o| o.* = .{ .after_s = x.after_s, .member = try a.dupe(u8, x.member) };
    return out;
}

// ---- state/alerts ----

/// The owner's message an alert is (a post): where, and how many parts.
pub const Msg = struct { chat: i64 = 0, thread: i64 = 0, message: i64 = 0, count: u32 = 1 };

/// A member told: their conversation and the message with [I'm on it].
pub const Told = struct { member: []const u8, conv: []const u8 = "", chat: i64 = 0, thread: i64 = 0, message: i64 = 0, at: i64 = 0 };

/// An urgent routine's question that makes its safe call itself when
/// nobody is on it `after_s` seconds after it was asked: `item` answered
/// as the yes would be; `call` the call, for the log; `done` when.
pub const Fallback = struct { after_s: u32, item: u64, call: []const u8 = "", at: i64 = 0, done: i64 = 0 };

/// A line the house's speakers say (a trigger's `announce`, filled):
/// `by` that trigger (`trigger:NAME`), `server` its MCP server, `room`
/// the event's ("": every speaker).
pub const Speak = struct { by: []const u8 = "", server: []const u8 = "", text: []const u8, room: []const u8 = "" };

/// Who said they are on it (`owner`, `member:NAME`), when, and how (a
/// button, a reply, an answer to its question).
pub const Acked = struct { by: []const u8, at: i64, via: []const u8 };

/// An urgent alert: its first message to the owner, the question it is
/// (if any), whom it goes to next, and how it ended.
pub const Alert = struct {
    id: u64 = 0,
    /// In its [I'm on it] buttons: a press must carry it.
    token: []const u8 = "",
    at: i64,
    /// What made it: `trigger:NAME`, `workflow:NAME/STEP`.
    by: []const u8,
    /// One alert for each: `workflow NAME#N` (an instance), `trigger NAME#RID` (a run).
    key: []const u8,
    conv: []const u8 = "main",
    /// Its first line (masked): what members are told.
    text: []const u8,
    /// The post as sent (masked), for its message's edit; "": a question.
    body: []const u8 = "",
    private: bool = false,
    /// The question it is; 0: a post.
    item: u64 = 0,
    msg: ?Msg = null,
    steps: []const Step = &.{},
    /// Steps made so far.
    next: u32 = 0,
    told: []const Told = &.{},
    /// Members who could not be told.
    unreached: []const []const u8 = &.{},
    fallback: ?Fallback = null,
    speak: ?Speak = null,
    acked: ?Acked = null,
    /// Why it ended ("" while open): acknowledged, its question closed.
    ended: []const u8 = "",
};

/// The escalation of an urgent trigger's or workflow's alerts:
/// `trigger:NAME` or `workflow:NAME` and its steps.
pub const Plan = struct { key: []const u8, steps: []const Step };

/// What is due for an open alert.
pub const Due = union(enum) {
    /// Its step `index` (a member told).
    step: struct { id: u64, index: u32 },
    /// Its question made by harness.
    fallback: struct { id: u64, item: u64 },
};

/// An alert is kept this long after its first message (open or not).
pub const keep_s: i64 = 86400;

const File = struct { v: u32 = 1, next: u64 = 1, alerts: []const Alert = &.{} };

/// A copy of `x` whose every slice is in `a`.
pub fn copy(a: Allocator, x: Alert) !Alert {
    var o = x;
    inline for (.{ "token", "by", "key", "conv", "text", "body", "ended" }) |f| @field(o, f) = try a.dupe(u8, @field(x, f));
    o.steps = try dupeSteps(a, x.steps);
    const told = try a.alloc(Told, x.told.len);
    for (x.told, told) |y, *z| z.* = .{ .member = try a.dupe(u8, y.member), .conv = try a.dupe(u8, y.conv), .chat = y.chat, .thread = y.thread, .message = y.message, .at = y.at };
    o.told = told;
    const un = try a.alloc([]const u8, x.unreached.len);
    for (x.unreached, un) |y, *z| z.* = try a.dupe(u8, y);
    o.unreached = un;
    if (x.fallback) |f| o.fallback = .{ .after_s = f.after_s, .item = f.item, .call = try a.dupe(u8, f.call), .at = f.at, .done = f.done };
    if (x.speak) |sp| o.speak = .{ .by = try a.dupe(u8, sp.by), .server = try a.dupe(u8, sp.server), .text = try a.dupe(u8, sp.text), .room = try a.dupe(u8, sp.room) };
    if (x.acked) |k| o.acked = .{ .by = try a.dupe(u8, k.by), .at = k.at, .via = try a.dupe(u8, k.via) };
    return o;
}

/// The plan's key of `by`: `trigger:NAME` for a trigger's and a
/// schedule's runs, `workflow:NAME` for a workflow's steps; null: none.
pub fn planKey(buf: *[160]u8, by: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, by, ':') orelse return null;
    const kind = by[0..colon];
    var name = by[colon + 1 ..];
    if (std.mem.eql(u8, kind, "workflow")) {
        name = name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len];
        return std.fmt.bufPrint(buf, "workflow:{s}", .{name}) catch null;
    }
    if (std.mem.eql(u8, kind, "trigger") or std.mem.eql(u8, kind, "schedule")) return std.fmt.bufPrint(buf, "trigger:{s}", .{name}) catch null;
    return null;
}

fn samePlan(x: Plan, y: Plan) bool {
    if (!std.mem.eql(u8, x.key, y.key) or x.steps.len != y.steps.len) return false;
    for (x.steps, y.steps) |p, q| if (p.after_s != q.after_s or !std.mem.eql(u8, p.member, q.member)) return false;
    return true;
}

/// The alerts, as `state/alerts` keeps them, written whole after every
/// change; the plans (refreshed beside the urgent list); the speakers'
/// lines triggers said lately (in memory).
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    mutex: Io.Mutex = .init,
    /// Holds the alerts' strings; let go of once none is left.
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Alert) = .empty,
    next: u64 = 1,
    plans_arena: std.heap.ArenaAllocator,
    plans: []const Plan = &.{},
    /// The last line each urgent trigger said (`by`), and when.
    spoken_arena: std.heap.ArenaAllocator,
    spoken: std.ArrayList(struct { sp: Speak, at: i64 }) = .empty,

    pub fn init(gpa: Allocator, io: Io, path: []const u8) Store {
        return .{ .gpa = gpa, .io = io, .path = path, .arena = .init(gpa), .plans_arena = .init(gpa), .spoken_arena = .init(gpa) };
    }

    pub fn deinit(s: *Store) void {
        s.list.deinit(s.gpa);
        s.spoken.deinit(s.gpa);
        s.arena.deinit();
        s.plans_arena.deinit();
        s.spoken_arena.deinit();
    }

    /// Reads the file (none: no alert).
    pub fn load(s: *Store) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const a = s.arena.allocator();
        const text = Io.Dir.cwd().readFileAlloc(s.io, s.path, a, .limited(16 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        const f = try std.json.parseFromSliceLeaky(File, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        s.list.clearRetainingCapacity();
        try s.list.appendSlice(s.gpa, f.alerts);
        s.next = f.next;
        for (f.alerts) |x| s.next = @max(s.next, x.id + 1);
    }

    /// Writes the file whole (under the mutex).
    fn save(s: *Store) !void {
        var tmp: std.heap.ArenaAllocator = .init(s.gpa);
        defer tmp.deinit();
        const text = try std.json.Stringify.valueAlloc(tmp.allocator(), File{ .next = s.next, .alerts = s.list.items }, .{});
        try util.writeReplace(s.io, s.path, try std.fmt.allocPrint(tmp.allocator(), "{s}\n", .{text}));
    }

    fn find(s: *Store, id: u64) ?*Alert {
        for (s.list.items) |*x| if (x.id == id) return x;
        return null;
    }

    /// The plans from now on, when they differ from those kept.
    pub fn setPlans(s: *Store, plans: []const Plan) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const same = plans.len == s.plans.len and for (plans, s.plans) |x, y| {
            if (!samePlan(x, y)) break false;
        } else true;
        if (same) return;
        _ = s.plans_arena.reset(.retain_capacity);
        const a = s.plans_arena.allocator();
        const out = try a.alloc(Plan, plans.len);
        for (plans, out) |p, *o| o.* = .{ .key = try a.dupe(u8, p.key), .steps = try dupeSteps(a, p.steps) };
        s.plans = out;
    }

    /// The escalation of what `by` made, in `a`; null when it is not urgent.
    pub fn planFor(s: *Store, a: Allocator, by: []const u8) ?[]const Step {
        var buf: [160]u8 = undefined;
        const key = planKey(&buf, by) orelse return null;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.plans) |p| if (std.mem.eql(u8, p.key, key)) return dupeSteps(a, p.steps) catch null;
        return null;
    }

    /// Notes the line trigger `sp.by` said now.
    pub fn noteSpeak(s: *Store, sp: Speak, now: i64) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.spoken.items.len >= 64) {
            s.spoken.clearRetainingCapacity();
            _ = s.spoken_arena.reset(.retain_capacity);
        }
        const a = s.spoken_arena.allocator();
        const owned: Speak = .{ .by = a.dupe(u8, sp.by) catch return, .server = a.dupe(u8, sp.server) catch return, .text = a.dupe(u8, sp.text) catch return, .room = a.dupe(u8, sp.room) catch return };
        for (s.spoken.items) |*x| if (std.mem.eql(u8, x.sp.by, sp.by)) {
            x.* = .{ .sp = owned, .at = now };
            return;
        };
        s.spoken.append(s.gpa, .{ .sp = owned, .at = now }) catch {};
    }

    /// The line trigger `by` said in the last 10 minutes, in `a`.
    pub fn speakOf(s: *Store, a: Allocator, by: []const u8, now: i64) ?Speak {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.spoken.items) |x| if (std.mem.eql(u8, x.sp.by, by) and now - x.at <= 600)
            return .{ .by = a.dupe(u8, x.sp.by) catch return null, .server = a.dupe(u8, x.sp.server) catch return null, .text = a.dupe(u8, x.sp.text) catch return null, .room = a.dupe(u8, x.sp.room) catch return null };
        return null;
    }

    /// Adds alert `x` (its id and token given here), written; its id.
    pub fn add(s: *Store, x: Alert) !u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var raw: [8]u8 = undefined;
        s.io.random(&raw);
        var o = try copy(s.arena.allocator(), x);
        o.id = s.next;
        o.token = try s.arena.allocator().dupe(u8, &std.fmt.bytesToHex(raw, .lower));
        try s.list.append(s.gpa, o);
        s.next += 1;
        errdefer _ = s.list.pop();
        try s.save();
        return o.id;
    }

    /// A copy of alert `id` in `a`.
    pub fn get(s: *Store, a: Allocator, id: u64) ?Alert {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return null;
        return copy(a, x.*) catch null;
    }

    /// The alert of `key` (open or ended), its id.
    pub fn byKey(s: *Store, key: []const u8) ?u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.list.items) |x| if (std.mem.eql(u8, x.key, key)) return x.id;
        return null;
    }

    /// The open alert whose question is `item`.
    pub fn byItem(s: *Store, item: u64) ?u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.list.items) |x| if (x.item == item and x.ended.len == 0) return x.id;
        return null;
    }

    /// The open alert whose post is message `message` in `chat`.
    pub fn byMessage(s: *Store, chat: i64, message: i64) ?u64 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.list.items) |x| if (x.ended.len == 0) if (x.msg) |m| if (m.chat == chat and message >= m.message and message < m.message + m.count) return x.id;
        return null;
    }

    /// Alert `id`'s post went out as `m`.
    pub fn setMsg(s: *Store, id: u64, m: Msg) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return;
        x.msg = m;
        try s.save();
    }

    /// Alert `id`'s question makes its call itself after `f.after_s`.
    pub fn setFallback(s: *Store, id: u64, f: Fallback) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return;
        x.fallback = .{ .after_s = f.after_s, .item = f.item, .call = try s.arena.allocator().dupe(u8, f.call), .at = if (f.at != 0) f.at else x.at, .done = f.done };
        try s.save();
    }

    /// Step `index` of alert `id` was made: `told` (null: the member
    /// could not be told, `member` named in `unreached`).
    pub fn stepMade(s: *Store, id: u64, index: u32, member: []const u8, told: ?Told) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return;
        const a = s.arena.allocator();
        x.next = @max(x.next, index + 1);
        if (told) |y| {
            x.told = try std.mem.concat(a, Told, &.{ x.told, &[_]Told{.{ .member = try a.dupe(u8, y.member), .conv = try a.dupe(u8, y.conv), .chat = y.chat, .thread = y.thread, .message = y.message, .at = y.at }} });
        } else x.unreached = try std.mem.concat(a, []const u8, &.{ x.unreached, &[_][]const u8{try a.dupe(u8, member)} });
        try s.save();
    }

    /// Alert `id`'s fallback was made at `at`.
    pub fn fallbackMade(s: *Store, id: u64, at: i64) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return;
        if (x.fallback) |*f| f.done = at;
        try s.save();
    }

    /// Someone is on alert `id`: noted, and it ends; a copy of it as it
    /// was (in `a`), or null when it was not open.
    pub fn ack(s: *Store, a: Allocator, id: u64, k: Acked) !?Alert {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return null;
        if (x.ended.len > 0) return null;
        const was = try copy(a, x.*);
        const ar = s.arena.allocator();
        x.acked = .{ .by = try ar.dupe(u8, k.by), .at = k.at, .via = try ar.dupe(u8, k.via) };
        x.ended = "acknowledged";
        try s.save();
        return was;
    }

    /// Alert `id` ends for `why` (its question closed): nothing more is due.
    pub fn end(s: *Store, id: u64, why: []const u8) !bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const x = s.find(id) orelse return false;
        if (x.ended.len > 0) return false;
        x.ended = try s.arena.allocator().dupe(u8, why);
        try s.save();
        return true;
    }

    /// What is due at `now`, in order: the steps due (all of them, after
    /// a restart), then a fallback. Alerts past `keep_s` are dropped.
    pub fn due(s: *Store, a: Allocator, now: i64) ![]Due {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var out: std.ArrayList(Due) = .empty;
        var i: usize = 0;
        var dropped = false;
        while (i < s.list.items.len) {
            const x = s.list.items[i];
            if (now - x.at >= keep_s) {
                _ = s.list.orderedRemove(i);
                dropped = true;
                continue;
            }
            i += 1;
            if (x.ended.len > 0) continue;
            var k = x.next;
            while (k < x.steps.len and now >= x.at + x.steps[k].after_s) : (k += 1) try out.append(a, .{ .step = .{ .id = x.id, .index = k } });
            if (x.fallback) |f| if (f.done == 0 and now >= (if (f.at != 0) f.at else x.at) + f.after_s) try out.append(a, .{ .fallback = .{ .id = x.id, .item = f.item } });
        }
        if (dropped) {
            if (s.list.items.len == 0) {
                s.list.clearRetainingCapacity();
                _ = s.arena.reset(.retain_capacity);
            }
            try s.save();
        }
        return out.items;
    }
};

// ---- tests ----

const t = std.testing;

test "escalate_reads_steps_or_no" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const two = try parseEscalate(a, "5m anna, 15m piotr", &why);
    try t.expectEqual(2, two.len);
    try t.expectEqual(300, two[0].after_s);
    try t.expectEqualStrings("anna", two[0].member);
    try t.expectEqual(900, two[1].after_s);
    try t.expectEqualStrings("piotr", two[1].member);
    try t.expectEqual(3600, (try parseEscalate(a, " 1h  anna ", &why))[0].after_s);
    try t.expectEqual(0, (try parseEscalate(a, "no", &why)).len);
    try t.expectEqual(0, (try parseEscalate(a, "off", &why)).len);
    try t.expectEqualStrings("anna after 5 min, then piotr after 15 min", try stepsText(a, two));
    const lines = [_][2][]const u8{
        .{ "", "DURATION MEMBER" },
        .{ "anna", "DURATION MEMBER" },
        .{ "5m", "DURATION MEMBER" },
        .{ "5 anna", "a duration like 5m or 1h" },
        .{ "30s anna", "from 1 minute to 24 hours" },
        .{ "25h anna", "from 1 minute to 24 hours" },
        .{ "15m piotr, 5m anna", "each later than the one before" },
        .{ "5m anna, 10m anna", "anna comes twice" },
        .{ "5m Anna", "a member's name" },
        .{ "1m a, 2m b, 3m c, 4m d, 5m e, 6m f", "at most 5" },
        .{ "5m anna and piotr", "DURATION MEMBER" },
    };
    for (lines) |b| {
        why = "";
        if (parseEscalate(a, b[0], &why)) |_| {
            std.debug.print("read: {s}\n", .{b[0]});
            return error.TestUnexpectedResult;
        } else |e| try t.expectEqual(error.BadEscalate, e);
        if (std.mem.indexOf(u8, why, b[1]) == null) {
            std.debug.print("{s}: wanted \"{s}\", got \"{s}\"\n", .{ b[0], b[1], why });
            return error.TestUnexpectedResult;
        }
    }
}

test "the_store_keeps_alerts_across_a_load" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "alerts" });
    var s: Store = .init(t.allocator, t.io, path);
    defer s.deinit();
    // the plans: only what is in them is urgent
    try s.setPlans(&.{ .{ .key = "workflow:leak", .steps = &.{ .{ .after_s = 300, .member = "anna" }, .{ .after_s = 900, .member = "piotr" } } }, .{ .key = "trigger:smoke", .steps = &.{} } });
    try t.expectEqual(2, s.planFor(a, "workflow:leak/ask").?.len);
    try t.expectEqual(0, s.planFor(a, "schedule:smoke").?.len);
    try t.expect(s.planFor(a, "workflow:door-open/tell") == null);
    try t.expect(s.planFor(a, "owner") == null);
    const t0: i64 = 1_800_000_000;
    const id = try s.add(.{ .at = t0, .by = "workflow:leak/ask", .key = "workflow leak#1", .text = "Water leak: Sink leak, Kitchen.", .item = 7, .steps = s.planFor(a, "workflow:leak/ask").? });
    try s.setFallback(id, .{ .after_s = 300, .item = 7, .call = "home/home_guarded {\"device\": \"water_main\", \"action\": \"close\"}" });
    try t.expectEqual(0, (try s.due(a, t0 + 299)).len);
    // at 5 minutes: anna, then the fallback
    const d5 = try s.due(a, t0 + 300);
    try t.expectEqual(2, d5.len);
    try t.expectEqual(0, d5[0].step.index);
    try t.expectEqual(7, d5[1].fallback.item);
    try s.stepMade(id, 0, "anna", .{ .member = "anna", .conv = "anna", .chat = 77, .message = 9, .at = t0 + 300 });
    try s.fallbackMade(id, t0 + 301);
    try t.expectEqual(0, (try s.due(a, t0 + 400)).len);
    // a restart: read back as it was; piotr due at 15 minutes
    var s2: Store = .init(t.allocator, t.io, path);
    defer s2.deinit();
    try s2.load();
    const back = s2.get(a, id).?;
    try t.expectEqualStrings("Water leak: Sink leak, Kitchen.", back.text);
    try t.expectEqual(16, back.token.len);
    try t.expectEqualStrings("anna", back.told[0].member);
    try t.expectEqual(t0 + 301, back.fallback.?.done);
    try t.expectEqual(id, s2.byItem(7).?);
    const d15 = try s2.due(a, t0 + 900);
    try t.expectEqual(1, d15.len);
    try t.expectEqual(1, d15[0].step.index);
    // on it: it ends; a second acknowledgement finds it ended
    try t.expect((try s2.ack(a, id, .{ .by = "member:anna", .at = t0 + 905, .via = "button" })) != null);
    try t.expect((try s2.ack(a, id, .{ .by = "owner", .at = t0 + 906, .via = "reply" })) == null);
    try t.expectEqual(0, (try s2.due(a, t0 + 1000)).len);
    try t.expect(s2.byItem(7) == null);
    // kept a day for its key, then dropped
    try t.expectEqual(id, s2.byKey("workflow leak#1").?);
    _ = try s2.due(a, t0 + keep_s);
    try t.expect(s2.byKey("workflow leak#1") == null);
    // a post: found by its messages
    const p = try s2.add(.{ .at = t0, .by = "trigger:smoke", .key = "trigger smoke#5", .text = "Smoke alarm.", .steps = &.{.{ .after_s = 60, .member = "anna" }} });
    try s2.setMsg(p, .{ .chat = 42, .message = 100, .count = 2 });
    try t.expectEqual(p, s2.byMessage(42, 101).?);
    try t.expect(s2.byMessage(42, 102) == null);
    try t.expect(s2.byMessage(43, 100) == null);
}

//! A workflow's instances on disk, `state/workflows/NAME/`: `next` (the
//! next instance's number), `line` (starts waiting for a place, JSON
//! lines) and a folder per instance, `N/`: `workflow.wf` (the file as it
//! was when the instance started: it ends on that version), `state`
//! (JSON, rewritten whole before the instance acts on it) and `journal`
//! (JSON lines appended: each step's start and end, 2 KB of result).
//! `state/workflows/day.json` counts today's agent steps. Every file
//! rewritten whole goes through `writeReplace`.
const std = @import("std");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How an instance is: `running` (a step runs, or runs at the next tick),
/// `waiting` (a timer, a retry, an event, an inbox item, the next day),
/// `paused` (a step was cut off: an `interrupted` item waits), `failed`
/// (a step failed: a `failed` item may still run it again), and the ends,
/// `done` and `stopped`.
pub const Status = enum { running, waiting, paused, done, failed, stopped };

pub const WaitKind = enum { none, timer, retry, event, item, day };

pub const Wait = struct {
    kind: WaitKind = .none,
    /// When it is over (a timer, a retry, the next day) or times out (an
    /// event; an item's own expiry is the inbox's); 0: never.
    until: i64 = 0,
    /// The inbox item it waits on.
    item: u64 = 0,
    /// What the item asks: `approval` (a tool step's call, as the gate
    /// asked it), `approve`, `review`, `interrupted`, `failed`.
    phase: []const u8 = "",
    /// The trigger whose next matching event it waits for.
    trigger: []const u8 = "",
    /// Since when it waits (of those waiting on a trigger, the one waiting
    /// longest gets an event first).
    since: i64 = 0,
    /// An event came: its fields, a JSON object, in `event`.
    got: bool = false,
    event: []const u8 = "",
    /// An `approval`'s question, its SHA-256: the owner's answer goes to
    /// that question alone when the call is decided again.
    ask: []const u8 = "",
};

/// The owner's answer to one question of a step's call: the question's
/// SHA-256 (hex), `once` or `day`, the item it was asked in.
pub const Answer = struct { ask: []const u8, key: []const u8, item: u64 = 0 };

pub const State = struct {
    name: []const u8,
    n: u32,
    status: Status = .running,
    /// The step it is at: the one to run, under way, or waited on.
    step: []const u8 = "",
    /// Which try of that step (1 the first).
    try_n: u32 = 1,
    /// Steps run, each try and each visit counted.
    steps: u32 = 0,
    /// The step's action had begun when this was written: a restart finds
    /// it cut off.
    under_way: bool = false,
    wait: Wait = .{},
    /// A tool step's (or a say's) input as the owner was asked about it.
    call: []const u8 = "",
    /// The owner's answers to that call's questions so far, each for its
    /// own question: the call is decided again with them all.
    answers: []const Answer = &.{},
    /// Who started it, and the definition when the workflow tool did.
    by: []const u8 = "owner",
    agent: []const u8 = "",
    /// The start's text, or the event as text.
    input: []const u8 = "",
    started: i64 = 0,
    updated: i64 = 0,
    ended: i64 = 0,
    /// When it runs out of days (its `days`): it fails then, waiting or not.
    ends: i64 = 0,
    /// How it ended, or why it waits.
    why: []const u8 = "",
    /// The values its steps left, a JSON object (with `input`, `event`,
    /// `instance`).
    values: []const u8 = "{}",
    /// Minutes nobody answered before a fallback made a call: its next
    /// say begins "No one answered in N minutes: "; 0: none.
    absent: u32 = 0,

    /// A copy whose every slice is in `a`.
    pub fn clone(s: State, a: Allocator) !State {
        var o = s;
        inline for (.{ "name", "step", "call", "by", "agent", "input", "why", "values" }) |f| @field(o, f) = try a.dupe(u8, @field(s, f));
        inline for (.{ "phase", "trigger", "event", "ask" }) |f| @field(o.wait, f) = try a.dupe(u8, @field(s.wait, f));
        const answers = try a.alloc(Answer, s.answers.len);
        for (s.answers, answers) |x, *y| y.* = .{ .ask = try a.dupe(u8, x.ask), .key = try a.dupe(u8, x.key), .item = x.item };
        o.answers = answers;
        return o;
    }

    /// Going: running, waiting or paused (failed, done and stopped are not).
    pub fn live(s: State) bool {
        return s.status == .running or s.status == .waiting or s.status == .paused;
    }

    /// Ended for good: done or stopped (a failed one may run its step again).
    pub fn ended_for_good(s: State) bool {
        return s.status == .done or s.status == .stopped;
    }
};

/// "NAME#N".
pub fn idOf(a: Allocator, name: []const u8, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}#{d}", .{ name, n });
}

/// "NAME#N" read back; null when it is none.
pub fn parseId(id: []const u8) ?struct { name: []const u8, n: u32 } {
    const hash = std.mem.indexOfScalar(u8, id, '#') orelse return null;
    const n = std.fmt.parseInt(u32, id[hash + 1 ..], 10) catch return null;
    if (hash == 0 or n == 0) return null;
    return .{ .name = id[0..hash], .n = n };
}

/// An instance's state as its file holds it.
pub fn stateJson(a: Allocator, s: State) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"v\":1,\"name\":");
    try util.jsonString(&out, a, s.name);
    try out.print(a, ",\"n\":{d},\"status\":\"{s}\",\"step\":", .{ s.n, @tagName(s.status) });
    try util.jsonString(&out, a, s.step);
    try out.print(a, ",\"try\":{d},\"steps\":{d},\"under_way\":{},\"wait\":{{\"kind\":\"{s}\",\"until\":{d},\"item\":{d},\"phase\":", .{ s.try_n, s.steps, s.under_way, @tagName(s.wait.kind), s.wait.until, s.wait.item });
    try util.jsonString(&out, a, s.wait.phase);
    try out.appendSlice(a, ",\"trigger\":");
    try util.jsonString(&out, a, s.wait.trigger);
    try out.print(a, ",\"since\":{d},\"got\":{},\"event\":", .{ s.wait.since, s.wait.got });
    try out.appendSlice(a, if (s.wait.event.len > 0) s.wait.event else "null");
    try out.appendSlice(a, ",\"ask\":");
    try util.jsonString(&out, a, s.wait.ask);
    try out.appendSlice(a, "},\"call\":");
    try util.jsonString(&out, a, s.call);
    try out.appendSlice(a, ",\"answers\":[");
    for (s.answers, 0..) |x, i| {
        try out.appendSlice(a, if (i > 0) ",{\"ask\":" else "{\"ask\":");
        try util.jsonString(&out, a, x.ask);
        try out.appendSlice(a, ",\"key\":");
        try util.jsonString(&out, a, x.key);
        try out.print(a, ",\"item\":{d}}}", .{x.item});
    }
    try out.appendSlice(a, "]");
    inline for (.{ "by", "agent", "input" }) |f| {
        try out.print(a, ",\"{s}\":", .{f});
        try util.jsonString(&out, a, @field(s, f));
    }
    try out.print(a, ",\"started\":{d},\"updated\":{d},\"ended\":{d},\"ends\":{d},\"why\":", .{ s.started, s.updated, s.ended, s.ends });
    try util.jsonString(&out, a, s.why);
    try out.appendSlice(a, ",\"values\":");
    try out.appendSlice(a, if (s.values.len > 0) s.values else "{}");
    if (s.absent > 0) try out.print(a, ",\"absent\":{d}", .{s.absent});
    try out.appendSlice(a, "}\n");
    return out.items;
}

/// An instance's state from its file's text; null when it does not read.
pub fn parseState(a: Allocator, text: []const u8) ?State {
    const v = jv.parse(a, text) orelse return null;
    if (v != .object) return null;
    const name = jv.str(jv.get(v, "name")) orelse return null;
    const n = jv.int(jv.get(v, "n")) orelse return null;
    if (n <= 0 or n > std.math.maxInt(u32)) return null;
    var s: State = .{ .name = name, .n = @intCast(n) };
    s.status = std.meta.stringToEnum(Status, jv.str(jv.get(v, "status")) orelse "") orelse return null;
    s.step = jv.str(jv.get(v, "step")) orelse "";
    // a file changed by hand reads in bounds: tries from 1, times from 0
    s.try_n = @max(1, count(jv.get(v, "try"), 1));
    s.steps = count(jv.get(v, "steps"), 0);
    s.under_way = jv.boolean(jv.get(v, "under_way")) orelse false;
    if (jv.get(v, "wait")) |w| {
        s.wait.kind = std.meta.stringToEnum(WaitKind, jv.str(jv.get(w, "kind")) orelse "") orelse .none;
        s.wait.until = time(jv.get(w, "until"));
        s.wait.item = @intCast(@max(0, jv.int(jv.get(w, "item")) orelse 0));
        s.wait.phase = jv.str(jv.get(w, "phase")) orelse "";
        s.wait.trigger = jv.str(jv.get(w, "trigger")) orelse "";
        s.wait.since = time(jv.get(w, "since"));
        s.wait.got = jv.boolean(jv.get(w, "got")) orelse false;
        if (jv.get(w, "event")) |e| s.wait.event = std.json.Stringify.valueAlloc(a, e, .{}) catch return null;
        s.wait.ask = jv.str(jv.get(w, "ask")) orelse "";
    }
    s.call = jv.str(jv.get(v, "call")) orelse "";
    if (jv.get(v, "answers")) |arr| if (arr == .array) {
        var list: std.ArrayList(Answer) = .empty;
        for (arr.array.items) |x| list.append(a, .{
            .ask = jv.str(jv.get(x, "ask")) orelse continue,
            .key = jv.str(jv.get(x, "key")) orelse continue,
            .item = @intCast(@max(0, jv.int(jv.get(x, "item")) orelse 0)),
        }) catch return null;
        s.answers = list.items;
    };
    s.by = jv.str(jv.get(v, "by")) orelse "owner";
    s.agent = jv.str(jv.get(v, "agent")) orelse "";
    s.input = jv.str(jv.get(v, "input")) orelse "";
    s.started = time(jv.get(v, "started"));
    s.updated = time(jv.get(v, "updated"));
    s.ended = time(jv.get(v, "ended"));
    s.ends = time(jv.get(v, "ends"));
    s.absent = count(jv.get(v, "absent"), 0);
    s.why = jv.str(jv.get(v, "why")) orelse "";
    const values = jv.get(v, "values") orelse jv.Value{ .object = .empty };
    if (values != .object) return null;
    s.values = std.json.Stringify.valueAlloc(a, values, .{}) catch return null;
    return s;
}

fn time(v: ?jv.Value) i64 {
    return @max(0, jv.int(v) orelse 0);
}

fn count(v: ?jv.Value, default: u32) u32 {
    const x = jv.int(v) orelse return default;
    return @intCast(std.math.clamp(x, 0, std.math.maxInt(u32)));
}

/// Writes `data` to `path` whole (util.writeReplace: a temporary file
/// next to it, synced, then a rename, retried on Windows while another
/// program holds the file), so a crash leaves the old file or the new
/// one, never half. The one function every rewritten workflow file goes
/// through.
pub fn writeReplace(io: Io, a: Allocator, path: []const u8, data: []const u8) !void {
    _ = a;
    return util.writeReplace(io, path, data);
}

/// A start waiting for a place (`line`): who, the definition (the
/// workflow tool's), the text, the event's fields (a JSON object, "" for
/// none), when it came.
pub const Start = struct {
    at: i64,
    by: []const u8,
    agent: []const u8 = "",
    input: []const u8 = "",
    event: []const u8 = "",
    /// Started by the workflow tool (the start line's `agent`).
    tool: bool = false,
};

fn startJson(a: Allocator, s: Start) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{\"at\":{d},\"by\":", .{s.at});
    try util.jsonString(&out, a, s.by);
    try out.appendSlice(a, ",\"agent\":");
    try util.jsonString(&out, a, s.agent);
    try out.appendSlice(a, ",\"input\":");
    try util.jsonString(&out, a, s.input);
    try out.appendSlice(a, ",\"event\":");
    try out.appendSlice(a, if (s.event.len > 0) s.event else "null");
    try out.print(a, ",\"tool\":{}}}\n", .{s.tool});
    return out.items;
}

/// `state/workflows/NAME`.
pub const Dir = struct {
    io: Io,
    path: []const u8,

    fn file(d: Dir, a: Allocator, name: []const u8) ![]const u8 {
        return std.fs.path.join(a, &.{ d.path, name });
    }

    /// The next instance's number, counted on: `next` holds it (written
    /// before the instance's folder is made), else one past the highest
    /// folder there.
    pub fn nextNumber(d: Dir, a: Allocator) !u32 {
        try Io.Dir.cwd().createDirPath(d.io, d.path);
        const p = try d.file(a, "next");
        var n: u32 = 1;
        if (Io.Dir.cwd().readFileAlloc(d.io, p, a, .limited(64))) |text| {
            n = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \r\n"), 10) catch 1;
        } else |_| {}
        for (try d.numbers(a)) |x| n = @max(n, x + 1);
        try writeReplace(d.io, a, p, try std.fmt.allocPrint(a, "{d}\n", .{n + 1}));
        return n;
    }

    pub fn instance(d: Dir, a: Allocator, n: u32) !Instance {
        return .{ .io = d.io, .path = try std.fs.path.join(a, &.{ d.path, try std.fmt.allocPrint(a, "{d}", .{n}) }) };
    }

    /// The instances' numbers there, lowest first.
    pub fn numbers(d: Dir, a: Allocator) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        var dir = Io.Dir.cwd().openDir(d.io, d.path, .{ .iterate = true }) catch return out.items;
        defer dir.close(d.io);
        var it = dir.iterate();
        while (it.next(d.io) catch null) |e| {
            if (e.kind != .directory) continue;
            const n = std.fmt.parseInt(u32, e.name, 10) catch continue;
            if (n > 0) try out.append(a, n);
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        return out.items;
    }

    /// The starts waiting for a place, oldest first.
    pub fn loadLine(d: Dir, a: Allocator) ![]Start {
        var out: std.ArrayList(Start) = .empty;
        const text = Io.Dir.cwd().readFileAlloc(d.io, try d.file(a, "line"), a, .limited(16 << 20)) catch return out.items;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const v = jv.parse(a, line) orelse continue;
            if (v != .object) continue;
            try out.append(a, .{
                .at = jv.int(jv.get(v, "at")) orelse 0,
                .by = jv.str(jv.get(v, "by")) orelse continue,
                .agent = jv.str(jv.get(v, "agent")) orelse "",
                .input = jv.str(jv.get(v, "input")) orelse "",
                .event = if (jv.get(v, "event")) |e| try std.json.Stringify.valueAlloc(a, e, .{}) else "",
                .tool = jv.boolean(jv.get(v, "tool")) orelse false,
            });
        }
        return out.items;
    }

    fn saveLine(d: Dir, a: Allocator, starts: []const Start) !void {
        try Io.Dir.cwd().createDirPath(d.io, d.path);
        var out: std.ArrayList(u8) = .empty;
        for (starts) |s| try out.appendSlice(a, try startJson(a, s));
        try writeReplace(d.io, a, try d.file(a, "line"), out.items);
    }

    /// Adds a start at the end of the line; null when `max` wait already.
    /// Else how many wait now.
    pub fn pushLine(d: Dir, a: Allocator, s: Start, max: usize) !?usize {
        const now = try d.loadLine(a);
        if (now.len >= max) return null;
        const all = try a.alloc(Start, now.len + 1);
        @memcpy(all[0..now.len], now);
        all[now.len] = s;
        try d.saveLine(a, all);
        return all.len;
    }

    /// Takes the oldest start off the line (written before it is acted on).
    pub fn popLine(d: Dir, a: Allocator) !?Start {
        const now = try d.loadLine(a);
        if (now.len == 0) return null;
        try d.saveLine(a, now[1..]);
        return now[0];
    }
};

/// One instance's folder, `state/workflows/NAME/N`.
pub const Instance = struct {
    io: Io,
    path: []const u8,

    fn file(i: Instance, a: Allocator, name: []const u8) ![]const u8 {
        return std.fs.path.join(a, &.{ i.path, name });
    }

    /// Makes the folder with the workflow's file as it is now and the
    /// first state.
    pub fn create(i: Instance, a: Allocator, wf_text: []const u8, s: State) !void {
        try Io.Dir.cwd().createDirPath(i.io, i.path);
        try writeReplace(i.io, a, try i.file(a, "workflow.wf"), wf_text);
        try i.saveState(a, s);
    }

    pub fn loadState(i: Instance, a: Allocator) !State {
        const text = try Io.Dir.cwd().readFileAlloc(i.io, try i.file(a, "state"), a, .limited(8 << 20));
        return parseState(a, text) orelse error.BadState;
    }

    pub fn saveState(i: Instance, a: Allocator, s: State) !void {
        try writeReplace(i.io, a, try i.file(a, "state"), try stateJson(a, s));
    }

    /// The workflow's file as it was when the instance started.
    pub fn workflowText(i: Instance, a: Allocator) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(i.io, try i.file(a, "workflow.wf"), a, .limited(1 << 20));
    }

    /// Adds a line to the journal.
    pub fn journal(i: Instance, a: Allocator, e: Entry) !void {
        try Io.Dir.cwd().createDirPath(i.io, i.path);
        const p = try i.file(a, "journal");
        var f = try Io.Dir.cwd().createFile(i.io, p, .{ .truncate = false, .permissions = util.private_file });
        defer f.close(i.io);
        try f.writePositionalAll(i.io, try entryJson(a, e), try f.length(i.io));
    }

    /// The journal's last `max` bytes, whole lines.
    pub fn readJournal(i: Instance, a: Allocator, max: usize) ![]const u8 {
        const text = Io.Dir.cwd().readFileAlloc(i.io, try i.file(a, "journal"), a, .limited(64 << 20)) catch return "";
        if (text.len <= max) return text;
        const from = text.len - max;
        const nl = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse return "";
        return text[nl + 1 ..];
    }

    pub fn remove(i: Instance) void {
        Io.Dir.cwd().deleteTree(i.io, i.path) catch {};
    }
};

/// A journal line: when, the step and try, what happened (`start`, `end`,
/// `wait`, `inbox`, `retry`, `resume`, `stopped`, `done`, `failed`), whether it went
/// well, and up to 2 KB of its result or why.
pub const Entry = struct {
    at: i64 = 0,
    step: []const u8 = "",
    try_n: u32 = 0,
    event: []const u8,
    ok: ?bool = null,
    text: []const u8 = "",
};

pub const journal_text_max = 2048;

fn entryJson(a: Allocator, e: Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tb: [20]u8 = undefined;
    try out.print(a, "{{\"at\":\"{s}\",\"step\":", .{util.isoTime(&tb, e.at)});
    try util.jsonString(&out, a, e.step);
    try out.print(a, ",\"try\":{d},\"event\":", .{e.try_n});
    try util.jsonString(&out, a, e.event);
    if (e.ok) |ok| try out.print(a, ",\"ok\":{}", .{ok});
    if (e.text.len > 0) {
        try out.appendSlice(a, ",\"text\":");
        try util.jsonString(&out, a, util.cut(e.text, journal_text_max));
    }
    try out.appendSlice(a, "}\n");
    return out.items;
}

/// Today's agent steps, all workflows together (`day.json`).
pub const Day = struct { day: i64 = 0, agent_steps: u32 = 0, told: bool = false };

pub fn loadDay(io: Io, a: Allocator, path: []const u8) Day {
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)) catch return .{};
    const v = jv.parse(a, text) orelse return .{};
    return .{ .day = jv.int(jv.get(v, "day")) orelse 0, .agent_steps = count(jv.get(v, "agent_steps"), 0), .told = jv.boolean(jv.get(v, "told")) orelse false };
}

pub fn saveDay(io: Io, a: Allocator, path: []const u8, d: Day) !void {
    try writeReplace(io, a, path, try std.fmt.allocPrint(a, "{{\"day\":{d},\"agent_steps\":{d},\"told\":{}}}\n", .{ d.day, d.agent_steps, d.told }));
}

// ---- tests ----

const t = std.testing;

const Fix = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init(f: *Fix) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        f.root = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.arena.allocator());
    }

    fn deinit(f: *Fix) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn dir(f: *Fix, name: []const u8) !Dir {
        return .{ .io = t.io, .path = try std.fs.path.join(f.arena.allocator(), &.{ f.root, name }) };
    }
};

test "state_is_written_whole_and_read_back" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const d = try f.dir("issue-reply");
    const n = try d.nextNumber(a);
    try t.expectEqual(1, n);
    const inst = try d.instance(a, n);
    const s: State = .{
        .name = "issue-reply",
        .n = n,
        .status = .waiting,
        .step = "ask",
        .try_n = 2,
        .steps = 5,
        .under_way = true,
        .wait = .{ .kind = .event, .until = 1_800_000_000, .item = 41, .phase = "approve", .trigger = "issues", .since = 1_700_000_000, .got = true, .event = "{\"number\":42,\"title\":\"x\"}", .ask = "ab12" },
        .call = "{\"text\":\"hi\"}",
        .by = "trigger:issues",
        .agent = "main",
        .input = "number: 42\ntitle: x",
        .started = 1_700_000_000,
        .updated = 1_700_000_100,
        .ended = 0,
        .ends = 1_700_604_800,
        .answers = &.{ .{ .ask = "ab12", .key = "once", .item = 40 }, .{ .ask = "cd34", .key = "day", .item = 41 } },
        .why = "waits for item 41",
        .values = "{\"draft\":{\"reply\":\"thanks\"},\"draft.ok\":true}",
    };
    try inst.create(a, "workflow issue-reply\nstep a\nsay hi\n", s);
    const back = try inst.loadState(a);
    try t.expectEqualDeep(s, back);
    try t.expectEqualStrings("workflow issue-reply\nstep a\nsay hi\n", try inst.workflowText(a));
    // whole: no temporary file left
    try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, try std.fs.path.join(a, &.{ inst.path, "state.tmp" }), .{}));
    try t.expectEqualStrings("issue-reply", parseId("issue-reply#12").?.name);
    try t.expectEqual(12, parseId("issue-reply#12").?.n);
    try t.expect(parseId("issue-reply") == null and parseId("x#0") == null);
}

test "the_line_keeps_its_order_and_its_cap" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const d = try f.dir("w");
    try t.expectEqual(1, (try d.pushLine(a, .{ .at = 1, .by = "owner", .input = "first" }, 2)).?);
    try t.expectEqual(2, (try d.pushLine(a, .{ .at = 2, .by = "trigger:x", .event = "{\"title\":\"t\"}" }, 2)).?);
    try t.expectEqual(null, try d.pushLine(a, .{ .at = 3, .by = "owner" }, 2));
    const one = (try d.popLine(a)).?;
    try t.expectEqualStrings("first", one.input);
    const two = (try d.popLine(a)).?;
    try t.expectEqualStrings("trigger:x", two.by);
    try t.expectEqualStrings("{\"title\":\"t\"}", two.event);
    try t.expectEqual(null, try d.popLine(a));
}

test "numbers_go_on_and_the_journal_appends" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const d = try f.dir("w");
    try t.expectEqual(1, try d.nextNumber(a));
    try t.expectEqual(2, try d.nextNumber(a));
    // a folder past `next` (a copied folder): numbers go on past it
    try Io.Dir.cwd().createDirPath(t.io, try std.fs.path.join(a, &.{ d.path, "7" }));
    try t.expectEqual(8, try d.nextNumber(a));
    try t.expectEqualSlices(u32, &.{7}, try d.numbers(a));
    const inst = try d.instance(a, 7);
    try inst.journal(a, .{ .at = 0, .step = "a", .try_n = 1, .event = "start" });
    const long = try a.alloc(u8, 3000);
    @memset(long, 'x');
    try inst.journal(a, .{ .at = 0, .step = "a", .try_n = 1, .event = "end", .ok = true, .text = long });
    const j = try inst.readJournal(a, 1 << 20);
    try t.expectEqual(2, std.mem.count(u8, j, "\n"));
    try t.expect(std.mem.startsWith(u8, j, "{\"at\":\"1970-01-01T00:00:00Z\",\"step\":\"a\",\"try\":1,\"event\":\"start\"}\n"));
    try t.expect(std.mem.indexOf(u8, j, try std.fmt.allocPrint(a, "\"ok\":true,\"text\":\"{s}\"}}", .{long[0..2048]})) != null);
    // the last lines only
    try t.expect(std.mem.startsWith(u8, try inst.readJournal(a, 2150), "{\"at\":\"1970-01-01T00:00:00Z\",\"step\":\"a\",\"try\":1,\"event\":\"end\""));
    const p = try std.fs.path.join(a, &.{ f.root, "day.json" });
    try saveDay(t.io, a, p, .{ .day = 20_000, .agent_steps = 3, .told = true });
    try t.expectEqual(Day{ .day = 20_000, .agent_steps = 3, .told = true }, loadDay(t.io, a, p));
}


test "a_state_read_back_is_kept_in_bounds" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = parseState(a, "{\"name\":\"w\",\"n\":1,\"status\":\"running\",\"try\":0,\"started\":-9223372036854775808,\"updated\":-1,\"ended\":-5,\"wait\":{\"kind\":\"timer\",\"until\":-1,\"since\":-7}}").?;
    try t.expectEqual(1, st.try_n);
    try t.expectEqual(0, st.started);
    try t.expectEqual(0, st.updated);
    try t.expectEqual(0, st.ended);
    try t.expectEqual(0, st.wait.until);
    try t.expectEqual(0, st.wait.since);
}

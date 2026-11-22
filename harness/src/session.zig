//! The log as the session view: a run read back from the action log — the
//! message it started with, its model calls, its tool calls with the
//! gate's decisions, its helpers, its posts, and how it ended. `/session`,
//! `harness log runs` and `harness log session` read it; apps (gap 8) get
//! `raw`'s lines.
const std = @import("std");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

/// One run, from its lines in the log.
pub const RunInfo = struct {
    rid: u64,
    time: []const u8,
    label: []const u8,
    by: []const u8,
    conversation: []const u8,
    /// The run that delegated it (a helper).
    parent: ?u64 = null,
    steps: ?i64 = null,
    /// How it ended: "answered", or why it ended early; "" while the log
    /// has no end for it (a brief, or one still going).
    end: []const u8 = "",
};

/// A log line that reads as JSON, with what every line has.
const Line = struct {
    v: jv.Value,
    raw: []const u8,
    seq: u64,
    rid: ?u64,
    kind: []const u8,
};

fn parse(a: std.mem.Allocator, text: []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |text_line| {
        if (text_line.len == 0) continue;
        const v = jv.parse(a, text_line) orelse continue;
        const seq = jv.int(jv.get(v, "seq")) orelse continue;
        try out.append(a, .{
            .v = v,
            .raw = text_line,
            .seq = @intCast(@max(0, seq)),
            .rid = if (jv.int(jv.get(v, "rid"))) |r| @as(u64, @intCast(@max(0, r))) else null,
            .kind = jv.str(jv.get(v, "kind")) orelse "",
        });
    }
    return out.items;
}

/// A string field as the log keeps it: the text, or for a private line
/// its size only.
fn field(a: std.mem.Allocator, v: jv.Value, name: []const u8) []const u8 {
    const x = jv.get(v, name) orelse return "";
    if (jv.str(x)) |s| return s;
    if (jv.int(jv.get(x, "bytes"))) |n| return std.fmt.allocPrint(a, "(private, {d} bytes)", .{n}) catch "(private)";
    return "";
}

/// The runs in the log `text`, oldest first.
pub fn runs(a: std.mem.Allocator, text: []const u8) ![]RunInfo {
    const lines = try parse(a, text);
    var out: std.ArrayList(RunInfo) = .empty;
    for (lines) |l| {
        const rid = l.rid orelse continue;
        if (rid == l.seq) {
            try out.append(a, .{
                .rid = rid,
                .time = field(a, l.v, "time"),
                .label = field(a, l.v, "run"),
                .by = field(a, l.v, "by"),
                .conversation = field(a, l.v, "conversation"),
                .parent = if (jv.int(jv.get(l.v, "parent"))) |p| @as(u64, @intCast(@max(0, p))) else null,
            });
            continue;
        }
        // a turn's last line: its steps and why it ended
        if (!std.mem.eql(u8, l.kind, "turn") or jv.get(l.v, "steps") == null) continue;
        var i = out.items.len;
        while (i > 0) {
            i -= 1;
            if (out.items[i].rid != rid) continue;
            out.items[i].steps = jv.int(jv.get(l.v, "steps"));
            const why = field(a, l.v, "ended_by");
            out.items[i].end = if (why.len > 0) why else "answered";
            break;
        }
    }
    return out.items;
}

/// The rid of the `back`-th last run (1: the last) that reported to
/// `conversation`, helpers left out.
pub fn lastRunIn(a: std.mem.Allocator, text: []const u8, conversation: []const u8, back: usize) !?u64 {
    const all = try runs(a, text);
    var n: usize = 0;
    var i = all.len;
    while (i > 0) {
        i -= 1;
        const r = all[i];
        if (r.parent != null or !std.mem.eql(u8, r.conversation, conversation)) continue;
        n += 1;
        if (n == back) return r.rid;
    }
    return null;
}

/// A line per run, the last `n`: id, time, label, who started it, its
/// conversation, its steps, how it ended (`harness log runs`).
pub fn runsText(a: std.mem.Allocator, text: []const u8, n: usize) ![]const u8 {
    const all = try runs(a, text);
    var out: std.ArrayList(u8) = .empty;
    for (all[all.len -| n ..]) |r| {
        try out.print(a, "{d}  {s}  {s}  by {s}  in {s}", .{ r.rid, r.time, r.label, if (r.by.len > 0) r.by else "?", if (r.conversation.len > 0) r.conversation else "-" });
        if (r.steps) |s| try out.print(a, "  {d} step{s}", .{ s, if (s == 1) "" else "s" });
        if (r.end.len > 0) try out.print(a, "  {s}", .{r.end});
        try out.append(a, '\n');
    }
    return out.items;
}

/// The lines of run `rid` and of the helpers it delegated, as they are.
pub fn raw(a: std.mem.Allocator, text: []const u8, rid: u64) ![]const u8 {
    const lines = try parse(a, text);
    const mine = try members(a, lines, rid);
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| if (l.rid) |r| if (has(mine, r)) {
        try out.appendSlice(a, l.raw);
        try out.append(a, '\n');
    };
    return out.items;
}

/// `rid` and the rids of the helpers it delegated.
fn members(a: std.mem.Allocator, lines: []const Line, rid: u64) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    try out.append(a, rid);
    for (lines) |l| {
        const r = l.rid orelse continue;
        if (r != l.seq) continue;
        const p = jv.int(jv.get(l.v, "parent")) orelse continue;
        if (p >= 0 and has(out.items, @intCast(p))) try out.append(a, r);
    }
    return out.items;
}

fn has(list: []const u64, x: u64) bool {
    return std.mem.indexOfScalar(u64, list, x) != null;
}

/// What a helper did, in one line.
const HelperSum = struct { label: []const u8 = "", task: []const u8 = "", models: usize = 0, tools: usize = 0, end: []const u8 = "" };

/// Run `rid` in readable lines: the message it started with, each model
/// call (tokens), each tool call (tool, argument cut to 80 bytes, the
/// gate's decision and why, ok or error, output size), each helper in a
/// line, its posts, how it ended. At most `max` bytes (0: all), then
/// "harness log session RID shows all". Null: no such run in `text`.
pub fn render(a: std.mem.Allocator, text: []const u8, rid: u64, max: usize) !?[]const u8 {
    const lines = try parse(a, text);
    const mine = try members(a, lines, rid);
    var helpers: std.AutoArrayHashMapUnmanaged(u64, HelperSum) = .empty;
    for (mine[1..]) |h| try helpers.put(a, h, .{});
    for (lines) |l| {
        const r = l.rid orelse continue;
        const hs = helpers.getPtr(r) orelse continue;
        if (r == l.seq) {
            hs.label = field(a, l.v, "run");
            hs.task = field(a, l.v, "text");
        } else if (std.mem.eql(u8, l.kind, "model")) {
            hs.models += 1;
        } else if (std.mem.eql(u8, l.kind, "tool")) {
            hs.tools += 1;
        } else if (std.mem.eql(u8, l.kind, "turn") and jv.get(l.v, "steps") != null) {
            const why = field(a, l.v, "ended_by");
            hs.end = if (why.len > 0) why else "answered";
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    // a gate line that allowed a call: said with the tool's own line
    var pending: ?jv.Value = null;
    for (lines) |l| {
        const r = l.rid orelse continue;
        if (helpers.get(r)) |hs| {
            if (r == l.seq) try out.print(a, "Helper {s}: {s} ({d} model calls, {d} tool calls; {s})\n", .{ hs.label, util.cut(hs.task, 80), hs.models, hs.tools, if (hs.end.len > 0) hs.end else "no end in the log" });
            continue;
        }
        if (r != rid) continue;
        const v = l.v;
        if (r == l.seq) {
            found = true;
            const by = field(a, v, "by");
            try out.print(a, "Run {d}: {s}, by {s}, in {s}, {s}\n", .{ rid, field(a, v, "run"), by, field(a, v, "conversation"), field(a, v, "time") });
            if (std.mem.eql(u8, l.kind, "turn")) {
                try out.print(a, "{s}: {s}\n", .{ if (std.mem.eql(u8, by, "owner")) "Owner" else "Instruction", util.cut(field(a, v, "text"), 200) });
                continue;
            }
        }
        if (std.mem.eql(u8, l.kind, "model")) {
            const result = field(a, v, "result");
            if (std.mem.eql(u8, result, "ok"))
                try out.print(a, "Model: {d} in, {d} out\n", .{ jv.int(jv.get(v, "input_tokens")) orelse 0, jv.int(jv.get(v, "output_tokens")) orelse 0 })
            else
                try out.print(a, "Model: {s} {s}\n", .{ result, util.cut(field(a, v, "detail"), 80) });
        } else if (std.mem.eql(u8, l.kind, "gate")) {
            if (std.mem.eql(u8, field(a, v, "decision"), "allow")) {
                pending = v;
            } else {
                try out.print(a, "{s} {s}: {s} ({s})\n", .{ field(a, v, "tool"), util.cut(field(a, v, "arg"), 80), field(a, v, "decision"), field(a, v, "why") });
                pending = null;
            }
        } else if (std.mem.eql(u8, l.kind, "tool")) {
            const tool = field(a, v, "tool");
            const event = field(a, v, "event");
            if (event.len > 0) {
                try out.print(a, "{s}: {s}\n", .{ tool, event });
                continue;
            }
            const ok = if (jv.boolean(jv.get(v, "is_error")) orelse false) "error" else "ok";
            const size = jv.int(jv.get(v, "bytes")) orelse @as(i64, @intCast(field(a, v, "output").len));
            if (pending) |g| if (std.mem.eql(u8, field(a, g, "tool"), tool)) {
                try out.print(a, "{s} {s}: allow ({s}), {s}, {d} bytes\n", .{ tool, util.cut(field(a, v, "arg"), 80), field(a, g, "why"), ok, size });
                pending = null;
                continue;
            };
            try out.print(a, "{s} {s}: {s}, {d} bytes\n", .{ tool, util.cut(field(a, v, "arg"), 80), ok, size });
        } else if (std.mem.eql(u8, l.kind, "send")) {
            pending = null;
            const event = field(a, v, "event");
            const to = field(a, v, "to");
            if (std.mem.eql(u8, event, "sent")) {
                const final = jv.boolean(jv.get(v, "final")) orelse false;
                const implicit = jv.boolean(jv.get(v, "implicit")) orelse false;
                try out.print(a, "Posted to {s}: {s} ({s})\n", .{ to, util.cut(field(a, v, "text"), 80), if (implicit) "the reply, posted by harness" else if (final) "final" else "a note" });
            } else try out.print(a, "Not posted to {s} ({s}): {s}\n", .{ to, event, field(a, v, "why") });
        } else if (std.mem.eql(u8, l.kind, "turn")) {
            if (jv.get(v, "steps")) |_| {
                const why = field(a, v, "ended_by");
                const steps = jv.int(jv.get(v, "steps")) orelse 0;
                try out.print(a, "Ended: {s} in {d} step{s}\n", .{ if (why.len > 0) why else "answered", steps, if (steps == 1) "" else "s" });
            } else {
                const event = field(a, v, "event");
                if (event.len > 0) try out.print(a, "{s}\n", .{event});
            }
        }
    }
    if (!found) return null;
    if (max == 0 or out.items.len <= max) return out.items;
    // whole lines that fit, then where the rest is
    const more = try std.fmt.allocPrint(a, "harness log session {d} shows all", .{rid});
    var keep = util.cut(out.items, max -| (more.len + 1)).len;
    if (std.mem.lastIndexOfScalar(u8, out.items[0..keep], '\n')) |nl| keep = nl + 1;
    return try std.fmt.allocPrint(a, "{s}{s}", .{ out.items[0..keep], more });
}

/// The last `max` bytes of the log at `path`, from its first whole line.
pub fn tail(io: Io, a: std.mem.Allocator, path: []const u8, max: usize) ![]const u8 {
    var f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const n: usize = @intCast(@min(len, max));
    const buf = try a.alloc(u8, n);
    const got = try f.readPositionalAll(io, buf, len - n);
    const text = buf[0..got];
    if (n == len) return text;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return text[0..0];
    return text[nl + 1 ..];
}

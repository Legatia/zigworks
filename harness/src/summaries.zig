//! Long memory, part two: each conversation's summaries by day, week and
//! month. Once a day (03:00 the owner's time, or the first tick after) the
//! memory model summarises each conversation's earlier days from the log,
//! oldest first, up to 7 days back; after a Sunday the week's days fold
//! into the week, after a month's last day its weeks into the month. Plain
//! files: `state/summaries/CONV/day/YYYY-MM-DD.md`, `week/YYYY-Www.md`,
//! `month/YYYY-MM.md`; the latest go into the prompt (`promptBlock`).
const std = @import("std");
const util = @import("util.zig");
const jv = @import("jv.zig");
const model = @import("model.zig");
const log_mod = @import("log.zig");
const scrub = @import("scrub.zig");
const conversations = @import("conversations.zig");
const history = @import("history.zig");
const Io = std.Io;

/// Minutes after midnight (the owner's time) of the daily pass.
pub const at_minutes = 3 * 60;
/// Days a pass looks back, at most: missed ones are caught up.
pub const back_days = 7;
/// How long summaries are kept: days 60 days, weeks 400 days, months always.
pub const keep_days = 60;
pub const keep_week_days = 400;
/// The most of a day's text one call is sent; the newest is kept.
pub const input_max = 200 * 1024;
/// The most the summaries in a prompt hold together.
pub const prompt_words = 1500;
/// Failed calls in one pass before it ends: the model is likely not there.
const max_failures = 3;
/// How long one call may take.
const call_seconds = 120;

pub const day_prompt =
    \\Summarise one day of a conversation between an agent and its owner, for the agent's own later use: what the owner asked for and decided, facts learned, names, dates, numbers and links worth keeping, and what is still open. Plain text, at most 150 words, no heading.
;
pub const week_prompt =
    \\Fold the daily summaries of one week of a conversation between an agent and its owner into one summary for the agent's own later use: decisions, facts, names, dates, numbers and links worth keeping, and what is still open. Plain text, at most 150 words, no heading.
;
pub const month_prompt =
    \\Fold the summaries of one month of a conversation between an agent and its owner (by week, and by day for days no week summary covers) into one summary for the agent's own later use: decisions, facts, names, dates, numbers and links worth keeping, and what is still open. Plain text, at most 200 words, no heading.
;

pub const Kind = enum {
    day,
    week,
    month,

    /// The words a summary of this kind is asked for.
    fn words(k: Kind) usize {
        return if (k == .month) 200 else 150;
    }
};

const weekday_names = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

/// A day, an ISO week or a month, by its first day (days since 1970, the
/// owner's time): the day, the week's Monday, the month's 1st.
pub const Period = struct {
    kind: Kind,
    first: i64,

    pub fn last(p: Period) i64 {
        return switch (p.kind) {
            .day => p.first,
            .week => p.first + 6,
            .month => monthEnd(p.first),
        };
    }

    /// "2026-11-22", "2026-W47", "2026-11".
    pub fn name(p: Period, buf: *[16]u8) []const u8 {
        const c = util.civil(p.first);
        const y: u64 = @intCast(std.math.clamp(c.y, 0, 9999));
        return switch (p.kind) {
            .day => std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, c.m, c.d }),
            .week => blk: {
                const w = isoWeek(p.first);
                break :blk std.fmt.bufPrint(buf, "{d:0>4}-W{d:0>2}", .{ @as(u64, @intCast(std.math.clamp(w.year, 0, 9999))), w.week });
            },
            .month => std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ y, c.m }),
        } catch unreachable;
    }

    /// The period a file's name (without its ending) names, or null.
    pub fn parse(kind: Kind, s: []const u8) ?Period {
        const y = std.fmt.parseInt(i64, if (s.len >= 4) s[0..4] else return null, 10) catch return null;
        switch (kind) {
            .day => {
                if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
                const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
                const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
                if (m < 1 or m > 12 or d < 1 or d > 31) return null;
                return .{ .kind = .day, .first = util.daysFromCivil(y, m, d) };
            },
            .week => {
                if (s.len != 8 or s[4] != '-' or s[5] != 'W') return null;
                const w = std.fmt.parseInt(u8, s[6..8], 10) catch return null;
                if (w < 1 or w > 53) return null;
                const jan4 = util.daysFromCivil(y, 1, 4);
                return .{ .kind = .week, .first = jan4 - util.weekday(jan4) + (@as(i64, w) - 1) * 7 };
            },
            .month => {
                if (s.len != 7 or s[4] != '-') return null;
                const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
                if (m < 1 or m > 12) return null;
                return .{ .kind = .month, .first = util.daysFromCivil(y, m, 1) };
            },
        }
    }
};

/// The ISO year and week of a day: the week (Monday to Sunday) belongs to
/// the year its Thursday is in.
pub fn isoWeek(day: i64) struct { year: i64, week: u8 } {
    const thursday = day - util.weekday(day) + 3;
    const y = util.civil(thursday).y;
    return .{ .year = y, .week = @intCast(@divFloor(thursday - util.daysFromCivil(y, 1, 1), 7) + 1) };
}

fn monthStart(day: i64) i64 {
    const c = util.civil(day);
    return util.daysFromCivil(c.y, c.m, 1);
}

fn monthEnd(day: i64) i64 {
    const c = util.civil(day);
    return (if (c.m == 12) util.daysFromCivil(c.y + 1, 1, 1) else util.daysFromCivil(c.y, c.m + 1, 1)) - 1;
}

fn localDay(secs: i64, utc_offset: i32) i64 {
    return @divFloor(secs + @as(i64, utc_offset) * 60, 86400);
}

/// "2026-11-22".
fn dayText(buf: *[16]u8, day: i64) []const u8 {
    return (Period{ .kind = .day, .first = day }).name(buf);
}

fn countWords(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    while (it.next()) |_| n += 1;
    return n;
}

/// The first `n` words of `s`, as written.
fn cutWords(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var in_word = false;
    for (s, 0..) |c, i| {
        const space = std.ascii.isWhitespace(c);
        if (!space and !in_word) {
            count += 1;
            if (count > n) return std.mem.trimEnd(u8, s[0..i], " \t\r\n");
        }
        in_word = !space;
    }
    return s;
}

/// Whether a conversation is private now: none of it is summarised.
pub const Private = struct {
    ctx: *anyopaque,
    is: *const fn (ctx: *anyopaque, name: []const u8) bool,
};

/// What a pass needs.
pub const Env = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The action log, read.
    log_path: []const u8,
    /// state/summaries.
    dir: []const u8,
    now_s: i64,
    utc_offset: i32 = 0,
    /// The memory model (or [memory] summary_model).
    client: *model.Client,
    /// Where `memory` lines go.
    log: *log_mod.Log,
    /// Masked in what is sent and written: the values masked now.
    secrets: []const scrub.Secret = &.{},
    private: ?Private = null,
    /// Set: the pass ends at its next call.
    stop: ?*const std.atomic.Value(bool) = null,

    fn isPrivate(env: *const Env, name: []const u8) bool {
        const p = env.private orelse return false;
        return p.is(p.ctx, name);
    }
};

/// The daily job: when it is due, and the calls that failed today.
pub const Job = struct {
    /// The day (the owner's time) of the last pass; null: none since start.
    pass_day: ?i64 = null,
    /// When a pass may try a failed call again (Unix seconds); 0: none waits.
    retry_s: i64 = 0,
    failures: std.ArrayList(Failure) = .empty,
    /// A pass is going (on harness's thread for it).
    running: std.atomic.Value(bool) = .init(false),

    /// A call that failed: tried again later that day, given up the next.
    const Failure = struct {
        conv_buf: [conversations.max_name]u8 = undefined,
        conv_len: usize = 0,
        period: Period,
        /// The day it first failed.
        day: i64,
        tries: u32 = 0,
        next_s: i64 = 0,
        why_buf: [48]u8 = undefined,
        why_len: usize = 0,

        fn conv(fl: *const Failure) []const u8 {
            return fl.conv_buf[0..fl.conv_len];
        }

        fn why(fl: *const Failure) []const u8 {
            return fl.why_buf[0..fl.why_len];
        }
    };

    pub fn deinit(j: *Job, gpa: std.mem.Allocator) void {
        j.failures.deinit(gpa);
    }

    /// A pass is due: from 03:00 (the owner's time) once a day, and when a
    /// failed call's wait is over.
    pub fn due(j: *const Job, now_s: i64, utc_offset: i32) bool {
        const local = now_s + @as(i64, utc_offset) * 60;
        if (@mod(local, 86400) < at_minutes * 60) return false;
        if (j.pass_day == null or j.pass_day.? < @divFloor(local, 86400)) return true;
        return j.retry_s != 0 and now_s >= j.retry_s;
    }

    fn find(j: *const Job, conv: []const u8, p: Period) ?usize {
        for (j.failures.items, 0..) |*fl, i| if (fl.period.kind == p.kind and fl.period.first == p.first and std.mem.eql(u8, fl.conv(), conv)) return i;
        return null;
    }

    /// Whether a period inside `p` of `conv` failed and waits to be tried again.
    fn waitsIn(j: *const Job, conv: []const u8, p: Period) bool {
        for (j.failures.items) |*fl| {
            if (@intFromEnum(fl.period.kind) >= @intFromEnum(p.kind) or !std.mem.eql(u8, fl.conv(), conv)) continue;
            if (fl.period.first <= p.last() and fl.period.last() >= p.first) return true;
        }
        return false;
    }

    /// Notes a failed call: the next try after 5 minutes, then 10, 20, 40,
    /// at most an hour later.
    fn failed(j: *Job, gpa: std.mem.Allocator, conv: []const u8, p: Period, today: i64, now_s: i64, why: []const u8) !void {
        const i = j.find(conv, p) orelse blk: {
            var fl: Failure = .{ .period = p, .day = today };
            fl.conv_len = @min(conv.len, fl.conv_buf.len);
            @memcpy(fl.conv_buf[0..fl.conv_len], conv[0..fl.conv_len]);
            try j.failures.append(gpa, fl);
            break :blk j.failures.items.len - 1;
        };
        const fl = &j.failures.items[i];
        fl.tries += 1;
        fl.next_s = now_s + @min(@as(i64, 300) << @intCast(@min(fl.tries - 1, 4)), 3600);
        const w = util.cut(why, fl.why_buf.len);
        @memcpy(fl.why_buf[0..w.len], w);
        fl.why_len = w.len;
    }

    /// One pass: the days back to 7 before today without a summary,
    /// oldest first, each followed by the week a Sunday ends and the month
    /// a month's last day ends; then old summaries go. A call that failed
    /// on an earlier day is given up first.
    pub fn pass(j: *Job, env: Env) void {
        j.passOrFail(env) catch |e| env.log.write(.memory, false, .{ .event = "summaries failed", .why = @errorName(e) }) catch {};
    }

    fn passOrFail(j: *Job, env: Env) !void {
        var arena: std.heap.ArenaAllocator = .init(env.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const today = localDay(env.now_s, env.utc_offset);
        var p: Pass = .{ .j = j, .env = env, .a = a, .today = today };
        // what failed on an earlier day is given up, wherever it is
        var i: usize = 0;
        while (i < j.failures.items.len) {
            if (j.failures.items[i].day < today) try p.giveUp(i) else i += 1;
        }
        const first = today - back_days;
        const days = try readDays(a, env, first, today);
        var d = first;
        while (d < today and !p.stopped) : (d += 1) {
            for (days) |dt| if (dt.day == d) try p.summarise(dt.conv, .{ .kind = .day, .first = d }, dt.text);
            if (util.weekday(d) == 6) for (try p.convs()) |conv| try p.fold(conv, .{ .kind = .week, .first = d - 6 });
            if (monthEnd(d) == d) for (try p.convs()) |conv| try p.fold(conv, .{ .kind = .month, .first = monthStart(d) });
        }
        prune(a, env, today);
        j.pass_day = today;
        j.retry_s = 0;
        for (j.failures.items) |fl| if (j.retry_s == 0 or fl.next_s < j.retry_s) {
            j.retry_s = fl.next_s;
        };
    }
};

/// One pass's work.
const Pass = struct {
    j: *Job,
    env: Env,
    a: std.mem.Allocator,
    today: i64,
    /// Calls that failed in this pass.
    failed: usize = 0,
    stopped: bool = false,

    fn path(p: *Pass, conv: []const u8, period: Period, ending: []const u8) ![]const u8 {
        var nb: [16]u8 = undefined;
        return std.fs.path.join(p.a, &.{ p.env.dir, conv, @tagName(period.kind), try std.fmt.allocPrint(p.a, "{s}{s}", .{ period.name(&nb), ending }) });
    }

    fn exists(p: *Pass, file: []const u8) bool {
        _ = Io.Dir.cwd().statFile(p.env.io, file, .{}) catch return false;
        return true;
    }

    /// Written, or given up.
    fn done(p: *Pass, conv: []const u8, period: Period) !bool {
        return p.exists(try p.path(conv, period, ".md")) or p.exists(try p.path(conv, period, ".given-up"));
    }

    /// A summary's text, or null.
    fn read(p: *Pass, conv: []const u8, period: Period) ?[]const u8 {
        const file = p.path(conv, period, ".md") catch return null;
        const text = Io.Dir.cwd().readFileAlloc(p.env.io, file, p.a, .limited(64 * 1024)) catch return null;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        return if (trimmed.len > 0) trimmed else null;
    }

    /// The conversations with a folder of summaries, not private ones,
    /// in name order.
    fn convs(p: *Pass) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var d = Io.Dir.cwd().openDir(p.env.io, p.env.dir, .{ .iterate = true }) catch return out.items;
        defer d.close(p.env.io);
        var it = d.iterate();
        while (try it.next(p.env.io)) |e| {
            if (e.kind != .directory or !conversations.validName(e.name) or p.env.isPrivate(e.name)) continue;
            try out.append(p.a, try p.a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        return out.items;
    }

    fn summarise(p: *Pass, conv: []const u8, period: Period, text: []const u8) !void {
        if (try p.done(conv, period)) return;
        var db: [16]u8 = undefined;
        const msg = try std.fmt.allocPrint(p.a, "Conversation: {s}\nDay: {s} {s} (the owner's time)\n\n{s}", .{ conv, weekday_names[util.weekday(period.first)], dayText(&db, period.first), text });
        try p.call(conv, period, day_prompt, msg);
    }

    /// A week from its days, or a month from its weeks and the days no
    /// week summary of it covers.
    fn fold(p: *Pass, conv: []const u8, period: Period) !void {
        if (try p.done(conv, period)) return;
        // its days (or weeks) first
        if (p.j.waitsIn(conv, period)) return;
        var parts: std.ArrayList(u8) = .empty;
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        if (period.kind == .week) {
            try p.addDays(&parts, conv, period.first, period.last());
        } else {
            var monday = period.first - util.weekday(period.first);
            while (monday <= period.last()) : (monday += 7) {
                const wk: Period = .{ .kind = .week, .first = monday };
                // a week counts for the month its Sunday is in
                if (wk.last() <= period.last()) if (p.read(conv, wk)) |text| {
                    try parts.print(p.a, "Week {s} ({s} to {s}):\n{s}\n\n", .{ wk.name(&b1), dayText(&b2, monday), dayText(&b3, wk.last()), text });
                    continue;
                };
                try p.addDays(&parts, conv, @max(monday, period.first), @min(wk.last(), period.last()));
            }
        }
        if (parts.items.len == 0) return;
        const msg = if (period.kind == .week)
            try std.fmt.allocPrint(p.a, "Conversation: {s}\nWeek: {s}, {s} to {s}\n\n{s}", .{ conv, period.name(&b1), dayText(&b2, period.first), dayText(&b3, period.last()), parts.items })
        else
            try std.fmt.allocPrint(p.a, "Conversation: {s}\nMonth: {s}\n\n{s}", .{ conv, period.name(&b1), parts.items });
        try p.call(conv, period, if (period.kind == .week) week_prompt else month_prompt, msg);
    }

    fn addDays(p: *Pass, parts: *std.ArrayList(u8), conv: []const u8, from: i64, to: i64) !void {
        var db: [16]u8 = undefined;
        var d = from;
        while (d <= to) : (d += 1) if (p.read(conv, .{ .kind = .day, .first = d })) |text|
            try parts.print(p.a, "{s} ({s}):\n{s}\n\n", .{ dayText(&db, d), weekday_names[util.weekday(d)], text });
    }

    /// One call of the model: the summary written whole, or the failure
    /// noted to be tried again.
    fn call(p: *Pass, conv: []const u8, period: Period, system: []const u8, msg: []const u8) !void {
        const env = p.env;
        if (p.j.find(conv, period)) |i| if (env.now_s < p.j.failures.items[i].next_s) return;
        if (p.failed >= max_failures) p.stopped = true;
        if (env.stop) |s| if (s.load(.acquire)) {
            p.stopped = true;
        };
        if (p.stopped) return;
        var nb: [16]u8 = undefined;
        const name = period.name(&nb);
        var sc = try scrub.Scrubber.init(p.a, env.secrets);
        const masked = try sc.scrubAlloc(p.a, msg);
        // the call's own clock: the pass's may be a test's
        const reply = env.client.sendParts(p.a, system, "", &.{.{ .role = .user, .blocks = &.{.{ .text = masked }} }}, &.{}, .{ .stop = env.stop, .deadline_s = util.nowSeconds(env.io) + call_seconds }) catch |e| return p.fail(conv, period, @errorName(e));
        const said = std.mem.trim(u8, try reply.text(p.a), " \t\r\n");
        if (said.len == 0) return p.fail(conv, period, "EmptySummary");
        // longer than asked: cut at twice the words
        const text = try sc.scrubAlloc(p.a, cutWords(said, period.kind.words() * 2));
        const file = try p.path(conv, period, ".md");
        try Io.Dir.cwd().createDirPath(env.io, std.fs.path.dirname(file).?);
        try util.writeReplace(env.io, file, try std.fmt.allocPrint(p.a, "{s}\n", .{text}));
        try env.log.write(.memory, false, .{ .event = "summary", .conversation = conv, .period = name, .words = countWords(text), .tokens = reply.input_tokens + reply.output_tokens, .provider = env.client.provider });
        if (p.j.find(conv, period)) |i| _ = p.j.failures.orderedRemove(i);
    }

    fn fail(p: *Pass, conv: []const u8, period: Period, why: []const u8) !void {
        p.failed += 1;
        var nb: [16]u8 = undefined;
        try p.env.log.write(.memory, false, .{ .event = "summary failed", .conversation = conv, .period = period.name(&nb), .why = why, .provider = p.env.client.provider });
        try p.j.failed(p.env.gpa, conv, period, p.today, p.env.now_s, why);
    }

    /// Failure `i`, from an earlier day: noted beside the summaries (so it
    /// is not tried again) and logged.
    fn giveUp(p: *Pass, i: usize) !void {
        const fl = p.j.failures.orderedRemove(i);
        var nb: [16]u8 = undefined;
        var tb: [20]u8 = undefined;
        const file = try p.path(fl.conv(), fl.period, ".given-up");
        try Io.Dir.cwd().createDirPath(p.env.io, std.fs.path.dirname(file).?);
        try util.writeReplace(p.env.io, file, try std.fmt.allocPrint(p.a, "Given up {s} after {d} tries: {s}\n", .{ util.isoTime(&tb, p.env.now_s), fl.tries, fl.why() }));
        try p.env.log.write(.memory, false, .{ .event = "summary given up", .conversation = fl.conv(), .period = fl.period.name(&nb), .tries = fl.tries, .why = fl.why() });
    }
};

/// One conversation's day: its turns as text.
const DayText = struct { conv: []const u8, day: i64, text: []const u8 };

/// A run read from the log, while it is read.
const RunText = struct {
    conv: []const u8,
    day: i64,
    /// The owner started it.
    owner: bool,
    /// It posted to the conversation.
    posted: bool = false,
    text: std.ArrayList(u8) = .empty,
};

/// The turns of each conversation on each day from `first` to before
/// `today` (the owner's time), from the log's masked text: the runs the
/// owner started, and the others that posted there (a scheduled check that
/// posted nothing is no turn); helpers' work is in their run's delegate
/// result. Private conversations, and private lines, give nothing.
fn readDays(a: std.mem.Allocator, env: Env, first: i64, today: i64) ![]DayText {
    var f = Io.Dir.cwd().openFile(env.io, env.log_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer f.close(env.io);
    const len = try f.length(env.io);
    var off = try history.seekLine(env.io, f, len, first * 86400 - @as(i64, env.utc_offset) * 60, history.timeKey);
    var runs: std.AutoHashMapUnmanaged(u64, *RunText) = .empty;
    var order: std.ArrayList(*RunText) = .empty;
    // each line parsed in its own arena, kept small
    var line_arena: std.heap.ArenaAllocator = .init(env.gpa);
    defer line_arena.deinit();
    const buf = try a.alloc(u8, 1 << 20);
    while (off < len) {
        const got = try f.readPositionalAll(env.io, buf, off);
        if (got == 0) break;
        const block = buf[0..got];
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, block, i, '\n')) |nl| {
            _ = line_arena.reset(.retain_capacity);
            try takeLine(a, line_arena.allocator(), env, block[i..nl], first, today, &runs, &order);
            i = nl + 1;
        }
        // a line longer than the block: not one harness writes
        if (i == 0) break;
        off += i;
        if (got < buf.len) break;
    }
    // each conversation's day: its runs in order, the newest kept within input_max
    var days: std.ArrayList(DayText) = .empty;
    var parts: std.ArrayList([]const u8) = .empty;
    var d = first;
    while (d < today) : (d += 1) {
        var names: std.ArrayList([]const u8) = .empty;
        for (order.items) |r| if (r.day == d and (r.owner or r.posted) and r.text.items.len > 0) {
            for (names.items) |n| {
                if (std.mem.eql(u8, n, r.conv)) break;
            } else try names.append(a, r.conv);
        };
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (names.items) |conv| {
            parts.clearRetainingCapacity();
            var size: usize = 0;
            var k = order.items.len;
            while (k > 0) {
                k -= 1;
                const r = order.items[k];
                if (r.day != d or !(r.owner or r.posted) or !std.mem.eql(u8, r.conv, conv)) continue;
                if (size > 0 and size + r.text.items.len > input_max) break;
                try parts.append(a, r.text.items);
                size += r.text.items.len;
            }
            var text: std.ArrayList(u8) = .empty;
            var m = parts.items.len;
            while (m > 0) {
                m -= 1;
                try text.appendSlice(a, parts.items[m]);
            }
            // one run alone over it: its end
            var kept = text.items;
            if (kept.len > input_max) {
                var from = kept.len - input_max;
                while (from < kept.len and kept[from] & 0xc0 == 0x80) from += 1;
                kept = kept[from..];
            }
            try days.append(a, .{ .conv = conv, .day = d, .text = kept });
        }
    }
    return days.items;
}

/// One line of the log, into the run it belongs to.
fn takeLine(a: std.mem.Allocator, la: std.mem.Allocator, env: Env, line: []const u8, first: i64, today: i64, runs: *std.AutoHashMapUnmanaged(u64, *RunText), order: *std.ArrayList(*RunText)) !void {
    // only a run's lines (they carry rid) are read
    if (std.mem.indexOf(u8, line[0..@min(line.len, 200)], "\"rid\":") == null) return;
    const v = jv.parse(la, line) orelse return;
    const rid = jv.int(jv.get(v, "rid")) orelse return;
    const seq = jv.int(jv.get(v, "seq")) orelse return;
    const kind = jv.str(jv.get(v, "kind")) orelse "";
    const eql = std.mem.eql;
    if (seq == rid) {
        // helpers' answers are in their run's delegate result
        if (jv.get(v, "parent") != null) return;
        const conv = jv.str(jv.get(v, "conversation")) orelse return;
        if (!conversations.validName(conv) or env.isPrivate(conv)) return;
        const started = util.parseIso(jv.str(jv.get(v, "time")) orelse "") orelse return;
        const day = localDay(started, env.utc_offset);
        if (day < first or day >= today) return;
        const owner = eql(u8, jv.str(jv.get(v, "by")) orelse "", "owner");
        const r = try a.create(RunText);
        r.* = .{ .conv = try a.dupe(u8, conv), .day = day, .owner = owner };
        try runs.put(a, @intCast(rid), r);
        try order.append(a, r);
        if (jv.str(jv.get(v, "text"))) |x| {
            var tb: [20]u8 = undefined;
            const hhmm = util.isoTime(&tb, started + @as(i64, env.utc_offset) * 60)[11..16];
            try r.text.print(a, "[{s}] {s}: {s}\n", .{ hhmm, if (owner) "Owner" else jv.str(jv.get(v, "run")) orelse "Instruction", x });
        }
        return;
    }
    const r = runs.get(@intCast(rid)) orelse return;
    if (r.text.items.len > input_max) return;
    if (eql(u8, kind, "send")) {
        const event = jv.str(jv.get(v, "event")) orelse "";
        if (!eql(u8, event, "sent") and !eql(u8, event, "kept")) return;
        const x = jv.str(jv.get(v, "text")) orelse return;
        r.posted = true;
        const to = jv.str(jv.get(v, "to")) orelse r.conv;
        if (eql(u8, to, r.conv)) try r.text.print(a, "Agent: {s}\n", .{x}) else try r.text.print(a, "Agent (to {s}): {s}\n", .{ to, x });
    } else if (eql(u8, kind, "turn")) {
        // a reply that was not posted (before conversations, a cut turn)
        const x = jv.str(jv.get(v, "answer")) orelse return;
        if (!r.posted and x.len > 0 and !eql(u8, std.mem.trim(u8, x, " \t\r\n."), "NOTHING")) try r.text.print(a, "Agent: {s}\n", .{x});
    } else if (eql(u8, kind, "tool")) {
        const tool = jv.str(jv.get(v, "tool")) orelse "";
        // what history answered is older turns again
        if (eql(u8, tool, "history")) return;
        try r.text.print(a, "({s} {s}: {s})\n", .{ tool, util.cut(jv.str(jv.get(v, "arg")) orelse "", 300), util.cut(jv.str(jv.get(v, "output")) orelse "", 500) });
    }
}

// ---- the prompt ----

/// A summary in the prompt.
const Shown = struct { period: Period, text: []const u8 };

/// The summaries of `kind` in `conv`'s folder, newest first (the
/// given-up marks are no summaries).
fn listed(a: std.mem.Allocator, io: Io, dir: []const u8, conv: []const u8, kind: Kind) ![]Period {
    var out: std.ArrayList(Period) = .empty;
    const path = try std.fs.path.join(a, &.{ dir, conv, @tagName(kind) });
    var d = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".md")) continue;
        try out.append(a, Period.parse(kind, e.name[0 .. e.name.len - 3]) orelse continue);
    }
    std.mem.sort(Period, out.items, {}, struct {
        fn newer(_: void, x: Period, y: Period) bool {
            return x.first > y.first;
        }
    }.newer);
    return out.items;
}

fn readShown(a: std.mem.Allocator, io: Io, dir: []const u8, conv: []const u8, p: Period) !?Shown {
    var nb: [16]u8 = undefined;
    const path = try std.fs.path.join(a, &.{ dir, conv, @tagName(p.kind), try std.fmt.allocPrint(a, "{s}.md", .{p.name(&nb)}) });
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return .{ .period = p, .text = trimmed };
}

/// The summaries of conversation `conv` for its prompt, oldest first:
/// the 3 latest days, the 2 latest weeks those days do not cover (a week
/// is covered when it has day summaries and all are shown), the 3 latest
/// months; within 1,500 words, the oldest dropped first (one alone over
/// it cut to its first 1,500), then a line on `history` when the run has
/// it. Only `conv`'s own. Null: there are none. The files change when the
/// daily pass writes one, so these bytes stay the same until then (the
/// prompt cache holds).
pub fn promptBlock(a: std.mem.Allocator, io: Io, dir: []const u8, conv: []const u8, history_line: bool) !?[]const u8 {
    if (dir.len == 0 or !conversations.validName(conv)) return null;
    var items: std.ArrayList(Shown) = .empty;
    const days = try listed(a, io, dir, conv, .day);
    const shown_days = days[0..@min(days.len, 3)];
    for (shown_days) |p| if (try readShown(a, io, dir, conv, p)) |x| try items.append(a, x);
    var weeks: usize = 0;
    for (try listed(a, io, dir, conv, .week)) |w| {
        if (weeks == 2) break;
        var any = false;
        var all_shown = true;
        for (days) |d| if (d.first >= w.first and d.first <= w.last()) {
            any = true;
            for (shown_days) |s| {
                if (s.first == d.first) break;
            } else all_shown = false;
        };
        if (any and all_shown) continue;
        if (try readShown(a, io, dir, conv, w)) |x| {
            try items.append(a, x);
            weeks += 1;
        }
    }
    const months = try listed(a, io, dir, conv, .month);
    for (months[0..@min(months.len, 3)]) |p| if (try readShown(a, io, dir, conv, p)) |x| try items.append(a, x);
    if (items.items.len == 0) return null;
    // oldest first: months, weeks, days
    std.mem.sort(Shown, items.items, {}, struct {
        fn older(_: void, x: Shown, y: Shown) bool {
            return x.period.first < y.period.first or (x.period.first == y.period.first and @intFromEnum(x.period.kind) > @intFromEnum(y.period.kind));
        }
    }.older);
    var total: usize = 0;
    for (items.items) |x| total += countWords(x.text);
    var from: usize = 0;
    while (total > prompt_words and items.items.len - from > 1) : (from += 1) total -= countWords(items.items[from].text);
    const kept = items.items[from..];
    if (total > prompt_words) kept[0].text = cutWords(kept[0].text, prompt_words);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "\nEarlier in this conversation:\n");
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    for (kept) |x| switch (x.period.kind) {
        .month => try out.print(a, "Month {s}: {s}\n", .{ x.period.name(&b1), x.text }),
        .week => try out.print(a, "Week {s} ({s} to {s}): {s}\n", .{ x.period.name(&b1), dayText(&b2, x.period.first), dayText(&b3, x.period.last()), x.text }),
        .day => try out.print(a, "{s} ({s}): {s}\n", .{ dayText(&b1, x.period.first), weekday_names[util.weekday(x.period.first)], x.text }),
    };
    if (history_line) try out.appendSlice(a, "history finds anything older than these, or the exact words.\n");
    return out.items;
}

/// Days older than 60 days go, weeks that ended over 400 days ago; months
/// stay.
fn prune(a: std.mem.Allocator, env: Env, today: i64) void {
    var d = Io.Dir.cwd().openDir(env.io, env.dir, .{ .iterate = true }) catch return;
    defer d.close(env.io);
    var it = d.iterate();
    while (it.next(env.io) catch null) |e| {
        if (e.kind != .directory or !conversations.validName(e.name)) continue;
        pruneKind(a, env, e.name, .day, today - keep_days);
        pruneKind(a, env, e.name, .week, today - keep_week_days);
    }
}

fn pruneKind(a: std.mem.Allocator, env: Env, conv: []const u8, kind: Kind, before: i64) void {
    const dir = std.fs.path.join(a, &.{ env.dir, conv, @tagName(kind) }) catch return;
    var d = Io.Dir.cwd().openDir(env.io, dir, .{ .iterate = true }) catch return;
    defer d.close(env.io);
    var old: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(env.io) catch null) |e| {
        if (e.kind != .file) continue;
        const stem = if (std.mem.endsWith(u8, e.name, ".md")) e.name[0 .. e.name.len - 3] else if (std.mem.endsWith(u8, e.name, ".given-up")) e.name[0 .. e.name.len - 9] else continue;
        const p = Period.parse(kind, stem) orelse continue;
        if (p.last() < before) old.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    for (old.items) |name| d.deleteFile(env.io, name) catch {};
}

const t = std.testing;

/// A pass's world: a log of turns at chosen times, the stand-in model, the
/// summaries' folder, a clock the test sets.
const Fix = struct {
    e: model.TestEnv,
    client: model.Client,
    /// Where the pass writes its `memory` lines.
    events: log_mod.Log,
    lines: history.Lines,
    dir: []const u8,
    log_path: []const u8 = "",
    job: Job = .{},
    private: []const []const u8 = &.{},
    secrets: []const @import("scrub.zig").Secret = &.{},

    fn init(f: *Fix) !void {
        try f.e.init();
        const a = f.e.arena.allocator();
        f.client = try f.e.client();
        f.events = try log_mod.Log.open(t.allocator, t.io, try std.fs.path.join(a, &.{ f.e.dir, "events.jsonl" }));
        f.lines = .{ .a = a };
        f.dir = try std.fs.path.join(a, &.{ f.e.dir, "summaries" });
        f.log_path = "";
        f.job = .{};
        f.private = &.{};
        f.secrets = &.{};
        // every answer, unless a test says otherwise: "Summary N."
        for (1..40) |n| try f.e.script(@intCast(n), try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":\"Summary {d}.\"}}],\"stop_reason\":\"end_turn\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":3}}}}", .{n}));
    }

    fn deinit(f: *Fix) void {
        f.job.deinit(t.allocator);
        f.events.close();
        f.client.deinit();
        f.e.deinit();
    }

    fn isPrivate(ctx: *anyopaque, name: []const u8) bool {
        const f: *Fix = @ptrCast(@alignCast(ctx));
        for (f.private) |p| if (std.mem.eql(u8, p, name)) return true;
        return false;
    }

    /// A pass at `iso` (UTC; the owner's time is UTC here).
    fn passAt(f: *Fix, iso: []const u8) !void {
        if (f.log_path.len == 0) f.log_path = try f.lines.save(&f.e.tmp);
        f.job.pass(.{
            .gpa = t.allocator,
            .io = t.io,
            .log_path = f.log_path,
            .dir = f.dir,
            .now_s = util.parseIso(iso).?,
            .client = &f.client,
            .log = &f.events,
            .secrets = f.secrets,
            .private = .{ .ctx = f, .is = isPrivate },
        });
    }

    /// A file under the summaries' folder, or null.
    fn file(f: *Fix, rel: []const u8) ?[]const u8 {
        const a = f.e.arena.allocator();
        return Io.Dir.cwd().readFileAlloc(t.io, std.fs.path.join(a, &.{ f.dir, rel }) catch return null, a, .limited(1 << 20)) catch null;
    }

    fn eventsText(f: *Fix) ![]const u8 {
        return f.e.tmp.dir.readFileAlloc(t.io, "events.jsonl", f.e.arena.allocator(), .unlimited);
    }

    /// One owner's turn with its reply.
    fn turn(f: *Fix, time: []const u8, conv: []const u8, said: []const u8, reply: []const u8) !void {
        const rid = try f.lines.start(time, conv, "chat", "owner", said);
        try f.lines.post(time, rid, conv, reply);
    }
};

fn expectIn(text: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, text, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
    try t.expect(std.mem.indexOf(u8, text, want) != null);
}

test "days_fold_into_weeks_and_months" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.turn("2026-11-16T09:00:00Z", "main", "Book the dentist for Friday", "Booked: Friday 10:00 at Dr. Weber.");
    // a scheduled check that posted nothing is no turn of the conversation
    _ = try f.lines.start("2026-11-17T07:00:00Z", "main", "task btc-watch", "schedule:btc-watch", "Check the BTC price.");
    try f.turn("2026-11-18T08:00:00Z", "house-search", "flats in Basel?", "Two in Basel, 2,400 and 2,900 CHF.");
    try f.turn("2026-11-18T12:00:00Z", "main", "Remind me of the dentist", "Friday 10:00 at Dr. Weber.");
    // a private conversation is never summarised
    try f.turn("2026-11-18T20:00:00Z", "diary", "my secret plans", "Kept between us.");
    f.private = &.{"diary"};
    const week = try f.lines.start("2026-11-22T18:00:00Z", "main", "chat", "owner", "Plan the week");
    try f.lines.tool("2026-11-22T18:00:02Z", week, "main", "fetch", "https://cal.example/week", "Mon: gym; Wed: dentist");
    try f.lines.post("2026-11-22T18:00:05Z", week, "main", "Done.");
    try f.turn("2026-11-30T09:00:00Z", "main", "flight to Oslo on Dec 12?", "Booked SK1471 on Dec 12.");
    // Monday 03:30: the days before, oldest first, then the week they end
    try f.passAt("2026-11-23T03:30:00Z");
    try t.expectEqual(6, f.e.server.modelRequests());
    const r1 = try f.e.request(1);
    try expectIn(r1, "Booked: Friday 10:00 at Dr. Weber.");
    try expectIn(r1, "Conversation: main\\nDay: Monday 2026-11-16");
    try expectIn(r1, "at most 150 words");
    try expectIn(try f.e.request(2), "Two in Basel");
    try expectIn(try f.e.request(4), "(fetch https://cal.example/week: Mon: gym; Wed: dentist)");
    try t.expectEqualStrings("Summary 1.\n", f.file("main/day/2026-11-16.md").?);
    try t.expectEqualStrings("Summary 2.\n", f.file("house-search/day/2026-11-18.md").?);
    try t.expectEqualStrings("Summary 3.\n", f.file("main/day/2026-11-18.md").?);
    try t.expectEqualStrings("Summary 4.\n", f.file("main/day/2026-11-22.md").?);
    try t.expectEqual(null, f.file("main/day/2026-11-17.md"));
    try t.expectEqual(null, f.file("diary/day/2026-11-18.md"));
    try t.expectEqualStrings("Summary 5.\n", f.file("house-search/week/2026-W47.md").?);
    try t.expectEqualStrings("Summary 6.\n", f.file("main/week/2026-W47.md").?);
    const r6 = try f.e.request(6);
    for ([_][]const u8{ "Week: 2026-W47, 2026-11-16 to 2026-11-22", "2026-11-16 (Monday):\\nSummary 1.", "2026-11-18 (Wednesday):\\nSummary 3.", "2026-11-22 (Sunday):\\nSummary 4." }) |want| try expectIn(r6, want);
    try expectIn(try f.eventsText(), "\"kind\":\"memory\",\"event\":\"summary\",\"conversation\":\"main\",\"period\":\"2026-W47\",\"words\":2,\"tokens\":13");
    // a day without turns makes no call
    try f.passAt("2026-11-24T03:30:00Z");
    try t.expectEqual(6, f.e.server.modelRequests());
    // the 1st: the last day, then the month from its weeks and its last days
    try f.passAt("2026-12-01T03:30:00Z");
    try t.expectEqual(9, f.e.server.modelRequests());
    try t.expectEqualStrings("Summary 7.\n", f.file("main/day/2026-11-30.md").?);
    try t.expectEqualStrings("Summary 8.\n", f.file("house-search/month/2026-11.md").?);
    try t.expectEqualStrings("Summary 9.\n", f.file("main/month/2026-11.md").?);
    const r9 = try f.e.request(9);
    for ([_][]const u8{ "Month: 2026-11", "at most 200 words", "Week 2026-W47 (2026-11-16 to 2026-11-22):\\nSummary 6.", "2026-11-30 (Monday):\\nSummary 7." }) |want| try expectIn(r9, want);
    // a week already folded is not told again day by day
    try t.expect(std.mem.indexOf(u8, r9, "Summary 1.") == null);
}

test "missed_days_are_caught_up_oldest_first_at_most_7_back" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.turn("2026-11-10T09:00:00Z", "main", "ten", "Noted ten.");
    try f.turn("2026-11-12T09:00:00Z", "main", "twelve", "Noted twelve.");
    try f.turn("2026-11-14T09:00:00Z", "main", "fourteen", "Noted fourteen.");
    try f.turn("2026-11-15T09:00:00Z", "main", "fifteen", "Noted fifteen.");
    // harness was off: its first pass, Friday the 20th
    try f.passAt("2026-11-20T16:00:00Z");
    try t.expectEqual(3, f.e.server.modelRequests());
    try expectIn(try f.e.request(1), "Noted fourteen.");
    try expectIn(try f.e.request(2), "Noted fifteen.");
    try expectIn(try f.e.request(3), "Week: 2026-W46");
    try t.expect(f.file("main/day/2026-11-14.md") != null);
    try t.expect(f.file("main/week/2026-W46.md") != null);
    // more than 7 days back: left
    try t.expectEqual(null, f.file("main/day/2026-11-12.md"));
    try t.expectEqual(null, f.file("main/day/2026-11-10.md"));
}

test "a_failed_summary_is_tried_again_then_given_up" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.turn("2026-11-21T09:00:00Z", "main", "saturday plans", "Hike at 10.");
    try f.turn("2026-11-22T09:00:00Z", "main", "sunday plans", "Brunch at 11.");
    try f.e.script(1, "{\"status\":500}");
    const monday = util.parseIso("2026-11-23T03:30:00Z").?;
    // not before 03:00, the owner's time; then once that day
    try t.expect(!f.job.due(monday - 3600, 0));
    try t.expect(f.job.due(monday, 0));
    try f.passAt("2026-11-23T03:30:00Z");
    // Saturday failed, Sunday went on; the week waits for Saturday
    try t.expectEqual(2, f.e.server.modelRequests());
    try t.expectEqual(null, f.file("main/day/2026-11-21.md"));
    try t.expectEqualStrings("Summary 2.\n", f.file("main/day/2026-11-22.md").?);
    try t.expectEqual(null, f.file("main/week/2026-W47.md"));
    try expectIn(try f.eventsText(), "\"event\":\"summary failed\",\"conversation\":\"main\",\"period\":\"2026-11-21\",\"why\":\"Upstream\"");
    // tried again after 5 minutes, not before
    try t.expect(!f.job.due(monday + 60, 0));
    try t.expect(f.job.due(monday + 300, 0));
    try f.e.script(3, "{\"status\":500}");
    try f.passAt("2026-11-23T03:35:00Z");
    try t.expectEqual(3, f.e.server.modelRequests());
    // then 10 minutes after that
    try t.expect(!f.job.due(monday + 300 + 599, 0));
    try t.expect(f.job.due(monday + 300 + 600, 0));
    // the next day it is given up, and the week folds what there is
    try f.passAt("2026-11-24T03:30:00Z");
    try t.expectEqual(4, f.e.server.modelRequests());
    try t.expect(f.file("main/day/2026-11-21.given-up") != null);
    try t.expectEqualStrings("Summary 4.\n", f.file("main/week/2026-W47.md").?);
    try expectIn(try f.eventsText(), "\"event\":\"summary given up\",\"conversation\":\"main\",\"period\":\"2026-11-21\",\"tries\":2");
    try t.expect(!f.job.due(util.parseIso("2026-11-24T12:00:00Z").?, 0));
    // and not tried again
    try f.passAt("2026-11-25T03:30:00Z");
    try t.expectEqual(4, f.e.server.modelRequests());
}

test "a_pass_stops_after_3_failed_calls" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "2026-11-17T09:00:00Z", "2026-11-18T09:00:00Z", "2026-11-19T09:00:00Z", "2026-11-20T09:00:00Z", "2026-11-21T09:00:00Z" }) |time| try f.turn(time, "main", "a day", "Noted.");
    for (1..6) |n| try f.e.script(@intCast(n), "{\"status\":402}");
    try f.passAt("2026-11-22T03:30:00Z");
    // the model is not there: three calls, then the pass ends
    try t.expectEqual(3, f.e.server.modelRequests());
}

test "summaries_are_kept_60_days_weeks_400_days_months_always" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const keep = [_][]const u8{ "main/day/2026-09-24.md", "main/week/2025-W42.md", "main/month/2024-01.md", "main/day/2026-11-20.given-up" };
    const drop = [_][]const u8{ "main/day/2026-09-23.md", "main/day/2026-09-01.given-up", "main/week/2025-W41.md" };
    for (keep ++ drop) |rel| {
        const p = try std.fs.path.join(a, &.{ f.dir, rel });
        try Io.Dir.cwd().createDirPath(t.io, std.fs.path.dirname(p).?);
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = "Old.\n" });
    }
    try f.passAt("2026-11-23T03:30:00Z");
    for (keep) |rel| try t.expect(f.file(rel) != null);
    for (drop) |rel| try t.expectEqual(null, f.file(rel));
}

test "a_summary_never_holds_a_secret" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    // a value stored after the line was written is masked now
    try f.turn("2026-11-22T09:00:00Z", "main", "my token is tok-4141-secret", "Stored.");
    f.secrets = &.{.{ .name = "github", .value = "tok-4141-secret" }};
    try f.e.script(1, "{\"content\":[{\"type\":\"text\",\"text\":\"The owner's token is tok-4141-secret.\"}],\"stop_reason\":\"end_turn\"}");
    try f.passAt("2026-11-23T03:30:00Z");
    const req = try f.e.request(1);
    try t.expect(std.mem.indexOf(u8, req, "tok-4141-secret") == null);
    try expectIn(req, "my token is [secret:github]");
    try t.expectEqualStrings("The owner's token is [secret:github].\n", f.file("main/day/2026-11-22.md").?);
}

/// Writes summary files under `dir`: `rel` and its text.
fn writeSummaries(a: std.mem.Allocator, dir: []const u8, files: []const [2][]const u8) !void {
    for (files) |x| {
        const p = try std.fs.path.join(a, &.{ dir, x[0] });
        try Io.Dir.cwd().createDirPath(t.io, std.fs.path.dirname(p).?);
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = x[1] });
    }
}

/// `n` words.
fn wordsOf(a: std.mem.Allocator, word: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| try out.print(a, "{s}{s}", .{ if (i > 0) " " else "", word });
    return out.items;
}

test "the_latest_summaries_are_picked_within_1500_words" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try t.expectEqual(null, try promptBlock(a, t.io, dir, "main", true));
    try writeSummaries(a, dir, &.{
        .{ "main/day/2026-11-19.md", "Thursday: gym.\n" },
        .{ "main/day/2026-11-20.md", "Friday: dentist at 10.\n" },
        .{ "main/day/2026-11-21.md", "Saturday: hike.\n" },
        .{ "main/day/2026-11-23.md", "Monday: flight booked.\n" },
        .{ "main/day/2026-11-18.given-up", "Given up.\n" },
        // W47 has a day not shown (the 19th): it is shown; W48 is covered
        .{ "main/week/2026-W48.md", "Week 48: covered by its days.\n" },
        .{ "main/week/2026-W47.md", "Week 47: dentist, gym, hike.\n" },
        .{ "main/week/2026-W46.md", "Week 46: flats.\n" },
        .{ "main/week/2026-W45.md", "Week 45: too old for two.\n" },
        .{ "main/month/2026-07.md", "July: too old for three.\n" },
        .{ "main/month/2026-08.md", "August: holidays.\n" },
        .{ "main/month/2026-09.md", "September: new job.\n" },
        .{ "main/month/2026-10.md", "October: the move.\n" },
        .{ "family/day/2026-11-22.md", "The family's day.\n" },
    });
    const block = (try promptBlock(a, t.io, dir, "main", true)).?;
    try t.expectEqualStrings(
        \\
        \\Earlier in this conversation:
        \\Month 2026-08: August: holidays.
        \\Month 2026-09: September: new job.
        \\Month 2026-10: October: the move.
        \\Week 2026-W46 (2026-11-09 to 2026-11-15): Week 46: flats.
        \\Week 2026-W47 (2026-11-16 to 2026-11-22): Week 47: dentist, gym, hike.
        \\2026-11-20 (Friday): Friday: dentist at 10.
        \\2026-11-21 (Saturday): Saturday: hike.
        \\2026-11-23 (Monday): Monday: flight booked.
        \\history finds anything older than these, or the exact words.
        \\
    , block);
    // a run without history gets no line about it; another conversation only its own
    try t.expect(std.mem.indexOf(u8, (try promptBlock(a, t.io, dir, "main", false)).?, "history") == null);
    try t.expectEqualStrings("\nEarlier in this conversation:\n2026-11-22 (Sunday): The family's day.\n", (try promptBlock(a, t.io, dir, "family", false)).?);
    // over 1,500 words: the oldest go first
    try writeSummaries(a, dir, &.{
        .{ "main/month/2026-08.md", try wordsOf(a, "aug", 600) },
        .{ "main/month/2026-09.md", try wordsOf(a, "sep", 600) },
        .{ "main/month/2026-10.md", try wordsOf(a, "oct", 600) },
    });
    const capped = (try promptBlock(a, t.io, dir, "main", false)).?;
    try t.expect(std.mem.indexOf(u8, capped, "Month 2026-08") == null);
    try t.expect(std.mem.indexOf(u8, capped, "Month 2026-09") != null);
    try t.expect(std.mem.indexOf(u8, capped, "Month 2026-10") != null);
    try t.expect(std.mem.indexOf(u8, capped, "2026-11-23 (Monday)") != null);
    try t.expect(countWords(capped) <= prompt_words + 60);
    // one summary alone over it: its first 1,500 words
    try writeSummaries(a, dir, &.{.{ "main/day/2026-11-23.md", try wordsOf(a, "long", 2000) }});
    const one = (try promptBlock(a, t.io, dir, "main", false)).?;
    try t.expect(std.mem.indexOf(u8, one, "Month") == null);
    try t.expectEqual(1500, std.mem.count(u8, one, "long"));
    // a name that is no conversation's reads nothing
    try t.expectEqual(null, try promptBlock(a, t.io, dir, "../main", true));
}

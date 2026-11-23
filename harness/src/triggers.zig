//! Triggers: the one format of `tasks.ini`, `briefs.ini` and
//! `triggers.ini` (a section's keys give its kind), the name rule, the
//! filters (`match`, `skip`; a workflow's `if` lines share them), `say`
//! lines, when a trigger polls next, and harness's own reading of a
//! trigger. Pure: no I/O.
const std = @import("std");
const config = @import("config.zig");
const conversations = @import("conversations.zig");
const agents = @import("agents.zig");
const rules = @import("rules.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

/// Which file a section is in.
pub const File = enum {
    tasks,
    briefs,
    triggers,

    pub fn fileName(f: File) []const u8 {
        return switch (f) {
            .tasks => "tasks.ini",
            .briefs => "briefs.ini",
            .triggers => "triggers.ini",
        };
    }
};

/// What a section is, by its keys: a schedule (tasks.ini, or `every`/`at`
/// with no source), a brief (`topic` lines), or an event kind.
pub const Kind = enum { schedule, brief, feed, search, page, file, mcp };

pub const Op = enum { has, is, starts, ends, like, gt, lt, ge, le };

/// `FIELD OP VALUE`, `|` between alternative values.
pub const Cond = struct { field: []const u8, op: Op, values: []const []const u8 };

/// One field of an event, as text.
pub const Field = struct { name: []const u8, value: []const u8 };

/// `mcp = SERVER resource URI` (uri) or `mcp = SERVER/TOOL JSON` (tool, input).
pub const Mcp = struct { server: []const u8, uri: []const u8 = "", tool: []const u8 = "", input: []const u8 = "" };

/// What a match does: a run (`do`), a message without the model (`say`),
/// a workflow (`start`, its name), or nothing but feed waiting workflows.
pub const Action = union(enum) { none, do: []const u8, say: []const u8, start: []const u8 };

pub const Trigger = struct {
    name: []const u8,
    file: File,
    kind: Kind,
    /// Its header's line in the file.
    line: usize = 0,
    /// Its name follows the rule (an old tasks.ini or briefs.ini name may not).
    name_ok: bool = true,
    /// Seconds between polls (event kinds) or runs (schedules); null with `at`.
    every_s: ?u32 = null,
    /// Minutes after midnight, the owner's time.
    at: ?u16 = null,
    /// Bit 0 Monday … bit 6 Sunday.
    days: u7 = 0x7f,
    /// Feed addresses, search words, the page's address or the file pattern.
    sources: []const []const u8 = &.{},
    /// A page's value: a path of names and `[N]`.
    json: []const u8 = "",
    mcp: ?Mcp = null,
    /// An MCP tool's list items are told apart by this field.
    key: []const u8 = "id",
    /// A brief's topics.
    topics: []const config.Topic = &.{},
    match: []const Cond = &.{},
    skip: []const Cond = &.{},
    /// A question the model answers yes or no about each event the rules passed.
    check: []const u8 = "",
    action: Action = .none,
    /// `start = workflow NAME TEXT`: TEXT, its `{field}`s filled from the
    /// event, is the instance's input; "": the event as text.
    start_input: []const u8 = "",
    /// The definition a `do` runs.
    agent: []const u8 = "main",
    /// What a `do` run may use, within its definition's tools; null: all of them.
    tools: ?[]const []const u8 = null,
    /// The conversation it posts to.
    to: []const u8 = "main",
    max_runs: u32 = 6,
    max_events: u32 = 20,
    checks_per_day: u32 = 50,
    /// `urgent = yes`: its posts and questions go through quiet hours.
    urgent: bool = false,
    /// `announce = TEXT`: a line said aloud on the house's speakers for
    /// each event (filled like `say`), beside its action; "": none.
    announce: []const u8 = "",
    /// "added by agent:main 2026-11-22 (item 41)": the comment right above its header.
    added: []const u8 = "",
    /// Its lines in the file (the mark above its header included), 1-based.
    first: usize = 0,
    last: usize = 0,

    /// A copy whose every slice is in `a`.
    pub fn clone(tr: Trigger, a: Allocator) !Trigger {
        var o = tr;
        inline for (.{ "name", "json", "key", "check", "agent", "to", "added", "announce", "start_input" }) |f| @field(o, f) = try a.dupe(u8, @field(tr, f));
        o.sources = try dupeList(a, tr.sources);
        if (tr.mcp) |m| o.mcp = .{ .server = try a.dupe(u8, m.server), .uri = try a.dupe(u8, m.uri), .tool = try a.dupe(u8, m.tool), .input = try a.dupe(u8, m.input) };
        const topics = try a.alloc(config.Topic, tr.topics.len);
        for (tr.topics, topics) |tp, *o2| o2.* = .{ .name = try a.dupe(u8, tp.name), .feeds = try dupeList(a, tp.feeds), .searches = try dupeList(a, tp.searches) };
        o.topics = topics;
        o.match = try dupeConds(a, tr.match);
        o.skip = try dupeConds(a, tr.skip);
        o.action = switch (tr.action) {
            .none => .none,
            .do => |x| .{ .do = try a.dupe(u8, x) },
            .say => |x| .{ .say = try a.dupe(u8, x) },
            .start => |x| .{ .start = try a.dupe(u8, x) },
        };
        if (tr.tools) |tl| o.tools = try dupeList(a, tl);
        return o;
    }

    /// An event kind: polled, its events queued.
    pub fn isEvent(tr: Trigger) bool {
        return tr.kind != .schedule and tr.kind != .brief;
    }
};

fn dupeList(a: Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

fn dupeConds(a: Allocator, list: []const Cond) ![]const Cond {
    const out = try a.alloc(Cond, list.len);
    for (list, out) |c, *o| o.* = .{ .field = try a.dupe(u8, c.field), .op = c.op, .values = try dupeList(a, c.values) };
    return out;
}

/// Where a file does not read: its line and why.
pub const Diag = struct { line: usize = 0, why: []const u8 = "" };
pub const Error = error{ BadTrigger, OutOfMemory };

/// The words the trigger and task commands take: never a name.
const command_words = [_][]const u8{ "add", "rm", "pause", "resume", "run", "test", "list", "show" };

/// The name rule: 1 to 64 of a-z, 0-9, `-` and `_`, starting with a letter
/// or digit, and none of the commands' words.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    for (command_words) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

const name_rule = "a name takes 1 to 64 of a-z, 0-9, - and _, starting with a letter or digit, and is none of add, rm, pause, resume, run, test, list and show";

/// The fields an event of `kind` has; null: any (an MCP tool's items).
pub fn fieldsOf(kind: Kind) ?[]const []const u8 {
    return switch (kind) {
        .feed => &.{ "title", "link", "text", "date", "source" },
        .search => &.{ "title", "link", "date" },
        .page => &.{ "text", "removed", "value", "change", "move" },
        .file => &.{ "path", "change", "size" },
        .mcp => null,
        .schedule, .brief => &.{},
    };
}

/// An event kind's `every`: its default and the least it takes, in seconds.
fn everyOf(kind: Kind) struct { default: u32, least: u32 } {
    return switch (kind) {
        .feed, .page => .{ .default = 3600, .least = 300 },
        .search => .{ .default = 6 * 3600, .least = 3600 },
        .file => .{ .default = 60, .least = 30 },
        .mcp => .{ .default = 900, .least = 60 },
        .schedule, .brief => .{ .default = 0, .least = 300 },
    };
}

// ---- reading the files ----

const Line = struct { section: []const u8, key: []const u8, value: []const u8, n: usize };
const Head = struct { name: []const u8, n: usize, mark: []const u8, first: usize };

/// A section's key lines, in order, and where it is.
const Group = struct { name: []const u8, head: Head, lines: []const Line };

fn bad(diag: *Diag, n: usize, why: []const u8) Error {
    diag.* = .{ .line = n, .why = why };
    return error.BadTrigger;
}

fn badf(a: Allocator, diag: *Diag, n: usize, comptime fmt: []const u8, args: anytype) Error {
    return bad(diag, n, try std.fmt.allocPrint(a, fmt, args));
}

/// The sections of `text` in the order they appear, as config.zig reads
/// INI: `[section]`, `key = value`, comments (in triggers.ini only whole
/// lines starting with `;` or `#`, so free text keeps them: `say = PR
/// #{number}`; elsewhere also after a space); a line that is neither is
/// an error. A section's lines are those after its
/// header up to the next header of another name; a name again later is an
/// error; a header with no keys makes no section.
fn groups(a: Allocator, text: []const u8, file: File, diag: *Diag) Error![]Group {
    var lines: std.ArrayList(Line) = .empty;
    var heads: std.ArrayList(Head) = .empty;
    var section: []const u8 = "";
    var mark: []const u8 = "";
    var mark_n: usize = 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, if (file == .triggers) wholeLineComment(raw) else config.stripComment(raw), " \t\r");
        if (line.len == 0) {
            // "; added by …" right above a header marks it
            const whole = std.mem.trim(u8, raw, " \t\r");
            mark = "";
            if (whole.len > 0 and (whole[0] == ';' or whole[0] == '#')) {
                const c = std.mem.trim(u8, whole[1..], " \t");
                if (std.mem.startsWith(u8, c, "added by ")) {
                    mark = c;
                    mark_n = n;
                }
            }
            continue;
        }
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return bad(diag, n, "not a [section] or key = value line");
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (section.len == 0) return bad(diag, n, "a [section] needs a name");
            const marked = mark.len > 0 and mark_n + 1 == n;
            try heads.append(a, .{ .name = section, .n = n, .mark = if (marked) mark else "", .first = if (marked) mark_n else n });
            mark = "";
            continue;
        }
        mark = "";
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return bad(diag, n, "not a [section] or key = value line");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return bad(diag, n, "not a [section] or key = value line");
        if (section.len == 0) return bad(diag, n, "a key = value line before the first [section]");
        try lines.append(a, .{ .section = section, .key = key, .value = std.mem.trim(u8, line[eq + 1 ..], " \t"), .n = n });
    }
    var out: std.ArrayList(Group) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const name = lines.items[i].section;
        var j = i;
        while (j < lines.items.len and std.mem.eql(u8, lines.items[j].section, name)) j += 1;
        // its header: the last of that name before its first line
        var head: Head = .{ .name = name, .n = lines.items[i].n, .mark = "", .first = lines.items[i].n };
        for (heads.items) |h| if (h.n < lines.items[i].n and std.mem.eql(u8, h.name, name)) {
            head = h;
        };
        for (out.items) |g| if (std.mem.eql(u8, g.name, name)) return badf(a, diag, head.n, "the name {s} is used twice", .{name});
        try out.append(a, .{ .name = name, .head = head, .lines = lines.items[i..j] });
        i = j;
    }
    return out.items;
}

/// `raw` unless it is a comment line (its first character past spaces `;`
/// or `#`): "".
fn wholeLineComment(raw: []const u8) []const u8 {
    const tl = std.mem.trimStart(u8, raw, " \t");
    return if (tl.len > 0 and (tl[0] == ';' or tl[0] == '#')) "" else raw;
}

/// Reads a tasks.ini, briefs.ini or triggers.ini: its sections as
/// triggers. tasks.ini and briefs.ini take only their keys, as before; a
/// name there that breaks the rule still reads (`name_ok` false). In
/// triggers.ini the keys give the kind and a name must follow the rule.
/// The triggers point into `text`: it must live as long as they do.
pub fn parse(a: Allocator, text: []const u8, file: File, diag: *Diag) Error![]Trigger {
    var out: std.ArrayList(Trigger) = .empty;
    for (try groups(a, text, file, diag)) |g| {
        var tr = switch (file) {
            .tasks => try taskSection(a, g, diag),
            .briefs => try briefSection(a, g, diag),
            .triggers => try triggerSection(a, g, diag),
        };
        tr.name = g.name;
        tr.file = file;
        tr.line = g.head.n;
        tr.first = g.head.first;
        tr.last = g.lines[g.lines.len - 1].n;
        tr.added = g.head.mark;
        tr.name_ok = validName(g.name);
        if (file == .triggers and !tr.name_ok) return bad(diag, g.head.n, name_rule);
        try out.append(a, tr);
    }
    return out.items;
}

/// A tasks.ini section: at, every (minutes, at least 5), days, do, to,
/// agent; `do` and one of `at` and `every`.
fn taskSection(a: Allocator, g: Group, diag: *Diag) Error!Trigger {
    var tr: Trigger = .{ .name = g.name, .file = .tasks, .kind = .schedule };
    var do: []const u8 = "";
    for (g.lines) |l| {
        if (std.mem.eql(u8, l.key, "at")) {
            tr.at = config.parseClock(l.value) catch return bad(diag, l.n, "at is HH:MM");
        } else if (std.mem.eql(u8, l.key, "every")) {
            tr.every_s = 60 * (config.parseEvery(l.value) catch return bad(diag, l.n, "every is like 15m or 2h, at least 5m"));
        } else if (std.mem.eql(u8, l.key, "days")) {
            tr.days = config.parseDays(l.value) catch return bad(diag, l.n, "days are mon, tue, wed, thu, fri, sat, sun, separated by commas");
        } else if (std.mem.eql(u8, l.key, "do")) {
            do = l.value;
        } else if (std.mem.eql(u8, l.key, "to")) {
            if (!conversations.validName(l.value)) return bad(diag, l.n, "to names a conversation: a-z, 0-9, - and _");
            tr.to = l.value;
        } else if (std.mem.eql(u8, l.key, "agent")) {
            if (!agents.validName(l.value)) return bad(diag, l.n, "agent names a definition: a-z, 0-9 and -");
            tr.agent = l.value;
        } else return badf(a, diag, l.n, "tasks.ini takes at, every, days, do, to and agent, not {s}", .{l.key});
    }
    if (do.len == 0) return bad(diag, g.head.n, "a task needs do");
    if ((tr.at == null) == (tr.every_s == null)) return bad(diag, g.head.n, "a task needs every or at, not both");
    tr.action = .{ .do = do };
    return tr;
}

/// A briefs.ini section: at (default 07:00), to, topic lines.
fn briefSection(a: Allocator, g: Group, diag: *Diag) Error!Trigger {
    var tr: Trigger = .{ .name = g.name, .file = .briefs, .kind = .brief, .at = 7 * 60 };
    var topics: std.ArrayList(config.Topic) = .empty;
    for (g.lines) |l| {
        if (std.mem.eql(u8, l.key, "at")) {
            tr.at = config.parseClock(l.value) catch return bad(diag, l.n, "at is HH:MM");
        } else if (std.mem.eql(u8, l.key, "to")) {
            if (!conversations.validName(l.value)) return bad(diag, l.n, "to names a conversation: a-z, 0-9, - and _");
            tr.to = l.value;
        } else if (std.mem.eql(u8, l.key, "topic")) {
            try topics.append(a, config.parseTopic(a, l.value) catch return bad(diag, l.n, "topic = Name | feed URL | search: words"));
        } else return badf(a, diag, l.n, "briefs.ini takes at, to and topic, not {s}", .{l.key});
    }
    tr.topics = topics.items;
    return tr;
}

const source_keys = [_][]const u8{ "topic", "feed", "search", "page", "file", "mcp" };
const other_keys = [_][]const u8{ "every", "at", "days", "match", "skip", "check", "do", "say", "start", "agent", "tools", "to", "max_runs", "max_events", "checks_per_day", "json", "key", "urgent", "announce" };

fn kindOfKey(key: []const u8) ?Kind {
    if (std.mem.eql(u8, key, "topic")) return .brief;
    if (std.mem.eql(u8, key, "feed")) return .feed;
    if (std.mem.eql(u8, key, "search")) return .search;
    if (std.mem.eql(u8, key, "page")) return .page;
    if (std.mem.eql(u8, key, "file")) return .file;
    if (std.mem.eql(u8, key, "mcp")) return .mcp;
    return null;
}

fn oneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// Whether a key goes with a trigger of `kind`.
fn keyFits(kind: Kind, key: []const u8) bool {
    return switch (kind) {
        .schedule => oneOf(key, &.{ "every", "at", "days", "do", "say", "start", "to", "agent", "urgent" }),
        .brief => oneOf(key, &.{ "topic", "at", "to" }),
        else => blk: {
            if (oneOf(key, &.{ "every", "at", "days", "match", "skip", "check", "do", "say", "start", "agent", "tools", "to", "max_runs", "max_events", "checks_per_day", "urgent", "announce" })) break :blk true;
            if (kindOfKey(key)) |k| break :blk k == kind;
            if (std.mem.eql(u8, key, "json")) break :blk kind == .page;
            if (std.mem.eql(u8, key, "key")) break :blk kind == .mcp;
            break :blk false;
        },
    };
}

/// A triggers.ini section: its keys give its kind.
fn triggerSection(a: Allocator, g: Group, diag: *Diag) Error!Trigger {
    // the kind first, so every value is read as its kind takes it
    var kind: ?Kind = null;
    var kind_key: []const u8 = "";
    for (g.lines) |l| {
        if (kindOfKey(l.key)) |k| {
            if (kind) |had| if (had != k) return badf(a, diag, l.n, "a trigger has one kind of source: {s} or {s}, not both", .{ kind_key, l.key });
            kind = k;
            kind_key = l.key;
        } else if (!oneOf(l.key, &other_keys)) return badf(a, diag, l.n, "unknown key: {s}", .{l.key});
    }
    const k = kind orelse .schedule;
    var tr: Trigger = .{ .name = g.name, .file = .triggers, .kind = k };
    var sources: std.ArrayList([]const u8) = .empty;
    var topics: std.ArrayList(config.Topic) = .empty;
    var match: std.ArrayList(Cond) = .empty;
    var skip: std.ArrayList(Cond) = .empty;
    var action_line: usize = 0;
    var every_line: usize = 0;
    var at_line: usize = 0;
    var tools_line: usize = 0;
    for (g.lines) |l| {
        const v = l.value;
        if (!keyFits(k, l.key)) return badf(a, diag, l.n, "{s} is not a key of a {s} trigger", .{ l.key, @tagName(k) });
        if (std.mem.eql(u8, l.key, "every")) {
            every_line = l.n;
            if (k == .schedule) {
                tr.every_s = 60 * (config.parseEvery(v) catch return bad(diag, l.n, "every is like 15m or 2h, at least 5 min"));
            } else {
                const s = parseDuration(v) orelse return bad(diag, l.n, "every is like 30s, 5m, 1h or 1d");
                const least = everyOf(k).least;
                if (s < least) return badf(a, diag, l.n, "every for a {s} trigger is at least {s}", .{ @tagName(k), try fmtDuration(a, least) });
                tr.every_s = s;
            }
        } else if (std.mem.eql(u8, l.key, "at")) {
            at_line = l.n;
            tr.at = config.parseClock(v) catch return bad(diag, l.n, "at is HH:MM");
        } else if (std.mem.eql(u8, l.key, "days")) {
            tr.days = config.parseDays(v) catch return bad(diag, l.n, "days are mon, tue, wed, thu, fri, sat, sun, separated by commas");
        } else if (std.mem.eql(u8, l.key, "match") or std.mem.eql(u8, l.key, "skip")) {
            var why: []const u8 = "";
            const c = condOf(a, v, k, &why) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadValue => return bad(diag, l.n, why),
            };
            try (if (std.mem.eql(u8, l.key, "match")) &match else &skip).append(a, c);
        } else if (std.mem.eql(u8, l.key, "check")) {
            if (v.len == 0) return bad(diag, l.n, "check needs a question");
            tr.check = v;
        } else if (std.mem.eql(u8, l.key, "do") or std.mem.eql(u8, l.key, "say") or std.mem.eql(u8, l.key, "start")) {
            if (action_line != 0) return bad(diag, l.n, "a trigger takes one of do, say and start");
            action_line = l.n;
            if (v.len == 0) return badf(a, diag, l.n, "{s} needs its text", .{l.key});
            if (std.mem.eql(u8, l.key, "do")) {
                tr.action = .{ .do = v };
            } else if (std.mem.eql(u8, l.key, "say")) {
                if (try unknownPlaceholder(a, v, k)) |why| return bad(diag, l.n, why);
                tr.action = .{ .say = v };
            } else {
                const word = "workflow ";
                const rest = if (std.mem.startsWith(u8, v, word)) std.mem.trim(u8, v[word.len..], " \t") else "";
                const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                const name = rest[0..sp];
                if (!workflowName(name)) return bad(diag, l.n, "start = workflow NAME (a-z, 0-9, - and _), then the text it starts with, if any");
                const input = std.mem.trim(u8, rest[sp..], " \t");
                if (try unknownPlaceholder(a, input, k)) |why| return bad(diag, l.n, why);
                tr.action = .{ .start = name };
                tr.start_input = input;
            }
        } else if (std.mem.eql(u8, l.key, "agent")) {
            if (!agents.validName(v)) return bad(diag, l.n, "agent names a definition: a-z, 0-9 and -");
            tr.agent = v;
        } else if (std.mem.eql(u8, l.key, "tools")) {
            tools_line = l.n;
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |raw| {
                const name = std.mem.trim(u8, raw, " \t");
                if (!toolName(name)) return bad(diag, l.n, "tools are tool names, SERVER/TOOL or SERVER/*, separated by commas");
                try list.append(a, name);
            }
            tr.tools = list.items;
        } else if (std.mem.eql(u8, l.key, "to")) {
            if (!conversations.validName(v)) return bad(diag, l.n, "to names a conversation: a-z, 0-9, - and _");
            tr.to = v;
        } else if (std.mem.eql(u8, l.key, "max_runs") or std.mem.eql(u8, l.key, "max_events") or std.mem.eql(u8, l.key, "checks_per_day")) {
            const x = std.fmt.parseInt(u32, v, 10) catch 0;
            if (x == 0 or (std.mem.eql(u8, l.key, "max_events") and x > 200)) return badf(a, diag, l.n, "{s} is a whole number from 1{s}", .{ l.key, if (std.mem.eql(u8, l.key, "max_events")) " to 200" else "" });
            if (std.mem.eql(u8, l.key, "max_runs")) tr.max_runs = x else if (std.mem.eql(u8, l.key, "max_events")) tr.max_events = x else tr.checks_per_day = x;
        } else if (std.mem.eql(u8, l.key, "urgent")) {
            tr.urgent = config.parseBool(v) orelse return bad(diag, l.n, "urgent = yes or no: yes goes through quiet hours");
        } else if (std.mem.eql(u8, l.key, "announce")) {
            if (v.len == 0) return bad(diag, l.n, "announce needs its text: what the house's speakers say");
            if (try unknownPlaceholder(a, v, k)) |why| return bad(diag, l.n, why);
            tr.announce = v;
        } else if (std.mem.eql(u8, l.key, "json")) {
            if (!jsonPath(v)) return bad(diag, l.n, "json is a path of names and [N], like data.amount or items[0].price");
            tr.json = v;
        } else if (std.mem.eql(u8, l.key, "key")) {
            if (!fieldName(v)) return bad(diag, l.n, "key names a field of the tool's items, like id or number");
            tr.key = v;
        } else if (std.mem.eql(u8, l.key, "feed")) {
            if (!webAddress(v)) return bad(diag, l.n, "feed = an http or https address");
            try sources.append(a, v);
        } else if (std.mem.eql(u8, l.key, "search")) {
            if (v.len == 0) return bad(diag, l.n, "search = the words to search for");
            try sources.append(a, v);
        } else if (std.mem.eql(u8, l.key, "page")) {
            if (sources.items.len > 0) return bad(diag, l.n, "a trigger reads one page");
            if (!webAddress(v)) return bad(diag, l.n, "page = an http or https address");
            try sources.append(a, v);
        } else if (std.mem.eql(u8, l.key, "file")) {
            if (sources.items.len > 0) return bad(diag, l.n, "a trigger watches one folder");
            if (try filePattern(a, v)) |p| try sources.append(a, p) else return bad(diag, l.n, "file = FOLDER/PATTERN, a folder inside the workspace (no ..), * only in the last part");
        } else if (std.mem.eql(u8, l.key, "mcp")) {
            if (tr.mcp != null) return bad(diag, l.n, "a trigger reads one MCP source");
            var why: []const u8 = "";
            tr.mcp = mcpSource(a, v, &why) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadValue => return bad(diag, l.n, why),
            };
        } else if (std.mem.eql(u8, l.key, "topic")) {
            try topics.append(a, config.parseTopic(a, v) catch return bad(diag, l.n, "topic = Name | feed URL | search: words"));
        }
    }
    tr.sources = sources.items;
    tr.topics = topics.items;
    tr.match = match.items;
    tr.skip = skip.items;
    if (every_line != 0 and at_line != 0) return bad(diag, @max(every_line, at_line), "every or at, not both");
    if (tools_line != 0 and tr.action != .do) return bad(diag, tools_line, "tools go with do");
    switch (k) {
        .schedule => {
            if (tr.action == .none) return bad(diag, g.head.n, "a schedule needs one of do, say or start");
            if (tr.every_s == null and tr.at == null) return bad(diag, g.head.n, "a schedule needs every or at");
        },
        .brief => if (tr.at == null) {
            tr.at = 7 * 60;
        },
        else => if (tr.at == null and tr.every_s == null) {
            tr.every_s = everyOf(k).default;
        },
    }
    return tr;
}

/// "30s", "5m", "1h", "2d" in seconds.
pub fn parseDuration(v: []const u8) ?u32 {
    if (v.len < 2) return null;
    const n = std.fmt.parseInt(u32, v[0 .. v.len - 1], 10) catch return null;
    if (n == 0) return null;
    const unit: u32 = switch (v[v.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return null,
    };
    return std.math.mul(u32, n, unit) catch null;
}

/// "30 s", "5 min", "1 h", "2 days".
pub fn fmtDuration(a: Allocator, s: u32) ![]const u8 {
    if (s >= 86400 and s % 86400 == 0) return std.fmt.allocPrint(a, "{d} day{s}", .{ s / 86400, if (s == 86400) "" else "s" });
    if (s >= 3600 and s % 3600 == 0) return std.fmt.allocPrint(a, "{d} h", .{s / 3600});
    if (s >= 60 and s % 60 == 0) return std.fmt.allocPrint(a, "{d} min", .{s / 60});
    return std.fmt.allocPrint(a, "{d} s", .{s});
}

fn workflowName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// A tool as files name it: a built-in's name, `SERVER/TOOL`, `SERVER/*`, `*`.
fn toolName(n: []const u8) bool {
    if (n.len == 0 or n.len > 100) return false;
    var slashes: usize = 0;
    for (n) |ch| {
        if (ch == '/') {
            slashes += 1;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '*')) return false;
    }
    return slashes <= 1;
}

fn fieldName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    return true;
}

fn webAddress(v: []const u8) bool {
    if (!(std.mem.startsWith(u8, v, "https://") or std.mem.startsWith(u8, v, "http://"))) return false;
    return std.mem.indexOfAny(u8, v, " \t\r\n") == null and v.len > "http://".len;
}

/// `data.amount`, `items[0].price`: names of letters, digits, `_` and `-`,
/// each with any number of `[N]`.
fn jsonPath(p: []const u8) bool {
    if (p.len == 0) return false;
    var it = std.mem.splitScalar(u8, p, '.');
    while (it.next()) |part| {
        const br = std.mem.indexOfScalar(u8, part, '[') orelse part.len;
        if (br == 0 and part.len == 0) return false;
        for (part[0..br]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
        var rest = part[br..];
        if (br == 0 and rest.len == 0) return false;
        while (rest.len > 0) {
            if (rest[0] != '[') return false;
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return false;
            _ = std.fmt.parseInt(u32, rest[1..close], 10) catch return false;
            rest = rest[close + 1 ..];
        }
    }
    return true;
}

/// `FOLDER/PATTERN` with `/` between the parts (`\` read as `/`): a
/// relative folder with no `..` and no `*`, and a pattern for the files
/// in it; null when it is not one.
fn filePattern(a: Allocator, v: []const u8) !?[]const u8 {
    const p = try a.dupe(u8, v);
    std.mem.replaceScalar(u8, p, '\\', '/');
    if (p.len == 0 or p[0] == '/' or std.mem.indexOfScalar(u8, p, ':') != null) return null;
    const slash = std.mem.lastIndexOfScalar(u8, p, '/');
    const pattern = if (slash) |s| p[s + 1 ..] else p;
    if (pattern.len == 0 or std.mem.eql(u8, pattern, "..") or std.mem.eql(u8, pattern, ".")) return null;
    if (slash) |s| {
        var it = std.mem.splitScalar(u8, p[0..s], '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '*') != null) return null;
        }
    }
    return p;
}

const Bad = error{ BadValue, OutOfMemory };

fn mcpServerName(n: []const u8) bool {
    if (n.len == 0 or n.len > 32 or std.mem.indexOf(u8, n, "__") != null) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// `SERVER resource URI` or `SERVER/TOOL JSON` (an object; none: `{}`).
fn mcpSource(a: Allocator, v: []const u8, why: *[]const u8) Bad!Mcp {
    const shape = "mcp = SERVER resource URI, or SERVER/TOOL with a JSON object";
    const sp = std.mem.indexOfAny(u8, v, " \t");
    const head = v[0 .. sp orelse v.len];
    const rest = if (sp) |i| std.mem.trim(u8, v[i..], " \t") else "";
    if (std.mem.indexOfScalar(u8, head, '/')) |slash| {
        const server = head[0..slash];
        const tool = head[slash + 1 ..];
        if (!mcpServerName(server) or tool.len == 0 or tool.len > 64) {
            why.* = shape;
            return error.BadValue;
        }
        for (tool) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) {
            why.* = shape;
            return error.BadValue;
        };
        // a poll would say it again and again, at night too
        if (std.mem.eql(u8, tool, "announce")) {
            why.* = "announce speaks aloud: a trigger doesn't poll it (announce = TEXT says a line per event)";
            return error.BadValue;
        }
        const input = if (rest.len == 0) "{}" else rest;
        const parsed = jv.parse(a, input);
        if (parsed == null or parsed.? != .object) {
            why.* = "the tool's input is a JSON object, like {\"repo\": \"zigworks\"}";
            return error.BadValue;
        }
        return .{ .server = server, .tool = tool, .input = input };
    }
    const word = "resource";
    if (!mcpServerName(head) or !std.mem.startsWith(u8, rest, word)) {
        why.* = shape;
        return error.BadValue;
    }
    const uri = std.mem.trim(u8, rest[word.len..], " \t");
    if (uri.len == 0 or rest.len == word.len or (rest[word.len] != ' ' and rest[word.len] != '\t')) {
        why.* = shape;
        return error.BadValue;
    }
    return .{ .server = head, .uri = uri };
}

/// Why a `say` names a field the kind's events do not have; null when
/// every `{name}` is one.
fn unknownPlaceholder(a: Allocator, template: []const u8, kind: Kind) !?[]const u8 {
    const known = fieldsOf(kind) orelse return null;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] != '{') continue;
        if (i + 1 < template.len and template[i + 1] == '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse return null;
        const name = template[i + 1 .. close];
        if (!oneOf(name, known)) {
            if (known.len == 0) return try std.fmt.allocPrint(a, "{{{s}}} is no field: a {s} has none", .{ name, @tagName(kind) });
            return try std.fmt.allocPrint(a, "{{{s}}} is no field of a {s} event ({s})", .{ name, @tagName(kind), try std.mem.join(a, ", ", known) });
        }
        i = close;
    }
    return null;
}

// ---- filters ----

const op_words = [_]struct { []const u8, Op }{
    .{ "has", .has },  .{ "is", .is },  .{ "starts", .starts }, .{ "ends", .ends }, .{ "like", .like },
    .{ ">", .gt },     .{ "<", .lt },   .{ ">=", .ge },         .{ "<=", .le },
};

/// `FIELD OP VALUE` with `|` between alternative values; for `kind` the
/// field must be one its events have (null: any).
pub fn parseCond(a: Allocator, text: []const u8, kind: ?Kind) !Cond {
    var why: []const u8 = "";
    return condOf(a, text, kind, &why) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadValue => error.BadTrigger,
    };
}

fn condOf(a: Allocator, text: []const u8, kind: ?Kind, why: *[]const u8) Bad!Cond {
    const shape = "a filter is FIELD OP VALUE, OP one of has, is, starts, ends, like, >, <, >=, <=, | between values";
    var words = std.mem.tokenizeAny(u8, text, " \t");
    const field = words.next() orelse {
        why.* = shape;
        return error.BadValue;
    };
    const op_word = words.next() orelse {
        why.* = shape;
        return error.BadValue;
    };
    const op = for (op_words) |ow| {
        if (std.mem.eql(u8, ow[0], op_word)) break ow[1];
    } else {
        why.* = shape;
        return error.BadValue;
    };
    if (!fieldName(field)) {
        why.* = shape;
        return error.BadValue;
    }
    if (kind) |k| if (fieldsOf(k)) |known| if (!oneOf(field, known)) {
        why.* = if (known.len == 0) try std.fmt.allocPrint(a, "a {s} has no fields to filter", .{@tagName(k)}) else try std.fmt.allocPrint(a, "{s} events have {s}", .{ @tagName(k), try std.mem.join(a, ", ", known) });
        return error.BadValue;
    };
    var values: std.ArrayList([]const u8) = .empty;
    var alts = std.mem.splitScalar(u8, std.mem.trim(u8, words.rest(), " \t"), '|');
    while (alts.next()) |raw| {
        const v = std.mem.trim(u8, raw, " \t");
        if (v.len == 0) {
            why.* = "a filter needs a value after its operator (| between values)";
            return error.BadValue;
        }
        if (numeric(op) and number(v) == null) {
            why.* = ">, <, >= and <= compare numbers";
            return error.BadValue;
        }
        try values.append(a, v);
    }
    return .{ .field = field, .op = op, .values = values.items };
}

fn numeric(op: Op) bool {
    return switch (op) {
        .gt, .lt, .ge, .le => true,
        else => false,
    };
}

fn number(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return v;
}

fn valueOf(fields: []const Field, name: []const u8) ?[]const u8 {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// Whether a filter holds for an event: its field, compared with any of
/// its values (has, is, starts, ends and like ignore case; the others
/// compare numbers). A field the event lacks never holds.
pub fn holds(c: Cond, fields: []const Field) bool {
    const v = valueOf(fields, c.field) orelse return false;
    for (c.values) |want| {
        const ok = switch (c.op) {
            .has => std.ascii.findIgnoreCase(v, want) != null,
            .is => std.ascii.eqlIgnoreCase(v, want),
            .starts => std.ascii.startsWithIgnoreCase(v, want),
            .ends => std.ascii.endsWithIgnoreCase(v, want),
            .like => rules.globCase(want, v, true),
            .gt, .lt, .ge, .le => blk: {
                const x = number(v) orelse break :blk false;
                const y = number(want) orelse break :blk false;
                break :blk switch (c.op) {
                    .gt => x > y,
                    .lt => x < y,
                    .ge => x >= y,
                    .le => x <= y,
                    else => unreachable,
                };
            },
        };
        if (ok) return true;
    }
    return false;
}

/// Every `match` holds and no `skip` does.
pub fn passes(tr: Trigger, fields: []const Field) bool {
    for (tr.match) |c| if (!holds(c, fields)) return false;
    for (tr.skip) |c| if (holds(c, fields)) return false;
    return true;
}

// ---- say ----

/// A `say` line for one event: each `{field}` its value (`{change}` signed
/// with one decimal, `{move}` one decimal), a field it lacks empty, `{{` a
/// brace.
pub fn fill(a: Allocator, template: []const u8, fields: []const Field) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch != '{') {
            try out.append(a, ch);
            i += 1;
            continue;
        }
        if (i + 1 < template.len and template[i + 1] == '{') {
            try out.append(a, '{');
            i += 2;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse {
            try out.appendSlice(a, template[i..]);
            break;
        };
        const name = template[i + 1 .. close];
        const v = valueOf(fields, name) orelse "";
        if (std.mem.eql(u8, name, "change") or std.mem.eql(u8, name, "move")) {
            if (number(v)) |x| {
                if (std.mem.eql(u8, name, "change") and x >= 0) try out.append(a, '+');
                try out.print(a, "{d:.1}", .{x});
            } else try out.appendSlice(a, v);
        } else try out.appendSlice(a, v);
        i = close + 1;
    }
    return out.items;
}

// ---- when ----

/// When a trigger polls (or a schedule runs) next after `after`: every
/// `every_s` with up to a tenth of it more (`jitter`, cut to that), on its
/// days; or at `at` (the owner's time, `utc_offset` minutes east) on the
/// next of its days.
pub fn nextPoll(tr: Trigger, after: i64, utc_offset: i32, jitter: u32) i64 {
    const off: i64 = @as(i64, utc_offset) * 60;
    if (tr.at) |at| {
        var day = @divFloor(after + off, 86400);
        while (true) : (day += 1) {
            const due = day * 86400 + @as(i64, at) * 60 - off;
            if (due <= after) continue;
            if (tr.days & (@as(u7, 1) << util.weekday(day)) == 0) continue;
            return due;
        }
    }
    const every: i64 = tr.every_s orelse 3600;
    var next = after + every + @min(@as(i64, jitter), @divFloor(every, 10));
    if (tr.days != 0x7f and tr.days != 0) {
        // on a day it does not run: the start of the next one it does
        var day = @divFloor(next + off, 86400);
        if (tr.days & (@as(u7, 1) << util.weekday(day)) == 0) {
            while (tr.days & (@as(u7, 1) << util.weekday(day)) == 0) day += 1;
            next = day * 86400 - off;
        }
    }
    return next;
}

// ---- harness's reading ----

/// What a trigger does, in harness's words (shown before the owner allows
/// the agent's `trigger add`, and by /trigger NAME): "Polls 1 feed every 1
/// h, no model call; a new item whose title has "release" starts a run of
/// main; at most 6 runs an hour."
pub fn reading(a: Allocator, tr: Trigger, check_model: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (tr.kind) {
        .schedule => {
            try out.appendSlice(a, try when(a, tr, true));
            switch (tr.action) {
                .do => |x| try out.print(a, ", a run of {s}: {s}", .{ tr.agent, util.cut(x, 200) }),
                .say => |x| try out.print(a, ", no model call, says: {s}", .{x}),
                .start => |x| {
                    try out.print(a, ", starts workflow {s}", .{x});
                    if (tr.start_input.len > 0) try out.print(a, " with \"{s}\"", .{tr.start_input});
                },
                .none => {},
            }
            if (!std.mem.eql(u8, tr.to, "main")) try out.print(a, "; posts to {s}", .{tr.to});
            if (tr.urgent) try out.appendSlice(a, urgent_words);
            try out.append(a, '.');
            return out.items;
        },
        .brief => {
            try out.print(a, "A brief of {d} topic{s}{s}", .{ tr.topics.len, if (tr.topics.len == 1) "" else "s", try when(a, tr, false) });
            if (!std.mem.eql(u8, tr.to, "main")) try out.print(a, "; posts to {s}", .{tr.to});
            try out.append(a, '.');
            return out.items;
        },
        .feed => try out.print(a, "Polls {d} feed{s}", .{ tr.sources.len, if (tr.sources.len == 1) "" else "s" }),
        .search => {
            try out.appendSlice(a, "Searches for ");
            for (tr.sources, 0..) |s, i| try out.print(a, "{s}\"{s}\"", .{ if (i > 0) ", " else "", s });
        },
        .page => try out.print(a, "Reads {s}", .{tr.sources[0]}),
        .file => try out.print(a, "Watches {s}", .{tr.sources[0]}),
        .mcp => {
            const m = tr.mcp.?;
            if (m.tool.len > 0) try out.print(a, "Calls {s}/{s} {s}", .{ m.server, m.tool, m.input }) else try out.print(a, "Reads {s} of {s}", .{ m.uri, m.server });
        },
    }
    try out.appendSlice(a, try when(a, tr, false));
    if (tr.kind == .page and tr.json.len > 0) try out.print(a, " (the value at {s})", .{tr.json});
    if (tr.check.len > 0)
        try out.print(a, ", asks {s} \"{s}\" of each item the rules pass (at most {d} a day)", .{ check_model, tr.check, tr.checks_per_day })
    else
        try out.appendSlice(a, ", no model call");
    const what: []const u8 = switch (tr.kind) {
        .page => if (tr.json.len > 0) "a new value" else "a change",
        .file => "a new, changed or removed file",
        .mcp => if (tr.mcp.?.tool.len > 0) try std.fmt.allocPrint(a, "a new item (by {s})", .{tr.key}) else "a change",
        else => "a new item",
    };
    try out.print(a, "; {s}", .{what});
    if (tr.match.len > 0) {
        try out.appendSlice(a, " whose ");
        for (tr.match, 0..) |c, i| try out.print(a, "{s}{s}", .{ if (i > 0) " and " else "", try condText(a, c) });
    }
    if (tr.skip.len > 0) {
        try out.appendSlice(a, ", unless ");
        for (tr.skip, 0..) |c, i| try out.print(a, "{s}{s}", .{ if (i > 0) " or " else "", try condText(a, c) });
        try out.append(a, ',');
    }
    switch (tr.action) {
        .do => {
            try out.print(a, " starts a run of {s}", .{tr.agent});
            if (tr.tools) |tl| try out.print(a, " with tools {s}", .{try std.mem.join(a, ", ", tl)});
            try out.print(a, "; at most {d} run{s} an hour", .{ tr.max_runs, if (tr.max_runs == 1) "" else "s" });
            if (tr.max_events != 20) try out.print(a, ", {d} events a run", .{tr.max_events});
        },
        .say => |x| try out.print(a, " says: {s}", .{x}),
        .start => |x| {
            try out.print(a, " starts workflow {s}", .{x});
            if (tr.start_input.len > 0) try out.print(a, " with \"{s}\"", .{tr.start_input});
            try out.appendSlice(a, ", an instance each");
        },
        .none => try out.appendSlice(a, " is kept for workflows that wait on it"),
    }
    if (tr.announce.len > 0) try out.print(a, "; says it on the house's speakers: {s}", .{tr.announce});
    if (!std.mem.eql(u8, tr.to, "main")) try out.print(a, "; posts to {s}", .{tr.to});
    if (tr.urgent) try out.appendSlice(a, urgent_words);
    try out.append(a, '.');
    return out.items;
}

const urgent_words = "; urgent: it goes through quiet hours";

/// " every 1 h", " at 07:00 on mon, fri" (capitalized: "Every 15 min").
fn when(a: Allocator, tr: Trigger, capital: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (tr.at) |at| {
        try out.print(a, "{s}t {d:0>2}:{d:0>2}", .{ if (capital) "A" else " a", at / 60, at % 60 });
    } else {
        try out.print(a, "{s}very {s}", .{ if (capital) "E" else " e", try fmtDuration(a, tr.every_s orelse 3600) });
    }
    if (tr.days != 0x7f) {
        try out.appendSlice(a, " on ");
        var first = true;
        for (config.day_names, 0..) |d, i| if (tr.days & (@as(u7, 1) << @intCast(i)) != 0) {
            try out.print(a, "{s}{s}", .{ if (first) "" else ", ", d });
            first = false;
        };
    }
    return out.items;
}

/// `title has "release" or "rc"`, `move > 3`.
pub fn condText(a: Allocator, c: Cond) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const op: []const u8 = switch (c.op) {
        .has => "has",
        .is => "is",
        .starts => "starts with",
        .ends => "ends with",
        .like => "is like",
        .gt => ">",
        .lt => "<",
        .ge => ">=",
        .le => "<=",
    };
    try out.print(a, "{s} {s} ", .{ c.field, op });
    for (c.values, 0..) |v, i| {
        if (i > 0) try out.appendSlice(a, " or ");
        if (numeric(c.op)) try out.appendSlice(a, v) else try out.print(a, "\"{s}\"", .{v});
    }
    return out.items;
}

/// What is wrong with a triggers.ini, as /reload and the tool say it:
/// "triggers.ini line 3 has an error: every = 1m (every for a feed trigger
/// is at least 5 min)"; null when it reads.
pub fn problem(a: Allocator, text: []const u8) !?[]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var d: Diag = .{};
    if (parse(scratch.allocator(), text, .triggers, &d)) |_| return null else |e| if (e == error.OutOfMemory) return e;
    return try lineProblem(a, "triggers.ini", text, d);
}

/// "NAME line N has an error: LINE (why)".
pub fn lineProblem(a: Allocator, name: []const u8, text: []const u8, d: Diag) ![]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: []const u8 = "";
    for (0..d.line) |_| line = it.next() orelse "";
    return std.fmt.allocPrint(a, "{s} line {d} has an error: {s} ({s})", .{ name, d.line, util.cut(std.mem.trim(u8, line, " \t\r"), 80), d.why });
}

/// The schedules among `list`, as the task code runs them.
pub fn tasksOf(a: Allocator, list: []const Trigger) ![]config.Task {
    var out: std.ArrayList(config.Task) = .empty;
    for (list) |tr| {
        if (tr.kind != .schedule) continue;
        try out.append(a, .{
            .name = tr.name,
            .at_minutes = tr.at,
            .every_minutes = if (tr.every_s) |s| s / 60 else null,
            .days = tr.days,
            .do = switch (tr.action) {
                .do => |x| x,
                else => "",
            },
            .say = switch (tr.action) {
                .say => |x| x,
                else => "",
            },
            .start = switch (tr.action) {
                .start => |x| x,
                else => "",
            },
            .start_input = tr.start_input,
            .to = tr.to,
            .agent = tr.agent,
            .in_triggers = tr.file == .triggers,
        });
    }
    return out.items;
}

/// The briefs among `list`, as the brief code runs them.
pub fn briefsOf(a: Allocator, list: []const Trigger) ![]config.Brief {
    var out: std.ArrayList(config.Brief) = .empty;
    for (list) |tr| if (tr.kind == .brief) try out.append(a, .{ .name = tr.name, .at_minutes = tr.at orelse 7 * 60, .topics = tr.topics, .to = tr.to });
    return out.items;
}

// ---- tests ----

const t = std.testing;

fn parseOne(a: Allocator, text: []const u8) !Trigger {
    var d: Diag = .{};
    const list = parse(a, text, .triggers, &d) catch |e| {
        std.debug.print("line {d}: {s}\n", .{ d.line, d.why });
        return e;
    };
    try t.expectEqual(1, list.len);
    return list[0];
}

/// `text` is refused, naming line `line` and a reason holding `why`.
fn refused(a: Allocator, text: []const u8, line: usize, why: []const u8) !void {
    var d: Diag = .{};
    if (parse(a, text, .triggers, &d)) |_| {
        std.debug.print("read without an error:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    } else |e| try t.expectEqual(error.BadTrigger, e);
    if (d.line != line or std.mem.indexOf(u8, d.why, why) == null) {
        std.debug.print("{s}\nwanted line {d} with \"{s}\", got line {d}: {s}\n", .{ text, line, why, d.line, d.why });
        return error.TestUnexpectedResult;
    }
}

test "every_kind_parses_and_bad_lines_are_named" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed = try parseOne(a, "[news]\nfeed = https://ziglang.org/news/index.xml\nmatch = title has release | rc\ndo = Tell me what changed.\n");
    try t.expectEqual(Kind.feed, feed.kind);
    try t.expectEqual(3600, feed.every_s.?);
    try t.expectEqual(6, feed.max_runs);
    try t.expectEqual(20, feed.max_events);
    try t.expectEqualStrings("main", feed.to);
    try t.expectEqualStrings("https://ziglang.org/news/index.xml", feed.sources[0]);
    try t.expectEqualStrings("title", feed.match[0].field);
    try t.expectEqual(Op.has, feed.match[0].op);
    try t.expectEqualStrings("rc", feed.match[0].values[1]);
    try t.expectEqualStrings("Tell me what changed.", feed.action.do);
    const btc = try parseOne(a, "[btc]\npage = https://api.coinbase.com/v2/prices/BTC-USD/spot\njson = data.amount\nevery = 5m\nmatch = move > 3\nsay = BTC {value} ({change}% since the last message)\n");
    try t.expectEqual(Kind.page, btc.kind);
    try t.expectEqual(300, btc.every_s.?);
    try t.expectEqualStrings("data.amount", btc.json);
    try t.expectEqual(Op.gt, btc.match[0].op);
    try t.expectEqualStrings("BTC {value} ({change}% since the last message)", btc.action.say);
    const s = try parseOne(a, "[zig]\nsearch = zig release\nsearch = zig 0.18\nto = news\nmax_runs = 2\n");
    try t.expectEqual(Kind.search, s.kind);
    try t.expectEqual(21600, s.every_s.?);
    try t.expectEqual(2, s.sources.len);
    try t.expectEqualStrings("news", s.to);
    try t.expectEqual(2, s.max_runs);
    try t.expectEqual(Action.none, s.action);
    const f = try parseOne(a, "[scans]\nfile = inbox/*.pdf\nevery = 30s\nskip = path like *draft*\nstart = workflow file-scans\n");
    try t.expectEqual(Kind.file, f.kind);
    try t.expectEqual(30, f.every_s.?);
    try t.expectEqualStrings("inbox/*.pdf", f.sources[0]);
    try t.expectEqualStrings("file-scans", f.action.start);
    const m = try parseOne(a, "[issues]\nmcp = github/list_issues {\"repo\": \"zigworks\"}\nkey = number\nagent = scout\ntools = fetch, github/*\ndo = Draft a reply.\n");
    try t.expectEqual(Kind.mcp, m.kind);
    try t.expectEqual(900, m.every_s.?);
    try t.expectEqualStrings("github", m.mcp.?.server);
    try t.expectEqualStrings("list_issues", m.mcp.?.tool);
    try t.expectEqualStrings("{\"repo\": \"zigworks\"}", m.mcp.?.input);
    try t.expectEqualStrings("number", m.key);
    try t.expectEqualStrings("scout", m.agent);
    try t.expectEqualStrings("github/*", m.tools.?[1]);
    const r = try parseOne(a, "[notes]\nmcp = files resource file:///notes.md\nevery = 1m\nsay = The notes changed.\n");
    try t.expectEqualStrings("file:///notes.md", r.mcp.?.uri);
    try t.expectEqual(60, r.every_s.?);
    const sch = try parseOne(a, "[water]\nat = 09:00\ndays = mon, tue\nsay = Drink water.\n");
    try t.expectEqual(Kind.schedule, sch.kind);
    try t.expectEqual(9 * 60, sch.at.?);
    try t.expectEqual(0b0000011, sch.days);
    const b = try parseOne(a, "[morning]\nat = 06:30\ntopic = Zig | https://ziglang.org/news/index.xml\n");
    try t.expectEqual(Kind.brief, b.kind);
    try t.expectEqual(6 * 60 + 30, b.at.?);
    try t.expectEqualStrings("Zig", b.topics[0].name);
    // a mark above a header says who added it; the lines it takes
    var d: Diag = .{};
    const two = try parse(a, "[a]\nsearch = x\n\n; added by agent:main 2026-11-22 (item 41)\n[b]\nsearch = y\n", .triggers, &d);
    try t.expectEqualStrings("added by agent:main 2026-11-22 (item 41)", two[1].added);
    try t.expectEqual(4, two[1].first);
    try t.expectEqual(6, two[1].last);
    try t.expectEqual(1, two[0].first);
    try t.expectEqual(2, two[0].last);

    try refused(a, "[news]\nfeed = https://z.org/f\nevery = 1m\n", 3, "at least 5 min");
    try refused(a, "[x]\nfeed = https://z.org/f\npage = https://z.org/p\n", 3, "one kind of source");
    try refused(a, "[x]\nfeed = https://z.org/f\nmatch = titel has x\n", 3, "title, link, text, date, source");
    try refused(a, "[x]\nfeed = https://z.org/f\ndo = a\nsay = b\n", 4, "one of do, say and start");
    try refused(a, "[add]\nsearch = x\n", 1, "a-z, 0-9");
    try refused(a, "[Btc]\nsearch = x\n", 1, "a-z, 0-9");
    try refused(a, "[a]\nsearch = x\n[b]\nsearch = y\n[a]\nsearch = z\n", 5, "twice");
    try refused(a, "[x]\nfile = ../x/*\n", 2, "inside the workspace");
    try refused(a, "[x]\nfile = a*/b\n", 2, "last part");
    try refused(a, "[x]\nmcp = a b\n", 2, "SERVER/TOOL");
    try refused(a, "[x]\nmcp = a/b [1]\n", 2, "JSON object");
    try refused(a, "[x]\npage = https://z.org/p\nsay = {nope}\n", 3, "{nope}");
    try refused(a, "[x]\nmail = home\ndo = y\n", 2, "unknown key");
    try refused(a, "[x]\nsearch = z\nstart = flow x\n", 3, "workflow NAME");
    try refused(a, "[x]\nevery = 15m\n", 1, "do, say or start");
    try refused(a, "[x]\nsay = hi\n", 1, "every or at");
    try refused(a, "[x]\nfeed = https://z.org/f\njson = a.b\n", 3, "json");
    try refused(a, "[x]\nsearch = z\nmatch = title > many\n", 3, "number");
    try refused(a, "no section here\n", 1, "[section]");
}

test "filters_hold_as_written" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]Field{
        .{ .name = "title", .value = "Zig 0.18 Release Notes" },
        .{ .name = "path", .value = "inbox/Scan-04.PDF" },
        .{ .name = "move", .value = "4.0" },
        .{ .name = "value", .value = "97012.5" },
    };
    for ([_][]const u8{ "title has release | rc", "title is zig 0.18 release notes", "title starts zig", "title ends NOTES", "path like inbox/*.pdf", "move > 3", "value >= 97012", "move <= 4", "value < 100000" }) |text|
        if (!holds(try parseCond(a, text, null), &fields)) {
            std.debug.print("{s} does not hold\n", .{text});
            return error.TestUnexpectedResult;
        };
    for ([_][]const u8{ "title has beta", "title is zig", "move > 4", "path like *.txt", "missing has x", "title > 3" }) |text|
        if (holds(try parseCond(a, text, null), &fields)) {
            std.debug.print("{s} holds\n", .{text});
            return error.TestUnexpectedResult;
        };
    var tr: Trigger = .{ .name = "x", .file = .triggers, .kind = .feed };
    tr.match = &.{ try parseCond(a, "title has zig", null), try parseCond(a, "move > 3", null) };
    try t.expect(passes(tr, &fields));
    tr.skip = &.{try parseCond(a, "path like *.pdf", null)};
    try t.expect(!passes(tr, &fields));
    tr.skip = &.{};
    tr.match = &.{ try parseCond(a, "title has zig", null), try parseCond(a, "move > 5", null) };
    try t.expect(!passes(tr, &fields));
}

test "say_fills_fields_and_change_is_signed" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up = [_]Field{ .{ .name = "value", .value = "104" }, .{ .name = "change", .value = "4" }, .{ .name = "move", .value = "4" } };
    try t.expectEqualStrings("BTC 104 (+4.0% since the last message)", try fill(a, "BTC {value} ({change}% since the last message)", &up));
    const down = [_]Field{ .{ .name = "change", .value = "-3.21" }, .{ .name = "move", .value = "3.21" } };
    try t.expectEqualStrings("-3.2 3.2 {x} ", try fill(a, "{change} {move} {{x} {gone}", &down));
}

test "next_poll_waits_every_or_until_at" {
    const base = 1796083200; // 2026-12-01 00:00 UTC, a Tuesday
    var tr: Trigger = .{ .name = "x", .file = .triggers, .kind = .page, .every_s = 300 };
    try t.expectEqual(base + 300, nextPoll(tr, base, 0, 0));
    try t.expectEqual(base + 330, nextPoll(tr, base, 0, 30));
    // a jitter past a tenth of every is cut to it
    try t.expectEqual(base + 330, nextPoll(tr, base, 0, 99));
    tr.every_s = null;
    tr.at = 7 * 60;
    tr.days = 0b0000001; // mon
    // 07:00 at +01:00 is 06:00 UTC; the next Monday is 2026-12-07
    try t.expectEqual(base + 6 * 86400 + 6 * 3600, nextPoll(tr, base, 60, 0));
    tr.days = 0x7f;
    try t.expectEqual(base + 6 * 3600, nextPoll(tr, base, 60, 0));
    try t.expectEqual(base + 86400 + 6 * 3600, nextPoll(tr, base + 6 * 3600, 60, 0));
}

test "a_reading_says_what_runs_without_the_model" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed = try parseOne(a, "[news]\nfeed = https://ziglang.org/news/index.xml\nmatch = title has release\ndo = Tell me.\n");
    try t.expectEqualStrings("Polls 1 feed every 1 h, no model call; a new item whose title has \"release\" starts a run of main; at most 6 runs an hour.", try reading(a, feed, "claude-haiku"));
    const btc = try parseOne(a, "[btc]\npage = https://api.example.com/btc\njson = data.amount\nevery = 5m\nmatch = move > 3\nsay = BTC {value}\n");
    try t.expectEqualStrings("Reads https://api.example.com/btc every 5 min (the value at data.amount), no model call; a new value whose move > 3 says: BTC {value}.", try reading(a, btc, "claude-haiku"));
    const bills = try parseOne(a, "[bills]\nfile = inbox/*.pdf\nskip = path has draft\ncheck = Is this a bill?\nagent = scout\ntools = read_file\nto = home\ndo = Say who wants how much.\n");
    try t.expectEqualStrings("Watches inbox/*.pdf every 1 min, asks claude-haiku \"Is this a bill?\" of each item the rules pass (at most 50 a day); a new, changed or removed file, unless path has \"draft\", starts a run of scout with tools read_file; at most 6 runs an hour; posts to home.", try reading(a, bills, "claude-haiku"));
}

test "in_triggers_ini_only_whole_lines_are_comments" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // free text keeps # and ; (an issue number, a list)
    const tr = try parseOne(a, "; a comment\n# another\n[issues]\nsearch = zig\nsay = PR #{title}; see {link} # here\n");
    try t.expectEqualStrings("PR #{title}; see {link} # here", tr.action.say);
    // tasks.ini keeps config.ini's rule: after a space, a comment
    var d: Diag = .{};
    const ts = try parse(a, "[x]\nevery = 5m ; five minutes\ndo = Look #now\n", .tasks, &d);
    try t.expectEqualStrings("Look", ts[0].action.do);
}

test "urgent_is_read_for_triggers_and_schedules" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const leak = try parseOne(a, "[leak]\nfeed = https://home.example.com/leak.xml\nurgent = yes\ndo = Say where the water is.\n");
    try t.expect(leak.urgent);
    try t.expect(!(try parseOne(a, "[news]\nfeed = https://ziglang.org/news/index.xml\ndo = Tell me.\n")).urgent);
    const door = try parseOne(a, "[door]\nat = 23:00\nurgent = on\nsay = The front door is unlocked.\n");
    try t.expectEqual(Kind.schedule, door.kind);
    try t.expect(door.urgent);
    try t.expect((try door.clone(a)).urgent);
    try refused(a, "[leak]\nfeed = https://home.example.com/leak.xml\nurgent = maybe\ndo = x\n", 3, "urgent = yes or no");
    // a brief has none, nor has tasks.ini
    try refused(a, "[m]\ntopic = Zig | https://z.org/f\nurgent = yes\n", 3, "not a key of a brief trigger");
    var d: Diag = .{};
    try t.expectError(error.BadTrigger, parse(a, "[x]\nevery = 5m\ndo = y\nurgent = yes\n", .tasks, &d));
    // the reading says it goes through quiet hours
    try t.expect(std.mem.endsWith(u8, try reading(a, leak, "claude-haiku"), "; urgent: it goes through quiet hours."));
    try t.expect(std.mem.endsWith(u8, try reading(a, door, "claude-haiku"), "; urgent: it goes through quiet hours."));
}

test "announce_is_said_on_the_house_speakers" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // with any action, or none; its fields filled like say's
    const leak = try parseOne(a, "[leak]\nmcp = home resource home://device/sink_leak\nmatch = text has \"to\":\"wet\"\nurgent = yes\nsay = Water under the kitchen sink.\nannounce = Water under the kitchen sink. Close the water main.\n");
    try t.expectEqualStrings("Water under the kitchen sink. Close the water main.", leak.announce);
    try t.expectEqualStrings("Water under the kitchen sink. Close the water main.", (try leak.clone(a)).announce);
    const door = try parseOne(a, "[door]\nfeed = https://home.example.com/door.xml\nannounce = {title}\n");
    try t.expectEqual(Action.none, door.action);
    try t.expectEqualStrings("{title}", door.announce);
    // a field the kind has not, an empty one, a schedule's or a brief's: refused
    try refused(a, "[door]\nfeed = https://home.example.com/door.xml\nannounce = {price}\n", 3, "{price} is no field");
    try refused(a, "[door]\nfeed = https://home.example.com/door.xml\nannounce =\n", 3, "announce needs its text");
    try refused(a, "[bed]\nat = 21:00\nannounce = Time for bed.\n", 3, "not a key of a schedule trigger");
    try refused(a, "[m]\ntopic = Zig | https://z.org/f\nannounce = x\n", 3, "not a key of a brief trigger");
    // the reading says it
    try t.expect(std.mem.indexOf(u8, try reading(a, leak, "claude-haiku"), "; says it on the house's speakers: Water under the kitchen sink. Close the water main.") != null);
}

test "a_trigger_never_polls_what_speaks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a poll would say it every time, at night too: announce = TEXT says a line per event
    try refused(a, "[x]\nmcp = home/announce {\"message\":\"hi\"}\nsay = x\n", 2, "announce speaks aloud: a trigger doesn't poll it");
}

test "start_takes_text_for_the_input" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const door = try parseOne(a, "[door-back_door]\nmcp = home resource home://device/back_door\nmatch = to is open\nstart = workflow door-open Back door ({room})\n");
    try t.expectEqualStrings("door-open", door.action.start);
    try t.expectEqualStrings("Back door ({room})", door.start_input);
    try t.expectEqualStrings("Back door ({room})", (try door.clone(a)).start_input);
    // filled from the event, as say is
    try t.expectEqualStrings("Back door (Kitchen)", try fill(a, door.start_input, &.{.{ .name = "room", .value = "Kitchen" }}));
    const plain = try parseOne(a, "[d]\nsearch = zig\nstart = workflow w\n");
    try t.expectEqualStrings("w", plain.action.start);
    try t.expectEqualStrings("", plain.start_input);
    // a field the source doesn't give is refused, as in say
    try refused(a, "[x]\nsearch = z\nstart = workflow w about {nope}\n", 3, "{nope} is no field of a search event");
    // the reading says it
    try t.expect(std.mem.indexOf(u8, try reading(a, door, "claude-haiku"), "starts workflow door-open with \"Back door ({room})\"") != null);
}

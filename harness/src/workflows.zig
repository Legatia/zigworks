//! Workflows: the `.wf` format of `workflows/NAME.wf` (steps harness runs
//! with their state on disk), the names, what a file may name, the values
//! steps leave and how they fill a step's text and JSON, where a step goes
//! next, and harness's own reading of a file. Pure: no I/O.
const std = @import("std");
const triggers = @import("triggers.zig");
const config = @import("config.zig");
const conversations = @import("conversations.zig");
const agents = @import("agents.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

pub const max_file = 64 * 1024;
pub const max_steps = 100;
/// A value a step leaves, and an instance's values together.
pub const max_value = 16 * 1024;
pub const max_values = 1 << 20;
/// Waits and inbox items, unless `timeout` says otherwise.
pub const default_timeout_s: u32 = 7 * 86400;
/// The longest wait between two tries.
pub const max_retry_wait_s: u32 = 6 * 3600;

pub const Limits = struct { steps: u32 = 50, days: u32 = 7, at_once: u32 = 3 };

pub const Wait = union(enum) {
    /// Seconds.
    timer: u32,
    /// Minutes after midnight, the owner's time.
    until: u16,
    /// A trigger's name: its next matching event.
    event: []const u8,
};

/// `tool TOOL JSON`: a built-in tool's name or `SERVER/TOOL`, and the
/// input as written (placeholders and all).
pub const Tool = struct { name: []const u8, json: []const u8 };

pub const Action = union(enum) {
    /// A step of `if` lines, a `goto` or `end` alone.
    none,
    tool: Tool,
    do: []const u8,
    wait: Wait,
    approve: []const u8,
    review: []const u8,
    say: []const u8,
};

/// `if COND goto STEP`.
pub const If = struct { cond: triggers.Cond, goto: []const u8, line: usize };

pub const Step = struct {
    name: []const u8,
    /// Its `step NAME` line.
    line: usize,
    action: Action = .none,
    action_line: usize = 0,
    /// `answer json`: the agent's answer must be JSON; its fields are values.
    answer_json: bool = false,
    /// The definition a `do` runs; "": the workflow's `agent`.
    agent: []const u8 = "",
    agent_line: usize = 0,
    /// What a `do` run may use, within its definition's tools; null: all.
    tools: ?[]const []const u8 = null,
    /// `match` lines of a `wait event`, as written (their values may hold
    /// placeholders, filled as text when an event comes).
    match: []const []const u8 = &.{},
    match_line: usize = 0,
    ifs: []const If = &.{},
    /// `retry N wait D`: N more tries after a failure, the waits doubling
    /// from D (up to 6 h).
    retry: u32 = 0,
    retry_wait_s: u32 = 0,
    on_fail: []const u8 = "",
    on_deny: []const u8 = "",
    on_timeout: []const u8 = "",
    /// The lines of `goto` and the `on` lines (fail, deny, timeout).
    goto_line: usize = 0,
    on_lines: [3]usize = .{ 0, 0, 0 },
    /// Waits and inbox items; null: 7 days.
    timeout_s: ?u32 = null,
    /// Where its commands run (`host` only for now).
    env: []const u8 = "",
    goto: []const u8 = "",
    end: bool = false,

    pub fn timeout(s: Step) u32 {
        return s.timeout_s orelse default_timeout_s;
    }
};

pub const Workflow = struct {
    name: []const u8,
    about: []const u8 = "",
    /// Who may start it: `owner`, `agent` (the workflow tool),
    /// `trigger:NAME`, `schedule:NAME`.
    start: []const []const u8 = &.{"owner"},
    start_line: usize = 0,
    limits: Limits = .{},
    /// The conversation it reports to.
    to: []const u8 = "main",
    /// The definition its agent steps run.
    agent: []const u8 = "main",
    agent_line: usize = 0,
    /// `urgent yes`: its posts and questions go through quiet hours.
    urgent: bool = false,
    steps: []const Step,
    /// "saved by agent:main 2026-11-22 (item 57)": its first line, when
    /// the agent's save wrote it.
    saved: []const u8 = "",
    /// The whole file.
    text: []const u8,

    pub fn find(w: Workflow, name: []const u8) ?usize {
        for (w.steps, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
        return null;
    }

    /// Whether the start line lets `by` start it: `owner`, or `agent` for
    /// a start by the workflow tool (`tool`), `trigger:NAME` and
    /// `schedule:NAME` by their name.
    pub fn allows(w: Workflow, by: []const u8, tool: bool) bool {
        const want = if (tool) "agent" else by;
        for (w.start) |s| if (std.mem.eql(u8, s, want)) return true;
        return false;
    }
};

pub const Diag = struct { line: usize = 0, why: []const u8 = "" };
pub const Error = error{ BadWorkflow, OutOfMemory };

/// The words the workflow commands take: never a workflow's name.
const command_words = [_][]const u8{ "start", "stop", "resume", "rm", "list", "check", "show", "save" };
/// The values every instance has: never a step's name.
const builtin_values = [_][]const u8{ "input", "event", "instance", "now" };

const name_rule = "a-z, 0-9, - and _ (up to 64), starting with a letter or digit";

/// A workflow's name: 1 to 64 of a-z, 0-9, `-` and `_`, starting with a
/// letter or digit, none of the commands' words.
pub fn validName(name: []const u8) bool {
    if (!stepName(name)) return false;
    for (command_words) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

/// A step's name: the same characters, none of the values every instance has.
pub fn validStep(name: []const u8) bool {
    if (!stepName(name)) return false;
    for (builtin_values) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

fn stepName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// Why a step's `env NAME` doesn't read; null: it does. Whether
/// environments.ini has it is seen when the step runs (a command in one
/// that isn't there is refused, never run on the host).
pub fn envProblem(name: []const u8) ?[]const u8 {
    if (@import("rules.zig").envName(name)) return null;
    return "env takes host or an environment's name (a-z, 0-9, - and _, up to 32)";
}

/// "workflows/x.wf line N has an error: LINE (why)".
pub fn lineProblem(a: Allocator, file: []const u8, text: []const u8, d: Diag) ![]const u8 {
    if (d.line == 0) return std.fmt.allocPrint(a, "{s} has an error: {s}", .{ file, d.why });
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: []const u8 = "";
    for (0..d.line) |_| line = it.next() orelse "";
    return std.fmt.allocPrint(a, "{s} line {d} has an error: {s} ({s})", .{ file, d.line, util.cut(std.mem.trim(u8, line, " \t\r"), 80), d.why });
}

fn bad(diag: *Diag, n: usize, why: []const u8) Error {
    diag.* = .{ .line = n, .why = why };
    return error.BadWorkflow;
}

fn badf(a: Allocator, diag: *Diag, n: usize, comptime fmt: []const u8, args: anytype) Error {
    return bad(diag, n, try std.fmt.allocPrint(a, fmt, args));
}

// ---- reading the file ----

/// A key and its value, and its line.
const Line = struct { key: []const u8, value: []const u8, n: usize };

/// The file's key lines: a key and its value; `#` starts a comment line
/// (a first line `# saved by …` is kept in `saved`); keys start at the
/// left edge; a line ending in `:` takes the lines below it indented two
/// or more spaces, their common indent removed, as (the rest of) its value.
fn readLines(a: Allocator, text: []const u8, diag: *Diag, saved: *[]const u8) Error![]Line {
    var raw: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try raw.append(a, std.mem.trimEnd(u8, l, "\r"));
    var out: std.ArrayList(Line) = .empty;
    var i: usize = 0;
    while (i < raw.items.len) : (i += 1) {
        const l = raw.items[i];
        const n = i + 1;
        if (std.mem.trim(u8, l, " \t").len == 0) continue;
        if (l[0] == '#') {
            if (n == 1 and std.mem.startsWith(u8, l, "# saved by ")) saved.* = std.mem.trim(u8, l[2..], " \t");
            continue;
        }
        if (l[0] == ' ' or l[0] == '\t') return bad(diag, n, "an indented line goes below a line ending in :");
        var line = std.mem.trimEnd(u8, l, " \t");
        var block: ?[]const u8 = null;
        if (std.mem.endsWith(u8, line, ":")) {
            var j = i + 1;
            while (j < raw.items.len and std.mem.trim(u8, raw.items[j], " \t").len == 0) j += 1;
            if (j < raw.items.len and (raw.items[j][0] == ' ' or raw.items[j][0] == '\t')) {
                var end = i + 1;
                while (end < raw.items.len) : (end += 1) {
                    const b = raw.items[end];
                    if (std.mem.trim(u8, b, " \t").len == 0) continue;
                    if (b[0] != ' ' and b[0] != '\t') break;
                }
                // the first indented line sets the width: two spaces or more
                var width: usize = 0;
                for (raw.items[j]) |ch| switch (ch) {
                    ' ' => width += 1,
                    '\t' => width += 2,
                    else => break,
                };
                if (width < 2) return bad(diag, j + 1, "indent the lines below a : by two or more spaces");
                var common: usize = std.math.maxInt(usize);
                for (raw.items[i + 1 .. end]) |b| {
                    if (std.mem.trim(u8, b, " \t").len == 0) continue;
                    var k: usize = 0;
                    while (k < b.len and (b[k] == ' ' or b[k] == '\t')) k += 1;
                    common = @min(common, k);
                }
                var joined: std.ArrayList(u8) = .empty;
                var last_full: usize = 0;
                for (raw.items[i + 1 .. end], 0..) |b, k| {
                    if (k > 0) try joined.append(a, '\n');
                    if (std.mem.trim(u8, b, " \t").len > 0) {
                        try joined.appendSlice(a, b[@min(common, b.len)..]);
                        last_full = joined.items.len;
                    }
                }
                block = joined.items[0..last_full];
                line = line[0 .. line.len - 1];
                i = end - 1;
            }
        }
        const tl = std.mem.trim(u8, line, " \t");
        const sp = std.mem.indexOfAny(u8, tl, " \t") orelse tl.len;
        var value = std.mem.trim(u8, tl[sp..], " \t");
        if (block) |b| value = if (value.len == 0) b else try std.fmt.allocPrint(a, "{s}\n{s}", .{ value, b });
        try out.append(a, .{ .key = tl[0..sp], .value = value, .n = n });
    }
    return out.items;
}

const head_keys = [_][]const u8{ "workflow", "about", "start", "limits", "to", "urgent" };
const step_keys = [_][]const u8{ "tool", "do", "wait", "approve", "review", "say", "answer", "tools", "match", "if", "retry", "on", "timeout", "env", "goto", "end" };

fn oneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// Reads a workflow file called `name` (`workflows/NAME.wf`); its
/// results point into `text`. A line that does not read is named in
/// `diag` with its number and why.
pub fn parse(a: Allocator, name: []const u8, text: []const u8, diag: *Diag) Error!Workflow {
    if (text.len > max_file) return bad(diag, 0, "a workflow file is at most 64 KB");
    var saved: []const u8 = "";
    const lines = try readLines(a, text, diag, &saved);
    var w: Workflow = .{ .name = "", .steps = &.{}, .text = text, .saved = saved };
    var steps: std.ArrayList(Step) = .empty;
    // each step's lines, to read them once all names are known
    var seen_head: std.ArrayList([]const u8) = .empty;
    var cur: ?usize = null;
    var step_lines: std.ArrayList(std.ArrayList(Line)) = .empty;
    for (lines, 0..) |l, k| {
        if (k == 0 and !std.mem.eql(u8, l.key, "workflow")) return bad(diag, l.n, "a workflow file starts with workflow NAME");
        if (std.mem.eql(u8, l.key, "step")) {
            if (!validStep(l.value)) return badf(a, diag, l.n, "step NAME: {s}, not input, event, instance or now", .{name_rule});
            for (steps.items) |s| if (std.mem.eql(u8, s.name, l.value)) return badf(a, diag, l.n, "a step called {s} comes before", .{l.value});
            if (steps.items.len == max_steps) return bad(diag, l.n, "a workflow has at most 100 steps");
            try steps.append(a, .{ .name = l.value, .line = l.n });
            try step_lines.append(a, .empty);
            cur = steps.items.len - 1;
            continue;
        }
        if (cur) |ci| {
            if (oneOf(l.key, &head_keys)) return badf(a, diag, l.n, "{s} goes in the head, above the first step", .{l.key});
            if (!oneOf(l.key, &step_keys) and !std.mem.eql(u8, l.key, "agent")) return badf(a, diag, l.n, "unknown key: {s}", .{l.key});
            try step_lines.items[ci].append(a, l);
            continue;
        }
        if (oneOf(l.key, &step_keys)) return badf(a, diag, l.n, "{s} goes in a step: step NAME first", .{l.key});
        if (!oneOf(l.key, &head_keys) and !std.mem.eql(u8, l.key, "agent")) return badf(a, diag, l.n, "unknown key: {s}", .{l.key});
        if (oneOf(l.key, seen_head.items)) return badf(a, diag, l.n, "{s} comes once", .{l.key});
        try seen_head.append(a, l.key);
        try headLine(a, &w, l, name, diag);
    }
    if (lines.len == 0) return bad(diag, 1, "a workflow file starts with workflow NAME");
    if (steps.items.len == 0) return bad(diag, lines[lines.len - 1].n, "a workflow has at least one step");
    w.steps = steps.items;
    for (steps.items, step_lines.items) |*s, sl| try stepLines(a, s, sl.items, w, diag);
    // where steps go, and what their texts name
    for (steps.items) |s| {
        for (s.ifs) |f| try target(a, w, f.goto, f.line, diag);
        if (s.goto.len > 0) try target(a, w, s.goto, s.goto_line, diag);
        for ([_][]const u8{ s.on_fail, s.on_deny, s.on_timeout }, s.on_lines) |to, n| if (to.len > 0) try target(a, w, to, n, diag);
        try namesIn(a, w, s, diag);
    }
    return w;
}

fn target(a: Allocator, w: Workflow, name: []const u8, n: usize, diag: *Diag) Error!void {
    if (w.find(name) != null) return;
    var names: std.ArrayList(u8) = .empty;
    for (w.steps, 0..) |s, i| try names.print(a, "{s}{s}", .{ if (i > 0) ", " else "", s.name });
    return badf(a, diag, n, "there is no step {s} (steps: {s})", .{ name, names.items });
}

fn headLine(a: Allocator, w: *Workflow, l: Line, file_name: []const u8, diag: *Diag) Error!void {
    const v = l.value;
    const eql = std.mem.eql;
    if (eql(u8, l.key, "workflow")) {
        if (!validName(v)) return badf(a, diag, l.n, "workflow NAME: {s}, not start, stop, resume, rm, list, check, show or save", .{name_rule});
        if (!eql(u8, v, file_name)) return badf(a, diag, l.n, "the file is {s}.wf: workflow {s}", .{ file_name, file_name });
        w.name = v;
    } else if (eql(u8, l.key, "about")) {
        w.about = v;
    } else if (eql(u8, l.key, "start")) {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t");
            const ok = eql(u8, s, "owner") or eql(u8, s, "agent") or
                (std.mem.startsWith(u8, s, "trigger:") and triggers.validName(s["trigger:".len..])) or
                (std.mem.startsWith(u8, s, "schedule:") and triggers.validName(s["schedule:".len..]));
            if (!ok) return bad(diag, l.n, "start lists owner, agent, trigger:NAME or schedule:NAME, separated by commas");
            if (!oneOf(s, list.items)) try list.append(a, s);
        }
        w.start = list.items;
        w.start_line = l.n;
    } else if (eql(u8, l.key, "limits")) {
        const shape = "limits steps N, days N, at-once N (any of them, whole numbers from 1)";
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |raw| {
            var words = std.mem.tokenizeAny(u8, raw, " \t");
            const word = words.next() orelse return bad(diag, l.n, shape);
            const x = std.fmt.parseInt(u32, words.next() orelse return bad(diag, l.n, shape), 10) catch return bad(diag, l.n, shape);
            if (words.next() != null or x == 0) return bad(diag, l.n, shape);
            if (eql(u8, word, "steps") and x <= 10_000) {
                w.limits.steps = x;
            } else if (eql(u8, word, "days") and x <= 365) {
                w.limits.days = x;
            } else if (eql(u8, word, "at-once") and x <= 100) {
                w.limits.at_once = x;
            } else return bad(diag, l.n, "limits steps N (up to 10000), days N (up to 365), at-once N (up to 100)");
        }
    } else if (eql(u8, l.key, "to")) {
        if (!conversations.validName(v)) return bad(diag, l.n, "to names a conversation: a-z, 0-9, - and _");
        w.to = v;
    } else if (eql(u8, l.key, "urgent")) {
        // `urgent yes`, or as triggers.ini writes it, `urgent = yes`
        const word = std.mem.trim(u8, if (std.mem.startsWith(u8, v, "=")) v[1..] else v, " \t");
        w.urgent = config.parseBool(word) orelse return bad(diag, l.n, "urgent yes or no: yes goes through quiet hours");
    } else if (eql(u8, l.key, "agent")) {
        if (!agents.validName(v)) return bad(diag, l.n, "agent names a definition: a-z, 0-9 and -");
        w.agent = v;
        w.agent_line = l.n;
    }
}

/// The built-in tools a `tool` step may call.
const step_tools = [_][]const u8{ "shell", "read_file", "write_file", "fetch", "browse", "search", "recall", "remember", "skill", "snapshot" };
/// Setup calls: never a step.
const setup_tools = [_][]const u8{ "agent_save", "trigger", "workflow", "app_save", "env_save" };

/// Why `name` can't be a tool step's tool; null: it can.
fn toolProblem(a: Allocator, name: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const server = name[0..slash];
        const tool = name[slash + 1 ..];
        if (!mcpServerName(server) or tool.len == 0 or tool.len > 64) return "an MCP tool is SERVER/TOOL";
        for (tool) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return "an MCP tool is SERVER/TOOL";
        return null;
    }
    if (oneOf(name, &step_tools)) return null;
    if (oneOf(name, &setup_tools)) return try std.fmt.allocPrint(a, "{s} changes what runs without you watching: it is never a step", .{name});
    if (std.mem.eql(u8, name, "send")) return "send is no step tool: say posts";
    if (std.mem.eql(u8, name, "ask_owner")) return "ask_owner is no step tool: approve and review ask you";
    if (std.mem.eql(u8, name, "delegate")) return "delegate is no step tool: an agent step (do) may delegate";
    if (oneOf(name, &.{ "web", "login", "skill_save" })) return try std.fmt.allocPrint(a, "{s} is no step tool", .{name});
    return try std.fmt.allocPrint(a, "no such tool: {s} (a built-in tool, or SERVER/TOOL)", .{name});
}

fn mcpServerName(n: []const u8) bool {
    if (n.len == 0 or n.len > 32 or std.mem.indexOf(u8, n, "__") != null) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// A tool as files name it: a built-in's name, `SERVER/TOOL`, `SERVER/*`, `*`.
fn toolPattern(n: []const u8) bool {
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

fn stepLines(a: Allocator, s: *Step, lines: []const Line, w: Workflow, diag: *Diag) Error!void {
    _ = w;
    const eql = std.mem.eql;
    var seen: std.ArrayList([]const u8) = .empty;
    var ifs: std.ArrayList(If) = .empty;
    var match: std.ArrayList([]const u8) = .empty;
    var tools_line: usize = 0;
    var answer_line: usize = 0;
    var timeout_line: usize = 0;
    var retry_line: usize = 0;
    var env_line: usize = 0;
    var on_timeout_line: usize = 0;
    for (lines) |l| {
        const v = l.value;
        const action = oneOf(l.key, &.{ "tool", "do", "wait", "approve", "review", "say" });
        if (action) {
            if (s.action_line != 0) return bad(diag, l.n, "a step takes one action: tool, do, wait, approve, review or say");
            s.action_line = l.n;
        } else if (!oneOf(l.key, &.{ "match", "if", "on" })) {
            if (oneOf(l.key, seen.items)) return badf(a, diag, l.n, "{s} comes once in a step", .{l.key});
            try seen.append(a, l.key);
        }
        if (eql(u8, l.key, "tool")) {
            const sp = std.mem.indexOfAny(u8, v, " \t\r\n") orelse v.len;
            const name = v[0..sp];
            const json = std.mem.trim(u8, v[sp..], " \t\r\n");
            if (name.len == 0) return bad(diag, l.n, "tool TOOL {json input}");
            if (try toolProblem(a, name)) |why| return bad(diag, l.n, why);
            const input = if (json.len == 0) "{}" else json;
            const parsed = jv.parse(a, input);
            if (parsed == null or parsed.? != .object) return bad(diag, l.n, "the tool's input is a JSON object, like {\"path\": \"notes.md\"}");
            s.action = .{ .tool = .{ .name = name, .json = input } };
        } else if (eql(u8, l.key, "do") or eql(u8, l.key, "approve") or eql(u8, l.key, "review") or eql(u8, l.key, "say")) {
            if (v.len == 0) return badf(a, diag, l.n, "{s} needs its text", .{l.key});
            s.action = if (eql(u8, l.key, "do")) .{ .do = v } else if (eql(u8, l.key, "approve")) .{ .approve = v } else if (eql(u8, l.key, "review")) .{ .review = v } else .{ .say = v };
        } else if (eql(u8, l.key, "wait")) {
            const shape = "wait 2h, wait until 09:00 or wait event TRIGGER";
            if (std.mem.startsWith(u8, v, "until ")) {
                s.action = .{ .wait = .{ .until = config.parseClock(std.mem.trim(u8, v[6..], " \t")) catch return bad(diag, l.n, shape) } };
            } else if (std.mem.startsWith(u8, v, "event ")) {
                const tr = std.mem.trim(u8, v[6..], " \t");
                if (!triggers.validName(tr)) return bad(diag, l.n, "wait event names a trigger of triggers.ini");
                s.action = .{ .wait = .{ .event = tr } };
            } else {
                s.action = .{ .wait = .{ .timer = triggers.parseDuration(v) orelse return bad(diag, l.n, shape) } };
            }
        } else if (eql(u8, l.key, "answer")) {
            if (!eql(u8, v, "json")) return bad(diag, l.n, "answer json: the agent's answer is JSON, its fields values");
            s.answer_json = true;
            answer_line = l.n;
        } else if (eql(u8, l.key, "agent")) {
            if (!agents.validName(v)) return bad(diag, l.n, "agent names a definition: a-z, 0-9 and -");
            s.agent = v;
            s.agent_line = l.n;
        } else if (eql(u8, l.key, "tools")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |raw| {
                const tool = std.mem.trim(u8, raw, " \t");
                if (!toolPattern(tool)) return bad(diag, l.n, "tools are tool names, SERVER/TOOL or SERVER/*, separated by commas");
                try list.append(a, tool);
            }
            s.tools = list.items;
            tools_line = l.n;
        } else if (eql(u8, l.key, "match")) {
            _ = condOf(a, v, true) catch return bad(diag, l.n, cond_shape);
            try match.append(a, v);
            if (s.match_line == 0) s.match_line = l.n;
        } else if (eql(u8, l.key, "if")) {
            const at = std.mem.lastIndexOf(u8, v, " goto ") orelse return bad(diag, l.n, "if FIELD OP VALUE goto STEP");
            const goto = std.mem.trim(u8, v[at + 6 ..], " \t");
            if (!validStep(goto)) return bad(diag, l.n, "if FIELD OP VALUE goto STEP");
            const c = condOf(a, v[0..at], false) catch return bad(diag, l.n, cond_shape);
            try ifs.append(a, .{ .cond = c, .goto = goto, .line = l.n });
        } else if (eql(u8, l.key, "retry")) {
            const shape = "retry N wait D: N more tries (1 to 10) after a failure, waiting D (30s, 5m, 1h), doubling";
            var words = std.mem.tokenizeAny(u8, v, " \t");
            const n = std.fmt.parseInt(u32, words.next() orelse return bad(diag, l.n, shape), 10) catch return bad(diag, l.n, shape);
            if (n == 0 or n > 10 or !eql(u8, words.next() orelse "", "wait")) return bad(diag, l.n, shape);
            const d = triggers.parseDuration(words.next() orelse return bad(diag, l.n, shape)) orelse return bad(diag, l.n, shape);
            if (words.next() != null) return bad(diag, l.n, shape);
            s.retry = n;
            s.retry_wait_s = d;
            retry_line = l.n;
        } else if (eql(u8, l.key, "on")) {
            const shape = "on fail goto STEP, on deny goto STEP or on timeout goto STEP";
            var words = std.mem.tokenizeAny(u8, v, " \t");
            const what = words.next() orelse return bad(diag, l.n, shape);
            if (!eql(u8, words.next() orelse "", "goto")) return bad(diag, l.n, shape);
            const goto = words.next() orelse return bad(diag, l.n, shape);
            if (words.next() != null or !validStep(goto)) return bad(diag, l.n, shape);
            const k: usize = if (eql(u8, what, "fail")) 0 else if (eql(u8, what, "deny")) 1 else if (eql(u8, what, "timeout")) 2 else return bad(diag, l.n, shape);
            const field: *[]const u8 = switch (k) {
                0 => &s.on_fail,
                1 => &s.on_deny,
                else => &s.on_timeout,
            };
            if (field.len > 0) return badf(a, diag, l.n, "on {s} comes once in a step", .{what});
            field.* = goto;
            s.on_lines[k] = l.n;
            if (k == 2) on_timeout_line = l.n;
        } else if (eql(u8, l.key, "timeout")) {
            s.timeout_s = triggers.parseDuration(v) orelse return bad(diag, l.n, "timeout D: 30s, 5m, 2h, 7d");
            timeout_line = l.n;
        } else if (eql(u8, l.key, "env")) {
            if (envProblem(v)) |why| return bad(diag, l.n, why);
            s.env = v;
            env_line = l.n;
        } else if (eql(u8, l.key, "goto")) {
            if (!validStep(v)) return bad(diag, l.n, "goto STEP");
            s.goto = v;
            s.goto_line = l.n;
        } else if (eql(u8, l.key, "end")) {
            if (v.len > 0) return bad(diag, l.n, "end takes nothing after it");
            s.end = true;
        }
    }
    s.ifs = ifs.items;
    s.match = match.items;
    const is_do = s.action == .do;
    const is_event = s.action == .wait and s.action.wait == .event;
    if (!is_do) {
        if (answer_line != 0) return bad(diag, answer_line, "answer json goes with do");
        if (s.agent_line != 0) return bad(diag, s.agent_line, "agent goes with do in a step");
        if (tools_line != 0) return bad(diag, tools_line, "tools go with do");
    }
    if (!is_event) {
        if (s.match_line != 0) return bad(diag, s.match_line, "match goes with wait event");
        if (on_timeout_line != 0) return bad(diag, on_timeout_line, "on timeout goes with wait event");
    }
    if (env_line != 0 and !(is_do or (s.action == .tool and std.mem.eql(u8, s.action.tool.name, "shell"))))
        return bad(diag, env_line, "env goes with do and tool shell");
    const can_time_out = switch (s.action) {
        .tool, .say, .approve, .review => true,
        .wait => |wt| wt == .event,
        else => false,
    };
    if (timeout_line != 0 and !can_time_out) return bad(diag, timeout_line, "timeout goes with wait event, approve, review, tool and say");
    const can_fail = switch (s.action) {
        .tool, .do, .say => true,
        .wait => |wt| wt == .event,
        else => false,
    };
    if (retry_line != 0 and !can_fail) return bad(diag, retry_line, "retry goes with tool, do, say and wait event");
    if (s.goto.len > 0 and s.end) return bad(diag, s.line, "a step takes goto or end, not both");
    if (s.action == .none and s.ifs.len == 0 and s.goto.len == 0 and !s.end) return bad(diag, s.line, "a step needs an action (tool, do, wait, approve, review, say), an if, a goto or end");
}

const cond_shape = "a condition is FIELD OP VALUE, OP one of has, is, starts, ends, like, >, <, >=, <= (| between values)";

/// A condition of `if` (a value's name as its field) or `match` (an
/// event's field; its values may hold placeholders, read as 0 here).
fn condOf(a: Allocator, text: []const u8, placeholders: bool) !triggers.Cond {
    var cond_text = text;
    if (placeholders) {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '{' and i + 1 < text.len and text[i + 1] != '{') if (std.mem.indexOfScalarPos(u8, text, i, '}')) |close| {
                try out.append(a, '0');
                i = close + 1;
                continue;
            };
            try out.append(a, text[i]);
            i += 1;
        }
        cond_text = out.items;
    }
    return triggers.parseCond(a, cond_text, null);
}

/// What a step's texts and conditions name: values an instance has.
fn namesIn(a: Allocator, w: Workflow, s: Step, diag: *Diag) Error!void {
    const n = if (s.action_line != 0) s.action_line else s.line;
    switch (s.action) {
        .do, .approve, .review, .say => |text| try checkText(a, w, text, n, diag),
        .tool => |tl| {
            const v = jv.parse(a, tl.json) orelse return bad(diag, n, "the tool's input is a JSON object");
            try checkJson(a, w, v, n, diag);
        },
        else => {},
    }
    for (s.match) |m| try checkText(a, w, m, s.match_line, diag);
    for (s.ifs) |f| if (try nameProblem(a, w, f.cond.field)) |why| return bad(diag, f.line, why);
}

fn checkJson(a: Allocator, w: Workflow, v: jv.Value, n: usize, diag: *Diag) Error!void {
    switch (v) {
        .string => |s| try checkText(a, w, s, n, diag),
        .array => |arr| for (arr.items) |x| try checkJson(a, w, x, n, diag),
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| try checkJson(a, w, e.value_ptr.*, n, diag);
        },
        else => {},
    }
}

fn checkText(a: Allocator, w: Workflow, text: []const u8, n: usize, diag: *Diag) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '{') {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '{') {
            i += 2;
            continue;
        }
        // a brace a name does not follow is text (`{"reply": …}`)
        const close = std.mem.indexOfScalarPos(u8, text, i, '}') orelse break;
        const name = text[i + 1 .. close];
        if (!placeholderName(name)) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, name, "secret:")) return bad(diag, n, "a step names no secret: MCP servers hold their own (mcp.ini)");
        if (try nameProblem(a, w, name)) |why| return bad(diag, n, why);
        i = close + 1;
    }
}

/// Why `name` is no value an instance can have; null: it can be.
fn nameProblem(a: Allocator, w: Workflow, name: []const u8) !?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const root = name[0 .. dot orelse name.len];
    if (oneOf(root, &.{ "input", "instance", "now" })) {
        if (dot != null) return try std.fmt.allocPrint(a, "{{{s}}}: {s} has no fields", .{ name, root });
        return null;
    }
    if (std.mem.eql(u8, root, "event")) return null;
    if (w.find(root) != null) return null;
    var names: std.ArrayList(u8) = .empty;
    for (w.steps, 0..) |s, i| try names.print(a, "{s}{s}", .{ if (i > 0) ", " else "", s.name });
    return try std.fmt.allocPrint(a, "{{{s}}} names no step (steps: {s}) nor input, event, instance or now", .{ name, names.items });
}

/// A placeholder's name: letters, digits, `_`, `-`, `.` (and `:` only to
/// tell a secret apart).
fn placeholderName(n: []const u8) bool {
    if (n.len == 0 or n.len > 200) return false;
    for (n) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == ':')) return false;
    return n[0] != '.' and n[n.len - 1] != '.';
}

// ---- what a file names elsewhere ----

/// A running MCP server and its tools.
pub const McpServer = struct { name: []const u8, tools: []const []const u8 };

/// What a workflow may name besides its own steps.
pub const Context = struct {
    /// triggers.ini's sections.
    triggers: []const triggers.Trigger = &.{},
    /// Whether a definition is there; null: not checked.
    agent: ?*const fn (ctx: ?*anyopaque, name: []const u8) bool = null,
    agent_ctx: ?*anyopaque = null,
    /// The MCP servers that run and their tools; null: not checked (they
    /// start after the settings are read).
    mcp: ?[]const McpServer = null,
};

/// Checks what `w` names outside itself: a `start` trigger or schedule
/// whose `start = workflow NAME` names it, `wait event` triggers (and the
/// fields `match` reads), definitions, MCP tools of servers that run.
/// Returns warnings (an MCP server that does not run); a problem in `diag`.
pub fn check(a: Allocator, w: Workflow, ctx: Context, diag: *Diag) Error![]const []const u8 {
    var warns: std.ArrayList([]const u8) = .empty;
    for (w.start) |s| {
        const trigger = std.mem.startsWith(u8, s, "trigger:");
        if (!trigger and !std.mem.startsWith(u8, s, "schedule:")) continue;
        const name = s[std.mem.indexOfScalar(u8, s, ':').? + 1 ..];
        const tr = findTrigger(ctx.triggers, name);
        const ok = if (tr) |x| x.isEvent() == trigger and x.action == .start and std.mem.eql(u8, x.action.start, w.name) else false;
        if (!ok) return badf(a, diag, w.start_line, "{s} has no start = workflow {s} in triggers.ini ({s})", .{ name, w.name, if (trigger) "an event trigger" else "a schedule" });
    }
    if (ctx.agent) |has| {
        var uses_agent = false;
        for (w.steps) |s| if (s.action == .do) {
            const d = if (s.agent.len > 0) s.agent else w.agent;
            if (s.agent.len == 0) uses_agent = true;
            if (!has(ctx.agent_ctx, d)) return badf(a, diag, if (s.agent.len > 0) s.agent_line else if (w.agent_line > 0) w.agent_line else s.action_line, "agent {s} is not defined (no agents/{s}.md)", .{ d, d });
        };
        if (!uses_agent and w.agent_line > 0 and !has(ctx.agent_ctx, w.agent)) return badf(a, diag, w.agent_line, "agent {s} is not defined (no agents/{s}.md)", .{ w.agent, w.agent });
    }
    for (w.steps) |s| switch (s.action) {
        .wait => |wt| if (wt == .event) {
            const tr = findTrigger(ctx.triggers, wt.event);
            if (tr == null or !tr.?.isEvent()) return badf(a, diag, s.action_line, "wait event: triggers.ini has no event trigger {s}", .{wt.event});
            if (triggers.fieldsOf(tr.?.kind)) |known| for (s.match) |m| {
                const c = condOf(a, m, true) catch continue;
                if (!oneOf(c.field, known)) return badf(a, diag, s.match_line, "{s} events have {s}", .{ @tagName(tr.?.kind), try std.mem.join(a, ", ", known) });
            };
        },
        .tool => |tl| if (ctx.mcp) |servers| if (std.mem.indexOfScalar(u8, tl.name, '/')) |slash| {
            const server = tl.name[0..slash];
            const tool = tl.name[slash + 1 ..];
            const srv = for (servers) |x| {
                if (std.mem.eql(u8, x.name, server)) break x;
            } else {
                try warns.append(a, try std.fmt.allocPrint(a, "{s} is not running: step {s} can't call {s} until it is", .{ server, s.name, tl.name }));
                continue;
            };
            if (!oneOf(tool, srv.tools)) return badf(a, diag, s.action_line, "{s} has no tool {s}", .{ server, tool });
        },
        else => {},
    };
    return warns.items;
}

fn findTrigger(list: []const triggers.Trigger, name: []const u8) ?triggers.Trigger {
    for (list) |tr| if (std.mem.eql(u8, tr.name, name)) return tr;
    return null;
}

// ---- values ----

/// The value called `name` among an instance's `values` (a JSON object):
/// the key itself (`draft.ok`), else the step's value and a path of its
/// fields (`draft.reply`, `items.0.id`). Null when there is none.
pub fn lookup(values: jv.Value, name: []const u8) ?jv.Value {
    if (values != .object) return null;
    if (values.object.get(name)) |v| return if (v == .null) null else v;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    var cur: jv.Value = values.object.get(name[0..dot]) orelse return null;
    var parts = std.mem.splitScalar(u8, name[dot + 1 ..], '.');
    while (parts.next()) |p| cur = jv.at(cur, &.{p}) orelse return null;
    return cur;
}

/// A value as text: a string as it is, a number as written, true or
/// false, null as nothing, anything else as JSON.
pub fn textOf(a: Allocator, v: jv.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .null => "",
        else => std.json.Stringify.valueAlloc(a, v, .{}),
    };
}

/// An event's field (text) as a value: a JSON number, true, false or null
/// when its text reads as one, else a string (R4).
pub fn typed(a: Allocator, text: []const u8) jv.Value {
    if (jv.parse(a, text)) |v| switch (v) {
        .integer, .float, .number_string, .bool, .null => return v,
        else => {},
    };
    return .{ .string = text };
}

/// `template` with each `{name}` its value as text and `{{` a brace. A
/// value there is none of: error.MissingValue, its name in `missing`.
pub fn fillText(a: Allocator, template: []const u8, values: jv.Value, missing: *[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try out.append(a, '{');
                i += 2;
                continue;
            }
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                const name = template[i + 1 .. close];
                if (placeholderName(name)) {
                    const v = lookup(values, name) orelse {
                        missing.* = name;
                        return error.MissingValue;
                    };
                    try out.appendSlice(a, try textOf(a, v));
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(a, ch);
        i += 1;
    }
    return out.items;
}

/// An agent step's text: each `{name}` becomes `[name]`, and the values
/// follow apart, a `[name]: value` line each (never spliced into the
/// instruction); `extra` names values that go there too when there are
/// (R5).
pub const Data = struct { text: []const u8, data: []const u8 };

pub fn fillData(a: Allocator, template: []const u8, values: jv.Value, extra: []const []const u8, missing: *[]const u8) !Data {
    var text: std.ArrayList(u8) = .empty;
    var data: std.ArrayList(u8) = .empty;
    var named: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try text.append(a, '{');
                i += 2;
                continue;
            }
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                const name = template[i + 1 .. close];
                if (placeholderName(name)) {
                    const v = lookup(values, name) orelse {
                        missing.* = name;
                        return error.MissingValue;
                    };
                    try text.print(a, "[{s}]", .{name});
                    if (!oneOf(name, named.items)) {
                        try named.append(a, name);
                        try data.print(a, "[{s}]: {s}\n", .{ name, util.cut(try textOf(a, v), max_value) });
                    }
                    i = close + 1;
                    continue;
                }
            }
        }
        try text.append(a, ch);
        i += 1;
    }
    for (extra) |name| {
        if (oneOf(name, named.items)) continue;
        const v = lookup(values, name) orelse continue;
        const s = try textOf(a, v);
        if (s.len == 0) continue;
        try data.print(a, "[{s}]: {s}\n", .{ name, util.cut(s, max_value) });
    }
    return .{ .text = text.items, .data = data.items };
}

/// A tool step's input: `template` read as JSON, then its strings filled
/// on the tree: a string that is exactly `"{x}"` takes the value with its
/// type, `{x}` in a longer string becomes text, and keys are never filled,
/// so a value can't add a field. Returns the JSON to send.
pub fn fillJson(a: Allocator, template: []const u8, values: jv.Value, missing: *[]const u8) ![]const u8 {
    const v = jv.parse(a, template) orelse return error.BadJson;
    const filled = try fillValue(a, v, values, missing);
    return std.json.Stringify.valueAlloc(a, filled, .{});
}

fn fillValue(a: Allocator, v: jv.Value, values: jv.Value, missing: *[]const u8) !jv.Value {
    switch (v) {
        .string => |s| {
            if (wholePlaceholder(s)) |name| return lookup(values, name) orelse {
                missing.* = name;
                return error.MissingValue;
            };
            return .{ .string = try fillText(a, s, values, missing) };
        },
        .array => |arr| {
            var out = jv.Value{ .array = .init(a) };
            for (arr.items) |x| try out.array.append(try fillValue(a, x, values, missing));
            return out;
        },
        .object => |o| {
            var m: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try m.put(a, e.key_ptr.*, try fillValue(a, e.value_ptr.*, values, missing));
            return .{ .object = m };
        },
        else => return v,
    }
}

/// `x` when `s` is exactly `{x}`.
fn wholePlaceholder(s: []const u8) ?[]const u8 {
    if (s.len < 3 or s[0] != '{' or s[s.len - 1] != '}' or s[1] == '{') return null;
    const name = s[1 .. s.len - 1];
    return if (placeholderName(name)) name else null;
}

// ---- where a step goes ----

pub const Next = union(enum) { step: usize, end };

/// Where an instance goes after step `i` succeeded: the first `if` that
/// holds, else its `goto`, else `end`, else the next step in the file
/// (after the last one: the end).
pub fn next(a: Allocator, w: Workflow, i: usize, values: jv.Value) Next {
    const s = w.steps[i];
    for (s.ifs) |f| if (ifHolds(a, f.cond, values)) return if (w.find(f.goto)) |k| .{ .step = k } else .end;
    if (s.goto.len > 0) return if (w.find(s.goto)) |k| .{ .step = k } else .end;
    if (s.end or i + 1 >= w.steps.len) return .end;
    return .{ .step = i + 1 };
}

/// Whether an `if` condition holds: its field is a value's name; a value
/// there is none of never holds.
pub fn ifHolds(a: Allocator, c: triggers.Cond, values: jv.Value) bool {
    const v = lookup(values, c.field) orelse return false;
    const text = textOf(a, v) catch return false;
    return triggers.holds(c, &.{.{ .name = c.field, .value = text }});
}

/// Whether every `match` line of a `wait event` holds for an event's
/// fields, their values' placeholders filled from the instance's values
/// as text (one there is none of: it does not hold).
pub fn matchHolds(a: Allocator, match: []const []const u8, values: jv.Value, fields: []const triggers.Field) bool {
    for (match) |m| {
        var missing: []const u8 = "";
        const filled = fillText(a, m, values, &missing) catch return false;
        const c = triggers.parseCond(a, filled, null) catch return false;
        if (!triggers.holds(c, fields)) return false;
    }
    return true;
}

/// Whether a step only reads, so one cut off by a restart runs again: a
/// tool step reading pages, searches, files or memory, a wait, an approve
/// or review (their items stay over a restart).
pub fn readOnly(s: Step) bool {
    return switch (s.action) {
        .tool => |tl| oneOf(tl.name, &.{ "fetch", "search", "browse", "read_file", "recall" }),
        .wait, .approve, .review, .none => true,
        .do, .say => false,
    };
}

// ---- harness's reading ----

/// What a workflow does, in harness's words (never the model's): who may
/// start it, its limits, each step with its tool, branches, waits and
/// retries, and the steps that move money (`money` says which MCP tools
/// do).
pub fn reading(a: Allocator, w: Workflow, money: ?*const fn (ctx: ?*anyopaque, tool: []const u8) bool, money_ctx: ?*anyopaque) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Workflow {s}", .{w.name});
    if (w.about.len > 0) try out.print(a, ": {s}", .{util.cut(w.about, 300)});
    try out.appendSlice(a, "\nWho may start it: ");
    for (w.start, 0..) |s, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        if (std.mem.eql(u8, s, "owner")) {
            try out.appendSlice(a, "you (/workflow start)");
        } else if (std.mem.eql(u8, s, "agent")) {
            try out.appendSlice(a, "the agent (the workflow tool, asked)");
        } else if (std.mem.startsWith(u8, s, "trigger:")) {
            try out.print(a, "trigger {s} (an instance per event)", .{s["trigger:".len..]});
        } else try out.print(a, "schedule {s}", .{s["schedule:".len..]});
    }
    try out.print(a, ".\nAt most {d} steps and {d} day{s} an instance, {d} at once (more wait in line); it posts to {s}", .{ w.limits.steps, w.limits.days, if (w.limits.days == 1) "" else "s", w.limits.at_once, w.to });
    var has_do = false;
    for (w.steps) |s| if (s.action == .do) {
        has_do = true;
    };
    if (has_do) try out.print(a, "; agent steps run {s}", .{w.agent});
    if (w.urgent) try out.appendSlice(a, "; urgent: its posts and questions go through quiet hours");
    try out.appendSlice(a, ".");
    var moving: std.ArrayList(u8) = .empty;
    for (w.steps, 1..) |s, n| {
        try out.print(a, "\n{d}. {s}: ", .{ n, s.name });
        switch (s.action) {
            .none => try out.appendSlice(a, "no action"),
            .tool => |tl| {
                try out.print(a, "calls {s} {s}", .{ tl.name, util.cut(oneLine(a, tl.json), 200) });
                if (money) |f| if (f(money_ctx, tl.name)) try moving.print(a, "{s}{s} ({s})", .{ if (moving.items.len > 0) ", " else "", s.name, tl.name });
            },
            .do => |text| {
                try out.print(a, "a run of {s}", .{if (s.agent.len > 0) s.agent else w.agent});
                if (s.tools) |tl| try out.print(a, " with tools {s}", .{try std.mem.join(a, ", ", tl)});
                if (s.answer_json) try out.appendSlice(a, ", answering in JSON");
                try out.print(a, ": {s}", .{util.cut(oneLine(a, text), 200)});
            },
            .wait => |wt| switch (wt) {
                .timer => |secs| try out.print(a, "waits {s}", .{try triggers.fmtDuration(a, secs)}),
                .until => |m| try out.print(a, "waits until {d:0>2}:{d:0>2}, your time", .{ m / 60, m % 60 }),
                .event => |tr| {
                    try out.print(a, "waits for the next event of trigger {s}", .{tr});
                    for (s.match, 0..) |m, i| try out.print(a, "{s}{s}", .{ if (i == 0) " whose " else " and ", m });
                    try out.print(a, " (up to {s})", .{try triggers.fmtDuration(a, s.timeout())});
                },
            },
            .approve => |text| try out.print(a, "asks you to approve: {s} (no answer in {s}: denied)", .{ util.cut(oneLine(a, text), 200), try triggers.fmtDuration(a, s.timeout()) }),
            .review => |text| try out.print(a, "shows you a draft to use, drop or replace: {s} (no answer in {s}: dropped)", .{ util.cut(oneLine(a, text), 200), try triggers.fmtDuration(a, s.timeout()) }),
            .say => |text| try out.print(a, "says: {s}", .{util.cut(oneLine(a, text), 200)}),
        }
        if (s.env.len > 0) try out.print(a, ", in {s}", .{s.env});
        if (s.retry > 0) try out.print(a, "; {d} more tr{s} after a failure, {s} apart and doubling", .{ s.retry, if (s.retry == 1) "y" else "ies", try triggers.fmtDuration(a, s.retry_wait_s) });
        for (s.ifs) |f| try out.print(a, "; if {s}, on to {s}", .{ try triggers.condText(a, f.cond), f.goto });
        if (s.on_fail.len > 0) try out.print(a, "; failed, on to {s}", .{s.on_fail});
        if (s.on_deny.len > 0) try out.print(a, "; denied, on to {s}", .{s.on_deny});
        if (s.on_timeout.len > 0) try out.print(a, "; no event in time, on to {s}", .{s.on_timeout});
        if (s.goto.len > 0) try out.print(a, "; then on to {s}", .{s.goto});
        if (s.end) try out.appendSlice(a, "; then the end");
    }
    if (moving.items.len > 0) try out.print(a, "\nMoves money: {s}; asked every time, never for 24 h.", .{moving.items});
    return out.items;
}

/// `text` on one line: its breaks as spaces.
fn oneLine(a: Allocator, text: []const u8) []const u8 {
    const out = a.dupe(u8, text) catch return text;
    for (out) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    return out;
}

// ---- tests ----

const t = std.testing;

/// The spec's example.
const issue_reply =
    \\workflow issue-reply
    \\about Drafts a reply to each new zigworks issue; posts it once I approve.
    \\start trigger:zigworks-issues, owner
    \\limits steps 20, days 3, at-once 3
    \\
    \\step draft
    \\answer json
    \\do:
    \\  Draft a short first reply to the GitHub issue in the event. Answer only
    \\  with JSON: {"reply": "…", "label": "bug|question|idea"}
    \\retry 2 wait 1m
    \\if draft.label is idea goto note
    \\
    \\step ask
    \\approve:
    \\  Post this on #{event.number}?
    \\  {draft.reply}
    \\timeout 2d
    \\
    \\step post
    \\tool github/add_issue_comment:
    \\  {"owner": "legatia", "repo": "zigworks",
    \\   "issue_number": "{event.number}", "body": "{draft.reply}"}
    \\retry 3 wait 5m
    \\end
    \\
    \\step note
    \\say #{event.number} is an idea; I left it for you.
    \\
;

fn refused(a: Allocator, name: []const u8, text: []const u8, line: usize, why: []const u8) !void {
    var d: Diag = .{};
    if (parse(a, name, text, &d)) |_| {
        std.debug.print("read, but should not:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    } else |e| try t.expectEqual(error.BadWorkflow, e);
    if (d.line != line or std.mem.indexOf(u8, d.why, why) == null) {
        std.debug.print("{s}\nwant line {d}: {s}\ngot line {d}: {s}\n", .{ text, line, why, d.line, d.why });
        return error.TestUnexpectedResult;
    }
}

test "every_step_kind_reads_and_a_bad_line_is_named" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const w = try parse(a, "issue-reply", issue_reply, &d);
    try t.expectEqualStrings("issue-reply", w.name);
    try t.expectEqualStrings("Drafts a reply to each new zigworks issue; posts it once I approve.", w.about);
    try t.expectEqual(2, w.start.len);
    try t.expect(w.allows("trigger:zigworks-issues", false) and w.allows("owner", false) and !w.allows("owner", true));
    try t.expectEqual(Limits{ .steps = 20, .days = 3, .at_once = 3 }, w.limits);
    try t.expectEqual(4, w.steps.len);
    const draft = w.steps[0];
    try t.expect(draft.answer_json and draft.retry == 2 and draft.retry_wait_s == 60);
    try t.expect(std.mem.startsWith(u8, draft.action.do, "Draft a short first reply") and std.mem.indexOf(u8, draft.action.do, "\nwith JSON: {\"reply\"") != null);
    try t.expectEqual(1, draft.ifs.len);
    try t.expectEqualStrings("note", draft.ifs[0].goto);
    try t.expectEqualStrings("draft.label", draft.ifs[0].cond.field);
    try t.expectEqualStrings("Post this on #{event.number}?\n{draft.reply}", w.steps[1].action.approve);
    try t.expectEqual(2 * 86400, w.steps[1].timeout());
    const post = w.steps[2];
    try t.expectEqualStrings("github/add_issue_comment", post.action.tool.name);
    try t.expect(std.mem.startsWith(u8, post.action.tool.json, "{\"owner\": \"legatia\"") and post.end and post.retry == 3 and post.retry_wait_s == 300);
    try t.expectEqualStrings("#{event.number} is an idea; I left it for you.", w.steps[3].action.say);
    // the other kinds and modifiers
    const more =
        \\# saved by agent:main 2026-11-22 (item 57)
        \\workflow more
        \\to news
        \\agent researcher
        \\step nap
        \\wait 2h
        \\step morning
        \\wait until 09:00
        \\step next-issue
        \\wait event issues
        \\match title has {input}
        \\match number > 3
        \\timeout 1d
        \\on timeout goto nap
        \\step check
        \\review Use this? {next-issue.title}
        \\on deny goto nap
        \\step build
        \\tool shell {"command": "make"}
        \\env host
        \\on fail goto nap
        \\step think
        \\do Sum it up.
        \\agent helper
        \\tools fetch, github/*
        \\step loop
        \\if build.ok is false goto nap
        \\goto morning
    ;
    const m = try parse(a, "more", more, &d);
    try t.expectEqualStrings("saved by agent:main 2026-11-22 (item 57)", m.saved);
    try t.expectEqualStrings("news", m.to);
    try t.expectEqualStrings("researcher", m.agent);
    try t.expectEqual(7200, m.steps[0].action.wait.timer);
    try t.expectEqual(9 * 60, m.steps[1].action.wait.until);
    try t.expectEqualStrings("issues", m.steps[2].action.wait.event);
    try t.expectEqual(2, m.steps[2].match.len);
    try t.expectEqualStrings("nap", m.steps[2].on_timeout);
    try t.expectEqualStrings("nap", m.steps[3].on_deny);
    try t.expectEqualStrings("host", m.steps[4].env);
    try t.expectEqualStrings("helper", m.steps[5].agent);
    try t.expectEqual(2, m.steps[5].tools.?.len);
    try t.expectEqualStrings("morning", m.steps[6].goto);
    // each bad line named, with why
    try refused(a, "x", "workflow other\nstep a\nsay hi\n", 1, "the file is x.wf: workflow x");
    try refused(a, "x", "about hi\n", 1, "starts with workflow NAME");
    try refused(a, "x", "workflow x\nstep input\nsay hi\n", 2, "not input, event, instance or now");
    try refused(a, "x", "workflow x\nstep a\nsay hi\ngoto nowhere\n", 4, "there is no step nowhere (steps: a)");
    try refused(a, "x", "workflow x\nstep a\nsay {nope}\n", 3, "{nope} names no step (steps: a)");
    try refused(a, "x", "workflow x\nstep a\nsay {secret:github}\n", 3, "a step names no secret");
    try refused(a, "x", "workflow x\nstep a\ntool web {}\n", 3, "web is no step tool");
    try refused(a, "x", "workflow x\nstep a\ntool trigger {}\n", 3, "it is never a step");
    try refused(a, "x", "workflow x\nstep a\ntool shell [1]\n", 3, "the tool's input is a JSON object");
    try refused(a, "x", "workflow x\nstep a\ntool shell {\"command\":\"ls\"}\nenv Box!\n", 4, "env takes host or an environment's name (a-z, 0-9, - and _, up to 32)");
    try refused(a, "x", "workflow x\nstep a\nsay hi\nmatch title has x\n", 4, "match goes with wait event");
    try refused(a, "x", "workflow x\nstep a\nsay hi\ndo more\n", 4, "a step takes one action");
    try refused(a, "x", "workflow x\nstep a\nsay hi\nretry two wait 1m\n", 4, "retry N wait D");
    try refused(a, "x", "workflow x\nstep a\nsay hi\n  more\n", 4, "an indented line goes below a line ending in :");
    try refused(a, "x", "workflow x\nstep a\nsay hi\nstep a\nsay ho\n", 4, "a step called a comes before");
    try refused(a, "x", "workflow x\nstart nobody\nstep a\nsay hi\n", 2, "start lists owner, agent");
    try refused(a, "x", "workflow x\nstep a\nsay hi\nstart owner\n", 4, "start goes in the head");
    try refused(a, "x", "workflow x\nstep a\nwait 2h\nretry 1 wait 1m\n", 4, "retry goes with tool, do, say and wait event");
    try refused(a, "x", "workflow x\nstep a\nsay hi {{\nif nope.x is 1 goto a\n", 4, "{nope.x} names no step");
    try refused(a, "x", "workflow x\nstep a\nsay {now.x}\n", 3, "now has no fields");
    try refused(a, "x", "workflow x\nstep a\nsay hi\nanswer json\n", 4, "answer json goes with do");
    try refused(a, "x", "workflow x\nstep a\n", 2, "a step needs an action");
    try refused(a, "start", "workflow start\nstep a\nsay hi\n", 1, "not start, stop");
}

/// Values as an instance has them: `s` a tool step's JSON result.
fn testValues(a: Allocator) !jv.Value {
    var v = jv.parse(a, "{\"input\":\"hello\",\"instance\":\"w#1\",\"s\":{\"count\":3,\"tags\":[\"a\"],\"title\":\"x\\\", \\\"admin\\\": true, \\\"y\\\": \\\"\"},\"s.ok\":true,\"event\":{}}").?;
    try v.object.getPtr("event").?.object.put(a, "number", typed(a, "42"));
    try v.object.getPtr("event").?.object.put(a, "title", typed(a, "Fix it"));
    return v;
}

test "tool_json_is_filled_on_the_tree_so_a_value_adds_no_field" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = try testValues(a);
    var missing: []const u8 = "";
    // a value that looks like more fields stays one string
    const got = try fillJson(a, "{\"name\": \"{s.title}\", \"note\": \"see {s.title}\", \"{s.title}\": 1}", values, &missing);
    const v = jv.parse(a, got).?;
    try t.expectEqual(3, v.object.count());
    try t.expectEqualStrings("x\", \"admin\": true, \"y\": \"", jv.str(jv.get(v, "name")).?);
    try t.expect(jv.get(v, "admin") == null);
    // keys are never filled
    try t.expectEqual(@as(i64, 1), jv.int(jv.get(v, "{s.title}")).?);
}

test "a_whole_placeholder_keeps_its_type" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = try testValues(a);
    var missing: []const u8 = "";
    const got = try fillJson(a, "{\"n\": \"{s.count}\", \"tags\": \"{s.tags}\", \"ok\": \"{s.ok}\", \"issue\": \"{event.number}\", \"title\": \"{event.title}\", \"text\": \"n {s.count}\", \"list\": [\"{s.count}\", 2]}", values, &missing);
    try t.expectEqualStrings("{\"n\":3,\"tags\":[\"a\"],\"ok\":true,\"issue\":42,\"title\":\"Fix it\",\"text\":\"n 3\",\"list\":[3,2]}", got);
    // as text, in say, approve, review and match
    try t.expectEqualStrings("3 [\"a\"] true 42 hello", try fillText(a, "{s.count} {s.tags} {s.ok} {event.number} {input}", values, &missing));
    // in an agent step, apart, as data
    const data = try fillData(a, "Reply to {event.title} ({s.count}), {event.title}.", values, &.{ "input", "nothing" }, &missing);
    try t.expectEqualStrings("Reply to [event.title] ([s.count]), [event.title].", data.text);
    try t.expectEqualStrings("[event.title]: Fix it\n[s.count]: 3\n[input]: hello\n", data.data);
}

test "a_missing_value_fails_the_step" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = try testValues(a);
    var missing: []const u8 = "";
    try t.expectError(error.MissingValue, fillText(a, "a {s.nope} b", values, &missing));
    try t.expectEqualStrings("s.nope", missing);
    try t.expectError(error.MissingValue, fillJson(a, "{\"x\": \"{draft}\"}", values, &missing));
    try t.expectEqualStrings("draft", missing);
    try t.expectError(error.MissingValue, fillJson(a, "{\"x\": [\"a {event.nope}\"]}", values, &missing));
    try t.expectEqualStrings("event.nope", missing);
    try t.expectError(error.MissingValue, fillData(a, "do {input} {gone}", values, &.{}, &missing));
    try t.expectEqualStrings("gone", missing);
    // {{ is a brace, not a value
    try t.expectEqualStrings("{x} and {", try fillText(a, "{{x} and {", values, &missing));
    // where a step goes: the first if that holds, else the next one
    var d: Diag = .{};
    const w = try parse(a, "x", "workflow x\nstep s\nsay hi\nif s.count > 2 goto c\nstep b\nsay b\nend\nstep c\nsay c\n", &d);
    try t.expectEqual(Next{ .step = 2 }, next(a, w, 0, values));
    try t.expectEqual(Next.end, next(a, w, 1, values));
    try t.expectEqual(Next.end, next(a, w, 2, values));
    try t.expect(!ifHolds(a, w.steps[0].ifs[0].cond, jv.parse(a, "{}").?));
    try t.expect(matchHolds(a, &.{"title has {input}"}, values, &.{.{ .name = "title", .value = "Say Hello there" }}));
    try t.expect(!matchHolds(a, &.{"title has {gone}"}, values, &.{.{ .name = "title", .value = "x" }}));
}

fn moneyTool(ctx: ?*anyopaque, tool: []const u8) bool {
    _ = ctx;
    return std.mem.eql(u8, tool, "github/add_issue_comment");
}

test "a_reading_says_what_each_step_does" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const w = try parse(a, "issue-reply", issue_reply, &d);
    const r = try reading(a, w, moneyTool, null);
    for ([_][]const u8{
        "Workflow issue-reply: Drafts a reply to each new zigworks issue; posts it once I approve.",
        "Who may start it: trigger zigworks-issues (an instance per event), you (/workflow start).",
        "At most 20 steps and 3 days an instance, 3 at once (more wait in line); it posts to main; agent steps run main.",
        "\n1. draft: a run of main, answering in JSON: Draft a short first reply",
        "; 2 more tries after a failure, 1 min apart and doubling; if draft.label is \"idea\", on to note",
        "\n2. ask: asks you to approve: Post this on #{event.number}? {draft.reply} (no answer in 2 days: denied)",
        "\n3. post: calls github/add_issue_comment {\"owner\": \"legatia\"",
        "; then the end",
        "\n4. note: says: #{event.number} is an idea; I left it for you.",
        "\nMoves money: post (github/add_issue_comment); asked every time, never for 24 h.",
    }) |needle| if (std.mem.indexOf(u8, r, needle) == null) {
        std.debug.print("no {s} in:\n{s}\n", .{ needle, r });
        return error.TestUnexpectedResult;
    };
    // what it names elsewhere
    var td: triggers.Diag = .{};
    const tlist = try triggers.parse(a, "[zigworks-issues]\nmcp = github/list_issues {}\nkey = number\nsay = x\n", .triggers, &td);
    try t.expectError(error.BadWorkflow, check(a, w, .{ .triggers = tlist }, &d));
    try t.expect(std.mem.indexOf(u8, d.why, "zigworks-issues has no start = workflow issue-reply") != null);
    try t.expectEqual(3, d.line);
    const ok = try triggers.parse(a, "[zigworks-issues]\nmcp = github/list_issues {}\nkey = number\nstart = workflow issue-reply\n", .triggers, &td);
    const warns = try check(a, w, .{ .triggers = ok, .mcp = &.{} }, &d);
    try t.expectEqual(1, warns.len);
    try t.expect(std.mem.indexOf(u8, warns[0], "github is not running") != null);
    try t.expectError(error.BadWorkflow, check(a, w, .{ .triggers = ok, .mcp = &.{.{ .name = "github", .tools = &.{"list_issues"} }} }, &d));
    try t.expectEqualStrings("github has no tool add_issue_comment", d.why);
    try t.expect(readOnly(w.steps[1]) and !readOnly(w.steps[2]) and !readOnly(w.steps[3]));
}

test "urgent_is_read_in_the_head" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const w = try parse(a, "leak", "workflow leak\nurgent yes\nstep ask\napprove Close the water main?\n", &d);
    try t.expect(w.urgent);
    // as triggers.ini writes it, too
    try t.expect((try parse(a, "leak", "workflow leak\nurgent = yes\nstep s\nsay hi\n", &d)).urgent);
    try t.expect(!(try parse(a, "leak", "workflow leak\nurgent no\nstep s\nsay hi\n", &d)).urgent);
    try t.expect(!(try parse(a, "plain", "workflow plain\nstep s\nsay hi\n", &d)).urgent);
    try t.expect(std.mem.indexOf(u8, try reading(a, w, null, null), "; urgent: its posts and questions go through quiet hours.") != null);
    try refused(a, "leak", "workflow leak\nurgent sometimes\nstep s\nsay hi\n", 2, "urgent yes or no");
    try refused(a, "leak", "workflow leak\nstep s\nurgent yes\nsay hi\n", 3, "urgent goes in the head");
}

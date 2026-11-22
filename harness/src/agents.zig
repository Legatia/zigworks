//! Agent definitions: `agents/NAME.md`, a header like a skill's (between
//! `---` lines) and the instructions as the body. An agent is a file, a
//! run one execution of it. Built in: `main` (the agent) and `helper`
//! (what `delegate` starts); a file of the same name replaces one, so
//! without `agents/` harness is as before.
const std = @import("std");
const skills = @import("skills.zig");
const gate = @import("gate.zig");
const rules = @import("rules.zig");
const util = @import("util.zig");
const Io = std.Io;

/// The most a definition's file may hold.
pub const max_file = 8 * 1024;
/// The most definitions, the built-ins counted.
pub const max_defs = 32;
pub const max_description = skills.max_description;

/// The words the agent commands take: never a definition's name.
const command_words = [_][]const u8{ "list", "show", "rm" };

/// a-z, 0-9 and `-` (not first, last or twice in a row), up to 64, and
/// none of the commands' words.
pub fn validName(name: []const u8) bool {
    if (!skills.validName(name)) return false;
    for (command_words) |w| if (std.mem.eql(u8, w, name)) return false;
    return true;
}

/// What of memory a definition's prompt gets: `shared` the pinned items,
/// the strongest and what a message recalls; `pinned` the pinned only.
pub const Memory = enum { shared, pinned };

/// One definition, as its file says.
pub const Def = struct {
    name: []const u8,
    /// One line: when to use it.
    description: []const u8,
    /// A model value: `PROVIDER:MODEL`, or a model of `[model] provider`
    /// (`model.Providers.pick`); "": `[model] model`, or `worker_model`
    /// when delegated.
    model: []const u8 = "",
    /// Tool names, `server/tool`, `server/*`, `*` for all.
    tools: []const []const u8 = &default_tools,
    /// Skill names or patterns (`zig-*`), `*` for all.
    skills: []const []const u8 = &.{"*"},
    memory: Memory = .shared,
    /// Per run; null: `[limits]`, or `[agents]` when delegated.
    steps: ?u32 = null,
    /// Input tokens per run, summed; null: none, or `[agents] tokens` when delegated.
    tokens: ?u32 = null,
    /// Per run; null: `[limits] turn_seconds`, or what is left of the turn when delegated.
    seconds: ?u32 = null,
    /// A delegated run's answer; null: `[agents] answer_bytes`.
    answer_bytes: ?u32 = null,
    /// Most runs of it at once; 0: the global limits only.
    parallel: u32 = 0,
    /// Where its commands run: `host` until environments (gap 2).
    environment: []const u8 = "host",
    /// Who saved it with `agent_save`, and when (harness writes it).
    saved: []const u8 = "",
    /// The instructions.
    body: []const u8 = "",
    /// The whole file (a built-in's as `harness init` writes it).
    text: []const u8 = "",
    /// No file: harness's own.
    builtin: bool = false,

    /// Whether its `tools` take `name`: a built-in tool's name, or an MCP
    /// tool as `server/tool`.
    pub fn allowsTool(d: *const Def, name: []const u8) bool {
        return toolMatches(d.tools, name);
    }

    /// Whether its `skills` take the skill `name`.
    pub fn allowsSkill(d: *const Def, name: []const u8) bool {
        for (d.skills) |p| if (rules.glob(p, name)) return true;
        return false;
    }

    /// A copy whose every slice is in `a`.
    pub fn clone(d: *const Def, a: std.mem.Allocator) !Def {
        var out = d.*;
        inline for (.{ "name", "description", "model", "environment", "saved", "body", "text" }) |f|
            @field(out, f) = try a.dupe(u8, @field(d, f));
        out.tools = try dupeList(a, d.tools);
        out.skills = try dupeList(a, d.skills);
        return out;
    }
};

fn dupeList(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

/// A definition's tools when its file names none: the helper's six of 0.3.
pub const default_tools = [_][]const u8{ "search", "fetch", "browse", "read_file", "recall", "skill" };

/// Where a definition does not read, and why.
pub const Diag = struct {
    /// "agents/researcher.md" (set by the folder's reader).
    file: []const u8 = "",
    /// 0: the file as a whole.
    line: usize = 0,
    why: []const u8 = "",

    /// "agents/x.md line 3 has an error: unknown key colour".
    pub fn text(d: *const Diag, a: std.mem.Allocator) ![]const u8 {
        const file = if (d.file.len > 0) d.file else "the definition";
        if (d.line == 0) return std.fmt.allocPrint(a, "{s} {s}", .{ file, d.why });
        return std.fmt.allocPrint(a, "{s} line {d} has an error: {s}", .{ file, d.line, d.why });
    }
};

pub const Error = error{ BadDefinition, OutOfMemory };

/// The header's keys.
const Key = enum { name, description, model, tools, skills, memory, steps, tokens, seconds, answer_bytes, parallel, environment, saved };

fn fail(diag: *Diag, line: usize, why: []const u8) Error {
    diag.line = line;
    diag.why = why;
    return error.BadDefinition;
}

/// Reads the definition `name` from its file's `text`. A text that does
/// not read is error.BadDefinition, with the line and why in `diag`.
pub fn parse(a: std.mem.Allocator, name: []const u8, text: []const u8, diag: *Diag) Error!Def {
    if (text.len > max_file) return fail(diag, 0, try std.fmt.allocPrint(a, "is over 8 KB ({d} bytes)", .{text.len}));
    const h = skills.readHeader(a, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diag, 1, "a definition starts with a header between --- lines"),
    };
    var d: Def = .{ .name = "", .description = "", .body = h.body, .text = text };
    var seen: std.EnumSet(Key) = .empty;
    for (h.fields) |f| {
        if (f.nested) return fail(diag, f.line, "nested values are not read; write a list on one line, separated by commas");
        if (f.key.len == 0) return fail(diag, f.line, "not a key: value line");
        const k = std.meta.stringToEnum(Key, f.key) orelse return fail(diag, f.line, try std.fmt.allocPrint(a, "unknown key {s}", .{f.key}));
        if (seen.contains(k)) return fail(diag, f.line, try std.fmt.allocPrint(a, "{s} is given twice", .{f.key}));
        seen.insert(k);
        const v = f.value;
        switch (k) {
            .name => if (!std.mem.eql(u8, v, name)) return fail(diag, f.line, try std.fmt.allocPrint(a, "name {s} is not the file's name ({s})", .{ v, name })),
            .description => {
                if (v.len == 0 or v.len > max_description or hasControl(v)) return fail(diag, f.line, "description is one line of up to 1024 bytes");
                d.description = v;
            },
            .model => {
                if (v.len == 0 or v.len > 128 or std.mem.indexOfAny(u8, v, " \t") != null or hasControl(v)) return fail(diag, f.line, "model is a model's name, or PROVIDER:MODEL");
                d.model = v;
            },
            .tools => d.tools = try readList(a, v, diag, f.line, .tools),
            .skills => d.skills = try readList(a, v, diag, f.line, .skills),
            .memory => d.memory = std.meta.stringToEnum(Memory, v) orelse return fail(diag, f.line, "memory is shared or pinned"),
            .steps, .tokens, .seconds, .answer_bytes => {
                const n = std.fmt.parseInt(u32, v, 10) catch 0;
                if (n == 0) return fail(diag, f.line, try std.fmt.allocPrint(a, "{s} is a whole number from 1", .{f.key}));
                switch (k) {
                    .steps => d.steps = n,
                    .tokens => d.tokens = n,
                    .seconds => d.seconds = n,
                    else => d.answer_bytes = n,
                }
            },
            .parallel => d.parallel = std.fmt.parseInt(u32, v, 10) catch return fail(diag, f.line, "parallel is a whole number (0: the global limits only)"),
            .environment => {
                if (!std.mem.eql(u8, v, "host")) return fail(diag, f.line, try std.fmt.allocPrint(a, "environment {s}: only host for now; other environments come later", .{v}));
                d.environment = v;
            },
            .saved => d.saved = v,
        }
    }
    if (!seen.contains(.name)) return fail(diag, 1, "the header has no name");
    if (!seen.contains(.description)) return fail(diag, 1, "the header has no description");
    d.name = name;
    return d;
}

fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

/// A comma-separated list of tools or skills; `none` alone for none.
fn readList(a: std.mem.Allocator, v: []const u8, diag: *Diag, line: usize, comptime what: Key) Error![]const []const u8 {
    if (std.mem.eql(u8, v, "none")) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        const ok = switch (what) {
            .tools => knownTool(item),
            else => skillPattern(item),
        };
        if (!ok) return fail(diag, line, if (item.len == 0)
            try std.fmt.allocPrint(a, "{s} is a list on one line, separated by commas (none for none)", .{@tagName(what)})
        else
            try std.fmt.allocPrint(a, "unknown {s} {s}", .{ if (what == .tools) "tool" else "skill pattern", item }));
        try out.append(a, item);
    }
    return out.items;
}

/// A tool a definition may name: `*`, a built-in tool, `server/tool` or
/// `server/*`.
fn knownTool(name: []const u8) bool {
    if (std.mem.eql(u8, name, "*")) return true;
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const server = name[0..slash];
        const tool = name[slash + 1 ..];
        if (!serverName(server) or tool.len == 0) return false;
        for (tool) |c| if (c <= 0x20 or c == 0x7f or c == '/') return false;
        return true;
    }
    const tl = gate.Tool.fromName(name) orelse return false;
    return switch (tl) {
        // kinds, not tools: an MCP tool is `server/tool`; login is web's
        .mcp, .money, .login => false,
        else => true,
    };
}

/// An MCP server's name as mcp.ini takes it: a-z, 0-9, - and _, up to 32, no `__`.
fn serverName(s: []const u8) bool {
    if (s.len == 0 or s.len > 32 or std.mem.indexOf(u8, s, "__") != null) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

/// A skill's name, with `*` for any run of characters.
fn skillPattern(p: []const u8) bool {
    if (p.len == 0 or p.len > skills.max_name) return false;
    for (p) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '*')) return false;
    return true;
}

/// Whether a pattern of `patterns` takes the tool `name` (a built-in
/// tool's name, or `server/tool`): `*` all, the name itself, `server/*`
/// all of a server's tools, `*/*` any MCP tool.
pub fn toolMatches(patterns: []const []const u8, name: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, name, '/');
    for (patterns) |p| {
        if (std.mem.eql(u8, p, "*") or std.mem.eql(u8, p, name)) return true;
        if (!std.mem.endsWith(u8, p, "/*")) continue;
        const server = p[0 .. p.len - 2];
        const s = slash orelse continue;
        if (std.mem.eql(u8, server, "*") or std.mem.eql(u8, server, name[0..s])) return true;
    }
    return false;
}

/// The built-in `main`, as `harness init` writes it.
pub const main_md =
    \\---
    \\name: main
    \\description: The agent: talks with the owner in every conversation and runs the scheduled tasks.
    \\tools: *
    \\---
    \\You are a personal agent working for one person, the owner, who talks to you in a chat.
    \\Be brief and plain. Do what was asked; ask when something is unclear.
    \\Use `remember` for lasting facts about the owner or their wishes, not for passing details.
    \\
;

/// The built-in `helper`, as `harness init` writes it.
pub const helper_md =
    \\---
    \\name: helper
    \\description: Does one task handed over with delegate and answers the agent that asked.
    \\# A task that names no tools gets search, fetch, browse, read_file, recall and skill.
    \\tools: *
    \\memory: pinned
    \\---
    \\You are a helper doing one task for an agent that works for its owner. Do only this task, with the tools you have.
    \\When done, answer in at most about 300 words: the result first, then the links you used, then anything you could not do and why. Your answer goes to the agent, not to the owner.
    \\
;

/// The body of a built-in's text: what follows its header's closing line.
fn bodyOf(comptime text: []const u8) []const u8 {
    const close = comptime std.mem.indexOf(u8, text[3..], "\n---\n").? + 3;
    return text[close + 5 ..];
}

pub const builtin_main: Def = .{
    .name = "main",
    .description = "The agent: talks with the owner in every conversation and runs the scheduled tasks.",
    .tools = &.{"*"},
    .body = bodyOf(main_md),
    .text = main_md,
    .builtin = true,
};

pub const builtin_helper: Def = .{
    .name = "helper",
    .description = "Does one task handed over with delegate and answers the agent that asked.",
    .tools = &.{"*"},
    .memory = .pinned,
    .body = bodyOf(helper_md),
    .text = helper_md,
    .builtin = true,
};

/// The built-ins, in the order they are listed.
pub const builtins = [_]*const Def{ &builtin_helper, &builtin_main };

// ---- a change's reading ----

/// What a definition's unset limits are: `[limits]` for a run of its
/// own, `[agents]` for a delegated one.
pub const Defaults = struct {
    steps: u32 = 20,
    seconds: u32 = 600,
    delegated_steps: u32 = 12,
    delegated_tokens: u32 = 150000,
    answer_bytes: u32 = 4000,
};

/// Harness's reading of a new text against the old: each header field
/// that changes, as a line ("model: claude-haiku → claude-sonnet").
pub const Comparison = struct {
    /// Tools, MCP tools or skills added; memory to shared; model or
    /// environment changed; a limit raised. For a new definition: what it
    /// may use.
    widens: []const []const u8,
    other: []const []const u8,
};

pub fn compare(a: std.mem.Allocator, old_def: ?Def, new: Def, d: Defaults) !Comparison {
    var widens: std.ArrayList([]const u8) = .empty;
    var other: std.ArrayList([]const u8) = .empty;
    const old = old_def orelse {
        // a new definition: what it may use, as harness reads it
        try widens.append(a, try std.fmt.allocPrint(a, "tools: {s}", .{try listText(a, new.tools)}));
        try widens.append(a, try std.fmt.allocPrint(a, "skills: {s}", .{try listText(a, new.skills)}));
        try widens.append(a, try std.fmt.allocPrint(a, "model: {s}", .{if (new.model.len > 0) new.model else "default ([model] model; worker_model when delegated)"}));
        try widens.append(a, try std.fmt.allocPrint(a, "memory: {s}", .{@tagName(new.memory)}));
        inline for (limit_fields) |lf| if (@field(new, lf)) |v| try widens.append(a, try std.fmt.allocPrint(a, "{s}: {d}", .{ lf, v }));
        if (new.parallel > 0) try widens.append(a, try std.fmt.allocPrint(a, "parallel: {d}", .{new.parallel}));
        try widens.append(a, try std.fmt.allocPrint(a, "environment: {s}", .{new.environment}));
        return .{ .widens = widens.items, .other = other.items };
    };
    if (!std.mem.eql(u8, old.description, new.description)) try other.append(a, try std.fmt.allocPrint(a, "description: {s} → {s}", .{ old.description, new.description }));
    // tools and skills: one the old ones did not cover widens
    inline for (.{ "tools", "skills" }) |field| {
        const was = @field(old, field);
        const now = @field(new, field);
        if (!sameList(was, now)) {
            var added: std.ArrayList([]const u8) = .empty;
            var dropped: std.ArrayList([]const u8) = .empty;
            for (now) |p| if (!covered(field, was, p)) try added.append(a, p);
            for (was) |p| if (!covered(field, now, p)) try dropped.append(a, p);
            var line: std.ArrayList(u8) = .empty;
            try line.print(a, "{s}: {s} → {s}", .{ field, try listText(a, was), try listText(a, now) });
            if (added.items.len > 0) try line.print(a, " (adds {s})", .{try std.mem.join(a, ", ", added.items)});
            try (if (added.items.len > 0) &widens else &other).append(a, line.items);
        }
    }
    if (!std.mem.eql(u8, old.model, new.model)) try widens.append(a, try std.fmt.allocPrint(a, "model: {s} → {s}", .{ orDefault(old.model), orDefault(new.model) }));
    if (old.memory != new.memory) try (if (new.memory == .shared) &widens else &other).append(a, try std.fmt.allocPrint(a, "memory: {s} → {s}", .{ @tagName(old.memory), @tagName(new.memory) }));
    if (!std.mem.eql(u8, old.environment, new.environment)) try widens.append(a, try std.fmt.allocPrint(a, "environment: {s} → {s}", .{ old.environment, new.environment }));
    // a limit is raised when a run of its own or a delegated one may do more
    inline for (limit_fields) |lf| {
        const was = @field(old, lf);
        const now = @field(new, lf);
        if (was != now) {
            const own = ownDefault(lf, d);
            const del = delegatedDefault(lf, d);
            const raised = effective(now, own) > effective(was, own) or effective(now, del) > effective(was, del);
            try (if (raised) &widens else &other).append(a, try std.fmt.allocPrint(a, "{s}: {s} → {s}", .{ lf, try limitText(a, was), try limitText(a, now) }));
        }
    }
    if (old.parallel != new.parallel) {
        // 0 is no cap of its own: the most
        const raised = old.parallel != 0 and (new.parallel == 0 or new.parallel > old.parallel);
        try (if (raised) &widens else &other).append(a, try std.fmt.allocPrint(a, "parallel: {d} → {d}", .{ old.parallel, new.parallel }));
    }
    if (!std.mem.eql(u8, old.body, new.body)) try other.append(a, "instructions: changed (the whole file is below)");
    return .{ .widens = widens.items, .other = other.items };
}

const limit_fields = .{ "steps", "tokens", "seconds", "answer_bytes" };

/// The most a limit allows; none at all is the most there is.
const unlimited = std.math.maxInt(u64);

/// What an unset limit is for a run of its own.
fn ownDefault(comptime field: []const u8, d: Defaults) u64 {
    if (comptime std.mem.eql(u8, field, "steps")) return d.steps;
    if (comptime std.mem.eql(u8, field, "seconds")) return d.seconds;
    // no token cap of its own; an answer's size is a delegated run's
    return unlimited;
}

/// What an unset limit is for a delegated run (its seconds never past its
/// parent's turn).
fn delegatedDefault(comptime field: []const u8, d: Defaults) u64 {
    if (comptime std.mem.eql(u8, field, "steps")) return d.delegated_steps;
    if (comptime std.mem.eql(u8, field, "tokens")) return d.delegated_tokens;
    if (comptime std.mem.eql(u8, field, "seconds")) return d.seconds;
    return d.answer_bytes;
}

fn effective(v: ?u32, default: u64) u64 {
    return if (v) |x| x else default;
}

fn limitText(a: std.mem.Allocator, v: ?u32) ![]const u8 {
    return if (v) |x| std.fmt.allocPrint(a, "{d}", .{x}) else "default";
}

fn orDefault(model: []const u8) []const u8 {
    return if (model.len > 0) model else "default";
}

fn listText(a: std.mem.Allocator, list: []const []const u8) ![]const u8 {
    if (list.len == 0) return "none";
    return std.mem.join(a, ", ", list);
}

fn sameList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// Whether one of `list` already takes all that pattern `p` takes.
fn covered(comptime field: []const u8, list: []const []const u8, p: []const u8) bool {
    for (list) |q| {
        if (std.mem.eql(u8, q, "*") or std.mem.eql(u8, q, p)) return true;
        if (comptime std.mem.eql(u8, field, "tools")) {
            // a server's tools, or any MCP tool
            const slash = std.mem.indexOfScalar(u8, p, '/') orelse continue;
            if (std.mem.eql(u8, q, "*/*")) return true;
            if (std.mem.endsWith(u8, q, "/*") and std.mem.eql(u8, q[0 .. q.len - 2], p[0..slash]) and !std.mem.eql(u8, p, "*/*")) return true;
        } else if (rules.glob(q, p)) return true;
    }
    return false;
}

/// The question's part that says what changes: "Widens:" first, then the
/// rest; for a new definition what it may use.
pub fn readingText(a: std.mem.Allocator, old: ?Def, c: Comparison) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (old == null) {
        try out.appendSlice(a, "It may use:\n");
        for (c.widens) |l| try out.print(a, "- {s}\n", .{l});
        return out.items;
    }
    if (c.widens.len > 0) {
        try out.appendSlice(a, "Widens:\n");
        for (c.widens) |l| try out.print(a, "- {s}\n", .{l});
    }
    if (c.other.len > 0) {
        try out.appendSlice(a, "Other changes:\n");
        for (c.other) |l| try out.print(a, "- {s}\n", .{l});
    }
    if (out.items.len == 0) try out.appendSlice(a, "No field changes.\n");
    return out.items;
}

/// `text` with its header's `saved:` line saying `value` (any the text
/// had dropped), put last in the header; the rest as it was. A text
/// without a header is returned as it was (the parser refuses it).
pub fn withSaved(a: std.mem.Allocator, text: []const u8, value: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return text;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, std.mem.trimStart(u8, first, "\xEF\xBB\xBF"), "\r"), "---")) return text;
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}\n", .{first});
    while (lines.next()) |line| {
        const bare = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.eql(u8, bare, "---")) {
            try out.print(a, "saved: {s}\n{s}", .{ value, line });
            if (lines.rest().len > 0 or lines.index != null) try out.append(a, '\n');
            try out.appendSlice(a, lines.rest());
            return out.items;
        }
        if (std.mem.startsWith(u8, bare, "saved:")) continue;
        try out.print(a, "{s}\n", .{line});
    }
    return text;
}

// ---- the folder ----

/// The definitions of a data folder: the built-ins, then each
/// `agents/NAME.md` over them. Shared by all runs (under its mutex); a run
/// takes a copy of its definition when it starts, so a change saved
/// meanwhile applies to the next run and frees nothing a run holds.
pub const Set = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// `agents/`; "": the built-ins only, and nothing is saved.
    dir: []const u8 = "",
    /// `state/agents/`: each definition's earlier versions.
    state: []const u8 = "",
    mutex: Io.Mutex = .init,
    items: std.ArrayList(*Item) = .empty,

    pub const Item = struct {
        arena: std.heap.ArenaAllocator,
        def: Def,
        /// The SHA-256 of its file as last read or written; null: a
        /// built-in without a file.
        file_hash: ?[32]u8 = null,
    };

    /// What `read` found, until `install` takes it.
    pub const Loaded = struct {
        gpa: std.mem.Allocator,
        items: std.ArrayList(*Item) = .empty,

        pub fn deinit(l: *Loaded) void {
            freeItems(l.gpa, &l.items);
        }

        pub fn has(l: *const Loaded, name: []const u8) bool {
            for (l.items.items) |it| if (std.mem.eql(u8, it.def.name, name)) return true;
            return false;
        }
    };

    pub fn init(gpa: std.mem.Allocator, io: Io, dir: []const u8, state: []const u8) Set {
        return .{ .gpa = gpa, .io = io, .dir = dir, .state = state };
    }

    pub fn deinit(s: *Set) void {
        freeItems(s.gpa, &s.items);
    }

    /// Reads the built-ins, then each `NAME.md` of the folder over them;
    /// nothing in `s` changes. A folder or file other users can write, a
    /// file that does not read, or more than `max_defs` definitions is
    /// error.BadDefinition, said in `diag` (its strings in `scratch`).
    pub fn read(s: *const Set, scratch: std.mem.Allocator, diag: *Diag) Error!Loaded {
        var l: Loaded = .{ .gpa = s.gpa };
        errdefer l.deinit();
        for (builtins) |b| {
            const it = try newItem(s.gpa);
            it.def = b.*;
            l.items.append(s.gpa, it) catch |e| {
                freeItem(s.gpa, it);
                return e;
            };
        }
        if (s.dir.len == 0) return l;
        var d = Io.Dir.cwd().openDir(s.io, s.dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return l,
            else => return failIn(scratch, diag, "agents", 0, try std.fmt.allocPrint(scratch, "can't be read ({s})", .{@errorName(e)})),
        };
        defer d.close(s.io);
        if (others_can_write) {
            const st = d.stat(s.io) catch |e| return failIn(scratch, diag, "agents", 0, try std.fmt.allocPrint(scratch, "can't be read ({s})", .{@errorName(e)}));
            if (st.permissions.toMode() & 0o022 != 0) return failIn(scratch, diag, "agents", 0, "can be changed by other users; run chmod go-w on it (it decides what runs)");
        }
        var files = d.iterate();
        while (files.next(s.io) catch |e| return failIn(scratch, diag, "agents", 0, try std.fmt.allocPrint(scratch, "can't be read ({s})", .{@errorName(e)}))) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, e.name, ".md")) continue;
            const file = try std.fmt.allocPrint(scratch, "agents/{s}", .{e.name});
            const name = e.name[0 .. e.name.len - 3];
            if (!validName(name)) return failIn(scratch, diag, file, 0, "is no definition's file: NAME.md, the name in a-z, 0-9 and - (up to 64), not list, show or rm");
            if (others_can_write) {
                const st = d.statFile(s.io, e.name, .{}) catch |err| return failIn(scratch, diag, file, 0, try std.fmt.allocPrint(scratch, "can't be read ({s})", .{@errorName(err)}));
                if (st.permissions.toMode() & 0o022 != 0) return failIn(scratch, diag, file, 0, try std.fmt.allocPrint(scratch, "can be changed by other users; run chmod 600 on it", .{}));
            }
            const it = try newItem(s.gpa);
            var kept = false;
            defer if (!kept) freeItem(s.gpa, it);
            const ia = it.arena.allocator();
            const text = d.readFileAlloc(s.io, e.name, ia, .limited(max_file + 1)) catch |err| switch (err) {
                error.StreamTooLong => return failIn(scratch, diag, file, 0, "is over 8 KB"),
                error.OutOfMemory => return error.OutOfMemory,
                else => return failIn(scratch, diag, file, 0, try std.fmt.allocPrint(scratch, "can't be read ({s})", .{@errorName(err)})),
            };
            var pd: Diag = .{};
            it.def = parse(ia, try ia.dupe(u8, name), text, &pd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDefinition => return failIn(scratch, diag, file, pd.line, try scratch.dupe(u8, pd.why)),
            };
            it.file_hash = sha(text);
            // over a built-in of the same name
            for (l.items.items, 0..) |old, i| {
                if (!std.mem.eql(u8, old.def.name, it.def.name)) continue;
                l.items.items[i] = it;
                freeItem(s.gpa, old);
                break;
            } else try l.items.append(s.gpa, it);
            kept = true;
            if (l.items.items.len > max_defs) return failIn(scratch, diag, "agents", 0, "has more than 32 definitions, the built-ins counted");
        }
        std.mem.sort(*Item, l.items.items, {}, struct {
            fn lt(_: void, x: *Item, y: *Item) bool {
                return std.mem.order(u8, x.def.name, y.def.name) == .lt;
            }
        }.lt);
        return l;
    }

    /// Puts what `read` found in place of what was there.
    pub fn install(s: *Set, l: Loaded) void {
        var old = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const o = s.items;
            s.items = l.items;
            break :blk o;
        };
        freeItems(s.gpa, &old);
    }

    pub fn load(s: *Set, scratch: std.mem.Allocator, diag: *Diag) Error!void {
        s.install(try s.read(scratch, diag));
    }

    /// A copy of the definition `name` in `a`; null: none.
    pub fn get(s: *Set, a: std.mem.Allocator, name: []const u8) !?Def {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const it = s.find(name) orelse return null;
        return try it.def.clone(a);
    }

    pub fn has(s: *Set, name: []const u8) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.find(name) != null;
    }

    /// Copies of all, by name.
    pub fn list(s: *Set, a: std.mem.Allocator) ![]Def {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const out = try a.alloc(Def, s.items.items.len);
        for (s.items.items, out) |it, *o| o.* = try it.def.clone(a);
        return out;
    }

    /// The definition's `parallel` (0 for none, or for no such definition).
    pub fn parallelOf(s: *Set, name: []const u8) u32 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return if (s.find(name)) |it| it.def.parallel else 0;
    }

    /// Under the mutex.
    fn find(s: *const Set, name: []const u8) ?*Item {
        for (s.items.items) |it| if (std.mem.eql(u8, it.def.name, name)) return it;
        return null;
    }

    /// Writes the definition `name` (its whole file, which `parse` takes):
    /// the file there before goes to its versions (the last 10 kept), the
    /// new one is written whole (a new file, then a rename), and runs that
    /// start from now on get it.
    pub fn save(s: *Set, name: []const u8, text: []const u8) !void {
        if (s.dir.len == 0) return error.NoFolder;
        const it = try newItem(s.gpa);
        var kept = false;
        defer if (!kept) freeItem(s.gpa, it);
        const ia = it.arena.allocator();
        var pd: Diag = .{};
        it.def = try parse(ia, try ia.dupe(u8, name), try ia.dupe(u8, text), &pd);
        it.file_hash = sha(text);
        const cwd = Io.Dir.cwd();
        _ = try cwd.createDirPathStatus(s.io, s.dir, private_dir);
        var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}{c}{s}.md", .{ s.dir, std.fs.path.sep, name });
        if (cwd.readFileAlloc(s.io, path, s.gpa, .limited(1 << 20))) |old| {
            defer s.gpa.free(old);
            try s.keepVersion(name, old);
        } else |e| if (e != error.FileNotFound) return e;
        // whole or not at all, even with it open in an editor
        try util.writeReplace(s.io, path, text);
        const old = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.items.items, 0..) |o, i| if (std.mem.eql(u8, o.def.name, name)) {
                s.items.items[i] = it;
                break :blk o;
            };
            var at: usize = 0;
            while (at < s.items.items.len and std.mem.order(u8, s.items.items[at].def.name, name) == .lt) at += 1;
            try s.items.insert(s.gpa, at, it);
            break :blk null;
        };
        kept = true;
        if (old) |o| freeItem(s.gpa, o);
    }

    /// Moves the definition's file to its versions; refused for `main` and
    /// `helper` (harness's own).
    pub fn remove(s: *Set, name: []const u8) !void {
        for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return error.BuiltIn;
        if (s.dir.len == 0 or !s.has(name)) return error.NotFound;
        const cwd = Io.Dir.cwd();
        var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}{c}{s}.md", .{ s.dir, std.fs.path.sep, name });
        const text = try cwd.readFileAlloc(s.io, path, s.gpa, .limited(1 << 20));
        defer s.gpa.free(text);
        try s.keepVersion(name, text);
        try cwd.deleteFile(s.io, path);
        const gone = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.items.items, 0..) |o, i| if (std.mem.eql(u8, o.def.name, name)) break :blk s.items.orderedRemove(i);
            break :blk null;
        };
        if (gone) |o| freeItem(s.gpa, o);
    }

    /// The folder of `name`'s earlier versions (in `buf`).
    fn versionsDir(s: *const Set, buf: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}{c}{s}{c}versions", .{ s.state, std.fs.path.sep, name, std.fs.path.sep });
    }

    /// Keeps `text` as the newest of `name`'s versions, dropping all but
    /// the last 10.
    fn keepVersion(s: *Set, name: []const u8, text: []const u8) !void {
        var vbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        try keepVersionIn(s.io, s.gpa, try s.versionsDir(&vbuf, name), text);
    }

    /// How many earlier versions of `name` are kept.
    pub fn versions(s: *Set, name: []const u8) usize {
        if (s.state.len == 0) return 0;
        var vbuf: [Io.Dir.max_path_bytes]u8 = undefined;
        const vdir = s.versionsDir(&vbuf, name) catch return 0;
        var d = Io.Dir.cwd().openDir(s.io, vdir, .{ .iterate = true }) catch return 0;
        defer d.close(s.io);
        var n: usize = 0;
        var it = d.iterate();
        while (it.next(s.io) catch null) |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.name, ".md")) n += 1;
        }
        return n;
    }

    /// Whether the folder's files are no longer what was last read or
    /// written (a hand edit, a file added or removed): they apply after
    /// /reload. A save does not count.
    pub fn changedOnDisk(s: *Set) bool {
        if (s.dir.len == 0) return false;
        const Known = struct { name: [64]u8, len: usize, hash: [32]u8 };
        var known: [max_defs]Known = undefined;
        var n_known: usize = 0;
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.items.items) |it| if (it.file_hash) |h| {
                if (n_known == known.len or it.def.name.len > 64) return true;
                known[n_known] = .{ .name = undefined, .len = it.def.name.len, .hash = h };
                @memcpy(known[n_known].name[0..it.def.name.len], it.def.name);
                n_known += 1;
            };
        }
        var d = Io.Dir.cwd().openDir(s.io, s.dir, .{ .iterate = true }) catch return n_known > 0;
        defer d.close(s.io);
        var on_disk: usize = 0;
        var buf: [max_file + 1]u8 = undefined;
        var it = d.iterate();
        while (it.next(s.io) catch return true) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, e.name, ".md")) continue;
            on_disk += 1;
            const name = e.name[0 .. e.name.len - 3];
            const k = for (known[0..n_known]) |*x| {
                if (std.mem.eql(u8, x.name[0..x.len], name)) break x;
            } else return true;
            const text = d.readFile(s.io, e.name, &buf) catch return true;
            if (!std.mem.eql(u8, &sha(text), &k.hash)) return true;
        }
        return on_disk != n_known;
    }
};

/// Versions kept of each definition.
const keep_versions = 10;

/// Keeps `text` as the newest file of the folder `vdir`
/// (`20261122T140211Z-001.md`, so the names sort in time order), dropping
/// all but the last 10. Definitions and skills keep their replaced files so.
pub fn keepVersionIn(io: Io, gpa: std.mem.Allocator, vdir: []const u8, text: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, vdir);
    var d = try cwd.openDir(io, vdir, .{ .iterate = true });
    defer d.close(io);
    var tb: [20]u8 = undefined;
    const iso = util.isoTime(&tb, util.nowSeconds(io));
    var stamp: [16]u8 = undefined;
    var n: usize = 0;
    for (iso) |c| if (c != '-' and c != ':') {
        stamp[n] = c;
        n += 1;
    };
    // after the last of this second, so the names sort in time order
    var last: u32 = 0;
    var scan = d.iterate();
    while (try scan.next(io)) |e| {
        if (!std.mem.startsWith(u8, e.name, stamp[0..n]) or !std.mem.endsWith(u8, e.name, ".md")) continue;
        const num = e.name[@min(n + 1, e.name.len) .. e.name.len - 3];
        last = @max(last, std.fmt.parseInt(u32, num, 10) catch 0);
    }
    var nb: [40]u8 = undefined;
    const file = try std.fmt.bufPrint(&nb, "{s}-{d:0>3}.md", .{ stamp[0..n], last + 1 });
    try d.writeFile(io, .{ .sub_path = file, .data = text, .flags = .{ .permissions = util.private_file } });
    // the names sort in time order: all but the last 10 go
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |x| gpa.free(x);
        names.deinit(gpa);
    }
    var it = d.iterate();
    while (try it.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".md")) {
        const x = try gpa.dupe(u8, e.name);
        names.append(gpa, x) catch |err| {
            gpa.free(x);
            return err;
        };
    };
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    if (names.items.len > keep_versions) for (names.items[0 .. names.items.len - keep_versions]) |x| d.deleteFile(io, x) catch {};
}

/// On macOS and Linux a folder or file other users can write is refused.
const others_can_write = @import("builtin").os.tag != .windows;

/// `agents/` is made readable only by its owner.
pub const private_dir: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700);

fn sha(text: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &h, .{});
    return h;
}

fn newItem(gpa: std.mem.Allocator) !*Set.Item {
    const it = try gpa.create(Set.Item);
    it.* = .{ .arena = .init(gpa), .def = undefined };
    return it;
}

fn freeItem(gpa: std.mem.Allocator, it: *Set.Item) void {
    it.arena.deinit();
    gpa.destroy(it);
}

fn failIn(scratch: std.mem.Allocator, diag: *Diag, file: []const u8, line: usize, why: []const u8) Error {
    _ = scratch;
    diag.* = .{ .file = file, .line = line, .why = why };
    return error.BadDefinition;
}

fn freeItems(gpa: std.mem.Allocator, items: *std.ArrayList(*Set.Item)) void {
    for (items.items) |it| freeItem(gpa, it);
    items.deinit(gpa);
}

/// What is wrong with the definitions in `dir`, said so the owner can fix
/// it; null when nothing is.
pub fn problem(io: Io, a: std.mem.Allocator, dir: []const u8) !?[]const u8 {
    var s: Set = .init(a, io, dir, "");
    var diag: Diag = .{};
    var l = s.read(a, &diag) catch |e| switch (e) {
        error.BadDefinition => return try diag.text(a),
        else => |x| return x,
    };
    l.deinit();
    return null;
}

// ---- tests ----

const t = std.testing;

/// The error `parse` gives for `text` as the file of `name`.
fn diagOf(a: std.mem.Allocator, name: []const u8, text: []const u8) !Diag {
    var d: Diag = .{};
    if (parse(a, name, text, &d)) |_| {
        std.debug.print("expected an error for:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    } else |e| try t.expectEqual(error.BadDefinition, e);
    return d;
}

test "bad_definitions_are_named_with_their_line" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "---\nname: researcher\ndescription: Research.\n";
    // the name is the file's
    var d = try diagOf(a, "researcher", "---\nname: researchr\ndescription: Research.\n---\nBody\n");
    try t.expectEqual(2, d.line);
    try t.expectEqualStrings("name researchr is not the file's name (researcher)", d.why);
    // an unknown key, an unknown tool, another environment
    d = try diagOf(a, "researcher", head ++ "colour: red\n---\n");
    try t.expectEqual(4, d.line);
    try t.expectEqualStrings("unknown key colour", d.why);
    d = try diagOf(a, "researcher", head ++ "tools: search, telnet\n---\n");
    try t.expectEqual(4, d.line);
    try t.expectEqualStrings("unknown tool telnet", d.why);
    d = try diagOf(a, "researcher", head ++ "environment: box\n---\n");
    try t.expect(std.mem.indexOf(u8, d.why, "only host") != null);
    // a key twice, a nested line, a line that is no key, a bad number
    d = try diagOf(a, "researcher", head ++ "model: a\nmodel: b\n---\n");
    try t.expectEqual(5, d.line);
    try t.expectEqualStrings("model is given twice", d.why);
    d = try diagOf(a, "researcher", head ++ "tools:\n  - search\n---\n");
    try t.expectEqual(4, d.line);
    try t.expectEqualStrings("tools is a list on one line, separated by commas (none for none)", d.why);
    d = try diagOf(a, "researcher", head ++ "model: a\n  b\n---\n");
    try t.expectEqual(5, d.line);
    try t.expect(std.mem.indexOf(u8, d.why, "on one line") != null);
    d = try diagOf(a, "researcher", head ++ "just words\n---\n");
    try t.expectEqual(4, d.line);
    d = try diagOf(a, "researcher", head ++ "steps: 0\n---\n");
    try t.expectEqualStrings("steps is a whole number from 1", d.why);
    d = try diagOf(a, "researcher", head ++ "memory: all\n---\n");
    try t.expectEqualStrings("memory is shared or pinned", d.why);
    // no name, no closing line, too large
    d = try diagOf(a, "researcher", "---\ndescription: Research.\n---\n");
    try t.expectEqualStrings("the header has no name", d.why);
    d = try diagOf(a, "researcher", head ++ "Body without a closing line\n");
    try t.expectEqual(1, d.line);
    const big = try a.alloc(u8, max_file + 1);
    @memset(big, 'x');
    @memcpy(big[0..head.len], head);
    d = try diagOf(a, "researcher", big);
    try t.expectEqual(0, d.line);
    try t.expectEqualStrings("is over 8 KB (8193 bytes)", d.why);
    d.file = "agents/researcher.md";
    try t.expectEqualStrings("agents/researcher.md is over 8 KB (8193 bytes)", try d.text(a));
    d.line = 4;
    d.why = "unknown key colour";
    try t.expectEqualStrings("agents/researcher.md line 4 has an error: unknown key colour", try d.text(a));
}

test "a_definition_reads_every_key" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const d = try parse(a, "researcher",
        \\---
        \\name: researcher
        \\description: Research across several sources; answers with links.
        \\model: claude-haiku
        \\tools: search, fetch, browse, read_file, recall, skill, github/list_issues
        \\skills: zig-*, notes
        \\memory: pinned
        \\steps: 8
        \\tokens: 90000
        \\seconds: 300
        \\answer_bytes: 2000
        \\parallel: 4
        \\environment: host
        \\saved: agent:main 2026-11-22T14:02:11Z
        \\---
        \\Research one question at a time. Use at least two independent sources.
        \\
    , &diag);
    try t.expectEqualStrings("researcher", d.name);
    try t.expectEqualStrings("Research across several sources; answers with links.", d.description);
    try t.expectEqualStrings("claude-haiku", d.model);
    try t.expectEqual(7, d.tools.len);
    try t.expectEqual(.pinned, d.memory);
    try t.expectEqual(8, d.steps.?);
    try t.expectEqual(90000, d.tokens.?);
    try t.expectEqual(300, d.seconds.?);
    try t.expectEqual(2000, d.answer_bytes.?);
    try t.expectEqual(4, d.parallel);
    try t.expectEqualStrings("agent:main 2026-11-22T14:02:11Z", d.saved);
    try t.expectEqualStrings("Research one question at a time. Use at least two independent sources.\n", d.body);
    try t.expect(!d.builtin);
    try t.expect(d.allowsTool("github/list_issues"));
    try t.expect(!d.allowsTool("github/create_issue"));
    try t.expect(!d.allowsTool("shell"));
    try t.expect(d.allowsSkill("zig-build"));
    try t.expect(d.allowsSkill("notes"));
    try t.expect(!d.allowsSkill("deploy"));
    // a server's tools, all tools, none
    try t.expect(toolMatches(&.{"github/*"}, "github/create_issue"));
    try t.expect(!toolMatches(&.{"github/*"}, "gitlab/x"));
    try t.expect(toolMatches(&.{"*"}, "shell"));
    try t.expect(toolMatches(&.{"*/*"}, "github/x"));
    try t.expect(!toolMatches(&.{"*/*"}, "shell"));
    const none = try parse(a, "writer", "---\nname: writer\ndescription: Writes.\ntools: none\nskills: none\n---\n", &diag);
    try t.expectEqual(0, none.tools.len);
    try t.expect(!none.allowsSkill("x"));
    // what it leaves out: the helper's six, every skill
    const plain = try parse(a, "plain", "---\nname: plain\ndescription: Plain.\n---\n", &diag);
    try t.expectEqual(default_tools.len, plain.tools.len);
    try t.expect(plain.allowsTool("fetch") and !plain.allowsTool("shell"));
    try t.expect(plain.allowsSkill("anything"));
    try t.expectEqual(.shared, plain.memory);
    // a copy owns its strings
    var other: std.heap.ArenaAllocator = .init(t.allocator);
    defer other.deinit();
    const c = try d.clone(other.allocator());
    try t.expectEqualStrings(d.body, c.body);
    try t.expect(c.body.ptr != d.body.ptr);
    try t.expectEqualStrings("github/list_issues", c.tools[6]);
}

test "the_builtins_read_as_their_files" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (builtins) |b| {
        var diag: Diag = .{};
        const d = parse(a, b.name, b.text, &diag) catch |e| {
            std.debug.print("{s}: {s}\n", .{ b.name, diag.why });
            return e;
        };
        try t.expectEqualStrings(b.name, d.name);
        try t.expectEqualStrings(b.description, d.description);
        try t.expectEqualStrings(b.body, d.body);
        try t.expectEqual(b.memory, d.memory);
        try t.expectEqual(b.tools.len, d.tools.len);
        for (b.tools, d.tools) |x, y| try t.expectEqualStrings(x, y);
        try t.expectEqualStrings(b.model, d.model);
        try t.expectEqual(b.steps, d.steps);
        try t.expectEqual(b.parallel, d.parallel);
    }
    try t.expectEqual(.pinned, builtin_helper.memory);
    try t.expect(builtin_main.allowsTool("shell") and builtin_helper.allowsTool("shell"));
    try t.expect(std.mem.startsWith(u8, builtin_main.body, "You are a personal agent"));
    for ([_][]const u8{ "main", "researcher", "zig-2" }) |n| try t.expect(validName(n));
    for ([_][]const u8{ "rm", "show", "list", "Main", "a b", "a/b", "", "-a", "a:b" }) |n| try t.expect(!validName(n));
}

/// A folder for a set's files: `agents/` and `state/agents/` in a temp dir.
const SetFix = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    state: []const u8,
    set: Set,

    fn init(f: *SetFix) !void {
        f.tmp = t.tmpDir(.{});
        f.arena = .init(t.allocator);
        const a = f.arena.allocator();
        const root = try f.tmp.dir.realPathFileAlloc(t.io, ".", a);
        f.dir = try std.fs.path.join(a, &.{ root, "agents" });
        f.state = try std.fs.path.join(a, &.{ root, "state", "agents" });
        f.set = .init(t.allocator, t.io, f.dir, f.state);
    }

    fn deinit(f: *SetFix) void {
        f.set.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn put(f: *SetFix, name: []const u8, text: []const u8) !void {
        try f.tmp.dir.createDirPath(t.io, "agents");
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(f.arena.allocator(), "agents/{s}", .{name}), .data = text, .flags = .{ .permissions = @import("util.zig").private_file } });
    }

    fn load(f: *SetFix) !void {
        var diag: Diag = .{};
        f.set.load(f.arena.allocator(), &diag) catch |e| {
            std.debug.print("load: {s}\n", .{try diag.text(f.arena.allocator())});
            return e;
        };
    }

    /// The text `load` refuses the folder with.
    fn refused(f: *SetFix) ![]const u8 {
        var diag: Diag = .{};
        if (f.set.load(f.arena.allocator(), &diag)) |_| return error.TestUnexpectedResult else |e| try t.expectEqual(error.BadDefinition, e);
        return diag.text(f.arena.allocator());
    }
};

fn researcherText(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "---\nname: researcher\ndescription: Research.\nmodel: claude-r\n---\n{s}\n", .{body});
}

test "no_agents_folder_means_the_builtins" {
    var f: SetFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.load();
    const all = try f.set.list(a);
    try t.expectEqual(2, all.len);
    try t.expectEqualStrings("helper", all[0].name);
    try t.expectEqualStrings("main", all[1].name);
    try t.expect(all[0].builtin and all[1].builtin);
    try t.expect((try f.set.get(a, "main")).?.builtin);
    try t.expectEqual(null, try f.set.get(a, "researcher"));
    try t.expect(f.set.has("helper") and !f.set.has("researcher"));
    try t.expect(!f.set.changedOnDisk());
}

test "a_file_replaces_its_builtin_and_adds_to_the_list" {
    var f: SetFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put("main.md", "---\nname: main\ndescription: Mine.\ntools: *\n---\nMy own instructions.\n");
    try f.put("researcher.md", try researcherText(a, "Research one thing."));
    try f.put("parallel.md", "---\nname: parallel\ndescription: Two at once.\nparallel: 2\n---\n");
    try f.put("notes.txt", "not a definition");
    try f.load();
    const all = try f.set.list(a);
    try t.expectEqual(4, all.len);
    try t.expectEqualStrings("helper", all[0].name);
    try t.expect(all[0].builtin);
    try t.expectEqualStrings("main", all[1].name);
    try t.expect(!all[1].builtin);
    try t.expectEqualStrings("My own instructions.\n", all[1].body);
    try t.expectEqualStrings("researcher", all[3].name);
    try t.expectEqualStrings("claude-r", (try f.set.get(a, "researcher")).?.model);
    try t.expectEqual(2, f.set.parallelOf("parallel"));
    try t.expectEqual(0, f.set.parallelOf("researcher"));
    // a file that does not read: nothing changes, its file and line are named
    try f.put("bad.md", "---\nname: bad\ncolour: red\n---\n");
    try t.expectEqualStrings("agents/bad.md line 3 has an error: unknown key colour", try f.refused());
    try t.expectEqualStrings("agents/bad.md line 3 has an error: unknown key colour", (try problem(t.io, a, f.dir)).?);
    try t.expectEqual(4, (try f.set.list(a)).len);
    try f.tmp.dir.deleteFile(t.io, "agents/bad.md");
    try t.expectEqual(null, try problem(t.io, a, f.dir));
    // a file whose name is no definition's
    try f.put("Big.md", "---\nname: Big\ndescription: x\n---\n");
    try t.expect(std.mem.startsWith(u8, try f.refused(), "agents/Big.md "));
    try f.tmp.dir.deleteFile(t.io, "agents/Big.md");
    // at most 32, the built-ins counted
    for (0..29) |i| try f.put(try std.fmt.allocPrint(a, "d{d}.md", .{i}), try std.fmt.allocPrint(a, "---\nname: d{d}\ndescription: x\n---\n", .{i}));
    try t.expectEqualStrings("agents has more than 32 definitions, the built-ins counted", try f.refused());
}

test "a_folder_or_file_others_can_write_is_refused" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: SetFix = undefined;
    try f.init();
    defer f.deinit();
    try f.put("researcher.md", try researcherText(f.arena.allocator(), "x"));
    {
        var d = try f.tmp.dir.openDir(t.io, "agents", .{ .iterate = true });
        defer d.close(t.io);
        try d.setPermissions(t.io, .fromMode(0o777));
    }
    try t.expect(std.mem.indexOf(u8, try f.refused(), "agents can be changed by other users") != null);
    try t.expectEqual(0, (try f.set.list(f.arena.allocator())).len);
    {
        var d = try f.tmp.dir.openDir(t.io, "agents", .{ .iterate = true });
        defer d.close(t.io);
        try d.setPermissions(t.io, .fromMode(0o700));
    }
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "agents/researcher.md", .data = try researcherText(f.arena.allocator(), "y"), .flags = .{ .permissions = .fromMode(0o666) } });
    // writeFile keeps an existing file's mode: set it
    {
        var file = try f.tmp.dir.openFile(t.io, "agents/researcher.md", .{});
        defer file.close(t.io);
        try file.setPermissions(t.io, .fromMode(0o666));
    }
    try t.expect(std.mem.indexOf(u8, try f.refused(), "agents/researcher.md can be changed by other users") != null);
}

test "a_save_keeps_the_last_ten_versions" {
    var f: SetFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.load();
    try f.set.save("researcher", try researcherText(a, "v0"));
    try t.expectEqual(0, f.set.versions("researcher"));
    try t.expectEqualStrings("v0\n", (try f.set.get(a, "researcher")).?.body);
    for (1..13) |i| try f.set.save("researcher", try researcherText(a, try std.fmt.allocPrint(a, "v{d}", .{i})));
    try t.expectEqual(10, f.set.versions("researcher"));
    try t.expectEqualStrings("v12\n", (try f.set.get(a, "researcher")).?.body);
    try t.expectEqualStrings(try researcherText(a, "v12"), try f.tmp.dir.readFileAlloc(t.io, "agents/researcher.md", a, .unlimited));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "agents/researcher.md.tmp", .{}));
    // the oldest went: v2 to v11 are kept
    var d = try f.tmp.dir.openDir(t.io, "state/agents/researcher/versions", .{ .iterate = true });
    defer d.close(t.io);
    var kept: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(t.io)) |e| try kept.append(a, try d.readFileAlloc(t.io, e.name, a, .unlimited));
    try t.expectEqual(10, kept.items.len);
    for (kept.items) |x| try t.expect(std.mem.indexOf(u8, x, "\nv0\n") == null and std.mem.indexOf(u8, x, "\nv1\n") == null);
    var has11 = false;
    for (kept.items) |x| has11 = has11 or std.mem.indexOf(u8, x, "\nv11\n") != null;
    try t.expect(has11);
}

test "rm_moves_the_file_to_its_versions_and_keeps_the_builtins" {
    var f: SetFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.put("main.md", "---\nname: main\ndescription: Mine.\n---\nMine.\n");
    try f.load();
    try f.set.save("researcher", try researcherText(a, "v0"));
    try f.set.remove("researcher");
    try t.expectEqual(null, try f.set.get(a, "researcher"));
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "agents/researcher.md", .{}));
    try t.expectEqual(1, f.set.versions("researcher"));
    try t.expectError(error.BuiltIn, f.set.remove("main"));
    try t.expectError(error.BuiltIn, f.set.remove("helper"));
    try t.expectError(error.NotFound, f.set.remove("nobody"));
    try t.expect(f.set.has("main"));
}

test "a_change_on_disk_is_noticed_and_a_save_is_not" {
    var f: SetFix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.load();
    try t.expect(!f.set.changedOnDisk());
    try f.set.save("researcher", try researcherText(a, "saved"));
    try t.expect(!f.set.changedOnDisk());
    try f.put("researcher.md", try researcherText(a, "edited by hand"));
    try t.expect(f.set.changedOnDisk());
    try f.load();
    try t.expect(!f.set.changedOnDisk());
    try f.put("other.md", "---\nname: other\ndescription: x\n---\n");
    try t.expect(f.set.changedOnDisk());
    try f.tmp.dir.deleteFile(t.io, "agents/other.md");
    try t.expect(!f.set.changedOnDisk());
    try f.tmp.dir.deleteFile(t.io, "agents/researcher.md");
    try t.expect(f.set.changedOnDisk());
}

test "agent_save_lists_what_widens_first" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const old = try parse(a, "researcher", "---\nname: researcher\ndescription: Research.\nmodel: claude-haiku\ntools: search, fetch\nskills: zig-*\nmemory: pinned\nsteps: 8\n---\nOld.\n", &diag);
    const new = try parse(a, "researcher", "---\nname: researcher\ndescription: Research across sources.\nmodel: claude-sonnet\ntools: search, fetch, shell, github/*\nskills: zig-build\nsteps: 50\n---\nNew.\n", &diag);
    const c = try compare(a, old, new, .{});
    const widens = try std.mem.join(a, "\n", c.widens);
    const other = try std.mem.join(a, "\n", c.other);
    for ([_][]const u8{
        "tools: search, fetch → search, fetch, shell, github/* (adds shell, github/*)",
        "model: claude-haiku → claude-sonnet",
        "memory: pinned → shared",
        "steps: 8 → 50",
    }) |want| {
        if (std.mem.indexOf(u8, widens, want) == null) std.debug.print("widens has no \"{s}\":\n{s}\n", .{ want, widens });
        try t.expect(std.mem.indexOf(u8, widens, want) != null);
    }
    for ([_][]const u8{ "description: Research. → Research across sources.", "skills: zig-* → zig-build", "instructions: changed" }) |want| {
        if (std.mem.indexOf(u8, other, want) == null) std.debug.print("other has no \"{s}\":\n{s}\n", .{ want, other });
        try t.expect(std.mem.indexOf(u8, other, want) != null);
    }
    const text = try readingText(a, old, c);
    const w = std.mem.indexOf(u8, text, "Widens:\n- ").?;
    try t.expect(w < std.mem.indexOf(u8, text, "Other changes:\n- ").?);
    try t.expect(std.mem.indexOf(u8, text, "- steps: 8 → 50") != null);
    // a change that only narrows has nothing under Widens
    const narrow = try parse(a, "researcher", "---\nname: researcher\ndescription: Research.\nmodel: claude-haiku\ntools: search\nskills: zig-*\nmemory: pinned\nsteps: 4\n---\nOld.\n", &diag);
    const c2 = try compare(a, old, narrow, .{});
    try t.expectEqual(0, c2.widens.len);
    try t.expect(std.mem.indexOf(u8, try readingText(a, old, c2), "Widens:") == null);
    // unset limits are the settings': 50 steps is over [limits]' 20, 5 under both
    const plain = try parse(a, "p", "---\nname: p\ndescription: P.\n---\n", &diag);
    const more = try parse(a, "p", "---\nname: p\ndescription: P.\nsteps: 50\ntokens: 1000000\n---\n", &diag);
    const less = try parse(a, "p", "---\nname: p\ndescription: P.\nsteps: 5\n---\n", &diag);
    const c3 = try compare(a, plain, more, .{});
    try t.expectEqual(2, c3.widens.len);
    try t.expectEqual(0, (try compare(a, plain, less, .{})).widens.len);
    // a new definition: what it may use
    const c4 = try compare(a, null, more, .{});
    const t4 = try readingText(a, null, c4);
    try t.expect(std.mem.indexOf(u8, t4, "It may use:\n") != null);
    try t.expect(std.mem.indexOf(u8, t4, "- tools: search, fetch, browse, read_file, recall, skill") != null);
    try t.expect(std.mem.indexOf(u8, t4, "- steps: 50") != null);
}

test "the_saved_line_is_harnesss" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("---\nname: x\ndescription: X.\nsaved: agent:main 2026-11-22T14:02:11Z\n---\nBody\n---\nmore\n", try withSaved(a, "---\nname: x\ndescription: X.\n---\nBody\n---\nmore\n", "agent:main 2026-11-22T14:02:11Z"));
    // one the model wrote is replaced, wherever it was
    try t.expectEqualStrings("---\r\nname: x\r\ndescription: X.\r\nsaved: agent:x 2026-11-22T15:00:00Z\n---\r\nB\r\n", try withSaved(a, "---\r\nname: x\r\nsaved: owner, honest\r\ndescription: X.\r\n---\r\nB\r\n", "agent:x 2026-11-22T15:00:00Z"));
    // no header: as it was (the parser refuses it)
    try t.expectEqualStrings("no header", try withSaved(a, "no header", "v"));
}

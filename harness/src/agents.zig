//! Agent definitions: `agents/NAME.md`, a header like a skill's (between
//! `---` lines) and the instructions as the body. An agent is a file, a
//! run one execution of it. Built in: `main` (the agent) and `helper`
//! (what `delegate` starts); a file of the same name replaces one, so
//! without `agents/` harness is as before.
const std = @import("std");
const skills = @import("skills.zig");
const gate = @import("gate.zig");
const rules = @import("rules.zig");
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
    /// An omnigate route; "": `[model] model`, or `worker_model` when delegated.
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
                if (v.len == 0 or v.len > 128 or std.mem.indexOfAny(u8, v, " \t") != null or hasControl(v)) return fail(diag, f.line, "model is an omnigate route's name");
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

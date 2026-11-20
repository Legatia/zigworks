//! The one place every tool call is decided: hard limits no rule can lift,
//! then the owner's rules, grants with an expiry, and each tool's default.
const std = @import("std");
const rules = @import("rules.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const Tool = enum {
    shell,
    read_file,
    write_file,
    fetch,
    search,
    recall,
    remember,
    /// A page rendered by a headless browser; the same limits as fetch.
    browse,
    /// Work handed to helpers; each helper's own calls pass the gate.
    delegate,
    skill,
    skill_save,
    /// A tool of an MCP server; the argument is "server/tool {input}".
    mcp,
    /// An MCP tool listed as moving money: asked every time, never granted.
    money,

    pub fn default(tool: Tool) rules.Action {
        return switch (tool) {
            .shell, .fetch, .browse, .skill_save, .mcp, .money => .ask,
            else => .allow,
        };
    }

    pub fn fromName(name: []const u8) ?Tool {
        return std.meta.stringToEnum(Tool, name);
    }
};

pub const Decision = struct {
    action: rules.Action,
    why: []const u8,
};

pub const Ctx = struct {
    /// No one is there to answer: `ask` becomes `deny`.
    scheduled: bool = false,
    /// A feed or search the owner listed in briefs.ini.
    brief_source: bool = false,
    /// The owner switched on money calls in scheduled runs ([money]
    /// scheduled = on); the caps were checked before the gate.
    money_unattended: bool = false,
};

/// What a grant covers: the exact argument, or for `fetch` the URL's host.
pub fn grantKey(tool: Tool, arg: []const u8) []const u8 {
    return switch (tool) {
        .fetch, .browse => urlHost(arg) orelse arg,
        // the tool, whatever its input
        .mcp, .money => arg[0 .. std.mem.indexOfScalar(u8, arg, ' ') orelse arg.len],
        else => arg,
    };
}

/// "https://Host:8080/x" → "Host:8080"; null if not an http(s) URL.
pub fn urlHost(url: []const u8) ?[]const u8 {
    const rest = if (std.ascii.startsWithIgnoreCase(url, "https://"))
        url[8..]
    else if (std.ascii.startsWithIgnoreCase(url, "http://"))
        url[7..]
    else
        return null;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

pub const Grants = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Grant) = .empty,

    pub const Grant = struct { tool: Tool, key: []u8, expires_s: i64 };

    pub fn init(gpa: std.mem.Allocator) Grants {
        return .{ .gpa = gpa };
    }

    pub fn deinit(g: *Grants) void {
        for (g.items.items) |it| g.gpa.free(it.key);
        g.items.deinit(g.gpa);
    }

    pub fn add(g: *Grants, tool: Tool, key: []const u8, expires_s: i64) !void {
        for (g.items.items) |*it| {
            if (it.tool == tool and std.ascii.eqlIgnoreCase(it.key, key)) {
                it.expires_s = expires_s;
                return;
            }
        }
        const k = try g.gpa.dupe(u8, key);
        errdefer g.gpa.free(k);
        try g.items.append(g.gpa, .{ .tool = tool, .key = k, .expires_s = expires_s });
    }

    pub fn has(g: *const Grants, tool: Tool, key: []const u8, now_s: i64) bool {
        for (g.items.items) |it| {
            if (it.tool == tool and it.expires_s > now_s and std.ascii.eqlIgnoreCase(it.key, key)) return true;
        }
        return false;
    }

    /// One grant per line: tool, expiry, key, separated by tabs.
    pub fn load(g: *Grants, io: Io, path: []const u8, now_s: i64) !void {
        const text = Io.Dir.cwd().readFileAlloc(io, path, g.gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer g.gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            var parts = std.mem.splitScalar(u8, line, '\t');
            const tool = Tool.fromName(parts.next() orelse continue) orelse continue;
            const exp = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
            const key = parts.rest();
            if (key.len == 0 or exp <= now_s) continue;
            try g.add(tool, key, exp);
        }
    }

    pub fn save(g: *const Grants, io: Io, path: []const u8, now_s: i64) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(g.gpa);
        for (g.items.items) |it| {
            if (it.expires_s <= now_s) continue;
            try out.print(g.gpa, "{s}\t{d}\t{s}\n", .{ @tagName(it.tool), it.expires_s, it.key });
        }
        var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = util.private_file });
        defer f.close(io);
        try f.writeStreamingAll(io, out.items);
    }
};

pub const Gate = struct {
    io: Io,
    rules: []const rules.Rule,
    grants: *Grants,
    /// The workspace's real path.
    workspace: []const u8,

    pub fn decide(g: *const Gate, arena: std.mem.Allocator, tool: Tool, arg: []const u8, now_s: i64, ctx: Ctx) Decision {
        // hard limits first: no rule, grant or listing lifts these
        switch (tool) {
            .fetch, .browse => if (urlHost(arg) == null) return .{ .action = .deny, .why = "only http and https addresses can be fetched" },
            .read_file, .write_file => {
                _ = confine(arena, g.io, g.workspace, arg) catch return .{ .action = .deny, .why = "outside the workspace" };
            },
            else => {},
        }
        if (ctx.brief_source) return .{ .action = .allow, .why = "listed in briefs.ini" };
        const name = @tagName(tool);
        for (g.rules) |r| {
            if (r.action == .deny and std.mem.eql(u8, r.tool, name) and rules.glob(r.pattern, arg))
                return .{ .action = .deny, .why = std.fmt.allocPrint(arena, "rule on line {d}", .{r.line}) catch "rule" };
        }
        if (tool == .money) {
            // no grant or allow rule lifts this: the owner is asked every time
            if (!ctx.scheduled) return .{ .action = .ask, .why = "money is asked every time" };
            if (ctx.money_unattended) return .{ .action = .allow, .why = "money in scheduled runs is switched on, within the caps" };
            return .{ .action = .deny, .why = "money is not moved in scheduled runs" };
        }
        if (g.grants.has(tool, grantKey(tool, arg), now_s)) return .{ .action = .allow, .why = "granted for 24 hours" };
        var d: Decision = .{ .action = tool.default(), .why = "default for this tool" };
        for (g.rules) |r| {
            if (r.action != .deny and std.mem.eql(u8, r.tool, name) and rules.glob(r.pattern, arg)) {
                d = .{ .action = r.action, .why = std.fmt.allocPrint(arena, "rule on line {d}", .{r.line}) catch "rule" };
                break;
            }
        }
        if (d.action == .ask and ctx.scheduled) return .{ .action = .deny, .why = "no one to ask in a scheduled run" };
        return d;
    }
};

/// The real path of `path` (relative to the workspace, or absolute), or
/// error.OutsideWorkspace if it is not inside `workspace` (a real path) —
/// lexically or after following symlinks of the parts that exist.
pub fn confine(arena: std.mem.Allocator, io: Io, workspace: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.OutsideWorkspace;
    const joined = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(arena, &.{ workspace, path });
    const resolved = try std.fs.path.resolve(arena, &.{joined});
    if (!inside(workspace, resolved)) return error.OutsideWorkspace;
    // the deepest part that exists, with symlinks followed, must be inside too
    var probe: []const u8 = resolved;
    while (true) {
        if (Io.Dir.cwd().realPathFileAlloc(io, probe, arena)) |real| {
            if (!inside(workspace, real)) return error.OutsideWorkspace;
            break;
        } else |e| switch (e) {
            error.FileNotFound, error.NotDir => probe = std.fs.path.dirname(probe) orelse return error.OutsideWorkspace,
            else => return error.OutsideWorkspace,
        }
    }
    return resolved;
}

fn inside(root: []const u8, p: []const u8) bool {
    if (!std.mem.startsWith(u8, p, root)) return false;
    return p.len == root.len or p[root.len] == std.fs.path.sep;
}

const t = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    grants: Grants,
    gate: Gate,

    fn init(f: *Fixture, rules_text: []const u8) !void {
        f.arena = .init(t.allocator);
        f.tmp = t.tmpDir(.{});
        f.grants = .init(t.allocator);
        const a = f.arena.allocator();
        try f.tmp.dir.createDirPath(t.io, "ws");
        const ws = try f.tmp.dir.realPathFileAlloc(t.io, "ws", a);
        f.gate = .{ .io = t.io, .rules = try rules.parse(a, rules_text), .grants = &f.grants, .workspace = ws };
    }

    fn deinit(f: *Fixture) void {
        f.grants.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn act(f: *Fixture, tool: Tool, arg: []const u8, ctx: Ctx) rules.Action {
        return f.gate.decide(f.arena.allocator(), tool, arg, 1000, ctx).action;
    }
};

test "deny_wins_over_earlier_ask" {
    var f: Fixture = undefined;
    try f.init("ask shell *\ndeny shell rm -rf *\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.shell, "rm -rf /", .{}));
    try t.expectEqual(.ask, f.act(.shell, "ls", .{}));
    // a grant does not lift a deny
    try f.grants.add(.shell, "rm -rf /", 5000);
    try t.expectEqual(.deny, f.act(.shell, "rm -rf /", .{}));
}

test "first_allow_or_ask_decides" {
    var f: Fixture = undefined;
    try f.init("allow shell git status\nask shell git *\nallow shell git *\n");
    defer f.deinit();
    try t.expectEqual(.allow, f.act(.shell, "git status", .{}));
    try t.expectEqual(.ask, f.act(.shell, "git push", .{}));
}

test "tool_default_applies_without_rule" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try t.expectEqual(.ask, f.act(.shell, "ls", .{}));
    try t.expectEqual(.ask, f.act(.fetch, "https://example.com/", .{}));
    try t.expectEqual(.allow, f.act(.search, "zig", .{}));
    try t.expectEqual(.allow, f.act(.read_file, "notes.txt", .{}));
    try t.expectEqual(.allow, f.act(.remember, "x", .{}));
}

test "grant_allows_until_expiry" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try f.grants.add(.fetch, grantKey(.fetch, "https://news.example.com/a"), 2000);
    try t.expectEqual(.allow, f.act(.fetch, "https://NEWS.example.com/other?x", .{}));
    try t.expectEqual(.ask, f.act(.fetch, "https://example.com/a", .{}));
    try t.expectEqual(.ask, f.gate.decide(f.arena.allocator(), .fetch, "https://news.example.com/a", 2000, .{}).action);
    // saved and loaded, expired ones dropped
    try f.grants.add(.shell, "ls -l", 1500);
    const path = try std.fs.path.join(f.arena.allocator(), &.{ f.gate.workspace, "grants" });
    try f.grants.save(t.io, path, 1000);
    var g2: Grants = .init(t.allocator);
    defer g2.deinit();
    try g2.load(t.io, path, 1600);
    try t.expect(g2.has(.fetch, "news.example.com", 1600));
    try t.expect(!g2.has(.shell, "ls -l", 1600));
}

test "scheduled_run_turns_ask_into_deny" {
    var f: Fixture = undefined;
    try f.init("allow shell date\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.shell, "ls", .{ .scheduled = true }));
    try t.expectEqual(.allow, f.act(.shell, "date", .{ .scheduled = true }));
}

test "listed_brief_source_is_allowed" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try t.expectEqual(.allow, f.act(.fetch, "https://feeds.example.com/rss", .{ .scheduled = true, .brief_source = true }));
    // but not past the hard limits
    try t.expectEqual(.deny, f.act(.fetch, "file:///etc/passwd", .{ .brief_source = true }));
}

test "paths_outside_workspace_are_refused" {
    var f: Fixture = undefined;
    try f.init("allow read_file *\nallow write_file *\n");
    defer f.deinit();
    try t.expectEqual(.allow, f.act(.write_file, "notes/today.md", .{}));
    try t.expectEqual(.deny, f.act(.read_file, "../config.ini", .{}));
    try t.expectEqual(.deny, f.act(.read_file, "/etc/passwd", .{}));
    try t.expectEqual(.deny, f.act(.write_file, "a/../../x", .{}));
    try t.expectEqual(.deny, f.act(.read_file, "", .{}));
    // a symlink inside the workspace that points out of it
    if (@import("builtin").os.tag != .windows) {
        try f.tmp.dir.symLink(t.io, "..", "ws/out", .{ .is_directory = true });
        try t.expectEqual(.deny, f.act(.read_file, "out/secret", .{}));
        try t.expectEqual(.deny, f.act(.write_file, "out/new.txt", .{}));
    }
}

test "fetch_refuses_non_http_schemes" {
    var f: Fixture = undefined;
    try f.init("allow fetch *\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.fetch, "file:///etc/passwd", .{}));
    try t.expectEqual(.deny, f.act(.fetch, "ftp://x/y", .{}));
    try t.expectEqual(.deny, f.act(.fetch, "https:///nohost", .{}));
    try t.expectEqual(.allow, f.act(.fetch, "http://example.com", .{}));
}

test "new_tool_kinds_have_their_defaults" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try t.expectEqual(.ask, f.act(.browse, "https://x.org/a", .{}));
    try t.expectEqual(.deny, f.act(.browse, "file:///etc/passwd", .{}));
    try t.expectEqual(.allow, f.act(.delegate, "2 tasks", .{}));
    try t.expectEqual(.allow, f.act(.skill, "weekly-report", .{}));
    try t.expectEqual(.ask, f.act(.skill_save, "weekly-report", .{}));
    try t.expectEqual(.ask, f.act(.mcp, "github/list_issues {}", .{}));
    try t.expectEqual(.ask, f.act(.money, "broker/place_order {}", .{}));
}

test "mcp_grant_covers_the_tool_with_any_input" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try t.expectEqualStrings("github/list_issues", grantKey(.mcp, "github/list_issues {\"repo\":\"a\"}"));
    try f.grants.add(.mcp, "github/list_issues", 5000);
    try t.expectEqual(.allow, f.act(.mcp, "github/list_issues {\"repo\":\"b\"}", .{}));
    try t.expectEqual(.ask, f.act(.mcp, "github/create_issue {}", .{}));
}

test "money_ignores_grants_and_allow_rules_and_is_refused_unattended" {
    var f: Fixture = undefined;
    try f.init("allow money *\n");
    defer f.deinit();
    try f.grants.add(.money, "broker/place_order", 5000);
    try t.expectEqual(.ask, f.act(.money, "broker/place_order {}", .{}));
    try t.expectEqual(.deny, f.act(.money, "broker/place_order {}", .{ .scheduled = true }));
    try t.expectEqual(.allow, f.act(.money, "broker/place_order {}", .{ .scheduled = true, .money_unattended = true }));
}

test "money_deny_rule_still_applies" {
    var f: Fixture = undefined;
    try f.init("deny money broker/withdraw *\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.money, "broker/withdraw {}", .{}));
    try t.expectEqual(.deny, f.act(.money, "broker/withdraw {}", .{ .scheduled = true, .money_unattended = true }));
}

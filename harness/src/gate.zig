//! The one place every tool call is decided: hard limits no rule can lift,
//! then the owner's rules, grants with an expiry, and each tool's default.
const std = @import("std");
const builtin = @import("builtin");
const rules = @import("rules.zig");
const util = @import("util.zig");
const url = @import("url.zig");
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
    /// The interactive browser; the argument is the page's host.
    web,
    /// A login's values or passkeys used in the browser: "NAME HOST".
    login,

    pub fn default(tool: Tool) rules.Action {
        return switch (tool) {
            .shell, .fetch, .browse, .skill_save, .mcp, .money, .web, .login => .ask,
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
    /// What the rules and grants were matched against: the argument, or
    /// for files the path inside the workspace (see `Confined.rel`).
    subject: []const u8 = "",
};

/// Volumes on macOS and Windows ignore case by default, so file rules and
/// grants do too there: `Private/k` is the file `private/k`.
pub const fold_paths = builtin.os.tag == .macos or builtin.os.tag == .windows;

pub const Ctx = struct {
    /// No one is there to answer: `ask` becomes `deny`.
    scheduled: bool = false,
    /// A feed or search the owner listed in briefs.ini.
    brief_source: bool = false,
    /// The owner switched on money calls in scheduled runs ([money]
    /// scheduled = on); the caps were checked before the gate.
    money_unattended: bool = false,
};

/// What a grant covers: the exact argument, or for `fetch` and `browse`
/// the address's host (with its port when not the scheme's own). `arg`:
/// the decision's subject, for an address the form `url.parse` gives it.
pub fn grantKey(tool: Tool, arg: []const u8) []const u8 {
    return switch (tool) {
        .fetch, .browse => blk: {
            const at = std.mem.indexOf(u8, arg, "://") orelse break :blk arg;
            const rest = arg[at + 3 ..];
            break :blk rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
        },
        // the tool, whatever its input
        .mcp, .money => arg[0 .. std.mem.indexOfScalar(u8, arg, ' ') orelse arg.len],
        else => arg,
    };
}

/// Whether two grant keys are the same: exactly, except that a host is
/// the same in any case, and so is a file's path where volumes ignore case.
fn sameKey(tool: Tool, a: []const u8, b: []const u8) bool {
    return switch (tool) {
        .fetch, .browse, .web => std.ascii.eqlIgnoreCase(a, b),
        // "NAME HOST"
        .login => {
            const sa = std.mem.indexOfScalar(u8, a, ' ') orelse return std.mem.eql(u8, a, b);
            const sb = std.mem.indexOfScalar(u8, b, ' ') orelse return false;
            return std.mem.eql(u8, a[0..sa], b[0..sb]) and std.ascii.eqlIgnoreCase(a[sa + 1 ..], b[sb + 1 ..]);
        },
        .read_file, .write_file => if (fold_paths) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b),
        else => std.mem.eql(u8, a, b),
    };
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
            if (it.tool == tool and sameKey(tool, it.key, key)) {
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
            if (it.tool == tool and it.expires_s > now_s and sameKey(tool, it.key, key)) return true;
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
        var d = g.decideRaw(arena, tool, arg, now_s, ctx);
        if (d.subject.len == 0) d.subject = arg;
        return d;
    }

    fn decideRaw(g: *const Gate, arena: std.mem.Allocator, tool: Tool, arg: []const u8, now_s: i64, ctx: Ctx) Decision {
        // what rules and grants see; for files, `given` is the path before
        // symlinks are followed, which deny rules see too
        var subject = arg;
        var given: []const u8 = "";
        // hard limits first: no rule, grant or listing lifts these
        switch (tool) {
            // the address as fetch and the browser will use it, so the
            // rules and grants see the host that is reached
            .fetch, .browse => {
                const u = url.parse(arena, arg) catch |e| return .{ .action = .deny, .why = if (e == error.NotWeb) "only http and https addresses can be fetched" else url.why(e) };
                subject = u.href;
                given = arg;
            },
            .read_file, .write_file => {
                const cf = confined(arena, g.io, g.workspace, arg) catch return .{ .action = .deny, .why = "outside the workspace" };
                subject = cf.rel;
                given = cf.given;
                if (tool == .write_file and cf.link) return .{ .action = .deny, .why = "a symbolic link: files are not written through one", .subject = subject };
            },
            .web => subject = (url.hostPort(arena, arg) catch return .{ .action = .deny, .why = "not a host name" }).text,
            else => {},
        }
        const name = @tagName(tool);
        for (g.rules) |r| {
            // a deny on a server's MCP tools covers its money tools too
            const same = std.mem.eql(u8, r.tool, name) or (tool == .money and std.mem.eql(u8, r.tool, "mcp"));
            if (r.action == .deny and same and (g.matches(arena, tool, r.pattern, subject) or (given.len > 0 and g.matches(arena, tool, r.pattern, given))))
                return .{ .action = .deny, .why = std.fmt.allocPrint(arena, "rule on line {d}", .{r.line}) catch "rule", .subject = subject };
        }
        // listing a source in briefs.ini allows it, as an allow rule would
        if (ctx.brief_source) return .{ .action = .allow, .why = "listed in briefs.ini", .subject = subject };
        if (tool == .money) {
            // no grant or allow rule lifts this: the owner is asked every time
            if (!ctx.scheduled) return .{ .action = .ask, .why = "money is asked every time", .subject = subject };
            if (ctx.money_unattended) return .{ .action = .allow, .why = "money in scheduled runs is switched on, within the caps", .subject = subject };
            return .{ .action = .deny, .why = "money is not moved in scheduled runs", .subject = subject };
        }
        if (g.grants.has(tool, grantKey(tool, subject), now_s)) return .{ .action = .allow, .why = "granted for 24 hours", .subject = subject };
        var d: Decision = .{ .action = tool.default(), .why = "default for this tool", .subject = subject };
        // programs read these as their settings (.git/config, .npmrc, .env):
        // a file written there can make the next command run something else
        if (tool == .write_file and dotPart(subject)) d = .{ .action = .ask, .why = "a name starting with \".\" asks: programs read those as settings", .subject = subject };
        for (g.rules) |r| {
            if (r.action != .deny and std.mem.eql(u8, r.tool, name) and g.matches(arena, tool, r.pattern, subject)) {
                d = .{ .action = r.action, .why = std.fmt.allocPrint(arena, "rule on line {d}", .{r.line}) catch "rule", .subject = subject };
                break;
            }
        }
        if (d.action == .ask and ctx.scheduled) return .{ .action = .deny, .why = "no one to ask in a scheduled run", .subject = subject };
        return d;
    }

    /// Whether a rule's pattern matches; file patterns are read like file
    /// arguments: a leading `./` or the workspace's own path is dropped,
    /// `\` is a separator on Windows, case is ignored where volumes ignore it.
    fn matches(g: *const Gate, arena: std.mem.Allocator, tool: Tool, pattern: []const u8, s: []const u8) bool {
        switch (tool) {
            .read_file, .write_file => {},
            else => return rules.glob(pattern, s),
        }
        var p = slashes(arena, pattern);
        const ws = slashes(arena, g.workspace);
        if (p.len > ws.len and std.mem.startsWith(u8, p, ws) and p[ws.len] == '/') p = p[ws.len + 1 ..];
        while (std.mem.startsWith(u8, p, "./")) p = std.mem.trimStart(u8, p[2..], "/");
        return rules.globCase(p, s, fold_paths);
    }
};

/// Whether a part of `rel` (with `/` between the parts) starts with `.`.
fn dotPart(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| if (part.len > 0 and part[0] == '.') return true;
    return false;
}

/// `/` for each separator (on Windows `\\` is one too).
fn slashes(arena: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.fs.path.sep == '/' or std.mem.indexOfScalar(u8, p, '\\') == null) return p;
    const out = arena.dupe(u8, p) catch return p;
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// The path to open for `path` (relative to the workspace, or absolute),
/// or error.OutsideWorkspace if it is not inside `workspace` (a real path)
/// — lexically or after following symlinks of the parts that exist.
pub fn confine(arena: std.mem.Allocator, io: Io, workspace: []const u8, path: []const u8) ![]const u8 {
    return (try confined(arena, io, workspace, path)).path;
}

pub const Confined = struct {
    /// What to open: absolute, `.` and `..` resolved.
    path: []const u8,
    /// What file rules and grants see: the path inside the workspace with
    /// the symlinks of the parts that exist followed (so their names as
    /// they are on disk), `/` between the parts; "" for the workspace.
    rel: []const u8,
    /// The same before symlinks are followed.
    given: []const u8,
    /// The last part is a symlink (to something inside the workspace).
    link: bool,
};

pub fn confined(arena: std.mem.Allocator, io: Io, workspace: []const u8, path: []const u8) !Confined {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.OutsideWorkspace;
    const joined = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(arena, &.{ workspace, path });
    const resolved = try std.fs.path.resolve(arena, &.{joined});
    if (!inside(workspace, resolved)) return error.OutsideWorkspace;
    // the deepest part that exists, with symlinks followed, must be inside too
    var probe: []const u8 = resolved;
    const real = while (true) {
        if (Io.Dir.cwd().realPathFileAlloc(io, probe, arena)) |real| {
            if (!inside(workspace, real)) return error.OutsideWorkspace;
            break real;
        } else |e| switch (e) {
            error.FileNotFound, error.NotDir => {
                // a symlink to something missing: where a write through it
                // would land can't be checked
                if (isLink(io, probe)) return error.OutsideWorkspace;
                probe = std.fs.path.dirname(probe) orelse return error.OutsideWorkspace;
            },
            else => return error.OutsideWorkspace,
        }
    };
    // what exists as it really is, then the parts not made yet
    const full = try std.mem.concat(arena, u8, &.{ real, resolved[probe.len..] });
    return .{ .path = resolved, .rel = relTo(arena, workspace, full), .given = relTo(arena, workspace, resolved), .link = isLink(io, resolved) };
}

fn isLink(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// `p` (inside `root`) relative to it, with `/` between the parts.
fn relTo(arena: std.mem.Allocator, root: []const u8, p: []const u8) []const u8 {
    return slashes(arena, std.mem.trimStart(u8, p[root.len..], "/\\"));
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

test "grants_compare_exactly_except_hosts" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try f.grants.add(.shell, "rm -rf build", 5000);
    try t.expectEqual(.allow, f.act(.shell, "rm -rf build", .{}));
    try t.expectEqual(.ask, f.act(.shell, "rm -rf BUILD", .{}));
    try f.grants.add(.mcp, "github/list_issues", 5000);
    try t.expectEqual(.ask, f.act(.mcp, "GitHub/List_Issues {}", .{}));
    // a host is the same host in any case; a login's name is not
    try f.grants.add(.web, "github.com", 5000);
    try t.expectEqual(.allow, f.act(.web, "GitHub.COM", .{}));
    try f.grants.add(.login, "bot github.com", 5000);
    try t.expectEqual(.allow, f.act(.login, "bot GitHub.com", .{}));
    try t.expectEqual(.ask, f.act(.login, "BOT github.com", .{}));
    // a file's path in any case where the volume ignores case
    try f.grants.add(.write_file, ".npmrc", 5000);
    try t.expectEqual(if (fold_paths) .allow else .ask, f.act(.write_file, ".NPMRC", .{}));
    // the same command in another case is a grant of its own, not a renewal
    try f.grants.add(.shell, "rm -rf BUILD", 6000);
    try t.expectEqual(5000, f.grants.items.items[0].expires_s);
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

test "a_deny_rule_applies_to_brief_sources_too" {
    var f: Fixture = undefined;
    try f.init("deny fetch https://feeds.example.com/*\ndeny search *passwords*\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.fetch, "https://feeds.example.com/rss", .{ .scheduled = true, .brief_source = true }));
    try t.expectEqual(.deny, f.act(.search, "leaked passwords list", .{ .scheduled = true, .brief_source = true }));
    try t.expectEqual(.allow, f.act(.fetch, "https://other.example.com/rss", .{ .scheduled = true, .brief_source = true }));
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

test "file_rules_see_the_path_inside_the_workspace" {
    var f: Fixture = undefined;
    try f.init("deny read_file private/*\nallow write_file notes/*\nask write_file *\n");
    defer f.deinit();
    const a = f.arena.allocator();
    try f.tmp.dir.createDirPath(t.io, "ws/private");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/private/k", .data = "key" });
    for ([_][]const u8{ "private/k", "./private/k", "a/../private/k", ".//private//k", "private/../private/./k" }) |p|
        try t.expectEqual(.deny, f.act(.read_file, p, .{}));
    try t.expectEqual(.deny, f.act(.read_file, try std.fs.path.join(a, &.{ f.gate.workspace, "private", "k" }), .{}));
    if (fold_paths) try t.expectEqual(.deny, f.act(.read_file, "PRIVATE/K", .{}));
    if (builtin.os.tag == .windows) try t.expectEqual(.deny, f.act(.read_file, "private\\k", .{}));
    // a symlink to the file is the file
    if (builtin.os.tag != .windows) {
        try f.tmp.dir.symLink(t.io, "private/k", "ws/k-link", .{});
        try t.expectEqual(.deny, f.act(.read_file, "k-link", .{}));
    }
    try t.expectEqual(.allow, f.act(.read_file, "notes/k", .{}));
    // allow and ask rules and grants see the same form
    try t.expectEqual(.ask, f.act(.write_file, "./notes/../todo.md", .{}));
    try t.expectEqual(.allow, f.act(.write_file, "./notes/a.md", .{}));
    try f.grants.add(.write_file, "todo.md", 5000);
    try t.expectEqual(.allow, f.act(.write_file, "./todo.md", .{}));
    // rules written with ./ or the workspace's own path, and in another case where case is ignored
    f.gate.rules = try rules.parse(a, try std.fmt.allocPrint(a, "deny write_file ./drafts/*\ndeny write_file {s}/old/*\ndeny write_file Plans/*\n", .{f.gate.workspace}));
    try t.expectEqual(.deny, f.act(.write_file, "drafts/x.md", .{}));
    try t.expectEqual(.deny, f.act(.write_file, "old/x.md", .{}));
    try t.expectEqual(if (fold_paths) .deny else .allow, f.act(.write_file, "plans/x.md", .{}));
    // the decision says which form it matched
    try t.expectEqualStrings("drafts/y.md", f.gate.decide(a, .write_file, "a/../drafts/y.md", 1000, .{}).subject);
}

test "a_symlink_whose_target_is_missing_is_refused_and_written_files_are_never_links" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    // a link out of the workspace to nothing yet: writing it would make the file outside
    try f.tmp.dir.symLink(t.io, "../outside.txt", "ws/dangle", .{});
    try f.tmp.dir.symLink(t.io, "../nowhere", "ws/dangle-dir", .{ .is_directory = true });
    try t.expectEqual(.deny, f.act(.write_file, "dangle", .{}));
    try t.expectEqual(.deny, f.act(.write_file, "dangle-dir/x.txt", .{}));
    try t.expectEqual(.deny, f.act(.read_file, "dangle", .{}));
    // a link to a file inside may be read, but a write would go through it
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/notes.txt", .data = "x" });
    try f.tmp.dir.symLink(t.io, "notes.txt", "ws/in-link", .{});
    try t.expectEqual(.allow, f.act(.read_file, "in-link", .{}));
    try t.expectEqual(.deny, f.act(.write_file, "in-link", .{}));
    try t.expectEqual(.allow, f.act(.write_file, "notes.txt", .{}));
}

test "writing_a_path_with_a_part_starting_with_a_dot_asks" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    for ([_][]const u8{ ".npmrc", ".git/config", "src/.env", "./a/../.git/hooks/pre-commit", "pkg/.venv/bin/x" }) |p|
        try t.expectEqual(.ask, f.act(.write_file, p, .{}));
    try t.expectEqual(.allow, f.act(.write_file, "notes/a.md", .{}));
    try t.expectEqual(.allow, f.act(.write_file, "./notes/./b.md", .{}));
    try t.expectEqual(.allow, f.act(.read_file, ".git/config", .{}));
    try t.expectEqual(.deny, f.act(.write_file, ".npmrc", .{ .scheduled = true }));
    // a grant covers that path, and an allow rule lifts it
    try f.grants.add(.write_file, ".npmrc", 5000);
    try t.expectEqual(.allow, f.act(.write_file, "./.npmrc", .{}));
    f.gate.rules = try rules.parse(f.arena.allocator(), "allow write_file .github/*\n");
    try t.expectEqual(.allow, f.act(.write_file, ".github/workflows/ci.yml", .{}));
    // a symlink to a dot folder is that folder
    if (builtin.os.tag != .windows) {
        try f.tmp.dir.createDirPath(t.io, "ws/.git");
        try f.tmp.dir.symLink(t.io, ".git", "ws/g", .{ .is_directory = true });
        try t.expectEqual(.ask, f.act(.write_file, "g/config", .{}));
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

test "an_address_with_a_name_before_the_at_is_refused" {
    var f: Fixture = undefined;
    try f.init("allow fetch *\nallow browse *\n");
    defer f.deinit();
    try f.grants.add(.fetch, "good.com", 5000);
    for ([_]Tool{ .fetch, .browse }) |tool| {
        for ([_][]const u8{ "https://good.com@evil.com/", "https://good.com:pw@evil.com/x", "http://@evil.com/" }) |u| {
            const d = f.gate.decide(f.arena.allocator(), tool, u, 1000, .{});
            try t.expectEqual(.deny, d.action);
            try t.expect(std.mem.indexOf(u8, d.why, "@") != null);
        }
    }
    // an @ after the host is part of the path
    try t.expectEqual(.allow, f.act(.fetch, "https://medium.com/@someone", .{}));
}

test "every_spelling_of_a_host_is_the_same_host" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    try f.grants.add(.fetch, "good.com", 5000);
    for ([_][]const u8{ "HTTPS://Good.COM./x", "https://good.com:443/y", "https://GOOD.com/a/../b" }) |u| try t.expectEqual(.allow, f.act(.fetch, u, .{}));
    try t.expectEqual(.ask, f.act(.fetch, "https://good.com:8443/", .{}));
    try f.grants.add(.browse, "127.0.0.1", 5000);
    for ([_][]const u8{ "http://0x7f.1/", "http://2130706433/", "http://127.1/", "http://0177.0.0.1/", "http://[::ffff:127.0.0.1]/" }) |u| try t.expectEqual(.allow, f.act(.browse, u, .{}));
    // what does not read one way is refused: an international name not in
    // its xn-- form, an IPv4 address of five parts, a backslash, a % in the host
    for ([_][]const u8{ "https://bücher.de/", "http://1.2.3.4.5/", "https://good.com\\@evil.com/", "https://ev%69l.com/" }) |u| try t.expectEqual(.deny, f.act(.fetch, u, .{}));
    // web's hosts the same way
    try f.grants.add(.web, "good.com", 5000);
    try t.expectEqual(.allow, f.act(.web, "Good.COM.", .{}));
    // the decision says the address as it is used
    try t.expectEqualStrings("https://good.com/b", f.gate.decide(a, .fetch, "HTTPS://Good.COM./a/../b", 1000, .{}).subject);
    try t.expectEqualStrings("good.com", f.gate.decide(a, .web, "Good.COM.", 1000, .{}).subject);
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

test "web_and_login_ask_by_default_and_grants_cover_host_and_login" {
    var f: Fixture = undefined;
    try f.init("allow web docs.example.com\n");
    defer f.deinit();
    try t.expectEqual(.ask, f.act(.web, "github.com", .{}));
    try t.expectEqual(.allow, f.act(.web, "docs.example.com", .{}));
    try t.expectEqual(.deny, f.act(.web, "", .{}));
    try t.expectEqual(.deny, f.act(.web, "github.com/x", .{}));
    try t.expectEqual(.ask, f.act(.login, "github-bot github.com", .{}));
    try t.expectEqual(.deny, f.act(.login, "github-bot github.com", .{ .scheduled = true }));
    try t.expectEqual(.deny, f.act(.web, "github.com", .{ .scheduled = true }));
    try t.expectEqualStrings("github.com", grantKey(.web, "github.com"));
    try t.expectEqualStrings("github-bot github.com", grantKey(.login, "github-bot github.com"));
    try f.grants.add(.login, "github-bot github.com", 5000);
    try t.expectEqual(.allow, f.act(.login, "github-bot github.com", .{}));
    try t.expectEqual(.ask, f.act(.login, "github-bot gist.github.com", .{}));
    try t.expectEqual(.ask, f.act(.login, "other github.com", .{}));
    try f.grants.add(.web, "github.com", 5000);
    try t.expectEqual(.allow, f.act(.web, "GitHub.com", .{}));
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

test "deny_mcp_rule_covers_money_tools_of_that_server" {
    var f: Fixture = undefined;
    try f.init("deny mcp broker/*\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.money, "broker/place_order {}", .{}));
}

//! The one place every tool call is decided, in this order: hard limits no
//! rule can lift; roles on folders (folders.ini, final); a deny rule; listed
//! sources, money and setup calls; a grant with an expiry; the first allow
//! or ask rule; the kind's default. Rules and grants are matched with the call's who:
//! its definition, the definitions that delegated it and what started its
//! run. A household member's call (`member:NAME`) and speech in a room of
//! the house (`room:NAME`) have an order of their own (`decideMember`).
const std = @import("std");
const builtin = @import("builtin");
const rules = @import("rules.zig");
const who_mod = @import("who.zig");
pub const Who = who_mod.Who;
const folders_mod = @import("folders.zig");
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
    /// Every earlier turn in the log, searched (long memory); the argument
    /// is the words, or `run N` for a run's steps.
    history,
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
    // The platform's kinds: decided here now, each tool built by its gap.
    /// A post to a conversation (gap 4); the argument is its name. Asked
    /// every time where others read it (`Ctx.shared`), else allowed.
    send,
    /// A question or draft for the owner (gap 5); the argument is the question.
    ask_owner,
    /// A mailbox read (gap 6); the argument is its name.
    mail,
    /// The trigger tool (gap 6): `add NAME` (a setup call), `rm NAME`,
    /// `test NAME`, `list`.
    trigger,
    /// The workflow tool (gap 7): `save NAME` (a setup call), `start NAME`,
    /// `stop NAME#N`, `check`, `list`, `show NAME`.
    workflow,
    /// A new or changed agent definition (gap 1); the argument is its name.
    agent_save,
    /// An app's read (gap 8): `NAME memory`, `NAME inbox` or `NAME log`.
    app_read,
    /// An app copied into the workspace to change (gap 8); the argument is its name.
    app_draft,
    /// An app installed (gap 8); the argument is its name.
    app_save,
    /// An environment saved (gap 2); the argument is its name.
    env_save,
    /// A snapshot of a workspace folder (gap 3); the argument is the folder.
    snapshot,

    /// The kind's default, as the rules file's comment names it: a send
    /// asks where others read it, trigger and workflow for some actions
    /// (see `defaultFor`).
    pub fn default(tool: Tool) rules.Action {
        return switch (tool) {
            .shell, .fetch, .browse, .skill_save, .mcp, .money, .web, .login => .ask,
            .send, .mail, .trigger, .workflow, .agent_save, .app_save, .env_save => .ask,
            else => .allow,
        };
    }

    /// A call that changes what runs without the owner watching: asked
    /// every time, like money; no grant or allow rule lifts it.
    pub fn setup(tool: Tool, arg: []const u8) bool {
        return switch (tool) {
            .agent_save, .app_save, .env_save => true,
            .trigger => std.mem.eql(u8, firstWord(arg), "add"),
            .workflow => std.mem.eql(u8, firstWord(arg), "save"),
            else => false,
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
    /// Whether a question may offer "Allow 24 h": never for money, a setup
    /// call or a post others read, which are asked every time.
    allow_day: bool = true,
    /// Refused by folders.ini: final, nothing is asked, and it is no
    /// approval anyone could give.
    role: bool = false,
    /// Where a shell command starts: a folder inside the workspace, `/`
    /// between parts; "" the workspace.
    dir: []const u8 = "",
};

/// A call's default: the kind's, except that a send to a conversation
/// only the owner reads, a trigger's test and list, and a workflow's
/// check, list and show are allowed.
fn defaultFor(tool: Tool, arg: []const u8, ctx: Ctx) rules.Action {
    return switch (tool) {
        .send => if (ctx.shared) .ask else .allow,
        .trigger => if (oneOf(firstWord(arg), &.{ "test", "list" })) .allow else .ask,
        .workflow => if (oneOf(firstWord(arg), &.{ "check", "list", "show" })) .allow else .ask,
        else => tool.default(),
    };
}

fn firstWord(arg: []const u8) []const u8 {
    return arg[0 .. std.mem.indexOfScalar(u8, arg, ' ') orelse arg.len];
}

fn oneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// Volumes on macOS and Windows ignore case by default, so file rules and
/// grants do too there: `Private/k` is the file `private/k`.
pub const fold_paths = builtin.os.tag == .macos or builtin.os.tag == .windows;

pub const Ctx = struct {
    /// No one is there to answer: `ask` becomes `deny`. Set for runs a
    /// schedule, a trigger or a workflow started (`Who.unattended`).
    scheduled: bool = false,
    /// A source the owner listed: the file that lists it (`briefs.ini`,
    /// `triggers.ini`); a read of it is allowed as an allow rule would.
    listed: ?[]const u8 = null,
    /// The owner switched on money calls in scheduled runs ([money]
    /// scheduled = on); the caps were checked before the gate.
    money_unattended: bool = false,
    /// Who makes the call; null: main, in a run the owner started.
    who: ?Who = null,
    /// Where a shell command runs; `host` is the only one until gap 2.
    env: []const u8 = "host",
    /// A `send` to a conversation others read (gap 4): asked every time.
    shared: bool = false,
    /// Where a shell command starts, as the model gave it ("" the
    /// workspace): confined like a file path, and `run` is checked there.
    dir: []const u8 = "",
    /// A `send` to the run's own conversation (where its message came
    /// from): a household member's run may post there.
    here: bool = false,
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

/// The grants the owner gave with "Allow 24 h", kept in `state/grants`. A
/// file harness writes starts with `file_head`; then a grant a line:
/// `TOOL[@ENV]`, expiry, key, who, separated by tabs, the key with `\`,
/// tab, CR and LF escaped (`\\`, `\t`, `\r`, `\n`). A file without that
/// first line is 0.3's (`TOOL`, expiry, the key to the end of the line) and
/// is read as before: a shell grant there is for host and covers any run.
pub const Grants = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Grant) = .empty,

    pub const Grant = struct {
        tool: Tool,
        key: []u8,
        expires_s: i64,
        /// A shell grant's environment (`host` until gap 2); "" for other
        /// kinds, which run in none.
        env: []const u8 = "",
        /// Who it covers: "" any run (0.3's grants); `agent:NAME` that
        /// definition's own calls; else the runs whose `by` it matches
        /// (`schedule:NAME`, `workflow:NAME` for all of its steps, `app:NAME`).
        who: []const u8 = "",
    };

    /// The first line of a grants file with who and environment.
    pub const file_head = "# harness grants 2: tool[@environment], expiry (Unix seconds), key (with \\ \\t \\r \\n escaped), who (empty: any run); tab-separated\n";

    pub fn init(gpa: std.mem.Allocator) Grants {
        return .{ .gpa = gpa };
    }

    pub fn deinit(g: *Grants) void {
        for (g.items.items) |it| {
            g.gpa.free(it.key);
            g.gpa.free(it.env);
            g.gpa.free(it.who);
        }
        g.items.deinit(g.gpa);
    }

    /// A grant with no who, as 0.3 made them; a shell grant is for host.
    pub fn add(g: *Grants, tool: Tool, key: []const u8, expires_s: i64) !void {
        return g.addFor(tool, "host", key, "", expires_s);
    }

    /// A grant for `who` (see `Grant.who`), for a shell command in `env`.
    /// It renews one for the same tool, environment, who and key.
    pub fn addFor(g: *Grants, tool: Tool, env: []const u8, key: []const u8, who: []const u8, expires_s: i64) !void {
        if (who.len > 0 and !who_mod.isValue(who)) return error.BadWho;
        const e = if (tool != .shell) "" else if (env.len == 0) "host" else env;
        for (g.items.items) |*it| {
            if (it.tool == tool and std.mem.eql(u8, it.env, e) and std.mem.eql(u8, it.who, who) and sameKey(tool, it.key, key)) {
                it.expires_s = expires_s;
                return;
            }
        }
        const k = try g.gpa.dupe(u8, key);
        errdefer g.gpa.free(k);
        const ed = try g.gpa.dupe(u8, e);
        errdefer g.gpa.free(ed);
        const wd = try g.gpa.dupe(u8, who);
        errdefer g.gpa.free(wd);
        try g.items.append(g.gpa, .{ .tool = tool, .key = k, .expires_s = expires_s, .env = ed, .who = wd });
    }

    /// Whether a grant covers this call by main, in a run the owner
    /// started, on host.
    pub fn has(g: *const Grants, tool: Tool, key: []const u8, now_s: i64) bool {
        return g.covers(tool, "host", key, .{}, now_s);
    }

    /// Whether an unexpired grant covers a call: the same tool (for shell,
    /// in the same environment) and key, and a who that is empty, the
    /// call's own definition (not one that delegated it), or matches what
    /// started its run.
    pub fn covers(g: *const Grants, tool: Tool, env: []const u8, key: []const u8, w: Who, now_s: i64) bool {
        for (g.items.items) |it| {
            if (it.tool != tool or it.expires_s <= now_s) continue;
            if (tool == .shell and !std.mem.eql(u8, it.env, env)) continue;
            if (sameKey(tool, it.key, key) and whoCovers(it.who, w)) return true;
        }
        return false;
    }

    /// Removes grant `i` (an index into `items`).
    pub fn remove(g: *Grants, i: usize) void {
        const it = g.items.orderedRemove(i);
        g.gpa.free(it.key);
        g.gpa.free(it.env);
        g.gpa.free(it.who);
    }

    pub fn load(g: *Grants, io: Io, path: []const u8, now_s: i64) !void {
        const text = Io.Dir.cwd().readFileAlloc(io, path, g.gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer g.gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        if (!std.mem.startsWith(u8, text, "#")) {
            // 0.3's: no who, and the key to the end of the line, tabs and all
            while (it.next()) |line| {
                var parts = std.mem.splitScalar(u8, line, '\t');
                const tool = Tool.fromName(parts.next() orelse continue) orelse continue;
                const exp = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
                const key = parts.rest();
                if (key.len == 0 or exp <= now_s) continue;
                try g.add(tool, key, exp);
            }
            return;
        }
        // a line that does not read is left out: it never widens a grant
        while (it.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const head = parts.next() orelse continue;
            const exp_text = parts.next() orelse continue;
            const key_text = parts.next() orelse continue;
            const who = parts.next() orelse continue;
            if (parts.next() != null) continue;
            const at = std.mem.indexOfScalar(u8, head, '@');
            const tool = Tool.fromName(head[0 .. at orelse head.len]) orelse continue;
            const env = if (at) |i| head[i + 1 ..] else "host";
            if (at != null and (tool != .shell or !rules.envName(env))) continue;
            const exp = std.fmt.parseInt(i64, exp_text, 10) catch continue;
            if (exp <= now_s) continue;
            const key = unescape(g.gpa, key_text) catch |e| switch (e) {
                error.BadEscape => continue,
                else => |x| return x,
            };
            defer g.gpa.free(key);
            if (key.len == 0) continue;
            g.addFor(tool, env, key, who, exp) catch |e| switch (e) {
                error.BadWho => continue,
                else => |x| return x,
            };
        }
    }

    pub fn save(g: *const Grants, io: Io, path: []const u8, now_s: i64) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(g.gpa);
        try out.appendSlice(g.gpa, file_head);
        for (g.items.items) |it| {
            if (it.expires_s <= now_s) continue;
            try out.appendSlice(g.gpa, @tagName(it.tool));
            if (it.tool == .shell) try out.print(g.gpa, "@{s}", .{it.env});
            try out.print(g.gpa, "\t{d}\t", .{it.expires_s});
            try escape(&out, g.gpa, it.key);
            try out.print(g.gpa, "\t{s}\n", .{it.who});
        }
        // whole or not at all: a grant cut in half, or a reader that finds
        // the file empty, would lose or change what was granted
        try util.writeReplace(io, path, out.items);
    }
};

/// Whether a grant's who covers a call by `w`.
fn whoCovers(grant_who: []const u8, w: Who) bool {
    if (grant_who.len == 0) return true;
    if (std.mem.startsWith(u8, grant_who, "agent:")) return std.mem.eql(u8, grant_who["agent:".len..], w.agent);
    return who_mod.matchesBy(grant_who, w.by);
}

/// A key as a grants line holds it: `\`, tab, CR and LF escaped, so a key
/// can't end its line or start another grant.
fn escape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8) !void {
    for (key) |c| switch (c) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        else => try out.append(gpa, c),
    };
}

fn unescape(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try out.append(gpa, text[i]);
            continue;
        }
        i += 1;
        if (i == text.len) return error.BadEscape;
        try out.append(gpa, switch (text[i]) {
            '\\' => '\\',
            't' => '\t',
            'r' => '\r',
            'n' => '\n',
            else => return error.BadEscape,
        });
    }
    return out.toOwnedSlice(gpa);
}

pub const Gate = struct {
    io: Io,
    rules: []const rules.Rule,
    grants: *Grants,
    /// The workspace's real path.
    workspace: []const u8,
    /// folders.ini, when it has a section: who may read, write and start
    /// commands in each folder. null: no roles (0.3's decisions).
    folders: ?*const folders_mod.Folders = null,

    pub fn decide(g: *const Gate, arena: std.mem.Allocator, tool: Tool, arg: []const u8, now_s: i64, ctx: Ctx) Decision {
        var dir: []const u8 = "";
        var d = g.decideRaw(arena, tool, arg, now_s, ctx, &dir);
        if (d.subject.len == 0) d.subject = arg;
        // a member, or speech in a room, is never given a day: the owner
        // decides each time
        const member = if (ctx.who) |w| who_mod.isHousehold(w.by) else false;
        d.allow_day = !(tool == .money or tool.setup(arg) or (tool == .send and ctx.shared) or member);
        d.dir = dir;
        return d;
    }

    /// Each section's folder as file rules read a path: inside the
    /// workspace, symbolic links followed; as written where that fails.
    pub fn realFolders(g: *const Gate, arena: std.mem.Allocator, f: *const folders_mod.Folders) ?[]const []const u8 {
        const out = arena.alloc([]const u8, f.sections.len) catch return null;
        for (f.sections, out) |s, *o| {
            o.* = if (s.folder.len == 0) "" else if (confined(arena, g.io, g.workspace, s.folder)) |cf| cf.rel else |_| s.folder;
        }
        return out;
    }

    fn decideRaw(g: *const Gate, arena: std.mem.Allocator, tool: Tool, arg: []const u8, now_s: i64, ctx: Ctx, dir: *[]const u8) Decision {
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
            // where the command starts, read like a file path
            .shell => if (ctx.dir.len > 0) {
                dir.* = (confined(arena, g.io, g.workspace, ctx.dir) catch return .{ .action = .deny, .why = "dir is outside the workspace" }).rel;
            },
            else => {},
        }
        const w = ctx.who orelse Who{};
        // roles on folders: a refusal is final, nothing is asked
        if (g.folders) |f| {
            const need: ?struct { rel: []const u8, access: folders_mod.Access } = switch (tool) {
                .read_file => .{ .rel = subject, .access = .read },
                .write_file => .{ .rel = subject, .access = .write },
                .shell => .{ .rel = dir.*, .access = .run },
                else => null,
            };
            if (need) |n| if (folders_mod.allows(f.*, arena, g.realFolders(arena, f), n.rel, n.access, w)) |why|
                return .{ .action = .deny, .why = why, .subject = subject, .role = true };
        }
        if (who_mod.isHousehold(w.by)) return g.decideMember(arena, tool, subject, given, ctx, w);
        const name = @tagName(tool);
        // a deny in the shared part, or in a section for the call's
        // definition, one that delegated it, or what started its run
        for (g.rules) |r| {
            if (r.action != .deny or !envFits(r, tool, ctx.env)) continue;
            // a deny on a server's MCP tools covers its money tools too
            const same = std.mem.eql(u8, r.tool, name) or (tool == .money and std.mem.eql(u8, r.tool, "mcp"));
            if (!same or !scope(r, w).any()) continue;
            if (g.matches(arena, tool, r.pattern, subject) or (given.len > 0 and g.matches(arena, tool, r.pattern, given)))
                return .{ .action = .deny, .why = ruleWhy(arena, r), .subject = subject };
        }
        // listing a source in briefs.ini or triggers.ini allows it, as an
        // allow rule would
        if (ctx.listed) |file| return .{ .action = .allow, .why = std.fmt.allocPrint(arena, "listed in {s}", .{file}) catch "listed by the owner", .subject = subject };
        if (tool == .money) {
            // no grant or allow rule lifts this: the owner is asked every time
            if (!ctx.scheduled) return .{ .action = .ask, .why = "money is asked every time", .subject = subject };
            if (ctx.money_unattended) return .{ .action = .allow, .why = "money in scheduled runs is switched on, within the caps", .subject = subject };
            return .{ .action = .deny, .why = "money is not moved in scheduled runs", .subject = subject };
        }
        if (tool.setup(arg)) {
            // like money: no grant or allow rule lifts this
            if (ctx.scheduled) return .{ .action = .deny, .why = "no one to ask in a scheduled run", .subject = subject };
            return .{ .action = .ask, .why = "asked every time: it changes what runs without you watching", .subject = subject };
        }
        // a grant for this tool (a shell command in this environment) and
        // key, for any run, the call's definition or what started its run;
        // a post others read is asked every time (an allow rule lifts that)
        const asked_every_time = tool == .send and ctx.shared;
        if (!asked_every_time and g.grants.covers(tool, ctx.env, grantKey(tool, subject), w, now_s)) return .{ .action = .allow, .why = "a grant covers it (/grants)", .subject = subject };
        var d: Decision = .{ .action = defaultFor(tool, arg, ctx), .why = "default for this tool", .subject = subject };
        // programs read these as their settings (.git/config, .npmrc, .env):
        // a file written there can make the next command run something else
        if (tool == .write_file and dotPart(subject)) d = .{ .action = .ask, .why = "a name starting with \".\" asks: programs read those as settings", .subject = subject };
        // the first allow or ask in the sections for the call's definition,
        // then in those for what started its run, then in the shared part
        var from: ?rules.Rule = null;
        pick: for ([_]Level{ .agent, .by, .shared }) |level| {
            for (g.rules) |r| {
                if (r.action == .deny or !std.mem.eql(u8, r.tool, name) or !envFits(r, tool, ctx.env)) continue;
                if (!scope(r, w).at(level) or !g.matches(arena, tool, r.pattern, subject)) continue;
                from = r;
                d = .{ .action = r.action, .why = ruleWhy(arena, r), .subject = subject };
                break :pick;
            }
        }
        // the definitions that delegated the call, and what started its
        // run, only narrow: an ask in their sections makes an allow from
        // anywhere else (another section, the default) ask
        if (d.action == .allow) for (g.rules) |r| {
            if (r.action != .ask or !std.mem.eql(u8, r.tool, name) or !envFits(r, tool, ctx.env)) continue;
            const sc = scope(r, w);
            if (!(sc.chain or sc.by) or sameSection(from, r) or !g.matches(arena, tool, r.pattern, subject)) continue;
            d = .{ .action = .ask, .why = ruleWhy(arena, r), .subject = subject };
            break;
        };
        if (d.action == .ask and ctx.scheduled) return .{ .action = .deny, .why = "no one to ask in a scheduled run", .subject = subject };
        return d;
    }

    /// A household member's call, or speech in a room (`room:NAME`, the
    /// same order with `[room]` sections): what members may use at all; a
    /// deny in any section that reaches it; money asked of the owner every
    /// time; a post where the member asked (speech posts nowhere: it is
    /// answered aloud); the first allow or ask in a section naming members
    /// (`[member:anna]`), then in `[member]`, then the household defaults.
    /// The shared part and the definitions' sections only narrow (their
    /// allows were written for the owner's runs), no grant covers a member,
    /// and only an MCP call can wait for the owner. A member's sections
    /// never reach speech, nor a room's a member (`matchesBy`: the kind).
    fn decideMember(g: *const Gate, arena: std.mem.Allocator, tool: Tool, subject: []const u8, given: []const u8, ctx: Ctx, w: Who) Decision {
        const room = who_mod.isRoom(w.by);
        if (!memberTool(tool)) return .{ .action = .deny, .why = if (room) "not for speech in the house" else "not for household members", .subject = subject };
        if (room and tool == .send) return .{ .action = .deny, .why = "speech in the house is answered aloud: it posts nowhere", .subject = subject };
        const name = @tagName(tool);
        for (g.rules) |r| {
            if (r.action != .deny or !envFits(r, tool, ctx.env)) continue;
            const same = std.mem.eql(u8, r.tool, name) or (tool == .money and std.mem.eql(u8, r.tool, "mcp"));
            if (!same or !scope(r, w).any()) continue;
            if (g.matches(arena, tool, r.pattern, subject) or (given.len > 0 and g.matches(arena, tool, r.pattern, given)))
                return .{ .action = .deny, .why = ruleWhy(arena, r), .subject = subject };
        }
        if (tool == .money) return .{ .action = .ask, .why = "money and guarded actions are asked of the owner every time", .subject = subject };
        if (tool == .send and ctx.here) return .{ .action = .allow, .why = "where the member asked", .subject = subject };
        var d = g.memberRule(arena, tool, subject, w) orelse memberDefault(tool, subject, room);
        // the owner's own lines narrow: an ask in the shared part or in a
        // section for the run's definition makes a member's allow ask
        if (d.action == .allow) for (g.rules) |r| {
            if (r.action != .ask or !std.mem.eql(u8, r.tool, name) or !envFits(r, tool, ctx.env)) continue;
            const sc = scope(r, w);
            if (!(sc.shared or sc.agent or sc.chain) or !g.matches(arena, tool, r.pattern, subject)) continue;
            d = .{ .action = .ask, .why = ruleWhy(arena, r), .subject = subject };
            break;
        };
        // only an action on a device or service can wait for the owner
        if (d.action == .ask and tool != .mcp) {
            if (room) return .{ .action = .deny, .why = std.fmt.allocPrint(arena, "{s} can't wait for the owner in speech: an allow line under [room] lets speech use it", .{name}) catch "it can't wait for the owner in speech", .subject = subject };
            return .{ .action = .deny, .why = std.fmt.allocPrint(arena, "{s} can't wait for the owner in a member's run: an allow line under [member] lets members use it", .{name}) catch "it can't wait for the owner in a member's run", .subject = subject };
        }
        return d;
    }

    /// The first allow or ask for a member's call in a section naming
    /// members (`[member:anna]`, `[member:a*]`), then in `[member]`; for
    /// speech the same with rooms (`[room:kitchen]`, then `[room]`).
    fn memberRule(g: *const Gate, arena: std.mem.Allocator, tool: Tool, subject: []const u8, w: Who) ?Decision {
        const name = @tagName(tool);
        for ([_]bool{ true, false }) |named| for (g.rules) |r| {
            if (r.action == .deny or !std.mem.eql(u8, r.tool, name)) continue;
            const section = r.section orelse continue;
            if (!who_mod.isHousehold(section) or (std.mem.indexOfScalar(u8, section, ':') != null) != named) continue;
            if (!who_mod.matchesBy(section, w.by) or !g.matches(arena, tool, r.pattern, subject)) continue;
            return .{ .action = r.action, .why = ruleWhy(arena, r), .subject = subject };
        };
        return null;
    }

    /// Whether a member's run is offered `tool`: what members may use, and
    /// a page read only when a member's section allows some. Speech's the
    /// same with `[room]` sections, and no `send` (it is answered aloud).
    pub fn memberOffers(g: *const Gate, tool: Tool, w: Who) bool {
        if (!memberTool(tool)) return false;
        if (tool == .send) return !who_mod.isRoom(w.by);
        if (tool != .fetch and tool != .browse) return true;
        for (g.rules) |r| {
            if (r.action != .allow or !std.mem.eql(u8, r.tool, @tagName(tool))) continue;
            const section = r.section orelse continue;
            if (who_mod.isHousehold(section) and who_mod.matchesBy(section, w.by)) return true;
        }
        return false;
    }

    /// Whether a rule's pattern matches; file patterns are read like file
    /// arguments: a leading `./` or the workspace's own path is dropped,
    /// `\` is a separator on Windows, case is ignored where volumes ignore it.
    /// Address patterns match by parts (rules.zig).
    fn matches(g: *const Gate, arena: std.mem.Allocator, tool: Tool, pattern: []const u8, s: []const u8) bool {
        switch (tool) {
            .read_file, .write_file => {},
            .fetch, .browse => return rules.matchUrl(arena, pattern, s),
            .web => return rules.matchHost(arena, pattern, s),
            else => return rules.glob(pattern, s),
        }
        var p = slashes(arena, pattern);
        const ws = slashes(arena, g.workspace);
        if (p.len > ws.len and std.mem.startsWith(u8, p, ws) and p[ws.len] == '/') p = p[ws.len + 1 ..];
        while (std.mem.startsWith(u8, p, "./")) p = std.mem.trimStart(u8, p[2..], "/");
        return rules.globCase(p, s, fold_paths);
    }
};

/// What a household member's run may use at all; the rest reaches the
/// owner's files, machine, accounts, memory or settings.
pub fn memberTool(tool: Tool) bool {
    return switch (tool) {
        .send, .search, .fetch, .browse, .mcp, .money => true,
        else => false,
    };
}

/// homemcp's tools a member uses alone: its reads and its ordinary devices
/// (lights, plugs, climate, covers, within the home file's limits), on
/// whatever server name the owner gave it. Never `home_guarded`.
const home_tools = [_][]const u8{ "home_state", "home_wait", "home_set" };

/// What a member's call gets when no member line decides it (speech's:
/// `room`, when no room's line does).
fn memberDefault(tool: Tool, subject: []const u8, room: bool) Decision {
    return switch (tool) {
        .search => .{ .action = .allow, .why = "household default: search", .subject = subject },
        .mcp => blk: {
            // "SERVER/TOOL INPUT"
            const head = subject[0 .. std.mem.indexOfScalar(u8, subject, ' ') orelse subject.len];
            const slash = std.mem.indexOfScalar(u8, head, '/') orelse break :blk .{ .action = .ask, .why = "household default: the owner decides", .subject = subject };
            if (oneOf(head[slash + 1 ..], &home_tools)) break :blk .{ .action = .allow, .why = "household default: the home's reads and ordinary devices", .subject = subject };
            break :blk .{ .action = .ask, .why = "household default: the owner decides", .subject = subject };
        },
        .fetch, .browse => .{ .action = .deny, .why = if (room) "household default: speech reads no pages (search instead); an allow line under [room] lets it read some" else "household default: members' runs read no pages (search instead); an allow line under [member] lets them read some", .subject = subject },
        .send => .{ .action = .deny, .why = "a member's run posts only where the member asked", .subject = subject },
        else => .{ .action = .deny, .why = if (room) "not for speech in the house" else "not for household members", .subject = subject },
    };
}

/// Where a rule applies to a call: the shared part, or a section whose who
/// pattern matches the call's definition, a definition that delegated it,
/// or what started its run.
const Scope = struct {
    shared: bool = false,
    agent: bool = false,
    chain: bool = false,
    by: bool = false,

    fn any(s: Scope) bool {
        return s.shared or s.agent or s.chain or s.by;
    }

    fn at(s: Scope, level: Level) bool {
        return switch (level) {
            .agent => s.agent,
            .by => s.by,
            .shared => s.shared,
        };
    }
};

/// The order allow and ask rules are looked at in.
const Level = enum { agent, by, shared };

fn scope(r: rules.Rule, w: Who) Scope {
    const section = r.section orelse return .{ .shared = true };
    const re = who_mod.reach(section, w);
    return .{ .agent = re.agent, .chain = re.chain, .by = re.by };
}

/// Whether `r` is in the section the rule `from` decided in: headers with
/// the same pattern are one section.
fn sameSection(from: ?rules.Rule, r: rules.Rule) bool {
    const f = from orelse return false;
    const a = f.section orelse return false;
    const b = r.section orelse return false;
    return std.mem.eql(u8, a, b);
}

/// A rule for an environment (`shell@box`) is only for calls there.
fn envFits(r: rules.Rule, tool: Tool, env: []const u8) bool {
    const e = r.env orelse return true;
    return tool == .shell and std.mem.eql(u8, e, env);
}

fn ruleWhy(arena: std.mem.Allocator, r: rules.Rule) []const u8 {
    return std.fmt.allocPrint(arena, "rule on line {d}", .{r.line}) catch "rule";
}

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
    try t.expectEqual(.allow, f.act(.fetch, "https://feeds.example.com/rss", .{ .scheduled = true, .listed = "briefs.ini" }));
    // but not past the hard limits
    try t.expectEqual(.deny, f.act(.fetch, "file:///etc/passwd", .{ .listed = "briefs.ini" }));
}

test "a_deny_rule_applies_to_brief_sources_too" {
    var f: Fixture = undefined;
    try f.init("deny fetch https://feeds.example.com/*\ndeny search *passwords*\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.fetch, "https://feeds.example.com/rss", .{ .scheduled = true, .listed = "briefs.ini" }));
    try t.expectEqual(.deny, f.act(.search, "leaked passwords list", .{ .scheduled = true, .listed = "briefs.ini" }));
    try t.expectEqual(.allow, f.act(.fetch, "https://other.example.com/rss", .{ .scheduled = true, .listed = "briefs.ini" }));
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

test "address_rules_match_by_parts_not_as_one_glob" {
    var f: Fixture = undefined;
    try f.init("allow fetch https://*.good.com/*\nallow browse https://docs.example.com/guide/*\nallow fetch http://127.0.0.1:*\nallow web *.good.com\n");
    defer f.deinit();
    // the host is the host, wherever else the name appears
    for ([_][]const u8{ "https://evil.com/.good.com/", "https://good.com.evil.com/", "https://evil.com/?x=.good.com", "https://evil.com/#.good.com/", "https://good.com/", "http://a.good.com/x", "https://a.good.com:8443/x" }) |u|
        try t.expectEqual(.ask, f.act(.fetch, u, .{}));
    for ([_][]const u8{ "https://a.good.com/x", "https://A.B.Good.COM./x?y=1", "https://a.good.com:443/" }) |u|
        try t.expectEqual(.allow, f.act(.fetch, u, .{}));
    // the path as the server gets it
    try t.expectEqual(.allow, f.act(.browse, "https://docs.example.com/guide/intro", .{}));
    for ([_][]const u8{ "https://docs.example.com/guide/../admin", "https://docs.example.com/guide/%2e%2e/admin", "https://docs.example.com/admin?/guide/" }) |u|
        try t.expectEqual(.ask, f.act(.browse, u, .{}));
    // a .. that some servers still follow, behind an escaped slash or a ;
    for ([_][]const u8{ "https://docs.example.com/guide/..%2Fadmin", "https://docs.example.com/guide/%2e%2e%2fadmin", "https://docs.example.com/guide/..;/admin" }) |u|
        try t.expectEqual(.deny, f.act(.browse, u, .{}));
    // a port of * is any port; no path is any path
    try t.expectEqual(.allow, f.act(.fetch, "http://127.0.0.1:8080/page/a", .{}));
    try t.expectEqual(.allow, f.act(.fetch, "http://127.0.0.1:8080/api/projects/group%2Fproject;v=2", .{}));
    try t.expectEqual(.ask, f.act(.fetch, "http://127.0.0.1.evil.com:8080/", .{}));
    // web: the host, and its port
    try t.expectEqual(.allow, f.act(.web, "a.good.com", .{}));
    try t.expectEqual(.ask, f.act(.web, "good.com.evil.com", .{}));
    try t.expectEqual(.ask, f.act(.web, "a.good.com:8443", .{}));
}

test "deny_and_ask_rules_that_are_not_addresses_match_the_whole_address" {
    var f: Fixture = undefined;
    try f.init("deny fetch *evil*\nask fetch *tracker*\ndeny web *bad*\nallow fetch https://*.good.com/*\nallow web *\n");
    defer f.deinit();
    // matched against the address as it is used, and as it was given
    try t.expectEqual(.deny, f.act(.fetch, "https://EVIL.com/", .{}));
    try t.expectEqual(.deny, f.act(.fetch, "https://a.good.com/?q=evil", .{}));
    try t.expectEqual(.ask, f.act(.fetch, "https://a.good.com/tracker.js", .{}));
    try t.expectEqual(.allow, f.act(.fetch, "https://a.good.com/x", .{}));
    try t.expectEqual(.deny, f.act(.web, "very.BAD.example", .{}));
    try t.expectEqual(.allow, f.act(.web, "localhost:8080", .{}));
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

test "a_definitions_section_allows_for_it_only" {
    var f: Fixture = undefined;
    try f.init("[agent:coder]\nallow shell zig build*\n");
    defer f.deinit();
    const coder: Who = .{ .agent = "coder" };
    const helper: Who = .{ .agent = "helper", .parent = &coder };
    try t.expectEqual(.allow, f.act(.shell, "zig build test", .{ .who = coder }));
    try t.expectEqual(.ask, f.act(.shell, "zig build test", .{}));
    // a delegating definition's section widens nothing for its helpers
    try t.expectEqual(.ask, f.act(.shell, "zig build test", .{ .who = helper }));
}

test "a_delegating_definitions_section_denies_and_asks_for_its_helpers_but_allows_nothing" {
    var f: Fixture = undefined;
    try f.init("allow shell ls*\n[agent:main]\ndeny shell rm *\nask read_file secret/*\nallow shell make*\n");
    defer f.deinit();
    const main: Who = .{};
    const helper: Who = .{ .agent = "helper", .parent = &main };
    try t.expectEqual(.deny, f.act(.shell, "rm -rf x", .{ .who = helper }));
    try t.expectEqual(.ask, f.act(.read_file, "secret/k", .{ .who = helper }));
    try t.expectEqual(.ask, f.act(.shell, "make all", .{ .who = helper }));
    try t.expectEqual(.allow, f.act(.shell, "ls -l", .{ .who = helper }));
    try t.expectEqual(.allow, f.act(.shell, "make all", .{ .who = main }));
    try t.expectEqual(.ask, f.act(.read_file, "secret/k", .{ .who = main }));
}

test "a_by_section_allows_for_that_origins_runs" {
    var f: Fixture = undefined;
    try f.init("[schedule:btc-watch]\nallow fetch https://api.coinbase.com/*\n");
    defer f.deinit();
    const task: Who = .{ .by = "schedule:btc-watch" };
    const helper: Who = .{ .agent = "helper", .by = task.by, .parent = &task };
    const u = "https://api.coinbase.com/v2/prices";
    try t.expectEqual(.allow, f.act(.fetch, u, .{ .who = task, .scheduled = true }));
    try t.expectEqual(.allow, f.act(.fetch, u, .{ .who = helper, .scheduled = true }));
    try t.expectEqual(.deny, f.act(.fetch, u, .{ .who = .{ .by = "schedule:other" }, .scheduled = true }));
    try t.expectEqual(.ask, f.act(.fetch, u, .{}));
}

test "an_ask_in_a_by_or_delegator_section_turns_an_allow_from_another_section_into_ask" {
    var f: Fixture = undefined;
    try f.init("[agent:main]\nallow shell make*\n[schedule]\nask shell *\n");
    defer f.deinit();
    const a = f.arena.allocator();
    try t.expectEqual(.allow, f.act(.shell, "make", .{}));
    try t.expectEqual(.ask, f.act(.shell, "make", .{ .who = .{ .by = "schedule:nightly" } }));
    // the definition that delegated narrows the shared part's allow
    f.gate.rules = try rules.parse(a, "allow shell make*\n[agent:main]\nask shell *\n");
    const main: Who = .{};
    try t.expectEqual(.ask, f.act(.shell, "make", .{ .who = .{ .agent = "helper", .parent = &main } }));
    try t.expectEqual(.ask, f.act(.shell, "make", .{}));
    // inside one section its first matching line decides
    f.gate.rules = try rules.parse(a, "[schedule]\nallow shell make*\nask shell *\n");
    try t.expectEqual(.allow, f.act(.shell, "make", .{ .who = .{ .by = "schedule:x" } }));
}

test "all_returns_to_rules_for_every_call_and_no_who_is_main_started_by_the_owner" {
    var f: Fixture = undefined;
    try f.init("[agent:coder]\nallow shell a\n[all]\nallow shell b\n[owner]\nallow shell c\n[agent:main]\nallow shell d\n");
    defer f.deinit();
    try t.expectEqual(.ask, f.act(.shell, "a", .{}));
    for ([_][]const u8{ "b", "c", "d" }) |cmd| try t.expectEqual(.allow, f.act(.shell, cmd, .{}));
    const coder: Who = .{ .agent = "coder" };
    for ([_][]const u8{ "a", "b", "c" }) |cmd| try t.expectEqual(.allow, f.act(.shell, cmd, .{ .who = coder }));
    try t.expectEqual(.ask, f.act(.shell, "d", .{ .who = coder }));
}

test "a_deny_in_any_section_that_reaches_the_call_wins" {
    var f: Fixture = undefined;
    try f.init("allow shell *\n[schedule:x]\ndeny shell curl *\n[agent:helper]\ndeny fetch *\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.shell, "curl a", .{ .who = .{ .by = "schedule:x" } }));
    try t.expectEqual(.allow, f.act(.shell, "curl a", .{}));
    const main: Who = .{};
    try f.grants.add(.fetch, "a.com", 5000);
    try t.expectEqual(.deny, f.act(.fetch, "https://a.com/", .{ .who = .{ .agent = "helper", .parent = &main } }));
    try t.expectEqual(.allow, f.act(.fetch, "https://a.com/", .{}));
}

test "a_shell_rule_for_an_environment_matches_only_there" {
    var f: Fixture = undefined;
    try f.init("allow shell@box *\ndeny shell rm *\nallow shell@host ls\n");
    defer f.deinit();
    try t.expectEqual(.ask, f.act(.shell, "make", .{}));
    try t.expectEqual(.deny, f.act(.shell, "rm x", .{}));
    try t.expectEqual(.allow, f.act(.shell, "ls", .{}));
    try t.expectEqual(.allow, f.act(.shell, "make", .{ .env = "box" }));
    try t.expectEqual(.deny, f.act(.shell, "rm x", .{ .env = "box" }));
}

test "grants_cover_the_who_they_name" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const main: Who = .{};
    const helper: Who = .{ .agent = "helper", .parent = &main };
    const task: Who = .{ .by = "schedule:btc-watch" };
    const task_helper: Who = .{ .agent = "helper", .by = task.by, .parent = &task };
    try f.grants.addFor(.shell, "host", "make", "agent:main", 5000);
    try t.expectEqual(.allow, f.act(.shell, "make", .{ .who = main }));
    try t.expectEqual(.allow, f.act(.shell, "make", .{ .who = task }));
    try t.expectEqual(.ask, f.act(.shell, "make", .{ .who = helper }));
    try f.grants.addFor(.fetch, "", "api.coinbase.com", "schedule:btc-watch", 5000);
    try t.expectEqual(.allow, f.act(.fetch, "https://api.coinbase.com/x", .{ .who = task }));
    try t.expectEqual(.allow, f.act(.fetch, "https://api.coinbase.com/x", .{ .who = task_helper }));
    try t.expectEqual(.ask, f.act(.fetch, "https://api.coinbase.com/x", .{}));
    // a workflow's grant covers all of its steps, no other workflow
    try f.grants.addFor(.mcp, "", "github/add_issue_comment", "workflow:release", 5000);
    try t.expectEqual(.allow, f.act(.mcp, "github/add_issue_comment {}", .{ .who = .{ .by = "workflow:release/post" } }));
    try t.expectEqual(.ask, f.act(.mcp, "github/add_issue_comment {}", .{ .who = .{ .by = "workflow:other/post" } }));
    // one with no who, as 0.3's, covers any run
    try f.grants.add(.shell, "ls", 5000);
    try t.expectEqual(.allow, f.act(.shell, "ls", .{ .who = helper }));
    try t.expectError(error.BadWho, f.grants.addFor(.shell, "host", "x", "agent:*", 5000));
}

test "a_shell_grant_names_its_environment" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try f.grants.addFor(.shell, "box", "make test", "", 5000);
    try t.expectEqual(.ask, f.act(.shell, "make test", .{}));
    try t.expectEqual(.allow, f.act(.shell, "make test", .{ .env = "box" }));
    try f.grants.add(.shell, "ls", 5000);
    try t.expectEqual(.allow, f.act(.shell, "ls", .{}));
    try t.expectEqual(.ask, f.act(.shell, "ls", .{ .env = "box" }));
    // other kinds run in no environment
    try f.grants.addFor(.fetch, "box", "a.com", "", 5000);
    try t.expectEqual(.allow, f.act(.fetch, "https://a.com/", .{}));
}

test "the_grants_file_keeps_who_and_environment_and_reads_0_3_lines_as_before" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const path = try std.fs.path.join(a, &.{ f.gate.workspace, "grants" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = "shell\t5000\tls -l\nfetch\t5000\tnews.example.com\nwrite_file\t5000\tnotes/a\tb.md\nshell\t500\told\n" });
    const main: Who = .{};
    const helper: Who = .{ .agent = "helper", .parent = &main };
    var g: Grants = .init(t.allocator);
    defer g.deinit();
    try g.load(t.io, path, 1000);
    try t.expect(g.covers(.shell, "host", "ls -l", main, 1000));
    try t.expect(!g.covers(.shell, "box", "ls -l", main, 1000));
    try t.expect(g.covers(.fetch, "", "news.example.com", helper, 1000));
    try t.expect(g.covers(.write_file, "", "notes/a\tb.md", main, 1000));
    try t.expect(!g.covers(.shell, "host", "old", main, 1000));
    // a line break in a key stays inside its grant
    const heredoc = "cat <<EOF\nshell\t9999999999\trm -rf /\nEOF";
    try g.addFor(.shell, "host", heredoc, "agent:main", 5000);
    try g.save(t.io, path, 1000);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
    try t.expect(std.mem.startsWith(u8, text, "#"));
    var g2: Grants = .init(t.allocator);
    defer g2.deinit();
    try g2.load(t.io, path, 1000);
    try t.expectEqual(4, g2.items.items.len);
    try t.expect(g2.covers(.shell, "host", heredoc, main, 1000));
    try t.expect(!g2.covers(.shell, "host", heredoc, helper, 1000));
    try t.expect(!g2.covers(.shell, "host", "rm -rf /", main, 1000));
    try t.expect(!g2.covers(.shell, "host", "rm -rf /", helper, 1000));
    try t.expect(g2.covers(.write_file, "", "notes/a\tb.md", helper, 1000));
    // a line whose who is not a who value is left out
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = try std.mem.concat(a, u8, &.{ text, "fetch\t5000\tevil.com\tagent:*\n" }) });
    var g3: Grants = .init(t.allocator);
    defer g3.deinit();
    try g3.load(t.io, path, 1000);
    try t.expect(!g3.covers(.fetch, "", "evil.com", main, 1000));
    try t.expectEqual(4, g3.items.items.len);
}

test "the_platforms_kinds_have_their_defaults" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try t.expectEqual(.allow, f.act(.send, "main", .{}));
    try t.expectEqual(.ask, f.act(.send, "family", .{ .shared = true }));
    try t.expectEqual(.deny, f.act(.send, "family", .{ .shared = true, .scheduled = true }));
    try t.expectEqual(.allow, f.act(.ask_owner, "Which account?", .{}));
    try t.expectEqual(.ask, f.act(.mail, "home", .{}));
    for ([_][]const u8{ "add btc", "rm btc" }) |arg| try t.expectEqual(.ask, f.act(.trigger, arg, .{}));
    for ([_][]const u8{ "test btc", "list" }) |arg| try t.expectEqual(.allow, f.act(.trigger, arg, .{}));
    for ([_][]const u8{ "save release", "start release", "stop release#3" }) |arg| try t.expectEqual(.ask, f.act(.workflow, arg, .{}));
    for ([_][]const u8{ "check", "list", "show release" }) |arg| try t.expectEqual(.allow, f.act(.workflow, arg, .{}));
    try t.expectEqual(.ask, f.act(.agent_save, "researcher", .{}));
    try t.expectEqual(.ask, f.act(.app_save, "notes", .{}));
    try t.expectEqual(.ask, f.act(.env_save, "box", .{}));
    try t.expectEqual(.allow, f.act(.app_read, "notes log", .{}));
    try t.expectEqual(.allow, f.act(.app_draft, "notes", .{}));
    try t.expectEqual(.allow, f.act(.snapshot, "notes", .{}));
}

test "setup_calls_are_asked_every_time_like_money" {
    var f: Fixture = undefined;
    try f.init("allow agent_save *\nallow trigger *\nallow workflow save *\ndeny app_save evil\n");
    defer f.deinit();
    const a = f.arena.allocator();
    try f.grants.add(.agent_save, "researcher", 5000);
    try f.grants.addFor(.trigger, "", "add btc", "agent:main", 5000);
    const d = f.gate.decide(a, .agent_save, "researcher", 1000, .{});
    try t.expectEqual(.ask, d.action);
    try t.expect(!d.allow_day);
    const add = f.gate.decide(a, .trigger, "add btc", 1000, .{});
    try t.expectEqual(.ask, add.action);
    try t.expect(!add.allow_day);
    try t.expectEqual(.allow, f.act(.trigger, "rm btc", .{}));
    try t.expectEqual(.ask, f.act(.workflow, "save release", .{}));
    try t.expectEqual(.deny, f.act(.app_save, "evil", .{}));
    try t.expectEqual(.deny, f.act(.env_save, "box", .{ .scheduled = true }));
    try t.expect(f.gate.decide(a, .shell, "ls", 1000, .{}).allow_day);
    try t.expect(!f.gate.decide(a, .money, "broker/x {}", 1000, .{}).allow_day);
}

test "a_send_others_read_is_asked_every_time_and_an_allow_rule_lifts_it" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const d = f.gate.decide(a, .send, "family", 1000, .{ .shared = true });
    try t.expectEqual(.ask, d.action);
    try t.expect(!d.allow_day);
    try f.grants.add(.send, "family", 5000);
    try t.expectEqual(.ask, f.act(.send, "family", .{ .shared = true }));
    f.gate.rules = try rules.parse(a, "allow send family\n");
    try t.expectEqual(.allow, f.act(.send, "family", .{ .shared = true }));
    f.gate.rules = try rules.parse(a, "deny send main\n");
    try t.expectEqual(.deny, f.act(.send, "main", .{}));
}

test "deny_mcp_rule_covers_money_tools_of_that_server" {
    var f: Fixture = undefined;
    try f.init("deny mcp broker/*\n");
    defer f.deinit();
    try t.expectEqual(.deny, f.act(.money, "broker/place_order {}", .{}));
}

test "no_folders_ini_keeps_every_0_3_decision" {
    var f: Fixture = undefined;
    try f.init("deny shell rm *\nallow fetch https://a.com/*\nask write_file secret/*\n");
    defer f.deinit();
    const a = f.arena.allocator();
    try f.grants.add(.shell, "make", 5000);
    // what harness init writes: comments only
    const empty = try folders_mod.parse(a, folders_mod.example);
    const Call = struct { tool: Tool, arg: []const u8, ctx: Ctx = .{} };
    const calls = [_]Call{
        .{ .tool = .shell, .arg = "rm -rf x" },
        .{ .tool = .shell, .arg = "make" },
        .{ .tool = .shell, .arg = "ls" },
        .{ .tool = .shell, .arg = "ls", .ctx = .{ .scheduled = true } },
        .{ .tool = .read_file, .arg = "notes/a" },
        .{ .tool = .read_file, .arg = "../x" },
        .{ .tool = .write_file, .arg = "secret/k" },
        .{ .tool = .write_file, .arg = ".npmrc" },
        .{ .tool = .write_file, .arg = "notes/a", .ctx = .{ .scheduled = true } },
        .{ .tool = .fetch, .arg = "https://a.com/x" },
        .{ .tool = .web, .arg = "a.com" },
        .{ .tool = .money, .arg = "broker/x {}" },
        .{ .tool = .skill_save, .arg = "s", .ctx = .{ .scheduled = true } },
    };
    for (calls) |c| {
        f.gate.folders = null;
        const before = f.gate.decide(a, c.tool, c.arg, 1000, c.ctx);
        f.gate.folders = &empty;
        const with = f.gate.decide(a, c.tool, c.arg, 1000, c.ctx);
        try t.expectEqual(before.action, with.action);
        try t.expectEqualStrings(before.why, with.why);
        try t.expect(!with.role);
    }
}

test "folders_match_like_file_rules" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const fs = try folders_mod.parse(a, "[notes]\nwrite = agent:coder\n");
    f.gate.folders = &fs;
    try f.tmp.dir.createDirPath(t.io, "ws/notes/sub");
    const refused = [_][]const u8{ "notes/a", "./notes/a", "x/../notes/a", try std.fs.path.join(a, &.{ f.gate.workspace, "notes", "a" }) };
    for (refused) |p| {
        const d = f.gate.decide(a, .write_file, p, 1000, .{});
        try t.expectEqual(.deny, d.action);
        try t.expect(d.role);
    }
    if (fold_paths) try t.expectEqual(.deny, f.act(.write_file, "NOTES/a", .{}));
    if (builtin.os.tag == .windows) try t.expectEqual(.deny, f.act(.write_file, "notes\\a", .{}));
    try t.expectEqual(.allow, f.act(.write_file, "notes2/a", .{}));
    if (builtin.os.tag != .windows) {
        // a link into the folder is the folder
        try f.tmp.dir.symLink(t.io, "notes/sub", "ws/short", .{ .is_directory = true });
        try t.expectEqual(.deny, f.act(.write_file, "short/x", .{}));
        // a section naming a link holds what it points to
        try f.tmp.dir.symLink(t.io, "notes", "ws/alias", .{ .is_directory = true });
        const via = try folders_mod.parse(a, "[alias]\nwrite = agent:coder\n");
        f.gate.folders = &via;
        try t.expectEqual(.deny, f.act(.write_file, "notes/x", .{}));
    }
}

test "a_role_refusal_is_final" {
    var f: Fixture = undefined;
    try f.init("allow write_file *\n");
    defer f.deinit();
    const a = f.arena.allocator();
    try f.grants.add(.write_file, "notes/a.md", 5000);
    const fs = try folders_mod.parse(a, "[notes]\nwrite = agent:coder\n");
    f.gate.folders = &fs;
    for ([_]Ctx{ .{}, .{ .scheduled = true } }) |ctx| {
        const d = f.gate.decide(a, .write_file, "notes/a.md", 1000, ctx);
        try t.expectEqual(.deny, d.action);
        try t.expect(d.role);
        try t.expectEqualStrings("folders.ini [notes] write: agent:main is not listed", d.why);
    }
    try t.expectEqual(.allow, f.act(.read_file, "notes/a.md", .{}));
}

test "shell_dir_is_confined_and_needs_run" {
    var f: Fixture = undefined;
    try f.init("allow shell ls\n");
    defer f.deinit();
    const a = f.arena.allocator();
    const out = f.gate.decide(a, .shell, "ls", 1000, .{ .dir = "../x" });
    try t.expectEqual(.deny, out.action);
    try t.expectEqualStrings("dir is outside the workspace", out.why);
    const fs = try folders_mod.parse(a, "[work]\nrun = agent:coder\n");
    f.gate.folders = &fs;
    for ([_][]const u8{ "work", "work/sub" }) |dir| {
        const d = f.gate.decide(a, .shell, "ls", 1000, .{ .dir = dir });
        try t.expectEqual(.deny, d.action);
        try t.expect(d.role);
        try t.expectEqualStrings("folders.ini [work] run: agent:main is not listed", d.why);
    }
    try t.expectEqual(.allow, f.act(.shell, "ls", .{ .dir = "work", .who = .{ .agent = "coder" } }));
    const moved = f.gate.decide(a, .shell, "make", 1000, .{ .dir = "./work/../notes" });
    try t.expectEqual(.ask, moved.action);
    try t.expectEqualStrings("notes", moved.dir);
    const plain = f.gate.decide(a, .shell, "make", 1000, .{});
    try t.expectEqual(.ask, plain.action);
    try t.expectEqualStrings("", plain.dir);
}

// ---- household members ----

const anna: Who = .{ .by = "member:anna" };
const ben: Who = .{ .by = "member:ben" };

test "a_members_defaults" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    const a = f.arena.allocator();
    const m: Ctx = .{ .who = anna };
    // homemcp's reads and ordinary devices, on any server's name, and search
    for ([_][]const u8{ "home/home_state {}", "house/home_wait {\"device\":\"hall_motion\"}", "home/home_set {\"device\":\"hall_light\",\"action\":\"on\"}" }) |arg|
        try t.expectEqual(.allow, f.act(.mcp, arg, m));
    try t.expectEqual(.allow, f.act(.search, "weather tomorrow", m));
    // another MCP tool is the owner's to decide; money every time; never for a day
    const car = f.gate.decide(a, .mcp, "cloud/car_status {}", 1000, m);
    try t.expectEqual(.ask, car.action);
    try t.expect(!car.allow_day);
    try t.expectEqual(.ask, f.act(.mcp, "home/home_settings {}", m));
    const lock = f.gate.decide(a, .money, "home/home_guarded {\"device\":\"front_door\",\"action\":\"unlock\"}", 1000, m);
    try t.expectEqual(.ask, lock.action);
    try t.expect(!lock.allow_day);
    // a home tool not listed as money is no guarded device's way round
    try t.expectEqual(.ask, f.act(.mcp, "home/home_guarded {\"device\":\"front_door\",\"action\":\"unlock\"}", m));
    // pages are not read for members
    try t.expectEqual(.deny, f.act(.fetch, "https://example.com/", m));
    try t.expectEqual(.deny, f.act(.browse, "https://example.com/", m));
    // a post where the member asked, nowhere else
    try t.expectEqual(.allow, f.act(.send, "home", .{ .who = anna, .shared = true, .here = true }));
    try t.expectEqual(.deny, f.act(.send, "main", .{ .who = anna }));
    try t.expectEqual(.deny, f.act(.send, "family", .{ .who = anna, .shared = true }));
    // the owner's runs keep their defaults
    try t.expectEqual(.ask, f.act(.mcp, "home/home_set {}", .{}));
    try t.expect(f.gate.decide(a, .shell, "ls", 1000, .{}).allow_day);
}

test "what_members_never_get" {
    var f: Fixture = undefined;
    try f.init("allow shell *\n[member]\nallow shell *\nallow read_file *\nallow write_file *\nallow web *\nallow login *\nallow recall *\nallow remember *\nallow history *\nallow skill *\nallow skill_save *\nallow delegate *\nallow agent_save *\nallow trigger *\nallow workflow *\nallow ask_owner *\nallow snapshot *\nallow app_read *\nallow env_save *\nallow mail *\n");
    defer f.deinit();
    const a = f.arena.allocator();
    const Call = struct { Tool, []const u8 };
    const calls = [_]Call{
        .{ .shell, "ls" },              .{ .read_file, "notes.md" }, .{ .write_file, "notes.md" }, .{ .web, "example.com" },
        .{ .login, "bot example.com" }, .{ .recall, "x" },           .{ .remember, "x" },          .{ .history, "x" },
        .{ .skill, "x" },               .{ .skill_save, "x" },       .{ .delegate, "1 task" },     .{ .agent_save, "x" },
        .{ .trigger, "add x" },         .{ .trigger, "list" },       .{ .workflow, "save x" },     .{ .workflow, "list" },
        .{ .ask_owner, "x?" },          .{ .snapshot, "notes" },     .{ .app_read, "x log" },      .{ .env_save, "box" },
        .{ .mail, "home" },
    };
    for (calls) |c| {
        const d = f.gate.decide(a, c[0], c[1], 1000, .{ .who = anna });
        if (d.action != .deny) std.debug.print("{s} {s}: {s}\n", .{ @tagName(c[0]), c[1], @tagName(d.action) });
        try t.expectEqual(.deny, d.action);
        try t.expectEqualStrings("not for household members", d.why);
        try t.expect(!f.gate.memberOffers(c[0], anna));
    }
    // the owner's are decided as before
    try t.expectEqual(.allow, f.act(.shell, "ls", .{}));
}

test "member_sections_decide_for_members_only" {
    var f: Fixture = undefined;
    try f.init(
        \\allow mcp cloud/car_lock *
        \\allow fetch https://news.example.com/*
        \\[agent:main]
        \\allow mcp cloud/car_climate *
        \\[owner]
        \\allow mcp cloud/car_status *
        \\[member]
        \\allow mcp cloud/car_status *
        \\allow fetch https://*.wikipedia.org/*
        \\ask fetch https://maps.example.com/*
        \\[member:anna]
        \\ask mcp cloud/car_status *
        \\[member:b*]
        \\allow mcp cloud/car_command *
        \\
    );
    defer f.deinit();
    const a = f.arena.allocator();
    // a section naming members first, whatever comes first in the file
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_status {}", .{ .who = anna }));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_status {}", .{ .who = ben }));
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_command {}", .{ .who = anna }));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_command {}", .{ .who = ben }));
    // the owner's allows are not a member's: the shared part, a definition's, [owner]
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_lock {}", .{ .who = anna }));
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_climate {}", .{ .who = anna }));
    try t.expectEqual(.deny, f.act(.fetch, "https://news.example.com/a", .{ .who = anna }));
    // a member line lets members read a page; an ask for one is no question
    try t.expectEqual(.allow, f.act(.fetch, "https://en.wikipedia.org/wiki/Zig", .{ .who = anna }));
    const maps = f.gate.decide(a, .fetch, "https://maps.example.com/x", 1000, .{ .who = anna });
    try t.expectEqual(.deny, maps.action);
    try t.expect(std.mem.indexOf(u8, maps.why, "[member]") != null);
    // the owner's runs as before
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_status {}", .{}));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_lock {}", .{}));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_climate {}", .{}));
    try t.expect(f.gate.memberOffers(.fetch, anna));
}

test "the_owners_deny_and_ask_reach_members" {
    var f: Fixture = undefined;
    try f.init(
        \\deny mcp */home_set {"device":"oven"*
        \\ask mcp */home_set {"device":"heater"*
        \\[agent:main]
        \\deny mcp cloud/*
        \\[member]
        \\allow mcp cloud/car_status *
        \\deny mcp */home_set {"device":"tv"*
        \\
    );
    defer f.deinit();
    const m: Ctx = .{ .who = anna };
    try t.expectEqual(.deny, f.act(.mcp, "home/home_set {\"device\":\"oven\",\"action\":\"on\"}", m));
    try t.expectEqual(.ask, f.act(.mcp, "home/home_set {\"device\":\"heater\",\"action\":\"on\"}", m));
    try t.expectEqual(.deny, f.act(.mcp, "cloud/car_status {}", m));
    try t.expectEqual(.deny, f.act(.mcp, "home/home_set {\"device\":\"tv\",\"action\":\"on\"}", m));
    try t.expectEqual(.allow, f.act(.mcp, "home/home_set {\"device\":\"hall_light\",\"action\":\"on\"}", m));
    // a deny stops a post where the member asked too
    f.gate.rules = try rules.parse(f.arena.allocator(), "[member:anna]\ndeny send home\n");
    try t.expectEqual(.deny, f.act(.send, "home", .{ .who = anna, .shared = true, .here = true }));
    try t.expectEqual(.allow, f.act(.send, "home", .{ .who = ben, .shared = true, .here = true }));
}

test "no_grant_covers_a_member" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try f.grants.add(.mcp, "cloud/car_status", 5000);
    try f.grants.addFor(.mcp, "", "cloud/car_command", "agent:main", 5000);
    try f.grants.addFor(.mcp, "", "cloud/car_climate", "member:anna", 5000);
    for ([_][]const u8{ "cloud/car_status {}", "cloud/car_command {}", "cloud/car_climate {}" }) |arg|
        try t.expectEqual(.ask, f.act(.mcp, arg, .{ .who = anna }));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_status {}", .{}));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_command {}", .{}));
}

test "member_offers_pages_only_when_a_member_rule_allows_them" {
    var f: Fixture = undefined;
    try f.init("allow fetch https://a.com/*\n[member:ben]\nallow fetch https://b.com/*\nask browse https://b.com/*\n");
    defer f.deinit();
    try t.expect(!f.gate.memberOffers(.fetch, anna));
    try t.expect(f.gate.memberOffers(.fetch, ben));
    try t.expect(!f.gate.memberOffers(.browse, ben));
    for ([_]Tool{ .send, .search, .mcp, .money }) |tool| try t.expect(f.gate.memberOffers(tool, anna));
}

// ---- speech in the house (Home Assistant's voice satellites) ----

const kitchen: Who = .{ .by = "room:kitchen" };
const hall: Who = .{ .by = "room:hall" };

test "a_rooms_defaults" {
    var f: Fixture = undefined;
    try f.init("allow shell *\n[room]\nallow shell *\nallow read_file *\nallow write_file *\nallow web *\nallow recall *\nallow remember *\nallow history *\nallow skill *\nallow delegate *\nallow agent_save *\nallow trigger *\nallow workflow *\nallow ask_owner *\nallow snapshot *\nallow send *\n");
    defer f.deinit();
    const a = f.arena.allocator();
    const r: Ctx = .{ .who = kitchen };
    // the household's: homemcp's reads and ordinary devices, and search
    for ([_][]const u8{ "home/home_state {}", "house/home_wait {\"device\":\"hall_motion\"}", "home/home_set {\"device\":\"hall_light\",\"action\":\"on\"}" }) |arg|
        try t.expectEqual(.allow, f.act(.mcp, arg, r));
    try t.expectEqual(.allow, f.act(.search, "weather tomorrow", r));
    // another MCP tool, money and the guarded tool: the owner's, never for a day
    const car = f.gate.decide(a, .mcp, "cloud/car_status {}", 1000, r);
    try t.expectEqual(.ask, car.action);
    try t.expect(!car.allow_day);
    const lock = f.gate.decide(a, .money, "home/home_guarded {\"device\":\"front_door\",\"action\":\"unlock\"}", 1000, r);
    try t.expectEqual(.ask, lock.action);
    try t.expect(!lock.allow_day);
    // no pages, and nothing of the owner's, whatever the rules say
    try t.expectEqual(.deny, f.act(.fetch, "https://example.com/", r));
    const Call = struct { Tool, []const u8 };
    for ([_]Call{
        .{ .shell, "ls" },   .{ .read_file, "notes.md" }, .{ .write_file, "notes.md" }, .{ .web, "example.com" },
        .{ .recall, "x" },   .{ .remember, "x" },         .{ .history, "x" },           .{ .skill, "x" },
        .{ .delegate, "1" }, .{ .agent_save, "x" },       .{ .trigger, "add x" },       .{ .workflow, "save x" },
        .{ .ask_owner, "x?" }, .{ .snapshot, "notes" },
    }) |c| {
        const d = f.gate.decide(a, c[0], c[1], 1000, r);
        if (d.action != .deny) std.debug.print("{s} {s}: {s}\n", .{ @tagName(c[0]), c[1], @tagName(d.action) });
        try t.expectEqual(.deny, d.action);
        try t.expectEqualStrings("not for speech in the house", d.why);
        try t.expect(!f.gate.memberOffers(c[0], kitchen));
    }
    // it is answered aloud: it posts nowhere, here or elsewhere
    try t.expectEqual(.deny, f.act(.send, "home", .{ .who = kitchen, .here = true }));
    try t.expectEqual(.deny, f.act(.send, "main", r));
    try t.expect(!f.gate.memberOffers(.send, kitchen));
    for ([_]Tool{ .search, .mcp, .money }) |tool| try t.expect(f.gate.memberOffers(tool, kitchen));
}

test "room_and_member_sections_stay_apart" {
    var f: Fixture = undefined;
    try f.init(
        \\allow mcp cloud/car_lock *
        \\deny mcp */home_set *"device":"oven"*
        \\[member]
        \\allow mcp cloud/car_status *
        \\[room]
        \\allow mcp cloud/weather *
        \\allow fetch https://*.wikipedia.org/*
        \\[room:kitchen]
        \\ask mcp cloud/weather *
        \\deny mcp */home_set *"device":"kettle"*
        \\[room:hall]
        \\allow mcp cloud/car_status *
        \\
    );
    defer f.deinit();
    // a member's lines are not speech's, nor speech's a member's
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_status {}", .{ .who = anna }));
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_status {}", .{ .who = kitchen }));
    try t.expectEqual(.ask, f.act(.mcp, "cloud/weather {}", .{ .who = anna }));
    try t.expectEqual(.deny, f.act(.fetch, "https://en.wikipedia.org/wiki/Zig", .{ .who = anna }));
    // a section naming the room first, then [room]
    try t.expectEqual(.ask, f.act(.mcp, "cloud/weather {}", .{ .who = kitchen }));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/weather {}", .{ .who = hall }));
    try t.expectEqual(.allow, f.act(.mcp, "cloud/car_status {}", .{ .who = hall }));
    try t.expectEqual(.allow, f.act(.fetch, "https://en.wikipedia.org/wiki/Zig", .{ .who = kitchen }));
    try t.expect(f.gate.memberOffers(.fetch, kitchen));
    try t.expect(!f.gate.memberOffers(.fetch, anna));
    // the shared part's allow is the owner's; its deny and the room's own deny stop it
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_lock {}", .{ .who = kitchen }));
    try t.expectEqual(.deny, f.act(.mcp, "home/home_set {\"device\":\"oven\",\"action\":\"on\"}", .{ .who = hall }));
    try t.expectEqual(.deny, f.act(.mcp, "home/home_set {\"device\":\"kettle\",\"action\":\"off\"}", .{ .who = kitchen }));
    try t.expectEqual(.allow, f.act(.mcp, "home/home_set {\"device\":\"kettle\",\"action\":\"off\"}", .{ .who = hall }));
    // no grant covers speech
    try f.grants.add(.mcp, "cloud/car_command", 5000);
    try f.grants.addFor(.mcp, "", "cloud/car_command", "agent:main", 5000);
    try f.grants.addFor(.mcp, "", "cloud/car_command", "room:kitchen", 5000);
    try t.expectEqual(.ask, f.act(.mcp, "cloud/car_command {}", .{ .who = kitchen }));
}

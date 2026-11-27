//! What the agent can do. Every call here has already passed the gate;
//! these functions still keep the hard limits (workspace paths, output
//! size, time) and mask stored secrets in everything they return.
const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const jv = @import("jv.zig");
const scrub = @import("scrub.zig");
const gate = @import("gate.zig");
const model = @import("model.zig");
const util = @import("util.zig");
const page = @import("page.zig");
const proc = @import("proc.zig");
const url_mod = @import("url.zig");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

pub const fetch_max = 1 << 20;

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Real path of the workspace.
    workspace: []const u8,
    tool_output_bytes: u32 = 16384,
    /// Longest a shell command may run.
    shell_seconds: u32 = 600,
    secrets: []const scrub.Secret = &.{},
    search_url: []const u8 = "",
    search_key: ?[]const u8 = null,
    /// The only variables a shell command gets (with LANG and TERM).
    path_var: []const u8 = "/usr/local/bin:/usr/bin:/bin",
    home: []const u8 = "",
    /// And, on Windows, the system's own (`util.system_var_names`).
    system_vars: []const util.Var = &.{},
    /// The command's own: folders.ini's `vars` of the folders from the
    /// workspace down to where it starts (host commands only).
    vars: []const util.Var = &.{},
    stop: *std.atomic.Value(bool),
    /// Chrome or Chromium for `browse`; empty: none found.
    browser: []const u8 = "",
    browser_seconds: u32 = 30,
    /// Where a throwaway browser profile goes.
    tmp_root: []const u8 = "",
    /// Decides each redirect of `fetch` and `search` (the agent's gate);
    /// null: only redirects on a host the request already reached.
    redirect: ?Redirect = null,
    /// Unix seconds by which fetch, search and browse must be over (the
    /// turn's end); 0: only their own limits.
    deadline_s: i64 = 0,
};

pub const Output = struct { text: []const u8, is_error: bool = false };

/// What reads a command on this machine, said to the model: it can't tell
/// from the tool's name, and asked for `dir /b` and `ls` at once when it
/// wasn't told (two questions to the owner for one listing).
pub const shell_words = if (@import("builtin").os.tag == .windows)
    " On this machine the shell is Windows' cmd.exe (dir, type, findstr); for more, powershell -NoProfile -Command \"...\"."
else
    " On this machine the shell is /bin/sh.";

pub fn defs() []const model.ToolDef {
    return &.{
        .{ .name = "shell", .description = "Run a shell command in the workspace folder. Returns the exit code and output." ++ shell_words, .schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}" },
        .{ .name = "read_file", .description = "Read a text file in the workspace.", .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}" },
        .{ .name = "write_file", .description = "Write a text file in the workspace, replacing it if it exists.", .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}" },
        .{ .name = "fetch", .description = "Fetch a web page or API over http(s) with GET. Pages come back as readable text (headings, lists, tables, links), in parts: a long page says where the next part starts.", .schema_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"start\":{\"type\":\"integer\",\"description\":\"where to continue a long page\"}},\"required\":[\"url\"]}" },
        .{ .name = "browse", .description = "Like fetch, but the page is first rendered by a headless browser, for pages built by JavaScript. Slower; use fetch first.", .schema_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"start\":{\"type\":\"integer\"}},\"required\":[\"url\"]}" },
        .{ .name = "search", .description = "Search the web. Returns titles, links and snippets.", .schema_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}" },
        .{ .name = "recall", .description = "Search your memory of the owner for these words.", .schema_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}" },
        .{ .name = "remember", .description = "Save a short fact about the owner or their wishes for later conversations.", .schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}" },
    };
}

/// The argument the gate matches for a call, from its JSON input.
pub fn mainArg(arena: std.mem.Allocator, tool: gate.Tool, input_json: []const u8) ![]const u8 {
    const v = jv.parse(arena, input_json) orelse return error.BadInput;
    const key = switch (tool) {
        .shell => "command",
        .read_file, .write_file => "path",
        .fetch, .browse => "url",
        .search, .recall => "query",
        // the words, or the run (history.gateArg); people.gateArg
        .history, .people => return error.NotHere,
        .remember => "text",
        .skill, .skill_save => "name",
        .snapshot => "folder",
        // the agent builds these arguments itself
        .delegate, .mcp, .money, .web, .login => return error.NotHere,
        // the platform's kinds: their tools are not here (yet)
        .send, .ask_owner, .mail, .trigger, .workflow, .agent_save, .app_read, .app_draft, .app_save, .env_save => return error.NotHere,
    };
    return jv.str(jv.get(v, key)) orelse error.BadInput;
}

/// Runs a tool other than recall/remember (the agent handles those).
pub fn run(env: Env, arena: std.mem.Allocator, tool: gate.Tool, input_json: []const u8) !Output {
    const raw = runRaw(env, arena, tool, input_json) catch |e| Output{ .text = switch (e) {
        error.TimeUp => "not finished: the turn's time is up",
        error.Stopped => "stopped by the owner",
        else => try std.fmt.allocPrint(arena, "failed: {s}", .{@errorName(e)}),
    }, .is_error = true };
    var s = try scrub.Scrubber.init(arena, env.secrets);
    const text = try s.scrubAlloc(arena, raw.text);
    return .{ .text = text, .is_error = raw.is_error };
}

fn runRaw(env: Env, arena: std.mem.Allocator, tool: gate.Tool, input_json: []const u8) !Output {
    const arg = try mainArg(arena, tool, input_json);
    return switch (tool) {
        .shell => shell(env, arena, arg, jv.str(jv.get(jv.parse(arena, input_json), "dir")) orelse ""),
        .read_file => {
            const p = try gate.confine(arena, env.io, env.workspace, arg);
            const data = Io.Dir.cwd().readFileAlloc(env.io, p, arena, .limited(fetch_max)) catch |e| switch (e) {
                error.StreamTooLong => return .{ .text = "file is larger than 1 MiB", .is_error = true },
                else => return e,
            };
            return .{ .text = capText(arena, try mask(arena, env.secrets, data, true), env.tool_output_bytes) };
        },
        .write_file => {
            const p = try gate.confine(arena, env.io, env.workspace, arg);
            const v = jv.parse(arena, input_json).?;
            const content = jv.str(jv.get(v, "content")) orelse return error.BadInput;
            if (std.fs.path.dirname(p)) |d| try Io.Dir.cwd().createDirPath(env.io, d);
            // check again now that the folders exist
            const cf = try gate.confined(arena, env.io, env.workspace, arg);
            if (cf.link) return .{ .text = "a symbolic link: files are not written through one", .is_error = true };
            try writeNoFollow(env.io, p, content);
            return .{ .text = try std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, arg }) };
        },
        .fetch => fetch(env, arena, arg, startOf(arena, input_json)),
        .browse => browse(env, arena, arg, startOf(arena, input_json)),
        .search => search(env, arena, arg),
        // the agent reads the log itself
        .history => error.NotHere,
        .recall, .remember, .delegate, .skill, .skill_save, .mcp, .money, .web, .login => error.NotHere,
        .send, .ask_owner, .mail, .trigger, .workflow, .agent_save, .app_read, .app_draft, .app_save, .env_save, .snapshot, .people => error.NotHere,
    };
}

/// Writes `p` as a new file, or over the regular file that is there; never
/// through a symlink, even one made since the gate looked.
fn writeNoFollow(io: Io, p: []const u8, content: []const u8) !void {
    // read access too: Windows refuses to stat a handle opened only to
    // write (AccessDenied), and the check below needs the stat
    var f = Io.Dir.cwd().createFile(io, p, .{ .exclusive = true, .read = true }) catch |e| switch (e) {
        error.PathAlreadyExists => blk: {
            // not a pipe either: opening one would wait for a reader
            if ((try Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false })).kind != .file) return error.NotAFile;
            break :blk try Io.Dir.cwd().openFile(io, p, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false });
        },
        else => return e,
    };
    defer f.close(io);
    // Windows opens the link itself rather than refusing it
    if ((try f.stat(io)).kind != .file) return error.NotAFile;
    try f.setLength(io, 0);
    try f.writeStreamingAll(io, content);
}

/// `raw` with the stored secrets masked, before anything is cut from it.
/// When `raw` is only the start of a longer output (`whole` false), a tail
/// that could be the start of a value is left out, so a value cut in two
/// is never half shown.
pub fn mask(arena: std.mem.Allocator, secrets: []const scrub.Secret, raw: []const u8, whole: bool) ![]const u8 {
    if (secrets.len == 0) return raw;
    var s = try scrub.Scrubber.init(arena, secrets);
    var w: Io.Writer.Allocating = .init(arena);
    s.feed(raw, &w.writer) catch return error.OutOfMemory;
    if (whole) s.finish(&w.writer) catch return error.OutOfMemory;
    return w.written();
}

/// At most `max` bytes of `s`, never inside a UTF-8 sequence, saying so
/// when cut. Mask first: see `mask`.
pub fn capText(arena: std.mem.Allocator, s: []const u8, max: u32) []const u8 {
    if (s.len <= max) return s;
    return std.fmt.allocPrint(arena, "{s}\n[output cut at {d} bytes of {d}]", .{ util.cut(s, max), max, s.len }) catch util.cut(s, max);
}

// ---- shell ----

const Collector = struct {
    mutex: Io.Mutex = .init,
    buf: std.ArrayList(u8) = .empty,
    total: usize = 0,
    cap: usize,
    gpa: std.mem.Allocator,
    finished: std.atomic.Value(u32) = .init(0),

    /// Reads until the pipe closes or `ended` is set, so a process that
    /// kept the pipe open can't hold us (see proc.waitReadable).
    fn pumpUntil(c: *Collector, io: Io, from: Io.File, ended: *std.atomic.Value(bool)) void {
        var chunk: [8192]u8 = undefined;
        while (proc.waitReadable(io, from, ended)) {
            const got = from.readStreaming(io, &.{&chunk}) catch break;
            if (got == 0) break;
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            c.total += got;
            const room = c.cap -| c.buf.items.len;
            c.buf.appendSlice(c.gpa, chunk[0..@min(room, got)]) catch {};
        }
        _ = c.finished.fetchAdd(1, .acq_rel);
    }
};

const Watch = struct {
    io: Io,
    id: std.process.Child.Id,
    /// Windows: the command's job (what it started is in it).
    job: *const proc.Job,
    stop: *std.atomic.Value(bool),
    deadline_ns: i128,
    done: std.atomic.Value(bool) = .init(false),
    reason: ?[]const u8 = null,

    fn run(w: *Watch) void {
        while (!w.done.load(.acquire)) {
            const now = Io.Clock.awake.now(w.io).nanoseconds;
            if (w.stop.load(.acquire)) {
                w.reason = "stopped by the owner";
                break;
            }
            if (now >= w.deadline_ns) {
                w.reason = "time limit reached";
                break;
            }
            w.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        if (w.reason != null) w.killAll();
    }

    /// The whole process group on POSIX, the job on Windows, so children
    /// started in the background go too.
    fn killAll(w: *Watch) void {
        if (is_windows) {
            w.job.kill(w.id);
        } else {
            std.posix.kill(-w.id, .KILL) catch {};
            std.posix.kill(w.id, .KILL) catch {};
        }
    }
};

/// Kills process group `pgid` until it is empty, for up to 1 s: a child
/// forked while the first kill landed can miss that kill, and one kill
/// would leave it running.
fn sweepGroup(io: Io, pgid: std.posix.pid_t) void {
    var waited: u32 = 0;
    while (waited < 1000) : (waited += 20) {
        // no process left in the group (or none we may signal): done
        std.posix.kill(-pgid, .KILL) catch return;
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
}

/// Runs `command` in `dir` (a folder in the workspace; "" the workspace).
fn shell(env: Env, arena: std.mem.Allocator, command: []const u8, dir: []const u8) !Output {
    const cwd = if (dir.len == 0) env.workspace else blk: {
        const p = gate.confine(arena, env.io, env.workspace, dir) catch return .{ .text = "dir is outside the workspace", .is_error = true };
        const st = Io.Dir.cwd().statFile(env.io, p, .{}) catch null;
        if (st == null or st.?.kind != .directory) return .{ .text = try std.fmt.allocPrint(arena, "not a folder in the workspace: {s}", .{dir}), .is_error = true };
        break :blk p;
    };
    var vars = std.process.Environ.Map.init(arena);
    for (env.system_vars) |v| try vars.put(v.name, v.value);
    // folders.ini can't name the ones below (nor the system's)
    for (env.vars) |v| try vars.put(v.name, v.value);
    try vars.put("PATH", env.path_var);
    if (env.home.len > 0) try vars.put("HOME", env.home);
    try vars.put("LANG", "C.UTF-8");
    try vars.put("TERM", "dumb");
    // Windows: in a job before it can start anything (see proc.zig)
    var job = proc.Job.create();
    defer job.close();
    var child = if (is_windows)
        // cmd reads the command as typed, quotes and all (proc.cmdLine)
        try proc.spawnRaw(env.io, arena, .{
            .app = try std.fs.path.join(arena, &.{ try proc.systemDir(arena), "cmd.exe" }),
            .command_line = try proc.cmdLine(arena, command),
            .env = &vars,
            .cwd = cwd,
        })
    else
        try std.process.spawn(env.io, .{
            .argv = &.{ "/bin/sh", "-c", command },
            .cwd = .{ .path = cwd },
            .environ_map = &vars,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        });
    job.adopt(&child);
    return runChild(env, arena, &child, &job);
}

/// What a started command writes, under the shell's limits: its output
/// masked and capped, and the time limit and a stop ending every process
/// it started (its process group on POSIX, `job` on Windows), as when it
/// ends by itself. `child` has stdout and stderr as pipes; on POSIX it
/// leads its own process group, on Windows `job` has adopted it.
pub fn runChild(env: Env, arena: std.mem.Allocator, child: *std.process.Child, job: *proc.Job) !Output {
    // more than is shown: masking can shorten it, and a value cut at the
    // end is left out
    var col: Collector = .{ .cap = @as(usize, env.tool_output_bytes) * 2 + 4096, .gpa = arena };
    var watch: Watch = .{
        .io = env.io,
        .id = child.id.?,
        .job = job,
        .stop = env.stop,
        .deadline_ns = Io.Clock.awake.now(env.io).nanoseconds + @as(i128, env.shell_seconds) * std.time.ns_per_s,
    };
    const th_watch = try std.Thread.spawn(.{}, Watch.run, .{&watch});
    var term: ?std.process.Child.Term = null;
    {
        // the pipes are ours: `wait` must not close them under the readers
        const out_f = child.stdout.?;
        const err_f = child.stderr.?;
        child.stdout = null;
        child.stderr = null;
        defer out_f.close(env.io);
        defer err_f.close(env.io);
        var ended: std.atomic.Value(bool) = .init(false);
        const th_out = try std.Thread.spawn(.{}, Collector.pumpUntil, .{ &col, env.io, out_f, &ended });
        const th_err = try std.Thread.spawn(.{}, Collector.pumpUntil, .{ &col, env.io, err_f, &ended });
        term = child.wait(env.io) catch null;
        // nothing the command started may outlive it
        if (is_windows) job.kill(null) else sweepGroup(env.io, watch.id);
        // what is left in the pipes, for up to 2 s; a process that left the
        // group and kept them open is not waited for
        var waited: u32 = 0;
        while (col.finished.load(.acquire) < 2 and waited < 2000) : (waited += 20) env.io.sleep(.fromMilliseconds(20), .awake) catch {};
        ended.store(true, .release);
        th_out.join();
        th_err.join();
    }
    watch.done.store(true, .release);
    th_watch.join();

    var out: std.ArrayList(u8) = .empty;
    if (watch.reason) |r| {
        try out.print(arena, "[{s}]\n", .{r});
    } else if (term) |tm| switch (tm) {
        .exited => |code| try out.print(arena, "exit code {d}\n", .{code}),
        else => try out.print(arena, "ended: {s}\n", .{@tagName(tm)}),
    };
    const whole = col.total == col.buf.items.len;
    const masked = try mask(arena, env.secrets, col.buf.items, whole);
    const shown = util.cut(masked, env.tool_output_bytes);
    try out.appendSlice(arena, shown);
    if (!whole or shown.len < masked.len) try out.print(arena, "\n[output cut at {d} bytes of {d}]", .{ env.tool_output_bytes, if (whole) masked.len else col.total });
    const failed = watch.reason != null or if (term) |tm| !(tm == .exited and tm.exited == 0) else true;
    return .{ .text = out.items, .is_error = failed };
}

// ---- web ----

pub const Got = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
    truncated: bool,
    /// Where the answer came from: the address asked for, or where its
    /// redirects led.
    url: []const u8 = "",
    /// Redirects followed.
    redirects: u8 = 0,
    /// A redirect that was not followed, and why; `status` is then the
    /// redirect's own and `url` the address that answered with it.
    stopped: ?Stopped = null,
    /// The answer's ETag and Last-Modified ("" for none), and how long it
    /// asked to wait before the next request.
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    retry_after_s: ?u32 = null,

    pub const Stopped = struct { to: []const u8, why: []const u8 };
};

/// Most redirects one request follows.
pub const max_redirects = 5;

/// Decides each redirect of a request: null when it may be followed, else
/// why not. `known_host`: the request has already reached that host.
pub const Redirect = struct {
    ctx: *anyopaque,
    allow: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, url: []const u8, known_host: bool) ?[]const u8,
};

/// What ends a request before its own limits (30 s without a byte, 2
/// minutes a hop).
pub const Until = struct {
    /// Unix seconds by which every hop must be over (the turn's end):
    /// error.TimeUp; 0: none.
    deadline_s: i64 = 0,
    /// Set: the hop under way ends, and no other starts (error.Stopped).
    stop: ?*const std.atomic.Value(bool) = null,

    fn stopped(u: Until) bool {
        const f = u.stop orelse return false;
        return f.load(.acquire);
    }

    /// Milliseconds left until the deadline; null for none.
    fn leftMs(u: Until, io: Io) ?i64 {
        if (u.deadline_s == 0) return null;
        return u.deadline_s * 1000 - nowMs(io);
    }
};

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// GET `url`, reading at most `max` bytes of the body. Up to
/// `max_redirects` redirects are followed, never from https to http, each
/// only if `redirect` allows it (without one: only those on a host already
/// reached); `headers` are not sent on once the host changes.
pub fn get(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, raw_url: []const u8, headers: []const std.http.Header, max: usize, redirect: ?Redirect) !Got {
    return getUntil(gpa, io, arena, raw_url, headers, max, redirect, .{});
}

/// `get`, every hop over by `until`'s deadline, and ended by its stop.
pub fn getUntil(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, raw_url: []const u8, headers: []const std.http.Header, max: usize, redirect: ?Redirect, until: Until) !Got {
    // the address as the gate read it (see url.zig): the host it decided
    // on is the one reached
    var cur = url_mod.parse(arena, raw_url) catch |e| return if (e == error.OutOfMemory) e else error.BadUrl;
    var hdrs = headers;
    var hosts: std.ArrayList([]const u8) = .empty;
    try hosts.append(arena, cur.host_port);
    var hops: u8 = 0;
    while (true) {
        if (until.stopped()) return error.Stopped;
        var g = try getOne(gpa, io, arena, cur, hdrs, max, until);
        g.got.redirects = hops;
        const loc = g.location orelse return g.got;
        const to = resolveUrl(arena, cur.href, loc) catch {
            g.got.stopped = .{ .to = loc, .why = "its address is not valid" };
            return g.got;
        };
        var next: url_mod.Url = undefined;
        const why: ?[]const u8 = blk: {
            if (hops >= max_redirects) break :blk "more than 5 redirects";
            if (hopRefusal(arena, cur.href, to)) |w| break :blk w;
            next = try url_mod.parse(arena, to);
            const known = for (hosts.items) |h| {
                if (std.mem.eql(u8, h, next.host_port)) break true;
            } else false;
            if (redirect) |r| break :blk r.allow(r.ctx, arena, next.href, known);
            break :blk if (known) null else "redirects to another host are not followed here";
        };
        if (why) |w| {
            g.got.stopped = .{ .to = if (url_mod.parse(arena, to)) |n| n.href else |_| to, .why = w };
            return g.got;
        }
        // what was meant for one host does not go on to another
        if (!std.mem.eql(u8, next.host_port, cur.host_port)) hdrs = &.{};
        try hosts.append(arena, next.host_port);
        cur = next;
        hops += 1;
    }
}

/// Why a redirect from `from` to `to` is never followed, whatever the
/// gate says; null if it may be.
pub fn hopRefusal(arena: std.mem.Allocator, from: []const u8, to: []const u8) ?[]const u8 {
    const n = url_mod.parse(arena, to) catch |e| return switch (e) {
        error.NotWeb => "it does not lead to an http or https address",
        error.UserInfo => "it leads to an address with a name before @, whose host is what follows the @",
        else => url_mod.why(e),
    };
    if (std.ascii.startsWithIgnoreCase(from, "https://") and !n.https) return "it leads from https to http";
    return null;
}

fn isRedirect(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

/// `loc` (a Location header) read against `base`; fragments dropped. A
/// name before @ is kept, so that url.parse sees it and refuses it.
fn resolveUrl(arena: std.mem.Allocator, base: []const u8, loc: []const u8) ![]const u8 {
    const base_uri = std.Uri.parse(base) catch return error.BadUrl;
    if (loc.len == 0 or std.mem.indexOfAny(u8, loc, " \r\n\t") != null) return error.BadUrl;
    const buf = try arena.alloc(u8, loc.len * 2 + base.len + 8);
    @memcpy(buf[0..loc.len], loc);
    var aux: []u8 = buf;
    const uri = base_uri.resolveInPlace(loc.len, &aux) catch return error.BadUrl;
    const out = try std.fmt.allocPrint(arena, "{f}", .{uri.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true })});
    // "HTTPS://…" works as well as "https://…" from here on
    for (out[0..uri.scheme.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

/// One request, no redirects followed; a redirect comes back with its
/// location.
const One = struct { got: Got, location: ?[]const u8 };

fn getOne(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, u: url_mod.Url, headers: []const std.http.Header, max: usize, until: Until) !One {
    // a hop gets what is left of the turn, no more
    var total_ms: u32 = 120_000;
    if (until.leftMs(io)) |left| {
        if (left <= 0) return error.TimeUp;
        total_ms = @intCast(@min(left, total_ms));
    }
    var c = http.Client.init(gpa, io, .{ .https = u.https, .host = u.connectHost(), .port = u.port, .prefix = "" });
    defer c.deinit();
    var resp = c.send(.{ .method = .GET, .path = u.target, .headers = headers, .limits = .{ .idle_ms = @min(30_000, total_ms), .total_ms = total_ms, .stop = until.stop } }) catch |e| return cutShort(e, io, until);
    defer resp.deinit();
    const ct = try arena.dupe(u8, resp.contentType());
    const etag = if (resp.etag) |x| try arena.dupe(u8, x) else "";
    const modified = if (resp.last_modified) |x| try arena.dupe(u8, x) else "";
    if (isRedirect(resp.status)) if (resp.location) |l| {
        // a redirect's own body is not wanted
        return .{ .got = .{ .status = resp.status, .content_type = ct, .body = "", .truncated = false, .url = u.href, .retry_after_s = resp.retry_after_s }, .location = try arena.dupe(u8, l) };
    };
    var body: std.ArrayList(u8) = .empty;
    var truncated = false;
    while (resp.next() catch |e| return cutShort(e, io, until)) |part| {
        const room = max - body.items.len;
        if (part.len > room) {
            try body.appendSlice(arena, part[0..room]);
            truncated = true;
            break;
        }
        try body.appendSlice(arena, part);
    }
    return .{ .got = .{ .status = resp.status, .content_type = ct, .body = body.items, .truncated = truncated, .url = u.href, .etag = etag, .last_modified = modified, .retry_after_s = resp.retry_after_s }, .location = null };
}

/// A request that failed: because of /stop or the turn's end, when one of
/// them came, else as it failed.
fn cutShort(e: http.Error, io: Io, until: Until) (http.Error || error{ Stopped, TimeUp }) {
    if (until.stopped()) return error.Stopped;
    if (e == error.Timeout) if (until.leftMs(io)) |left| if (left <= 100) return error.TimeUp;
    return e;
}

fn isText(ct: []const u8) bool {
    if (ct.len == 0) return true;
    return std.ascii.startsWithIgnoreCase(ct, "text/") or std.ascii.findIgnoreCase(ct, "json") != null or std.ascii.findIgnoreCase(ct, "xml") != null;
}

fn startOf(arena: std.mem.Allocator, input_json: []const u8) usize {
    const v = jv.parse(arena, input_json) orelse return 0;
    const n = jv.int(jv.get(v, "start")) orelse return 0;
    return if (n > 0) @intCast(n) else 0;
}

fn fetch(env: Env, arena: std.mem.Allocator, url: []const u8, start: usize) !Output {
    const g = try getUntil(env.gpa, env.io, arena, url, &.{}, fetch_max, env.redirect, limitsOf(env));
    var head: std.ArrayList(u8) = .empty;
    // the status, and where it came from when that is not where it was asked
    try head.print(arena, "status {d}", .{g.status});
    if (g.redirects > 0) try head.print(arena, " from {s} (after {d} redirect{s})", .{ g.url, g.redirects, if (g.redirects == 1) "" else "s" });
    if (g.stopped) |st| return .{ .text = try std.fmt.allocPrint(arena, "{s}: the redirect to {s} was not followed: {s}", .{ head.items, st.to, st.why }), .is_error = true };
    try head.append(arena, '\n');
    if (!isText(g.content_type)) return .{ .text = try std.fmt.allocPrint(arena, "not text ({s}); only text pages are fetched", .{g.content_type}), .is_error = true };
    var text: []const u8 = g.body;
    if (std.ascii.findIgnoreCase(g.content_type, "html") != null) {
        const pg = try page.extract(arena, g.body, g.url);
        if (pg.title.len > 0) try head.print(arena, "title: {s}\n", .{pg.title});
        text = pg.text;
    }
    if (g.truncated) try head.appendSlice(arena, "[page cut at 1 MiB]\n");
    // masked whole before it is cut into parts: a value across two parts
    // would be half shown in each
    text = try mask(arena, env.secrets, text, !g.truncated);
    return .{ .text = try textPart(env, arena, head.items, text, g.url, start), .is_error = g.status >= 400 };
}

/// What ends fetch and search besides their own limits: the turn's end, /stop.
fn limitsOf(env: Env) Until {
    return .{ .deadline_s = env.deadline_s, .stop = env.stop };
}

fn browse(env: Env, arena: std.mem.Allocator, url: []const u8, start: usize) !Output {
    if (env.browser.len == 0) return .{ .text = "no Chrome or Chromium found (set [browser] path in config.ini); use fetch instead", .is_error = true };
    // what is left of the turn, to the millisecond
    var limit_ms: u32 = env.browser_seconds *| 1000;
    if (limitsOf(env).leftMs(env.io)) |left| {
        if (left <= 0) return error.TimeUp;
        limit_ms = @intCast(@min(left, limit_ms));
    }
    const html = page.render(env.gpa, env.io, arena, env.browser, url, if (env.tmp_root.len > 0) env.tmp_root else env.workspace, env.stop, limit_ms, 4 << 20, .{ .path = env.path_var, .home = env.home, .system = env.system_vars }) catch |e|
        return .{ .text = try std.fmt.allocPrint(arena, "the browser failed: {s}", .{@errorName(e)}), .is_error = true };
    const pg = try page.extract(arena, html, url);
    var head: std.ArrayList(u8) = .empty;
    if (pg.title.len > 0) try head.print(arena, "title: {s}\n", .{pg.title});
    return .{ .text = try textPart(env, arena, head.items, try mask(arena, env.secrets, pg.text, true), url, start) };
}

/// One part of a long text, with where the next one starts.
fn textPart(env: Env, arena: std.mem.Allocator, head: []const u8, text: []const u8, url: []const u8, start: usize) ![]const u8 {
    const room = @max(env.tool_output_bytes, 600) - 300;
    if (start > text.len) return std.fmt.allocPrint(arena, "{s}nothing at {d}: the text is {d} bytes", .{ head, start, text.len });
    const c = page.chunk(text, start, room);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, head);
    if (start > 0 or c.next != null) try out.print(arena, "[bytes {d}-{d} of {d}]\n", .{ start, start + c.text.len, c.total });
    try out.appendSlice(arena, c.text);
    if (c.next) |n| {
        try out.appendSlice(arena, "\n[more: continue with {\"url\":");
        try util.jsonString(&out, arena, url);
        try out.print(arena, ",\"start\":{d}}}]", .{n});
    }
    return out.items;
}

/// Text of an HTML page: scripts, styles and tags out, entities for the
/// common characters decoded, whitespace runs collapsed.
pub fn stripHtml(arena: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var space = false;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const drop = for ([_][]const u8{ "script", "style" }) |tag| {
                if (html.len > i + 1 + tag.len and std.ascii.eqlIgnoreCase(html[i + 1 .. i + 1 + tag.len], tag)) break tag;
            } else null;
            if (drop) |tag| {
                const close = try std.fmt.allocPrint(arena, "</{s}", .{tag});
                i = if (std.ascii.findIgnoreCasePos(html, i, close)) |e| e + close.len else html.len;
            }
            i = if (std.mem.indexOfScalarPos(u8, html, i, '>')) |e| e + 1 else html.len;
            space = true;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            space = true;
            i += 1;
            continue;
        }
        if (space and out.items.len > 0) try out.append(arena, ' ');
        space = false;
        if (c == '&') {
            const ents = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&nbsp;", " " } };
            const hit = for (ents) |e| {
                if (std.mem.startsWith(u8, html[i..], e[0])) break e;
            } else null;
            if (hit) |e| {
                try out.appendSlice(arena, e[1]);
                i += e[0].len;
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

fn search(env: Env, arena: std.mem.Allocator, query: []const u8) !Output {
    const key = env.search_key orelse return .{ .text = "web search is not set up: no search API key stored", .is_error = true };
    var url: std.ArrayList(u8) = .empty;
    try url.print(arena, "{s}/res/v1/web/search?count=8&q=", .{std.mem.trimEnd(u8, env.search_url, "/")});
    for (query) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try url.append(arena, c) else try url.print(arena, "%{X:0>2}", .{c});
    }
    const g = try getUntil(env.gpa, env.io, arena, url.items, &.{
        .{ .name = "X-Subscription-Token", .value = key },
        .{ .name = "Accept", .value = "application/json" },
    }, fetch_max, env.redirect, limitsOf(env));
    if (g.stopped) |st| return .{ .text = try std.fmt.allocPrint(arena, "search failed: the redirect to {s} was not followed: {s}", .{ st.to, st.why }), .is_error = true };
    if (g.status != 200) return .{ .text = try std.fmt.allocPrint(arena, "search failed with status {d}", .{g.status}), .is_error = true };
    const v = jv.parse(arena, g.body) orelse return .{ .text = "search answered something that is not JSON", .is_error = true };
    var out: std.ArrayList(u8) = .empty;
    for (jv.arr(jv.at(v, &.{ "web", "results" })) orelse &.{}) |r| {
        try out.print(arena, "{s}\n{s}\n{s}\n\n", .{ jv.str(jv.get(r, "title")) orelse "", jv.str(jv.get(r, "url")) orelse "", jv.str(jv.get(r, "description")) orelse "" });
    }
    if (out.items.len == 0) return .{ .text = "no results" };
    return .{ .text = capText(arena, try mask(arena, env.secrets, out.items, true), env.tool_output_bytes) };
}

// ---- tests ----

const t = std.testing;

const Fix = struct {
    e: model.TestEnv,
    stop: std.atomic.Value(bool) = .init(false),
    env: Env,

    fn init(f: *Fix) !void {
        try f.e.init();
        const a = f.e.arena.allocator();
        try f.e.tmp.dir.createDirPath(t.io, "ws");
        f.stop = .init(false);
        f.env = .{
            .gpa = t.allocator,
            .io = t.io,
            .workspace = try f.e.tmp.dir.realPathFileAlloc(t.io, "ws", a),
            .stop = &f.stop,
            .search_url = try f.e.url(),
            .search_key = "brave-key",
            .secrets = &.{.{ .name = "telegram", .value = "123456:SECRET-bot-token-value" }},
        };
    }

    fn deinit(f: *Fix) void {
        f.e.deinit();
    }

    fn call(f: *Fix, tool: gate.Tool, input: []const u8) !Output {
        return run(f.env, f.e.arena.allocator(), tool, input);
    }
};

test "shell_runs_in_workspace_with_reduced_env" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const o = try f.call(.shell, "{\"command\":\"pwd; env\"}");
    try t.expect(!o.is_error);
    try t.expect(std.mem.startsWith(u8, o.text, "exit code 0\n"));
    try t.expect(std.mem.indexOf(u8, o.text, f.env.workspace) != null);
    try t.expect(std.mem.indexOf(u8, o.text, "TERM=dumb") != null);
    try t.expect(std.mem.indexOf(u8, o.text, "HARNESS") == null);
    try t.expect(std.mem.indexOf(u8, o.text, "USER=") == null);
    const bad = try f.call(.shell, "{\"command\":\"exit 3\"}");
    try t.expect(bad.is_error);
    try t.expect(std.mem.startsWith(u8, bad.text, "exit code 3"));
}

test "system_vars_reach_a_shell_command" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.system_vars = &.{.{ .name = "HARNESS_T_SYSVAR", .value = "from-the-system" }};
    const cmd = if (is_windows) "{\"command\":\"echo %HARNESS_T_SYSVAR%\"}" else "{\"command\":\"echo $HARNESS_T_SYSVAR\"}";
    const o = try f.call(.shell, cmd);
    try t.expect(!o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "from-the-system") != null);
}

fn stopLater(flag: *std.atomic.Value(bool)) void {
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    flag.store(true, .release);
}

test "shell_is_killed_on_stop_with_children" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const th = try std.Thread.spawn(.{}, stopLater, .{&f.stop});
    defer th.join();
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    const o = try f.call(.shell, "{\"command\":\"sleep 30 & sleep 30\"}");
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - start, std.time.ns_per_ms);
    try t.expect(took_ms < 2300);
    try t.expect(o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "stopped by the owner") != null);
}

test "shell_time_limit" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.shell_seconds = 1;
    const o = try f.call(.shell, "{\"command\":\"sleep 20\"}");
    try t.expect(std.mem.indexOf(u8, o.text, "time limit reached") != null);
}

test "output_capped" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.tool_output_bytes = 100;
    const o = try f.call(.shell, "{\"command\":\"yes x | head -c 5000\"}");
    try t.expect(o.text.len < 250);
    try t.expect(std.mem.indexOf(u8, o.text, "[output cut at 100 bytes of 5000]") != null);
}

test "secret_in_output_is_masked" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const o = try f.call(.shell, "{\"command\":\"echo token=123456:SECRET-bot-token-value\"}");
    try t.expect(std.mem.indexOf(u8, o.text, "SECRET") == null);
    try t.expect(std.mem.indexOf(u8, o.text, "token=[secret:telegram]") != null);
}

/// `n` bytes of padding, then the secret of `Fix`: a cut at `n` + 10 bytes
/// falls inside the secret.
fn paddedSecret(a: std.mem.Allocator, n: usize) ![]const u8 {
    const pad = try a.alloc(u8, n);
    @memset(pad, 'x');
    return std.fmt.allocPrint(a, "{s}123456:SECRET-bot-token-value end", .{pad});
}

test "a_secret_cut_by_the_output_limit_is_not_half_shown" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    f.env.tool_output_bytes = 100;
    const text = try paddedSecret(a, 90);
    const sh = try f.call(.shell, try std.fmt.allocPrint(a, "{{\"command\":\"printf '%s' '{s}'\"}}", .{text}));
    try t.expect(std.mem.indexOf(u8, sh.text, "[output cut at 100 bytes of") != null);
    try t.expect(std.mem.indexOf(u8, sh.text, "123456:S") == null);
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/long.txt", .data = text });
    const rd = try f.call(.read_file, "{\"path\":\"long.txt\"}");
    try t.expect(std.mem.indexOf(u8, rd.text, "[output cut at 100 bytes of") != null);
    try t.expect(std.mem.indexOf(u8, rd.text, "123456:S") == null);
}

test "a_secret_across_two_parts_of_a_page_is_masked_in_both" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    // not html, so the text is the body as it is, in parts of 300 bytes
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/s.xml", .data = try paddedSecret(a, 290) });
    f.env.tool_output_bytes = 600;
    const base = try f.e.url();
    var start: usize = 0;
    var parts: usize = 0;
    while (parts < 10) : (parts += 1) {
        const part = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/s.xml\",\"start\":{d}}}", .{ base, start }));
        try t.expect(std.mem.indexOf(u8, part.text, "123456:S") == null);
        try t.expect(std.mem.indexOf(u8, part.text, "bot-token-value") == null);
        const k = std.mem.indexOf(u8, part.text, "\"start\":") orelse break;
        start = try std.fmt.parseInt(usize, part.text[k + 8 .. std.mem.indexOfScalarPos(u8, part.text, k, '}').?], 10);
    }
    try t.expectEqual(1, parts);
}

test "files_confined_to_workspace" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const w = try f.call(.write_file, "{\"path\":\"notes/a.txt\",\"content\":\"hello\"}");
    if (w.is_error) std.debug.print("write_file said: {s}\n", .{w.text});
    try t.expect(!w.is_error);
    const r = try f.call(.read_file, "{\"path\":\"notes/a.txt\"}");
    try t.expectEqualStrings("hello", r.text);
    const out = try f.call(.write_file, "{\"path\":\"../escape.txt\",\"content\":\"x\"}");
    try t.expect(out.is_error);
    try t.expectError(error.FileNotFound, f.e.tmp.dir.access(t.io, "escape.txt", .{}));
}

test "write_file_never_writes_through_a_symlink" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.e.tmp.dir.symLink(t.io, "../outside.txt", "ws/dangle", .{});
    const w = try f.call(.write_file, "{\"path\":\"dangle\",\"content\":\"planted\"}");
    try t.expect(w.is_error);
    try t.expectError(error.FileNotFound, f.e.tmp.dir.access(t.io, "outside.txt", .{}));
    // nor through one to a file that is there
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "target.txt", .data = "before" });
    try f.e.tmp.dir.symLink(t.io, "../target.txt", "ws/to-target", .{});
    try t.expect((try f.call(.write_file, "{\"path\":\"to-target\",\"content\":\"after\"}")).is_error);
    try t.expectEqualStrings("before", try f.e.tmp.dir.readFileAlloc(t.io, "target.txt", f.e.arena.allocator(), .unlimited));
    // a file that is there is replaced
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/plain.txt", .data = "old and long" });
    try t.expect(!(try f.call(.write_file, "{\"path\":\"plain.txt\",\"content\":\"new\"}")).is_error);
    try t.expectEqualStrings("new", try f.e.tmp.dir.readFileAlloc(t.io, "ws/plain.txt", f.e.arena.allocator(), .unlimited));
}

/// Windows: a junction at `link` to the folder `target` (no administrator
/// needed, unlike a symbolic link); the test is skipped if none can be made.
fn junction(link: []const u8, target: []const u8) !void {
    var child = try std.process.spawn(t.io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", link, target }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true });
    const term = try child.wait(t.io);
    if (!(term == .exited and term.exited == 0)) return error.SkipZigTest;
}

/// The call was refused, by an error result or an error.
fn refused(f: *Fix, tool: gate.Tool, input: []const u8) bool {
    const o = f.call(tool, input) catch return true;
    return o.is_error;
}

test "files_are_never_written_or_read_through_a_junction_out_of_the_workspace_windows" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.createDirPath(t.io, "outside");
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "outside/there.txt", .data = "before" });
    try junction(try std.fs.path.join(a, &.{ f.env.workspace, "door" }), try f.e.tmp.dir.realPathFileAlloc(t.io, "outside", a));
    // a new file through it, and one that is there, are not written
    try t.expect(refused(&f, .write_file, "{\"path\":\"door/planted.txt\",\"content\":\"planted\"}"));
    try t.expectError(error.FileNotFound, f.e.tmp.dir.access(t.io, "outside/planted.txt", .{}));
    try t.expect(refused(&f, .write_file, "{\"path\":\"door/there.txt\",\"content\":\"after\"}"));
    try t.expectEqualStrings("before", try f.e.tmp.dir.readFileAlloc(t.io, "outside/there.txt", a, .unlimited));
    // the junction itself is not a file to write
    try t.expect(refused(&f, .write_file, "{\"path\":\"door\",\"content\":\"x\"}"));
    // nor is what is behind it read
    try t.expect(refused(&f, .read_file, "{\"path\":\"door/there.txt\"}"));
    // a plain file in the workspace still is written
    try t.expect(!(try f.call(.write_file, "{\"path\":\"plain.txt\",\"content\":\"new\"}")).is_error);
}

test "fetch_caps_body_and_refuses_binary" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/hello.html", .data = "<html><head><style>p{}</style><script>var x=1;</script></head><body><p>Hello &amp; welcome</p>\n\n<p>second</p></body></html>" });
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/blob.bin", .data = "\x00\x01\x02" });
    const big = try a.alloc(u8, fetch_max + 1000);
    @memset(big, 'a');
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/big.xml", .data = big });
    const base = try f.e.url();
    const pg = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/hello.html\"}}", .{base}));
    try t.expect(std.mem.startsWith(u8, pg.text, "status 200\n"));
    try t.expect(std.mem.indexOf(u8, pg.text, "Hello & welcome") != null);
    try t.expect(std.mem.indexOf(u8, pg.text, "var x") == null);
    const bin = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/blob.bin\"}}", .{base}));
    try t.expect(bin.is_error);
    f.env.tool_output_bytes = 5 * fetch_max;
    const long = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/big.xml\"}}", .{base}));
    try t.expect(std.mem.indexOf(u8, long.text, "[page cut at 1 MiB]") != null);
    try t.expect(long.text.len < fetch_max + 100);
}

/// A redirect gate for tests: says what it was asked, refuses when told to.
const HopLog = struct {
    n: u32 = 0,
    last: []const u8 = "",
    last_known: bool = false,
    refuse: ?[]const u8 = null,

    fn redirect(h: *HopLog) Redirect {
        return .{ .ctx = h, .allow = allow };
    }

    fn allow(ctx: *anyopaque, arena: std.mem.Allocator, url: []const u8, known_host: bool) ?[]const u8 {
        const h: *HopLog = @ptrCast(@alignCast(ctx));
        h.n += 1;
        h.last = arena.dupe(u8, url) catch "";
        h.last_known = known_host;
        return h.refuse;
    }
};

test "fetch_follows_redirects_through_the_gate_and_says_where_it_ended" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const base = try f.e.url();
    const other = try std.fmt.allocPrint(a, "http://localhost:{d}", .{f.e.server.port});
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/a.redirect", .data = "301 /page/b.html" });
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/b.html", .data = "<html><body><p>Landed on b</p></body></html>" });
    var hops: HopLog = .{};
    f.env.redirect = hops.redirect();
    const o = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/a\"}}", .{base}));
    try t.expect(!o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "Landed on b") != null);
    try t.expect(std.mem.indexOf(u8, o.text, try std.fmt.allocPrint(a, "status 200 from {s}/page/b.html (after 1 redirect)", .{base})) != null);
    // the same host still passes the gate (its deny rules), as a known one
    try t.expectEqual(1, hops.n);
    try t.expect(hops.last_known);
    // another host: the gate decides; refused, the redirect is not followed
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/away.redirect", .data = try std.fmt.allocPrint(a, "302 {s}/page/b.html", .{other}) });
    hops.refuse = "denied by the owner";
    const away = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/away\"}}", .{base}));
    try t.expect(away.is_error);
    try t.expect(!hops.last_known);
    try t.expect(std.mem.indexOf(u8, away.text, try std.fmt.allocPrint(a, "status 302: the redirect to {s}/page/b.html was not followed: denied by the owner", .{other})) != null);
    try t.expect(std.mem.indexOf(u8, away.text, "Landed on b") == null);
}

test "redirects_stop_after_five_and_headers_stay_with_their_host" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const base = try f.e.url();
    for (0..6) |i| try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(a, "pages/r{d}.redirect", .{i}), .data = try std.fmt.allocPrint(a, "302 r{d}", .{i + 1}) });
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/r6", .data = "the end" });
    // without a gate only redirects on the same host are followed
    const g = try get(t.allocator, t.io, a, try std.fmt.allocPrint(a, "{s}/page/r0", .{base}), &.{}, 1000, null);
    try t.expectEqual(302, g.status);
    try t.expectEqualStrings("more than 5 redirects", g.stopped.?.why);
    try t.expectEqual(5, g.redirects);
    // a header for one host is not sent on to another
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/h.redirect", .data = try std.fmt.allocPrint(a, "307 http://localhost:{d}/page/r6", .{f.e.server.port}) });
    var hops: HopLog = .{};
    const h = try get(t.allocator, t.io, a, try std.fmt.allocPrint(a, "{s}/page/h", .{base}), &.{.{ .name = "X-Subscription-Token", .value = "brave-key" }}, 1000, hops.redirect());
    try t.expectEqualStrings("the end", h.body);
    try t.expectEqual(1, h.redirects);
    const reqs = try f.e.tmp.dir.readFileAlloc(t.io, "page-requests.jsonl", a, .unlimited);
    var it = std.mem.splitScalar(u8, reqs, '\n');
    var checked: u32 = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"/page/h\"") != null) {
            try t.expect(std.mem.indexOf(u8, line, "brave-key") != null);
            checked += 1;
        }
        if (std.mem.indexOf(u8, line, "\"/page/r6\"") != null) {
            try t.expect(std.mem.indexOf(u8, line, "brave-key") == null);
            checked += 1;
        }
    }
    try t.expectEqual(2, checked);
}

/// A turn's deadline about a second away: the clock counts whole seconds,
/// so `now + 1` can be a moment away and end a call before it is sent.
fn aSecondAway() i64 {
    const s0 = util.nowSeconds(t.io);
    while (util.nowSeconds(t.io) == s0) t.io.sleep(.fromMilliseconds(5), .awake) catch {};
    return s0 + 2;
}

test "fetch_and_search_end_when_the_turns_time_is_up" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const base = try f.e.url();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/slow.html", .data = "<p>late</p>" });
    f.env.deadline_s = aSecondAway();
    const start = Io.Clock.awake.now(t.io);
    const o = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/slow.html?delay_ms=4000\"}}", .{base}));
    try t.expect(start.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 2000);
    try t.expect(o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "time is up") != null);
    // search the same way (a slow stand-in for the search API)
    f.env.search_url = try std.fmt.allocPrint(a, "{s}/page/s?delay_ms=4000&", .{base});
    f.env.deadline_s = aSecondAway();
    const s_start = Io.Clock.awake.now(t.io);
    const s = try f.call(.search, "{\"query\":\"zig\"}");
    try t.expect(s_start.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 2000);
    try t.expect(s.is_error);
    // with no time left nothing is sent: what was, once the stand-in has
    // written both slow requests (it may still be writing the second; on
    // Windows a read then is a sharing violation)
    const before = blk: {
        var waited: u32 = 0;
        while (waited < 8000) : (waited += 20) {
            const text = f.e.tmp.dir.readFileAlloc(t.io, "page-requests.jsonl", a, .unlimited) catch "";
            if (std.mem.count(u8, text, "delay_ms=4000") >= 2) break :blk text;
            t.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        std.debug.print("the stand-in never recorded both slow requests:\n{s}\n", .{f.e.tmp.dir.readFileAlloc(t.io, "page-requests.jsonl", a, .unlimited) catch ""});
        return error.TestTimedOut;
    };
    f.env.deadline_s = util.nowSeconds(t.io) - 1;
    try t.expect((try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/slow.html\"}}", .{base}))).is_error);
    try t.expectEqualStrings(before, try f.e.tmp.dir.readFileAlloc(t.io, "page-requests.jsonl", a, .unlimited));
}

test "stop_ends_a_fetch_under_way" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/slow.html", .data = "<p>late</p>" });
    const th = try std.Thread.spawn(.{}, stopLater, .{&f.stop});
    defer th.join();
    const start = Io.Clock.awake.now(t.io);
    const o = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/slow.html?delay_ms=5000\"}}", .{try f.e.url()}));
    try t.expect(start.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 1500);
    try t.expect(o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "stopped by the owner") != null);
}

test "a_redirect_to_an_address_with_a_name_before_the_at_is_not_followed" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const base = try f.e.url();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/b.html", .data = "<html><body><p>Landed on b</p></body></html>" });
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/u.redirect", .data = try std.fmt.allocPrint(a, "302 http://good.com@127.0.0.1:{d}/page/b.html", .{f.e.server.port}) });
    var hops: HopLog = .{};
    f.env.redirect = hops.redirect();
    const o = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/u\"}}", .{base}));
    try t.expect(o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "was not followed") != null);
    try t.expect(std.mem.indexOf(u8, o.text, "before @") != null);
    try t.expect(std.mem.indexOf(u8, o.text, "Landed on b") == null);
    // the gate is not even asked
    try t.expectEqual(0, hops.n);
}

test "a_redirect_from_https_to_http_or_off_the_web_is_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(hopRefusal(a, "https://a.example/x", "http://a.example/y") != null);
    try t.expect(hopRefusal(a, "https://a.example/x", "file:///etc/passwd") != null);
    try t.expect(hopRefusal(a, "https://a.example/x", "https://a.example@b.example/y") != null);
    try t.expect(hopRefusal(a, "http://a.example/x", "https://b.example/y") == null);
    try t.expect(hopRefusal(a, "https://a.example/x", "https://b.example/y") == null);
}

test "search_returns_titles_and_links" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "search.json", .data = "{\"web\":{\"results\":[{\"title\":\"Zig 0.18 released\",\"url\":\"https://ziglang.org/news/0.18\",\"description\":\"New release\"}]}}" });
    const o = try f.call(.search, "{\"query\":\"zig release\"}");
    try t.expect(!o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "Zig 0.18 released\nhttps://ziglang.org/news/0.18\nNew release") != null);
    f.env.search_key = null;
    try t.expect((try f.call(.search, "{\"query\":\"x\"}")).is_error);
}

test "a_child_that_leaves_the_group_does_not_hang_the_command" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.shell_seconds = 20;
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    // a detached child that keeps the output pipe open, and a background job
    const o = try f.call(.shell, "{\"command\":\"perl -e 'use POSIX; POSIX::setsid(); sleep 8' & sleep 30 & echo started\"}");
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - start, std.time.ns_per_ms);
    try t.expect(took_ms < 5000);
    try t.expect(std.mem.indexOf(u8, o.text, "started") != null);
    try t.expect(std.mem.startsWith(u8, o.text, "exit code 0"));
}

test "shell_stop_ends_what_the_command_started_windows" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.path_var = try proc.systemDir(f.e.arena.allocator());
    // started in the background, it leaves a mark if it lives two seconds
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/bg.cmd", .data = "@ping -n 3 127.0.0.1 >nul\r\n@echo alive> left.txt\r\n" });
    const th = try std.Thread.spawn(.{}, stopLater, .{&f.stop});
    defer th.join();
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    const o = try f.call(.shell, "{\"command\":\"start /b cmd /c bg.cmd & ping -n 30 127.0.0.1 >nul\"}");
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - start, std.time.ns_per_ms);
    try t.expect(took_ms < 2300);
    try t.expect(o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "stopped by the owner") != null);
    // what it started went with it: no mark, even well after
    t.io.sleep(.fromMilliseconds(3000), .awake) catch {};
    try t.expectError(error.FileNotFound, f.e.tmp.dir.statFile(t.io, "ws/left.txt", .{}));
}

test "a_child_that_keeps_the_output_open_does_not_hang_the_command_windows" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.path_var = try proc.systemDir(f.e.arena.allocator());
    f.env.shell_seconds = 20;
    // started in the background, it holds the output pipe for 8 s
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/bg.cmd", .data = "@ping -n 9 127.0.0.1 >nul\r\n" });
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    const o = try f.call(.shell, "{\"command\":\"start /b cmd /c bg.cmd & echo started\"}");
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - start, std.time.ns_per_ms);
    try t.expect(took_ms < 5000);
    try t.expect(std.mem.indexOf(u8, o.text, "started") != null);
    try t.expect(std.mem.startsWith(u8, o.text, "exit code 0"));
}

test "a_command_with_quotes_reads_as_typed_windows" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    f.env.path_var = try proc.systemDir(f.e.arena.allocator());
    try f.e.tmp.dir.createDirPath(t.io, "ws/two words");
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/two words/a b.txt", .data = "quoted path read\r\n" });
    // a path with spaces, quoted, and a quote in what is echoed
    const o = try f.call(.shell, "{\"command\":\"type \\\"two words\\\\a b.txt\\\" && echo say \\\"hi\\\"\"}");
    if (o.is_error) std.debug.print("{s}\n", .{o.text});
    try t.expect(!o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "quoted path read") != null);
    try t.expect(std.mem.indexOf(u8, o.text, "say \"hi\"") != null);
}

test "fetch_gives_readable_text_in_pages" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "<html><head><title>Story</title></head><body><nav>Home | Menu</nav><article><h1>Big news</h1><p>See <a href=\"/more\">more</a>.</p>");
    for (0..60) |i| try body.print(a, "<p>Paragraph {d} of the story goes on for a while.</p>", .{i});
    try body.appendSlice(a, "<p>THE END</p></article><footer>Copyright</footer></body></html>");
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/story.html", .data = body.items });
    f.env.tool_output_bytes = 1000;
    const base = try f.e.url();
    const first = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/story.html\"}}", .{base}));
    try t.expect(!first.is_error);
    try t.expect(std.mem.indexOf(u8, first.text, "# Big news") != null);
    try t.expect(std.mem.indexOf(u8, first.text, try std.fmt.allocPrint(a, "[more]({s}/more)", .{base})) != null);
    try t.expect(std.mem.indexOf(u8, first.text, "Menu") == null);
    try t.expect(std.mem.indexOf(u8, first.text, "THE END") == null);
    const at = std.mem.indexOf(u8, first.text, "\"start\":").?;
    const n = std.fmt.parseInt(usize, first.text[at + 8 .. std.mem.indexOfScalarPos(u8, first.text, at, '}').?], 10) catch unreachable;
    var start = n;
    var found = false;
    for (0..20) |_| {
        const next = try f.call(.fetch, try std.fmt.allocPrint(a, "{{\"url\":\"{s}/page/story.html\",\"start\":{d}}}", .{ base, start }));
        if (std.mem.indexOf(u8, next.text, "THE END") != null) {
            found = true;
            try t.expect(std.mem.indexOf(u8, next.text, "\"start\":") == null);
            break;
        }
        const k = std.mem.indexOf(u8, next.text, "\"start\":").?;
        start = std.fmt.parseInt(usize, next.text[k + 8 .. std.mem.indexOfScalarPos(u8, next.text, k, '}').?], 10) catch unreachable;
    }
    try t.expect(found);
}

test "browse_renders_through_the_browser" {
    if (is_windows) return error.SkipZigTest;
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.e.arena.allocator();
    const none = try f.call(.browse, "{\"url\":\"https://example.com/\"}");
    try t.expect(none.is_error);
    try t.expect(std.mem.indexOf(u8, none.text, "no Chrome or Chromium") != null);
    // a stand-in browser that prints a page made by "JavaScript"
    try f.e.tmp.dir.writeFile(t.io, .{ .sub_path = "chrome.sh", .data = "#!/bin/sh\necho '<html><body><div id=app><p>Rendered by script</p></div></body></html>'\n" });
    const sh = try f.e.tmp.dir.realPathFileAlloc(t.io, "chrome.sh", a);
    try Io.Dir.cwd().setFilePermissions(t.io, sh, .fromMode(0o755), .{});
    f.env.browser = sh;
    f.env.tmp_root = try f.e.tmp.dir.realPathFileAlloc(t.io, ".", a);
    const o = try f.call(.browse, "{\"url\":\"https://example.com/\"}");
    try t.expect(!o.is_error);
    try t.expect(std.mem.indexOf(u8, o.text, "Rendered by script") != null);
}

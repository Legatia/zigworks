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
    /// The only variables a shell command gets.
    path_var: []const u8 = "/usr/local/bin:/usr/bin:/bin",
    home: []const u8 = "",
    stop: *std.atomic.Value(bool),
    /// Chrome or Chromium for `browse`; empty: none found.
    browser: []const u8 = "",
    browser_seconds: u32 = 30,
    /// Where a throwaway browser profile goes.
    tmp_root: []const u8 = "",
};

pub const Output = struct { text: []const u8, is_error: bool = false };

pub fn defs() []const model.ToolDef {
    return &.{
        .{ .name = "shell", .description = "Run a shell command in the workspace folder. Returns the exit code and output.", .schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}" },
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
        .remember => "text",
        .skill, .skill_save => "name",
        // the agent builds these arguments itself
        .delegate, .mcp, .money => return error.NotHere,
    };
    return jv.str(jv.get(v, key)) orelse error.BadInput;
}

/// Runs a tool other than recall/remember (the agent handles those).
pub fn run(env: Env, arena: std.mem.Allocator, tool: gate.Tool, input_json: []const u8) !Output {
    const raw = runRaw(env, arena, tool, input_json) catch |e| Output{ .text = try std.fmt.allocPrint(arena, "failed: {s}", .{@errorName(e)}), .is_error = true };
    var s = try scrub.Scrubber.init(arena, env.secrets);
    const text = try s.scrubAlloc(arena, raw.text);
    return .{ .text = text, .is_error = raw.is_error };
}

fn runRaw(env: Env, arena: std.mem.Allocator, tool: gate.Tool, input_json: []const u8) !Output {
    const arg = try mainArg(arena, tool, input_json);
    return switch (tool) {
        .shell => shell(env, arena, arg),
        .read_file => {
            const p = try gate.confine(arena, env.io, env.workspace, arg);
            const data = Io.Dir.cwd().readFileAlloc(env.io, p, arena, .limited(fetch_max)) catch |e| switch (e) {
                error.StreamTooLong => return .{ .text = "file is larger than 1 MiB", .is_error = true },
                else => return e,
            };
            return .{ .text = capText(arena, data, env.tool_output_bytes) };
        },
        .write_file => {
            const p = try gate.confine(arena, env.io, env.workspace, arg);
            const v = jv.parse(arena, input_json).?;
            const content = jv.str(jv.get(v, "content")) orelse return error.BadInput;
            if (std.fs.path.dirname(p)) |d| try Io.Dir.cwd().createDirPath(env.io, d);
            // check again now that the folders exist
            _ = try gate.confine(arena, env.io, env.workspace, arg);
            try Io.Dir.cwd().writeFile(env.io, .{ .sub_path = p, .data = content });
            return .{ .text = try std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, arg }) };
        },
        .fetch => fetch(env, arena, arg, startOf(arena, input_json)),
        .browse => browse(env, arena, arg, startOf(arena, input_json)),
        .search => search(env, arena, arg),
        .recall, .remember, .delegate, .skill, .skill_save, .mcp, .money => error.NotHere,
    };
}

fn capText(arena: std.mem.Allocator, s: []const u8, max: u32) []const u8 {
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

    /// POSIX: reads until the pipe closes or `ended` is set, looking every
    /// 100 ms, so a process that kept the pipe open can't hold us.
    fn pumpUntil(c: *Collector, io: Io, from: Io.File, ended: *std.atomic.Value(bool)) void {
        var chunk: [8192]u8 = undefined;
        while (!ended.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = from.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;
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

    fn pump(c: *Collector, io: Io, from: Io.File) void {
        var chunk: [8192]u8 = undefined;
        while (true) {
            const got = from.readStreaming(io, &.{&chunk}) catch break;
            if (got == 0) break;
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            c.total += got;
            const room = c.cap -| c.buf.items.len;
            c.buf.appendSlice(c.gpa, chunk[0..@min(room, got)]) catch {};
        }
    }
};

extern "kernel32" fn TerminateProcess(h: std.os.windows.HANDLE, code: u32) callconv(.winapi) std.os.windows.BOOL;

const Watch = struct {
    io: Io,
    id: std.process.Child.Id,
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

    /// The whole process group on POSIX, so children started in the
    /// background go too; the process itself on Windows.
    fn killAll(w: *Watch) void {
        if (is_windows) {
            _ = TerminateProcess(w.id, 1);
        } else {
            std.posix.kill(-w.id, .KILL) catch {};
            std.posix.kill(w.id, .KILL) catch {};
        }
    }
};

fn shell(env: Env, arena: std.mem.Allocator, command: []const u8) !Output {
    var vars = std.process.Environ.Map.init(arena);
    try vars.put("PATH", env.path_var);
    if (env.home.len > 0) try vars.put("HOME", env.home);
    try vars.put("LANG", "C.UTF-8");
    try vars.put("TERM", "dumb");
    const argv: []const []const u8 = if (is_windows) &.{ "cmd.exe", "/c", command } else &.{ "/bin/sh", "-c", command };
    var child = try std.process.spawn(env.io, .{
        .argv = argv,
        .cwd = .{ .path = env.workspace },
        .environ_map = &vars,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (is_windows) null else 0,
        .create_no_window = true,
    });
    var col: Collector = .{ .cap = env.tool_output_bytes, .gpa = arena };
    var watch: Watch = .{
        .io = env.io,
        .id = child.id.?,
        .stop = env.stop,
        .deadline_ns = Io.Clock.awake.now(env.io).nanoseconds + @as(i128, env.shell_seconds) * std.time.ns_per_s,
    };
    const th_watch = try std.Thread.spawn(.{}, Watch.run, .{&watch});
    var term: ?std.process.Child.Term = null;
    if (is_windows) {
        const th_out = try std.Thread.spawn(.{}, Collector.pump, .{ &col, env.io, child.stdout.? });
        const th_err = try std.Thread.spawn(.{}, Collector.pump, .{ &col, env.io, child.stderr.? });
        th_out.join();
        th_err.join();
        term = child.wait(env.io) catch null;
    } else {
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
        std.posix.kill(-watch.id, .KILL) catch {};
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
    try out.appendSlice(arena, col.buf.items);
    if (col.total > col.buf.items.len) try out.print(arena, "\n[output cut at {d} bytes of {d}]", .{ col.cap, col.total });
    const failed = watch.reason != null or if (term) |tm| !(tm == .exited and tm.exited == 0) else true;
    return .{ .text = out.items, .is_error = failed };
}

// ---- web ----

pub const Got = struct { status: u16, content_type: []const u8, body: []const u8, truncated: bool };

/// GET `url`, reading at most `max` bytes of the body.
pub fn get(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, max: usize) !Got {
    const host = gate.urlHost(url) orelse return error.BadUrl;
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(url, "https://")) 8 else 7;
    const path_start = scheme_len + host.len;
    const base = url[0..path_start];
    const rest = if (path_start < url.len) url[path_start..] else "/";
    const p = if (rest[0] == '/') rest else try std.fmt.allocPrint(arena, "/{s}", .{rest});
    if (std.mem.indexOfAny(u8, p, " \r\n") != null) return error.BadUrl;
    var c = http.Client.init(gpa, io, try http.Target.parse(base));
    defer c.deinit();
    var resp = try c.send(.{ .method = .GET, .path = p, .headers = headers, .limits = .{ .idle_ms = 30_000, .total_ms = 120_000 } });
    defer resp.deinit();
    var body: std.ArrayList(u8) = .empty;
    var truncated = false;
    while (try resp.next()) |part| {
        const room = max - body.items.len;
        if (part.len > room) {
            try body.appendSlice(arena, part[0..room]);
            truncated = true;
            break;
        }
        try body.appendSlice(arena, part);
    }
    return .{ .status = resp.status, .content_type = try arena.dupe(u8, resp.contentType()), .body = body.items, .truncated = truncated };
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
    const g = try get(env.gpa, env.io, arena, url, &.{}, fetch_max);
    if (!isText(g.content_type)) return .{ .text = try std.fmt.allocPrint(arena, "not text ({s}); only text pages are fetched", .{g.content_type}), .is_error = true };
    var head: std.ArrayList(u8) = .empty;
    try head.print(arena, "status {d}\n", .{g.status});
    var text: []const u8 = g.body;
    if (std.ascii.findIgnoreCase(g.content_type, "html") != null) {
        const pg = try page.extract(arena, g.body, url);
        if (pg.title.len > 0) try head.print(arena, "title: {s}\n", .{pg.title});
        text = pg.text;
    }
    if (g.truncated) try head.appendSlice(arena, "[page cut at 1 MiB]\n");
    return .{ .text = try textPart(env, arena, head.items, text, url, start), .is_error = g.status >= 400 };
}

fn browse(env: Env, arena: std.mem.Allocator, url: []const u8, start: usize) !Output {
    if (env.browser.len == 0) return .{ .text = "no Chrome or Chromium found (set [browser] path in config.ini); use fetch instead", .is_error = true };
    const html = page.render(env.gpa, env.io, arena, env.browser, url, if (env.tmp_root.len > 0) env.tmp_root else env.workspace, env.stop, env.browser_seconds * 1000, 4 << 20) catch |e|
        return .{ .text = try std.fmt.allocPrint(arena, "the browser failed: {s}", .{@errorName(e)}), .is_error = true };
    const pg = try page.extract(arena, html, url);
    var head: std.ArrayList(u8) = .empty;
    if (pg.title.len > 0) try head.print(arena, "title: {s}\n", .{pg.title});
    return .{ .text = try textPart(env, arena, head.items, pg.text, url, start) };
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
    const g = try get(env.gpa, env.io, arena, url.items, &.{
        .{ .name = "X-Subscription-Token", .value = key },
        .{ .name = "Accept", .value = "application/json" },
    }, fetch_max);
    if (g.status != 200) return .{ .text = try std.fmt.allocPrint(arena, "search failed with status {d}", .{g.status}), .is_error = true };
    const v = jv.parse(arena, g.body) orelse return .{ .text = "search answered something that is not JSON", .is_error = true };
    var out: std.ArrayList(u8) = .empty;
    for (jv.arr(jv.at(v, &.{ "web", "results" })) orelse &.{}) |r| {
        try out.print(arena, "{s}\n{s}\n{s}\n\n", .{ jv.str(jv.get(r, "title")) orelse "", jv.str(jv.get(r, "url")) orelse "", jv.str(jv.get(r, "description")) orelse "" });
    }
    if (out.items.len == 0) return .{ .text = "no results" };
    return .{ .text = capText(arena, out.items, env.tool_output_bytes) };
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

test "files_confined_to_workspace" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const w = try f.call(.write_file, "{\"path\":\"notes/a.txt\",\"content\":\"hello\"}");
    try t.expect(!w.is_error);
    const r = try f.call(.read_file, "{\"path\":\"notes/a.txt\"}");
    try t.expectEqualStrings("hello", r.text);
    const out = try f.call(.write_file, "{\"path\":\"../escape.txt\",\"content\":\"x\"}");
    try t.expect(out.is_error);
    try t.expectError(error.FileNotFound, f.e.tmp.dir.access(t.io, "escape.txt", .{}));
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

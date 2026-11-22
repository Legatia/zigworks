//! MCP servers the agent can use, each a child process speaking
//! newline-delimited JSON-RPC 2.0 on stdin/stdout (`mcp.ini`).
//!
//! One reader thread per server takes lines off its stdout: responses are
//! matched to the one call waiting (by id; late answers to calls that were
//! stopped or timed out are dropped), notifications are skipped but
//! `notifications/resources/updated`, passed on to `updated`, and
//! requests from the server are answered (`ping` with an empty result,
//! anything else with -32601). A second thread drains stderr, keeping the
//! last 2 KB for error messages.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const proc = @import("proc.zig");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

/// Longest line read from a server; longer ones are skipped.
pub const max_line = 16 << 20;
/// Most tools taken from one server.
pub const max_tools = 500;
const protocol_version = "2025-06-18";

// ---- mcp.ini ----

pub const ServerConfig = struct {
    /// Section name, [a-z0-9_-]{1,32} without "__" (the model sees its
    /// tools as "server__tool").
    name: []const u8,
    /// Whole command line, split on spaces; "double quotes" group.
    command: []const u8,
    /// `secret = ENV:storedname, ENV2:name2`
    secrets: []const EnvSecret,
    /// `money = a, b`: tools that move money.
    money: []const []const u8,
    /// `amount =`: where the money tools' inputs hold their amounts.
    amount: Amount = .unset,
    /// `max_per_call =`, `max_per_day =`: this server's money caps; 0 for
    /// `none` (no cap for this server, whatever config.ini says); null:
    /// the ones in config.ini's [money].
    max_per_call: ?u32 = null,
    max_per_day: ?u32 = null,
};

pub const EnvSecret = struct { env: []const u8, secret: []const u8 };

/// Where a money tool's input holds the amount it moves.
pub const Field = union(enum) {
    /// mcp.ini does not say.
    unset,
    /// `tool:none`: the tool moves no amount (like cancelling an order).
    none,
    /// The input field's name.
    name: []const u8,
};

/// `amount =`: one field for every money tool (`amount = notional_usd`),
/// or a field per tool (`amount = place_order:notional_usd,
/// cancel_order:none`).
pub const Amount = union(enum) {
    unset,
    all: []const u8,
    each: []const ToolField,

    pub const ToolField = struct { tool: []const u8, field: Field };

    /// The field holding `tool`'s amount; `.unset` for a tool the list
    /// leaves out.
    pub fn of(am: Amount, tool: []const u8) Field {
        return switch (am) {
            .unset => .unset,
            .all => |f| .{ .name = f },
            .each => |list| for (list) |tf| {
                if (std.mem.eql(u8, tf.tool, tool)) break tf.field;
            } else .unset,
        };
    }
};

/// What is wrong with an mcp.ini line, when more can be said than that it
/// does not read.
pub fn configReason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.ZeroCap => "0 is not a cap here: write none to lift config.ini's cap for this server, or remove the line to use config.ini's",
        else => null,
    };
}

/// A server's cap: a whole number above 0, or `none` (0 here: no cap).
fn parseCap(value: []const u8) error{ BadConfig, ZeroCap }!u32 {
    if (std.mem.eql(u8, value, "none")) return 0;
    const n = std.fmt.parseInt(u32, value, 10) catch return error.BadConfig;
    // "no cap" would lift config.ini's as quietly as a typo: said as none
    if (n == 0) return error.ZeroCap;
    return n;
}

/// Servers in the order they appear. Unknown keys, a missing `command`,
/// bad names and the same server twice are errors.
pub fn parseConfig(arena: std.mem.Allocator, text: []const u8) error{ BadConfig, ZeroCap, OutOfMemory }![]ServerConfig {
    const ls = try config.lines(arena, text);
    var out: std.ArrayList(ServerConfig) = .empty;
    var i: usize = 0;
    while (i < ls.len) {
        const name = ls[i].section;
        if (!validName(name)) return error.BadConfig;
        for (out.items) |o| if (std.mem.eql(u8, o.name, name)) return error.BadConfig;
        var cfg: ServerConfig = .{ .name = name, .command = "", .secrets = &.{}, .money = &.{} };
        var seen: [6]bool = @splat(false);
        while (i < ls.len and std.mem.eql(u8, ls[i].section, name)) : (i += 1) {
            const l = ls[i];
            const keys = [_][]const u8{ "command", "secret", "money", "amount", "max_per_call", "max_per_day" };
            const k = for (keys, 0..) |key, n| {
                if (std.mem.eql(u8, l.key, key)) break n;
            } else return error.BadConfig;
            if (seen[k]) return error.BadConfig;
            seen[k] = true;
            switch (k) {
                0 => {
                    _ = splitCommand(arena, l.value) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.BadConfig,
                    };
                    cfg.command = l.value;
                },
                1 => {
                    var list: std.ArrayList(EnvSecret) = .empty;
                    for (try items(arena, l.value)) |item| {
                        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return error.BadConfig;
                        const env = std.mem.trim(u8, item[0..colon], " \t");
                        const sec = std.mem.trim(u8, item[colon + 1 ..], " \t");
                        if (!validEnv(env) or !validSecretName(sec)) return error.BadConfig;
                        try list.append(arena, .{ .env = env, .secret = sec });
                    }
                    cfg.secrets = list.items;
                },
                2 => {
                    const names = try items(arena, l.value);
                    for (names) |n| if (std.mem.indexOfAny(u8, n, " \t") != null) return error.BadConfig;
                    cfg.money = names;
                },
                3 => cfg.amount = try parseAmount(arena, l.value),
                4 => cfg.max_per_call = try parseCap(l.value),
                5 => cfg.max_per_day = try parseCap(l.value),
                else => unreachable,
            }
        }
        if (cfg.command.len == 0) return error.BadConfig;
        // caps are for money tools: without them they are a mistake
        if ((cfg.max_per_call != null or cfg.max_per_day != null) and cfg.money.len == 0) return error.BadConfig;
        // an amount names money tools: without them it is a mistake
        switch (cfg.amount) {
            .unset => {},
            .all => if (cfg.money.len == 0) return error.BadConfig,
            .each => |list| for (list) |tf| {
                for (cfg.money) |m| {
                    if (std.mem.eql(u8, m, tf.tool)) break;
                } else return error.BadConfig;
            },
        }
        try out.append(arena, cfg);
    }
    return out.items;
}

/// `field` alone, or `tool:field, tool:none, ...` (each tool once). A
/// field alone may not be `none`: that is said per tool.
fn parseAmount(arena: std.mem.Allocator, value: []const u8) error{ BadConfig, OutOfMemory }!Amount {
    if (std.mem.indexOfAny(u8, value, ":,") == null) {
        if (!validField(value) or std.mem.eql(u8, value, "none")) return error.BadConfig;
        return .{ .all = value };
    }
    var list: std.ArrayList(Amount.ToolField) = .empty;
    for (try items(arena, value)) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return error.BadConfig;
        const tool = std.mem.trim(u8, item[0..colon], " \t");
        const field = std.mem.trim(u8, item[colon + 1 ..], " \t");
        if (!validToolName(tool) or !validField(field)) return error.BadConfig;
        for (list.items) |tf| if (std.mem.eql(u8, tf.tool, tool)) return error.BadConfig;
        try list.append(arena, .{ .tool = tool, .field = if (std.mem.eql(u8, field, "none")) .none else .{ .name = field } });
    }
    return .{ .each = list.items };
}

/// An input field's name in mcp.ini: no spaces, commas or colons.
fn validField(f: []const u8) bool {
    return f.len > 0 and std.mem.indexOfAny(u8, f, " \t,:") == null;
}

/// "a, b ,c" → {"a","b","c"}; an empty item is an error.
fn items(arena: std.mem.Allocator, value: []const u8) error{ BadConfig, OutOfMemory }![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) return error.BadConfig;
        try out.append(arena, item);
    }
    return out.items;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or std.mem.indexOf(u8, name, "__") != null) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    return true;
}

/// A stored secret's name, as `harness secret add` takes it: a-z, 0-9,
/// `-` and `_`, at most 64, not starting with `-`. So no name reaches
/// outside the secrets folder or past the Credential Manager's name.
pub fn validSecretName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '-') return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    return true;
}

fn validEnv(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Splits a command line on spaces and tabs; "double quotes" keep spaces
/// in an argument (no escapes inside).
pub fn splitCommand(arena: std.mem.Allocator, cmd: []const u8) error{ BadCommand, OutOfMemory }![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_arg = false;
    var quoted = false;
    for (cmd) |c| {
        if (quoted) {
            if (c == '"') quoted = false else try cur.append(arena, c);
            continue;
        }
        switch (c) {
            '"' => {
                quoted = true;
                in_arg = true;
            },
            ' ', '\t' => if (in_arg) {
                try args.append(arena, cur.items);
                cur = .empty;
                in_arg = false;
            },
            else => {
                try cur.append(arena, c);
                in_arg = true;
            },
        }
    }
    if (quoted) return error.BadCommand;
    if (in_arg) try args.append(arena, cur.items);
    if (args.items.len == 0 or args.items[0].len == 0) return error.BadCommand;
    return args.items;
}

// ---- servers ----

pub const Tool = struct { server: []const u8, name: []const u8, description: []const u8, schema_json: []const u8 };
pub const Result = struct { text: []const u8, is_error: bool };

/// The end of a server's stderr, for saying why it failed to start.
pub const Diag = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    pub fn text(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }
};

pub const StartOptions = struct {
    /// The folder the server runs in: one of its own, never the agent's
    /// workspace, where a file the agent wrote (an .npmrc, a module named
    /// like one the server loads, a .git/config) would become its code or
    /// settings.
    cwd: []const u8,
    path_var: []const u8,
    home: []const u8,
    /// On Windows, the system's own variables (`util.system_var_names`).
    system_vars: []const util.Var = &.{},
    /// `secret_values[i]` is the value for `cfg.secrets[i]`.
    secret_values: []const []const u8,
    start_timeout_ms: u32 = 20000,
    /// When the start must be over (awake clock, ns), spawning included;
    /// several servers started together share one. 0: `start_timeout_ms`.
    deadline_ns: i128 = 0,
    /// When start fails, the end of the server's stderr goes here.
    diag: ?*Diag = null,
    /// Set: the start ends at once (error.Stopped).
    stop: ?*std.atomic.Value(bool) = null,
    /// Where `notifications/resources/updated` goes (a trigger reads the
    /// resource again).
    updated: ?Updated = null,
};

/// Told a resource the server was asked to watch changed: the server's
/// name and the resource's uri. Called on the server's reader thread.
pub const Updated = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, server: []const u8, uri: []const u8) void,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    name: []const u8 = "",
    child: std.process.Child,
    /// The process (and on POSIX its group).
    pid: std.process.Child.Id,
    /// Windows: the server and all it started (see proc.zig).
    job: proc.Job = .{},
    stdin: ?Io.File,
    stdout: Io.File,
    stderr: Io.File,
    tool_list: []Tool = &.{},
    /// It offers `resources/subscribe` (its capabilities say so).
    subscribes: bool = false,
    /// Where `notifications/resources/updated` goes; set before its
    /// reader starts.
    updated: ?Updated = null,

    /// One call at a time.
    call_mutex: Io.Mutex = .init,
    /// Lines written to stdin, by callers and the reader (answers to pings).
    write_mutex: Io.Mutex = .init,
    /// Guards want, got and the stderr tail.
    state_mutex: Io.Mutex = .init,
    next_id: u64 = 1,
    /// The id being waited for; 0 when none.
    want: u64 = 0,
    /// Its response line (gpa), once it came.
    got: ?[]u8 = null,
    err_tail: [2048]u8 = undefined,
    err_len: usize = 0,

    /// stdout closed: the server is gone.
    eof: std.atomic.Value(bool) = .init(false),
    /// stderr closed (its reader ended).
    err_eof: std.atomic.Value(bool) = .init(false),
    /// Tells the readers to stop.
    ended: std.atomic.Value(bool) = .init(false),
    th_out: ?std.Thread = null,
    th_err: ?std.Thread = null,

    /// Starts `cfg.command` in its own process group in `opts.cwd`, with
    /// only PATH, HOME, LANG, TERM and the named secrets in its
    /// environment; then initialize, notifications/initialized and
    /// tools/list.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, cfg: ServerConfig, opts: StartOptions) !*Server {
        if (opts.secret_values.len != cfg.secrets.len) return error.BadSecrets;
        var tmp_state = std.heap.ArenaAllocator.init(gpa);
        defer tmp_state.deinit();
        const tmp = tmp_state.allocator();
        const argv = try splitCommand(tmp, cfg.command);
        var vars = std.process.Environ.Map.init(tmp);
        for (opts.system_vars) |v| try vars.put(v.name, v.value);
        try vars.put("PATH", opts.path_var);
        if (opts.home.len > 0) try vars.put("HOME", opts.home);
        try vars.put("LANG", "C.UTF-8");
        try vars.put("TERM", "dumb");
        for (cfg.secrets, opts.secret_values) |sec, val| try vars.put(sec.env, val);

        // Windows: in a job before it can start anything (see proc.zig)
        var job = proc.Job.create();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = opts.cwd },
            .environ_map = &vars,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (is_windows) null else 0,
            .start_suspended = is_windows,
            .create_no_window = true,
        }) catch |e| {
            job.close();
            return e;
        };
        job.adopt(&child);
        // the pipes are ours: `wait` must not close them under the readers
        const s = gpa.create(Server) catch |e| {
            killTree(child.id.?, &job);
            _ = child.wait(io) catch {};
            job.close();
            return e;
        };
        s.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = .init(gpa),
            .child = child,
            .pid = child.id.?,
            .job = job,
            .stdin = child.stdin.?,
            .stdout = child.stdout.?,
            .stderr = child.stderr.?,
            .updated = opts.updated,
        };
        s.child.stdin = null;
        s.child.stdout = null;
        s.child.stderr = null;
        errdefer {
            // it never answered: no grace for it
            s.shutdownWith(0);
            if (opts.diag) |d| {
                @memcpy(d.buf[0..s.err_len], s.err_tail[0..s.err_len]);
                d.len = s.err_len;
            }
            s.free();
        }
        s.th_out = try std.Thread.spawn(.{}, readOut, .{s});
        s.th_err = try std.Thread.spawn(.{}, readErr, .{s});
        const a = s.arena_state.allocator();
        s.name = try a.dupe(u8, cfg.name);

        var never: std.atomic.Value(bool) = .init(false);
        const stop = opts.stop orelse &never;
        const deadline = if (opts.deadline_ns > 0) opts.deadline_ns else nowNs(io) + @as(i128, opts.start_timeout_ms) * std.time.ns_per_ms;
        const init_raw = try s.request(tmp, "initialize", "{\"protocolVersion\":\"" ++ protocol_version ++ "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"harness\",\"version\":\"" ++ @import("build_options").version ++ "\"}}", stop, deadline);
        const init_v = jv.parse(tmp, init_raw) orelse return error.BadResponse;
        if (jv.get(init_v, "result") == null) return error.InitFailed;
        s.subscribes = jv.boolean(jv.at(init_v, &.{ "result", "capabilities", "resources", "subscribe" })) orelse false;
        try s.send(tmp, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");

        var list: std.ArrayList(Tool) = .empty;
        var cursor: ?[]const u8 = null;
        var pages: u32 = 0;
        while (pages < 100 and list.items.len < max_tools) : (pages += 1) {
            var params: std.ArrayList(u8) = .empty;
            try params.appendSlice(tmp, "{");
            if (cursor) |c| {
                try params.appendSlice(tmp, "\"cursor\":");
                try util.jsonString(&params, tmp, c);
            }
            try params.appendSlice(tmp, "}");
            const raw = try s.request(tmp, "tools/list", params.items, stop, deadline);
            const v = jv.parse(tmp, raw) orelse return error.BadResponse;
            const result = jv.get(v, "result") orelse return error.ListFailed;
            for (jv.arr(jv.get(result, "tools")) orelse &.{}) |tv| {
                if (list.items.len >= max_tools) break;
                const name = jv.str(jv.get(tv, "name")) orelse continue;
                if (!validToolName(name)) continue;
                const schema = if (jv.get(tv, "inputSchema")) |sch|
                    try std.json.Stringify.valueAlloc(a, sch, .{})
                else
                    "{\"type\":\"object\"}";
                try list.append(a, .{
                    .server = s.name,
                    .name = try a.dupe(u8, name),
                    .description = try a.dupe(u8, jv.str(jv.get(tv, "description")) orelse ""),
                    .schema_json = schema,
                });
            }
            const next = jv.str(jv.get(result, "nextCursor")) orelse break;
            if (next.len == 0) break;
            cursor = next;
        }
        s.tool_list = list.items;
        return s;
    }

    pub fn tools(s: *const Server) []const Tool {
        return s.tool_list;
    }

    /// tools/call. The text of all `text` content items joined by "\n"
    /// (others as "[image]", "[resource uri]" …), capped at `max_bytes`;
    /// is_error from `isError` or a JSON-RPC error. error.Stopped when
    /// `stop` becomes true, error.Timeout after `timeout_ms`,
    /// error.ServerExited when it goes away meanwhile.
    pub fn call(s: *Server, arena: std.mem.Allocator, tool: []const u8, args_json: []const u8, stop: *std.atomic.Value(bool), timeout_ms: u32, max_bytes: usize) !Result {
        // re-encoded: no raw newlines may reach the wire
        const args = jv.parse(arena, if (args_json.len == 0) "{}" else args_json) orelse return error.BadInput;
        if (args != .object) return error.BadInput;
        var params: std.ArrayList(u8) = .empty;
        try params.appendSlice(arena, "{\"name\":");
        try util.jsonString(&params, arena, tool);
        try params.appendSlice(arena, ",\"arguments\":");
        try params.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, args, .{}));
        try params.appendSlice(arena, "}");

        s.call_mutex.lockUncancelable(s.io);
        defer s.call_mutex.unlock(s.io);
        const deadline = nowNs(s.io) + @as(i128, timeout_ms) * std.time.ns_per_ms;
        const raw = try s.request(arena, "tools/call", params.items, stop, deadline);
        const v = jv.parse(arena, raw) orelse return error.BadResponse;
        if (jv.get(v, "error")) |e| {
            const msg = jv.str(jv.get(e, "message")) orelse "";
            const code = jv.int(jv.get(e, "code")) orelse 0;
            return .{ .text = cap(arena, try std.fmt.allocPrint(arena, "error {d}: {s}", .{ code, msg }), max_bytes), .is_error = true };
        }
        const result = jv.get(v, "result") orelse return error.BadResponse;
        var out: std.ArrayList(u8) = .empty;
        for (jv.arr(jv.get(result, "content")) orelse &.{}) |item| {
            if (out.items.len > 0) try out.append(arena, '\n');
            const kind = jv.str(jv.get(item, "type")) orelse "unknown";
            if (std.mem.eql(u8, kind, "text")) {
                try out.appendSlice(arena, jv.str(jv.get(item, "text")) orelse "");
            } else if (std.mem.eql(u8, kind, "resource")) {
                try out.print(arena, "[resource {s}]", .{jv.str(jv.at(item, &.{ "resource", "uri" })) orelse ""});
            } else if (std.mem.eql(u8, kind, "resource_link")) {
                try out.print(arena, "[resource {s}]", .{jv.str(jv.get(item, "uri")) orelse ""});
            } else {
                try out.print(arena, "[{s}]", .{kind});
            }
        }
        if (out.items.len == 0) {
            if (jv.get(result, "structuredContent")) |sc| try out.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, sc, .{}));
        }
        return .{ .text = cap(arena, out.items, max_bytes), .is_error = jv.boolean(jv.get(result, "isError")) orelse false };
    }

    /// resources/read: the text of its contents joined by "\n" (a blob as
    /// "[blob]"), capped at `max_bytes`; is_error for a JSON-RPC error.
    pub fn readResource(s: *Server, arena: std.mem.Allocator, uri: []const u8, stop: *std.atomic.Value(bool), timeout_ms: u32, max_bytes: usize) !Result {
        var params: std.ArrayList(u8) = .empty;
        try params.appendSlice(arena, "{\"uri\":");
        try util.jsonString(&params, arena, uri);
        try params.append(arena, '}');
        s.call_mutex.lockUncancelable(s.io);
        defer s.call_mutex.unlock(s.io);
        const deadline = nowNs(s.io) + @as(i128, timeout_ms) * std.time.ns_per_ms;
        const raw = try s.request(arena, "resources/read", params.items, stop, deadline);
        const v = jv.parse(arena, raw) orelse return error.BadResponse;
        if (jv.get(v, "error")) |e| {
            const msg = jv.str(jv.get(e, "message")) orelse "";
            const code = jv.int(jv.get(e, "code")) orelse 0;
            return .{ .text = cap(arena, try std.fmt.allocPrint(arena, "error {d}: {s}", .{ code, msg }), max_bytes), .is_error = true };
        }
        const result = jv.get(v, "result") orelse return error.BadResponse;
        var out: std.ArrayList(u8) = .empty;
        for (jv.arr(jv.get(result, "contents")) orelse &.{}) |item| {
            if (out.items.len > 0) try out.append(arena, '\n');
            try out.appendSlice(arena, jv.str(jv.get(item, "text")) orelse "[blob]");
        }
        return .{ .text = cap(arena, out.items, max_bytes), .is_error = false };
    }

    /// resources/subscribe: the server says when `uri` changes (`updated`).
    pub fn subscribe(s: *Server, arena: std.mem.Allocator, uri: []const u8, stop: *std.atomic.Value(bool), timeout_ms: u32) !void {
        var params: std.ArrayList(u8) = .empty;
        try params.appendSlice(arena, "{\"uri\":");
        try util.jsonString(&params, arena, uri);
        try params.append(arena, '}');
        s.call_mutex.lockUncancelable(s.io);
        defer s.call_mutex.unlock(s.io);
        const deadline = nowNs(s.io) + @as(i128, timeout_ms) * std.time.ns_per_ms;
        const raw = try s.request(arena, "resources/subscribe", params.items, stop, deadline);
        const v = jv.parse(arena, raw) orelse return error.BadResponse;
        if (jv.get(v, "error") != null) return error.Refused;
    }

    /// False once the server closed its output (it exited or crashed).
    pub fn alive(s: *const Server) bool {
        return !s.eof.load(.acquire);
    }

    /// The end of what the server wrote to stderr.
    pub fn stderrTail(s: *Server, buf: *[2048]u8) []const u8 {
        s.state_mutex.lockUncancelable(s.io);
        defer s.state_mutex.unlock(s.io);
        @memcpy(buf[0..s.err_len], s.err_tail[0..s.err_len]);
        return buf[0..s.err_len];
    }

    /// Kills the server's process and its group (Windows: its job) at
    /// once; frees nothing (`deinit` still has to follow, unless the
    /// process is ending).
    pub fn kill(s: *Server) void {
        killTree(s.pid, &s.job);
    }

    /// Closes stdin, gives the server a moment to exit, kills its process
    /// group, waits for it and frees everything.
    pub fn deinit(s: *Server) void {
        s.shutdown();
        s.free();
    }

    fn shutdown(s: *Server) void {
        s.shutdownWith(500);
    }

    /// Closes stdin: a server that reads it ends on its own.
    fn closeInput(s: *Server) void {
        s.write_mutex.lockUncancelable(s.io);
        if (s.stdin) |f| f.close(s.io);
        s.stdin = null;
        s.write_mutex.unlock(s.io);
    }

    /// Ended (its output closed), or never had a reader.
    fn outputClosed(s: *Server) bool {
        return s.eof.load(.acquire) or s.th_out == null;
    }

    /// Closes stdin, waits up to `grace_ms` for the server to end, then
    /// kills its group and waits for it.
    fn shutdownWith(s: *Server, grace_ms: u32) void {
        const io = s.io;
        s.closeInput();
        var waited: u32 = 0;
        while (!s.outputClosed() and waited < grace_ms) : (waited += 10) io.sleep(.fromMilliseconds(10), .awake) catch {};
        // the whole group (Windows: the job), so whatever it started goes too
        killTree(s.pid, &s.job);
        _ = s.child.wait(io) catch {};
        if (is_windows) s.job.kill(null) else std.posix.kill(-s.pid, .KILL) catch {};
        // what is left in both pipes (stderr says why a start failed); a
        // process that left the group and kept them open is not waited for
        waited = 0;
        while (!(s.eof.load(.acquire) and s.err_eof.load(.acquire)) and s.th_out != null and waited < 1000) : (waited += 10) io.sleep(.fromMilliseconds(10), .awake) catch {};
        s.ended.store(true, .release);
        if (s.th_out) |th| th.join();
        if (s.th_err) |th| th.join();
        s.th_out = null;
        s.th_err = null;
        s.stdout.close(io);
        s.stderr.close(io);
    }

    fn free(s: *Server) void {
        s.job.close();
        if (s.got) |g| s.gpa.free(g);
        s.arena_state.deinit();
        s.gpa.destroy(s);
    }

    // ---- inside ----

    /// Sends a request and waits for its response line (copied to `arena`).
    fn request(s: *Server, arena: std.mem.Allocator, method: []const u8, params_json: []const u8, stop: *std.atomic.Value(bool), deadline_ns: i128) ![]const u8 {
        s.state_mutex.lockUncancelable(s.io);
        const id = s.next_id;
        s.next_id += 1;
        s.want = id;
        if (s.got) |g| s.gpa.free(g);
        s.got = null;
        s.state_mutex.unlock(s.io);
        defer {
            s.state_mutex.lockUncancelable(s.io);
            s.want = 0;
            if (s.got) |g| s.gpa.free(g);
            s.got = null;
            s.state_mutex.unlock(s.io);
        }
        try s.send(arena, try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json }));
        while (true) {
            // eof first: a response that came before it is still taken
            const gone = s.eof.load(.acquire);
            s.state_mutex.lockUncancelable(s.io);
            if (s.got) |g| {
                defer s.state_mutex.unlock(s.io);
                return arena.dupe(u8, g);
            }
            s.state_mutex.unlock(s.io);
            if (gone) return error.ServerExited;
            if (stop.load(.acquire)) {
                s.cancel(arena, id, "stopped");
                return error.Stopped;
            }
            if (nowNs(s.io) >= deadline_ns) {
                s.cancel(arena, id, "timed out");
                return error.Timeout;
            }
            s.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }

    fn cancel(s: *Server, arena: std.mem.Allocator, id: u64, reason: []const u8) void {
        const msg = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{{\"requestId\":{d},\"reason\":\"{s}\"}}}}", .{ id, reason }) catch return;
        s.send(arena, msg) catch {};
    }

    /// Writes one line to the server's stdin.
    fn send(s: *Server, scratch: std.mem.Allocator, line: []const u8) !void {
        const buf = try std.mem.concat(scratch, u8, &.{ line, "\n" });
        s.write_mutex.lockUncancelable(s.io);
        defer s.write_mutex.unlock(s.io);
        const f = s.stdin orelse return error.ServerExited;
        f.writeStreamingAll(s.io, buf) catch return error.ServerExited;
    }

    /// Waits until the pipe has data; false when the readers should stop.
    fn ready(s: *Server, f: Io.File) bool {
        return proc.waitReadable(s.io, f, &s.ended);
    }

    fn readOut(s: *Server) void {
        defer s.eof.store(true, .release);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(s.gpa);
        var skipping = false;
        var chunk: [65536]u8 = undefined;
        while (s.ready(s.stdout)) {
            const got = s.stdout.readStreaming(s.io, &.{&chunk}) catch break;
            if (got == 0) break;
            var rest: []const u8 = chunk[0..got];
            while (true) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const part = rest[0 .. nl orelse rest.len];
                if (!skipping) {
                    if (line.items.len + part.len > max_line) {
                        skipping = true;
                        line.clearAndFree(s.gpa);
                    } else line.appendSlice(s.gpa, part) catch {
                        skipping = true;
                        line.clearAndFree(s.gpa);
                    };
                }
                const end = nl orelse break;
                if (!skipping) s.handleLine(line.items);
                line.clearRetainingCapacity();
                skipping = false;
                rest = rest[end + 1 ..];
            }
        }
    }

    fn handleLine(s: *Server, raw: []const u8) void {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = jv.parse(a, text) orelse return;
        if (v != .object) return;
        if (jv.str(jv.get(v, "method"))) |method| {
            // a request needs an answer; a notification doesn't (a
            // resource that changed is passed on)
            const idv = jv.get(v, "id") orelse {
                if (std.mem.eql(u8, method, "notifications/resources/updated")) if (s.updated) |u| if (jv.str(jv.at(v, &.{ "params", "uri" }))) |uri| u.f(u.ctx, s.name, uri);
                return;
            };
            const id_json = std.json.Stringify.valueAlloc(a, idv, .{}) catch return;
            const reply = if (std.mem.eql(u8, method, "ping"))
                std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_json})
            else
                std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id_json});
            s.send(a, reply catch return) catch {};
            return;
        }
        const id = jv.int(jv.get(v, "id")) orelse return;
        if (jv.get(v, "result") == null and jv.get(v, "error") == null) return;
        s.state_mutex.lockUncancelable(s.io);
        defer s.state_mutex.unlock(s.io);
        if (s.want != 0 and id == s.want and s.got == null) s.got = s.gpa.dupe(u8, text) catch null;
    }

    fn readErr(s: *Server) void {
        defer s.err_eof.store(true, .release);
        var chunk: [4096]u8 = undefined;
        while (s.ready(s.stderr)) {
            const got = s.stderr.readStreaming(s.io, &.{&chunk}) catch break;
            if (got == 0) break;
            s.state_mutex.lockUncancelable(s.io);
            defer s.state_mutex.unlock(s.io);
            const cap_len = s.err_tail.len;
            if (got >= cap_len) {
                @memcpy(&s.err_tail, chunk[got - cap_len .. got]);
                s.err_len = cap_len;
            } else {
                const keep = @min(s.err_len, cap_len - got);
                std.mem.copyForwards(u8, s.err_tail[0..keep], s.err_tail[s.err_len - keep .. s.err_len]);
                @memcpy(s.err_tail[keep .. keep + got], chunk[0..got]);
                s.err_len = keep + got;
            }
        }
    }
};

/// Names a model API accepts as (part of) a tool name.
fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

/// Stops servers, each with its group (Windows: its job), and frees them: all are told
/// together (their stdin closed) and share one grace, so stopping many
/// takes no longer than stopping one.
pub fn stopAll(servers: []const *Server) void {
    if (servers.len == 0) return;
    const io = servers[0].io;
    for (servers) |srv| srv.closeInput();
    const until = nowNs(io) + 500 * std.time.ns_per_ms;
    while (nowNs(io) < until) {
        var open = false;
        for (servers) |srv| if (!srv.outputClosed()) {
            open = true;
            break;
        };
        if (!open) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    for (servers) |srv| {
        srv.shutdownWith(0);
        srv.free();
    }
}

/// The process group on POSIX; the job on Windows (the process alone
/// when it has none).
fn killTree(id: std.process.Child.Id, job: *const proc.Job) void {
    if (is_windows) {
        job.kill(id);
    } else {
        std.posix.kill(-id, .KILL) catch {};
        std.posix.kill(id, .KILL) catch {};
    }
}

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn cap(arena: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return std.fmt.allocPrint(arena, "{s}\n[output cut at {d} bytes of {d}]", .{ util.cut(s, max), max, s.len }) catch util.cut(s, max);
}

// ---- tests ----

const t = std.testing;

test "parse_config_reads_servers_secrets_and_money_tools" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\; servers
        \\[github]
        \\command = npx -y @modelcontextprotocol/server-github
        \\secret = GITHUB_PERSONAL_ACCESS_TOKEN:github   ; env var : stored secret name
        \\
        \\[broker-1]
        \\command = "/opt/my broker/bin/mcp" --mode "live trading"
        \\secret = API_KEY:broker, API_SECRET : broker_secret
        \\money = place_order, cancel_order              ; tools that move money
        \\amount = notional_usd
    ;
    const servers = try parseConfig(a, text);
    try t.expectEqual(2, servers.len);
    try t.expectEqualStrings("github", servers[0].name);
    try t.expectEqualStrings("npx -y @modelcontextprotocol/server-github", servers[0].command);
    try t.expectEqual(1, servers[0].secrets.len);
    try t.expectEqualStrings("GITHUB_PERSONAL_ACCESS_TOKEN", servers[0].secrets[0].env);
    try t.expectEqualStrings("github", servers[0].secrets[0].secret);
    try t.expectEqual(0, servers[0].money.len);
    try t.expect(servers[0].amount == .unset);
    const b = servers[1];
    try t.expectEqualStrings("broker-1", b.name);
    try t.expectEqual(2, b.secrets.len);
    try t.expectEqualStrings("API_SECRET", b.secrets[1].env);
    try t.expectEqualStrings("broker_secret", b.secrets[1].secret);
    try t.expectEqual(2, b.money.len);
    try t.expectEqualStrings("place_order", b.money[0]);
    try t.expectEqualStrings("cancel_order", b.money[1]);
    try t.expectEqualStrings("notional_usd", b.amount.of("place_order").name);
    const argv = try splitCommand(a, b.command);
    try t.expectEqual(3, argv.len);
    try t.expectEqualStrings("/opt/my broker/bin/mcp", argv[0]);
    try t.expectEqualStrings("--mode", argv[1]);
    try t.expectEqualStrings("live trading", argv[2]);
    try t.expectEqual(0, (try parseConfig(a, "; nothing\n")).len);
}

test "parse_config_refuses_bad_lines" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = [_][]const u8{
        "command = x\n", // outside a section
        "[Git Hub]\ncommand = x\n", // bad name
        "[abcdefghijabcdefghijabcdefghijabc]\ncommand = x\n", // 33 chars
        "[a]\nsecret = X:y\n", // no command
        "[a]\ncommand = x\ncolour = red\n", // unknown key
        "[a]\ncommand = x\ncommand = y\n", // twice
        "[a]\ncommand = x\nsecret = NOCOLON\n",
        "[a]\ncommand = x\nsecret = :name\n",
        "[a]\ncommand = x\nsecret = BAD-ENV:name\n",
        "[a]\ncommand = x\nmoney = a,,b\n",
        "[a]\ncommand = \"unterminated\n",
        "[a]\ncommand = x\n[a]\ncommand = y\n", // same server twice
        "[a]\njust words\n",
        "[a__b]\ncommand = x\n", // a__b's tool c and a's tool b__c would both be a__b__c
    };
    for (bad) |text| {
        if (parseConfig(a, text)) |_| {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |e| try t.expectEqual(error.BadConfig, e);
    }
}

test "parse_config_takes_the_amount_field_per_tool" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // README's example, as written there
    const servers = try parseConfig(a,
        \\[broker]
        \\command = /opt/broker-mcp/server
        \\secret = BROKER_KEY:broker
        \\money = place_order, cancel_order              ; tools that move money
        \\amount = place_order:notional_usd, cancel_order:none   ; or one field for all: amount = notional_usd
    );
    try t.expectEqual(1, servers.len);
    const am = servers[0].amount;
    try t.expectEqualStrings("notional_usd", am.of("place_order").name);
    try t.expect(am.of("cancel_order") == .none);
    try t.expect(am.of("other_tool") == .unset);
    // one field for all money tools
    const one = try parseConfig(a, "[b]\ncommand = x\nmoney = p, q\namount = notional_usd\n");
    try t.expectEqualStrings("notional_usd", one[0].amount.of("q").name);
    try t.expect((try parseConfig(a, "[b]\ncommand = x\nmoney = p\n"))[0].amount == .unset);
    const bad = [_][]const u8{
        "[b]\ncommand = x\nmoney = p\namount = p:\n",
        "[b]\ncommand = x\nmoney = p\namount = :usd\n",
        "[b]\ncommand = x\nmoney = p\namount = p:usd:eur\n",
        "[b]\ncommand = x\nmoney = p\namount = p:usd, p:none\n", // the same tool twice
        "[b]\ncommand = x\nmoney = p, q\namount = p:usd,, q:none\n",
        "[b]\ncommand = x\nmoney = p\namount = q:usd\n", // not a money tool: a typo
        "[b]\ncommand = x\namount = usd\n", // an amount without money tools
        "[b]\ncommand = x\nmoney = p\namount = none\n", // none is said per tool
        "[b]\ncommand = x\nmoney = p\namount = notional usd\n",
    };
    for (bad) |text| {
        if (parseConfig(a, text)) |_| {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |e| try t.expectEqual(error.BadConfig, e);
    }
}

test "parse_config_takes_money_caps_per_server" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const servers = try parseConfig(a, "[b]\ncommand = x\nmoney = p\namount = usd\nmax_per_call = 100\nmax_per_day = none   ; no cap for this one\n[c]\ncommand = y\nmoney = q\n");
    try t.expectEqual(100, servers[0].max_per_call.?);
    // none: no cap here, whatever config.ini says
    try t.expectEqual(0, servers[0].max_per_day.?);
    try t.expectEqual(null, servers[1].max_per_call);
    try t.expectEqual(null, servers[1].max_per_day);
    // 0 says nothing clear (no cap? none allowed?): write none, or leave the line out
    for ([_][]const u8{
        "[b]\ncommand = x\nmoney = p\nmax_per_day = 0\n",
        "[b]\ncommand = x\nmoney = p\nmax_per_call = 0\n",
        "[b]\ncommand = x\nmoney = p\nmax_per_call = 000\n",
    }) |text| try t.expectError(error.ZeroCap, parseConfig(a, text));
    try t.expect(std.mem.indexOf(u8, configReason(error.ZeroCap).?, "write none") != null);
    try t.expectEqual(null, configReason(error.BadConfig));
    const bad = [_][]const u8{
        "[b]\ncommand = x\nmoney = p\nmax_per_call = -1\n",
        "[b]\ncommand = x\nmoney = p\nmax_per_call = 2.5\n",
        "[b]\ncommand = x\nmoney = p\nmax_per_day = lots\n",
        "[b]\ncommand = x\nmoney = p\nmax_per_day =\n",
        "[b]\ncommand = x\nmax_per_day = 10\n", // a cap without money tools
        "[b]\ncommand = x\nmoney = p\nmax_per_day = 1\nmax_per_day = 2\n",
        "[b]\ncommand = x\nmoney = p\nmax_per_day = None\n",
        "[b]\ncommand = x\nmax_per_day = none\n", // none without money tools
    };
    for (bad) |text| {
        if (parseConfig(a, text)) |_| {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |e| try t.expectEqual(error.BadConfig, e);
    }
}

test "parse_config_takes_only_secret_names_the_store_can_hold" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // the names `harness secret add` takes: a-z, 0-9, - and _, at most 64
    const longest: [64]u8 = @splat('s');
    const ok = try parseConfig(a, "[a]\ncommand = x\nsecret = K:" ++ longest ++ ", L:my_key-2\n");
    try t.expectEqualStrings(&longest, ok[0].secrets[0].secret);
    const bad = [_][]const u8{
        "[a]\ncommand = x\nsecret = K:../config.ini\n", // a file outside the secrets folder
        "[a]\ncommand = x\nsecret = K:sub/name\n",
        "[a]\ncommand = x\nsecret = K:..\n",
        "[a]\ncommand = x\nsecret = K:Upper\n", // never stored under that name
        "[a]\ncommand = x\nsecret = K:-flag\n",
        "[a]\ncommand = x\nsecret = K:" ++ longest ++ "s\n", // too long for the Credential Manager's name
        "[a]\ncommand = x\nsecret = K:na\\me\n",
    };
    for (bad) |text| {
        if (parseConfig(a, text)) |_| {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |e| try t.expectEqual(error.BadConfig, e);
    }
}

const fake_path = if (@import("builtin").is_test) @import("build_options").fake_path else "";

const Fx = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    ws: []const u8,
    fake: []const u8,
    stop: std.atomic.Value(bool) = .init(false),

    fn init(f: *Fx) !void {
        f.arena_state = .init(t.allocator);
        f.tmp = t.tmpDir(.{});
        f.stop = .init(false);
        try f.tmp.dir.createDirPath(t.io, "ws");
        f.ws = try f.tmp.dir.realPathFileAlloc(t.io, "ws", f.arena_state.allocator());
        // the build gives it relative to the build folder; servers start in ws
        f.fake = try Io.Dir.cwd().realPathFileAlloc(t.io, fake_path, f.arena_state.allocator());
    }

    fn deinit(f: *Fx) void {
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    fn a(f: *Fx) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    fn startWith(f: *Fx, command: []const u8, secrets: []const EnvSecret, values: []const []const u8) !*Server {
        return Server.start(t.allocator, t.io, .{ .name = "fake", .command = command, .secrets = secrets, .money = &.{} }, .{
            .cwd = f.ws,
            .path_var = "/usr/bin:/bin",
            .home = "/home/tester",
            .secret_values = values,
            .start_timeout_ms = 10000,
        });
    }

    fn start(f: *Fx) !*Server {
        return f.startWith(try std.fmt.allocPrint(f.a(), "\"{s}\" --mcp", .{f.fake}), &.{}, &.{});
    }

    fn call(f: *Fx, s: *Server, tool: []const u8, args: []const u8, timeout_ms: u32) !Result {
        return s.call(f.a(), tool, args, &f.stop, timeout_ms, 4096);
    }
};

fn nowMs() i64 {
    return @intCast(@divFloor(Io.Clock.awake.now(t.io).nanoseconds, std.time.ns_per_ms));
}

test "start_lists_the_tools_with_their_schemas" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.start();
    defer s.deinit();
    try t.expect(s.alive());
    const ts = s.tools();
    try t.expectEqual(3, ts.len);
    try t.expectEqualStrings("echo", ts[0].name);
    try t.expectEqualStrings("fail", ts[1].name);
    try t.expectEqualStrings("sleep", ts[2].name);
    try t.expectEqualStrings("fake", ts[0].server);
    try t.expectEqualStrings("Echo text back.", ts[0].description);
    try t.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}", ts[0].schema_json);
}

test "call_returns_text_and_errors_and_skips_notifications" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.start();
    defer s.deinit();
    const r = try f.call(s, "echo", "{\"text\":\"hello\\nworld\"}", 5000);
    try t.expect(!r.is_error);
    try t.expectEqualStrings("hello\nworld", r.text);
    const bad = try f.call(s, "fail", "{}", 5000);
    try t.expect(bad.is_error);
    try t.expectEqualStrings("it failed", bad.text);
    // the server's ping request (sent with a notification before the tool list) was answered
    try t.expectEqualStrings("yes", (try f.call(s, "echo", "{\"text\":\"pinged\"}", 5000)).text);
    try t.expectEqualStrings("one\n[image]\n[resource file:///x.txt]\ntwo", (try f.call(s, "echo", "{\"text\":\"mixed\"}", 5000)).text);
    const capped = try s.call(f.a(), "echo", "{\"text\":\"0123456789\"}", &f.stop, 5000, 4);
    try t.expect(std.mem.startsWith(u8, capped.text, "0123\n[output cut at 4 bytes of 10]"));
    try t.expectError(error.BadInput, f.call(s, "echo", "not json", 5000));
    try t.expect(s.alive());
}

test "the_secret_and_home_reach_the_server_and_nothing_else" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const cmd = try std.fmt.allocPrint(f.a(), "{s} --mcp", .{f.fake});
    const s = try f.startWith(cmd, &.{.{ .env = "FAKE_SECRET", .secret = "fake" }}, &.{"s3cr3t-value"});
    defer s.deinit();
    const r = try f.call(s, "echo", "{\"text\":\"env\"}", 5000);
    try t.expectEqualStrings("secret=s3cr3t-value home=/home/tester user=", r.text);
}

test "system_vars_reach_the_server" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const cmd = try std.fmt.allocPrint(f.a(), "\"{s}\" --mcp", .{f.fake});
    const s = try Server.start(t.allocator, t.io, .{ .name = "fake", .command = cmd, .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.ws,
        .path_var = "/usr/bin:/bin",
        .home = "/home/tester",
        .system_vars = &.{.{ .name = "USER", .value = "from-the-system" }},
        .secret_values = &.{},
        .start_timeout_ms = 10000,
    });
    defer s.deinit();
    const r = try f.call(s, "echo", "{\"text\":\"env\"}", 5000);
    try t.expectEqualStrings("secret= home=/home/tester user=from-the-system", r.text);
}

fn stopLater(flag: *std.atomic.Value(bool)) void {
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    flag.store(true, .release);
}

test "stop_ends_a_call_quickly" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.start();
    defer s.deinit();
    const th = try std.Thread.spawn(.{}, stopLater, .{&f.stop});
    defer th.join();
    const t0 = nowMs();
    try t.expectError(error.Stopped, f.call(s, "sleep", "{\"ms\":10000}", 30000));
    try t.expect(nowMs() - t0 < 1000);
}

test "after_a_timeout_the_next_call_gets_its_own_answer" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.start();
    defer s.deinit();
    const t0 = nowMs();
    try t.expectError(error.Timeout, f.call(s, "sleep", "{\"ms\":800}", 200));
    try t.expect(nowMs() - t0 < 700);
    // the server answers "slept" for the old call first; that must be dropped
    const r = try f.call(s, "echo", "{\"text\":\"mine\"}", 5000);
    try t.expectEqualStrings("mine", r.text);
}

test "a_start_ends_by_its_deadline_counted_from_before_the_spawn" {
    if (is_windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const t0 = nowMs();
    // up after a second: past a deadline 0.4 s from before it was spawned
    const r = Server.start(t.allocator, t.io, .{ .name = "late", .command = try std.fmt.allocPrint(f.a(), "/bin/sh -c \"sleep 1; exec '{s}' --mcp\"", .{f.fake}), .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.ws,
        .path_var = "/usr/bin:/bin",
        .home = "/home/tester",
        .secret_values = &.{},
        .deadline_ns = Io.Clock.awake.now(t.io).nanoseconds + 400 * std.time.ns_per_ms,
    });
    if (r) |srv| {
        srv.deinit();
        return error.TestUnexpectedResult;
    } else |e| try t.expectEqual(error.Timeout, e);
    try t.expect(nowMs() - t0 < 900);
}

test "a_server_that_never_started_is_ended_at_once" {
    if (is_windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const t0 = nowMs();
    // never answers, and a closed input doesn't end it: no grace for it
    const r = Server.start(t.allocator, t.io, .{ .name = "mute", .command = "/bin/sh -c \"exec sleep 30\"", .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.ws,
        .path_var = "/usr/bin:/bin",
        .home = "/home/tester",
        .secret_values = &.{},
        .deadline_ns = Io.Clock.awake.now(t.io).nanoseconds + 200 * std.time.ns_per_ms,
    });
    if (r) |srv| {
        srv.deinit();
        return error.TestUnexpectedResult;
    } else |e| try t.expectEqual(error.Timeout, e);
    const took = nowMs() - t0;
    if (took >= 500) std.debug.print("a start that timed out after 200 ms took {d} ms\n", .{took});
    try t.expect(took < 500);
}

test "servers_are_stopped_together" {
    if (is_windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    // each keeps its output open after its input closes: each waits out
    // the grace, so one after another three would take three of them
    var list: [3]*Server = undefined;
    for (&list) |*s| s.* = try f.startWith(try std.fmt.allocPrint(f.a(), "/bin/sh -c \"'{s}' --mcp; exec sleep 30\"", .{f.fake}), &.{}, &.{});
    const t0 = nowMs();
    stopAll(&list);
    const took = nowMs() - t0;
    if (took >= 1100) std.debug.print("stopping three servers took {d} ms\n", .{took});
    try t.expect(took < 1100);
}

test "deinit_leaves_no_process_behind" {
    if (is_windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    // the shell leaves a background child in the group, then becomes the server
    const cmd = try std.fmt.allocPrint(f.a(), "/bin/sh -c \"sleep 30 & exec {s} --mcp\"", .{f.fake});
    const s = try f.startWith(cmd, &.{}, &.{});
    const pid = s.pid;
    try std.posix.kill(-pid, @fromBackingInt(@intCast(0)));
    s.deinit();
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        std.posix.kill(-pid, @fromBackingInt(@intCast(0))) catch |e| {
            try t.expectEqual(error.ProcessNotFound, e);
            return;
        };
        t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "deinit_leaves_no_process_behind_windows" {
    if (!is_windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    // cmd starts a background child that holds the server's pipes and
    // leaves a mark if it lives two seconds, then runs the server
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/bg.cmd", .data = "@ping -n 3 127.0.0.1 >nul\r\n@echo alive> left.txt\r\n" });
    const cmd = try std.fmt.allocPrint(f.a(), "cmd /c start /b cmd /c bg.cmd & \"{s}\" --mcp", .{f.fake});
    const s = try Server.start(t.allocator, t.io, .{ .name = "fake", .command = cmd, .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.ws,
        .path_var = try proc.systemDir(f.a()),
        .home = "",
        .secret_values = &.{},
        .start_timeout_ms = 10000,
    });
    try t.expect(s.alive());
    const t0 = nowMs();
    s.deinit();
    try t.expect(nowMs() - t0 < 2000);
    // what it started went with it: no mark, even well after
    t.io.sleep(.fromMilliseconds(3000), .awake) catch {};
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "ws/left.txt", .{}));
}

test "a_missing_or_broken_command_fails_to_start_with_its_stderr" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    if (f.startWith("sub/nonexistent-mcp-server --x", &.{}, &.{})) |s| {
        s.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    if (f.startWith("./nonexistent-mcp-server --x", &.{}, &.{})) |s| {
        s.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    if (f.startWith("/nonexistent/mcp-server --x", &.{}, &.{})) |s| {
        s.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    if (is_windows) return;
    var diag: Diag = .{};
    const t0 = nowMs();
    const r = Server.start(t.allocator, t.io, .{ .name = "x", .command = "/bin/sh -c \"echo broken >&2; exit 3\"", .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.ws,
        .path_var = "/usr/bin:/bin",
        .home = "",
        .secret_values = &.{},
        .start_timeout_ms = 5000,
        .diag = &diag,
    });
    try t.expectError(error.ServerExited, r);
    try t.expect(nowMs() - t0 < 3000);
    try t.expect(std.mem.indexOf(u8, diag.text(), "broken") != null);
}

/// What `Server.updated` was told, for the tests.
const Updates = struct {
    n: std.atomic.Value(u32) = .init(0),
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn note(ctx: *anyopaque, server: []const u8, uri: []const u8) void {
        const u: *Updates = @ptrCast(@alignCast(ctx));
        _ = server;
        const n = @min(uri.len, u.buf.len);
        @memcpy(u.buf[0..n], uri[0..n]);
        u.len = n;
        _ = u.n.fetchAdd(1, .release);
    }
};

test "resources_are_read_and_updates_passed_on" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/res.txt", .data = "version one" });
    var ups: Updates = .{};
    const s = try Server.start(t.allocator, t.io, .{ .name = "fake", .command = try std.fmt.allocPrint(f.a(), "\"{s}\" --mcp", .{f.fake}), .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.ws,
        .path_var = "/usr/bin:/bin",
        .home = "/home/tester",
        .secret_values = &.{},
        .start_timeout_ms = 10000,
        .updated = .{ .ctx = &ups, .f = Updates.note },
    });
    defer s.deinit();
    try t.expect(s.subscribes);
    const r = try s.readResource(f.a(), "fake://res.txt", &f.stop, 5000, 4096);
    try t.expect(!r.is_error);
    try t.expectEqualStrings("version one", r.text);
    try t.expect((try s.readResource(f.a(), "fake://none.txt", &f.stop, 5000, 4096)).is_error);
    try s.subscribe(f.a(), "fake://res.txt", &f.stop, 5000);
    // the server says it changed: passed on, not dropped
    try t.expectEqualStrings("notified", (try f.call(s, "echo", "{\"text\":\"notify:fake://res.txt\"}", 5000)).text);
    var waited: u32 = 0;
    while (ups.n.load(.acquire) == 0 and waited < 3000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try t.expectEqual(1, ups.n.load(.acquire));
    try t.expectEqualStrings("fake://res.txt", ups.buf[0..ups.len]);
    // the stand-in's echo reads a file of its folder
    try t.expectEqualStrings("version one", (try f.call(s, "echo", "{\"text\":\"file:res.txt\"}", 5000)).text);
}

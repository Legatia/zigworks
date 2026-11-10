//! MCP server over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout.
//! Nothing but protocol messages is ever written to stdout.
//!
//! Tools are thin wrappers over the session model in client.zig; they talk
//! to session servers in-process, not through the CLI.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const json = std.json;
const client = @import("client.zig");
const server = @import("server.zig");
const regex = @import("regex.zig");

const supported_versions = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25" };
const default_version = "2025-06-18";
const max_ms = 60_000;
const max_line = 4 << 20;
const start_idle_ms = 300;
const start_timeout_ms = 5_000;
/// Sessions started over MCP end after an hour without requests or output,
/// unless the caller passes another ttl_s (0 disables it).
const default_ttl_s = 3600;
const max_ttl_s = 30 * 24 * 3600;

/// Reads requests from stdin until EOF and writes replies to stdout.
pub fn serve(gpa: Allocator) !void {
    const in_buf = try gpa.alloc(u8, max_line);
    defer gpa.free(in_buf);
    var reader = std.fs.File.stdin().readerStreaming(in_buf);
    var out_buf: [8192]u8 = undefined;
    var writer = std.fs.File.stdout().writerStreaming(&out_buf);
    const out = &writer.interface;

    var io: Io = .{ .gpa = gpa, .in = &reader.interface, .in_fd = posix.STDIN_FILENO };
    // One diff marker per MCP server process, separate from CLI users and
    // other agents watching the same session.
    io.client_id = std.fmt.bufPrint(&io.client_id_buf, "mcp-{d}", .{std.c.getpid()}) catch "mcp";
    defer io.deinit();

    while (true) {
        const line = io.next() catch |err| switch (err) {
            error.LineTooLong => {
                const r = try errorReply(gpa, .null, -32700, "request line too long");
                defer gpa.free(r);
                try writeLine(out, r);
                continue;
            },
            else => |e| return e,
        } orelse return;
        defer gpa.free(line);
        if (try handleMessage(gpa, line, &io)) |r| {
            defer gpa.free(r);
            try writeLine(out, r);
        }
    }
}

fn writeLine(out: *std.Io.Writer, msg: []const u8) !void {
    try out.writeAll(msg);
    try out.writeByte('\n');
    try out.flush();
}

/// Stdin while serving. A tool call that waits on a session keeps reading
/// stdin so it can notice `notifications/cancelled`; anything else that
/// arrives meanwhile is queued and handled afterwards, in order.
const Io = struct {
    gpa: Allocator,
    in: *std.Io.Reader,
    in_fd: posix.fd_t,
    client_id_buf: [32]u8 = undefined,
    client_id: []const u8 = "mcp",
    pending: std.ArrayList([]u8) = .empty,
    /// JSON-encoded ids of queued requests that were cancelled.
    cancelled: std.ArrayList([]u8) = .empty,
    eof: bool = false,

    fn deinit(io: *Io) void {
        for (io.pending.items) |l| io.gpa.free(l);
        io.pending.deinit(io.gpa);
        for (io.cancelled.items) |c| io.gpa.free(c);
        io.cancelled.deinit(io.gpa);
    }

    /// The next message (caller frees it), or null at end of input.
    fn next(io: *Io) !?[]u8 {
        if (io.pending.items.len > 0) return io.pending.orderedRemove(0);
        if (io.eof) return null;
        const line = io.in.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            error.StreamTooLong => {
                _ = io.in.discardDelimiterInclusive('\n') catch {
                    io.eof = true;
                };
                return error.LineTooLong;
            },
            error.ReadFailed => return err,
        };
        return try io.gpa.dupe(u8, line);
    }

    /// Blocks until `fd` is readable. Returns false if request `id` (JSON
    /// encoded) was cancelled in the meantime. After end of input the
    /// current request still runs to completion.
    fn waitReadable(io: *Io, fd: posix.fd_t, id: []const u8) !bool {
        while (true) {
            // Complete lines already buffered never show up in poll().
            while (std.mem.indexOfScalar(u8, io.in.buffered(), '\n') != null) {
                const line = io.in.takeDelimiterExclusive('\n') catch break;
                if (try io.absorb(try io.gpa.dupe(u8, line), id)) return false;
            }
            var fds = [_]posix.pollfd{
                .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (io.eof) -1 else io.in_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = try posix.poll(&fds, -1);
            if (fds[0].revents != 0) return true;
            if (fds[1].revents != 0) {
                if (io.in.buffered().len == io.in.buffer.len) {
                    // A line longer than the buffer: drop it.
                    io.in.toss(io.in.buffered().len);
                }
                io.in.fillMore() catch {
                    io.eof = true;
                    // A final line without a newline is still a message.
                    const rest = io.in.buffered();
                    if (rest.len > 0) {
                        const line = try io.gpa.dupe(u8, rest);
                        io.in.toss(rest.len);
                        if (try io.absorb(line, id)) return false;
                    }
                };
            }
        }
    }

    /// Takes ownership of `line`. Returns true if it cancels request `id`.
    fn absorb(io: *Io, line: []u8, id: []const u8) !bool {
        if (try cancelledId(io.gpa, line)) |target| {
            io.gpa.free(line);
            if (std.mem.eql(u8, target, id)) {
                io.gpa.free(target);
                return true;
            }
            if (io.cancelled.items.len >= 64) io.gpa.free(io.cancelled.orderedRemove(0));
            try io.cancelled.append(io.gpa, target);
            return false;
        }
        try io.pending.append(io.gpa, line);
        return false;
    }

    /// True (and forgets it) if request `id` was cancelled while queued.
    fn takeCancelled(io: *Io, id: []const u8) bool {
        for (io.cancelled.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, id)) {
                io.gpa.free(io.cancelled.orderedRemove(i));
                return true;
            }
        }
        return false;
    }
};

/// If `line` is a notifications/cancelled message, its JSON-encoded
/// requestId (caller frees).
fn cancelledId(gpa: Allocator, line: []const u8) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const msg = json.parseFromSliceLeaky(json.Value, arena_state.allocator(), line, .{}) catch return null;
    if (msg != .object) return null;
    const method = msg.object.get("method") orelse return null;
    if (method != .string or !eql(method.string, "notifications/cancelled")) return null;
    const params = msg.object.get("params") orelse return null;
    if (params != .object) return null;
    const id = params.object.get("requestId") orelse return null;
    return try json.Stringify.valueAlloc(gpa, id, .{});
}

/// Handles one JSON-RPC message. Returns the reply (without newline,
/// caller owns it), or null for notifications.
pub fn handleLine(gpa: Allocator, line: []const u8) Allocator.Error!?[]u8 {
    return handleMessage(gpa, line, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // only reachable with stdin attached
    };
}

fn handleMessage(gpa: Allocator, line_in: []const u8, io: ?*Io) !?[]u8 {
    const line = std.mem.trim(u8, line_in, " \t\r");
    if (line.len == 0) return null;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msg = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try errorReply(gpa, .null, -32700, "parse error"),
    };
    if (msg != .object) return try errorReply(gpa, .null, -32600, "invalid request: expected a JSON object");
    const obj = msg.object;
    const id = obj.get("id");
    const method = switch (obj.get("method") orelse .null) {
        .string => |s| s,
        else => {
            if (id == null) return null;
            return try errorReply(gpa, id.?, -32600, "invalid request: missing method");
        },
    };
    // Notifications (no id) never get a reply.
    const req_id = id orelse return null;
    const id_json = try json.Stringify.valueAlloc(arena, req_id, .{});
    if (io) |i| if (i.takeCancelled(id_json)) return null;

    var d: Dispatch = .{ .gpa = gpa, .arena = arena, .io = io, .id_json = id_json };
    if (io) |i| d.client_id = i.client_id;
    const result = d.dispatch(method, obj.get("params")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MethodNotFound => return try errorReply(gpa, req_id, -32601, d.err_msg),
        error.InvalidParams => return try errorReply(gpa, req_id, -32602, d.err_msg),
        // The client gave up on this request: send nothing.
        error.Cancelled => return null,
        else => |e| return e,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var jw: json.Stringify = .{ .writer = &out.writer };
    writeEnvelope(&jw, req_id, result) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn writeEnvelope(jw: *json.Stringify, id: json.Value, result: Result) !void {
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("result");
    switch (result) {
        .raw => |r| {
            try jw.beginWriteRaw();
            try jw.writer.writeAll(r);
            jw.endWriteRaw();
        },
        .initialize => |version| try jw.write(.{
            .protocolVersion = version,
            .capabilities = .{ .tools = Empty{} },
            .serverInfo = .{ .name = "headterm", .version = server.version },
        }),
        .tool => |t| try jw.write(.{
            .content = &[_]TextContent{.{ .text = t.text }},
            .isError = t.is_error,
        }),
    }
    try jw.endObject();
}

fn errorReply(gpa: Allocator, id: json.Value, code: i32, message: []const u8) Allocator.Error![]u8 {
    return json.Stringify.valueAlloc(gpa, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    }, .{});
}

const Empty = struct {};
const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

const ToolResult = struct {
    text: []const u8,
    is_error: bool = false,
};

const Result = union(enum) {
    raw: []const u8,
    initialize: []const u8,
    tool: ToolResult,
};

const DispatchError = error{ MethodNotFound, InvalidParams, Cancelled } || Allocator.Error || posix.PollError;

const Dispatch = struct {
    gpa: Allocator,
    arena: Allocator,
    /// Null in unit tests: session calls then block without watching stdin.
    io: ?*Io = null,
    id_json: []const u8 = "",
    /// The `styles` argument of the current tool call.
    styles: bool = false,
    /// Diff marker id passed to the session server.
    client_id: []const u8 = "mcp",
    err_msg: []const u8 = "",

    fn fail(self: *Dispatch, err: DispatchError, comptime fmt: []const u8, args: anytype) DispatchError {
        self.err_msg = std.fmt.allocPrint(self.arena, fmt, args) catch "invalid params";
        return err;
    }

    fn dispatch(self: *Dispatch, method: []const u8, params: ?json.Value) DispatchError!Result {
        if (eql(method, "initialize")) {
            var version: []const u8 = default_version;
            if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
                for (supported_versions) |s| {
                    if (eql(s, v.string)) version = s;
                }
            };
            return .{ .initialize = version };
        }
        if (eql(method, "ping")) return .{ .raw = "{}" };
        if (eql(method, "tools/list")) return .{ .raw = tools_json };
        if (eql(method, "tools/call")) {
            const p = params orelse return self.fail(error.InvalidParams, "tools/call needs params", .{});
            if (p != .object) return self.fail(error.InvalidParams, "params must be an object", .{});
            const name = switch (p.object.get("name") orelse .null) {
                .string => |s| s,
                else => return self.fail(error.InvalidParams, "params.name must be a string", .{}),
            };
            const arguments: Args = switch (p.object.get("arguments") orelse .null) {
                .object => |o| .{ .d = self, .obj = o },
                .null => .{ .d = self, .obj = null },
                else => return self.fail(error.InvalidParams, "params.arguments must be an object", .{}),
            };
            return .{ .tool = try self.callTool(name, arguments) };
        }
        return self.fail(error.MethodNotFound, "method not found: {s}", .{method});
    }

    fn callTool(self: *Dispatch, tool: []const u8, a: Args) DispatchError!ToolResult {
        if (eql(tool, "headterm_list")) return self.list();
        const name = try a.requiredString("name");
        self.styles = try a.boolean("styles") orelse false;
        if (eql(tool, "headterm_start")) {
            const command = (try a.stringArray("command")) orelse return self.fail(error.InvalidParams, "missing required argument 'command'", .{});
            if (command.len == 0) return self.fail(error.InvalidParams, "'command' must not be empty", .{});
            var opts: client.StartOptions = .{};
            if (try a.int("cols", 2, 1000)) |c| opts.cols = @intCast(c);
            if (try a.int("rows", 1, 1000)) |r| opts.rows = @intCast(r);
            opts.cwd = try a.string("cwd");
            opts.record_path = try a.string("record");
            const ttl = (try a.int("ttl_s", 0, max_ttl_s)) orelse default_ttl_s;
            opts.ttl_s = if (ttl == 0) null else @intCast(ttl);
            const wait = try self.waitSpec(try a.object("then_wait"), .{ .idle_ms = start_idle_ms, .timeout_ms = start_timeout_ms });

            var msg: [256]u8 = undefined;
            const pid = client.startSession(self.gpa, name, command, opts, &msg) catch
                return .{ .text = try std.fmt.allocPrint(self.arena, "start failed: {s}", .{std.mem.sliceTo(&msg, 0)}), .is_error = true };
            var r = try self.waitFor(name, wait);
            r.text = try std.fmt.allocPrint(self.arena, "started {s} pid={d}\n{s}", .{ name, pid, r.text });
            return r;
        }
        if (eql(tool, "headterm_screen")) {
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(self.arena, &.{ "screen", "--client", self.client_id });
            if (try a.boolean("diff") orelse false) {
                try args.append(self.arena, "--diff");
            } else {
                try args.append(self.arena, "--trim");
            }
            if (self.styles) try args.append(self.arena, "--styles");
            if (try a.int("scrollback", 0, 100_000)) |n| {
                try args.append(self.arena, "--scrollback");
                try args.append(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{n}));
            }
            return (try self.session(name, args.items)).result();
        }
        if (eql(tool, "headterm_send")) {
            const keys = (try a.stringArray("keys")) orelse return self.fail(error.InvalidParams, "missing required argument 'keys'", .{});
            const then_wait = try a.object("then_wait");
            const wait = if (then_wait != null) try self.waitSpec(then_wait, .{ .idle_ms = start_idle_ms }) else null;
            const literal = try a.boolean("literal") orelse false;
            const paste = try a.boolean("paste") orelse false;
            const esc_delay = try a.int("esc_delay_ms", 0, 10_000);
            var args: std.ArrayList([]const u8) = .empty;
            try args.append(self.arena, "send");
            if (esc_delay) |ms| try args.appendSlice(self.arena, &.{ "--esc-delay", try std.fmt.allocPrint(self.arena, "{d}", .{ms}) });
            // `--literal` ends option parsing itself; otherwise `--` does,
            // so no element of `keys` is ever read as an option.
            if (paste) {
                try args.appendSlice(self.arena, &.{ "--paste", "--" });
            } else if (literal) {
                try args.append(self.arena, "--literal");
            } else {
                try args.append(self.arena, "--");
            }
            try args.appendSlice(self.arena, keys);
            const sent = try self.session(name, args.items);
            if (sent.is_error) return sent.result();
            if (wait) |w| return self.waitFor(name, w);
            return .{ .text = "sent" };
        }
        if (eql(tool, "headterm_wait")) {
            const wait = try self.waitSpec(a, null);
            return self.waitFor(name, wait);
        }
        if (eql(tool, "headterm_resize")) {
            const cols = (try a.int("cols", 2, 1000)) orelse return self.fail(error.InvalidParams, "missing required argument 'cols'", .{});
            const rows = (try a.int("rows", 1, 1000)) orelse return self.fail(error.InvalidParams, "missing required argument 'rows'", .{});
            const r = try self.session(name, &.{
                "resize",
                try std.fmt.allocPrint(self.arena, "{d}", .{cols}),
                try std.fmt.allocPrint(self.arena, "{d}", .{rows}),
            });
            if (r.is_error) return r.result();
            return .{ .text = try std.fmt.allocPrint(self.arena, "resized {s} to {d}x{d}", .{ name, cols, rows }) };
        }
        if (eql(tool, "headterm_kill")) {
            const r = try self.session(name, &.{"kill"});
            if (r.is_error) return r.result();
            return .{ .text = try std.fmt.allocPrint(self.arena, "killed {s}", .{name}) };
        }
        return self.fail(error.InvalidParams, "unknown tool: {s}", .{tool});
    }

    const WaitSpec = struct {
        text: ?[]const u8 = null,
        regex: ?[]const u8 = null,
        gone: ?[]const u8 = null,
        idle_ms: ?i64 = null,
        exit: bool = false,
        timeout_ms: ?i64 = null,
        /// The caller asked for a condition; failing it is a tool error.
        explicit: bool = false,
    };

    /// Reads {text?, idle_ms?, exit?, timeout_ms?}. Without a condition,
    /// `default` is used, or the call is rejected when there is none.
    fn waitSpec(self: *Dispatch, args: ?Args, default: ?WaitSpec) DispatchError!WaitSpec {
        var w: WaitSpec = .{};
        if (args) |a| {
            w.text = try a.string("text");
            w.gone = try a.string("gone");
            w.regex = try a.string("regex");
            if (w.regex) |pattern| {
                var diag: regex.Diagnostic = .{};
                var re = regex.Regex.compile(self.gpa, pattern, &diag) catch |err| switch (err) {
                    error.BadRegex => return self.fail(error.InvalidParams, "bad regex: {s}", .{diag.message()}),
                    else => |e| return e,
                };
                re.deinit();
            }
            w.idle_ms = try a.int("idle_ms", 0, max_ms);
            w.exit = try a.boolean("exit") orelse false;
            w.timeout_ms = try a.int("timeout_ms", 0, max_ms);
        }
        if (w.text != null or w.regex != null or w.gone != null or w.idle_ms != null or w.exit) {
            w.explicit = true;
            return w;
        }
        var d = default orelse return self.fail(error.InvalidParams, "wait needs at least one of 'text', 'regex', 'gone', 'idle_ms' or 'exit'", .{});
        if (w.timeout_ms) |t| d.timeout_ms = t;
        return d;
    }

    fn waitFor(self: *Dispatch, name: []const u8, w: WaitSpec) DispatchError!ToolResult {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(self.arena, &.{ "wait", "--client", self.client_id });
        if (w.text) |t| try args.appendSlice(self.arena, &.{ "--text", t });
        if (w.regex) |r| try args.appendSlice(self.arena, &.{ "--regex", r });
        if (w.gone) |t| try args.appendSlice(self.arena, &.{ "--text-gone", t });
        if (w.idle_ms) |ms| try args.appendSlice(self.arena, &.{ "--idle", try std.fmt.allocPrint(self.arena, "{d}", .{ms}) });
        if (w.exit) try args.append(self.arena, "--exit");
        if (w.timeout_ms) |ms| try args.appendSlice(self.arena, &.{ "--timeout", try std.fmt.allocPrint(self.arena, "{d}", .{ms}) });
        try args.append(self.arena, "--trim");
        if (self.styles) try args.append(self.arena, "--styles");
        var r = try self.session(name, args.items);
        // An unmet default wait (e.g. a program that keeps printing) is not
        // a failure; the screen is still useful.
        if (!w.explicit and r.is_error and !r.request_failed) r.is_error = false;
        return r.result();
    }

    const SessionResult = struct {
        text: []const u8,
        is_error: bool,
        /// The request itself failed (no session, bad arguments), as
        /// opposed to a wait that ran out of time.
        request_failed: bool,

        fn result(r: SessionResult) ToolResult {
            return .{ .text = r.text, .is_error = r.is_error };
        }
    };

    fn session(self: *Dispatch, name: []const u8, args: []const []const u8) DispatchError!SessionResult {
        const resp = self.callSession(name, args) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.Unexpected, error.SystemResources, error.NetworkSubsystemFailed => |e| return e,
            else => |e| {
                var buf: [256]u8 = undefined;
                const hint = if (e == error.NoSuchSession or e == error.StaleSession) " (see headterm_list)" else "";
                const text = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ client.describeError(&buf, e, name), hint });
                return .{ .text = text, .is_error = true, .request_failed = true };
            },
        };
        const body = std.mem.trimRight(u8, resp.body, "\n");
        return switch (resp.status) {
            .ok => .{ .text = body, .is_error = false, .request_failed = false },
            .timeout => .{ .text = body, .is_error = true, .request_failed = false },
            .@"error" => .{ .text = std.mem.trimRight(u8, resp.body, "\n"), .is_error = true, .request_failed = true },
        };
    }

    fn callSession(self: *Dispatch, name: []const u8, args: []const []const u8) (client.CallError || error{Cancelled} || posix.PollError)!client.Response {
        const io = self.io orelse return client.call(self.arena, name, args);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const stream = try client.connect(try client.sessionSocket(&path_buf, name));
        // Closing the connection early cancels a wait on the session server.
        defer stream.close();
        try client.sendRequest(self.arena, stream.handle, args);
        if (!try io.waitReadable(stream.handle, self.id_json)) return error.Cancelled;
        return client.readResponse(self.arena, stream.handle);
    }

    fn list(self: *Dispatch) DispatchError!ToolResult {
        const sessions = client.listSessions(self.arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .text = try std.fmt.allocPrint(self.arena, "list failed: {s}", .{@errorName(err)}), .is_error = true },
        };
        if (sessions.infos.len == 0) return .{ .text = "no sessions" };
        var out: std.Io.Writer.Allocating = .init(self.arena);
        out.writer.writeAll("NAME             PID      SIZE      STATUS     COMMAND\n") catch return error.OutOfMemory;
        client.writeSessionTable(&out.writer, sessions.infos) catch return error.OutOfMemory;
        return .{ .text = std.mem.trimRight(u8, out.written(), "\n") };
    }
};

/// Access to a tool's `arguments` object with type checking.
const Args = struct {
    d: *Dispatch,
    obj: ?json.ObjectMap,

    fn get(a: Args, key: []const u8) ?json.Value {
        const o = a.obj orelse return null;
        const v = o.get(key) orelse return null;
        return if (v == .null) null else v;
    }

    fn string(a: Args, key: []const u8) DispatchError!?[]const u8 {
        const v = a.get(key) orelse return null;
        if (v != .string) return a.d.fail(error.InvalidParams, "'{s}' must be a string", .{key});
        return v.string;
    }

    fn requiredString(a: Args, key: []const u8) DispatchError![]const u8 {
        return (try a.string(key)) orelse a.d.fail(error.InvalidParams, "missing required argument '{s}'", .{key});
    }

    fn boolean(a: Args, key: []const u8) DispatchError!?bool {
        const v = a.get(key) orelse return null;
        if (v != .bool) return a.d.fail(error.InvalidParams, "'{s}' must be a boolean", .{key});
        return v.bool;
    }

    fn int(a: Args, key: []const u8, min: i64, max: i64) DispatchError!?i64 {
        const v = a.get(key) orelse return null;
        const n: i64 = switch (v) {
            .integer => |i| i,
            .float => |f| if (@floor(f) == f and @abs(f) < 1e15) @intFromFloat(f) else return a.d.fail(error.InvalidParams, "'{s}' must be an integer", .{key}),
            else => return a.d.fail(error.InvalidParams, "'{s}' must be an integer", .{key}),
        };
        if (n < min or n > max) return a.d.fail(error.InvalidParams, "'{s}' must be between {d} and {d}", .{ key, min, max });
        return n;
    }

    fn stringArray(a: Args, key: []const u8) DispatchError!?[]const []const u8 {
        const v = a.get(key) orelse return null;
        if (v != .array) return a.d.fail(error.InvalidParams, "'{s}' must be an array of strings", .{key});
        const out = try a.d.arena.alloc([]const u8, v.array.items.len);
        for (v.array.items, out) |item, *o| {
            if (item != .string) return a.d.fail(error.InvalidParams, "'{s}' must be an array of strings", .{key});
            o.* = item.string;
        }
        return out;
    }

    fn object(a: Args, key: []const u8) DispatchError!?Args {
        const v = a.get(key) orelse return null;
        if (v != .object) return a.d.fail(error.InvalidParams, "'{s}' must be an object", .{key});
        return .{ .d = a.d, .obj = v.object };
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// Tool definitions. The descriptions are what a model reads to decide how
// to call a tool: keep them short, and keep the key syntax in one place
// (headterm_send).

const wait_props =
    \\"text":{"type":"string","description":"Text is on screen (wrapped rows count as one line)."},
    \\"regex":{"type":"string","description":"A screen line matches: . [] \\d \\w \\s \\b ^ $ | () * + ? {n,m}, (?i) prefix for any case."},
    \\"gone":{"type":"string","description":"Text is no longer on screen, e.g. a spinner or 'Loading'."},
    \\"idle_ms":{"type":"integer","minimum":0,"maximum":60000,"description":"No output for this many ms."},
    \\"exit":{"type":"boolean","description":"The program exited."},
    \\"timeout_ms":{"type":"integer","minimum":0,"maximum":60000,"description":"Default 10000."}
;

const name_prop =
    \\"name":{"type":"string","description":"Session name: letters, digits, '.', '_', '-'."}
;

const styles_prop =
    \\"styles":{"type":"boolean","description":"Also list styled runs per row: 'row N: [start-end attrs \"text\"]'. Shows the selected menu item (inverse or a background color), red errors, the focused field."}
;

// Written over several lines for readability; the line breaks fall between
// JSON tokens and are removed so the reply stays on one line.
const tools_json = oneLine(tools_json_src);

fn oneLine(comptime src: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime var out: [src.len]u8 = undefined;
    comptime var n: usize = 0;
    inline for (src) |c| {
        if (c != '\n') {
            out[n] = c;
            n += 1;
        }
    }
    const final = out[0..n].*;
    return &final;
}

const tools_json_src =
    \\{"tools":[
++
    \\{"name":"headterm_start","description":"Start a program in a new terminal session and return its first screen, after 300 ms without output (at most 5 s). For interactive and full-screen programs: shells, REPLs, vim, less, installers.","inputSchema":{"type":"object","properties":{
++ name_prop ++
    \\,"command":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Program and arguments, e.g. [\"python3\", \"-q\"]."},
    \\"cols":{"type":"integer","minimum":2,"maximum":1000,"description":"Width, default 120."},
    \\"rows":{"type":"integer","minimum":1,"maximum":1000,"description":"Height, default 40."},
    \\"cwd":{"type":"string","description":"Working directory."},
    \\"ttl_s":{"type":"integer","minimum":0,"maximum":2592000,"description":"End the session after this many seconds without calls or output. Default 3600, 0 = never."},
    \\"record":{"type":"string","description":"Write an asciicast v2 recording to this file (play with asciinema play)."},
++ styles_prop ++ "," ++
    \\"then_wait":{"type":"object","description":"Wait for this instead of the 300 ms idle default.","properties":{
++ wait_props ++
    \\}}},"required":["name","command"]}},
++
    \\{"name":"headterm_send","description":"Send keys, optionally wait, and return the screen. Each keys element is text or a key: <Enter> <Tab> <Esc> <Backspace> <Space> <Up> <Down> <Left> <Right> <Home> <End> <PageUp> <PageDown> <Delete> <F1>..<F12> <lt>; modifiers <C-c> <M-x> <S-Tab>. Mouse, only if the program enabled it (0-based row,col): <Click r,c> <RightClick r,c> <Drag r1,c1 r2,c2> <ScrollUp r,c> <ScrollDown r,c>, also <S-Click r,c> <C-Click r,c>. Example: [\"ihello\", \"<Esc>\", \":wq\", \"<Enter>\"].","inputSchema":{"type":"object","properties":{
++ name_prop ++
    \\,"keys":{"type":"array","items":{"type":"string"},"description":"Sent in order; never treated as options."},
    \\"literal":{"type":"boolean","description":"Send keys as plain text, without <Key> parsing."},
    \\"paste":{"type":"boolean","description":"Send keys as one bracketed paste."},
    \\"esc_delay_ms":{"type":"integer","minimum":0,"maximum":10000,"description":"Pause after a lone <Esc> so it is not read as Alt. Default 100."},
++ styles_prop ++ "," ++
    \\"then_wait":{"type":"object","description":"Wait, then return the screen. {} means {\"idle_ms\":300}.","properties":{
++ wait_props ++
    \\}}},"required":["name","keys"]}},
++
    \\{"name":"headterm_screen","description":"Return the screen: rows, then a status line with size, cursor (0-based row,col), alt screen and exit status.","inputSchema":{"type":"object","properties":{
++ name_prop ++
    \\,"diff":{"type":"boolean","description":"Only rows whose text or styles changed since this MCP server's last screen, as 'row|text'."},
    \\"scrollback":{"type":"integer","minimum":0,"maximum":100000,"description":"Also return up to this many lines that scrolled off the top."},
++ styles_prop ++
    \\},"required":["name"]}},
++
    \\{"name":"headterm_wait","description":"Wait until the first of the given conditions holds, then return the screen. On timeout: an error result, with the screen.","inputSchema":{"type":"object","properties":{
++ name_prop ++ "," ++ wait_props ++ "," ++ styles_prop ++
    \\},"required":["name"]}},
++
    \\{"name":"headterm_resize","description":"Resize the terminal; the program gets SIGWINCH.","inputSchema":{"type":"object","properties":{
++ name_prop ++
    \\,"cols":{"type":"integer","minimum":2,"maximum":1000},"rows":{"type":"integer","minimum":1,"maximum":1000}},"required":["name","cols","rows"]}},
++
    \\{"name":"headterm_kill","description":"End a session: SIGHUP, then SIGTERM, then SIGKILL to the program.","inputSchema":{"type":"object","properties":{
++ name_prop ++
    \\},"required":["name"]}},
++
    \\{"name":"headterm_list","description":"List sessions: name, pid, size, status, command.","inputSchema":{"type":"object","properties":{}}}
    \\]}
;

// ======================================================================
// Tests

const testing = std.testing;

fn roundTrip(line: []const u8) !?json.Parsed(json.Value) {
    const reply = try handleLine(testing.allocator, line) orelse return null;
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOfScalar(u8, reply, '\n') == null);
    return try json.parseFromSlice(json.Value, testing.allocator, reply, .{});
}

fn expectErrorCode(line: []const u8, code: i64) !void {
    const p = (try roundTrip(line)).?;
    defer p.deinit();
    try testing.expectEqual(code, p.value.object.get("error").?.object.get("code").?.integer);
}

fn toolCall(args_json: []const u8) !json.Parsed(json.Value) {
    var buf: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{s}}}", .{args_json});
    return (try roundTrip(line)).?;
}

test "tools/list is valid JSON with all tools and schemas" {
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, tools_json, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    const names = [_][]const u8{ "headterm_start", "headterm_send", "headterm_screen", "headterm_wait", "headterm_resize", "headterm_kill", "headterm_list" };
    try testing.expectEqual(names.len, tools.len);
    for (tools, names) |t, n| {
        try testing.expectEqualStrings(n, t.object.get("name").?.string);
        const schema = t.object.get("inputSchema").?.object;
        try testing.expectEqualStrings("object", schema.get("type").?.string);
        try testing.expect(schema.get("properties").? == .object);
    }

    const p = (try roundTrip("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")).?;
    defer p.deinit();
    try testing.expectEqual(@as(i64, 2), p.value.object.get("id").?.integer);
    try testing.expectEqual(names.len, p.value.object.get("result").?.object.get("tools").?.array.items.len);
}

test "initialize negotiates the protocol version" {
    {
        const p = (try roundTrip("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")).?;
        defer p.deinit();
        const r = p.value.object.get("result").?.object;
        try testing.expectEqualStrings("2025-03-26", r.get("protocolVersion").?.string);
        try testing.expect(r.get("capabilities").?.object.get("tools").? == .object);
        try testing.expectEqualStrings("headterm", r.get("serverInfo").?.object.get("name").?.string);
        try testing.expectEqualStrings(server.version, r.get("serverInfo").?.object.get("version").?.string);
    }
    {
        const p = (try roundTrip("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}")).?;
        defer p.deinit();
        try testing.expectEqualStrings("abc", p.value.object.get("id").?.string);
        try testing.expectEqualStrings(default_version, p.value.object.get("result").?.object.get("protocolVersion").?.string);
    }
}

test "notifications get no reply" {
    try testing.expect((try roundTrip("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == null);
    try testing.expect((try roundTrip("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}")) == null);
    try testing.expect((try roundTrip("{\"jsonrpc\":\"2.0\",\"method\":\"no/such/thing\"}")) == null);
    try testing.expect((try roundTrip("   ")) == null);
}

test "ping" {
    const p = (try roundTrip("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}")).?;
    defer p.deinit();
    try testing.expect(p.value.object.get("result").? == .object);
    try testing.expectEqual(@as(usize, 0), p.value.object.get("result").?.object.count());
}

test "protocol errors" {
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\"}", -32601);
    try expectErrorCode("{not json", -32700);
    try expectErrorCode("[1,2]", -32600);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1}", -32600);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_screen\",\"arguments\":{}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_wait\",\"arguments\":{\"name\":\"x\"}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_wait\",\"arguments\":{\"name\":\"x\",\"idle_ms\":100,\"timeout_ms\":600000}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_send\",\"arguments\":{\"name\":\"x\",\"keys\":\"abc\"}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_start\",\"arguments\":{\"name\":\"x\",\"command\":[]}}}", -32602);

    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_wait\",\"arguments\":{\"name\":\"x\",\"regex\":\"a{9,1}\"}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_send\",\"arguments\":{\"name\":\"x\",\"keys\":[],\"then_wait\":{\"regex\":\"(\"}}}}", -32602);
    try expectErrorCode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"headterm_start\",\"arguments\":{\"name\":\"x\",\"command\":[\"sh\"],\"ttl_s\":-1}}}", -32602);

    // A parse error carries a null id.
    const p = (try roundTrip("{\"id\":")).?;
    defer p.deinit();
    try testing.expect(p.value.object.get("id").? == .null);
}

test "tool failures are results with isError" {
    {
        const p = try toolCall("{\"name\":\"headterm_screen\",\"arguments\":{\"name\":\"bad/name\"}}");
        defer p.deinit();
        const r = p.value.object.get("result").?.object;
        try testing.expect(r.get("isError").?.bool);
        const content = r.get("content").?.array.items[0].object;
        try testing.expectEqualStrings("text", content.get("type").?.string);
        try testing.expect(std.mem.indexOf(u8, content.get("text").?.string, "invalid session name") != null);
    }
    {
        const p = try toolCall("{\"name\":\"headterm_kill\",\"arguments\":{\"name\":\"headterm-unit-test-no-such-session\"}}");
        defer p.deinit();
        const r = p.value.object.get("result").?.object;
        try testing.expect(r.get("isError").?.bool);
        try testing.expect(std.mem.indexOf(u8, r.get("content").?.array.items[0].object.get("text").?.string, "no session named") != null);
    }
}

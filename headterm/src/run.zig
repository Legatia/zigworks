//! `run`: start a program, play a script of steps (send keys, wait, take a
//! screen), report every step and the final screen, then end the session.
//! One call for a whole menu, wizard or passphrase prompt.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const json = std.json;
const client = @import("client.zig");
const regex = @import("regex.zig");

pub const Wait = struct {
    text: ?[]const u8 = null,
    regex: ?[]const u8 = null,
    gone: ?[]const u8 = null,
    idle_ms: ?i64 = null,
    settle_ms: ?i64 = null,
    exit: bool = false,
    timeout_ms: ?i64 = null,

    fn hasCondition(w: Wait) bool {
        return w.text != null or w.regex != null or w.gone != null or w.idle_ms != null or w.settle_ms != null or w.exit;
    }

    fn appendArgs(w: Wait, arena: Allocator, args: *std.ArrayList([]const u8)) !void {
        if (w.text) |t| try args.appendSlice(arena, &.{ "--text", t });
        if (w.regex) |r| try args.appendSlice(arena, &.{ "--regex", r });
        if (w.gone) |t| try args.appendSlice(arena, &.{ "--text-gone", t });
        if (w.idle_ms) |ms| try args.appendSlice(arena, &.{ "--idle", try std.fmt.allocPrint(arena, "{d}", .{ms}) });
        if (w.settle_ms) |ms| try args.appendSlice(arena, &.{ "--settle", try std.fmt.allocPrint(arena, "{d}", .{ms}) });
        if (w.exit) try args.append(arena, "--exit");
        if (w.timeout_ms) |ms| try args.appendSlice(arena, &.{ "--timeout", try std.fmt.allocPrint(arena, "{d}", .{ms}) });
    }
};

pub const Step = union(enum) {
    send: struct { keys: []const []const u8, literal: bool = false },
    wait: Wait,
    screen,
};

pub const Options = struct {
    name: []const u8,
    /// Empty: play the steps on the existing session `name` instead.
    argv: []const []const u8,
    start: client.StartOptions = .{},
    /// Keep the session after a successful run.
    keep: bool = false,
    styles: bool = false,
    /// Diff marker id, so screens taken here don't disturb other clients.
    client_id: ?[]const u8 = null,
};

/// How long a session survives when a step failed and it is kept for the
/// caller to recover, unless a TTL was given.
pub const failure_ttl_s = 600;
/// And when it is kept with --keep.
pub const keep_ttl_s = 3600;
const max_ms = 60_000;

pub const Error = client.CallError || error{Cancelled} || posix.PollError;

/// Sends one request to a session. The MCP server's version watches stdin
/// for cancellation.
pub const Caller = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, name: []const u8, args: []const []const u8) Error!client.Response,

    fn call(c: Caller, name: []const u8, args: []const []const u8) Error!client.Response {
        return c.callFn(c.ctx, name, args);
    }
};

pub const Result = struct {
    text: []const u8,
    ok: bool,
};

/// Runs the script. Everything is allocated in `arena`; `gpa` is passed to
/// the session server it starts.
pub fn run(arena: Allocator, gpa: Allocator, opts: Options, steps: []const Step, caller: Caller) (Error || error{ OutOfMemory, WriteFailed })!Result {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    // An existing session has already drawn its screen.
    const existing = opts.argv.len == 0;
    var waited_before_send = existing;
    var last_screen: []const u8 = "";
    if (opts.argv.len > 0) {
        var msg: [256]u8 = undefined;
        const pid = client.startSession(gpa, opts.name, opts.argv, opts.start, &msg) catch {
            try w.print("start failed: {s}", .{std.mem.sliceTo(&msg, 0)});
            return .{ .text = out.written(), .ok = false };
        };
        try w.print("started {s} pid={d}\n", .{ opts.name, pid });
    }

    var failed_at: ?usize = null;
    var exited_at_failure = false;
    var last_was_send = false;
    for (steps, 1..) |step, n| {
        switch (step) {
            .send => |s| {
                // Keys sent before the program has drawn anything can be lost
                // or misread, so let its first output settle (at most 2 s).
                if (!waited_before_send) {
                    _ = try session(arena, caller, opts, &.{ "wait", "--settle", "150", "--timeout", "2000" });
                    waited_before_send = true;
                }
                var args: std.ArrayList([]const u8) = .empty;
                try args.append(arena, "send");
                try args.append(arena, if (s.literal) "--literal" else "--");
                try args.appendSlice(arena, s.keys);
                const r = try session(arena, caller, opts, args.items);
                if (!r.ok) {
                    try w.print("{d} send FAILED: {s}\n", .{ n, r.text });
                    failed_at = n;
                    break;
                }
                // The session says so when it read `down enter` as keys.
                if (r.text.len > 0) try w.print("{d} send ok, {s}\n", .{ n, r.text }) else try w.print("{d} send ok\n", .{n});
                last_was_send = true;
            },
            .wait => |wt| {
                waited_before_send = true;
                var args: std.ArrayList([]const u8) = .empty;
                try args.append(arena, "wait");
                try wt.appendArgs(arena, &args);
                try screenArgs(arena, &args, opts);
                const r = try session(arena, caller, opts, args.items);
                if (!r.ok) {
                    try w.print("{d} wait FAILED: ", .{n});
                    try writeWaitStatus(w, r.text);
                    try w.print("\nscreen at failure:\n{s}\n", .{stripWait(r.text)});
                    failed_at = n;
                    exited_at_failure = programExited(r.text);
                    break;
                }
                try w.print("{d} wait ", .{n});
                try writeWaitStatus(w, r.text);
                try w.writeByte('\n');
                last_was_send = false;
            },
            .screen => {
                last_screen = try capture(arena, caller, opts, last_was_send or !waited_before_send);
                try w.print("{d} screen:\n{s}\n", .{ n, last_screen });
                last_was_send = false;
                waited_before_send = true;
            },
        }
    }

    if (failed_at) |n| {
        try w.print("stopped at step {d} of {d}; ", .{ n, steps.len });
        if (exited_at_failure and !opts.keep) {
            _ = try session(arena, caller, opts, &.{"kill"});
            try w.writeAll("the program exited, session ended");
        } else if (existing) {
            try w.print("session {s} kept (its program is still running)", .{opts.name});
        } else {
            try w.print("session {s} kept for recovery (send/screen/kill it; it ends after {d} s idle)", .{ opts.name, opts.start.ttl_s orelse failure_ttl_s });
        }
        return .{ .text = out.written(), .ok = false };
    }

    // A screen step at the very end already showed the final screen.
    if (steps.len == 0 or steps[steps.len - 1] != .screen) {
        last_screen = try capture(arena, caller, opts, last_was_send or !waited_before_send);
        try w.print("final screen:\n{s}\n", .{last_screen});
    }

    // A session the caller started earlier is theirs: steps played on it
    // with --session leave it running, so the next call can continue. It
    // ends here only once its program has exited.
    const exited = programExited(last_screen);
    if (opts.keep or (existing and !exited)) {
        try w.print("session {s} kept", .{opts.name});
        if (existing and !opts.keep) try w.writeAll(" (its program is still running)");
    } else {
        const k = try session(arena, caller, opts, &.{"kill"});
        if (existing) {
            try w.writeAll("the program exited, session ended");
        } else {
            try w.writeAll(if (k.ok) "session ended" else "session already ended");
        }
    }
    return .{ .text = out.written(), .ok = true };
}

/// The screen. Right after a send, or before the program has been given time
/// to draw at all, it gets a moment first: until its output has been quiet
/// for 200 ms (at most 3 s).
fn capture(arena: Allocator, caller: Caller, opts: Options, settle: bool) Error![]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (settle) {
        try args.appendSlice(arena, &.{ "wait", "--settle", "200", "--timeout", "3000" });
    } else {
        try args.append(arena, "screen");
    }
    try screenArgs(arena, &args, opts);
    const r = try session(arena, caller, opts, args.items);
    return stripWait(r.text);
}

fn screenArgs(arena: Allocator, args: *std.ArrayList([]const u8), opts: Options) !void {
    try args.append(arena, "--trim");
    if (opts.styles) try args.append(arena, "--styles");
    if (opts.client_id) |id| try args.appendSlice(arena, &.{ "--client", id });
}

const SessionResult = struct { text: []const u8, ok: bool };

fn session(arena: Allocator, caller: Caller, opts: Options, args: []const []const u8) Error!SessionResult {
    const resp = caller.call(opts.name, args) catch |err| switch (err) {
        error.Cancelled => {
            // The caller gave up: don't leave the program running.
            if (client.call(arena, opts.name, &.{"kill"})) |_| {} else |_| {}
            return error.Cancelled;
        },
        error.InvalidName, error.NoSuchSession, error.StaleSession, error.BadResponse => |e| {
            var buf: [256]u8 = undefined;
            return .{ .text = try arena.dupe(u8, client.describeError(&buf, e, opts.name)), .ok = false };
        },
        else => |e| return e,
    };
    return .{ .text = std.mem.trimRight(u8, resp.body, "\n"), .ok = resp.status == .ok };
}

fn statusLine(body: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| body[i + 1 ..] else body;
}

/// "ok(text) 12ms" from a wait response's "wait=ok(text) waited=12ms".
fn writeWaitStatus(w: *std.Io.Writer, body: []const u8) !void {
    const last = statusLine(body);
    const at = std.mem.indexOf(u8, last, " wait=") orelse return w.writeAll(std.mem.trim(u8, last, " "));
    var it = std.mem.tokenizeScalar(u8, last[at + 6 ..], ' ');
    try w.writeAll(it.next() orelse "");
    if (it.next()) |waited| {
        if (std.mem.startsWith(u8, waited, "waited=")) try w.print(" {s}", .{waited[7..]});
    }
}

fn programExited(body: []const u8) bool {
    const last = statusLine(body);
    return std.mem.indexOf(u8, last, " exited") != null or std.mem.indexOf(u8, last, " killed-by-signal=") != null;
}

/// The final screen's status line without the internal settle wait.
fn stripWait(body: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, body, " wait=") orelse return body;
    if (std.mem.indexOfScalarPos(u8, body, at, '\n') != null) return body;
    return body[0..at];
}

// ----------------------------------------------------------------------
// Parsing steps from JSON (MCP arguments, `headterm run --steps`)

pub const ParseError = error{InvalidSteps} || Allocator.Error;

/// Parses `[{"send": [...], "literal": bool?} | {"wait": {...}} |
/// {"screen": true}, ...]`. On error, `err_msg` says what is wrong.
pub fn parseSteps(arena: Allocator, value: json.Value, err_msg: *[]const u8) ParseError![]Step {
    if (value != .array) return fail(arena, err_msg, "steps must be an array", .{});
    if (value.array.items.len == 0) return fail(arena, err_msg, "steps must not be empty", .{});
    if (value.array.items.len > 100) return fail(arena, err_msg, "at most 100 steps", .{});
    const steps = try arena.alloc(Step, value.array.items.len);
    for (value.array.items, steps, 1..) |item, *step, n| {
        if (item != .object) return fail(arena, err_msg, "step {d}: must be an object", .{n});
        const o = item.object;
        if (o.get("send")) |keys| {
            if (keys != .array or keys.array.items.len == 0) return fail(arena, err_msg, "step {d}: send must be a non-empty array of strings", .{n});
            const list = try arena.alloc([]const u8, keys.array.items.len);
            for (keys.array.items, list) |k, *dst| {
                if (k != .string) return fail(arena, err_msg, "step {d}: send must be a non-empty array of strings", .{n});
                dst.* = k.string;
            }
            const literal = switch (o.get("literal") orelse json.Value{ .bool = false }) {
                .bool => |b| b,
                else => return fail(arena, err_msg, "step {d}: literal must be a boolean", .{n}),
            };
            step.* = .{ .send = .{ .keys = list, .literal = literal } };
        } else if (o.get("wait")) |wv| {
            if (wv != .object) return fail(arena, err_msg, "step {d}: wait must be an object", .{n});
            step.* = .{ .wait = try parseWait(arena, wv.object, n, err_msg) };
        } else if (o.get("screen")) |sv| {
            if (sv != .bool or !sv.bool) return fail(arena, err_msg, "step {d}: use {{\"screen\": true}}", .{n});
            step.* = .screen;
        } else {
            return fail(arena, err_msg, "step {d}: needs one of send, wait, screen", .{n});
        }
    }
    return steps;
}

fn parseWait(arena: Allocator, o: json.ObjectMap, n: usize, err_msg: *[]const u8) ParseError!Wait {
    var w: Wait = .{};
    var it = o.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (eql(k, "text") or eql(k, "regex") or eql(k, "gone")) {
            if (v != .string) return fail(arena, err_msg, "step {d}: wait.{s} must be a string", .{ n, k });
            if (eql(k, "text")) w.text = v.string else if (eql(k, "gone")) w.gone = v.string else w.regex = v.string;
        } else if (eql(k, "idle_ms") or eql(k, "timeout_ms")) {
            const ms: i64 = switch (v) {
                .integer => |i| i,
                else => return fail(arena, err_msg, "step {d}: wait.{s} must be an integer", .{ n, k }),
            };
            if (ms < 0 or ms > max_ms) return fail(arena, err_msg, "step {d}: wait.{s} must be 0..60000", .{ n, k });
            if (eql(k, "idle_ms")) w.idle_ms = ms else w.timeout_ms = ms;
        } else if (eql(k, "exit")) {
            if (v != .bool) return fail(arena, err_msg, "step {d}: wait.exit must be a boolean", .{n});
            w.exit = v.bool;
        } else {
            return fail(arena, err_msg, "step {d}: unknown wait field '{s}'", .{ n, k });
        }
    }
    if (!w.hasCondition()) return fail(arena, err_msg, "step {d}: wait needs text, regex, gone, idle_ms or exit", .{n});
    if (w.regex) |pattern| {
        var diag: regex.Diagnostic = .{};
        var re = regex.Regex.compile(arena, pattern, &diag) catch |err| switch (err) {
            error.BadRegex => return fail(arena, err_msg, "step {d}: bad regex: {s}", .{ n, diag.message() }),
            else => |e| return e,
        };
        re.deinit();
    }
    return w;
}

fn fail(arena: Allocator, err_msg: *[]const u8, comptime fmt: []const u8, args: anytype) ParseError {
    err_msg.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.InvalidSteps;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ======================================================================
// Tests

const testing = std.testing;

fn expectParseError(src: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, arena, src, .{});
    var msg: []const u8 = "";
    try testing.expectError(error.InvalidSteps, parseSteps(arena, v, &msg));
    try testing.expectEqualStrings(expected, msg);
}

test "parse steps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, arena,
        \\[{"send": ["<Down>", "<Enter>"]}, {"send": ["<pw>"], "literal": true},
        \\ {"wait": {"regex": "^saved", "timeout_ms": 2000}}, {"screen": true}]
    , .{});
    var msg: []const u8 = "";
    const steps = try parseSteps(arena, v, &msg);
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqualStrings("<Enter>", steps[0].send.keys[1]);
    try testing.expect(!steps[0].send.literal);
    try testing.expect(steps[1].send.literal);
    try testing.expectEqualStrings("^saved", steps[2].wait.regex.?);
    try testing.expectEqual(@as(?i64, 2000), steps[2].wait.timeout_ms);
    try testing.expect(steps[3] == .screen);
}

test "bad steps are rejected with the step number" {
    try expectParseError("[]", "steps must not be empty");
    try expectParseError("{}", "steps must be an array");
    try expectParseError("[{\"send\": []}]", "step 1: send must be a non-empty array of strings");
    try expectParseError("[{\"screen\": true}, {\"wait\": {}}]", "step 2: wait needs text, regex, gone, idle_ms or exit");
    try expectParseError("[{\"wait\": {\"regex\": \"(\"}}]", "step 1: bad regex: missing ')' at offset 1");
    try expectParseError("[{\"wait\": {\"idle_ms\": 99999}}]", "step 1: wait.idle_ms must be 0..60000");
    try expectParseError("[{\"wait\": {\"txt\": \"a\"}}]", "step 1: unknown wait field 'txt'");
    try expectParseError("[{\"type\": \"send\"}]", "step 1: needs one of send, wait, screen");
}

test "wait status and stripWait" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeWaitStatus(&w, "a\n[headterm] x 10x2 cursor=0,0 running wait=ok(text) waited=3ms");
    try testing.expectEqualStrings("ok(text) 3ms", w.buffered());
    try testing.expect(programExited("[headterm] x 10x2 cursor=0,0 exited=1 wait=failed(exited) waited=5ms"));
    try testing.expect(!programExited("[headterm] x 10x2 cursor=0,0 running wait=failed(timeout) waited=5ms"));
    try testing.expectEqualStrings("a\n[headterm] x 10x2 running", stripWait("a\n[headterm] x 10x2 running wait=ok(settle) waited=200ms"));
}

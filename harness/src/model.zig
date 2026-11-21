//! The model, through omnigate's Anthropic-style `/v1/messages`: one
//! request with the conversation and the tools, one whole answer back.
const std = @import("std");
const http = @import("http.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const Block = union(enum) {
    text: []const u8,
    tool_use: struct { id: []const u8, name: []const u8, input_json: []const u8 },
    tool_result: struct { id: []const u8, content: []const u8, is_error: bool = false },
};

pub const Role = enum { user, assistant };

pub const Message = struct { role: Role, blocks: []const Block };

pub const ToolDef = struct { name: []const u8, description: []const u8, schema_json: []const u8 };

pub const Reply = struct {
    blocks: []Block,
    stop_reason: []const u8,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    /// Prompt-cache figures: input read from cache, input written to it.
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn text(r: Reply, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (r.blocks) |b| if (b == .text) {
            if (out.items.len > 0) try out.append(arena, '\n');
            try out.appendSlice(arena, b.text);
        };
        return out.items;
    }
};

pub const Error = error{
    /// omnigate answered 402: the key's budget is spent. Never retried.
    BudgetSpent,
    /// 429 twice in a row.
    RateLimited,
    /// 400 or 413: the request itself was refused (invalid, or too
    /// large); sent again unchanged it would be refused again.
    Rejected,
    /// Any other error status from omnigate or the provider.
    Upstream,
    /// The answer was not the expected JSON.
    BadReply,
    /// No key is stored: the call is refused before anything is sent.
    NoKey,
    /// No url is set: the call is refused before anything is sent.
    NoUrl,
    /// /stop came while waiting to send again: nothing more was sent.
    Stopped,
    /// The turn's time ran out: the call was not sent, or was cut off at
    /// the turn's deadline (told apart from a call that took too long by
    /// itself, whatever the clocks round to).
    TimeUp,
} || http.Error;

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Null when no url is set: every call is refused.
    http: ?http.Client,
    key: []const u8,
    model: []const u8,
    max_tokens: u32,
    /// The error message omnigate gave with the last failure, if any.
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
    /// Longest wait on a 429 (seconds).
    max_retry_wait: u32 = 60,
    /// Longest one call may take (ms), whatever the deadline.
    call_ms: u32 = 900_000,

    /// An empty `url` or `key` gives a client whose calls are refused
    /// (error.NoUrl, error.NoKey), so nothing is sent without both.
    pub fn init(gpa: std.mem.Allocator, io: Io, url: []const u8, key: []const u8, model: []const u8, max_tokens: u32) http.Error!Client {
        const target: ?http.Target = if (url.len == 0) null else try http.Target.parse(url);
        return .{ .gpa = gpa, .io = io, .http = if (target) |tg| .init(gpa, io, tg) else null, .key = key, .model = model, .max_tokens = max_tokens };
    }

    pub fn deinit(c: *Client) void {
        if (c.http) |*h| h.deinit();
    }

    pub fn lastError(c: *const Client) []const u8 {
        return c.last_error[0..c.last_error_len];
    }

    /// What a call's waits end on.
    pub const Limits = struct {
        /// Set: no retry and no wait after it is true.
        stop: ?*const std.atomic.Value(bool) = null,
        /// Unix seconds by which the call must be over; 0: none.
        deadline_s: i64 = 0,
    };

    /// A one-off call: the system prompt goes as plain text, unmarked.
    pub fn send(c: *Client, arena: std.mem.Allocator, system: []const u8, messages: []const Message, tools: []const ToolDef) Error!Reply {
        return c.sendSystem(arena, .{ .stable = system, .cache = false }, messages, tools, .{});
    }

    /// A call of a turn: `stable` is the part of the system prompt that
    /// stays the same from call to call (marked for the prompt cache),
    /// `changing` the rest.
    pub fn sendParts(c: *Client, arena: std.mem.Allocator, stable: []const u8, changing: []const u8, messages: []const Message, tools: []const ToolDef, lim: Limits) Error!Reply {
        return c.sendSystem(arena, .{ .stable = stable, .changing = changing }, messages, tools, lim);
    }

    fn sendSystem(c: *Client, arena: std.mem.Allocator, system: System, messages: []const Message, tools: []const ToolDef, lim: Limits) Error!Reply {
        if (c.http == null) return error.NoUrl;
        if (c.key.len == 0) return error.NoKey;
        const body = try requestBody(arena, c.model, c.max_tokens, system, messages, tools);
        var limited = false;
        var connect_retry = false;
        while (true) {
            if (stopped(lim)) return error.Stopped;
            // past the deadline nothing is sent; before it, the answer is
            // waited for only until then
            const ms = c.callLimit(lim) orelse return error.TimeUp;
            // shorter than a call may take: the turn's deadline set it
            const by_deadline = lim.deadline_s > 0 and ms < c.call_ms;
            const r = c.post(arena, body, ms) catch |e| switch (e) {
                // nothing reached the server: once more
                error.ConnectFailed => {
                    if (connect_retry) return e;
                    connect_retry = true;
                    continue;
                },
                error.Timeout => return if (by_deadline) error.TimeUp else e,
                // cut off after it was sent: the model may have answered
                // it, and sent again it may be billed twice
                else => return e,
            };
            switch (r.status) {
                200 => return parseReply(arena, r.body) orelse error.BadReply,
                402 => {
                    c.note(r.body);
                    return error.BudgetSpent;
                },
                400, 413 => {
                    c.note(r.body);
                    return error.Rejected;
                },
                429 => {
                    c.note(r.body);
                    if (limited) return error.RateLimited;
                    limited = true;
                    try c.pause(@min(r.retry_after_s orelse 5, c.max_retry_wait), lim);
                },
                else => {
                    c.note(r.body);
                    return error.Upstream;
                },
            }
        }
    }

    fn stopped(lim: Limits) bool {
        const f = lim.stop orelse return false;
        return f.load(.acquire);
    }

    /// How long the next call may take (ms): `call_ms`, or less to end by
    /// the deadline; null once the deadline has passed.
    fn callLimit(c: *const Client, lim: Limits) ?u32 {
        if (lim.deadline_s == 0) return c.call_ms;
        const left = lim.deadline_s * 1000 - nowMs(c.io);
        if (left <= 0) return null;
        return @intCast(@min(left, c.call_ms));
    }

    /// Waits `seconds` before asking again: error.Stopped on /stop,
    /// error.RateLimited at once when the wait would end past the deadline.
    fn pause(c: *Client, seconds: u32, lim: Limits) Error!void {
        const wait_ms = @as(i64, seconds) * 1000;
        if (lim.deadline_s > 0 and nowMs(c.io) + wait_ms >= lim.deadline_s * 1000) return error.RateLimited;
        const until = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, wait_ms) * std.time.ns_per_ms;
        while (Io.Clock.awake.now(c.io).nanoseconds < until) {
            if (stopped(lim)) return error.Stopped;
            c.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        if (stopped(lim)) return error.Stopped;
    }

    fn nowMs(io: Io) i64 {
        return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
    }

    const Raw = struct { status: u16, body: []u8, retry_after_s: ?u32 };

    fn post(c: *Client, arena: std.mem.Allocator, body: []const u8, total_ms: u32) http.Error!Raw {
        var resp = try c.http.?.send(.{
            .path = "/v1/messages",
            .body = body,
            .headers = &.{
                .{ .name = "x-api-key", .value = c.key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            },
            .limits = .{ .idle_ms = @min(300_000, total_ms), .total_ms = total_ms },
        });
        defer resp.deinit();
        const got = try resp.readAll(arena, 32 << 20);
        return .{ .status = resp.status, .body = got, .retry_after_s = resp.retry_after_s };
    }

    fn note(c: *Client, body: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const v = jv.parse(arena.allocator(), body);
        const msg = jv.str(jv.at(v, &.{ "error", "message" })) orelse body;
        const s = util.cut(msg, c.last_error.len);
        @memcpy(c.last_error[0..s.len], s);
        c.last_error_len = s.len;
    }
};

const cache_mark = ",\"cache_control\":{\"type\":\"ephemeral\"}";

/// The system prompt of one request.
pub const System = struct {
    /// The same from call to call: marked for the prompt cache when `cache`.
    stable: []const u8,
    /// The rest, after it; never marked.
    changing: []const u8 = "",
    /// false: a one-off call, sent as plain text.
    cache: bool = true,
};

/// Prompt-cache marks (at most 4 are allowed): the last tool, the stable
/// system part (calls of a turn), and the last message's last block, so
/// each step of a turn reads the steps before it from cache, and a new
/// turn reads at least the tools and the instructions.
pub fn requestBody(arena: std.mem.Allocator, model: []const u8, max_tokens: u32, system: System, messages: []const Message, tools: []const ToolDef) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"model\":");
    try util.jsonString(&out, arena, model);
    try out.print(arena, ",\"max_tokens\":{d},\"system\":", .{max_tokens});
    // an empty text block is refused, so an empty part is left out
    const marked = system.cache and system.stable.len > 0;
    if (!marked and system.changing.len == 0) {
        try util.jsonString(&out, arena, system.stable);
    } else {
        try out.append(arena, '[');
        if (system.stable.len > 0) {
            try out.appendSlice(arena, "{\"type\":\"text\",\"text\":");
            try util.jsonString(&out, arena, system.stable);
            if (marked) try out.appendSlice(arena, cache_mark);
            try out.append(arena, '}');
        }
        if (system.changing.len > 0) {
            if (system.stable.len > 0) try out.append(arena, ',');
            try out.appendSlice(arena, "{\"type\":\"text\",\"text\":");
            try util.jsonString(&out, arena, system.changing);
            try out.append(arena, '}');
        }
        try out.append(arena, ']');
    }
    try out.appendSlice(arena, ",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try out.append(arena, ',');
        try out.print(arena, "{{\"role\":\"{s}\",\"content\":[", .{@tagName(m.role)});
        for (m.blocks, 0..) |b, j| {
            if (j > 0) try out.append(arena, ',');
            const mark = i + 1 == messages.len and j + 1 == m.blocks.len;
            switch (b) {
                .text => |s| {
                    try out.appendSlice(arena, "{\"type\":\"text\",\"text\":");
                    try util.jsonString(&out, arena, s);
                    if (mark) try out.appendSlice(arena, cache_mark);
                    try out.append(arena, '}');
                },
                .tool_use => |u| {
                    try out.appendSlice(arena, "{\"type\":\"tool_use\",\"id\":");
                    try util.jsonString(&out, arena, u.id);
                    try out.appendSlice(arena, ",\"name\":");
                    try util.jsonString(&out, arena, u.name);
                    try out.print(arena, ",\"input\":{s}", .{if (u.input_json.len > 0) u.input_json else "{}"});
                    if (mark) try out.appendSlice(arena, cache_mark);
                    try out.append(arena, '}');
                },
                .tool_result => |r| {
                    try out.appendSlice(arena, "{\"type\":\"tool_result\",\"tool_use_id\":");
                    try util.jsonString(&out, arena, r.id);
                    try out.appendSlice(arena, ",\"content\":");
                    try util.jsonString(&out, arena, r.content);
                    try out.print(arena, ",\"is_error\":{s}", .{if (r.is_error) "true" else "false"});
                    if (mark) try out.appendSlice(arena, cache_mark);
                    try out.append(arena, '}');
                },
            }
        }
        try out.appendSlice(arena, "]}");
    }
    try out.append(arena, ']');
    if (tools.len > 0) {
        try out.appendSlice(arena, ",\"tools\":[");
        for (tools, 0..) |td, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, "{\"name\":");
            try util.jsonString(&out, arena, td.name);
            try out.appendSlice(arena, ",\"description\":");
            try util.jsonString(&out, arena, td.description);
            try out.print(arena, ",\"input_schema\":{s}", .{td.schema_json});
            if (i + 1 == tools.len) try out.appendSlice(arena, cache_mark);
            try out.append(arena, '}');
        }
        try out.append(arena, ']');
    }
    try out.append(arena, '}');
    return out.items;
}

pub fn parseReply(arena: std.mem.Allocator, body: []const u8) ?Reply {
    const v = jv.parse(arena, body) orelse return null;
    const content = jv.arr(jv.get(v, "content")) orelse return null;
    var blocks: std.ArrayList(Block) = .empty;
    for (content) |b| {
        const typ = jv.str(jv.get(b, "type")) orelse continue;
        if (std.mem.eql(u8, typ, "text")) {
            blocks.append(arena, .{ .text = jv.str(jv.get(b, "text")) orelse "" }) catch return null;
        } else if (std.mem.eql(u8, typ, "tool_use")) {
            const input = jv.get(b, "input") orelse std.json.Value{ .object = .empty };
            const input_json = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(input, .{})}) catch return null;
            blocks.append(arena, .{ .tool_use = .{
                .id = jv.str(jv.get(b, "id")) orelse return null,
                .name = jv.str(jv.get(b, "name")) orelse return null,
                .input_json = input_json,
            } }) catch return null;
        }
    }
    return .{
        .blocks = blocks.items,
        .stop_reason = jv.str(jv.get(v, "stop_reason")) orelse "",
        .input_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "input_tokens" })) orelse 0)),
        .output_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "output_tokens" })) orelse 0)),
        .cache_read_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "cache_read_input_tokens" })) orelse 0)),
        .cache_write_tokens = @intCast(@max(0, jv.int(jv.at(v, &.{ "usage", "cache_creation_input_tokens" })) orelse 0)),
    };
}

// ---- tests ----

const t = std.testing;
const fake = @import("fake.zig");

pub const TestEnv = struct {
    tmp: t.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    server: *fake.Server,

    pub fn init(e: *TestEnv) !void {
        e.tmp = t.tmpDir(.{});
        e.arena = .init(t.allocator);
        e.dir = try e.tmp.dir.realPathFileAlloc(t.io, ".", e.arena.allocator());
        e.server = try fake.Server.start(t.io, e.dir, 0);
    }

    pub fn deinit(e: *TestEnv) void {
        e.server.stop();
        e.arena.deinit();
        e.tmp.cleanup();
    }

    pub fn url(e: *TestEnv) ![]const u8 {
        return std.fmt.allocPrint(e.arena.allocator(), "http://127.0.0.1:{d}", .{e.server.port});
    }

    /// Writes the n-th scripted model answer.
    pub fn script(e: *TestEnv, n: u32, body: []const u8) !void {
        const name = try std.fmt.allocPrint(e.arena.allocator(), "model/{d:0>3}.json", .{n});
        try e.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = body });
    }

    pub fn request(e: *TestEnv, n: u32) ![]u8 {
        const name = try std.fmt.allocPrint(e.arena.allocator(), "requests/{d:0>3}.json", .{n});
        return e.tmp.dir.readFileAlloc(t.io, name, e.arena.allocator(), .unlimited);
    }

    pub fn client(e: *TestEnv) !Client {
        var c = try Client.init(t.allocator, t.io, try e.url(), "og-test-key", "claude-test", 1000);
        c.max_retry_wait = 1;
        return c;
    }
};

pub fn textReply(comptime s: []const u8) []const u8 {
    return "{\"content\":[{\"type\":\"text\",\"text\":\"" ++ s ++ "\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}";
}

pub fn toolReply(comptime id: []const u8, comptime name: []const u8, comptime input: []const u8) []const u8 {
    return "{\"content\":[{\"type\":\"text\",\"text\":\"Let me check.\"},{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":" ++ input ++ "}],\"stop_reason\":\"tool_use\"}";
}

test "text_reply_parsed" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("Hello there."));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "be brief", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{});
    try t.expectEqualStrings("Hello there.", try r.text(a));
    try t.expectEqualStrings("end_turn", r.stop_reason);
    try t.expectEqual(10, r.input_tokens);
}

test "tool_use_reply_parsed_with_input_json" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, toolReply("tu_1", "shell", "{\"command\":\"ls -l\"}"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "", &.{.{ .role = .user, .blocks = &.{.{ .text = "list" }} }}, &.{.{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" }});
    try t.expectEqual(2, r.blocks.len);
    const u = r.blocks[1].tool_use;
    try t.expectEqualStrings("tu_1", u.id);
    try t.expectEqualStrings("shell", u.name);
    try t.expectEqualStrings("{\"command\":\"ls -l\"}", u.input_json);
}

test "request_carries_x_api_key_and_version" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("ok"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    _ = try c.send(a, "sys", &.{
        .{ .role = .user, .blocks = &.{.{ .text = "run it" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_use = .{ .id = "tu_9", .name = "shell", .input_json = "{\"command\":\"date\"}" } }} },
        .{ .role = .user, .blocks = &.{.{ .tool_result = .{ .id = "tu_9", .content = "Thu \"Nov\"", .is_error = false } }} },
    }, &.{.{ .name = "shell", .description = "run", .schema_json = "{\"type\":\"object\"}" }});
    const req = try e.request(1);
    const v = jv.parse(a, req).?;
    try t.expectEqualStrings("og-test-key", jv.str(jv.at(v, &.{ "headers", "x-api-key" })).?);
    try t.expectEqualStrings("2023-06-01", jv.str(jv.at(v, &.{ "headers", "anthropic-version" })).?);
    try t.expectEqualStrings("claude-test", jv.str(jv.at(v, &.{ "body", "model" })).?);
    try t.expectEqualStrings("sys", jv.str(jv.at(v, &.{ "body", "system" })).?);
    const msgs = jv.arr(jv.at(v, &.{ "body", "messages" })).?;
    try t.expectEqual(3, msgs.len);
    const result = jv.arr(jv.get(msgs[2], "content")).?[0];
    try t.expectEqualStrings("Thu \"Nov\"", jv.str(jv.get(result, "content")).?);
    try t.expectEqualStrings("date", jv.str(jv.at(jv.arr(jv.get(msgs[1], "content")).?[0], &.{ "input", "command" })).?);
}

test "budget_spent_is_not_retried" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":402}");
    try e.script(2, textReply("should not be reached"));
    var c = try e.client();
    defer c.deinit();
    try t.expectError(error.BudgetSpent, c.send(e.arena.allocator(), "", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{}));
    try t.expectEqual(1, e.server.modelRequests());
    try t.expectEqualStrings("scripted error", c.lastError());
}

test "rate_limited_waits_once_then_succeeds" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":429,\"retry_after\":1}");
    try e.script(2, textReply("ok now"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.send(a, "", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{});
    try t.expectEqualStrings("ok now", try r.text(a));
    try t.expectEqual(2, e.server.modelRequests());
}

test "rate_limited_twice_gives_up" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":429,\"retry_after\":1}");
    try e.script(2, "{\"status\":429,\"retry_after\":1}");
    try e.script(3, textReply("too late"));
    var c = try e.client();
    defer c.deinit();
    try t.expectError(error.RateLimited, c.send(e.arena.allocator(), "", &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{}));
    try t.expectEqual(2, e.server.modelRequests());
}

test "no_url_or_no_key_refuses_the_call_without_sending_it" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("should not be reached"));
    const a = e.arena.allocator();
    const msgs: []const Message = &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }};
    // config.ini has no url yet
    var no_url = try Client.init(t.allocator, t.io, "", "og-test-key", "claude-test", 100);
    defer no_url.deinit();
    try t.expectError(error.NoUrl, no_url.send(a, "", msgs, &.{}));
    // no key stored: the request would go out with an empty key
    var no_key = try Client.init(t.allocator, t.io, try e.url(), "", "claude-test", 100);
    defer no_key.deinit();
    try t.expectError(error.NoKey, no_key.send(a, "", msgs, &.{}));
    try t.expectEqual(0, e.server.modelRequests());
}

fn sinceMs(start: Io.Timestamp) i64 {
    return start.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds();
}

const hi: []const Message = &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }};

test "a_timed_out_call_is_not_sent_again" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    // the model may be at work on it: sent again, it may be billed again
    try e.script(1, comptime "{\"delay_ms\":2000," ++ textReply("late")[1..]);
    try e.script(2, textReply("sent twice"));
    var c = try e.client();
    defer c.deinit();
    c.call_ms = 500;
    try t.expectError(error.Timeout, c.send(e.arena.allocator(), "", hi, &.{}));
    try t.expectEqual(1, e.server.modelRequests());
}

test "a_call_ends_by_the_turn_deadline" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, comptime "{\"delay_ms\":5000," ++ textReply("too late")[1..]);
    var c = try e.client();
    defer c.deinit();
    const start = Io.Clock.awake.now(t.io);
    // said as the turn's time running out, not as a failed call: the
    // limit was the deadline, however the clocks round
    try t.expectError(error.TimeUp, c.sendParts(e.arena.allocator(), "", "", hi, &.{}, .{ .deadline_s = util.nowSeconds(t.io) + 1 }));
    try t.expect(sinceMs(start) < 3000);
}

fn stopSoon(flag: *std.atomic.Value(bool)) void {
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    flag.store(true, .release);
}

test "stop_and_the_deadline_end_the_wait_after_a_429" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"status\":429,\"retry_after\":10}");
    try e.script(2, "{\"status\":429,\"retry_after\":10}");
    try e.script(3, textReply("after the wait"));
    var c = try e.client();
    defer c.deinit();
    c.max_retry_wait = 10;
    const a = e.arena.allocator();
    var stop: std.atomic.Value(bool) = .init(false);
    const th = try std.Thread.spawn(.{}, stopSoon, .{&stop});
    var start = Io.Clock.awake.now(t.io);
    const stopped = c.sendParts(a, "", "", hi, &.{}, .{ .stop = &stop });
    th.join();
    try t.expectError(error.Stopped, stopped);
    try t.expect(sinceMs(start) < 3000);
    try t.expectEqual(1, e.server.modelRequests());
    // a wait that would end past the deadline is not begun
    start = Io.Clock.awake.now(t.io);
    try t.expectError(error.RateLimited, c.sendParts(a, "", "", hi, &.{}, .{ .deadline_s = util.nowSeconds(t.io) + 2 }));
    try t.expect(sinceMs(start) < 3000);
    try t.expectEqual(2, e.server.modelRequests());
}

test "cache_marks_on_last_tool_stable_system_and_last_message" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1,\"cache_read_input_tokens\":900,\"cache_creation_input_tokens\":40}}");
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    const r = try c.sendParts(a, "stable part", "changing part", &.{
        .{ .role = .user, .blocks = &.{.{ .text = "first" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "answer" }} },
        .{ .role = .user, .blocks = &.{ .{ .text = "a" }, .{ .text = "last" } } },
    }, &.{
        .{ .name = "one", .description = "1", .schema_json = "{\"type\":\"object\"}" },
        .{ .name = "two", .description = "2", .schema_json = "{\"type\":\"object\"}" },
    }, .{});
    try t.expectEqual(900, r.cache_read_tokens);
    try t.expectEqual(40, r.cache_write_tokens);
    const v = jv.parse(a, try e.request(1)).?;
    const sys = jv.arr(jv.at(v, &.{ "body", "system" })).?;
    try t.expectEqual(2, sys.len);
    try t.expectEqualStrings("stable part", jv.str(jv.get(sys[0], "text")).?);
    try t.expectEqualStrings("ephemeral", jv.str(jv.at(sys[0], &.{ "cache_control", "type" })).?);
    try t.expectEqualStrings("changing part", jv.str(jv.get(sys[1], "text")).?);
    try t.expect(jv.get(sys[1], "cache_control") == null);
    const tl = jv.arr(jv.at(v, &.{ "body", "tools" })).?;
    try t.expect(jv.get(tl[0], "cache_control") == null);
    try t.expect(jv.get(tl[1], "cache_control") != null);
    const msgs = jv.arr(jv.at(v, &.{ "body", "messages" })).?;
    try t.expect(jv.get(jv.arr(jv.get(msgs[0], "content")).?[0], "cache_control") == null);
    const last = jv.arr(jv.get(msgs[2], "content")).?;
    try t.expect(jv.get(last[0], "cache_control") == null);
    try t.expect(jv.get(last[1], "cache_control") != null);
}

test "a_turn_call_marks_its_stable_instructions_for_the_cache" {
    var e: TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.script(1, textReply("ok"));
    var c = try e.client();
    defer c.deinit();
    const a = e.arena.allocator();
    // what a turn sends: nothing changing in the system prompt
    _ = try c.sendParts(a, "stable part", "", hi, &.{}, .{});
    const v = jv.parse(a, try e.request(1)).?;
    const sys = jv.arr(jv.at(v, &.{ "body", "system" })).?;
    try t.expectEqual(1, sys.len);
    try t.expectEqualStrings("stable part", jv.str(jv.get(sys[0], "text")).?);
    try t.expectEqualStrings("ephemeral", jv.str(jv.at(sys[0], &.{ "cache_control", "type" })).?);
}

test "plain_send_keeps_system_a_string" {
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const body = try requestBody(arena.allocator(), "m", 10, .{ .stable = "sys", .cache = false }, &.{.{ .role = .user, .blocks = &.{.{ .text = "hi" }} }}, &.{});
    const v = jv.parse(arena.allocator(), body).?;
    try t.expectEqualStrings("sys", jv.str(jv.get(v, "system")).?);
}

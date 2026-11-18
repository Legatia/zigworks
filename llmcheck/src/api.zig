//! The OpenAI-style API as model servers speak it: building a request,
//! sending it, and reading the answer (whole or streamed) into one shape,
//! leniently, since the checks are about what servers get wrong.
const std = @import("std");
const http = @import("http.zig");
const sock = @import("sock.zig");
const jv = @import("jv.zig");
const sse = @import("sse.zig");
const fidelity = @import("fidelity.zig");
const Value = jv.Value;

pub const Step = fidelity.Step;
pub const Alt = fidelity.Alt;

pub const Message = struct { role: []const u8 = "user", content: []const u8 };

pub const Format = union(enum) {
    text,
    json_object,
    /// The schema, as JSON.
    json_schema: []const u8,
};

pub const Ask = struct {
    /// Null: the server's (see `Server.model`).
    model: ?[]const u8 = null,
    messages: []const Message = &.{},
    /// Set: text to continue as it is (/v1/completions), not a conversation.
    prompt: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f64 = null,
    seed: ?u64 = null,
    stop: ?[]const u8 = null,
    stream: bool = false,
    /// Ask for the probabilities of each token and this many alternatives.
    logprobs: ?u32 = null,
    format: Format = .text,
    /// The tools, as a JSON array, and which to call, as JSON.
    tools: ?[]const u8 = null,
    tool_choice: ?[]const u8 = null,
};

pub const ToolCall = struct { name: []const u8, arguments: []const u8 };

pub const Completion = struct {
    status: u16 = 0,
    content_type: []const u8 = "",
    content: []const u8 = "",
    /// Thinking text some models send apart from the answer.
    reasoning: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    tool_calls: []const ToolCall = &.{},
    steps: []const Step = &.{},
    error_message: ?[]const u8 = null,
    /// A whole answer's body as it came (not kept for streams).
    body: []const u8 = "",
    /// The body, or every streamed event, was JSON.
    well_formed: bool = false,
    total_ns: u64 = 0,

    // streams only
    streamed: bool = false,
    events: usize = 0,
    bad_events: usize = 0,
    /// The closing "[DONE]" came.
    done: bool = false,
    /// When each piece of text (or thinking, or tool call) arrived, from the send.
    arrivals_ns: []const u64 = &.{},

    pub fn ok(c: *const Completion) bool {
        return c.status == 200 and c.error_message == null;
    }

    pub fn firstNs(c: *const Completion) ?u64 {
        return if (c.arrivals_ns.len > 0) c.arrivals_ns[0] else null;
    }
};

pub const Models = struct { status: u16, ids: []const []const u8, body: []const u8 };

/// The JSON body for `a`.
pub fn requestBody(arena: std.mem.Allocator, a: Ask) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    write(&s, a) catch return error.OutOfMemory;
    return out.written();
}

fn raw(s: *std.json.Stringify, json: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(json);
    s.endWriteRaw();
}

fn write(s: *std.json.Stringify, a: Ask) !void {
    try s.beginObject();
    if (a.model) |m| {
        try s.objectField("model");
        try s.write(m);
    }
    if (a.prompt) |p| {
        try s.objectField("prompt");
        try s.write(p);
    } else {
        try s.objectField("messages");
        try s.beginArray();
        for (a.messages) |m| {
            try s.beginObject();
            try s.objectField("role");
            try s.write(m.role);
            try s.objectField("content");
            try s.write(m.content);
            try s.endObject();
        }
        try s.endArray();
    }
    if (a.max_tokens) |n| {
        try s.objectField("max_tokens");
        try s.write(n);
    }
    if (a.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (a.seed) |n| {
        try s.objectField("seed");
        try s.write(n);
    }
    if (a.stop) |st| {
        try s.objectField("stop");
        try s.beginArray();
        try s.write(st);
        try s.endArray();
    }
    if (a.stream) {
        try s.objectField("stream");
        try s.write(true);
        try s.objectField("stream_options");
        try raw(s, "{\"include_usage\":true}");
    }
    if (a.logprobs) |k| {
        try s.objectField("logprobs");
        if (a.prompt != null) {
            try s.write(k);
        } else {
            try s.write(true);
            try s.objectField("top_logprobs");
            try s.write(k);
        }
    }
    switch (a.format) {
        .text => {},
        .json_object => {
            try s.objectField("response_format");
            try raw(s, "{\"type\":\"json_object\"}");
        },
        .json_schema => |schema| {
            try s.objectField("response_format");
            try s.beginObject();
            try s.objectField("type");
            try s.write("json_schema");
            try s.objectField("json_schema");
            try s.beginObject();
            try s.objectField("name");
            try s.write("answer");
            try s.objectField("strict");
            try s.write(true);
            try s.objectField("schema");
            try raw(s, schema);
            try s.endObject();
            try s.endObject();
        },
    }
    if (a.tools) |t| {
        try s.objectField("tools");
        try raw(s, t);
    }
    if (a.tool_choice) |t| {
        try s.objectField("tool_choice");
        try raw(s, t);
    }
    try s.endObject();
}

fn byLogprob(_: void, a: Alt, b: Alt) bool {
    return a.logprob > b.logprob;
}

/// Token probabilities in either layout servers use: the chat one
/// ("content": [{token, logprob, top_logprobs: [...]}]) or the older one of
/// /v1/completions (tokens, token_logprobs, top_logprobs: [{token: logprob}]).
fn readSteps(arena: std.mem.Allocator, lp: ?Value, out: *std.ArrayList(Step)) !void {
    if (jv.arr(jv.get(lp, "content"))) |items| {
        for (items) |it| {
            const tok = jv.str(jv.get(it, "token")) orelse continue;
            const l = jv.num(jv.get(it, "logprob")) orelse continue;
            var top: std.ArrayList(Alt) = .empty;
            for (jv.arr(jv.get(it, "top_logprobs")) orelse &[_]Value{}) |al| {
                const t = jv.str(jv.get(al, "token")) orelse continue;
                const p = jv.num(jv.get(al, "logprob")) orelse continue;
                try top.append(arena, .{ .token = t, .logprob = p });
            }
            std.mem.sort(Alt, top.items, {}, byLogprob);
            try out.append(arena, .{ .token = tok, .logprob = l, .top = top.items });
        }
        return;
    }
    const toks = jv.arr(jv.get(lp, "tokens")) orelse return;
    const lps = jv.arr(jv.get(lp, "token_logprobs")) orelse return;
    const tops = jv.arr(jv.get(lp, "top_logprobs")) orelse &[_]Value{};
    for (toks, 0..) |t, i| {
        if (i >= lps.len) break;
        const tok = jv.str(t) orelse continue;
        const l = jv.num(lps[i]) orelse continue;
        var top: std.ArrayList(Alt) = .empty;
        if (i < tops.len and tops[i] == .object) {
            var it = tops[i].object.iterator();
            while (it.next()) |e| {
                const p = jv.num(e.value_ptr.*) orelse continue;
                try top.append(arena, .{ .token = e.key_ptr.*, .logprob = p });
            }
        }
        std.mem.sort(Alt, top.items, {}, byLogprob);
        try out.append(arena, .{ .token = tok, .logprob = l, .top = top.items });
    }
}

/// What a server says went wrong, in the places servers put it.
fn readError(v: ?Value) ?[]const u8 {
    if (jv.get(v, "error")) |e| {
        if (jv.str(e)) |s| return s;
        if (jv.str(jv.get(e, "message"))) |s| return s;
        return "error";
    }
    if (jv.str(jv.get(v, "detail"))) |s| return s;
    if (jv.get(v, "choices") == null) {
        if (jv.str(jv.get(v, "message"))) |s| return s;
    }
    return null;
}

fn readUsage(c: *Completion, v: ?Value) void {
    const u = jv.get(v, "usage") orelse return;
    if (jv.int(jv.get(u, "prompt_tokens"))) |n| c.prompt_tokens = @intCast(@max(n, 0));
    if (jv.int(jv.get(u, "completion_tokens"))) |n| c.completion_tokens = @intCast(@max(n, 0));
}

/// Tool arguments as text: servers send a JSON string, a few an object.
fn argumentsText(arena: std.mem.Allocator, v: ?Value) ![]const u8 {
    const val = v orelse return "";
    if (val == .string) return val.string;
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(val, .{})});
}

/// Reads a whole (not streamed) answer.
pub fn readWhole(arena: std.mem.Allocator, c: *Completion, body: []const u8) !void {
    c.body = body;
    const v = jv.parse(arena, body) orelse return;
    c.well_formed = true;
    c.error_message = readError(v);
    readUsage(c, v);
    const choice = jv.at(v, &.{ "choices", "0" }) orelse return;
    c.finish_reason = jv.str(jv.get(choice, "finish_reason"));
    const msg = jv.get(choice, "message");
    c.content = jv.str(jv.get(msg, "content")) orelse jv.str(jv.get(choice, "text")) orelse "";
    c.reasoning = jv.str(jv.get(msg, "reasoning_content")) orelse jv.str(jv.get(msg, "reasoning")) orelse "";
    var calls: std.ArrayList(ToolCall) = .empty;
    for (jv.arr(jv.get(msg, "tool_calls")) orelse &[_]Value{}) |tc| {
        const f = jv.get(tc, "function");
        try calls.append(arena, .{
            .name = jv.str(jv.get(f, "name")) orelse "",
            .arguments = try argumentsText(arena, jv.get(f, "arguments")),
        });
    }
    c.tool_calls = calls.items;
    var steps: std.ArrayList(Step) = .empty;
    try readSteps(arena, jv.get(choice, "logprobs"), &steps);
    c.steps = steps.items;
}

/// Puts a streamed answer together from its lines.
pub const Stream = struct {
    arena: std.mem.Allocator,
    c: *Completion,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    steps: std.ArrayList(Step) = .empty,
    arrivals: std.ArrayList(u64) = .empty,

    const Call = struct { name: std.ArrayList(u8) = .empty, args: std.ArrayList(u8) = .empty };

    /// One line of the stream, which arrived `at_ns` after the send.
    pub fn line(s: *Stream, text: []const u8, at_ns: u64) !void {
        const payload = sse.data(text) orelse return;
        const c = s.c;
        if (std.mem.eql(u8, std.mem.trim(u8, payload, " "), "[DONE]")) {
            c.done = true;
            return;
        }
        c.events += 1;
        const v = jv.parse(s.arena, payload) orelse {
            c.bad_events += 1;
            return;
        };
        if (readError(v)) |e| c.error_message = e;
        readUsage(c, v);
        const choice = jv.at(v, &.{ "choices", "0" }) orelse return;
        if (jv.str(jv.get(choice, "finish_reason"))) |f| c.finish_reason = f;
        const delta = jv.get(choice, "delta");
        var something = false;
        if (jv.str(jv.get(delta, "content")) orelse jv.str(jv.get(choice, "text"))) |t| {
            try s.content.appendSlice(s.arena, t);
            something = something or t.len > 0;
        }
        if (jv.str(jv.get(delta, "reasoning_content")) orelse jv.str(jv.get(delta, "reasoning"))) |t| {
            try s.reasoning.appendSlice(s.arena, t);
            something = something or t.len > 0;
        }
        for (jv.arr(jv.get(delta, "tool_calls")) orelse &[_]Value{}, 0..) |tc, pos| {
            const index: usize = @intCast(@max(jv.int(jv.get(tc, "index")) orelse @as(i64, @intCast(pos)), 0));
            if (index > 64) continue;
            while (s.calls.items.len <= index) try s.calls.append(s.arena, .{});
            const call = &s.calls.items[index];
            const f = jv.get(tc, "function");
            if (jv.str(jv.get(f, "name"))) |n| try call.name.appendSlice(s.arena, n);
            if (jv.get(f, "arguments")) |a| try call.args.appendSlice(s.arena, try argumentsText(s.arena, a));
            something = true;
        }
        try readSteps(s.arena, jv.get(choice, "logprobs"), &s.steps);
        if (something) try s.arrivals.append(s.arena, at_ns);
    }

    pub fn finish(s: *Stream) !void {
        const c = s.c;
        c.content = s.content.items;
        c.reasoning = s.reasoning.items;
        c.steps = s.steps.items;
        c.arrivals_ns = s.arrivals.items;
        c.well_formed = c.events > 0 and c.bad_events == 0;
        const calls = try s.arena.alloc(ToolCall, s.calls.items.len);
        for (calls, s.calls.items) |*out, in| out.* = .{ .name = in.name.items, .arguments = in.args.items };
        c.tool_calls = calls;
    }
};

const max_body = 64 << 20;

/// One model server and how to talk to it.
pub const Server = struct {
    client: http.Client,
    key: ?[]const u8 = null,
    /// Used for requests that name no model.
    model: ?[]const u8 = null,
    limits: http.Limits = .{},

    pub fn init(gpa: std.mem.Allocator, io: std.Io, target: http.Target) Server {
        return .{ .client = http.Client.init(gpa, io, target) };
    }

    pub fn deinit(s: *Server) void {
        s.client.deinit();
    }

    /// The models the server lists. Everything returned lives in `arena`.
    pub fn models(s: *Server, arena: std.mem.Allocator) http.Error!Models {
        const a = try http.fetch(&s.client, arena, .{ .method = .GET, .path = "/v1/models", .key = s.key, .limits = s.limits });
        var ids: std.ArrayList([]const u8) = .empty;
        const v = jv.parse(arena, a.body);
        // OpenAI's layout, and Ollama's own ("models": [{"name"}])
        for (jv.arr(jv.get(v, "data")) orelse jv.arr(jv.get(v, "models")) orelse &[_]Value{}) |m| {
            if (jv.str(jv.get(m, "id")) orelse jv.str(jv.get(m, "name"))) |id| try ids.append(arena, id);
        }
        return .{ .status = a.status, .ids = ids.items, .body = a.body };
    }

    /// Sends `ask` and reads the answer. Everything returned lives in `arena`.
    /// An HTTP error status is an answer (see `Completion.status`), not an error.
    pub fn ask(s: *Server, arena: std.mem.Allocator, ask_in: Ask) http.Error!Completion {
        var a = ask_in;
        if (a.model == null) a.model = s.model;
        const body = try requestBody(arena, a);
        var c: Completion = .{};
        const timer = sock.Timer.start(s.client.io);
        var resp = try s.client.send(.{
            .path = if (a.prompt != null) "/v1/completions" else "/v1/chat/completions",
            .body = body,
            .key = s.key,
            .limits = s.limits,
        });
        defer resp.deinit();
        c.status = resp.status;
        c.content_type = try arena.dupe(u8, resp.contentType());
        if (a.stream and resp.status == 200 and std.ascii.startsWithIgnoreCase(c.content_type, "text/event-stream")) {
            c.streamed = true;
            var stream: Stream = .{ .arena = arena, .c = &c };
            var lines: sse.Splitter = .{};
            var at: u64 = 0;
            while (try resp.next()) |part| {
                at = timer.read();
                try lines.feed(arena, part);
                while (lines.next()) |l| try stream.line(l, at);
            }
            if (lines.rest().len > 0) try stream.line(lines.rest(), at);
            try stream.finish();
        } else {
            try readWhole(arena, &c, try resp.readAll(arena, max_body));
        }
        c.total_ns = timer.read();
        return c;
    }
};

// ---- tests ----

const testing = std.testing;
const fake = @import("fake.zig");

const Rig = struct {
    fake_server: *fake.Server,
    server: Server,
    arena_state: std.heap.ArenaAllocator,

    fn init(r: *Rig, faults: fake.Faults) !void {
        r.fake_server = try fake.Server.start(testing.io, faults, 0);
        r.server = Server.init(testing.allocator, testing.io, .{ .https = false, .host = "127.0.0.1", .port = r.fake_server.port, .prefix = "" });
        r.server.key = faults.key;
        r.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }
    fn deinit(r: *Rig) void {
        r.server.deinit();
        r.arena_state.deinit();
        r.fake_server.stop();
    }
    fn arena(r: *Rig) std.mem.Allocator {
        return r.arena_state.allocator();
    }
};

const hello = [_]Message{.{ .content = "Say something about rivers." }};

test "a_request_is_written_as_the_api_expects_it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const chat = try requestBody(arena, .{
        .model = "m",
        .messages = &.{ .{ .role = "system", .content = "Be \"brief\"." }, .{ .content = "Hi" } },
        .max_tokens = 5,
        .temperature = 0,
        .seed = 7,
        .stop = "\n",
        .stream = true,
        .logprobs = 3,
        .format = .{ .json_schema = "{\"type\":\"object\"}" },
        .tools = "[]",
        .tool_choice = "\"required\"",
    });
    try testing.expectEqualStrings(
        "{\"model\":\"m\",\"messages\":[{\"role\":\"system\",\"content\":\"Be \\\"brief\\\".\"},{\"role\":\"user\",\"content\":\"Hi\"}]," ++
            "\"max_tokens\":5,\"temperature\":0,\"seed\":7,\"stop\":[\"\\n\"],\"stream\":true,\"stream_options\":{\"include_usage\":true}," ++
            "\"logprobs\":true,\"top_logprobs\":3," ++
            "\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"answer\",\"strict\":true,\"schema\":{\"type\":\"object\"}}}," ++
            "\"tools\":[],\"tool_choice\":\"required\"}",
        chat,
    );
    const text = try requestBody(arena, .{ .prompt = "Once", .logprobs = 5, .format = .json_object });
    try testing.expectEqualStrings("{\"prompt\":\"Once\",\"logprobs\":5,\"response_format\":{\"type\":\"json_object\"}}", text);
}

test "a_whole_answer_is_read_with_its_counts_and_probabilities" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    const m = try r.server.models(r.arena());
    try testing.expectEqual(@as(usize, 1), m.ids.len);
    try testing.expectEqualStrings("fake-1", m.ids[0]);
    const c = try r.server.ask(r.arena(), .{ .messages = &hello, .temperature = 0, .logprobs = 3 });
    try testing.expect(c.ok());
    try testing.expect(c.content.len > 20);
    try testing.expectEqualStrings("stop", c.finish_reason.?);
    try testing.expectEqual(@as(?u64, 6), c.prompt_tokens); // <|user|> + 4 words + <|assistant|>
    try testing.expectEqual(@as(u64, c.steps.len), c.completion_tokens.?);
    try testing.expectEqual(@as(usize, 3), c.steps[0].top.len);
    // at temperature 0 the produced token is the likeliest one
    try testing.expectEqualStrings(c.steps[0].token, c.steps[0].top[0].token);
    try testing.expect(c.steps[0].top[0].logprob >= c.steps[0].top[1].logprob);
    try testing.expect(c.steps[0].logprob < 0);
}

test "a_streamed_answer_reads_the_same_as_a_whole_one" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    const whole = try r.server.ask(r.arena(), .{ .messages = &hello, .temperature = 0, .logprobs = 2 });
    const s = try r.server.ask(r.arena(), .{ .messages = &hello, .temperature = 0, .logprobs = 2, .stream = true });
    try testing.expect(s.streamed and s.done and s.well_formed);
    try testing.expectEqualStrings(whole.content, s.content);
    try testing.expectEqualStrings("stop", s.finish_reason.?);
    try testing.expectEqual(whole.completion_tokens, s.completion_tokens);
    try testing.expectEqual(whole.prompt_tokens, s.prompt_tokens);
    try testing.expectEqual(whole.steps.len, s.steps.len);
    try testing.expectEqual(whole.steps[3].logprob, s.steps[3].logprob);
    try testing.expectEqual(@as(usize, @intCast(s.completion_tokens.?)), s.arrivals_ns.len);
    try testing.expect(s.firstNs().? <= s.total_ns);
}

test "text_continued_as_it_is_comes_with_probabilities_in_the_older_layout" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    for ([_]bool{ false, true }) |stream| {
        const c = try r.server.ask(r.arena(), .{ .prompt = "The river moves", .temperature = 0, .logprobs = 4, .max_tokens = 6, .stream = stream });
        try testing.expect(c.ok());
        try testing.expectEqualStrings("length", c.finish_reason.?);
        try testing.expectEqual(@as(usize, 6), c.steps.len);
        try testing.expectEqual(@as(usize, 4), c.steps[5].top.len);
        try testing.expectEqualStrings(c.steps[5].token, c.steps[5].top[0].token);
        try testing.expectEqual(@as(?u64, 3), c.prompt_tokens);
    }
}

const weather_tools =
    \\[{"type":"function","function":{"name":"get_weather","description":"Weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"},"unit":{"type":"string","enum":["celsius","fahrenheit"]}},"required":["city","unit"]}}}]
;

test "a_tool_call_is_read_whole_and_streamed" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    for ([_]bool{ false, true }) |stream| {
        const c = try r.server.ask(r.arena(), .{ .messages = &hello, .tools = weather_tools, .tool_choice = "\"required\"", .stream = stream });
        try testing.expect(c.ok());
        try testing.expectEqual(@as(usize, 1), c.tool_calls.len);
        try testing.expectEqualStrings("get_weather", c.tool_calls[0].name);
        try testing.expectEqualStrings("{\"city\":\"river\",\"unit\":\"celsius\"}", c.tool_calls[0].arguments);
        try testing.expectEqualStrings("tool_calls", c.finish_reason.?);
        try testing.expectEqualStrings("", c.content);
    }
}

test "a_refusal_comes_back_as_an_answer_with_its_reason" {
    var r: Rig = undefined;
    try r.init(.{ .key = "sesame", .context = 8 });
    defer r.deinit();
    const long = try r.server.ask(r.arena(), .{ .messages = &.{.{ .content = "one two three four five six seven eight nine ten" }} });
    try testing.expectEqual(@as(u16, 400), long.status);
    try testing.expect(std.mem.indexOf(u8, long.error_message.?, "maximum context length is 8 tokens") != null);
    r.server.key = null;
    const c = try r.server.ask(r.arena(), .{ .messages = &hello });
    try testing.expectEqual(@as(u16, 401), c.status);
    try testing.expect(!c.ok());
    try testing.expectEqualStrings("Incorrect API key provided.", c.error_message.?);
}

test "what_a_stream_leaves_out_is_noticed" {
    var r: Rig = undefined;
    try r.init(.{ .no_done = true, .no_usage = true, .no_logprobs = true });
    defer r.deinit();
    const c = try r.server.ask(r.arena(), .{ .messages = &hello, .temperature = 0, .stream = true, .logprobs = 2 });
    try testing.expect(c.ok() and c.streamed);
    try testing.expect(!c.done);
    try testing.expect(c.completion_tokens == null);
    try testing.expectEqual(@as(usize, 0), c.steps.len);
    try testing.expect(c.content.len > 0);
}

test "a_stream_is_put_together_from_its_lines_and_broken_ones_are_counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var c: Completion = .{};
    var s: Stream = .{ .arena = arena_state.allocator(), .c = &c };
    const lines = [_][]const u8{
        ": ping",
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}",
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hm\"}}]}",
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}",
        "",
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":null}]}",
        "data: {broken",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"a\\\"\"}}]}}]}",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":1}\"}}]}}]}",
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}",
        "data: [DONE]",
    };
    for (lines, 0..) |l, i| try s.line(l, i * 10);
    try s.finish();
    try testing.expectEqualStrings("Hello", c.content);
    try testing.expectEqualStrings("hm", c.reasoning);
    try testing.expectEqualStrings("stop", c.finish_reason.?);
    try testing.expectEqual(@as(usize, 9), c.events);
    try testing.expectEqual(@as(usize, 1), c.bad_events);
    try testing.expect(c.done and !c.well_formed);
    try testing.expectEqual(@as(?u64, 2), c.completion_tokens);
    try testing.expectEqualStrings("f", c.tool_calls[0].name);
    try testing.expectEqualStrings("{\"a\":1}", c.tool_calls[0].arguments);
    // the first piece of anything is the thinking, at line 2
    try testing.expectEqual(@as(?u64, 20), c.firstNs());
    try testing.expectEqual(@as(usize, 5), c.arrivals_ns.len);
}

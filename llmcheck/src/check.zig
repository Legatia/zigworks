//! The interface checks: does the server do what its API promises? Each
//! check sends a few small requests and looks at what comes back, for the
//! ways servers are known to go wrong without saying so: output formats that
//! are dropped, tool calls written into the text, long prompts cut short,
//! limits and stop strings that are ignored.
const std = @import("std");
const api = @import("api.zig");
const http = @import("http.zig");
const jv = @import("jv.zig");

pub const Status = enum { pass, fail, warn, skip };

pub const Result = struct { id: []const u8, status: Status, detail: []const u8 };

pub const Options = struct {
    /// Comma-separated check names: run only these / leave these out.
    only: ?[]const u8 = null,
    skip: ?[]const u8 = null,
    /// The longest prompt the context check tries, in words.
    max_prompt_words: u32 = 8192,
};

pub const Report = struct {
    results: []const Result,
    /// The model the requests named.
    model: ?[]const u8,

    pub fn count(r: Report, status: Status) usize {
        var n: usize = 0;
        for (r.results) |x| n += @intFromBool(x.status == status);
        return n;
    }

    pub fn find(r: Report, id: []const u8) ?Result {
        for (r.results) |x| if (std.mem.eql(u8, x.id, id)) return x;
        return null;
    }
};

const Outcome = struct { status: Status, detail: []const u8 };

const Ctx = struct {
    arena: std.mem.Allocator,
    s: *api.Server,
    ref: ?*api.Server,
    opts: Options,
    models: api.Models,
    /// The model named on the command line, if any.
    given_model: ?[]const u8,

    fn out(ctx: *Ctx, status: Status, comptime fmt: []const u8, args: anytype) !Outcome {
        return .{ .status = status, .detail = try std.fmt.allocPrint(ctx.arena, fmt, args) };
    }

    /// Why a request was not answered properly: "HTTP 400: <the server's words>".
    fn why(ctx: *Ctx, c: api.Completion) ![]const u8 {
        if (c.error_message) |m| return std.fmt.allocPrint(ctx.arena, "HTTP {d}: {s}", .{ c.status, try clip(ctx.arena, m, 140) });
        if (c.status == 200 and !c.well_formed) return "the answer is not JSON";
        return std.fmt.allocPrint(ctx.arena, "HTTP {d}", .{c.status});
    }
};

const Check = struct {
    id: []const u8,
    func: *const fn (*Ctx) http.Error!Outcome,
    /// Only with a reference server.
    needs_ref: bool = false,
};

const checks = [_]Check{
    .{ .id = "models", .func = checkModels },
    .{ .id = "chat", .func = checkChat },
    .{ .id = "auth", .func = checkAuth },
    .{ .id = "stream", .func = checkStream },
    .{ .id = "deterministic", .func = checkDeterministic },
    .{ .id = "max_tokens", .func = checkMaxTokens },
    .{ .id = "stop", .func = checkStop },
    .{ .id = "json_schema", .func = checkJsonSchema },
    .{ .id = "json_object", .func = checkJsonObject },
    .{ .id = "tools", .func = checkTools },
    .{ .id = "tools_stream", .func = checkToolsStream },
    .{ .id = "context", .func = checkContext },
    .{ .id = "sampling", .func = checkSampling },
    .{ .id = "logprobs", .func = checkLogprobs },
    .{ .id = "usage_match", .func = checkUsageMatch, .needs_ref = true },
};

pub const names = blk: {
    var out: [checks.len][]const u8 = undefined;
    for (checks, 0..) |c, i| out[i] = c.id;
    break :blk out;
};

pub fn known(id: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, id)) return true;
    return false;
}

fn listed(list: []const u8, id: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |x| if (std.mem.eql(u8, std.mem.trim(u8, x, " "), id)) return true;
    return false;
}

fn selected(opts: Options, id: []const u8) bool {
    if (opts.only) |o| if (!listed(o, id)) return false;
    if (opts.skip) |s| if (listed(s, id)) return false;
    return true;
}

/// Text from a server, made fit for one line of output.
pub fn clip(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    var end = @min(text.len, max);
    // not in the middle of a character
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    const out = try arena.alloc(u8, end);
    for (out, text[0..end]) |*o, ch| o.* = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
    if (end == text.len) return out;
    return std.fmt.allocPrint(arena, "{s}...", .{out});
}

pub fn describe(arena: std.mem.Allocator, e: http.Error, limits: http.Limits) ![]const u8 {
    return switch (e) {
        error.Timeout => blk: {
            const ms = limits.total_ms orelse limits.idle_ms;
            if (ms < 1000) break :blk std.fmt.allocPrint(arena, "no answer within {d} ms", .{ms});
            break :blk std.fmt.allocPrint(arena, "no answer within {d} s", .{ms / 1000});
        },
        error.ConnectFailed => "could not connect",
        error.ConnectionClosed => "the server closed the connection without answering",
        error.TlsFailed => "the secure connection (TLS) could not be set up",
        error.CertificateRejected => "the server's https certificate is not trusted on this machine (--insecure accepts any certificate)",
        error.BadResponse => "the answer is not valid HTTP",
        error.BadUrl => "the address is not valid",
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Runs the checks against `s` (and, where two servers are compared, `ref`).
/// An error means the server could not be reached at all.
pub fn run(arena: std.mem.Allocator, s: *api.Server, ref: ?*api.Server, opts: Options) http.Error!Report {
    var ctx: Ctx = .{ .arena = arena, .s = s, .ref = ref, .opts = opts, .models = undefined, .given_model = s.model };
    ctx.models = try s.models(arena);
    if (s.model == null and ctx.models.ids.len > 0) s.model = ctx.models.ids[0];
    if (ref) |r| {
        if (r.model == null) {
            const m = try r.models(arena);
            if (m.ids.len > 0) r.model = m.ids[0];
        }
    }
    var results: std.ArrayList(Result) = .empty;
    var chat_failed = false;
    for (checks) |c| {
        if (!selected(opts, c.id)) continue;
        if (c.needs_ref and ref == null) continue;
        const is_chat = std.mem.eql(u8, c.id, "chat");
        const o: Outcome = if (chat_failed)
            .{ .status = .skip, .detail = "chat does not work" }
        else
            c.func(&ctx) catch |e| .{ .status = .fail, .detail = try describe(arena, e, s.limits) };
        if (is_chat and o.status == .fail) chat_failed = true;
        try results.append(arena, .{ .id = c.id, .status = o.status, .detail = o.detail });
    }
    return .{ .results = results.items, .model = s.model };
}

const say = [_]api.Message{.{ .content = "Describe a river in two short sentences." }};

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn checkModels(ctx: *Ctx) http.Error!Outcome {
    const m = ctx.models;
    if (m.status == 404) return ctx.out(.warn, "the server has no /v1/models (HTTP 404)", .{});
    if (m.status != 200) {
        const msg = jv.str(jv.at(jv.parse(ctx.arena, m.body), &.{ "error", "message" })) orelse "";
        return ctx.out(.fail, "HTTP {d}{s}{s}", .{ m.status, if (msg.len > 0) ": " else "", try clip(ctx.arena, msg, 140) });
    }
    if (m.ids.len == 0) return ctx.out(.warn, "the list of models is empty", .{});
    if (ctx.given_model) |g| {
        for (m.ids) |id| {
            if (std.mem.eql(u8, id, g)) break;
        } else return ctx.out(.warn, "'{s}' is not among the {d} listed", .{ g, m.ids.len });
    }
    return ctx.out(.pass, "{d} listed; using {s}", .{ m.ids.len, ctx.s.model orelse m.ids[0] });
}

fn checkChat(ctx: *Ctx) http.Error!Outcome {
    const c = try ctx.s.ask(ctx.arena, .{ .messages = &say, .max_tokens = 64, .temperature = 0 });
    if (!c.ok() or !c.well_formed) return ctx.out(.fail, "{s}", .{try ctx.why(c)});
    if (c.content.len == 0 and c.reasoning.len == 0) return ctx.out(.fail, "the answer has no text", .{});
    if (c.finish_reason == null) return ctx.out(.warn, "the answer has no finish_reason", .{});
    if (c.prompt_tokens == null or c.completion_tokens == null) return ctx.out(.warn, "the answer reports no token counts (usage)", .{});
    return ctx.out(.pass, "{d} tokens in {d:.2} s", .{ c.completion_tokens.?, seconds(c.total_ns) });
}

fn checkAuth(ctx: *Ctx) http.Error!Outcome {
    const key = ctx.s.key;
    ctx.s.key = null;
    defer ctx.s.key = key;
    const c = try ctx.s.ask(ctx.arena, .{ .messages = &say, .max_tokens = 1 });
    const refused = c.status == 401 or c.status == 403;
    if (key == null) {
        if (c.status == 200) return ctx.out(.warn, "the server answers anyone: no key is needed", .{});
        return ctx.out(.fail, "{s}", .{try ctx.why(c)});
    }
    if (refused) return ctx.out(.pass, "a request without the key is refused (HTTP {d})", .{c.status});
    if (c.status == 200) return ctx.out(.fail, "a request without the key is answered", .{});
    return ctx.out(.warn, "a request without the key gets HTTP {d}, not 401", .{c.status});
}

fn checkStream(ctx: *Ctx) http.Error!Outcome {
    const c = try ctx.s.ask(ctx.arena, .{ .messages = &say, .max_tokens = 64, .temperature = 0, .stream = true });
    if (!c.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(c)});
    if (!c.streamed) return ctx.out(.fail, "asked for a stream, got '{s}'", .{try clip(ctx.arena, c.content_type, 60)});
    if (c.bad_events > 0) return ctx.out(.fail, "{d} of {d} events are not JSON", .{ c.bad_events, c.events });
    if (c.content.len == 0 and c.reasoning.len == 0) return ctx.out(.fail, "the stream carries no text", .{});
    if (c.finish_reason == null) return ctx.out(.fail, "the stream ends without a finish_reason", .{});
    if (!c.done) return ctx.out(.warn, "the stream ends without \"data: [DONE]\"", .{});
    if (c.completion_tokens == null) return ctx.out(.warn, "no token counts in the stream (stream_options.include_usage is ignored)", .{});
    return ctx.out(.pass, "{d} pieces, the first after {d} ms", .{ c.arrivals_ns.len, (c.firstNs() orelse 0) / std.time.ns_per_ms });
}

fn firstDifference(a: []const u8, b: []const u8) usize {
    return std.mem.indexOfDiff(u8, a, b) orelse a.len;
}

fn checkDeterministic(ctx: *Ctx) http.Error!Outcome {
    const ask: api.Ask = .{ .messages = &say, .max_tokens = 48, .temperature = 0, .seed = 1 };
    const a = try ctx.s.ask(ctx.arena, ask);
    if (!a.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(a)});
    const b = try ctx.s.ask(ctx.arena, ask);
    if (!b.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(b)});
    if (!std.mem.eql(u8, a.content, b.content)) {
        return ctx.out(.warn, "the same request twice at temperature 0 gave different text (from character {d})", .{firstDifference(a.content, b.content)});
    }
    return ctx.out(.pass, "the same request twice at temperature 0 gives the same text", .{});
}

fn checkMaxTokens(ctx: *Ctx) http.Error!Outcome {
    const c = try ctx.s.ask(ctx.arena, .{ .messages = &.{.{ .content = "Write a long story about a river, at least ten sentences." }}, .max_tokens = 5, .temperature = 0 });
    if (!c.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(c)});
    if (c.completion_tokens) |n| {
        if (n > 5) return ctx.out(.fail, "asked for at most 5 tokens, got {d}", .{n});
    } else {
        // no count to go by: five tokens are never more than a few dozen characters
        if (c.content.len + c.reasoning.len > 200) return ctx.out(.fail, "asked for at most 5 tokens, got {d} characters", .{c.content.len + c.reasoning.len});
    }
    const reason = c.finish_reason orelse "";
    if (!std.mem.eql(u8, reason, "length")) return ctx.out(.warn, "cut at 5 tokens, but finish_reason is '{s}', not 'length'", .{try clip(ctx.arena, reason, 30)});
    return ctx.out(.pass, "stops at 5 tokens with finish_reason 'length'", .{});
}

/// A word from the middle of `text` that does not occur before that place.
fn pickStop(text: []const u8) ?[]const u8 {
    var words: [128][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    if (n < 4) return null;
    for ([_][2]usize{ .{ n / 2, n }, .{ 1, n / 2 } }) |range| {
        for (words[range[0]..range[1]]) |raw| {
            var w = raw;
            while (w.len > 0 and !std.ascii.isAlphanumeric(w[0])) w = w[1..];
            while (w.len > 0 and !std.ascii.isAlphanumeric(w[w.len - 1])) w = w[0 .. w.len - 1];
            if (w.len < 3) continue;
            const at = @intFromPtr(w.ptr) - @intFromPtr(text.ptr);
            if (std.mem.indexOf(u8, text, w).? == at) return w;
        }
    }
    return null;
}

fn checkStop(ctx: *Ctx) http.Error!Outcome {
    var ask: api.Ask = .{ .messages = &say, .max_tokens = 64, .temperature = 0, .seed = 1 };
    const base = try ctx.s.ask(ctx.arena, ask);
    if (!base.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(base)});
    const word = pickStop(base.content) orelse return ctx.out(.skip, "the answer is too short to pick a stop string from", .{});
    ask.stop = word;
    const c = try ctx.s.ask(ctx.arena, ask);
    if (!c.ok()) return ctx.out(.fail, "with a stop string: {s}", .{try ctx.why(c)});
    if (std.mem.indexOf(u8, c.content, word) != null) return ctx.out(.fail, "the answer runs past the stop string '{s}'", .{word});
    if (c.content.len >= base.content.len) return ctx.out(.warn, "with the stop string '{s}' the answer is another one, and no shorter", .{word});
    return ctx.out(.pass, "the answer ends before the stop string '{s}'", .{word});
}

const city_schema =
    \\{"type":"object","properties":{"city":{"type":"string"},"population":{"type":"integer"},"capital":{"type":"boolean"}},"required":["city","population","capital"],"additionalProperties":false}
;

fn checkJsonSchema(ctx: *Ctx) http.Error!Outcome {
    const c = try ctx.s.ask(ctx.arena, .{
        .messages = &.{.{ .content = "Tell me about Paris: its name, its population, and whether it is a capital." }},
        .max_tokens = 200,
        .temperature = 0,
        .format = .{ .json_schema = city_schema },
    });
    if (!c.ok()) return ctx.out(.warn, "output by schema is refused: {s}", .{try ctx.why(c)});
    const v = jv.parse(ctx.arena, std.mem.trim(u8, c.content, " \t\r\n")) orelse {
        if (std.mem.eql(u8, c.finish_reason orelse "", "length")) return ctx.out(.warn, "the JSON is cut off at 200 tokens", .{});
        return ctx.out(.fail, "asked for JSON by schema, got '{s}' (response_format is ignored)", .{try clip(ctx.arena, c.content, 50)});
    };
    if (v != .object) return ctx.out(.fail, "the schema asks for an object, the answer is another kind of JSON", .{});
    if (jv.str(jv.get(v, "city")) == null) return ctx.out(.fail, "the JSON does not follow the schema: 'city' is not a string", .{});
    if (jv.int(jv.get(v, "population")) == null) return ctx.out(.fail, "the JSON does not follow the schema: 'population' is not an integer", .{});
    if (jv.boolean(jv.get(v, "capital")) == null) return ctx.out(.fail, "the JSON does not follow the schema: 'capital' is not true or false", .{});
    if (v.object.count() != 3) return ctx.out(.fail, "the JSON does not follow the schema: it has fields the schema forbids", .{});
    return ctx.out(.pass, "the answer is JSON that follows the schema", .{});
}

fn checkJsonObject(ctx: *Ctx) http.Error!Outcome {
    const c = try ctx.s.ask(ctx.arena, .{
        .messages = &.{.{ .content = "Answer in JSON with the key \"answer\": what colour is a clear sky?" }},
        .max_tokens = 200,
        .temperature = 0,
        .format = .json_object,
    });
    if (!c.ok()) return ctx.out(.warn, "JSON output is refused: {s}", .{try ctx.why(c)});
    if (jv.parse(ctx.arena, std.mem.trim(u8, c.content, " \t\r\n")) == null) {
        if (std.mem.eql(u8, c.finish_reason orelse "", "length")) return ctx.out(.warn, "the JSON is cut off at 200 tokens", .{});
        return ctx.out(.warn, "asked for JSON, got '{s}'", .{try clip(ctx.arena, c.content, 50)});
    }
    return ctx.out(.pass, "the answer is JSON", .{});
}

const weather_tools =
    \\[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city.","parameters":{"type":"object","properties":{"city":{"type":"string","description":"The city's name"},"unit":{"type":"string","enum":["celsius","fahrenheit"]}},"required":["city","unit"]}}}]
;
const weather_ask = [_]api.Message{.{ .content = "What is the weather in Paris, in celsius? Use the tool." }};

fn toolOutcome(ctx: *Ctx, c: api.Completion) http.Error!Outcome {
    if (!c.ok()) return ctx.out(.warn, "tools are refused: {s}", .{try ctx.why(c)});
    if (c.tool_calls.len == 0) {
        if (std.mem.indexOf(u8, c.content, "get_weather") != null or std.mem.indexOf(u8, c.content, "tool_call") != null) {
            return ctx.out(.fail, "the tool call is written into the text ('{s}'), not returned as tool_calls", .{try clip(ctx.arena, c.content, 50)});
        }
        return ctx.out(.fail, "no tool call, although tool_choice is 'required'", .{});
    }
    const call = c.tool_calls[0];
    if (!std.mem.eql(u8, call.name, "get_weather")) return ctx.out(.fail, "the call names '{s}', not the tool that was offered", .{try clip(ctx.arena, call.name, 40)});
    const args = jv.parse(ctx.arena, call.arguments) orelse return ctx.out(.fail, "the call's arguments are not JSON: '{s}'", .{try clip(ctx.arena, call.arguments, 50)});
    if (jv.str(jv.get(args, "city")) == null) return ctx.out(.fail, "the call's arguments lack the required 'city'", .{});
    const reason = c.finish_reason orelse "";
    if (!std.mem.eql(u8, reason, "tool_calls")) return ctx.out(.warn, "a tool call came, but finish_reason is '{s}', not 'tool_calls'", .{try clip(ctx.arena, reason, 30)});
    return ctx.out(.pass, "get_weather is called with arguments that parse", .{});
}

fn checkTools(ctx: *Ctx) http.Error!Outcome {
    return toolOutcome(ctx, try ctx.s.ask(ctx.arena, .{ .messages = &weather_ask, .max_tokens = 200, .temperature = 0, .tools = weather_tools, .tool_choice = "\"required\"" }));
}

fn checkToolsStream(ctx: *Ctx) http.Error!Outcome {
    return toolOutcome(ctx, try ctx.s.ask(ctx.arena, .{ .messages = &weather_ask, .max_tokens = 200, .temperature = 0, .tools = weather_tools, .tool_choice = "\"required\"", .stream = true }));
}

const filler = [_][]const u8{ "the", "quick", "brown", "fox", "jumps", "over", "a", "lazy", "dog", "near", "one", "quiet", "river", "bank", "this", "morning" };

fn wordsPrompt(arena: std.mem.Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, filler[i % filler.len]);
    }
    return out.items;
}

fn askWords(ctx: *Ctx, n: usize) http.Error!api.Completion {
    return ctx.s.ask(ctx.arena, .{ .messages = &.{.{ .content = try wordsPrompt(ctx.arena, n) }}, .max_tokens = 1, .temperature = 0 });
}

fn checkContext(ctx: *Ctx) http.Error!Outcome {
    // two short prompts tell how many tokens a word takes here
    const a = try askWords(ctx, 64);
    if (!a.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(a)});
    const b = try askWords(ctx, 128);
    if (!b.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(b)});
    const pa: f64 = @floatFromInt(a.prompt_tokens orelse return ctx.out(.skip, "the server reports no token counts to go by", .{}));
    const pb: f64 = @floatFromInt(b.prompt_tokens orelse return ctx.out(.skip, "the server reports no token counts to go by", .{}));
    const per_word = (pb - pa) / 64;
    if (per_word <= 0) return ctx.out(.skip, "the reported token counts do not grow with the prompt", .{});
    const fixed = pa - per_word * 64;

    var n: usize = 1024;
    var longest: u64 = 0;
    while (n <= ctx.opts.max_prompt_words) : (n *= 2) {
        const expected: u64 = @intFromFloat(@round(fixed + per_word * @as(f64, @floatFromInt(n))));
        const c = try askWords(ctx, n);
        if (c.status >= 500) return ctx.out(.fail, "a prompt of about {d} tokens breaks the server: {s}", .{ expected, try ctx.why(c) });
        if (c.status != 200) return ctx.out(.pass, "a prompt of about {d} tokens is refused: {s}", .{ expected, try ctx.why(c) });
        const got = c.prompt_tokens orelse return ctx.out(.skip, "the server reports no token counts to go by", .{});
        if (@as(f64, @floatFromInt(got)) < 0.7 * @as(f64, @floatFromInt(expected))) {
            return ctx.out(.fail, "a prompt of about {d} tokens is cut to {d} without a word (the context is smaller than the prompt)", .{ expected, got });
        }
        longest = got;
    }
    if (longest == 0) return ctx.out(.skip, "no long prompt was tried (--max-prompt-words is below 1024)", .{});
    return ctx.out(.pass, "prompts up to {d} tokens are taken whole (longer ones not tried)", .{longest});
}

fn checkSampling(ctx: *Ctx) http.Error!Outcome {
    var ask: api.Ask = .{ .messages = &.{.{ .content = "Write one sentence about the sea." }}, .max_tokens = 24, .temperature = 1, .seed = 1 };
    const a = try ctx.s.ask(ctx.arena, ask);
    if (!a.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(a)});
    const b = try ctx.s.ask(ctx.arena, ask);
    if (!b.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(b)});
    ask.seed = 2;
    const c = try ctx.s.ask(ctx.arena, ask);
    if (!c.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(c)});
    if (!std.mem.eql(u8, a.content, b.content)) return ctx.out(.warn, "the same seed twice gave different text (the seed is ignored)", .{});
    if (std.mem.eql(u8, a.content, c.content)) return ctx.out(.warn, "two seeds gave the same text at temperature 1 (temperature or seed is ignored)", .{});
    return ctx.out(.pass, "the same seed repeats its text, another seed gives another", .{});
}

fn checkLogprobs(ctx: *Ctx) http.Error!Outcome {
    const c = try ctx.s.ask(ctx.arena, .{ .messages = &say, .max_tokens = 8, .temperature = 0, .logprobs = 5 });
    if (!c.ok()) return ctx.out(.warn, "token probabilities are refused: {s} (fidelity cannot run)", .{try ctx.why(c)});
    if (c.steps.len == 0) return ctx.out(.warn, "no token probabilities in the answer (fidelity cannot run)", .{});
    var least: usize = c.steps[0].top.len;
    for (c.steps) |s| least = @min(least, s.top.len);
    if (least == 0) return ctx.out(.warn, "token probabilities come without alternatives (fidelity will be coarse)", .{});
    return ctx.out(.pass, "{d} tokens, each with {d} alternatives", .{ c.steps.len, least });
}

const conversations = [_][]const api.Message{
    &.{.{ .content = "Hello" }},
    &.{ .{ .role = "system", .content = "You are terse." }, .{ .content = "Name three colours." } },
    &.{ .{ .content = "What is 2+2?" }, .{ .role = "assistant", .content = "4" }, .{ .content = "And 3+3?" } },
};

fn checkUsageMatch(ctx: *Ctx) http.Error!Outcome {
    const ref = ctx.ref.?;
    for (conversations, 1..) |messages, i| {
        const ask: api.Ask = .{ .messages = messages, .max_tokens = 1, .temperature = 0 };
        const here = try ctx.s.ask(ctx.arena, ask);
        if (!here.ok()) return ctx.out(.fail, "{s}", .{try ctx.why(here)});
        const there = ref.ask(ctx.arena, ask) catch |e| return ctx.out(.skip, "the reference: {s}", .{try describe(ctx.arena, e, ref.limits)});
        if (!there.ok()) return ctx.out(.skip, "the reference: {s}", .{try ctx.why(there)});
        const n_here = here.prompt_tokens orelse return ctx.out(.skip, "the server reports no token counts to compare", .{});
        const n_there = there.prompt_tokens orelse return ctx.out(.skip, "the reference reports no token counts to compare", .{});
        if (n_here != n_there) {
            return ctx.out(.fail, "conversation {d} is {d} prompt tokens here and {d} on the reference (another chat template or tokenizer)", .{ i, n_here, n_there });
        }
    }
    return ctx.out(.pass, "{d} conversations count the same prompt tokens as on the reference", .{conversations.len});
}

// ---- tests ----

const testing = std.testing;
const fake = @import("fake.zig");

const Rig = struct {
    arena_state: std.heap.ArenaAllocator,
    fake_server: *fake.Server,
    fake_ref: ?*fake.Server = null,
    server: api.Server,
    ref: api.Server = undefined,

    fn init(r: *Rig, faults: fake.Faults, ref_faults: ?fake.Faults) !void {
        r.* = .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .fake_server = try fake.Server.start(testing.io, faults, 0),
            .server = undefined,
        };
        r.server = api.Server.init(testing.allocator, testing.io, .{ .https = false, .host = "127.0.0.1", .port = r.fake_server.port, .prefix = "" });
        r.server.key = faults.key;
        if (ref_faults) |rf| {
            r.fake_ref = try fake.Server.start(testing.io, rf, 0);
            r.ref = api.Server.init(testing.allocator, testing.io, .{ .https = false, .host = "127.0.0.1", .port = r.fake_ref.?.port, .prefix = "" });
        }
    }

    fn deinit(r: *Rig) void {
        r.server.deinit();
        r.fake_server.stop();
        if (r.fake_ref) |f| {
            r.ref.deinit();
            f.stop();
        }
        r.arena_state.deinit();
    }

    fn run(r: *Rig, opts: Options) !Report {
        return check(r.arena_state.allocator(), &r.server, if (r.fake_ref != null) &r.ref else null, opts);
    }
};

const check = run;

fn expectStatus(report: Report, id: []const u8, want: Status, text: []const u8) !void {
    const got = report.find(id) orelse {
        std.debug.print("no check '{s}' in the report\n", .{id});
        return error.TestUnexpectedResult;
    };
    if (got.status != want or std.mem.indexOf(u8, got.detail, text) == null) {
        std.debug.print("check {s}: {s} \"{s}\"; wanted {s} with \"{s}\"\n", .{ id, @tagName(got.status), got.detail, @tagName(want), text });
        return error.TestUnexpectedResult;
    }
}

/// The report for a server with `faults`, with only `id` looked at.
fn expectFault(faults: fake.Faults, id: []const u8, want: Status, text: []const u8) !void {
    var r: Rig = undefined;
    try r.init(faults, null);
    defer r.deinit();
    const report = try r.run(.{ .only = id });
    try testing.expectEqual(@as(usize, 1), report.results.len);
    try expectStatus(report, id, want, text);
}

test "a_server_that_does_everything_right_passes_every_check" {
    var r: Rig = undefined;
    try r.init(.{ .key = "sesame" }, .{});
    defer r.deinit();
    const report = try r.run(.{});
    for (report.results) |x| {
        if (x.status != .pass) {
            std.debug.print("check {s}: {s} \"{s}\"\n", .{ x.id, @tagName(x.status), x.detail });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(names.len, report.results.len);
    try testing.expectEqualStrings("fake-1", report.model.?);
    try expectStatus(report, "models", .pass, "1 listed; using fake-1");
    try expectStatus(report, "auth", .pass, "refused (HTTP 401)");
    try expectStatus(report, "max_tokens", .pass, "stops at 5 tokens");
    try expectStatus(report, "context", .pass, "a prompt of about 1026 tokens is refused: HTTP 400: This model's maximum context length is 512 tokens.");
    try expectStatus(report, "logprobs", .pass, "8 tokens, each with 5 alternatives");
    try expectStatus(report, "usage_match", .pass, "3 conversations");
}

test "a_server_open_to_anyone_is_pointed_out" {
    try expectFault(.{}, "auth", .warn, "no key is needed");
}

test "a_dropped_output_format_is_caught" {
    try expectFault(.{ .drops_grammar = true }, "json_schema", .fail, "response_format is ignored");
    try expectFault(.{ .drops_grammar = true }, "json_object", .warn, "asked for JSON, got");
}

test "a_tool_call_written_into_the_text_is_caught" {
    try expectFault(.{ .tool_in_content = true }, "tools", .fail, "written into the text");
    try expectFault(.{ .tool_in_content = true }, "tools_stream", .fail, "written into the text");
}

test "a_long_prompt_cut_short_without_a_word_is_caught" {
    try expectFault(.{ .truncate_context = true }, "context", .fail, "a prompt of about 1026 tokens is cut to 512 without a word");
}

test "a_server_that_takes_every_prompt_tried_passes_with_the_length_reached" {
    var r: Rig = undefined;
    try r.init(.{ .context = 100_000 }, null);
    defer r.deinit();
    const report = try r.run(.{ .only = "context", .max_prompt_words = 2048 });
    try expectStatus(report, "context", .pass, "prompts up to 2050 tokens are taken whole");
}

test "ignored_limits_are_caught" {
    try expectFault(.{ .ignore_max_tokens = true }, "max_tokens", .fail, "asked for at most 5 tokens, got");
    try expectFault(.{ .ignore_stop = true }, "stop", .fail, "runs past the stop string");
}

test "answers_that_change_when_they_should_not_are_pointed_out" {
    try expectFault(.{ .nondeterministic = true }, "deterministic", .warn, "gave different text");
    try expectFault(.{ .ignore_seed = true }, "sampling", .warn, "the seed is ignored");
}

test "what_a_stream_or_an_answer_leaves_out_is_pointed_out" {
    try expectFault(.{ .no_done = true }, "stream", .warn, "[DONE]");
    try expectFault(.{ .no_usage = true }, "stream", .warn, "include_usage is ignored");
    try expectFault(.{ .no_usage = true }, "chat", .warn, "no token counts");
    try expectFault(.{ .no_usage = true }, "context", .skip, "no token counts");
    try expectFault(.{ .no_logprobs = true }, "logprobs", .warn, "fidelity cannot run");
}

test "another_chat_template_than_the_reference_is_caught" {
    var r: Rig = undefined;
    try r.init(.{ .template_differs = true }, .{});
    defer r.deinit();
    const report = try r.run(.{ .only = "usage_match" });
    try expectStatus(report, "usage_match", .fail, "conversation 1 is 4 prompt tokens here and 3 on the reference");
}

test "when_chat_does_not_work_the_rest_is_not_tried" {
    var r: Rig = undefined;
    try r.init(.{ .hang = true }, null);
    defer r.deinit();
    r.server.limits = .{ .idle_ms = 200 };
    const report = try r.run(.{});
    try expectStatus(report, "models", .pass, "fake-1");
    try expectStatus(report, "chat", .fail, "no answer within 200 ms");
    try expectStatus(report, "stream", .skip, "chat does not work");
    try testing.expectEqual(@as(usize, 1), report.count(.fail));
    try testing.expectEqual(names.len - 3, report.count(.skip));
}

test "a_wrong_key_fails_at_the_first_request" {
    var r: Rig = undefined;
    try r.init(.{ .key = "sesame" }, null);
    defer r.deinit();
    r.server.key = "wrong";
    const report = try r.run(.{});
    try expectStatus(report, "models", .fail, "HTTP 401: Incorrect API key provided.");
    try expectStatus(report, "chat", .fail, "HTTP 401");
}

test "checks_are_chosen_by_name" {
    var r: Rig = undefined;
    try r.init(.{}, null);
    defer r.deinit();
    const report = try r.run(.{ .only = "chat,stream,tools", .skip = "tools" });
    try testing.expectEqual(@as(usize, 2), report.results.len);
    try testing.expectEqualStrings("chat", report.results[0].id);
    try testing.expectEqualStrings("stream", report.results[1].id);
    try testing.expect(known("context") and !known("contxt"));
}

test "text_from_a_server_is_made_fit_for_one_line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a b", try clip(arena, "a\nb", 10));
    try testing.expectEqualStrings("abc...", try clip(arena, "abcdef", 3));
    // never cut inside a character
    try testing.expectEqualStrings("a...", try clip(arena, "a\u{00e9}b", 2));
}

test "a_stop_string_is_picked_from_the_middle_of_the_text" {
    try testing.expectEqualStrings("three", pickStop("one two three, four").?);
    // "the" is in the text before the middle: the next word that is new
    try testing.expectEqualStrings("river", pickStop("the cat the river now").?);
    try testing.expect(pickStop("too short") == null);
}

test "a_refused_certificate_says_how_to_go_on_anyway" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try describe(arena_state.allocator(), error.CertificateRejected, .{ .idle_ms = 1000 });
    try std.testing.expect(std.mem.indexOf(u8, text, "certificate") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--insecure") != null);
}

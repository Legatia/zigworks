//! A stand-in for a model server, for the tests and for trying llmcheck
//! without a model. It speaks the OpenAI-style API (/v1/models,
//! /v1/chat/completions, /v1/completions; whole answers and streamed ones,
//! token probabilities, JSON output, tool calls) and can be told to misbehave
//! in the ways real servers do, one fault at a time.
//!
//! Its "model": a token is a word; what follows a text is decided by a hash
//! of that text, so the same input gives the same probabilities every time.
const std = @import("std");
const jv = @import("jv.zig");
const sock = @import("sock.zig");
const Value = jv.Value;

pub const Faults = struct {
    /// Asked for JSON by schema, answers in prose (HTTP 200).
    drops_grammar: bool = false,
    /// Writes a tool call into the text instead of `tool_calls`.
    tool_in_content: bool = false,
    /// Cuts an over-long prompt down instead of refusing it.
    truncate_context: bool = false,
    ignore_max_tokens: bool = false,
    ignore_stop: bool = false,
    ignore_seed: bool = false,
    /// Different text for the same request, even at temperature 0.
    nondeterministic: bool = false,
    /// The model list answers; generation never does.
    hang: bool = false,
    /// Streams without the closing "[DONE]".
    no_done: bool = false,
    /// Never reports token counts.
    no_usage: bool = false,
    no_logprobs: bool = false,
    /// Slightly different probabilities everywhere (other weights).
    weights_differ: bool = false,
    /// One more token in front of every chat prompt (another template).
    template_differs: bool = false,
    /// Time per generated token.
    token_delay_ms: u32 = 0,
    /// When set, requests must carry this key.
    key: ?[]const u8 = null,
    /// Tokens the model can take in.
    context: u32 = 512,

    pub const names = [_][]const u8{
        "drops_grammar",    "tool_in_content", "truncate_context", "ignore_max_tokens",
        "ignore_stop",      "ignore_seed",     "nondeterministic", "hang",
        "no_done",          "no_usage",        "no_logprobs",      "weights_differ",
        "template_differs",
    };

    /// Switches on the fault called `name`; false when there is none.
    pub fn set(f: *Faults, name: []const u8) bool {
        inline for (names) |n| {
            if (std.mem.eql(u8, n, name)) {
                @field(f, n) = true;
                return true;
            }
        }
        return false;
    }
};

pub const model_name = "fake-1";

const vocab = [64][]const u8{
    "the",    "a",      "model",  "server", "answer", "token",  "river",   "stone",
    "light",  "under",  "over",   "small",  "large",  "quiet",  "bright",  "moves",
    "holds",  "gives",  "takes",  "finds",  "water",  "paper",  "garden",  "window",
    "letter", "number", "simple", "common", "early",  "late",   "green",   "silver",
    "walks",  "reads",  "writes", "counts", "and",    "but",    "with",    "from",
    "into",   "near",   "every",  "some",   "first",  "second", "morning", "evening",
    "house",  "road",   "bridge", "field",  "open",   "closed", "warm",    "cold",
    "slowly", "often",  "again",  "there",  "here",   "then",   "still",   "always",
};

const eos: u16 = 0xffff;
const n_cand = 8;
/// From here on the end of the text becomes more and more likely.
const eos_from = 16;
const hard_cap = 256;

const Cand = struct { id: u16, logit: f64 };

fn mix(x0: u64) u64 {
    var x = x0 +% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return x ^ (x >> 31);
}

/// What may follow the text with hash `h`, most likely first.
fn candidates(h: u64, generated: usize, f: *const Faults) [n_cand]Cand {
    var out: [n_cand]Cand = undefined;
    const base = mix(h);
    const start: usize = @intCast(base % vocab.len);
    // odd, so the eight words are different ones
    const stride: usize = 1 + 2 * @as(usize, @intCast((base >> 8) % 16));
    for (&out, 0..) |*c, i| {
        const r = mix(base +% @as(u64, i + 1) *% 0x9E3779B97F4A7C15);
        var logit = @as(f64, @floatFromInt(r % 6000)) / 1000.0;
        if (f.weights_differ) {
            const r2 = mix(r ^ 0xabcdef);
            logit += @as(f64, @floatFromInt(r2 % 1000)) / 1000.0 - 0.5;
        }
        c.* = .{ .id = @intCast((start + i * stride) % vocab.len), .logit = logit };
    }
    if (generated >= eos_from) out[0] = .{ .id = eos, .logit = 3.0 + @as(f64, @floatFromInt(generated - eos_from)) * 0.75 };
    std.mem.sort(Cand, &out, {}, struct {
        fn before(_: void, a: Cand, b: Cand) bool {
            return a.logit > b.logit;
        }
    }.before);
    return out;
}

fn pick(cands: []const Cand, temperature: f64, rng: std.Random) usize {
    if (temperature <= 0) return 0;
    var weights: [n_cand]f64 = undefined;
    var total: f64 = 0;
    for (cands, 0..) |c, i| {
        weights[i] = @exp((c.logit - cands[0].logit) / temperature);
        total += weights[i];
    }
    var x = rng.float(f64) * total;
    for (weights[0..cands.len], 0..) |w, i| {
        if (x < w) return i;
        x -= w;
    }
    return cands.len - 1;
}

const Alt = struct { text: []const u8, logprob: f64 };

const Tok = struct {
    /// As it appears in the text: with a space in front, except the first.
    text: []const u8,
    logprob: f64,
    alts: [n_cand]Alt,
};

const Gen = struct {
    max_tokens: usize = hard_cap,
    temperature: f64 = 1,
    seed: ?u64 = null,
    stop: ?[]const u8 = null,
};

const Generated = struct { toks: []Tok, finish: []const u8 };

fn generate(io: std.Io, arena: std.mem.Allocator, h0: u64, g: Gen, f: *const Faults) !Generated {
    var toks: std.ArrayList(Tok) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var h = h0;
    const random_seed = f.ignore_seed or f.nondeterministic or g.seed == null;
    var chance: u64 = undefined;
    io.random(std.mem.asBytes(&chance));
    var prng = std.Random.DefaultPrng.init(if (random_seed) chance else g.seed.?);
    const temperature: f64 = if (f.nondeterministic) 1 else g.temperature;
    const max = if (f.ignore_max_tokens) hard_cap else @min(g.max_tokens, hard_cap);
    var finish: []const u8 = "stop";
    while (true) {
        if (toks.items.len >= max) {
            finish = "length";
            break;
        }
        const cands = candidates(h, toks.items.len, f);
        var lse: f64 = 0;
        for (cands) |c| lse += @exp(c.logit - cands[0].logit);
        const log_total = cands[0].logit + @log(lse);
        const chosen = cands[pick(&cands, temperature, prng.random())];
        if (chosen.id == eos) break;
        const first = toks.items.len == 0;
        var tok: Tok = .{
            .text = try wordText(arena, chosen.id, first),
            .logprob = chosen.logit - log_total,
            .alts = undefined,
        };
        for (cands, 0..) |c, i| tok.alts[i] = .{ .text = try wordText(arena, c.id, first), .logprob = c.logit - log_total };
        try text.appendSlice(arena, tok.text);
        if (g.stop) |stop| {
            if (!f.ignore_stop and stop.len > 0 and std.mem.indexOf(u8, text.items, stop) != null) break;
        }
        try toks.append(arena, tok);
        h = std.hash.Wyhash.hash(h, vocab[chosen.id]);
    }
    return .{ .toks = try toks.toOwnedSlice(arena), .finish = finish };
}

fn wordText(arena: std.mem.Allocator, id: u16, first: bool) ![]const u8 {
    if (id == eos) return "";
    return if (first) vocab[id] else try std.fmt.allocPrint(arena, " {s}", .{vocab[id]});
}

fn splitWords(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), text: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| try out.append(arena, w);
}

/// JSON that fits `schema`, for the simple schemas the checks use.
fn fromSchema(w: *std.Io.Writer, schema: ?Value, depth: usize) !void {
    const kind = jv.str(jv.get(schema, "type")) orelse "string";
    if (jv.arr(jv.get(schema, "enum"))) |values| {
        if (values.len > 0) return w.print("{f}", .{std.json.fmt(values[0], .{})});
    }
    if (std.mem.eql(u8, kind, "object") and depth < 8) {
        try w.writeByte('{');
        if (jv.get(schema, "properties")) |props| {
            var it = props.object.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}:", .{std.json.fmt(e.key_ptr.*, .{})});
                try fromSchema(w, e.value_ptr.*, depth + 1);
            }
        }
        try w.writeByte('}');
    } else if (std.mem.eql(u8, kind, "array") and depth < 8) {
        try w.writeByte('[');
        try fromSchema(w, jv.get(schema, "items"), depth + 1);
        try w.writeByte(']');
    } else if (std.mem.eql(u8, kind, "integer") or std.mem.eql(u8, kind, "number")) {
        try w.writeAll("7");
    } else if (std.mem.eql(u8, kind, "boolean")) {
        try w.writeAll("true");
    } else if (std.mem.eql(u8, kind, "null")) {
        try w.writeAll("null");
    } else {
        try w.writeAll("\"river\"");
    }
}

pub const Server = struct {
    io: std.Io,
    faults: Faults,
    listener: sock.Listener,
    port: u16,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    /// Requests seen, of any kind.
    requests: std.atomic.Value(u32) = .init(0),
    /// Generations running at the same moment, and the most there were.
    generating: std.atomic.Value(u32) = .init(0),
    peak_generating: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    open: std.ArrayList(sock.Handle) = .empty,

    const gpa = std.heap.page_allocator;
    /// How long a connection may sit without a request before it is closed.
    const idle_ms = 60 * 60 * 1000;

    /// Listens on 127.0.0.1; `port` 0 takes a free one (see `Server.port`).
    pub fn start(io: std.Io, faults: Faults, port: u16) !*Server {
        const listener = try sock.Listener.open(port);
        errdefer listener.close();
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{ .io = io, .faults = faults, .listener = listener, .port = listener.port };
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
    }

    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        // wake the accept
        if (sock.connect(s.io, "127.0.0.1", s.port, 1000)) |c| sock.closeHandle(c) else |_| {}
        if (s.thread) |t| t.join();
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.open.items) |c| sock.shutdown(c);
        }
        while (s.active.load(.acquire) > 0) s.pause(1);
        s.listener.close();
        s.open.deinit(gpa);
        gpa.destroy(s);
    }

    fn pause(s: *Server, ms: u64) void {
        s.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
    }

    fn acceptLoop(s: *Server) void {
        while (true) {
            const conn = s.listener.accept() catch {
                if (s.stopping.load(.acquire)) return;
                continue;
            };
            if (s.stopping.load(.acquire)) {
                sock.closeHandle(conn);
                return;
            }
            {
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                s.open.append(gpa, conn) catch {};
            }
            _ = s.active.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, serve, .{ s, conn }) catch {
                s.done(conn);
                continue;
            };
            t.detach();
        }
    }

    fn done(s: *Server, conn: sock.Handle) void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.open.items, 0..) |c, i| {
                if (c == conn) {
                    _ = s.open.swapRemove(i);
                    break;
                }
            }
        }
        sock.closeHandle(conn);
        _ = s.active.fetchSub(1, .acq_rel);
    }

    fn serve(s: *Server, conn: sock.Handle) void {
        defer s.done(conn);
        var rbuf: [32 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var sk: sock.Socket = undefined;
        sk.init(s.io, conn, &rbuf, &wbuf, idle_ms);
        var http_server = std.http.Server.init(&sk.reader, &sk.writer);
        while (!s.stopping.load(.acquire)) {
            var req = http_server.receiveHead() catch return;
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            s.handle(arena_state.allocator(), &req) catch return;
        }
    }

    fn handle(s: *Server, arena: std.mem.Allocator, req: *std.http.Server.Request) !void {
        _ = s.requests.fetchAdd(1, .monotonic);
        const method = req.head.method;
        var target = try arena.dupe(u8, req.head.target);
        if (std.mem.indexOfScalar(u8, target, '?')) |q| target = target[0..q];
        var authorized = s.faults.key == null;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "authorization")) continue;
            const k = s.faults.key orelse continue;
            if (std.mem.startsWith(u8, h.value, "Bearer ") and std.mem.eql(u8, h.value[7..], k)) authorized = true;
        }
        var body_buf: [8192]u8 = undefined;
        const body_reader = try req.readerExpectContinue(&body_buf);
        const body = try body_reader.allocRemaining(arena, .limited(32 << 20));

        if (!authorized) return fail(req, arena, .unauthorized, "Incorrect API key provided.", "invalid_api_key");
        if (method == .GET and std.mem.eql(u8, target, "/v1/models")) {
            return json(req, .ok, "{\"object\":\"list\",\"data\":[{\"id\":\"" ++ model_name ++ "\",\"object\":\"model\",\"created\":0,\"owned_by\":\"llmcheck\"}]}");
        }
        const is_chat = std.mem.eql(u8, target, "/v1/chat/completions");
        if (method == .POST and (is_chat or std.mem.eql(u8, target, "/v1/completions"))) {
            if (s.faults.hang) {
                var waited: usize = 0;
                while (!s.stopping.load(.acquire) and waited < 120_000) : (waited += 20) s.pause(20);
                return error.Hung;
            }
            const now = s.generating.fetchAdd(1, .acq_rel) + 1;
            _ = s.peak_generating.fetchMax(now, .acq_rel);
            defer _ = s.generating.fetchSub(1, .acq_rel);
            return s.complete(arena, req, body, is_chat);
        }
        return fail(req, arena, .not_found, "No such endpoint.", "not_found");
    }

    fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn fail(req: *std.http.Server.Request, arena: std.mem.Allocator, status: std.http.Status, message: []const u8, code: []const u8) !void {
        const body = try std.fmt.allocPrint(arena, "{{\"error\":{{\"message\":{f},\"type\":\"invalid_request_error\",\"code\":{f}}}}}", .{ std.json.fmt(message, .{}), std.json.fmt(code, .{}) });
        try json(req, status, body);
    }

    /// One piece of an answer as it is streamed.
    const Piece = struct { text: []const u8, tok: ?*const Tok = null };

    fn complete(s: *Server, arena: std.mem.Allocator, req: *std.http.Server.Request, body: []const u8, is_chat: bool) !void {
        const f = &s.faults;
        const v = jv.parse(arena, body) orelse return fail(req, arena, .bad_request, "The request body is not JSON.", "bad_json");

        // the prompt as tokens
        var toks: std.ArrayList([]const u8) = .empty;
        if (is_chat) {
            const msgs = jv.arr(jv.get(v, "messages")) orelse return fail(req, arena, .bad_request, "'messages' is required.", "missing_messages");
            if (f.template_differs) try toks.append(arena, "<|bos|>");
            for (msgs) |m| {
                try toks.append(arena, try std.fmt.allocPrint(arena, "<|{s}|>", .{jv.str(jv.get(m, "role")) orelse "user"}));
                if (jv.str(jv.get(m, "content"))) |c| try splitWords(arena, &toks, c);
            }
            try toks.append(arena, "<|assistant|>");
        } else {
            const p = jv.str(jv.get(v, "prompt")) orelse return fail(req, arena, .bad_request, "'prompt' is required.", "missing_prompt");
            try splitWords(arena, &toks, p);
        }
        var prompt = toks.items;
        if (prompt.len > f.context) {
            if (!f.truncate_context) {
                const msg = try std.fmt.allocPrint(arena, "This model's maximum context length is {d} tokens. However, your request has {d} input tokens.", .{ f.context, prompt.len });
                return fail(req, arena, .bad_request, msg, "context_length_exceeded");
            }
            prompt = prompt[prompt.len - f.context ..];
        }
        var h: u64 = 0x5eed;
        for (prompt) |t| h = std.hash.Wyhash.hash(h, t);

        var g: Gen = .{};
        if (jv.int(jv.get(v, "max_tokens")) orelse jv.int(jv.get(v, "max_completion_tokens"))) |m| g.max_tokens = @intCast(@max(m, 0));
        if (jv.num(jv.get(v, "temperature"))) |t| g.temperature = t;
        if (jv.int(jv.get(v, "seed"))) |sd| g.seed = @bitCast(sd);
        if (jv.get(v, "stop")) |st| {
            g.stop = jv.str(st) orelse if (jv.arr(st)) |a| (if (a.len > 0) jv.str(a[0]) else null) else null;
        }
        const stream = jv.boolean(jv.get(v, "stream")) orelse false;
        const want_usage = !f.no_usage and (!stream or (jv.boolean(jv.at(v, &.{ "stream_options", "include_usage" })) orelse false));
        var top: usize = 0;
        var want_logprobs = false;
        if (is_chat) {
            want_logprobs = jv.boolean(jv.get(v, "logprobs")) orelse false;
            top = @intCast(@max(jv.int(jv.get(v, "top_logprobs")) orelse 0, 0));
        } else if (jv.int(jv.get(v, "logprobs"))) |k| {
            want_logprobs = true;
            top = @intCast(@max(k, 0));
        }
        if (f.no_logprobs) want_logprobs = false;
        top = @min(top, n_cand);

        // what to answer
        var pieces: std.ArrayList(Piece) = .empty;
        var finish: []const u8 = "stop";
        var tool_name: ?[]const u8 = null;
        var tool_args: []const u8 = "";
        var completion_tokens: usize = 0;

        const tools = jv.arr(jv.get(v, "tools")) orelse &[_]Value{};
        const tool_choice = jv.get(v, "tool_choice");
        const no_tools = if (jv.str(tool_choice)) |c| std.mem.eql(u8, c, "none") else false;
        const format = jv.str(jv.at(v, &.{ "response_format", "type" })) orelse "text";
        var structured: ?[]const u8 = null;

        if (is_chat and tools.len > 0 and !no_tools) {
            var chosen = tools[0];
            if (jv.str(jv.at(tool_choice, &.{ "function", "name" }))) |wanted| {
                for (tools) |t| {
                    if (std.mem.eql(u8, jv.str(jv.at(t, &.{ "function", "name" })) orelse "", wanted)) chosen = t;
                }
            }
            var args: std.Io.Writer.Allocating = .init(arena);
            try fromSchema(&args.writer, jv.at(chosen, &.{ "function", "parameters" }), 0);
            const name = jv.str(jv.at(chosen, &.{ "function", "name" })) orelse "tool";
            if (f.tool_in_content) {
                structured = try std.fmt.allocPrint(arena, "<tool_call>{{\"name\":{f},\"arguments\":{s}}}</tool_call>", .{ std.json.fmt(name, .{}), args.written() });
            } else {
                tool_name = name;
                tool_args = args.written();
                finish = "tool_calls";
                completion_tokens = 12;
            }
        } else if (is_chat and !f.drops_grammar and std.mem.eql(u8, format, "json_schema")) {
            var out: std.Io.Writer.Allocating = .init(arena);
            try fromSchema(&out.writer, jv.at(v, &.{ "response_format", "json_schema", "schema" }), 0);
            structured = out.written();
        }
        if (structured) |text| {
            var i: usize = 0;
            while (i < text.len) : (i += 8) try pieces.append(arena, .{ .text = text[i..@min(i + 8, text.len)] });
            completion_tokens = pieces.items.len;
        } else if (tool_name == null) {
            const made = try generate(s.io, arena, h, g, f);
            finish = made.finish;
            completion_tokens = made.toks.len;
            const as_object = is_chat and !f.drops_grammar and std.mem.eql(u8, format, "json_object");
            if (as_object) try pieces.append(arena, .{ .text = "{\"answer\":\"" });
            for (made.toks) |*t| try pieces.append(arena, .{ .text = t.text, .tok = if (as_object) null else t });
            if (as_object) try pieces.append(arena, .{ .text = "\"}" });
        }
        const usage = try std.fmt.allocPrint(arena, "{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}", .{ prompt.len, completion_tokens, prompt.len + completion_tokens });
        const delay: u64 = f.token_delay_ms;

        if (!stream) {
            if (delay > 0) s.pause(delay * @max(completion_tokens, 1));
            var out: std.Io.Writer.Allocating = .init(arena);
            const w = &out.writer;
            var text: std.ArrayList(u8) = .empty;
            for (pieces.items) |p| try text.appendSlice(arena, p.text);
            try w.print("{{\"id\":\"cmpl-fake\",\"object\":\"{s}\",\"created\":0,\"model\":\"" ++ model_name ++ "\",\"choices\":[{{\"index\":0,", .{if (is_chat) "chat.completion" else "text_completion"});
            if (is_chat) {
                try w.writeAll("\"message\":{\"role\":\"assistant\",");
                if (tool_name) |name| {
                    try w.print("\"content\":null,\"tool_calls\":[{{\"id\":\"call_1\",\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}]}},", .{ std.json.fmt(name, .{}), std.json.fmt(tool_args, .{}) });
                } else {
                    try w.print("\"content\":{f}}},", .{std.json.fmt(text.items, .{})});
                }
            } else {
                try w.print("\"text\":{f},", .{std.json.fmt(text.items, .{})});
            }
            try w.writeAll("\"logprobs\":");
            if (want_logprobs) try writeLogprobs(w, pieces.items, top, is_chat) else try w.writeAll("null");
            try w.print(",\"finish_reason\":\"{s}\"}}]", .{finish});
            if (want_usage) try w.print(",\"usage\":{s}", .{usage});
            try w.writeAll("}");
            return json(req, .ok, out.written());
        }

        var sbuf: [4096]u8 = undefined;
        var bw = try req.respondStreaming(&sbuf, .{ .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        } } });
        const w = &bw.writer;
        const head = "data: {\"id\":\"cmpl-fake\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"" ++ model_name ++ "\",\"choices\":[{\"index\":0,";
        // the same, as a format string
        const head_f = "data: {{\"id\":\"cmpl-fake\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"" ++ model_name ++ "\",\"choices\":[{{\"index\":0,";
        if (is_chat) {
            // as real servers do: the role first, with no text yet
            try w.writeAll(head ++ "\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n");
            try w.flush();
            try bw.flush();
        }
        if (tool_name) |name| {
            if (delay > 0) s.pause(delay);
            try w.print(head_f ++ "\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":\"\"}}}}]}},\"finish_reason\":null}}]}}\n\n", .{std.json.fmt(name, .{})});
            var i: usize = 0;
            while (i < tool_args.len) : (i += 6) {
                try w.print(head_f ++ "\"delta\":{{\"tool_calls\":[{{\"index\":0,\"function\":{{\"arguments\":{f}}}}}]}},\"finish_reason\":null}}]}}\n\n", .{std.json.fmt(tool_args[i..@min(i + 6, tool_args.len)], .{})});
            }
            try w.flush();
            try bw.flush();
        }
        for (pieces.items) |p| {
            if (delay > 0) s.pause(delay);
            if (is_chat) {
                try w.print(head_f ++ "\"delta\":{{\"content\":{f}}},", .{std.json.fmt(p.text, .{})});
            } else {
                try w.print(head_f ++ "\"text\":{f},", .{std.json.fmt(p.text, .{})});
            }
            if (want_logprobs and p.tok != null) {
                try w.writeAll("\"logprobs\":");
                try writeLogprobs(w, &.{p}, top, is_chat);
                try w.writeAll(",");
            }
            try w.writeAll("\"finish_reason\":null}]}\n\n");
            try w.flush();
            try bw.flush();
        }
        if (is_chat) {
            try w.print(head_f ++ "\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}\n\n", .{finish});
        } else {
            try w.print(head_f ++ "\"text\":\"\",\"finish_reason\":\"{s}\"}}]}}\n\n", .{finish});
        }
        if (want_usage) try w.print("data: {{\"id\":\"cmpl-fake\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"" ++ model_name ++ "\",\"choices\":[],\"usage\":{s}}}\n\n", .{usage});
        if (!f.no_done) try w.writeAll("data: [DONE]\n\n");
        try bw.end();
    }

    fn writeLogprobs(w: *std.Io.Writer, pieces: []const Piece, top: usize, is_chat: bool) !void {
        if (is_chat) {
            try w.writeAll("{\"content\":[");
            var n: usize = 0;
            for (pieces) |p| {
                const t = p.tok orelse continue;
                if (n > 0) try w.writeByte(',');
                n += 1;
                try w.print("{{\"token\":{f},\"logprob\":{d},\"bytes\":null,\"top_logprobs\":[", .{ std.json.fmt(t.text, .{}), t.logprob });
                for (t.alts[0..top], 0..) |a, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.print("{{\"token\":{f},\"logprob\":{d},\"bytes\":null}}", .{ std.json.fmt(a.text, .{}), a.logprob });
                }
                try w.writeAll("]}");
            }
            try w.writeAll("]}");
            return;
        }
        // the older layout of /v1/completions
        try w.writeAll("{\"tokens\":[");
        var n: usize = 0;
        for (pieces) |p| {
            const t = p.tok orelse continue;
            if (n > 0) try w.writeByte(',');
            n += 1;
            try w.print("{f}", .{std.json.fmt(t.text, .{})});
        }
        try w.writeAll("],\"token_logprobs\":[");
        n = 0;
        for (pieces) |p| {
            const t = p.tok orelse continue;
            if (n > 0) try w.writeByte(',');
            n += 1;
            try w.print("{d}", .{t.logprob});
        }
        try w.writeAll("],\"top_logprobs\":[");
        n = 0;
        for (pieces) |p| {
            const t = p.tok orelse continue;
            if (n > 0) try w.writeByte(',');
            n += 1;
            try w.writeByte('{');
            for (t.alts[0..top], 0..) |a, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}:{d}", .{ std.json.fmt(a.text, .{}), a.logprob });
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
};

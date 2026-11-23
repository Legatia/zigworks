//! Home Assistant's conversation agent, served: an OpenAI-compatible chat
//! endpoint that Home Assistant's llama.cpp integration calls with what its
//! voice pipeline heard. Two routes: `GET /v1/models` (asked at setup) and
//! `POST /v1/chat/completions`, on the one address `[voice_agent] listen`
//! names. Every request carries the bearer token the owner stored (compared
//! as SHA-256 digests, in constant time, before a body is read); a body
//! over 256 KB is refused unread. What was said goes to the answerer (the
//! speech turn) and its words come back as JSON, or as server-sent events
//! when the request asks to stream.
const std = @import("std");
const Io = std.Io;
const sock = @import("sock.zig");
const log_mod = @import("log.zig");
const speech = @import("speech.zig");

const config = @import("config.zig");

/// What makes the words to speak from what was said: the speech turn.
pub const Answerer = struct {
    ctx: *anyopaque,
    /// On the request's thread; the words in `a`. It ends in its own time
    /// (the speech turn's limit) and never fails: its own line if need be.
    answer: *const fn (ctx: *anyopaque, a: std.mem.Allocator, said: speech.Said) []const u8,
};

pub const Options = struct {
    /// `[voice_agent] listen` (config.parseListen's rules; port 0: a free
    /// one, for the tests).
    listen: []const u8,
    /// The stored token; only its SHA-256 is kept.
    token: []const u8,
    answerer: Answerer,
    log: ?*log_mod.Log = null,
    /// A request's body past this is refused unread.
    max_body: usize = 256 * 1024,
    /// A request's head, and then its body, must come within this.
    head_ms: u32 = 10_000,
    /// A kept connection waits this long for its next request.
    idle_ms: u32 = 30_000,
    /// Connections at once; more are closed as they come.
    max_connections: u32 = 4,
};

/// The shortest token taken: Home Assistant's API key field holds the same.
pub const min_token = 16;

/// What one model list answers: harness.
const models_json = "{\"object\":\"list\",\"data\":[{\"id\":\"harness\",\"object\":\"model\",\"created\":0,\"owned_by\":\"harness\"}]}";

const Refusal = enum { route, token, size, request };

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    listener: sock.Listener,
    port: u16,
    /// Where it listens, as "127.0.0.1:8765" or "[::1]:8765".
    addr_buf: [64]u8 = undefined,
    addr_len: usize = 0,
    /// Where `stop` connects to wake the accept.
    wake_host: [48]u8 = undefined,
    wake_len: usize = 0,
    digest: [32]u8,
    answerer: Answerer,
    log: ?*log_mod.Log,
    max_body: usize,
    head_ms: u32,
    idle_ms: u32,
    max_connections: u32,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    mutex: Io.Mutex = .init,
    open: std.ArrayList(sock.Handle) = .empty,
    /// Answers given, for their ids.
    seq: std.atomic.Value(u64) = .init(0),
    /// When a refusal of each kind was last logged (one a minute).
    last_refusal_ms: [4]i64 = @splat(-std.math.maxInt(i32)),

    pub fn start(gpa: std.mem.Allocator, io: Io, o: Options) !*Server {
        var ip = config.parseListen(o.listen) orelse return error.BadAddress;
        if (o.token.len < min_token) return error.ShortToken;
        const listener = try sock.Listener.openOn(ip);
        errdefer listener.close();
        switch (ip) {
            .ip4 => |*x| x.port = listener.port,
            .ip6 => |*x| x.port = listener.port,
        }
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .port = listener.port,
            .digest = undefined,
            .answerer = o.answerer,
            .log = o.log,
            .max_body = o.max_body,
            .head_ms = o.head_ms,
            .idle_ms = o.idle_ms,
            .max_connections = o.max_connections,
        };
        std.crypto.hash.sha2.Sha256.hash(o.token, &s.digest, .{});
        s.addr_len = (std.fmt.bufPrint(&s.addr_buf, "{f}", .{ip}) catch return error.BadAddress).len;
        const host = s.addr_buf[0 .. std.mem.lastIndexOfScalar(u8, s.addr_buf[0..s.addr_len], ':') orelse 0];
        const bare = std.mem.trim(u8, host, "[]");
        @memcpy(s.wake_host[0..bare.len], bare);
        s.wake_len = bare.len;
        if (s.log) |l| l.write(.chat, false, .{ .event = "voice agent listening", .address = s.address() }) catch {};
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
    }

    /// Where it listens.
    pub fn address(s: *const Server) []const u8 {
        return s.addr_buf[0..s.addr_len];
    }

    /// Stops listening and waits for the requests going to end (their
    /// speech turns were stopped first).
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        if (sock.connect(s.io, s.wake_host[0..s.wake_len], s.port, 1000)) |c| sock.closeHandle(c) else |_| {}
        if (s.thread) |th| th.join();
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.open.items) |c| sock.shutdown(c);
        }
        var waited: u32 = 0;
        while (s.active.load(.acquire) > 0 and waited < 60_000) : (waited += 5) s.io.sleep(.fromMilliseconds(5), .awake) catch {};
        s.listener.close();
        if (s.log) |l| l.write(.chat, false, .{ .event = "voice agent stopped", .address = s.address() }) catch {};
        // a request still going owns its memory: let it go first
        if (s.active.load(.acquire) > 0) return;
        s.open.deinit(s.gpa);
        s.gpa.destroy(s);
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
            if (s.active.load(.acquire) >= s.max_connections) {
                sock.closeHandle(conn);
                continue;
            }
            {
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                s.open.append(s.gpa, conn) catch {};
            }
            _ = s.active.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, serve, .{ s, conn }) catch {
                s.done(conn);
                continue;
            };
            th.detach();
        }
    }

    fn done(s: *Server, conn: sock.Handle) void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.open.items, 0..) |c, i| if (c == conn) {
                _ = s.open.swapRemove(i);
                break;
            };
        }
        sock.closeHandle(conn);
        _ = s.active.fetchSub(1, .acq_rel);
    }

    fn serve(s: *Server, conn: sock.Handle) void {
        defer s.done(conn);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var sk: sock.Socket = undefined;
        sk.init(s.io, conn, &rbuf, &wbuf, s.head_ms);
        var http_server = std.http.Server.init(&sk.reader, &sk.writer);
        var first = true;
        while (!s.stopping.load(.acquire)) {
            // a head within its time; a kept connection waits a while first
            const wait = if (first) s.head_ms else s.idle_ms;
            sk.setLimits(wait, wait, &s.stopping);
            var req = http_server.receiveHead() catch return;
            first = false;
            sk.setLimits(s.head_ms, s.head_ms, &s.stopping);
            var arena_state = std.heap.ArenaAllocator.init(s.gpa);
            defer arena_state.deinit();
            const keep = s.handle(arena_state.allocator(), &req, &sk) catch return;
            if (!keep) return;
        }
    }

    fn handle(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, sk: *sock.Socket) !bool {
        const target = req.head.target;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const models = std.mem.eql(u8, path, "/v1/models");
        if (!models and !std.mem.eql(u8, path, "/v1/chat/completions"))
            return s.refuse(req, .route, .not_found, "not_found", "harness answers POST /v1/chat/completions and GET /v1/models only");
        const want: std.http.Method = if (models) .GET else .POST;
        if (req.head.method != want)
            return s.refuse(req, .route, .method_not_allowed, "method_not_allowed", if (models) "the model list is GET /v1/models" else "speech is POST /v1/chat/completions");
        // the token, before anything of the request is read
        if (!s.authorized(req)) return s.refuse(req, .token, .unauthorized, "invalid_api_key", "the API key is not the one stored as harness's [voice_agent] token");
        if (models) return s.respond(req, .ok, models_json, "application/json");
        if (req.head.content_length) |n| if (n > s.max_body)
            return s.refuse(req, .size, .payload_too_large, "request_too_large", "the request is over 256 KB: switch off Home Assistant's AI tools for this agent");
        var body_buf: [8192]u8 = undefined;
        const r = req.readerExpectContinue(&body_buf) catch return false;
        const body = r.allocRemaining(a, .limited(s.max_body)) catch |e| switch (e) {
            error.StreamTooLong => return s.refuse(req, .size, .payload_too_large, "request_too_large", "the request is over 256 KB: switch off Home Assistant's AI tools for this agent"),
            else => return false,
        };
        const said = speech.read(a, body) catch |e| return s.refuse(req, .request, .bad_request, "invalid_request", switch (e) {
            error.NothingSaid => "no user message with words in it",
            error.NoMessages => "no messages",
            else => "not a chat request in JSON",
        });
        const words = s.answerer.answer(s.answerer.ctx, a, said);
        // the answer may have taken its time: its writing gets its own
        sk.setLimits(10_000, 10_000, &s.stopping);
        const n = s.seq.fetchAdd(1, .acq_rel) + 1;
        const created = @divFloor(Io.Clock.real.now(s.io).nanoseconds, std.time.ns_per_s);
        const content = try jsonString(a, words);
        if (said.stream) {
            const head = try std.fmt.allocPrint(a, "{{\"id\":\"chatcmpl-harness-{d}\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":\"harness\",\"choices\":[{{\"index\":0,", .{ n, created });
            const text = try std.fmt.allocPrint(a, "data: {s}\"delta\":{{\"role\":\"assistant\",\"content\":{s}}},\"finish_reason\":null}}]}}\n\ndata: {s}\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n", .{ head, content, head });
            return s.respond(req, .ok, text, "text/event-stream");
        }
        const text = try std.fmt.allocPrint(a, "{{\"id\":\"chatcmpl-harness-{d}\",\"object\":\"chat.completion\",\"created\":{d},\"model\":\"harness\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":{s}}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}}}", .{ n, created, content });
        return s.respond(req, .ok, text, "application/json");
    }

    /// `Authorization: Bearer TOKEN` whose SHA-256 is the stored one's,
    /// compared in time that doesn't depend on where they differ.
    fn authorized(s: *const Server, req: *const std.http.Server.Request) bool {
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "authorization")) continue;
            const v = std.mem.trim(u8, h.value, " ");
            if (v.len < 7 or !std.ascii.eqlIgnoreCase(v[0..7], "bearer ")) return false;
            var got: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(std.mem.trim(u8, v[7..], " "), &got, .{});
            return std.crypto.timing_safe.eql([32]u8, got, s.digest);
        }
        return false;
    }

    /// An error in OpenAI's form; the connection ends with it. Logged once
    /// a minute a kind, without what came in.
    fn refuse(s: *Server, req: *std.http.Server.Request, why: Refusal, status: std.http.Status, code: []const u8, message: []const u8) !bool {
        const now = Io.Clock.awake.now(s.io).toMilliseconds();
        const i = @intFromEnum(why);
        if (now - s.last_refusal_ms[i] >= 60 * 1000) {
            s.last_refusal_ms[i] = @intCast(now);
            if (s.log) |l| l.write(.chat, false, .{ .event = "voice agent refused", .why = @tagName(why), .status = @intFromEnum(status) }) catch {};
        }
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"error\":{{\"message\":\"{s}\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"{s}\"}}}}", .{ message, code }) catch "{}";
        try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
        return false;
    }

    fn respond(s: *Server, req: *std.http.Server.Request, status: std.http.Status, body: []const u8, ct: []const u8) !bool {
        _ = s;
        const keep = req.head.keep_alive;
        try req.respond(body, .{ .status = status, .keep_alive = keep, .extra_headers = &.{ .{ .name = "content-type", .value = ct }, .{ .name = "cache-control", .value = "no-store" } } });
        return keep;
    }
};

/// `text` as a JSON string, quotes and all.
fn jsonString(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, text, .{});
}

/// A request as Home Assistant's client sends it.
pub const Request = struct {
    method: []const u8 = "POST",
    path: []const u8 = "/v1/chat/completions",
    /// The Authorization header's value; null: none.
    auth: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const Reply = struct { status: u16, head: []const u8, body: []const u8 };

/// One request on a connection of its own, as Home Assistant's client
/// sends it; the reply in `a`. For the tests and harness-fake's `--ha`.
pub fn request(io: Io, a: std.mem.Allocator, host: []const u8, port: u16, r: Request) !Reply {
    const h = try sock.connect(io, host, port, 2000);
    const rbuf = try a.alloc(u8, 64 * 1024);
    var wbuf: [4096]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(io, h, rbuf, &wbuf, 90_000);
    defer sk.close();
    try sk.writer.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n", .{ r.method, r.path, host, port, r.body.len });
    if (r.auth) |x| try sk.writer.print("Authorization: {s}\r\n", .{x});
    try sk.writer.writeAll("Connection: close\r\n\r\n");
    try sk.writer.writeAll(r.body);
    try sk.writer.flush();
    const all = try sk.reader.allocRemaining(a, .limited(4 << 20));
    const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadResponse;
    if (all.len < 12) return error.BadResponse;
    return .{ .status = try std.fmt.parseInt(u16, all[9..12], 10), .head = all[0..split], .body = all[split + 4 ..] };
}

const t = std.testing;

/// The test answerer: what it heard, and what it says.
const Heard = struct {
    mutex: Io.Mutex = .init,
    calls: u32 = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,
    room: [64]u8 = undefined,
    room_len: usize = 0,
    reply: []const u8 = "The kitchen light is on.",

    fn answerer(h: *Heard) Answerer {
        return .{ .ctx = h, .answer = answer };
    }

    fn answer(ctx: *anyopaque, a: std.mem.Allocator, said: speech.Said) []const u8 {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(t.io);
        defer h.mutex.unlock(t.io);
        h.calls += 1;
        h.last_len = @min(said.text.len, h.last.len);
        @memcpy(h.last[0..h.last_len], said.text[0..h.last_len]);
        h.room_len = @min(said.room.len, h.room.len);
        @memcpy(h.room[0..h.room_len], said.room[0..h.room_len]);
        return a.dupe(u8, h.reply) catch "";
    }

    fn count(h: *Heard) u32 {
        h.mutex.lockUncancelable(t.io);
        defer h.mutex.unlock(t.io);
        return h.calls;
    }
};

const token = "t0ken-for-tests-1234567890";
const say_kitchen = "{\"model\":\"harness\",\"messages\":[{\"role\":\"system\",\"content\":\"Room: Kitchen\\nLanguage: en\"},{\"role\":\"user\",\"content\":\"turn on the kitchen light\"}]}";

const Fix = struct {
    heard: Heard = .{},
    s: *Server = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(f: *Fix, o: Options) !void {
        f.* = .{};
        f.arena = .init(t.allocator);
        var opts = o;
        opts.answerer = f.heard.answerer();
        f.s = try Server.start(t.allocator, t.io, opts);
    }

    fn deinit(f: *Fix) void {
        f.s.stop();
        f.arena.deinit();
    }

    fn send(f: *Fix, r: Request) !Reply {
        return request(t.io, f.arena.allocator(), "127.0.0.1", f.s.port, r);
    }
};

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

test "voice_agent_refuses_without_the_token" {
    var f: Fix = undefined;
    try f.init(.{ .listen = "127.0.0.1:0", .token = token, .answerer = undefined });
    defer f.deinit();
    // none, another one, the right one without "Bearer": all refused unheard
    for ([_]?[]const u8{ null, "Bearer wrong-token-1234567890", token, "Bearer " ++ token ++ "x", "Bearer" }) |auth| {
        const got = try f.send(.{ .auth = auth, .body = say_kitchen });
        try t.expectEqual(401, got.status);
        try expectHas(got.body, "\"code\":\"invalid_api_key\"");
    }
    try t.expectEqual(401, (try f.send(.{ .method = "GET", .path = "/v1/models", .auth = "Bearer nope" })).status);
    try t.expectEqual(0, f.heard.count());
    // the right token, as Home Assistant's client sends it
    const ok = try f.send(.{ .auth = "Bearer " ++ token, .body = say_kitchen });
    try t.expectEqual(200, ok.status);
    try t.expectEqual(1, f.heard.count());
    try t.expectEqualStrings("turn on the kitchen light", f.heard.last[0..f.heard.last_len]);
    try t.expectEqualStrings("Kitchen", f.heard.room[0..f.heard.room_len]);
    // "bearer" in any case is the same scheme
    try t.expectEqual(200, (try f.send(.{ .auth = "bearer " ++ token, .body = say_kitchen })).status);
}

test "voice_agent_answers_two_routes_only" {
    var f: Fix = undefined;
    try f.init(.{ .listen = "127.0.0.1:0", .token = token, .answerer = undefined });
    defer f.deinit();
    const auth = "Bearer " ++ token;
    // the model list Home Assistant asks for at setup: one, harness
    const models = try f.send(.{ .method = "GET", .path = "/v1/models", .auth = auth });
    try t.expectEqual(200, models.status);
    try expectHas(models.head, "content-type: application/json");
    try expectHas(models.body, "\"object\":\"list\"");
    try expectHas(models.body, "\"id\":\"harness\"");
    // another method on them, anything else: refused, never answered
    try t.expectEqual(405, (try f.send(.{ .method = "POST", .path = "/v1/models", .auth = auth, .body = "{}" })).status);
    try t.expectEqual(405, (try f.send(.{ .method = "GET", .path = "/v1/chat/completions", .auth = auth })).status);
    for ([_][]const u8{ "/", "/v1/completions", "/v1/chat/completions/x", "/chat/completions", "/v1/models/../chat/completions", "/v1/embeddings" }) |path| {
        const got = try f.send(.{ .path = path, .auth = auth, .body = say_kitchen });
        if (got.status != 404) std.debug.print("{s}: {d}\n", .{ path, got.status });
        try t.expectEqual(404, got.status);
    }
    // a query string is the same route
    try t.expectEqual(200, (try f.send(.{ .path = "/v1/chat/completions?x=1", .auth = auth, .body = say_kitchen })).status);
    try t.expectEqual(1, f.heard.count());
}

test "voice_agent_caps_the_body" {
    var f: Fix = undefined;
    try f.init(.{ .listen = "127.0.0.1:0", .token = token, .answerer = undefined, .max_body = 4096 });
    defer f.deinit();
    const auth = "Bearer " ++ token;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(t.allocator);
    try big.appendSlice(t.allocator, "{\"messages\":[{\"role\":\"user\",\"content\":\"");
    for (0..5000) |_| try big.append(t.allocator, 'x');
    try big.appendSlice(t.allocator, "\"}]}");
    const got = try f.send(.{ .auth = auth, .body = big.items });
    try t.expectEqual(413, got.status);
    // what isn't a request of Home Assistant's: told plainly, never answered
    try t.expectEqual(400, (try f.send(.{ .auth = auth, .body = "turn on the light" })).status);
    try t.expectEqual(400, (try f.send(.{ .auth = auth, .body = "{\"messages\":[{\"role\":\"system\",\"content\":\"Room: Hall\"}]}" })).status);
    try t.expectEqual(0, f.heard.count());
}

test "voice_agent_streams_when_asked" {
    var f: Fix = undefined;
    try f.init(.{ .listen = "127.0.0.1:0", .token = token, .answerer = undefined });
    defer f.deinit();
    const auth = "Bearer " ++ token;
    f.heard.reply = "Light is on, \"30 %\".";
    // as one JSON answer
    const whole = try f.send(.{ .auth = auth, .body = say_kitchen });
    try t.expectEqual(200, whole.status);
    try expectHas(whole.head, "content-type: application/json");
    const v = try std.json.parseFromSlice(std.json.Value, t.allocator, whole.body, .{});
    defer v.deinit();
    try t.expectEqualStrings("chat.completion", v.value.object.get("object").?.string);
    const choice = v.value.object.get("choices").?.array.items[0].object;
    try t.expectEqualStrings("stop", choice.get("finish_reason").?.string);
    try t.expectEqualStrings("assistant", choice.get("message").?.object.get("role").?.string);
    try t.expectEqualStrings("Light is on, \"30 %\".", choice.get("message").?.object.get("content").?.string);
    // as server-sent events: the words, the stop, [DONE]
    const stream_body = "{\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}";
    const sse = try f.send(.{ .auth = auth, .body = stream_body });
    try t.expectEqual(200, sse.status);
    try expectHas(sse.head, "content-type: text/event-stream");
    var lines = std.mem.splitSequence(u8, sse.body, "\n\n");
    var events: std.ArrayList([]const u8) = .empty;
    defer events.deinit(t.allocator);
    while (lines.next()) |ev| if (ev.len > 0) try events.append(t.allocator, ev);
    try t.expectEqual(3, events.items.len);
    try t.expect(std.mem.startsWith(u8, events.items[0], "data: {"));
    const first = try std.json.parseFromSlice(std.json.Value, t.allocator, events.items[0]["data: ".len..], .{});
    defer first.deinit();
    try t.expectEqualStrings("chat.completion.chunk", first.value.object.get("object").?.string);
    const delta = first.value.object.get("choices").?.array.items[0].object.get("delta").?.object;
    try t.expectEqualStrings("assistant", delta.get("role").?.string);
    try t.expectEqualStrings("Light is on, \"30 %\".", delta.get("content").?.string);
    try expectHas(events.items[1], "\"finish_reason\":\"stop\"");
    try t.expectEqualStrings("data: [DONE]", events.items[2]);
}

test "voice_agent_binds_what_config_says" {
    var f: Fix = undefined;
    try f.init(.{ .listen = "127.0.0.1:0", .token = token, .answerer = undefined });
    defer f.deinit();
    // the address it listens on is the one named, nothing wider
    try t.expect(std.mem.startsWith(u8, f.s.address(), "127.0.0.1:"));
    // the port is its own while it runs
    var buf: [32]u8 = undefined;
    const taken = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{f.s.port});
    try t.expectError(error.AddressInUse, Server.start(t.allocator, t.io, .{ .listen = taken, .token = token, .answerer = f.heard.answerer() }));
    // every address at once, a name, a short token: never started
    for ([_][]const u8{ "0.0.0.0:0", "[::]:0", "localhost:0", "127.0.0.1" }) |listen|
        try t.expectError(error.BadAddress, Server.start(t.allocator, t.io, .{ .listen = listen, .token = token, .answerer = f.heard.answerer() }));
    try t.expectError(error.ShortToken, Server.start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .token = "short", .answerer = f.heard.answerer() }));
}

test "voice_agent_drops_a_slow_request" {
    var f: Fix = undefined;
    try f.init(.{ .listen = "127.0.0.1:0", .token = token, .answerer = undefined, .head_ms = 300 });
    defer f.deinit();
    const h = try sock.connect(t.io, "127.0.0.1", f.s.port, 2000);
    var rbuf: [1024]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    defer sk.close();
    // half a head, then nothing: the connection is closed within the limit
    try sk.writer.writeAll("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\n");
    try sk.writer.flush();
    const started = sock.nowNs(t.io);
    const got = sk.reader.allocRemaining(t.allocator, .limited(4096)) catch null;
    defer if (got) |g| t.allocator.free(g);
    const took_ms = @divFloor(sock.nowNs(t.io) - started, std.time.ns_per_ms);
    if (took_ms >= 3000) std.debug.print("a head of 300 ms was dropped after {d} ms\n", .{took_ms});
    try t.expect(took_ms < 3000);
    try t.expectEqual(0, f.heard.count());
}

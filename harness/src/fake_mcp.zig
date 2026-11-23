//! `harness-fake --mcp`: a small MCP server on stdio for the tests of
//! mcp.zig. Tools: `echo` (returns `text`; "env" returns FAKE_SECRET and
//! HOME; "file:NAME" the file NAME of its folder; "notify:URI" sends
//! notifications/resources/updated for URI first), `fail` (isError),
//! `sleep` (waits `ms` then answers "slept"). Resources: `fake://NAME` is
//! the file NAME of its folder; it takes subscriptions.
//! Before the tools/list reply it sends a notification and a `ping`
//! request, to prove the client skips the one and answers the other.
//!
//! `Http` below is the same server over HTTP (Streamable HTTP), part of
//! fake.zig's stand-in, for the tests of mcp_http.zig.
const std = @import("std");
const jv = @import("jv.zig");
const Io = std.Io;

const tools_json =
    \\{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},{"name":"fail","description":"Always fails.","inputSchema":{"type":"object","properties":{}}},{"name":"sleep","description":"Wait ms milliseconds.","inputSchema":{"type":"object","properties":{"ms":{"type":"integer"}},"required":["ms"]}}]}
;

pub fn run(io: Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) u8 {
    var buf: [1 << 16]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    var pinged = false;
    while (true) {
        const line = (r.interface.takeDelimiter('\n') catch return 1) orelse return 0;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const id = o.get("id");
        const method = if (o.get("method")) |m| (if (m == .string) m.string else "") else {
            // a response: ours to the ping is id "p1"
            if (id) |i| if (i == .string and std.mem.eql(u8, i.string, "p1") and o.get("result") != null) {
                pinged = true;
            };
            continue;
        };
        const idv = id orelse continue; // notifications need no answer
        const id_json = std.json.Stringify.valueAlloc(a, idv, .{}) catch return 1;
        var result: []const u8 = "{}";
        if (std.mem.eql(u8, method, "initialize")) {
            result = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{},\"resources\":{\"subscribe\":true}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}";
        } else if (std.mem.eql(u8, method, "tools/list")) {
            send(io, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"listing\"}}");
            send(io, "{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}");
            // a stray response with an id nobody asked for
            send(io, "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{\"tools\":[]}}");
            result = tools_json;
        } else if (std.mem.eql(u8, method, "tools/call")) {
            result = call(io, a, v, env, pinged) catch return 1;
        } else if (std.mem.eql(u8, method, "resources/read")) {
            result = resource(io, a, v) orelse {
                send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32002,\"message\":\"no such resource\"}}}}", .{id_json}) catch return 1);
                continue;
            };
        } else if (std.mem.eql(u8, method, "resources/subscribe")) {
            result = "{}";
        } else if (std.mem.eql(u8, method, "ping")) {
            result = "{}";
        } else {
            send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"no such method\"}}}}", .{id_json}) catch return 1);
            continue;
        }
        send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result }) catch return 1);
    }
}

/// A file of its folder (no slashes), as `resources/read` gives it.
fn fileOf(io: Io, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, "..")) return null;
    return Io.Dir.cwd().readFileAlloc(io, name, a, .limited(1 << 20)) catch null;
}

/// `resources/read` of `fake://NAME`: the file NAME of its folder.
fn resource(io: Io, a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    const params = v.object.get("params") orelse return null;
    if (params != .object) return null;
    const uv = params.object.get("uri") orelse return null;
    if (uv != .string or !std.mem.startsWith(u8, uv.string, "fake://")) return null;
    const text = fileOf(io, a, uv.string["fake://".len..]) orelse return null;
    const uri = std.json.Stringify.valueAlloc(a, uv.string, .{}) catch return null;
    const body = std.json.Stringify.valueAlloc(a, text, .{}) catch return null;
    return std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":{s},\"mimeType\":\"text/plain\",\"text\":{s}}}]}}", .{ uri, body }) catch null;
}

fn send(io: Io, line: []const u8) void {
    const out = Io.File.stdout();
    out.writeStreamingAll(io, line) catch {};
    out.writeStreamingAll(io, "\n") catch {};
}

fn textResult(a: std.mem.Allocator, text: []const u8, is_error: bool) ![]const u8 {
    const s = try std.json.Stringify.valueAlloc(a, text, .{});
    return std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{}}}", .{ s, is_error });
}

fn call(io: Io, a: std.mem.Allocator, v: std.json.Value, env: *const std.process.Environ.Map, pinged: bool) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const name = if (name_v == .string) name_v.string else "";
    const args: ?std.json.ObjectMap = if (params.object.get("arguments")) |x| (if (x == .object) x.object else null) else null;
    if (std.mem.eql(u8, name, "echo")) {
        const tv = if (args) |m| m.get("text") else null;
        const text = if (tv) |x| (if (x == .string) x.string else "") else "";
        if (std.mem.eql(u8, text, "env")) {
            const s = try std.fmt.allocPrint(a, "secret={s} home={s} user={s}", .{ env.get("FAKE_SECRET") orelse "", env.get("HOME") orelse "", env.get("USER") orelse "" });
            return textResult(a, s, false);
        }
        if (std.mem.eql(u8, text, "pinged")) return textResult(a, if (pinged) "yes" else "no", false);
        if (std.mem.startsWith(u8, text, "file:")) return textResult(a, fileOf(io, a, text["file:".len..]) orelse "no such file", false);
        if (std.mem.startsWith(u8, text, "notify:")) {
            const uri = try std.json.Stringify.valueAlloc(a, text["notify:".len..], .{});
            send(io, try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{{\"uri\":{s}}}}}", .{uri}));
            return textResult(a, "notified", false);
        }
        if (std.mem.eql(u8, text, "mixed")) return "{\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"image\",\"data\":\"AAAA\",\"mimeType\":\"image/png\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///x.txt\",\"text\":\"x\"}},{\"type\":\"text\",\"text\":\"two\"}]}";
        return textResult(a, text, false);
    }
    if (std.mem.eql(u8, name, "fail")) return textResult(a, "it failed", true);
    if (std.mem.eql(u8, name, "sleep")) {
        const mv = if (args) |m| m.get("ms") else null;
        const ms: i64 = if (mv) |x| (if (x == .integer) x.integer else 0) else 0;
        io.sleep(.fromMilliseconds(ms), .awake) catch {};
        return textResult(a, "slept", false);
    }
    return textResult(a, "unknown tool", true);
}

// ---- over HTTP ----

/// What a handler of `Http` gets from fake.zig's server.
pub const Ctx = struct {
    io: Io,
    /// The script folder: `mcp-token` (the token flavor's, else
    /// mcp-test-token-1), `mcp-files/NAME` (resource fake://NAME).
    dir: []const u8,
    port: u16,
    stopping: *const std.atomic.Value(bool),
};

pub const Header = struct { name: []const u8, value: []const u8 };

/// The MCP servers at `/mcp/FLAVOR`: `json` (answers are JSON), `sse`
/// (answers are event streams with a notification and a `ping` first),
/// `old` (MCP 2025-03-26), `future` (a version harness doesn't speak),
/// `token` (wants `Authorization: Bearer` with the token; a wrong one is
/// refused and said back), `nostream` (no GET stream: 405); others 404.
/// The same tools and resources as on stdio; `echo` "notify:URI" says URI
/// changed on the session's GET stream, "auth" says the Authorization it
/// got, "pinged" whether the session answered a ping. A session is
/// needed after initialize (none: 400; unknown or ended: 404) with the
/// version it started with; DELETE ends it. Tests steer it through the
/// methods below.
pub const Http = struct {
    /// Set by fake.zig's server when it starts.
    io: Io = undefined,
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,
    initializes: std.atomic.Value(u32) = .init(0),
    deleted: std.atomic.Value(u32) = .init(0),
    /// GET streams opened (200), and GETs refused (405).
    streams: std.atomic.Value(u32) = .init(0),
    refused_gets: std.atomic.Value(u32) = .init(0),
    /// Every request with a session is answered 404.
    end_always: std.atomic.Value(bool) = .init(false),
    /// Bumped: every open GET stream ends.
    drop_epoch: std.atomic.Value(u32) = .init(0),
    /// The next POSTs' failure (under `mutex`).
    fail: Fail = .{},

    const gpa = std.heap.page_allocator;

    pub const Fail = struct {
        status: u16 = 0,
        count: u32 = 1,
        retry_after: ?u32 = null,
        location: []const u8 = "",
        /// The message says the Authorization the request carried.
        echo_auth: bool = false,
    };

    const Session = struct {
        id_buf: [32]u8 = undefined,
        id_len: usize = 0,
        version: []const u8,
        ended: bool = false,
        pinged: bool = false,
        next_event: u32 = 0,
        /// Notifications for the GET stream (gpa).
        queue: std.ArrayList([]u8) = .empty,
        subscribed: std.ArrayList([]u8) = .empty,

        fn id(s: *const Session) []const u8 {
            return s.id_buf[0..s.id_len];
        }
    };

    pub fn deinit(h: *Http) void {
        for (h.sessions.items) |s| {
            for (s.queue.items) |q| gpa.free(q);
            s.queue.deinit(gpa);
            for (s.subscribed.items) |u| gpa.free(u);
            s.subscribed.deinit(gpa);
            gpa.destroy(s);
        }
        h.sessions.deinit(gpa);
    }

    /// The server forgets every session: the next request with one gets 404.
    pub fn endSessions(h: *Http) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.sessions.items) |s| s.ended = true;
    }

    /// Every open GET stream ends.
    pub fn dropStreams(h: *Http) void {
        _ = h.drop_epoch.fetchAdd(1, .acq_rel);
    }

    /// The next `f.count` POSTs answer `f.status`.
    pub fn failNext(h: *Http, f: Fail) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.fail = f;
    }

    /// How many sessions subscribed to `uri`.
    pub fn subscribedIn(h: *Http, uri: []const u8) u32 {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        var n: u32 = 0;
        for (h.sessions.items) |s| for (s.subscribed.items) |u| {
            if (std.mem.eql(u8, u, uri)) n += 1;
        };
        return n;
    }

    /// `/mcp/…` (and, for sign-ins, `/.well-known/…` and `/auth/…`).
    pub fn handle(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, method: std.http.Method, route: []const u8, hs: []const Header, body: []const u8) !void {
        if (!std.mem.startsWith(u8, route, "/mcp/")) return json(req, .not_found, "{}");
        const flavor = route["/mcp/".len..];
        const known = [_][]const u8{ "json", "sse", "old", "future", "token", "nostream" };
        for (known) |k| {
            if (std.mem.eql(u8, k, flavor)) break;
        } else return json(req, .not_found, "{\"error\":\"no such server\"}");
        if (std.mem.eql(u8, flavor, "token")) {
            const want = if (Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(a, &.{ c.dir, "mcp-token" }), a, .limited(4096))) |x| std.mem.trim(u8, x, " \r\n\t") else |_| "mcp-test-token-1";
            const got = header(hs, "authorization") orelse "";
            if (!std.mem.startsWith(u8, got, "Bearer ") or !std.mem.eql(u8, got["Bearer ".len..], want))
                return req.respond(try std.fmt.allocPrint(a, "{{\"error\":\"invalid_token\",\"error_description\":{f}}}", .{std.json.fmt(try std.fmt.allocPrint(a, "{s} is not a token here", .{got}), .{})}), .{ .status = .unauthorized, .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "www-authenticate", .value = "Bearer error=\"invalid_token\"" },
                } });
        }
        return switch (method) {
            .POST => h.post(c, a, req, flavor, hs, body),
            .GET => h.stream(c, a, req, flavor, hs),
            .DELETE => h.delete(c, req, hs),
            else => json(req, .method_not_allowed, "{}"),
        };
    }

    fn takeFail(h: *Http, io: Io) ?Fail {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        if (h.fail.status == 0 or h.fail.count == 0) return null;
        const f = h.fail;
        h.fail.count -= 1;
        if (h.fail.count == 0) h.fail = .{};
        return f;
    }

    /// The session a request names, if the server still has it.
    fn find(h: *Http, io: Io, hs: []const Header) ?*Session {
        const sid = header(hs, "mcp-session-id") orelse return null;
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        if (h.end_always.load(.acquire)) return null;
        for (h.sessions.items) |s| if (!s.ended and std.mem.eql(u8, s.id(), sid)) return s;
        return null;
    }

    fn post(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, flavor: []const u8, hs: []const Header, body: []const u8) !void {
        if (h.takeFail(c.io)) |f| {
            const msg = if (f.echo_auth) try std.fmt.allocPrint(a, "forbidden for {s}", .{header(hs, "authorization") orelse ""}) else "scripted failure";
            const out = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32000,\"message\":{f}}}}}", .{std.json.fmt(msg, .{})});
            var extra: [3]std.http.Header = undefined;
            var n: usize = 0;
            extra[n] = .{ .name = "content-type", .value = "application/json" };
            n += 1;
            var rb: [16]u8 = undefined;
            if (f.retry_after) |r| {
                extra[n] = .{ .name = "retry-after", .value = try std.fmt.bufPrint(&rb, "{d}", .{r}) };
                n += 1;
            }
            if (f.location.len > 0) {
                extra[n] = .{ .name = "location", .value = f.location };
                n += 1;
            }
            return req.respond(out, .{ .status = @enumFromInt(f.status), .extra_headers = extra[0..n] });
        }
        const v = jv.parse(a, body) orelse return json(req, .bad_request, "{\"error\":\"not JSON\"}");
        const method = jv.str(jv.get(v, "method"));
        const idv: ?std.json.Value = if (v == .object) v.object.get("id") else null;
        if (method != null and std.mem.eql(u8, method.?, "initialize")) {
            const version: []const u8 = if (std.mem.eql(u8, flavor, "old")) "2025-03-26" else if (std.mem.eql(u8, flavor, "future")) "2099-01-01" else "2025-06-18";
            const s = try gpa.create(Session);
            s.* = .{ .version = version };
            var raw: [8]u8 = undefined;
            c.io.random(&raw);
            const sid = try std.fmt.bufPrint(&s.id_buf, "s-{x}", .{raw});
            s.id_len = sid.len;
            {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                try h.sessions.append(gpa, s);
            }
            _ = h.initializes.fetchAdd(1, .acq_rel);
            const result = try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{\"subscribe\":true}}}},\"serverInfo\":{{\"name\":\"fake-http\",\"version\":\"1\"}}}}", .{version});
            return answer(req, a, flavor, try reply(a, idv, result), s.id());
        }
        if (header(hs, "mcp-session-id") == null) return json(req, .bad_request, "{\"error\":\"no session\"}");
        const s = h.find(c.io, hs) orelse return json(req, .not_found, "{\"error\":\"no such session\"}");
        if (!std.mem.eql(u8, header(hs, "mcp-protocol-version") orelse "", s.version)) return json(req, .bad_request, "{\"error\":\"MCP-Protocol-Version is not the session's\"}");
        if (method == null) {
            // a response: ours to the ping is "p1"
            if (idv) |i| if (i == .string and std.mem.eql(u8, i.string, "p1") and jv.get(v, "result") != null) {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                s.pinged = true;
            };
            return req.respond("", .{ .status = .accepted });
        }
        // a notification needs no answer
        if (idv == null) return req.respond("", .{ .status = .accepted });
        const m = method.?;
        if (std.mem.eql(u8, m, "tools/list")) return answer(req, a, flavor, try reply(a, idv, tools_json), null);
        if (std.mem.eql(u8, m, "ping")) return answer(req, a, flavor, try reply(a, idv, "{}"), null);
        if (std.mem.eql(u8, m, "resources/subscribe")) {
            const uri = jv.str(jv.at(v, &.{ "params", "uri" })) orelse "";
            {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                try s.subscribed.append(gpa, try gpa.dupe(u8, uri));
            }
            return answer(req, a, flavor, try reply(a, idv, "{}"), null);
        }
        if (std.mem.eql(u8, m, "resources/read")) {
            const uri = jv.str(jv.at(v, &.{ "params", "uri" })) orelse "";
            const name = if (std.mem.startsWith(u8, uri, "fake://")) uri["fake://".len..] else "";
            const text = if (name.len > 0 and std.mem.indexOfAny(u8, name, "/\\") == null and !std.mem.eql(u8, name, ".."))
                Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(a, &.{ c.dir, "mcp-files", name }), a, .limited(1 << 20)) catch null
            else
                null;
            const t = text orelse return answer(req, a, flavor, try errorReply(a, idv, -32002, "no such resource"), null);
            return answer(req, a, flavor, try reply(a, idv, try std.fmt.allocPrint(a, "{{\"contents\":[{{\"uri\":{f},\"mimeType\":\"text/plain\",\"text\":{f}}}]}}", .{ std.json.fmt(uri, .{}), std.json.fmt(t, .{}) })), null);
        }
        if (std.mem.eql(u8, m, "tools/call")) {
            const name = jv.str(jv.at(v, &.{ "params", "name" })) orelse "";
            const text = jv.str(jv.at(v, &.{ "params", "arguments", "text" })) orelse "";
            if (std.mem.eql(u8, name, "echo") and std.mem.startsWith(u8, text, "notify:")) {
                const note = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{{\"uri\":{f}}}}}", .{std.json.fmt(text["notify:".len..], .{})});
                h.mutex.lockUncancelable(c.io);
                s.queue.append(gpa, note) catch gpa.free(note);
                h.mutex.unlock(c.io);
                return answer(req, a, flavor, try reply(a, idv, try textResult(a, "notified", false)), null);
            }
            if (std.mem.eql(u8, name, "echo") and std.mem.eql(u8, text, "auth")) return answer(req, a, flavor, try reply(a, idv, try textResult(a, header(hs, "authorization") orelse "none", false)), null);
            if (std.mem.eql(u8, name, "sleep")) {
                // by the clock, and ended by the stand-in's stop
                const ms = jv.int(jv.at(v, &.{ "params", "arguments", "ms" })) orelse 0;
                const until = Io.Clock.awake.now(c.io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
                while (Io.Clock.awake.now(c.io).nanoseconds < until and !c.stopping.load(.acquire)) c.io.sleep(.fromMilliseconds(20), .awake) catch {};
                return answer(req, a, flavor, try reply(a, idv, try textResult(a, "slept", false)), null);
            }
            const pinged = blk: {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                break :blk s.pinged;
            };
            var env = std.process.Environ.Map.init(a);
            const result = try call(c.io, a, v, &env, pinged);
            return answer(req, a, flavor, try reply(a, idv, result), null);
        }
        return answer(req, a, flavor, try errorReply(a, idv, -32601, "no such method"), null);
    }

    /// The GET stream of a session: what `notify:` queued, as it comes.
    fn stream(h: *Http, c: Ctx, a: std.mem.Allocator, req: *std.http.Server.Request, flavor: []const u8, hs: []const Header) !void {
        _ = a;
        if (std.mem.eql(u8, flavor, "nostream")) {
            _ = h.refused_gets.fetchAdd(1, .acq_rel);
            return json(req, .method_not_allowed, "{}");
        }
        const s = h.find(c.io, hs) orelse return json(req, .not_found, "{\"error\":\"no such session\"}");
        if (std.mem.indexOf(u8, header(hs, "accept") orelse "", "text/event-stream") == null) return json(req, .not_acceptable, "{}");
        const epoch = h.drop_epoch.load(.acquire);
        var buf: [4096]u8 = undefined;
        var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} } });
        try bw.writer.writeAll(": stream open\n\n");
        try bw.writer.flush();
        try bw.flush();
        _ = h.streams.fetchAdd(1, .acq_rel);
        while (!c.stopping.load(.acquire) and h.drop_epoch.load(.acquire) == epoch) {
            const item: ?[]u8, const n: u32, const ended = blk: {
                h.mutex.lockUncancelable(c.io);
                defer h.mutex.unlock(c.io);
                if (s.ended or h.end_always.load(.acquire)) break :blk .{ null, 0, true };
                if (s.queue.items.len == 0) break :blk .{ null, 0, false };
                s.next_event += 1;
                break :blk .{ s.queue.orderedRemove(0), s.next_event, false };
            };
            if (ended) break;
            if (item) |x| {
                defer gpa.free(x);
                try bw.writer.print("id: {d}\ndata: {s}\n\n", .{ n, x });
                try bw.writer.flush();
                try bw.flush();
                continue;
            }
            c.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        bw.end() catch {};
    }

    fn delete(h: *Http, c: Ctx, req: *std.http.Server.Request, hs: []const Header) !void {
        const s = h.find(c.io, hs) orelse return json(req, .not_found, "{}");
        {
            h.mutex.lockUncancelable(c.io);
            defer h.mutex.unlock(c.io);
            s.ended = true;
        }
        _ = h.deleted.fetchAdd(1, .acq_rel);
        return json(req, .ok, "{}");
    }
};

/// A header's value (the first of that name, any case).
pub fn header(hs: []const Header, name: []const u8) ?[]const u8 {
    for (hs) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
    return null;
}

fn reply(a: std.mem.Allocator, idv: ?std.json.Value, result: []const u8) ![]const u8 {
    const id_json = if (idv) |i| try std.json.Stringify.valueAlloc(a, i, .{}) else "null";
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result });
}

fn errorReply(a: std.mem.Allocator, idv: ?std.json.Value, code: i32, msg: []const u8) ![]const u8 {
    const id_json = if (idv) |i| try std.json.Stringify.valueAlloc(a, i, .{}) else "null";
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{ id_json, code, std.json.fmt(msg, .{}) });
}

/// A response as JSON, or (flavor sse) as an event stream: a notification
/// and a ping of the server's own first, the response in two data lines.
fn answer(req: *std.http.Server.Request, a: std.mem.Allocator, flavor: []const u8, msg: []const u8, session: ?[]const u8) !void {
    _ = a;
    var extra: [2]std.http.Header = undefined;
    var n: usize = 0;
    if (session) |sid| {
        extra[n] = .{ .name = "mcp-session-id", .value = sid };
        n += 1;
    }
    if (!std.mem.eql(u8, flavor, "sse")) {
        extra[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
        return req.respond(msg, .{ .extra_headers = extra[0..n] });
    }
    extra[n] = .{ .name = "content-type", .value = "text/event-stream" };
    n += 1;
    var buf: [4096]u8 = undefined;
    var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .extra_headers = extra[0..n] } });
    try bw.writer.writeAll("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"working\"}}\n\n");
    try bw.writer.writeAll("data: {\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}\n\n");
    try bw.writer.flush();
    try bw.flush();
    try bw.writer.print("id: 1\ndata: {{\ndata: {s}\n\n", .{msg[1..]});
    try bw.end();
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

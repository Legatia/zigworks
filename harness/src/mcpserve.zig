//! MCP for other agents, served: the proxy (README: MCP, "For other
//! agents"). One route, `POST /mcp`, on this machine's own address: one
//! JSON-RPC message a request, answered as JSON (Streamable HTTP without
//! sessions or streams). Every request carries a client's bearer token
//! (compared as SHA-256 digests, in constant time, before a body is kept);
//! the token says which `[client NAME]` is asking. What the client may see
//! and whether a call is made is the backend's to say (the core: the gate,
//! the owner's approval); this file is the protocol and the door.
const std = @import("std");
const Io = std.Io;
const sock = @import("sock.zig");
const log_mod = @import("log.zig");
const config = @import("config.zig");
const mcp_http = @import("mcp_http.zig");

/// The shortest token taken.
pub const min_token = 32;

/// A client and the token that names it.
pub const ClientToken = struct { name: []const u8, token: []const u8 };

/// What a listing came to: the tools as a JSON array's text, or `busy`
/// (the servers are restarting: ask again).
pub const Listed = union(enum) { tools: []const u8, busy };

pub const Result = struct { text: []const u8, is_error: bool };

/// What a call came to: the tool's answer (a refusal by the gate is one,
/// with `is_error`), `unknown` (no such tool for this client) or `busy`.
pub const Called = union(enum) { result: Result, unknown, busy };

/// Who answers for the tools: the core.
pub const Backend = struct {
    ctx: *anyopaque,
    /// On the request's thread; the text in `a`.
    list: *const fn (ctx: *anyopaque, a: std.mem.Allocator, client: []const u8, gone: *std.atomic.Value(bool)) Listed,
    /// On the request's thread; `args_json` is a JSON object's text.
    /// `gone` is the call's stop flag: set when the client hung up or
    /// cancelled, or the server stops (the backend may set it too, as the
    /// owner's /stop does). A call that waits ends soon after.
    call: *const fn (ctx: *anyopaque, a: std.mem.Allocator, client: []const u8, name: []const u8, args_json: []const u8, gone: *std.atomic.Value(bool)) Called,
};

pub const Options = struct {
    /// `[proxy] listen` (config.parseLoopback's rules; port 0: a free one,
    /// for the tests).
    listen: []const u8,
    /// The clients served; only each token's SHA-256 is kept.
    clients: []const ClientToken,
    backend: Backend,
    log: ?*log_mod.Log = null,
    /// A request's body past this is refused.
    max_body: usize = 1 << 20,
    /// A request's head, and then its body, must come within this.
    head_ms: u32 = 10_000,
    /// A kept connection waits this long for its next request.
    idle_ms: u32 = 60_000,
    /// Connections at once; more are closed as they come.
    max_connections: u32 = 32,
    /// Calls of one client going at once; one more is answered at once.
    calls_per_client: u32 = 4,
};

/// A request as an MCP client sends it.
pub const Request = struct {
    method: []const u8 = "POST",
    path: []const u8 = "/mcp",
    /// The Authorization header's value; null: none.
    auth: ?[]const u8 = null,
    body: []const u8 = "",
    origin: ?[]const u8 = null,
    /// The MCP-Protocol-Version header's value.
    version: ?[]const u8 = null,
};

pub const Reply = struct { status: u16, head: []const u8, body: []const u8 };

/// One request on a connection of its own; the reply in `a`. For the tests.
pub fn request(io: Io, a: std.mem.Allocator, host: []const u8, port: u16, r: Request) !Reply {
    const h = try sock.connect(io, host, port, 2000);
    const rbuf = try a.alloc(u8, 64 * 1024);
    var wbuf: [4096]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(io, h, rbuf, &wbuf, 90_000);
    defer sk.close();
    try writeRequest(&sk, host, port, r, true);
    const all = try sk.reader.allocRemaining(a, .limited(4 << 20));
    const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadResponse;
    if (all.len < 12) return error.BadResponse;
    return .{ .status = try std.fmt.parseInt(u16, all[9..12], 10), .head = all[0..split], .body = all[split + 4 ..] };
}

fn writeRequest(sk: *sock.Socket, host: []const u8, port: u16, r: Request, close: bool) !void {
    try sk.writer.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {d}\r\n", .{ r.method, r.path, host, port, r.body.len });
    if (r.auth) |x| try sk.writer.print("Authorization: {s}\r\n", .{x});
    if (r.origin) |x| try sk.writer.print("Origin: {s}\r\n", .{x});
    if (r.version) |x| try sk.writer.print("MCP-Protocol-Version: {s}\r\n", .{x});
    try sk.writer.writeAll(if (close) "Connection: close\r\n\r\n" else "\r\n");
    try sk.writer.writeAll(r.body);
    try sk.writer.flush();
}

/// JSON nested deeper than this is refused before it is parsed.
const max_depth = 64;

const reloading = "harness is reloading its servers; ask again in a moment";

const instructions =
    "Tools of the owner's MCP servers, through harness. Every call passes harness's gate first; " ++
    "one the gate asks about waits for the owner's approval, which can take minutes (allow a long timeout). " ++
    "A call that was not made comes back as the tool's result with isError and a text starting " ++
    "\"refused by the gate\": the same call sent again is decided again, and may ask the owner again.";

const Refusal = enum { origin, token, route, method, version, size, message };

/// A request with a backend's answer still to come.
const Going = struct {
    client: usize,
    /// The request's id as JSON text.
    id: []const u8,
    conn: sock.Handle,
    gone: *std.atomic.Value(bool),
};

const Answer = struct { status: std.http.Status = .ok, body: []const u8 = "", why: Refusal = .message };

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    listener: sock.Listener,
    port: u16,
    addr_buf: [64]u8 = undefined,
    addr_len: usize = 0,
    wake_host: [48]u8 = undefined,
    wake_len: usize = 0,
    backend: Backend,
    log: ?*log_mod.Log,
    max_body: usize,
    head_ms: u32,
    idle_ms: u32,
    max_connections: u32,
    calls_per_client: u32,
    n: usize = 0,
    names: [config.max_clients][32]u8 = undefined,
    name_lens: [config.max_clients]u8 = undefined,
    digests: [config.max_clients][32]u8 = undefined,
    /// Calls going, by client.
    calls: [config.max_clients]std.atomic.Value(u32) = @splat(.init(0)),
    thread: ?std.Thread = null,
    watcher: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    /// Guards `going`, `watch_end` and `last_refusal_ms`.
    mutex: Io.Mutex = .init,
    /// Signalled when `going` gets its first entry, and at the end.
    wake: Io.Condition = .init,
    watch_end: bool = false,
    /// Room for one entry a connection, reserved at the start.
    going: std.ArrayList(Going) = .empty,
    last_refusal_ms: [std.enums.values(Refusal).len]i64 = @splat(-std.math.maxInt(i32)),

    /// Listens on `o.listen` and serves `o.clients`. Errors: `BadAddress`
    /// (not this machine's own address with a port), `NoClients`,
    /// `TooManyClients`, `BadName`, `SameName`, `ShortToken`, `SameToken`,
    /// and the listener's (`AddressInUse`).
    pub fn start(gpa: std.mem.Allocator, io: Io, o: Options) !*Server {
        var ip = config.parseLoopback(o.listen) orelse return error.BadAddress;
        if (o.clients.len == 0) return error.NoClients;
        if (o.clients.len > config.max_clients) return error.TooManyClients;
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .listener = undefined,
            .port = 0,
            .backend = o.backend,
            .log = o.log,
            .max_body = o.max_body,
            .head_ms = o.head_ms,
            .idle_ms = o.idle_ms,
            .max_connections = o.max_connections,
            .calls_per_client = o.calls_per_client,
            .n = o.clients.len,
        };
        for (o.clients, 0..) |c, i| {
            if (!config.validClientName(c.name)) return error.BadName;
            if (c.token.len < min_token) return error.ShortToken;
            @memcpy(s.names[i][0..c.name.len], c.name);
            s.name_lens[i] = @intCast(c.name.len);
            std.crypto.hash.sha2.Sha256.hash(c.token, &s.digests[i], .{});
            for (0..i) |j| {
                if (std.mem.eql(u8, s.name(j), c.name)) return error.SameName;
                if (std.mem.eql(u8, &s.digests[j], &s.digests[i])) return error.SameToken;
            }
        }
        try s.going.ensureTotalCapacity(gpa, o.max_connections);
        errdefer s.going.deinit(gpa);
        s.listener = try sock.Listener.openOn(ip);
        errdefer s.listener.close();
        s.port = s.listener.port;
        switch (ip) {
            .ip4 => |*x| x.port = s.port,
            .ip6 => |*x| x.port = s.port,
        }
        s.addr_len = (std.fmt.bufPrint(&s.addr_buf, "{f}", .{ip}) catch return error.BadAddress).len;
        const host = s.addr_buf[0 .. std.mem.lastIndexOfScalar(u8, s.addr_buf[0..s.addr_len], ':') orelse 0];
        const bare = std.mem.trim(u8, host, "[]");
        @memcpy(s.wake_host[0..bare.len], bare);
        s.wake_len = bare.len;
        s.watcher = try std.Thread.spawn(.{}, watch, .{s});
        errdefer s.endWatcher();
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        if (s.log) |l| {
            var buf: [config.max_clients * 34]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            for (0..s.n) |i| w.print("{s}{s}", .{ if (i == 0) "" else ", ", s.name(i) }) catch {};
            l.write(.config, false, .{ .event = "proxy listening", .address = s.address(), .clients = w.buffered() }) catch {};
        }
        return s;
    }

    /// Where it listens.
    pub fn address(s: *const Server) []const u8 {
        return s.addr_buf[0..s.addr_len];
    }

    fn name(s: *const Server, i: usize) []const u8 {
        return s.names[i][0..s.name_lens[i]];
    }

    /// Stops listening and ends what is going: a request that waits for
    /// its head or body ends at once (its socket's stop flag); a call that
    /// waits has its `gone` set, and its answer (the backend's, usually
    /// the gate's "its run stopped") is still written.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        if (sock.connect(s.io, s.wake_host[0..s.wake_len], s.port, 1000)) |c| sock.closeHandle(c) else |_| {}
        if (s.thread) |th| th.join();
        var waited: u32 = 0;
        while (s.active.load(.acquire) > 0 and waited < 60_000) : (waited += 5) s.io.sleep(.fromMilliseconds(5), .awake) catch {};
        s.endWatcher();
        s.listener.close();
        if (s.log) |l| l.write(.config, false, .{ .event = "proxy stopped", .address = s.address() }) catch {};
        // a request still going owns its memory: let it go first
        if (s.active.load(.acquire) > 0) return;
        s.going.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn endWatcher(s: *Server) void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            s.watch_end = true;
        }
        s.wake.signal(s.io);
        if (s.watcher) |th| th.join();
        s.watcher = null;
    }

    /// Sets `gone` of the requests going whose client hung up, and of all
    /// of them at a stop. Asleep while nothing goes.
    fn watch(s: *Server) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        while (!s.watch_end) {
            if (s.going.items.len == 0) {
                s.wake.waitUncancelable(s.io, &s.mutex);
                continue;
            }
            const stopping = s.stopping.load(.acquire);
            for (s.going.items) |g| if (stopping or sock.ended(g.conn)) g.gone.store(true, .release);
            s.mutex.unlock(s.io);
            s.io.sleep(.fromMilliseconds(50), .awake) catch {};
            s.mutex.lockUncancelable(s.io);
        }
    }

    fn enter(s: *Server, client: usize, id: []const u8, conn: sock.Handle, gone: *std.atomic.Value(bool)) void {
        if (s.stopping.load(.acquire)) gone.store(true, .release);
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            // (one a connection, and never more connections than reserved)
            if (s.going.items.len < s.going.capacity) s.going.appendAssumeCapacity(.{ .client = client, .id = id, .conn = conn, .gone = gone });
        }
        s.wake.signal(s.io);
    }

    fn leave(s: *Server, gone: *std.atomic.Value(bool)) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.going.items, 0..) |g, i| if (g.gone == gone) {
            _ = s.going.swapRemove(i);
            return;
        };
    }

    /// `notifications/cancelled`: the client's own request with that id.
    fn cancel(s: *Server, client: usize, id: []const u8) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.going.items) |g| if (g.client == client and std.mem.eql(u8, g.id, id)) g.gone.store(true, .release);
    }

    fn acceptLoop(s: *Server) void {
        while (!s.stopping.load(.acquire)) {
            // a poll, so a stop is seen even when no connection wakes it
            const got = s.listener.acceptWithin(s.io, 500, &s.stopping) catch {
                s.io.sleep(.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            const conn = got orelse continue;
            if (s.stopping.load(.acquire)) {
                sock.closeHandle(conn);
                return;
            }
            if (s.active.load(.acquire) >= s.max_connections) {
                sock.closeHandle(conn);
                continue;
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
            const keep = s.handle(arena_state.allocator(), &req, &sk, conn) catch return;
            if (!keep) return;
        }
    }

    fn handle(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, sk: *sock.Socket, conn: sock.Handle) !bool {
        var auth: ?[]const u8 = null;
        var foreign = false;
        var other_version = false;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            const v = std.mem.trim(u8, h.value, " \t");
            if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
                if (!s.ownOrigin(v)) foreign = true;
            } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                if (auth == null) auth = v;
            } else if (std.ascii.eqlIgnoreCase(h.name, "mcp-protocol-version")) {
                for (mcp_http.versions) |known| {
                    if (std.mem.eql(u8, v, known)) break;
                } else other_version = true;
            }
        }
        // a page in a browser says where it is from; no page is the proxy's
        if (foreign) return s.refuse(req, .origin, .forbidden, "a request from a web page (its Origin is not the proxy's own address)");
        // the token, before anything else of the request is looked at
        const client = s.clientOf(auth) orelse return s.refuse(req, .token, .unauthorized, "a client's token is needed: Authorization: Bearer TOKEN");
        const target = req.head.target;
        if (!std.mem.eql(u8, target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len], "/mcp"))
            return s.refuse(req, .route, .not_found, "harness serves MCP at POST /mcp only");
        // no stream to open (GET) and no session to end (DELETE)
        if (req.head.method != .POST) return s.refuse(req, .method, .method_not_allowed, "MCP here is POST /mcp: one message a request, answered as JSON");
        if (req.head.content_length) |n| if (n > s.max_body) return s.refuse(req, .size, .payload_too_large, "the message is over the proxy's limit");
        var body_buf: [8192]u8 = undefined;
        const r = req.readerExpectContinue(&body_buf) catch return false;
        const body = r.allocRemaining(a, .limited(s.max_body)) catch |e| switch (e) {
            error.StreamTooLong => {
                // a body with no length (chunked): the rest is read off
                // through the reader already open, a second one can't be
                _ = r.discardShort(4 << 20) catch {};
                return s.turnAway(req, .size, .payload_too_large, "the message is over the proxy's limit");
            },
            else => return false,
        };
        const answer = try s.message(a, client, conn, body, other_version);
        if (answer.status == .bad_request) s.noteRefusal(answer.why, .bad_request);
        // the answer may have waited for the owner: its writing gets its
        // own time, and a stop meanwhile doesn't cut it
        sk.setLimits(10_000, 10_000, null);
        const keep = req.head.keep_alive;
        try req.respond(answer.body, .{ .status = answer.status, .keep_alive = keep, .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
        return keep;
    }

    fn ownOrigin(s: *const Server, origin: []const u8) bool {
        var buf: [64]u8 = undefined;
        for ([_][]const u8{ "127.0.0.1", "localhost", "[::1]" }) |host| {
            const own = std.fmt.bufPrint(&buf, "http://{s}:{d}", .{ host, s.port }) catch return false;
            if (std.ascii.eqlIgnoreCase(origin, own)) return true;
        }
        return false;
    }

    /// The client whose token `Authorization: Bearer TOKEN` carries: the
    /// SHA-256 digests compared, each in time that doesn't depend on where
    /// they differ, and all of them every time.
    fn clientOf(s: *const Server, auth: ?[]const u8) ?usize {
        const v = auth orelse return null;
        if (v.len < 7 or !std.ascii.eqlIgnoreCase(v[0..7], "bearer ")) return null;
        var got: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(std.mem.trim(u8, v[7..], " \t"), &got, .{});
        var found: ?usize = null;
        for (s.digests[0..s.n], 0..) |d, i| {
            if (std.crypto.timing_safe.eql([32]u8, got, d)) found = i;
        }
        return found;
    }

    /// One line a minute for each kind of refusal, without what came in.
    fn noteRefusal(s: *Server, why: Refusal, status: std.http.Status) void {
        const now = Io.Clock.awake.now(s.io).toMilliseconds();
        const i = @intFromEnum(why);
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            if (now - s.last_refusal_ms[i] < 60 * 1000) return;
            s.last_refusal_ms[i] = @intCast(now);
        }
        if (s.log) |l| l.write(.config, false, .{ .event = "proxy refused", .why = @tagName(why), .status = @intFromEnum(status) }) catch {};
    }

    /// A request turned away at the door; the connection ends with it.
    fn refuse(s: *Server, req: *std.http.Server.Request, why: Refusal, status: std.http.Status, comptime message_text: []const u8) !bool {
        // what it sent is read off first, unkept (up to 4 MiB, within the
        // head's time): closed with its body unread, the connection is
        // reset and the answer lost
        if (req.head.expect == null and (req.head.content_length orelse 0) <= 4 << 20) {
            var drain_buf: [8192]u8 = undefined;
            if (req.readerExpectContinue(&drain_buf)) |r| {
                _ = r.discardRemaining() catch {};
            } else |_| {}
        }
        return s.turnAway(req, why, status, message_text);
    }

    /// `refuse`'s answer, for a request whose body was already read at.
    fn turnAway(s: *Server, req: *std.http.Server.Request, why: Refusal, status: std.http.Status, comptime message_text: []const u8) !bool {
        s.noteRefusal(why, status);
        const body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"" ++ message_text ++ "\"}}";
        const base = [_]std.http.Header{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } };
        const extra: []const std.http.Header = switch (why) {
            .token => &(base ++ [_]std.http.Header{.{ .name = "www-authenticate", .value = "Bearer" }}),
            .method => &(base ++ [_]std.http.Header{.{ .name = "allow", .value = "POST" }}),
            else => &base,
        };
        try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = extra });
        return false;
    }

    /// One JSON-RPC message of `client`, answered.
    /// `other_version`: its MCP-Protocol-Version header names a version
    /// harness doesn't speak.
    fn message(s: *Server, a: std.mem.Allocator, client: usize, conn: sock.Handle, body: []const u8, other_version: bool) !Answer {
        if (tooDeep(body)) return fail(a, .bad_request, "null", -32600, "the message is nested deeper than 64 levels");
        const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return fail(a, .bad_request, "null", -32700, "not a JSON message"),
        };
        if (root != .object) return fail(a, .bad_request, "null", -32600, "one JSON-RPC message a request: an object, no batch");
        const o = root.object;
        // without a method: a response to something harness never asked
        const method_v = o.get("method") orelse return .{ .status = .accepted };
        if (method_v != .string) return fail(a, .bad_request, "null", -32600, "method is not a string");
        const method = method_v.string;
        const params_v: std.json.Value = o.get("params") orelse .null;
        const id_v = o.get("id") orelse {
            // a notification: nothing to answer
            if (std.mem.eql(u8, method, "notifications/cancelled") and params_v == .object) {
                if (params_v.object.get("requestId")) |rid| if (try idText(a, rid)) |text| s.cancel(client, text);
            }
            return .{ .status = .accepted };
        };
        const id = (try idText(a, id_v)) orelse return fail(a, .bad_request, "null", -32600, "id is not a string or a whole number");

        // initialize is where the version is agreed, in its body: a client
        // may send its own newest as the header there (the MCP Python SDK
        // does). Any other request under a version harness doesn't speak
        // is refused.
        if (other_version and !std.mem.eql(u8, method, "initialize")) {
            var refused = try fail(a, .bad_request, "null", -32000, "MCP-Protocol-Version is not one harness speaks (2025-06-18, 2025-03-26)");
            refused.why = .version;
            return refused;
        }
        if (std.mem.eql(u8, method, "ping")) return ok(a, id, "{}");
        if (std.mem.eql(u8, method, "initialize")) {
            var version: []const u8 = mcp_http.versions[0];
            if (params_v == .object) if (params_v.object.get("protocolVersion")) |pv| if (pv == .string) {
                for (mcp_http.versions) |known| if (std.mem.eql(u8, pv.string, known)) {
                    version = known;
                };
            };
            return ok(a, id, try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"harness\",\"version\":{s}}},\"instructions\":{s}}}", .{ version, try jsonString(a, @import("build_options").version), try jsonString(a, instructions) }));
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            var gone: std.atomic.Value(bool) = .init(false);
            s.enter(client, id, conn, &gone);
            const got = s.backend.list(s.backend.ctx, a, s.name(client), &gone);
            s.leave(&gone);
            return switch (got) {
                .tools => |tools| ok(a, id, try std.fmt.allocPrint(a, "{{\"tools\":{s}}}", .{tools})),
                .busy => fail(a, .ok, id, -32000, reloading),
            };
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            if (params_v != .object) return fail(a, .ok, id, -32602, "tools/call needs params: name and arguments");
            const name_v: std.json.Value = params_v.object.get("name") orelse .null;
            if (name_v != .string) return fail(a, .ok, id, -32602, "tools/call needs the tool's name");
            const args_v: std.json.Value = params_v.object.get("arguments") orelse .null;
            const args = switch (args_v) {
                .null => "{}",
                .object => try std.json.Stringify.valueAlloc(a, args_v, .{}),
                else => return fail(a, .ok, id, -32602, "arguments is not an object"),
            };
            // one more than a client may have going: said at once, as the
            // tool's answer (the model reads it and waits)
            if (s.calls[client].fetchAdd(1, .acq_rel) >= s.calls_per_client) {
                _ = s.calls[client].fetchSub(1, .acq_rel);
                return result(a, id, try std.fmt.allocPrint(a, "{d} calls of this client are going already; ask again when one has ended", .{s.calls_per_client}), true);
            }
            var gone: std.atomic.Value(bool) = .init(false);
            s.enter(client, id, conn, &gone);
            const got = s.backend.call(s.backend.ctx, a, s.name(client), name_v.string, args, &gone);
            // off the books before the answer is on its way: the client's
            // next call may come the moment it has it
            s.leave(&gone);
            _ = s.calls[client].fetchSub(1, .acq_rel);
            return switch (got) {
                .result => |res| result(a, id, res.text, res.is_error),
                .unknown => fail(a, .ok, id, -32602, if (name_v.string.len <= 128) try std.fmt.allocPrint(a, "no tool {s} for this client (tools/list has them)", .{name_v.string}) else "no such tool for this client (tools/list has them)"),
                .busy => fail(a, .ok, id, -32000, reloading),
            };
        }
        return fail(a, .ok, id, -32601, "harness's proxy has initialize, ping, tools/list and tools/call");
    }
};

/// A request's id as JSON text; null: not one (ids are strings and whole
/// numbers).
fn idText(a: std.mem.Allocator, v: std.json.Value) !?[]const u8 {
    return switch (v) {
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .string => |text| try jsonString(a, text),
        else => null,
    };
}

fn ok(a: std.mem.Allocator, id: []const u8, result_json: []const u8) !Answer {
    return .{ .body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result_json }) };
}

fn result(a: std.mem.Allocator, id: []const u8, text: []const u8, is_error: bool) !Answer {
    return ok(a, id, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{}}}", .{ try jsonString(a, text), is_error }));
}

fn fail(a: std.mem.Allocator, status: std.http.Status, id: []const u8, code: i32, message_text: []const u8) !Answer {
    return .{ .status = status, .body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ id, code, try jsonString(a, message_text) }) };
}

/// `text` as a JSON string, quotes and all.
fn jsonString(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, text, .{});
}

/// Whether `body` opens more than `max_depth` arrays and objects inside
/// one another (brackets in strings are text).
fn tooDeep(body: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (in_string) {
            if (ch == '\\') i += 1 else if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max_depth) return true;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return false;
}

const t = std.testing;

const tok_a = "token-of-client-a-0123456789abcdef";
const tok_b = "token-of-client-b-0123456789abcdef";
const two = [_]ClientToken{ .{ .name = "a", .token = tok_a }, .{ .name = "b", .token = tok_b } };
const list_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
const call_body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"notes__add\",\"arguments\":{\"text\":\"milk \\\"2 %\\\"\"}}}";

/// The test backend: what it was asked, and what it says.
const Rec = struct {
    mutex: Io.Mutex = .init,
    lists: u32 = 0,
    calls: u32 = 0,
    client: [32]u8 = undefined,
    client_len: usize = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    args: [256]u8 = undefined,
    args_len: usize = 0,
    tools: []const u8 = "[{\"name\":\"notes__add\",\"description\":\"Add a note\",\"inputSchema\":{\"type\":\"object\"}}]",
    listed_busy: bool = false,
    reply: Called = .{ .result = .{ .text = "added \"milk\"", .is_error = false } },
    mode: enum { answer, wait_gone, hold_first } = .answer,
    entered: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    saw_gone: std.atomic.Value(bool) = .init(false),
    gone_at_entry: std.atomic.Value(bool) = .init(false),

    fn backend(r: *Rec) Backend {
        return .{ .ctx = r, .list = list, .call = call };
    }

    fn list(ctx: *anyopaque, a: std.mem.Allocator, client: []const u8, gone: *std.atomic.Value(bool)) Listed {
        _ = a;
        _ = gone;
        const r: *Rec = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        r.lists += 1;
        r.client_len = @min(client.len, r.client.len);
        @memcpy(r.client[0..r.client_len], client[0..r.client_len]);
        return if (r.listed_busy) .busy else .{ .tools = r.tools };
    }

    fn call(ctx: *anyopaque, a: std.mem.Allocator, client: []const u8, name: []const u8, args_json: []const u8, gone: *std.atomic.Value(bool)) Called {
        _ = a;
        const r: *Rec = @ptrCast(@alignCast(ctx));
        {
            r.mutex.lockUncancelable(t.io);
            defer r.mutex.unlock(t.io);
            r.calls += 1;
            r.client_len = @min(client.len, r.client.len);
            @memcpy(r.client[0..r.client_len], client[0..r.client_len]);
            r.name_len = @min(name.len, r.name.len);
            @memcpy(r.name[0..r.name_len], name[0..r.name_len]);
            r.args_len = @min(args_json.len, r.args.len);
            @memcpy(r.args[0..r.args_len], args_json[0..r.args_len]);
        }
        if (gone.load(.acquire)) r.gone_at_entry.store(true, .release);
        const n = r.entered.fetchAdd(1, .acq_rel) + 1;
        switch (r.mode) {
            .answer => {},
            .wait_gone => {
                var waited: u32 = 0;
                while (!gone.load(.acquire) and waited < 5000) : (waited += 10) t.io.sleep(.fromMilliseconds(10), .awake) catch {};
                r.saw_gone.store(gone.load(.acquire), .release);
                return .{ .result = .{ .text = "refused by the gate: its run stopped", .is_error = true } };
            },
            .hold_first => if (n == 1) {
                var waited: u32 = 0;
                while (!r.release.load(.acquire) and !gone.load(.acquire) and waited < 5000) : (waited += 10) t.io.sleep(.fromMilliseconds(10), .awake) catch {};
            },
        }
        return r.reply;
    }

    fn counts(r: *Rec) [2]u32 {
        r.mutex.lockUncancelable(t.io);
        defer r.mutex.unlock(t.io);
        return .{ r.lists, r.calls };
    }

    fn waitEntered(r: *Rec, n: u32) !void {
        var waited: u32 = 0;
        while (r.entered.load(.acquire) < n) : (waited += 10) {
            if (waited >= 5000) return error.BackendNotReached;
            t.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
};

const Fix = struct {
    rec: Rec = .{},
    s: *Server = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(f: *Fix, o: Options) !void {
        f.* = .{};
        f.arena = .init(t.allocator);
        var opts = o;
        opts.backend = f.rec.backend();
        f.s = try Server.start(t.allocator, t.io, opts);
    }

    fn deinit(f: *Fix) void {
        f.s.stop();
        f.arena.deinit();
    }

    fn send(f: *Fix, r: Request) !Reply {
        return request(t.io, f.arena.allocator(), "127.0.0.1", f.s.port, r);
    }

    /// A message with a client's token.
    fn rpc(f: *Fix, token: []const u8, body: []const u8) !Reply {
        return f.send(.{ .auth = try std.fmt.allocPrint(f.arena.allocator(), "Bearer {s}", .{token}), .body = body });
    }

    fn json(f: *Fix, r: Reply) !std.json.ObjectMap {
        return (try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), r.body, .{})).object;
    }

    /// The error's code of an answer.
    fn code(f: *Fix, r: Reply) !i64 {
        return (try f.json(r)).get("error").?.object.get("code").?.integer;
    }
};

const plain: Options = .{ .listen = "127.0.0.1:0", .clients = &two, .backend = undefined };

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

/// A client on its own thread and arena.
const Caller = struct {
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    got: ?Reply = null,

    fn start(c: *Caller, port: u16, token: []const u8, body: []const u8) !void {
        c.* = .{ .arena = .init(t.allocator) };
        c.thread = try std.Thread.spawn(.{}, run, .{ c, port, token, body });
    }

    fn run(c: *Caller, port: u16, token: []const u8, body: []const u8) void {
        const a = c.arena.allocator();
        const auth = std.fmt.allocPrint(a, "Bearer {s}", .{token}) catch return;
        c.got = request(t.io, a, "127.0.0.1", port, .{ .auth = auth, .body = body }) catch null;
    }

    fn join(c: *Caller) !Reply {
        c.thread.join();
        return c.got orelse error.NoAnswer;
    }
};

test "no_token_or_a_wrong_one_is_refused_before_the_body" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    // none, another one, another scheme, the token bare or longer: refused
    for ([_]?[]const u8{ null, "Bearer wrong-token-0123456789abcdef-wrong", "Basic x", tok_a, "Bearer " ++ tok_a ++ "x", "Bearer" }) |auth| {
        const got = try f.send(.{ .auth = auth, .body = call_body });
        try t.expectEqual(401, got.status);
        try expectHas(got.head, "www-authenticate: Bearer");
        try expectHas(got.body, "\"error\":{");
    }
    // a large body under a wrong token: answered, never kept or looked at
    const big = try f.arena.allocator().alloc(u8, 2 << 20);
    @memset(big, 'x');
    try t.expectEqual(401, (try f.send(.{ .auth = "Bearer wrong-token-0123456789abcdef-wrong", .body = big })).status);
    // a GET says no more to one without the token
    try t.expectEqual(401, (try f.send(.{ .method = "GET" })).status);
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
    // the token, in any case of "bearer"
    try t.expectEqual(200, (try f.send(.{ .auth = "Bearer " ++ tok_a, .body = list_body })).status);
    try t.expectEqual(200, (try f.send(.{ .auth = "bearer " ++ tok_a, .body = list_body })).status);
    try t.expectEqual([2]u32{ 2, 0 }, f.rec.counts());
}

test "each_token_names_its_client" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    try t.expectEqual(200, (try f.rpc(tok_b, list_body)).status);
    try t.expectEqualStrings("b", f.rec.client[0..f.rec.client_len]);
    try t.expectEqual(200, (try f.rpc(tok_a, call_body)).status);
    try t.expectEqualStrings("a", f.rec.client[0..f.rec.client_len]);
    try t.expectEqual(200, (try f.rpc(tok_b, call_body)).status);
    try t.expectEqualStrings("b", f.rec.client[0..f.rec.client_len]);
}

test "initialize_answers_the_version_asked_or_the_newest" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const old = try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"x\",\"version\":\"1\"}}}");
    try t.expectEqual(200, old.status);
    try expectHas(old.head, "content-type: application/json");
    const o = try f.json(old);
    try t.expectEqualStrings("2.0", o.get("jsonrpc").?.string);
    try t.expectEqual(7, o.get("id").?.integer);
    const res = o.get("result").?.object;
    try t.expectEqualStrings("2025-03-26", res.get("protocolVersion").?.string);
    try expectHas(old.body, "\"capabilities\":{\"tools\":{}}");
    try expectHas(old.body, "\"serverInfo\":{\"name\":\"harness\",\"version\":\"");
    try expectHas(res.get("instructions").?.string, "refused by the gate");
    try expectHas(res.get("instructions").?.string, "approval");
    // a version harness doesn't speak, or none: the newest it does; the id as sent
    const new = try f.json(try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"id\":\"abc-\\\"1\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"}}"));
    try t.expectEqualStrings("abc-\"1", new.get("id").?.string);
    try t.expectEqualStrings("2025-06-18", new.get("result").?.object.get("protocolVersion").?.string);
    const none = try f.json(try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"id\":9007199254740993,\"method\":\"initialize\"}"));
    try t.expectEqual(9007199254740993, none.get("id").?.integer);
    try t.expectEqualStrings("2025-06-18", none.get("result").?.object.get("protocolVersion").?.string);
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
}

test "notifications_and_responses_get_202" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/whatever\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"x\"}}",
        // a notification named like a request is still only a notification
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"notes__add\"}}",
    }) |body| {
        const got = try f.rpc(tok_a, body);
        try t.expectEqual(202, got.status);
        try t.expectEqualStrings("", got.body);
    }
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
}

test "ping_answers_empty" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const got = try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}");
    try t.expectEqual(200, got.status);
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{}}", got.body);
}

test "tools_list_is_the_backends_array" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const got = try f.rpc(tok_a, list_body);
    try t.expectEqual(200, got.status);
    const o = try f.json(got);
    try t.expectEqual(1, o.get("id").?.integer);
    const tools = o.get("result").?.object.get("tools").?.array.items;
    try t.expectEqual(1, tools.len);
    try t.expectEqualStrings("notes__add", tools[0].object.get("name").?.string);
    try t.expectEqualStrings("object", tools[0].object.get("inputSchema").?.object.get("type").?.string);
    // no cursor: the whole list at once
    try t.expect(o.get("result").?.object.get("nextCursor") == null);
    // a client with nothing named
    f.rec.tools = "[]";
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}", (try f.rpc(tok_a, list_body)).body);
    // while the servers restart: an error that says to ask again
    f.rec.listed_busy = true;
    const busy = try f.rpc(tok_a, list_body);
    try t.expectEqual(200, busy.status);
    try t.expectEqual(-32000, try f.code(busy));
    try expectHas(busy.body, "reloading");
}

test "tools_call_carries_name_and_arguments" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const got = try f.rpc(tok_a, call_body);
    try t.expectEqual(200, got.status);
    try t.expectEqualStrings("notes__add", f.rec.name[0..f.rec.name_len]);
    try t.expectEqualStrings("{\"text\":\"milk \\\"2 %\\\"\"}", f.rec.args[0..f.rec.args_len]);
    try t.expect(!f.rec.gone_at_entry.load(.acquire));
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"added \\\"milk\\\"\"}],\"isError\":false}}", got.body);
    // no arguments: an empty object
    try t.expectEqual(200, (try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"notes__list\"}}")).status);
    try t.expectEqualStrings("notes__list", f.rec.name[0..f.rec.name_len]);
    try t.expectEqualStrings("{}", f.rec.args[0..f.rec.args_len]);
    // the gate's refusal is the tool's answer, marked
    f.rec.reply = .{ .result = .{ .text = "refused by the gate: denied by the owner", .is_error = true } };
    const refused = try f.json(try f.rpc(tok_a, call_body));
    const res = refused.get("result").?.object;
    try t.expect(res.get("isError").?.bool);
    try t.expectEqualStrings("refused by the gate: denied by the owner", res.get("content").?.array.items[0].object.get("text").?.string);
    // not among this client's tools
    f.rec.reply = .unknown;
    const unknown = try f.rpc(tok_a, call_body);
    try t.expectEqual(200, unknown.status);
    try t.expectEqual(-32602, try f.code(unknown));
    try expectHas(unknown.body, "notes__add");
    // while the servers restart
    f.rec.reply = .busy;
    const busy = try f.rpc(tok_a, call_body);
    try t.expectEqual(-32000, try f.code(busy));
    try expectHas(busy.body, "reloading");
    try t.expectEqual(2, (try f.json(busy)).get("id").?.integer);
}

test "what_is_not_mcp_is_refused" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const auth = "Bearer " ++ tok_a;
    // a method harness doesn't have: resources, prompts, anything
    for ([_][]const u8{ "resources/list", "prompts/list", "logging/setLevel", "tools/run", "" }) |m| {
        const got = try f.rpc(tok_a, try std.fmt.allocPrint(f.arena.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"{s}\"}}", .{m}));
        try t.expectEqual(200, got.status);
        try t.expectEqual(-32601, try f.code(got));
        try t.expectEqual(3, (try f.json(got)).get("id").?.integer);
    }
    // a batch, what isn't a message, an id that can't be one
    for ([_][]const u8{ "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", "5", "\"ping\"", "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}", "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}", "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":5}" }) |body| {
        const got = try f.rpc(tok_a, body);
        try t.expectEqual(400, got.status);
        try t.expectEqual(-32600, try f.code(got));
    }
    // not JSON
    for ([_][]const u8{ "hello", "", "{\"jsonrpc\":" }) |body| {
        const got = try f.rpc(tok_a, body);
        try t.expectEqual(400, got.status);
        try t.expectEqual(-32700, try f.code(got));
    }
    // no stream to open, no session to end
    for ([_][]const u8{ "GET", "DELETE", "PUT" }) |m| {
        const got = try f.send(.{ .method = m, .auth = auth });
        try t.expectEqual(405, got.status);
        try expectHas(got.head, "allow: POST");
    }
    for ([_][]const u8{ "/", "/other", "/mcp/x", "/v1/mcp", "/MCP" }) |path|
        try t.expectEqual(404, (try f.send(.{ .path = path, .auth = auth, .body = list_body })).status);
    try t.expectEqual(200, (try f.send(.{ .path = "/mcp?x=1", .auth = auth, .body = list_body })).status);
    // a call without its tool's name, or with arguments that are no object
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":5}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"notes__add\",\"arguments\":\"x\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":[\"notes__add\"]}",
    }) |body| {
        const got = try f.rpc(tok_a, body);
        try t.expectEqual(200, got.status);
        try t.expectEqual(-32602, try f.code(got));
    }
    // a version of the protocol harness doesn't speak
    try t.expectEqual(400, (try f.send(.{ .auth = auth, .body = list_body, .version = "2024-11-05" })).status);
    try t.expectEqual(200, (try f.send(.{ .auth = auth, .body = list_body, .version = "2025-03-26" })).status);
    try t.expectEqual(200, (try f.send(.{ .auth = auth, .body = list_body, .version = "2025-06-18" })).status);
    try t.expectEqual([2]u32{ 3, 0 }, f.rec.counts());
}

test "initialize under a newer MCP-Protocol-Version header is answered with the version harness speaks" {
    // the MCP Python SDK (Hermes) sends its newest version as the header of
    // initialize itself, before anything is agreed
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const auth = "Bearer " ++ tok_a;
    const got = try f.send(.{ .auth = auth, .version = "2025-11-25", .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"mcp\",\"version\":\"0.1.0\"}}}" });
    try t.expectEqual(200, got.status);
    try t.expectEqualStrings("2025-06-18", (try f.json(got)).get("result").?.object.get("protocolVersion").?.string);
    // the notification that follows may still carry it; it is taken
    try t.expectEqual(202, (try f.send(.{ .auth = auth, .version = "2025-11-25", .body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" })).status);
    // any other request under a version harness doesn't speak is refused, with the reason
    const list = try f.send(.{ .auth = auth, .version = "2025-11-25", .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}" });
    try t.expectEqual(400, list.status);
    try expectHas(list.body, "MCP-Protocol-Version is not one harness speaks (2025-06-18, 2025-03-26)");
    try t.expectEqual(400, (try f.send(.{ .auth = auth, .version = "2025-11-25", .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}" })).status);
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
}

test "a_foreign_origin_is_refused" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const a = f.arena.allocator();
    const auth = "Bearer " ++ tok_a;
    for ([_][]const u8{ "https://evil.example", "http://evil.example:8766", "null", "http://127.0.0.1", "http://127.0.0.1:1", "https://localhost" }) |origin| {
        const got = try f.send(.{ .auth = auth, .body = call_body, .origin = origin });
        try t.expectEqual(403, got.status);
    }
    // a page's own port on another name is another origin
    try t.expectEqual(403, (try f.send(.{ .auth = auth, .body = call_body, .origin = try std.fmt.allocPrint(a, "http://evil.example:{d}", .{f.s.port}) })).status);
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
    // the proxy's own address
    for ([_][]const u8{ "http://127.0.0.1:{d}", "http://localhost:{d}", "http://[::1]:{d}", "HTTP://LOCALHOST:{d}" }) |form| {
        const origin = try std.mem.replaceOwned(u8, a, form, "{d}", try std.fmt.allocPrint(a, "{d}", .{f.s.port}));
        try t.expectEqual(200, (try f.send(.{ .auth = auth, .body = list_body, .origin = origin })).status);
    }
}

test "a_body_over_the_limit_is_refused" {
    var f: Fix = undefined;
    var o = plain;
    o.max_body = 4096;
    try f.init(o);
    defer f.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(t.allocator);
    try big.appendSlice(t.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"notes__add\",\"arguments\":{\"text\":\"");
    for (0..5000) |_| try big.append(t.allocator, 'x');
    try big.appendSlice(t.allocator, "\"}}}");
    const got = try f.rpc(tok_a, big.items);
    try t.expectEqual(413, got.status);
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
    try t.expectEqual(200, (try f.rpc(tok_a, call_body)).status);
}

test "a_chunked_body_over_the_limit_is_refused" {
    var f: Fix = undefined;
    var o = plain;
    o.max_body = 4096;
    try f.init(o);
    defer f.deinit();
    const a = f.arena.allocator();
    // no Content-Length to refuse it by: the size shows only while reading
    const h = try sock.connect(t.io, "127.0.0.1", f.s.port, 2000);
    const rbuf = try a.alloc(u8, 64 * 1024);
    var wbuf: [4096]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, rbuf, &wbuf, 20_000);
    defer sk.close();
    try sk.writer.print("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{ f.s.port, tok_a });
    try sk.writer.writeAll("1388\r\n");
    for (0..5000) |_| try sk.writer.writeByte('x');
    try sk.writer.writeAll("\r\n0\r\n\r\n");
    try sk.writer.flush();
    const all = try sk.reader.allocRemaining(a, .limited(1 << 20));
    try t.expect(std.mem.startsWith(u8, all, "HTTP/1.1 413"));
    try t.expectEqual([2]u32{ 0, 0 }, f.rec.counts());
    // and the proxy still answers
    try t.expectEqual(200, (try f.rpc(tok_a, call_body)).status);
}

test "a_fifth_call_of_one_client_is_answered_at_once" {
    var f: Fix = undefined;
    var o = plain;
    o.calls_per_client = 1;
    try f.init(o);
    defer f.deinit();
    f.rec.mode = .hold_first;
    var first: Caller = undefined;
    try first.start(f.s.port, tok_a, call_body);
    defer first.arena.deinit();
    try f.rec.waitEntered(1);
    // one more of the same client: told so at once, as the tool's answer
    const second = try f.rpc(tok_a, call_body);
    try t.expectEqual(200, second.status);
    const res = (try f.json(second)).get("result").?.object;
    try t.expect(res.get("isError").?.bool);
    try expectHas(res.get("content").?.array.items[0].object.get("text").?.string, "going already");
    try t.expectEqual(1, f.rec.entered.load(.acquire));
    // listing is no call, and another client's call is its own
    try t.expectEqual(200, (try f.rpc(tok_a, list_body)).status);
    const other = try f.rpc(tok_b, call_body);
    try expectHas(other.body, "\"isError\":false");
    try t.expectEqual(2, f.rec.entered.load(.acquire));
    f.rec.release.store(true, .release);
    try expectHas((try first.join()).body, "\"isError\":false");
    // and when it ended, the next one goes
    try expectHas((try f.rpc(tok_a, call_body)).body, "\"isError\":false");
}

test "hanging_up_sets_gone" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    f.rec.mode = .wait_gone;
    const h = try sock.connect(t.io, "127.0.0.1", f.s.port, 2000);
    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    try writeRequest(&sk, "127.0.0.1", f.s.port, .{ .auth = "Bearer " ++ tok_a, .body = call_body }, false);
    try f.rec.waitEntered(1);
    try t.expect(!f.rec.gone_at_entry.load(.acquire));
    // the client gives up (its own timeout, its user's stop)
    sk.close();
    var waited: u32 = 0;
    while (!f.rec.saw_gone.load(.acquire) and waited < 2000) : (waited += 10) t.io.sleep(.fromMilliseconds(10), .awake) catch {};
    try t.expect(f.rec.saw_gone.load(.acquire));
}

test "more_bytes_on_the_connection_are_no_hang_up" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    f.rec.mode = .wait_gone;
    const h = try sock.connect(t.io, "127.0.0.1", f.s.port, 2000);
    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    defer sk.close();
    try writeRequest(&sk, "127.0.0.1", f.s.port, .{ .auth = "Bearer " ++ tok_a, .body = call_body }, false);
    try f.rec.waitEntered(1);
    // the next request sent while the call goes: the client is still there
    try writeRequest(&sk, "127.0.0.1", f.s.port, .{ .auth = "Bearer " ++ tok_a, .body = list_body }, false);
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try t.expect(!f.rec.saw_gone.load(.acquire));
}

test "a_message_nested_too_deep_is_refused" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const a = f.arena.allocator();
    const head = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"notes__add\",\"arguments\":{\"x\":";
    for ([_]usize{ 20, 100, 200_000 }, [_]u16{ 200, 400, 400 }) |depth, status| {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, head);
        try body.appendNTimes(a, '[', depth);
        // brackets inside a string are text
        try body.appendSlice(a, "\"[[[[ \\\" {{{{\"");
        try body.appendNTimes(a, ']', depth);
        try body.appendSlice(a, "}}}");
        const got = try f.rpc(tok_a, body.items);
        try t.expectEqual(status, got.status);
        if (status == 400) try t.expectEqual(-32600, try f.code(got));
    }
    try t.expectEqual([2]u32{ 0, 1 }, f.rec.counts());
}

test "a_cancelled_notification_sets_gone" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    f.rec.mode = .wait_gone;
    var going: Caller = undefined;
    try going.start(f.s.port, tok_a, call_body);
    defer going.arena.deinit();
    try f.rec.waitEntered(1);
    // another client's cancel, or one for another request, ends nothing
    try t.expectEqual(202, (try f.rpc(tok_b, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}")).status);
    try t.expectEqual(202, (try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"2\"}}")).status);
    try t.expectEqual(202, (try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\"}")).status);
    t.io.sleep(.fromMilliseconds(150), .awake) catch {};
    try t.expect(!f.rec.saw_gone.load(.acquire));
    // its own
    try t.expectEqual(202, (try f.rpc(tok_a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2,\"reason\":\"user\"}}")).status);
    const got = try going.join();
    try t.expect(f.rec.saw_gone.load(.acquire));
    try expectHas(got.body, "\"isError\":true");
}

test "a_stop_ends_a_waiting_call_and_answers_it" {
    var rec: Rec = .{ .mode = .wait_gone };
    const s = try Server.start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &two, .backend = rec.backend() });
    var going: Caller = undefined;
    try going.start(s.port, tok_a, call_body);
    defer going.arena.deinit();
    try rec.waitEntered(1);
    const started = sock.nowNs(t.io);
    s.stop();
    try t.expect(@divFloor(sock.nowNs(t.io) - started, std.time.ns_per_ms) < 3000);
    const got = try going.join();
    try t.expect(rec.saw_gone.load(.acquire));
    try t.expectEqual(200, got.status);
    try expectHas(got.body, "its run stopped");
}

test "a_kept_connection_answers_again" {
    var f: Fix = undefined;
    try f.init(plain);
    defer f.deinit();
    const h = try sock.connect(t.io, "127.0.0.1", f.s.port, 2000);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    defer sk.close();
    // a call, a notification, a call: each answered in turn on the one connection
    for ([_][]const u8{ call_body, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", call_body }, [_][]const u8{ "200", "202", "200" }) |body, status| {
        try writeRequest(&sk, "127.0.0.1", f.s.port, .{ .auth = "Bearer " ++ tok_a, .body = body }, false);
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(t.allocator);
        while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) try head.append(t.allocator, try sk.reader.takeByte());
        try t.expectEqualStrings(status, head.items[9..12]);
        const at = std.ascii.findIgnoreCase(head.items, "content-length: ").? + "content-length: ".len;
        const n = try std.fmt.parseInt(usize, head.items[at .. at + std.mem.indexOf(u8, head.items[at..], "\r\n").?], 10);
        for (0..n) |_| _ = try sk.reader.takeByte();
    }
    try t.expectEqual([2]u32{ 0, 2 }, f.rec.counts());
    try t.expect(!f.rec.gone_at_entry.load(.acquire));
}

test "short_same_and_missing_tokens_do_not_start" {
    var rec: Rec = .{};
    const b = rec.backend();
    const start = Server.start;
    try t.expectError(error.NoClients, start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &.{}, .backend = b }));
    try t.expectError(error.ShortToken, start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &.{ two[0], .{ .name = "c", .token = "0123456789abcdef0123456789abcde" } }, .backend = b }));
    try t.expectError(error.SameToken, start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &.{ two[0], two[1], .{ .name = "c", .token = tok_a } }, .backend = b }));
    try t.expectError(error.SameName, start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &.{ two[0], .{ .name = "a", .token = tok_b } }, .backend = b }));
    try t.expectError(error.BadName, start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &.{.{ .name = "Bad Name", .token = tok_a }}, .backend = b }));
    var many: [config.max_clients + 1]ClientToken = undefined;
    var names: [config.max_clients + 1][4]u8 = undefined;
    var tokens: [config.max_clients + 1][40]u8 = undefined;
    for (&many, 0..) |*m, i| m.* = .{
        .name = try std.fmt.bufPrint(&names[i], "c{d}", .{i}),
        .token = try std.fmt.bufPrint(&tokens[i], "token-number-{d:0>2}-0123456789abcdef-xyz", .{i}),
    };
    try t.expectError(error.TooManyClients, start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &many, .backend = b }));
    // this machine's own address only
    for ([_][]const u8{ "0.0.0.0:0", "192.168.1.5:0", "[::]:0", "localhost:0", "127.0.0.1", "off" }) |listen|
        try t.expectError(error.BadAddress, start(t.allocator, t.io, .{ .listen = listen, .clients = &two, .backend = b }));
    // sixteen is fine, and the port is its own while it runs
    const s = try start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = many[0..config.max_clients], .backend = b });
    defer s.stop();
    try t.expect(std.mem.startsWith(u8, s.address(), "127.0.0.1:"));
    var buf: [32]u8 = undefined;
    try t.expectError(error.AddressInUse, start(t.allocator, t.io, .{ .listen = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{s.port}), .clients = &two, .backend = b }));
}

test "the_token_is_not_logged" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "log.jsonl" });
    var l = try log_mod.Log.open(t.allocator, t.io, path);
    var rec: Rec = .{};
    {
        const s = try Server.start(t.allocator, t.io, .{ .listen = "127.0.0.1:0", .clients = &two, .backend = rec.backend(), .log = &l });
        defer s.stop();
        const wrong = "Bearer wrong-token-0123456789abcdef-wrong";
        // refusals of one kind are one line a minute
        for (0..3) |_| try t.expectEqual(401, (try request(t.io, a, "127.0.0.1", s.port, .{ .auth = wrong, .body = call_body })).status);
        try t.expectEqual(404, (try request(t.io, a, "127.0.0.1", s.port, .{ .path = "/x", .auth = "Bearer " ++ tok_a })).status);
        try t.expectEqual(200, (try request(t.io, a, "127.0.0.1", s.port, .{ .auth = "Bearer " ++ tok_a, .body = call_body })).status);
    }
    l.close();
    const text = try tmp.dir.readFileAlloc(t.io, "log.jsonl", a, .limited(1 << 20));
    try expectHas(text, "proxy listening");
    try expectHas(text, "\"clients\":\"a, b\"");
    try expectHas(text, "proxy stopped");
    try t.expectEqual(1, std.mem.count(u8, text, "\"why\":\"token\""));
    try t.expectEqual(1, std.mem.count(u8, text, "\"why\":\"route\""));
    for ([_][]const u8{ tok_a, tok_b, "wrong-token", "milk" }) |secret| try t.expect(std.mem.indexOf(u8, text, secret) == null);
}

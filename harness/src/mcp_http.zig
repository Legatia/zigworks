//! MCP's Streamable HTTP transport, for a server at a url (`url =` in
//! mcp.ini): MCP 2025-06-18, and 2025-03-26 when the server answers with
//! it. mcp.zig's `Server` sends its JSON-RPC requests through `Remote`
//! instead of a program's stdin, so the rest of harness can't tell the two
//! apart.
//!
//! - Each message is a POST of its own, `Accept: application/json,
//!   text/event-stream`; the answer is JSON or an event stream that carries
//!   it (notifications in it are passed on or dropped as stdio's are, and
//!   the server's requests answered: `ping` with an empty result, anything
//!   else "not supported"). A notification is answered 202.
//! - `initialize` gives the session (`Mcp-Session-Id`) and the version;
//!   every later request carries both. A 404 with a session means it
//!   ended: the session is started again once (with what was subscribed)
//!   and the request sent again (a 404 request did not run).
//! - With a server that takes subscriptions, a GET event stream carries
//!   its resource updates, opened again with backoff; the session is
//!   deleted on stop.
//! - 401: one renewal for a sign-in, then said with what to do; 403, a
//!   redirect (never followed), a 404 without a session and 5xx are said
//!   naming the server; 429 waits as told once within the call's time.
//!   What a failure says is masked: a token never reaches a message.
const std = @import("std");
const http = @import("http.zig");
const url_mod = @import("url.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const scrub = @import("scrub.zig");
const oauth = @import("oauth.zig");
const store_mod = @import("store.zig");
const masks_mod = @import("masks.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The versions harness speaks, the one it asks for first.
pub const versions = [_][]const u8{ "2025-06-18", "2025-03-26" };
/// The longest answer or event taken.
pub const max_message = 16 << 20;
/// The longest session id kept.
const max_session = 256;
/// How long the GET stream may bring nothing before it is opened again.
const stream_idle_ms = 10 * 60 * 1000;
/// Longest wait after a 429 (s).
const max_retry_wait_s = 60;

/// How a server's requests are signed.
pub const Auth = union(enum) {
    none,
    /// `token =`: a stored secret sent as `Authorization: Bearer`.
    token: Token,
    /// `login = oauth`: the sign-in kept in the store as `mcp-NAME`
    /// (`harness mcp login NAME`), renewed and kept there; its values are
    /// added to `masks`.
    signin: SignIn,

    pub const Token = struct { name: []const u8, value: []const u8 };
    pub const SignIn = struct { store: store_mod.Store, masks: ?*masks_mod.List = null };
};

/// Told a resource the server was asked to watch changed. Called on the
/// stream's thread (or the caller's, for one in a POST's answer).
pub const Updated = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, server: []const u8, uri: []const u8) void,
};

pub const Options = struct {
    /// The server's name in mcp.ini (said in every failure).
    name: []const u8,
    /// Its address, in url.zig's one form.
    url: []const u8,
    headers: []const std.http.Header = &.{},
    auth: Auth = .none,
    updated: ?Updated = null,
    /// The first wait before the GET stream is opened again; it doubles up
    /// to a minute.
    backoff_ms: u32 = 1000,
};

pub const Error = error{
    /// The failure is said in `why()`.
    Said,
    Timeout,
    Stopped,
    OutOfMemory,
};

pub const Remote = struct {
    gpa: Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    name: []const u8,
    url: []const u8,
    target: http.Target,
    /// Path and query, as sent.
    path: []const u8,
    headers: []const std.http.Header,
    auth: Auth,
    /// A sign-in's tokens (`auth` is .signin).
    keeper: ?*oauth.Keeper = null,
    updated: ?Updated,
    backoff_ms: u32,

    /// Requests, one at a time (with `next_id`, `init_params` and
    /// `subscribed`).
    post_mutex: Io.Mutex = .init,
    post: http.Client,
    next_id: u64 = 1,
    /// initialize's params, for starting a session again.
    init_params: []const u8 = "",
    /// What was subscribed to (gpa), subscribed to again in a new session.
    subscribed: std.ArrayList([]u8) = .empty,

    /// Answers to the server's requests, cancellations, the DELETE.
    side_mutex: Io.Mutex = .init,
    side: http.Client,

    /// The session and the version, read by every request.
    state_mutex: Io.Mutex = .init,
    session_buf: [max_session]u8 = undefined,
    session_len: usize = 0,
    /// One of `versions` once initialized; "" before.
    version: []const u8 = "",
    /// The GET stream was told the session ended: the next request starts
    /// one again.
    session_gone: std.atomic.Value(bool) = .init(false),

    stream_thread: ?std.Thread = null,
    stream_stop: std.atomic.Value(bool) = .init(false),
    /// GET streams opened so far.
    streams: std.atomic.Value(u32) = .init(0),

    /// Why the last request failed (error.Said), masked, and what kind of
    /// failure it was (`failure`).
    why_buf: [1024]u8 = undefined,
    why_len: usize = 0,
    why_err: anyerror = error.Refused,

    /// error.NotSignedIn for a sign-in with nothing kept.
    pub fn open(gpa: Allocator, io: Io, o: Options) !*Remote {
        // made here, then moved into the Remote (`a` is not used after)
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_state.deinit();
        const a = arena_state.allocator();
        const u = url_mod.parse(a, o.url) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadUrl;
        const target: http.Target = .{ .https = u.https, .host = u.connectHost(), .port = u.port, .prefix = "" };
        const hs = try a.alloc(std.http.Header, o.headers.len);
        for (o.headers, 0..) |h, i| hs[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        const name = try a.dupe(u8, o.name);
        const auth: Auth = switch (o.auth) {
            .token => |tk| .{ .token = .{ .name = try a.dupe(u8, tk.name), .value = try a.dupe(u8, tk.value) } },
            .signin => |si| .{ .signin = .{ .store = try storeCopy(a, si.store), .masks = si.masks } },
            .none => .none,
        };
        var keeper: ?*oauth.Keeper = null;
        if (auth == .signin) {
            var buf: [40]u8 = undefined;
            const secret = std.fmt.bufPrint(&buf, "mcp-{s}", .{o.name}) catch return error.BadUrl;
            keeper = try oauth.Keeper.open(gpa, io, auth.signin.store, o.name, secret, auth.signin.masks);
        }
        errdefer if (keeper) |k| k.destroy();
        const r = try gpa.create(Remote);
        r.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = arena_state,
            .name = name,
            .url = u.href,
            .target = target,
            .path = u.target,
            .headers = hs,
            .auth = auth,
            .keeper = keeper,
            .updated = o.updated,
            .backoff_ms = @max(o.backoff_ms, 10),
            .post = .init(gpa, io, target),
            .side = .init(gpa, io, target),
        };
        return r;
    }

    /// Ends the stream and deletes the session (a short try: a server that
    /// doesn't answer is not waited for).
    pub fn end(r: *Remote) void {
        r.stopStream();
        if (r.stream_thread) |th| th.join();
        r.stream_thread = null;
        var sbuf: [max_session]u8 = undefined;
        const st = r.state(&sbuf);
        if (st.session.len > 0) {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            r.side_mutex.lockUncancelable(r.io);
            defer r.side_mutex.unlock(r.io);
            const bearer = r.bearerNow(a) catch null;
            var hs: [2]std.http.Header = undefined;
            const n = sessionHeaders(&hs, st);
            if (r.side.send(.{ .method = .DELETE, .path = r.path, .key = bearer, .headers = hs[0..n], .limits = .{ .idle_ms = 1000, .total_ms = 1000 } })) |resp| {
                var x = resp;
                x.deinit();
            } else |_| {}
        }
        r.setState("", "");
    }

    /// Frees everything; after `end`.
    pub fn destroy(r: *Remote) void {
        r.post.deinit();
        r.side.deinit();
        for (r.subscribed.items) |u| r.gpa.free(u);
        r.subscribed.deinit(r.gpa);
        if (r.keeper) |k| k.destroy();
        r.arena_state.deinit();
        r.gpa.destroy(r);
    }

    /// Tells the stream to end (it does within 0.1 s); waits for nothing.
    pub fn stopStream(r: *Remote) void {
        r.stream_stop.store(true, .release);
    }

    /// What the last failed request said (error.Said).
    pub fn why(r: *const Remote) []const u8 {
        return r.why_buf[0..r.why_len];
    }

    /// What kind of failure that was: Refused, NotFound, Redirected,
    /// RateLimited, Upstream, Unreachable, BadVersion or BadAnswer.
    pub fn failure(r: *const Remote) anyerror {
        return r.why_err;
    }

    /// Whether the server refused the sign-in since it started (for
    /// /status).
    pub fn signInRefused(r: *const Remote) bool {
        const k = r.keeper orelse return false;
        return k.refused();
    }

    /// `text` with the server's token, or its sign-in's values, masked.
    pub fn mask(r: *Remote, arena: Allocator, text: []const u8) ![]const u8 {
        var list: std.ArrayList(scrub.Secret) = .empty;
        switch (r.auth) {
            .none => {},
            .token => |tk| try list.append(arena, .{ .name = tk.name, .value = tk.value }),
            .signin => if (r.keeper) |k| try list.appendSlice(arena, try k.secrets(arena)),
        }
        if (list.items.len == 0) return text;
        var s = try scrub.Scrubber.init(arena, list.items);
        return s.scrubAlloc(arena, text);
    }

    /// Remembers a resource subscribed to, to subscribe again in a new
    /// session.
    pub fn remember(r: *Remote, uri: []const u8) void {
        r.post_mutex.lockUncancelable(r.io);
        defer r.post_mutex.unlock(r.io);
        for (r.subscribed.items) |u| if (std.mem.eql(u8, u, uri)) return;
        const owned = r.gpa.dupe(u8, uri) catch return;
        r.subscribed.append(r.gpa, owned) catch r.gpa.free(owned);
    }

    /// Sends a request and returns its JSON-RPC response (copied to
    /// `arena`); `initialize` also takes the session and the version.
    pub fn request(r: *Remote, arena: Allocator, method: []const u8, params_json: []const u8, stop: *const std.atomic.Value(bool), deadline_ns: i128) Error![]const u8 {
        r.post_mutex.lockUncancelable(r.io);
        defer r.post_mutex.unlock(r.io);
        r.why_len = 0;
        if (std.mem.eql(u8, method, "initialize")) {
            r.init_params = try r.arena_state.allocator().dupe(u8, params_json);
            r.setState("", "");
            r.session_gone.store(false, .release);
            return r.requestLocked(arena, method, params_json, stop, deadline_ns, false);
        }
        // the stream saw the session end: a new one before this request
        if (r.session_gone.load(.acquire) and r.hasSession()) {
            try r.restart(arena, stop, deadline_ns);
            return r.requestLocked(arena, method, params_json, stop, deadline_ns, false);
        }
        return r.requestLocked(arena, method, params_json, stop, deadline_ns, true);
    }

    /// Sends a notification (`json` is the whole message); 202 expected.
    pub fn notify(r: *Remote, arena: Allocator, json: []const u8, stop: *const std.atomic.Value(bool), deadline_ns: i128) Error!void {
        r.post_mutex.lockUncancelable(r.io);
        defer r.post_mutex.unlock(r.io);
        r.why_len = 0;
        return r.notifyLocked(arena, json, stop, deadline_ns);
    }

    /// Opens the GET stream the server's resource updates come on, kept
    /// open and opened again with backoff until `end`.
    pub fn startStream(r: *Remote) void {
        if (r.stream_thread != null) return;
        r.stream_stop.store(false, .release);
        r.stream_thread = std.Thread.spawn(.{}, streamLoop, .{r}) catch null;
    }

    // ---- inside ----

    const State = struct { session: []const u8, version: []const u8 };

    /// The session and the version now (the session copied to `buf`).
    fn state(r: *Remote, buf: *[max_session]u8) State {
        r.state_mutex.lockUncancelable(r.io);
        defer r.state_mutex.unlock(r.io);
        @memcpy(buf[0..r.session_len], r.session_buf[0..r.session_len]);
        return .{ .session = buf[0..r.session_len], .version = r.version };
    }

    fn setState(r: *Remote, session: []const u8, version: []const u8) void {
        r.state_mutex.lockUncancelable(r.io);
        defer r.state_mutex.unlock(r.io);
        const n = @min(session.len, max_session);
        @memcpy(r.session_buf[0..n], session[0..n]);
        r.session_len = n;
        r.version = version;
    }

    fn hasSession(r: *Remote) bool {
        r.state_mutex.lockUncancelable(r.io);
        defer r.state_mutex.unlock(r.io);
        return r.session_len > 0;
    }

    /// Mcp-Session-Id and MCP-Protocol-Version, as far as there are any.
    fn sessionHeaders(hs: *[2]std.http.Header, st: State) usize {
        var n: usize = 0;
        if (st.version.len > 0) {
            hs[n] = .{ .name = "MCP-Protocol-Version", .value = st.version };
            n += 1;
        }
        if (st.session.len > 0) {
            hs[n] = .{ .name = "Mcp-Session-Id", .value = st.session };
            n += 1;
        }
        return n;
    }

    /// The token to send now: the stored one, or the sign-in's (renewed
    /// first when it is about to expire).
    fn bearerNow(r: *Remote, a: Allocator) error{OutOfMemory}!?[]const u8 {
        return switch (r.auth) {
            .none => null,
            .token => |tk| tk.value,
            .signin => if (r.keeper) |k| try k.bearer(a) else null,
        };
    }

    /// Says a failure (masked) of kind `kind` and returns error.Said.
    fn say(r: *Remote, kind: anyerror, comptime fmt: []const u8, args: anytype) Error {
        r.why_err = kind;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const raw = std.fmt.allocPrint(a, fmt, args) catch return error.OutOfMemory;
        const text = r.mask(a, raw) catch raw;
        const s = util.cut(text, r.why_buf.len);
        @memcpy(r.why_buf[0..s.len], s);
        r.why_len = s.len;
        return error.Said;
    }

    fn requestLocked(r: *Remote, arena: Allocator, method: []const u8, params_json: []const u8, stop: *const std.atomic.Value(bool), deadline_ns: i128, may_restart: bool) Error![]const u8 {
        const id = r.next_id;
        r.next_id += 1;
        const body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, std.json.fmt(method, .{}), params_json });
        const initializing = std.mem.eql(u8, method, "initialize");
        var restarted = !may_restart;
        var renewed = false;
        var limited = false;
        var connect_retry = false;
        while (true) {
            const bearer = try r.bearerNow(arena);
            const out = r.exchange(arena, &r.post, .POST, body, id, bearer, stop, deadline_ns, initializing) catch |e| {
                if (e == error.Timeout or e == error.Stopped) r.cancel(id, if (e == error.Timeout) "timed out" else "stopped");
                return e;
            };
            switch (out) {
                .answer => |ans| {
                    if (initializing) try r.takeSession(arena, ans);
                    return ans.json;
                },
                .accepted => return r.say(error.BadAnswer, "{s} accepted {s} without answering it", .{ r.name, method }),
                .unreached => |e| {
                    // nothing reached the server: once more
                    if (e == error.ConnectFailed and !connect_retry) {
                        connect_retry = true;
                        continue;
                    }
                    return r.unreached(e);
                },
                .status => |st| switch (st.code) {
                    404 => if (!restarted and r.hasSession()) {
                        // the session ended: a new one, and this again (it did not run)
                        restarted = true;
                        try r.restart(arena, stop, deadline_ns);
                        continue;
                    } else return r.statusFailure(arena, st),
                    401 => {
                        // a sign-in: renewed once (or one made since taken)
                        if (!renewed) if (r.keeper) |k| {
                            renewed = true;
                            if (k.renew(arena, bearer orelse "")) continue;
                        };
                        return r.refused();
                    },
                    429 => {
                        if (!limited) {
                            limited = true;
                            if (try r.pause(st.retry_after_s, stop, deadline_ns)) continue;
                        }
                        return r.say(error.RateLimited, "{s} is rate limited; try again later.", .{r.name});
                    },
                    else => return r.statusFailure(arena, st),
                },
            }
        }
    }

    fn notifyLocked(r: *Remote, arena: Allocator, json: []const u8, stop: *const std.atomic.Value(bool), deadline_ns: i128) Error!void {
        var renewed = false;
        var connect_retry = false;
        while (true) {
            const bearer = try r.bearerNow(arena);
            const out = try r.exchange(arena, &r.post, .POST, json, null, bearer, stop, deadline_ns, false);
            switch (out) {
                .answer, .accepted => return,
                .unreached => |e| {
                    if (e == error.ConnectFailed and !connect_retry) {
                        connect_retry = true;
                        continue;
                    }
                    return r.unreached(e);
                },
                .status => |st| switch (st.code) {
                    401 => {
                        if (!renewed) if (r.keeper) |k| {
                            renewed = true;
                            if (k.renew(arena, bearer orelse "")) continue;
                        };
                        return r.refused();
                    },
                    else => return r.statusFailure(arena, st),
                },
            }
        }
    }

    /// A new session: initialize, initialized, and what was subscribed.
    fn restart(r: *Remote, arena: Allocator, stop: *const std.atomic.Value(bool), deadline_ns: i128) Error!void {
        r.setState("", "");
        r.session_gone.store(false, .release);
        const raw = try r.requestLocked(arena, "initialize", r.init_params, stop, deadline_ns, false);
        const v = jv.parse(arena, raw);
        if (jv.get(v, "result") == null) return r.say(error.BadAnswer, "{s} ended the session and did not start another", .{r.name});
        try r.notifyLocked(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", stop, deadline_ns);
        for (r.subscribed.items) |uri| {
            var params: std.ArrayList(u8) = .empty;
            try params.appendSlice(arena, "{\"uri\":");
            try util.jsonString(&params, arena, uri);
            try params.append(arena, '}');
            _ = r.requestLocked(arena, "resources/subscribe", params.items, stop, deadline_ns, false) catch |e| switch (e) {
                error.Said => {},
                else => return e,
            };
        }
    }

    /// The session and version `initialize` gave.
    fn takeSession(r: *Remote, arena: Allocator, ans: Answer) Error!void {
        const v = jv.parse(arena, ans.json);
        // an error: mcp.zig says the start failed
        const result = jv.get(v, "result") orelse return;
        const asked = jv.str(jv.get(result, "protocolVersion")) orelse "";
        const version = for (versions) |known| {
            if (std.mem.eql(u8, known, asked)) break known;
        } else return r.say(error.BadVersion, "{s} speaks MCP version {s}; harness speaks {s} and {s}", .{ r.name, util.cut(asked, 40), versions[0], versions[1] });
        const session = ans.session orelse "";
        if (session.len > max_session) return r.say(error.BadAnswer, "{s} gave a session id longer than {d} characters", .{ r.name, max_session });
        for (session) |c| if (c < 0x21 or c > 0x7e) return r.say(error.BadAnswer, "{s} gave a session id with characters that can't be sent back", .{r.name});
        r.setState(session, version);
    }

    const Answer = struct { json: []const u8, session: ?[]const u8 = null };

    const Status = struct {
        code: u16,
        body: []const u8,
        retry_after_s: ?u32 = null,
        location: []const u8 = "",
    };

    const Outcome = union(enum) {
        /// The response to the request.
        answer: Answer,
        /// A notification (or an answer to the server) taken.
        accepted,
        /// An answer that is no response.
        status: Status,
        /// The request could not be sent (`ConnectFailed`: not at all).
        unreached: anyerror,
    };

    /// One HTTP exchange. `want` is the request's id (null: a notification).
    fn exchange(r: *Remote, arena: Allocator, client: *http.Client, method: @FieldType(http.Request, "method"), body: ?[]const u8, want: ?u64, bearer: ?[]const u8, stop: *const std.atomic.Value(bool), deadline_ns: i128, initializing: bool) Error!Outcome {
        const left = msLeft(r.io, deadline_ns) orelse return error.Timeout;
        var sbuf: [max_session]u8 = undefined;
        var st = r.state(&sbuf);
        // initialize starts afresh
        if (initializing) st = .{ .session = "", .version = "" };
        var hs: [2 + 8]std.http.Header = undefined;
        var n = sessionHeaders(hs[0..2], st);
        for (r.headers[0..@min(r.headers.len, 8)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = client.send(.{
            .method = method,
            .path = r.path,
            .body = body,
            .key = bearer,
            .headers = hs[0..n],
            .accept = "application/json, text/event-stream",
            .keep = &.{"mcp-session-id"},
            .limits = .{ .idle_ms = left, .total_ms = left, .stop = stop },
        }) catch |e| {
            if (stop.load(.acquire)) return error.Stopped;
            return switch (e) {
                error.Timeout => error.Timeout,
                error.OutOfMemory => error.OutOfMemory,
                else => .{ .unreached = e },
            };
        };
        defer resp.deinit();
        switch (resp.status) {
            200 => {
                const ct = resp.contentType();
                if (startsWithIgnoreCase(ct, "text/event-stream")) {
                    const id = want orelse return .accepted;
                    const json = try r.readEvents(arena, &resp, id, stop);
                    return .{ .answer = .{ .json = json, .session = if (resp.kept[0]) |s| try arena.dupe(u8, s) else null } };
                }
                const id = want orelse return .accepted;
                if (!startsWithIgnoreCase(ct, "application/json")) return r.say(error.BadAnswer, "{s} answered with {s}, not JSON or an event stream", .{ r.name, if (ct.len == 0) "no Content-Type" else ct });
                const text = resp.readAll(arena, max_message) catch |e| return r.readFailed(e, stop);
                const json = (try responseTo(arena, text, id)) orelse return r.say(error.BadAnswer, "{s} answered something that is not the response to the request", .{r.name});
                return .{ .answer = .{ .json = json, .session = if (resp.kept[0]) |s| try arena.dupe(u8, s) else null } };
            },
            202, 204 => return if (want == null) .accepted else .accepted,
            else => {
                // what it says, a little of it
                const text = resp.readAll(arena, 64 << 10) catch "";
                return .{ .status = .{
                    .code = resp.status,
                    .body = text,
                    .retry_after_s = resp.retry_after_s,
                    .location = if (resp.location) |l| try arena.dupe(u8, l) else "",
                } };
            },
        }
    }

    /// Reads an event stream until the response to request `id`; the
    /// notifications and requests before it are handled.
    fn readEvents(r: *Remote, arena: Allocator, resp: *http.Response, id: u64, stop: *const std.atomic.Value(bool)) Error![]const u8 {
        var sse: Sse = .{ .gpa = r.gpa };
        defer sse.deinit();
        while (true) {
            const chunk = (resp.next() catch |e| return r.readFailed(e, stop)) orelse
                return r.say(error.BadAnswer, "{s}'s event stream ended before its answer", .{r.name});
            sse.push(chunk) catch return error.OutOfMemory;
            while (sse.next()) |ev| {
                if (!ev.message()) continue;
                // the event's data is the reader's: copied
                if (try responseTo(arena, ev.data, id)) |json| return try arena.dupe(u8, json);
                r.incoming(arena, ev.data, stop);
            }
        }
    }

    fn readFailed(r: *Remote, e: anyerror, stop: *const std.atomic.Value(bool)) Error {
        if (stop.load(.acquire)) return error.Stopped;
        return switch (e) {
            error.Timeout => error.Timeout,
            error.OutOfMemory => error.OutOfMemory,
            error.BadResponse => r.say(error.BadAnswer, "{s}'s answer is longer than {d} MB", .{ r.name, max_message >> 20 }),
            else => r.say(error.Unreachable, "{s} ended the connection before its answer ({s})", .{ r.name, @errorName(e) }),
        };
    }

    /// The server's own messages: a resource update is passed on, a
    /// request answered (ping, else "not supported"), the rest dropped.
    fn incoming(r: *Remote, arena: Allocator, data: []const u8, stop: ?*const std.atomic.Value(bool)) void {
        const v = jv.parse(arena, data) orelse return;
        const list: []const jv.Value = if (v == .array) v.array.items else &.{v};
        for (list) |msg| {
            if (msg != .object) continue;
            const method = jv.str(jv.get(msg, "method")) orelse continue;
            const idv = msg.object.get("id") orelse {
                if (std.mem.eql(u8, method, "notifications/resources/updated")) if (r.updated) |u| if (jv.str(jv.at(msg, &.{ "params", "uri" }))) |uri| u.f(u.ctx, r.name, uri);
                continue;
            };
            const id_json = std.json.Stringify.valueAlloc(arena, idv, .{}) catch continue;
            const reply = (if (std.mem.eql(u8, method, "ping"))
                std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_json})
            else
                std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{id_json})) catch continue;
            r.sideSend(arena, reply, stop, 5000);
        }
    }

    /// A message of harness's own to the server outside the request lock
    /// (an answer, a cancellation): one try within `ms`.
    fn sideSend(r: *Remote, arena: Allocator, json: []const u8, stop: ?*const std.atomic.Value(bool), ms: u32) void {
        r.side_mutex.lockUncancelable(r.io);
        defer r.side_mutex.unlock(r.io);
        const bearer = r.bearerNow(arena) catch return;
        var sbuf: [max_session]u8 = undefined;
        const st = r.state(&sbuf);
        var hs: [2 + 8]std.http.Header = undefined;
        var n = sessionHeaders(hs[0..2], st);
        for (r.headers[0..@min(r.headers.len, 8)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = r.side.send(.{
            .method = .POST,
            .path = r.path,
            .body = json,
            .key = bearer,
            .headers = hs[0..n],
            .accept = "application/json, text/event-stream",
            .limits = .{ .idle_ms = ms, .total_ms = ms, .stop = stop },
        }) catch return;
        resp.deinit();
    }

    /// Tells the server a request was given up (best effort, at most 0.5 s).
    fn cancel(r: *Remote, id: u64, reason: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{{\"requestId\":{d},\"reason\":\"{s}\"}}}}", .{ id, reason }) catch return;
        r.sideSend(a, msg, null, 500);
    }

    /// Waits as a 429 says (5 s when it doesn't, at most a minute); false
    /// when the wait would end past the deadline.
    fn pause(r: *Remote, retry_after_s: ?u32, stop: *const std.atomic.Value(bool), deadline_ns: i128) Error!bool {
        const wait_ns: i128 = @as(i128, @min(retry_after_s orelse 5, max_retry_wait_s)) * std.time.ns_per_s;
        const until = nowNs(r.io) + wait_ns;
        if (until >= deadline_ns) return false;
        while (nowNs(r.io) < until) {
            if (stop.load(.acquire)) return error.Stopped;
            r.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        if (stop.load(.acquire)) return error.Stopped;
        return true;
    }

    fn refused(r: *Remote) Error {
        return switch (r.auth) {
            .token => |tk| r.say(error.Refused, "{s} refused the token stored as {s}: store the right one with harness secret add {s}", .{ r.name, tk.name, tk.name }),
            .signin => blk: {
                if (r.keeper) |k| k.markRefused();
                break :blk r.say(error.Refused, "{s} refused the sign-in: harness mcp login {s}", .{ r.name, r.name });
            },
            .none => r.say(error.Refused, "{s} needs a sign-in: add login = oauth to [{s}] in mcp.ini, then harness mcp login {s} (or token = a stored secret)", .{ r.name, r.name, r.name }),
        };
    }

    fn unreached(r: *Remote, e: anyerror) Error {
        return switch (e) {
            error.CertificateRejected => r.say(error.Unreachable, "{s} could not be reached: its https certificate was not accepted", .{r.name}),
            error.ConnectionClosed => r.say(error.Unreachable, "{s} ended the connection before its answer", .{r.name}),
            else => r.say(error.Unreachable, "{s} could not be reached ({s})", .{ r.name, @errorName(e) }),
        };
    }

    fn statusFailure(r: *Remote, arena: Allocator, st: Status) Error {
        const d = detail(arena, st.body);
        const sep: []const u8 = if (d.len > 0) ": " else "";
        return switch (st.code) {
            300...399 => r.say(error.Redirected, "{s} answered {d}, a redirect to {s}, which harness does not follow: put the address it gives in mcp.ini", .{ r.name, st.code, if (st.location.len > 0) util.cut(st.location, 200) else "(none given)" }),
            403 => r.say(error.Refused, "{s} refused the request (403){s}{s}", .{ r.name, sep, d }),
            404 => r.say(error.NotFound, "{s} answered 404: there is no MCP server at {s}", .{ r.name, r.url }),
            500...599 => r.say(error.Upstream, "{s} had an upstream error ({d}){s}{s}", .{ r.name, st.code, sep, d }),
            else => r.say(error.Refused, "{s} refused the request ({d}){s}{s}", .{ r.name, st.code, sep, d }),
        };
    }

    // ---- the GET stream ----

    fn streamLoop(r: *Remote) void {
        var client = http.Client.init(r.gpa, r.io, r.target);
        defer client.deinit();
        var last_id: std.ArrayList(u8) = .empty;
        defer last_id.deinit(r.gpa);
        var wait_ms: u32 = r.backoff_ms;
        while (!r.stream_stop.load(.acquire)) {
            const opened = nowNs(r.io);
            const how = r.streamOnce(&client, &last_id);
            if (r.stream_stop.load(.acquire)) return;
            switch (how) {
                // this server keeps no stream
                .not_offered => return,
                // a stream that stayed open a while starts the waits afresh
                .ended => |retry| {
                    if (nowNs(r.io) - opened > 30 * std.time.ns_per_s) wait_ms = r.backoff_ms;
                    if (retry) |ms| wait_ms = @max(ms, 10);
                },
                .failed => {},
            }
            const until = nowNs(r.io) + @as(i128, wait_ms) * std.time.ns_per_ms;
            while (nowNs(r.io) < until and !r.stream_stop.load(.acquire)) r.io.sleep(.fromMilliseconds(10), .awake) catch {};
            wait_ms = @min(wait_ms *| 2, 60_000);
        }
    }

    const StreamEnd = union(enum) { not_offered, failed, ended: ?u32 };

    fn streamOnce(r: *Remote, client: *http.Client, last_id: *std.ArrayList(u8)) StreamEnd {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const stop = &r.stream_stop;
        const bearer = r.bearerNow(a) catch return .failed;
        var sbuf: [max_session]u8 = undefined;
        const st = r.state(&sbuf);
        var hs: [3 + 8]std.http.Header = undefined;
        var n = sessionHeaders(hs[0..2], st);
        if (last_id.items.len > 0) {
            hs[n] = .{ .name = "Last-Event-ID", .value = last_id.items };
            n += 1;
        }
        for (r.headers[0..@min(r.headers.len, 8)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = client.send(.{
            .method = .GET,
            .path = r.path,
            .key = bearer,
            .headers = hs[0..n],
            .accept = "text/event-stream",
            .limits = .{ .idle_ms = stream_idle_ms, .stop = stop },
        }) catch return .failed;
        defer resp.deinit();
        switch (resp.status) {
            200 => {},
            405 => return .not_offered,
            404 => {
                // the session ended: the next request starts another
                if (st.session.len > 0) r.session_gone.store(true, .release);
                return .failed;
            },
            401 => {
                if (r.keeper) |k| _ = k.renew(a, bearer orelse "");
                return .failed;
            },
            else => return .failed,
        }
        if (!startsWithIgnoreCase(resp.contentType(), "text/event-stream")) return .failed;
        _ = r.streams.fetchAdd(1, .acq_rel);
        var sse: Sse = .{ .gpa = r.gpa };
        defer sse.deinit();
        while (true) {
            const chunk = (resp.next() catch break) orelse break;
            sse.push(chunk) catch break;
            while (sse.next()) |ev| {
                if (sse.id_set) {
                    last_id.clearRetainingCapacity();
                    last_id.appendSlice(r.gpa, sse.lastId()) catch {};
                    sse.id_set = false;
                }
                if (!ev.message()) continue;
                var ev_arena: std.heap.ArenaAllocator = .init(r.gpa);
                defer ev_arena.deinit();
                r.incoming(ev_arena.allocator(), ev.data, stop);
            }
        }
        return .{ .ended = sse.retry_ms };
    }
};

/// A store whose name or folder is in `a`.
fn storeCopy(a: Allocator, st: store_mod.Store) !store_mod.Store {
    return switch (st) {
        .dir => |d| .{ .dir = try a.dupe(u8, d) },
        .keychain => |ns| .{ .keychain = try a.dupe(u8, ns) },
        .wincred => |ns| .{ .wincred = try a.dupe(u8, ns) },
    };
}

/// The JSON-RPC response with id `id` in `text` (an object, or a batch
/// of them); null when it isn't there.
fn responseTo(arena: Allocator, text: []const u8, id: u64) Error!?[]const u8 {
    const v = jv.parse(arena, text) orelse return null;
    const list: []const jv.Value = if (v == .array) v.array.items else &.{v};
    for (list) |msg| {
        if (msg != .object or msg.object.get("method") != null) continue;
        const got = jv.int(jv.get(msg, "id")) orelse continue;
        if (got != id) continue;
        if (jv.get(msg, "result") == null and jv.get(msg, "error") == null) continue;
        if (list.len == 1) return text;
        return try std.json.Stringify.valueAlloc(arena, msg, .{});
    }
    return null;
}

/// What an error answer says: a JSON-RPC error's message, an OAuth
/// error's description, else its first line (200 bytes at most).
fn detail(arena: Allocator, body: []const u8) []const u8 {
    const v = jv.parse(arena, body);
    if (jv.str(jv.at(v, &.{ "error", "message" }))) |m| return util.cut(m, 200);
    if (jv.str(jv.get(v, "error_description"))) |m| return util.cut(m, 200);
    if (jv.str(jv.get(v, "message"))) |m| return util.cut(m, 200);
    if (jv.str(jv.get(v, "error"))) |m| return util.cut(m, 200);
    if (v != null) return "";
    const line = std.mem.trim(u8, body[0 .. std.mem.indexOfAny(u8, body, "\r\n") orelse body.len], " \t");
    return util.cut(line, 200);
}

/// Milliseconds until `deadline_ns` (awake clock), at least 1; null once
/// it has passed.
fn msLeft(io: Io, deadline_ns: i128) ?u32 {
    const left = @divFloor(deadline_ns - nowNs(io), std.time.ns_per_ms);
    if (left <= 0) return null;
    return @intCast(@min(left, std.math.maxInt(u32)));
}

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, prefix);
}

/// Reads a text/event-stream as it arrives: `push` what came, then `next`
/// until null. Lines end in CRLF, LF or CR; a `data` longer than
/// `max_message` is dropped.
pub const Sse = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Where `next` goes on in `buf`.
    pos: usize = 0,
    /// The line before ended in CR: an LF now belongs to it.
    skip_lf: bool = false,
    data: std.ArrayList(u8) = .empty,
    too_big: bool = false,
    kind_buf: [32]u8 = undefined,
    kind_len: usize = 0,
    id_buf: [256]u8 = undefined,
    id_len: usize = 0,
    /// An `id:` line came since this was last cleared.
    id_set: bool = false,
    retry_ms: ?u32 = null,
    /// The event `next` returned (its data, until the next call).
    out: std.ArrayList(u8) = .empty,

    pub const Event = struct {
        kind: []const u8,
        data: []const u8,

        /// A JSON-RPC message (no `event:`, or `event: message`).
        pub fn message(e: Event) bool {
            return e.kind.len == 0 or std.mem.eql(u8, e.kind, "message");
        }
    };

    pub fn deinit(s: *Sse) void {
        s.buf.deinit(s.gpa);
        s.data.deinit(s.gpa);
        s.out.deinit(s.gpa);
    }

    pub fn push(s: *Sse, bytes: []const u8) !void {
        // what was read is dropped first
        if (s.pos > 0) {
            const rest = s.buf.items.len - s.pos;
            std.mem.copyForwards(u8, s.buf.items[0..rest], s.buf.items[s.pos..]);
            s.buf.shrinkRetainingCapacity(rest);
            s.pos = 0;
        }
        try s.buf.appendSlice(s.gpa, bytes);
    }

    pub fn lastId(s: *const Sse) []const u8 {
        return s.id_buf[0..s.id_len];
    }

    pub fn next(s: *Sse) ?Event {
        while (true) {
            var rest = s.buf.items[s.pos..];
            if (s.skip_lf and rest.len > 0) {
                s.skip_lf = false;
                if (rest[0] == '\n') {
                    s.pos += 1;
                    rest = rest[1..];
                }
            }
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse return null;
            const line = rest[0..end];
            s.pos += end + 1;
            if (rest[end] == '\r') s.skip_lf = true;
            if (line.len == 0) {
                // the end of an event
                const had = s.data.items.len > 0 and !s.too_big;
                s.too_big = false;
                if (!had) {
                    s.data.clearRetainingCapacity();
                    s.kind_len = 0;
                    continue;
                }
                s.out.clearRetainingCapacity();
                s.out.appendSlice(s.gpa, s.data.items[0 .. s.data.items.len - 1]) catch {
                    s.data.clearRetainingCapacity();
                    continue;
                };
                s.data.clearRetainingCapacity();
                const kind = s.kind_buf[0..s.kind_len];
                s.kind_len = 0;
                return .{ .kind = kind, .data = s.out.items };
            }
            if (line[0] == ':') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':');
            const field = line[0 .. colon orelse line.len];
            var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (std.mem.eql(u8, field, "data")) {
                if (s.too_big or s.data.items.len + value.len + 1 > max_message) {
                    s.too_big = true;
                    s.data.clearRetainingCapacity();
                    continue;
                }
                s.data.appendSlice(s.gpa, value) catch {
                    s.too_big = true;
                    continue;
                };
                s.data.append(s.gpa, '\n') catch {
                    s.too_big = true;
                };
            } else if (std.mem.eql(u8, field, "event")) {
                const n = @min(value.len, s.kind_buf.len);
                @memcpy(s.kind_buf[0..n], value[0..n]);
                s.kind_len = n;
            } else if (std.mem.eql(u8, field, "id")) {
                if (std.mem.indexOfScalar(u8, value, 0) == null and value.len <= s.id_buf.len) {
                    @memcpy(s.id_buf[0..value.len], value);
                    s.id_len = value.len;
                    s.id_set = true;
                }
            } else if (std.mem.eql(u8, field, "retry")) {
                s.retry_ms = std.fmt.parseInt(u32, value, 10) catch s.retry_ms;
            }
        }
    }
};

// ---- tests ----

const t = std.testing;
const mcp = @import("mcp.zig");
const model = @import("model.zig");

/// The stand-in (fake.zig) with its MCP servers at /mcp/FLAVOR.
const Fx = struct {
    e: model.TestEnv,
    stop: std.atomic.Value(bool) = .init(false),

    fn init(f: *Fx) !void {
        try f.e.init();
        f.stop = .init(false);
    }

    fn deinit(f: *Fx) void {
        f.e.deinit();
    }

    fn a(f: *Fx) Allocator {
        return f.e.arena.allocator();
    }

    fn url(f: *Fx, flavor: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.a(), "http://127.0.0.1:{d}/mcp/{s}", .{ f.e.server.port, flavor });
    }

    const Extra = struct {
        auth: Auth = .none,
        headers: []const std.http.Header = &.{},
        diag: ?*mcp.Diag = null,
        updated: ?mcp.Updated = null,
    };

    fn start(f: *Fx, flavor: []const u8, x: Extra) !*mcp.Server {
        return mcp.Server.start(t.allocator, t.io, .{ .name = "web", .command = "", .url = try f.url(flavor), .headers = x.headers, .secrets = &.{}, .money = &.{} }, .{
            .cwd = "",
            .path_var = "",
            .home = "",
            .secret_values = &.{},
            .start_timeout_ms = 10000,
            .auth = x.auth,
            .diag = x.diag,
            .updated = x.updated,
            .stream_backoff_ms = 100,
        });
    }

    fn call(f: *Fx, s: *mcp.Server, tool: []const u8, args: []const u8) !mcp.Result {
        return s.call(f.a(), tool, args, &f.stop, 10000, 4096);
    }

    /// What the stand-in's MCP routes were sent, a JSON line each.
    fn requests(f: *Fx) ![]const u8 {
        return f.e.tmp.dir.readFileAlloc(t.io, "mcp-requests.jsonl", f.a(), .unlimited) catch "";
    }
};

/// What `updated` was told, for the tests.
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

    fn waitFor(u: *Updates, n: u32) !void {
        var waited: u32 = 0;
        while (u.n.load(.acquire) < n and waited < 5000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
        if (u.n.load(.acquire) < n) std.debug.print("{d} updates after 5 s, not {d}\n", .{ u.n.load(.acquire), n });
        try t.expect(u.n.load(.acquire) >= n);
    }
};

/// Waits up to 5 s for `v` to reach `n`.
fn waitCount(v: *std.atomic.Value(u32), n: u32, what: []const u8) !void {
    var waited: u32 = 0;
    while (v.load(.acquire) < n and waited < 5000) : (waited += 20) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    if (v.load(.acquire) < n) std.debug.print("{s}: {d} after 5 s, not {d}\n", .{ what, v.load(.acquire), n });
    try t.expect(v.load(.acquire) >= n);
}

fn nowMs() i64 {
    return @intCast(@divFloor(nowNs(t.io), std.time.ns_per_ms));
}

test "json_and_event_stream_answers_list_and_call_tools" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "json", "sse" }) |flavor| {
        const s = try f.start(flavor, .{});
        defer s.deinit();
        try t.expectEqual(3, s.tools().len);
        try t.expectEqualStrings("echo", s.tools()[0].name);
        try t.expectEqualStrings("web", s.tools()[0].server);
        try t.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}", s.tools()[0].schema_json);
        const r = try f.call(s, "echo", "{\"text\":\"hello\\nworld\"}");
        try t.expect(!r.is_error);
        try t.expectEqualStrings("hello\nworld", r.text);
        const bad = try f.call(s, "fail", "{}");
        try t.expect(bad.is_error);
        try t.expectEqualStrings("it failed", bad.text);
        // in an event stream the server's ping came before each answer:
        // answered, on a request of its own
        if (std.mem.eql(u8, flavor, "sse")) try t.expectEqualStrings("yes", (try f.call(s, "echo", "{\"text\":\"pinged\"}")).text);
    }
    // every request after initialize carries the session and the version,
    // and takes both kinds of answer
    const log = try f.requests();
    try t.expect(std.mem.indexOf(u8, log, "\"Accept\":\"application/json, text/event-stream\"") != null);
    try t.expect(std.mem.indexOf(u8, log, "\"MCP-Protocol-Version\":\"2025-06-18\"") != null);
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    var calls: u32 = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "tools/call") == null) continue;
        calls += 1;
        try t.expect(std.mem.indexOf(u8, line, "\"Mcp-Session-Id\":\"") != null);
    }
    try t.expectEqual(5, calls);
}

test "a_session_that_ended_is_started_again" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.start("json", .{});
    defer s.deinit();
    try s.subscribe(f.a(), "fake://res.txt", &f.stop, 5000);
    try t.expectEqualStrings("one", (try f.call(s, "echo", "{\"text\":\"one\"}")).text);
    try t.expectEqual(1, f.e.server.mcp.initializes.load(.acquire));
    // the server forgets the session: the call is answered in a new one,
    // which watches what the old one did
    f.e.server.mcp.endSessions();
    try t.expectEqualStrings("two", (try f.call(s, "echo", "{\"text\":\"two\"}")).text);
    try t.expectEqual(2, f.e.server.mcp.initializes.load(.acquire));
    try t.expect(f.e.server.mcp.subscribedIn("fake://res.txt") >= 2);
    // only once a call: a session that ends again fails the call, said
    f.e.server.mcp.end_always.store(true, .release);
    const r = try f.call(s, "echo", "{\"text\":\"three\"}");
    try t.expect(r.is_error);
    try t.expect(std.mem.startsWith(u8, r.text, "web answered 404"));
    try t.expectEqual(3, f.e.server.mcp.initializes.load(.acquire));
}

test "resource_updates_arrive_over_the_event_stream" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var ups: Updates = .{};
    const s = try f.start("json", .{ .updated = .{ .ctx = &ups, .f = Updates.note } });
    defer s.deinit();
    try t.expect(s.subscribes);
    try waitCount(&f.e.server.mcp.streams, 1, "streams opened");
    try s.subscribe(f.a(), "fake://res.txt", &f.stop, 5000);
    // the server says it changed on its stream, not in the call's answer
    try t.expectEqualStrings("notified", (try f.call(s, "echo", "{\"text\":\"notify:fake://res.txt\"}")).text);
    try ups.waitFor(1);
    try t.expectEqualStrings("fake://res.txt", ups.buf[0..ups.len]);
    // the stream ends: it is opened again (with its last event id) and
    // the next update comes on it
    f.e.server.mcp.dropStreams();
    try waitCount(&f.e.server.mcp.streams, 2, "streams opened");
    try t.expect(std.mem.indexOf(u8, try f.requests(), "\"Last-Event-ID\":\"") != null);
    _ = try f.call(s, "echo", "{\"text\":\"notify:fake://res.txt\"}");
    try ups.waitFor(2);
    // a server that keeps no stream (405) is not asked again
    const quiet = try f.start("nostream", .{ .updated = .{ .ctx = &ups, .f = Updates.note } });
    defer quiet.deinit();
    try waitCount(&f.e.server.mcp.refused_gets, 1, "GETs refused");
    t.io.sleep(.fromMilliseconds(500), .awake) catch {};
    try t.expectEqual(1, f.e.server.mcp.refused_gets.load(.acquire));
}

test "a_2025_03_26_server_is_taken_and_another_version_refused" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.start("old", .{});
    defer s.deinit();
    try t.expectEqualStrings("old one", (try f.call(s, "echo", "{\"text\":\"old one\"}")).text);
    try t.expect(std.mem.indexOf(u8, try f.requests(), "\"MCP-Protocol-Version\":\"2025-03-26\"") != null);
    var diag: mcp.Diag = .{};
    try t.expectError(error.BadVersion, f.start("future", .{ .diag = &diag }));
    try t.expectEqualStrings("web speaks MCP version 2099-01-01; harness speaks 2025-06-18 and 2025-03-26", diag.text());
}

test "errors_name_the_server_and_what_to_do" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const good = "mcp-test-token-1";
    // a token the server refuses: named, never shown (the server says it back)
    var diag: mcp.Diag = .{};
    try t.expectError(error.Refused, f.start("token", .{ .auth = .{ .token = .{ .name = "web-token", .value = "wrong-token-value-9" } }, .diag = &diag }));
    try t.expectEqualStrings("web refused the token stored as web-token: store the right one with harness secret add web-token", diag.text());
    const s = try f.start("token", .{ .auth = .{ .token = .{ .name = "web-token", .value = good } } });
    defer s.deinit();
    const m = &f.e.server.mcp;
    // 403, with the token said back: masked
    m.failNext(.{ .status = 403, .echo_auth = true });
    const forbidden = try f.call(s, "echo", "{\"text\":\"x\"}");
    try t.expect(forbidden.is_error);
    try t.expectEqualStrings("web refused the request (403): forbidden for Bearer [secret:web-token]", forbidden.text);
    // 429: waited as told, once
    m.failNext(.{ .status = 429, .retry_after = 1 });
    const t0 = nowMs();
    try t.expectEqualStrings("after a wait", (try f.call(s, "echo", "{\"text\":\"after a wait\"}")).text);
    try t.expect(nowMs() - t0 >= 900);
    m.failNext(.{ .status = 429, .retry_after = 1, .count = 2 });
    try t.expectEqualStrings("web is rate limited; try again later.", (try f.call(s, "echo", "{\"text\":\"x\"}")).text);
    // 5xx
    m.failNext(.{ .status = 502 });
    try t.expectEqualStrings("web had an upstream error (502): scripted failure", (try f.call(s, "echo", "{\"text\":\"x\"}")).text);
    // a redirect is not followed
    m.failNext(.{ .status = 307, .location = "https://elsewhere.example/mcp" });
    try t.expectEqualStrings("web answered 307, a redirect to https://elsewhere.example/mcp, which harness does not follow: put the address it gives in mcp.ini", (try f.call(s, "echo", "{\"text\":\"x\"}")).text);
    // still fine after all that
    try t.expectEqualStrings("fine", (try f.call(s, "echo", "{\"text\":\"fine\"}")).text);
    // no server there, and none signed in to
    try t.expectError(error.NotFound, f.start("nowhere", .{ .diag = &diag }));
    try t.expect(std.mem.startsWith(u8, diag.text(), "web answered 404: there is no MCP server at http://127.0.0.1:"));
    try t.expectError(error.Refused, f.start("token", .{ .diag = &diag }));
    try t.expect(std.mem.startsWith(u8, diag.text(), "web needs a sign-in: add login = oauth to [web] in mcp.ini"));
    // the header lines reach the server
    const h = try f.start("json", .{ .headers = &.{ .{ .name = "X-Team", .value = "tools" }, .{ .name = "X-Region", .value = "eu" } } });
    defer h.deinit();
    const log = try f.requests();
    try t.expect(std.mem.indexOf(u8, log, "\"X-Team\":\"tools\",\"X-Region\":\"eu\"") != null);
    try t.expect(std.mem.indexOf(u8, log, "\"Authorization\":\"Bearer " ++ good ++ "\"") != null);
}

fn stopLater(flag: *std.atomic.Value(bool)) void {
    t.io.sleep(.fromMilliseconds(300), .awake) catch {};
    flag.store(true, .release);
}

test "stop_and_the_deadline_end_an_http_call" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "json", "sse" }) |flavor| {
        f.stop.store(false, .release);
        const s = try f.start(flavor, .{});
        defer s.deinit();
        const th = try std.Thread.spawn(.{}, stopLater, .{&f.stop});
        const t0 = nowMs();
        const r = s.call(f.a(), "sleep", "{\"ms\":10000}", &f.stop, 30000, 4096);
        th.join();
        const took = nowMs() - t0;
        if (took >= 1500) std.debug.print("{s}: a call stopped after 300 ms took {d} ms\n", .{ flavor, took });
        try t.expectError(error.Stopped, r);
        try t.expect(took < 1500);
        f.stop.store(false, .release);
        const t1 = nowMs();
        try t.expectError(error.Timeout, s.call(f.a(), "sleep", "{\"ms\":3000}", &f.stop, 200, 4096));
        const timed = nowMs() - t1;
        if (timed >= 1500) std.debug.print("{s}: a call with 200 ms took {d} ms\n", .{ flavor, timed });
        try t.expect(timed < 1500);
        // the next call gets its own answer
        try t.expectEqualStrings("mine", (try f.call(s, "echo", "{\"text\":\"mine\"}")).text);
    }
    // the server was told what was given up
    try t.expect(std.mem.indexOf(u8, try f.requests(), "notifications/cancelled") != null);
}

test "the_session_is_deleted_on_stop" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const one = try f.start("json", .{});
    one.deinit();
    try t.expectEqual(1, f.e.server.mcp.deleted.load(.acquire));
    try t.expect(std.mem.indexOf(u8, try f.requests(), "\"method\":\"DELETE\"") != null);
    // stopped together with programs
    const fake = try Io.Dir.cwd().realPathFileAlloc(t.io, @import("build_options").fake_path, f.a());
    var list: [3]*mcp.Server = undefined;
    list[0] = try f.start("json", .{});
    list[1] = try f.start("sse", .{});
    list[2] = try mcp.Server.start(t.allocator, t.io, .{ .name = "prog", .command = try std.fmt.allocPrint(f.a(), "\"{s}\" --mcp", .{fake}), .secrets = &.{}, .money = &.{} }, .{
        .cwd = f.e.dir,
        .path_var = "/usr/bin:/bin",
        .home = "/tmp",
        .secret_values = &.{},
        .start_timeout_ms = 10000,
    });
    const t0 = nowMs();
    mcp.stopAll(&list);
    const took = nowMs() - t0;
    if (took >= 1500) std.debug.print("stopping two servers at a url and a program took {d} ms\n", .{took});
    try t.expect(took < 1500);
    try t.expectEqual(3, f.e.server.mcp.deleted.load(.acquire));
}

test "an_event_stream_is_read_whatever_its_line_ends" {
    var s: Sse = .{ .gpa = t.allocator };
    defer s.deinit();
    // CRLF, CR and LF; a comment; two data lines; split anywhere
    const text = ": hello\r\nevent: message\r\ndata: {\"a\":\r\ndata: 1}\r\nid: 7\r\n\r\ndata: two\r\rdata: three\n\nretry: 250\nevent: other\ndata: x\n\n";
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |g| t.allocator.free(g);
        got.deinit(t.allocator);
    }
    for (text) |c| {
        try s.push(&.{c});
        while (s.next()) |ev| try got.append(t.allocator, try std.fmt.allocPrint(t.allocator, "{s}|{s}", .{ ev.kind, ev.data }));
    }
    try t.expectEqual(4, got.items.len);
    try t.expectEqualStrings("message|{\"a\":\n1}", got.items[0]);
    try t.expectEqualStrings("|two", got.items[1]);
    try t.expectEqualStrings("|three", got.items[2]);
    try t.expectEqualStrings("other|x", got.items[3]);
    try t.expectEqualStrings("7", s.lastId());
    try t.expectEqual(250, s.retry_ms.?);
}

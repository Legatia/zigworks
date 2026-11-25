//! The app server (gap 8): apps (apps.zig) and harness's page around them,
//! on 127.0.0.1 alone, entered by links that hold a token made at each
//! start: the shell's (`/s/TOKEN/`) and each app's (`/a/TOKEN/`, an HMAC of
//! its name and version under the start's key). An app is shown in a
//! sandboxed frame of the shell with an opaque origin; it can't reach the
//! shell, another app, cookies or storage, and its responses carry a CSP
//! that keeps every load on this server. Requests whose Host isn't
//! 127.0.0.1:PORT (DNS rebinding) or whose Origin is another site are
//! refused; app HTML is served only into a frame. The API apps read and
//! act through (`api/`) comes after this; its paths answer 404 for now.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sock = @import("sock.zig");
const apps = @import("apps.zig");
const log_mod = @import("log.zig");
const deskwin = @import("deskwin.zig");
const config = @import("config.zig");

pub const Options = struct {
    /// DATA/apps.
    apps_dir: []const u8,
    /// DATA/state/apps.
    state_dir: []const u8,
    /// 0: a free one.
    port: u16 = 0,
    log: ?*log_mod.Log = null,
    /// harness's own: the built-in apps' version.
    version: []const u8,
    /// What answers the apps' API and the bar; null: both answer 404.
    host: ?Host = null,
    /// The desk (harness's own window); null: its paths answer 404.
    desk: ?DeskOptions = null,
};

/// Where the desk's files and entry are.
pub const DeskOptions = struct {
    /// DATA: `avatars/` and `desk-assets/` are served from it.
    home: []const u8,
    /// DATA/state: `open-request` and `desk-code`.
    state: []const u8,
};

/// One call of the desk's API (`/desk/api/PATH`), its session checked.
pub const DeskCall = struct {
    method: std.http.Method,
    /// After `/desk/api/`.
    path: []const u8,
    query: []const u8,
    body: []const u8,
    content_type: []const u8 = "",
    /// Set when the server stops: a long-poll ends.
    stop: *const std.atomic.Value(bool),
};

/// One call of an app's API (`/a/TOKEN/api/PATH`).
pub const Call = struct {
    app: []const u8,
    version: []const u8,
    builtin: bool,
    method: std.http.Method,
    /// After `api/`.
    path: []const u8,
    query: []const u8,
    body: []const u8,
    /// Set when the server stops: a call that waits ends.
    stop: *const std.atomic.Value(bool),
};

/// One call of harness's own page (`/s/TOKEN/api/PATH`): the bar's.
pub const ShellCall = struct {
    method: std.http.Method,
    path: []const u8,
    query: []const u8,
    body: []const u8,
};

pub const Answer = struct {
    status: std.http.Status = .ok,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

/// Who answers the calls: the core. Its answers are in `a`.
pub const Host = struct {
    ctx: *anyopaque,
    api: *const fn (ctx: *anyopaque, a: std.mem.Allocator, call: Call) Answer,
    shell: *const fn (ctx: *anyopaque, a: std.mem.Allocator, call: ShellCall) Answer,
    /// An app's page went into a frame.
    opened: *const fn (ctx: *anyopaque, name: []const u8, version: []const u8) void,
    /// The desk's API; null: it answers 404.
    desk: ?*const fn (ctx: *anyopaque, a: std.mem.Allocator, call: DeskCall) Answer = null,
};

/// The longest body a call may carry.
pub const max_body: usize = 1 << 20;
/// The desk's voice and upload paths take this much.
pub const max_desk_body: usize = 10 << 20;
/// The largest avatar or fit file served.
pub const max_desk_file: u64 = 20 << 20;

/// The desk's page and its files, in the binary (`/desk/static/F`).
pub const desk_files = [_][2][]const u8{
    .{ "index.html", @embedFile("desk/index.html") },
    .{ "desk.css", @embedFile("desk/desk.css") },
    .{ "desk.js", @embedFile("desk/desk.js") },
    .{ "avatar.js", @embedFile("desk/avatar.js") },
    .{ "fit.js", @embedFile("desk/fit.js") },
    .{ "vendor/three.module.min.js", @embedFile("desk/vendor/three.module.min.js") },
    .{ "fonts/chakra-petch-latin-400-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-400-normal.woff2") },
    .{ "fonts/chakra-petch-latin-500-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-500-normal.woff2") },
    .{ "fonts/chakra-petch-latin-600-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-600-normal.woff2") },
    .{ "fonts/chakra-petch-latin-700-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-700-normal.woff2") },
    .{ "fonts/chakra-petch-latin-ext-400-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-ext-400-normal.woff2") },
    .{ "fonts/chakra-petch-latin-ext-500-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-ext-500-normal.woff2") },
    .{ "fonts/chakra-petch-latin-ext-600-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-ext-600-normal.woff2") },
    .{ "fonts/chakra-petch-latin-ext-700-normal.woff2", @embedFile("desk/fonts/chakra-petch-latin-ext-700-normal.woff2") },
    .{ "fonts/jetbrains-mono-latin-400-normal.woff2", @embedFile("desk/fonts/jetbrains-mono-latin-400-normal.woff2") },
    .{ "fonts/jetbrains-mono-latin-500-normal.woff2", @embedFile("desk/fonts/jetbrains-mono-latin-500-normal.woff2") },
    .{ "fonts/jetbrains-mono-latin-ext-400-normal.woff2", @embedFile("desk/fonts/jetbrains-mono-latin-ext-400-normal.woff2") },
    .{ "fonts/jetbrains-mono-latin-ext-500-normal.woff2", @embedFile("desk/fonts/jetbrains-mono-latin-ext-500-normal.woff2") },
    .{ "fonts/OFL-chakra-petch.txt", @embedFile("desk/fonts/OFL-chakra-petch.txt") },
    .{ "fonts/OFL-jetbrains-mono.txt", @embedFile("desk/fonts/OFL-jetbrains-mono.txt") },
};

fn deskFile(rel: []const u8) ?[]const u8 {
    for (desk_files) |f| if (std.mem.eql(u8, f[0], rel)) return f[1];
    return null;
}

/// The apps in the binary, read-only; fork one to change it.
pub const builtins = [_]Builtin{
    .{ .name = "inbox", .title = "Inbox", .files = &.{
        .{ "index.html", @embedFile("apps/inbox/index.html") },
        .{ "app.js", @embedFile("apps/inbox/app.js") },
        .{ "style.css", @embedFile("apps/common/style.css") },
    } },
    .{ .name = "log", .title = "Log", .files = &.{
        .{ "index.html", @embedFile("apps/log/index.html") },
        .{ "app.js", @embedFile("apps/log/app.js") },
        .{ "style.css", @embedFile("apps/common/style.css") },
    } },
    .{ .name = "files", .title = "Files", .files = &.{
        .{ "index.html", @embedFile("apps/files/index.html") },
        .{ "app.js", @embedFile("apps/files/app.js") },
        .{ "style.css", @embedFile("apps/common/style.css") },
    } },
};

pub const Builtin = struct {
    name: []const u8,
    title: []const u8,
    files: []const [2][]const u8,

    fn file(b: Builtin, rel: []const u8) ?[]const u8 {
        for (b.files) |f| if (std.mem.eql(u8, f[0], rel)) return f[1];
        return null;
    }
};

const shell_css = @embedFile("apps/common/shell.css");
const shell_js = @embedFile("apps/common/shell.js");

/// What a draft's API answers: it is shown, and reads and does nothing.
const draft_api = "{\"error\":\"a draft being reviewed reads nothing and asks harness for nothing\"}";

/// What every refusal of a link says: an old start's token and an unknown
/// one alike.
const old_link = "This link is from an earlier start of harness. Ask for the app again.";

const Refusal = enum { host, origin, token, frame, desk };

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    apps_dir: []u8,
    state_dir: []u8,
    version: []u8,
    log: ?*log_mod.Log,
    host: ?Host,
    listener: sock.Listener,
    port: u16,
    /// This start's: the apps' tokens are HMACs under it.
    key: [32]u8,
    shell_token: [22]u8,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    mutex: Io.Mutex = .init,
    open: std.ArrayList(sock.Handle) = .empty,
    /// When a refusal of each kind was last logged (one a minute).
    last_refusal_ms: [5]i64 = @splat(-std.math.maxInt(i32)),
    /// The desk: DATA and DATA/state ("": off), its code and sessions, and
    /// the thread that answers `state/open-request`.
    desk_home: []u8 = &.{},
    desk_state: []u8 = &.{},
    codes: deskwin.Codes = .{},
    sessions: deskwin.Sessions = .{},
    desk_thread: ?std.Thread = null,

    const max_connections = 32;
    const idle_ms = 30 * 1000;

    pub fn start(gpa: std.mem.Allocator, io: Io, o: Options) !*Server {
        const listener = try sock.Listener.openExclusive(o.port);
        errdefer listener.close();
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .apps_dir = try gpa.dupe(u8, o.apps_dir),
            .state_dir = try gpa.dupe(u8, o.state_dir),
            .version = try gpa.dupe(u8, o.version),
            .log = o.log,
            .host = o.host,
            .listener = listener,
            .port = listener.port,
            .key = undefined,
            .shell_token = undefined,
        };
        try io.randomSecure(&s.key);
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&s.shell_token, &raw);
        if (o.desk) |d| {
            s.desk_home = try gpa.dupe(u8, d.home);
            s.desk_state = try gpa.dupe(u8, d.state);
            s.desk_thread = try std.Thread.spawn(.{}, deskLoop, .{s});
        }
        if (s.log) |l| l.write(.app, false, .{ .event = "server started", .port = s.port }) catch {};
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
    }

    /// Every 200 ms: a request for a code (`state/open-request`, written by
    /// the desk app) is taken and a code written to `state/desk-code`; a
    /// code past its 60 s goes.
    fn deskLoop(s: *Server) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const request = std.fs.path.join(a, &.{ s.desk_state, "open-request" }) catch return;
        const code = std.fs.path.join(a, &.{ s.desk_state, "desk-code" }) catch return;
        while (!s.stopping.load(.acquire)) {
            const now = Io.Clock.awake.now(s.io).toMilliseconds();
            if (Io.Dir.cwd().statFile(s.io, request, .{})) |_| {
                Io.Dir.cwd().deleteFile(s.io, request) catch {};
                if (s.codes.issue(s.io, code, @intCast(now))) |_| {
                    if (s.log) |l| l.write(.app, false, .{ .event = "desk code written" }) catch {};
                } else |e| if (s.log) |l| l.write(.app, false, .{ .event = "desk code not written", .why = @errorName(e) }) catch {};
            } else |_| {}
            s.codes.expire(s.io, code, @intCast(now));
            s.io.sleep(.fromMilliseconds(200), .awake) catch {};
        }
        // a code nobody took goes with this start
        s.codes.expire(s.io, code, std.math.maxInt(i64));
    }

    /// Ends within 2 s, connections kept open by browsers too.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        if (sock.connect(s.io, "127.0.0.1", s.port, 1000)) |c| sock.closeHandle(c) else |_| {}
        if (s.thread) |th| th.join();
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.open.items) |c| sock.shutdown(c);
        }
        if (s.desk_thread) |th| th.join();
        var waited: u32 = 0;
        while (s.active.load(.acquire) > 0 and waited < 2000) : (waited += 5) s.io.sleep(.fromMilliseconds(5), .awake) catch {};
        s.listener.close();
        // a thread still in a request owns its memory: let it go first
        if (s.active.load(.acquire) > 0) return;
        s.open.deinit(s.gpa);
        s.gpa.free(s.apps_dir);
        s.gpa.free(s.state_dir);
        s.gpa.free(s.version);
        s.gpa.free(s.desk_home);
        s.gpa.free(s.desk_state);
        s.gpa.destroy(s);
    }

    /// The link to harness's page of apps, for this start.
    pub fn shellUrl(s: *const Server, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/s/{s}/", .{ s.port, &s.shell_token });
    }

    /// The link to app `name` in harness's page, at `view` ("" for none).
    pub fn appUrl(s: *const Server, a: std.mem.Allocator, name: []const u8, view: []const u8) ![]const u8 {
        if (view.len == 0) return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/s/{s}/{s}", .{ s.port, &s.shell_token, name });
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/s/{s}/{s}?view={s}", .{ s.port, &s.shell_token, name, view });
    }

    /// The link to the review page of the save `id`.
    pub fn reviewUrl(s: *const Server, a: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/s/{s}/review/{s}", .{ s.port, &s.shell_token, id });
    }

    /// An app's token: HMAC-SHA256(key, NAME, version) cut to 16 bytes.
    pub fn appToken(s: *const Server, name: []const u8, version: []const u8) [22]u8 {
        var mac: [32]u8 = undefined;
        var h = std.crypto.auth.hmac.sha2.HmacSha256.init(&s.key);
        h.update(name);
        h.update("\x00");
        h.update(version);
        h.final(&mac);
        var out: [22]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&out, mac[0..16]);
        return out;
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
            if (s.active.load(.acquire) >= max_connections) {
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
        sk.init(s.io, conn, &rbuf, &wbuf, idle_ms);
        // a stop ends a connection's wait for its next request at once
        sk.stop = &s.stopping;
        var http_server = std.http.Server.init(&sk.reader, &sk.writer);
        while (!s.stopping.load(.acquire)) {
            var req = http_server.receiveHead() catch return;
            var arena_state = std.heap.ArenaAllocator.init(s.gpa);
            defer arena_state.deinit();
            const keep = s.handle(arena_state.allocator(), &req) catch return;
            if (!keep) return;
        }
    }

    fn handle(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request) !bool {
        // copied: reading a body uses the buffer the head is in
        const target = try a.dupe(u8, req.head.target);
        const method = req.head.method;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";
        var host: ?[]const u8 = null;
        var origin: ?[]const u8 = null;
        var dest: ?[]const u8 = null;
        var cookie: []const u8 = "";
        var if_none: []const u8 = "";
        var ctype: []const u8 = "";
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) host = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "sec-fetch-dest")) dest = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "cookie")) cookie = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "if-none-match")) if_none = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) ctype = try a.dupe(u8, h.value);
        }
        const own = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{s.port});
        const own_origin = try std.fmt.allocPrint(a, "http://{s}", .{own});
        // another name for this machine (DNS rebinding) is not this server
        if (host == null or !std.mem.eql(u8, host.?, own)) return s.refuse(req, .host, .forbidden, "Open harness's apps from the link it printed.");
        const in_app = std.mem.startsWith(u8, path, "/a/");
        if (origin) |o| if (!std.mem.eql(u8, o, own_origin) and !(in_app and std.mem.eql(u8, o, "null")))
            return s.refuse(req, .origin, .forbidden, "Requests from other sites are refused.");
        // files are read; only a token's `api/` paths take calls
        const reads = method == .GET or method == .HEAD;
        const calls = method == .POST or method == .PUT or method == .DELETE or method == .OPTIONS;
        const desk_api = std.mem.startsWith(u8, path, "/desk/api/");
        if (!reads and !(calls and (isApi(path) or desk_api))) return s.plain(req, .method_not_allowed, "Only GET.", own_origin, null);
        // the desk's voice and upload take more
        const limit: usize = if (std.mem.eql(u8, path, "/desk/api/voice") or std.mem.eql(u8, path, "/desk/api/upload")) max_desk_body else max_body;
        var body: []const u8 = "";
        if (method == .POST or method == .PUT) {
            const too_big = if (limit == max_body) "A call carries at most 1 MiB." else "A call carries at most 10 MB.";
            if (req.head.content_length) |n| if (n > limit) {
                // read off first (up to 4 MiB): closed with its body unread,
                // Windows resets the connection and the answer is lost
                if (n <= @max(4 << 20, limit + (1 << 20))) {
                    var drain_buf: [8192]u8 = undefined;
                    if (req.readerExpectContinue(&drain_buf)) |r| {
                        _ = r.discardRemaining() catch {};
                    } else |_| {}
                }
                return s.plain(req, .payload_too_large, too_big, own_origin, null);
            };
            var body_buf: [8192]u8 = undefined;
            const r = req.readerExpectContinue(&body_buf) catch return false;
            body = r.allocRemaining(a, .limited(limit)) catch |e| switch (e) {
                error.StreamTooLong => return s.plain(req, .payload_too_large, too_big, own_origin, null),
                else => return false,
            };
        }
        const rq: Rq = .{ .req = req, .method = method, .query = query, .body = body, .origin = origin, .dest = dest, .own_origin = own_origin, .cookie = cookie, .if_none = if_none, .content_type = ctype };
        if (std.mem.eql(u8, path, "/alive")) return s.respondEx(req, .ok, "", "text/plain; charset=utf-8", own_origin, .plain, null, .{});
        if (s.desk_home.len > 0) {
            if (std.mem.eql(u8, path, "/enter")) return s.enter(a, rq);
            if (std.mem.eql(u8, path, "/desk") or std.mem.startsWith(u8, path, "/desk/")) return s.desk(a, rq, path);
        }
        if (std.mem.startsWith(u8, path, "/s/")) return s.shell(a, rq, path["/s/".len..]);
        if (in_app) return s.app(a, rq, path["/a/".len..]);
        return s.plain(req, .not_found, old_link, own_origin, null);
    }

    /// One request, its head read.
    const Rq = struct {
        req: *std.http.Server.Request,
        method: std.http.Method,
        query: []const u8,
        body: []const u8,
        origin: ?[]const u8,
        dest: ?[]const u8,
        own_origin: []const u8,
        cookie: []const u8 = "",
        if_none: []const u8 = "",
        content_type: []const u8 = "",
    };

    // ---- the desk ----

    /// `/enter?code=C`: the code the desk app read from `state/desk-code`,
    /// once, within its 60 s: a session, kept in memory only, as a cookie.
    fn enter(s: *Server, a: std.mem.Allocator, rq: Rq) !bool {
        const req = rq.req;
        const gone = "This code was used or has expired. Open the desk again.";
        const code = queryValue(rq.query, "code") orelse return s.refuse(req, .desk, .forbidden, gone);
        const path = try std.fs.path.join(a, &.{ s.desk_state, "desk-code" });
        if (!s.codes.take(s.io, path, code, @intCast(Io.Clock.awake.now(s.io).toMilliseconds()))) return s.refuse(req, .desk, .forbidden, gone);
        const tok = try s.sessions.create(s.io);
        var buf: [128]u8 = undefined;
        if (s.log) |l| l.write(.app, false, .{ .event = "desk entered" }) catch {};
        return s.respondEx(req, .see_other, "", "text/plain; charset=utf-8", rq.own_origin, .plain, null, .{ .headers = &.{
            .{ .name = "location", .value = "/desk" },
            .{ .name = "set-cookie", .value = deskwin.setCookie(&buf, &tok) },
        } });
    }

    /// `/desk…`: the page, its files, the avatars and fit files, an app in
    /// its frame, and the API; each only to a session.
    fn desk(s: *Server, a: std.mem.Allocator, rq: Rq, path: []const u8) !bool {
        const req = rq.req;
        const o = rq.own_origin;
        const signed_in = if (deskwin.cookieOf(rq.cookie, deskwin.cookie_name)) |tok| s.sessions.valid(s.io, tok) else false;
        if (std.mem.startsWith(u8, path, "/desk/api/")) {
            if (!signed_in) return s.respond(req, .unauthorized, "{\"error\":\"signed out\"}", "application/json", o, .plain, null);
            if (rq.method == .OPTIONS) return s.plain(req, .method_not_allowed, "Only GET and POST.", o, null);
            const h = s.host orelse return s.respond(req, .not_found, "{\"error\":\"not here\"}", "application/json", o, .plain, null);
            const f = h.desk orelse return s.respond(req, .not_found, "{\"error\":\"not here\"}", "application/json", o, .plain, null);
            const got = f(h.ctx, a, .{ .method = rq.method, .path = path["/desk/api/".len..], .query = rq.query, .body = rq.body, .content_type = rq.content_type, .stop = &s.stopping });
            return s.respond(req, got.status, got.body, got.content_type, o, .plain, null);
        }
        if (!signed_in) return s.refuse(req, .desk, .unauthorized, "Open the desk from the harness app.");
        if (std.mem.eql(u8, path, "/desk") or std.mem.eql(u8, path, "/desk/")) return s.respond(req, .ok, deskFile("index.html").?, "text/html; charset=utf-8", o, .desk, null);
        if (std.mem.startsWith(u8, path, "/desk/static/")) {
            const rel = path["/desk/static/".len..];
            const body = deskFile(rel) orelse return s.plain(req, .not_found, "No such file.", o, null);
            return s.respond(req, .ok, body, contentType(rel), o, .desk, null);
        }
        if (std.mem.startsWith(u8, path, "/desk/apps/")) return s.deskApp(a, rq, path["/desk/apps/".len..]);
        // the owner's avatars and the fit's files, from the data folder
        var dir: []const u8 = "";
        var rel: []const u8 = "";
        if (std.mem.startsWith(u8, path, "/desk/avatars/")) {
            const rest = path["/desk/avatars/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return s.plain(req, .not_found, "No such file.", o, null);
            const name = rest[0..slash];
            rel = rest[slash + 1 ..];
            if (!config.avatarName(name) or std.mem.indexOfScalar(u8, rel, '/') != null) return s.plain(req, .not_found, "No such file.", o, null);
            dir = try std.fs.path.join(a, &.{ s.desk_home, "avatars", name });
        } else if (std.mem.startsWith(u8, path, "/desk/assets/")) {
            rel = path["/desk/assets/".len..];
            dir = try std.fs.path.join(a, &.{ s.desk_home, "desk-assets" });
        } else return s.plain(req, .not_found, "No such file.", o, null);
        if (!deskName(rel)) return s.plain(req, .not_found, "No such file.", o, null);
        const body = readDeskFile(s.io, a, dir, rel) catch |e| switch (e) {
            error.TooBig => return s.plain(req, .payload_too_large, "Files here are at most 20 MB.", o, null),
            else => return e,
        } orelse return s.plain(req, .not_found, "No such file.", o, null);
        const tag = deskwin.etag(body);
        const cache = "private, max-age=86400";
        if (std.mem.eql(u8, std.mem.trim(u8, rq.if_none, " "), &tag)) return s.respondEx(req, .not_modified, "", contentType(rel), o, .plain, null, .{ .cache = cache, .headers = &.{.{ .name = "etag", .value = &tag }} });
        return s.respondEx(req, .ok, body, contentType(rel), o, .plain, null, .{ .cache = cache, .headers = &.{.{ .name = "etag", .value = &tag }} });
    }

    /// `/desk/apps/NAME`: the app in its frame, as `/s/TOKEN/NAME` shows it.
    fn deskApp(s: *Server, a: std.mem.Allocator, rq: Rq, name: []const u8) !bool {
        const req = rq.req;
        const found = (try s.findApp(a, name)) orelse return s.plain(req, .not_found, "No app by that name; the page of apps lists them.", rq.own_origin, null);
        const token = s.appToken(found.name, found.version);
        var out: std.ArrayList(u8) = .empty;
        try s.pageHead(&out, a, found.title, try std.fmt.allocPrint(a, "<a href=\"/desk\">Desk</a><span>{s}</span>", .{try escape(a, found.title)}));
        try out.print(a, "<iframe sandbox=\"allow-scripts allow-forms\" referrerpolicy=\"no-referrer\" allow=\"\" src=\"/a/{s}/?in=page&amp;view={s}\" title=\"{s}\"></iframe>", .{ &token, viewOf(rq.query), try escape(a, found.title) });
        try s.pageTail(&out, a);
        return s.shellPage(req, out.items, rq.own_origin);
    }

    /// `/s/TOKEN/api/...` or `/a/TOKEN/api/...`.
    fn isApi(path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, "/s/") and !std.mem.startsWith(u8, path, "/a/")) return false;
        const rest = path[3..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        return std.mem.startsWith(u8, rest[slash + 1 ..], "api/");
    }

    /// `/s/TOKEN/...`: harness's page of apps, one app in its frame, the
    /// review page of a save, and the bar's calls.
    fn shell(s: *Server, a: std.mem.Allocator, rq: Rq, rest: []const u8) !bool {
        const req = rq.req;
        const own_origin = rq.own_origin;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return s.refuse(req, .token, .not_found, old_link);
        if (!tokenEql(rest[0..slash], &s.shell_token)) return s.refuse(req, .token, .not_found, old_link);
        const sub = rest[slash + 1 ..];
        if (std.mem.startsWith(u8, sub, "api/")) {
            const h = s.host orelse return s.respond(req, .not_found, "{\"error\":\"not here\"}", "application/json", own_origin, .plain, null);
            if (rq.method == .OPTIONS) return s.plain(req, .method_not_allowed, "Only GET and POST.", own_origin, null);
            const got = h.shell(h.ctx, a, .{ .method = rq.method, .path = sub["api/".len..], .query = rq.query, .body = rq.body });
            return s.respond(req, got.status, got.body, got.content_type, own_origin, .plain, null);
        }
        if (sub.len == 0) return s.shellPage(req, try s.homeHtml(a), own_origin);
        if (std.mem.eql(u8, sub, "shell.css")) return s.respond(req, .ok, shell_css, "text/css; charset=utf-8", own_origin, .shell, null);
        if (std.mem.eql(u8, sub, "shell.js")) return s.respond(req, .ok, shell_js, "text/javascript; charset=utf-8", own_origin, .shell, null);
        if (std.mem.startsWith(u8, sub, "review/")) {
            const html = (try s.reviewHtml(a, sub["review/".len..])) orelse
                return s.plain(req, .not_found, "That save is not waiting any more: it was answered, or harness started again.", own_origin, null);
            return s.shellPage(req, html, own_origin);
        }
        const found = try s.findApp(a, sub);
        const app_ = found orelse return s.plain(req, .not_found, "No app by that name; the page of apps lists them.", own_origin, null);
        const view = viewOf(rq.query);
        const token = s.appToken(app_.name, app_.version);
        var out: std.ArrayList(u8) = .empty;
        try s.pageHead(&out, a, app_.title, try std.fmt.allocPrint(a, "<a href=\"/s/{s}/\">Apps</a><span>{s}</span>", .{ &s.shell_token, try escape(a, app_.title) }));
        try out.print(a, "<iframe sandbox=\"allow-scripts allow-forms\" referrerpolicy=\"no-referrer\" allow=\"\" src=\"/a/{s}/?in=page&amp;view={s}\" title=\"{s}\"></iframe>", .{ &token, view, try escape(a, app_.title) });
        try s.pageTail(&out, a);
        return s.shellPage(req, out.items, own_origin);
    }

    /// The start of one of harness's own pages: its header and the bar,
    /// where every open inbox item is answered.
    fn pageHead(s: *Server, out: *std.ArrayList(u8), a: std.mem.Allocator, title: []const u8, header: []const u8) !void {
        try out.print(a,
            \\<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{s}</title>
            \\<link rel="stylesheet" href="/s/{s}/shell.css"></head><body data-api="/s/{s}/api/">
            \\<header>{s}</header>
            \\<section id="bar" aria-label="What waits for you"></section>
            \\
        , .{ try escape(a, title), &s.shell_token, &s.shell_token, header });
    }

    fn pageTail(s: *Server, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        try out.print(a, "<script src=\"/s/{s}/shell.js\"></script></body></html>", .{&s.shell_token});
    }

    const Found = struct { name: []const u8, title: []const u8, version: []const u8, builtin: ?Builtin = null, draft: bool = false };

    /// An app by name: a built-in, or one approved and unchanged since.
    fn findApp(s: *Server, a: std.mem.Allocator, name: []const u8) !?Found {
        for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return .{ .name = b.name, .title = b.title, .version = s.version, .builtin = b };
        if (!apps.validName(name)) return null;
        const ap = (try apps.readApproved(s.io, a, s.state_dir, name)) orelse return null;
        const dir = try std.fs.path.join(a, &.{ s.apps_dir, name });
        const m = blk: {
            const ini = Io.Dir.cwd().readFileAlloc(s.io, try std.fs.path.join(a, &.{ dir, "app.ini" }), a, .limited(64 << 10)) catch return null;
            break :blk apps.parse(a, ini) catch return null;
        };
        return .{ .name = name, .title = if (m.title.len > 0) m.title else name, .version = try std.fmt.allocPrint(a, "{d}", .{ap.version}) };
    }

    /// The approved apps, by name.
    fn approvedNames(s: *Server, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var d = Io.Dir.cwd().openDir(s.io, s.state_dir, .{ .iterate = true }) catch return out.items;
        defer d.close(s.io);
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .directory or !apps.validName(e.name)) continue;
            if ((try apps.readApproved(s.io, a, s.state_dir, e.name)) == null) continue;
            try out.append(a, try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return out.items;
    }

    /// The saves being asked, by id.
    fn pendingIds(s: *Server, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var d = Io.Dir.cwd().openDir(s.io, try std.fs.path.join(a, &.{ s.state_dir, "pending" }), .{ .iterate = true }) catch return out.items;
        defer d.close(s.io);
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind == .directory and apps.validId(e.name)) try out.append(a, try a.dupe(u8, e.name));
        }
        return out.items;
    }

    fn homeHtml(s: *Server, a: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try s.pageHead(&out, a, "Apps", "<span>Apps</span>");
        try out.appendSlice(a, "<main><ul>");
        for (builtins) |b| try out.print(a, "<li><a href=\"{s}\">{s}</a> <small>built in</small></li>", .{ b.name, b.title });
        for (try s.approvedNames(a)) |name| {
            const f = (try s.findApp(a, name)) orelse continue;
            try out.print(a, "<li><a href=\"{s}\">{s}</a> <small>v{s}</small></li>", .{ name, try escape(a, f.title), f.version });
        }
        try out.appendSlice(a, "</ul></main>");
        try s.pageTail(&out, a);
        return out.items;
    }

    /// The review page of the save `id`: what it would install, every
    /// file in full, and the draft in a frame, where it reads nothing and
    /// asks harness for nothing. Null: no such save is waiting.
    fn reviewHtml(s: *Server, a: std.mem.Allocator, id: []const u8) !?[]const u8 {
        if (!apps.validId(id)) return null;
        const dir = try std.fs.path.join(a, &.{ s.state_dir, "pending", id });
        const ini = Io.Dir.cwd().readFileAlloc(s.io, try std.fs.path.join(a, &.{ dir, "app.ini" }), a, .limited(64 << 10)) catch return null;
        const m = apps.parse(a, ini) catch return null;
        const f = apps.checkFolder(s.io, a, dir, m.name) catch return null;
        var out: std.ArrayList(u8) = .empty;
        const title = try std.fmt.allocPrint(a, "Review: {s} v{d}", .{ m.name, m.version });
        try s.pageHead(&out, a, title, try std.fmt.allocPrint(a, "<a href=\"/s/{s}/\">Apps</a><span>{s}</span>", .{ &s.shell_token, try escape(a, title) }));
        try out.appendSlice(a, "<main class=\"review\"><p>What this save installs, as harness copied it when it was asked. Answer it in the bar above, or where the question was sent.</p>");
        try out.print(a, "<h2>app.ini</h2><pre>{s}</pre>", .{try escape(a, ini)});
        for (f.files) |file| {
            try out.print(a, "<h2>{s} <small>{d} bytes, SHA-256 {s}</small></h2>", .{ try escape(a, file.rel), file.size, &file.sha });
            if (!isText(file.rel)) {
                try out.appendSlice(a, "<p>Not text (an image or a font); the draft below shows it.</p>");
                continue;
            }
            const text = (try readFileIn(s.io, a, dir, file.rel)) orelse "";
            try out.print(a, "<pre>{s}</pre>", .{try escape(a, text)});
        }
        try out.appendSlice(a, "<h2>The draft <small>shown as it would look; here it reads nothing and asks harness for nothing</small></h2>");
        try out.print(a, "<iframe sandbox=\"allow-scripts allow-forms\" referrerpolicy=\"no-referrer\" allow=\"\" src=\"/a/{s}/?in=review\" title=\"The draft\"></iframe></main>", .{&s.appToken(id, "draft")});
        try s.pageTail(&out, a);
        return out.items;
    }

    /// `/a/TOKEN/...`: an app's own files, and its API under `api/`.
    fn app(s: *Server, a: std.mem.Allocator, rq: Rq, rest: []const u8) !bool {
        const req = rq.req;
        const own_origin = rq.own_origin;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return s.refuse(req, .token, .not_found, old_link);
        const token = rest[0..slash];
        const sub = rest[slash + 1 ..];
        const cors: ?[]const u8 = if (rq.origin) |o| (if (std.mem.eql(u8, o, "null")) "null" else null) else null;
        // the app whose token it is: built-ins, approved apps and the
        // drafts of saves being asked, each compared in full
        var hit: ?Found = null;
        for (builtins) |b| if (tokenEql(token, &s.appToken(b.name, s.version))) {
            hit = .{ .name = b.name, .title = b.title, .version = s.version, .builtin = b };
        };
        for (try s.approvedNames(a)) |name| {
            const ap = (try apps.readApproved(s.io, a, s.state_dir, name)) orelse continue;
            const v = try std.fmt.allocPrint(a, "{d}", .{ap.version});
            if (tokenEql(token, &s.appToken(name, v))) hit = .{ .name = name, .title = name, .version = v };
        }
        for (try s.pendingIds(a)) |id| if (tokenEql(token, &s.appToken(id, "draft"))) {
            hit = .{ .name = id, .title = "draft", .version = "draft", .draft = true };
        };
        const found = hit orelse return s.refuse(req, .token, .not_found, old_link);
        if (std.mem.startsWith(u8, sub, "api/")) {
            if (rq.method == .OPTIONS) return s.preflight(req, cors);
            if (found.draft) return s.respond(req, .forbidden, draft_api, "application/json", own_origin, .plain, cors);
            const h = s.host orelse return s.respond(req, .not_found, "{\"error\":\"the apps' API is not on\"}", "application/json", own_origin, .plain, cors);
            const got = h.api(h.ctx, a, .{
                .app = found.name,
                .version = found.version,
                .builtin = found.builtin != null,
                .method = rq.method,
                .path = sub["api/".len..],
                .query = rq.query,
                .body = rq.body,
                .stop = &s.stopping,
            });
            return s.respond(req, got.status, got.body, got.content_type, own_origin, .plain, cors);
        }
        const rel = if (sub.len == 0) "index.html" else sub;
        if (!apps.servableName(rel)) return s.plain(req, .not_found, "No such file.", own_origin, cors);
        const is_html = std.mem.endsWith(u8, rel, ".html");
        // a page in a tab of its own could navigate itself anywhere
        if (is_html and !(rq.dest != null and std.mem.eql(u8, rq.dest.?, "iframe"))) return s.refuse(req, .frame, .forbidden, "Open the app from harness's page of apps.");
        if (found.builtin) |b| {
            const body = b.file(rel) orelse return s.plain(req, .not_found, "No such file.", own_origin, cors);
            if (is_html) if (s.host) |h| h.opened(h.ctx, found.name, found.version);
            return s.respond(req, .ok, body, contentType(rel), own_origin, .app, cors);
        }
        if (found.draft) {
            const dir = try std.fs.path.join(a, &.{ s.state_dir, "pending", found.name });
            const body = (try readFileIn(s.io, a, dir, rel)) orelse return s.plain(req, .not_found, "No such file.", own_origin, cors);
            return s.respond(req, .ok, body, contentType(rel), own_origin, .app, cors);
        }
        // its files as approved, before its page is served
        if (is_html and (try apps.asApproved(s.io, a, s.apps_dir, s.state_dir, found.name)) == null) {
            if (s.log) |l| l.write(.app, false, .{ .event = "changed outside harness", .name = found.name }) catch {};
            return s.plain(req, .forbidden, "This app's files changed outside harness; /app approve NAME serves it again.", own_origin, cors);
        }
        const body = (try readFileIn(s.io, a, try std.fs.path.join(a, &.{ s.apps_dir, found.name }), rel)) orelse return s.plain(req, .not_found, "No such file.", own_origin, cors);
        if (is_html) if (s.host) |h| h.opened(h.ctx, found.name, found.version);
        return s.respond(req, .ok, body, contentType(rel), own_origin, .app, cors);
    }

    /// The answer to a browser asking whether an app's frame (its origin
    /// is `null`) may send a call with a JSON body, or PUT or DELETE.
    fn preflight(s: *Server, req: *std.http.Server.Request, cors: ?[]const u8) !bool {
        _ = s;
        const c = cors orelse "null";
        try req.respond("", .{ .status = .no_content, .keep_alive = false, .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = c },
            .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
            .{ .name = "access-control-max-age", .value = "600" },
            .{ .name = "cache-control", .value = "no-store" },
        } });
        return false;
    }


    fn shellPage(s: *Server, req: *std.http.Server.Request, html: []const u8, own_origin: []const u8) !bool {
        return s.respond(req, .ok, html, "text/html; charset=utf-8", own_origin, .shell, null);
    }

    fn plain(s: *Server, req: *std.http.Server.Request, status: std.http.Status, text: []const u8, own_origin: []const u8, cors: ?[]const u8) !bool {
        return s.respond(req, status, text, "text/plain; charset=utf-8", own_origin, .plain, cors);
    }

    fn refuse(s: *Server, req: *std.http.Server.Request, why: Refusal, status: std.http.Status, text: []const u8) !bool {
        const now = std.Io.Clock.awake.now(s.io).toMilliseconds();
        const i = @backingInt(why);
        if (now - s.last_refusal_ms[i] >= 60 * 1000) {
            s.last_refusal_ms[i] = @intCast(now);
            if (s.log) |l| l.write(.app, false, .{ .event = "refused", .why = @tagName(why) }) catch {};
        }
        return s.respond(req, status, text, "text/plain; charset=utf-8", "", .plain, null);
    }

    const Kind = enum { shell, app, plain, desk };

    /// What a response carries beyond the usual: its caching, and headers
    /// (a cookie, a redirect, an ETag).
    const Extra = struct { cache: []const u8 = "no-store", headers: []const std.http.Header = &.{} };

    fn respond(s: *Server, req: *std.http.Server.Request, status: std.http.Status, body: []const u8, ct: []const u8, own_origin: []const u8, kind: Kind, cors: ?[]const u8) !bool {
        return s.respondEx(req, status, body, ct, own_origin, kind, cors, .{});
    }

    /// Every response: no referrer, no sniffing, nothing kept (but the
    /// desk's avatar and fit files); the shell's, an app's and the desk's
    /// own CSP.
    fn respondEx(s: *Server, req: *std.http.Server.Request, status: std.http.Status, body: []const u8, ct: []const u8, own_origin: []const u8, kind: Kind, cors: ?[]const u8, extra: Extra) !bool {
        _ = s;
        var buf: [1024]u8 = undefined;
        var headers: [14]std.http.Header = undefined;
        var n: usize = 0;
        headers[n] = .{ .name = "content-type", .value = ct };
        n += 1;
        headers[n] = .{ .name = "referrer-policy", .value = "no-referrer" };
        n += 1;
        headers[n] = .{ .name = "x-content-type-options", .value = "nosniff" };
        n += 1;
        headers[n] = .{ .name = "cache-control", .value = extra.cache };
        n += 1;
        switch (kind) {
            .shell => {
                headers[n] = .{ .name = "cross-origin-opener-policy", .value = "same-origin" };
                n += 1;
                headers[n] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
                n += 1;
                headers[n] = .{ .name = "content-security-policy", .value = try std.fmt.bufPrint(&buf, "default-src {s}; frame-ancestors 'none'; base-uri 'none'", .{own_origin}) };
                n += 1;
            },
            .app => {
                headers[n] = .{ .name = "content-security-policy", .value = try std.fmt.bufPrint(&buf, "default-src 'none'; script-src {0s}; style-src {0s} 'unsafe-inline'; img-src {0s} data: blob:; font-src {0s}; media-src {0s} blob:; connect-src {0s}; form-action 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors {0s}; sandbox allow-scripts allow-forms", .{own_origin}) };
                n += 1;
            },
            .plain => {
                headers[n] = .{ .name = "content-security-policy", .value = "default-src 'none'; frame-ancestors 'none'" };
                n += 1;
            },
            .desk => {
                headers[n] = .{ .name = "cross-origin-opener-policy", .value = "same-origin" };
                n += 1;
                headers[n] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
                n += 1;
                // MediaPipe's WebAssembly (the fit) needs wasm-unsafe-eval; a
                // photo picked for the fit and the voice's audio are blob URLs
                headers[n] = .{ .name = "content-security-policy", .value = try std.fmt.bufPrint(&buf, "default-src 'none'; script-src {0s} 'wasm-unsafe-eval'; style-src {0s}; img-src {0s} blob:; font-src {0s}; media-src {0s} blob:; connect-src {0s}; worker-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'", .{own_origin}) };
                n += 1;
            },
        }
        if (cors) |c| {
            headers[n] = .{ .name = "access-control-allow-origin", .value = c };
            n += 1;
        }
        for (extra.headers) |h| {
            headers[n] = h;
            n += 1;
        }
        // an error ends the connection; so does a client that asked to
        const keep = (status == .ok or status == .not_modified) and req.head.keep_alive;
        try req.respond(body, .{ .status = status, .extra_headers = headers[0..n], .keep_alive = keep });
        return keep;
    }
};

/// Equal in full, in time that doesn't depend on where they differ.
fn tokenEql(given: []const u8, want: *const [22]u8) bool {
    if (given.len != want.len) return false;
    return std.crypto.timing_safe.eql([22]u8, given[0..22].*, want.*);
}

/// `key=V` from a query (as given); null: not there.
fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=') return kv[key.len + 1 ..];
    }
    return null;
}

/// A file of an avatar or of the fit: parts of letters, digits, `.`, `_`
/// and `-` (none starting or ending with a dot, no device names), with an
/// extension those files have.
fn deskName(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > 512) return false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    var last: []const u8 = "";
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or part[part.len - 1] == '.') return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
        const base = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "con", "prn", "aux", "nul" }) |d| if (std.ascii.eqlIgnoreCase(base, d)) return false;
        if (base.len == 4 and (std.ascii.startsWithIgnoreCase(base, "com") or std.ascii.startsWithIgnoreCase(base, "lpt")) and base[3] >= '1' and base[3] <= '9') return false;
        last = part;
    }
    const dot = std.mem.lastIndexOfScalar(u8, last, '.') orelse return false;
    const ext = last[dot + 1 ..];
    for ([_][]const u8{ "jpg", "jpeg", "png", "webp", "bin", "ini", "wasm", "js", "mjs", "task", "json", "txt" }) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

/// `rel` in `dir` as `readFileIn` reads it, up to 20 MB (error.TooBig
/// past it); null: not there, or not a file.
fn readDeskFile(io: Io, a: std.mem.Allocator, dir: []const u8, rel: []const u8) !?[]const u8 {
    var path = dir;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        path = try std.fs.path.join(a, &.{ path, part });
        const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
        const last = parts.peek() == null;
        if (last and st.kind != .file) return null;
        if (!last and st.kind != .directory) return null;
        if (last and st.size > max_desk_file) return error.TooBig;
    }
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_desk_file)) catch |e| switch (e) {
        error.StreamTooLong => error.TooBig,
        else => null,
    };
}

/// `view=V` from a query: letters, digits, - and _ (up to 64), else "".
fn viewOf(query: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        if (!std.mem.startsWith(u8, kv, "view=")) continue;
        const v = kv["view=".len..];
        if (v.len > 64) return "";
        for (v) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return "";
        return v;
    }
    return "";
}

fn escape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&#39;"),
        else => try out.append(a, c),
    };
    return out.items;
}

/// `rel` in the folder `dir`: each part a folder or, the last, a file,
/// never a link.
fn readFileIn(io: Io, a: std.mem.Allocator, dir: []const u8, rel: []const u8) !?[]const u8 {
    var path = dir;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        path = try std.fs.path.join(a, &.{ path, part });
        const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return null;
        const last = parts.peek() == null;
        if (last and st.kind != .file) return null;
        if (!last and st.kind != .directory) return null;
    }
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(apps.max_file)) catch null;
}

/// Whether a file of an app is text the review page shows in full.
fn isText(rel: []const u8) bool {
    const ext = rel[(std.mem.lastIndexOfScalar(u8, rel, '.') orelse return false) + 1 ..];
    for ([_][]const u8{ "html", "js", "mjs", "css", "json", "svg", "txt", "md" }) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

fn contentType(rel: []const u8) []const u8 {
    const ext = rel[(std.mem.lastIndexOfScalar(u8, rel, '.') orelse return "application/octet-stream") + 1 ..];
    const map = [_][2][]const u8{
        .{ "html", "text/html; charset=utf-8" }, .{ "js", "text/javascript; charset=utf-8" }, .{ "mjs", "text/javascript; charset=utf-8" },
        .{ "css", "text/css; charset=utf-8" },   .{ "json", "application/json" },             .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },                 .{ "jpg", "image/jpeg" },                    .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },               .{ "ico", "image/x-icon" },                  .{ "woff2", "font/woff2" },
        .{ "txt", "text/plain; charset=utf-8" }, .{ "md", "text/markdown; charset=utf-8" }, .{ "jpeg", "image/jpeg" },
        .{ "wasm", "application/wasm" },        .{ "ini", "text/plain; charset=utf-8" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], ext)) return m[1];
    return "application/octet-stream";
}

// ---- tests ----

const t = std.testing;

const Got = struct { status: u16, head: []const u8, body: []const u8 };

/// One request on a connection of its own, headers as given.
fn get(a: std.mem.Allocator, port: u16, path: []const u8, extra: []const u8) !Got {
    const h = try sock.connect(t.io, "127.0.0.1", port, 2000);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    defer sk.close();
    try sk.writer.print("GET {s} HTTP/1.1\r\n{s}Connection: close\r\n\r\n", .{ path, extra });
    try sk.writer.flush();
    const all = try sk.reader.allocRemaining(a, .limited(4 << 20));
    const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadResponse;
    const status = try std.fmt.parseInt(u16, all[9..12], 10);
    return .{ .status = status, .head = all[0..split], .body = all[split + 4 ..] };
}

const Fix = struct {
    tmp: t.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    apps_dir: []const u8,
    state_dir: []const u8,
    s: *Server,
    host: []const u8,

    fn init(f: *Fix) !void {
        f.tmp = t.tmpDir(.{});
        f.arena_state = .init(t.allocator);
        f.a = f.arena_state.allocator();
        try f.tmp.dir.createDirPath(t.io, "apps/notes/js");
        try f.tmp.dir.createDirPath(t.io, "state/apps");
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "apps/notes/app.ini", .data = "[app]\nname = notes\ntitle = My <Notes>\n" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "apps/notes/index.html", .data = "<!doctype html><p>notes page</p><script src=\"js/app.js\"></script>" });
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = "apps/notes/js/app.js", .data = "console.log('notes')" });
        const root = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.a);
        f.apps_dir = try std.fs.path.join(f.a, &.{ root, "apps" });
        f.state_dir = try std.fs.path.join(f.a, &.{ root, "state", "apps" });
        _ = try apps.approve(t.io, f.a, f.apps_dir, f.state_dir, "notes", "owner", 1);
        f.s = try Server.start(t.allocator, t.io, .{ .apps_dir = f.apps_dir, .state_dir = f.state_dir, .version = "0.3.0" });
        f.host = try std.fmt.allocPrint(f.a, "Host: 127.0.0.1:{d}\r\n", .{f.s.port});
    }

    fn deinit(f: *Fix) void {
        f.s.stop();
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    fn shellPath(f: *Fix, sub: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.a, "/s/{s}/{s}", .{ &f.s.shell_token, sub });
    }

    fn appPath(f: *Fix, name: []const u8, version: []const u8, sub: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.a, "/a/{s}/{s}", .{ &f.s.appToken(name, version), sub });
    }

    fn frame(f: *Fix) ![]const u8 {
        return std.fmt.allocPrint(f.a, "{s}Sec-Fetch-Dest: iframe\r\n", .{f.host});
    }
};

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

test "app_server_binds_loopback_alone" {
    const l = try sock.Listener.openExclusive(0);
    defer l.close();
    // a second listener on the port, even one asking to share it, fails
    // (Windows says access denied to one asking with SO_REUSEADDR)
    for ([_]bool{ false, true }) |exclusive| {
        if (if (exclusive) sock.Listener.openExclusive(l.port) else sock.Listener.open(l.port)) |other| {
            other.close();
            return error.TestUnexpectedResult;
        } else |e| try t.expect(e == error.AddressInUse or e == error.AccessDenied);
    }
}

test "app_requests_need_host_token_origin" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    const home = try f.shellPath("");
    // the right Host: the page of apps, the built-ins and the approved app
    const ok = try get(a, f.s.port, home, f.host);
    try t.expectEqual(200, ok.status);
    try expectHas(ok.body, ">Inbox</a>");
    try expectHas(ok.body, "My &lt;Notes&gt;");
    // another name for this machine: refused (DNS rebinding)
    try t.expectEqual(403, (try get(a, f.s.port, home, try std.fmt.allocPrint(a, "Host: localhost:{d}\r\n", .{f.s.port}))).status);
    try t.expectEqual(403, (try get(a, f.s.port, home, "")).status);
    // an old or unknown token: 404, one body
    const old = try get(a, f.s.port, "/s/AAAAAAAAAAAAAAAAAAAAAA/", f.host);
    try t.expectEqual(404, old.status);
    try t.expectEqualStrings(old_link, old.body);
    const app_old = try get(a, f.s.port, "/a/AAAAAAAAAAAAAAAAAAAAAA/index.html", try f.frame());
    try t.expectEqual(404, app_old.status);
    try t.expectEqualStrings(old_link, app_old.body);
    try t.expectEqualStrings(old_link, (try get(a, f.s.port, "/elsewhere", f.host)).body);
    // another site's Origin: refused; `null` only on an app's paths
    try t.expectEqual(403, (try get(a, f.s.port, home, try std.fmt.allocPrint(a, "{s}Origin: http://evil.test\r\n", .{f.host}))).status);
    try t.expectEqual(403, (try get(a, f.s.port, home, try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{f.host}))).status);
    const js = try get(a, f.s.port, try f.appPath("notes", "1", "js/app.js"), try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{f.host}));
    try t.expectEqual(200, js.status);
    try expectHas(js.head, "access-control-allow-origin: null");
    try t.expectEqual(200, (try get(a, f.s.port, home, try std.fmt.allocPrint(a, "{s}Origin: http://127.0.0.1:{d}\r\n", .{ f.host, f.s.port }))).status);
}

test "app_tokens_change_each_start_and_version" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const one = f.s.appToken("notes", "1");
    try t.expect(!std.mem.eql(u8, &one, &f.s.appToken("notes", "2")));
    try t.expect(!std.mem.eql(u8, &one, &f.s.appToken("other", "1")));
    const again = try Server.start(t.allocator, t.io, .{ .apps_dir = f.apps_dir, .state_dir = f.state_dir, .version = "0.3.0" });
    defer again.stop();
    try t.expect(!std.mem.eql(u8, &one, &again.appToken("notes", "1")));
    try t.expect(!std.mem.eql(u8, &f.s.shell_token, &again.shell_token));
    // an earlier start's link is an old one
    const got = try get(f.a, again.port, try f.appPath("notes", "1", "index.html"), try std.fmt.allocPrint(f.a, "Host: 127.0.0.1:{d}\r\nSec-Fetch-Dest: iframe\r\n", .{again.port}));
    try t.expectEqual(404, got.status);
}

test "app_html_only_into_a_frame" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const page = try f.appPath("notes", "1", "");
    try t.expectEqual(403, (try get(f.a, f.s.port, page, f.host)).status);
    try t.expectEqual(403, (try get(f.a, f.s.port, page, try std.fmt.allocPrint(f.a, "{s}Sec-Fetch-Dest: document\r\n", .{f.host}))).status);
    const framed = try get(f.a, f.s.port, page, try f.frame());
    try t.expectEqual(200, framed.status);
    try expectHas(framed.body, "notes page");
    // its script needs no frame
    try t.expectEqual(200, (try get(f.a, f.s.port, try f.appPath("notes", "1", "js/app.js"), f.host)).status);
}

test "app_responses_carry_csp_and_headers" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const o = try std.fmt.allocPrint(f.a, "http://127.0.0.1:{d}", .{f.s.port});
    const shell = try get(f.a, f.s.port, try f.shellPath("notes?view=week"), f.host);
    try t.expectEqual(200, shell.status);
    for ([_][]const u8{ "referrer-policy: no-referrer", "x-content-type-options: nosniff", "cache-control: no-store", "cross-origin-opener-policy: same-origin", "cross-origin-resource-policy: same-origin" }) |h| try expectHas(shell.head, h);
    try expectHas(shell.head, try std.fmt.allocPrint(f.a, "content-security-policy: default-src {s}; frame-ancestors 'none'; base-uri 'none'", .{o}));
    // the app in a sandboxed frame, its own token, the view passed on
    try expectHas(shell.body, "sandbox=\"allow-scripts allow-forms\"");
    try expectHas(shell.body, try std.fmt.allocPrint(f.a, "src=\"/a/{s}/?in=page&amp;view=week\"", .{&f.s.appToken("notes", "1")}));
    try t.expect(std.mem.indexOf(u8, shell.body, "<script>") == null);
    const app_page = try get(f.a, f.s.port, try f.appPath("notes", "1", ""), try f.frame());
    for ([_][]const u8{ "referrer-policy: no-referrer", "x-content-type-options: nosniff", "cache-control: no-store" }) |h| try expectHas(app_page.head, h);
    try expectHas(app_page.head, try std.fmt.allocPrint(f.a, "content-security-policy: default-src 'none'; script-src {0s}; style-src {0s} 'unsafe-inline'; img-src {0s} data: blob:; font-src {0s}; media-src {0s} blob:; connect-src {0s}; form-action 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors {0s}; sandbox allow-scripts allow-forms", .{o}));
    try expectHas(app_page.head, "content-type: text/html; charset=utf-8");
}

test "app_paths_refuse_tricks_over_http" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const tricks = [_][]const u8{ "../app.ini", "%2e%2e/app.ini", "js/../index.html", "data/x.json", "app.ini", "index.html::$DATA", "con.txt", "index.html.", ".hidden.html", "js%2fapp.js" };
    for (tricks) |tr| {
        const got = try get(f.a, f.s.port, try f.appPath("notes", "1", tr), try f.frame());
        if (got.status != 404) std.debug.print("{s}: {d}\n", .{ tr, got.status });
        try t.expectEqual(404, got.status);
    }
    // a link where a file was: never followed (where links can be made)
    f.tmp.dir.symLink(t.io, "app.js", "apps/notes/js/link.js", .{}) catch return;
    try t.expectEqual(404, (try get(f.a, f.s.port, try f.appPath("notes", "1", "js/link.js"), f.host)).status);
}

test "app_changed_outside_not_served_until_approved" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "apps/notes/js/app.js", .data = "console.log('changed by a command')" });
    const got = try get(f.a, f.s.port, try f.appPath("notes", "1", ""), try f.frame());
    try t.expectEqual(403, got.status);
    try expectHas(got.body, "changed outside harness");
    // approved again: a new version, a new token
    try t.expectEqual(2, try apps.approve(t.io, f.a, f.apps_dir, f.state_dir, "notes", "owner", 2));
    try t.expectEqual(404, (try get(f.a, f.s.port, try f.appPath("notes", "1", ""), try f.frame())).status);
    try t.expectEqual(200, (try get(f.a, f.s.port, try f.appPath("notes", "2", ""), try f.frame())).status);
}

test "builtin_apps_from_the_binary" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    for (builtins) |b| {
        const page = try get(f.a, f.s.port, try f.appPath(b.name, "0.3.0", ""), try f.frame());
        try t.expectEqual(200, page.status);
        try expectHas(page.body, "<script src=\"app.js\"></script>");
        try t.expect(std.mem.indexOf(u8, page.body, "<script>") == null);
        try t.expectEqual(200, (try get(f.a, f.s.port, try f.appPath(b.name, "0.3.0", "app.js"), f.host)).status);
        try t.expectEqual(200, (try get(f.a, f.s.port, try f.appPath(b.name, "0.3.0", "style.css"), f.host)).status);
        // with no host, their API is not on
        try t.expectEqual(404, (try get(f.a, f.s.port, try f.appPath(b.name, "0.3.0", "api/info"), f.host)).status);
    }
}

test "app_server_stops_within_2s" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", arena.allocator());
    const s = try Server.start(t.allocator, t.io, .{ .apps_dir = root, .state_dir = root, .version = "0.3.0" });
    // a browser's connection, kept open after its request
    const h = try sock.connect(t.io, "127.0.0.1", s.port, 2000);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    defer sk.close();
    try sk.writer.print("GET /s/{s}/ HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{ &s.shell_token, s.port });
    try sk.writer.flush();
    _ = try sk.reader.peekGreedy(12);
    const started = Io.Clock.awake.now(t.io);
    s.stop();
    try t.expect(started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 2000);
}

/// One request with a method and a body, on a connection of its own.
fn send(a: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, extra: []const u8, body: []const u8) !Got {
    const h = try sock.connect(t.io, "127.0.0.1", port, 2000);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 5000);
    defer sk.close();
    try sk.writer.print("{s} {s} HTTP/1.1\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, extra, body.len });
    try sk.writer.writeAll(body);
    try sk.writer.flush();
    const all = try sk.reader.allocRemaining(a, .limited(4 << 20));
    const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadResponse;
    const status = try std.fmt.parseInt(u16, all[9..12], 10);
    return .{ .status = status, .head = all[0..split], .body = all[split + 4 ..] };
}

/// A host that says what it was asked.
const FakeHost = struct {
    api_calls: u32 = 0,
    shell_calls: u32 = 0,
    opened: u32 = 0,
    desk_calls: u32 = 0,

    fn host(h: *FakeHost) Host {
        return .{ .ctx = h, .api = api, .shell = shell, .opened = wasOpened, .desk = deskCall };
    }

    fn deskCall(ctx: *anyopaque, a: std.mem.Allocator, call: DeskCall) Answer {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        h.desk_calls += 1;
        return .{ .body = std.fmt.allocPrint(a, "{{\"desk\":\"{s}\",\"method\":\"{s}\",\"query\":\"{s}\",\"body\":{d},\"type\":\"{s}\"}}", .{ call.path, @tagName(call.method), call.query, call.body.len, call.content_type }) catch "{}" };
    }

    fn api(ctx: *anyopaque, a: std.mem.Allocator, call: Call) Answer {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        h.api_calls += 1;
        if (std.mem.eql(u8, call.path, "missing")) return .{ .status = .not_found, .body = "{\"error\":\"no\"}" };
        return .{ .body = std.fmt.allocPrint(a, "{{\"app\":\"{s}\",\"version\":\"{s}\",\"builtin\":{},\"method\":\"{s}\",\"path\":\"{s}\",\"query\":\"{s}\",\"body\":{d}}}", .{ call.app, call.version, call.builtin, @tagName(call.method), call.path, call.query, call.body.len }) catch "{}" };
    }

    fn shell(ctx: *anyopaque, a: std.mem.Allocator, call: ShellCall) Answer {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        h.shell_calls += 1;
        return .{ .body = std.fmt.allocPrint(a, "{{\"shell\":\"{s}\",\"method\":\"{s}\",\"body\":{d}}}", .{ call.path, @tagName(call.method), call.body.len }) catch "{}" };
    }

    fn wasOpened(ctx: *anyopaque, name: []const u8, version: []const u8) void {
        const h: *FakeHost = @ptrCast(@alignCast(ctx));
        _ = name;
        _ = version;
        h.opened += 1;
    }
};

/// The fixture's server again, answered by `fh`.
fn withHost(f: *Fix, fh: *FakeHost) !void {
    f.s.stop();
    f.s = try Server.start(t.allocator, t.io, .{ .apps_dir = f.apps_dir, .state_dir = f.state_dir, .version = "0.3.0", .host = fh.host() });
    f.host = try std.fmt.allocPrint(f.a, "Host: 127.0.0.1:{d}\r\n", .{f.s.port});
}

test "app_api_calls_reach_the_host_from_the_apps_own_paths" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    // no host: the API is not on
    try t.expectEqual(404, (try get(a, f.s.port, try f.appPath("notes", "1", "api/info"), f.host)).status);
    var fh: FakeHost = .{};
    try withHost(&f, &fh);
    const null_origin = try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{f.host});
    const info = try get(a, f.s.port, try f.appPath("notes", "1", "api/log/runs?after=4"), null_origin);
    try t.expectEqual(200, info.status);
    try t.expectEqualStrings("{\"app\":\"notes\",\"version\":\"1\",\"builtin\":false,\"method\":\"GET\",\"path\":\"log/runs\",\"query\":\"after=4\",\"body\":0}", info.body);
    try expectHas(info.head, "access-control-allow-origin: null");
    try expectHas(info.head, "content-type: application/json");
    try expectHas(info.head, "cache-control: no-store");
    // a call with a body, and the host's own status
    const act = try send(a, f.s.port, "POST", try f.appPath("log", "0.3.0", "api/act"), try std.fmt.allocPrint(a, "{s}Content-Type: application/json\r\n", .{null_origin}), "{\"tool\":\"x\"}");
    try t.expectEqual(200, act.status);
    try expectHas(act.body, "\"app\":\"log\",\"version\":\"0.3.0\",\"builtin\":true,\"method\":\"POST\",\"path\":\"act\",\"query\":\"\",\"body\":12");
    try t.expectEqual(200, (try send(a, f.s.port, "PUT", try f.appPath("notes", "1", "api/data/k"), null_origin, "1")).status);
    try t.expectEqual(200, (try send(a, f.s.port, "DELETE", try f.appPath("notes", "1", "api/data/k"), null_origin, "")).status);
    try t.expectEqual(404, (try get(a, f.s.port, try f.appPath("notes", "1", "api/missing"), f.host)).status);
    // the browser's question before a call with a JSON body from a frame
    const pre = try send(a, f.s.port, "OPTIONS", try f.appPath("notes", "1", "api/act"), null_origin, "");
    try t.expectEqual(204, pre.status);
    for ([_][]const u8{ "access-control-allow-origin: null", "access-control-allow-methods: GET, POST, PUT, DELETE", "access-control-allow-headers: content-type" }) |h| try expectHas(pre.head, h);
    const calls = fh.api_calls;
    // only `api/` takes calls; a file is read
    try t.expectEqual(405, (try send(a, f.s.port, "POST", try f.appPath("notes", "1", "js/app.js"), f.host, "x")).status);
    try t.expectEqual(405, (try send(a, f.s.port, "POST", try f.shellPath(""), f.host, "x")).status);
    try t.expectEqual(405, (try send(a, f.s.port, "DELETE", try f.shellPath("notes"), f.host, "")).status);
    // an unknown token, another site, too large a body: not the host's
    try t.expectEqual(404, (try send(a, f.s.port, "POST", "/a/AAAAAAAAAAAAAAAAAAAAAA/api/act", f.host, "{}")).status);
    try t.expectEqual(403, (try send(a, f.s.port, "POST", try f.appPath("notes", "1", "api/act"), try std.fmt.allocPrint(a, "{s}Origin: http://evil.test\r\n", .{f.host}), "{}")).status);
    const big = try a.alloc(u8, max_body + 1);
    @memset(big, 'x');
    try t.expectEqual(413, (try send(a, f.s.port, "POST", try f.appPath("notes", "1", "api/act"), f.host, big)).status);
    try t.expectEqual(calls, fh.api_calls);
    // its page into a frame is told to the host, a script is not
    _ = try get(a, f.s.port, try f.appPath("notes", "1", ""), try f.frame());
    _ = try get(a, f.s.port, try f.appPath("notes", "1", "js/app.js"), f.host);
    try t.expectEqual(1, fh.opened);
}

test "the_bars_calls_need_the_shell_token_and_no_app_path_reaches_them" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var fh: FakeHost = .{};
    try withHost(&f, &fh);
    // harness's pages carry the bar and its script, nothing written into them
    for ([_][]const u8{ "", "notes" }) |page| {
        const got = try get(a, f.s.port, try f.shellPath(page), f.host);
        try t.expectEqual(200, got.status);
        try expectHas(got.body, "<section id=\"bar\"");
        try expectHas(got.body, try std.fmt.allocPrint(a, "data-api=\"/s/{s}/api/\"", .{&f.s.shell_token}));
        try expectHas(got.body, try std.fmt.allocPrint(a, "<script src=\"/s/{s}/shell.js\"></script>", .{&f.s.shell_token}));
        try t.expect(std.mem.indexOf(u8, got.body, "<script>") == null);
    }
    const js = try get(a, f.s.port, try f.shellPath("shell.js"), f.host);
    try t.expectEqual(200, js.status);
    try expectHas(js.head, "content-type: text/javascript");
    try expectHas(js.body, "api + \"answer\"");
    // the bar's calls, with the shell token
    const inbox = try get(a, f.s.port, try f.shellPath("api/inbox"), f.host);
    try t.expectEqualStrings("{\"shell\":\"inbox\",\"method\":\"GET\",\"body\":0}", inbox.body);
    const ans = try send(a, f.s.port, "POST", try f.shellPath("api/answer"), f.host, "{\"id\":3,\"key\":\"once\"}");
    try t.expectEqual(200, ans.status);
    try expectHas(ans.body, "\"shell\":\"answer\",\"method\":\"POST\",\"body\":21");
    try t.expectEqual(2, fh.shell_calls);
    // not with an app's token, an old one, or from a frame (Origin: null)
    try t.expectEqual(404, (try send(a, f.s.port, "POST", try std.fmt.allocPrint(a, "/s/{s}/api/answer", .{&f.s.appToken("notes", "1")}), f.host, "{}")).status);
    try t.expectEqual(404, (try send(a, f.s.port, "POST", "/s/AAAAAAAAAAAAAAAAAAAAAA/api/answer", f.host, "{}")).status);
    try t.expectEqual(403, (try send(a, f.s.port, "POST", try f.shellPath("api/answer"), try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{f.host}), "{}")).status);
    try t.expectEqual(2, fh.shell_calls);
    // an app's own `api/answer` is its API's, which has no such call
    const app_answer = try send(a, f.s.port, "POST", try f.appPath("notes", "1", "api/answer"), f.host, "{\"id\":3,\"key\":\"once\"}");
    try expectHas(app_answer.body, "\"app\":\"notes\"");
    try t.expectEqual(2, fh.shell_calls);
}

test "the_review_page_shows_a_save_in_full_and_its_draft_reads_nothing" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var fh: FakeHost = .{};
    try withHost(&f, &fh);
    try f.tmp.dir.createDirPath(t.io, "ws/draft");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/draft/app.ini", .data = "[app]\nname = notes\ntitle = My <Notes>\nreads = log\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/draft/index.html", .data = "<!doctype html><p>draft & page</p><script src=\"app.js\"></script>" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/draft/app.js", .data = "fetch('api/log')" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "ws/draft/dot.png", .data = "\x89PNG" });
    const root = try f.tmp.dir.realPathFileAlloc(t.io, ".", a);
    const id = "00000000000000d1";
    _ = try apps.stage(t.io, a, f.apps_dir, f.state_dir, "notes", .{ .dir = try std.fs.path.join(a, &.{ root, "ws", "draft" }) }, id);
    const page = try get(a, f.s.port, try f.shellPath("review/00000000000000d1"), f.host);
    try t.expectEqual(200, page.status);
    for ([_][]const u8{ "Review: notes v2", "reads = log", "&lt;p&gt;draft &amp; page&lt;/p&gt;", "fetch(&#39;api/log&#39;)", "dot.png <small>4 bytes", "Not text", "<section id=\"bar\"" }) |want| try expectHas(page.body, want);
    try t.expect(std.mem.indexOf(u8, page.body, "<p>draft") == null);
    const token = f.s.appToken(id, "draft");
    try expectHas(page.body, try std.fmt.allocPrint(a, "src=\"/a/{s}/?in=review\"", .{&token}));
    // the draft runs in its frame, from the copy; its API answers nothing
    const draft = try get(a, f.s.port, try std.fmt.allocPrint(a, "/a/{s}/", .{&token}), try f.frame());
    try t.expectEqual(200, draft.status);
    try expectHas(draft.body, "draft & page");
    try expectHas(draft.head, "sandbox allow-scripts allow-forms");
    try t.expectEqual(403, (try get(a, f.s.port, try std.fmt.allocPrint(a, "/a/{s}/", .{&token}), f.host)).status);
    const api = try get(a, f.s.port, try std.fmt.allocPrint(a, "/a/{s}/api/log", .{&token}), f.host);
    try t.expectEqual(403, api.status);
    try t.expectEqual(403, (try send(a, f.s.port, "POST", try std.fmt.allocPrint(a, "/a/{s}/api/act", .{&token}), f.host, "{}")).status);
    try t.expectEqual(0, fh.api_calls);
    try t.expectEqual(0, fh.opened);
    // answered: the page and the draft are gone
    apps.dropPending(t.io, a, f.state_dir, id);
    try t.expectEqual(404, (try get(a, f.s.port, try f.shellPath("review/00000000000000d1"), f.host)).status);
    try t.expectEqual(404, (try get(a, f.s.port, try std.fmt.allocPrint(a, "/a/{s}/", .{&token}), try f.frame())).status);
    for ([_][]const u8{ "review/../../x", "review/zz", "review/" }) |bad| try t.expectEqual(404, (try get(a, f.s.port, try f.shellPath(bad), f.host)).status);
}

// ---- the desk ----

/// The fixture's server again, with the desk on (DATA is the fixture's
/// folder) and answered by `fh`.
fn withDesk(f: *Fix, fh: *FakeHost) !void {
    f.s.stop();
    const root = try f.tmp.dir.realPathFileAlloc(t.io, ".", f.a);
    try f.tmp.dir.createDirPath(t.io, "state");
    f.s = try Server.start(t.allocator, t.io, .{ .apps_dir = f.apps_dir, .state_dir = f.state_dir, .version = "0.3.0", .host = fh.host(), .desk = .{ .home = root, .state = try std.fs.path.join(f.a, &.{ root, "state" }) } });
    f.host = try std.fmt.allocPrint(f.a, "Host: 127.0.0.1:{d}\r\n", .{f.s.port});
}

/// What the desk app does: asks for a code, reads it, enters; returns the
/// code and the session's Cookie header line.
fn enterDesk(f: *Fix) !struct { code: []const u8, cookie: []const u8, entered: Got } {
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "state/open-request", .data = "" });
    var waited: u32 = 0;
    const code = while (waited < 3000) : (waited += 20) {
        if (f.tmp.dir.readFileAlloc(t.io, "state/desk-code", f.a, .limited(64))) |x| {
            if (x.len > 0) break std.mem.trim(u8, x, " \r\n");
        } else |_| {}
        t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    } else return error.NoCode;
    const got = try get(f.a, f.s.port, try std.fmt.allocPrint(f.a, "/enter?code={s}", .{code}), f.host);
    const at = std.mem.indexOf(u8, got.head, "set-cookie: harness_desk=") orelse return .{ .code = code, .cookie = "", .entered = got };
    const v = got.head[at + "set-cookie: ".len ..];
    const tok = v[0..std.mem.indexOfScalar(u8, v, ';').?];
    return .{ .code = code, .cookie = try std.fmt.allocPrint(f.a, "Cookie: {s}\r\n", .{tok}), .entered = got };
}

test "alive_answers_and_nothing_else" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    var fh: FakeHost = .{};
    try withDesk(&f, &fh);
    const got = try get(f.a, f.s.port, "/alive", f.host);
    try t.expectEqual(200, got.status);
    try t.expectEqualStrings("", got.body);
    try expectHas(got.head, "cache-control: no-store");
    try t.expectEqual(403, (try get(f.a, f.s.port, "/alive", try std.fmt.allocPrint(f.a, "Host: localhost:{d}\r\n", .{f.s.port}))).status);
    try t.expectEqual(405, (try send(f.a, f.s.port, "POST", "/alive", f.host, "")).status);
}

test "enter_sets_a_session_cookie_once" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    var fh: FakeHost = .{};
    try withDesk(&f, &fh);
    const e = try enterDesk(&f);
    // the request was taken
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/open-request", .{}));
    try t.expectEqual(303, e.entered.status);
    try expectHas(e.entered.head, "location: /desk");
    try expectHas(e.entered.head, "; Path=/; HttpOnly; SameSite=Strict");
    try t.expect(std.mem.indexOf(u8, e.entered.head, "Expires") == null);
    try t.expect(std.mem.indexOf(u8, e.entered.head, "Max-Age") == null);
    // used once: the file is gone, the code refused again
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, "state/desk-code", .{}));
    const again = try get(f.a, f.s.port, try std.fmt.allocPrint(f.a, "/enter?code={s}", .{e.code}), f.host);
    try t.expectEqual(403, again.status);
    try t.expect(std.mem.indexOf(u8, again.head, "set-cookie") == null);
    try t.expectEqual(403, (try get(f.a, f.s.port, "/enter?code=AAAAAAAAAAAAAAAAAAAAAA", f.host)).status);
    try t.expectEqual(403, (try get(f.a, f.s.port, "/enter", f.host)).status);
    // the session opens the desk; nothing reusable was left in the data folder
    try t.expectEqual(200, (try get(f.a, f.s.port, "/desk", try std.fmt.allocPrint(f.a, "{s}{s}", .{ f.host, e.cookie }))).status);
    const tok = e.cookie["Cookie: harness_desk=".len .. e.cookie.len - 2];
    var it = try f.tmp.dir.walk(f.a);
    defer it.deinit();
    while (try it.next(t.io)) |w| if (w.kind == .file) {
        const text = try f.tmp.dir.readFileAlloc(t.io, w.path, f.a, .unlimited);
        try t.expect(std.mem.indexOf(u8, text, tok) == null);
    };
}

test "desk_paths_refuse_a_framed_app_and_need_the_cookie" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var fh: FakeHost = .{};
    try withDesk(&f, &fh);
    const e = try enterDesk(&f);
    const with = try std.fmt.allocPrint(a, "{s}{s}", .{ f.host, e.cookie });
    const ok = try get(a, f.s.port, "/desk/api/state?x=1", with);
    try t.expectEqual(200, ok.status);
    try t.expectEqualStrings("{\"desk\":\"state\",\"method\":\"GET\",\"query\":\"x=1\",\"body\":0,\"type\":\"\"}", ok.body);
    try expectHas(ok.head, "cache-control: no-store");
    const sent = try send(a, f.s.port, "POST", "/desk/api/send", try std.fmt.allocPrint(a, "{s}Content-Type: application/json\r\nOrigin: http://127.0.0.1:{d}\r\n", .{ with, f.s.port }), "{\"conv\":\"main\",\"text\":\"hi\"}");
    try t.expectEqual(200, sent.status);
    try expectHas(sent.body, "\"method\":\"POST\",\"query\":\"\",\"body\":27,\"type\":\"application/json\"");
    try t.expectEqual(2, fh.desk_calls);
    // no cookie, a made-up one: signed out
    const out = try get(a, f.s.port, "/desk/api/state", f.host);
    try t.expectEqual(401, out.status);
    try t.expectEqualStrings("{\"error\":\"signed out\"}", out.body);
    try t.expectEqual(401, (try get(a, f.s.port, "/desk/api/state", try std.fmt.allocPrint(a, "{s}Cookie: harness_desk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\r\n", .{f.host}))).status);
    try t.expectEqual(401, (try get(a, f.s.port, "/desk", f.host)).status);
    // a framed app (Origin: null), even with the cookie, and another site
    try t.expectEqual(403, (try send(a, f.s.port, "POST", "/desk/api/send", try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{with}), "{}")).status);
    try t.expectEqual(403, (try get(a, f.s.port, "/desk/api/state", try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{with}))).status);
    try t.expectEqual(403, (try send(a, f.s.port, "POST", "/desk/api/answer", try std.fmt.allocPrint(a, "{s}Origin: http://evil.test\r\n", .{with}), "{}")).status);
    try t.expectEqual(403, (try get(a, f.s.port, "/desk/avatars/butler/avatar.ini", try std.fmt.allocPrint(a, "{s}Origin: null\r\n", .{with}))).status);
    try t.expectEqual(2, fh.desk_calls);
    // an app's token reaches no desk path
    try t.expectEqual(404, (try get(a, f.s.port, try std.fmt.allocPrint(a, "/a/{s}/desk/api/state", .{&f.s.appToken("notes", "1")}), with)).status);
    try t.expectEqual(2, fh.desk_calls);
}

test "desk_page_and_static_files_with_their_csp" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var fh: FakeHost = .{};
    try withDesk(&f, &fh);
    const e = try enterDesk(&f);
    const with = try std.fmt.allocPrint(a, "{s}{s}", .{ f.host, e.cookie });
    const o = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.s.port});
    const csp = try std.fmt.allocPrint(a, "content-security-policy: default-src 'none'; script-src {0s} 'wasm-unsafe-eval'; style-src {0s}; img-src {0s} blob:; font-src {0s}; media-src {0s} blob:; connect-src {0s}; worker-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'", .{o});
    for ([_][]const u8{ "/desk", "/desk/" }) |p| {
        const page = try get(a, f.s.port, p, with);
        try t.expectEqual(200, page.status);
        try expectHas(page.head, "content-type: text/html; charset=utf-8");
        try expectHas(page.head, csp);
        try expectHas(page.body, "<script type=\"module\" src=\"/desk/static/desk.js\"></script>");
        try t.expect(std.mem.indexOf(u8, page.body, "<script>") == null);
    }
    for ([_][2][]const u8{
        .{ "desk.js", "text/javascript" },
        .{ "avatar.js", "text/javascript" },
        .{ "fit.js", "text/javascript" },
        .{ "vendor/three.module.min.js", "text/javascript" },
        .{ "desk.css", "text/css" },
        .{ "fonts/chakra-petch-latin-400-normal.woff2", "font/woff2" },
        .{ "fonts/jetbrains-mono-latin-ext-500-normal.woff2", "font/woff2" },
        .{ "fonts/OFL-chakra-petch.txt", "text/plain" },
    }) |x| {
        const got = try get(a, f.s.port, try std.fmt.allocPrint(a, "/desk/static/{s}", .{x[0]}), with);
        try t.expectEqual(200, got.status);
        try expectHas(got.head, try std.fmt.allocPrint(a, "content-type: {s}", .{x[1]}));
        try expectHas(got.head, csp);
    }
    try t.expectEqual(404, (try get(a, f.s.port, "/desk/static/nothing.js", with)).status);
    try t.expectEqual(404, (try get(a, f.s.port, "/desk/static/../index.html", with)).status);
    // the stand-in's fit says it isn't there yet
    try expectHas((try get(a, f.s.port, "/desk/static/fit.js", with)).body, "Fitting isn't available yet");
    try expectHas((try get(a, f.s.port, "/desk/static/avatar.js", with)).body, "export async function createAvatar(");
}

test "desk_files_are_served_with_caching_and_no_tricks" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var fh: FakeHost = .{};
    try withDesk(&f, &fh);
    const e = try enterDesk(&f);
    const with = try std.fmt.allocPrint(a, "{s}{s}", .{ f.host, e.cookie });
    try f.tmp.dir.createDirPath(t.io, "avatars/butler");
    try f.tmp.dir.createDirPath(t.io, "desk-assets/mediapipe/wasm");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "avatars/butler/avatar.ini", .data = "[avatar]\nstill = still.jpg\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "avatars/butler/still.jpg", .data = "\xff\xd8\xffportrait" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "desk-assets/mediapipe/wasm/vision_wasm_internal.wasm", .data = "\x00asm\x01" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "desk-assets/base-head.bin", .data = "head" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "config.ini", .data = "[model]\n" });
    const still = try get(a, f.s.port, "/desk/avatars/butler/still.jpg", with);
    try t.expectEqual(200, still.status);
    try t.expectEqualStrings("\xff\xd8\xffportrait", still.body);
    try expectHas(still.head, "content-type: image/jpeg");
    try expectHas(still.head, "cache-control: private, max-age=86400");
    const tag = deskwin.etag("\xff\xd8\xffportrait");
    try expectHas(still.head, try std.fmt.allocPrint(a, "etag: {s}", .{&tag}));
    // asked again with its tag: not sent again
    const same = try get(a, f.s.port, "/desk/avatars/butler/still.jpg", try std.fmt.allocPrint(a, "{s}If-None-Match: {s}\r\n", .{ with, &tag }));
    try t.expectEqual(304, same.status);
    try t.expectEqualStrings("", same.body);
    try expectHas((try get(a, f.s.port, "/desk/avatars/butler/avatar.ini", with)).body, "still = still.jpg");
    const wasm = try get(a, f.s.port, "/desk/assets/mediapipe/wasm/vision_wasm_internal.wasm", with);
    try t.expectEqual(200, wasm.status);
    try expectHas(wasm.head, "content-type: application/wasm");
    try expectHas(wasm.head, "cache-control: private, max-age=86400");
    try t.expectEqual(200, (try get(a, f.s.port, "/desk/assets/base-head.bin", with)).status);
    // without the session, nothing
    try t.expectEqual(401, (try get(a, f.s.port, "/desk/avatars/butler/still.jpg", f.host)).status);
    // tricks
    for ([_][]const u8{
        "/desk/avatars/../config.ini",
        "/desk/avatars/butler/../../config.ini",
        "/desk/avatars/%2e%2e/config.ini",
        "/desk/avatars/Butler/still.jpg",
        "/desk/avatars/butler/",
        "/desk/avatars/butler",
        "/desk/avatars/butler/sub/still.jpg",
        "/desk/avatars/butler/.hidden.jpg",
        "/desk/avatars/butler/con.jpg",
        "/desk/assets/../config.ini",
        "/desk/assets/mediapipe/../../config.ini",
        "/desk/assets/",
        "/desk/assets/nothing.bin",
    }) |tr| {
        const got = try get(a, f.s.port, tr, with);
        if (got.status != 404) std.debug.print("{s}: {d}\n", .{ tr, got.status });
        try t.expectEqual(404, got.status);
    }
    // a link where a file was: never followed (where links can be made)
    if (f.tmp.dir.symLink(t.io, "../../config.ini", "avatars/butler/link.jpg", .{})) {
        try t.expectEqual(404, (try get(a, f.s.port, "/desk/avatars/butler/link.jpg", with)).status);
    } else |_| {}
    // past 20 MB: refused
    const big = try a.alloc(u8, max_desk_file + 1);
    @memset(big, 0);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "desk-assets/big.bin", .data = big });
    try t.expectEqual(413, (try get(a, f.s.port, "/desk/assets/big.bin", with)).status);
}

test "desk_bodies_may_be_10_mb_for_voice_and_upload_only" {
    var f: Fix = undefined;
    try f.init();
    defer f.deinit();
    const a = f.a;
    var fh: FakeHost = .{};
    try withDesk(&f, &fh);
    const e = try enterDesk(&f);
    const with = try std.fmt.allocPrint(a, "{s}{s}", .{ f.host, e.cookie });
    const two = try a.alloc(u8, 2 << 20);
    @memset(two, 'x');
    for ([_][]const u8{ "voice?conv=main", "upload?avatar=mine&part=still&consent=yes" }) |p| {
        const got = try sendBig(a, f.s.port, "POST", try std.fmt.allocPrint(a, "/desk/api/{s}", .{p}), with, two);
        try t.expectEqual(200, got.status);
        try expectHas(got.body, "\"body\":2097152");
    }
    try t.expectEqual(413, (try sendBig(a, f.s.port, "POST", "/desk/api/send", with, two)).status);
    const over = try a.alloc(u8, max_desk_body + 1);
    @memset(over, 'x');
    try t.expectEqual(413, (try sendBig(a, f.s.port, "POST", "/desk/api/voice", with, over)).status);
    try t.expectEqual(2, fh.desk_calls);
}

/// `send` for bodies larger than the socket's buffers.
fn sendBig(a: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, extra: []const u8, body: []const u8) !Got {
    const h = try sock.connect(t.io, "127.0.0.1", port, 2000);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, h, &rbuf, &wbuf, 10_000);
    defer sk.close();
    try sk.writer.print("{s} {s} HTTP/1.1\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, extra, body.len });
    sk.writer.writeAll(body) catch {};
    sk.writer.flush() catch {};
    const all = try sk.reader.allocRemaining(a, .limited(4 << 20));
    const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadResponse;
    const status = try std.fmt.parseInt(u16, all[9..12], 10);
    return .{ .status = status, .head = all[0..split], .body = all[split + 4 ..] };
}

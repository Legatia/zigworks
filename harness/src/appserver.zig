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
};

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

/// What every refusal of a link says: an old start's token and an unknown
/// one alike.
const old_link = "This link is from an earlier start of harness. Ask for the app again.";

const Refusal = enum { host, origin, token, frame };

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    apps_dir: []u8,
    state_dir: []u8,
    version: []u8,
    log: ?*log_mod.Log,
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
    last_refusal_ms: [4]i64 = @splat(-std.math.maxInt(i32)),

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
            .listener = listener,
            .port = listener.port,
            .key = undefined,
            .shell_token = undefined,
        };
        try io.randomSecure(&s.key);
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&s.shell_token, &raw);
        if (s.log) |l| l.write(.app, false, .{ .event = "server started", .port = s.port }) catch {};
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
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
        var waited: u32 = 0;
        while (s.active.load(.acquire) > 0 and waited < 2000) : (waited += 5) s.io.sleep(.fromMilliseconds(5), .awake) catch {};
        s.listener.close();
        // a thread still in a request owns its memory: let it go first
        if (s.active.load(.acquire) > 0) return;
        s.open.deinit(s.gpa);
        s.gpa.free(s.apps_dir);
        s.gpa.free(s.state_dir);
        s.gpa.free(s.version);
        s.gpa.destroy(s);
    }

    /// The link to harness's page of apps, for this start.
    pub fn shellUrl(s: *const Server, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/s/{s}/", .{ s.port, &s.shell_token });
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
        const target = req.head.target;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";
        var host: ?[]const u8 = null;
        var origin: ?[]const u8 = null;
        var dest: ?[]const u8 = null;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "sec-fetch-dest")) dest = h.value;
        }
        const own = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{s.port});
        const own_origin = try std.fmt.allocPrint(a, "http://{s}", .{own});
        // another name for this machine (DNS rebinding) is not this server
        if (host == null or !std.mem.eql(u8, host.?, own)) return s.refuse(req, .host, .forbidden, "Open harness's apps from the link it printed.");
        const in_app = std.mem.startsWith(u8, path, "/a/");
        if (origin) |o| if (!std.mem.eql(u8, o, own_origin) and !(in_app and std.mem.eql(u8, o, "null")))
            return s.refuse(req, .origin, .forbidden, "Requests from other sites are refused.");
        if (req.head.method != .GET and req.head.method != .HEAD) return s.plain(req, .method_not_allowed, "Only GET.", own_origin, null);
        if (std.mem.startsWith(u8, path, "/s/")) return s.shell(a, req, path["/s/".len..], query, own_origin);
        if (in_app) return s.app(a, req, path["/a/".len..], origin, dest, own_origin);
        return s.plain(req, .not_found, old_link, own_origin, null);
    }

    /// `/s/TOKEN/...`: harness's page of apps, one app in its frame.
    fn shell(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, rest: []const u8, query: []const u8, own_origin: []const u8) !bool {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return s.refuse(req, .token, .not_found, old_link);
        if (!tokenEql(rest[0..slash], &s.shell_token)) return s.refuse(req, .token, .not_found, old_link);
        const sub = rest[slash + 1 ..];
        if (sub.len == 0) return s.shellPage(req, try s.homeHtml(a), own_origin);
        if (std.mem.eql(u8, sub, "shell.css")) return s.respond(req, .ok, shell_css, "text/css; charset=utf-8", own_origin, .shell, null);
        if (std.mem.startsWith(u8, sub, "api/") or std.mem.startsWith(u8, sub, "review/")) return s.plain(req, .not_found, "Not here yet.", own_origin, null);
        const found = try s.findApp(a, sub);
        const app_ = found orelse return s.plain(req, .not_found, "No app by that name; the page of apps lists them.", own_origin, null);
        const view = viewOf(query);
        const token = s.appToken(app_.name, app_.version);
        const html = try std.fmt.allocPrint(a,
            \\<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{s}</title>
            \\<link rel="stylesheet" href="shell.css"></head><body>
            \\<header><a href="./">Apps</a><span>{s}</span></header>
            \\<iframe sandbox="allow-scripts allow-forms" referrerpolicy="no-referrer" allow="" src="/a/{s}/?in=page&amp;view={s}" title="{s}"></iframe>
            \\</body></html>
        , .{ try escape(a, app_.title), try escape(a, app_.title), &token, view, try escape(a, app_.title) });
        return s.shellPage(req, html, own_origin);
    }

    const Found = struct { name: []const u8, title: []const u8, version: []const u8, builtin: ?Builtin = null };

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

    fn homeHtml(s: *Server, a: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Apps</title><link rel=\"stylesheet\" href=\"shell.css\"></head><body><header><span>Apps</span></header><main><ul>");
        for (builtins) |b| try out.print(a, "<li><a href=\"{s}\">{s}</a> <small>built in</small></li>", .{ b.name, b.title });
        for (try s.approvedNames(a)) |name| {
            const f = (try s.findApp(a, name)) orelse continue;
            try out.print(a, "<li><a href=\"{s}\">{s}</a> <small>v{s}</small></li>", .{ name, try escape(a, f.title), f.version });
        }
        try out.appendSlice(a, "</ul></main></body></html>");
        return out.items;
    }

    /// `/a/TOKEN/...`: an app's own files (its API under `api/`).
    fn app(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, rest: []const u8, origin: ?[]const u8, dest: ?[]const u8, own_origin: []const u8) !bool {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return s.refuse(req, .token, .not_found, old_link);
        const token = rest[0..slash];
        const sub = rest[slash + 1 ..];
        const cors: ?[]const u8 = if (origin) |o| (if (std.mem.eql(u8, o, "null")) "null" else null) else null;
        // the app whose token it is: built-ins and approved apps, each
        // compared in full
        var hit: ?Found = null;
        for (builtins) |b| if (tokenEql(token, &s.appToken(b.name, s.version))) {
            hit = .{ .name = b.name, .title = b.title, .version = s.version, .builtin = b };
        };
        for (try s.approvedNames(a)) |name| {
            const ap = (try apps.readApproved(s.io, a, s.state_dir, name)) orelse continue;
            const v = try std.fmt.allocPrint(a, "{d}", .{ap.version});
            if (tokenEql(token, &s.appToken(name, v))) hit = .{ .name = name, .title = name, .version = v };
        }
        const found = hit orelse return s.refuse(req, .token, .not_found, old_link);
        if (std.mem.startsWith(u8, sub, "api/")) return s.respond(req, .not_found, "{\"error\":\"the apps' API is not built yet\"}", "application/json", own_origin, .app, cors);
        const rel = if (sub.len == 0) "index.html" else sub;
        if (!apps.servableName(rel)) return s.plain(req, .not_found, "No such file.", own_origin, cors);
        const is_html = std.mem.endsWith(u8, rel, ".html");
        // a page in a tab of its own could navigate itself anywhere
        if (is_html and !(dest != null and std.mem.eql(u8, dest.?, "iframe"))) return s.refuse(req, .frame, .forbidden, "Open the app from harness's page of apps.");
        if (found.builtin) |b| {
            const body = b.file(rel) orelse return s.plain(req, .not_found, "No such file.", own_origin, cors);
            return s.respond(req, .ok, body, contentType(rel), own_origin, .app, cors);
        }
        // its files as approved, before its page is served
        if (is_html and (try apps.asApproved(s.io, a, s.apps_dir, s.state_dir, found.name)) == null) {
            if (s.log) |l| l.write(.app, false, .{ .event = "changed outside harness", .name = found.name }) catch {};
            return s.plain(req, .forbidden, "This app's files changed outside harness; /app approve NAME serves it again.", own_origin, cors);
        }
        const body = (try s.readAppFile(a, found.name, rel)) orelse return s.plain(req, .not_found, "No such file.", own_origin, cors);
        return s.respond(req, .ok, body, contentType(rel), own_origin, .app, cors);
    }

    /// `rel` in app `name`'s folder: each part a folder or, the last, a
    /// file, never a link.
    fn readAppFile(s: *Server, a: std.mem.Allocator, name: []const u8, rel: []const u8) !?[]const u8 {
        var path = try std.fs.path.join(a, &.{ s.apps_dir, name });
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |part| {
            path = try std.fs.path.join(a, &.{ path, part });
            const st = Io.Dir.cwd().statFile(s.io, path, .{ .follow_symlinks = false }) catch return null;
            const last = parts.peek() == null;
            if (last and st.kind != .file) return null;
            if (!last and st.kind != .directory) return null;
        }
        return Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(apps.max_file)) catch null;
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

    const Kind = enum { shell, app, plain };

    /// Every response: no referrer, no sniffing, nothing kept; the shell's
    /// and an app's own CSP.
    fn respond(s: *Server, req: *std.http.Server.Request, status: std.http.Status, body: []const u8, ct: []const u8, own_origin: []const u8, kind: Kind, cors: ?[]const u8) !bool {
        _ = s;
        var buf: [1024]u8 = undefined;
        var headers: [9]std.http.Header = undefined;
        var n: usize = 0;
        headers[n] = .{ .name = "content-type", .value = ct };
        n += 1;
        headers[n] = .{ .name = "referrer-policy", .value = "no-referrer" };
        n += 1;
        headers[n] = .{ .name = "x-content-type-options", .value = "nosniff" };
        n += 1;
        headers[n] = .{ .name = "cache-control", .value = "no-store" };
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
        }
        if (cors) |c| {
            headers[n] = .{ .name = "access-control-allow-origin", .value = c };
            n += 1;
        }
        // an error ends the connection; so does a client that asked to
        const keep = status == .ok and req.head.keep_alive;
        try req.respond(body, .{ .status = status, .extra_headers = headers[0..n], .keep_alive = keep });
        return keep;
    }
};

/// Equal in full, in time that doesn't depend on where they differ.
fn tokenEql(given: []const u8, want: *const [22]u8) bool {
    if (given.len != want.len) return false;
    return std.crypto.timing_safe.eql([22]u8, given[0..22].*, want.*);
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

fn contentType(rel: []const u8) []const u8 {
    const ext = rel[(std.mem.lastIndexOfScalar(u8, rel, '.') orelse return "application/octet-stream") + 1 ..];
    const map = [_][2][]const u8{
        .{ "html", "text/html; charset=utf-8" }, .{ "js", "text/javascript; charset=utf-8" }, .{ "mjs", "text/javascript; charset=utf-8" },
        .{ "css", "text/css; charset=utf-8" },   .{ "json", "application/json" },             .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },                 .{ "jpg", "image/jpeg" },                    .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },               .{ "ico", "image/x-icon" },                  .{ "woff2", "font/woff2" },
        .{ "txt", "text/plain; charset=utf-8" }, .{ "md", "text/markdown; charset=utf-8" },
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
    try t.expect(std.mem.indexOf(u8, shell.body, "<script") == null);
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
        // their API is not here yet
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

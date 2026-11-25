//! Stand-ins for the services harness talks to, driven by files in a script
//! directory so tests can say exactly what each service answers:
//!
//! - models (omnigate and any other provider): `POST …/messages` (Anthropic
//!   Messages) and `POST …/chat/completions` (OpenAI Chat Completions)
//!   answer `model/001.json`, `002.json`, … in order, one count for both,
//!   each file in the format its request was in; a file `{"status":402}` or
//!   `{"status":429,"retry_after":1}` answers that error instead (in the
//!   request's format; with `"echo_key":true` its message says the key the
//!   request carried, as some gateways do), `{"delay_ms":N, ...}` waits
//!   first. Each request is saved as `requests/001.json`, … with its
//!   target, headers and body.
//! - Every file the stand-ins record is written whole, a temporary file
//!   renamed into place, so a test that finds one never reads half of it.
//! - transcription (OpenAI-compatible): `POST …/audio/transcriptions`
//!   answers `transcribe/001.json`, `002.json`, … in order (`{"text":…}`
//!   as it is; `{"status":N}` that error in OpenAI's format, with
//!   `"echo_key":true` its message saying the key; `{"delay_ms":N,…}`
//!   waits first). Each request is saved as `transcribe-requests/001.json`,
//!   … with its target, headers and body (a string).
//! - speech (OpenAI-compatible): `POST …/audio/speech` answers
//!   `audio/mpeg` bytes, "ID3" and the request's `input`; each request is
//!   saved as `speech-requests/001.json`, … with its target, headers and
//!   body.
//! - speech (Gemini's format): `POST …/models/MODEL:generateContent`
//!   answers one inline part of raw PCM (`audio/L16;codec=pcm;rate=24000`)
//!   whose bytes are the request's text (a 0 added to make it even), or
//!   `gemini/001.json`, `002.json`, … when there is one:
//!   `{"status":N}` that error in Google's shape (`"echo_key":true`: its
//!   message says the key), `{"mime":"audio/wav"}` the same audio as a
//!   WAV file, `{"answer":{…}}` that answer as it is. Each request is
//!   saved as `gemini-requests/001.json`, … with its target, headers and
//!   body (a string).
//! - search: `GET /res/v1/web/search?q=…` answers `search.json`.
//! - pages and feeds: `GET /page/NAME` answers the file `pages/NAME`
//!   (POST too; `?delay_ms=N` answers after N ms), or, when there is a
//!   file `pages/NAME.redirect` holding "STATUS LOCATION", that redirect;
//!   `pages/NAME.status` holding "STATUS [RETRY_AFTER]" answers that
//!   status; `pages/NAME.etag` and `pages/NAME.modified` are sent as its
//!   ETag and Last-Modified, and a request carrying the same in
//!   If-None-Match or If-Modified-Since gets 304. Each page request is
//!   appended to `page-requests.jsonl` with its headers.
//! - Telegram: see `telegram` below.
//! - MCP servers over HTTP and an authorization server: `/mcp/FLAVOR`,
//!   `/.well-known/…`, `/auth/…` (fake_mcp.zig's `Http`, steered by tests
//!   through `mcp`); each such request is appended to `mcp-requests.jsonl`
//!   with its method, target, headers and body. `browse` and `Browser`
//!   play the owner's browser for a sign-in.
//! - GitHub's codeload: `GET /codeload/OWNER/REPO/tar.gz/REF` answers the
//!   folder `repos/OWNER/REPO/` as a tar.gz (top folder `REPO-REF/`), its
//!   pax header naming the commit in `repos/OWNER/REPO.commit` (else
//!   0123…); no such folder: 404. Each request is appended to
//!   `codeload-requests.jsonl`.
const std = @import("std");
const sock = @import("sock.zig");
const jv = @import("jv.zig");
const http = @import("http.zig");
const url_mod = @import("url.zig");
const fake_mcp = @import("fake_mcp.zig");
const targz = @import("targz.zig");
const Io = std.Io;

pub const Server = struct {
    io: Io,
    dir: []const u8,
    listener: sock.Listener,
    port: u16,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    model_n: std.atomic.Value(u32) = .init(0),
    /// Transcription requests seen so far.
    stt_n: std.atomic.Value(u32) = .init(0),
    tts_n: std.atomic.Value(u32) = .init(0),
    /// Gemini-format speech requests seen so far.
    gem_n: std.atomic.Value(u32) = .init(0),
    tg_n: std.atomic.Value(u32) = .init(0),
    /// What setMySettings set for topics: 0 nothing yet, 1 off, 2 on.
    tg_topics: std.atomic.Value(u8) = .init(0),
    /// Telegram calls answered with `telegram/fail.json`'s error so far.
    tg_failed: std.atomic.Value(i64) = .init(0),
    mutex: Io.Mutex = .init,
    open: std.ArrayList(sock.Handle) = .empty,
    /// The MCP servers over HTTP.
    mcp: fake_mcp.Http = .{},

    const gpa = std.heap.page_allocator;
    const idle_ms = 60 * 60 * 1000;

    pub fn start(io: Io, dir: []const u8, port: u16) !*Server {
        const listener = try sock.Listener.open(port);
        errdefer listener.close();
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{ .io = io, .dir = try gpa.dupe(u8, dir), .listener = listener, .port = listener.port, .mcp = .{ .io = io } };
        inline for (.{ "requests", "model", "pages", "telegram/in", "telegram/files", "transcribe", "transcribe-requests", "speech-requests", "gemini", "gemini-requests" }) |sub| {
            const p = try std.fs.path.join(gpa, &.{ dir, sub });
            defer gpa.free(p);
            try Io.Dir.cwd().createDirPath(io, p);
        }
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
    }

    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        if (sock.connect(s.io, "127.0.0.1", s.port, 1000)) |c| sock.closeHandle(c) else |_| {}
        if (s.thread) |th| th.join();
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            for (s.open.items) |c| sock.shutdown(c);
        }
        while (s.active.load(.acquire) > 0) s.io.sleep(.fromMilliseconds(1), .awake) catch {};
        s.listener.close();
        s.open.deinit(gpa);
        s.mcp.deinit();
        gpa.free(s.dir);
        gpa.destroy(s);
    }

    /// Model requests seen so far.
    pub fn modelRequests(s: *Server) u32 {
        return s.model_n.load(.acquire);
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
        var rbuf: [64 * 1024]u8 = undefined;
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

    fn path(s: *Server, a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(a, s.dir);
        try all.appendSlice(a, parts);
        return std.fs.path.join(a, all.items);
    }

    fn readScript(s: *Server, a: std.mem.Allocator, parts: []const []const u8) ?[]u8 {
        const p = s.path(a, parts) catch return null;
        return Io.Dir.cwd().readFileAlloc(s.io, p, a, .limited(16 << 20)) catch null;
    }

    /// Writes record file `p` whole: a temporary file, then renamed into
    /// place, so a test that finds `p` never reads it half written.
    fn writeRecord(s: *Server, a: std.mem.Allocator, p: []const u8, data: []const u8) !void {
        const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{p});
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(s.io, .{ .sub_path = tmp, .data = data });
        // on Windows a reader that has the old file open can hold the
        // rename up for a moment
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (cwd.rename(tmp, cwd, p, s.io)) |_| return else |e| if (tries >= 100) {
                cwd.deleteFile(s.io, tmp) catch {};
                return e;
            }
            s.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }

    /// Adds `line` to the end of record file `p`, written whole again
    /// (callers hold `mutex`: one writer at a time).
    fn appendRecord(s: *Server, a: std.mem.Allocator, p: []const u8, line: []const u8) !void {
        const old: []const u8 = Io.Dir.cwd().readFileAlloc(s.io, p, a, .limited(256 << 20)) catch |e| switch (e) {
            error.FileNotFound => "",
            else => return e,
        };
        try s.writeRecord(a, p, try std.mem.concat(a, u8, &.{ old, line }));
    }

    fn handle(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const target = try a.dupe(u8, req.head.target);
        const method = req.head.method;
        var headers: std.ArrayList(u8) = .empty;
        // the key a model request carries, for `echo_key`
        var key: []const u8 = "";
        // a page request's conditions
        var if_none_match: ?[]const u8 = null;
        var if_modified_since: ?[]const u8 = null;
        // all of them, for the MCP servers
        var all: std.ArrayList(fake_mcp.Header) = .empty;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            try headers.print(a, "{f}:{f},", .{ std.json.fmt(h.name, .{}), std.json.fmt(h.value, .{}) });
            try all.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
            if (std.ascii.eqlIgnoreCase(h.name, "if-none-match")) if_none_match = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "if-modified-since")) if_modified_since = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "x-api-key") or std.ascii.eqlIgnoreCase(h.name, "x-goog-api-key")) key = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "authorization") and std.mem.startsWith(u8, h.value, "Bearer ")) key = try a.dupe(u8, h.value["Bearer ".len..]);
        }
        var body_buf: [8192]u8 = undefined;
        const body_reader = try req.readerExpectContinue(&body_buf);
        const body = try body_reader.allocRemaining(a, .limited(32 << 20));
        const route = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        if (std.mem.startsWith(u8, route, "/mcp/") or std.mem.startsWith(u8, route, "/.well-known/") or std.mem.startsWith(u8, route, "/auth/")) {
            {
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                const lp = try s.path(a, &.{"mcp-requests.jsonl"});
                const line = try std.fmt.allocPrint(a, "{{\"method\":\"{s}\",\"target\":{f},\"headers\":{{{s}\"\":\"\"}},\"body\":{f}}}\n", .{ @tagName(method), std.json.fmt(target, .{}), headers.items, std.json.fmt(body, .{}) });
                try s.appendRecord(a, lp, line);
            }
            return s.mcp.handle(.{ .io = s.io, .dir = s.dir, .port = s.port, .stopping = &s.stopping }, a, req, method, target, all.items, body);
        }

        if (method == .POST and !std.mem.startsWith(u8, route, "/page/") and !std.mem.startsWith(u8, route, "/bot")) {
            if (std.mem.endsWith(u8, route, "/messages")) return s.model(a, req, .anthropic, target, body, headers.items, key);
            if (std.mem.endsWith(u8, route, "/chat/completions")) return s.model(a, req, .openai, target, body, headers.items, key);
            if (std.mem.endsWith(u8, route, "/audio/transcriptions")) return s.transcribe(a, req, target, body, headers.items, key);
            if (std.mem.endsWith(u8, route, "/audio/speech")) return s.speech(a, req, target, body, headers.items);
            if (std.mem.endsWith(u8, route, ":generateContent")) return s.gemini(a, req, target, body, headers.items, key);
        }
        if (method == .GET and std.mem.eql(u8, route, "/res/v1/web/search")) {
            const text = s.readScript(a, &.{"search.json"}) orelse "{\"web\":{\"results\":[]}}";
            return json(req, .ok, text);
        }
        if ((method == .GET or method == .POST) and std.mem.startsWith(u8, route, "/page/")) {
            const name = route["/page/".len..];
            {
                // every page request, with its headers
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                const lp = try s.path(a, &.{"page-requests.jsonl"});
                const line = try std.fmt.allocPrint(a, "{{\"target\":{f},\"headers\":{{{s}\"\":\"\"}}}}\n", .{ std.json.fmt(target, .{}), headers.items });
                try s.appendRecord(a, lp, line);
            }
            // `pages/NAME.redirect` holds "STATUS LOCATION"
            if (name.len > 0 and std.mem.indexOf(u8, name, "..") == null) {
                if (s.readScript(a, &.{ "pages", try std.fmt.allocPrint(a, "{s}.redirect", .{name}) })) |r| {
                    const line = std.mem.trim(u8, r, " \r\n\t");
                    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
                    const st = std.fmt.parseInt(u10, line[0..sp], 10) catch 302;
                    return req.respond("", .{ .status = @fromBackingInt(st), .extra_headers = &.{.{ .name = "location", .value = std.mem.trim(u8, line[sp..], " ") }} });
                }
            }
            // `?delay_ms=N`: a slow page
            if (std.mem.indexOf(u8, target, "delay_ms=")) |at| {
                const digits = target[at + "delay_ms=".len ..];
                var n: usize = 0;
                while (n < digits.len and std.ascii.isDigit(digits[n])) n += 1;
                const ms = std.fmt.parseInt(i96, digits[0..n], 10) catch 0;
                const until = Io.Clock.awake.now(s.io).nanoseconds + ms * std.time.ns_per_ms;
                while (Io.Clock.awake.now(s.io).nanoseconds < until and !s.stopping.load(.acquire)) s.io.sleep(.fromMilliseconds(20), .awake) catch {};
            }
            if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return json(req, .not_found, "{}");
            // `pages/NAME.status`: "STATUS [RETRY_AFTER]"
            if (s.readScript(a, &.{ "pages", try std.fmt.allocPrint(a, "{s}.status", .{name}) })) |st_text| {
                var parts = std.mem.tokenizeAny(u8, st_text, " \r\n\t");
                const st = std.fmt.parseInt(u10, parts.next() orelse "500", 10) catch 500;
                if (parts.next()) |retry| return req.respond("{}", .{ .status = @fromBackingInt(st), .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "retry-after", .value = retry },
                } });
                return json(req, @fromBackingInt(st), "{}");
            }
            const etag = if (s.readScript(a, &.{ "pages", try std.fmt.allocPrint(a, "{s}.etag", .{name}) })) |x| std.mem.trim(u8, x, " \r\n\t") else null;
            const modified = if (s.readScript(a, &.{ "pages", try std.fmt.allocPrint(a, "{s}.modified", .{name}) })) |x| std.mem.trim(u8, x, " \r\n\t") else null;
            var extra: [3]std.http.Header = undefined;
            var n: usize = 0;
            if (etag) |e| {
                extra[n] = .{ .name = "etag", .value = e };
                n += 1;
            }
            if (modified) |m| {
                extra[n] = .{ .name = "last-modified", .value = m };
                n += 1;
            }
            const same_tag = etag != null and if_none_match != null and std.mem.eql(u8, etag.?, if_none_match.?);
            const same_time = modified != null and if_modified_since != null and std.mem.eql(u8, modified.?, if_modified_since.?);
            if (same_tag or same_time) return req.respond("", .{ .status = .not_modified, .extra_headers = extra[0..n] });
            const text = s.readScript(a, &.{ "pages", name }) orelse return json(req, .not_found, "{}");
            const ct = if (std.mem.endsWith(u8, name, ".bin")) "application/octet-stream" else if (std.mem.endsWith(u8, name, ".xml")) "application/rss+xml" else if (std.mem.endsWith(u8, name, ".json")) "application/json" else if (std.mem.endsWith(u8, name, ".txt")) "text/plain; charset=utf-8" else "text/html; charset=utf-8";
            extra[n] = .{ .name = "content-type", .value = ct };
            n += 1;
            return req.respond(text, .{ .extra_headers = extra[0..n] });
        }
        if (method == .GET and std.mem.startsWith(u8, route, "/codeload/")) return s.codeload(a, req, route);
        if (method == .GET and std.mem.startsWith(u8, route, "/file/bot")) return s.telegramFile(a, req, route);
        if (std.mem.startsWith(u8, route, "/bot")) return s.telegram(a, req, route, body);
        return json(req, .not_found, "{\"error\":\"no such route\"}");
    }

    /// codeload.github.com's tar.gz of a folder of the script's `repos/`.
    fn codeload(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, route: []const u8) !void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            try s.appendRecord(a, try s.path(a, &.{"codeload-requests.jsonl"}), try std.fmt.allocPrint(a, "{{\"target\":{f}}}\n", .{std.json.fmt(route, .{})}));
        }
        var parts = std.mem.splitScalar(u8, route["/codeload/".len..], '/');
        const owner = parts.next() orelse "";
        const repo_name = parts.next() orelse "";
        const kind = parts.next() orelse "";
        const ref = parts.rest();
        if (owner.len == 0 or repo_name.len == 0 or ref.len == 0 or !std.mem.eql(u8, kind, "tar.gz") or std.mem.indexOf(u8, route, "..") != null) return json(req, .not_found, "{}");
        const root = try s.path(a, &.{ "repos", owner, repo_name });
        const commit = if (s.readScript(a, &.{ "repos", owner, try std.fmt.allocPrint(a, "{s}.commit", .{repo_name}) })) |c| std.mem.trim(u8, c, " \r\n") else "0123456789abcdef0123456789abcdef01234567";
        const top = try std.fmt.allocPrint(a, "{s}-{s}", .{ repo_name, ref });
        for (top) |*ch| if (ch.* == '/') {
            ch.* = '-';
        };
        var entries: std.ArrayList(targz.Entry) = .empty;
        try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/", .{top}), .kind = .dir });
        var d = Io.Dir.cwd().openDir(s.io, root, .{ .iterate = true }) catch return json(req, .not_found, "{}");
        defer d.close(s.io);
        var w = try d.walk(a);
        defer w.deinit();
        while (try w.next(s.io)) |e| {
            if (e.kind != .file) continue;
            const rel = try a.dupe(u8, e.path);
            for (rel) |*ch| if (ch.* == '\\') {
                ch.* = '/';
            };
            const data = try d.readFileAlloc(s.io, e.path, a, .limited(64 << 20));
            const exec = @import("builtin").os.tag != .windows and if (d.statFile(s.io, e.path, .{})) |st| st.permissions.toMode() & 0o111 != 0 else |_| false;
            try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}/{s}", .{ top, rel }), .data = data, .exec = exec });
        }
        const gz = try targz.write(a, commit, entries.items);
        return req.respond(gz, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/x-gzip" }} });
    }

    /// The format a model request is in, and its errors are answered in.
    const Format = enum { anthropic, openai };

    fn model(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, format: Format, target: []const u8, body: []const u8, headers: []const u8, key: []const u8) !void {
        const n = s.model_n.fetchAdd(1, .acq_rel) + 1;
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>3}.json", .{n});
        const saved = try std.fmt.allocPrint(a, "{{\"target\":{f},\"headers\":{{{s}\"\":\"\"}},\"body\":{s}}}", .{ std.json.fmt(target, .{}), headers, if (body.len > 0) body else "null" });
        const rp = try s.path(a, &.{ "requests", name });
        try s.writeRecord(a, rp, saved);
        const script = s.readScript(a, &.{ "model", name }) orelse
            return json(req, .internal_server_error, try errorBody(a, format, 500, "no script for this request"));
        const v = jv.parse(a, script);
        if (jv.int(jv.get(v, "delay_ms"))) |ms| {
            // By the clock, not by counting sleeps: on a busy machine each sleep runs long.
            const until = Io.Clock.awake.now(s.io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
            while (Io.Clock.awake.now(s.io).nanoseconds < until and !s.stopping.load(.acquire)) s.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        if (jv.int(jv.get(v, "status"))) |st| {
            const status: std.http.Status = @fromBackingInt(@as(u10, @intCast(st)));
            const retry = jv.int(jv.get(v, "retry_after"));
            var rb: [16]u8 = undefined;
            const echo = jv.boolean(jv.get(v, "echo_key")) orelse false;
            const msg = if (echo) try std.fmt.allocPrint(a, "scripted error for key {s}", .{key}) else "scripted error";
            const err_body = try errorBody(a, format, st, msg);
            if (retry) |r| {
                return req.respond(err_body, .{ .status = status, .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "retry-after", .value = try std.fmt.bufPrint(&rb, "{d}", .{r}) },
                } });
            }
            return json(req, status, err_body);
        }
        return json(req, .ok, script);
    }

    /// `…/audio/transcriptions`: the next `transcribe/NNN.json` (see the
    /// top of the file); the request kept as `transcribe-requests/NNN.json`.
    fn transcribe(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, target: []const u8, body: []const u8, headers: []const u8, key: []const u8) !void {
        const n = s.stt_n.fetchAdd(1, .acq_rel) + 1;
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>3}.json", .{n});
        const saved = try std.fmt.allocPrint(a, "{{\"target\":{f},\"headers\":{{{s}\"\":\"\"}},\"body\":{f}}}", .{ std.json.fmt(target, .{}), headers, std.json.fmt(body, .{}) });
        try s.writeRecord(a, try s.path(a, &.{ "transcribe-requests", name }), saved);
        const script = s.readScript(a, &.{ "transcribe", name }) orelse
            return json(req, .internal_server_error, try errorBody(a, .openai, 500, "no script for this request"));
        const v = jv.parse(a, script);
        if (jv.int(jv.get(v, "delay_ms"))) |ms| {
            const until = Io.Clock.awake.now(s.io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
            while (Io.Clock.awake.now(s.io).nanoseconds < until and !s.stopping.load(.acquire)) s.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        if (jv.int(jv.get(v, "status"))) |st| {
            const echo = jv.boolean(jv.get(v, "echo_key")) orelse false;
            const msg = if (echo) try std.fmt.allocPrint(a, "scripted error for key {s}", .{key}) else "scripted error";
            return json(req, @fromBackingInt(@as(u10, @intCast(st))), try errorBody(a, .openai, st, msg));
        }
        return json(req, .ok, script);
    }

    /// `…/audio/speech`: "ID3" and the request's input, as audio; the
    /// request kept as `speech-requests/NNN.json`.
    fn speech(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, target: []const u8, body: []const u8, headers: []const u8) !void {
        const n = s.tts_n.fetchAdd(1, .acq_rel) + 1;
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>3}.json", .{n});
        const saved = try std.fmt.allocPrint(a, "{{\"target\":{f},\"headers\":{{{s}\"\":\"\"}},\"body\":{f}}}", .{ std.json.fmt(target, .{}), headers, std.json.fmt(body, .{}) });
        try s.writeRecord(a, try s.path(a, &.{ "speech-requests", name }), saved);
        const input = jv.str(jv.get(jv.parse(a, body), "input")) orelse return json(req, .bad_request, try errorBody(a, .openai, 400, "no input"));
        try req.respond(try std.fmt.allocPrint(a, "ID3{s}", .{input}), .{ .extra_headers = &.{.{ .name = "content-type", .value = "audio/mpeg" }} });
    }

    /// `…/models/MODEL:generateContent`: the request's text as raw PCM, or
    /// `gemini/NNN.json` (see the top of the file); the request kept as
    /// `gemini-requests/NNN.json`.
    fn gemini(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, target: []const u8, body: []const u8, headers: []const u8, key: []const u8) !void {
        const n = s.gem_n.fetchAdd(1, .acq_rel) + 1;
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>3}.json", .{n});
        const saved = try std.fmt.allocPrint(a, "{{\"target\":{f},\"headers\":{{{s}\"\":\"\"}},\"body\":{f}}}", .{ std.json.fmt(target, .{}), headers, std.json.fmt(body, .{}) });
        try s.writeRecord(a, try s.path(a, &.{ "gemini-requests", name }), saved);
        const v: ?jv.Value = if (s.readScript(a, &.{ "gemini", name })) |x| jv.parse(a, x) else null;
        if (jv.int(jv.get(v, "status"))) |st| {
            const echo = jv.boolean(jv.get(v, "echo_key")) orelse false;
            const msg = if (echo) try std.fmt.allocPrint(a, "scripted error for key {s}", .{key}) else "scripted error";
            return json(req, @fromBackingInt(@as(u10, @intCast(st))), try std.fmt.allocPrint(a, "{{\"error\":{{\"code\":{d},\"message\":{f},\"status\":\"SCRIPTED\"}}}}", .{ st, std.json.fmt(msg, .{}) }));
        }
        if (jv.get(v, "answer")) |ans| return json(req, .ok, try std.json.Stringify.valueAlloc(a, ans, .{}));
        const text = jv.str(jv.at(jv.parse(a, body), &.{ "contents", "0", "parts", "0", "text" })) orelse
            return json(req, .bad_request, "{\"error\":{\"code\":400,\"message\":\"no text\",\"status\":\"INVALID_ARGUMENT\"}}");
        var pcm: std.ArrayList(u8) = .empty;
        try pcm.appendSlice(a, text);
        if (pcm.items.len % 2 == 1) try pcm.append(a, 0);
        const as_wav = std.mem.eql(u8, jv.str(jv.get(v, "mime")) orelse "", "audio/wav");
        var audio: std.ArrayList(u8) = .empty;
        if (as_wav) {
            // RIFF, mono, 16-bit, 24 kHz
            const len: u32 = @intCast(pcm.items.len);
            try audio.appendSlice(a, "RIFF");
            try audio.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, 36 + len)));
            try audio.appendSlice(a, "WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\xc0\x5d\x00\x00\x80\xbb\x00\x00\x02\x00\x10\x00data");
            try audio.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, len)));
        }
        try audio.appendSlice(a, pcm.items);
        const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(audio.items.len));
        const mime = if (as_wav) "audio/wav" else "audio/L16;codec=pcm;rate=24000";
        return json(req, .ok, try std.fmt.allocPrint(a, "{{\"candidates\":[{{\"content\":{{\"role\":\"model\",\"parts\":[{{\"inlineData\":{{\"mimeType\":\"{s}\",\"data\":\"{s}\"}}}}]}},\"finishReason\":\"STOP\",\"index\":0}}],\"modelVersion\":\"stand-in\"}}", .{ mime, std.base64.standard.Encoder.encode(b64, audio.items) }));
    }

    /// A file of Telegram's (`GET /file/bot<token>/<path>`, a path getFile
    /// gave: `voice/ID.oga`): `telegram/files/ID`. Recorded in out.jsonl as
    /// `{"method":"download","path":…}`, without the token.
    fn telegramFile(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, route: []const u8) !void {
        const rest = route["/file/bot".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return json(req, .not_found, "{\"ok\":false}");
        const file_path = rest[slash + 1 ..];
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const line = try std.fmt.allocPrint(a, "{{\"method\":\"download\",\"path\":{f}}}\n", .{std.json.fmt(file_path, .{})});
            try s.appendRecord(a, try s.path(a, &.{ "telegram", "out.jsonl" }), line);
        }
        const base = std.fs.path.basename(file_path);
        const id = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
        const data = if (id.len > 0 and std.mem.indexOf(u8, file_path, "..") == null) s.readScript(a, &.{ "telegram", "files", id }) else null;
        const d = data orelse return json(req, .not_found, "{\"ok\":false,\"error_code\":404,\"description\":\"Not Found\"}");
        return req.respond(d, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }} });
    }

    /// Telegram Bot API: `getUpdates` hands out the files in
    /// `telegram/in/` in name order (each one update object, the update_id
    /// is assigned here), at most one batch per call; sent messages and
    /// other calls are appended to `telegram/out.jsonl`, each line with the
    /// message id the call is answered with
    /// (`{"method":"sendMessage","message_id":3,"body":{...}}`; a body that
    /// is not JSON, a document's, as a string). `getFile` answers the file
    /// `telegram/files/ID` as `voice/ID.oga` (400 when there is none). `getMe` answers
    /// `telegram/me.json` (default: a bot with topics on),
    /// `createForumTopic` thread 5000 + its number (an error while
    /// `telegram/no-topics` exists). With
    /// `telegram/fail.json` (`{"status":429,"retry_after":1,"count":N}`)
    /// the first N other calls of the server's life answer that error
    /// instead, and are not recorded.
    fn telegram(s: *Server, a: std.mem.Allocator, req: *std.http.Server.Request, route: []const u8, body: []const u8) !void {
        const slash = std.mem.indexOfScalarPos(u8, route, 1, '/') orelse return json(req, .not_found, "{\"ok\":false}");
        const method = route[slash + 1 ..];
        if (std.mem.eql(u8, method, "getUpdates")) {
            const v = jv.parse(a, body);
            const offset = jv.int(jv.get(v, "offset")) orelse 0;
            const timeout = jv.int(jv.get(v, "timeout")) orelse 0;
            var waited: i64 = 0;
            while (true) {
                const batch = try s.pending(a, offset);
                if (batch.len > 2 or waited >= timeout * 1000 or s.stopping.load(.acquire)) {
                    const out = try std.fmt.allocPrint(a, "{{\"ok\":true,\"result\":[{s}]}}", .{batch});
                    return json(req, .ok, out);
                }
                s.io.sleep(.fromMilliseconds(50), .awake) catch {};
                waited += 50;
            }
        }
        if (s.readScript(a, &.{ "telegram", "fail.json" })) |script| {
            const v = jv.parse(a, script);
            const count = jv.int(jv.get(v, "count")) orelse 1;
            if (s.tg_failed.fetchAdd(1, .acq_rel) < count) {
                const st = jv.int(jv.get(v, "status")) orelse 500;
                const status: std.http.Status = @fromBackingInt(@as(u10, @intCast(st)));
                const out = if (jv.int(jv.get(v, "retry_after"))) |r|
                    try std.fmt.allocPrint(a, "{{\"ok\":false,\"error_code\":{d},\"description\":\"Too Many Requests: retry after {d}\",\"parameters\":{{\"retry_after\":{d}}}}}", .{ st, r, r })
                else
                    try std.fmt.allocPrint(a, "{{\"ok\":false,\"error_code\":{d},\"description\":\"scripted\"}}", .{st});
                return json(req, status, out);
            }
        }
        if (std.mem.eql(u8, method, "createForumTopic") and s.readScript(a, &.{ "telegram", "no-topics" }) != null)
            return json(req, .bad_request, "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: topics are not enabled in this chat\"}");
        // setMySettings refused while telegram/no-settings exists; else
        // getMe answers what it set
        if (std.mem.eql(u8, method, "setMySettings")) {
            if (s.readScript(a, &.{ "telegram", "no-settings" }) != null)
                return json(req, .bad_request, "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: method is not available\"}");
            const on = jv.boolean(jv.get(jv.parse(a, body), "has_topics_enabled")) orelse false;
            s.tg_topics.store(if (on) 2 else 1, .release);
        }
        // an edit of a message listed in telegram/gone: Telegram no longer has it
        if (std.mem.eql(u8, method, "editMessageText")) if (s.readScript(a, &.{ "telegram", "gone" })) |gone| {
            const id = jv.int(jv.get(jv.parse(a, body), "message_id")) orelse 0;
            var it = std.mem.tokenizeAny(u8, gone, " \r\n");
            while (it.next()) |w| if ((std.fmt.parseInt(i64, w, 10) catch -1) == id)
                return json(req, .bad_request, "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: message to edit not found\"}");
        };
        // record everything else, with the message id it is answered with
        // (numbered under the lock, so the lines and the ids agree)
        const n = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const id = s.tg_n.fetchAdd(1, .acq_rel) + 1;
            const op = try s.path(a, &.{ "telegram", "out.jsonl" });
            // a body that is not JSON (a document's multipart) as a string
            const json_body = body.len > 0 and body[0] == '{';
            const line = if (body.len == 0)
                try std.fmt.allocPrint(a, "{{\"method\":\"{s}\",\"message_id\":{d},\"body\":null}}\n", .{ method, id })
            else if (json_body)
                try std.fmt.allocPrint(a, "{{\"method\":\"{s}\",\"message_id\":{d},\"body\":{s}}}\n", .{ method, id, body })
            else
                try std.fmt.allocPrint(a, "{{\"method\":\"{s}\",\"message_id\":{d},\"body\":{f}}}\n", .{ method, id, std.json.fmt(body, .{}) });
            try s.appendRecord(a, op, line);
            break :blk id;
        };
        // getMe: telegram/me.json, else a bot with topics in private chats
        if (std.mem.eql(u8, method, "getMe")) {
            const scripted = s.readScript(a, &.{ "telegram", "me.json" });
            const set = s.tg_topics.load(.acquire);
            if (set != 0) {
                const name = if (scripted) |x| jv.str(jv.get(jv.parse(a, x), "username")) orelse "harness_test_bot" else "harness_test_bot";
                return json(req, .ok, try std.fmt.allocPrint(a, "{{\"ok\":true,\"result\":{{\"id\":1,\"is_bot\":true,\"first_name\":\"harness\",\"username\":{f},\"has_topics_enabled\":{}}}}}", .{ std.json.fmt(name, .{}), set == 2 }));
            }
            const me = scripted orelse "{\"id\":1,\"is_bot\":true,\"first_name\":\"harness\",\"username\":\"harness_test_bot\",\"has_topics_enabled\":true}";
            return json(req, .ok, try std.fmt.allocPrint(a, "{{\"ok\":true,\"result\":{s}}}", .{std.mem.trim(u8, me, " \r\n")}));
        }
        // getFile: telegram/files/ID, as voice/ID.oga; none: a 400
        if (std.mem.eql(u8, method, "getFile")) {
            const id = jv.str(jv.get(jv.parse(a, body), "file_id")) orelse "";
            const usable = id.len > 0 and std.mem.indexOfAny(u8, id, "/\\.") == null;
            const data = if (usable) s.readScript(a, &.{ "telegram", "files", id }) else null;
            const d = data orelse return json(req, .bad_request, "{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: invalid file_id\"}");
            return json(req, .ok, try std.fmt.allocPrint(a, "{{\"ok\":true,\"result\":{{\"file_id\":{f},\"file_unique_id\":\"u{d}\",\"file_size\":{d},\"file_path\":\"voice/{s}.oga\"}}}}", .{ std.json.fmt(id, .{}), n, d.len, id }));
        }
        // a new topic's thread: 5000 and its call's number
        if (std.mem.eql(u8, method, "createForumTopic"))
            return json(req, .ok, try std.fmt.allocPrint(a, "{{\"ok\":true,\"result\":{{\"message_thread_id\":{d},\"name\":\"topic\"}}}}", .{5000 + n}));
        const out = try std.fmt.allocPrint(a, "{{\"ok\":true,\"result\":{{\"message_id\":{d}}}}}", .{n});
        return json(req, .ok, out);
    }

    /// Updates with id ≥ offset, as a JSON list body (no brackets).
    fn pending(s: *Server, a: std.mem.Allocator, offset: i64) ![]u8 {
        const dir = try s.path(a, &.{ "telegram", "in" });
        var d = Io.Dir.cwd().openDir(s.io, dir, .{ .iterate = true }) catch return a.dupe(u8, "");
        defer d.close(s.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json")) try names.append(a, try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        var out: std.ArrayList(u8) = .empty;
        for (names.items, 1..) |name, id| {
            if (@as(i64, @intCast(id)) < offset) continue;
            const text = d.readFileAlloc(s.io, name, a, .limited(1 << 20)) catch continue;
            const trimmed = std.mem.trim(u8, text, " \r\n\t");
            if (trimmed.len < 2 or trimmed[0] != '{') continue;
            if (out.items.len > 0) try out.append(a, ',');
            try out.print(a, "{{\"update_id\":{d},{s}", .{ id, trimmed[1..] });
        }
        return out.items;
    }
};

pub const BrowseOptions = struct {
    /// A path asked of the host it is sent back to first (as a browser
    /// asks for /favicon.ico).
    first: ?[]const u8 = null,
    /// Replaces the state the way back carries.
    state: ?[]const u8 = null,
};

pub const Page = struct {
    status: u16,
    body: []const u8,
    /// Where it was sent back to ("" when it wasn't).
    back: []const u8 = "",
    /// The status `first` got.
    first_status: u16 = 0,
};

/// A browser for sign-ins: opens `link` and follows one redirect (to
/// 127.0.0.1 only); the last page's status and body (in `a`).
pub fn browse(io: Io, a: std.mem.Allocator, link: []const u8, o: BrowseOptions) !Page {
    const first = try get(io, a, link);
    if (first.status < 300 or first.status >= 400) return .{ .status = first.status, .body = first.body };
    var back = first.location;
    const u = try url_mod.parse(a, back);
    if (!std.mem.eql(u8, u.host, "127.0.0.1")) return error.NotThisMachine;
    var page: Page = .{ .status = 0, .body = "" };
    if (o.first) |p| page.first_status = (try get(io, a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ u.port, p }))).status;
    if (o.state) |st| if (std.mem.indexOf(u8, back, "state=")) |at| {
        const end = std.mem.indexOfScalarPos(u8, back, at, '&') orelse back.len;
        back = try std.fmt.allocPrint(a, "{s}state={s}{s}", .{ back[0..at], st, back[end..] });
    };
    const last = try get(io, a, back);
    page.status = last.status;
    page.body = last.body;
    page.back = back;
    return page;
}

/// Home Assistant's llama.cpp integration, as harness's voice agent sees
/// it: `body` POSTed to `link` with `token` as its API key; the answer's
/// status and body.
pub fn sayAsHomeAssistant(io: Io, a: std.mem.Allocator, link: []const u8, token: []const u8, body: []const u8) !Page {
    const u = try url_mod.parse(a, link);
    var c = http.Client.init(a, io, .{ .https = u.https, .host = u.connectHost(), .port = u.port, .prefix = "" });
    defer c.deinit();
    var resp = try c.send(.{ .path = u.target, .body = body, .key = token, .resend = false, .limits = .{ .idle_ms = 60_000, .total_ms = 60_000 } });
    defer resp.deinit();
    return .{ .status = resp.status, .body = resp.readAll(a, 1 << 20) catch "" };
}

const Got = struct { status: u16, body: []const u8, location: []const u8 };

fn get(io: Io, a: std.mem.Allocator, link: []const u8) !Got {
    const u = try url_mod.parse(a, link);
    var c = http.Client.init(a, io, .{ .https = u.https, .host = u.connectHost(), .port = u.port, .prefix = "" });
    defer c.deinit();
    var resp = try c.send(.{ .method = .GET, .path = u.target, .accept = "text/html", .limits = .{ .idle_ms = 15_000, .total_ms = 15_000 } });
    defer resp.deinit();
    const body = resp.readAll(a, 1 << 20) catch "";
    return .{ .status = resp.status, .body = body, .location = if (resp.location) |l| try a.dupe(u8, l) else "" };
}

/// One request to the desk's server on 127.0.0.1:`port`, its own
/// connection; `cookie` the session ("" none).
fn deskReq(io: Io, a: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, cookie: []const u8, body: []const u8) !struct { status: u16, head: []const u8, body: []const u8 } {
    const h = try sock.connect(io, "127.0.0.1", port, 2000);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(io, h, &rbuf, &wbuf, 40_000);
    defer sk.close();
    try sk.writer.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n", .{ method, path, port });
    if (cookie.len > 0) try sk.writer.print("Cookie: harness_desk={s}\r\n", .{cookie});
    if (body.len > 0) try sk.writer.print("Content-Type: application/json\r\nOrigin: http://127.0.0.1:{d}\r\n", .{port});
    try sk.writer.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try sk.writer.writeAll(body);
    try sk.writer.flush();
    const all = try sk.reader.allocRemaining(a, .limited(4 << 20));
    const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadResponse;
    if (all.len < 12) return error.BadResponse;
    return .{ .status = try std.fmt.parseInt(u16, all[9..12], 10), .head = all[0..split], .body = all[split + 4 ..] };
}

/// Header `name`'s value in a response head (any case); null without it.
fn headerOf(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// `harness-fake --desk HOME TEXT`: what the desk app and its page do,
/// over HTTP: a code asked for (state/open-request), read and deleted,
/// entered for a session cookie; the page and the state read; TEXT sent in
/// main; the events long-polled until harness's reply, which is then asked
/// for read aloud (`speech STATUS TYPE` and the audio's first 4 bytes, or
/// the error). A line each.
pub fn deskClient(io: Io, a: std.mem.Allocator, home: []const u8, text: []const u8) !void {
    const out = Io.File.stdout();
    const state = try std.fs.path.join(a, &.{ home, "state" });
    const info = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ state, "desk.json" }), a, .limited(64 << 10));
    const port: u16 = @intCast(jv.int(jv.get(jv.parse(a, info), "port")) orelse return error.NoPort);
    const code_path = try std.fs.path.join(a, &.{ state, "desk-code" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ state, "open-request" }), .data = "" });
    var waited: u32 = 0;
    const code = while (waited < 5000) : (waited += 50) {
        if (Io.Dir.cwd().readFileAlloc(io, code_path, a, .limited(64))) |x| {
            const c = std.mem.trim(u8, x, " \r\n");
            if (c.len > 0) break c;
        } else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    } else return error.NoCode;
    Io.Dir.cwd().deleteFile(io, code_path) catch {};
    try out.writeStreamingAll(io, "code read\n");
    const entered = try deskReq(io, a, port, "GET", try std.fmt.allocPrint(a, "/enter?code={s}", .{code}), "", "");
    const at = std.mem.indexOf(u8, entered.head, "set-cookie: harness_desk=") orelse return error.NoSession;
    const v = entered.head[at + "set-cookie: harness_desk=".len ..];
    const cookie = v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse return error.NoSession];
    try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "entered {d}{s}\n", .{ entered.status, if (std.mem.indexOf(u8, entered.head, "HttpOnly; SameSite=Strict") != null) " httponly samesite" else "" }));
    // the same code again: refused
    try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "again {d}\n", .{(try deskReq(io, a, port, "GET", try std.fmt.allocPrint(a, "/enter?code={s}", .{code}), "", "")).status}));
    const page = try deskReq(io, a, port, "GET", "/desk", cookie, "");
    try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "page {d}{s}\n", .{ page.status, if (std.mem.indexOf(u8, page.body, "/desk/static/desk.js") != null) " with its script" else "" }));
    const st = try deskReq(io, a, port, "GET", "/desk/api/state", cookie, "");
    const sv = jv.parse(a, st.body);
    var seq = jv.int(jv.get(sv, "seq")) orelse 0;
    try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "state {d} {s}\n", .{ st.status, jv.str(jv.get(sv, "state")) orelse "?" }));
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "{\"conv\":\"main\",\"text\":");
    try @import("util.zig").jsonString(&body, a, text);
    try body.append(a, '}');
    const sent = try deskReq(io, a, port, "POST", "/desk/api/send", cookie, body.items);
    try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "sent {d}\n", .{sent.status}));
    // the events until harness's reply in main
    var tries: u32 = 0;
    while (tries < 8) : (tries += 1) {
        const ev = try deskReq(io, a, port, "GET", try std.fmt.allocPrint(a, "/desk/api/events?after={d}&wait=5", .{seq}), cookie, "");
        const e = jv.parse(a, ev.body);
        seq = jv.int(jv.get(e, "seq")) orelse seq;
        const list = jv.get(e, "events") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |x| {
            if (!std.mem.eql(u8, jv.str(jv.get(x, "type")) orelse "", "message")) continue;
            const m = jv.get(x, "msg");
            const from = jv.str(jv.get(m, "from")) orelse "";
            const words = jv.str(jv.get(m, "text")) orelse "";
            try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ from, words }));
            if (std.mem.eql(u8, from, "harness")) {
                // read aloud, as the page asks for it
                const sp = try deskReq(io, a, port, "POST", "/desk/api/speech", cookie, try std.fmt.allocPrint(a, "{{\"id\":{d}}}", .{jv.int(jv.get(m, "id")) orelse 0}));
                const shown = if (sp.status == 200) sp.body[0..@min(4, sp.body.len)] else sp.body[0..@min(200, sp.body.len)];
                try out.writeStreamingAll(io, try std.fmt.allocPrint(a, "speech {d} {s} {s}\n", .{ sp.status, headerOf(sp.head, "content-type") orelse "-", shown }));
                return;
            }
        }
    }
    return error.NoReply;
}

/// The desk's port, from state/desk.json.
fn deskPort(io: Io, a: std.mem.Allocator, home: []const u8) !u16 {
    const info = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ home, "state", "desk.json" }), a, .limited(64 << 10));
    return @intCast(jv.int(jv.get(jv.parse(a, info), "port")) orelse return error.NoPort);
}

/// `harness-fake --desk-enter HOME`: as the desk app enters (a code asked
/// for, read, entered); prints the session cookie.
pub fn deskEnter(io: Io, a: std.mem.Allocator, home: []const u8) !void {
    const port = try deskPort(io, a, home);
    const state = try std.fs.path.join(a, &.{ home, "state" });
    const code_path = try std.fs.path.join(a, &.{ state, "desk-code" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ state, "open-request" }), .data = "" });
    var waited: u32 = 0;
    const code = while (waited < 5000) : (waited += 50) {
        if (Io.Dir.cwd().readFileAlloc(io, code_path, a, .limited(64))) |x| {
            const c = std.mem.trim(u8, x, " \r\n");
            if (c.len > 0) break c;
        } else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    } else return error.NoCode;
    Io.Dir.cwd().deleteFile(io, code_path) catch {};
    const entered = try deskReq(io, a, port, "GET", try std.fmt.allocPrint(a, "/enter?code={s}", .{code}), "", "");
    const at = std.mem.indexOf(u8, entered.head, "set-cookie: harness_desk=") orelse return error.NoSession;
    const v = entered.head[at + "set-cookie: harness_desk=".len ..];
    const cookie = v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse return error.NoSession];
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "{s}\n", .{cookie}));
}

/// `harness-fake --desk-api HOME COOKIE METHOD PATH [BODY]`: one call of
/// the desk's API (`/desk/api/PATH`); prints the status, then the body.
pub fn deskApiCall(io: Io, a: std.mem.Allocator, home: []const u8, cookie: []const u8, method: []const u8, path: []const u8, body: []const u8) !u16 {
    const port = try deskPort(io, a, home);
    const got = try deskReq(io, a, port, method, try std.fmt.allocPrint(a, "/desk/api/{s}", .{path}), cookie, body);
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "{d}\n{s}\n", .{ got.status, got.body }));
    return got.status;
}

/// The owner's browser in sign-in tests: told the link (`opened`, as an
/// oauth.Link), it opens it on a thread of its own; `join`, then read what
/// it got.
pub const Browser = struct {
    io: Io,
    first: ?[]const u8 = null,
    state: ?[]const u8 = null,
    link_buf: [4096]u8 = undefined,
    link_len: usize = 0,
    back_buf: [1024]u8 = undefined,
    back_len: usize = 0,
    body_buf: [1024]u8 = undefined,
    body_len: usize = 0,
    status: u16 = 0,
    first_status: u16 = 0,
    thread: ?std.Thread = null,

    pub fn opened(ctx: ?*anyopaque, link: []const u8, port: u16) void {
        _ = port;
        const b: *Browser = @ptrCast(@alignCast(ctx.?));
        const n = @min(link.len, b.link_buf.len);
        @memcpy(b.link_buf[0..n], link[0..n]);
        b.link_len = n;
        b.thread = std.Thread.spawn(.{}, run, .{b}) catch null;
    }

    fn run(b: *Browser) void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const p = browse(b.io, arena.allocator(), b.link_buf[0..b.link_len], .{ .first = b.first, .state = b.state }) catch return;
        b.status = p.status;
        b.first_status = p.first_status;
        const n = @min(p.body.len, b.body_buf.len);
        @memcpy(b.body_buf[0..n], p.body[0..n]);
        b.body_len = n;
        const m = @min(p.back.len, b.back_buf.len);
        @memcpy(b.back_buf[0..m], p.back[0..m]);
        b.back_len = m;
    }

    pub fn join(b: *Browser) void {
        if (b.thread) |th| th.join();
        b.thread = null;
    }

    pub fn body(b: *const Browser) []const u8 {
        return b.body_buf[0..b.body_len];
    }

    /// Where it was sent back to (the listener's address).
    pub fn back(b: *const Browser) []const u8 {
        return b.back_buf[0..b.back_len];
    }
};

/// A model error's body: Anthropic's `{"type":"error","error":{...}}` or
/// OpenAI's `{"error":{"message":...,"type":...,"code":N}}`.
fn errorBody(a: std.mem.Allocator, format: Server.Format, status: i64, msg: []const u8) ![]u8 {
    return switch (format) {
        .anthropic => std.fmt.allocPrint(a, "{{\"type\":\"error\",\"error\":{{\"type\":\"scripted\",\"message\":{f}}}}}", .{std.json.fmt(msg, .{})}),
        .openai => std.fmt.allocPrint(a, "{{\"error\":{{\"message\":{f},\"type\":\"scripted\",\"code\":{d}}}}}", .{ std.json.fmt(msg, .{}), status }),
    };
}

fn json(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

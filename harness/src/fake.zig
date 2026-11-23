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
const std = @import("std");
const sock = @import("sock.zig");
const jv = @import("jv.zig");
const http = @import("http.zig");
const url_mod = @import("url.zig");
const fake_mcp = @import("fake_mcp.zig");
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
    tg_n: std.atomic.Value(u32) = .init(0),
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
        inline for (.{ "requests", "model", "pages", "telegram/in", "telegram/files", "transcribe", "transcribe-requests" }) |sub| {
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
            if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) key = try a.dupe(u8, h.value);
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
        if (method == .GET and std.mem.startsWith(u8, route, "/file/bot")) return s.telegramFile(a, req, route);
        if (std.mem.startsWith(u8, route, "/bot")) return s.telegram(a, req, route, body);
        return json(req, .not_found, "{\"error\":\"no such route\"}");
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
            const me = s.readScript(a, &.{ "telegram", "me.json" }) orelse "{\"id\":1,\"is_bot\":true,\"first_name\":\"harness\",\"username\":\"harness_test_bot\",\"has_topics_enabled\":true}";
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

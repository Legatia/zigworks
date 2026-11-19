//! The gateway: listens on this machine only. A request to
//! http://127.0.0.1:PORT/NAME/path that carries NAME's placeholder, and
//! that NAME's rule allows, goes to NAME's upstream with the real value in
//! the rule's header. The answer comes back with the value masked. Every
//! request, allowed or not, is one line in the log.
const std = @import("std");
const sock = @import("sock.zig");
const rules = @import("rules.zig");
const scrub = @import("scrub.zig");
const upstream = @import("upstream.zig");
const Io = std.Io;

pub const Entry = struct {
    rule: rules.Rule,
    value: []const u8,
    placeholder: []const u8,
};

pub const Deny = struct {
    status: std.http.Status,
    reason: []const u8,
};

pub const Decision = union(enum) {
    forward: struct {
        entry: usize,
        /// After "/NAME", with the query: what goes upstream after the base.
        rest: []const u8,
        /// `rest` without the query, as the rules saw it.
        path: []const u8,
    },
    deny: Deny,
};

/// Whether a request may go upstream, from its head alone.
pub fn decide(entries: []const Entry, port: u16, method: []const u8, target: []const u8, headers: []const std.http.Header, now: i64) Decision {
    // A page in a browser can send requests here too; it can't make one
    // whose Host says this machine (DNS rebinding) without the browser
    // sending its own name.
    const host = headerValue(headers, "host") orelse return deny(.forbidden, "no Host header");
    if (!isOwnHost(host, port)) return deny(.forbidden, "Host is not this gateway");
    if (target.len < 2 or target[0] != '/') return deny(.bad_request, "the path is /NAME/...");
    const name_end = std.mem.indexOfAnyPos(u8, target, 1, "/?#") orelse target.len;
    const name = target[1..name_end];
    const idx = for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.rule.name, name)) break i;
    } else return deny(.not_found, "no secret by that name");
    const e = entries[idx];
    var rest = target[name_end..];
    if (rest.len == 0 or rest[0] != '/') {
        if (rest.len > 0 and rest[0] != '?') return deny(.bad_request, "bad path");
        rest = target[name_end..];
    }
    const path = if (rest.len == 0 or rest[0] == '?') "/" else (rules.cleanPath(rest) orelse return deny(.bad_request, "the path has .., //, or an encoded / or ."));
    var carried = false;
    for (headers) |h| {
        if (std.mem.indexOf(u8, h.value, e.placeholder) != null) carried = true;
    }
    if (!carried) return deny(.unauthorized, "the request does not carry this secret's placeholder");
    if (std.ascii.eqlIgnoreCase(method, "CONNECT") or headerValue(headers, "upgrade") != null) return deny(.bad_request, "upgrades and CONNECT are not passed on");
    return switch (e.rule.permits(method, path, now)) {
        .ok => .{ .forward = .{ .entry = idx, .rest = rest, .path = path } },
        .expired => deny(.forbidden, "this secret's rule has expired"),
        .not_allowed => deny(.forbidden, "no allow line covers this method and path"),
    };
}

fn deny(status: std.http.Status, reason: []const u8) Decision {
    return .{ .deny = .{ .status = status, .reason = reason } };
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn isOwnHost(host: []const u8, port: u16) bool {
    var buf: [32]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, ":{d}", .{port}) catch return false;
    if (!std.mem.endsWith(u8, host, p)) return false;
    const h = host[0 .. host.len - p.len];
    return std.mem.eql(u8, h, "127.0.0.1") or std.ascii.eqlIgnoreCase(h, "localhost") or std.mem.eql(u8, h, "[::1]");
}

/// Headers that belong to one connection, not to the request.
fn hopByHop(name: []const u8) bool {
    const list = [_][]const u8{ "host", "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade", "content-length", "accept-encoding", "expect", "proxy-authorization", "proxy-authenticate", "proxy-connection" };
    for (list) |l| if (std.ascii.eqlIgnoreCase(name, l)) return true;
    return false;
}

/// The request line and headers for the upstream.
pub fn upstreamHead(a: std.mem.Allocator, e: Entry, method: []const u8, rest: []const u8, headers: []const std.http.Header, body_len: usize) ![]u8 {
    var w: Io.Writer.Allocating = .init(a);
    const up = e.rule.upstream;
    const path = if (rest.len == 0 or rest[0] == '?') try std.fmt.allocPrint(a, "/{s}", .{rest}) else rest;
    try w.writer.print("{s} {s}{s} HTTP/1.1\r\n", .{ method, up.base, path });
    const v6 = std.mem.indexOfScalar(u8, up.host, ':') != null;
    try w.writer.print("Host: {s}{s}{s}", .{ if (v6) "[" else "", up.host, if (v6) "]" else "" });
    if (up.port != @as(u16, if (up.https) 443 else 80)) try w.writer.print(":{d}", .{up.port});
    try w.writer.writeAll("\r\n");
    for (headers) |h| {
        if (hopByHop(h.name)) continue;
        if (std.ascii.eqlIgnoreCase(h.name, e.rule.header_name)) continue;
        if (std.mem.indexOf(u8, h.value, e.placeholder) != null) continue;
        try w.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    const at = std.mem.indexOf(u8, e.rule.header_value, "{secret}").?;
    try w.writer.print("{s}: {s}{s}{s}\r\n", .{ e.rule.header_name, e.rule.header_value[0..at], e.value, e.rule.header_value[at + "{secret}".len ..] });
    try w.writer.writeAll("Accept-Encoding: identity\r\nConnection: close\r\n");
    if (body_len > 0 or methodHasBody(method)) try w.writer.print("Content-Length: {d}\r\n", .{body_len});
    try w.writer.writeAll("\r\n");
    return w.toOwnedSlice();
}

fn methodHasBody(m: []const u8) bool {
    return std.mem.eql(u8, m, "POST") or std.mem.eql(u8, m, "PUT") or std.mem.eql(u8, m, "PATCH");
}

/// One JSON line per request, appended to a file.
pub const Log = struct {
    file: Io.File,
    offset: u64,
    mutex: Io.Mutex = .init,

    pub fn open(io: Io, path: []const u8) !Log {
        if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
        const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600) });
        return .{ .file = f, .offset = try f.length(io) };
    }

    pub fn close(l: *Log, io: Io) void {
        l.file.close(io);
    }

    pub const Line = struct {
        time: i64,
        secret: []const u8,
        method: []const u8,
        path: []const u8,
        result: []const u8,
        reason: ?[]const u8 = null,
        status: ?u16 = null,
        masked: usize = 0,
    };

    pub fn write(l: *Log, io: Io, line: Line) void {
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        format(&w, line) catch return;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.file.writePositionalAll(io, w.buffered(), l.offset) catch return;
        l.offset += w.buffered().len;
    }

    pub fn format(w: *Io.Writer, line: Line) !void {
        var tb: [20]u8 = undefined;
        try w.print("{{\"time\":\"{s}\",\"secret\":", .{isoTime(&tb, line.time)});
        try jsonString(w, line.secret);
        try w.writeAll(",\"method\":");
        try jsonString(w, line.method);
        try w.writeAll(",\"path\":");
        try jsonString(w, if (line.path.len > 512) line.path[0..512] else line.path);
        try w.writeAll(",\"result\":");
        try jsonString(w, line.result);
        if (line.reason) |r| {
            try w.writeAll(",\"reason\":");
            try jsonString(w, r);
        }
        if (line.status) |s| try w.print(",\"status\":{d}", .{s});
        if (line.masked > 0) try w.print(",\"masked\":{d}", .{line.masked});
        try w.writeAll("}\n");
    }
};

fn jsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// "2026-11-19T10:04:05Z"
pub fn isoTime(buf: *[20]u8, secs: i64) []const u8 {
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
    // Howard Hinnant's civil_from_days
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)), sod / 3600, sod / 60 % 60, sod % 60,
    }) catch unreachable;
}

pub const Gate = struct {
    gpa: std.mem.Allocator,
    io: Io,
    entries: []const Entry,
    listener: sock.Listener,
    port: u16,
    log: ?*Log,
    certs: upstream.Certs,
    limits: upstream.Limits = .{},
    max_request: usize = 32 * 1024 * 1024,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),

    /// Listens on 127.0.0.1:`port`; 0 takes a free port.
    pub fn start(gpa: std.mem.Allocator, io: Io, entries: []const Entry, port: u16, log: ?*Log) !*Gate {
        const listener = try sock.Listener.open(port);
        errdefer listener.close();
        const g = try gpa.create(Gate);
        g.* = .{ .gpa = gpa, .io = io, .entries = entries, .listener = listener, .port = listener.port, .log = log, .certs = .{ .gpa = gpa } };
        g.thread = try std.Thread.spawn(.{}, acceptLoop, .{g});
        return g;
    }

    /// Blocks until the gateway stops (it doesn't, short of the process
    /// ending).
    pub fn wait(g: *Gate) void {
        if (g.thread) |th| th.join();
        g.thread = null;
    }

    pub fn stop(g: *Gate) void {
        g.stopping.store(true, .release);
        if (sock.connect(g.io, "127.0.0.1", g.port, 1000)) |c| sock.closeHandle(c) else |_| {}
        g.wait();
        while (g.active.load(.acquire) > 0) g.io.sleep(.fromMilliseconds(1), .awake) catch {};
        g.listener.close();
        g.certs.deinit();
        g.gpa.destroy(g);
    }

    fn acceptLoop(g: *Gate) void {
        while (true) {
            const conn = g.listener.accept() catch {
                if (g.stopping.load(.acquire)) return;
                continue;
            };
            if (g.stopping.load(.acquire)) {
                sock.closeHandle(conn);
                return;
            }
            _ = g.active.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, serve, .{ g, conn }) catch {
                sock.closeHandle(conn);
                _ = g.active.fetchSub(1, .acq_rel);
                continue;
            };
            th.detach();
        }
    }

    fn serve(g: *Gate, conn: sock.Handle) void {
        defer _ = g.active.fetchSub(1, .acq_rel);
        defer sock.closeHandle(conn);
        var rbuf: [64 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var sk: sock.Socket = undefined;
        sk.init(g.io, conn, &rbuf, &wbuf, 120_000);
        var server = std.http.Server.init(&sk.reader, &sk.writer);
        while (!g.stopping.load(.acquire)) {
            var req = server.receiveHead() catch return;
            var arena: std.heap.ArenaAllocator = .init(g.gpa);
            defer arena.deinit();
            const keep = g.handle(arena.allocator(), &req) catch return;
            if (!keep) return;
        }
    }

    /// False: close the connection.
    fn handle(g: *Gate, a: std.mem.Allocator, req: *std.http.Server.Request) !bool {
        const method = @tagName(req.head.method);
        const target = try a.dupe(u8, req.head.target);
        var hs: std.ArrayList(std.http.Header) = .empty;
        var it = req.iterateHeaders();
        while (it.next()) |h| try hs.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
        const now: i64 = @intCast(@divFloor(Io.Clock.real.now(g.io).nanoseconds, std.time.ns_per_s));

        const d = decide(g.entries, g.port, method, target, hs.items, now);
        const fwd = switch (d) {
            .deny => |x| {
                const name = secretName(target);
                const known = for (g.entries) |e| {
                    if (std.mem.eql(u8, e.rule.name, name)) break true;
                } else false;
                g.writeLog(a, .{ .time = now, .secret = if (known) name else "?", .method = method, .path = pathForLog(target), .result = "denied", .reason = x.reason, .status = @backingInt(x.status) }, null);
                try respondText(req, x.status, x.reason);
                return req.head.keep_alive;
            },
            .forward => |f| f,
        };
        const e = g.entries[fwd.entry];

        var body: []u8 = &.{};
        if (req.head.content_length != null or req.head.transfer_encoding == .chunked) {
            var bbuf: [16 * 1024]u8 = undefined;
            const r = req.readerExpectContinue(&bbuf) catch return false;
            body = r.allocRemaining(a, .limited(g.max_request)) catch |err| switch (err) {
                error.StreamTooLong => {
                    g.writeLog(a, .{ .time = now, .secret = e.rule.name, .method = method, .path = fwd.path, .result = "denied", .reason = "request body too large", .status = 413 }, e);
                    try respondText(req, .payload_too_large, "request body too large");
                    return false;
                },
                else => return false,
            };
        }

        const head = try upstreamHead(a, e, method, fwd.rest, hs.items, body.len);
        var resp = upstream.exchange(g.gpa, g.io, &g.certs, e.rule.upstream, req.head.method, head, body, g.limits) catch |err| {
            const why: []const u8 = switch (err) {
                error.Compressed => "the service answered compressed, so the answer can't be checked for the secret",
                error.TooLarge => "the answer is too large",
                error.Timeout => "the service did not answer in time",
                error.CertificateRejected => "the service's https certificate was not accepted",
                error.ConnectFailed => "could not connect to the service",
                else => "the service's answer could not be read",
            };
            g.writeLog(a, .{ .time = now, .secret = e.rule.name, .method = method, .path = fwd.path, .result = "failed", .reason = why, .status = 502 }, e);
            try respondText(req, .bad_gateway, why);
            return false;
        };
        defer resp.deinit();

        var s = try scrub.Scrubber.init(a, &.{.{ .name = e.rule.name, .value = e.value }});
        const clean_body = try s.scrubAlloc(a, resp.body);
        var out_headers: std.ArrayList(std.http.Header) = .empty;
        for (resp.headers) |h| {
            if (hopByHop(h.name)) continue;
            try out_headers.append(a, .{ .name = h.name, .value = try s.scrubAlloc(a, h.value) });
        }
        const status: std.http.Status = @fromBackingInt(@as(u10, @intCast(@min(resp.status, 999))));
        g.writeLog(a, .{ .time = now, .secret = e.rule.name, .method = method, .path = fwd.path, .result = "allowed", .status = resp.status, .masked = s.hits }, e);
        try req.respond(clean_body, .{ .status = status, .extra_headers = out_headers.items, .keep_alive = req.head.keep_alive });
        return req.head.keep_alive;
    }

    fn writeLog(g: *Gate, a: std.mem.Allocator, line: Log.Line, e: ?Entry) void {
        const l = g.log orelse return;
        var copy = line;
        if (e) |x| {
            // neither the value nor the placeholder goes in the log
            var s = scrub.Scrubber.init(a, &.{ .{ .name = x.rule.name, .value = x.value }, .{ .name = "placeholder", .value = x.placeholder } }) catch return;
            copy.path = s.scrubAlloc(a, line.path) catch return;
        }
        l.write(g.io, copy);
    }
};

fn secretName(target: []const u8) []const u8 {
    if (target.len < 2 or target[0] != '/') return "";
    const end = std.mem.indexOfAnyPos(u8, target, 1, "/?#") orelse target.len;
    return target[1..end];
}

/// The path after "/NAME", without the query: as allowed requests log it.
fn pathForLog(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const p = target[0..end];
    if (p.len < 2 or p[0] != '/') return p;
    const slash = std.mem.indexOfScalarPos(u8, p, 1, '/') orelse return "/";
    return p[slash..];
}

test "pathForLog drops the secret's name and the query" {
    try t.expectEqualStrings("/a/b", pathForLog("/gh/a/b?x=1"));
    try t.expectEqualStrings("/", pathForLog("/gh"));
    try t.expectEqualStrings("/", pathForLog("/gh?x"));
}

fn respondText(req: *std.http.Server.Request, status: std.http.Status, reason: []const u8) !void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "keygate: {s}\n", .{reason}) catch reason;
    try req.respond(text, .{ .status = status, .keep_alive = req.head.keep_alive, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

const t = std.testing;

fn testEntries(a: std.mem.Allocator) ![]Entry {
    const r = try rules.parse(a,
        \\[gh]
        \\upstream = https://api.github.com
        \\header = Authorization: Bearer {secret}
        \\allow = GET /repos/me/scratch/
        \\expires = 2030-01-01
    );
    const list = try a.alloc(Entry, 1);
    list[0] = .{ .rule = r.ok[0], .value = "ghp_realvalue1234567890", .placeholder = "kg-gh-00112233445566778899aabbccddeeff" };
    return list;
}

fn hdrs(host: []const u8, auth: []const u8) [2]std.http.Header {
    return .{ .{ .name = "Host", .value = host }, .{ .name = "Authorization", .value = auth } };
}

test "decide: allowed request" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const es = try testEntries(arena.allocator());
    const h = hdrs("127.0.0.1:7311", "Bearer kg-gh-00112233445566778899aabbccddeeff");
    const d = decide(es, 7311, "GET", "/gh/repos/me/scratch/contents/x?ref=main", &h, 0);
    try t.expectEqualStrings("/repos/me/scratch/contents/x?ref=main", d.forward.rest);
    try t.expectEqualStrings("/repos/me/scratch/contents/x", d.forward.path);
}

test "decide: refusals" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const es = try testEntries(arena.allocator());
    const good = "Bearer kg-gh-00112233445566778899aabbccddeeff";
    const cases = [_]struct { host: []const u8, auth: []const u8, method: []const u8, target: []const u8, now: i64, status: std.http.Status }{
        .{ .host = "evil.example:7311", .auth = good, .method = "GET", .target = "/gh/repos/me/scratch/x", .now = 0, .status = .forbidden },
        .{ .host = "127.0.0.1:7311", .auth = good, .method = "GET", .target = "/nope/x", .now = 0, .status = .not_found },
        .{ .host = "127.0.0.1:7311", .auth = "Bearer kg-gh-wrong", .method = "GET", .target = "/gh/repos/me/scratch/x", .now = 0, .status = .unauthorized },
        .{ .host = "127.0.0.1:7311", .auth = good, .method = "POST", .target = "/gh/repos/me/scratch/x", .now = 0, .status = .forbidden },
        .{ .host = "127.0.0.1:7311", .auth = good, .method = "GET", .target = "/gh/gists", .now = 0, .status = .forbidden },
        .{ .host = "127.0.0.1:7311", .auth = good, .method = "GET", .target = "/gh/repos/me/scratch/../../other", .now = 0, .status = .bad_request },
        .{ .host = "127.0.0.1:7311", .auth = good, .method = "GET", .target = "/gh/repos/me/scratch%2f..%2fother", .now = 0, .status = .bad_request },
        .{ .host = "127.0.0.1:7311", .auth = good, .method = "GET", .target = "/gh/repos/me/scratch/x", .now = 1893456000, .status = .forbidden },
    };
    for (cases) |c| {
        const h = hdrs(c.host, c.auth);
        const d = decide(es, 7311, c.method, c.target, &h, c.now);
        try t.expectEqual(c.status, d.deny.status);
    }
}

test "upstream head: real value in the rule's header, placeholder and hop headers gone" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = try testEntries(a);
    const in = [_]std.http.Header{
        .{ .name = "Host", .value = "127.0.0.1:7311" },
        .{ .name = "Authorization", .value = "Bearer kg-gh-00112233445566778899aabbccddeeff" },
        .{ .name = "X-Other", .value = "token kg-gh-00112233445566778899aabbccddeeff" },
        .{ .name = "Accept-Encoding", .value = "gzip" },
        .{ .name = "Accept", .value = "application/json" },
    };
    const head = try upstreamHead(a, es[0], "GET", "/repos/me/scratch/x?ref=a", &in, 0);
    try t.expectEqualStrings(
        "GET /repos/me/scratch/x?ref=a HTTP/1.1\r\n" ++
            "Host: api.github.com\r\n" ++
            "Accept: application/json\r\n" ++
            "Authorization: Bearer ghp_realvalue1234567890\r\n" ++
            "Accept-Encoding: identity\r\nConnection: close\r\n\r\n",
        head,
    );
}

test "log lines are JSON and hold no value" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try Log.format(&w, .{ .time = 1796083200, .secret = "gh", .method = "GET", .path = "/a\"b", .result = "denied", .reason = "no", .status = 403 });
    try t.expectEqualStrings("{\"time\":\"2026-12-01T00:00:00Z\",\"secret\":\"gh\",\"method\":\"GET\",\"path\":\"/a\\\"b\",\"result\":\"denied\",\"reason\":\"no\",\"status\":403}\n", w.buffered());
}

test "isoTime" {
    var b: [20]u8 = undefined;
    try t.expectEqualStrings("1970-01-01T00:00:00Z", isoTime(&b, 0));
    try t.expectEqualStrings("2024-02-29T23:59:59Z", isoTime(&b, 1709251199));
}

// End to end: a stand-in service that echoes what it got, including the
// real value; the gateway in front of it.

const Echo = struct {
    listener: sock.Listener,
    thread: std.Thread,

    fn start() !Echo {
        const l = try sock.Listener.open(0);
        return .{ .listener = l, .thread = try std.Thread.spawn(.{}, run, .{l}) };
    }

    fn run(l: sock.Listener) void {
        const io = t.io;
        while (true) {
            const conn = l.accept() catch return;
            defer sock.closeHandle(conn);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var sk: sock.Socket = undefined;
            sk.init(io, conn, &rbuf, &wbuf, 5000);
            var server = std.http.Server.init(&sk.reader, &sk.writer);
            var req = server.receiveHead() catch continue;
            if (std.mem.eql(u8, req.head.target, "/quit")) {
                req.respond("", .{ .keep_alive = false }) catch {};
                return;
            }
            var out: [4096]u8 = undefined;
            var w: Io.Writer = .fixed(&out);
            w.print("{s} {s}\n", .{ @tagName(req.head.method), req.head.target }) catch {};
            var it = req.iterateHeaders();
            var auth: []const u8 = "";
            while (it.next()) |h| {
                w.print("{s}: {s}\n", .{ h.name, h.value }) catch {};
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = h.value;
            }
            req.respond(w.buffered(), .{ .keep_alive = false, .extra_headers = &.{.{ .name = "x-echo-auth", .value = auth }} }) catch {};
        }
    }

    fn stop(e: *Echo) void {
        if (sock.connect(t.io, "127.0.0.1", e.listener.port, 1000)) |c| {
            var rb: [256]u8 = undefined;
            var wb: [256]u8 = undefined;
            var sk: sock.Socket = undefined;
            sk.init(t.io, c, &rb, &wb, 1000);
            sk.writer.writeAll("GET /quit HTTP/1.1\r\nHost: x\r\n\r\n") catch {};
            sk.writer.flush() catch {};
            if (sk.reader.allocRemaining(t.allocator, .limited(1024))) |b| t.allocator.free(b) else |_| {}
            sk.close();
        } else |_| {}
        e.thread.join();
        e.listener.close();
    }
};

fn ask(port: u16, request: []const u8) ![]u8 {
    const c = try sock.connect(t.io, "127.0.0.1", port, 2000);
    var rb: [16 * 1024]u8 = undefined;
    var wb: [4096]u8 = undefined;
    var sk: sock.Socket = undefined;
    sk.init(t.io, c, &rb, &wb, 5000);
    defer sk.close();
    try sk.writer.writeAll(request);
    try sk.writer.flush();
    return sk.reader.allocRemaining(t.allocator, .limited(64 * 1024));
}

test "end to end: the service gets the value, the caller never sees it" {
    var echo = try Echo.start();
    defer echo.stop();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.fmt.allocPrint(a,
        \\[svc]
        \\upstream = http://127.0.0.1:{d}/base
        \\header = Authorization: Bearer {{secret}}
        \\allow = GET /items/
    , .{echo.listener.port});
    const r = (try rules.parse(a, text)).ok;
    const ph = "kg-svc-ffeeddccbbaa99887766554433221100";
    const es = [_]Entry{.{ .rule = r[0], .value = "sk_live_realvalue_abcdef123456", .placeholder = ph }};

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const log_path = try std.fs.path.join(a, &.{ dir, "log.jsonl" });
    var log = try Log.open(t.io, log_path);
    defer log.close(t.io);

    const g = try Gate.start(t.allocator, t.io, &es, 0, &log);
    defer g.stop();

    const ok = try ask(g.port, try std.fmt.allocPrint(a, "GET /svc/items/1?x=2 HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{ g.port, ph }));
    defer t.allocator.free(ok);
    try t.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200"));
    // the service saw the real value (echoed back), the caller sees a mask
    try t.expect(std.mem.indexOf(u8, ok, "GET /base/items/1?x=2") != null);
    try t.expect(std.mem.indexOf(u8, ok, "Authorization: Bearer [keygate:svc]") != null);
    try t.expect(std.mem.indexOf(u8, ok, "x-echo-auth: Bearer [keygate:svc]") != null);
    try t.expect(std.mem.indexOf(u8, ok, "sk_live_realvalue") == null);

    const no_ph = try ask(g.port, try std.fmt.allocPrint(a, "GET /svc/items/1 HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{g.port}));
    defer t.allocator.free(no_ph);
    try t.expect(std.mem.startsWith(u8, no_ph, "HTTP/1.1 401"));

    const wrong_path = try ask(g.port, try std.fmt.allocPrint(a, "GET /svc/admin HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{ g.port, ph }));
    defer t.allocator.free(wrong_path);
    try t.expect(std.mem.startsWith(u8, wrong_path, "HTTP/1.1 403"));

    const logged = try Io.Dir.cwd().readFileAlloc(t.io, log_path, a, .limited(64 * 1024));
    try t.expectEqual(3, std.mem.count(u8, logged, "\n"));
    try t.expect(std.mem.indexOf(u8, logged, "\"result\":\"allowed\",\"status\":200,\"masked\":") != null);
    try t.expect(std.mem.indexOf(u8, logged, "sk_live") == null);
    try t.expect(std.mem.indexOf(u8, logged, ph) == null);
}

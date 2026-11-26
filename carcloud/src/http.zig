//! A small HTTP/1.1 client for talking to model servers: JSON requests,
//! answers read whole or as they arrive (for streamed answers), time limits
//! on everything, https, and one kept-open connection per client.
const std = @import("std");
const sock = @import("sock.zig");
const Io = std.Io;
const tls = std.crypto.tls;

pub const Error = error{
    /// The server didn't answer, or stopped answering, within the limits.
    Timeout,
    /// No connection could be opened.
    ConnectFailed,
    /// The connection ended before the answer was complete.
    ConnectionClosed,
    /// The https handshake failed for another reason than the certificate.
    TlsFailed,
    /// The server's https certificate was not accepted.
    CertificateRejected,
    /// What came back isn't HTTP as this client understands it.
    BadResponse,
    BadUrl,
    OutOfMemory,
};

/// Where a server is: parsed from "http://host:port/prefix".
pub const Target = struct {
    https: bool,
    host: []const u8,
    port: u16,
    /// Path before "/v1/...": "" for most servers.
    prefix: []const u8,

    /// Accepts "host:port", "http://host:port", and a trailing "/" or "/v1".
    /// The result points into `url`.
    pub fn parse(url: []const u8) Error!Target {
        var rest = url;
        var https = false;
        if (std.mem.startsWith(u8, rest, "https://")) {
            https = true;
            rest = rest[8..];
        } else if (std.mem.startsWith(u8, rest, "http://")) {
            rest = rest[7..];
        } else if (std.mem.indexOf(u8, rest, "://") != null) return error.BadUrl;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var authority = rest[0..slash];
        var prefix = rest[slash..];
        while (std.mem.endsWith(u8, prefix, "/")) prefix = prefix[0 .. prefix.len - 1];
        if (std.mem.endsWith(u8, prefix, "/v1")) prefix = prefix[0 .. prefix.len - 3];
        if (std.mem.indexOfAny(u8, prefix, "?# \r\n") != null) return error.BadUrl;
        var port: u16 = if (https) 443 else 80;
        if (std.mem.startsWith(u8, authority, "[")) {
            // [::1]:8080
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadUrl;
            const after = authority[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return error.BadUrl;
                port = std.fmt.parseInt(u16, after[1..], 10) catch return error.BadUrl;
            }
            authority = authority[1..close];
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.BadUrl;
            authority = authority[0..colon];
        }
        if (authority.len == 0 or port == 0) return error.BadUrl;
        for (authority) |ch| if (ch <= ' ' or ch == '@' or ch >= 0x7f) return error.BadUrl;
        return .{ .https = https, .host = authority, .port = port, .prefix = prefix };
    }
};

pub const Limits = struct {
    /// Longest wait for the connection to open and for each read to bring
    /// something.
    idle_ms: u32 = 30_000,
    /// Longest the whole exchange may take; null: no limit.
    total_ms: ?u32 = null,
};

pub const Request = struct {
    method: enum { GET, POST } = .POST,
    /// Path after the target's prefix, as "/v1/models".
    path: []const u8,
    /// JSON to send.
    body: ?[]const u8 = null,
    /// The body's type (OAuth token endpoints take form data).
    content_type: []const u8 = "application/json",
    /// Sent as "Authorization: Bearer ...".
    key: ?[]const u8 = null,
    /// More headers, sent after the defaults.
    headers: []const std.http.Header = &.{},
    limits: Limits = .{},
};

const read_buf_len = 64 * 1024;
const write_buf_len = 32 * 1024;
/// How much of a request waits unencrypted: one TLS record's worth, never
/// more. std's `tls.Client` flush (Zig 0.17.1) encrypts as much of what
/// waits as fits the socket's buffer and forgets the rest; with 32 KB
/// waiting, a request of 32,725 to 32,768 bytes (head and body) lost its
/// last bytes, and the server waited for them until it closed. One record
/// always fits: the flush asks the socket's buffer for a whole record's
/// room first. (Found with harness against a real model, 2026-11-26.)
const tls_plain_out_len = tls.max_ciphertext_inner_record_len;
const body_buf_len = 32 * 1024;

const Conn = struct {
    s: sock.Socket,
    tls_client: ?tls.Client,
    reader: std.http.Reader,
    mem: []u8,
    /// The answer said the connection stays open.
    keep: bool = false,

    fn in(c: *Conn) *Io.Reader {
        return if (c.tls_client) |*t| &t.reader else &c.s.reader;
    }

    fn out(c: *Conn) *Io.Writer {
        return if (c.tls_client) |*t| &t.writer else &c.s.writer;
    }

    fn flush(c: *Conn) !void {
        if (c.tls_client) |*t| try t.writer.flush();
        try c.s.writer.flush();
    }
};

/// Why a handshake failed: the certificate was refused, or anything else.
fn tlsFailure(e: anyerror) Error {
    if (e == error.TlsCertificateNotVerified or std.mem.startsWith(u8, @errorName(e), "Certificate")) return error.CertificateRejected;
    return error.TlsFailed;
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    target: Target,
    /// The certificates trusted for https, a PEM file (a server's own,
    /// such as tesla-http-proxy's); "": the system's roots. There is no
    /// way to turn the check off.
    ca_file: []const u8 = "",
    user_agent: []const u8 = "harness",
    conn: ?*Conn = null,
    ca: ?std.crypto.Certificate.Bundle = null,
    ca_lock: Io.RwLock = .init,
    /// More about the last error than its name says.
    detail: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, target: Target) Client {
        return .{ .gpa = gpa, .io = io, .target = target };
    }

    pub fn deinit(c: *Client) void {
        c.drop();
        if (c.ca) |*b| b.deinit(c.gpa);
        c.ca = null;
    }

    fn drop(c: *Client) void {
        const conn = c.conn orelse return;
        conn.s.close();
        c.gpa.free(conn.mem);
        c.gpa.destroy(conn);
        c.conn = null;
    }

    fn open(c: *Client, limits: Limits) Error!*Conn {
        const t = c.target;
        const handle = sock.connect(c.io, t.host, t.port, limits.idle_ms) catch |e| {
            c.detail = e;
            return if (e == error.OutOfMemory) error.OutOfMemory else if (e == error.ConnectionTimedOut) error.Timeout else error.ConnectFailed;
        };
        errdefer sock.closeHandle(handle);
        const conn = try c.gpa.create(Conn);
        errdefer c.gpa.destroy(conn);
        // One block: socket in, socket out, and for https the two buffers
        // for the decrypted side.
        const n = read_buf_len + write_buf_len + if (t.https) read_buf_len + write_buf_len else @as(usize, 0);
        const mem = try c.gpa.alloc(u8, n);
        errdefer c.gpa.free(mem);
        conn.mem = mem;
        conn.keep = false;
        conn.tls_client = null;
        conn.s.init(c.io, handle, mem[0..read_buf_len], mem[read_buf_len..][0..write_buf_len], limits.idle_ms);
        conn.s.setLimits(limits.idle_ms, limits.total_ms);
        if (t.https) {
            const plain = mem[read_buf_len + write_buf_len ..];
            if (c.ca == null) {
                var bundle: std.crypto.Certificate.Bundle = .empty;
                const now = Io.Clock.real.now(c.io);
                const loaded = if (c.ca_file.len > 0)
                    bundle.addCertsFromFilePath(c.gpa, c.io, now, Io.Dir.cwd(), c.ca_file)
                else
                    bundle.rescan(c.gpa, c.io, now);
                loaded catch |e| {
                    bundle.deinit(c.gpa);
                    c.detail = e;
                    return error.TlsFailed;
                };
                c.ca = bundle;
            }
            // what the handshake's keys are made from
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            c.io.randomSecure(&entropy) catch |e| {
                c.detail = e;
                return error.TlsFailed;
            };
            conn.tls_client = tls.Client.init(&conn.s.reader, &conn.s.writer, .{
                .host = .{ .explicit = t.host },
                .ca = .{ .bundle = .{
                    .gpa = c.gpa,
                    .io = c.io,
                    .lock = &c.ca_lock,
                    .bundle = &c.ca.?,
                } },
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(c.io),
                .read_buffer = plain[0..read_buf_len],
                .write_buffer = plain[read_buf_len..][0..tls_plain_out_len],
                // HTTP says how long each answer is, so a cut-off one is noticed.
                .allow_truncation_attacks = true,
            }) catch |e| {
                c.detail = conn.s.err orelse e;
                return if (conn.s.timed_out) error.Timeout else tlsFailure(e);
            };
        }
        conn.reader = .{ .in = conn.in(), .state = .ready, .interface = undefined, .max_head_len = read_buf_len, .side = .response };
        return conn;
    }

    fn failure(c: *Client, conn: *Conn, fallback: Error) Error {
        if (conn.s.timed_out) return error.Timeout;
        if (conn.s.err) |e| c.detail = e;
        return fallback;
    }

    /// Sends `req` and reads the answer's status line and headers. Call
    /// `Response.deinit` when done with it.
    pub fn send(c: *Client, req: Request) Error!Response {
        c.detail = null;
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const reused = c.conn != null;
            const conn = c.conn orelse try c.open(req.limits);
            c.conn = conn;
            if (reused) conn.s.setLimits(req.limits.idle_ms, req.limits.total_ms);
            if (c.exchange(conn, req)) |resp| {
                return resp;
            } else |e| {
                const timed_out = conn.s.timed_out;
                c.drop();
                // A kept connection the server closed meanwhile: once more
                // on a new one.
                if (reused and attempt == 0 and !timed_out and e == error.ConnectionClosed) continue;
                return e;
            }
        }
    }

    fn exchange(c: *Client, conn: *Conn, req: Request) Error!Response {
        const t = c.target;
        const w = conn.out();
        writeHead(w, t, req, c.user_agent) catch return c.failure(conn, error.ConnectionClosed);
        if (req.body) |b| w.writeAll(b) catch return c.failure(conn, error.ConnectionClosed);
        conn.flush() catch return c.failure(conn, error.ConnectionClosed);

        var head_bytes: []const u8 = undefined;
        var head: std.http.Client.Response.Head = undefined;
        while (true) {
            head_bytes = conn.reader.receiveHead() catch |e| switch (e) {
                error.HttpConnectionClosing, error.HttpRequestTruncated => return c.failure(conn, error.ConnectionClosed),
                error.ReadFailed => return c.failure(conn, error.ConnectionClosed),
                error.HttpHeadersOversize => return error.BadResponse,
            };
            head = std.http.Client.Response.Head.parse(head_bytes) catch |e| {
                c.detail = e;
                return error.BadResponse;
            };
            if (head.status == .@"continue") {
                conn.reader.state = .ready;
                continue;
            }
            break;
        }
        var resp: Response = .{
            .client = c,
            .status = @backingInt(head.status),
            .body = undefined,
            .body_buf = undefined,
        };
        if (head.content_type) |ct| {
            const n = @min(ct.len, resp.content_type_buf.len);
            @memcpy(resp.content_type_buf[0..n], ct[0..n]);
            resp.content_type_len = n;
        }
        var hit = head.iterateHeaders();
        while (hit.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) resp.retry_after_s = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " "), 10) catch null;
        }
        conn.keep = head.keep_alive;
        const no_body = req.method == .GET and head.content_length == null and head.transfer_encoding == .none and head.keep_alive;
        const buf = try c.gpa.alloc(u8, body_buf_len);
        resp.body_buf = buf;
        resp.body = if (no_body or head.status == .no_content or head.status == .not_modified)
            conn.reader.bodyReader(buf, .none, 0)
        else
            conn.reader.bodyReader(buf, head.transfer_encoding, head.content_length);
        return resp;
    }
};

fn writeHead(w: *Io.Writer, t: Target, req: Request, user_agent: []const u8) !void {
    try w.print("{s} {s}{s} HTTP/1.1\r\n", .{ @tagName(req.method), t.prefix, req.path });
    const default_port: u16 = if (t.https) 443 else 80;
    const v6 = std.mem.indexOfScalar(u8, t.host, ':') != null;
    try w.print("Host: {s}{s}{s}", .{ if (v6) "[" else "", t.host, if (v6) "]" else "" });
    if (t.port != default_port) try w.print(":{d}", .{t.port});
    try w.print("\r\nUser-Agent: {s}\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: keep-alive\r\n", .{user_agent});
    if (req.key) |k| try w.print("Authorization: Bearer {s}\r\n", .{k});
    for (req.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    if (req.body) |b| try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ req.content_type, b.len });
    try w.writeAll("\r\n");
}

pub const Response = struct {
    client: *Client,
    status: u16,
    body: *Io.Reader,
    body_buf: []u8,
    content_type_buf: [96]u8 = undefined,
    content_type_len: usize = 0,
    /// The answer's retry-after, in seconds, when it gave one.
    retry_after_s: ?u32 = null,
    ended: bool = false,

    pub fn contentType(r: *const Response) []const u8 {
        return r.content_type_buf[0..r.content_type_len];
    }

    /// The next part of the body as soon as any of it has arrived; null at
    /// its end. The bytes are valid until the next call.
    pub fn next(r: *Response) Error!?[]const u8 {
        if (r.ended) return null;
        const conn = r.client.conn orelse return error.ConnectionClosed;
        const got = r.body.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => {
                r.ended = true;
                return null;
            },
            error.ReadFailed => return r.client.failure(conn, error.ConnectionClosed),
        };
        r.body.toss(got.len);
        return got;
    }

    /// The whole body, at most `max` bytes of it. Caller frees.
    pub fn readAll(r: *Response, gpa: std.mem.Allocator, max: usize) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (try r.next()) |part| {
            if (out.items.len + part.len > max) return error.BadResponse;
            try out.appendSlice(gpa, part);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Keeps the connection for the next request when the body was read to
    /// its end and the server leaves it open; closes it otherwise.
    pub fn deinit(r: *Response) void {
        const c = r.client;
        c.gpa.free(r.body_buf);
        const conn = c.conn orelse return;
        if (!(r.ended and conn.keep and conn.reader.state == .ready)) c.drop();
    }
};

/// Sends `req` and returns status and whole body. Caller frees `body`.
pub const Answer = struct { status: u16, body: []u8 };

pub fn fetch(c: *Client, gpa: std.mem.Allocator, req: Request) Error!Answer {
    var resp = try c.send(req);
    defer resp.deinit();
    const body = try resp.readAll(gpa, 64 * 1024 * 1024);
    return .{ .status = resp.status, .body = body };
}

// ---- tests ----

const testing = std.testing;

test "a_server_address_is_split_into_its_parts" {
    const a = try Target.parse("http://localhost:8080");
    try testing.expectEqualStrings("localhost", a.host);
    try testing.expectEqual(@as(u16, 8080), a.port);
    try testing.expect(!a.https);
    try testing.expectEqualStrings("", a.prefix);

    const b = try Target.parse("https://llm.example.com/v1/");
    try testing.expect(b.https);
    try testing.expectEqual(@as(u16, 443), b.port);
    try testing.expectEqualStrings("", b.prefix);

    const c = try Target.parse("10.0.0.5:11434/api/proxy/v1");
    try testing.expectEqualStrings("10.0.0.5", c.host);
    try testing.expectEqual(@as(u16, 11434), c.port);
    try testing.expectEqualStrings("/api/proxy", c.prefix);

    const d = try Target.parse("http://[::1]:8000");
    try testing.expectEqualStrings("::1", d.host);
    try testing.expectEqual(@as(u16, 8000), d.port);
}

test "addresses_that_are_not_servers_are_refused" {
    try testing.expectError(error.BadUrl, Target.parse("ftp://host/x"));
    try testing.expectError(error.BadUrl, Target.parse("http://"));
    try testing.expectError(error.BadUrl, Target.parse("http://host:notaport"));
    try testing.expectError(error.BadUrl, Target.parse("http://user@host:80"));
    try testing.expectError(error.BadUrl, Target.parse("http://host/path?x=1"));
}

//! One request to the real service and its whole answer: a new connection
//! each time, https checked against the system's certificates.
const std = @import("std");
const sock = @import("sock.zig");
const rules = @import("rules.zig");
const Io = std.Io;
const tls = std.crypto.tls;

pub const Error = error{
    Timeout,
    ConnectFailed,
    TlsFailed,
    CertificateRejected,
    BadResponse,
    /// The service sent its answer compressed despite being asked not to,
    /// so it can't be checked for the secret.
    Compressed,
    TooLarge,
    OutOfMemory,
};

/// The system's certificates, read once.
pub const Certs = struct {
    gpa: std.mem.Allocator,
    bundle: ?std.crypto.Certificate.Bundle = null,
    lock: Io.RwLock = .init,
    mutex: Io.Mutex = .init,

    fn get(c: *Certs, io: Io) !*std.crypto.Certificate.Bundle {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.bundle == null) {
            var b: std.crypto.Certificate.Bundle = .empty;
            try b.rescan(c.gpa, io, Io.Clock.real.now(io));
            c.bundle = b;
        }
        return &c.bundle.?;
    }

    pub fn deinit(c: *Certs) void {
        if (c.bundle) |*b| b.deinit(c.gpa);
    }
};

pub const Response = struct {
    status: u16,
    /// Pairs of name and value, in the order they came.
    headers: []std.http.Header,
    body: []u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(r: *Response) void {
        r.arena.deinit();
    }
};

pub const Limits = struct {
    idle_ms: u32 = 60_000,
    total_ms: u32 = 600_000,
    max_body: usize = 64 * 1024 * 1024,
};

const buf_len = 64 * 1024;

/// Sends `head` (the request line and headers, ending in an empty line)
/// and `body`, and reads the answer whole.
pub fn exchange(gpa: std.mem.Allocator, io: Io, certs: *Certs, up: rules.Upstream, method: std.http.Method, head: []const u8, body: []const u8, limits: Limits) Error!Response {
    const handle = sock.connect(io, up.host, up.port, limits.idle_ms) catch |e| {
        return if (e == error.OutOfMemory) error.OutOfMemory else if (e == error.ConnectionTimedOut) error.Timeout else error.ConnectFailed;
    };
    var s: sock.Socket = undefined;
    const mem = gpa.alloc(u8, 4 * buf_len) catch {
        sock.closeHandle(handle);
        return error.OutOfMemory;
    };
    defer gpa.free(mem);
    s.init(io, handle, mem[0..buf_len], mem[buf_len..][0..buf_len], limits.idle_ms);
    defer s.close();
    s.setLimits(limits.idle_ms, limits.total_ms);

    var tls_client: ?tls.Client = null;
    if (up.https) {
        const bundle = certs.get(io) catch return error.TlsFailed;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.randomSecure(&entropy) catch return error.TlsFailed;
        tls_client = tls.Client.init(&s.reader, &s.writer, .{
            .host = .{ .explicit = up.host },
            .ca = .{ .bundle = .{ .gpa = certs.gpa, .io = io, .lock = &certs.lock, .bundle = bundle } },
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(io),
            .read_buffer = mem[2 * buf_len ..][0..buf_len],
            // one TLS record's worth, never more: std's flush (Zig 0.17.1)
            // encrypts what fits the socket's buffer and forgets the rest,
            // so a request a few bytes short of a full buffer lost its end
            .write_buffer = mem[3 * buf_len ..][0..tls.max_ciphertext_inner_record_len],
            // lengths in the answer tell a cut-off one apart
            .allow_truncation_attacks = true,
        }) catch |e| {
            if (s.timed_out) return error.Timeout;
            if (e == error.TlsCertificateNotVerified or std.mem.startsWith(u8, @errorName(e), "Certificate")) return error.CertificateRejected;
            return error.TlsFailed;
        };
    }
    const in: *Io.Reader = if (tls_client) |*c| &c.reader else &s.reader;
    const out: *Io.Writer = if (tls_client) |*c| &c.writer else &s.writer;

    out.writeAll(head) catch return failed(&s);
    out.writeAll(body) catch return failed(&s);
    if (tls_client) |*c| c.writer.flush() catch return failed(&s);
    s.writer.flush() catch return failed(&s);

    var reader: std.http.Reader = .{ .in = in, .state = .ready, .interface = undefined, .max_head_len = buf_len, .side = .response };
    var head_bytes: []const u8 = undefined;
    var parsed: std.http.Client.Response.Head = undefined;
    while (true) {
        head_bytes = reader.receiveHead() catch |e| switch (e) {
            error.HttpHeadersOversize => return error.BadResponse,
            else => return failed(&s),
        };
        parsed = std.http.Client.Response.Head.parse(head_bytes) catch |e| switch (e) {
            error.HttpContentEncodingUnsupported => return error.Compressed,
            else => return error.BadResponse,
        };
        if (parsed.status == .@"continue") {
            reader.state = .ready;
            continue;
        }
        break;
    }
    if (parsed.content_encoding != .identity) return error.Compressed;

    var resp: Response = .{ .status = @backingInt(parsed.status), .headers = &.{}, .body = &.{}, .arena = .init(gpa) };
    errdefer resp.arena.deinit();
    const a = resp.arena.allocator();
    var hs: std.ArrayList(std.http.Header) = .empty;
    var it = parsed.iterateHeaders();
    while (it.next()) |h| try hs.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
    resp.headers = hs.items;

    const no_body = method == .HEAD or parsed.status == .no_content or parsed.status == .not_modified or (resp.status >= 100 and resp.status < 200);
    if (!no_body) {
        var tbuf: [buf_len]u8 = undefined;
        const br = reader.bodyReader(&tbuf, parsed.transfer_encoding, parsed.content_length);
        resp.body = br.allocRemaining(a, .limited(limits.max_body)) catch |e| switch (e) {
            error.StreamTooLong => return error.TooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return failed(&s),
        };
    }
    return resp;
}

fn failed(s: *sock.Socket) Error {
    return if (s.timed_out) error.Timeout else error.BadResponse;
}

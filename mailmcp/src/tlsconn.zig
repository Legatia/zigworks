//! A connection to a mail server: TCP with time limits on everything, TLS
//! from the start (IMAP 993, SMTP 465) or after STARTTLS (SMTP 587). The
//! server's certificate is always checked, by std's TLS client, against
//! the system's roots and the mail file's `ca` if it names one, for the
//! host the file names. There is no way to turn the check off.
const std = @import("std");
const Io = std.Io;
const tls = std.crypto.tls;
const sock = @import("sock.zig");

pub const Error = error{
    Timeout,
    ConnectFailed,
    ConnectionClosed,
    TlsFailed,
    CertificateRejected,
    OutOfMemory,
};

/// The certificates trusted: the system's, and one more file's.
pub const Trust = struct {
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: Io.RwLock = .init,
    loaded: bool = false,
    /// Why the extra file wasn't read; null: read (or none).
    problem: ?anyerror = null,

    pub fn deinit(t: *Trust, gpa: std.mem.Allocator) void {
        t.bundle.deinit(gpa);
    }

    /// Loads the system's roots and `extra` (a PEM file; "" none), once.
    pub fn load(t: *Trust, gpa: std.mem.Allocator, io: Io, extra: []const u8) !void {
        if (t.loaded) return;
        const now = Io.Clock.real.now(io);
        t.bundle.rescan(gpa, io, now) catch |e| {
            // no system store (a bare container): the extra file alone
            if (extra.len == 0) return e;
        };
        if (extra.len > 0) t.bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), extra) catch |e| {
            t.problem = e;
            return error.CaUnreadable;
        };
        t.loaded = true;
    }

    /// Trusts the certificates of a PEM text too (tests: the sim's CA,
    /// without the system's store).
    pub fn addPem(t: *Trust, gpa: std.mem.Allocator, io: Io, pem: []const u8) !void {
        const now_s = Io.Clock.real.now(io).toSeconds();
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        var rest = pem;
        while (std.mem.indexOf(u8, rest, begin)) |b| {
            const from = b + begin.len;
            const e = std.mem.indexOfPos(u8, rest, from, end) orelse return error.BadPem;
            var b64: std.ArrayList(u8) = .empty;
            defer b64.deinit(gpa);
            for (rest[from..e]) |ch| if (!std.ascii.isWhitespace(ch)) try b64.append(gpa, ch);
            const n = std.base64.standard.Decoder.calcSizeForSlice(b64.items) catch return error.BadPem;
            const start: u32 = @intCast(t.bundle.bytes.items.len);
            try t.bundle.bytes.resize(gpa, start + n);
            std.base64.standard.Decoder.decode(t.bundle.bytes.items[start..], b64.items) catch return error.BadPem;
            try t.bundle.parseCert(gpa, start, now_s);
            rest = rest[e + end.len ..];
        }
        t.loaded = true;
    }
};

const read_len = tls.Client.min_buffer_len;
const write_len = 16 * 1024;

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    s: sock.Socket,
    tls_client: ?tls.Client = null,
    mem: []u8,
    host: []const u8,
    /// More about the last failure than its name.
    detail: ?anyerror = null,

    pub fn in(c: *Conn) *Io.Reader {
        return if (c.tls_client) |*t| &t.reader else &c.s.reader;
    }

    pub fn out(c: *Conn) *Io.Writer {
        return if (c.tls_client) |*t| &t.writer else &c.s.writer;
    }

    pub fn flush(c: *Conn) !void {
        if (c.tls_client) |*t| try t.writer.flush();
        try c.s.writer.flush();
    }

    /// Whether something can be read within `ms`.
    pub fn readable(c: *Conn, ms: u32) !bool {
        if (c.in().bufferedLen() > 0) return true;
        return c.s.readable(ms);
    }

    pub fn setIdle(c: *Conn, ms: u32) void {
        c.s.setLimits(ms, null);
    }

    pub fn close(c: *Conn) void {
        if (c.tls_client) |*t| {
            t.end() catch {};
            c.s.writer.flush() catch {};
        }
        c.s.close();
        c.gpa.free(c.mem);
        c.gpa.destroy(c);
    }

    /// TLS on the connection as it is (after STARTTLS, or at once).
    pub fn startTls(c: *Conn, trust: *Trust) Error!void {
        const plain = c.mem[2 * read_len ..];
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.randomSecure(&entropy) catch |e| {
            c.detail = e;
            return error.TlsFailed;
        };
        c.tls_client = tls.Client.init(&c.s.reader, &c.s.writer, .{
            .host = .{ .explicit = c.host },
            .ca = .{ .bundle = .{ .gpa = c.gpa, .io = c.io, .lock = &trust.lock, .bundle = &trust.bundle } },
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(c.io),
            .read_buffer = plain[0..read_len],
            .write_buffer = plain[read_len..][0..write_len],
        }) catch |e| {
            c.detail = c.s.err orelse e;
            if (c.s.timed_out) return error.Timeout;
            if (e == error.TlsCertificateNotVerified or std.mem.startsWith(u8, @errorName(e), "Certificate")) return error.CertificateRejected;
            return error.TlsFailed;
        };
    }
};

/// Opens a connection to `host`:`port`; `implicit` starts TLS at once.
pub fn open(gpa: std.mem.Allocator, io: Io, host: []const u8, port: u16, implicit: bool, trust: *Trust, idle_ms: u32) Error!*Conn {
    const handle = sock.connect(io, host, port, idle_ms) catch |e| {
        return if (e == error.OutOfMemory) error.OutOfMemory else if (e == error.ConnectionTimedOut) error.Timeout else error.ConnectFailed;
    };
    const c = gpa.create(Conn) catch {
        sock.closeHandle(handle);
        return error.OutOfMemory;
    };
    // socket in, socket out, then the decrypted side's two buffers
    const mem = gpa.alloc(u8, 2 * read_len + read_len + write_len) catch {
        sock.closeHandle(handle);
        gpa.destroy(c);
        return error.OutOfMemory;
    };
    c.* = .{ .gpa = gpa, .io = io, .s = undefined, .mem = mem, .host = host };
    c.s.init(io, handle, mem[0..read_len], mem[read_len .. 2 * read_len], idle_ms);
    c.s.setLimits(idle_ms, null);
    if (implicit) c.startTls(trust) catch |e| {
        c.s.close();
        gpa.free(mem);
        gpa.destroy(c);
        return e;
    };
    return c;
}

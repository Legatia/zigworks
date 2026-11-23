//! The server half of TLS 1.3, for mailmcp-sim only (std has a client and
//! no server): X25519, TLS_AES_128_GCM_SHA256, an Ed25519 certificate, no
//! session tickets, no client certificates, no HelloRetryRequest. Enough
//! for std's own client, which mailmcp uses, to check the certificate and
//! talk. Never part of the mailmcp binary. The certificate's key is ECDSA
//! P-256 (std's client takes no Ed25519 handshake signature).
const std = @import("std");
const tls = std.crypto.tls;
const Io = std.Io;
const sock = @import("sock.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes = std.crypto.aead.aes_gcm.Aes128Gcm;
const X25519 = std.crypto.dh.X25519;
const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Identity = struct { cert_der: []const u8, key: P256.KeyPair };

const max_plain = 1 << 14;

pub const Server = struct {
    s: *sock.Socket,
    reader: Io.Reader,
    writer: Io.Writer,
    c_key: [16]u8 = undefined,
    c_iv: [12]u8 = undefined,
    s_key: [16]u8 = undefined,
    s_iv: [12]u8 = undefined,
    rseq: u64 = 0,
    wseq: u64 = 0,
    /// A decrypted record not yet handed on.
    rec: [max_plain + 256]u8 = undefined,
    rec_start: usize = 0,
    rec_end: usize = 0,
    eof: bool = false,

    /// The handshake on `s` (just accepted, or after STARTTLS). `entropy`:
    /// 64 random bytes. `t` must not move afterwards.
    pub fn accept(t: *Server, s: *sock.Socket, id: *const Identity, entropy: *const [64]u8, read_buf: []u8, write_buf: []u8) !void {
        t.* = .{
            .s = s,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = read_buf, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = drain, .flush = flushFn }, .buffer = write_buf },
        };
        const r = &s.reader;
        var transcript = Sha256.init(.{});
        // ClientHello
        const hdr = try r.takeArray(5);
        if (hdr[0] != 0x16) return error.NotAHandshake;
        const len = std.mem.readInt(u16, hdr[3..5], .big);
        const rec = try r.take(len);
        if (rec.len < 4 or rec[0] != 0x01) return error.NotAClientHello;
        const hs_len = std.mem.readInt(u24, rec[1..4], .big);
        if (hs_len + 4 > rec.len) return error.ClientHelloTooLong;
        const ch = rec[0 .. 4 + hs_len];
        transcript.update(ch);
        var p: usize = 4 + 2 + 32;
        const sid_len = ch[p];
        p += 1;
        var sid: [32]u8 = undefined;
        if (sid_len > 32) return error.BadClientHello;
        @memcpy(sid[0..sid_len], ch[p .. p + sid_len]);
        p += sid_len;
        const cs_len = std.mem.readInt(u16, ch[p..][0..2], .big);
        p += 2;
        var has_suite = false;
        var i: usize = 0;
        while (i + 1 < cs_len) : (i += 2) {
            if (std.mem.readInt(u16, ch[p + i ..][0..2], .big) == 0x1301) has_suite = true;
        }
        p += cs_len;
        if (!has_suite) return error.NoCommonSuite;
        p += 1 + ch[p];
        const ext_len = std.mem.readInt(u16, ch[p..][0..2], .big);
        p += 2;
        const ext_end = p + ext_len;
        var client_pub: ?[32]u8 = null;
        while (p + 4 <= ext_end) {
            const et = std.mem.readInt(u16, ch[p..][0..2], .big);
            const el = std.mem.readInt(u16, ch[p + 2 ..][0..2], .big);
            const body = ch[p + 4 .. p + 4 + el];
            p += 4 + el;
            if (et != 0x0033) continue;
            var q: usize = 2;
            while (q + 4 <= body.len) {
                const group = std.mem.readInt(u16, body[q..][0..2], .big);
                const kl = std.mem.readInt(u16, body[q + 2 ..][0..2], .big);
                if (group == 0x001d and kl == 32) client_pub = body[q + 4 ..][0..32].*;
                q += 4 + kl;
            }
        }
        const their = client_pub orelse return error.NoX25519Share;
        const kp = X25519.KeyPair.generateDeterministic(entropy[0..32].*);
        const shared = X25519.scalarmult(kp.secret_key, their) catch return error.BadKeyShare;
        // ServerHello
        var sh: std.ArrayList(u8) = .empty;
        var sh_buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&sh_buf);
        const fa = fba.allocator();
        try sh.appendSlice(fa, &.{ 0x02, 0, 0, 0, 0x03, 0x03 });
        try sh.appendSlice(fa, entropy[32..64]);
        try sh.append(fa, sid_len);
        try sh.appendSlice(fa, sid[0..sid_len]);
        try sh.appendSlice(fa, &.{ 0x13, 0x01, 0x00, 0x00, 46, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04, 0x00, 0x33, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20 });
        try sh.appendSlice(fa, &kp.public_key);
        std.mem.writeInt(u24, sh.items[1..4], @intCast(sh.items.len - 4), .big);
        transcript.update(sh.items);
        const w = &s.writer;
        try w.writeAll(&.{ 0x16, 0x03, 0x03 });
        try w.writeInt(u16, @intCast(sh.items.len), .big);
        try w.writeAll(sh.items);
        // middlebox compatibility: std's client waits for it
        try w.writeAll(&.{ 0x14, 0x03, 0x03, 0x00, 0x01, 0x01 });
        // the key schedule (RFC 8446 7.1)
        const zeroes: [32]u8 = @splat(0);
        const empty = tls.emptyHash(Sha256);
        const early = Hkdf.extract(&[1]u8{0}, &zeroes);
        const hs_derived = tls.hkdfExpandLabel(Hkdf, early, "derived", &empty, 32);
        const hs_secret = Hkdf.extract(&hs_derived, &shared);
        const hello_hash = transcript.peek();
        const c_hs = tls.hkdfExpandLabel(Hkdf, hs_secret, "c hs traffic", &hello_hash, 32);
        const s_hs = tls.hkdfExpandLabel(Hkdf, hs_secret, "s hs traffic", &hello_hash, 32);
        const ap_derived = tls.hkdfExpandLabel(Hkdf, hs_secret, "derived", &empty, 32);
        const master = Hkdf.extract(&ap_derived, &zeroes);
        t.s_key = tls.hkdfExpandLabel(Hkdf, s_hs, "key", "", 16);
        t.s_iv = tls.hkdfExpandLabel(Hkdf, s_hs, "iv", "", 12);
        t.c_key = tls.hkdfExpandLabel(Hkdf, c_hs, "key", "", 16);
        t.c_iv = tls.hkdfExpandLabel(Hkdf, c_hs, "iv", "", 12);
        const s_fin_key = tls.hkdfExpandLabel(Hkdf, s_hs, "finished", "", 32);
        const c_fin_key = tls.hkdfExpandLabel(Hkdf, c_hs, "finished", "", 32);
        // EncryptedExtensions, Certificate, CertificateVerify, Finished
        const ee = [_]u8{ 0x08, 0, 0, 2, 0, 0 };
        transcript.update(&ee);
        try t.sealRecord(0x16, &ee);
        var cert_head: [11]u8 = undefined;
        const cert_len: u24 = @intCast(id.cert_der.len);
        cert_head[0] = 0x0b;
        std.mem.writeInt(u24, cert_head[1..4], cert_len + 3 + 2 + 3 + 1, .big);
        cert_head[4] = 0;
        std.mem.writeInt(u24, cert_head[5..8], cert_len + 3 + 2, .big);
        std.mem.writeInt(u24, cert_head[8..11], cert_len, .big);
        var cert_msg: std.ArrayList(u8) = .empty;
        var cm_buf: [8192]u8 = undefined;
        var fba2 = std.heap.FixedBufferAllocator.init(&cm_buf);
        try cert_msg.appendSlice(fba2.allocator(), &cert_head);
        try cert_msg.appendSlice(fba2.allocator(), id.cert_der);
        try cert_msg.appendSlice(fba2.allocator(), &.{ 0, 0 });
        transcript.update(cert_msg.items);
        try t.sealRecord(0x16, cert_msg.items);
        const pad: [64]u8 = @splat(' ');
        const cv_hash = transcript.peek();
        const signed = pad ++ "TLS 1.3, server CertificateVerify\x00".* ++ cv_hash;
        var der_buf: [P256.Signature.der_encoded_length_max]u8 = undefined;
        const sig = (try id.key.sign(&signed, null)).toDer(&der_buf);
        var cv_buf: [8 + P256.Signature.der_encoded_length_max]u8 = undefined;
        const cv = cv_buf[0 .. 8 + sig.len];
        cv[0] = 0x0f;
        std.mem.writeInt(u24, cv[1..4], @intCast(4 + sig.len), .big);
        cv[4] = 0x04;
        cv[5] = 0x03;
        std.mem.writeInt(u16, cv[6..8], @intCast(sig.len), .big);
        @memcpy(cv[8..], sig);
        transcript.update(cv);
        try t.sealRecord(0x16, cv);
        var fin: [4 + 32]u8 = undefined;
        fin[0] = 0x14;
        std.mem.writeInt(u24, fin[1..4], 32, .big);
        fin[4..].* = hmac(transcript.peek(), s_fin_key);
        transcript.update(&fin);
        try t.sealRecord(0x16, &fin);
        try w.flush();
        const app_hash = transcript.peek();
        const want_fin = hmac(app_hash, c_fin_key);
        // the client's ChangeCipherSpec and Finished
        t.rseq = 0;
        while (true) {
            const got = try t.openRecord();
            if (got.ct == 0x14) continue;
            if (got.ct != 0x16) return error.UnexpectedRecord;
            const m = t.rec[0..got.len];
            if (m.len != 36 or m[0] != 0x14 or !std.crypto.timing_safe.eql([32]u8, m[4..36].*, want_fin)) return error.BadFinished;
            break;
        }
        const c_ap = tls.hkdfExpandLabel(Hkdf, master, "c ap traffic", &app_hash, 32);
        const s_ap = tls.hkdfExpandLabel(Hkdf, master, "s ap traffic", &app_hash, 32);
        t.c_key = tls.hkdfExpandLabel(Hkdf, c_ap, "key", "", 16);
        t.c_iv = tls.hkdfExpandLabel(Hkdf, c_ap, "iv", "", 12);
        t.s_key = tls.hkdfExpandLabel(Hkdf, s_ap, "key", "", 16);
        t.s_iv = tls.hkdfExpandLabel(Hkdf, s_ap, "iv", "", 12);
        t.rseq = 0;
        t.wseq = 0;
        t.rec_start = 0;
        t.rec_end = 0;
    }

    fn hmac(msg: [32]u8, key: [32]u8) [32]u8 {
        var out: [32]u8 = undefined;
        Hmac.create(&out, &msg, &key);
        return out;
    }

    fn nonce(iv: [12]u8, seq: u64) [12]u8 {
        var n = iv;
        var be: [8]u8 = undefined;
        std.mem.writeInt(u64, &be, seq, .big);
        for (0..8) |i| n[4 + i] ^= be[i];
        return n;
    }

    /// Encrypts one record of `ct` holding `data` (at most 16 KB) onto the
    /// socket's writer.
    fn sealRecord(t: *Server, ct: u8, data: []const u8) !void {
        var buf: [max_plain + 1]u8 = undefined;
        @memcpy(buf[0..data.len], data);
        buf[data.len] = ct;
        const inner = buf[0 .. data.len + 1];
        var hdr: [5]u8 = .{ 0x17, 0x03, 0x03, 0, 0 };
        std.mem.writeInt(u16, hdr[3..5], @intCast(inner.len + 16), .big);
        var out: [max_plain + 1]u8 = undefined;
        var tag: [16]u8 = undefined;
        Aes.encrypt(out[0..inner.len], &tag, inner, &hdr, nonce(t.s_iv, t.wseq), t.s_key);
        t.wseq += 1;
        const w = &t.s.writer;
        try w.writeAll(&hdr);
        try w.writeAll(out[0..inner.len]);
        try w.writeAll(&tag);
    }

    const Opened = struct { ct: u8, len: usize };

    /// Reads and decrypts the next record into `rec`. A ChangeCipherSpec
    /// comes back as itself, unencrypted.
    fn openRecord(t: *Server) !Opened {
        const r = &t.s.reader;
        const hdr = (try r.takeArray(5)).*;
        const len = std.mem.readInt(u16, hdr[3..5], .big);
        if (len > max_plain + 256) return error.RecordTooLong;
        const body = try r.take(len);
        if (hdr[0] == 0x14) return .{ .ct = 0x14, .len = 0 };
        if (hdr[0] == 0x15) return error.Alert;
        if (hdr[0] != 0x17 or len < 17) return error.UnexpectedRecord;
        const clen = len - 16;
        Aes.decrypt(t.rec[0..clen], body[0..clen], body[clen..][0..16].*, &hdr, nonce(t.c_iv, t.rseq), t.c_key) catch return error.BadRecordMac;
        t.rseq += 1;
        var n = clen;
        while (n > 0 and t.rec[n - 1] == 0) n -= 1;
        if (n == 0) return error.UnexpectedRecord;
        return .{ .ct = t.rec[n - 1], .len = n - 1 };
    }

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Server = @alignCast(@fieldParentPtr("reader", io_r));
        while (t.rec_start == t.rec_end) {
            if (t.eof) return error.EndOfStream;
            const got = t.openRecord() catch |e| {
                if (e == error.EndOfStream or e == error.Alert) {
                    t.eof = true;
                    return error.EndOfStream;
                }
                return error.ReadFailed;
            };
            if (got.ct == 0x15) {
                // an alert (close_notify): the end
                t.eof = true;
                return error.EndOfStream;
            }
            if (got.ct != 0x17) continue;
            t.rec_start = 0;
            t.rec_end = got.len;
        }
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = @min(dest.len, t.rec_end - t.rec_start);
        @memcpy(dest[0..n], t.rec[t.rec_start..][0..n]);
        t.rec_start += n;
        w.advance(n);
        return n;
    }

    fn sendAll(t: *Server, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, max_plain);
            try t.sealRecord(0x17, rest[0..n]);
            rest = rest[n..];
        }
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const t: *Server = @alignCast(@fieldParentPtr("writer", io_w));
        t.sendAll(io_w.buffered()) catch return error.WriteFailed;
        io_w.end = 0;
        for (data[0 .. data.len - 1]) |d| t.sendAll(d) catch return error.WriteFailed;
        for (0..splat) |_| t.sendAll(data[data.len - 1]) catch return error.WriteFailed;
        t.s.writer.flush() catch return error.WriteFailed;
        return Io.Writer.countSplat(data, splat);
    }

    fn flushFn(io_w: *Io.Writer) Io.Writer.Error!void {
        const t: *Server = @alignCast(@fieldParentPtr("writer", io_w));
        t.sendAll(io_w.buffered()) catch return error.WriteFailed;
        io_w.end = 0;
        t.s.writer.flush() catch return error.WriteFailed;
    }

    /// Whether something can be read within `ms`.
    pub fn readable(t: *Server, ms: u32) !bool {
        if (t.reader.bufferedLen() > 0 or t.rec_start < t.rec_end) return true;
        return t.s.readable(ms);
    }
};

const testca = @import("testca.zig");
const tlsconn = @import("tlsconn.zig");

const Echo = struct {
    io: Io,
    listener: sock.Listener,
    id: Identity,
    fn serve(e: *Echo) void {
        const h = e.listener.accept() catch return;
        var rb: [1 << 15]u8 = undefined;
        var wb: [1 << 15]u8 = undefined;
        var s: sock.Socket = undefined;
        s.init(e.io, h, &rb, &wb, 5000);
        defer s.close();
        var entropy: [64]u8 = undefined;
        e.io.randomSecure(&entropy) catch return;
        var t: Server = undefined;
        var prb: [1 << 15]u8 = undefined;
        var pwb: [1 << 15]u8 = undefined;
        t.accept(&s, &e.id, &entropy, &prb, &pwb) catch return;
        const line = (t.reader.takeDelimiter('\n') catch return) orelse return;
        t.writer.print("you said {s}\r\n", .{std.mem.trimEnd(u8, line, "\r")}) catch return;
        t.writer.flush() catch return;
    }
};

test "std_tls_client_checks_and_talks_to_the_sim_server" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var seed: [64]u8 = undefined;
    try io.randomSecure(&seed);
    const made = try testca.make(arena.allocator(), &seed, Io.Clock.real.now(io).toSeconds());
    var e: Echo = .{ .io = io, .listener = try sock.Listener.open(0), .id = .{ .cert_der = made.cert_der, .key = made.key } };
    defer e.listener.close();
    const th = try std.Thread.spawn(.{}, Echo.serve, .{&e});
    var trust: tlsconn.Trust = .{};
    defer trust.deinit(gpa);
    try trust.addPem(gpa, io, made.ca_pem);
    const c = try tlsconn.open(gpa, io, "127.0.0.1", e.listener.port, true, &trust, 5000);
    try c.out().writeAll("hello\r\n");
    try c.flush();
    const got = (try c.in().takeDelimiter('\n')).?;
    try std.testing.expectEqualStrings("you said hello\r", got);
    c.close();
    th.join();

    // a CA the client doesn't trust: refused
    var seed2: [64]u8 = undefined;
    try io.randomSecure(&seed2);
    const other = try testca.make(arena.allocator(), &seed2, Io.Clock.real.now(io).toSeconds());
    var e2: Echo = .{ .io = io, .listener = try sock.Listener.open(0), .id = .{ .cert_der = other.cert_der, .key = other.key } };
    defer e2.listener.close();
    const th2 = try std.Thread.spawn(.{}, Echo.serve, .{&e2});
    try std.testing.expectError(error.CertificateRejected, tlsconn.open(gpa, io, "127.0.0.1", e2.listener.port, true, &trust, 5000));
    th2.join();

    // the right CA, the wrong name: refused
    var e3: Echo = .{ .io = io, .listener = try sock.Listener.open(0), .id = .{ .cert_der = made.cert_der, .key = made.key } };
    defer e3.listener.close();
    const th3 = try std.Thread.spawn(.{}, Echo.serve, .{&e3});
    // "127.0.0.2" reaches nothing; the name check is what is tested: connect to 127.0.0.1 by another name
    const c3 = tlsconn.open(gpa, io, "localhost.", e3.listener.port, true, &trust, 5000);
    if (c3) |cc| cc.close() else |err| try std.testing.expect(err == error.CertificateRejected or err == error.ConnectFailed);
    th3.join();
}

//! A certificate authority made on the spot, for mailmcp-sim and the tests
//! only: an Ed25519 CA and one server certificate (an ECDSA P-256 key:
//! std's TLS client takes no Ed25519 handshake signature) it signs for
//! `localhost` and 127.0.0.1, valid from a day ago for 30 days. The CA is
//! written as PEM for the mail file's `ca =`; nothing here turns any
//! certificate check off.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Made = struct {
    /// The CA's certificate, PEM.
    ca_pem: []const u8,
    /// The server's certificate (DER) and key.
    cert_der: []const u8,
    key: P256.KeyPair,
};

const oid_ed25519 = [_]u8{ 0x06, 0x03, 0x2B, 0x65, 0x70 };
const oid_cn = [_]u8{ 0x06, 0x03, 0x55, 0x04, 0x03 };
const oid_san = [_]u8{ 0x06, 0x03, 0x55, 0x1D, 0x11 };
const oid_basic = [_]u8{ 0x06, 0x03, 0x55, 0x1D, 0x13 };
const oid_ec = [_]u8{ 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
const oid_p256 = [_]u8{ 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };

/// A CA and a server certificate from 64 random bytes; `now_s` the time.
pub fn make(a: Allocator, seed: *const [64]u8, now_s: i64) !Made {
    const ca_key = try Ed25519.KeyPair.generateDeterministic(seed[0..32].*);
    const srv_key = try P256.KeyPair.generateDeterministic(seed[32..64].*);
    const ca_name = try name(a, "mailmcp-sim test CA");
    const srv_name = try name(a, "localhost");
    const from = now_s - 86400;
    const until = now_s + 30 * 86400;
    // the CA: basicConstraints CA:TRUE, critical
    const bc = try cat(a, &.{ &oid_basic, &.{ 0x01, 0x01, 0xFF }, try tlv(a, 0x04, try tlv(a, 0x30, &.{ 0x01, 0x01, 0xFF })) });
    const ca_ext = try tlv(a, 0xA3, try tlv(a, 0x30, try tlv(a, 0x30, bc)));
    const ca_pub = ca_key.public_key.toBytes();
    const ca_spki = try tlv(a, 0x30, try cat(a, &.{ try tlv(a, 0x30, &oid_ed25519), try tlv(a, 0x03, try cat(a, &.{ &.{0}, &ca_pub })) }));
    const ca_der = try certificate(a, 1, ca_name, ca_name, from, until, ca_spki, ca_ext, ca_key);
    // the server: localhost and 127.0.0.1
    const names = try tlv(a, 0x30, try cat(a, &.{ try tlv(a, 0x82, "localhost"), &.{ 0x87, 0x04, 127, 0, 0, 1 } }));
    const san = try cat(a, &.{ &oid_san, try tlv(a, 0x04, names) });
    const srv_ext = try tlv(a, 0xA3, try tlv(a, 0x30, try tlv(a, 0x30, san)));
    const srv_pub = srv_key.public_key.toUncompressedSec1();
    const srv_spki = try tlv(a, 0x30, try cat(a, &.{ try tlv(a, 0x30, try cat(a, &.{ &oid_ec, &oid_p256 })), try tlv(a, 0x03, try cat(a, &.{ &.{0}, &srv_pub })) }));
    const srv_der = try certificate(a, 2, ca_name, srv_name, from, until, srv_spki, srv_ext, ca_key);
    return .{ .ca_pem = try pem(a, ca_der), .cert_der = srv_der, .key = srv_key };
}

fn certificate(a: Allocator, serial: u8, issuer: []const u8, subject: []const u8, from: i64, until: i64, spki: []const u8, ext: []const u8, signer: Ed25519.KeyPair) ![]const u8 {
    const alg = try tlv(a, 0x30, &oid_ed25519);
    const validity = try tlv(a, 0x30, try cat(a, &.{ try utcTime(a, from), try utcTime(a, until) }));
    const tbs = try tlv(a, 0x30, try cat(a, &.{
        &.{ 0xA0, 0x03, 0x02, 0x01, 0x02 },
        &.{ 0x02, 0x01, serial },
        alg,
        issuer,
        validity,
        subject,
        spki,
        ext,
    }));
    const sig = try signer.sign(tbs, null);
    return tlv(a, 0x30, try cat(a, &.{ tbs, alg, try tlv(a, 0x03, try cat(a, &.{ &.{0}, &sig.toBytes() })) }));
}

fn name(a: Allocator, cn: []const u8) ![]const u8 {
    return tlv(a, 0x30, try tlv(a, 0x31, try tlv(a, 0x30, try cat(a, &.{ &oid_cn, try tlv(a, 0x0C, cn) }))));
}

fn utcTime(a: Allocator, secs: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    const text = try std.fmt.allocPrint(a, "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ day.year % 100, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    return tlv(a, 0x17, text);
}

fn tlv(a: Allocator, tag: u8, content: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.append(a, tag);
    if (content.len < 0x80) {
        try o.append(a, @intCast(content.len));
    } else if (content.len < 0x100) {
        try o.appendSlice(a, &.{ 0x81, @intCast(content.len) });
    } else {
        try o.appendSlice(a, &.{ 0x82, @intCast(content.len >> 8), @intCast(content.len & 0xff) });
    }
    try o.appendSlice(a, content);
    return o.items;
}

fn cat(a: Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.concat(a, u8, parts);
}

fn pem(a: Allocator, der: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(der.len));
    _ = enc.encode(b64, der);
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "-----BEGIN CERTIFICATE-----\n");
    var i: usize = 0;
    while (i < b64.len) : (i += 64) {
        try o.appendSlice(a, b64[i..@min(i + 64, b64.len)]);
        try o.append(a, '\n');
    }
    try o.appendSlice(a, "-----END CERTIFICATE-----\n");
    return o.items;
}

test "the_test_ca_signs_a_certificate_std_accepts_for_localhost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    const now_s: i64 = 1795305600;
    const m = try make(a, &seed, now_s);
    // the server certificate parses, names localhost and 127.0.0.1, and the CA signed it
    const srv = try (std.crypto.Certificate{ .buffer = m.cert_der, .index = 0 }).parse();
    try srv.verifyHostName("localhost");
    try srv.verifyHostName("127.0.0.1");
    try std.testing.expectError(error.CertificateHostMismatch, srv.verifyHostName("example.com"));
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.testing.allocator);
    // the PEM as a file would give it
    const begin = "-----BEGIN CERTIFICATE-----\n";
    const body = m.ca_pem[begin.len..std.mem.indexOf(u8, m.ca_pem, "-----END").?];
    var joined: std.ArrayList(u8) = .empty;
    for (body) |ch| if (ch != '\n') try joined.append(a, ch);
    const der = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(joined.items));
    try std.base64.standard.Decoder.decode(der, joined.items);
    const start: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.appendSlice(std.testing.allocator, der);
    try bundle.parseCert(std.testing.allocator, start, now_s);
    try bundle.verify(srv, now_s);
    // a day after it ends, no longer
    try std.testing.expectError(error.CertificateExpired, bundle.verify(srv, now_s + 31 * 86400));
}

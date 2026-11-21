//! A web address read one way for everything that decides on one or uses
//! it: the gate's rules and grants, fetch and search and their redirects,
//! browse's host rule for the browser, web's host checks. So a rule, a
//! grant and the connection all name the same host.
//!
//! Only http and https. What programs read differently is refused: a name
//! before `@` (`https://good.com@evil.com/` goes to evil.com), a
//! backslash, spaces and control characters anywhere, `%` and letters
//! outside ASCII in the host (an international name is written in its
//! `xn--` form). The rest comes out in one form: the host lowercase and
//! without a trailing dot, an IPv4 address in dotted decimal however it was
//! written (`0x7f.1`, `2130706433`, `127.1`, or inside IPv6 as
//! `::ffff:127.0.0.1`), another IPv6 one in its short form, the scheme's
//! own port left out, `.` and `..` in the path resolved, `%XX` of a letter,
//! a digit or `-._~` written as that character, other `%xx` in capitals,
//! and bytes outside ASCII after the host as `%XX`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Not an http or https address.
    NotWeb,
    /// A name (and password) before `@`.
    UserInfo,
    /// A space, a control character or a backslash.
    BadChar,
    /// The host is not a name or an IP address.
    BadHost,
    /// Letters outside ASCII in the host.
    NotAscii,
    BadPort,
    OutOfMemory,
};

pub const Url = struct {
    https: bool,
    /// A lowercase name, a dotted IPv4 address, or IPv6 in brackets.
    host: []const u8,
    port: u16,
    /// Path and query, as they are sent: starts with "/".
    target: []const u8,
    /// After "#" (never sent); "" for none.
    fragment: []const u8,
    /// The whole address in this form.
    href: []const u8,
    /// "host", or "host:port" for a port other than the scheme's own: as a
    /// page's location.host has it, and what a grant covers.
    host_port: []const u8,

    pub fn scheme(u: Url) []const u8 {
        return if (u.https) "https" else "http";
    }

    /// The host as a connection is opened to it (IPv6 without brackets).
    pub fn connectHost(u: Url) []const u8 {
        return if (u.host[0] == '[') u.host[1 .. u.host.len - 1] else u.host;
    }
};

pub fn defaultPort(https: bool) u16 {
    return if (https) 443 else 80;
}

/// Why an address is refused, said to the owner and the model.
pub fn why(e: anyerror) []const u8 {
    return switch (e) {
        error.NotWeb => "only http and https addresses are used",
        error.UserInfo => "an address with a name before @ (like good.com@evil.com) is refused: its host would be what follows the @",
        error.BadChar => "the address has a space, a control character or a backslash",
        error.BadHost => "its host is not a valid name or IP address",
        error.NotAscii => "its host has letters outside ASCII: write it in its xn-- form",
        error.BadPort => "its port is not a number from 1 to 65535",
        else => @errorName(e),
    };
}

pub fn parse(arena: Allocator, raw: []const u8) Error!Url {
    for (raw) |c| if (c <= ' ' or c == 0x7f or c == '\\') return error.BadChar;
    const https = std.ascii.startsWithIgnoreCase(raw, "https://");
    const rest = if (https) raw[8..] else if (std.ascii.startsWithIgnoreCase(raw, "http://")) raw[7..] else return error.NotWeb;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const hp = try hostPort(arena, rest[0..end]);
    const port = hp.port orelse defaultPort(https);
    var tail = rest[end..];
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, tail, '#')) |h| {
        fragment = try escapes(arena, tail[h + 1 ..]);
        tail = tail[0..h];
    }
    const q = std.mem.indexOfScalar(u8, tail, '?');
    const path = try cleanPath(arena, tail[0 .. q orelse tail.len]);
    const target = if (q) |i| try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, try escapes(arena, tail[i + 1 ..]) }) else path;
    const host_port = if (port == defaultPort(https)) hp.host else try std.fmt.allocPrint(arena, "{s}:{d}", .{ hp.host, port });
    return .{
        .https = https,
        .host = hp.host,
        .port = port,
        .target = target,
        .fragment = fragment,
        .href = try std.fmt.allocPrint(arena, "{s}://{s}{s}{s}{s}", .{ if (https) "https" else "http", host_port, target, if (fragment.len > 0) "#" else "", fragment }),
        .host_port = host_port,
    };
}

pub const HostPort = struct {
    host: []const u8,
    /// Null when none was given.
    port: ?u16,
    /// "host" or "host:port", as given (in this form).
    text: []const u8,
};

/// "host" or "host:port", as between an address's "//" and its path.
pub fn hostPort(arena: Allocator, text: []const u8) Error!HostPort {
    if (std.mem.indexOfScalar(u8, text, '@') != null) return error.UserInfo;
    var host_text = text;
    var port_text: ?[]const u8 = null;
    if (std.mem.startsWith(u8, text, "[")) {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return error.BadHost;
        host_text = text[0 .. close + 1];
        const after = text[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.BadHost;
            port_text = after[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        host_text = text[0..colon];
        port_text = text[colon + 1 ..];
    }
    const host = try canonicalHost(arena, host_text);
    // "host:" is the host alone
    const port: ?u16 = if (port_text) |p| (if (p.len == 0) null else try parsePort(p)) else null;
    return .{ .host = host, .port = port, .text = if (port) |n| try std.fmt.allocPrint(arena, "{s}:{d}", .{ host, n }) else host };
}

/// 1 to 65535, in decimal digits only.
pub fn parsePort(p: []const u8) Error!u16 {
    if (p.len == 0) return error.BadPort;
    var n: u32 = 0;
    for (p) |c| {
        if (!std.ascii.isDigit(c)) return error.BadPort;
        n = n * 10 + (c - '0');
        if (n > 65535) return error.BadPort;
    }
    if (n == 0) return error.BadPort;
    return @intCast(n);
}

/// A host in the one form: see the top of this file.
pub fn canonicalHost(arena: Allocator, text: []const u8) Error![]const u8 {
    if (text.len == 0) return error.BadHost;
    if (text[0] == '[') {
        if (text.len < 3 or text[text.len - 1] != ']') return error.BadHost;
        const inner = text[1 .. text.len - 1];
        // a zone (%en0) names an interface of this machine, not a host
        if (std.mem.indexOfScalar(u8, inner, '%') != null) return error.BadHost;
        const ua = switch (std.Io.net.Ip6Address.Unresolved.parse(inner)) {
            .success => |x| x,
            else => return error.BadHost,
        };
        const b = ua.bytes;
        // an IPv4 address written as IPv6 reaches that IPv4 address
        if (std.mem.eql(u8, b[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))
            return std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ b[12], b[13], b[14], b[15] });
        const plain: std.Io.net.Ip6Address.Unresolved = .{ .bytes = b, .interface_name = null };
        return std.fmt.allocPrint(arena, "[{f}]", .{plain});
    }
    for (text) |c| if (c >= 0x80) return error.NotAscii;
    // one trailing dot names the same host
    const name = if (text[text.len - 1] == '.') text[0 .. text.len - 1] else text;
    if (name.len == 0 or name.len > 253) return error.BadHost;
    const low = try std.ascii.allocLowerString(arena, name);
    for (low) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_' or c == '.')) return error.BadHost;
    var labels = std.mem.splitScalar(u8, low, '.');
    var last: []const u8 = "";
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63) return error.BadHost;
        last = l;
    }
    // ending in a number, it is an IPv4 address (as browsers read it) or nothing
    if (endsInNumber(last)) return (try ipv4(arena, low)) orelse error.BadHost;
    return low;
}

/// Whether a host in this form is an IP address.
pub fn isIp(host: []const u8) bool {
    if (host.len > 0 and host[0] == '[') return true;
    for (host) |c| if (!(std.ascii.isDigit(c) or c == '.')) return false;
    return host.len > 0;
}

fn endsInNumber(label: []const u8) bool {
    if (label.len == 0) return false;
    if (std.mem.startsWith(u8, label, "0x")) {
        for (label[2..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    for (label) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// "a.b.c.d" with each part decimal, octal (a leading 0) or hex (0x), the
/// last one filling the bytes left (127.1 is 127.0.0.1); null if it is not
/// an address.
fn ipv4(arena: Allocator, name: []const u8) Error!?[]const u8 {
    var parts: [4]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |p| {
        if (n == parts.len) return null;
        parts[n] = ipv4Number(p) orelse return null;
        n += 1;
    }
    for (parts[0 .. n - 1]) |x| if (x > 255) return null;
    const bits: u6 = @intCast(8 * (5 - n));
    if (parts[n - 1] >= (@as(u64, 1) << bits)) return null;
    var v: u64 = parts[n - 1];
    for (parts[0 .. n - 1], 0..) |x, i| v += x << @intCast(8 * (3 - i));
    return try std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{ v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff });
}

fn ipv4Number(p: []const u8) ?u64 {
    if (p.len == 0) return null;
    var digits = p;
    var radix: u64 = 10;
    if (std.mem.startsWith(u8, p, "0x")) {
        radix = 16;
        digits = p[2..];
    } else if (p.len > 1 and p[0] == '0') {
        radix = 8;
        digits = p[1..];
    }
    var v: u64 = 0;
    for (digits) |c| {
        const d: u64 = std.fmt.charToDigit(c, @intCast(radix)) catch return null;
        v = std.math.mul(u64, v, radix) catch return null;
        v = std.math.add(u64, v, d) catch return null;
    }
    return v;
}

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// `%XX` of a letter, a digit or `-._~` as that character, other `%xx` in
/// capitals, bytes outside ASCII as `%XX`; the rest as it is.
pub fn escapes(arena: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            const v = (std.fmt.charToDigit(s[i + 1], 16) catch unreachable) * 16 + (std.fmt.charToDigit(s[i + 2], 16) catch unreachable);
            if (unreserved(v)) try out.append(arena, v) else try out.print(arena, "%{X:0>2}", .{v});
            i += 2;
        } else if (c >= 0x80) {
            try out.print(arena, "%{X:0>2}", .{c});
        } else try out.append(arena, c);
    }
    return out.items;
}

/// The path with its `.` and `..` parts resolved (as browsers do), "/"
/// for none; `raw` is "" or starts with "/".
fn cleanPath(arena: Allocator, raw: []const u8) Error![]const u8 {
    const norm = try escapes(arena, raw);
    const body = if (norm.len > 0 and norm[0] == '/') norm[1..] else norm;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '/');
    while (it.next()) |p| {
        const last = it.index == null;
        if (std.mem.eql(u8, p, ".")) {
            if (last) try parts.append(arena, "");
        } else if (std.mem.eql(u8, p, "..")) {
            _ = parts.pop();
            if (last) try parts.append(arena, "");
        } else try parts.append(arena, p);
    }
    if (parts.items.len == 0) return "/";
    var out: std.ArrayList(u8) = .empty;
    for (parts.items) |p| {
        try out.append(arena, '/');
        try out.appendSlice(arena, p);
    }
    return out.items;
}

// ---- tests ----

const t = std.testing;

test "an_address_comes_out_in_one_form" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][2][]const u8{
        .{ "https://example.com", "https://example.com/" },
        .{ "HTTPS://Example.COM./A/b?Q=1#Frag", "https://example.com/A/b?Q=1#Frag" },
        .{ "https://example.com:443/x", "https://example.com/x" },
        .{ "http://example.com:80", "http://example.com/" },
        .{ "https://example.com:80/", "https://example.com:80/" },
        .{ "http://example.com:0080/", "http://example.com/" },
        .{ "https://example.com:/x", "https://example.com/x" },
        .{ "https://a.com/x/./y/../z", "https://a.com/x/z" },
        .{ "https://a.com/x/%2e%2E/y", "https://a.com/y" },
        .{ "https://a.com/x/..", "https://a.com/" },
        .{ "https://a.com/../../x", "https://a.com/x" },
        .{ "https://a.com//x", "https://a.com//x" },
        .{ "https://a.com/%7euser/%2f/%41", "https://a.com/~user/%2F/A" },
        .{ "https://a.com/Bücher?q=ü", "https://a.com/B%C3%BCcher?q=%C3%BC" },
        .{ "https://a.com?x=/../y", "https://a.com/?x=/../y" },
        .{ "https://medium.com/@user", "https://medium.com/@user" },
        .{ "http://0x7f.1/", "http://127.0.0.1/" },
        .{ "http://2130706433/", "http://127.0.0.1/" },
        .{ "http://0177.0.0.01/", "http://127.0.0.1/" },
        .{ "http://127.1.2/", "http://127.1.0.2/" },
        .{ "http://1.2.3.4./", "http://1.2.3.4/" },
        .{ "http://[0:0:0:0:0:0:0:1]:8080/", "http://[::1]:8080/" },
        .{ "http://[::FFFF:127.0.0.1]/", "http://127.0.0.1/" },
        .{ "http://[2001:DB8::0:1]/", "http://[2001:db8::1]/" },
        .{ "https://XN--BCHER-KVA.de/", "https://xn--bcher-kva.de/" },
        .{ "https://my_host.example/", "https://my_host.example/" },
    }) |c| {
        const u = try parse(a, c[0]);
        try t.expectEqualStrings(c[1], u.href);
    }
    const u = try parse(a, "https://Example.com:8443/p?q#f");
    try t.expectEqualStrings("example.com", u.host);
    try t.expectEqual(8443, u.port);
    try t.expectEqualStrings("/p?q", u.target);
    try t.expectEqualStrings("f", u.fragment);
    try t.expectEqualStrings("example.com:8443", u.host_port);
    try t.expectEqualStrings("::1", (try parse(a, "http://[::1]/")).connectHost());
}

test "addresses_read_differently_by_different_programs_are_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, Error }{
        .{ "ftp://example.com/", error.NotWeb },
        .{ "https:/example.com/", error.NotWeb },
        .{ "https:example.com", error.NotWeb },
        .{ "javascript:alert(1)", error.NotWeb },
        .{ "https://good.com@evil.com/", error.UserInfo },
        .{ "https://good.com:pw@evil.com/", error.UserInfo },
        .{ "https://@evil.com/", error.UserInfo },
        .{ "https://good.com\\@evil.com/", error.BadChar },
        .{ "https://a.com/x\\y", error.BadChar },
        .{ " https://a.com/", error.BadChar },
        .{ "https://a.com/\tx", error.BadChar },
        .{ "https://ev\nil.com/", error.BadChar },
        .{ "https://", error.BadHost },
        .{ "https:///x", error.BadHost },
        .{ "https://ev%69l.com/", error.BadHost },
        .{ "https://a..com/", error.BadHost },
        .{ "https://.a.com/", error.BadHost },
        .{ "https://a.com../", error.BadHost },
        .{ "https://a*.com/", error.BadHost },
        .{ "https://a.com:b/", error.BadPort },
        .{ "http://1.2.3.4.5/", error.BadHost },
        .{ "http://example.123/", error.BadHost },
        .{ "http://256.1.1.1/", error.BadHost },
        .{ "http://1.2.3.08/", error.BadHost },
        .{ "http://1_0.2.3.4/", error.BadHost },
        .{ "http://4294967296/", error.BadHost },
        .{ "http://[::1%25en0]/", error.BadHost },
        .{ "http://[::1/", error.BadHost },
        .{ "http://[::1]x/", error.BadHost },
        .{ "https://bücher.de/", error.NotAscii },
        .{ "https://a.com:0/", error.BadPort },
        .{ "https://a.com:65536/", error.BadPort },
        .{ "https://a.com:-1/", error.BadPort },
    }) |c| {
        if (parse(a, c[0])) |u| {
            std.debug.print("accepted {s} as {s}\n", .{ c[0], u.href });
            return error.TestUnexpectedResult;
        } else |e| try t.expectEqual(c[1], e);
    }
}

test "a_host_and_port_alone_read_the_same_way" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hp = try hostPort(a, "GitHub.COM.:8443");
    try t.expectEqualStrings("github.com", hp.host);
    try t.expectEqual(8443, hp.port.?);
    try t.expectEqualStrings("github.com:8443", hp.text);
    try t.expectEqualStrings("127.0.0.1", (try hostPort(a, "0x7f.1")).text);
    try t.expectEqual(null, (try hostPort(a, "localhost")).port);
    try t.expectError(error.BadHost, hostPort(a, "github.com/x"));
    try t.expectError(error.UserInfo, hostPort(a, "a@b.com"));
    try t.expect(isIp("127.0.0.1") and isIp("[::1]") and !isIp("a1.com") and !isIp(""));
}

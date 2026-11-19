//! The rules file: which secret may be sent where, and how.
//!
//!     [github]
//!     upstream = https://api.github.com
//!     header = Authorization: Bearer {secret}
//!     allow = GET /repos/me/scratch/
//!     allow = POST /repos/me/scratch/issues
//!     expires = 2026-12-01
//!     env = GITHUB_TOKEN
//!
//! Nothing is allowed that no `allow` line names.
const std = @import("std");

pub const Upstream = struct {
    https: bool,
    host: []const u8,
    port: u16,
    /// Put in front of every forwarded path: "" or "/api".
    base: []const u8,
};

pub const Allow = struct {
    /// null: any method.
    method: ?[]const u8,
    prefix: []const u8,
};

pub const Rule = struct {
    name: []const u8,
    upstream: Upstream,
    header_name: []const u8,
    /// Contains "{secret}" once.
    header_value: []const u8,
    allows: []const Allow,
    /// Seconds since 1970, UTC; null: never.
    expires: ?i64 = null,
    /// Variable name for `keygate run`; null: KEYGATE_<NAME>.
    env: ?[]const u8 = null,

    pub const Decision = enum { ok, expired, not_allowed };

    pub fn permits(r: Rule, method: []const u8, path: []const u8, now: i64) Decision {
        if (r.expires) |e| if (now >= e) return .expired;
        for (r.allows) |a| {
            if (a.method) |m| if (!std.mem.eql(u8, m, method)) continue;
            if (prefixMatch(a.prefix, path)) return .ok;
        }
        return .not_allowed;
    }
};

/// "/repos/me" matches "/repos/me" and "/repos/me/x", not "/repos/meow".
fn prefixMatch(prefix: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    return prefix[prefix.len - 1] == '/' or path[prefix.len] == '/';
}

/// The path part of a request target, or null when it could mean a
/// different path to the upstream than it seems to here: "..", "//",
/// backslashes, encoded slashes or dots, control bytes.
pub fn cleanPath(target: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const path = target[0..end];
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.indexOf(u8, path, "//") != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;
    for (path) |c| if (c <= ' ' or c >= 0x7f) return null;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, i, '%')) |p| : (i = p + 1) {
        if (p + 2 >= path.len) return null;
        const code = std.fmt.parseInt(u8, path[p + 1 .. p + 3], 16) catch return null;
        if (code == '/' or code == '.' or code == '\\' or code == '%' or code < ' ') return null;
    }
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return null;
    return path;
}

pub const Result = union(enum) {
    ok: []const Rule,
    err: struct { line: usize, msg: []const u8 },
};

/// Parses a rules file. Results point into `text` and `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Result {
    var rules: std.ArrayList(Rule) = .empty;
    var allows: std.ArrayList(Allow) = .empty;
    var cur: ?Draft = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (cur) |d| {
                if (try finish(arena, d, &allows, &rules)) |msg| return .{ .err = .{ .line = d.line, .msg = msg } };
            }
            if (line[line.len - 1] != ']') return bad(n, "a section is written [name]");
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (!validName(name)) return bad(n, "secret names use a-z, 0-9, - and _");
            for (rules.items) |r| if (std.mem.eql(u8, r.name, name)) return bad(n, "this secret already has a section");
            cur = .{ .name = name, .line = n };
            continue;
        }
        const d = if (cur) |*d| d else return bad(n, "a line before the first [name]");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return bad(n, "expected key = value");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "upstream")) {
            if (d.upstream != null) return bad(n, "upstream is given twice");
            d.upstream = parseUpstream(val) orelse return bad(n, "upstream is https://host[:port][/path]; http:// only for this machine");
        } else if (std.mem.eql(u8, key, "header")) {
            if (d.header_name != null) return bad(n, "header is given twice");
            const colon = std.mem.indexOfScalar(u8, val, ':') orelse return bad(n, "header is Name: value with {secret} in it");
            const hn = std.mem.trim(u8, val[0..colon], " \t");
            const hv = std.mem.trim(u8, val[colon + 1 ..], " \t");
            if (!validToken(hn)) return bad(n, "not a header name");
            if (std.mem.count(u8, hv, "{secret}") != 1) return bad(n, "the header value needs {secret} exactly once");
            d.header_name = hn;
            d.header_value = hv;
        } else if (std.mem.eql(u8, key, "allow")) {
            const sp = std.mem.indexOfAny(u8, val, " \t") orelse return bad(n, "allow is METHOD /path-prefix");
            const m = val[0..sp];
            const p = std.mem.trim(u8, val[sp..], " \t");
            if (!std.mem.eql(u8, m, "*") and !validMethod(m)) return bad(n, "method is GET, POST, ... or *");
            if (cleanPath(p) == null or std.mem.indexOfAny(u8, p, "?#") != null) return bad(n, "the path prefix starts with / and has no .., // or encoded / and .");
            if (d.first_allow == null) d.first_allow = allows.items.len;
            if (d.first_allow.? + d.allow_count != allows.items.len) return bad(n, "allow lines of one secret go together");
            try allows.append(arena, .{ .method = if (std.mem.eql(u8, m, "*")) null else m, .prefix = p });
            d.allow_count += 1;
        } else if (std.mem.eql(u8, key, "expires")) {
            if (d.expires != null) return bad(n, "expires is given twice");
            d.expires = parseTime(val) orelse return bad(n, "expires is YYYY-MM-DD or YYYY-MM-DDTHH:MMZ (UTC)");
        } else if (std.mem.eql(u8, key, "env")) {
            if (d.env != null) return bad(n, "env is given twice");
            if (!validEnv(val)) return bad(n, "env is a variable name: A-Z, 0-9, _");
            d.env = val;
        } else return bad(n, "unknown key; known: upstream, header, allow, expires, env");
    }
    if (cur) |d| {
        if (try finish(arena, d, &allows, &rules)) |msg| return .{ .err = .{ .line = d.line, .msg = msg } };
    }
    return .{ .ok = try rules.toOwnedSlice(arena) };
}

const Draft = struct {
    name: []const u8,
    line: usize,
    upstream: ?Upstream = null,
    header_name: ?[]const u8 = null,
    header_value: []const u8 = "",
    first_allow: ?usize = null,
    allow_count: usize = 0,
    expires: ?i64 = null,
    env: ?[]const u8 = null,
};

fn finish(arena: std.mem.Allocator, d: Draft, allows: *std.ArrayList(Allow), rules: *std.ArrayList(Rule)) !?[]const u8 {
    const up = d.upstream orelse return "this secret has no upstream";
    const hn = d.header_name orelse return "this secret has no header";
    const first = d.first_allow orelse return "this secret has no allow line, so nothing could use it";
    try rules.append(arena, .{
        .name = d.name,
        .upstream = up,
        .header_name = hn,
        .header_value = d.header_value,
        .allows = allows.items[first..][0..d.allow_count],
        .expires = d.expires,
        .env = d.env,
    });
    return null;
}

fn bad(line: usize, msg: []const u8) Result {
    return .{ .err = .{ .line = line, .msg = msg } };
}

fn stripComment(line: []const u8) []const u8 {
    const s = std.mem.trimStart(u8, line, " \t");
    return if (s.len > 0 and s[0] == '#') "" else line;
}

pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

fn validToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn validMethod(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isUpper(c)) return false;
    return true;
}

fn validEnv(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

pub fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1");
}

fn parseUpstream(url: []const u8) ?Upstream {
    var rest = url;
    var https = true;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        https = false;
        rest = rest[7..];
    } else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var host = rest[0..slash];
    var base = rest[slash..];
    while (std.mem.endsWith(u8, base, "/")) base = base[0 .. base.len - 1];
    if (base.len > 0 and (cleanPath(base) == null or std.mem.indexOfAny(u8, base, "?#") != null)) return null;
    var port: u16 = if (https) 443 else 80;
    if (std.mem.startsWith(u8, host, "[")) {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        const after = host[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return null;
            port = std.fmt.parseInt(u16, after[1..], 10) catch return null;
        }
        host = host[1..close];
    } else if (std.mem.lastIndexOfScalar(u8, host, ':')) |c| {
        port = std.fmt.parseInt(u16, host[c + 1 ..], 10) catch return null;
        host = host[0..c];
    }
    if (host.len == 0 or port == 0) return null;
    for (host) |c| if (c <= ' ' or c == '@' or c >= 0x7f) return null;
    if (!https and !isLoopback(host)) return null;
    return .{ .https = https, .host = host, .port = port, .base = base };
}

/// "2026-12-01" (midnight UTC) or "2026-12-01T18:30Z" / "...T18:30:05Z".
pub fn parseTime(s: []const u8) ?i64 {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var secs: i64 = 0;
    if (s.len > 10) {
        const tm = s[10..];
        if (tm[0] != 'T' or tm[tm.len - 1] != 'Z') return null;
        const hms = tm[1 .. tm.len - 1];
        if (hms.len != 5 and hms.len != 8) return null;
        if (hms[2] != ':') return null;
        const h = std.fmt.parseInt(u8, hms[0..2], 10) catch return null;
        const mi = std.fmt.parseInt(u8, hms[3..5], 10) catch return null;
        var sec: u8 = 0;
        if (hms.len == 8) {
            if (hms[5] != ':') return null;
            sec = std.fmt.parseInt(u8, hms[6..8], 10) catch return null;
        }
        if (h > 23 or mi > 59 or sec > 59) return null;
        secs = @as(i64, h) * 3600 + @as(i64, mi) * 60 + sec;
    }
    return daysFromCivil(y, mo, d) * 86400 + secs;
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const t = std.testing;

const sample =
    \\# test rules
    \\[github]
    \\upstream = https://api.github.com
    \\header = Authorization: Bearer {secret}
    \\allow = GET /repos/me/scratch/
    \\allow = POST /repos/me/scratch/issues
    \\expires = 2026-12-01
    \\env = GITHUB_TOKEN
    \\
    \\[local]
    \\upstream = http://127.0.0.1:9000/api/
    \\header = X-Key: {secret}
    \\allow = * /
;

test "parses a rules file" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), sample);
    const rules = r.ok;
    try t.expectEqual(2, rules.len);
    try t.expectEqualStrings("github", rules[0].name);
    try t.expect(rules[0].upstream.https);
    try t.expectEqualStrings("api.github.com", rules[0].upstream.host);
    try t.expectEqual(443, rules[0].upstream.port);
    try t.expectEqualStrings("", rules[0].upstream.base);
    try t.expectEqualStrings("Authorization", rules[0].header_name);
    try t.expectEqualStrings("Bearer {secret}", rules[0].header_value);
    try t.expectEqual(2, rules[0].allows.len);
    try t.expectEqualStrings("POST", rules[0].allows[1].method.?);
    try t.expectEqual(1796083200, rules[0].expires.?); // 2026-12-01T00:00:00Z
    try t.expectEqualStrings("GITHUB_TOKEN", rules[0].env.?);
    try t.expectEqual(9000, rules[1].upstream.port);
    try t.expectEqualStrings("/api", rules[1].upstream.base);
    try t.expectEqual(null, rules[1].allows[0].method);
}

fn expectErr(text: []const u8, line: usize, needle: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), text);
    switch (r) {
        .ok => return error.TestExpectedError,
        .err => |e| {
            try t.expectEqual(line, e.line);
            if (std.mem.indexOf(u8, e.msg, needle) == null) {
                std.debug.print("message: {s}\n", .{e.msg});
                return error.TestUnexpectedMessage;
            }
        },
    }
}

test "refuses plain http to another machine" {
    try expectErr("[a]\nupstream = http://api.example.com\n", 2, "only for this machine");
}

test "refuses a secret with no allow line" {
    try expectErr("[a]\nupstream = https://x.io\nheader = A: {secret}\n", 1, "no allow line");
}

test "refuses a header without {secret}" {
    try expectErr("[a]\nupstream = https://x.io\nheader = A: token\n", 3, "{secret}");
}

test "refuses unknown keys and traversal in prefixes" {
    try expectErr("[a]\nhost = x\n", 2, "unknown key");
    try expectErr("[a]\nallow = GET /a/../b\n", 2, "path prefix");
    try expectErr("[a]\nallow = GET /a/%2e%2e/b\n", 2, "path prefix");
}

test "refuses a second section for one secret" {
    try expectErr("[a]\nupstream = https://x.io\nheader = A: {secret}\nallow = * /\n[a]\n", 5, "already");
}

test "method and path prefix decide" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const r = (try parse(arena.allocator(), sample)).ok[0];
    const before = 1796083199;
    try t.expectEqual(.ok, r.permits("GET", "/repos/me/scratch/contents/a", before));
    try t.expectEqual(.not_allowed, r.permits("DELETE", "/repos/me/scratch/contents/a", before));
    try t.expectEqual(.not_allowed, r.permits("GET", "/repos/me/other", before));
    try t.expectEqual(.ok, r.permits("POST", "/repos/me/scratch/issues", before));
    try t.expectEqual(.ok, r.permits("POST", "/repos/me/scratch/issues/3/comments", before));
    // a prefix without a trailing slash still ends at a path segment
    try t.expectEqual(.not_allowed, r.permits("POST", "/repos/me/scratch/issuesx", before));
    try t.expectEqual(.not_allowed, r.permits("POST", "/gists", before));
    try t.expectEqual(.expired, r.permits("GET", "/repos/me/scratch/x", before + 1));
}

test "cleanPath rejects paths that could mean another path upstream" {
    try t.expectEqualStrings("/a/b", cleanPath("/a/b?x=1").?);
    try t.expectEqualStrings("/a%20b", cleanPath("/a%20b").?);
    try t.expectEqual(null, cleanPath("/a/../b"));
    try t.expectEqual(null, cleanPath("/a/./b"));
    try t.expectEqual(null, cleanPath("/a//b"));
    try t.expectEqual(null, cleanPath("/a/%2E%2E/b"));
    try t.expectEqual(null, cleanPath("/a%2fb"));
    try t.expectEqual(null, cleanPath("/a%5cb"));
    try t.expectEqual(null, cleanPath("/a%252fb"));
    try t.expectEqual(null, cleanPath("/a\\b"));
    try t.expectEqual(null, cleanPath("/a%2"));
    try t.expectEqual(null, cleanPath("a/b"));
    try t.expectEqual(null, cleanPath("http://evil/"));
}

test "parseTime" {
    try t.expectEqual(0, parseTime("1970-01-01").?);
    try t.expectEqual(1796083200 + 18 * 3600 + 30 * 60, parseTime("2026-12-01T18:30Z").?);
    try t.expectEqual(1796083200 + 5, parseTime("2026-12-01T00:00:05Z").?);
    try t.expectEqual(null, parseTime("2026-13-01"));
    try t.expectEqual(null, parseTime("2026-12-01T18:30"));
}

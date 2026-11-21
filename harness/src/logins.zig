//! The agent's own logins: `logins.ini` (name, site, username; nothing
//! secret), the rules for which pages a login's values may be typed into
//! and which passkeys it may hold, placeholders, generated passwords, and
//! the stored form of passkeys. The values live in the key store under
//! `login-NAME-password`, `login-NAME-totp` and `login-NAME-passkeys`.
const std = @import("std");
const config = @import("config.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const Login = struct {
    name: []const u8,
    site: []const u8,
    username: []const u8 = "",
};

pub const max_name = 48;

pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > max_name) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

/// A lowercase host name: labels of a-z, 0-9 and `-`, joined by dots; no
/// scheme, port or path.
pub fn validSite(s: []const u8) bool {
    if (s.len == 0 or s.len > 253) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

/// `logins.ini`: one section per login with `site` and `username`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ![]Login {
    const ls = config.lines(arena, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadLogins,
    };
    var out: std.ArrayList(Login) = .empty;
    for (ls) |l| {
        if (!validName(l.section)) return error.BadLogins;
        const cur: *Login = blk: {
            if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1].name, l.section)) break :blk &out.items[out.items.len - 1];
            for (out.items) |o| if (std.mem.eql(u8, o.name, l.section)) return error.BadLogins;
            try out.append(arena, .{ .name = l.section, .site = "" });
            break :blk &out.items[out.items.len - 1];
        };
        if (std.mem.eql(u8, l.key, "site")) {
            if (cur.site.len > 0 or !validSite(l.value)) return error.BadLogins;
            cur.site = l.value;
        } else if (std.mem.eql(u8, l.key, "username")) {
            cur.username = l.value;
        } else return error.BadLogins;
    }
    for (out.items) |o| if (o.site.len == 0) return error.BadLogins;
    return out.items;
}

pub fn find(list: []const Login, name: []const u8) ?Login {
    for (list) |l| if (std.mem.eql(u8, l.name, name)) return l;
    return null;
}

/// Whether a value of a login for `site` may be typed into a page at
/// `scheme`://`host`: the host is the site or below it, over https (http
/// only when the site is `localhost`).
pub fn hostAllowed(site: []const u8, scheme: []const u8, host_in: []const u8) bool {
    const sch = std.mem.trimEnd(u8, scheme, ":");
    const https = std.ascii.eqlIgnoreCase(sch, "https");
    const http = std.ascii.eqlIgnoreCase(sch, "http");
    if (!https and !(http and std.mem.eql(u8, site, "localhost"))) return false;
    var buf: [256]u8 = undefined;
    if (host_in.len == 0 or host_in.len > buf.len) return false;
    const host = std.ascii.lowerString(&buf, host_in);
    return underSite(site, host);
}

fn underSite(site: []const u8, host: []const u8) bool {
    if (std.mem.eql(u8, host, site)) return true;
    return host.len > site.len and std.mem.endsWith(u8, host, site) and host[host.len - site.len - 1] == '.';
}

/// Whether a passkey for `rp_id` belongs to a login for `site`: the site
/// itself, a name below it, or a parent domain of it that is not a bare
/// top-level name (`com`).
pub fn rpIdAllowed(site: []const u8, rp_id: []const u8) bool {
    if (rp_id.len == 0) return false;
    if (std.mem.eql(u8, rp_id, site)) return true;
    if (underSite(site, rp_id)) return true;
    if (underSite(rp_id, site)) return std.mem.indexOfScalar(u8, rp_id, '.') != null;
    return false;
}

// ---- placeholders ----

pub const Field = enum { username, password, code };

pub const Span = struct {
    start: usize,
    end: usize,
    login: []const u8,
    field: Field,
};

const open_mark = "{login:";

/// Every `{login:NAME.FIELD}` in `text`. Something that starts like one
/// but is not (an unknown field, a bad name, no closing brace) is an error.
pub fn placeholders(arena: std.mem.Allocator, text: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, open_mark)) |s| {
        const body_start = s + open_mark.len;
        const close = std.mem.indexOfScalarPos(u8, text, body_start, '}') orelse return error.BadPlaceholder;
        const body = text[body_start..close];
        const dot = std.mem.lastIndexOfScalar(u8, body, '.') orelse return error.BadPlaceholder;
        const name = body[0..dot];
        if (!validName(name)) return error.BadPlaceholder;
        const field = std.meta.stringToEnum(Field, body[dot + 1 ..]) orelse return error.BadPlaceholder;
        try out.append(arena, .{ .start = s, .end = close + 1, .login = name, .field = field });
        i = close + 1;
    }
    return out.items;
}

// ---- passwords ----

const lower = "abcdefghijklmnopqrstuvwxyz";
const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const digits = "0123456789";
const symbols = "!#$%&*+-=?@^_";
const alphabet = lower ++ upper ++ digits ++ symbols;

pub const password_len = 24;

/// 24 characters from letters, digits and `!#$%&*+-=?@^_`, with at least
/// one lowercase and one uppercase letter, one digit and one symbol.
pub fn genPassword(io: Io) ![password_len]u8 {
    while (true) {
        var out: [password_len]u8 = undefined;
        var n: usize = 0;
        while (n < out.len) {
            var raw: [64]u8 = undefined;
            try io.randomSecure(&raw);
            // no bias: only bytes below the largest multiple of the alphabet
            const limit = 256 - 256 % alphabet.len;
            for (raw) |b| {
                if (b >= limit or n == out.len) continue;
                out[n] = alphabet[b % alphabet.len];
                n += 1;
            }
        }
        if (hasAny(&out, lower) and hasAny(&out, upper) and hasAny(&out, digits) and hasAny(&out, symbols)) return out;
    }
}

fn hasAny(s: []const u8, set: []const u8) bool {
    return std.mem.indexOfAny(u8, s, set) != null;
}

// ---- passkeys ----

/// A stored passkey; `id`, `key` (PKCS#8), and `user` are base64 as the
/// DevTools protocol gives them.
pub const Passkey = struct {
    id: []const u8,
    rp_id: []const u8,
    key: []const u8,
    user: []const u8 = "",
    count: u32 = 0,
};

pub fn encode(arena: std.mem.Allocator, list: []const Passkey) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (list, 0..) |p, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"id\":");
        try util.jsonString(&out, arena, p.id);
        try out.appendSlice(arena, ",\"rp_id\":");
        try util.jsonString(&out, arena, p.rp_id);
        try out.appendSlice(arena, ",\"key\":");
        try util.jsonString(&out, arena, p.key);
        try out.appendSlice(arena, ",\"user\":");
        try util.jsonString(&out, arena, p.user);
        try out.print(arena, ",\"count\":{d}}}", .{p.count});
    }
    try out.append(arena, ']');
    return out.items;
}

pub fn decode(arena: std.mem.Allocator, json: []const u8) ![]Passkey {
    if (std.mem.trim(u8, json, " \r\n\t").len == 0) return &.{};
    const v = jv.parse(arena, json) orelse return error.BadPasskeys;
    const items = jv.arr(v) orelse return error.BadPasskeys;
    const out = try arena.alloc(Passkey, items.len);
    for (items, 0..) |it, i| {
        out[i] = .{
            .id = jv.str(jv.get(it, "id")) orelse return error.BadPasskeys,
            .rp_id = jv.str(jv.get(it, "rp_id")) orelse return error.BadPasskeys,
            .key = jv.str(jv.get(it, "key")) orelse return error.BadPasskeys,
            .user = jv.str(jv.get(it, "user")) orelse "",
            .count = @intCast(std.math.clamp(jv.int(jv.get(it, "count")) orelse 0, 0, std.math.maxInt(u32))),
        };
    }
    return out;
}

// ---- where the values are kept ----

pub const Kind = enum { password, totp, passkeys };

/// `login-NAME-password`, `login-NAME-totp`, `login-NAME-passkeys`.
pub fn secretName(buf: *[96]u8, name: []const u8, kind: Kind) []const u8 {
    return std.fmt.bufPrint(buf, "login-{s}-{s}", .{ name, @tagName(kind) }) catch unreachable;
}

const t = std.testing;

test "logins_ini_parses_and_refuses_bad_names_and_sites" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parse(a, "[github-bot]\nsite = github.com\nusername = agent-bot@example.com\n\n[local_1]\nsite = localhost\n");
    try t.expectEqual(2, list.len);
    try t.expectEqualStrings("github-bot", list[0].name);
    try t.expectEqualStrings("github.com", list[0].site);
    try t.expectEqualStrings("agent-bot@example.com", list[0].username);
    try t.expectEqualStrings("", list[1].username);
    try t.expectEqualStrings("localhost", find(list, "local_1").?.site);
    for ([_][]const u8{
        "[Bad]\nsite = github.com\n",
        "[x]\nsite = https://github.com\n",
        "[x]\nsite = github.com/login\n",
        "[x]\nsite = github.com:443\n",
        "[x]\nsite = GitHub.com\n",
        "[x]\nusername = u\n",
        "[x]\nsite = a.com\n[x]\nsite = b.com\n",
        "[x]\nsite = a.com\npassword = no\n",
    }) |bad| try t.expectError(error.BadLogins, parse(a, bad));
}

test "host_binding_follows_the_site" {
    try t.expect(hostAllowed("github.com", "https", "github.com"));
    try t.expect(hostAllowed("github.com", "https:", "gist.github.com"));
    try t.expect(hostAllowed("github.com", "https", "GitHub.com"));
    try t.expect(!hostAllowed("github.com", "https", "github.com.evil.com"));
    try t.expect(!hostAllowed("github.com", "https", "evilgithub.com"));
    try t.expect(!hostAllowed("github.com", "https", "evil.com"));
    try t.expect(!hostAllowed("github.com", "http", "github.com"));
    try t.expect(!hostAllowed("github.com", "file", "github.com"));
    try t.expect(hostAllowed("localhost", "http:", "localhost"));
    try t.expect(hostAllowed("localhost", "https", "localhost"));
    try t.expect(!hostAllowed("localhost", "http", "127.0.0.1"));
    try t.expect(!hostAllowed("example.com", "http", "localhost"));
}

test "passkey_rp_ids_must_belong_to_the_site" {
    try t.expect(rpIdAllowed("github.com", "github.com"));
    try t.expect(rpIdAllowed("github.com", "auth.github.com"));
    try t.expect(rpIdAllowed("login.github.com", "github.com"));
    try t.expect(!rpIdAllowed("github.com", "com"));
    try t.expect(!rpIdAllowed("login.github.com", "com"));
    try t.expect(!rpIdAllowed("github.com", "evil.com"));
    try t.expect(!rpIdAllowed("github.com", "notgithub.com"));
    try t.expect(!rpIdAllowed("github.com", ""));
    try t.expect(rpIdAllowed("localhost", "localhost"));
    try t.expect(!rpIdAllowed("localhost", "example.com"));
}

test "placeholders_are_found_and_bad_ones_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "user {login:github-bot.username} pw {login:github-bot.password}{login:x.code}";
    const ps = try placeholders(a, text);
    try t.expectEqual(3, ps.len);
    try t.expectEqualStrings("github-bot", ps[0].login);
    try t.expectEqual(Field.username, ps[0].field);
    try t.expectEqualStrings("{login:github-bot.password}", text[ps[1].start..ps[1].end]);
    try t.expectEqual(Field.code, ps[2].field);
    try t.expectEqual(0, (try placeholders(a, "plain {text} here")).len);
    try t.expectError(error.BadPlaceholder, placeholders(a, "{login:x.pin}"));
    try t.expectError(error.BadPlaceholder, placeholders(a, "{login:X.password}"));
    try t.expectError(error.BadPlaceholder, placeholders(a, "{login:x.password"));
    try t.expectError(error.BadPlaceholder, placeholders(a, "{login:password}"));
}

test "generated_passwords_have_every_class" {
    var seen: [password_len]u8 = undefined;
    for (0..50) |i| {
        const p = try genPassword(t.io);
        try t.expect(hasAny(&p, lower) and hasAny(&p, upper) and hasAny(&p, digits) and hasAny(&p, symbols));
        for (p) |c| try t.expect(std.mem.indexOfScalar(u8, alphabet, c) != null);
        if (i > 0) try t.expect(!std.mem.eql(u8, &p, &seen));
        seen = p;
    }
}

test "passkeys_round_trip" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]Passkey{
        .{ .id = "aWQx", .rp_id = "github.com", .key = "a2V5\"1", .user = "dXNlcg==", .count = 3 },
        .{ .id = "aWQy", .rp_id = "localhost", .key = "a2V5Mg==" },
    };
    const back = try decode(a, try encode(a, &list));
    try t.expectEqual(2, back.len);
    try t.expectEqualStrings("a2V5\"1", back[0].key);
    try t.expectEqual(3, back[0].count);
    try t.expectEqualStrings("localhost", back[1].rp_id);
    try t.expectEqual(0, (try decode(a, "")).len);
    try t.expectError(error.BadPasskeys, decode(a, "{}"));
    var buf: [96]u8 = undefined;
    try t.expectEqualStrings("login-github-bot-passkeys", secretName(&buf, "github-bot", .passkeys));
}

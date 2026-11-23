//! Gate rules: one per line, `allow|ask|deny TOOL[@ENV] PATTERN`, `#`
//! comments. `*` in a pattern matches any run of characters (including
//! none). A line `[WHO]` (a who pattern, see who.zig) starts rules for the
//! calls whose who it matches; lines before the first, or after `[all]`,
//! are the shared part, for every call. `@ENV` is only for `shell`: the
//! rule is for commands in that environment (`host` until gap 2).
//!
//! For `fetch` and `browse` a pattern is an address matched by parts (see
//! `UrlPattern`), for `web` a host (see `HostPattern`), each against the
//! address as url.zig reads it. An `allow` rule for them must be one;
//! `deny` and `ask` rules may also be any other pattern, matched as a glob
//! over the whole address: they can only stop or ask about more.
const std = @import("std");
const url = @import("url.zig");
const who = @import("who.zig");
const Allocator = std.mem.Allocator;

pub const Action = enum { allow, ask, deny };

pub const Rule = struct {
    action: Action,
    tool: []const u8,
    pattern: []const u8,
    line: usize,
    /// `shell@box`: the environment the rule is for; null: every one.
    env: ?[]const u8 = null,
    /// The who pattern of the section the rule is in (`agent:coder`);
    /// null: the shared part.
    section: ?[]const u8 = null,
};

pub const Error = error{
    BadRule,
    /// An allow rule for fetch or browse that is not an address pattern.
    BadUrlRule,
    /// An allow rule for web that is not a host pattern.
    BadHostRule,
    /// A `[...]` line that is not `[all]` or a who pattern.
    BadSection,
    /// `TOOL@ENV` for a tool that runs in no environment, or a bad name.
    BadEnv,
    OutOfMemory,
};

/// What is wrong with a rule's line, when more can be said than that it
/// does not read.
pub fn reason(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.BadUrlRule => "an allow rule for fetch or browse takes an address: scheme://host/path, the host a name, *.name or *, like https://*.example.com/*; a port, when given, is a number or *",
        error.BadHostRule => "an allow rule for web takes a host: a name, *.name or *, like *.example.com; a port, when given, is a number or *",
        error.BadSection => "a section is [all] or a who: owner, schedule:NAME, trigger:NAME, workflow:NAME/STEP, app:NAME, agent:NAME, member:NAME or room:NAME; a kind alone covers all its names, and * works as in rules",
        error.BadEnv => "only shell takes an environment: shell@NAME, the name in a-z, 0-9, - and _",
        else => null,
    };
}

/// The host part of an address pattern, or a web rule's pattern.
pub const HostPattern = struct {
    host: Host,
    port: Port,

    pub const Host = union(enum) {
        any,
        /// Every name below this one (`*.example.com`), not itself.
        below: []const u8,
        exact: []const u8,
    };
    /// `default`: none was written, so the scheme's own (for web: an
    /// address without a port).
    pub const Port = union(enum) { default, any, n: u16 };

    fn hostMatches(p: HostPattern, host: []const u8) bool {
        return switch (p.host) {
            .any => true,
            .exact => |h| std.mem.eql(u8, h, host),
            .below => |h| host.len > h.len + 1 and std.mem.endsWith(u8, host, h) and host[host.len - h.len - 1] == '.',
        };
    }

    /// A web host: "host" or "host:port".
    pub fn matches(p: HostPattern, hp: url.HostPort) bool {
        if (!p.hostMatches(hp.host)) return false;
        return switch (p.port) {
            .default => hp.port == null,
            .any => true,
            .n => |n| hp.port == n,
        };
    }
};

/// A fetch or browse pattern: the scheme (a glob), the host, the port, and
/// a glob over the path with its query, where none written is any.
pub const UrlPattern = struct {
    scheme: []const u8,
    host: HostPattern,
    target: ?[]const u8,

    pub fn matches(p: UrlPattern, u: url.Url) bool {
        if (!glob(p.scheme, u.scheme())) return false;
        if (!p.host.hostMatches(u.host)) return false;
        switch (p.host.port) {
            .default => if (u.port != url.defaultPort(u.https)) return false,
            .any => {},
            .n => |n| if (u.port != n) return false,
        }
        return if (p.target) |tg| glob(tg, u.target) else true;
    }
};

/// `text` read as a host pattern, the host in url.zig's form; null if it
/// is not one. `*` is the whole host or its first part (`*.example.com`):
/// anywhere else it could match a name that is not below the one meant.
pub fn hostPattern(arena: Allocator, text: []const u8) ?HostPattern {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '@') != null) return null;
    var host_text = text;
    var port_text: ?[]const u8 = null;
    if (text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return null;
        host_text = text[0 .. close + 1];
        const after = text[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return null;
            port_text = after[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        host_text = text[0..colon];
        port_text = text[colon + 1 ..];
    }
    var port: HostPattern.Port = .default;
    if (port_text) |p| {
        if (std.mem.eql(u8, p, "*")) {
            port = .any;
        } else if (p.len > 0) port = .{ .n = url.parsePort(p) catch return null };
    }
    const host: HostPattern.Host = if (std.mem.eql(u8, host_text, "*"))
        .any
    else if (std.mem.startsWith(u8, host_text, "*.")) blk: {
        const h = url.canonicalHost(arena, host_text[2..]) catch return null;
        // below an IP address there are no names
        if (url.isIp(h)) return null;
        break :blk .{ .below = h };
    } else .{ .exact = url.canonicalHost(arena, host_text) catch return null };
    return .{ .host = host, .port = port };
}

/// `text` read as an address pattern; null if it is not one.
pub fn urlPattern(arena: Allocator, text: []const u8) ?UrlPattern {
    if (std.mem.eql(u8, text, "*")) return .{ .scheme = "*", .host = .{ .host = .any, .port = .any }, .target = null };
    const sep = std.mem.indexOf(u8, text, "://") orelse return null;
    const scheme = std.ascii.allocLowerString(arena, text[0..sep]) catch return null;
    for (scheme) |c| if (!(std.ascii.isLower(c) or c == '*')) return null;
    if (!glob(scheme, "http") and !glob(scheme, "https")) return null;
    const rest = text[sep + 3 ..];
    // a fragment is never sent, so it is never matched
    for (rest) |c| if (c <= ' ' or c == 0x7f or c == '\\' or c == '#') return null;
    const end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const host = hostPattern(arena, rest[0..end]) orelse return null;
    const tail = rest[end..];
    if (tail.len == 0) return .{ .scheme = scheme, .host = host, .target = null };
    // the path as url.zig writes an address's: "/" first, %XX as there
    const t0 = if (tail[0] == '?') std.fmt.allocPrint(arena, "/{s}", .{tail}) catch return null else tail;
    return .{ .scheme = scheme, .host = host, .target = url.escapes(arena, t0) catch return null };
}

/// Whether a fetch or browse rule's pattern matches `address` (as url.zig
/// writes it): by parts for an address pattern, else as a glob.
pub fn matchUrl(arena: Allocator, pattern: []const u8, address: []const u8) bool {
    const p = urlPattern(arena, pattern) orelse return glob(pattern, address);
    const u = url.parse(arena, address) catch return false;
    return p.matches(u);
}

/// Whether a web rule's pattern matches `host` ("host" or "host:port"):
/// by parts for a host pattern (`*` alone: any host and port), else as a
/// glob.
pub fn matchHost(arena: Allocator, pattern: []const u8, host: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const p = hostPattern(arena, pattern) orelse return glob(pattern, host);
    const hp = url.hostPort(arena, host) catch return false;
    return p.matches(hp);
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error![]Rule {
    var out: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    // the who pattern of the section being read; null: the shared part
    var section: ?[]const u8 = null;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') return error.BadSection;
            const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.eql(u8, inner, "all")) {
                section = null;
            } else if (who.isPattern(inner)) {
                section = inner;
            } else return error.BadSection;
            continue;
        }
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const action_word = words.next() orelse return error.BadRule;
        const action = std.meta.stringToEnum(Action, action_word) orelse return error.BadRule;
        const tool_word = words.next() orelse return error.BadRule;
        // shell@box: a rule for commands in that environment only
        var tool = tool_word;
        var env: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, tool_word, '@')) |at| {
            tool = tool_word[0..at];
            env = tool_word[at + 1 ..];
            if (!std.mem.eql(u8, tool, "shell") or !envName(env.?)) return error.BadEnv;
        }
        // the pattern is the rest of the line, inner spaces kept
        const rest = std.mem.trim(u8, words.rest(), " \t");
        if (rest.len == 0) return error.BadRule;
        // as one glob over an address, an allow could let another host through
        if (action == .allow) {
            if ((std.mem.eql(u8, tool, "fetch") or std.mem.eql(u8, tool, "browse")) and urlPattern(arena, rest) == null) return error.BadUrlRule;
            if (std.mem.eql(u8, tool, "web") and !std.mem.eql(u8, rest, "*") and hostPattern(arena, rest) == null) return error.BadHostRule;
        }
        try out.append(arena, .{ .action = action, .tool = tool, .pattern = rest, .line = n, .env = env, .section = section });
    }
    return out.items;
}

/// An environment's name (gap 2): 1 to 32 of a-z, 0-9, `-` and `_`.
pub fn envName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

/// `*` matches any run of characters; everything else matches itself.
pub fn glob(pattern: []const u8, s: []const u8) bool {
    return globCase(pattern, s, false);
}

/// `glob`, with ASCII letters matching either case when `fold` is set.
pub fn globCase(pattern: []const u8, s: []const u8, fold: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = i;
        } else if (p < pattern.len and (pattern[p] == s[i] or (fold and std.ascii.toLower(pattern[p]) == std.ascii.toLower(s[i])))) {
            p += 1;
            i += 1;
        } else if (star) |st| {
            p = st + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const t = std.testing;

test "rules_parse_and_keep_spaces_in_patterns" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rs = try parse(arena.allocator(),
        \\# comment
        \\deny  shell rm -rf *
        \\allow fetch https://news.ycombinator.com/*
    );
    try t.expectEqual(2, rs.len);
    try t.expectEqual(Action.deny, rs[0].action);
    try t.expectEqualStrings("shell", rs[0].tool);
    try t.expectEqualStrings("rm -rf *", rs[0].pattern);
    try t.expectError(error.BadRule, parse(arena.allocator(), "permit shell *"));
    try t.expectError(error.BadRule, parse(arena.allocator(), "allow shell"));
}

test "an_allow_rule_for_an_address_tool_must_be_one_that_matches_by_parts" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // as one glob over the address these let other hosts through
    for ([_][]const u8{
        "allow fetch *.good.com/*",
        "allow fetch *good.com*",
        "allow fetch https://good.com*",
        "allow fetch https://*good.com/*",
        "allow browse https://www.google.*/*",
        "allow fetch https://192.168.1.*/*",
        "allow fetch https://good.com@*/*",
        "allow fetch ftp://good.com/*",
        "allow fetch https://*.127.0.0.1/*",
        "allow fetch https://good.com/#x",
        "allow fetch https://bücher.de/*",
        "allow fetch https://good.com:http/*",
    }) |line| try t.expectError(error.BadUrlRule, parse(a, line));
    for ([_][]const u8{ "allow web *good.com", "allow web good.com*", "allow web https://good.com/*", "allow web good.com/x", "allow web *.1.2.3.4" }) |line|
        try t.expectError(error.BadHostRule, parse(a, line));
    // these match by parts; deny and ask may be any pattern
    const ok = try parse(a,
        \\allow fetch *
        \\allow fetch https://*.good.com/*
        \\allow fetch http://127.0.0.1:*
        \\allow browse *://Good.COM.:8080/api/*?key=*
        \\allow fetch https://[::1]:8443/*
        \\allow web *
        \\allow web *.good.com
        \\allow web localhost:8080
        \\deny fetch *evil*
        \\ask browse *.good.com/*
        \\deny web *bad*
    );
    try t.expectEqual(11, ok.len);
    try t.expect(reason(error.BadUrlRule) != null and reason(error.BadHostRule) != null and reason(error.BadRule) == null);
}

test "sections_and_environments_parse" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rs = try parse(a,
        \\deny  shell rm -rf *
        \\[agent:coder]
        \\allow shell@box zig build*
        \\[schedule:btc-watch]
        \\allow fetch https://api.coinbase.com/*
        \\[all]
        \\ask shell@host git push*
    );
    try t.expectEqual(4, rs.len);
    try t.expectEqual(null, rs[0].section);
    try t.expectEqual(null, rs[0].env);
    try t.expectEqualStrings("agent:coder", rs[1].section.?);
    try t.expectEqualStrings("shell", rs[1].tool);
    try t.expectEqualStrings("box", rs[1].env.?);
    try t.expectEqualStrings("zig build*", rs[1].pattern);
    try t.expectEqual(3, rs[1].line);
    try t.expectEqualStrings("schedule:btc-watch", rs[2].section.?);
    try t.expectEqual(null, rs[3].section);
    try t.expectEqualStrings("host", rs[3].env.?);
    for ([_][]const u8{ "[nobody:x]", "[agent:coder", "[]", "[agent:coder] # note" }) |line|
        try t.expectError(error.BadSection, parse(a, line));
    for ([_][]const u8{ "allow fetch@box https://a.com/*", "allow shell@ *", "allow shell@Box *" }) |line|
        try t.expectError(error.BadEnv, parse(a, line));
    try t.expect(reason(error.BadSection) != null and reason(error.BadEnv) != null);
}

test "glob_matches_runs" {
    try t.expect(glob("*", ""));
    try t.expect(glob("rm -rf *", "rm -rf /"));
    try t.expect(!glob("rm -rf *", "echo rm -rf /"));
    try t.expect(glob("*rm -rf*", "echo; rm -rf /"));
    try t.expect(glob("https://a.com/*", "https://a.com/x/y"));
    try t.expect(!glob("https://a.com/*", "https://a.com.evil/x"));
    try t.expect(glob("a*b*c", "aXXbYYc"));
    try t.expect(!glob("a*b*c", "aXXbYY"));
    try t.expect(glob("git status", "git status"));
    try t.expect(!glob("git status", "git status; rm x"));
    try t.expect(!glob("Private/*", "private/k"));
    try t.expect(globCase("Private/*", "private/k", true));
    try t.expect(!globCase("private/*", "public/k", true));
}

test "member_sections_parse" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rs = try parse(arena.allocator(),
        \\[member]
        \\allow mcp cloud/car_status *
        \\[member:anna]
        \\ask mcp */home_set *
    );
    try t.expectEqual(2, rs.len);
    try t.expectEqualStrings("member", rs[0].section.?);
    try t.expectEqualStrings("member:anna", rs[1].section.?);
    try t.expect(std.mem.indexOf(u8, reason(error.BadSection).?, "member:NAME") != null);
}

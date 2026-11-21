//! Gate rules: one per line, `allow|ask|deny TOOL PATTERN`, `#` comments.
//! `*` in a pattern matches any run of characters (including none).
const std = @import("std");

pub const Action = enum { allow, ask, deny };

pub const Rule = struct {
    action: Action,
    tool: []const u8,
    pattern: []const u8,
    line: usize,
};

pub const Error = error{ BadRule, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error![]Rule {
    var out: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const action_word = words.next() orelse return error.BadRule;
        const action = std.meta.stringToEnum(Action, action_word) orelse return error.BadRule;
        const tool = words.next() orelse return error.BadRule;
        // the pattern is the rest of the line, inner spaces kept
        const rest = std.mem.trim(u8, words.rest(), " \t");
        if (rest.len == 0) return error.BadRule;
        try out.append(arena, .{ .action = action, .tool = tool, .pattern = rest, .line = n });
    }
    return out.items;
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

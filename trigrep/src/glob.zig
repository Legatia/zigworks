//! gitignore-style glob matching: `*`, `?`, `[...]`, `**`, backslash escapes.

const std = @import("std");

/// Matches `pat` against `s`. `*` and `?` don't cross `/`; `**/` matches zero or more
/// directories and a trailing `**` matches everything.
pub fn match(pat: []const u8, s: []const u8) bool {
    return matchAt(pat, 0, s, 0);
}

fn matchAt(p: []const u8, pi0: usize, s: []const u8, si0: usize) bool {
    var pi = pi0;
    var si = si0;
    while (pi < p.len) {
        const c = p[pi];
        if (c == '*') {
            if (pi + 1 < p.len and p[pi + 1] == '*') {
                var np = pi + 2;
                if (np < p.len and p[np] == '/') {
                    np += 1;
                    if (matchAt(p, np, s, si)) return true;
                    var k = si;
                    while (k < s.len) : (k += 1) {
                        if (s[k] == '/' and matchAt(p, np, s, k + 1)) return true;
                    }
                    return false;
                }
                var k = si;
                while (k <= s.len) : (k += 1) {
                    if (matchAt(p, np, s, k)) return true;
                }
                return false;
            }
            var k = si;
            while (true) : (k += 1) {
                if (matchAt(p, pi + 1, s, k)) return true;
                if (k >= s.len or s[k] == '/') return false;
            }
        }
        if (si >= s.len) return false;
        switch (c) {
            '?' => {
                if (s[si] == '/') return false;
                pi += 1;
            },
            '[' => {
                if (classMatch(p, pi, s[si])) |r| {
                    if (!r.matched) return false;
                    pi = r.end;
                } else {
                    if (s[si] != '[') return false;
                    pi += 1;
                }
            },
            '\\' => {
                const lit = if (pi + 1 < p.len) p[pi + 1] else '\\';
                if (s[si] != lit) return false;
                pi += if (pi + 1 < p.len) 2 else 1;
            },
            else => {
                if (s[si] != c) return false;
                pi += 1;
            },
        }
        si += 1;
    }
    return si == s.len;
}

const ClassResult = struct { matched: bool, end: usize };

/// Returns null if the `[` at `start` has no closing `]` (then it's a literal).
fn classMatch(p: []const u8, start: usize, ch: u8) ?ClassResult {
    var i = start + 1;
    var negate = false;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < p.len) {
        if (p[i] == ']' and !first) return .{ .matched = matched != negate, .end = i + 1 };
        first = false;
        var lo = p[i];
        if (lo == '\\' and i + 1 < p.len) {
            i += 1;
            lo = p[i];
        }
        i += 1;
        var hi = lo;
        if (i + 1 < p.len and p[i] == '-' and p[i + 1] != ']') {
            hi = p[i + 1];
            i += 2;
        }
        if (ch >= lo and ch <= hi and ch != '/') matched = true;
    }
    return null;
}

test "basic globs" {
    try std.testing.expect(match("*.zig", "main.zig"));
    try std.testing.expect(!match("*.zig", "src/main.zig"));
    try std.testing.expect(match("src/*.zig", "src/main.zig"));
    try std.testing.expect(match("ma?n.zig", "main.zig"));
    try std.testing.expect(match("[a-c]x", "bx"));
    try std.testing.expect(!match("[!a-c]x", "bx"));
    try std.testing.expect(match("\\*x", "*x"));
    try std.testing.expect(match("[x", "[x"));
}

test "double star" {
    try std.testing.expect(match("**/foo", "foo"));
    try std.testing.expect(match("**/foo", "a/b/foo"));
    try std.testing.expect(match("a/**/b", "a/b"));
    try std.testing.expect(match("a/**/b", "a/x/y/b"));
    try std.testing.expect(!match("a/**/b", "a/x/y/c"));
    try std.testing.expect(match("a/**", "a/x/y"));
    try std.testing.expect(match("**", "anything/at/all"));
}

//! Turns a regex AST into a trigram query (which files can possibly match) and a
//! required literal (a substring every matching line contains, used to skip lines).
//!
//! Trigrams are ASCII-lowercased on both sides, so one index serves case-sensitive and
//! case-insensitive searches. The query is always a superset filter: false positives are
//! fine (the regex runs afterwards), false negatives are bugs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const Node = regex.Node;

pub const Query = union(enum) {
    /// No constraint: every file is a candidate.
    all,
    tri: u32,
    and_: []const Query,
    or_: []const Query,
};

pub const Literal = struct {
    bytes: []const u8,
    /// Some characters came from a case-folded set, so match case-insensitively.
    ignore_case: bool,
};

pub const Plan = struct {
    query: Query,
    /// Longest substring every match contains, or null if there's no useful one.
    required: ?Literal,
    /// When there's no single required literal but the pattern is an alternation of
    /// literals (`TODO|FIXME`), every match contains one of these.
    alternatives: ?[]const Literal = null,
    /// The regex matches exactly `required` (or one of `alternatives`) and nothing else,
    /// so a substring hit is already a match.
    pure_literal: bool,
};

pub fn fold(b: u8) u8 {
    return std.ascii.toLower(b);
}

pub fn trigramKey(a: u8, b: u8, c: u8) u32 {
    return (@as(u32, fold(a)) << 16) | (@as(u32, fold(b)) << 8) | fold(c);
}

const Info = struct {
    /// The node always matches exactly this string.
    exact: ?Literal,
    query: Query,
    required: ?Literal,
    /// The node is an alternation of these non-empty literals.
    alts: ?[]const Literal = null,
};

const Analyzer = struct {
    arena: Allocator,
    has_assertions: bool = false,

    fn trigramsOf(a: *Analyzer, s: []const u8) !Query {
        if (s.len < 3) return .all;
        var items: std.ArrayList(Query) = .empty;
        var i: usize = 0;
        while (i + 3 <= s.len) : (i += 1) {
            if (std.mem.indexOfScalar(u8, s[i .. i + 3], '\n') != null) continue;
            const t = trigramKey(s[i], s[i + 1], s[i + 2]);
            for (items.items) |q| {
                if (q.tri == t) break;
            } else try items.append(a.arena, .{ .tri = t });
        }
        if (items.items.len == 0) return .all;
        if (items.items.len == 1) return items.items[0];
        return .{ .and_ = items.items };
    }

    fn andOf(a: *Analyzer, x: Query, y: Query) !Query {
        if (x == .all) return y;
        if (y == .all) return x;
        var items: std.ArrayList(Query) = .empty;
        for ([_]Query{ x, y }) |q| switch (q) {
            .and_ => |sub| try items.appendSlice(a.arena, sub),
            else => try items.append(a.arena, q),
        };
        return .{ .and_ = items.items };
    }

    fn finalize(a: *Analyzer, info: Info) !Query {
        if (info.exact) |e| return a.trigramsOf(e.bytes);
        return info.query;
    }

    fn longer(x: ?Literal, y: ?Literal) ?Literal {
        if (x == null) return y;
        if (y == null) return x;
        return if (y.?.bytes.len > x.?.bytes.len) y else x;
    }

    fn exactInfo(lit: Literal) Info {
        return .{ .exact = lit, .query = .all, .required = if (lit.bytes.len > 0) lit else null };
    }

    const SetChar = struct { byte: u8, ignore_case: bool };

    /// A set that is really one character: a single byte, or a letter in both cases.
    fn setLiteral(s: regex.Set) ?SetChar {
        if (s.ranges.len > 0) return null;
        const n = s.bytes.count();
        const first: u8 = @intCast(s.bytes.findFirstSet() orelse return null);
        if (n == 1) return .{ .byte = first, .ignore_case = false };
        if (n == 2 and std.ascii.isAlphabetic(first)) {
            const lower = std.ascii.toLower(first);
            if (s.bytes.isSet(lower) and s.bytes.isSet(std.ascii.toUpper(first)))
                return .{ .byte = lower, .ignore_case = true };
        }
        return null;
    }

    fn analyze(a: *Analyzer, n: Node) error{OutOfMemory}!Info {
        switch (n) {
            .empty => return exactInfo(.{ .bytes = "", .ignore_case = false }),
            .byte => |b| return exactInfo(.{ .bytes = try a.arena.dupe(u8, &.{b}), .ignore_case = false }),
            .set => |s| {
                if (setLiteral(s)) |ch| return exactInfo(.{ .bytes = try a.arena.dupe(u8, &.{ch.byte}), .ignore_case = ch.ignore_case });
                return .{ .exact = null, .query = .all, .required = null };
            },
            .bol, .eol, .word_boundary, .not_word_boundary => {
                a.has_assertions = true;
                return exactInfo(.{ .bytes = "", .ignore_case = false });
            },
            .concat => |items| {
                var run: std.ArrayList(u8) = .empty;
                var run_ci = false;
                var broken = false;
                var q: Query = .all;
                var required: ?Literal = null;
                for (items) |it| {
                    const info = try a.analyze(it);
                    if (info.exact) |e| {
                        try run.appendSlice(a.arena, e.bytes);
                        run_ci = run_ci or e.ignore_case;
                        continue;
                    }
                    broken = true;
                    if (run.items.len > 0) {
                        q = try a.andOf(q, try a.trigramsOf(run.items));
                        required = longer(required, .{ .bytes = run.items, .ignore_case = run_ci });
                        run = .empty;
                        run_ci = false;
                    }
                    q = try a.andOf(q, info.query);
                    required = longer(required, info.required);
                }
                if (!broken) return exactInfo(.{ .bytes = run.items, .ignore_case = run_ci });
                if (run.items.len > 0) {
                    q = try a.andOf(q, try a.trigramsOf(run.items));
                    required = longer(required, .{ .bytes = run.items, .ignore_case = run_ci });
                }
                return .{ .exact = null, .query = q, .required = required };
            },
            .alt => |items| {
                var alts: std.ArrayList(Query) = .empty;
                var lits: std.ArrayList(Literal) = .empty;
                var all_literal = true;
                var unconstrained = false;
                for (items) |it| {
                    const info = try a.analyze(it);
                    if (info.exact) |e| {
                        if (e.bytes.len > 0) try lits.append(a.arena, e) else all_literal = false;
                    } else all_literal = false;
                    const q = try a.finalize(info);
                    if (q == .all) unconstrained = true else try alts.append(a.arena, q);
                }
                return .{
                    .exact = null,
                    .query = if (unconstrained) .all else .{ .or_ = alts.items },
                    .required = null,
                    .alts = if (all_literal) lits.items else null,
                };
            },
            .repeat => |r| {
                if (r.min == 0) {
                    // Still walk the child so assertions inside it are noticed.
                    _ = try a.analyze(r.node.*);
                    return .{ .exact = null, .query = .all, .required = null };
                }
                const info = try a.analyze(r.node.*);
                if (info.exact) |e| {
                    if (r.max != null and r.max.? == r.min and e.bytes.len * r.min <= 256) {
                        var s: std.ArrayList(u8) = .empty;
                        for (0..r.min) |_| try s.appendSlice(a.arena, e.bytes);
                        return exactInfo(.{ .bytes = s.items, .ignore_case = e.ignore_case });
                    }
                    // x{2,} contains x twice in a row, so its trigrams are required.
                    var s: std.ArrayList(u8) = .empty;
                    for (0..r.min) |_| try s.appendSlice(a.arena, e.bytes);
                    const lit = Literal{ .bytes = s.items, .ignore_case = e.ignore_case };
                    return .{ .exact = null, .query = try a.trigramsOf(s.items), .required = if (s.items.len > 0) lit else null };
                }
                return .{ .exact = null, .query = info.query, .required = info.required };
            },
        }
    }
};

pub fn plan(arena: Allocator, root: Node) !Plan {
    var a = Analyzer{ .arena = arena };
    const info = try a.analyze(root);
    const query = try a.finalize(info);
    const required = if (info.exact) |e| (if (e.bytes.len > 0) e else null) else info.required;
    const alternatives = if (required == null) info.alts else null;
    return .{
        .query = query,
        .required = required,
        .alternatives = alternatives,
        .pure_literal = !a.has_assertions and ((info.exact != null and required != null) or alternatives != null),
    };
}

// ---------------------------------------------------------------------------
// Tests

fn planFor(arena: Allocator, pattern: []const u8, opts: regex.Options) !Plan {
    return plan(arena, try regex.parse(arena, pattern, opts));
}

fn countTris(q: Query) usize {
    return switch (q) {
        .all => 0,
        .tri => 1,
        .and_, .or_ => |items| blk: {
            var n: usize = 0;
            for (items) |it| n += countTris(it);
            break :blk n;
        },
    };
}

test "literal becomes an AND of its trigrams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try planFor(arena.allocator(), "hello", .{});
    try std.testing.expect(p.query == .and_);
    try std.testing.expectEqual(@as(usize, 3), p.query.and_.len);
    try std.testing.expectEqualStrings("hello", p.required.?.bytes);
    try std.testing.expect(p.pure_literal);
}

test "case-insensitive literal uses the same lowercased trigrams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try planFor(arena.allocator(), "Hello", .{ .ignore_case = true });
    try std.testing.expectEqualStrings("hello", a.required.?.bytes);
    try std.testing.expect(a.required.?.ignore_case);
    try std.testing.expectEqual(trigramKey('h', 'e', 'l'), a.query.and_[0].tri);
}

test "classes break literals; short literals give no constraint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try planFor(arena.allocator(), "foo[0-9]+bar", .{});
    try std.testing.expectEqual(@as(usize, 2), countTris(p.query));
    try std.testing.expect(!p.pure_literal);
    const q = try planFor(arena.allocator(), "ab.cd", .{});
    try std.testing.expect(q.query == .all);
    const r = try planFor(arena.allocator(), "\\w+", .{});
    try std.testing.expect(r.query == .all);
    try std.testing.expect(r.required == null);
}

test "alternation is an OR; an unconstrained branch makes it all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try planFor(arena.allocator(), "foobar|bazqux", .{});
    try std.testing.expect(p.query == .or_);
    try std.testing.expect(p.required == null);
    try std.testing.expectEqual(@as(usize, 2), p.alternatives.?.len);
    try std.testing.expect(p.pure_literal);
    const q = try planFor(arena.allocator(), "foobar|x", .{});
    try std.testing.expect(q.query == .all);
    try std.testing.expectEqual(@as(usize, 2), q.alternatives.?.len);
    const r = try planFor(arena.allocator(), "foo|ba[rz]", .{});
    try std.testing.expect(r.alternatives == null);
}

test "optional parts are not required, anchors stay exact but not pure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try planFor(arena.allocator(), "colou?r", .{});
    try std.testing.expectEqual(@as(usize, 2), countTris(p.query)); // "col", "olo"
    try std.testing.expectEqualStrings("colo", p.required.?.bytes);
    const q = try planFor(arena.allocator(), "^fn main", .{});
    try std.testing.expectEqualStrings("fn main", q.required.?.bytes);
    try std.testing.expect(!q.pure_literal);
    const r = try planFor(arena.allocator(), "(abc)+", .{});
    try std.testing.expectEqualStrings("abc", r.required.?.bytes);
}

//! Small regular expressions for `wait --regex`.
//!
//! Syntax: literals, `.`, `[...]` and `[^...]` classes with ranges, `\d \w
//! \s` (and `\D \W \S`), `^` `$`, `(...)` and `(?:...)` groups, `|`, and the
//! quantifiers `* + ? {n} {n,} {n,m}` (a trailing `?` for laziness is
//! accepted and ignored). A leading `(?i)` makes ASCII letters match either
//! case. Matching is on codepoints of UTF-8 text.
//!
//! Patterns compile to a Thompson NFA run as a Pike VM without captures, so
//! a search is O(text × pattern) and no pattern can make it blow up.

const std = @import("std");
const Allocator = std.mem.Allocator;

const max_program = 20_000;
const max_repeat = 1_000;

const Range = struct { lo: u21, hi: u21 };

const Class = struct {
    ranges: []const Range,
    negated: bool,

    fn has(c: Class, cp: u21) bool {
        for (c.ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) return !c.negated;
        }
        return c.negated;
    }
};

const Inst = union(enum) {
    char: u21,
    any,
    class: Class,
    split: [2]u32,
    jmp: u32,
    bol,
    eol,
    match,
};

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: Class,
    bol,
    eol,
    cat: []const Node,
    alt: []const Node,
    repeat: struct { node: *const Node, min: u32, max: ?u32 },
};

pub const Error = error{BadRegex} || Allocator.Error;

/// Why a pattern was rejected. Owned by the caller, so it outlives the
/// failed compile.
pub const Diagnostic = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        d.len = (std.fmt.bufPrint(&d.buf, fmt, args) catch d.buf[0..]).len;
    }
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    prog: []const Inst,
    icase: bool,
    // Scratch space for search.
    clist: []u32,
    nlist: []u32,
    stack: []u32,
    marks: []u32,
    gen: u32 = 0,

    /// On error.BadRegex, `diag` says what is wrong.
    pub fn compile(gpa: Allocator, pattern_in: []const u8, diag: *Diagnostic) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var pattern = pattern_in;
        var icase = false;
        if (std.mem.startsWith(u8, pattern, "(?i)")) {
            icase = true;
            pattern = pattern[4..];
        }
        if (!std.unicode.utf8ValidateSlice(pattern)) {
            diag.set("pattern is not valid UTF-8", .{});
            return error.BadRegex;
        }

        var p: Parser = .{ .a = a, .src = pattern, .diag = diag };
        const root = try p.parseAlt();
        if (p.pos < p.src.len) return p.fail("unmatched ')'");

        var c: Compiler = .{ .a = a, .diag = diag };
        try c.emitNode(root);
        _ = try c.emit(.match);

        const n = c.prog.items.len;
        const clist = try a.alloc(u32, n);
        const nlist = try a.alloc(u32, n);
        const stack = try a.alloc(u32, 2 * n + 2);
        const marks = try a.alloc(u32, n);
        @memset(marks, 0);
        // Copy the arena only after its last allocation.
        return .{
            .arena = arena,
            .prog = c.prog.items,
            .icase = icase,
            .clist = clist,
            .nlist = nlist,
            .stack = stack,
            .marks = marks,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    /// True if the pattern matches anywhere in `text` (UTF-8).
    pub fn search(self: *Regex, gpa: Allocator, text: []const u8) Allocator.Error!bool {
        var cps: std.ArrayList(u21) = .empty;
        defer cps.deinit(gpa);
        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(i + len, text.len);
            const cp = std.unicode.utf8Decode(text[i..end]) catch text[i];
            try cps.append(gpa, cp);
            i = end;
        }
        return self.run(cps.items);
    }

    fn nextGen(self: *Regex) u32 {
        if (self.gen == std.math.maxInt(u32)) {
            @memset(self.marks, 0);
            self.gen = 0;
        }
        self.gen += 1;
        return self.gen;
    }

    fn run(self: *Regex, text: []const u21) bool {
        var clist = self.clist;
        var nlist = self.nlist;
        var clen: usize = 0;
        var gen = self.nextGen();
        var pos: usize = 0;
        while (true) : (pos += 1) {
            // Unanchored search: a new thread starts at every position.
            if (self.addThread(clist, &clen, 0, pos, text.len, gen)) return true;
            if (pos == text.len) return false;
            const c = text[pos];
            var nlen: usize = 0;
            const next_gen = self.nextGen();
            for (clist[0..clen]) |pc| {
                if (self.consumes(self.prog[pc], c)) {
                    if (self.addThread(nlist, &nlen, pc + 1, pos + 1, text.len, next_gen)) return true;
                }
            }
            std.mem.swap([]u32, &clist, &nlist);
            clen = nlen;
            gen = next_gen;
        }
    }

    /// Adds `start` and everything reachable from it without consuming
    /// input. Returns true if that reaches `match`.
    fn addThread(self: *Regex, list: []u32, len: *usize, start: u32, pos: usize, n: usize, gen: u32) bool {
        var sp: usize = 0;
        self.stack[sp] = start;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = self.stack[sp];
            if (self.marks[pc] == gen) continue;
            self.marks[pc] = gen;
            switch (self.prog[pc]) {
                .jmp => |x| {
                    self.stack[sp] = x;
                    sp += 1;
                },
                .split => |xy| {
                    self.stack[sp] = xy[1];
                    self.stack[sp + 1] = xy[0];
                    sp += 2;
                },
                .bol => if (pos == 0) {
                    self.stack[sp] = pc + 1;
                    sp += 1;
                },
                .eol => if (pos == n) {
                    self.stack[sp] = pc + 1;
                    sp += 1;
                },
                .match => return true,
                else => {
                    list[len.*] = pc;
                    len.* += 1;
                },
            }
        }
        return false;
    }

    fn consumes(self: *const Regex, inst: Inst, c: u21) bool {
        return switch (inst) {
            .any => c != '\n',
            .char => |x| x == c or (self.icase and fold(x) == fold(c)),
            .class => |cl| cl.has(c) or (self.icase and (cl.has(fold(c)) or cl.has(upper(c)))),
            else => false,
        };
    }
};

fn fold(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn upper(c: u21) u21 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    diag: *Diagnostic,

    fn fail(p: *Parser, msg: []const u8) Error {
        p.diag.set("{s} at offset {d}", .{ msg, p.pos });
        return error.BadRegex;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn nextCodepoint(p: *Parser) u21 {
        const len = std.unicode.utf8ByteSequenceLength(p.src[p.pos]) catch 1;
        const cp = std.unicode.utf8Decode(p.src[p.pos..][0..len]) catch p.src[p.pos];
        p.pos += len;
        return cp;
    }

    fn parseAlt(p: *Parser) Error!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(p.a, try p.parseCat());
        while (p.peek() == '|') {
            p.pos += 1;
            try branches.append(p.a, try p.parseCat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn parseCat(p: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(p.a, try p.parseRepeat());
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .cat = items.items };
    }

    fn parseRepeat(p: *Parser) Error!Node {
        var node = try p.parseAtom();
        while (p.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => p.pos += 1,
                '+' => {
                    p.pos += 1;
                    min = 1;
                },
                '?' => {
                    p.pos += 1;
                    max = 1;
                },
                '{' => {
                    const save = p.pos;
                    if (!try p.parseBraces(&min, &max)) {
                        // Not a valid quantifier: `{` is a literal.
                        p.pos = save;
                        return node;
                    }
                },
                else => return node,
            }
            switch (node) {
                .empty, .bol, .eol => return p.fail("nothing to repeat"),
                else => {},
            }
            if (p.peek() == '?') p.pos += 1; // lazy: same result for a yes/no search
            const inner = try p.a.create(Node);
            inner.* = node;
            node = .{ .repeat = .{ .node = inner, .min = min, .max = max } };
        }
        return node;
    }

    /// `{n}`, `{n,}` or `{n,m}`. Returns false if the text is not one.
    fn parseBraces(p: *Parser, min: *u32, max: *?u32) Error!bool {
        p.pos += 1;
        const lo = p.parseNumber() orelse return false;
        var hi: ?u32 = lo;
        if (p.peek() == ',') {
            p.pos += 1;
            hi = p.parseNumber();
        }
        if (p.peek() != '}') return false;
        p.pos += 1;
        if (lo > max_repeat or (hi != null and hi.? > max_repeat)) return p.fail("repeat count too large (max 1000)");
        if (hi != null and hi.? < lo) return p.fail("bad repeat range");
        min.* = lo;
        max.* = hi;
        return true;
    }

    fn parseNumber(p: *Parser) ?u32 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            p.pos += 1;
        }
        if (p.pos == start) return null;
        return std.fmt.parseInt(u32, p.src[start..p.pos], 10) catch max_repeat + 1;
    }

    fn parseAtom(p: *Parser) Error!Node {
        const c = p.peek().?;
        switch (c) {
            '(' => {
                p.pos += 1;
                if (std.mem.startsWith(u8, p.src[p.pos..], "?:")) p.pos += 2;
                p.depth += 1;
                if (p.depth > 200) return p.fail("groups nested too deeply");
                const inner = try p.parseAlt();
                p.depth -= 1;
                if (p.peek() != ')') return p.fail("missing ')'");
                p.pos += 1;
                return inner;
            },
            '[' => return p.parseClass(),
            '.' => {
                p.pos += 1;
                return .any;
            },
            '^' => {
                p.pos += 1;
                return .bol;
            },
            '$' => {
                p.pos += 1;
                return .eol;
            },
            '*', '+', '?' => return p.fail("nothing to repeat"),
            '\\' => {
                p.pos += 1;
                if (p.peek() == null) return p.fail("trailing backslash");
                if (try p.classEscape(false)) |cl| return .{ .class = cl };
                return .{ .char = try p.escapedChar() };
            },
            else => return .{ .char = p.nextCodepoint() },
        }
    }

    /// After a backslash: `\d \w \s` and, outside classes, `\D \W \S`.
    fn classEscape(p: *Parser, in_class: bool) Error!?Class {
        const c = p.peek().?;
        const ranges: []const Range = switch (std.ascii.toLower(c)) {
            'd' => &digit,
            'w' => &word,
            's' => &space,
            else => return null,
        };
        const negated = std.ascii.isUpper(c);
        if (negated and in_class) return p.fail("\\D, \\W and \\S are not supported inside [...]");
        p.pos += 1;
        return .{ .ranges = ranges, .negated = negated };
    }

    fn escapedChar(p: *Parser) Error!u21 {
        const c = p.peek().?;
        if (std.ascii.isAlphanumeric(c)) {
            p.pos += 1;
            return switch (c) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                else => p.fail("unsupported escape"),
            };
        }
        return p.nextCodepoint();
    }

    fn parseClass(p: *Parser) Error!Node {
        p.pos += 1;
        var negated = false;
        if (p.peek() == '^') {
            negated = true;
            p.pos += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail("missing ']'");
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            var lo: u21 = undefined;
            if (c == '\\') {
                p.pos += 1;
                if (p.peek() == null) return p.fail("trailing backslash");
                if (try p.classEscape(true)) |cl| {
                    try ranges.appendSlice(p.a, cl.ranges);
                    continue;
                }
                lo = try p.escapedChar();
            } else {
                lo = p.nextCodepoint();
            }
            var hi = lo;
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.pos += 1;
                if (p.peek() == '\\') {
                    p.pos += 1;
                    if (p.peek() == null) return p.fail("trailing backslash");
                    hi = try p.escapedChar();
                } else {
                    hi = p.nextCodepoint();
                }
                if (hi < lo) return p.fail("bad range in [...]");
            }
            try ranges.append(p.a, .{ .lo = lo, .hi = hi });
        }
        return .{ .class = .{ .ranges = ranges.items, .negated = negated } };
    }
};

const digit = [_]Range{.{ .lo = '0', .hi = '9' }};
const word = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const space = [_]Range{ .{ .lo = '\t', .hi = '\r' }, .{ .lo = ' ', .hi = ' ' } };

const Compiler = struct {
    a: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    diag: *Diagnostic,

    fn emit(c: *Compiler, inst: Inst) Error!u32 {
        if (c.prog.items.len >= max_program) {
            c.diag.set("pattern too large", .{});
            return error.BadRegex;
        }
        try c.prog.append(c.a, inst);
        return @intCast(c.prog.items.len - 1);
    }

    fn pc(c: *Compiler) u32 {
        return @intCast(c.prog.items.len);
    }

    fn emitNode(c: *Compiler, node: Node) Error!void {
        switch (node) {
            .empty => {},
            .char => |x| _ = try c.emit(.{ .char = x }),
            .any => _ = try c.emit(.any),
            .class => |cl| _ = try c.emit(.{ .class = cl }),
            .bol => _ = try c.emit(.bol),
            .eol => _ = try c.emit(.eol),
            .cat => |items| for (items) |n| try c.emitNode(n),
            .alt => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                for (branches, 0..) |b, i| {
                    if (i + 1 == branches.len) {
                        try c.emitNode(b);
                        break;
                    }
                    const split = try c.emit(.{ .split = .{ 0, 0 } });
                    try c.emitNode(b);
                    try jumps.append(c.a, try c.emit(.{ .jmp = 0 }));
                    c.prog.items[split] = .{ .split = .{ split + 1, c.pc() } };
                }
                for (jumps.items) |j| c.prog.items[j] = .{ .jmp = c.pc() };
            },
            .repeat => |r| {
                for (0..r.min) |_| try c.emitNode(r.node.*);
                if (r.max) |max| {
                    // Optional copies: each may be skipped to the end.
                    var splits: std.ArrayList(u32) = .empty;
                    for (r.min..max) |_| {
                        try splits.append(c.a, try c.emit(.{ .split = .{ 0, 0 } }));
                        try c.emitNode(r.node.*);
                    }
                    for (splits.items) |s| c.prog.items[s] = .{ .split = .{ s + 1, c.pc() } };
                } else {
                    const loop = try c.emit(.{ .split = .{ 0, 0 } });
                    try c.emitNode(r.node.*);
                    _ = try c.emit(.{ .jmp = loop });
                    c.prog.items[loop] = .{ .split = .{ loop + 1, c.pc() } };
                }
            },
        }
    }
};

// ======================================================================
// Tests

const testing = std.testing;

fn expectMatch(pattern: []const u8, text: []const u8, expected: bool) !void {
    var diag: Diagnostic = .{};
    var re = try Regex.compile(testing.allocator, pattern, &diag);
    defer re.deinit();
    if (try re.search(testing.allocator, text) != expected) {
        std.debug.print("pattern {s} on '{s}': expected {}\n", .{ pattern, text, expected });
        return error.TestUnexpectedResult;
    }
}

fn expectBad(pattern: []const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadRegex, Regex.compile(testing.allocator, pattern, &diag));
    try testing.expect(diag.message().len > 0);
}

test "literals, dot and anchors" {
    try expectMatch("abc", "xxabcxx", true);
    try expectMatch("abd", "xxabcxx", false);
    try expectMatch("a.c", "abc", true);
    try expectMatch("a.c", "ac", false);
    try expectMatch("^abc", "abcd", true);
    try expectMatch("^bcd", "abcd", false);
    try expectMatch("cd$", "abcd", true);
    try expectMatch("bc$", "abcd", false);
    try expectMatch("^$", "", true);
    try expectMatch("", "anything", true);
    try expectMatch("\\$ $", "user@host:~$ ", true);
    try expectMatch("a\\.b", "a.b", true);
    try expectMatch("a\\.b", "axb", false);
}

test "classes and escapes" {
    try expectMatch("[abc]x", "bx", true);
    try expectMatch("[^abc]x", "bx", false);
    try expectMatch("[^abc]x", "dx", true);
    try expectMatch("[0-9]+%", "progress 42%", true);
    try expectMatch("\\d+%", "progress 42%", true);
    try expectMatch("\\d+%", "progress %", false);
    try expectMatch("^\\w+:", "error: boom", true);
    try expectMatch("\\s\\S", "a b", true);
    try expectMatch("[\\d.]+", "v1.2", true);
    try expectMatch("[]a]", "]", true);
    try expectMatch("[a-]", "-", true);
    try expectMatch("\\D", "123", false);
}

test "groups, alternation and quantifiers" {
    try expectMatch("cat|dog", "hotdog", true);
    try expectMatch("^(cat|dog)$", "dog", true);
    try expectMatch("^(cat|dog)$", "dogs", false);
    try expectMatch("(?:ab)+c", "ababc", true);
    try expectMatch("^(ab)+c", "abac", false);
    try expectMatch("colou?r", "color", true);
    try expectMatch("colou?r", "colour", true);
    try expectMatch("^a{3}$", "aaa", true);
    try expectMatch("^a{3}$", "aa", false);
    try expectMatch("^a{2,}$", "aaaa", true);
    try expectMatch("^a{2,3}$", "aaaa", false);
    try expectMatch("^a{2,3}$", "aa", true);
    try expectMatch("x{", "x{", true);
    try expectMatch("a.*?b", "a123b", true);
    try expectMatch("(a|)+b", "aab", true);
}

test "case-insensitive and UTF-8" {
    try expectMatch("(?i)error", "ERROR: x", true);
    try expectMatch("error", "ERROR: x", false);
    try expectMatch("(?i)[a-z]+ ok", "ALL OK", true);
    try expectMatch("^.$", "中", true);
    try expectMatch("^..$", "中", false);
    try expectMatch("[中文]+", "文", true);
}

test "pathological patterns stay fast" {
    var buf: [3000]u8 = undefined;
    @memset(&buf, 'a');
    try expectMatch("(a*)*b", &buf, false);
    try expectMatch("(a|a)*(a|a)*(a|a)*c", &buf, false);
    try expectMatch("^(a+)+$", &buf, true);
}

test "bad patterns are rejected with a message" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadRegex, Regex.compile(testing.allocator, "ab(c", &diag));
    try testing.expectEqualStrings("missing ')' at offset 4", diag.message());
    try expectBad("(abc");
    try expectBad("abc)");
    try expectBad("[abc");
    try expectBad("*a");
    try expectBad("a{5,2}");
    try expectBad("a{2000}");
    try expectBad("[z-a]");
    try expectBad("\\q");
    try expectBad("[\\W]");
    try expectBad("(a{1000}){1000}");
}

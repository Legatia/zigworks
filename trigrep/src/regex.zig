//! A small line-oriented regex engine: parser, Thompson-NFA compiler and Pike VM.
//!
//! Matching is byte-based, but classes are Unicode-aware: a class is an ASCII bitset
//! plus non-ASCII code point ranges, compiled to UTF-8 byte sequences. \w, \d, \s and
//! \b use Unicode tables (src/unicode_tables.zig). Case folding is Unicode for
//! non-ASCII letters and ASCII-only for ASCII letters (so `k` doesn't match the Kelvin
//! sign; that keeps -i searches on the fast literal path). No captures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode_tables.zig");

pub const Error = error{ OutOfMemory, BadPattern, Unsupported, TooBig };

pub const ByteSet = std.StaticBitSet(256);

pub const Range = [2]u21;

/// Matches one character: an ASCII byte from `bytes` (only bits 0-127 are used) or a
/// non-ASCII code point in one of `ranges` (sorted, disjoint, all >= 0x80).
pub const Set = struct {
    bytes: ByteSet,
    ranges: []const Range = &.{},
};

const all_non_ascii = [_]Range{.{ 0x80, 0x10FFFF }};

fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid][0]) hi = mid else if (cp > ranges[mid][1]) lo = mid + 1 else return true;
    }
    return false;
}

/// Sorts and merges `list` in place; returns the normalized slice.
fn normalize(list: []Range) []Range {
    if (list.len == 0) return list;
    std.mem.sort(Range, list, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a[0] < b[0];
        }
    }.lt);
    var n: usize = 0;
    for (list) |r| {
        if (n > 0 and r[0] <= list[n - 1][1] +| 1) {
            list[n - 1][1] = @max(list[n - 1][1], r[1]);
        } else {
            list[n] = r;
            n += 1;
        }
    }
    return list[0..n];
}

/// Non-ASCII code points not in `ranges` (which must be normalized).
fn complement(arena: Allocator, ranges: []const Range) ![]const Range {
    var out: std.ArrayList(Range) = .empty;
    var next: u21 = 0x80;
    for (ranges) |r| {
        if (r[0] > next) try out.append(arena, .{ next, r[0] - 1 });
        next = r[1] +| 1;
    }
    if (next <= 0x10FFFF) try out.append(arena, .{ next, 0x10FFFF });
    return out.items;
}

/// Code points that are case variants of `cp` (non-ASCII only; empty for most).
fn foldVariants(cp: u21) []const Range {
    // The table is sorted by its first column.
    var lo: usize = 0;
    var hi: usize = unicode.fold.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (unicode.fold[mid][0] < cp) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < unicode.fold.len and unicode.fold[end][0] == cp) end += 1;
    return unicode.fold[lo..end];
}

pub fn isWordChar(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return inRanges(cp, &unicode.word);
}

pub const Repeat = struct { node: *const Node, min: u32, max: ?u32, lazy: bool = false };

pub const Node = union(enum) {
    empty,
    byte: u8,
    set: Set,
    concat: []const Node,
    alt: []const Node,
    repeat: Repeat,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
};

pub const Options = struct {
    ignore_case: bool = false,
    fixed_string: bool = false,
    word: bool = false,
};

const max_repeat = 1000;
const max_insts = 200_000;

fn isSpaceByte(b: u8) bool {
    return b == ' ' or (b >= '\t' and b <= '\r');
}

// ---------------------------------------------------------------------------
// Parser

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    fold: bool,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn peekAt(p: *Parser, off: usize) ?u8 {
        return if (p.pos + off < p.src.len) p.src[p.pos + off] else null;
    }

    fn parseAlt(p: *Parser) Error!Node {
        var alts: std.ArrayList(Node) = .empty;
        try alts.append(p.arena, try p.parseConcat());
        while (p.peek() == '|') {
            p.pos += 1;
            try alts.append(p.arena, try p.parseConcat());
        }
        if (alts.items.len == 1) return alts.items[0];
        return .{ .alt = alts.items };
    }

    fn parseConcat(p: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = (try p.parseAtom()) orelse continue;
            try items.append(p.arena, try p.parseQuantifiers(atom));
        }
        return switch (items.items.len) {
            0 => .empty,
            1 => items.items[0],
            else => .{ .concat = items.items },
        };
    }

    fn parseQuantifiers(p: *Parser, first: Node) Error!Node {
        var atom = first;
        while (p.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => p.pos += 1,
                '+' => {
                    min = 1;
                    p.pos += 1;
                },
                '?' => {
                    max = 1;
                    p.pos += 1;
                },
                '{' => {
                    const b = p.parseBraces() orelse break;
                    min = b.min;
                    max = b.max;
                },
                else => break,
            }
            // `?` makes it lazy (prefers fewer repetitions; only matters for match
            // positions). A possessive `+` is treated as greedy.
            var lazy = false;
            if (p.peek() == '?') {
                lazy = true;
                p.pos += 1;
            } else if (p.peek() == '+') p.pos += 1;
            if (min > max_repeat or (max != null and max.? > max_repeat)) return error.TooBig;
            if (max != null and max.? < min) return error.BadPattern;
            const boxed = try p.arena.create(Node);
            boxed.* = atom;
            atom = .{ .repeat = .{ .node = boxed, .min = min, .max = max, .lazy = lazy } };
        }
        return atom;
    }

    const Braces = struct { min: u32, max: ?u32 };

    /// `{n}`, `{n,}` or `{n,m}`. Anything else is a literal `{`.
    fn parseBraces(p: *Parser) ?Braces {
        const start = p.pos;
        p.pos += 1;
        const min = p.parseInt() orelse {
            p.pos = start;
            return null;
        };
        var max: ?u32 = min;
        if (p.peek() == ',') {
            p.pos += 1;
            max = p.parseInt();
        }
        if (p.peek() != '}') {
            p.pos = start;
            return null;
        }
        p.pos += 1;
        return .{ .min = min, .max = max };
    }

    fn parseInt(p: *Parser) ?u32 {
        var n: u32 = 0;
        var any = false;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            n = n *| 10 +| (c - '0');
            any = true;
            p.pos += 1;
        }
        return if (any) n else null;
    }

    /// Returns null for a flag group like `(?i)`, which only changes parser state.
    fn parseAtom(p: *Parser) Error!?Node {
        const c = p.src[p.pos];
        switch (c) {
            '(' => {
                p.pos += 1;
                if (p.peek() != '?') return try p.groupBody(p.fold);
                p.pos += 1;
                if (p.peek() == 'P') p.pos += 1;
                if (p.peek() == '<') {
                    p.pos += 1;
                    if (p.peek() == '=' or p.peek() == '!') return error.Unsupported;
                    const close = std.mem.indexOfScalarPos(u8, p.src, p.pos, '>') orelse return error.BadPattern;
                    p.pos = close + 1;
                    return try p.groupBody(p.fold);
                }
                if (p.peek() == '=' or p.peek() == '!') return error.Unsupported;
                var fold = p.fold;
                var on = true;
                while (p.peek()) |f| {
                    switch (f) {
                        'i' => fold = on,
                        '-' => on = false,
                        // Multi-line and dot-all don't matter for single lines; verbose does.
                        'm', 's', 'U', 'u' => {},
                        ':', ')' => break,
                        else => return error.Unsupported,
                    }
                    p.pos += 1;
                }
                const f = p.peek() orelse return error.BadPattern;
                p.pos += 1;
                if (f == ')') {
                    p.fold = fold;
                    return null;
                }
                return try p.groupBody(fold);
            },
            '[' => return try p.parseClass(),
            '.' => {
                p.pos += 1;
                return .{ .set = dotSet() };
            },
            '^' => {
                p.pos += 1;
                return .bol;
            },
            '$' => {
                p.pos += 1;
                return .eol;
            },
            '\\' => return try p.parseEscape(),
            '*', '+', '?' => return error.BadPattern,
            else => return try p.literalChar(),
        }
    }

    fn groupBody(p: *Parser, fold: bool) Error!Node {
        const saved = p.fold;
        p.fold = fold;
        const inner = try p.parseAlt();
        p.fold = saved;
        if (p.peek() != ')') return error.BadPattern;
        p.pos += 1;
        return inner;
    }

    fn lit(p: *Parser, c: u8) Node {
        if (p.fold and std.ascii.isAlphabetic(c)) {
            var s = Set{ .bytes = ByteSet.initEmpty() };
            s.bytes.set(std.ascii.toLower(c));
            s.bytes.set(std.ascii.toUpper(c));
            return .{ .set = s };
        }
        return .{ .byte = c };
    }

    fn literalChar(p: *Parser) Error!Node {
        const c = p.src[p.pos];
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (len == 1 or p.pos + len > p.src.len) {
            p.pos += 1;
            return p.lit(c);
        }
        const bytes = p.src[p.pos..][0..len];
        p.pos += len;
        if (p.fold) {
            if (std.unicode.utf8Decode(bytes)) |cp| {
                const variants = foldVariants(cp);
                if (variants.len > 0) {
                    var list: std.ArrayList(Range) = .empty;
                    try list.append(p.arena, .{ cp, cp });
                    for (variants) |v| if (v[1] >= 0x80) try list.append(p.arena, .{ v[1], v[1] });
                    var s = Set{ .bytes = ByteSet.initEmpty(), .ranges = normalize(list.items) };
                    // A non-ASCII letter whose variant is ASCII (e.g. U+212A Kelvin -> k).
                    for (variants) |v| if (v[1] < 0x80) s.bytes.set(v[1]);
                    return .{ .set = s };
                }
            } else |_| {}
        }
        const items = try p.arena.alloc(Node, len);
        for (bytes, 0..) |b, i| items[i] = .{ .byte = b };
        return .{ .concat = items };
    }

    fn parseEscape(p: *Parser) Error!Node {
        p.pos += 1;
        const c = p.peek() orelse return error.BadPattern;
        p.pos += 1;
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => return .{ .set = try classEscape(p.arena, c) },
            'b' => return .word_boundary,
            'B' => return .not_word_boundary,
            'A' => return .bol,
            'z' => return .eol,
            else => return p.lit(try p.escapeByte(c)),
        }
    }

    fn escapeByte(p: *Parser, c: u8) Error!u8 {
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            '0' => 0,
            'x' => {
                if (p.pos + 2 > p.src.len) return error.BadPattern;
                const v = std.fmt.parseInt(u8, p.src[p.pos..][0..2], 16) catch return error.Unsupported;
                p.pos += 2;
                return v;
            },
            else => if (std.ascii.isAlphanumeric(c)) error.Unsupported else c,
        };
    }

    fn classChar(p: *Parser) u21 {
        const c = p.src[p.pos];
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (len > 1 and p.pos + len <= p.src.len) {
            if (std.unicode.utf8Decode(p.src[p.pos..][0..len])) |cp| {
                p.pos += len;
                return cp;
            } else |_| {}
        }
        p.pos += 1;
        return c;
    }

    fn addByte(p: *Parser, s: *Set, b: u8) void {
        s.bytes.set(b);
        if (p.fold and std.ascii.isAlphabetic(b)) {
            s.bytes.set(std.ascii.toLower(b));
            s.bytes.set(std.ascii.toUpper(b));
        }
    }

    fn parseClass(p: *Parser) Error!Node {
        p.pos += 1;
        var negate = false;
        if (p.peek() == '^') {
            negate = true;
            p.pos += 1;
        }
        var bytes = ByteSet.initEmpty();
        var ranges: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            const c = p.peek() orelse return error.BadPattern;
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            if (c == '[' and p.peekAt(1) == ':') {
                const end = std.mem.indexOfPos(u8, p.src, p.pos + 2, ":]") orelse return error.BadPattern;
                bytes.setUnion(try posixClass(p.src[p.pos + 2 .. end]));
                p.pos = end + 2;
                continue;
            }
            var lo: u21 = undefined;
            if (c == '\\') {
                p.pos += 1;
                const e = p.peek() orelse return error.BadPattern;
                p.pos += 1;
                switch (e) {
                    'd', 'D', 'w', 'W', 's', 'S' => {
                        const cs = try classEscape(p.arena, e);
                        bytes.setUnion(cs.bytes);
                        try ranges.appendSlice(p.arena, cs.ranges);
                        continue;
                    },
                    else => lo = try p.escapeByte(e),
                }
            } else lo = p.classChar();
            var hi = lo;
            if (p.peek() == '-' and p.peekAt(1) != null and p.peekAt(1) != ']') {
                p.pos += 1;
                if (p.peek() == '\\') {
                    p.pos += 1;
                    const e = p.peek() orelse return error.BadPattern;
                    p.pos += 1;
                    hi = try p.escapeByte(e);
                } else hi = p.classChar();
                if (hi < lo) return error.BadPattern;
            }
            var x = lo;
            while (x <= @min(hi, 0x7F)) : (x += 1) {
                bytes.set(x);
                if (p.fold and std.ascii.isAlphabetic(@intCast(x))) {
                    bytes.set(std.ascii.toLower(@intCast(x)));
                    bytes.set(std.ascii.toUpper(@intCast(x)));
                }
            }
            if (hi >= 0x80) {
                const r = Range{ @max(lo, 0x80), hi };
                try ranges.append(p.arena, r);
                if (p.fold) {
                    // Add case variants of every non-ASCII letter in the range.
                    for (unicode.fold) |f| {
                        if (f[0] >= r[0] and f[0] <= r[1]) {
                            if (f[1] >= 0x80) try ranges.append(p.arena, .{ f[1], f[1] }) else bytes.set(f[1]);
                        }
                    }
                }
            }
        }
        const norm = normalize(ranges.items);
        if (negate) {
            var neg = ByteSet.initEmpty();
            for (0..0x80) |i| {
                if (!bytes.isSet(i)) neg.set(i);
            }
            neg.unset('\n');
            return .{ .set = .{ .bytes = neg, .ranges = try complement(p.arena, norm) } };
        }
        return .{ .set = .{ .bytes = bytes, .ranges = norm } };
    }
};

fn dotSet() Set {
    var s = Set{ .bytes = ByteSet.initEmpty(), .ranges = &all_non_ascii };
    for (0..0x80) |i| s.bytes.set(i);
    s.bytes.unset('\n');
    return s;
}

/// \d \w \s (Unicode) and their negations.
fn classEscape(arena: Allocator, c: u8) Error!Set {
    var s = Set{ .bytes = ByteSet.initEmpty() };
    const kind = std.ascii.toLower(c);
    for (0..0x80) |i| {
        const b: u8 = @intCast(i);
        const in = switch (kind) {
            'd' => std.ascii.isDigit(b),
            'w' => std.ascii.isAlphanumeric(b) or b == '_',
            's' => isSpaceByte(b),
            else => unreachable,
        };
        if (in) s.bytes.set(b);
    }
    s.ranges = switch (kind) {
        'd' => &unicode.digit,
        'w' => &unicode.word,
        's' => &unicode.space,
        else => unreachable,
    };
    if (std.ascii.isUpper(c)) {
        var neg = ByteSet.initEmpty();
        for (0..0x80) |i| {
            if (!s.bytes.isSet(i)) neg.set(i);
        }
        return .{ .bytes = neg, .ranges = try complement(arena, s.ranges) };
    }
    return s;
}

fn posixClass(name: []const u8) Error!ByteSet {
    var s = ByteSet.initEmpty();
    for (0..0x80) |i| {
        const b: u8 = @intCast(i);
        const in = if (std.mem.eql(u8, name, "alpha")) std.ascii.isAlphabetic(b)
            else if (std.mem.eql(u8, name, "digit")) std.ascii.isDigit(b)
            else if (std.mem.eql(u8, name, "alnum")) std.ascii.isAlphanumeric(b)
            else if (std.mem.eql(u8, name, "upper")) std.ascii.isUpper(b)
            else if (std.mem.eql(u8, name, "lower")) std.ascii.isLower(b)
            else if (std.mem.eql(u8, name, "space")) isSpaceByte(b)
            else if (std.mem.eql(u8, name, "blank")) (b == ' ' or b == '\t')
            else if (std.mem.eql(u8, name, "punct")) (std.ascii.isPrint(b) and !std.ascii.isAlphanumeric(b) and b != ' ')
            else if (std.mem.eql(u8, name, "xdigit")) std.ascii.isHex(b)
            else if (std.mem.eql(u8, name, "word")) (std.ascii.isAlphanumeric(b) or b == '_')
            else if (std.mem.eql(u8, name, "cntrl")) std.ascii.isControl(b)
            else if (std.mem.eql(u8, name, "print")) std.ascii.isPrint(b)
            else if (std.mem.eql(u8, name, "graph")) (std.ascii.isPrint(b) and b != ' ')
            else return error.BadPattern;
        if (in) s.set(b);
    }
    return s;
}

/// Parses `pattern` into an AST allocated in `arena`.
pub fn parse(arena: Allocator, pattern: []const u8, opts: Options) Error!Node {
    var p = Parser{ .arena = arena, .src = pattern, .fold = opts.ignore_case };
    var root: Node = undefined;
    if (opts.fixed_string) {
        var items: std.ArrayList(Node) = .empty;
        for (pattern) |b| try items.append(arena, p.lit(b));
        root = .{ .concat = items.items };
    } else {
        root = try p.parseAlt();
        if (p.pos != pattern.len) return error.BadPattern;
    }
    if (opts.word) {
        const items = try arena.alloc(Node, 3);
        items[0] = .word_boundary;
        items[1] = root;
        items[2] = .word_boundary;
        root = .{ .concat = items };
    }
    return root;
}

// ---------------------------------------------------------------------------
// Compiler

pub const Inst = union(enum) {
    byte: u8,
    set: u32,
    split: [2]u32,
    jmp: u32,
    match,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
};

pub const Program = struct {
    insts: []const Inst,
    sets: []const ByteSet,
    anchored_start: bool,
};

const Compiler = struct {
    arena: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    sets: std.ArrayList(ByteSet) = .empty,

    fn len(c: *Compiler) u32 {
        return @intCast(c.insts.items.len);
    }

    fn emit(c: *Compiler, inst: Inst) Error!u32 {
        if (c.insts.items.len >= max_insts) return error.TooBig;
        const at = c.len();
        try c.insts.append(c.arena, inst);
        return at;
    }

    fn compile(c: *Compiler, n: Node) Error!void {
        switch (n) {
            .empty => {},
            .byte => |b| _ = try c.emit(.{ .byte = b }),
            .set => |s| try c.compileSet(s),
            .concat => |items| for (items) |it| try c.compile(it),
            .alt => |items| {
                var jumps: std.ArrayList(u32) = .empty;
                for (items, 0..) |it, i| {
                    if (i + 1 < items.len) {
                        const sp = try c.emit(.{ .split = .{ 0, 0 } });
                        try c.compile(it);
                        try jumps.append(c.arena, try c.emit(.{ .jmp = 0 }));
                        c.insts.items[sp] = .{ .split = .{ sp + 1, c.len() } };
                    } else try c.compile(it);
                }
                for (jumps.items) |j| c.insts.items[j] = .{ .jmp = c.len() };
            },
            .repeat => |r| {
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try c.compile(r.node.*);
                if (r.max) |max| {
                    var splits: std.ArrayList(u32) = .empty;
                    var k = r.min;
                    while (k < max) : (k += 1) {
                        const sp = try c.emit(.{ .split = .{ 0, 0 } });
                        try splits.append(c.arena, sp);
                        try c.compile(r.node.*);
                    }
                    for (splits.items) |sp| c.insts.items[sp] = .{ .split = order(r.lazy, sp + 1, c.len()) };
                } else {
                    const sp = try c.emit(.{ .split = .{ 0, 0 } });
                    try c.compile(r.node.*);
                    _ = try c.emit(.{ .jmp = sp });
                    c.insts.items[sp] = .{ .split = order(r.lazy, sp + 1, c.len()) };
                }
            },
            .bol => _ = try c.emit(.bol),
            .eol => _ = try c.emit(.eol),
            .word_boundary => _ = try c.emit(.word_boundary),
            .not_word_boundary => _ = try c.emit(.not_word_boundary),
        }
    }

    /// A split preferring `body` (greedy) or `skip` (lazy).
    fn order(lazy: bool, body: u32, skip: u32) [2]u32 {
        return if (lazy) .{ skip, body } else .{ body, skip };
    }

    fn emitRange(c: *Compiler, lo: u8, hi: u8) Error!void {
        if (lo == hi) {
            _ = try c.emit(.{ .byte = lo });
            return;
        }
        var bs = ByteSet.initEmpty();
        bs.setRangeValue(.{ .start = lo, .end = @as(usize, hi) + 1 }, true);
        const idx: u32 = @intCast(c.sets.items.len);
        try c.sets.append(c.arena, bs);
        _ = try c.emit(.{ .set = idx });
    }

    fn compileSet(c: *Compiler, s: Set) Error!void {
        const n_ascii = s.bytes.count();
        if (s.ranges.len == 0) {
            if (n_ascii == 1) {
                _ = try c.emit(.{ .byte = @intCast(s.bytes.findFirstSet().?) });
            } else {
                const idx: u32 = @intCast(c.sets.items.len);
                try c.sets.append(c.arena, s.bytes);
                _ = try c.emit(.{ .set = idx });
            }
            return;
        }
        // Non-ASCII ranges become UTF-8 byte sequences, merged into a trie so that
        // sequences with the same leading bytes share instructions.
        var trie = Trie{};
        for (s.ranges) |r| try utf8Sequences(c.arena, r[0], r[1], &trie);
        var jumps: std.ArrayList(u32) = .empty;
        var branches: usize = trie.children.items.len;
        if (n_ascii > 0) branches += 1;
        var done: usize = 0;
        if (n_ascii > 0) {
            done += 1;
            const sp = if (done < branches) try c.emit(.{ .split = .{ 0, 0 } }) else null;
            const idx: u32 = @intCast(c.sets.items.len);
            try c.sets.append(c.arena, s.bytes);
            _ = try c.emit(.{ .set = idx });
            try jumps.append(c.arena, try c.emit(.{ .jmp = 0 }));
            if (sp) |x| c.insts.items[x] = .{ .split = .{ x + 1, c.len() } };
        }
        try c.compileTrie(&trie, &jumps, done);
        for (jumps.items) |j| c.insts.items[j] = .{ .jmp = c.len() };
    }

    fn compileTrie(c: *Compiler, t: *const Trie, jumps: *std.ArrayList(u32), already: usize) Error!void {
        _ = already;
        const kids = t.children.items;
        for (kids, 0..) |k, i| {
            const sp = if (i + 1 < kids.len) try c.emit(.{ .split = .{ 0, 0 } }) else null;
            try c.emitRange(k.lo, k.hi);
            if (k.child.children.items.len == 0) {
                try jumps.append(c.arena, try c.emit(.{ .jmp = 0 }));
            } else {
                var inner: std.ArrayList(u32) = .empty;
                try c.compileTrie(k.child, &inner, 0);
                for (inner.items) |j| try jumps.append(c.arena, j);
            }
            if (sp) |x| c.insts.items[x] = .{ .split = .{ x + 1, c.len() } };
        }
    }
};

const Trie = struct {
    children: std.ArrayList(Edge) = .empty,
    const Edge = struct { lo: u8, hi: u8, child: *Trie };

    fn insert(t: *Trie, arena: Allocator, seq: []const [2]u8) !void {
        if (seq.len == 0) return;
        for (t.children.items) |e| {
            if (e.lo == seq[0][0] and e.hi == seq[0][1]) return e.child.insert(arena, seq[1..]);
        }
        const child = try arena.create(Trie);
        child.* = .{};
        try t.children.append(arena, .{ .lo = seq[0][0], .hi = seq[0][1], .child = child });
        try child.insert(arena, seq[1..]);
    }
};

/// Splits [lo, hi] into ranges whose UTF-8 encodings differ only in byte ranges
/// (the utf8-ranges algorithm) and inserts each byte-range sequence into `trie`.
fn utf8Sequences(arena: Allocator, lo: u21, hi: u21, trie: *Trie) !void {
    if (lo > hi) return;
    if (lo <= 0xDFFF and hi >= 0xD800) {
        if (lo < 0xD800) try utf8Sequences(arena, lo, 0xD7FF, trie);
        if (hi > 0xDFFF) try utf8Sequences(arena, 0xE000, hi, trie);
        return;
    }
    for ([_]u21{ 0x7F, 0x7FF, 0xFFFF }) |b| {
        if (lo <= b and hi > b) {
            try utf8Sequences(arena, lo, b, trie);
            try utf8Sequences(arena, b + 1, hi, trie);
            return;
        }
    }
    if (hi <= 0x7F) {
        try trie.insert(arena, &.{.{ @intCast(lo), @intCast(hi) }});
        return;
    }
    const n: u3 = std.unicode.utf8CodepointSequenceLength(lo) catch unreachable;
    var i: u5 = 1;
    while (i < n) : (i += 1) {
        const m: u21 = (@as(u21, 1) << (6 * i)) - 1;
        if ((lo & ~m) != (hi & ~m)) {
            if ((lo & m) != 0) {
                try utf8Sequences(arena, lo, lo | m, trie);
                try utf8Sequences(arena, (lo | m) + 1, hi, trie);
                return;
            }
            if ((hi & m) != m) {
                try utf8Sequences(arena, lo, (hi & ~m) - 1, trie);
                try utf8Sequences(arena, hi & ~m, hi, trie);
                return;
            }
        }
    }
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    _ = std.unicode.utf8Encode(lo, &a) catch unreachable;
    _ = std.unicode.utf8Encode(hi, &b) catch unreachable;
    var seq: [4][2]u8 = undefined;
    for (0..n) |k| seq[k] = .{ a[k], b[k] };
    try trie.insert(arena, seq[0..n]);
}

fn startsWithBol(n: Node) bool {
    return switch (n) {
        .bol => true,
        .concat => |items| items.len > 0 and startsWithBol(items[0]),
        else => false,
    };
}

pub fn compile(arena: Allocator, root: Node) Error!Program {
    var c = Compiler{ .arena = arena };
    try c.compile(root);
    _ = try c.emit(.match);
    return .{ .insts = c.insts.items, .sets = c.sets.items, .anchored_start = startsWithBol(root) };
}

// ---------------------------------------------------------------------------
// Pike VM

const ThreadList = struct {
    dense: []u32,
    sparse: []u32,
    len: u32 = 0,

    fn contains(l: *const ThreadList, pc: u32) bool {
        const i = l.sparse[pc];
        return i < l.len and l.dense[i] == pc;
    }

    fn insert(l: *ThreadList, pc: u32) void {
        l.sparse[pc] = l.len;
        l.dense[l.len] = pc;
        l.len += 1;
    }
};

/// A lazily built DFA over the program: each state is the set of NFA instructions
/// alive after some input, transitions are computed on first use and cached. Doesn't
/// handle word boundaries (those depend on the next byte); Matcher falls back to the
/// Pike VM for them and when the cache fills up.
pub const Dfa = struct {
    gpa: Allocator,
    prog: *const Program,
    pcs: std.ArrayList(u32) = .empty,
    states: std.ArrayList(State) = .empty,
    trans: std.ArrayList(i32) = .empty,
    table: std.HashMapUnmanaged(u32, void, TableCtx, 80) = .empty,
    mark: []u32,
    gen: u32 = 0,
    stack: []u32,
    seeds: std.ArrayList(u32) = .empty,
    out: std.ArrayList(u32) = .empty,
    start: u32 = 0,
    /// Per state: bit 0 = contains `match`, bit 1 = dead (no threads). Kept next to
    /// the transitions so the hot loop doesn't touch `states`.
    flags: std.ArrayList(u8) = .empty,
    /// Where `nextMatchingLine` gave up with CacheFull: the start of that line.
    fail_line: usize = 0,

    const State = struct { off: u32, len: u32, match: bool, eol: enum { unknown, no, yes } = .unknown };
    const max_states = 4096;
    pub const DfaError = error{ CacheFull, OutOfMemory };

    const TableCtx = struct {
        d: *const Dfa,
        pub fn hash(c: TableCtx, id: u32) u64 {
            return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(c.d.statePcs(id)));
        }
        pub fn eql(_: TableCtx, a: u32, b: u32) bool {
            return a == b;
        }
    };

    const KeyCtx = struct {
        d: *const Dfa,
        pub fn hash(_: KeyCtx, key: []const u32) u64 {
            return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
        }
        pub fn eql(c: KeyCtx, key: []const u32, id: u32) bool {
            return std.mem.eql(u32, key, c.d.statePcs(id));
        }
    };

    pub fn supported(prog: *const Program) bool {
        for (prog.insts) |inst| switch (inst) {
            .word_boundary, .not_word_boundary => return false,
            else => {},
        };
        return true;
    }

    pub fn init(gpa: Allocator, prog: *const Program) !Dfa {
        const n = prog.insts.len;
        const mark = try gpa.alloc(u32, n);
        @memset(mark, 0);
        return .{ .gpa = gpa, .prog = prog, .mark = mark, .stack = try gpa.alloc(u32, 2 * n + 2) };
    }

    pub fn deinit(d: *Dfa) void {
        d.gpa.free(d.mark);
        d.gpa.free(d.stack);
        d.pcs.deinit(d.gpa);
        d.states.deinit(d.gpa);
        d.trans.deinit(d.gpa);
        d.table.deinit(d.gpa);
        d.flags.deinit(d.gpa);
        d.seeds.deinit(d.gpa);
        d.out.deinit(d.gpa);
    }

    /// Forgets every cached state and transition.
    pub fn reset(d: *Dfa) void {
        d.pcs.clearRetainingCapacity();
        d.states.clearRetainingCapacity();
        d.trans.clearRetainingCapacity();
        d.table.clearRetainingCapacity();
        d.flags.clearRetainingCapacity();
        d.start = 0;
    }

    fn statePcs(d: *const Dfa, id: u32) []const u32 {
        const s = d.states.items[id];
        return d.pcs.items[s.off..][0..s.len];
    }

    /// Follows epsilon edges from `seeds` into `d.out` (sorted). Keeps consuming
    /// instructions, `match`, and `eol` instructions that can't fire yet.
    fn closure(d: *Dfa, seeds: []const u32, at_start: bool, at_end: bool) !void {
        d.out.clearRetainingCapacity();
        d.gen +%= 1;
        if (d.gen == 0) {
            @memset(d.mark, 0);
            d.gen = 1;
        }
        var sp: usize = 0;
        for (seeds) |s| {
            d.stack[sp] = s;
            sp += 1;
            while (sp > 0) {
                sp -= 1;
                const pc = d.stack[sp];
                if (d.mark[pc] == d.gen) continue;
                d.mark[pc] = d.gen;
                switch (d.prog.insts[pc]) {
                    .byte, .set, .match => try d.out.append(d.gpa, pc),
                    .jmp => |t| {
                        d.stack[sp] = t;
                        sp += 1;
                    },
                    .split => |x| {
                        d.stack[sp] = x[1];
                        d.stack[sp + 1] = x[0];
                        sp += 2;
                    },
                    .bol => if (at_start) {
                        d.stack[sp] = pc + 1;
                        sp += 1;
                    },
                    .eol => if (at_end) {
                        d.stack[sp] = pc + 1;
                        sp += 1;
                    } else try d.out.append(d.gpa, pc),
                    .word_boundary, .not_word_boundary => unreachable,
                }
            }
        }
        std.mem.sort(u32, d.out.items, {}, std.sort.asc(u32));
    }

    fn intern(d: *Dfa) DfaError!u32 {
        const key = d.out.items;
        const gop = try d.table.getOrPutContextAdapted(d.gpa, key, KeyCtx{ .d = d }, TableCtx{ .d = d });
        if (gop.found_existing) return gop.key_ptr.*;
        if (d.states.items.len >= max_states) {
            d.table.removeByPtr(gop.key_ptr);
            return error.CacheFull;
        }
        const id: u32 = @intCast(d.states.items.len);
        var match = false;
        for (key) |pc| {
            if (d.prog.insts[pc] == .match) match = true;
        }
        const off: u32 = @intCast(d.pcs.items.len);
        try d.pcs.appendSlice(d.gpa, key);
        try d.states.append(d.gpa, .{ .off = off, .len = @intCast(key.len), .match = match });
        try d.trans.appendNTimes(d.gpa, -1, 256);
        try d.flags.append(d.gpa, @as(u8, @intFromBool(match)) | (@as(u8, @intFromBool(key.len == 0)) << 1));
        gop.key_ptr.* = id;
        return id;
    }

    fn startState(d: *Dfa) DfaError!u32 {
        if (d.states.items.len == 0) {
            try d.closure(&.{0}, true, false);
            d.start = try d.intern();
        }
        return d.start;
    }

    fn next(d: *Dfa, s: u32, b: u8) DfaError!u32 {
        const t = d.trans.items[@as(usize, s) * 256 + b];
        if (t >= 0) return @intCast(t);
        d.seeds.clearRetainingCapacity();
        for (d.statePcs(s)) |pc| {
            const ok = switch (d.prog.insts[pc]) {
                .byte => |x| x == b,
                .set => |si| d.prog.sets[si].isSet(b),
                else => false,
            };
            if (ok) try d.seeds.append(d.gpa, pc + 1);
        }
        if (!d.prog.anchored_start) try d.seeds.append(d.gpa, 0);
        try d.closure(d.seeds.items, false, false);
        const id = try d.intern();
        d.trans.items[@as(usize, s) * 256 + b] = @intCast(id);
        return id;
    }

    fn eolMatch(d: *Dfa, s: u32) DfaError!bool {
        switch (d.states.items[s].eol) {
            .yes => return true,
            .no => return false,
            .unknown => {},
        }
        d.seeds.clearRetainingCapacity();
        try d.seeds.appendSlice(d.gpa, d.statePcs(s));
        try d.closure(d.seeds.items, false, true);
        var hit = false;
        for (d.out.items) |pc| {
            if (d.prog.insts[pc] == .match) hit = true;
        }
        d.states.items[s].eol = if (hit) .yes else .no;
        return hit;
    }

    /// The start of the first line in `data[from..]` (`from` is a line start) that
    /// matches, scanning the whole buffer in one pass. `empty_matches` says whether an
    /// empty line matches (handled outside the DFA, since it's both start and end).
    pub fn nextMatchingLine(d: *Dfa, data: []const u8, from: usize, empty_matches: bool) DfaError!?usize {
        const start = try d.startState();
        var line_start = from;
        var s = start;
        var i = from;
        errdefer d.fail_line = line_start;
        if (d.flags.items[start] & 1 != 0) return if (from < data.len) from else null;
        var trans = d.trans.items;
        var flags = d.flags.items;
        while (i < data.len) : (i += 1) {
            const b = data[i];
            if (b == '\n') {
                if (i == line_start) {
                    if (empty_matches) return line_start;
                } else if (try d.eolMatch(s)) return line_start;
                line_start = i + 1;
                s = start;
                continue;
            }
            const t = trans[@as(usize, s) * 256 + b];
            if (t >= 0) {
                s = @intCast(t);
            } else {
                s = try d.next(s, b);
                trans = d.trans.items;
                flags = d.flags.items;
            }
            const f = flags[s];
            if (f == 0) continue;
            if (f & 1 != 0) return line_start;
            // Dead state: nothing on this line can match.
            const nl = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse return null;
            i = nl - 1;
        }
        if (line_start < data.len and try d.eolMatch(s)) return line_start;
        return null;
    }

    /// Like Matcher.isMatch, for non-empty lines.
    pub fn isMatch(d: *Dfa, line: []const u8) DfaError!bool {
        var s = try d.startState();
        if (d.flags.items[s] & 1 != 0) return true;
        var trans = d.trans.items;
        var flags = d.flags.items;
        for (line) |b| {
            const t = trans[@as(usize, s) * 256 + b];
            if (t >= 0) {
                s = @intCast(t);
            } else {
                s = try d.next(s, b);
                trans = d.trans.items;
                flags = d.flags.items;
            }
            const f = flags[s];
            if (f == 0) continue;
            return f & 1 != 0;
        }
        return d.eolMatch(s);
    }
};

/// Reusable matching state for one thread. Not thread-safe; make one per worker.
pub const Matcher = struct {
    prog: *const Program,
    buf: []u32,
    cur: ThreadList,
    next: ThreadList,
    stack: []u32,
    /// Start position of each thread, by pc, for `findSpan`.
    cur_start: []u32,
    next_start: []u32,
    dfa: ?Dfa = null,
    /// Cached: does the regex match an empty line?
    empty_matches: ?bool = null,

    pub fn init(gpa: Allocator, prog: *const Program) !Matcher {
        const n = prog.insts.len;
        const buf = try gpa.alloc(u32, n * 8 + 2);
        @memset(buf, 0);
        return .{
            .prog = prog,
            .buf = buf,
            .cur = .{ .dense = buf[0..n], .sparse = buf[n .. 2 * n] },
            .next = .{ .dense = buf[2 * n .. 3 * n], .sparse = buf[3 * n .. 4 * n] },
            .cur_start = buf[4 * n .. 5 * n],
            .next_start = buf[5 * n .. 6 * n],
            .stack = buf[6 * n ..],
            .dfa = if (Dfa.supported(prog)) try Dfa.init(gpa, prog) else null,
        };
    }

    pub const Span = struct { start: usize, end: usize };

    /// Like addThread, but keeps `match` in the list (so priority decides) and
    /// records each thread's start position.
    fn addSpanThread(m: *Matcher, list: *ThreadList, starts: []u32, pc0: u32, start: u32, line: []const u8, pos: usize) void {
        var sp: usize = 0;
        m.stack[sp] = pc0;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = m.stack[sp];
            if (list.contains(pc)) continue;
            list.insert(pc);
            starts[pc] = start;
            switch (m.prog.insts[pc]) {
                .jmp => |t| {
                    m.stack[sp] = t;
                    sp += 1;
                },
                .split => |x| {
                    m.stack[sp] = x[1];
                    m.stack[sp + 1] = x[0];
                    sp += 2;
                },
                .bol, .eol, .word_boundary, .not_word_boundary => {
                    const ok = switch (m.prog.insts[pc]) {
                        .bol => pos == 0,
                        .eol => pos == line.len,
                        .word_boundary => atBoundary(line, pos),
                        .not_word_boundary => !atBoundary(line, pos),
                        else => unreachable,
                    };
                    if (ok) {
                        m.stack[sp] = pc + 1;
                        sp += 1;
                    }
                },
                .byte, .set, .match => {},
            }
        }
    }

    /// The leftmost-first match in `line` starting at or after `from` (Perl and
    /// ripgrep semantics), or null.
    pub fn findSpan(m: *Matcher, line: []const u8, from: usize) ?Span {
        m.cur.len = 0;
        var found: ?Span = null;
        var pos = from;
        while (true) : (pos += 1) {
            if (found == null and (!m.prog.anchored_start or pos == 0))
                m.addSpanThread(&m.cur, m.cur_start, 0, @intCast(pos), line, pos);
            if (m.cur.len == 0) {
                if (found != null or pos >= line.len or m.prog.anchored_start) return found;
                continue;
            }
            m.next.len = 0;
            for (m.cur.dense[0..m.cur.len]) |pc| {
                switch (m.prog.insts[pc]) {
                    .match => {
                        // Lower-priority threads lose to this one.
                        found = .{ .start = m.cur_start[pc], .end = pos };
                        break;
                    },
                    .byte => |x| if (pos < line.len and line[pos] == x)
                        m.addSpanThread(&m.next, m.next_start, pc + 1, m.cur_start[pc], line, pos + 1),
                    .set => |si| if (pos < line.len and m.prog.sets[si].isSet(line[pos]))
                        m.addSpanThread(&m.next, m.next_start, pc + 1, m.cur_start[pc], line, pos + 1),
                    else => {},
                }
            }
            if (pos >= line.len) return found;
            std.mem.swap(ThreadList, &m.cur, &m.next);
            std.mem.swap([]u32, &m.cur_start, &m.next_start);
        }
    }

    pub fn deinit(m: *Matcher, gpa: Allocator) void {
        gpa.free(m.buf);
        if (m.dfa) |*d| d.deinit();
    }

    /// True if the regex matches anywhere in `line` (which has no newline).
    pub fn isMatch(m: *Matcher, line: []const u8) bool {
        if (line.len > 0) {
            if (m.dfa) |*d| {
                if (d.isMatch(line)) |hit| return hit else |err| switch (err) {
                    error.CacheFull => {
                        // Start the cache over (as RE2 and Rust's regex do) and retry; a
                        // line that alone needs more states than fit uses the Pike VM.
                        d.reset();
                        if (d.isMatch(line)) |hit| return hit else |_| d.reset();
                    },
                    error.OutOfMemory => {
                        d.deinit();
                        m.dfa = null;
                    },
                }
            }
        }
        return m.pikeMatch(line);
    }

    fn charBefore(line: []const u8, pos: usize) ?u21 {
        if (pos == 0) return null;
        var start = pos - 1;
        while (start > 0 and pos - start < 4 and line[start] & 0xC0 == 0x80) start -= 1;
        return std.unicode.utf8Decode(line[start..pos]) catch line[pos - 1];
    }

    fn charAt(line: []const u8, pos: usize) ?u21 {
        if (pos >= line.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(line[pos]) catch return line[pos];
        if (pos + n > line.len) return line[pos];
        return std.unicode.utf8Decode(line[pos..][0..n]) catch line[pos];
    }

    fn atBoundary(line: []const u8, pos: usize) bool {
        const before = if (charBefore(line, pos)) |cp| isWordChar(cp) else false;
        const after = if (charAt(line, pos)) |cp| isWordChar(cp) else false;
        return before != after;
    }

    /// Adds `pc0` and everything reachable from it without consuming input.
    /// Returns true if that reaches `match`.
    fn addThread(m: *Matcher, list: *ThreadList, pc0: u32, line: []const u8, pos: usize) bool {
        var sp: usize = 0;
        m.stack[sp] = pc0;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = m.stack[sp];
            if (list.contains(pc)) continue;
            list.insert(pc);
            switch (m.prog.insts[pc]) {
                .match => return true,
                .jmp => |t| {
                    m.stack[sp] = t;
                    sp += 1;
                },
                .split => |s| {
                    m.stack[sp] = s[1];
                    m.stack[sp + 1] = s[0];
                    sp += 2;
                },
                .bol, .eol, .word_boundary, .not_word_boundary => {
                    const ok = switch (m.prog.insts[pc]) {
                        .bol => pos == 0,
                        .eol => pos == line.len,
                        .word_boundary => atBoundary(line, pos),
                        .not_word_boundary => !atBoundary(line, pos),
                        else => unreachable,
                    };
                    if (ok) {
                        m.stack[sp] = pc + 1;
                        sp += 1;
                    }
                },
                .byte, .set => {},
            }
        }
        return false;
    }

    /// Whether `nextMatchingLine` can use the one-pass DFA scan.
    pub fn canScan(m: *const Matcher) bool {
        return m.dfa != null;
    }

    /// The start of the first matching line at or after `from` (a line start).
    pub fn nextMatchingLine(m: *Matcher, data: []const u8, from: usize) ?usize {
        var pos = from;
        while (pos < data.len) {
            if (m.dfa) |*d| {
                if (m.empty_matches == null) m.empty_matches = m.pikeMatch("");
                if (d.nextMatchingLine(data, pos, m.empty_matches.?)) |r| return r else |err| switch (err) {
                    error.CacheFull => {
                        pos = d.fail_line;
                        d.reset();
                        if (d.nextMatchingLine(data, pos, m.empty_matches.?)) |r| return r else |_| d.reset();
                        // This line alone needs more states than fit: check it with the
                        // Pike VM, then carry on with the DFA.
                        const e = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
                        if (m.pikeMatch(data[pos..e])) return pos;
                        pos = e + 1;
                        continue;
                    },
                    error.OutOfMemory => {
                        d.deinit();
                        m.dfa = null;
                    },
                }
            }
            const e = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
            if (m.isMatch(data[pos..e])) return pos;
            pos = e + 1;
        }
        return null;
    }

    pub fn pikeMatch(m: *Matcher, line: []const u8) bool {
        m.cur.len = 0;
        var pos: usize = 0;
        while (true) : (pos += 1) {
            if (pos == 0 or !m.prog.anchored_start) {
                if (m.addThread(&m.cur, 0, line, pos)) return true;
            }
            if (pos >= line.len) return false;
            if (m.cur.len == 0) {
                if (m.prog.anchored_start) return false;
                continue;
            }
            m.next.len = 0;
            const b = line[pos];
            for (m.cur.dense[0..m.cur.len]) |pc| {
                const ok = switch (m.prog.insts[pc]) {
                    .byte => |x| x == b,
                    .set => |si| m.prog.sets[si].isSet(b),
                    else => false,
                };
                if (ok and m.addThread(&m.next, pc + 1, line, pos + 1)) return true;
            }
            std.mem.swap(ThreadList, &m.cur, &m.next);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

fn expectMatch(pattern: []const u8, opts: Options, line: []const u8, want: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), pattern, opts);
    const prog = try compile(arena.allocator(), root);
    var m = try Matcher.init(std.testing.allocator, &prog);
    defer m.deinit(std.testing.allocator);
    if (m.isMatch(line) != want) {
        std.debug.print("pattern {s} on \"{s}\": want {}\n", .{ pattern, line, want });
        return error.TestUnexpectedResult;
    }
}

test "literals and concatenation" {
    try expectMatch("hello", .{}, "say hello world", true);
    try expectMatch("hello", .{}, "say hell world", false);
    try expectMatch("", .{}, "anything", true);
    try expectMatch("", .{}, "", true);
}

test "anchors" {
    try expectMatch("^fn ", .{}, "fn main() {", true);
    try expectMatch("^fn ", .{}, "pub fn main() {", false);
    try expectMatch("}$", .{}, "  }", true);
    try expectMatch("}$", .{}, "} x", false);
    try expectMatch("^$", .{}, "", true);
}

test "classes and escapes" {
    try expectMatch("[a-c]x", .{}, "zzbx", true);
    try expectMatch("[^a-c]x", .{}, "bx", false);
    try expectMatch("[^a-c]x", .{}, "dx", true);
    try expectMatch("\\d{3}-\\d{4}", .{}, "call 555-1234", true);
    try expectMatch("\\d{3}-\\d{4}", .{}, "call 55-1234", false);
    try expectMatch("a\\.b", .{}, "a.b", true);
    try expectMatch("a\\.b", .{}, "axb", false);
    try expectMatch("[[:digit:]]+", .{}, "abc 7", true);
    try expectMatch("\\s+$", .{}, "trailing  ", true);
    try expectMatch("[]]", .{}, "a]b", true);
}

test "alternation, groups and repetition" {
    try expectMatch("foo|bar", .{}, "xbarx", true);
    try expectMatch("foo|bar", .{}, "baz", false);
    try expectMatch("(ab)+c", .{}, "ababc", true);
    try expectMatch("(ab)+c", .{}, "ac", false);
    try expectMatch("colou?r", .{}, "color", true);
    try expectMatch("a{2,3}b", .{}, "ab", false);
    try expectMatch("a{2,3}b", .{}, "aaab", true);
    try expectMatch("a{2,}b", .{}, "aaaaab", true);
    try expectMatch("(?:x|y)*z", .{}, "xyxyz", true);
    try expectMatch("(a*)*b", .{}, "aaab", true);
    try expectMatch("(?P<name>ab)c", .{}, "abc", true);
    try expectMatch("x{,3}", .{}, "x{,3}", true);
}

test "case folding" {
    try expectMatch("Hello", .{ .ignore_case = true }, "HELLO there", true);
    try expectMatch("(?i)hello", .{}, "HeLLo", true);
    try expectMatch("hello", .{}, "HELLO", false);
    try expectMatch("[a-z]+", .{ .ignore_case = true }, "ABC", true);
}

test "word boundaries and word mode" {
    try expectMatch("\\bfoo\\b", .{}, "a foo b", true);
    try expectMatch("\\bfoo\\b", .{}, "afoo b", false);
    try expectMatch("foo", .{ .word = true }, "foo_bar", false);
    try expectMatch("foo", .{ .word = true }, "(foo)", true);
}

test "fixed strings" {
    try expectMatch("a.b(", .{ .fixed_string = true }, "x a.b( y", true);
    try expectMatch("a.b(", .{ .fixed_string = true }, "x axb( y", false);
}

test "utf-8" {
    try expectMatch("a.b", .{}, "aéb", true);
    try expectMatch("a..b", .{}, "aéb", false);
    try expectMatch("é+", .{}, "caféé", true);
    try expectMatch("[éa]x", .{}, "éx", true);
    try expectMatch("[^a]x", .{}, "éx", true);
}

test "DFA agrees with the Pike VM" {
    const gpa = std.testing.allocator;
    const patterns = [_][]const u8{
        "abc",        "a.c",       "^ab",         "bc$",          "^$",       "a|b|cd",
        "(ab)*c",     "[a-c]+d",   "x?y{2,3}",    "\\d+\\.\\d*",  ".*z$",     "(a|ab)(c|bcd)",
        "^(foo|bar)$", "[^a]b$",   "é.",          "a{0,2}b",      "",         "$x",
    };
    const lines = [_][]const u8{
        "abc",  "xabcx", "ab",   "bc",   "abbc",  "cd",   "ababc", "aad",  "yy",  "xyyy",
        "12.5", "3.",    "..z",  "abcd", "foo",   "bar",  "foobar", "bb",  "ab",  "éa",
        "ééb",  "aab",   "b",    "zzz",  "x",     "a",
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (patterns) |pat| {
        const prog = try compile(arena.allocator(), try parse(arena.allocator(), pat, .{}));
        var m = try Matcher.init(gpa, &prog);
        defer m.deinit(gpa);
        try std.testing.expect(m.dfa != null);
        for (lines) |line| {
            const want = m.pikeMatch(line);
            const got = try m.dfa.?.isMatch(line);
            if (want != got) {
                std.debug.print("pattern {s} line {s}: pike {} dfa {}\n", .{ pat, line, want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
}

fn expectSpans(pattern: []const u8, opts: Options, line: []const u8, want: []const [2]usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prog = try compile(arena.allocator(), try parse(arena.allocator(), pattern, opts));
    var m = try Matcher.init(std.testing.allocator, &prog);
    defer m.deinit(std.testing.allocator);
    var got: std.ArrayList([2]usize) = .empty;
    defer got.deinit(std.testing.allocator);
    var from: usize = 0;
    while (from <= line.len) {
        const sp = m.findSpan(line, from) orelse break;
        try got.append(std.testing.allocator, .{ sp.start, sp.end });
        from = if (sp.end > sp.start) sp.end else sp.end + 1;
    }
    std.testing.expectEqualSlices([2]usize, want, got.items) catch |err| {
        std.debug.print("pattern {s} on \"{s}\"\n", .{ pattern, line });
        return err;
    };
}

test "match spans are leftmost-first" {
    try expectSpans("fo+", .{}, "one foo two foo", &.{ .{ 4, 7 }, .{ 12, 15 } });
    try expectSpans("foo", .{}, "foofoo", &.{ .{ 0, 3 }, .{ 3, 6 } });
    try expectSpans("a|ab", .{}, "ab", &.{.{ 0, 1 }}); // first alternative wins
    try expectSpans("ab|a", .{}, "ab", &.{.{ 0, 2 }});
    try expectSpans("a*?b", .{}, "aab", &.{.{ 0, 3 }});
    try expectSpans("a+?", .{}, "aaa", &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } });
    try expectSpans("<.+?>", .{}, "<a><b>", &.{ .{ 0, 3 }, .{ 3, 6 } });
    try expectSpans("<.+>", .{}, "<a><b>", &.{.{ 0, 6 }});
    try expectSpans("^x", .{}, "xx", &.{.{ 0, 1 }});
    try expectSpans("x$", .{}, "xx", &.{.{ 1, 2 }});
    try expectSpans("\\bis\\b", .{}, "this is it", &.{.{ 5, 7 }});
    try expectSpans("é+", .{}, "caféé!", &.{.{ 3, 7 }});
    try expectSpans("\\d+", .{}, "a1b22c333", &.{ .{ 1, 2 }, .{ 3, 5 }, .{ 6, 9 } });
    try expectSpans("z", .{}, "abc", &.{});
}

test "unicode classes, folding and boundaries" {
    // Subscript one and the ellipsis aren't word characters; Greek eta is.
    try expectMatch("\\w+_\\w+_\\w+", .{}, "a\u{2081}\u{2026}a_\u{3b7}b\u{2081}\u{2026}b_\u{3b7}a\u{2081}", false);
    try expectMatch("^\\w+$", .{}, "\u{3b7}\u{3bb}\u{3b9}\u{3bf}\u{3c2}", true);
    try expectMatch("^\\w+$", .{}, "a\u{2026}", false);
    try expectMatch("\\d", .{}, "\u{0663}", true); // Arabic-Indic three
    try expectMatch("\\s", .{}, "a\u{3000}b", true); // ideographic space
    try expectMatch("[\u{3b1}-\u{3c9}]+", .{}, "x\u{3bb}y", true);
    try expectMatch("[^\u{e9}]", .{}, "\u{e9}", false);
    try expectMatch("[^\u{e9}]", .{}, "\u{e8}", true);
    try expectMatch("\u{c9}t\u{c9}", .{ .ignore_case = true }, "\u{e9}t\u{e9}", true);
    try expectMatch("\u{3a3}", .{ .ignore_case = true }, "\u{3c3}", true);
    try expectMatch("[\u{e0}-\u{e9}]", .{ .ignore_case = true }, "\u{c9}", true);
    try expectMatch("k", .{ .ignore_case = true }, "\u{212a}", false); // ASCII folds ASCII-only
    try expectMatch("\\bcaf\u{e9}\\b", .{}, "un caf\u{e9}s", false);
    try expectMatch("\\bcaf\u{e9}\\b", .{}, "un caf\u{e9}!", true);
    try expectMatch(".", .{}, "\u{1F600}", true);
    try expectMatch("^.$", .{}, "\u{1F600}", true);
}

test "one-pass line scan agrees with per-line matching" {
    const gpa = std.testing.allocator;
    const patterns = [_][]const u8{ "[0-9]{4}-[0-9]{2}", "^$", "^a", "b$", "x*", "\\d+\\.\\d+", "z", "^.*q.*$" };
    const data = "a1\n\n2024-01-02\nab\nqqq\n1.5\nxb\n\nlast";
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (patterns) |pat| {
        const prog = try compile(arena.allocator(), try parse(arena.allocator(), pat, .{}));
        var m = try Matcher.init(gpa, &prog);
        defer m.deinit(gpa);
        var want: std.ArrayList(usize) = .empty;
        defer want.deinit(gpa);
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        var p: usize = 0;
        while (p <= data.len) {
            const e = std.mem.indexOfScalarPos(u8, data, p, '\n') orelse data.len;
            if (m.pikeMatch(data[p..e])) try want.append(gpa, p);
            p = e + 1;
        }
        p = 0;
        while (m.nextMatchingLine(data, p)) |ls| {
            try got.append(gpa, ls);
            p = (std.mem.indexOfScalarPos(u8, data, ls, '\n') orelse data.len) + 1;
            if (p > data.len) break;
        }
        std.testing.expectEqualSlices(usize, want.items, got.items) catch |err| {
            std.debug.print("pattern {s}\n", .{pat});
            return err;
        };
    }
}

test "errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadPattern, parse(a, "(abc", .{}));
    try std.testing.expectError(error.BadPattern, parse(a, "abc)", .{}));
    try std.testing.expectError(error.BadPattern, parse(a, "*a", .{}));
    try std.testing.expectError(error.Unsupported, parse(a, "(?=a)", .{}));
    try std.testing.expectError(error.Unsupported, parse(a, "\\1", .{}));
}

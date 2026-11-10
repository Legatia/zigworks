//! A small line-oriented regex engine: parser, Thompson-NFA compiler and Pike VM.
//!
//! Matching is byte-based, but `.`, negated classes and \D/\S/\w treat a whole UTF-8
//! sequence as one character. Case folding (`-i`, `(?i)`) is ASCII-only. There are no
//! captures: trigrep only needs to know whether a line matches.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, BadPattern, Unsupported, TooBig };

pub const ByteSet = std.StaticBitSet(256);

/// Matches one character: a byte from `bytes`, any multi-byte UTF-8 sequence when
/// `multibyte`, or one of `seqs` (non-ASCII characters listed in a class).
pub const Set = struct {
    bytes: ByteSet,
    multibyte: bool = false,
    seqs: []const []const u8 = &.{},
};

pub const Repeat = struct { node: *const Node, min: u32, max: ?u32 };

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

pub fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

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
            // Lazy and possessive suffixes don't change whether a line matches.
            if (p.peek() == '?' or p.peek() == '+') p.pos += 1;
            if (min > max_repeat or (max != null and max.? > max_repeat)) return error.TooBig;
            if (max != null and max.? < min) return error.BadPattern;
            const boxed = try p.arena.create(Node);
            boxed.* = atom;
            atom = .{ .repeat = .{ .node = boxed, .min = min, .max = max } };
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
        const items = try p.arena.alloc(Node, len);
        for (p.src[p.pos..][0..len], 0..) |b, i| items[i] = .{ .byte = b };
        p.pos += len;
        return .{ .concat = items };
    }

    fn parseEscape(p: *Parser) Error!Node {
        p.pos += 1;
        const c = p.peek() orelse return error.BadPattern;
        p.pos += 1;
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => return .{ .set = classEscape(c) },
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
        var s = Set{ .bytes = ByteSet.initEmpty() };
        var seqs: std.ArrayList([]const u8) = .empty;
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
                const named = try posixClass(p.src[p.pos + 2 .. end]);
                s.bytes.setUnion(named);
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
                        const cs = classEscape(e);
                        s.bytes.setUnion(cs.bytes);
                        if (cs.multibyte) s.multibyte = true;
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
            if (hi < 0x80) {
                var x = lo;
                while (x <= hi) : (x += 1) p.addByte(&s, @intCast(x));
            } else if (lo == hi) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(lo, &buf) catch return error.BadPattern;
                try seqs.append(p.arena, try p.arena.dupe(u8, buf[0..n]));
            } else return error.Unsupported;
        }
        if (negate) {
            if (seqs.items.len > 0) return error.Unsupported;
            var neg = ByteSet.initEmpty();
            for (0..0x80) |i| {
                if (!s.bytes.isSet(i)) neg.set(i);
            }
            neg.unset('\n');
            return .{ .set = .{ .bytes = neg, .multibyte = !s.multibyte } };
        }
        s.seqs = seqs.items;
        return .{ .set = s };
    }
};

fn dotSet() Set {
    var s = Set{ .bytes = ByteSet.initEmpty(), .multibyte = true };
    for (0..0x80) |i| s.bytes.set(i);
    s.bytes.unset('\n');
    return s;
}

/// \d \w \s and their negations. Non-ASCII characters count as word characters and as
/// non-digits/non-spaces.
fn classEscape(c: u8) Set {
    var s = Set{ .bytes = ByteSet.initEmpty() };
    const kind = std.ascii.toLower(c);
    for (0..0x80) |i| {
        const b: u8 = @intCast(i);
        const in = switch (kind) {
            'd' => std.ascii.isDigit(b),
            'w' => isWordByte(b),
            's' => isSpaceByte(b),
            else => unreachable,
        };
        if (in) s.bytes.set(b);
    }
    if (kind == 'w') s.multibyte = true;
    if (std.ascii.isUpper(c)) {
        var neg = ByteSet.initEmpty();
        for (0..0x80) |i| {
            if (!s.bytes.isSet(i)) neg.set(i);
        }
        return .{ .bytes = neg, .multibyte = !s.multibyte };
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
                    for (splits.items) |sp| c.insts.items[sp] = .{ .split = .{ sp + 1, c.len() } };
                } else {
                    const sp = try c.emit(.{ .split = .{ 0, 0 } });
                    try c.compile(r.node.*);
                    _ = try c.emit(.{ .jmp = sp });
                    c.insts.items[sp] = .{ .split = .{ sp + 1, c.len() } };
                }
            },
            .bol => _ = try c.emit(.bol),
            .eol => _ = try c.emit(.eol),
            .word_boundary => _ = try c.emit(.word_boundary),
            .not_word_boundary => _ = try c.emit(.not_word_boundary),
        }
    }

    fn rangeSet(lo: u8, hi: u8) Node {
        var s = Set{ .bytes = ByteSet.initEmpty() };
        s.bytes.setRangeValue(.{ .start = lo, .end = @as(usize, hi) + 1 }, true);
        return .{ .set = s };
    }

    fn compileSet(c: *Compiler, s: Set) Error!void {
        if (!s.multibyte and s.seqs.len == 0) {
            if (s.bytes.count() == 1) {
                _ = try c.emit(.{ .byte = @intCast(s.bytes.findFirstSet().?) });
            } else {
                const idx: u32 = @intCast(c.sets.items.len);
                try c.sets.append(c.arena, s.bytes);
                _ = try c.emit(.{ .set = idx });
            }
            return;
        }
        var alts: std.ArrayList(Node) = .empty;
        if (s.bytes.count() > 0) try alts.append(c.arena, .{ .set = .{ .bytes = s.bytes } });
        if (s.multibyte) {
            const cont = rangeSet(0x80, 0xBF);
            const two = try c.arena.dupe(Node, &.{ rangeSet(0xC2, 0xDF), cont });
            const three = try c.arena.dupe(Node, &.{ rangeSet(0xE0, 0xEF), cont, cont });
            const four = try c.arena.dupe(Node, &.{ rangeSet(0xF0, 0xF4), cont, cont, cont });
            try alts.append(c.arena, .{ .concat = two });
            try alts.append(c.arena, .{ .concat = three });
            try alts.append(c.arena, .{ .concat = four });
        }
        for (s.seqs) |q| {
            const items = try c.arena.alloc(Node, q.len);
            for (q, 0..) |b, i| items[i] = .{ .byte = b };
            try alts.append(c.arena, .{ .concat = items });
        }
        if (alts.items.len == 1) return c.compile(alts.items[0]);
        try c.compile(.{ .alt = alts.items });
    }
};

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
        d.seeds.deinit(d.gpa);
        d.out.deinit(d.gpa);
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

    /// Like Matcher.isMatch, for non-empty lines.
    pub fn isMatch(d: *Dfa, line: []const u8) DfaError!bool {
        var s = try d.startState();
        if (d.states.items[s].match) return true;
        for (line) |b| {
            s = try d.next(s, b);
            const st = d.states.items[s];
            if (st.match) return true;
            if (st.len == 0) return false;
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
    dfa: ?Dfa = null,

    pub fn init(gpa: Allocator, prog: *const Program) !Matcher {
        const n = prog.insts.len;
        const buf = try gpa.alloc(u32, n * 6 + 2);
        @memset(buf, 0);
        return .{
            .prog = prog,
            .buf = buf,
            .cur = .{ .dense = buf[0..n], .sparse = buf[n .. 2 * n] },
            .next = .{ .dense = buf[2 * n .. 3 * n], .sparse = buf[3 * n .. 4 * n] },
            .stack = buf[4 * n ..],
            .dfa = if (Dfa.supported(prog)) try Dfa.init(gpa, prog) else null,
        };
    }

    pub fn deinit(m: *Matcher, gpa: Allocator) void {
        gpa.free(m.buf);
        if (m.dfa) |*d| d.deinit();
    }

    /// True if the regex matches anywhere in `line` (which has no newline).
    pub fn isMatch(m: *Matcher, line: []const u8) bool {
        if (line.len > 0) {
            if (m.dfa) |*d| {
                if (d.isMatch(line)) |hit| return hit else |_| {
                    // Too many states for this pattern: stay on the Pike VM from now on.
                    d.deinit();
                    m.dfa = null;
                }
            }
        }
        return m.pikeMatch(line);
    }

    fn atBoundary(line: []const u8, pos: usize) bool {
        const before = pos > 0 and isWordByte(line[pos - 1]);
        const after = pos < line.len and isWordByte(line[pos]);
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

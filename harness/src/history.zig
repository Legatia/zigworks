//! Long memory, part one: `history`, a search of every earlier turn in the
//! action log, newest first. A turn is a run: the message it started with,
//! its posts and its answer, its tool calls with their results (the first
//! 2 KB, what the log keeps). A private run keeps only sizes and hashes in
//! the log, so its words are never found. There is no index: the log is
//! read from its end a block at a time, and a run is complete when its
//! first line is reached, so the first matches found are the newest.
const std = @import("std");
const util = @import("util.zig");
const jv = @import("jv.zig");
const session = @import("session.zig");
const model = @import("model.zig");
const Io = std.Io;

/// Turns a search returns at most.
pub const max_hits = 20;
/// The most a run's view, or a search's answer to the agent, holds.
pub const max_view = 16 * 1024;
/// Words and phrases a search takes at most.
pub const max_terms = 16;
/// How much of the log is read at a time.
const block_size = 1 << 20;
/// How much of the log after a run's first line its view reads.
const view_window = 8 << 20;

/// What a run may search: every conversation (the owner's own runs), or
/// only its own.
pub const Scope = struct {
    all: bool,
    /// The run's conversation: the only one searched when not `all`.
    conversation: []const u8 = "",
};

/// Where `history` reads, and how a run's scope is told.
pub const Source = struct {
    log_path: []const u8,
    /// state/summaries ("": none), for the summaries in the prompt.
    summaries_dir: []const u8 = "",
    ctx: ?*anyopaque = null,
    /// Whether others read conversation `name` (a group).
    shared: ?*const fn (ctx: ?*anyopaque, name: []const u8) bool = null,

    /// A run the owner started, in a conversation only the owner reads,
    /// searches every conversation; any other run (a schedule's, a
    /// trigger's, a workflow's, an app's, or one where others read) only
    /// its own.
    pub fn scopeOf(s: *const Source, by: []const u8, conversation: []const u8) Scope {
        const shared = if (s.shared) |f| f(s.ctx, conversation) else false;
        return .{ .all = std.mem.eql(u8, by, "owner") and !shared, .conversation = conversation };
    }
};

/// A word or a phrase to find.
pub const Term = struct {
    /// As typed (a phrase without its quotes).
    text: []const u8,
    /// As the log's bytes hold it: JSON-escaped, ASCII letters in lower case.
    scan: []const u8,
};

/// The words of `words`, and the phrases in it between double quotes ("…"
/// or “…”), each once, at most `max_terms`.
pub fn parseTerms(a: std.mem.Allocator, words_in: []const u8) ![]const Term {
    var out: std.ArrayList(Term) = .empty;
    var i: usize = 0;
    while (i < words_in.len and out.items.len < max_terms) {
        if (quoteAt(words_in, i)) |q| {
            const start = i + q;
            var j = start;
            while (j < words_in.len and quoteAt(words_in, j) == null) j += 1;
            try addTerm(a, &out, words_in[start..j]);
            i = if (j < words_in.len) j + quoteAt(words_in, j).? else j;
            continue;
        }
        if (std.ascii.isWhitespace(words_in[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < words_in.len and !std.ascii.isWhitespace(words_in[i]) and quoteAt(words_in, i) == null) i += 1;
        try addTerm(a, &out, words_in[start..i]);
    }
    return out.items;
}

/// The length of the double quote at `i` (", “ or ”), or null.
fn quoteAt(s: []const u8, i: usize) ?usize {
    if (s[i] == '"') return 1;
    for ([_][]const u8{ "\u{201c}", "\u{201d}" }) |q| if (std.mem.startsWith(u8, s[i..], q)) return q.len;
    return null;
}

fn addTerm(a: std.mem.Allocator, out: *std.ArrayList(Term), raw: []const u8) !void {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return;
    var esc: std.ArrayList(u8) = .empty;
    try util.jsonString(&esc, a, text);
    const scan = esc.items[1 .. esc.items.len - 1];
    for (scan) |*c| c.* = std.ascii.toLower(c.*);
    for (out.items) |o| if (std.mem.eql(u8, o.scan, scan)) return;
    try out.append(a, .{ .text = text, .scan = scan });
}

/// Boyer-Moore-Horspool for one term, its table made once.
const Finder = struct {
    needle: []const u8,
    skip: [256]u32,

    fn init(needle: []const u8) Finder {
        var f: Finder = .{ .needle = needle, .skip = @splat(@intCast(needle.len)) };
        if (needle.len > 1) for (needle[0 .. needle.len - 1], 0..) |c, i| {
            f.skip[c] = @intCast(needle.len - 1 - i);
        };
        return f;
    }

    fn in(f: *const Finder, hay: []const u8) bool {
        const n = f.needle;
        if (n.len == 0) return true;
        if (hay.len < n.len) return false;
        const last = n.len - 1;
        var i: usize = 0;
        while (i <= hay.len - n.len) {
            const c = hay[i + last];
            if (c == n[last] and std.mem.eql(u8, hay[i .. i + last], n[0..last])) return true;
            i += f.skip[c];
        }
        return false;
    }
};

// ---- reading log lines without parsing them ----

/// The part of a line where a run's labels are (`rid`, `conversation`,
/// `run`, `by`, `agent`, `parent`, `tool`, `event`: all short).
fn head(line: []const u8) []const u8 {
    return line[0..@min(line.len, 512)];
}

/// The raw (still escaped) value of the string field `name`, or null (no
/// such field, or one kept private: `{"bytes":…}`). `,"` never occurs
/// inside a string's value, where every `"` is escaped.
fn rawField(line: []const u8, comptime name: []const u8) ?[]const u8 {
    const key = ",\"" ++ name ++ "\":\"";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const s = line[at + key.len ..];
    var i: usize = 0;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '"' => return s[0..i],
        else => {},
    };
    return null;
}

fn intField(line: []const u8, comptime name: []const u8) ?u64 {
    const key = ",\"" ++ name ++ "\":";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    return leadingInt(line[at + key.len ..]);
}

/// Where the JSON string that starts at `from` (after its quote) ends: the
/// first `"` not escaped.
fn stringEnd(s: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, s, i, '"')) |q| {
        var slashes: usize = 0;
        while (q - slashes > from and s[q - slashes - 1] == '\\') slashes += 1;
        if (slashes % 2 == 0) return q;
        i = q + 1;
    }
    return null;
}

/// A log line's top-level fields in order: each name and raw value (a
/// string's without its quotes, still escaped; a private value's
/// `{"bytes":…}` whole). Lines are flat: strings, numbers, booleans, null,
/// and those private objects.
const Walker = struct {
    line: []const u8,
    i: usize = 1,

    const Field = struct { name: []const u8, raw: []const u8, string: bool = false };

    fn next(w: *Walker) ?Field {
        const s = w.line;
        if (w.i >= s.len or s[w.i] != '"') return null;
        const name_end = std.mem.indexOfScalarPos(u8, s, w.i + 1, '"') orelse return null;
        var f: Field = .{ .name = s[w.i + 1 .. name_end], .raw = "" };
        var i = name_end + 1;
        if (i + 1 >= s.len or s[i] != ':') return null;
        i += 1;
        switch (s[i]) {
            '"' => {
                const end = stringEnd(s, i + 1) orelse return null;
                f.raw = s[i + 1 .. end];
                f.string = true;
                i = end + 1;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, s, i, '}') orelse return null;
                f.raw = s[i .. close + 1];
                i = close + 1;
            },
            else => {
                const start = i;
                while (i < s.len and s[i] != ',' and s[i] != '}') i += 1;
                f.raw = s[start..i];
            },
        }
        if (i < s.len and s[i] == ',') i += 1;
        w.i = i;
        return f;
    }
};

fn leadingInt(s: []const u8) ?u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i]) and i < 19) : (i += 1) n = n * 10 + (s[i] - '0');
    return if (i == 0) null else n;
}

fn seqOf(line: []const u8) ?u64 {
    const key = "{\"seq\":";
    if (!std.mem.startsWith(u8, line, key)) return null;
    return leadingInt(line[key.len..]);
}

/// "2026-11-19T08:12:00Z" in either case (a block is searched lowered).
fn parseTime(s: []const u8) ?i64 {
    if (s.len != 20) return null;
    var b: [20]u8 = s[0..20].*;
    b[10] = std.ascii.toUpper(b[10]);
    b[19] = std.ascii.toUpper(b[19]);
    return util.parseIso(&b);
}

fn seqKey(line: []const u8) ?i64 {
    const s = seqOf(line) orelse return null;
    return @intCast(@min(s, std.math.maxInt(i63)));
}

/// A line's time, as a key for `seekLine`.
pub fn timeKey(line: []const u8) ?i64 {
    return parseTime(rawField(head(line), "time") orelse return null);
}

/// The offset of the first line whose key is at least `want`, the keys
/// rising through the file (`seq`; `time`, nearly); `len` when none.
pub fn seekLine(io: Io, f: Io.File, len: u64, want: i64, key: *const fn ([]const u8) ?i64) !u64 {
    var lo: u64 = 0;
    var hi: u64 = len;
    var buf: [16 * 1024]u8 = undefined;
    // halves while what is left is large; a line is far shorter than a window
    while (hi - lo > 64 * 1024) {
        const mid = lo + (hi - lo) / 2;
        const got = try f.readPositionalAll(io, &buf, mid);
        const w = buf[0..got];
        const nl = std.mem.indexOfScalar(u8, w, '\n') orelse break;
        const start = mid + nl + 1;
        if (start >= hi) break;
        const k = key(w[nl + 1 ..]) orelse break;
        if (k < want) lo = start else hi = start;
    }
    // then line by line from `lo`
    var off = lo;
    var rbuf: [64 * 1024]u8 = undefined;
    while (off < len) {
        const got = try f.readPositionalAll(io, &rbuf, off);
        const w = rbuf[0..got];
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, w, i, '\n')) |nl| {
            if (key(w[i..nl])) |k| if (k >= want) return off + i;
            i = nl + 1;
        }
        // the last line, without its newline
        if (got < rbuf.len) {
            if (i < got) if (key(w[i..got])) |k| if (k >= want) return off + i;
            return len;
        }
        // a line longer than the window: not one harness writes
        if (i == 0) return len;
        off += i;
    }
    return len;
}

// ---- the search ----

pub const Query = struct {
    terms: []const Term,
    /// Only this conversation (within the scope).
    conversation: ?[]const u8 = null,
    /// Only runs that started before this (Unix seconds).
    before_s: ?i64 = null,
    max: usize = max_hits,
};

/// A line of the log, by where it is.
pub const LineRef = struct { off: u64, len: u32 };

/// A run with every term: its first line, and its posts, its answer and
/// the tool calls with a term in them (newest first).
pub const Hit = struct { rid: u64, first: LineRef, lines: []const LineRef };

pub const Found = struct { hits: []const Hit, more: bool = false };

/// What the backward read keeps of a run whose first line it has not
/// reached yet.
const Open = struct { mask: u32 = 0, lines: std.ArrayList(LineRef) = .empty };

const Scan = struct {
    a: std.mem.Allocator,
    finders: []const Finder,
    full: u32,
    scope: Scope,
    /// The conversation asked for (lower case), or null.
    only: ?[]const u8,
    before_s: ?i64,
    max: usize,
    open: std.AutoHashMapUnmanaged(u64, Open) = .empty,
    hits: std.ArrayList(Hit) = .empty,

    fn inScope(s: *const Scan, conv: ?[]const u8) bool {
        if (!s.scope.all) {
            const c = conv orelse return false;
            if (!std.mem.eql(u8, c, s.scope.conversation)) return false;
        }
        if (s.only) |want| {
            const c = conv orelse return false;
            if (!std.mem.eql(u8, c, want)) return false;
        }
        return true;
    }

    /// The terms in `x`, as bits.
    fn terms(s: *const Scan, x: []const u8) u32 {
        var m: u32 = 0;
        for (s.finders, 0..) |*fd, i| if (fd.in(x)) {
            m |= @as(u32, 1) << @intCast(i);
        };
        return m;
    }

    /// One line (lower case), read backward; true when enough runs are found.
    fn take(s: *Scan, off: u64, line: []const u8) !bool {
        const eql = std.mem.eql;
        var w: Walker = .{ .line = line };
        var seq: ?u64 = null;
        var rid: ?u64 = null;
        var conv: ?[]const u8 = null;
        var kind: []const u8 = "";
        var tool: []const u8 = "";
        var event: []const u8 = "";
        var in_scope = false;
        // what was said: the message, the answer, a post, a call and its result
        var said: [2][]const u8 = undefined;
        var n_said: usize = 0;
        var answer = false;
        while (w.next()) |f| {
            const name = f.name;
            if (eql(u8, name, "seq")) {
                seq = leadingInt(f.raw);
            } else if (eql(u8, name, "kind")) {
                kind = f.raw;
            } else if (eql(u8, name, "rid")) {
                rid = leadingInt(f.raw);
            } else if (eql(u8, name, "conversation")) {
                conv = f.raw;
            } else if (eql(u8, name, "run")) {
                // a run's labels come first (every line of it names its
                // conversation): a line of another is left at once
                if (rid == null or !s.inScope(conv)) return false;
                in_scope = true;
            } else if (eql(u8, name, "tool")) {
                tool = f.raw;
            } else if (eql(u8, name, "event")) {
                event = f.raw;
            } else if (f.string and n_said < said.len and (eql(u8, name, "text") or eql(u8, name, "answer") or eql(u8, name, "arg") or eql(u8, name, "output"))) {
                said[n_said] = f.raw;
                n_said += 1;
                if (eql(u8, name, "answer")) answer = true;
            }
        }
        if (!in_scope) return false;
        const r = rid.?;
        var found: u32 = 0;
        // shown with the run even without a term: its posts and its answer
        var keep = false;
        const counts = if (eql(u8, kind, "turn"))
            true
        else if (eql(u8, kind, "send"))
            // a refused post, or a scheduled run's NOTHING, said nothing
            !eql(u8, event, "refused") and !eql(u8, event, "silent")
        else if (eql(u8, kind, "tool"))
            // what history answered is older turns again
            !eql(u8, tool, "history")
        else
            false;
        if (counts) {
            for (said[0..n_said]) |x| found |= s.terms(x);
            keep = answer or (eql(u8, kind, "send") and n_said > 0);
        }
        if (seq == r) return s.complete(r, off, line, found);
        if (found == 0 and !keep) return false;
        const gop = try s.open.getOrPut(s.a, r);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.mask |= found;
        try gop.value_ptr.lines.append(s.a, .{ .off = off, .len = @intCast(line.len) });
        return false;
    }

    /// The run's first line: all its lines are read.
    fn complete(s: *Scan, rid: u64, off: u64, line: []const u8, found: u32) !bool {
        var mask = found;
        var lines: []const LineRef = &.{};
        if (s.open.fetchRemove(rid)) |kv| {
            mask |= kv.value.mask;
            lines = kv.value.lines.items;
        }
        if (mask != s.full) return false;
        if (s.before_s) |b| {
            const started = timeKey(line) orelse return false;
            if (started >= b) return false;
        }
        try s.hits.append(s.a, .{ .rid = rid, .first = .{ .off = off, .len = @intCast(line.len) }, .lines = lines });
        return s.hits.items.len > s.max;
    }
};

/// The newest runs (at most `q.max`) in `scope` that have every term of
/// `q`, read from the log at `path`; `more` when there are older ones.
pub fn search(a: std.mem.Allocator, io: Io, path: []const u8, scope: Scope, q: Query) !Found {
    if (q.terms.len == 0 or q.terms.len > max_terms) return .{ .hits = &.{} };
    const finders = try a.alloc(Finder, q.terms.len);
    for (q.terms, finders) |tm, *fd| fd.* = .init(tm.scan);
    var s: Scan = .{
        .a = a,
        .finders = finders,
        .full = @intCast((@as(u64, 1) << @intCast(q.terms.len)) - 1),
        // conversation names are lower case; the blocks are read lowered
        .scope = .{ .all = scope.all, .conversation = try std.ascii.allocLowerString(a, scope.conversation) },
        .only = if (q.conversation) |c| try std.ascii.allocLowerString(a, c) else null,
        .before_s = q.before_s,
        .max = q.max,
    };
    var f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try a.alloc(u8, block_size);
    var end: u64 = len;
    // inside a line longer than a block (not one harness writes): skipped
    var long_line = false;
    scan: while (end > 0) {
        const start = end -| block_size;
        const n: usize = @intCast(end - start);
        const got = try f.readPositionalAll(io, buf[0..n], start);
        const block = buf[0..got];
        // where this block's whole lines begin: the first one may have begun before it
        var from: usize = 0;
        if (start > 0) {
            from = (std.mem.indexOfScalar(u8, block, '\n') orelse {
                end = start;
                long_line = true;
                continue;
            }) + 1;
        }
        var to: usize = block.len;
        if (long_line) {
            to = std.mem.lastIndexOfScalar(u8, block, '\n').? + 1;
            long_line = false;
        }
        const lines = block[from..to];
        for (lines) |*c| c.* = std.ascii.toLower(c.*);
        // its lines, last first
        var stop = lines.len;
        while (stop > 0) {
            var e = stop;
            if (lines[e - 1] == '\n') e -= 1;
            const b = if (std.mem.lastIndexOfScalar(u8, lines[0..e], '\n')) |k| k + 1 else 0;
            if (e > b and try s.take(start + from + b, lines[b..e])) break :scan;
            stop = b;
        }
        end = start + from;
    }
    const more = s.hits.items.len > q.max;
    return .{ .hits = s.hits.items[0..@min(s.hits.items.len, q.max)], .more = more };
}

// ---- what a search shows ----

/// The owner's time of `secs`: "2026-11-20 14:02", with ":SS" when `seconds`.
fn localStamp(buf: *[20]u8, secs: i64, utc_offset: i32, seconds: bool) []const u8 {
    const iso = util.isoTime(buf, secs + @as(i64, utc_offset) * 60);
    buf[10] = ' ';
    return iso[0..if (seconds) 19 else 16];
}

/// "2026-11-20", "2026-11-20 14:02" or "2026-11-20 14:02:11" (or with a
/// T), in the owner's time: Unix seconds; null when it is none of those.
pub fn parseBefore(s_in: []const u8, utc_offset: i32) ?i64 {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    var secs = util.daysFromCivil(y, m, d) * 86400;
    if (s.len > 10) {
        if (s[10] != ' ' and s[10] != 'T') return null;
        const rest = s[11..];
        if ((rest.len != 5 and rest.len != 8) or rest[2] != ':' or (rest.len == 8 and rest[5] != ':')) return null;
        const h = std.fmt.parseInt(i64, rest[0..2], 10) catch return null;
        const mi = std.fmt.parseInt(i64, rest[3..5], 10) catch return null;
        const se = if (rest.len == 8) std.fmt.parseInt(i64, rest[6..8], 10) catch return null else 0;
        if (h > 23 or mi > 59 or se > 59) return null;
        secs += h * 3600 + mi * 60 + se;
    }
    return secs - @as(i64, utc_offset) * 60;
}

/// `text` on one line of at most about 300 bytes: its start, or the part
/// around the first term in it.
fn snippet(a: std.mem.Allocator, text: []const u8, terms: []const Term) ![]const u8 {
    const flat = try a.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
    for (flat) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    const width = 300;
    if (flat.len <= width) return flat;
    var at: ?usize = null;
    for (terms) |tm| if (std.ascii.findIgnoreCase(flat, tm.text)) |p| {
        if (at == null or p < at.?) at = p;
    };
    const p = at orelse 0;
    if (p + 60 < width) return std.fmt.allocPrint(a, "{s}…", .{util.cut(flat, width)});
    var from = p - 100;
    while (from < flat.len and flat[from] & 0xc0 == 0x80) from += 1;
    const part = util.cut(flat[from..], width);
    return std.fmt.allocPrint(a, "…{s}{s}", .{ part, if (from + part.len < flat.len) "…" else "" });
}

fn readLine(a: std.mem.Allocator, io: Io, f: Io.File, ref: LineRef) ![]const u8 {
    const buf = try a.alloc(u8, ref.len);
    const got = try f.readPositionalAll(io, buf, ref.off);
    return buf[0..got];
}

/// One hit as shown: when and where, what the run started with, its
/// posts (or its answer), the tool calls with a term in them.
fn hitText(a: std.mem.Allocator, io: Io, f: Io.File, h: Hit, terms: []const Term, utc_offset: i32) !struct { text: []const u8, start_s: i64 } {
    const v = jv.parse(a, try readLine(a, io, f, h.first)) orelse return error.BadLogLine;
    const start_s = util.parseIso(jv.str(jv.get(v, "time")) orelse "") orelse 0;
    const conv = jv.str(jv.get(v, "conversation")) orelse "-";
    const label = jv.str(jv.get(v, "run")) orelse "";
    const own = std.mem.eql(u8, jv.str(jv.get(v, "by")) orelse "", "owner") and jv.get(v, "parent") == null;
    var out: std.ArrayList(u8) = .empty;
    var tb: [20]u8 = undefined;
    try out.print(a, "\n{s}, {s}, run {d} ({s})\n", .{ localStamp(&tb, start_s, utc_offset, false), conv, h.rid, label });
    if (jv.str(jv.get(v, "text"))) |text| try out.print(a, "{s}: {s}\n", .{ if (own) "Owner" else "Instruction", try snippet(a, text, terms) });
    var posts: usize = 0;
    var calls: usize = 0;
    var answer: ?[]const u8 = null;
    var i = h.lines.len;
    while (i > 0) {
        i -= 1;
        const lv = jv.parse(a, try readLine(a, io, f, h.lines[i])) orelse continue;
        const kind = jv.str(jv.get(lv, "kind")) orelse "";
        if (std.mem.eql(u8, kind, "send")) {
            posts += 1;
            if (posts > 3) continue;
            const to = jv.str(jv.get(lv, "to")) orelse conv;
            const where = if (std.mem.eql(u8, to, conv)) "" else try std.fmt.allocPrint(a, " (to {s})", .{to});
            try out.print(a, "Agent{s}: {s}\n", .{ where, try snippet(a, jv.str(jv.get(lv, "text")) orelse "", terms) });
        } else if (std.mem.eql(u8, kind, "turn")) {
            if (jv.str(jv.get(lv, "answer"))) |x| answer = x;
        } else if (std.mem.eql(u8, kind, "tool")) {
            calls += 1;
            if (calls > 3) continue;
            try out.print(a, "{s} {s}: {s}\n", .{ jv.str(jv.get(lv, "tool")) orelse "", util.cut(jv.str(jv.get(lv, "arg")) orelse "", 80), try snippet(a, jv.str(jv.get(lv, "output")) orelse "", terms) });
        }
    }
    // a reply posted by harness is a post; before posts, the answer was it
    if (posts == 0) if (answer) |x| if (x.len > 0) try out.print(a, "Agent: {s}\n", .{try snippet(a, x, terms)});
    return .{ .text = out.items, .start_s = start_s };
}

/// What a search found, as the agent or the owner reads it: each run with
/// its date (the owner's time), conversation and run, newest first, within
/// `max_bytes` (0: no limit), then where older ones are.
pub fn render(a: std.mem.Allocator, io: Io, path: []const u8, found: Found, terms: []const Term, utc_offset: i32, max_bytes: usize, scope: Scope) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (found.hits.len == 0) {
        var said: std.ArrayList(u8) = .empty;
        for (terms, 0..) |tm, i| try said.print(a, "{s}{s}", .{ if (i > 0) " " else "", tm.text });
        try out.print(a, "No turn has all of: {s}.", .{said.items});
    } else {
        var f = try Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        try out.print(a, "{d} turn{s}, newest first (the owner's time):\n", .{ found.hits.len, if (found.hits.len == 1) "" else "s" });
        const title_len = out.items.len;
        var shown: usize = 0;
        var oldest: i64 = 0;
        for (found.hits) |h| {
            const part = try hitText(a, io, f, h, terms, utc_offset);
            // room for the line that says where the rest is
            if (max_bytes > 0 and out.items.len + part.text.len + 160 > max_bytes and shown > 0) break;
            try out.appendSlice(a, if (max_bytes > 0) util.cut(part.text, max_bytes -| 160) else part.text);
            shown += 1;
            oldest = part.start_s;
        }
        if (shown < found.hits.len) {
            const title = try std.fmt.allocPrint(a, "{d} of the turns found, newest first (the owner's time):\n", .{shown});
            try out.replaceRange(a, 0, title_len, title);
        }
        if (shown < found.hits.len or found.more) {
            var tb: [20]u8 = undefined;
            try out.print(a, "\nMore turns match. For older ones: before = {s}.", .{localStamp(&tb, oldest, utc_offset, true)});
        }
    }
    if (!scope.all) try out.print(a, "\nOnly {s} is searched from here.", .{scope.conversation});
    return out.items;
}

/// Run `rid` step by step (the session view, at most `max_bytes`), if the
/// scope holds it and it was not private.
pub fn runView(a: std.mem.Allocator, io: Io, path: []const u8, scope: Scope, rid: u64, max_bytes: usize) ![]const u8 {
    const none = if (scope.all)
        try std.fmt.allocPrint(a, "No run {d} in the log.", .{rid})
    else
        try std.fmt.allocPrint(a, "No run {d} in {s}.", .{ rid, scope.conversation });
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return none,
        else => return e,
    };
    defer f.close(io);
    const len = try f.length(io);
    const off = try seekLine(io, f, len, @intCast(@min(rid, std.math.maxInt(i63))), seqKey);
    if (off >= len) return none;
    const n: usize = @intCast(@min(len - off, view_window));
    const buf = try a.alloc(u8, n);
    var text = buf[0..try f.readPositionalAll(io, buf, off)];
    if (off + text.len < len) text = text[0 .. (std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0) + 1];
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (seqOf(first) != rid or intField(head(first), "rid") != rid) return none;
    if (!scope.all) {
        const conv = rawField(head(first), "conversation") orelse return none;
        if (!std.mem.eql(u8, conv, scope.conversation)) return none;
    }
    // a private run's line keeps sizes and hashes, not what was said
    if (std.mem.indexOf(u8, first, "\":{\"bytes\":") != null) return std.fmt.allocPrint(a, "Run {d} is private: what was said in it is not in the log.", .{rid});
    return (try session.render(a, text, rid, max_bytes)) orelse none;
}

const t = std.testing;

/// Log lines as harness writes them, at times a test picks.
const Lines = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    seq: u64 = 0,

    /// A run's first line, a turn with its message: the run's id.
    fn start(l: *Lines, time: []const u8, conv: []const u8, label: []const u8, by: []const u8, text: []const u8) !u64 {
        l.seq += 1;
        try l.out.print(l.a, "{{\"seq\":{d},\"time\":\"{s}\",\"kind\":\"turn\",\"rid\":{d},\"conversation\":\"{s}\",\"run\":\"{s}\",\"by\":\"{s}\",\"agent\":\"main\",\"text\":{s}", .{ l.seq, time, l.seq, conv, label, by, try l.js(text) });
        try l.close();
        return l.seq;
    }

    /// A later line of run `rid`: its kind, then `fields` (JSON, from a comma).
    fn add(l: *Lines, time: []const u8, rid: u64, conv: []const u8, kind: []const u8, fields: []const u8) !void {
        l.seq += 1;
        try l.out.print(l.a, "{{\"seq\":{d},\"time\":\"{s}\",\"kind\":\"{s}\",\"rid\":{d},\"conversation\":\"{s}\",\"run\":\"chat\"{s}", .{ l.seq, time, kind, rid, conv, fields });
        try l.close();
    }

    /// A line of no run.
    fn other(l: *Lines, time: []const u8) !void {
        l.seq += 1;
        try l.out.print(l.a, "{{\"seq\":{d},\"time\":\"{s}\",\"kind\":\"config\",\"event\":\"settings files changed\"", .{ l.seq, time });
        try l.close();
    }

    fn close(l: *Lines) !void {
        const zeros: [64]u8 = @splat('0');
        try l.out.print(l.a, ",\"prev\":\"{s}\"}}\n", .{&zeros});
    }

    fn js(l: *Lines, s: []const u8) ![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        try util.jsonString(&o, l.a, s);
        return o.items;
    }

    fn post(l: *Lines, time: []const u8, rid: u64, conv: []const u8, text: []const u8) !void {
        try l.add(time, rid, conv, "send", try std.fmt.allocPrint(l.a, ",\"to\":\"{s}\",\"event\":\"sent\",\"bytes\":{d},\"text\":{s},\"final\":true,\"implicit\":false,\"delivered\":true", .{ conv, text.len, try l.js(text) }));
    }

    fn tool(l: *Lines, time: []const u8, rid: u64, conv: []const u8, name: []const u8, arg: []const u8, output: []const u8) !void {
        try l.add(time, rid, conv, "tool", try std.fmt.allocPrint(l.a, ",\"agent\":\"main\",\"tool\":\"{s}\",\"arg\":{s},\"is_error\":false,\"output\":{s},\"bytes\":{d}", .{ name, try l.js(arg), try l.js(output), output.len }));
    }

    fn save(l: *Lines, tmp: *t.TmpDir) ![]const u8 {
        try tmp.dir.writeFile(t.io, .{ .sub_path = "actions.jsonl", .data = l.out.items });
        const dir = try tmp.dir.realPathFileAlloc(t.io, ".", l.a);
        return std.fs.path.join(l.a, &.{ dir, "actions.jsonl" });
    }
};

/// The runs a search finds, newest first, are `want`.
fn expectHits(a: std.mem.Allocator, path: []const u8, scope: Scope, q: Query, want: []const u64) !void {
    const found = try search(a, t.io, path, scope, q);
    var got: std.ArrayList(u64) = .empty;
    for (found.hits) |h| try got.append(a, h.rid);
    if (!std.mem.eql(u64, got.items, want)) std.debug.print("got {any}, want {any}\n", .{ got.items, want });
    try t.expectEqualSlices(u64, want, got.items);
}

fn words(a: std.mem.Allocator, w: []const u8) !Query {
    return .{ .terms = try parseTerms(a, w) };
}

fn expectIn(text: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, text, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, text });
    try t.expect(std.mem.indexOf(u8, text, want) != null);
}

test "history_finds_old_turns_by_words_and_phrase" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: Lines = .{ .a = a };
    // the words spread over the owner's message, a tool's result and the reply
    const flats = try l.start("2026-11-02T09:00:00Z", "main", "chat", "owner", "Find flats in Zurich");
    try l.tool("2026-11-02T09:00:05Z", flats, "main", "fetch", "https://flats.example/zurich", "Seefeld: 2,800 CHF, balcony");
    try l.post("2026-11-02T09:00:09Z", flats, "main", "Three flats match; the Seefeld one has a BALCONY.");
    const weather = try l.start("2026-11-03T10:00:00Z", "main", "chat", "owner", "Zurich weather tomorrow?");
    try l.post("2026-11-03T10:00:04Z", weather, "main", "Rain in Zurich.");
    const flight = try l.start("2026-11-04T08:00:00Z", "house-search", "chat", "owner", "When do I fly?");
    try l.post("2026-11-04T08:00:03Z", flight, "house-search", "Your flight to Oslo leaves at 9.");
    const prices = try l.start("2026-11-05T08:00:00Z", "main", "chat", "owner", "Compare Oslo prices for a flight");
    const path = try l.save(&tmp);
    const all: Scope = .{ .all = true, .conversation = "main" };
    // every word, in any case, anywhere in the run
    try expectHits(a, path, all, try words(a, "zurich FLATS balcony"), &.{flats});
    // part of a word counts; newest first
    try expectHits(a, path, all, try words(a, "zuri"), &.{ weather, flats });
    // a phrase as it was written; its words alone in any order
    try expectHits(a, path, all, try words(a, "\"flight to oslo\""), &.{flight});
    try expectHits(a, path, all, try words(a, "\u{201c}Flight to Oslo\u{201d}"), &.{flight});
    try expectHits(a, path, all, try words(a, "oslo flight"), &.{ prices, flight });
    // a word missing from the turn, or only in a label, finds nothing
    try expectHits(a, path, all, try words(a, "zurich oslo"), &.{});
    for ([_][]const u8{ "owner", "chat", "fetch", "turn", "sent" }) |w| try expectHits(a, path, all, try words(a, w), &.{});
    // shown with its date (the owner's time), conversation and run: what
    // was said, and the result the word is in
    const terms = try parseTerms(a, "balcony");
    const shown = try render(a, t.io, path, try search(a, t.io, path, all, .{ .terms = terms }), terms, 60, max_view, all);
    for ([_][]const u8{
        "2026-11-02 10:00, main, run 1 (chat)\n",
        "Owner: Find flats in Zurich\n",
        "fetch https://flats.example/zurich: Seefeld: 2,800 CHF, balcony\n",
        "Agent: Three flats match; the Seefeld one has a BALCONY.\n",
    }) |want| try expectIn(shown, want);
    // nothing found says so
    const none = try render(a, t.io, path, try search(a, t.io, path, all, try words(a, "kayak")), try parseTerms(a, "kayak"), 0, max_view, all);
    try expectIn(none, "No turn has all of: kayak");
}

test "history_shows_20_turns_and_where_the_older_ones_are" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: Lines = .{ .a = a };
    var rids: [25]u64 = undefined;
    for (&rids, 0..) |*r, i| {
        const time = try std.fmt.allocPrint(a, "2026-11-01T10:{d:0>2}:00Z", .{i});
        r.* = try l.start(time, "main", "chat", "owner", try std.fmt.allocPrint(a, "Kayak trip, day {d}", .{i}));
        try l.other(time);
    }
    const path = try l.save(&tmp);
    const all: Scope = .{ .all = true, .conversation = "main" };
    const found = try search(a, t.io, path, all, try words(a, "kayak"));
    try t.expectEqual(20, found.hits.len);
    try t.expect(found.more);
    try t.expectEqual(rids[24], found.hits[0].rid);
    try t.expectEqual(rids[5], found.hits[19].rid);
    // where the rest are
    const terms = try parseTerms(a, "kayak");
    const shown = try render(a, t.io, path, found, terms, 0, max_view, all);
    try expectIn(shown, "20 turns, newest first");
    try expectIn(shown, "More turns match. For older ones: before = 2026-11-01 10:05:00.");
    // before: only the older ones
    var q = try words(a, "kayak");
    q.before_s = parseBefore("2026-11-01 10:05:00", 0).?;
    try expectHits(a, path, all, q, &.{ rids[4], rids[3], rids[2], rids[1], rids[0] });
    try t.expect(!(try search(a, t.io, path, all, q)).more);
    // a date alone is its start, in the owner's time
    try t.expectEqual(util.daysFromCivil(2026, 11, 2) * 86400 - 3600, parseBefore("2026-11-02", 60).?);
    try t.expectEqual(null, parseBefore("2026-13-02", 0));
    try t.expectEqual(null, parseBefore("yesterday", 0));
    // an answer cut to a size says the same
    const short = try render(a, t.io, path, found, terms, 0, 1000, all);
    try t.expect(short.len <= 1000);
    try expectIn(short, "More turns match. For older ones: before = ");
}

test "search_keeps_to_its_scope" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: Lines = .{ .a = a };
    // harness 0.3's line, before conversations
    l.seq += 1;
    const legacy = l.seq;
    try l.out.print(a, "{{\"seq\":{d},\"time\":\"2026-10-01T09:00:00Z\",\"kind\":\"turn\",\"rid\":{d},\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"main\",\"text\":\"old flats talk\"", .{ legacy, legacy });
    try l.close();
    const main_run = try l.start("2026-11-02T09:00:00Z", "main", "chat", "owner", "flats in Zurich");
    const house = try l.start("2026-11-02T10:00:00Z", "house-search", "chat", "owner", "flats in Basel");
    const family = try l.start("2026-11-02T11:00:00Z", "family", "task digest", "schedule:digest", "Post the flats for the family");
    // a private run: its words are not in the log
    l.seq += 1;
    try l.out.print(a, "{{\"seq\":{d},\"time\":\"2026-11-02T12:00:00Z\",\"kind\":\"turn\",\"rid\":{d},\"conversation\":\"diary\",\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"main\",\"text\":{{\"bytes\":21,\"hmac\":\"{s}\"}}", .{ l.seq, l.seq, "abababababababababababababababababababababababababababababababab" });
    try l.close();
    // what history itself answered is not searched again
    const asked = try l.start("2026-11-02T13:00:00Z", "main", "chat", "owner", "what did we say?");
    try l.tool("2026-11-02T13:00:01Z", asked, "main", "history", "flats", "2026-11-02 09:00, main, run 2 (chat)\nOwner: flats in Zurich");
    const path = try l.save(&tmp);
    // the owner's own runs: every conversation, and 0.3's lines
    const all: Scope = .{ .all = true, .conversation = "main" };
    try expectHits(a, path, all, try words(a, "flats"), &.{ family, house, main_run, legacy });
    // a conversation asked for
    var q = try words(a, "flats");
    q.conversation = "house-search";
    try expectHits(a, path, all, q, &.{house});
    // a run that may see only its own conversation
    try expectHits(a, path, .{ .all = false, .conversation = "family" }, try words(a, "flats"), &.{family});
    try expectHits(a, path, .{ .all = false, .conversation = "family" }, q, &.{});
    // a hash is not words
    try expectHits(a, path, all, try words(a, "abab"), &.{});
    try expectHits(a, path, all, try words(a, "bytes"), &.{});
    // a scheduled run's instruction is shown as one
    const terms = try parseTerms(a, "family");
    const shown = try render(a, t.io, path, try search(a, t.io, path, all, .{ .terms = terms }), terms, 0, max_view, all);
    try expectIn(shown, "2026-11-02 11:00, family, run 4 (task digest)\nInstruction: Post the flats for the family\n");
    // where only one conversation is searched, the answer says so
    const one = try render(a, t.io, path, try search(a, t.io, path, .{ .all = false, .conversation = "family" }, .{ .terms = try parseTerms(a, "zurich") }), try parseTerms(a, "zurich"), 0, max_view, .{ .all = false, .conversation = "family" });
    try expectIn(one, "Only family is searched from here.");
}

test "history_run_returns_its_session" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: Lines = .{ .a = a };
    // enough before it that the run is looked up, not read from the start
    for (0..3000) |_| try l.other("2026-11-01T08:00:00Z");
    const long = try l.start("2026-11-02T09:00:00Z", "main", "chat", "owner", "check every server");
    for (0..400) |i| try l.tool("2026-11-02T09:00:01Z", long, "main", "shell", try std.fmt.allocPrint(a, "ping -c 1 server-{d}.example.org", .{i}), "1 packets transmitted, 1 received");
    try l.post("2026-11-02T09:05:00Z", long, "main", "All 400 answer.");
    const small = try l.start("2026-11-02T10:00:00Z", "family", "task digest", "schedule:digest", "Post the digest");
    try l.post("2026-11-02T10:00:02Z", small, "family", "Today's digest: two new flats.");
    l.seq += 1;
    const private = l.seq;
    try l.out.print(a, "{{\"seq\":{d},\"time\":\"2026-11-02T11:00:00Z\",\"kind\":\"turn\",\"rid\":{d},\"conversation\":\"diary\",\"run\":\"chat\",\"by\":\"owner\",\"agent\":\"main\",\"text\":{{\"bytes\":21,\"hmac\":\"{s}\"}}", .{ private, private, "abababababababababababababababababababababababababababababababab" });
    try l.close();
    for (0..10) |_| try l.other("2026-11-02T12:00:00Z");
    const path = try l.save(&tmp);
    const all: Scope = .{ .all = true, .conversation = "main" };
    // its steps, cut to 16 KB with where the rest is
    const view = try runView(a, t.io, path, all, long, max_view);
    try t.expect(view.len <= max_view);
    try t.expect(std.mem.startsWith(u8, view, try std.fmt.allocPrint(a, "Run {d}: chat, by owner, in main, 2026-11-02T09:00:00Z\nOwner: check every server\n", .{long})));
    try expectIn(view, "shell ping -c 1 server-0.example.org: ok, 33 bytes\n");
    try t.expect(std.mem.endsWith(u8, view, try std.fmt.allocPrint(a, "harness log session {d} shows all", .{long})));
    const whole = try runView(a, t.io, path, all, small, max_view);
    try expectIn(whole, "Posted to family: Today's digest: two new flats. (final)\n");
    // a run this one may not see is not there for it
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "No run {d} in family.", .{long}), try runView(a, t.io, path, .{ .all = false, .conversation = "family" }, long, max_view));
    try expectIn(try runView(a, t.io, path, .{ .all = false, .conversation = "family" }, small, max_view), "Posted to family");
    // a private run kept no words
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "Run {d} is private: what was said in it is not in the log.", .{private}), try runView(a, t.io, path, all, private, max_view));
    try t.expectEqualStrings("No run 99999 in the log.", try runView(a, t.io, path, all, 99999, max_view));
    try t.expectEqualStrings("No run 3 in the log.", try runView(a, t.io, path, all, 3, max_view));
}

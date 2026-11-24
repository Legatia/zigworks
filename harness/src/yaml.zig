//! A small reader for the YAML Hermes writes (`config.yaml`, skills'
//! frontmatter): block mappings and sequences, plain, single- and
//! double-quoted scalars, `|` and `>` blocks, and flow lists and maps
//! written on one line (`["-y", "x"]`, `{a: b}`). Anchors, aliases, tags
//! and flow collections over several lines are not read: they are an
//! error at their line, never guessed. `topBlocks` lets a caller read a
//! file's top-level keys one at a time, so a part it can't read stops
//! only that key.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Str = struct { text: []const u8, quoted: bool = false };
pub const Entry = struct { key: []const u8, value: Value, line: usize };
pub const Value = union(enum) {
    null,
    str: Str,
    seq: []const Value,
    map: []const Entry,
};

/// Where a text does not read: its line (1-based) and why.
pub const Diag = struct { line: usize = 0, why: []const u8 = "" };
pub const Error = error{ BadYaml, OutOfMemory };

/// A top-level key's lines: from its own (1-based) to the line before the
/// next top-level key.
pub const Block = struct { key: []const u8, first: usize, last: usize };

/// The value of `key` in map `v`; null when `v` is not a map or has none
/// (the last such key counts, as YAML readers keep it).
pub fn get(v: ?Value, key: []const u8) ?Value {
    const m = v orelse return null;
    if (m != .map) return null;
    var found: ?Value = null;
    for (m.map) |e| if (std.mem.eql(u8, e.key, key)) {
        found = e.value;
    };
    return found;
}

/// The line a key of map `v` is on; 0 when it has none.
pub fn lineOf(v: ?Value, key: []const u8) usize {
    const m = v orelse return 0;
    if (m != .map) return 0;
    for (m.map) |e| if (std.mem.eql(u8, e.key, key)) return e.line;
    return 0;
}

/// A scalar's text; null for a list, a map or nothing.
pub fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .str => |s| s.text,
        else => null,
    };
}

/// A list's items; a scalar is a list of one (Hermes takes either); none for the rest.
pub fn list(a: Allocator, v: ?Value) ![]const Value {
    const x = v orelse return &.{};
    return switch (x) {
        .seq => |s| s,
        .str => blk: {
            const one = try a.alloc(Value, 1);
            one[0] = x;
            break :blk one;
        },
        else => &.{},
    };
}

/// Hermes's reading of a yes-or-no: true, yes, on, 1 / false, no, off, 0
/// (any case); anything else, or nothing, is `default`.
pub fn boolish(v: ?Value, default: bool) bool {
    const s = std.mem.trim(u8, str(v) orelse return default, " \t");
    for ([_][]const u8{ "true", "yes", "on", "1", "y" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    for ([_][]const u8{ "false", "no", "off", "0", "n" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return false;
    return default;
}

const Line = struct {
    n: usize,
    indent: usize,
    /// The line past its indent, `\r` and trailing spaces off.
    text: []const u8,
};

const Parser = struct {
    a: Allocator,
    lines: []Line,
    i: usize = 0,
    diag: *Diag,

    fn fail(p: *Parser, n: usize, why: []const u8) Error {
        p.diag.* = .{ .line = n, .why = why };
        return error.BadYaml;
    }

    /// The next line that holds something (not blank, not a comment).
    fn peek(p: *Parser) ?*Line {
        while (p.i < p.lines.len) : (p.i += 1) {
            const l = &p.lines[p.i];
            if (l.text.len == 0 or l.text[0] == '#') continue;
            return l;
        }
        return null;
    }

    fn node(p: *Parser, indent: usize) Error!Value {
        const l = p.peek() orelse return .null;
        if (isItem(l.text)) return p.seq(l.indent);
        if (keyEnd(l.text) != null) return p.map(l.indent);
        _ = indent;
        // a scalar alone on its line(s)
        p.i += 1;
        const v = try p.inline_(l, l.text, l.indent);
        if (p.peek()) |next| if (next.indent > l.indent) return p.fail(next.n, "a value goes on with more indent; only one line is read");
        return v;
    }

    fn map(p: *Parser, indent: usize) Error!Value {
        var out: std.ArrayList(Entry) = .empty;
        while (p.peek()) |l| {
            if (l.indent < indent) break;
            if (l.indent > indent) return p.fail(l.n, "more indent than the keys before it");
            if (isItem(l.text)) break;
            const end = keyEnd(l.text) orelse return p.fail(l.n, "not a key: value line");
            const key = try p.keyText(l, l.text[0..end]);
            const rest = stripComment(std.mem.trim(u8, l.text[end + 1 ..], " \t"));
            p.i += 1;
            var v: Value = .null;
            if (rest.len == 0) {
                if (p.peek()) |next| {
                    if (next.indent > indent) {
                        v = try p.node(next.indent);
                    } else if (next.indent == indent and isItem(next.text)) {
                        // a list under a key may start at the key's own indent
                        v = try p.seq(indent);
                    }
                }
            } else v = try p.inline_(l, rest, indent);
            try out.append(p.a, .{ .key = key, .value = v, .line = l.n });
        }
        return .{ .map = out.items };
    }

    fn seq(p: *Parser, indent: usize) Error!Value {
        var out: std.ArrayList(Value) = .empty;
        while (p.peek()) |l| {
            if (l.indent < indent) break;
            if (l.indent > indent) return p.fail(l.n, "more indent than the items before it");
            if (!isItem(l.text)) break;
            const after = std.mem.trimStart(u8, l.text[1..], " ");
            if (after.len == 0 or after[0] == '#') {
                p.i += 1;
                const next = p.peek();
                if (next != null and next.?.indent > indent) {
                    try out.append(p.a, try p.node(next.?.indent));
                } else try out.append(p.a, .null);
                continue;
            }
            // the item's own text, read as a line at its column ("- k: v" starts a map there)
            const col = l.indent + (l.text.len - after.len);
            l.indent = col;
            l.text = after;
            if (isItem(after) or keyEnd(after) != null) {
                try out.append(p.a, try p.node(col));
            } else {
                p.i += 1;
                try out.append(p.a, try p.inline_(l, stripComment(after), indent));
            }
        }
        return .{ .seq = out.items };
    }

    /// A key, quotes taken off.
    fn keyText(p: *Parser, l: *const Line, raw: []const u8) Error![]const u8 {
        const k = std.mem.trim(u8, raw, " \t");
        if (k.len > 0 and (k[0] == '"' or k[0] == '\'')) {
            var pos: usize = 0;
            const s = try p.quoted(l, k, &pos);
            return s;
        }
        if (k.len > 0 and (k[0] == '&' or k[0] == '*' or k[0] == '!' or k[0] == '?')) return p.fail(l.n, "anchors, aliases, tags and complex keys are not read");
        return k;
    }

    /// A value written on its key's or item's line: a block scalar (its
    /// lines follow, past `parent`'s indent), a flow list or map, or a scalar.
    fn inline_(p: *Parser, l: *const Line, text: []const u8, parent: usize) Error!Value {
        const c = text[0];
        if (c == '|' or c == '>') return p.block(l, text, parent);
        if (c == '&' or c == '*' or c == '!') return p.fail(l.n, "anchors, aliases and tags are not read");
        if (c == '[' or c == '{') {
            var pos: usize = 0;
            const v = try p.flow(l, text, &pos);
            const left = std.mem.trim(u8, text[pos..], " \t");
            if (left.len > 0) return p.fail(l.n, "a flow list or map ends its line (one written over several lines is not read)");
            return v;
        }
        if (c == '"' or c == '\'') {
            var pos: usize = 0;
            const s = try p.quoted(l, text, &pos);
            const left = stripComment(std.mem.trim(u8, text[pos..], " \t"));
            if (left.len > 0) return p.fail(l.n, "text after a quoted value");
            return .{ .str = .{ .text = s, .quoted = true } };
        }
        return plain(text);
    }

    fn block(p: *Parser, l: *const Line, head: []const u8, parent: usize) Error!Value {
        const folded = head[0] == '>';
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit: ?usize = null;
        for (stripComment(head[1..])) |ch| switch (ch) {
            '-' => chomp = .strip,
            '+' => chomp = .keep,
            '1'...'9' => explicit = ch - '0',
            ' ', '\t' => {},
            else => return p.fail(l.n, "a block scalar's header is | or > with - or + and a number"),
        };
        // its lines: blank ones, and those indented past the parent
        const start = p.i;
        var end = p.i;
        var ind: ?usize = if (explicit) |e| parent + e else null;
        while (end < p.lines.len) : (end += 1) {
            const x = p.lines[end];
            if (x.text.len == 0) continue;
            if (x.indent <= parent) break;
            if (ind == null) ind = x.indent;
            if (x.indent < ind.?) break;
        }
        // trailing blank lines past the last line with text are the block's too (for keep)
        var last_text = start;
        var k = start;
        while (k < end) : (k += 1) if (p.lines[k].text.len > 0) {
            last_text = k + 1;
        };
        var out: std.ArrayList(u8) = .empty;
        const bi = ind orelse parent + 1;
        var prev_blank = true;
        k = start;
        while (k < last_text) : (k += 1) {
            const x = p.lines[k];
            if (x.text.len == 0) {
                // folded: the break after a text line becomes this one newline
                if (!(folded and !prev_blank and out.items.len > 0)) try out.append(p.a, '\n');
                prev_blank = true;
                continue;
            }
            // more indent than the block's is kept as text
            const extra = x.indent - bi;
            if (folded and out.items.len > 0 and !prev_blank and extra == 0) {
                out.items[out.items.len - 1] = ' ';
            }
            try out.appendNTimes(p.a, ' ', extra);
            try out.appendSlice(p.a, x.text);
            try out.append(p.a, '\n');
            prev_blank = extra > 0;
        }
        p.i = end;
        switch (chomp) {
            .strip => while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
                out.items.len -= 1;
            },
            .clip => {
                while (out.items.len > 1 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') out.items.len -= 1;
            },
            .keep => {
                var b = last_text;
                while (b < end) : (b += 1) try out.append(p.a, '\n');
            },
        }
        return .{ .str = .{ .text = out.items, .quoted = true } };
    }

    fn quoted(p: *Parser, l: *const Line, text: []const u8, pos: *usize) Error![]const u8 {
        const q = text[pos.*];
        var out: std.ArrayList(u8) = .empty;
        var i = pos.* + 1;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (q == '\'') {
                if (ch == '\'') {
                    if (i + 1 < text.len and text[i + 1] == '\'') {
                        try out.append(p.a, '\'');
                        i += 1;
                        continue;
                    }
                    pos.* = i + 1;
                    return out.items;
                }
                try out.append(p.a, ch);
                continue;
            }
            if (ch == '"') {
                pos.* = i + 1;
                return out.items;
            }
            if (ch != '\\') {
                try out.append(p.a, ch);
                continue;
            }
            i += 1;
            if (i >= text.len) break;
            switch (text[i]) {
                'n' => try out.append(p.a, '\n'),
                't' => try out.append(p.a, '\t'),
                'r' => try out.append(p.a, '\r'),
                '0' => try out.append(p.a, 0),
                '"', '\\', '/', ' ' => try out.append(p.a, text[i]),
                'x', 'u', 'U' => {
                    const width: usize = switch (text[i]) {
                        'x' => 2,
                        'u' => 4,
                        else => 8,
                    };
                    if (i + width >= text.len) return p.fail(l.n, "a \\x, \\u or \\U escape needs its digits");
                    const cp = std.fmt.parseInt(u21, text[i + 1 .. i + 1 + width], 16) catch return p.fail(l.n, "a \\x, \\u or \\U escape needs its digits");
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return p.fail(l.n, "an escape that is no character");
                    try out.appendSlice(p.a, buf[0..len]);
                    i += width;
                },
                else => return p.fail(l.n, "an escape YAML does not have"),
            }
        }
        return p.fail(l.n, "a quoted value not closed on its line (one over several lines is not read)");
    }

    fn flow(p: *Parser, l: *const Line, text: []const u8, pos: *usize) Error!Value {
        const open = text[pos.*];
        const close: u8 = if (open == '[') ']' else '}';
        pos.* += 1;
        var items: std.ArrayList(Value) = .empty;
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            skipSpaces(text, pos);
            if (pos.* >= text.len) return p.fail(l.n, "a flow list or map not closed on its line (one over several lines is not read)");
            if (text[pos.*] == close) {
                pos.* += 1;
                break;
            }
            if (open == '{') {
                const key = try p.flowScalar(l, text, pos, true);
                skipSpaces(text, pos);
                if (pos.* >= text.len or text[pos.*] != ':') return p.fail(l.n, "a flow map's entry is key: value");
                pos.* += 1;
                skipSpaces(text, pos);
                const v = if (pos.* < text.len and (text[pos.*] == ',' or text[pos.*] == '}')) Value.null else try p.flowValue(l, text, pos);
                try entries.append(p.a, .{ .key = str(key) orelse "", .value = v, .line = l.n });
            } else try items.append(p.a, try p.flowValue(l, text, pos));
            skipSpaces(text, pos);
            if (pos.* < text.len and text[pos.*] == ',') {
                pos.* += 1;
                continue;
            }
            if (pos.* < text.len and text[pos.*] == close) continue;
            return p.fail(l.n, "a flow list or map's items are separated by commas");
        }
        return if (open == '[') .{ .seq = items.items } else .{ .map = entries.items };
    }

    fn flowValue(p: *Parser, l: *const Line, text: []const u8, pos: *usize) Error!Value {
        if (text[pos.*] == '[' or text[pos.*] == '{') return p.flow(l, text, pos);
        return p.flowScalar(l, text, pos, false);
    }

    fn flowScalar(p: *Parser, l: *const Line, text: []const u8, pos: *usize, is_key: bool) Error!Value {
        const c = text[pos.*];
        if (c == '"' or c == '\'') return .{ .str = .{ .text = try p.quoted(l, text, pos), .quoted = true } };
        if (c == '&' or c == '*' or c == '!') return p.fail(l.n, "anchors, aliases and tags are not read");
        const start = pos.*;
        while (pos.* < text.len) : (pos.* += 1) {
            const ch = text[pos.*];
            if (ch == ',' or ch == ']' or ch == '}') break;
            if (is_key and ch == ':') break;
            if (ch == ':' and (pos.* + 1 >= text.len or text[pos.* + 1] == ' ')) break;
        }
        return plain(std.mem.trim(u8, text[start..pos.*], " \t"));
    }
};

fn skipSpaces(text: []const u8, pos: *usize) void {
    while (pos.* < text.len and (text[pos.*] == ' ' or text[pos.*] == '\t')) pos.* += 1;
}

/// A plain scalar: `~`, `null` and nothing are null; the rest is text.
fn plain(text: []const u8) Value {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0 or std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL")) return .null;
    return .{ .str = .{ .text = s } };
}

/// Text before a ` #` comment (outside quotes the caller already took off).
fn stripComment(text: []const u8) []const u8 {
    if (text.len > 0 and text[0] == '#') return "";
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single and (i == 0 or text[i - 1] != '\\')) in_double = !in_double;
        if (c == '#' and !in_single and !in_double and i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) return std.mem.trimEnd(u8, text[0..i], " \t");
    }
    return text;
}

fn isItem(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ' or text[1] == '\t');
}

/// Where the `:` that ends a key is (a `:` followed by a space or the end
/// of the line, outside quotes), or null when the line is no key line.
fn keyEnd(text: []const u8) ?usize {
    if (text.len == 0 or isItem(text)) return null;
    if (text[0] == '[' or text[0] == '{' or text[0] == '|' or text[0] == '>') return null;
    var i: usize = 0;
    if (text[0] == '"' or text[0] == '\'') {
        const q = text[0];
        i = 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and q == '"') {
                i += 1;
                continue;
            }
            if (text[i] == q) {
                if (q == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                break;
            }
        }
        if (i >= text.len) return null;
        i += 1;
        while (i < text.len and text[i] == ' ') i += 1;
        if (i < text.len and text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\t')) return i;
        return null;
    }
    while (i < text.len) : (i += 1) {
        if (text[i] == '#' and i > 0 and text[i - 1] == ' ') return null;
        if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ' or text[i + 1] == '\t')) return i;
    }
    return null;
}

/// The lines of `text` from `first` to `last` (1-based, inclusive), a
/// document's `---` and `...` lines left out; error.BadYaml for a tab
/// in an indent.
fn splitLines(a: Allocator, text: []const u8, first: usize, last: usize, diag: *Diag) Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw0| {
        n += 1;
        if (n < first) continue;
        if (n > last) break;
        var raw = std.mem.trimEnd(u8, raw0, "\r");
        // a UTF-8 BOM before the first line
        if (n == 1) raw = std.mem.trimStart(u8, raw, "\xEF\xBB\xBF");
        var ind: usize = 0;
        while (ind < raw.len and raw[ind] == ' ') ind += 1;
        const body = std.mem.trimEnd(u8, raw[ind..], " \t");
        if (body.len > 0 and body[0] == '\t') {
            diag.* = .{ .line = n, .why = "a tab in an indent (YAML takes spaces)" };
            return error.BadYaml;
        }
        if (ind == 0 and (std.mem.eql(u8, body, "---") or std.mem.eql(u8, body, "..."))) {
            try out.append(a, .{ .n = n, .indent = 0, .text = "" });
            continue;
        }
        try out.append(a, .{ .n = n, .indent = ind, .text = body });
    }
    return out.items;
}

/// Reads a whole YAML text: its value (a map, usually), or error.BadYaml
/// with the line in `diag`.
pub fn parse(a: Allocator, text: []const u8, diag: *Diag) Error!Value {
    return parseLines(a, text, 1, std.math.maxInt(usize), diag);
}

/// Reads lines `first` to `last` (1-based, inclusive) of `text` alone.
pub fn parseLines(a: Allocator, text: []const u8, first: usize, last: usize, diag: *Diag) Error!Value {
    const lines = try splitLines(a, text, first, last, diag);
    var p: Parser = .{ .a = a, .lines = lines, .diag = diag };
    const first_line = p.peek() orelse return .null;
    const v = try p.node(first_line.indent);
    if (p.peek()) |left| return p.fail(left.n, "a line that belongs to nothing before it");
    return v;
}

/// The top-level keys of `text`, each with its lines, so each can be read
/// apart (`parseLines`).
pub fn topBlocks(a: Allocator, text: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw0| {
        n += 1;
        var raw = std.mem.trimEnd(u8, raw0, "\r");
        if (n == 1) raw = std.mem.trimStart(u8, raw, "\xEF\xBB\xBF");
        if (raw.len == 0 or raw[0] == ' ' or raw[0] == '#' or raw[0] == '\t') continue;
        const end = keyEnd(raw) orelse continue;
        if (out.items.len > 0) out.items[out.items.len - 1].last = n - 1;
        var key = std.mem.trim(u8, raw[0..end], " \t");
        if (key.len >= 2 and (key[0] == '"' or key[0] == '\'') and key[key.len - 1] == key[0]) key = key[1 .. key.len - 1];
        try out.append(a, .{ .key = key, .first = n, .last = std.math.maxInt(usize) });
    }
    return out.items;
}

// ---- tests ----

const t = std.testing;

fn read(a: Allocator, text: []const u8) !Value {
    var d: Diag = .{};
    return parse(a, text, &d) catch |e| {
        std.debug.print("line {d}: {s}\n", .{ d.line, d.why });
        return e;
    };
}

test "block_maps_sequences_and_scalars" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try read(a,
        \\# Hermes settings
        \\model:
        \\  provider: openrouter   # the default
        \\  default: anthropic/claude-sonnet-4
        \\mcp_servers:
        \\  github:
        \\    command: npx
        \\    args:
        \\      - -y
        \\      - "@modelcontextprotocol/server-github"
        \\    env:
        \\      GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_TOKEN}
        \\    enabled: false
        \\approvals:
        \\  deny:
        \\  - rm -rf /*
        \\  - "git push --force*"
        \\custom_providers:
        \\  - name: local
        \\    base_url: http://localhost:8080/v1
        \\  - name: other
        \\empty:
        \\nothing: ~
        \\url: https://example.com/a#frag
    );
    try t.expectEqualStrings("openrouter", str(get(get(v, "model"), "provider")).?);
    try t.expectEqual(3, lineOf(get(v, "model"), "provider"));
    const gh = get(get(v, "mcp_servers"), "github");
    try t.expectEqualStrings("npx", str(get(gh, "command")).?);
    const args = try list(a, get(gh, "args"));
    try t.expectEqual(2, args.len);
    try t.expectEqualStrings("-y", str(args[0]).?);
    try t.expectEqualStrings("@modelcontextprotocol/server-github", str(args[1]).?);
    try t.expect(args[1].str.quoted);
    try t.expectEqualStrings("${GITHUB_TOKEN}", str(get(get(gh, "env"), "GITHUB_PERSONAL_ACCESS_TOKEN")).?);
    try t.expect(!boolish(get(gh, "enabled"), true));
    const deny = try list(a, get(get(v, "approvals"), "deny"));
    try t.expectEqual(2, deny.len);
    try t.expectEqualStrings("rm -rf /*", str(deny[0]).?);
    try t.expectEqualStrings("git push --force*", str(deny[1]).?);
    const cps = try list(a, get(v, "custom_providers"));
    try t.expectEqual(2, cps.len);
    try t.expectEqualStrings("http://localhost:8080/v1", str(get(cps[0], "base_url")).?);
    try t.expectEqualStrings("other", str(get(cps[1], "name")).?);
    try t.expect(get(v, "empty").? == .null);
    try t.expect(get(v, "nothing").? == .null);
    try t.expectEqualStrings("https://example.com/a#frag", str(get(v, "url")).?);
    // a scalar where a list is taken is a list of one
    try t.expectEqual(1, (try list(a, get(get(v, "model"), "provider"))).len);
}

test "quoted_scalars_and_escapes" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try read(a,
        \\a: "line one\nline two \"quoted\" \\ \u00e9 \x41"
        \\b: 'it''s # not a comment'
        \\"c d": "x" # a comment
        \\e: plain words: with a colon
    );
    try t.expectEqualStrings("line one\nline two \"quoted\" \\ é A", str(get(v, "a")).?);
    try t.expectEqualStrings("it's # not a comment", str(get(v, "b")).?);
    try t.expectEqualStrings("x", str(get(v, "c d")).?);
    try t.expectEqualStrings("plain words: with a colon", str(get(v, "e")).?);
}

test "literal_and_folded_blocks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try read(a,
        \\lit: |
        \\  first line
        \\    indented
        \\
        \\  after a blank
        \\fold: >
        \\  one
        \\  two
        \\
        \\  three
        \\strip: |-
        \\  no newline
        \\keep: |+
        \\  kept
        \\
        \\next: x
    );
    try t.expectEqualStrings("first line\n  indented\n\nafter a blank\n", str(get(v, "lit")).?);
    try t.expectEqualStrings("one two\nthree\n", str(get(v, "fold")).?);
    try t.expectEqualStrings("no newline", str(get(v, "strip")).?);
    try t.expectEqualStrings("kept\n\n", str(get(v, "keep")).?);
    try t.expectEqualStrings("x", str(get(v, "next")).?);
}

test "flow_lists_and_maps" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try read(a,
        \\args: ["-y", 'x y', plain, [1, 2]]
        \\tools: {include: [a_*, b], exclude: []}
        \\empty: {}
    );
    const args = try list(a, get(v, "args"));
    try t.expectEqual(4, args.len);
    try t.expectEqualStrings("-y", str(args[0]).?);
    try t.expectEqualStrings("x y", str(args[1]).?);
    try t.expectEqualStrings("plain", str(args[2]).?);
    try t.expectEqual(2, (try list(a, args[3])).len);
    const inc = try list(a, get(get(v, "tools"), "include"));
    try t.expectEqual(2, inc.len);
    try t.expectEqualStrings("a_*", str(inc[0]).?);
    try t.expectEqual(0, (try list(a, get(get(v, "tools"), "exclude"))).len);
    try t.expectEqual(0, get(v, "empty").?.map.len);
}

test "crlf_reads_the_same" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try read(a, "\xEF\xBB\xBFmodel:\r\n  provider: anthropic\r\nlist:\r\n  - a\r\n  - b\r\ntext: |\r\n  one\r\n  two\r\n");
    try t.expectEqualStrings("anthropic", str(get(get(v, "model"), "provider")).?);
    try t.expectEqual(2, (try list(a, get(v, "list"))).len);
    try t.expectEqualStrings("one\ntwo\n", str(get(v, "text")).?);
}

test "an_unreadable_part_says_its_line" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { text: []const u8, line: usize }{
        .{ .text = "a: 1\nb: &anchor x\n", .line = 2 },
        .{ .text = "a: 1\nb: *alias\n", .line = 2 },
        .{ .text = "a:\n  - x\n  y: 2\n", .line = 3 },
        .{ .text = "a: [1,\n  2]\n", .line = 1 },
        .{ .text = "a: \"open\n", .line = 1 },
        .{ .text = "a:\n\t- x\n", .line = 2 },
        .{ .text = "a: !!str x\n", .line = 1 },
    }) |c| {
        var d: Diag = .{};
        try t.expectError(error.BadYaml, parse(a, c.text, &d));
        try t.expectEqual(c.line, d.line);
    }
}

test "top_level_blocks_are_read_apart" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\model: x
        \\plugins:
        \\  base: &b {a: 1}
        \\  more: *b
        \\mcp_servers:
        \\  s:
        \\    url: https://mcp.example.com/mcp
        \\# a comment
    ;
    const blocks = try topBlocks(a, text);
    try t.expectEqual(3, blocks.len);
    try t.expectEqualStrings("plugins", blocks[1].key);
    try t.expectEqual(2, blocks[1].first);
    try t.expectEqual(4, blocks[1].last);
    var d: Diag = .{};
    try t.expectError(error.BadYaml, parseLines(a, text, blocks[1].first, blocks[1].last, &d));
    try t.expectEqual(3, d.line);
    const m = try parseLines(a, text, blocks[2].first, blocks[2].last, &d);
    try t.expectEqualStrings("https://mcp.example.com/mcp", str(get(get(get(m, "mcp_servers"), "s"), "url")).?);
}

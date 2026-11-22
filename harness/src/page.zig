//! Readable text from web pages, paging of long texts, and rendering of
//! pages built by JavaScript in a headless Chrome or Chromium.
//!
//! The extractor works in three linear passes: a tolerant tokenizer, a
//! structure pass that matches every start tag to where it ends (closing
//! unclosed elements the way browsers mostly do) and picks the main
//! content, and a writer that turns the chosen tokens into text.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const jv = @import("jv.zig");
const url_mod = @import("url.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const is_windows = builtin.os.tag == .windows;

/// Longer input is cut to this before extracting.
pub const max_input = 4 << 20;

pub const Page = struct { title: []const u8, text: []const u8 };

/// Readable text from HTML. See the module notes and the tests for the
/// exact shape: headings as "# " lines, lists as "- " lines, tables one row
/// per line, links as [text](absolute url).
pub fn extract(arena: Allocator, html_in: []const u8, base_url: []const u8) !Page {
    const html = html_in[0..@min(html_in.len, max_input)];
    const toks = try tokenize(arena, html);
    const info = try structure(arena, toks);

    var base = base_url;
    if (info.base) |bi| if (attr(toks[bi].s, "href")) |raw| {
        if (try resolve(arena, base_url, try decodeAlloc(arena, raw))) |b| base = b;
    };

    var title: []const u8 = "";
    if (info.title) |ti| {
        var o: Out = .{ .a = arena, .inline_only = 1 };
        try o.text(toks[ti].s);
        title = o.buf.items;
    }
    if (title.len == 0) if (info.h1) |hi| {
        var o: Out = .{ .a = arena, .inline_only = 1 };
        try renderRange(&o, toks, hi + 1, toks[hi].end, base);
        title = o.buf.items;
    };

    var o: Out = .{ .a = arena };
    try renderRange(&o, toks, info.from, info.to, base);
    return .{ .title = title, .text = std.mem.trimEnd(u8, o.buf.items, " \n") };
}

// ---- tokens ----

const Tag = enum {
    other,
    a,
    address,
    area,
    article,
    aside,
    base,
    blockquote,
    body,
    br,
    button,
    caption,
    col,
    dd,
    details,
    dialog,
    div,
    dl,
    dt,
    embed,
    fieldset,
    figcaption,
    figure,
    footer,
    form,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    hgroup,
    hr,
    html,
    iframe,
    img,
    input,
    li,
    link,
    main,
    menu,
    meta,
    nav,
    noembed,
    noframes,
    noscript,
    ol,
    option,
    p,
    param,
    pre,
    script,
    section,
    select,
    source,
    style,
    summary,
    svg,
    table,
    tbody,
    td,
    template,
    textarea,
    tfoot,
    th,
    thead,
    title,
    tr,
    track,
    ul,
    wbr,
    xmp,
};

fn isVoid(tag: Tag) bool {
    return switch (tag) {
        .area, .base, .br, .col, .embed, .hr, .img, .input, .link, .meta, .param, .source, .track, .wbr => true,
        else => false,
    };
}

/// Dropped with everything inside. header and footer only when they are
/// the page's banner and footer, not inside an article, main or section
/// (there they hold its headline and byline).
fn isDrop(tag: Tag, in_section: bool) bool {
    return switch (tag) {
        .script, .style, .noscript, .template, .svg, .nav, .aside, .form, .iframe, .button, .select => true,
        .title, .textarea, .noembed, .noframes, .xmp => true,
        .header, .footer => !in_section,
        else => false,
    };
}

/// Elements whose content is not markup, with the tag that ends it.
fn rawCloser(tag: Tag) ?[]const u8 {
    return switch (tag) {
        .script => "</script",
        .style => "</style",
        .title => "</title",
        .textarea => "</textarea",
        .iframe => "</iframe",
        .noembed => "</noembed",
        .noframes => "</noframes",
        .xmp => "</xmp",
        else => null,
    };
}

/// Opening one of these closes an open <p> right above it.
fn closesP(tag: Tag) bool {
    return switch (tag) {
        .address, .article, .aside, .blockquote, .details, .dialog, .div, .dl, .fieldset, .figcaption, .figure, .footer, .form, .h1, .h2, .h3, .h4, .h5, .h6, .header, .hgroup, .hr, .main, .menu, .nav, .ol, .p, .pre, .section, .table, .ul, .li, .dd, .dt => true,
        else => false,
    };
}

const Kind = enum(u8) { start, end, text, raw };

const Token = struct {
    kind: Kind,
    tag: Tag = .other,
    self_close: bool = false,
    /// Set by `structure`: dropped with its content.
    drop: bool = false,
    /// Text, or the attribute source of a start tag.
    s: []const u8,
    /// Lowercase tag name.
    key: []const u8 = "",
    /// Start tags: index of the token where the element ends.
    end: u32 = 0,
};

/// Finds the next `c` at or after a position, remembering the last answer
/// so searches that fail don't rescan the rest of the input every time.
const Finder = struct {
    c: u8,
    from: usize = 0,
    at: ?usize = null,
    valid: bool = false,

    fn find(f: *Finder, h: []const u8, pos: usize) ?usize {
        if (f.valid and f.from <= pos) {
            if (f.at) |a| {
                if (pos <= a) return a;
            } else return null;
        }
        const r = std.mem.indexOfScalarPos(u8, h, pos, f.c);
        f.* = .{ .c = f.c, .from = pos, .at = r, .valid = true };
        return r;
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c';
}

fn lowerKey(a: Allocator, name: []const u8) ![]const u8 {
    for (name) |c| {
        if (std.ascii.isUpper(c)) return std.ascii.allocLowerString(a, name);
    }
    return name;
}

fn tagOf(key: []const u8) Tag {
    if (key.len > 12) return .other;
    return std.meta.stringToEnum(Tag, key) orelse .other;
}

fn tokenize(a: Allocator, html: []const u8) ![]Token {
    var toks: std.ArrayList(Token) = .empty;
    try toks.ensureTotalCapacity(a, html.len / 24 + 16);
    var dq: Finder = .{ .c = '"' };
    var sq: Finder = .{ .c = '\'' };
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < html.len) {
        if (html[i] != '<' or i + 1 >= html.len) {
            i += 1;
            continue;
        }
        const c = html[i + 1];
        const closing = c == '/' and i + 2 < html.len and std.ascii.isAlphabetic(html[i + 2]);
        if (!(c == '!' or c == '?' or closing or std.ascii.isAlphabetic(c))) {
            if (c == '/' and i + 2 < html.len and html[i + 2] == '>') {
                // "</>" is nothing
            } else {
                i += 1;
                continue;
            }
        }
        if (i > text_start) try toks.append(a, .{ .kind = .text, .s = html[text_start..i] });
        if (c == '!' and std.mem.startsWith(u8, html[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, html, i + 2, "-->")) |e| e + 3 else html.len;
        } else if (c == '!' or c == '?' or (c == '/' and !closing)) {
            i = if (std.mem.indexOfScalarPos(u8, html, i, '>')) |e| e + 1 else html.len;
        } else if (closing) {
            var j = i + 2;
            while (j < html.len and !isWs(html[j]) and html[j] != '/' and html[j] != '>') j += 1;
            const key = try lowerKey(a, html[i + 2 .. j]);
            try toks.append(a, .{ .kind = .end, .tag = tagOf(key), .s = "", .key = key });
            i = if (std.mem.indexOfScalarPos(u8, html, j, '>')) |e| e + 1 else html.len;
        } else {
            var j = i + 1;
            while (j < html.len and !isWs(html[j]) and html[j] != '/' and html[j] != '>') j += 1;
            const key = try lowerKey(a, html[i + 1 .. j]);
            const attrs_start = j;
            var self_close = false;
            var tag_end: usize = html.len; // the '>'
            var attrs_end: usize = html.len;
            while (j < html.len) {
                const ch = html[j];
                if (ch == '>') {
                    tag_end = j;
                    attrs_end = j;
                    break;
                }
                if (ch == '/') {
                    if (j + 1 < html.len and html[j + 1] == '>') {
                        self_close = true;
                        attrs_end = j;
                        tag_end = j + 1;
                        break;
                    }
                    j += 1;
                    continue;
                }
                if (ch == '=') {
                    j += 1;
                    while (j < html.len and isWs(html[j])) j += 1;
                    if (j < html.len and (html[j] == '"' or html[j] == '\'')) {
                        const f = if (html[j] == '"') &dq else &sq;
                        j = if (f.find(html, j + 1)) |q| q + 1 else (std.mem.indexOfScalarPos(u8, html, j, '>') orelse html.len);
                        continue;
                    }
                    while (j < html.len and !isWs(html[j]) and html[j] != '>') j += 1;
                    continue;
                }
                j += 1;
            }
            const tag = tagOf(key);
            try toks.append(a, .{ .kind = .start, .tag = tag, .self_close = self_close, .s = html[attrs_start..attrs_end], .key = key });
            i = if (tag_end < html.len) tag_end + 1 else html.len;
            if (!self_close) if (rawCloser(tag)) |closer| {
                const e = std.ascii.findIgnoreCasePos(html, i, closer) orelse html.len;
                if (e > i) try toks.append(a, .{ .kind = .raw, .s = html[i..e] });
                i = e;
            };
        }
        text_start = i;
    }
    if (html.len > text_start) try toks.append(a, .{ .kind = .text, .s = html[text_start..] });
    return toks.items;
}

// ---- attributes ----

const Attr = struct { name: []const u8, value: []const u8 };

const AttrIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *AttrIter) ?Attr {
        const s = it.s;
        while (true) {
            while (it.i < s.len and (isWs(s[it.i]) or s[it.i] == '/')) it.i += 1;
            if (it.i >= s.len) return null;
            const ns = it.i;
            while (it.i < s.len and !isWs(s[it.i]) and s[it.i] != '=' and s[it.i] != '/') it.i += 1;
            if (it.i == ns) {
                it.i += 1; // a stray '='
                continue;
            }
            const name = s[ns..it.i];
            var j = it.i;
            while (j < s.len and isWs(s[j])) j += 1;
            if (j >= s.len or s[j] != '=') return .{ .name = name, .value = "" };
            j += 1;
            while (j < s.len and isWs(s[j])) j += 1;
            if (j < s.len and (s[j] == '"' or s[j] == '\'')) {
                const q = s[j];
                const e = std.mem.indexOfScalarPos(u8, s, j + 1, q) orelse s.len;
                it.i = @min(e + 1, s.len);
                return .{ .name = name, .value = s[j + 1 .. e] };
            }
            const vs = j;
            while (j < s.len and !isWs(s[j])) j += 1;
            it.i = j;
            return .{ .name = name, .value = s[vs..j] };
        }
    }
};

/// Raw (not entity-decoded) value of an attribute; "" when it has none.
fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var it: AttrIter = .{ .s = attrs };
    while (it.next()) |at| if (std.ascii.eqlIgnoreCase(at.name, name)) return at.value;
    return null;
}

fn isHidden(attrs: []const u8) bool {
    if (attrs.len == 0) return false;
    var it: AttrIter = .{ .s = attrs };
    while (it.next()) |at| {
        if (std.ascii.eqlIgnoreCase(at.name, "hidden")) return true;
        if (std.ascii.eqlIgnoreCase(at.name, "aria-hidden") and std.ascii.eqlIgnoreCase(std.mem.trim(u8, at.value, " "), "true")) return true;
        if (std.ascii.eqlIgnoreCase(at.name, "style")) {
            var buf: [256]u8 = undefined;
            var n: usize = 0;
            for (at.value) |c| {
                if (isWs(c)) continue;
                if (n == buf.len) break;
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
            if (std.mem.indexOf(u8, buf[0..n], "display:none") != null or std.mem.indexOf(u8, buf[0..n], "visibility:hidden") != null) return true;
        }
    }
    return false;
}

// ---- structure ----

const Info = struct {
    title: ?usize = null, // its raw token
    h1: ?usize = null,
    base: ?usize = null,
    from: usize = 0,
    to: usize = 0,
};

const Entry = struct { tok: u32, drop: bool, in_drop: bool };

const Structure = struct {
    toks: []Token,
    a: Allocator,
    stack: std.ArrayList(Entry) = .empty,
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    dropped: u32 = 0,
    /// vis[k]: visible text bytes before token k.
    vis: []u64,
    best_article: ?u32 = null,
    best_size: u64 = 0,
    body: ?u32 = null,
    main: ?u32 = null,

    fn count(s: *Structure, key: []const u8) u32 {
        return s.counts.get(key) orelse 0;
    }

    fn pop(s: *Structure, at: usize) void {
        const e = s.stack.pop().?;
        const tk = &s.toks[e.tok];
        tk.end = @intCast(at);
        if (s.counts.getPtr(tk.key)) |c| c.* -= 1;
        if (e.drop) s.dropped -= 1;
        if (tk.tag == .article and !e.drop and !e.in_drop) {
            const size = s.vis[at] - s.vis[e.tok];
            if (s.best_article == null or size > s.best_size) {
                s.best_article = e.tok;
                s.best_size = size;
            }
        }
    }

    /// Pops down to and including the topmost open `key` (which must be open).
    fn popTo(s: *Structure, key: []const u8, at: usize) void {
        while (s.stack.items.len > 0) {
            const top = s.stack.items[s.stack.items.len - 1];
            const match = std.mem.eql(u8, s.toks[top.tok].key, key);
            s.pop(at);
            if (match) return;
        }
    }

    /// Closes the nearest open element in `names`, looking at most a few
    /// entries down and not past one in `stops`.
    fn closeNear(s: *Structure, names: []const Tag, stops: []const Tag, at: usize) void {
        var k = s.stack.items.len;
        var looked: u32 = 0;
        while (k > 0 and looked < 8) : (looked += 1) {
            k -= 1;
            const tag = s.toks[s.stack.items[k].tok].tag;
            if (std.mem.indexOfScalar(Tag, names, tag) != null) {
                while (s.stack.items.len > k) s.pop(at);
                return;
            }
            if (std.mem.indexOfScalar(Tag, stops, tag) != null) return;
        }
    }

    fn topTag(s: *Structure) ?Tag {
        if (s.stack.items.len == 0) return null;
        return s.toks[s.stack.items[s.stack.items.len - 1].tok].tag;
    }

    fn implicitClose(s: *Structure, tag: Tag, at: usize) void {
        if (closesP(tag) and s.topTag() == .p) s.pop(at);
        switch (tag) {
            .li => s.closeNear(&.{.li}, &.{ .ul, .ol, .menu }, at),
            .dt, .dd => s.closeNear(&.{ .dt, .dd }, &.{.dl}, at),
            .tr => s.closeNear(&.{.tr}, &.{ .table, .thead, .tbody, .tfoot }, at),
            .td, .th => s.closeNear(&.{ .td, .th }, &.{ .tr, .table }, at),
            .thead, .tbody, .tfoot => s.closeNear(&.{ .thead, .tbody, .tfoot }, &.{.table}, at),
            .option => if (s.topTag() == .option) s.pop(at),
            .a => if (s.count("a") > 0) s.popTo("a", at),
            .body => if (s.count("head") > 0) s.popTo("head", at),
            else => {},
        }
    }
};

fn visibleLen(s: []const u8) u64 {
    var n: u64 = 0;
    for (s) |c| n += @intFromBool(!isWs(c));
    return n;
}

fn structure(a: Allocator, toks: []Token) !Info {
    var s: Structure = .{ .toks = toks, .a = a, .vis = try a.alloc(u64, toks.len + 1) };
    var info: Info = .{};
    s.vis[0] = 0;
    for (toks, 0..) |*tk, idx| {
        s.vis[idx + 1] = s.vis[idx];
        switch (tk.kind) {
            .text => if (s.dropped == 0) {
                s.vis[idx + 1] += visibleLen(tk.s);
            },
            .raw => {},
            .end => if (s.count(tk.key) > 0) s.popTo(tk.key, idx),
            .start => {
                s.implicitClose(tk.tag, idx);
                tk.end = @intCast(idx + 1);
                switch (tk.tag) {
                    .html, .head, .body => if (s.count(tk.key) > 0) continue, // a second one
                    .base => if (info.base == null) {
                        info.base = idx;
                    },
                    else => {},
                }
                if (isVoid(tk.tag) or tk.self_close) continue;
                const in_drop = s.dropped > 0;
                const in_section = s.count("article") + s.count("main") + s.count("section") > 0;
                const drop = isDrop(tk.tag, in_section) or isHidden(tk.s);
                tk.drop = drop;
                if (!drop and !in_drop) switch (tk.tag) {
                    .h1 => if (info.h1 == null) {
                        info.h1 = idx;
                    },
                    .main => if (s.main == null) {
                        s.main = @intCast(idx);
                    },
                    .body => if (s.body == null) {
                        s.body = @intCast(idx);
                    },
                    else => {},
                };
                if (tk.tag == .title and info.title == null and s.count("svg") == 0 and idx + 1 < toks.len and toks[idx + 1].kind == .raw) info.title = idx + 1;
                try s.stack.append(a, .{ .tok = @intCast(idx), .drop = drop, .in_drop = in_drop });
                const gop = try s.counts.getOrPut(a, tk.key);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                if (drop) s.dropped += 1;
            },
        }
    }
    while (s.stack.items.len > 0) s.pop(toks.len);

    const total = if (s.body) |b| s.vis[toks[b].end] - s.vis[b] else s.vis[toks.len];
    // the largest article, unless it is only a small part of the page (a
    // list of teasers rather than one story)
    const pick: ?u32 = if (s.best_article != null and s.best_size > 0 and s.best_size * 4 >= total) s.best_article else s.main orelse s.body;
    if (pick) |p| {
        info.from = p + 1;
        info.to = toks[p].end;
    } else {
        info.from = 0;
        info.to = toks.len;
    }
    return info;
}

// ---- text ----

const Out = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Line breaks wanted before the next text (2 = a blank line).
    nl: u8 = 0,
    space: bool = false,
    /// Written before the next text: "# ", "- ", "[".
    prefix: std.ArrayList(u8) = .empty,
    /// Inside a link or table cell: line breaks become spaces.
    inline_only: u32 = 0,
    /// The part of inline_only that comes from table cells.
    cell_inline: u32 = 0,
    pre: u32 = 0,
    pre_start: bool = false,
    /// A list item has started and nothing is written in it yet.
    li_fresh: bool = false,

    fn atLineStart(o: *Out) bool {
        return o.buf.items.len == 0 or o.buf.items[o.buf.items.len - 1] == '\n';
    }

    fn brk(o: *Out, n: u8) void {
        if (o.inline_only > 0) {
            o.space = true;
            return;
        }
        const m = if (o.li_fresh) @min(n, 1) else n;
        if (m > o.nl) o.nl = m;
    }

    fn hardBreak(o: *Out) void {
        if (o.inline_only > 0) {
            o.space = true;
            return;
        }
        o.nl = @min(o.nl + 1, 2);
    }

    fn flush(o: *Out, with_space: bool) !void {
        if (o.buf.items.len == 0) {
            o.nl = 0;
            o.space = false;
        } else if (o.nl > 0) {
            while (o.buf.items.len > 0 and o.buf.items[o.buf.items.len - 1] == ' ') o.buf.items.len -= 1;
            var have: u8 = 0;
            var k = o.buf.items.len;
            while (k > 0 and have < 2 and o.buf.items[k - 1] == '\n') : (k -= 1) have += 1;
            while (have < o.nl) : (have += 1) try o.buf.append(o.a, '\n');
            o.nl = 0;
            o.space = false;
        }
        if (o.space) {
            if (with_space and !o.atLineStart()) try o.buf.append(o.a, ' ');
            o.space = false;
        }
        if (o.prefix.items.len > 0) {
            try o.buf.appendSlice(o.a, o.prefix.items);
            o.prefix.clearRetainingCapacity();
        }
        o.li_fresh = false;
    }

    fn pending(o: *Out) bool {
        return o.nl > 0 or o.space or o.prefix.items.len > 0;
    }

    fn put(o: *Out, bytes: []const u8) !void {
        if (o.pending()) try o.flush(true);
        try o.buf.appendSlice(o.a, bytes);
    }

    /// Text outside <pre>: entities decoded, whitespace collapsed.
    fn text(o: *Out, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c == '&') {
                if (decodeEntity(s, i, false)) |d| {
                    i += d.len;
                    if (d.cp == 0xA0 or (d.cp < 0x80 and isWs(@intCast(d.cp)))) {
                        o.space = true;
                    } else if (d.cp != 0xAD) {
                        var u: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(d.cp, &u) catch unreachable;
                        try o.put(u[0..n]);
                    }
                    continue;
                }
            }
            if (isWs(c)) {
                o.space = true;
            } else if (o.pending()) {
                try o.put(s[i .. i + 1]);
            } else {
                try o.buf.append(o.a, c);
            }
            i += 1;
        }
    }

    /// Text inside <pre>: kept as it is, entities decoded.
    fn preText(o: *Out, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            var u: [4]u8 = undefined;
            var bytes: []const u8 = s[i .. i + 1];
            if (s[i] == '&') if (decodeEntity(s, i, false)) |d| {
                const cp: u21 = if (d.cp == 0xA0) ' ' else d.cp;
                bytes = u[0 .. std.unicode.utf8Encode(cp, &u) catch unreachable];
                i += d.len - 1;
            };
            i += 1;
            if (bytes.len == 1 and bytes[0] == '\r') continue;
            if (o.pre_start) {
                o.pre_start = false;
                if (bytes.len == 1 and bytes[0] == '\n') continue;
            }
            if (o.pending()) try o.flush(false);
            try o.buf.appendSlice(o.a, bytes);
        }
    }

    fn sep(o: *Out) !void {
        o.space = false;
        if (o.pending()) try o.flush(false);
        try o.buf.appendSlice(o.a, if (o.atLineStart()) "| " else " | ");
    }
};

const REntry = struct {
    end: u32,
    tag: Tag,
    mark: usize = 0,
    url: ?[]const u8 = null,
    saved_cells: u32 = 0,
    saved_cell_inline: u32 = 0,
};

fn headingLevel(tag: Tag) ?u8 {
    return switch (tag) {
        .h1 => 1,
        .h2 => 2,
        .h3 => 3,
        .h4 => 4,
        .h5 => 5,
        .h6 => 6,
        else => null,
    };
}

fn renderRange(o: *Out, toks: []const Token, from: usize, to: usize, base: []const u8) !void {
    var stack: std.ArrayList(REntry) = .empty;
    var lists: u32 = 0;
    var cells: u32 = 0;
    var links: u32 = 0;
    var i = from;
    while (true) {
        while (stack.items.len > 0 and (stack.items[stack.items.len - 1].end <= i or i >= to)) {
            const e = stack.pop().?;
            try close(o, e, &lists, &cells, &links);
        }
        if (i >= to) break;
        const tk = toks[i];
        switch (tk.kind) {
            .text => if (o.pre > 0) try o.preText(tk.s) else try o.text(tk.s),
            .raw, .end => {},
            .start => {
                if (tk.drop) {
                    i = @max(tk.end, i + 1);
                    continue;
                }
                var e: REntry = .{ .end = tk.end, .tag = tk.tag };
                if (headingLevel(tk.tag)) |lv| {
                    o.brk(2);
                    e.mark = o.prefix.items.len;
                    if (o.inline_only == 0) {
                        for (0..lv) |_| try o.prefix.append(o.a, '#');
                        try o.prefix.append(o.a, ' ');
                    }
                } else switch (tk.tag) {
                    .p, .pre, .table, .hr, .blockquote => {
                        if (tk.tag == .table) {
                            // a table inside a cell gets rows of its own
                            e.saved_cell_inline = o.cell_inline;
                            e.saved_cells = cells;
                            o.inline_only -= o.cell_inline;
                            o.cell_inline = 0;
                            cells = 0;
                        }
                        o.brk(2);
                        if (tk.tag == .pre) {
                            o.pre += 1;
                            o.pre_start = true;
                        }
                    },
                    .div, .section, .article, .main, .header, .footer, .figure, .figcaption, .address, .details, .summary, .dl, .dt, .dd, .caption, .fieldset, .hgroup, .dialog => o.brk(1),
                    .ul, .ol, .menu => {
                        o.brk(1);
                        lists += 1;
                    },
                    .li => {
                        o.brk(1);
                        if (o.inline_only == 0) {
                            o.prefix.clearRetainingCapacity();
                            for (1..@max(lists, 1)) |_| try o.prefix.appendSlice(o.a, "  ");
                            try o.prefix.appendSlice(o.a, "- ");
                            o.li_fresh = true;
                        }
                    },
                    .br => o.hardBreak(),
                    .tr => {
                        o.brk(1);
                        e.saved_cells = cells;
                        cells = 0;
                    },
                    .td, .th => {
                        if (cells > 0) try o.sep();
                        cells += 1;
                        o.inline_only += 1;
                        o.cell_inline += 1;
                    },
                    .img => if (attr(tk.s, "alt")) |raw| {
                        const alt = std.mem.trim(u8, raw, " \t\r\n");
                        if (alt.len > 0) {
                            try o.text("[image: ");
                            try o.text(alt);
                            try o.text("]");
                        }
                    },
                    .a => if (links == 0) if (attr(tk.s, "href")) |raw| {
                        if (try resolve(o.a, base, try decodeAlloc(o.a, raw))) |url| {
                            e.url = url;
                            e.mark = o.prefix.items.len;
                            try o.prefix.append(o.a, '[');
                            o.inline_only += 1;
                            links += 1;
                        }
                    },
                    else => {},
                }
                if (tk.end > i + 1) {
                    try stack.append(o.a, e);
                } else {
                    // void or empty: its closing work happens now
                    try close(o, e, &lists, &cells, &links);
                }
            },
        }
        i += 1;
    }
}

fn close(o: *Out, e: REntry, lists: *u32, cells: *u32, links: *u32) !void {
    if (headingLevel(e.tag) != null) {
        if (o.prefix.items.len > e.mark) o.prefix.shrinkRetainingCapacity(e.mark);
        o.brk(2);
        return;
    }
    switch (e.tag) {
        .p, .hr, .blockquote => o.brk(2),
        .table => {
            o.brk(2);
            o.inline_only += e.saved_cell_inline;
            o.cell_inline = e.saved_cell_inline;
            cells.* = e.saved_cells;
        },
        .pre => {
            o.pre -|= 1;
            o.pre_start = false;
            o.brk(2);
        },
        .div, .section, .article, .main, .header, .footer, .figure, .figcaption, .address, .details, .summary, .dl, .dt, .dd, .caption, .fieldset, .hgroup, .dialog => o.brk(1),
        .ul, .ol, .menu => {
            lists.* -|= 1;
            o.brk(1);
        },
        .li => {
            if (o.inline_only == 0) o.prefix.clearRetainingCapacity();
            o.li_fresh = false;
            o.brk(1);
        },
        .tr => {
            cells.* = e.saved_cells;
            o.brk(1);
        },
        .td, .th => {
            o.inline_only -|= 1;
            o.cell_inline -|= 1;
        },
        .a => if (e.url) |url| {
            o.inline_only -|= 1;
            links.* -|= 1;
            if (o.prefix.items.len > e.mark) {
                o.prefix.shrinkRetainingCapacity(e.mark); // nothing in the link
            } else {
                try o.buf.appendSlice(o.a, "](");
                for (url) |c| {
                    if (c == ' ') try o.buf.appendSlice(o.a, "%20") else try o.buf.append(o.a, c);
                }
                try o.buf.append(o.a, ')');
            }
        },
        else => {},
    }
}

// ---- entities ----

const named = std.StaticStringMap(u21).initComptime(.{
    .{ "amp", '&' },       .{ "lt", '<' },        .{ "gt", '>' },        .{ "quot", '"' },
    .{ "apos", '\'' },     .{ "nbsp", 0xA0 },     .{ "copy", 0xA9 },     .{ "reg", 0xAE },
    .{ "trade", 0x2122 },  .{ "hellip", 0x2026 }, .{ "mdash", 0x2014 },  .{ "ndash", 0x2013 },
    .{ "lsquo", 0x2018 },  .{ "rsquo", 0x2019 },  .{ "sbquo", 0x201A },  .{ "ldquo", 0x201C },
    .{ "rdquo", 0x201D },  .{ "bdquo", 0x201E },  .{ "laquo", 0xAB },    .{ "raquo", 0xBB },
    .{ "lsaquo", 0x2039 }, .{ "rsaquo", 0x203A }, .{ "bull", 0x2022 },   .{ "middot", 0xB7 },
    .{ "deg", 0xB0 },      .{ "euro", 0x20AC },   .{ "pound", 0xA3 },    .{ "yen", 0xA5 },
    .{ "cent", 0xA2 },     .{ "times", 0xD7 },    .{ "divide", 0xF7 },   .{ "plusmn", 0xB1 },
    .{ "sect", 0xA7 },     .{ "para", 0xB6 },     .{ "frac12", 0xBD },   .{ "frac14", 0xBC },
    .{ "frac34", 0xBE },   .{ "shy", 0xAD },      .{ "iexcl", 0xA1 },    .{ "iquest", 0xBF },
    .{ "micro", 0xB5 },    .{ "dagger", 0x2020 }, .{ "Dagger", 0x2021 }, .{ "permil", 0x2030 },
    .{ "prime", 0x2032 },  .{ "larr", 0x2190 },   .{ "rarr", 0x2192 },   .{ "uarr", 0x2191 },
    .{ "darr", 0x2193 },   .{ "harr", 0x2194 },   .{ "le", 0x2264 },     .{ "ge", 0x2265 },
    .{ "ne", 0x2260 },     .{ "asymp", 0x2248 },  .{ "infin", 0x221E },  .{ "minus", 0x2212 },
    .{ "ensp", 0x2002 },   .{ "emsp", 0x2003 },   .{ "thinsp", 0x2009 }, .{ "zwnj", 0x200C },
    .{ "zwj", 0x200D },    .{ "check", 0x2713 },  .{ "hearts", 0x2665 }, .{ "star", 0x2606 },
    .{ "alpha", 0x3B1 },   .{ "beta", 0x3B2 },    .{ "gamma", 0x3B3 },   .{ "delta", 0x3B4 },
    .{ "pi", 0x3C0 },      .{ "mu", 0x3BC },      .{ "sigma", 0x3C3 },   .{ "Delta", 0x394 },
    .{ "aacute", 0xE1 },   .{ "agrave", 0xE0 },   .{ "acirc", 0xE2 },    .{ "auml", 0xE4 },
    .{ "atilde", 0xE3 },   .{ "aring", 0xE5 },    .{ "aelig", 0xE6 },    .{ "ccedil", 0xE7 },
    .{ "eacute", 0xE9 },   .{ "egrave", 0xE8 },   .{ "ecirc", 0xEA },    .{ "euml", 0xEB },
    .{ "iacute", 0xED },   .{ "igrave", 0xEC },   .{ "icirc", 0xEE },    .{ "iuml", 0xEF },
    .{ "ntilde", 0xF1 },   .{ "oacute", 0xF3 },   .{ "ograve", 0xF2 },   .{ "ocirc", 0xF4 },
    .{ "ouml", 0xF6 },     .{ "otilde", 0xF5 },   .{ "oslash", 0xF8 },   .{ "uacute", 0xFA },
    .{ "ugrave", 0xF9 },   .{ "ucirc", 0xFB },    .{ "uuml", 0xFC },     .{ "yacute", 0xFD },
    .{ "yuml", 0xFF },     .{ "szlig", 0xDF },    .{ "Aacute", 0xC1 },   .{ "Agrave", 0xC0 },
    .{ "Auml", 0xC4 },     .{ "Aring", 0xC5 },    .{ "Ccedil", 0xC7 },   .{ "Eacute", 0xC9 },
    .{ "Egrave", 0xC8 },   .{ "Ntilde", 0xD1 },   .{ "Oacute", 0xD3 },   .{ "Ouml", 0xD6 },
    .{ "Oslash", 0xD8 },   .{ "Uacute", 0xDA },   .{ "Uuml", 0xDC },     .{ "oelig", 0x153 },
    .{ "scaron", 0x161 },  .{ "Scaron", 0x160 },  .{ "zcaron", 0x17E },  .{ "Zcaron", 0x17D },
});

/// Old pages: &#128;–&#159; mean windows-1252 characters.
const cp1252 = [32]u21{
    0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
};

const Decoded = struct { cp: u21, len: usize };

/// The entity at s[i] (which is '&'), or null to keep the '&' as it is.
/// Without a ';' only the old common names count, and not in attributes.
fn decodeEntity(s: []const u8, i: usize, in_attr: bool) ?Decoded {
    var j = i + 1;
    if (j < s.len and s[j] == '#') {
        j += 1;
        const hex = j < s.len and (s[j] == 'x' or s[j] == 'X');
        if (hex) j += 1;
        const ds = j;
        var v: u32 = 0;
        while (j < s.len) : (j += 1) {
            const d = std.fmt.charToDigit(s[j], if (hex) 16 else 10) catch break;
            v = @min(v *| (if (hex) @as(u32, 16) else 10) +| d, 0x110000);
        }
        if (j == ds) return null;
        if (j < s.len and s[j] == ';') j += 1;
        const cp: u21 = if (v == 0 or v >= 0x110000 or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else if (v >= 0x80 and v <= 0x9F) cp1252[v - 0x80] else @intCast(v);
        return .{ .cp = cp, .len = j - i };
    }
    while (j < s.len and j - i <= 32 and std.ascii.isAlphanumeric(s[j])) j += 1;
    const name = s[i + 1 .. j];
    if (name.len == 0) return null;
    if (j < s.len and s[j] == ';') {
        const cp = named.get(name) orelse return null;
        return .{ .cp = cp, .len = j + 1 - i };
    }
    if (in_attr) return null;
    for ([_][]const u8{ "amp", "lt", "gt", "quot", "nbsp", "copy", "reg" }) |legacy| {
        if (std.mem.eql(u8, name, legacy)) return .{ .cp = named.get(name).?, .len = j - i };
    }
    return null;
}

/// An attribute value with its entities decoded.
fn decodeAlloc(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (decodeEntity(s, i, true)) |d| {
            var u: [4]u8 = undefined;
            try out.appendSlice(a, u[0 .. std.unicode.utf8Encode(d.cp, &u) catch unreachable]);
            i += d.len;
            continue;
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

// ---- links ----

fn schemeLen(u: []const u8) ?usize {
    if (u.len == 0 or !std.ascii.isAlphabetic(u[0])) return null;
    for (u, 0..) |c, k| {
        if (c == ':') return k;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    }
    return null;
}

/// `href` as an absolute URL against `base`, or null when the link is
/// only text (a fragment on this page, javascript:, mailto: and the like).
fn resolve(a: Allocator, base: []const u8, href_in: []const u8) !?[]const u8 {
    var href: []const u8 = std.mem.trim(u8, href_in, " \t\r\n\x0c");
    if (std.mem.indexOfAny(u8, href, "\t\r\n") != null) {
        var clean: std.ArrayList(u8) = .empty;
        for (href) |c| if (c != '\t' and c != '\r' and c != '\n') try clean.append(a, c);
        href = clean.items;
    }
    if (href.len == 0 or href[0] == '#') return null;
    if (schemeLen(href)) |n| {
        const scheme = href[0..n];
        for ([_][]const u8{ "javascript", "mailto", "tel", "sms", "data", "vbscript", "blob", "about" }) |s| {
            if (std.ascii.eqlIgnoreCase(scheme, s)) return null;
        }
        return href;
    }
    // base: scheme "://" authority, then path, query
    const bs = schemeLen(base) orelse return href;
    if (!std.mem.startsWith(u8, base[bs..], "://")) return href;
    const auth_start = bs + 3;
    const auth_end = std.mem.indexOfAnyPos(u8, base, auth_start, "/?#") orelse base.len;
    const origin = base[0..auth_end];
    const rest = base[auth_end..];
    const path_end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    const path = if (path_end == 0) "/" else rest[0..path_end];

    if (std.mem.startsWith(u8, href, "//")) return try std.fmt.allocPrint(a, "{s}:{s}", .{ base[0..bs], href });
    if (href[0] == '?') return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ origin, path, href });
    const tail_at = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
    const merged = if (href[0] == '/')
        href[0..tail_at]
    else
        try std.fmt.allocPrint(a, "{s}{s}", .{ path[0 .. std.mem.lastIndexOfScalar(u8, path, '/').? + 1], href[0..tail_at] });
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ origin, try removeDots(a, merged), href[tail_at..] });
}

/// "/a/b/../c/./d" → "/a/c/d".
fn removeDots(a: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, path, "/.") == null) return path;
    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    var trailing = false;
    while (it.next()) |seg| {
        trailing = false;
        if (std.mem.eql(u8, seg, ".")) {
            trailing = true;
        } else if (std.mem.eql(u8, seg, "..")) {
            _ = segs.pop();
            trailing = true;
        } else try segs.append(a, seg);
    }
    var out: std.ArrayList(u8) = .empty;
    for (segs.items) |seg| {
        try out.append(a, '/');
        try out.appendSlice(a, seg);
    }
    if (trailing or out.items.len == 0) try out.append(a, '/');
    return out.items;
}

// ---- paging ----

pub const Chunk = struct { text: []const u8, next: ?usize, total: usize };

/// One page of a long text: text[start..] cut at <= max bytes, preferring
/// to end at a line break in the last 20%, never splitting a UTF-8
/// sequence (if max is smaller than one character, that one character).
/// next = null when nothing remains.
pub fn chunk(text: []const u8, start: usize, max: usize) Chunk {
    if (start >= text.len) return .{ .text = "", .next = null, .total = text.len };
    if (text.len - start <= max) return .{ .text = text[start..], .next = null, .total = text.len };
    var end = start + max;
    const lo = start + max - max / 5;
    if (std.mem.lastIndexOfScalar(u8, text[lo..end], '\n')) |k| {
        end = lo + k + 1;
    } else {
        while (end > start and (text[end] & 0xC0) == 0x80) end -= 1;
        if (end == start) {
            end = start + 1;
            while (end < text.len and (text[end] & 0xC0) == 0x80) end += 1;
        }
    }
    return .{ .text = text[start..end], .next = if (end < text.len) end else null, .total = text.len };
}

// ---- browser ----

const standard_paths: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    },
    .windows => &.{
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files\\Chromium\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    },
    else => &.{},
};

const path_names = [_][]const u8{ "google-chrome", "google-chrome-stable", "chromium", "chromium-browser" };

fn isFile(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind != .directory;
}

/// Headless Chrome/Chromium: `explicit` if it exists, else `env_chrome`
/// (the HARNESS_CHROME value), else the standard install paths, else (not
/// on Windows) google-chrome, google-chrome-stable, chromium,
/// chromium-browser on `env_path` (the PATH value). Null if none.
pub fn findBrowser(arena: Allocator, io: Io, explicit: []const u8, env_chrome: []const u8, env_path: []const u8) !?[]const u8 {
    return findIn(arena, io, explicit, env_chrome, env_path, standard_paths);
}

fn findIn(arena: Allocator, io: Io, explicit: []const u8, env_chrome: []const u8, env_path: []const u8, std_paths: []const []const u8) !?[]const u8 {
    for ([_][]const u8{ explicit, env_chrome }) |p| {
        if (p.len > 0 and isFile(io, p)) return try arena.dupe(u8, p);
    }
    for (std_paths) |p| if (isFile(io, p)) return try arena.dupe(u8, p);
    if (is_windows) return null;
    var dirs = std.mem.tokenizeScalar(u8, env_path, ':');
    while (dirs.next()) |d| {
        for (path_names) |n| {
            const p = try std.fs.path.join(arena, &.{ d, n });
            if (isFile(io, p)) return p;
        }
    }
    return null;
}

const Collector = struct {
    mutex: Io.Mutex = .init,
    buf: std.ArrayList(u8) = .empty,
    cap: usize,
    gpa: Allocator,
    finished: std.atomic.Value(bool) = .init(false),

    fn add(c: *Collector, io: Io, part: []const u8) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const room = c.cap -| c.buf.items.len;
        c.buf.appendSlice(c.gpa, part[0..@min(room, part.len)]) catch {};
    }

    /// POSIX: reads until the pipe closes or `ended` is set, looking every
    /// 100 ms, so a process that kept the pipe open can't hold us.
    fn pumpUntil(c: *Collector, io: Io, from: Io.File, ended: *std.atomic.Value(bool)) void {
        var buf: [16384]u8 = undefined;
        while (!ended.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = from.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;
            const got = from.readStreaming(io, &.{&buf}) catch break;
            if (got == 0) break;
            c.add(io, buf[0..got]);
        }
        c.finished.store(true, .release);
    }

    fn pump(c: *Collector, io: Io, from: Io.File) void {
        var buf: [16384]u8 = undefined;
        while (true) {
            const got = from.readStreaming(io, &.{&buf}) catch break;
            if (got == 0) break;
            c.add(io, buf[0..got]);
        }
        c.finished.store(true, .release);
    }
};

const Ended = enum { stopped, timeout, download };

const Watch = struct {
    io: Io,
    id: std.process.Child.Id,
    stop: *std.atomic.Value(bool),
    deadline_ns: i128,
    done: std.atomic.Value(bool) = .init(false),
    reason: ?Ended = null,
    /// The browser was reaped: its pid and group id may be another's now.
    reaped: std.atomic.Value(bool) = .init(false),
    /// Made by the browser when the address turns out to be a download
    /// (refused, see prepareProfile). On Linux headless Chrome then waits
    /// for a page that never comes, so its appearing ends the run.
    download_dir: []const u8 = "",

    fn run(w: *Watch) void {
        while (!w.done.load(.acquire)) {
            if (w.stop.load(.acquire)) {
                w.reason = .stopped;
                break;
            }
            if (w.download_dir.len > 0) if (Io.Dir.cwd().statFile(w.io, w.download_dir, .{})) |_| {
                w.reason = .download;
                break;
            } else |_| {};
            if (Io.Clock.awake.now(w.io).nanoseconds >= w.deadline_ns) {
                w.reason = .timeout;
                break;
            }
            w.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        if (w.reason != null) w.killAll();
    }

    /// The whole process group on POSIX (the browser's helpers go too);
    /// the process itself on Windows.
    fn killAll(w: *Watch) void {
        if (is_windows) {
            _ = std.os.windows.ntdll.NtTerminateProcess(w.id, @fromBackingInt(@intCast(1)));
        } else {
            w.killGroup();
            std.posix.kill(w.id, .KILL) catch {};
        }
    }

    fn killGroup(w: *Watch) void {
        if (is_windows) return else {
            if (w.reaped.load(.acquire)) _ = late_group_kills.fetchAdd(1, .acq_rel);
            std.posix.kill(-w.id, .KILL) catch {};
        }
    }
};

/// Group kills sent after the browser was reaped (must stay 0; for tests).
pub var late_group_kills: std.atomic.Value(u32) = .init(0);

/// Blocks until the child `pid` has ended, without reaping it: until it is
/// reaped, its pid and its process group id stay its own, so its group can
/// still be killed safely. (Elsewhere than Linux and macOS: at once.)
pub fn waitExited(pid: std.posix.pid_t) void {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var info: linux.siginfo_t = undefined;
            while (true) switch (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOWAIT, null))) {
                .INTR => continue,
                else => return,
            };
        },
        .macos => {
            // <sys/wait.h>: P_PID 1, WEXITED 0x4, WNOWAIT 0x20
            var info: [256]u8 align(16) = undefined;
            while (true) {
                if (darwin_waitid(1, @intCast(pid), &info, 0x4 | 0x20) == 0) return;
                if (std.c.errno(@as(c_int, -1)) != .INTR) return;
            }
        },
        else => {},
    }
}

extern "c" fn waitid(idtype: c_int, id: c_uint, infop: *anyopaque, options: c_int) c_int;
const darwin_waitid = if (builtin.os.tag == .macos) waitid else undefined;

/// What a browser's environment is made of: nothing else of harness's own
/// environment (keys and tokens among it) reaches it.
pub const BrowserEnv = struct {
    path: []const u8 = "",
    home: []const u8 = "",
    /// Windows: the system's own variables (util.system_var_names).
    system: []const util.Var = &.{},

    pub fn map(e: BrowserEnv, arena: Allocator) !std.process.Environ.Map {
        var m = std.process.Environ.Map.init(arena);
        for (e.system) |v| try m.put(v.name, v.value);
        try m.put("PATH", if (e.path.len > 0) e.path else "/usr/local/bin:/usr/bin:/bin");
        if (e.home.len > 0) try m.put("HOME", e.home);
        try m.put("LANG", "C.UTF-8");
        return m;
    }
};

/// Every browser harness starts: headless, no first-run screens, and the
/// system's own key store left alone (a mock of the macOS Keychain, no
/// desktop keyring on Linux).
pub const browser_flags = [_][]const u8{
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--mute-audio",
    "--use-mock-keychain",
    "--password-store=basic",
};

/// Settings harness needs in a browser `profile`, written to its
/// Default/Preferences before the browser starts (whatever else is there
/// stays): Chrome's own password manager off (typed passwords must not end
/// up in the profile's Login Data), and downloads blocked, with their
/// folder inside the profile should one get through: a page never saves a
/// file anywhere else (the user's Downloads among them).
pub fn prepareProfile(io: Io, a: Allocator, profile: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ profile, "Default" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, "Preferences" });
    const old = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    var root: std.json.Value = .{ .object = .empty };
    if (jv.parse(a, old)) |v| if (v == .object) {
        root = v;
    };
    const downloads = try std.fs.path.join(a, &.{ profile, "Downloads" });
    try setPref(a, &root, &.{"credentials_enable_service"}, .{ .bool = false });
    try setPref(a, &root, &.{ "profile", "password_manager_enabled" }, .{ .bool = false });
    // 3: every download blocked
    try setPref(a, &root, &.{"download_restrictions"}, .{ .integer = 3 });
    try setPref(a, &root, &.{ "download", "default_directory" }, .{ .string = downloads });
    try setPref(a, &root, &.{ "download", "prompt_for_download" }, .{ .bool = false });
    try setPref(a, &root, &.{ "download", "directory_upgrade" }, .{ .bool = true });
    try setPref(a, &root, &.{ "savefile", "default_directory" }, .{ .string = downloads });
    const text = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(root, .{})});
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = util.private_file });
    defer f.close(io);
    try f.writeStreamingAll(io, text);
}

/// Sets `value` at `keys` below `v`, making the objects on the way.
fn setPref(a: Allocator, v: *std.json.Value, keys: []const []const u8, value: std.json.Value) !void {
    if (v.* != .object) v.* = .{ .object = .empty };
    if (keys.len == 1) return v.object.put(a, keys[0], value);
    const slot = try v.object.getOrPut(a, keys[0]);
    if (!slot.found_existing) slot.value_ptr.* = .{ .object = .empty };
    return setPref(a, slot.value_ptr, keys[1..], value);
}

/// The folders of throwaway profiles in a `tmp_root`: browse's, web's.
pub const throwaway_prefixes = [_][]const u8{ "harness-browser-", "harness-web-" };

var profiles_mutex: Io.Mutex = .init;
/// The roots swept in this process (page_allocator).
var swept: std.StringHashMapUnmanaged(void) = .empty;

/// A new empty throwaway profile `PREFIX<random>` in `tmp_root`. The first
/// one this process makes there first removes those left by an earlier
/// run (killed before it could remove its own); this process has none
/// there yet then.
pub fn newProfile(io: Io, arena: Allocator, tmp_root: []const u8, prefix: []const u8) ![]const u8 {
    profiles_mutex.lockUncancelable(io);
    defer profiles_mutex.unlock(io);
    try Io.Dir.cwd().createDirPath(io, tmp_root);
    if (!swept.contains(tmp_root)) {
        sweepProfiles(io, tmp_root);
        const k = try std.heap.page_allocator.dupe(u8, tmp_root);
        swept.put(std.heap.page_allocator, k, {}) catch std.heap.page_allocator.free(k);
    }
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const p = try std.fs.path.join(arena, &.{ tmp_root, try std.fmt.allocPrint(arena, "{s}{x}", .{ prefix, rnd }) });
    try Io.Dir.cwd().createDir(io, p, .default_dir);
    return p;
}

/// Removes the throwaway profiles in `root` (folders only, not links).
fn sweepProfiles(io: Io, root: []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    // the names first: removing while listing may skip some
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        for (throwaway_prefixes) |pre| if (std.mem.startsWith(u8, e.name, pre)) {
            names.append(a, a.dupe(u8, e.name) catch continue) catch {};
        };
    }
    for (names.items) |n| dir.deleteTree(io, n) catch {};
}

/// Renders `url` in a headless browser with a fresh throwaway profile and
/// returns the DOM as HTML (at most max_bytes). Ends it on `stop`
/// (error.Stopped) or after timeout_ms (error.Timeout).
pub fn render(gpa: Allocator, io: Io, arena: Allocator, browser: []const u8, url: []const u8, tmp_root: []const u8, stop: *std.atomic.Value(bool), timeout_ms: u32, max_bytes: usize, benv: BrowserEnv) ![]const u8 {
    // as the gate read it (url.zig): the browser goes to that host, in
    // that form; an IPv6 one has no host rule here
    const u = url_mod.parse(arena, url) catch |e| return if (e == error.OutOfMemory) e else error.BadUrl;
    if (u.host[0] == '[') return error.BadUrl;
    const host = u.host;

    const profile = try newProfile(io, arena, tmp_root, "harness-browser-");
    defer removeProfile(io, profile);
    try prepareProfile(io, arena, profile);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, browser);
    try argv.appendSlice(arena, &browser_flags);
    try argv.appendSlice(arena, &.{
        try std.fmt.allocPrint(arena, "--user-data-dir={s}", .{profile}),
        // the gate allowed this host: no other is even looked up (the
        // page's scripts, images and frames from elsewhere don't load)
        try std.fmt.allocPrint(arena, "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE {s}", .{host}),
        "--virtual-time-budget=8000",
        "--dump-dom",
        u.href,
    });
    var vars = try benv.map(arena);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &vars,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = if (is_windows) null else 0,
        .create_no_window = true,
    });
    var col: Collector = .{ .cap = max_bytes, .gpa = gpa };
    defer col.buf.deinit(gpa);
    var watch: Watch = .{
        .io = io,
        .id = child.id.?,
        .stop = stop,
        .deadline_ns = Io.Clock.awake.now(io).nanoseconds + @as(i128, timeout_ms) * std.time.ns_per_ms,
        .download_dir = try std.fs.path.join(arena, &.{ profile, "Downloads" }),
    };
    const th_watch = try std.Thread.spawn(.{}, Watch.run, .{&watch});
    var term: ?std.process.Child.Term = null;
    if (is_windows) {
        const th_out = try std.Thread.spawn(.{}, Collector.pump, .{ &col, io, child.stdout.? });
        th_out.join();
        term = child.wait(io) catch null;
    } else {
        // the pipe is ours: `wait` must not close it under the reader
        const out_f = child.stdout.?;
        child.stdout = null;
        defer out_f.close(io);
        var ended: std.atomic.Value(bool) = .init(false);
        const th_out = try std.Thread.spawn(.{}, Collector.pumpUntil, .{ &col, io, out_f, &ended });
        // ended (on its own, or killed by the watch) but not reaped: its
        // group id is still its own, and the watch kills nothing after this
        waitExited(watch.id);
        watch.done.store(true, .release);
        th_watch.join();
        // nothing it started may outlive it
        watch.killGroup();
        term = child.wait(io) catch null;
        watch.reaped.store(true, .release);
        var waited: u32 = 0;
        while (!col.finished.load(.acquire) and waited < 2000) : (waited += 20) io.sleep(.fromMilliseconds(20), .awake) catch {};
        ended.store(true, .release);
        th_out.join();
    }
    if (is_windows) {
        watch.done.store(true, .release);
        th_watch.join();
    }

    if (watch.reason) |r| return switch (r) {
        .stopped => error.Stopped,
        .timeout => error.Timeout,
        .download => error.DownloadRefused,
    };
    if (col.buf.items.len == 0) {
        // the address was a download: refused (see prepareProfile), and
        // nothing to show. Its folder is made when one starts, but a
        // browser that ends at once may not have made it yet; a page
        // always prints at least <html>…</html>, so printing nothing and
        // ending well is a download too
        const dl = try std.fs.path.join(arena, &.{ profile, "Downloads" });
        if (Io.Dir.cwd().statFile(io, dl, .{})) |_| return error.DownloadRefused else |_| {}
        const ok = if (term) |tm| tm == .exited and tm.exited == 0 else false;
        return if (ok) error.DownloadRefused else error.BrowserFailed;
    }
    return try arena.dupe(u8, col.buf.items);
}

/// The browser's helpers may still be writing as they die: a few tries.
fn removeProfile(io: Io, path: []const u8) void {
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        Io.Dir.cwd().deleteTree(io, path) catch {
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        return;
    }
}

// ---- tests ----

const t = std.testing;

/// What the stand-in browsers in the tests need: `sleep` and `echo`.
const test_env: BrowserEnv = .{ .path = "/usr/bin:/bin" };

fn ex(html: []const u8, base: []const u8) !Page {
    return extract(t.allocator, html, base);
}

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const r = comptime blk: {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        break :blk out;
    };
    return &r;
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (!has(hay, needle)) {
        std.debug.print("\n--- missing: {s}\n--- in:\n{s}\n---\n", .{ needle, hay });
        return error.TestExpectedSubstring;
    }
}

fn expectLacks(hay: []const u8, needle: []const u8) !void {
    if (has(hay, needle)) {
        std.debug.print("\n--- unexpected: {s}\n--- in:\n{s}\n---\n", .{ needle, hay });
        return error.TestUnexpectedSubstring;
    }
}

test "news_article_gives_title_and_article_text_only" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const html =
        \\<!DOCTYPE html>
        \\<html lang="en"><head>
        \\<meta charset="utf-8"><title>Rates held at 4% &ndash; Daily News</title>
        \\<style>body { color: red }</style>
        \\<script>window.dataLayer = []; document.write("<p>tracking</p>");</script>
        \\<script type="application/ld+json">{"headline":"json ld"}</script>
        \\</head>
        \\<body>
        \\<header class="site"><a href="/">Daily News</a><nav><ul><li><a href="/world">World</a></li><li><a href="/business">Business</a></li></ul></nav></header>
        \\<div class="ad" aria-hidden="true">Buy now</div>
        \\<main>
        \\<article>
        \\  <h1>Central bank holds rates at 4%</h1>
        \\  <p class="byline">By <a href="/staff/jane">Jane Roe</a></p>
        \\  <p>The central bank kept its main rate
        \\     unchanged on Thursday, citing    sticky inflation.</p>
        \\  <h2>What analysts said</h2>
        \\  <p>Most economists had expected the decision.<br>Markets barely moved.</p>
        \\  <figure><img src="chart.png" alt="Rate chart"><figcaption>Rates since 2020</figcaption></figure>
        \\  <aside class="related"><a href="/other">Related story</a></aside>
        \\  <p hidden>Secret paywall text</p>
        \\  <form><input name="q"><button>Subscribe</button></form>
        \\</article>
        \\<section class="more"><article><p>Short teaser</p></article></section>
        \\</main>
        \\<footer><p>&copy; 2026 Daily News</p></footer>
        \\<noscript><p>Enable JS</p></noscript>
        \\<script>trackEnd()</script>
        \\</body></html>
    ;
    const p = try extract(arena.allocator(), html, "https://news.example.com/2026/11/rates.html");
    try t.expectEqualStrings("Rates held at 4% \u{2013} Daily News", p.title);
    try t.expect(std.mem.startsWith(u8, p.text, "# Central bank holds rates at 4%\n\n"));
    try expectHas(p.text, "By [Jane Roe](https://news.example.com/staff/jane)");
    try expectHas(p.text, "The central bank kept its main rate unchanged on Thursday, citing sticky inflation.");
    try expectHas(p.text, "\n\n## What analysts said\n\n");
    try expectHas(p.text, "Most economists had expected the decision.\nMarkets barely moved.");
    try expectHas(p.text, "[image: Rate chart]");
    try expectHas(p.text, "Rates since 2020");
    for ([_][]const u8{ "tracking", "dataLayer", "json ld", "color", "World", "Business", "Buy now", "Related story", "Secret", "Subscribe", "Short teaser", "2026 Daily News", "Enable JS", "trackEnd" }) |bad| try expectLacks(p.text, bad);
    try expectLacks(p.text, "\n\n\n");
    try expectLacks(p.text, "  ");
}

test "title_falls_back_to_first_h1" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const p = try extract(arena.allocator(), "<body><h1>Hello <b>there</b></h1><p>x</p></body>", "https://a.example/");
    try t.expectEqualStrings("Hello there", p.title);
    try t.expectEqualStrings("# Hello there\n\nx", p.text);
}

test "links_resolved_against_base" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const html =
        \\<body>
        \\<p><a href="https://other.example/x?y=1&amp;z=2">abs</a></p>
        \\<p><a href="//cdn.example/lib.js">scheme</a></p>
        \\<p><a href="/root/page">root</a></p>
        \\<p><a href="sibling.html">rel</a></p>
        \\<p><a href="../up/there.html#s">dots</a></p>
        \\<p><a href="./here">dot</a></p>
        \\<p><a href="?page=2">query</a></p>
        \\<p><a href="#top">frag</a></p>
        \\<p><a href="javascript:void(0)">js</a></p>
        \\<p><a href="mailto:a@b.example">mail</a></p>
        \\<p><a href=/unquoted/>unq</a></p>
        \\<p><a href='single.html'>single</a></p>
        \\<p><a>nohref</a></p>
        \\<p><a href="/img"><img src=x.png></a>after</p>
        \\</body>
    ;
    const p = try extract(arena.allocator(), html, "https://site.example/a/b/page.html?old=1#frag");
    try expectHas(p.text, "[abs](https://other.example/x?y=1&z=2)");
    try expectHas(p.text, "[scheme](https://cdn.example/lib.js)");
    try expectHas(p.text, "[root](https://site.example/root/page)");
    try expectHas(p.text, "[rel](https://site.example/a/b/sibling.html)");
    try expectHas(p.text, "[dots](https://site.example/a/up/there.html#s)");
    try expectHas(p.text, "[dot](https://site.example/a/b/here)");
    try expectHas(p.text, "[query](https://site.example/a/b/page.html?page=2)");
    try expectHas(p.text, "\nfrag\n");
    try expectHas(p.text, "\njs\n");
    try expectHas(p.text, "\nmail\n");
    try expectHas(p.text, "[unq](https://site.example/unquoted/)");
    try expectHas(p.text, "[single](https://site.example/a/b/single.html)");
    try expectHas(p.text, "\nnohref\n");
    try expectLacks(p.text, "[](");
    try expectHas(p.text, "\nafter");
}

test "base_element_changes_resolution" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const p = try extract(arena.allocator(), "<head><base href=\"/docs/\"></head><body><a href=\"intro\">i</a></body>", "https://x.example/a/b");
    try t.expectEqualStrings("[i](https://x.example/docs/intro)", p.text);
}

test "tables_one_line_per_row" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const html =
        \\<body><p>Prices:</p><table>
        \\<thead><tr><th>Coin</th><th>Price</th></tr></thead>
        \\<tbody>
        \\<tr><td>BTC</td><td>100,000</td></tr>
        \\<tr><td>ETH <p>(ether)</p></td><td>4,000
        \\<tr><td>SOL<td>200
        \\</table><p>End</p></body>
    ;
    const p = try extract(arena.allocator(), html, "");
    try t.expectEqualStrings("Prices:\n\nCoin | Price\nBTC | 100,000\nETH (ether) | 4,000\nSOL | 200\n\nEnd", p.text);
}

test "nested_table_in_a_cell_gets_its_own_rows" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const html = "<body><table><tr><td>Top</td></tr><tr><td><table><tr><td>1.</td><td>First</td></tr><tr><td>2.</td><td>Second</td></tr></table></td></tr></table></body>";
    const p = try extract(arena.allocator(), html, "");
    try t.expectEqualStrings("Top\n\n1. | First\n2. | Second", p.text);
}

test "header_inside_main_is_kept_page_header_is_not" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const html = "<body><header>Site banner</header><main><header><h1>Page heading</h1></header><p>Body text</p><footer>Last edited today</footer></main><footer>Site footer</footer></body>";
    const p = try extract(arena.allocator(), html, "");
    try t.expectEqualStrings("# Page heading\n\nBody text\n\nLast edited today", p.text);
}

test "lists_and_pre" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const html =
        \\<body><ul><li>one<li>two <b>bold</b></li><li>three<ul><li>nested</li></ul></li></ul>
        \\<ol><li><p>para item</p></li></ol>
        \\<pre>
        \\  code   line 1
        \\    line &lt;2&gt;
        \\</pre><p>after</p></body>
    ;
    const p = try extract(arena.allocator(), html, "");
    try t.expectEqualStrings("- one\n- two bold\n- three\n  - nested\n- para item\n\n  code   line 1\n    line <2>\n\nafter", p.text);
}

test "entities_decoded" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const p = try extract(arena.allocator(), "<p>a&amp;b &lt;c&gt; &quot;q&quot; &apos;s&#39; &copy; &euro;5 &#8212; &#x1F600; &#xe9;&eacute; x&nbsp;y &#146; &unknown; & alone &amp</p>", "");
    try t.expectEqualStrings("a&b <c> \"q\" 's' \u{a9} \u{20ac}5 \u{2014} \u{1F600} \u{e9}\u{e9} x y \u{2019} &unknown; & alone &", p.text);
}

test "broken_html_does_not_crash" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "",
        "<",
        "<<<>>>",
        "a < b and c > d",
        "<p>unclosed <b>bold <i>both",
        "<DIV><P>Upper</P></DIV>",
        "<a href=\"never closed>text</a> more",
        "<a href='x' title=\"y>z",
        "<!-- unterminated comment",
        "<script>never closed",
        "</p></div></body>stray closers",
        "<p attr=unquoted other = 'spaced' bare>ok</p>",
        "<!DOCTYPE html><html><body>&#xFFFFFFFF; &#0; &#55296; &#;</body>",
        "<table><td>cell outside tr</table>",
        "<li>orphan li",
        "<svg><title>icon</title></svg><p>text</p>",
        "<p>text</p><nav>unclosed nav",
        "<br/><img/><hr/>",
        "<\x00\xff>",
    };
    for (cases) |c| _ = try extract(a, c, "https://x.example/");
    try t.expectEqualStrings("Upper", (try extract(a, "<DIV><P>Upper</P></DIV>", "")).text);
    try t.expectEqualStrings("a < b and c > d", (try extract(a, "a < b and c > d", "")).text);
    try t.expectEqualStrings("unclosed bold both", (try extract(a, "<p>unclosed <b>bold <i>both", "")).text);
    try t.expectEqualStrings("ok", (try extract(a, "<p attr=unquoted other = 'spaced' bare>ok</p>", "")).text);
    const svg = try extract(a, "<html><head><title>Real</title></head><body><svg><title>icon</title></svg><p>text</p></body></html>", "");
    try t.expectEqualStrings("Real", svg.title);
    try t.expectEqualStrings("text", svg.text);
    try t.expectEqualStrings("- orphan li", (try extract(a, "<li>orphan li", "")).text);
}

test "large_page_extracts_fast" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "<html><head><title>Big</title></head><body><nav>menu</nav><article>");
    var n: usize = 0;
    while (src.items.len < 2 << 20) : (n += 1) {
        try src.print(a, "<div class=\"row r{d}\"><p>Paragraph {d} with <a href=\"/p/{d}\">a link</a> &amp; <b>bold <i>text</p><span>unclosed<li>item<script>var x = {d};</script>\n", .{ n, n, n, n });
    }
    try src.appendSlice(a, "</article></body></html>");
    // a page full of stray quotes and unclosed tags too
    var bad: std.ArrayList(u8) = .empty;
    while (bad.items.len < 2 << 20) try bad.appendSlice(a, "<div a=\"x b='y <p>text \" ");
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    const p = try extract(a, src.items, "https://big.example/");
    _ = try extract(a, bad.items, "https://big.example/");
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - start, std.time.ns_per_ms);
    try t.expectEqualStrings("Big", p.title);
    try expectHas(p.text, "Paragraph 0 with [a link](https://big.example/p/0) & bold text");
    try expectLacks(p.text, "var x");
    try t.expect(took_ms < 1000);
}

test "input_over_4_mib_is_cut" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, max_input + 1000);
    @memset(big, 'a');
    const p = try extract(a, big, "");
    try t.expectEqual(@as(usize, max_input), p.text.len);
}

test "chunk_prefers_line_breaks" {
    const text = "aaaaaaaaa\nbbbbbbbbb\nccccccccc\n"; // 30 bytes, lines of 10
    var c = chunk(text, 0, 22); // the last 20% is bytes 18..22, holding the '\n' at 19
    try t.expectEqualStrings("aaaaaaaaa\nbbbbbbbbb\n", c.text);
    try t.expectEqual(@as(?usize, 20), c.next);
    try t.expectEqual(@as(usize, 30), c.total);
    c = chunk(text, 20, 25);
    try t.expectEqualStrings("ccccccccc\n", c.text);
    try t.expectEqual(@as(?usize, null), c.next);
    // no line break in the last 20%: cut at max
    const flat = rep("x", 50);
    c = chunk(flat, 0, 20);
    try t.expectEqual(@as(usize, 20), c.text.len);
    try t.expectEqual(@as(?usize, 20), c.next);
    // a line break early in the window is not used
    c = chunk("ab\n" ++ rep("y", 40), 0, 20);
    try t.expectEqual(@as(usize, 20), c.text.len);
    // past the end
    c = chunk(text, 30, 10);
    try t.expectEqualStrings("", c.text);
    try t.expectEqual(@as(?usize, null), c.next);
    c = chunk(text, 99, 10);
    try t.expectEqual(@as(?usize, null), c.next);
}

test "chunk_never_splits_utf8" {
    const text = "ab\u{20ac}\u{20ac}\u{20ac}"; // 2 + 3*3 bytes
    var c = chunk(text, 0, 4); // would cut inside the first euro
    try t.expectEqualStrings("ab", c.text);
    try t.expectEqual(@as(?usize, 2), c.next);
    c = chunk(text, 2, 4);
    try t.expectEqualStrings("\u{20ac}", c.text);
    try t.expectEqual(@as(?usize, 5), c.next);
    // walking the whole text in pages gives it back unchanged
    const long = rep("\u{1F600}x\u{e9}\n", 300);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(t.allocator);
    var pos: ?usize = 0;
    while (pos) |s| {
        const k = chunk(long, s, 37);
        try t.expect(k.text.len <= 37);
        try t.expect(std.unicode.utf8ValidateSlice(k.text));
        try got.appendSlice(t.allocator, k.text);
        pos = k.next;
    }
    try t.expectEqualStrings(long, got.items);
    // max smaller than one character still makes progress
    c = chunk("\u{1F600}\u{1F600}", 0, 2);
    try t.expectEqualStrings("\u{1F600}", c.text);
}

test "findBrowser_null_when_nothing_found" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the search itself, without the standard install paths
    try t.expectEqual(@as(?[]const u8, null), try findIn(a, t.io, "/no/such/chrome", "", "", &.{}));
    try t.expectEqual(@as(?[]const u8, null), try findIn(a, t.io, "", "/no/such/either", "/no/such/dir", &.{"/no/such/Chrome.app"}));
    // the real thing, unless this machine has a browser installed
    if (t.environ.containsUnemptyConstant("HARNESS_CHROME")) return error.SkipZigTest;
    for (standard_paths) |p| if (isFile(t.io, p)) return error.SkipZigTest;
    try t.expectEqual(@as(?[]const u8, null), try findBrowser(a, t.io, "/no/such/chrome", "", ""));
}

test "findBrowser_order_and_path_lookup" {
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "bin");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bin/chromium", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "mine", .data = "#!/bin/sh\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const mine = try std.fs.path.join(a, &.{ root, "mine" });
    const path_var = try std.fmt.allocPrint(a, "/no/such:{s}", .{bin});
    const found = (try findIn(a, t.io, "", "", path_var, &.{})).?;
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ bin, "chromium" }), found);
    try t.expectEqualStrings(mine, (try findIn(a, t.io, mine, "", path_var, &.{})).?);
    try t.expectEqualStrings(mine, (try findIn(a, t.io, "/no/such", mine, path_var, &.{})).?);
    try t.expectEqualStrings(mine, (try findIn(a, t.io, "", "", "", &.{ "/no/such", mine })).?);
    // a directory is not a browser
    try t.expectEqual(@as(?[]const u8, null), try findIn(a, t.io, bin, "", "", &.{}));
}

test "render_refuses_non_http_urls" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    for ([_][]const u8{ "file:///etc/passwd", "javascript:alert(1)", "ftp://x.example/", "about:blank", "--headless", "http://x.example/a b", "" }) |u| {
        try t.expectError(error.BadUrl, render(t.allocator, t.io, arena.allocator(), "/no/such/chrome", u, "/tmp", &stop, 1000, 1 << 20, .{}));
    }
}

test "render_stops_and_times_out_and_cleans_up" {
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a stand-in browser: prints its profile dir, then hangs (with a child)
    try tmp.dir.writeFile(t.io, .{ .sub_path = "slow", .data = "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\nsleep 30 &\nsleep 30\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "quick", .data = "#!/bin/sh\necho '<html><body><p>dom</p></body></html>'\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    for ([_][]const u8{ "slow", "quick" }) |n| {
        const p = try std.fs.path.join(a, &.{ root, n });
        var child = try std.process.spawn(t.io, .{ .argv = &.{ "/bin/chmod", "755", p }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        _ = try child.wait(t.io);
    }
    try tmp.dir.createDirPath(t.io, "profiles");
    const profiles = try std.fs.path.join(a, &.{ root, "profiles" });
    var stop: std.atomic.Value(bool) = .init(false);

    const start = Io.Clock.awake.now(t.io).nanoseconds;
    try t.expectError(error.Timeout, render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "slow" }), "https://example.com/", profiles, &stop, 500, 1 << 20, test_env));
    const took_ms = @divFloor(Io.Clock.awake.now(t.io).nanoseconds - start, std.time.ns_per_ms);
    try t.expect(took_ms < 3000);

    const th = try std.Thread.spawn(.{}, struct {
        fn f(flag: *std.atomic.Value(bool)) void {
            t.io.sleep(.fromMilliseconds(300), .awake) catch {};
            flag.store(true, .release);
        }
    }.f, .{&stop});
    try t.expectError(error.Stopped, render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "slow" }), "https://example.com/", profiles, &stop, 20_000, 1 << 20, test_env));
    th.join();
    stop.store(false, .release);

    const dom = try render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "quick" }), "http://example.com/", profiles, &stop, 5000, 1 << 20, test_env);
    try t.expectEqualStrings("<html><body><p>dom</p></body></html>\n", dom);
    const capped = try render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "quick" }), "http://example.com/", profiles, &stop, 5000, 6, test_env);
    try t.expectEqualStrings("<html>", capped);

    // every throwaway profile is gone
    var dir = try tmp.dir.openDir(t.io, "profiles", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    try t.expectEqual(@as(?Io.Dir.Entry, null), try it.next(t.io));
}

test "render_never_kills_a_group_after_the_browser_was_reaped" {
    // once reaped, its pid and group id can be given to another process
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "quick", .data = "#!/bin/sh\necho '<html><body><p>dom</p></body></html>'\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "slow", .data = "#!/bin/sh\nsleep 30 &\nsleep 30\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    for ([_][]const u8{ "quick", "slow" }) |n| {
        var f = try tmp.dir.openFile(t.io, n, .{});
        defer f.close(t.io);
        try f.setPermissions(t.io, .fromMode(0o755));
    }
    var stop: std.atomic.Value(bool) = .init(false);
    const before = late_group_kills.load(.acquire);
    _ = try render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "quick" }), "http://example.com/", root, &stop, 5000, 1 << 20, test_env);
    try t.expectError(error.Timeout, render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "slow" }), "http://example.com/", root, &stop, 300, 1 << 20, test_env));
    try t.expectEqual(before, late_group_kills.load(.acquire));
}

/// The variables in `env` output (one NAME=value a line) other than those
/// in `allowed` and those a shell sets itself (for tests).
pub fn otherVars(a: Allocator, env_out: []const u8, allowed: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, env_out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ARG ") or std.mem.startsWith(u8, line, "<")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = line[0..eq];
        if (name.len == 0) continue;
        const ok = for ([_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_" } ++ .{}) |n| {
            if (std.mem.eql(u8, n, name)) break true;
        } else for (allowed) |n| {
            if (std.mem.eql(u8, n, name)) break true;
        } else false;
        if (!ok) try out.print(a, "{s} ", .{name});
    }
    return out.items;
}

test "render_gives_the_browser_a_small_environment_and_keeps_it_on_the_host" {
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a stand-in browser that shows its environment and arguments
    try tmp.dir.writeFile(t.io, .{ .sub_path = "show", .data = "#!/bin/sh\necho '<html><body><pre>'\nenv\nfor a in \"$@\"; do echo \"ARG $a\"; done\necho '</pre></body></html>'\n" });
    var f = try tmp.dir.openFile(t.io, "show", .{});
    try f.setPermissions(t.io, .fromMode(0o755));
    f.close(t.io);
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    const show = try std.fs.path.join(a, &.{ root, "show" });
    // the host is what the gate reads: a name before @ is refused, not skipped
    try t.expectError(error.BadUrl, render(t.allocator, t.io, a, show, "https://docs.example.com@evil.example/", root, &stop, 5000, 1 << 20, .{ .path = "/usr/bin:/bin" }));
    const out = try render(t.allocator, t.io, a, show, "https://Docs.Example.com.:8443/a", root, &stop, 5000, 1 << 20, .{ .path = "/usr/bin:/bin", .home = "/no/such/home" });
    try t.expectEqualStrings("", try otherVars(a, out, &.{ "PATH", "HOME", "LANG" }));
    try expectHas(out, "PATH=/usr/bin:/bin\n");
    try expectHas(out, "HOME=/no/such/home\n");
    // the system's key store is left alone (macOS Keychain, a desktop keyring)
    try expectHas(out, "ARG --use-mock-keychain\n");
    try expectHas(out, "ARG --password-store=basic\n");
    // no other host than the one the gate allowed is even looked up
    try expectHas(out, "ARG --host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE docs.example.com\n");
    // and the browser is given the address in the form the gate saw
    try expectHas(out, "ARG https://docs.example.com:8443/a\n");
}

test "render_keeps_downloads_off_and_inside_the_profile" {
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a stand-in that shows the settings the browser would start with
    try tmp.dir.writeFile(t.io, .{ .sub_path = "prefs", .data = "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --user-data-dir=*) d=\"${a#--user-data-dir=}\";; esac; done\necho \"PROFILE $d\"\ncat \"$d/Default/Preferences\"\n" });
    var f = try tmp.dir.openFile(t.io, "prefs", .{});
    try f.setPermissions(t.io, .fromMode(0o755));
    f.close(t.io);
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    const out = try render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "prefs" }), "http://example.com/", root, &stop, 5000, 1 << 20, test_env);
    const nl = std.mem.indexOfScalar(u8, out, '\n') orelse return error.TestUnexpectedResult;
    const profile = out["PROFILE ".len..nl];
    const v = jv.parse(a, out[nl + 1 ..]) orelse {
        std.debug.print("\nno settings:\n{s}\n", .{out});
        return error.TestUnexpectedResult;
    };
    try t.expectEqual(@as(?i64, 3), jv.int(jv.get(v, "download_restrictions")));
    const dl = try std.fs.path.join(a, &.{ profile, "Downloads" });
    try t.expectEqualStrings(dl, jv.str(jv.at(v, &.{ "download", "default_directory" })).?);
    try t.expectEqualStrings(dl, jv.str(jv.at(v, &.{ "savefile", "default_directory" })).?);
    try t.expectEqual(false, jv.boolean(jv.at(v, &.{ "download", "prompt_for_download" })).?);
    try t.expectEqual(false, jv.boolean(jv.get(v, "credentials_enable_service")).?);
    // an address that is a download: Chrome prints nothing and starts the
    // download (refused): that is said, not an empty page
    try tmp.dir.writeFile(t.io, .{ .sub_path = "dl", .data = "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --user-data-dir=*) d=\"${a#--user-data-dir=}\";; esac; done\nmkdir -p \"$d/Downloads\"\n" });
    var g = try tmp.dir.openFile(t.io, "dl", .{});
    try g.setPermissions(t.io, .fromMode(0o755));
    g.close(t.io);
    try t.expectError(error.DownloadRefused, render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "dl" }), "http://example.com/file.zip", root, &stop, 5000, 1 << 20, test_env));
}

test "render_says_a_download_even_when_the_browser_ends_before_its_folder_is_made" {
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    // the browser ends at once, printing nothing and making no folder (a
    // helper killed with it never made it): still a download, not a page
    try tmp.dir.writeFile(t.io, .{ .sub_path = "quiet", .data = "#!/bin/sh\nexit 0\n" });
    var g = try tmp.dir.openFile(t.io, "quiet", .{});
    try g.setPermissions(t.io, .fromMode(0o755));
    g.close(t.io);
    var stop: std.atomic.Value(bool) = .init(false);
    try t.expectError(error.DownloadRefused, render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "quiet" }), "http://example.com/file.zip", root, &stop, 5000, 1 << 20, test_env));
}

test "render_removes_throwaway_profiles_a_killed_run_left" {
    if (is_windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "quick", .data = "#!/bin/sh\necho '<html><body><p>dom</p></body></html>'\n" });
    var f = try tmp.dir.openFile(t.io, "quick", .{});
    try f.setPermissions(t.io, .fromMode(0o755));
    f.close(t.io);
    // what a harness killed in the middle of a page left behind
    try tmp.dir.createDirPath(t.io, "state/harness-browser-0123abcd/Default");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/harness-browser-0123abcd/Default/Cookies", .data = "x" });
    try tmp.dir.createDirPath(t.io, "state/harness-web-4567ef01");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/grants", .data = "kept" });
    try tmp.dir.createDirPath(t.io, "state/harness-webby");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    _ = try render(t.allocator, t.io, a, try std.fs.path.join(a, &.{ root, "quick" }), "http://example.com/", try std.fs.path.join(a, &.{ root, "state" }), &stop, 5000, 1 << 20, test_env);
    var dir = try tmp.dir.openDir(t.io, "state", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var names: std.ArrayList(u8) = .empty;
    while (try it.next(t.io)) |e| try names.print(a, "{s} ", .{e.name});
    try t.expect(!has(names.items, "harness-browser-") and !has(names.items, "harness-web-"));
    try expectHas(names.items, "grants");
    try expectHas(names.items, "harness-webby");
}

test "render_of_a_download_saves_nothing_and_says_so" {
    if (is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const browser = (try @import("cdp.zig").testBrowser(a)) orelse return error.SkipZigTest;
    var e: @import("model.zig").TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var rnd: [6]u8 = undefined;
    t.io.random(&rnd);
    const name = try std.fmt.allocPrint(a, "harness-probe-{x}.bin", .{rnd});
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = try std.fmt.allocPrint(a, "pages/{s}", .{name}), .data = "\x00probe bytes" });
    // Chrome starts only with downloads off and inside the profile, so
    // this test can't save a file anywhere else, whatever render does
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "guard", .data = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\for a in "$@"; do case "$a" in --user-data-dir=*) d="${{a#--user-data-dir=}}";; esac; done
        \\grep -qF '"download_restrictions":3' "$d/Default/Preferences" || exit 3
        \\grep -qF "\"default_directory\":\"$d/Downloads\"" "$d/Default/Preferences" || exit 3
        \\exec "{s}" "$@"
        \\
    , .{browser}) });
    var f = try e.tmp.dir.openFile(t.io, "guard", .{});
    try f.setPermissions(t.io, .fromMode(0o755));
    f.close(t.io);
    const guard = try std.fs.path.join(a, &.{ e.dir, "guard" });
    var stop: std.atomic.Value(bool) = .init(false);
    try t.expectError(error.DownloadRefused, render(t.allocator, t.io, a, guard, try std.fmt.allocPrint(a, "http://localhost:{d}/page/{s}", .{ e.server.port, name }), e.dir, &stop, 30_000, 4 << 20, test_env));
    // (looked at, never written: the folder downloads go to by default)
    if (t.environ.getPosix("HOME")) |home| {
        const there = try std.fs.path.join(a, &.{ home, "Downloads", name });
        try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, there, .{}));
    }
}

test "render_loads_nothing_from_another_host" {
    if (is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const browser = (try @import("cdp.zig").testBrowser(a)) orelse return error.SkipZigTest;
    var e: @import("model.zig").TestEnv = undefined;
    try e.init();
    defer e.deinit();
    // 127.0.0.1 is another host than localhost, though the same server
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/h.html", .data = try std.fmt.allocPrint(a, "<html><body><p>page</p><script src=\"http://127.0.0.1:{d}/page/o.bin\"></script><script src=\"/page/s.bin\"></script></body></html>", .{e.server.port}) });
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/o.bin", .data = "document.body.append('other host ran');" });
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "pages/s.bin", .data = "document.body.append('same host ran');" });
    var stop: std.atomic.Value(bool) = .init(false);
    const dom = try render(t.allocator, t.io, a, browser, try std.fmt.allocPrint(a, "http://localhost:{d}/page/h.html", .{e.server.port}), e.dir, &stop, 30_000, 4 << 20, test_env);
    try expectHas(dom, "same host ran");
    try expectLacks(dom, "other host ran");
}

test "render_example_com_with_a_real_browser" {
    if (is_windows) return error.SkipZigTest; // reads the environment the POSIX way
    if (!t.environ.containsUnemptyConstant("HARNESS_NET_TESTS")) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env_chrome: []const u8 = if (t.environ.getPosix("HARNESS_CHROME")) |v| v else "";
    const env_path: []const u8 = if (t.environ.getPosix("PATH")) |v| v else "";
    const browser = (try findBrowser(a, t.io, "", env_chrome, env_path)) orelse return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    const dom = try render(t.allocator, t.io, a, browser, "https://example.com/", root, &stop, 30_000, 4 << 20, test_env);
    const p = try extract(a, dom, "https://example.com/");
    std.debug.print("\nbrowser: {s}\ntitle: {s}\ntext: {s}\n", .{ browser, p.title, p.text });
    try t.expect(has(p.title, "Example Domain"));
    try t.expect(has(p.text, "documentation examples"));
}

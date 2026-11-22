//! RSS 2.0, RSS 1.0 (RDF) and Atom entries: title, link, date. Lenient
//! about everything except structure: anything that is not a feed gives no
//! entries rather than an error.
const std = @import("std");

/// `text`: the entry's summary (description, summary or content) as text.
pub const Entry = struct { title: []const u8, link: []const u8, date: []const u8 = "", text: []const u8 = "" };

/// At most this many entries are read from one feed.
pub const max_entries = 200;

pub fn parse(arena: std.mem.Allocator, xml: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    const atom = std.mem.indexOf(u8, xml, "<feed") != null and std.mem.indexOf(u8, xml, "<entry") != null;
    const open_tag = if (atom) "entry" else "item";
    var pos: usize = 0;
    while (out.items.len < max_entries) {
        const start = findTag(xml, pos, open_tag) orelse break;
        const body_start = (std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break) + 1;
        const close = try std.fmt.allocPrint(arena, "</{s}>", .{open_tag});
        const end = std.mem.indexOfPos(u8, xml, body_start, close) orelse break;
        const body = xml[body_start..end];
        pos = end + close.len;

        const title = try text(arena, element(body, "title") orelse "");
        const link = if (atom) atomLink(body) orelse "" else try text(arena, element(body, "link") orelse element(body, "guid") orelse "");
        const date = try text(arena, element(body, "pubDate") orelse element(body, "published") orelse element(body, "updated") orelse element(body, "dc:date") orelse "");
        const l = std.mem.trim(u8, try decode(arena, link), " \t\r\n");
        if (l.len == 0 or !(std.mem.startsWith(u8, l, "http://") or std.mem.startsWith(u8, l, "https://"))) continue;
        const summary = try text(arena, try decode(arena, element(body, "description") orelse element(body, "summary") orelse element(body, "content") orelse ""));
        try out.append(arena, .{ .title = title, .link = l, .date = date, .text = summary });
    }
    return out.items;
}

/// Index of `<tag` followed by a space, `>` or `/`.
fn findTag(xml: []const u8, from: usize, tag: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, xml, i, "<")) |lt| {
        const rest = xml[lt + 1 ..];
        if (std.mem.startsWith(u8, rest, tag) and rest.len > tag.len) {
            const c = rest[tag.len];
            if (c == ' ' or c == '>' or c == '/' or c == '\n' or c == '\t' or c == '\r') return lt;
        }
        i = lt + 1;
    }
    return null;
}

/// The raw inside of the first `<tag ...>…</tag>` in `body`.
fn element(body: []const u8, tag: []const u8) ?[]const u8 {
    const s = findTag(body, 0, tag) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, body, s, '>') orelse return null;
    if (body[gt - 1] == '/') return "";
    var buf: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&buf, "</{s}>", .{tag}) catch return null;
    const e = std.mem.indexOfPos(u8, body, gt + 1, close) orelse return null;
    return body[gt + 1 .. e];
}

/// Atom: the href of `<link rel="alternate">`, or of a `<link>` without rel.
fn atomLink(body: []const u8) ?[]const u8 {
    var pos: usize = 0;
    var fallback: ?[]const u8 = null;
    while (findTag(body, pos, "link")) |s| {
        const gt = std.mem.indexOfScalarPos(u8, body, s, '>') orelse return fallback;
        const tag = body[s..gt];
        pos = gt;
        const href = attr(tag, "href") orelse continue;
        const rel = attr(tag, "rel");
        if (rel == null or std.mem.eql(u8, rel.?, "alternate")) return href;
        if (fallback == null) fallback = href;
    }
    return fallback;
}

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |at| {
        i = at + name.len;
        if (at == 0 or tag[at - 1] != ' ' and tag[at - 1] != '\n' and tag[at - 1] != '\t') continue;
        var j = at + name.len;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const q = tag[j];
        const e = std.mem.indexOfScalarPos(u8, tag, j + 1, q) orelse return null;
        return tag[j + 1 .. e];
    }
    return null;
}

/// Inner text: CDATA unwrapped, tags removed, entities decoded, spaces
/// collapsed.
pub fn text(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var plain: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (std.mem.startsWith(u8, raw[i..], "<![CDATA[")) {
            const e = std.mem.indexOfPos(u8, raw, i, "]]>") orelse raw.len;
            // CDATA may itself hold escaped HTML; keep it for decode/strip below
            try plain.appendSlice(arena, raw[i + 9 .. e]);
            i = @min(raw.len, e + 3);
            continue;
        }
        try plain.append(arena, raw[i]);
        i += 1;
    }
    const decoded = try decode(arena, plain.items);
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    i = 0;
    while (i < decoded.len) {
        const c = decoded[i];
        if (c == '<') {
            i = (std.mem.indexOfScalarPos(u8, decoded, i, '>') orelse decoded.len - 1) + 1;
            space = true;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            space = true;
            i += 1;
            continue;
        }
        if (space and out.items.len > 0) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

/// `&amp; &lt; &gt; &quot; &apos; &#39; &#NNN; &#xHH;`.
pub fn decode(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, s, i, ';')) |semi| if (semi - i <= 10) {
                const name = s[i + 1 .. semi];
                const named = [_][2][]const u8{ .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" }, .{ "nbsp", " " } };
                const hit = for (named) |n| {
                    if (std.mem.eql(u8, n[0], name)) break n[1];
                } else null;
                if (hit) |h| {
                    try out.appendSlice(arena, h);
                    i = semi + 1;
                    continue;
                }
                if (name.len > 1 and name[0] == '#') {
                    const cp = if (name[1] == 'x' or name[1] == 'X')
                        std.fmt.parseInt(u21, name[2..], 16) catch null
                    else
                        std.fmt.parseInt(u21, name[1..], 10) catch null;
                    if (cp) |c| {
                        var buf: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(c, &buf)) |n| {
                            try out.appendSlice(arena, buf[0..n]);
                            i = semi + 1;
                            continue;
                        } else |_| {}
                    }
                }
            };
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

const t = std.testing;

test "rss_and_atom_entries" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rss = try parse(a,
        \\<?xml version="1.0"?><rss version="2.0"><channel><title>News</title>
        \\<item><title>Zig 0.18 released</title><link>https://ziglang.org/news/0.18</link><pubDate>Tue, 18 Nov 2026 10:00:00 GMT</pubDate></item>
        \\<item><title>No link here</title></item>
        \\<item><title>Second</title><guid>https://example.com/2</guid></item>
        \\</channel></rss>
    );
    try t.expectEqual(2, rss.len);
    try t.expectEqualStrings("Zig 0.18 released", rss[0].title);
    try t.expectEqualStrings("https://ziglang.org/news/0.18", rss[0].link);
    try t.expectEqualStrings("Tue, 18 Nov 2026 10:00:00 GMT", rss[0].date);
    try t.expectEqualStrings("https://example.com/2", rss[1].link);

    const atom = try parse(a,
        \\<feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title>
        \\<entry><title type="html">A post</title><link rel="self" href="https://b.com/self"/><link rel="alternate" href="https://b.com/post"/><updated>2026-11-18T09:00:00Z</updated></entry>
        \\<entry><title>Other</title><link href="https://b.com/other"/></entry>
        \\</feed>
    );
    try t.expectEqual(2, atom.len);
    try t.expectEqualStrings("https://b.com/post", atom[0].link);
    try t.expectEqualStrings("2026-11-18T09:00:00Z", atom[0].date);
    try t.expectEqualStrings("https://b.com/other", atom[1].link);
}

test "malformed_xml_gives_nothing" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(0, (try parse(a, "")).len);
    try t.expectEqual(0, (try parse(a, "<html><body>not a feed</body></html>")).len);
    try t.expectEqual(0, (try parse(a, "<rss><channel><item><title>cut off")).len);
    try t.expectEqual(0, (try parse(a, "<item><link>javascript:alert(1)</link></item>")).len);
}

test "entities_and_cdata" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try parse(a,
        \\<rss><channel><item><title><![CDATA[Fish &amp; <b>chips</b>]]></title>
        \\<link>https://x.com/?a=1&amp;b=2</link></item>
        \\<item><title>caf&#233; &#x2014; &quot;ok&quot;</title><link>https://x.com/c</link></item></channel></rss>
    );
    try t.expectEqualStrings("Fish & chips", e[0].title);
    try t.expectEqualStrings("https://x.com/?a=1&b=2", e[0].link);
    try t.expectEqualStrings("café — \"ok\"", e[1].title);
}

test "a_feed_entry_carries_its_summary_as_text" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rss = try parse(a, "<rss><channel><item><title>T</title><link>https://x.com/1</link><description><![CDATA[<p>Fish &amp; <b>chips</b></p>]]></description></item></channel></rss>");
    try t.expectEqualStrings("Fish & chips", rss[0].text);
    const atom = try parse(a, "<feed><entry><title>A</title><link href=\"https://b.com/a\"/><summary>Short one</summary></entry><entry><title>B</title><link href=\"https://b.com/b\"/><content type=\"html\">&lt;p&gt;Long&lt;/p&gt;</content></entry></feed>");
    try t.expectEqualStrings("Short one", atom[0].text);
    try t.expectEqualStrings("Long", atom[1].text);
    try t.expectEqualStrings("", (try parse(a, "<rss><item><title>x</title><link>https://x.com/2</link></item></rss>"))[0].text);
}

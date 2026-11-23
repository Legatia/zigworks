//! HTML mail bodies as readable text.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The text of `html` (UTF-8) with "\n" line ends: blocks on their own
/// lines, list items as "- ", table cells side by side, links as
/// "label (URL)". Never fails on broken markup.
pub fn toText(a: Allocator, html: []const u8) ![]u8 {
    var w: Writer = .{ .a = a };
    try w.out.ensureTotalCapacity(a, html.len / 2 + 16);
    var i: usize = 0;
    while (i < html.len) {
        switch (html[i]) {
            '<' => i = try tag(&w, html, i),
            '&' => i = try entity(&w, html, i),
            else => {
                const end = std.mem.indexOfAnyPos(u8, html, i, "<&") orelse html.len;
                try w.text(html[i..end]);
                i = end;
            },
        }
    }
    try w.closeLink();
    return tidy(a, w.out.items);
}

const Writer = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    space: bool = false,
    bullet: bool = false,
    pre: u32 = 0,
    list: u32 = 0,
    href: ?[]const u8 = null,
    label_start: usize = 0,
    /// Set once a search for the end of <head> has failed.
    no_head_end: bool = false,

    /// Text as it appears in the markup: whitespace collapses.
    fn text(w: *Writer, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0C) {
                if (c == '\n' and w.pre > 0) try w.newline(1) else w.space = true;
                i += 1;
                continue;
            }
            if (c >= 0x80) {
                if (std.mem.startsWith(u8, s[i..], "\u{A0}")) {
                    w.space = true;
                    i += 2;
                    continue;
                }
                if (invisibleAt(s[i..])) |n| {
                    i += n;
                    continue;
                }
            }
            // A run up to whitespace or a lead byte of the characters above.
            var end = i + 1;
            while (end < s.len and s[end] > ' ' and s[end] != 0xC2 and s[end] != 0xCD and s[end] != 0xE2 and s[end] != 0xEF) end += 1;
            try w.chars(s[i..end]);
            i = end;
        }
    }

    /// Visible characters, after any pending bullet or space.
    fn chars(w: *Writer, s: []const u8) !void {
        if (w.bullet) {
            try w.out.appendSlice(w.a, "- ");
            w.bullet = false;
            w.space = false;
        }
        if (w.space) {
            const items = w.out.items;
            if (items.len > 0 and items[items.len - 1] != '\n' and items[items.len - 1] != ' ') try w.out.append(w.a, ' ');
            w.space = false;
        }
        try w.out.appendSlice(w.a, s);
    }

    /// Ends the line; `n` 2 leaves a blank line.
    fn newline(w: *Writer, n: usize) !void {
        if (w.bullet) return;
        w.space = false;
        while (w.out.items.len > 0 and w.out.items[w.out.items.len - 1] == ' ') w.out.items.len -= 1;
        if (w.out.items.len == 0) return;
        const want = if (w.list > 0) 1 else n;
        var have: usize = 0;
        while (have < want and have < w.out.items.len and w.out.items[w.out.items.len - 1 - have] == '\n') have += 1;
        while (have < want) : (have += 1) try w.out.append(w.a, '\n');
    }

    /// A "<br>": one more line end, so two leave a blank line.
    fn lineBreak(w: *Writer) !void {
        if (w.bullet) return;
        w.space = false;
        while (w.out.items.len > 0 and w.out.items[w.out.items.len - 1] == ' ') w.out.items.len -= 1;
        if (w.out.items.len > 0) try w.out.append(w.a, '\n');
    }

    fn closeLink(w: *Writer) !void {
        const href = w.href orelse return;
        w.href = null;
        const label = std.mem.trim(u8, w.out.items[@min(w.label_start, w.out.items.len)..], " \n");
        const url = std.mem.trim(u8, href, " \t\r\n");
        if (label.len == 0 or sameUrl(label, url)) return;
        if (!std.ascii.startsWithIgnoreCase(url, "http://") and !std.ascii.startsWithIgnoreCase(url, "https://")) return;
        try w.out.appendSlice(w.a, " (");
        try w.out.appendSlice(w.a, url);
        try w.out.append(w.a, ')');
    }
};

/// Whether a link label just repeats its URL.
fn sameUrl(label: []const u8, url: []const u8) bool {
    return std.ascii.eqlIgnoreCase(bareUrl(label), bareUrl(url));
}

fn bareUrl(s: []const u8) []const u8 {
    var u = s;
    for ([_][]const u8{ "https://", "http://" }) |p| {
        if (std.ascii.startsWithIgnoreCase(u, p)) u = u[p.len..];
    }
    if (std.ascii.startsWithIgnoreCase(u, "www.")) u = u[4..];
    return std.mem.trimEnd(u8, u, "/");
}

/// Length of a zero-width character at the start of `s`, or null.
fn invisibleAt(s: []const u8) ?usize {
    for ([_][]const u8{ "\u{AD}", "\u{34F}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{2060}", "\u{FEFF}" }) |z| {
        if (std.mem.startsWith(u8, s, z)) return z.len;
    }
    return null;
}

const Kind = enum { skip, head, br, para, line, li, list, cell, a, pre, other };

const kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "script", .skip },     .{ "style", .skip },      .{ "title", .skip },   .{ "xml", .skip },
    .{ "head", .head },       .{ "br", .br },           .{ "p", .para },       .{ "h1", .para },
    .{ "h2", .para },         .{ "h3", .para },         .{ "h4", .para },      .{ "h5", .para },
    .{ "h6", .para },         .{ "blockquote", .para }, .{ "table", .para },   .{ "hr", .para },
    .{ "dl", .para },         .{ "pre", .pre },         .{ "ul", .list },      .{ "ol", .list },
    .{ "li", .li },           .{ "div", .line },        .{ "tr", .line },      .{ "dt", .line },
    .{ "dd", .line },         .{ "section", .line },    .{ "article", .line }, .{ "header", .line },
    .{ "footer", .line },     .{ "center", .line },     .{ "form", .line },    .{ "address", .line },
    .{ "nav", .line },        .{ "aside", .line },      .{ "main", .line },    .{ "figure", .line },
    .{ "figcaption", .line }, .{ "caption", .line },    .{ "td", .cell },      .{ "th", .cell },
    .{ "a", .a },
});

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0C;
}

/// Handles the markup starting at `h[i]` (a "<"); returns where text resumes.
fn tag(w: *Writer, h: []const u8, i: usize) !usize {
    if (std.mem.startsWith(u8, h[i..], "<!--")) {
        const end = std.mem.indexOfPos(u8, h, i + 4, "-->") orelse return h.len;
        return end + 3;
    }
    var j = i + 1;
    if (j < h.len and (h[j] == '!' or h[j] == '?')) {
        const end = std.mem.indexOfScalarPos(u8, h, j, '>') orelse return h.len;
        return end + 1;
    }
    const closing = j < h.len and h[j] == '/';
    if (closing) j += 1;
    if (j >= h.len or !std.ascii.isAlphabetic(h[j])) {
        try w.chars("<");
        return i + 1;
    }
    const name_start = j;
    while (j < h.len and (std.ascii.isAlphanumeric(h[j]) or h[j] == '-' or h[j] == ':')) j += 1;
    var name_buf: [16]u8 = undefined;
    const raw_name = h[name_start..j];
    const kind: Kind = if (raw_name.len <= name_buf.len)
        kinds.get(std.ascii.lowerString(&name_buf, raw_name)) orelse .other
    else
        .other;

    var href: ?[]const u8 = null;
    while (true) {
        while (j < h.len and (isSpace(h[j]) or h[j] == '/')) j += 1;
        if (j >= h.len) return h.len;
        if (h[j] == '>') {
            j += 1;
            break;
        }
        const an_start = j;
        while (j < h.len and !isSpace(h[j]) and h[j] != '=' and h[j] != '>' and h[j] != '/') j += 1;
        if (j == an_start) j += 1;
        const attr = h[an_start..j];
        while (j < h.len and isSpace(h[j])) j += 1;
        if (j < h.len and h[j] == '=') {
            j += 1;
            while (j < h.len and isSpace(h[j])) j += 1;
            if (j >= h.len) return h.len;
            var value: []const u8 = undefined;
            if (h[j] == '"' or h[j] == '\'') {
                const end = std.mem.indexOfScalarPos(u8, h, j + 1, h[j]) orelse return h.len;
                value = h[j + 1 .. end];
                j = end + 1;
            } else {
                const vs = j;
                while (j < h.len and !isSpace(h[j]) and h[j] != '>') j += 1;
                value = h[vs..j];
            }
            if (std.ascii.eqlIgnoreCase(attr, "href")) href = value;
        }
    }

    switch (kind) {
        .skip => if (!closing) {
            var needle_buf: [18]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "</{s}", .{raw_name}) catch unreachable;
            const end = std.ascii.findIgnoreCasePos(h, j, needle) orelse return h.len;
            const gt = std.mem.indexOfScalarPos(u8, h, end, '>') orelse return h.len;
            return gt + 1;
        },
        .head => if (!closing and !w.no_head_end) {
            if (std.ascii.findIgnoreCasePos(h, j, "</head")) |end| {
                const gt = std.mem.indexOfScalarPos(u8, h, end, '>') orelse return h.len;
                return gt + 1;
            }
            if (std.ascii.findIgnoreCasePos(h, j, "<body")) |body| return body;
            w.no_head_end = true;
        },
        .br => try w.lineBreak(),
        .para => try w.newline(2),
        .line => try w.newline(1),
        .pre => {
            try w.newline(2);
            if (closing) w.pre -|= 1 else w.pre += 1;
        },
        .list => {
            if (closing) w.list -|= 1;
            try w.newline(2);
            if (!closing) w.list += 1;
        },
        .li => {
            try w.newline(1);
            if (!closing) w.bullet = true;
        },
        .cell => if (!closing) {
            w.space = true;
        },
        .a => {
            try w.closeLink();
            if (!closing) {
                if (href) |raw| {
                    if (!std.ascii.startsWithIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), "mailto:")) {
                        w.href = try decodeEntities(w.a, raw);
                        w.label_start = w.out.items.len;
                    }
                }
            }
        },
        .other => {},
    }
    return j;
}

/// Handles the "&" at `h[i]`; returns where text resumes.
fn entity(w: *Writer, h: []const u8, i: usize) !usize {
    var buf: [4]u8 = undefined;
    if (entityAt(h, i, &buf)) |e| {
        switch (e.cp) {
            0xA0, 0x2002...0x200A => w.space = true,
            0xAD, 0x34F, 0x200B...0x200F, 0x2060, 0xFEFF => {},
            else => try w.chars(e.bytes),
        }
        return e.end;
    }
    try w.chars("&");
    return i + 1;
}

const Entity = struct { cp: u21, bytes: []const u8, end: usize };

/// The character reference starting at `h[i]` ("&"), or null when there is none.
fn entityAt(h: []const u8, i: usize, buf: *[4]u8) ?Entity {
    var j = i + 1;
    var cp: u21 = undefined;
    if (j < h.len and h[j] == '#') {
        j += 1;
        const hex = j < h.len and (h[j] == 'x' or h[j] == 'X');
        if (hex) j += 1;
        const ds = j;
        var v: u32 = 0;
        while (j < h.len and j - ds < 8) : (j += 1) {
            const d = std.fmt.charToDigit(h[j], if (hex) 16 else 10) catch break;
            v = v * (if (hex) @as(u32, 16) else 10) + d;
        }
        if (j == ds or v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return null;
        if (j < h.len and std.ascii.isAlphanumeric(h[j])) return null;
        if (j < h.len and h[j] == ';') j += 1;
        cp = @intCast(v);
    } else {
        const ns = j;
        while (j < h.len and j - ns < 12 and std.ascii.isAlphanumeric(h[j])) j += 1;
        const name = h[ns..j];
        if (j < h.len and h[j] == ';') {
            cp = named.get(name) orelse return null;
            j += 1;
        } else {
            // Without ";" only the few that old mailers leave that way.
            const legacy = std.StaticStringMap(u21).initComptime(.{
                .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "nbsp", 0xA0 },
            });
            cp = legacy.get(name) orelse return null;
        }
    }
    const n = std.unicode.utf8Encode(cp, buf) catch return null;
    return .{ .cp = cp, .bytes = buf[0..n], .end = j };
}

/// `s` with character references replaced (for attribute values).
fn decodeEntities(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            var buf: [4]u8 = undefined;
            if (entityAt(s, i, &buf)) |e| {
                try out.appendSlice(a, e.bytes);
                i = e.end;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

const named = std.StaticStringMap(u21).initComptime(.{
    .{ "amp", '&' },       .{ "lt", '<' },       .{ "gt", '>' },        .{ "quot", '"' },
    .{ "apos", '\'' },     .{ "nbsp", 0xA0 },    .{ "ensp", 0x2002 },   .{ "emsp", 0x2003 },
    .{ "thinsp", 0x2009 }, .{ "shy", 0xAD },     .{ "zwnj", 0x200C },   .{ "zwj", 0x200D },
    .{ "lrm", 0x200E },    .{ "rlm", 0x200F },
    .{ "oacute", 'ó' },
    .{ "Oacute", 'Ó' },
    .{ "eacute", 'é' },
    .{ "Eacute", 'É' },
    .{ "aacute", 'á' },
    .{ "Aacute", 'Á' },
    .{ "iacute", 'í' },
    .{ "Iacute", 'Í' },
    .{ "uacute", 'ú' },
    .{ "Uacute", 'Ú' },
    .{ "yacute", 'ý' },
    .{ "agrave", 'à' },
    .{ "egrave", 'è' },
    .{ "ccedil", 'ç' },
    .{ "ntilde", 'ñ' },
    .{ "acirc", 'â' },
    .{ "ecirc", 'ê' },
    .{ "ocirc", 'ô' },
    .{ "uuml", 'ü' },
    .{ "Uuml", 'Ü' },
    .{ "ouml", 'ö' },
    .{ "Ouml", 'Ö' },
    .{ "auml", 'ä' },
    .{ "Auml", 'Ä' },
    .{ "szlig", 'ß' },
    .{ "aogon", 'ą' },
    .{ "Aogon", 'Ą' },
    .{ "cacute", 'ć' },
    .{ "Cacute", 'Ć' },
    .{ "eogon", 'ę' },
    .{ "Eogon", 'Ę' },
    .{ "lstrok", 'ł' },
    .{ "Lstrok", 'Ł' },
    .{ "nacute", 'ń' },
    .{ "Nacute", 'Ń' },
    .{ "sacute", 'ś' },
    .{ "Sacute", 'Ś' },
    .{ "zacute", 'ź' },
    .{ "Zacute", 'Ź' },
    .{ "zdot", 'ż' },
    .{ "Zdot", 'Ż' },
    .{ "scaron", 'š' },
    .{ "Scaron", 'Š' },
    .{ "zcaron", 'ž' },
    .{ "Zcaron", 'Ž' },
    .{ "ccaron", 'č' },
    .{ "Ccaron", 'Č' },
    .{ "ecaron", 'ě' },
    .{ "euro", 0x20AC },   .{ "pound", 0xA3 },   .{ "cent", 0xA2 },     .{ "yen", 0xA5 },
    .{ "ndash", 0x2013 },  .{ "mdash", 0x2014 }, .{ "hellip", 0x2026 }, .{ "laquo", 0xAB },
    .{ "raquo", 0xBB },    .{ "bdquo", 0x201E }, .{ "ldquo", 0x201C },  .{ "rdquo", 0x201D },
    .{ "lsquo", 0x2018 },  .{ "rsquo", 0x2019 }, .{ "sbquo", 0x201A },  .{ "copy", 0xA9 },
    .{ "reg", 0xAE },      .{ "trade", 0x2122 }, .{ "bull", 0x2022 },   .{ "middot", 0xB7 },
    .{ "times", 0xD7 },    .{ "deg", 0xB0 },     .{ "plusmn", 0xB1 },   .{ "sect", 0xA7 },
    .{ "para", 0xB6 },     .{ "frac12", 0xBD },  .{ "rarr", 0x2192 },   .{ "larr", 0x2190 },
    .{ "iexcl", 0xA1 },    .{ "iquest", 0xBF },
});

/// Lines trimmed, runs of spaces collapsed, at most one blank line in a
/// row, no blank lines at the ends.
fn tidy(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var blank = false;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            blank = out.items.len > 0;
            continue;
        }
        if (out.items.len > 0) out.appendSliceAssumeCapacity(if (blank) "\n\n" else "\n");
        blank = false;
        var prev_space = false;
        for (line) |c| {
            const sp = c == ' ' or c == '\t';
            if (sp and prev_space) continue;
            try out.append(a, if (sp) ' ' else c);
            prev_space = sp;
        }
    }
    return out.items;
}

const testing = std.testing;

fn expectText(want: []const u8, html: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try toText(arena.allocator(), html));
}

test "blocks_lists_and_tables_give_lines" {
    try expectText(
        \\Dzień dobry,
        \\
        \\Twoja faktura jest gotowa.
        \\
        \\- Numer: 12/2026
        \\- Kwota: 249,99 zł
        \\
        \\Termin 05.12.2026
        \\Status Nieopłacona
        \\
        \\Pozdrawiamy
        \\Zespół
        \\Obsługi
    ,
        "<html><head><meta charset=\"utf-8\"><title>Powiadomienie</title></head>\r\n" ++
            "<body><div>Dzień dobry,</div><p>Twoja faktura jest gotowa.</p>\r\n" ++
            "<ul><li>Numer: 12/2026</li><li><p>Kwota: 249,99&nbsp;zł</p></li></ul>\r\n" ++
            "<table><tr><td>Termin</td><td>05.12.2026</td></tr>\r\n<tr><th>Status</th><td>Nieopłacona</td></tr></table>\r\n" ++
            "Pozdrawiamy<br>Zespół<BR/>Obsługi</body></html>\r\n",
    );
    try expectText("Title\n\nText\n\nmore\n\nend", "<h1>Title</h1>Text<hr>more<blockquote>end</blockquote>");
    try expectText("- a\n- b", "<ol><li>a<li>b</ol>");
    // Gmail and Outlook paragraphs.
    try expectText("Pasuje.\n\nAnna", "<div dir=\"ltr\">Pasuje.<div><br></div><div>Anna</div></div>");
    try expectText("Dzień dobry,\n\nproszę o fakturę.", "<p class=MsoNormal>Dzień dobry,<o:p></o:p></p>\r\n<p class=MsoNormal><o:p>&nbsp;</o:p></p>\r\n<p class=MsoNormal>proszę o fakturę.<o:p></o:p></p>");
}

test "links_show_their_url" {
    try expectText(
        \\Śledź przesyłkę: kliknij tutaj (https://inpost.pl/sledzenie-przesylek?number=620000000000000000000000)
        \\
        \\https://www.mbank.pl/
        \\
        \\Zobacz (https://example.com/a?x=1&y=2)
        \\
        \\Pisz: pomoc@example.pl
        \\
        \\www.allegro.pl
    ,
        "<p>Śledź przesyłkę: <a class=\"btn\" href=\"https://inpost.pl/sledzenie-przesylek?number=620000000000000000000000\" target=\"_blank\">kliknij <b>tutaj</b></a></p>\r\n" ++
            "<p><a href=\"https://www.mbank.pl/\">https://www.mbank.pl/</a></p>\r\n" ++
            "<p><A HREF=\"https://example.com/a?x=1&amp;y=2\">Zobacz</A></p>\r\n" ++
            "<p>Pisz: <a href=\"mailto:pomoc@example.pl\">pomoc@example.pl</a></p>\r\n" ++
            "<p><a href=\"https://example.com/x\"><img src=\"logo.png\" alt=\"Logo\"></a></p>\r\n" ++
            "<p><a href='https://www.allegro.pl'>www.allegro.pl</a></p>\r\n",
    );
}

test "head_script_style_and_comments_dropped" {
    try expectText("Hello\n\nWorld",
        \\<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN">
        \\<html><head><title>Newsletter</title><style type="text/css">.x { color: red; } td > p {}</style>
        \\<script>var a = "<p>no</p>";</script></head><body><!-- preheader <p>hidden</p> --><!--[if mso]><table><tr><td><![endif]-->
        \\<p>Hello</p><script type="text/javascript">alert("x")</script><STYLE>p{}</STYLE><p>World</p><!--[if mso]></td></tr></table><![endif]--></body></html>
    );
    // A head that is never closed ends where the body starts.
    try expectText("Body", "<html><head><meta name=x><body>Body</body></html>");
}

test "entities_decode" {
    try expectText(
        "Fish & Chips <3 > \"q\" 'a' 'b' ą ł óÓ éá üöäß 5€ a–b a—b wait… «x» „Tak” “y” ‘z’ © ® cooperate ab &unknown; & AT&T",
        "<p>Fish &amp; Chips &lt;3 &gt; &quot;q&quot; &apos;a&apos; &#39;b&#39; &#261; &#x142; &oacute;&Oacute; &eacute;&aacute; " ++
            "&uuml;&ouml;&auml;&szlig; 5&euro; a&ndash;b a&mdash;b wait&hellip; &laquo;x&raquo; &bdquo;Tak&rdquo; &ldquo;y&rdquo; " ++
            "&lsquo;z&rsquo; &copy; &reg; co&shy;operate a&zwnj;b &unknown; &amp AT&T</p>",
    );
    try expectText("Łódź", "&Lstrok;&oacute;d&zacute;");
}

test "whitespace_collapses_and_blank_lines_limited" {
    try expectText("lots of space here\n\nnext", "<div>   lots    of\r\n\r\n   space\t\there  </div><br><br><br><br><div>next</div>");
    try expectText("a b\nc", "<pre>a  b\n  c</pre>");
    try expectText("x y", "x&nbsp;&nbsp;&nbsp;y");
    try expectText("Preheader\nText", "<div>Preheader&nbsp;&zwnj;&nbsp;&#847;&zwnj;&nbsp;</div><div>Text</div>");
}

test "broken_html_does_not_fail" {
    try expectText("Unclosed bold", "<p>Unclosed <b>bold");
    try expectText("a < b and c > d", "a < b and c > d");
    try expectText("x", "<p>x</p><!-- never closed <p>y</p>");
    try expectText("label (https://x.pl)", "<a href=\"https://x.pl\">label");
    try expectText("text", "<div class=\"a>b\">text</div>");
    try expectText("ok", "ok<scr");
    try expectText("", "");
    try expectText("", "<script>never closed");
    try expectText("a", "a<a href=\"https://x.pl");
    try expectText("&#99999999; &#xZZ; &", "&#99999999; &#xZZ; &");
}

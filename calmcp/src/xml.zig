//! A small XML reader for WebDAV answers (RFC 4918 multistatus): elements
//! by their local names (the namespace prefix dropped: `d:href`, `D:href`
//! and `href` under a default namespace are all `href`), attributes, text
//! with entities and CDATA. Comments, processing instructions and the
//! doctype are passed over.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    /// The local name, without its prefix.
    name: []const u8,
    attrs: []const Attr = &.{},
    kids: []const Node = &.{},
    /// The text directly inside it, entities decoded.
    text: []const u8 = "",

    pub fn child(n: *const Node, name: []const u8) ?*const Node {
        for (n.kids) |*k| if (std.mem.eql(u8, k.name, name)) return k;
        return null;
    }

    /// The first element called `name` at any depth below (or `n` itself).
    pub fn find(n: *const Node, name: []const u8) ?*const Node {
        if (std.mem.eql(u8, n.name, name)) return n;
        for (n.kids) |*k| if (k.find(name)) |f| return f;
        return null;
    }

    /// Follows children by name: `n.path(&.{"propstat", "prop", "getetag"})`.
    pub fn path(n: *const Node, names: []const []const u8) ?*const Node {
        var cur = n;
        for (names) |x| cur = cur.child(x) orelse return null;
        return cur;
    }

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs) |x| if (std.mem.eql(u8, x.name, name)) return x.value;
        return null;
    }

    /// Its text trimmed of white space.
    pub fn value(n: *const Node) []const u8 {
        return std.mem.trim(u8, n.text, " \t\r\n");
    }
};

/// The root element of `text`.
pub fn parse(a: Allocator, text: []const u8) !Node {
    var p: Parser = .{ .a = a, .s = text };
    p.skipMisc();
    if (p.i >= p.s.len or p.s[p.i] != '<') return error.BadXml;
    const root = try p.element(0);
    return root;
}

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn startsWith(p: *Parser, x: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], x);
    }

    fn skipTo(p: *Parser, end: []const u8) void {
        if (std.mem.indexOfPos(u8, p.s, p.i, end)) |k| p.i = k + end.len else p.i = p.s.len;
    }

    /// White space, comments, <?…?> and <!DOCTYPE …> before or after the root.
    fn skipMisc(p: *Parser) void {
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                p.i += 1;
            } else if (p.startsWith("<?")) {
                p.skipTo("?>");
            } else if (p.startsWith("<!--")) {
                p.skipTo("-->");
            } else if (p.startsWith("<!")) {
                p.skipTo(">");
            } else break;
        }
    }

    fn nameEnd(p: *Parser) usize {
        var k = p.i;
        while (k < p.s.len) : (k += 1) switch (p.s[k]) {
            ' ', '\t', '\r', '\n', '/', '>', '=' => break,
            else => {},
        };
        return k;
    }

    fn skipSpace(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\r' or p.s[p.i] == '\n')) p.i += 1;
    }

    /// An element starting at `<`, to its end tag.
    fn element(p: *Parser, depth: u32) anyerror!Node {
        if (depth > 64) return error.BadXml;
        p.i += 1;
        const ne = p.nameEnd();
        if (ne == p.i) return error.BadXml;
        const qname = p.s[p.i..ne];
        p.i = ne;
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            p.skipSpace();
            if (p.i >= p.s.len) return error.BadXml;
            if (p.startsWith("/>")) {
                p.i += 2;
                return .{ .name = local(qname), .attrs = attrs.items };
            }
            if (p.s[p.i] == '>') {
                p.i += 1;
                break;
            }
            const an_end = p.nameEnd();
            if (an_end == p.i) return error.BadXml;
            const an = p.s[p.i..an_end];
            p.i = an_end;
            p.skipSpace();
            if (p.i >= p.s.len or p.s[p.i] != '=') return error.BadXml;
            p.i += 1;
            p.skipSpace();
            if (p.i >= p.s.len or (p.s[p.i] != '"' and p.s[p.i] != '\'')) return error.BadXml;
            const q = p.s[p.i];
            const close = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, q) orelse return error.BadXml;
            try attrs.append(p.a, .{ .name = an, .value = try decode(p.a, p.s[p.i + 1 .. close]) });
            p.i = close + 1;
        }
        var kids: std.ArrayList(Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.s.len) return error.BadXml;
            if (p.startsWith("</")) {
                p.i += 2;
                const ce = p.nameEnd();
                if (!std.mem.eql(u8, p.s[p.i..ce], qname)) return error.BadXml;
                p.i = ce;
                p.skipSpace();
                if (p.i >= p.s.len or p.s[p.i] != '>') return error.BadXml;
                p.i += 1;
                return .{ .name = local(qname), .attrs = attrs.items, .kids = kids.items, .text = text.items };
            }
            if (p.startsWith("<![CDATA[")) {
                const from = p.i + 9;
                const end = std.mem.indexOfPos(u8, p.s, from, "]]>") orelse return error.BadXml;
                try text.appendSlice(p.a, p.s[from..end]);
                p.i = end + 3;
                continue;
            }
            if (p.startsWith("<!--")) {
                p.skipTo("-->");
                continue;
            }
            if (p.startsWith("<?")) {
                p.skipTo("?>");
                continue;
            }
            if (p.s[p.i] == '<') {
                try kids.append(p.a, try p.element(depth + 1));
                continue;
            }
            const next = std.mem.indexOfScalarPos(u8, p.s, p.i, '<') orelse p.s.len;
            try text.appendSlice(p.a, try decode(p.a, p.s[p.i..next]));
            p.i = next;
        }
    }
};

fn local(qname: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, qname, ':') orelse return qname;
    return qname[colon + 1 ..];
}

/// Text with its entities decoded (&amp; &lt; &gt; &quot; &apos; &#N; &#xH;).
fn decode(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try o.append(a, s[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, s, i, ';') orelse {
            try o.append(a, s[i]);
            i += 1;
            continue;
        };
        const ent = s[i + 1 .. semi];
        const named = [_]struct { []const u8, u8 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' } };
        var done = false;
        for (named) |n| if (std.mem.eql(u8, ent, n[0])) {
            try o.append(a, n[1]);
            done = true;
        };
        if (!done and ent.len > 1 and ent[0] == '#') {
            const cp = if (ent[1] == 'x' or ent[1] == 'X') std.fmt.parseInt(u21, ent[2..], 16) catch null else std.fmt.parseInt(u21, ent[1..], 10) catch null;
            if (cp) |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch 0;
                if (n > 0) {
                    try o.appendSlice(a, buf[0..n]);
                    done = true;
                }
            }
        }
        if (!done) try o.appendSlice(a, s[i .. semi + 1]);
        i = semi + 1;
    }
    return o.items;
}

/// `s` with &, <, >, " and ' written as entities.
pub fn escape(a: Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '&' => try o.appendSlice(a, "&amp;"),
        '<' => try o.appendSlice(a, "&lt;"),
        '>' => try o.appendSlice(a, "&gt;"),
        '"' => try o.appendSlice(a, "&quot;"),
        '\'' => try o.appendSlice(a, "&apos;"),
        else => try o.append(a, ch),
    };
    return o.items;
}

// ---- tests ----

const tt = std.testing;

test "a_multistatus_reads_with_any_prefix" {
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- a comment -->
        \\<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
        \\  <d:response>
        \\    <d:href>/dav/calendars/anna/personal/dentist-1.ics</d:href>
        \\    <d:propstat>
        \\      <d:prop>
        \\        <d:getetag>&quot;abc-1&quot;</d:getetag>
        \\        <cal:calendar-data><![CDATA[BEGIN:VCALENDAR
        \\SUMMARY:Fish & chips <later>
        \\END:VCALENDAR
        \\]]></cal:calendar-data>
        \\      </d:prop>
        \\      <d:status>HTTP/1.1 200 OK</d:status>
        \\    </d:propstat>
        \\  </d:response>
        \\  <response xmlns="DAV:"><href>/x%20y/</href><propstat><prop><resourcetype><collection/><C:calendar xmlns:C="urn:ietf:params:xml:ns:caldav"/></resourcetype><C:supported-calendar-component-set xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp name='VEVENT'/></C:supported-calendar-component-set><displayname>Work &amp; more &#8211; &#x2713;</displayname></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        \\</d:multistatus>
    ;
    const root = try parse(a, text);
    try tt.expectEqualStrings("multistatus", root.name);
    try tt.expectEqual(@as(usize, 2), root.kids.len);
    const r0 = &root.kids[0];
    try tt.expectEqualStrings("/dav/calendars/anna/personal/dentist-1.ics", r0.child("href").?.value());
    try tt.expectEqualStrings("\"abc-1\"", r0.path(&.{ "propstat", "prop", "getetag" }).?.value());
    const data = r0.find("calendar-data").?.text;
    try tt.expect(std.mem.indexOf(u8, data, "SUMMARY:Fish & chips <later>") != null);
    const r1 = &root.kids[1];
    try tt.expectEqualStrings("/x%20y/", r1.child("href").?.value());
    try tt.expect(r1.find("calendar") != null);
    try tt.expectEqualStrings("VEVENT", r1.find("comp").?.attr("name").?);
    try tt.expectEqualStrings("Work & more – ✓", r1.find("displayname").?.value());
    try tt.expect(r1.find("nothing-here") == null);
    try tt.expectError(error.BadXml, parse(a, "<a><b></a>"));
    try tt.expectError(error.BadXml, parse(a, "no xml"));
    try tt.expectEqualStrings("a &amp; b &lt;c&gt; &quot;d&quot;", try escape(a, "a & b <c> \"d\""));
}

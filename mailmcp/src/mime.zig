//! Reading mail (RFC 5322 headers, MIME parts, encodings) into text, and
//! writing plain-text mail.
const std = @import("std");
const Allocator = std.mem.Allocator;
const charset = @import("charset.zig");
const html = @import("html.zig");

/// A part that is listed, not read: its decoded name, lowercased type and
/// decoded size in bytes.
pub const Attachment = struct { name: []const u8, type: []const u8, size: usize };

/// The first event of a text/calendar part or .ics attachment.
pub const Invite = struct {
    /// The calendar's METHOD: REQUEST, CANCEL, REPLY, ...
    method: []const u8 = "",
    summary: []const u8 = "",
    /// "YYYY-MM-DD HH:MM" (in the event's own zone, or with " UTC"), or
    /// "YYYY-MM-DD" for all-day events.
    start: []const u8 = "",
    end: []const u8 = "",
    location: []const u8 = "",
    /// The organizer's address, lowercased.
    organizer: []const u8 = "",
};

/// A message/rfc822 part.
pub const Forwarded = struct {
    from: []const u8 = "",
    subject: []const u8 = "",
    date: []const u8 = "",
    text: []const u8 = "",
};

/// What the receiving server's Authentication-Results says about the From
/// domain.
pub const Auth = enum { pass, fail, none };

pub const Mail = struct {
    /// Decoded: "Name <addr>" or "addr".
    from: []const u8 = "",
    /// The addr-spec, lowercased.
    from_addr: []const u8 = "",
    /// Decoded display name; "" if none.
    from_name: []const u8 = "",
    /// Addr-spec of Reply-To, lowercased; "" if none.
    reply_to: []const u8 = "",
    /// Decoded header values.
    to: []const u8 = "",
    cc: []const u8 = "",
    /// Decoded, on one line.
    subject: []const u8 = "",
    /// The Date header as written (unfolded).
    date: []const u8 = "",
    /// Seconds since 1970 UTC, from Date.
    date_s: ?i64 = null,
    /// "<...>" as written.
    message_id: []const u8 = "",
    in_reply_to: []const u8 = "",
    /// The ids, separated by single spaces.
    references: []const u8 = "",
    auth: Auth = .none,
    /// The body as UTF-8 text with "\n" line ends.
    text: []const u8 = "",
    /// The text came from HTML (there was no text/plain part).
    from_html: bool = false,
    attachments: []const Attachment = &.{},
    invite: ?Invite = null,
    forwarded: []const Forwarded = &.{},
};

/// Reads a whole message. Never fails on content: broken or truncated
/// mail gives what can be read. Nothing in the result points into `raw`.
pub fn parse(a: Allocator, raw: []const u8) !Mail {
    return parseDepth(a, raw, 0);
}

/// Forwarded mail inside forwarded mail is read this deep.
const max_forward_depth = 5;
/// Multiparts inside multiparts are read this deep.
const max_nest = 32;

fn parseDepth(a: Allocator, raw: []const u8, depth: u8) Allocator.Error!Mail {
    const head = try splitHead(a, raw);
    var m: Mail = .{};

    if (head.first("from")) |v| {
        const value = try unfold(a, v);
        const item = firstItem(value);
        const addr = addrOf(item);
        m.from_name = try displayName(a, item);
        m.from_addr = try std.ascii.allocLowerString(a, addr);
        m.from = if (m.from_name.len > 0 and addr.len > 0)
            try std.fmt.allocPrint(a, "{s} <{s}>", .{ m.from_name, addr })
        else if (addr.len > 0) try a.dupe(u8, addr) else try decodeWords(a, value);
    }
    if (head.first("reply-to")) |v| m.reply_to = try std.ascii.allocLowerString(a, addrOf(firstItem(try unfold(a, v))));
    if (head.first("to")) |v| m.to = try decodeWords(a, v);
    if (head.first("cc")) |v| m.cc = try decodeWords(a, v);
    if (head.first("subject")) |v| m.subject = std.mem.trim(u8, try decodeWords(a, v), " ");
    if (head.first("date")) |v| {
        m.date = try a.dupe(u8, try unfold(a, v));
        m.date_s = parseDate(m.date);
    }
    if (head.first("message-id")) |v| m.message_id = try a.dupe(u8, firstId(try unfold(a, v)));
    if (head.first("in-reply-to")) |v| m.in_reply_to = try a.dupe(u8, firstId(try unfold(a, v)));
    if (head.first("references")) |v| m.references = try joinIds(a, try unfold(a, v));
    if (head.first("authentication-results")) |v| {
        const at = std.mem.lastIndexOfScalar(u8, m.from_addr, '@');
        m.auth = try authResult(a, v, if (at) |i| m.from_addr[i + 1 ..] else "");
    }

    var w: Walker = .{ .a = a, .depth = depth };
    try w.walk(head, 0, .all);
    m.text = try tidyText(a, try std.mem.join(a, "\n\n", w.texts.items));
    m.from_html = w.html_parts > 0 and w.plain_parts == 0;
    m.attachments = w.attachments.items;
    m.forwarded = w.forwarded.items;
    m.invite = w.invite;
    return m;
}

// ---------------------------------------------------------------- headers

const Header = struct { name: []const u8, value: []const u8 };

const Head = struct {
    headers: []const Header,
    body: []const u8,

    /// The raw (folded) value of the first header called `name`.
    fn first(h: Head, name: []const u8) ?[]const u8 {
        for (h.headers) |hd| {
            if (std.ascii.eqlIgnoreCase(hd.name, name)) return hd.value;
        }
        return null;
    }
};

/// Splits headers from the body at the first empty line. A line that is
/// neither a header nor a continuation starts the body too.
fn splitHead(a: Allocator, raw: []const u8) !Head {
    var list: std.ArrayList(Header) = .empty;
    var value_start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const eol = std.mem.indexOfScalarPos(u8, raw, i, '\n') orelse raw.len;
        const line = std.mem.trimEnd(u8, raw[i..eol], "\r");
        const next = @min(eol + 1, raw.len);
        if (line.len == 0) return .{ .headers = list.items, .body = raw[next..] };
        if (line[0] == ' ' or line[0] == '\t') {
            if (list.items.len > 0) list.items[list.items.len - 1].value = raw[value_start..eol];
            i = next;
            continue;
        }
        if (i == 0 and std.mem.startsWith(u8, line, "From ")) {
            i = next;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .{ .headers = list.items, .body = raw[i..] };
        const name = std.mem.trimEnd(u8, line[0..colon], " \t");
        if (!isHeaderName(name)) return .{ .headers = list.items, .body = raw[i..] };
        value_start = i + colon + 1;
        try list.append(a, .{ .name = name, .value = raw[value_start..eol] });
        i = next;
    }
    return .{ .headers = list.items, .body = "" };
}

fn isHeaderName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c <= ' ' or c >= 0x7F) return false;
    }
    return true;
}

/// A header value on one line: each fold becomes one space; trimmed.
fn unfold(a: Allocator, value: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.indexOfAny(u8, t, "\r\n") == null) return t;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, t.len);
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (c == '\r' or c == '\n') {
            while (i < t.len and (t[i] == '\r' or t[i] == '\n' or t[i] == ' ' or t[i] == '\t')) i += 1;
            const items = out.items;
            if (items.len > 0 and items[items.len - 1] != ' ' and items[items.len - 1] != '\t') out.appendAssumeCapacity(' ');
            continue;
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.items;
}

/// RFC 2047 encoded words decoded into UTF-8, folds unfolded. Whitespace
/// between two encoded words is dropped; malformed words stay as written;
/// raw 8-bit text is read as UTF-8, or Windows-1252 when it isn't valid.
pub fn decodeWords(a: Allocator, value: []const u8) ![]u8 {
    const v = try unfold(a, value);
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, v.len);
    var pend: std.ArrayList(u8) = .empty;
    var pend_cs: []const u8 = "";
    var plain_start: usize = 0;
    var after_word = false;
    var i: usize = 0;
    while (i + 1 < v.len) {
        if (v[i] == '=' and v[i + 1] == '?') {
            if (encodedWordAt(v, i)) |ew| {
                const between = v[plain_start..i];
                const adjacent = after_word and std.mem.trim(u8, between, " \t").len == 0;
                if (!adjacent or !std.ascii.eqlIgnoreCase(pend_cs, ew.charset)) {
                    try flushWords(a, &out, &pend, pend_cs);
                }
                if (!adjacent) try appendRaw(a, &out, between);
                if (ew.b) {
                    try base64Append(a, &pend, ew.text);
                } else {
                    try qDecodeAppend(a, &pend, ew.text);
                }
                pend_cs = ew.charset;
                i = ew.end;
                plain_start = i;
                after_word = true;
                continue;
            }
        }
        i += 1;
    }
    try flushWords(a, &out, &pend, pend_cs);
    try appendRaw(a, &out, v[plain_start..]);
    for (out.items) |*c| {
        if (c.* < ' ' or c.* == 0x7F) c.* = ' ';
    }
    return out.items;
}

const EncodedWord = struct { charset: []const u8, b: bool, text: []const u8, end: usize };

/// The encoded word "=?charset?B|Q?text?=" starting at `v[i]`, if well formed.
fn encodedWordAt(v: []const u8, i: usize) ?EncodedWord {
    const cs_start = i + 2;
    const q1 = std.mem.indexOfScalarPos(u8, v[0..@min(v.len, cs_start + 65)], cs_start, '?') orelse return null;
    if (q1 == cs_start or q1 + 3 > v.len) return null;
    const cs_full = v[cs_start..q1];
    if (std.mem.indexOfAny(u8, cs_full, " \t=") != null) return null;
    const enc = std.ascii.toLower(v[q1 + 1]);
    if ((enc != 'b' and enc != 'q') or v[q1 + 2] != '?') return null;
    const text_start = q1 + 3;
    // Encoded words are short; looking further would make bad input slow.
    const close = std.mem.indexOfPos(u8, v[0..@min(v.len, text_start + 1024)], text_start, "?=") orelse return null;
    const text = v[text_start..close];
    if (std.mem.indexOfAny(u8, text, " \t") != null) return null;
    if (enc == 'b') {
        for (text) |c| {
            if (b64Value(c) == null and c != '=') return null;
        }
    }
    const cs = if (std.mem.indexOfScalar(u8, cs_full, '*')) |star| cs_full[0..star] else cs_full;
    return .{ .charset = cs, .b = enc == 'b', .text = text, .end = close + 2 };
}

fn flushWords(a: Allocator, out: *std.ArrayList(u8), pend: *std.ArrayList(u8), cs: []const u8) !void {
    if (pend.items.len == 0) return;
    try out.appendSlice(a, try charset.toUtf8(a, cs, pend.items));
    pend.clearRetainingCapacity();
}

/// Text outside encoded words: UTF-8 when valid, else Windows-1252.
fn appendRaw(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c >= 0x80) return out.appendSlice(a, try charset.toUtf8(a, "us-ascii", s));
    }
    try out.appendSlice(a, s);
}

fn qDecodeAppend(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') {
            try out.append(a, ' ');
        } else if (c == '=' and hexByte(s[i + 1 ..]) != null) {
            try out.append(a, hexByte(s[i + 1 ..]).?);
            i += 2;
        } else {
            try out.append(a, c);
        }
    }
}

/// The byte written as two hex digits at the start of `s`.
fn hexByte(s: []const u8) ?u8 {
    if (s.len < 2) return null;
    const hi = std.fmt.charToDigit(s[0], 16) catch return null;
    const lo = std.fmt.charToDigit(s[1], 16) catch return null;
    return hi * 16 + lo;
}

// ---------------------------------------------------------------- parameters

const Param = struct { name: []const u8, value: []const u8 };

/// A structured header such as Content-Type: its value lowercased and its
/// parameters as written (quotes removed).
const Field = struct {
    value: []const u8 = "",
    params: []const Param = &.{},

    fn raw(f: Field, name: []const u8) ?[]const u8 {
        for (f.params) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, name)) return p.value;
        }
        return null;
    }

    /// The parameter `name` as UTF-8: RFC 2231 forms (`name*`, `name*0*`,
    /// ...) first, then the plain one with any RFC 2047 words decoded.
    fn get(f: Field, a: Allocator, name: []const u8) !?[]const u8 {
        var key_buf: [80]u8 = undefined;
        if (name.len > 64) return null;
        if (f.raw(std.fmt.bufPrint(&key_buf, "{s}*", .{name}) catch unreachable)) |ext| {
            var bytes: std.ArrayList(u8) = .empty;
            const cs = try extendedAppend(a, &bytes, ext, true);
            return try charset.toUtf8(a, cs, bytes.items);
        }
        var bytes: std.ArrayList(u8) = .empty;
        var cs: []const u8 = "";
        var n: usize = 0;
        while (n < 100) : (n += 1) {
            if (f.raw(std.fmt.bufPrint(&key_buf, "{s}*{d}*", .{ name, n }) catch unreachable)) |seg| {
                const c = try extendedAppend(a, &bytes, seg, n == 0);
                if (n == 0) cs = c;
            } else if (f.raw(std.fmt.bufPrint(&key_buf, "{s}*{d}", .{ name, n }) catch unreachable)) |seg| {
                try bytes.appendSlice(a, seg);
            } else break;
        }
        if (n > 0) return try charset.toUtf8(a, cs, bytes.items);
        if (f.raw(name)) |plain| return try decodeWords(a, plain);
        return null;
    }
};

/// Appends an RFC 2231 extended value (percent-encoded, with a
/// "charset'lang'" prefix on the first part); returns the charset.
fn extendedAppend(a: Allocator, out: *std.ArrayList(u8), v: []const u8, first: bool) ![]const u8 {
    var s = v;
    var cs: []const u8 = "";
    if (first) {
        if (std.mem.indexOfScalar(u8, s, '\'')) |q1| {
            if (std.mem.indexOfScalarPos(u8, s, q1 + 1, '\'')) |q2| {
                cs = s[0..q1];
                s = s[q2 + 1 ..];
            }
        }
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (hexByte(s[i + 1 ..])) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            }
        }
        try out.append(a, s[i]);
    }
    return cs;
}

fn parseField(a: Allocator, raw_value: ?[]const u8) !Field {
    const v = try unfold(a, raw_value orelse return .{});
    const semi = std.mem.indexOfScalar(u8, v, ';') orelse v.len;
    var f: Field = .{ .value = try std.ascii.allocLowerString(a, std.mem.trim(u8, v[0..semi], " \t\"")) };
    var params: std.ArrayList(Param) = .empty;
    var i = semi;
    while (i < v.len) {
        while (i < v.len and (v[i] == ';' or v[i] == ' ' or v[i] == '\t')) i += 1;
        const ns = i;
        while (i < v.len and v[i] != '=' and v[i] != ';') i += 1;
        const name = std.mem.trim(u8, v[ns..i], " \t");
        if (i >= v.len or v[i] == ';') continue;
        i += 1;
        while (i < v.len and (v[i] == ' ' or v[i] == '\t')) i += 1;
        var value: []const u8 = "";
        if (i < v.len and v[i] == '"') {
            i += 1;
            var buf: std.ArrayList(u8) = .empty;
            while (i < v.len and v[i] != '"') : (i += 1) {
                if (v[i] == '\\' and i + 1 < v.len) i += 1;
                try buf.append(a, v[i]);
            }
            i += 1;
            value = buf.items;
        } else {
            const vs = i;
            while (i < v.len and v[i] != ';') i += 1;
            value = std.mem.trim(u8, v[vs..i], " \t");
        }
        if (name.len > 0) try params.append(a, .{ .name = name, .value = value });
    }
    f.params = params.items;
    return f;
}

// ---------------------------------------------------------------- bodies

fn b64Value(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

/// Base64 decoded onto `out`, skipping whitespace and other characters;
/// "=" ends a group early.
fn base64Append(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.ensureUnusedCapacity(a, s.len / 4 * 3 + 3);
    var acc: u32 = 0;
    var n: u8 = 0;
    for (s) |c| {
        if (c == '=') {
            flushB64(out, acc, n);
            acc = 0;
            n = 0;
            continue;
        }
        const v = b64Value(c) orelse continue;
        acc = acc << 6 | v;
        n += 1;
        if (n == 4) {
            out.appendSliceAssumeCapacity(&.{ @truncate(acc >> 16), @truncate(acc >> 8), @truncate(acc) });
            acc = 0;
            n = 0;
        }
    }
    flushB64(out, acc, n);
}

fn flushB64(out: *std.ArrayList(u8), acc: u32, n: u8) void {
    switch (n) {
        2 => out.appendAssumeCapacity(@truncate(acc >> 4)),
        3 => out.appendSliceAssumeCapacity(&.{ @truncate(acc >> 10), @truncate(acc >> 2) }),
        else => {},
    }
}

/// How many bytes `s` decodes to as base64.
fn base64Size(s: []const u8) usize {
    var total: usize = 0;
    var n: usize = 0;
    for (s) |c| {
        if (c == '=') {
            total += partialB64(n);
            n = 0;
        } else if (b64Value(c) != null) {
            n += 1;
            if (n == 4) {
                total += 3;
                n = 0;
            }
        }
    }
    return total + partialB64(n);
}

fn partialB64(n: usize) usize {
    return switch (n) {
        2 => 1,
        3 => 2,
        else => 0,
    };
}

/// Quoted-printable decoded: "=XX" bytes, soft line breaks dropped, other
/// "=" left as written.
fn qpDecode(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c != '=') {
            const end = std.mem.indexOfScalarPos(u8, s, i, '=') orelse s.len;
            out.appendSliceAssumeCapacity(s[i..end]);
            i = end;
            continue;
        }
        var j = i + 1;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
        if (j >= s.len) break;
        if (s[j] == '\n') {
            i = j + 1;
            continue;
        }
        if (s[j] == '\r') {
            i = if (j + 1 < s.len and s[j + 1] == '\n') j + 2 else j + 1;
            continue;
        }
        if (hexByte(s[i + 1 ..])) |b| {
            out.appendAssumeCapacity(b);
            i += 3;
            continue;
        }
        out.appendAssumeCapacity('=');
        i += 1;
    }
    return out.items;
}

/// The body with its Content-Transfer-Encoding undone.
fn decodeBody(a: Allocator, cte: []const u8, body: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(cte, "base64")) {
        var out: std.ArrayList(u8) = .empty;
        try base64Append(a, &out, body);
        return out.items;
    }
    if (std.ascii.eqlIgnoreCase(cte, "quoted-printable")) return qpDecode(a, body);
    return body;
}

/// Text with "\n" line ends, trailing whitespace off each line, at most one
/// blank line in a row, trimmed at the ends.
fn tidyText(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var blank = false;
    var i: usize = 0;
    while (i <= s.len) {
        const eol = std.mem.indexOfAnyPos(u8, s, i, "\r\n") orelse s.len;
        const line = std.mem.trimEnd(u8, s[i..eol], " \t");
        if (eol < s.len and s[eol] == '\r' and eol + 1 < s.len and s[eol + 1] == '\n') i = eol + 2 else i = eol + 1;
        if (line.len == 0) {
            blank = out.items.len > 0;
            continue;
        }
        if (out.items.len > 0) out.appendSliceAssumeCapacity(if (blank) "\n\n" else "\n");
        blank = false;
        for (line) |c| {
            if (c != 0) out.appendAssumeCapacity(c);
        }
    }
    const t = std.mem.trim(u8, out.items, " \t\n");
    std.mem.copyForwards(u8, out.items[0..t.len], t);
    return out.items[0..t.len];
}

/// format=flowed text (RFC 3676) with its soft line breaks joined.
fn unflow(a: Allocator, s: []const u8, delsp: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var it = std.mem.splitScalar(u8, s, '\n');
    var joining = false;
    var depth: usize = 0;
    while (it.next()) |raw_line| {
        var line = std.mem.trimEnd(u8, raw_line, "\r");
        var d: usize = 0;
        while (d < line.len and line[d] == '>') d += 1;
        if (joining and d == depth) {
            line = line[d..];
            if (line.len > 0 and line[0] == ' ') line = line[1..];
        } else if (joining) {
            out.appendAssumeCapacity('\n');
        }
        depth = d;
        const soft = line.len > 0 and line[line.len - 1] == ' ' and !std.mem.eql(u8, std.mem.trimStart(u8, line[@min(d, line.len)..], " "), "-- ");
        if (soft) {
            out.appendSliceAssumeCapacity(if (delsp) line[0 .. line.len - 1] else line);
            joining = true;
        } else {
            out.appendSliceAssumeCapacity(line);
            if (it.peek() != null) out.appendAssumeCapacity('\n');
            joining = false;
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- parts

const Mode = enum { all, attachments_only };

const Walker = struct {
    a: Allocator,
    depth: u8,
    texts: std.ArrayList([]const u8) = .empty,
    plain_parts: usize = 0,
    html_parts: usize = 0,
    attachments: std.ArrayList(Attachment) = .empty,
    forwarded: std.ArrayList(Forwarded) = .empty,
    invite: ?Invite = null,

    fn walk(w: *Walker, head: Head, nest: u32, mode: Mode) Allocator.Error!void {
        const a = w.a;
        const ct = try parseField(a, head.first("content-type"));
        const ctype = if (std.mem.indexOfScalar(u8, ct.value, '/') == null) "text/plain" else ct.value;
        const cte = std.mem.trim(u8, try unfold(a, head.first("content-transfer-encoding") orelse ""), " \t\"");

        if (std.mem.startsWith(u8, ctype, "multipart/")) {
            const boundary = ct.raw("boundary") orelse "";
            const parts = if (boundary.len > 0 and nest < max_nest) try splitParts(a, head.body, boundary) else &.{};
            if (parts.len == 0) {
                if (mode == .all and nest < max_nest) try w.addText(.plain, try decodeBody(a, cte, head.body), "", false, false);
                return;
            }
            if (std.mem.eql(u8, ctype, "multipart/alternative")) return w.alternative(parts, nest, mode);
            for (parts) |p| try w.walk(try splitHead(a, p), nest + 1, mode);
            return;
        }

        if (std.mem.eql(u8, ctype, "message/rfc822") or std.mem.eql(u8, ctype, "message/global")) {
            if (w.depth >= max_forward_depth) return;
            const inner = try parseDepth(a, try decodeBody(a, cte, head.body), w.depth + 1);
            try w.forwarded.append(a, .{ .from = inner.from, .subject = inner.subject, .date = inner.date, .text = inner.text });
            return;
        }

        const disp = try parseField(a, head.first("content-disposition"));
        const name = (try disp.get(a, "filename")) orelse (try ct.get(a, "name")) orelse "";
        const cs = ct.raw("charset") orelse "";
        const is_ics = std.mem.eql(u8, ctype, "text/calendar") or std.mem.eql(u8, ctype, "application/ics") or
            std.ascii.endsWithIgnoreCase(name, ".ics");
        if (is_ics and w.invite == null) {
            if (try parseCalendar(a, try charset.toUtf8(a, cs, try decodeBody(a, cte, head.body)))) |inv| {
                var i = inv;
                if (i.method.len == 0) i.method = try a.dupe(u8, ct.raw("method") orelse "");
                w.invite = i;
            }
        }
        const attached = std.mem.eql(u8, disp.value, "attachment") or name.len > 0 or !std.mem.startsWith(u8, ctype, "text/");
        if (attached) {
            // Base64 is only counted: attachments can be large.
            const size = if (std.ascii.eqlIgnoreCase(cte, "base64")) base64Size(head.body) else (try decodeBody(a, cte, head.body)).len;
            try w.attachments.append(a, .{ .name = name, .type = ctype, .size = size });
            return;
        }
        if (mode != .all or std.mem.eql(u8, ctype, "text/calendar")) return;
        const body = try decodeBody(a, cte, head.body);
        const flowed = if (ct.raw("format")) |f| std.ascii.eqlIgnoreCase(f, "flowed") else false;
        const delsp = if (ct.raw("delsp")) |d| std.ascii.eqlIgnoreCase(d, "yes") else false;
        try w.addText(if (std.mem.eql(u8, ctype, "text/html")) .html else .plain, body, cs, flowed, delsp);
    }

    /// multipart/alternative: the plain text when it has any, else the
    /// last HTML or multipart version. The others are only searched for
    /// attachments and invitations.
    fn alternative(w: *Walker, parts: []const []const u8, nest: u32, mode: Mode) !void {
        const a = w.a;
        const heads = try a.alloc(Head, parts.len);
        for (parts, heads) |p, *h| h.* = try splitHead(a, p);
        var chosen: ?usize = null;
        if (mode == .all) {
            for (heads, 0..) |h, i| {
                const ct = try parseField(a, h.first("content-type"));
                const ctype = if (std.mem.indexOfScalar(u8, ct.value, '/') == null) "text/plain" else ct.value;
                if (!std.mem.eql(u8, ctype, "text/plain")) continue;
                const disp = try parseField(a, h.first("content-disposition"));
                if (std.mem.eql(u8, disp.value, "attachment")) continue;
                const cte = std.mem.trim(u8, try unfold(a, h.first("content-transfer-encoding") orelse ""), " \t\"");
                const body = try decodeBody(a, cte, h.body);
                if (std.mem.trim(u8, body, " \t\r\n").len > 0) {
                    chosen = i;
                    break;
                }
            }
            if (chosen == null) {
                var i = heads.len;
                while (i > 0) {
                    i -= 1;
                    const ct = try parseField(a, heads[i].first("content-type"));
                    if (std.mem.eql(u8, ct.value, "text/html") or std.mem.startsWith(u8, ct.value, "multipart/")) {
                        chosen = i;
                        break;
                    }
                }
            }
        }
        for (heads, 0..) |h, i| {
            const m: Mode = if (chosen == null) mode else if (chosen.? == i) .all else .attachments_only;
            try w.walk(h, nest + 1, m);
        }
    }

    fn addText(w: *Walker, kind: enum { plain, html }, body: []const u8, cs: []const u8, flowed: bool, delsp: bool) !void {
        const a = w.a;
        var text: []const u8 = try charset.toUtf8(a, cs, body);
        switch (kind) {
            .plain => if (flowed) {
                text = try unflow(a, text, delsp);
            },
            .html => text = try html.toText(a, text),
        }
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        try w.texts.append(a, text);
        switch (kind) {
            .plain => w.plain_parts += 1,
            .html => w.html_parts += 1,
        }
    }
};

/// The parts of a multipart body between "--boundary" lines; a missing
/// closing "--boundary--" ends the last part at the end of the body.
fn splitParts(a: Allocator, body: []const u8, boundary: []const u8) ![]const []const u8 {
    const dash = try std.fmt.allocPrint(a, "--{s}", .{boundary});
    var parts: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, dash)) |at| {
        pos = at + 1;
        if (at != 0 and body[at - 1] != '\n') continue;
        var e = at + dash.len;
        const closing = std.mem.startsWith(u8, body[e..], "--");
        if (closing) e += 2;
        const eol = std.mem.indexOfScalarPos(u8, body, e, '\n') orelse body.len;
        if (std.mem.trim(u8, body[e..eol], " \t\r").len != 0) continue;
        if (start) |s| {
            var end = at;
            if (end > s and body[end - 1] == '\n') end -= 1;
            if (end > s and body[end - 1] == '\r') end -= 1;
            try parts.append(a, body[s..@max(s, end)]);
        }
        if (closing) return parts.items;
        start = @min(eol + 1, body.len);
        pos = start.?;
    }
    if (start) |s| try parts.append(a, body[s..]);
    return parts.items;
}

// ---------------------------------------------------------------- calendar

/// The first VEVENT of an iCalendar object, or null when there is none.
fn parseCalendar(a: Allocator, text: []const u8) !?Invite {
    var un: std.ArrayList(u8) = .empty;
    try un.ensureTotalCapacity(a, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r' and i + 2 < text.len and text[i + 1] == '\n' and (text[i + 2] == ' ' or text[i + 2] == '\t')) {
            i += 3;
        } else if (text[i] == '\n' and i + 1 < text.len and (text[i + 1] == ' ' or text[i + 1] == '\t')) {
            i += 2;
        } else {
            un.appendAssumeCapacity(text[i]);
            i += 1;
        }
    }
    var inv: Invite = .{};
    var in_event = false;
    var found = false;
    var nested: usize = 0;
    var it = std.mem.splitScalar(u8, un.items, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const colon = propertyColon(line) orelse continue;
        const semi = std.mem.indexOfScalar(u8, line[0..colon], ';') orelse colon;
        const name = line[0..semi];
        const value = line[colon + 1 ..];
        if (std.ascii.eqlIgnoreCase(name, "BEGIN")) {
            if (in_event) {
                nested += 1;
            } else if (!found and std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " "), "VEVENT")) {
                in_event = true;
                found = true;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "END")) {
            if (in_event) {
                if (nested > 0) nested -= 1 else in_event = false;
            }
        } else if (!in_event) {
            if (std.ascii.eqlIgnoreCase(name, "METHOD") and inv.method.len == 0) inv.method = try a.dupe(u8, std.mem.trim(u8, value, " "));
        } else if (nested == 0) {
            if (std.ascii.eqlIgnoreCase(name, "SUMMARY")) {
                inv.summary = try icsText(a, value);
            } else if (std.ascii.eqlIgnoreCase(name, "LOCATION")) {
                inv.location = try icsText(a, value);
            } else if (std.ascii.eqlIgnoreCase(name, "DTSTART")) {
                inv.start = try icsTime(a, value);
            } else if (std.ascii.eqlIgnoreCase(name, "DTEND")) {
                inv.end = try icsTime(a, value);
            } else if (std.ascii.eqlIgnoreCase(name, "ORGANIZER")) {
                const v = std.mem.trim(u8, value, " ");
                const addr = if (std.ascii.startsWithIgnoreCase(v, "mailto:")) v[7..] else v;
                inv.organizer = try std.ascii.allocLowerString(a, addr);
            }
        }
    }
    return if (found) inv else null;
}

/// Where the value of a content line starts (its ":" outside quoted
/// parameter values).
fn propertyColon(line: []const u8) ?usize {
    var quoted = false;
    for (line, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if (c == ':' and !quoted) return i;
    }
    return null;
}

/// An iCalendar TEXT value unescaped, on one line.
fn icsText(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, v.len);
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] == '\\' and i + 1 < v.len) {
            i += 1;
            out.appendAssumeCapacity(switch (v[i]) {
                'n', 'N' => ' ',
                else => v[i],
            });
        } else {
            out.appendAssumeCapacity(v[i]);
        }
    }
    return std.mem.trim(u8, out.items, " ");
}

/// "20261201T093000[Z]" as "2026-12-01 09:30[ UTC]", "20261201" as
/// "2026-12-01"; anything else as written.
fn icsTime(a: Allocator, value: []const u8) ![]const u8 {
    const v = std.mem.trim(u8, value, " ");
    const digits = struct {
        fn all(s: []const u8) bool {
            for (s) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
    }.all;
    if (v.len >= 8 and digits(v[0..8])) {
        if (v.len == 8) return std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ v[0..4], v[4..6], v[6..8] });
        if (v.len >= 13 and v[8] == 'T' and digits(v[9..13])) {
            const utc = v[v.len - 1] == 'Z' or v[v.len - 1] == 'z';
            return std.fmt.allocPrint(a, "{s}-{s}-{s} {s}:{s}{s}", .{ v[0..4], v[4..6], v[6..8], v[9..11], v[11..13], if (utc) " UTC" else "" });
        }
    }
    return a.dupe(u8, v);
}

// ---------------------------------------------------------------- addresses

/// Walks an address header byte by byte, keeping track of quoted
/// strings, comments and angle brackets.
const Scan = struct {
    quoted: bool = false,
    comment: usize = 0,
    angle: bool = false,
    escaped: bool = false,

    /// Whether `c` is outside quotes, comments and angle brackets.
    fn top(s: *Scan, c: u8) bool {
        if (s.escaped) {
            s.escaped = false;
            return false;
        }
        if (c == '\\' and (s.quoted or s.comment > 0)) {
            s.escaped = true;
            return false;
        }
        if (s.quoted) {
            if (c == '"') s.quoted = false;
            return false;
        }
        if (s.comment > 0) {
            if (c == '(') s.comment += 1;
            if (c == ')') s.comment -= 1;
            return false;
        }
        if (s.angle) {
            if (c == '>') s.angle = false;
            return false;
        }
        switch (c) {
            '"' => s.quoted = true,
            '(' => s.comment = 1,
            '<' => s.angle = true,
            else => return true,
        }
        return false;
    }
};

/// The addr-spec in `Name <a@b>`, `a@b`, `"Doe, J" <a@b>` or
/// `a@b (Name)`, as written.
pub fn addrOf(value: []const u8) []const u8 {
    var s: Scan = .{};
    for (value, 0..) |c, i| {
        if (c == '<' and !s.quoted and s.comment == 0 and !s.escaped) {
            const end = std.mem.indexOfScalarPos(u8, value, i + 1, '>') orelse value.len;
            return std.mem.trim(u8, value[i + 1 .. end], " \t\r\n");
        }
        _ = s.top(c);
    }
    // No angle brackets: the first word outside quotes and comments that
    // has an "@", else the first word.
    var first_word: []const u8 = "";
    s = .{};
    var start: ?usize = null;
    for (value, 0..) |c, i| {
        const top = s.top(c) and !(c == ' ' or c == '\t' or c == '\r' or c == '\n');
        if (top and start == null) start = i;
        if (!top and start != null) {
            const word = value[start.?..i];
            if (std.mem.indexOfScalar(u8, word, '@') != null) return word;
            if (first_word.len == 0) first_word = word;
            start = null;
        }
    }
    if (start) |st| {
        const word = value[st..];
        if (std.mem.indexOfScalar(u8, word, '@') != null or first_word.len == 0) return word;
    }
    return first_word;
}

/// Every addr-spec of an address-list header, lowercased. Group names
/// ("Team: a@b, c@d;") are skipped.
pub fn addrList(a: Allocator, value: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var s: Scan = .{};
    var start: usize = 0;
    for (value, 0..) |c, i| {
        if (!s.top(c)) continue;
        switch (c) {
            ':' => start = i + 1,
            ',', ';' => {
                try addAddr(a, &out, value[start..i]);
                start = i + 1;
            },
            else => {},
        }
    }
    try addAddr(a, &out, value[@min(start, value.len)..]);
    return out.items;
}

fn addAddr(a: Allocator, out: *std.ArrayList([]const u8), item: []const u8) !void {
    const addr = addrOf(item);
    if (std.mem.indexOfScalar(u8, addr, '@') == null) return;
    try out.append(a, try std.ascii.allocLowerString(a, addr));
}

/// The first address of a list (up to a top-level comma).
fn firstItem(value: []const u8) []const u8 {
    var s: Scan = .{};
    for (value, 0..) |c, i| {
        if (s.top(c) and c == ',') return value[0..i];
    }
    return value;
}

/// The display name of one address, unquoted and decoded; "" if none.
fn displayName(a: Allocator, item: []const u8) ![]const u8 {
    var s: Scan = .{};
    var lt: ?usize = null;
    for (item, 0..) |c, i| {
        if (c == '<' and !s.quoted and s.comment == 0 and !s.escaped) {
            lt = i;
            break;
        }
        _ = s.top(c);
    }
    var phrase: []const u8 = "";
    if (lt) |l| {
        phrase = item[0..l];
    } else if (std.mem.indexOfScalar(u8, item, '(')) |open| {
        const close = std.mem.lastIndexOfScalar(u8, item, ')') orelse item.len;
        if (close > open) phrase = item[open + 1 .. close];
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < phrase.len) : (i += 1) {
        const c = phrase[i];
        if (c == '"') continue;
        if (c == '\\' and i + 1 < phrase.len) i += 1;
        try out.append(a, phrase[i]);
    }
    return std.mem.trim(u8, try decodeWords(a, out.items), " \t");
}

/// The first "<...>" id in `v`, else `v`.
fn firstId(v: []const u8) []const u8 {
    const lt = std.mem.indexOfScalar(u8, v, '<') orelse return v;
    const gt = std.mem.indexOfScalarPos(u8, v, lt, '>') orelse return v[lt..];
    return v[lt .. gt + 1];
}

/// The "<...>" ids in `v` separated by single spaces.
fn joinIds(a: Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, v, pos, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, v, lt, '>') orelse break;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, v[lt .. gt + 1]);
        pos = gt + 1;
    }
    if (out.items.len > 0) return out.items;
    var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
    while (it.next()) |t| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, t);
    }
    return out.items;
}

// ---------------------------------------------------------------- authentication

/// Reads the receiving server's Authentication-Results: a DMARC pass, or a
/// DKIM pass signed by the From domain or a parent of it, is a pass.
fn authResult(a: Allocator, raw_value: []const u8, from_domain: []const u8) !Auth {
    const v = try unfold(a, raw_value);
    // Comments out, so text inside them can't pose as a result.
    var clean: std.ArrayList(u8) = .empty;
    var s: Scan = .{};
    for (v) |c| {
        const in_comment = s.comment > 0 or c == '(';
        _ = s.top(c);
        try clean.append(a, if (in_comment or c == ')') ' ' else c);
    }
    var segs = std.mem.splitScalar(u8, clean.items, ';');
    while (segs.next()) |seg| {
        var toks = std.mem.tokenizeAny(u8, seg, " \t");
        var method: []const u8 = "";
        var result: []const u8 = "";
        while (toks.next()) |t| {
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const key = t[0..eq];
            const val = std.mem.trim(u8, t[eq + 1 ..], "\"");
            if (method.len == 0) {
                if (std.mem.indexOfScalar(u8, key, '.') != null) continue;
                method = key;
                result = val;
                if (std.ascii.eqlIgnoreCase(method, "dmarc") and std.ascii.eqlIgnoreCase(result, "pass")) return .pass;
                continue;
            }
            if (!std.ascii.eqlIgnoreCase(method, "dkim") or !std.ascii.eqlIgnoreCase(result, "pass")) break;
            var d: []const u8 = "";
            if (std.ascii.eqlIgnoreCase(key, "header.d")) d = val;
            if (std.ascii.eqlIgnoreCase(key, "header.i")) d = if (std.mem.lastIndexOfScalar(u8, val, '@')) |at| val[at + 1 ..] else "";
            if (covers(d, from_domain)) return .pass;
        }
    }
    return .fail;
}

/// Whether signing domain `d` is `domain` or a parent of it.
fn covers(d: []const u8, domain: []const u8) bool {
    if (d.len == 0 or domain.len == 0 or std.mem.indexOfScalar(u8, d, '.') == null) return false;
    if (std.ascii.eqlIgnoreCase(d, domain)) return true;
    return domain.len > d.len and std.ascii.endsWithIgnoreCase(domain, d) and domain[domain.len - d.len - 1] == '.';
}

// ---------------------------------------------------------------- dates

/// Days from 1970-01-01 to the given civil date.
pub fn daysFromCivil(y: i64, m: u32, d: u32) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: u32, d: u32 };

/// The civil date `days` after 1970-01-01.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = era * 400 + yoe + @intFromBool(m <= 2), .m = m, .d = d };
}

pub fn daysInMonth(y: i64, m: u32) u32 {
    return switch (m) {
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

/// An RFC 5322 date ("Tue, 1 Dec 2026 09:30:00 +0100 (CET)") as seconds
/// since 1970 UTC; null when it can't be read.
pub fn parseDate(value: []const u8) ?i64 {
    const v = value[0 .. std.mem.indexOfScalar(u8, value, '(') orelse value.len];
    var toks: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, v, " \t\r\n,");
    while (it.next()) |t| {
        if (n == toks.len) break;
        toks[n] = t;
        n += 1;
    }
    var k: usize = 0;
    if (k < n and std.ascii.isAlphabetic(toks[k][0])) k += 1;
    if (n < k + 3) return null;
    const day = std.fmt.parseInt(u32, toks[k], 10) catch return null;
    const mon_tok = toks[k + 1];
    if (mon_tok.len < 3) return null;
    var month: u32 = 0;
    for (month_names, 1..) |name, i| {
        if (std.ascii.eqlIgnoreCase(mon_tok[0..3], name)) month = @intCast(i);
    }
    if (month == 0) return null;
    const ytok = toks[k + 2];
    var year = std.fmt.parseInt(i64, ytok, 10) catch return null;
    if (ytok.len == 2) year += if (year < 50) 2000 else 1900;
    if (ytok.len == 3) year += 1900;
    if (day < 1 or day > daysInMonth(year, month)) return null;

    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var zone_tok: []const u8 = "";
    if (n > k + 3) {
        var parts = std.mem.splitScalar(u8, toks[k + 3], ':');
        h = std.fmt.parseInt(i64, parts.next().?, 10) catch return null;
        mi = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
        if (parts.next()) |s| sec = std.fmt.parseInt(i64, s, 10) catch return null;
        if (h < 0 or h > 23 or mi < 0 or mi > 59 or sec < 0 or sec > 60) return null;
        if (sec == 60) sec = 59;
        if (n > k + 4) zone_tok = toks[k + 4];
    }
    const secs = daysFromCivil(year, month, day) * 86400 + h * 3600 + mi * 60 + sec;
    return secs - @as(i64, zoneMinutes(zone_tok)) * 60;
}

/// A zone ("+0100", "-05:00", "GMT", "EST", ...) as minutes east of UTC;
/// unknown zones count as UTC.
fn zoneMinutes(z: []const u8) i32 {
    if (z.len >= 5 and (z[0] == '+' or z[0] == '-')) {
        var digits: [4]u8 = undefined;
        var n: usize = 0;
        for (z[1..]) |c| {
            if (c == ':') continue;
            if (!std.ascii.isDigit(c) or n == 4) break;
            digits[n] = c;
            n += 1;
        }
        if (n != 4) return 0;
        const hh: i32 = (digits[0] - '0') * 10 + (digits[1] - '0');
        const mm: i32 = (digits[2] - '0') * 10 + (digits[3] - '0');
        const m = hh * 60 + mm;
        return if (z[0] == '-') -m else m;
    }
    const zones = [_]struct { []const u8, i32 }{
        .{ "EST", -300 }, .{ "EDT", -240 }, .{ "CST", -360 }, .{ "CDT", -300 },
        .{ "MST", -420 }, .{ "MDT", -360 }, .{ "PST", -480 }, .{ "PDT", -420 },
        .{ "CET", 60 },   .{ "CEST", 120 },
    };
    for (zones) |zn| {
        if (std.ascii.eqlIgnoreCase(z, zn[0])) return zn[1];
    }
    return 0;
}

// ---------------------------------------------------------------- composing

/// A plain-text message to write.
pub const Outgoing = struct {
    /// Addr-spec.
    from: []const u8,
    from_name: []const u8 = "",
    /// Addr-specs.
    to: []const []const u8,
    cc: []const []const u8 = &.{},
    subject: []const u8,
    /// UTF-8, "\n" or "\r\n" line ends.
    text: []const u8,
    /// "<id>" or "".
    in_reply_to: []const u8 = "",
    /// "<a> <b>" or "".
    references: []const u8 = "",
    /// "<...>", made by the caller.
    message_id: []const u8,
    /// Seconds since 1970 UTC.
    date_s: i64,
    /// The Date header's zone.
    utc_offset_min: i32 = 0,
    /// Changes nothing in the bytes for now.
    draft: bool = false,
};

/// Writes a plain-text message with "\r\n" line ends and a quoted-printable
/// UTF-8 body. error.BadHeader when a header field holds a line break,
/// error.BadAddress when an address isn't a bare addr-spec.
pub fn compose(a: Allocator, o: Outgoing) ![]u8 {
    for ([_][]const u8{ o.from, o.from_name, o.subject, o.in_reply_to, o.references, o.message_id }) |f| try noBreak(f);
    for (o.to) |f| try noBreak(f);
    for (o.cc) |f| try noBreak(f);
    try checkAddr(o.from);
    for (o.to) |f| try checkAddr(f);
    for (o.cc) |f| try checkAddr(f);

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, o.text.len * 3 / 2 + 1024);
    try writeDate(a, &out, o.date_s, o.utc_offset_min);

    var h: HeaderWriter = .{ .a = a, .out = &out };
    try h.start("From:");
    if (o.from_name.len == 0) {
        try h.word(o.from);
    } else {
        if (!isPlainAscii(o.from_name)) {
            try h.encoded(o.from_name);
        } else if (std.mem.indexOfAny(u8, o.from_name, "()<>[]:;@\\,.\"") != null) {
            var q: std.ArrayList(u8) = .empty;
            try q.append(a, '"');
            for (o.from_name) |c| {
                if (c == '"' or c == '\\') try q.append(a, '\\');
                try q.append(a, c);
            }
            try q.append(a, '"');
            try h.word(q.items);
        } else {
            try h.words(o.from_name);
        }
        try h.word(try std.fmt.allocPrint(a, "<{s}>", .{o.from}));
    }
    try h.end();
    for ([_]struct { []const u8, []const []const u8 }{ .{ "To:", o.to }, .{ "Cc:", o.cc } }) |hl| {
        if (hl[1].len == 0) continue;
        try h.start(hl[0]);
        for (hl[1], 0..) |addr, i| {
            try h.word(if (i + 1 < hl[1].len) try std.fmt.allocPrint(a, "{s},", .{addr}) else addr);
        }
        try h.end();
    }
    try h.start("Subject:");
    if (isPlainAscii(o.subject) and std.mem.indexOf(u8, o.subject, "=?") == null) {
        try h.words(o.subject);
    } else {
        try h.encoded(o.subject);
    }
    try h.end();
    try h.start("Message-ID:");
    try h.word(o.message_id);
    try h.end();
    if (o.in_reply_to.len > 0) {
        try h.start("In-Reply-To:");
        try h.word(o.in_reply_to);
        try h.end();
    }
    if (o.references.len > 0) {
        try h.start("References:");
        var it = std.mem.tokenizeAny(u8, o.references, " \t");
        while (it.next()) |id| try h.word(id);
        try h.end();
    }
    try out.appendSlice(a, "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n" ++
        "Content-Transfer-Encoding: quoted-printable\r\n\r\n");
    try writeQp(a, &out, o.text);
    return out.items;
}

fn noBreak(s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return error.BadHeader;
}

fn checkAddr(s: []const u8) !void {
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return error.BadAddress;
    if (at == 0 or at + 1 == s.len) return error.BadAddress;
    for (s) |c| {
        if (c <= ' ' or c == 0x7F or c == '<' or c == '>' or c == ',' or c == '"') return error.BadAddress;
    }
}

fn isPlainAscii(s: []const u8) bool {
    for (s) |c| {
        if (c < ' ' or c > '~') return false;
    }
    return true;
}

const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const month_caps = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "Date: Mon, 23 Nov 2026 19:30:00 +0100\r\n".
fn writeDate(a: Allocator, out: *std.ArrayList(u8), secs: i64, offset_min: i32) !void {
    const local = secs + @as(i64, offset_min) * 60;
    const days = @divFloor(local, 86400);
    const rem: u64 = @intCast(local - days * 86400);
    const c = civilFromDays(days);
    const off: u32 = @abs(offset_min);
    try out.print(a, "Date: {s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>2}{d:0>2}\r\n", .{
        day_names[@intCast(@mod(days, 7))], c.d,           month_caps[c.m - 1], c.y,
        rem / 3600,                         rem / 60 % 60, rem % 60,            @as(u8, if (offset_min < 0) '-' else '+'),
        off / 60,                           off % 60,
    });
}

/// Writes header fields folded to stay within 78 columns.
const HeaderWriter = struct {
    a: Allocator,
    out: *std.ArrayList(u8),
    col: usize = 0,
    fresh: bool = true,

    fn start(h: *HeaderWriter, name: []const u8) !void {
        try h.out.appendSlice(h.a, name);
        h.col = name.len;
        h.fresh = true;
    }

    fn end(h: *HeaderWriter) !void {
        try h.out.appendSlice(h.a, "\r\n");
    }

    /// One word after a space, on a new line when it wouldn't fit.
    fn word(h: *HeaderWriter, w: []const u8) !void {
        if (!h.fresh and h.col + 1 + w.len > 78) {
            try h.out.appendSlice(h.a, "\r\n");
            h.col = 0;
        }
        try h.out.append(h.a, ' ');
        try h.out.appendSlice(h.a, w);
        h.col += 1 + w.len;
        h.fresh = false;
    }

    fn words(h: *HeaderWriter, s: []const u8) !void {
        var it = std.mem.splitScalar(u8, s, ' ');
        while (it.next()) |w| try h.word(w);
    }

    /// `s` as RFC 2047 B words of UTF-8, each at most 75 bytes and split
    /// between characters.
    fn encoded(h: *HeaderWriter, s: []const u8) !void {
        var rest = s;
        while (rest.len > 0) {
            if (h.col + 1 + 12 + 8 > 78) {
                try h.out.appendSlice(h.a, "\r\n");
                h.col = 0;
            }
            const room = @min(75, 78 - h.col - 1) - 12;
            var n = @min(rest.len, room / 4 * 3);
            while (n > 0 and n < rest.len and rest[n] & 0xC0 == 0x80) n -= 1;
            if (n == 0) n = @min(rest.len, std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
            const enc = std.base64.standard.Encoder;
            const buf = try h.a.alloc(u8, enc.calcSize(n));
            const w = try std.fmt.allocPrint(h.a, "=?UTF-8?B?{s}?=", .{enc.encode(buf, rest[0..n])});
            try h.out.append(h.a, ' ');
            try h.out.appendSlice(h.a, w);
            h.col += 1 + w.len;
            h.fresh = false;
            rest = rest[n..];
        }
    }
};

/// The body as quoted-printable: lines of at most 76 characters, "\r\n"
/// line ends, a "." at a line start written "=2E".
fn writeQp(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        if (it.peek() == null and raw_line.len == 0) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        var col: usize = 0;
        for (line, 0..) |c, i| {
            const last = i + 1 == line.len;
            var tok: [3]u8 = undefined;
            var len: usize = 0;
            for (0..2) |_| {
                const literal = (c > ' ' and c <= '~' and c != '=' and !(c == '.' and col == 0)) or
                    ((c == ' ' or c == '\t') and !last);
                if (literal) {
                    tok[0] = c;
                    len = 1;
                } else {
                    tok = .{ '=', hex[c >> 4], hex[c & 15] };
                    len = 3;
                }
                if (col + len <= (if (last) @as(usize, 76) else 75)) break;
                try out.appendSlice(a, "=\r\n");
                col = 0;
            }
            try out.appendSlice(a, tok[0..len]);
            col += len;
        }
        try out.appendSlice(a, "\r\n");
    }
}

// ---------------------------------------------------------------- quotes

pub const Split = struct { own: []const u8, rest: []const u8 };

/// Splits a body into what the writer wrote and what follows from the
/// first line that starts a quote or a forwarded message.
pub fn splitQuoted(text: []const u8) Split {
    var starts: [5]usize = undefined; // line starts: current and next 4
    var lines: [5][]const u8 = undefined;
    var count: usize = 0;
    var pos: usize = 0;
    // Fill a window of lines; slide it one line at a time.
    while (count < lines.len and pos <= text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        starts[count] = pos;
        lines[count] = std.mem.trim(u8, text[pos..eol], " \t\r");
        count += 1;
        pos = eol + 1;
    }
    var prev_start: ?usize = null;
    var prev_line: []const u8 = "";
    while (count > 0) {
        if (quoteStart(lines[0..count])) {
            var at = starts[0];
            if (prev_start) |ps| {
                if (isRule(prev_line)) at = ps;
            }
            return .{ .own = std.mem.trim(u8, text[0..at], " \t\r\n"), .rest = text[at..] };
        }
        if (lines[0].len > 0) {
            prev_start = starts[0];
            prev_line = lines[0];
        }
        std.mem.copyForwards(usize, starts[0 .. count - 1], starts[1..count]);
        std.mem.copyForwards([]const u8, lines[0 .. count - 1], lines[1..count]);
        count -= 1;
        if (pos <= text.len) {
            const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
            starts[count] = pos;
            lines[count] = std.mem.trim(u8, text[pos..eol], " \t\r");
            count += 1;
            pos = eol + 1;
        }
    }
    return .{ .own = std.mem.trim(u8, text, " \t\r\n"), .rest = "" };
}

/// A line of only "_" or "-" (Outlook puts one above its header block).
fn isRule(line: []const u8) bool {
    if (line.len < 8) return false;
    for (line) |c| {
        if (c != '_' and c != '-') return false;
    }
    return true;
}

/// Whether `l[0]` starts quoted or forwarded text; `l[1..]` are the
/// lines after it.
fn quoteStart(l: []const []const u8) bool {
    const line = l[0];
    if (line.len == 0) return false;
    if (line[0] == '>') return true;
    if (attribution(line, line)) return true;
    if (l.len > 1 and l[1].len > 0 and l[1].len < 80 and attribution(line, l[1])) {
        if (std.mem.startsWith(u8, line, "On ") or std.mem.startsWith(u8, line, "W dniu ") or
            std.mem.indexOfScalar(u8, line, '@') != null or line[line.len - 1] == '<') return true;
    }
    const markers = [_][]const u8{
        "forwarded message", "original message",
        "przekazana wiadomość",
        "wiadomość oryginalna",
    };
    if (line[0] == '-') {
        for (markers) |mk| {
            if (std.ascii.findIgnoreCase(line, mk) != null) return true;
        }
    }
    if (std.ascii.startsWithIgnoreCase(line, "Begin forwarded message")) return true;
    const blocks = [_]struct { []const u8, []const []const u8 }{
        .{ "From:", &.{ "Sent:", "Date:", "Subject:" } },
        .{ "Od:", &.{ "Wysłano:", "Data:", "Temat:" } },
    };
    for (blocks) |b| {
        if (!std.mem.startsWith(u8, line, b[0])) continue;
        for (l[1..@min(l.len, 4)]) |next| {
            for (b[1]) |key| {
                if (std.mem.startsWith(u8, next, key)) return true;
            }
        }
    }
    return false;
}

/// Whether `first` .. `last` reads as "On ... wrote:" or its Polish forms.
fn attribution(first: []const u8, last: []const u8) bool {
    if (std.mem.endsWith(u8, last, "wrote:")) return std.mem.startsWith(u8, first, "On ");
    if (std.mem.endsWith(u8, last, "pisze:")) return std.mem.startsWith(u8, first, "W dniu ");
    for ([_][]const u8{ "napisał(a):", "napisał:", "napisała:" }) |end| {
        if (std.mem.endsWith(u8, last, end)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test {
    _ = @import("charset.zig");
    _ = @import("html.zig");
    _ = @import("classify.zig");
}

/// `s` with every "\n" made "\r\n", as mail arrives.
fn crlf(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\n') try out.append(a, '\r');
        try out.append(a, c);
    }
    return out.items;
}

const polish = "Zażółć gęślą jaźń — Łódź";

fn singlePart(a: Allocator, content_type: []const u8, cte: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "From: Jan Kowalski <jan@example.pl>\r\nTo: anna@example.pl\r\n" ++
        "Subject: Test\r\nDate: Mon, 23 Nov 2026 10:00:00 +0100\r\nMIME-Version: 1.0\r\n" ++
        "Content-Type: {s}\r\nContent-Transfer-Encoding: {s}\r\n\r\n{s}", .{ content_type, cte, body });
}

test "polish_charsets_read_the_same" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "text/plain; charset=utf-8", "8bit", polish ++ "\r\n" },
        .{ "text/plain; charset=\"UTF-8\"", "quoted-printable", "Za=C5=BC=C3=B3=C5=82=C4=87 g=C4=99=C5=9Bl=C4=85 ja=C5=BA=C5=84 =E2=80=94 =\r\n=C5=81=C3=B3d=C5=BA\r\n" },
        .{ "text/plain; charset=utf-8", "base64", "WmHFvMOzxYLEhyBnxJnFm2zEhSBqYcW6xYQg4oCUIMWBw7Nkxbo=\r\n" },
        .{ "text/plain; charset=windows-1250", "quoted-printable", "Za=BF=F3=B3=E6 g=EA=9Cl=B9 ja=9F=F1 =97 =A3=F3d=9F\r\n" },
        .{ "text/plain; charset=\"Windows-1250\"", "base64", "WmG/87PmIGfqnGy5IGphn/EglyCj82Sf\r\n" },
        .{ "text/plain; charset=windows-1250", "8bit", "Za\xBF\xF3\xB3\xE6 g\xEA\x9Cl\xB9 ja\x9F\xF1 \x97 \xA3\xF3d\x9F\r\n" },
        // ISO-8859-2 has no dash, so these are HTML with an entity for it.
        .{ "text/html; charset=iso-8859-2", "quoted-printable", "<html><body><p>Za=BF=F3=B3=E6 g=EA=B6l=B1 ja=BC=F1 &mdash; =A3=F3d=BC</p></=\r\nbody></html>\r\n" },
        .{ "text/html; charset=ISO-8859-2", "base64", "PGh0bWw+PGJvZHk+PHA+WmG/87PmIGfqtmyxIGphvPEgJm1kYXNoOyCj82S8PC9wPjwvYm9keT48L2h0bWw+\r\n" },
        .{ "text/html; charset=latin2", "8bit", "<p>Za\xBF\xF3\xB3\xE6 g\xEA\xB6l\xB1 ja\xBC\xF1 &#8212; \xA3\xF3d\xBC</p>\r\n" },
    };
    for (cases) |c| {
        const m = try parse(a, try singlePart(a, c[0], c[1], c[2]));
        try testing.expectEqualStrings(polish, m.text);
        try testing.expectEqual(std.mem.startsWith(u8, c[0], "text/html"), m.from_html);
    }
}

test "encoded_words_in_headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "=?UTF-8?B?WmHFvMOzxYLEhyBnxJnFm2zEhSBqYcW6xYQ=?=", "Zażółć gęślą jaźń" },
        .{ "=?utf-8?Q?Faktura_VAT_nr_12/2026_=E2=80=93_do_zap=C5=82aty?=", "Faktura VAT nr 12/2026 – do zapłaty" },
        .{ "=?UTF-8?Q?Potwierdzenie_rezerwacji_?= =?UTF-8?Q?lotu_LO_3923?=", "Potwierdzenie rezerwacji lotu LO 3923" },
        // A character split across two words.
        .{ "=?UTF-8?B?UHJ6ZXN5xQ==?=\r\n =?UTF-8?B?gmthIHcgZHJvZHpl?=", "Przesyłka w drodze" },
        .{ "Re: =?iso-8859-2?Q?Spotkanie_w_=A3odzi?= jutro", "Re: Spotkanie w Łodzi jutro" },
        .{ "=?windows-1250?Q?=8Cwi=EAta?= =?ISO-8859-2?B?v7Nw?= i plain", "Świętażłp i plain" },
        .{ "Fwd: =?utf-8?q?Zam=C3=B3wienie?= nr 123", "Fwd: Zamówienie nr 123" },
        .{ "=?utf-8?X?abc?= stays", "=?utf-8?X?abc?= stays" },
        .{ "=?utf-8?B?not base64!?= stays", "=?utf-8?B?not base64!?= stays" },
        .{ "unterminated =?utf-8?Q?abc", "unterminated =?utf-8?Q?abc" },
        .{ "a =?utf-8?Q?b?= c", "a b c" },
        .{ "=?UTF-8*pl?Q?Dzie=C5=84_dobry?=", "Dzień dobry" },
        .{ "Raw UTF-8 subject: Zażółć", "Raw UTF-8 subject: Zażółć" },
        .{ "Raw Latin-1: Caf\xE9", "Raw Latin-1: Café" },
        .{ "Folded\r\n line", "Folded line" },
        .{ "Tab\r\n\tfolded", "Tab folded" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try decodeWords(a, c[0]));

    const raw = try crlf(a,
        \\From: =?UTF-8?Q?Jan_Kowalski_=E2=80=93_Biuro?= <Jan.Kowalski@Example.PL>
        \\Reply-To: "Biuro" <Biuro@Example.PL>
        \\To: =?utf-8?B?QW5uYSBOb3dhaw==?= <anna@example.pl>, "Doe, J" <j@example.com>
        \\Subject: =?utf-8?Q?Faktura_VAT_nr_12/2026_=E2=80=93?=
        \\ =?utf-8?Q?_do_zap=C5=82aty?=
        \\
        \\Body
    );
    const m = try parse(a, raw);
    try testing.expectEqualStrings("Jan Kowalski – Biuro", m.from_name);
    try testing.expectEqualStrings("jan.kowalski@example.pl", m.from_addr);
    try testing.expectEqualStrings("Jan Kowalski – Biuro <Jan.Kowalski@Example.PL>", m.from);
    try testing.expectEqualStrings("biuro@example.pl", m.reply_to);
    try testing.expectEqualStrings("Anna Nowak <anna@example.pl>, \"Doe, J\" <j@example.com>", m.to);
    try testing.expectEqualStrings("Faktura VAT nr 12/2026 – do zapłaty", m.subject);
}

test "qp_and_base64_bodies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qp = try parse(a, try singlePart(a, "text/plain; charset=utf-8", "Quoted-Printable", "Dzie=C5=84 dobry,\r\n" ++
        "\r\n" ++
        "informujemy, =C5=BCe Pa=C5=84stwa zam=C3=B3wienie nr 1234567 zosta=C5=82o wys=\r\n" ++
        "=c5=82ane. Kwota: 1+1=3D2 =ZZ zostaje.=\n" ++
        " Dalej.  \r\n" ++
        "Linia ko=C5=84czy si=C4=99 spacj=C4=85=20\r\n" ++
        "Koniec =   \r\n" ++
        "tekstu.=\r\n"));
    try testing.expectEqualStrings("Dzień dobry,\n\n" ++
        "informujemy, że Państwa zamówienie nr 1234567 zostało wysłane. Kwota: 1+1=2 =ZZ zostaje. Dalej.\n" ++
        "Linia kończy się spacją\nKoniec tekstu.", qp.text);

    const b64 = try parse(a, try singlePart(a, "text/plain; charset=UTF-8", "base64", "U3phbm93bmkgUGHFhHN0d28sCgp1cHJ6ZWptaWUgaW5mb3JtdWplbXksIMW8ZSBvZCAxIGdydWRu\r\n" ++
        "aWEgMjAyNiByLiB6bWllbmlhIHNpxJkgcmVndWxhbWluIMWbd2lhZGN6ZW5pYSB1c8WCdWcuIFBl\r\n" ++
        "xYJuYSB0cmXFm8SHIG5vd2VnbyByZWd1bGFtaW51IGplc3QgZG9zdMSZcG5hIG5hIG5hc3plaiBz\r\n" ++
        "dHJvbmllLgoKWiBwb3dhxbxhbmllbQpaZXNww7PFgiBPYnPFgnVnaSBLbGllbnRhCg==\r\n"));
    const want = "Szanowni Państwo,\n\nuprzejmie informujemy, że od 1 grudnia 2026 r. zmienia się regulamin " ++
        "świadczenia usług. Pełna treść nowego regulaminu jest dostępna na naszej stronie.\n\nZ poważaniem\nZespół Obsługi Klienta";
    try testing.expectEqualStrings(want, b64.text);

    // Stray characters and a missing end are skipped.
    const junk = try parse(a, try singlePart(a, "text/plain; charset=UTF-8", "BASE64", "U3phbm93bmkgUGHFhHN0d28s*\r\n  !!Cgp1cHJ6ZW\tptaWU"));
    try testing.expectEqualStrings("Szanowni Państwo,\n\nuprzejmie", junk.text);

    // The same mail with "\n" line ends reads the same.
    const lf = try parse(a, "Subject: x\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nwys=\n=C5=82ane\n\n\n\nkoniec  \n");
    try testing.expectEqualStrings("wysłane\n\nkoniec", lf.text);
    // No Content-Type: US-ASCII text.
    const bare = try parse(a, "Subject: x\r\n\r\nHello\r\nthere\r\n");
    try testing.expectEqualStrings("Hello\nthere", bare.text);
}

test "flowed_text_is_joined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, "Content-Type: text/plain; charset=utf-8; format=flowed\r\n\r\n" ++
        "To jest d\xC5\x82uga linia, kt\xC3\xB3ra \r\nzosta\xC5\x82a zawini\xC4\x99ta.\r\n" ++
        "> cytat \r\n> dalej\r\nNowa \r\n>> inny poziom\r\n-- \r\nPodpis\r\n");
    try testing.expectEqualStrings("To jest długa linia, która została zawinięta.\n> cytat dalej\nNowa\n>> inny poziom\n--\nPodpis", m.text);
    const d = try parse(a, "Content-Type: text/plain; format=flowed; delsp=yes\r\n\r\nZa\xC5\xBC\xC3\xB3 \r\n\xC5\x82\xC4\x87\r\n");
    try testing.expectEqualStrings("Zażółć", d.text);
}

const gmail_reply =
    \\MIME-Version: 1.0
    \\Date: Mon, 23 Nov 2026 19:30:12 +0100
    \\Message-ID: <CAF8x9Kp2Lm+QwErTy=uI@mail.gmail.com>
    \\Subject: Re: Spotkanie w czwartek
    \\From: Anna Nowak <anna.nowak@gmail.com>
    \\To: Tobias <owner.name@example.pl>
    \\Cc: jan@example.pl
    \\In-Reply-To: <CAB1zz@mail.gmail.com>
    \\References: <CAA0aa@mail.gmail.com>
    \\ <CAB1zz@mail.gmail.com>
    \\Content-Type: multipart/alternative; boundary="000000000000c2d4a705f1e2b3a4"
    \\
    \\--000000000000c2d4a705f1e2b3a4
    \\Content-Type: text/plain; charset="UTF-8"
    \\Content-Transfer-Encoding: quoted-printable
    \\
    \\Dzi=C4=99ki, pasuje mi czwartek o 10:00.
    \\
    \\Anna
    \\
    \\On Mon, Nov 23, 2026 at 6:02 PM Tobias <owner.name@example.pl> wrote:
    \\> Czy czwartek pasuje?
    \\
    \\--000000000000c2d4a705f1e2b3a4
    \\Content-Type: text/html; charset="UTF-8"
    \\Content-Transfer-Encoding: quoted-printable
    \\
    \\<div dir=3D"ltr">HTML VERSION<div><br></div><div>Anna</div></div>
    \\
    \\--000000000000c2d4a705f1e2b3a4--
    \\
;

test "multipart_alternative_prefers_plain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ try crlf(a, gmail_reply), gmail_reply }) |raw| {
        const m = try parse(a, raw);
        try testing.expectEqualStrings("Dzięki, pasuje mi czwartek o 10:00.\n\nAnna\n\n" ++
            "On Mon, Nov 23, 2026 at 6:02 PM Tobias <owner.name@example.pl> wrote:\n> Czy czwartek pasuje?", m.text);
        try testing.expect(!m.from_html);
        try testing.expectEqualStrings("Anna Nowak <anna.nowak@gmail.com>", m.from);
        try testing.expectEqualStrings("anna.nowak@gmail.com", m.from_addr);
        try testing.expectEqualStrings("Anna Nowak", m.from_name);
        try testing.expectEqualStrings("Tobias <owner.name@example.pl>", m.to);
        try testing.expectEqualStrings("jan@example.pl", m.cc);
        try testing.expectEqualStrings("Re: Spotkanie w czwartek", m.subject);
        try testing.expectEqualStrings("Mon, 23 Nov 2026 19:30:12 +0100", m.date);
        try testing.expectEqual(@as(?i64, 1795458612), m.date_s);
        try testing.expectEqualStrings("<CAF8x9Kp2Lm+QwErTy=uI@mail.gmail.com>", m.message_id);
        try testing.expectEqualStrings("<CAB1zz@mail.gmail.com>", m.in_reply_to);
        try testing.expectEqualStrings("<CAA0aa@mail.gmail.com> <CAB1zz@mail.gmail.com>", m.references);
        try testing.expectEqual(Auth.none, m.auth);
        try testing.expectEqual(@as(usize, 0), m.attachments.len);
    }
    // An empty plain part gives way to the HTML one.
    const empty_plain = try parse(a, try crlf(a,
        \\Subject: x
        \\Content-Type: multipart/alternative; boundary=b
        \\
        \\--b
        \\Content-Type: text/plain
        \\
        \\
        \\--b
        \\Content-Type: text/html
        \\
        \\<p>From HTML</p>
        \\--b--
    ));
    try testing.expectEqualStrings("From HTML", empty_plain.text);
    try testing.expect(empty_plain.from_html);
}

test "html_only_mail_reads_as_text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, try crlf(a,
        \\From: mBank <kontakt@mbank.pl>
        \\To: jan.kowalski@example.pl
        \\Subject: =?UTF-8?Q?Powiadomienie_o_operacji?=
        \\Date: Tue, 24 Nov 2026 08:15:00 +0100
        \\MIME-Version: 1.0
        \\Content-Type: text/html; charset=iso-8859-2
        \\Content-Transfer-Encoding: quoted-printable
        \\
        \\<html><head><style>td{font-family:Arial}</style></head><body>
        \\<table><tr><td>Szanowny Kliencie,</td></tr>
        \\<tr><td>na Twoim rachunku zaksi=EAgowano wp=B3yw: <b>1&nbsp;250,00 PLN</b>.</td></tr>
        \\<tr><td><a href=3D"https://www.mbank.pl/pomoc">Pomoc</a></td></tr></table>
        \\</body></html>
    ));
    try testing.expectEqualStrings("Szanowny Kliencie,\nna Twoim rachunku zaksięgowano wpływ: 1 250,00 PLN.\nPomoc (https://www.mbank.pl/pomoc)", m.text);
    try testing.expect(m.from_html);
    try testing.expectEqualStrings("Powiadomienie o operacji", m.subject);
    try testing.expectEqualStrings("mBank", m.from_name);
}

test "attachments_are_listed_not_read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, try crlf(a,
        \\From: "Biuro Rachunkowe Kowalski Sp. z o.o." <biuro@kowalski-ksiegowosc.pl>
        \\To: jan@example.pl
        \\Subject: Faktura VAT 12/2026
        \\Date: Wed, 25 Nov 2026 10:00:00 +0100
        \\MIME-Version: 1.0
        \\Content-Type: multipart/mixed;
        \\  boundary="----=_Part_12345_67890.1732525200000"
        \\
        \\This is a multi-part message in MIME format.
        \\------=_Part_12345_67890.1732525200000
        \\Content-Type: text/plain; charset=UTF-8
        \\Content-Transfer-Encoding: 8bit
        \\
        \\W załączeniu faktura za październik.
        \\------=_Part_12345_67890.1732525200000
        \\Content-Type: application/pdf; name="=?UTF-8?Q?Faktura_pa=C5=BAdziernik.pdf?="
        \\Content-Transfer-Encoding: base64
        \\Content-Disposition: attachment;
        \\ filename*=UTF-8''Faktura%20VAT%2012%2F2026%20pa%C5%BAdziernik.pdf
        \\
        \\JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoKPDwvTGVuZ3RoIDMgMCBSL0ZpbHRlci9GbGF0ZURl
        \\Y29kZT4+CnN0cmVhbQp4nDPQM1Qo5ypUMFAw0DMAAAo=
        \\------=_Part_12345_67890.1732525200000
        \\Content-Type: IMAGE/PNG
        \\Content-Disposition: inline
        \\Content-Transfer-Encoding: base64
        \\Content-ID: <logo@kowalski>
        \\
        \\iVBORw0KGgo=
        \\------=_Part_12345_67890.1732525200000
        \\Content-Type: application/octet-stream;
        \\ name*0*=UTF-8''Wyci%C4%85g%20z%20;
        \\ name*1*=rachunku;
        \\ name*2=".csv"
        \\Content-Disposition: attachment
        \\Content-Transfer-Encoding: base64
        \\
        \\ZGF0YTsxMjM=
        \\------=_Part_12345_67890.1732525200000
        \\Content-Type: text/plain; charset=utf-8; name="notatki.txt"
        \\
        \\Notatki, nie w tekście.
        \\------=_Part_12345_67890.1732525200000
        \\Content-Type: application/pdf; name=umowa.pdf
        \\Content-Transfer-Encoding: quoted-printable
        \\
        \\%PDF-1.4=0A=E2=82=AC
        \\------=_Part_12345_67890.1732525200000--
        \\
    ));
    try testing.expectEqualStrings("W załączeniu faktura za październik.", m.text);
    try testing.expectEqualStrings("Biuro Rachunkowe Kowalski Sp. z o.o.", m.from_name);
    try testing.expectEqual(@as(usize, 5), m.attachments.len);
    try testing.expectEqualStrings("Faktura VAT 12/2026 październik.pdf", m.attachments[0].name);
    try testing.expectEqualStrings("application/pdf", m.attachments[0].type);
    try testing.expectEqual(@as(usize, 89), m.attachments[0].size);
    try testing.expectEqualStrings("", m.attachments[1].name);
    try testing.expectEqualStrings("image/png", m.attachments[1].type);
    try testing.expectEqual(@as(usize, 8), m.attachments[1].size);
    try testing.expectEqualStrings("Wyciąg z rachunku.csv", m.attachments[2].name);
    try testing.expectEqualStrings("application/octet-stream", m.attachments[2].type);
    try testing.expectEqual(@as(usize, 8), m.attachments[2].size);
    try testing.expectEqualStrings("notatki.txt", m.attachments[3].name);
    try testing.expectEqualStrings("text/plain", m.attachments[3].type);
    try testing.expectEqualStrings("umowa.pdf", m.attachments[4].name);
    try testing.expectEqual(@as(usize, 12), m.attachments[4].size);
}

test "a_forwarded_mail_is_parsed_inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, try crlf(a,
        \\From: Tobias <owner.name@example.pl>
        \\To: anna@example.com
        \\Subject: Fwd: Potwierdzenie rezerwacji
        \\Date: Thu, 26 Nov 2026 12:00:00 +0000
        \\MIME-Version: 1.0
        \\Content-Type: multipart/mixed; boundary=outer
        \\
        \\--outer
        \\Content-Type: text/plain; charset=utf-8
        \\
        \\Patrz niżej.
        \\--outer
        \\Content-Type: message/rfc822
        \\Content-Disposition: attachment; filename="Potwierdzenie.eml"
        \\
        \\From: =?utf-8?Q?Hotel_Bristol_Warszawa?= <rezerwacje@hotelbristol.pl>
        \\To: owner.name@example.pl
        \\Subject: =?utf-8?B?UG90d2llcmR6ZW5pZSByZXplcndhY2pp?=
        \\Date: Wed, 25 Nov 2026 09:00:00 +0100
        \\Content-Type: multipart/alternative; boundary=inner
        \\
        \\--inner
        \\Content-Type: text/plain; charset=utf-8
        \\Content-Transfer-Encoding: quoted-printable
        \\
        \\Dzi=C4=99kujemy za rezerwacj=C4=99. Przyjazd: 10.12.2026.
        \\--inner
        \\Content-Type: text/html; charset=utf-8
        \\
        \\<p>HTML</p>
        \\--inner--
        \\
        \\--outer--
        \\
    ));
    try testing.expectEqualStrings("Patrz niżej.", m.text);
    try testing.expectEqual(@as(usize, 0), m.attachments.len);
    try testing.expectEqual(@as(usize, 1), m.forwarded.len);
    const f = m.forwarded[0];
    try testing.expectEqualStrings("Hotel Bristol Warszawa <rezerwacje@hotelbristol.pl>", f.from);
    try testing.expectEqualStrings("Potwierdzenie rezerwacji", f.subject);
    try testing.expectEqualStrings("Wed, 25 Nov 2026 09:00:00 +0100", f.date);
    try testing.expectEqualStrings("Dziękujemy za rezerwację. Przyjazd: 10.12.2026.", f.text);

    // Forwards inside forwards stop at a depth of 5.
    var deep: std.ArrayList(u8) = .empty;
    for (0..8) |_| try deep.appendSlice(a, "Subject: level\r\nContent-Type: message/rfc822\r\n\r\n");
    try deep.appendSlice(a, "Subject: bottom\r\n\r\ntext\r\n");
    const d = try parse(a, deep.items);
    try testing.expectEqual(@as(usize, 1), d.forwarded.len);
}

const google_invite =
    \\From: Anna Nowak <anna.nowak@example.com>
    \\To: owner.name@example.pl
    \\Subject: Invitation: =?UTF-8?Q?Przegl=C4=85d_kwartalny?= @ Tue Dec 1, 2026 9:30am - 10:30am
    \\ (CET) (owner.name@example.pl)
    \\Date: Mon, 23 Nov 2026 15:04:05 +0000
    \\MIME-Version: 1.0
    \\Content-Type: multipart/mixed; boundary="000000000000a1a2a3a4a5a6a7a8"
    \\
    \\--000000000000a1a2a3a4a5a6a7a8
    \\Content-Type: multipart/alternative; boundary="000000000000b1b2b3b4b5b6b7b8"
    \\
    \\--000000000000b1b2b3b4b5b6b7b8
    \\Content-Type: text/plain; charset="UTF-8"; format=flowed; delsp=yes
    \\Content-Transfer-Encoding: base64
    \\
    \\QW5uYSBOb3dhayB6YXByb3NpxYJhIENpxJkgbmEgd3lkYXJ6ZW5pZQoKUHJ6ZWdsxIVkIGt3YXJ0
    \\YWxueQp3dG9yZWssIDEgZ3J1ZG5pYSAyMDI2IDA5OjMwIOKAkyAxMDozMCAoY3phcyDFm3JvZGtv
    \\d29ldXJvcGVqc2tpIHN0YW5kYXJkb3d5IC0gV2Fyc3phd2EpCgpEb8WCxIVjeiBwcnpleiBHb29n
    \\bGUgTWVldDogaHR0cHM6Ly9tZWV0Lmdvb2dsZS5jb20vYWJjLWRlZmctaGlqCg==
    \\--000000000000b1b2b3b4b5b6b7b8
    \\Content-Type: text/html; charset="UTF-8"
    \\Content-Transfer-Encoding: quoted-printable
    \\
    \\<p>Przegl=C4=85d kwartalny</p>
    \\--000000000000b1b2b3b4b5b6b7b8
    \\Content-Type: text/calendar; charset="UTF-8"; method=REQUEST
    \\Content-Transfer-Encoding: 7bit
    \\
    \\BEGIN:VCALENDAR
    \\PRODID:-//Google Inc//Google Calendar 70.9054//EN
    \\VERSION:2.0
    \\CALSCALE:GREGORIAN
    \\METHOD:REQUEST
    \\BEGIN:VTIMEZONE
    \\TZID:Europe/Warsaw
    \\BEGIN:STANDARD
    \\TZOFFSETFROM:+0200
    \\TZOFFSETTO:+0100
    \\DTSTART:19701025T030000
    \\END:STANDARD
    \\END:VTIMEZONE
    \\BEGIN:VEVENT
    \\DTSTART;TZID=Europe/Warsaw:20261201T093000
    \\DTEND;TZID=Europe/Warsaw:20261201T103000
    \\DTSTAMP:20261123T150405Z
    \\ORGANIZER;CN=Anna Nowak:mailto:anna.nowak@example.com
    \\UID:7kukuqrfedlm2f9t2vr3uqkn9c@google.com
    \\ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
    \\ TRUE;CN=owner.name@example.pl;X-NUM-GUESTS=0:mailto:owner.name@example.pl
    \\CREATED:20261123T150404Z
    \\DESCRIPTION:Agenda: wyniki Q4\, plan na 2027
    \\LOCATION:Sala konferencyjna 2\, ul. Marszałkowska 1\, Warszawa
    \\SEQUENCE:0
    \\STATUS:CONFIRMED
    \\SUMMARY:Przegląd kwartalny – zespół produktu i dział sprzedaży (Warszawa
    \\  i Kraków)
    \\TRANSP:OPAQUE
    \\BEGIN:VALARM
    \\ACTION:DISPLAY
    \\DESCRIPTION:This is an event reminder
    \\SUMMARY:Alarm
    \\TRIGGER:-P0DT0H30M0S
    \\END:VALARM
    \\END:VEVENT
    \\END:VCALENDAR
    \\
    \\--000000000000b1b2b3b4b5b6b7b8--
    \\
    \\--000000000000a1a2a3a4a5a6a7a8
    \\Content-Type: application/ics; name="invite.ics"
    \\Content-Disposition: attachment; filename="invite.ics"
    \\Content-Transfer-Encoding: base64
    \\
    \\QkVHSU46VkNBTEVOREFSDQpNRVRIT0Q6UkVRVUVTVA0KRU5EOlZDQUxFTkRBUg0K
    \\--000000000000a1a2a3a4a5a6a7a8--
    \\
;

test "an_invitation_gives_its_event" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, try crlf(a, google_invite));
    try testing.expectEqualStrings("Invitation: Przegląd kwartalny @ Tue Dec 1, 2026 9:30am - 10:30am (CET) (owner.name@example.pl)", m.subject);
    const inv = m.invite orelse return error.TestExpectedInvite;
    try testing.expectEqualStrings("REQUEST", inv.method);
    try testing.expectEqualStrings("Przegląd kwartalny – zespół produktu i dział sprzedaży (Warszawa i Kraków)", inv.summary);
    try testing.expectEqualStrings("2026-12-01 09:30", inv.start);
    try testing.expectEqualStrings("2026-12-01 10:30", inv.end);
    try testing.expectEqualStrings("Sala konferencyjna 2, ul. Marszałkowska 1, Warszawa", inv.location);
    try testing.expectEqualStrings("anna.nowak@example.com", inv.organizer);
    try testing.expect(std.mem.startsWith(u8, m.text, "Anna Nowak zaprosiła Cię na wydarzenie\n\nPrzegląd kwartalny\n"));
    try testing.expect(std.mem.indexOf(u8, m.text, "BEGIN:VCALENDAR") == null);
    try testing.expectEqual(@as(usize, 1), m.attachments.len);
    try testing.expectEqualStrings("invite.ics", m.attachments[0].name);
    try testing.expectEqualStrings("application/ics", m.attachments[0].type);

    // Outlook: only an .ics attachment, times in UTC.
    const outlook = try parse(a, try crlf(a,
        \\From: "Kowalski, Jan" <Jan.Kowalski@Example.PL>
        \\Subject: Spotkanie zespołu
        \\Content-Type: multipart/mixed; boundary="_000_DB9PR"
        \\
        \\--_000_DB9PR
        \\Content-Type: text/plain; charset="iso-8859-2"
        \\Content-Transfer-Encoding: quoted-printable
        \\
        \\Zapraszam na spotkanie.
        \\--_000_DB9PR
        \\Content-Type: application/octet-stream; name="spotkanie.ics"
        \\Content-Disposition: attachment; filename="spotkanie.ics"
        \\Content-Transfer-Encoding: base64
        \\
        \\QkVHSU46VkNBTEVOREFSDQpQUk9ESUQ6LS8vTWljcm9zb2Z0IENvcnBvcmF0aW9uLy9PdXRsb29r
        \\IDE2LjAgTUlNRURJUi8vRU4NClZFUlNJT046Mi4wDQpNRVRIT0Q6UkVRVUVTVA0KQkVHSU46VkVW
        \\RU5UDQpPUkdBTklaRVI7Q049Iktvd2Fsc2tpLCBKYW4iOk1BSUxUTzpKYW4uS293YWxza2lARXhh
        \\bXBsZS5QTA0KRFRTVEFSVDoyMDI2MTIwMVQwODMwMDBaDQpEVEVORDoyMDI2MTIwMVQwOTMwMDBa
        \\DQpMT0NBVElPTjpUZWFtcw0KU1VNTUFSWTpTcG90a2FuaWUgemVzcG/FgnUNClVJRDowNDAwMDAw
        \\MDgyMDBFMDAwNzRDNUI3MTAxQTgyRTAwOA0KRU5EOlZFVkVOVA0KRU5EOlZDQUxFTkRBUg0K
        \\--_000_DB9PR--
    ));
    const oi = outlook.invite orelse return error.TestExpectedInvite;
    try testing.expectEqualStrings("REQUEST", oi.method);
    try testing.expectEqualStrings("Spotkanie zespołu", oi.summary);
    try testing.expectEqualStrings("2026-12-01 08:30 UTC", oi.start);
    try testing.expectEqualStrings("2026-12-01 09:30 UTC", oi.end);
    try testing.expectEqualStrings("Teams", oi.location);
    try testing.expectEqualStrings("jan.kowalski@example.pl", oi.organizer);
    try testing.expectEqualStrings("Zapraszam na spotkanie.", outlook.text);
    try testing.expectEqual(@as(usize, 1), outlook.attachments.len);

    // An all-day event, the calendar being the whole mail.
    const allday = try parse(a, try crlf(a,
        \\Subject: Wigilia firmowa
        \\Content-Type: text/calendar; method=CANCEL; charset=utf-8
        \\
        \\BEGIN:VCALENDAR
        \\METHOD:CANCEL
        \\BEGIN:VEVENT
        \\DTSTART;VALUE=DATE:20261224
        \\DTEND;VALUE=DATE:20261225
        \\SUMMARY:Wigilia firmowa\; sala A
        \\END:VEVENT
        \\END:VCALENDAR
    ));
    const ai = allday.invite orelse return error.TestExpectedInvite;
    try testing.expectEqualStrings("CANCEL", ai.method);
    try testing.expectEqualStrings("2026-12-24", ai.start);
    try testing.expectEqualStrings("2026-12-25", ai.end);
    try testing.expectEqualStrings("Wigilia firmowa; sala A", ai.summary);
    try testing.expectEqualStrings("", allday.text);
}

fn authOf(a: Allocator, from: []const u8, results: []const []const u8) !Auth {
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, "Delivered-To: owner.name@example.pl\r\nReceived: by 2002:a05:7300:1234 with SMTP id x;\r\n        Mon, 23 Nov 2026 10:00:01 -0800 (PST)\r\n");
    for (results) |r| try raw.print(a, "Authentication-Results: {s}\r\n", .{r});
    try raw.print(a, "From: {s}\r\nSubject: x\r\n\r\nbody\r\n", .{from});
    return (try parse(a, raw.items)).auth;
}

test "authentication_results_pass_only_for_the_from_domain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gmail_ok = "mx.google.com;\r\n       dkim=pass header.i=@gmail.com header.s=20230601 header.b=Xy7Zq1Ab;\r\n" ++
        "       spf=pass (google.com: domain of anna.nowak@gmail.com designates 209.85.220.41 as permitted sender) smtp.mailfrom=anna.nowak@gmail.com";
    try testing.expectEqual(Auth.pass, try authOf(a, "Anna Nowak <anna.nowak@gmail.com>", &.{gmail_ok}));
    try testing.expectEqual(Auth.pass, try authOf(a, "anna.nowak@gmail.com", &.{"mx.google.com; dkim=pass header.d=gmail.com header.s=20230601"}));
    try testing.expectEqual(Auth.pass, try authOf(a, "Anna <Anna.Nowak@GMail.com>", &.{"mx.google.com; DKIM=PASS header.d=GMAIL.COM"}));
    try testing.expectEqual(Auth.pass, try authOf(a, "Alerts <alerts@mail.example.com>", &.{"mx.google.com; dkim=pass header.d=example.com"}));
    try testing.expectEqual(Auth.pass, try authOf(a, "PayPal <service@paypal.com>", &.{"mx.google.com; dkim=pass header.d=evil.com; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=paypal.com"}));
    // Microsoft writes no server name first.
    try testing.expectEqual(Auth.pass, try authOf(a, "biuro@example.pl", &.{"spf=pass (sender IP is 40.107.22.55) smtp.mailfrom=example.pl; dkim=pass (signature was verified) header.d=example.pl;dmarc=pass action=none header.from=example.pl;compauth=pass reason=100"}));

    try testing.expectEqual(Auth.fail, try authOf(a, "PayPal <service@paypal.com>", &.{"mx.google.com;\r\n       dkim=pass header.d=evil.com header.s=s1;\r\n       spf=pass smtp.mailfrom=evil.com;\r\n       dmarc=fail (p=REJECT sp=REJECT dis=QUARANTINE) header.from=paypal.com"}));
    try testing.expectEqual(Auth.fail, try authOf(a, "x@example.com", &.{"mx.google.com; dkim=pass header.d=ample.com"}));
    try testing.expectEqual(Auth.fail, try authOf(a, "x@example.com", &.{"mx.google.com; dkim=pass header.d=sub.example.com"}));
    try testing.expectEqual(Auth.fail, try authOf(a, "x@example.com", &.{"mx.google.com; dkim=fail (dmarc=pass would be nice) header.d=example.com"}));
    try testing.expectEqual(Auth.fail, try authOf(a, "x@example.com", &.{"mx.example.net; none"}));
    // Only the topmost header, the receiving server's, counts.
    try testing.expectEqual(Auth.fail, try authOf(a, "PayPal <service@paypal.com>", &.{ "mx.google.com; dkim=none; spf=softfail smtp.mailfrom=evil.com; dmarc=fail header.from=paypal.com", "mx.google.com; dmarc=pass header.from=paypal.com; dkim=pass header.d=paypal.com" }));
    try testing.expectEqual(Auth.none, try authOf(a, "anna.nowak@gmail.com", &.{}));
}

test "compose_round_trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "Dzień dobry,\r\n\r\npasuje mi wtorek. " ++ polish ++ ".\n" ++
        ".\n" ++
        ".ukryta linia\n" ++
        "Bardzo długa linia, która na pewno przekroczy siedemdziesiąt sześć znaków, bo zawiera mnóstwo polskich liter: ąćęłńóśźż ĄĆĘŁŃÓŚŹŻ, i jeszcze trochę.\n" ++
        "x = y, 100% pewności\n" ++
        "\tWcięcie tabulatorem\n" ++
        "Pozdrawiam\n-- \nTobias";
    const o: Outgoing = .{
        .from = "owner.name@example.pl",
        .from_name = "Tobiasz Dudek-Żółkiewski",
        .to = &.{"anna.nowak@example.com"},
        .cc = &.{ "jan.kowalski@example.pl", "biuro.rachunkowe.kowalski@kowalski-ksiegowosc.pl", "zarzad@example.pl" },
        .subject = "Re: Przegląd kwartalny – zespół produktu i dział sprzedaży, Łódź i Kraków (grudzień 2026)",
        .text = body,
        .in_reply_to = "<CAF8x9Kp2Lm+QwErTy=uI@mail.gmail.com>",
        .references = "<CAA0aa@mail.gmail.com> <CAB1zz@mail.gmail.com> <CAF8x9Kp2Lm+QwErTy=uI@mail.gmail.com>",
        .message_id = "<20261123183000.4f2a9c@mailmcp>",
        .date_s = 1795458600,
        .utc_offset_min = 60,
    };
    const raw = try compose(a, o);
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    while (lines.next()) |line| {
        try testing.expect(line.len <= 78);
        try testing.expect(std.mem.indexOfAny(u8, line, "\r\n") == null);
        if (line.len > 0) try testing.expect(line[line.len - 1] != ' ' and line[line.len - 1] != '\t');
    }
    try testing.expect(std.mem.endsWith(u8, raw, "\r\n"));
    try testing.expect(std.mem.indexOf(u8, raw, "Date: Mon, 23 Nov 2026 19:30:00 +0100\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "MIME-Version: 1.0\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "Content-Type: text/plain; charset=UTF-8\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "Content-Transfer-Encoding: quoted-printable\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "From: =?UTF-8?B?") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "Subject: =?UTF-8?B?") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\r\n=2E\r\n=2Eukryta linia\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\r\n.") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "x =3D y, 100% pewno=C5=9Bci\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\r\n-- =\r\n\r\n") != null or std.mem.indexOf(u8, raw, "\r\n--=20\r\n") != null);

    const m = try parse(a, raw);
    try testing.expectEqualStrings(o.subject, m.subject);
    try testing.expectEqualStrings(o.from_name, m.from_name);
    try testing.expectEqualStrings(o.from, m.from_addr);
    try testing.expectEqualStrings("anna.nowak@example.com", m.to);
    try testing.expectEqualStrings("jan.kowalski@example.pl, biuro.rachunkowe.kowalski@kowalski-ksiegowosc.pl, zarzad@example.pl", m.cc);
    try testing.expectEqualStrings(o.in_reply_to, m.in_reply_to);
    try testing.expectEqualStrings(o.references, m.references);
    try testing.expectEqualStrings(o.message_id, m.message_id);
    try testing.expectEqual(@as(?i64, o.date_s), m.date_s);
    const want = "Dzień dobry,\n\npasuje mi wtorek. " ++ polish ++ ".\n" ++
        ".\n" ++
        ".ukryta linia\n" ++
        "Bardzo długa linia, która na pewno przekroczy siedemdziesiąt sześć znaków, bo zawiera mnóstwo polskich liter: ąćęłńóśźż ĄĆĘŁŃÓŚŹŻ, i jeszcze trochę.\n" ++
        "x = y, 100% pewności\n" ++
        "\tWcięcie tabulatorem\n" ++
        "Pozdrawiam\n--\nTobias";
    try testing.expectEqualStrings(want, m.text);

    // Plain ASCII stays readable; a long one folds; specials get quotes.
    const plain = try compose(a, .{
        .from = "jan@example.pl",
        .from_name = "Kowalski, Jan \"JK\"",
        .to = &.{"anna@example.com"},
        .subject = "Meeting notes for the quarterly review of the product team and the sales department",
        .text = "Hi",
        .message_id = "<1@x>",
        .date_s = 0,
    });
    try testing.expect(std.mem.indexOf(u8, plain, "From: \"Kowalski, Jan \\\"JK\\\"\" <jan@example.pl>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "Subject: Meeting notes") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "In-Reply-To") == null);
    const pm = try parse(a, plain);
    try testing.expectEqualStrings("Kowalski, Jan \"JK\"", pm.from_name);
    try testing.expectEqualStrings("Meeting notes for the quarterly review of the product team and the sales department", pm.subject);
    try testing.expectEqualStrings("Hi", pm.text);
    var pl = std.mem.splitSequence(u8, plain, "\r\n");
    while (pl.next()) |line| try testing.expect(line.len <= 78);

    // A negative offset.
    const west = try compose(a, .{ .from = "a@b.co", .to = &.{"c@d.co"}, .subject = "x", .text = "", .message_id = "<2@x>", .date_s = 1795458600, .utc_offset_min = -330 });
    try testing.expect(std.mem.indexOf(u8, west, "Date: Mon, 23 Nov 2026 13:00:00 -0530\r\n") != null);
}

test "compose_refuses_header_injection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Outgoing = .{ .from = "me@example.com", .to = &.{"you@example.com"}, .subject = "Hi", .text = "x", .message_id = "<1@example.com>", .date_s = 0 };
    var o = base;
    o.subject = "Hello\r\nBcc: victim@example.com";
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.from_name = "Eve\nBcc: x@example.com";
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.to = &.{"you@example.com\r\nBcc: c@example.com"};
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.cc = &.{ "ok@example.com", "x@example.com\n" };
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.in_reply_to = "<x@y>\r\nX-Evil: 1";
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.references = "<a@b>\r";
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.message_id = "<x@y>\n";
    try testing.expectError(error.BadHeader, compose(a, o));
    o = base;
    o.from = "me@example.com\r\n";
    try testing.expectError(error.BadHeader, compose(a, o));

    for ([_][]const u8{ "not-an-address", "a b@example.com", "<a@example.com>", "a@example.com, c@example.com", "\"a\"@example.com", "@example.com", "a@", "a@b>" }) |bad| {
        o = base;
        o.to = &.{bad};
        try testing.expectError(error.BadAddress, compose(a, o));
    }
    o = base;
    o.from = "me";
    try testing.expectError(error.BadAddress, compose(a, o));
    o = base;
    o.cc = &.{"x y@z.pl"};
    try testing.expectError(error.BadAddress, compose(a, o));
    // A body may hold anything.
    o = base;
    o.text = "Line\r\nBcc: x@y.z\r\n\r\n.\r\n";
    _ = try compose(a, o);
}

test "quoted_and_forwarded_parts_split_off" {
    const cases = [_][3][]const u8{
        .{ "Sounds good.\n\nOn Mon, Nov 23, 2026 at 6:02 PM Tobias <owner.name@example.pl> wrote:\n> Thursday?\n", "Sounds good.", "On Mon, Nov 23, 2026 at 6:02 PM Tobias <owner.name@example.pl> wrote:\n> Thursday?\n" },
        .{ "Ok.\n\nOn Mon, Nov 23, 2026 at 6:02 PM Tobias Dudek <\nowner.name@example.pl> wrote:\n\n> x", "Ok.", "On Mon, Nov 23, 2026 at 6:02 PM Tobias Dudek <\nowner.name@example.pl> wrote:\n\n> x" },
        .{ "Dzięki!\n\nW dniu pon., 23 lis 2026 o 18:02 Tobias <owner.name@example.pl> napisał(a):\n> Pasuje?", "Dzięki!", "W dniu pon., 23 lis 2026 o 18:02 Tobias <owner.name@example.pl> napisał(a):\n> Pasuje?" },
        .{ "Dzięki!\n\npon., 23 lis 2026 o 18:02 Tobias <owner.name@example.pl>\nnapisał(a):\n\n> Pasuje?", "Dzięki!", "pon., 23 lis 2026 o 18:02 Tobias <owner.name@example.pl>\nnapisał(a):\n\n> Pasuje?" },
        .{ "Ok\n\nW dniu 23.11.2026 o 18:02, Jan Kowalski pisze:\n> a", "Ok", "W dniu 23.11.2026 o 18:02, Jan Kowalski pisze:\n> a" },
        .{ "Please see below.\n\n________________________________\nFrom: Jan Kowalski <jan@example.pl>\nSent: Monday, November 23, 2026 6:02 PM\nTo: Tobias <owner.name@example.pl>\nSubject: Faktura\n\nbody", "Please see below.", "________________________________\nFrom: Jan Kowalski <jan@example.pl>\nSent: Monday, November 23, 2026 6:02 PM\nTo: Tobias <owner.name@example.pl>\nSubject: Faktura\n\nbody" },
        .{ "Proszę o kontakt.\n\nOd: Jan Kowalski <jan@example.pl>\nWysłano: poniedziałek, 23 listopada 2026 18:02\nDo: Tobias\nTemat: Faktura\n\ntreść", "Proszę o kontakt.", "Od: Jan Kowalski <jan@example.pl>\nWysłano: poniedziałek, 23 listopada 2026 18:02\nDo: Tobias\nTemat: Faktura\n\ntreść" },
        .{ "FYI\n\n---------- Forwarded message ---------\nFrom: LOT <noreply@lot.com>\nDate: Mon, Nov 23, 2026\n", "FYI", "---------- Forwarded message ---------\nFrom: LOT <noreply@lot.com>\nDate: Mon, Nov 23, 2026\n" },
        .{ "Zobacz\n\n---------- Przekazana wiadomość ---------\nOd: LOT\n", "Zobacz", "---------- Przekazana wiadomość ---------\nOd: LOT\n" },
        .{ "Tak\n-------- Wiadomość oryginalna --------\nTemat: x", "Tak", "-------- Wiadomość oryginalna --------\nTemat: x" },
        .{ "Yes\n-------- Original Message --------\nSubject: x", "Yes", "-------- Original Message --------\nSubject: x" },
        .{ "Yes\n\n-----Original Message-----\nFrom: a\n", "Yes", "-----Original Message-----\nFrom: a\n" },
        .{ "Look\n\nBegin forwarded message:\n\nFrom: a@b.c\n", "Look", "Begin forwarded message:\n\nFrom: a@b.c\n" },
        .{ "Hi\n\nFrom: Jan <jan@example.pl>\nDate: Mon, 23 Nov 2026\nSubject: x\n\ny", "Hi", "From: Jan <jan@example.pl>\nDate: Mon, 23 Nov 2026\nSubject: x\n\ny" },
        .{ "> quoted first\nthen reply", "", "> quoted first\nthen reply" },
        .{ "  Just text.\r\nFrom: here we go\nand more.\n\n", "Just text.\r\nFrom: here we go\nand more.", "" },
        .{ "On Monday we meet.\nOK?", "On Monday we meet.\nOK?", "" },
        .{ "", "", "" },
    };
    for (cases) |c| {
        const s = splitQuoted(c[0]);
        try testing.expectEqualStrings(c[1], s.own);
        try testing.expectEqualStrings(c[2], s.rest);
    }
}

test "dates_parse" {
    const cases = [_]struct { []const u8, ?i64 }{
        .{ "Mon, 1 Dec 2026 09:30:00 +0100", 1796113800 },
        .{ "1 Dec 2026 09:30:00 +0100", 1796113800 },
        .{ "Tue, 01 Dec 2026 08:30:00 -0000", 1796113800 },
        .{ "Tue, 01 Dec 26 09:30 GMT", 1796117400 },
        .{ "01 Dec 2026 09:30:00 UT", 1796117400 },
        .{ "01 dec 2026 09:30:00 Z", 1796117400 },
        .{ "Tue,  1 Dec 2026 09:30:00 +0000 (UTC)", 1796117400 },
        .{ "Tue, 1 Dec 2026 10:30:00 +0100 (CET)", 1796117400 },
        .{ "Mon, 23 Nov 2026 19:30:12 -0500 (EST)", 1795480212 },
        .{ "Mon, 23 Nov 2026 19:30:12 EST", 1795480212 },
        .{ "Mon, 23 Nov 2026 20:30:12 EDT", 1795480212 },
        .{ "23 Nov 2026 19:30 PDT", 1795487400 },
        .{ "23 Nov 2026 18:30 PST", 1795487400 },
        .{ "23 Nov 2026 21:30 CDT", 1795487400 },
        .{ "Mon, 23 Nov 2026 19:30:12 +0100", 1795458612 },
        .{ "Tue, 29 Feb 2028 12:00:00 +0000", 1835438400 },
        .{ "Wed, 1 Dec 99 09:30:00 +0000", 944040600 },
        .{ "Sat, 1 Jan 2000 00:00:00 +0000", 946684800 },
        .{ "Thu, 1 Jan 1970 00:00:00 +0000", 0 },
        .{ "Mon, 1 Dec 2026 09:30:00", 1796117400 },
        .{ "Mon, 1 Dec 2026\r\n 09:30:00 +0100", 1796113800 },
        .{ "", null },
        .{ "yesterday", null },
        .{ "32 Dec 2026 10:00:00 +0000", null },
        .{ "30 Feb 2026 10:00:00 +0000", null },
        .{ "1 Foo 2026 10:00 +0000", null },
        .{ "1 Dec 2026 25:00 +0000", null },
        .{ "1 Dec", null },
    };
    for (cases) |c| {
        testing.expectEqual(c[1], parseDate(c[0])) catch |e| {
            std.debug.print("date: {s}\n", .{c[0]});
            return e;
        };
    }
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 20788), daysFromCivil(2026, 12, 1));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
}

test "addresses_and_lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Jan@Example.pl", addrOf("Jan Kowalski <Jan@Example.pl>"));
    try testing.expectEqualStrings("jan@example.pl", addrOf("  jan@example.pl "));
    try testing.expectEqualStrings("j.doe@example.com", addrOf("\"Doe, J\" <j.doe@example.com>"));
    try testing.expectEqualStrings("jan@example.pl", addrOf("jan@example.pl (Jan Kowalski)"));
    try testing.expectEqualStrings("real@x.com", addrOf("\"a <b@c>\" <real@x.com>"));
    try testing.expectEqualStrings("a@b.pl", addrOf("<a@b.pl"));
    try testing.expectEqualStrings("", addrOf(""));
    const list = try addrList(a, "\"Doe, J\" <J.Doe@Example.com>, anna@x.pl,\r\n =?UTF-8?Q?Kowalski=2C_J?= <jan@y.pl>, Team: a@t.pl, B@t.pl;, undisclosed-recipients:;, (comment, here) c@z.pl");
    try testing.expectEqual(@as(usize, 6), list.len);
    const want = [_][]const u8{ "j.doe@example.com", "anna@x.pl", "jan@y.pl", "a@t.pl", "b@t.pl", "c@z.pl" };
    for (want, list) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqual(@as(usize, 0), (try addrList(a, "")).len);
}

test "broken_mail_still_reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try crlf(a, google_invite);
    var i: usize = 0;
    while (i <= full.len) : (i += 7) _ = try parse(a, full[0..i]);
    i = 0;
    while (i <= gmail_reply.len) : (i += 3) _ = try parse(a, gmail_reply[0..i]);
    // A missing final boundary.
    const m = try parse(a, "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--x\r\n\r\nsecond");
    try testing.expectEqualStrings("first\n\nsecond", m.text);
    // No boundary parameter: the body as text.
    const nb = try parse(a, "Content-Type: multipart/mixed\r\n\r\njust text");
    try testing.expectEqualStrings("just text", nb.text);
    // No empty line after the headers.
    const nh = try parse(a, "Subject: only headers\r\nFrom: a@b.c");
    try testing.expectEqualStrings("only headers", nh.subject);
    try testing.expectEqualStrings("", nh.text);
    _ = try parse(a, "");
    _ = try parse(a, "\r\n\r\n");
    _ = try parse(a, ":\r\n:::\r\n\r\n=?=?=?");
    _ = try parse(a, "Content-Type: text/plain; charset=\"\r\nContent-Transfer-Encoding: base64\r\n\r\n====");
    _ = try parse(a, "Content-Type: multipart/mixed; boundary=\"\"\r\n\r\n--\r\n--\r\n");
    _ = try parse(a, "Content-Type: text/calendar\r\n\r\nBEGIN:VEVENT\r\nDTSTART:2026\r\nORGANIZER:\r\n");
    _ = try parse(a, "Content-Type: application/pdf; name*0*=; name*1*=%\r\n\r\nx");
    var nested: std.ArrayList(u8) = .empty;
    for (0..200) |_| try nested.appendSlice(a, "Content-Type: multipart/mixed; boundary=z\r\n\r\n--z\r\n");
    _ = try parse(a, nested.items);
}

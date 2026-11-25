//! `harness config set SECTION.KEY VALUE` and `harness config get
//! SECTION.KEY`: one setting of config.ini, written in place (comments and
//! order kept) only when the result parses; read as harness uses it.

const std = @import("std");
const config = @import("config.zig");
const core = @import("core.zig");
const mail = @import("mail.zig");

const model = @import("model.zig");

/// `SECTION.KEY`; a named section's SECTION is `provider NAME`.
pub const Key = struct { section: []const u8, key: []const u8 };

/// What `set` or `get` came to: the new text or the value, else the one
/// line it was refused with.
pub const Result = struct { text: ?[]const u8 = null, value: ?[]const u8 = null, refused: ?[]const u8 = null };

/// `SECTION.KEY` as one argument (`provider local.url` too) or a named
/// section as two (`provider` `local.url`); null when it isn't one.
pub fn parseKey(a: std.mem.Allocator, args: []const []const u8) ?Key {
    const whole = switch (args.len) {
        1 => args[0],
        2 => if (std.mem.indexOfScalar(u8, args[0], '.') == null and std.mem.indexOfScalar(u8, args[1], '.') != null)
            std.fmt.allocPrint(a, "{s} {s}", .{ args[0], args[1] }) catch return null
        else
            return null,
        else => return null,
    };
    const dot = std.mem.lastIndexOfScalar(u8, whole, '.') orelse return null;
    const key = std.mem.trim(u8, whole[dot + 1 ..], " \t");
    if (key.len == 0) return null;
    // the section's words, one space between
    var sec: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, whole[0..dot], " \t");
    while (words.next()) |w| {
        if (sec.items.len > 0) sec.append(a, ' ') catch return null;
        sec.appendSlice(a, w) catch return null;
    }
    if (sec.items.len == 0) return null;
    return .{ .section = sec.items, .key = key };
}

/// NAME of a section `provider NAME`.
fn providerName(section: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, section, "provider ")) return null;
    return section["provider ".len..];
}

const provider_keys = [_][]const u8{ "api", "url", "auth", "key", "cache", "header" };

/// Whether config.ini has setting `k`.
fn known(k: Key) bool {
    if (providerName(k.section)) |name| {
        if (!model.validName(name)) return false;
        for (provider_keys) |pk| if (std.mem.eql(u8, pk, k.key)) return true;
        return false;
    }
    const ci = @typeInfo(config.Config).@"struct";
    inline for (ci.field_names, ci.field_types) |sname, ST| {
        if (comptime @typeInfo(ST) == .@"struct") if (std.mem.eql(u8, k.section, sname)) {
            inline for (@typeInfo(ST).@"struct".field_names) |fname| if (std.mem.eql(u8, k.key, fname)) return true;
            return false;
        };
    }
    return false;
}

/// A setting whose value is a stored secret's name (`model.key`,
/// `chat.token`, a provider's `key`).
fn namesSecret(k: Key) bool {
    return std.mem.eql(u8, k.key, "key") or std.mem.eql(u8, k.key, "token");
}

fn secretName(v: []const u8) bool {
    if (v.len == 0 or v.len > 64) return false;
    if (!(std.ascii.isLower(v[0]) or std.ascii.isDigit(v[0]))) return false;
    for (v) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// config.ini `text` with `k` set to `value_in`: the line in use changed
/// in place (its comment kept), else one added under its section, else
/// the section added at the end. Refused when the result doesn't parse.
pub fn setText(a: std.mem.Allocator, text: []const u8, k: Key, value_in: []const u8) !Result {
    return setAll(a, text, &.{.{ .key = k, .value = value_in }});
}

/// One setting and its value.
pub const Pair = struct { key: Key, value: []const u8 };

/// `KEY VALUE [KEY VALUE]...`, each key one argument or (a named
/// section) two; null when a key lacks its value.
pub fn parsePairs(a: std.mem.Allocator, args: []const []const u8) ?[]const Pair {
    var out: std.ArrayList(Pair) = .empty;
    var i: usize = 0;
    while (i < args.len) {
        const n: usize = if (std.mem.indexOfScalar(u8, args[i], '.') != null) 1 else 2;
        if (i + n >= args.len) return null;
        const k = parseKey(a, args[i .. i + n]) orelse return null;
        out.append(a, .{ .key = k, .value = args[i + n] }) catch return null;
        i += n + 1;
    }
    if (out.items.len == 0) return null;
    return out.items;
}

/// `setText` for each pair in turn, the result parsed once: settings
/// that only read together (a provider's api and url) go in together, or
/// none does.
pub fn setAll(a: std.mem.Allocator, text: []const u8, pairs: []const Pair) !Result {
    var out = text;
    for (pairs) |p| {
        const r = try apply(a, out, p.key, p.value);
        if (r.refused != null) return r;
        out = r.text.?;
    }
    if (try core.parseProblem(a, "config.ini", out, config.parse)) |why| return .{ .refused = try std.fmt.allocPrint(a, "Not changed: {s}", .{why}) };
    for (pairs) |p| if (startProblem(p)) |why| return .{ .refused = try std.fmt.allocPrint(a, "Not changed: {s}.{s} {s}", .{ p.key.section, p.key.key, why }) };
    return .{ .text = out };
}

/// What harness would refuse at its start of a value config.ini reads
/// (an address it can't call, a port past 65535); null: nothing.
fn startProblem(p: Pair) ?[]const u8 {
    const v = std.mem.trim(u8, p.value, " \t");
    const urls = [_][2][]const u8{ .{ "model", "url" }, .{ "search", "url" }, .{ "chat", "api" } };
    for (urls) |u| if (std.mem.eql(u8, p.key.section, u[0]) and std.mem.eql(u8, p.key.key, u[1])) {
        // omnigate's may stay unset
        if (v.len == 0 and std.mem.eql(u8, u[0], "model")) return null;
        return if (model.validUrl(v)) null else "takes an http:// or https:// address";
    };
    if (std.mem.eql(u8, p.key.section, "apps") and std.mem.eql(u8, p.key.key, "port")) {
        const n = std.fmt.parseInt(u32, v, 10) catch return "is a port, 0 to 65535";
        if (n > std.math.maxInt(u16)) return "is a port, 0 to 65535";
    }
    return null;
}

/// One setting written into `text`, unparsed.
fn apply(a: std.mem.Allocator, text: []const u8, k: Key, value_in: []const u8) !Result {
    const value = std.mem.trim(u8, value_in, " \t");
    if (!known(k)) return .{ .refused = try std.fmt.allocPrint(a, "config.ini has no setting {s}.{s}", .{ k.section, k.key }) };
    for (value) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f)
        return .{ .refused = try std.fmt.allocPrint(a, "{s}.{s}: a value is one line, with no control characters", .{ k.section, k.key }) };
    if (config.stripComment(value).len != value.len)
        return .{ .refused = try std.fmt.allocPrint(a, "{s}.{s}: a value can't hold \" ;\" or \" #\" (config.ini reads a comment from there)", .{ k.section, k.key }) };
    if (namesSecret(k) and !secretName(value))
        return .{ .refused = try std.fmt.allocPrint(a, "{s}.{s} takes a stored secret's name (a-z, 0-9, - and _); store the {s} itself with harness secret add NAME", .{ k.section, k.key, k.key }) };
    return .{ .text = (try replaceLast(a, text, k, value)) orelse try mail.setKey(a, text, k.section, k.key, value) };
}

/// The section of a header line (`[provider  local]` → "provider local").
fn headerSection(a: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const tl = std.mem.trim(u8, config.stripComment(line), " \t\r");
    if (tl.len < 2 or tl[0] != '[' or tl[tl.len - 1] != ']') return null;
    var sec: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, tl[1 .. tl.len - 1], " \t");
    while (words.next()) |w| {
        if (sec.items.len > 0) try sec.append(a, ' ');
        try sec.appendSlice(a, w);
    }
    return sec.items;
}

/// `text` with the last `k = …` line (the one harness uses) saying
/// `value`, as written before the `=` and with the comment after it
/// kept; null when there is none.
fn replaceLast(a: std.mem.Allocator, text: []const u8, k: Key, value: []const u8) !?[]const u8 {
    var at: ?struct { start: usize, end: usize } = null;
    var in = false;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..end];
        if (try headerSection(a, line)) |sec| {
            in = std.mem.eql(u8, sec, k.section);
        } else if (in) {
            const body = config.stripComment(line);
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                if (std.mem.eql(u8, std.mem.trim(u8, body[0..eq], " \t"), k.key)) at = .{ .start = pos, .end = end };
            }
        }
        pos = end + 1;
    }
    const where = at orelse return null;
    const line = text[where.start..where.end];
    const cr = std.mem.endsWith(u8, line, "\r");
    const raw = if (cr) line[0 .. line.len - 1] else line;
    const body = config.stripComment(raw);
    const eq = std.mem.indexOfScalar(u8, body, '=').?;
    // the comment, with the space before it
    var gap = body.len;
    while (gap > eq + 1 and (body[gap - 1] == ' ' or body[gap - 1] == '\t')) gap -= 1;
    const comment = if (body.len < raw.len) raw[gap..] else "";
    const before = std.mem.trimEnd(u8, raw[0 .. eq + 1], " \t");
    return try std.fmt.allocPrint(a, "{s}{s} {s}{s}{s}{s}", .{ text[0..where.start], before, value, comment, if (cr) "\r" else "", text[where.end..] });
}

/// The value of `k` harness uses with config.ini `text`: as written, else
/// harness's default ("" where there is none).
pub fn getValue(a: std.mem.Allocator, text: []const u8, k: Key) !Result {
    if (!known(k)) return .{ .refused = try std.fmt.allocPrint(a, "config.ini has no setting {s}.{s}", .{ k.section, k.key }) };
    if (try core.parseProblem(a, "config.ini", text, config.parse)) |why| return .{ .refused = why };
    var found: ?[]const u8 = null;
    var in = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (try headerSection(a, line)) |sec| {
            in = std.mem.eql(u8, sec, k.section);
            continue;
        }
        if (!in) continue;
        const body = std.mem.trim(u8, config.stripComment(line), " \t\r");
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, body[0..eq], " \t"), k.key)) found = std.mem.trim(u8, body[eq + 1 ..], " \t");
    }
    if (found) |v| return .{ .value = v };
    if (providerName(k.section) != null) return .{ .value = "" };
    const d: config.Config = .{};
    const ci = @typeInfo(config.Config).@"struct";
    inline for (ci.field_names, ci.field_types) |sname, ST| {
        if (comptime @typeInfo(ST) == .@"struct") if (std.mem.eql(u8, k.section, sname)) {
            inline for (@typeInfo(ST).@"struct".field_names) |fname| if (std.mem.eql(u8, k.key, fname))
                return .{ .value = try shown(a, fname, @field(@field(d, sname), fname)) };
        };
    }
    return .{ .value = "" };
}

/// A default as config.ini writes it.
fn shown(a: std.mem.Allocator, comptime name: []const u8, v: anytype) ![]const u8 {
    const T = @TypeOf(v);
    if (T == []const u8) return v;
    if (T == bool) return if (v) "on" else "off";
    if (T == u32 or T == f64) return std.fmt.allocPrint(a, "{d}", .{v});
    if (T == i32) {
        // utc_offset
        const m: u32 = @abs(v);
        return std.fmt.allocPrint(a, "{s}{d:0>2}:{d:0>2}", .{ if (v < 0) "-" else "+", m / 60, m % 60 });
    }
    if (T == u16) return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ v / 60, v % 60 });
    if (T == config.Quiet) {
        var buf: [16]u8 = undefined;
        return a.dupe(u8, config.formatQuiet(&buf, v));
    }
    if (@typeInfo(T) == .optional) return if (v) |inner| shown(a, name, inner) else "off";
    return "";
}

/// Whether a running harness takes the change only at its next start
/// (the rest: at /reload).
pub fn needsRestart(k: Key) bool {
    const restart = [_][2][]const u8{ .{ "chat", "telegram" }, .{ "chat", "token" }, .{ "apps", "on" }, .{ "apps", "port" } };
    for (restart) |r| if (std.mem.eql(u8, k.section, r[0]) and std.mem.eql(u8, k.key, r[1])) return true;
    return false;
}

const t = std.testing;

test "set_keeps_comments_and_order" {
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const text = "; my notes\n[model]\nurl = https://a.example ; the gateway\nmodel = claude-sonnet\n\n[chat]\ntelegram = on\n";
    const k = parseKey(x, &.{"model.url"}).?;
    const r = try setText(x, text, k, "https://b.example");
    try t.expectEqualStrings("; my notes\n[model]\nurl = https://b.example ; the gateway\nmodel = claude-sonnet\n\n[chat]\ntelegram = on\n", r.text.?);
    // a key the section doesn't have yet: under it; a section not there: at the end
    try t.expectEqualStrings("; my notes\n[model]\nurl = https://a.example ; the gateway\nmodel = claude-sonnet\nmax_tokens = 8000\n\n[chat]\ntelegram = on\n", (try setText(x, text, parseKey(x, &.{"model.max_tokens"}).?, "8000")).text.?);
    try t.expectEqualStrings("; my notes\n[model]\nurl = https://a.example ; the gateway\nmodel = claude-sonnet\n\n[chat]\ntelegram = on\n\n[desk]\nspeak = browser\n", (try setText(x, text, parseKey(x, &.{"desk.speak"}).?, "browser")).text.?);
    // a \r\n file stays one
    try t.expectEqualStrings("[chat]\r\nutc_offset = auto\r\n", (try setText(x, "[chat]\r\nutc_offset = +01:00\r\n", parseKey(x, &.{"chat.utc_offset"}).?, "auto")).text.?);
    // a key written twice: the one in use is the one changed
    try t.expectEqualStrings("[chat]\nutc_offset = +01:00\nutc_offset = +02:00\n", (try setText(x, "[chat]\nutc_offset = +01:00\nutc_offset = -03:00\n", parseKey(x, &.{"chat.utc_offset"}).?, "+02:00")).text.?);
}

test "a_named_section_is_one_argument_or_two" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const one = parseKey(x, &.{"provider local.url"}).?;
    try t.expectEqualStrings("provider local", one.section);
    try t.expectEqualStrings("url", one.key);
    const two = parseKey(x, &.{ "provider", "local.url" }).?;
    try t.expectEqualStrings("provider local", two.section);
    try t.expectEqualStrings("url", two.key);
    try t.expect(parseKey(x, &.{"model"}) == null);
    try t.expect(parseKey(x, &.{".url"}) == null);
    try t.expect(parseKey(x, &.{"model."}) == null);
    try t.expect(parseKey(x, &.{ "model.url", "x" }) == null);
    try t.expectEqualStrings("provider local", parseKey(x, &.{"provider   local.url"}).?.section);
    const text = "[model]\nprovider = local\nmodel = gpt\n\n[provider local]\napi = openai\nurl = https://a.example/v1\n";
    try t.expectEqualStrings("[model]\nprovider = local\nmodel = gpt\n\n[provider local]\napi = openai\nurl = https://b.example/v1\n", (try setText(x, text, one, "https://b.example/v1")).text.?);
    try t.expectEqualStrings("https://a.example/v1", (try getValue(x, text, two)).value.?);
}

test "a_change_that_does_not_parse_is_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const text = "[chat]\nutc_offset = +01:00\n";
    const bad = try setText(x, text, parseKey(x, &.{"chat.utc_offset"}).?, "5");
    try t.expect(bad.text == null);
    try t.expectEqualStrings("Not changed: config.ini line 2 has an error: utc_offset = 5", bad.refused.?);
    try t.expectEqualStrings("config.ini has no setting chat.colour", (try setText(x, text, parseKey(x, &.{"chat.colour"}).?, "red")).refused.?);
    try t.expectEqualStrings("config.ini has no setting garden.size", (try setText(x, text, parseKey(x, &.{"garden.size"}).?, "3")).refused.?);
    try t.expectEqualStrings("config.ini has no setting provider local.colour", (try setText(x, text, parseKey(x, &.{"provider local.colour"}).?, "red")).refused.?);
    // a value of several lines, or one config.ini would cut at a comment
    try t.expect((try setText(x, text, parseKey(x, &.{"model.model"}).?, "a\n[chat]")).refused != null);
    try t.expect((try setText(x, text, parseKey(x, &.{"model.model"}).?, "a ; b")).refused != null);
    // an unknown provider named: refused with why
    try t.expect(std.mem.indexOf(u8, (try setText(x, text, parseKey(x, &.{"model.provider"}).?, "nobody")).refused.?, "no provider has that name") != null);
    // a setting that names a secret takes a name, never the secret
    try t.expectEqualStrings("model.key takes a stored secret's name (a-z, 0-9, - and _); store the key itself with harness secret add NAME", (try setText(x, text, parseKey(x, &.{"model.key"}).?, "sk-ant-api03-AbCdEf0123456789")).refused.?);
    try t.expect((try setText(x, text, parseKey(x, &.{"model.key"}).?, "anthropic")).text != null);
    try t.expect((try setText(x, text, parseKey(x, &.{"provider local.key"}).?, "Bearer XYZ")).refused != null);
}

test "get_prints_the_value_in_use" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const text = "[model]\nmodel = claude-opus ; mine\n[chat]\nutc_offset = auto\ntelegram = off\n";
    try t.expectEqualStrings("claude-opus", (try getValue(x, text, parseKey(x, &.{"model.model"}).?)).value.?);
    try t.expectEqualStrings("auto", (try getValue(x, text, parseKey(x, &.{"chat.utc_offset"}).?)).value.?);
    try t.expectEqualStrings("off", (try getValue(x, text, parseKey(x, &.{"chat.telegram"}).?)).value.?);
    // not written: harness's default
    try t.expectEqualStrings("4096", (try getValue(x, text, parseKey(x, &.{"model.max_tokens"}).?)).value.?);
    try t.expectEqualStrings("omnigate", (try getValue(x, text, parseKey(x, &.{"model.provider"}).?)).value.?);
    try t.expectEqualStrings("on", (try getValue(x, text, parseKey(x, &.{"apps.on"}).?)).value.?);
    try t.expectEqualStrings("+00:00", (try getValue(x, "", parseKey(x, &.{"chat.utc_offset"}).?)).value.?);
    try t.expectEqualStrings("off", (try getValue(x, "", parseKey(x, &.{"butler.quiet"}).?)).value.?);
    try t.expectEqualStrings("", (try getValue(x, "", parseKey(x, &.{"model.url"}).?)).value.?);
    try t.expectEqualStrings("config.ini has no setting model.colour", (try getValue(x, text, parseKey(x, &.{"model.colour"}).?)).refused.?);
    try t.expect((try getValue(x, "[chat]\nutc_offset = 5\n", parseKey(x, &.{"chat.telegram"}).?)).refused != null);
}

test "a_running_harness_needs_reload_or_restart" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    try t.expect(!needsRestart(parseKey(x, &.{"model.model"}).?));
    try t.expect(needsRestart(parseKey(x, &.{"chat.telegram"}).?));
    try t.expect(needsRestart(parseKey(x, &.{"chat.token"}).?));
    try t.expect(needsRestart(parseKey(x, &.{"apps.port"}).?));
    try t.expect(!needsRestart(parseKey(x, &.{"chat.utc_offset"}).?));
}

test "several_settings_go_in_at_once_and_are_parsed_together" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    // a provider of one's own needs api and url together: neither alone parses
    const pairs = parsePairs(x, &.{ "provider", "other.api", "openai", "provider other.url", "https://llm.example/v1", "model.provider", "other" }).?;
    try t.expectEqual(3, pairs.len);
    try t.expectEqualStrings("provider other", pairs[1].key.section);
    try t.expectEqualStrings("https://llm.example/v1", pairs[1].value);
    const text = "[model]\nmodel = gpt-x\n";
    try t.expect((try setText(x, text, pairs[0].key, pairs[0].value)).refused != null);
    const all = try setAll(x, text, pairs);
    try t.expectEqualStrings("[model]\nmodel = gpt-x\nprovider = other\n\n[provider other]\napi = openai\nurl = https://llm.example/v1\n", all.text.?);
    // one refused: none written
    try t.expect((try setAll(x, text, parsePairs(x, &.{ "model.model", "gpt-y", "chat.utc_offset", "5" }).?)).text == null);
    // a key without its value, or nothing
    try t.expect(parsePairs(x, &.{"model.model"}) == null);
    try t.expect(parsePairs(x, &.{ "model.model", "a", "model.url" }) == null);
    try t.expect(parsePairs(x, &.{}) == null);
    try t.expect(parsePairs(x, &.{ "provider", "x" }) == null);
}

test "a_value_harness_would_refuse_at_start_is_refused_now" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    try t.expectEqualStrings("Not changed: model.url takes an http:// or https:// address", (try setText(x, "", parseKey(x, &.{"model.url"}).?, "notaurl")).refused.?);
    try t.expect((try setText(x, "", parseKey(x, &.{"search.url"}).?, "ftp://x.example")).refused != null);
    try t.expect((try setText(x, "", parseKey(x, &.{"chat.api"}).?, "api.telegram.org")).refused != null);
    try t.expectEqualStrings("Not changed: apps.port is a port, 0 to 65535", (try setText(x, "", parseKey(x, &.{"apps.port"}).?, "70000")).refused.?);
    try t.expect((try setText(x, "", parseKey(x, &.{"model.url"}).?, "https://og.example")).text != null);
    try t.expect((try setText(x, "", parseKey(x, &.{"apps.port"}).?, "8642")).text != null);
    // a file broken already elsewhere doesn't stop another change
    try t.expect((try setText(x, "[search]\nurl = nope\n", parseKey(x, &.{"model.model"}).?, "gpt")).text != null);
}

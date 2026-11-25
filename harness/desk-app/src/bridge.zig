//! The messages the page sends the app, one way: `{"badge": N}`,
//! `{"attention": "urgent"}`, `{"reenter": true}`, and from the app's own
//! "harness isn't running" page `{"start": true}`, and from its "Set up"
//! page `{"setup": {provider, model, url, api, replace}}` and `{"cancel": true}`. Through
//! `window.webkit.messageHandlers.harness.postMessage(…)`, an object or its JSON
//! text.
const std = @import("std");

const policy = @import("policy.zig");
const setup = @import("setup.zig");

pub const Message = struct {
    badge: ?u32 = null,
    attention: bool = false,
    reenter: bool = false,
    start: bool = false,
    /// The "Set up" page's [Continue]: the form as typed (never a key).
    setup: ?setup.Form = null,
    /// Its [Cancel].
    cancel: bool = false,
};

pub const max_badge = 99999;

/// The message in `json`, or null when it says nothing the app knows. The
/// form's strings are copied into `a` (an arena is expected).
pub fn parse(a: std.mem.Allocator, json: []const u8) ?Message {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    var m: Message = .{};
    var any = false;
    if (obj.get("badge")) |v| if (v == .integer and v.integer >= 0) {
        m.badge = @intCast(@min(v.integer, max_badge));
        any = true;
    };
    if (obj.get("attention")) |v| if (v == .string and std.mem.eql(u8, v.string, "urgent")) {
        m.attention = true;
        any = true;
    };
    if (obj.get("reenter")) |v| if (v == .bool and v.bool) {
        m.reenter = true;
        any = true;
    };
    if (obj.get("start")) |v| if (v == .bool and v.bool) {
        m.start = true;
        any = true;
    };
    if (obj.get("cancel")) |v| if (v == .bool and v.bool) {
        m.cancel = true;
        any = true;
    };
    if (obj.get("setup")) |v| if (formOf(a, v)) |f| {
        m.setup = f;
        any = true;
    };
    return if (any) m else null;
}

/// The longest Model or Address taken (more is no form of ours).
const max_field = 2048;

/// The form in `v`, its strings copied into `a`; null when it isn't one.
/// Only its own fields are read: anything else in it is left behind.
fn formOf(a: std.mem.Allocator, v: std.json.Value) ?setup.Form {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var f: setup.Form = .{};
    f.provider = switch (o.get("provider") orelse return null) {
        .string => |s| std.meta.stringToEnum(setup.Provider, s) orelse return null,
        else => return null,
    };
    inline for (.{ "model", "url" }) |name| if (o.get(name)) |x| switch (x) {
        .string => |s| {
            if (s.len > max_field) return null;
            @field(f, name) = a.dupe(u8, s) catch return null;
        },
        else => return null,
    };
    if (o.get("api")) |x| f.api = switch (x) {
        .string => |s| std.meta.stringToEnum(setup.Api, s) orelse return null,
        else => return null,
    };
    if (o.get("replace")) |x| f.replace = switch (x) {
        .bool => |b| b,
        else => return null,
    };
    return f;
}

pub const Source = enum { desk, builtin, other };

/// Who sent a message: the desk page (the main frame on harness's origin),
/// the app's own built-in page (the main frame, not on the web, while one is
/// shown), or anything else (a framed app, a page that shouldn't be there).
pub fn source(main_frame: bool, proto: []const u8, host: []const u8, origin_port: u16, port: ?u16, showing_builtin: bool) Source {
    if (!main_frame) return .other;
    if (policy.isHarnessOrigin(proto, host, origin_port, port)) return .desk;
    const web = std.ascii.eqlIgnoreCase(proto, "http") or std.ascii.eqlIgnoreCase(proto, "https");
    if (showing_builtin and !web) return .builtin;
    return .other;
}

const t = std.testing;

test "messages_parse" {
    const a = t.allocator;
    try t.expectEqual(@as(?u32, 3), parse(a, "{\"badge\": 3}").?.badge);
    try t.expectEqual(@as(?u32, 0), parse(a, "{\"badge\":0}").?.badge);
    try t.expectEqual(@as(?u32, 99999), parse(a, "{\"badge\": 1000000}").?.badge);
    try t.expect(parse(a, "{\"attention\": \"urgent\"}").?.attention);
    try t.expect(parse(a, "{\"reenter\": true}").?.reenter);
    try t.expect(parse(a, "{\"start\": true}").?.start);
    const both = parse(a, "{\"badge\": 2, \"attention\": \"urgent\", \"other\": 1}").?;
    try t.expectEqual(@as(?u32, 2), both.badge);
    try t.expect(both.attention and !both.reenter and !both.start);
}

test "setup_and_cancel_parse" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = parse(a, "{\"setup\": {\"provider\": \"other\", \"model\": \" m1 \", \"url\": \"http://127.0.0.1:8080/v1\", \"api\": \"anthropic\", \"replace\": true}}").?;
    const f = m.setup.?;
    try t.expectEqual(setup.Provider.other, f.provider);
    try t.expectEqualStrings(" m1 ", f.model);
    try t.expectEqualStrings("http://127.0.0.1:8080/v1", f.url);
    try t.expectEqual(setup.Api.anthropic, f.api);
    try t.expect(f.replace);
    // missing fields: the defaults; a provider or format it doesn't know: nothing
    const min = parse(a, "{\"setup\": {\"provider\": \"openai\"}}").?.setup.?;
    try t.expectEqualStrings("", min.model);
    try t.expect(!min.replace);
    try t.expect(parse(a, "{\"setup\": {\"provider\": \"gemini\", \"model\": \"m\"}}") == null);
    try t.expect(parse(a, "{\"setup\": {\"provider\": \"other\", \"api\": \"gemini\"}}") == null);
    try t.expect(parse(a, "{\"setup\": {\"provider\": \"openai\", \"model\": 3}}") == null);
    try t.expect(parse(a, "{\"setup\": \"anthropic\"}") == null);
    try t.expect(parse(a, "{\"cancel\": true}").?.cancel);
    try t.expect(parse(a, "{\"cancel\": 1}") == null);
}

test "a_key_field_in_a_message_is_ignored" {
    // the page never holds the key; a message that brings one doesn't pass it on
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = parse(a, "{\"setup\": {\"provider\": \"anthropic\", \"model\": \"claude-opus-4-8\", \"key\": \"sk-test-not-a-key\"}, \"key\": \"sk-test-not-a-key\"}").?;
    const f = m.setup.?;
    inline for (@typeInfo(setup.Form).@"struct".field_names) |name| {
        const v = @field(f, name);
        if (@TypeOf(v) == []const u8) try t.expect(std.mem.indexOf(u8, v, "sk-test") == null);
    }
    try t.expect(parse(a, "{\"key\": \"sk-test-not-a-key\"}") == null);
}

test "wrong_shapes_are_nothing" {
    const a = t.allocator;
    for ([_][]const u8{
        "{\"badge\": -1}",
        "{\"badge\": 2.5}",
        "{\"badge\": \"3\"}",
        "{\"attention\": \"low\"}",
        "{\"attention\": true}",
        "{\"reenter\": false}",
        "{\"reenter\": \"yes\"}",
        "{\"start\": 1}",
        "{}",
        "3",
        "[]",
        "null",
        "not json",
        "",
    }) |json| {
        try t.expect(parse(a, json) == null);
    }
}

test "sources" {
    // the desk page: the main frame on harness's origin
    try t.expectEqual(Source.desk, source(true, "http", "127.0.0.1", 41234, 41234, false));
    try t.expectEqual(Source.desk, source(true, "http", "127.0.0.1", 41234, 41234, true));
    // a framed app, even on the same origin
    try t.expectEqual(Source.other, source(false, "http", "127.0.0.1", 41234, 41234, false));
    try t.expectEqual(Source.other, source(false, "", "", 0, 41234, true));
    // the app's own page, shown from a string
    try t.expectEqual(Source.builtin, source(true, "", "", 0, 41234, true));
    try t.expectEqual(Source.builtin, source(true, "about", "", 0, null, true));
    try t.expectEqual(Source.other, source(true, "", "", 0, 41234, false));
    // anything on the web is neither
    try t.expectEqual(Source.other, source(true, "https", "example.com", 443, 41234, true));
    try t.expectEqual(Source.other, source(true, "http", "127.0.0.1", 41235, 41234, true));
}

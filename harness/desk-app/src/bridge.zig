//! The messages the page sends the app, one way: `{"badge": N}`,
//! `{"attention": "urgent"}`, `{"reenter": true}`, and from the app's own
//! "harness isn't running" page `{"start": true}`. Through
//! `window.webkit.messageHandlers.desk.postMessage(…)`, an object or its JSON
//! text.
const std = @import("std");

const policy = @import("policy.zig");

pub const Message = struct {
    badge: ?u32 = null,
    attention: bool = false,
    reenter: bool = false,
    start: bool = false,
};

pub const max_badge = 99999;

/// The message in `json`, or null when it says nothing the app knows.
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
    return if (any) m else null;
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

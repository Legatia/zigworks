//! Reading JSON whose shape isn't trusted: every lookup answers null instead
//! of failing when the value is missing or of another kind.
const std = @import("std");
pub const Value = std.json.Value;

/// Parses `bytes`; everything is allocated in `arena`. Null when it isn't JSON.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always }) catch null;
}

/// The field `key` of an object; null for JSON null too.
pub fn get(v: ?Value, key: []const u8) ?Value {
    const val = v orelse return null;
    if (val != .object) return null;
    const f = val.object.get(key) orelse return null;
    return if (f == .null) null else f;
}

/// Follows object fields and, for a key made of digits, array positions.
pub fn at(v: ?Value, keys: []const []const u8) ?Value {
    var cur = v;
    for (keys) |k| {
        const c = cur orelse return null;
        if (c == .array) {
            const i = std.fmt.parseInt(usize, k, 10) catch return null;
            if (i >= c.array.items.len) return null;
            cur = c.array.items[i];
            if (cur.? == .null) return null;
        } else cur = get(c, k);
    }
    return cur;
}

pub fn str(v: ?Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

pub fn num(v: ?Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn int(v: ?Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (f == @floor(f) and @abs(f) < 9e15) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn boolean(v: ?Value) ?bool {
    const val = v orelse return null;
    return if (val == .bool) val.bool else null;
}

pub fn arr(v: ?Value) ?[]Value {
    const val = v orelse return null;
    return if (val == .array) val.array.items else null;
}

const testing = std.testing;

test "lookups_in_json_of_any_shape_answer_null_instead_of_failing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = parse(arena, "{\"a\":{\"b\":[{\"c\":\"x\"},null,3]},\"n\":2.0,\"z\":null}").?;
    try testing.expectEqualStrings("x", str(at(v, &.{ "a", "b", "0", "c" })).?);
    try testing.expect(at(v, &.{ "a", "b", "1" }) == null);
    try testing.expectEqual(@as(i64, 3), int(at(v, &.{ "a", "b", "2" })).?);
    try testing.expect(at(v, &.{ "a", "b", "9" }) == null);
    try testing.expect(at(v, &.{ "a", "x", "c" }) == null);
    try testing.expectEqual(@as(i64, 2), int(get(v, "n")).?);
    try testing.expect(get(v, "z") == null);
    try testing.expect(str(get(v, "n")) == null);
    try testing.expect(parse(arena, "not json") == null);
}

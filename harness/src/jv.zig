//! Reading JSON whose shape isn't trusted: every lookup answers null instead
//! of failing when the value is missing or of another kind.
const std = @import("std");
pub const Value = std.json.Value;
const util = @import("util.zig");

/// Parses `bytes`; everything is allocated in `arena`. Null when it isn't JSON.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always }) catch null;
}

/// `bytes` as one JSON text, the same however it was written: object keys
/// sorted (bytewise), no spaces, numbers as written. Null when it isn't
/// JSON, or an object holds a key twice (one reader could take the first
/// and another the last).
pub fn canonical(arena: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always, .parse_numbers = false, .duplicate_field_behavior = .@"error" }) catch return null;
    var out: std.ArrayList(u8) = .empty;
    writeCanonical(&out, arena, v) catch return null;
    return out.items;
}

fn writeCanonical(out: *std.ArrayList(u8), a: std.mem.Allocator, v: Value) !void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |n| try out.print(a, "{d}", .{n}),
        .float => |x| try out.print(a, "{d}", .{x}),
        .number_string => |n| try out.appendSlice(a, n),
        .string => |str_v| try util.jsonString(out, a, str_v),
        .array => |list| {
            try out.append(a, '[');
            for (list.items, 0..) |x, i| {
                if (i > 0) try out.append(a, ',');
                try writeCanonical(out, a, x);
            }
            try out.append(a, ']');
        },
        .object => |obj| {
            const keys = try a.alloc([]const u8, obj.count());
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.less);
            try out.append(a, '{');
            for (keys, 0..) |k, j| {
                if (j > 0) try out.append(a, ',');
                try util.jsonString(out, a, k);
                try out.append(a, ':');
                try writeCanonical(out, a, obj.get(k).?);
            }
            try out.append(a, '}');
        },
    }
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

test "canonical_sorts_keys_drops_spaces_keeps_numbers_and_refuses_a_field_twice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("{\"a\":[1.50,{\"x\":true,\"y\":null}],\"b\":\"q\\\"r\"}", canonical(a, " { \"b\" : \"q\\\"r\" , \"a\": [1.50, {\"y\": null, \"x\": true}] } ").?);
    try std.testing.expectEqual(null, canonical(a, "{\"text\":\"hi\",\"text\":\"lock\"}"));
    try std.testing.expectEqual(null, canonical(a, "{\"a\":{\"k\":1,\"k\":2}}"));
    try std.testing.expectEqual(null, canonical(a, "not json"));
    try std.testing.expectEqualStrings("{}", canonical(a, "{}").?);
}

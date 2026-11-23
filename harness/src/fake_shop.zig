//! `harness-fake --mcp --shop`: a shop's MCP server on stdio, for the
//! reorder tests. `shop_quote` prices `items` (5.00 PLN each; one with
//! "oat" in it is not found), or answers the file `quote.json` of its
//! folder when there is one; `shop_order` writes its input as a line of
//! `orders.jsonl` and says the order was placed, refusing a `total` under
//! what the items cost. Its folder is where it starts (state/mcp/NAME).
const std = @import("std");
const Io = std.Io;

const tools_json =
    \\{"tools":[{"name":"shop_quote","description":"Price a basket: each item's product and price, the total and the delivery. Only reads.","inputSchema":{"type":"object","properties":{"items":{"type":"array","items":{"type":"string"}}},"required":["items"]},"annotations":{"readOnlyHint":true}},{"name":"shop_order","description":"Order the items, paying at most total.","inputSchema":{"type":"object","properties":{"items":{"type":"array","items":{"type":"string"}},"total":{"type":"number"}},"required":["items","total"]}}]}
;

pub const delivery = "Sat 28 Nov, 10:00–12:00";

fn found(item: []const u8) bool {
    return std.ascii.findIgnoreCase(item, "oat") == null;
}

fn itemsOf(args: ?std.json.Value) []const std.json.Value {
    const x = args orelse return &.{};
    if (x != .object) return &.{};
    const v = x.object.get("items") orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

fn textResult(a: std.mem.Allocator, text: []const u8, is_error: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":{}}}", .{ std.json.fmt(text, .{}), is_error });
}

fn fileOf(io: Io, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, name, a, .limited(1 << 20)) catch null;
}

fn call(io: Io, a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    const params = v.object.get("params") orelse return textResult(a, "no params", true);
    if (params != .object) return textResult(a, "bad params", true);
    const name_v = params.object.get("name") orelse return textResult(a, "no name", true);
    const name = if (name_v == .string) name_v.string else "";
    const args = params.object.get("arguments");
    const items = itemsOf(args);
    if (std.mem.eql(u8, name, "shop_quote")) {
        if (fileOf(io, a, "quote.json")) |q| return textResult(a, q, false);
        var o: std.ArrayList(u8) = .empty;
        var n: usize = 0;
        try o.appendSlice(a, "{\"lines\":[");
        for (items) |it| {
            if (it != .string or !found(it.string)) continue;
            if (n > 0) try o.append(a, ',');
            try o.print(a, "{{\"item\":{f},\"product\":{f},\"price\":5.00}}", .{ std.json.fmt(it.string, .{}), std.json.fmt(try std.fmt.allocPrint(a, "{s} (Shop's own)", .{it.string}), .{}) });
            n += 1;
        }
        try o.appendSlice(a, "],\"missing\":[");
        var m: usize = 0;
        for (items) |it| {
            if (it != .string or found(it.string)) continue;
            if (m > 0) try o.append(a, ',');
            try o.print(a, "{f}", .{std.json.fmt(it.string, .{})});
            m += 1;
        }
        try o.print(a, "],\"total\":{d}.00,\"currency\":\"PLN\",\"delivery\":\"{s}\"}}", .{ n * 5, delivery });
        return textResult(a, o.items, false);
    }
    if (std.mem.eql(u8, name, "shop_order")) {
        const total: f64 = blk: {
            const x = args orelse break :blk 0;
            if (x != .object) break :blk 0;
            const tv = x.object.get("total") orelse break :blk 0;
            break :blk switch (tv) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => 0,
            };
        };
        var cost: f64 = 0;
        for (items) |it| if (it == .string and found(it.string)) {
            cost += 5;
        };
        if (items.len == 0) return textResult(a, "nothing to order", true);
        if (total + 0.001 < cost) return textResult(a, try std.fmt.allocPrint(a, "the basket costs {d:.2} PLN, more than the {d:.2} allowed: not ordered", .{ cost, total }), true);
        const line = try std.json.Stringify.valueAlloc(a, args.?, .{});
        const old = fileOf(io, a, "orders.jsonl") orelse "";
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = "orders.jsonl", .data = try std.fmt.allocPrint(a, "{s}{s}\n", .{ old, line }) });
        return textResult(a, try std.fmt.allocPrint(a, "Order 4471 placed: {d:.2} PLN, delivery {s}.", .{ cost, delivery }), false);
    }
    return textResult(a, "unknown tool", true);
}

fn send(io: Io, line: []const u8) void {
    const out = Io.File.stdout();
    out.writeStreamingAll(io, line) catch {};
    out.writeStreamingAll(io, "\n") catch {};
}

/// The shop on stdio, until stdin ends.
pub fn run(io: Io, gpa: std.mem.Allocator) u8 {
    var buf: [1 << 16]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    while (true) {
        const line = (r.interface.takeDelimiter('\n') catch return 1) orelse return 0;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (v != .object) continue;
        const idv = v.object.get("id") orelse continue;
        const method = if (v.object.get("method")) |m| (if (m == .string) m.string else "") else continue;
        const id_json = std.json.Stringify.valueAlloc(a, idv, .{}) catch return 1;
        const result: []const u8 = if (std.mem.eql(u8, method, "initialize"))
            "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"shop\",\"version\":\"1\"}}"
        else if (std.mem.eql(u8, method, "tools/list"))
            tools_json
        else if (std.mem.eql(u8, method, "tools/call"))
            call(io, a, v) catch return 1
        else
            "{}";
        send(io, std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result }) catch return 1);
    }
}

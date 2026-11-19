//! The Telegram Bot API: long polling for messages and button presses,
//! sending text (split at Telegram's 4,096 characters) and buttons.
const std = @import("std");
const http = @import("http.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const max_text = 4096;

pub const Update = union(enum) {
    message: struct { update_id: i64, from_id: i64, chat_id: i64, text: []const u8 },
    callback: struct { update_id: i64, id: []const u8, from_id: i64, chat_id: i64, message_id: i64, data: []const u8 },

    pub fn updateId(u: Update) i64 {
        return switch (u) {
            inline else => |x| x.update_id,
        };
    }
};

pub const Bot = struct {
    gpa: std.mem.Allocator,
    io: Io,
    http: http.Client,
    token: []const u8,
    mutex: Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: Io, api: []const u8, token: []const u8) !Bot {
        return .{ .gpa = gpa, .io = io, .http = .init(gpa, io, try http.Target.parse(api)), .token = token };
    }

    pub fn deinit(b: *Bot) void {
        b.http.deinit();
    }

    /// One Bot API call; returns the `result` value (in `arena`).
    fn call(b: *Bot, arena: std.mem.Allocator, method: []const u8, body: []const u8, idle_ms: u32) !?jv.Value {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const path = try std.fmt.allocPrint(arena, "/bot{s}/{s}", .{ b.token, method });
        var resp = try b.http.send(.{ .path = path, .body = body, .limits = .{ .idle_ms = idle_ms, .total_ms = idle_ms + 30_000 } });
        defer resp.deinit();
        const got = try resp.readAll(arena, 8 << 20);
        const v = jv.parse(arena, got) orelse return error.BadReply;
        if (!(jv.boolean(jv.get(v, "ok")) orelse false)) return error.TelegramRefused;
        return jv.get(v, "result");
    }

    pub fn getUpdates(b: *Bot, arena: std.mem.Allocator, offset: i64, timeout_s: u32) ![]Update {
        const body = try std.fmt.allocPrint(arena, "{{\"offset\":{d},\"timeout\":{d},\"allowed_updates\":[\"message\",\"callback_query\"]}}", .{ offset, timeout_s });
        const res = try b.call(arena, "getUpdates", body, (timeout_s + 20) * 1000);
        var out: std.ArrayList(Update) = .empty;
        for (jv.arr(res) orelse &.{}) |u| {
            const id = jv.int(jv.get(u, "update_id")) orelse continue;
            if (jv.get(u, "message")) |m| {
                try out.append(arena, .{ .message = .{
                    .update_id = id,
                    .from_id = jv.int(jv.at(m, &.{ "from", "id" })) orelse 0,
                    .chat_id = jv.int(jv.at(m, &.{ "chat", "id" })) orelse 0,
                    .text = jv.str(jv.get(m, "text")) orelse "",
                } });
            } else if (jv.get(u, "callback_query")) |c| {
                try out.append(arena, .{ .callback = .{
                    .update_id = id,
                    .id = jv.str(jv.get(c, "id")) orelse "",
                    .from_id = jv.int(jv.at(c, &.{ "from", "id" })) orelse 0,
                    .chat_id = jv.int(jv.at(c, &.{ "message", "chat", "id" })) orelse 0,
                    .message_id = jv.int(jv.at(c, &.{ "message", "message_id" })) orelse 0,
                    .data = jv.str(jv.get(c, "data")) orelse "",
                } });
            } else {
                // something else: still advance past it
                try out.append(arena, .{ .message = .{ .update_id = id, .from_id = 0, .chat_id = 0, .text = "" } });
            }
        }
        return out.items;
    }

    /// Sends `text`, split into parts of at most 4,096 bytes at line breaks.
    pub fn send(b: *Bot, chat_id: i64, text: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        for (try split(a, if (text.len > 0) text else "(empty)", max_text)) |part| {
            var body: std.ArrayList(u8) = .empty;
            try body.print(a, "{{\"chat_id\":{d},\"text\":", .{chat_id});
            try util.jsonString(&body, a, part);
            try body.appendSlice(a, ",\"link_preview_options\":{\"is_disabled\":true}}");
            _ = try b.call(a, "sendMessage", body.items, 30_000);
        }
    }

    /// Sends `text` with one row of buttons (label, data); returns the
    /// message id.
    pub fn sendButtons(b: *Bot, chat_id: i64, text: []const u8, buttons: []const [2][]const u8) !i64 {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        try body.print(a, "{{\"chat_id\":{d},\"text\":", .{chat_id});
        try util.jsonString(&body, a, util.cut(text, max_text));
        try body.appendSlice(a, ",\"reply_markup\":{\"inline_keyboard\":[[");
        for (buttons, 0..) |btn, i| {
            if (i > 0) try body.append(a, ',');
            try body.appendSlice(a, "{\"text\":");
            try util.jsonString(&body, a, btn[0]);
            try body.appendSlice(a, ",\"callback_data\":");
            try util.jsonString(&body, a, btn[1]);
            try body.append(a, '}');
        }
        try body.appendSlice(a, "]]}}");
        const res = try b.call(a, "sendMessage", body.items, 30_000);
        return jv.int(jv.get(res, "message_id")) orelse 0;
    }

    pub fn answer(b: *Bot, callback_id: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, "{\"callback_query_id\":");
        try util.jsonString(&body, a, callback_id);
        try body.append(a, '}');
        _ = try b.call(a, "answerCallbackQuery", body.items, 30_000);
    }

    /// Removes the buttons under a message once it has been answered.
    pub fn clearButtons(b: *Bot, chat_id: i64, message_id: i64) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try std.fmt.allocPrint(a, "{{\"chat_id\":{d},\"message_id\":{d},\"reply_markup\":{{\"inline_keyboard\":[]}}}}", .{ chat_id, message_id });
        _ = try b.call(a, "editMessageReplyMarkup", body, 30_000);
    }
};

/// Parts of at most `max` bytes, cut after the last line break that fits,
/// else at a UTF-8 boundary.
pub fn split(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = text;
    while (rest.len > max) {
        var cut = std.mem.lastIndexOfScalar(u8, rest[0..max], '\n') orelse 0;
        if (cut == 0) cut = util.cut(rest, max).len else cut += 1;
        try out.append(arena, rest[0..cut]);
        rest = rest[cut..];
    }
    if (rest.len > 0) try out.append(arena, rest);
    return out.items;
}

/// The next update id to ask for, kept across restarts.
pub const Offset = struct {
    pub fn load(io: Io, path: []const u8) i64 {
        var buf: [32]u8 = undefined;
        const got = Io.Dir.cwd().readFile(io, path, &buf) catch return 0;
        return std.fmt.parseInt(i64, std.mem.trim(u8, got, " \n"), 10) catch 0;
    }

    pub fn save(io: Io, path: []const u8, offset: i64) !void {
        var buf: [32]u8 = undefined;
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.fmt.bufPrint(&buf, "{d}\n", .{offset}) });
    }
};

// ---- tests ----

const t = std.testing;
const model = @import("model.zig");

pub fn inbox(e: *model.TestEnv, n: u32, update_json: []const u8) !void {
    const name = try std.fmt.allocPrint(e.arena.allocator(), "telegram/in/{d:0>3}.json", .{n});
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = update_json });
}

pub fn outbox(e: *model.TestEnv) ![]u8 {
    return e.tmp.dir.readFileAlloc(t.io, "telegram/out.jsonl", e.arena.allocator(), .unlimited) catch |err| switch (err) {
        error.FileNotFound => e.arena.allocator().dupe(u8, ""),
        else => err,
    };
}

test "updates_parsed_messages_and_callbacks" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try inbox(&e, 1, "{\"message\":{\"message_id\":5,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"text\":\"hello\"}}");
    try inbox(&e, 2, "{\"callback_query\":{\"id\":\"cb1\",\"from\":{\"id\":42},\"message\":{\"message_id\":7,\"chat\":{\"id\":42}},\"data\":\"a:once\"}}");
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const ups = try b.getUpdates(e.arena.allocator(), 0, 0);
    try t.expectEqual(2, ups.len);
    try t.expectEqual(42, ups[0].message.from_id);
    try t.expectEqualStrings("hello", ups[0].message.text);
    try t.expectEqualStrings("cb1", ups[1].callback.id);
    try t.expectEqualStrings("a:once", ups[1].callback.data);
    try t.expectEqual(7, ups[1].callback.message_id);
    try t.expectEqual(2, ups[1].updateId());
}

test "long_text_split_at_4096_on_line_breaks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..300) |i| try text.print(a, "line number {d} of the brief\n", .{i});
    const parts = try split(a, text.items, max_text);
    try t.expect(parts.len >= 2);
    var total: usize = 0;
    for (parts) |p| {
        try t.expect(p.len <= max_text);
        try t.expect(p[p.len - 1] == '\n');
        total += p.len;
    }
    try t.expectEqual(text.items.len, total);
    const nobreak = try a.alloc(u8, 9000);
    @memset(nobreak, 'a');
    try t.expectEqual(3, (try split(a, nobreak, max_text)).len);

    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    try b.send(42, text.items);
    const out = try outbox(&e);
    try t.expectEqual(parts.len, std.mem.count(u8, out, "\"method\":\"sendMessage\""));
}

test "buttons_sent_as_inline_keyboard" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const id = try b.sendButtons(42, "Run shell: ls?", &.{ .{ "Allow once", "a1:once" }, .{ "Deny", "a1:deny" } });
    try t.expect(id > 0);
    try b.answer("cb1");
    try b.clearButtons(42, id);
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"inline_keyboard\":[[{\"text\":\"Allow once\",\"callback_data\":\"a1:once\"},{\"text\":\"Deny\",\"callback_data\":\"a1:deny\"}]]") != null);
    try t.expect(std.mem.indexOf(u8, out, "answerCallbackQuery") != null);
    try t.expect(std.mem.indexOf(u8, out, "editMessageReplyMarkup") != null);
}

test "offset_persists_across_restart" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try inbox(&e, 1, "{\"message\":{\"from\":{\"id\":42},\"chat\":{\"id\":42},\"text\":\"one\"}}");
    try inbox(&e, 2, "{\"message\":{\"from\":{\"id\":42},\"chat\":{\"id\":42},\"text\":\"two\"}}");
    const a = e.arena.allocator();
    const path = try std.fs.path.join(a, &.{ e.dir, "offset" });
    {
        var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
        defer b.deinit();
        const ups = try b.getUpdates(a, Offset.load(t.io, path), 0);
        try t.expectEqual(2, ups.len);
        try Offset.save(t.io, path, ups[ups.len - 1].updateId() + 1);
    }
    var b2 = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b2.deinit();
    try t.expectEqual(3, Offset.load(t.io, path));
    try t.expectEqual(0, (try b2.getUpdates(a, Offset.load(t.io, path), 0)).len);
}

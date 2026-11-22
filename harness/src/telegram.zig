//! The Telegram Bot API: long polling for messages and button presses,
//! sending text (split at Telegram's 4,096 characters), buttons and
//! documents, to a chat or one of its topics, and opening topics.
const std = @import("std");
const http = @import("http.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;

pub const max_text = 4096;

pub const Update = union(enum) {
    message: Message,
    callback: Callback,

    pub fn updateId(u: Update) i64 {
        return switch (u) {
            inline else => |x| x.update_id,
        };
    }
};

pub const Message = struct {
    update_id: i64,
    from_id: i64,
    chat_id: i64,
    text: []const u8,
    message_id: i64 = 0,
    /// "private", "group", "supergroup" or "channel".
    chat_type: []const u8 = "private",
    /// The topic it was sent in; 0: the chat itself.
    thread: i64 = 0,
    /// The topic's name, when the message opened it or replies to its
    /// opening (as a topic's messages do).
    topic: ?[]const u8 = null,
};

pub const Callback = struct {
    update_id: i64,
    id: []const u8,
    from_id: i64,
    chat_id: i64,
    message_id: i64,
    data: []const u8,
    /// The topic its message is in; 0: the chat itself.
    thread: i64 = 0,
};

/// The messages a text was sent in: the first one's id and how many.
pub const Sent = struct { first: i64 = 0, count: u32 = 0 };

/// What the bot is (`getMe`).
pub const Me = struct {
    username: []const u8,
    /// Topics in private chats are switched on for it (@BotFather, Bot API 9.3).
    topics: bool,
};

/// The topic a message is in: `message_thread_id` in a private chat (only
/// topics have one there), in a group only with `is_topic_message` (there
/// it also marks reply threads).
fn threadOf(m: jv.Value) i64 {
    const raw = jv.int(jv.get(m, "message_thread_id")) orelse return 0;
    const private = std.mem.eql(u8, jv.str(jv.at(m, &.{ "chat", "type" })) orelse "private", "private");
    return if (private or (jv.boolean(jv.get(m, "is_topic_message")) orelse false)) raw else 0;
}

pub const Bot = struct {
    gpa: std.mem.Allocator,
    io: Io,
    http: http.Client,
    /// The Bot API's address, the bot's own copy: the settings it came from
    /// are replaced on /reload.
    api: []u8,
    token: []const u8,
    mutex: Io.Mutex = .init,
    /// Longest wait Telegram may ask for before a call is tried again
    /// (seconds); asked to wait longer, the call fails with RateLimited.
    max_retry_wait_s: u32 = 60,

    pub fn init(gpa: std.mem.Allocator, io: Io, api: []const u8, token: []const u8) !Bot {
        const own = try gpa.dupe(u8, api);
        errdefer gpa.free(own);
        return .{ .gpa = gpa, .io = io, .http = .init(gpa, io, try http.Target.parse(own)), .api = own, .token = token };
    }

    pub fn deinit(b: *Bot) void {
        b.http.deinit();
        b.gpa.free(b.api);
    }

    /// One Bot API call; returns the `result` value (in `arena`). Told to
    /// slow down (429), it waits as long as Telegram says and tries again,
    /// twice at most.
    fn call(b: *Bot, arena: std.mem.Allocator, method: []const u8, body: []const u8, idle_ms: u32) !?jv.Value {
        return b.callAs(arena, method, body, "application/json", idle_ms);
    }

    fn callAs(b: *Bot, arena: std.mem.Allocator, method: []const u8, body: []const u8, content_type: []const u8, idle_ms: u32) !?jv.Value {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const path = try std.fmt.allocPrint(arena, "/bot{s}/{s}", .{ b.token, method });
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            var resp = try b.http.send(.{ .path = path, .body = body, .content_type = content_type, .limits = .{ .idle_ms = idle_ms, .total_ms = idle_ms + 30_000 } });
            defer resp.deinit();
            const got = try resp.readAll(arena, 8 << 20);
            const v = jv.parse(arena, got) orelse return error.BadReply;
            if (jv.boolean(jv.get(v, "ok")) orelse false) return jv.get(v, "result");
            if (resp.status == 429 or (jv.int(jv.get(v, "error_code")) orelse 0) == 429) {
                const wait = jv.int(jv.at(v, &.{ "parameters", "retry_after" })) orelse @as(i64, resp.retry_after_s orelse 1);
                if (tries >= 2 or wait > b.max_retry_wait_s) return error.RateLimited;
                b.io.sleep(.fromSeconds(@max(wait, 1)), .awake) catch {};
                continue;
            }
            return error.TelegramRefused;
        }
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
                    .message_id = jv.int(jv.get(m, "message_id")) orelse 0,
                    .chat_type = jv.str(jv.at(m, &.{ "chat", "type" })) orelse "private",
                    .thread = threadOf(m),
                    .topic = jv.str(jv.at(m, &.{ "forum_topic_created", "name" })) orelse jv.str(jv.at(m, &.{ "reply_to_message", "forum_topic_created", "name" })),
                } });
            } else if (jv.get(u, "callback_query")) |c| {
                try out.append(arena, .{ .callback = .{
                    .update_id = id,
                    .id = jv.str(jv.get(c, "id")) orelse "",
                    .from_id = jv.int(jv.at(c, &.{ "from", "id" })) orelse 0,
                    .chat_id = jv.int(jv.at(c, &.{ "message", "chat", "id" })) orelse 0,
                    .message_id = jv.int(jv.at(c, &.{ "message", "message_id" })) orelse 0,
                    .data = jv.str(jv.get(c, "data")) orelse "",
                    .thread = if (jv.get(c, "message")) |m| threadOf(m) else 0,
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
        _ = try b.sendTo(chat_id, 0, text);
    }

    /// `send` to topic `thread` of the chat (0: the chat itself).
    pub fn sendTo(b: *Bot, chat_id: i64, thread: i64, text: []const u8) !Sent {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var sent: Sent = .{};
        for (try split(a, if (text.len > 0) text else "(empty)", max_text)) |part| {
            var body: std.ArrayList(u8) = .empty;
            try where(&body, a, chat_id, thread);
            try body.appendSlice(a, ",\"text\":");
            try util.jsonString(&body, a, part);
            try body.appendSlice(a, ",\"link_preview_options\":{\"is_disabled\":true}}");
            const res = try b.call(a, "sendMessage", body.items, 30_000);
            const id = jv.int(jv.get(res, "message_id")) orelse 0;
            if (sent.count == 0) sent.first = id;
            sent.count += 1;
        }
        return sent;
    }

    /// Sends `text` with one row of buttons (label, data); returns the
    /// message id.
    pub fn sendButtons(b: *Bot, chat_id: i64, text: []const u8, buttons: []const [2][]const u8) !i64 {
        return b.sendButtonsTo(chat_id, 0, text, buttons);
    }

    /// `sendButtons` to topic `thread` of the chat (0: the chat itself).
    pub fn sendButtonsTo(b: *Bot, chat_id: i64, thread: i64, text: []const u8, buttons: []const [2][]const u8) !i64 {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        try where(&body, a, chat_id, thread);
        try body.appendSlice(a, ",\"text\":");
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

    /// Sends `data` as a document called `name` (multipart); returns the
    /// message id.
    pub fn sendDocument(b: *Bot, chat_id: i64, thread: i64, name: []const u8, data: []const u8) !i64 {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var raw: [16]u8 = undefined;
        b.io.random(&raw);
        const boundary = try std.fmt.allocPrint(a, "harness-{s}", .{std.fmt.bytesToHex(raw, .lower)});
        var parts: std.ArrayList(http.Part) = .empty;
        try parts.append(a, .{ .name = "chat_id", .value = try std.fmt.allocPrint(a, "{d}", .{chat_id}) });
        if (thread != 0) try parts.append(a, .{ .name = "message_thread_id", .value = try std.fmt.allocPrint(a, "{d}", .{thread}) });
        try parts.append(a, .{ .name = "document", .value = data, .filename = name });
        const body = try http.multipart(a, boundary, parts.items);
        const ct = try std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary});
        const res = try b.callAs(a, "sendDocument", body, ct, 60_000);
        return jv.int(jv.get(res, "message_id")) orelse 0;
    }

    /// Opens a topic called `name` in the chat; returns its thread.
    pub fn createForumTopic(b: *Bot, chat_id: i64, name: []const u8) !i64 {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        try body.print(a, "{{\"chat_id\":{d},\"name\":", .{chat_id});
        try util.jsonString(&body, a, name);
        try body.append(a, '}');
        const res = try b.call(a, "createForumTopic", body.items, 30_000);
        return jv.int(jv.get(res, "message_thread_id")) orelse error.BadReply;
    }

    /// The bot's username and whether topics in private chats are on.
    pub fn getMe(b: *Bot, arena: std.mem.Allocator) !Me {
        const res = try b.call(arena, "getMe", "{}", 30_000);
        return .{
            .username = jv.str(jv.get(res, "username")) orelse "",
            .topics = jv.boolean(jv.get(res, "has_topics_enabled")) orelse false,
        };
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

/// `{"chat_id":N` and, for a topic, `,"message_thread_id":T`.
fn where(body: *std.ArrayList(u8), a: std.mem.Allocator, chat_id: i64, thread: i64) !void {
    try body.print(a, "{{\"chat_id\":{d}", .{chat_id});
    if (thread != 0) try body.print(a, ",\"message_thread_id\":{d}", .{thread});
}

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

test "updates_carry_the_topic_and_sends_go_to_it" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try inbox(&e, 1, "{\"message\":{\"message_id\":9,\"from\":{\"id\":42},\"chat\":{\"id\":42,\"type\":\"private\"},\"message_thread_id\":5012,\"is_topic_message\":true,\"reply_to_message\":{\"message_id\":8,\"forum_topic_created\":{\"name\":\"House search\"}},\"text\":\"find flats\"}}");
    try inbox(&e, 2, "{\"message\":{\"message_id\":3,\"from\":{\"id\":42},\"chat\":{\"id\":-1001,\"type\":\"supergroup\"},\"message_thread_id\":77,\"text\":\"a reply in a thread\"}}");
    try inbox(&e, 3, "{\"callback_query\":{\"id\":\"cb1\",\"from\":{\"id\":42},\"message\":{\"message_id\":7,\"message_thread_id\":5012,\"chat\":{\"id\":42,\"type\":\"private\"}},\"data\":\"r1-x:1\"}}");
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const a = e.arena.allocator();
    const ups = try b.getUpdates(a, 0, 0);
    try t.expectEqual(3, ups.len);
    const m = ups[0].message;
    try t.expectEqual(5012, m.thread);
    try t.expectEqualStrings("House search", m.topic.?);
    try t.expectEqualStrings("private", m.chat_type);
    try t.expectEqual(9, m.message_id);
    // in a group the field also marks reply threads: only a topic's counts
    try t.expectEqualStrings("supergroup", ups[1].message.chat_type);
    try t.expectEqual(0, ups[1].message.thread);
    try t.expectEqual(null, ups[1].message.topic);
    try t.expectEqual(5012, ups[2].callback.thread);
    const sent = try b.sendTo(42, 5012, "three flats");
    try t.expect(sent.first > 0);
    try t.expectEqual(1, sent.count);
    try b.send(42, "in the chat");
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"chat_id\":42,\"message_thread_id\":5012,\"text\":\"three flats\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"chat_id\":42,\"text\":\"in the chat\"") != null);
    _ = try b.sendButtonsTo(42, 5012, "pick one", &.{.{ "Yes", "r1-x:1" }});
    try t.expect(std.mem.indexOf(u8, try outbox(&e), "\"chat_id\":42,\"message_thread_id\":5012,\"text\":\"pick one\"") != null);
    const me = try b.getMe(a);
    try t.expectEqualStrings("harness_test_bot", me.username);
    try t.expect(me.topics);
    const thread = try b.createForumTopic(42, "Trading");
    try t.expect(thread > 0);
    try t.expect(std.mem.indexOf(u8, try outbox(&e), "\"method\":\"createForumTopic\",\"message_id\":") != null);
    try t.expect(std.mem.indexOf(u8, try outbox(&e), "\"name\":\"Trading\"") != null);
    // a chat without topics refuses
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/no-topics", .data = "" });
    try t.expectError(error.TelegramRefused, b.createForumTopic(42, "Other"));
}

test "documents_are_sent_as_multipart" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const a = e.arena.allocator();
    const id = try b.sendDocument(42, 5012, "flats.csv", "street,rooms\nMain 1,3\n");
    try t.expect(id > 0);
    // the body as Telegram gets it (the stand-in keeps one that is not JSON as a string)
    var lines = std.mem.splitScalar(u8, try outbox(&e), '\n');
    const body = while (lines.next()) |l| {
        const v = jv.parse(a, l) orelse continue;
        if (std.mem.eql(u8, jv.str(jv.get(v, "method")) orelse "", "sendDocument")) break jv.str(jv.get(v, "body")) orelse return error.TestUnexpectedResult;
    } else return error.TestUnexpectedResult;
    for ([_][]const u8{
        "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n42\r\n",
        "Content-Disposition: form-data; name=\"message_thread_id\"\r\n\r\n5012\r\n",
        "Content-Disposition: form-data; name=\"document\"; filename=\"flats.csv\"\r\nContent-Type: application/octet-stream\r\n\r\nstreet,rooms\nMain 1,3\n\r\n",
    }) |want| {
        if (std.mem.indexOf(u8, body, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, body });
        try t.expect(std.mem.indexOf(u8, body, want) != null);
    }
    // a file name can't end its header or start another
    const mp = try http.multipart(a, "BOUNDARY", &.{.{ .name = "document", .value = "x", .filename = "a\"b\r\nc\\.txt" }});
    try t.expect(std.mem.indexOf(u8, mp, "filename=\"abc.txt\"") != null);
    try t.expect(std.mem.startsWith(u8, mp, "--BOUNDARY\r\n"));
    try t.expect(std.mem.endsWith(u8, mp, "--BOUNDARY--\r\n"));
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

test "a_rate_limited_send_waits_as_told_and_goes_through" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/fail.json", .data = "{\"status\":429,\"retry_after\":1,\"count\":1}" });
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    try b.send(42, "after the wait");
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - start >= 900 * std.time.ns_per_ms);
    try t.expectEqual(1, std.mem.count(u8, try outbox(&e), "after the wait"));
    // told to wait longer than a send may: an error, not a silent loss
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/fail.json", .data = "{\"status\":429,\"retry_after\":3600,\"count\":5}" });
    try t.expectError(error.RateLimited, b.send(42, "far too soon"));
    try t.expectEqual(0, std.mem.count(u8, try outbox(&e), "far too soon"));
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

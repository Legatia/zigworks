//! The Telegram Bot API: long polling for messages (voice notes too) and
//! button presses, sending text (split at Telegram's 4,096 characters),
//! buttons and documents, to a chat or one of its topics, opening topics,
//! and fetching a file a message carries.
const std = @import("std");
const http = @import("http.zig");
const jv = @import("jv.zig");
const util = @import("util.zig");
const voice = @import("voice.zig");
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
    /// The message it replies to; 0: none (a topic's reply to its own
    /// opening is no reply).
    reply_to: i64 = 0,
    /// A voice note or an audio file it carries (its text is then "").
    voice: ?voice.Note = null,
    /// The owner forwarded it (`forward_origin`, or an older client's
    /// `forward_date`): someone else's words.
    forwarded: bool = false,
};

/// Where a file is (`getFile`): its path for `download`, and its size (0:
/// not said).
pub const File = struct { path: []const u8, size: u64 = 0 };

/// How a message is sent.
pub const Opts = struct {
    /// Without a sound on the owner's devices (`disable_notification`).
    quiet: bool = false,
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
    /// The text of the message its button is in ("" when Telegram leaves
    /// it out): an Undo press edits it with the outcome.
    text: []const u8 = "",
};

/// The messages a text was sent in: the first one's id and how many.
pub const Sent = struct { first: i64 = 0, count: u32 = 0 };

/// A message entity: a link over part of the text, or a quote folded
/// until tapped. Offsets and lengths in bytes of the text; sent in UTF-16
/// units, as the Bot API counts them. No parse_mode is ever used, so text
/// from outside can't make markup.
pub const Entity = struct {
    kind: Kind,
    offset: usize,
    len: usize,
    /// A text_link's address.
    url: []const u8 = "",

    pub const Kind = enum { text_link, expandable_blockquote };
};

/// How many UTF-16 units `s` is (a byte that isn't UTF-8: one).
pub fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            n += 1;
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            n += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            n += 1;
            i += 1;
            continue;
        };
        n += if (cp >= 0x10000) 2 else 1;
        i += len;
    }
    return n;
}

/// `,"entities":[…]` for `ents` of `text` (in UTF-16 units); nothing for none.
fn entitiesJson(body: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, ents: []const Entity) !void {
    var first = true;
    for (ents) |e| {
        if (e.len == 0 or e.offset + e.len > text.len) continue;
        try body.appendSlice(a, if (first) ",\"entities\":[" else ",");
        first = false;
        // counted on the text as it is sent (broken UTF-8 replaced)
        try body.print(a, "{{\"type\":\"{s}\",\"offset\":{d},\"length\":{d}", .{ @tagName(e.kind), utf16Len(try util.validUtf8(a, text[0..e.offset])), utf16Len(try util.validUtf8(a, text[e.offset .. e.offset + e.len])) });
        if (e.kind == .text_link) {
            try body.appendSlice(a, ",\"url\":");
            try util.jsonString(body, a, e.url);
        }
        try body.append(a, '}');
    }
    if (!first) try body.append(a, ']');
}

/// What the bot is (`getMe`).
pub const Me = struct {
    username: []const u8,
    /// Topics in private chats are switched on for it (@BotFather, Bot API 9.3).
    topics: bool,
};

/// The topic a message is in: `message_thread_id` in a private chat (only
/// topics have one there), in a group only with `is_topic_message` (there
/// it also marks reply threads).
/// The voice note (`voice`) or audio file (`audio`) a message carries.
fn noteOf(m: jv.Value) ?voice.Note {
    const kind: voice.Note.Kind = if (jv.get(m, "voice") != null) .voice else if (jv.get(m, "audio") != null) .audio else return null;
    const v = jv.get(m, @tagName(kind)).?;
    return .{
        .kind = kind,
        .file_id = jv.str(jv.get(v, "file_id")) orelse return null,
        .seconds = @intCast(std.math.clamp(jv.int(jv.get(v, "duration")) orelse 0, 0, std.math.maxInt(u32))),
        .size = @intCast(@max(0, jv.int(jv.get(v, "file_size")) orelse 0)),
        .mime = jv.str(jv.get(v, "mime_type")) orelse "",
        .name = jv.str(jv.get(v, "file_name")) orelse "",
    };
}

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
        var why: []const u8 = "";
        return b.callWhy(arena, method, body, content_type, idle_ms, &why);
    }

    /// `callAs`; a refusal's description in `why` (in `arena`).
    fn callWhy(b: *Bot, arena: std.mem.Allocator, method: []const u8, body: []const u8, content_type: []const u8, idle_ms: u32, why: *[]const u8) !?jv.Value {
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
            why.* = jv.str(jv.get(v, "description")) orelse "";
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
                    .reply_to = if (jv.get(m, "reply_to_message")) |r| (if (jv.get(r, "forum_topic_created") != null) 0 else jv.int(jv.get(r, "message_id")) orelse 0) else 0,
                    .voice = noteOf(m),
                    .forwarded = jv.get(m, "forward_origin") != null or jv.get(m, "forward_date") != null,
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
                    .text = jv.str(jv.at(c, &.{ "message", "text" })) orelse "",
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
        _ = try b.sendTo(chat_id, 0, text, .{});
    }

    /// `send` to topic `thread` of the chat (0: the chat itself).
    pub fn sendTo(b: *Bot, chat_id: i64, thread: i64, text: []const u8, opts: Opts) !Sent {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var sent: Sent = .{};
        for (try split(a, if (text.len > 0) text else "(empty)", max_text)) |part| {
            var body: std.ArrayList(u8) = .empty;
            try where(&body, a, chat_id, thread);
            try body.appendSlice(a, ",\"text\":");
            try util.jsonString(&body, a, part);
            try body.appendSlice(a, ",\"link_preview_options\":{\"is_disabled\":true}");
            if (opts.quiet) try body.appendSlice(a, ",\"disable_notification\":true");
            try body.append(a, '}');
            const res = try b.call(a, "sendMessage", body.items, 30_000);
            const id = jv.int(jv.get(res, "message_id")) orelse 0;
            if (sent.count == 0) sent.first = id;
            sent.count += 1;
        }
        return sent;
    }

    /// Sends `text` with buttons (label, data): up to three on one row,
    /// four as two rows of two, more in rows of four; returns the message
    /// id.
    pub fn sendButtons(b: *Bot, chat_id: i64, text: []const u8, buttons: []const [2][]const u8) !i64 {
        return b.sendButtonsTo(chat_id, 0, text, buttons, .{});
    }

    /// `sendButtons` to topic `thread` of the chat (0: the chat itself).
    pub fn sendButtonsTo(b: *Bot, chat_id: i64, thread: i64, text: []const u8, buttons: []const [2][]const u8, opts: Opts) !i64 {
        return b.sendButtonsRich(chat_id, thread, text, &.{}, buttons, opts);
    }

    /// `sendButtonsTo` with message entities (no parse_mode).
    pub fn sendButtonsRich(b: *Bot, chat_id: i64, thread: i64, text: []const u8, ents: []const Entity, buttons: []const [2][]const u8, opts: Opts) !i64 {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        const cut = util.cut(text, max_text);
        try where(&body, a, chat_id, thread);
        try body.appendSlice(a, ",\"text\":");
        try util.jsonString(&body, a, cut);
        try entitiesJson(&body, a, cut, ents);
        if (opts.quiet) try body.appendSlice(a, ",\"disable_notification\":true");
        try body.appendSlice(a, ",\"reply_markup\":{\"inline_keyboard\":[[");
        const row = rowLength(buttons.len);
        for (buttons, 0..) |btn, i| {
            if (i > 0) try body.appendSlice(a, if (i % row == 0) "],[" else ",");
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
        return b.sendDocumentAs(chat_id, thread, name, data, .{});
    }

    /// `sendDocument`, without a sound when `opts.quiet`.
    pub fn sendDocumentAs(b: *Bot, chat_id: i64, thread: i64, name: []const u8, data: []const u8, opts: Opts) !i64 {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var raw: [16]u8 = undefined;
        b.io.random(&raw);
        const boundary = try std.fmt.allocPrint(a, "harness-{s}", .{std.fmt.bytesToHex(raw, .lower)});
        var parts: std.ArrayList(http.Part) = .empty;
        try parts.append(a, .{ .name = "chat_id", .value = try std.fmt.allocPrint(a, "{d}", .{chat_id}) });
        if (thread != 0) try parts.append(a, .{ .name = "message_thread_id", .value = try std.fmt.allocPrint(a, "{d}", .{thread}) });
        if (opts.quiet) try parts.append(a, .{ .name = "disable_notification", .value = "true" });
        try parts.append(a, .{ .name = "document", .value = data, .filename = name });
        const body = try http.multipart(a, boundary, parts.items);
        const ct = try std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary});
        const res = try b.callAs(a, "sendDocument", body, ct, 60_000);
        return jv.int(jv.get(res, "message_id")) orelse 0;
    }

    /// `sendTo` with message entities (no parse_mode): each part gets the
    /// entities wholly in it.
    pub fn sendRich(b: *Bot, chat_id: i64, thread: i64, text: []const u8, ents: []const Entity, opts: Opts) !Sent {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var sent: Sent = .{};
        var at: usize = 0;
        for (try split(a, if (text.len > 0) text else "(empty)", max_text)) |part| {
            defer at += part.len;
            var mine: std.ArrayList(Entity) = .empty;
            for (ents) |e| if (e.offset >= at and e.offset + e.len <= at + part.len) {
                var x = e;
                x.offset -= at;
                try mine.append(a, x);
            };
            var body: std.ArrayList(u8) = .empty;
            try where(&body, a, chat_id, thread);
            try body.appendSlice(a, ",\"text\":");
            try util.jsonString(&body, a, part);
            try entitiesJson(&body, a, part, mine.items);
            try body.appendSlice(a, ",\"link_preview_options\":{\"is_disabled\":true}");
            if (opts.quiet) try body.appendSlice(a, ",\"disable_notification\":true");
            try body.append(a, '}');
            const res = try b.call(a, "sendMessage", body.items, 30_000);
            const id = jv.int(jv.get(res, "message_id")) orelse 0;
            if (sent.count == 0) sent.first = id;
            sent.count += 1;
        }
        return sent;
    }

    /// Replaces a message's text and entities; error.MessageGone when
    /// Telegram no longer has it (the same text again is no error).
    pub fn editRich(b: *Bot, chat_id: i64, message_id: i64, text: []const u8, ents: []const Entity) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        const cut = util.cut(text, max_text);
        try body.print(a, "{{\"chat_id\":{d},\"message_id\":{d},\"text\":", .{ chat_id, message_id });
        try util.jsonString(&body, a, cut);
        try entitiesJson(&body, a, cut, ents);
        try body.appendSlice(a, ",\"link_preview_options\":{\"is_disabled\":true}}");
        var why: []const u8 = "";
        _ = b.callWhy(a, "editMessageText", body.items, "application/json", 30_000, &why) catch |e| {
            if (e != error.TelegramRefused) return e;
            if (std.mem.indexOf(u8, why, "not modified") != null) return;
            if (std.mem.indexOf(u8, why, "not found") != null or std.mem.indexOf(u8, why, "can't be edited") != null) return error.MessageGone;
            return e;
        };
    }

    /// Pins a message without a sound.
    pub fn pin(b: *Bot, chat_id: i64, message_id: i64) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try std.fmt.allocPrint(a, "{{\"chat_id\":{d},\"message_id\":{d},\"disable_notification\":true}}", .{ chat_id, message_id });
        _ = try b.call(a, "pinChatMessage", body, 30_000);
    }

    /// Switches topics in private chats on (or off) for the bot (Bot API
    /// 10.5's setMySettings).
    pub fn setTopics(b: *Bot, on: bool) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        _ = try b.call(a, "setMySettings", if (on) "{\"has_topics_enabled\":true}" else "{\"has_topics_enabled\":false}", 30_000);
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

    /// Replaces a message's text; its buttons go with the old text.
    pub fn editText(b: *Bot, chat_id: i64, message_id: i64, text: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        try body.print(a, "{{\"chat_id\":{d},\"message_id\":{d},\"text\":", .{ chat_id, message_id });
        try util.jsonString(&body, a, util.cut(text, max_text));
        try body.appendSlice(a, ",\"link_preview_options\":{\"is_disabled\":true}}");
        _ = try b.call(a, "editMessageText", body.items, 30_000);
    }

    /// Where file `file_id` is: its path for `download`, and its size.
    pub fn getFile(b: *Bot, arena: std.mem.Allocator, file_id: []const u8) !File {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(arena, "{\"file_id\":");
        try util.jsonString(&body, arena, file_id);
        try body.append(arena, '}');
        const res = try b.call(arena, "getFile", body.items, 30_000);
        const path = jv.str(jv.get(res, "file_path")) orelse return error.BadReply;
        if (!filePath(path)) return error.BadReply;
        return .{ .path = try arena.dupe(u8, path), .size = @intCast(@max(0, jv.int(jv.get(res, "file_size")) orelse 0)) };
    }

    /// The file at `path` (as getFile gave it), in `arena`; error.TooLarge
    /// past `max` bytes (nothing more is read).
    pub fn download(b: *Bot, arena: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
        if (!filePath(path)) return error.BadPath;
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const target = try std.fmt.allocPrint(arena, "/file/bot{s}/{s}", .{ b.token, path });
        var resp = try b.http.send(.{ .method = .GET, .path = target, .limits = .{ .idle_ms = 30_000, .total_ms = 120_000 } });
        defer resp.deinit();
        if (resp.status != 200) return error.TelegramRefused;
        var out: std.ArrayList(u8) = .empty;
        while (try resp.next()) |part| {
            if (out.items.len + part.len > max) return error.TooLarge;
            try out.appendSlice(arena, part);
        }
        return out.items;
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

/// A file's path as getFile gives it ("voice/file_3.oga"): nothing that
/// could reach past the bot's files.
fn filePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 256 or path[0] == '/' or std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '_' or ch == '-' or ch == '.')) return false;
    return true;
}

/// Buttons on a row: up to three on one, four as two rows of two, more
/// in rows of four.
fn rowLength(n: usize) usize {
    if (n <= 3) return @max(n, 1);
    if (n == 4) return 2;
    return 4;
}

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

test "a_forwarded_message_is_read_as_forwarded" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try inbox(&e, 1, "{\"message\":{\"message_id\":5,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"forward_origin\":{\"type\":\"user\",\"date\":1,\"sender_user\":{\"id\":7}},\"text\":\"/dryrun off\"}}");
    try inbox(&e, 2, "{\"message\":{\"message_id\":6,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"forward_date\":1,\"text\":\"an older client's forward\"}}");
    try inbox(&e, 3, "{\"message\":{\"message_id\":7,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"text\":\"my own words\"}}");
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const ups = try b.getUpdates(e.arena.allocator(), 0, 0);
    try t.expectEqual(3, ups.len);
    try t.expect(ups[0].message.forwarded);
    try t.expect(ups[1].message.forwarded);
    try t.expect(!ups[2].message.forwarded);
}

test "a_callbacks_message_text_is_kept" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try inbox(&e, 1, "{\"callback_query\":{\"id\":\"cb1\",\"from\":{\"id\":42},\"message\":{\"message_id\":7,\"chat\":{\"id\":42},\"text\":\"Wrote a.\\n\\nChanged 1 file in notes/.\"},\"data\":\"u41-0123456789abcdef\"}}");
    try inbox(&e, 2, "{\"callback_query\":{\"id\":\"cb2\",\"from\":{\"id\":42},\"message\":{\"message_id\":8,\"chat\":{\"id\":42}},\"data\":\"a:once\"}}");
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const ups = try b.getUpdates(e.arena.allocator(), 0, 0);
    try t.expectEqualStrings("Wrote a.\n\nChanged 1 file in notes/.", ups[0].callback.text);
    try t.expectEqualStrings("", ups[1].callback.text);
}

test "a_voice_note_and_an_audio_file_are_read" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try inbox(&e, 1, "{\"message\":{\"message_id\":5,\"from\":{\"id\":42},\"chat\":{\"id\":42,\"type\":\"private\"},\"voice\":{\"file_id\":\"AwACAgIAAxk\",\"file_unique_id\":\"AgAD\",\"duration\":4,\"mime_type\":\"audio/ogg\",\"file_size\":7316}}}");
    try inbox(&e, 2, "{\"message\":{\"message_id\":6,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"audio\":{\"file_id\":\"CQACAgIAAxk\",\"duration\":95,\"mime_type\":\"audio/mpeg\",\"file_name\":\"memo.mp3\",\"file_size\":1520000},\"reply_to_message\":{\"message_id\":3,\"text\":\"Which room?\"}}}");
    try inbox(&e, 3, "{\"message\":{\"message_id\":7,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"text\":\"plain\"}}");
    // a voice note Telegram says nothing more of
    try inbox(&e, 4, "{\"message\":{\"message_id\":8,\"from\":{\"id\":42},\"chat\":{\"id\":42},\"voice\":{\"file_id\":\"bare\"}}}");
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const ups = try b.getUpdates(e.arena.allocator(), 0, 0);
    try t.expectEqual(4, ups.len);
    const v = ups[0].message.voice.?;
    try t.expectEqual(voice.Note.Kind.voice, v.kind);
    try t.expectEqualStrings("AwACAgIAAxk", v.file_id);
    try t.expectEqual(4, v.seconds);
    try t.expectEqual(7316, v.size);
    try t.expectEqualStrings("audio/ogg", v.mime);
    try t.expectEqualStrings("", ups[0].message.text);
    const au = ups[1].message.voice.?;
    try t.expectEqual(voice.Note.Kind.audio, au.kind);
    try t.expectEqualStrings("memo.mp3", au.name);
    try t.expectEqualStrings("audio/mpeg", au.mime);
    try t.expectEqual(95, au.seconds);
    try t.expectEqual(3, ups[1].message.reply_to);
    try t.expect(ups[2].message.voice == null);
    const bare = ups[3].message.voice.?;
    try t.expectEqual(0, bare.seconds);
    try t.expectEqual(0, bare.size);
}

test "a_voice_file_is_fetched_by_its_path" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/files/AwACAgIAAxk", .data = "OggS-voice-bytes" });
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const a = e.arena.allocator();
    const f = try b.getFile(a, "AwACAgIAAxk");
    try t.expectEqualStrings("voice/AwACAgIAAxk.oga", f.path);
    try t.expectEqual(16, f.size);
    try t.expectEqualStrings("OggS-voice-bytes", try b.download(a, f.path, 1 << 20));
    // more than a note may be: refused, not cut
    try t.expectError(error.TooLarge, b.download(a, f.path, 8));
    // an id Telegram doesn't know, and a path that could leave its files
    try t.expectError(error.TelegramRefused, b.getFile(a, "nope"));
    try t.expectError(error.BadPath, b.download(a, "../bot123:abc/getMe", 1 << 20));
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"method\":\"getFile\",\"message_id\":") != null);
    try t.expect(std.mem.indexOf(u8, out, "{\"method\":\"download\",\"path\":\"voice/AwACAgIAAxk.oga\"}") != null);
    // the token is in the request's path only, never in what was recorded
    try t.expect(std.mem.indexOf(u8, out, "123:abc") == null);
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
    const sent = try b.sendTo(42, 5012, "three flats", .{});
    try t.expect(sent.first > 0);
    try t.expectEqual(1, sent.count);
    try b.send(42, "in the chat");
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"chat_id\":42,\"message_thread_id\":5012,\"text\":\"three flats\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"chat_id\":42,\"text\":\"in the chat\"") != null);
    _ = try b.sendButtonsTo(42, 5012, "pick one", &.{.{ "Yes", "r1-x:1" }}, .{});
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

test "replies_quiet_sends_edits_and_rows" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    // a reply to a message, and a topic's message, whose reply is its opening
    try inbox(&e, 1, "{\"message\":{\"message_id\":80,\"from\":{\"id\":42},\"chat\":{\"id\":42,\"type\":\"private\"},\"reply_to_message\":{\"message_id\":77,\"text\":\"Allow this? [1]\"},\"text\":\"use staging\"}}");
    try inbox(&e, 2, "{\"message\":{\"message_id\":81,\"from\":{\"id\":42},\"chat\":{\"id\":42,\"type\":\"private\"},\"message_thread_id\":5012,\"is_topic_message\":true,\"reply_to_message\":{\"message_id\":8,\"forum_topic_created\":{\"name\":\"House search\"}},\"text\":\"find flats\"}}");
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const a = e.arena.allocator();
    const ups = try b.getUpdates(a, 0, 0);
    try t.expectEqual(77, ups[0].message.reply_to);
    try t.expectEqual(0, ups[1].message.reply_to);
    // quiet: no sound on the owner's phone
    _ = try b.sendTo(42, 0, "a quiet note", .{ .quiet = true });
    _ = try b.sendButtonsTo(42, 0, "four", &.{ .{ "A", "i1-x:1" }, .{ "B", "i1-x:2" }, .{ "C", "i1-x:3" }, .{ "D", "i1-x:4" } }, .{ .quiet = true });
    _ = try b.sendButtonsTo(42, 0, "three", &.{ .{ "A", "i2-x:1" }, .{ "B", "i2-x:2" }, .{ "C", "i2-x:3" } }, .{});
    _ = try b.sendButtonsTo(42, 0, "six", &.{ .{ "S1", "s1" }, .{ "S2", "s2" }, .{ "S3", "s3" }, .{ "S4", "s4" }, .{ "S5", "s5" }, .{ "S6", "s6" } }, .{});
    try b.editText(42, 9, "done");
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"text\":\"a quiet note\",\"link_preview_options\":{\"is_disabled\":true},\"disable_notification\":true") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"text\":\"four\",\"disable_notification\":true,\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"A\",\"callback_data\":\"i1-x:1\"},{\"text\":\"B\",\"callback_data\":\"i1-x:2\"}],[{\"text\":\"C\",\"callback_data\":\"i1-x:3\"},{\"text\":\"D\",\"callback_data\":\"i1-x:4\"}]]}") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"text\":\"three\",\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"A\",\"callback_data\":\"i2-x:1\"},{\"text\":\"B\",\"callback_data\":\"i2-x:2\"},{\"text\":\"C\",\"callback_data\":\"i2-x:3\"}]]}") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"callback_data\":\"s4\"}],[{\"text\":\"S5\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"method\":\"editMessageText\",\"message_id\":") != null);
    try t.expect(std.mem.indexOf(u8, out, "{\"chat_id\":42,\"message_id\":9,\"text\":\"done\",\"link_preview_options\":{\"is_disabled\":true}}") != null);
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

test "a_document_can_go_without_a_sound" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    _ = try b.sendDocumentAs(42, 0, "report.csv", "a,b\n", .{ .quiet = true });
    _ = try b.sendDocument(42, 0, "loud.csv", "c,d\n");
    const out = try outbox(&e);
    const quiet_at = std.mem.indexOf(u8, out, "report.csv").?;
    const loud_at = std.mem.indexOf(u8, out, "loud.csv").?;
    const mark = "name=\\\"disable_notification\\\"\\r\\n\\r\\ntrue";
    const found = std.mem.indexOf(u8, out, mark) orelse {
        std.debug.print("no {s} in:\n{s}\n", .{ mark, out });
        return error.TestUnexpectedResult;
    };
    try t.expect(found < loud_at and quiet_at < loud_at);
    try t.expectEqual(1, std.mem.count(u8, out, "disable_notification"));
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

test "entities_count_utf16_units" {
    try t.expectEqual(5, utf16Len("hello"));
    // Polish letters: one unit each; an emoji: two
    try t.expectEqual(4, utf16Len("łódź"));
    try t.expectEqual(2, utf16Len("\u{1F600}"));
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    // "Kraków 😀 (Travel)": the link over "Travel", after an emoji and a ó
    const text = "Kraków \u{1F600} (Travel)";
    const at = std.mem.indexOf(u8, text, "Travel").?;
    _ = try b.sendRich(42, 5003, text, &.{.{ .kind = .text_link, .offset = at, .len = 6, .url = "https://t.me/harness_test_bot/5003" }}, .{ .quiet = true });
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"entities\":[{\"type\":\"text_link\",\"offset\":11,\"length\":6,\"url\":\"https://t.me/harness_test_bot/5003\"}]") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"message_thread_id\":5003") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"disable_notification\":true") != null);
    try t.expect(std.mem.indexOf(u8, out, "parse_mode") == null);
}

test "set_my_settings_pin_and_a_gone_edit" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/me.json", .data = "{\"id\":1,\"is_bot\":true,\"username\":\"harness_test_bot\",\"has_topics_enabled\":false}" });
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const a = e.arena.allocator();
    try t.expect(!(try b.getMe(a)).topics);
    try b.setTopics(true);
    try t.expect((try b.getMe(a)).topics);
    try b.pin(42, 9);
    try b.editRich(42, 9, "Travel\nPending: none.", &.{});
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/gone", .data = "9\n" });
    try t.expectError(error.MessageGone, b.editRich(42, 9, "Travel\nPending: one.", &.{}));
    const out = try outbox(&e);
    try t.expect(std.mem.indexOf(u8, out, "\"method\":\"setMySettings\",\"message_id\":") != null);
    try t.expect(std.mem.indexOf(u8, out, "{\"has_topics_enabled\":true}") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"method\":\"pinChatMessage\",\"message_id\":") != null);
    try t.expect(std.mem.indexOf(u8, out, "{\"chat_id\":42,\"message_id\":9,\"disable_notification\":true}") != null);
    // the setting refused: an error, said by the caller
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = "telegram/no-settings", .data = "" });
    try t.expectError(error.TelegramRefused, b.setTopics(true));
}

test "entities_after_broken_utf8_line_up" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    var b = try Bot.init(t.allocator, t.io, try e.url(), "123:abc");
    defer b.deinit();
    const a = e.arena.allocator();
    // a cut emoji, then the link
    const text = "ab\xf0\x9f\x98Xcd (Travel)";
    const at = std.mem.indexOf(u8, text, "Travel").?;
    _ = try b.sendRich(42, 0, text, &.{.{ .kind = .text_link, .offset = at, .len = 6, .url = "https://t.me/b/5003" }}, .{});
    const out = try outbox(&e);
    const line = out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len];
    const v = jv.parse(a, line).?;
    const sent = jv.str(jv.at(v, &.{ "body", "text" })).?;
    const want = utf16Len(sent[0..std.mem.indexOf(u8, sent, "Travel").?]);
    const ents = jv.arr(jv.at(v, &.{ "body", "entities" })).?;
    try t.expectEqual(@as(i64, @intCast(want)), jv.int(jv.get(ents[0], "offset")).?);
}

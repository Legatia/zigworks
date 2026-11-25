//! Voice notes: a Telegram voice or audio message, transcribed through an
//! OpenAI-compatible `POST {url}/audio/transcriptions` (OpenAI, Groq, a
//! local whisper.cpp server): multipart/form-data with the audio as
//! `file`, `model`, `language` when set and `response_format=json`; the
//! answer's `text`. The audio is only ever in memory.
const std = @import("std");
const http = @import("http.zig");
const jv = @import("jv.zig");
const model = @import("model.zig");
const util = @import("util.zig");
const Io = std.Io;

/// The longest note taken, in seconds.
pub const max_seconds = 120;
/// The largest file the Bot API lets a bot download.
pub const max_bytes = 20 * 1024 * 1024;

/// A voice note or an audio file, as Telegram describes it.
pub const Note = struct {
    kind: Kind = .voice,
    file_id: []const u8,
    /// Its length; 0: not said.
    seconds: u32 = 0,
    /// Its size; 0: not said.
    size: u64 = 0,
    mime: []const u8 = "",
    /// An audio file's own name ("" for a voice note).
    name: []const u8 = "",

    pub const Kind = enum { voice, audio };

    /// A copy whose strings are `gpa`'s (`deinit` frees them).
    pub fn clone(n: Note, gpa: std.mem.Allocator) !Note {
        var o = n;
        o.file_id = try gpa.dupe(u8, n.file_id);
        errdefer gpa.free(o.file_id);
        o.mime = try gpa.dupe(u8, n.mime);
        errdefer gpa.free(o.mime);
        o.name = try gpa.dupe(u8, n.name);
        return o;
    }

    pub fn deinit(n: Note, gpa: std.mem.Allocator) void {
        gpa.free(n.file_id);
        gpa.free(n.mime);
        gpa.free(n.name);
    }

    /// "0:04", "2:15": its length as the owner's app shows it.
    pub fn length(n: Note, buf: *[16]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ n.seconds / 60, n.seconds % 60 }) catch "";
    }
};

/// Extensions the transcription services read the format from.
const known_ext = [_][]const u8{ "flac", "m4a", "mp3", "mp4", "mpeg", "mpga", "ogg", "wav", "webm" };

/// The name the audio is sent as: its extension tells the service the
/// format (OGG/Opus for a voice note; an audio file's by its name, else
/// its type). Never the owner's own file name.
pub fn fileName(n: Note) []const u8 {
    if (n.kind == .voice) return "voice.ogg";
    const dot = std.mem.lastIndexOfScalar(u8, n.name, '.');
    if (dot) |d| {
        var buf: [8]u8 = undefined;
        const ext = n.name[d + 1 ..];
        if (ext.len <= buf.len) {
            const low = std.ascii.lowerString(&buf, ext);
            inline for (known_ext) |k| if (std.mem.eql(u8, low, k)) return "audio." ++ k;
            if (std.mem.eql(u8, low, "oga") or std.mem.eql(u8, low, "opus")) return "audio.ogg";
        }
    }
    const types = [_][2][]const u8{
        .{ "audio/mpeg", "audio.mp3" },  .{ "audio/mp3", "audio.mp3" },   .{ "audio/mp4", "audio.m4a" },
        .{ "audio/x-m4a", "audio.m4a" }, .{ "audio/m4a", "audio.m4a" },   .{ "audio/aac", "audio.m4a" },
        .{ "audio/ogg", "audio.ogg" },   .{ "audio/opus", "audio.ogg" },  .{ "audio/wav", "audio.wav" },
        .{ "audio/x-wav", "audio.wav" }, .{ "audio/wave", "audio.wav" },  .{ "audio/flac", "audio.flac" },
        .{ "audio/x-flac", "audio.flac" }, .{ "audio/webm", "audio.webm" },
    };
    for (types) |tp| if (std.ascii.eqlIgnoreCase(n.mime, tp[0])) return tp[1];
    return "audio.mp3";
}

/// The transcript as the owner sees it first: one line, in straight
/// quotes, whole.
pub fn quoted(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    var space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t' or ch == ' ') {
            space = true;
            continue;
        }
        if (space) try out.append(a, ' ');
        space = false;
        try out.append(a, ch);
    }
    try out.append(a, '"');
    return out.items;
}

pub const Error = error{
    /// No key is stored: nothing is sent.
    NoKey,
    /// No url is set: nothing is sent.
    NoUrl,
    /// 401 or 403.
    KeyRefused,
    /// 402.
    BudgetSpent,
    /// 429: not tried again (the owner sends the note again).
    RateLimited,
    /// 400, 413, 415 or 422: the request itself was refused.
    Rejected,
    /// Any other error status.
    Upstream,
    /// The answer had no `text`.
    BadReply,
    /// /stop came while it was under way.
    Stopped,
} || http.Error;

/// One provider's transcription: its address, auth, headers and key (a
/// `model.Provider`, as `[provider NAME]` or a preset makes it), the
/// model and the language hint.
pub const Transcriber = struct {
    gpa: std.mem.Allocator,
    io: Io,
    provider: model.Provider,
    model: []const u8,
    /// ISO 639-1 ("pl"); "": the service finds it.
    language: []const u8 = "",
    /// The provider's message with the last failure (the key masked).
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
    /// Longest the call may take (ms).
    call_ms: u32 = 180_000,

    /// The transcript of `audio` (sent as `file_name`), trimmed, in `a`.
    pub fn transcribe(tr: *Transcriber, a: std.mem.Allocator, audio: []const u8, file_name: []const u8, stop: ?*const std.atomic.Value(bool)) Error![]const u8 {
        const p = tr.provider;
        if (p.url.len == 0) return error.NoUrl;
        if (!p.hasKey()) return error.NoKey;
        var target = try http.Target.parse(p.url);
        target.prefix = model.Client.urlPath(p.url);
        var client = http.Client.init(tr.gpa, tr.io, target);
        defer client.deinit();
        var raw: [16]u8 = undefined;
        tr.io.random(&raw);
        const boundary = try std.fmt.allocPrint(a, "harness-{s}", .{std.fmt.bytesToHex(raw, .lower)});
        var parts: std.ArrayList(http.Part) = .empty;
        try parts.append(a, .{ .name = "file", .value = audio, .filename = file_name });
        if (tr.model.len > 0) try parts.append(a, .{ .name = "model", .value = tr.model });
        if (tr.language.len > 0) try parts.append(a, .{ .name = "language", .value = tr.language });
        try parts.append(a, .{ .name = "response_format", .value = "json" });
        const body = try http.multipart(a, boundary, parts.items);
        // the key as the provider takes it, then its own headers
        var hs: [model.max_headers + 1]std.http.Header = undefined;
        var n: usize = 0;
        if (p.auth == .x_api_key) {
            hs[n] = .{ .name = "x-api-key", .value = p.key };
            n += 1;
        }
        for (p.headers[0..@min(p.headers.len, model.max_headers)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = client.send(.{
            .path = "/audio/transcriptions",
            .body = body,
            .content_type = try std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{boundary}),
            .accept = "application/json",
            .key = if (p.auth == .bearer) p.key else null,
            .headers = hs[0..n],
            // sent again, the same audio would be billed again
            .resend = false,
            .limits = .{ .idle_ms = @min(120_000, tr.call_ms), .total_ms = tr.call_ms, .stop = stop },
        }) catch |e| return if (stopped(stop)) error.Stopped else e;
        defer resp.deinit();
        const got = resp.readAll(a, 1 << 20) catch |e| return if (stopped(stop)) error.Stopped else e;
        if (stopped(stop)) return error.Stopped;
        switch (resp.status) {
            200 => {
                const v = jv.parse(a, got) orelse return error.BadReply;
                const text = jv.str(jv.get(v, "text")) orelse return error.BadReply;
                return std.mem.trim(u8, text, " \t\r\n");
            },
            401, 403 => {
                tr.note(got);
                return error.KeyRefused;
            },
            402 => {
                tr.note(got);
                return error.BudgetSpent;
            },
            400, 413, 415, 422 => {
                tr.note(got);
                return error.Rejected;
            },
            429 => {
                tr.note(got);
                return error.RateLimited;
            },
            else => {
                tr.note(got);
                return error.Upstream;
            },
        }
    }

    pub fn stopped(stop: ?*const std.atomic.Value(bool)) bool {
        const f = stop orelse return false;
        return f.load(.acquire);
    }

    pub fn lastError(tr: *const Transcriber) []const u8 {
        return tr.last_error[0..tr.last_error_len];
    }

    /// Keeps the provider's message, the key masked as `[secret:NAME]`.
    pub fn note(tr: *Transcriber, body: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(tr.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = jv.parse(a, body);
        var msg = jv.str(jv.at(v, &.{ "error", "message" })) orelse jv.str(jv.get(v, "error")) orelse body;
        // a gateway may say the key back: never kept, never shown
        if (tr.provider.key.len > 0) {
            const mark = std.fmt.allocPrint(a, "[secret:{s}]", .{tr.provider.key_name}) catch "[secret]";
            msg = std.mem.replaceOwned(u8, a, msg, tr.provider.key, mark) catch "(an error message that could not be masked)";
        }
        const s = util.cut(std.mem.trim(u8, msg, " \t\r\n"), tr.last_error.len);
        @memcpy(tr.last_error[0..s.len], s);
        tr.last_error_len = s.len;
    }

    /// What the owner is told when a note was not transcribed: the
    /// model's words for the same failure, naming the provider.
    pub fn failure(tr: *const Transcriber, a: std.mem.Allocator, e: anyerror) []const u8 {
        const p = tr.provider.name;
        const k = tr.provider.key_name;
        const msg = tr.lastError();
        const said: []const u8 = switch (e) {
            error.NoKey => std.fmt.allocPrint(a, "Voice notes are refused: no {s} key is stored (harness secret add {s}).", .{ p, k }),
            error.NoUrl => std.fmt.allocPrint(a, "Voice notes are refused: no {s} url is set ([provider {s}] url in config.ini, then /reload).", .{ p, p }),
            error.KeyRefused => std.fmt.allocPrint(a, "Voice notes are refused: {s} refused the key stored as {s}{s}{s}{s}; store the right key with harness secret add {s}.", .{
                p, k, if (msg.len > 0) " (" else "", msg, if (msg.len > 0) ")" else "", k,
            }),
            error.BudgetSpent => std.fmt.allocPrint(a, "Transcription budget used up at {s}.", .{p}),
            error.RateLimited => std.fmt.allocPrint(a, "Transcription is rate limited at {s}; try again later.", .{p}),
            error.Rejected => if (msg.len > 0) std.fmt.allocPrint(a, "The transcription API at {s} refused the request: {s}", .{ p, msg }) else std.fmt.allocPrint(a, "The transcription API at {s} refused the request.", .{p}),
            error.BadReply => std.fmt.allocPrint(a, "Transcription failed at {s}: its answer had no text.", .{p}),
            error.Stopped => "Stopped.",
            else => if (msg.len > 0) std.fmt.allocPrint(a, "Transcription failed at {s}: {s} {s}", .{ p, @errorName(e), msg }) else std.fmt.allocPrint(a, "Transcription failed at {s}: {s}", .{ p, @errorName(e) }),
        } catch "Transcription failed.";
        return said;
    }
};

/// The desk's voice: a provider's OpenAI-format `POST {url}/audio/speech`
/// (`{"model","input","voice","response_format":"mp3"}`), fetched by
/// harness, so the key never reaches the page.
pub const Speaker = struct {
    gpa: std.mem.Allocator,
    io: Io,
    provider: model.Provider,
    model: []const u8,
    voice: []const u8,
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
    call_ms: u32 = 60_000,

    /// The most audio taken back.
    pub const max_audio = 10 << 20;

    /// `text` read aloud, as MP3 bytes in `a`.
    pub fn speak(sp: *Speaker, a: std.mem.Allocator, text: []const u8, stop: ?*const std.atomic.Value(bool)) Error![]const u8 {
        const p = sp.provider;
        if (p.url.len == 0) return error.NoUrl;
        if (!p.hasKey()) return error.NoKey;
        var target = try http.Target.parse(p.url);
        target.prefix = model.Client.urlPath(p.url);
        var client = http.Client.init(sp.gpa, sp.io, target);
        defer client.deinit();
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, "{\"model\":");
        try util.jsonString(&body, a, sp.model);
        try body.appendSlice(a, ",\"input\":");
        try util.jsonString(&body, a, text);
        try body.appendSlice(a, ",\"voice\":");
        try util.jsonString(&body, a, sp.voice);
        try body.appendSlice(a, ",\"response_format\":\"mp3\"}");
        var hs: [model.max_headers + 1]std.http.Header = undefined;
        var n: usize = 0;
        if (p.auth == .x_api_key) {
            hs[n] = .{ .name = "x-api-key", .value = p.key };
            n += 1;
        }
        for (p.headers[0..@min(p.headers.len, model.max_headers)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = client.send(.{
            .path = "/audio/speech",
            .body = body.items,
            .content_type = "application/json",
            .accept = "audio/mpeg",
            .key = if (p.auth == .bearer) p.key else null,
            .headers = hs[0..n],
            .resend = false,
            .limits = .{ .idle_ms = @min(60_000, sp.call_ms), .total_ms = sp.call_ms, .stop = stop },
        }) catch |e| return if (Transcriber.stopped(stop)) error.Stopped else e;
        defer resp.deinit();
        const got = resp.readAll(a, max_audio) catch |e| return if (Transcriber.stopped(stop)) error.Stopped else e;
        if (Transcriber.stopped(stop)) return error.Stopped;
        switch (resp.status) {
            200 => return got,
            401, 403 => {
                sp.note(got);
                return error.KeyRefused;
            },
            402 => return error.BudgetSpent,
            429 => return error.RateLimited,
            400, 413, 415, 422 => {
                sp.note(got);
                return error.Rejected;
            },
            else => {
                sp.note(got);
                return error.Upstream;
            },
        }
    }

    fn note(sp: *Speaker, body: []const u8) void {
        var tr: Transcriber = .{ .gpa = sp.gpa, .io = sp.io, .provider = sp.provider, .model = sp.model };
        tr.note(body);
        @memcpy(sp.last_error[0..tr.last_error_len], tr.last_error[0..tr.last_error_len]);
        sp.last_error_len = tr.last_error_len;
    }

    /// What the desk says when the voice wasn't fetched.
    pub fn failure(sp: *const Speaker, a: std.mem.Allocator, e: anyerror) []const u8 {
        const p = sp.provider.name;
        const msg = sp.last_error[0..sp.last_error_len];
        return switch (e) {
            error.NoKey => std.fmt.allocPrint(a, "No {s} key is stored (harness secret add {s}).", .{ p, sp.provider.key_name }),
            error.NoUrl => std.fmt.allocPrint(a, "No {s} url is set ([provider {s}] url in config.ini).", .{ p, p }),
            error.KeyRefused => std.fmt.allocPrint(a, "{s} refused the key stored as {s}.", .{ p, sp.provider.key_name }),
            error.BudgetSpent => std.fmt.allocPrint(a, "Speech budget used up at {s}.", .{p}),
            error.RateLimited => std.fmt.allocPrint(a, "Speech is rate limited at {s}; try again later.", .{p}),
            else => if (msg.len > 0) std.fmt.allocPrint(a, "Speech failed at {s}: {s} {s}", .{ p, @errorName(e), msg }) else std.fmt.allocPrint(a, "Speech failed at {s}: {s}", .{ p, @errorName(e) }),
        } catch "Speech failed.";
    }
};

// ---- tests ----

const t = std.testing;

fn transcriber(e: *model.TestEnv, auth: model.Auth, key: []const u8) !Transcriber {
    return .{ .gpa = t.allocator, .io = t.io, .provider = try e.provider("groq", .openai, auth, key), .model = "whisper-large-v3-turbo", .language = "pl" };
}

fn sttScript(e: *model.TestEnv, n: u32, body: []const u8) !void {
    const name = try std.fmt.allocPrint(e.arena.allocator(), "transcribe/{d:0>3}.json", .{n});
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = body });
}

fn sttRequest(e: *model.TestEnv, n: u32) !jv.Value {
    const name = try std.fmt.allocPrint(e.arena.allocator(), "transcribe-requests/{d:0>3}.json", .{n});
    const text = try e.tmp.dir.readFileAlloc(t.io, name, e.arena.allocator(), .unlimited);
    return jv.parse(e.arena.allocator(), text) orelse error.TestUnexpectedResult;
}

test "a_note_goes_as_multipart_with_model_and_language" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    try sttScript(&e, 1, "{\"text\":\"  włącz światło w kuchni \\n\"}");
    var tr = try transcriber(&e, .bearer, "gsk-test-key-1");
    const got = try tr.transcribe(a, "OggS\x00\x02voice", "voice.ogg", null);
    try t.expectEqualStrings("włącz światło w kuchni", got);
    const req = try sttRequest(&e, 1);
    try t.expectEqualStrings("/v1/audio/transcriptions", jv.str(jv.get(req, "target")).?);
    try t.expectEqualStrings("Bearer gsk-test-key-1", jv.str(jv.at(req, &.{ "headers", "Authorization" })).?);
    try t.expect(std.mem.startsWith(u8, jv.str(jv.at(req, &.{ "headers", "Content-Type" })).?, "multipart/form-data; boundary=harness-"));
    const body = jv.str(jv.get(req, "body")).?;
    for ([_][]const u8{
        "Content-Disposition: form-data; name=\"file\"; filename=\"voice.ogg\"\r\nContent-Type: application/octet-stream\r\n\r\nOggS\x00\x02voice\r\n",
        "Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n",
        "Content-Disposition: form-data; name=\"language\"\r\n\r\npl\r\n",
        "Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n",
    }) |want| {
        if (std.mem.indexOf(u8, body, want) == null) std.debug.print("missing {s} in:\n{s}\n", .{ want, body });
        try t.expect(std.mem.indexOf(u8, body, want) != null);
    }
    // no language: none sent (the service finds it)
    try sttScript(&e, 2, "{\"text\":\"hello\"}");
    tr.language = "";
    _ = try tr.transcribe(a, "x", "voice.ogg", null);
    try t.expect(std.mem.indexOf(u8, jv.str(jv.get(try sttRequest(&e, 2), "body")).?, "name=\"language\"") == null);
}

test "each_status_is_said_in_the_providers_words" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var tr = try transcriber(&e, .bearer, "gsk-test-key-1");
    const Case = struct { script: []const u8, err: anyerror, said: []const u8 };
    const cases = [_]Case{
        .{ .script = "{\"status\":401,\"echo_key\":true}", .err = error.KeyRefused, .said = "Voice notes are refused: groq refused the key stored as groq (scripted error for key [secret:groq]); store the right key with harness secret add groq." },
        .{ .script = "{\"status\":402}", .err = error.BudgetSpent, .said = "Transcription budget used up at groq." },
        .{ .script = "{\"status\":429,\"retry_after\":1}", .err = error.RateLimited, .said = "Transcription is rate limited at groq; try again later." },
        .{ .script = "{\"status\":400}", .err = error.Rejected, .said = "The transcription API at groq refused the request: scripted error" },
        .{ .script = "{\"status\":500}", .err = error.Upstream, .said = "Transcription failed at groq: Upstream scripted error" },
        .{ .script = "{\"words\":\"none\"}", .err = error.BadReply, .said = "Transcription failed at groq: its answer had no text." },
    };
    for (cases, 1..) |cs, n| {
        try sttScript(&e, @intCast(n), cs.script);
        try t.expectError(cs.err, tr.transcribe(a, "x", "voice.ogg", null));
        const said = tr.failure(a, cs.err);
        try t.expectEqualStrings(cs.said, said);
        // the key is never kept or said
        try t.expect(std.mem.indexOf(u8, said, "gsk-test-key-1") == null);
    }
    // a 429 is not tried again: one request each
    try t.expect(e.tmp.dir.statFile(t.io, "transcribe-requests/006.json", .{}) != error.FileNotFound);
    try t.expectError(error.FileNotFound, e.tmp.dir.statFile(t.io, "transcribe-requests/007.json", .{}));
    // no key where one is needed, no url: refused before anything is sent
    var no_key = try transcriber(&e, .bearer, "");
    try t.expectError(error.NoKey, no_key.transcribe(a, "x", "voice.ogg", null));
    try t.expectEqualStrings("Voice notes are refused: no groq key is stored (harness secret add groq).", no_key.failure(a, error.NoKey));
    var no_url = try transcriber(&e, .bearer, "k");
    no_url.provider.url = "";
    try t.expectError(error.NoUrl, no_url.transcribe(a, "x", "voice.ogg", null));
    try t.expectEqualStrings("Voice notes are refused: no groq url is set ([provider groq] url in config.ini, then /reload).", no_url.failure(a, error.NoUrl));
    try t.expectError(error.FileNotFound, e.tmp.dir.statFile(t.io, "transcribe-requests/007.json", .{}));
    // a local server that takes no key: none sent
    try sttScript(&e, 7, "{\"text\":\"ok\"}");
    var local = try transcriber(&e, .none, "");
    try t.expectEqualStrings("ok", try local.transcribe(a, "x", "voice.ogg", null));
    const req = try sttRequest(&e, 7);
    try t.expect(jv.at(req, &.{ "headers", "Authorization" }) == null);
    try t.expect(jv.at(req, &.{ "headers", "x-api-key" }) == null);
}

test "speaker_posts_json_and_returns_audio" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var sp: Speaker = .{ .gpa = t.allocator, .io = t.io, .provider = try e.provider("tts", .openai, .bearer, "sk-speech-key-1"), .model = "tts-1", .voice = "onyx" };
    const audio = try sp.speak(a, "Three flats match.", null);
    try t.expectEqualStrings("ID3Three flats match.", audio);
    const text = try e.tmp.dir.readFileAlloc(t.io, "speech-requests/001.json", a, .unlimited);
    const req = jv.parse(a, text).?;
    try t.expectEqualStrings("/v1/audio/speech", jv.str(jv.get(req, "target")).?);
    try t.expectEqualStrings("Bearer sk-speech-key-1", jv.str(jv.at(req, &.{ "headers", "Authorization" })).?);
    const body = jv.parse(a, jv.str(jv.get(req, "body")).?).?;
    try t.expectEqualStrings("tts-1", jv.str(jv.get(body, "model")).?);
    try t.expectEqualStrings("Three flats match.", jv.str(jv.get(body, "input")).?);
    try t.expectEqualStrings("onyx", jv.str(jv.get(body, "voice")).?);
    try t.expectEqualStrings("mp3", jv.str(jv.get(body, "response_format")).?);
    // no key: nothing sent
    var none: Speaker = .{ .gpa = t.allocator, .io = t.io, .provider = try e.provider("tts", .openai, .bearer, ""), .model = "tts-1", .voice = "onyx" };
    try t.expectError(error.NoKey, none.speak(a, "x", null));
}

test "a_note_name_follows_its_kind_and_type" {
    try t.expectEqualStrings("voice.ogg", fileName(.{ .file_id = "x", .mime = "audio/ogg" }));
    try t.expectEqualStrings("audio.mp3", fileName(.{ .kind = .audio, .file_id = "x", .name = "Memo 12.MP3" }));
    try t.expectEqualStrings("audio.m4a", fileName(.{ .kind = .audio, .file_id = "x", .name = "memo", .mime = "audio/x-m4a" }));
    try t.expectEqualStrings("audio.ogg", fileName(.{ .kind = .audio, .file_id = "x", .name = "a.opus" }));
    try t.expectEqualStrings("audio.wav", fileName(.{ .kind = .audio, .file_id = "x", .mime = "audio/wav" }));
    // nothing to go by: the most common
    try t.expectEqualStrings("audio.mp3", fileName(.{ .kind = .audio, .file_id = "x" }));
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("0:04", (Note{ .file_id = "x", .seconds = 4 }).length(&buf));
    try t.expectEqualStrings("2:15", (Note{ .file_id = "x", .seconds = 135 }).length(&buf));
}

test "the_quoted_line_is_one_line" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("\"turn the heating up a bit in the living room\"", try quoted(a, "turn the heating up a bit in the living room"));
    try t.expectEqualStrings("\"one. two three\"", try quoted(a, "  one.\n\ttwo   three \r\n"));
    try t.expectEqualStrings("\"\"", try quoted(a, " \n "));
}

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
    /// A speech answer had no audio harness can play.
    NoAudio,
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

/// What a provider read aloud: the bytes, and what they are.
pub const Audio = struct { bytes: []const u8, content_type: []const u8 };

/// A kind's speech model and voice, when `[desk]` names none (checked
/// 2026-11-25).
pub const SpeakDefaults = struct { model: []const u8, voice: []const u8 };

pub fn speakDefaults(api: model.Api) ?SpeakDefaults {
    return switch (api) {
        .openai => .{ .model = "tts-1", .voice = "alloy" },
        // Schedar ("Even"): a steady, unhurried voice for the butler
        .gemini => .{ .model = "gemini-3.8-flash-lite-tts", .voice = "Schedar" },
        .anthropic => null,
    };
}

/// The desk's voice, fetched by harness so the key never reaches the page:
/// - api = openai: `POST {url}/audio/speech`
///   (`{"model","input","voice","response_format":"mp3"}`), MP3 back;
/// - api = gemini: `POST {url}/models/MODEL:generateContent` with audio out
///   and a prebuilt voice; the answer's inline audio as WAV (Gemini 3.8
///   sends WAV, older models raw 16-bit PCM, which is wrapped here).
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
    /// The most of a Gemini answer read (its audio is base64 in JSON).
    pub const max_answer = 16 << 20;

    /// `text` read aloud, in `a`.
    pub fn speak(sp: *Speaker, a: std.mem.Allocator, text: []const u8, stop: ?*const std.atomic.Value(bool)) Error!Audio {
        sp.last_error_len = 0;
        const p = sp.provider;
        if (p.url.len == 0) return error.NoUrl;
        if (!p.hasKey()) return error.NoKey;
        var target = try http.Target.parse(p.url);
        target.prefix = model.Client.urlPath(p.url);
        var client = http.Client.init(sp.gpa, sp.io, target);
        defer client.deinit();
        var body: std.ArrayList(u8) = .empty;
        const path: []const u8 = switch (p.api) {
            .openai => blk: {
                try body.appendSlice(a, "{\"model\":");
                try util.jsonString(&body, a, sp.model);
                try body.appendSlice(a, ",\"input\":");
                try util.jsonString(&body, a, text);
                try body.appendSlice(a, ",\"voice\":");
                try util.jsonString(&body, a, sp.voice);
                try body.appendSlice(a, ",\"response_format\":\"mp3\"}");
                break :blk "/audio/speech";
            },
            .gemini => blk: {
                try body.appendSlice(a, "{\"contents\":[{\"parts\":[{\"text\":");
                try util.jsonString(&body, a, text);
                try body.appendSlice(a, "}]}],\"generationConfig\":{\"responseModalities\":[\"AUDIO\"],\"speechConfig\":{\"voiceConfig\":{\"prebuiltVoiceConfig\":{\"voiceName\":");
                try util.jsonString(&body, a, sp.voice);
                try body.appendSlice(a, "}}}}}");
                break :blk try std.fmt.allocPrint(a, "/models/{s}:generateContent", .{try pathSegment(a, sp.model)});
            },
            // config.ini lets no Anthropic-format provider speak
            .anthropic => return error.Rejected,
        };
        var hs: [model.max_headers + 1]std.http.Header = undefined;
        var n: usize = 0;
        if (model.keyHeader(p.auth)) |name| {
            hs[n] = .{ .name = name, .value = p.key };
            n += 1;
        }
        for (p.headers[0..@min(p.headers.len, model.max_headers)]) |h| {
            hs[n] = h;
            n += 1;
        }
        var resp = client.send(.{
            .path = path,
            .body = body.items,
            .content_type = "application/json",
            .accept = if (p.api == .gemini) "application/json" else "audio/mpeg",
            .key = if (p.auth == .bearer) p.key else null,
            .headers = hs[0..n],
            .resend = false,
            .limits = .{ .idle_ms = @min(60_000, sp.call_ms), .total_ms = sp.call_ms, .stop = stop },
        }) catch |e| return if (Transcriber.stopped(stop)) error.Stopped else e;
        defer resp.deinit();
        const got = resp.readAll(a, if (p.api == .gemini) max_answer else max_audio) catch |e| return if (Transcriber.stopped(stop)) error.Stopped else e;
        if (Transcriber.stopped(stop)) return error.Stopped;
        if (resp.status != 200) return sp.statusError(resp.status, got);
        if (p.api == .gemini) return sp.geminiAudio(a, got);
        return .{ .bytes = got, .content_type = "audio/mpeg" };
    }

    /// An error status as every kind says it.
    fn statusError(sp: *Speaker, status: u16, got: []const u8) Error {
        switch (status) {
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

    /// The audio of a Gemini answer: its first WAV part as it is, else
    /// its raw PCM parts joined and wrapped as WAV; none: NoAudio, with
    /// Google's reason when it gave one.
    fn geminiAudio(sp: *Speaker, a: std.mem.Allocator, got: []const u8) Error!Audio {
        const v = jv.parse(a, got) orelse return error.NoAudio;
        var pcm: std.ArrayList(u8) = .empty;
        var rate: u32 = 24000;
        for (jv.arr(jv.at(v, &.{ "candidates", "0", "content", "parts" })) orelse &.{}) |part| {
            const data = jv.get(part, "inlineData") orelse continue;
            const mime = jv.str(jv.get(data, "mimeType")) orelse "";
            const bytes = try base64(a, jv.str(jv.get(data, "data")) orelse continue) orelse continue;
            if (bytes.len == 0) continue;
            if (isWav(bytes)) {
                if (pcm.items.len == 0) return .{ .bytes = bytes, .content_type = "audio/wav" };
                continue;
            }
            if (std.ascii.startsWithIgnoreCase(mime, "audio/l16") or std.ascii.startsWithIgnoreCase(mime, "audio/pcm")) {
                if (pcm.items.len == 0) rate = pcmRate(mime);
                try pcm.appendSlice(a, bytes);
            }
        }
        if (pcm.items.len >= 2) return .{ .bytes = try wav(a, pcm.items, rate), .content_type = "audio/wav" };
        if (jv.str(jv.at(v, &.{ "candidates", "0", "finishReason" }))) |r| {
            sp.say("finishReason {s}", .{r});
        } else if (jv.str(jv.at(v, &.{ "promptFeedback", "blockReason" }))) |r| sp.say("blockReason {s}", .{r});
        return error.NoAudio;
    }

    fn say(sp: *Speaker, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&sp.last_error, fmt, args) catch sp.last_error[0..];
        sp.last_error_len = s.len;
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
            error.NoAudio => if (msg.len > 0) std.fmt.allocPrint(a, "Speech failed at {s}: its answer had no audio ({s}).", .{ p, msg }) else std.fmt.allocPrint(a, "Speech failed at {s}: its answer had no audio.", .{p}),
            else => if (msg.len > 0) std.fmt.allocPrint(a, "Speech failed at {s}: {s} {s}", .{ p, @errorName(e), msg }) else std.fmt.allocPrint(a, "Speech failed at {s}: {s}", .{ p, @errorName(e) }),
        } catch "Speech failed.";
    }
};

/// Whether `bytes` are a WAV file (its RIFF header says so).
fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// `text` decoded as base64 (padded or not, standard or URL-safe); null
/// when it isn't.
fn base64(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]u8 {
    inline for (.{ std.base64.standard.Decoder, std.base64.standard_no_pad.Decoder, std.base64.url_safe.Decoder, std.base64.url_safe_no_pad.Decoder }) |d| {
        if (d.calcSizeForSlice(text)) |size| {
            const out = try a.alloc(u8, size);
            if (d.decode(out, text)) |_| return out else |_| {}
        } else |_| {}
    }
    return null;
}

/// Raw 16-bit little-endian mono PCM at `rate` as a WAV file (a 44-byte
/// header); half a sample at the end is dropped.
pub fn wav(a: std.mem.Allocator, pcm: []const u8, rate: u32) error{OutOfMemory}![]u8 {
    // at most Speaker.max_answer is read: it fits
    const n: u32 = @intCast(pcm.len & ~@as(usize, 1));
    const out = try a.alloc(u8, 44 + n);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + n, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 1, .little); // mono
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * 2, .little);
    std.mem.writeInt(u16, out[32..34], 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], n, .little);
    @memcpy(out[44..], pcm[0..n]);
    return out;
}

/// The sample rate a raw PCM type names (`audio/L16;codec=pcm;rate=24000`);
/// 24000 when it names none, or one outside 8000 to 96000.
pub fn pcmRate(mime: []const u8) u32 {
    var it = std.mem.splitScalar(u8, mime, ';');
    _ = it.next();
    while (it.next()) |param| {
        const kv = std.mem.trim(u8, param, " \t");
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, kv[0..eq], " \t"), "rate")) continue;
        const r = std.fmt.parseInt(u32, std.mem.trim(u8, kv[eq + 1 ..], " \t\""), 10) catch return 24000;
        return if (r >= 8000 and r <= 96000) r else 24000;
    }
    return 24000;
}

/// `s` as one segment of a URL path: every byte but A-Z a-z 0-9 - . _ ~
/// percent-encoded.
fn pathSegment(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try out.append(a, ch);
        } else try out.print(a, "%{X:0>2}", .{ch});
    }
    return out.items;
}

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
    try t.expectEqualStrings("ID3Three flats match.", audio.bytes);
    try t.expectEqualStrings("audio/mpeg", audio.content_type);
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

fn gemSpeaker(e: *model.TestEnv, auth: model.Auth, key: []const u8) !Speaker {
    var p = try e.provider("gemini", .gemini, auth, key);
    p.url = try std.fmt.allocPrint(e.arena.allocator(), "{s}/v1beta", .{try e.url()});
    return .{ .gpa = t.allocator, .io = t.io, .provider = p, .model = "gemini-3.8-flash-lite-tts", .voice = "Schedar" };
}

fn gemScript(e: *model.TestEnv, n: u32, body: []const u8) !void {
    const name = try std.fmt.allocPrint(e.arena.allocator(), "gemini/{d:0>3}.json", .{n});
    try e.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = body });
}

fn gemRequest(e: *model.TestEnv, n: u32) !jv.Value {
    const name = try std.fmt.allocPrint(e.arena.allocator(), "gemini-requests/{d:0>3}.json", .{n});
    const text = try e.tmp.dir.readFileAlloc(t.io, name, e.arena.allocator(), .unlimited);
    return jv.parse(e.arena.allocator(), text) orelse error.TestUnexpectedResult;
}

/// An answer of Gemini's with these inline parts (mime type, raw bytes).
fn gemAnswer(a: std.mem.Allocator, parts: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"answer\":{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[");
    for (parts, 0..) |p, i| {
        if (i > 0) try out.append(a, ',');
        const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(p[1].len));
        try out.print(a, "{{\"inlineData\":{{\"mimeType\":\"{s}\",\"data\":\"{s}\"}}}}", .{ p[0], std.base64.standard.Encoder.encode(b64, p[1]) });
    }
    try out.appendSlice(a, "]},\"finishReason\":\"STOP\"}]}}");
    return out.items;
}

test "gemini_speech_posts_generate_content_and_wraps_pcm_as_wav" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var sp = try gemSpeaker(&e, .x_goog_api_key, "gm-test-key-1");
    const got = try sp.speak(a, "Three flats match.", null);
    try t.expectEqualStrings("audio/wav", got.content_type);
    // the stand-in's PCM is the text's 18 bytes, at 24 kHz
    try t.expectEqual(44 + 18, got.bytes.len);
    try t.expectEqualStrings("RIFF", got.bytes[0..4]);
    try t.expectEqualStrings("WAVE", got.bytes[8..12]);
    try t.expectEqual(24000, std.mem.readInt(u32, got.bytes[24..28], .little));
    try t.expectEqualStrings("Three flats match.", got.bytes[44..]);
    const req = try gemRequest(&e, 1);
    try t.expectEqualStrings("/v1beta/models/gemini-3.8-flash-lite-tts:generateContent", jv.str(jv.get(req, "target")).?);
    try t.expectEqualStrings("gm-test-key-1", jv.str(jv.at(req, &.{ "headers", "x-goog-api-key" })).?);
    try t.expect(jv.at(req, &.{ "headers", "Authorization" }) == null);
    try t.expectEqualStrings(
        "{\"contents\":[{\"parts\":[{\"text\":\"Three flats match.\"}]}],\"generationConfig\":{\"responseModalities\":[\"AUDIO\"],\"speechConfig\":{\"voiceConfig\":{\"prebuiltVoiceConfig\":{\"voiceName\":\"Schedar\"}}}}}",
        jv.str(jv.get(req, "body")).?,
    );
}

test "gemini_wav_passes_through_and_pcm_is_wrapped" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var sp = try gemSpeaker(&e, .x_goog_api_key, "gm-test-key-1");
    // Gemini 3.8's own WAV: as it came, never wrapped twice
    try gemScript(&e, 1, "{\"mime\":\"audio/wav\"}");
    const w = try sp.speak(a, "One.", null);
    try t.expectEqualStrings("audio/wav", w.content_type);
    try t.expectEqual(44 + 4, w.bytes.len);
    try t.expectEqual(1, std.mem.count(u8, w.bytes, "RIFF"));
    try t.expectEqualStrings("One.", w.bytes[44..]);
    // older models' raw PCM in two parts at 16 kHz: joined, then wrapped
    try gemScript(&e, 2, try gemAnswer(a, &.{ .{ "audio/L16;codec=pcm;rate=16000", "ab" }, .{ "audio/L16;codec=pcm;rate=16000", "cd" } }));
    const p = try sp.speak(a, "x", null);
    try t.expectEqualStrings("abcd", p.bytes[44..]);
    try t.expectEqual(16000, std.mem.readInt(u32, p.bytes[24..28], .little));
    try t.expectEqual(1, std.mem.count(u8, p.bytes, "RIFF"));
    // a WAV said to be something else is still known by its header
    const riff = "RIFF\x28\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\xc0\x5d\x00\x00\x80\xbb\x00\x00\x02\x00\x10\x00data\x04\x00\x00\x00wxyz";
    try gemScript(&e, 3, try gemAnswer(a, &.{.{ "application/octet-stream", riff }}));
    try t.expectEqualStrings(riff, (try sp.speak(a, "x", null)).bytes);
}

test "gemini_without_audio_says_why" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var sp = try gemSpeaker(&e, .x_goog_api_key, "gm-test-key-1");
    const Case = struct { script: []const u8, said: []const u8 };
    const cases = [_]Case{
        .{ .script = "{\"answer\":{\"candidates\":[{\"finishReason\":\"OTHER\"}]}}", .said = "Speech failed at gemini: its answer had no audio (finishReason OTHER)." },
        .{ .script = "{\"answer\":{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}}", .said = "Speech failed at gemini: its answer had no audio (blockReason SAFETY)." },
        .{ .script = "{\"answer\":{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"I can't.\"}]},\"finishReason\":\"STOP\"}]}}", .said = "Speech failed at gemini: its answer had no audio (finishReason STOP)." },
        .{ .script = "{\"answer\":{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"audio/L16;rate=24000\",\"data\":\"!!!\"}}]}}]}}", .said = "Speech failed at gemini: its answer had no audio." },
        .{ .script = "{\"answer\":{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"audio/mulaw\",\"data\":\"AAAA\"}}]}}]}}", .said = "Speech failed at gemini: its answer had no audio." },
        .{ .script = "{\"answer\":{\"candidates\":[]}}", .said = "Speech failed at gemini: its answer had no audio." },
    };
    for (cases, 1..) |cs, n| {
        try gemScript(&e, @intCast(n), cs.script);
        try t.expectError(error.NoAudio, sp.speak(a, "x", null));
        try t.expectEqualStrings(cs.said, sp.failure(a, error.NoAudio));
    }
}

test "gemini_errors_are_said_in_the_providers_words" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var sp = try gemSpeaker(&e, .x_goog_api_key, "gm-test-key-1");
    const Case = struct { script: []const u8, err: anyerror, said: []const u8 };
    const cases = [_]Case{
        .{ .script = "{\"status\":401,\"echo_key\":true}", .err = error.KeyRefused, .said = "gemini refused the key stored as gemini." },
        .{ .script = "{\"status\":403}", .err = error.KeyRefused, .said = "gemini refused the key stored as gemini." },
        .{ .script = "{\"status\":402}", .err = error.BudgetSpent, .said = "Speech budget used up at gemini." },
        .{ .script = "{\"status\":429}", .err = error.RateLimited, .said = "Speech is rate limited at gemini; try again later." },
        .{ .script = "{\"status\":400}", .err = error.Rejected, .said = "Speech failed at gemini: Rejected scripted error" },
        .{ .script = "{\"status\":500}", .err = error.Upstream, .said = "Speech failed at gemini: Upstream scripted error" },
    };
    for (cases, 1..) |cs, n| {
        try gemScript(&e, @intCast(n), cs.script);
        try t.expectError(cs.err, sp.speak(a, "x", null));
        const said = sp.failure(a, cs.err);
        try t.expectEqualStrings(cs.said, said);
        try t.expect(std.mem.indexOf(u8, said, "gm-test-key-1") == null);
        // Google said the key back: kept masked
        if (n == 1) try t.expectEqualStrings("scripted error for key [secret:gemini]", sp.last_error[0..sp.last_error_len]);
    }
    // one request each: a 429 is not tried again
    try t.expect(e.tmp.dir.statFile(t.io, "gemini-requests/006.json", .{}) != error.FileNotFound);
    try t.expectError(error.FileNotFound, e.tmp.dir.statFile(t.io, "gemini-requests/007.json", .{}));
    // no key: refused before anything is sent
    var none = try gemSpeaker(&e, .x_goog_api_key, "");
    try t.expectError(error.NoKey, none.speak(a, "x", null));
    try t.expectEqualStrings("No gemini key is stored (harness secret add gemini).", none.failure(a, error.NoKey));
    try t.expectError(error.FileNotFound, e.tmp.dir.statFile(t.io, "gemini-requests/007.json", .{}));
}

test "gemini_takes_auth_and_headers_as_its_section_says" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    // a gateway that takes a bearer token, with a header of its own
    var bearer = try gemSpeaker(&e, .bearer, "gw-test-key-1");
    bearer.provider.headers = &.{.{ .name = "X-Gateway", .value = "desk" }};
    _ = try bearer.speak(a, "x", null);
    const r1 = try gemRequest(&e, 1);
    try t.expectEqualStrings("Bearer gw-test-key-1", jv.str(jv.at(r1, &.{ "headers", "Authorization" })).?);
    try t.expect(jv.at(r1, &.{ "headers", "x-goog-api-key" }) == null);
    try t.expectEqualStrings("desk", jv.str(jv.at(r1, &.{ "headers", "X-Gateway" })).?);
    // a local server that takes no key: none sent
    var local = try gemSpeaker(&e, .none, "");
    _ = try local.speak(a, "x", null);
    const r2 = try gemRequest(&e, 2);
    try t.expect(jv.at(r2, &.{ "headers", "Authorization" }) == null);
    try t.expect(jv.at(r2, &.{ "headers", "x-goog-api-key" }) == null);
}

test "a_model_name_is_one_path_segment" {
    var e: model.TestEnv = undefined;
    try e.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var sp = try gemSpeaker(&e, .x_goog_api_key, "gm-test-key-1");
    sp.model = "a b/c";
    _ = try sp.speak(a, "x", null);
    try t.expectEqualStrings("/v1beta/models/a%20b%2Fc:generateContent", jv.str(jv.get(try gemRequest(&e, 1), "target")).?);
}

test "wav_header_is_mono_16_bit" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "RIFF\x28\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\xc0\x5d\x00\x00\x80\xbb\x00\x00\x02\x00\x10\x00data\x04\x00\x00\x00\x01\x02\x03\x04",
        try wav(a, "\x01\x02\x03\x04", 24000),
    );
    // half a sample at the end: dropped
    const odd = try wav(a, "\x01\x02\x03", 24000);
    try t.expectEqual(44 + 2, odd.len);
    try t.expectEqual(2, std.mem.readInt(u32, odd[40..44], .little));
    try t.expectEqual(38, std.mem.readInt(u32, odd[4..8], .little));
}

test "pcm_rate_reads_the_mime_type" {
    try t.expectEqual(16000, pcmRate("audio/L16;codec=pcm;rate=16000"));
    try t.expectEqual(8000, pcmRate("audio/l16; RATE=8000"));
    try t.expectEqual(24000, pcmRate("audio/L16"));
    try t.expectEqual(24000, pcmRate("audio/L16;rate=5"));
    try t.expectEqual(24000, pcmRate("audio/L16;rate=fast"));
    try t.expectEqual(48000, pcmRate("audio/pcm;rate=48000;codec=pcm"));
}

test "speak_defaults_per_kind" {
    try t.expectEqualStrings("tts-1", speakDefaults(.openai).?.model);
    try t.expectEqualStrings("alloy", speakDefaults(.openai).?.voice);
    try t.expectEqualStrings("gemini-3.8-flash-lite-tts", speakDefaults(.gemini).?.model);
    try t.expectEqualStrings("Schedar", speakDefaults(.gemini).?.voice);
    try t.expect(speakDefaults(.anthropic) == null);
}

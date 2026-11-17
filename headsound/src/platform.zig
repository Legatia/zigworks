//! What depends on the operating system: decoding files other than WAV, the
//! microphone (macOS, through Core Audio) and the sound classifier (macOS,
//! SoundAnalysis).
const std = @import("std");
const builtin = @import("builtin");
const Audio = @import("audio.zig").Audio;

pub const is_mac = builtin.os.tag == .macos;

const c = struct {
    extern fn hsnd_decode(path: [*:0]const u8, out: *?[*]f32, frames: *c_longlong, rate: *c_int, channels: *c_int, codec: [*]u8, codec_len: c_int) c_int;
    extern fn hsnd_free(p: ?*anyopaque) void;
    extern fn hsnd_host_app(buf: [*]u8, len: c_int) c_int;
    extern fn hsnd_mic_access() c_int;
    extern fn hsnd_listen(rate: f64, sink: *const fn (?*anyopaque, [*]const f32, c_int) callconv(.c) c_int, ctx: ?*anyopaque, max_ms: c_int) c_int;
    extern fn hsnd_classify(samples: [*]const f32, frames: c_longlong, rate: f64, window_s: f64, floor: f64, sink: *const fn (?*anyopaque, f64, f64, [*:0]const u8, f64) callconv(.c) void, ctx: ?*anyopaque) c_int;
    extern fn hsnd_speech_access() c_int;
    extern fn hsnd_transcribe(samples: [*]const f32, frames: c_longlong, rate: f64, locale: ?[*:0]const u8, used: [*]u8, used_len: c_int, sink: *const fn (?*anyopaque, [*:0]const u8, f64, f64, f64, c_int) callconv(.c) void, ctx: ?*anyopaque) c_int;
    extern fn hsnd_class_names(sink: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, ctx: ?*anyopaque) c_int;
};

const OK = 0;
const UNSUPPORTED = 1;
const PERMISSION = 3;
const NO_HOST = 4;
const NO_INPUT = 5;
const UNANSWERED = 6;

pub const Decoded = struct { audio: Audio, codec: []const u8 };

/// Decodes a file Core Audio can read (AAC/m4a, MP3, ALAC, FLAC, AIFF, CAF...).
/// error.UnsupportedFormat where there is no such decoder (Linux).
pub fn decode(alloc: std.mem.Allocator, path: []const u8, codec_buf: []u8) !Decoded {
    if (!is_mac) return error.UnsupportedFormat;
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    var ptr: ?[*]f32 = null;
    var frames: c_longlong = 0;
    var rate: c_int = 0;
    var channels: c_int = 0;
    const rc = c.hsnd_decode(z, &ptr, &frames, &rate, &channels, codec_buf.ptr, @intCast(codec_buf.len));
    if (rc == UNSUPPORTED) return error.UnsupportedFormat;
    if (rc != OK) return error.DecodeFailed;
    defer c.hsnd_free(ptr);
    const n: usize = @intCast(frames * channels);
    const samples = try alloc.alloc(f32, n);
    if (n > 0) @memcpy(samples, ptr.?[0..n]);
    return .{
        .audio = .{ .rate = @intCast(rate), .channels = @intCast(channels), .samples = samples },
        .codec = std.mem.sliceTo(codec_buf, 0),
    };
}

pub fn hostApp(buf: []u8) ?[]const u8 {
    if (!is_mac) return null;
    if (c.hsnd_host_app(buf.ptr, @intCast(buf.len)) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

/// unanswered: macOS asked and nobody answered in two minutes.
pub const Access = enum { granted, denied, no_host, unanswered };

/// Microphone permission; asks the first time.
pub fn micAccess() Access {
    if (!is_mac) return .denied;
    return switch (c.hsnd_mic_access()) {
        OK => .granted,
        NO_HOST => .no_host,
        UNANSWERED => .unanswered,
        else => .denied,
    };
}

/// Records mono at `rate` and calls `sink.feed([]const f32) bool` (true:
/// stop) until it says stop or `max_ms` passes.
pub fn listen(rate: u32, sink: anytype, max_ms: u32) !void {
    if (!is_mac) return error.NoMicrophone;
    const S = @TypeOf(sink.*);
    const tramp = struct {
        fn f(ctx: ?*anyopaque, x: [*]const f32, n: c_int) callconv(.c) c_int {
            const s: *S = @ptrCast(@alignCast(ctx.?));
            return @intFromBool(s.feed(x[0..@intCast(n)]));
        }
    }.f;
    switch (c.hsnd_listen(@floatFromInt(rate), &tramp, sink, @intCast(max_ms))) {
        OK => {},
        NO_INPUT => return error.NoMicrophone,
        PERMISSION => return error.AccessDenied,
        else => return error.Failed,
    }
}

pub const Window = @import("sounds.zig").Window;

/// Apple's sound classifier over mono `x` at `rate`: every class with
/// confidence >= `floor` in each window (strings live in `arena`).
/// error.Unsupported off macOS.
pub fn classify(arena: std.mem.Allocator, x: []const f32, rate: u32, window_s: f64, floor: f64) ![]Window {
    if (!is_mac) return error.Unsupported;
    const Ctx = struct {
        arena: std.mem.Allocator,
        list: std.ArrayList(Window) = .empty,
        oom: bool = false,
        fn f(ctx: ?*anyopaque, start: f64, dur: f64, label: [*:0]const u8, conf: f64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const l = self.arena.dupe(u8, std.mem.span(label)) catch {
                self.oom = true;
                return;
            };
            self.list.append(self.arena, .{ .start = start, .end = start + dur, .label = l, .confidence = conf }) catch {
                self.oom = true;
            };
        }
    };
    var ctx = Ctx{ .arena = arena };
    if (c.hsnd_classify(x.ptr, @intCast(x.len), @floatFromInt(rate), window_s, floor, &Ctx.f, &ctx) != OK) return error.ClassifierFailed;
    if (ctx.oom) return error.OutOfMemory;
    return ctx.list.items;
}

/// The names of every class the classifier knows.
pub fn classNames(arena: std.mem.Allocator) ![]const []const u8 {
    if (!is_mac) return error.Unsupported;
    const Ctx = struct {
        arena: std.mem.Allocator,
        list: std.ArrayList([]const u8) = .empty,
        fn f(ctx: ?*anyopaque, label: [*:0]const u8) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const l = self.arena.dupe(u8, std.mem.span(label)) catch return;
            self.list.append(self.arena, l) catch {};
        }
    };
    var ctx = Ctx{ .arena = arena };
    if (c.hsnd_class_names(&Ctx.f, &ctx) != OK) return error.ClassifierFailed;
    return ctx.list.items;
}

/// Speech recognition permission; asks the first time.
pub fn speechAccess() Access {
    if (!is_mac) return .denied;
    return switch (c.hsnd_speech_access()) {
        OK => .granted,
        NO_HOST => .no_host,
        UNANSWERED => .unanswered,
        else => .denied,
    };
}

pub const Word = @import("transcript.zig").Word;

/// Words said in mono `x`, recognised on this Mac (strings in `arena`),
/// times from the start of `x`. `locale` null: the user's language; the one
/// used goes to `used`. error.NoRecognizer: none on this Mac for it;
/// error.Unsupported off macOS.
pub fn transcribe(arena: std.mem.Allocator, x: []const f32, rate: u32, locale: ?[]const u8, used: []u8) ![]Word {
    if (!is_mac) return error.Unsupported;
    const Ctx = struct {
        arena: std.mem.Allocator,
        list: std.ArrayList(Word) = .empty,
        oom: bool = false,
        fn f(ctx: ?*anyopaque, text: [*:0]const u8, start: f64, dur: f64, conf: f64, space: c_int) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const t = self.arena.dupe(u8, std.mem.span(text)) catch {
                self.oom = true;
                return;
            };
            self.list.append(self.arena, .{ .text = t, .start = start, .end = start + dur, .confidence = conf, .space_before = space != 0 }) catch {
                self.oom = true;
            };
        }
    };
    var ctx = Ctx{ .arena = arena };
    const z: ?[:0]u8 = if (locale) |l| try arena.dupeZ(u8, l) else null;
    @memset(used, 0);
    const rc = c.hsnd_transcribe(x.ptr, @intCast(x.len), @floatFromInt(rate), if (z) |v| v.ptr else null, used.ptr, @intCast(used.len), &Ctx.f, &ctx);
    switch (rc) {
        OK => {},
        UNSUPPORTED => return error.NoRecognizer,
        PERMISSION => return error.SpeechDenied,
        else => return error.TranscribeFailed,
    }
    if (ctx.oom) return error.OutOfMemory;
    return ctx.list.items;
}

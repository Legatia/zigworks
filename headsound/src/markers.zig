//! Markers for audio editors: cue points inside a WAV file (cue + LIST/adtl
//! labl/ltxt, read by GoldWave, Audition, Sound Forge, WaveLab, Reaper), an
//! Audacity label track (.txt), and a CD cue sheet (.cue, GoldWave's Cue
//! Points > Import).
const std = @import("std");
const wav = @import("wav.zig");

pub const Marker = struct {
    /// Frames from the start of the file.
    start: u64,
    /// Frames; 0 for a point.
    length: u64 = 0,
    name: []const u8,
};

const Cue = struct { id: u32, offset: u32, name: []const u8 = "", length: u32 = 0 };

/// What a WAV already holds: its cue points (parsed, and each 24-byte entry
/// as it was) and every subchunk of its adtl lists as it was.
const Existing = struct {
    cues: std.ArrayList(Cue) = .empty,
    raw_cues: std.ArrayList([]const u8) = .empty,
    raw_adtl: std.ArrayList([]const u8) = .empty,

    fn deinit(e: *Existing, alloc: std.mem.Allocator) void {
        e.cues.deinit(alloc);
        e.raw_cues.deinit(alloc);
        e.raw_adtl.deinit(alloc);
    }
};

/// The markers already in WAV `bytes` (from its cue and adtl chunks).
pub fn read(alloc: std.mem.Allocator, bytes: []const u8) ![]Marker {
    var ex = Existing{};
    defer ex.deinit(alloc);
    try parse(alloc, bytes, &ex);
    const out = try alloc.alloc(Marker, ex.cues.items.len);
    for (ex.cues.items, out) |c, *m| m.* = .{ .start = c.offset, .length = c.length, .name = c.name };
    return out;
}

/// Calls `f(ctx, id, body, whole)` for each chunk in `bytes[from..]`: `body`
/// is clamped to the bytes there, `whole` is the header, body and pad.
fn chunks(bytes: []const u8, from: usize, ctx: anytype, comptime f: anytype) !void {
    var pos = from;
    while (pos + 8 <= bytes.len) {
        const size: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const end = @min(bytes.len, pos + 8 +| size);
        const next = @min(bytes.len, end +| (size & 1));
        try f(ctx, bytes[pos..][0..4], bytes[pos + 8 .. end], bytes[pos..next], size);
        pos = pos + 8 +| size +| (size & 1);
    }
}

fn parse(alloc: std.mem.Allocator, bytes: []const u8, ex: *Existing) !void {
    if (!wav.isWav(bytes)) return error.NotWav;
    const C = struct { alloc: std.mem.Allocator, ex: *Existing };
    const top = struct {
        fn f(c: C, id: *const [4]u8, body: []const u8, _: []const u8, _: usize) !void {
            if (std.mem.eql(u8, id, "cue ") and body.len >= 4) {
                const n = std.mem.readInt(u32, body[0..4], .little);
                var i: usize = 0;
                while (i < n and 4 + (i + 1) * 24 <= body.len) : (i += 1) {
                    const p = body[4 + i * 24 ..][0..24];
                    try c.ex.raw_cues.append(c.alloc, p);
                    try c.ex.cues.append(c.alloc, .{ .id = std.mem.readInt(u32, p[0..4], .little), .offset = std.mem.readInt(u32, p[20..24], .little) });
                }
            } else if (std.mem.eql(u8, id, "LIST") and body.len >= 4 and std.mem.eql(u8, body[0..4], "adtl")) {
                try chunks(body, 4, c, sub);
            }
        }
        fn sub(c: C, id: *const [4]u8, body: []const u8, whole: []const u8, _: usize) !void {
            try c.ex.raw_adtl.append(c.alloc, whole);
            if (body.len < 4) return;
            const cue_id = std.mem.readInt(u32, body[0..4], .little);
            for (c.ex.cues.items) |*q| if (q.id == cue_id) {
                if (std.mem.eql(u8, id, "labl")) {
                    q.name = std.mem.sliceTo(body[4..], 0);
                } else if (std.mem.eql(u8, id, "ltxt") and body.len >= 8) {
                    q.length = std.mem.readInt(u32, body[4..8], .little);
                }
            };
        }
    };
    // the cue chunk first: adtl lists may come before it
    try chunks(bytes, 12, C{ .alloc = alloc, .ex = ex }, struct {
        fn f(c: C, id: *const [4]u8, body: []const u8, whole: []const u8, size: usize) !void {
            if (std.mem.eql(u8, id, "cue ")) try top.f(c, id, body, whole, size);
        }
    }.f);
    try chunks(bytes, 12, C{ .alloc = alloc, .ex = ex }, struct {
        fn f(c: C, id: *const [4]u8, body: []const u8, whole: []const u8, size: usize) !void {
            if (!std.mem.eql(u8, id, "cue ")) try top.f(c, id, body, whole, size);
        }
    }.f);
}

/// `bytes` (a WAV file) with `add` appended to its markers. The audio and
/// every other chunk are copied unchanged; the cue points, labels and notes
/// already there are kept as they were. Positions are frames, so they must
/// fit in 32 bits (any WAV under 4 GB).
pub fn addToWav(alloc: std.mem.Allocator, bytes: []const u8, add: []const Marker) ![]u8 {
    var ex = Existing{};
    defer ex.deinit(alloc);
    try parse(alloc, bytes, &ex);
    const ids = try alloc.alloc(u32, add.len);
    defer alloc.free(ids);
    // new ids: after the largest, or (if that would wrap) the lowest free ones
    var next: u32 = 1;
    for (ex.cues.items) |c| next = @max(next, c.id +| 1);
    for (ids) |*id| {
        while (next == std.math.maxInt(u32) or used(ex.cues.items, ids[0 .. id - ids.ptr], next)) next = if (next == std.math.maxInt(u32)) 1 else next + 1;
        id.* = next;
        next += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, bytes[0..12]);
    // Every chunk but the old cue chunk and adtl lists, as it was; a chunk
    // cut short gets its real size, and an odd one its pad byte.
    const C = struct { alloc: std.mem.Allocator, out: *std.ArrayList(u8) };
    try chunks(bytes, 12, C{ .alloc = alloc, .out = &out }, struct {
        fn f(c: C, id: *const [4]u8, body: []const u8, _: []const u8, size: usize) !void {
            if (std.mem.eql(u8, id, "cue ")) return;
            if (std.mem.eql(u8, id, "LIST") and body.len >= 4 and std.mem.eql(u8, body[0..4], "adtl")) return;
            try c.out.appendSlice(c.alloc, id);
            try int(c.alloc, c.out, if (body.len < size) @intCast(body.len) else @intCast(size));
            try c.out.appendSlice(c.alloc, body);
            if (body.len & 1 == 1) try c.out.append(c.alloc, 0);
        }
    }.f);
    // cue chunk: the old entries, then the new
    const n_cues = ex.raw_cues.items.len + add.len;
    try chunkHeader(alloc, &out, "cue ", std.math.cast(u32, 4 + 24 * n_cues) orelse return error.FileTooBig);
    try int(alloc, &out, @intCast(n_cues));
    for (ex.raw_cues.items) |r| try out.appendSlice(alloc, r);
    for (add, ids) |m, id| {
        const off = std.math.cast(u32, m.start) orelse return error.FileTooBig;
        try int(alloc, &out, id);
        try int(alloc, &out, off); // play order position: the offset, as most editors write
        try out.appendSlice(alloc, "data");
        try int(alloc, &out, 0);
        try int(alloc, &out, 0);
        try int(alloc, &out, off);
    }
    // LIST adtl: the old subchunks, then a label for each new one and a
    // length for ranges
    var list_len: usize = 4;
    for (ex.raw_adtl.items) |r| list_len += padded(r.len);
    for (add) |m| {
        list_len += 8 + padded(4 + m.name.len + 1);
        if (m.length > 0) list_len += 8 + 20;
    }
    try chunkHeader(alloc, &out, "LIST", std.math.cast(u32, list_len) orelse return error.FileTooBig);
    try out.appendSlice(alloc, "adtl");
    for (ex.raw_adtl.items) |r| {
        try out.appendSlice(alloc, r);
        if (r.len & 1 == 1) try out.append(alloc, 0);
    }
    for (add, ids) |m, id| {
        const n = 4 + m.name.len + 1;
        try chunkHeader(alloc, &out, "labl", @intCast(n));
        try int(alloc, &out, id);
        try out.appendSlice(alloc, m.name);
        try out.append(alloc, 0);
        if (n & 1 == 1) try out.append(alloc, 0);
        if (m.length > 0) {
            try chunkHeader(alloc, &out, "ltxt", 20);
            try int(alloc, &out, id);
            try int(alloc, &out, std.math.cast(u32, m.length) orelse return error.FileTooBig);
            try out.appendSlice(alloc, "rgn ");
            try out.appendNTimes(alloc, 0, 8); // country, language, dialect, code page
        }
    }
    std.mem.writeInt(u32, out.items[4..8], std.math.cast(u32, out.items.len - 8) orelse return error.FileTooBig, .little);
    return out.toOwnedSlice(alloc);
}

fn used(cues: []const Cue, taken: []const u32, id: u32) bool {
    for (cues) |c| if (c.id == id) return true;
    for (taken) |t| if (t == id) return true;
    return false;
}

fn padded(n: usize) usize {
    return n + (n & 1);
}

fn chunkHeader(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: []const u8, size: u32) !void {
    try out.appendSlice(alloc, id);
    try int(alloc, out, size);
}

fn int(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

/// An Audacity label track: "start<TAB>end<TAB>name" in seconds per line.
pub fn writeLabels(w: *std.Io.Writer, ms: []const Marker, rate: u32) !void {
    const r: f64 = @floatFromInt(rate);
    for (ms) |m| {
        const s = @as(f64, @floatFromInt(m.start)) / r;
        const e = @as(f64, @floatFromInt(m.start + m.length)) / r;
        try w.print("{d:.6}\t{d:.6}\t", .{ s, e });
        try writeClean(w, m.name, '\t');
        try w.writeByte('\n');
    }
}

/// A CD cue sheet with one track per marker (a CD allows 99), positions in
/// 1/75 s. Returns how many markers it holds.
pub fn writeCueSheet(alloc: std.mem.Allocator, w: *std.Io.Writer, ms: []const Marker, rate: u32, audio_name: []const u8) !usize {
    try w.writeAll("FILE \"");
    try writeClean(w, std.Io.Dir.path.basename(audio_name), '"');
    try w.print("\" {s}\n", .{if (std.ascii.endsWithIgnoreCase(audio_name, ".mp3")) "MP3" else "WAVE"});
    // the first 99 by time
    const sorted = try alloc.dupe(Marker, ms);
    defer alloc.free(sorted);
    std.mem.sort(Marker, sorted, {}, struct {
        fn lt(_: void, a: Marker, b: Marker) bool {
            return a.start < b.start;
        }
    }.lt);
    const n = @min(ms.len, 99);
    for (sorted[0..n], 1..) |m, i| {
        const frames75 = m.start * 75 / rate;
        try w.print("  TRACK {d:0>2} AUDIO\n    TITLE \"", .{i});
        try writeClean(w, m.name, '"');
        try w.print("\"\n    INDEX 01 {d:0>2}:{d:0>2}:{d:0>2}\n", .{ frames75 / (75 * 60), frames75 / 75 % 60, frames75 % 75 });
    }
    return n;
}

/// `s` with control characters (tabs, line breaks) and `bad` as spaces.
/// An Audition marker list (Markers panel > Import Markers): tab-separated
/// in spite of the .csv name Audition wants, times in its "decimal" format.
pub fn writeAudition(w: *std.Io.Writer, ms: []const Marker, rate: u32) !void {
    try w.writeAll("Name\tStart\tDuration\tTime Format\tType\tDescription\n");
    for (ms) |m| {
        try writeClean(w, m.name, '\t');
        try w.writeByte('\t');
        try decimalTime(w, m.start, rate);
        try w.writeByte('\t');
        try decimalTime(w, m.length, rate);
        try w.writeAll("\tdecimal\tCue\t\n");
    }
}

/// M:SS.mmm, or H:MM:SS.mmm from an hour.
fn decimalTime(w: *std.Io.Writer, frames: u64, rate: u32) !void {
    const ms = millis(frames, rate);
    const h = ms / 3_600_000;
    const m = ms / 60_000 % 60;
    const s = ms / 1000 % 60;
    if (h > 0) try w.print("{d}:{d:0>2}", .{ h, m }) else try w.print("{d}", .{m});
    try w.print(":{d:0>2}.{d:0>3}", .{ s, ms % 1000 });
}

fn millis(frames: u64, rate: u32) u64 {
    return (frames * 1000 + rate / 2) / rate;
}

/// A video frame rate: `num`/`den` frames a second, timecode counting `base`
/// frames to the second (non-drop frame).
pub const Fps = struct {
    num: u64,
    den: u64,
    base: u32,

    const known = [_]struct { []const u8, Fps }{
        .{ "23.976", .{ .num = 24000, .den = 1001, .base = 24 } },
        .{ "24", .{ .num = 24, .den = 1, .base = 24 } },
        .{ "25", .{ .num = 25, .den = 1, .base = 25 } },
        .{ "29.97", .{ .num = 30000, .den = 1001, .base = 30 } },
        .{ "30", .{ .num = 30, .den = 1, .base = 30 } },
        .{ "48", .{ .num = 48, .den = 1, .base = 48 } },
        .{ "50", .{ .num = 50, .den = 1, .base = 50 } },
        .{ "59.94", .{ .num = 60000, .den = 1001, .base = 60 } },
        .{ "60", .{ .num = 60, .den = 1, .base = 60 } },
    };
    pub const names = "23.976, 24, 25, 29.97, 30, 48, 50, 59.94 or 60";

    pub fn parse(s: []const u8) ?Fps {
        for (known) |k| if (std.mem.eql(u8, k[0], s)) return k[1];
        return null;
    }

    /// The video frame that audio frame `at` falls in.
    pub fn frameAt(f: Fps, at: u64, rate: u32) u64 {
        return at * f.num / (@as(u64, rate) * f.den);
    }
};

/// A DaVinci Resolve marker EDL (Timelines > Import > Timeline Markers from
/// EDL): one-frame events whose comment line holds the marker's colour, name
/// and length in frames. `start` is the timeline's start timecode in frames.
/// Returns how many it kept: an EDL numbers events with three digits (999).
pub fn writeEdl(w: *std.Io.Writer, ms: []const Marker, rate: u32, fps: Fps, start: u64, title: []const u8) !usize {
    try w.writeAll("TITLE: ");
    try writeClean(w, title, 0);
    try w.writeAll("\nFCM: NON-DROP FRAME\n\n");
    const kept = ms[0..@min(ms.len, 999)];
    for (kept, 1..) |m, i| {
        const at = start + fps.frameAt(m.start, rate);
        const den = @as(u64, rate) * fps.den;
        const len = @max(1, (m.length * fps.num + den / 2) / den);
        try w.print("{d:0>3}  001      V     C        ", .{i});
        try timecode(w, at, fps.base);
        try w.writeByte(' ');
        try timecode(w, at + 1, fps.base);
        try w.writeByte(' ');
        try timecode(w, at, fps.base);
        try w.writeByte(' ');
        try timecode(w, at + 1, fps.base);
        try w.writeAll("  \n |C:ResolveColorBlue |M:");
        try writeClean(w, m.name, '|');
        try w.print(" |D:{d}\n\n", .{len});
    }
    return kept.len;
}

fn timecode(w: *std.Io.Writer, frame: u64, base: u32) !void {
    const s = frame / base;
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60, frame % base });
}

pub const SubtitleFormat = enum { srt, vtt };

/// Subtitles in time order, each marker a caption; a point or anything
/// shorter than a second is shown for a second, or until the next caption.
pub fn writeSubtitles(alloc: std.mem.Allocator, w: *std.Io.Writer, ms: []const Marker, rate: u32, format: SubtitleFormat) !void {
    const sorted = try alloc.dupe(Marker, ms);
    defer alloc.free(sorted);
    std.mem.sort(Marker, sorted, {}, struct {
        fn lt(_: void, a: Marker, b: Marker) bool {
            return a.start < b.start;
        }
    }.lt);
    if (format == .vtt) try w.writeAll("WEBVTT\n\n");
    const sep: u8 = if (format == .srt) ',' else '.';
    for (sorted, 1..) |m, i| {
        if (format == .srt) try w.print("{d}\n", .{i});
        const s = millis(m.start, rate);
        const next = if (i < sorted.len) millis(sorted[i].start, rate) else std.math.maxInt(u64);
        const shown = if (next > s) @min(s + 1000, next) else s + 1000;
        const e = @max(millis(m.start + m.length, rate), shown);
        try clock(w, s, sep);
        try w.writeAll(" --> ");
        try clock(w, e, sep);
        try w.writeByte('\n');
        try writeClean(w, m.name, 0);
        try w.writeAll("\n\n");
    }
}

fn clock(w: *std.Io.Writer, ms: u64, sep: u8) !void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>3}", .{ ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000 });
}

/// A Standard MIDI File (type 0) with a marker event at each marker, at
/// 120 bpm (the default tempo of Pro Tools, Logic and Cubase, so the times
/// hold even when the tempo map isn't imported), 960 ticks a quarter note.
pub fn writeMidi(alloc: std.mem.Allocator, w: *std.Io.Writer, ms: []const Marker, rate: u32) !void {
    const sorted = try alloc.dupe(Marker, ms);
    defer alloc.free(sorted);
    std.mem.sort(Marker, sorted, {}, struct {
        fn lt(_: void, a: Marker, b: Marker) bool {
            return a.start < b.start;
        }
    }.lt);
    var track: std.Io.Writer.Allocating = .init(alloc);
    defer track.deinit();
    const t = &track.writer;
    try t.writeAll("\x00\xff\x51\x03\x07\xa1\x20"); // 500000 us a quarter note
    var last: u64 = 0;
    for (sorted) |m| {
        const tick = (m.start * 1920 + rate / 2) / rate; // 1920 ticks a second
        try vlq(t, tick - last);
        last = tick;
        const name = m.name[0..@min(m.name.len, 255)];
        try t.writeAll("\xff\x06");
        try vlq(t, name.len);
        try writeClean(t, name, 0);
    }
    try t.writeAll("\x00\xff\x2f\x00");
    const body = track.written();
    try w.writeAll("MThd\x00\x00\x00\x06\x00\x00\x00\x01\x03\xc0MTrk");
    try w.writeInt(u32, std.math.cast(u32, body.len) orelse return error.FileTooBig, .big);
    try w.writeAll(body);
}

/// A MIDI variable-length quantity.
fn vlq(w: *std.Io.Writer, v: u64) !void {
    var groups: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        groups[n] = @intCast(x & 0x7f);
        n += 1;
        x >>= 7;
        if (x == 0) break;
    }
    while (n > 1) {
        n -= 1;
        try w.writeByte(groups[n] | 0x80);
    }
    try w.writeByte(groups[0]);
}

fn writeClean(w: *std.Io.Writer, s: []const u8, bad: u8) !void {
    for (s) |c| try w.writeByte(if (c < 0x20 or c == bad) ' ' else c);
}

// ---- tests ----

const testing = std.testing;
const Audio = @import("audio.zig").Audio;

test "markers_round_trip_through_a_wav_and_keep_the_audio" {
    var s: [1000]f32 = undefined;
    for (&s, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i % 100)) / 100.0;
    const bytes = try wav.encode(testing.allocator, .{ .rate = 1000, .channels = 1, .samples = &s }, 16);
    defer testing.allocator.free(bytes);
    const once = try addToWav(testing.allocator, bytes, &.{ .{ .start = 100, .name = "click" }, .{ .start = 300, .length = 200, .name = "hum 60 Hz" } });
    defer testing.allocator.free(once);
    // adding again keeps the first ones
    const twice = try addToWav(testing.allocator, once, &.{.{ .start = 900, .name = "pop" }});
    defer testing.allocator.free(twice);
    const ms = try read(testing.allocator, twice);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 3), ms.len);
    try testing.expectEqualStrings("click", ms[0].name);
    try testing.expectEqual(@as(u64, 300), ms[1].start);
    try testing.expectEqual(@as(u64, 200), ms[1].length);
    try testing.expectEqualStrings("hum 60 Hz", ms[1].name);
    try testing.expectEqualStrings("pop", ms[2].name);
    // the audio is byte for byte the same
    var d = try wav.decode(testing.allocator, twice);
    defer d.audio.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bytes[8..], twice[8..bytes.len]);
    try testing.expectEqual(@as(usize, 1000), d.audio.samples.len);
    // RIFF size matches the file
    try testing.expectEqual(@as(u32, @intCast(twice.len - 8)), std.mem.readInt(u32, twice[4..8], .little));
}

/// A WAV with `extra` chunks after the data (each given whole, header and all).
fn wavWith(alloc: std.mem.Allocator, extra: []const []const u8) ![]u8 {
    var s = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const base = try wav.encode(alloc, .{ .rate = 1000, .channels = 1, .samples = &s }, 16);
    defer alloc.free(base);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, base);
    for (extra) |e| try out.appendSlice(alloc, e);
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .little);
    return out.toOwnedSlice(alloc);
}

/// Chunk ids in order, as a reader walking the file sees them.
fn chunkIds(bytes: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pos: usize = 12;
    while (pos + 8 <= bytes.len and n + 4 <= buf.len) {
        @memcpy(buf[n..][0..4], bytes[pos..][0..4]);
        n += 4;
        const size: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        pos += 8 + size + (size & 1);
    }
    return buf[0..n];
}

test "a_broken_adtl_list_does_not_crash" {
    // labl with size 0, then a list size that runs past the end
    const bytes = try wavWith(testing.allocator, &.{"LIST\x18\x00\x00\x00adtllabl\x00\x00\x00\x00noteabcd\x04\x00\x00\x00"});
    defer testing.allocator.free(bytes);
    const out = try addToWav(testing.allocator, bytes, &.{.{ .start = 1, .name = "click 1" }});
    defer testing.allocator.free(out);
    const ms = try read(testing.allocator, out);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 1), ms.len);
}

test "odd_last_chunk_gets_its_pad_so_the_markers_stay_aligned" {
    const bytes = try wavWith(testing.allocator, &.{"note\x03\x00\x00\x00abc"}); // no pad byte
    defer testing.allocator.free(bytes);
    const out = try addToWav(testing.allocator, bytes, &.{.{ .start = 2, .name = "pop 1" }});
    defer testing.allocator.free(out);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("fmt datanotecue LIST", chunkIds(out, &buf));
    const ms = try read(testing.allocator, out);
    defer testing.allocator.free(ms);
    try testing.expectEqualStrings("pop 1", ms[0].name);
}

test "existing_cue_points_and_notes_are_kept_as_they_were" {
    // a cue point with play position 7 and offset 3, its label and a note
    const cue = "cue \x1c\x00\x00\x00\x01\x00\x00\x00" ++ "\xff\xff\xff\xff" ++ "\x07\x00\x00\x00" ++ "data" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x03\x00\x00\x00";
    const list = "LIST\x26\x00\x00\x00adtl" ++ "labl\x08\x00\x00\x00\xff\xff\xff\xffmine" ++ "note\x0a\x00\x00\x00\xff\xff\xff\xffhello\x00";
    const bytes = try wavWith(testing.allocator, &.{ cue, list });
    defer testing.allocator.free(bytes);
    const out = try addToWav(testing.allocator, bytes, &.{.{ .start = 1, .name = "click 1" }});
    defer testing.allocator.free(out);
    // the old entry byte for byte, the note too
    try testing.expect(std.mem.find(u8, out, cue[12..]) != null);
    try testing.expect(std.mem.find(u8, out, "note\x0a\x00\x00\x00\xff\xff\xff\xffhello\x00") != null);
    const ms = try read(testing.allocator, out);
    defer testing.allocator.free(ms);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expectEqualStrings("mine", ms[0].name);
    try testing.expectEqualStrings("click 1", ms[1].name);
    // the new id doesn't wrap onto an old one
    var ids: [2]u32 = undefined;
    var pos: usize = std.mem.find(u8, out, "cue ").? + 12;
    for (&ids) |*v| {
        v.* = std.mem.readInt(u32, out[pos..][0..4], .little);
        pos += 24;
    }
    try testing.expect(ids[0] != ids[1]);
}

test "labels_and_cue_sheet" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ms = [_]Marker{ .{ .start = 48000 * 61 + 24000, .length = 4800, .name = "hum\t60" }, .{ .start = 480, .name = "click" } };
    try writeLabels(&w, &ms, 48000);
    try testing.expectEqualStrings("61.500000\t61.600000\thum 60\n0.010000\t0.010000\tclick\n", w.buffered());
    w = .fixed(&buf);
    const n = try writeCueSheet(testing.allocator, &w, &ms, 48000, "/x/talk \"1\".wav");
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings(
        \\FILE "talk  1 .wav" WAVE
        \\  TRACK 01 AUDIO
        \\    TITLE "click"
        \\    INDEX 01 00:00:00
        \\  TRACK 02 AUDIO
        \\    TITLE "hum 60"
        \\    INDEX 01 01:01:37
        \\
    , w.buffered());
}

test "audition_marker_list" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ms = [_]Marker{
        .{ .start = 480, .name = "click\t1" },
        .{ .start = 48000 * 61 + 24000, .length = 4800, .name = "hum 60 Hz" },
        .{ .start = 48000 * 3725, .length = 48000 * 2, .name = "speech 3" },
    };
    try writeAudition(&w, &ms, 48000);
    try testing.expectEqualStrings(
        "Name\tStart\tDuration\tTime Format\tType\tDescription\n" ++
            "click 1\t0:00.010\t0:00.000\tdecimal\tCue\t\n" ++
            "hum 60 Hz\t1:01.500\t0:00.100\tdecimal\tCue\t\n" ++
            "speech 3\t1:02:05.000\t0:02.000\tdecimal\tCue\t\n",
        w.buffered(),
    );
}

test "resolve_marker_edl" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ms = [_]Marker{
        .{ .start = 48000 * 2 + 4800, .name = "click | 1" },
        .{ .start = 48000 * 61 + 24000, .length = 48000 + 1000, .name = "pop 1" },
    };
    // 25 fps; the pop's 1.02 s round to 26 frames (25.5) from 01:00:00:00
    _ = try writeEdl(&w, &ms, 48000, Fps.parse("25").?, 25 * 3600, "talk");
    try testing.expectEqualStrings(
        \\TITLE: talk
        \\FCM: NON-DROP FRAME
        \\
        \\001  001      V     C        01:00:02:02 01:00:02:03 01:00:02:02 01:00:02:03  
        \\ |C:ResolveColorBlue |M:click   1 |D:1
        \\
        \\002  001      V     C        01:01:01:12 01:01:01:13 01:01:01:12 01:01:01:13  
        \\ |C:ResolveColorBlue |M:pop 1 |D:26
        \\
        \\
    , w.buffered());
}

test "edl_frames_at_29_97_count_real_frames_with_30_labels" {
    const f = Fps.parse("29.97").?;
    try testing.expectEqual(@as(u32, 30), f.base);
    // 100 real seconds are 2997 frames, labelled 00:01:39:27
    try testing.expectEqual(@as(u64, 2997), f.frameAt(100 * 48000, 48000));
    try testing.expect(Fps.parse("26") == null);
    try testing.expectEqual(@as(u32, 24), Fps.parse("23.976").?.base);
}

test "edl_keeps_the_first_999_markers" {
    var many: [1005]Marker = undefined;
    for (&many, 0..) |*m, k| m.* = .{ .start = k * 4800, .name = "click" };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const n = try writeEdl(&out.writer, &many, 48000, Fps.parse("25").?, 0, "t");
    try testing.expectEqual(@as(usize, 999), n);
    try testing.expect(std.mem.find(u8, out.written(), "\n999  001") != null);
    try testing.expect(std.mem.find(u8, out.written(), "1000  001") == null);
}

test "a_short_caption_is_not_stretched_over_the_next" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ms = [_]Marker{
        .{ .start = 48000, .name = "click 1" },
        .{ .start = 48000 + 24000, .name = "click 2" }, // half a second later
        .{ .start = 48000 * 5, .length = 48000 * 3, .name = "speech" },
        .{ .start = 48000 * 5, .length = 48000 * 2, .name = "music" }, // overlaps for real: kept
    };
    try writeSubtitles(testing.allocator, &w, &ms, 48000, .srt);
    try testing.expect(std.mem.find(u8, w.buffered(), "00:00:01,000 --> 00:00:01,500\nclick 1") != null);
    try testing.expect(std.mem.find(u8, w.buffered(), "00:00:01,500 --> 00:00:02,500\nclick 2") != null);
    try testing.expect(std.mem.find(u8, w.buffered(), "00:00:05,000 --> 00:00:08,000\nspeech") != null);
}

test "subtitles_srt_and_vtt" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // out of order, a point and a long stretch; points are shown for 1 s
    const ms = [_]Marker{
        .{ .start = 48000 * 3725, .length = 48000 * 2, .name = "music" },
        .{ .start = 4800, .name = "click\n1" },
    };
    try writeSubtitles(testing.allocator, &w, &ms, 48000, .srt);
    try testing.expectEqualStrings(
        "1\n00:00:00,100 --> 00:00:01,100\nclick 1\n\n" ++
            "2\n01:02:05,000 --> 01:02:07,000\nmusic\n\n",
        w.buffered(),
    );
    w = .fixed(&buf);
    try writeSubtitles(testing.allocator, &w, &ms, 48000, .vtt);
    try testing.expectEqualStrings(
        "WEBVTT\n\n00:00:00.100 --> 00:00:01.100\nclick 1\n\n" ++
            "01:02:05.000 --> 01:02:07.000\nmusic\n\n",
        w.buffered(),
    );
}

test "midi_file_markers_at_120_bpm" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 1.5 s and 3 s at 48 kHz: 2880 and 5760 ticks of 1/1920 s
    const ms = [_]Marker{ .{ .start = 48000 * 3, .name = "pop 1" }, .{ .start = 72000, .length = 100, .name = "click\x011" } };
    try writeMidi(testing.allocator, &w, &ms, 48000);
    const want = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x03\xc0" ++
        "MTrk\x00\x00\x00\x21" ++
        "\x00\xff\x51\x03\x07\xa1\x20" ++ // 120 bpm
        "\x96\x40\xff\x06\x07click 1" ++ // delta 2880
        "\x96\x40\xff\x06\x05pop 1" ++ // delta 2880 more
        "\x00\xff\x2f\x00";
    try testing.expectEqualSlices(u8, want, w.buffered());
}

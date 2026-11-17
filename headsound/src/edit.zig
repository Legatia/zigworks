//! Edits on whole files: shorten pauses, cut a span, change the level,
//! change the rate or mix to mono. Joins get 5 ms fades so they don't click.
const std = @import("std");
const audio = @import("audio.zig");
const resample = @import("resample.zig");
const Audio = audio.Audio;
const Segment = @import("vad.zig").Segment;

const fade_s = 0.005;

pub const Span = struct { start: f64, end: f64 };

/// The parts of the file to keep when every pause between `segs` is shortened
/// to `keep_s` (half of it on each side), and silence before the first and
/// after the last stretch to `keep_s / 2`.
pub fn pauseKeeps(alloc: std.mem.Allocator, segs: []const Segment, duration: f64, keep_s: f64) ![]Span {
    const half = keep_s / 2;
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);
    for (segs, 0..) |s, i| {
        // A pause up to keep_s stays whole (each side keeps half of it).
        const before = if (i == 0) @min(s.start, half) else blk: {
            const gap = s.start - segs[i - 1].end;
            break :blk if (gap <= keep_s) gap / 2 else half;
        };
        const after = if (i + 1 == segs.len) @min(duration - s.end, half) else blk: {
            const gap = segs[i + 1].start - s.end;
            break :blk if (gap <= keep_s) gap / 2 else half;
        };
        const sp = Span{ .start = s.start - before, .end = s.end + after };
        if (out.items.len > 0 and sp.start <= out.items[out.items.len - 1].end + 1e-9) {
            out.items[out.items.len - 1].end = sp.end;
        } else try out.append(alloc, sp);
    }
    return out.toOwnedSlice(alloc);
}

fn frameAt(a: Audio, t: f64) usize {
    const f: usize = @intFromFloat(@max(0, @round(t * @as(f64, @floatFromInt(a.rate)))));
    return @min(f, a.frames());
}

/// The spans of `a`, joined. Each piece fades in and out over 5 ms where it
/// meets another piece.
pub fn join(alloc: std.mem.Allocator, a: Audio, spans: []const Span) !Audio {
    var total: usize = 0;
    for (spans) |sp| total += frameAt(a, sp.end) - frameAt(a, sp.start);
    const out = try alloc.alloc(f32, total * a.channels);
    const fade_n: usize = @intFromFloat(fade_s * @as(f64, @floatFromInt(a.rate)));
    var p: usize = 0;
    for (spans, 0..) |sp, k| {
        const f0 = frameAt(a, sp.start);
        const f1 = frameAt(a, sp.end);
        const n = f1 - f0;
        @memcpy(out[p * a.channels ..][0 .. n * a.channels], a.samples[f0 * a.channels ..][0 .. n * a.channels]);
        const fn_ = @min(fade_n, n / 2);
        for (0..fn_) |i| {
            const g = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fn_));
            for (0..a.channels) |c| {
                if (k > 0) out[(p + i) * a.channels + c] *= g;
                if (k + 1 < spans.len) out[(p + n - 1 - i) * a.channels + c] *= g;
            }
        }
        p += n;
    }
    return .{ .rate = a.rate, .channels = a.channels, .samples = out };
}

/// Multiplies every sample by `db` decibels.
pub fn gain(a: Audio, db: f64) void {
    const g: f32 = @floatCast(audio.fromDb(db));
    for (a.samples) |*x| x.* *= g;
}

/// `a` at another rate and/or mixed to mono.
pub fn convert(alloc: std.mem.Allocator, a: Audio, rate: u32, to_mono: bool) !Audio {
    const ch: u16 = if (to_mono) 1 else a.channels;
    if (to_mono and a.channels > 1) {
        const m = try audio.mono(alloc, a);
        defer alloc.free(m);
        return .{ .rate = rate, .channels = 1, .samples = try resample.resample(alloc, m, a.rate, rate) };
    }
    if (rate == a.rate) return .{ .rate = rate, .channels = ch, .samples = try alloc.dupe(f32, a.samples) };
    // One channel at a time.
    const n = a.frames();
    const one = try alloc.alloc(f32, n);
    defer alloc.free(one);
    var out: ?[]f32 = null;
    errdefer if (out) |o| alloc.free(o);
    var out_frames: usize = 0;
    for (0..ch) |c| {
        for (0..n) |i| one[i] = a.samples[i * ch + c];
        const r = try resample.resample(alloc, one, a.rate, rate);
        defer alloc.free(r);
        if (out == null) {
            out_frames = r.len;
            out = try alloc.alloc(f32, r.len * ch);
        }
        for (r, 0..) |v, i| out.?[i * ch + c] = v;
    }
    return .{ .rate = rate, .channels = ch, .samples = out.? };
}

// ---- tests ----

const testing = std.testing;

test "long_pauses_shrink_short_ones_stay" {
    const segs = [_]Segment{ .{ .start = 2, .end = 3 }, .{ .start = 3.3, .end = 4 }, .{ .start = 7, .end = 8 } };
    const keeps = try pauseKeeps(testing.allocator, &segs, 10, 0.5);
    defer testing.allocator.free(keeps);
    // 2 s of lead-in becomes 0.25; the 0.3 s pause stays; the 3 s pause becomes 0.5; the tail 0.25
    try testing.expectEqual(@as(usize, 2), keeps.len);
    try testing.expectApproxEqAbs(@as(f64, 1.75), keeps[0].start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.25), keeps[0].end, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 6.75), keeps[1].start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.25), keeps[1].end, 1e-9);
}

test "join_concatenates_with_fades" {
    var s: [2000]f32 = undefined;
    @memset(&s, 1);
    const a = Audio{ .rate = 1000, .channels = 1, .samples = &s };
    var j = try join(testing.allocator, a, &.{ .{ .start = 0, .end = 0.5 }, .{ .start = 1.0, .end = 1.25 } });
    defer j.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 750), j.samples.len);
    try testing.expectEqual(@as(f32, 1), j.samples[0]); // the file's own start: no fade
    try testing.expect(j.samples[499] < 0.25); // faded out at the join
    try testing.expect(j.samples[500] < 0.25); // faded in after it
    try testing.expectEqual(@as(f32, 1), j.samples[600]);
    try testing.expectEqual(@as(f32, 1), j.samples[749]); // the file's own end: no fade
}

test "gain_and_convert" {
    var s = [_]f32{ 0.5, -0.5, 0.25, -0.25 } ** 100;
    const a = Audio{ .rate = 8000, .channels = 2, .samples = &s };
    gain(a, -6.0206);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s[0], 1e-4);
    var m = try convert(testing.allocator, a, 8000, true);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 1), m.channels);
    try testing.expectEqual(@as(usize, 200), m.samples.len);
    try testing.expectApproxEqAbs(@as(f32, 0), m.samples[100], 1e-3);
    var r = try convert(testing.allocator, a, 16000, false);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 2), r.channels);
    try testing.expectEqual(@as(usize, 400), r.frames());
}

//! Problems in recorded speech: pops ("p" and "b" hitting the microphone:
//! short bursts below 80 Hz) and harsh s sounds (bursts above 5 kHz much
//! louder than the voice around them).
const std = @import("std");
const audio = @import("audio.zig");
const Biquad = @import("biquad.zig").Biquad;

pub const Burst = struct {
    /// Seconds.
    start: f64,
    end: f64,
    /// dBFS of the band in the burst.
    level: f64,
    /// dB above the reference it was judged against.
    over: f64,
};

const frame_s = 0.01;

/// RMS level (dB) of each 10 ms frame of `x` after the filters in `chain`.
fn bandLevels(alloc: std.mem.Allocator, x: []const f32, rate: u32, chain: []const Biquad) ![]f64 {
    const hop: usize = @intFromFloat(@as(f64, @floatFromInt(rate)) * frame_s);
    const n = x.len / hop;
    const out = try alloc.alloc(f64, n);
    var fs: [8]Biquad = undefined;
    @memcpy(fs[0..chain.len], chain);
    var acc: f64 = 0;
    for (0..n * hop) |i| {
        var y: f64 = x[i];
        for (fs[0..chain.len]) |*f| y = f.process(y);
        acc += y * y;
        if ((i + 1) % hop == 0) {
            out[i / hop] = audio.db(@sqrt(acc / @as(f64, @floatFromInt(hop))));
            acc = 0;
        }
    }
    return out;
}

fn percentile(alloc: std.mem.Allocator, v: []const f64, p: f64) !f64 {
    var tmp: std.ArrayList(f64) = .empty;
    defer tmp.deinit(alloc);
    for (v) |x| if (std.math.isFinite(x)) try tmp.append(alloc, x);
    if (tmp.items.len == 0) return -std.math.inf(f64);
    std.mem.sort(f64, tmp.items, {}, std.sort.asc(f64));
    return tmp.items[@intFromFloat(@round(p * @as(f64, @floatFromInt(tmp.items.len - 1))))];
}

/// Frames where `hit` holds, grouped (one quiet frame may split nothing),
/// kept when between `min_frames` and `max_frames` long.
fn group(alloc: std.mem.Allocator, hit: []const bool, band: []const f64, ref: f64, min_frames: usize, max_frames: usize) ![]Burst {
    var out: std.ArrayList(Burst) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < hit.len) {
        if (!hit[i]) {
            i += 1;
            continue;
        }
        var j = i;
        var peak = band[i];
        while (j + 1 < hit.len and (hit[j + 1] or (j + 2 < hit.len and hit[j + 2]))) : (j += 1) peak = @max(peak, band[j + 1]);
        const len = j - i + 1;
        if (len >= min_frames and len <= max_frames) try out.append(alloc, .{
            .start = @as(f64, @floatFromInt(i)) * frame_s,
            .end = @as(f64, @floatFromInt(j + 1)) * frame_s,
            .level = peak,
            .over = peak - ref,
        });
        i = j + 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Pops: 10 to 150 ms where the band below 80 Hz jumps 15 dB or more over
/// its usual level in the speech, makes up most of the sound, and is louder
/// than -45 dBFS.
pub fn pops(alloc: std.mem.Allocator, x: []const f32, rate: u32) ![]Burst {
    const lp = [_]Biquad{ Biquad.lowpass(rate, 80, 0.5412), Biquad.lowpass(rate, 80, 1.3066) };
    const lf = try bandLevels(alloc, x, rate, &lp);
    defer alloc.free(lf);
    const full = try bandLevels(alloc, x, rate, &.{});
    defer alloc.free(full);
    // the usual low end where there is sound
    const loud = try percentile(alloc, full, 0.95);
    var act: std.ArrayList(f64) = .empty;
    defer act.deinit(alloc);
    for (lf, full) |l, f| if (f > loud - 30) try act.append(alloc, l);
    const ref = try percentile(alloc, act.items, 0.5);
    const hit = try alloc.alloc(bool, lf.len);
    defer alloc.free(hit);
    for (hit, lf, full) |*h, l, f| h.* = l >= ref + 15 and l >= f - 4 and l >= -45;
    const bs = try group(alloc, hit, lf, ref, 1, 15);
    // each pop reaches as far as its thump is still 6 dB over (up to 100 ms)
    for (bs) |*b| {
        var i: usize = @intFromFloat(@round(b.start / frame_s));
        var j: usize = @intFromFloat(@round(b.end / frame_s));
        const first = i;
        const last = j;
        while (i > 0 and first - (i - 1) <= 10 and lf[i - 1] >= ref + 6) i -= 1;
        while (j < lf.len and j - last < 10 and lf[j] >= ref + 6) j += 1;
        b.start = @as(f64, @floatFromInt(i)) * frame_s;
        b.end = @as(f64, @floatFromInt(j)) * frame_s;
    }
    return bs;
}

/// Harsh s: 30 to 400 ms where the band above 5 kHz is louder than the
/// voice's usual level nearby (the median speech-band level of its louder
/// frames within 1.5 s) by 3 dB or more: a de-esser's job. Needs a rate of
/// 22050 Hz or more; none below that.
pub fn harshS(alloc: std.mem.Allocator, x: []const f32, rate: u32) ![]Burst {
    if (rate < 22050) return alloc.alloc(Burst, 0);
    const hp = [_]Biquad{ Biquad.highpass(rate, 5000, 0.5412), Biquad.highpass(rate, 5000, 1.3066) };
    const sp = [_]Biquad{ Biquad.highpass(rate, 300, 0.7071), Biquad.lowpass(rate, 3400, 0.7071) };
    const hf = try bandLevels(alloc, x, rate, &hp);
    defer alloc.free(hf);
    const speech = try bandLevels(alloc, x, rate, &sp);
    defer alloc.free(speech);
    const top = try percentile(alloc, speech, 0.95);
    // the voice's level per half second: the median of its louder frames
    const per = 50;
    const nb = (speech.len + per - 1) / per;
    const block_ref = try alloc.alloc(f64, nb);
    defer alloc.free(block_ref);
    var act: std.ArrayList(f64) = .empty;
    defer act.deinit(alloc);
    for (block_ref, 0..) |*r, b| {
        act.clearRetainingCapacity();
        for (speech[b * per .. @min(speech.len, (b + 1) * per)]) |v| if (v > top - 20) try act.append(alloc, v);
        r.* = if (act.items.len >= 5) try percentile(alloc, act.items, 0.5) else std.math.nan(f64);
    }
    const hit = try alloc.alloc(bool, hf.len);
    defer alloc.free(hit);
    const refs = try alloc.alloc(f64, hf.len);
    defer alloc.free(refs);
    var near: std.ArrayList(f64) = .empty;
    defer near.deinit(alloc);
    for (hit, hf, speech, refs, 0..) |*h, f, sv, *rf, i| {
        const b = i / per;
        near.clearRetainingCapacity();
        for (b -| 3..@min(nb, b + 4)) |k| if (!std.math.isNan(block_ref[k])) try near.append(alloc, block_ref[k]);
        if (near.items.len == 0) {
            h.* = false;
            rf.* = 0;
            continue;
        }
        const ref = try percentile(alloc, near.items, 0.5);
        rf.* = ref;
        h.* = f >= ref + 3 and f >= sv;
    }
    return groupLocal(alloc, hit, hf, refs, 3, 40);
}

/// As `group`, with a reference level per frame.
fn groupLocal(alloc: std.mem.Allocator, hit: []const bool, band: []const f64, refs: []const f64, min_frames: usize, max_frames: usize) ![]Burst {
    var out: std.ArrayList(Burst) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < hit.len) {
        if (!hit[i]) {
            i += 1;
            continue;
        }
        var j = i;
        var over = band[i] - refs[i];
        var peak = band[i];
        while (j + 1 < hit.len and (hit[j + 1] or (j + 2 < hit.len and hit[j + 2]))) : (j += 1) {
            peak = @max(peak, band[j + 1]);
            over = @max(over, band[j + 1] - refs[j + 1]);
        }
        const len = j - i + 1;
        if (len >= min_frames and len <= max_frames) try out.append(alloc, .{
            .start = @as(f64, @floatFromInt(i)) * frame_s,
            .end = @as(f64, @floatFromInt(j + 1)) * frame_s,
            .level = peak,
            .over = over,
        });
        i = j + 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---- tests ----

const testing = std.testing;

/// Syllables of a 140 Hz buzz, with an s (high noise) and a pop where asked.
fn talk(alloc: std.mem.Allocator, rate: u32, s_gain: f64, pop_at: ?f64) ![]f32 {
    var prng = std.Random.DefaultPrng.init(4);
    const rnd = prng.random();
    const fs: f64 = @floatFromInt(rate);
    const n: usize = @intFromFloat(4 * fs);
    const out = try alloc.alloc(f32, n);
    // a gentle high-pass for the s noise: differences of white noise
    var prev: f64 = 0;
    for (out, 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / fs;
        var acc: f64 = 0;
        for (1..12) |h| acc += @sin(2 * std.math.pi * 140 * @as(f64, @floatFromInt(h)) * t) / @as(f64, @floatFromInt(h));
        const syl = @max(0, @sin(2 * std.math.pi * 2 * t)); // 4 syllables a second
        var y = 0.2 * acc * syl;
        // an s between syllables at 1.25 s and 2.75 s
        const noise = rnd.float(f64) - 0.5;
        const hpn = noise - prev;
        prev = noise;
        for ([_]f64{ 1.25, 2.75 }) |c| {
            if (@abs(t - c) < 0.08) y += s_gain * 0.05 * hpn;
        }
        if (pop_at) |p| {
            const d = t - p;
            if (d >= 0 and d < 0.05) y += 0.5 * @sin(2 * std.math.pi * 30 * d) * @exp(-d / 0.02);
        }
        v.* = @floatCast(y);
    }
    return out;
}

test "a_pop_is_found_and_the_voice_is_not_a_pop" {
    const x = try talk(testing.allocator, 44100, 1, 2.1);
    defer testing.allocator.free(x);
    const ps = try pops(testing.allocator, x, 44100);
    defer testing.allocator.free(ps);
    try testing.expectEqual(@as(usize, 1), ps.len);
    try testing.expectApproxEqAbs(@as(f64, 2.1), ps[0].start, 0.02);
    const clean = try talk(testing.allocator, 44100, 1, null);
    defer testing.allocator.free(clean);
    const none = try pops(testing.allocator, clean, 44100);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "harsh_s_is_found_only_when_loud" {
    const soft = try talk(testing.allocator, 44100, 1, null);
    defer testing.allocator.free(soft);
    const a = try harshS(testing.allocator, soft, 44100);
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const harsh = try talk(testing.allocator, 44100, 8, null);
    defer testing.allocator.free(harsh);
    const b = try harshS(testing.allocator, harsh, 44100);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectApproxEqAbs(@as(f64, 1.17), b[0].start, 0.04);
    try testing.expectApproxEqAbs(@as(f64, 2.67), b[1].start, 0.04);
}

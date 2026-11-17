//! Loudness per ITU-R BS.1770-4 / EBU R128: integrated loudness (K-weighting,
//! 400 ms blocks with 75% overlap, gates at -70 LUFS and 10 LU below), the
//! loudness range (EBU Tech 3342), maximum momentary and short-term loudness,
//! and the true peak.
const std = @import("std");
const Audio = @import("audio.zig").Audio;
const kWeighting = @import("biquad.zig").kWeighting;

fn weight(channels: u16, c: usize) f64 {
    // 5.1 (L R C LFE Ls Rs): the LFE is left out, the surrounds count +1.5 dB.
    if (channels == 6) return switch (c) {
        3 => 0,
        4, 5 => 1.41,
        else => 1,
    };
    return 1;
}

pub const Measure = struct {
    /// Integrated loudness (LUFS); -inf when nothing passes the gates.
    integrated: f64,
    /// Loudness range (LU, EBU Tech 3342); 0 when the audio is too short.
    lra: f64,
    /// Loudest 400 ms block (momentary) and 3 s window (short-term), LUFS.
    max_momentary: f64,
    max_short_term: f64,
};

/// Integrated loudness in LUFS; -inf when everything is below the absolute gate
/// or the audio is shorter than one block.
pub fn integrated(alloc: std.mem.Allocator, a: Audio) !f64 {
    return (try measure(alloc, a)).integrated;
}

/// Weighted, K-filtered energy of each 100 ms step, summed over channels.
fn stepEnergies(alloc: std.mem.Allocator, a: Audio) ![]f64 {
    const step = a.rate / 10;
    const n_steps = if (step == 0) 0 else a.frames() / step;
    const steps = try alloc.alloc(f64, n_steps);
    @memset(steps, 0);
    for (0..a.channels) |c| {
        const w = weight(a.channels, c);
        if (w == 0) continue;
        var k = kWeighting(a.rate);
        for (0..n_steps * step) |i| {
            const x: f64 = a.samples[i * a.channels + c];
            const y = k[1].process(k[0].process(x));
            steps[i / step] += w * y * y;
        }
    }
    return steps;
}

/// Mean energies of windows of `len` steps, one per step.
fn windows(alloc: std.mem.Allocator, steps: []const f64, len: usize, step_samples: usize) ![]f64 {
    if (steps.len < len) return alloc.alloc(f64, 0);
    const out = try alloc.alloc(f64, steps.len - len + 1);
    const total: f64 = @floatFromInt(step_samples * len);
    var sum: f64 = 0;
    for (steps[0..len]) |v| sum += v;
    out[0] = sum / total;
    for (1..out.len) |j| {
        sum += steps[j + len - 1] - steps[j - 1];
        out[j] = @max(0, sum) / total;
    }
    return out;
}

fn gatedMean(blocks: []const f64, rel_lu: f64) struct { mean: f64, gate: f64 } {
    const abs_gate = fromLufs(-70.0);
    var sum: f64 = 0;
    var count: usize = 0;
    for (blocks) |b| if (b > abs_gate) {
        sum += b;
        count += 1;
    };
    if (count == 0) return .{ .mean = 0, .gate = std.math.inf(f64) };
    const rel_gate = @max(abs_gate, sum / @as(f64, @floatFromInt(count)) * std.math.pow(f64, 10.0, rel_lu / 10.0));
    sum = 0;
    count = 0;
    for (blocks) |b| if (b > rel_gate) {
        sum += b;
        count += 1;
    };
    return .{ .mean = if (count == 0) 0 else sum / @as(f64, @floatFromInt(count)), .gate = rel_gate };
}

pub fn measure(alloc: std.mem.Allocator, a: Audio) !Measure {
    const ninf = -std.math.inf(f64);
    var m = Measure{ .integrated = ninf, .lra = 0, .max_momentary = ninf, .max_short_term = ninf };
    const step = a.rate / 10;
    const steps = try stepEnergies(alloc, a);
    defer alloc.free(steps);

    const blocks = try windows(alloc, steps, 4, step);
    defer alloc.free(blocks);
    for (blocks) |b| m.max_momentary = @max(m.max_momentary, toLufs(b));
    const g = gatedMean(blocks, -10.0);
    if (g.mean > 0) m.integrated = toLufs(g.mean);

    // Loudness range: short-term (3 s) values, gated at -70 LUFS and 20 LU
    // below their mean, from the 10th to the 95th percentile.
    const short = try windows(alloc, steps, 30, step);
    defer alloc.free(short);
    for (short) |b| m.max_short_term = @max(m.max_short_term, toLufs(b));
    const sg = gatedMean(short, -20.0);
    var kept: std.ArrayList(f64) = .empty;
    defer kept.deinit(alloc);
    for (short) |b| if (b > sg.gate) try kept.append(alloc, toLufs(b));
    if (kept.items.len >= 2) {
        std.mem.sort(f64, kept.items, {}, std.sort.asc(f64));
        const at = struct {
            fn f(s: []const f64, p: f64) f64 {
                return s[@intFromFloat(@round(p * @as(f64, @floatFromInt(s.len - 1))))];
            }
        }.f;
        m.lra = at(kept.items, 0.95) - at(kept.items, 0.10);
    }
    return m;
}

/// True peak (dBTP, ITU-R BS.1770-4 Annex 2): the largest value of the signal
/// oversampled 4 times, so peaks between samples count. Only stretches within
/// 6 dB of the sample peak are oversampled.
pub fn truePeak(a: Audio) f64 {
    const taps = 12; // per side
    const S = struct {
        fn kaiserSinc(t: f64) f64 {
            if (@abs(t) >= taps) return 0;
            const s = if (t == 0) 1.0 else @sin(std.math.pi * t) / (std.math.pi * t);
            const r = t / taps;
            return s * bessel0(8.0 * @sqrt(@max(0, 1 - r * r))) / bessel0(8.0);
        }
        fn bessel0(x: f64) f64 {
            var sum: f64 = 1;
            var term: f64 = 1;
            var k: f64 = 1;
            while (k < 40) : (k += 1) {
                term *= (x / (2 * k)) * (x / (2 * k));
                sum += term;
            }
            return sum;
        }
    };
    var h: [3][2 * taps]f64 = undefined;
    for (0..3) |p| for (0..2 * taps) |k| {
        // the value at n + (p+1)/4 from samples n - taps + 1 + k
        const t = (@as(f64, @floatFromInt(p + 1)) / 4.0) - (@as(f64, @floatFromInt(k)) - taps + 1);
        h[p][k] = S.kaiserSinc(t);
    };
    const sample_peak: f64 = @import("audio.zig").peak(a.samples);
    var best = sample_peak;
    const lo = sample_peak * 0.5;
    const n = a.frames();
    const ch = a.channels;
    for (0..ch) |c| {
        var i: usize = 0;
        while (i + 1 < n) : (i += 1) {
            if (@max(@abs(a.samples[i * ch + c]), @abs(a.samples[(i + 1) * ch + c])) < lo) continue;
            for (0..3) |p| {
                var y: f64 = 0;
                for (0..2 * taps) |k| {
                    const idx = @as(isize, @intCast(i + k)) - taps + 1;
                    if (idx < 0 or idx >= @as(isize, @intCast(n))) continue;
                    y += h[p][k] * a.samples[@as(usize, @intCast(idx)) * ch + c];
                }
                best = @max(best, @abs(y));
            }
        }
    }
    return @import("audio.zig").db(best);
}

fn toLufs(z: f64) f64 {
    return -0.691 + 10.0 * std.math.log10(z);
}

fn fromLufs(l: f64) f64 {
    return std.math.pow(f64, 10.0, (l + 0.691) / 10.0);
}

// ---- tests ----

const testing = std.testing;

/// `secs` of a 1 kHz sine at `dbfs` (peak), with `silence` seconds of zeros after.
fn sine(alloc: std.mem.Allocator, rate: u32, channels: u16, dbfs: f64, secs: f64, silence: f64) !Audio {
    const n: usize = @intFromFloat(secs * @as(f64, @floatFromInt(rate)));
    const z: usize = @intFromFloat(silence * @as(f64, @floatFromInt(rate)));
    const s = try alloc.alloc(f32, (n + z) * channels);
    @memset(s, 0);
    const amp = std.math.pow(f64, 10.0, dbfs / 20.0);
    for (0..n) |i| {
        const x: f32 = @floatCast(amp * @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate))));
        for (0..channels) |c| s[i * channels + c] = x;
    }
    return .{ .rate = rate, .channels = channels, .samples = s };
}

test "ebu_tech_3341_case_1_stereo_sine_is_minus_23" {
    var a = try sine(testing.allocator, 48000, 2, -23.0, 20, 0);
    defer a.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, -23.0), try integrated(testing.allocator, a), 0.1);
}

test "mono_sine_at_44k1_is_3_db_lower" {
    var a = try sine(testing.allocator, 44100, 1, -23.0, 10, 0);
    defer a.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, -26.0), try integrated(testing.allocator, a), 0.1);
}

test "silence_is_gated_out" {
    var a = try sine(testing.allocator, 48000, 2, -23.0, 10, 10);
    defer a.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, -23.0), try integrated(testing.allocator, a), 0.15);
    var q = try sine(testing.allocator, 16000, 1, -100.0, 2, 0);
    defer q.deinit(testing.allocator);
    try testing.expect(std.math.isNegativeInf(try integrated(testing.allocator, q)));
}

test "relative_gate_drops_quiet_parts" {
    // EBU 3341 case 3 shape: -36 dBFS for 10 s, -23 for 60 s, -36 for 10 s -> -23
    const rate: u32 = 16000;
    var a = try sine(testing.allocator, rate, 2, -23.0, 80, 0);
    defer a.deinit(testing.allocator);
    const quiet: f32 = @floatCast(std.math.pow(f64, 10.0, -13.0 / 20.0));
    for (0..10 * rate) |i| for (0..2) |c| {
        a.samples[i * 2 + c] *= quiet;
        a.samples[(70 * rate + i) * 2 + c] *= quiet;
    };
    try testing.expectApproxEqAbs(@as(f64, -23.0), try integrated(testing.allocator, a), 0.15);
}

/// EBU Tech 3342 shape: 20 s pieces of a stereo 1 kHz sine at these levels.
fn steps3342(alloc: std.mem.Allocator, levels: []const f64) !Audio {
    const rate: u32 = 16000;
    const per: usize = 20 * rate;
    const s = try alloc.alloc(f32, per * levels.len * 2);
    for (levels, 0..) |l, j| {
        const amp = std.math.pow(f64, 10.0, l / 20.0);
        for (0..per) |i| {
            const n = j * per + i;
            const x: f32 = @floatCast(amp * @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(rate))));
            s[n * 2] = x;
            s[n * 2 + 1] = x;
        }
    }
    return .{ .rate = rate, .channels = 2, .samples = s };
}

test "ebu_tech_3342_loudness_range_cases" {
    const cases = [_]struct { levels: []const f64, lra: f64 }{
        .{ .levels = &.{ -20, -30 }, .lra = 10 },
        .{ .levels = &.{ -20, -15 }, .lra = 5 },
        .{ .levels = &.{ -40, -20 }, .lra = 20 },
        .{ .levels = &.{ -50, -35, -20, -35, -50 }, .lra = 15 },
    };
    for (cases) |c| {
        var a = try steps3342(testing.allocator, c.levels);
        defer a.deinit(testing.allocator);
        const m = try measure(testing.allocator, a);
        try testing.expectApproxEqAbs(c.lra, m.lra, 1.0);
    }
}

test "max_momentary_and_short_term" {
    var a = try steps3342(testing.allocator, &.{ -30, -20 });
    defer a.deinit(testing.allocator);
    const m = try measure(testing.allocator, a);
    try testing.expectApproxEqAbs(@as(f64, -20), m.max_momentary, 0.2);
    try testing.expectApproxEqAbs(@as(f64, -20), m.max_short_term, 0.2);
}

test "true_peak_finds_peaks_between_samples" {
    // A sine at a quarter of the rate, 45 degrees off: every sample is at
    // 0.707 of the real peak, so the sample peak is 3 dB low.
    const n = 4000;
    var s: [n]f32 = undefined;
    for (&s, 0..) |*v, i| {
        // faded in and out: an abrupt start would really overshoot
        const e = @min(1.0, @as(f64, @floatFromInt(@min(i, n - 1 - i))) / 400.0);
        v.* = @floatCast(0.5 * e * @sin(std.math.pi / 2.0 * @as(f64, @floatFromInt(i)) + std.math.pi / 4.0));
    }
    const a = Audio{ .rate = 48000, .channels = 1, .samples = &s };
    try testing.expectApproxEqAbs(@as(f64, -9.03), @import("audio.zig").db(@import("audio.zig").peak(&s)), 0.05);
    try testing.expectApproxEqAbs(@as(f64, -6.02), truePeak(a), 0.05);
}

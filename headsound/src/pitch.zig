//! Voice pitch with YIN (de Cheveigné & Kawahara 2002): the cumulative mean
//! normalised difference, first dip under a threshold, parabolic refinement.
const std = @import("std");

pub const fmin: f32 = 60;
pub const fmax: f32 = 500;
pub const threshold: f32 = 0.15;

pub const Pitch = struct { hz: f32, aperiodicity: f32 };

/// Frame length YIN needs at `rate`: a 25 ms window plus the longest period.
pub fn frameLen(rate: u32) usize {
    return @as(usize, rate) / 40 + @as(usize, @trunc(@ceil(@as(f32, @floatFromInt(rate)) / fmin))) + 2;
}

/// Pitch of `x` (at least frameLen(rate) samples), or null when it isn't
/// periodic enough to be voiced. `scratch` needs frameLen(rate) floats.
pub fn yin(x: []const f32, rate: u32, scratch: []f32) ?Pitch {
    const w: usize = rate / 40;
    const tau_max: usize = @trunc(@ceil(@as(f32, @floatFromInt(rate)) / fmin));
    const tau_min: usize = @trunc(@floor(@as(f32, @floatFromInt(rate)) / fmax));
    std.debug.assert(x.len >= w + tau_max + 1 and scratch.len >= tau_max + 2);
    var energy: f32 = 0;
    for (x[0 .. w + tau_max]) |v| energy += v * v;
    if (energy < 1e-7 * @as(f32, @floatFromInt(w))) return null; // below about -70 dBFS

    const d = scratch[0 .. tau_max + 2];
    d[0] = 1;
    var running: f32 = 0;
    for (1..tau_max + 2) |tau| {
        var s: f32 = 0;
        for (0..w) |j| {
            const diff = x[j] - x[j + tau];
            s += diff * diff;
        }
        running += s;
        d[tau] = if (running > 0) s * @as(f32, @floatFromInt(tau)) / running else 1;
    }
    var best: usize = 0;
    var tau = tau_min;
    while (tau <= tau_max) : (tau += 1) {
        if (d[tau] < threshold) {
            while (tau + 1 <= tau_max and d[tau + 1] < d[tau]) tau += 1;
            best = tau;
            break;
        }
    }
    if (best == 0) return null;
    // An octave down is the usual mistake: a period that is a multiple of the
    // real one. Prefer the shortest divisor whose dip is nearly as deep.
    var k: usize = 4;
    while (k >= 2) : (k -= 1) {
        const t = (best + k / 2) / k;
        if (t < tau_min + 1 or t + 1 > tau_max) continue;
        var m = t - 1;
        for (t - 1..t + 2) |j| if (d[j] < d[m]) {
            m = j;
        };
        if (d[m] < 2 * threshold and d[m] < d[best] + 0.1) {
            best = m;
            break;
        }
    }
    // Parabolic interpolation around the dip.
    const a = d[best - 1];
    const b = d[best];
    const c = d[best + 1];
    const den = a - 2 * b + c;
    const shift: f32 = if (den != 0) std.math.clamp(0.5 * (a - c) / den, -1, 1) else 0;
    const period = @as(f32, @floatFromInt(best)) + shift;
    return .{ .hz = @as(f32, @floatFromInt(rate)) / period, .aperiodicity = b };
}

/// Pitch every 10 ms (0 where unvoiced) for frames whose `want` flag is set
/// (null: all frames). Frame i starts at sample i * rate / 100.
pub fn track(alloc: std.mem.Allocator, x: []const f32, rate: u32, want: ?[]const bool) ![]f32 {
    const hop: usize = rate / 100;
    const flen = frameLen(rate);
    const n = if (x.len >= flen) (x.len - flen) / hop + 1 else 0;
    const out = try alloc.alloc(f32, n);
    const scratch = try alloc.alloc(f32, flen);
    defer alloc.free(scratch);
    for (out, 0..) |*o, i| {
        if (want) |wv| if (i >= wv.len or !wv[i]) {
            o.* = 0;
            continue;
        };
        o.* = if (yin(x[i * hop ..][0..flen], rate, scratch)) |p| p.hz else 0;
    }
    return out;
}

pub const Stats = struct { median: f32, low: f32, high: f32, voiced: usize };

/// Median and 10th/90th percentiles of the voiced frames; null without any.
pub fn stats(alloc: std.mem.Allocator, hz: []const f32) !?Stats {
    var v: std.ArrayList(f32) = .empty;
    defer v.deinit(alloc);
    for (hz) |h| if (h > 0) try v.append(alloc, h);
    if (v.items.len == 0) return null;
    std.mem.sort(f32, v.items, {}, std.sort.asc(f32));
    const at = struct {
        fn f(s: []const f32, p: f32) f32 {
            const i: usize = @trunc(@round(p * @as(f32, @floatFromInt(s.len - 1))));
            return s[i];
        }
    }.f;
    return .{ .median = at(v.items, 0.5), .low = at(v.items, 0.1), .high = at(v.items, 0.9), .voiced = v.items.len };
}

// ---- tests ----

const testing = std.testing;

fn harmonic(alloc: std.mem.Allocator, rate: u32, hz: f64, secs: f64) ![]f32 {
    // a buzzy voice-like tone: five harmonics falling off
    const n: usize = @trunc(secs * @as(f64, @floatFromInt(rate)));
    const s = try alloc.alloc(f32, n);
    for (s, 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        var acc: f64 = 0;
        for (1..6) |k| acc += @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(k)) * t) / @as(f64, @floatFromInt(k));
        v.* = @floatCast(0.3 * acc);
    }
    return s;
}

test "yin_finds_a_pure_tone" {
    var scratch: [1024]f32 = undefined;
    const x = try harmonic(testing.allocator, 16000, 200, 0.1);
    defer testing.allocator.free(x);
    const p = yin(x, 16000, &scratch).?;
    try testing.expectApproxEqAbs(@as(f32, 200), p.hz, 1.0);
    try testing.expect(p.aperiodicity < threshold);
}

test "yin_low_and_high_voices" {
    var scratch: [1024]f32 = undefined;
    for ([_]f64{ 85, 120, 310 }) |hz| {
        const x = try harmonic(testing.allocator, 16000, hz, 0.1);
        defer testing.allocator.free(x);
        const p = yin(x, 16000, &scratch).?;
        try testing.expectApproxEqAbs(@as(f32, @floatCast(hz)), p.hz, @as(f32, @floatCast(hz * 0.01)));
    }
}

test "noise_and_silence_are_unvoiced" {
    var scratch: [1024]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var x: [1024]f32 = undefined;
    for (&x) |*v| v.* = (r.float(f32) - 0.5) * 0.5;
    try testing.expect(yin(&x, 16000, &scratch) == null);
    @memset(&x, 0);
    try testing.expect(yin(&x, 16000, &scratch) == null);
}

test "track_and_stats" {
    const x = try harmonic(testing.allocator, 16000, 150, 1);
    defer testing.allocator.free(x);
    const hz = try track(testing.allocator, x, 16000, null);
    defer testing.allocator.free(hz);
    try testing.expect(hz.len > 80);
    const st = (try stats(testing.allocator, hz)).?;
    try testing.expectApproxEqAbs(@as(f32, 150), st.median, 1.0);
    try testing.expectEqual(hz.len, st.voiced);
}

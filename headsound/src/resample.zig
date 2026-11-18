//! Sample-rate conversion with a Kaiser-windowed sinc (16 zero crossings,
//! table-driven). Stopband below about -80 dB; the passband ends at 94% of
//! the lower Nyquist frequency.
const std = @import("std");

const zero_crossings = 16;
const phases = 512; // table entries per zero crossing
const beta = 8.6;

var table: [zero_crossings * phases + 2]f32 = undefined;
/// 0: not built, 1: one thread is building it, 2: ready.
var table_state = std.atomic.Value(u8).init(0);

fn bessel0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 40) : (k += 1) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
        if (term < 1e-12 * sum) break;
    }
    return sum;
}

fn kernel() *const [zero_crossings * phases + 2]f32 {
    if (table_state.load(.acquire) == 2) return &table;
    if (table_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        const norm = bessel0(beta);
        for (&table, 0..) |*t, i| {
            const u = @as(f64, @floatFromInt(i)) / phases; // in zero crossings
            if (u >= zero_crossings) {
                t.* = 0;
                continue;
            }
            const sinc = if (i == 0) 1.0 else @sin(std.math.pi * u) / (std.math.pi * u);
            const r = u / zero_crossings;
            t.* = @floatCast(sinc * bessel0(beta * @sqrt(1 - r * r)) / norm);
        }
        table_state.store(2, .release);
        return &table;
    }
    // Another thread is filling the table (a few milliseconds of work).
    while (table_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    return &table;
}

/// `x` (one channel at `from` Hz) converted to `to` Hz. Caller frees.
pub fn resample(alloc: std.mem.Allocator, x: []const f32, from: u32, to: u32) ![]f32 {
    if (from == to) return alloc.dupe(f32, x);
    const t = kernel();
    const ratio = @as(f64, @floatFromInt(to)) / @as(f64, @floatFromInt(from));
    const cutoff = @min(1.0, ratio) * 0.94; // relative to the input's Nyquist
    const half_width = @as(f64, zero_crossings) / cutoff; // in input samples
    const n_out: usize = @trunc(@floor(@as(f64, @floatFromInt(x.len)) * ratio));
    const out = try alloc.alloc(f32, n_out);
    const len: i64 = @intCast(x.len);
    for (out, 0..) |*o, n| {
        const center = @as(f64, @floatFromInt(n)) / ratio;
        const lo: i64 = @max(0, @as(i64, @trunc(@ceil(center - half_width))));
        const hi: i64 = @min(len - 1, @as(i64, @trunc(@floor(center + half_width))));
        var acc: f64 = 0;
        var k = lo;
        while (k <= hi) : (k += 1) {
            const u = @abs(center - @as(f64, @floatFromInt(k))) * cutoff * phases;
            const idx: usize = @trunc(u);
            if (idx >= zero_crossings * phases) continue;
            const frac: f32 = @floatCast(u - @as(f64, @floatFromInt(idx)));
            const w = t[idx] + (t[idx + 1] - t[idx]) * frac;
            acc += @as(f64, x[@intCast(k)]) * w;
        }
        o.* = @floatCast(acc * cutoff);
    }
    return out;
}

// ---- tests ----

const testing = std.testing;

fn tone(alloc: std.mem.Allocator, rate: u32, hz: f64, secs: f64) ![]f32 {
    const n: usize = @trunc(secs * @as(f64, @floatFromInt(rate)));
    const s = try alloc.alloc(f32, n);
    for (s, 0..) |*v, i| v.* = @floatCast(0.5 * @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate))));
    return s;
}

/// RMS of the middle half (away from the edges).
fn rms(x: []const f32) f64 {
    const m = x[x.len / 4 .. x.len * 3 / 4];
    var s: f64 = 0;
    for (m) |v| s += @as(f64, v) * v;
    return @sqrt(s / @as(f64, @floatFromInt(m.len)));
}

fn zeroCrossings(x: []const f32) usize {
    var n: usize = 0;
    for (1..x.len) |i| {
        if ((x[i - 1] < 0) != (x[i] < 0)) n += 1;
    }
    return n;
}

test "downsample_keeps_a_tone_in_the_passband" {
    const x = try tone(testing.allocator, 48000, 1000, 1);
    defer testing.allocator.free(x);
    const y = try resample(testing.allocator, x, 48000, 16000);
    defer testing.allocator.free(y);
    try testing.expectEqual(@as(usize, 16000), y.len);
    try testing.expectApproxEqAbs(0.5 / @sqrt(2.0), rms(y), 0.005);
    // 1000 Hz for one second: about 2000 zero crossings
    try testing.expect(@abs(@as(i64, @intCast(zeroCrossings(y))) - 2000) <= 2);
}

test "downsample_removes_what_would_alias" {
    const x = try tone(testing.allocator, 48000, 9000, 1);
    defer testing.allocator.free(x);
    const y = try resample(testing.allocator, x, 48000, 16000);
    defer testing.allocator.free(y);
    try testing.expect(rms(y) < 0.5 / @sqrt(2.0) * 0.001); // below -60 dB
}

test "upsample_odd_ratio" {
    const x = try tone(testing.allocator, 22050, 440, 1);
    defer testing.allocator.free(x);
    const y = try resample(testing.allocator, x, 22050, 48000);
    defer testing.allocator.free(y);
    try testing.expectEqual(@as(usize, 48000), y.len);
    try testing.expectApproxEqAbs(0.5 / @sqrt(2.0), rms(y), 0.005);
    try testing.expect(@abs(@as(i64, @intCast(zeroCrossings(y))) - 880) <= 2);
}

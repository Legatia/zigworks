//! Clicks and pops: found as bursts the signal's own short-term prediction
//! (a linear predictor fitted to each 2048-sample block) can't explain, and
//! repaired by least-squares autoregressive interpolation (Vaseghi & Rayner;
//! Janssen et al.). A burst that starts a louder stretch (a drum hit, a "t")
//! is a transient, not a click.
const std = @import("std");

pub const order = 16;
const block = 2048;
/// Residual peaks this many robust standard deviations out count.
const threshold = 6.0;

pub const Click = struct {
    /// Sample range [start, end) that is damaged.
    start: usize,
    end: usize,
    /// Peak of the prediction error, as an amplitude.
    height: f32,
};

/// Predictor coefficients a[1..p] (a[0] = 1) for the autocorrelation `r`
/// (Levinson-Durbin). False when the signal is silent.
fn levinson(r: []const f64, a: []f64) bool {
    const p = a.len - 1;
    @memset(a, 0);
    a[0] = 1;
    if (r[0] <= 1e-20) return false;
    var err = r[0] * (1 + 1e-9); // a little white noise keeps it stable
    var tmp: [65]f64 = undefined;
    for (1..p + 1) |i| {
        var acc = r[i];
        for (1..i) |j| acc += a[j] * r[i - j];
        const k = -acc / err;
        @memcpy(tmp[0 .. i + 1], a[0 .. i + 1]);
        for (1..i) |j| a[j] = tmp[j] + k * tmp[i - j];
        a[i] = k;
        err *= (1 - k * k);
        if (err <= 0) return false;
    }
    return true;
}

/// Adds the autocorrelation (lags 0..p) of Hann-windowed `x` to `r`.
fn autocorr(x: []const f32, r: []f64) void {
    const n = x.len;
    if (n < 2) return;
    var buf: [4096]f64 = undefined;
    const m = @min(n, buf.len);
    for (0..m) |i| buf[i] = x[i] * (0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(m - 1))));
    for (r, 0..) |*v, lag| {
        if (lag >= m) break;
        var s: f64 = 0;
        for (0..m - lag) |i| s += buf[i] * buf[i + lag];
        v.* += s;
    }
}

fn median(v: []f32) f32 {
    std.mem.sort(f32, v, {}, std.sort.asc(f32));
    return v[v.len / 2];
}

fn peakOf(x: []const f32) f32 {
    var m: f32 = 0;
    for (x) |v| m = @max(m, @abs(v));
    return m;
}

fn rmsOf(x: []const f32) f64 {
    if (x.len == 0) return 0;
    var s: f64 = 0;
    for (x) |v| s += @as(f64, v) * v;
    return @sqrt(s / @as(f64, @floatFromInt(x.len)));
}

/// The smallest click counted, as an amplitude: about -70 dBFS for PCM.
pub const floor_pcm: f32 = 3e-4;
/// For files decoded from a lossy codec (AAC, MP3, Opus), whose own
/// artifacts in quiet parts look like small clicks: -40 dBFS.
pub const floor_lossy: f32 = 0.01;

/// Clicks in one channel `x` at `rate`, none smaller than `floor`.
pub fn detect(alloc: std.mem.Allocator, x: []const f32, rate: u32, floor: f32) ![]Click {
    var out: std.ArrayList(Click) = .empty;
    errdefer out.deinit(alloc);
    // Prediction error of the whole channel, each block with its own model.
    const e = try alloc.alloc(f32, x.len);
    defer alloc.free(e);
    @memset(e, 0);
    var a: [order + 1]f64 = undefined;
    var b: usize = 0;
    while (b < x.len) : (b += block) {
        const end = @min(x.len, b + block);
        var r = [_]f64{0} ** (order + 1);
        autocorr(x[b..end], &r);
        if (!levinson(&r, &a)) continue; // silence
        for (b..end) |n| {
            var sum: f64 = x[n];
            for (1..order + 1) |k| {
                if (n >= k) sum += a[k] * x[n - k];
            }
            e[n] = @floatCast(sum);
        }
    }
    // The threshold follows the error's usual size nearby (robust: a median
    // per 512 samples, the largest of three neighbours), so a quiet stretch
    // just before speech doesn't make the speech look like clicks.
    const sub = 512;
    const n_sub = (x.len + sub - 1) / sub;
    const med = try alloc.alloc(f32, n_sub);
    defer alloc.free(med);
    const mag = try alloc.alloc(f32, sub);
    defer alloc.free(mag);
    for (med, 0..) |*m, k| {
        const s0 = k * sub;
        const s1 = @min(x.len, s0 + sub);
        for (s0..s1) |n| mag[n - s0] = @abs(e[n]);
        m.* = median(mag[0 .. s1 - s0]);
    }
    const lims = try alloc.alloc(f32, n_sub);
    defer alloc.free(lims);
    for (lims, 0..) |*l, k| {
        var m = med[k];
        if (k > 0) m = @max(m, med[k - 1]);
        if (k + 1 < n_sub) m = @max(m, med[k + 1]);
        l.* = @max(threshold * 1.4826 * m, floor);
    }

    const join_gap: usize = @max(1, rate / 1000); // 1 ms
    const max_len: usize = rate * 4 / 1000; // 4 ms
    const ctx: usize = rate / 100; // 10 ms
    const guard: usize = rate * 3 / 2000; // 1.5 ms
    const reach: usize = rate * 15 / 1000; // 15 ms
    var i: usize = 0;
    while (i < x.len) : (i += 1) {
        const lim = lims[i / sub];
        if (@abs(e[i]) <= lim) continue;
        var last = i;
        var height: f32 = @abs(e[i]);
        var j = i;
        while (j + 1 < x.len and j + 1 <= last + join_gap) : (j += 1) {
            if (@abs(e[j + 1]) > lims[(j + 1) / sub]) {
                last = j + 1;
                height = @max(height, @abs(e[j + 1]));
            }
        }
        var s0 = i;
        var s1 = last + 1;
        i = last;
        // One spike towering over the rest of the burst is a click even on
        // the start of a word; keep just that spike.
        var m = s0;
        for (s0..s1) |k| if (@abs(e[k]) > @abs(e[m])) {
            m = k;
        };
        const lo = @max(s0, m -| join_gap);
        const hi = @min(s1, m + join_gap + order);
        const dominant = @max(peakOf(e[s0..lo]), peakOf(e[hi..s1])) * 3 <= height;
        if (dominant) {
            // from the first to the last large error near the spike (a
            // short pop has one at each edge)
            s0 = m;
            s1 = m + 1;
            for (lo..hi) |k| if (@abs(e[k]) > 0.3 * height) {
                s0 = @min(s0, k);
                s1 = @max(s1, k + 1);
            };
        } else if (s1 - s0 > max_len) continue;
        if (s0 < ctx + guard or s1 + ctx + guard > x.len) continue;
        // A transient starts something much louder (a "t" after a pause, a
        // hit after quiet); a click leaves the level as it was. A towering
        // spike may sit on the start of a word (up to 18 dB louder after).
        const before = rmsOf(x[s0 - guard - ctx .. s0 - guard]);
        const after = rmsOf(x[s1 + guard .. s1 + guard + ctx]);
        if (after > @as(f64, if (dominant) 8.0 else 4.0) * before + 1e-5) continue;
        // In noise (a cymbal, a drum's tail, hiss) the error is large all
        // around; a click stands far out of what surrounds it.
        const around = @max(rmsOf(e[s0 - guard - ctx .. s0 - guard]), rmsOf(e[s1 + guard .. s1 + guard + ctx]));
        if (height < 8.0 * around) continue;
        // A voice is driven by a pulse every pitch period (2.5 to 15 ms): an
        // error spike with others of similar size around it is the voice.
        if (s0 >= guard + reach and s1 + guard + reach <= x.len) {
            const near = @max(peakOf(e[s0 - guard - reach .. s0 - guard]), peakOf(e[s1 + guard .. s1 + guard + reach]));
            if (near > 0.35 * height) continue;
        }
        if (out.items.len > 0 and s0 <= out.items[out.items.len - 1].end + join_gap) {
            const lc = &out.items[out.items.len - 1];
            lc.end = s1;
            lc.height = @max(lc.height, height);
        } else try out.append(alloc, .{ .start = s0, .end = s1, .height = height });
    }
    return out.toOwnedSlice(alloc);
}

/// Replaces x[start..end) by the values that best continue the signal on
/// both sides (least-squares AR interpolation). False when the gap is longer
/// than the longest click found (4 ms, with room to spare: 5 ms or 400
/// samples) or the context too short; x is then unchanged.
pub fn repair(alloc: std.mem.Allocator, x: []f32, start: usize, end: usize, rate: u32) !bool {
    const p = 32;
    const m = end - start;
    if (m == 0) return true;
    if (m > @max(400, rate / 200)) return false;
    const ctx = @max(1024, 4 * m);
    if (start < p + 8 or end + p + 8 > x.len) return false;
    const c0 = start -| ctx;
    const c1 = @min(x.len, end + ctx);
    // AR model from the clean context on both sides
    var r = [_]f64{0} ** (p + 1);
    autocorr(x[c0..start], &r);
    autocorr(x[end..c1], &r);
    var a: [p + 1]f64 = undefined;
    if (!levinson(&r, &a)) {
        // silence around it: silence in it
        @memset(x[start..end], 0);
        return true;
    }
    // Normal equations: R_a(|i-j|) x_j = -sum_n a_{n-u_i} c[n].
    var ra: [p + 1]f64 = undefined;
    for (0..p + 1) |d| {
        var s: f64 = 0;
        for (0..p + 1 - d) |k| s += a[k] * a[k + d];
        ra[d] = s;
    }
    const mat = try alloc.alloc(f64, m * m);
    defer alloc.free(mat);
    const rhs = try alloc.alloc(f64, m);
    defer alloc.free(rhs);
    for (0..m) |i| for (0..m) |j| {
        const d = if (i > j) i - j else j - i;
        mat[i * m + j] = if (d <= p) ra[d] else 0;
    };
    // c[n]: the known part of the prediction error at n in [start, end + p)
    @memset(rhs, 0);
    for (start..end + p) |n| {
        var cn: f64 = 0;
        for (0..p + 1) |k| {
            const idx = n - k;
            if (idx < start or idx >= end) cn += a[k] * x[idx];
        }
        // every unknown u = n - k with k in 0..p
        for (0..p + 1) |k| {
            const idx = n -% k;
            if (idx >= start and idx < end) rhs[idx - start] -= a[k] * cn;
        }
    }
    // Cholesky, in place
    for (0..m) |j| {
        var s = mat[j * m + j];
        for (0..j) |k| s -= mat[j * m + k] * mat[j * m + k];
        if (s <= 0) return false;
        const d = @sqrt(s);
        mat[j * m + j] = d;
        for (j + 1..m) |i| {
            var t = mat[i * m + j];
            for (0..j) |k| t -= mat[i * m + k] * mat[j * m + k];
            mat[i * m + j] = t / d;
        }
    }
    // L y = rhs, then L^T x = y
    for (0..m) |i| {
        var s = rhs[i];
        for (0..i) |k| s -= mat[i * m + k] * rhs[k];
        rhs[i] = s / mat[i * m + i];
    }
    var i: usize = m;
    while (i > 0) {
        i -= 1;
        var s = rhs[i];
        for (i + 1..m) |k| s -= mat[k * m + i] * rhs[k];
        rhs[i] = s / mat[i * m + i];
    }
    for (0..m) |k| x[start + k] = @floatCast(rhs[k]);
    return true;
}

// ---- tests ----

const testing = std.testing;

/// Music-like test signal: three tones with vibrato and a little noise.
fn music(alloc: std.mem.Allocator, rate: u32, secs: f64, seed: u64) ![]f32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const n: usize = @intFromFloat(secs * @as(f64, @floatFromInt(rate)));
    const s = try alloc.alloc(f32, n);
    const fs: f64 = @floatFromInt(rate);
    for (s, 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / fs;
        const vib = 1 + 0.003 * @sin(2 * std.math.pi * 5 * t);
        var acc: f64 = 0;
        for ([_]f64{ 220, 277.2, 329.6 }) |f| {
            for (1..6) |h| acc += @sin(2 * std.math.pi * f * vib * @as(f64, @floatFromInt(h)) * t) / @as(f64, @floatFromInt(h * h));
        }
        v.* = @floatCast(0.15 * acc + (rnd.float(f64) - 0.5) * 0.002);
    }
    return s;
}

test "clicks_are_found_where_they_are" {
    const rate = 44100;
    const x = try music(testing.allocator, rate, 3, 1);
    defer testing.allocator.free(x);
    const at = [_]usize{ 22050, 50000, 90001, 110000 };
    x[at[0]] += 0.4; // one sample
    for (0..20) |k| x[at[1] + k] += 0.3 * @as(f32, if (k % 2 == 0) 1 else -0.7); // 0.5 ms crackle
    x[at[2]] -= 0.15;
    x[at[3]] += 0.08; // small, under the music
    const cs = try detect(testing.allocator, x, rate, floor_pcm);
    defer testing.allocator.free(cs);
    try testing.expectEqual(@as(usize, 4), cs.len);
    for (cs, at) |c, want| {
        try testing.expect(c.start <= want + 2 and c.end > want);
        try testing.expect(c.end - c.start < 100);
    }
}

test "clean_music_and_drum_hits_are_not_clicks" {
    const rate = 44100;
    const x = try music(testing.allocator, rate, 3, 2);
    defer testing.allocator.free(x);
    var prng = std.Random.DefaultPrng.init(9);
    const rnd = prng.random();
    // drum hits: noise bursts with a sharp start and a 80 ms decay
    for ([_]usize{ 30000, 70000, 100000 }) |h| {
        for (0..8000) |k| {
            const env = @exp(-@as(f64, @floatFromInt(k)) / (0.08 * rate));
            x[h + k] += @floatCast(0.5 * env * (rnd.float(f64) - 0.5));
        }
    }
    const cs = try detect(testing.allocator, x, rate, floor_pcm);
    defer testing.allocator.free(cs);
    try testing.expectEqual(@as(usize, 0), cs.len);
}

test "repair_restores_the_signal_under_a_click" {
    const rate = 44100;
    const clean = try music(testing.allocator, rate, 1, 3);
    defer testing.allocator.free(clean);
    // a sharp click (8 samples) and a 1 ms pop
    for ([_][2]usize{ .{ 8, 1 }, .{ 40, 0 } }) |shape| {
        const x = try testing.allocator.dupe(f32, clean);
        defer testing.allocator.free(x);
        for (20000..20000 + shape[0]) |i| x[i] += if (shape[1] == 1 and i % 2 == 1) -0.5 else 0.5;
        const cs = try detect(testing.allocator, x, rate, floor_pcm);
        defer testing.allocator.free(cs);
        try testing.expectEqual(@as(usize, 1), cs.len);
        try testing.expect(try repair(testing.allocator, x, cs[0].start, cs[0].end, rate));
        // everything outside the repaired span is untouched
        for (0..cs[0].start) |i| try testing.expectEqual(clean[i], x[i]);
        for (cs[0].end..x.len) |i| try testing.expectEqual(clean[i], x[i]);
        var err: f64 = 0;
        for (cs[0].start..cs[0].end) |i| err += (x[i] - clean[i]) * (x[i] - clean[i]);
        const err_rms = @sqrt(err / @as(f64, @floatFromInt(cs[0].end - cs[0].start)));
        // the signal there is about 0.36 RMS
        try testing.expect(err_rms < @as(f64, if (shape[0] == 8) 0.01 else 0.04));
    }
}

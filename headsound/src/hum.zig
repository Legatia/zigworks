//! Mains hum: steady peaks at 50 or 60 Hz and their harmonics, found in
//! 2-second spectra of the signal at 4 kHz, and removed with narrow notch
//! filters run forwards and backwards (no phase shift).
const std = @import("std");
const audio = @import("audio.zig");
const resample = @import("resample.zig");
const fft = @import("fft.zig");
const Biquad = @import("biquad.zig").Biquad;
const Audio = audio.Audio;

const rate_lo: u32 = 4000;
pub const max_harmonics = 16;

pub const Hum = struct {
    /// Seconds.
    start: f64,
    end: f64,
    /// The fundamental (50 or 60 Hz, as measured).
    freq: f64,
    /// dBFS of all its harmonics together (as a sine's peak).
    level: f64,
    /// Bit k-1 set when harmonic k is there.
    mask: u32,

    pub fn harmonics(h: Hum) u32 {
        return @popCount(h.mask);
    }
};

const Block = struct { found: bool, base: f64 = 0, freq: f64 = 0, power: f64 = 0, mask: u32 = 0 };

/// Peak bin power (3 bins) around `hz` and its height over the median of
/// the bins 2 to 8 Hz away, in dB.
fn prominence(p: []const f64, binw: f64, hz: f64, scratch: []f64) struct { db: f64, power: f64, at: f64 } {
    const c: usize = @trunc(@round(hz / binw));
    if (c < 2 or c + 2 >= p.len) return .{ .db = 0, .power = 0, .at = hz };
    var best = c;
    for (c - 1..c + 2) |i| if (p[i] > p[best]) {
        best = i;
    };
    const pw = p[best - 1] + p[best] + p[best + 1];
    const near: usize = @trunc(@ceil(2.0 / binw));
    const far: usize = @trunc(@ceil(8.0 / binw));
    var n: usize = 0;
    var i: usize = c -| far;
    while (i <= @min(p.len - 1, c + far)) : (i += 1) {
        const d = if (i > c) i - c else c - i;
        if (d < near) continue;
        scratch[n] = p[i];
        n += 1;
    }
    if (n == 0) return .{ .db = 0, .power = 0, .at = hz };
    std.mem.sort(f64, scratch[0..n], {}, std.sort.asc(f64));
    const med = @max(scratch[n / 2], 1e-30);
    // the peak's centre, from a parabola through the log powers
    const l0 = @log(@max(p[best - 1], 1e-30));
    const l1 = @log(@max(p[best], 1e-30));
    const l2 = @log(@max(p[best + 1], 1e-30));
    const den = l0 - 2 * l1 + l2;
    const shift = if (den != 0) std.math.clamp(0.5 * (l0 - l2) / den, -0.5, 0.5) else 0;
    return .{ .db = 10 * std.math.log10(pw / (3 * med)), .power = pw, .at = (@as(f64, @floatFromInt(best)) + shift) * binw };
}

/// Hum in one spectrum: two or more harmonics 10 dB over their
/// neighbourhood, or one of the first three `strong_db` over it.
fn analyzeBlock(p: []const f64, binw: f64, scratch: []f64, strong_db: f64) Block {
    var best = Block{ .found = false };
    var best_count: u32 = 0;
    for ([_]f64{ 50, 60 }) |base| {
        // the fundamental from the strongest of the first three harmonics
        var f = base;
        var top: f64 = 0;
        for (1..4) |k| {
            const kf: f64 = @floatFromInt(k);
            const pr = prominence(p, binw, base * kf, scratch);
            if (pr.db > top and @abs(pr.at / kf - base) <= 0.6) {
                top = pr.db;
                f = pr.at / kf;
            }
        }
        var mask: u32 = 0;
        var power: f64 = 0;
        var strong = false;
        for (1..max_harmonics + 1) |k| {
            const kf: f64 = @floatFromInt(k);
            if (f * kf >= @as(f64, @floatFromInt(rate_lo)) * 0.47) break;
            const pr = prominence(p, binw, f * kf, scratch);
            if (pr.db >= 10) {
                mask |= @as(u32, 1) << @intCast(k - 1);
                power += pr.power;
                if (k <= 3 and pr.db >= strong_db) strong = true;
            }
        }
        const count = @popCount(mask);
        // Mains hum always has its fundamental, 2nd or 3rd harmonic; a
        // steady tone's harmonics can land on 7 x 60 and 14 x 60 alone.
        const low = mask & 0b111 != 0;
        if (low and (count >= 2 or strong) and count > best_count) {
            best_count = count;
            best = .{ .found = true, .base = base, .freq = f, .power = power, .mask = mask };
        }
    }
    return best;
}

/// Hum at the harmonics of `freq` in `mask` in one block's spectrum, with
/// a lower bar than finding it from nothing (6 dB): the frequency is known.
fn knownHum(p: []const f64, binw: f64, freq: f64, mask: u32, scratch: []f64) Block {
    var found: u32 = 0;
    var power: f64 = 0;
    for (1..max_harmonics + 1) |k| {
        if (mask & (@as(u32, 1) << @intCast(k - 1)) == 0) continue;
        const pr = prominence(p, binw, freq * @as(f64, @floatFromInt(k)), scratch);
        if (pr.db >= 6) {
            found |= @as(u32, 1) << @intCast(k - 1);
            power += pr.power;
        }
    }
    return .{ .found = found != 0, .base = 0, .freq = freq, .power = power, .mask = found };
}

/// Hum in `x` (one channel or a mix) at `rate`, as stretches. Hum is steady
/// and a voice isn't, so the spectrum averaged over the whole file (in dB)
/// shows hum
/// that single 2 s blocks under loud speech miss; once found there, blocks
/// count with a lower bar. Hum in a part only is found block by block.
pub fn detect(alloc: std.mem.Allocator, x: []const f32, rate: u32) ![]Hum {
    const lo = try resample.resample(alloc, x, rate, rate_lo);
    defer alloc.free(lo);
    const n: usize = if (lo.len >= 8192) 8192 else if (lo.len >= 4096) 4096 else return alloc.alloc(Hum, 0);
    var spec = try fft.Spectrum.init(alloc, n);
    defer spec.deinit(alloc);
    const scratch = try alloc.alloc(f64, n);
    defer alloc.free(scratch);
    const binw = @as(f64, @floatFromInt(rate_lo)) / @as(f64, @floatFromInt(n));
    const secs_per = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(rate_lo));
    // blocks; the last one may overlap the one before so the end is covered
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(alloc);
    var b: usize = 0;
    while (b < lo.len) : (b += n) {
        const start = if (b + n <= lo.len) b else lo.len - n;
        try starts.append(alloc, start);
        if (start != b) break;
    }
    const blocks = try alloc.alloc(Block, starts.items.len);
    defer alloc.free(blocks);
    const avg = try alloc.alloc(f64, n / 2 + 1);
    defer alloc.free(avg);
    @memset(avg, 0);
    // the average of the log powers: a few loud events (pops, a slammed
    // door) don't bury the steady peaks the way a plain average would
    for (starts.items, blocks) |start, *blk| {
        const p = spec.compute(lo[start..][0..n]);
        for (avg, p) |*v, q| v.* += @log(@max(q, 1e-30));
        blk.* = analyzeBlock(p, binw, scratch, 20);
    }
    for (avg) |*v| v.* = @exp(v.* / @as(f64, @floatFromInt(starts.items.len)));
    // averaged over the file a single steady line is already convincing
    const whole = analyzeBlock(avg, binw, scratch, 12);
    if (whole.found) {
        for (starts.items, blocks) |start, *blk| {
            if (blk.found) continue;
            const k = knownHum(spec.compute(lo[start..][0..n]), binw, whole.freq, whole.mask, scratch);
            if (k.found) blk.* = k;
        }
    }

    var out: std.ArrayList(Hum) = .empty;
    errdefer out.deinit(alloc);
    var sums = struct { freq: f64 = 0, blocks: f64 = 0 }{};
    for (starts.items, blocks) |start, blk| {
        if (!blk.found) continue;
        const t0 = @as(f64, @floatFromInt(start)) / @as(f64, @floatFromInt(rate_lo));
        const lv = audio.db(@sqrt(2 * blk.power));
        // up to two blocks without it (a loud word over it) don't split it
        if (out.items.len > 0 and @abs(out.items[out.items.len - 1].freq - blk.freq) < 2 and
            out.items[out.items.len - 1].end >= t0 - 2 * secs_per - 1e-6)
        {
            const h = &out.items[out.items.len - 1];
            sums.freq += blk.freq;
            sums.blocks += 1;
            h.freq = sums.freq / sums.blocks;
            h.end = t0 + secs_per;
            h.level = @max(h.level, lv);
            h.mask |= blk.mask;
        } else {
            sums = .{ .freq = blk.freq, .blocks = 1 };
            try out.append(alloc, .{ .start = t0, .end = t0 + secs_per, .freq = blk.freq, .level = lv, .mask = blk.mask });
        }
    }
    const dur = @as(f64, @floatFromInt(x.len)) / @as(f64, @floatFromInt(rate));
    for (out.items) |*h| h.end = @min(h.end, dur);
    return out.toOwnedSlice(alloc);
}

/// Notch filters at the harmonics of `freq` in `mask`, run forwards and
/// backwards over every channel of `a` (in place). Each notch is `width` Hz
/// wide at the fundamental and wider up the series, where the hum drifts
/// more (k * width / 4 at harmonic k, once that is wider).
pub fn remove(alloc: std.mem.Allocator, a: Audio, freq: f64, mask: u32, width: f64) !void {
    var notches: [max_harmonics]Biquad = undefined;
    var nn: usize = 0;
    const nyq = @as(f64, @floatFromInt(a.rate)) / 2;
    for (1..max_harmonics + 1) |k| {
        if (mask & (@as(u32, 1) << @intCast(k - 1)) == 0) continue;
        const f = freq * @as(f64, @floatFromInt(k));
        if (f >= nyq * 0.95) break;
        const bw = @max(width, width / 4 * @as(f64, @floatFromInt(k)));
        notches[nn] = notch(a.rate, f, f / bw);
        nn += 1;
    }
    if (nn == 0) return;
    const frames = a.frames();
    // a second of the signal mirrored at each end, so the filters have
    // settled before the real start and end
    const pad = @min(frames -| 1, a.rate);
    const buf = try alloc.alloc(f64, frames + 2 * pad);
    defer alloc.free(buf);
    for (0..a.channels) |c| {
        for (0..frames) |i| buf[pad + i] = a.samples[i * a.channels + c];
        for (0..pad) |i| {
            buf[pad - 1 - i] = 2 * buf[pad] - buf[pad + 1 + i];
            buf[pad + frames + i] = 2 * buf[pad + frames - 1] - buf[pad + frames - 2 - i];
        }
        for (notches[0..nn]) |proto| {
            var f = proto;
            for (buf) |*v| v.* = f.process(v.*);
            f = proto;
            var i: usize = buf.len;
            while (i > 0) {
                i -= 1;
                buf[i] = f.process(buf[i]);
            }
        }
        for (0..frames) |i| a.samples[i * a.channels + c] = @floatCast(buf[pad + i]);
    }
}

fn notch(rate: u32, f: f64, q: f64) Biquad {
    const w0 = 2.0 * std.math.pi * f / @as(f64, @floatFromInt(rate));
    const alpha = @sin(w0) / (2.0 * q);
    const c = @cos(w0);
    const a0 = 1.0 + alpha;
    return .{ .b0 = 1 / a0, .b1 = -2 * c / a0, .b2 = 1 / a0, .a1 = -2 * c / a0, .a2 = (1 - alpha) / a0 };
}

// ---- tests ----

const testing = std.testing;

/// A voice-like buzz around 140 Hz whose pitch wanders, plus hum.
fn voiceWithHum(alloc: std.mem.Allocator, rate: u32, secs: f64, hum_hz: f64, hum_db: f64, hum_from: f64) ![]f32 {
    const n: usize = @trunc(secs * @as(f64, @floatFromInt(rate)));
    const s = try alloc.alloc(f32, n);
    const fs: f64 = @floatFromInt(rate);
    const amp = audio.fromDb(hum_db);
    var ph: f64 = 0;
    for (s, 0..) |*v, i| {
        const t = @as(f64, @floatFromInt(i)) / fs;
        const f0 = 140 * (1 + 0.06 * @sin(2 * std.math.pi * 0.7 * t) + 0.03 * @sin(2 * std.math.pi * 2.3 * t));
        ph += 2 * std.math.pi * f0 / fs;
        var acc: f64 = 0;
        for (1..9) |h| acc += @sin(ph * @as(f64, @floatFromInt(h))) / @as(f64, @floatFromInt(h));
        var hum: f64 = 0;
        if (t >= hum_from) {
            for ([_]f64{ 1, 2, 3, 5 }, [_]f64{ 1, 0.6, 0.5, 0.3 }) |k, g|
                hum += g * @sin(2 * std.math.pi * hum_hz * k * t);
        }
        v.* = @floatCast(0.2 * acc * (0.6 + 0.4 * @sin(2 * std.math.pi * 3 * t)) + amp * hum);
    }
    return s;
}

test "hum_is_found_with_its_frequency_and_harmonics" {
    const x = try voiceWithHum(testing.allocator, 44100, 10, 60.0, -40, 4.0);
    defer testing.allocator.free(x);
    const hs = try detect(testing.allocator, x, 44100);
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expectApproxEqAbs(@as(f64, 60), hs[0].freq, 0.1);
    try testing.expect(hs[0].start >= 2 and hs[0].start <= 4.1);
    try testing.expectApproxEqAbs(@as(f64, 10), hs[0].end, 0.01);
    // the 5th harmonic (-50 dBFS) is under the voice's own harmonics
    try testing.expect(hs[0].mask & 0b111 == 0b111);
    try testing.expect(hs[0].level > -42 and hs[0].level < -35);
}

test "fifty_hertz_and_no_hum" {
    const x = try voiceWithHum(testing.allocator, 48000, 6, 50.0, -50, 0);
    defer testing.allocator.free(x);
    const hs = try detect(testing.allocator, x, 48000);
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expectApproxEqAbs(@as(f64, 50), hs[0].freq, 0.1);
    const clean = try voiceWithHum(testing.allocator, 48000, 6, 50.0, -200, 100);
    defer testing.allocator.free(clean);
    const none = try detect(testing.allocator, clean, 48000);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "remove_takes_the_hum_out_and_leaves_the_voice" {
    const rate = 44100;
    const x = try voiceWithHum(testing.allocator, rate, 8, 60.0, -35, 0);
    defer testing.allocator.free(x);
    const voice = try voiceWithHum(testing.allocator, rate, 8, 60.0, -200, 100);
    defer testing.allocator.free(voice);
    const hs = try detect(testing.allocator, x, rate);
    defer testing.allocator.free(hs);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try remove(testing.allocator, .{ .rate = rate, .channels = 1, .samples = x }, hs[0].freq, hs[0].mask, 1.0);
    const after = try detect(testing.allocator, x, rate);
    defer testing.allocator.free(after);
    for (after) |h| try testing.expect(h.level < hs[0].level - 25);
    // what is left differs from the voice alone by little (about -25 dB)
    var err: f64 = 0;
    var sig: f64 = 0;
    for (x[rate..], voice[rate..]) |a, b| {
        err += (a - b) * (a - b);
        sig += b * b;
    }
    try testing.expect(10 * std.math.log10(err / sig) < -25);
}

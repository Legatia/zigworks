//! Radix-2 complex FFT (in place) and a Hann-windowed power spectrum.
const std = @import("std");

/// In-place forward FFT of `re`/`im` (length a power of two).
pub fn fft(re: []f64, im: []f64) void {
    const n = re.len;
    std.debug.assert(n == im.len and std.math.isPowerOfTwo(n));
    // bit reversal
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std.mem.swap(f64, &re[i], &re[j]);
            std.mem.swap(f64, &im[i], &im[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var i: usize = 0;
        while (i < n) : (i += len) {
            var cr: f64 = 1;
            var ci: f64 = 0;
            for (0..len / 2) |k| {
                const a = i + k;
                const b = a + len / 2;
                const tr = re[b] * cr - im[b] * ci;
                const ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                const ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

/// Reusable buffers for power spectra of frames of `n` samples.
pub const Spectrum = struct {
    n: usize,
    re: []f64,
    im: []f64,
    window: []f64,
    /// n/2 + 1 bins, power (mean square amplitude) per bin.
    power: []f64,

    pub fn init(alloc: std.mem.Allocator, n: usize) !Spectrum {
        const re = try alloc.alloc(f64, n);
        errdefer alloc.free(re);
        const im = try alloc.alloc(f64, n);
        errdefer alloc.free(im);
        const w = try alloc.alloc(f64, n);
        errdefer alloc.free(w);
        const p = try alloc.alloc(f64, n / 2 + 1);
        for (w, 0..) |*v, i| v.* = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
        return .{ .n = n, .re = re, .im = im, .window = w, .power = p };
    }

    pub fn deinit(s: *Spectrum, alloc: std.mem.Allocator) void {
        alloc.free(s.re);
        alloc.free(s.im);
        alloc.free(s.window);
        alloc.free(s.power);
    }

    /// Power of each bin of `x` (n samples), scaled so a sine of amplitude A
    /// shows about A^2/2 summed over its main lobe.
    pub fn compute(s: *Spectrum, x: []const f32) []f64 {
        std.debug.assert(x.len >= s.n);
        var wsum: f64 = 0;
        for (s.window) |w| wsum += w * w;
        for (0..s.n) |i| {
            s.re[i] = x[i] * s.window[i];
            s.im[i] = 0;
        }
        fft(s.re, s.im);
        const scale = 2.0 / (wsum * @as(f64, @floatFromInt(s.n)));
        for (s.power, 0..) |*p, i| p.* = (s.re[i] * s.re[i] + s.im[i] * s.im[i]) * scale;
        return s.power;
    }
};

const testing = std.testing;

test "fft_finds_a_sine_in_its_bin" {
    var re: [64]f64 = undefined;
    var im: [64]f64 = undefined;
    for (&re, 0..) |*v, i| v.* = @sin(2.0 * std.math.pi * 5.0 * @as(f64, @floatFromInt(i)) / 64.0);
    @memset(&im, 0);
    fft(&re, &im);
    try testing.expectApproxEqAbs(@as(f64, 32), @sqrt(re[5] * re[5] + im[5] * im[5]), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), @sqrt(re[6] * re[6] + im[6] * im[6]), 1e-9);
}

test "spectrum_power_sums_to_sine_power" {
    var s = try Spectrum.init(testing.allocator, 1024);
    defer s.deinit(testing.allocator);
    var x: [1024]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatCast(0.5 * @sin(2.0 * std.math.pi * 100.5 * @as(f64, @floatFromInt(i)) / 1024.0));
    const p = s.compute(&x);
    var sum: f64 = 0;
    for (p[95..106]) |v| sum += v;
    try testing.expectApproxEqRel(@as(f64, 0.125), sum, 0.02);
}

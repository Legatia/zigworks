//! Second-order IIR filters (transposed direct form II), and the K-weighting
//! pair from ITU-R BS.1770 for any sample rate.
const std = @import("std");

pub const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64 = 0,
    z2: f64 = 0,

    pub fn process(f: *Biquad, x: f64) f64 {
        const y = f.b0 * x + f.z1;
        f.z1 = f.b1 * x - f.a1 * y + f.z2;
        f.z2 = f.b2 * x - f.a2 * y;
        return y;
    }

    pub fn reset(f: *Biquad) void {
        f.z1 = 0;
        f.z2 = 0;
    }

    /// Butterworth-style high-pass (RBJ cookbook).
    pub fn highpass(rate: u32, fc: f64, q: f64) Biquad {
        const w0 = 2.0 * std.math.pi * fc / @as(f64, @floatFromInt(rate));
        const alpha = @sin(w0) / (2.0 * q);
        const c = @cos(w0);
        const a0 = 1.0 + alpha;
        return .{ .b0 = (1.0 + c) / 2.0 / a0, .b1 = -(1.0 + c) / a0, .b2 = (1.0 + c) / 2.0 / a0, .a1 = -2.0 * c / a0, .a2 = (1.0 - alpha) / a0 };
    }

    /// Low-pass (RBJ cookbook).
    pub fn lowpass(rate: u32, fc: f64, q: f64) Biquad {
        const w0 = 2.0 * std.math.pi * fc / @as(f64, @floatFromInt(rate));
        const alpha = @sin(w0) / (2.0 * q);
        const c = @cos(w0);
        const a0 = 1.0 + alpha;
        return .{ .b0 = (1.0 - c) / 2.0 / a0, .b1 = (1.0 - c) / a0, .b2 = (1.0 - c) / 2.0 / a0, .a1 = -2.0 * c / a0, .a2 = (1.0 - alpha) / a0 };
    }
};

/// BS.1770 K-weighting: a high shelf (+4 dB above about 1.5 kHz), then a
/// high-pass at about 38 Hz. Coefficients derived for `rate` the way
/// libebur128 does, which reproduces the standard's 48 kHz table.
pub fn kWeighting(rate: u32) [2]Biquad {
    const fs: f64 = @floatFromInt(rate);
    var out: [2]Biquad = undefined;
    {
        const f0 = 1681.974450955533;
        const g = 3.999843853973347;
        const q = 0.7071752369554196;
        const k = @tan(std.math.pi * f0 / fs);
        const vh = std.math.pow(f64, 10.0, g / 20.0);
        const vb = std.math.pow(f64, vh, 0.4996667741545416);
        const a0 = 1.0 + k / q + k * k;
        out[0] = .{
            .b0 = (vh + vb * k / q + k * k) / a0,
            .b1 = 2.0 * (k * k - vh) / a0,
            .b2 = (vh - vb * k / q + k * k) / a0,
            .a1 = 2.0 * (k * k - 1.0) / a0,
            .a2 = (1.0 - k / q + k * k) / a0,
        };
    }
    {
        const f0 = 38.13547087602444;
        const q = 0.5003270373238773;
        const k = @tan(std.math.pi * f0 / fs);
        const d = 1.0 + k / q + k * k;
        out[1] = .{ .b0 = 1, .b1 = -2, .b2 = 1, .a1 = 2.0 * (k * k - 1.0) / d, .a2 = (1.0 - k / q + k * k) / d };
    }
    return out;
}

const testing = std.testing;

test "k_weighting_matches_bs1770_table_at_48k" {
    const k = kWeighting(48000);
    try testing.expectApproxEqAbs(@as(f64, 1.53512485958697), k[0].b0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2.69169618940638), k[0].b1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.19839281085285), k[0].b2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1.69065929318241), k[0].a1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.73248077421585), k[0].a2, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1.99004745483398), k[1].a1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.99007225036621), k[1].a2, 1e-9);
}

fn gainAt(f: Biquad, rate: u32, hz: f64) f64 {
    var g = f;
    g.reset();
    var peak: f64 = 0;
    const n = rate; // one second
    for (0..n) |i| {
        const x = @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate)));
        const y = g.process(x);
        if (i > n / 2) peak = @max(peak, @abs(y));
    }
    return peak;
}

test "highpass_and_lowpass_pass_and_stop" {
    const hp = Biquad.highpass(16000, 100, 0.7071);
    try testing.expect(gainAt(hp, 16000, 1000) > 0.98);
    try testing.expect(gainAt(hp, 16000, 20) < 0.05);
    const lp = Biquad.lowpass(16000, 1000, 0.7071);
    try testing.expect(gainAt(lp, 16000, 100) > 0.98);
    try testing.expect(gainAt(lp, 16000, 6000) < 0.05);
}

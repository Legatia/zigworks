//! Decoded audio: interleaved f32 samples in [-1, 1].
const std = @import("std");

pub const Audio = struct {
    rate: u32,
    channels: u16,
    /// Interleaved: frame i, channel c is samples[i * channels + c].
    samples: []f32,

    pub fn frames(a: Audio) usize {
        return a.samples.len / a.channels;
    }

    pub fn seconds(a: Audio) f64 {
        return @as(f64, @floatFromInt(a.frames())) / @as(f64, @floatFromInt(a.rate));
    }

    pub fn deinit(a: *Audio, alloc: std.mem.Allocator) void {
        alloc.free(a.samples);
    }
};

/// The channels averaged into one.
pub fn mono(alloc: std.mem.Allocator, a: Audio) ![]f32 {
    const n = a.frames();
    const out = try alloc.alloc(f32, n);
    if (a.channels == 1) {
        @memcpy(out, a.samples[0..n]);
        return out;
    }
    const inv = 1.0 / @as(f32, @floatFromInt(a.channels));
    for (out, 0..) |*o, i| {
        var s: f32 = 0;
        for (a.samples[i * a.channels ..][0..a.channels]) |x| s += x;
        o.* = s * inv;
    }
    return out;
}

/// Amplitude to dB (relative to full scale); -inf for 0.
pub fn db(x: f64) f64 {
    if (x <= 0) return -std.math.inf(f64);
    return 20.0 * std.math.log10(x);
}

pub fn fromDb(d: f64) f64 {
    return std.math.pow(f64, 10.0, d / 20.0);
}

/// Largest absolute sample.
pub fn peak(samples: []const f32) f32 {
    var m: f32 = 0;
    for (samples) |x| m = @max(m, @abs(x));
    return m;
}

/// Runs of 3 or more consecutive samples (per channel) at full scale.
pub fn clippedRuns(a: Audio) u32 {
    var runs: u32 = 0;
    for (0..a.channels) |c| {
        var len: u32 = 0;
        var i: usize = c;
        while (i < a.samples.len) : (i += a.channels) {
            if (@abs(a.samples[i]) >= 0.999) {
                len += 1;
                if (len == 3) runs += 1;
            } else len = 0;
        }
    }
    return runs;
}

const testing = std.testing;

test "mono_averages_channels" {
    var s = [_]f32{ 1, 0, 0.5, 0.5, -1, 1 };
    const a = Audio{ .rate = 8000, .channels = 2, .samples = &s };
    const m = try mono(testing.allocator, a);
    defer testing.allocator.free(m);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0 }, m);
    try testing.expectEqual(@as(usize, 3), a.frames());
}

test "clipped_runs_counts_flat_tops_per_channel" {
    // channel 0 clips for 4 samples (one run); channel 1 touches full scale twice (no run)
    var s = [_]f32{ 1, 1, 1, 0, 1, 1, 1, 0, 0, 0 };
    const a = Audio{ .rate = 8000, .channels = 2, .samples = &s };
    try testing.expectEqual(@as(u32, 1), clippedRuns(a));
}

test "db_roundtrip" {
    try testing.expectApproxEqAbs(@as(f64, -6.0206), db(0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.5), fromDb(db(0.5)), 1e-9);
    try testing.expect(std.math.isNegativeInf(db(0)));
}

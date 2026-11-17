//! Numbers about many measurements: middle value, the slow end, the average.
const std = @import("std");

pub const Summary = struct {
    n: usize = 0,
    mean: f64 = 0,
    min: f64 = 0,
    p50: f64 = 0,
    p90: f64 = 0,
    p99: f64 = 0,
    max: f64 = 0,
};

/// The value below which the share `q` (0 to 1) of `sorted` lies, measured
/// between neighbours where it falls between two. 0 for no values.
pub fn percentile(sorted: []const f64, q: f64) f64 {
    if (sorted.len == 0) return 0;
    const pos = std.math.clamp(q, 0, 1) * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi = @min(lo + 1, sorted.len - 1);
    const part = pos - @floor(pos);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * part;
}

/// Sorts `values` and describes them.
pub fn summarize(values: []f64) Summary {
    if (values.len == 0) return .{};
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (values) |v| sum += v;
    return .{
        .n = values.len,
        .mean = sum / @as(f64, @floatFromInt(values.len)),
        .min = values[0],
        .p50 = percentile(values, 0.5),
        .p90 = percentile(values, 0.9),
        .p99 = percentile(values, 0.99),
        .max = values[values.len - 1],
    };
}

// ---- tests ----

const testing = std.testing;

test "percentiles_fall_between_neighbours" {
    const v = [_]f64{ 10, 20, 30, 40, 50 };
    try testing.expectEqual(@as(f64, 10), percentile(&v, 0));
    try testing.expectEqual(@as(f64, 30), percentile(&v, 0.5));
    try testing.expectEqual(@as(f64, 50), percentile(&v, 1));
    try testing.expectApproxEqAbs(@as(f64, 46), percentile(&v, 0.9), 1e-9);
    try testing.expectEqual(@as(f64, 7), percentile(&.{7}, 0.99));
    try testing.expectEqual(@as(f64, 0), percentile(&.{}, 0.5));
}

test "a_set_of_measurements_is_summed_up" {
    var v = [_]f64{ 40, 10, 30, 20 };
    const s = summarize(&v);
    try testing.expectEqual(@as(usize, 4), s.n);
    try testing.expectEqual(@as(f64, 25), s.mean);
    try testing.expectEqual(@as(f64, 10), s.min);
    try testing.expectEqual(@as(f64, 25), s.p50);
    try testing.expectEqual(@as(f64, 40), s.max);
    var none = [_]f64{};
    try testing.expectEqual(@as(usize, 0), summarize(&none).n);
}

//! Faults found by measuring the samples: clipping, dropouts (digital
//! silence in the middle of sound), DC offset and stereo phase.
const std = @import("std");
const audio = @import("audio.zig");
const fnd = @import("finding.zig");
const Audio = audio.Audio;
const Finding = fnd.Finding;

fn secs(a: Audio, frame: usize) f64 {
    return @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(a.rate));
}

/// Flat tops: 3 or more equal samples in a row near the file's peak (also
/// when the level was lowered after clipping), and samples over full scale
/// (decoded lossy files overshoot instead of going flat). Runs closer than
/// 10 ms join.
pub fn clipping(alloc: std.mem.Allocator, a: Audio, out: *std.ArrayList(Finding)) !void {
    const pk = audio.peak(a.samples);
    if (pk <= 0) return;
    const near = pk * 0.95;
    const gap: usize = a.rate / 100;
    const ch = a.channels;
    const n = a.frames();
    const runs = try alloc.alloc(fnd.Runs, ch);
    defer alloc.free(runs);
    for (runs) |*r| r.* = .{};
    defer for (runs) |*r| r.deinit(alloc);
    for (0..ch) |c| {
        var len: usize = 1;
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const same = i < n and a.samples[i * ch + c] == a.samples[(i - 1) * ch + c] and @abs(a.samples[i * ch + c]) >= near;
            if (same) {
                len += 1;
                continue;
            }
            if (len >= 3 and (len >= 8 or steep(a, c, i - len, i))) try runs[c].add(alloc, i - len, i, @intCast(len), @abs(a.samples[(i - 1) * ch + c]), gap);
            len = 1;
        }
        // overs
        for (0..n) |j| {
            const v = @abs(a.samples[j * ch + c]);
            if (v > 1.0001) try addSorted(alloc, &runs[c], j, j + 1, v, gap);
        }
    }
    var merged = try fnd.mergeRuns(alloc, runs, gap);
    defer merged.deinit(alloc);
    for (merged.list.items) |r| try out.append(alloc, .{
        .kind = .clipping,
        .start = secs(a, r.start),
        .end = secs(a, r.end),
        .level = audio.db(r.peak),
        .count = r.count,
    });
}

/// Whether the wave runs into or out of the flat run [from, to) steeply. A
/// slow wave near its crest also repeats a 16-bit value a few times, but its
/// neighbours are within a step or two; a clipped one arrives at speed.
fn steep(a: Audio, c: usize, from: usize, to: usize) bool {
    const ch = a.channels;
    const v = a.samples[from * ch + c];
    const lim = 2.0 / 32768.0;
    if (from > 0 and @abs(a.samples[(from - 1) * ch + c] - v) > lim) return true;
    if (to < a.frames() and @abs(a.samples[to * ch + c] - v) > lim) return true;
    return false;
}

/// Runs are added in order by the flat-top pass; overs may come between.
fn addSorted(alloc: std.mem.Allocator, r: *fnd.Runs, start: usize, end: usize, peak: f32, gap: usize) !void {
    const items = r.list.items;
    for (items) |*x| {
        if (start + gap >= x.start and start <= x.end + gap) {
            x.start = @min(x.start, start);
            x.end = @max(x.end, end);
            x.count += 1;
            x.peak = @max(x.peak, peak);
            return;
        }
    }
    var i: usize = items.len;
    while (i > 0 and items[i - 1].start > start) i -= 1;
    try r.list.insert(alloc, i, .{ .start = start, .end = end, .count = 1, .peak = peak });
}

fn rms(a: Audio, from: usize, to: usize) f64 {
    var s: f64 = 0;
    const ch = a.channels;
    for (from..to) |i| for (0..ch) |c| {
        const v: f64 = a.samples[i * ch + c];
        s += v * v;
    };
    const cnt = (to - from) * ch;
    return if (cnt == 0) 0 else @sqrt(s / @as(f64, @floatFromInt(cnt)));
}

/// Stretches of 2 ms or more where every channel holds one value near zero,
/// with sound (louder than -50 dBFS) in the 20 ms on both sides: a gap in
/// the recording, not a pause.
pub fn dropouts(alloc: std.mem.Allocator, a: Audio, out: *std.ArrayList(Finding)) !void {
    const ch = a.channels;
    const n = a.frames();
    const min_len = @max(2, a.rate / 500);
    const ctx = a.rate / 50;
    const loud = audio.fromDb(-50);
    var i: usize = 1;
    while (i < n) {
        const flat = blk: {
            for (0..ch) |c| {
                const v = a.samples[i * ch + c];
                if (v != a.samples[(i - 1) * ch + c] or @abs(v) > 0.01) break :blk false;
            }
            break :blk true;
        };
        if (!flat) {
            i += 1;
            continue;
        }
        const start = i - 1;
        var j = i;
        while (j + 1 < n) : (j += 1) {
            var same = true;
            for (0..ch) |c| if (a.samples[(j + 1) * ch + c] != a.samples[j * ch + c]) {
                same = false;
            };
            if (!same) break;
        }
        const end = j + 1; // first frame after the run
        if (end - start >= min_len and start >= ctx and end + ctx <= n and
            rms(a, start - ctx, start) >= loud and rms(a, end, end + ctx) >= loud)
        {
            try out.append(alloc, .{ .kind = .dropout, .start = secs(a, start), .end = secs(a, end) });
        }
        i = end + 1;
    }
}

/// A channel whose average is off zero by 0.2% of full scale or more, where
/// it is quiet: the median average of the quietest quarter of its 100 ms
/// blocks. A real offset is there in the pauses too; loud lopsided sound
/// (a voice, clipping) moves the average only while it plays.
pub fn dcOffset(alloc: std.mem.Allocator, a: Audio, out: *std.ArrayList(Finding)) !void {
    const ch = a.channels;
    const n = a.frames();
    const blk = @max(1, a.rate / 10);
    const nb = n / blk;
    if (nb == 0) return;
    const Blk = struct { mean: f64, rms: f64 };
    const bs = try alloc.alloc(Blk, nb);
    defer alloc.free(bs);
    const quiet = try alloc.alloc(f64, nb);
    defer alloc.free(quiet);
    for (0..ch) |c| {
        for (bs, 0..) |*m, b| {
            var s: f64 = 0;
            var q: f64 = 0;
            for (b * blk..(b + 1) * blk) |i| {
                const v: f64 = a.samples[i * ch + c];
                s += v;
                q += v * v;
            }
            const cnt: f64 = @floatFromInt(blk);
            const mean = s / cnt;
            // the level without the offset itself
            m.* = .{ .mean = mean, .rms = @sqrt(@max(0, q / cnt - mean * mean)) };
        }
        std.mem.sort(Blk, bs, {}, struct {
            fn lt(_: void, x: Blk, y: Blk) bool {
                return x.rms < y.rms;
            }
        }.lt);
        const k = @max(1, nb / 4);
        for (bs[0..k], 0..) |b, i| quiet[i] = b.mean;
        std.mem.sort(f64, quiet[0..k], {}, std.sort.asc(f64));
        const med = quiet[k / 2];
        if (@abs(med) >= 0.002) try out.append(alloc, .{
            .kind = .dc,
            .start = 0,
            .end = a.seconds(),
            .channel = @intCast(c + 1),
            .level = audio.db(@abs(med)),
            .value = med * 100,
        });
    }
}

/// Stereo correlation of `a` over all of it where both sides have sound;
/// null for mono or silence.
pub fn correlation(a: Audio) ?f64 {
    if (a.channels != 2) return null;
    var lr: f64 = 0;
    var ll: f64 = 0;
    var rr: f64 = 0;
    for (0..a.frames()) |i| {
        const l: f64 = a.samples[i * 2];
        const r: f64 = a.samples[i * 2 + 1];
        lr += l * r;
        ll += l * l;
        rr += r * r;
    }
    if (ll <= 0 or rr <= 0) return null;
    return lr / @sqrt(ll * rr);
}

/// Stereo stretches (400 ms steps) where the channels are mostly opposite
/// (correlation below -0.5) while both have sound: they cancel in mono.
pub fn phase(alloc: std.mem.Allocator, a: Audio, out: *std.ArrayList(Finding)) !void {
    if (a.channels != 2) return;
    const w = a.rate * 2 / 5;
    const n = a.frames();
    const loud = audio.fromDb(-50);
    var open: ?struct { start: usize, end: usize, worst: f64 } = null;
    var i: usize = 0;
    while (i + w <= n) : (i += w) {
        var lr: f64 = 0;
        var ll: f64 = 0;
        var rr: f64 = 0;
        for (i..i + w) |k| {
            const l: f64 = a.samples[k * 2];
            const r: f64 = a.samples[k * 2 + 1];
            lr += l * r;
            ll += l * l;
            rr += r * r;
        }
        const wf: f64 = @floatFromInt(w);
        const has = @sqrt(ll / wf) >= loud and @sqrt(rr / wf) >= loud;
        const corr = if (has) lr / @sqrt(ll * rr) else 0;
        if (has and corr < -0.5) {
            if (open) |*o| {
                o.end = i + w;
                o.worst = @min(o.worst, corr);
            } else open = .{ .start = i, .end = i + w, .worst = corr };
        } else if (open) |o| {
            try out.append(alloc, .{ .kind = .phase, .start = secs(a, o.start), .end = secs(a, o.end), .value = o.worst });
            open = null;
        }
    }
    if (open) |o| try out.append(alloc, .{ .kind = .phase, .start = secs(a, o.start), .end = secs(a, o.end), .value = o.worst });
}

// ---- tests ----

const testing = std.testing;

fn tone(alloc: std.mem.Allocator, rate: u32, secs_: f64, amp: f64, hz: f64) ![]f32 {
    const n: usize = @intFromFloat(secs_ * @as(f64, @floatFromInt(rate)));
    const s = try alloc.alloc(f32, n);
    for (s, 0..) |*v, i| v.* = @floatCast(amp * @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate))));
    return s;
}

test "clipping_finds_flat_tops_even_after_the_level_was_lowered" {
    const s = try tone(testing.allocator, 48000, 2, 1.0, 220);
    defer testing.allocator.free(s);
    // clip at 0.6 between 0.5 and 0.52 s, then lower everything by half
    for (s, 0..) |*v, i| {
        if (i >= 24000 and i < 24960) v.* = std.math.clamp(v.*, -0.6, 0.6) else v.* *= 0.6;
        v.* *= 0.5;
    }
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(testing.allocator);
    try clipping(testing.allocator, .{ .rate = 48000, .channels = 1, .samples = s }, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out.items[0].start, 0.005);
    try testing.expectApproxEqAbs(@as(f64, 0.52), out.items[0].end, 0.005);
    try testing.expectApproxEqAbs(@as(f64, -10.5), out.items[0].level, 0.1);
}

test "clean_sine_and_bass_are_not_clipping" {
    for ([_]f64{ 1000, 100, 40 }) |hz| {
        const s = try tone(testing.allocator, 48000, 1, 0.99, hz);
        defer testing.allocator.free(s);
        // as 16-bit samples would be
        for (s) |*v| v.* = @round(v.* * 32768) / 32768;
        var out: std.ArrayList(Finding) = .empty;
        defer out.deinit(testing.allocator);
        try clipping(testing.allocator, .{ .rate = 48000, .channels = 1, .samples = s }, &out);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "overs_from_a_lossy_decode_count" {
    const s = try tone(testing.allocator, 44100, 1, 0.9, 300);
    defer testing.allocator.free(s);
    s[1000] = 1.05;
    s[1003] = -1.02;
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(testing.allocator);
    try clipping(testing.allocator, .{ .rate = 44100, .channels = 1, .samples = s }, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 2), out.items[0].count);
}

test "dropout_in_sound_but_not_a_pause" {
    const s = try tone(testing.allocator, 16000, 3, 0.3, 440);
    defer testing.allocator.free(s);
    @memset(s[16000..16080], 0); // 5 ms gap at 1.0 s
    @memset(s[32000..48000], 0); // the last second is silent: a pause, not a dropout
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(testing.allocator);
    try dropouts(testing.allocator, .{ .rate = 16000, .channels = 1, .samples = s }, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out.items[0].start, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.005), out.items[0].end, 0.001);
}

test "lopsided_loud_sound_is_not_dc" {
    // a pulse wave: big positive peaks, long shallow negative parts, in bursts
    const s = try testing.allocator.alloc(f32, 16000 * 2);
    defer testing.allocator.free(s);
    for (s, 0..) |*v, i| {
        const on = (i / 4000) % 2 == 0;
        v.* = if (!on) 0 else if (i % 100 < 10) 0.9 else -0.1;
    }
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(testing.allocator);
    try dcOffset(testing.allocator, .{ .rate = 16000, .channels = 1, .samples = s }, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "dc_offset_and_phase" {
    const n = 16000 * 2;
    const s = try testing.allocator.alloc(f32, n * 2);
    defer testing.allocator.free(s);
    for (0..n) |i| {
        const v: f32 = @floatCast(0.3 * @sin(2.0 * std.math.pi * 300.0 * @as(f64, @floatFromInt(i)) / 16000.0));
        s[i * 2] = v + 0.01;
        // the second second: right channel inverted
        s[i * 2 + 1] = if (i >= 16000) -v else v;
    }
    const a = Audio{ .rate = 16000, .channels = 2, .samples = s };
    var out: std.ArrayList(Finding) = .empty;
    defer out.deinit(testing.allocator);
    try dcOffset(testing.allocator, a, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u16, 1), out.items[0].channel);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out.items[0].value, 0.01);
    out.clearRetainingCapacity();
    try phase(testing.allocator, a, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1.2), out.items[0].start, 0.41);
    try testing.expectApproxEqAbs(@as(f64, 2.0), out.items[0].end, 0.01);
    try testing.expect(out.items[0].value < -0.9);
}

//! Where the speech is. Works on 16 kHz mono: a 100-3800 Hz band-pass, the
//! level of 20 ms frames every 10 ms against the background level, and a
//! voicing check (YIN) so steady noise, clicks and hiss don't count.
const std = @import("std");
const Biquad = @import("biquad.zig").Biquad;
const pitch = @import("pitch.zig");

pub const rate: u32 = 16000;
pub const hop: usize = 160; // 10 ms
pub const win: usize = 320; // 20 ms
const hang_frames = 15; // a dip shorter than 150 ms doesn't end a stretch
const on_above_floor = 12.0;
const off_above_floor = 6.0;

pub const Segment = struct { start: f64, end: f64 };

pub const Options = struct {
    /// Pauses shorter than this join the speech on both sides.
    min_pause_s: f64 = 0.3,
    /// Stretches shorter than this are dropped (coughs, clicks).
    min_speech_s: f64 = 0.12,
    /// Kept before and after each stretch, so word edges aren't cut.
    pad_s: f64 = 0.05,
};

pub const Analysis = struct {
    /// Level of each 10 ms frame in dBFS (band-passed).
    levels: []f32,
    /// Background level the thresholds are relative to.
    floor: f32,
    /// Pitch per frame (0: unvoiced or not looked at).
    hz: []f32,
    segments: []Segment,
    duration: f64,

    pub fn deinit(a: *Analysis, alloc: std.mem.Allocator) void {
        alloc.free(a.levels);
        alloc.free(a.hz);
        alloc.free(a.segments);
    }

    pub fn speechSeconds(a: Analysis) f64 {
        var s: f64 = 0;
        for (a.segments) |g| s += g.end - g.start;
        return s;
    }

    pub fn longestPause(a: Analysis) f64 {
        var m: f64 = 0;
        if (a.segments.len < 2) return 0;
        for (1..a.segments.len) |i| m = @max(m, a.segments[i].start - a.segments[i - 1].end);
        return m;
    }
};

pub const BandPass = struct {
    hp: Biquad = Biquad.highpass(rate, 100, 0.7071),
    lp: Biquad = Biquad.lowpass(rate, 3800, 0.7071),

    pub fn process(b: *BandPass, x: f32) f32 {
        return @floatCast(b.lp.process(b.hp.process(x)));
    }
};

fn frameLevel(x: []const f32) f32 {
    var s: f64 = 0;
    for (x) |v| s += @as(f64, v) * v;
    const ms = s / @as(f64, @floatFromInt(x.len));
    return @floatCast(10.0 * std.math.log10(ms + 1e-12) + 3.01); // a full-scale sine reads 0
}

fn percentile(alloc: std.mem.Allocator, v: []const f32, p: f32) !f32 {
    const s = try alloc.dupe(f32, v);
    defer alloc.free(s);
    std.mem.sort(f32, s, {}, std.sort.asc(f32));
    return s[@intFromFloat(@round(p * @as(f32, @floatFromInt(s.len - 1))))];
}

/// The background level: the 10th percentile of frame levels. When the levels
/// hardly vary (speech or noise throughout) it is put 25 dB under the loud end.
fn backgroundLevel(alloc: std.mem.Allocator, levels: []const f32) !f32 {
    if (levels.len == 0) return -90;
    const p10 = try percentile(alloc, levels, 0.1);
    const p90 = try percentile(alloc, levels, 0.9);
    const f = if (p90 - p10 < 20) p90 - 25 else p10;
    return @max(f, -90);
}

fn onLevel(floor: f32) f32 {
    return @max(floor + on_above_floor, -65);
}
fn offLevel(floor: f32) f32 {
    return @max(floor + off_above_floor, -70);
}

/// Speech stretches in `x` (16 kHz mono).
pub fn analyze(alloc: std.mem.Allocator, x: []const f32, opts: Options) !Analysis {
    const duration = @as(f64, @floatFromInt(x.len)) / rate;
    const filtered = try alloc.alloc(f32, x.len);
    defer alloc.free(filtered);
    var bp = BandPass{};
    for (x, filtered) |v, *o| o.* = bp.process(v);

    const n = if (x.len >= win) (x.len - win) / hop + 1 else 0;
    const levels = try alloc.alloc(f32, n);
    errdefer alloc.free(levels);
    for (levels, 0..) |*l, i| l.* = frameLevel(filtered[i * hop ..][0..win]);
    const floor = try backgroundLevel(alloc, levels);
    const on = onLevel(floor);
    const off = offLevel(floor);

    // Loud stretches, with hysteresis.
    var cands: std.ArrayList([2]usize) = .empty;
    defer cands.deinit(alloc);
    {
        var in = false;
        var start: usize = 0;
        var last: usize = 0;
        for (levels, 0..) |e, i| {
            if (!in) {
                if (e > on) {
                    in = true;
                    start = i;
                    last = i;
                }
                continue;
            }
            if (e > off) {
                last = i;
            } else if (i - last > hang_frames) {
                try cands.append(alloc, .{ start, last + 1 });
                in = false;
            }
        }
        if (in) try cands.append(alloc, .{ start, last + 1 });
    }

    // Pitch only where it is loud; a stretch counts as speech if enough of it is voiced.
    const want = try alloc.alloc(bool, n);
    defer alloc.free(want);
    @memset(want, false);
    for (cands.items) |c| @memset(want[c[0]..c[1]], true);
    const hz_raw = try pitch.track(alloc, filtered, rate, want);
    defer alloc.free(hz_raw);
    const hz = try alloc.alloc(f32, n);
    errdefer alloc.free(hz);
    @memset(hz, 0);
    @memcpy(hz[0..@min(n, hz_raw.len)], hz_raw[0..@min(n, hz_raw.len)]);

    var segs: std.ArrayList(Segment) = .empty;
    errdefer segs.deinit(alloc);
    const frame_s = @as(f64, hop) / rate;
    const win_s = @as(f64, win) / rate;
    for (cands.items) |c| {
        var voiced: usize = 0;
        for (hz[c[0]..c[1]]) |h| {
            if (h > 0) voiced += 1;
        }
        const len = c[1] - c[0];
        if (voiced < 3 or @as(f64, @floatFromInt(voiced)) < 0.15 * @as(f64, @floatFromInt(len))) continue;
        const s = Segment{ .start = @as(f64, @floatFromInt(c[0])) * frame_s, .end = @as(f64, @floatFromInt(c[1] - 1)) * frame_s + win_s };
        if (segs.items.len > 0 and s.start - segs.items[segs.items.len - 1].end < opts.min_pause_s) {
            segs.items[segs.items.len - 1].end = s.end;
        } else try segs.append(alloc, s);
    }
    // Drop short ones, then pad (merging stretches the padding makes touch).
    var out: std.ArrayList(Segment) = .empty;
    errdefer out.deinit(alloc);
    for (segs.items) |s| {
        if (s.end - s.start < opts.min_speech_s) continue;
        const p = Segment{ .start = @max(0, s.start - opts.pad_s), .end = @min(duration, s.end + opts.pad_s) };
        if (out.items.len > 0 and p.start <= out.items[out.items.len - 1].end) {
            out.items[out.items.len - 1].end = p.end;
        } else try out.append(alloc, p);
    }
    segs.deinit(alloc);
    return .{ .levels = levels, .floor = floor, .hz = hz, .segments = try out.toOwnedSlice(alloc), .duration = duration };
}

/// Syllables per second while speaking: peaks of the level in voiced frames
/// at least 100 ms apart with a 2 dB dip between them. An estimate.
pub fn syllableRate(a: Analysis) ?f64 {
    const speaking = a.speechSeconds();
    if (speaking < 0.5) return null;
    const on = onLevel(a.floor);
    var count: usize = 0;
    var last_peak: ?usize = null;
    var min_since: f32 = std.math.inf(f32);
    const L = a.levels;
    for (L, 0..) |e, i| {
        min_since = @min(min_since, e);
        if (i >= a.hz.len or a.hz[i] == 0 or e < on) continue;
        const lo = i -| 5;
        const hi = @min(L.len, i + 6);
        var is_max = true;
        for (lo..hi) |j| if (L[j] > e or (L[j] == e and j < i)) {
            is_max = false;
            break;
        };
        if (!is_max) continue;
        if (last_peak) |lp| {
            if (e - min_since < 2.0 and L[lp] - min_since < 2.0) continue;
        }
        count += 1;
        last_peak = i;
        min_since = e;
    }
    return @as(f64, @floatFromInt(count)) / speaking;
}

/// Listening as audio arrives: decides when speech has started and when it
/// has ended (`silence_s` without speech after it). 16 kHz mono in.
pub const Live = struct {
    alloc: std.mem.Allocator,
    silence_s: f64,
    max_s: f64,
    raw: std.ArrayList(f32) = .empty,
    filtered: std.ArrayList(f32) = .empty,
    bp: BandPass = .{},
    scratch: []f32,
    next_frame: usize = 0,
    floor: f32 = 0,
    calibrated: bool = false,
    state: State = .waiting,
    cand_start: ?usize = null,
    cand_last: usize = 0,
    voiced: u32 = 0,
    speech_start: usize = 0,
    last_active: usize = 0,
    end_frame: usize = 0,

    pub const State = enum { waiting, speaking, done };
    pub const pre_roll_frames = 30;
    const calib_frames = 20;

    pub fn init(alloc: std.mem.Allocator, silence_s: f64, max_s: f64) !Live {
        return .{ .alloc = alloc, .silence_s = silence_s, .max_s = max_s, .scratch = try alloc.alloc(f32, pitch.frameLen(rate)) };
    }

    pub fn deinit(l: *Live) void {
        l.raw.deinit(l.alloc);
        l.filtered.deinit(l.alloc);
        l.alloc.free(l.scratch);
    }

    /// Adds samples; returns the state after them.
    pub fn feed(l: *Live, samples: []const f32) !State {
        if (l.state == .done) return .done;
        try l.raw.appendSlice(l.alloc, samples);
        for (samples) |v| try l.filtered.append(l.alloc, l.bp.process(v));
        const flen = pitch.frameLen(rate);
        while (l.state != .done and l.next_frame * hop + flen <= l.filtered.items.len) : (l.next_frame += 1) {
            l.step(l.next_frame);
        }
        return l.state;
    }

    fn step(l: *Live, i: usize) void {
        const f = l.filtered.items[i * hop ..];
        const e = frameLevel(f[0..win]);
        if (!l.calibrated) {
            l.floor = if (i == 0) e else @min(l.floor, e);
            if (i + 1 >= calib_frames) l.calibrated = true;
            return;
        }
        if (l.state == .waiting) {
            // The background follows quiet frames down at once and drifts up slowly.
            l.floor = if (e < l.floor) e else l.floor + 0.01;
        }
        const on = onLevel(l.floor);
        const off = offLevel(l.floor);
        switch (l.state) {
            .waiting => {
                if (l.cand_start == null) {
                    if (e <= on) return;
                    l.cand_start = i;
                    l.cand_last = i;
                    l.voiced = 0;
                }
                if (e > off) {
                    l.cand_last = i;
                    if (pitch.yin(f[0..pitch.frameLen(rate)], rate, l.scratch) != null) l.voiced += 1;
                    if (l.voiced >= 5) {
                        l.state = .speaking;
                        l.speech_start = l.cand_start.?;
                        l.last_active = i;
                    }
                } else if (i - l.cand_last > hang_frames) l.cand_start = null;
            },
            .speaking => {
                if (e > off) l.last_active = i;
                const quiet_s = @as(f64, @floatFromInt(i - l.last_active)) * 0.01;
                const long_s = @as(f64, @floatFromInt(i - l.speech_start)) * 0.01;
                if (quiet_s >= l.silence_s or long_s >= l.max_s) {
                    l.state = .done;
                    l.end_frame = l.last_active + 2;
                }
            },
            .done => {},
        }
    }

    /// Seconds from the start of listening to the first speech.
    pub fn startedAt(l: Live) f64 {
        return @as(f64, @floatFromInt(l.speech_start)) * 0.01;
    }

    /// The utterance: from a moment before the speech to a moment after it.
    pub fn utterance(l: Live) []const f32 {
        const from = (l.speech_start -| pre_roll_frames) * hop;
        const to = @min(l.raw.items.len, (l.end_frame + 15) * hop + win);
        return l.raw.items[from..to];
    }
};

// ---- tests ----

const testing = std.testing;

/// Builds a test signal: a list of (seconds, kind) parts at 16 kHz with a
/// little background noise everywhere.
const Part = struct { secs: f64, kind: enum { quiet, voice, noise, click } };

fn build(alloc: std.mem.Allocator, parts: []const Part, seed: u64) ![]f32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(alloc);
    var t: usize = 0;
    for (parts) |p| {
        const n: usize = @intFromFloat(p.secs * rate);
        for (0..n) |k| {
            const bg = (r.float(f32) - 0.5) * 0.002; // about -60 dBFS
            const ts = @as(f64, @floatFromInt(t)) / rate;
            const v: f32 = switch (p.kind) {
                .quiet => 0,
                .voice => blk: {
                    // 140 Hz buzz with a 4 Hz syllable rhythm
                    var acc: f64 = 0;
                    for (1..8) |h| acc += @sin(2.0 * std.math.pi * 140.0 * @as(f64, @floatFromInt(h)) * ts) / @as(f64, @floatFromInt(h));
                    const env = 0.55 + 0.45 * @sin(2.0 * std.math.pi * 4.0 * ts);
                    break :blk @floatCast(0.2 * acc * env);
                },
                .noise => (r.float(f32) - 0.5) * 0.6,
                .click => if (k < 40) 0.9 else 0,
            };
            try out.append(alloc, v + bg);
            t += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

test "finds_two_stretches_of_voice" {
    const x = try build(testing.allocator, &.{
        .{ .secs = 1.0, .kind = .quiet }, .{ .secs = 1.5, .kind = .voice },
        .{ .secs = 1.0, .kind = .quiet }, .{ .secs = 0.8, .kind = .voice },
        .{ .secs = 0.7, .kind = .quiet },
    }, 1);
    defer testing.allocator.free(x);
    var a = try analyze(testing.allocator, x, .{});
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), a.segments.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), a.segments[0].start, 0.1);
    try testing.expectApproxEqAbs(@as(f64, 2.5), a.segments[0].end, 0.2);
    try testing.expectApproxEqAbs(@as(f64, 3.5), a.segments[1].start, 0.1);
    try testing.expectApproxEqAbs(@as(f64, 4.3), a.segments[1].end, 0.2);
    try testing.expectApproxEqAbs(@as(f64, 1.0), a.longestPause(), 0.25);
}

test "noise_bursts_and_clicks_are_not_speech" {
    const x = try build(testing.allocator, &.{
        .{ .secs = 1.0, .kind = .quiet }, .{ .secs = 0.6, .kind = .noise },
        .{ .secs = 1.0, .kind = .quiet }, .{ .secs = 0.3, .kind = .click },
        .{ .secs = 1.0, .kind = .voice }, .{ .secs = 1.0, .kind = .quiet },
    }, 2);
    defer testing.allocator.free(x);
    var a = try analyze(testing.allocator, x, .{});
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), a.segments.len);
    try testing.expectApproxEqAbs(@as(f64, 2.9), a.segments[0].start, 0.15);
}

test "short_pauses_join" {
    const x = try build(testing.allocator, &.{
        .{ .secs = 0.5, .kind = .quiet }, .{ .secs = 1.0, .kind = .voice },
        .{ .secs = 0.25, .kind = .quiet }, .{ .secs = 1.0, .kind = .voice },
        .{ .secs = 0.5, .kind = .quiet },
    }, 3);
    defer testing.allocator.free(x);
    var a = try analyze(testing.allocator, x, .{ .min_pause_s = 0.4 });
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), a.segments.len);
    var b = try analyze(testing.allocator, x, .{ .min_pause_s = 0.1, .pad_s = 0 });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), b.segments.len);
}

test "speech_throughout_and_silence_throughout" {
    const x = try build(testing.allocator, &.{.{ .secs = 3.0, .kind = .voice }}, 4);
    defer testing.allocator.free(x);
    var a = try analyze(testing.allocator, x, .{});
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), a.segments.len);
    try testing.expect(a.speechSeconds() > 2.8);
    const q = try build(testing.allocator, &.{.{ .secs = 2.0, .kind = .quiet }}, 5);
    defer testing.allocator.free(q);
    var b = try analyze(testing.allocator, q, .{});
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), b.segments.len);
    try testing.expectEqual(@as(f64, 0), b.longestPause());
    try testing.expectEqual(@as(f64, 0), b.speechSeconds());
    try testing.expect(syllableRate(b) == null);
    var c = try analyze(testing.allocator, &.{}, .{});
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), c.segments.len);
}

test "syllable_rate_follows_the_rhythm" {
    const x = try build(testing.allocator, &.{
        .{ .secs = 0.5, .kind = .quiet }, .{ .secs = 3.0, .kind = .voice }, .{ .secs = 0.5, .kind = .quiet },
    }, 6);
    defer testing.allocator.free(x);
    var a = try analyze(testing.allocator, x, .{});
    defer a.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 4.0), syllableRate(a).?, 0.8);
}

test "live_detects_start_and_end_of_an_utterance" {
    const x = try build(testing.allocator, &.{
        .{ .secs = 1.0, .kind = .quiet }, .{ .secs = 0.6, .kind = .noise }, .{ .secs = 0.6, .kind = .quiet },
        .{ .secs = 1.2, .kind = .voice }, .{ .secs = 0.2, .kind = .quiet }, .{ .secs = 0.6, .kind = .voice },
        .{ .secs = 3.0, .kind = .quiet },
    }, 7);
    defer testing.allocator.free(x);
    var l = try Live.init(testing.allocator, 0.8, 30);
    defer l.deinit();
    var state: Live.State = .waiting;
    var i: usize = 0;
    while (i < x.len and state != .done) : (i += 1600) state = try l.feed(x[i..@min(x.len, i + 1600)]);
    try testing.expectEqual(Live.State.done, state);
    try testing.expectApproxEqAbs(@as(f64, 2.2), l.startedAt(), 0.1);
    // ends after the second stretch (the 0.2 s pause doesn't end it)
    const u_end = @as(f64, @floatFromInt((l.speech_start -| Live.pre_roll_frames) * hop + l.utterance().len)) / rate;
    try testing.expect(u_end > 4.2 and u_end < 4.7); // speech ends at 4.2 s
    // it stopped listening about 0.8 s after the speech ended, not at the end of the input
    try testing.expect(i < x.len);
}

test "live_max_length_stops_it" {
    const x = try build(testing.allocator, &.{ .{ .secs = 0.5, .kind = .quiet }, .{ .secs = 4.0, .kind = .voice } }, 8);
    defer testing.allocator.free(x);
    var l = try Live.init(testing.allocator, 0.8, 1.5);
    defer l.deinit();
    try testing.expectEqual(Live.State.done, try l.feed(x));
    try testing.expect(l.utterance().len < 3 * rate);
}

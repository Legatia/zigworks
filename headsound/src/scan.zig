//! Every check on one recording: what an editor would want to fix, where.
const std = @import("std");
const audio = @import("audio.zig");
const fnd = @import("finding.zig");
const faults = @import("faults.zig");
const clicks = @import("clicks.zig");
const hum = @import("hum.zig");
const voicefx = @import("voicefx.zig");
const loudness = @import("loudness.zig");
const Audio = audio.Audio;
const Finding = fnd.Finding;

pub const Report = struct {
    findings: std.ArrayList(Finding),
    loudness: loudness.Measure,
    true_peak: f64,
    /// Stereo correlation over the whole file; null for mono.
    correlation: ?f64,

    pub fn deinit(r: *Report, alloc: std.mem.Allocator) void {
        r.findings.deinit(alloc);
    }

    pub fn count(r: Report, k: fnd.Kind) usize {
        var n: usize = 0;
        for (r.findings.items) |f| if (f.kind == k) {
            n += 1;
        };
        return n;
    }

    /// The loudest hum found, if any.
    pub fn strongestHum(r: Report) ?Finding {
        var best: ?Finding = null;
        for (r.findings.items) |f| if (f.kind == .hum and (best == null or f.level > best.?.level)) {
            best = f;
        };
        return best;
    }
};

/// One channel of `a`, deinterleaved.
pub fn channel(alloc: std.mem.Allocator, a: Audio, c: usize) ![]f32 {
    const n = a.frames();
    const out = try alloc.alloc(f32, n);
    for (out, 0..) |*v, i| v.* = a.samples[i * a.channels + c];
    return out;
}

/// Clicks in every channel, as findings (channels merged within 1 ms).
pub fn findClicks(alloc: std.mem.Allocator, a: Audio, floor: f32, out: *std.ArrayList(Finding)) !void {
    const runs = try alloc.alloc(fnd.Runs, a.channels);
    defer alloc.free(runs);
    for (runs) |*r| r.* = .{};
    defer for (runs) |*r| r.deinit(alloc);
    for (0..a.channels) |c| {
        const x = try channel(alloc, a, c);
        defer alloc.free(x);
        const cs = try clicks.detect(alloc, x, a.rate, floor);
        defer alloc.free(cs);
        for (cs) |k| try runs[c].add(alloc, k.start, k.end, 1, k.height, 0);
    }
    var merged = try fnd.mergeRuns(alloc, runs, a.rate / 1000);
    defer merged.deinit(alloc);
    const r: f64 = @floatFromInt(a.rate);
    for (merged.list.items) |k| try out.append(alloc, .{
        .kind = .click,
        .start = @as(f64, @floatFromInt(k.start)) / r,
        .end = @as(f64, @floatFromInt(k.end)) / r,
        .level = audio.db(k.peak),
    });
}

pub const Fix = struct { start: usize, end: usize, ok: bool };
pub const FixCount = struct { found: usize, repaired: usize };

/// Clicks from all channels counted once where they overlap (within `gap`
/// samples), as scan counts them; one counts as repaired when every
/// channel's part of it was.
pub fn countFixes(alloc: std.mem.Allocator, fixes: []const Fix, gap: usize) !FixCount {
    const sorted = try alloc.dupe(Fix, fixes);
    defer alloc.free(sorted);
    std.mem.sort(Fix, sorted, {}, struct {
        fn lt(_: void, a: Fix, b: Fix) bool {
            return a.start < b.start;
        }
    }.lt);
    var n = FixCount{ .found = 0, .repaired = 0 };
    var i: usize = 0;
    while (i < sorted.len) {
        var end = sorted[i].end;
        var ok = sorted[i].ok;
        var j = i + 1;
        while (j < sorted.len and sorted[j].start <= end + gap) : (j += 1) {
            end = @max(end, sorted[j].end);
            ok = ok and sorted[j].ok;
        }
        n.found += 1;
        if (ok) n.repaired += 1;
        i = j;
    }
    return n;
}

test "clicks_in_several_channels_count_once" {
    // as a review found: one unrepaired burst joining two repaired clicks
    const fs = [_]Fix{
        .{ .start = 1000, .end = 1001, .ok = true },
        .{ .start = 1150, .end = 1650, .ok = false },
        .{ .start = 1800, .end = 1801, .ok = true },
        .{ .start = 9000, .end = 9001, .ok = true },
    };
    const n = try countFixes(std.testing.allocator, &fs, 192);
    try std.testing.expectEqual(@as(usize, 2), n.found);
    try std.testing.expectEqual(@as(usize, 1), n.repaired);
}

/// Whether the click `c` is part of another problem found: within 10 ms of
/// a pop, harsh s, clipping or a dropout (their edges look like clicks).
pub fn partOfOther(c: Finding, all: []const Finding) bool {
    for (all) |f| switch (f.kind) {
        .pop, .ess, .clipping, .dropout => if (c.start < f.end + 0.01 and c.end > f.start - 0.01) return true,
        else => {},
    };
    return false;
}

fn dropPartOf(out: *std.ArrayList(Finding)) void {
    var w: usize = 0;
    for (out.items) |f| {
        if (f.kind == .click and partOfOther(f, out.items)) continue;
        out.items[w] = f;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
}

/// The faults whose edges look like clicks: clipping, dropouts, pops, harsh s.
pub fn otherFaults(alloc: std.mem.Allocator, a: Audio, out: *std.ArrayList(Finding)) !void {
    try faults.clipping(alloc, a, out);
    try faults.dropouts(alloc, a, out);
    const m = try audio.mono(alloc, a);
    defer alloc.free(m);
    const ps = try voicefx.pops(alloc, m, a.rate);
    defer alloc.free(ps);
    for (ps) |p| try out.append(alloc, .{ .kind = .pop, .start = p.start, .end = p.end });
    const ss = try voicefx.harshS(alloc, m, a.rate);
    defer alloc.free(ss);
    for (ss) |p| try out.append(alloc, .{ .kind = .ess, .start = p.start, .end = p.end });
}

/// `lossy`: decoded from AAC, MP3 or Opus (small clicks don't count).
pub fn run(alloc: std.mem.Allocator, a: Audio, lossy: bool) !Report {
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(alloc);
    try faults.clipping(alloc, a, &out);
    try faults.dropouts(alloc, a, &out);
    try findClicks(alloc, a, if (lossy) clicks.floor_lossy else clicks.floor_pcm, &out);
    try faults.dcOffset(alloc, a, &out);
    try faults.phase(alloc, a, &out);

    const m = try audio.mono(alloc, a);
    defer alloc.free(m);
    const hs = try hum.detect(alloc, m, a.rate);
    defer alloc.free(hs);
    for (hs) |h| try out.append(alloc, .{
        .kind = .hum,
        .start = h.start,
        .end = h.end,
        .freq = h.freq,
        .level = h.level,
        .count = h.harmonics(),
    });
    const ps = try voicefx.pops(alloc, m, a.rate);
    defer alloc.free(ps);
    for (ps) |p| try out.append(alloc, .{ .kind = .pop, .start = p.start, .end = p.end, .level = p.level, .value = p.over });
    const ss = try voicefx.harshS(alloc, m, a.rate);
    defer alloc.free(ss);
    for (ss) |p| try out.append(alloc, .{ .kind = .ess, .start = p.start, .end = p.end, .level = p.level, .value = p.over });

    dropPartOf(&out);
    std.mem.sort(Finding, out.items, {}, Finding.lessThan);
    return .{
        .findings = out,
        .loudness = try loudness.measure(alloc, a),
        .true_peak = loudness.truePeak(a),
        .correlation = faults.correlation(a),
    };
}

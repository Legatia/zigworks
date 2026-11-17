//! A problem (or a sound) found in a recording, with where it is.
const std = @import("std");

pub const Kind = enum {
    clipping,
    click,
    dropout,
    hum,
    pop,
    ess,
    dc,
    phase,
    sound,

    /// The marker name editors show.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .clipping => "clipping",
            .click => "click",
            .dropout => "dropout",
            .hum => "hum",
            .pop => "pop (plosive)",
            .ess => "harsh s",
            .dc => "DC offset",
            .phase => "out of phase",
            .sound => "sound",
        };
    }
};

pub const Finding = struct {
    kind: Kind,
    /// Seconds from the start.
    start: f64,
    end: f64,
    /// dBFS of the problem (click height, hum level, clip level...); NaN if none.
    level: f64 = std.math.nan(f64),
    /// Hz, for hum.
    freq: f64 = 0,
    /// 1-based channel, 0 for all.
    channel: u16 = 0,
    /// Clipped samples, hum harmonics...
    count: u32 = 0,
    /// Per kind: DC offset in percent, phase correlation, dB over the s
    /// threshold, the classifier's confidence.
    value: f64 = std.math.nan(f64),
    /// For sounds: the classifier's name for it.
    label: []const u8 = "",

    pub fn lessThan(_: void, a: Finding, b: Finding) bool {
        return a.start < b.start or (a.start == b.start and @intFromEnum(a.kind) < @intFromEnum(b.kind));
    }
};

/// Sorted runs of sample indices; neighbours closer than `gap` join.
pub const Runs = struct {
    list: std.ArrayList(Run) = .empty,

    pub const Run = struct { start: usize, end: usize, count: u32 = 1, peak: f32 = 0 };

    pub fn add(r: *Runs, alloc: std.mem.Allocator, start: usize, end: usize, count: u32, peak: f32, gap: usize) !void {
        if (r.list.items.len > 0) {
            const last = &r.list.items[r.list.items.len - 1];
            if (start <= last.end + gap) {
                last.end = @max(last.end, end);
                last.count += count;
                last.peak = @max(last.peak, peak);
                return;
            }
        }
        try r.list.append(alloc, .{ .start = start, .end = end, .count = count, .peak = peak });
    }

    pub fn deinit(r: *Runs, alloc: std.mem.Allocator) void {
        r.list.deinit(alloc);
    }
};

/// Merges runs from several channels (each sorted) into one sorted list.
pub fn mergeRuns(alloc: std.mem.Allocator, per_channel: []const Runs, gap: usize) !Runs {
    var all: std.ArrayList(Runs.Run) = .empty;
    defer all.deinit(alloc);
    for (per_channel) |r| try all.appendSlice(alloc, r.list.items);
    std.mem.sort(Runs.Run, all.items, {}, struct {
        fn lt(_: void, a: Runs.Run, b: Runs.Run) bool {
            return a.start < b.start;
        }
    }.lt);
    var out = Runs{};
    errdefer out.deinit(alloc);
    for (all.items) |x| try out.add(alloc, x.start, x.end, x.count, x.peak, gap);
    return out;
}

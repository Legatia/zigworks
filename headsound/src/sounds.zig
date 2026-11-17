//! What is heard, from the classifier's overlapping windows: for each
//! class, the stretches where its confidence stays high.
const std = @import("std");

/// One classifier window and one class in it.
pub const Window = struct { start: f64, end: f64, label: []const u8, confidence: f64 };

pub const Stretch = struct { start: f64, end: f64, label: []const u8, confidence: f64 };

/// Windows of the same class with confidence >= `min` that touch or overlap
/// join; each stretch carries its mean confidence. Sorted by start.
pub fn stretches(alloc: std.mem.Allocator, ws: []const Window, min: f64) ![]Stretch {
    const sorted = try alloc.dupe(Window, ws);
    defer alloc.free(sorted);
    std.mem.sort(Window, sorted, {}, struct {
        fn lt(_: void, a: Window, b: Window) bool {
            const o = std.mem.order(u8, a.label, b.label);
            return o == .lt or (o == .eq and a.start < b.start);
        }
    }.lt);
    var out: std.ArrayList(Stretch) = .empty;
    errdefer out.deinit(alloc);
    var sum: f64 = 0;
    var cnt: f64 = 0;
    for (sorted) |w| {
        if (w.confidence < min) continue;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (std.mem.eql(u8, last.label, w.label) and w.start <= last.end + 1e-6) {
                last.end = @max(last.end, w.end);
                sum += w.confidence;
                cnt += 1;
                last.confidence = sum / cnt;
                continue;
            }
        }
        sum = w.confidence;
        cnt = 1;
        try out.append(alloc, .{ .start = w.start, .end = w.end, .label = w.label, .confidence = w.confidence });
    }
    std.mem.sort(Stretch, out.items, {}, struct {
        fn lt(_: void, a: Stretch, b: Stretch) bool {
            return a.start < b.start or (a.start == b.start and std.mem.order(u8, a.label, b.label) == .lt);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "windows_of_a_class_join_into_stretches" {
    const ws = [_]Window{
        .{ .start = 0, .end = 1, .label = "speech", .confidence = 0.9 },
        .{ .start = 0.5, .end = 1.5, .label = "speech", .confidence = 0.7 },
        .{ .start = 1.0, .end = 2.0, .label = "speech", .confidence = 0.2 }, // too unsure
        .{ .start = 2.0, .end = 3.0, .label = "speech", .confidence = 0.8 }, // after a gap
        .{ .start = 0.5, .end = 1.5, .label = "music", .confidence = 0.6 },
    };
    const st = try stretches(testing.allocator, &ws, 0.5);
    defer testing.allocator.free(st);
    try testing.expectEqual(@as(usize, 3), st.len);
    try testing.expectEqualStrings("speech", st[0].label);
    try testing.expectEqual(@as(f64, 1.5), st[0].end);
    try testing.expectApproxEqAbs(@as(f64, 0.8), st[0].confidence, 1e-9);
    try testing.expectEqualStrings("music", st[1].label);
    try testing.expectEqual(@as(f64, 2.0), st[2].start);
}

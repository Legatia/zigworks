//! The warm-car routine's timing and reading (the household spec, section
//! 7): which of the diary's leave-bys gets the question now (30 minutes
//! before a morning one, once each), the car's outside temperature from
//! carcloud's car_status lines, and what the routine's instance starts
//! with. Pure: no I/O.
const std = @import("std");
const diary = @import("diary.zig");
const Allocator = std.mem.Allocator;

/// The question comes this long before the leave-by (Tesla's own
/// preconditioning takes 15 to 30 minutes).
pub const ask_before_s: i64 = 30 * 60;
/// A leave-by before this minute of the day (the owner's time) is a
/// morning's.
pub const morning_until: i64 = 12 * 60;
/// The workflow harness starts, and its built-in schedule.
pub const workflow = "warm-car";
pub const by = "schedule:warm-car";

/// A leave-by whose question is due: its key in state/diary, when to
/// leave, the event.
pub const Due = struct { key: []const u8, leave: i64, event: diary.Event };

/// The leave-bys whose question is due at `now`, not yet `said`.
pub fn due(a: Allocator, evs: []const diary.Event, now: i64, travel: diary.Travel, said: []const []const u8) ![]Due {
    var out: std.ArrayList(Due) = .empty;
    for (evs) |e| {
        if (e.all_day or e.cancelled or std.ascii.eqlIgnoreCase(e.answer, "DECLINED") or !diary.goesTo(e.place)) continue;
        const leave = e.start - @as(i64, minutesFor(e, travel)) * 60;
        if (now < leave - ask_before_s or now >= leave) continue;
        // a morning's: before noon, the owner's time
        if (@mod(leave + @as(i64, e.offset) * 60, 86400) >= morning_until * 60) continue;
        const key = try std.fmt.allocPrint(a, "warm:{s}@{d}", .{ e.id, e.start });
        for (said) |k| {
            if (std.mem.eql(u8, k, key)) break;
        } else try out.append(a, .{ .key = key, .leave = leave, .event = e });
    }
    return out.items;
}

/// How long the way takes, as the diary has it: the maps' minutes for
/// this event, else `[butler] travel`.
fn minutesFor(e: diary.Event, travel: diary.Travel) u32 {
    for (travel.each) |x| if (x.start == e.start and std.mem.eql(u8, x.id, e.id)) return x.minutes;
    return travel.minutes;
}

/// The outside temperature in car_status's lines ("outside: -3 °C");
/// null when there is none (asleep, not woken, another make).
pub fn outsideOf(status: []const u8) ?f64 {
    var it = std.mem.splitScalar(u8, status, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "outside: ")) continue;
        const v = std.mem.trim(u8, line["outside: ".len..], " ");
        const end = std.mem.indexOfScalar(u8, v, ' ') orelse v.len;
        return std.fmt.parseFloat(f64, v[0..end]) catch null;
    }
    return null;
}

/// "8:10": the leave-by in the owner's time, the hour without a leading 0.
pub fn clockText(buf: *[8]u8, t: i64, offset: i32) []const u8 {
    const sod: u64 = @intCast(@mod(t + @as(i64, offset) * 60, 86400));
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ sod / 3600, sod / 60 % 60 }) catch "";
}

/// The instance's event (JSON: leave, outside, title) and input.
pub fn start(a: Allocator, d: Due, outside: f64) !struct { event: []const u8, input: []const u8 } {
    var lb: [8]u8 = undefined;
    var sb: [8]u8 = undefined;
    const leave = clockText(&lb, d.leave, d.event.offset);
    const deg = if (@abs(outside - @round(outside)) < 1e-9) try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(@round(outside)))}) else try std.fmt.allocPrint(a, "{d:.1}", .{outside});
    const Ev = struct { leave: []const u8, outside: []const u8, title: []const u8 };
    return .{
        .event = try std.json.Stringify.valueAlloc(a, Ev{ .leave = leave, .outside = deg, .title = d.event.title }, .{}),
        .input = try std.fmt.allocPrint(a, "{s} at {s}: leave at {s}; {s} °C at the car", .{ d.event.title, diary.clock(&sb, d.event.start, d.event.offset), leave, deg }),
    };
}

// ---- tests ----

const tt = std.testing;

/// 09:00 at +01:00 (08:00 UTC) on a day.
const nine: i64 = 1795478400 + 8 * 3600;

fn office(start_s: i64) diary.Event {
    return .{ .id = "work/office-1@calmcp-sim", .calendar = "work", .title = "Office", .start = start_s, .end = start_s + 8 * 3600, .offset = 60, .busy = true, .place = "Office, ul. Długa 5, Kraków", .when = "09:00–17:00", .day = "Tue 24 Nov" };
}

test "the_question_is_due_30_minutes_before_a_morning_leave_by_once" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const travel: diary.Travel = .{ .minutes = 50 };
    const leave = nine - 50 * 60;
    const evs = [_]diary.Event{office(nine)};
    try tt.expectEqual(@as(usize, 0), (try due(a, &evs, leave - ask_before_s - 60, travel, &.{})).len);
    const got = try due(a, &evs, leave - ask_before_s, travel, &.{});
    try tt.expectEqual(@as(usize, 1), got.len);
    try tt.expectEqual(leave, got[0].leave);
    try tt.expectEqualStrings("warm:work/office-1@calmcp-sim@1795507200", got[0].key);
    // later, up to the leave-by, still (harness may have been down); not after
    try tt.expectEqual(@as(usize, 1), (try due(a, &evs, leave - 60, travel, &.{})).len);
    try tt.expectEqual(@as(usize, 0), (try due(a, &evs, leave, travel, &.{})).len);
    // once
    try tt.expectEqual(@as(usize, 0), (try due(a, &evs, leave - 60, travel, &.{got[0].key})).len);
    // the maps' minutes for this event, when it gave them
    const by_maps: diary.Travel = .{ .minutes = 50, .each = &.{.{ .id = "work/office-1@calmcp-sim", .start = nine, .minutes = 20 }} };
    try tt.expectEqual(@as(usize, 0), (try due(a, &evs, leave - 60, by_maps, &.{})).len);
    try tt.expectEqual(nine - 20 * 60, (try due(a, &evs, nine - 20 * 60 - ask_before_s, by_maps, &.{}))[0].leave);
}

test "no_question_for_an_afternoon_a_call_a_whole_day_or_a_declined_event" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const travel: diary.Travel = .{ .minutes = 30 };
    // 14:00: leave at 13:30, an afternoon
    const two = nine + 5 * 3600;
    try tt.expectEqual(@as(usize, 0), (try due(a, &.{office(two)}, two - 50 * 60, travel, &.{})).len);
    // 12:20 leaves at 11:50: still the morning
    const noonish = nine + 3 * 3600 + 20 * 60;
    try tt.expectEqual(@as(usize, 1), (try due(a, &.{office(noonish)}, noonish - 50 * 60, travel, &.{})).len);
    var call = office(nine);
    call.place = "Zoom";
    var whole = office(nine);
    whole.all_day = true;
    var declined = office(nine);
    declined.answer = "DECLINED";
    var cancelled = office(nine);
    cancelled.cancelled = true;
    for ([_]diary.Event{ call, whole, declined, cancelled }) |e| try tt.expectEqual(@as(usize, 0), (try due(a, &.{e}, nine - 50 * 60, travel, &.{})).len);
}

test "the_outside_temperature_from_car_status" {
    try tt.expectEqual(@as(?f64, -3), outsideOf("The made-up Tesla:\nbattery: 64%\ninside: 4.5 °C\noutside: -3 °C\nclimate: off, set to 21 °C\n"));
    try tt.expectEqual(@as(?f64, 7.5), outsideOf("outside: 7.5 °C\r\n"));
    try tt.expectEqual(@as(?f64, null), outsideOf("The made-up Tesla:\nasleep: yes; reading it would wake it\n"));
    try tt.expectEqual(@as(?f64, null), outsideOf("outside: ? °C\n"));
    var b: [8]u8 = undefined;
    try tt.expectEqualStrings("8:10", clockText(&b, nine - 50 * 60, 60));
    try tt.expectEqualStrings("12:05", clockText(&b, nine + 3 * 3600 + 5 * 60, 60));
}

test "the_instance_starts_with_the_leave_by_and_the_reading" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try start(a, .{ .key = "k", .leave = nine - 50 * 60, .event = office(nine) }, -3);
    try tt.expectEqualStrings("{\"leave\":\"8:10\",\"outside\":\"-3\",\"title\":\"Office\"}", s.event);
    try tt.expectEqualStrings("Office at 09:00: leave at 8:10; -3 °C at the car", s.input);
    try tt.expectEqualStrings("{\"leave\":\"8:10\",\"outside\":\"-0.5\",\"title\":\"Office\"}", (try start(a, .{ .key = "k", .leave = nine - 50 * 60, .event = office(nine) }, -0.5)).event);
}

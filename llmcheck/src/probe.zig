//! One look at a server: does it list its models, answer a short chat and
//! start a stream, and how long does each take. With a record of its earlier
//! answers (see fidelity) also: does it still answer the same.

const std = @import("std");
const api = @import("api.zig");
const http = @import("http.zig");
const check = @import("check.zig");
const fidelity = @import("fidelity.zig");

pub const Options = struct {
    baseline: ?fidelity.Record = null,
    max_kl: f64 = 0.01,
    min_top1: f64 = 0.95,
};

/// `down`: the server could not be reached. `fail`: it was reached and
/// something does not work. `drift`: it works and answers differently
/// from the baseline.
pub const Status = enum { ok, fail, drift, down };

pub const Outcome = struct {
    status: Status = .ok,
    problem: ?[]const u8 = null,
    model: ?[]const u8 = null,
    models_ms: ?f64 = null,
    chat_ms: ?f64 = null,
    ttft_ms: ?f64 = null,
    drift_kl: ?f64 = null,
    drift_top1: ?f64 = null,
};

pub fn once(arena: std.mem.Allocator, s: *api.Server, opts: Options) error{OutOfMemory}!Outcome {
    var o: Outcome = .{};
    const given = s.model;
    defer s.model = given;
    const ms = std.time.ns_per_ms;

    var timer = std.time.Timer.start() catch unreachable;
    const models = s.models(arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem(arena, &o, .down, "", e, s),
    };
    o.models_ms = @as(f64, @floatFromInt(timer.read())) / ms;
    if (models.status != 200) {
        o.status = .fail;
        o.problem = try std.fmt.allocPrint(arena, "models: HTTP {d}", .{models.status});
        return o;
    }
    if (s.model == null and models.ids.len > 0) s.model = models.ids[0];
    o.model = s.model;

    const message = [_]api.Message{.{ .content = "Say hello." }};
    const chat = s.ask(arena, .{ .messages = &message, .max_tokens = 8 }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem(arena, &o, .fail, "chat: ", e, s),
    };
    if (try refused(arena, &o, "chat", chat)) return o;
    o.chat_ms = @as(f64, @floatFromInt(chat.total_ns)) / ms;

    const stream = s.ask(arena, .{ .messages = &message, .max_tokens = 8, .stream = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem(arena, &o, .fail, "stream: ", e, s),
    };
    if (try refused(arena, &o, "stream", stream)) return o;
    const first = stream.firstNs() orelse {
        o.status = .fail;
        o.problem = "stream: the answer did not come in pieces";
        return o;
    };
    o.ttft_ms = @as(f64, @floatFromInt(first)) / ms;

    if (opts.baseline) |baseline| {
        const prompts = try arena.alloc(fidelity.Prompt, baseline.items.len);
        for (baseline.items, prompts) |it, *p| p.* = it.prompt;
        const now = fidelity.record(arena, s, prompts, baseline.tokens, baseline.top) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return problem(arena, &o, .fail, "baseline: ", e, s),
        };
        const summary = fidelity.compareRecords(baseline, now);
        const judged = fidelity.judge(summary, baseline.noise, opts.max_kl, opts.min_top1);
        const all = summary.all();
        if (all.positions > 0) {
            o.drift_kl = all.meanKl();
            o.drift_top1 = all.top1();
        }
        switch (judged.verdict) {
            .same => {},
            .differs => {
                o.status = .drift;
                o.problem = judged.reason;
            },
            .unknown => {
                o.status = .fail;
                const why = summary.raw.problem orelse summary.chat.problem orelse judged.reason;
                o.problem = try std.fmt.allocPrint(arena, "baseline: {s}", .{why});
            },
        }
    }
    return o;
}

fn problem(arena: std.mem.Allocator, o: *Outcome, status: Status, comptime what: []const u8, e: http.Error, s: *api.Server) error{OutOfMemory}!Outcome {
    o.status = status;
    o.problem = try std.fmt.allocPrint(arena, what ++ "{s}", .{try check.describe(arena, e, s.limits)});
    return o.*;
}

/// True when `c` is not a usable answer; the outcome then says why.
fn refused(arena: std.mem.Allocator, o: *Outcome, comptime what: []const u8, c: api.Completion) error{OutOfMemory}!bool {
    if (c.ok() and (c.content.len > 0 or c.reasoning.len > 0)) return false;
    o.status = .fail;
    o.problem = if (!c.ok())
        if (c.error_message) |m|
            try std.fmt.allocPrint(arena, what ++ ": HTTP {d}: {s}", .{ c.status, try check.clip(arena, m, 140) })
        else
            try std.fmt.allocPrint(arena, what ++ ": HTTP {d}", .{c.status})
    else
        what ++ ": the answer is empty";
    return true;
}

/// Seconds since 1970 as UTC time, such as 2026-11-17T09:30:00Z.
pub fn isoTime(buf: *[20]u8, secs: u64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,                  month.month.numeric(),       @as(u32, month.day_index) + 1,
        clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

// ---- tests ----

const testing = std.testing;
const fake = @import("fake.zig");

const Rig = struct {
    arena_state: std.heap.ArenaAllocator,
    fake_server: *fake.Server,
    server: api.Server,

    fn init(r: *Rig, faults: fake.Faults) !void {
        r.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        r.fake_server = try fake.Server.start(faults, 0);
        r.server = api.Server.init(testing.allocator, .{ .https = false, .host = "127.0.0.1", .port = r.fake_server.port, .prefix = "" });
        r.server.limits = .{ .idle_ms = 300 };
    }
    fn deinit(r: *Rig) void {
        r.server.deinit();
        r.fake_server.stop();
        r.arena_state.deinit();
    }
    fn once(r: *Rig, opts: Options) !Outcome {
        return probe.once(r.arena_state.allocator(), &r.server, opts);
    }
};
const probe = @This();

test "a_working_server_is_timed_in_three_places" {
    var r: Rig = undefined;
    try r.init(.{ .token_delay_ms = 5 });
    defer r.deinit();
    const o = try r.once(.{});
    try testing.expectEqual(Status.ok, o.status);
    try testing.expect(o.problem == null);
    try testing.expectEqualStrings("fake-1", o.model.?);
    try testing.expect(o.models_ms.? > 0 and o.models_ms.? < 1000);
    try testing.expect(o.chat_ms.? >= 35 and o.chat_ms.? < 2000); // 8 tokens 5 ms apart
    try testing.expect(o.ttft_ms.? > 0 and o.ttft_ms.? < o.chat_ms.?);
    try testing.expect(o.drift_kl == null);
    // the model that was found is not kept: the next probe looks again
    try testing.expect(r.server.model == null);
}

test "a_server_that_is_reached_and_does_not_work_fails" {
    var r: Rig = undefined;
    try r.init(.{ .hang = true });
    defer r.deinit();
    const hung = try r.once(.{});
    try testing.expectEqual(Status.fail, hung.status);
    try testing.expectEqualStrings("chat: no answer within 300 ms", hung.problem.?);
    try testing.expect(hung.models_ms != null and hung.chat_ms == null);

    var keyed: Rig = undefined;
    try keyed.init(.{ .key = "sesame" });
    defer keyed.deinit();
    const denied = try keyed.once(.{});
    try testing.expectEqual(Status.fail, denied.status);
    try testing.expectEqualStrings("models: HTTP 401", denied.problem.?);
}

test "a_server_that_is_not_there_is_down" {
    var r: Rig = undefined;
    try r.init(.{});
    r.fake_server.stop();
    r.fake_server = try fake.Server.start(.{}, 0);
    defer r.deinit();
    // Windows takes its time to report a refused connection (more than the
    // 300 ms of the other tests), and until then it is a server not answering
    r.server.limits = .{ .idle_ms = 10_000 };
    const o = try r.once(.{});
    try testing.expectEqual(Status.down, o.status);
    try testing.expectEqualStrings("could not connect", o.problem.?);
}

test "answers_are_held_against_a_baseline" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    r.server.model = fake.model_name;
    const baseline = try fidelity.record(r.arena_state.allocator(), &r.server, fidelity.default_prompts[6..10], 8, 5);
    const same = try r.once(.{ .baseline = baseline });
    try testing.expectEqual(Status.ok, same.status);
    try testing.expectEqual(@as(f64, 0), same.drift_kl.?);
    try testing.expectEqual(@as(f64, 1), same.drift_top1.?);

    var other: Rig = undefined;
    try other.init(.{ .weights_differ = true });
    defer other.deinit();
    const drifted = try other.once(.{ .baseline = baseline });
    try testing.expectEqual(Status.drift, drifted.status);
    try testing.expect(drifted.drift_kl.? > 0.01);
    try testing.expect(std.mem.indexOf(u8, drifted.problem.?, "the model itself") != null);
    try testing.expect(drifted.ttft_ms != null);

    var mute: Rig = undefined;
    try mute.init(.{ .no_logprobs = true });
    defer mute.deinit();
    const unknown = try mute.once(.{ .baseline = baseline });
    try testing.expectEqual(Status.fail, unknown.status);
    try testing.expectEqualStrings("baseline: no token probabilities in the answer", unknown.problem.?);
}

test "time_is_written_as_utc" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", isoTime(&buf, 0));
    try testing.expectEqualStrings("2001-09-09T01:46:40Z", isoTime(&buf, 1_000_000_000));
    try testing.expectEqualStrings("2024-02-29T23:59:59Z", isoTime(&buf, 1709251199));
}

//! A modest load test: how fast a server answers when several ask at once.
//! Either a fixed number of askers that each send their next request as soon
//! as the last is answered (closed loop), or requests sent at a fixed rate
//! whatever the server does (open loop, --rate), where a request's time
//! counts from the moment it was due, so a server falling behind shows.

const std = @import("std");
const api = @import("api.zig");
const http = @import("http.zig");
const stats = @import("stats.zig");
const check = @import("check.zig");

pub const Setup = struct {
    target: http.Target,
    key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    insecure: bool = false,
    limits: http.Limits = .{ .idle_ms = 120_000 },
};

pub const Options = struct {
    concurrency: u32 = 16,
    /// Null with no duration either: twice the concurrency, 32 at least.
    requests: ?u32 = null,
    duration_s: ?f64 = null,
    /// Requests per second; null for a closed loop.
    rate: ?f64 = null,
    max_tokens: u32 = 64,
    prompt_words: u32 = 64,
    /// Requests sent first, one after another, and not counted.
    warmup: u32 = 1,
};

pub const Result = struct {
    model: ?[]const u8 = null,
    /// Requests sent, the failed ones too.
    requests: usize = 0,
    errors: usize = 0,
    first_error: ?[]const u8 = null,
    seconds: f64 = 0,
    output_tokens: u64 = 0,
    /// The server gave no token counts: the pieces of the streams were counted.
    estimated: bool = false,
    /// With --rate: requests that started over 5 ms after they were due.
    late: usize = 0,
    ttft_ms: stats.Summary = .{},
    latency_ms: stats.Summary = .{},
    token_gap_ms: stats.Summary = .{},
    stream_tokens_per_s: stats.Summary = .{},

    pub fn tokensPerS(r: Result) f64 {
        return if (r.seconds > 0) @as(f64, @floatFromInt(r.output_tokens)) / r.seconds else 0;
    }
    pub fn requestsPerS(r: Result) f64 {
        return if (r.seconds > 0) @as(f64, @floatFromInt(r.requests - r.errors)) / r.seconds else 0;
    }
};

/// An error means the server could not be reached at all. `gpa` is used
/// from several threads; what the result points to is in `arena`.
pub fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, setup: Setup, opts: Options) http.Error!Result {
    var shared: Shared = .{ .gpa = gpa, .setup = setup, .opts = opts, .model = setup.model, .start = undefined };
    if (opts.duration_s) |d| shared.duration_ns = @intFromFloat(d * std.time.ns_per_s);
    if (opts.requests) |n| shared.requests = n;
    if (opts.requests == null and opts.duration_s == null) shared.requests = @max(32, 2 * opts.concurrency);
    const n_workers: usize = @intCast(@max(1, if (shared.requests) |n| @min(n, opts.concurrency) else opts.concurrency));

    const workers = try arena.alloc(Worker, n_workers);
    for (workers) |*w| w.* = Worker.init(&shared);
    defer for (workers) |*w| w.deinit();

    // the first worker also finds the model and warms the server up
    const first = &workers[0];
    if (shared.model == null) {
        const m = try first.server.models(arena);
        if (m.ids.len > 0) shared.model = m.ids[0];
        first.server.model = shared.model;
    }
    for (0..opts.warmup) |i| {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        _ = try first.server.ask(scratch.allocator(), try request(scratch.allocator(), opts, std.math.maxInt(u32) - i));
    }

    shared.start = std.time.Instant.now() catch return error.ConnectFailed;
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        w.thread = std.Thread.spawn(.{}, Worker.loop, .{w}) catch break;
        spawned += 1;
    }
    first.loop();
    for (workers[1..][0..spawned]) |*w| w.thread.join();
    const wall = shared.now();

    var res: Result = .{ .model = shared.model, .seconds = @as(f64, @floatFromInt(wall)) / std.time.ns_per_s };
    var ttft: std.ArrayList(f64) = .empty;
    var latency: std.ArrayList(f64) = .empty;
    var gaps: std.ArrayList(f64) = .empty;
    var rates: std.ArrayList(f64) = .empty;
    var first_error_at: u64 = std.math.maxInt(u64);
    for (workers) |*w| {
        res.requests += w.requests;
        res.errors += w.errors;
        res.late += w.late;
        res.output_tokens += w.output_tokens;
        res.estimated = res.estimated or w.estimated;
        try ttft.appendSlice(arena, w.ttft.items);
        try latency.appendSlice(arena, w.latency.items);
        try gaps.appendSlice(arena, w.gaps.items);
        try rates.appendSlice(arena, w.rates.items);
        if (w.first_error) |e| if (w.first_error_at < first_error_at) {
            first_error_at = w.first_error_at;
            res.first_error = try arena.dupe(u8, e);
        };
        if (w.oom) return error.OutOfMemory;
    }
    res.ttft_ms = stats.summarize(ttft.items);
    res.latency_ms = stats.summarize(latency.items);
    res.token_gap_ms = stats.summarize(gaps.items);
    res.stream_tokens_per_s = stats.summarize(rates.items);
    return res;
}

const Shared = struct {
    gpa: std.mem.Allocator,
    setup: Setup,
    opts: Options,
    model: ?[]const u8,
    start: std.time.Instant,
    requests: ?u64 = null,
    duration_ns: ?u64 = null,
    next: std.atomic.Value(u64) = .init(0),

    fn now(s: *const Shared) u64 {
        const t = std.time.Instant.now() catch return 0;
        return t.since(s.start);
    }
};

const filler = [_][]const u8{
    "river", "stone", "light", "winter", "garden", "silver", "window", "paper",
    "harbour", "morning", "thread", "forest", "candle", "bridge", "summer", "copper",
};

/// A request no other is like, so that no cache answers it.
fn request(arena: std.mem.Allocator, opts: Options, nonce: u64) error{OutOfMemory}!api.Ask {
    var text: std.ArrayList(u8) = .empty;
    try text.print(arena, "Request {d}. Here are some words:", .{nonce});
    for (0..opts.prompt_words) |i| {
        try text.append(arena, ' ');
        try text.appendSlice(arena, filler[(i * 7 + nonce) % filler.len]);
    }
    try text.appendSlice(arena, ". Write a long story that uses them.");
    const messages = try arena.alloc(api.Message, 1);
    messages[0] = .{ .content = text.items };
    return .{ .messages = messages, .max_tokens = opts.max_tokens, .stream = true };
}

const Worker = struct {
    shared: *Shared,
    server: api.Server,
    thread: std.Thread = undefined,
    requests: usize = 0,
    errors: usize = 0,
    late: usize = 0,
    output_tokens: u64 = 0,
    estimated: bool = false,
    oom: bool = false,
    first_error: ?[]u8 = null,
    first_error_at: u64 = 0,
    ttft: std.ArrayList(f64) = .empty,
    latency: std.ArrayList(f64) = .empty,
    gaps: std.ArrayList(f64) = .empty,
    rates: std.ArrayList(f64) = .empty,

    fn init(shared: *Shared) Worker {
        var w: Worker = .{ .shared = shared, .server = api.Server.init(shared.gpa, shared.setup.target) };
        w.server.key = shared.setup.key;
        w.server.model = shared.model;
        w.server.limits = shared.setup.limits;
        w.server.client.insecure = shared.setup.insecure;
        return w;
    }

    fn deinit(w: *Worker) void {
        const gpa = w.shared.gpa;
        w.server.deinit();
        if (w.first_error) |e| gpa.free(e);
        w.ttft.deinit(gpa);
        w.latency.deinit(gpa);
        w.gaps.deinit(gpa);
        w.rates.deinit(gpa);
    }

    fn loop(w: *Worker) void {
        const s = w.shared;
        w.server.model = s.model;
        while (true) {
            const i = s.next.fetchAdd(1, .monotonic);
            if (s.requests) |n| if (i >= n) return;
            var due: ?u64 = null;
            if (s.opts.rate) |rate| {
                due = @intFromFloat(@as(f64, @floatFromInt(i)) / rate * std.time.ns_per_s);
                if (s.duration_ns) |d| if (due.? >= d) return;
                const t = s.now();
                if (t < due.?) std.Thread.sleep(due.? - t);
            } else if (s.duration_ns) |d| {
                if (s.now() >= d) return;
            }
            w.one(i, due) catch {
                w.oom = true;
                return;
            };
        }
    }

    fn fail(w: *Worker, i: u64, comptime fmt: []const u8, args: anytype) !void {
        w.errors += 1;
        if (w.first_error == null) {
            w.first_error = try std.fmt.allocPrint(w.shared.gpa, fmt, args);
            w.first_error_at = i;
        }
    }

    fn one(w: *Worker, i: u64, due: ?u64) !void {
        const s = w.shared;
        const gpa = s.gpa;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // at a fixed rate the clock of a request starts when it was due
        const started = s.now();
        const waited: u64 = if (due) |d| started -| d else 0;
        if (waited > 5 * std.time.ns_per_ms) w.late += 1;

        w.requests += 1;
        const c = w.server.ask(arena, try request(arena, s.opts, i)) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return w.fail(i, "{s}", .{try check.describe(arena, e, w.server.limits)}),
        };
        if (!c.ok()) {
            if (c.error_message) |m| return w.fail(i, "HTTP {d}: {s}", .{ c.status, try check.clip(arena, m, 140) });
            return w.fail(i, "HTTP {d}", .{c.status});
        }
        const ms = std.time.ns_per_ms;
        try w.latency.append(gpa, @as(f64, @floatFromInt(waited + c.total_ns)) / ms);
        var tokens: u64 = c.arrivals_ns.len;
        if (c.completion_tokens) |n| tokens = n else w.estimated = true;
        w.output_tokens += tokens;
        const first = c.firstNs() orelse return;
        try w.ttft.append(gpa, @as(f64, @floatFromInt(waited + first)) / ms);
        for (c.arrivals_ns[0 .. c.arrivals_ns.len - 1], c.arrivals_ns[1..]) |a, b| {
            try w.gaps.append(gpa, @as(f64, @floatFromInt(b - a)) / ms);
        }
        if (tokens > 1 and c.total_ns > first) {
            try w.rates.append(gpa, @as(f64, @floatFromInt(tokens - 1)) / (@as(f64, @floatFromInt(c.total_ns - first)) / std.time.ns_per_s));
        }
    }
};

// ---- tests ----

const testing = std.testing;
const fake = @import("fake.zig");

const Rig = struct {
    arena_state: std.heap.ArenaAllocator,
    fake_server: *fake.Server,
    setup: Setup,

    fn init(r: *Rig, faults: fake.Faults) !void {
        r.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        r.fake_server = try fake.Server.start(faults, 0);
        r.setup = .{
            .target = .{ .https = false, .host = "127.0.0.1", .port = r.fake_server.port, .prefix = "" },
            .model = fake.model_name,
            .limits = .{ .idle_ms = 5000 },
        };
    }
    fn deinit(r: *Rig) void {
        r.fake_server.stop();
        r.arena_state.deinit();
    }
    fn run(r: *Rig, opts: Options) !Result {
        return bench.run(testing.allocator, r.arena_state.allocator(), r.setup, opts);
    }
};
const bench = @This();

test "askers_work_side_by_side_and_every_request_is_measured" {
    var r: Rig = undefined;
    try r.init(.{ .token_delay_ms = 5 });
    defer r.deinit();
    const res = try r.run(.{ .concurrency = 4, .requests = 8, .max_tokens = 8 });
    try testing.expectEqual(@as(usize, 8), res.requests);
    try testing.expectEqual(@as(usize, 0), res.errors);
    try testing.expect(res.first_error == null);
    try testing.expectEqual(@as(u64, 64), res.output_tokens);
    try testing.expect(!res.estimated);
    try testing.expectEqualStrings("fake-1", res.model.?);
    try testing.expectEqual(@as(u32, 4), r.fake_server.peak_generating.load(.acquire));
    // one warm-up request before the eight, and the model was given: nothing else is sent
    try testing.expectEqual(@as(u32, 9), r.fake_server.requests.load(.acquire));
    try testing.expectEqual(@as(usize, 8), res.ttft_ms.n);
    try testing.expectEqual(@as(usize, 8), res.latency_ms.n);
    try testing.expectEqual(@as(usize, 8), res.stream_tokens_per_s.n);
    try testing.expect(res.token_gap_ms.n > 0);
    // 8 tokens 5 ms apart: 35 ms from the first to the last
    try testing.expect(res.latency_ms.min >= 35);
    try testing.expect(res.ttft_ms.max <= res.latency_ms.max);
    try testing.expect(res.stream_tokens_per_s.max <= 200.5);
    try testing.expect(res.seconds >= 0.07 and res.seconds < 5);
    try testing.expectApproxEqAbs(64 / res.seconds, res.tokensPerS(), 1e-9);
    try testing.expectApproxEqAbs(8 / res.seconds, res.requestsPerS(), 1e-9);
}

test "a_model_is_picked_from_the_list_when_none_is_named" {
    var r: Rig = undefined;
    try r.init(.{ .no_usage = true });
    defer r.deinit();
    r.setup.model = null;
    const res = try r.run(.{ .concurrency = 2, .requests = 2, .max_tokens = 4, .warmup = 0 });
    try testing.expectEqualStrings("fake-1", res.model.?);
    try testing.expectEqual(@as(usize, 0), res.errors);
    // without counts from the server the pieces of the stream are counted
    try testing.expect(res.estimated);
    try testing.expectEqual(@as(u64, 8), res.output_tokens);
}

test "requests_at_a_fixed_rate_start_when_they_are_due" {
    var r: Rig = undefined;
    try r.init(.{});
    defer r.deinit();
    const res = try r.run(.{ .concurrency = 4, .requests = 10, .rate = 50, .max_tokens = 4, .warmup = 0 });
    try testing.expectEqual(@as(usize, 10), res.requests);
    try testing.expectEqual(@as(usize, 0), res.errors);
    try testing.expect(res.seconds >= 0.18 and res.seconds < 5); // the tenth is due after 180 ms
}

test "a_server_that_falls_behind_a_rate_shows_in_the_times" {
    var r: Rig = undefined;
    try r.init(.{ .token_delay_ms = 10 });
    defer r.deinit();
    // one asker, 40 ms an answer, a request due every 10 ms: the last waits its turn
    const res = try r.run(.{ .concurrency = 1, .requests = 5, .rate = 100, .max_tokens = 4, .warmup = 0 });
    try testing.expectEqual(@as(usize, 5), res.requests);
    try testing.expect(res.late >= 3);
    try testing.expect(res.latency_ms.max >= 100);
    try testing.expect(res.ttft_ms.max >= 70);
}

test "a_run_can_end_after_a_time" {
    var r: Rig = undefined;
    try r.init(.{ .token_delay_ms = 5 });
    defer r.deinit();
    const res = try r.run(.{ .concurrency = 2, .duration_s = 0.15, .max_tokens = 4, .warmup = 0 });
    try testing.expect(res.requests >= 4);
    try testing.expect(res.seconds >= 0.15 and res.seconds < 2);
    try testing.expectEqual(@as(usize, 0), res.errors);
}

test "refused_requests_are_counted_with_the_first_reason" {
    var r: Rig = undefined;
    try r.init(.{ .key = "sesame" });
    defer r.deinit();
    const res = try r.run(.{ .concurrency = 2, .requests = 4, .max_tokens = 4 });
    try testing.expectEqual(@as(usize, 4), res.requests);
    try testing.expectEqual(@as(usize, 4), res.errors);
    try testing.expectEqualStrings("HTTP 401: Incorrect API key provided.", res.first_error.?);
    try testing.expectEqual(@as(usize, 0), res.latency_ms.n);
    try testing.expectEqual(@as(f64, 0), res.requestsPerS());

    r.setup.key = "sesame";
    const with_key = try r.run(.{ .concurrency = 2, .requests = 4, .max_tokens = 4 });
    try testing.expectEqual(@as(usize, 0), with_key.errors);
}

test "a_server_that_is_not_there_is_an_error" {
    var r: Rig = undefined;
    try r.init(.{});
    r.fake_server.stop();
    r.fake_server = try fake.Server.start(.{}, 0);
    defer r.deinit();
    try testing.expectError(error.ConnectFailed, r.run(.{ .concurrency = 2, .requests = 2 }));
}

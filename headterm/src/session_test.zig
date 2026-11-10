//! Tests against real session servers, forked from the test process into a
//! private session directory.

const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const client = @import("client.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const gpa = std.heap.c_allocator;

/// Points XDG_RUNTIME_DIR at a fresh directory for the duration of a test.
const SessionDir = struct {
    path_buf: [64]u8 = undefined,
    path: [:0]const u8 = "",
    old_buf: [std.fs.max_path_bytes]u8 = undefined,
    old: ?[:0]const u8 = null,

    fn init(self: *SessionDir, tag: []const u8) !void {
        self.path = try std.fmt.bufPrintZ(&self.path_buf, "/tmp/headterm-test-{d}-{s}", .{ std.c.getpid(), tag });
        std.fs.makeDirAbsolute(self.path) catch |e| if (e != error.PathAlreadyExists) return e;
        if (posix.getenv("XDG_RUNTIME_DIR")) |old| self.old = try std.fmt.bufPrintZ(&self.old_buf, "{s}", .{old});
        _ = setenv("XDG_RUNTIME_DIR", self.path, 1);
    }

    fn deinit(self: *SessionDir) void {
        if (self.old) |old| _ = setenv("XDG_RUNTIME_DIR", old, 1) else _ = unsetenv("XDG_RUNTIME_DIR");
        std.fs.deleteTreeAbsolute(self.path) catch {};
    }
};

fn start(name: []const u8, argv: []const []const u8, opts: client.StartOptions) !void {
    var msg: [256]u8 = undefined;
    _ = client.startSession(gpa, name, argv, opts, &msg) catch {
        std.debug.print("start failed: {s}\n", .{std.mem.sliceTo(&msg, 0)});
        return error.StartFailed;
    };
}

fn kill(name: []const u8) void {
    if (client.call(gpa, name, &.{"kill"})) |r| gpa.free(r.body) else |_| {}
}

fn call(name: []const u8, args: []const []const u8) !client.Response {
    return client.call(gpa, name, args);
}

test "a client that hangs up before the reply does not take the session down" {
    var dir: SessionDir = .{};
    try dir.init("hangup");
    defer dir.deinit();
    try start("hangup", &.{ "sleep", "30" }, .{});
    defer kill("hangup");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = try client.sessionSocket(&path_buf, "hangup");
    // macOS fails setsockopt with EINVAL on an accepted socket whose peer
    // has already closed; std.posix.setsockopt treated that as unreachable
    // and the session server crashed.
    const requests = [_][]const []const u8{
        &.{"screen"},
        &.{"info"},
        &.{ "send", "--", "x" },
        &.{ "wait", "--text", "never" },
        &.{ "wait", "--idle", "50" },
    };
    for (requests) |args| {
        for (0..3) |_| {
            const s = try client.connect(sock);
            try client.sendRequest(gpa, s.handle, args);
            s.close();
        }
    }
    const resp = try call("hangup", &.{"info"});
    defer gpa.free(resp.body);
    try testing.expectEqual(client.Status.ok, resp.status);
}

test "a session with a TTL ends after that long without requests or output" {
    var dir: SessionDir = .{};
    try dir.init("ttl");
    defer dir.deinit();
    try start("ttl", &.{ "sleep", "30" }, .{ .ttl_s = 1 });
    defer kill("ttl");

    const info = try call("ttl", &.{"info"});
    defer gpa.free(info.body);
    try testing.expect(std.mem.indexOf(u8, info.body, "\"ttl_s\":1") != null);

    // Every request counts as activity, so stay quiet for longer than the
    // TTL, then look once.
    std.Thread.sleep(2200 * std.time.ns_per_ms);
    try testing.expectError(error.NoSuchSession, call("ttl", &.{"info"}));
}

test "each client has its own diff marker" {
    var dir: SessionDir = .{};
    try dir.init("markers");
    defer dir.deinit();
    try start("markers", &.{ "/bin/sh", "-c", "echo one; read x; echo two; sleep 30" }, .{ .cols = 20, .rows = 4 });
    defer kill("markers");

    const first = try call("markers", &.{ "wait", "--text", "one", "--client", "a" });
    gpa.free(first.body);
    const b_first = try call("markers", &.{ "screen", "--diff", "--client", "b" });
    defer gpa.free(b_first.body);
    try testing.expect(std.mem.indexOf(u8, b_first.body, "0|one") != null);

    const sent = try call("markers", &.{ "send", "<Enter>" });
    gpa.free(sent.body);
    const a_wait = try call("markers", &.{ "wait", "--text", "two", "--diff", "--client", "a" });
    defer gpa.free(a_wait.body);
    try testing.expect(std.mem.indexOf(u8, a_wait.body, "2|two") != null);
    try testing.expect(std.mem.indexOf(u8, a_wait.body, "0|one") == null);

    // Client a has seen "two"; client b has not, and still gets it.
    const b_diff = try call("markers", &.{ "screen", "--diff", "--client", "b" });
    defer gpa.free(b_diff.body);
    try testing.expect(std.mem.indexOf(u8, b_diff.body, "2|two") != null);
    const a_diff = try call("markers", &.{ "screen", "--diff", "--client", "a" });
    defer gpa.free(a_diff.body);
    try testing.expect(std.mem.indexOf(u8, a_diff.body, "changed=0") != null);
}

test "settle after a send waits for the program to react to the keys" {
    var dir: SessionDir = .{};
    try dir.init("settle");
    defer dir.deinit();
    // No echo, so the only output after the send is the program's own, and
    // it comes 300 ms later.
    try start("settle", &.{ "/bin/sh", "-c", "stty -echo; echo ready; read x; sleep 0.3; echo got-$x; read y; sleep 30" }, .{ .cols = 20, .rows = 4 });
    defer kill("settle");

    const ready = try call("settle", &.{ "wait", "--text", "ready" });
    gpa.free(ready.body);
    // The last output is now older than the settle time.
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const sent = try call("settle", &.{ "send", "a", "<Enter>" });
    gpa.free(sent.body);
    const after = try call("settle", &.{ "wait", "--settle", "100", "--timeout", "3000" });
    defer gpa.free(after.body);
    try testing.expectEqual(client.Status.ok, after.status);
    try testing.expect(std.mem.indexOf(u8, after.body, "got-a") != null);

    // Keys the program doesn't answer: settle gives up after the grace
    // period instead of running into the timeout.
    const quiet = try call("settle", &.{ "send", "b", "<Enter>" });
    gpa.free(quiet.body);
    const t0 = std.time.milliTimestamp();
    const none = try call("settle", &.{ "wait", "--settle", "100", "--timeout", "5000" });
    defer gpa.free(none.body);
    const took = std.time.milliTimestamp() - t0;
    try testing.expectEqual(client.Status.ok, none.status);
    try testing.expect(took >= 300 and took < 2000);
}

test "wait --exit gives up early when the program is reading keys" {
    var dir: SessionDir = .{};
    try dir.init("awaiting");
    defer dir.deinit();

    try start("pw", &.{ "/bin/sh", "-c", "stty -echo; printf 'pw: '; read x; stty echo; echo got:$x" }, .{ .cols = 40, .rows = 5 });
    defer kill("pw");
    var t0 = std.time.milliTimestamp();
    const first = try call("pw", &.{ "wait", "--exit", "--timeout", "9000" });
    defer gpa.free(first.body);
    try testing.expectEqual(client.Status.timeout, first.status);
    try testing.expect(std.time.milliTimestamp() - t0 < 6000);
    try testing.expect(std.mem.indexOf(u8, first.body, "wait=failed(awaiting-input)") != null);
    try testing.expect(std.mem.indexOf(u8, first.body, "echo is off, so it is probably waiting for input") != null);

    // Once per send: a second wait runs to its timeout.
    const second = try call("pw", &.{ "wait", "--exit", "--timeout", "2600" });
    defer gpa.free(second.body);
    try testing.expect(std.mem.indexOf(u8, second.body, "wait=failed(timeout)") != null);

    const sent = try call("pw", &.{ "send", "s3cret", "<Enter>" });
    gpa.free(sent.body);
    const done = try call("pw", &.{ "wait", "--exit", "--timeout", "5000" });
    defer gpa.free(done.body);
    try testing.expectEqual(client.Status.ok, done.status);
    try testing.expect(std.mem.indexOf(u8, done.body, "got:s3cret") != null);

    // A line prompt with echo looks like any quiet program: no early stop.
    try start("line", &.{ "/bin/sh", "-c", "printf 'name: '; read x" }, .{ .cols = 40, .rows = 5 });
    defer kill("line");
    t0 = std.time.milliTimestamp();
    const line = try call("line", &.{ "wait", "--exit", "--timeout", "2600" });
    defer gpa.free(line.body);
    try testing.expect(std.mem.indexOf(u8, line.body, "wait=failed(timeout)") != null);
    try testing.expect(std.time.milliTimestamp() - t0 >= 2500);
}

test "wait --idle ignores a blinking cursor but not other output" {
    var dir: SessionDir = .{};
    try dir.init("idle");
    defer dir.deinit();

    // A cursor the program draws itself and blinks in reverse video, as
    // Bubble Tea forms do: output every 100 ms, the same text every time.
    try start("blink", &.{ "/bin/sh", "-c", "printf 'name: '; while :; do printf '\\033[7m \\033[0m\\b'; sleep 0.1; printf ' \\b'; sleep 0.1; done" }, .{ .cols = 40, .rows = 5 });
    defer kill("blink");
    const idle = try call("blink", &.{ "wait", "--idle", "500", "--timeout", "4000" });
    defer gpa.free(idle.body);
    try testing.expectEqual(client.Status.ok, idle.status);
    try testing.expect(std.mem.indexOf(u8, idle.body, "name:") != null);

    // A cell going through four colors: the text stays the same, but no
    // screen is the one before the last.
    try start("bar", &.{ "/bin/sh", "-c", "while :; do for c in 41 42 43 44; do printf '\\033[%sm \\033[0m\\b' $c; sleep 0.1; done; done" }, .{ .cols = 40, .rows = 4 });
    defer kill("bar");
    const bar = try call("bar", &.{ "wait", "--idle", "500", "--timeout", "1500" });
    defer gpa.free(bar.body);
    try testing.expectEqual(client.Status.timeout, bar.status);

    // The same line again and again leaves the screen's text as it was, but
    // it is scrolling.
    try start("scroll", &.{ "/bin/sh", "-c", "while :; do echo same; sleep 0.1; done" }, .{ .cols = 40, .rows = 4 });
    defer kill("scroll");
    const busy = try call("scroll", &.{ "wait", "--idle", "500", "--timeout", "1500" });
    defer gpa.free(busy.body);
    try testing.expectEqual(client.Status.timeout, busy.status);
}

test "start --record writes a valid asciicast v2 file" {
    var dir: SessionDir = .{};
    try dir.init("record");
    defer dir.deinit();
    var path_buf: [128]u8 = undefined;
    const cast = try std.fmt.bufPrint(&path_buf, "{s}/session.cast", .{dir.path});

    try start("rec", &.{ "/bin/sh", "-c", "read x; echo got:$x" }, .{ .cols = 30, .rows = 5, .record_path = cast });
    defer kill("rec");
    const sent = try call("rec", &.{ "send", "hi", "<Enter>" });
    gpa.free(sent.body);
    const waited = try call("rec", &.{ "wait", "--exit" });
    gpa.free(waited.body);
    kill("rec"); // closes the recording

    const data = try std.fs.cwd().readFileAlloc(gpa, cast, 1 << 20);
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, data, "\n"), '\n');
    const header = try std.json.parseFromSlice(std.json.Value, gpa, lines.next().?, .{});
    defer header.deinit();
    try testing.expectEqual(@as(i64, 2), header.value.object.get("version").?.integer);
    try testing.expectEqual(@as(i64, 30), header.value.object.get("width").?.integer);
    try testing.expectEqual(@as(i64, 5), header.value.object.get("height").?.integer);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var input_seen = false;
    while (lines.next()) |line| {
        const ev = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer ev.deinit();
        const arr = ev.value.array.items;
        try testing.expectEqual(@as(usize, 3), arr.len);
        try testing.expect(arr[0] == .float or arr[0] == .integer);
        if (std.mem.eql(u8, arr[1].string, "o")) try output.appendSlice(gpa, arr[2].string);
        if (std.mem.eql(u8, arr[1].string, "i")) {
            try testing.expectEqualStrings("hi\r", arr[2].string);
            input_seen = true;
        }
    }
    try testing.expect(input_seen);
    try testing.expect(std.mem.indexOf(u8, output.items, "got:hi") != null);
}

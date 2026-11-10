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

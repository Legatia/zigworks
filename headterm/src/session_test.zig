//! Tests against real session servers, started from the test process into
//! a private session directory.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const client = @import("client.zig");
const sys = @import("sys.zig");

const gpa = std.heap.c_allocator;

/// The programs the sessions run: one-liners for sh on macOS and Linux,
/// for cmd.exe on Windows (where `pause` reads one key without echo, and
/// `set /p` a line with echo).
const programs = if (builtin.os.tag == .windows) struct {
    fn tmpDir(buf: []u8) []const u8 {
        return sys.getenvBuf(buf, "TEMP") orelse ".";
    }
    /// Runs until it is killed.
    const idle: []const []const u8 = &.{"cmd.exe"};
    /// Prints "one", reads a line, prints "two". `set /p` and not `pause`:
    /// pause throws away what was typed before it began to wait, and a
    /// test sends its key as soon as "one" is there.
    const one_two: []const []const u8 = &.{ "cmd.exe", "/d", "/c", "echo one& set /p x=& echo two& pause>nul" };
    /// The row "two" ends up on: the line that was read takes row 1.
    const two_row = "2|two";
    /// Prints "ready"; answers the first key 150 ms later with "got-a",
    /// and the second not at all. PowerShell, as cmd.exe cannot pause for
    /// less than a second. (150 ms and not the 300 of the sh version:
    /// PowerShell on a busy machine is late by itself, and the answer has
    /// to come within the time a send is given to be answered.)
    const slow_answer: []const []const u8 = &.{ "powershell.exe", "-NoProfile", "-Command", "Write-Host ready; [void][Console]::ReadKey($true); Start-Sleep -Milliseconds 150; Write-Host got-a; [void][Console]::ReadKey($true); Start-Sleep 30" };
    const answer_keys: []const []const u8 = &.{"a"};
    /// Reads a line and prints it after "got:".
    const echo_line: []const []const u8 = &.{ "cmd.exe", "/d", "/v:on", "/c", "set /p x=& echo got:!x!" };
    /// Asks for a key without echo, then prints "got:" and a line it reads.
    const hidden_prompt: []const []const u8 = &.{ "cmd.exe", "/d", "/v:on", "/c", "echo pw& pause>nul& set /p x=& echo got:!x!" };
    const hidden_mode = "the terminal is in raw mode, so it is probably waiting for input";
    const hidden_keys: []const []const u8 = &.{ "k", "s3cret", "<Enter>" };
    /// Asks for a line, with echo.
    const line_prompt: []const []const u8 = &.{ "cmd.exe", "/d", "/c", "set /p x=name: " };
} else struct {
    fn tmpDir(_: []u8) []const u8 {
        return "/tmp";
    }
    const idle: []const []const u8 = &.{ "sleep", "30" };
    const one_two: []const []const u8 = &.{ "/bin/sh", "-c", "echo one; read x; echo two; sleep 30" };
    const two_row = "2|two";
    // No echo, so the only output after the send is the program's own,
    // and it comes 300 ms later.
    const slow_answer: []const []const u8 = &.{ "/bin/sh", "-c", "stty -echo; echo ready; read x; sleep 0.3; echo got-$x; read y; sleep 30" };
    const answer_keys: []const []const u8 = &.{ "a", "<Enter>" };
    const echo_line: []const []const u8 = &.{ "/bin/sh", "-c", "read x; echo got:$x" };
    const hidden_prompt: []const []const u8 = &.{ "/bin/sh", "-c", "stty -echo; printf 'pw: '; read x; stty echo; echo got:$x" };
    const hidden_mode = "echo is off, so it is probably waiting for input";
    const hidden_keys: []const []const u8 = &.{ "s3cret", "<Enter>" };
    const line_prompt: []const []const u8 = &.{ "/bin/sh", "-c", "printf 'name: '; read x" };
};

/// Points XDG_RUNTIME_DIR at a fresh directory for the duration of a test.
const SessionDir = struct {
    path_buf: [200]u8 = undefined,
    path: [:0]const u8 = "",
    old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    old: ?[:0]const u8 = null,

    fn init(self: *SessionDir, tag: []const u8) !void {
        var tmp_buf: [128]u8 = undefined;
        const tmp = programs.tmpDir(&tmp_buf);
        self.path = try std.mem.printSentinel(&self.path_buf, "{s}" ++ std.fs.path.sep_str ++ "headterm-test-{d}-{s}", .{ tmp, sys.getpid(), tag }, 0);
        std.Io.Dir.createDirAbsolute(testing.io, self.path, .default_dir) catch |e| if (e != error.PathAlreadyExists) return e;
        var old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (sys.getenvBuf(&old_buf, "XDG_RUNTIME_DIR")) |old| self.old = try std.mem.printSentinel(&self.old_buf, "{s}", .{old}, 0);
        sys.setEnv("XDG_RUNTIME_DIR", self.path);
    }

    fn deinit(self: *SessionDir) void {
        sys.setEnv("XDG_RUNTIME_DIR", self.old);
        std.Io.Dir.cwd().deleteTree(testing.io, self.path) catch {};
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

/// `send` followed by `keys`.
fn sendArgs(buf: [][]const u8, keys: []const []const u8) ![]const []const u8 {
    if (keys.len + 1 > buf.len) return error.TestTooManyKeys;
    buf[0] = "send";
    @memcpy(buf[1..][0..keys.len], keys);
    return buf[0 .. keys.len + 1];
}

fn sleepMs(ms: i64) !void {
    try std.Io.sleep(testing.io, .fromMilliseconds(ms), .awake);
}

test "a client that hangs up before the reply does not take the session down" {
    var dir: SessionDir = .{};
    try dir.init("hangup");
    defer dir.deinit();
    try start("hangup", programs.idle, .{});
    defer kill("hangup");

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
            const fd = try client.connect(sock);
            try client.sendRequest(gpa, fd, args);
            sys.close(fd);
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
    try start("ttl", programs.idle, .{ .ttl_s = 1 });
    defer kill("ttl");

    const info = try call("ttl", &.{"info"});
    defer gpa.free(info.body);
    try testing.expect(std.mem.find(u8, info.body, "\"ttl_s\":1") != null);

    // Every request counts as activity, so stay quiet for longer than the
    // TTL, then look once. On a busy machine the server can be late, or be
    // caught while it ends (the request then gets no answer): look again
    // after another quiet stretch, a few times at most.
    var gone = false;
    var tries: u32 = 0;
    while (!gone and tries < 4) : (tries += 1) {
        try sleepMs(2200);
        if (call("ttl", &.{"info"})) |still| {
            gpa.free(still.body);
        } else |err| switch (err) {
            error.NoSuchSession => gone = true,
            else => {},
        }
    }
    try testing.expect(gone);
}

test "each client has its own diff marker" {
    var dir: SessionDir = .{};
    try dir.init("markers");
    defer dir.deinit();
    try start("markers", programs.one_two, .{ .cols = 20, .rows = 4 });
    defer kill("markers");

    const first = try call("markers", &.{ "wait", "--text", "one", "--client", "a" });
    gpa.free(first.body);
    const b_first = try call("markers", &.{ "screen", "--diff", "--client", "b" });
    defer gpa.free(b_first.body);
    try testing.expect(std.mem.find(u8, b_first.body, "0|one") != null);

    const sent = try call("markers", &.{ "send", "<Enter>" });
    gpa.free(sent.body);
    const a_wait = try call("markers", &.{ "wait", "--text", "two", "--diff", "--client", "a" });
    defer gpa.free(a_wait.body);
    // seen to fail once in about a hundred runs on a busy Windows machine:
    // say what came instead
    if (std.mem.find(u8, a_wait.body, programs.two_row) == null) std.debug.print("each client has its own diff marker: no '{s}' in the wait's answer ({s}): [{s}]; client b's first screen: [{s}]\n", .{ programs.two_row, @tagName(a_wait.status), a_wait.body, b_first.body });
    try testing.expect(std.mem.find(u8, a_wait.body, programs.two_row) != null);
    try testing.expect(std.mem.find(u8, a_wait.body, "0|one") == null);

    // Client a has seen "two"; client b has not, and still gets it.
    const b_diff = try call("markers", &.{ "screen", "--diff", "--client", "b" });
    defer gpa.free(b_diff.body);
    try testing.expect(std.mem.find(u8, b_diff.body, programs.two_row) != null);
    const a_diff = try call("markers", &.{ "screen", "--diff", "--client", "a" });
    defer gpa.free(a_diff.body);
    try testing.expect(std.mem.find(u8, a_diff.body, "changed=0") != null);
}

test "settle after a send waits for the program to react to the keys" {
    var dir: SessionDir = .{};
    try dir.init("settle");
    defer dir.deinit();
    try start("settle", programs.slow_answer, .{ .cols = 20, .rows = 4 });
    defer kill("settle");

    var args_buf: [8][]const u8 = undefined;
    const ready = try call("settle", &.{ "wait", "--text", "ready" });
    gpa.free(ready.body);
    // The last output is now older than the settle time.
    try sleepMs(300);

    const sent = try call("settle", try sendArgs(&args_buf, programs.answer_keys));
    gpa.free(sent.body);
    const after = try call("settle", &.{ "wait", "--settle", "100", "--timeout", "3000" });
    defer gpa.free(after.body);
    try testing.expectEqual(client.Status.ok, after.status);
    try testing.expect(std.mem.find(u8, after.body, "got-a") != null);

    // Keys the program doesn't answer: settle gives up after the grace
    // period instead of running into the timeout.
    const quiet = try call("settle", try sendArgs(&args_buf, programs.answer_keys));
    gpa.free(quiet.body);
    const t0 = sys.milliTimestamp();
    const none = try call("settle", &.{ "wait", "--settle", "100", "--timeout", "5000" });
    defer gpa.free(none.body);
    const took = sys.milliTimestamp() - t0;
    try testing.expectEqual(client.Status.ok, none.status);
    try testing.expect(took >= 300 and took < 2000);
}

test "wait --exit gives up early when the program is reading keys" {
    var dir: SessionDir = .{};
    try dir.init("awaiting");
    defer dir.deinit();

    try start("pw", programs.hidden_prompt, .{ .cols = 40, .rows = 5 });
    defer kill("pw");
    var t0 = sys.milliTimestamp();
    const first = try call("pw", &.{ "wait", "--exit", "--timeout", "9000" });
    defer gpa.free(first.body);
    try testing.expectEqual(client.Status.timeout, first.status);
    try testing.expect(sys.milliTimestamp() - t0 < 6000);
    try testing.expect(std.mem.find(u8, first.body, "wait=failed(awaiting-input)") != null);
    try testing.expect(std.mem.find(u8, first.body, programs.hidden_mode) != null);

    // Once per send: a second wait runs to its timeout.
    const second = try call("pw", &.{ "wait", "--exit", "--timeout", "2600" });
    defer gpa.free(second.body);
    try testing.expect(std.mem.find(u8, second.body, "wait=failed(timeout)") != null);

    var args_buf: [8][]const u8 = undefined;
    const sent = try call("pw", try sendArgs(&args_buf, programs.hidden_keys));
    gpa.free(sent.body);
    const done = try call("pw", &.{ "wait", "--exit", "--timeout", "5000" });
    defer gpa.free(done.body);
    try testing.expectEqual(client.Status.ok, done.status);
    try testing.expect(std.mem.find(u8, done.body, "got:s3cret") != null);

    // A line prompt with echo looks like any quiet program: no early stop.
    try start("line", programs.line_prompt, .{ .cols = 40, .rows = 5 });
    defer kill("line");
    t0 = sys.milliTimestamp();
    const line = try call("line", &.{ "wait", "--exit", "--timeout", "2600" });
    defer gpa.free(line.body);
    try testing.expect(std.mem.find(u8, line.body, "wait=failed(timeout)") != null);
    try testing.expect(sys.milliTimestamp() - t0 >= 2500);
}

test "wait --idle ignores a blinking cursor but not other output" {
    // The programs print escape sequences from sh.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    try testing.expect(std.mem.find(u8, idle.body, "name:") != null);

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
    var path_buf: [256]u8 = undefined;
    const cast = try std.fmt.bufPrint(&path_buf, "{s}" ++ std.fs.path.sep_str ++ "session.cast", .{dir.path});

    try start("rec", programs.echo_line, .{ .cols = 30, .rows = 5, .record_path = cast });
    defer kill("rec");
    const sent = try call("rec", &.{ "send", "hi", "<Enter>" });
    gpa.free(sent.body);
    const waited = try call("rec", &.{ "wait", "--exit" });
    gpa.free(waited.body);
    kill("rec"); // closes the recording

    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, cast, gpa, .limited(1 << 20));
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
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
    try testing.expect(std.mem.find(u8, output.items, "got:hi") != null);
}

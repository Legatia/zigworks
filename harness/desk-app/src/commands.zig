//! The harness commands the app runs, through the binary desk.json names.
const std = @import("std");

const Io = std.Io;
const Environ = std.process.Environ;

pub const Command = enum { run, stop, autostart_on, autostart_off, autostart_query };

/// The command line for `cmd`, always naming the data folder; its strings
/// are copied into `a`.
pub fn argv(a: std.mem.Allocator, cmd: Command, binary: []const u8, home: []const u8) ![]const []const u8 {
    const words: []const []const u8 = switch (cmd) {
        .run => &.{"run"},
        .stop => &.{"stop"},
        .autostart_on => &.{ "autostart", "on" },
        .autostart_off => &.{ "autostart", "off" },
        .autostart_query => &.{"autostart"},
    };
    // copies: the line outlives the controller's copy of desk.json
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, try a.dupe(u8, binary));
    try out.appendSlice(a, words);
    try out.appendSlice(a, &.{ "--home", try a.dupe(u8, home) });
    return out.toOwnedSlice(a);
}

/// `harness autostart`'s answer: its first word, `on` or `off`.
pub fn parseAutostart(out: []const u8) ?bool {
    const trimmed = std.mem.trimStart(u8, out, " \t\r\n");
    const line = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len];
    var end: usize = 0;
    while (end < line.len and std.ascii.isAlphabetic(line[end])) end += 1;
    const word = line[0..end];
    // what follows the word ends it: nothing, a space or punctuation
    if (end < line.len and std.ascii.isAlphanumeric(line[end])) return null;
    if (std.ascii.eqlIgnoreCase(word, "on")) return true;
    if (std.ascii.eqlIgnoreCase(word, "off")) return false;
    return null;
}

/// A copy of `base` with PATH set to `path`.
pub fn withPath(a: std.mem.Allocator, base: *const Environ.Map, path: []const u8) !Environ.Map {
    var env = try base.clone(a);
    errdefer env.deinit();
    try env.put("PATH", path);
    return env;
}

/// Starts `argv` on its own: its input and output on /dev/null (it may
/// outlive the app, whose pipes would close), in a process group of its own.
/// The caller waits for it, so it is reaped. Windows: with a console of its
/// own that has no window (the app has none to share, and a new one would
/// show), so no Ctrl-C of anyone's reaches it; nothing there ends a process
/// with the one that started it.
pub fn spawnDetached(io: Io, args: []const []const u8, env: ?*const Environ.Map) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = args,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (is_windows) null else 0,
        .create_no_window = true,
    });
}

const is_windows = @import("builtin").os.tag == .windows;

pub const Result = struct {
    ok: bool,
    code: ?u8,
    out: []const u8,
    err: []const u8,

    /// One line saying why it failed: the first of its error output, else of
    /// its output, else its exit code.
    pub fn why(r: Result, a: std.mem.Allocator) ![]const u8 {
        for ([_][]const u8{ r.err, r.out }) |text| {
            var lines = std.mem.tokenizeAny(u8, text, "\r\n");
            while (lines.next()) |l| {
                const line = std.mem.trim(u8, l, " \t");
                if (line.len > 0) return line;
            }
        }
        const c = r.code orelse return "It was stopped.";
        return std.fmt.allocPrint(a, "It ended with code {d}.", .{c});
    }
};

/// `runWait` with `input` written to its standard input, which is then
/// closed (the key, for `harness secret add NAME --stdin`). `input` is the
/// caller's to clear; nothing here keeps a copy of it.
pub fn runWithStdin(io: Io, a: std.mem.Allocator, args: []const []const u8, env: ?*const Environ.Map, input: []const u8) !Result {
    var child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);
    {
        // what's written fits the pipe: the child reads it whenever it likes
        var stdin = child.stdin.?;
        child.stdin = null;
        defer stdin.close(io);
        stdin.writeStreamingAll(io, input) catch |e| switch (e) {
            // it ended without reading: what it said is the answer
            error.BrokenPipe => {},
            else => return e,
        };
    }
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } };
    while (reader.fill(64, timeout)) |_| {
        if (reader.reader(0).buffered().len > 64 * 1024 or reader.reader(1).buffered().len > 64 * 1024) return error.StreamTooLong;
    } else |e| switch (e) {
        error.EndOfStream => {},
        else => return e,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    const code: ?u8 = switch (term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .ok = code == 0, .code = code, .out = try reader.toOwnedSlice(0), .err = try reader.toOwnedSlice(1) };
}

/// The line for a command that didn't come to an end: it ran too long, or
/// couldn't be started.
pub fn notRun(a: std.mem.Allocator, binary: []const u8, e: anyerror) ![]const u8 {
    if (e == error.Timeout) return std.fmt.allocPrint(a, "{s} didn't finish within 30 s.", .{binary});
    return std.fmt.allocPrint(a, "{s} couldn't be run ({t}).", .{ binary, e });
}

/// Runs `argv` to its end (at most 30 s), keeping what it printed.
pub fn runWait(io: Io, a: std.mem.Allocator, args: []const []const u8, env: ?*const Environ.Map) !Result {
    const r = try std.process.run(a, io, .{
        .argv = args,
        .environ_map = env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    const code: ?u8 = switch (r.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .ok = code == 0, .code = code, .out = r.stdout, .err = r.stderr };
}

const t = std.testing;

test "argv_per_command" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = [_]struct { Command, []const []const u8 }{
        .{ .run, &.{ "/bin/harness", "run", "--home", "/h" } },
        .{ .stop, &.{ "/bin/harness", "stop", "--home", "/h" } },
        .{ .autostart_on, &.{ "/bin/harness", "autostart", "on", "--home", "/h" } },
        .{ .autostart_off, &.{ "/bin/harness", "autostart", "off", "--home", "/h" } },
        .{ .autostart_query, &.{ "/bin/harness", "autostart", "--home", "/h" } },
    };
    for (want) |w| {
        const got = try argv(a, w[0], "/bin/harness", "/h");
        try t.expectEqual(w[1].len, got.len);
        for (w[1], got) |x, y| try t.expectEqualStrings(x, y);
    }
}

test "argv_copies_its_strings" {
    // the binary's name lives in the controller's copy of desk.json, which
    // is replaced when desk.json changes; the command line outlives that
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const bin = try t.allocator.dupe(u8, "/bin/harness");
    const home = try t.allocator.dupe(u8, "/h");
    const got = try argv(arena.allocator(), .stop, bin, home);
    try t.expect(got[0].ptr != bin.ptr);
    try t.expect(got[got.len - 1].ptr != home.ptr);
    @memset(bin, 'x');
    @memset(home, 'x');
    t.allocator.free(bin);
    t.allocator.free(home);
    try t.expectEqualStrings("/bin/harness", got[0]);
    try t.expectEqualStrings("/h", got[got.len - 1]);
}

test "autostart_output_reads_on_and_off" {
    try t.expectEqual(@as(?bool, true), parseAutostart("on\n"));
    try t.expectEqual(@as(?bool, false), parseAutostart("off"));
    try t.expectEqual(@as(?bool, true), parseAutostart("  On: harness starts at login.\n"));
    try t.expectEqual(@as(?bool, false), parseAutostart("OFF.\nmore"));
    try t.expectEqual(@as(?bool, null), parseAutostart(""));
    try t.expectEqual(@as(?bool, null), parseAutostart("online"));
    try t.expectEqual(@as(?bool, null), parseAutostart("Open at login is on"));
    try t.expectEqual(@as(?bool, null), parseAutostart("usage: harness autostart on|off"));
}

test "path_replaces_only_path" {
    var base: std.process.Environ.Map = .init(t.allocator);
    defer base.deinit();
    try base.put("HOME", "/Users/me");
    try base.put("PATH", "/usr/bin:/bin");
    var env = try withPath(t.allocator, &base, "/opt/homebrew/bin:/usr/bin");
    defer env.deinit();
    try t.expectEqualStrings("/opt/homebrew/bin:/usr/bin", env.get("PATH").?);
    try t.expectEqualStrings("/Users/me", env.get("HOME").?);
    try t.expectEqualStrings("/usr/bin:/bin", base.get("PATH").?);
}

const posix_only = struct {
    extern "c" fn getpgid(pid: std.c.pid_t) std.c.pid_t;
};
const getpgid = posix_only.getpgid;

test "spawn_detached_outlives_its_waiter" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    if (is_windows) {
        // (no process groups to look at: it runs with no window and no
        // pipe of the app's, and writes its file)
        // (the test's folder has no space in it: cmd takes the line bare)
        const line = try std.fmt.allocPrint(a, "ping -n 2 127.0.0.1 >nul & echo ran> {s}\\out", .{dir});
        var child = try spawnDetached(t.io, &.{ "cmd.exe", "/d", "/c", line }, null);
        const term = try child.wait(t.io);
        try t.expect(term == .exited and term.exited == 0);
        const out = try tmp.dir.readFileAlloc(t.io, "out", a, .limited(64));
        try t.expect(std.mem.startsWith(u8, out, "ran"));
        return;
    }
    const script = try std.fmt.allocPrint(a, "sleep 0.2; echo $$ > '{s}/out'", .{dir});
    var child = try spawnDetached(t.io, &.{ "/bin/sh", "-c", script }, null);
    // its own process group: a terminal's hangup or Ctrl-C to the app's
    // group doesn't reach it
    try t.expectEqual(child.id.?, getpgid(child.id.?));
    try t.expect(getpgid(child.id.?) != getpgid(0));
    const term = try child.wait(t.io);
    try t.expect(term == .exited and term.exited == 0);
    const out = try tmp.dir.readFileAlloc(t.io, "out", a, .limited(64));
    try t.expect(out.len > 1);
}

test "run_wait_gives_output_and_status" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (is_windows) {
        // (`echo on` alone switches cmd's echo on and prints nothing)
        const ok = try runWait(t.io, a, &.{ "cmd.exe", "/d", "/c", "echo(on" }, null);
        try t.expect(ok.ok);
        try t.expectEqualStrings("on", std.mem.trim(u8, ok.out, " \r\n"));
        const bad = try runWait(t.io, a, &.{ "cmd.exe", "/d", "/c", "echo nope 1>&2 & exit 3" }, null);
        try t.expect(!bad.ok);
        try t.expectEqualStrings("nope", try bad.why(a));
        const quiet = try runWait(t.io, a, &.{ "cmd.exe", "/d", "/c", "exit 4" }, null);
        try t.expectEqualStrings("It ended with code 4.", try quiet.why(a));
        try t.expectError(error.FileNotFound, runWait(t.io, a, &.{"C:\\no\\such\\harness.exe"}, null));
        return;
    }
    const ok = try runWait(t.io, a, &.{ "/bin/sh", "-c", "echo on" }, null);
    try t.expect(ok.ok);
    try t.expectEqualStrings("on\n", ok.out);
    const bad = try runWait(t.io, a, &.{ "/bin/sh", "-c", "echo nope >&2; exit 3" }, null);
    try t.expect(!bad.ok);
    try t.expectEqualStrings("nope", try bad.why(a));
    const quiet = try runWait(t.io, a, &.{ "/bin/sh", "-c", "exit 4" }, null);
    try t.expectEqualStrings("It ended with code 4.", try quiet.why(a));
    try t.expectError(error.FileNotFound, runWait(t.io, a, &.{"/no/such/harness"}, null));
}

test "run_with_stdin_feeds_and_closes_the_input" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (is_windows) {
        // sort reads to the end of its input: it ends only once that is closed
        const r = try runWithStdin(t.io, a, &.{ "cmd.exe", "/d", "/c", "sort" }, null, "fed-in\n");
        try t.expect(r.ok);
        try t.expectEqualStrings("fed-in", std.mem.trim(u8, r.out, " \r\n"));
        return;
    }
    // cat ends only once its input is closed; no newline at the end
    const r = try runWithStdin(t.io, a, &.{"/bin/cat"}, null, "fed-in");
    try t.expect(r.ok);
    try t.expectEqualStrings("fed-in", r.out);
    const bad = try runWithStdin(t.io, a, &.{ "/bin/sh", "-c", "cat >/dev/null; echo refused >&2; exit 2" }, null, "x");
    try t.expect(!bad.ok);
    try t.expectEqualStrings("refused", try bad.why(a));
    try t.expectError(error.FileNotFound, runWithStdin(t.io, a, &.{"/no/such/harness"}, null, "x"));
}

test "a_command_that_couldnt_finish_says_which_way" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/b/harness didn't finish within 30 s.", try notRun(a, "/b/harness", error.Timeout));
    try t.expectEqualStrings("/b/harness couldn't be run (FileNotFound).", try notRun(a, "/b/harness", error.FileNotFound));
}

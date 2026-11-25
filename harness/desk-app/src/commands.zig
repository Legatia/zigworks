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
/// The caller waits for it, so it is reaped.
pub fn spawnDetached(io: Io, args: []const []const u8, env: ?*const Environ.Map) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = args,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

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

extern "c" fn getpgid(pid: std.c.pid_t) std.c.pid_t;

test "spawn_detached_outlives_its_waiter" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
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

//! Getting in, the app's half: ask the running harness for a one-time code
//! by writing `state/open-request` (no secret in it), wait for harness to
//! write `state/desk-code`, read and delete it, and build the address that
//! trades it for a session cookie.
const std = @import("std");
const Io = std.Io;

/// Asks the running harness for a code: drops a code left from an earlier
/// try (a stale one would only fail), then writes `state/open-request`,
/// readable only by you, holding this program's pid and nothing reusable.
pub fn request(io: Io, home: []const u8) !void {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, try statePath(&buf, home, "desk-code")) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    var f = try cwd.createFile(io, try statePath(&buf, home, "open-request"), .{ .truncate = true, .permissions = .fromMode(0o600) });
    defer f.close(io);
    var line: [32]u8 = undefined;
    try f.writeStreamingAll(io, try std.fmt.bufPrint(&line, "pid {d}\n", .{std.c.getpid()}));
}

/// The code harness wrote, read once: the file is deleted as it's taken.
/// null while there's none, or while it's empty (harness may be halfway
/// through writing it).
pub fn take(io: Io, a: std.mem.Allocator, home: []const u8) !?[]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const p = try statePath(&buf, home, "desk-code");
    const cwd = Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, p, a, .limited(1024)) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.StreamTooLong => {
            // not a code harness wrote
            cwd.deleteFile(io, p) catch {};
            return null;
        },
        else => return e,
    };
    defer a.free(text);
    const code = std.mem.trim(u8, text, " \t\r\n");
    if (code.len == 0) return null;
    cwd.deleteFile(io, p) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    return try a.dupe(u8, code);
}

/// `take`, every `poll_ms`, until a code or `timeout_ms` has passed.
pub fn wait(io: Io, a: std.mem.Allocator, home: []const u8, timeout_ms: u32, poll_ms: u32) !?[]u8 {
    const started = Io.Clock.awake.now(io);
    while (true) {
        if (try take(io, a, home)) |code| return code;
        if (started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() >= timeout_ms) return null;
        io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
    }
}

/// Where the code is traded for the session cookie.
pub fn enterUrl(a: std.mem.Allocator, port: u16, code: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "http://127.0.0.1:{d}/enter?code=", .{port});
    for (code) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try out.append(a, ch),
        else => try out.print(a, "%{X:0>2}", .{ch}),
    };
    return out.toOwnedSlice(a);
}

fn statePath(buf: []u8, home: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}" ++ std.fs.path.sep_str ++ "state" ++ std.fs.path.sep_str ++ "{s}", .{ home, name });
}

const t = std.testing;

fn tmpHome(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.createDirPath(t.io, "state");
    return tmp.dir.realPathFileAlloc(t.io, ".", a);
}

test "request_writes_no_secret_and_drops_a_stale_code" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(a, &tmp);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/desk-code", .data = "old-code-1234" });

    try request(t.io, home);

    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "state/desk-code", .{}));
    const text = try tmp.dir.readFileAlloc(t.io, "state/open-request", a, .limited(1024));
    try t.expect(std.mem.startsWith(u8, text, "pid "));
    try t.expect(std.mem.indexOf(u8, text, "old-code") == null);
    const st = try tmp.dir.statFile(t.io, "state/open-request", .{});
    try t.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);

    // a second request over the first is fine
    try request(t.io, home);
}

test "take_reads_once_and_deletes" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(a, &tmp);

    try t.expect((try take(t.io, a, home)) == null);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/desk-code", .data = "  Xy9-_~code\n" });
    try t.expectEqualStrings("Xy9-_~code", (try take(t.io, a, home)).?);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "state/desk-code", .{}));
    try t.expect((try take(t.io, a, home)) == null);
}

test "an_empty_code_file_is_not_a_code" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(a, &tmp);
    // harness may be halfway through writing it: left for the next look
    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/desk-code", .data = " \n" });
    try t.expect((try take(t.io, a, home)) == null);
    _ = try tmp.dir.statFile(t.io, "state/desk-code", .{});
}

const LateWriter = struct {
    fn run(dir: Io.Dir) void {
        t.io.sleep(.fromMilliseconds(200), .awake) catch {};
        dir.writeFile(t.io, .{ .sub_path = "state/desk-code", .data = "late-code" }) catch {};
    }
};

test "wait_returns_a_code_written_later_and_null_after_the_time" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmpHome(a, &tmp);

    const th = try std.Thread.spawn(.{}, LateWriter.run, .{tmp.dir});
    const code = try wait(t.io, a, home, 5000, 20);
    th.join();
    try t.expectEqualStrings("late-code", code.?);

    const started = Io.Clock.awake.now(t.io);
    try t.expect((try wait(t.io, a, home, 300, 20)) == null);
    const took = started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds();
    try t.expect(took >= 280 and took < 2000);
}

test "enter_url_encodes_the_code" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("http://127.0.0.1:41234/enter?code=abc-DEF_1.2~", try enterUrl(a, 41234, "abc-DEF_1.2~"));
    try t.expectEqualStrings("http://127.0.0.1:8080/enter?code=a%2Bb%2F%3D%26x%20y", try enterUrl(a, 8080, "a+b/=&x y"));
}

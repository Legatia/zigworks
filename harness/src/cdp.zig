//! A headless Chrome driven over the DevTools protocol through a pipe
//! (`--remote-debugging-pipe`: Chrome reads commands on fd 3 and writes
//! replies on fd 4), never a network port. Each message is JSON followed
//! by one NUL byte, both ways. POSIX only for now.
const std = @import("std");
const builtin = @import("builtin");
const jv = @import("jv.zig");
const util = @import("util.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const is_windows = builtin.os.tag == .windows;

/// Replies by id; events are dropped (nothing here waits for one).
pub const Inbox = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    replies: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Bytes of a message not yet ended by its NUL.
    partial: std.ArrayList(u8) = .empty,
    /// The pipe closed: Chrome is gone.
    closed: std.atomic.Value(bool) = .init(false),

    pub fn deinit(b: *Inbox) void {
        var it = b.replies.valueIterator();
        while (it.next()) |v| b.gpa.free(v.*);
        b.replies.deinit(b.gpa);
        b.partial.deinit(b.gpa);
    }

    /// Splits `bytes` into messages and keeps the replies among them.
    pub fn feed(b: *Inbox, io: Io, bytes: []const u8) void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, 0)) |end| {
            if (b.partial.items.len > 0) {
                b.partial.appendSlice(b.gpa, rest[0..end]) catch {};
                b.keep(io, b.partial.items);
                b.partial.clearRetainingCapacity();
            } else b.keep(io, rest[0..end]);
            rest = rest[end + 1 ..];
        }
        b.partial.appendSlice(b.gpa, rest) catch {};
    }

    fn keep(b: *Inbox, io: Io, msg: []const u8) void {
        const id = replyId(msg) orelse return;
        const copy = b.gpa.dupe(u8, msg) catch return;
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        const old = b.replies.fetchPut(b.gpa, id, copy) catch {
            b.gpa.free(copy);
            return;
        };
        if (old) |kv| b.gpa.free(kv.value);
    }

    /// The reply with `id`, if it came; the caller frees it.
    pub fn take(b: *Inbox, io: Io, id: u32) ?[]u8 {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        const kv = b.replies.fetchRemove(id) orelse return null;
        return kv.value;
    }
};

/// Chrome writes the id first (`{"id":5,...}`); an event has none.
fn replyId(msg: []const u8) ?u32 {
    const mark = "{\"id\":";
    if (!std.mem.startsWith(u8, msg, mark)) return null;
    var i: usize = mark.len;
    var n: u32 = 0;
    while (i < msg.len and std.ascii.isDigit(msg[i])) : (i += 1) n = n *% 10 +% (msg[i] - '0');
    if (i == mark.len) return null;
    return n;
}

pub const Error = error{ Cdp, Script, Timeout, Stopped, BrowserGone, Unsupported, NoPage };

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    stop: *std.atomic.Value(bool),
    /// How long one call may take.
    timeout_ms: u32,
    pid: std.posix.pid_t = 0,
    child: std.process.Child = undefined,
    to_chrome: ?Io.File = null,
    from_chrome: ?Io.File = null,
    reader: ?std.Thread = null,
    inbox: Inbox,
    next_id: u32 = 1,
    write_mutex: Io.Mutex = .init,
    /// The page's session id (flat mode).
    page_session: []u8 = &.{},
    ended: std.atomic.Value(bool) = .init(false),
    closed: bool = false,
    /// The message of the last `error.Cdp` or `error.Script`.
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,

    pub fn lastError(s: *const Session) []const u8 {
        return s.err_buf[0..s.err_len];
    }

    fn setError(s: *Session, msg: []const u8) void {
        const m = util.cut(msg, s.err_buf.len);
        @memcpy(s.err_buf[0..m.len], m);
        s.err_len = m.len;
    }

    /// Starts `browser` with `profile_dir` and attaches to its page.
    pub fn open(gpa: Allocator, io: Io, browser: []const u8, profile_dir: []const u8, stop: *std.atomic.Value(bool), timeout_ms: u32) !*Session {
        if (is_windows) return error.Unsupported else return openPosix(gpa, io, browser, profile_dir, stop, timeout_ms);
    }

    fn openPosix(gpa: Allocator, io: Io, browser: []const u8, profile_dir: []const u8, stop: *std.atomic.Value(bool), timeout_ms: u32) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .stop = stop, .timeout_ms = timeout_ms, .inbox = .{ .gpa = gpa } };
        const data_dir = try std.fmt.allocPrint(gpa, "--user-data-dir={s}", .{profile_dir});
        defer gpa.free(data_dir);
        // our stdin pipe becomes Chrome's fd 3, our stdout pipe its fd 4
        const argv: []const []const u8 = &.{
            "/bin/sh",
            "-c",
            "exec \"$@\" 3<&0 4>&1 0</dev/null 1>/dev/null",
            "sh",
            browser,
            "--headless=new",
            "--disable-gpu",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--mute-audio",
            "--remote-debugging-pipe",
            data_dir,
            "about:blank",
        };
        s.child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        s.pid = s.child.id.?;
        // the pipes are ours: `wait` must not close them under the reader
        s.to_chrome = s.child.stdin;
        s.from_chrome = s.child.stdout;
        s.child.stdin = null;
        s.child.stdout = null;
        s.reader = std.Thread.spawn(.{}, readLoop, .{s}) catch |e| {
            s.close();
            return e;
        };
        s.attach() catch |e| {
            s.close();
            return e;
        };
        return s;
    }

    fn attach(s: *Session) !void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // the first page may take a moment to appear
        const until = deadline(s.io, s.timeout_ms);
        const target = outer: while (true) {
            const res = try s.callIn(a, "Target.getTargets", "{}", null);
            if (jv.arr(jv.get(res, "targetInfos"))) |infos| for (infos) |info| {
                if (!std.mem.eql(u8, jv.str(jv.get(info, "type")) orelse "", "page")) continue;
                if (jv.str(jv.get(info, "targetId"))) |id| break :outer id;
            };
            if (Io.Clock.awake.now(s.io).nanoseconds >= until) return error.NoPage;
            s.io.sleep(.fromMilliseconds(50), .awake) catch {};
        };
        var p: std.ArrayList(u8) = .empty;
        try p.appendSlice(a, "{\"targetId\":");
        try util.jsonString(&p, a, target);
        try p.appendSlice(a, ",\"flatten\":true}");
        const res = try s.callIn(a, "Target.attachToTarget", p.items, null);
        const sid = jv.str(jv.get(res, "sessionId")) orelse return error.NoPage;
        s.page_session = try s.gpa.dupe(u8, sid);
        _ = try s.call(a, "Page.enable", "{}");
        _ = try s.call(a, "Runtime.enable", "{}");
    }

    fn readLoop(s: *Session) void {
        const f = s.from_chrome.?;
        var buf: [64 * 1024]u8 = undefined;
        while (!s.ended.load(.acquire)) {
            // a stop ends the browser at once, whatever is waiting on it
            if (s.stop.load(.acquire)) s.killGroup();
            var fds = [_]std.posix.pollfd{.{ .fd = f.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 50) catch break;
            if (ready == 0) continue;
            const got = f.readStreaming(s.io, &.{&buf}) catch break;
            if (got == 0) break;
            s.inbox.feed(s.io, buf[0..got]);
        }
        s.inbox.closed.store(true, .release);
    }

    fn killGroup(s: *Session) void {
        if (is_windows or s.pid == 0) return;
        std.posix.kill(-s.pid, .KILL) catch {};
        std.posix.kill(s.pid, .KILL) catch {};
    }

    /// A method on the page; returns its `result`.
    pub fn call(s: *Session, arena: Allocator, method: []const u8, params_json: []const u8) !jv.Value {
        return s.callIn(arena, method, params_json, s.page_session);
    }

    /// A method on the browser (`sid` null) or a session; returns its
    /// `result`. A reply with `error` is error.Cdp (see lastError).
    pub fn callIn(s: *Session, arena: Allocator, method: []const u8, params_json: []const u8, sid: ?[]const u8) !jv.Value {
        if (s.stop.load(.acquire)) return error.Stopped;
        if (s.inbox.closed.load(.acquire) or s.closed) return error.BrowserGone;
        const id = s.next_id;
        s.next_id += 1;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(s.gpa);
        try msg.print(s.gpa, "{{\"id\":{d},\"method\":", .{id});
        try util.jsonString(&msg, s.gpa, method);
        try msg.appendSlice(s.gpa, ",\"params\":");
        try msg.appendSlice(s.gpa, params_json);
        if (sid) |x| if (x.len > 0) {
            try msg.appendSlice(s.gpa, ",\"sessionId\":");
            try util.jsonString(&msg, s.gpa, x);
        };
        try msg.appendSlice(s.gpa, "}\x00");
        {
            s.write_mutex.lockUncancelable(s.io);
            defer s.write_mutex.unlock(s.io);
            s.to_chrome.?.writeStreamingAll(s.io, msg.items) catch return error.BrowserGone;
        }
        const until = deadline(s.io, s.timeout_ms);
        while (true) {
            if (s.inbox.take(s.io, id)) |reply| {
                defer s.gpa.free(reply);
                const v = jv.parse(arena, reply) orelse return error.Cdp;
                if (jv.get(v, "error")) |e| {
                    s.setError(jv.str(jv.get(e, "message")) orelse "error");
                    return error.Cdp;
                }
                return jv.get(v, "result") orelse .{ .object = .empty };
            }
            if (s.stop.load(.acquire)) return error.Stopped;
            if (s.inbox.closed.load(.acquire)) return error.BrowserGone;
            if (Io.Clock.awake.now(s.io).nanoseconds >= until) return error.Timeout;
            s.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
    }

    /// Runs `expr` in the page and returns its value as JSON; an exception
    /// is error.Script.
    pub fn evaluate(s: *Session, arena: Allocator, expr: []const u8) ![]const u8 {
        var p: std.ArrayList(u8) = .empty;
        try p.appendSlice(arena, "{\"expression\":");
        try util.jsonString(&p, arena, expr);
        try p.appendSlice(arena, ",\"returnByValue\":true,\"awaitPromise\":true}");
        const res = try s.call(arena, "Runtime.evaluate", p.items);
        if (jv.get(res, "exceptionDetails")) |ex| {
            const text = jv.str(jv.at(ex, &.{ "exception", "description" })) orelse jv.str(jv.get(ex, "text")) orelse "exception";
            s.setError(text);
            return error.Script;
        }
        const v = jv.at(res, &.{ "result", "value" }) orelse return "null";
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(v, .{})});
    }

    /// Loads `url` and waits until the new document has loaded.
    pub fn navigate(s: *Session, arena: Allocator, url: []const u8) !void {
        // a mark on the old document: gone once the new one is there
        _ = s.evaluate(arena, "window.__hxOld = true") catch {};
        var p: std.ArrayList(u8) = .empty;
        try p.appendSlice(arena, "{\"url\":");
        try util.jsonString(&p, arena, url);
        try p.append(arena, '}');
        const res = try s.call(arena, "Page.navigate", p.items);
        if (jv.str(jv.get(res, "errorText"))) |why| if (why.len > 0) {
            s.setError(why);
            return error.Cdp;
        };
        try s.waitFor(arena, "window.__hxOld !== true && document.readyState === 'complete'");
        try s.settle(arena);
    }

    /// After something that may have started a navigation (a click, Enter):
    /// waits until the document, old or new, has loaded and stayed so.
    pub fn settle(s: *Session, arena: Allocator) !void {
        try s.sleep(300);
        try s.waitFor(arena, "document.readyState === 'complete'");
    }

    fn sleep(s: *Session, ms: u32) !void {
        const until = deadline(s.io, ms);
        while (Io.Clock.awake.now(s.io).nanoseconds < until) {
            if (s.stop.load(.acquire)) return error.Stopped;
            s.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }

    /// Polls `cond` every 50 ms until it is true; a script that fails
    /// while the document is replaced is tried again.
    fn waitFor(s: *Session, arena: Allocator, cond: []const u8) !void {
        const until = deadline(s.io, s.timeout_ms);
        while (true) {
            const v = s.evaluate(arena, cond) catch |e| switch (e) {
                error.Script, error.Cdp, error.Timeout => "false",
                else => return e,
            };
            if (std.mem.eql(u8, v, "true")) return;
            if (Io.Clock.awake.now(s.io).nanoseconds >= until) return error.Timeout;
            try s.sleep(50);
        }
    }

    /// Ends the browser and everything it started; safe to call twice.
    pub fn close(s: *Session) void {
        if (s.closed) return;
        if (!is_windows) {
            if (s.page_session.len > 0 and !s.inbox.closed.load(.acquire) and !s.stop.load(.acquire)) {
                var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
                defer arena_state.deinit();
                const saved = s.timeout_ms;
                s.timeout_ms = 1000;
                _ = s.callIn(arena_state.allocator(), "Browser.close", "{}", null) catch {};
                s.timeout_ms = saved;
            }
            s.closed = true;
            s.killGroup();
            if (s.child.id != null) _ = s.child.wait(s.io) catch {};
            // its helpers too, should one have kept the group alive
            std.posix.kill(-s.pid, .KILL) catch {};
            s.ended.store(true, .release);
            if (s.reader) |th| th.join();
            if (s.to_chrome) |f| f.close(s.io);
            if (s.from_chrome) |f| f.close(s.io);
        }
        s.closed = true;
    }

    /// Closes and frees.
    pub fn destroy(s: *Session) void {
        s.close();
        s.inbox.deinit();
        if (s.page_session.len > 0) s.gpa.free(s.page_session);
        s.gpa.destroy(s);
    }
};

fn deadline(io: Io, ms: u32) i96 {
    return Io.Clock.awake.now(io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
}

// ---- tests ----

const t = std.testing;

test "messages_are_split_at_nul_and_events_skipped" {
    var b: Inbox = .{ .gpa = t.allocator };
    defer b.deinit();
    b.feed(t.io, "{\"id\":1,\"result\":{}}\x00{\"method\":\"Page.loadEventFired\",\"params\":{}}\x00{\"id\":2,\"res");
    const one = b.take(t.io, 1).?;
    defer t.allocator.free(one);
    try t.expectEqualStrings("{\"id\":1,\"result\":{}}", one);
    try t.expectEqual(null, b.take(t.io, 2));
    b.feed(t.io, "ult\":{\"x\":\"a\\u0000b\"}}");
    try t.expectEqual(null, b.take(t.io, 2));
    b.feed(t.io, "\x00{\"method\":\"Runtime.consoleAPICalled\"}\x00");
    const two = b.take(t.io, 2).?;
    defer t.allocator.free(two);
    try t.expectEqualStrings("{\"id\":2,\"result\":{\"x\":\"a\\u0000b\"}}", two);
    // the events were never kept
    try t.expectEqual(0, b.replies.count());
    try t.expectEqual(0, b.partial.items.len);
}

/// Chrome, for the tests that need one; null skips them.
pub fn testBrowser(a: Allocator) !?[]const u8 {
    if (is_windows) return null;
    const page = @import("page.zig");
    const env_chrome: []const u8 = if (t.environ.getPosix("HARNESS_CHROME")) |v| v else "";
    const env_path: []const u8 = if (t.environ.getPosix("PATH")) |v| v else "";
    return page.findBrowser(a, t.io, "", env_chrome, env_path);
}

fn processGone(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch return true;
    return false;
}

test "chrome_over_a_pipe_evaluates_and_closes_without_leftovers" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const browser = (try testBrowser(a)) orelse return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    const s = try Session.open(t.allocator, t.io, browser, profile, &stop, 20_000);
    const pid = s.pid;
    try t.expectEqualStrings("2", try s.evaluate(a, "1+1"));
    try t.expectEqualStrings("\"ab\"", try s.evaluate(a, "Promise.resolve('a' + 'b')"));
    try t.expectError(error.Script, s.evaluate(a, "no_such_name.x"));
    try t.expectError(error.Cdp, s.call(a, "No.suchMethod", "{}"));
    s.destroy();
    try t.expect(processGone(pid));
    // nothing of its group is left either (helpers die a moment later)
    var waited: u32 = 0;
    while (waited < 3000 and !processGone(-pid)) : (waited += 50) t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    try t.expect(processGone(-pid));
}

test "a_stop_ends_chrome_at_once" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const browser = (try testBrowser(a)) orelse return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    const s = try Session.open(t.allocator, t.io, browser, profile, &stop, 20_000);
    defer s.destroy();
    const th = try std.Thread.spawn(.{}, struct {
        fn f(flag: *std.atomic.Value(bool)) void {
            t.io.sleep(.fromMilliseconds(300), .awake) catch {};
            flag.store(true, .release);
        }
    }.f, .{&stop});
    defer th.join();
    const start = Io.Clock.awake.now(t.io).nanoseconds;
    try t.expectError(error.Stopped, s.evaluate(a, "new Promise(() => {})"));
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - start < 3 * std.time.ns_per_s);
    var waited: u32 = 0;
    while (waited < 3000 and !processGone(s.pid)) : (waited += 50) t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    // killed but not yet reaped is a zombie: kill(pid, 0) still succeeds,
    // so look at whether the pipe closed instead
    while (waited < 3000 and !s.inbox.closed.load(.acquire)) : (waited += 50) t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    try t.expect(s.inbox.closed.load(.acquire));
}

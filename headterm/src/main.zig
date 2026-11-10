const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const client = @import("client.zig");
const server = @import("server.zig");
const mcp = @import("mcp.zig");
const run_mod = @import("run.zig");

const usage_text =
    \\usage: headterm <command> [arguments]
    \\
    \\  run <steps> -- <cmd> [args...]              start, send, wait, print, end: one command
    \\  start <name> [options] -- <cmd> [args...]   start a program in a new session
    \\  screen <name> [options]                     print the screen
    \\  send <name> [options] <keys>...             send keys and text
    \\  wait <name> <conditions> [options]          wait for text, a regex, idle or exit
    \\  resize <name> <cols> <rows>                 resize the terminal
    \\  kill <name>                                 end a session
    \\  list [--json]                               list sessions
    \\  mcp                                         run the MCP server on stdin/stdout
    \\  help [command], version
    \\
    \\Run 'headterm help <command>' for its options.
    \\Exit codes: 0 ok, 1 wait not satisfied, 2 error.
    \\
;

const Help = struct { []const u8, []const u8 };
const command_help = [_]Help{
    .{
        "run",
        \\usage: headterm run [options] <steps> -- <cmd> [args...]
        \\       headterm run --session NAME [options] <steps>
        \\
        \\Starts <cmd>, plays the steps in order, prints each step's result and the
        \\final screen, then ends the session. If a step fails it stops, prints the
        \\screen at that point and keeps the session (10 min TTL) to recover.
        \\Exit code 1 if a step failed.
        \\
        \\To go step by step, keep the session and continue it:
        \\  headterm run --name NAME --keep --screen -- <cmd>
        \\  headterm run --session NAME --send Down Enter --screen
        \\It stays until its program exits, 'headterm kill NAME', or an hour
        \\without use (--ttl S, 0 = never).
        \\
        \\steps, in order:
        \\  --send KEY...     keys or text (consecutive --send form one step)
        \\  --send-text TEXT  plain text, no <Key> parsing
        \\  --screen          print the screen. It first waits for the program's
        \\                    first output, or for its reaction to the keys just
        \\                    sent, so no wait step is needed before it
        \\  --wait-text STR   --wait-regex RE   --wait-gone STR   --wait-idle MS
        \\  --wait-exit       --timeout MS (for the wait just before it)
        \\  --steps JSON      [{"send":[...]},{"wait":{"text":"..."}},{"screen":true}]
        \\
        \\keys: Enter Tab Esc Space Backspace Up Down Left Right Home End PageUp
        \\      PageDown Delete F1..F12, C-c (Ctrl), M-x (Alt), S-Tab (Shift);
        \\      any other argument is typed as text
        \\
        \\options: --name NAME --keep --cols N --rows N --cwd DIR --ttl S
        \\         --record FILE --styles
        \\
        \\example: headterm run --send billing Enter --wait-text Framework \
        \\             --send Down Enter --wait-exit -- npm create my-app
        \\
        \\Keys before the first wait are sent once the program's first output
        \\settles.
        \\
    },
    .{
        "start",
        \\usage: headterm start <name> [options] -- <cmd> [args...]
        \\
        \\Starts <cmd> in a pseudo-terminal held by a background session server and
        \\returns once it is running. <name>: letters, digits, '.', '_', '-'.
        \\
        \\  --cols N        width (default 120)
        \\  --rows N        height (default 40)
        \\  --cwd DIR       working directory
        \\  --ttl S         end the session after S seconds without requests or output
        \\  --record FILE   write an asciicast v2 recording (asciinema play FILE)
        \\  --log FILE      append the raw program output to FILE
        \\
    },
    .{
        "screen",
        \\usage: headterm screen <name> [options]
        \\
        \\Prints the screen, one line per row, then a status line with size,
        \\cursor (0-based row,col), alt screen and exit status.
        \\
        \\  --json           JSON output
        \\  --diff           only rows changed since this client's last screen/wait
        \\  --styles         also list styled runs (inverse, bold, colors) per row
        \\  --trim           leave out empty rows at the bottom
        \\  --scrollback N   also print up to N lines that scrolled off the top
        \\  --client ID      use the diff marker ID instead of the shared one
        \\
    },
    .{
        "send",
        \\usage: headterm send <name> [options] [--] <keys>...
        \\
        \\Each argument is text or a key:
        \\  <Enter> <Tab> <Esc> <Backspace> <Space> <Up> <Down> <Left> <Right>
        \\  <Home> <End> <PageUp> <PageDown> <Insert> <Delete> <F1>..<F12> <lt>
        \\  modifiers: <C-c> (Ctrl), <M-x> (Alt), <S-Tab> (Shift), combinable
        \\  an argument spelled like a key also works: Enter, Down, C-c
        \\  down, enter: also keys, unless the same send has a key spelled as above
        \\  (then they are text, as in 'send up Enter' to a debugger)
        \\Mouse, if the program enabled mouse reporting (0-based positions):
        \\  <Click r,c> <RightClick r,c> <MiddleClick r,c> <Drag r1,c1 r2,c2>
        \\  <ScrollUp r,c> <ScrollDown r,c>, with modifiers: <S-Click r,c>
        \\
        \\  --literal        send the following arguments as plain text
        \\  --paste          send them as one bracketed paste
        \\  --esc-delay MS   pause after a lone <Esc> (default 100, 0 = none)
        \\  --               end of options
        \\
    },
    .{
        "wait",
        \\usage: headterm wait <name> <conditions> [options]
        \\
        \\Waits until one of the conditions holds, then prints the screen.
        \\Exit code 1 if none did before the timeout.
        \\
        \\  --text STR        STR is on screen (rows joined where text wrapped)
        \\  --regex RE        a screen line matches RE (see the README for syntax)
        \\  --text-gone STR   STR is not on screen
        \\  --idle MS         the screen has not changed for MS milliseconds (a
        \\                    cursor that the program blinks itself is ignored)
        \\  --settle MS       the program printed something (after the last send, if
        \\                    any; it gets 500 ms to react), then nothing for MS
        \\  --exit            the program exited (alone, it fails after 2 s when the
        \\                    program went quiet in raw mode or with echo off:
        \\                    it is waiting for input)
        \\  --timeout MS      give up after MS (default 10000)
        \\
        \\Output options as for screen: --json --diff --styles --trim
        \\--scrollback N --client ID
        \\
    },
    .{
        "resize",
        \\usage: headterm resize <name> <cols> <rows>
        \\
        \\Resizes the terminal (2..1000 columns, 1..1000 rows); the program gets
        \\SIGWINCH.
        \\
    },
    .{
        "kill",
        \\usage: headterm kill <name>
        \\
        \\Hangs up the program (SIGHUP, then SIGTERM, then SIGKILL) and removes the
        \\session.
        \\
    },
    .{
        "list",
        \\usage: headterm list [--json]
        \\
        \\Lists sessions: name, pid, size, status, command.
        \\
    },
    .{
        "mcp",
        \\usage: headterm mcp
        \\
        \\Runs an MCP server on stdin/stdout (JSON-RPC, one message per line).
        \\Register it with: claude mcp add headterm -- /path/to/headterm mcp
        \\
    },
};

fn helpFor(cmd: []const u8) ?[]const u8 {
    for (command_help) |h| {
        if (eql(h[0], cmd)) return h[1];
    }
    return null;
}

fn isHelpFlag(a: []const u8) bool {
    return eql(a, "--help") or eql(a, "-h");
}

pub fn main() u8 {
    const gpa = std.heap.c_allocator;
    const args = std.process.argsAlloc(gpa) catch return fail("out of memory", .{});
    defer std.process.argsFree(gpa, args);
    return run(gpa, args[1..]) catch |err| fail("{s}", .{@errorName(err)});
}

fn run(gpa: Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try writeStderr(usage_text);
        return 2;
    }
    const cmd = args[0];
    if (eql(cmd, "help") or isHelpFlag(cmd)) {
        if (args.len > 1) {
            const text = helpFor(args[1]) orelse return fail("help: no command '{s}' (commands: run start screen send wait resize kill list mcp)", .{args[1]});
            try writeStdout(text);
        } else {
            try writeStdout(usage_text);
        }
        return 0;
    }
    if (args.len > 1 and isHelpFlag(args[1])) {
        if (helpFor(cmd)) |text| {
            try writeStdout(text);
            return 0;
        }
    }
    if (eql(cmd, "version") or eql(cmd, "--version")) {
        try writeStdout("headterm " ++ server.version ++ "\n");
        return 0;
    }

    if (eql(cmd, "list")) return list(gpa, args[1..]);
    if (eql(cmd, "run")) return runCmd(gpa, args[1..]);
    if (eql(cmd, "mcp")) {
        if (args.len > 1) return fail("mcp: takes no arguments (got '{s}')", .{args[1]});
        try mcp.serve(gpa);
        return 0;
    }

    const known = [_][]const u8{ "start", "screen", "send", "wait", "resize", "kill" };
    for (known) |k| {
        if (eql(cmd, k)) break;
    } else return fail("unknown command '{s}' (see 'headterm help')", .{cmd});

    if (args.len < 2) return fail("{s}: missing session name (see 'headterm help {s}')", .{ cmd, cmd });
    // `start --name NAME` is accepted too, as `run` spells it that way.
    if (eql(cmd, "start") and eql(args[1], "--name") and args.len > 2) {
        if (!client.validName(args[2])) return fail("invalid session name '{s}': use 1-64 letters, digits, '.', '_' or '-', not starting with '.' or '-'", .{args[2]});
        return start(gpa, args[2], args[3..]);
    }
    const name = args[1];
    if (!client.validName(name)) return fail("invalid session name '{s}': use 1-64 letters, digits, '.', '_' or '-', not starting with '.' or '-'", .{name});
    if (eql(cmd, "start")) return start(gpa, name, args[2..]);

    // Everything else is forwarded to the session server as-is.
    var fwd: std.ArrayList([]const u8) = .empty;
    defer fwd.deinit(gpa);
    try fwd.append(gpa, cmd);
    try fwd.appendSlice(gpa, args[2..]);
    const resp = client.call(gpa, name, fwd.items) catch |err| {
        var buf: [256]u8 = undefined;
        return fail("{s} (see 'headterm list')", .{client.describeError(&buf, err, name)});
    };
    defer gpa.free(resp.body);
    switch (resp.status) {
        .ok => {
            try writeStdout(resp.body);
            return 0;
        },
        .timeout => {
            try writeStdout(resp.body);
            return 1;
        },
        .@"error" => {
            try writeStderr("headterm: ");
            try writeStderr(resp.body);
            return 2;
        },
    }
}

fn runCmd(gpa: Allocator, args: []const []const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts: run_mod.Options = .{ .name = "", .argv = &.{} };
    var name: ?[]const u8 = null;
    var existing: ?[]const u8 = null;
    var ttl_given = false;
    var steps: std.ArrayList(run_mod.Step) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--")) {
            i += 1;
            break;
        }
        if (isHelpFlag(a)) {
            try writeStdout(helpFor("run").?);
            return 0;
        }
        if (eql(a, "--keep")) {
            opts.keep = true;
            continue;
        }
        if (eql(a, "--styles")) {
            opts.styles = true;
            continue;
        }
        if (eql(a, "--wait-exit")) {
            try steps.append(arena, .{ .wait = .{ .exit = true } });
            continue;
        }
        if (eql(a, "--screen")) {
            try steps.append(arena, .screen);
            continue;
        }
        if (i + 1 >= args.len) return fail("run: {s} needs a value (see 'headterm help run')", .{a});
        const v = args[i + 1];
        i += 1;
        if (eql(a, "--send")) {
            // Consecutive --send arguments form one step.
            // `--send KEY KEY ...` takes keys up to the next option or `--`.
            var more = i + 1;
            while (more < args.len and !std.mem.startsWith(u8, args[more], "--")) more += 1;
            const new = args[i..more];
            i = more - 1;
            const last = if (steps.items.len > 0) &steps.items[steps.items.len - 1] else null;
            if (last != null and last.?.* == .send and !last.?.send.literal) {
                const old = last.?.send.keys;
                const keys = try arena.alloc([]const u8, old.len + new.len);
                @memcpy(keys[0..old.len], old);
                @memcpy(keys[old.len..], new);
                last.?.send.keys = keys;
            } else {
                try steps.append(arena, .{ .send = .{ .keys = try arena.dupe([]const u8, new) } });
            }
        } else if (eql(a, "--send-text")) {
            try steps.append(arena, .{ .send = .{ .keys = try arena.dupe([]const u8, &.{v}), .literal = true } });
        } else if (eql(a, "--wait-text")) {
            try steps.append(arena, .{ .wait = .{ .text = v } });
        } else if (eql(a, "--wait-regex")) {
            try steps.append(arena, .{ .wait = .{ .regex = v } });
        } else if (eql(a, "--wait-gone")) {
            try steps.append(arena, .{ .wait = .{ .gone = v } });
        } else if (eql(a, "--wait-idle")) {
            const ms = std.fmt.parseInt(i64, v, 10) catch return fail("run: --wait-idle needs milliseconds, got '{s}'", .{v});
            try steps.append(arena, .{ .wait = .{ .idle_ms = ms } });
        } else if (eql(a, "--timeout")) {
            const ms = std.fmt.parseInt(i64, v, 10) catch return fail("run: --timeout needs milliseconds, got '{s}'", .{v});
            if (steps.items.len == 0 or steps.items[steps.items.len - 1] != .wait) return fail("run: --timeout must follow a --wait-* step", .{});
            steps.items[steps.items.len - 1].wait.timeout_ms = ms;
        } else if (eql(a, "--steps")) {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, v, .{}) catch return fail("run: --steps is not valid JSON", .{});
            var msg: []const u8 = "";
            const parsed = run_mod.parseSteps(arena, value, &msg) catch |err| switch (err) {
                error.InvalidSteps => return fail("run: {s}", .{msg}),
                else => |e| return e,
            };
            try steps.appendSlice(arena, parsed);
        } else if (eql(a, "--name")) {
            name = v;
        } else if (eql(a, "--session")) {
            existing = v;
        } else if (eql(a, "--cols")) {
            opts.start.cols = std.fmt.parseInt(u16, v, 10) catch return fail("run: bad --cols '{s}'", .{v});
        } else if (eql(a, "--rows")) {
            opts.start.rows = std.fmt.parseInt(u16, v, 10) catch return fail("run: bad --rows '{s}'", .{v});
        } else if (eql(a, "--cwd")) {
            opts.start.cwd = v;
        } else if (eql(a, "--record")) {
            opts.start.record_path = v;
        } else if (eql(a, "--ttl")) {
            const ttl = std.fmt.parseInt(u32, v, 10) catch return fail("run: bad --ttl '{s}' (seconds)", .{v});
            opts.start.ttl_s = if (ttl == 0) null else ttl;
            ttl_given = true;
        } else {
            return fail("run: unknown option '{s}' (see 'headterm help run')", .{a});
        }
    }
    opts.argv = args[i..];
    if (existing != null and opts.argv.len > 0) return fail("run: give either --session NAME or -- <cmd>, not both", .{});
    if (existing == null and opts.argv.len == 0) return fail("run: missing command, e.g. 'headterm run --send q -- less FILE' (or --session NAME)", .{});
    if (steps.items.len == 0) return fail("run: give at least one step (--send, --wait-*, --screen or --steps)", .{});
    // Without --keep the session ends after the run; if a step fails it is
    // kept for recovery and expires. A kept session expires too, later, so
    // one that is forgotten doesn't run forever.
    if (!ttl_given) opts.start.ttl_s = if (opts.keep) run_mod.keep_ttl_s else run_mod.failure_ttl_s;
    opts.name = existing orelse name orelse try std.fmt.allocPrint(arena, "run-{d}", .{std.c.getpid()});
    if (!client.validName(opts.name)) return fail("run: invalid session name '{s}'", .{opts.name});

    var call_arena = arena;
    const caller: run_mod.Caller = .{ .ctx = @ptrCast(&call_arena), .callFn = cliCall };
    const result = run_mod.run(arena, gpa, opts, steps.items, caller) catch |err| return fail("run: {s}", .{@errorName(err)});
    try writeStdout(result.text);
    try writeStdout("\n");
    return if (result.ok) 0 else 1;
}

fn cliCall(ctx: *anyopaque, name: []const u8, args: []const []const u8) run_mod.Error!client.Response {
    const arena: *Allocator = @ptrCast(@alignCast(ctx));
    return client.call(arena.*, name, args);
}

fn start(gpa: Allocator, name: []const u8, args: []const []const u8) !u8 {
    var opts: client.StartOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, a, "--")) break;
        if (i + 1 >= args.len) return fail("start: {s} needs a value (see 'headterm help start')", .{a});
        const v = args[i + 1];
        i += 1;
        if (eql(a, "--cols")) {
            opts.cols = std.fmt.parseInt(u16, v, 10) catch return fail("start: bad --cols '{s}'", .{v});
        } else if (eql(a, "--rows")) {
            opts.rows = std.fmt.parseInt(u16, v, 10) catch return fail("start: bad --rows '{s}'", .{v});
        } else if (eql(a, "--cwd")) {
            opts.cwd = v;
        } else if (eql(a, "--log")) {
            opts.log_path = v;
        } else if (eql(a, "--record")) {
            opts.record_path = v;
        } else if (eql(a, "--ttl")) {
            const ttl = std.fmt.parseInt(u32, v, 10) catch return fail("start: bad --ttl '{s}' (seconds)", .{v});
            opts.ttl_s = if (ttl == 0) null else ttl;
        } else {
            return fail("start: unknown option '{s}' (see 'headterm help start')", .{a});
        }
    }
    const argv = args[i..];
    if (argv.len == 0) return fail("start: missing command, e.g. 'headterm start {s} -- python3'", .{name});

    var msg: [256]u8 = undefined;
    const pid = client.startSession(gpa, name, argv, opts, &msg) catch
        return fail("start: {s}", .{std.mem.sliceTo(&msg, 0)});
    var buf: [128]u8 = undefined;
    try writeStdout(try std.fmt.bufPrint(&buf, "started {s} pid={d}\n", .{ name, pid }));
    return 0;
}

fn list(gpa: Allocator, args: []const []const u8) !u8 {
    var json = false;
    for (args) |a| {
        if (eql(a, "--json")) json = true else return fail("list: unknown option '{s}' (only --json)", .{a});
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = try client.listSessions(arena_state.allocator());

    var out_buf: [4096]u8 = undefined;
    // Streaming, not the default positional mode: with stdout redirected to
    // a file, positional writes would start at offset 0 and clobber it.
    var fw = std.fs.File.stdout().writerStreaming(&out_buf);
    const out = &fw.interface;
    if (json) {
        try out.writeByte('[');
        for (sessions.raw, 0..) |r, i| {
            if (i > 0) try out.writeByte(',');
            try out.writeAll(r);
        }
        try out.writeAll("]\n");
    } else {
        try client.writeSessionTable(out, sessions.infos);
    }
    try out.flush();
    return 0;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeStdout(bytes: []const u8) !void {
    try std.fs.File.stdout().writeAll(bytes);
}

fn writeStderr(bytes: []const u8) !void {
    try std.fs.File.stderr().writeAll(bytes);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "headterm: " ++ fmt ++ "\n", args) catch "headterm: error\n";
    std.fs.File.stderr().writeAll(msg) catch {};
    return 2;
}

test {
    _ = @import("vt.zig");
    _ = @import("keys.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
    _ = @import("pty.zig");
    _ = @import("mcp.zig");
    _ = @import("regex.zig");
    _ = @import("session_test.zig");
    _ = @import("record.zig");
    _ = @import("run.zig");
    _ = @import("stylenote.zig");
}

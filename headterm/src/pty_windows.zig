//! The Windows side of pty.zig: a pseudoconsole (ConPTY) with the program
//! started on it.
//!
//! The console host turns what the program does to its console into
//! terminal output on a pipe and takes keys from another. The output pipe
//! is read with overlapped I/O, so that the session server can wait for it
//! together with its sockets. The program runs in a job, which ends it and
//! everything it started when the session does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys_windows.zig");
const w = @import("win32.zig");
const Exit = @import("pty.zig").Exit;

pub const SpawnError = error{ PtyOpenFailed, ExecFailed, ChdirFailed } || Allocator.Error;

pub const help = struct {
    pub const resize =
        \\Resizes the terminal (2..1000 columns, 1..1000 rows); the program sees
        \\its console change size.
    ;
    pub const kill =
        \\Ends the program and everything it started, at once, and removes the
        \\session.
    ;
};

/// The console host starts by setting modes, clearing the screen and
/// homing the cursor, whatever the program does.
pub const prints_setup = true;

/// The reading side of the output pipe. It has a fixed address, as the
/// system writes into it while a read is under way.
const Output = struct {
    pipe: w.HANDLE,
    /// Signaled when `read` has something to do: at first, to start the
    /// first read, and then whenever one has finished.
    event: w.HANDLE,
    overlapped: w.OVERLAPPED,
    reading: bool = false,
    /// Read from the pipe and not yet handed out.
    ready: []u8 = &.{},
    buf: [65536]u8 = undefined,
};

pub const Pty = struct {
    gpa: Allocator,
    pid: sys.pid_t,
    process: w.HANDLE,
    job: w.HANDLE,
    /// Null once it is closed, which happens when the program has exited.
    console: ?w.HPCON,
    input: w.HANDLE,
    output: *Output,
    exited: bool = false,

    pub fn deinit(p: *Pty) void {
        const out = p.output;
        if (out.reading) {
            _ = w.CancelIo(out.pipe);
            var n: w.DWORD = 0;
            _ = w.GetOverlappedResult(out.pipe, &out.overlapped, &n, 1);
        }
        // The pipe goes first: closing the console waits, on older Windows
        // versions, for the console host to write out what it has left.
        _ = w.CloseHandle(out.pipe);
        if (p.console) |console| w.ClosePseudoConsole(console);
        _ = w.CloseHandle(p.input);
        _ = w.CloseHandle(out.event);
        // Ends whatever the program left running.
        _ = w.CloseHandle(p.job);
        _ = w.CloseHandle(p.process);
        p.gpa.destroy(out);
    }

    /// Readable when the program has printed something. Writes never wait.
    pub fn outputFd(p: *const Pty) sys.fd_t {
        return .init(p.output.event, .waitable);
    }

    /// Readable when the program has exited: ask `reap`.
    pub fn exitFd(p: *const Pty) sys.fd_t {
        return .init(p.process, .waitable);
    }

    /// The program's output. `WouldBlock` when there is none right now,
    /// 0 once the console is closed and everything has been read.
    pub fn read(p: *Pty, buf: []u8) sys.ReadError!usize {
        const out = p.output;
        while (out.ready.len == 0) {
            var n: w.DWORD = 0;
            const done = if (out.reading)
                w.GetOverlappedResult(out.pipe, &out.overlapped, &n, 0)
            else
                w.ReadFile(out.pipe, &out.buf, out.buf.len, &n, &out.overlapped);
            if (done == 0) switch (w.GetLastError()) {
                w.Err.IO_PENDING, w.Err.IO_INCOMPLETE => {
                    out.reading = true;
                    return error.WouldBlock;
                },
                w.Err.BROKEN_PIPE, w.Err.HANDLE_EOF, w.Err.PIPE_NOT_CONNECTED => {
                    out.reading = false;
                    return 0;
                },
                else => return error.Unexpected,
            };
            out.reading = false;
            out.ready = out.buf[0..n];
        }
        const n = @min(buf.len, out.ready.len);
        @memcpy(buf[0..n], out.ready[0..n]);
        out.ready = out.ready[n..];
        return n;
    }

    /// Input for the program.
    pub fn write(p: *Pty, bytes: []const u8) sys.WriteError!usize {
        return sys.write(.init(p.input, .file), bytes);
    }

    pub fn resize(p: *Pty, cols: u16, rows: u16) void {
        if (p.console) |console| _ = w.ResizePseudoConsole(console, .{ .X = @intCast(cols), .Y = @intCast(rows) });
    }

    /// The exit status once the program has exited, without waiting.
    pub fn reap(p: *Pty) ?Exit {
        if (p.exited or w.WaitForSingleObject(p.process, 0) != w.WAIT_OBJECT_0) return null;
        p.exited = true;
        var code: w.DWORD = 0;
        if (w.GetExitCodeProcess(p.process, &code) == 0) return .{};
        return .{ .code = code };
    }

    /// Ends the program and everything it started, at once: Windows has no
    /// signal that asks first. False when there is no such `step`.
    pub fn kill(p: *Pty, step: usize) bool {
        if (step > 0) return false;
        _ = w.TerminateJobObject(p.job, 1);
        return true;
    }

    /// Called once the program has exited. Closes the console, which makes
    /// the console host write out what it still has and then end the
    /// output; true, as that end is worth waiting for.
    pub fn afterExit(p: *Pty) bool {
        const console = p.console orelse return false;
        w.ClosePseudoConsole(console);
        p.console = null;
        return true;
    }

    /// How the program has set its console up to read keys itself; null in
    /// ordinary line mode with echo. To look, this process joins the
    /// program's console for a moment, which only works while it has none
    /// of its own (the session server has none).
    pub fn inputMode(p: *const Pty) ?[]const u8 {
        if (p.exited or w.AttachConsole(p.pid) == 0) return null;
        defer _ = w.FreeConsole();
        const conin = w.CreateFileW(std.unicode.wtf8ToWtf16LeStringLiteral("CONIN$"), w.GENERIC_READ | w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, 0, null);
        if (conin == w.INVALID_HANDLE_VALUE) return null;
        defer _ = w.CloseHandle(conin);
        var mode: w.DWORD = 0;
        if (w.GetConsoleMode(conin, &mode) == 0) return null;
        if (mode & w.ENABLE_LINE_INPUT == 0) return "the terminal is in raw mode";
        if (mode & w.ENABLE_ECHO_INPUT == 0) return "echo is off";
        return null;
    }
};

/// Console control events reach this process only while `inputMode` has it
/// joined to the program's console; they are meant for the program.
fn ignoreControlEvent(_: w.DWORD) callconv(.winapi) w.BOOL {
    return 1;
}

var pipe_serial: u32 = 0;

/// Opens a pseudoconsole of the given size and starts `argv` on it.
/// `err_msg` receives a human-readable reason on failure.
pub fn spawn(
    gpa: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    cols: u16,
    rows: u16,
    err_msg: *[256]u8,
) (SpawnError || error{SpawnFailed})!Pty {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Everything about the program is settled before the console exists.
    var cwd_buf: w.PathBuf = undefined;
    const cwd_w: ?[:0]const u16 = if (cwd) |d| blk: {
        const d_w = w.toWide(&cwd_buf, d) catch return failed(err_msg, error.ChdirFailed, "chdir", d, "NameTooLong");
        const attrs = w.GetFileAttributesW(d_w);
        if (attrs == w.INVALID_FILE_ATTRIBUTES) return failed(err_msg, error.ChdirFailed, "chdir", d, "FileNotFound");
        if (attrs & w.FILE_ATTRIBUTE_DIRECTORY == 0) return failed(err_msg, error.ChdirFailed, "chdir", d, "NotDir");
        break :blk d_w;
    } else null;
    const program = try findProgram(arena, argv[0], cwd_w) orelse return failed(err_msg, error.ExecFailed, "exec", argv[0], "FileNotFound");
    // A batch file is run by cmd.exe, which is also what CreateProcess
    // would do with it, less carefully.
    const batch = w.isBatchFile(program);
    const app = if (batch)
        try findProgram(arena, "cmd.exe", null) orelse return failed(err_msg, error.ExecFailed, "exec", "cmd.exe", "FileNotFound")
    else
        program;
    const app_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => unreachable, // `findProgram` made it from UTF-16
    };
    var args = try arena.dupe([]const u8, argv);
    if (batch) args[0] = program;
    const command_line = w.commandLine(arena, args, batch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return failed(err_msg, error.ExecFailed, "exec", argv[0], "InvalidWtf8"),
    };

    const output = try gpa.create(Output);
    errdefer gpa.destroy(output);
    var name_buf: [64]u8 = undefined;
    var name_w_buf: [64]u16 = undefined;
    pipe_serial += 1;
    const pipe_name = w.toWide(&name_w_buf, std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\headterm-{d}-{d}", .{ w.GetCurrentProcessId(), pipe_serial }) catch unreachable) catch unreachable;
    const out_read = w.CreateNamedPipeW(pipe_name, w.PIPE_ACCESS_INBOUND | w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE, w.PIPE_REJECT_REMOTE_CLIENTS, 1, 0, 1 << 20, 0, null);
    if (out_read == w.INVALID_HANDLE_VALUE) return error.PtyOpenFailed;
    errdefer _ = w.CloseHandle(out_read);
    const out_write = w.CreateFileW(pipe_name, w.GENERIC_WRITE, 0, null, w.OPEN_EXISTING, 0, null);
    if (out_write == w.INVALID_HANDLE_VALUE) return error.PtyOpenFailed;
    // The console host gets its own copies of its two ends.
    defer _ = w.CloseHandle(out_write);
    var in_read: w.HANDLE = undefined;
    var in_write: w.HANDLE = undefined;
    if (w.CreatePipe(&in_read, &in_write, null, 0) == 0) return error.PtyOpenFailed;
    defer _ = w.CloseHandle(in_read);
    errdefer _ = w.CloseHandle(in_write);
    const event = w.CreateEventW(null, 1, 1, null) orelse return error.PtyOpenFailed;
    errdefer _ = w.CloseHandle(event);
    output.* = .{ .pipe = out_read, .event = event, .overlapped = .{ .hEvent = event } };

    var console: w.HPCON = undefined;
    if (w.CreatePseudoConsole(.{ .X = @intCast(cols), .Y = @intCast(rows) }, in_read, out_write, 0, &console) < 0) return error.PtyOpenFailed;
    errdefer w.ClosePseudoConsole(console);

    const job = w.CreateJobObjectW(null, null) orelse return error.PtyOpenFailed;
    errdefer _ = w.CloseHandle(job);
    var limits = std.mem.zeroes(w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = w.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (w.SetInformationJobObject(job, w.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0) return error.PtyOpenFailed;

    var list_size: usize = 0;
    _ = w.InitializeProcThreadAttributeList(null, 2, 0, &list_size);
    const list = try arena.alignedAlloc(u8, .of(usize), list_size);
    if (w.InitializeProcThreadAttributeList(list.ptr, 2, 0, &list_size) == 0) return error.PtyOpenFailed;
    defer w.DeleteProcThreadAttributeList(list.ptr);
    var jobs = [_]w.HANDLE{job};
    if (w.UpdateProcThreadAttribute(list.ptr, 0, w.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, @sizeOf(w.HPCON), null, null) == 0 or
        w.UpdateProcThreadAttribute(list.ptr, 0, w.PROC_THREAD_ATTRIBUTE_JOB_LIST, &jobs, @sizeOf(@TypeOf(jobs)), null, null) == 0)
        return error.PtyOpenFailed;

    // The program must get Ctrl-C even if this process was started with it
    // switched off, which a child would inherit.
    _ = w.SetConsoleCtrlHandler(null, 0);
    _ = w.SetConsoleCtrlHandler(ignoreControlEvent, 1);

    // No standard handles of this process: the program takes the console's.
    var startup: w.STARTUPINFOEXW = .{ .lpAttributeList = list.ptr };
    startup.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES;
    var info: w.PROCESS_INFORMATION = undefined;
    if (w.CreateProcessW(app_w, command_line, null, null, 0, w.EXTENDED_STARTUPINFO_PRESENT | w.CREATE_UNICODE_ENVIRONMENT, null, if (cwd_w) |d| d.ptr else null, &startup.StartupInfo, &info) == 0) {
        var code_buf: [32]u8 = undefined;
        const code = w.GetLastError();
        return failed(err_msg, error.ExecFailed, "exec", argv[0], switch (code) {
            w.Err.FILE_NOT_FOUND, w.Err.PATH_NOT_FOUND => "FileNotFound",
            w.Err.ACCESS_DENIED => "AccessDenied",
            w.Err.BAD_EXE_FORMAT => "InvalidExe",
            w.Err.NOT_ENOUGH_MEMORY => "SystemResources",
            else => std.fmt.bufPrint(&code_buf, "Windows error {d}", .{code}) catch unreachable,
        });
    }
    _ = w.CloseHandle(info.hThread);

    return .{
        .gpa = gpa,
        .pid = info.dwProcessId,
        .process = info.hProcess,
        .job = job,
        .console = console,
        .input = in_write,
        .output = output,
    };
}

fn failed(err_msg: *[256]u8, err: SpawnError, stage: []const u8, target: []const u8, reason: []const u8) SpawnError {
    _ = std.mem.printSentinel(err_msg, "{s} {s}: {s}", .{ stage, target, reason }, 0) catch {};
    return err;
}

/// The file that running `name` means, as cmd.exe would find it: in `cwd`
/// if one is given, then in this program's own directory, the system's
/// and those of `%PATH%`, trying the endings of `%PATHEXT%` if `name` has
/// none. Null if there is no such file.
fn findProgram(arena: Allocator, name: []const u8, cwd: ?[:0]const u16) Allocator.Error!?[]const u8 {
    const name_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return null,
    };
    var pathext_buf: [256]u8 = undefined;
    const pathext = sys.getenvBuf(&pathext_buf, "PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
    var found: w.PathBuf = undefined;
    // SearchPath looks in the one directory it is given, or without one in
    // the usual places.
    const places = [_]?[*:0]const u16{ if (cwd) |d| d.ptr else null, null };
    for (places[@intFromBool(cwd == null)..]) |place| {
        var endings = std.mem.tokenizeScalar(u8, pathext, ';');
        // With an ending of its own, `name` is taken as it is first;
        // SearchPath adds an ending only to a name that has none.
        var ending: ?[]const u8 = if (std.fs.path.extension(name).len > 0) "" else endings.next();
        while (ending) |e| : (ending = endings.next()) {
            var ending_buf: [32]u16 = undefined;
            const ending_w = w.toWide(&ending_buf, e) catch continue;
            const n = w.SearchPathW(place, name_w, if (e.len > 0) ending_w.ptr else null, found.len, &found, null);
            if (n > 0 and n < found.len) return try std.unicode.wtf16LeToWtf8Alloc(arena, found[0..n]);
        }
    }
    return null;
}

const testing = std.testing;

/// Reads output until `needle` shows up in it, for at most five seconds.
fn readUntil(p: *Pty, seen: *std.ArrayList(u8), needle: []const u8) !void {
    const until = sys.milliTimestamp() + 5000;
    while (std.mem.find(u8, seen.items, needle) == null) {
        if (sys.milliTimestamp() > until) return error.TestExpectedOutput;
        var items = [_]sys.PollItem{sys.pollItem(p.outputFd(), false)};
        try sys.poll(&items, 100);
        if (!sys.readable(items[0])) continue;
        var buf: [4096]u8 = undefined;
        const n = p.read(&buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |e| return e,
        };
        if (n == 0) return error.TestExpectedOutput;
        try seen.appendSlice(testing.allocator, buf[0..n]);
    }
}

test "a program on a pseudoconsole: output, input, exit code, end of output" {
    var msg: [256]u8 = undefined;
    var p = try spawn(testing.allocator, &.{ "cmd.exe", "/d", "/c", "echo ready& set /p x=& exit 7" }, null, 40, 5, &msg);
    defer p.deinit();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try readUntil(&p, &seen, "ready");
    try testing.expect(p.reap() == null);
    try testing.expectEqual(3, try p.write("ok\r"));

    var exit_items = [_]sys.PollItem{sys.pollItem(p.exitFd(), false)};
    try sys.poll(&exit_items, 5000);
    try testing.expectEqual(7, p.reap().?.code.?);
    try testing.expect(p.reap() == null);

    // Closing the console ends the output.
    try testing.expect(p.afterExit());
    const until = sys.milliTimestamp() + 5000;
    while (sys.milliTimestamp() < until) {
        var items = [_]sys.PollItem{sys.pollItem(p.outputFd(), false)};
        try sys.poll(&items, 100);
        if (!sys.readable(items[0])) continue;
        var buf: [4096]u8 = undefined;
        const n = p.read(&buf) catch continue;
        if (n == 0) break;
    } else return error.TestExpectedEndOfOutput;
}

test "kill ends a program that would run on" {
    var msg: [256]u8 = undefined;
    var p = try spawn(testing.allocator, &.{"cmd.exe"}, null, 40, 5, &msg);
    defer p.deinit();
    try testing.expect(p.kill(0));
    try testing.expect(!p.kill(1));
    var items = [_]sys.PollItem{sys.pollItem(p.exitFd(), false)};
    try sys.poll(&items, 5000);
    try testing.expect(p.reap() != null);
}

test "a program or directory that does not exist is reported" {
    var msg: [256]u8 = undefined;
    try testing.expectError(error.ExecFailed, spawn(testing.allocator, &.{"headterm-no-such-program"}, null, 40, 5, &msg));
    try testing.expectEqualStrings("exec headterm-no-such-program: FileNotFound", std.mem.sliceTo(&msg, 0));
    try testing.expectError(error.ChdirFailed, spawn(testing.allocator, &.{"cmd.exe"}, "C:\\headterm-no-such-dir", 40, 5, &msg));
    try testing.expectEqualStrings("chdir C:\\headterm-no-such-dir: FileNotFound", std.mem.sliceTo(&msg, 0));
}

test findProgram {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd = (try findProgram(arena, "cmd", null)).?;
    try testing.expect(std.ascii.endsWithIgnoreCase(cmd, "\\cmd.exe"));
    try testing.expect(std.ascii.eqlIgnoreCase(cmd, (try findProgram(arena, "cmd.exe", null)).?));
    try testing.expect(std.ascii.eqlIgnoreCase(cmd, (try findProgram(arena, cmd, null)).?));
    try testing.expect(try findProgram(arena, "headterm-no-such-program", null) == null);
}

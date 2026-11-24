//! Child processes: what one starts ends with it, and reading its pipes
//! can't hang.
//!
//! POSIX does the first with process groups (the callers do that). Windows
//! has none: there each child goes into a job object that ends every
//! process in it when it is terminated, or when its handle is closed,
//! harness's own death included. The child is created suspended, put in
//! the job, and only then let run, so nothing it starts can be outside the
//! job (`cmd /c start` included); the job does not let processes break
//! away from it.
//!
//! Reads of a child's pipe first wait until bytes are there, the other end
//! has closed, or the reader is told to stop: poll() on POSIX,
//! PeekNamedPipe on Windows. So a process that keeps a pipe open, or a
//! read nobody needs any more, never holds a call, /stop or the exit.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

pub const Job = struct {
    handle: if (is_windows) ?windows.HANDLE else void = if (is_windows) null else {},

    /// A job that ends all its processes when it is terminated or closed.
    /// Without one (Windows refused, or not Windows) a child still runs;
    /// then only the child itself can be ended.
    pub fn create() Job {
        if (!is_windows) return .{};
        const h = win.CreateJobObjectW(null, null) orelse return .{};
        var info: win.ExtendedLimit = .{};
        info.basic.limit_flags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!win.SetInformationJobObject(h, win.JobObjectExtendedLimitInformation, &info, @sizeOf(win.ExtendedLimit)).toBool()) {
            windows.CloseHandle(h);
            return .{};
        }
        return .{ .handle = h };
    }

    /// Puts `child`, spawned with `.start_suspended = is_windows`, in the
    /// job and lets it run. If it can't go in the job it runs anyway, and
    /// the job is let go (only the child can be ended then).
    pub fn adopt(j: *Job, child: *const std.process.Child) void {
        if (!is_windows) return;
        if (j.handle) |h| {
            if (!win.AssignProcessToJobObject(h, child.id.?).toBool()) {
                windows.CloseHandle(h);
                j.handle = null;
            }
        }
        _ = win.ResumeThread(child.thread_handle);
    }

    /// Ends every process in the job; without a job, `process` alone
    /// (when given). Safe from any thread, as often as needed.
    pub fn kill(j: *const Job, process: ?std.process.Child.Id) void {
        if (!is_windows) return;
        if (j.handle) |h| {
            _ = win.TerminateJobObject(h, 1);
        } else if (process) |p| _ = win.TerminateProcess(p, 1);
    }

    /// Ends what is left in the job and lets go of it. Call once nothing
    /// else uses the job (after the threads that kill it are joined).
    pub fn close(j: *Job) void {
        if (!is_windows) return;
        if (j.handle) |h| {
            _ = win.TerminateJobObject(h, 1);
            windows.CloseHandle(h);
        }
        j.handle = null;
    }

    /// How many processes are in the job now; null without a job.
    pub fn active(j: *const Job) ?u32 {
        if (!is_windows) return null;
        const h = j.handle orelse return null;
        var info: win.BasicAccounting = .{};
        if (!win.QueryInformationJobObject(h, win.JobObjectBasicAccountingInformation, &info, @sizeOf(win.BasicAccounting), null).toBool()) return null;
        return info.active_processes;
    }

    /// Waits up to `ms` for every process in the job to have ended, unless
    /// `stop` is set first; true once none is left (at once without a job).
    /// Looks every 20 ms.
    pub fn waitEmpty(j: *const Job, io: Io, ms: u32, stop: ?*const std.atomic.Value(bool)) bool {
        const until = Io.Clock.awake.now(io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms;
        while (true) {
            const left = j.active() orelse return true;
            if (left == 0) return true;
            if (stop) |x| if (x.load(.acquire)) return false;
            if (Io.Clock.awake.now(io).nanoseconds >= until) return false;
            io.sleep(.fromMilliseconds(20), .awake) catch return false;
        }
    }
};

/// Waits until the pipe `f` has bytes to read or its other end closed
/// (true: a read now returns at once), or until `ended` is set (false).
/// Looks every 100 ms on POSIX, 20 ms on Windows.
pub fn waitReadable(io: Io, f: Io.File, ended: *const std.atomic.Value(bool)) bool {
    while (!ended.load(.acquire)) {
        if (readableWithin(io, f, 100)) return true;
    }
    return false;
}

/// Whether the pipe `f` has bytes to read, or its other end closed, within
/// `ms` (true: a read now returns at once).
pub fn readableWithin(io: Io, f: Io.File, ms: u32) bool {
    if (is_windows) {
        var waited: u32 = 0;
        while (true) : (waited += 20) {
            var avail: u32 = 0;
            // fails when the writers are gone: the read then sees the end
            if (!win.PeekNamedPipe(f.handle, null, 0, null, &avail, null).toBool()) return true;
            if (avail > 0) return true;
            if (waited >= ms) return false;
            io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    } else {
        var fds = [_]std.posix.pollfd{.{ .fd = f.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, @intCast(ms)) catch return true;
        return n > 0;
    }
}

/// Windows: an anonymous pipe; neither end is inherited by children unless
/// it is given to one (std.process.SpawnOptions.inherit_files).
pub const Pipe = struct {
    read: Io.File,
    write: Io.File,

    pub fn open() !Pipe {
        if (!is_windows) return error.Unsupported;
        var r: windows.HANDLE = undefined;
        var w: windows.HANDLE = undefined;
        if (!win.CreatePipe(&r, &w, null, 0).toBool()) return error.Unexpected;
        return .{ .read = .{ .handle = r, .flags = .{ .nonblocking = false } }, .write = .{ .handle = w, .flags = .{ .nonblocking = false } } };
    }
};

/// Windows: what spawnRaw starts.
pub const RawSpawn = struct {
    /// The program's full path.
    app: []const u8,
    /// The command line as the program gets it, word for word.
    command_line: []const u8,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    /// An AppContainer's SECURITY_CAPABILITIES (sandbox.zig); null: it
    /// runs as harness does.
    security_capabilities: ?*const anyopaque = null,
};

/// Windows: `command` for cmd.exe, read as typed: /s takes away the outer
/// quotes alone (std.process.spawn's quoting, \" for a quote, is not cmd's,
/// so a command with quotes in it failed), /d runs no AutoRun command.
pub fn cmdLine(arena: std.mem.Allocator, command: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "cmd.exe /d /s /c \"{s}\"", .{command});
}

/// Windows: starts a program suspended (for Job.adopt), stdout and stderr
/// pipes, stdin NUL, those three its only inherited handles, its command
/// line as given (see cmdLine).
pub fn spawnRaw(io: Io, arena: std.mem.Allocator, o: RawSpawn) !std.process.Child {
    if (!is_windows) return error.Unsupported;
    const app = try std.unicode.utf8ToUtf16LeAllocZ(arena, o.app);
    const cmd = try std.unicode.utf8ToUtf16LeAllocZ(arena, o.command_line);
    const block = try envBlock(arena, o.env);
    const cwd = try std.unicode.utf8ToUtf16LeAllocZ(arena, o.cwd);

    const out = try Pipe.open();
    errdefer out.read.close(io);
    defer out.write.close(io);
    const err = try Pipe.open();
    errdefer err.read.close(io);
    defer err.write.close(io);
    var sa: win.SECURITY_ATTRIBUTES = .{ .length = @sizeOf(win.SECURITY_ATTRIBUTES), .descriptor = null, .inherit = .TRUE };
    const nul = win.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), win.GENERIC_READ, 3, &sa, win.OPEN_EXISTING, 0, null);
    if (nul == windows.INVALID_HANDLE_VALUE) return error.Unexpected;
    defer windows.CloseHandle(nul);
    for ([_]windows.HANDLE{ out.write.handle, err.write.handle }) |h| {
        if (!win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT).toBool()) return error.Unexpected;
    }
    var handles = [3]windows.HANDLE{ nul, out.write.handle, err.write.handle };

    const count: u32 = if (o.security_capabilities != null) 2 else 1;
    var size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, count, 0, &size);
    const list = try arena.alignedAlloc(u8, .of(usize), size);
    if (!win.InitializeProcThreadAttributeList(list.ptr, count, 0, &size).toBool()) return error.Unexpected;
    defer win.DeleteProcThreadAttributeList(list.ptr);
    if (!win.UpdateProcThreadAttribute(list.ptr, 0, win.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles, @sizeOf(@TypeOf(handles)), null, null).toBool()) return error.Unexpected;
    if (o.security_capabilities) |sc| {
        if (!win.UpdateProcThreadAttribute(list.ptr, 0, win.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, sc, win.security_capabilities_size, null, null).toBool()) return error.Unexpected;
    }

    var si: win.STARTUPINFOEXW = std.mem.zeroes(win.STARTUPINFOEXW);
    si.si.cb = @sizeOf(win.STARTUPINFOEXW);
    si.si.dwFlags = win.STARTF_USESTDHANDLES;
    si.si.hStdInput = nul;
    si.si.hStdOutput = out.write.handle;
    si.si.hStdError = err.write.handle;
    si.attribute_list = list.ptr;
    var pi: win.PROCESS_INFORMATION = undefined;
    const flags = win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_SUSPENDED | win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT;
    if (!win.CreateProcessW(app, cmd, null, null, .TRUE, flags, block.ptr, cwd, &si, &pi).toBool()) {
        return switch (win.GetLastError()) {
            5 => error.AccessDenied,
            2, 3, 267 => error.FileNotFound,
            else => error.Unexpected,
        };
    }
    return .{
        .id = pi.process,
        .thread_handle = pi.thread,
        .stdin = null,
        .stdout = out.read,
        .stderr = err.read,
        .request_resource_usage_statistics = false,
    };
}

/// Windows: KEY=VALUE\0...\0\0 in UTF-16, sorted by name as Windows keeps
/// an environment.
pub fn envBlock(arena: std.mem.Allocator, m: *const std.process.Environ.Map) ![]u16 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = m.iterator();
    while (it.next()) |e| try names.append(arena, e.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lt);
    var out: std.ArrayList(u16) = .empty;
    for (names.items) |n| {
        const line = try std.fmt.allocPrint(arena, "{s}={s}", .{ n, m.get(n).? });
        try out.appendSlice(arena, try std.unicode.utf8ToUtf16LeAlloc(arena, line));
        try out.append(arena, 0);
    }
    try out.append(arena, 0);
    return out.items;
}

/// Windows: the system folder (C:\Windows\System32), where cmd, ping and
/// the like are; a PATH for children in tests.
pub fn systemDir(gpa: std.mem.Allocator) ![]u8 {
    if (!is_windows) return error.Unsupported;
    var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const n = win.GetSystemDirectoryW(&buf, buf.len);
    if (n == 0 or n >= buf.len) return error.Unexpected;
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
}

// ---- Windows: a sandbox with drive letters of its own ----
//
// cmd's own dir, del, ren, copy, move and cd /d first ask a path's drive
// what file system it has, and an AppContainer may not open a real
// drive's root (its access list is an administrator's to change). So the
// folders a sandbox works in are drives of its own. DOS device names
// belong to a logon session: the sandbox is started from a launcher that
// Windows' Secondary Logon service starts in a new one (as `runas
// /netonly` does: the same user here, other credentials only toward the
// network, which an AppContainer doesn't use). There the launcher names
// the drives and starts the AppContainer's cmd; every program that starts
// sees them, no other session does (not Explorer either), and they are
// gone with the session's last process.

/// The launcher's argument, for harness itself and for harness-fake.
pub const launch_arg = "sandbox-launch";

/// The drive letters this session has (bit 0 is A).
pub fn logicalDrives() u32 {
    return if (is_windows) win.GetLogicalDrives() else 0;
}

/// The variables that tell the launcher what to start; it takes them out
/// of what the sandbox gets.
const launch_prefix = "HARNESS_SBX_";

pub const Drive = struct { letter: u8, folder: []const u8 };

pub const SessionSpawn = struct {
    /// The program that is the launcher, and the argument that makes it one.
    launcher: [2][]const u8,
    app: []const u8,
    command_line: []const u8,
    env: *const std.process.Environ.Map,
    /// Where the launcher starts (a real path); the command changes to
    /// its drive itself.
    cwd: []const u8,
    /// The AppContainer's name, and whether it reaches outside hosts.
    profile: []const u8,
    network: bool,
    drives: []const Drive,
};

/// Windows: starts the launcher suspended (for Job.adopt) in a logon
/// session of its own, with stdout and stderr pipes and stdin NUL, which
/// it hands on to the sandbox's command. error.NoSession: the Secondary
/// Logon service doesn't start one here (switched off, not there, or not
/// allowed). error.SessionNotNow: it didn't this time (Windows' error is
/// in `last_session_error`); another try may.
pub fn spawnInSession(io: Io, arena: std.mem.Allocator, o: SessionSpawn) !std.process.Child {
    if (!is_windows) return error.Unsupported;
    var vars = try o.env.clone(arena);
    try vars.put(launch_prefix ++ "APP", o.app);
    try vars.put(launch_prefix ++ "LINE", o.command_line);
    try vars.put(launch_prefix ++ "PROFILE", o.profile);
    try vars.put(launch_prefix ++ "NET", if (o.network) "1" else "0");
    var list: std.ArrayList(u8) = .empty;
    for (o.drives) |d| try list.print(arena, "{c}={s}|", .{ d.letter, d.folder });
    try vars.put(launch_prefix ++ "DRIVES", list.items);
    const block = try envBlock(arena, &vars);
    const exe = try std.unicode.utf8ToUtf16LeAllocZ(arena, o.launcher[0]);
    const cmd = try std.unicode.utf8ToUtf16LeAllocZ(arena, try std.fmt.allocPrint(arena, "\"{s}\" {s}", .{ o.launcher[0], o.launcher[1] }));
    const cwd = try std.unicode.utf8ToUtf16LeAllocZ(arena, o.cwd);

    const out = try Pipe.open();
    errdefer out.read.close(io);
    defer out.write.close(io);
    const err = try Pipe.open();
    errdefer err.read.close(io);
    defer err.write.close(io);
    var sa: win.SECURITY_ATTRIBUTES = .{ .length = @sizeOf(win.SECURITY_ATTRIBUTES), .descriptor = null, .inherit = .TRUE };
    const nul = win.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), win.GENERIC_READ, 3, &sa, win.OPEN_EXISTING, 0, null);
    if (nul == windows.INVALID_HANDLE_VALUE) return error.Unexpected;
    defer windows.CloseHandle(nul);
    for ([_]windows.HANDLE{ out.write.handle, err.write.handle }) |h| {
        if (!win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT).toBool()) return error.Unexpected;
    }
    // (the service copies these three to the new process; it passes on no
    // other handle)
    var si: win.STARTUPINFOW = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);
    si.dwFlags = win.STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = out.write.handle;
    si.hStdError = err.write.handle;
    var pi: win.PROCESS_INFORMATION = undefined;
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const flags = win.CREATE_SUSPENDED | win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT;
    // a name and password that are never checked here (LOGON_NETCREDENTIALS_ONLY)
    if (!win.CreateProcessWithLogonW(W("harness-sandbox"), W("."), W("-"), win.LOGON_NETCREDENTIALS_ONLY, exe, cmd, flags, block.ptr, cwd, &si, &pi).toBool()) {
        const code = win.GetLastError();
        last_session_error.store(code, .release);
        return switch (code) {
            2, 3, 267 => error.FileNotFound,
            // the service is disabled, not installed, can't start, or
            // this account may not use it
            1058, 1060, 1068, 1069, 1385 => error.NoSession,
            else => error.SessionNotNow,
        };
    }
    return .{
        .id = pi.process,
        .thread_handle = pi.thread,
        .stdin = null,
        .stdout = out.read,
        .stderr = err.read,
        .request_resource_usage_statistics = false,
    };
}

/// Windows' error the last time a session of its own could not be
/// started; 0: never.
pub var last_session_error: std.atomic.Value(u32) = .init(0);

/// The launcher, in its new logon session: names the drives, starts the
/// AppContainer's command with this process's own stdin, stdout and
/// stderr, waits for it and ends with its exit code. Never returns on
/// Windows.
pub fn sandboxLaunch(arena: std.mem.Allocator, env: *const std.process.Environ.Map) u8 {
    if (!is_windows) return 2;
    const code = launchIn(arena, env) catch |e| blk: {
        std.debug.print("harness: the sandbox could not be started: {s}\n", .{@errorName(e)});
        break :blk 125;
    };
    win.ExitProcess(code);
}

fn launchIn(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !u32 {
    const app8 = env.get(launch_prefix ++ "APP") orelse return error.NotALauncher;
    const line8 = env.get(launch_prefix ++ "LINE") orelse return error.NotALauncher;
    const profile8 = env.get(launch_prefix ++ "PROFILE") orelse return error.NotALauncher;
    const network = std.mem.eql(u8, env.get(launch_prefix ++ "NET") orelse "0", "1");
    var drives = std.mem.tokenizeScalar(u8, env.get(launch_prefix ++ "DRIVES") orelse "", '|');
    while (drives.next()) |d| {
        if (d.len < 3 or d[1] != '=') return error.BadDrive;
        const name = try std.unicode.utf8ToUtf16LeAllocZ(arena, &.{ d[0], ':' });
        const target = try std.unicode.utf8ToUtf16LeAllocZ(arena, std.mem.trimEnd(u8, d[2..], "\\/"));
        std.mem.replaceScalar(u16, target, '/', '\\');
        if (!win.DefineDosDeviceW(0, name, target).toBool()) return error.DriveNotNamed;
    }
    // what the sandbox gets: this process's variables without the launcher's
    var vars = std.process.Environ.Map.init(arena);
    var it = env.iterator();
    while (it.next()) |e| {
        if (std.ascii.startsWithIgnoreCase(e.key_ptr.*, launch_prefix)) continue;
        try vars.put(e.key_ptr.*, e.value_ptr.*);
    }
    const block = try envBlock(arena, &vars);
    const app = try std.unicode.utf8ToUtf16LeAllocZ(arena, app8);
    const cmd = try std.unicode.utf8ToUtf16LeAllocZ(arena, line8);

    var sid: ?*anyopaque = null;
    if (win.DeriveAppContainerSidFromAppContainerName(try std.unicode.utf8ToUtf16LeAllocZ(arena, profile8), &sid) != 0) return error.NoProfile;
    var net_sid: ?*anyopaque = null;
    var caps: [1]win.SID_AND_ATTRIBUTES = undefined;
    var cap_count: u32 = 0;
    if (network) {
        // internetClient: outside hosts, never loopback or the LAN
        if (!win.ConvertStringSidToSidW(std.unicode.utf8ToUtf16LeStringLiteral("S-1-15-3-1"), &net_sid).toBool()) return error.Unexpected;
        caps[0] = .{ .sid = net_sid, .attributes = 0x4 };
        cap_count = 1;
    }
    const sc: win.SECURITY_CAPABILITIES = .{ .app_container_sid = sid, .capabilities = if (cap_count > 0) &caps else null, .capability_count = cap_count };

    var handles: [3]windows.HANDLE = undefined;
    for (&handles, [_]i32{ -10, -11, -12 }) |*h, n| {
        h.* = win.GetStdHandle(@bitCast(n)) orelse return error.NoStdHandle;
        if (!win.SetHandleInformation(h.*, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT).toBool()) return error.Unexpected;
    }
    var size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 2, 0, &size);
    const list = try arena.alignedAlloc(u8, .of(usize), size);
    if (!win.InitializeProcThreadAttributeList(list.ptr, 2, 0, &size).toBool()) return error.Unexpected;
    defer win.DeleteProcThreadAttributeList(list.ptr);
    if (!win.UpdateProcThreadAttribute(list.ptr, 0, win.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles, @sizeOf(@TypeOf(handles)), null, null).toBool()) return error.Unexpected;
    if (!win.UpdateProcThreadAttribute(list.ptr, 0, win.PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &sc, win.security_capabilities_size, null, null).toBool()) return error.Unexpected;
    var si: win.STARTUPINFOEXW = std.mem.zeroes(win.STARTUPINFOEXW);
    si.si.cb = @sizeOf(win.STARTUPINFOEXW);
    si.si.dwFlags = win.STARTF_USESTDHANDLES;
    si.si.hStdInput = handles[0];
    si.si.hStdOutput = handles[1];
    si.si.hStdError = handles[2];
    si.attribute_list = list.ptr;
    var pi: win.PROCESS_INFORMATION = undefined;
    const flags = win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_NO_WINDOW | win.CREATE_UNICODE_ENVIRONMENT;
    if (!win.CreateProcessW(app, cmd, null, null, .TRUE, flags, block.ptr, null, &si, &pi).toBool()) return error.CommandNotStarted;
    _ = win.WaitForSingleObject(pi.process, 0xFFFFFFFF);
    var code: u32 = 1;
    _ = win.GetExitCodeProcess(pi.process, &code);
    return code;
}

const win = struct {
    const LOGON_NETCREDENTIALS_ONLY: u32 = 2;
    const SID_AND_ATTRIBUTES = extern struct { sid: ?*anyopaque, attributes: u32 };
    const SECURITY_CAPABILITIES = extern struct {
        app_container_sid: ?*anyopaque,
        capabilities: ?[*]SID_AND_ATTRIBUTES,
        capability_count: u32,
        reserved: u32 = 0,
    };
    extern "advapi32" fn CreateProcessWithLogonW(user: [*:0]const u16, domain: ?[*:0]const u16, password: [*:0]const u16, logon_flags: u32, app: ?[*:0]const u16, cmd: ?[*:0]u16, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn ConvertStringSidToSidW(s: [*:0]const u16, sid: *?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "userenv" fn DeriveAppContainerSidFromAppContainerName(name: [*:0]const u16, sid: *?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn DefineDosDeviceW(flags: u32, name: [*:0]const u16, target: ?[*:0]const u16) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn WaitForSingleObject(h: windows.HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(h: windows.HANDLE, code: *u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
    pub extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
    const JobObjectBasicAccountingInformation: c_int = 1;
    const JobObjectExtendedLimitInformation: c_int = 9;

    const BasicLimit = extern struct {
        per_process_user_time_limit: i64 = 0,
        per_job_user_time_limit: i64 = 0,
        limit_flags: u32 = 0,
        minimum_working_set_size: usize = 0,
        maximum_working_set_size: usize = 0,
        active_process_limit: u32 = 0,
        affinity: usize = 0,
        priority_class: u32 = 0,
        scheduling_class: u32 = 0,
    };

    const IoCounters = extern struct {
        read_operations: u64 = 0,
        write_operations: u64 = 0,
        other_operations: u64 = 0,
        read_bytes: u64 = 0,
        write_bytes: u64 = 0,
        other_bytes: u64 = 0,
    };

    const ExtendedLimit = extern struct {
        basic: BasicLimit = .{},
        io: IoCounters = .{},
        process_memory_limit: usize = 0,
        job_memory_limit: usize = 0,
        peak_process_memory_used: usize = 0,
        peak_job_memory_used: usize = 0,
    };

    const BasicAccounting = extern struct {
        total_user_time: i64 = 0,
        total_kernel_time: i64 = 0,
        this_period_total_user_time: i64 = 0,
        this_period_total_kernel_time: i64 = 0,
        total_page_fault_count: u32 = 0,
        total_processes: u32 = 0,
        active_processes: u32 = 0,
        total_terminated_processes: u32 = 0,
    };

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: ?windows.HANDLE, class: c_int, info: *anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, code: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateProcess(process: windows.HANDLE, code: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ResumeThread(thread: windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn PeekNamedPipe(pipe: windows.HANDLE, buf: ?*anyopaque, buf_len: u32, read: ?*u32, avail: ?*u32, left: ?*u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreatePipe(read: *windows.HANDLE, write: *windows.HANDLE, attributes: ?*anyopaque, size: u32) callconv(.winapi) windows.BOOL;

    const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x20002;
    const PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES: usize = 0x20009;
    /// SECURITY_CAPABILITIES: a SID, a capabilities pointer, two u32s.
    const security_capabilities_size: usize = 2 * @sizeOf(usize) + 8;
    const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
    const CREATE_SUSPENDED: u32 = 0x4;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    const CREATE_UNICODE_ENVIRONMENT: u32 = 0x400;
    const STARTF_USESTDHANDLES: u32 = 0x100;
    const HANDLE_FLAG_INHERIT: u32 = 0x1;
    const GENERIC_READ: u32 = 0x80000000;
    const OPEN_EXISTING: u32 = 3;

    const SECURITY_ATTRIBUTES = extern struct { length: u32, descriptor: ?*anyopaque, inherit: windows.BOOL };
    const STARTUPINFOW = extern struct {
        cb: u32,
        lpReserved: ?[*:0]u16,
        lpDesktop: ?[*:0]u16,
        lpTitle: ?[*:0]u16,
        dwX: u32,
        dwY: u32,
        dwXSize: u32,
        dwYSize: u32,
        dwXCountChars: u32,
        dwYCountChars: u32,
        dwFillAttribute: u32,
        dwFlags: u32,
        wShowWindow: u16,
        cbReserved2: u16,
        lpReserved2: ?*u8,
        hStdInput: ?windows.HANDLE,
        hStdOutput: ?windows.HANDLE,
        hStdError: ?windows.HANDLE,
    };
    const STARTUPINFOEXW = extern struct { si: STARTUPINFOW, attribute_list: ?*anyopaque };
    const PROCESS_INFORMATION = extern struct { process: windows.HANDLE, thread: windows.HANDLE, pid: u32, tid: u32 };

    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: u32, attribute: usize, value: *const anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: windows.BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOEXW, pi: *PROCESS_INFORMATION) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetHandleInformation(h: windows.HANDLE, mask: u32, flags: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*SECURITY_ATTRIBUTES, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
};

const t = std.testing;

test "the job's structures have the sizes Windows expects" {
    if (!is_windows or @sizeOf(usize) != 8) return error.SkipZigTest;
    try t.expectEqual(@as(usize, 64), @sizeOf(win.BasicLimit));
    try t.expectEqual(@as(usize, 144), @sizeOf(win.ExtendedLimit));
    try t.expectEqual(@as(usize, 48), @sizeOf(win.BasicAccounting));
}

test "a_job_ends_what_its_child_started_and_its_own_end_ends_it_too" {
    if (!is_windows) return error.SkipZigTest;
    var job = Job.create();
    defer job.close();
    try t.expect(job.handle != null);
    // cmd starts a second process in the background, then waits itself
    var child = try std.process.spawn(t.io, .{
        .argv = &.{ "cmd.exe", "/c", "start /b ping -n 30 127.0.0.1 >nul & ping -n 30 127.0.0.1 >nul" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .start_suspended = true,
        .create_no_window = true,
    });
    job.adopt(&child);
    var tries: u32 = 0;
    while ((job.active() orelse 0) < 3 and tries < 100) : (tries += 1) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    // cmd and its two pings (and the console host, if Windows counts it)
    try t.expect((job.active() orelse 0) >= 3);
    job.kill(child.id);
    _ = try child.wait(t.io);
    tries = 0;
    while ((job.active() orelse 0) > 0 and tries < 100) : (tries += 1) t.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try t.expectEqual(@as(?u32, 0), job.active());
}

test "waitEmpty_waits_for_every_process_of_the_job_to_end_by_itself" {
    if (!is_windows) return error.SkipZigTest;
    var job = Job.create();
    defer job.close();
    // cmd ends after about a second, the ping it started after about two
    var child = try std.process.spawn(t.io, .{
        .argv = &.{ "cmd.exe", "/c", "start /b ping -n 3 127.0.0.1 >nul & ping -n 2 127.0.0.1 >nul" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .start_suspended = true,
        .create_no_window = true,
    });
    job.adopt(&child);
    var stop: std.atomic.Value(bool) = .init(false);
    try t.expect(!job.waitEmpty(t.io, 300, &stop));
    try t.expect((job.active() orelse 0) > 0);
    // a stop ends the wait at once
    stop.store(true, .release);
    const before = Io.Clock.awake.now(t.io).nanoseconds;
    try t.expect(!job.waitEmpty(t.io, 10_000, &stop));
    try t.expect(Io.Clock.awake.now(t.io).nanoseconds - before < 500 * std.time.ns_per_ms);
    stop.store(false, .release);
    try t.expect(job.waitEmpty(t.io, 10_000, &stop));
    try t.expectEqual(@as(?u32, 0), job.active());
    _ = try child.wait(t.io);
}

test "waitReadable_sees_bytes_the_end_of_a_pipe_and_being_told_to_stop" {
    var ended: std.atomic.Value(bool) = .init(false);
    const argv: []const []const u8 = if (is_windows) &.{ "cmd.exe", "/c", "echo hi" } else &.{ "/bin/sh", "-c", "echo hi" };
    var child = try std.process.spawn(t.io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore, .create_no_window = true });
    const out = child.stdout.?;
    child.stdout = null;
    defer out.close(t.io);
    _ = try child.wait(t.io);
    try t.expect(waitReadable(t.io, out, &ended));
    var buf: [64]u8 = undefined;
    const got = try out.readStreaming(t.io, &.{&buf});
    try t.expect(std.mem.startsWith(u8, buf[0..got], "hi"));
    // the writer is gone: readable, and the read says end of file
    try t.expect(waitReadable(t.io, out, &ended));
    try t.expectEqual(@as(usize, 0), out.readStreaming(t.io, &.{&buf}) catch 0);
    ended.store(true, .release);
    try t.expect(!waitReadable(t.io, out, &ended));
}

test "the_sandbox_launcher_starts_nothing_it_was_not_told_to" {
    if (!is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    // run by hand, or by a program that isn't harness: no variables, nothing
    var none = std.process.Environ.Map.init(arena.allocator());
    try t.expectError(error.NotALauncher, launchIn(arena.allocator(), &none));
    try none.put("HARNESS_SBX_APP", "cmd.exe");
    try t.expectError(error.NotALauncher, launchIn(arena.allocator(), &none));
}

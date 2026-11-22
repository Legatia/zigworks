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

/// Windows: the system folder (C:\Windows\System32), where cmd, ping and
/// the like are; a PATH for children in tests.
pub fn systemDir(gpa: std.mem.Allocator) ![]u8 {
    if (!is_windows) return error.Unsupported;
    var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const n = win.GetSystemDirectoryW(&buf, buf.len);
    if (n == 0 or n >= buf.len) return error.Unexpected;
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]);
}

const win = struct {
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

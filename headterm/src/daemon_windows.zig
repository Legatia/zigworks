//! The Windows side of daemon.zig: the session server is this program
//! started again, with `server_command` as its only argument.
//!
//! The new process has no console and none of the caller's handles, so a
//! caller that waits for the end of headterm's output (`$(headterm start
//! ...)`) is not held up by it. It gets the session's configuration on its
//! standard input and reports on its standard output, both pipes.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sys = @import("sys_windows.zig");
const w = @import("win32.zig");
const server = @import("server.zig");

pub const server_command = "session-server";

pub const LaunchError = error{ ServerStartFailed, NameTooLong } || Allocator.Error;

/// Starts the session server and returns the reading end of the pipe on
/// which it reports that it is ready.
pub fn launch(gpa: Allocator, cfg: server.Config) LaunchError!sys.fd_t {
    var exe_buf: w.PathBuf = undefined;
    const exe = try serverExe(&exe_buf);
    var exe_utf8: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const command_line = w.commandLine(gpa, &.{ w.fromWide(&exe_utf8, exe) orelse return error.NameTooLong, server_command }, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.ServerStartFailed,
    };
    defer gpa.free(command_line);
    const payload = try encodeConfig(gpa, cfg);
    defer gpa.free(payload);

    // The server inherits exactly these three handles.
    var inherit: w.SECURITY_ATTRIBUTES = .{ .bInheritHandle = 1 };
    var cfg_read: w.HANDLE = undefined;
    var cfg_write: w.HANDLE = undefined;
    if (w.CreatePipe(&cfg_read, &cfg_write, &inherit, 0) == 0) return error.ServerStartFailed;
    defer _ = w.CloseHandle(cfg_read);
    defer _ = w.CloseHandle(cfg_write);
    var ready_read: w.HANDLE = undefined;
    var ready_write: w.HANDLE = undefined;
    if (w.CreatePipe(&ready_read, &ready_write, &inherit, 0) == 0) return error.ServerStartFailed;
    defer _ = w.CloseHandle(ready_write);
    errdefer _ = w.CloseHandle(ready_read);
    const nul = w.CreateFileW(std.unicode.wtf8ToWtf16LeStringLiteral("NUL"), w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, &inherit, w.OPEN_EXISTING, 0, null);
    if (nul == w.INVALID_HANDLE_VALUE) return error.ServerStartFailed;
    defer _ = w.CloseHandle(nul);

    var list_size: usize = 0;
    _ = w.InitializeProcThreadAttributeList(null, 1, 0, &list_size);
    const list = try gpa.alignedAlloc(u8, .of(usize), list_size);
    defer gpa.free(list);
    if (w.InitializeProcThreadAttributeList(list.ptr, 1, 0, &list_size) == 0) return error.ServerStartFailed;
    defer w.DeleteProcThreadAttributeList(list.ptr);
    var handles = [_]w.HANDLE{ cfg_read, ready_write, nul };
    if (w.UpdateProcThreadAttribute(list.ptr, 0, w.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &handles, @sizeOf(@TypeOf(handles)), null, null) == 0) return error.ServerStartFailed;

    var startup: w.STARTUPINFOEXW = .{ .lpAttributeList = list.ptr };
    startup.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = cfg_read;
    startup.StartupInfo.hStdOutput = ready_write;
    startup.StartupInfo.hStdError = nul;
    // No console, so Ctrl-C in the caller's does not reach the server. Not
    // a new process group: that switches Ctrl-C off for the server and,
    // by inheritance, for the program it starts. Out of the caller's job
    // if that is allowed, so that the session outlives a caller whose job
    // is ended with it.
    const flags = w.DETACHED_PROCESS | w.CREATE_UNICODE_ENVIRONMENT | w.EXTENDED_STARTUPINFO_PRESENT;
    var info: w.PROCESS_INFORMATION = undefined;
    if (w.CreateProcessW(exe, command_line, null, null, 1, flags | w.CREATE_BREAKAWAY_FROM_JOB, null, null, &startup.StartupInfo, &info) == 0 and
        w.CreateProcessW(exe, command_line, null, null, 1, flags, null, null, &startup.StartupInfo, &info) == 0)
        return error.ServerStartFailed;
    _ = w.CloseHandle(info.hThread);
    _ = w.CloseHandle(info.hProcess);

    // A server that ends early breaks the pipe; the missing report says so.
    sys.writeAll(.init(cfg_write, .file), payload) catch {};
    return .init(ready_read, .file);
}

/// The program to start as session server: this one. The unit tests run
/// in a test binary, which has no such command; build.zig tells them
/// where headterm is.
fn serverExe(buf: *w.PathBuf) error{ ServerStartFailed, NameTooLong }![:0]const u16 {
    if (builtin.is_test) return w.toWide(buf, @import("test_options").headterm_exe);
    const n = w.GetModuleFileNameW(null, buf, buf.len);
    if (n == 0) return error.ServerStartFailed;
    if (n >= buf.len) return error.NameTooLong;
    return buf[0..n :0];
}

/// Runs the session server that `launch` started. Does not return.
pub fn serverMain(gpa: Allocator) noreturn {
    var payload: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(sys.stdin(), &buf) catch sys.exit(2);
        if (n == 0) break;
        payload.appendSlice(gpa, buf[0..n]) catch sys.exit(2);
    }
    const ready = sys.stdout();
    sys.close(sys.stdin());
    // Both pipes get closed while the server runs on, and their numbers
    // go to other handles. So the standard handles all become the null
    // device that standard error already is: joining the program's console
    // (`Pty.inputMode`) sets up and closes standard handles that are not
    // valid ones of some other kind.
    const nul = w.GetStdHandle(w.STD_ERROR_HANDLE);
    _ = w.SetStdHandle(w.STD_INPUT_HANDLE, nul);
    _ = w.SetStdHandle(w.STD_OUTPUT_HANDLE, nul);
    // The configuration lives as long as the server.
    const cfg = decodeConfig(gpa, payload.items) catch sys.exit(2);
    server.serve(gpa, cfg, ready);
}

/// The configuration as NUL-terminated fields: name, socket path, columns,
/// rows, the four optional settings ("-" if unset, else "=" and the
/// value), then the command.
fn encodeConfig(gpa: Allocator, cfg: server.Config) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writeConfig(&out.writer, cfg) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeConfig(out: *std.Io.Writer, cfg: server.Config) !void {
    try out.print("{s}\x00{s}\x00{d}\x00{d}\x00", .{ cfg.name, cfg.socket_path, cfg.cols, cfg.rows });
    for ([_]?[]const u8{ cfg.cwd, cfg.log_path, cfg.record_path }) |value| {
        if (value) |v| try out.print("={s}\x00", .{v}) else try out.writeAll("-\x00");
    }
    if (cfg.ttl_s) |ttl| try out.print("={d}\x00", .{ttl}) else try out.writeAll("-\x00");
    for (cfg.argv) |arg| try out.print("{s}\x00", .{arg});
}

/// The reverse of `encodeConfig`. The result points into `payload`, and
/// its command is allocated with `gpa`.
fn decodeConfig(gpa: Allocator, payload: []const u8) !server.Config {
    var fields = std.mem.splitScalar(u8, payload, 0);
    const name = fields.next() orelse return error.BadConfig;
    const socket_path = fields.next() orelse return error.BadConfig;
    const cols = try std.fmt.parseInt(u16, fields.next() orelse return error.BadConfig, 10);
    const rows = try std.fmt.parseInt(u16, fields.next() orelse return error.BadConfig, 10);
    var optional: [4]?[]const u8 = undefined;
    for (&optional) |*value| {
        const field = fields.next() orelse return error.BadConfig;
        if (field.len == 0) return error.BadConfig;
        value.* = if (field[0] == '=') field[1..] else null;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    // The last field is the empty one after the final terminator.
    while (fields.next()) |arg| {
        if (fields.peek() != null) try argv.append(gpa, arg);
    }
    if (argv.items.len == 0) return error.BadConfig;
    return .{
        .name = name,
        .socket_path = socket_path,
        .argv = try argv.toOwnedSlice(gpa),
        .cwd = optional[0],
        .cols = cols,
        .rows = rows,
        .log_path = optional[1],
        .record_path = optional[2],
        .ttl_s = if (optional[3]) |ttl| try std.fmt.parseInt(u32, ttl, 10) else null,
    };
}

test "the configuration survives the trip to the server" {
    const gpa = std.testing.allocator;
    const cases = [_]server.Config{
        .{ .name = "a", .socket_path = "C:\\t\\a.sock", .argv = &.{ "cmd.exe", "/c", "echo  two  spaces", "" }, .cwd = null, .cols = 120, .rows = 40 },
        .{ .name = "b", .socket_path = "s", .argv = &.{"python"}, .cwd = "C:\\work dir", .cols = 2, .rows = 1, .log_path = "-", .ttl_s = 3600, .record_path = "=r.cast" },
    };
    for (cases) |cfg| {
        const payload = try encodeConfig(gpa, cfg);
        defer gpa.free(payload);
        const back = try decodeConfig(gpa, payload);
        defer gpa.free(back.argv);
        try std.testing.expectEqualDeep(cfg, back);
    }
    try std.testing.expectError(error.BadConfig, decodeConfig(gpa, "a\x00s\x0080\x0024\x00-\x00-\x00-\x00-\x00"));
}

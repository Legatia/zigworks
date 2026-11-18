//! The Win32 and Winsock declarations headterm uses (std declares almost
//! none of them), and the text conversions every call needs.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HANDLE = *anyopaque;
pub const HPCON = *anyopaque;
pub const BOOL = c_int;
pub const WORD = u16;
pub const DWORD = u32;
pub const SOCKET = usize;

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;
pub const MAXIMUM_WAIT_OBJECTS = 64;

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const FILE_TYPE_CHAR: DWORD = 2;
pub const FILE_TYPE_PIPE: DWORD = 3;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_APPEND_DATA: DWORD = 0x0004;
pub const FILE_SHARE_READ: DWORD = 1;
pub const FILE_SHARE_WRITE: DWORD = 2;
pub const FILE_SHARE_DELETE: DWORD = 4;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const PIPE_ACCESS_INBOUND: DWORD = 1;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 8;

pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;

pub const STARTF_USESTDHANDLES: DWORD = 0x100;
pub const DETACHED_PROCESS: DWORD = 0x00000008;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub const PROC_THREAD_ATTRIBUTE_JOB_LIST: usize = 0x0002000D;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
pub const JobObjectExtendedLimitInformation: c_int = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x2000;

/// The error codes headterm tells apart.
pub const Err = struct {
    pub const FILE_NOT_FOUND = 2;
    pub const PATH_NOT_FOUND = 3;
    pub const ACCESS_DENIED = 5;
    pub const NOT_ENOUGH_MEMORY = 8;
    pub const SHARING_VIOLATION = 32;
    pub const HANDLE_EOF = 38;
    pub const BROKEN_PIPE = 109;
    pub const DISK_FULL = 112;
    pub const INVALID_NAME = 123;
    pub const ALREADY_EXISTS = 183;
    pub const BAD_EXE_FORMAT = 193;
    pub const NO_DATA = 232;
    pub const PIPE_NOT_CONNECTED = 233;
    pub const IO_INCOMPLETE = 996;
    pub const IO_PENDING = 997;

    pub const WSAEACCES = 10013;
    pub const WSAEINVAL = 10022;
    pub const WSAEMFILE = 10024;
    pub const WSAEWOULDBLOCK = 10035;
    pub const WSAEAFNOSUPPORT = 10047;
    pub const WSAEADDRINUSE = 10048;
    pub const WSAENETDOWN = 10050;
    pub const WSAECONNABORTED = 10053;
    pub const WSAECONNRESET = 10054;
    pub const WSAENOBUFS = 10055;
    pub const WSAENOTCONN = 10057;
    pub const WSAESHUTDOWN = 10058;
    pub const WSAETIMEDOUT = 10060;
    pub const WSAECONNREFUSED = 10061;
};

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL,
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{ .cb = @sizeOf(STARTUPINFOEXW) },
    lpAttributeList: ?*anyopaque = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const COORD = extern struct { X: i16, Y: i16 };

pub const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: DWORD,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: DWORD,
        Affinity: usize,
        PriorityClass: DWORD,
        SchedulingClass: DWORD,
    },
    IoInfo: [6]u64,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetStdHandle(which: DWORD, h: ?HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileType(h: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?[*]u8, len: DWORD, read: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: DWORD, pipe_mode: DWORD, max_instances: DWORD, out_size: DWORD, in_size: DWORD, timeout: DWORD, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
pub extern "kernel32" fn CreateEventW(sa: ?*SECURITY_ATTRIBUTES, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetOverlappedResult(h: HANDLE, ov: *OVERLAPPED, transferred: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIo(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(count: DWORD, handles: [*]const HANDLE, wait_all: BOOL, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, command_line: ?[*:0]u16, process_sa: ?*SECURITY_ATTRIBUTES, thread_sa: ?*SECURITY_ATTRIBUTES, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attribute: usize, value: *const anyopaque, size: usize, prev: ?*anyopaque, ret_size: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn CreatePseudoConsole(size: COORD, input: HANDLE, output: HANDLE, flags: DWORD, console: *HPCON) callconv(.winapi) i32;
pub extern "kernel32" fn ResizePseudoConsole(console: HPCON, size: COORD) callconv(.winapi) i32;
pub extern "kernel32" fn ClosePseudoConsole(console: HPCON) callconv(.winapi) void;
pub extern "kernel32" fn CreateJobObjectW(sa: ?*SECURITY_ATTRIBUTES, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, len: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, exit_code: c_uint) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, len: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]u16, len: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn SearchPathW(path: ?[*:0]const u16, file: [*:0]const u16, ext: ?[*:0]const u16, len: DWORD, buf: [*]u16, file_part: ?*?[*:0]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetSystemTimeAsFileTime(ft: *FILETIME) callconv(.winapi) void;
pub extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteConsoleW(h: HANDLE, buf: [*]const u16, len: DWORD, written: ?*DWORD, reserved: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn AttachConsole(pid: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

pub const sockaddr_un = extern struct {
    family: u16 = AF_UNIX,
    path: [108]u8,
};

pub const AF_UNIX = 1;
pub const SOCK_STREAM = 1;
pub const SOL_SOCKET = 0xffff;
pub const SO_RCVTIMEO = 0x1006;
pub const FIONBIO: c_long = @bitCast(@as(u32, 0x8004667e));
pub const FD_READ: c_long = 1;
pub const FD_ACCEPT: c_long = 8;
pub const FD_CLOSE: c_long = 32;

pub extern "ws2_32" fn WSAStartup(version: WORD, data: *[512]u8) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
pub extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
pub extern "ws2_32" fn bind(s: SOCKET, addr: *const sockaddr_un, len: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, len: ?*c_int) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn connect(s: SOCKET, addr: *const sockaddr_un, len: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn getsockopt(s: SOCKET, level: c_int, name: c_int, value: [*]u8, len: *c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, name: c_int, value: [*]const u8, len: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: c_long, arg: *c_ulong) callconv(.winapi) c_int;
pub const fd_set = extern struct {
    count: c_uint = 0,
    sockets: [MAXIMUM_WAIT_OBJECTS]SOCKET = undefined,
};
pub const timeval = extern struct { sec: c_long, usec: c_long };
pub extern "ws2_32" fn select(ignored: c_int, read: ?*fd_set, write: ?*fd_set, except: ?*fd_set, timeout: ?*const timeval) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSACreateEvent() callconv(.winapi) ?HANDLE;
pub extern "ws2_32" fn WSAEventSelect(s: SOCKET, event: ?HANDLE, events: c_long) callconv(.winapi) c_int;

/// Longest path, in UTF-16 units, the conversions below take.
pub const max_path = 1024;
pub const PathBuf = [max_path:0]u16;

/// `text` as NUL-terminated UTF-16 in `buf`.
pub fn toWide(buf: []u16, text: []const u8) error{NameTooLong}![:0]u16 {
    if (buf.len == 0 or (std.unicode.calcWtf16LeLen(text) catch return error.NameTooLong) >= buf.len) return error.NameTooLong;
    const n = std.unicode.wtf8ToWtf16Le(buf, text) catch return error.NameTooLong;
    buf[n] = 0;
    return buf[0..n :0];
}

/// `wide` as UTF-8 in `buf`; null if it does not fit.
pub fn fromWide(buf: []u8, wide: []const u16) ?[]u8 {
    if (std.unicode.calcWtf8Len(wide) > buf.len) return null;
    return buf[0..std.unicode.wtf16LeToWtf8(buf, wide)];
}

/// Whether a batch file runs `path`: those are started through cmd.exe.
pub fn isBatchFile(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".cmd") or std.ascii.endsWithIgnoreCase(path, ".bat");
}

/// Appends `arg` to a command line so that the program gets it back
/// unchanged (the rules of CommandLineToArgvW and the C runtime). With
/// `for_cmd`, also quotes what cmd.exe would otherwise act on.
pub fn appendQuoted(gpa: Allocator, line: *std.ArrayList(u8), arg: []const u8, for_cmd: bool) Allocator.Error!void {
    const plain = " \t\"";
    const special = if (for_cmd) plain ++ "&|<>^()%!,;=" else plain;
    if (arg.len > 0 and std.mem.findAny(u8, arg, special) == null) return line.appendSlice(gpa, arg);
    try line.append(gpa, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
        } else {
            // Backslashes count as escapes only in front of a quote.
            if (c == '"') for (0..backslashes + 1) |_| try line.append(gpa, '\\');
            backslashes = 0;
        }
        try line.append(gpa, c);
    }
    for (0..backslashes) |_| try line.append(gpa, '\\');
    try line.append(gpa, '"');
}

/// The command line that starts `argv`, as NUL-terminated UTF-16. The
/// caller frees it.
pub fn commandLine(gpa: Allocator, argv: []const []const u8, for_cmd: bool) error{ OutOfMemory, InvalidWtf8 }![:0]u16 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    // cmd.exe /s strips one pair of quotes around the whole command.
    if (for_cmd) try line.appendSlice(gpa, "cmd.exe /d /s /c \"");
    for (argv, 0..) |arg, i| {
        if (i > 0) try line.append(gpa, ' ');
        try appendQuoted(gpa, &line, arg, for_cmd);
    }
    if (for_cmd) try line.append(gpa, '"');
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, line.items);
}

test appendQuoted {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, bool, []const u8 }{
        .{ "plain", false, "plain" },
        .{ "", false, "\"\"" },
        .{ "two words", false, "\"two words\"" },
        .{ "say \"hi\"", false, "\"say \\\"hi\\\"\"" },
        .{ "C:\\dir\\", false, "C:\\dir\\" },
        .{ "C:\\my dir\\", false, "\"C:\\my dir\\\\\"" },
        .{ "a\\\"b", false, "\"a\\\\\\\"b\"" },
        .{ "a&b", false, "a&b" },
        .{ "a&b", true, "\"a&b\"" },
    };
    for (cases) |case| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        try appendQuoted(gpa, &line, case[0], case[1]);
        try std.testing.expectEqualStrings(case[2], line.items);
    }
}

test commandLine {
    const gpa = std.testing.allocator;
    const line = try commandLine(gpa, &.{ "C:\\x\\npm.cmd", "create", "my app" }, true);
    defer gpa.free(line);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("cmd.exe /d /s /c \"C:\\x\\npm.cmd create \"my app\"\"", fromWide(&buf, line).?);
}

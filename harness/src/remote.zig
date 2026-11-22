//! Remote machines over SSH (environments.ini `kind = remote`, gap 2): a
//! command runs on a POSIX machine (Linux, macOS, BSD) through the
//! system's OpenSSH, with harness's own key for that environment (`harness
//! env key NAME`) and its host key kept once the owner confirmed it; never
//! the owner's keys, agent or ssh config. Harness doesn't speak SSH itself.
//!
//! A wrapper on the remote starts the command, reports its exit code, and
//! ends everything the command started when it ends or when ssh's input
//! closes: a stop or the time limit ends ssh here, the connection closes,
//! and the remote side goes with it.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const environments = @import("environments.zig");
const tools = @import("tools.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const is_windows = builtin.os.tag == .windows;

pub const Request = struct {
    env: *const environments.Env,
    command: []const u8,
    /// The environment's own folder (state/env/NAME): key, key.pub,
    /// known_hosts.
    dir: []const u8,
    /// PATH for ssh itself.
    path_var: []const u8,
    /// Windows: the system's own variables (ssh.exe needs them).
    system_vars: []const util.Var = &.{},
    /// Tests: a job of the caller's, left open.
    job: ?*proc.Job = null,
};

/// Tests: the ssh to run instead of the system's.
pub var ssh_override: ?[]const u8 = null;

/// Where the system's OpenSSH tools are (ssh, ssh-keygen, ssh-keyscan).
pub fn findTool(io: Io, arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, name, "ssh")) if (ssh_override) |o| return o;
    if (is_windows) {
        const sys = try proc.systemDir(arena);
        const p = try std.fmt.allocPrint(arena, "{s}\\OpenSSH\\{s}.exe", .{ sys, name });
        return if (exists(io, p)) p else null;
    }
    for ([_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin", "/opt/homebrew/bin" }) |d| {
        const p = try std.fs.path.join(arena, &.{ d, name });
        if (exists(io, p)) return p;
    }
    return null;
}

fn exists(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

pub fn keyPath(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ dir, "key" });
}

pub fn knownHostsPath(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ dir, "known_hosts" });
}

/// Why commands can't run on this remote yet; null when they can.
pub fn notReady(io: Io, arena: std.mem.Allocator, name: []const u8, dir: []const u8) !?[]const u8 {
    if (try findTool(io, arena, "ssh") == null) return "there is no ssh on this machine (OpenSSH's client)";
    if (!exists(io, try keyPath(arena, dir))) return try std.fmt.allocPrint(arena, "it has no key yet: run harness env key {s}", .{name});
    if (!exists(io, try knownHostsPath(arena, dir))) return try std.fmt.allocPrint(arena, "its host key isn't kept yet: run harness env key {s}", .{name});
    return null;
}

/// Runs on the remote as `sh -c WRAPPER harness-remote DIR COMMAND`.
/// The command's input is /dev/null; the watcher reads the session's own
/// (fd 3: an asynchronous list's input would be /dev/null) and ends the
/// whole process group when it closes. At the command's end what it left
/// is ended too, and its exit code is the session's.
const wrapper =
    \\exec 3<&0
    \\d=$1
    \\case $d in "~") d=$HOME ;; "~/"*) d=$HOME/${d#"~/"} ;; esac
    \\if [ -n "$d" ]; then cd "$d" || { echo "harness: no folder $d on the remote" >&2; exit 125; }; fi
    \\sh -c "$2" </dev/null 3<&- &
    \\p=$!
    \\(while read -r _; do :; done; kill -KILL 0) <&3 &
    \\exec 3<&-
    \\wait "$p"
    \\s=$?
    \\trap '' TERM
    \\kill -TERM 0 2>/dev/null
    \\exit "$s"
;

/// `s` as one word for a POSIX shell: in single quotes, a quote as '\''.
pub fn shQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |c| if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    try out.append(arena, '\'');
    return out.items;
}

/// What the remote's login shell is given: the wrapper, where to start,
/// the command; each one word.
pub fn remoteCommand(arena: std.mem.Allocator, dir: []const u8, command: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "exec sh -c {s} harness-remote {s} {s}", .{ try shQuote(arena, wrapper), try shQuote(arena, dir), try shQuote(arena, command) });
}

/// A path in an ssh option: forward slashes (OpenSSH reads `\` as an
/// escape there) in double quotes (a value with spaces is several files).
fn optPath(arena: std.mem.Allocator, key: []const u8, path: []const u8) ![]const u8 {
    const p = try arena.dupe(u8, path);
    if (is_windows) std.mem.replaceScalar(u8, p, '\\', '/');
    return std.fmt.allocPrint(arena, "{s}=\"{s}\"", .{ key, p });
}

/// ssh's arguments: no config file, no agent, no password, no
/// forwarding; this environment's key alone and its kept host key alone.
pub fn argv(arena: std.mem.Allocator, ssh: []const u8, req: Request) ![]const []const u8 {
    const kh = try knownHostsPath(arena, req.dir);
    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(arena, &.{ ssh, "-F", "none", "-T" });
    const opts = [_][]const u8{
        "BatchMode=yes",                              "IdentitiesOnly=yes",                           "IdentityAgent=none",
        try optPath(arena, "UserKnownHostsFile", kh), try optPath(arena, "GlobalKnownHostsFile", kh), "StrictHostKeyChecking=yes",
        "UpdateHostKeys=no",                          "PasswordAuthentication=no",                    "KbdInteractiveAuthentication=no",
        "ForwardAgent=no",                            "ForwardX11=no",                                "ClearAllForwardings=yes",
        "PermitLocalCommand=no",                      "ControlMaster=no",                             "ControlPath=none",
        "ConnectTimeout=15",                          "ServerAliveInterval=15",                       "ServerAliveCountMax=3",
    };
    for (opts) |o| try a.appendSlice(arena, &.{ "-o", o });
    try a.appendSlice(arena, &.{ "-i", try keyPath(arena, req.dir), "-p", try std.fmt.allocPrint(arena, "{d}", .{req.env.port}), req.env.host, try remoteCommand(arena, req.env.dir, req.command) });
    return a.items;
}

/// Runs `req.command` on the remote under `tenv`'s limits (time, output,
/// masking, stop), as the shell tool runs one on the host. Exit code 255
/// is ssh's own failure (its words follow); 125: no such folder there.
pub fn run(tenv: tools.Env, arena: std.mem.Allocator, req: Request) !tools.Output {
    std.debug.assert(req.env.kind == .remote);
    if (try notReady(tenv.io, arena, req.env.name, req.dir)) |why| return .{ .text = try std.fmt.allocPrint(arena, "not run: {s}", .{why}), .is_error = true };
    const ssh = (try findTool(tenv.io, arena, "ssh")).?;
    var vars = std.process.Environ.Map.init(arena);
    for (req.system_vars) |v| try vars.put(v.name, v.value);
    try vars.put("PATH", req.path_var);
    try vars.put("LANG", "C.UTF-8");
    var own_job = proc.Job.create();
    defer own_job.close();
    const job = req.job orelse &own_job;
    var child = try std.process.spawn(tenv.io, .{
        .argv = try argv(arena, ssh, req),
        .environ_map = &vars,
        // the remote watches it: closed, the remote side ends
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (is_windows) null else 0,
        .start_suspended = is_windows,
        .create_no_window = true,
    });
    job.adopt(&child);
    return tools.runChild(tenv, arena, &child, job);
}

// ---- the key and the host key (harness env key NAME) ----

pub const Key = struct {
    /// The line for the remote's ~/.ssh/authorized_keys.
    authorized: []const u8,
    /// `256 SHA256:... harness-NAME (ED25519)`.
    fingerprint: []const u8,
    /// Made now (else it was there).
    made: bool,
};

/// The environment's own key (ed25519, no passphrase, in its folder only),
/// made if there is none.
pub fn makeKey(io: Io, arena: std.mem.Allocator, name: []const u8, dir: []const u8) !Key {
    const keygen = (try findTool(io, arena, "ssh-keygen")) orelse return error.NoSshKeygen;
    try Io.Dir.cwd().createDirPath(io, dir);
    const key = try keyPath(arena, dir);
    const made = !exists(io, key);
    if (made) {
        const r = try std.process.run(arena, io, .{ .argv = &.{ keygen, "-q", "-t", "ed25519", "-N", "", "-C", try std.fmt.allocPrint(arena, "harness-{s}", .{name}), "-f", key } });
        if (!r.term.success()) return error.KeygenFailed;
    }
    const public = std.mem.trim(u8, try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.pub", .{key}), arena, .limited(16 << 10)), " \r\n");
    const fp = try std.process.run(arena, io, .{ .argv = &.{ keygen, "-l", "-f", try std.fmt.allocPrint(arena, "{s}.pub", .{key}) } });
    return .{
        // restrict: no forwarding, no terminal, whatever sshd allows by default
        .authorized = try std.fmt.allocPrint(arena, "restrict {s}", .{public}),
        .fingerprint = std.mem.trim(u8, fp.stdout, " \r\n"),
        .made = made,
    };
}

/// The host key a connection gets, as a known_hosts line, with its
/// fingerprint for the owner to compare; `why` is ssh's own words when no
/// key came (unreachable, refused).
pub const HostKeys = struct { lines: []const u8, fingerprints: []const u8, why: []const u8 = "" };

/// Asks the host for its key the way commands will connect: ssh itself
/// (Windows' ssh-keyscan can't do the exchange recent servers offer),
/// taking a new key into a scratch file only; nothing is kept here.
pub fn scanHost(io: Io, arena: std.mem.Allocator, env: *const environments.Env, dir: []const u8, path_var: []const u8, system_vars: []const util.Var) !HostKeys {
    const ssh = (try findTool(io, arena, "ssh")) orelse return error.NoSsh;
    const keygen = (try findTool(io, arena, "ssh-keygen")) orelse return error.NoSshKeygen;
    try Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fs.path.join(arena, &.{ dir, "known_hosts.scan" });
    Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    var vars = std.process.Environ.Map.init(arena);
    for (system_vars) |v| try vars.put(v.name, v.value);
    try vars.put("PATH", path_var);
    const r = try std.process.run(arena, io, .{
        .argv = &.{
            ssh,      "-F",                                          "none", "-T",
            "-o",     "BatchMode=yes",                               "-o",   "StrictHostKeyChecking=accept-new",
            "-o",     try optPath(arena, "UserKnownHostsFile", tmp), "-o",   try optPath(arena, "GlobalKnownHostsFile", tmp),
            "-o",     "HashKnownHosts=no",                           "-o",   "IdentitiesOnly=yes",
            "-o",     "IdentityAgent=none",                          "-o",   "PasswordAuthentication=no",
            "-o",     "KbdInteractiveAuthentication=no",             "-o",   "ConnectTimeout=10",
            "-i",     try keyPath(arena, dir),                       "-p",   try std.fmt.allocPrint(arena, "{d}", .{env.port}),
            env.host, "exit",
        },
        .environ_map = &vars,
    });
    const got = Io.Dir.cwd().readFileAlloc(io, tmp, arena, .limited(64 << 10)) catch "";
    var lines: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \r");
        if (l.len == 0 or l[0] == '#') continue;
        try lines.print(arena, "{s}\n", .{l});
    }
    if (lines.items.len == 0) return .{ .lines = "", .fingerprints = "", .why = std.mem.trim(u8, r.stderr, " \r\n") };
    const fp = try std.process.run(arena, io, .{ .argv = &.{ keygen, "-l", "-f", tmp } });
    return .{ .lines = lines.items, .fingerprints = std.mem.trim(u8, fp.stdout, " \r\n") };
}

/// Keeps the host keys the owner confirmed: only they are accepted.
pub fn keepHostKeys(io: Io, arena: std.mem.Allocator, dir: []const u8, lines: []const u8) !void {
    const path = try knownHostsPath(arena, dir);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = lines });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

// ---- tests ----

const t = std.testing;

fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (!has(text, part)) {
        std.debug.print("expected {s} in:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

test "remote_ssh_command_is_locked_down" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: environments.Env = .{ .name = "buildbox", .line = 1, .kind = .remote, .host = "agent@10.0.0.5", .port = 2222, .dir = "/home/agent/work" };
    const dir = if (is_windows) "C:\\Users\\Some One\\harness\\state\\env\\buildbox" else "/data/state/env/buildbox";
    const args = try argv(a, "ssh", .{ .env = &env, .command = "echo it's here", .dir = dir, .path_var = "" });
    const line = try std.mem.join(a, " ", args);
    for ([_][]const u8{ "-F none", "-T", "BatchMode=yes", "IdentitiesOnly=yes", "IdentityAgent=none", "StrictHostKeyChecking=yes", "PasswordAuthentication=no", "ForwardAgent=no", "ClearAllForwardings=yes", "ControlPath=none", "-p 2222" }) |want| try expectHas(line, want);
    const kh = if (is_windows) "UserKnownHostsFile=\"C:/Users/Some One/harness/state/env/buildbox/known_hosts\"" else "UserKnownHostsFile=\"/data/state/env/buildbox/known_hosts\"";
    try expectHas(line, kh);
    // its own key, the host, then the one command for the remote's shell
    try t.expectEqualStrings("-i", args[args.len - 6]);
    try t.expectEqualStrings(try keyPath(a, dir), args[args.len - 5]);
    try t.expectEqualStrings("2222", args[args.len - 3]);
    try t.expectEqualStrings("agent@10.0.0.5", args[args.len - 2]);
    const remote = args[args.len - 1];
    try t.expect(std.mem.startsWith(u8, remote, "exec sh -c '"));
    try t.expect(std.mem.endsWith(u8, remote, "harness-remote '/home/agent/work' 'echo it'\\''s here'"));
}

/// Runs `remote_command` the way a remote's login shell would (`sh -c`),
/// here, with its input a pipe that stays open unless `close_after_ms`.
fn asRemoteShell(a: std.mem.Allocator, remote_command: []const u8, close_after_ms: ?u32) !struct { out: []const u8, code: u8 } {
    // a group of its own, as sshd gives a session: the wrapper's `kill 0`
    // must not reach the tests
    var child = try std.process.spawn(t.io, .{ .argv = &.{ "/bin/sh", "-c", remote_command }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .pgid = 0 });
    const stdin = child.stdin.?;
    child.stdin = null;
    if (close_after_ms) |ms| {
        t.io.sleep(.fromMilliseconds(ms), .awake) catch {};
        stdin.close(t.io);
    }
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = child.stdout.?.readStreaming(t.io, &.{buf[n..]}) catch break;
        if (got == 0) break;
        n += got;
    }
    const term = try child.wait(t.io);
    if (close_after_ms == null) stdin.close(t.io);
    return .{ .out = try a.dupe(u8, buf[0..n]), .code = switch (term) {
        .exited => |c| c,
        else => 255,
    } };
}

test "the_wrapper_starts_where_it_is_told_quotes_right_and_returns_the_exit_code" {
    if (is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try asRemoteShell(a, try remoteCommand(a, "/tmp", "pwd; printf '%s\\n' \"it's\" 'a \"b\"'; exit 3"), null);
    try t.expectEqual(3, r.code);
    try t.expectEqualStrings("/tmp\nit's\na \"b\"\n", r.out);
    // a folder that isn't there: 125
    const missing = try asRemoteShell(a, try remoteCommand(a, "/no/such/folder-91", "echo never"), null);
    try t.expectEqual(125, missing.code);
    try t.expect(!has(missing.out, "never"));
}

test "the_wrapper_ends_what_the_command_started_when_its_input_closes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const started = Io.Clock.awake.now(t.io);
    _ = try asRemoteShell(a, try remoteCommand(a, "", "sleep 32.3 >/dev/null & setsid sleep 32.3 >/dev/null & sleep 32.3"), 600);
    try t.expect(started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 3000);
    // the one that left the group (setsid) is the one a wrapper can't end
    try expectGone("32.3", 1);
    // at its own end too: what the command left in the background goes
    _ = try asRemoteShell(a, try remoteCommand(a, "", "sleep 32.4 & echo done"), null);
    try expectGone("32.4", 0);
}

/// At most `allowed` processes with `marker` in their command line remain
/// (within 2 s); those are ended.
fn expectGone(marker: []const u8, allowed: usize) !void {
    var waited: u32 = 0;
    var left: usize = 0;
    while (waited <= 2000) : (waited += 50) {
        left = try countProcesses(marker, false);
        if (left <= allowed) break;
        t.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    _ = try countProcesses(marker, true);
    if (left > allowed) {
        std.debug.print("{d} processes with {s} left\n", .{ left, marker });
        return error.TestUnexpectedResult;
    }
}

fn countProcesses(marker: []const u8, kill: bool) !usize {
    return if (builtin.os.tag == .linux) countLinux(marker, kill) else 0;
}

fn countLinux(marker: []const u8, kill: bool) !usize {
    var d = try Io.Dir.cwd().openDir(t.io, "/proc", .{ .iterate = true });
    defer d.close(t.io);
    var it = d.iterate();
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (try it.next(t.io)) |e| {
        if (e.name.len == 0 or !std.ascii.isDigit(e.name[0])) continue;
        var pb: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "/proc/{s}/cmdline", .{e.name}) catch continue;
        const got = Io.Dir.cwd().readFile(t.io, p, &buf) catch continue;
        if (std.mem.indexOf(u8, got, marker) == null) continue;
        // a zombie has an empty command line; this one is running
        n += 1;
        if (kill) std.posix.kill(std.fmt.parseInt(std.posix.pid_t, e.name, 10) catch continue, .KILL) catch {};
    }
    return n;
}

/// A sshd of the test's own on 127.0.0.1 (Linux, when sshd is here), the
/// environment's key authorized there, its host key kept by scanHost.
const Sshd = struct {
    tmp: t.TmpDir,
    child: std.process.Child,
    port: u16,
    dir: []const u8,
    env: environments.Env,

    fn start(s: *Sshd, a: std.mem.Allocator) !void {
        if (builtin.os.tag != .linux) return error.SkipZigTest;
        const io = t.io;
        if (!exists(io, "/usr/sbin/sshd")) return error.SkipZigTest;
        s.tmp = t.tmpDir(.{});
        errdefer s.tmp.cleanup();
        const root = try s.tmp.dir.realPathFileAlloc(io, ".", a);
        s.dir = try std.fs.path.join(a, &.{ root, "env", "box" });
        const key = try makeKey(io, a, "box", s.dir);
        try t.expect(key.made);
        try t.expect(has(key.fingerprint, "harness-box"));
        const host_key = try std.fs.path.join(a, &.{ root, "host_key" });
        const keygen = (try findTool(io, a, "ssh-keygen")).?;
        _ = try std.process.run(a, io, .{ .argv = &.{ keygen, "-q", "-t", "ed25519", "-N", "", "-f", host_key } });
        const auth = try std.fs.path.join(a, &.{ root, "authorized_keys" });
        try s.tmp.dir.writeFile(io, .{ .sub_path = "authorized_keys", .data = try std.fmt.allocPrint(a, "{s}\n", .{key.authorized}) });
        // a free port: one a listener got, given back
        const l = try @import("sock.zig").Listener.open(0);
        s.port = l.port;
        l.close();
        const config = try std.fmt.allocPrint(a,
            \\Port {d}
            \\ListenAddress 127.0.0.1
            \\HostKey {s}
            \\AuthorizedKeysFile {s}
            \\PidFile none
            \\StrictModes no
            \\UsePAM no
            \\PasswordAuthentication no
            \\KbdInteractiveAuthentication no
            \\LogLevel ERROR
            \\
        , .{ s.port, host_key, auth });
        try s.tmp.dir.writeFile(io, .{ .sub_path = "sshd_config", .data = config });
        s.child = try std.process.spawn(io, .{ .argv = &.{ "/usr/sbin/sshd", "-D", "-e", "-f", try std.fs.path.join(a, &.{ root, "sshd_config" }) }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        // up when it answers
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            const h = @import("sock.zig").connect(io, "127.0.0.1", s.port, 500) catch {
                io.sleep(.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            @import("sock.zig").closeHandle(h);
            break;
        } else return error.SkipZigTest;
        const user = std.mem.trim(u8, (try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/id", "-un" } })).stdout, " \n");
        s.env = .{ .name = "box", .line = 1, .kind = .remote, .host = try std.fmt.allocPrint(a, "{s}@127.0.0.1", .{user}), .port = s.port, .dir = root };
        const hk = try scanHost(io, a, &s.env, s.dir, "/usr/bin:/bin", &.{});
        if (hk.lines.len == 0) std.debug.print("no host key: {s}\n", .{hk.why});
        try t.expect(has(hk.fingerprints, "SHA256:"));
        try t.expect(has(hk.lines, try std.fmt.allocPrint(a, "[127.0.0.1]:{d} ", .{s.port})));
        try keepHostKeys(io, a, s.dir, hk.lines);
    }

    fn stop(s: *Sshd) void {
        s.child.kill(t.io);
        s.tmp.cleanup();
    }
};

test "remote_stop_ends_the_remote_command" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Sshd = undefined;
    try s.start(a);
    defer s.stop();
    var stop: std.atomic.Value(bool) = .init(false);
    const tenv: tools.Env = .{ .gpa = t.allocator, .io = t.io, .workspace = "", .stop = &stop, .shell_seconds = 30 };
    // exit codes come back, and it starts in dir
    const r = try run(tenv, a, .{ .env = &s.env, .command = "pwd; echo it\\'s; exit 4", .dir = s.dir, .path_var = "/usr/bin:/bin" });
    try expectHas(r.text, "exit code 4");
    try expectHas(r.text, s.env.dir);
    try expectHas(r.text, "it's");
    try t.expect(r.is_error);
    // a stop ends it, and what it started there
    const Stopper = struct {
        fn go(flag: *std.atomic.Value(bool)) void {
            t.io.sleep(.fromMilliseconds(1000), .awake) catch {};
            flag.store(true, .release);
        }
    };
    const started = Io.Clock.awake.now(t.io);
    const th = try std.Thread.spawn(.{}, Stopper.go, .{&stop});
    const o = try run(tenv, a, .{ .env = &s.env, .command = "sleep 33.7 & sleep 33.7", .dir = s.dir, .path_var = "/usr/bin:/bin" });
    th.join();
    try expectHas(o.text, "stopped by the owner");
    try t.expect(started.durationTo(Io.Clock.awake.now(t.io)).toMilliseconds() < 1000 + 2300);
    try expectGone("33.7", 0);
    // a host key that isn't the kept one is refused: the kept line names
    // this host, with another machine's key
    const other = try std.fs.path.join(a, &.{ s.dir, "other" });
    _ = try std.process.run(a, t.io, .{ .argv = &.{ (try findTool(t.io, a, "ssh-keygen")).?, "-q", "-t", "ed25519", "-N", "", "-f", other } });
    const other_pub = std.mem.trim(u8, try Io.Dir.cwd().readFileAlloc(t.io, try std.fmt.allocPrint(a, "{s}.pub", .{other}), a, .limited(4096)), " \n");
    const parts = std.mem.indexOfScalarPos(u8, other_pub, std.mem.indexOfScalar(u8, other_pub, ' ').? + 1, ' ') orelse other_pub.len;
    try keepHostKeys(t.io, a, s.dir, try std.fmt.allocPrint(a, "[127.0.0.1]:{d} {s}\n", .{ s.port, other_pub[0..parts] }));
    stop.store(false, .release);
    const refused = try run(tenv, a, .{ .env = &s.env, .command = "echo should-not-run", .dir = s.dir, .path_var = "/usr/bin:/bin" });
    try t.expect(refused.is_error);
    try expectHas(refused.text, "exit code 255");
    try t.expect(!has(refused.text, "should-not-run"));
}

test "a_remote_without_its_key_or_host_key_is_refused_plainly" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var stop: std.atomic.Value(bool) = .init(false);
    const tenv: tools.Env = .{ .gpa = t.allocator, .io = t.io, .workspace = "", .stop = &stop };
    const env: environments.Env = .{ .name = "buildbox", .line = 1, .kind = .remote, .host = "agent@192.0.2.1" };
    ssh_override = if (is_windows) "C:\\Windows\\System32\\whoami.exe" else "/bin/true";
    defer ssh_override = null;
    const o = try run(tenv, a, .{ .env = &env, .command = "echo x", .dir = dir, .path_var = "" });
    try t.expect(o.is_error);
    try expectHas(o.text, "not run: it has no key yet: run harness env key buildbox");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "key", .data = "not a real key" });
    try expectHas((try run(tenv, a, .{ .env = &env, .command = "echo x", .dir = dir, .path_var = "" })).text, "its host key isn't kept yet");
}

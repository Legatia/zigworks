//! tasks.ini's `do_file = NAME.md`: a task's instructions in a file of
//! their own, `tasks/NAME.md`, read whole (an imported Hermes prompt that
//! one `do =` line would cut: ` ;`, ` #`, several lines). The `tasks/`
//! folder decides what runs unattended, so it is guarded like
//! `workflows/`: on Linux and macOS neither it nor a file in it may be
//! writable by others.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const Io = std.Io;

/// Longest instructions file read.
pub const max_file = 64 * 1024;

/// Fills each task's `do` from its `do_file` in `dir` (tasks/), whole;
/// the folder and the files checked as `workflows/` is. Returns what is
/// wrong, said so the owner can fix it, or null. Tasks without a
/// `do_file` are left as they are, and so is the folder when none has one.
pub fn resolve(io: Io, a: std.mem.Allocator, dir: []const u8, tasks: []config.Task) !?[]const u8 {
    var checked = false;
    for (tasks) |*tk| {
        if (tk.do_file.len == 0) continue;
        if (!checked and guarded) {
            checked = true;
            const st = Io.Dir.cwd().statFile(io, dir, .{}) catch |e| switch (e) {
                error.FileNotFound => return try std.fmt.allocPrint(a, "tasks.ini: task {s} names tasks/{s}, which can't be read (there is no tasks folder)", .{ tk.name, tk.do_file }),
                else => return try std.fmt.allocPrint(a, "tasks can't be read ({s})", .{@errorName(e)}),
            };
            if (st.permissions.toMode() & 0o022 != 0) return "tasks can be changed by other users; run chmod go-w on it (it decides what runs)";
        }
        const path = try std.fs.path.join(a, &.{ dir, tk.do_file });
        if (guarded) {
            const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e|
                return try std.fmt.allocPrint(a, "tasks.ini: task {s} names tasks/{s}, which can't be read ({s})", .{ tk.name, tk.do_file, @errorName(e) });
            if (st.permissions.toMode() & 0o022 != 0) return try std.fmt.allocPrint(a, "tasks/{s} can be changed by other users; run chmod 600 on it", .{tk.do_file});
        }
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file + 1)) catch |e| switch (e) {
            error.StreamTooLong => return try std.fmt.allocPrint(a, "tasks/{s} is over 64 KB", .{tk.do_file}),
            error.OutOfMemory => return error.OutOfMemory,
            else => return try std.fmt.allocPrint(a, "tasks.ini: task {s} names tasks/{s}, which can't be read ({s})", .{ tk.name, tk.do_file, @errorName(e) }),
        };
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return try std.fmt.allocPrint(a, "tasks/{s} is empty: task {s} has nothing to do", .{ tk.do_file, tk.name });
        tk.do = text;
    }
    return null;
}

/// Linux and macOS: the folder and its files may be written by the owner alone.
const guarded = builtin.os.tag != .windows;

const t = std.testing;

fn fixture(tmp: *t.TmpDir, a: std.mem.Allocator) ![]const u8 {
    try tmp.dir.createDirPath(t.io, "tasks");
    return tmp.dir.realPathFileAlloc(t.io, "tasks", a);
}

test "do_file_is_read_whole" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try fixture(&tmp, a);
    const text = "Check the feeds ; then the inbox #now\n\n  Second paragraph, indented.\r\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tasks/brief.md", .data = text });
    var tasks = [_]config.Task{ .{ .name = "brief", .do_file = "brief.md" }, .{ .name = "plain", .do = "Say hi." } };
    try t.expect(try resolve(t.io, a, dir, &tasks) == null);
    try t.expectEqualStrings(text, tasks[0].do);
    try t.expectEqualStrings("Say hi.", tasks[1].do);
}

test "a_missing_do_file_is_a_settings_problem" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try fixture(&tmp, a);
    var tasks = [_]config.Task{.{ .name = "brief", .do_file = "brief.md" }};
    const why = (try resolve(t.io, a, dir, &tasks)).?;
    try t.expect(std.mem.indexOf(u8, why, "tasks.ini: task brief names tasks/brief.md, which can't be read") != null);
    // an empty one says nothing to do
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tasks/brief.md", .data = " \n" });
    try t.expect(std.mem.indexOf(u8, (try resolve(t.io, a, dir, &tasks)).?, "tasks/brief.md is empty") != null);
}

test "a_tasks_folder_others_can_write_is_refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try fixture(&tmp, a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tasks/brief.md", .data = "Do it." });
    var tasks = [_]config.Task{.{ .name = "brief", .do_file = "brief.md" }};
    {
        var d = try tmp.dir.openDir(t.io, "tasks", .{ .iterate = true });
        defer d.close(t.io);
        try d.setPermissions(t.io, .fromMode(0o777));
    }
    try t.expect(std.mem.indexOf(u8, (try resolve(t.io, a, dir, &tasks)).?, "tasks can be changed by other users") != null);
    {
        var d = try tmp.dir.openDir(t.io, "tasks", .{ .iterate = true });
        defer d.close(t.io);
        try d.setPermissions(t.io, .fromMode(0o700));
    }
    {
        var f = try tmp.dir.openFile(t.io, "tasks/brief.md", .{});
        defer f.close(t.io);
        try f.setPermissions(t.io, .fromMode(0o666));
    }
    try t.expect(std.mem.indexOf(u8, (try resolve(t.io, a, dir, &tasks)).?, "tasks/brief.md can be changed by other users") != null);
}

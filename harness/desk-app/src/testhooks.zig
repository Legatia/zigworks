//! In a build with test hooks only (`-Dtest-hooks`): the smoke drives the
//! app through `TESTDIR/commands`, one per line, and reads what it did in
//! `TESTDIR/log`. External links are logged there instead of opened.
const std = @import("std");
const Io = std.Io;
const MenuItem = @import("controller.zig").MenuItem;

pub const Command = union(enum) {
    /// Run this in the page's main frame.
    js: []const u8,
    menu: MenuItem,
    /// Set the window's frame: x, y (from the bottom left), width, height.
    frame: [4]f64,
    log_frame,
    /// The key sheet: filled with the test build's fake key and saved, or
    /// cancelled.
    key: KeyAction,
    quit,
};

pub const KeyAction = enum { fill, cancel };

pub fn parseCommand(raw: []const u8) ?Command {
    const line = std.mem.trimEnd(u8, raw, "\r\n");
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const word = line[0 .. sp orelse line.len];
    const rest = if (sp) |i| line[i + 1 ..] else "";
    if (std.mem.eql(u8, word, "js")) return if (rest.len > 0) .{ .js = rest } else null;
    if (std.mem.eql(u8, word, "menu")) return .{ .menu = std.meta.stringToEnum(MenuItem, rest) orelse return null };
    if (std.mem.eql(u8, word, "frame")) {
        var f: [4]f64 = undefined;
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        for (&f) |*v| v.* = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
        if (it.next() != null) return null;
        return .{ .frame = f };
    }
    if (std.mem.eql(u8, word, "key")) return .{ .key = std.meta.stringToEnum(KeyAction, rest) orelse return null };
    if (std.mem.eql(u8, line, "log-frame")) return .log_frame;
    if (std.mem.eql(u8, line, "quit")) return .quit;
    return null;
}

/// The log and the command file. Used on the main thread only.
pub const Hooks = struct {
    io: Io,
    log_path: []const u8,
    commands_path: []const u8,
    /// How much of the command file has been read.
    read_to: usize = 0,

    pub fn open(io: Io, a: std.mem.Allocator, dir: []const u8) !Hooks {
        try Io.Dir.cwd().createDirPath(io, dir);
        const h: Hooks = .{
            .io = io,
            .log_path = try std.fs.path.join(a, &.{ dir, "log" }),
            .commands_path = try std.fs.path.join(a, &.{ dir, "commands" }),
        };
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = h.log_path, .data = "" });
        return h;
    }

    /// One line in the log, written at once.
    pub fn log(h: *Hooks, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        var f = Io.Dir.cwd().openFile(h.io, h.log_path, .{ .mode = .write_only }) catch return;
        defer f.close(h.io);
        const end = f.length(h.io) catch return;
        f.writePositionalAll(h.io, line, end) catch {};
    }

    /// The whole lines added to the command file since the last call.
    pub fn take(h: *Hooks, a: std.mem.Allocator) ![]Command {
        const text = Io.Dir.cwd().readFileAlloc(h.io, h.commands_path, a, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        var out: std.ArrayList(Command) = .empty;
        while (h.read_to < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, h.read_to, '\n') orelse break;
            if (parseCommand(text[h.read_to..nl])) |c| try out.append(a, c) else h.log("unknown {s}", .{text[h.read_to..nl]});
            h.read_to = nl + 1;
        }
        return out.toOwnedSlice(a);
    }
};

const t = std.testing;

test "commands_parse" {
    try t.expectEqualStrings("document.getElementById('start').click()", parseCommand("js document.getElementById('start').click()").?.js);
    try t.expectEqual(MenuItem.autostart, parseCommand("menu autostart").?.menu);
    try t.expectEqual(MenuItem.stop, parseCommand("menu stop\r").?.menu);
    const f = parseCommand("frame 100 120.5 1100 750").?.frame;
    try t.expectEqual([4]f64{ 100, 120.5, 1100, 750 }, f);
    try t.expect(parseCommand("quit").? == .quit);
    try t.expect(parseCommand("log-frame").? == .log_frame);
    for ([_][]const u8{ "", "menu", "menu nope", "frame 1 2 3", "frame a b c d", "js", "dance" }) |line| {
        try t.expect(parseCommand(line) == null);
    }
}

test "key_commands_parse" {
    // the sheet is filled with the build's own fake key, never one from the
    // command file
    try t.expectEqual(KeyAction.fill, parseCommand("key fill").?.key);
    try t.expectEqual(KeyAction.cancel, parseCommand("key cancel").?.key);
    try t.expect(parseCommand("key sk-test-not-a-key") == null);
    try t.expect(parseCommand("key") == null);
    try t.expectEqual(MenuItem.provider, parseCommand("menu provider").?.menu);
}

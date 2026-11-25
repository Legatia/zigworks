//! `state/desk.json`, which harness writes at each start: where its binary
//! is, the port of its app server, its data folder and its version, and
//! (optionally) the PATH it was started with.
const std = @import("std");
const Io = std.Io;

pub const Desk = struct {
    /// The harness program; "" when not given (no commands can be run).
    binary: []const u8 = "",
    port: u16,
    home: []const u8 = "",
    version: []const u8 = "",
    /// The PATH harness was started with: the commands the app runs get it,
    /// since an app opened from the Dock has launchd's short one.
    path: []const u8 = "",
};

/// Strings in the result are allocated in `a` (an arena is expected).
pub fn parse(a: std.mem.Allocator, text: []const u8) error{ BadDesk, OutOfMemory }!Desk {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadDesk,
    };
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadDesk,
    };
    const port: u16 = switch (obj.get("port") orelse return error.BadDesk) {
        .integer => |n| if (n >= 1 and n <= 65535) @intCast(n) else return error.BadDesk,
        else => return error.BadDesk,
    };
    var d: Desk = .{ .port = port };
    inline for (.{ "binary", "home", "version", "path" }) |name| {
        if (obj.get(name)) |f| switch (f) {
            .string => |s| @field(d, name) = s,
            .null => {},
            else => return error.BadDesk,
        };
    }
    return d;
}

/// `HOME/state/desk.json`; null when it isn't there (harness never ran).
pub fn read(io: Io, a: std.mem.Allocator, home: []const u8) !?Desk {
    const p = try std.fs.path.join(a, &.{ home, "state", "desk.json" });
    const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        error.StreamTooLong => return error.BadDesk,
        else => return e,
    };
    return try parse(a, text);
}

const t = std.testing;

test "full_and_minimal_files_parse" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try parse(a,
        \\{"binary": "/usr/local/bin/harness", "port": 41234, "home": "/Users/me/.local/share/harness",
        \\ "version": "0.3.0", "path": "/opt/homebrew/bin:/usr/bin:/bin"}
    );
    try t.expectEqualStrings("/usr/local/bin/harness", full.binary);
    try t.expectEqual(@as(u16, 41234), full.port);
    try t.expectEqualStrings("/Users/me/.local/share/harness", full.home);
    try t.expectEqualStrings("0.3.0", full.version);
    try t.expectEqualStrings("/opt/homebrew/bin:/usr/bin:/bin", full.path);

    const min = try parse(a, "{\"port\": 8080}");
    try t.expectEqual(@as(u16, 8080), min.port);
    try t.expectEqualStrings("", min.binary);
    try t.expectEqualStrings("", min.path);
}

test "a_bad_port_or_no_port_is_refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{}",
        "{\"port\": 0}",
        "{\"port\": 70000}",
        "{\"port\": -1}",
        "{\"port\": \"8080\"}",
        "{\"port\": 80.5}",
        "{\"port\": 8080, \"binary\": 3}",
        "[8080]",
        "not json",
        "",
    }) |text| {
        try t.expectError(error.BadDesk, parse(a, text));
    }
}

test "unknown_fields_are_ignored" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(), "{\"port\": 9000, \"started\": 1732500000, \"pid\": 77, \"extra\": {\"x\": [1]}}");
    try t.expectEqual(@as(u16, 9000), d.port);
}

test "read_says_missing_as_null" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(t.io, ".", a);

    try t.expect((try read(t.io, a, home)) == null);

    try tmp.dir.createDirPath(t.io, "state");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/desk.json", .data = "{\"port\": 5555, \"binary\": \"/bin/harness\"}" });
    const d = (try read(t.io, a, home)).?;
    try t.expectEqual(@as(u16, 5555), d.port);
    try t.expectEqualStrings("/bin/harness", d.binary);

    try tmp.dir.writeFile(t.io, .{ .sub_path = "state/desk.json", .data = "{\"port\": " });
    try t.expectError(error.BadDesk, read(t.io, a, home));
}

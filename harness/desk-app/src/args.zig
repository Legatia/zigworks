//! The app's command line: `--home DIR` (from `harness open`) and, in a
//! build with test hooks, `--test-dir DIR`. Anything else is ignored:
//! Finder and AppKit add arguments of their own (`-psn_…`, `-NS… YES`).
const std = @import("std");

pub const Args = struct {
    home: ?[]const u8 = null,
    test_dir: ?[]const u8 = null,
};

/// `argv` includes the program's own name first.
pub fn parse(argv: []const []const u8) Args {
    var out: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        inline for (.{ .{ "--home", "home" }, .{ "--test-dir", "test_dir" } }) |flag| {
            if (std.mem.eql(u8, arg, flag[0])) {
                if (i + 1 < argv.len) {
                    i += 1;
                    if (argv[i].len > 0) @field(out, flag[1]) = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, flag[0] ++ "=")) {
                const v = arg[flag[0].len + 1 ..];
                if (v.len > 0) @field(out, flag[1]) = v;
            }
        }
    }
    return out;
}

const t = std.testing;

test "home_and_test_dir_are_read_and_others_ignored" {
    const a = parse(&.{ "harness-desk", "-psn_0_12345", "--home", "/tmp/h", "-NSDocumentRevisionsDebugMode", "YES", "--test-dir=/tmp/t" });
    try t.expectEqualStrings("/tmp/h", a.home.?);
    try t.expectEqualStrings("/tmp/t", a.test_dir.?);

    const b = parse(&.{ "harness-desk", "--home=/one", "--home", "/two" });
    try t.expectEqualStrings("/two", b.home.?);
    try t.expect(b.test_dir == null);

    // a flag with nothing after it, or an empty value, sets nothing
    const c = parse(&.{ "harness-desk", "--home=", "--home" });
    try t.expect(c.home == null);
    try t.expect(parse(&.{"harness-desk"}).home == null);
}

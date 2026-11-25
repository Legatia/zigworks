//! The data folder the app looks in when `harness open` didn't name one:
//! the same order harness itself follows (main.zig's defaultHome).
const std = @import("std");

/// HARNESS_HOME, else `$XDG_DATA_HOME/harness`, else
/// `$HOME/.local/share/harness`; empty values count as unset.
pub fn default(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("HARNESS_HOME")) |h| if (h.len > 0) return a.dupe(u8, h);
    if (env.get("XDG_DATA_HOME")) |x| if (x.len > 0) return std.fs.path.join(a, &.{ x, "harness" });
    const home = env.get("HOME") orelse return error.NoHomeDirectory;
    if (home.len == 0) return error.NoHomeDirectory;
    return std.fs.path.join(a, &.{ home, ".local", "share", "harness" });
}

const t = std.testing;

test "default_follows_harness_order" {
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try t.expectError(error.NoHomeDirectory, default(t.allocator, &env));

    try env.put("HOME", "/Users/me");
    const plain = try default(t.allocator, &env);
    defer t.allocator.free(plain);
    try t.expectEqualStrings("/Users/me/.local/share/harness", plain);

    try env.put("XDG_DATA_HOME", "/data");
    const xdg = try default(t.allocator, &env);
    defer t.allocator.free(xdg);
    try t.expectEqualStrings("/data/harness", xdg);

    try env.put("HARNESS_HOME", "/elsewhere");
    const named = try default(t.allocator, &env);
    defer t.allocator.free(named);
    try t.expectEqualStrings("/elsewhere", named);

    // empty values count as unset
    try env.put("HARNESS_HOME", "");
    try env.put("XDG_DATA_HOME", "");
    const back = try default(t.allocator, &env);
    defer t.allocator.free(back);
    try t.expectEqualStrings("/Users/me/.local/share/harness", back);
}

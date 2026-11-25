//! The data folder the app looks in when `harness open` didn't name one:
//! the same order harness itself follows (main.zig's defaultHome).
const std = @import("std");

/// HARNESS_HOME, else `$XDG_DATA_HOME/harness`, else
/// `$HOME/.local/share/harness`; on Windows HARNESS_HOME, else
/// `%LOCALAPPDATA%\harness`. Empty values count as unset.
pub fn default(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    return defaultOn(a, env, @import("builtin").os.tag == .windows);
}

/// `default`, as on Windows or as elsewhere (tests ask for both).
pub fn defaultOn(a: std.mem.Allocator, env: *const std.process.Environ.Map, windows: bool) ![]u8 {
    if (env.get("HARNESS_HOME")) |h| if (h.len > 0) return a.dupe(u8, h);
    if (windows) {
        const base = env.get("LOCALAPPDATA") orelse return error.NoHomeDirectory;
        if (base.len == 0) return error.NoHomeDirectory;
        return std.fmt.allocPrint(a, "{s}\\harness", .{std.mem.trimEnd(u8, base, "\\/")});
    }
    if (env.get("XDG_DATA_HOME")) |x| if (x.len > 0) return std.fmt.allocPrint(a, "{s}/harness", .{std.mem.trimEnd(u8, x, "/")});
    const home = env.get("HOME") orelse return error.NoHomeDirectory;
    if (home.len == 0) return error.NoHomeDirectory;
    return std.fmt.allocPrint(a, "{s}/.local/share/harness", .{std.mem.trimEnd(u8, home, "/")});
}

const t = std.testing;

test "default_follows_harness_order" {
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try t.expectError(error.NoHomeDirectory, defaultOn(t.allocator, &env, false));

    try env.put("HOME", "/Users/me");
    const plain = try defaultOn(t.allocator, &env, false);
    defer t.allocator.free(plain);
    try t.expectEqualStrings("/Users/me/.local/share/harness", plain);

    try env.put("XDG_DATA_HOME", "/data");
    const xdg = try defaultOn(t.allocator, &env, false);
    defer t.allocator.free(xdg);
    try t.expectEqualStrings("/data/harness", xdg);

    try env.put("HARNESS_HOME", "/elsewhere");
    const named = try defaultOn(t.allocator, &env, false);
    defer t.allocator.free(named);
    try t.expectEqualStrings("/elsewhere", named);

    // empty values count as unset
    try env.put("HARNESS_HOME", "");
    try env.put("XDG_DATA_HOME", "");
    const back = try defaultOn(t.allocator, &env, false);
    defer t.allocator.free(back);
    try t.expectEqualStrings("/Users/me/.local/share/harness", back);
}

test "on_windows_the_default_is_under_localappdata" {
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    // HOME and XDG_DATA_HOME are not Windows' to go by
    try env.put("HOME", "/Users/me");
    try env.put("XDG_DATA_HOME", "/data");
    try t.expectError(error.NoHomeDirectory, defaultOn(t.allocator, &env, true));

    try env.put("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local");
    const plain = try defaultOn(t.allocator, &env, true);
    defer t.allocator.free(plain);
    try t.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\harness", plain);

    try env.put("HARNESS_HOME", "D:\\elsewhere");
    const named = try defaultOn(t.allocator, &env, true);
    defer t.allocator.free(named);
    try t.expectEqualStrings("D:\\elsewhere", named);

    try env.put("HARNESS_HOME", "");
    const back = try defaultOn(t.allocator, &env, true);
    defer t.allocator.free(back);
    try t.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\harness", back);
}

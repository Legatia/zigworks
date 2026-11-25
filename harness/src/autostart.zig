//! `harness autostart on|off`: `harness --home DIR run` at login (a
//! LaunchAgent on macOS, the HKCU Run key on Windows, an XDG autostart
//! entry on Linux); and where `harness open` looks for the desk app
//! (`harness-desk`). The texts and paths here; main.zig writes them.
const std = @import("std");

/// The LaunchAgent's label (and its file's name).
pub const launch_label = "com.legatia.harness";

/// `~/Library/LaunchAgents/com.legatia.harness.plist`.
pub fn launchAgentPath(a: std.mem.Allocator, user_home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/Library/LaunchAgents/{s}.plist", .{ std.mem.trimEnd(u8, user_home, "/"), launch_label });
}

fn xmlEscape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
    return out.items;
}

/// The LaunchAgent: `EXE --home HOME run` at login, with the PATH the
/// command was given (launchd's own is bare), its output in
/// `HOME/log/autostart.log`.
pub fn launchAgent(a: std.mem.Allocator, exe: []const u8, home: []const u8, path_var: []const u8) ![]const u8 {
    const h = try xmlEscape(a, home);
    return std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key><string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>--home</string>
        \\    <string>{s}</string>
        \\    <string>run</string>
        \\  </array>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>PATH</key><string>{s}</string>
        \\  </dict>
        \\  <key>RunAtLoad</key><true/>
        \\  <key>StandardOutPath</key><string>{s}/log/autostart.log</string>
        \\  <key>StandardErrorPath</key><string>{s}/log/autostart.log</string>
        \\</dict>
        \\</plist>
        \\
    , .{ launch_label, try xmlEscape(a, exe), h, try xmlEscape(a, path_var), h, h });
}

/// `$XDG_CONFIG_HOME/autostart/harness.desktop` (`~/.config` when unset
/// or empty).
pub fn xdgPath(a: std.mem.Allocator, xdg_config_home: ?[]const u8, user_home: []const u8) ![]const u8 {
    if (xdg_config_home) |x| if (x.len > 0) return std.fmt.allocPrint(a, "{s}/autostart/harness.desktop", .{std.mem.trimEnd(u8, x, "/")});
    return std.fmt.allocPrint(a, "{s}/.config/autostart/harness.desktop", .{std.mem.trimEnd(u8, user_home, "/")});
}

/// One argument of an Exec line: quoted, `"`, `` ` ``, `$` and `\`
/// escaped, then the string's own `\` doubled and `%` as `%%`.
fn execArg(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) !void {
    try out.append(a, '"');
    for (arg) |c| switch (c) {
        '"', '`', '$' => try out.appendSlice(a, &.{ '\\', '\\', c }),
        '\\' => try out.appendSlice(a, "\\\\\\\\"),
        '%' => try out.appendSlice(a, "%%"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

/// The XDG autostart entry: `EXE --home HOME run` at login.
pub fn xdgEntry(a: std.mem.Allocator, exe: []const u8, home: []const u8) ![]const u8 {
    var exec: std.ArrayList(u8) = .empty;
    try execArg(&exec, a, exe);
    try exec.appendSlice(a, " --home ");
    try execArg(&exec, a, home);
    try exec.appendSlice(a, " run");
    return std.fmt.allocPrint(a, "[Desktop Entry]\nType=Application\nName=harness\nComment=Starts harness run at login\nExec={s}\nTerminal=false\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n", .{exec.items});
}

/// The HKCU Run value: `"EXE" --home "HOME" run` (Windows paths hold no
/// quote).
pub fn runValue(a: std.mem.Allocator, exe: []const u8, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "\"{s}\" --home \"{s}\" run", .{ exe, home });
}

/// What `harness autostart` alone says: `on` or `off` first (the desk
/// app's menu reads that word).
pub fn statusLine(on: bool) []const u8 {
    return if (on) "on: harness run starts when you log in.\n" else "off: harness run doesn't start when you log in.\n";
}

pub const Os = enum { macos, windows, linux };

/// Where `harness open` looks for the desk app, in order: beside harness,
/// then (macOS) in /Applications and ~/Applications.
pub fn deskAppCandidates(a: std.mem.Allocator, os: Os, exe_dir: []const u8, user_home: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (os) {
        .macos => {
            try out.append(a, try std.fmt.allocPrint(a, "{s}/harness-desk.app", .{std.mem.trimEnd(u8, exe_dir, "/")}));
            try out.append(a, "/Applications/harness-desk.app");
            try out.append(a, try std.fmt.allocPrint(a, "{s}/Applications/harness-desk.app", .{std.mem.trimEnd(u8, user_home, "/")}));
        },
        .windows => try out.append(a, try std.fmt.allocPrint(a, "{s}\\harness-desk.exe", .{std.mem.trimEnd(u8, exe_dir, "\\/")})),
        .linux => try out.append(a, try std.fmt.allocPrint(a, "{s}/harness-desk", .{std.mem.trimEnd(u8, exe_dir, "/")})),
    }
    return out.items;
}

// ---- tests ----

const t = std.testing;

test "launch_agent_runs_harness_with_its_home" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/Users/x/Library/LaunchAgents/com.legatia.harness.plist", try launchAgentPath(a, "/Users/x"));
    const plist = try launchAgent(a, "/opt/h & co/harness", "/Users/x/.harness", "/usr/bin:/bin");
    try t.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key><string>com.legatia.harness</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/opt/h &amp; co/harness</string>
        \\    <string>--home</string>
        \\    <string>/Users/x/.harness</string>
        \\    <string>run</string>
        \\  </array>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>PATH</key><string>/usr/bin:/bin</string>
        \\  </dict>
        \\  <key>RunAtLoad</key><true/>
        \\  <key>StandardOutPath</key><string>/Users/x/.harness/log/autostart.log</string>
        \\  <key>StandardErrorPath</key><string>/Users/x/.harness/log/autostart.log</string>
        \\</dict>
        \\</plist>
        \\
    , plist);
}

test "xdg_entry_quotes_its_paths" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/home/x/.config/autostart/harness.desktop", try xdgPath(a, null, "/home/x"));
    try t.expectEqualStrings("/cfg/autostart/harness.desktop", try xdgPath(a, "/cfg", "/home/x"));
    try t.expectEqualStrings("/home/x/.config/autostart/harness.desktop", try xdgPath(a, "", "/home/x"));
    const e = try xdgEntry(a, "/opt/my apps/harness", "/home/x/100% $data");
    try t.expect(std.mem.indexOf(u8, e, "[Desktop Entry]\nType=Application\nName=harness\n") != null);
    try t.expect(std.mem.indexOf(u8, e, "\nExec=\"/opt/my apps/harness\" --home \"/home/x/100%% \\\\$data\" run\n") != null);
    try t.expect(std.mem.indexOf(u8, e, "\nTerminal=false\n") != null);
    try t.expect(std.mem.indexOf(u8, e, "\nX-GNOME-Autostart-enabled=true\n") != null);
}

test "windows_run_value_quotes_its_paths" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("\"C:\\Program Files\\harness\\harness.exe\" --home \"C:\\Users\\x\\AppData\\Local\\harness\" run", try runValue(a, "C:\\Program Files\\harness\\harness.exe", "C:\\Users\\x\\AppData\\Local\\harness"));
}

test "autostart_says_on_or_off_first" {
    try t.expectEqualStrings("on: harness run starts when you log in.\n", statusLine(true));
    try t.expectEqualStrings("off: harness run doesn't start when you log in.\n", statusLine(false));
}

test "the_desk_app_is_looked_for_beside_then_in_applications" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mac = try deskAppCandidates(a, .macos, "/opt/harness", "/Users/x");
    try t.expectEqual(3, mac.len);
    try t.expectEqualStrings("/opt/harness/harness-desk.app", mac[0]);
    try t.expectEqualStrings("/Applications/harness-desk.app", mac[1]);
    try t.expectEqualStrings("/Users/x/Applications/harness-desk.app", mac[2]);
    const win = try deskAppCandidates(a, .windows, "C:\\h", "C:\\Users\\x");
    try t.expectEqual(1, win.len);
    try t.expect(std.mem.endsWith(u8, win[0], "harness-desk.exe"));
    const lin = try deskAppCandidates(a, .linux, "/opt/harness", "/home/x");
    try t.expectEqual(1, lin.len);
    try t.expectEqualStrings("/opt/harness/harness-desk", lin[0]);
}

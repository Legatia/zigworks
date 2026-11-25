//! The app's Info.plist (build.zig writes it into the bundle).
const std = @import("std");

pub const Options = struct {
    version: []const u8,
    bundle_id: []const u8,
};

pub fn info(a: std.mem.Allocator, o: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    const strings = [_][2][]const u8{
        .{ "CFBundleDevelopmentRegion", "en" },
        .{ "CFBundleExecutable", "harness-desk" },
        .{ "CFBundleName", "harness" },
        .{ "CFBundleDisplayName", "harness" },
        .{ "CFBundleIdentifier", o.bundle_id },
        .{ "CFBundleIconFile", "harness" },
        .{ "CFBundleInfoDictionaryVersion", "6.0" },
        .{ "CFBundlePackageType", "APPL" },
        .{ "CFBundleShortVersionString", o.version },
        .{ "CFBundleVersion", o.version },
        .{ "LSMinimumSystemVersion", "12.0" },
        .{ "LSApplicationCategoryType", "public.app-category.productivity" },
        .{ "NSPrincipalClass", "NSApplication" },
        .{ "NSMicrophoneUsageDescription", "The desk records your voice when you use its microphone button." },
    };
    for (strings) |kv| {
        try out.print(a, "\t<key>{s}</key>\n\t<string>", .{kv[0]});
        try escape(&out, a, kv[1]);
        try out.appendSlice(a, "</string>\n");
    }
    try out.appendSlice(a, "\t<key>NSHighResolutionCapable</key>\n\t<true/>\n" ++
        "\t<key>NSSupportsAutomaticGraphicsSwitching</key>\n\t<true/>\n" ++
        "\t<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>\n" ++
        "</dict>\n</plist>\n");
    return out.toOwnedSlice(a);
}

fn escape(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        else => try out.append(a, ch),
    };
}

const t = std.testing;

test "the_plist_has_its_keys" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const p = try info(arena.allocator(), .{ .version = "0.3.0", .bundle_id = "io.github.legatia.harness-desk" });
    try t.expect(std.mem.startsWith(u8, p, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"));
    for ([_][]const u8{
        "<key>CFBundleExecutable</key>\n\t<string>harness-desk</string>",
        "<key>CFBundleName</key>\n\t<string>harness</string>",
        "<key>CFBundleDisplayName</key>\n\t<string>harness</string>",
        "<key>CFBundleIdentifier</key>\n\t<string>io.github.legatia.harness-desk</string>",
        "<key>CFBundleIconFile</key>\n\t<string>harness</string>",
        "<key>CFBundlePackageType</key>\n\t<string>APPL</string>",
        "<key>CFBundleShortVersionString</key>\n\t<string>0.3.0</string>",
        "<key>CFBundleVersion</key>\n\t<string>0.3.0</string>",
        "<key>LSMinimumSystemVersion</key>\n\t<string>12.0</string>",
        "<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>",
        "<key>NSHighResolutionCapable</key>\n\t<true/>",
        "<key>NSMicrophoneUsageDescription</key>\n\t<string>",
        "<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>",
    }) |want| {
        if (std.mem.indexOf(u8, p, want) == null) {
            std.debug.print("missing: {s}\n", .{want});
            return error.TestExpectedEqual;
        }
    }
}

test "values_are_escaped" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const p = try info(arena.allocator(), .{ .version = "1<2&3", .bundle_id = "x" });
    try t.expect(std.mem.indexOf(u8, p, "<string>1&lt;2&amp;3</string>") != null);
}

const std = @import("std");
const plist = @import("src/plist.zig");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        // Run on macOS 12 and later, not only on the build machine's version.
        var q = target.query;
        q.os_version_min = .{ .semver = .{ .major = 12, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(q);
    }
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (for release builds)") orelse false;
    const version = b.option([]const u8, "version", "The bundle's version (default: build.zig.zon's)") orelse @import("build.zig.zon").version;
    const test_hooks = b.option(bool, "test-hooks", "Build in the smoke's command file and log") orelse false;
    const bundle_id = b.option([]const u8, "bundle-id", "The bundle's identifier") orelse "io.github.legatia.harness-desk";

    // The decisions, on every system: no window, no web view.
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Run only the tests whose names hold this")) |f| &.{f} else &.{};
    const unit = b.addTest(.{ .root_module = unit_mod, .filters = filters });
    const run_unit = b.addRunArtifact(unit);
    b.step("test", "Run the unit tests").dependOn(&run_unit.step);

    // The icon, drawn on the machine that builds.
    const icon_exe = b.addExecutable(.{ .name = "harness-icon", .root_module = b.createModule(.{
        .root_source_file = b.path("src/icon.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }) });
    const icon_run = b.addRunArtifact(icon_exe);
    const icns = icon_run.addOutputFileArg("harness.icns");
    b.step("icon", "Draw the icon into zig-out/harness.icns").dependOn(&b.addInstallFile(icns, "harness.icns").step);

    // The Windows and Linux apps join here, from src/windows and src/linux.
    if (target.result.os.tag != .macos) return;

    // With an explicit minimum version Zig treats this as a cross build and
    // doesn't look for the SDK itself, so give it Xcode's SDK paths (as
    // headsound does). The path comes from xcrun and moves with Xcode.
    b.graph.poisonCache();
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result);

    const app = addApp(b, .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .sdk = sdk,
        .icns = icns,
        .version = version,
        .bundle_id = bundle_id,
        .test_hooks = test_hooks,
        .dir = "harness-desk.app",
        .step = "app",
        .about = "Build zig-out/harness-desk.app",
    });
    b.getInstallStep().dependOn(app);

    // The smoke: an app with test hooks and an id of its own, against the
    // stand-in harness, in a window.
    const smoke_app = addApp(b, .{
        .target = target,
        .optimize = optimize,
        .strip = false,
        .sdk = sdk,
        .icns = icns,
        .version = version,
        .bundle_id = "io.github.legatia.harness-desk.smoke",
        .test_hooks = true,
        .dir = "smoke/harness-desk.app",
        .step = "smoke-app",
        .about = "Build zig-out/smoke/harness-desk.app, with test hooks",
    });
    const smoke = b.addSystemCommand(&.{ "/bin/sh", "scripts/smoke.sh" });
    smoke.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "smoke/harness-desk.app" } });
    smoke.has_side_effects = true;
    smoke.step.dependOn(smoke_app);
    b.step("smoke", "Run the app against the stand-in harness (needs a window session)").dependOn(&smoke.step);
}

const AppOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    sdk: ?[]const u8,
    icns: std.Build.LazyPath,
    version: []const u8,
    bundle_id: []const u8,
    test_hooks: bool,
    /// Under the install prefix.
    dir: []const u8,
    step: []const u8,
    about: []const u8,
};

/// `DIR/Contents/{MacOS/harness-desk, Info.plist, PkgInfo, Resources/harness.icns}`.
fn addApp(b: *std.Build, o: AppOptions) *std.Build.Step {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .strip = o.strip,
        .link_libc = true,
    });
    if (o.sdk) |sdk| {
        mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    }
    mod.addCSourceFile(.{ .file = b.path("src/mac/desk.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Werror" } });
    for ([_][]const u8{ "Foundation", "AppKit", "WebKit" }) |f| mod.linkFramework(f, .{});
    mod.linkSystemLibrary("objc", .{});
    const options = b.addOptions();
    options.addOption([]const u8, "version", o.version);
    options.addOption(bool, "test_hooks", o.test_hooks);
    mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "harness-desk", .root_module = mod });

    const step = &b.step(o.step, o.about).*;
    const contents = b.pathJoin(&.{ o.dir, "Contents" });
    step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{ contents, "MacOS" }) } } }).step);
    const files = b.addWriteFiles();
    const info = plist.info(b.allocator, .{ .version = o.version, .bundle_id = o.bundle_id }) catch @panic("OOM");
    step.dependOn(&b.addInstallFile(files.add("Info.plist", info), b.pathJoin(&.{ contents, "Info.plist" })).step);
    step.dependOn(&b.addInstallFile(files.add("PkgInfo", "APPL????"), b.pathJoin(&.{ contents, "PkgInfo" })).step);
    step.dependOn(&b.addInstallFile(o.icns, b.pathJoin(&.{ contents, "Resources", "harness.icns" })).step);
    return step;
}

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

    switch (target.result.os.tag) {
        .macos => {},
        .windows => return addWindows(b, target, optimize, strip, version, icon_exe),
        .linux => return addLinux(b, target, optimize, strip, version, icon_exe),
        else => return,
    }

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

/// Windows: `harness-desk/harness-desk.exe` with `WebView2Loader.dll`
/// beside it, and the same under `smoke/` with test hooks. The header and
/// the loader come from Microsoft's NuGet package Microsoft.Web.WebView2,
/// unpacked: `-Dwebview2=DIR` (CI pins its version and SHA-256).
fn addWindows(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, version: []const u8, icon_exe: *std.Build.Step.Compile) void {
    // the program's icon, drawn on the machine that builds
    const ico_run = b.addRunArtifact(icon_exe);
    const ico = ico_run.addOutputFileArg("harness.ico");
    const app = b.step("app", "Build zig-out/harness-desk/harness-desk.exe with its loader");
    const smoke = b.step("smoke", "Run the app against the stand-in harness (needs a desktop)");
    const sdk = b.option([]const u8, "webview2", "The unpacked Microsoft.Web.WebView2 package (WebView2.h and the loader)") orelse {
        const need = b.addFail("the Windows app needs -Dwebview2=DIR: the unpacked Microsoft.Web.WebView2 NuGet package");
        app.dependOn(&need.step);
        smoke.dependOn(&need.step);
        return;
    };
    const arch_dir = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "x86",
        else => @panic("WebView2 has no loader for this processor"),
    };
    const loader: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sdk, "build", "native", arch_dir, "WebView2Loader.dll" }) };
    inline for (.{ .{ "harness-desk", false, app }, .{ "smoke", true, smoke } }) |v| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (v[1]) false else strip,
            .link_libc = true,
        });
        // (as a system header: its warnings are Microsoft's)
        mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "build", "native", "include" }) });
        mod.addIncludePath(b.path("src/windows"));
        // (the smoke's build can fill the key window with its fake key)
        mod.addCSourceFile(.{ .file = b.path("src/windows/desk.c"), .flags = if (v[1]) &.{ "-Wall", "-Wextra", "-Werror", "-DHDESK_TEST_HOOKS=1" } else &.{ "-Wall", "-Wextra", "-Werror" } });
        mod.addWin32ResourceFile(.{ .file = b.path("src/windows/desk.rc"), .include_paths = &.{ico.dirname()} });
        for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32" }) |lib| mod.linkSystemLibrary(lib, .{});
        const options = b.addOptions();
        options.addOption([]const u8, "version", version);
        options.addOption(bool, "test_hooks", v[1]);
        mod.addOptions("build_options", options);
        const exe = b.addExecutable(.{ .name = "harness-desk", .root_module = mod });
        // a window, no console
        exe.subsystem = .windows;
        const built = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = v[0] } } });
        const dll = b.addInstallFile(loader, v[0] ++ "/WebView2Loader.dll");
        if (v[1]) {
            // the stand-in harness as a program: the smoke puts it beside
            // the app as harness.exe, where the release carries harness
            const launcher_mod = b.createModule(.{
                .root_source_file = b.path("test/fake_launcher.zig"),
                .target = target,
                .optimize = .Debug,
            });
            const launcher = b.addInstallArtifact(b.addExecutable(.{ .name = "fake-harness", .root_module = launcher_mod }), .{ .dest_dir = .{ .override = .{ .custom = "smoke-tools" } } });
            const run = b.addSystemCommand(&.{ "sh", "scripts/smoke-other.sh" });
            run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "smoke/harness-desk.exe" } });
            run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "smoke-tools/fake-harness.exe" } });
            run.has_side_effects = true;
            run.step.dependOn(&built.step);
            run.step.dependOn(&dll.step);
            run.step.dependOn(&launcher.step);
            v[2].dependOn(&run.step);
        } else {
            v[2].dependOn(&built.step);
            v[2].dependOn(&dll.step);
            b.getInstallStep().dependOn(v[2]);
        }
    }
}

/// Linux: `harness-desk/harness-desk`, linked against the system's GTK 3
/// and WebKitGTK 4.1 (found with pkg-config: libgtk-3-dev and
/// libwebkit2gtk-4.1-dev), and the same under `smoke/` with test hooks.
fn addLinux(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool, version: []const u8, icon_exe: *std.Build.Step.Compile) void {
    // the window's icon, drawn on the machine that builds, inside the program
    const png_run = b.addRunArtifact(icon_exe);
    const icon_png = png_run.addOutputFileArg("harness.png");
    const app = b.step("app", "Build zig-out/harness-desk/harness-desk");
    const smoke = b.step("smoke", "Run the app against the stand-in harness (needs a display, or xvfb-run)");
    inline for (.{ .{ "harness-desk", false, app }, .{ "smoke", true, smoke } }) |v| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (v[1]) false else strip,
            .link_libc = true,
        });
        // (GTK 3 marks much of itself as deprecated: not this file's to fix)
        // (the smoke's build can fill the key dialog with its fake key)
        mod.addCSourceFile(.{ .file = b.path("src/linux/desk.c"), .flags = if (v[1]) &.{ "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations", "-DHDESK_TEST_HOOKS=1" } else &.{ "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations" } });
        mod.addAnonymousImport("icon_png", .{ .root_source_file = icon_png });
        mod.linkSystemLibrary("gtk+-3.0", .{});
        mod.linkSystemLibrary("webkit2gtk-4.1", .{});
        const options = b.addOptions();
        options.addOption([]const u8, "version", version);
        options.addOption(bool, "test_hooks", v[1]);
        mod.addOptions("build_options", options);
        const exe = b.addExecutable(.{ .name = "harness-desk", .root_module = mod });
        const built = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = v[0] } } });
        if (v[1]) {
            const run = b.addSystemCommand(&.{ "sh", "scripts/smoke-other.sh" });
            run.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "smoke/harness-desk" } });
            run.has_side_effects = true;
            run.step.dependOn(&built.step);
            v[2].dependOn(&run.step);
        } else {
            v[2].dependOn(&built.step);
            b.getInstallStep().dependOn(v[2]);
        }
    }
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
    // the test hooks' fake key is compiled into the smoke's app only
    const flags: []const []const u8 = if (o.test_hooks) &.{ "-fobjc-arc", "-Wall", "-Werror", "-DHDESK_TEST_HOOKS=1" } else &.{ "-fobjc-arc", "-Wall", "-Werror" };
    mod.addCSourceFile(.{ .file = b.path("src/mac/desk.m"), .flags = flags });
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

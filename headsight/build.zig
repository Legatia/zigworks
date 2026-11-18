const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        // Run on macOS 14 and later, not only on the build machine's version.
        var q = target.query;
        q.os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } };
        // A plain native build keeps targeting this machine's CPU; without this the
        // changed query is sent to the compiler as the baseline CPU for the architecture.
        if (q.cpu_arch == null and q.cpu_model == .determined_by_arch_os) q.cpu_model = .native;
        target = b.resolveTargetQuery(q);
    }
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (for release binaries)") orelse false;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    if (target.result.os.tag == .macos) {
        // With an explicit minimum version Zig treats this as a cross build and
        // doesn't look for the SDK itself, so give it Xcode's SDK paths.
        // The path comes from asking xcrun, which the build cache can't track
        // (it changes with Xcode updates and xcode-select), so ask every time.
        b.graph.poisonCache();
        if (std.zig.system.darwin.getSdk(b.graph.arena, b.graph.io, &target.result)) |sdk| {
            mod.addSystemFrameworkPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System/Library/Frameworks" })));
            mod.addSystemIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/include" })));
            mod.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })));
        }
        mod.addCSourceFile(.{ .file = b.path("src/mac/capture.m"), .flags = &.{"-fobjc-arc"} });
        for ([_][]const u8{ "Foundation", "ScreenCaptureKit", "AVFoundation", "CoreMedia", "CoreVideo", "CoreGraphics", "CoreText", "ImageIO", "Vision" }) |f|
            mod.linkFramework(f, .{});
        mod.linkSystemLibrary("objc", .{});
    } else if (target.result.os.tag == .linux) {
        // The camera through V4L2; uses the kernel headers that ship with Zig.
        mod.addCSourceFile(.{ .file = b.path("src/linux/capture.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-Wall", "-Wextra", "-Werror" } });
    }
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "headsight", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run headsight").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // CLI paths that need no capture permission.
    const smoke = b.addSystemCommand(&.{ "/bin/sh", "scripts/smoke.sh" });
    smoke.addArtifactArg2(exe, .{});
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the CLI smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
}

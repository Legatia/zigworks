const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        // Run on macOS 14 and later, not only on the build machine's version.
        var q = target.query;
        q.os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } };
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
        // The path comes from xcrun and moves with Xcode, so the configuration
        // is not kept between builds.
        b.graph.poisonCache();
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
        mod.addCSourceFile(.{ .file = b.path("src/mac/audio.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Werror" } });
        for ([_][]const u8{ "Foundation", "AVFoundation", "AudioToolbox", "CoreAudio", "CoreMedia", "SoundAnalysis", "Speech" }) |f|
            mod.linkFramework(f, .{});
        mod.linkSystemLibrary("objc", .{});
    }
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "headsound", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run headsound").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // The CLI on generated audio files; no microphone needed.
    // On Windows: the sh of Git for Windows (on PATH on GitHub's runners).
    const sh = if (b.graph.host.result.os.tag == .windows) "sh" else "/bin/sh";
    const smoke = b.addSystemCommand(&.{ sh, "scripts/smoke.sh" });
    smoke.addArtifactArg2(exe, .{});
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the CLI smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (for release binaries)") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = target.result.os.tag == .macos,
    });
    mod.addOptions("build_options", options);
    linkSystem(mod, target);
    const exe = b.addExecutable(.{ .name = "harness", .root_module = mod });
    b.installArtifact(exe);

    // Stand-ins for omnigate, Telegram, feeds and search, for the tests.
    const fake_mod = b.createModule(.{
        .root_source_file = b.path("src/fake_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) fake_mod.linkSystemLibrary("ws2_32", .{});
    const fake = b.addExecutable(.{ .name = "harness-fake", .root_module = fake_mod });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run harness").dependOn(&run.step);

    // The unit tests get their own module so they can know where harness-fake
    // is (the MCP tests start it as a server).
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    test_options.addOptionPath("fake_path", fake.getEmittedBin());
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .macos,
    });
    test_mod.addOptions("build_options", test_options);
    linkSystem(test_mod, target);
    const unit = b.addTest(.{ .root_module = test_mod });
    const run_unit = b.addRunArtifact(unit);

    // The CLI end to end against a local stand-in upstream; no real keys.
    const sh = if (@import("builtin").os.tag == .windows) "sh" else "/bin/sh";
    const smoke = b.addSystemCommand(&.{ sh, "scripts/smoke.sh" });
    smoke.addArtifactArg(exe);
    smoke.addArtifactArg(fake);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the CLI smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
}

fn linkSystem(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .windows => {
            mod.linkSystemLibrary("ws2_32", .{});
            mod.linkSystemLibrary("advapi32", .{});
        },
        .macos => {
            mod.linkFramework("Security", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }
}

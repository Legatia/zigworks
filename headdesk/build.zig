const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (for release binaries)") orelse false;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    const exe = b.addExecutable(.{ .name = "headdesk", .root_module = mod });
    b.installArtifact(exe);

    // A small Wayland client with a window, a button and a menu, for the
    // tests: what an app does, without an app.
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/testclient.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    const client = b.addExecutable(.{ .name = "headdesk-testclient", .root_module = client_mod });
    b.installArtifact(client);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // End to end: a desktop with the test client in it, driven through the CLI.
    const smoke = b.addSystemCommand(&.{ "/bin/sh", "scripts/smoke.sh" });
    smoke.addArtifactArg2(exe, .{});
    smoke.addArtifactArg2(client, .{});
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    b.step("unit", "Run unit tests only").dependOn(&run_unit.step);

    const test_step = b.step("test", "Run unit tests and the end-to-end test");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
}

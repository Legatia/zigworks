const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave out debug info") orelse false;

    // The tap. No libc: a static binary for any Linux target.
    const tap = b.addExecutable(.{ .name = "cantap", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    }) });
    b.installArtifact(tap);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Run the tests (the bus tests need vcan0 up)").dependOn(&b.addRunArtifact(tests).step);

    // The poller against an ECU simulator with its own ISO-TP (../cansim).
    const sim_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/uds_sim_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-uds-sim", "Ask the made-up battery ECU (/opt/cansim/bin/uds-ecu, running) for its identifiers")
        .dependOn(&b.addRunArtifact(sim_tests).step);

    // The research's first sketch, unchanged except that the C headers are
    // translated here instead of by @cImport, which 0.17.1 no longer has.
    const headers = b.addTranslateC(.{
        .root_source_file = b.path("sketch/can_headers.h"),
        .target = target,
        .optimize = optimize,
    });
    const sketch_mod = b.createModule(.{
        .root_source_file = b.path("sketch/sketch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sketch_mod.addImport("c", headers.createModule());
    const sketch = b.addExecutable(.{ .name = "sketch", .root_module = sketch_mod });
    b.step("sketch", "Build the libc version of the sketch").dependOn(&b.addInstallArtifact(sketch, .{}).step);
}

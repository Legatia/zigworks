const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info (for release binaries)") orelse false;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    const windows = target.result.os.tag == .windows;
    // Winsock, for the Unix sockets that sessions are reached over.
    if (windows) mod.linkSystemLibrary("ws2_32", .{});
    const exe = b.addExecutable(.{ .name = "headterm", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run headterm").dependOn(&run.step);

    // Windows has no fork: the tests that start sessions run headterm.exe
    // as their session server, and are told where it is.
    const unit_mod = if (windows) blk: {
        const m = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.linkSystemLibrary("ws2_32", .{});
        const options = b.addOptions();
        options.addOptionPath("headterm_exe", exe.getEmittedBin());
        m.addOptions("test_options", options);
        break :blk m;
    } else mod;
    const unit = b.addTest(.{ .root_module = unit_mod });
    const run_unit = b.addRunArtifact(unit);

    // End-to-end tests: real sessions through the CLI and through `mcp`.
    // On Windows: the sh of Git for Windows (on PATH on GitHub's runners).
    const sh = if (b.graph.host.result.os.tag == .windows) "sh" else "/bin/sh";
    const smoke = b.addSystemCommand(&.{ sh, "scripts/smoke.sh" });
    smoke.addArtifactArg2(exe, .{});
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    const mcp_smoke = b.addSystemCommand(&.{ sh, "scripts/mcp_smoke.sh" });
    mcp_smoke.addArtifactArg2(exe, .{});
    mcp_smoke.has_side_effects = true;
    mcp_smoke.step.dependOn(&run_unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the end-to-end smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
    test_step.dependOn(&mcp_smoke.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{ .name = "headterm", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run headterm").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // End-to-end tests: real sessions through the CLI and through `mcp`.
    const smoke = b.addSystemCommand(&.{ "/bin/sh", "scripts/smoke.sh" });
    smoke.addArtifactArg(exe);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    const mcp_smoke = b.addSystemCommand(&.{ "/bin/sh", "scripts/mcp_smoke.sh" });
    mcp_smoke.addArtifactArg(exe);
    mcp_smoke.has_side_effects = true;
    mcp_smoke.step.dependOn(&run_unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the end-to-end smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
    test_step.dependOn(&mcp_smoke.step);
}

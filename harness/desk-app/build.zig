const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
}

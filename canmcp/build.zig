const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave out debug info (for release binaries)") orelse false;
    // What may ever be sent on a bus is decided here, not at run time:
    // `none` builds a binary with no transmit code at all.
    const diag = b.option([]const u8, "diag", "Diagnostic reads compiled in: none (default; the binary cannot transmit) or sim (the made-up battery ECU of ../harness/research/cansim)") orelse "none";

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption([]const u8, "diag", diag);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "canmcp", .root_module = mod });
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // The binary end to end over MCP; the bus parts need vcan (skipped without).
    const smoke = b.addSystemCommand(&.{ "sh", "scripts/smoke.sh" });
    smoke.addArtifactArg(exe);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    b.step("unit", "Run the unit tests").dependOn(&run_unit.step);
    const test_step = b.step("test", "Run the unit tests, then scripts/smoke.sh");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);

    // The readings on two real cars' recordings, checked against each other.
    // Needs ../harness/research/cansim's /opt/cansim (skipped without).
    const rec = b.addSystemCommand(&.{ "sh", "scripts/recordings.sh" });
    rec.addArtifactArg(exe);
    rec.has_side_effects = true;
    b.step("recordings", "Check the readings on cansim's recordings of a Tesla Model 3 and a Hyundai Ioniq 5").dependOn(&rec.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave out debug info (for release binaries)") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const mod = module(b, "src/main.zig", target, optimize, strip);
    mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "homemcp", .root_module = mod });
    b.installArtifact(exe);

    // A made-up home to try it on: Zigbee2MQTT through a broker, or Home Assistant.
    const sim_mod = module(b, "src/sim_main.zig", target, optimize, strip);
    sim_mod.addOptions("build_options", options);
    const sim = b.addExecutable(.{ .name = "homemcp-sim", .root_module = sim_mod });
    b.installArtifact(sim);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    const sh = if (@import("builtin").os.tag == .windows) "sh" else "/bin/sh";
    const smoke = b.addSystemCommand(&.{ sh, "scripts/smoke.sh" });
    smoke.addArtifactArg(exe);
    smoke.addArtifactArg(sim);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    b.step("unit", "Run the unit tests").dependOn(&run_unit.step);
    const test_step = b.step("test", "Run the unit tests, then scripts/smoke.sh");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
}

fn module(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = target.result.os.tag == .macos,
    });
    if (target.result.os.tag == .windows) m.linkSystemLibrary("ws2_32", .{});
    return m;
}

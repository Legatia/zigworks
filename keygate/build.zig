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
    const exe = b.addExecutable(.{ .name = "keygate", .root_module = mod });
    b.installArtifact(exe);

    // The stand-in service the smoke tests put behind the gateway.
    const echo_mod = b.createModule(.{
        .root_source_file = b.path("src/echo_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) echo_mod.linkSystemLibrary("ws2_32", .{});
    const echo = b.addExecutable(.{ .name = "keygate-echo", .root_module = echo_mod });

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run keygate").dependOn(&run.step);

    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // The CLI end to end against a local stand-in upstream; no real keys.
    const sh = if (@import("builtin").os.tag == .windows) "sh" else "/bin/sh";
    const smoke = b.addSystemCommand(&.{ sh, "scripts/smoke.sh" });
    smoke.addArtifactArg(exe);
    smoke.addArtifactArg(echo);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the CLI smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);
}

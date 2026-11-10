const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = module(b, target, optimize);
    const exe = b.addExecutable(.{ .name = "trigrep", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run trigrep").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module(b, target, optimize) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // FSEvents, for `trigrep watch`.
    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreServices", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
    return mod;
}

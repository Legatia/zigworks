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
    // the butler's routines (examples/butler/), built in
    const butler_files = b.createModule(.{ .root_source_file = b.path("examples/butler/files.zig") });
    mod.addImport("butler_files", butler_files);
    linkSystem(b, mod, target);
    const exe = b.addExecutable(.{ .name = "harness", .root_module = mod });
    b.installArtifact(exe);

    // Stand-ins for omnigate, Telegram, feeds and search, for the tests.
    const fake_mod = b.createModule(.{
        .root_source_file = b.path("src/fake_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) {
        fake_mod.linkSystemLibrary("ws2_32", .{});
        // the sandbox's launcher, which the unit tests start it as
        fake_mod.linkSystemLibrary("advapi32", .{});
        fake_mod.linkSystemLibrary("userenv", .{});
    }
    const fake = b.addExecutable(.{ .name = "harness-fake", .root_module = fake_mod });
    // installed beside harness: the injection demo runs it (release
    // packages copy harness alone)
    b.installArtifact(fake);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run harness").dependOn(&run.step);

    // The unit tests get their own module so they can know where harness-fake
    // is (the MCP tests start it as a server).
    // -Dbrowser-tests=false: the tests that start a browser (Chrome or Edge)
    // are skipped here; the browser-test step below always runs them.
    const browser_tests = b.option(bool, "browser-tests", "Run the tests that start a browser among the unit tests (default: true)") orelse true;
    // -Dtest-filter=NAME (more than once for more): only the unit tests whose name has it
    const filters = b.option([]const []const u8, "test-filter", "Run only the unit tests whose names contain this") orelse &.{};
    const tests: UnitTests = .{ .b = b, .target = target, .optimize = optimize, .fake = fake, .butler_files = butler_files };
    const unit = tests.add(browser_tests, filters);
    const run_unit = b.addRunArtifact(unit);

    // The tests that start a browser, alone (CI runs them as a job of their
    // own: they wait on a real browser, and one fails there now and then,
    // cause not found). A part of a test's full name each, FILE.test.NAME; a
    // new test that calls cdp.testBrowser goes here, and
    // scripts/check-browser-tests.sh fails this step until it does.
    const browser_filters: []const []const u8 = &.{
        "web.test.",
        "cdp.test.chrome_over_a_pipe_evaluates_and_closes_without_leftovers",
        "cdp.test.a_stop_ends_chrome_at_once",
        "cdp.test.chrome_ends_when_harness_goes_away",
        "cdp.test.chrome_is_never_signalled_after_it_was_reaped",
        "page.test.render_loads_nothing_from_another_host",
        "page.test.render_of_a_download_saves_nothing_and_says_so",
        "page.test.render_example_com_with_a_real_browser",
        "agent.test.web_fill_through_a_turn_keeps_the_value_out_of_requests_and_the_log",
    };

    // The CLI end to end against a local stand-in upstream; no real keys.
    const sh = if (@import("builtin").os.tag == .windows) "sh" else "/bin/sh";
    const smoke = b.addSystemCommand(&.{ sh, "scripts/smoke.sh" });
    smoke.addArtifactArg(exe);
    smoke.addArtifactArg(fake);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&run_unit.step);

    // compile the unit tests without running them (for other targets)
    const unit_build = b.step("unit-build", "Build the unit tests without running them");
    unit_build.dependOn(&unit.step);

    const unit_step = b.step("unit", "Run unit tests only");
    unit_step.dependOn(&run_unit.step);
    const test_step = b.step("test", "Run unit tests and the CLI smoke tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&smoke.step);

    const listed = b.addSystemCommand(&.{ sh, "scripts/check-browser-tests.sh" });
    listed.addArgs(browser_filters);
    const run_browser = b.addRunArtifact(tests.add(true, browser_filters));
    run_browser.step.dependOn(&listed.step);
    b.step("browser-test", "Run only the unit tests that start a browser").dependOn(&run_browser.step);
}

/// The unit tests' program: with or without the tests that start a browser,
/// and only the tests the filters name (all of them when there are none).
const UnitTests = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    fake: *std.Build.Step.Compile,
    butler_files: *std.Build.Module,

    fn add(u: UnitTests, browser: bool, filters: []const []const u8) *std.Build.Step.Compile {
        const b = u.b;
        const options = b.addOptions();
        options.addOption([]const u8, "version", @import("build.zig.zon").version);
        options.addOptionPath("fake_path", u.fake.getEmittedBin());
        options.addOption(bool, "browser_tests", browser);
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = u.target,
            .optimize = u.optimize,
            .link_libc = u.target.result.os.tag == .macos,
        });
        mod.addOptions("build_options", options);
        mod.addImport("butler_files", u.butler_files);
        linkSystem(b, mod, u.target);
        return b.addTest(.{ .root_module = mod, .filters = filters });
    }
};

fn linkSystem(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .windows => {
            mod.linkSystemLibrary("ws2_32", .{});
            mod.linkSystemLibrary("advapi32", .{});
            // AppContainer profiles, for sandboxes
            mod.linkSystemLibrary("userenv", .{});
        },
        .macos => {
            // A named Mac target is a cross build to Zig, which then doesn't
            // look for the SDK: on a Mac, give it Xcode's (the desk app's
            // package carries harness for both kinds of Mac). The path comes
            // from xcrun and moves with Xcode, as desk-app/build.zig has it.
            if (target.query.os_tag != null and b.graph.host.result.os.tag == .macos) {
                b.graph.poisonCache();
                if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
                    mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
                    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
                    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
                }
            }
            mod.linkFramework("Security", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }
}

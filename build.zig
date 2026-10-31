const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `gnarl --version` prints build.zig.zon's version.
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{ .name = "gnarl", .root_module = gnarlModule(b, target, optimize, options) });
    b.installArtifact(exe);

    // `zig build run -- <path>...`
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run gnarl on the given paths").dependOn(&run.step);

    // Some tests run gnarl itself and some read src/ at run time: they need
    // the binary's path, the repository root as their working directory,
    // and to run every time rather than be cached on the test binary alone.
    const test_options = b.addOptions();
    test_options.addOptionPath("gnarl_exe", exe.getEmittedBin());
    // `zig build test -Dupdate`: a golden table whose numbers moved is
    // rewritten to them (src/golden.zig).
    test_options.addOption(bool, "update", b.option(bool, "update", "Rewrite the golden tables to what gnarl measures") orelse false);
    const test_module = gnarlModule(b, target, optimize, options);
    test_module.addOptions("test_options", test_options);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    run_tests.setCwd(b.path("."));
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);

    // `zig build check`: gnarl holds its own source to complexity.baseline,
    // so a function new and over a critical threshold, or above its number
    // there, fails. What it reads is what a plain `gnarl --check` here
    // reads: complexity.zon leaves the golden fixtures out. The report is
    // left out; on a failure, stderr names each function and the --explain
    // to run. `zig build test` runs it too.
    const check = b.addRunArtifact(exe);
    check.addArgs(&.{"--check"});
    check.setCwd(b.path("."));
    check.has_side_effects = true;
    _ = check.captureStdOut(.{});
    check.expectExitCode(0);
    b.step("check", "Hold gnarl's own source to complexity.baseline").dependOn(&check.step);
    test_step.dependOn(&check.step);
}

fn gnarlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    return module;
}

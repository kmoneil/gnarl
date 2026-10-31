const std = @import("std");
const zon = @import("build.zig.zon");

/// What a GitHub release carries: one binary for each platform, named
/// gnarl-<os>-<arch> as the Homebrew formula and the install docs name them.
const release_targets = [_]struct { query: std.Target.Query, name: []const u8 }{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .name = "gnarl-linux-amd64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .name = "gnarl-linux-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "gnarl-darwin-amd64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "gnarl-darwin-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "gnarl-windows-amd64.exe" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .name = "gnarl-windows-arm64.exe" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `gnarl --version` prints build.zig.zon's version; the release
    // workflow refuses a tag that does not match it.
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
    // there, fails. What it reads is what `gnarl --check .` here reads:
    // complexity.zon leaves the golden fixtures out. The report is
    // left out; on a failure, stderr names each function and the --explain
    // to run. `zig build test` runs it too.
    const check = b.addRunArtifact(exe);
    check.addArgs(&.{ "--check", "." });
    check.setCwd(b.path("."));
    check.has_side_effects = true;
    _ = check.captureStdOut(.{});
    check.expectExitCode(0);
    b.step("check", "Hold gnarl's own source to complexity.baseline").dependOn(&check.step);
    test_step.dependOn(&check.step);

    // `zig build fmt` writes the source as zig fmt would; `zig build test`
    // fails on a file it would change, so nothing goes in unformatted. The
    // golden fixtures are left as they are.
    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon"), b.path("complexity.zon") };
    b.step("fmt", "Format the source as zig fmt does").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    test_step.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);

    // `zig build lint`: zigvet over gnarl's own source, as CI runs it. zigvet
    // is a binary of its own (github.com/kmoneil/zigvet), so `zig build test`
    // does not need it.
    const lint = b.addSystemCommand(&.{ "zigvet", "src", "build.zig" });
    lint.setCwd(b.path("."));
    lint.has_side_effects = true;
    b.step("lint", "Run zigvet over gnarl's own source").dependOn(&lint.step);

    // `zig build release`: every binary a release carries, into
    // zig-out/release/. CI builds it on every change, so a tag never finds
    // a target that does not build.
    const release = b.step("release", "Build the release binaries into zig-out/release/");
    for (release_targets) |release_target| release.dependOn(releaseBinary(b, release_target.query, release_target.name, options));
}

/// One release binary: ReleaseSafe, so a bug stops gnarl with a message
/// rather than letting it print a wrong number, and stripped, since the
/// debug info holds the paths of the machine that built it.
fn releaseBinary(b: *std.Build, query: std.Target.Query, name: []const u8, options: *std.Build.Step.Options) *std.Build.Step {
    const exe = b.addExecutable(.{
        .name = "gnarl",
        .root_module = gnarlModule(b, b.resolveTargetQuery(query), .ReleaseSafe, options),
    });
    exe.root_module.strip = true;
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
        .dest_sub_path = name,
        .pdb_dir = .disabled,
    });
    return &install.step;
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

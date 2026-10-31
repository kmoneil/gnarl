//! The `gnarl` command: complexity metrics for each function in Zig source.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ast = std.zig.Ast;

const build_options = @import("build_options");
const test_options = @import("test_options");
const measure = @import("measure.zig");
const report = @import("report.zig");
const Thresholds = @import("thresholds.zig").Thresholds;
const walk = @import("walk.zig");

const usage =
    \\Usage: gnarl [--exclude <path>]... [--format <format>] [--json] <path>...
    \\       gnarl --version
    \\
    \\Measures every function and test block in each file named, and in
    \\every .zig file under each directory named: cyclomatic complexity,
    \\logical lines, nesting depth and parameters (plain, and weighted with a
    \\type parameter and an anytype counted twice). One row per function,
    \\worst first; a number over its warning threshold is marked !, over its
    \\critical one !!. Hidden files and directories, zig-out and zig-pkg are
    \\skipped.
    \\
    \\  --exclude <path>  Skip this file or directory, named as gnarl prints
    \\                    paths: relative to the current directory. May be
    \\                    given more than once.
    \\  --format <format> text (the default, a table), json, or md (a
    \\                    Markdown table, for a review).
    \\  --json            The same as --format json.
    \\
    \\Exit status: 0 if every file was read, 2 on a usage error, a path that
    \\could not be read or holds no .zig file, or a file that does not parse.
    \\The files that could be read are reported either way.
    \\
;

/// `Ast` offsets are 32-bit.
const max_source_bytes = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // Streaming, so that when stdout is a file the shell has already
    // written to, the report lands after what is there rather than over it.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = (try init.minimal.args.toSlice(arena))[1..];
    const run = switch (try parseArgs(arena, args)) {
        .run => |run| run,
        .help => {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        },
        .version => {
            try out.print("gnarl {s}\n", .{build_options.version});
            try out.flush();
            return 0;
        },
        .usage_error => |message| {
            if (message.len > 0) std.debug.print("gnarl: {s}\n\n", .{message});
            std.debug.print("{s}", .{usage});
            return 2;
        },
    };

    const cwd = Io.Dir.cwd();
    var unreadable = false;
    var files: std.ArrayList([]const u8) = .empty;
    for (run.paths) |arg| {
        const before = files.items.len;
        walk.collect(arena, io, cwd, arg, run.excludes, &files) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("gnarl: {s}: {t}\n", .{ arg, err });
                unreadable = true;
                continue;
            },
        };
        // Listing nothing would read exactly like a directory with no
        // functions in it.
        if (files.items.len == before) {
            std.debug.print("gnarl: {s}: no .zig file to read (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)\n", .{arg});
            unreadable = true;
        }
    }
    walk.sortUnique(&files);

    // What one file needs is freed before the next is read; the rows are
    // kept for the whole run.
    var file_arena: std.heap.ArenaAllocator = .init(gpa);
    defer file_arena.deinit();
    var rows: std.ArrayList(report.Row) = .empty;
    var measured: usize = 0;
    for (files.items) |path| {
        _ = file_arena.reset(.retain_capacity);
        const source = cwd.readFileAllocOptions(io, path, gpa, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                std.debug.print("gnarl: {s}: {t}\n", .{ path, err });
                unreadable = true;
                continue;
            },
        };
        defer gpa.free(source);
        var tree = try Ast.parse(gpa, source, .{});
        defer tree.deinit(gpa);
        if (tree.errors.len > 0) {
            try printParseErrors(file_arena.allocator(), path, &tree);
            unreadable = true;
            continue;
        }
        measured += 1;
        try measure.file(arena, file_arena.allocator(), path, &tree, &rows);
    }
    try report.rank(arena, rows.items, .normal);
    const status: u8 = if (unreadable) 2 else 0;
    report.write(out, run.format, rows.items, measured, .normal) catch |err| return closedEarly(err, &stdout_writer, status);
    out.flush() catch |err| return closedEarly(err, &stdout_writer, status);
    return status;
}

/// A reader that stops early, as `gnarl src | head` does, closes the pipe:
/// that ends the report quietly, with the status it would have had. Any
/// other failure to write is an error.
fn closedEarly(err: Io.Writer.Error, stdout_writer: *const Io.File.Writer, status: u8) !u8 {
    const cause = stdout_writer.err orelse return err;
    if (cause == error.BrokenPipe) return status;
    return cause;
}

/// Says on stderr where `tree` does not parse and why.
fn printParseErrors(arena: std.mem.Allocator, path: []const u8, tree: *const Ast) std.mem.Allocator.Error!void {
    var message: Io.Writer.Allocating = .init(arena);
    for (tree.errors) |parse_error| {
        message.clearRetainingCapacity();
        tree.renderError(parse_error, &message.writer) catch return error.OutOfMemory;
        const loc = tree.tokenLocation(0, parse_error.token);
        std.debug.print("gnarl: {s}:{d}:{d}: {s}\n", .{ path, loc.line + 1, loc.column + tree.errorOffset(parse_error) + 1, message.written() });
    }
}

/// What the command line asks for.
const Command = union(enum) {
    run: struct {
        paths: []const []const u8,
        /// Cleaned, as `walk.collect` cleans the paths it lists.
        excludes: []const []const u8,
        format: report.Format,
    },
    help,
    version,
    /// Why the command line cannot be run; empty when the usage alone says.
    usage_error: []const u8,
};

/// `-h` and `--help`, `--version`, and an unknown option take effect where
/// they stand; anything after them is not read.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Command {
    var paths: std.ArrayList([]const u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    var format: report.Format = .text;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (optionValue(args, &i, "--exclude")) |path| {
            if (path.len == 0) return .{ .usage_error = "--exclude needs a path" };
            try excludes.append(arena, try std.fs.path.resolveAlloc(arena, &.{path}));
        } else if (optionValue(args, &i, "--format")) |name| {
            format = std.meta.stringToEnum(report.Format, name) orelse
                return .{ .usage_error = try arena.print("--format takes text, json or md, not '{s}'", .{name}) };
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage_error = try arena.print("unknown option '{s}'", .{arg}) };
        } else try paths.append(arena, arg);
    }
    if (paths.items.len == 0) return .{ .usage_error = "" };
    return .{ .run = .{ .paths = paths.items, .excludes = excludes.items, .format = format } };
}

/// The value of option `name` if `args[i.*]` is it, given as `name value`
/// or `name=value`; "" when the value is missing. Moves `i` past a value
/// given on its own.
fn optionValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, name)) {
        i.* += 1;
        return if (i.* < args.len) args[i.*] else "";
    }
    return std.mem.cutPrefix(u8, std.mem.cutPrefix(u8, arg, name) orelse return null, "=");
}

/// What gnarl writes when run in `dir` with `argv`. Free both with
/// `std.testing.allocator`.
fn runGnarl(dir: Io.Dir, argv: []const []const u8) !std.process.RunResult {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.gnarl_exe, gpa);
    defer gpa.free(exe);
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, exe);
    try full.appendSlice(gpa, argv);
    return std.process.run(gpa, io, .{ .argv = full.items, .cwd = .{ .dir = dir } });
}

/// Runs gnarl in `dir` and checks how it exits and what it writes.
fn expectRun(dir: Io.Dir, argv: []const []const u8, exit: u8, stdout: []const u8, stderr: []const u8) !void {
    const result = try runGnarl(dir, argv);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqualStrings(stdout, result.stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = exit }, result.term);
}

const thresholds_line = "Thresholds (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.\n";

test "a row per function, worst first, from every file read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const S = struct {\n    fn m(c: bool) void {\n        if (c) {}\n    }\n};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f() void {}\ntest \"f\" {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.zig", .data = "const x = 1;\n" });

    try expectRun(tmp.dir, &.{"."}, 0,
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\       2      2        1       1           1  b.zig:2   S.m
        \\       1      1        0       0           0  a.zig:1   f
        \\       1      1        0       0           0  a.zig:2   test "f"
        \\
        \\3 functions in 3 files: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line, "");
}

test "a reader that stops early ends the report quietly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Enough functions that the report is more than a pipe holds.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    for (0..4000) |i| try source.print(gpa, "fn f{d}() void {{}}\n", .{i});
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = source.items });
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.gnarl_exe, gpa);
    defer gpa.free(exe);

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "a.zig" },
        .cwd = .{ .dir = tmp.dir },
        .stdout = .pipe,
        .stderr = .pipe,
    });
    child.stdout.?.close(io);
    child.stdout = null;
    var buffer: [1024]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &buffer);
    const stderr = try stderr_reader.interface.allocRemaining(gpa, .limited(1 << 20));
    defer gpa.free(stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    try std.testing.expectEqualStrings("", stderr);
}

test "--json: the same rows, for a program to read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f(x: anytype) void {\n    _ = x;\n}\n" });

    const result = try runGnarl(tmp.dir, &.{ "--json", "a.zig" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const Doc = struct { functions: []const report.Row, files: usize, thresholds: Thresholds };
    const doc = try std.json.parseFromSlice(Doc, gpa, result.stdout, .{});
    defer doc.deinit();
    try std.testing.expectEqual(1, doc.value.functions.len);
    try std.testing.expectEqualStrings("f", doc.value.functions[0].name);
    try std.testing.expectEqual(2, doc.value.functions[0].params_weighted);
    try std.testing.expectEqual(1, doc.value.files);
}

test "a file that does not parse is reported and the rest still listed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "fn f( {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "good.zig", .data = "fn g() void {}\n" });

    try expectRun(tmp.dir, &.{"."}, 2,
        \\cyclomatic  lines  nesting  params  weighted  location    function
        \\       1      1        0       0           0  good.zig:1  g
        \\
        \\1 function in 1 file: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line, "gnarl: bad.zig:1:7: expected type expression, found '{'\n");
}

test "a path that is missing or holds no .zig file is an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, "gen");
    try tmp.dir.writeFile(io, .{ .sub_path = "gen/a.zig", .data = "fn a() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "fn b() void {}\n" });

    try expectRun(tmp.dir, &.{ "nope", "empty", "gen", "--exclude", "gen/a.zig", "b.zig" }, 2,
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\       1      1        0       0           0  b.zig:1   b
        \\
        \\1 function in 1 file: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line,
        \\gnarl: nope: FileNotFound
        \\gnarl: empty: no .zig file to read (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)
        \\gnarl: gen: no .zig file to read (hidden files and directories, zig-out, zig-pkg and excluded paths are skipped)
        \\
    );
}

test "--version, --help and usage errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectRun(tmp.dir, &.{"--version"}, 0, "gnarl " ++ build_options.version ++ "\n", "");
    try expectRun(tmp.dir, &.{"--help"}, 0, usage, "");
    try expectRun(tmp.dir, &.{}, 2, "", usage);
    try expectRun(tmp.dir, &.{ "src", "--frobnicate" }, 2, "", "gnarl: unknown option '--frobnicate'\n\n" ++ usage);
}

test "parseArgs: paths and excludes, in any order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const run = (try parseArgs(arena, &.{ "src", "--exclude", "./_tmp/", "--exclude=src/vendor", "build.zig" })).run;
    try std.testing.expectEqual(2, run.paths.len);
    try std.testing.expectEqualStrings("src", run.paths[0]);
    try std.testing.expectEqualStrings("build.zig", run.paths[1]);
    try std.testing.expectEqual(2, run.excludes.len);
    try std.testing.expectEqualStrings("_tmp", run.excludes[0]);
    try std.testing.expectEqualStrings(try std.fs.path.resolveAlloc(arena, &.{"src/vendor"}), run.excludes[1]);
    try std.testing.expectEqual(.text, run.format);
}

test "parseArgs: --format and --json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(.md, (try parseArgs(arena, &.{ "--format", "md", "src" })).run.format);
    try std.testing.expectEqual(.json, (try parseArgs(arena, &.{ "src", "--format=json" })).run.format);
    try std.testing.expectEqual(.json, (try parseArgs(arena, &.{ "src", "--json" })).run.format);
    try std.testing.expectEqualStrings("--format takes text, json or md, not 'xml'", (try parseArgs(arena, &.{ "--format", "xml", "src" })).usage_error);
    try std.testing.expectEqualStrings("--format takes text, json or md, not ''", (try parseArgs(arena, &.{ "src", "--format" })).usage_error);
    try std.testing.expectEqualStrings("unknown option '--formats'", (try parseArgs(arena, &.{ "--formats", "src" })).usage_error);
}

test "parseArgs: help, version and usage errors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try parseArgs(arena, &.{ "src", "--help" }) == .help);
    try std.testing.expect(try parseArgs(arena, &.{ "-h", "-x" }) == .help);
    try std.testing.expect(try parseArgs(arena, &.{ "--version", "src" }) == .version);
    try std.testing.expectEqualStrings("--exclude needs a path", (try parseArgs(arena, &.{ "src", "--exclude" })).usage_error);
    try std.testing.expectEqualStrings("--exclude needs a path", (try parseArgs(arena, &.{ "src", "--exclude=" })).usage_error);
    try std.testing.expectEqualStrings("unknown option '-x'", (try parseArgs(arena, &.{ "-x", "--help" })).usage_error);
    try std.testing.expectEqualStrings("", (try parseArgs(arena, &.{})).usage_error);
    try std.testing.expectEqualStrings("", (try parseArgs(arena, &.{ "--exclude", "src" })).usage_error);
}

test {
    _ = @import("children.zig");
    _ = @import("cyclomatic.zig");
    _ = @import("functions.zig");
    _ = @import("golden.zig");
    _ = @import("lines.zig");
    _ = @import("measure.zig");
    _ = @import("nesting.zig");
    _ = @import("params.zig");
    _ = @import("report.zig");
    _ = @import("thresholds.zig");
    _ = @import("walk.zig");
}

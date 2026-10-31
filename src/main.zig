//! The `gnarl` command: complexity metrics for each function in Zig source.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;

const build_options = @import("build_options");
const test_options = @import("test_options");
const cyclomatic = @import("cyclomatic.zig");
const functions = @import("functions.zig");
const lines = @import("lines.zig");
const nesting = @import("nesting.zig");
const params = @import("params.zig");
const walk = @import("walk.zig");

const usage =
    \\Usage: gnarl [--exclude <path>]... <path>...
    \\       gnarl --version
    \\
    \\Lists every function and test block in each file named, and in every
    \\.zig file under each directory named, a line each with its metrics:
    \\path:line: name cyclomatic=N lines=N nesting=N params=N
    \\params_weighted=N. Hidden files and directories, zig-out and zig-pkg
    \\are skipped.
    \\
    \\  --exclude <path>  Skip this file or directory, named as gnarl prints
    \\                    paths: relative to the current directory. May be
    \\                    given more than once.
    \\
    \\Exit status: 0 if every file was read, 2 on a usage error, a path that
    \\could not be read or holds no .zig file, or a file that does not parse.
    \\The files that could be read are listed either way.
    \\
;

/// `Ast` offsets are 32-bit.
const max_source_bytes = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // Streaming, so that when stdout is a file the shell has already
    // written to, the list lands after what is there rather than over it.
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

    // What one file needs is freed before the next is read.
    var file_arena: std.heap.ArenaAllocator = .init(gpa);
    defer file_arena.deinit();
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
        for (try functions.list(file_arena.allocator(), &tree)) |function| {
            const cc = try cyclomatic.count(file_arena.allocator(), &tree, function.node);
            const lloc = try lines.count(file_arena.allocator(), &tree, function.node);
            const depth = try nesting.depth(file_arena.allocator(), &tree, function.node);
            const p = params.count(&tree, function);
            try out.print("{s}:{d}: {s} cyclomatic={d} lines={d} nesting={d} params={d} params_weighted={d}\n", .{
                path, function.line, function.name, cc, lloc, depth, p.count, p.weighted,
            });
        }
    }
    try out.flush();
    return if (unreadable) 2 else 0;
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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (optionValue(args, &i, "--exclude")) |path| {
            if (path.len == 0) return .{ .usage_error = "--exclude needs a path" };
            try excludes.append(arena, try std.fs.path.resolveAlloc(arena, &.{path}));
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage_error = try arena.print("unknown option '{s}'", .{arg}) };
        } else try paths.append(arena, arg);
    }
    if (paths.items.len == 0) return .{ .usage_error = "" };
    return .{ .run = .{ .paths = paths.items, .excludes = excludes.items } };
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

/// Runs gnarl in `dir` and checks how it exits and what it writes.
fn expectRun(dir: Io.Dir, argv: []const []const u8, exit: u8, stdout: []const u8, stderr: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, test_options.gnarl_exe, gpa);
    defer gpa.free(exe);
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, exe);
    try full.appendSlice(gpa, argv);
    const result = try std.process.run(gpa, io, .{ .argv = full.items, .cwd = .{ .dir = dir } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(stdout, result.stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = exit }, result.term);
}

test "lists each file's functions, files in path order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.zig", .data = "const S = struct {\n    fn m(c: bool) void {\n        if (c) {}\n    }\n};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "fn f() void {}\ntest \"f\" {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/c.zig", .data = "const x = 1;\n" });

    const sep = std.fs.path.sep_str;
    try expectRun(tmp.dir, &.{"src"}, 0,
        \\src
    ++ sep ++
        \\a.zig:1: f cyclomatic=1 lines=1 nesting=0 params=0 params_weighted=0
        \\src
    ++ sep ++
        \\a.zig:2: test "f" cyclomatic=1 lines=1 nesting=0 params=0 params_weighted=0
        \\src
    ++ sep ++
        \\b.zig:2: S.m cyclomatic=2 lines=2 nesting=1 params=1 params_weighted=1
        \\
    , "");
}

test "a file that does not parse is reported and the rest still listed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "fn f( {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "good.zig", .data = "fn g() void {}\n" });

    try expectRun(tmp.dir, &.{"."}, 2, "good.zig:1: g cyclomatic=1 lines=1 nesting=0 params=0 params_weighted=0\n", "gnarl: bad.zig:1:7: expected type expression, found '{'\n");
}

test "a path that is missing or holds no .zig file is an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, "gen");
    try tmp.dir.writeFile(io, .{ .sub_path = "gen/a.zig", .data = "fn a() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "fn b() void {}\n" });

    try expectRun(tmp.dir, &.{ "nope", "empty", "gen", "--exclude", "gen/a.zig", "b.zig" }, 2, "b.zig:1: b cyclomatic=1 lines=1 nesting=0 params=0 params_weighted=0\n",
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
    _ = @import("lines.zig");
    _ = @import("nesting.zig");
    _ = @import("params.zig");
    _ = @import("walk.zig");
}

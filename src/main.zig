//! The `gnarl` command: complexity metrics for each function in Zig source.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ast = std.zig.Ast;

const build_options = @import("build_options");
const test_options = @import("test_options");
const config = @import("config.zig");
const explain = @import("explain.zig");
const measure = @import("measure.zig");
const messages = @import("messages.zig");
const report = @import("report.zig");
const select = @import("select.zig");
const skill = @import("skill.zig");
const Classes = @import("thresholds.zig").Classes;
const walk = @import("walk.zig");

const usage =
    \\Usage: gnarl [--exclude <path>]... [--config <file>] [--check]
    \\             [--all] [--top <n>] [--function <function>]... [--no-ignore]
    \\             [--format <format>] [--json] [<path>...]
    \\       gnarl --explain <function>... [<path>...]
    \\       gnarl skill [--install <dir>]
    \\       gnarl --version | --help
    \\
    \\Measures every function and test block in each file named, and in
    \\every .zig file under each directory named (the current directory
    \\when none is): cyclomatic complexity, logical lines, nesting depth and
    \\parameters (plain, and weighted with a type parameter and an anytype
    \\counted twice). One row per function over a threshold, worst first,
    \\and a summary of them all; a number over its warning threshold is
    \\marked !, over its critical one !!. Hidden files and directories,
    \\zig-out and zig-pkg are skipped, and in a git work tree what git
    \\ignores, unless the file or directory is named outright.
    \\
    \\gnarl skill prints what an AI agent needs to work with gnarl: the
    \\loop, the rules with examples, the output; --install <dir> writes it
    \\to <dir>/gnarl/SKILL.md.
    \\
    \\The thresholds depend on the class of code a file is in, hot, normal
    \\or cold, which complexity.zon in the current directory gives by globs,
    \\with any thresholds of its own. With no such file every file is normal.
    \\
    \\  --exclude <path>  Skip this file or directory, named as gnarl prints
    \\                    paths: relative to the current directory. May be
    \\                    given more than once.
    \\  --no-ignore       Read what git ignores too.
    \\  --config <file>   Read the classes and thresholds from this file
    \\                    rather than complexity.zon.
    \\  --check           Exit 1 if a function is over a critical threshold.
    \\  --all             List every function, within its limits or not.
    \\  --top <n>         List at most the n worst.
    \\  --function <function>
    \\                    List only this function, whatever its numbers,
    \\                    named as --explain takes it; its file need not be
    \\                    among the paths. May be given more than once.
    \\  --explain <function>
    \\                    Say why the function scores what it does, metric by
    \\                    metric, rather than report: each construct counted
    \\                    and where, the deepest nesting, the lines left out,
    \\                    each parameter. The function is path:line as the
    \\                    report prints it (or any line inside it), or its
    \\                    name or the end of it (record for Validator.record),
    \\                    looked for in the paths given, or the current
    \\                    directory if none. May be given more than once.
    \\  --format <format> text (the default, a table); md (a Markdown table,
    \\                    for a review); json or xml (every field and all
    \\                    that stderr says, versioned); csv or tsv (a header,
    \\                    then a row per function, or per explained item).
    \\  --json            The same as --format json.
    \\
    \\Exit status: 0 if every file was read (and, with --check, no function
    \\is over a critical threshold); 1 if --check found one; 2 on a usage
    \\error, a configuration that cannot be used, a path that could not be
    \\read or holds no .zig file, a file that does not parse, or an
    \\--explain that names no function or more than one. The files that
    \\could be read are reported either way.
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
        .skill => |install_dir| {
            if (install_dir) |dir| {
                const path = skill.install(arena, io, dir) catch |err| {
                    std.debug.print("gnarl: {s}: {t}\n", .{ dir, err });
                    return 2;
                };
                try out.print("{s}\n", .{path});
            } else try out.writeAll(skill.text);
            out.flush() catch |err| return closedEarly(err, &stdout_writer, 0);
            return 0;
        },
        .usage_error => |message| {
            if (message.len > 0) std.debug.print("gnarl: {s}\n\n", .{message});
            std.debug.print("{s}", .{usage});
            return 2;
        },
    };

    const cwd = Io.Dir.cwd();
    // Everything said on stderr, kept for the documents that carry it.
    var said: messages.Messages = .{ .arena = arena };
    const settings = try loadConfig(gpa, arena, io, cwd, run.config, &said) orelse {
        // A document that carries everything says so on stdout too.
        const status: u8 = 2;
        if (run.format == .json or run.format == .xml) {
            if (run.explain.len > 0) {
                explain.write(out, run.format, &.{}, .{ .version = build_options.version, .messages = said.items.items }) catch |err| return closedEarly(err, &stdout_writer, status);
            } else {
                report.write(out, run.format, &.{}, .{ .rows = &.{} }, .{
                    .version = build_options.version,
                    .files = 0,
                    .classes = .defaults,
                    .messages = said.items.items,
                }) catch |err| return closedEarly(err, &stdout_writer, status);
            }
            out.flush() catch |err| return closedEarly(err, &stdout_writer, status);
        }
        return status;
    };
    var search: ?explain.Search = if (run.explain.len > 0) try .init(arena, run.explain) else null;
    const picks = try arena.alloc(select.Selector, run.functions.len);
    for (run.functions, picks) |text, *p| p.* = try select.Selector.parse(arena, text);
    // With no path, gnarl reads the current directory; but a function
    // named by path:line needs no path besides, so --explain and
    // --function naming only those read only their files.
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.appendSlice(arena, run.paths);
    const selectors = if (search) |s| s.selectors else picks;
    const by_name = for (selectors) |s| {
        if (s == .name) break true;
    } else false;
    if (paths.items.len == 0 and (selectors.len == 0 or by_name)) try paths.append(arena, ".");
    for (selectors) |s| switch (s) {
        .at => |at| try paths.append(arena, at.path),
        .name => {},
    };
    var files: std.ArrayList([]const u8) = .empty;
    for (paths.items) |arg| {
        const before = files.items.len;
        walk.collect(arena, io, cwd, arg, run.excludes, &files, .{ .git = !run.no_ignore }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                try said.fail(arg, "{t}", .{err});
                continue;
            },
        };
        // Listing nothing would read exactly like a directory with no
        // functions in it.
        if (files.items.len == before) {
            try said.fail(arg, "no .zig file to read (hidden files and directories, zig-out, zig-pkg, excluded paths and what git ignores are skipped)", .{});
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
                try said.fail(path, "{t}", .{err});
                continue;
            },
        };
        defer gpa.free(source);
        var tree = try Ast.parse(gpa, source, .{});
        defer tree.deinit(gpa);
        if (tree.errors.len > 0) {
            try sayParseErrors(&said, path, &tree);
            continue;
        }
        measured += 1;
        const class = settings.classOf(path);
        if (search) |*s| {
            try s.file(arena, file_arena.allocator(), path, &tree, class, settings.classes.get(class));
            continue;
        }
        const first = rows.items.len;
        try measure.file(arena, file_arena.allocator(), path, &tree, &rows);
        for (rows.items[first..]) |*row| row.class = class;
    }
    if (search) |s| {
        const found = try s.results(arena, &said);
        const status: u8 = if (said.errors() > 0) 2 else 0;
        explain.write(out, run.format, found.explanations, .{ .version = build_options.version, .messages = said.items.items }) catch |err| return closedEarly(err, &stdout_writer, status);
        out.flush() catch |err| return closedEarly(err, &stdout_writer, status);
        return status;
    }
    try report.rank(arena, rows.items, settings.classes);
    var listing: report.Listing = .{ .all = run.all, .top = run.top };
    if (picks.len > 0) {
        const picked = try select.pick(arena, rows.items, picks);
        for (picked.unmatched) |s| switch (picks[s]) {
            // A file that could not be read has been said already.
            .at => |at| if (contains(files.items, at.path)) {
                try said.add(.{ .level = .@"error", .path = at.path, .line = at.line, .text = "no function at or around that line" });
            },
            .name => try said.fail(run.functions[s], "no function by that name in the files read", .{}),
        };
        listing.picked = picked.picked;
    }
    const listed = try report.list(arena, rows.items, listing);
    const critical = report.countCritical(rows.items);
    const failed = run.check and critical > 0;
    const status: u8 = if (said.errors() > 0) 2 else if (failed) 1 else 0;
    report.write(out, run.format, rows.items, listed, .{
        .version = build_options.version,
        .files = measured,
        .classes = settings.classes,
        .check = .{ .asked = run.check, .failed = failed, .critical = critical },
        .messages = said.items.items,
    }) catch |err| return closedEarly(err, &stdout_writer, status);
    out.flush() catch |err| return closedEarly(err, &stdout_writer, status);
    // The rows run worst first, so the first is the one to look at.
    if (failed) std.debug.print("gnarl: --check: {d} function{s} over a critical threshold; gnarl --explain {s}:{d} says why the worst scores what it does\n", .{
        critical, if (critical == 1) "" else "s", rows.items[0].path, rows.items[0].line,
    });
    return status;
}

fn contains(items: []const []const u8, item: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i, item)) return true;
    return false;
}

/// The configuration in the file `named`, or in complexity.zon if there is
/// one, or the defaults. Null when the file cannot be used: why is said in
/// `said`.
fn loadConfig(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, dir: Io.Dir, named: ?[]const u8, said: *messages.Messages) std.mem.Allocator.Error!?config.Config {
    const path = named orelse config.default_path;
    const source = dir.readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            if (err == error.FileNotFound and named == null) return .{};
            try said.fail(path, "{t}", .{err});
            return null;
        },
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: config.Problem = undefined;
    return config.parse(gpa, arena, source, &diagnostics, &problem) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseZon => {
            for (diagnostics.errors) |e| {
                try said.add(.{ .level = .@"error", .path = path, .line = @intCast(e.loc.line + 1), .column = @intCast(e.loc.column + 1), .text = e.msg });
                for (e.notes) |note| {
                    try said.add(.{ .level = .note, .path = path, .line = @intCast(note.loc.line + 1), .column = @intCast(note.loc.column + 1), .text = note.msg });
                }
            }
            return null;
        },
        error.Invalid => {
            try said.fail(path, "{s}", .{problem.message});
            return null;
        },
    };
}

/// A reader that stops early, as `gnarl src | head` does, closes the pipe:
/// that ends the report quietly, with the status it would have had. Any
/// other failure to write is an error.
fn closedEarly(err: Io.Writer.Error, stdout_writer: *const Io.File.Writer, status: u8) !u8 {
    const cause = stdout_writer.err orelse return err;
    if (cause == error.BrokenPipe) return status;
    return cause;
}

/// Says in `said` where `tree` does not parse and why.
fn sayParseErrors(said: *messages.Messages, path: []const u8, tree: *const Ast) std.mem.Allocator.Error!void {
    for (tree.errors) |parse_error| {
        var message: Io.Writer.Allocating = .init(said.arena);
        tree.renderError(parse_error, &message.writer) catch return error.OutOfMemory;
        const loc = tree.tokenLocation(0, parse_error.token);
        try said.add(.{
            .level = .@"error",
            .path = path,
            .line = @intCast(loc.line + 1),
            .column = @intCast(loc.column + tree.errorOffset(parse_error) + 1),
            .text = message.written(),
        });
    }
}

/// What the command line asks for.
const Command = union(enum) {
    run: struct {
        paths: []const []const u8,
        /// Cleaned, as `walk.collect` cleans the paths it lists.
        excludes: []const []const u8,
        format: report.Format,
        /// The configuration file named, if one is.
        config: ?[]const u8,
        check: bool,
        /// The functions to explain, as given; none for a report.
        explain: []const []const u8,
        all: bool,
        top: ?usize,
        /// Read what git ignores too.
        no_ignore: bool,
        /// The functions the report is to list, as given; none for all.
        functions: []const []const u8,
    },
    help,
    version,
    /// `gnarl skill`, and the directory to install it under, if any.
    skill: ?[]const u8,
    /// Why the command line cannot be run; empty when the usage alone says.
    usage_error: []const u8,
};

/// `-h` and `--help`, `--version`, and an unknown option take effect where
/// they stand; anything after them is not read.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Command {
    // A path named skill is ./skill.
    if (args.len > 0 and std.mem.eql(u8, args[0], "skill")) {
        if (args.len == 1) return .{ .skill = null };
        var i: usize = 1;
        if (optionValue(args, &i, "--install")) |dir| {
            if (dir.len == 0) return .{ .usage_error = "--install needs a directory" };
            if (i + 1 == args.len) return .{ .skill = dir };
        }
        return .{ .usage_error = "gnarl skill takes --install <dir>, or nothing" };
    }
    var paths: std.ArrayList([]const u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    var format: report.Format = .text;
    var config_path: ?[]const u8 = null;
    var check = false;
    var to_explain: std.ArrayList([]const u8) = .empty;
    var all = false;
    var top: ?usize = null;
    var no_ignore = false;
    var to_list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-ignore")) {
            no_ignore = true;
            continue;
        }
        if (optionValue(args, &i, "--exclude")) |path| {
            if (path.len == 0) return .{ .usage_error = "--exclude needs a path" };
            try excludes.append(arena, try std.fs.path.resolveAlloc(arena, &.{path}));
        } else if (optionValue(args, &i, "--top")) |n| {
            top = std.fmt.parseInt(usize, n, 10) catch 0;
            if (top == 0) return .{ .usage_error = try arena.print("--top takes how many functions to list, 1 or more, not '{s}'", .{n}) };
        } else if (optionValue(args, &i, "--function")) |function| {
            if (function.len == 0) return .{ .usage_error = "--function needs a function: path:line, or a name" };
            try to_list.append(arena, function);
        } else if (optionValue(args, &i, "--explain")) |function| {
            if (function.len == 0) return .{ .usage_error = "--explain needs a function: path:line, or a name" };
            try to_explain.append(arena, function);
        } else if (optionValue(args, &i, "--config")) |path| {
            if (path.len == 0) return .{ .usage_error = "--config needs a file" };
            config_path = path;
        } else if (optionValue(args, &i, "--format")) |name| {
            format = std.meta.stringToEnum(report.Format, name) orelse
                return .{ .usage_error = try arena.print("--format takes text, md, json, xml, csv or tsv, not '{s}'", .{name}) };
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage_error = try arena.print("unknown option '{s}'", .{arg}) };
        } else try paths.append(arena, arg);
    }
    if (to_explain.items.len > 0 and (check or all or top != null or to_list.items.len > 0)) {
        return .{ .usage_error = "--check, --all, --top and --function are for the report, not --explain" };
    }
    return .{ .run = .{
        .paths = paths.items,
        .excludes = excludes.items,
        .format = format,
        .config = config_path,
        .check = check,
        .explain = to_explain.items,
        .all = all,
        .top = top,
        .no_ignore = no_ignore,
        .functions = to_list.items,
    } };
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

const thresholds_line = "Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.\n";

test "a row per function, worst first, from every file read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const S = struct {\n    fn m(c: bool) void {\n        if (c) {}\n    }\n};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f() void {}\ntest \"f\" {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.zig", .data = "const x = 1;\n" });

    try expectRun(tmp.dir, &.{ "--all", "." }, 0,
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\       2      2        1       1         1    b.zig:2   S.m
        \\       1      1        0       0         0    a.zig:1   f
        \\       1      1        0       0         0    a.zig:2   test "f"
        \\
        \\3 functions in 3 files: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line, "");
}

test "in a git work tree, what git ignores is not read; --no-ignore reads it" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = std.process.run(arena, io, .{ .argv = &.{ "git", "--version" } }) catch return error.SkipZigTest;
    if (git.term != .exited or git.term.exited != 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/_tmp");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/.gitignore", .data = "_tmp/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.zig", .data = "fn a() void {}\n" });
    // Scratch that does not even parse: read, it would fail the run.
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/_tmp/b.zig", .data = "fn b( {}\n" });
    var proj = try tmp.dir.openDir(io, "proj", .{});
    defer proj.close(io);
    const init = try std.process.run(arena, io, .{ .argv = &.{ "git", "init", "-q" }, .cwd = .{ .dir = proj } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, init.term);

    // gnarl walks its own current directory here, as a person running it
    // in a repository does.
    try expectRun(proj, &.{"--all"}, 0,
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\       1      1        0       0         0    a.zig:1   a
        \\
        \\1 function in 1 file: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line, "");
    const all = try runGnarl(proj, &.{ "--all", "--no-ignore" });
    defer std.testing.allocator.free(all.stdout);
    defer std.testing.allocator.free(all.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, all.term);
    try std.testing.expect(std.mem.startsWith(u8, all.stderr, "gnarl: _tmp" ++ std.fs.path.sep_str ++ "b.zig:1:7: "));
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
        .argv = &.{ exe, "--all", "a.zig" },
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

    const result = try runGnarl(tmp.dir, &.{ "--json", "--all", "a.zig" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const doc = try std.json.parseFromSlice(Document, gpa, result.stdout, .{});
    defer doc.deinit();
    try std.testing.expectEqual(1, doc.value.functions.len);
    try std.testing.expectEqual(1, doc.value.measured);
    try std.testing.expectEqual(report.NotListed{}, doc.value.not_listed);
    try std.testing.expectEqual(3, doc.value.functions[0].end_line);
    try std.testing.expectEqualStrings("f", doc.value.functions[0].name);
    try std.testing.expectEqual(2, doc.value.functions[0].params_weighted);
    try std.testing.expectEqual(1, doc.value.files);
}

/// A function with twelve ifs: cyclomatic 13, a warning in normal code and
/// critical in hot code.
const thirteen = source: {
    var s: []const u8 = "fn f(c: bool) void {\n";
    for (0..12) |_| s = s ++ "    if (c) {}\n";
    break :source s ++ "}\n";
};

test "by default only what is over a threshold; --top, and --function to pick" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = thirteen ++ "fn g() void {}\n" });

    const f_row =
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\      13!    13        1       1         1    a.zig:1   f
        \\
        \\2 functions in 1 file: 0 over a critical threshold (!!), 1 more over a warning one (!).
        \\
    ;
    try expectRun(tmp.dir, &.{"a.zig"}, 0, f_row ++ "1 within limits is not listed; --all lists every function.\n" ++ thresholds_line, "");
    // No path reads the current directory.
    try expectRun(tmp.dir, &.{}, 0, f_row ++ "1 within limits is not listed; --all lists every function.\n" ++ thresholds_line, "");
    try expectRun(tmp.dir, &.{ "--all", "--top", "1", "a.zig" }, 0, f_row ++ "1 more is not listed: --top 1 keeps the worst 1.\n" ++ thresholds_line, "");
    // Picked by a line inside it, with no path besides.
    try expectRun(tmp.dir, &.{ "--function", "a.zig:3" }, 0, f_row ++ "1 not picked by --function is not listed.\n" ++ thresholds_line, "");
    try expectRun(tmp.dir, &.{ "--function", "g", "a.zig" }, 0,
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\       1      1        0       0         0    a.zig:15  g
        \\
        \\2 functions in 1 file: 0 over a critical threshold (!!), 1 more over a warning one (!).
        \\1 not picked by --function is not listed.
        \\
    ++ thresholds_line, "");
    const result = try runGnarl(tmp.dir, &.{ "--function", "nope", "a.zig" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
    try std.testing.expectEqualStrings("gnarl: nope: no function by that name in the files read\n", result.stderr);
}

test "--check fails on a critical threshold, by the class complexity.zon gives the file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hot.zig", .data = thirteen });
    try tmp.dir.writeFile(io, .{ .sub_path = "normal.zig", .data = thirteen });

    // No configuration: both normal, a warning each, and --check passes.
    {
        const result = try runGnarl(tmp.dir, &.{ "--check", "." });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("", result.stderr);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "complexity.zon", .data = ".{ .hot = .{\"hot.zig\"} }\n" });
    {
        const result = try runGnarl(tmp.dir, &.{ "--check", "." });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
        try std.testing.expectEqualStrings("gnarl: --check: 1 function over a critical threshold; gnarl --explain hot.zig:1 says why the worst scores what it does\n", result.stderr);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "      13!!  ") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "      13!   ") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Thresholds for hot code (warning, critical): cyclomatic 8, 12;") != null);
    }
    // Without --check the same report exits 0.
    {
        const result = try runGnarl(tmp.dir, &.{"."});
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    }
}

test "--explain: by path:line or by name; a name that fits none or several is an error" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f(c: bool) void {\n    if (c) {}\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.zig", .data = "const S = struct {\n    fn f() void {}\n};\n" });

    const one =
        \\a.zig:1  f  (normal code)
        \\
        \\cyclomatic 2: 1, and 1 for each of these
        \\  2:5  if  +1
        \\nesting 1: the deepest chain
        \\  2:5  if   1
        \\lines 2 of the 3 from signature to closing brace; not counted: 0 blank, 0 comment, 1 closing, 0 in nested functions
        \\params 1, weighted 1
        \\  c  bool  1
        \\
    ;
    // No path needed for a path:line, and any line inside will do.
    try expectRun(tmp.dir, &.{ "--explain", "a.zig:1" }, 0, one, "");
    try expectRun(tmp.dir, &.{ "--explain", "a.zig:3" }, 0, one, "");
    // A whole name beats the end of a longer one.
    try expectRun(tmp.dir, &.{ "--explain", "f", "a.zig" }, 0, one, "");
    {
        const result = try runGnarl(tmp.dir, &.{ "--explain", "S.f" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, "sub" ++ std.fs.path.sep_str ++ "b.zig:2  S.f  (normal code)\n"));
    }
    // The whole name wins over S.f, and says S.f was there.
    try expectRun(tmp.dir, &.{ "--explain", "f" }, 0, one, "gnarl: f: note: explained the function of exactly that name; 1 more ends with it:\n  sub" ++ std.fs.path.sep_str ++ "b.zig:2  S.f\n");
    try expectRun(tmp.dir, &.{ "--explain", "nope" }, 2, "", "gnarl: nope: no function by that name in the files read\n");
    try expectRun(tmp.dir, &.{ "--explain", "a.zig:9" }, 2, "", "gnarl: a.zig:9: no function at or around that line\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "fn f() void {}\n" });
    try expectRun(tmp.dir, &.{ "--explain", "f" }, 2, "",
        \\gnarl: f: 2 functions answer to that name; name one by path:line:
        \\  a.zig:1  f
        \\  c.zig:1  f
        \\
    );
}

test "a configuration that cannot be used is an error, and nothing is measured" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn a() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "typo.zon", .data = ".{ .hott = .{\"a.zig\"} }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "limits.zon", .data = ".{ .thresholds = .{ .hot = .{ .lines = .{ .warning = 9, .critical = 9 } } } }\n" });

    try expectRun(tmp.dir, &.{ "--config", "nope.zon", "." }, 2, "", "gnarl: nope.zon: FileNotFound\n");
    try expectRun(tmp.dir, &.{ "--config=limits.zon", "." }, 2, "", "gnarl: limits.zon: thresholds.hot.lines: the warning limit, 9, is not below the critical one, 9\n");
    try expectRun(tmp.dir, &.{ "--config", "typo.zon", "." }, 2, "",
        \\gnarl: typo.zon:1:5: unexpected field 'hott'
        \\gnarl: typo.zon:1:5: note: supported: 'hot', 'cold', 'thresholds'
        \\
    );

    // The documents that carry everything carry this too.
    const result = try runGnarl(tmp.dir, &.{ "--json", "--config", "typo.zon", "." });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
    const doc = try std.json.parseFromSlice(Document, std.testing.allocator, result.stdout, .{});
    defer doc.deinit();
    try std.testing.expectEqual(0, doc.value.functions.len);
    try std.testing.expectEqualStrings("unexpected field 'hott'", doc.value.errors[0].text);
    try std.testing.expectEqual(5, doc.value.errors[0].column.?);
    try std.testing.expectEqualStrings("supported: 'hot', 'cold', 'thresholds'", doc.value.notes[0].text);
}

/// The report's json document, read back whole: an unknown field is an
/// error, so a field added without the tests knowing fails them.
const Document = struct {
    schema: u32,
    gnarl: []const u8,
    files: usize,
    measured: usize,
    not_listed: report.NotListed,
    check: report.Check,
    thresholds: Classes,
    errors: []const Said,
    notes: []const Said,
    functions: []const report.Row,
};
const Said = struct { path: []const u8, line: ?u32, column: ?u32, text: []const u8, more: []const []const u8 };

test "--json says what stderr says: a file that does not parse, a missing path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "fn f( {}\n" });
    const result = try runGnarl(tmp.dir, &.{ "--json", "--check", "bad.zig", "nope" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
    const doc = try std.json.parseFromSlice(Document, gpa, result.stdout, .{});
    defer doc.deinit();
    try std.testing.expectEqual(2, doc.value.errors.len);
    try std.testing.expectEqualStrings("nope", doc.value.errors[0].path);
    try std.testing.expectEqualStrings("FileNotFound", doc.value.errors[0].text);
    try std.testing.expectEqualStrings("bad.zig", doc.value.errors[1].path);
    try std.testing.expectEqual(7, doc.value.errors[1].column.?);
    try std.testing.expectEqual(report.Check{ .asked = true }, doc.value.check);
    try std.testing.expectEqual(report.schema, doc.value.schema);
}

test "--format csv and tsv: a header, then a row per function listed" {
    const io = std.testing.io;
    const formats = @import("formats.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f() void {}\ntest \"x, \\\"y\\\"\" {}\n" });
    for ([_][]const u8{ "csv", "tsv" }) |format| {
        const result = try runGnarl(tmp.dir, &.{ "--format", format, "--all", "a.zig" });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        const table = try formats.readDelimited(arena, if (format[0] == 'c') .csv else .tsv, result.stdout);
        try std.testing.expectEqual(3, table.len);
        try std.testing.expectEqualStrings("path", table[0][0]);
        try std.testing.expectEqualStrings("test \"x, \\\"y\\\"\"", table[2][4]);
    }
}

test "a file that does not parse is reported and the rest still listed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "fn f( {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "good.zig", .data = "fn g() void {}\n" });

    try expectRun(tmp.dir, &.{"."}, 2,
        \\1 function in 1 file: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\1 within limits is not listed; --all lists every function.
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

    try expectRun(tmp.dir, &.{ "nope", "empty", "gen", "--exclude", "gen/a.zig", "b.zig", "--all" }, 2,
        \\cyclomatic  lines  nesting  params  weighted  location  function
        \\       1      1        0       0         0    b.zig:1   b
        \\
        \\1 function in 1 file: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line,
        \\gnarl: nope: FileNotFound
        \\gnarl: empty: no .zig file to read (hidden files and directories, zig-out, zig-pkg, excluded paths and what git ignores are skipped)
        \\gnarl: gen: no .zig file to read (hidden files and directories, zig-out, zig-pkg, excluded paths and what git ignores are skipped)
        \\
    );
}

test "--version, --help and usage errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectRun(tmp.dir, &.{"--version"}, 0, "gnarl " ++ build_options.version ++ "\n", "");
    try expectRun(tmp.dir, &.{"--help"}, 0, usage, "");
    // No path is the current directory: here, one with no .zig file.
    try expectRun(tmp.dir, &.{}, 2, "0 functions in 0 files: 0 over a critical threshold (!!), 0 more over a warning one (!).\n", "gnarl: .: no .zig file to read (hidden files and directories, zig-out, zig-pkg, excluded paths and what git ignores are skipped)\n");
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
    try std.testing.expectEqual(null, run.config);
    try std.testing.expect(!run.check);
    try std.testing.expect(!run.all);
    try std.testing.expectEqual(null, run.top);
    try std.testing.expect(!run.no_ignore);
    try std.testing.expect((try parseArgs(arena, &.{"--no-ignore"})).run.no_ignore);
}

test "parseArgs: --all, --top and --function" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const run = (try parseArgs(arena, &.{ "--all", "--top=5", "--function", "a.zig:3", "--function=parse" })).run;
    try std.testing.expect(run.all);
    try std.testing.expectEqual(5, run.top.?);
    try std.testing.expectEqual(2, run.functions.len);
    try std.testing.expectEqual(0, run.paths.len);
    try std.testing.expectEqualStrings("--top takes how many functions to list, 1 or more, not '0'", (try parseArgs(arena, &.{ "--top", "0", "src" })).usage_error);
    try std.testing.expectEqualStrings("--top takes how many functions to list, 1 or more, not 'x'", (try parseArgs(arena, &.{ "src", "--top=x" })).usage_error);
    try std.testing.expectEqualStrings("--function needs a function: path:line, or a name", (try parseArgs(arena, &.{ "src", "--function" })).usage_error);
    try std.testing.expectEqualStrings("--check, --all, --top and --function are for the report, not --explain", (try parseArgs(arena, &.{ "--all", "--explain", "f" })).usage_error);
}

test "parseArgs: --config and --check" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const run = (try parseArgs(arena, &.{ "--check", "--config", "ci.zon", "src" })).run;
    try std.testing.expect(run.check);
    try std.testing.expectEqualStrings("ci.zon", run.config.?);
    try std.testing.expectEqualStrings("ci.zon", (try parseArgs(arena, &.{ "src", "--config=ci.zon" })).run.config.?);
    try std.testing.expectEqualStrings("--config needs a file", (try parseArgs(arena, &.{ "src", "--config" })).usage_error);
}

test "gnarl skill prints the skill; --install writes it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectRun(tmp.dir, &.{"skill"}, 0, skill.text, "");
    const result = try runGnarl(tmp.dir, &.{ "skill", "--install", "agents" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("agents" ++ std.fs.path.sep_str ++ "gnarl" ++ std.fs.path.sep_str ++ "SKILL.md\n", result.stdout);
    const written = try tmp.dir.readFileAlloc(io, "agents/gnarl/SKILL.md", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(skill.text, written);
}

test "the skill names every flag gnarl takes, and no other" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const in_usage = try flags(arena, usage);
    const in_skill = try flags(arena, skill.text);
    var ok = true;
    for (in_usage.keys()) |flag| if (!in_skill.contains(flag)) {
        std.debug.print("{s} is in --help but not in the skill\n", .{flag});
        ok = false;
    };
    for (in_skill.keys()) |flag| if (!in_usage.contains(flag)) {
        std.debug.print("{s} is in the skill but gnarl does not take it\n", .{flag});
        ok = false;
    };
    try std.testing.expect(ok);
    try std.testing.expect(in_usage.count() >= 12);
}

/// Every `--flag` in `text`.
fn flags(arena: std.mem.Allocator, text: []const u8) !std.StringArrayHashMapUnmanaged(void) {
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (std.mem.findPos(u8, text, i, "--")) |at| {
        i = at + 2;
        if (at > 0 and (std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '-')) continue;
        var end = i;
        while (end < text.len and (std.ascii.isLower(text[end]) or (text[end] == '-' and end + 1 < text.len and std.ascii.isLower(text[end + 1])))) end += 1;
        if (end == i) continue;
        try out.put(arena, text[at..end], {});
        i = end;
    }
    return out;
}

test "parseArgs: gnarl skill" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(null, (try parseArgs(arena, &.{"skill"})).skill);
    try std.testing.expectEqualStrings("d", (try parseArgs(arena, &.{ "skill", "--install", "d" })).skill.?);
    try std.testing.expectEqualStrings("d", (try parseArgs(arena, &.{ "skill", "--install=d" })).skill.?);
    try std.testing.expectEqualStrings("gnarl skill takes --install <dir>, or nothing", (try parseArgs(arena, &.{ "skill", "src" })).usage_error);
    try std.testing.expectEqualStrings("--install needs a directory", (try parseArgs(arena, &.{ "skill", "--install" })).usage_error);
    // A path called skill is given as ./skill.
    try std.testing.expectEqualStrings("./skill", (try parseArgs(arena, &.{"./skill"})).run.paths[0]);
}

test "parseArgs: --explain, more than once, with or without paths" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const run = (try parseArgs(arena, &.{ "--explain", "a.zig:3", "--explain=Parser.next" })).run;
    try std.testing.expectEqual(2, run.explain.len);
    try std.testing.expectEqualStrings("Parser.next", run.explain[1]);
    try std.testing.expectEqual(0, run.paths.len);
    try std.testing.expectEqualStrings("--explain needs a function: path:line, or a name", (try parseArgs(arena, &.{"--explain"})).usage_error);
    try std.testing.expectEqualStrings("--check, --all, --top and --function are for the report, not --explain", (try parseArgs(arena, &.{ "--check", "--explain", "f" })).usage_error);
}

test "parseArgs: --format and --json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(.md, (try parseArgs(arena, &.{ "--format", "md", "src" })).run.format);
    try std.testing.expectEqual(.json, (try parseArgs(arena, &.{ "src", "--format=json" })).run.format);
    try std.testing.expectEqual(.json, (try parseArgs(arena, &.{ "src", "--json" })).run.format);
    try std.testing.expectEqual(.xml, (try parseArgs(arena, &.{ "--format", "xml", "src" })).run.format);
    try std.testing.expectEqual(.tsv, (try parseArgs(arena, &.{ "--format=tsv", "src" })).run.format);
    try std.testing.expectEqualStrings("--format takes text, md, json, xml, csv or tsv, not 'yaml'", (try parseArgs(arena, &.{ "--format", "yaml", "src" })).usage_error);
    try std.testing.expectEqualStrings("--format takes text, md, json, xml, csv or tsv, not ''", (try parseArgs(arena, &.{ "src", "--format" })).usage_error);
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
    try std.testing.expectEqual(0, (try parseArgs(arena, &.{})).run.paths.len);
    try std.testing.expectEqual(1, (try parseArgs(arena, &.{ "--exclude", "src" })).run.excludes.len);
}

test {
    _ = @import("children.zig");
    _ = @import("config.zig");
    _ = @import("docs.zig");
    _ = @import("explain.zig");
    _ = @import("formats.zig");
    _ = @import("cyclomatic.zig");
    _ = @import("functions.zig");
    _ = @import("glob.zig");
    _ = @import("golden.zig");
    _ = @import("lines.zig");
    _ = @import("measure.zig");
    _ = @import("messages.zig");
    _ = @import("nesting.zig");
    _ = @import("params.zig");
    _ = @import("report.zig");
    _ = @import("select.zig");
    _ = @import("skill.zig");
    _ = @import("thresholds.zig");
    _ = @import("walk.zig");
}

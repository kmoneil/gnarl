//! The `gnarl` command: complexity metrics for each function in Zig source.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ast = std.zig.Ast;

const build_options = @import("build_options");
const test_options = @import("test_options");
const baseline = @import("baseline.zig");
const config = @import("config.zig");
const diff = @import("diff.zig");
const explain = @import("explain.zig");
const fan = @import("fan.zig");
const measure = @import("measure.zig");
const messages = @import("messages.zig");
const report = @import("report.zig");
const select = @import("select.zig");
const skill = @import("skill.zig");
const Class = @import("thresholds.zig").Class;
const Classes = @import("thresholds.zig").Classes;
const walk = @import("walk.zig");

const usage =
    \\Usage: gnarl [--exclude <path>]... [--config <file>] [--check]
    \\             [--baseline <file>] [--update-baseline]
    \\             [--all] [--top <n>] [--function <function>]... [--no-ignore]
    \\             [--format <format>] [--json] [<path>...]
    \\       gnarl --explain <function>... [<path>...]
    \\       gnarl --diff <ref> [<path>...]
    \\       gnarl skill [--install <dir>]
    \\       gnarl --version | --help
    \\
    \\Measures every function and test block in each file named, and in
    \\every .zig file under each directory named (the current directory
    \\when none is): cyclomatic complexity, cognitive complexity (how hard
    \\it is to follow: each structure 1, and 1 more for each level it sits
    \\in), logical lines, nesting depth and parameters (plain, and weighted
    \\with a type parameter and an anytype counted twice). One row per
    \\function over a threshold, worst first, and a summary of them all;
    \\a number over its warning threshold is marked !, over its critical
    \\one !!. Hidden files and directories, zig-out and zig-pkg are
    \\skipped, and in a git work tree what git ignores, unless the file or
    \\directory is named outright.
    \\
    \\gnarl skill prints what an AI agent needs to work with gnarl: the
    \\loop, the rules with examples, the output; --install <dir> writes it
    \\to <dir>/gnarl/SKILL.md.
    \\
    \\The thresholds depend on the class of code a file is in, hot, normal
    \\or cold, which complexity.zon in the current directory gives by globs,
    \\with any thresholds of its own. With no such file every file is normal.
    \\A test block is held to the tests class's thresholds whatever its file.
    \\Its .exclude globs leave out what they match, as what git ignores is:
    \\not read under a directory named, read when named outright.
    \\
    \\  --exclude <path>  Skip this file or directory, named as gnarl prints
    \\                    paths: relative to the current directory. May be
    \\                    given more than once.
    \\  --no-ignore       Read what git ignores too.
    \\  --config <file>   Read the classes and thresholds from this file
    \\                    rather than complexity.zon.
    \\  --check           Exit 1 if a function is over a critical threshold,
    \\                    or with a baseline, over its critical limit and
    \\                    above the baseline's number for it: new or worse.
    \\  --baseline <file> The baseline --check holds to, or --update-baseline
    \\                    writes, rather than complexity.baseline (which
    \\                    --check holds to when it is there).
    \\  --update-baseline Write the baseline: each function now over a
    \\                    critical threshold, with its numbers, one a line.
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
    \\                    report prints it (or any line inside it), path:A-B
    \\                    for what lines A to B of the function around them
    \\                    cost and about what moving them into a function of
    \\                    their own would leave, or its
    \\                    name or the end of it (record for Validator.record),
    \\                    looked for in the paths given, or the current
    \\                    directory if none. May be given more than once.
    \\  --diff <ref>      Rather than report, list each function the change
    \\                    from the commit <ref> to the work tree touched,
    \\                    uncommitted edits and new files included, with its
    \\                    numbers before and after: worse first, then mixed
    \\                    (some up, some down), added, the same, better and
    \\                    removed.
    \\  --files           Rather than report functions, list each file: the
    \\                    files it imports (fan-out), the files read that
    \\                    import it (fan-in), and the modules it imports,
    \\                    which gnarl does not follow; the most coupled
    \\                    first. Takes --top.
    \\  --format <format> text (the default, a table); md (a Markdown table,
    \\                    for a review); json or xml (every field and all
    \\                    that stderr says, versioned); csv or tsv (a header,
    \\                    then a row per function, or per explained item).
    \\  --json            The same as --format json.
    \\
    \\Exit status: 0 if every file was read (and, with --check, nothing
    \\fails it); 1 if --check found what does; 2 on a usage error, a
    \\configuration or baseline that cannot be used or written, a path that
    \\could not be read or holds no .zig file, a file that does not parse,
    \\or an --explain that names no function or more than one. The files
    \\that could be read are reported either way.
    \\
;

/// `Ast` offsets are 32-bit.
const max_source_bytes = std.math.maxInt(u32);

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    // Streaming, so that when stdout is a file the shell has already
    // written to, the report lands after what is there rather than over it.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);

    const args = (try init.minimal.args.toSlice(arena))[1..];
    const run = switch (try parseArgs(arena, args)) {
        .run => |run| run,
        else => |command| return answer(arena, init.io, &stdout_writer, command),
    };
    const cwd = Io.Dir.cwd();
    // Everything said on stderr, kept for the documents that carry it.
    var said: messages.Messages = .{ .arena = arena };
    const settings = try loadConfig(init.gpa, arena, init.io, cwd, run.config, &said) orelse
        return stopEarly(&stdout_writer, run, said.items.items);
    const c: Context = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = init.io,
        .cwd = cwd,
        .run = run,
        .settings = settings,
        .said = &said,
        .stdout_writer = &stdout_writer,
    };
    if (run.diff) |ref| return runDiff(c, ref);
    if (run.explain.len > 0) return runExplain(c);
    if (run.files) return runFiles(c);
    return runReport(c);
}

/// A command that is not a run: the usage, the version, the skill, or why
/// the command line cannot be run.
fn answer(arena: std.mem.Allocator, io: Io, stdout_writer: *Io.File.Writer, command: Command) !u8 {
    const out = &stdout_writer.interface;
    switch (command) {
        .run => unreachable,
        .help => try out.writeAll(usage),
        .version => try out.print("gnarl {s}\n", .{build_options.version}),
        .skill => |install_dir| if (install_dir) |dir| {
            const path = skill.install(arena, io, dir) catch |err| {
                std.debug.print("gnarl: {s}: {t}\n", .{ dir, err });
                return 2;
            };
            try out.print("{s}\n", .{path});
        } else try out.writeAll(skill.text),
        .usage_error => |message| {
            if (message.len > 0) std.debug.print("gnarl: {s}\n\n", .{message});
            std.debug.print("{s}", .{usage});
            return 2;
        },
    }
    out.flush() catch |err| return closedEarly(err, stdout_writer, 0);
    return 0;
}

/// What every kind of run reads from and writes to.
const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    run: Run,
    settings: config.Config,
    /// Everything said on stderr, kept for the documents that carry it.
    said: *messages.Messages,
    stdout_writer: *Io.File.Writer,

    fn out(c: Context) *Io.Writer {
        return &c.stdout_writer.interface;
    }

    /// Flushes what was written, and returns `status`: a reader that
    /// stopped early is no failure.
    fn finish(c: Context, status: u8) !u8 {
        c.out().flush() catch |err| return closedEarly(err, c.stdout_writer, status);
        return status;
    }

    /// 2 when anything went wrong, else `otherwise`.
    fn exitStatus(c: Context, otherwise: u8) u8 {
        return if (c.said.errors() > 0) 2 else otherwise;
    }

    /// `source` parsed, or null when it does not parse: where and why is
    /// said, under `label`.
    fn parse(c: Context, label: []const u8, source: [:0]const u8) !?Ast {
        var tree = try Ast.parse(c.gpa, source, .{});
        if (tree.errors.len == 0) return tree;
        try sayParseErrors(c.said, label, &tree);
        tree.deinit(c.gpa);
        return null;
    }

    /// The file at `path`, read into `scratch` and parsed; null when it
    /// cannot be read or does not parse, which is said.
    fn readTree(c: Context, scratch: std.mem.Allocator, path: []const u8) !?Ast {
        const source = c.cwd.readFileAllocOptions(c.io, path, scratch, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                try c.said.fail(path, "{t}", .{err});
                return null;
            },
        };
        return c.parse(path, source);
    }
};

/// The files the paths name, or, with none, the current directory's; and
/// the file of each function named by `path:line`, which needs no path
/// besides. Sorted, each once; what cannot be read is said.
fn collectFiles(c: Context, selectors: []const select.Selector) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.appendSlice(c.arena, c.run.paths);
    const by_name = for (selectors) |s| {
        if (s == .name) break true;
    } else false;
    if (paths.items.len == 0 and (selectors.len == 0 or by_name)) try paths.append(c.arena, ".");
    for (selectors) |s| switch (s) {
        .at => |at| try paths.append(c.arena, at.path),
        .name => {},
    };
    var files: std.ArrayList([]const u8) = .empty;
    for (paths.items) |arg| try collectPath(c, arg, &files);
    walk.sortUnique(&files);
    return files.items;
}

fn collectPath(c: Context, arg: []const u8, files: *std.ArrayList([]const u8)) !void {
    const before = files.items.len;
    walk.collect(c.arena, c.io, c.cwd, arg, .{ .paths = c.run.excludes, .globs = c.settings.exclude }, files, .{ .git = !c.run.no_ignore }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return c.said.fail(arg, "{t}", .{err}),
    };
    // Listing nothing would read exactly like a directory with no
    // functions in it.
    if (files.items.len == before) {
        try c.said.fail(arg, "no .zig file to read (hidden files and directories, zig-out, zig-pkg, excluded paths and what git ignores are skipped)", .{});
    }
}

/// Reads and parses each of `files` and hands each tree to `sink.file`,
/// with the file's class and memory freed before the next file is read.
/// Returns how many files were measured.
fn readFiles(c: Context, files: []const []const u8, sink: anytype) !usize {
    var file_arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer file_arena.deinit();
    var measured: usize = 0;
    for (files) |path| {
        _ = file_arena.reset(.retain_capacity);
        var tree = try c.readTree(file_arena.allocator(), path) orelse continue;
        defer tree.deinit(c.gpa);
        measured += 1;
        try sink.file(file_arena.allocator(), path, &tree, c.settings.classOf(path));
    }
    return measured;
}

/// What `readFiles` hands each tree to for --explain: the search for the
/// functions named.
const ExplainSink = struct {
    search: *explain.Search,
    arena: std.mem.Allocator,
    classes: Classes,

    pub fn file(s: ExplainSink, scratch: std.mem.Allocator, path: []const u8, tree: *const Ast, class: Class) !void {
        try s.search.file(s.arena, scratch, path, tree, class, s.classes);
    }
};

/// What `readFiles` hands each tree to for the report: a row per
/// function, each held to its class.
const ReportSink = struct {
    rows: *std.ArrayList(report.Row),
    arena: std.mem.Allocator,

    pub fn file(s: ReportSink, scratch: std.mem.Allocator, path: []const u8, tree: *const Ast, class: Class) !void {
        const first = s.rows.items.len;
        try measure.file(s.arena, scratch, path, tree, s.rows);
        for (s.rows.items[first..]) |*row| row.class = .forFunction(class, row.kind == .@"test");
    }
};

/// What `readFiles` hands each tree to for --files: what each file
/// imports.
const FanSink = struct {
    files: *std.ArrayList(fan.File),
    arena: std.mem.Allocator,

    pub fn file(s: FanSink, _: std.mem.Allocator, path: []const u8, tree: *const Ast, _: Class) !void {
        try s.files.append(s.arena, try fan.of(s.arena, path, tree));
    }
};

/// `--files`: each file's imports, and the files read that import it.
fn runFiles(c: Context) !u8 {
    const files = try collectFiles(c, &.{});
    var found: std.ArrayList(fan.File) = .empty;
    _ = try readFiles(c, files, FanSink{ .files = &found, .arena = c.arena });
    try fan.link(c.arena, found.items);
    fan.sort(found.items);
    const status = c.exitStatus(0);
    fan.write(c.out(), c.run.format, found.items, .{ .version = build_options.version, .top = c.run.top, .messages = c.said.items.items }) catch |err| return closedEarly(err, c.stdout_writer, status);
    return c.finish(status);
}

/// `--explain`: why each function named scores what it does.
fn runExplain(c: Context) !u8 {
    var search: explain.Search = try .init(c.arena, c.run.explain);
    const files = try collectFiles(c, search.selectors);
    _ = try readFiles(c, files, ExplainSink{ .search = &search, .arena = c.arena, .classes = c.settings.classes });
    const found = try search.results(c.arena, c.said);
    const status = c.exitStatus(0);
    explain.write(c.out(), c.run.format, found.explanations, .{ .version = build_options.version, .messages = c.said.items.items }) catch |err| return closedEarly(err, c.stdout_writer, status);
    return c.finish(status);
}

/// The report: a row per function, worst first, and with --check, whether
/// any is over what it may be.
fn runReport(c: Context) !u8 {
    // A baseline is read only to check against it.
    const held: ?Held = if (c.run.check) switch (try loadBaseline(c.arena, c.io, c.cwd, c.run.baseline, c.said)) {
        .none => null,
        .held => |h| h,
        .failed => return stopEarly(c.stdout_writer, c.run, c.said.items.items),
    } else null;
    const picks = try c.arena.alloc(select.Selector, c.run.functions.len);
    for (c.run.functions, picks) |text, *p| p.* = try select.Selector.parse(c.arena, text);
    const files = try collectFiles(c, picks);
    var rows: std.ArrayList(report.Row) = .empty;
    const measured = try readFiles(c, files, ReportSink{ .rows = &rows, .arena = c.arena });
    try report.rank(c.arena, rows.items, c.settings.classes);
    const listed = try report.list(c.arena, rows.items, try listing(c, rows.items, picks, files));
    const check = try runCheck(c, rows.items, held, files);
    if (c.run.update_baseline) try updateBaseline(c.arena, c.io, c.cwd, c.run.baseline orelse baseline.default_path, rows.items, c.said);
    const status = c.exitStatus(if (check.failed) 1 else 0);
    report.write(c.out(), c.run.format, rows.items, listed, .{
        .version = build_options.version,
        .files = measured,
        .classes = c.settings.classes,
        .check = check,
        .messages = c.said.items.items,
    }) catch |err| return closedEarly(err, c.stdout_writer, status);
    c.out().flush() catch |err| return closedEarly(err, c.stdout_writer, status);
    if (check.failed) sayFailures(check);
    return status;
}

/// Which of the ranked `rows` the report lists: --all, --top, and the
/// functions --function picks, saying which pick none.
fn listing(c: Context, rows: []const report.Row, picks: []const select.Selector, files: []const []const u8) !report.Listing {
    var l: report.Listing = .{ .all = c.run.all, .top = c.run.top };
    if (picks.len == 0) return l;
    const picked = try select.pick(c.arena, rows, picks);
    for (picked.unmatched) |s| switch (picks[s]) {
        // A file that could not be read has been said already.
        .at => |at| if (contains(files, at.path)) {
            try c.said.add(.{ .level = .@"error", .path = at.path, .line = at.line, .text = at.missing() });
        },
        .name => try c.said.fail(c.run.functions[s], "no function by that name in the files read", .{}),
    };
    l.picked = picked.picked;
    return l;
}

/// What --check finds, held to the baseline if there is one; with no
/// --check, only how many functions are over a critical threshold.
fn runCheck(c: Context, rows: []const report.Row, held: ?Held, files: []const []const u8) !report.Check {
    var check: report.Check = .{ .asked = c.run.check, .critical = report.countCritical(rows) };
    if (!c.run.check) return check;
    const r = try baseline.ratchet(c.arena, rows, c.settings.classes, if (held) |h| h.base else null, files);
    check.failed = r.failures.len > 0;
    check.failures = r.failures;
    check.improved = r.improved;
    check.unneeded = r.unneeded;
    check.gone = r.gone;
    const h = held orelse return check;
    check.baseline = h.path;
    try sayBaselineNotes(c, h.path, r);
    return check;
}

/// What in the baseline at `path` --update-baseline would change: entries
/// to tighten, to drop as within their limits, and to drop as gone.
fn sayBaselineNotes(c: Context, path: []const u8, r: baseline.Ratchet) !void {
    if (r.improved > 0) try c.said.add(.{ .level = .note, .path = path, .text = try std.fmt.allocPrint(c.arena, "{d} baselined function{s} {s} under the baseline's numbers now; gnarl --update-baseline tightens it", .{
        r.improved, plural(r.improved), if (r.improved == 1) "is" else "are",
    }) });
    if (r.unneeded > 0) try c.said.add(.{ .level = .note, .path = path, .text = try std.fmt.allocPrint(c.arena, "{d} baselined function{s} {s} within {s} limits now; gnarl --update-baseline drops {s}", .{
        r.unneeded, plural(r.unneeded), if (r.unneeded == 1) "is" else "are", if (r.unneeded == 1) "its" else "their", if (r.unneeded == 1) "it" else "them",
    }) });
    if (r.gone > 0) try c.said.add(.{ .level = .note, .path = path, .text = try std.fmt.allocPrint(c.arena, "{d} baselined function{s} {s} gone (renamed, moved or deleted); gnarl --update-baseline drops {s}", .{
        r.gone, plural(r.gone), if (r.gone == 1) "is" else "are", if (r.gone == 1) "it" else "them",
    }) });
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// `--diff ref`: each function the change touched, before and after.
fn runDiff(c: Context, ref: []const u8) !u8 {
    const paths: []const []const u8 = if (c.run.paths.len > 0) c.run.paths else &.{"."};
    const changed = try diff.changedFiles(c.arena, c.io, ref, paths, .{ .paths = c.run.excludes, .globs = c.settings.exclude }, c.said) orelse &.{};
    var file_arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer file_arena.deinit();
    var touched: std.ArrayList(diff.Touched) = .empty;
    for (changed) |file| {
        _ = file_arena.reset(.retain_capacity);
        try diffFile(c, file_arena.allocator(), ref, file, &touched);
    }
    diff.sort(touched.items);
    const status = c.exitStatus(0);
    diff.write(c.out(), c.run.format, touched.items, .{
        .version = build_options.version,
        .ref = ref,
        .files = changed.len,
        .classes = c.settings.classes,
        .messages = c.said.items.items,
    }) catch |err| return closedEarly(err, c.stdout_writer, status);
    return c.finish(status);
}

/// The functions `file` had at `ref` and has now, compared, appended to
/// `touched`; nothing when a side cannot be read or parsed, which is said.
fn diffFile(c: Context, scratch: std.mem.Allocator, ref: []const u8, file: diff.File, touched: *std.ArrayList(diff.Touched)) !void {
    var before: ?Ast = null;
    defer if (before) |*t| t.deinit(c.gpa);
    if (file.status != .added) {
        const source = try diff.oldSource(scratch, c.io, ref, file) orelse
            return c.said.fail(file.path, "git could not show it as it was at {s}", .{ref});
        before = try c.parse(try std.fmt.allocPrint(c.arena, "{s}:{s}", .{ ref, file.path }), source) orelse return;
    }
    var after: ?Ast = null;
    defer if (after) |*t| t.deinit(c.gpa);
    if (file.status != .removed) after = try c.readTree(scratch, file.path) orelse return;
    try diff.compareFile(c.arena, scratch, file.path, if (before) |*t| t else null, if (after) |*t| t else null, c.settings.classOf(file.path), c.settings.classes, touched);
}

/// When a configuration or baseline cannot be used, a document that
/// carries everything still says so on stdout, with nothing measured.
fn stopEarly(stdout_writer: *Io.File.Writer, run: Run, said: []const messages.Message) !u8 {
    const status: u8 = 2;
    if (run.format != .json and run.format != .xml) return status;
    const out = &stdout_writer.interface;
    if (run.explain.len > 0) {
        explain.write(out, run.format, &.{}, .{ .version = build_options.version, .messages = said }) catch |err| return closedEarly(err, stdout_writer, status);
    } else {
        report.write(out, run.format, &.{}, .{ .rows = &.{} }, .{
            .version = build_options.version,
            .files = 0,
            .classes = .defaults,
            .messages = said,
        }) catch |err| return closedEarly(err, stdout_writer, status);
    }
    out.flush() catch |err| return closedEarly(err, stdout_writer, status);
    return status;
}

const Held = struct { path: []const u8, base: baseline.Baseline };

/// The baseline in the file `named`, or in complexity.baseline if there
/// is one. `failed` when the file cannot be used: why is said in `said`.
fn loadBaseline(arena: std.mem.Allocator, io: Io, dir: Io.Dir, named: ?[]const u8, said: *messages.Messages) std.mem.Allocator.Error!union(enum) { none, held: Held, failed } {
    const path = named orelse baseline.default_path;
    const text = dir.readFileAlloc(io, path, arena, .limited(1 << 28)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            if (err == error.FileNotFound and named == null) return .none;
            try said.fail(path, "{t}", .{err});
            return .failed;
        },
    };
    var problem: baseline.Problem = undefined;
    const base = baseline.parse(arena, text, &problem) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Invalid => {
            try said.add(.{ .level = .@"error", .path = path, .line = problem.line, .text = problem.message });
            return .failed;
        },
    };
    return .{ .held = .{ .path = path, .base = base } };
}

/// Writes the baseline of `rows` to `path`, unless a file could not be
/// read: then what it held would be left out.
fn updateBaseline(arena: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, rows: []const report.Row, said: *messages.Messages) !void {
    if (said.errors() > 0) return said.fail(path, "not written: a file that could not be read would be left out of it", .{});
    var text: Io.Writer.Allocating = .init(arena);
    const n = baseline.write(arena, &text.writer, rows) catch return error.OutOfMemory;
    dir.writeFile(io, .{ .sub_path = path, .data = text.written() }) catch |err| return said.fail(path, "{t}", .{err});
    try said.add(.{ .level = .note, .path = path, .text = try std.fmt.allocPrint(arena, "wrote {d} function{s} over a critical threshold", .{ n, plural(n) }) });
}

/// Says on stderr what fails --check, after the report: each function and
/// how, held to a baseline, or how many with none, and the --explain to
/// run for the first.
fn sayFailures(check: report.Check) void {
    const first = check.failures[0];
    const n = baseline.functionsFailing(check.failures);
    const path = check.baseline orelse {
        std.debug.print("gnarl: --check: {d} function{s} over a critical threshold; gnarl --explain {s}:{d} says why the worst scores what it does\n", .{ n, plural(n), first.path, first.line });
        return;
    };
    std.debug.print("gnarl: --check: {d} function{s} fail{s} against {s}:", .{ n, plural(n), if (n == 1) "s" else "", path });
    for (check.failures, 0..) |f, i| {
        const same = i > 0 and check.failures[i - 1].line == f.line and std.mem.eql(u8, check.failures[i - 1].path, f.path);
        if (same) {
            std.debug.print("; ", .{});
        } else std.debug.print("\n  {s}:{d}  {s}: ", .{ f.path, f.line, f.name });
        if (f.baselined) |b| {
            if (b > f.limit) {
                std.debug.print("{t} {d}, above its baseline {d}", .{ f.metric, f.value, b });
            } else std.debug.print("{t} {d}, over the critical limit {d}, which its baseline ({d}) was not", .{ f.metric, f.value, f.limit, b });
        } else std.debug.print("{t} {d}, over the critical limit {d}; not in the baseline", .{ f.metric, f.value, f.limit });
    }
    std.debug.print("\ngnarl --explain {s}:{d} says why the first scores what it does\n", .{ first.path, first.line });
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
    run: Run,
    help,
    version,
    /// `gnarl skill`, and the directory to install it under, if any.
    skill: ?[]const u8,
    /// Why the command line cannot be run; empty when the usage alone says.
    usage_error: []const u8,
};

const Run = struct {
    paths: []const []const u8 = &.{},
    /// Cleaned, as `walk.collect` cleans the paths it lists.
    excludes: []const []const u8 = &.{},
    format: report.Format = .text,
    /// The configuration file named, if one is.
    config: ?[]const u8 = null,
    check: bool = false,
    /// The functions to explain, as given; none for a report.
    explain: []const []const u8 = &.{},
    all: bool = false,
    top: ?usize = null,
    /// Read what git ignores too.
    no_ignore: bool = false,
    /// The functions the report is to list, as given; none for all.
    functions: []const []const u8 = &.{},
    /// The baseline file named, if one is.
    baseline: ?[]const u8 = null,
    update_baseline: bool = false,
    /// The commit to diff the work tree against, if one is given.
    diff: ?[]const u8 = null,
    /// List files and their imports rather than functions.
    files: bool = false,

    /// Whether an option only the report takes is given.
    fn reportOnly(r: Run) bool {
        return r.check or r.all or r.top != null or r.functions.len > 0;
    }

    fn baselineFlags(r: Run) bool {
        return r.baseline != null or r.update_baseline;
    }

    /// Why the options given cannot go together, if they cannot.
    fn conflict(r: Run) ?[]const u8 {
        if (r.explain.len > 0 and (r.reportOnly() or r.baselineFlags())) {
            return "--check, --all, --top, --function, --baseline and --update-baseline are for the report, not --explain";
        }
        if (r.check and r.update_baseline) return "--update-baseline writes the baseline and --check holds to it: one at a time";
        if (r.diff != null and (r.reportOnly() or r.baselineFlags() or r.explain.len > 0)) {
            return "--diff takes paths, --exclude, --config and --format; not --check, --explain, the baseline flags, --all, --top or --function";
        }
        if (r.files and r.notForFiles()) {
            return "--files takes paths, --exclude, --no-ignore, --config, --format and --top; not --check, --explain, --diff, the baseline flags, --all or --function";
        }
        if (r.baseline != null and !r.check and !r.update_baseline) return "--baseline is for --check or --update-baseline";
        return null;
    }

    fn notForFiles(r: Run) bool {
        return r.check or r.all or r.functions.len > 0 or r.baselineFlags() or r.explain.len > 0 or r.diff != null;
    }
};

/// The options that stand alone.
const Flag = enum { @"--json", @"--check", @"--all", @"--no-ignore", @"--update-baseline", @"--files" };

/// The options that take a value, as `--top 5` or `--top=5`.
const Option = enum { @"--exclude", @"--top", @"--function", @"--explain", @"--diff", @"--baseline", @"--config", @"--format" };

/// A run as the command line builds it, its lists still growing.
const Parsing = struct {
    run: Run = .{},
    paths: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    explain: std.ArrayList([]const u8) = .empty,
    functions: std.ArrayList([]const u8) = .empty,

    fn flag(p: *Parsing, f: Flag) void {
        switch (f) {
            .@"--json" => p.run.format = .json,
            .@"--check" => p.run.check = true,
            .@"--all" => p.run.all = true,
            .@"--no-ignore" => p.run.no_ignore = true,
            .@"--update-baseline" => p.run.update_baseline = true,
            .@"--files" => p.run.files = true,
        }
    }

    /// Takes `option`'s `value`; returns why it will not do, if it will
    /// not.
    fn option(p: *Parsing, arena: std.mem.Allocator, o: Option, value: []const u8) std.mem.Allocator.Error!?[]const u8 {
        if (value.len == 0) if (needs(o)) |message| return message;
        switch (o) {
            .@"--exclude" => try p.excludes.append(arena, try std.fs.path.resolveAlloc(arena, &.{value})),
            .@"--top" => {
                p.run.top = std.fmt.parseInt(usize, value, 10) catch 0;
                if (p.run.top == 0) return try arena.print("--top takes how many functions to list, 1 or more, not '{s}'", .{value});
            },
            .@"--function" => try p.functions.append(arena, value),
            .@"--explain" => try p.explain.append(arena, value),
            .@"--diff" => p.run.diff = value,
            .@"--baseline" => p.run.baseline = value,
            .@"--config" => p.run.config = value,
            .@"--format" => p.run.format = std.meta.stringToEnum(report.Format, value) orelse
                return try arena.print("--format takes text, md, json, xml, csv or tsv, not '{s}'", .{value}),
        }
        return null;
    }

    fn done(p: Parsing) Run {
        var run = p.run;
        run.paths = p.paths.items;
        run.excludes = p.excludes.items;
        run.explain = p.explain.items;
        run.functions = p.functions.items;
        return run;
    }
};

/// What to say when `o` is given no value; null for the options whose
/// own message says what they take.
fn needs(o: Option) ?[]const u8 {
    return switch (o) {
        .@"--exclude" => "--exclude needs a path",
        .@"--function" => "--function needs a function: path:line, or a name",
        .@"--explain" => "--explain needs a function: path:line, or a name",
        .@"--diff" => "--diff needs a commit: HEAD, main, a hash",
        .@"--baseline" => "--baseline needs a file",
        .@"--config" => "--config needs a file",
        .@"--top", .@"--format" => null,
    };
}

/// `-h` and `--help`, `--version`, and an unknown option take effect where
/// they stand; anything after them is not read.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Command {
    // A path named skill is ./skill.
    if (args.len > 0 and std.mem.eql(u8, args[0], "skill")) return parseSkill(args[1..]);
    var p: Parsing = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.meta.stringToEnum(Flag, arg)) |f| {
            p.flag(f);
        } else if (optionAt(args, &i)) |given| {
            if (try p.option(arena, given[0], given[1])) |message| return .{ .usage_error = message };
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage_error = try arena.print("unknown option '{s}'", .{arg}) };
        } else try p.paths.append(arena, arg);
    }
    const run = p.done();
    if (run.conflict()) |message| return .{ .usage_error = message };
    return .{ .run = run };
}

/// `gnarl skill`, given what follows `skill`.
fn parseSkill(args: []const []const u8) Command {
    if (args.len == 0) return .{ .skill = null };
    var i: usize = 0;
    if (optionValue(args, &i, "--install")) |dir| {
        if (dir.len == 0) return .{ .usage_error = "--install needs a directory" };
        if (i + 1 == args.len) return .{ .skill = dir };
    }
    return .{ .usage_error = "gnarl skill takes --install <dir>, or nothing" };
}

/// The option `args[i.*]` is, and its value, moving `i` past a value given
/// on its own.
fn optionAt(args: []const []const u8, i: *usize) ?struct { Option, []const u8 } {
    inline for (comptime std.enums.values(Option)) |o| {
        if (optionValue(args, i, @tagName(o))) |value| return .{ o, value };
    }
    return null;
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

const thresholds_line = "Thresholds for normal code (warning, critical): cyclomatic 10, 15; cognitive 15, 25; lines 50, 100; nesting 4; params 4.\n";

test "a row per function, worst first, from every file read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const S = struct {\n    fn m(c: bool) void {\n        if (c) {}\n    }\n};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn f() void {}\ntest \"f\" {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.zig", .data = "const x = 1;\n" });

    try expectRun(tmp.dir, &.{ "--all", "." }, 0,
        \\cyclomatic  cognitive  lines  nesting  params  weighted  location  function
        \\       2          1      2        1       1         1    b.zig:2   S.m
        \\       1          0      1        0       0         0    a.zig:1   f
        \\       1          0      1        0       0         0    a.zig:2   test "f"
        \\
        \\3 functions in 3 files: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\
    ++ thresholds_line ++
        \\Thresholds for test code (warning, critical): cyclomatic -, 20; cognitive -, 35.
        \\
    , "");
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
        \\cyclomatic  cognitive  lines  nesting  params  weighted  location  function
        \\       1          0      1        0       0         0    a.zig:1   a
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

/// A function of `ifs` ifs, cyclomatic ifs + 1, named `name`.
fn branchy(arena: std.mem.Allocator, name: []const u8, ifs: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "fn {s}(c: bool) void {{\n", .{name});
    for (0..ifs) |_| try out.appendSlice(arena, "    if (c) {}\n");
    try out.appendSlice(arena, "}\n");
    return out.items;
}

test "--update-baseline, then --check holds to it: new or worse fails, debt kept passes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Step = struct { source: []const u8, exit: u8, stderr: []const u8 };
    const held_at = try branchy(arena, "f", 16);
    const steps = [_]Step{
        // No baseline yet: any critical crossing fails.
        .{ .source = held_at, .exit = 1, .stderr = "gnarl: --check: 1 function over a critical threshold; gnarl --explain a.zig:1 says why the worst scores what it does\n" },
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = steps[0].source });
    for (steps) |step| {
        const result = try runGnarl(tmp.dir, &.{ "--check", "a.zig" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqualStrings(step.stderr, result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = step.exit }, result.term);
    }

    // Written: the one function over, with its numbers.
    {
        const result = try runGnarl(tmp.dir, &.{ "--update-baseline", "a.zig" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("gnarl: complexity.baseline: note: wrote 1 function over a critical threshold\n", result.stderr);
        const written = try tmp.dir.readFileAlloc(io, "complexity.baseline", arena, .limited(1 << 20));
        try std.testing.expect(std.mem.endsWith(u8, written, "\na.zig\tf\t17\t16\t17\t1\t1\t1\n"));
    }

    const held = [_]Step{
        // Held at its baseline: passes.
        .{ .source = held_at, .exit = 0, .stderr = "" },
        // Worse than its baseline: fails, saying by how much. Its lines
        // rise too, but within their limit, which is allowed.
        .{ .source = try branchy(arena, "f", 18), .exit = 1, .stderr =
        \\gnarl: --check: 1 function fails against complexity.baseline:
        \\  a.zig:1  f: cyclomatic 19, above its baseline 17
        \\gnarl --explain a.zig:1 says why the first scores what it does
        \\
        },
        // A new function over: fails; f is held still.
        .{ .source = try std.mem.concat(arena, u8, &.{ held_at, try branchy(arena, "g", 15) }), .exit = 1, .stderr =
        \\gnarl: --check: 1 function fails against complexity.baseline:
        \\  a.zig:19  g: cyclomatic 16, over the critical limit 15; not in the baseline
        \\gnarl --explain a.zig:19 says why the first scores what it does
        \\
        },
        // Better than its baseline, still over: passes, and says to tighten.
        .{ .source = try branchy(arena, "f", 15), .exit = 0, .stderr = "gnarl: complexity.baseline: note: 1 baselined function is under the baseline's numbers now; gnarl --update-baseline tightens it\n" },
        // Within every limit now: passes, and says the entry can go.
        .{ .source = try branchy(arena, "f", 10), .exit = 0, .stderr = "gnarl: complexity.baseline: note: 1 baselined function is within its limits now; gnarl --update-baseline drops it\n" },
        // Renamed: a new function over, and the old one gone.
        .{ .source = try branchy(arena, "h", 16), .exit = 1, .stderr =
        \\gnarl: complexity.baseline: note: 1 baselined function is gone (renamed, moved or deleted); gnarl --update-baseline drops it
        \\gnarl: --check: 1 function fails against complexity.baseline:
        \\  a.zig:1  h: cyclomatic 17, over the critical limit 15; not in the baseline
        \\gnarl --explain a.zig:1 says why the first scores what it does
        \\
        },
    };
    for (held) |step| {
        try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = step.source });
        const result = try runGnarl(tmp.dir, &.{ "--check", "a.zig" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqualStrings(step.stderr, result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = step.exit }, result.term);
    }
}

test "a baseline that cannot be used stops the run, and says where" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn a() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "complexity.baseline", .data = "# fine\na.zig\ta\t1\t1\n" });
    try expectRun(tmp.dir, &.{ "--check", "a.zig" }, 2, "", "gnarl: complexity.baseline:2: fewer than 8 fields: path, name and the six metrics, tab-separated\n");
    try expectRun(tmp.dir, &.{ "--check", "--baseline", "nope", "a.zig" }, 2, "", "gnarl: nope: FileNotFound\n");
    // Not written over a run that could not read every file.
    try expectRun(tmp.dir, &.{ "--update-baseline", "--baseline=b.txt", "a.zig", "missing.zig" }, 2,
        \\1 function in 1 file: 0 over a critical threshold (!!), 0 more over a warning one (!).
        \\1 within limits is not listed; --all lists every function.
        \\
    ++ thresholds_line, "gnarl: missing.zig: FileNotFound\ngnarl: b.txt: not written: a file that could not be read would be left out of it\n");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "b.txt", .{}));
}

test "--diff: the functions a change touched, before and after, worse first" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git_there = std.process.run(arena, io, .{ .argv = &.{ "git", "--version" } }) catch return error.SkipZigTest;
    if (git_there.term != .exited or git_there.term.exited != 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj");
    var proj = try tmp.dir.openDir(io, "proj", .{});
    defer proj.close(io);
    try proj.writeFile(io, .{ .sub_path = "a.zig", .data = "fn grows(c: bool) void {\n    if (c) {}\n}\nfn tidied() void {}\nfn dropped() void {}\nfn kept() void {}\n" });
    try proj.writeFile(io, .{ .sub_path = "b.zig", .data = "fn gone() void {}\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "add", "." },
        &.{ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "start" },
    }) |argv| {
        const r = try std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .dir = proj } });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    }
    // grows gets worse, tidied gets a comment, dropped goes, fresh comes;
    // kept only moves down; b.zig is deleted; c.zig is new and untracked.
    try proj.writeFile(io, .{ .sub_path = "a.zig", .data = "fn grows(c: bool) void {\n    if (c) {}\n    if (c) {}\n}\nfn tidied() void {\n    // why\n}\n\nfn kept() void {}\nfn fresh() void {}\n" });
    try proj.deleteFile(io, "b.zig");
    try proj.writeFile(io, .{ .sub_path = "c.zig", .data = "fn made() void {}\n" });

    try expectRun(proj, &.{ "--diff", "HEAD" }, 0,
        \\change   cyclomatic  cognitive  lines   nesting  params  weighted  location  function
        \\worse    2 -> 3      1 -> 2     2 -> 3  1        1       1         a.zig:1   grows
        \\added    1           0          1       0        0       0         a.zig:10  fresh
        \\added    1           0          1       0        0       0         c.zig:1   made
        \\same     1           0          1       0        0       0         a.zig:5   tidied
        \\removed  1           0          1       0        0       0         a.zig:5   dropped
        \\removed  1           0          1       0        0       0         b.zig:1   gone
        \\
        \\6 functions touched in 3 files since HEAD: 1 worse, 0 mixed, 2 added, 1 the same, 0 better, 2 removed.
        \\gnarl --explain a.zig:1 says why grows, the worst of those that got worse, scores what it does now.
        \\None of them is over a critical limit now.
        \\
    ++ thresholds_line, "");
    try expectRun(proj, &.{ "--diff", "nope" }, 2, "No function touched since nope.\n", "gnarl: nope: not a commit git knows here\n");
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
        \\cyclomatic  cognitive  lines  nesting  params  weighted  location  function
        \\      13!        12     13        1       1         1    a.zig:1   f
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
        \\cyclomatic  cognitive  lines  nesting  params  weighted  location  function
        \\       1          0      1        0       0         0    a.zig:15  g
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
    // A test block is held as a test, not as hot code: thirteen ifs are
    // within its limits.
    try tmp.dir.writeFile(io, .{ .sub_path = "hot.zig", .data = "test \"t\" {\n" ++ thirteen["fn f(c: bool) void {\n".len..] });
    {
        const result = try runGnarl(tmp.dir, &.{ "--check", "--json", "hot.zig" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"within_limits\":1") != null);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "hot.zig", .data = thirteen });
    // Excluded, hot.zig is not read under `.`, and is when named.
    try tmp.dir.writeFile(io, .{ .sub_path = "complexity.zon", .data = ".{ .hot = .{\"hot.zig\"}, .exclude = .{\"hot.zig\"} }\n" });
    {
        const result = try runGnarl(tmp.dir, &.{ "--check", "." });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "1 function in 1 file") != null);
    }
    {
        const result = try runGnarl(tmp.dir, &.{ "--check", "hot.zig" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
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
        \\cognitive 1: the sum of these
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
        \\gnarl: typo.zon:1:5: note: supported: 'hot', 'cold', 'exclude', 'thresholds'
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
    try std.testing.expectEqualStrings("supported: 'hot', 'cold', 'exclude', 'thresholds'", doc.value.notes[0].text);
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
    try std.testing.expect(doc.value.check.asked and !doc.value.check.failed);
    try std.testing.expectEqual(0, doc.value.check.failures.len);
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
        \\cyclomatic  cognitive  lines  nesting  params  weighted  location  function
        \\       1          0      1        0       0         0    b.zig:1   b
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
    try std.testing.expectEqualStrings("--check, --all, --top, --function, --baseline and --update-baseline are for the report, not --explain", (try parseArgs(arena, &.{ "--all", "--explain", "f" })).usage_error);
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

test "parseArgs: --baseline and --update-baseline" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const run = (try parseArgs(arena, &.{ "--check", "--baseline", "ci.baseline" })).run;
    try std.testing.expectEqualStrings("ci.baseline", run.baseline.?);
    try std.testing.expect((try parseArgs(arena, &.{"--update-baseline"})).run.update_baseline);
    try std.testing.expectEqualStrings("--update-baseline writes the baseline and --check holds to it: one at a time", (try parseArgs(arena, &.{ "--check", "--update-baseline" })).usage_error);
    try std.testing.expectEqualStrings("--baseline is for --check or --update-baseline", (try parseArgs(arena, &.{ "--baseline", "b" })).usage_error);
    try std.testing.expectEqualStrings("--baseline needs a file", (try parseArgs(arena, &.{ "--check", "--baseline" })).usage_error);
}

test "parseArgs: --diff" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("main", (try parseArgs(arena, &.{ "--diff", "main", "src" })).run.diff.?);
    try std.testing.expectEqualStrings("--diff needs a commit: HEAD, main, a hash", (try parseArgs(arena, &.{"--diff"})).usage_error);
    try std.testing.expectEqualStrings("--diff takes paths, --exclude, --config and --format; not --check, --explain, the baseline flags, --all, --top or --function", (try parseArgs(arena, &.{ "--diff", "HEAD", "--check" })).usage_error);
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
    try std.testing.expectEqualStrings("--check, --all, --top, --function, --baseline and --update-baseline are for the report, not --explain", (try parseArgs(arena, &.{ "--check", "--explain", "f" })).usage_error);
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
    _ = @import("baseline.zig");
    _ = @import("children.zig");
    _ = @import("cognitive.zig");
    _ = @import("comptime_tally.zig");
    _ = @import("config.zig");
    _ = @import("diff.zig");
    _ = @import("docs.zig");
    _ = @import("explain.zig");
    _ = @import("fan.zig");
    _ = @import("flow.zig");
    _ = @import("suggest.zig");
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
    _ = @import("regions.zig");
    _ = @import("report.zig");
    _ = @import("select.zig");
    _ = @import("skill.zig");
    _ = @import("thresholds.zig");
    _ = @import("walk.zig");
}

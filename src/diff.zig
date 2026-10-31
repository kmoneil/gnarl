//! --diff REF: the functions a change touched, each with its numbers
//! before and after.
//!
//! The change is from the commit REF to the work tree, uncommitted edits
//! included; an untracked file git does not ignore counts as added. A
//! function is known by its path and qualified name, as the baseline
//! knows it, and it is touched when its own source differs: the text of
//! any function declared inside it is not its own. So a function that
//! only moved is not touched, and an edit to a nested function does not
//! touch the one around it.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;

const baseline = @import("baseline.zig");
const children = @import("children.zig");
const formats = @import("formats.zig");
const functions = @import("functions.zig");
const measure = @import("measure.zig");
const messages = @import("messages.zig");
const report = @import("report.zig");
const thresholds = @import("thresholds.zig");
const walk = @import("walk.zig");
const Class = thresholds.Class;
const Classes = thresholds.Classes;
const Metric = thresholds.Metric;
const Thresholds = thresholds.Thresholds;
const Trip = thresholds.Trip;

const metrics = std.enums.values(Metric);

/// What a change did to a function, in the order a diff lists them.
pub const Change = enum {
    /// A number went up and none down.
    worse,
    /// Some numbers went up and some down: often a refactor that moved
    /// the cost, as an extraction that made a function far simpler at the
    /// price of a parameter.
    mixed,
    added,
    /// Its text changed, its numbers did not.
    same,
    /// A number went down and none up.
    better,
    removed,
};

pub const Values = struct {
    cyclomatic: u32,
    cognitive: u32,
    lines: u32,
    nesting: u32,
    params: u32,
    params_weighted: u32,

    fn of(row: report.Row) Values {
        var v: Values = undefined;
        inline for (metrics) |m| @field(v, @tagName(m)) = @field(row, @tagName(m));
        return v;
    }

    fn get(v: Values, metric: Metric) u32 {
        return switch (metric) {
            inline else => |m| @field(v, @tagName(m)),
        };
    }
};

pub const Touched = struct {
    path: []const u8,
    /// Where it is now; for a removed function, where it was.
    line: u32,
    name: []const u8,
    kind: functions.Kind,
    class: Class,
    change: Change,
    /// Null for an added function.
    before: ?Values,
    /// Null for a removed function.
    after: ?Values,
    /// The limits its numbers after the change are over.
    trips: []const Trip,
};

pub const File = struct {
    /// As gnarl prints it.
    path: []const u8,
    /// As git names it, with `/`, relative to the current directory.
    git_path: []const u8,
    status: enum { added, modified, removed },
};

const Git = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

/// Runs git in the current directory. Null when there is no git to run.
fn git(arena: Allocator, io: Io, argv: []const []const u8) Allocator.Error!?Git {
    const r = std.process.run(arena, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// The .zig files the change from `ref` to the work tree touches under
/// `paths`, sorted, as walk would list them (no hidden or build-output
/// paths, nothing `excludes` leaves out). Null when git cannot say; why is
/// said in `said`.
pub fn changedFiles(arena: Allocator, io: Io, ref: []const u8, paths: []const []const u8, excludes: walk.Excludes, said: *messages.Messages) Allocator.Error!?[]const File {
    const inside = try git(arena, io, &.{ "git", "rev-parse", "--is-inside-work-tree" }) orelse {
        try said.fail("--diff", "git is not there to ask what changed", .{});
        return null;
    };
    if (!inside.ok) {
        try said.fail("--diff", "the current directory is not in a git work tree", .{});
        return null;
    }
    const commit = (try git(arena, io, &.{ "git", "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref}) })).?;
    if (!commit.ok) {
        try said.fail(ref, "not a commit git knows here", .{});
        return null;
    }

    var files: std.ArrayList(File) = .empty;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "diff", "--name-status", "--no-renames", "--relative", "-z", ref, "--" });
    try argv.appendSlice(arena, paths);
    const changed = (try git(arena, io, argv.items)).?;
    if (!changed.ok) {
        try said.fail("--diff", "git diff: {s}", .{std.mem.trim(u8, changed.stderr, " \n")});
        return null;
    }
    var it = std.mem.splitScalar(u8, changed.stdout, 0);
    while (it.next()) |status| {
        if (status.len == 0) continue;
        const path = it.next() orelse break;
        try keep(arena, &files, path, excludes.paths, switch (status[0]) {
            'A' => .added,
            'D' => .removed,
            else => .modified,
        });
    }

    argv.clearRetainingCapacity();
    try argv.appendSlice(arena, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z", "--" });
    try argv.appendSlice(arena, paths);
    const untracked = (try git(arena, io, argv.items)).?;
    if (untracked.ok) {
        var new = std.mem.splitScalar(u8, untracked.stdout, 0);
        while (new.next()) |path| if (path.len > 0) try keep(arena, &files, path, excludes.paths, .added);
    }
    try dropGlobbed(arena, &files, paths, excludes.globs);
    std.mem.sort(File, files.items, {}, byPath);
    return files.items;
}

/// Leaves out of `files` what one of `globs` covers below the path among
/// `paths` each was found under, as `walk.collect` does.
fn dropGlobbed(arena: Allocator, files: *std.ArrayList(File), paths: []const []const u8, globs: []const []const u8) Allocator.Error!void {
    if (globs.len == 0) return;
    const roots = try arena.alloc([]const u8, paths.len);
    for (paths, roots) |path, *root| root.* = try std.fs.path.resolveAlloc(arena, &.{path});
    var kept: usize = 0;
    for (files.items) |file| {
        if (walk.globbed(walk.rootOf(roots, file.path) orelse ".", file.path, globs)) continue;
        files.items[kept] = file;
        kept += 1;
    }
    files.shrinkRetainingCapacity(kept);
}

test "dropGlobbed: what a glob covers below the path named, not the path named" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Cleaned, as changedFiles cleans what git lists: `\` on Windows.
    const all = [_]File{
        .{ .path = try std.fs.path.resolveAlloc(arena, &.{"src/a.zig"}), .git_path = "src/a.zig", .status = .modified },
        .{ .path = try std.fs.path.resolveAlloc(arena, &.{"test/golden/f.zig"}), .git_path = "test/golden/f.zig", .status = .modified },
    };
    var files: std.ArrayList(File) = .empty;
    try files.appendSlice(arena, &all);
    try dropGlobbed(arena, &files, &.{"."}, &.{"test/golden"});
    try std.testing.expectEqual(1, files.items.len);
    try std.testing.expectEqualStrings("src/a.zig", files.items[0].git_path);

    files.clearRetainingCapacity();
    try files.appendSlice(arena, &all);
    try dropGlobbed(arena, &files, &.{ ".", "test/golden" }, &.{"test/golden"});
    try std.testing.expectEqual(2, files.items.len);
}

fn keep(arena: Allocator, files: *std.ArrayList(File), git_path: []const u8, excludes: []const []const u8, status: @FieldType(File, "status")) Allocator.Error!void {
    if (!std.mem.endsWith(u8, git_path, ".zig") or walk.skipped(git_path)) return;
    const path = try std.fs.path.resolveAlloc(arena, &.{git_path});
    if (walk.excluded(path, excludes)) return;
    try files.append(arena, .{ .path = path, .git_path = git_path, .status = status });
}

fn byPath(_: void, a: File, b: File) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// The file at `ref`, as git has it, ready to parse.
pub fn oldSource(arena: Allocator, io: Io, ref: []const u8, file: File) Allocator.Error!?[:0]const u8 {
    const shown = try git(arena, io, &.{ "git", "show", try std.fmt.allocPrint(arena, "{s}:./{s}", .{ ref, file.git_path }) }) orelse return null;
    if (!shown.ok) return null;
    return try arena.dupeSentinel(u8, shown.stdout, 0);
}

/// One side of a file: its functions' rows, keys and own text.
const Side = struct {
    rows: []const report.Row = &.{},
    keys: []const []const u8 = &.{},
    texts: []const []const u8 = &.{},
};

fn side(arena: Allocator, scratch: Allocator, path: []const u8, tree: *const Ast) Allocator.Error!Side {
    var rows: std.ArrayList(report.Row) = .empty;
    try measure.file(arena, scratch, path, tree, &rows);
    // Only the rows outlive the file; the keys and texts are compared and
    // dropped.
    const listed = try functions.list(scratch, tree);
    const texts = try scratch.alloc([]const u8, listed.len);
    for (listed, texts) |function, *text| text.* = try ownText(scratch, scratch, tree, function.node);
    return .{ .rows = rows.items, .keys = try baseline.keys(scratch, rows.items), .texts = texts };
}

/// The source of `function` without the functions declared inside it.
fn ownText(arena: Allocator, scratch: Allocator, tree: *const Ast, function: Ast.Node.Index) Allocator.Error![]const u8 {
    var cuts: std.ArrayList([2]u32) = .empty;
    var stack: std.ArrayList(Ast.Node.Index) = .empty;
    try children.append(scratch, tree, function, &stack);
    while (stack.pop()) |node| switch (tree.nodeTag(node)) {
        .fn_decl, .test_decl => {
            const last = tree.lastToken(node);
            try cuts.append(scratch, .{ tree.tokenStart(tree.firstToken(node)), tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)) });
        },
        else => try children.append(scratch, tree, node, &stack),
    };
    std.mem.sort([2]u32, cuts.items, {}, cutBefore);
    const last = tree.lastToken(function);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    var pos: usize = tree.tokenStart(tree.firstToken(function));
    var out: std.ArrayList(u8) = .empty;
    for (cuts.items) |cut| {
        try out.appendSlice(arena, tree.source[pos..cut[0]]);
        pos = cut[1];
    }
    try out.appendSlice(arena, tree.source[pos..end]);
    return out.items;
}

fn cutBefore(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0];
}

/// Appends to `out` what the change did to the functions of one file:
/// `before` is the file at the commit, `after` in the work tree, either
/// null when the file is not there.
pub fn compareFile(
    arena: Allocator,
    scratch: Allocator,
    path: []const u8,
    before: ?*const Ast,
    after: ?*const Ast,
    /// The file's; each function is held to its own, as
    /// `Class.forFunction` gives it.
    file_class: Class,
    classes: thresholds.Classes,
    out: *std.ArrayList(Touched),
) Allocator.Error!void {
    const old: Side = if (before) |t| try side(arena, scratch, path, t) else .{};
    const new: Side = if (after) |t| try side(arena, scratch, path, t) else .{};
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (old.keys, 0..) |key, i| try index.put(scratch, key, i);
    const matched = try scratch.alloc(bool, old.rows.len);
    @memset(matched, false);

    for (new.rows, new.keys, new.texts) |row, key, text| {
        const now = Values.of(row);
        var change: Change = .added;
        var was: ?Values = null;
        if (index.get(key)) |i| {
            matched[i] = true;
            if (std.mem.eql(u8, text, old.texts[i])) continue;
            was = Values.of(old.rows[i]);
            change = compare(was.?, now);
        }
        const class: Class = .forFunction(file_class, row.kind == .@"test");
        var trips: std.ArrayList(Trip) = .empty;
        for (metrics) |m| if (classes.get(class).over(m, now.get(m))) |trip| try trips.append(arena, trip);
        try out.append(arena, .{ .path = path, .line = row.line, .name = row.name, .kind = row.kind, .class = class, .change = change, .before = was, .after = now, .trips = trips.items });
    }
    for (old.rows, matched) |row, m| if (!m) {
        try out.append(arena, .{ .path = path, .line = row.line, .name = row.name, .kind = row.kind, .class = .forFunction(file_class, row.kind == .@"test"), .change = .removed, .before = Values.of(row), .after = null, .trips = &.{} });
    };
}

/// What makes one touched function worse than another: its critical and
/// warning trips after, then how much each metric rose.
fn severity(t: Touched) [2 + metrics.len]i64 {
    var out: [2 + metrics.len]i64 = @splat(0);
    for (t.trips) |trip| out[if (trip.level == .critical) 0 else 1] += 1;
    for (metrics, 0..) |m, i| {
        const now: i64 = if (t.after) |v| v.get(m) else 0;
        const was: i64 = if (t.before) |v| v.get(m) else 0;
        out[2 + i] = now - was;
    }
    return out;
}

fn compare(was: Values, now: Values) Change {
    var up = false;
    var down = false;
    for (metrics) |m| {
        if (now.get(m) > was.get(m)) up = true;
        if (now.get(m) < was.get(m)) down = true;
    }
    if (up and down) return .mixed;
    return if (up) .worse else if (down) .better else .same;
}

/// Worse first, then mixed, added, the same, better and removed. Within
/// worse, mixed and added, the worst first: the most critical limits passed, then the
/// most warnings, then the most each number rose (from nothing, for an
/// added function), cyclomatic first. Then by place.
pub fn sort(touched: []Touched) void {
    std.mem.sort(Touched, touched, {}, listedBefore);
}

fn listedBefore(_: void, a: Touched, b: Touched) bool {
    if (a.change != b.change) return @backingInt(a.change) < @backingInt(b.change);
    if (a.change == .worse or a.change == .mixed or a.change == .added) {
        for (severity(a), severity(b)) |x, y| {
            if (x != y) return x > y;
        }
    }
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => a.line < b.line,
    };
}

/// What to do next, after a diff's counts: the --explain for the worst of
/// those that got worse, or with none, of the mixed; or that nothing got
/// worse. `touched` is sorted, so the first is that worst.
/// How many of `touched`, as they are now, are over a critical limit.
pub fn countCritical(touched: []const Touched) usize {
    var n: usize = 0;
    for (touched) |t| {
        for (t.trips) |trip| if (trip.level == .critical) {
            n += 1;
            break;
        };
    }
    return n;
}

/// Whether the change leaves any function it touched over a critical
/// limit, so the loop's last step needs no --check of its own.
fn writeCritical(w: *Writer, n: usize) Writer.Error!void {
    if (n == 0) return w.writeAll("None of them is over a critical limit now.");
    try w.print("{d} of them {s} over a critical limit now.", .{ n, if (n == 1) "is" else "are" });
}

fn writeNext(w: *Writer, touched: []const Touched, n: Counts) Writer.Error!void {
    const first = touched[0];
    if (n.worse > 0) {
        try w.print("gnarl --explain {s}:{d} says why {s}, the worst of those that got worse, scores what it does now.", .{ first.path, first.line, first.name });
    } else if (n.mixed > 0) {
        try w.print("Nothing got only worse; of the mixed, some numbers up and some down, gnarl --explain {s}:{d} says why {s}, the worst, scores what it does now.", .{ first.path, first.line, first.name });
    } else try w.writeAll("Nothing got worse.");
}

pub const Counts = struct { worse: usize = 0, mixed: usize = 0, added: usize = 0, same: usize = 0, better: usize = 0, removed: usize = 0 };

fn count(touched: []const Touched) Counts {
    var c: Counts = .{};
    for (touched) |t| switch (t.change) {
        inline else => |change| @field(c, @tagName(change)) += 1,
    };
    return c;
}

/// What a diff says besides its functions.
pub const Context = struct {
    version: []const u8,
    ref: []const u8,
    /// How many files the change touched.
    files: usize,
    classes: Classes,
    messages: []const messages.Message = &.{},
};

pub fn write(w: *Writer, format: report.Format, touched: []const Touched, c: Context) Writer.Error!void {
    switch (format) {
        .text => try writeTable(w, touched, c, .text),
        .md => try writeTable(w, touched, c, .md),
        .json => try writeJson(w, touched, c),
        .xml => try writeXml(w, touched, c),
        .csv => try writeDelimited(w, .csv, touched),
        .tsv => try writeDelimited(w, .tsv, touched),
    }
}

const headers = [_][]const u8{ "change", "cyclomatic", "cognitive", "lines", "nesting", "params", "weighted", "location", "function" };
/// Where `location` is in `headers`: after the change and each metric.
const location_column = 1 + metrics.len;
comptime {
    std.debug.assert(std.mem.eql(u8, headers[location_column], "location"));
}

/// A metric's cell: `12 -> 16!!` when it moved, the one number when it
/// did not or the function is added or removed, marked as the report marks
/// it.
fn cell(buffer: []u8, t: Touched, metric: Metric) []const u8 {
    var w: Writer = .fixed(buffer);
    const mark = for (t.trips) |trip| {
        if (trip.metric == metric) break if (trip.level == .critical) "!!" else "!";
    } else "";
    if (t.before) |b| {
        if (t.after) |a| {
            if (b.get(metric) != a.get(metric)) {
                w.print("{d} -> {d}{s}", .{ b.get(metric), a.get(metric), mark }) catch unreachable;
            } else w.print("{d}{s}", .{ a.get(metric), mark }) catch unreachable;
        } else w.print("{d}", .{b.get(metric)}) catch unreachable;
    } else w.print("{d}{s}", .{ t.after.?.get(metric), mark }) catch unreachable;
    return w.buffered();
}

/// Each column's width: its header's, or its widest cell's.
fn widthsOf(touched: []const Touched) [headers.len]usize {
    var cells: [64]u8 = undefined;
    var widths: [headers.len]usize = undefined;
    for (headers, &widths) |h, *width| width.* = h.len;
    for (touched) |t| {
        widths[0] = @max(widths[0], @tagName(t.change).len);
        for (metrics, 1..) |m, i| widths[i] = @max(widths[i], cell(&cells, t, m).len);
        widths[location_column] = @max(widths[location_column], std.fmt.count("{s}:{d}", .{ t.path, t.line }));
    }
    return widths;
}

fn writeRowsText(w: *Writer, touched: []const Touched) Writer.Error!void {
    var cells: [64]u8 = undefined;
    const widths = widthsOf(touched);
    for (headers[0 .. headers.len - 1], widths[0 .. headers.len - 1]) |h, width| {
        try w.writeAll(h);
        try w.splatByteAll(' ', width - h.len + 2);
    }
    try w.writeAll("function\n");
    for (touched) |t| {
        try w.writeAll(@tagName(t.change));
        try w.splatByteAll(' ', widths[0] - @tagName(t.change).len + 2);
        for (metrics, 1..) |m, i| {
            const text = cell(&cells, t, m);
            try w.writeAll(text);
            try w.splatByteAll(' ', widths[i] - text.len + 2);
        }
        try w.print("{s}:{d}", .{ t.path, t.line });
        try w.splatByteAll(' ', widths[location_column] - std.fmt.count("{s}:{d}", .{ t.path, t.line }) + 2);
        try w.print("{s}\n", .{t.name});
    }
}

fn writeRowsMarkdown(w: *Writer, touched: []const Touched) Writer.Error!void {
    var cells: [64]u8 = undefined;
    try w.writeAll("|");
    for (headers) |h| try w.print(" {s} |", .{h});
    try w.writeAll("\n| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |\n");
    for (touched) |t| {
        try w.print("| {t} |", .{t.change});
        for (metrics) |m| try w.print(" {s} |", .{cell(&cells, t, m)});
        try w.print(" `{s}:{d}` | `{s}` |\n", .{ t.path, t.line, t.name });
    }
}

fn writeTable(w: *Writer, touched: []const Touched, c: Context, kind: enum { text, md }) Writer.Error!void {
    if (touched.len > 0) {
        switch (kind) {
            .text => try writeRowsText(w, touched),
            .md => try writeRowsMarkdown(w, touched),
        }
        try w.writeByte('\n');
    }
    // Each line of the summary; in Markdown, each its own paragraph.
    const gap = if (kind == .md) "\n\n" else "\n";
    if (touched.len == 0) return w.print("No function touched since {s}.\n", .{c.ref});
    const n = count(touched);
    try w.print("{d} function{s} touched in {d} file{s} since {s}: {d} worse, {d} mixed, {d} added, {d} the same, {d} better, {d} removed.", .{
        touched.len, plural(touched.len), c.files, plural(c.files), c.ref, n.worse, n.mixed, n.added, n.same, n.better, n.removed,
    });
    try w.writeAll(gap);
    try writeNext(w, touched, n);
    try w.writeAll(gap);
    try writeCritical(w, countCritical(touched));
    for (std.enums.values(Class)) |class| {
        for (touched) |t| {
            if (t.class == class) break;
        } else continue;
        try w.writeAll(gap);
        try report.writeThresholds(w, c.classes, class);
    }
    try w.writeByte('\n');
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn writeJson(w: *Writer, touched: []const Touched, c: Context) Writer.Error!void {
    try w.print("{{\"schema\":{d},\"gnarl\":", .{report.schema});
    try std.json.Stringify.value(c.version, .{}, w);
    try w.writeAll(",\"ref\":");
    try std.json.Stringify.value(c.ref, .{}, w);
    try w.print(",\"files\":{d},\"changes\":", .{c.files});
    try std.json.Stringify.value(count(touched), .{}, w);
    try w.print(",\"critical\":{d}", .{countCritical(touched)});
    try w.writeAll(",\"thresholds\":");
    try std.json.Stringify.value(c.classes, .{}, w);
    try messages.writeJson(w, c.messages);
    try w.writeAll(",\"functions\":[");
    for (touched, 0..) |t, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try std.json.Stringify.value(t, .{}, w);
    }
    try w.writeAll(if (touched.len > 0) "\n]}\n" else "]}\n");
}

fn writeXml(w: *Writer, touched: []const Touched, c: Context) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gnarl");
    try formats.attrInt(w, "schema", report.schema);
    try formats.attr(w, "version", c.version);
    try formats.attr(w, "ref", c.ref);
    try formats.attrInt(w, "files", c.files);
    try formats.attrInt(w, "critical", countCritical(touched));
    try w.writeAll(">\n  <changes");
    const n = count(touched);
    inline for (comptime std.enums.values(Change)) |change| try formats.attrInt(w, @tagName(change), @field(n, @tagName(change)));
    try w.writeAll("/>\n");
    try report.writeThresholdsXml(w, c.classes);
    try messages.writeXml(w, c.messages);
    try w.writeAll("  <functions>\n");
    for (touched) |t| {
        try w.writeAll("    <function");
        try formats.attr(w, "path", t.path);
        try formats.attrInt(w, "line", t.line);
        try formats.attr(w, "name", t.name);
        try formats.attr(w, "kind", @tagName(t.kind));
        try formats.attr(w, "class", @tagName(t.class));
        try formats.attr(w, "change", @tagName(t.change));
        try w.writeAll(">\n");
        inline for (.{ "before", "after" }) |which| {
            if (@field(t, which)) |v| {
                try w.writeAll("      <" ++ which);
                inline for (metrics) |m| try formats.attrInt(w, @tagName(m), @field(v, @tagName(m)));
                try w.writeAll("/>\n");
            }
        }
        for (t.trips) |trip| {
            try w.writeAll("      <trip");
            try formats.attr(w, "metric", @tagName(trip.metric));
            try formats.attr(w, "level", @tagName(trip.level));
            try formats.attrInt(w, "limit", trip.limit);
            try w.writeAll("/>\n");
        }
        try w.writeAll("    </function>\n");
    }
    try w.writeAll("  </functions>\n</gnarl>\n");
}

pub const delimited_columns = [_][]const u8{
    "path",              "line",             "name",             "kind",            "class",                  "change",
    "cyclomatic_before", "cyclomatic_after", "cognitive_before", "cognitive_after", "lines_before",           "lines_after",
    "nesting_before",    "nesting_after",    "params_before",    "params_after",    "params_weighted_before", "params_weighted_after",
    "over",
};

/// A header, then a row per function; a side the function does not have
/// is empty.
fn writeDelimited(w: *Writer, kind: formats.Delimited, touched: []const Touched) Writer.Error!void {
    try formats.header(w, kind, &delimited_columns);
    for (touched) |t| {
        try formats.field(w, kind, true, t.path);
        try formats.fieldInt(w, kind, false, t.line);
        try formats.field(w, kind, false, t.name);
        try formats.field(w, kind, false, @tagName(t.kind));
        try formats.field(w, kind, false, @tagName(t.class));
        try formats.field(w, kind, false, @tagName(t.change));
        for (metrics) |m| {
            inline for (.{ "before", "after" }) |which| {
                if (@field(t, which)) |v| try formats.fieldInt(w, kind, false, v.get(m)) else try formats.field(w, kind, false, "");
            }
        }
        var buffer: [256]u8 = undefined;
        var over: Writer = .fixed(&buffer);
        for (t.trips, 0..) |trip, i| over.print("{s}{t}:{t}:{d}", .{ if (i == 0) "" else " ", trip.metric, trip.level, trip.limit }) catch unreachable;
        try formats.field(w, kind, false, over.buffered());
        try w.writeByte('\n');
    }
}

fn parse(gpa: Allocator, source: [:0]const u8) !Ast {
    const tree = try Ast.parse(gpa, source, .{});
    if (tree.errors.len > 0) return error.ExampleDoesNotParse;
    return tree;
}

test "compareFile: worse, added, the same, better, removed; moved or nested-only is not touched" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var old = try parse(gpa,
        \\fn grows(c: bool) void {
        \\    if (c) {}
        \\}
        \\fn shrinks(c: bool) void {
        \\    if (c) {}
        \\    if (c) {}
        \\}
        \\fn comment() void {}
        \\fn moves() void {}
        \\fn outer() void {
        \\    const S = struct {
        \\        fn inner() void {}
        \\    };
        \\    _ = S;
        \\}
        \\fn dropped() void {}
        \\fn trades(c: bool) void {
        \\    if (c) {}
        \\    if (c) {}
        \\}
    );
    defer old.deinit(gpa);
    var new = try parse(gpa,
        \\fn grows(c: bool) void {
        \\    if (c) {}
        \\    if (c) {}
        \\}
        \\fn shrinks(c: bool) void {
        \\    if (c) {}
        \\}
        \\fn comment() void {
        \\    // now it says why
        \\}
        \\
        \\
        \\fn moves() void {}
        \\fn outer() void {
        \\    const S = struct {
        \\        fn inner(c: bool) void {
        \\            if (c) {}
        \\        }
        \\    };
        \\    _ = S;
        \\}
        \\fn fresh() void {}
        \\fn trades(c: bool, d: bool) void {
        \\    if (c and d) {}
        \\}
    );
    defer new.deinit(gpa);
    var touched: std.ArrayList(Touched) = .empty;
    try compareFile(arena, arena, "a.zig", &old, &new, .normal, Classes.defaults, &touched);
    sort(touched.items);
    var got: std.ArrayList(u8) = .empty;
    for (touched.items) |t| try got.print(arena, "{t} {s} {d}\n", .{ t.change, t.name, t.line });
    // moves only moved; outer only had a nested function change. Of the
    // two worse, inner rose in nesting too, so it is the worse. trades
    // took a parameter for a line: mixed.
    try std.testing.expectEqualStrings(
        \\worse outer.S.inner 16
        \\worse grows 1
        \\mixed trades 23
        \\added fresh 22
        \\same comment 8
        \\better shrinks 5
        \\removed dropped 16
        \\
    , got.items);
}

test "write: the table, and the summary saying when nothing got worse" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before: Values = .{ .cyclomatic = 12, .cognitive = 9, .lines = 40, .nesting = 3, .params = 2, .params_weighted = 2 };
    var after = before;
    after.cyclomatic = 16;
    const touched = [_]Touched{
        .{ .path = "a.zig", .line = 3, .name = "grows", .kind = .@"fn", .class = .normal, .change = .worse, .before = before, .after = after, .trips = &.{.{ .metric = .cyclomatic, .level = .critical, .limit = 15 }} },
        .{ .path = "b.zig", .line = 9, .name = "gone", .kind = .@"fn", .class = .normal, .change = .removed, .before = before, .after = null, .trips = &.{} },
    };
    const context: Context = .{ .version = "0.0.0", .ref = "main", .files = 2, .classes = .defaults };
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, .text, &touched, context);
    try std.testing.expectEqualStrings(
        \\change   cyclomatic  cognitive  lines  nesting  params  weighted  location  function
        \\worse    12 -> 16!!  9          40     3        2       2         a.zig:3   grows
        \\removed  12          9          40     3        2       2         b.zig:9   gone
        \\
        \\2 functions touched in 2 files since main: 1 worse, 0 mixed, 0 added, 0 the same, 0 better, 1 removed.
        \\gnarl --explain a.zig:3 says why grows, the worst of those that got worse, scores what it does now.
        \\1 of them is over a critical limit now.
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; cognitive 15, 25; lines 50, 100; nesting 4; params 4.
        \\
    , out.written());

    var better: Writer.Allocating = .init(arena);
    try write(&better.writer, .text, touched[1..], context);
    try std.testing.expect(std.mem.indexOf(u8, better.written(), "\nNothing got worse.\n") != null);

    // Simpler at the price of a parameter: mixed, and said so.
    var traded = after;
    traded.cyclomatic = 4;
    traded.params = 3;
    const mixed = [_]Touched{.{ .path = "a.zig", .line = 3, .name = "trades", .kind = .@"fn", .class = .normal, .change = .mixed, .before = before, .after = traded, .trips = &.{} }};
    var some: Writer.Allocating = .init(arena);
    try write(&some.writer, .text, &mixed, context);
    try std.testing.expect(std.mem.indexOf(u8, some.written(), "\nmixed   12 -> 4 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, some.written(), ": 0 worse, 1 mixed, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, some.written(), "\nNothing got only worse; of the mixed, some numbers up and some down, gnarl --explain a.zig:3 says why trades, the worst, scores what it does now.\n") != null);

    var none: Writer.Allocating = .init(arena);
    try write(&none.writer, .md, &.{}, context);
    try std.testing.expectEqualStrings("No function touched since main.\n", none.written());

    // The others read back.
    var json: Writer.Allocating = .init(arena);
    try write(&json.writer, .json, &touched, context);
    const Doc = struct { schema: u32, gnarl: []const u8, ref: []const u8, files: usize, changes: Counts, critical: usize, thresholds: Classes, errors: []const std.json.Value, notes: []const std.json.Value, functions: []const Touched };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, json.written(), .{});
    try std.testing.expectEqual(1, doc.changes.worse);
    try std.testing.expectEqual(1, doc.critical);
    try std.testing.expectEqual(16, doc.functions[0].after.?.cyclomatic);
    try std.testing.expectEqual(null, doc.functions[1].after);

    var xml: Writer.Allocating = .init(arena);
    try write(&xml.writer, .xml, &touched, context);
    const root = try formats.readXml(arena, xml.written());
    try std.testing.expectEqualStrings("main", root.get("ref").?);
    try std.testing.expectEqualStrings("16", root.child("functions").?.children[0].child("after").?.get("cyclomatic").?);

    var tsv: Writer.Allocating = .init(arena);
    try write(&tsv.writer, .tsv, &touched, context);
    const table = try formats.readDelimited(arena, .tsv, tsv.written());
    try std.testing.expectEqualStrings("12", table[1][6]);
    try std.testing.expectEqualStrings("16", table[1][7]);
    try std.testing.expectEqualStrings("", table[2][7]);
}

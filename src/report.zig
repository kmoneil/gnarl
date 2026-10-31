//! The report: a row per function, worst first, as a table, as JSON, or as
//! a Markdown table for a review.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const functions = @import("functions.zig");
const thresholds = @import("thresholds.zig");
const Thresholds = thresholds.Thresholds;
const Metric = thresholds.Metric;
const Trip = thresholds.Trip;

pub const Format = enum { text, json, md };

pub const Row = struct {
    path: []const u8,
    line: u32,
    column: u32,
    name: []const u8,
    kind: functions.Kind,
    cyclomatic: u32,
    lines: u32,
    nesting: u32,
    params: u32,
    params_weighted: u32,
    /// The limits it is over, each metric once at its worst. Set by `rank`.
    trips: []const Trip = &.{},
};

/// Sets each row's trips against `limits`, and sorts the rows worst first:
/// the most critical trips, then the most warnings, then by cyclomatic
/// complexity, lines, nesting and parameters, then by path and line.
pub fn rank(arena: Allocator, rows: []Row, limits: Thresholds) Allocator.Error!void {
    for (rows) |*row| {
        var buffer: [std.enums.values(Metric).len]Trip = undefined;
        var n: usize = 0;
        inline for (comptime std.enums.values(Metric)) |metric| {
            if (limits.over(metric, @field(row, @tagName(metric)))) |trip| {
                buffer[n] = trip;
                n += 1;
            }
        }
        row.trips = try arena.dupe(Trip, buffer[0..n]);
    }
    std.mem.sort(Row, rows, {}, worse);
}

fn worse(_: void, a: Row, b: Row) bool {
    for (severity(a), severity(b)) |x, y| {
        if (x != y) return x > y;
    }
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => a.line < b.line,
    };
}

fn severity(row: Row) [6]u32 {
    return .{ tally(row, .critical), tally(row, .warning), row.cyclomatic, row.lines, row.nesting, row.params };
}

fn tally(row: Row, level: thresholds.Level) u32 {
    var n: u32 = 0;
    for (row.trips) |trip| n += @intFromBool(trip.level == level);
    return n;
}

/// The worst level `row` is over for `metric`, if any.
fn levelOf(row: Row, metric: Metric) ?thresholds.Level {
    for (row.trips) |trip| if (trip.metric == metric) return trip.level;
    return null;
}

/// Writes `rows`, ranked, in `format`. `files` is how many files they
/// came from.
pub fn write(w: *Writer, format: Format, rows: []const Row, files: usize, limits: Thresholds) Writer.Error!void {
    switch (format) {
        .text => try writeText(w, rows, files, limits),
        .md => try writeMarkdown(w, rows, files, limits),
        .json => {
            try std.json.Stringify.value(.{ .functions = rows, .files = files, .thresholds = limits }, .{ .whitespace = .indent_2 }, w);
            try w.writeByte('\n');
        },
    }
}

/// The table's number columns, in order; the last has no limits.
const Column = struct { header: []const u8, metric: ?Metric };
const columns = [_]Column{
    .{ .header = "cyclomatic", .metric = .cyclomatic },
    .{ .header = "lines", .metric = .lines },
    .{ .header = "nesting", .metric = .nesting },
    .{ .header = "params", .metric = .params },
    .{ .header = "weighted", .metric = null },
};

fn value(row: Row, column: Column) u32 {
    const metric = column.metric orelse return row.params_weighted;
    return switch (metric) {
        inline else => |m| @field(row, @tagName(m)),
    };
}

/// What follows a number over a limit: `!` a warning, `!!` critical.
fn marker(row: Row, column: Column) []const u8 {
    const metric = column.metric orelse return "";
    const level = levelOf(row, metric) orelse return "";
    return switch (level) {
        .warning => "!",
        .critical => "!!",
    };
}

fn writeText(w: *Writer, rows: []const Row, files: usize, limits: Thresholds) Writer.Error!void {
    // Each number column is wide enough for its header and for its widest
    // number with a two-character marker after it.
    var widths: [columns.len]usize = undefined;
    for (columns, &widths) |column, *width| {
        width.* = column.header.len;
        for (rows) |row| {
            const marked = std.fmt.count("{d}", .{value(row, column)}) + @as(usize, if (column.metric != null) 2 else 0);
            width.* = @max(width.*, marked);
        }
    }
    var location_width: usize = "location".len;
    for (rows) |row| location_width = @max(location_width, std.fmt.count("{s}:{d}", .{ row.path, row.line }));

    for (columns, widths) |column, width| {
        try w.splatByteAll(' ', width - column.header.len);
        try w.print("{s}  ", .{column.header});
    }
    try w.writeAll("location");
    try w.splatByteAll(' ', location_width - "location".len + 2);
    try w.writeAll("function\n");
    for (rows) |row| {
        for (columns, widths) |column, width| {
            const mark = marker(row, column);
            const number = std.fmt.count("{d}", .{value(row, column)});
            const tail: usize = if (column.metric != null) 2 else 0;
            try w.splatByteAll(' ', width - tail - number);
            try w.print("{d}{s}", .{ value(row, column), mark });
            try w.splatByteAll(' ', tail - mark.len + 2);
        }
        try w.print("{s}:{d}", .{ row.path, row.line });
        try w.splatByteAll(' ', locationPad(row, location_width) + 2);
        try w.print("{s}\n", .{row.name});
    }
    try w.writeByte('\n');
    try writeSummary(w, rows, files, limits, "\n");
}

fn locationPad(row: Row, width: usize) usize {
    return width - std.fmt.count("{s}:{d}", .{ row.path, row.line });
}

fn writeMarkdown(w: *Writer, rows: []const Row, files: usize, limits: Thresholds) Writer.Error!void {
    try w.writeAll("|");
    for (columns) |column| try w.print(" {s} |", .{column.header});
    try w.writeAll(" location | function |\n|");
    for (columns) |_| try w.writeAll(" ---: |");
    try w.writeAll(" --- | --- |\n");
    for (rows) |row| {
        try w.writeAll("|");
        for (columns) |column| {
            const mark = marker(row, column);
            try w.print(" {d}{s}{s} |", .{ value(row, column), if (mark.len > 0) " " else "", mark });
        }
        var buffer: [16]u8 = undefined;
        try w.writeByte(' ');
        try writeCode(w, row.path, std.fmt.bufPrint(&buffer, ":{d}", .{row.line}) catch unreachable);
        try w.writeAll(" | ");
        try writeCode(w, row.name, "");
        try w.writeAll(" |\n");
    }
    try w.writeByte('\n');
    try writeSummary(w, rows, files, limits, "\n\n");
}

/// Writes `text` and `suffix` as one Markdown code span that a table cell
/// can hold: fenced with one more backtick than the longest run in it, and
/// each `|` escaped.
fn writeCode(w: *Writer, text: []const u8, suffix: []const u8) Writer.Error!void {
    var longest: usize = 0;
    var run: usize = 0;
    for (text) |c| {
        run = if (c == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    const pad = text.len > 0 and (text[0] == '`' or text[text.len - 1] == '`');
    try w.splatByteAll('`', longest + 1);
    if (pad) try w.writeByte(' ');
    for (text) |c| {
        if (c == '|') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeAll(suffix);
    if (pad) try w.writeByte(' ');
    try w.splatByteAll('`', longest + 1);
}

/// How many functions were measured and how many are over a limit, then
/// the limits; `gap` goes between the two.
fn writeSummary(w: *Writer, rows: []const Row, files: usize, limits: Thresholds, gap: []const u8) Writer.Error!void {
    var critical: usize = 0;
    var warning: usize = 0;
    for (rows) |row| {
        if (tally(row, .critical) > 0) {
            critical += 1;
        } else if (row.trips.len > 0) warning += 1;
    }
    try w.print("{d} function{s} in {d} file{s}: {d} over a critical threshold (!!), {d} more over a warning one (!).{s}", .{
        rows.len, plural(rows.len), files, plural(files), critical, warning, gap,
    });
    try w.writeAll("Thresholds (warning, critical):");
    var first = true;
    inline for (comptime std.enums.values(Metric)) |metric| {
        const limit = @field(limits, @tagName(metric));
        if (limit.warning != null or limit.critical != null) {
            try w.print("{s} {s}", .{ if (first) "" else ";", @tagName(metric) });
            first = false;
            if (limit.warning) |n| try w.print(" {d}", .{n}) else try w.writeAll(" -");
            if (limit.critical) |n| try w.print(", {d}", .{n});
        }
    }
    try w.writeAll(".\n");
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// Rows for the format tests: one critical, one warning, two clean, out of
/// order.
fn sampleRows(arena: Allocator) ![]Row {
    const rows = try arena.dupe(Row, &.{
        .{ .path = "src/a.zig", .line = 9, .column = 4, .name = "small", .kind = .@"fn", .cyclomatic = 1, .lines = 3, .nesting = 0, .params = 0, .params_weighted = 0 },
        .{ .path = "src/b.zig", .line = 120, .column = 8, .name = "Parser.next", .kind = .@"fn", .cyclomatic = 22, .lines = 140, .nesting = 5, .params = 2, .params_weighted = 3 },
        .{ .path = "src/a.zig", .line = 30, .column = 1, .name = "test \"a|b\"", .kind = .@"test", .cyclomatic = 3, .lines = 12, .nesting = 1, .params = 0, .params_weighted = 0 },
        .{ .path = "src/a.zig", .line = 2, .column = 4, .name = "wide", .kind = .@"fn", .cyclomatic = 4, .lines = 20, .nesting = 1, .params = 6, .params_weighted = 8 },
    });
    try rank(arena, rows, .normal);
    return rows;
}

fn expectWritten(format: Format, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, format, try sampleRows(arena), 2, .normal);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "rank: critical first, then warnings, then the numbers, then the place" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try sampleRows(arena_state.allocator());
    const names = [_][]const u8{ "Parser.next", "wide", "test \"a|b\"", "small" };
    for (names, rows) |name, row| try std.testing.expectEqualStrings(name, row.name);
    // Parser.next: cyclomatic and lines critical, nesting a warning.
    try std.testing.expectEqual(3, rows[0].trips.len);
    try std.testing.expectEqual(.critical, levelOf(rows[0], .lines).?);
    try std.testing.expectEqual(.warning, levelOf(rows[0], .nesting).?);
    try std.testing.expectEqual(.warning, levelOf(rows[1], .params).?);
}

test "write: text" {
    try expectWritten(.text,
        \\cyclomatic  lines  nesting  params  weighted  location       function
        \\      22!!  140!!      5!      2           3  src/b.zig:120  Parser.next
        \\       4     20        1       6!          8  src/a.zig:2    wide
        \\       3     12        1       0           0  src/a.zig:30   test "a|b"
        \\       1      3        0       0           0  src/a.zig:9    small
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\Thresholds (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
}

test "write: Markdown" {
    try expectWritten(.md,
        \\| cyclomatic | lines | nesting | params | weighted | location | function |
        \\| ---: | ---: | ---: | ---: | ---: | --- | --- |
        \\| 22 !! | 140 !! | 5 ! | 2 | 3 | `src/b.zig:120` | `Parser.next` |
        \\| 4 | 20 | 1 | 6 ! | 8 | `src/a.zig:2` | `wide` |
        \\| 3 | 12 | 1 | 0 | 0 | `src/a.zig:30` | `test "a\|b"` |
        \\| 1 | 3 | 0 | 0 | 0 | `src/a.zig:9` | `small` |
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\
        \\Thresholds (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
}

test "write: JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, .json, try sampleRows(arena), 2, .normal);

    // Read back, it says what the table says.
    const Doc = struct { functions: []const Row, files: usize, thresholds: Thresholds };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, out.written(), .{});
    try std.testing.expectEqual(4, doc.functions.len);
    try std.testing.expectEqual(2, doc.files);
    try std.testing.expectEqualStrings("Parser.next", doc.functions[0].name);
    try std.testing.expectEqualStrings("test \"a|b\"", doc.functions[2].name);
    try std.testing.expectEqual(.@"test", doc.functions[2].kind);
    try std.testing.expectEqual(3, doc.functions[0].trips.len);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .critical, .limit = 15 }, doc.functions[0].trips[0]);
    try std.testing.expectEqual(null, doc.thresholds.nesting.critical);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"params_weighted\": 3") != null);
}

test "writeCode: a backtick in the text takes a longer fence" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCode(&out.writer, "test \"a `b`\"", "");
    try std.testing.expectEqualStrings("``test \"a `b`\"``", out.written());
}

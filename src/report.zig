//! The report: a row per function, worst first, as a table, as JSON, or as
//! a Markdown table for a review.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const formats = @import("formats.zig");
const functions = @import("functions.zig");
const messages = @import("messages.zig");
const Message = messages.Message;
const thresholds = @import("thresholds.zig");
const Class = thresholds.Class;
const Classes = thresholds.Classes;
const Metric = thresholds.Metric;
const Trip = thresholds.Trip;

pub const Format = enum { text, md, json, xml, csv, tsv };

/// The version of the shape of the json and xml documents. It goes up
/// when a field is renamed, moved or taken away; one added leaves it.
pub const schema = 1;

pub const Row = struct {
    path: []const u8,
    /// Where its name is, as the report prints it.
    line: u32,
    /// Where it ends: the line of its closing brace.
    end_line: u32 = 0,
    column: u32,
    name: []const u8,
    kind: functions.Kind,
    cyclomatic: u32,
    lines: u32,
    nesting: u32,
    params: u32,
    params_weighted: u32,
    /// The class of code its file is in, which picks its thresholds.
    class: Class = .normal,
    /// The limits it is over, each metric once at its worst. Set by `rank`.
    trips: []const Trip = &.{},
};

/// Sets each row's trips against its class's thresholds, and sorts the rows
/// worst first: the most critical trips, then the most warnings, then by
/// cyclomatic complexity, lines, nesting and parameters, then by path and
/// line.
pub fn rank(arena: Allocator, rows: []Row, classes: Classes) Allocator.Error!void {
    for (rows) |*row| {
        const limits = classes.get(row.class);
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

/// How many rows are over a critical threshold.
pub fn countCritical(rows: []const Row) usize {
    var n: usize = 0;
    for (rows) |row| n += @intFromBool(tally(row, .critical) > 0);
    return n;
}

/// Which of the ranked rows a report lists.
pub const Listing = struct {
    /// Every row, not only those over a threshold.
    all: bool = false,
    /// At most this many, the worst.
    top: ?usize = null,
    /// Only the rows flagged, whatever their numbers: a flag per ranked
    /// row. Null when nothing is picked.
    picked: ?[]const bool = null,
};

/// How many rows a report leaves out, by why.
pub const NotListed = struct {
    /// Within every limit, with no --all.
    within_limits: usize = 0,
    /// Past --top.
    past_top: usize = 0,
    /// Not picked by --function.
    not_selected: usize = 0,
};

pub const Listed = struct {
    rows: []const Row,
    not_listed: NotListed = .{},
    top: ?usize = null,
};

/// The rows of `ranked` that `listing` lists, worst first.
pub fn list(arena: Allocator, ranked: []const Row, listing: Listing) Allocator.Error!Listed {
    var rows: std.ArrayList(Row) = .empty;
    var not_listed: NotListed = .{};
    for (ranked, 0..) |row, i| {
        if (listing.picked) |picked| {
            if (!picked[i]) {
                not_listed.not_selected += 1;
                continue;
            }
        } else if (!listing.all and row.trips.len == 0) {
            not_listed.within_limits += 1;
            continue;
        }
        if (listing.top) |n| if (rows.items.len >= n) {
            not_listed.past_top += 1;
            continue;
        };
        try rows.append(arena, row);
    }
    return .{ .rows = rows.items, .not_listed = not_listed, .top = listing.top };
}

pub const Check = struct {
    /// Whether --check was given.
    asked: bool = false,
    /// Whether it fails the run: asked, and a function is over a critical
    /// threshold.
    failed: bool = false,
    /// How many functions are over a critical threshold, asked or not.
    critical: usize = 0,
};

/// What a report says besides its rows.
pub const Context = struct {
    /// gnarl's own version.
    version: []const u8,
    /// How many files the rows came from.
    files: usize,
    /// The thresholds the rows were ranked against.
    classes: Classes,
    check: Check = .{},
    /// Everything said on stderr, for the documents that carry it.
    messages: []const Message = &.{},
};

/// Writes `listed`, of the ranked `rows`, in `format`.
pub fn write(w: *Writer, format: Format, rows: []const Row, listed: Listed, context: Context) Writer.Error!void {
    switch (format) {
        .text => try writeText(w, rows, listed, context.files, context.classes),
        .md => try writeMarkdown(w, rows, listed, context.files, context.classes),
        .json => try writeJson(w, rows, listed, context),
        .xml => try writeXml(w, rows, listed, context),
        .csv => try writeDelimited(w, .csv, listed.rows),
        .tsv => try writeDelimited(w, .tsv, listed.rows),
    }
}

/// One document, compact, the functions last and one to a line, so a
/// reader can stop early or take a line at a time.
fn writeJson(w: *Writer, rows: []const Row, listed: Listed, c: Context) Writer.Error!void {
    try w.print("{{\"schema\":{d},\"gnarl\":", .{schema});
    try std.json.Stringify.value(c.version, .{}, w);
    try w.print(",\"files\":{d},\"measured\":{d},\"not_listed\":", .{ c.files, rows.len });
    try std.json.Stringify.value(listed.not_listed, .{}, w);
    try w.writeAll(",\"check\":");
    try std.json.Stringify.value(c.check, .{}, w);
    try w.writeAll(",\"thresholds\":");
    try std.json.Stringify.value(c.classes, .{}, w);
    try messages.writeJson(w, c.messages);
    try w.writeAll(",\"functions\":[");
    for (listed.rows, 0..) |row, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try std.json.Stringify.value(row, .{}, w);
    }
    try w.writeAll(if (listed.rows.len > 0) "\n]}\n" else "]}\n");
}

/// The json document's fields as elements and attributes.
fn writeXml(w: *Writer, rows: []const Row, listed: Listed, c: Context) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gnarl");
    try formats.attrInt(w, "schema", schema);
    try formats.attr(w, "version", c.version);
    try formats.attrInt(w, "files", c.files);
    try formats.attrInt(w, "measured", rows.len);
    try w.writeAll(">\n  <not_listed");
    try formats.attrInt(w, "within_limits", listed.not_listed.within_limits);
    try formats.attrInt(w, "past_top", listed.not_listed.past_top);
    try formats.attrInt(w, "not_selected", listed.not_listed.not_selected);
    try w.writeAll("/>\n  <check");
    try formats.attrBool(w, "asked", c.check.asked);
    try formats.attrBool(w, "failed", c.check.failed);
    try formats.attrInt(w, "critical", c.check.critical);
    try w.writeAll("/>\n  <thresholds>\n");
    for (std.enums.values(Class)) |class| {
        try w.writeAll("    <class");
        try formats.attr(w, "name", @tagName(class));
        try w.writeAll(">\n");
        const limits = c.classes.get(class);
        for (std.enums.values(Metric)) |metric| {
            const limit = limits.of(metric);
            if (limit.warning == null and limit.critical == null) continue;
            try w.writeAll("      <limit");
            try formats.attr(w, "metric", @tagName(metric));
            if (limit.warning) |n| try formats.attrInt(w, "warning", n);
            if (limit.critical) |n| try formats.attrInt(w, "critical", n);
            try w.writeAll("/>\n");
        }
        try w.writeAll("    </class>\n");
    }
    try w.writeAll("  </thresholds>\n");
    try messages.writeXml(w, c.messages);
    try w.writeAll("  <functions>\n");
    for (listed.rows) |row| {
        try w.writeAll("    <function");
        try formats.attr(w, "path", row.path);
        try formats.attrInt(w, "line", row.line);
        try formats.attrInt(w, "end_line", row.end_line);
        try formats.attrInt(w, "column", row.column);
        try formats.attr(w, "name", row.name);
        try formats.attr(w, "kind", @tagName(row.kind));
        try formats.attr(w, "class", @tagName(row.class));
        inline for (comptime std.enums.values(Metric)) |metric| {
            try formats.attrInt(w, @tagName(metric), @field(row, @tagName(metric)));
        }
        if (row.trips.len == 0) {
            try w.writeAll("/>\n");
            continue;
        }
        try w.writeAll(">\n");
        for (row.trips) |trip| {
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
    "path",       "line",  "end_line", "column", "name",            "kind", "class",
    "cyclomatic", "lines", "nesting",  "params", "params_weighted", "over",
};

/// A header row, then a row per function listed. `over` holds each limit
/// passed as `metric:level:limit`, separated by spaces.
fn writeDelimited(w: *Writer, kind: formats.Delimited, rows: []const Row) Writer.Error!void {
    try formats.header(w, kind, &delimited_columns);
    for (rows) |row| {
        try formats.field(w, kind, true, row.path);
        try formats.fieldInt(w, kind, false, row.line);
        try formats.fieldInt(w, kind, false, row.end_line);
        try formats.fieldInt(w, kind, false, row.column);
        try formats.field(w, kind, false, row.name);
        try formats.field(w, kind, false, @tagName(row.kind));
        try formats.field(w, kind, false, @tagName(row.class));
        inline for (comptime std.enums.values(Metric)) |metric| {
            try formats.fieldInt(w, kind, false, @field(row, @tagName(metric)));
        }
        var buffer: [256]u8 = undefined;
        var over: Writer = .fixed(&buffer);
        for (row.trips, 0..) |trip, i| over.print("{s}{t}:{t}:{d}", .{ if (i == 0) "" else " ", trip.metric, trip.level, trip.limit }) catch unreachable;
        try formats.field(w, kind, false, over.buffered());
        try w.writeByte('\n');
    }
}

/// The table's number columns, in order.
const Column = struct { header: []const u8, metric: Metric };
const columns = [_]Column{
    .{ .header = "cyclomatic", .metric = .cyclomatic },
    .{ .header = "lines", .metric = .lines },
    .{ .header = "nesting", .metric = .nesting },
    .{ .header = "params", .metric = .params },
    .{ .header = "weighted", .metric = .params_weighted },
};

fn value(row: Row, column: Column) u32 {
    return switch (column.metric) {
        inline else => |m| @field(row, @tagName(m)),
    };
}

/// What follows a number over a limit: `!` a warning, `!!` critical.
fn marker(row: Row, column: Column) []const u8 {
    const level = levelOf(row, column.metric) orelse return "";
    return switch (level) {
        .warning => "!",
        .critical => "!!",
    };
}

fn writeText(w: *Writer, all: []const Row, listed: Listed, files: usize, classes: Classes) Writer.Error!void {
    if (listed.rows.len > 0) try writeTable(w, listed.rows);
    try writeSummary(w, all, listed, files, classes, "\n");
}

fn writeTable(w: *Writer, rows: []const Row) Writer.Error!void {
    // Each number column is wide enough for its header and for its widest
    // number with a two-character marker after it.
    var widths: [columns.len]usize = undefined;
    for (columns, &widths) |column, *width| {
        width.* = column.header.len;
        for (rows) |row| {
            width.* = @max(width.*, std.fmt.count("{d}", .{value(row, column)}) + 2);
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
            try w.splatByteAll(' ', width - 2 - number);
            try w.print("{d}{s}", .{ value(row, column), mark });
            try w.splatByteAll(' ', 2 - mark.len + 2);
        }
        try w.print("{s}:{d}", .{ row.path, row.line });
        try w.splatByteAll(' ', locationPad(row, location_width) + 2);
        try w.print("{s}\n", .{row.name});
    }
    try w.writeByte('\n');
}

fn locationPad(row: Row, width: usize) usize {
    return width - std.fmt.count("{s}:{d}", .{ row.path, row.line });
}

fn writeMarkdown(w: *Writer, all: []const Row, listed: Listed, files: usize, classes: Classes) Writer.Error!void {
    if (listed.rows.len > 0) try writeMarkdownTable(w, listed.rows);
    try writeSummary(w, all, listed, files, classes, "\n\n");
}

fn writeMarkdownTable(w: *Writer, rows: []const Row) Writer.Error!void {
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

/// How many functions were measured and how many are over a limit, what
/// the report leaves out and how to see it, then the limits of each class
/// of code they are in; `gap` ends each line.
fn writeSummary(w: *Writer, rows: []const Row, listed: Listed, files: usize, classes: Classes, gap: []const u8) Writer.Error!void {
    var critical: usize = 0;
    var warning: usize = 0;
    for (rows) |row| {
        if (tally(row, .critical) > 0) {
            critical += 1;
        } else if (row.trips.len > 0) warning += 1;
    }
    try w.print("{d} function{s} in {d} file{s}: {d} over a critical threshold (!!), {d} more over a warning one (!).", .{
        rows.len, plural(rows.len), files, plural(files), critical, warning,
    });
    const not = listed.not_listed;
    if (not.within_limits > 0) try w.print("{s}{d} within limits {s} not listed; --all lists every function.", .{ gap, not.within_limits, isAre(not.within_limits) });
    if (not.past_top > 0) try w.print("{s}{d} more {s} not listed: --top {d} keeps the worst {d}.", .{ gap, not.past_top, isAre(not.past_top), listed.top.?, listed.top.? });
    if (not.not_selected > 0) try w.print("{s}{d} not picked by --function {s} not listed.", .{ gap, not.not_selected, isAre(not.not_selected) });
    for (std.enums.values(Class)) |class| {
        for (rows) |row| {
            if (row.class == class) break;
        } else continue;
        try w.print("{s}Thresholds for {t} code (warning, critical):", .{ gap, class });
        const limits = classes.get(class);
        var first = true;
        for (std.enums.values(Metric)) |metric| {
            const limit = limits.of(metric);
            if (limit.warning == null and limit.critical == null) continue;
            try w.print("{s} {t}", .{ if (first) "" else ";", metric });
            first = false;
            if (limit.warning) |n| try w.print(" {d}", .{n}) else try w.writeAll(" -");
            if (limit.critical) |n| try w.print(", {d}", .{n});
        }
        try w.writeAll(if (first) " none." else ".");
    }
    try w.writeByte('\n');
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn isAre(n: usize) []const u8 {
    return if (n == 1) "is" else "are";
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
    try rank(arena, rows, .defaults);
    return rows;
}

fn expectWritten(format: Format, listing: Listing, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    const rows = try sampleRows(arena);
    try write(&out.writer, format, rows, try list(arena, rows, listing), .{ .version = "0.0.0", .files = 2, .classes = .defaults });
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
    try std.testing.expectEqual(1, countCritical(rows));
    try std.testing.expectEqual(0, countCritical(rows[1..]));
}

test "rank: each row against its own class's thresholds" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const row: Row = .{ .path = "a.zig", .line = 1, .column = 4, .name = "f", .kind = .@"fn", .cyclomatic = 13, .lines = 45, .nesting = 0, .params = 0, .params_weighted = 0 };
    var rows = [_]Row{ row, row, row };
    rows[0].class = .hot;
    rows[1].line = 2;
    rows[2].class = .cold;
    rows[2].line = 3;
    try rank(arena, &rows, .defaults);
    // Hot: cyclomatic 13 is past 12, lines 45 past 40. Normal: a warning
    // for cyclomatic only. Cold: nothing.
    try std.testing.expectEqual(Class.hot, rows[0].class);
    try std.testing.expectEqual(2, rows[0].trips.len);
    try std.testing.expectEqual(.critical, levelOf(rows[0], .cyclomatic).?);
    try std.testing.expectEqual(.warning, levelOf(rows[1], .cyclomatic).?);
    try std.testing.expectEqual(null, levelOf(rows[1], .lines));
    try std.testing.expectEqual(0, rows[2].trips.len);

    var out: Writer.Allocating = .init(arena);
    try writeSummary(&out.writer, &rows, .{ .rows = &rows }, 1, .defaults, "\n");
    try std.testing.expectEqualStrings(
        \\3 functions in 1 file: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\Thresholds for hot code (warning, critical): cyclomatic 8, 12; lines 40, 80; nesting 3; params 4.
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\Thresholds for cold code (warning, critical): cyclomatic -, 20.
        \\
    , out.written());
}

test "write: text, every function" {
    try expectWritten(.text, .{ .all = true },
        \\cyclomatic  lines  nesting  params  weighted  location       function
        \\      22!!  140!!      5!      2         3    src/b.zig:120  Parser.next
        \\       4     20        1       6!        8    src/a.zig:2    wide
        \\       3     12        1       0         0    src/a.zig:30   test "a|b"
        \\       1      3        0       0         0    src/a.zig:9    small
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
}

test "write: by default only what is over a threshold, and the footer says how to see the rest" {
    try expectWritten(.text, .{},
        \\cyclomatic  lines  nesting  params  weighted  location       function
        \\      22!!  140!!      5!      2         3    src/b.zig:120  Parser.next
        \\       4     20        1       6!        8    src/a.zig:2    wide
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\2 within limits are not listed; --all lists every function.
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
    try expectWritten(.text, .{ .top = 1 },
        \\cyclomatic  lines  nesting  params  weighted  location       function
        \\      22!!  140!!      5!      2         3    src/b.zig:120  Parser.next
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\2 within limits are not listed; --all lists every function.
        \\1 more is not listed: --top 1 keeps the worst 1.
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
    // Picked, a function within limits is listed all the same.
    try expectWritten(.text, .{ .picked = &.{ false, false, true, false } },
        \\cyclomatic  lines  nesting  params  weighted  location      function
        \\       3     12        1       0         0    src/a.zig:30  test "a|b"
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\3 not picked by --function are not listed.
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
}

test "write: nothing to list is a summary alone" {
    try expectWritten(.md, .{ .picked = &.{ false, false, false, false }, .top = 3 },
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\
        \\4 not picked by --function are not listed.
        \\
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
}

test "write: Markdown" {
    try expectWritten(.md, .{ .all = true },
        \\| cyclomatic | lines | nesting | params | weighted | location | function |
        \\| ---: | ---: | ---: | ---: | ---: | --- | --- |
        \\| 22 !! | 140 !! | 5 ! | 2 | 3 | `src/b.zig:120` | `Parser.next` |
        \\| 4 | 20 | 1 | 6 ! | 8 | `src/a.zig:2` | `wide` |
        \\| 3 | 12 | 1 | 0 | 0 | `src/a.zig:30` | `test "a\|b"` |
        \\| 1 | 3 | 0 | 0 | 0 | `src/a.zig:9` | `small` |
        \\
        \\4 functions in 2 files: 1 over a critical threshold (!!), 1 more over a warning one (!).
        \\
        \\Thresholds for normal code (warning, critical): cyclomatic 10, 15; lines 50, 100; nesting 4; params 4.
        \\
    );
}

test "write: JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    const rows = try sampleRows(arena);
    try write(&out.writer, .json, rows, try list(arena, rows, .{ .all = true, .top = 3 }), sampleContext());

    // Read back, it says what the table says, and what stderr said.
    const Doc = struct {
        schema: u32,
        gnarl: []const u8,
        files: usize,
        measured: usize,
        not_listed: NotListed,
        check: Check,
        thresholds: Classes,
        errors: []const JsonMessage,
        notes: []const JsonMessage,
        functions: []const Row,
    };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, out.written(), .{});
    try std.testing.expectEqual(schema, doc.schema);
    try std.testing.expectEqualStrings("0.0.0", doc.gnarl);
    try std.testing.expectEqual(Check{ .asked = true, .failed = true, .critical = 1 }, doc.check);
    try std.testing.expectEqualStrings("bad.zig", doc.errors[0].path);
    try std.testing.expectEqual(3, doc.errors[0].line.?);
    try std.testing.expectEqual(null, doc.notes[0].line);
    try std.testing.expectEqualStrings("a.zig:1  f", doc.notes[0].more[0]);
    try std.testing.expectEqual(3, doc.functions.len);
    try std.testing.expectEqual(4, doc.measured);
    try std.testing.expectEqual(NotListed{ .past_top = 1 }, doc.not_listed);
    try std.testing.expectEqual(2, doc.files);
    try std.testing.expectEqualStrings("Parser.next", doc.functions[0].name);
    try std.testing.expectEqualStrings("test \"a|b\"", doc.functions[2].name);
    try std.testing.expectEqual(.@"test", doc.functions[2].kind);
    try std.testing.expectEqual(3, doc.functions[0].trips.len);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .critical, .limit = 15 }, doc.functions[0].trips[0]);
    try std.testing.expectEqual(null, doc.thresholds.normal.nesting.critical);
    try std.testing.expectEqual(20, doc.thresholds.cold.cyclomatic.critical);
    try std.testing.expectEqual(.normal, doc.functions[0].class);
    // One function to a line, the functions last.
    try std.testing.expectEqual(5, std.mem.countScalar(u8, out.written(), '\n'));
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "{\"schema\":1,\"gnarl\":\"0.0.0\",\"files\":2,"));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "}\n]}\n"));
}

const JsonMessage = struct { path: []const u8, line: ?u32, column: ?u32, text: []const u8, more: []const []const u8 };

fn sampleContext() Context {
    return .{
        .version = "0.0.0",
        .files = 2,
        .classes = .defaults,
        .check = .{ .asked = true, .failed = true, .critical = 1 },
        .messages = &.{
            .{ .level = .@"error", .path = "bad.zig", .line = 3, .column = 7, .text = "expected ';' after statement" },
            .{ .level = .note, .path = "f", .text = "explained the function of exactly that name; 1 more ends with it:", .more = &.{"a.zig:1  f"} },
        },
    };
}

test "write: xml says what json does, and reads back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    const rows = try sampleRows(arena);
    try write(&out.writer, .xml, rows, try list(arena, rows, .{}), sampleContext());

    const doc = try formats.readXml(arena, out.written());
    try std.testing.expectEqualStrings("gnarl", doc.name);
    try std.testing.expectEqualStrings("1", doc.get("schema").?);
    try std.testing.expectEqualStrings("4", doc.get("measured").?);
    try std.testing.expectEqualStrings("2", doc.child("not_listed").?.get("within_limits").?);
    try std.testing.expectEqualStrings("true", doc.child("check").?.get("failed").?);
    try std.testing.expectEqual(3, doc.child("thresholds").?.children.len);
    try std.testing.expectEqualStrings("3", doc.child("errors").?.children[0].get("line").?);
    try std.testing.expectEqualStrings("a.zig:1  f", doc.child("notes").?.children[0].children[0].get("text").?);
    const listed = doc.child("functions").?.children;
    try std.testing.expectEqual(2, listed.len);
    try std.testing.expectEqualStrings("Parser.next", listed[0].get("name").?);
    try std.testing.expectEqualStrings("22", listed[0].get("cyclomatic").?);
    try std.testing.expectEqualStrings("critical", listed[0].children[0].get("level").?);
}

test "write: csv and tsv, a header and a row per function listed, read back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try sampleRows(arena);
    for ([_]Format{ .csv, .tsv }) |format| {
        var out: Writer.Allocating = .init(arena);
        try write(&out.writer, format, rows, try list(arena, rows, .{ .all = true }), sampleContext());
        const table = try formats.readDelimited(arena, if (format == .csv) .csv else .tsv, out.written());
        try std.testing.expectEqual(5, table.len);
        for (delimited_columns, table[0]) |want, got| try std.testing.expectEqualStrings(want, got);
        try std.testing.expectEqualStrings("Parser.next", table[1][4]);
        try std.testing.expectEqualStrings("cyclomatic:critical:15 lines:critical:100 nesting:warning:4", table[1][12]);
        try std.testing.expectEqualStrings("test \"a|b\"", table[3][4]);
        try std.testing.expectEqualStrings("", table[3][12]);
    }
}

test "writeCode: a backtick in the text takes a longer fence" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCode(&out.writer, "test \"a `b`\"", "");
    try std.testing.expectEqualStrings("``test \"a `b`\"``", out.written());
}

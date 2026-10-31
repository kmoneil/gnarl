//! The baseline: the functions over a critical threshold when it was
//! written, with their numbers. Held to it, --check fails only what is new
//! or worse: each metric of a function may go up to its critical limit, or
//! to the baseline's number if that is higher. So existing debt does not
//! block a change, new debt does, and debt may only shrink.
//!
//! The file is plain text, a line per function, sorted, so that a change
//! to it reads as a diff. Lines starting `#` are comments. Each other line
//! is tab-separated: the path (with `/`), the qualified name, then
//! cyclomatic, cognitive, lines, nesting, params and params_weighted. A tab, newline,
//! carriage return or backslash in a field is written `\t`, `\n`, `\r` or
//! `\\`.
//!
//! A function is known by its path and its qualified name, so a rename or
//! a move to another file is a new function. A second function of the same
//! name in one file is `name#2`, a third `name#3`, by order in the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const formats = @import("formats.zig");
const Row = @import("report.zig").Row;
const thresholds = @import("thresholds.zig");
const Classes = thresholds.Classes;
const Metric = thresholds.Metric;

/// Where gnarl looks when no file is named.
pub const default_path = "complexity.baseline";

/// The comment the file starts with.
const header =
    \\# gnarl baseline: the functions over a critical threshold when it was
    \\# written. gnarl --check fails a function that is new and over one, or
    \\# above its number here; gnarl --update-baseline rewrites this file.
    \\# path, name, cyclomatic, cognitive, lines, nesting, params, params_weighted
    \\
;

const metrics = std.enums.values(Metric);

pub const Entry = struct {
    /// The path with `/`, then a tab, then the name with its `#n`, if any.
    key: []const u8,
    values: [metrics.len]u32,
};

pub const Baseline = struct {
    entries: []const Entry,
    by_key: std.StringHashMapUnmanaged(usize),

    pub fn get(b: Baseline, key: []const u8) ?Entry {
        const i = b.by_key.get(key) orelse return null;
        return b.entries[i];
    }
};

/// Why a baseline file cannot be used, and on which line.
pub const Problem = struct { line: u32, message: []const u8 };

/// Reads a baseline file. On `error.Invalid`, `problem` says what is wrong
/// and where. Allocated with `arena`.
pub fn parse(arena: Allocator, text: []const u8, problem: *Problem) error{ OutOfMemory, Invalid }!Baseline {
    var entries: std.ArrayList(Entry) = .empty;
    var by_key: std.StringHashMapUnmanaged(usize) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const entry = switch (try parseLine(arena, line)) {
            .entry => |entry| entry,
            .bad => |message| return fail(problem, number, message),
        };
        const seen = try by_key.getOrPut(arena, entry.key);
        if (seen.found_existing) return fail(problem, number, "a function given twice");
        seen.value_ptr.* = entries.items.len;
        try entries.append(arena, entry);
    }
    return .{ .entries = entries.items, .by_key = by_key };
}

/// A line of a baseline file read: its entry, or why it cannot be.
const Line = union(enum) { entry: Entry, bad: []const u8 };

fn parseLine(arena: Allocator, line: []const u8) Allocator.Error!Line {
    var fields: [2 + metrics.len][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |field| : (n += 1) {
        if (n == fields.len) return .{ .bad = "more than 8 fields" };
        fields[n] = unescape(arena, field) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.BadEscape => return .{ .bad = "a backslash that is not \\t, \\n, \\r or \\\\" },
        };
    }
    // Written before cognitive complexity was measured.
    if (n == fields.len - 1) return .{ .bad = "7 fields, a baseline from before cognitive complexity; gnarl --update-baseline rewrites it" };
    if (n != fields.len) return .{ .bad = "fewer than 8 fields: path, name and the six metrics, tab-separated" };
    var entry: Entry = .{ .key = try std.mem.concat(arena, u8, &.{ fields[0], "\t", fields[1] }), .values = undefined };
    for (&entry.values, fields[2..]) |*value, field| {
        value.* = std.fmt.parseInt(u32, field, 10) catch return .{ .bad = "a metric that is not a number" };
    }
    return .{ .entry = entry };
}

fn fail(problem: *Problem, line: u32, message: []const u8) error{Invalid} {
    problem.* = .{ .line = line, .message = message };
    return error.Invalid;
}

fn unescape(arena: Allocator, field: []const u8) error{ OutOfMemory, BadEscape }![]const u8 {
    if (std.mem.findScalar(u8, field, '\\') == null) return field;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < field.len) : (i += 1) {
        if (field[i] != '\\') {
            try out.append(arena, field[i]);
            continue;
        }
        i += 1;
        if (i == field.len) return error.BadEscape;
        try out.append(arena, switch (field[i]) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            '\\' => '\\',
            else => return error.BadEscape,
        });
    }
    return out.items;
}

/// Each row's key, in the order of `rows`: its path with `/`, a tab, and
/// its name, with `#n` for the nth function of that name in its file.
pub fn keys(arena: Allocator, rows: []const Row) Allocator.Error![]const []const u8 {
    // By place, so that #2 is the second in the file whatever the rank.
    const order = try arena.alloc(usize, rows.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, rows, byPlace);
    const out = try arena.alloc([]const u8, rows.len);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    for (order) |i| {
        const row = rows[i];
        const plain = try std.mem.concat(arena, u8, &.{ try slashed(arena, row.path), "\t", row.name });
        const count = try seen.getOrPut(arena, plain);
        count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
        out[i] = if (count.value_ptr.* == 1) plain else try std.fmt.allocPrint(arena, "{s}#{d}", .{ plain, count.value_ptr.* });
    }
    return out;
}

fn byPlace(rows: []const Row, a: usize, b: usize) bool {
    return switch (std.mem.order(u8, rows[a].path, rows[b].path)) {
        .lt => true,
        .gt => false,
        .eq => rows[a].line < rows[b].line,
    };
}

/// `path` with `/` for the platform's separator, so a baseline written on
/// one platform holds on another.
fn slashed(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.sep == '/') return path;
    return std.mem.replaceOwned(u8, arena, path, &.{std.fs.path.sep}, "/");
}

/// Writes the baseline of `rows`, ranked against `classes`: each function
/// over a critical threshold, sorted. Returns how many it wrote.
pub fn write(arena: Allocator, w: *Writer, rows: []const Row) (Allocator.Error || Writer.Error)!usize {
    const row_keys = try keys(arena, rows);
    var kept: std.ArrayList(usize) = .empty;
    for (rows, 0..) |row, i| {
        for (row.trips) |trip| if (trip.level == .critical) {
            try kept.append(arena, i);
            break;
        };
    }
    std.mem.sort(usize, kept.items, row_keys, byKey);
    try w.writeAll(header);
    for (kept.items) |i| {
        const tab = std.mem.findScalar(u8, row_keys[i], '\t').?;
        try formats.field(w, .tsv, true, row_keys[i][0..tab]);
        try formats.field(w, .tsv, false, row_keys[i][tab + 1 ..]);
        inline for (metrics) |metric| try formats.fieldInt(w, .tsv, false, @field(rows[i], @tagName(metric)));
        try w.writeByte('\n');
    }
    return kept.items.len;
}

fn byKey(row_keys: []const []const u8, a: usize, b: usize) bool {
    return std.mem.order(u8, row_keys[a], row_keys[b]) == .lt;
}

/// A metric of a function that --check fails.
pub const Failure = struct {
    path: []const u8,
    line: u32,
    name: []const u8,
    metric: Metric,
    value: u32,
    /// Its critical limit.
    limit: u32,
    /// The baseline's number for it, when the baseline holds the function.
    baselined: ?u32,
};

pub const Ratchet = struct {
    /// Worst first, as the rows are.
    failures: []const Failure,
    /// Baselined functions now under the baseline's number on a metric:
    /// --update-baseline would tighten the ratchet.
    improved: usize,
    /// Baselined functions of a file read that are no longer there:
    /// renamed, moved or deleted.
    gone: usize,
};

/// What --check finds in `rows`, ranked worst first, against `base`, or
/// against the critical limits alone with no baseline. `paths` are the
/// files read, so that a baselined function of a file not read this time
/// is not taken for gone.
pub fn ratchet(arena: Allocator, rows: []const Row, classes: Classes, base: ?Baseline, paths: []const []const u8) Allocator.Error!Ratchet {
    const row_keys = try keys(arena, rows);
    var failures: std.ArrayList(Failure) = .empty;
    var improved: usize = 0;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    for (rows, row_keys) |row, key| {
        try present.put(arena, key, {});
        const held = if (base) |b| b.get(key) else null;
        const limits = classes.get(row.class);
        var better = false;
        var failed = false;
        inline for (metrics, 0..) |metric, m| {
            const value = @field(row, @tagName(metric));
            if (limits.of(metric).critical) |limit| {
                const allowed = if (held) |h| @max(limit, h.values[m]) else limit;
                if (value > allowed) {
                    failed = true;
                    try failures.append(arena, .{
                        .path = row.path,
                        .line = row.line,
                        .name = row.name,
                        .metric = metric,
                        .value = value,
                        .limit = limit,
                        .baselined = if (held) |h| h.values[m] else null,
                    });
                } else if (held) |h| {
                    if (h.values[m] > limit and value < h.values[m]) better = true;
                }
            }
        }
        if (better and !failed) improved += 1;
    }
    var gone: usize = 0;
    if (base) |b| {
        var read: std.StringHashMapUnmanaged(void) = .empty;
        for (paths) |path| try read.put(arena, try slashed(arena, path), {});
        for (b.entries) |entry| {
            const path = entry.key[0..std.mem.findScalar(u8, entry.key, '\t').?];
            if (read.contains(path) and !present.contains(entry.key)) gone += 1;
        }
    }
    return .{ .failures = failures.items, .improved = improved, .gone = gone };
}

/// How many functions `failures` names; they are grouped by function.
pub fn functionsFailing(failures: []const Failure) usize {
    var n: usize = 0;
    for (failures, 0..) |f, i| {
        if (i == 0 or failures[i - 1].line != f.line or !std.mem.eql(u8, failures[i - 1].path, f.path)) n += 1;
    }
    return n;
}

fn sampleRow(path: []const u8, line: u32, name: []const u8, cyclomatic: u32, lines: u32) Row {
    return .{ .path = path, .line = line, .column = 4, .name = name, .kind = .@"fn", .cyclomatic = cyclomatic, .cognitive = 0, .lines = lines, .nesting = 0, .params = 0, .params_weighted = 0 };
}

test "write, then read back: the functions over a critical threshold, sorted, a second of one name #2" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rows = [_]Row{
        sampleRow("src/b.zig", 40, "parse", 30, 20),
        sampleRow("src/a.zig", 9, "small", 2, 3),
        sampleRow("src/a.zig", 50, "S.a", 16, 10),
        sampleRow("src/a.zig", 12, "S.a", 20, 120),
        sampleRow("src/a.zig", 70, "test \"tab\there\"", 40, 3),
    };
    try @import("report.zig").rank(arena, &rows, .defaults);
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.testing.expectEqual(4, try write(arena, &out.writer, &rows));
    try std.testing.expectEqualStrings(header ++
        "src/a.zig\tS.a\t20\t0\t120\t0\t0\t0\n" ++
        "src/a.zig\tS.a#2\t16\t0\t10\t0\t0\t0\n" ++
        "src/a.zig\ttest \"tab\\there\"\t40\t0\t3\t0\t0\t0\n" ++
        "src/b.zig\tparse\t30\t0\t20\t0\t0\t0\n", out.written());

    var problem: Problem = undefined;
    const b = try parse(arena, out.written(), &problem);
    try std.testing.expectEqual(4, b.entries.len);
    try std.testing.expectEqual(16, b.get("src/a.zig\tS.a#2").?.values[0]);
    try std.testing.expectEqual(40, b.get("src/a.zig\ttest \"tab\there\"").?.values[0]);
}

test "parse: a bad line says which and why" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = undefined;
    try std.testing.expectError(error.Invalid, parse(arena, "# x\nsrc/a.zig\tf\t1\t2\n", &problem));
    try std.testing.expectEqual(2, problem.line);
    try std.testing.expectError(error.Invalid, parse(arena, "a\tf\t1\t2\t3\t4\t5\tsix\n", &problem));
    try std.testing.expectEqualStrings("a metric that is not a number", problem.message);
    // A line of the format before cognitive complexity says how to rewrite it.
    try std.testing.expectError(error.Invalid, parse(arena, "a\tf\t1\t1\t1\t1\t1\n", &problem));
    try std.testing.expectEqualStrings("7 fields, a baseline from before cognitive complexity; gnarl --update-baseline rewrites it", problem.message);
    try std.testing.expectError(error.Invalid, parse(arena, "a\tf\t1\t1\t1\t1\t1\t1\na\tf\t2\t2\t2\t2\t2\t2\n", &problem));
    try std.testing.expectEqualStrings("a function given twice", problem.message);
    try std.testing.expectEqual(0, (try parse(arena, "", &problem)).entries.len);
}

test "ratchet: new over a limit, above its baseline, newly over another; within limits, anything goes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = undefined;
    // Held: worse at cyclomatic 30, lines 120; kept at 20, 60; improved
    // from 40; gone; and one in a file not read this time.
    const base = try parse(arena, "src/a.zig\tworse\t30\t0\t120\t0\t0\t0\n" ++
        "src/a.zig\tkept\t20\t0\t60\t0\t0\t0\n" ++
        "src/a.zig\tbetter\t40\t0\t10\t0\t0\t0\n" ++
        "src/a.zig\tgone\t50\t0\t10\t0\t0\t0\n" ++
        "src/other.zig\telsewhere\t50\t0\t10\t0\t0\t0\n", &problem);
    var rows = [_]Row{
        sampleRow("src/a.zig", 1, "worse", 31, 120),
        sampleRow("src/a.zig", 20, "kept", 20, 101),
        sampleRow("src/a.zig", 40, "better", 25, 10),
        sampleRow("src/a.zig", 60, "new", 16, 10),
        sampleRow("src/a.zig", 80, "fine", 15, 100),
    };
    try @import("report.zig").rank(arena, &rows, .defaults);
    const r = try ratchet(arena, &rows, .defaults, base, &.{"src/a.zig"});
    // worse: cyclomatic 31 over its 30. kept: lines 101 crosses 100, which
    // its baseline (60) did not. new: 16 over 15, not baselined.
    try std.testing.expectEqual(3, r.failures.len);
    try std.testing.expectEqual(3, functionsFailing(r.failures));
    for (r.failures) |f| {
        if (std.mem.eql(u8, f.name, "worse")) try std.testing.expectEqual(Failure{ .path = f.path, .line = 1, .name = f.name, .metric = .cyclomatic, .value = 31, .limit = 15, .baselined = 30 }, f);
        if (std.mem.eql(u8, f.name, "kept")) try std.testing.expectEqual(.lines, f.metric);
        if (std.mem.eql(u8, f.name, "new")) try std.testing.expectEqual(null, f.baselined);
    }
    try std.testing.expectEqual(1, r.improved);
    try std.testing.expectEqual(1, r.gone);

    // With no baseline, every critical crossing fails.
    const plain = try ratchet(arena, &rows, .defaults, null, &.{"src/a.zig"});
    // worse and kept on two metrics each, better and new on one.
    try std.testing.expectEqual(6, plain.failures.len);
    try std.testing.expectEqual(4, functionsFailing(plain.failures));
}

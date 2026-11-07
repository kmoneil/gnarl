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
/// over a critical threshold, and the entries `kept`, of files no row is
/// of, sorted together. Returns how many functions of `rows` it wrote.
pub fn write(arena: Allocator, w: *Writer, rows: []const Row, kept: []const Entry) (Allocator.Error || Writer.Error)!usize {
    const row_keys = try keys(arena, rows);
    var lines: std.ArrayList(Entry) = .empty;
    try lines.appendSlice(arena, kept);
    for (rows, row_keys) |row, key| {
        for (row.trips) |trip| if (trip.level == .critical) {
            var entry: Entry = .{ .key = key, .values = undefined };
            inline for (metrics, 0..) |metric, m| entry.values[m] = @field(row, @tagName(metric));
            try lines.append(arena, entry);
            break;
        };
    }
    std.mem.sort(Entry, lines.items, {}, byKey);
    try w.writeAll(header);
    for (lines.items) |entry| {
        const tab = std.mem.findScalar(u8, entry.key, '\t').?;
        try formats.field(w, .tsv, true, entry.key[0..tab]);
        try formats.field(w, .tsv, false, entry.key[tab + 1 ..]);
        for (entry.values) |value| try formats.fieldInt(w, .tsv, false, value);
        try w.writeByte('\n');
    }
    return lines.items.len - kept.len;
}

fn byKey(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
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
    /// Baselined functions still over a critical limit, but under the
    /// baseline's number on a metric: --update-baseline would tighten the
    /// ratchet.
    improved: usize,
    /// Baselined functions now within every critical limit: their entries
    /// hold nothing back but let them grow, and --update-baseline drops
    /// them.
    unneeded: usize,
    /// Baselined functions no longer there: of a file read, renamed, moved
    /// or deleted; of a file not read under a path given, its file deleted,
    /// excluded or ignored.
    gone: usize,
};

/// What a run read, which is all --check may take a baselined function
/// for gone in: one of a file outside it is not.
pub const Read = struct {
    /// The files read.
    files: []const []const u8,
    /// The paths the run was given, cleaned: a baselined function of a
    /// file under one that was not read is gone with its file.
    roots: []const []const u8,
};

/// What --check finds in `rows`, ranked worst first, against `base`, or
/// against the critical limits alone with no baseline. What the run
/// `read` bounds what is taken for gone.
pub fn ratchet(arena: Allocator, rows: []const Row, classes: Classes, base: ?Baseline, read: Read) Allocator.Error!Ratchet {
    const row_keys = try keys(arena, rows);
    var failures: std.ArrayList(Failure) = .empty;
    var improved: usize = 0;
    var unneeded: usize = 0;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    for (rows, row_keys) |row, key| {
        try present.put(arena, key, {});
        const held = if (base) |b| b.get(key) else null;
        const s = try judge(arena, row, held, classes.get(row.class), &failures);
        if (held == null or s.failed) continue;
        if (!s.over) {
            unneeded += 1;
        } else if (s.better) improved += 1;
    }
    const gone = if (base) |b| try countGone(arena, b, present, read) else 0;
    return .{ .failures = failures.items, .improved = improved, .unneeded = unneeded, .gone = gone };
}

/// How many of `base`'s functions are gone: of a file read and not
/// `present`, or of a file not read under a path given.
fn countGone(arena: Allocator, base: Baseline, present: std.StringHashMapUnmanaged(void), read: Read) Allocator.Error!usize {
    const reached: Reached = try .init(arena, read);
    var gone: usize = 0;
    for (base.entries) |entry| {
        const is_gone = switch (reached.of(entry)) {
            .read => !present.contains(entry.key),
            .under => true,
            .outside => false,
        };
        if (is_gone) gone += 1;
    }
    return gone;
}

/// The entries of `base` of a file outside what the run `read`: not read,
/// and under no path given. The run says nothing of them, so
/// --update-baseline keeps them.
pub fn outside(arena: Allocator, base: Baseline, read: Read) Allocator.Error![]const Entry {
    const reached: Reached = try .init(arena, read);
    var out: std.ArrayList(Entry) = .empty;
    for (base.entries) |entry| if (reached.of(entry) == .outside) try out.append(arena, entry);
    return out.items;
}

/// Where the file of a baselined function stands in what a run read.
const Reach = enum {
    /// Read: its functions are among the rows.
    read,
    /// Not read, but under a path given: deleted, excluded or ignored.
    under,
    /// Not read, and under no path given.
    outside,
};

/// What a run read, with `/`, to say where a file stands in it.
const Reached = struct {
    files: std.StringHashMapUnmanaged(void),
    roots: []const []const u8,

    fn init(arena: Allocator, read: Read) Allocator.Error!Reached {
        var files: std.StringHashMapUnmanaged(void) = .empty;
        for (read.files) |path| try files.put(arena, try slashed(arena, path), {});
        const roots = try arena.alloc([]const u8, read.roots.len);
        for (read.roots, roots) |root, *r| r.* = try slashed(arena, root);
        return .{ .files = files, .roots = roots };
    }

    fn of(r: Reached, entry: Entry) Reach {
        const path = entry.key[0..std.mem.findScalar(u8, entry.key, '\t').?];
        if (r.files.contains(path)) return .read;
        return if (underAny(r.roots, path)) .under else .outside;
    }
};

/// Whether `path` is one of `roots` or inside one, all with `/`. `.`
/// holds every relative path that does not climb out of it.
fn underAny(roots: []const []const u8, path: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, root, ".")) {
            const climbs = std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../");
            if (!climbs and !std.fs.path.isAbsolute(path)) return true;
        } else if (std.mem.startsWith(u8, path, root)) {
            // A root that ends in `/` is a file system's root.
            if (path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/') return true;
        }
    }
    return false;
}

/// How a function stands against its limits and its baseline entry.
const Standing = struct {
    /// Over what it may be on a metric.
    failed: bool = false,
    /// Over a critical limit on a metric.
    over: bool = false,
    /// Under its baseline's number on a metric that is over its limit.
    better: bool = false,

    /// Holds `row`'s `metric`, `value`, to its critical `limit`, or to its
    /// baseline's number, `baselined`, when that is higher; a failure
    /// appended to `failures`.
    fn hold(s: *Standing, arena: Allocator, row: Row, metric: Metric, value: u32, limit: u32, baselined: ?u32, failures: *std.ArrayList(Failure)) Allocator.Error!void {
        s.over = s.over or value > limit;
        const allowed = if (baselined) |b| @max(limit, b) else limit;
        if (value > allowed) {
            s.failed = true;
            try failures.append(arena, .{ .path = row.path, .line = row.line, .name = row.name, .metric = metric, .value = value, .limit = limit, .baselined = baselined });
        } else if (baselined) |b| {
            if (b > limit and value < b) s.better = true;
        }
    }
};

/// How `row` stands, held to `limits` and the entry `held`; each metric it
/// fails on appended to `failures`. A flat dispatch's cyclomatic is held
/// to nothing.
fn judge(arena: Allocator, row: Row, held: ?Entry, limits: thresholds.Thresholds, failures: *std.ArrayList(Failure)) Allocator.Error!Standing {
    var s: Standing = .{};
    const dispatch = limits.isDispatch(row.cyclomatic, row.cognitive);
    inline for (metrics, 0..) |metric, m| {
        const limit = limits.of(metric).critical;
        if (limit != null and !(dispatch and metric == .cyclomatic)) {
            try s.hold(arena, row, metric, @field(row, @tagName(metric)), limit.?, if (held) |h| h.values[m] else null, failures);
        }
    }
    return s;
}

/// How many functions `failures` names; they are grouped by function.
pub fn functionsFailing(failures: []const Failure) usize {
    var n: usize = 0;
    for (failures, 0..) |f, i| {
        if (i == 0 or failures[i - 1].line != f.line or !std.mem.eql(u8, failures[i - 1].path, f.path)) n += 1;
    }
    return n;
}

/// A row whose cognitive, 20, is past its warning: so no flat dispatch,
/// and its cyclomatic is held.
fn sampleRow(path: []const u8, line: u32, name: []const u8, cyclomatic: u32, lines: u32) Row {
    return .{ .path = path, .line = line, .column = 4, .name = name, .kind = .@"fn", .cyclomatic = cyclomatic, .cognitive = 20, .lines = lines, .nesting = 0, .params = 0, .params_weighted = 0 };
}

/// A run given src/a.zig alone.
const read_a: Read = .{ .files = &.{"src/a.zig"}, .roots = &.{"src/a.zig"} };

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
    try std.testing.expectEqual(4, try write(arena, &out.writer, &rows, &.{}));
    try std.testing.expectEqualStrings(header ++
        "src/a.zig\tS.a\t20\t20\t120\t0\t0\t0\n" ++
        "src/a.zig\tS.a#2\t16\t20\t10\t0\t0\t0\n" ++
        "src/a.zig\ttest \"tab\\there\"\t40\t20\t3\t0\t0\t0\n" ++
        "src/b.zig\tparse\t30\t20\t20\t0\t0\t0\n", out.written());

    var problem: Problem = undefined;
    const b = try parse(arena, out.written(), &problem);
    try std.testing.expectEqual(4, b.entries.len);
    try std.testing.expectEqual(16, b.get("src/a.zig\tS.a#2").?.values[0]);
    try std.testing.expectEqual(40, b.get("src/a.zig\ttest \"tab\there\"").?.values[0]);

    // Entries kept from files no row is of go in among them, in order,
    // escaped as they were read, and are not counted as written.
    const kept = [_]Entry{
        .{ .key = "build.zig\tbuild", .values = .{ 16, 17, 18, 1, 1, 1 } },
        .{ .key = "src/aa.zig\tf\tg", .values = .{ 20, 0, 0, 0, 0, 0 } },
    };
    var again: std.Io.Writer.Allocating = .init(arena);
    try std.testing.expectEqual(4, try write(arena, &again.writer, &rows, &kept));
    try std.testing.expectEqualStrings(header ++
        "build.zig\tbuild\t16\t17\t18\t1\t1\t1\n" ++
        "src/a.zig\tS.a\t20\t20\t120\t0\t0\t0\n" ++
        "src/a.zig\tS.a#2\t16\t20\t10\t0\t0\t0\n" ++
        "src/a.zig\ttest \"tab\\there\"\t40\t20\t3\t0\t0\t0\n" ++
        "src/aa.zig\tf\\tg\t20\t0\t0\t0\t0\t0\n" ++
        "src/b.zig\tparse\t30\t20\t20\t0\t0\t0\n", again.written());
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
        "src/a.zig\tsettled\t20\t0\t10\t0\t0\t0\n" ++
        "src/other.zig\telsewhere\t50\t0\t10\t0\t0\t0\n", &problem);
    var rows = [_]Row{
        sampleRow("src/a.zig", 1, "worse", 31, 120),
        sampleRow("src/a.zig", 20, "kept", 20, 101),
        sampleRow("src/a.zig", 40, "better", 25, 10),
        sampleRow("src/a.zig", 60, "new", 16, 10),
        sampleRow("src/a.zig", 80, "fine", 15, 100),
        sampleRow("src/a.zig", 100, "settled", 12, 10),
    };
    try @import("report.zig").rank(arena, &rows, .defaults);
    const r = try ratchet(arena, &rows, .defaults, base, read_a);
    // worse: cyclomatic 31 over its 30. kept: lines 101 crosses 100, which
    // its baseline (60) did not. new: 16 over 15, not baselined.
    try std.testing.expectEqual(3, r.failures.len);
    try std.testing.expectEqual(3, functionsFailing(r.failures));
    for (r.failures) |f| {
        if (std.mem.eql(u8, f.name, "worse")) try std.testing.expectEqual(Failure{ .path = f.path, .line = 1, .name = f.name, .metric = .cyclomatic, .value = 31, .limit = 15, .baselined = 30 }, f);
        if (std.mem.eql(u8, f.name, "kept")) try std.testing.expectEqual(.lines, f.metric);
        if (std.mem.eql(u8, f.name, "new")) try std.testing.expectEqual(null, f.baselined);
    }
    // better is still over its limit, settled within every one.
    try std.testing.expectEqual(1, r.improved);
    try std.testing.expectEqual(1, r.unneeded);
    try std.testing.expectEqual(1, r.gone);

    // With no baseline, every critical crossing fails.
    const plain = try ratchet(arena, &rows, .defaults, null, read_a);
    // worse and kept on two metrics each, better and new on one.
    try std.testing.expectEqual(6, plain.failures.len);
    try std.testing.expectEqual(4, functionsFailing(plain.failures));
}

test "ratchet: gone, of a file read, or of a file not read under a path given" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problem: Problem = undefined;
    const base = try parse(arena, "src/a.zig\there\t20\t0\t10\t0\t0\t0\n" ++
        "src/a.zig\tmissing\t20\t0\t10\t0\t0\t0\n" ++
        "src/deleted.zig\tparse\t20\t0\t10\t0\t0\t0\n" ++
        "src/core/deleted.zig\tread\t20\t0\t10\t0\t0\t0\n" ++
        "srcs/b.zig\tbeside\t20\t0\t10\t0\t0\t0\n" ++
        "build.zig\tbuild\t20\t0\t10\t0\t0\t0\n" ++
        "../up.zig\tclimbs\t20\t0\t10\t0\t0\t0\n", &problem);
    var rows = [_]Row{sampleRow("src/a.zig", 1, "here", 20, 10)};
    try @import("report.zig").rank(arena, &rows, .defaults);
    const gone = struct {
        fn of(a: Allocator, rs: []const Row, b: Baseline, roots: []const []const u8) !usize {
            return (try ratchet(a, rs, .defaults, b, .{ .files = &.{"src/a.zig"}, .roots = roots })).gone;
        }
    }.of;
    // src/a.zig named alone: only its own missing function.
    try std.testing.expectEqual(1, try gone(arena, &rows, base, &.{"src/a.zig"}));
    // src: its two deleted files too, at any depth; srcs/ is not in it.
    try std.testing.expectEqual(3, try gone(arena, &rows, base, &.{"src"}));
    // .: every relative path but one that climbs out of it.
    try std.testing.expectEqual(5, try gone(arena, &rows, base, &.{"."}));
    // No path, only a file of a function named: as src/a.zig alone.
    try std.testing.expectEqual(1, try gone(arena, &rows, base, &.{}));

    // What is neither read nor gone is outside: --update-baseline keeps it.
    const kept = try outside(arena, base, .{ .files = &.{"src/a.zig"}, .roots = &.{"src"} });
    try std.testing.expectEqual(3, kept.len);
    try std.testing.expectEqualStrings("srcs/b.zig\tbeside", kept[0].key);
    try std.testing.expectEqualStrings("build.zig\tbuild", kept[1].key);
    try std.testing.expectEqualStrings("../up.zig\tclimbs", kept[2].key);
    try std.testing.expectEqual(1, (try outside(arena, base, .{ .files = &.{"src/a.zig"}, .roots = &.{"."} })).len);
}

test "ratchet: a flat dispatch is held to its other limits, not cyclomatic's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var flat = sampleRow("src/a.zig", 1, "visit", 37, 32);
    flat.cognitive = 12;
    var long = sampleRow("src/a.zig", 40, "table", 33, 244);
    long.cognitive = 3;
    var rows = [_]Row{ flat, long };
    try @import("report.zig").rank(arena, &rows, .defaults);
    // visit: cyclomatic 37 with cognitive 12, within its warning: nothing
    // fails. table: a dispatch too, but its 244 lines are over 100.
    const r = try ratchet(arena, &rows, .defaults, null, read_a);
    try std.testing.expectEqual(1, r.failures.len);
    try std.testing.expectEqualStrings("table", r.failures[0].name);
    try std.testing.expectEqual(.lines, r.failures[0].metric);
    // Baselined at its cyclomatic of old, a dispatch's entry holds back
    // nothing: it is within every limit that holds it.
    var problem: Problem = undefined;
    const base = try parse(arena, "src/a.zig\tvisit\t40\t20\t32\t0\t0\t0\n", &problem);
    const visit = for (&rows, 0..) |row, i| {
        if (std.mem.eql(u8, row.name, "visit")) break i;
    } else unreachable;
    try std.testing.expectEqual(1, (try ratchet(arena, rows[visit .. visit + 1], .defaults, base, read_a)).unneeded);
}

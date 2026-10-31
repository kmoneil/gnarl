//! --explain: why a function scores what it does, metric by metric. Each
//! count's own walk gives the reasons, so the reasons always add up to the
//! number the report prints.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const cyclomatic = @import("cyclomatic.zig");
const functions = @import("functions.zig");
const lines = @import("lines.zig");
const nesting = @import("nesting.zig");
const params = @import("params.zig");
const report = @import("report.zig");
const select = @import("select.zig");
const thresholds = @import("thresholds.zig");
const Class = thresholds.Class;
const Metric = thresholds.Metric;
const Thresholds = thresholds.Thresholds;
const Trip = thresholds.Trip;

/// What names a function on the command line.
pub const Selector = select.Selector;

pub const Branch = struct { line: u32, column: u32, construct: []const u8, adds: u32, why: []const u8 };
pub const Level = struct { line: u32, column: u32, construct: []const u8, level: u32 };

pub const Explanation = struct {
    path: []const u8,
    line: u32,
    column: u32,
    name: []const u8,
    kind: functions.Kind,
    class: Class,
    /// The limits it is over, each metric once at its worst.
    trips: []const Trip,
    cyclomatic: struct { value: u32, branches: []const Branch },
    nesting: struct { value: u32, chain: []const Level },
    lines: struct { value: u32, span: u32, blank: u32, comment: u32, closer: u32, nested: u32 },
    params: struct { value: u32, weighted: u32, each: []const params.Param },
};

const LineIndex = select.LineIndex;

/// Every reason for `function`'s numbers. The strings are copied into
/// `arena`, so the explanation outlives `tree`; `scratch` is working
/// memory.
fn build(
    arena: Allocator,
    scratch: Allocator,
    tree: *const Ast,
    index: LineIndex,
    path: []const u8,
    function: functions.Function,
    class: Class,
    limits: Thresholds,
) Allocator.Error!Explanation {
    var raw_branches: std.ArrayList(cyclomatic.Branch) = .empty;
    const cc = try cyclomatic.explain(scratch, tree, function.node, &raw_branches);
    const branches = try arena.alloc(Branch, raw_branches.items.len);
    for (raw_branches.items, branches) |b, *out| {
        const loc = index.ofToken(tree, b.token);
        out.* = .{ .line = loc.line, .column = loc.column, .construct = try arena.dupe(u8, b.construct), .adds = b.adds, .why = b.why };
    }

    var raw_chain: std.ArrayList(nesting.Level) = .empty;
    const depth = try nesting.explain(scratch, tree, function.node, &raw_chain);
    const chain = try arena.alloc(Level, raw_chain.items.len);
    for (raw_chain.items, chain) |l, *out| {
        const loc = index.ofToken(tree, l.token);
        out.* = .{ .line = loc.line, .column = loc.column, .construct = try arena.dupe(u8, l.construct), .level = l.level };
    }

    const breakdown = try lines.explain(scratch, tree, function.node);

    var raw_params: std.ArrayList(params.Param) = .empty;
    const p = try params.explain(scratch, tree, function, &raw_params);
    const each = try arena.alloc(params.Param, raw_params.items.len);
    for (raw_params.items, each) |param, *out| {
        out.* = .{ .name = try arena.dupe(u8, param.name), .type = try arena.dupe(u8, param.type), .weight = param.weight, .why = param.why };
    }

    var e: Explanation = .{
        .path = path,
        .line = function.line,
        .column = function.column,
        .name = try arena.dupe(u8, function.name),
        .kind = function.kind,
        .class = class,
        .trips = &.{},
        .cyclomatic = .{ .value = cc, .branches = branches },
        .nesting = .{ .value = depth, .chain = chain },
        .lines = .{
            .value = breakdown.counted,
            .span = breakdown.span,
            .blank = breakdown.blank,
            .comment = breakdown.comment,
            .closer = breakdown.closer,
            .nested = breakdown.nested,
        },
        .params = .{ .value = p.count, .weighted = p.weighted, .each = each },
    };
    var trips: std.ArrayList(Trip) = .empty;
    for (std.enums.values(Metric)) |metric| {
        if (limits.over(metric, valueOf(e, metric))) |trip| try trips.append(arena, trip);
    }
    e.trips = trips.items;
    return e;
}

fn valueOf(e: Explanation, metric: Metric) u32 {
    return switch (metric) {
        .cyclomatic => e.cyclomatic.value,
        .lines => e.lines.value,
        .nesting => e.nesting.value,
        .params => e.params.value,
        .params_weighted => e.params.weighted,
    };
}

/// Looks for each selector's function in the files read, one at a time.
pub const Search = struct {
    selectors: []const Selector,
    texts: []const []const u8,
    found: []Found,

    const Found = struct {
        /// Functions at the selector's line, or whose whole name it is.
        exact: std.ArrayList(Explanation) = .empty,
        /// Functions around the selector's line, innermost first in the
        /// file read, or whose name ends with it.
        partial: std.ArrayList(Explanation) = .empty,
        /// Whether a selector's file has been read.
        read: bool = false,
    };

    pub fn init(arena: Allocator, texts: []const []const u8) Allocator.Error!Search {
        const selectors = try arena.alloc(Selector, texts.len);
        for (texts, selectors) |text, *s| s.* = try Selector.parse(arena, text);
        const found = try arena.alloc(Found, texts.len);
        @memset(found, .{});
        return .{ .selectors = selectors, .texts = texts, .found = found };
    }

    /// The files the `path:line` selectors name.
    pub fn paths(s: Search, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (s.selectors) |selector| switch (selector) {
            .at => |at| try out.append(arena, at.path),
            .name => {},
        };
        return out.items;
    }

    pub fn hasNames(s: Search) bool {
        for (s.selectors) |selector| if (selector == .name) return true;
        return false;
    }

    /// Explains each function in `tree`, read from `path`, that a selector
    /// names.
    pub fn file(s: *Search, arena: Allocator, scratch: Allocator, path: []const u8, tree: *const Ast, class: Class, limits: Thresholds) Allocator.Error!void {
        const listed = try functions.list(scratch, tree);
        var index: ?LineIndex = null;
        for (s.selectors, s.found) |selector, *found| switch (selector) {
            .at => |at| {
                if (!std.mem.eql(u8, at.path, path)) continue;
                found.read = true;
                if (index == null) index = try LineIndex.init(scratch, tree.source);
                var around: ?functions.Function = null;
                var around_span: u32 = std.math.maxInt(u32);
                for (listed) |function| {
                    if (function.line == at.line) {
                        try found.exact.append(arena, try build(arena, scratch, tree, index.?, path, function, class, limits));
                        break;
                    }
                    const first = index.?.ofToken(tree, tree.firstToken(function.node)).line;
                    const last = index.?.ofToken(tree, tree.lastToken(function.node)).line;
                    if (first <= at.line and at.line <= last and last - first < around_span) {
                        around = function;
                        around_span = last - first;
                    }
                } else if (around) |function| {
                    try found.partial.append(arena, try build(arena, scratch, tree, index.?, path, function, class, limits));
                }
            },
            .name => |name| for (listed) |function| {
                const match = select.matchName(function.name, name);
                if (match == .none) continue;
                if (index == null) index = try LineIndex.init(scratch, tree.source);
                const e = try build(arena, scratch, tree, index.?, path, function, class, limits);
                try (if (match == .exact) &found.exact else &found.partial).append(arena, e);
            },
        };
    }

    /// The one explanation each selector found, in selector order. Says on
    /// stderr why a selector found none, or more than one.
    pub fn results(s: Search, arena: Allocator) Allocator.Error!struct { explanations: []const Explanation, all_found: bool } {
        var out: std.ArrayList(Explanation) = .empty;
        var all_found = true;
        for (s.selectors, s.found, s.texts) |selector, found, text| {
            const matches = if (found.exact.items.len > 0) found.exact.items else found.partial.items;
            if (matches.len == 1) {
                try out.append(arena, matches[0]);
                // A whole name wins, but say which longer ones it hid.
                if (selector == .name and found.exact.items.len == 1 and found.partial.items.len > 0) {
                    const n = found.partial.items.len;
                    std.debug.print("gnarl: {s}: explained the function of exactly that name; {d} more end{s} with it:\n", .{ text, n, if (n == 1) "s" else "" });
                    for (found.partial.items) |m| std.debug.print("  {s}:{d}  {s}\n", .{ m.path, m.line, m.name });
                }
                continue;
            }
            all_found = false;
            if (matches.len == 0) {
                switch (selector) {
                    // A file that could not be read has been said already.
                    .at => if (found.read) std.debug.print("gnarl: {s}: no function at or around that line\n", .{text}),
                    .name => std.debug.print("gnarl: {s}: no function by that name in the files read\n", .{text}),
                }
                continue;
            }
            std.debug.print("gnarl: {s}: {d} functions answer to that name; name one by path:line:\n", .{ text, matches.len });
            for (matches) |m| std.debug.print("  {s}:{d}  {s}\n", .{ m.path, m.line, m.name });
        }
        return .{ .explanations = out.items, .all_found = all_found };
    }
};

/// Writes `explanations` in `format`.
pub fn write(w: *Writer, format: report.Format, explanations: []const Explanation) Writer.Error!void {
    switch (format) {
        .text => for (explanations, 0..) |e, i| {
            if (i > 0) try w.writeByte('\n');
            try writeText(w, e);
        },
        .md => for (explanations, 0..) |e, i| {
            if (i > 0) try w.writeByte('\n');
            try writeMarkdown(w, e);
        },
        .json => {
            try std.json.Stringify.value(.{ .explanations = explanations }, .{ .whitespace = .indent_2 }, w);
            try w.writeByte('\n');
        },
    }
}

/// `, over the warning limit (10)` for a metric over one, else nothing.
fn writeOver(w: *Writer, e: Explanation, metric: Metric) Writer.Error!void {
    for (e.trips) |trip| if (trip.metric == metric) {
        try w.print(", over the {t} limit ({d})", .{ trip.level, trip.limit });
    };
}

fn writeText(w: *Writer, e: Explanation) Writer.Error!void {
    try w.print("{s}:{d}  {s}  ({t} code)\n\n", .{ e.path, e.line, e.name, e.class });

    try w.print("cyclomatic {d}", .{e.cyclomatic.value});
    try writeOver(w, e, .cyclomatic);
    try w.writeAll(if (adding(e) > 0) ": 1, and 1 for each of these\n" else ": 1, nothing branches\n");
    var at_width: usize = 0;
    var construct_width: usize = 0;
    for (e.cyclomatic.branches) |b| {
        if (b.adds == 0) continue;
        at_width = @max(at_width, std.fmt.count("{d}:{d}", .{ b.line, b.column }));
        construct_width = @max(construct_width, b.construct.len);
    }
    for (e.nesting.chain) |l| {
        at_width = @max(at_width, std.fmt.count("{d}:{d}", .{ l.line, l.column }));
        construct_width = @max(construct_width, l.construct.len);
    }
    for (e.cyclomatic.branches) |b| {
        if (b.adds == 0) continue;
        try writeAt(w, b.line, b.column, at_width);
        try w.print("{s}", .{b.construct});
        try w.splatByteAll(' ', construct_width - b.construct.len + 2);
        try w.print("+{d}\n", .{b.adds});
    }
    try writeNotCounted(w, e.cyclomatic.branches, .text);

    try w.print("nesting {d}", .{e.nesting.value});
    try writeOver(w, e, .nesting);
    try w.writeAll(if (e.nesting.chain.len > 0) ": the deepest chain\n" else ": no construct opens a level\n");
    for (e.nesting.chain) |l| {
        try writeAt(w, l.line, l.column, at_width);
        try w.print("{s}", .{l.construct});
        try w.splatByteAll(' ', construct_width - l.construct.len + 2);
        try w.print(" {d}\n", .{l.level});
    }

    try w.print("lines {d}", .{e.lines.value});
    try writeOver(w, e, .lines);
    try w.print(" of the {d} from signature to closing brace; not counted: {d} blank, {d} comment, {d} closing, {d} in nested functions\n", .{
        e.lines.span, e.lines.blank, e.lines.comment, e.lines.closer, e.lines.nested,
    });

    try w.print("params {d}", .{e.params.value});
    try writeOver(w, e, .params);
    try w.print(", weighted {d}", .{e.params.weighted});
    try writeOver(w, e, .params_weighted);
    try w.writeAll(if (e.params.each.len > 0) "\n" else ": none\n");
    var name_width: usize = 0;
    var type_width: usize = 0;
    for (e.params.each) |p| {
        name_width = @max(name_width, p.name.len);
        type_width = @max(type_width, p.type.len);
    }
    for (e.params.each) |p| {
        try w.print("  {s}", .{p.name});
        try w.splatByteAll(' ', name_width - p.name.len + 2);
        try w.print("{s}", .{p.type});
        try w.splatByteAll(' ', type_width - p.type.len + 2);
        try w.print("{d}", .{p.weight});
        if (p.why.len > 0) try w.print("  {s}", .{p.why});
        try w.writeByte('\n');
    }
}

/// How many of the constructs listed add one.
fn adding(e: Explanation) usize {
    var n: usize = 0;
    for (e.cyclomatic.branches) |b| n += @intFromBool(b.adds > 0);
    return n;
}

/// For each kind of construct that adds nothing, one line: where each one
/// is, and why.
fn writeNotCounted(w: *Writer, branches: []const Branch, format: enum { text, md }) Writer.Error!void {
    for (branches, 0..) |b, i| {
        if (b.adds > 0) continue;
        const earlier = for (branches[0..i]) |p| {
            if (sameKind(p, b)) break true;
        } else false;
        if (earlier) continue;
        switch (format) {
            .text => try w.print("  {s} at ", .{b.construct}),
            .md => try w.print("\n`{s}` at ", .{b.construct}),
        }
        var first = true;
        for (branches[i..]) |q| if (sameKind(q, b)) {
            try w.print("{s}{d}:{d}", .{ if (first) "" else ", ", q.line, q.column });
            first = false;
        };
        try w.print(" adds nothing: {s}{s}\n", .{ b.why, if (format == .md) "." else "" });
    }
}

fn sameKind(a: Branch, b: Branch) bool {
    return a.adds == 0 and b.adds == 0 and std.mem.eql(u8, a.construct, b.construct) and std.mem.eql(u8, a.why, b.why);
}

fn writeAt(w: *Writer, line: u32, column: u32, width: usize) Writer.Error!void {
    try w.print("  {d}:{d}", .{ line, column });
    try w.splatByteAll(' ', width - std.fmt.count("{d}:{d}", .{ line, column }) + 2);
}

fn writeMarkdown(w: *Writer, e: Explanation) Writer.Error!void {
    try w.print("### `{s}` at `{s}:{d}` ({t} code)\n\n", .{ e.name, e.path, e.line, e.class });

    try w.print("**cyclomatic {d}**", .{e.cyclomatic.value});
    try writeOver(w, e, .cyclomatic);
    if (adding(e) == 0) {
        try w.writeAll(": 1, nothing branches.\n");
    } else {
        try w.writeAll(": 1, and 1 for each of these.\n\n| at | construct |\n| --- | --- |\n");
        for (e.cyclomatic.branches) |b| if (b.adds > 0) try w.print("| {d}:{d} | `{s}` |\n", .{ b.line, b.column, b.construct });
    }
    try writeNotCounted(w, e.cyclomatic.branches, .md);

    try w.print("\n**nesting {d}**", .{e.nesting.value});
    try writeOver(w, e, .nesting);
    if (e.nesting.chain.len == 0) {
        try w.writeAll(": no construct opens a level.\n");
    } else {
        try w.writeAll(": the deepest chain.\n\n| at | construct | level |\n| --- | --- | ---: |\n");
        for (e.nesting.chain) |l| try w.print("| {d}:{d} | `{s}` | {d} |\n", .{ l.line, l.column, l.construct, l.level });
    }

    try w.print("\n**lines {d}**", .{e.lines.value});
    try writeOver(w, e, .lines);
    try w.print(" of the {d} from signature to closing brace; not counted: {d} blank, {d} comment, {d} closing, {d} in nested functions.\n", .{
        e.lines.span, e.lines.blank, e.lines.comment, e.lines.closer, e.lines.nested,
    });

    try w.print("\n**params {d}**", .{e.params.value});
    try writeOver(w, e, .params);
    try w.print(", weighted {d}", .{e.params.weighted});
    try writeOver(w, e, .params_weighted);
    if (e.params.each.len == 0) {
        try w.writeAll(": none.\n");
    } else {
        try w.writeAll(".\n\n| name | type | weight | why |\n| --- | --- | ---: | --- |\n");
        for (e.params.each) |p| try w.print("| `{s}` | `{s}` | {d} | {s} |\n", .{ p.name, p.type, p.weight, p.why });
    }
}

const sample =
    \\const S = struct {
    \\    fn pick(s: *S, gpa: Allocator, x: u8) !u8 {
    \\        if (x > 3 and x < 9) {
    \\            for (s.items) |item| {
    \\                // the first big one
    \\                if (item > x) return item;
    \\            }
    \\        }
    \\        return try s.fallback(gpa);
    \\    }
    \\};
    \\fn other() void {}
;

/// Explains what `texts` select in `sample`, read as `a.zig`.
fn explainSample(arena: Allocator, texts: []const []const u8) !struct { explanations: []const Explanation, all_found: bool } {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, sample, .{});
    defer tree.deinit(gpa);
    var search: Search = try .init(arena, texts);
    try search.file(arena, arena, "a.zig", &tree, .normal, thresholds.Classes.defaults.normal);
    const r = try search.results(arena);
    return .{ .explanations = r.explanations, .all_found = r.all_found };
}

test "Search: by the line the report prints, by any line inside, by a name or its end" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try explainSample(arena, &.{ "a.zig:2", "a.zig:6", "S.pick", "pick", "a.zig:12" });
    try std.testing.expect(r.all_found);
    for (r.explanations[0..4]) |e| try std.testing.expectEqualStrings("S.pick", e.name);
    try std.testing.expectEqualStrings("other", r.explanations[4].name);
}

test "the reasons add up to the numbers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const e = (try explainSample(arena_state.allocator(), &.{"S.pick"})).explanations[0];
    // 1 + if + and + for + if; the try is listed and adds nothing.
    try std.testing.expectEqual(5, e.cyclomatic.value);
    var sum: u32 = 1;
    for (e.cyclomatic.branches) |b| sum += b.adds;
    try std.testing.expectEqual(e.cyclomatic.value, sum);
    try std.testing.expectEqual(3, e.nesting.value);
    try std.testing.expectEqual(3, e.nesting.chain.len);
    try std.testing.expectEqual(e.lines.span, e.lines.value + e.lines.blank + e.lines.comment + e.lines.closer + e.lines.nested);
    try std.testing.expectEqual(1, e.params.value);
}

test "write: text" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, .text, (try explainSample(arena, &.{"pick"})).explanations);
    try std.testing.expectEqualStrings(
        \\a.zig:2  S.pick  (normal code)
        \\
        \\cyclomatic 5: 1, and 1 for each of these
        \\  3:9   if   +1
        \\  3:19  and  +1
        \\  4:13  for  +1
        \\  6:17  if   +1
        \\  try at 9:16 adds nothing: a try passes an error on; it is not a branch
        \\nesting 3: the deepest chain
        \\  3:9   if    1
        \\  4:13  for   2
        \\  6:17  if    3
        \\lines 5 of the 9 from signature to closing brace; not counted: 0 blank, 1 comment, 3 closing, 0 in nested functions
        \\params 1, weighted 1
        \\  s    *S         0  a leading self
        \\  gpa  Allocator  0  an Allocator: context, not input
        \\  x    u8         1
        \\
    , out.written());
}

test "write: Markdown and JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const explanations = (try explainSample(arena, &.{"other"})).explanations;
    var md: Writer.Allocating = .init(arena);
    try write(&md.writer, .md, explanations);
    try std.testing.expectEqualStrings(
        \\### `other` at `a.zig:12` (normal code)
        \\
        \\**cyclomatic 1**: 1, nothing branches.
        \\
        \\**nesting 0**: no construct opens a level.
        \\
        \\**lines 1** of the 1 from signature to closing brace; not counted: 0 blank, 0 comment, 0 closing, 0 in nested functions.
        \\
        \\**params 0**, weighted 0: none.
        \\
    , md.written());

    var json: Writer.Allocating = .init(arena);
    try write(&json.writer, .json, (try explainSample(arena, &.{"pick"})).explanations);
    const Doc = struct { explanations: []const Explanation };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, json.written(), .{});
    try std.testing.expectEqualStrings("S.pick", doc.explanations[0].name);
    try std.testing.expectEqual(5, doc.explanations[0].cyclomatic.branches.len);
    try std.testing.expectEqualStrings("a leading self", doc.explanations[0].params.each[0].why);
}

test "every golden fixture function: the explanation agrees with its golden row" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const measure = @import("measure.zig");
    var dir = try std.Io.Dir.cwd().openDir(io, "test/golden", .{ .iterate = true });
    defer dir.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const source = try dir.readFileAllocOptions(io, entry.name, gpa, .limited(std.math.maxInt(u32)), .of(u8), 0);
        defer gpa.free(source);
        var tree = try Ast.parse(gpa, source, .{});
        defer tree.deinit(gpa);
        var rows: std.ArrayList(report.Row) = .empty;
        try measure.file(arena, arena, entry.name, &tree, &rows);
        const index = try LineIndex.init(arena, tree.source);
        for (try functions.list(arena, &tree), rows.items) |function, row| {
            const e = try build(arena, arena, &tree, index, entry.name, function, .normal, .{});
            try std.testing.expectEqual(row.cyclomatic, e.cyclomatic.value);
            try std.testing.expectEqual(row.lines, e.lines.value);
            try std.testing.expectEqual(row.nesting, e.nesting.value);
            try std.testing.expectEqual(row.params, e.params.value);
            try std.testing.expectEqual(row.params_weighted, e.params.weighted);
            var sum: u32 = 1;
            for (e.cyclomatic.branches) |b| sum += b.adds;
            try std.testing.expectEqual(e.cyclomatic.value, sum);
            try std.testing.expectEqual(e.nesting.value, e.nesting.chain.len);
            try std.testing.expectEqual(e.lines.span, e.lines.value + e.lines.blank + e.lines.comment + e.lines.closer + e.lines.nested);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 100);
}

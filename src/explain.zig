//! --explain: why a function scores what it does, metric by metric. Each
//! count's own walk gives the reasons, so the reasons always add up to the
//! number the report prints.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const cognitive = @import("cognitive.zig");
const cyclomatic = @import("cyclomatic.zig");
const formats = @import("formats.zig");
const functions = @import("functions.zig");
const messages = @import("messages.zig");
const Message = messages.Message;
const Messages = messages.Messages;
const lines = @import("lines.zig");
const nesting = @import("nesting.zig");
const params = @import("params.zig");
const regions = @import("regions.zig");
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
/// `depth` is how much of `adds` is for the levels the construct sits in.
pub const Cost = struct { line: u32, column: u32, construct: []const u8, adds: u32, depth: u32, why: []const u8 };
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
    cognitive: struct { value: u32, costs: []const Cost },
    nesting: struct { value: u32, chain: []const Level },
    lines: struct { value: u32, span: u32, blank: u32, comment: u32, closer: u32, nested: u32 },
    params: struct { value: u32, weighted: u32, each: []const params.Param },
    /// The signature, then each statement of the body, and what each adds.
    regions: []const Region,
    /// For `path:A-B`, what those lines cost; null otherwise.
    range: ?Range = null,
};

pub const Region = struct {
    first_line: u32,
    last_line: u32,
    /// How many of the body's statements it is: 0 for the signature.
    statements: u32,
    cyclomatic: u32,
    cognitive: u32,
    lines: u32,
    /// The deepest level a construct in it opens; 0 for none.
    nesting: u32,
    /// Its first line, as written.
    text: []const u8,
};

pub const Range = struct {
    first_line: u32,
    last_line: u32,
    cyclomatic: u32,
    cognitive: u32,
    /// How much of `cognitive` is for the depth its structures sit at.
    depth: u32,
    lines: u32,
    /// The deepest level a construct in the lines opens.
    nesting: u32,
    /// Moved into a function of its own, about: that function's numbers
    /// and what this one keeps.
    extracted: regions.Extracted,
};

const LineIndex = select.LineIndex;

/// The signature and each statement of `function`'s body, and what each
/// adds. Allocated with `arena`; `scratch` is working memory.
fn regionsOf(arena: Allocator, scratch: Allocator, tree: *const Ast, index: LineIndex, function: Ast.Node.Index) Allocator.Error![]const Region {
    const facts: regions.Facts = try .of(scratch, tree, function);
    const raw = try regions.ofBody(scratch, tree, function, facts);
    const out = try arena.alloc(Region, raw.len);
    for (raw, out) |r, *o| o.* = .{
        .first_line = index.ofToken(tree, r.first).line,
        .last_line = index.ofToken(tree, r.last).line,
        .statements = r.statements,
        .cyclomatic = r.sum.cyclomatic,
        .cognitive = r.sum.cognitive,
        .lines = r.sum.lines,
        .nesting = r.sum.nesting,
        .text = try arena.dupe(u8, lineText(tree.source, tree.tokenStart(r.first))),
    };
    return out;
}

/// The line the byte at `offset` is on, without its indentation or its
/// line break.
fn lineText(source: []const u8, offset: usize) []const u8 {
    const start = if (std.mem.findScalarLast(u8, source[0..offset], '\n')) |nl| nl + 1 else 0;
    const end = std.mem.findScalarPos(u8, source, offset, '\n') orelse source.len;
    return std.mem.trim(u8, source[start..end], " \t\r");
}

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
    /// The file's; the function is held to its own, as
    /// `Class.forFunction` gives it.
    file_class: Class,
    classes: thresholds.Classes,
) Allocator.Error!Explanation {
    const class: Class = .forFunction(file_class, function.kind == .@"test");
    const limits = classes.get(class);
    var raw_branches: std.ArrayList(cyclomatic.Branch) = .empty;
    const cc = try cyclomatic.explain(scratch, tree, function.node, &raw_branches);
    const branches = try arena.alloc(Branch, raw_branches.items.len);
    for (raw_branches.items, branches) |b, *out| {
        const loc = index.ofToken(tree, b.token);
        out.* = .{ .line = loc.line, .column = loc.column, .construct = try arena.dupe(u8, b.construct), .adds = b.adds, .why = b.why };
    }

    var raw_costs: std.ArrayList(cognitive.Cost) = .empty;
    const cog = try cognitive.explain(scratch, tree, function.node, &raw_costs);
    const costs = try arena.alloc(Cost, raw_costs.items.len);
    for (raw_costs.items, costs) |c, *out| {
        const loc = index.ofToken(tree, c.token);
        out.* = .{ .line = loc.line, .column = loc.column, .construct = try arena.dupe(u8, c.construct), .adds = c.adds, .depth = c.depth, .why = c.why };
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
        .cognitive = .{ .value = cog, .costs = costs },
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
        .regions = try regionsOf(arena, scratch, tree, index, function.node),
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
        .cognitive => e.cognitive.value,
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
    /// names. `class` is the file's; each function is held to its own, as
    /// `Class.forFunction` gives it.
    pub fn file(s: *Search, arena: Allocator, scratch: Allocator, path: []const u8, tree: *const Ast, class: Class, classes: thresholds.Classes) Allocator.Error!void {
        const r: Reading = .{
            .arena = arena,
            .scratch = scratch,
            .tree = tree,
            .index = try LineIndex.init(scratch, tree.source),
            .path = path,
            .class = class,
            .classes = classes,
            .listed = try functions.list(scratch, tree),
        };
        for (s.selectors, s.found) |selector, *found| switch (selector) {
            .at => |at| {
                if (!std.mem.eql(u8, at.path, path)) continue;
                found.read = true;
                const hit = r.around(at) orelse continue;
                var e = try r.explain(hit.function);
                if (at.last) |last| e.range = try r.range(hit.function, e, at.line, last);
                try (if (hit.exact) &found.exact else &found.partial).append(arena, e);
            },
            .name => |name| for (r.listed) |function| {
                const match = select.matchName(function.name, name);
                if (match == .none) continue;
                try (if (match == .exact) &found.exact else &found.partial).append(arena, try r.explain(function));
            },
        };
    }

    /// The one explanation each selector found, in selector order. Says in
    /// `said` why a selector found none, or more than one, and which longer
    /// names a whole name passed over.
    pub fn results(s: Search, arena: Allocator, said: *Messages) Allocator.Error!struct { explanations: []const Explanation, all_found: bool } {
        var out: std.ArrayList(Explanation) = .empty;
        var all_found = true;
        for (s.selectors, s.found, s.texts) |selector, found, text| {
            const matches = if (found.exact.items.len > 0) found.exact.items else found.partial.items;
            if (matches.len == 1) {
                try out.append(arena, matches[0]);
                // A whole name wins, but say which longer ones it hid.
                if (selector == .name and found.exact.items.len == 1 and found.partial.items.len > 0) {
                    const n = found.partial.items.len;
                    try said.add(.{
                        .level = .note,
                        .path = text,
                        .text = try std.fmt.allocPrint(arena, "explained the function of exactly that name; {d} more end{s} with it:", .{ n, if (n == 1) "s" else "" }),
                        .more = try places(arena, found.partial.items),
                    });
                }
                continue;
            }
            all_found = false;
            if (matches.len == 0) {
                switch (selector) {
                    // A file that could not be read has been said already.
                    .at => |at| if (found.read) try said.add(.{ .level = .@"error", .path = at.path, .line = at.line, .text = at.missing() }),
                    .name => try said.fail(text, "no function by that name in the files read", .{}),
                }
                continue;
            }
            try said.add(.{
                .level = .@"error",
                .path = text,
                .text = try std.fmt.allocPrint(arena, "{d} functions answer to that name; name one by path:line:", .{matches.len}),
                .more = try places(arena, matches),
            });
        }
        return .{ .explanations = out.items, .all_found = all_found };
    }
};

/// `path:line  name` for each of `explanations`.
fn places(arena: Allocator, explanations: []const Explanation) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, explanations.len);
    for (explanations, out) |e, *line| line.* = try std.fmt.allocPrint(arena, "{s}:{d}  {s}", .{ e.path, e.line, e.name });
    return out;
}

/// What an explanation document says besides the explanations.
pub const Context = struct {
    /// gnarl's own version.
    version: []const u8,
    /// Everything said on stderr, for the documents that carry it.
    messages: []const Message = &.{},
};

/// A file being read for the selectors that name its functions.
const Reading = struct {
    arena: Allocator,
    scratch: Allocator,
    tree: *const Ast,
    index: LineIndex,
    path: []const u8,
    /// The file's; each function is held to its own.
    class: Class,
    classes: thresholds.Classes,
    listed: []const functions.Function,

    fn explain(r: Reading, function: functions.Function) Allocator.Error!Explanation {
        return build(r.arena, r.scratch, r.tree, r.index, r.path, function, r.class, r.classes);
    }

    /// The function `at` names: the one whose line it is, or the innermost
    /// around it (for a range, around all of it).
    fn around(r: Reading, at: Selector.At) ?struct { function: functions.Function, exact: bool } {
        const last_line = at.last orelse at.line;
        var best: ?functions.Function = null;
        var best_span: u32 = std.math.maxInt(u32);
        for (r.listed) |function| {
            if (at.last == null and function.line == at.line) return .{ .function = function, .exact = true };
            const first = r.index.ofToken(r.tree, r.tree.firstToken(function.node)).line;
            const last = r.index.ofToken(r.tree, r.tree.lastToken(function.node)).line;
            if (first <= at.line and last_line <= last and last - first < best_span) {
                best = function;
                best_span = last - first;
            }
        }
        return .{ .function = best orelse return null, .exact = false };
    }

    /// What lines `first_line` to `last_line` of `function`, explained as
    /// `e`, add, and about what moving them out would leave.
    fn range(r: Reading, function: functions.Function, e: Explanation, first_line: u32, last_line: u32) Allocator.Error!Range {
        const facts: regions.Facts = try .of(r.scratch, r.tree, function.node);
        const sum: regions.Sum = if (r.tokensOn(function, first_line, last_line)) |span| .of(facts, span[0], span[1]) else .{};
        return .{
            .first_line = first_line,
            .last_line = last_line,
            .cyclomatic = sum.cyclomatic,
            .cognitive = sum.cognitive,
            .depth = sum.depth,
            .lines = sum.lines,
            .nesting = sum.nesting,
            .extracted = .of(sum, .{ .cyclomatic = e.cyclomatic.value, .cognitive = e.cognitive.value, .lines = e.lines.value }),
        };
    }

    /// The first and last of `function`'s tokens on those lines; null when
    /// none is.
    fn tokensOn(r: Reading, function: functions.Function, first_line: u32, last_line: u32) ?[2]Ast.TokenIndex {
        var span: ?[2]Ast.TokenIndex = null;
        var t = r.tree.firstToken(function.node);
        while (t <= r.tree.lastToken(function.node)) : (t += 1) {
            const line = r.index.ofToken(r.tree, t).line;
            if (line > last_line) break;
            if (line < first_line) continue;
            // Read before writing: `span = .{ span..., t }` would see the
            // half-written result.
            const start = if (span) |s| s[0] else t;
            span = .{ start, t };
        }
        return span;
    }
};

/// Writes `explanations` in `format`.
pub fn write(w: *Writer, format: report.Format, explanations: []const Explanation, context: Context) Writer.Error!void {
    switch (format) {
        .text => for (explanations, 0..) |e, i| {
            if (i > 0) try w.writeByte('\n');
            try writeText(w, e);
        },
        .md => for (explanations, 0..) |e, i| {
            if (i > 0) try w.writeByte('\n');
            try writeMarkdown(w, e);
        },
        .json => try writeJson(w, explanations, context),
        .xml => try writeXml(w, explanations, context),
        .csv => try writeDelimited(w, .csv, explanations),
        .tsv => try writeDelimited(w, .tsv, explanations),
    }
}

/// One document, compact, an explanation to a line, as the report's.
fn writeJson(w: *Writer, explanations: []const Explanation, c: Context) Writer.Error!void {
    try w.print("{{\"schema\":{d},\"gnarl\":", .{report.schema});
    try std.json.Stringify.value(c.version, .{}, w);
    try messages.writeJson(w, c.messages);
    try w.writeAll(",\"explanations\":[");
    for (explanations, 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try std.json.Stringify.value(e, .{}, w);
    }
    try w.writeAll(if (explanations.len > 0) "\n]}\n" else "]}\n");
}

/// The json document's fields as elements and attributes.
fn writeXml(w: *Writer, explanations: []const Explanation, c: Context) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gnarl");
    try formats.attrInt(w, "schema", report.schema);
    try formats.attr(w, "version", c.version);
    try w.writeAll(">\n");
    try messages.writeXml(w, c.messages);
    try w.writeAll("  <explanations>\n");
    for (explanations) |e| {
        try w.writeAll("    <explanation");
        try formats.attr(w, "path", e.path);
        try formats.attrInt(w, "line", e.line);
        try formats.attrInt(w, "column", e.column);
        try formats.attr(w, "name", e.name);
        try formats.attr(w, "kind", @tagName(e.kind));
        try formats.attr(w, "class", @tagName(e.class));
        try w.writeAll(">\n");
        for (e.trips) |trip| {
            try w.writeAll("      <trip");
            try formats.attr(w, "metric", @tagName(trip.metric));
            try formats.attr(w, "level", @tagName(trip.level));
            try formats.attrInt(w, "limit", trip.limit);
            try w.writeAll("/>\n");
        }
        try w.print("      <cyclomatic value=\"{d}\">\n", .{e.cyclomatic.value});
        for (e.cyclomatic.branches) |b| {
            try w.writeAll("        <branch");
            try formats.attrInt(w, "line", b.line);
            try formats.attrInt(w, "column", b.column);
            try formats.attr(w, "construct", b.construct);
            try formats.attrInt(w, "adds", b.adds);
            try formats.attr(w, "why", b.why);
            try w.writeAll("/>\n");
        }
        try w.writeAll("      </cyclomatic>\n");
        try writeCognitiveXml(w, e);
        try w.print("      <nesting value=\"{d}\">\n", .{e.nesting.value});
        for (e.nesting.chain) |l| {
            try w.writeAll("        <level");
            try formats.attrInt(w, "line", l.line);
            try formats.attrInt(w, "column", l.column);
            try formats.attr(w, "construct", l.construct);
            try formats.attrInt(w, "level", l.level);
            try w.writeAll("/>\n");
        }
        try w.writeAll("      </nesting>\n      <lines");
        inline for (.{ "value", "span", "blank", "comment", "closer", "nested" }) |field| try formats.attrInt(w, field, @field(e.lines, field));
        try w.print("/>\n      <params value=\"{d}\" weighted=\"{d}\">\n", .{ e.params.value, e.params.weighted });
        for (e.params.each) |p| {
            try w.writeAll("        <param");
            try formats.attr(w, "name", p.name);
            try formats.attr(w, "type", p.type);
            try formats.attrInt(w, "weight", p.weight);
            try formats.attr(w, "why", p.why);
            try w.writeAll("/>\n");
        }
        try w.writeAll("      </params>\n");
        try writeRegionsXml(w, e);
        try w.writeAll("    </explanation>\n");
    }
    try w.writeAll("  </explanations>\n</gnarl>\n");
}

fn writeCognitiveXml(w: *Writer, e: Explanation) Writer.Error!void {
    try w.print("      <cognitive value=\"{d}\">\n", .{e.cognitive.value});
    for (e.cognitive.costs) |cost| {
        try w.writeAll("        <cost");
        try formats.attrInt(w, "line", cost.line);
        try formats.attrInt(w, "column", cost.column);
        try formats.attr(w, "construct", cost.construct);
        try formats.attrInt(w, "adds", cost.adds);
        try formats.attrInt(w, "depth", cost.depth);
        try formats.attr(w, "why", cost.why);
        try w.writeAll("/>\n");
    }
    try w.writeAll("      </cognitive>\n");
}

pub const delimited_columns = [_][]const u8{ "path", "line", "name", "metric", "item", "at", "value", "why" };

/// A header row, then a row per item: for each metric its total, then
/// what makes it, so a metric's rows other than `total` add up to it
/// (`base` 1 for cyclomatic; the line kinds for lines, `span` aside). A
/// cognitive cost's `why` says how much of it is for its depth.
fn writeDelimited(w: *Writer, kind: formats.Delimited, explanations: []const Explanation) Writer.Error!void {
    try formats.header(w, kind, &delimited_columns);
    for (explanations) |e| {
        const row: Item = .{ .w = w, .kind = kind, .e = e };
        try row.put("cyclomatic", "total", "", e.cyclomatic.value, "");
        try row.put("cyclomatic", "base", "", 1, "");
        for (e.cyclomatic.branches) |b| try row.putAt("cyclomatic", b.construct, b.line, b.column, b.adds, b.why);
        try row.put("cognitive", "total", "", e.cognitive.value, "");
        for (e.cognitive.costs) |c| {
            var buffer: [256]u8 = undefined;
            var why: Writer = .fixed(&buffer);
            writeReason(&why, c) catch {};
            try row.putAt("cognitive", c.construct, c.line, c.column, c.adds, why.buffered());
        }
        try row.put("nesting", "total", "", e.nesting.value, "");
        for (e.nesting.chain) |l| try row.putAt("nesting", l.construct, l.line, l.column, l.level, "");
        try row.put("lines", "total", "", e.lines.value, "");
        inline for (.{ "span", "blank", "comment", "closer", "nested" }) |field| try row.put("lines", field, "", @field(e.lines, field), "");
        try row.put("params", "total", "", e.params.value, "");
        try row.put("params", "weighted", "", e.params.weighted, "");
        for (e.params.each) |p| {
            var buffer: [512]u8 = undefined;
            const item = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ p.name, p.type }) catch p.name;
            try row.put("params", item, "", p.weight, p.why);
        }
        try putRegions(row, e);
    }
}

/// A region's rows, a metric each, `at` its lines and `why` its first
/// line; and a range's.
fn putRegions(row: Item, e: Explanation) Writer.Error!void {
    var buffer: [24]u8 = undefined;
    for (e.regions) |r| {
        const at = std.fmt.bufPrint(&buffer, "{d}-{d}", .{ r.first_line, r.last_line }) catch unreachable;
        inline for (.{ "cyclomatic", "cognitive", "lines", "nesting" }) |field| try row.put("region", field, at, @field(r, field), r.text);
    }
    const range = e.range orelse return;
    const at = std.fmt.bufPrint(&buffer, "{d}-{d}", .{ range.first_line, range.last_line }) catch unreachable;
    inline for (.{ "cyclomatic", "cognitive", "depth", "lines", "nesting" }) |field| try row.put("range", field, at, @field(range, field), "");
    inline for (.{ "cyclomatic", "cognitive", "nesting" }) |field| try row.put("range", "helper." ++ field, at, @field(range.extracted.helper, field), "");
    inline for (.{ "cyclomatic", "cognitive", "lines" }) |field| try row.put("range", "rest." ++ field, at, @field(range.extracted.rest, field), "");
}

/// The `<regions>` element, and `<range>` when lines were asked about.
fn writeRegionsXml(w: *Writer, e: Explanation) Writer.Error!void {
    try w.writeAll("      <regions>\n");
    for (e.regions) |r| {
        try w.writeAll("        <region");
        inline for (.{ "first_line", "last_line", "statements", "cyclomatic", "cognitive", "lines", "nesting" }) |field| try formats.attrInt(w, field, @field(r, field));
        try formats.attr(w, "text", r.text);
        try w.writeAll("/>\n");
    }
    try w.writeAll("      </regions>\n");
    const range = e.range orelse return;
    try w.writeAll("      <range");
    inline for (.{ "first_line", "last_line", "cyclomatic", "cognitive", "depth", "lines", "nesting" }) |field| try formats.attrInt(w, field, @field(range, field));
    try w.writeAll(">\n        <extracted>\n          <helper");
    inline for (.{ "cyclomatic", "cognitive", "nesting" }) |field| try formats.attrInt(w, field, @field(range.extracted.helper, field));
    try w.writeAll("/>\n          <rest");
    inline for (.{ "cyclomatic", "cognitive", "lines" }) |field| try formats.attrInt(w, field, @field(range.extracted.rest, field));
    try w.writeAll("/>\n        </extracted>\n      </range>\n");
}

/// The regions as a report lists them: each that adds something, and
/// each run of statements between those that adds nothing, as one.
const RegionRows = struct {
    all: []const Region,
    i: usize = 0,

    fn next(it: *RegionRows) ?Region {
        if (it.i >= it.all.len) return null;
        var row = it.all[it.i];
        it.i += 1;
        if (!idle(row)) return row;
        while (it.i < it.all.len and idle(it.all[it.i])) : (it.i += 1) {
            const more = it.all[it.i];
            row.last_line = more.last_line;
            row.statements += more.statements;
            row.lines += more.lines;
            row.nesting = @max(row.nesting, more.nesting);
        }
        return row;
    }

    fn idle(r: Region) bool {
        return r.statements > 0 and r.cyclomatic == 0 and r.cognitive == 0;
    }

    /// Whether there is anything to compare: two regions that add.
    fn worthListing(all: []const Region) bool {
        var n: usize = 0;
        for (all) |r| n += @intFromBool(r.cyclomatic > 0 or r.cognitive > 0);
        return n >= 2;
    }
};

/// A region's lines, as `12` or `12-30`.
fn lineSpan(buffer: []u8, r: Region) []const u8 {
    if (r.first_line == r.last_line) return std.fmt.bufPrint(buffer, "{d}", .{r.first_line}) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}-{d}", .{ r.first_line, r.last_line }) catch unreachable;
}

/// A region's first line, cut to a width a table row can carry.
fn shortText(text: []const u8) struct { []const u8, []const u8 } {
    if (text.len <= 60) return .{ text, "" };
    var cut: usize = 57;
    while (cut > 0 and text[cut] & 0xC0 == 0x80) cut -= 1;
    return .{ text[0..cut], "..." };
}

fn writeRegionsText(w: *Writer, all: []const Region) Writer.Error!void {
    if (!RegionRows.worthListing(all)) return;
    var buffer: [24]u8 = undefined;
    const width = @max("lines".len, lineSpan(&buffer, .{ .first_line = all[all.len - 1].last_line, .last_line = all[all.len - 1].last_line + 1, .statements = 0, .cyclomatic = 0, .cognitive = 0, .lines = 0, .nesting = 0, .text = "" }).len);
    try w.writeAll("regions: the signature and the body's statements, what each adds\n  lines");
    try w.splatByteAll(' ', width - "lines".len + 2);
    try w.writeAll("cyclomatic  cognitive  logical  deepest\n");
    var rows: RegionRows = .{ .all = all };
    while (rows.next()) |r| {
        const at = lineSpan(&buffer, r);
        try w.print("  {s}", .{at});
        try w.splatByteAll(' ', width - at.len + 2);
        try writePadded(w, "+{d}", r.cyclomatic, "cyclomatic".len + 2);
        try writePadded(w, "+{d}", r.cognitive, "cognitive".len + 2);
        try writePadded(w, "{d}", r.lines, "logical".len + 2);
        try writePadded(w, "{d}", r.nesting, "deepest".len + 2);
        const text, const more = shortText(r.text);
        try w.print("{s}{s}", .{ text, more });
        if (r.statements > 1) try w.print("  ({d} statements)", .{r.statements});
        try w.writeByte('\n');
    }
}

fn writePadded(w: *Writer, comptime format: []const u8, n: u32, width: usize) Writer.Error!void {
    try w.print(format, .{n});
    try w.splatByteAll(' ', width -| std.fmt.count(format, .{n}));
}

fn writeRegionsMarkdown(w: *Writer, all: []const Region) Writer.Error!void {
    if (!RegionRows.worthListing(all)) return;
    try w.writeAll("\n**regions**: the signature and the body's statements, what each adds.\n\n| lines | cyclomatic | cognitive | logical | deepest | starts |\n| --- | ---: | ---: | ---: | ---: | --- |\n");
    var buffer: [24]u8 = undefined;
    var rows: RegionRows = .{ .all = all };
    while (rows.next()) |r| {
        const text, const more = shortText(r.text);
        try w.print("| {s} | {d} | {d} | {d} | {d} | `{s}{s}`", .{ lineSpan(&buffer, r), r.cyclomatic, r.cognitive, r.lines, r.nesting, text, more });
        if (r.statements > 1) try w.print(" ({d} statements)", .{r.statements});
        try w.writeAll(" |\n");
    }
}

fn writeRangeMarkdown(w: *Writer, e: Explanation, r: Range) Writer.Error!void {
    try w.print("**lines {d}-{d}**: cyclomatic +{d}, cognitive +{d} ({d} of it for depth), {d} logical lines, the deepest level {d}.\n\n", .{ r.first_line, r.last_line, r.cyclomatic, r.cognitive, r.depth, r.lines, r.nesting });
    const x = r.extracted;
    try w.print("Moved into a function of its own, about: that function cyclomatic {d}, cognitive {d}, nesting {d}; `{s}` keeps cyclomatic {d}, cognitive {d}, lines {d}. A return, break or continue that leaves those lines is not accounted for.\n", .{ x.helper.cyclomatic, x.helper.cognitive, x.helper.nesting, e.name, x.rest.cyclomatic, x.rest.cognitive, x.rest.lines });
}

/// What lines asked about cost, and about what moving them out would
/// leave; in place of the whole explanation.
fn writeRangeText(w: *Writer, e: Explanation, r: Range) Writer.Error!void {
    try w.print("lines {d}-{d}: cyclomatic +{d}, cognitive +{d} ({d} of it for depth), {d} logical lines, the deepest level {d}\n", .{ r.first_line, r.last_line, r.cyclomatic, r.cognitive, r.depth, r.lines, r.nesting });
    const x = r.extracted;
    try w.print("moved into a function of its own, about: that function cyclomatic {d}, cognitive {d}, nesting {d}; {s} keeps cyclomatic {d}, cognitive {d}, lines {d}\n", .{ x.helper.cyclomatic, x.helper.cognitive, x.helper.nesting, e.name, x.rest.cyclomatic, x.rest.cognitive, x.rest.lines });
    try w.writeAll("a return, break or continue that leaves those lines is not accounted for\n");
}

/// Writes `explanations` in `format`.
const Item = struct {
    w: *Writer,
    kind: formats.Delimited,
    e: Explanation,

    fn put(r: Item, metric: []const u8, item: []const u8, at: []const u8, value: u32, why: []const u8) Writer.Error!void {
        try formats.field(r.w, r.kind, true, r.e.path);
        try formats.fieldInt(r.w, r.kind, false, r.e.line);
        try formats.field(r.w, r.kind, false, r.e.name);
        try formats.field(r.w, r.kind, false, metric);
        try formats.field(r.w, r.kind, false, item);
        try formats.field(r.w, r.kind, false, at);
        try formats.fieldInt(r.w, r.kind, false, value);
        try formats.field(r.w, r.kind, false, why);
        try r.w.writeByte('\n');
    }

    fn putAt(r: Item, metric: []const u8, item: []const u8, line: u32, column: u32, value: u32, why: []const u8) Writer.Error!void {
        var buffer: [24]u8 = undefined;
        try r.put(metric, item, std.fmt.bufPrint(&buffer, "{d}:{d}", .{ line, column }) catch unreachable, value, why);
    }
};

/// `, over the warning limit (10)` for a metric over one, else nothing.
fn writeOver(w: *Writer, e: Explanation, metric: Metric) Writer.Error!void {
    for (e.trips) |trip| if (trip.metric == metric) {
        try w.print(", over the {t} limit ({d})", .{ trip.level, trip.limit });
    };
}

/// How wide the place and construct columns of the text are: as wide as
/// the widest row any section lists.
const Widths = struct {
    at: usize = 0,
    construct: usize = 0,

    fn of(e: Explanation) Widths {
        var ws: Widths = .{};
        for (e.cyclomatic.branches) |b| if (b.adds > 0) ws.fit(b.line, b.column, b.construct);
        for (e.cognitive.costs) |c| if (c.adds > 0) ws.fit(c.line, c.column, c.construct);
        for (e.nesting.chain) |l| ws.fit(l.line, l.column, l.construct);
        return ws;
    }

    fn fit(ws: *Widths, line: u32, column: u32, construct: []const u8) void {
        ws.at = @max(ws.at, std.fmt.count("{d}:{d}", .{ line, column }));
        ws.construct = @max(ws.construct, construct.len);
    }

    /// A row's place and construct, padded to the columns.
    fn writeRow(ws: Widths, w: *Writer, line: u32, column: u32, construct: []const u8) Writer.Error!void {
        try writeAt(w, line, column, ws.at);
        try w.print("{s}", .{construct});
        try w.splatByteAll(' ', ws.construct - construct.len + 2);
    }
};

fn writeText(w: *Writer, e: Explanation) Writer.Error!void {
    try w.print("{s}:{d}  {s}  ({s})\n\n", .{ e.path, e.line, e.name, e.class.text() });
    if (e.range) |r| return writeRangeText(w, e, r);
    const ws: Widths = .of(e);

    try w.print("cyclomatic {d}", .{e.cyclomatic.value});
    try writeOver(w, e, .cyclomatic);
    try w.writeAll(if (adding(e.cyclomatic.branches) > 0) ": 1, and 1 for each of these\n" else ": 1, nothing branches\n");
    for (e.cyclomatic.branches) |b| if (b.adds > 0) {
        try ws.writeRow(w, b.line, b.column, b.construct);
        try w.print("+{d}\n", .{b.adds});
    };
    try writeNotCounted(w, e.cyclomatic.branches, .text);

    try writeCognitiveText(w, e, ws);

    try w.print("nesting {d}", .{e.nesting.value});
    try writeOver(w, e, .nesting);
    try w.writeAll(if (e.nesting.chain.len > 0) ": the deepest chain\n" else ": no construct opens a level\n");
    for (e.nesting.chain) |l| {
        try ws.writeRow(w, l.line, l.column, l.construct);
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
    try writeRegionsText(w, e.regions);
}

fn writeCognitiveText(w: *Writer, e: Explanation, ws: Widths) Writer.Error!void {
    try w.print("cognitive {d}", .{e.cognitive.value});
    try writeOver(w, e, .cognitive);
    try w.writeAll(if (adding(e.cognitive.costs) > 0) ": the sum of these\n" else ": nothing costs\n");
    for (e.cognitive.costs) |c| if (c.adds > 0) {
        try ws.writeRow(w, c.line, c.column, c.construct);
        try w.print("+{d}", .{c.adds});
        if (c.depth > 0 or c.why.len > 0) try w.writeAll("  ");
        try writeReason(w, c);
        try w.writeByte('\n');
    };
    try writeNotCounted(w, e.cognitive.costs, .text);
}

/// How much of a cognitive cost is for its depth, and why it costs what it
/// does, when its kind does not say.
fn writeReason(w: *Writer, c: Cost) Writer.Error!void {
    if (c.depth > 0) try w.print("{d} for its depth", .{c.depth});
    if (c.depth > 0 and c.why.len > 0) try w.writeAll("; ");
    try w.writeAll(c.why);
}

/// How many of the constructs listed (branches or costs) add something.
fn adding(items: anytype) usize {
    var n: usize = 0;
    for (items) |item| n += @intFromBool(item.adds > 0);
    return n;
}

/// For each kind of construct that adds nothing, one line: where each one
/// is, and why. `branches` are a metric's branches or costs.
fn writeNotCounted(w: *Writer, branches: anytype, format: enum { text, md }) Writer.Error!void {
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

fn sameKind(a: anytype, b: @TypeOf(a)) bool {
    return a.adds == 0 and b.adds == 0 and std.mem.eql(u8, a.construct, b.construct) and std.mem.eql(u8, a.why, b.why);
}

fn writeAt(w: *Writer, line: u32, column: u32, width: usize) Writer.Error!void {
    try w.print("  {d}:{d}", .{ line, column });
    try w.splatByteAll(' ', width - std.fmt.count("{d}:{d}", .{ line, column }) + 2);
}

fn writeMarkdown(w: *Writer, e: Explanation) Writer.Error!void {
    try w.print("### `{s}` at `{s}:{d}` ({s})\n\n", .{ e.name, e.path, e.line, e.class.text() });
    if (e.range) |r| return writeRangeMarkdown(w, e, r);

    try w.print("**cyclomatic {d}**", .{e.cyclomatic.value});
    try writeOver(w, e, .cyclomatic);
    if (adding(e.cyclomatic.branches) == 0) {
        try w.writeAll(": 1, nothing branches.\n");
    } else {
        try w.writeAll(": 1, and 1 for each of these.\n\n| at | construct |\n| --- | --- |\n");
        for (e.cyclomatic.branches) |b| if (b.adds > 0) try w.print("| {d}:{d} | `{s}` |\n", .{ b.line, b.column, b.construct });
    }
    try writeNotCounted(w, e.cyclomatic.branches, .md);
    try writeCognitiveMarkdown(w, e);

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
    try writeRegionsMarkdown(w, e.regions);
}

fn writeCognitiveMarkdown(w: *Writer, e: Explanation) Writer.Error!void {
    try w.print("\n**cognitive {d}**", .{e.cognitive.value});
    try writeOver(w, e, .cognitive);
    if (adding(e.cognitive.costs) == 0) {
        try w.writeAll(": nothing costs.\n");
    } else {
        try w.writeAll(": the sum of these.\n\n| at | construct | adds | why |\n| --- | --- | ---: | --- |\n");
        for (e.cognitive.costs) |c| if (c.adds > 0) {
            try w.print("| {d}:{d} | `{s}` | {d} | ", .{ c.line, c.column, c.construct, c.adds });
            try writeReason(w, c);
            try w.writeAll(" |\n");
        };
    }
    try writeNotCounted(w, e.cognitive.costs, .md);
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
    try search.file(arena, arena, "a.zig", &tree, .normal, .defaults);
    var said: Messages = .{ .arena = arena, .echo = false };
    const r = try search.results(arena, &said);
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
    // if 1, and 1, for 2, if 3, the return in the loop 1.
    try std.testing.expectEqual(8, e.cognitive.value);
    var cost: u32 = 0;
    for (e.cognitive.costs) |c| cost += c.adds;
    try std.testing.expectEqual(e.cognitive.value, cost);
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
    try write(&out.writer, .text, (try explainSample(arena, &.{"pick"})).explanations, .{ .version = "0.0.0" });
    try std.testing.expectEqualStrings(
        \\a.zig:2  S.pick  (normal code)
        \\
        \\cyclomatic 5: 1, and 1 for each of these
        \\  3:9   if      +1
        \\  3:19  and     +1
        \\  4:13  for     +1
        \\  6:17  if      +1
        \\  try at 9:16 adds nothing: a try passes an error on; it is not a branch
        \\cognitive 8: the sum of these
        \\  3:9   if      +1
        \\  3:19  and     +1
        \\  4:13  for     +2  1 for its depth
        \\  6:17  if      +3  2 for its depth
        \\  6:31  return  +1  inside a loop: it ends the loop too
        \\nesting 3: the deepest chain
        \\  3:9   if       1
        \\  4:13  for      2
        \\  6:17  if       3
        \\lines 5 of the 9 from signature to closing brace; not counted: 0 blank, 1 comment, 3 closing, 0 in nested functions
        \\params 1, weighted 1
        \\  s    *S         0  a leading self
        \\  gpa  Allocator  0  an Allocator: context, not input
        \\  x    u8         1
        \\
    , out.written());
}

test "a range: what its lines add, and about what moving them out would leave" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The for in S.pick, lines 4 to 7.
    const r = try explainSample(arena, &.{"a.zig:4-7"});
    try std.testing.expect(r.all_found);
    try std.testing.expectEqualStrings("S.pick", r.explanations[0].name);
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, .text, r.explanations, .{ .version = "0.0.0" });
    // for one level in 2, if two 3, the return in the loop 1; lifted out,
    // both a level shallower: for 1, if 2, the return 1.
    try std.testing.expectEqualStrings(
        \\a.zig:2  S.pick  (normal code)
        \\
        \\lines 4-7: cyclomatic +2, cognitive +6 (3 of it for depth), 2 logical lines, the deepest level 3
        \\moved into a function of its own, about: that function cyclomatic 3, cognitive 4, nesting 2; S.pick keeps cyclomatic 3, cognitive 2, lines 4
        \\a return, break or continue that leaves those lines is not accounted for
        \\
    , out.written());
}

test "regions: each that adds a row, the runs between that add nothing one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa,
        \\fn f(xs: []const u8, c: bool) u8 {
        \\    const n = xs.len;
        \\    var m: usize = 0;
        \\    for (xs) |x| {
        \\        if (x == 0) m += 1;
        \\    }
        \\    if (c and n > m) return 1;
        \\    return 0;
        \\}
    , .{});
    defer tree.deinit(gpa);
    var search: Search = try .init(arena, &.{"f"});
    try search.file(arena, arena, "a.zig", &tree, .normal, .defaults);
    var said: Messages = .{ .arena = arena, .echo = false };
    const found = try search.results(arena, &said);
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, .text, found.explanations, .{ .version = "0.0.0" });
    const text = out.written();
    try std.testing.expectEqualStrings(
        \\regions: the signature and the body's statements, what each adds
        \\  lines  cyclomatic  cognitive  logical  deepest
        \\  1      +0          +0         1        0        fn f(xs: []const u8, c: bool) u8 {
        \\  2-3    +0          +0         2        0        const n = xs.len;  (2 statements)
        \\  4-6    +2          +3         2        2        for (xs) |x| {
        \\  7      +2          +2         1        1        if (c and n > m) return 1;
        \\  8      +0          +0         1        0        return 0;
        \\
    , text[std.mem.find(u8, text, "regions:").?..]);
}

test "write: Markdown and JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const explanations = (try explainSample(arena, &.{"other"})).explanations;
    var md: Writer.Allocating = .init(arena);
    try write(&md.writer, .md, explanations, .{ .version = "0.0.0" });
    try std.testing.expectEqualStrings(
        \\### `other` at `a.zig:12` (normal code)
        \\
        \\**cyclomatic 1**: 1, nothing branches.
        \\
        \\**cognitive 0**: nothing costs.
        \\
        \\**nesting 0**: no construct opens a level.
        \\
        \\**lines 1** of the 1 from signature to closing brace; not counted: 0 blank, 0 comment, 0 closing, 0 in nested functions.
        \\
        \\**params 0**, weighted 0: none.
        \\
    , md.written());

    var json: Writer.Allocating = .init(arena);
    const said = [_]Message{.{ .level = .@"error", .path = "nope", .text = "no function by that name in the files read" }};
    try write(&json.writer, .json, (try explainSample(arena, &.{"pick"})).explanations, .{ .version = "0.0.0", .messages = &said });
    const JsonMessage = struct { path: []const u8, line: ?u32, column: ?u32, text: []const u8, more: []const []const u8 };
    const Doc = struct { schema: u32, gnarl: []const u8, errors: []const JsonMessage, notes: []const JsonMessage, explanations: []const Explanation };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, json.written(), .{});
    try std.testing.expectEqual(report.schema, doc.schema);
    try std.testing.expectEqualStrings("nope", doc.errors[0].path);
    try std.testing.expectEqual(0, doc.notes.len);
    try std.testing.expectEqualStrings("S.pick", doc.explanations[0].name);
    try std.testing.expectEqual(5, doc.explanations[0].cyclomatic.branches.len);
    try std.testing.expectEqualStrings("a leading self", doc.explanations[0].params.each[0].why);
}

test "write: xml, csv and tsv say what json does" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const explanations = (try explainSample(arena, &.{"pick"})).explanations;

    var xml: Writer.Allocating = .init(arena);
    try write(&xml.writer, .xml, explanations, .{ .version = "0.0.0" });
    const doc = try formats.readXml(arena, xml.written());
    const e = doc.child("explanations").?.children[0];
    try std.testing.expectEqualStrings("S.pick", e.get("name").?);
    try std.testing.expectEqualStrings("5", e.child("cyclomatic").?.get("value").?);
    try std.testing.expectEqual(5, e.child("cyclomatic").?.children.len);
    try std.testing.expectEqualStrings("8", e.child("cognitive").?.get("value").?);
    try std.testing.expectEqualStrings("2", e.child("cognitive").?.children[3].get("depth").?);
    try std.testing.expectEqualStrings("3", e.child("nesting").?.children[2].get("level").?);
    try std.testing.expectEqualStrings("9", e.child("lines").?.get("span").?);
    try std.testing.expectEqualStrings("Allocator", e.child("params").?.children[1].get("type").?);

    for ([_]report.Format{ .csv, .tsv }) |format| {
        var out: Writer.Allocating = .init(arena);
        try write(&out.writer, format, explanations, .{ .version = "0.0.0" });
        const table = try formats.readDelimited(arena, if (format == .csv) .csv else .tsv, out.written());
        for (delimited_columns, table[0]) |want, got| try std.testing.expectEqualStrings(want, got);
        // The rows say what the totals are made of: cyclomatic's items add
        // up to it, nesting's deepest level is it, and params counts the
        // parameters that weigh anything.
        const metrics = [_][]const u8{ "cyclomatic", "nesting", "lines", "params", "cognitive", "region", "range" };
        var totals: [metrics.len]u32 = @splat(0);
        var cyclomatic_sum: u32 = 0;
        var cognitive_sum: u32 = 0;
        var deepest: u32 = 0;
        var counted: u32 = 0;
        for (table[1..]) |row| {
            const m = for (metrics, 0..) |name, i| {
                if (std.mem.eql(u8, row[3], name)) break i;
            } else return error.UnknownMetric;
            const value = try std.fmt.parseInt(u32, row[6], 10);
            if (std.mem.eql(u8, row[4], "total")) {
                totals[m] = value;
                continue;
            }
            switch (m) {
                0 => cyclomatic_sum += value,
                4 => cognitive_sum += value,
                1 => deepest = @max(deepest, value),
                3 => if (!std.mem.eql(u8, row[4], "weighted")) {
                    counted += @intFromBool(value > 0);
                },
                else => {},
            }
        }
        try std.testing.expectEqual(totals[0], cyclomatic_sum);
        try std.testing.expectEqual(totals[4], cognitive_sum);
        try std.testing.expectEqual(totals[1], deepest);
        try std.testing.expectEqual(totals[3], counted);
        try std.testing.expectEqualStrings("cyclomatic", table[3][3]);
        try std.testing.expectEqualStrings("if", table[3][4]);
        try std.testing.expectEqualStrings("3:9", table[3][5]);
    }
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
            const e = try build(arena, arena, &tree, index, entry.name, function, .normal, .defaults);
            try std.testing.expectEqual(row.cyclomatic, e.cyclomatic.value);
            try std.testing.expectEqual(row.cognitive, e.cognitive.value);
            var cost: u32 = 0;
            for (e.cognitive.costs) |c| cost += c.adds;
            try std.testing.expectEqual(e.cognitive.value, cost);
            // The regions add up to the totals.
            var regions_sum: Region = .{ .first_line = 0, .last_line = 0, .statements = 0, .cyclomatic = 1, .cognitive = 0, .lines = 0, .nesting = 0, .text = "" };
            for (e.regions) |r| {
                regions_sum.cyclomatic += r.cyclomatic;
                regions_sum.cognitive += r.cognitive;
                regions_sum.lines += r.lines;
                regions_sum.nesting = @max(regions_sum.nesting, r.nesting);
            }
            try std.testing.expectEqual(e.cyclomatic.value, regions_sum.cyclomatic);
            try std.testing.expectEqual(e.cognitive.value, regions_sum.cognitive);
            try std.testing.expectEqual(e.lines.value, regions_sum.lines);
            try std.testing.expectEqual(e.nesting.value, regions_sum.nesting);
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

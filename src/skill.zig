//! `gnarl skill`: what an agent needs to work with gnarl, printed by the
//! binary itself, and tested here against what gnarl does: every example
//! in it measures as it says.
//!
//! The guide is printed in parts. An agent reads it as a command's
//! output, and every load costs all of it, though most jobs need the
//! loop and not the reference: what each metric counts, each format's
//! fields, the thresholds. So `gnarl skill` prints the guide up to its
//! first topic, `gnarl skill counts` that topic, and `--all` the whole.
//! skill.md stays one file: a topic is a `## ` heading ending
//! `: gnarl skill <name>` and what follows it, up to the next, and every
//! section from the first topic on is one.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const cognitive = @import("cognitive.zig");
const config = @import("config.zig");
const cyclomatic = @import("cyclomatic.zig");
const functions = @import("functions.zig");
const measure = @import("measure.zig");
const nesting = @import("nesting.zig");
const params = @import("params.zig");
const report = @import("report.zig");
const thresholds = @import("thresholds.zig");

/// The whole guide, frontmatter first: `gnarl skill --all` prints it.
pub const text = @embedFile("skill.md");

/// The frontmatter, from its first `---` line through its last.
const frontmatter = text[0 .. (std.mem.find(u8, text[4..], "\n---\n") orelse @compileError("skill.md: no end to the frontmatter")) + 4 + "\n---\n".len];

/// Where the guide starts after its frontmatter and the blank line under it.
const body_start = std.mem.findNonePos(u8, text, frontmatter.len, "\n") orelse text.len;

/// What a topic's heading ends with, before the topic's name.
const topic_mark = ": gnarl skill ";

/// Where the topics start: the first `## ` heading that names one.
const topics_start = blk: {
    @setEvalBranchQuota(1_000_000);
    var at: usize = body_start;
    while (std.mem.findPos(u8, text, at, "\n## ")) |start| : (at = start + 1) {
        const line_end = std.mem.findScalarPos(u8, text, start + 1, '\n') orelse text.len;
        if (std.mem.find(u8, text[start + 1 .. line_end], topic_mark) != null) break :blk start + 1;
    }
    @compileError("skill.md: no heading ends `: gnarl skill <topic>`");
};

/// What `gnarl skill` prints: the guide after its frontmatter, up to the
/// first topic.
pub const short = text[body_start..topics_start];

/// What `gnarl skill --install` writes: the frontmatter, so an agent knows
/// when to load the skill, and a line handing over to `gnarl skill`, so an
/// installed skill is never older than the gnarl that prints it.
pub const stub = frontmatter ++
    \\
    \\Run `gnarl skill` and follow what it prints: it is the guide to the gnarl installed on this machine, current for its version.
    \\
;

/// A topic's part of the guide: its `## ` heading and what follows it, up
/// to the next.
pub const Topic = struct {
    /// What follows `: gnarl skill ` in the heading; empty when the heading
    /// names no topic, which the tests do not allow.
    name: []const u8,
    text: []const u8,
};

/// The topics, in the guide's order.
pub const Topics = struct {
    at: usize = topics_start,

    pub fn next(it: *Topics) ?Topic {
        if (it.at >= text.len) return null;
        const end = if (std.mem.findPos(u8, text, it.at + 1, "\n## ")) |at| at + 1 else text.len;
        const part = text[it.at..end];
        it.at = end;
        const heading = part[0 .. std.mem.findScalar(u8, part, '\n') orelse part.len];
        const mark = std.mem.find(u8, heading, topic_mark) orelse return .{ .name = "", .text = part };
        return .{ .name = heading[mark + topic_mark.len ..], .text = part };
    }
};

/// The part of the topic named `name`, or null when there is no such topic.
pub fn topicOf(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var it: Topics = .{};
    while (it.next()) |topic| {
        if (std.mem.eql(u8, topic.name, name)) return topic.text;
    }
    return null;
}

/// Every topic's name, in the guide's order, for a message:
/// `counts, output, thresholds`.
pub fn names(arena: Allocator) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it: Topics = .{};
    while (it.next()) |topic| {
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, topic.name);
    }
    return out.items;
}

/// Writes the stub to `dir/gnarl/SKILL.md`, making the directories, and
/// returns the path written.
pub fn install(arena: Allocator, io: Io, dir: []const u8) ![]const u8 {
    const sub = try std.fs.path.join(arena, &.{ dir, "gnarl" });
    try Io.Dir.cwd().createDirPath(io, sub);
    const path = try std.fs.path.join(arena, &.{ sub, "SKILL.md" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = stub });
    return path;
}

const Row = struct {
    /// The table's header row, which says what the numbers are.
    header: []const u8,
    /// The code, unescaped (`\|` is `|`), then the other cells trimmed.
    cells: []const []const u8,
};

/// Each table row under `section` that starts with a code span.
fn tableRows(arena: Allocator, doc: []const u8, section: []const u8) ![]const Row {
    const start = std.mem.find(u8, doc, section) orelse return error.NoSection;
    const end = std.mem.findPos(u8, doc, start + section.len, "\n## ") orelse doc.len;
    var rows: std.ArrayList(Row) = .empty;
    var header: []const u8 = "";
    var lines = std.mem.splitScalar(u8, doc[start..end], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "| Code |")) header = line;
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        const close = std.mem.find(u8, line, "` |") orelse return error.BadRow;
        const code = try std.mem.replaceOwned(u8, arena, line[3..close], "\\|", "|");
        var cells: std.ArrayList([]const u8) = .empty;
        try cells.append(arena, code);
        var rest = std.mem.splitScalar(u8, line[close + 3 ..], '|');
        while (rest.next()) |cell| {
            const trimmed = std.mem.trim(u8, cell, " ");
            if (trimmed.len > 0) try cells.append(arena, trimmed);
        }
        try rows.append(arena, .{ .header = header, .cells = cells.items });
    }
    return rows.items;
}

/// The first function in `source`, parsed with `gpa` into `tree`.
fn firstFunction(arena: Allocator, tree: *const Ast) !functions.Function {
    if (tree.errors.len > 0) return error.ExampleDoesNotParse;
    const listed = try functions.list(arena, tree);
    if (listed.len == 0) return error.NoFunction;
    return listed[0];
}

test "every example in the rules' tables measures as the skill says" {
    try expectRulesMeasure(text);
}

test "the site's metrics page carries the same tables, and they measure as it says" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try expectRulesMeasure(try Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/metrics.md", arena_state.allocator(), .limited(1 << 20)));
}

/// Each example in the tables under `doc`'s "What it counts" measures as
/// its row says.
fn expectRulesMeasure(doc: []const u8) !void {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checked: usize = 0;
    for (try tableRows(arena, doc, "## What it counts")) |row| {
        const code = row.cells[0];
        var tree = try Ast.parse(gpa, try arena.dupeSentinel(u8, code, 0), .{});
        defer tree.deinit(gpa);
        const function = try firstFunction(arena, &tree);
        const a = try std.fmt.parseInt(u32, row.cells[1], 10);
        const b = try std.fmt.parseInt(u32, row.cells[2], 10);
        if (std.mem.eql(u8, row.header, "| Code | params | weighted |")) {
            const p = params.count(&tree, function);
            if (p.count != a or p.weighted != b) {
                std.debug.print("skill: `{s}`: says params {d} weighted {d}, gnarl gives {d} and {d}\n", .{ code, a, b, p.count, p.weighted });
                return error.TestUnexpectedResult;
            }
        } else if (std.mem.eql(u8, row.header, "| Code | cyclomatic | cognitive |")) {
            const cc = try cyclomatic.count(arena, &tree, function.node);
            const cog = try cognitive.count(arena, &tree, function.node);
            if (cc != a or cog != b) {
                std.debug.print("skill: `{s}`: says cyclomatic {d} cognitive {d}, gnarl gives {d} and {d}\n", .{ code, a, b, cc, cog });
                return error.TestUnexpectedResult;
            }
        } else if (std.mem.eql(u8, row.header, "| Code | cyclomatic | nesting |")) {
            const cc = try cyclomatic.count(arena, &tree, function.node);
            const depth = try nesting.depth(arena, &tree, function.node);
            if (cc != a or depth != b) {
                std.debug.print("skill: `{s}`: says cyclomatic {d} nesting {d}, gnarl gives {d} and {d}\n", .{ code, a, b, cc, depth });
                return error.TestUnexpectedResult;
            }
        } else return error.UnknownTable;
        checked += 1;
    }
    try std.testing.expectEqual(26, checked);
}

test "the worked example measures as the skill says" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const intro = "A worked example:\n\n```zig\n";
    const start = (std.mem.find(u8, text, intro) orelse return error.NoExample) + intro.len;
    const end = std.mem.findPos(u8, text, start, "```") orelse return error.NoExample;
    const source = try arena.dupeSentinel(u8, text[start..end], 0);
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    var rows: std.ArrayList(report.Row) = .empty;
    try measure.file(arena, arena, "example.zig", &tree, .normal, &rows);

    const claim_start = (std.mem.findPos(u8, text, end, "gnarl measures ") orelse return error.NoClaim) + "gnarl measures ".len;
    const claim = text[claim_start .. std.mem.findScalarPos(u8, text, claim_start, '\n') orelse return error.NoClaim];
    const colon = std.mem.findScalar(u8, claim, ':') orelse return error.NoClaim;
    const row = for (rows.items) |r| {
        if (std.mem.eql(u8, r.name, claim[0..colon])) break r;
    } else return error.NoSuchFunction;
    var got: std.Io.Writer.Allocating = .init(arena);
    try got.writer.print("{s}: cyclomatic {d}, cognitive {d}, lines {d}, nesting {d}, params {d}, weighted {d}.", .{
        row.name, row.cyclomatic, row.cognitive, row.lines, row.nesting, row.params, row.params_weighted,
    });
    try std.testing.expectEqualStrings(claim, got.written());
}

test "the default thresholds and the complexity.zon example are as gnarl has them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const header = "| | cyclomatic | cognitive | lines | nesting | params |";
    var lines = std.mem.splitScalar(u8, text[std.mem.find(u8, text, header).?..], '\n');
    _ = lines.next();
    _ = lines.next();
    for (std.enums.values(thresholds.Class)) |class| {
        const line = lines.next().?;
        var cells = std.mem.splitScalar(u8, line, '|');
        _ = cells.next();
        try std.testing.expectEqualStrings(@tagName(class), std.mem.trim(u8, cells.next().?, " "));
        const limits = thresholds.Classes.defaults.get(class);
        for ([_]thresholds.Metric{ .cyclomatic, .cognitive, .lines, .nesting, .params }) |metric| {
            const cell = std.mem.trim(u8, cells.next().?, " ");
            var want: thresholds.Limit = .{};
            if (std.mem.cutPrefix(u8, cell, "critical ")) |n| {
                want.critical = try std.fmt.parseInt(u32, n, 10);
            } else if (std.mem.findScalar(u8, cell, ',')) |comma| {
                want.warning = try std.fmt.parseInt(u32, cell[0..comma], 10);
                want.critical = try std.fmt.parseInt(u32, std.mem.trim(u8, cell[comma + 1 ..], " "), 10);
            } else if (cell.len > 0) {
                want.warning = try std.fmt.parseInt(u32, cell, 10);
            }
            try std.testing.expectEqual(want, limits.of(metric));
        }
    }

    const intro = "```zig\n.{";
    const start = (std.mem.find(u8, text, intro) orelse return error.NoExample) + "```zig\n".len;
    const end = std.mem.findPos(u8, text, start, "```") orelse return error.NoExample;
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: config.Problem = undefined;
    const parsed = try config.parse(std.testing.allocator, arena, try arena.dupeSentinel(u8, text[start..end], 0), &diagnostics, &problem);
    try std.testing.expectEqual(.hot, parsed.classOf("src/parse/deep/a.zig"));
    try std.testing.expectEqual(.cold, parsed.classOf("build.zig"));
}

test "every metric and format gnarl has is named in the skill" {
    inline for (comptime std.enums.values(thresholds.Metric)) |metric| {
        try std.testing.expect(std.mem.find(u8, text, "`" ++ @tagName(metric) ++ "`") != null);
    }
    inline for (comptime std.enums.values(report.Format)) |format| {
        try std.testing.expect(std.mem.find(u8, text, "`" ++ @tagName(format) ++ "`") != null);
    }
}

test "the short guide and the topics, in order, are the guide" {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    try joined.appendSlice(std.testing.allocator, text[0..body_start]);
    try joined.appendSlice(std.testing.allocator, short);
    var it: Topics = .{};
    var count: usize = 0;
    while (it.next()) |topic| : (count += 1) {
        try std.testing.expect(std.mem.startsWith(u8, topic.text, "## "));
        try std.testing.expect(std.mem.find(u8, topic.text, "\n## ") == null);
        if (topic.name.len == 0 or std.mem.findScalar(u8, topic.name, ' ') != null) {
            std.debug.print("skill: a section after the first topic names no topic: {s}\n", .{topic.text[0 .. std.mem.findScalar(u8, topic.text, '\n') orelse topic.text.len]});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings(topic.text, topicOf(topic.name).?);
        try joined.appendSlice(std.testing.allocator, topic.text);
    }
    try std.testing.expectEqualStrings(text, joined.items);
    try std.testing.expectEqual(3, count);
    // The short guide is the whole guide up to the first topic.
    try std.testing.expect(std.mem.startsWith(u8, short, "# gnarl"));
    try std.testing.expect(std.mem.endsWith(u8, short, "\n\n"));
    try std.testing.expect(std.mem.find(u8, short, "## The loop\n") != null);
    try std.testing.expect(std.mem.find(u8, short, "## What catches agents out\n") != null);
    try std.testing.expectEqual(null, topicOf(""));
    try std.testing.expectEqual(null, topicOf("loop"));
    try std.testing.expectEqual(null, topicOf("What it counts"));
}

test "the short guide names every topic in a line, in the guide's order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each `- `gnarl skill name`: ` line.
    var listed: Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, short, '\n');
    while (lines.next()) |line| {
        const item = std.mem.cutPrefix(u8, line, "- `gnarl skill ") orelse continue;
        const close = std.mem.find(u8, item, "`: ") orelse continue;
        try listed.writer.print("{s}{s}", .{ if (listed.written().len == 0) "" else ", ", item[0..close] });
    }
    try std.testing.expectEqualStrings(try names(arena), listed.written());
}

test "the short guide and each topic are held under a size" {
    // An agent reads them as a command's output: the short guide on every
    // load, and a topic when the job needs it. Raise a limit only after
    // cutting what can go.
    const short_cap = 12_000;
    const topic_cap = 7_000;
    if (short.len > short_cap) {
        std.debug.print("skill: the short guide is {d} bytes, over {d}\n", .{ short.len, short_cap });
        return error.TestUnexpectedResult;
    }
    var it: Topics = .{};
    while (it.next()) |topic| {
        if (topic.text.len > topic_cap) {
            std.debug.print("skill: {s} is {d} bytes, over {d}\n", .{ topic.name, topic.text.len, topic_cap });
            return error.TestUnexpectedResult;
        }
    }
}

test "the stub is the frontmatter and a line handing over to gnarl skill" {
    try std.testing.expect(std.mem.startsWith(u8, stub, "---\nname: gnarl\ndescription: "));
    try std.testing.expect(std.mem.startsWith(u8, text, frontmatter));
    try std.testing.expectEqualStrings(frontmatter, stub[0..frontmatter.len]);
    try std.testing.expect(std.mem.find(u8, stub[frontmatter.len..], "`gnarl skill`") != null);
}

test "install writes the stub as SKILL.md under the directory named" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dir = try std.fs.path.join(arena, &.{ base, "skills" });
    const path = try install(arena, io, dir);
    try std.testing.expect(std.mem.endsWith(u8, path, "gnarl" ++ std.fs.path.sep_str ++ "SKILL.md"));
    const written = try tmp.dir.readFileAlloc(io, "skills/gnarl/SKILL.md", arena, .limited(1 << 20));
    try std.testing.expectEqualStrings(stub, written);
}

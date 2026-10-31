//! `gnarl skill`: what an agent needs to work with gnarl, printed by the
//! binary itself, and tested here against what gnarl does: every example
//! in it measures as it says.

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

pub const text = @embedFile("skill.md");

/// Writes the skill to `dir/gnarl/SKILL.md`, making the directories, and
/// returns the path written.
pub fn install(arena: Allocator, io: Io, dir: []const u8) ![]const u8 {
    const sub = try std.fs.path.join(arena, &.{ dir, "gnarl" });
    try Io.Dir.cwd().createDirPath(io, sub);
    const path = try std.fs.path.join(arena, &.{ sub, "SKILL.md" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
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
    try std.testing.expectEqual(25, checked);
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
    try measure.file(arena, arena, "example.zig", &tree, &rows);

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

test "install writes SKILL.md under the directory named" {
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
    try std.testing.expectEqualStrings(text, written);
}

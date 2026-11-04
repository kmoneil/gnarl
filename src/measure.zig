//! Every metric of every function in one parsed file.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const cognitive = @import("cognitive.zig");
const cyclomatic = @import("cyclomatic.zig");
const functions = @import("functions.zig");
const lines = @import("lines.zig");
const nesting = @import("nesting.zig");
const params = @import("params.zig");
const Row = @import("report.zig").Row;
const LineIndex = @import("select.zig").LineIndex;
const test_code = @import("test_code.zig");
const Class = @import("thresholds.zig").Class;

/// Appends a row for each function in `tree`, read from `path`, to `rows`,
/// in source order, each held to its class: `class`, the file's, or
/// `tests` for test code (test_code.zig). The rows and their names are
/// allocated with `arena` and the working memory with `scratch`; `path`
/// must outlive the rows.
pub fn file(arena: Allocator, scratch: Allocator, path: []const u8, tree: *const Ast, class: Class, rows: *std.ArrayList(Row)) Allocator.Error!void {
    const index = try LineIndex.init(scratch, tree.source);
    const listed = try functions.list(scratch, tree);
    for (listed, try test_code.judge(scratch, tree, listed)) |function, reason| {
        const p = params.count(tree, function);
        try rows.append(arena, .{
            .path = path,
            .line = function.line,
            .end_line = index.ofToken(tree, tree.lastToken(function.node)).line,
            .column = function.column,
            .name = try arena.dupe(u8, function.name),
            .kind = function.kind,
            .class = .forFunction(class, reason != null),
            .cyclomatic = try cyclomatic.count(scratch, tree, function.node),
            .cognitive = try cognitive.count(scratch, tree, function.node),
            .lines = try lines.count(scratch, tree, function.node),
            .nesting = try nesting.depth(scratch, tree, function.node),
            .params = p.count,
            .params_weighted = p.weighted,
        });
    }
}

//! Every metric of every function in one parsed file.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const cyclomatic = @import("cyclomatic.zig");
const functions = @import("functions.zig");
const lines = @import("lines.zig");
const nesting = @import("nesting.zig");
const params = @import("params.zig");
const Row = @import("report.zig").Row;

/// Appends a row for each function in `tree`, read from `path`, to `rows`,
/// in source order. The rows and their names are allocated with `arena`
/// and the working memory with `scratch`; `path` must outlive the rows.
pub fn file(arena: Allocator, scratch: Allocator, path: []const u8, tree: *const Ast, rows: *std.ArrayList(Row)) Allocator.Error!void {
    for (try functions.list(scratch, tree)) |function| {
        const p = params.count(tree, function);
        try rows.append(arena, .{
            .path = path,
            .line = function.line,
            .column = function.column,
            .name = try arena.dupe(u8, function.name),
            .kind = function.kind,
            .cyclomatic = try cyclomatic.count(scratch, tree, function.node),
            .lines = try lines.count(scratch, tree, function.node),
            .nesting = try nesting.depth(scratch, tree, function.node),
            .params = p.count,
            .params_weighted = p.weighted,
        });
    }
}

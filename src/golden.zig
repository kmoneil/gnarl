//! The golden tables: every metric of every function in each fixture under
//! test/golden/, checked against the table committed beside it
//! (`name.zig` and `name.txt`, a line per function in source order).
//!
//! The numbers were checked when each table was written; this keeps them
//! from moving unnoticed. When a counting rule changes on purpose,
//! `zig build test -Dupdate` rewrites the tables, and the diff shows what
//! the change moved.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;

const test_options = @import("test_options");
const measure = @import("measure.zig");
const Row = @import("report.zig").Row;

const dir_path = "test/golden";

/// `rows` as a golden table.
fn render(gpa: std.mem.Allocator, rows: []const Row) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows) |row| try out.print(gpa, "{d} {s} cyclomatic={d} cognitive={d} lines={d} nesting={d} params={d} weighted={d}\n", .{
        row.line, row.name, row.cyclomatic, row.cognitive, row.lines, row.nesting, row.params, row.params_weighted,
    });
    return out.toOwnedSlice(gpa);
}

test "every fixture's functions measure as its golden table says" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    try std.testing.expect(names.items.len > 0);

    var failed = false;
    for (names.items) |name| {
        const source = try dir.readFileAllocOptions(io, name, gpa, .limited(std.math.maxInt(u32)), .of(u8), 0);
        defer gpa.free(source);
        var tree = try Ast.parse(gpa, source, .{});
        defer tree.deinit(gpa);
        try std.testing.expectEqual(0, tree.errors.len);

        var rows: std.ArrayList(Row) = .empty;
        try measure.file(arena, arena, name, &tree, &rows);
        const got = try render(gpa, rows.items);
        defer gpa.free(got);

        const table = try std.fmt.allocPrint(arena, "{s}.txt", .{name[0 .. name.len - ".zig".len]});
        if (test_options.update) {
            try dir.writeFile(io, .{ .sub_path = table, .data = got });
            continue;
        }
        const want = dir.readFileAlloc(io, table, gpa, .limited(1 << 24)) catch |err| {
            std.debug.print("{s}/{s}: {t}; zig build test -Dupdate writes it\n", .{ dir_path, table, err });
            failed = true;
            continue;
        };
        defer gpa.free(want);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s}/{s} no longer matches what gnarl measures:\n", .{ dir_path, table });
            std.testing.expectEqualStrings(want, got) catch {};
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

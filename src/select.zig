//! Naming functions on the command line, as --explain and --function do:
//! `path:line`, the line the report prints or any line inside the
//! function, or a name, whole or its end (`record` for `Validator.record`).

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Row = @import("report.zig").Row;

pub const Selector = union(enum) {
    /// `path:line`: the function there, as the report prints it, or the
    /// innermost one around that line.
    at: struct { path: []const u8, line: u32 },
    /// A qualified name, or its last segments.
    name: []const u8,

    pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Selector {
        if (std.mem.findScalarLast(u8, text, ':')) |colon| {
            if (colon > 0) {
                if (std.fmt.parseInt(u32, text[colon + 1 ..], 10)) |line| {
                    if (line > 0) return .{ .at = .{ .path = try std.fs.path.resolveAlloc(arena, &.{text[0..colon]}), .line = line } };
                } else |_| {}
            }
        }
        return .{ .name = text };
    }
};

pub const NameMatch = enum { none, exact, tail };

/// Whether `name`, a qualified name, is `wanted`, or ends with it after a
/// `.`: `record` ends `Validator.record`, but not `rerecord`.
pub fn matchName(name: []const u8, wanted: []const u8) NameMatch {
    if (std.mem.eql(u8, name, wanted)) return .exact;
    if (name.len > wanted.len and std.mem.endsWith(u8, name, wanted) and name[name.len - wanted.len - 1] == '.') return .tail;
    return .none;
}

/// Which `rows` the selectors pick, as a flag per row, and the selectors
/// (by index) that pick none. A `path:line` picks the row at that line, or
/// else the innermost row around it; a name picks every row of exactly
/// that name, or else every row whose name ends with it.
pub fn pick(arena: Allocator, rows: []const Row, selectors: []const Selector) Allocator.Error!struct { picked: []bool, unmatched: []const usize } {
    const picked = try arena.alloc(bool, rows.len);
    @memset(picked, false);
    var unmatched: std.ArrayList(usize) = .empty;
    for (selectors, 0..) |selector, s| {
        var any = false;
        switch (selector) {
            .at => |at| {
                var around: ?usize = null;
                for (rows, 0..) |row, i| {
                    if (!std.mem.eql(u8, row.path, at.path)) continue;
                    if (row.line == at.line) {
                        around = i;
                        break;
                    }
                    if (row.line <= at.line and at.line <= row.end_line) {
                        if (around == null or row.end_line - row.line < rows[around.?].end_line - rows[around.?].line) around = i;
                    }
                }
                if (around) |i| {
                    picked[i] = true;
                    any = true;
                }
            },
            .name => |name| {
                const exact = for (rows) |row| {
                    if (matchName(row.name, name) == .exact) break true;
                } else false;
                const wanted: NameMatch = if (exact) .exact else .tail;
                for (rows, picked) |row, *p| if (matchName(row.name, name) == wanted) {
                    p.* = true;
                    any = true;
                };
            },
        }
        if (!any) try unmatched.append(arena, s);
    }
    return .{ .picked = picked, .unmatched = unmatched.items };
}

/// Line starts in a source, to turn a byte offset into a line and column.
pub const LineIndex = struct {
    starts: []const u32,

    pub fn init(arena: Allocator, source: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        for (source, 0..) |c, i| if (c == '\n') try starts.append(arena, @intCast(i + 1));
        return .{ .starts = starts.items };
    }

    /// The line and column of `offset`, both from 1; the column counts
    /// bytes.
    pub fn at(index: LineIndex, offset: u32) struct { line: u32, column: u32 } {
        // The last line starting at or before `offset`.
        var lo: usize = 0;
        var hi: usize = index.starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (index.starts[mid] <= offset) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .column = offset - index.starts[lo] + 1 };
    }

    pub fn ofToken(index: LineIndex, tree: *const Ast, token: Ast.TokenIndex) struct { line: u32, column: u32 } {
        const loc = index.at(tree.tokenStart(token));
        return .{ .line = loc.line, .column = loc.column };
    }
};

test "Selector: path:line, or a name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at = (try Selector.parse(arena, "./src/a.zig:12")).at;
    try std.testing.expectEqualStrings(try std.fs.path.resolveAlloc(arena, &.{"src/a.zig"}), at.path);
    try std.testing.expectEqual(12, at.line);
    try std.testing.expectEqualStrings("Validator.record", (try Selector.parse(arena, "Validator.record")).name);
    try std.testing.expectEqualStrings("a.zig:", (try Selector.parse(arena, "a.zig:")).name);
    try std.testing.expectEqualStrings("a.zig:x", (try Selector.parse(arena, "a.zig:x")).name);
}

test "matchName: the whole name, or its end after a dot" {
    try std.testing.expectEqual(.exact, matchName("record", "record"));
    try std.testing.expectEqual(.tail, matchName("Validator.record", "record"));
    try std.testing.expectEqual(.tail, matchName("a.B.c", "B.c"));
    try std.testing.expectEqual(.none, matchName("rerecord", "record"));
    try std.testing.expectEqual(.none, matchName("Validator.record", "Validator"));
}

test "pick: by line, by a line inside, by name; a whole name hides the ends" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const row: Row = .{ .path = "a.zig", .line = 1, .end_line = 1, .column = 1, .name = "", .kind = .@"fn", .cyclomatic = 1, .lines = 1, .nesting = 0, .params = 0, .params_weighted = 0 };
    var rows = [_]Row{ row, row, row, row };
    rows[0].name = "S";
    rows[0].end_line = 20;
    rows[1].name = "S.record";
    rows[1].line = 5;
    rows[1].end_line = 9;
    rows[2].name = "record";
    rows[2].line = 22;
    rows[2].end_line = 25;
    rows[3].name = "T.parse";
    rows[3].path = "b.zig";
    const selectors = [_]Selector{
        .{ .at = .{ .path = "a.zig", .line = 7 } },
        .{ .name = "parse" },
        .{ .name = "nope" },
        .{ .at = .{ .path = "a.zig", .line = 30 } },
    };
    const r = try pick(arena, &rows, &selectors);
    // Line 7 is inside S and S.record: the innermost, S.record.
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, true }, r.picked);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, r.unmatched);

    const by_name = try pick(arena, &rows, &.{.{ .name = "record" }});
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, false }, by_name.picked);
}

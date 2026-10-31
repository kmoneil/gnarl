//! The ranges of a function worth lifting into functions of their own:
//! each statement of each block, and each block's statements together,
//! estimated as `--explain path:A-B` estimates a range, best first.
//!
//! Best is a clean cut: no `return`, `break` or `continue` leaves it, it
//! takes four parameters or fewer and gives back a value at most; then
//! one that would need a struct of either; then one a jump leaves, which
//! would need reworking; past a clean cut, the fewer values carried in
//! and out the better. Then the cut that leaves the larger of the two
//! functions, the one that stays and the one lifted out, the least
//! complex: by cognitive complexity, then cyclomatic.
//! Ranges overlapping a better one are left out, so each is its own cut,
//! and so is one that would take away less than a tenth of the cost, or
//! less than 3.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const flow = @import("flow.zig");
const functions = @import("functions.zig");
const regions = @import("regions.zig");

pub const Candidate = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    sum: regions.Sum,
    extracted: regions.Extracted,
    /// How many names it would give back.
    gives: u32,
    /// How many jumps leave it.
    leaving: u32,

    /// The larger of the two functions the cut leaves, by cognitive then
    /// cyclomatic complexity: what to make small.
    fn larger(c: Candidate) [2]u32 {
        const h = c.extracted.helper;
        const r = c.extracted.rest;
        return .{ @max(h.cognitive, r.cognitive), @max(h.cyclomatic, r.cyclomatic) };
    }

    /// 0 for a clean cut: no jump leaves it, it takes 4 parameters or
    /// fewer and gives back one value at most. 1 for one that needs a
    /// struct of parameters or results; 2 for one a jump leaves.
    fn group(c: Candidate) u2 {
        if (c.leaving > 0) return 2;
        if (c.extracted.helper.params > 4 or c.gives > 1) return 1;
        return 0;
    }

    fn before(_: void, a: Candidate, b: Candidate) bool {
        if (a.group() != b.group()) return a.group() < b.group();
        // Past a clean cut, the fewer values to carry in and out the better.
        if (a.group() > 0 and a.carried() != b.carried()) return a.carried() < b.carried();
        const x = a.larger();
        const y = b.larger();
        if (x[0] != y[0]) return x[0] < y[0];
        if (x[1] != y[1]) return x[1] < y[1];
        return a.first < b.first;
    }

    /// What the new function would take and give back, counted together.
    fn carried(c: Candidate) u32 {
        return c.extracted.helper.params + c.gives;
    }

    fn overlaps(a: Candidate, b: Candidate) bool {
        return a.first <= b.last and b.first <= a.last;
    }
};

/// What the whole function scores, which a cut divides.
pub const Totals = struct { cyclomatic: u32, cognitive: u32, lines: u32 };

/// At most `n` ranges of `function` worth lifting out, best first, none
/// overlapping another. Allocated with `arena`.
pub fn best(arena: Allocator, tree: *const Ast, function: functions.Function, totals: Totals, n: usize) Allocator.Error![]const Candidate {
    const facts: regions.Facts = try .of(arena, tree, function.node);
    const jumps = try regions.jumps(arena, tree, function.node);
    var all: std.ArrayList(Candidate) = .empty;
    for (try spans(arena, tree, function.node)) |span| {
        const sum: regions.Sum = .of(facts, span[0], span[1]);
        if (!worthIt(sum, totals)) continue;
        try all.append(arena, try estimate(arena, tree, function, span, sum, jumps, totals));
    }
    std.mem.sort(Candidate, all.items, {}, Candidate.before);
    var chosen: std.ArrayList(Candidate) = .empty;
    for (all.items) |c| {
        if (chosen.items.len == n) break;
        const clash = for (chosen.items) |o| {
            if (c.overlaps(o)) break true;
        } else false;
        if (!clash) try chosen.append(arena, c);
    }
    return chosen.items;
}

/// Whether lifting `sum` out would take away enough to matter: a tenth or
/// more of what the function adds, and 3 or more, of its cognitive
/// complexity, or of its cyclomatic when it has none. A big function is
/// rarely brought under by one cut, so the bar is a series of cuts'.
fn worthIt(sum: regions.Sum, totals: Totals) bool {
    if (totals.cognitive > 0) return sum.cognitive >= @max(3, (totals.cognitive + 9) / 10);
    return sum.cyclomatic >= @max(3, (totals.cyclomatic + 9) / 10);
}

fn estimate(arena: Allocator, tree: *const Ast, function: functions.Function, span: [2]Ast.TokenIndex, sum: regions.Sum, jumps: []const regions.Jump, totals: Totals) Allocator.Error!Candidate {
    var c: Candidate = .{
        .first = span[0],
        .last = span[1],
        .sum = sum,
        .extracted = .of(sum, .{ .cyclomatic = totals.cyclomatic, .cognitive = totals.cognitive, .lines = totals.lines }),
        .gives = 0,
        .leaving = 0,
    };
    for (jumps) |j| c.leaving += @intFromBool(j.leaves(span[0], span[1]));
    const f = try flow.of(arena, tree, function, span[0], span[1]);
    for (f.needs) |need| c.extracted.helper.params += @intFromBool(!flow.isContext(need.type));
    c.gives = @intCast(f.gives.len);
    return c;
}

/// Each statement of each block in the function's own code, and each
/// block's statements together when there are two or more; not the whole
/// body, which is the function itself.
fn spans(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error![]const [2]Ast.TokenIndex {
    const body = switch (tree.nodeTag(function)) {
        .fn_decl => tree.nodeData(function).node_and_node[1],
        else => tree.nodeData(function).opt_token_and_node[1],
    };
    var out: std.ArrayList([2]Ast.TokenIndex) = .empty;
    var stack: std.ArrayList(Node.Index) = .empty;
    try stack.append(arena, body);
    while (stack.pop()) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl, .test_decl => continue,
            .block_two, .block_two_semicolon, .block, .block_semicolon => try blockSpans(arena, tree, node, node == body, &out),
            else => {},
        }
        try children.append(arena, tree, node, &stack);
    }
    return out.items;
}

fn blockSpans(arena: Allocator, tree: *const Ast, block: Node.Index, is_body: bool, out: *std.ArrayList([2]Ast.TokenIndex)) Allocator.Error!void {
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block).?;
    for (statements) |s| try out.append(arena, .{ tree.firstToken(s), tree.lastToken(s) });
    if (statements.len >= 2 and !is_body) try out.append(arena, .{ tree.firstToken(statements[0]), tree.lastToken(statements[statements.len - 1]) });
}

test "the prongs of a switch that holds it all are the cuts, best first" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\fn pick(rows: []const Row, selectors: []const Selector, picked: []bool) void {
        \\    for (selectors) |selector| {
        \\        var any = false;
        \\        switch (selector) {
        \\            .at => |at| {
        \\                var around: ?usize = null;
        \\                for (rows, 0..) |row, i| {
        \\                    if (!std.mem.eql(u8, row.path, at.path)) continue;
        \\                    if (row.line == at.line) {
        \\                        around = i;
        \\                        break;
        \\                    }
        \\                }
        \\                if (around) |i| {
        \\                    picked[i] = true;
        \\                    any = true;
        \\                }
        \\            },
        \\            .name => |name| {
        \\                for (rows, picked) |row, *p| if (eql(row.name, name)) {
        \\                    p.* = true;
        \\                    any = true;
        \\                };
        \\            },
        \\        }
        \\        if (!any) fail();
        \\    }
        \\}
    ;
    var tree = try Ast.parse(arena, source, .{});
    try std.testing.expectEqual(0, tree.errors.len);
    const function = (try functions.list(arena, &tree))[0];
    const cyclomatic = @import("cyclomatic.zig");
    const cognitive = @import("cognitive.zig");
    const lines = @import("lines.zig");
    const totals: Totals = .{
        .cyclomatic = try cyclomatic.count(arena, &tree, function.node),
        .cognitive = try cognitive.count(arena, &tree, function.node),
        .lines = try lines.count(arena, &tree, function.node),
    };
    const found = try best(arena, &tree, function, totals, 3);
    var got: std.ArrayList(u8) = .empty;
    for (found) |c| {
        try got.print(arena, "{d}-{d} keeps {d}/{d} lifts {d}/{d} params {d} gives {d} leaving {d}\n", .{
            tree.tokenLocation(0, c.first).line + 1, tree.tokenLocation(0, c.last).line + 1,
            c.extracted.rest.cognitive,              c.extracted.rest.cyclomatic,
            c.extracted.helper.cognitive,            c.extracted.helper.cyclomatic,
            c.extracted.helper.params,               c.gives,
            c.leaving,
        });
    }
    // Each prong's body: lifting .at's leaves pick 12 cognitive and makes a
    // function of 6, taking rows, at and picked and giving back any; .name's
    // likewise. The if after the switch takes away too little to name.
    try std.testing.expectEqualStrings(
        \\6-17 keeps 12/7 lifts 6/5 params 3 gives 1 leaving 0
        \\20-23 keeps 19/9 lifts 3/3 params 3 gives 1 leaving 0
        \\
    , got.items);
}

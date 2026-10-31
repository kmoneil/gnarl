//! Where a function's numbers come from, by region: the signature and
//! each top-level statement of its body, or any range of its lines. Each
//! construct a count charged, each logical line and each level is in the
//! region that holds its token, so the regions of a body add up to the
//! function's totals: cyclomatic's base 1 aside, the cyclomatic and
//! cognitive costs and the lines sum, and the deepest level of any is the
//! nesting depth.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const cognitive = @import("cognitive.zig");
const cyclomatic = @import("cyclomatic.zig");
const lines = @import("lines.zig");
const nesting = @import("nesting.zig");

/// What each count found in a function, each at its token.
pub const Facts = struct {
    branches: []const cyclomatic.Branch,
    costs: []const cognitive.Cost,
    /// The first code token of each logical line.
    lines: []const Ast.TokenIndex,
    levels: []const nesting.Level,

    pub fn of(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!Facts {
        var branches: std.ArrayList(cyclomatic.Branch) = .empty;
        _ = try cyclomatic.explain(arena, tree, function, &branches);
        var costs: std.ArrayList(cognitive.Cost) = .empty;
        _ = try cognitive.explain(arena, tree, function, &costs);
        var firsts: std.ArrayList(Ast.TokenIndex) = .empty;
        _ = try lines.firsts(arena, tree, function, &firsts);
        var opened: std.ArrayList(nesting.Level) = .empty;
        _ = try nesting.levels(arena, tree, function, &opened);
        return .{ .branches = branches.items, .costs = costs.items, .lines = firsts.items, .levels = opened.items };
    }
};

/// What the facts in a range of tokens add.
pub const Sum = struct {
    cyclomatic: u32 = 0,
    cognitive: u32 = 0,
    /// How much of `cognitive` is for the depth its structures sit at.
    depth: u32 = 0,
    lines: u32 = 0,
    /// The deepest level a construct in it opens; 0 for none.
    nesting: u32 = 0,
    /// The structures charged in it: the costs that grow with depth.
    structures: u32 = 0,
    /// The least depth a structure in it sits at: its outermost
    /// structures'. Null when it has none.
    base: ?u32 = null,

    /// What the facts with a token from `first` to `last` add.
    pub fn of(facts: Facts, first: Ast.TokenIndex, last: Ast.TokenIndex) Sum {
        var s: Sum = .{};
        for (facts.branches) |b| if (first <= b.token and b.token <= last) {
            s.cyclomatic += b.adds;
        };
        for (facts.costs) |c| if (first <= c.token and c.token <= last) s.addCost(c);
        for (facts.lines) |t| s.lines += @intFromBool(first <= t and t <= last);
        for (facts.levels) |l| if (first <= l.token and l.token <= last) {
            s.nesting = @max(s.nesting, l.level);
        };
        return s;
    }

    fn addCost(s: *Sum, c: cognitive.Cost) void {
        s.cognitive += c.adds;
        s.depth += c.depth;
        if (!c.structure) return;
        s.structures += 1;
        s.base = @min(s.base orelse c.depth, c.depth);
    }
};

pub const Region = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    /// How many of the body's statements it is: 0 for the signature.
    statements: u32,
    sum: Sum,
};

/// The signature (from the function's first token to its body's opening
/// brace), then each top-level statement of its body. Allocated with
/// `arena`.
pub fn ofBody(arena: Allocator, tree: *const Ast, function: Node.Index, facts: Facts) Allocator.Error![]const Region {
    const body = switch (tree.nodeTag(function)) {
        .fn_decl => tree.nodeData(function).node_and_node[1],
        else => tree.nodeData(function).opt_token_and_node[1],
    };
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body).?;
    const out = try arena.alloc(Region, 1 + statements.len);
    const lbrace = tree.nodeMainToken(body);
    out[0] = .{ .first = tree.firstToken(function), .last = lbrace, .statements = 0, .sum = .of(facts, tree.firstToken(function), lbrace) };
    for (statements, out[1..]) |statement, *region| {
        const first = tree.firstToken(statement);
        const last = tree.lastToken(statement);
        region.* = .{ .first = first, .last = last, .statements = 1, .sum = .of(facts, first, last) };
    }
    return out;
}

/// What lifting a range out into a function of its own would leave, about:
/// the new function's numbers, its structures as much shallower as the
/// range's outermost ones sit deep, and what the old one keeps. Jumps out
/// of the range, which would need reworking, are not accounted for.
pub const Extracted = struct {
    helper: struct { cyclomatic: u32, cognitive: u32, nesting: u32 },
    rest: struct { cyclomatic: u32, cognitive: u32, lines: u32 },

    /// `range`, of a function whose totals are `whole`, lifted out.
    pub fn of(range: Sum, whole: struct { cyclomatic: u32, cognitive: u32, lines: u32 }) Extracted {
        const base = range.base orelse 0;
        return .{
            .helper = .{
                .cyclomatic = 1 + range.cyclomatic,
                .cognitive = range.cognitive - base * range.structures,
                .nesting = range.nesting -| base,
            },
            // The call stays, a line of its own.
            .rest = .{
                .cyclomatic = whole.cyclomatic - range.cyclomatic,
                .cognitive = whole.cognitive - range.cognitive,
                .lines = whole.lines - range.lines + 1,
            },
        };
    }
};

const testing = struct {
    const functions = @import("functions.zig");

    fn parse(arena: Allocator, source: []const u8) !Ast {
        const tree = try Ast.parse(arena, try arena.dupeSentinel(u8, source, 0), .{});
        try std.testing.expectEqual(0, tree.errors.len);
        return tree;
    }
};

test "a body's regions add up to the function's totals" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try testing.parse(arena,
        \\fn f(xs: []const u8, c: bool) u8 {
        \\    const n = xs.len; const m = n + 1;
        \\    for (xs) |x| {
        \\        if (x == 0 and c) return x;
        \\    }
        \\    _ = m;
        \\    return if (c) 1 else 2;
        \\}
    );
    const function = (try testing.functions.list(arena, &tree))[0];
    const facts: Facts = try .of(arena, &tree, function.node);
    const regions = try ofBody(arena, &tree, function.node, facts);
    // The signature, then five statements, two of them on one line.
    try std.testing.expectEqual(6, regions.len);
    var cc: u32 = 1;
    var cog: u32 = 0;
    var n: u32 = 0;
    var deepest: u32 = 0;
    for (regions) |r| {
        cc += r.sum.cyclomatic;
        cog += r.sum.cognitive;
        n += r.sum.lines;
        deepest = @max(deepest, r.sum.nesting);
    }
    try std.testing.expectEqual(try cyclomatic.count(arena, &tree, function.node), cc);
    try std.testing.expectEqual(try cognitive.count(arena, &tree, function.node), cog);
    try std.testing.expectEqual(try lines.count(arena, &tree, function.node), n);
    try std.testing.expectEqual(try nesting.depth(arena, &tree, function.node), deepest);
    // The for: for, if and and; for 1, if 2, and 1, the return in it 1;
    // its lines; for > if.
    try std.testing.expectEqual(Sum{ .cyclomatic = 3, .cognitive = 5, .depth = 1, .lines = 2, .nesting = 2, .structures = 2, .base = 0 }, regions[3].sum);
    // Two statements on one line: the line goes to the first.
    try std.testing.expectEqual(1, regions[1].sum.lines);
    try std.testing.expectEqual(0, regions[2].sum.lines);
}

test "extracted: the structures as much shallower as the range's outermost sit deep" {
    // A range inside a loop: an if at depth 1 with an if inside, at 2.
    const range: Sum = .{ .cyclomatic = 2, .cognitive = 2 + 3, .depth = 1 + 2, .lines = 3, .nesting = 3, .structures = 2, .base = 1 };
    const e: Extracted = .of(range, .{ .cyclomatic = 10, .cognitive = 20, .lines = 30 });
    try std.testing.expectEqual(3, e.helper.cyclomatic);
    try std.testing.expectEqual(3, e.helper.cognitive);
    try std.testing.expectEqual(2, e.helper.nesting);
    try std.testing.expectEqual(8, e.rest.cyclomatic);
    try std.testing.expectEqual(15, e.rest.cognitive);
    try std.testing.expectEqual(28, e.rest.lines);
}

//! Where a function's numbers come from, by region: the signature and
//! each top-level statement of its body, or any range of its lines. Each
//! construct a count charged, each logical line and each level is in the
//! region that holds its token, so the regions of a body add up to the
//! function's totals: cyclomatic's base 1 aside, the cyclomatic and
//! cognitive costs and the lines sum, and the deepest level of any is the
//! nesting depth. A region that holds most of the cost is opened into its
//! parts, so a function whose body is one big statement still shows where
//! inside it the cost is.

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
        return within(facts, .{ .first = first, .last = last });
    }

    /// What the facts from `first` to `last` add, those in `holes` aside.
    pub fn except(facts: Facts, first: Ast.TokenIndex, last: Ast.TokenIndex, holes: []const [2]Ast.TokenIndex) Sum {
        return within(facts, .{ .first = first, .last = last, .holes = holes });
    }

    fn within(facts: Facts, span: Span) Sum {
        var s: Sum = .{};
        for (facts.branches) |b| if (span.holds(b.token)) {
            s.cyclomatic += b.adds;
        };
        for (facts.costs) |c| if (span.holds(c.token)) s.addCost(c);
        for (facts.lines) |t| s.lines += @intFromBool(span.holds(t));
        for (facts.levels) |l| if (span.holds(l.token)) {
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

/// A range of tokens, less any holes in it.
const Span = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    holes: []const [2]Ast.TokenIndex = &.{},

    fn holds(s: Span, t: Ast.TokenIndex) bool {
        if (t < s.first or t > s.last) return false;
        for (s.holes) |h| if (h[0] <= t and t <= h[1]) return false;
        return true;
    }
};

pub const Region = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    /// How many of the body's statements it is: 0 for the signature.
    statements: u32,
    sum: Sum,
    /// The statement or part it is, which may open into parts of its own;
    /// null for the signature and for a head.
    node: ?Node.Index = null,
    /// 0 for the signature and the body's statements; 1 for the parts of
    /// a statement opened, 2 for the parts of one of those, and so on.
    level: u32 = 0,

    fn adds(r: Region) bool {
        return r.sum.cyclomatic > 0 or r.sum.cognitive > 0;
    }
};

/// The one region of `regions` that adds anything, if exactly one does.
fn lone(regions: []const Region) ?usize {
    var found: ?usize = null;
    for (regions, 0..) |r, i| if (r.adds()) {
        if (found != null) return null;
        found = i;
    };
    return found;
}

/// The signature (from the function's first token to its body's opening
/// brace), then each top-level statement of its body; but when one
/// statement alone adds anything, it is opened: in its place, its head and
/// its parts, so there is something to compare. Allocated with `arena`.
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
        region.* = .{ .first = first, .last = last, .statements = 1, .sum = .of(facts, first, last), .node = statement };
    }
    var regions: []const Region = out;
    for (0..8) |_| {
        const i = dominant(regions) orelse break;
        const opened = try open(arena, tree, facts, regions[i], 0) orelse break;
        regions = try splice(arena, regions, i, opened);
    }
    return regions;
}

/// The region that holds most of what the function adds, three quarters
/// or more of its cognitive complexity (of its cyclomatic, with none), if
/// one does and it is a statement or part that may open.
fn dominant(regions: []const Region) ?usize {
    var cognitive_total: u32 = 0;
    var cyclomatic_total: u32 = 0;
    for (regions) |r| {
        cognitive_total += r.sum.cognitive;
        cyclomatic_total += r.sum.cyclomatic;
    }
    const by_cognitive = cognitive_total > 0;
    const total = if (by_cognitive) cognitive_total else cyclomatic_total;
    if (total == 0) return null;
    for (regions, 0..) |r, i| {
        const weight = if (by_cognitive) r.sum.cognitive else r.sum.cyclomatic;
        if (4 * weight >= 3 * total and r.node != null) return i;
    }
    return null;
}

/// `regions` with the one at `at` replaced by `with`.
fn splice(arena: Allocator, regions: []const Region, at: usize, with: []const Region) Allocator.Error![]const Region {
    var out: std.ArrayList(Region) = .empty;
    try out.appendSlice(arena, regions[0..at]);
    try out.appendSlice(arena, with);
    try out.appendSlice(arena, regions[at + 1 ..]);
    return out.items;
}

/// `r` opened: a head, what of it no part holds (its keyword, condition,
/// an `else`), then each of its parts; a part that alone adds anything
/// opened in turn. Null when that never gives two regions that add.
fn open(arena: Allocator, tree: *const Ast, facts: Facts, r: Region, depth: u32) Allocator.Error!?[]const Region {
    if (depth == 8) return null;
    const ps = try parts(arena, tree, r.node orelse return null);
    if (ps.len == 0) return null;
    const holes = try arena.alloc([2]Ast.TokenIndex, ps.len);
    for (ps, holes) |p, *h| h.* = .{ tree.firstToken(p), tree.lastToken(p) };
    var out: std.ArrayList(Region) = .empty;
    try out.append(arena, .{ .first = r.first, .last = holes[0][0] - 1, .statements = 1, .level = r.level, .sum = .except(facts, r.first, r.last, holes) });
    for (ps, holes) |p, h| try out.append(arena, .{ .first = h[0], .last = h[1], .statements = 1, .node = p, .level = r.level + 1, .sum = .of(facts, h[0], h[1]) });
    // The head holding it all opens no further.
    const i = lone(out.items) orelse return out.items;
    if (i == 0) return null;
    const inner = try open(arena, tree, facts, out.items[i], depth + 1) orelse return null;
    return try splice(arena, out.items, i, inner);
}

/// What `statement` opens into: a block's statements, a switch's prongs,
/// an `if`'s branches, a loop's body and `else`, a block handler's
/// statements, a block's taken as its statements; through a declaration's,
/// a `return`'s, an assignment's or a `try`'s value. None for anything
/// else.
fn parts(arena: Allocator, tree: *const Ast, statement: Node.Index) Allocator.Error![]const Node.Index {
    const n = core(tree, statement);
    var out: std.ArrayList(Node.Index) = .empty;
    switch (tree.nodeTag(n)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => try flat(arena, tree, n, &out),
        .@"switch", .switch_comma => return tree.fullSwitch(n).?.ast.cases,
        .if_simple, .@"if" => {
            const full = tree.fullIf(n).?;
            try flat(arena, tree, full.ast.then_expr, &out);
            if (full.ast.else_expr.unwrap()) |e| try flat(arena, tree, e, &out);
        },
        .while_simple, .while_cont, .@"while", .for_simple, .@"for" => {
            const body, const e = loopBodies(tree, n);
            try flat(arena, tree, body, &out);
            if (e) |x| try flat(arena, tree, x, &out);
        },
        .@"catch", .@"orelse" => {
            const handler = tree.nodeData(n).node_and_node[1];
            if (isBlock(tree, handler)) try flat(arena, tree, handler, &out);
        },
        else => {},
    }
    return out.items;
}

/// Appends `node`, or its statements if it is a block.
fn flat(arena: Allocator, tree: *const Ast, node: Node.Index, out: *std.ArrayList(Node.Index)) Allocator.Error!void {
    if (!isBlock(tree, node)) return out.append(arena, node);
    var buffer: [2]Node.Index = undefined;
    try out.appendSlice(arena, tree.blockStatements(&buffer, node).?);
}

fn loopBodies(tree: *const Ast, loop: Node.Index) struct { Node.Index, ?Node.Index } {
    if (tree.fullWhile(loop)) |w| return .{ w.ast.then_expr, w.ast.else_expr.unwrap() };
    const f = tree.fullFor(loop).?;
    return .{ f.ast.then_expr, f.ast.else_expr.unwrap() };
}

/// What `node` is a wrapper of: a declaration's, a `return`'s, an
/// assignment's or a `try`'s value, and so on down.
fn core(tree: *const Ast, node: Node.Index) Node.Index {
    var n = node;
    while (true) {
        n = switch (tree.nodeTag(n)) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => tree.fullVarDecl(n).?.ast.init_node.unwrap() orelse return n,
            .@"return" => tree.nodeData(n).opt_node.unwrap() orelse return n,
            .@"try", .@"comptime", .@"nosuspend", .@"defer", .@"errdefer" => tree.nodeData(n).node,
            .assign => tree.nodeData(n).node_and_node[1],
            else => return n,
        };
    }
}

fn isBlock(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => true,
        else => false,
    };
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
    // The signature, then five statements, two of them on one line; the
    // for, holding 5 of the 6 cognitive, opened into its head and its if.
    try std.testing.expectEqual(7, regions.len);
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
    // The for's head: the for 1, its line, its level. Its if: if and and,
    // the if one level in 2, and 1, the return in the loop 1; for > if.
    try std.testing.expectEqual(Sum{ .cyclomatic = 1, .cognitive = 1, .depth = 0, .lines = 1, .nesting = 1, .structures = 1, .base = 0 }, regions[3].sum);
    try std.testing.expectEqual(Sum{ .cyclomatic = 2, .cognitive = 4, .depth = 1, .lines = 1, .nesting = 2, .structures = 1, .base = 1 }, regions[4].sum);
    try std.testing.expectEqual(1, regions[4].level);
    // Two statements on one line: the line goes to the first.
    try std.testing.expectEqual(1, regions[1].sum.lines);
    try std.testing.expectEqual(0, regions[2].sum.lines);
}

test "a statement that alone adds is opened, its parts a level in; the sums still the totals" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try testing.parse(arena,
        \\fn f(x: u8, ys: []const u8) u8 {
        \\    var n: u8 = 0;
        \\    const v = switch (x) {
        \\        0 => blk: {
        \\            for (ys) |y| {
        \\                if (y == 0) n += 1;
        \\            }
        \\            break :blk n;
        \\        },
        \\        1 => if (n > 0) 1 else 2,
        \\        else => 3,
        \\    };
        \\    return v;
        \\}
    );
    const function = (try testing.functions.list(arena, &tree))[0];
    const facts: Facts = try .of(arena, &tree, function.node);
    const regions = try ofBody(arena, &tree, function.node, facts);
    var got: std.ArrayList(u8) = .empty;
    var cc: u32 = 1;
    var cog: u32 = 0;
    var n: u32 = 0;
    for (regions) |r| {
        cc += r.sum.cyclomatic;
        cog += r.sum.cognitive;
        n += r.sum.lines;
        try got.print(arena, "{d} {d}-{d} +{d} +{d}\n", .{ r.level, tree.tokenLocation(0, r.first).line + 1, tree.tokenLocation(0, r.last).line + 1, r.sum.cyclomatic, r.sum.cognitive });
    }
    try std.testing.expectEqual(try cyclomatic.count(arena, &tree, function.node), cc);
    try std.testing.expectEqual(try cognitive.count(arena, &tree, function.node), cog);
    try std.testing.expectEqual(try lines.count(arena, &tree, function.node), n);
    // The signature, n, then the switch's head (the switch 1) and its
    // prongs, each with its own cyclomatic 1: 0 (for 2, if 3; the labeled
    // block a prong's body, no level), 1 (if 2, its else free), else.
    try std.testing.expectEqualStrings(
        \\0 1-1 +0 +0
        \\0 2-2 +0 +0
        \\0 3-3 +0 +1
        \\1 4-9 +3 +5
        \\1 10-10 +2 +2
        \\1 11-11 +0 +0
        \\0 13-13 +0 +0
        \\
    , got.items);
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

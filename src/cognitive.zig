//! Cognitive complexity: how hard a function is to follow. A structure
//! costs once however many ways it branches, and more the deeper it sits.
//! docs/cognitive.md is the rule book, an example to each rule, and the
//! tests below hold this file to every one of them.
//!
//! An `if`, a `while`, a `for`, a `switch`, and a `catch` or `orelse` whose
//! handler is a block or a `switch` cost 1, and 1 more for each level they
//! sit in. An `else if`, an `else` and a loop's `else` cost 1, but the
//! `else` of an `if` whose branches are both expressions costs nothing.
//! These cost 1 at any depth: each run of `and` or of `or`, a `catch` or
//! `orelse` with a value or a jump for its handler, a labeled block used as
//! a value, a `return` inside a loop or a labeled `switch` (a state
//! machine), a labeled `break` or `continue` that ends a loop, a labeled
//! `switch` or a labeled block on its way, and an `errdefer`. A `catch` or
//! `orelse` with no real handler (`catch unreachable`, `catch {}`,
//! `orelse unreachable`) costs nothing.
//!
//! What opens a level: the branches of an `if` (an `else if` stays on its
//! `if`'s level), a loop's body and `else`, a `switch`'s prongs, a handler
//! that is a block or a `switch`, and a labeled block used as a value.
//!
//! A function declared in a container inside this one is measured on its
//! own, and adds nothing here; the container costs nothing either.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

/// The cognitive complexity of `function`, a `fn_decl` or `test_decl`. The
/// working memory is allocated with `arena`.
pub fn count(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!u32 {
    var w: Walk = .{ .arena = arena, .tree = tree, .sink = null };
    return w.run(function);
}

/// A construct the count charged, or one a reader may expect it to charge
/// that costs nothing, and why.
pub const Cost = struct {
    /// Its keyword, operator or label.
    token: Ast.TokenIndex,
    /// As written: `if`, `else if`, `else`, `inline for`, `switch`,
    /// `catch`, `and`, `blk:`, `return`, `continue :outer`, `errdefer`.
    construct: []const u8,
    adds: u32,
    /// How much of `adds` is for the levels it sits in.
    depth: u32 = 0,
    /// Whether its cost grows with its depth, as an `if`'s does and an
    /// `and`'s does not: moved to a shallower place, it costs less.
    structure: bool = false,
    /// Why it costs what it does, when its kind and depth do not say.
    why: []const u8 = "",

    fn before(_: void, a: Cost, b: Cost) bool {
        return a.token < b.token;
    }
};

/// The count of `function`, as `count` gives it, with each construct it
/// charged appended to `costs` in source order. Allocated with `arena`.
pub fn explain(arena: Allocator, tree: *const Ast, function: Node.Index, costs: *std.ArrayList(Cost)) Allocator.Error!u32 {
    const first = costs.items.len;
    var w: Walk = .{ .arena = arena, .tree = tree, .sink = costs };
    const total = try w.run(function);
    std.mem.sort(Cost, costs.items[first..], {}, Cost.before);
    return total;
}

/// A node still to visit.
const Item = struct {
    node: Node.Index,
    /// The levels it sits in.
    depth: u32,
    /// The innermost loop, labeled `switch` or labeled block it is in, an
    /// index into the frames.
    frame: u32,
    place: Place = .other,

    /// `node` at the same depth and in the same frame.
    fn with(item: Item, node: Node.Index) Item {
        return .{ .node = node, .depth = item.depth, .frame = item.frame, .place = item.place };
    }
};

/// What a node is to the one it is in, where that changes what it costs.
const Place = enum {
    other,
    /// A branch's body or a block handler: a labeled block there is that
    /// branch's level, not a value with a level of its own.
    body,
    /// A statement in a block: a labeled block there is not a value.
    statement,
    /// An `if` that is another's `else`.
    else_if,
};

/// What a jump can end on its way to where it lands.
const Frame = struct {
    kind: Kind,
    label: ?Ast.TokenIndex,
    /// The frame it is in; the function's own, 0, is its own parent.
    parent: u32,

    const Kind = enum { function, loop, @"switch", block };
};

const Walk = struct {
    arena: Allocator,
    tree: *const Ast,
    /// Where each cost goes, when explaining.
    sink: ?*std.ArrayList(Cost),
    total: u32 = 0,
    stack: std.ArrayList(Item) = .empty,
    kids: std.ArrayList(Node.Index) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    /// The operators of one run of `and` and `or`, and what is still to
    /// look through for more.
    ops: std.ArrayList(Node.Index) = .empty,
    region: std.ArrayList(Node.Index) = .empty,

    fn run(w: *Walk, function: Node.Index) Allocator.Error!u32 {
        try w.frames.append(w.arena, .{ .kind = .function, .label = null, .parent = 0 });
        try w.pushChildren(function, 0, 0, .other);
        while (w.stack.pop()) |item| try w.visit(item);
        return w.total;
    }

    fn visit(w: *Walk, item: Item) Allocator.Error!void {
        switch (w.tree.nodeTag(item.node)) {
            // Measured on their own.
            .fn_decl, .test_decl => {},
            .if_simple, .@"if" => try w.ifElse(item),
            .while_simple, .while_cont, .@"while", .for_simple, .@"for" => try w.loop(item),
            .@"switch", .switch_comma => try w.switchOn(item, true),
            .@"catch", .@"orelse" => try w.handler(item),
            .block_two, .block_two_semicolon, .block, .block_semicolon => try w.block(item),
            .bool_and, .bool_or => try w.logic(item),
            .@"break", .@"continue", .@"return" => try w.jump(item),
            .@"errdefer" => {
                try w.add(.{ .token = w.tree.nodeMainToken(item.node), .construct = "errdefer", .adds = 1, .why = "a branch taken only on the error path" });
                try w.pushChildren(item.node, item.depth, item.frame, .other);
            },
            else => try w.pushChildren(item.node, item.depth, item.frame, .other),
        }
    }

    fn ifElse(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const full = tree.fullIf(item.node).?;
        const d = item.depth;
        if (item.place == .else_if) {
            try w.add(.{ .token = full.ast.if_token, .construct = "else if", .adds = 1 });
        } else try w.add(.{ .token = full.ast.if_token, .construct = "if", .adds = 1 + d, .depth = d, .structure = true });
        try w.push(.{ .node = full.ast.cond_expr, .depth = d, .frame = item.frame });
        try w.push(.{ .node = full.ast.then_expr, .depth = d + 1, .frame = item.frame, .place = .body });
        const e = full.ast.else_expr.unwrap() orelse return;
        switch (tree.nodeTag(e)) {
            .if_simple, .@"if" => return w.push(.{ .node = e, .depth = d, .frame = item.frame, .place = .else_if }),
            else => {},
        }
        if (isBlock(tree, full.ast.then_expr) or isBlock(tree, e)) {
            try w.add(.{ .token = full.else_token, .construct = "else", .adds = 1 });
        } else try w.add(.{ .token = full.else_token, .construct = "else", .adds = 0, .why = "both branches are expressions: one choice of two values" });
        try w.push(.{ .node = e, .depth = d + 1, .frame = item.frame, .place = .body });
    }

    fn loop(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const d = item.depth;
        const parts = try w.loopParts(item);
        try w.add(.{ .token = parts.keyword, .construct = try w.text(&.{ if (parts.inline_token != null) "inline " else "", tree.tokenSlice(parts.keyword) }), .adds = 1 + d, .depth = d, .structure = true });
        // A jump from the body ends the loop; one from its else does not,
        // the loop being over by then.
        const frame = try w.open(item.frame, .loop, parts.label);
        try w.push(.{ .node = parts.body, .depth = d + 1, .frame = frame, .place = .body });
        const e = parts.@"else" orelse return;
        try w.add(.{ .token = parts.else_token.?, .construct = "else", .adds = 1, .why = "a loop's else" });
        try w.push(.{ .node = e, .depth = d + 1, .frame = item.frame, .place = .body });
    }

    /// The parts of a `while` or `for` that differ in shape, having pushed
    /// what comes before its body: the condition, the continue expression,
    /// the inputs.
    fn loopParts(w: *Walk, item: Item) Allocator.Error!LoopParts {
        const tree = w.tree;
        const at: Item = .{ .node = undefined, .depth = item.depth, .frame = item.frame };
        if (tree.fullWhile(item.node)) |full| {
            try w.push(at.with(full.ast.cond_expr));
            if (full.ast.cont_expr.unwrap()) |cont| try w.push(at.with(cont));
            return .{ .keyword = full.ast.while_token, .inline_token = full.inline_token, .label = full.label_token, .body = full.ast.then_expr, .@"else" = full.ast.else_expr.unwrap(), .else_token = full.else_token };
        }
        const full = tree.fullFor(item.node).?;
        for (full.ast.inputs) |input| try w.push(at.with(input));
        return .{ .keyword = full.ast.for_token, .inline_token = full.inline_token, .label = full.label_token, .body = full.ast.then_expr, .@"else" = full.ast.else_expr.unwrap(), .else_token = full.else_token };
    }

    /// A `switch`. One that is the handler of a `catch` or `orelse` is one
    /// structure with it, which has cost what the two do (`own` false).
    fn switchOn(w: *Walk, item: Item, own: bool) Allocator.Error!void {
        const tree = w.tree;
        const full = tree.fullSwitch(item.node).?;
        const d = item.depth;
        if (own) {
            try w.add(.{ .token = full.ast.switch_token, .construct = "switch", .adds = 1 + d, .depth = d, .structure = true });
        } else try w.add(.{ .token = full.ast.switch_token, .construct = "switch", .adds = 0, .why = "the handler: one structure with its catch or orelse" });
        try w.push(.{ .node = full.ast.condition, .depth = d, .frame = item.frame });
        const frame = if (full.label_token) |label| try w.open(item.frame, .@"switch", label) else item.frame;
        for (full.ast.cases) |case| {
            const prong = tree.fullSwitchCase(case).?;
            for (prong.ast.values) |value| try w.push(.{ .node = value, .depth = d + 1, .frame = frame });
            try w.push(.{ .node = prong.ast.target_expr, .depth = d + 1, .frame = frame, .place = .body });
        }
    }

    /// A `catch` or `orelse`, by what its handler is.
    fn handler(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const d = item.depth;
        const keyword = tree.nodeMainToken(item.node);
        const name = tree.tokenSlice(keyword);
        const lhs, const rhs = tree.nodeData(item.node).node_and_node;
        try w.push(.{ .node = lhs, .depth = d, .frame = item.frame });
        switch (handlerKind(tree, item.node, rhs)) {
            .none => try w.add(.{ .token = keyword, .construct = name, .adds = 0, .why = noHandler(tree, item.node, rhs) }),
            .value => {
                try w.add(.{ .token = keyword, .construct = name, .adds = 1, .why = "a value or a jump for its handler" });
                try w.push(.{ .node = rhs, .depth = d, .frame = item.frame });
            },
            .block => {
                try w.add(.{ .token = keyword, .construct = name, .adds = 1 + d, .depth = d, .structure = true });
                try w.push(.{ .node = rhs, .depth = d + 1, .frame = item.frame, .place = .body });
            },
            .@"switch" => {
                try w.add(.{ .token = keyword, .construct = name, .adds = 1 + d, .depth = d, .structure = true });
                try w.switchOn(.{ .node = rhs, .depth = d, .frame = item.frame }, false);
            },
        }
    }

    /// A block: a labeled one is what a jump can end, and one used as a
    /// value costs 1 and is a level.
    fn block(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const label = blockLabel(tree, item.node) orelse return w.pushChildren(item.node, item.depth, item.frame, .statement);
        const frame = try w.open(item.frame, .block, label);
        if (item.place != .other) return w.pushChildren(item.node, item.depth, frame, .statement);
        try w.add(.{ .token = label, .construct = try w.text(&.{ tree.tokenSlice(label), ":" }), .adds = 1, .why = "a labeled block used as a value" });
        try w.pushChildren(item.node, item.depth + 1, frame, .statement);
    }

    /// The whole of an `and` and `or` expression `item` heads, through
    /// parentheses and `!`: each run of one operator in it, in source
    /// order, costs 1. What the operators join is visited as any node.
    fn logic(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        w.ops.clearRetainingCapacity();
        w.region.clearRetainingCapacity();
        try w.region.append(w.arena, item.node);
        while (w.region.pop()) |node| switch (tree.nodeTag(node)) {
            .bool_and, .bool_or => {
                try w.ops.append(w.arena, node);
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                try w.region.appendSlice(w.arena, &.{ lhs, rhs });
            },
            .grouped_expression => try w.region.append(w.arena, tree.nodeData(node).node_and_token[0]),
            .bool_not => try w.region.append(w.arena, tree.nodeData(node).node),
            else => try w.push(.{ .node = node, .depth = item.depth, .frame = item.frame }),
        };
        std.mem.sort(Node.Index, w.ops.items, tree, mainTokenBefore);
        // .root is never an operator: the first one starts a run.
        var last: Node.Tag = .root;
        for (w.ops.items) |op| {
            const tag = tree.nodeTag(op);
            if (tag == last) continue;
            last = tag;
            try w.add(.{ .token = tree.nodeMainToken(op), .construct = tree.tokenSlice(tree.nodeMainToken(op)), .adds = 1 });
        }
    }

    /// A `return`, `break` or `continue`: 1 when it ends more than the
    /// construct it names, the function for a `return`.
    fn jump(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const keyword = tree.nodeMainToken(item.node);
        try w.pushChildren(item.node, item.depth, item.frame, .other);
        if (tree.nodeTag(item.node) == .@"return") {
            if (w.endedByReturn(item.frame)) |why| try w.add(.{ .token = keyword, .construct = "return", .adds = 1, .why = why });
            return;
        }
        const label = tree.nodeData(item.node).opt_token_and_opt_node[0].unwrap() orelse return;
        const construct = try w.text(&.{ tree.tokenSlice(keyword), " :", tree.tokenSlice(label) });
        if (w.passed(item.frame, label)) |kind| {
            try w.add(.{ .token = keyword, .construct = construct, .adds = 1, .why = switch (kind) {
                .loop => "it ends a loop on its way",
                .@"switch" => "it ends a labeled switch on its way",
                .block, .function => "it ends a labeled block on its way",
            } });
        } else try w.add(.{ .token = keyword, .construct = construct, .adds = 0, .why = "nothing stands between it and its label" });
    }

    /// What the innermost loop, labeled `switch` or labeled block between
    /// `from` and the one `label` names is, if one is.
    fn passed(w: *Walk, from: u32, label: Ast.TokenIndex) ?Frame.Kind {
        const name = w.tree.tokenSlice(label);
        var first: ?Frame.Kind = null;
        var f = from;
        while (f != 0) : (f = w.frames.items[f].parent) {
            const frame = w.frames.items[f];
            if (frame.label) |l| if (std.mem.eql(u8, w.tree.tokenSlice(l), name)) return first;
            first = first orelse frame.kind;
        }
        return null;
    }

    /// What a `return` at `from` ends besides the function, said as why it
    /// costs: the innermost loop or labeled `switch` around it, if any.
    fn endedByReturn(w: *Walk, from: u32) ?[]const u8 {
        var f = from;
        while (f != 0) : (f = w.frames.items[f].parent) {
            switch (w.frames.items[f].kind) {
                .loop => return "inside a loop: it ends the loop too",
                .@"switch" => return "inside a labeled switch: it ends the state machine too",
                .function, .block => {},
            }
        }
        return null;
    }

    fn open(w: *Walk, parent: u32, kind: Frame.Kind, label: ?Ast.TokenIndex) Allocator.Error!u32 {
        try w.frames.append(w.arena, .{ .kind = kind, .label = label, .parent = parent });
        return @intCast(w.frames.items.len - 1);
    }

    fn add(w: *Walk, cost: Cost) Allocator.Error!void {
        w.total += cost.adds;
        if (w.sink) |costs| try costs.append(w.arena, cost);
    }

    /// `parts` joined, for an explanation; nothing when only counting.
    fn text(w: *Walk, parts: []const []const u8) Allocator.Error![]const u8 {
        if (w.sink == null) return "";
        return std.mem.concat(w.arena, u8, parts);
    }

    fn push(w: *Walk, item: Item) Allocator.Error!void {
        try w.stack.append(w.arena, item);
    }

    /// Pushes every child of `node`, each at `place`.
    fn pushChildren(w: *Walk, node: Node.Index, depth: u32, frame: u32, place: Place) Allocator.Error!void {
        w.kids.clearRetainingCapacity();
        try children.append(w.arena, w.tree, node, &w.kids);
        for (w.kids.items) |kid| try w.push(.{ .node = kid, .depth = depth, .frame = frame, .place = place });
    }
};

const LoopParts = struct {
    keyword: Ast.TokenIndex,
    inline_token: ?Ast.TokenIndex,
    label: ?Ast.TokenIndex,
    body: Node.Index,
    @"else": ?Node.Index,
    else_token: ?Ast.TokenIndex,
};

fn mainTokenBefore(tree: *const Ast, a: Node.Index, b: Node.Index) bool {
    return tree.nodeMainToken(a) < tree.nodeMainToken(b);
}

const Handler = enum { none, value, block, @"switch" };

/// What the handler of the `catch` or `orelse` `node` is. No real handler
/// is the same set the cyclomatic count leaves out.
fn handlerKind(tree: *const Ast, node: Node.Index, handler: Node.Index) Handler {
    return switch (tree.nodeTag(handler)) {
        .unreachable_literal => .none,
        .@"switch", .switch_comma => .@"switch",
        .block_two, .block_two_semicolon, .block, .block_semicolon => if (tree.nodeTag(node) == .@"catch" and isEmpty(tree, handler)) .none else .block,
        else => .value,
    };
}

fn noHandler(tree: *const Ast, node: Node.Index, handler: Node.Index) []const u8 {
    if (tree.nodeTag(node) == .@"orelse") return "orelse unreachable has no other path: it is .?";
    if (tree.nodeTag(handler) == .unreachable_literal) return "catch unreachable has no handler";
    return "catch {} has no handler";
}

fn isBlock(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => true,
        else => false,
    };
}

fn isEmpty(tree: *const Ast, block: Node.Index) bool {
    var buffer: [2]Node.Index = undefined;
    return tree.blockStatements(&buffer, block).?.len == 0;
}

/// The label of the block `node`, as `blk` is of `blk: {`, if it has one.
fn blockLabel(tree: *const Ast, node: Node.Index) ?Ast.TokenIndex {
    const lbrace = tree.nodeMainToken(node);
    if (lbrace < 2 or tree.tokenTag(lbrace - 1) != .colon or tree.tokenTag(lbrace - 2) != .identifier) return null;
    return lbrace - 2;
}

const testing = struct {
    const functions = @import("functions.zig");

    /// Each function in `source` with its count, a line each as `name
    /// count`; and checks each explanation adds up to its count.
    fn counts(arena: Allocator, source: []const u8) ![]const u8 {
        const tree = try parse(arena, source);
        var got: std.ArrayList(u8) = .empty;
        for (try functions.list(arena, &tree)) |function| {
            const total = try count(arena, &tree, function.node);
            try got.print(arena, "{s} {d}\n", .{ function.name, total });
            var costs: std.ArrayList(Cost) = .empty;
            try std.testing.expectEqual(total, try explain(arena, &tree, function.node, &costs));
            var sum: u32 = 0;
            for (costs.items) |cost| sum += cost.adds;
            try std.testing.expectEqual(total, sum);
        }
        return got.items;
    }

    fn parse(arena: Allocator, source: []const u8) !Ast {
        const tree = try Ast.parse(arena, try arena.dupeSentinel(u8, source, 0), .{});
        try std.testing.expectEqual(0, tree.errors.len);
        return tree;
    }

    /// The costs of every function in `source` summed by line, from 1.
    fn costsByLine(arena: Allocator, source: []const u8) ![]u32 {
        const tree = try parse(arena, source);
        const by_line = try arena.alloc(u32, std.mem.countScalar(u8, source, '\n') + 2);
        @memset(by_line, 0);
        for (try functions.list(arena, &tree)) |function| {
            var costs: std.ArrayList(Cost) = .empty;
            _ = try explain(arena, &tree, function.node, &costs);
            for (costs.items) |cost| by_line[tree.tokenLocation(0, cost.token).line + 1] += cost.adds;
        }
        return by_line;
    }

    /// What the comment on each line of an example says its line costs:
    /// the sum of the numbers in it (`// 3, and 1: a return inside a
    /// loop` is 4), and 0 for a line with no comment.
    fn saidByLine(arena: Allocator, source: []const u8) ![]u32 {
        const by_line = try arena.alloc(u32, std.mem.countScalar(u8, source, '\n') + 2);
        @memset(by_line, 0);
        var lines = std.mem.splitScalar(u8, source, '\n');
        var n: usize = 1;
        while (lines.next()) |line| : (n += 1) {
            const comment = line[(std.mem.find(u8, line, "//") orelse continue)..];
            var digits = std.mem.tokenizeAny(u8, comment, "/abcdefghijklmnopqrstuvwxyz:;,. ");
            while (digits.next()) |word| by_line[n] += std.fmt.parseInt(u32, word, 10) catch 0;
        }
        return by_line;
    }

    /// The number `sentence` gives the function `name`: `Cognitive N` for
    /// the first in an example, `` `name` has its own N `` for another.
    fn said(sentence: []const u8, name: []const u8, first: bool, arena: Allocator) !u32 {
        const after = if (first) "Cognitive " else try std.mem.concat(arena, u8, &.{ "`", name, "` has its own " });
        const at = (std.mem.find(u8, sentence, after) orelse return error.NotSaid) + after.len;
        var end = at;
        while (end < sentence.len and std.ascii.isDigit(sentence[end])) end += 1;
        return std.fmt.parseInt(u32, sentence[at..end], 10);
    }
};

test "every example in docs/cognitive.md: its count, and each line's costs as its comment gives them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/cognitive.md", arena, .limited(1 << 20));

    var examples: usize = 0;
    var rest: []const u8 = doc;
    while (std.mem.find(u8, rest, "```zig\n")) |open| : (examples += 1) {
        const start = open + "```zig\n".len;
        const end = std.mem.findPos(u8, rest, start, "```\n") orelse return error.Unclosed;
        const source = rest[start..end];
        rest = std.mem.trimStart(u8, rest[end + "```\n".len ..], "\n");
        const sentence = rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len];

        const tree = try testing.parse(arena, source);
        for (try testing.functions.list(arena, &tree), 0..) |function, i| {
            const want = try testing.said(sentence, function.name, i == 0, arena);
            const got = try count(arena, &tree, function.node);
            if (got != want) std.debug.print("{s}: {d}, the document says {d}\n", .{ function.name, got, want });
            try std.testing.expectEqual(want, got);
        }
        const by_line = try testing.costsByLine(arena, source);
        const comments = try testing.saidByLine(arena, source);
        for (by_line, comments, 0..) |got, want, line| {
            if (got != want) std.debug.print("example {d}, line {d}: costs {d}, its comment says {d}\n", .{ examples + 1, line, got, want });
            try std.testing.expectEqual(want, got);
        }
    }
    try std.testing.expectEqual(21, examples);
}

/// Checks each function in `source` has its expected count, given a line
/// each as `name count`.
fn expectCounts(source: []const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(expected, try testing.counts(arena_state.allocator(), source));
}

// The cases the document's examples leave open. Each count is worked out
// by hand in the comment beside it.

test "a catch whose handler is a switch costs as a switch, by its depth" {
    try expectCounts(
        \\fn inLoop(xs: []const u8) void {
        \\    for (xs) |x| {
        \\        use(x) catch |err| switch (err) {
        \\            error.A => if (x == 0) skip(),
        \\            else => {},
        \\        };
        \\    }
        \\}
    ,
        // for 1; catch one level in 2, its switch nothing; if two levels in 3.
        \\inLoop 6
        \\
    );
}

test "an else chain of expressions: else if 1, the last else nothing" {
    try expectCounts(
        \\fn chain(a: bool, b: bool) u8 {
        \\    return if (a) 1 else if (b) 2 else 3;
        \\}
        \\fn statement(c: bool) void {
        \\    if (c) a() else b();
        \\}
        \\fn mixed(c: bool) void {
        \\    if (c) a() else {
        \\        b();
        \\    }
        \\}
    ,
        // if 1, else if 1; if 1; if 1, else 1 (a block).
        \\chain 2
        \\statement 1
        \\mixed 2
        \\
    );
}

test "a run of and or or goes through parentheses and !, and ends at a call" {
    try expectCounts(
        \\fn grouped(a: bool, b: bool, c: bool) bool {
        \\    return a and (b and c);
        \\}
        \\fn alternating(a: bool, b: bool, c: bool, d: bool) bool {
        \\    return a and (b or c) and d;
        \\}
        \\fn negated(a: bool, b: bool, c: bool) bool {
        \\    return !(a and b) and c;
        \\}
        \\fn called(a: bool, b: bool, c: bool) bool {
        \\    return f(a and b) or c;
        \\}
    ,
        // and; and, or, and again; and; or, and the and in the call its own.
        \\grouped 1
        \\alternating 3
        \\negated 1
        \\called 2
        \\
    );
}

test "a labeled block as a statement or a branch's body costs nothing itself" {
    try expectCounts(
        \\fn statement(c: bool) void {
        \\    blk: {
        \\        if (c) break :blk;
        \\        work();
        \\    }
        \\}
        \\fn body(c: bool, d: bool) u8 {
        \\    return if (c) r: {
        \\        if (d) break :r 1;
        \\        break :r 2;
        \\    } else 3;
        \\}
        \\fn passed(xs: []const u8) void {
        \\    blk: {
        \\        for (xs) |x| {
        \\            if (x == 0) break :blk;
        \\        }
        \\    }
        \\}
    ,
        // if, its break to the block it is in free; if 1, if one level in
        // 2, else 1 (a block); for 1, if 2, break past the loop 1.
        \\statement 1
        \\body 4
        \\passed 4
        \\
    );
}

test "a jump from a loop's else does not end the loop; one to its own loop is free" {
    try expectCounts(
        \\fn afterLoop(xs: []const u8) u8 {
        \\    for (xs) |x| {
        \\        use(x);
        \\    } else return 0;
        \\}
        \\fn toItself(xs: []const u8) void {
        \\    outer: for (xs) |x| {
        \\        if (x == 0) continue :outer;
        \\    }
        \\}
    ,
        // for 1, else 1, the return after the loop free; for 1, if 2.
        \\afterLoop 2
        \\toItself 3
        \\
    );
}

test "comptime code counts as any other; a container inside costs nothing" {
    try expectCounts(
        \\fn generic(comptime T: type) void {
        \\    comptime {
        \\        if (T == u8) check();
        \\    }
        \\    inline for (.{ 1, 2 }) |n| _ = n;
        \\    const S = struct {
        \\        n: u8 = 0,
        \\        fn inner(c: bool) void {
        \\            if (c) {}
        \\        }
        \\    };
        \\    _ = S;
        \\}
    ,
        // if 1, inline for 1; inner on its own: if 1.
        \\generic 2
        \\generic.S.inner 1
        \\
    );
}

test "a return from a labeled switch ends the machine, and a labeled block is no loop" {
    try expectCounts(
        \\fn machine(s: S) void {
        \\    sw: switch (s) {
        \\        .a => continue :sw .b,
        \\        .b => return,
        \\    }
        \\}
    ,
        // switch 1; the continue straight from a prong free; the return
        // ends the machine, 1.
        \\machine 2
        \\
    );
    try expectCounts(
        \\fn value(c: bool) u8 {
        \\    const v = blk: {
        \\        if (c) return 0;
        \\        break :blk 1;
        \\    };
        \\    return v;
        \\}
    ,
        // blk 1; if one level in 2; a return from a labeled block ends no
        // loop or machine, so is free.
        \\value 3
        \\
    );
}

test "a test block is measured as a function is" {
    try expectCounts(
        \\test "t" {
        \\    for (xs) |x| {
        \\        if (x) {}
        \\    }
        \\}
    ,
        \\test "t" 3
        \\
    );
}

test "explain: each cost where it is, its depth, and why the free ones are free" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try testing.parse(arena,
        \\fn f(xs: []const u8, m: *Map) !u8 {
        \\    errdefer m.clear();
        \\    outer: for (xs) |x| {
        \\        const v = m.get(x) orelse unreachable;
        \\        for (xs) |y| {
        \\            if (y == v and x > 0) continue :outer else continue;
        \\        }
        \\        work() catch {};
        \\        return blk: {
        \\            break :blk if (x == 0) 1 else 2;
        \\        };
        \\    }
        \\    return 0;
        \\}
    );
    const function = (try testing.functions.list(arena, &tree))[0];
    var costs: std.ArrayList(Cost) = .empty;
    try std.testing.expectEqual(14, try explain(arena, &tree, function.node, &costs));
    var got: std.ArrayList(u8) = .empty;
    for (costs.items) |cost| {
        const loc = tree.tokenLocation(0, cost.token);
        try got.print(arena, "{d}:{d} {s} {d} {d}{s}{s}\n", .{ loc.line + 1, loc.column + 1, cost.construct, cost.adds, cost.depth, if (cost.why.len > 0) " " else "", cost.why });
    }
    try std.testing.expectEqualStrings(
        \\2:5 errdefer 1 0 a branch taken only on the error path
        \\3:12 for 1 0
        \\4:28 orelse 0 0 orelse unreachable has no other path: it is .?
        \\5:9 for 2 1
        \\6:13 if 3 2
        \\6:24 and 1 0
        \\6:35 continue :outer 1 0 it ends a loop on its way
        \\6:51 else 0 0 both branches are expressions: one choice of two values
        \\8:16 catch 0 0 catch {} has no handler
        \\9:9 return 1 0 inside a loop: it ends the loop too
        \\9:16 blk: 1 0 a labeled block used as a value
        \\10:13 break :blk 0 0 nothing stands between it and its label
        \\10:24 if 3 2
        \\10:38 else 0 0 both branches are expressions: one choice of two values
        \\
    , got.items);
}

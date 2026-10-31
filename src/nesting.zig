//! Nesting depth: how many levels deep a function's code goes. A function
//! of straight-line code is 0; an `if` in its body is 1, an `if` in that
//! `if` is 2.
//!
//! Each of these opens a level for what is inside it: an `if` (its
//! branches, not its condition), a `while` and a `for` (their bodies and
//! `else`), a `switch` (its prongs), a labeled block, a container declared
//! in the function, and a `catch` or `orelse` whose handler is a block
//! with something in it. An `else if` is on its `if`'s level, not inside
//! it.
//!
//! These open none: a plain block, whether a branch's body or one written
//! on its own to scope a `defer`; a labeled block that is a branch's body,
//! which is the branch's level already; a `defer` or `errdefer`; and a
//! `catch` or `orelse` whose handler is a value or a jump.
//!
//! A function declared in a container inside this one is measured on its
//! own, from 0. The container is a level of this one.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

/// A node still to visit.
const Item = struct {
    node: Node.Index,
    /// The levels it is inside.
    depth: u32,
    /// Whether it is a branch's body: then a block is that branch's level,
    /// labeled or not.
    body: bool,
};

/// The nesting depth of `function`, a `fn_decl` or `test_decl`. The working
/// memory is allocated with `arena`.
pub fn depth(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!u32 {
    var w: Walk = .{ .arena = arena, .tree = tree };
    try w.pushChildren(function, 0);
    while (w.stack.pop()) |item| try w.visit(item);
    return w.deepest;
}

const Walk = struct {
    arena: Allocator,
    tree: *const Ast,
    stack: std.ArrayList(Item) = .empty,
    kids: std.ArrayList(Node.Index) = .empty,
    deepest: u32 = 0,

    fn visit(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const node = item.node;
        const d = item.depth;
        switch (tree.nodeTag(node)) {
            // Measured on their own.
            .fn_decl, .test_decl => {},

            .if_simple, .@"if" => {
                const full = tree.fullIf(node).?;
                w.reach(d + 1);
                try w.push(full.ast.cond_expr, d, false);
                try w.push(full.ast.then_expr, d + 1, true);
                if (full.ast.else_expr.unwrap()) |e| switch (tree.nodeTag(e)) {
                    .if_simple, .@"if" => try w.push(e, d, false),
                    else => try w.push(e, d + 1, true),
                };
            },

            .while_simple, .while_cont, .@"while" => {
                const full = tree.fullWhile(node).?;
                w.reach(d + 1);
                try w.push(full.ast.cond_expr, d, false);
                if (full.ast.cont_expr.unwrap()) |cont| try w.push(cont, d, false);
                try w.push(full.ast.then_expr, d + 1, true);
                if (full.ast.else_expr.unwrap()) |e| try w.push(e, d + 1, true);
            },

            .for_simple, .@"for" => {
                const full = tree.fullFor(node).?;
                w.reach(d + 1);
                for (full.ast.inputs) |input| try w.push(input, d, false);
                try w.push(full.ast.then_expr, d + 1, true);
                if (full.ast.else_expr.unwrap()) |e| try w.push(e, d + 1, true);
            },

            .@"switch", .switch_comma => {
                const full = tree.fullSwitch(node).?;
                w.reach(d + 1);
                try w.push(full.ast.condition, d, false);
                for (full.ast.cases) |case| try w.push(case, d + 1, false);
            },

            .switch_case_one,
            .switch_case_inline_one,
            .switch_case,
            .switch_case_inline,
            => {
                const full = tree.fullSwitchCase(node).?;
                for (full.ast.values) |value| try w.push(value, d, false);
                try w.push(full.ast.target_expr, d, true);
            },

            .@"catch", .@"orelse" => {
                const lhs, const handler = tree.nodeData(node).node_and_node;
                try w.push(lhs, d, false);
                if (isFullBlock(tree, handler)) {
                    w.reach(d + 1);
                    try w.push(handler, d + 1, true);
                } else try w.push(handler, d, false);
            },

            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            => {
                const level = if (!item.body and isLabeled(tree, node)) d + 1 else d;
                w.reach(level);
                try w.pushChildren(node, level);
            },

            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                w.reach(d + 1);
                try w.pushChildren(node, d + 1);
            },

            else => try w.pushChildren(node, d),
        }
    }

    fn reach(w: *Walk, level: u32) void {
        w.deepest = @max(w.deepest, level);
    }

    fn push(w: *Walk, node: Node.Index, d: u32, body: bool) Allocator.Error!void {
        try w.stack.append(w.arena, .{ .node = node, .depth = d, .body = body });
    }

    /// Pushes every child of `node` at depth `d`, none of them a body.
    fn pushChildren(w: *Walk, node: Node.Index, d: u32) Allocator.Error!void {
        w.kids.clearRetainingCapacity();
        try children.append(w.arena, w.tree, node, &w.kids);
        for (w.kids.items) |kid| try w.push(kid, d, false);
    }
};

/// Whether `node` is a block with a statement in it.
fn isFullBlock(tree: *const Ast, node: Node.Index) bool {
    var buffer: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node) orelse return false;
    return statements.len > 0;
}

/// Whether the block `node` has a label, as `blk: {` does.
fn isLabeled(tree: *const Ast, node: Node.Index) bool {
    const lbrace = tree.nodeMainToken(node);
    return lbrace >= 2 and tree.tokenTag(lbrace - 1) == .colon and tree.tokenTag(lbrace - 2) == .identifier;
}

/// Checks each function in `source` has its expected depth, given a line
/// each as `name depth`.
fn expectDepths(source: [:0]const u8, expected: []const u8) !void {
    const functions = @import("functions.zig");
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var got: std.ArrayList(u8) = .empty;
    for (try functions.list(arena, &tree)) |function| {
        try got.print(arena, "{s} {d}\n", .{ function.name, try depth(arena, &tree, function.node) });
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

// One test per construct. Each depth is worked out by hand in the comment
// beside it.

test "straight-line code is 0" {
    try expectDepths(
        \\fn f() !void {
        \\    try a();
        \\    b();
        \\}
    ,
        \\f 0
        \\
    );
}

test "an if is a level, an if in it another; else if stays on its if's level" {
    try expectDepths(
        \\fn one(c: bool) void {
        \\    if (c) a();
        \\}
        \\fn two(c: bool, d: bool) void {
        \\    if (c) {
        \\        if (d) a();
        \\    }
        \\}
        \\fn chain(x: u8) void {
        \\    if (x == 0) a() else if (x == 1) b() else if (x == 2) c() else d();
        \\}
        \\fn inElse(c: bool, d: bool) void {
        \\    if (c) a() else {
        \\        if (d) b();
        \\    }
        \\}
        \\fn asValue(c: bool) u8 {
        \\    return if (c) 1 else 2;
        \\}
        \\fn inCondition(c: bool) void {
        \\    if (if (c) true else false) a();
        \\}
    ,
        // if; if > if; three ifs on one level; else > if; if; if in an if's
        // condition is not inside it.
        \\one 1
        \\two 2
        \\chain 1
        \\inElse 2
        \\asValue 1
        \\inCondition 1
        \\
    );
}

test "while and for are a level for their body and else" {
    try expectDepths(
        \\fn loops(xs: []const u8, c: bool) void {
        \\    for (xs) |x| {
        \\        while (c) : (a(x)) {} else {
        \\            if (c) b();
        \\        }
        \\    }
        \\}
    ,
        // for > while's else > if.
        \\loops 3
        \\
    );
}

test "a switch is a level for its prongs, and a prong's body is that level" {
    try expectDepths(
        \\fn prongs(x: E, c: bool) void {
        \\    switch (x) {
        \\        .a => if (c) a(),
        \\        .b => {
        \\            b();
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\fn flat(x: E) u8 {
        \\    return switch (x) {
        \\        .a => 1,
        \\        .b => 2,
        \\    };
        \\}
    ,
        // switch > if; switch.
        \\prongs 2
        \\flat 1
        \\
    );
}

test "a labeled block is a level, unless it is a branch's body; a plain block never is" {
    try expectDepths(
        \\fn labeled(c: bool) u8 {
        \\    const v = blk: {
        \\        if (c) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\    return v;
        \\}
        \\fn asBody(c: bool, d: bool) u8 {
        \\    return if (c) r: {
        \\        if (d) break :r 1;
        \\        break :r 2;
        \\    } else 3;
        \\}
        \\fn plain(c: bool) void {
        \\    {
        \\        defer a();
        \\        if (c) b();
        \\    }
        \\}
    ,
        // blk > if; if (its body r: is its level) > if; the block adds
        // nothing > if.
        \\labeled 2
        \\asBody 2
        \\plain 1
        \\
    );
}

test "a catch or orelse is a level when its handler is a block with something in it" {
    try expectDepths(
        \\fn block() !void {
        \\    work() catch |err| {
        \\        if (bad(err)) return err;
        \\    };
        \\}
        \\fn value(opt: ?u8) u8 {
        \\    const n = parse() catch 0;
        \\    const m = opt orelse return 1;
        \\    work() catch {};
        \\    return n + m;
        \\}
        \\fn handlerSwitch() u8 {
        \\    return parse() catch |e| switch (e) {
        \\        error.A => 1,
        \\        else => 2,
        \\    };
        \\}
        \\fn orelseBlock(opt: ?u8) u8 {
        \\    return opt orelse {
        \\        log();
        \\        return 0;
        \\    };
        \\}
    ,
        // catch's block > if; no level; the switch only; orelse's block.
        \\block 2
        \\value 0
        \\handlerSwitch 1
        \\orelseBlock 1
        \\
    );
}

test "defer, errdefer and comptime blocks add no level" {
    try expectDepths(
        \\fn deferred(c: bool) !void {
        \\    defer {
        \\        if (c) a();
        \\    }
        \\    errdefer if (c) b();
        \\    comptime {
        \\        if (debug) check();
        \\    }
        \\}
    ,
        // Each if is at 1.
        \\deferred 1
        \\
    );
}

test "a container declared inside is a level; its functions are measured on their own" {
    try expectDepths(
        \\fn outer(xs: []const u8) void {
        \\    const S = struct {
        \\        fn inner(c: bool) void {
        \\            if (c) {
        \\                if (c) a();
        \\            }
        \\        }
        \\    };
        \\    for (xs) |_| {
        \\        const T = struct { n: u8 = 0 };
        \\        _ = T;
        \\    }
        \\    S.inner(true);
        \\}
    ,
        // for > struct; inner: if > if, from 0.
        \\outer 2
        \\outer.S.inner 2
        \\
    );
}

test "a test block is measured as a function is" {
    try expectDepths(
        \\test "t" {
        \\    for (xs) |x| {
        \\        if (x) {}
        \\    }
        \\}
    ,
        \\test "t" 2
        \\
    );
}

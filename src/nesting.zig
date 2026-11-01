//! Nesting depth: how many levels deep a function's code goes. A function
//! of straight-line code is 0; an `if` in its body is 1, an `if` in that
//! `if` is 2.
//!
//! Each of these opens a level for what is inside it: an `if` (its
//! branches, not its condition), a `while` and a `for` (their bodies and
//! `else`), a `switch` (its prongs), a labeled block, a container declared
//! in the function's body (one in its signature, as a return or a
//! parameter's type, is not, nor one it returns), and a `catch` or
//! `orelse` whose handler is a block with something in it. An `else if` is
//! on its `if`'s level, not inside it.
//!
//! These open none: a plain block, whether a branch's body or one written
//! on its own to scope a `defer`; a labeled block that is a branch's body,
//! which is the branch's level already; a `defer` or `errdefer`; and a
//! `catch` or `orelse` whose handler is a value or a jump.
//!
//! A function declared in a container inside this one is measured on its
//! own, from 0. The container is a level of this one. A container the
//! function returns, as `return struct {...};`, is the type it makes, not
//! code it runs: no level, and nothing in it is one.

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
    /// The innermost construct it is inside, an index into the frames.
    frame: u32,
    /// Whether it is a branch's body: then a block is that branch's level,
    /// labeled or not.
    body: bool = false,
    /// Whether it is an if that is another if's else.
    else_if: bool = false,
};

/// A construct that opens a level.
pub const Level = struct {
    /// Its keyword, operator or label.
    token: Ast.TokenIndex,
    /// As written: `if`, `else if`, `inline for`, `switch`, `blk:`,
    /// `struct`, `catch`.
    construct: []const u8,
    /// The level it opens: 1 for one in the function's body.
    level: u32,
};

const Frame = struct {
    level: Level,
    /// The frame it is inside; the function's own, 0, is its own parent.
    parent: u32,
};

/// The nesting depth of `function`, a `fn_decl` or `test_decl`. The working
/// memory is allocated with `arena`.
pub fn depth(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!u32 {
    var w: Walk = .{ .arena = arena, .tree = tree };
    return w.run(function);
}

/// Every construct in `function` that opens a level, appended to `out` in
/// no particular order; returns the depth, as `depth` gives it.
pub fn levels(arena: Allocator, tree: *const Ast, function: Node.Index, out: *std.ArrayList(Level)) Allocator.Error!u32 {
    var w: Walk = .{ .arena = arena, .tree = tree };
    const deepest = try w.run(function);
    for (w.frames.items[1..]) |frame| try out.append(arena, frame.level);
    return deepest;
}

/// The depth of `function`, as `depth` gives it, with the constructs that
/// reach it appended to `chain`, outermost first. Allocated with `arena`.
pub fn explain(arena: Allocator, tree: *const Ast, function: Node.Index, chain: *std.ArrayList(Level)) Allocator.Error!u32 {
    var w: Walk = .{ .arena = arena, .tree = tree };
    const deepest = try w.run(function);
    const first = chain.items.len;
    var f = w.deepest_frame;
    while (f != 0) : (f = w.frames.items[f].parent) try chain.append(arena, w.frames.items[f].level);
    std.mem.reverse(Level, chain.items[first..]);
    return deepest;
}

const Walk = struct {
    arena: Allocator,
    tree: *const Ast,
    stack: std.ArrayList(Item) = .empty,
    kids: std.ArrayList(Node.Index) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    deepest: u32 = 0,
    deepest_frame: u32 = 0,

    fn run(w: *Walk, function: Node.Index) Allocator.Error!u32 {
        try w.frames.append(w.arena, .{ .level = .{ .token = 0, .construct = "", .level = 0 }, .parent = 0 });
        // The body alone: a struct in the signature, as a return or a
        // parameter's type, is no level of the code.
        const body = switch (w.tree.nodeTag(function)) {
            .fn_decl => w.tree.nodeData(function).node_and_node[1],
            else => w.tree.nodeData(function).opt_token_and_node[1],
        };
        try w.push(.{ .node = body, .depth = 0, .frame = 0, .body = true });
        while (w.stack.pop()) |item| try w.visit(item);
        return w.deepest;
    }

    fn visit(w: *Walk, item: Item) Allocator.Error!void {
        switch (w.tree.nodeTag(item.node)) {
            // Measured on their own.
            .fn_decl, .test_decl => {},
            .if_simple, .@"if" => try w.ifElse(item),
            .while_simple, .while_cont, .@"while" => try w.whileLoop(item),
            .for_simple, .@"for" => try w.forLoop(item),
            .@"switch", .switch_comma => try w.switchOn(item),
            .switch_case_one,
            .switch_case_inline_one,
            .switch_case,
            .switch_case_inline,
            => try w.prong(item),
            .@"catch", .@"orelse" => try w.handler(item),
            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            => try w.block(item),
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
            => try w.container(item),
            else => try w.pushChildren(item.node, item.depth, item.frame),
        }
    }

    /// An `if` is a level for its branches; an `else if` stays on its
    /// `if`'s level.
    fn ifElse(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const full = tree.fullIf(item.node).?;
        const d = item.depth;
        const f = try w.open(item.frame, tree.nodeMainToken(item.node), if (item.else_if) "else if" else "if", d + 1);
        try w.push(.{ .node = full.ast.cond_expr, .depth = d, .frame = item.frame });
        try w.push(.{ .node = full.ast.then_expr, .depth = d + 1, .frame = f, .body = true });
        if (full.ast.else_expr.unwrap()) |e| switch (tree.nodeTag(e)) {
            .if_simple, .@"if" => try w.push(.{ .node = e, .depth = d, .frame = item.frame, .else_if = true }),
            else => try w.push(.{ .node = e, .depth = d + 1, .frame = f, .body = true }),
        };
    }

    fn whileLoop(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const full = tree.fullWhile(item.node).?;
        const token = tree.nodeMainToken(item.node);
        const f = try w.open(item.frame, token, if (isInline(tree, token)) "inline while" else "while", item.depth + 1);
        try w.push(.{ .node = full.ast.cond_expr, .depth = item.depth, .frame = item.frame });
        if (full.ast.cont_expr.unwrap()) |cont| try w.push(.{ .node = cont, .depth = item.depth, .frame = item.frame });
        try w.loopBody(full.ast.then_expr, full.ast.else_expr.unwrap(), item.depth + 1, f);
    }

    fn forLoop(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const full = tree.fullFor(item.node).?;
        const token = tree.nodeMainToken(item.node);
        const f = try w.open(item.frame, token, if (isInline(tree, token)) "inline for" else "for", item.depth + 1);
        for (full.ast.inputs) |input| try w.push(.{ .node = input, .depth = item.depth, .frame = item.frame });
        try w.loopBody(full.ast.then_expr, full.ast.else_expr.unwrap(), item.depth + 1, f);
    }

    /// A loop's body and its `else`, at the loop's level `d`.
    fn loopBody(w: *Walk, body: Node.Index, else_expr: ?Node.Index, d: u32, f: u32) Allocator.Error!void {
        try w.push(.{ .node = body, .depth = d, .frame = f, .body = true });
        if (else_expr) |e| try w.push(.{ .node = e, .depth = d, .frame = f, .body = true });
    }

    /// A `switch` is a level for its prongs.
    fn switchOn(w: *Walk, item: Item) Allocator.Error!void {
        const full = w.tree.fullSwitch(item.node).?;
        const f = try w.open(item.frame, w.tree.nodeMainToken(item.node), "switch", item.depth + 1);
        try w.push(.{ .node = full.ast.condition, .depth = item.depth, .frame = item.frame });
        for (full.ast.cases) |case| try w.push(.{ .node = case, .depth = item.depth + 1, .frame = f });
    }

    /// A prong's body is the switch's level.
    fn prong(w: *Walk, item: Item) Allocator.Error!void {
        const full = w.tree.fullSwitchCase(item.node).?;
        for (full.ast.values) |value| try w.push(.{ .node = value, .depth = item.depth, .frame = item.frame });
        try w.push(.{ .node = full.ast.target_expr, .depth = item.depth, .frame = item.frame, .body = true });
    }

    /// A `catch` or `orelse` is a level when its handler is a block with
    /// something in it.
    fn handler(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        const token = tree.nodeMainToken(item.node);
        const lhs, const rhs = tree.nodeData(item.node).node_and_node;
        try w.push(.{ .node = lhs, .depth = item.depth, .frame = item.frame });
        if (!isFullBlock(tree, rhs)) return w.push(.{ .node = rhs, .depth = item.depth, .frame = item.frame });
        const f = try w.open(item.frame, token, tree.tokenSlice(token), item.depth + 1);
        try w.push(.{ .node = rhs, .depth = item.depth + 1, .frame = f, .body = true });
    }

    /// A labeled block is a level, unless it is a branch's body.
    fn block(w: *Walk, item: Item) Allocator.Error!void {
        const tree = w.tree;
        if (item.body or !isLabeled(tree, item.node)) return w.pushChildren(item.node, item.depth, item.frame);
        const label = tree.nodeMainToken(item.node) - 2;
        const construct = try std.mem.concat(w.arena, u8, &.{ tree.tokenSlice(label), ":" });
        const f = try w.open(item.frame, label, construct, item.depth + 1);
        try w.pushChildren(item.node, item.depth + 1, f);
    }

    /// A container declared in the function is a level.
    fn container(w: *Walk, item: Item) Allocator.Error!void {
        const token = w.tree.nodeMainToken(item.node);
        const f = try w.open(item.frame, token, w.tree.tokenSlice(token), item.depth + 1);
        try w.pushChildren(item.node, item.depth + 1, f);
    }

    /// Records a construct at `token` that opens `level`, inside `parent`,
    /// and returns its frame.
    fn open(w: *Walk, parent: u32, token: Ast.TokenIndex, construct: []const u8, level: u32) Allocator.Error!u32 {
        try w.frames.append(w.arena, .{ .level = .{ .token = token, .construct = construct, .level = level }, .parent = parent });
        const f: u32 = @intCast(w.frames.items.len - 1);
        if (level > w.deepest) {
            w.deepest = level;
            w.deepest_frame = f;
        }
        return f;
    }

    fn push(w: *Walk, item: Item) Allocator.Error!void {
        try w.stack.append(w.arena, item);
    }

    /// Pushes every child of `node` at depth `d` inside `frame`, none of
    /// them a body.
    fn pushChildren(w: *Walk, node: Node.Index, d: u32, frame: u32) Allocator.Error!void {
        w.kids.clearRetainingCapacity();
        try children.appendCode(w.arena, w.tree, node, &w.kids);
        for (w.kids.items) |kid| try w.push(.{ .node = kid, .depth = d, .frame = frame });
    }
};

/// Whether the loop keyword at `token` is written `inline`.
fn isInline(tree: *const Ast, token: Ast.TokenIndex) bool {
    return token > 0 and tree.tokenTag(token - 1) == .keyword_inline;
}

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
        const d = try depth(arena, &tree, function.node);
        try got.print(arena, "{s} {d}\n", .{ function.name, d });
        // The explanation is a chain from level 1 to the depth.
        var chain: std.ArrayList(Level) = .empty;
        try std.testing.expectEqual(d, try explain(arena, &tree, function.node, &chain));
        try std.testing.expectEqual(d, chain.items.len);
        for (chain.items, 1..) |level, n| try std.testing.expectEqual(n, level.level);
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "explain: the deepest chain, outermost first, as each construct is written" {
    const functions = @import("functions.zig");
    const gpa = std.testing.allocator;
    const source =
        \\fn f(xs: []const u8, c: bool) u8 {
        \\    if (c) {}
        \\    for (xs) |x| {
        \\        if (x == 0) {} else if (c) {
        \\            const v = blk: {
        \\                break :blk switch (x) {
        \\                    else => 1,
        \\                };
        \\            };
        \\            _ = v;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chain: std.ArrayList(Level) = .empty;
    try std.testing.expectEqual(4, try explain(arena, &tree, (try functions.list(arena, &tree))[0].node, &chain));
    var got: std.ArrayList(u8) = .empty;
    for (chain.items) |level| {
        const loc = tree.tokenLocation(0, level.token);
        try got.print(arena, "{d}:{d} {s} {d}\n", .{ loc.line + 1, loc.column + 1, level.construct, level.level });
    }
    // for > else if (on the if's level; its if keyword) > blk: > switch.
    try std.testing.expectEqualStrings(
        \\3:5 for 1
        \\4:29 else if 2
        \\5:23 blk: 3
        \\6:28 switch 4
        \\
    , got.items);
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

test "a container the function returns is no level, nor is anything in it" {
    try expectDepths(
        \\fn Box(comptime T: type) type {
        \\    if (@sizeOf(T) == 0) @compileError("empty");
        \\    return struct {
        \\        const Inner = struct {
        \\            const deep = blk: {
        \\                break :blk switch (@sizeOf(T)) {
        \\                    1 => 1,
        \\                    else => 2,
        \\                };
        \\            };
        \\        };
        \\        x: T,
        \\        fn get(b: @This()) T {
        \\            return b.x;
        \\        }
        \\    };
        \\}
        \\fn local() void {
        \\    const S = struct { x: u8 };
        \\    _ = S;
        \\}
    ,
        // Box: the if, 1; the struct it returns, Inner, blk: and the
        // switch are the type's. get: 0. local: a struct it declares and
        // does not return is a level, 1.
        \\Box 1
        \\Box.get 0
        \\local 1
        \\
    );
}

test "a container in the signature is no level; nesting is of the body" {
    try expectDepths(
        \\fn returns() struct { a: u8 } {
        \\    return .{ .a = 1 };
        \\}
        \\fn takes(x: struct { a: u8 }) u8 {
        \\    if (x.a > 0) return 1;
        \\    return 0;
        \\}
    ,
        // nothing; the if.
        \\returns 0
        \\takes 1
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

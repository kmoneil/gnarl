//! Cyclomatic complexity by Zig's rules: 1, and 1 more for each place a
//! function's code can go one of two ways.
//!
//! Each of these adds 1: an `if` (so each `else if`, and an `if` written
//! as a value), a `while`, a `for`, an `and`, an `or`, an `orelse`, a
//! `catch`, and each switch prong but a plain `else`. An `inline else`
//! adds 1: a prong for each value it stands for, written once.
//!
//! These add nothing: a `try`, which only passes an error on; a payload
//! capture, which names a value on a branch its `if` or `while` already
//! counted; an `else`; a labeled `break` or `continue`; a `_` prong, which
//! a non-exhaustive enum's switch takes by default as it would `else`; and
//! a `catch` or `orelse` with no real handler: `catch unreachable`, `catch
//! {}`, and `orelse unreachable`, which is `.?`.
//!
//! A function declared in a container inside this one is counted on its
//! own, and adds nothing here.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

/// The cyclomatic complexity of `function`, a `fn_decl` or `test_decl`.
/// The working memory is allocated with `arena`.
pub fn count(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!u32 {
    return walk(arena, tree, function, null);
}

/// A construct the count looked at: one that adds 1, or one a reader may
/// expect to count that adds nothing, and why.
pub const Branch = struct {
    /// Its keyword or operator, or a prong's first value.
    token: Ast.TokenIndex,
    /// As written: `if`, `else if`, `inline for`, `and`, `orelse`, `catch`,
    /// `try`, or `prong` and the prong's values.
    construct: []const u8,
    adds: u32,
    /// Why it adds nothing, when it does not.
    why: []const u8 = "",

    fn before(_: void, a: Branch, b: Branch) bool {
        return a.token < b.token;
    }
};

/// The count of `function`, as `count` gives it, with each construct it
/// looked at appended to `branches` in source order. Allocated with
/// `arena`.
pub fn explain(arena: Allocator, tree: *const Ast, function: Node.Index, branches: *std.ArrayList(Branch)) Allocator.Error!u32 {
    const first = branches.items.len;
    const total = try walk(arena, tree, function, branches);
    std.mem.sort(Branch, branches.items[first..], {}, Branch.before);
    return total;
}

fn walk(arena: Allocator, tree: *const Ast, function: Node.Index, sink: ?*std.ArrayList(Branch)) Allocator.Error!u32 {
    var total: u32 = 1;
    var stack: std.ArrayList(Node.Index) = .empty;
    // The ifs that are another if's else, which an explanation calls
    // `else if`. An if is visited before its else.
    var else_ifs: std.AutoHashMapUnmanaged(Node.Index, void) = .empty;
    try children.append(arena, tree, function, &stack);
    while (stack.pop()) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl, .test_decl => continue,
            else => {},
        }
        const adds = ways(tree, node);
        total += adds;
        if (sink) |branches| try note(arena, tree, node, adds, &else_ifs, branches);
        try children.append(arena, tree, node, &stack);
    }
    return total;
}

/// Appends what `node` is to `branches`, if it is a construct worth naming.
fn note(
    arena: Allocator,
    tree: *const Ast,
    node: Node.Index,
    adds: u32,
    else_ifs: *std.AutoHashMapUnmanaged(Node.Index, void),
    branches: *std.ArrayList(Branch),
) Allocator.Error!void {
    var token = tree.nodeMainToken(node);
    const construct: []const u8, const why: []const u8 = switch (tree.nodeTag(node)) {
        .if_simple, .@"if" => construct: {
            if (tree.fullIf(node).?.ast.else_expr.unwrap()) |e| switch (tree.nodeTag(e)) {
                .if_simple, .@"if" => try else_ifs.put(arena, e, {}),
                else => {},
            };
            break :construct .{ if (else_ifs.contains(node)) "else if" else "if", "" };
        },
        .while_simple, .while_cont, .@"while" => .{ if (isInline(tree, token)) "inline while" else "while", "" },
        .for_simple, .@"for" => .{ if (isInline(tree, token)) "inline for" else "for", "" },
        .bool_and => .{ "and", "" },
        .bool_or => .{ "or", "" },
        .@"orelse" => .{ "orelse", if (adds == 0) "orelse unreachable has no other path: it is .?" else "" },
        .@"catch" => .{ "catch", if (adds > 0) "" else switch (tree.nodeTag(tree.nodeData(node).node_and_node[1])) {
            .unreachable_literal => "catch unreachable has no handler",
            else => "catch {} has no handler",
        } },
        .@"try" => .{ "try", "a try passes an error on; it is not a branch" },
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => prong: {
            const full = tree.fullSwitchCase(node).?;
            const values = full.ast.values;
            const prefix = if (full.inline_token != null) "prong inline " else "prong ";
            if (values.len == 0) {
                token = full.inline_token orelse full.ast.arrow_token - 1;
                break :prong .{ try std.mem.concat(arena, u8, &.{ prefix, "else" }), if (adds == 0) "the default prong" else "" };
            }
            token = tree.firstToken(values[0]);
            const start = tree.tokenStart(token);
            const last = tree.lastToken(values[values.len - 1]);
            var text = tree.source[start .. tree.tokenStart(last) + tree.tokenSlice(last).len];
            if (std.mem.findScalar(u8, text, '\n')) |nl| text = text[0..nl];
            break :prong .{ try std.mem.concat(arena, u8, &.{ prefix, text }), if (adds == 0) "the default prong of a non-exhaustive enum" else "" };
        },
        else => return,
    };
    try branches.append(arena, .{ .token = token, .construct = construct, .adds = adds, .why = why });
}

/// Whether the loop keyword at `token` is written `inline`.
fn isInline(tree: *const Ast, token: Ast.TokenIndex) bool {
    return token > 0 and tree.tokenTag(token - 1) == .keyword_inline;
}

/// What `node` itself adds, apart from the nodes inside it.
fn ways(tree: *const Ast, node: Node.Index) u32 {
    return switch (tree.nodeTag(node)) {
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .bool_and,
        .bool_or,
        => 1,
        .@"orelse" => @intFromBool(tree.nodeTag(tree.nodeData(node).node_and_node[1]) != .unreachable_literal),
        .@"catch" => @intFromBool(handles(tree, tree.nodeData(node).node_and_node[1])),
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => @intFromBool(!isDefault(tree, node)),
        else => 0,
    };
}

/// Whether `handler`, what a `catch` gives in place of its value, does
/// anything: whether it is neither `unreachable` nor `{}`.
fn handles(tree: *const Ast, handler: Node.Index) bool {
    return switch (tree.nodeTag(handler)) {
        .unreachable_literal => false,
        .block_two, .block_two_semicolon => {
            var buffer: [2]Node.Index = undefined;
            return tree.blockStatements(&buffer, handler).?.len > 0;
        },
        else => true,
    };
}

/// Whether the switch prong `case` is the one taken when no other is: a
/// plain `else`, or a lone `_`.
fn isDefault(tree: *const Ast, case: Node.Index) bool {
    const full = tree.fullSwitchCase(case).?;
    if (full.inline_token != null) return false;
    const values = full.ast.values;
    if (values.len == 0) return true;
    return values.len == 1 and tree.nodeTag(values[0]) == .identifier and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(values[0])), "_");
}

/// Checks each function in `source` has its expected count, given a line
/// each as `name count`.
fn expectCounts(source: [:0]const u8, expected: []const u8) !void {
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
        const total = try count(arena, &tree, function.node);
        try got.print(arena, "{s} {d}\n", .{ function.name, total });
        // The explanation adds up to the count.
        var branches: std.ArrayList(Branch) = .empty;
        try std.testing.expectEqual(total, try explain(arena, &tree, function.node, &branches));
        var sum: u32 = 1;
        for (branches.items) |branch| sum += branch.adds;
        try std.testing.expectEqual(total, sum);
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

/// Checks the explanation of the only function in `source`, given a line
/// each as `line:column construct adds why`.
fn expectBranches(source: [:0]const u8, expected: []const u8) !void {
    const functions = @import("functions.zig");
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const function = (try functions.list(arena, &tree))[0];
    var branches: std.ArrayList(Branch) = .empty;
    _ = try explain(arena, &tree, function.node, &branches);
    var got: std.ArrayList(u8) = .empty;
    for (branches.items) |branch| {
        const loc = tree.tokenLocation(0, branch.token);
        try got.print(arena, "{d}:{d} {s} {d}{s}{s}\n", .{ loc.line + 1, loc.column + 1, branch.construct, branch.adds, if (branch.why.len > 0) " " else "", branch.why });
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "explain: each construct where it is, and why the ones that add nothing do not" {
    try expectBranches(
        \\fn f(x: E, opt: ?u8) !u8 {
        \\    if (x == .a and opt != null) try g() else if (x == .b) h();
        \\    inline for (.{1}) |_| {}
        \\    const v = opt orelse unreachable;
        \\    work() catch {};
        \\    return switch (x) {
        \\        .a, .b => v,
        \\        inline else => 0,
        \\    };
        \\}
    ,
        \\2:5 if 1
        \\2:17 and 1
        \\2:34 try 0 a try passes an error on; it is not a branch
        \\2:47 else if 1
        \\3:12 inline for 1
        \\4:19 orelse 0 orelse unreachable has no other path: it is .?
        \\5:12 catch 0 catch {} has no handler
        \\7:9 prong .a, .b 1
        \\8:9 prong inline else 1
        \\
    );
}

test "explain: a plain else and a lone _ are the default prongs" {
    try expectBranches(
        \\fn f(x: E, y: Open) void {
        \\    switch (x) {
        \\        0...9 => {},
        \\        else => {},
        \\    }
        \\    switch (y) {
        \\        _ => {},
        \\    }
        \\}
    ,
        \\3:9 prong 0...9 1
        \\4:9 prong else 0 the default prong
        \\7:9 prong _ 0 the default prong of a non-exhaustive enum
        \\
    );
}

// One test per rule. Each count is worked out by hand in the comment
// beside it.

test "straight-line code is 1, and a try adds nothing" {
    try expectCounts(
        \\fn f() !void {
        \\    try a();
        \\    const x = try b();
        \\    _ = x;
        \\}
    ,
        \\f 1
        \\
    );
}

test "each if adds 1, else if included; else adds nothing" {
    try expectCounts(
        \\fn one(c: bool) void {
        \\    if (c) a();
        \\}
        \\fn withElse(c: bool) void {
        \\    if (c) a() else b();
        \\}
        \\fn chain(x: u8) void {
        \\    if (x == 0) a() else if (x == 1) b() else if (x == 2) c() else d();
        \\}
        \\fn asValue(c: bool) u8 {
        \\    return if (c) 1 else 2;
        \\}
    ,
        // 1 + if; 1 + if; 1 + three ifs; 1 + if.
        \\one 2
        \\withElse 2
        \\chain 4
        \\asValue 2
        \\
    );
}

test "while and for add 1 each; their else and continue expression nothing" {
    try expectCounts(
        \\fn loops(xs: []const u8) void {
        \\    var i: usize = 0;
        \\    while (i < 10) : (i += 1) {} else {}
        \\    for (xs, 0..) |x, j| {
        \\        _ = .{ x, j };
        \\    } else {}
        \\    inline for (.{ 1, 2 }) |n| _ = n;
        \\}
    ,
        // 1 + while + for + inline for.
        \\loops 4
        \\
    );
}

test "a payload capture adds nothing past its if or while" {
    try expectCounts(
        \\fn captures(opt: ?u8, eu: anyerror!u8, it: *Iter) void {
        \\    if (opt) |v| use(v);
        \\    if (eu) |v| use(v) else |err| fail(err);
        \\    while (it.next()) |v| use(v);
        \\}
    ,
        // 1 + if + if + while.
        \\captures 4
        \\
    );
}

test "each switch prong adds 1 but a plain else or a lone _; inline else adds 1" {
    try expectCounts(
        \\fn prongs(x: E) void {
        \\    switch (x) {
        \\        .a => {},
        \\        .b, .c => {},
        \\        else => {},
        \\    }
        \\}
        \\fn ranges(n: u8) void {
        \\    switch (n) {
        \\        0...9 => {},
        \\        10 => {},
        \\        else => {},
        \\    }
        \\}
        \\fn inlined(u: U) void {
        \\    switch (u) {
        \\        .a => {},
        \\        inline else => |v| use(v),
        \\    }
        \\}
        \\fn nonExhaustive(e: Open) void {
        \\    switch (e) {
        \\        .a => {},
        \\        _ => {},
        \\    }
        \\}
        \\fn onlyElse(x: u8) void {
        \\    switch (x) {
        \\        else => {},
        \\    }
        \\}
    ,
        // 1 + .a + (.b, .c); 1 + 0...9 + 10; 1 + .a + inline else;
        // 1 + .a; 1.
        \\prongs 3
        \\ranges 3
        \\inlined 3
        \\nonExhaustive 2
        \\onlyElse 1
        \\
    );
}

test "and, or and orelse add 1 each; || on error sets and bitwise | nothing" {
    try expectCounts(
        \\fn logic(a: bool, b: bool, c: bool) bool {
        \\    return a and b or c;
        \\}
        \\fn fallback(x: ?u8, y: ?u8) u8 {
        \\    return x orelse y orelse 0;
        \\}
        \\fn inIf(a: bool, b: bool) void {
        \\    if (a and b) go();
        \\}
        \\fn merged() (error{A} || error{B})!u8 {
        \\    return 1 | 2 & 3;
        \\}
    ,
        // 1 + and + or; 1 + two orelses; 1 + if + and; 1.
        \\logic 3
        \\fallback 3
        \\inIf 3
        \\merged 1
        \\
    );
}

test "a catch with a handler adds 1, and a switch in it its prongs" {
    try expectCounts(
        \\fn value() u8 {
        \\    return parse() catch 0;
        \\}
        \\fn passOn() !void {
        \\    work() catch |err| return err;
        \\}
        \\fn handled() u8 {
        \\    return parse() catch |err| switch (err) {
        \\        error.A => 1,
        \\        error.B => 2,
        \\        else => 3,
        \\    };
        \\}
        \\fn withBlock() void {
        \\    work() catch |err| {
        \\        log(err);
        \\    };
        \\}
    ,
        // 1 + catch; 1 + catch; 1 + catch + error.A + error.B; 1 + catch.
        \\value 2
        \\passOn 2
        \\handled 4
        \\withBlock 2
        \\
    );
}

test "catch unreachable, catch {} and orelse unreachable add nothing" {
    try expectCounts(
        \\fn asserted(x: ?u8) u8 {
        \\    work() catch unreachable;
        \\    work() catch {};
        \\    return x orelse unreachable;
        \\}
    ,
        \\asserted 1
        \\
    );
}

test "labeled blocks, break and continue add nothing" {
    try expectCounts(
        \\fn labeled(xs: []const u8, ys: []const u8) u8 {
        \\    const v = blk: {
        \\        break :blk 1;
        \\    };
        \\    outer: for (xs) |x| {
        \\        for (ys) |y| {
        \\            if (x == y) continue :outer;
        \\        }
        \\    }
        \\    return v;
        \\}
        \\fn state(s: S) void {
        \\    sw: switch (s) {
        \\        .start => continue :sw .stop,
        \\        .stop => {},
        \\    }
        \\}
    ,
        // 1 + for + for + if; 1 + .start + .stop.
        \\labeled 4
        \\state 3
        \\
    );
}

test "defer, errdefer and comptime code count as any other; errdefer itself nothing" {
    try expectCounts(
        \\fn deferred(c: bool) !void {
        \\    defer if (c) a();
        \\    errdefer cleanUp();
        \\    comptime {
        \\        if (debug) check();
        \\    }
        \\}
    ,
        // 1 + if + if.
        \\deferred 3
        \\
    );
}

test "a function declared inside counts on its own, not in the one around it" {
    try expectCounts(
        \\fn outer(c: bool) void {
        \\    const S = struct {
        \\        fn inner(d: bool) void {
        \\            if (d) {}
        \\            if (d) {}
        \\        }
        \\    };
        \\    if (c) S.inner(c);
        \\}
    ,
        // 1 + if; 1 + if + if.
        \\outer 2
        \\outer.S.inner 3
        \\
    );
}

test "a test block is counted as a function is" {
    try expectCounts(
        \\test "t" {
        \\    if (x) {}
        \\    for (xs) |_| {}
        \\}
    ,
        // 1 + if + for.
        \\test "t" 3
        \\
    );
}

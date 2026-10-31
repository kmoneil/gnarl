//! Parameters: how many inputs a caller must give a function, in two
//! numbers.
//!
//! The count leaves out what is context rather than input: a leading self
//! (a first parameter whose type, past any `*` or `?`, is `@This()`, the
//! container's own name, or a name the container gives `@This()`), and an
//! `Allocator` or `Io` wherever it stands. The weighted count is the same
//! with a `type` parameter and an `anytype` counted twice: each is a
//! contract the caller must meet that the signature does not spell out.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

const functions = @import("functions.zig");

pub const Count = struct {
    count: u32,
    weighted: u32,
};

/// The parameters of `function`. A test block has none.
pub fn count(tree: *const Ast, function: functions.Function) Count {
    return walk(tree, function, null) catch unreachable;
}

/// One parameter, and what it adds.
pub const Param = struct {
    /// Its name, or "" when it has none.
    name: []const u8,
    /// Its type as written, or `anytype`.
    type: []const u8,
    /// What it adds to the weighted count; 0 when it is left out of both.
    weight: u32,
    /// Why it is left out or weighs 2.
    why: []const u8,
};

/// The counts of `function`, as `count` gives them, with each parameter
/// appended to `out`. Allocated with `arena`.
pub fn explain(arena: std.mem.Allocator, tree: *const Ast, function: functions.Function, out: *std.ArrayList(Param)) std.mem.Allocator.Error!Count {
    return walk(tree, function, .{ .arena = arena, .out = out });
}

const Sink = struct { arena: std.mem.Allocator, out: *std.ArrayList(Param) };

fn walk(tree: *const Ast, function: functions.Function, sink: ?Sink) std.mem.Allocator.Error!Count {
    var total: Count = .{ .count = 0, .weighted = 0 };
    if (function.kind == .@"test") return total;
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function.node).node_and_node[0]).?;
    var it = proto.iterate(tree);
    var first = true;
    while (it.next()) |param| {
        defer first = false;
        const weight: u32, const why: []const u8 = if (param.type_expr) |type_expr| judged: {
            if (first and isSelf(tree, type_expr, function)) break :judged .{ 0, "a leading self" };
            if (contextName(tree, type_expr)) |name| break :judged .{ 0, if (name[0] == 'A') "an Allocator: context, not input" else "an Io: context, not input" };
            if (isTypeType(tree, type_expr)) break :judged .{ 2, "a type parameter: a contract the signature does not spell out" };
            break :judged .{ 1, "" };
        } else switch (tree.tokenTag(param.anytype_ellipsis3.?)) {
            .keyword_anytype => .{ 2, "anytype: a contract the signature does not spell out" },
            // `...` is only for extern functions, which have no body.
            else => .{ 0, "variadic" },
        };
        if (sink) |s| try s.out.append(s.arena, .{
            .name = if (param.name_token) |t| tree.tokenSlice(t) else "",
            .type = if (param.type_expr) |t| text(tree, t) else tree.tokenSlice(param.anytype_ellipsis3.?),
            .weight = weight,
            .why = why,
        });
        if (weight == 0) continue;
        total.count += 1;
        total.weighted += weight;
    }
    return total;
}

/// The source of `node`, first token to last.
fn text(tree: *const Ast, node: Node.Index) []const u8 {
    const last = tree.lastToken(node);
    return tree.source[tree.tokenStart(tree.firstToken(node)) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
}

/// Whether `type_expr`, the first parameter's type, is the container the
/// function is declared in.
fn isSelf(tree: *const Ast, type_expr: Node.Index, function: functions.Function) bool {
    var base = type_expr;
    while (true) switch (tree.nodeTag(base)) {
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => base = tree.fullPtrType(base).?.ast.child_type,
        .optional_type => base = tree.nodeData(base).node,
        else => break,
    };
    if (isThis(tree, base)) return true;
    if (tree.nodeTag(base) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(base));
    if (function.container_name) |token| {
        if (std.mem.eql(u8, name, tree.tokenSlice(token))) return true;
    }
    // A name the container gives `@This()`, as `const Self = @This();`.
    var buffer: [2]Node.Index = undefined;
    const members = if (function.container == .root) tree.rootDecls() else tree.fullContainerDecl(&buffer, function.container).?.ast.members;
    for (members) |member| {
        const decl = tree.fullVarDecl(member) orelse continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        if (isThis(tree, init) and std.mem.eql(u8, name, tree.tokenSlice(decl.ast.mut_token + 1))) return true;
    }
    return false;
}

/// Whether `node` is `@This()`.
fn isThis(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@This"),
        else => false,
    };
}

/// Whether the type `node` is an `Allocator` or an `Io`, named alone or as
/// the last field of a path (`std.mem.Allocator`).
fn contextName(tree: *const Ast, node: Node.Index) ?[]const u8 {
    const name_token = switch (tree.nodeTag(node)) {
        .identifier => tree.nodeMainToken(node),
        .field_access => tree.nodeData(node).node_and_token[1],
        else => return null,
    };
    const name = tree.tokenSlice(name_token);
    if (std.mem.eql(u8, name, "Allocator") or std.mem.eql(u8, name, "Io")) return name;
    return null;
}

/// Whether the type `node` is `type`.
fn isTypeType(tree: *const Ast, node: Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
}

/// Checks each function in `source` has its expected counts, given a line
/// each as `name count weighted`.
fn expectCounts(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var got: std.ArrayList(u8) = .empty;
    for (try functions.list(arena, &tree)) |function| {
        const c = count(&tree, function);
        try got.print(arena, "{s} {d} {d}\n", .{ function.name, c.count, c.weighted });
        // The explanation gives the same counts.
        var each: std.ArrayList(Param) = .empty;
        try std.testing.expectEqual(c, try explain(arena, &tree, function, &each));
        var weighted: u32 = 0;
        for (each.items) |p| weighted += p.weight;
        try std.testing.expectEqual(c.weighted, weighted);
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "explain: each parameter, its type as written, and why it is left out or weighs 2" {
    const gpa = std.testing.allocator;
    const source =
        \\const S = struct {
        \\    fn m(s: *const S, gpa: std.mem.Allocator, comptime T: type, x: anytype, n: []const T) void {}
        \\};
    ;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var each: std.ArrayList(Param) = .empty;
    const c = try explain(arena, &tree, (try functions.list(arena, &tree))[0], &each);
    try std.testing.expectEqual(Count{ .count = 3, .weighted = 5 }, c);
    var got: std.ArrayList(u8) = .empty;
    for (each.items) |p| try got.print(arena, "{s}|{s}|{d}|{s}\n", .{ p.name, p.type, p.weight, p.why });
    try std.testing.expectEqualStrings(
        \\s|*const S|0|a leading self
        \\gpa|std.mem.Allocator|0|an Allocator: context, not input
        \\T|type|2|a type parameter: a contract the signature does not spell out
        \\x|anytype|2|anytype: a contract the signature does not spell out
        \\n|[]const T|1|
        \\
    , got.items);
}

// Each count is worked out by hand in the comment beside it.

test "each parameter counts once" {
    try expectCounts(
        \\fn none() void {}
        \\fn two(a: u8, b: []const u8) void {}
        \\fn values(comptime n: usize, noalias p: *u8) void {}
    ,
        // A comptime value and a noalias pointer are plain parameters.
        \\none 0 0
        \\two 2 2
        \\values 2 2
        \\
    );
}

test "a leading self is left out, however the container is named" {
    try expectCounts(
        \\const S = struct {
        \\    const Self = @This();
        \\    fn byName(s: *S, x: u8) void {}
        \\    fn byThis(self: *const @This()) void {}
        \\    fn byAlias(self: Self, y: u8) void {}
        \\    fn optional(s: ?*S) void {}
        \\    fn notLeading(x: u8, s: *S) void {}
        \\    fn other(t: *T) void {}
        \\};
        \\const File = @This();
        \\fn fileMethod(f: *File, z: u8) void {}
        \\fn free(s: *S) void {}
    ,
        // Self dropped in the first four; only a leading one is; T is not
        // the container; the file's own alias is self at the top; S is not
        // the file.
        \\S.byName 1 1
        \\S.byThis 0 0
        \\S.byAlias 1 1
        \\S.optional 0 0
        \\S.notLeading 2 2
        \\S.other 1 1
        \\fileMethod 1 1
        \\free 1 1
        \\
    );
}

test "an Allocator or an Io is left out wherever it stands" {
    try expectCounts(
        \\fn ctx(gpa: std.mem.Allocator, io: std.Io, arena: Allocator, n: u8, w: *std.Io.Writer) void {}
    ,
        // n and w: an Io.Writer is input.
        \\ctx 2 2
        \\
    );
}

test "a type parameter and an anytype weigh 2" {
    try expectCounts(
        \\fn generic(comptime T: type, value: T, x: anytype) void {}
        \\fn implicit(T: type) void {}
    ,
        // 3 parameters weighing 2 + 1 + 2; a type parameter needs no
        // comptime to weigh 2.
        \\generic 3 5
        \\implicit 1 2
        \\
    );
}

test "the struct a generic function returns, and one declared in a function" {
    try expectCounts(
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        fn append(self: *Self, gpa: Allocator, item: T) !void {}
        \\    };
        \\}
        \\fn outer() void {
        \\    const Local = struct {
        \\        fn m(l: Local) void {}
        \\    };
        \\}
        \\test "t" {}
    ,
        // T weighs 2; append's self and gpa are left out; Local is m's
        // container; a test has none.
        \\List 1 2
        \\List.append 1 1
        \\outer 0 0
        \\outer.Local.m 0 0
        \\test "t" 0 0
        \\
    );
}

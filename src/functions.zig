//! Every function in a parsed file, and the name each is known by.
//!
//! A function's name is its own after the names of what it is declared in,
//! joined with `.`. What gives a name: a function, a `const` or `var`, a
//! container field and a test. So a method of `const Validator = struct
//! {...}` is `Validator.record`, and a method of a container declared in a
//! function body is `f.Local.g`. Anything else (a container written where
//! a value goes, a call, a block) adds nothing: the methods of the struct a
//! generic function returns are `List.append`, and an anonymous struct
//! handed to a sort for its comparator gives `sortItems.lessThan`.
//!
//! Test blocks are listed too, named as written: `test "name"`, `test
//! name`, or `test` alone. A function with no body (`extern fn`, a function
//! type) is not listed: there is nothing in it to measure.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

pub const Kind = enum { @"fn", @"test" };

pub const Function = struct {
    kind: Kind,
    /// The `fn_decl` or `test_decl`.
    node: Node.Index,
    /// Qualified, as this file's doc comment says.
    name: []const u8,
    /// Where the function is said to be: its name, or a test's `test`
    /// keyword.
    token: Ast.TokenIndex,
    /// The token's line and column, both from 1. The column counts bytes.
    line: u32,
    column: u32,
    /// The container the function is declared in: a container declaration,
    /// or `.root` for the file.
    container: Node.Index,
    /// The name a `const` or `var` gives that container, if one does.
    container_name: ?Ast.TokenIndex,
};

/// One link in the chain of names from a node up to the file.
const Scope = struct {
    /// The node that gives the name; `.root` for the file itself.
    node: Node.Index,
    /// An index into the same list. The file's scope, 0, is its own parent.
    parent: u32,
};

/// A node still to visit, and where it is.
const Item = struct {
    node: Node.Index,
    scope: u32,
    /// The container it is in, and the name given that container.
    container: Node.Index,
    container_name: ?Ast.TokenIndex,
    /// The name the `const` or `var` it is part of gives it, if it is one's
    /// type or value.
    given_name: ?Ast.TokenIndex,
};

/// Every function and test block in `tree`, in source order. Allocated with
/// `arena`, as is the working memory.
pub fn list(arena: Allocator, tree: *const Ast) Allocator.Error![]Function {
    var scopes: std.ArrayList(Scope) = .empty;
    try scopes.append(arena, .{ .node = .root, .parent = 0 });
    var found: std.ArrayList(Function) = .empty;

    // A stack rather than recursion, so no nesting depth a file can reach
    // runs out of call stack.
    var stack: std.ArrayList(Item) = .empty;
    var kids: std.ArrayList(Node.Index) = .empty;
    try stack.append(arena, .{ .node = .root, .scope = 0, .container = .root, .container_name = null, .given_name = null });
    while (stack.pop()) |item| {
        var scope = item.scope;
        if (givesName(tree, item.node)) {
            try scopes.append(arena, .{ .node = item.node, .parent = scope });
            scope = @intCast(scopes.items.len - 1);
            if (kindOf(tree, item.node)) |kind| try found.append(arena, .{
                .kind = kind,
                .node = item.node,
                .name = try qualifiedName(arena, tree, scopes.items, scope),
                .token = nameToken(tree, item.node),
                .line = 0,
                .column = 0,
                .container = item.container,
                .container_name = item.container_name,
            });
        }
        var next = item;
        next.scope = scope;
        next.given_name = null;
        if (isContainer(tree.nodeTag(item.node))) {
            next.container = item.node;
            next.container_name = item.given_name;
        }
        if (tree.fullVarDecl(item.node) != null) next.given_name = nameToken(tree, item.node);
        kids.clearRetainingCapacity();
        try children.append(arena, tree, item.node, &kids);
        for (kids.items) |kid| {
            next.node = kid;
            try stack.append(arena, next);
        }
    }

    std.mem.sort(Function, found.items, {}, before);
    locate(tree, found.items);
    return found.items;
}

fn before(_: void, a: Function, b: Function) bool {
    return a.token < b.token;
}

/// Sets each function's line and column, in one pass over the source:
/// `functions` is in source order.
fn locate(tree: *const Ast, functions: []Function) void {
    var line: u32 = 1;
    var line_start: usize = 0;
    var pos: usize = 0;
    for (functions) |*function| {
        const offset = tree.tokenStart(function.token);
        const gap = tree.source[pos..offset];
        line += @intCast(std.mem.countScalar(u8, gap, '\n'));
        if (std.mem.findScalarLast(u8, gap, '\n')) |i| line_start = pos + i + 1;
        pos = offset;
        function.line = line;
        function.column = @intCast(offset - line_start + 1);
    }
}

fn isContainer(tag: Node.Tag) bool {
    return switch (tag) {
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
        => true,
        else => false,
    };
}

fn kindOf(tree: *const Ast, node: Node.Index) ?Kind {
    return switch (tree.nodeTag(node)) {
        .fn_decl => .@"fn",
        .test_decl => .@"test",
        else => null,
    };
}

/// Whether `node` puts its name on what is declared inside it.
fn givesName(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .fn_decl,
        .test_decl,
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => true,
        // A tuple's fields have no names.
        .container_field_init,
        .container_field_align,
        .container_field,
        => !tree.fullContainerField(node).?.ast.tuple_like,
        else => false,
    };
}

/// The token that names `node`, one `givesName` is true of. A test's is its
/// `test` keyword, and a function's that has no name is its `fn` keyword.
fn nameToken(tree: *const Ast, node: Node.Index) Ast.TokenIndex {
    return switch (tree.nodeTag(node)) {
        .fn_decl => {
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?;
            return proto.name_token orelse proto.ast.fn_token;
        },
        .test_decl => tree.nodeMainToken(node),
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => tree.fullVarDecl(node).?.ast.mut_token + 1,
        else => tree.fullContainerField(node).?.ast.main_token,
    };
}

/// The names from the file down to `scope`, joined with `.`.
fn qualifiedName(arena: Allocator, tree: *const Ast, scopes: []const Scope, scope: u32) Allocator.Error![]const u8 {
    var chain: std.ArrayList(Node.Index) = .empty;
    var s = scope;
    while (s != 0) : (s = scopes[s].parent) try chain.append(arena, scopes[s].node);
    std.mem.reverse(Node.Index, chain.items);

    var name: std.ArrayList(u8) = .empty;
    for (chain.items, 0..) |node, i| {
        if (i > 0) try name.append(arena, '.');
        try name.appendSlice(arena, tree.tokenSlice(nameToken(tree, node)));
        if (tree.nodeTag(node) == .test_decl) {
            if (tree.nodeData(node).opt_token_and_node[0].unwrap()) |test_name| {
                try name.append(arena, ' ');
                try name.appendSlice(arena, tree.tokenSlice(test_name));
            }
        }
    }
    return name.items;
}

/// `source`'s functions, a line each as `line: name`, for tests.
fn expectListed(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var got: std.ArrayList(u8) = .empty;
    for (try list(arena, &tree)) |function| {
        try got.print(arena, "{d}:{d}: {s}{s}\n", .{
            function.line,
            function.column,
            function.name,
            if (function.kind == .@"test") " (test)" else "",
        });
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "list: functions at the top and methods of named containers" {
    try expectListed(
        \\const std = @import("std");
        \\fn a() void {}
        \\pub fn b() void {}
        \\export fn c() void {}
        \\inline fn d() void {}
        \\/// Doc comments come before it.
        \\pub inline fn e() void {}
        \\pub const Validator = struct {
        \\    count: u32,
        \\    pub fn record(v: *Validator) void { _ = v; }
        \\    const Inner = enum {
        \\        x,
        \\        fn f() void {}
        \\    };
        \\};
        \\const U = union(enum) { a: u8, fn g() void {} };
        \\const O = opaque { fn h() void {} };
        \\fn @"quoted name"() void {}
    ,
        \\2:4: a
        \\3:8: b
        \\4:11: c
        \\5:11: d
        \\7:15: e
        \\10:12: Validator.record
        \\13:12: Validator.Inner.f
        \\16:35: U.g
        \\17:23: O.h
        \\18:4: @"quoted name"
        \\
    );
}

test "list: a function with no body is not listed" {
    try expectListed(
        \\extern fn write(fd: i32) isize;
        \\pub extern "c" fn read(fd: i32) isize;
        \\const Callback = fn (u8) void;
        \\const S = struct {
        \\    cb: *const fn () void,
        \\    extern fn f() void;
        \\};
    , "");
}

test "list: containers declared in a function body take the function's name" {
    try expectListed(
        \\fn outer() void {
        \\    const Local = struct {
        \\        fn inner() void {
        \\            const Deeper = struct {
        \\                fn deepest() void {}
        \\            };
        \\            _ = Deeper;
        \\        }
        \\    };
        \\    _ = Local;
        \\}
        \\const S = struct {
        \\    fn method() void {
        \\        const Impl = if (true) struct { fn a() void {} } else struct { fn a() void {} };
        \\        _ = Impl;
        \\    }
        \\};
    ,
        \\1:4: outer
        \\3:12: outer.Local.inner
        \\5:20: outer.Local.inner.Deeper.deepest
        \\13:8: S.method
        \\14:44: S.method.Impl.a
        \\14:75: S.method.Impl.a
        \\
    );
}

test "list: anonymous containers add no name" {
    try expectListed(
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        pub fn append(self: *@This()) void { _ = self; }
        \\    };
        \\}
        \\fn sortItems(items: []u8) void {
        \\    std.mem.sort(u8, items, {}, struct {
        \\        fn lessThan(_: void, a: u8, b: u8) bool { return a < b; }
        \\    }.lessThan);
        \\}
        \\comptime {
        \\    _ = struct { fn inComptime() void {} };
        \\}
        \\const Pair = struct { u8, struct { fn inTuple() void {} } };
    ,
        \\1:4: List
        \\4:16: List.append
        \\7:4: sortItems
        \\9:12: sortItems.lessThan
        \\13:21: inComptime
        \\15:39: Pair.inTuple
        \\
    );
}

test "list: a field or a variable gives its name, a parameter does not" {
    try expectListed(
        \\const S = struct {
        \\    inner: struct { fn f() void {} } = .{},
        \\    handler: *const fn () void = struct { fn g() void {} }.g,
        \\};
        \\var registry = register(struct { fn h() void {} });
        \\fn takes(x: struct { fn i() void {} }) void { _ = x; }
        \\fn local() void {
        \\    const a, const b = .{ struct { fn j() void {} }, 1 };
        \\    _ = .{ a, b };
        \\}
    ,
        \\2:24: S.inner.f
        \\3:46: S.handler.g
        \\5:37: registry.h
        \\6:4: takes
        \\6:25: takes.i
        \\7:4: local
        \\8:39: local.j
        \\
    );
}

test "list: test blocks, and what is declared in them" {
    try expectListed(
        \\test "a name" {
        \\    const S = struct { fn helper() void {} };
        \\    _ = S;
        \\}
        \\test {}
        \\test decl {}
        \\fn decl() void {}
    ,
        \\1:1: test "a name" (test)
        \\2:27: test "a name".S.helper
        \\5:1: test (test)
        \\6:1: test decl (test)
        \\7:4: decl
        \\
    );
}

test "list: lines and columns count from 1, columns in bytes" {
    try expectListed("fn a() void {}\n\n\n    fn b() void {}\r\nconst s = \"é\"; fn c() void {}", "1:4: a\n4:8: b\n5:20: c\n");
}

test "list: every fn_decl and test_decl in this repository's source, once each" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        files += 1;
        const source = try dir.readFileAllocOptions(io, entry.name, gpa, .limited(std.math.maxInt(u32)), .of(u8), 0);
        defer gpa.free(source);
        var tree = try Ast.parse(gpa, source, .{});
        defer tree.deinit(gpa);
        try std.testing.expectEqual(0, tree.errors.len);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();

        const listed = try list(arena_state.allocator(), &tree);
        var expected: usize = 0;
        for (0..tree.nodes.len) |i| {
            if (kindOf(&tree, @fromBackingInt(@intCast(i))) != null) expected += 1;
        }
        try std.testing.expectEqual(expected, listed.len);
        if (listed.len > 1) for (listed[1..], listed[0 .. listed.len - 1]) |b, a| try std.testing.expect(a.node != b.node);
    }
    try std.testing.expect(files > 0);
}

//! Logical lines: the lines of a function that hold code, from its
//! signature to its closing brace.
//!
//! Not counted: a blank line, a line with only a comment, and a line that
//! only closes, holding nothing but closing brackets and the `;` or `,`
//! after them (`}`, `};`, `},`, `});`). Counted like any other: each line
//! of the signature, `defer` and `errdefer`, and each line of a multiline
//! string.
//!
//! The lines of a function declared in a container inside this one are
//! its own, and not counted here.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

/// The logical lines of `function`, a `fn_decl` or `test_decl`. The working
/// memory is allocated with `arena`.
pub fn count(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!u32 {
    // The tokens of the functions declared inside, first and last, in
    // source order. They do not overlap: none is looked inside.
    var nested: std.ArrayList([2]Ast.TokenIndex) = .empty;
    var stack: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, function, &stack);
    while (stack.pop()) |node| switch (tree.nodeTag(node)) {
        .fn_decl, .test_decl => try nested.append(arena, .{ tree.firstToken(node), tree.lastToken(node) }),
        else => try children.append(arena, tree, node, &stack),
    };
    std.mem.sort([2]Ast.TokenIndex, nested.items, {}, startsBefore);

    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var lines: u32 = 0;
    // Lines from `first`'s, up to the byte at `pos`.
    var line: u32 = 0;
    var pos = tree.tokenStart(first);
    var counted_line: u32 = std.math.maxInt(u32);
    var next_nested: usize = 0;
    var token = first;
    while (token <= last) : (token += 1) {
        if (next_nested < nested.items.len and token == nested.items[next_nested][0]) {
            token = nested.items[next_nested][1];
            next_nested += 1;
            continue;
        }
        if (!isCode(tree.tokenTag(token))) continue;
        const start = tree.tokenStart(token);
        line += @intCast(std.mem.countScalar(u8, tree.source[pos..start], '\n'));
        pos = start;
        if (line != counted_line) {
            lines += 1;
            counted_line = line;
        }
    }
    return lines;
}

fn startsBefore(_: void, a: [2]Ast.TokenIndex, b: [2]Ast.TokenIndex) bool {
    return a[0] < b[0];
}

/// Whether a line holding a token tagged `tag` holds code. A line with only
/// closers and doc comments holds none. Plain comments are not tokens.
fn isCode(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .r_brace, .r_paren, .r_bracket, .semicolon, .comma, .doc_comment, .container_doc_comment => false,
        else => true,
    };
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
        try got.print(arena, "{s} {d}\n", .{ function.name, try count(arena, &tree, function.node) });
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

// Each count is worked out by hand in the comment beside it.

test "blank lines, comment-only lines and a lone closing brace are not counted" {
    try expectCounts(
        \\fn f() void {
        \\    a();
        \\
        \\    // Why b follows.
        \\    b(); // and a comment after code
        \\}
        \\fn one() void {}
    ,
        // The signature, a(), b(); the one-line function.
        \\f 3
        \\one 1
        \\
    );
}

test "a line of closers in any shape is not counted; } else { is" {
    try expectCounts(
        \\fn g(x: bool) void {
        \\    call(
        \\        1,
        \\        2,
        \\    );
        \\    const s = .{
        \\        .a = 1,
        \\    };
        \\    if (x) {
        \\        y(.{
        \\            .b = 2,
        \\        });
        \\    } else {
        \\        z(s);
        \\    }
        \\}
    ,
        // fn g, call(, 1, 2, const s, .a, if, y(.{, .b, } else {, z(s).
        \\g 11
        \\
    );
}

test "each line of the signature, defer and errdefer count" {
    try expectCounts(
        \\pub fn long(
        \\    a: u8,
        \\    b: u8,
        \\) !void {
        \\    defer done();
        \\    errdefer undo();
        \\    errdefer {
        \\        undoMore();
        \\    }
        \\    _ = .{ a, b };
        \\}
    ,
        // Four signature lines, defer, errdefer, errdefer {, undoMore(), _ =.
        \\long 9
        \\
    );
}

test "each line of a multiline string counts; a lone ; does not" {
    try expectCounts(
        \\fn text() []const u8 {
        \\    const s =
        \\        \\one
        \\        \\// not a comment: part of the string
        \\    ;
        \\    return s;
        \\}
    ,
        // fn text, const s =, the two string lines, return s.
        \\text 5
        \\
    );
}

test "a function declared inside has its own lines; its container's lines are the outer one's" {
    try expectCounts(
        \\fn outer() void {
        \\    const S = struct {
        \\        /// How many.
        \\        n: u8 = 0,
        \\        fn inner() void {
        \\            a();
        \\        }
        \\    };
        \\    const T = struct { fn g() void {} };
        \\    S.inner();
        \\    T.g();
        \\}
    ,
        // outer: fn outer, const S, n, const T (g is on it but its own),
        // S.inner(), T.g(); inner: fn inner, a(); g: its one line.
        \\outer 6
        \\outer.S.inner 2
        \\outer.T.g 1
        \\
    );
}

test "a test block is counted as a function is" {
    try expectCounts(
        \\test "t" {
        \\    a();
        \\}
    ,
        \\test "t" 2
        \\
    );
}

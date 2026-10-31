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
    return walk(arena, tree, function, null);
}

/// The count of `function`, as `count` gives it, with the first code
/// token of each line counted appended to `firsts`, in order.
pub fn firsts(arena: Allocator, tree: *const Ast, function: Node.Index, out: *std.ArrayList(Ast.TokenIndex)) Allocator.Error!u32 {
    return walk(arena, tree, function, out);
}

fn walk(arena: Allocator, tree: *const Ast, function: Node.Index, sink: ?*std.ArrayList(Ast.TokenIndex)) Allocator.Error!u32 {
    const nested = try nestedRanges(arena, tree, function);
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
        if (next_nested < nested.len and token == nested[next_nested][0]) {
            token = nested[next_nested][1];
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
            if (sink) |out| try out.append(arena, token);
        }
    }
    return lines;
}

/// The first and last tokens of the functions declared inside `function`,
/// in source order. They do not overlap: none is looked inside.
fn nestedRanges(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error![]const [2]Ast.TokenIndex {
    var nested: std.ArrayList([2]Ast.TokenIndex) = .empty;
    var stack: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, function, &stack);
    while (stack.pop()) |node| switch (tree.nodeTag(node)) {
        .fn_decl, .test_decl => try nested.append(arena, .{ tree.firstToken(node), tree.lastToken(node) }),
        else => try children.append(arena, tree, node, &stack),
    };
    std.mem.sort([2]Ast.TokenIndex, nested.items, {}, startsBefore);
    return nested.items;
}

fn startsBefore(_: void, a: [2]Ast.TokenIndex, b: [2]Ast.TokenIndex) bool {
    return a[0] < b[0];
}

/// How a function's lines, from its signature to its closing brace,
/// divide. Each is in exactly one: `counted` is what `count` gives.
pub const Breakdown = struct {
    span: u32 = 0,
    counted: u32 = 0,
    blank: u32 = 0,
    /// Only a comment, or a doc comment.
    comment: u32 = 0,
    /// Only closing brackets and the `;` or `,` after them.
    closer: u32 = 0,
    /// Only a function declared inside this one, which has its own count.
    nested: u32 = 0,

    /// Counts a line, `text`, that holds what `s` says, in its one kind.
    fn add(b: *Breakdown, s: Seen, text: []const u8) void {
        if (s.code) {
            b.counted += 1;
        } else if (s.nested) {
            b.nested += 1;
        } else if (s.closer) {
            b.closer += 1;
        } else if (s.doc or std.mem.trim(u8, text, " \t\r").len > 0) {
            b.comment += 1;
        } else b.blank += 1;
    }
};

/// What a line holds, as the tokens on it say.
const Seen = packed struct {
    code: bool = false,
    nested: bool = false,
    closer: bool = false,
    doc: bool = false,

    /// Marks a token tagged `tag` on the line: one of a nested function's,
    /// code, a doc comment, or else a closer.
    fn mark(s: *Seen, tag: std.zig.Token.Tag, inside_nested: bool) void {
        if (inside_nested) {
            s.nested = true;
        } else if (isCode(tag)) {
            s.code = true;
        } else if (tag == .doc_comment or tag == .container_doc_comment) {
            s.doc = true;
        } else s.closer = true;
    }
};

/// How the lines of `function` divide. Allocated with `arena`.
pub fn explain(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!Breakdown {
    const nested = try nestedRanges(arena, tree, function);
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    const source = tree.source;
    const start = if (std.mem.findScalarLast(u8, source[0..tree.tokenStart(first)], '\n')) |nl| nl + 1 else 0;
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    const span: u32 = @intCast(std.mem.countScalar(u8, source[start..end], '\n') + 1);

    const seen = try arena.alloc(Seen, span);
    @memset(seen, .{});
    var line: u32 = 0;
    var pos = start;
    var next_nested: usize = 0;
    var inside_nested = false;
    var token = first;
    while (token <= last) : (token += 1) {
        const at = tree.tokenStart(token);
        line += @intCast(std.mem.countScalar(u8, source[pos..at], '\n'));
        pos = at;
        if (next_nested < nested.len and token == nested[next_nested][0]) inside_nested = true;
        seen[line].mark(tree.tokenTag(token), inside_nested);
        if (inside_nested and token == nested[next_nested][1]) {
            inside_nested = false;
            next_nested += 1;
        }
    }

    var b: Breakdown = .{ .span = span };
    var it = std.mem.splitScalar(u8, source[start..end], '\n');
    for (seen) |s| b.add(s, it.next().?);
    return b;
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
        const n = try count(arena, &tree, function.node);
        try got.print(arena, "{s} {d}\n", .{ function.name, n });
        // The breakdown counts the same lines, and every line once.
        const b = try explain(arena, &tree, function.node);
        try std.testing.expectEqual(n, b.counted);
        try std.testing.expectEqual(b.span, b.counted + b.blank + b.comment + b.closer + b.nested);
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "explain: every line from signature to closing brace in one kind" {
    const functions = @import("functions.zig");
    const gpa = std.testing.allocator;
    const source =
        \\/// Not in the span: before the signature.
        \\fn outer() void {
        \\    a();
        \\
        \\    // why
        \\    const S = struct {
        \\        /// How many.
        \\        n: u8 = 0,
        \\        fn inner() void {
        \\            b();
        \\        }
        \\    };
        \\    c(.{
        \\        .d = 1,
        \\    });
        \\}
    ;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b = try explain(arena, &tree, (try functions.list(arena, &tree))[0].node);
    // Counted: fn outer, a(), const S, n, c(.{, .d. Comment: // why, ///
    // How many. Nested: fn inner, b(), its }. Closer: };, });, }.
    try std.testing.expectEqual(Breakdown{ .span = 15, .counted = 6, .blank = 1, .comment = 2, .closer = 3, .nested = 3 }, b);
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

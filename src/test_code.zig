//! Which functions of a file are test code, held to the tests class
//! whatever their file's class: a test block, a function declared in one,
//! and a function only test code uses, or declared in a declaration only
//! test code uses.
//!
//! A declaration a container holds (a function, or a `const` or `var`) is
//! used only by test code when it is neither `pub` nor `export`, so no
//! other file can reach it; when test code uses it; and when nothing else
//! in the file does. So the property a fuzz test hands to the fuzzer, a
//! fake only tests build and every method of it, and a table of cases only
//! tests read are all test code. What uses it may be test code by the same
//! rule: a helper only another such helper calls is one too.
//!
//! A use is an identifier with its name, outside its own declaration, that
//! names nothing being declared there: not the name of a function, a
//! parameter, a `const` or `var` or a field, nor a field's in a struct
//! literal. Zig lets no local name shadow a declaration, so such an
//! identifier is a use of it, or of a field or a declaration elsewhere
//! with the same name. Those count too, which errs toward the file's
//! class: a name other code uses keeps a declaration there. A use the
//! source spells only as a string, as `@field(@This(), "name")` does, is
//! not seen.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const functions = @import("functions.zig");

/// What makes a function test code: the innermost test block, or
/// declaration only test code uses, that it is or is declared in.
pub const Reason = struct {
    node: Node.Index,
    /// The test block's `test` keyword, or the declaration's name.
    name: Ast.TokenIndex,
    /// Where test code uses the declaration, in source order; empty for a
    /// test block.
    uses: []const Ast.TokenIndex,
};

/// For each of `listed`, `tree`'s functions as `functions.list` gives
/// them, what makes it test code, or null when it is not. Allocated with
/// `arena`, as is the working memory.
pub fn judge(arena: Allocator, tree: *const Ast, listed: []const functions.Function) Allocator.Error![]const ?Reason {
    const spans = try collect(arena, tree);
    try findUses(arena, tree, spans, try declaredNames(arena, tree));
    rule(spans);
    return reasons(arena, spans, listed);
}

/// A part of the file that is test code, or may be: a test block, or a
/// declaration a container holds that is neither `pub` nor `export`.
const Span = struct {
    node: Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    /// A test block's `test` keyword, or the declaration's name.
    name: Ast.TokenIndex,
    is_test: bool,
    /// The innermost span it is inside.
    parent: ?u32 = null,
    /// A declaration's uses outside itself.
    uses: std.ArrayList(Use) = .empty,
    /// A declaration not yet ruled out: nothing but test code, or a
    /// declaration not yet ruled out, uses it.
    kept: bool = false,
    /// A declaration test code uses, and nothing else does.
    used: bool = false,

    fn contains(s: Span, token: Ast.TokenIndex) bool {
        return s.first <= token and token <= s.last;
    }
};

/// An identifier with a declaration's name, and the innermost span it is
/// in.
const Use = struct {
    token: Ast.TokenIndex,
    in: ?u32,
};

/// Every span in `tree`, in source order, a span before those inside it,
/// each with its parent.
fn collect(arena: Allocator, tree: *const Ast) Allocator.Error![]Span {
    var spans: std.ArrayList(Span) = .empty;
    // A stack rather than recursion, so no nesting depth a file can reach
    // runs out of call stack.
    var stack: std.ArrayList(Node.Index) = .empty;
    var kids: std.ArrayList(Node.Index) = .empty;
    try stack.append(arena, .root);
    while (stack.pop()) |node| {
        kids.clearRetainingCapacity();
        try children.append(arena, tree, node, &kids);
        const holds = node == .root or children.isContainer(tree.nodeTag(node));
        for (kids.items) |kid| {
            if (holds) if (spanOf(tree, kid)) |s| try spans.append(arena, s);
            try stack.append(arena, kid);
        }
    }
    std.mem.sort(Span, spans.items, {}, outerFirst);

    // Spans are nested or apart, as the nodes they are made of are.
    var open: std.ArrayList(u32) = .empty;
    for (spans.items, 0..) |*s, i| {
        while (open.getLastOrNull()) |top| {
            if (spans.items[top].last >= s.first) break;
            _ = open.pop();
        }
        s.parent = open.getLastOrNull();
        try open.append(arena, @intCast(i));
    }
    return spans.items;
}

fn outerFirst(_: void, a: Span, b: Span) bool {
    if (a.first != b.first) return a.first < b.first;
    return a.last > b.last;
}

/// The span `node` makes as a member of a container, if it makes one.
fn spanOf(tree: *const Ast, node: Node.Index) ?Span {
    const name: Ast.TokenIndex = switch (tree.nodeTag(node)) {
        .test_decl => tree.nodeMainToken(node),
        .fn_decl => name: {
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?;
            if (proto.visib_token != null) return null;
            if (proto.extern_export_inline_token) |t| {
                if (tree.tokenTag(t) == .keyword_export) return null;
            }
            break :name proto.name_token orelse return null;
        },
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => name: {
            const decl = tree.fullVarDecl(node).?;
            if (decl.visib_token != null or decl.extern_export_token != null) return null;
            break :name decl.ast.mut_token + 1;
        },
        else => return null,
    };
    return .{
        .node = node,
        .first = tree.firstToken(node),
        .last = tree.lastToken(node),
        .name = name,
        .is_test = tree.nodeTag(node) == .test_decl,
    };
}

/// Walks `spans` alongside the tokens, keeping the innermost span around
/// the token reached.
const Sweep = struct {
    spans: []const Span,
    at: ?u32 = null,
    next: u32 = 0,

    /// Moves to `token`, which must not be before the one last moved to.
    fn to(s: *Sweep, token: Ast.TokenIndex) void {
        while (s.at) |i| {
            if (s.spans[i].last >= token) break;
            s.at = s.spans[i].parent;
        }
        // A span that starts here or before and has not ended is inside
        // the one the sweep is at.
        while (s.next < s.spans.len and s.spans[s.next].first <= token) : (s.next += 1) {
            if (s.spans[s.next].last >= token) s.at = s.next;
        }
    }
};

/// Every token that names what is being declared rather than uses
/// something: the name of a function, a parameter, a `const` or `var` or a
/// field, and a field's name in a struct literal.
fn declaredNames(arena: Allocator, tree: *const Ast) Allocator.Error!std.DynamicBitSetUnmanaged {
    var names: std.DynamicBitSetUnmanaged = try .initEmpty(arena, tree.tokens.len);
    var stack: std.ArrayList(Node.Index) = .empty;
    try stack.append(arena, .root);
    while (stack.pop()) |node| {
        markNames(tree, node, &names);
        try children.append(arena, tree, node, &stack);
    }
    return names;
}

fn markNames(tree: *const Ast, node: Node.Index, names: *std.DynamicBitSetUnmanaged) void {
    var one: [1]Node.Index = undefined;
    var two: [2]Node.Index = undefined;
    if (tree.fullFnProto(&one, node)) |proto| {
        if (proto.name_token) |t| names.set(t);
        var params = proto.iterate(tree);
        while (params.next()) |param| if (param.name_token) |t| names.set(t);
    } else if (tree.fullVarDecl(node)) |decl| {
        names.set(decl.ast.mut_token + 1);
    } else if (tree.fullContainerField(node)) |field| {
        if (!field.ast.tuple_like) names.set(field.ast.main_token);
    } else if (tree.fullStructInit(&two, node)) |init| {
        // `.name = value`: the name is two tokens before the value.
        for (init.ast.fields) |value| names.set(tree.firstToken(value) - 2);
    }
}

/// Sets each declaration's uses outside itself: each identifier with its
/// name but those `names` holds.
fn findUses(arena: Allocator, tree: *const Ast, spans: []Span, names: std.DynamicBitSetUnmanaged) Allocator.Error!void {
    var by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (spans, 0..) |s, i| {
        if (s.is_test) continue;
        const entry = try by_name.getOrPut(arena, tree.tokenSlice(s.name));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, @intCast(i));
    }
    var sweep: Sweep = .{ .spans = spans };
    for (0..tree.tokens.len) |t| {
        const token: Ast.TokenIndex = @intCast(t);
        sweep.to(token);
        if (tree.tokenTag(token) != .identifier or names.isSet(token)) continue;
        const named = by_name.get(tree.tokenSlice(token)) orelse continue;
        for (named.items) |i| {
            if (spans[i].contains(token)) continue;
            try spans[i].uses.append(arena, .{ .token = token, .in = sweep.at });
        }
    }
}

/// Marks each declaration test code uses and nothing else does.
fn rule(spans: []Span) void {
    // First rule out each declaration something other than test code
    // uses. What is not ruled out yet counts as test code meanwhile, so
    // declarations that use only each other stay in.
    for (spans) |*s| s.kept = !s.is_test and s.uses.items.len > 0;
    while (ruleOut(spans)) {}
    // Then, of those left, keep what test code reaches: a declaration used
    // by a test block, or by one kept so.
    while (reach(spans)) {}
}

/// Rules out each declaration kept that something other than test code,
/// or a declaration still kept, uses. Returns whether it ruled any out.
fn ruleOut(spans: []Span) bool {
    var changed = false;
    for (spans) |*s| {
        if (!s.kept or allWithin(spans, s.uses.items, .kept)) continue;
        s.kept = false;
        changed = true;
    }
    return changed;
}

/// Marks each declaration kept that a test block, or a declaration
/// marked, uses. Returns whether it marked any.
fn reach(spans: []Span) bool {
    var changed = false;
    for (spans) |*s| {
        if (!s.kept or s.used or !anyWithin(spans, s.uses.items, .used)) continue;
        s.used = true;
        changed = true;
    }
    return changed;
}

const Flag = enum { kept, used };

fn allWithin(spans: []const Span, uses: []const Use, comptime flag: Flag) bool {
    for (uses) |u| if (!within(spans, u.in, flag)) return false;
    return true;
}

fn anyWithin(spans: []const Span, uses: []const Use, comptime flag: Flag) bool {
    for (uses) |u| if (within(spans, u.in, flag)) return true;
    return false;
}

/// Whether span `in`, or one it is inside, is a test block or a
/// declaration with `flag` set.
fn within(spans: []const Span, in: ?u32, comptime flag: Flag) bool {
    var at = in;
    while (at) |i| : (at = spans[i].parent) {
        if (spans[i].is_test or @field(spans[i], @tagName(flag))) return true;
    }
    return false;
}

fn reasons(arena: Allocator, spans: []const Span, listed: []const functions.Function) Allocator.Error![]const ?Reason {
    const out = try arena.alloc(?Reason, listed.len);
    var sweep: Sweep = .{ .spans = spans };
    for (listed, out) |function, *reason| {
        sweep.to(function.token);
        reason.* = null;
        var at = sweep.at;
        while (at) |i| : (at = spans[i].parent) {
            const s = spans[i];
            if (!s.is_test and !s.used) continue;
            const uses = try arena.alloc(Ast.TokenIndex, s.uses.items.len);
            for (s.uses.items, uses) |u, *token| token.* = u.token;
            reason.* = .{ .node = s.node, .name = s.name, .uses = uses };
            break;
        }
    }
    return out;
}

/// `source`'s functions, a line each: the name, and `test code` with the
/// name of what makes it so and the lines it is used at, or nothing.
fn expectJudged(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    try std.testing.expectEqual(0, tree.errors.len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const listed = try functions.list(arena, &tree);
    var got: std.ArrayList(u8) = .empty;
    for (listed, try judge(arena, &tree, listed)) |function, reason| {
        try got.appendSlice(arena, function.name);
        if (reason) |r| {
            try got.print(arena, ": test code, by {s}", .{tree.tokenSlice(r.name)});
            for (r.uses) |use| try got.print(arena, " {d}", .{tree.tokenLocation(0, use).line + 1});
        }
        try got.append(arena, '\n');
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "a test block, and a function declared in one, are test code" {
    try expectJudged(
        \\fn f() void {}
        \\test "t" {
        \\    const S = struct {
        \\        fn g() void {}
        \\        fn h() void {}
        \\    };
        \\    S.g();
        \\}
        \\
    ,
        \\f
        \\test "t": test code, by test
        \\test "t".S.g: test code, by g 7
        \\test "t".S.h: test code, by test
        \\
    );
}

test "a function only tests use is test code; one other code uses, or pub, or unused, is not" {
    try expectJudged(
        \\fn property(input: []const u8) !void { _ = input; }
        \\fn shared() void {}
        \\pub fn exported() void { shared(); }
        \\pub fn helper() void {}
        \\fn unused() void {}
        \\export fn c_abi() void {}
        \\test "fuzz" {
        \\    try std.testing.fuzz({}, property, .{});
        \\    shared();
        \\    helper();
        \\    c_abi();
        \\}
        \\
    ,
        \\property: test code, by property 8
        \\shared
        \\exported
        \\helper
        \\unused
        \\c_abi
        \\test "fuzz": test code, by test
        \\
    );
}

test "what only test code uses is test code, through helpers, tables and fakes" {
    try expectJudged(
        \\fn leaf() void {}
        \\fn middle() void { leaf(); }
        \\fn caseA() void {}
        \\const cases = [_]*const fn () void{caseA};
        \\const Fake = struct {
        \\    calls: u32 = 0,
        \\    pub fn send(f: *Fake) void { f.calls += 1; }
        \\};
        \\const Real = struct {
        \\    pub fn send(r: Real) void { _ = r; }
        \\};
        \\pub fn run(r: Real) void { r.send(); }
        \\test "t" {
        \\    middle();
        \\    for (cases) |case| case();
        \\    var fake: Fake = .{};
        \\    fake.send();
        \\}
        \\
    ,
        \\leaf: test code, by leaf 2
        \\middle: test code, by middle 14
        \\caseA: test code, by caseA 4
        \\Fake.send: test code, by Fake 16
        \\Real.send
        \\run
        \\test "t": test code, by test
        \\
    );
}

test "a declaration, or a field in a struct literal, with its name is no use of it" {
    try expectJudged(
        \\fn decide() void {}
        \\const Plan = struct { decide: *const fn () void };
        \\const Other = struct {
        \\    pub fn decide() void {}
        \\};
        \\pub fn run(chosen: *const fn () void) Plan {
        \\    return .{ .decide = chosen };
        \\}
        \\test "t" { decide(); }
        \\
    ,
        \\decide: test code, by decide 9
        \\Other.decide
        \\run
        \\test "t": test code, by test
        \\
    );
}

test "functions that call only each other are test code when a test reaches them" {
    try expectJudged(
        \\fn even(n: u32) bool { return n == 0 or odd(n - 1); }
        \\fn odd(n: u32) bool { return n != 0 and even(n - 1); }
        \\fn ping(n: u32) void { if (n > 0) pong(n - 1); }
        \\fn pong(n: u32) void { if (n > 0) ping(n - 1); }
        \\test "t" { _ = even(4); }
        \\
    ,
        \\even: test code, by even 2 5
        \\odd: test code, by odd 1
        \\ping
        \\pong
        \\test "t": test code, by test
        \\
    );
}

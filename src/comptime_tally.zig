//! The comptime tally: what of a function runs at compile time, as far as
//! its source shows, and what its source cannot show.
//!
//! Counted, each where it is: a `comptime` block or expression, an
//! `inline for` or `inline while`, an `inline` switch prong, a reflection
//! builtin (`@typeInfo`, `@Type`, `@hasDecl`, `@hasField`, `@FieldType`),
//! a `comptime` parameter and an `anytype` parameter; and whether the
//! function returns a type, whose methods are then measured on their own.
//!
//! Not seen from the source, and said rather than left out: the members of
//! an inferred error set (`!T`), how many times a generic function (one
//! with a comptime or anytype parameter, or that returns a type) is
//! instantiated and with what, and what each anytype parameter must
//! provide.
//!
//! A function declared inside this one has its own tally.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const functions = @import("functions.zig");

pub const Item = struct {
    /// Its keyword or builtin.
    token: Ast.TokenIndex,
    /// As written: `comptime`, `inline for`, `inline prong`, `@typeInfo`,
    /// `comptime T`, `anytype w`.
    construct: []const u8,
};

pub const Tally = struct {
    /// In source order.
    items: []const Item,
    returns_type: bool,
    /// What the source cannot show about it, each said in a sentence.
    unknown: []const []const u8,
};

const reflection = [_][]const u8{ "@typeInfo", "@Type", "@hasDecl", "@hasField", "@FieldType" };

/// The tally of `function`. Allocated with `arena`.
pub fn of(arena: Allocator, tree: *const Ast, function: functions.Function) Allocator.Error!Tally {
    var items: std.ArrayList(Item) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var returns_type = false;
    if (function.kind == .@"fn") {
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(function.node).node_and_node[0]).?;
        const generic = try signature(arena, tree, proto, &items, &unknown);
        returns_type = isType(tree, proto.ast.return_type.unwrap());
        if (generic or returns_type) try unknown.insert(arena, 0, "how many times it is instantiated, and with what");
        if (inferredErrorSet(tree, proto)) try unknown.insert(arena, 0, "the members of its inferred error set");
    }
    try body(arena, tree, function.node, &items);
    std.mem.sort(Item, items.items, {}, before);
    return .{ .items = items.items, .returns_type = returns_type, .unknown = unknown.items };
}

/// Appends each comptime and anytype parameter, and for each anytype what
/// it must provide as unknown; returns whether any parameter is either.
fn signature(arena: Allocator, tree: *const Ast, proto: Ast.full.FnProto, items: *std.ArrayList(Item), unknown: *std.ArrayList([]const u8)) Allocator.Error!bool {
    var generic = false;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const name = if (param.name_token) |t| tree.tokenSlice(t) else "_";
        if (param.comptime_noalias) |t| if (tree.tokenTag(t) == .keyword_comptime) {
            generic = true;
            try items.append(arena, .{ .token = t, .construct = try std.mem.concat(arena, u8, &.{ "comptime ", name }) });
        };
        const ellipsis = param.anytype_ellipsis3 orelse continue;
        if (tree.tokenTag(ellipsis) != .keyword_anytype) continue;
        generic = true;
        try items.append(arena, .{ .token = ellipsis, .construct = try std.mem.concat(arena, u8, &.{ "anytype ", name }) });
        try unknown.append(arena, try std.fmt.allocPrint(arena, "what `{s}` must provide", .{name}));
    }
    return generic;
}

/// Appends each comptime construct in the function's own code.
fn body(arena: Allocator, tree: *const Ast, function: Node.Index, items: *std.ArrayList(Item)) Allocator.Error!void {
    var stack: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, function, &stack);
    while (stack.pop()) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl, .test_decl => continue,
            else => {},
        }
        if (constructOf(tree, node)) |item| try items.append(arena, item);
        try children.append(arena, tree, node, &stack);
    }
}

fn constructOf(tree: *const Ast, node: Node.Index) ?Item {
    const token = tree.nodeMainToken(node);
    return switch (tree.nodeTag(node)) {
        .@"comptime" => .{ .token = token, .construct = "comptime" },
        .while_simple, .while_cont, .@"while" => if (isInline(tree, token)) .{ .token = token - 1, .construct = "inline while" } else null,
        .for_simple, .@"for" => if (isInline(tree, token)) .{ .token = token - 1, .construct = "inline for" } else null,
        .switch_case_inline, .switch_case_inline_one => .{ .token = tree.fullSwitchCase(node).?.inline_token.?, .construct = "inline prong" },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => for (reflection) |name| {
            if (std.mem.eql(u8, tree.tokenSlice(token), name)) break .{ .token = token, .construct = name };
        } else null,
        else => null,
    };
}

fn isInline(tree: *const Ast, token: Ast.TokenIndex) bool {
    return token > 0 and tree.tokenTag(token - 1) == .keyword_inline;
}

fn isType(tree: *const Ast, node: ?Node.Index) bool {
    const n = node orelse return false;
    return tree.nodeTag(n) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(n)), "type");
}

/// Whether the return type is `!T`: an error set the compiler infers from
/// the body.
fn inferredErrorSet(tree: *const Ast, proto: Ast.full.FnProto) bool {
    const return_type = proto.ast.return_type.unwrap() orelse return false;
    const first = tree.firstToken(return_type);
    return first > 0 and tree.tokenTag(first - 1) == .bang;
}

fn before(_: void, a: Item, b: Item) bool {
    return a.token < b.token;
}

test "the tally: each construct where it is, and what the source cannot show" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\fn Wrap(comptime T: type, w: anytype) type {
        \\    comptime {
        \\        if (@typeInfo(T) != .@"struct") @compileError("no");
        \\    }
        \\    inline for (@typeInfo(T).@"struct".fields) |f| _ = f;
        \\    return struct {
        \\        fn get() T {
        \\            inline while (false) {}
        \\            return undefined;
        \\        }
        \\    };
        \\}
        \\fn read(r: anytype) !u8 {
        \\    switch (r.kind) {
        \\        inline else => |k| _ = k,
        \\    }
        \\    return 0;
        \\}
        \\fn plain(x: u8) error{Bad}!u8 {
        \\    return x;
        \\}
    ;
    var tree = try Ast.parse(arena, source, .{});
    try std.testing.expectEqual(0, tree.errors.len);
    var got: std.ArrayList(u8) = .empty;
    for (try functions.list(arena, &tree)) |function| {
        const t = try of(arena, &tree, function);
        try got.print(arena, "{s}{s}\n", .{ function.name, if (t.returns_type) ", returns a type" else "" });
        for (t.items) |item| {
            const loc = tree.tokenLocation(0, item.token);
            try got.print(arena, "  {d}:{d} {s}\n", .{ loc.line + 1, loc.column + 1, item.construct });
        }
        for (t.unknown) |u| try got.print(arena, "  unknown: {s}\n", .{u});
    }
    // get, inside the struct Wrap returns, has its own tally: Wrap's does
    // not hold its inline while. plain's error set is written out.
    try std.testing.expectEqualStrings(
        \\Wrap, returns a type
        \\  1:9 comptime T
        \\  1:30 anytype w
        \\  2:5 comptime
        \\  3:13 @typeInfo
        \\  5:5 inline for
        \\  5:17 @typeInfo
        \\  unknown: how many times it is instantiated, and with what
        \\  unknown: what `w` must provide
        \\Wrap.get
        \\  8:13 inline while
        \\read
        \\  13:12 anytype r
        \\  15:9 inline prong
        \\  unknown: the members of its inferred error set
        \\  unknown: how many times it is instantiated, and with what
        \\  unknown: what `r` must provide
        \\plain
        \\
    , got.items);
}

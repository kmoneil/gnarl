//! What a range of a function's lines needs from the rest of it and must
//! give back, were the lines lifted into a function of their own: the
//! names it reads that the function declares outside them (its parameters,
//! locals and captures), which the new function would take; and the names
//! it assigns, or declares, that are read after it, which the new function
//! would have to return or take by pointer.
//!
//! Names are matched by their text: Zig lets no local shadow another, so
//! within one function a name means one thing, but for siblings (two
//! blocks each with an `i`), which this may confuse. A field (`a.b`), an
//! enum literal, a label and a name declared outside the function are not
//! the function's, and are left out. Types are given where a declaration
//! writes them.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");
const functions = @import("functions.zig");
const lines = @import("lines.zig");

pub const Name = struct {
    name: []const u8,
    /// As its declaration writes it; empty when it does not.
    type: []const u8 = "",
};

pub const Given = struct {
    name: []const u8,
    type: []const u8 = "",
    /// `assigned in the lines` or `declared in the lines`, and read after
    /// them either way.
    why: []const u8,
};

pub const Flow = struct {
    needs: []const Name,
    gives: []const Given,
};

/// What the tokens `first` to `last` of `function` need and give back.
/// Allocated with `arena`.
pub fn of(arena: Allocator, tree: *const Ast, function: functions.Function, first: Ast.TokenIndex, last: Ast.TokenIndex) Allocator.Error!Flow {
    var s: Scan = .{ .arena = arena, .tree = tree, .first = first, .last = last };
    try s.declarations(function);
    try s.assignments(function.node);
    try s.uses(function.node);
    return s.result();
}

const Decl = struct { token: Ast.TokenIndex, type: []const u8, kind: Kind };

/// A capture's name lives only in its own construct, so one in the lines
/// is never read after them: one of that name there is another's.
const Kind = enum { param, local, capture };

const Scan = struct {
    arena: Allocator,
    tree: *const Ast,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    /// Each name the function declares, by its text: where, and its type.
    decls: std.StringArrayHashMapUnmanaged(Decl) = .empty,
    /// The names declared in the lines: they are the lines' own.
    inside: std.StringArrayHashMapUnmanaged(Ast.TokenIndex) = .empty,
    /// Each token that only receives a value: the target of a plain `=`.
    written_only: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .empty,
    /// The names assigned in the lines.
    assigned: std.StringArrayHashMapUnmanaged(void) = .empty,
    read_in: std.StringArrayHashMapUnmanaged(void) = .empty,
    read_after: std.StringArrayHashMapUnmanaged(void) = .empty,
    nested: []const [2]Ast.TokenIndex = &.{},

    fn in(s: *const Scan, t: Ast.TokenIndex) bool {
        return s.first <= t and t <= s.last;
    }

    /// The parameters, the locals (`const`, `var`) and the captures.
    fn declarations(s: *Scan, function: functions.Function) Allocator.Error!void {
        const tree = s.tree;
        s.nested = (try lines.holes(s.arena, tree, function.node)).functions;
        if (function.kind == .@"fn") {
            var buffer: [1]Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, tree.nodeData(function.node).node_and_node[0]).?;
            var it = proto.iterate(tree);
            while (it.next()) |param| {
                const t = param.name_token orelse continue;
                try s.declare(t, if (param.type_expr) |e| text(tree, e) else "anytype", .param);
            }
        }
        var stack: std.ArrayList(Node.Index) = .empty;
        try children.append(s.arena, tree, function.node, &stack);
        while (stack.pop()) |node| switch (tree.nodeTag(node)) {
            .fn_decl, .test_decl => {},
            .simple_var_decl, .local_var_decl, .aligned_var_decl => {
                const decl = tree.fullVarDecl(node).?;
                try s.declare(decl.ast.mut_token + 1, if (decl.ast.type_node.unwrap()) |t| text(tree, t) else "", .local);
                try children.append(s.arena, tree, node, &stack);
            },
            else => try children.append(s.arena, tree, node, &stack),
        };
        try s.captures(function.node);
    }

    /// Each name between the bars of a capture: `|x|`, `|*x, i|`, after
    /// a condition, a `catch`, an `else` or a prong's `=>`.
    fn captures(s: *Scan, function: Node.Index) Allocator.Error!void {
        const tree = s.tree;
        var t = tree.firstToken(function);
        while (t < tree.lastToken(function)) : (t += 1) {
            if (tree.tokenTag(t) != .pipe or !opensCapture(tree.tokenTag(t - 1))) continue;
            t += 1;
            while (t < tree.lastToken(function) and tree.tokenTag(t) != .pipe) : (t += 1) {
                if (tree.tokenTag(t) == .identifier) try s.declare(t, "", .capture);
            }
        }
    }

    fn declare(s: *Scan, t: Ast.TokenIndex, type_text: []const u8, kind: Kind) Allocator.Error!void {
        const name = s.tree.tokenSlice(t);
        if (std.mem.eql(u8, name, "_") or s.inNested(t)) return;
        if (s.in(t)) try s.inside.put(s.arena, name, t);
        const seen = try s.decls.getOrPut(s.arena, name);
        if (!seen.found_existing or !s.in(t)) seen.value_ptr.* = .{ .token = t, .type = type_text, .kind = kind };
    }

    /// The targets of assignments: a plain `=` only writes its target, a
    /// compound one (`+=`) reads it too.
    fn assignments(s: *Scan, function: Node.Index) Allocator.Error!void {
        const tree = s.tree;
        var stack: std.ArrayList(Node.Index) = .empty;
        try children.append(s.arena, tree, function, &stack);
        while (stack.pop()) |node| {
            switch (tree.nodeTag(node)) {
                .fn_decl, .test_decl => continue,
                .assign, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => {
                    const target = tree.nodeData(node).node_and_node[0];
                    if (tree.nodeTag(target) == .identifier) {
                        const t = tree.nodeMainToken(target);
                        if (tree.nodeTag(node) == .assign) try s.written_only.put(s.arena, t, {});
                        if (s.in(t)) try s.assigned.put(s.arena, tree.tokenSlice(t), {});
                    }
                },
                else => {},
            }
            try children.append(s.arena, tree, node, &stack);
        }
    }

    /// Each read of a name: an identifier that is not a declaration, a
    /// field, an enum literal, a label or the bare target of an `=`.
    fn uses(s: *Scan, function: Node.Index) Allocator.Error!void {
        const tree = s.tree;
        var t = tree.firstToken(function);
        while (t <= tree.lastToken(function)) : (t += 1) {
            if (tree.tokenTag(t) != .identifier or !s.isRead(t)) continue;
            const name = tree.tokenSlice(t);
            const decl = s.decls.get(name) orelse continue;
            if (decl.token == t) continue;
            if (s.in(t)) {
                try s.read_in.put(s.arena, name, {});
            } else if (t > s.last) try s.read_after.put(s.arena, name, {});
        }
    }

    fn isRead(s: *const Scan, t: Ast.TokenIndex) bool {
        const tree = s.tree;
        const before = tree.tokenTag(t - 1);
        if (before == .period or before == .colon) return false;
        if (t + 1 < tree.tokens.len and tree.tokenTag(t + 1) == .colon) return false;
        return !s.written_only.contains(t) and !s.inNested(t);
    }

    /// Whether `name` is declared in the lines by a `const` or `var`, the
    /// only declaration there that lives on after them.
    fn declaredLocal(s: *const Scan, name: []const u8) bool {
        const t = s.inside.get(name) orelse return false;
        const before = s.tree.tokenTag(t - 1);
        return before == .keyword_const or before == .keyword_var;
    }

    fn inNested(s: *const Scan, t: Ast.TokenIndex) bool {
        for (s.nested) |r| if (r[0] <= t and t <= r[1]) return true;
        return false;
    }

    fn result(s: *Scan) Allocator.Error!Flow {
        var needs: std.ArrayList(Name) = .empty;
        for (s.read_in.keys()) |name| {
            if (s.inside.contains(name)) continue;
            try needs.append(s.arena, .{ .name = name, .type = s.decls.get(name).?.type });
        }
        var gives: std.ArrayList(Given) = .empty;
        for (s.assigned.keys()) |name| {
            if (s.inside.contains(name) or !s.read_after.contains(name) or !s.decls.contains(name)) continue;
            try gives.append(s.arena, .{ .name = name, .type = s.decls.get(name).?.type, .why = "assigned in the lines" });
        }
        for (s.inside.keys()) |name| {
            if (!s.read_after.contains(name) or !s.declaredLocal(name)) continue;
            try gives.append(s.arena, .{ .name = name, .type = s.decls.get(name).?.type, .why = "declared in the lines" });
        }
        return .{ .needs = needs.items, .gives = gives.items };
    }
};

/// Whether a parameter typed `type_text` is context the parameter count
/// leaves out: an Allocator or an Io.
pub fn isContext(type_text: []const u8) bool {
    return std.mem.endsWith(u8, type_text, "Allocator") or std.mem.eql(u8, type_text, "Io") or std.mem.endsWith(u8, type_text, ".Io");
}

/// Whether a `|` after a token so tagged opens a capture.
fn opensCapture(before: std.zig.Token.Tag) bool {
    return switch (before) {
        .r_paren, .keyword_catch, .keyword_else, .equal_angle_bracket_right => true,
        else => false,
    };
}

/// The source of `node`, first token to last.
fn text(tree: *const Ast, node: Node.Index) []const u8 {
    const last = tree.lastToken(node);
    return tree.source[tree.tokenStart(tree.firstToken(node)) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
}

fn expectFlow(source: [:0]const u8, first_line: u32, last_line: u32, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = try Ast.parse(arena, source, .{});
    try std.testing.expectEqual(0, tree.errors.len);
    const function = (try functions.list(arena, &tree))[0];
    var first: Ast.TokenIndex = 0;
    while (tree.tokenLocation(0, first).line + 1 < first_line) first += 1;
    var last = first;
    while (last + 1 < tree.tokens.len and tree.tokenLocation(0, last + 1).line + 1 <= last_line) last += 1;
    const flow = try of(arena, &tree, function, first, last);
    var got: std.ArrayList(u8) = .empty;
    for (flow.needs) |n| try got.print(arena, "needs {s}{s}{s}\n", .{ n.name, if (n.type.len > 0) ": " else "", n.type });
    for (flow.gives) |g| try got.print(arena, "gives {s} ({s})\n", .{ g.name, g.why });
    try std.testing.expectEqualStrings(expected, got.items);
}

test "a prong lifted out: what it reads it takes, what it assigns and is read after it gives back" {
    try expectFlow(
        \\fn pick(rows: []const Row, selectors: []const Selector, picked: []bool) void {
        \\    for (selectors) |selector| {
        \\        var any = false;
        \\        switch (selector) {
        \\            .at => |at| {
        \\                var around: ?usize = null;
        \\                for (rows, 0..) |row, i| {
        \\                    if (row.line == at.line) around = i;
        \\                }
        \\                if (around) |i| {
        \\                    picked[i] = true;
        \\                    any = true;
        \\                }
        \\            },
        \\            .name => {},
        \\        }
        \\        if (!any) fail();
        \\    }
        \\}
    , 6, 13,
        // around, row and i are the lines' own; at is the prong's capture,
        // outside them; any is only written, then read after.
        \\needs rows: []const Row
        \\needs at
        \\needs picked: []bool
        \\gives any (assigned in the lines)
        \\
    );
}

test "a capture in the lines is not given back, though a sibling's of its name is read after" {
    try expectFlow(
        \\fn f(xs: []const u8, ys: []const u8) usize {
        \\    var n: usize = 0;
        \\    for (xs) |x| n += x;
        \\    for (ys) |x| n -= x;
        \\    return n;
        \\}
    , 3, 3,
        \\needs xs: []const u8
        \\needs n: usize
        \\gives n (assigned in the lines)
        \\
    );
}

test "a name declared in the lines and read after them is given back; fields and labels are no names" {
    try expectFlow(
        \\fn f(xs: []const u8) usize {
        \\    var total: usize = 0;
        \\    const n = blk: {
        \\        for (xs) |x| total += x;
        \\        break :blk xs.len;
        \\    };
        \\    const s: S = .{ .total = total };
        \\    return n + s.total;
        \\}
    , 3, 6,
        // total is read (+= reads it) and assigned, and read after; n,
        // declared on line 3, is read after; .total and blk are not names.
        \\needs xs: []const u8
        \\needs total: usize
        \\gives total (assigned in the lines)
        \\gives n (declared in the lines)
        \\
    );
}

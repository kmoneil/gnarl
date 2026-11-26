//! Which of a function's decisions are made at compile time, as far as its
//! source shows. In any one instantiation such a decision always goes the
//! same way, so it is no path: the cyclomatic count adds nothing for it,
//! and the cognitive count charges it as a reader follows it but does not
//! nest what it holds.
//!
//! Decided at compile time:
//! - Anything in comptime code: a `comptime` block or expression, the
//!   declarations of a container declared in the function, and the whole
//!   of a function that returns a type, which runs only at compile time.
//! - A compile-time assertion: an `if` with no `else` whose body is only
//!   `@compileError`, or an `orelse` or `catch` whose handler is.
//! - An `if` or `switch` with a branch that is only `@compileError`, which
//!   compiles only when the branch is decided at compile time.
//! - An `if` whose condition, a `switch` whose operand, or an `orelse` or
//!   `catch` whose left side is known at compile time; and an `and` or `or`
//!   with a side known at compile time, which leaves at most the other to
//!   decide at run time.
//!
//! Known at compile time, from the source alone: a literal, a type, a
//! primitive (`u8`, `true`), a `comptime` parameter or one whose type is
//! `type`, and a field of one; a local `const` set to what is known, an
//! `if`'s or `catch`'s capture of what is known, a capture of an `inline
//! for` over what is known, and the tag an `inline` prong captures; a
//! declaration of a container the function is in, but a `var`; what a
//! function declared inside another reads of the one around it, which it
//! can read only when it is known; the reflection builtins (`@typeInfo`,
//! `@TypeOf`, `@sizeOf`, `@hasDecl` and the like); `@import("builtin")`
//! and what is read through it; and an operator, a conversion builtin, a
//! `comptime` expression or a field of what is known. A call is not known,
//! nor is what is read through another file's namespace
//! (`std.debug.runtime_safety`), which may be a `var`, nor a name declared
//! nowhere in the file.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

const children = @import("children.zig");

/// Why a decision is made at compile time.
pub const Why = enum {
    /// It is in comptime code.
    in_comptime,
    /// An `if` with no `else` whose body is only `@compileError`, or an
    /// `orelse` or `catch` whose handler is.
    assertion,
    /// What it decides on is known at compile time; for an `and` or an
    /// `or`, one side is.
    known,
    /// A branch of it is only `@compileError`.
    forced,
    /// It is in what an assertion, or a decision with a branch that is
    /// only `@compileError`, decides on.
    in_condition,

    /// Why it adds no path, said for a construct so tagged.
    pub fn text(why: Why, tag: Node.Tag) []const u8 {
        const kind: enum { @"if", @"switch", logic, handler, loop } = switch (tag) {
            .if_simple, .@"if" => .@"if",
            .@"switch", .switch_comma => .@"switch",
            .bool_and, .bool_or => .logic,
            .@"orelse", .@"catch" => .handler,
            else => .loop,
        };
        return switch (why) {
            .in_comptime => "comptime code: decided at compile time",
            .in_condition => "in a condition decided at compile time",
            .assertion => switch (kind) {
                .handler => "a compile-time assertion: its handler is only @compileError",
                else => "a compile-time assertion: its body is only @compileError",
            },
            .forced => "a branch is only @compileError, so it is decided at compile time",
            .known => switch (kind) {
                .@"if" => "its condition is known at compile time: one way in each instantiation",
                .@"switch" => "its operand is known at compile time: one prong in each instantiation",
                .logic => "a side is known at compile time: at most the other is decided at run time",
                .handler, .loop => "its left side is known at compile time",
            },
        };
    }
};

/// The decisions of one function made at compile time, and why.
pub const Decided = struct {
    whys: std.AutoHashMapUnmanaged(Node.Index, Why) = .empty,

    /// Why the decision `node` is made at compile time, or null when it is
    /// not, or not known to be. A switch's prongs answer as their switch.
    pub fn get(d: *const Decided, node: Node.Index) ?Why {
        return d.whys.get(node);
    }
};

/// The decisions of `function`, a `fn_decl` or `test_decl`, made at compile
/// time. Allocated with `arena`.
pub fn of(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!Decided {
    var known: Known = .{ .arena = arena, .tree = tree, .function = function };
    var d: Decided = .{};
    const Item = struct { node: Node.Index, context: ?Why };
    var stack: std.ArrayList(Item) = .empty;
    var kids: std.ArrayList(Node.Index) = .empty;

    // A function that returns a type runs only at compile time.
    const context: ?Why = if (returnsType(tree, function)) .in_comptime else null;
    try children.appendCode(arena, tree, function, &kids);
    for (kids.items) |kid| try stack.append(arena, .{ .node = kid, .context = context });
    while (stack.pop()) |item| {
        switch (tree.nodeTag(item.node)) {
            .fn_decl, .test_decl => continue,
            else => {},
        }
        const in = try decide(&d, &known, item.node, item.context);
        kids.clearRetainingCapacity();
        try children.appendCode(arena, tree, item.node, &kids);
        for (kids.items) |kid| try stack.append(arena, .{ .node = kid, .context = in.of(kid) });
    }
    return d;
}

/// Whether `function` is a `fn` whose return type is `type`.
pub fn returnsType(tree: *const Ast, function: Node.Index) bool {
    if (tree.nodeTag(function) != .fn_decl) return false;
    var buffer: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]).?;
    const return_type = proto.ast.return_type.unwrap() orelse return false;
    return tree.nodeTag(return_type) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_type)), "type");
}

/// What a node's children are in.
const In = struct {
    /// What its children are in.
    children: ?Why,
    /// Its condition, operand or left side, if it has one.
    condition: ?Node.Index = null,
    /// What `condition` is in.
    condition_context: ?Why = null,

    fn of(in: In, kid: Node.Index) ?Why {
        return if (in.condition == kid) in.condition_context else in.children;
    }
};

/// Records whether `node`, in `context`, is a decision made at compile
/// time, and says what its children are in.
fn decide(d: *Decided, known: *Known, node: Node.Index, context: ?Why) Allocator.Error!In {
    const tree = known.tree;
    const tag = tree.nodeTag(node);
    // Why the decision is made at compile time, if it is, and its
    // condition, operand or left side.
    const why: ?Why, const condition: ?Node.Index = switch (tag) {
        .@"comptime" => return .{ .children = context orelse .in_comptime },
        .if_simple, .@"if" => .{ try ifWhy(known, tree.fullIf(node).?, context), tree.fullIf(node).?.ast.cond_expr },
        .@"switch", .switch_comma => .{ context orelse try switchWhy(known, tree.fullSwitch(node).?), tree.fullSwitch(node).?.ast.condition },
        .bool_and, .bool_or => .{ context orelse try logicWhy(known, node), null },
        .@"orelse", .@"catch" => .{ try handlerWhy(known, node, context), tree.nodeData(node).node_and_node[0] },
        .while_simple, .while_cont, .@"while", .for_simple, .@"for" => .{ context, null },
        // A container's declarations are comptime code.
        else => return .{ .children = if (children.isContainer(tag)) context orelse .in_comptime else context },
    };
    if (why) |w| {
        try d.whys.put(known.arena, node, w);
        // A switch's prongs answer as it does.
        if (tree.fullSwitch(node)) |full| for (full.ast.cases) |case| try d.whys.put(known.arena, case, w);
    }
    return .{ .children = context, .condition = condition, .condition_context = context orelse inCondition(why) };
}

fn logicWhy(known: *Known, node: Node.Index) Allocator.Error!?Why {
    const lhs, const rhs = known.tree.nodeData(node).node_and_node;
    return if (try known.isKnown(lhs) or try known.isKnown(rhs)) .known else null;
}

/// An assertion is one wherever it is; anything else in `context` is
/// decided as it is.
fn handlerWhy(known: *Known, node: Node.Index, context: ?Why) Allocator.Error!?Why {
    const lhs, const rhs = known.tree.nodeData(node).node_and_node;
    if (onlyCompileError(known.tree, rhs)) return .assertion;
    if (context) |c| return c;
    return if (try known.isKnown(lhs)) .known else null;
}

/// What a decided decision's condition is in: for one decided by its
/// `@compileError`, the whole condition is decided at compile time; for one
/// decided by what it reads, each part answers for itself.
fn inCondition(why: ?Why) ?Why {
    return switch (why orelse return null) {
        .assertion, .forced => .in_condition,
        .known, .in_comptime, .in_condition => null,
    };
}

/// As `handlerWhy`.
fn ifWhy(known: *Known, full: Ast.full.If, context: ?Why) Allocator.Error!?Why {
    const tree = known.tree;
    const then_only = onlyCompileError(tree, full.ast.then_expr);
    const else_expr = full.ast.else_expr.unwrap();
    if (then_only and else_expr == null) return .assertion;
    if (context) |c| return c;
    if (try known.isKnown(full.ast.cond_expr)) return .known;
    if (then_only) return .forced;
    if (else_expr) |e| if (onlyCompileError(tree, e)) return .forced;
    return null;
}

fn switchWhy(known: *Known, full: Ast.full.Switch) Allocator.Error!?Why {
    const tree = known.tree;
    // A labeled switch is entered with its operand but goes on to the
    // prong each `continue` to it names, at run time.
    if (full.label_token == null and try known.isKnown(full.ast.condition)) return .known;
    for (full.ast.cases) |case| {
        if (onlyCompileError(tree, tree.fullSwitchCase(case).?.ast.target_expr)) return .forced;
    }
    return null;
}

/// Whether `node` is a call of `@compileError`, or a block of nothing else.
pub fn onlyCompileError(tree: *const Ast, node: Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@compileError");
        },
        .block_two, .block_two_semicolon, .block, .block_semicolon => {
            var buffer: [2]Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            return statements.len == 1 and onlyCompileError(tree, statements[0]);
        },
        else => return false,
    }
}

/// What is known at compile time of an expression, and of what is read
/// through it.
const Kind = union(enum) {
    /// Not known at compile time, or not known to be.
    runtime,
    /// Known, and so is what is read through it.
    value,
    /// A type: known, as is what is read through it, and so is what it is
    /// compared with, which must be a type too.
    type,
    /// Known, but what is read through it is another file's, which may be
    /// a `var`, or what a call gave, which may hold one.
    namespace,
    /// Known, but it points at what may change, so what is read through it
    /// is not.
    pointer,
    /// A container declared in this file: what is read through it is the
    /// declaration of that name.
    container: Node.Index,

    fn isKnown(k: Kind) bool {
        return k != .runtime;
    }

    fn isType(k: Kind) bool {
        return k == .type or k == .container;
    }
};

/// What a binding is known to be, or the expression that says.
const Source = union(enum) { fixed: Kind, of: Node.Index };

/// A name the function binds: a parameter, a local `const` or `var`, a
/// capture.
const Binding = struct {
    /// Its name.
    token: Ast.TokenIndex,
    /// What it is known to be, or the expression that says.
    kind: Source,
    /// `kind`, worked out, once it has been.
    found: ?Kind = null,
};

/// Builtins that give a type.
const type_builtins = [_][]const u8{
    "@TypeOf", "@FieldType", "@EnumLiteral", "@Int",  "@Tuple",  "@Pointer",
    "@Fn",     "@Struct",    "@Union",       "@Enum", "@Vector", "@Frame",
};

/// Builtins whose result is known at compile time whatever they are given:
/// what they take must be known.
const always_known = [_][]const u8{
    "@typeInfo",    "@typeName", "@sizeOf",   "@bitSizeOf",  "@alignOf", "@offsetOf",
    "@bitOffsetOf", "@hasDecl",  "@hasField", "@inComptime", "@src",     "@embedFile",
};

/// Builtins whose result is known when all they are given is.
const known_of_known = [_][]const u8{
    "@as",           "@intCast",   "@truncate",     "@intFromEnum",  "@enumFromInt", "@intFromBool",
    "@tagName",      "@errorName", "@field",        "@min",          "@max",         "@abs",
    "@bitCast",      "@floatCast", "@floatFromInt", "@intFromFloat", "@divExact",    "@divFloor",
    "@divCeil",      "@divTrunc",  "@mod",          "@rem",          "@shlExact",    "@shrExact",
    "@clz",          "@ctz",       "@popCount",     "@byteSwap",     "@bitReverse",  "@errorFromInt",
    "@intFromError", "@errorCast", "@splat",        "@sqrt",         "@floor",       "@ceil",
    "@trunc",        "@round",
};

fn isOneOf(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// What is known whatever is in it: a literal, a `comptime` expression.
const always_known_tags = [_]Node.Tag{
    .number_literal, .char_literal,     .string_literal, .multiline_string_literal,
    .enum_literal,   .anyframe_literal, .error_value,    .@"comptime",
};

/// What writes a type.
const type_tags = [_]Node.Tag{
    .optional_type, .array_type,         .array_type_sentinel, .ptr_type_aligned, .ptr_type_sentinel,
    .ptr_type,      .ptr_type_bit_range, .error_union,         .merge_error_sets, .error_set_decl,
    .anyframe_type, .fn_proto_simple,    .fn_proto_multi,      .fn_proto_one,     .fn_proto,
};

/// What is known when all its children are: an operator, an `if`,
/// `orelse` or `catch` as a value, an array or struct literal.
const operator_tags = [_]Node.Tag{
    .less_than,       .greater_than,          .less_or_equal,       .greater_or_equal,
    .mul,             .div,                   .mod,                 .mul_wrap,
    .mul_sat,         .add,                   .sub,                 .array_cat,
    .add_wrap,        .sub_wrap,              .add_sat,             .sub_sat,
    .shl,             .shl_sat,               .shr,                 .bit_and,
    .bit_xor,         .bit_or,                .bool_and,            .bool_or,
    .bool_not,        .negation,              .negation_wrap,       .bit_not,
    .@"orelse",       .@"catch",              .if_simple,           .@"if",
    .array_init_one,  .array_init_one_comma,  .array_init_dot_two,  .array_init_dot_two_comma,
    .array_init_dot,  .array_init_dot_comma,  .array_init,          .array_init_comma,
    .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma,
    .struct_init_dot, .struct_init_dot_comma, .struct_init,         .struct_init_comma,
};

fn isTagOf(tag: Node.Tag, tags: []const Node.Tag) bool {
    return std.mem.findScalar(Node.Tag, tags, tag) != null;
}

/// How deep an expression is followed before it is taken as not known.
const max_depth = 64;

/// What is known at compile time in one function, worked out as it is
/// asked for.
const Known = struct {
    arena: Allocator,
    tree: *const Ast,
    function: Node.Index,
    /// The names the function binds, each name's in source order; null
    /// until first needed.
    bindings: ?std.StringHashMapUnmanaged(std.ArrayList(Binding)) = null,
    /// The containers the function is in, the file first; null until first
    /// needed.
    containers: ?[]const Node.Index = null,
    /// The functions and test blocks the function is declared inside, set
    /// with `containers`.
    around: []const Node.Index = &.{},
    /// Names the function does not bind, as what they are known to be.
    outer: std.StringHashMapUnmanaged(Kind) = .empty,

    fn isKnown(k: *Known, node: Node.Index) Allocator.Error!bool {
        return (try k.kindOf(node, 0)).isKnown();
    }

    fn kindOf(k: *Known, node: Node.Index, depth: u32) Allocator.Error!Kind {
        if (depth > max_depth) return .runtime;
        const tree = k.tree;
        const tag = tree.nodeTag(node);
        if (children.isContainer(tag)) return .{ .container = node };
        if (isTagOf(tag, &always_known_tags)) return .value;
        if (isTagOf(tag, &type_tags)) return .type;
        return switch (tag) {
            .identifier => k.identifier(node, depth),
            .grouped_expression => k.kindOf(tree.nodeData(node).node_and_token[0], depth + 1),
            .field_access => {
                const lhs, const name = tree.nodeData(node).node_and_token;
                return k.field(try k.kindOf(lhs, depth + 1), name, depth);
            },
            .array_access, .unwrap_optional => k.indexed(node, depth),
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => k.builtin(node, depth),
            .equal_equal, .bang_equal => k.comparison(node, depth),
            else => {
                if (!isTagOf(tag, &operator_tags)) return .runtime;
                var kids: std.ArrayList(Node.Index) = .empty;
                try children.append(k.arena, tree, node, &kids);
                return k.allKnown(kids.items, depth);
            },
        };
    }

    /// `a[i]` or `a.?`: known when `a` is a value, not what it points at,
    /// and `i` is known.
    fn indexed(k: *Known, node: Node.Index, depth: u32) Allocator.Error!Kind {
        var kids: std.ArrayList(Node.Index) = .empty;
        try children.append(k.arena, k.tree, node, &kids);
        if (try k.kindOf(kids.items[0], depth + 1) != .value) return .runtime;
        return k.allKnown(kids.items[1..], depth);
    }

    /// `a == b` or `a != b`. A type is compared only with a type, and every
    /// type is known: `T == std.mem.Allocator` is, whatever the other file
    /// declares.
    fn comparison(k: *Known, node: Node.Index, depth: u32) Allocator.Error!Kind {
        const lhs, const rhs = k.tree.nodeData(node).node_and_node;
        const a = try k.kindOf(lhs, depth + 1);
        const b = try k.kindOf(rhs, depth + 1);
        if (a.isType() or b.isType() or (a.isKnown() and b.isKnown())) return .value;
        return .runtime;
    }

    fn allKnown(k: *Known, nodes: []const Node.Index, depth: u32) Allocator.Error!Kind {
        for (nodes) |n| if (!(try k.kindOf(n, depth + 1)).isKnown()) return .runtime;
        return .value;
    }

    /// What is read through `of` by the name `name`.
    fn field(k: *Known, through: Kind, name: Ast.TokenIndex, depth: u32) Allocator.Error!Kind {
        return switch (through) {
            .runtime, .namespace, .pointer => .runtime,
            .value, .type => .value,
            .container => |c| k.member(c, k.tree.tokenSlice(name), depth),
        };
    }

    fn builtin(k: *Known, node: Node.Index, depth: u32) Allocator.Error!Kind {
        const tree = k.tree;
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        var buffer: [2]Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, node).?;
        if (std.mem.eql(u8, name, "@import")) {
            if (params.len == 1 and tree.nodeTag(params[0]) == .string_literal and
                std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(params[0])), "\"builtin\"")) return .value;
            return .namespace;
        }
        if (std.mem.eql(u8, name, "@This")) {
            const chain = try k.enclosing();
            return .{ .container = chain[chain.len - 1] };
        }
        if (isOneOf(name, &type_builtins)) return .type;
        if (isOneOf(name, &always_known)) return .value;
        if (isOneOf(name, &known_of_known)) return k.allKnown(params, depth);
        return .runtime;
    }

    fn identifier(k: *Known, node: Node.Index, depth: u32) Allocator.Error!Kind {
        const tree = k.tree;
        const token = tree.nodeMainToken(node);
        const name = tree.tokenSlice(token);
        const bindings = try k.bindingsOf();
        if (bindings.getPtr(name)) |list| {
            // Zig lets no name shadow another, so the binding a name reads
            // is the last one before it.
            var found: ?*Binding = null;
            for (list.items) |*b| {
                if (b.token < token) found = b;
            }
            const b = found orelse return .runtime;
            if (b.found) |kind| return kind;
            // Not found yet: a cycle, which Zig would refuse, reads as not
            // known.
            b.found = .runtime;
            const kind: Kind = switch (b.kind) {
                .fixed => |f| f,
                .of => |n| try k.kindOf(n, depth + 1),
            };
            b.found = kind;
            return kind;
        }
        return k.outerName(name, depth);
    }

    /// What a name the function does not bind is: a primitive, a
    /// declaration of a container it is in, or what a function around it
    /// binds, which a function inside can read only when it is known.
    fn outerName(k: *Known, name: []const u8, depth: u32) Allocator.Error!Kind {
        if (std.zig.primitives.isPrimitive(name)) {
            return if (isOneOf(name, &.{ "true", "false", "null", "undefined" })) .value else .type;
        }
        if (k.outer.get(name)) |kind| return kind;
        try k.outer.put(k.arena, name, .runtime);
        const chain = try k.enclosing();
        var i = chain.len;
        const kind: Kind = while (i > 0) {
            i -= 1;
            if (try k.declared(chain[i], name, depth)) |found| break found;
        } else try k.boundAround(name);
        try k.outer.put(k.arena, name, kind);
        return kind;
    }

    /// Known when a function around this one binds `name`, as it can be read
    /// from here only then; not known when nothing does, as of a name that
    /// is declared nowhere in the file.
    fn boundAround(k: *Known, name: []const u8) Allocator.Error!Kind {
        for (k.around) |f| {
            if ((try collect(k.arena, k.tree, f)).contains(name)) return .value;
        }
        return .runtime;
    }

    /// What is read through the container `c` by `name`: its declaration
    /// of that name, or a field (an enum's or a union's tag).
    fn member(k: *Known, c: Node.Index, name: []const u8, depth: u32) Allocator.Error!Kind {
        if (try k.declared(c, name, depth)) |kind| return kind;
        var buffer: [2]Node.Index = undefined;
        for (k.members(c, &buffer)) |m| {
            const f = k.tree.fullContainerField(m) orelse continue;
            if (std.mem.eql(u8, k.tree.tokenSlice(f.ast.main_token), name)) return .value;
        }
        return .runtime;
    }

    /// What `c` declares by `name`, if it does: a `var` is not known; a
    /// `const` and a function are.
    fn declared(k: *Known, c: Node.Index, name: []const u8, depth: u32) Allocator.Error!?Kind {
        const tree = k.tree;
        var buffer: [2]Node.Index = undefined;
        for (k.members(c, &buffer)) |m| {
            const declares = declaredName(tree, m) orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(declares), name)) continue;
            // A function.
            const decl = tree.fullVarDecl(m) orelse return .value;
            if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) return .runtime;
            const init = decl.ast.init_node.unwrap() orelse return .namespace;
            return try k.declaredConst(c, init, depth);
        }
        return null;
    }

    /// What a container's `const` set to `init` is. Its value is known, as
    /// any container's `const` is; what is read through it may not be.
    fn declaredConst(k: *Known, c: Node.Index, init: Node.Index, depth: u32) Allocator.Error!Kind {
        const tree = k.tree;
        switch (tree.nodeTag(init)) {
            .address_of => return .pointer,
            .builtin_call_two, .builtin_call_two_comma => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@This")) return .{ .container = c },
            else => {},
        }
        return switch (try k.kindOf(init, depth + 1)) {
            .runtime => .namespace,
            else => |kind| kind,
        };
    }

    fn members(k: *Known, c: Node.Index, buffer: *[2]Node.Index) []const Node.Index {
        if (c == .root) return k.tree.rootDecls();
        return k.tree.fullContainerDecl(buffer, c).?.ast.members;
    }

    /// The containers the function is in, the file first.
    fn enclosing(k: *Known) Allocator.Error![]const Node.Index {
        if (k.containers) |c| return c;
        const tree = k.tree;
        var out: std.ArrayList(Node.Index) = .empty;
        var around: std.ArrayList(Node.Index) = .empty;
        try out.append(k.arena, .root);
        var kids: std.ArrayList(Node.Index) = .empty;
        var node: Node.Index = .root;
        while (try k.childAround(node, &kids)) |kid| : (node = kid) {
            if (kid == k.function) break;
            switch (tree.nodeTag(kid)) {
                .fn_decl, .test_decl => try around.append(k.arena, kid),
                else => |tag| if (children.isContainer(tag)) try out.append(k.arena, kid),
            }
        }
        k.containers = out.items;
        k.around = around.items;
        return out.items;
    }

    /// The child of `node` that is the function or has it inside, if one
    /// does. `kids` is working memory.
    fn childAround(k: *Known, node: Node.Index, kids: *std.ArrayList(Node.Index)) Allocator.Error!?Node.Index {
        const tree = k.tree;
        const first = tree.firstToken(k.function);
        const last = tree.lastToken(k.function);
        kids.clearRetainingCapacity();
        try children.append(k.arena, tree, node, kids);
        for (kids.items) |kid| {
            if (kid == k.function or (tree.firstToken(kid) <= first and tree.lastToken(kid) >= last)) return kid;
        }
        return null;
    }

    fn bindingsOf(k: *Known) Allocator.Error!*std.StringHashMapUnmanaged(std.ArrayList(Binding)) {
        if (k.bindings == null) k.bindings = try collect(k.arena, k.tree, k.function);
        return &k.bindings.?;
    }
};

/// Every name `function` binds, each name's bindings in source order.
fn collect(arena: Allocator, tree: *const Ast, function: Node.Index) Allocator.Error!std.StringHashMapUnmanaged(std.ArrayList(Binding)) {
    var c: Collector = .{ .arena = arena, .tree = tree };
    if (tree.nodeTag(function) == .fn_decl) try c.params(function);
    var stack: std.ArrayList(Node.Index) = .empty;
    var kids: std.ArrayList(Node.Index) = .empty;
    try children.appendCode(arena, tree, function, &stack);
    while (stack.pop()) |node| {
        const tag = tree.nodeTag(node);
        switch (tag) {
            // What a function or container inside binds is not this one's.
            .fn_decl, .test_decl => continue,
            else => if (children.isContainer(tag)) continue,
        }
        try c.node(node);
        kids.clearRetainingCapacity();
        try children.appendCode(arena, tree, node, &kids);
        try stack.appendSlice(arena, kids.items);
    }
    var it = c.names.valueIterator();
    while (it.next()) |list| std.mem.sort(Binding, list.items, {}, Collector.before);
    return c.names;
}

/// The name a container's member `m` declares, if it is a `const`, a `var`
/// or a function.
fn declaredName(tree: *const Ast, m: Node.Index) ?Ast.TokenIndex {
    if (tree.fullVarDecl(m)) |decl| return decl.ast.mut_token + 1;
    if (tree.nodeTag(m) != .fn_decl) return null;
    var buffer: [1]Node.Index = undefined;
    return tree.fullFnProto(&buffer, tree.nodeData(m).node_and_node[0]).?.name_token;
}

/// Whether a parameter so typed must be known at compile time.
fn comptimeOnly(tree: *const Ast, type_expr: Node.Index) bool {
    if (tree.nodeTag(type_expr) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(type_expr));
    return isOneOf(name, &.{ "type", "comptime_int", "comptime_float" });
}

/// Whether `type_expr` is `type`: what it types is a type.
fn isTypeType(tree: *const Ast, type_expr: Node.Index) bool {
    return tree.nodeTag(type_expr) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type");
}

const Collector = struct {
    arena: Allocator,
    tree: *const Ast,
    names: std.StringHashMapUnmanaged(std.ArrayList(Binding)) = .empty,

    fn add(c: *Collector, token: Ast.TokenIndex, source: Source) Allocator.Error!void {
        const entry = try c.names.getOrPut(c.arena, c.tree.tokenSlice(token));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(c.arena, .{ .token = token, .kind = source });
    }

    fn before(_: void, a: Binding, b: Binding) bool {
        return a.token < b.token;
    }

    /// Adds each named parameter of the `fn_decl` `function`: a type
    /// parameter is a type, a `comptime` one known, any other not.
    fn params(c: *Collector, function: Node.Index) Allocator.Error!void {
        const tree = c.tree;
        var buffer: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]).?;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const name = param.name_token orelse continue;
            const is_comptime = if (param.comptime_noalias) |t| tree.tokenTag(t) == .keyword_comptime else false;
            const kind: Kind = if (param.type_expr) |t|
                if (isTypeType(tree, t)) .type else if (is_comptime or comptimeOnly(tree, t)) .value else .runtime
            else if (is_comptime) .value else .runtime;
            try c.add(name, .{ .fixed = kind });
        }
    }

    /// Adds what `n` binds itself.
    fn node(c: *Collector, n: Node.Index) Allocator.Error!void {
        const tree = c.tree;
        if (tree.fullVarDecl(n)) |decl| return c.add(decl.ast.mut_token + 1, varSource(tree, decl));
        if (tree.fullIf(n)) |full| return c.payloads(full.payload_token, full.error_token, .{ .of = full.ast.cond_expr });
        if (tree.fullWhile(n)) |full| return c.payloads(full.payload_token, full.error_token, .{ .fixed = .runtime });
        if (tree.fullFor(n)) |full| return c.forCaptures(full);
        if (tree.fullSwitch(n)) |full| {
            for (full.ast.cases) |case| try c.prongCaptures(tree.fullSwitchCase(case).?, full.ast.condition);
            return;
        }
        switch (tree.nodeTag(n)) {
            .@"catch" => try c.captureAfter(n, .{ .of = tree.nodeData(n).node_and_node[0] }),
            .@"errdefer" => try c.captureAfter(n, .{ .fixed = .runtime }),
            else => {},
        }
    }

    /// The captures of an `if` or `while`, `|v|` and its `else |err|`, all
    /// of `source`.
    fn payloads(c: *Collector, payload: ?Ast.TokenIndex, err: ?Ast.TokenIndex, source: Source) Allocator.Error!void {
        if (payload) |t| try c.captures(t, source);
        if (err) |t| try c.add(t, source);
    }

    /// Each capture of a `for`: of the input in its place for an `inline
    /// for`, and not known for any other.
    fn forCaptures(c: *Collector, full: Ast.full.For) Allocator.Error!void {
        var t = full.payload_token;
        var i: usize = 0;
        while (c.tree.tokenTag(t) != .pipe) : (t += 1) {
            if (c.tree.tokenTag(t) != .identifier) continue;
            const inlined = full.inline_token != null and i < full.ast.inputs.len;
            try c.add(t, if (inlined) .{ .of = full.ast.inputs[i] } else .{ .fixed = .runtime });
            i += 1;
        }
    }

    /// Each capture of a switch prong: of the operand, but the second of an
    /// inline prong, its tag, known in each copy of the prong.
    fn prongCaptures(c: *Collector, prong: Ast.full.SwitchCase, operand: Node.Index) Allocator.Error!void {
        var t = prong.payload_token orelse return;
        var i: usize = 0;
        while (c.tree.tokenTag(t) != .pipe) : (t += 1) {
            if (c.tree.tokenTag(t) != .identifier) continue;
            try c.add(t, if (i == 1 and prong.inline_token != null) .{ .fixed = .value } else .{ .of = operand });
            i += 1;
        }
    }

    /// The capture written after the keyword of `n`, as `catch |err|` has.
    fn captureAfter(c: *Collector, n: Node.Index, source: Source) Allocator.Error!void {
        const keyword = c.tree.nodeMainToken(n);
        if (c.tree.tokenTag(keyword + 1) == .pipe) try c.add(keyword + 2, source);
    }

    /// Adds each name captured from `first` to the closing `|`, all of
    /// `source`.
    fn captures(c: *Collector, first: Ast.TokenIndex, source: Source) Allocator.Error!void {
        var t = first;
        while (c.tree.tokenTag(t) != .pipe) : (t += 1) {
            if (c.tree.tokenTag(t) == .identifier) try c.add(t, source);
        }
    }
};

/// What a local `const` or `var` is known to be.
fn varSource(tree: *const Ast, decl: Ast.full.VarDecl) Source {
    if (decl.comptime_token != null) return .{ .fixed = .value };
    if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) return .{ .fixed = .runtime };
    if (decl.ast.type_node.unwrap()) |t| {
        if (isTypeType(tree, t)) return .{ .fixed = .type };
        if (comptimeOnly(tree, t)) return .{ .fixed = .value };
    }
    // A part of a destructure has no init of its own.
    const init = decl.ast.init_node.unwrap() orelse return .{ .fixed = .runtime };
    return .{ .of = init };
}

/// The decisions of the function `name` in `source` made at compile time,
/// a line each as `line:column construct why`, in source order.
fn expectDecided(source: [:0]const u8, name: []const u8, expected: []const u8) !void {
    const functions = @import("functions.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try Ast.parse(arena, source, .{});
    try std.testing.expectEqual(0, tree.errors.len);
    const function = for (try functions.list(arena, &tree)) |f| {
        if (std.mem.eql(u8, f.name, name)) break f;
    } else return error.NoSuchFunction;
    const d = try of(arena, &tree, function.node);
    var nodes: std.ArrayList(Node.Index) = .empty;
    var it = d.whys.keyIterator();
    while (it.next()) |n| switch (tree.nodeTag(n.*)) {
        // A prong answers as its switch.
        .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {},
        else => try nodes.append(arena, n.*),
    };
    std.mem.sort(Node.Index, nodes.items, @as(*const Ast, &tree), struct {
        fn lessThan(t: *const Ast, a: Node.Index, b: Node.Index) bool {
            return t.nodeMainToken(a) < t.nodeMainToken(b);
        }
    }.lessThan);
    var got: std.ArrayList(u8) = .empty;
    for (nodes.items) |n| {
        const token = tree.nodeMainToken(n);
        const loc = tree.tokenLocation(0, token);
        try got.print(arena, "{d}:{d} {s} {t}\n", .{ loc.line + 1, loc.column + 1, tree.tokenSlice(token), d.get(n).? });
    }
    try std.testing.expectEqualStrings(expected, got.items);
}

test "comptime parameters, their fields, types and reflection are known; a run-time value is not" {
    try expectDecided(
        \\const Options = struct { optional: bool = false, strict: bool = false };
        \\fn argument(comptime o: Options, comptime T: type, values: []const u32, comptime n: usize) ?T {
        \\    if (o.strict) {
        \\        if (@typeInfo(T) != .int) @compileError("a strict argument is an integer");
        \\    }
        \\    const v: ?u32 = if (n < values.len) values[n] else null;
        \\    if (o.optional) {
        \\        if (@typeInfo(T) != .optional and @typeInfo(T) != .int) @compileError("take it as an optional");
        \\        if (v == null) return null;
        \\    }
        \\    if (T == u32) return v;
        \\    return @intCast(v orelse 0);
        \\}
    , "argument",
        \\3:5 if known
        \\4:9 if assertion
        \\7:5 if known
        \\8:9 if assertion
        \\8:39 and in_condition
        \\11:5 if known
        \\
    );
}

test "a type parameter needs no comptime; a local const of what is known is known, a var is not" {
    try expectDecided(
        \\fn f(T: type, x: u8) void {
        \\    const info = @typeInfo(T);
        \\    const big = @sizeOf(T) > 8;
        \\    var flag = true;
        \\    const copy = flag;
        \\    if (info == .int) a();
        \\    if (big) a();
        \\    if (flag) a();
        \\    if (copy) a();
        \\    if (x > 0 and big) a();
        \\    if (big or x > 0) a();
        \\    flag = false;
        \\}
    , "f",
        \\6:5 if known
        \\7:5 if known
        \\10:15 and known
        \\11:13 or known
        \\
    );
}

test "a container's const is known, its var not; builtin is known, another file's namespace not" {
    try expectDecided(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const debug = false;
        \\var count: u32 = 0;
        \\const native_os = builtin.os.tag;
        \\const Mode = enum { fast, safe };
        \\const mode: Mode = .fast;
        \\const S = struct {
        \\    var hits: u32 = 0;
        \\    const limit = 3;
        \\};
        \\fn f(comptime T: type) void {
        \\    if (debug) a();
        \\    if (count > 0) a();
        \\    if (builtin.os.tag == .windows) a();
        \\    if (native_os == .linux) a();
        \\    if (std.debug.runtime_safety) a();
        \\    if (mode == Mode.safe) a();
        \\    if (S.hits > S.limit) a();
        \\    if (S.limit > 2) a();
        \\    if (@import("builtin").mode == .Debug) a();
        \\    if (T == std.mem.Allocator) a();
        \\    if (std.mem.Allocator == @TypeOf(count)) a();
        \\    if (u8 == std.ArrayList(u8)) a();
        \\}
    , "f",
        \\13:5 if known
        \\15:5 if known
        \\16:5 if known
        \\18:5 if known
        \\20:5 if known
        \\21:5 if known
        \\22:5 if known
        \\23:5 if known
        \\24:5 if known
        \\
    );
}

test "comptime code, a container's declarations and a branch of only @compileError are decided; a labeled switch is not, by the operand it starts on" {
    try expectDecided(
        \\const State = enum { start, end };
        \\fn f(x: u8, o: ?u8) u8 {
        \\    comptime {
        \\        for (0..3) |i| if (i > 1) check();
        \\    }
        \\    if (comptime ready()) a();
        \\    const S = struct {
        \\        const n = if (big()) 2 else 1;
        \\    };
        \\    _ = S;
        \\    if (isValid(x)) {} else @compileError("no");
        \\    switch (kind(x)) {
        \\        .a => {},
        \\        else => @compileError("no"),
        \\    }
        \\    const v = o orelse @compileError("none");
        \\    if (!valid(x) or !small(x)) @compileError("no");
        \\    state: switch (State.start) {
        \\        .start => if (x > 0) continue :state .end,
        \\        .end => {},
        \\    }
        \\    return v;
        \\}
    , "f",
        \\4:9 for in_comptime
        \\4:24 if in_comptime
        \\6:5 if known
        \\8:19 if in_comptime
        \\11:5 if forced
        \\12:5 switch forced
        \\16:17 orelse assertion
        \\17:5 if assertion
        \\17:19 or in_condition
        \\
    );
}

test "captures: an inline for over what is known, an if of what is known, an inline prong's tag" {
    try expectDecided(
        \\fn f(comptime T: type, value: T, xs: []const u8, u: U) void {
        \\    inline for (@typeInfo(T).@"struct".fields) |field| {
        \\        if (field.type == u8) a(@field(value, field.name));
        \\    }
        \\    for (xs) |x| {
        \\        if (x == 0) a();
        \\    }
        \\    switch (u) {
        \\        inline else => |payload, tag| {
        \\            if (tag == .a) a();
        \\            if (payload > 0) a();
        \\        },
        \\    }
        \\    if (@typeInfo(T).@"struct".backing_integer) |int| {
        \\        if (int == u8) a();
        \\    }
        \\}
    , "f",
        \\3:9 if known
        \\10:13 if known
        \\14:5 if known
        \\15:9 if known
        \\
    );
}

test "a method reads what the function around it binds only when it is known" {
    try expectDecided(
        \\fn Ring(comptime T: type, comptime n: usize) type {
        \\    return struct {
        \\        const Self = @This();
        \\        items: [n]T,
        \\        fn next(self: *Self, i: usize) usize {
        \\            if (n > 64) a();
        \\            if (i + 1 == n) return 0;
        \\            if (@sizeOf(T) > 8 and self.items.len > 0) a();
        \\            return i + 1;
        \\        }
        \\    };
        \\}
        \\fn a() void {}
    , "Ring.next",
        // n and T are Ring's, which next can read only because they are
        // known; i and self are next's own, and not.
        \\6:13 if known
        \\8:32 and known
        \\
    );
}

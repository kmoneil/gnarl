//! Fan-out and fan-in, per file: the files each file imports, and the
//! files read that import it.
//!
//! An `@import` of a string ending in `.zig` or `.zon` names a file,
//! relative to the importing one, and is followed. Anything else (`std`,
//! `builtin`, `root`, a build option or a named module from build.zig)
//! names a module, which the source alone cannot place: each is listed as
//! a module, an import gnarl cannot follow, rather than left out of the
//! count. Fan-in counts only the files read in the same run.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const children = @import("children.zig");
const formats = @import("formats.zig");
const messages = @import("messages.zig");
const Message = messages.Message;
const report = @import("report.zig");

pub const File = struct {
    /// As gnarl prints paths: cleaned, relative to the current directory.
    path: []const u8,
    /// The files it imports, each once, sorted.
    imports: []const []const u8,
    /// The files read that import it, sorted. Set by `link`.
    imported_by: []const []const u8 = &.{},
    /// The modules it imports, each once, sorted: imports gnarl cannot
    /// follow.
    modules: []const []const u8,

    pub fn fanOut(f: File) usize {
        return f.imports.len;
    }

    pub fn fanIn(f: File) usize {
        return f.imported_by.len;
    }
};

/// What `tree`, read from `path`, imports. Allocated with `arena`, so it
/// outlives `tree`.
pub fn of(arena: Allocator, path: []const u8, tree: *const Ast) Allocator.Error!File {
    var files: std.StringArrayHashMapUnmanaged(void) = .empty;
    var modules: std.StringArrayHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList(Node.Index) = .empty;
    try children.append(arena, tree, .root, &stack);
    while (stack.pop()) |node| {
        try children.append(arena, tree, node, &stack);
        const target = try importOf(arena, tree, node) orelse continue;
        if (isFile(target)) {
            try files.put(arena, try std.fs.path.resolveAlloc(arena, &.{ std.fs.path.dirname(path) orelse ".", target }), {});
        } else try modules.put(arena, target, {});
    }
    return .{ .path = path, .imports = try sorted(arena, files.keys()), .modules = try sorted(arena, modules.keys()) };
}

/// The string `node` imports, if it is an `@import` of a string literal.
fn importOf(arena: Allocator, tree: *const Ast, node: Node.Index) Allocator.Error!?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
    var buffer: [2]Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node).?;
    if (params.len == 0 or tree.nodeTag(params[0]) != .string_literal) return null;
    return std.zig.string_literal.parseAlloc(arena, tree.tokenSlice(tree.nodeMainToken(params[0]))) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => null,
    };
}

fn isFile(target: []const u8) bool {
    return std.mem.endsWith(u8, target, ".zig") or std.mem.endsWith(u8, target, ".zon");
}

fn sorted(arena: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.dupe([]const u8, items);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Sets each file's `imported_by`: the files of `files` that import it.
pub fn link(arena: Allocator, files: []File) Allocator.Error!void {
    var at: std.StringHashMapUnmanaged(usize) = .empty;
    for (files, 0..) |f, i| try at.put(arena, f.path, i);
    const by = try arena.alloc(std.ArrayList([]const u8), files.len);
    @memset(by, .empty);
    for (files) |f| for (f.imports) |target| {
        if (at.get(target)) |i| try by[i].append(arena, f.path);
    };
    for (files, by) |*f, list| f.imported_by = try sorted(arena, list.items);
}

/// The most coupled first: the most imports in and out, then the most
/// out, then by path.
pub fn sort(files: []File) void {
    std.mem.sort(File, files, {}, listedBefore);
}

fn listedBefore(_: void, a: File, b: File) bool {
    const total_a = a.fanIn() + a.fanOut();
    const total_b = b.fanIn() + b.fanOut();
    if (total_a != total_b) return total_a > total_b;
    if (a.fanOut() != b.fanOut()) return a.fanOut() > b.fanOut();
    return lessThan({}, a.path, b.path);
}

/// What a files document says besides its files.
pub const Context = struct {
    version: []const u8,
    /// At most this many listed, the most coupled.
    top: ?usize = null,
    messages: []const Message = &.{},
};

/// Writes `files`, sorted, in `format`.
pub fn write(w: *Writer, format: report.Format, files: []const File, c: Context) Writer.Error!void {
    const listed = files[0..@min(files.len, c.top orelse files.len)];
    switch (format) {
        .text, .md => try writeTable(w, format, files, listed),
        .json => try writeJson(w, listed, c),
        .xml => try writeXml(w, listed, c),
        .csv => try writeDelimited(w, .csv, listed),
        .tsv => try writeDelimited(w, .tsv, listed),
    }
}

fn writeTable(w: *Writer, format: report.Format, all: []const File, listed: []const File) Writer.Error!void {
    if (listed.len > 0) {
        if (format == .md) {
            try w.writeAll("| fan-out | fan-in | modules | file |\n| ---: | ---: | ---: | --- |\n");
            for (listed) |f| try w.print("| {d} | {d} | {d} | `{s}` |\n", .{ f.fanOut(), f.fanIn(), f.modules.len, f.path });
        } else {
            try w.writeAll("fan-out  fan-in  modules  file\n");
            for (listed) |f| try w.print("{d: >7}  {d: >6}  {d: >7}  {s}\n", .{ f.fanOut(), f.fanIn(), f.modules.len, f.path });
        }
        try w.writeByte('\n');
    }
    var imports: usize = 0;
    var modules: usize = 0;
    for (all) |f| {
        imports += f.fanOut();
        modules += f.modules.len;
    }
    try w.print("{d} file{s} read: {d} import{s} of files, {d} of modules, which gnarl does not follow (std, build options and named modules).\n", .{
        all.len, plural(all.len), imports, plural(imports), modules,
    });
    if (listed.len < all.len) try w.print("{d} more not listed: --top {d} keeps the most coupled.\n", .{ all.len - listed.len, listed.len });
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn writeJson(w: *Writer, files: []const File, c: Context) Writer.Error!void {
    try w.print("{{\"schema\":{d},\"gnarl\":", .{report.schema});
    try std.json.Stringify.value(c.version, .{}, w);
    try messages.writeJson(w, c.messages);
    try w.writeAll(",\"files\":[");
    for (files, 0..) |f, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try std.json.Stringify.value(.{
            .path = f.path,
            .fan_out = f.fanOut(),
            .fan_in = f.fanIn(),
            .imports = f.imports,
            .imported_by = f.imported_by,
            .modules = f.modules,
        }, .{}, w);
    }
    try w.writeAll(if (files.len > 0) "\n]}\n" else "]}\n");
}

fn writeXml(w: *Writer, files: []const File, c: Context) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gnarl");
    try formats.attrInt(w, "schema", report.schema);
    try formats.attr(w, "version", c.version);
    try w.writeAll(">\n");
    try messages.writeXml(w, c.messages);
    try w.writeAll("  <files>\n");
    for (files) |f| {
        try w.writeAll("    <file");
        try formats.attr(w, "path", f.path);
        try formats.attrInt(w, "fan_out", f.fanOut());
        try formats.attrInt(w, "fan_in", f.fanIn());
        try w.writeAll(">\n");
        inline for (.{ .{ "import", "imports" }, .{ "imported_by", "imported_by" }, .{ "module", "modules" } }) |pair| {
            for (@field(f, pair[1])) |item| {
                try w.writeAll("      <" ++ pair[0]);
                try formats.attr(w, if (comptime std.mem.eql(u8, pair[0], "module")) "name" else "path", item);
                try w.writeAll("/>\n");
            }
        }
        try w.writeAll("    </file>\n");
    }
    try w.writeAll("  </files>\n</gnarl>\n");
}

pub const delimited_columns = [_][]const u8{ "path", "fan_out", "fan_in", "imports", "imported_by", "modules" };

/// A header, then a row per file; each list separated by spaces.
fn writeDelimited(w: *Writer, kind: formats.Delimited, files: []const File) Writer.Error!void {
    try formats.header(w, kind, &delimited_columns);
    for (files) |f| {
        try formats.field(w, kind, true, f.path);
        try formats.fieldInt(w, kind, false, f.fanOut());
        try formats.fieldInt(w, kind, false, f.fanIn());
        inline for (.{ "imports", "imported_by", "modules" }) |name| {
            var buffer: [4096]u8 = undefined;
            var joined: Writer = .fixed(&buffer);
            for (@field(f, name), 0..) |item, i| joined.print("{s}{s}", .{ if (i == 0) "" else " ", item }) catch break;
            try formats.field(w, kind, false, joined.buffered());
        }
        try w.writeByte('\n');
    }
}

fn parse(arena: Allocator, source: []const u8) !Ast {
    const tree = try Ast.parse(arena, try arena.dupeSentinel(u8, source, 0), .{});
    try std.testing.expectEqual(0, tree.errors.len);
    return tree;
}

test "of: files relative to the importer, each once; modules apart" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try parse(arena,
        \\const std = @import("std");
        \\const walk = @import("walk.zig");
        \\const up = @import("../lib/up.zig");
        \\const opts = @import("build_options");
        \\fn f() void {
        \\    _ = @import("walk.zig");
        \\    _ = @import("data.zon");
        \\    _ = @import("std");
        \\    _ = @typeName(u8);
        \\}
    );
    const f = try of(arena, "src/a.zig", &tree);
    const sep = std.fs.path.sep_str;
    try std.testing.expectEqual(3, f.imports.len);
    try std.testing.expectEqualStrings("lib" ++ sep ++ "up.zig", f.imports[0]);
    try std.testing.expectEqualStrings("src" ++ sep ++ "data.zon", f.imports[1]);
    try std.testing.expectEqualStrings("src" ++ sep ++ "walk.zig", f.imports[2]);
    try std.testing.expectEqual(2, f.modules.len);
    try std.testing.expectEqualStrings("build_options", f.modules[0]);
    try std.testing.expectEqualStrings("std", f.modules[1]);
}

test "link and sort: fan-in from the files read, the most coupled first" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files = [_]File{
        .{ .path = "a.zig", .imports = &.{ "b.zig", "c.zig" }, .modules = &.{"std"} },
        .{ .path = "b.zig", .imports = &.{"c.zig"}, .modules = &.{} },
        .{ .path = "c.zig", .imports = &.{"elsewhere.zig"}, .modules = &.{} },
    };
    try link(arena, &files);
    sort(&files);
    // c: in from a and b, out 1; a: out 2; b: in 1, out 1.
    try std.testing.expectEqualStrings("c.zig", files[0].path);
    try std.testing.expectEqual(2, files[0].fanIn());
    try std.testing.expectEqualStrings("a.zig", files[1].path);
    try std.testing.expectEqualStrings("b.zig", files[2].path);
    try std.testing.expectEqualStrings("a.zig", files[2].imported_by[0]);

    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, .text, &files, .{ .version = "0.0.0", .top = 2 });
    try std.testing.expectEqualStrings(
        \\fan-out  fan-in  modules  file
        \\      1       2        0  c.zig
        \\      2       0        1  a.zig
        \\
        \\3 files read: 4 imports of files, 1 of modules, which gnarl does not follow (std, build options and named modules).
        \\1 more not listed: --top 2 keeps the most coupled.
        \\
    , out.written());

    for ([_]report.Format{ .csv, .tsv }) |format| {
        var table: Writer.Allocating = .init(arena);
        try write(&table.writer, format, &files, .{ .version = "0.0.0" });
        const rows = try formats.readDelimited(arena, if (format == .csv) .csv else .tsv, table.written());
        try std.testing.expectEqual(4, rows.len);
        try std.testing.expectEqualStrings("a.zig b.zig", rows[1][4]);
    }
    var xml: Writer.Allocating = .init(arena);
    try write(&xml.writer, .xml, &files, .{ .version = "0.0.0" });
    const doc = try formats.readXml(arena, xml.written());
    try std.testing.expectEqualStrings("2", doc.child("files").?.children[0].get("fan_in").?);
}

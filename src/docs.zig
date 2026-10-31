//! docs/output.md and the json documents name the same fields: every key
//! a document holds is listed in its section, and every name listed there
//! is a key the document holds.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const explain = @import("explain.zig");
const messages = @import("messages.zig");
const report = @import("report.zig");

const doc_path = "docs/output.md";

/// The names a section of the document lists: each `name` in backticks
/// at the start of a list item, and those after it joined by `, ` (as in
/// `- `line`, `column`: ...`).
fn listed(arena: Allocator, doc: []const u8, heading: []const u8) !std.StringArrayHashMapUnmanaged(void) {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    const start = (std.mem.find(u8, doc, heading) orelse return error.NoSection) + heading.len;
    const end = if (std.mem.findPos(u8, doc, start, "\n## ")) |e| e else doc.len;
    var it = std.mem.splitScalar(u8, doc[start..end], '\n');
    while (it.next()) |line| {
        var rest = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, rest, "- `")) continue;
        rest = rest[2..];
        while (std.mem.startsWith(u8, rest, "`")) {
            const close = std.mem.findScalarPos(u8, rest, 1, '`') orelse return error.Unclosed;
            try names.put(arena, rest[1..close], {});
            rest = rest[close + 1 ..];
            if (!std.mem.startsWith(u8, rest, ", `")) break;
            rest = rest[2..];
        }
    }
    return names;
}

/// Every object key anywhere in `value`.
fn keys(arena: Allocator, value: std.json.Value, out: *std.StringArrayHashMapUnmanaged(void)) !void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                try out.put(arena, entry.key_ptr.*, {});
                try keys(arena, entry.value_ptr.*, out);
            }
        },
        .array => |array| for (array.items) |item| try keys(arena, item, out),
        else => {},
    }
}

/// Every key in `json` is listed under `heading`, or under `also` (a
/// section the first refers to, as an explanation does to the report),
/// and every name under `heading` is a key in `json`.
fn expectSame(arena: Allocator, doc: []const u8, heading: []const u8, also: ?[]const u8, json: []const u8) !void {
    var names = try listed(arena, doc, heading);
    var known = try names.clone(arena);
    if (also) |other| {
        var more = try listed(arena, doc, other);
        for (more.keys()) |name| try known.put(arena, name, {});
    }
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    var found: std.StringArrayHashMapUnmanaged(void) = .empty;
    try keys(arena, value, &found);
    var ok = true;
    for (found.keys()) |key| if (!known.contains(key)) {
        std.debug.print("{s} {s}: `{s}` is in the json but not listed\n", .{ doc_path, heading, key });
        ok = false;
    };
    for (names.keys()) |name| if (!found.contains(name)) {
        std.debug.print("{s} {s}: `{s}` is listed but not in the json\n", .{ doc_path, heading, name });
        ok = false;
    };
    if (!ok) return error.TestUnexpectedResult;
}

/// Messages with every field filled, so every key is in the document.
const said = [_]messages.Message{
    .{ .level = .@"error", .path = "a.zig", .line = 1, .column = 2, .text = "wrong", .more = &.{"more"} },
    .{ .level = .note, .text = "worth knowing" },
};

test "docs/output.md lists every field of the report, and no other" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try std.Io.Dir.cwd().readFileAlloc(io, doc_path, arena, .limited(1 << 20));

    var rows = [_]report.Row{.{ .path = "a.zig", .line = 1, .end_line = 3, .column = 4, .name = "f", .kind = .@"fn", .cyclomatic = 30, .lines = 3, .nesting = 0, .params = 0, .params_weighted = 0 }};
    try report.rank(arena, &rows, .defaults);
    var out: std.Io.Writer.Allocating = .init(arena);
    try report.write(&out.writer, .json, &rows, try report.list(arena, &rows, .{}), .{
        .version = "0.0.0",
        .files = 1,
        .classes = .defaults,
        .messages = &said,
        // A failure, so its fields are in the document.
        .check = .{ .asked = true, .failed = true, .critical = 1, .baseline = "complexity.baseline", .failures = &.{.{
            .path = "a.zig",
            .line = 1,
            .name = "f",
            .metric = .cyclomatic,
            .value = 30,
            .limit = 15,
            .baselined = 20,
        }} },
    });
    try expectSame(arena, doc, "## The report", null, out.written());
}

test "docs/output.md lists every field of an explanation, and no other" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try std.Io.Dir.cwd().readFileAlloc(io, doc_path, arena, .limited(1 << 20));

    // A function with a branch, a level, and a parameter, over a limit.
    const source = "fn f(x: u8) void {\n    if (x > 0) {}\n}\n";
    var tree = try Ast.parse(std.testing.allocator, source, .{});
    defer tree.deinit(std.testing.allocator);
    var search: explain.Search = try .init(arena, &.{"f"});
    try search.file(arena, arena, "a.zig", &tree, .normal, .{ .cyclomatic = .{ .warning = 1 } });
    var quiet: messages.Messages = .{ .arena = arena, .echo = false };
    const found = try search.results(arena, &quiet);
    var out: std.Io.Writer.Allocating = .init(arena);
    try explain.write(&out.writer, .json, found.explanations, .{ .version = "0.0.0", .messages = &said });
    try expectSame(arena, doc, "## An explanation", "## The report", out.written());
}

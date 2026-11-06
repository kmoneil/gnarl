//! The golden tables: every metric of every function in each fixture under
//! test/golden/, the class it is held to and the limits it is over,
//! checked against the table committed beside it (`name.zig` and
//! `name.txt`, a line per function in source order).
//!
//! The numbers were checked when each table was written; this keeps them
//! from moving unnoticed. When a counting rule changes on purpose,
//! `zig build test -Dupdate` rewrites the tables, and the diff shows what
//! the change moved. Tables that move while their fixtures do not mean
//! gnarl counts otherwise: the release it goes out in joins `changes` in
//! counting.zig, and a test here holds the tables to the hash beside it.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const test_options = @import("test_options");
const counting = @import("counting.zig");
const measure = @import("measure.zig");
const report = @import("report.zig");
const Row = report.Row;

const dir_path = "test/golden";

/// A fixture under test/golden/ and what gnarl measures of it.
const Fixture = struct {
    /// `name.zig`, its table `name.txt`.
    name: []const u8,
    source: [:0]const u8,
    /// What gnarl measures of it, as a golden table.
    table: []const u8,
};

/// Every fixture in `dir`, in name order, measured.
fn measureAll(arena: Allocator, io: Io, dir: Io.Dir) ![]Fixture {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, byName);
    const fixtures = try arena.alloc(Fixture, names.items.len);
    for (fixtures, names.items) |*fixture, name| {
        const source = try dir.readFileAllocOptions(io, name, arena, .limited(std.math.maxInt(u32)), .of(u8), 0);
        fixture.* = .{ .name = name, .source = source, .table = try measureOne(arena, name, source) };
    }
    return fixtures;
}

fn byName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The golden table of `source`, read from `name`, held as normal code
/// to the default limits.
fn measureOne(arena: Allocator, name: []const u8, source: [:0]const u8) ![]const u8 {
    const tree = try Ast.parse(arena, source, .{});
    try std.testing.expectEqual(0, tree.errors.len);
    var rows: std.ArrayList(Row) = .empty;
    try measure.file(arena, arena, name, &tree, .normal, &rows);
    for (rows.items) |*row| try report.judge(arena, row, .defaults);
    return render(arena, rows.items);
}

/// `rows` as a golden table: each row's numbers, its class, the limits it
/// is over as `metric:level:limit`, and `dispatch` for a flat dispatch.
fn render(arena: Allocator, rows: []const Row) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (rows) |row| {
        try out.print(arena, "{d} {s} cyclomatic={d} cognitive={d} lines={d} nesting={d} params={d} weighted={d} class={t}", .{
            row.line, row.name, row.cyclomatic, row.cognitive, row.lines, row.nesting, row.params, row.params_weighted, row.class,
        });
        for (row.trips, 0..) |trip, i| try out.print(arena, "{s}{t}:{t}:{d}", .{ if (i == 0) " over=" else ",", trip.metric, trip.level, trip.limit });
        if (row.dispatch) try out.appendSlice(arena, " dispatch");
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

/// The first 16 hex digits of a SHA-256 over each fixture's name and its
/// `field`, `source` or `table`, in the order given.
fn hash(fixtures: []const Fixture, comptime field: []const u8) [16]u8 {
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (fixtures) |fixture| {
        sha.update(fixture.name);
        sha.update(&.{0});
        sha.update(@field(fixture, field));
        sha.update(&.{0});
    }
    const digest = sha.finalResult();
    return std.fmt.bytesToHex(digest[0..8], .lower);
}

test "every fixture's functions measure as its golden table says" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const fixtures = try measureAll(arena, io, dir);
    try std.testing.expect(fixtures.len > 0);

    var failed = false;
    for (fixtures) |fixture| {
        const table = try std.fmt.allocPrint(arena, "{s}.txt", .{fixture.name[0 .. fixture.name.len - ".zig".len]});
        if (test_options.update) {
            try dir.writeFile(io, .{ .sub_path = table, .data = fixture.table });
            continue;
        }
        const want = dir.readFileAlloc(io, table, arena, .limited(1 << 24)) catch |err| {
            std.debug.print("{s}/{s}: {t}; zig build test -Dupdate writes it\n", .{ dir_path, table, err });
            failed = true;
            continue;
        };
        if (!std.mem.eql(u8, want, fixture.table)) {
            std.debug.print("{s}/{s} no longer matches what gnarl measures:\n", .{ dir_path, table });
            std.testing.expectEqualStrings(want, fixture.table) catch {};
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

// What gnarl measures, not the files: under -Dupdate this says what the
// rewrite means as the tables are written.
test "the golden tables move only with a release in counting.zig" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const fixtures = try measureAll(arena, io, dir);
    const fixtures_hash = hash(fixtures, "source");
    const tables_hash = hash(fixtures, "table");

    const golden = counting.golden;
    const last = counting.changes[counting.changes.len - 1];
    if (golden.release.order(last) != .eq) {
        std.debug.print("src/counting.zig: `golden` names {f}, and the last of `changes` is {f}: set its release to {f}, its fixtures to \"{s}\" and its tables to \"{s}\"\n", .{ golden.release, last, last, fixtures_hash, tables_hash });
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, &fixtures_hash, golden.fixtures)) {
        std.debug.print("src/counting.zig: the golden fixtures changed: set `golden`'s fixtures to \"{s}\" and its tables to \"{s}\". A counting change made with them goes unnoticed here, so change the fixtures on their own.\n", .{ fixtures_hash, tables_hash });
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, &tables_hash, golden.tables)) {
        std.debug.print("src/counting.zig: the golden tables moved and their fixtures did not, so gnarl counts otherwise than {f}, the last of `changes`: add the release this goes out in to `changes`, then set `golden`'s release to it and its tables to \"{s}\". If {f} is not out yet and this goes out in it, set only the tables.\n", .{ last, tables_hash, last });
        return error.TestUnexpectedResult;
    }
}

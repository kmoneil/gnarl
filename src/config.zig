//! complexity.zon: which paths are hot and which cold, and the thresholds
//! that differ from the defaults.
//!
//!     .{
//!         .hot = .{ "src/scan.zig", "src/parse/**" },
//!         .cold = .{ "build.zig", "test/**" },
//!         .exclude = .{ "test/fixtures", "**/*_gen.zig" },
//!         .thresholds = .{
//!             .hot = .{ .cyclomatic = .{ .warning = 6, .critical = 10 } },
//!             .normal = .{ .params_weighted = .{ .warning = 6 } },
//!         },
//!     }
//!
//! Every field may be left out. The globs (see glob.zig) are matched
//! against paths as gnarl prints them, relative to the current directory.
//! A path both a hot and a cold glob match is hot; one no glob matches is
//! normal. A metric named under a class replaces both its limits there; a
//! metric not named keeps the class's default. What an `.exclude` glob
//! matches, or what is inside it, is not read when gnarl walks a directory
//! above it, as what git ignores is not; named outright, it is read.

const std = @import("std");
const Allocator = std.mem.Allocator;

const glob = @import("glob.zig");
const thresholds = @import("thresholds.zig");
const Class = thresholds.Class;
const Classes = thresholds.Classes;
const Limit = thresholds.Limit;
const Metric = thresholds.Metric;

/// Where gnarl looks when no file is named.
pub const default_path = "complexity.zon";

pub const Config = struct {
    hot: []const []const u8 = &.{},
    cold: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    classes: Classes = .defaults,

    pub fn classOf(c: Config, path: []const u8) Class {
        for (c.hot) |pattern| if (glob.match(pattern, path)) return .hot;
        for (c.cold) |pattern| if (glob.match(pattern, path)) return .cold;
        return .normal;
    }
};

/// The file as written.
const File = struct {
    hot: []const []const u8 = &.{},
    cold: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    thresholds: struct {
        hot: Overrides = .{},
        normal: Overrides = .{},
        cold: Overrides = .{},
    } = .{},
};

const Overrides = struct {
    cyclomatic: ?Limit = null,
    cognitive: ?Limit = null,
    lines: ?Limit = null,
    nesting: ?Limit = null,
    params: ?Limit = null,
    params_weighted: ?Limit = null,
};

/// Why a file that parses cannot be used.
pub const Problem = struct { message: []const u8 };

/// Reads `source`. On `error.ParseZon`, `diagnostics` says what is wrong
/// where; on `error.Invalid`, `problem` does. Allocated with `arena`.
pub fn parse(
    gpa: Allocator,
    arena: Allocator,
    source: [:0]const u8,
    diagnostics: *std.zon.parse.Diagnostics,
    problem: *Problem,
) error{ OutOfMemory, ParseZon, Invalid }!Config {
    const file = try std.zon.parse.fromSlice(File, .{ .gpa = gpa, .arena = arena, .source = source, .diagnostics = diagnostics });
    var config: Config = .{ .hot = file.hot, .cold = file.cold, .exclude = file.exclude };
    inline for (comptime std.enums.values(Class)) |class| {
        const overrides = @field(file.thresholds, @tagName(class));
        const t = config.classes.getPtr(class);
        inline for (comptime std.enums.values(Metric)) |metric| {
            if (@field(overrides, @tagName(metric))) |limit| {
                if (limit.warning) |w| if (limit.critical) |c| if (w >= c) {
                    problem.message = try std.fmt.allocPrint(arena, "thresholds.{s}.{s}: the warning limit, {d}, is not below the critical one, {d}", .{ @tagName(class), @tagName(metric), w, c });
                    return error.Invalid;
                };
                @field(t, @tagName(metric)) = limit;
            }
        }
    }
    return config;
}

test "an empty file is the defaults: everything normal" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    const config = try parse(std.testing.allocator, arena_state.allocator(), ".{}", &diagnostics, &problem);
    try std.testing.expectEqual(.normal, config.classOf("src/scan.zig"));
    try std.testing.expectEqualDeep(Classes.defaults, config.classes);
}

test "globs give the classes; hot wins over cold" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    const config = try parse(std.testing.allocator, arena_state.allocator(),
        \\.{
        \\    .hot = .{ "src/scan.zig", "src/fast/**" },
        \\    .cold = .{ "build.zig", "src/**" },
        \\}
    , &diagnostics, &problem);
    try std.testing.expectEqual(.hot, config.classOf("src/scan.zig"));
    try std.testing.expectEqual(.hot, config.classOf("src/fast/deep/a.zig"));
    try std.testing.expectEqual(.cold, config.classOf("src/other.zig"));
    try std.testing.expectEqual(.cold, config.classOf("build.zig"));
    try std.testing.expectEqual(.normal, config.classOf("tools/gen.zig"));
}

test "exclude: globs, read as written" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    const config = try parse(std.testing.allocator, arena_state.allocator(), ".{ .exclude = .{ \"test/golden\", \"**/*_gen.zig\" } }", &diagnostics, &problem);
    try std.testing.expectEqual(2, config.exclude.len);
    try std.testing.expectEqualStrings("**/*_gen.zig", config.exclude[1]);
}

test "a metric named under a class replaces both its limits; the rest keep the defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    const config = try parse(std.testing.allocator, arena_state.allocator(),
        \\.{ .thresholds = .{
        \\    .hot = .{ .cyclomatic = .{ .warning = 6 } },
        \\    .normal = .{ .params_weighted = .{ .warning = 6, .critical = 9 } },
        \\} }
    , &diagnostics, &problem);
    try std.testing.expectEqual(Limit{ .warning = 6, .critical = null }, config.classes.hot.cyclomatic);
    try std.testing.expectEqual(Classes.defaults.hot.lines, config.classes.hot.lines);
    try std.testing.expectEqual(Limit{ .warning = 6, .critical = 9 }, config.classes.normal.params_weighted);
    try std.testing.expectEqualDeep(Classes.defaults.cold, config.classes.cold);
}

test "a misspelled field is an error that says where; a warning not below its critical one too" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    try std.testing.expectError(error.ParseZon, parse(std.testing.allocator, arena, ".{ .hott = .{\"a.zig\"} }", &diagnostics, &problem));
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{f}", .{diagnostics.fmt("complexity.zon")});
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "complexity.zon:1:5: error: unexpected field 'hott'\n"));

    try std.testing.expectError(error.Invalid, parse(std.testing.allocator, arena, ".{ .thresholds = .{ .cold = .{ .lines = .{ .warning = 90, .critical = 90 } } } }", &diagnostics, &problem));
    try std.testing.expectEqualStrings("thresholds.cold.lines: the warning limit, 90, is not below the critical one, 90", problem.message);
}

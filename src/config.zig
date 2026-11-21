//! complexity.zon: which paths are hot and which cold, and the thresholds
//! that differ from the defaults.
//!
//!     .{
//!         .gnarl = "0.7.0",
//!         .hot = .{ "src/scan.zig", "src/parse/**" },
//!         .normal = .{"src/**"},
//!         .cold = .{ "build.zig", "test/**" },
//!         .exclude = .{ "test/fixtures", "**/*_gen.zig" },
//!         .thresholds = .{
//!             .hot = .{ .cyclomatic = .{ .warning = 6, .critical = 10 } },
//!             .normal = .{ .params_weighted = .{ .warning = 6 } },
//!             .tests = .{ .lines = .{ .warning = 150 } },
//!         },
//!     }
//!
//! Every field may be left out. The globs (see glob.zig) are matched
//! against paths as gnarl prints them, relative to the current directory.
//! A path both a hot and a cold glob match is hot; one a `.normal` glob
//! matches, and no hot or cold one, is normal; one no glob matches is
//! normal too. With a `.normal` list, even `.{}`, every file is to be
//! named: one no glob matches is unclassed, which `--check` fails and
//! every other run warns of, so a new file left off the lists is seen.
//! A metric named under a class replaces both its limits there; a
//! metric not named keeps the class's default. Test code (test_code.zig)
//! is held to `.tests`, whatever its file's class. What an `.exclude` glob
//! matches, or what is inside it, is not read when gnarl walks a directory
//! above it, as what git ignores is not; named outright, it is read.
//!
//! `.gnarl` names the release the code is judged by. A gnarl that counts
//! otherwise (counting.zig) will not run `--check`, and warns on every
//! other run.

const std = @import("std");
const Allocator = std.mem.Allocator;

const counting = @import("counting.zig");
const glob = @import("glob.zig");
const thresholds = @import("thresholds.zig");
const Class = thresholds.Class;
const Classes = thresholds.Classes;
const Limit = thresholds.Limit;
const Metric = thresholds.Metric;

/// Where gnarl looks when no file is named.
pub const default_path = "complexity.zon";

pub const Config = struct {
    /// The release the code is judged by, if the file names one.
    gnarl: ?std.SemanticVersion = null,
    hot: []const []const u8 = &.{},
    /// Null when the file has no `.normal` list: then a file no glob
    /// matches is normal, and nothing is said of it.
    normal: ?[]const []const u8 = null,
    cold: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    classes: Classes = .defaults,

    /// The class of the file at `path` and the glob that gave it: the
    /// first hot glob that matches, else the first cold one, else the
    /// first normal one; normal with no glob when none does.
    pub fn classify(c: Config, path: []const u8) Classed {
        inline for (.{ .{ "hot", Class.hot }, .{ "cold", Class.cold } }) |pair| {
            for (@field(c, pair[0])) |pattern| if (glob.match(pattern, path)) return .{ .class = pair[1], .glob = pattern };
        }
        for (c.normal orelse &.{}) |pattern| if (glob.match(pattern, path)) return .{ .class = .normal, .glob = pattern };
        return .{ .class = .normal };
    }

    pub fn classOf(c: Config, path: []const u8) Class {
        return c.classify(path).class;
    }

    /// Whether the file at `path` is in no class when the file asks that
    /// every one be in one: it has a `.normal` list, and no glob matches.
    pub fn unclassed(c: Config, path: []const u8) bool {
        return c.normal != null and c.classify(path).glob == null;
    }
};

/// A file's class, and the glob of complexity.zon that gave it.
pub const Classed = struct {
    class: Class,
    /// Null when no glob matches the file: it is normal by default.
    glob: ?[]const u8 = null,
};

/// The file as written.
const File = struct {
    gnarl: ?[]const u8 = null,
    hot: []const []const u8 = &.{},
    normal: ?[]const []const u8 = null,
    cold: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    thresholds: struct {
        hot: Overrides = .{},
        normal: Overrides = .{},
        cold: Overrides = .{},
        tests: Overrides = .{},
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
    var config: Config = .{ .hot = file.hot, .normal = file.normal, .cold = file.cold, .exclude = file.exclude };
    config.gnarl = try release(arena, file.gnarl, problem);
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

/// `.gnarl`'s text as a release, or null for none: a whole version, with
/// no pre-release or build part, and not before the first release.
fn release(arena: Allocator, given: ?[]const u8, problem: *Problem) error{ OutOfMemory, Invalid }!?std.SemanticVersion {
    const text = given orelse return null;
    const version = std.SemanticVersion.parse(text) catch null;
    if (version == null or version.?.pre != null or version.?.build != null) {
        problem.message = try std.fmt.allocPrint(arena, ".gnarl = \"{s}\" is not a release: write one as gnarl --version prints it, three numbers and nothing else", .{text});
        return error.Invalid;
    }
    if (counting.since(version.?) == null) {
        problem.message = try std.fmt.allocPrint(arena, ".gnarl = \"{s}\" is before every release: the first is 0.1.0", .{text});
        return error.Invalid;
    }
    return version.?;
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
    // No .normal list: a file no glob matches is normal, and not unclassed.
    try std.testing.expectEqual(null, config.classify("tools/gen.zig").glob);
    try std.testing.expect(!config.unclassed("tools/gen.zig"));
}

test "a .normal list: normal after hot and cold, and a file no glob matches is unclassed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    const config = try parse(std.testing.allocator, arena,
        \\.{
        \\    .hot = .{ "src/scan.zig" },
        \\    .normal = .{ "src/**", "build.zig" },
        \\    .cold = .{ "build.zig", "tools/**" },
        \\}
    , &diagnostics, &problem);
    try std.testing.expectEqualDeep(Classed{ .class = .hot, .glob = "src/scan.zig" }, config.classify("src/scan.zig"));
    try std.testing.expectEqualDeep(Classed{ .class = .normal, .glob = "src/**" }, config.classify("src/cli/args.zig"));
    // Cold before normal, as hot before both.
    try std.testing.expectEqualDeep(Classed{ .class = .cold, .glob = "build.zig" }, config.classify("build.zig"));
    try std.testing.expectEqualDeep(Classed{ .class = .cold, .glob = "tools/**" }, config.classify("tools/gen.zig"));
    // Matched by nothing: held to normal's limits, and unclassed.
    try std.testing.expectEqualDeep(Classed{ .class = .normal }, config.classify("bench/run.zig"));
    try std.testing.expect(config.unclassed("bench/run.zig"));
    try std.testing.expect(!config.unclassed("src/scan.zig"));
    try std.testing.expect(!config.unclassed("build.zig"));

    // An empty list asks it too: every file hot or cold.
    const empty = try parse(std.testing.allocator, arena, ".{ .hot = .{\"a.zig\"}, .normal = .{} }", &diagnostics, &problem);
    try std.testing.expect(empty.unclassed("b.zig"));
    try std.testing.expect(!empty.unclassed("a.zig"));
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

test "gnarl: a release, as --version prints it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var problem: Problem = undefined;
    const config = try parse(std.testing.allocator, arena, ".{ .gnarl = \"0.6.1\" }", &diagnostics, &problem);
    try std.testing.expectEqual(std.SemanticVersion{ .major = 0, .minor = 6, .patch = 1 }, config.gnarl.?);
    try std.testing.expectEqual(null, (try parse(std.testing.allocator, arena, ".{}", &diagnostics, &problem)).gnarl);

    for ([_][]const u8{ "0.6", "v0.6.0", "0.7.0-dev", "0.6.0+abc", "" }) |text| {
        const source = try std.fmt.allocPrintSentinel(arena, ".{{ .gnarl = \"{s}\" }}", .{text}, 0);
        try std.testing.expectError(error.Invalid, parse(std.testing.allocator, arena, source, &diagnostics, &problem));
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, ".gnarl = \"{s}\" is not a release: write one as gnarl --version prints it, three numbers and nothing else", .{text}),
            problem.message,
        );
    }
    try std.testing.expectError(error.Invalid, parse(std.testing.allocator, arena, ".{ .gnarl = \"0.0.9\" }", &diagnostics, &problem));
    try std.testing.expectEqualStrings(".gnarl = \"0.0.9\" is before every release: the first is 0.1.0", problem.message);
}

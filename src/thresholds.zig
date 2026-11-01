//! The limits a function's metrics are held to, by the class of code it is
//! in, and which of them it is over.

const std = @import("std");

/// A metric with limits. Each names a field of `Thresholds` and of a
/// report row.
pub const Metric = enum { cyclomatic, cognitive, lines, nesting, params, params_weighted };

pub const Level = enum { warning, critical };

pub const Limit = struct {
    /// Over this is a warning.
    warning: ?u32 = null,
    /// Over this is critical.
    critical: ?u32 = null,
};

pub const Thresholds = struct {
    cyclomatic: Limit = .{},
    cognitive: Limit = .{},
    lines: Limit = .{},
    nesting: Limit = .{},
    params: Limit = .{},
    params_weighted: Limit = .{},

    /// The worst limit `value` of `metric` is over, if it is over one.
    pub fn over(t: Thresholds, metric: Metric, value: u32) ?Trip {
        const limit = t.of(metric);
        if (limit.critical) |c| if (value > c) return .{ .metric = metric, .level = .critical, .limit = c };
        if (limit.warning) |w| if (value > w) return .{ .metric = metric, .level = .warning, .limit = w };
        return null;
    }

    pub fn of(t: Thresholds, metric: Metric) Limit {
        return switch (metric) {
            inline else => |m| @field(t, @tagName(m)),
        };
    }

    /// Whether a function with these numbers is a flat dispatch: over a
    /// cyclomatic limit, its cognitive over none of its own. Many paths
    /// that read as one decision, as a switch whose every prong is a call:
    /// cyclomatic's limits do not hold it. Where cognitive has no limit,
    /// nothing tells one, and there is none.
    pub fn isDispatch(t: Thresholds, cyclomatic: u32, cognitive: u32) bool {
        if (t.cognitive.warning == null and t.cognitive.critical == null) return false;
        return t.over(.cyclomatic, cyclomatic) != null and t.over(.cognitive, cognitive) == null;
    }

    /// The limits a function with `values` is over, and whether it is a
    /// flat dispatch, whose cyclomatic is then not held.
    pub fn judge(t: Thresholds, values: std.EnumArray(Metric, u32)) Judged {
        var j: Judged = .{ .dispatch = t.isDispatch(values.get(.cyclomatic), values.get(.cognitive)) };
        for (std.enums.values(Metric)) |metric| {
            if (j.dispatch and metric == .cyclomatic) continue;
            const trip = t.over(metric, values.get(metric)) orelse continue;
            j.buffer[j.len] = trip;
            j.len += 1;
        }
        return j;
    }
};

/// What `Thresholds.judge` finds of a function.
pub const Judged = struct {
    buffer: [std.enums.values(Metric).len]Trip = undefined,
    len: usize = 0,
    /// A flat dispatch: then cyclomatic is not among the trips.
    dispatch: bool,

    /// The limits it is over, each metric once at its worst, in the order
    /// of `Metric`.
    pub fn trips(j: *const Judged) []const Trip {
        return j.buffer[0..j.len];
    }
};

/// How strictly code is held: hot code is on a path that runs often or
/// matters most, cold code is build scripts, tools and the like. Which
/// paths are which is configuration, never guessed. A test block is held
/// as `tests` whatever its file's class: Zig keeps tests in the files
/// they test, so no path tells them apart.
pub const Class = enum {
    hot,
    normal,
    cold,
    tests,

    /// The class a function is held to, in a file of class `file`.
    pub fn forFunction(file: Class, is_test: bool) Class {
        return if (is_test) .tests else file;
    }

    /// As a report says it: `hot code`, `test code`.
    pub fn text(class: Class) []const u8 {
        return switch (class) {
            .hot => "hot code",
            .normal => "normal code",
            .cold => "cold code",
            .tests => "test code",
        };
    }
};

pub const Classes = struct {
    hot: Thresholds,
    normal: Thresholds,
    cold: Thresholds,
    tests: Thresholds,

    pub const defaults: Classes = .{
        .hot = .{
            .cyclomatic = .{ .warning = 8, .critical = 12 },
            .cognitive = .{ .warning = 10, .critical = 15 },
            .lines = .{ .warning = 40, .critical = 80 },
            .nesting = .{ .warning = 3 },
            .params = .{ .warning = 4 },
        },
        .normal = .{
            .cyclomatic = .{ .warning = 10, .critical = 15 },
            .cognitive = .{ .warning = 15, .critical = 25 },
            .lines = .{ .warning = 50, .critical = 100 },
            .nesting = .{ .warning = 4 },
            .params = .{ .warning = 4 },
        },
        // Only what is far past any class's limits.
        .cold = .{
            .cyclomatic = .{ .critical = 20 },
            .cognitive = .{ .critical = 35 },
        },
        // As cold: a long test is usually a table of cases, and only a
        // test with real logic in it is worth a look.
        .tests = .{
            .cyclomatic = .{ .critical = 20 },
            .cognitive = .{ .critical = 35 },
        },
    };

    pub fn get(c: Classes, class: Class) Thresholds {
        return switch (class) {
            inline else => |k| @field(c, @tagName(k)),
        };
    }

    pub fn getPtr(c: *Classes, class: Class) *Thresholds {
        return switch (class) {
            inline else => |k| &@field(c, @tagName(k)),
        };
    }
};

/// A limit a function is over.
pub const Trip = struct {
    metric: Metric,
    level: Level,
    /// The limit it is over.
    limit: u32,
};

test "over: the worst limit passed, and only past it" {
    const t = Classes.defaults.normal;
    try std.testing.expectEqual(null, t.over(.cyclomatic, 10));
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .warning, .limit = 10 }, t.over(.cyclomatic, 11).?);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .warning, .limit = 10 }, t.over(.cyclomatic, 15).?);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .critical, .limit = 15 }, t.over(.cyclomatic, 16).?);
    // Nesting has a warning and no critical limit; weighted parameters none.
    try std.testing.expectEqual(Trip{ .metric = .nesting, .level = .warning, .limit = 4 }, t.over(.nesting, 9).?);
    try std.testing.expectEqual(null, t.over(.params_weighted, 50));
    try std.testing.expectEqual(null, (Thresholds{}).over(.lines, 1000));
}

test "the classes: hot is stricter than normal, cold only past 20 (cognitive 35)" {
    const c = Classes.defaults;
    try std.testing.expectEqual(.critical, c.get(.hot).over(.cyclomatic, 13).?.level);
    try std.testing.expectEqual(.warning, c.get(.normal).over(.cyclomatic, 13).?.level);
    try std.testing.expectEqual(null, c.get(.cold).over(.cyclomatic, 20));
    try std.testing.expectEqual(.critical, c.get(.cold).over(.cyclomatic, 21).?.level);
    try std.testing.expectEqual(null, c.get(.cold).over(.lines, 500));
    try std.testing.expectEqual(.critical, c.get(.hot).over(.cognitive, 16).?.level);
    try std.testing.expectEqual(.warning, c.get(.normal).over(.cognitive, 16).?.level);
    try std.testing.expectEqual(.critical, c.get(.normal).over(.cognitive, 26).?.level);
    try std.testing.expectEqual(null, c.get(.cold).over(.cognitive, 35));
    try std.testing.expectEqual(.critical, c.get(.cold).over(.cognitive, 36).?.level);
}

test "a flat dispatch: over a cyclomatic limit, cognitive over none; its cyclomatic is not held" {
    const normal = Classes.defaults.normal;
    var values: std.EnumArray(Metric, u32) = .initFill(1);
    // 37 paths and cognitive 12, within its warning 15: a flat switch.
    values.set(.cyclomatic, 37);
    values.set(.cognitive, 12);
    values.set(.lines, 120);
    const flat = normal.judge(values);
    try std.testing.expect(flat.dispatch);
    // Lines are held as ever.
    try std.testing.expectEqualSlices(Trip, &.{.{ .metric = .lines, .level = .critical, .limit = 100 }}, flat.trips());
    // Cognitive past its warning: real debt, cyclomatic held.
    values.set(.cognitive, 16);
    const tangled = normal.judge(values);
    try std.testing.expect(!tangled.dispatch);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .critical, .limit = 15 }, tangled.trips()[0]);
    // Within every cyclomatic limit, nothing to call a dispatch.
    try std.testing.expect(!normal.isDispatch(10, 1));
    // Cold code has no cognitive warning: within its critical, 35.
    try std.testing.expect(Classes.defaults.cold.isDispatch(30, 35));
    try std.testing.expect(!Classes.defaults.cold.isDispatch(30, 36));
    // No cognitive limit at all: nothing tells a dispatch, so none is.
    try std.testing.expect(!(Thresholds{ .cyclomatic = .{ .critical = 5 } }).isDispatch(30, 0));
}

test "a test block is held as tests whatever its file's class; tests only past cold's limits" {
    try std.testing.expectEqual(Class.tests, Class.forFunction(.hot, true));
    try std.testing.expectEqual(Class.hot, Class.forFunction(.hot, false));
    const t = Classes.defaults.get(.tests);
    try std.testing.expectEqual(null, t.over(.lines, 500));
    try std.testing.expectEqual(null, t.over(.cognitive, 35));
    try std.testing.expectEqual(.critical, t.over(.cyclomatic, 21).?.level);
}

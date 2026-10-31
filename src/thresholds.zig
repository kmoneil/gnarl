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
};

/// How strictly code is held: hot code is on a path that runs often or
/// matters most, cold code is build scripts, tools and the like. Which
/// paths are which is configuration, never guessed.
pub const Class = enum { hot, normal, cold };

pub const Classes = struct {
    hot: Thresholds,
    normal: Thresholds,
    cold: Thresholds,

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

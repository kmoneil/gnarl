//! The limits a function's metrics are held to, and which of them it is
//! over.

const std = @import("std");

/// A metric with limits. Each names a field of `Thresholds` and of a
/// report row.
pub const Metric = enum { cyclomatic, lines, nesting, params };

pub const Level = enum { warning, critical };

pub const Limit = struct {
    /// Over this is a warning.
    warning: ?u32 = null,
    /// Over this is critical.
    critical: ?u32 = null,
};

pub const Thresholds = struct {
    cyclomatic: Limit = .{},
    lines: Limit = .{},
    nesting: Limit = .{},
    params: Limit = .{},

    /// The defaults for code that is neither hot nor cold.
    pub const normal: Thresholds = .{
        .cyclomatic = .{ .warning = 10, .critical = 15 },
        .lines = .{ .warning = 50, .critical = 100 },
        .nesting = .{ .warning = 4 },
        .params = .{ .warning = 4 },
    };

    /// The worst limit `value` of `metric` is over, if it is over one.
    pub fn over(t: Thresholds, metric: Metric, value: u32) ?Trip {
        const limit = switch (metric) {
            inline else => |m| @field(t, @tagName(m)),
        };
        if (limit.critical) |c| if (value > c) return .{ .metric = metric, .level = .critical, .limit = c };
        if (limit.warning) |w| if (value > w) return .{ .metric = metric, .level = .warning, .limit = w };
        return null;
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
    const t: Thresholds = .normal;
    try std.testing.expectEqual(null, t.over(.cyclomatic, 10));
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .warning, .limit = 10 }, t.over(.cyclomatic, 11).?);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .warning, .limit = 10 }, t.over(.cyclomatic, 15).?);
    try std.testing.expectEqual(Trip{ .metric = .cyclomatic, .level = .critical, .limit = 15 }, t.over(.cyclomatic, 16).?);
    // Nesting has a warning and no critical limit.
    try std.testing.expectEqual(Trip{ .metric = .nesting, .level = .warning, .limit = 4 }, t.over(.nesting, 9).?);
    try std.testing.expectEqual(null, (Thresholds{}).over(.lines, 1000));
}

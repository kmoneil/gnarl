//! Which gnarl releases count alike. A release that changes a number gnarl
//! gives a function, the class it holds one to, or how it holds one to its
//! limits is added to `changes`; one that changes only what is read or how
//! it is printed is not. complexity.zon's `.gnarl` names the release a
//! repo is judged by, and a gnarl that counts otherwise says so.

const std = @import("std");
const Version = std.SemanticVersion;

/// Each the first release to count as it does, oldest first.
pub const changes = [_]Version{
    // The first release.
    .{ .major = 0, .minor = 1, .patch = 0 },
    // A function's return type is no part of its numbers.
    .{ .major = 0, .minor = 4, .patch = 0 },
    // A flat dispatch is held to no cyclomatic limit.
    .{ .major = 0, .minor = 5, .patch = 0 },
    // What only test code uses is held as tests.
    .{ .major = 0, .minor = 6, .patch = 0 },
};

/// Which of `changes` `v` counts by: the last at or before it, or null for
/// a version before the first release.
pub fn since(v: Version) ?usize {
    var found: ?usize = null;
    for (changes, 0..) |change, i| {
        if (change.order(v) != .gt) found = i;
    }
    return found;
}

/// Whether `asked` counts as `this` does. A release newer than this one
/// may have changed how it counts, and this one cannot know, so it does
/// not count alike.
pub fn alike(asked: Version, this: Version) bool {
    if (asked.order(this) == .gt) return false;
    return since(asked) == since(this);
}

fn release(text: []const u8) Version {
    return Version.parse(text) catch unreachable;
}

test "changes are in order, each a release" {
    for (changes[1..], changes[0 .. changes.len - 1]) |later, earlier| {
        try std.testing.expectEqual(.gt, later.order(earlier));
    }
    for (changes) |change| {
        try std.testing.expectEqual(null, change.pre);
        try std.testing.expectEqual(null, change.build);
    }
}

test "releases between two changes count alike; across one, not" {
    // 0.2.0 and 0.3.0 changed what is read and printed, not the counting.
    try std.testing.expect(alike(release("0.1.0"), release("0.3.0")));
    try std.testing.expect(alike(release("0.6.0"), release("0.6.1")));
    try std.testing.expect(alike(release("0.4.0"), release("0.4.9")));
    try std.testing.expect(!alike(release("0.3.1"), release("0.4.0")));
    try std.testing.expect(!alike(release("0.5.0"), release("0.6.0")));
    try std.testing.expectEqual(null, since(release("0.0.9")));
    try std.testing.expectEqual(changes.len - 1, since(release("1.0.0")).?);
}

test "a newer release than this one never counts alike: this one cannot know" {
    try std.testing.expect(!alike(release("0.6.1"), release("0.6.0")));
    try std.testing.expect(!alike(release("0.7.0"), release("0.6.0")));
    try std.testing.expect(alike(release("0.6.0"), release("0.6.0")));
}

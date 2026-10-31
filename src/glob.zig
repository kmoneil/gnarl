//! Path globs, written with `/` and matched against a whole path.
//!
//! `*` matches any run of characters within one segment, `?` any one
//! character but a separator, and `**` any run at all, separators
//! included; `**/` also matches no directory, so `src/**/a.zig` names
//! `src/a.zig` too. Anything else matches itself. A path's separators may
//! be the platform's (`\` on Windows).

const std = @import("std");
const isSep = std.fs.path.isSep;

/// Whether `pattern` matches all of `path`.
pub fn match(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (std.mem.startsWith(u8, pattern, "**")) {
        const rest = pattern[2..];
        if (rest.len > 0 and rest[0] == '/' and match(rest[1..], path)) return true;
        for (0..path.len + 1) |i| {
            if (match(rest, path[i..])) return true;
        }
        return false;
    }
    switch (pattern[0]) {
        '*' => {
            for (0..path.len + 1) |i| {
                if (match(pattern[1..], path[i..])) return true;
                if (i < path.len and isSep(path[i])) break;
            }
            return false;
        },
        '?' => return path.len > 0 and !isSep(path[0]) and match(pattern[1..], path[1..]),
        '/' => return path.len > 0 and isSep(path[0]) and match(pattern[1..], path[1..]),
        else => |c| return path.len > 0 and path[0] == c and match(pattern[1..], path[1..]),
    }
}

test "a plain pattern matches only that path" {
    try std.testing.expect(match("build.zig", "build.zig"));
    try std.testing.expect(!match("build.zig", "src/build.zig"));
    try std.testing.expect(!match("src/scan.zig", "src/scan.zig.bak"));
    try std.testing.expect(!match("src", "src/a.zig"));
}

test "* stays within a segment; ? is one character" {
    try std.testing.expect(match("src/*.zig", "src/a.zig"));
    try std.testing.expect(!match("src/*.zig", "src/sub/a.zig"));
    try std.testing.expect(match("src/*_test.zig", "src/scan_test.zig"));
    try std.testing.expect(match("src/?.zig", "src/a.zig"));
    try std.testing.expect(!match("src/?.zig", "src/ab.zig"));
    try std.testing.expect(!match("src?a.zig", "src/a.zig"));
}

test "** crosses segments, and **/ may match none" {
    try std.testing.expect(match("test/**", "test/a.zig"));
    try std.testing.expect(match("test/**", "test/cases/deep/a.zig"));
    try std.testing.expect(match("src/**/a.zig", "src/a.zig"));
    try std.testing.expect(match("src/**/a.zig", "src/x/y/a.zig"));
    try std.testing.expect(!match("src/**/a.zig", "src/x/ba.zig"));
    try std.testing.expect(match("**/*_test.zig", "scan_test.zig"));
    try std.testing.expect(match("**/*_test.zig", "src/deep/scan_test.zig"));
    try std.testing.expect(!match("test/**", "tests/a.zig"));
}

test "the platform's separator in a path matches /" {
    const path = "src" ++ std.fs.path.sep_str ++ "a.zig";
    try std.testing.expect(match("src/a.zig", path));
    try std.testing.expect(match("src/*.zig", path));
    try std.testing.expect(match("**/a.zig", path));
}

//! Turns the path arguments into the list of files to read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const glob = @import("glob.zig");

/// Appends what `arg`, relative to `base`, names to `files`: `arg` itself if
/// it is a file, whatever its extension, or every `.zig` file under it if it
/// is a directory, as `arg` joined with the path inside it. Hidden files
/// under it are not listed, and directories that are hidden or hold build
/// output or fetched packages are not walked into.
///
/// Each path is cleaned the way `std.fs.path.resolveAlloc` does it, on the
/// text alone: `.`, `..` and repeated separators collapse, and on Windows
/// every separator becomes `\`. So one file reached two ways, `gnarl .
/// src/a.zig`, is one string, and is read and reported once. The
/// appended paths are allocated with `arena`.
///
/// What `excludes` leaves out is not listed or walked into; see
/// `Excludes`.
///
/// In a git work tree, a directory's files are those git does not ignore,
/// as git itself says: tracked files, and untracked ones no ignore rule
/// covers, so scratch, vendored copies and generated code a repository
/// ignores are not read. A directory that is itself ignored is read whole,
/// since it was named on purpose, and so is a file named outright. Outside
/// a work tree, with no git, or with `options.git` off, every file is
/// listed.
pub fn collect(
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    arg: []const u8,
    excludes: Excludes,
    files: *std.ArrayList([]const u8),
    options: Options,
) !void {
    const stat = try base.statFile(io, arg, .{});
    const root = try std.fs.path.resolveAlloc(arena, &.{arg});
    if (excluded(root, excludes.paths)) return;
    if (stat.kind != .directory) {
        try files.append(arena, root);
        return;
    }
    const c: Collecting = .{ .arena = arena, .io = io, .base = base, .arg = arg, .root = root, .excludes = excludes, .files = files };
    if (options.git) if (try notIgnored(arena, io, base, arg)) |listed| return c.listed(listed);
    return c.walked();
}

/// One directory named, being collected: what `collect` lists of it.
const Collecting = struct {
    arena: Allocator,
    io: Io,
    base: Io.Dir,
    /// As named, and cleaned.
    arg: []const u8,
    root: []const u8,
    excludes: Excludes,
    files: *std.ArrayList([]const u8),

    /// The .zig files of those git lists under the directory, relative
    /// to it, that the walk would reach and nothing leaves out.
    fn listed(c: Collecting, inside_paths: []const []const u8) !void {
        for (inside_paths) |inside| {
            if (!std.mem.endsWith(u8, inside, ".zig") or skipped(inside)) continue;
            const path = try std.fs.path.resolveAlloc(c.arena, &.{ c.arg, inside });
            if (c.excludes.under(c.root, path)) continue;
            // A tracked file deleted from the work tree is not there.
            const file = c.base.statFile(c.io, path, .{}) catch continue;
            if (file.kind != .directory) try c.files.append(c.arena, path);
        }
    }

    /// The .zig files under the directory, walked, skipping what the walk
    /// skips and nothing leaves out.
    fn walked(c: Collecting) !void {
        var dir = try c.base.openDir(c.io, c.arg, .{ .iterate = true });
        defer dir.close(c.io);
        var walker = try dir.walkSelectively(c.arena);
        defer walker.deinit();
        while (try walker.next(c.io)) |entry| switch (entry.kind) {
            .directory => if (!skipDir(entry.basename)) {
                const path = try std.fs.path.resolveAlloc(c.arena, &.{ c.arg, entry.path });
                if (!c.excludes.under(c.root, path)) try walker.enter(c.io, entry);
            },
            .file => if (entry.basename[0] != '.' and std.mem.endsWith(u8, entry.basename, ".zig")) {
                const path = try std.fs.path.resolveAlloc(c.arena, &.{ c.arg, entry.path });
                if (!c.excludes.under(c.root, path)) try c.files.append(c.arena, path);
            },
            else => {},
        };
    }
};

pub const Options = struct {
    /// Leave out what git ignores, in a git work tree.
    git: bool = true,
};

/// What a walk leaves out besides what it always skips.
pub const Excludes = struct {
    /// The paths `--exclude` names, cleaned as `collect` cleans what it
    /// lists: neither they nor anything inside them is read, even when
    /// named outright.
    paths: []const []const u8 = &.{},
    /// The globs complexity.zon's `.exclude` gives: what one matches, or
    /// what is inside it, is left out when found under a directory named,
    /// as what git ignores is, and read when named outright.
    globs: []const []const u8 = &.{},

    /// Whether `path`, found under the path `root` named, is left out.
    pub fn under(e: Excludes, root: []const u8, path: []const u8) bool {
        return excluded(path, e.paths) or globbed(root, path, e.globs);
    }
};

/// Whether one of `globs` matches `path`, or a directory it is in that is
/// below `root`, the path named that it was found under. `path` itself,
/// named outright, is never globbed.
pub fn globbed(root: []const u8, path: []const u8, globs: []const []const u8) bool {
    if (std.mem.eql(u8, root, path)) return false;
    // Paths found under `.` do not start with it.
    const base = if (std.mem.eql(u8, root, ".")) 0 else root.len;
    for (globs) |pattern| {
        if (glob.match(pattern, path)) return true;
        for (path[base..], base..) |c, i| {
            if (i > base and std.fs.path.isSep(c) and glob.match(pattern, path[0..i])) return true;
        }
    }
    return false;
}

/// Of the cleaned `roots`, the one `path` is found under: the deepest
/// that is it or holds it, `.` holding every relative path. Null if none.
pub fn rootOf(roots: []const []const u8, path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (roots) |root| {
        const holds = std.mem.eql(u8, root, ".") or std.mem.eql(u8, root, path) or
            (path.len > root.len and std.mem.startsWith(u8, path, root) and std.fs.path.isSep(path[root.len]));
        if (holds and (best == null or root.len > best.?.len)) best = root;
    }
    return best;
}

/// The files under the directory `dir` that git does not ignore, relative
/// to it, as git lists them (with `/`). Null when git cannot say (no git,
/// or not a work tree) and when `dir` is itself ignored.
fn notIgnored(arena: Allocator, io: Io, base: Io.Dir, dir: []const u8) Allocator.Error!?[]const []const u8 {
    // The current directory's handle is not one a child can change to:
    // it inherits it instead.
    const cwd: std.process.Child.Cwd = if (base.handle == Io.Dir.cwd().handle) .inherit else .{ .dir = base };
    // 0 when `dir` is ignored, 1 when not, 128 outside a work tree.
    const ignored = std.process.run(arena, io, .{
        .argv = &.{ "git", "-C", dir, "check-ignore", "-q", "." },
        .cwd = cwd,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
    switch (ignored.term) {
        .exited => |code| if (code != 1) return null,
        else => return null,
    }
    const listing = std.process.run(arena, io, .{
        .argv = &.{ "git", "-C", dir, "ls-files", "--cached", "--others", "--exclude-standard", "-z" },
        .cwd = cwd,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
    switch (listing.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, listing.stdout, 0);
    while (it.next()) |path| if (path.len > 0) try out.append(arena, path);
    return out.items;
}

/// Whether a path git lists, with `/`, is one the walk would not reach: a
/// hidden file, or one inside a directory it does not walk into.
pub fn skipped(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (it.peek() == null) return part[0] == '.';
        if (skipDir(part)) return true;
    }
    return false;
}

/// Whether `path` is one of `excludes`, or inside one.
pub fn excluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |exclude| {
        if (!std.mem.startsWith(u8, path, exclude)) continue;
        if (path.len == exclude.len or std.fs.path.isSep(path[exclude.len])) return true;
    }
    return false;
}

/// Sorts `files` and drops repeats, so output order is stable and a file
/// named twice is checked once.
pub fn sortUnique(files: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, files.items, {}, lessThan);
    var kept: usize = 0;
    for (files.items) |path| {
        if (kept > 0 and std.mem.eql(u8, files.items[kept - 1], path)) continue;
        files.items[kept] = path;
        kept += 1;
    }
    files.shrinkRetainingCapacity(kept);
}

fn skipDir(name: []const u8) bool {
    return name[0] == '.' or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, "zig-cache");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "collect: .zig files under a directory, skipping build output and hidden files and dirs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "proj/a.zig",
        "proj/._a.zig",
        "proj/notes.txt",
        "proj/build.zig.zon",
        "proj/sub/b.zig",
        "proj/sub/.#b.zig",
        "proj/zig-out/c.zig",
        "proj/zig-pkg/d.zig",
        "proj/.zig-cache/e.zig",
        "proj/.git/f.zig",
    }) |sub_path| {
        if (std.fs.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }

    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "proj", .{}, &files, .{ .git = false });
    try collect(arena, io, tmp.dir, "proj/notes.txt", .{}, &files, .{ .git = false });
    // Named outright, a hidden file is still listed.
    try collect(arena, io, tmp.dir, "proj/sub/.#b.zig", .{}, &files, .{ .git = false });
    sortUnique(&files);

    try expectPaths(arena, &.{ "proj/a.zig", "proj/notes.txt", "proj/sub/.#b.zig", "proj/sub/b.zig" }, files.items);
}

test "collect: one file reached several ways is listed once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "proj/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/sub/b.zig", .data = "" });

    var files: std.ArrayList([]const u8) = .empty;
    // A leading `./`, a trailing separator, `/` where Windows uses `\`, and
    // a file both walked to and named.
    try collect(arena, io, tmp.dir, "./proj/", .{}, &files, .{ .git = false });
    try collect(arena, io, tmp.dir, "proj/a.zig", .{}, &files, .{ .git = false });
    try collect(arena, io, tmp.dir, "proj", .{}, &files, .{ .git = false });
    sortUnique(&files);

    try expectPaths(arena, &.{ "proj/a.zig", "proj/sub/b.zig" }, files.items);
}

/// `expected` is written with `/`; each is compared in the native form.
fn expectPaths(arena: Allocator, expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(try std.fs.path.resolveAlloc(arena, &.{want}), got);
    }
}

test "collect: a missing path is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var files: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(
        error.FileNotFound,
        collect(std.testing.allocator, std.testing.io, tmp.dir, "nope", .{}, &files, .{ .git = false }),
    );
}

test "collect: in a git work tree, what git ignores is left out; named outright, it is read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The test needs git; without it there is nothing to ask.
    const git = std.process.run(arena, io, .{ .argv = &.{ "git", "--version" } }) catch return error.SkipZigTest;
    if (git.term != .exited or git.term.exited != 0) return error.SkipZigTest;

    try tmp.dir.createDirPath(io, "proj");
    for ([_][2][]const u8{
        .{ "proj/.gitignore", "_tmp/\nkept/\n" },
        .{ "proj/a.zig", "" },
        .{ "proj/sub/c.zig", "" },
        .{ "proj/_tmp/b.zig", "" },
        .{ "proj/kept/forced.zig", "" },
        .{ "proj/gone.zig", "" },
        .{ "proj/.hidden/d.zig", "" },
        .{ "proj/zig-out/e.zig", "" },
    }) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        // Tracked though its directory is ignored, and tracked then
        // deleted from the work tree.
        &.{ "git", "add", "-f", "kept/forced.zig", "gone.zig" },
    }) |argv| {
        const r = try std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .dir = try tmp.dir.openDir(io, "proj", .{}) } });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    }
    try tmp.dir.deleteFile(io, "proj/gone.zig");

    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "proj", .{}, &files, .{});
    sortUnique(&files);
    try expectPaths(arena, &.{ "proj/a.zig", "proj/kept/forced.zig", "proj/sub/c.zig" }, files.items);

    // Named outright, an ignored file or directory is read.
    files.clearRetainingCapacity();
    try collect(arena, io, tmp.dir, "proj/_tmp/b.zig", .{}, &files, .{});
    try collect(arena, io, tmp.dir, "proj/kept", .{}, &files, .{});
    sortUnique(&files);
    try expectPaths(arena, &.{ "proj/_tmp/b.zig", "proj/kept/forced.zig" }, files.items);

    // With git off, every file is listed, as outside a work tree.
    files.clearRetainingCapacity();
    try collect(arena, io, tmp.dir, "proj", .{}, &files, .{ .git = false });
    sortUnique(&files);
    try expectPaths(arena, &.{ "proj/_tmp/b.zig", "proj/a.zig", "proj/kept/forced.zig", "proj/sub/c.zig" }, files.items);
}

test "skipped: hidden files, and what is inside a directory the walk leaves" {
    try std.testing.expect(!skipped("a.zig"));
    try std.testing.expect(!skipped("src/a.zig"));
    try std.testing.expect(skipped(".a.zig"));
    try std.testing.expect(skipped("src/.#a.zig"));
    try std.testing.expect(skipped(".hidden/a.zig"));
    try std.testing.expect(skipped("x/zig-out/a.zig"));
    try std.testing.expect(skipped("zig-pkg/dep/a.zig"));
}

test "collect: an excluded directory is not walked into, an excluded file not listed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "proj/a.zig",
        "proj/_tmp/wt/a.zig",
        "proj/_tmpfile.zig",
        "proj/gen/b.zig",
        "proj/gen/c.zig",
    }) |sub_path| {
        if (std.fs.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }

    const excludes = [_][]const u8{
        try std.fs.path.resolveAlloc(arena, &.{"proj/_tmp"}),
        try std.fs.path.resolveAlloc(arena, &.{"proj/gen/c.zig"}),
    };
    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "proj", .{ .paths = &excludes }, &files, .{ .git = false });
    // Named outright, an excluded file is still skipped.
    try collect(arena, io, tmp.dir, "proj/_tmp/wt/a.zig", .{ .paths = &excludes }, &files, .{ .git = false });
    sortUnique(&files);

    // `_tmpfile.zig` shares `_tmp`'s first letters but is not inside it.
    try expectPaths(arena, &.{ "proj/_tmpfile.zig", "proj/a.zig", "proj/gen/b.zig" }, files.items);
}

test "collect: what a complexity.zon glob matches is left out under a directory named, and read named outright" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "proj/a.zig",
        "proj/fixtures/f.zig",
        "proj/fixtures/deep/g.zig",
        "proj/src/b.zig",
        "proj/src/b_gen.zig",
    }) |sub_path| {
        if (std.fs.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }
    const excludes: Excludes = .{ .globs = &.{ "proj/fixtures", "**/*_gen.zig" } };

    var files: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, tmp.dir, "proj", excludes, &files, .{ .git = false });
    try expectPaths(arena, &.{ "proj/a.zig", "proj/src/b.zig" }, files.items);

    // Named outright, the directory and the file are read.
    files.clearRetainingCapacity();
    try collect(arena, io, tmp.dir, "proj/fixtures", excludes, &files, .{ .git = false });
    try collect(arena, io, tmp.dir, "proj/src/b_gen.zig", excludes, &files, .{ .git = false });
    sortUnique(&files);
    try expectPaths(arena, &.{ "proj/fixtures/deep/g.zig", "proj/fixtures/f.zig", "proj/src/b_gen.zig" }, files.items);
}

test "globbed: the path or a directory it is in below the root; rootOf: the deepest root holding it" {
    const globs = [_][]const u8{"test/golden"};
    try std.testing.expect(globbed(".", "test/golden/a.zig", &globs));
    try std.testing.expect(globbed("test", "test/golden/a.zig", &globs));
    try std.testing.expect(!globbed("test/golden", "test/golden/a.zig", &globs));
    try std.testing.expect(!globbed("test/golden", "test/golden", &globs));
    try std.testing.expect(!globbed(".", "test/goldenrod.zig", &globs));
    try std.testing.expectEqualStrings("test/golden", rootOf(&.{ ".", "test/golden", "test" }, "test/golden/a.zig").?);
    try std.testing.expectEqualStrings(".", rootOf(&.{ ".", "src" }, "test/a.zig").?);
    try std.testing.expectEqual(null, rootOf(&.{"src"}, "srcs/a.zig"));
}

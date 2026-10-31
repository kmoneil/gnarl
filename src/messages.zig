//! What gnarl has to say besides its report: errors, which make the exit
//! status 2, and notes. Each is written to stderr as it is added, and kept
//! for the formats that carry everything (json and xml), so a program
//! reading stdout never needs stderr.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const formats = @import("formats.zig");

pub const Level = enum { @"error", note };

pub const Message = struct {
    level: Level,
    /// The file or argument it is about, or "" for neither.
    path: []const u8 = "",
    /// Where in the file, both from 1, when it is about a place in one.
    line: ?u32 = null,
    column: ?u32 = null,
    text: []const u8,
    /// Each a further line: the functions a name fits, say.
    more: []const []const u8 = &.{},
};

pub const Messages = struct {
    arena: Allocator,
    items: std.ArrayList(Message) = .empty,
    /// Whether each is written to stderr as it is added.
    echo: bool = true,

    pub fn add(m: *Messages, message: Message) Allocator.Error!void {
        try m.items.append(m.arena, message);
        if (m.echo) print(message);
    }

    /// Adds an error about `path`.
    pub fn fail(m: *Messages, path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try m.add(.{ .level = .@"error", .path = path, .text = try std.fmt.allocPrint(m.arena, fmt, args) });
    }

    pub fn errors(m: Messages) usize {
        var n: usize = 0;
        for (m.items.items) |message| n += @intFromBool(message.level == .@"error");
        return n;
    }
};

/// `message` as stderr shows it: `gnarl: path:line:column: text`, as much
/// of the place as it has, then each further line indented.
fn print(message: Message) void {
    var buffer: [256]u8 = undefined;
    const locked = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    format(&locked.file_writer.interface, message) catch {};
}

pub fn format(w: *std.Io.Writer, message: Message) std.Io.Writer.Error!void {
    try w.writeAll("gnarl: ");
    if (message.path.len > 0) {
        try w.writeAll(message.path);
        if (message.line) |line| try w.print(":{d}", .{line});
        if (message.column) |column| try w.print(":{d}", .{column});
        try w.writeAll(": ");
    }
    if (message.level == .note) try w.writeAll("note: ");
    try w.print("{s}\n", .{message.text});
    for (message.more) |more| try w.print("  {s}\n", .{more});
}

/// `,"errors":[...],"notes":[...]`, for a json document: each message by
/// its level, as an object with the same fields but `level`.
pub fn writeJson(w: *Writer, items: []const Message) Writer.Error!void {
    inline for (.{ .{ "errors", Level.@"error" }, .{ "notes", Level.note } }) |pair| {
        try w.print(",\"{s}\":[", .{pair[0]});
        var first = true;
        for (items) |m| if (m.level == pair[1]) {
            if (!first) try w.writeByte(',');
            first = false;
            try std.json.Stringify.value(.{ .path = m.path, .line = m.line, .column = m.column, .text = m.text, .more = m.more }, .{}, w);
        };
        try w.writeByte(']');
    }
}

/// `<errors>` and `<notes>`, for an xml document: each message an element
/// with its fields as attributes, and a `<more text="..."/>` for each
/// further line.
pub fn writeXml(w: *Writer, items: []const Message) Writer.Error!void {
    inline for (.{ .{ "errors", "error", Level.@"error" }, .{ "notes", "note", Level.note } }) |names| {
        const any = for (items) |m| {
            if (m.level == names[2]) break true;
        } else false;
        if (!any) {
            try w.print("  <{s}/>\n", .{names[0]});
        } else {
            try w.print("  <{s}>\n", .{names[0]});
            for (items) |m| if (m.level == names[2]) {
                try w.print("    <{s}", .{names[1]});
                try formats.attr(w, "path", m.path);
                if (m.line) |line| try formats.attrInt(w, "line", line);
                if (m.column) |column| try formats.attrInt(w, "column", column);
                try formats.attr(w, "text", m.text);
                if (m.more.len == 0) {
                    try w.writeAll("/>\n");
                } else {
                    try w.writeAll(">\n");
                    for (m.more) |more| {
                        try w.writeAll("      <more");
                        try formats.attr(w, "text", more);
                        try w.writeAll("/>\n");
                    }
                    try w.print("    </{s}>\n", .{names[1]});
                }
            };
            try w.print("  </{s}>\n", .{names[0]});
        }
    }
}

test "format: as much of the place as there is, then the further lines" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try format(&out.writer, .{ .level = .@"error", .path = "a.zig", .line = 3, .column = 7, .text = "expected ';'" });
    try format(&out.writer, .{ .level = .@"error", .path = "nope", .text = "FileNotFound" });
    try format(&out.writer, .{ .level = .note, .text = "plain", .more = &.{ "a.zig:1  f", "b.zig:2  S.f" } });
    try std.testing.expectEqualStrings(
        \\gnarl: a.zig:3:7: expected ';'
        \\gnarl: nope: FileNotFound
        \\gnarl: note: plain
        \\  a.zig:1  f
        \\  b.zig:2  S.f
        \\
    , out.written());
}

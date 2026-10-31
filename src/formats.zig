//! The pieces the xml, csv and tsv writers share.
//!
//! xml: every value is an attribute, escaped; the documents have no text
//! content. csv: RFC 4180 quoting, a field quoted only when it holds a
//! comma, a quote or a line break, a quote inside doubled. tsv: no field
//! holds a tab or a line break; a tab, newline, carriage return or
//! backslash in one is written `\t`, `\n`, `\r` or `\\`. Both end each row
//! with a newline and begin with a header row.

const std = @import("std");
const Writer = std.Io.Writer;

/// ` name="value"`, the value escaped for an attribute.
pub fn attr(w: *Writer, name: []const u8, value: []const u8) Writer.Error!void {
    try w.print(" {s}=\"", .{name});
    var view = std.unicode.Utf8View.initUnchecked(value);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |c| {
        if (c.len > 1) {
            try w.writeAll(c);
            continue;
        }
        switch (c[0]) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            '\t' => try w.writeAll("&#9;"),
            '\n' => try w.writeAll("&#10;"),
            '\r' => try w.writeAll("&#13;"),
            // Not allowed in XML 1.0 at all.
            0...8, 11, 12, 14...31 => try w.writeAll("\u{FFFD}"),
            else => try w.writeByte(c[0]),
        }
    }
    try w.writeByte('"');
}

pub fn attrInt(w: *Writer, name: []const u8, value: anytype) Writer.Error!void {
    try w.print(" {s}=\"{d}\"", .{ name, value });
}

pub fn attrBool(w: *Writer, name: []const u8, value: bool) Writer.Error!void {
    try w.print(" {s}=\"{s}\"", .{ name, if (value) "true" else "false" });
}

pub const Delimited = enum { csv, tsv };

/// One field of a row: a separator first unless it is the row's first.
pub fn field(w: *Writer, kind: Delimited, first: bool, value: []const u8) Writer.Error!void {
    if (!first) try w.writeByte(if (kind == .csv) ',' else '\t');
    switch (kind) {
        .csv => {
            if (std.mem.findAny(u8, value, ",\"\r\n") == null) return w.writeAll(value);
            try w.writeByte('"');
            for (value) |c| {
                if (c == '"') try w.writeByte('"');
                try w.writeByte(c);
            }
            try w.writeByte('"');
        },
        .tsv => for (value) |c| switch (c) {
            '\t' => try w.writeAll("\\t"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        },
    }
}

pub fn fieldInt(w: *Writer, kind: Delimited, first: bool, value: anytype) Writer.Error!void {
    var buffer: [24]u8 = undefined;
    try field(w, kind, first, std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
}

/// The header row: `names`, then the newline.
pub fn header(w: *Writer, kind: Delimited, names: []const []const u8) Writer.Error!void {
    for (names, 0..) |name, i| try field(w, kind, i == 0, name);
    try w.writeByte('\n');
}

// For the tests: read the documents back.

/// Splits csv or tsv text into rows of fields, undoing the quoting or
/// escaping. Allocated with `arena`.
pub fn readDelimited(arena: std.mem.Allocator, kind: Delimited, text: []const u8) ![]const []const []const u8 {
    var rows: std.ArrayList([]const []const u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const separator: u8 = if (kind == .csv) ',' else '\t';
    var quoted = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (kind == .csv and quoted) {
            if (c == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    try current.append(arena, '"');
                    i += 1;
                } else quoted = false;
            } else try current.append(arena, c);
            continue;
        }
        if (kind == .csv and c == '"' and current.items.len == 0) {
            quoted = true;
        } else if (kind == .tsv and c == '\\' and i + 1 < text.len) {
            i += 1;
            try current.append(arena, switch (text[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                '\\' => '\\',
                else => return error.BadEscape,
            });
        } else if (c == separator) {
            try fields.append(arena, try current.toOwnedSlice(arena));
        } else if (c == '\n') {
            try fields.append(arena, try current.toOwnedSlice(arena));
            try rows.append(arena, try fields.toOwnedSlice(arena));
        } else try current.append(arena, c);
    }
    if (quoted or current.items.len > 0 or fields.items.len > 0) return error.Unterminated;
    return rows.items;
}

/// An element as the xml documents write them: a name, attributes, and
/// elements inside.
pub const Element = struct {
    name: []const u8,
    attrs: []const [2][]const u8,
    children: []const Element,

    pub fn get(e: Element, name: []const u8) ?[]const u8 {
        for (e.attrs) |a| if (std.mem.eql(u8, a[0], name)) return a[1];
        return null;
    }

    pub fn child(e: Element, name: []const u8) ?Element {
        for (e.children) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

/// Reads a document of elements and attributes alone, checking that each
/// element is closed in order and that nothing but whitespace is between
/// them. Allocated with `arena`.
pub fn readXml(arena: std.mem.Allocator, text: []const u8) !Element {
    var r: XmlReader = .{ .arena = arena, .text = text };
    if (std.mem.startsWith(u8, text, "<?xml")) r.pos = (std.mem.find(u8, text, "?>") orelse return error.BadXml) + 2;
    const root = try r.element();
    r.skipSpace();
    if (r.pos != text.len) return error.BadXml;
    return root;
}

const XmlReader = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn skipSpace(r: *XmlReader) void {
        while (r.pos < r.text.len and std.ascii.isWhitespace(r.text[r.pos])) r.pos += 1;
    }

    fn name(r: *XmlReader) ![]const u8 {
        const start = r.pos;
        while (r.pos < r.text.len and (std.ascii.isAlphanumeric(r.text[r.pos]) or r.text[r.pos] == '_' or r.text[r.pos] == '-')) r.pos += 1;
        if (r.pos == start) return error.BadXml;
        return r.text[start..r.pos];
    }

    fn element(r: *XmlReader) anyerror!Element {
        r.skipSpace();
        if (r.pos >= r.text.len or r.text[r.pos] != '<') return error.BadXml;
        r.pos += 1;
        const tag = try r.name();
        var attrs: std.ArrayList([2][]const u8) = .empty;
        while (true) {
            r.skipSpace();
            if (std.mem.startsWith(u8, r.text[r.pos..], "/>")) {
                r.pos += 2;
                return .{ .name = tag, .attrs = attrs.items, .children = &.{} };
            }
            if (r.pos < r.text.len and r.text[r.pos] == '>') {
                r.pos += 1;
                break;
            }
            const key = try r.name();
            if (!std.mem.startsWith(u8, r.text[r.pos..], "=\"")) return error.BadXml;
            r.pos += 2;
            const end = std.mem.findScalarPos(u8, r.text, r.pos, '"') orelse return error.BadXml;
            try attrs.append(r.arena, .{ key, try unescape(r.arena, r.text[r.pos..end]) });
            r.pos = end + 1;
        }
        var children: std.ArrayList(Element) = .empty;
        while (true) {
            r.skipSpace();
            if (std.mem.startsWith(u8, r.text[r.pos..], "</")) {
                r.pos += 2;
                if (!std.mem.eql(u8, try r.name(), tag)) return error.Unbalanced;
                if (r.pos >= r.text.len or r.text[r.pos] != '>') return error.BadXml;
                r.pos += 1;
                return .{ .name = tag, .attrs = attrs.items, .children = children.items };
            }
            try children.append(r.arena, try r.element());
        }
    }
};

fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '<') return error.BadXml;
        if (text[i] != '&') {
            try out.append(arena, text[i]);
            continue;
        }
        const end = std.mem.findScalarPos(u8, text, i, ';') orelse return error.BadXml;
        const entity = text[i + 1 .. end];
        const entities = [_][2][]const u8{ .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" }, .{ "#9", "\t" }, .{ "#10", "\n" }, .{ "#13", "\r" } };
        for (entities) |e| {
            if (std.mem.eql(u8, entity, e[0])) {
                try out.appendSlice(arena, e[1]);
                break;
            }
        } else return error.BadXml;
        i = end;
    }
    return out.items;
}

test "attr: everything that would break an attribute is escaped, and reads back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    const value = "test \"a<b>&'c'\"\twith é";
    try out.writer.writeAll("<x");
    try attr(&out.writer, "name", value);
    try out.writer.writeAll("/>");
    try std.testing.expectEqualStrings("<x name=\"test &quot;a&lt;b&gt;&amp;&apos;c&apos;&quot;&#9;with é\"/>", out.written());
    try std.testing.expectEqualStrings(value, (try readXml(arena, out.written())).get("name").?);
}

test "field: csv quotes only when it must, tsv escapes; both read back" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const values = [_][]const u8{ "plain", "a,b", "say \"hi\"", "two\nlines", "tab\there", "back\\slash" };
    for ([_]Delimited{ .csv, .tsv }) |kind| {
        var out: Writer.Allocating = .init(arena);
        try header(&out.writer, kind, &values);
        const rows = try readDelimited(arena, kind, out.written());
        try std.testing.expectEqual(1, rows.len);
        for (values, rows[0]) |want, got| try std.testing.expectEqualStrings(want, got);
        if (kind == .tsv) try std.testing.expectEqual(1, std.mem.countScalar(u8, out.written(), '\n'));
    }
    var out: Writer.Allocating = .init(arena);
    try header(&out.writer, .csv, &values);
    try std.testing.expectEqualStrings("plain,\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",tab\there,back\\slash\n", out.written());
}

test "readXml: an element left open, or closed out of order, is an error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.Unbalanced, readXml(arena, "<a><b></a></b>"));
    try std.testing.expectError(error.BadXml, readXml(arena, "<a x=\"1\">text</a>"));
    const doc = try readXml(arena, "<?xml version=\"1.0\"?>\n<a x=\"1\">\n  <b y=\"&amp;\"/>\n</a>\n");
    try std.testing.expectEqualStrings("&", doc.child("b").?.get("y").?);
}

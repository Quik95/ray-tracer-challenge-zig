//! A reader for the indented, line-oriented notation scene files are written
//! in — the subset of YAML those files actually use.
//!
//! What that subset is: mappings of `key: value`, sequences of `- item`,
//! nesting by indentation, inline sequences in brackets, and comments from a
//! `#` to the end of the line. What it is not: anchors, aliases, tags,
//! multi-line scalars, flow mappings, or documents in the plural. None of
//! those appear in a scene, and leaving them out keeps this a few hundred
//! lines rather than a library.
//!
//! The result is a tree of plain values, still made of slices into the source
//! text: nothing here knows what a sphere is. Turning the tree into a world
//! is the scene reader's business, one file over.

const std = @import("std");

/// A node of the tree: text, a sequence, or a mapping. A scalar is left as
/// written — reading it as a number or a truth value is the caller's to do,
/// since only the caller knows which it wanted.
pub const Value = union(enum) {
    scalar: []const u8,
    list: []const Value,
    map: []const Field,

    /// The empty scalar, which is what a key with nothing after it holds.
    pub const empty: Value = .{ .scalar = "" };

    /// The value under `key`, if this is a mapping that has one. A key
    /// written twice is read the first time it appears.
    pub fn get(self: Value, key: []const u8) ?Value {
        const pairs = switch (self) {
            .map => |p| p,
            else => return null,
        };
        for (pairs) |field| {
            if (std.mem.eql(u8, field.key, key)) return field.value;
        }
        return null;
    }

    /// The mapping's fields, in the order they were written, or none if this
    /// is not a mapping.
    pub fn fields(self: Value) []const Field {
        return switch (self) {
            .map => |f| f,
            else => &.{},
        };
    }

    /// The sequence's elements, or none if this is not a sequence. A lone
    /// value is *not* read as a sequence of one; `elements` is for callers
    /// that want that leniency.
    pub fn items(self: Value) []const Value {
        return switch (self) {
            .list => |l| l,
            else => &.{},
        };
    }

    /// The value read as a sequence, allowing a single value to stand in for
    /// a sequence holding only it. `self` is borrowed, so the result lives
    /// only as long as the value does.
    pub fn elements(self: *const Value) []const Value {
        return switch (self.*) {
            .list => |l| l,
            else => @as(*const [1]Value, self)[0..],
        };
    }

    /// The scalar's text, or null if this node is not a scalar.
    pub fn text(self: Value) ?[]const u8 {
        return switch (self) {
            .scalar => |s| s,
            else => null,
        };
    }

    /// Whether this node is a scalar equal to `expected`.
    pub fn is(self: Value, expected: []const u8) bool {
        const s = self.text() orelse return false;
        return std.mem.eql(u8, s, expected);
    }

    /// The scalar read as a number, or null if it is not one. The notation
    /// has no integer type of its own: a count and a coordinate are written
    /// the same way and told apart by what reads them.
    pub fn float(self: Value, comptime T: type) ?T {
        const s = self.text() orelse return null;
        if (s.len == 0) return null;
        return std.fmt.parseFloat(T, s) catch null;
    }

    /// The scalar read as a whole, non-negative count.
    pub fn count(self: Value) ?usize {
        const s = self.text() orelse return null;
        return std.fmt.parseInt(usize, s, 10) catch null;
    }

    /// The scalar read as a truth value, written either way round.
    pub fn boolean(self: Value) ?bool {
        const s = self.text() orelse return null;
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or
            std.mem.eql(u8, s, "on")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no") or
            std.mem.eql(u8, s, "off")) return false;
        return null;
    }
};

/// One `key: value` pair of a mapping.
pub const Field = struct {
    key: []const u8,
    value: Value,
};

pub const ParseError = std.mem.Allocator.Error || error{
    /// A line that is neither a sequence item nor a `key: value` pair.
    MalformedLine,
    /// A line indented further than anything it could belong to, or
    /// indented with something other than spaces.
    BadIndentation,
    /// An inline sequence that runs off the end of its line, or one whose
    /// elements are not separated by commas.
    MalformedList,
};

/// A parsed file: the tree, and the memory it is built in.
///
/// The nodes hold slices into the source text rather than copies of it, so
/// the source has to outlive the document — which costs nothing, since a
/// scene is read from a buffer the caller already holds.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Read `source` as a document. The caller owns the result and frees it with
/// `deinit`, and keeps `source` alive for as long as the result.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Document {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    var lines: std.ArrayList(Line) = .empty;
    var rest = source;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const raw = rest[0..end];
        rest = rest[@min(end + 1, rest.len)..];
        if (try Line.of(raw)) |line| try lines.append(scratch, line);
    }

    if (lines.items.len == 0) return .{ .arena = arena, .root = .empty };
    if (lines.items[0].indent != 0) return error.BadIndentation;

    var parser: Parser = .{ .arena = scratch, .lines = lines.items };
    const root = try parser.node(0);
    // A line left over is one the tree had no room for: indented to a depth
    // nothing above it opened.
    if (parser.at < parser.lines.len) return error.BadIndentation;
    return .{ .arena = arena, .root = root };
}

/// A line worth reading: how far it is indented, and what it says once the
/// indentation and any comment are taken off.
const Line = struct {
    indent: usize,
    text: []const u8,

    /// The line `raw` carries, or null if it carries nothing — blank, or
    /// comment all the way across.
    fn of(raw: []const u8) ParseError!?Line {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent == line.len) return null;
        // A tab is a space to the eye and not to the parser, which is how a
        // file comes to mean something other than it looks like. Refuse it.
        if (line[indent] == '\t') return error.BadIndentation;
        if (line[indent] == '#') return null;

        const body = stripComment(line[indent..]);
        if (body.len == 0) return null;
        return .{ .indent = indent, .text = body };
    }
};

/// The line with any trailing comment taken off. A `#` counts as the start of
/// one only where a space stands before it, so that a colour written as a name
/// or a path holding a `#` survives.
fn stripComment(text: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (text, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#' and i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) {
            return std.mem.trimEnd(u8, text[0..i], " \t");
        }
    }
    return text;
}

/// Where a line's key ends: the index of the colon that separates it from the
/// value, or null if the line is not a `key: value` pair at all. Only a colon
/// at the end of the line or followed by a space divides one, so that a value
/// like a time or a URL is left whole.
fn keyEnd(text: []const u8) ?usize {
    for (text, 0..) |c, i| {
        if (c == '[' or c == ',') return null;
        if (c != ':') continue;
        if (i + 1 == text.len or text[i + 1] == ' ') return if (i == 0) null else i;
    }
    return null;
}

/// Whether the line opens a sequence item.
fn isItem(text: []const u8) bool {
    return text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

/// The scalar `text` writes, with any quotes taken off.
fn scalarOf(text: []const u8) Value {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'') and text[text.len - 1] == text[0]) {
        return .{ .scalar = text[1 .. text.len - 1] };
    }
    return .{ .scalar = text };
}

/// A cursor over the lines, and the tree being built from them.
const Parser = struct {
    arena: std.mem.Allocator,
    lines: []Line,
    at: usize = 0,

    /// Whatever stands at `indent`, starting from the current line: a
    /// sequence if it opens with an item, a mapping otherwise.
    fn node(self: *Parser, indent: usize) ParseError!Value {
        if (self.at >= self.lines.len) return .empty;
        return if (isItem(self.lines[self.at].text))
            self.sequence(indent)
        else
            self.mapping(indent);
    }

    fn sequence(self: *Parser, indent: usize) ParseError!Value {
        var out: std.ArrayList(Value) = .empty;
        while (self.at < self.lines.len) {
            const line = self.lines[self.at];
            if (line.indent != indent or !isItem(line.text)) break;

            const body = std.mem.trimStart(u8, line.text[1..], " ");
            if (body.len == 0) {
                // Nothing after the dash: the item is written underneath it.
                self.at += 1;
                try out.append(self.arena, try self.deeper(indent));
            } else if (body[0] == '[') {
                self.at += 1;
                try out.append(self.arena, try self.flow(body));
            } else if (keyEnd(body) != null) {
                // A mapping that starts on the dash's own line. Its keys line
                // up under the first one, so the item is read as though the
                // dash were indentation — which, for this purpose, it is.
                const column = indent + (line.text.len - body.len);
                self.lines[self.at] = .{ .indent = column, .text = body };
                try out.append(self.arena, try self.mapping(column));
            } else {
                self.at += 1;
                try out.append(self.arena, scalarOf(body));
            }
        }
        return .{ .list = try out.toOwnedSlice(self.arena) };
    }

    fn mapping(self: *Parser, indent: usize) ParseError!Value {
        var out: std.ArrayList(Field) = .empty;
        while (self.at < self.lines.len) {
            const line = self.lines[self.at];
            if (line.indent < indent) break;
            if (line.indent > indent) return error.BadIndentation;
            if (isItem(line.text)) break;

            const split = keyEnd(line.text) orelse return error.MalformedLine;
            const key = std.mem.trimEnd(u8, line.text[0..split], " ");
            const body = std.mem.trimStart(u8, line.text[split + 1 ..], " ");
            self.at += 1;

            const value: Value = if (body.len > 0)
                if (body[0] == '[') try self.flow(body) else scalarOf(body)
            else if (self.at < self.lines.len and
                self.lines[self.at].indent == indent and
                isItem(self.lines[self.at].text))
                // A sequence written flush with its key rather than under it,
                // which the notation allows and scene files use.
                try self.sequence(indent)
            else
                try self.deeper(indent);

            try out.append(self.arena, .{ .key = (scalarOf(key).text().?), .value = value });
        }
        return .{ .map = try out.toOwnedSlice(self.arena) };
    }

    /// Whatever is written underneath a line indented `indent`, or the empty
    /// scalar if nothing is.
    fn deeper(self: *Parser, indent: usize) ParseError!Value {
        if (self.at >= self.lines.len) return .empty;
        const next = self.lines[self.at];
        if (next.indent <= indent) return .empty;
        return self.node(next.indent);
    }

    /// A bracketed sequence, written on one line and possibly holding others.
    fn flow(self: *Parser, text: []const u8) ParseError!Value {
        var cursor: usize = 0;
        const value = try self.flowAt(text, &cursor);
        if (std.mem.trim(u8, text[cursor..], " ").len != 0) return error.MalformedList;
        return value;
    }

    fn flowAt(self: *Parser, text: []const u8, cursor: *usize) ParseError!Value {
        std.debug.assert(text[cursor.*] == '[');
        cursor.* += 1;

        var out: std.ArrayList(Value) = .empty;
        while (true) {
            while (cursor.* < text.len and text[cursor.*] == ' ') cursor.* += 1;
            if (cursor.* == text.len) return error.MalformedList;
            if (text[cursor.*] == ']') {
                cursor.* += 1;
                return .{ .list = try out.toOwnedSlice(self.arena) };
            }

            if (text[cursor.*] == '[') {
                try out.append(self.arena, try self.flowAt(text, cursor));
            } else {
                const start = cursor.*;
                while (cursor.* < text.len and text[cursor.*] != ',' and
                    text[cursor.*] != ']') cursor.* += 1;
                if (cursor.* == text.len) return error.MalformedList;
                const word = std.mem.trim(u8, text[start..cursor.*], " ");
                if (word.len == 0) return error.MalformedList;
                try out.append(self.arena, scalarOf(word));
            }

            // Elements are divided by commas, and the last one is followed by
            // the bracket instead.
            while (cursor.* < text.len and text[cursor.*] == ' ') cursor.* += 1;
            if (cursor.* == text.len) return error.MalformedList;
            if (text[cursor.*] == ',') {
                cursor.* += 1;
            } else if (text[cursor.*] != ']') {
                return error.MalformedList;
            }
        }
    }
};

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

/// Parse `source` into an arena the caller drops afterwards.
fn parsed(source: []const u8) !Document {
    return parse(testing.allocator, source);
}

test "a mapping reads its keys in the order they were written" {
    var doc = try parsed(
        \\width: 100
        \\height: 50
        \\name: the eye
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.root.fields().len);
    try testing.expectEqualStrings("width", doc.root.fields()[0].key);
    try testing.expectEqual(@as(?usize, 100), doc.root.get("width").?.count());
    try testing.expectEqualStrings("the eye", doc.root.get("name").?.text().?);
    try testing.expect(doc.root.get("depth") == null);
}

test "an inline sequence holds the numbers on its line" {
    var doc = try parsed("from: [ -6, 6.5, -10 ]");
    defer doc.deinit();

    const from = doc.root.get("from").?.items();
    try testing.expectEqual(@as(usize, 3), from.len);
    try testing.expectEqual(@as(?f64, -6), from[0].float(f64));
    try testing.expectEqual(@as(?f64, 6.5), from[1].float(f64));
}

test "an inline sequence may hold others" {
    var doc = try parsed("transform: [ [ scale, 2, 2, 2 ], [ translate, 0, 1, 0 ] ]");
    defer doc.deinit();

    const steps = doc.root.get("transform").?.items();
    try testing.expectEqual(@as(usize, 2), steps.len);
    try testing.expect(steps[0].items()[0].is("scale"));
    try testing.expectEqual(@as(?f64, 1), steps[1].items()[2].float(f64));
}

test "a sequence of mappings starting on the dash's own line" {
    var doc = try parsed(
        \\- add: camera
        \\  width: 100
        \\- add: sphere
        \\  material:
        \\    color: [ 1, 0, 0 ]
    );
    defer doc.deinit();

    const items = doc.root.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expect(items[0].get("add").?.is("camera"));
    try testing.expectEqual(@as(?usize, 100), items[0].get("width").?.count());

    const color = items[1].get("material").?.get("color").?.items();
    try testing.expectEqual(@as(?f64, 1), color[0].float(f64));
}

test "a sequence under a key, indented or flush with it" {
    for ([_][]const u8{
        \\transform:
        \\  - [ scale, 2, 2, 2 ]
        \\  - [ translate, 0, 1, 0 ]
        \\shadow: false
        ,
        \\transform:
        \\- [ scale, 2, 2, 2 ]
        \\- [ translate, 0, 1, 0 ]
        \\shadow: false
        ,
    }) |source| {
        var doc = try parsed(source);
        defer doc.deinit();

        try testing.expectEqual(@as(usize, 2), doc.root.get("transform").?.items().len);
        try testing.expectEqual(false, doc.root.get("shadow").?.boolean().?);
    }
}

test "an item written underneath its dash" {
    var doc = try parsed(
        \\-
        \\  add: sphere
        \\-
        \\  add: plane
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.root.items().len);
    try testing.expect(doc.root.items()[1].get("add").?.is("plane"));
}

test "comments and blank lines say nothing" {
    var doc = try parsed(
        \\# the eye
        \\
        \\width: 100  # pixels across
        \\name: "a # in quotes stays"
        \\
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.root.fields().len);
    try testing.expectEqual(@as(?usize, 100), doc.root.get("width").?.count());
    try testing.expectEqualStrings("a # in quotes stays", doc.root.get("name").?.text().?);
}

test "quotes come off a scalar and a key alike" {
    var doc = try parsed(
        \\"field-of-view": '1.152'
    );
    defer doc.deinit();

    try testing.expectEqual(@as(?f64, 1.152), doc.root.get("field-of-view").?.float(f64));
}

test "a lone value stands in for a sequence of one" {
    var doc = try parsed("children: only-me");
    defer doc.deinit();

    const child = doc.root.get("children").?;
    try testing.expectEqual(@as(usize, 1), child.elements().len);
    try testing.expect(child.elements()[0].is("only-me"));
}

test "reading a scalar as what it is not gives nothing" {
    var doc = try parsed(
        \\a: not a number
        \\b: [ 1 ]
        \\c:
    );
    defer doc.deinit();

    try testing.expect(doc.root.get("a").?.float(f64) == null);
    try testing.expect(doc.root.get("a").?.boolean() == null);
    try testing.expect(doc.root.get("b").?.text() == null);
    try testing.expect(doc.root.get("c").?.count() == null);
    try testing.expectEqualStrings("", doc.root.get("c").?.text().?);
}

test "an empty file is an empty scalar" {
    var doc = try parsed("\n  \n# nothing here\n");
    defer doc.deinit();
    try testing.expectEqualStrings("", doc.root.text().?);
}

test "malformed input is refused rather than guessed at" {
    try testing.expectError(error.MalformedLine, parsed("a sentence, not a mapping"));
    try testing.expectError(error.BadIndentation, parsed("  width: 100"));
    try testing.expectError(error.BadIndentation, parsed("a: 1\n  b: 2"));
    try testing.expectError(error.BadIndentation, parsed("\ta: 1"));
    try testing.expectError(error.MalformedList, parsed("a: [ 1, 2"));
    try testing.expectError(error.MalformedList, parsed("a: [ 1, ,2 ]"));
}

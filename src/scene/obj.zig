//! A reader for Wavefront OBJ files: a list of points, and the triangles
//! drawn between them.
//!
//! Arranging triangles by hand stops being practical long before a model
//! becomes interesting, so models are built elsewhere and exported. The format
//! is line-oriented plain text, and the ray tracer needs only a handful of its
//! statements: `v` for a corner, `vn` for a normal, `f` for a face, and `g`
//! for the name of the part being described. Everything else is skipped, so a
//! file carrying materials or texture coordinates still loads.
//!
//! This is the one part of the tracer that allocates. A model's size is only
//! known once it has been read, and the shapes must then stay put, since a
//! group points at its children and every child points back: the `Model` owns
//! that storage and hands out a group that can be dropped into a world.

const std = @import("std");
const shape_mod = @import("shape.zig");
const tuple = @import("../math/tuple.zig");

/// A reader for OBJ files, over a float type.
pub fn Obj(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Object = shape_mod.Shape(T);

        pub const ParseError = std.mem.Allocator.Error || error{
            /// A statement the reader knows, written in a way it does not:
            /// too few numbers, one that will not parse, or a face naming a
            /// corner the file never gave.
            MalformedStatement,
        };

        /// The name the reader files triangles under until the model gives
        /// one of its own.
        pub const default_group_name = "";

        /// A parsed model: the points it was written from, the triangles
        /// drawn between them, and the groups those triangles belong to.
        ///
        /// The whole of it is one allocation's worth of slices owned here, so
        /// a model is freed in one call and never partly.
        pub const Model = struct {
            allocator: std.mem.Allocator,
            /// How many lines said something the reader does not understand.
            ignored: usize = 0,
            /// The corners, in the order the file gave them.
            vertices: []Point = &.{},
            /// The vertex normals, likewise.
            normals: []Point = &.{},
            /// Every triangle in the model, laid out so that the triangles of
            /// one group are neighbours.
            faces: []Object = &.{},
            /// One group per name the file used, each over its own run of
            /// `faces`.
            groups: []Object = &.{},
            /// What each of those groups is called, in the same order.
            names: [][]const u8 = &.{},
            /// A group over all of them: the model as one shape. Empty until
            /// every face has been read.
            root: Object = Object.group(&.{}),

            pub fn deinit(self: *Model) void {
                for (self.names) |name| self.allocator.free(name);
                self.allocator.free(self.names);
                self.allocator.free(self.groups);
                self.allocator.free(self.faces);
                self.allocator.free(self.normals);
                self.allocator.free(self.vertices);
                self.* = undefined;
            }

            /// Tie the model's groups to their triangles and to each other.
            ///
            /// Like any other tree of groups this can only be done where the
            /// tree will stay, and the root is part of the model itself — so
            /// a model that is moved, or returned by value, is linked at its
            /// destination rather than here.
            pub fn link(self: *Model) void {
                self.root.geometry.group.children = self.groups;
                self.root.link();
            }

            /// The corner the file's `index` names, counting from one as the
            /// format does, or from the end when negative. Null if the file
            /// never gave it.
            pub fn vertex(self: Model, index: isize) ?Point {
                return at(Point, self.vertices, index);
            }

            /// The vertex normal the file's `index` names, by the same rules.
            pub fn normal(self: Model, index: isize) ?Point {
                return at(Point, self.normals, index);
            }

            fn at(comptime E: type, items: []const E, index: isize) ?E {
                const i = if (index < 0)
                    @as(isize, @intCast(items.len)) + index
                else
                    index - 1;
                if (i < 0 or i >= items.len) return null;
                return items[@intCast(i)];
            }

            /// The group the model calls `name`, if it has one. The group
            /// holding everything the file wrote before naming anything is
            /// the one called `default_group_name`.
            pub fn group(self: *Model, name: []const u8) ?*Object {
                for (self.names, self.groups) |candidate, *g| {
                    if (std.mem.eql(u8, candidate, name)) return g;
                }
                return null;
            }

            /// The group holding everything written before the file named a
            /// part of its own. Always present, and often empty.
            pub fn defaultGroup(self: *Model) *Object {
                return self.group(default_group_name).?;
            }
        };

        /// Read `source` as an OBJ file. The caller owns the result and frees
        /// it with `deinit`, and must `link` it once it stands where it will
        /// stay.
        pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Model {
            var vertices: std.ArrayList(Point) = .empty;
            defer vertices.deinit(allocator);
            var normals: std.ArrayList(Point) = .empty;
            defer normals.deinit(allocator);

            // One bucket of triangles per named group, kept apart while
            // reading so that a name returned to later carries on where it
            // left off, and flattened into one array at the end.
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(allocator);
            var buckets: std.ArrayList(std.ArrayList(Object)) = .empty;
            defer {
                for (buckets.items) |*bucket| bucket.deinit(allocator);
                buckets.deinit(allocator);
            }

            var owned_names = false;
            errdefer if (owned_names) for (names.items) |name| allocator.free(name);

            try names.append(allocator, try allocator.dupe(u8, default_group_name));
            owned_names = true;
            try buckets.append(allocator, .empty);
            var current: usize = 0;

            var ignored: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;

                var words = std.mem.tokenizeAny(u8, line, " \t");
                const command = words.next().?;

                if (std.mem.eql(u8, command, "v")) {
                    try vertices.append(allocator, try readTriple(&words, .point));
                } else if (std.mem.eql(u8, command, "vn")) {
                    try normals.append(allocator, try readTriple(&words, .vector));
                } else if (std.mem.eql(u8, command, "f")) {
                    try readFace(
                        allocator,
                        &words,
                        vertices.items,
                        normals.items,
                        &buckets.items[current],
                    );
                } else if (std.mem.eql(u8, command, "g") or std.mem.eql(u8, command, "o")) {
                    const name = words.rest();
                    current = find(names.items, name) orelse blk: {
                        try names.append(allocator, try allocator.dupe(u8, name));
                        try buckets.append(allocator, .empty);
                        break :blk names.items.len - 1;
                    };
                } else {
                    ignored += 1;
                }
            }

            var model: Model = .{ .allocator = allocator, .ignored = ignored };
            errdefer model.deinit();

            var total: usize = 0;
            for (buckets.items) |bucket| total += bucket.items.len;
            model.faces = try allocator.alloc(Object, total);
            model.groups = try allocator.alloc(Object, buckets.items.len);

            var next: usize = 0;
            for (buckets.items, model.groups) |bucket, *g| {
                @memcpy(model.faces[next..][0..bucket.items.len], bucket.items);
                g.* = Object.group(model.faces[next..][0..bucket.items.len]);
                next += bucket.items.len;
            }
            model.root = Object.group(model.groups);

            model.names = try names.toOwnedSlice(allocator);
            owned_names = false;
            model.vertices = try vertices.toOwnedSlice(allocator);
            model.normals = try normals.toOwnedSlice(allocator);
            return model;
        }

        fn find(names: []const []const u8, name: []const u8) ?usize {
            for (names, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, name)) return i;
            }
            return null;
        }

        const Kind = enum { point, vector };

        /// The three numbers a `v` or `vn` statement carries. A fourth, which
        /// `v` may carry as a weight, is of no use here and is left unread.
        fn readTriple(words: *std.mem.TokenIterator(u8, .any), comptime kind: Kind) ParseError!Point {
            var xyz: [3]T = undefined;
            for (&xyz) |*component| {
                const word = words.next() orelse return error.MalformedStatement;
                component.* = std.fmt.parseFloat(T, word) catch return error.MalformedStatement;
            }
            return switch (kind) {
                .point => Point.point(xyz[0], xyz[1], xyz[2]),
                .vector => Point.vector(xyz[0], xyz[1], xyz[2]),
            };
        }

        /// One corner of a face: a vertex index, and optionally a texture and
        /// a normal index after it, as `v`, `v/vt`, `v//vn`, or `v/vt/vn`.
        /// Texture coordinates are read past and dropped.
        const Corner = struct {
            point: Point,
            normal: ?Point,

            fn parse(word: []const u8, vertices: []const Point, normals: []const Point) ParseError!Corner {
                var parts = std.mem.splitScalar(u8, word, '/');
                const point = Model.at(Point, vertices, try index(parts.next().?)) orelse
                    return error.MalformedStatement;

                _ = parts.next();
                const third = parts.next() orelse return .{ .point = point, .normal = null };
                if (third.len == 0) return .{ .point = point, .normal = null };

                const normal = Model.at(Point, normals, try index(third)) orelse
                    return error.MalformedStatement;
                return .{ .point = point, .normal = normal };
            }

            fn index(word: []const u8) ParseError!isize {
                return std.fmt.parseInt(isize, word, 10) catch error.MalformedStatement;
            }
        };

        /// The triangles of one face.
        ///
        /// A face may name more than three corners, and the tracer knows only
        /// triangles, so a polygon is fanned out from its first corner: one
        /// triangle per pair of neighbouring corners after it. This is right
        /// for convex faces, which is what exporters write.
        fn readFace(
            allocator: std.mem.Allocator,
            words: *std.mem.TokenIterator(u8, .any),
            vertices: []const Point,
            normals: []const Point,
            out: *std.ArrayList(Object),
        ) ParseError!void {
            // SAFETY: read only once `seen` says a corner has been stored.
            var fan: Corner = undefined;
            // SAFETY: read only once `seen` says a corner has been stored.
            var previous: Corner = undefined;
            var seen: usize = 0;

            while (words.next()) |word| : (seen += 1) {
                const corner = try Corner.parse(word, vertices, normals);
                switch (seen) {
                    0 => fan = corner,
                    1 => {},
                    else => try out.append(allocator, triangleOf(fan, previous, corner)),
                }
                previous = corner;
            }
            if (seen < 3) return error.MalformedStatement;
        }

        /// The triangle through three corners: smooth where the file gave a
        /// normal at every one of them, and flat otherwise, since a normal
        /// missing at one corner leaves nothing to blend towards.
        fn triangleOf(a: Corner, b: Corner, c: Corner) Object {
            if (a.normal) |na| if (b.normal) |nb| if (c.normal) |nc| {
                return Object.smoothTriangle(a.point, b.point, c.point, na, nb, nc);
            };
            return Object.triangle(a.point, b.point, c.point);
        }
    };
}

/// The reader at the precision the ray tracer uses.
pub const O = Obj(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = @import("ray.zig").R;
const Sh = shape_mod.Sh;

test "lines the reader does not understand are counted and skipped" {
    var model = try O.parse(testing.allocator,
        \\There was a young lady named Bright
        \\who traveled much faster than light.
        \\She set out one day
        \\in a relative way,
        \\and came back the previous night.
    );
    defer model.deinit();

    try testing.expectEqual(@as(usize, 5), model.ignored);
    try testing.expectEqual(@as(usize, 0), model.vertices.len);
    try testing.expectEqual(@as(usize, 0), model.faces.len);
}

test "blank lines and comments say nothing and are not counted against the file" {
    var model = try O.parse(testing.allocator,
        \\# a cube's worth of nothing
        \\
        \\   
        \\mtllib something.mtl
    );
    defer model.deinit();
    try testing.expectEqual(@as(usize, 1), model.ignored);
}

test "vertices are numbered from one, as the format writes them" {
    var model = try O.parse(testing.allocator,
        \\v -1 1 0
        \\v -1.0000 0.5000 0.0000
        \\v 1 0 0
        \\v 1 1 0
    );
    defer model.deinit();

    try testing.expect(model.vertex(1).?.eql(V.point(-1, 1, 0)));
    try testing.expect(model.vertex(2).?.eql(V.point(-1, 0.5, 0)));
    try testing.expect(model.vertex(3).?.eql(V.point(1, 0, 0)));
    try testing.expect(model.vertex(4).?.eql(V.point(1, 1, 0)));
    // Zero names nothing, and neither does one past the end.
    try testing.expect(model.vertex(0) == null);
    try testing.expect(model.vertex(5) == null);
    // Counting back from the end is how a file refers to what it just wrote.
    try testing.expect(model.vertex(-1).?.eql(V.point(1, 1, 0)));
}

test "faces become triangles between the corners they name" {
    var model = try O.parse(testing.allocator,
        \\v -1 1 0
        \\v -1 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\
        \\f 1 2 3
        \\f 1 3 4
    );
    defer model.deinit();
    model.link();

    const faces = model.defaultGroup().geometry.group.children;
    try testing.expectEqual(@as(usize, 2), faces.len);
    try expectCorners(faces[0], model.vertex(1).?, model.vertex(2).?, model.vertex(3).?);
    try expectCorners(faces[1], model.vertex(1).?, model.vertex(3).?, model.vertex(4).?);
}

test "a face of more than three corners is fanned out into triangles" {
    var model = try O.parse(testing.allocator,
        \\v -1 1 0
        \\v -1 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 2 0
        \\
        \\f 1 2 3 4 5
    );
    defer model.deinit();
    model.link();

    const faces = model.defaultGroup().geometry.group.children;
    try testing.expectEqual(@as(usize, 3), faces.len);
    try expectCorners(faces[0], model.vertex(1).?, model.vertex(2).?, model.vertex(3).?);
    try expectCorners(faces[1], model.vertex(1).?, model.vertex(3).?, model.vertex(4).?);
    try expectCorners(faces[2], model.vertex(1).?, model.vertex(4).?, model.vertex(5).?);
}

/// A file with two named parts, which several scenarios below read.
const two_groups =
    \\v -1 1 0
    \\v -1 0 0
    \\v 1 0 0
    \\v 1 1 0
    \\
    \\g FirstGroup
    \\f 1 2 3
    \\g SecondGroup
    \\f 1 3 4
;

test "triangles are filed under the part of the model being described" {
    var model = try O.parse(testing.allocator, two_groups);
    defer model.deinit();
    model.link();

    const first = model.group("FirstGroup") orelse return error.MissingGroup;
    const second = model.group("SecondGroup") orelse return error.MissingGroup;
    try expectCorners(
        first.geometry.group.children[0],
        model.vertex(1).?,
        model.vertex(2).?,
        model.vertex(3).?,
    );
    try expectCorners(
        second.geometry.group.children[0],
        model.vertex(1).?,
        model.vertex(3).?,
        model.vertex(4).?,
    );

    // Nothing was written before the first name, so the default part is empty.
    try testing.expect(model.defaultGroup().geometry.group.isEmpty());
    try testing.expect(model.group("ThirdGroup") == null);
}

test "a name returned to carries on where it left off" {
    var model = try O.parse(testing.allocator,
        \\v 0 1 0
        \\v -1 0 0
        \\v 1 0 0
        \\v 0 -1 0
        \\g fan
        \\f 1 2 3
        \\g other
        \\f 2 3 4
        \\g fan
        \\f 1 3 4
    );
    defer model.deinit();
    model.link();

    try testing.expectEqual(@as(usize, 3), model.groups.len);
    try testing.expectEqual(@as(usize, 2), model.group("fan").?.geometry.group.children.len);
    try testing.expectEqual(@as(usize, 1), model.group("other").?.geometry.group.children.len);
}

test "the whole model is one group of its parts" {
    var model = try O.parse(testing.allocator, two_groups);
    defer model.deinit();
    model.link();

    const parts = model.root.geometry.group;
    try testing.expect(parts.includes(model.group("FirstGroup").?));
    try testing.expect(parts.includes(model.group("SecondGroup").?));

    // Linking reaches all the way down: every triangle knows its part, and
    // every part knows the model.
    for (model.groups) |*part| {
        try testing.expectEqual(&model.root, part.parent);
        for (part.geometry.group.children) |*face| {
            try testing.expectEqual(part, face.parent);
        }
    }
}

test "a model can be met by a ray once it stands where it will stay" {
    var model = try O.parse(testing.allocator, two_groups);
    defer model.deinit();
    model.link();

    // The two triangles together cover the square from (-1, 0) to (1, 1).
    var buf: [8]Sh.Hit = undefined;
    const xs = try model.root.intersect(R.init(V.point(-0.5, 0.5, -2), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqual(@as(f64, 2), xs[0].t);

    // Beyond the square the ray meets nothing, and the boxes say so first.
    try testing.expect(model.root.nearestHit(R.init(V.point(3, 0.5, -2), V.vector(0, 0, 1))) == null);
}

test "faces carry vertex normals, and the triangles they make are smooth" {
    var model = try O.parse(testing.allocator,
        \\v 0 1 0
        \\v -1 0 0
        \\v 1 0 0
        \\
        \\vn -1 0 0
        \\vn 1 0 0
        \\vn 0 1 0
        \\
        \\f 1//3 2//1 3//2
        \\f 1/0/3 2/102/1 3/14/2
    );
    defer model.deinit();
    model.link();

    const faces = model.defaultGroup().geometry.group.children;
    try testing.expectEqual(@as(usize, 2), faces.len);
    for (faces) |face| {
        try expectCorners(face, model.vertex(1).?, model.vertex(2).?, model.vertex(3).?);
        const tri = face.geometry.triangle;
        try testing.expect(tri.isSmooth());
        try testing.expect(tri.normals.?[0].eql(model.normal(3).?));
        try testing.expect(tri.normals.?[1].eql(model.normal(1).?));
        try testing.expect(tri.normals.?[2].eql(model.normal(2).?));
    }
}

test "a face missing a normal at one corner has nothing to blend and stays flat" {
    var model = try O.parse(testing.allocator,
        \\v 0 1 0
        \\v -1 0 0
        \\v 1 0 0
        \\vn 0 0 1
        \\f 1//1 2//1 3
    );
    defer model.deinit();

    try testing.expect(!model.faces[0].geometry.triangle.isSmooth());
}

test "a statement the reader knows but cannot read is an error" {
    for ([_][]const u8{
        "v 1 2",
        "v 1 2 three",
        "vn 0 1",
        "f 1 2",
        "f 1 2 9",
        "f 1//9 2//1 3//1",
        "f x y z",
    }) |source| {
        try testing.expectError(error.MalformedStatement, O.parse(testing.allocator, source));
    }
}

test "an empty file is a model of nothing" {
    var model = try O.parse(testing.allocator, "");
    defer model.deinit();
    model.link();

    try testing.expectEqual(@as(usize, 1), model.groups.len);
    try testing.expectEqual(@as(usize, 0), model.faces.len);
    try testing.expect(model.root.geometry.group.bounds().isEmpty());
}

/// Check that a shape is a triangle with exactly these three corners.
fn expectCorners(face: Sh, p1: V, p2: V, p3: V) !void {
    const tri = face.geometry.triangle;
    try testing.expect(tri.p1.eql(p1));
    try testing.expect(tri.p2.eql(p2));
    try testing.expect(tri.p3.eql(p3));
}

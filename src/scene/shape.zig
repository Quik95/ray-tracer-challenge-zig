//! A shape: a geometry placed in the world, and what its surface is made of.
//!
//! Every geometry is written in its own coordinates — the unit sphere at the
//! origin, the xz plane — and a shape is what puts one of them somewhere.
//! Rays are carried into those coordinates by the inverse of the shape's
//! transformation, and normals carried back out of them, so a geometry never
//! has to know where it stands.
//!
//! Which geometry a shape wears is a tagged union rather than a table of
//! function pointers: the dispatch is a switch the compiler can see through,
//! and a whole scene stays usable at comptime.

const std = @import("std");
const intersection = @import("intersection.zig");
const bounds_mod = @import("bounds.zig");
const cone_mod = @import("cone.zig");
const csg_mod = @import("csg.zig");
const cube_mod = @import("cube.zig");
const cylinder_mod = @import("cylinder.zig");
const group_mod = @import("group.zig");
const material = @import("material.zig");
const matrix = @import("../math/matrix.zig");
const plane_mod = @import("plane.zig");
const ray_mod = @import("ray.zig");
const sphere_mod = @import("sphere.zig");
const triangle_mod = @import("triangle.zig");
const tuple = @import("../math/tuple.zig");

/// A shape in the world, over a float type.
pub fn Shape(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const M = matrix.Matrix(T, 4);
        pub const Ray = ray_mod.Ray(T);
        pub const Hit = intersection.Intersection(T, Self);
        pub const Mat = material.Material(T);
        pub const Bounds = bounds_mod.Bounds(T);
        pub const Scalar = T;

        /// The geometries the ray tracer knows how to meet.
        pub const Geometry = union(enum) {
            sphere: sphere_mod.Sphere(T),
            plane: plane_mod.Plane(T),
            cube: cube_mod.Cube(T),
            cylinder: cylinder_mod.Cylinder(T),
            cone: cone_mod.Cone(T),
            triangle: triangle_mod.Triangle(T),
            group: group_mod.Group(T),
            csg: csg_mod.Csg(T),
        };

        /// The most crossings any one surface among them can report. A group
        /// and a CSG shape report none of their own: they are met only through
        /// their children, and how many of those there are is the scene's
        /// business rather than the geometry's.
        pub const max_hits = blk: {
            var most: usize = 0;
            for (@typeInfo(Geometry).@"union".field_types) |Field| {
                most = @max(most, Field.max_hits);
            }
            break :blk most;
        };

        /// How many crossings of one CSG tree `nearestHit` will collect
        /// before giving up on it. Unlike every other shape, a CSG shape
        /// cannot say which crossing is nearest without seeing them all, and
        /// that list has to live somewhere; enough room for a tree of a
        /// reasonable size, on a stack that recursion is already using.
        pub const max_csg_hits = 64;

        pub const IntersectError = error{IntersectionOverflow};

        /// An optional output label; intersections identify their object by pointer.
        id: usize = 0,
        /// The group this shape belongs to, if any. It is what carries points
        /// the rest of the way into this shape's coordinates, and normals the
        /// rest of the way back out to the world.
        parent: ?*const Self = null,
        /// Object space to world space. The identity leaves the geometry
        /// exactly where it is written.
        transform: M = M.identity,
        /// What the surface is made of, and how it answers light.
        material: Mat = .{},
        /// Whether the shape stops light on its way to a surface. Almost
        /// everything does; turning it off is what lets a shape be seen
        /// without darkening what stands behind it — a pane of glass that
        /// would otherwise throw an opaque shadow, or a light's own fixture.
        casts_shadow: bool = true,
        /// The surface itself.
        geometry: Geometry = .{ .sphere = .{} },

        pub fn init(geometry: Geometry) Self {
            return .{
                .geometry = geometry,
            };
        }

        pub fn sphere() Self {
            return init(.{ .sphere = .{} });
        }

        pub fn plane() Self {
            return init(.{ .plane = .{} });
        }

        pub fn cube() Self {
            return init(.{ .cube = .{} });
        }

        pub fn cylinder() Self {
            return init(.{ .cylinder = .{} });
        }

        pub fn cone() Self {
            return init(.{ .cone = .{} });
        }

        /// A flat triangle with the given corners.
        pub fn triangle(p1: Point, p2: Point, p3: Point) Self {
            return init(.{ .triangle = .init(p1, p2, p3) });
        }

        /// A triangle that shades as though a curved surface ran through it,
        /// given the normal at each corner.
        pub fn smoothTriangle(
            p1: Point,
            p2: Point,
            p3: Point,
            n1: Point,
            n2: Point,
            n3: Point,
        ) Self {
            return init(.{ .triangle = .smooth(p1, p2, p3, n1, n2, n3) });
        }

        /// A group over `children`, which the caller owns and keeps alive for
        /// as long as the group is. The children learn which group holds them
        /// only once `link` is called.
        pub fn group(children: []Self) Self {
            return init(.{ .group = group_mod.Group(T).init(children) });
        }

        /// Two shapes combined by a set operation. `children` holds exactly
        /// two of them, left first, and is the caller's the same way a
        /// group's children are; `link` is what ties them to the result.
        pub fn csg(operation: csg_mod.Csg(T).Operation, children: []Self) Self {
            return init(.{ .csg = csg_mod.Csg(T).init(operation, children) });
        }

        /// Whether `other` is this shape or one of the shapes beneath it.
        /// Shapes are compared by identity, as everywhere else in the tracer.
        pub fn includes(self: *const Self, other: *const Self) bool {
            return switch (self.geometry) {
                .group => |g| for (g.children) |*child| {
                    if (child.includes(other)) break true;
                } else false,
                .csg => |c| for (c.children) |*child| {
                    if (child.includes(other)) break true;
                } else false,
                else => self == other,
            };
        }

        /// Tell every shape below this one which group it belongs to.
        ///
        /// A child cannot be handed its parent when the group is built, since
        /// the group has no address of its own yet, so linking is a pass over
        /// a tree that already stands where it will stay. Moving a linked tree
        /// leaves the links behind; link it again where it lands.
        ///
        /// It is also where a group's bounding box is worked out, for the same
        /// reason: the box is drawn around children that are already in place,
        /// and around the boxes of the groups beneath them, which linking has
        /// worked out first.
        pub fn link(self: *Self) void {
            switch (self.geometry) {
                .group => |*g| {
                    var box: Bounds = .empty;
                    for (g.children) |*child| {
                        child.parent = self;
                        child.link();
                        box = box.merge(child.parentBounds());
                    }
                    g.box = box;
                },
                .csg => |*c| {
                    for (c.children) |*child| {
                        child.parent = self;
                        child.link();
                    }
                    // Only now that both operands stand where they will stay
                    // is there a combined shape to draw a box around.
                    c.box = c.boundsOf();
                },
                else => {},
            }
        }

        /// Link a whole scene at once, so shapes built as a plain array of
        /// trees are ready in one call.
        pub fn linkAll(shapes: []Self) void {
            for (shapes) |*s| s.link();
        }

        /// The box holding this shape, in its own coordinates.
        pub fn bounds(self: *const Self) Bounds {
            return switch (self.geometry) {
                inline else => |geometry| geometry.bounds(),
            };
        }

        /// The box holding this shape in the coordinates of whatever holds
        /// it: the group it belongs to, or the world if none does.
        pub fn parentBounds(self: *const Self) Bounds {
            return self.bounds().transform(self.transform);
        }

        /// A sphere of glass: clear through, and bending light as glass
        /// does. Scenes want a marble often enough to name one.
        pub fn glassSphere() Self {
            var self = sphere();
            self.material.transparency = 1.0;
            self.material.refractive_index = 1.5;
            return self;
        }

        pub fn setTransform(self: *Self, m: M) void {
            self.transform = m;
        }

        pub fn setMaterial(self: *Self, m: Mat) void {
            self.material = m;
        }

        /// A world-space point in this shape's own coordinates, or null if a
        /// transformation on the way in has no inverse to carry it back along.
        ///
        /// The way in runs through every group the shape belongs to: each of
        /// them stands the shape somewhere, and the point has to come through
        /// all of them before this shape's own transformation applies.
        pub fn worldToObject(self: *const Self, world_point: Point) ?Point {
            var point = world_point;
            if (self.parent) |parent| {
                point = parent.worldToObject(point) orelse return null;
            }
            const inv = self.transform.inverse() catch return null;
            return inv.mulTuple(point);
        }

        /// A normal written in this shape's own coordinates, carried out to
        /// world space through every group the shape belongs to.
        ///
        /// Each step takes the inverse *transpose*: multiplying by the
        /// transform alone would tilt the normal off the surface wherever the
        /// shape is scaled unevenly.
        pub fn normalToWorld(self: *const Self, normal: Point) ?Point {
            const inv = self.transform.inverse() catch return null;
            var out = inv.transpose().mulTuple(normal);
            // A translation in the transform leaks into w through the
            // transpose; clearing it keeps the result a vector.
            out.v[@backingInt(tuple.Axis.w)] = 0;
            out = out.normalizeChecked() catch return null;

            if (self.parent) |parent| return parent.normalToWorld(out);
            return out;
        }

        /// A world-space ray in this shape's own coordinates, or null if the
        /// transformation has collapsed the shape to nothing and so has no
        /// inverse to carry the ray back along.
        pub fn localRay(self: *const Self, world_ray: Ray) ?Ray {
            const inv = self.transform.inverse() catch return null;
            return world_ray.transform(inv);
        }

        /// Where `world_ray` crosses this shape, written into `buf` and
        /// returned as the part of it that was filled.
        ///
        /// A surface reports at most `max_hits` crossings, but a group reports
        /// as many as everything beneath it together, so the room for them
        /// comes from the caller rather than from the geometry.
        pub fn intersect(self: *const Self, world_ray: Ray, buf: []Hit) IntersectError![]Hit {
            const local = self.localRay(world_ray) orelse return buf[0..0];

            var n: usize = 0;
            // Each geometry reports its own number of crossings, so the
            // gathering happens inside the switch, where that count is known.
            switch (self.geometry) {
                // A group has no surface of its own: the ray carries on into
                // the group's coordinates and meets its children there —
                // unless it misses the box drawn around them, in which case
                // there is nothing below to meet either.
                .group => |g| {
                    if (!g.box.intersects(local)) return buf[0..0];
                    for (g.children) |*child| {
                        n += (try child.intersect(local, buf[n..])).len;
                    }
                    const found = buf[0..n];
                    Hit.sort(found);
                    return found;
                },
                // A CSG shape is met through its operands too, and then the
                // operation says which of those crossings are on the combined
                // surface and which are buried inside it. Ordering them is
                // what makes the answer readable: the filter works out where
                // the ray is by counting the surfaces it has passed through.
                .csg => |c| {
                    if (c.isEmpty() or !c.box.intersects(local)) return buf[0..0];
                    for (c.children) |*child| {
                        n += (try child.intersect(local, buf[n..])).len;
                    }
                    const found = buf[0..n];
                    Hit.sort(found);
                    return c.filter(found);
                },
                inline else => |geometry| for (geometry.localIntersect(local).items()) |t| {
                    if (n == buf.len) return error.IntersectionOverflow;
                    buf[n] = Hit.init(t, self);
                    n += 1;
                },
            }
            return buf[0..n];
        }

        /// The nearest crossing of `world_ray` ahead of its origin, found
        /// without collecting the rest — and so without a buffer to collect
        /// them into.
        pub fn nearestHit(self: *const Self, world_ray: Ray) ?Hit {
            // A CSG shape is the one exception: whether a crossing is on the
            // combined surface at all depends on the crossings around it, so
            // there is no finding the nearest one without collecting them.
            // The scratch buffer is the cost of that, and a tree that fills
            // it is treated as missed rather than shaded from a partial list.
            if (self.geometry == .csg) {
                var scratch: [max_csg_hits]Hit = undefined;
                const xs = self.intersect(world_ray, &scratch) catch return null;
                return Hit.hit(xs);
            }

            const local = self.localRay(world_ray) orelse return null;

            var closest: ?Hit = null;
            switch (self.geometry) {
                .group => |g| {
                    if (!g.box.intersects(local)) return null;
                    for (g.children) |*child| {
                        const found = child.nearestHit(local) orelse continue;
                        if (closest == null or found.t < closest.?.t) closest = found;
                    }
                },
                // Answered above, before the ray was carried in at all.
                .csg => unreachable,
                inline else => |geometry| for (geometry.localIntersect(local).items()) |t| {
                    if (t < 0) continue;
                    if (closest == null or t < closest.?.t) closest = Hit.init(t, self);
                },
            }
            return closest;
        }

        /// The unit vector perpendicular to the surface at a world-space point
        /// on it, or null where there is no surface: a group, which is
        /// abstract, or a shape collapsed to nothing.
        pub fn normalAt(self: *const Self, world_point: Point) ?Point {
            const local_point = self.worldToObject(world_point) orelse return null;
            const local_normal = switch (self.geometry) {
                .group, .csg => return null,
                inline else => |geometry| geometry.localNormalAt(local_point),
            };
            return self.normalToWorld(local_normal);
        }
    };
}

/// The shape at the precision the ray tracer uses.
pub const Sh = Shape(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const R = ray_mod.R;
const Tf = @import("../math/transform.zig").Tf;
const V = tuple.Tup;

test "a shape has a default transformation and material" {
    const s = Sh.sphere();
    try testing.expect(s.transform.eql(Sh.M.identity));
    try testing.expect(s.material.eql(.{}));
}

test "a shape's transformation and material can be assigned" {
    var s = Sh.sphere();
    const t = Tf.translation(2, 3, 4);
    const m: Sh.Mat = .{ .ambient = 1 };
    s.setTransform(t);
    s.setMaterial(m);
    try testing.expect(s.transform.eql(t));
    try testing.expect(s.material.eql(m));
}

test "shape copies retain labels but intersections identify objects by pointer" {
    var a = Sh.sphere();
    try testing.expectEqual(@as(usize, 0), a.id);
    a.id = 42;
    var b = a;
    try testing.expectEqual(a.id, b.id);
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var buf_ax: [8]Sh.Hit = undefined;
    const ax = try a.intersect(r, &buf_ax);
    var buf_bx: [8]Sh.Hit = undefined;
    const bx = try b.intersect(r, &buf_bx);
    try testing.expectEqual(&a, ax[0].object);
    try testing.expectEqual(&b, bx[0].object);
    try testing.expect(ax[0].object != bx[0].object);
}

test "shape constructors work at comptime with default labels" {
    comptime {
        for (.{
            Sh.sphere(),
            Sh.plane(),
            Sh.cube(),
            Sh.cylinder(),
            Sh.cone(),
            Sh.glassSphere(),
            Sh.triangle(V.point(0, 1, 0), V.point(-1, 0, 0), V.point(1, 0, 0)),
        }) |s| {
            try testing.expectEqual(@as(usize, 0), s.id);
        }
    }
}

test "intersecting a scaled shape carries the ray into its coordinates" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var s = Sh.sphere();
    s.setTransform(Tf.scaling(2, 2, 2));
    const local = s.localRay(r).?;
    try testing.expect(local.origin.eql(V.point(0, 0, -2.5)));
    try testing.expect(local.direction.eql(V.vector(0, 0, 0.5)));
}

test "intersecting a translated shape carries the ray into its coordinates" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var s = Sh.sphere();
    s.setTransform(Tf.translation(5, 0, 0));
    const local = s.localRay(r).?;
    try testing.expect(local.origin.eql(V.point(-5, 0, -5)));
    try testing.expect(local.direction.eql(V.vector(0, 0, 1)));
}

test "the normal on a translated shape" {
    var s = Sh.sphere();
    s.setTransform(Tf.translation(0, 1, 0));
    const n = s.normalAt(V.point(0, 1.70711, -0.70711)).?;
    try testing.expect(n.eql(V.vector(0, 0.70711, -0.70711)));
}

test "the normal on a scaled and rotated shape" {
    var s = Sh.sphere();
    s.setTransform(Tf.scaling(1, 0.5, 1).mul(Tf.rotationZ(std.math.pi / 5.0)));
    const half_root_two = @sqrt(2.0) / 2.0;
    const n = s.normalAt(V.point(0, half_root_two, -half_root_two)).?;
    try testing.expect(n.eql(V.vector(0, 0.97014, -0.24254)));
}

test "intersecting a scaled sphere" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s: Sh = .{ .transform = Tf.scaling(2, 2, 2) };
    var buf: [8]Sh.Hit = undefined;
    const xs = try s.intersect(r, &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 3), xs[0].t);
    try testing.expectEqual(@as(f64, 7), xs[1].t);
}

test "intersecting a translated sphere" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s: Sh = .{ .transform = Tf.translation(5, 0, 0) };
    var buf: [8]Sh.Hit = undefined;
    try testing.expectEqual(@as(usize, 0), (try s.intersect(r, &buf)).len);
}

test "intersect sets the object on the intersection" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s = Sh.sphere();
    var buf: [8]Sh.Hit = undefined;
    const xs = try s.intersect(r, &buf);
    try testing.expectEqual(&s, xs[0].object);
    try testing.expectEqual(&s, xs[1].object);
}

test "a translated plane is met where it now lies" {
    const s: Sh = .{ .geometry = .{ .plane = .{} }, .transform = Tf.translation(0, -1, 0) };
    const r = R.init(V.point(0, 1, 0), V.vector(0, -1, 0));
    var buf: [8]Sh.Hit = undefined;
    const xs = try s.intersect(r, &buf);
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqual(@as(f64, 2), xs[0].t);
    try testing.expect(s.normalAt(V.point(5, -1, 5)).?.eql(V.vector(0, 1, 0)));
}

test "a collapsed shape can be neither intersected nor asked for a normal" {
    // A zero scale has no inverse: there is nothing left to meet.
    const s: Sh = .{ .transform = Tf.scaling(0, 0, 0) };
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var buf: [8]Sh.Hit = undefined;
    try testing.expectEqual(@as(usize, 0), (try s.intersect(r, &buf)).len);
    try testing.expect(s.normalAt(V.point(1, 0, 0)) == null);
}

test "shapes are intersected and shaded at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const s: Sh = .{ .transform = Tf.scaling(2, 2, 2) };
        const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
        var buf: [8]Sh.Hit = undefined;
        const xs = try s.intersect(r, &buf);
        try testing.expect(xs[0].t == 3);
        try testing.expect(s.normalAt(V.point(0, 2, 0)).?.eql(V.vector(0, 1, 0)));
    }
}

test "a glass sphere is clear and bends light" {
    const s = Sh.glassSphere();
    try testing.expect(s.transform.eql(Sh.M.identity));
    try testing.expectEqual(@as(f64, 1.0), s.material.transparency);
    try testing.expectEqual(@as(f64, 1.5), s.material.refractive_index);
}

test "a transformed cube is met where it now stands" {
    // Widened and pushed aside, so a ray down the x axis enters its near face.
    const s: Sh = .{
        .geometry = .{ .cube = .{} },
        .transform = Tf.chain().scale(2, 1, 1).translate(4, 0, 0).m,
    };
    var buf: [8]Sh.Hit = undefined;
    const xs = try s.intersect(R.init(V.point(-5, 0, 0), V.vector(1, 0, 0)), &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 7), xs[0].t);
    try testing.expectEqual(@as(f64, 11), xs[1].t);
    try testing.expect(s.normalAt(V.point(2, 0, 0)).?.eql(V.vector(-1, 0, 0)));
}

test "a transformed cylinder is met where it now stands" {
    // A capped length of pipe, laid along the x axis and pushed aside.
    var s: Sh = .{
        .geometry = .{ .cylinder = .{ .minimum = -1, .maximum = 1, .closed = true } },
        .transform = Tf.chain().rotateZ(std.math.pi / 2.0).translate(3, 0, 0).m,
    };
    s.id = 1;
    var buf: [8]Sh.Hit = undefined;
    const xs = try s.intersect(R.init(V.point(0, 0, 0), V.vector(1, 0, 0)), &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectApproxEqAbs(@as(f64, 2), xs[0].t, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), xs[1].t, 1e-9);
    // The cap faces back down the x axis, towards where the ray came from.
    try testing.expect(s.normalAt(V.point(2, 0, 0)).?.eql(V.vector(-1, 0, 0)));
}

test "a point comes into a nested shape's coordinates through its groups" {
    var inner = [_]Sh{.{ .transform = Tf.translation(5, 0, 0) }};
    var middle = [_]Sh{Sh.group(&inner)};
    middle[0].setTransform(Tf.scaling(2, 2, 2));
    var outer = Sh.group(&middle);
    outer.setTransform(Tf.rotationY(std.math.pi / 2.0));
    outer.link();

    const p = inner[0].worldToObject(V.point(-2, 0, -10)).?;
    try testing.expect(p.eql(V.point(0, 0, -1)));
}

test "a normal goes out of a nested shape's coordinates through its groups" {
    var inner = [_]Sh{.{ .transform = Tf.translation(5, 0, 0) }};
    var middle = [_]Sh{Sh.group(&inner)};
    middle[0].setTransform(Tf.scaling(1, 2, 3));
    var outer = Sh.group(&middle);
    outer.setTransform(Tf.rotationY(std.math.pi / 2.0));
    outer.link();

    const third = @sqrt(3.0) / 3.0;
    const n = inner[0].normalToWorld(V.vector(third, third, third)).?;
    try expectVector(V.vector(0.2857, 0.4286, -0.8571), n);
}

test "the normal on a shape inside a group" {
    var inner = [_]Sh{.{ .transform = Tf.translation(5, 0, 0) }};
    var middle = [_]Sh{Sh.group(&inner)};
    middle[0].setTransform(Tf.scaling(1, 2, 3));
    var outer = Sh.group(&middle);
    outer.setTransform(Tf.rotationY(std.math.pi / 2.0));
    outer.link();

    const n = inner[0].normalAt(V.point(1.7321, 1.1547, -5.5774)).?;
    try expectVector(V.vector(0.2857, 0.4286, -0.8571), n);
}

test "linking a scene reaches every group in it" {
    var leaves = [_]Sh{ Sh.sphere(), Sh.cube() };
    var branch = [_]Sh{Sh.group(leaves[0..1])};
    var scene = [_]Sh{ Sh.group(&branch), Sh.plane() };
    Sh.linkAll(&scene);

    try testing.expectEqual(&scene[0], branch[0].parent);
    try testing.expectEqual(&branch[0], leaves[0].parent);
    // Nothing holds the plane or the cube, so neither gained a parent.
    try testing.expect(scene[1].parent == null);
    try testing.expect(leaves[1].parent == null);
}

/// Compare two tuples to the four decimals the book's expected values carry,
/// which is coarser than the tracer's own tolerance.
fn expectVector(expected: V, actual: V) !void {
    inline for (0..4) |i| {
        try testing.expectApproxEqAbs(expected.v[i], actual.v[i], 1e-4);
    }
}

test "a transformed triangle is met where it now stands" {
    var s = Sh.triangle(V.point(0, 1, 0), V.point(-1, 0, 0), V.point(1, 0, 0));
    s.setTransform(Tf.translation(0, 0, 4));

    var buf: [8]Sh.Hit = undefined;
    const xs = try s.intersect(R.init(V.point(0, 0.5, 0), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqual(@as(f64, 4), xs[0].t);
    // The face looks back down the z axis, towards where the ray came from.
    try testing.expect(s.normalAt(V.point(0, 0.5, 4)).?.eql(V.vector(0, 0, -1)));
}

test "a smooth triangle in a group is shaded by its corner normals" {
    var children = [_]Sh{Sh.smoothTriangle(
        V.point(0, 1, 0),
        V.point(-1, 0, 0),
        V.point(1, 0, 0),
        V.vector(0, 1, 0),
        V.vector(-1, 0, 0),
        V.vector(1, 0, 0),
    )};
    var g = Sh.group(&children);
    g.setTransform(Tf.translation(0, 0, 5));
    g.link();

    var buf: [8]Sh.Hit = undefined;
    const xs = try g.intersect(R.init(V.point(-0.2, 0.3, 0), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqual(@as(f64, 5), xs[0].t);

    // The blend follows the shape out of the group and into the world.
    const n = xs[0].object.normalAt(V.point(-0.2, 0.3, 5)).?;
    try expectVector(V.vector(-0.5547, 0.83205, 0), n);
}

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
const material = @import("material.zig");
const matrix = @import("../math/matrix.zig");
const plane_mod = @import("plane.zig");
const ray_mod = @import("ray.zig");
const sphere_mod = @import("sphere.zig");
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
        pub const Scalar = T;

        /// The geometries the ray tracer knows how to meet.
        pub const Geometry = union(enum) {
            sphere: sphere_mod.Sphere(T),
            plane: plane_mod.Plane(T),
        };

        /// The most crossings any of them can report.
        pub const max_hits = blk: {
            var most: usize = 0;
            for (@typeInfo(Geometry).@"union".fields) |field| {
                most = @max(most, field.type.max_hits);
            }
            break :blk most;
        };

        /// Where a ray meets this shape, nearest first.
        pub const Hits = struct {
            buf: [max_hits]Hit = undefined,
            len: usize = 0,

            pub const none: Hits = .{};

            pub fn items(self: *const Hits) []const Hit {
                return self.buf[0..self.len];
            }
        };

        /// Distinguishes one shape from another in output; intersections
        /// identify their object by pointer.
        id: usize = 0,
        /// Object space to world space. The identity leaves the geometry
        /// exactly where it is written.
        transform: M = M.identity,
        /// What the surface is made of, and how it answers light.
        material: Mat = .{},
        /// The surface itself.
        geometry: Geometry = .{ .sphere = .{} },

        var next_id: usize = 0;

        /// A shape with an id no other shape shares.
        pub fn init(geometry: Geometry) Self {
            return .{
                .id = @atomicRmw(usize, &next_id, .Add, 1, .monotonic),
                .geometry = geometry,
            };
        }

        pub fn sphere() Self {
            return init(.{ .sphere = .{} });
        }

        pub fn plane() Self {
            return init(.{ .plane = .{} });
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

        /// A world-space point in this shape's own coordinates, or null if
        /// the transformation has no inverse to carry the point back along.
        pub fn localPoint(self: *const Self, world_point: Point) ?Point {
            const inv = self.transform.inverse() catch return null;
            return inv.mulTuple(world_point);
        }

        /// A world-space ray in this shape's own coordinates, or null if the
        /// transformation has collapsed the shape to nothing and so has no
        /// inverse to carry the ray back along.
        pub fn localRay(self: *const Self, world_ray: Ray) ?Ray {
            const inv = self.transform.inverse() catch return null;
            return world_ray.transform(inv);
        }

        /// Where `world_ray` crosses this shape.
        pub fn intersect(self: *const Self, world_ray: Ray) Hits {
            const local = self.localRay(world_ray) orelse return .none;

            var hits: Hits = .{};
            // Each geometry reports its own number of crossings, so the
            // gathering happens inside the switch, where that count is known.
            switch (self.geometry) {
                inline else => |g| for (g.localIntersect(local).items()) |t| {
                    hits.buf[hits.len] = Hit.init(t, self);
                    hits.len += 1;
                },
            }
            return hits;
        }

        /// The unit vector perpendicular to the surface at a world-space
        /// point on it, or null if the shape has been collapsed to nothing.
        ///
        /// Carrying the geometry's own normal back to world space takes the
        /// inverse *transpose*: multiplying by the transform alone would tilt
        /// the normal off the surface wherever the shape is scaled unevenly.
        pub fn normalAt(self: *const Self, world_point: Point) ?Point {
            const inv = self.transform.inverse() catch return null;
            const local_point = inv.mulTuple(world_point);
            const local_normal = switch (self.geometry) {
                inline else => |g| g.localNormalAt(local_point),
            };

            var world_normal = inv.transpose().mulTuple(local_normal);
            // A translation in the transform leaks into w through the
            // transpose; clearing it keeps the result a vector.
            world_normal.v[@intFromEnum(tuple.Axis.w)] = 0;
            return world_normal.normalize();
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

test "shapes are told apart from one another" {
    const a = Sh.sphere();
    const b = Sh.plane();
    try testing.expect(a.id != b.id);
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
    const xs = s.intersect(r);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 3), xs.items()[0].t);
    try testing.expectEqual(@as(f64, 7), xs.items()[1].t);
}

test "intersecting a translated sphere" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s: Sh = .{ .transform = Tf.translation(5, 0, 0) };
    try testing.expectEqual(@as(usize, 0), s.intersect(r).len);
}

test "intersect sets the object on the intersection" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s = Sh.sphere();
    const xs = s.intersect(r);
    try testing.expectEqual(&s, xs.items()[0].object);
    try testing.expectEqual(&s, xs.items()[1].object);
}

test "a translated plane is met where it now lies" {
    const s: Sh = .{ .geometry = .{ .plane = .{} }, .transform = Tf.translation(0, -1, 0) };
    const r = R.init(V.point(0, 1, 0), V.vector(0, -1, 0));
    const xs = s.intersect(r);
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqual(@as(f64, 2), xs.items()[0].t);
    try testing.expect(s.normalAt(V.point(5, -1, 5)).?.eql(V.vector(0, 1, 0)));
}

test "a collapsed shape can be neither intersected nor asked for a normal" {
    // A zero scale has no inverse: there is nothing left to meet.
    const s: Sh = .{ .transform = Tf.scaling(0, 0, 0) };
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    try testing.expectEqual(@as(usize, 0), s.intersect(r).len);
    try testing.expect(s.normalAt(V.point(1, 0, 0)) == null);
}

test "shapes are intersected and shaded at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const s: Sh = .{ .transform = Tf.scaling(2, 2, 2) };
        const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
        const xs = s.intersect(r);
        try testing.expect(xs.items()[0].t == 3);
        try testing.expect(s.normalAt(V.point(0, 2, 0)).?.eql(V.vector(0, 1, 0)));
    }
}

test "a glass sphere is clear and bends light" {
    const s = Sh.glassSphere();
    try testing.expect(s.transform.eql(Sh.M.identity));
    try testing.expectEqual(@as(f64, 1.0), s.material.transparency);
    try testing.expectEqual(@as(f64, 1.5), s.material.refractive_index);
}

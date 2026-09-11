//! Spheres: the first shape the ray tracer can see.
//!
//! Every sphere is a unit sphere at the origin. Size, position, and shape
//! come from its transformation, and a ray is intersected by moving the ray
//! into the sphere's own coordinates with the inverse of that transformation
//! rather than by moving the sphere.

const std = @import("std");
const intersection = @import("intersection.zig");
const matrix = @import("../math/matrix.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// A sphere, over a float type.
pub fn Sphere(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const M = matrix.Matrix(T, 4);
        pub const Ray = ray.Ray(T);
        pub const Hit = intersection.Intersection(T, Self);
        pub const Scalar = T;

        /// Distinguishes one sphere from another in output; intersections
        /// identify their object by pointer.
        id: usize = 0,
        /// Object space to world space. The identity leaves a unit sphere at
        /// the origin.
        transform: M = M.identity,

        var next_id: usize = 0;

        /// A unit sphere at the origin, with an id no other sphere shares.
        pub fn init() Self {
            return .{ .id = @atomicRmw(usize, &next_id, .Add, 1, .monotonic) };
        }

        pub fn setTransform(self: *Self, m: M) void {
            self.transform = m;
        }

        /// Where the ray crosses the sphere, nearest first, or null if it
        /// misses. A ray that grazes the sphere reports the same point twice,
        /// so a caller counting crossings sees the tangent as two.
        pub fn intersect(self: *const Self, world_ray: Ray) ?[2]Hit {
            // Moving the ray into object space is what lets the maths below
            // assume a unit sphere at the origin.
            const inv = self.transform.inverse() catch return null;
            const r = world_ray.transform(inv);

            const sphere_to_ray = r.origin.sub(Point.point(0, 0, 0));
            const a = r.direction.dot(r.direction);
            const b = 2 * r.direction.dot(sphere_to_ray);
            const c = sphere_to_ray.dot(sphere_to_ray) - 1;

            // Negative under the root means the ray passes the sphere by.
            const discriminant = b * b - 4 * a * c;
            if (discriminant < 0) return null;

            const root = @sqrt(discriminant);
            return .{
                Hit.init((-b - root) / (2 * a), self),
                Hit.init((-b + root) / (2 * a), self),
            };
        }
    };
}

/// The sphere at the precision the ray tracer uses.
pub const S = Sphere(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;
const Tf = @import("../math/transform.zig").Tf;

test "a ray intersects a sphere at two points" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s = S.init();
    const xs = s.intersect(r).?;
    try testing.expectEqual(@as(f64, 4), xs[0].t);
    try testing.expectEqual(@as(f64, 6), xs[1].t);
}

test "a ray intersects a sphere at a tangent" {
    const r = R.init(V.point(0, 1, -5), V.vector(0, 0, 1));
    const s = S.init();
    const xs = s.intersect(r).?;
    try testing.expectEqual(@as(f64, 5), xs[0].t);
    try testing.expectEqual(@as(f64, 5), xs[1].t);
}

test "a ray misses a sphere" {
    const r = R.init(V.point(0, 2, -5), V.vector(0, 0, 1));
    const s = S.init();
    try testing.expect(s.intersect(r) == null);
}

test "a ray originates inside a sphere" {
    const r = R.init(V.point(0, 0, 0), V.vector(0, 0, 1));
    const s = S.init();
    const xs = s.intersect(r).?;
    try testing.expectEqual(@as(f64, -1), xs[0].t);
    try testing.expectEqual(@as(f64, 1), xs[1].t);
}

test "a sphere is behind a ray" {
    const r = R.init(V.point(0, 0, 5), V.vector(0, 0, 1));
    const s = S.init();
    const xs = s.intersect(r).?;
    try testing.expectEqual(@as(f64, -6), xs[0].t);
    try testing.expectEqual(@as(f64, -4), xs[1].t);
}

test "intersect sets the object on the intersection" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s = S.init();
    const xs = s.intersect(r).?;
    try testing.expectEqual(&s, xs[0].object);
    try testing.expectEqual(&s, xs[1].object);
}

test "spheres are told apart from one another" {
    const a = S.init();
    const b = S.init();
    try testing.expect(a.id != b.id);
}

test "a sphere's default transformation" {
    const s = S.init();
    try testing.expect(s.transform.eql(S.M.identity));
}

test "changing a sphere's transformation" {
    var s = S.init();
    const t = Tf.translation(2, 3, 4);
    s.setTransform(t);
    try testing.expect(s.transform.eql(t));
}

test "intersecting a scaled sphere with a ray" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var s = S.init();
    s.setTransform(Tf.scaling(2, 2, 2));
    const xs = s.intersect(r).?;
    try testing.expectEqual(@as(f64, 3), xs[0].t);
    try testing.expectEqual(@as(f64, 7), xs[1].t);
}

test "intersecting a translated sphere with a ray" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var s = S.init();
    s.setTransform(Tf.translation(5, 0, 0));
    try testing.expect(s.intersect(r) == null);
}

test "a sphere flattened along y is missed above and below" {
    const s: S = .{ .transform = Tf.scaling(1, 0.5, 1) };
    const through = R.init(V.point(0, 0.4, -5), V.vector(0, 0, 1));
    const over = R.init(V.point(0, 0.6, -5), V.vector(0, 0, 1));
    try testing.expect(s.intersect(through) != null);
    try testing.expect(s.intersect(over) == null);
}

test "a collapsed sphere cannot be intersected" {
    // A zero scale has no inverse: the sphere has no interior left to hit.
    const s: S = .{ .transform = Tf.scaling(0, 0, 0) };
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    try testing.expect(s.intersect(r) == null);
}

test "spheres can be intersected at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const s: S = .{ .transform = Tf.scaling(2, 2, 2) };
        const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
        const xs = s.intersect(r).?;
        try testing.expect(tuple.feq(f64, xs[0].t, 3));
        try testing.expect(S.Hit.hit(&xs).?.t == 3);
    }
}

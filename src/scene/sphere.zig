//! The unit sphere: the first shape the ray tracer could see.
//!
//! This is the bare geometry, a sphere of radius one centred on the origin.
//! Size, position, and shape come from the transformation of the shape that
//! wears it, which is also what carries a ray into these coordinates.

const std = @import("std");
const intersection = @import("intersection.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// A unit sphere at the origin, over a float type.
pub fn Sphere(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Ray = ray.Ray(T);
        pub const Scalar = T;

        /// A ray can enter a sphere and leave it, and no more.
        pub const max_hits = 2;
        pub const Roots = intersection.Roots(T, max_hits);

        /// Where the ray crosses the sphere, nearest first. A ray that grazes
        /// it reports the same point twice, so a caller counting crossings
        /// sees the tangent as two.
        pub fn localIntersect(_: Self, r: Ray) Roots {
            const centre_to_ray = r.origin.sub(Point.point(0, 0, 0));
            const a = r.direction.dot(r.direction);
            const b = 2 * r.direction.dot(centre_to_ray);
            const c = centre_to_ray.dot(centre_to_ray) - 1;

            // Negative under the root means the ray passes the sphere by.
            const discriminant = b * b - 4 * a * c;
            if (discriminant < 0) return .none;

            const root = @sqrt(discriminant);
            return .of(.{ (-b - root) / (2 * a), (-b + root) / (2 * a) });
        }

        /// The normal at a point on the surface is the arrow from the centre
        /// out to it, which in these coordinates is the point itself.
        pub fn localNormalAt(_: Self, point: Point) Point {
            return point.sub(Point.point(0, 0, 0));
        }
    };
}

/// The sphere at the precision the ray tracer uses.
pub const S = Sphere(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;

test "a ray intersects a sphere at two points" {
    const xs = S.localIntersect(.{}, R.init(V.point(0, 0, -5), V.vector(0, 0, 1)));
    try testing.expectEqualSlices(f64, &.{ 4, 6 }, xs.items());
}

test "a ray intersects a sphere at a tangent" {
    const xs = S.localIntersect(.{}, R.init(V.point(0, 1, -5), V.vector(0, 0, 1)));
    try testing.expectEqualSlices(f64, &.{ 5, 5 }, xs.items());
}

test "a ray misses a sphere" {
    const xs = S.localIntersect(.{}, R.init(V.point(0, 2, -5), V.vector(0, 0, 1)));
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "a ray originates inside a sphere" {
    const xs = S.localIntersect(.{}, R.init(V.point(0, 0, 0), V.vector(0, 0, 1)));
    try testing.expectEqualSlices(f64, &.{ -1, 1 }, xs.items());
}

test "a sphere is behind a ray" {
    const xs = S.localIntersect(.{}, R.init(V.point(0, 0, 5), V.vector(0, 0, 1)));
    try testing.expectEqualSlices(f64, &.{ -6, -4 }, xs.items());
}

test "the normal on a sphere at a point on each axis" {
    const s: S = .{};
    try testing.expect(s.localNormalAt(V.point(1, 0, 0)).eql(V.vector(1, 0, 0)));
    try testing.expect(s.localNormalAt(V.point(0, 1, 0)).eql(V.vector(0, 1, 0)));
    try testing.expect(s.localNormalAt(V.point(0, 0, 1)).eql(V.vector(0, 0, 1)));
}

test "the normal at a nonaxial point" {
    const k = @sqrt(3.0) / 3.0;
    const n = S.localNormalAt(.{}, V.point(k, k, k));
    try testing.expect(n.eql(V.vector(k, k, k)));
}

test "the normal is a normalized vector" {
    const k = @sqrt(3.0) / 3.0;
    const n = S.localNormalAt(.{}, V.point(k, k, k));
    try testing.expect(n.eql(n.normalize()));
}

test "spheres are intersected at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const xs = S.localIntersect(.{}, R.init(V.point(0, 0, -5), V.vector(0, 0, 1)));
        try testing.expect(xs.items()[0] == 4);
        try testing.expect(S.localNormalAt(.{}, V.point(0, 1, 0)).eql(V.vector(0, 1, 0)));
    }
}

//! The plane: perfectly flat, and infinite in x and z.
//!
//! Like the sphere this is bare geometry — the xz plane through the origin.
//! A floor, a wall, or a ceiling is that plane under a transformation.

const std = @import("std");
const intersection = @import("intersection.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// The xz plane through the origin, over a float type.
pub fn Plane(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Ray = ray.Ray(T);
        pub const Scalar = T;

        /// A flat surface is crossed once or not at all.
        pub const max_hits = 1;
        pub const Roots = intersection.Roots(T, max_hits);

        /// Where the ray crosses the plane. A ray with no slope in y runs
        /// parallel to the surface and never meets it — including the ray
        /// lying in the plane itself, which meets it everywhere, but which
        /// sees an infinitely thin surface edge-on and so sees nothing.
        pub fn localIntersect(_: Self, r: Ray) Roots {
            const slope = r.direction.y();
            if (@abs(slope) < tuple.epsilonOf(T)) return .none;
            return .of(.{-r.origin.y() / slope});
        }

        /// A plane has no curvature, so the same normal serves everywhere.
        pub fn localNormalAt(_: Self, _: Point) Point {
            return Point.vector(0, 1, 0);
        }
    };
}

/// The plane at the precision the ray tracer uses.
pub const P = Plane(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;

test "the normal of a plane is constant everywhere" {
    const p: P = .{};
    try testing.expect(p.localNormalAt(V.point(0, 0, 0)).eql(V.vector(0, 1, 0)));
    try testing.expect(p.localNormalAt(V.point(10, 0, -10)).eql(V.vector(0, 1, 0)));
    try testing.expect(p.localNormalAt(V.point(-5, 0, 150)).eql(V.vector(0, 1, 0)));
}

test "a ray parallel to the plane misses it" {
    const xs = P.localIntersect(.{}, R.init(V.point(0, 10, 0), V.vector(0, 0, 1)));
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "a ray lying in the plane sees it edge-on and misses" {
    const xs = P.localIntersect(.{}, R.init(V.point(0, 0, 0), V.vector(0, 0, 1)));
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "a ray intersects the plane from above" {
    const xs = P.localIntersect(.{}, R.init(V.point(0, 1, 0), V.vector(0, -1, 0)));
    try testing.expectEqualSlices(f64, &.{1}, xs.items());
}

test "a ray intersects the plane from below" {
    const xs = P.localIntersect(.{}, R.init(V.point(0, -1, 0), V.vector(0, 1, 0)));
    try testing.expectEqualSlices(f64, &.{1}, xs.items());
}

test "planes are intersected at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const xs = P.localIntersect(.{}, R.init(V.point(0, 1, 0), V.vector(0, -1, 0)));
        try testing.expect(xs.items()[0] == 1);
        try testing.expect(P.localNormalAt(.{}, V.point(3, 0, 4)).eql(V.vector(0, 1, 0)));
    }
}

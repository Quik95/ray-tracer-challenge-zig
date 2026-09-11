//! The cube: an axis-aligned box, two units on a side, centered at the origin.
//!
//! Keeping it axis-aligned is what makes the math cheap. Every other box —
//! tilted, stretched, moved — is this one under a transformation, and the
//! shape wearing the geometry is what applies it.

const std = @import("std");
const intersection = @import("intersection.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// The box from (-1, -1, -1) to (1, 1, 1), over a float type.
pub fn Cube(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Ray = ray.Ray(T);
        pub const Scalar = T;

        /// A convex solid: in one side and out the other.
        pub const max_hits = 2;
        pub const Roots = intersection.Roots(T, max_hits);

        /// The three components that carry position; `w` says point or
        /// vector and has no part in the geometry.
        const Axes = @Vector(3, T);

        inline fn axes(t: Point) Axes {
            return @shuffle(T, t.v, undefined, [3]i32{ 0, 1, 2 });
        }

        /// Where the ray crosses the box.
        ///
        /// The box is the region between three pairs of parallel planes, one
        /// pair per axis. The ray is inside the box only where it is inside
        /// all three slabs at once, so the entry is the last of the three
        /// entries and the exit the first of the three exits; an entry later
        /// than the exit means the ray passed the box by.
        ///
        /// A direction of zero along an axis sends that slab's bounds to
        /// infinity with the sign of the numerator, which is exactly right: a
        /// ray running parallel to a pair of planes is inside that slab for
        /// its whole length, or outside it for the whole length. Where the
        /// ray also lies exactly in one of the planes the quotient is NaN,
        /// and `@min`/`@max` take the other bound — both ends collapse to the
        /// same infinity and the box is missed, the same answer a plane gives
        /// a ray that meets it edge-on.
        pub fn localIntersect(_: Self, r: Ray) Roots {
            const origin = axes(r.origin);
            const direction = axes(r.direction);

            const near = (@as(Axes, @splat(-1)) - origin) / direction;
            const far = (@as(Axes, @splat(1)) - origin) / direction;

            // Which plane of a pair is met first depends on which way the ray
            // runs along that axis.
            const entry = @reduce(.Max, @min(near, far));
            const exit = @reduce(.Min, @max(near, far));

            if (entry > exit) return .none;
            return .of(.{ entry, exit });
        }

        /// The face a point lies on is the one its largest component names:
        /// on the +x face x is 1 and nothing else can exceed it, and so on
        /// around the box. Comparing magnitudes rather than testing for 1
        /// exactly keeps rounding in the point from leaving it on no face at
        /// all. A corner belongs to whichever face is checked first.
        pub fn localNormalAt(_: Self, p: Point) Point {
            const v = axes(p);
            const magnitude = @abs(v);
            const largest = @reduce(.Max, magnitude);

            if (largest == magnitude[0]) return Point.vector(v[0], 0, 0);
            if (largest == magnitude[1]) return Point.vector(0, v[1], 0);
            return Point.vector(0, 0, v[2]);
        }
    };
}

/// The cube at the precision the ray tracer uses.
pub const C = Cube(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;

test "a ray intersects the cube from every side, and from within" {
    const cases = [_]struct { origin: V, direction: V, t0: f64, t1: f64 }{
        .{ .origin = V.point(5, 0.5, 0), .direction = V.vector(-1, 0, 0), .t0 = 4, .t1 = 6 },
        .{ .origin = V.point(-5, 0.5, 0), .direction = V.vector(1, 0, 0), .t0 = 4, .t1 = 6 },
        .{ .origin = V.point(0.5, 5, 0), .direction = V.vector(0, -1, 0), .t0 = 4, .t1 = 6 },
        .{ .origin = V.point(0.5, -5, 0), .direction = V.vector(0, 1, 0), .t0 = 4, .t1 = 6 },
        .{ .origin = V.point(0.5, 0, 5), .direction = V.vector(0, 0, -1), .t0 = 4, .t1 = 6 },
        .{ .origin = V.point(0.5, 0, -5), .direction = V.vector(0, 0, 1), .t0 = 4, .t1 = 6 },
        .{ .origin = V.point(0, 0.5, 0), .direction = V.vector(0, 0, 1), .t0 = -1, .t1 = 1 },
    };

    for (cases) |case| {
        const xs = C.localIntersect(.{}, R.init(case.origin, case.direction));
        try testing.expectEqualSlices(f64, &.{ case.t0, case.t1 }, xs.items());
    }
}

test "a ray pointed away from the cube misses it" {
    const cases = [_]struct { origin: V, direction: V }{
        .{ .origin = V.point(-2, 0, 0), .direction = V.vector(0.2673, 0.5345, 0.8018) },
        .{ .origin = V.point(0, -2, 0), .direction = V.vector(0.8018, 0.2673, 0.5345) },
        .{ .origin = V.point(0, 0, -2), .direction = V.vector(0.5345, 0.8018, 0.2673) },
        .{ .origin = V.point(2, 0, 2), .direction = V.vector(0, 0, -1) },
        .{ .origin = V.point(0, 2, 2), .direction = V.vector(0, -1, 0) },
        .{ .origin = V.point(2, 2, 0), .direction = V.vector(-1, 0, 0) },
    };

    for (cases) |case| {
        const xs = C.localIntersect(.{}, R.init(case.origin, case.direction));
        try testing.expectEqual(@as(usize, 0), xs.len);
    }
}

test "a ray lying in a face of the cube sees it edge-on and misses" {
    const xs = C.localIntersect(.{}, R.init(V.point(1, 0, -5), V.vector(0, 0, 1)));
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "the normal on a cube names the face the point lies on" {
    const cases = [_]struct { point: V, normal: V }{
        .{ .point = V.point(1, 0.5, -0.8), .normal = V.vector(1, 0, 0) },
        .{ .point = V.point(-1, -0.2, 0.9), .normal = V.vector(-1, 0, 0) },
        .{ .point = V.point(-0.4, 1, -0.1), .normal = V.vector(0, 1, 0) },
        .{ .point = V.point(0.3, -1, -0.7), .normal = V.vector(0, -1, 0) },
        .{ .point = V.point(-0.6, 0.3, 1), .normal = V.vector(0, 0, 1) },
        .{ .point = V.point(0.4, 0.4, -1), .normal = V.vector(0, 0, -1) },
        // The corners belong to a face like everywhere else does.
        .{ .point = V.point(1, 1, 1), .normal = V.vector(1, 0, 0) },
        .{ .point = V.point(-1, -1, -1), .normal = V.vector(-1, 0, 0) },
    };

    for (cases) |case| {
        try testing.expect(C.localNormalAt(.{}, case.point).eql(case.normal));
    }
}

test "cubes are intersected at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const xs = C.localIntersect(.{}, R.init(V.point(5, 0.5, 0), V.vector(-1, 0, 0)));
        try testing.expect(xs.items()[0] == 4 and xs.items()[1] == 6);
        try testing.expect(C.localNormalAt(.{}, V.point(-1, -0.2, 0.9)).eql(V.vector(-1, 0, 0)));
    }
}

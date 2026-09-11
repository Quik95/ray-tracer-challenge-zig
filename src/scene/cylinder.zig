//! The cylinder, and the body its geometry shares with the cone.
//!
//! Both are surfaces of revolution about the y axis, written at the origin
//! and infinite in both +y and -y. What separates them is the radius at a
//! given height: the cylinder holds 1 everywhere, the cone takes |y| and so
//! closes to a point at the origin. That single difference runs through the
//! quadratic, the cap tests, and the wall normal, which is why one body
//! serves both — `profile` is comptime, so each instantiation compiles down
//! to the arithmetic for its own shape with no branch left over.
//!
//! Either can be truncated to a span of y and closed off with end caps. The
//! span is exclusive: a cylinder cut at y = 2 reaches up to, but not
//! including, that height.

const std = @import("std");
const bounds_mod = @import("bounds.zig");
const intersection = @import("intersection.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// Which surface of revolution a `Quadric` is: the radius it holds at a
/// given height is the whole of the difference between them.
pub const Profile = enum { cylinder, cone };

/// A truncatable, cappable surface of revolution about the y axis, over a
/// float type.
pub fn Quadric(comptime T: type, comptime profile: Profile) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Ray = ray.Ray(T);
        pub const Scalar = T;

        /// Two crossings of the curved wall, and one of each end cap. A ray
        /// can only take four if it enters through a cap and leaves through
        /// the wall at the exact height the other cap meets it, but the
        /// buffer has to hold the case regardless.
        pub const max_hits = 4;
        pub const Roots = intersection.Roots(T, max_hits);

        const epsilon = tuple.epsilonOf(T);

        /// The lowest y the surface reaches, exclusive.
        minimum: T = -std.math.inf(T),
        /// The highest y the surface reaches, exclusive.
        maximum: T = std.math.inf(T),
        /// Whether the open ends are covered by end caps.
        closed: bool = false,

        /// The square of the surface's radius at height `y`.
        inline fn radiusSquared(y: T) T {
            return switch (profile) {
                .cylinder => 1,
                .cone => y * y,
            };
        }

        pub const Bounds = bounds_mod.Bounds(T);

        /// As wide as the surface ever grows, and as tall as it was
        /// truncated to. The cylinder holds one unit of radius throughout;
        /// the cone widens with height, so the further of its two ends is
        /// what says how wide it gets — and an end left at infinity leaves
        /// the box infinite too.
        pub fn bounds(self: Self) Bounds {
            const radius = switch (profile) {
                .cylinder => 1,
                .cone => @max(@abs(self.minimum), @abs(self.maximum)),
            };
            return .init(
                Point.point(-radius, self.minimum, -radius),
                Point.point(radius, self.maximum, radius),
            );
        }

        /// Where the ray crosses the surface, nearest first.
        ///
        /// Substituting the ray into the surface's equation leaves a
        /// quadratic in t, exactly as it does for the sphere. A vanishing
        /// leading coefficient means the ray never approaches the wall at
        /// all — it runs parallel to the cylinder's axis, or to one half of
        /// the cone — and what is left is linear: the cone's other half is
        /// still met once, while the cylinder is not met at all. The caps
        /// are considered either way, since a ray straight down the axis
        /// meets nothing but caps.
        pub fn localIntersect(self: Self, r: Ray) Roots {
            var roots: Roots = .{};

            const o = r.origin;
            const d = r.direction;
            const a = switch (profile) {
                .cylinder => d.x() * d.x() + d.z() * d.z(),
                .cone => d.x() * d.x() - d.y() * d.y() + d.z() * d.z(),
            };
            const b = 2 * switch (profile) {
                .cylinder => o.x() * d.x() + o.z() * d.z(),
                .cone => o.x() * d.x() - o.y() * d.y() + o.z() * d.z(),
            };
            const c = switch (profile) {
                .cylinder => o.x() * o.x() + o.z() * o.z() - 1,
                .cone => o.x() * o.x() - o.y() * o.y() + o.z() * o.z(),
            };

            if (@abs(a) < epsilon) {
                // Both coefficients gone means the ray runs along the cone's
                // surface and misses it the way a plane is missed edge-on.
                if (@abs(b) >= epsilon) self.addWall(r, -c / (2 * b), &roots);
            } else {
                const disc = b * b - 4 * a * c;
                if (disc >= 0) {
                    const root = @sqrt(disc);
                    self.addWall(r, (-b - root) / (2 * a), &roots);
                    self.addWall(r, (-b + root) / (2 * a), &roots);
                }
            }

            self.addCaps(r, &roots);
            roots.sort();
            return roots;
        }

        /// Keep a crossing of the infinite wall if it falls within the span
        /// the surface was truncated to.
        fn addWall(self: Self, r: Ray, t: T, roots: *Roots) void {
            const y = r.origin.y() + t * r.direction.y();
            if (self.minimum < y and y < self.maximum) roots.push(t);
        }

        /// The crossings of the end caps, which are discs of the surface's
        /// own radius lying in the planes that close it off. A ray with no
        /// slope in y runs parallel to both and meets neither.
        fn addCaps(self: Self, r: Ray, roots: *Roots) void {
            if (!self.closed or @abs(r.direction.y()) < epsilon) return;

            for ([_]T{ self.minimum, self.maximum }) |plane| {
                const t = (plane - r.origin.y()) / r.direction.y();
                const x = r.origin.x() + t * r.direction.x();
                const z = r.origin.z() + t * r.direction.z();
                if (x * x + z * z <= radiusSquared(plane)) roots.push(t);
            }
        }

        /// The normal at a point on the surface.
        ///
        /// A point nearer the axis than the surface itself reaches must be
        /// on an end cap, which is flat and so has one normal throughout.
        /// The `epsilon` matters: without it, rounding that leaves the point
        /// a hair inside a cap earns it the wall's normal instead, and the
        /// cap shades as a ring of wrong pixels.
        pub fn localNormalAt(self: Self, p: Point) Point {
            const dist = p.x() * p.x() + p.z() * p.z();

            if (self.closed) {
                if (dist < radiusSquared(self.maximum) and p.y() >= self.maximum - epsilon)
                    return Point.vector(0, 1, 0);
                if (dist < radiusSquared(self.minimum) and p.y() <= self.minimum + epsilon)
                    return Point.vector(0, -1, 0);
            }

            return switch (profile) {
                .cylinder => Point.vector(p.x(), 0, p.z()),
                // The cone's wall slopes, so the normal leans along y by as
                // much as the point stands out from the axis — away from the
                // apex, which is to say opposite the sign of y.
                .cone => Point.vector(
                    p.x(),
                    if (p.y() > 0) -@sqrt(dist) else @sqrt(dist),
                    p.z(),
                ),
            };
        }
    };
}

/// The unit-radius cylinder about the y axis, over a float type.
pub fn Cylinder(comptime T: type) type {
    return Quadric(T, .cylinder);
}

/// The cylinder at the precision the ray tracer uses.
pub const Cyl = Cylinder(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;

test "a ray parallel to the y axis or aimed away misses the cylinder" {
    const cases = [_]struct { origin: V, direction: V }{
        // On the surface and inside it, both running alongside the axis.
        .{ .origin = V.point(1, 0, 0), .direction = V.vector(0, 1, 0) },
        .{ .origin = V.point(0, 0, 0), .direction = V.vector(0, 1, 0) },
        .{ .origin = V.point(0, 0, -5), .direction = V.vector(1, 1, 1) },
    };

    for (cases) |case| {
        const xs = Cyl.localIntersect(.{}, R.init(case.origin, case.direction.normalize()));
        try testing.expectEqual(@as(usize, 0), xs.len);
    }
}

test "a ray strikes the cylinder's wall" {
    const cases = [_]struct { origin: V, direction: V, t0: f64, t1: f64 }{
        // A tangent still reports two crossings, so that overlapping solids
        // can be told apart later.
        .{ .origin = V.point(1, 0, -5), .direction = V.vector(0, 0, 1), .t0 = 5, .t1 = 5 },
        .{ .origin = V.point(0, 0, -5), .direction = V.vector(0, 0, 1), .t0 = 4, .t1 = 6 },
        .{
            .origin = V.point(0.5, 0, -5),
            .direction = V.vector(0.1, 1, 1),
            .t0 = 6.80798,
            .t1 = 7.08872,
        },
    };

    for (cases) |case| {
        const xs = Cyl.localIntersect(.{}, R.init(case.origin, case.direction.normalize()));
        try testing.expectEqual(@as(usize, 2), xs.len);
        try testing.expectApproxEqAbs(case.t0, xs.items()[0], 1e-5);
        try testing.expectApproxEqAbs(case.t1, xs.items()[1], 1e-5);
    }
}

test "the normal on the cylinder's wall points straight out from the axis" {
    const cases = [_]struct { point: V, normal: V }{
        .{ .point = V.point(1, 0, 0), .normal = V.vector(1, 0, 0) },
        .{ .point = V.point(0, 5, -1), .normal = V.vector(0, 0, -1) },
        .{ .point = V.point(0, -2, 1), .normal = V.vector(0, 0, 1) },
        .{ .point = V.point(-1, 1, 0), .normal = V.vector(-1, 0, 0) },
    };

    for (cases) |case| {
        try testing.expect(Cyl.localNormalAt(.{}, case.point).eql(case.normal));
    }
}

test "a cylinder reaches to infinity and is open by default" {
    const c: Cyl = .{};
    try testing.expectEqual(-std.math.inf(f64), c.minimum);
    try testing.expectEqual(std.math.inf(f64), c.maximum);
    try testing.expect(!c.closed);
}

test "a truncated cylinder is met only between its ends" {
    const c: Cyl = .{ .minimum = 1, .maximum = 2 };
    const cases = [_]struct { origin: V, direction: V, count: usize }{
        // Escaping diagonally from inside, and passing above and below.
        .{ .origin = V.point(0, 1.5, 0), .direction = V.vector(0.1, 1, 0), .count = 0 },
        .{ .origin = V.point(0, 3, -5), .direction = V.vector(0, 0, 1), .count = 0 },
        .{ .origin = V.point(0, 0, -5), .direction = V.vector(0, 0, 1), .count = 0 },
        // The bounds themselves are outside the surface.
        .{ .origin = V.point(0, 2, -5), .direction = V.vector(0, 0, 1), .count = 0 },
        .{ .origin = V.point(0, 1, -5), .direction = V.vector(0, 0, 1), .count = 0 },
        .{ .origin = V.point(0, 1.5, -2), .direction = V.vector(0, 0, 1), .count = 2 },
    };

    for (cases) |case| {
        const xs = c.localIntersect(R.init(case.origin, case.direction.normalize()));
        try testing.expectEqual(case.count, xs.len);
    }
}

test "a closed cylinder is met through its end caps" {
    const c: Cyl = .{ .minimum = 1, .maximum = 2, .closed = true };
    const cases = [_]struct { origin: V, direction: V }{
        // Straight down the axis, through both caps.
        .{ .origin = V.point(0, 3, 0), .direction = V.vector(0, -1, 0) },
        // In through a cap and out through the far wall, from above and below.
        .{ .origin = V.point(0, 3, -2), .direction = V.vector(0, -1, 2) },
        .{ .origin = V.point(0, 0, -2), .direction = V.vector(0, 1, 2) },
        // Leaving exactly where the other cap meets the wall: still two.
        .{ .origin = V.point(0, 4, -2), .direction = V.vector(0, -1, 1) },
        .{ .origin = V.point(0, -1, -2), .direction = V.vector(0, 1, 1) },
    };

    for (cases) |case| {
        const xs = c.localIntersect(R.init(case.origin, case.direction.normalize()));
        try testing.expectEqual(@as(usize, 2), xs.len);
    }
}

test "the normal on a cylinder's end caps is flat" {
    const c: Cyl = .{ .minimum = 1, .maximum = 2, .closed = true };
    const cases = [_]struct { point: V, normal: V }{
        .{ .point = V.point(0, 1, 0), .normal = V.vector(0, -1, 0) },
        .{ .point = V.point(0.5, 1, 0), .normal = V.vector(0, -1, 0) },
        .{ .point = V.point(0, 1, 0.5), .normal = V.vector(0, -1, 0) },
        .{ .point = V.point(0, 2, 0), .normal = V.vector(0, 1, 0) },
        .{ .point = V.point(0.5, 2, 0), .normal = V.vector(0, 1, 0) },
        .{ .point = V.point(0, 2, 0.5), .normal = V.vector(0, 1, 0) },
    };

    for (cases) |case| {
        try testing.expect(c.localNormalAt(case.point).eql(case.normal));
    }
}

test "cylinders are intersected at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const c: Cyl = .{ .minimum = 1, .maximum = 2, .closed = true };
        const xs = c.localIntersect(R.init(V.point(0, 3, 0), V.vector(0, -1, 0)));
        try testing.expect(xs.items()[0] == 1 and xs.items()[1] == 2);
        try testing.expect(c.localNormalAt(V.point(0, 2, 0)).eql(V.vector(0, 1, 0)));
    }
}

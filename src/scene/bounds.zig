//! An axis-aligned box around something, and the cheap test for whether a ray
//! comes near it at all.
//!
//! Every geometry knows a box that holds it, written in its own coordinates.
//! A group's box is the boxes of everything beneath it, each carried into the
//! group's coordinates and merged; a ray that misses that box misses every
//! shape inside it, so the whole subtree can be skipped for the price of one
//! box test.
//!
//! A box may reach to infinity along an axis — the plane does, and so does an
//! untruncated cylinder — in which case it never rules anything out, which is
//! the right answer rather than a special case.

const std = @import("std");
const ray_mod = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// An axis-aligned box, over a float type.
pub fn Bounds(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Ray = ray_mod.Ray(T);
        pub const M = @import("../math/matrix.zig").Matrix(T, 4);
        pub const Scalar = T;

        const inf = std.math.inf(T);

        /// The near-bottom-left corner, and the far-top-right one.
        min: Point = Point.point(inf, inf, inf),
        max: Point = Point.point(-inf, -inf, -inf),

        /// A box holding nothing. Its corners are the wrong way round, so
        /// growing it by a point leaves the point's own bounds behind.
        pub const empty: Self = .{};

        /// A box holding everything: what a shape of unknown extent is
        /// bounded by, and what never rules a ray out.
        pub const everything: Self = .{
            .min = Point.point(-inf, -inf, -inf),
            .max = Point.point(inf, inf, inf),
        };

        pub fn init(min: Point, max: Point) Self {
            return .{ .min = min, .max = max };
        }

        /// A box from the origin out to `x`, `y`, and `z` in each direction.
        pub fn centered(x: T, y: T, z: T) Self {
            return init(Point.point(-x, -y, -z), Point.point(x, y, z));
        }

        pub fn isEmpty(self: Self) bool {
            return @reduce(.Or, self.min.v > self.max.v);
        }

        /// The box grown just enough to hold `p`.
        pub fn add(self: Self, p: Point) Self {
            return .{
                .min = .{ .v = @min(self.min.v, p.v) },
                .max = .{ .v = @max(self.max.v, p.v) },
            };
        }

        /// The smallest box holding both.
        pub fn merge(self: Self, other: Self) Self {
            if (other.isEmpty()) return self;
            if (self.isEmpty()) return other;
            return .{
                .min = .{ .v = @min(self.min.v, other.min.v) },
                .max = .{ .v = @max(self.max.v, other.max.v) },
            };
        }

        /// The box the two have in common, and empty where they have none.
        /// What lies outside either box lies outside their overlap, which is
        /// what bounds a CSG intersection.
        pub fn overlap(self: Self, other: Self) Self {
            if (self.isEmpty() or other.isEmpty()) return empty;
            const box: Self = .{
                .min = .{ .v = @max(self.min.v, other.min.v) },
                .max = .{ .v = @min(self.max.v, other.max.v) },
            };
            return if (box.isEmpty()) empty else box;
        }

        pub fn contains(self: Self, p: Point) bool {
            return @reduce(.And, self.min.v <= p.v) and @reduce(.And, p.v <= self.max.v);
        }

        /// The smallest axis-aligned box holding this one once `m` has been
        /// applied to it.
        ///
        /// A transformation can turn the box, so it is all eight corners that
        /// are carried over and a fresh box drawn around where they land;
        /// moving the two corners alone would leave a box that no longer holds
        /// the shape. A box already reaching to infinity is left as it is: the
        /// arithmetic would only produce nonsense, and nothing finite could
        /// hold it anyway.
        pub fn transform(self: Self, m: M) Self {
            if (self.isEmpty()) return empty;
            if (!self.isFinite()) return everything;

            var out: Self = .empty;
            for (0..8) |corner| {
                // The three bits of the corner's number pick, per axis,
                // which of the two bounds that corner takes.
                const from = Point.point(
                    if (corner & 1 == 0) self.min.x() else self.max.x(),
                    if (corner & 2 == 0) self.min.y() else self.max.y(),
                    if (corner & 4 == 0) self.min.z() else self.max.z(),
                );
                out = out.add(m.mulTuple(from));
            }
            return out;
        }

        fn isFinite(self: Self) bool {
            inline for (0..3) |i| {
                if (!std.math.isFinite(self.min.v[i]) or !std.math.isFinite(self.max.v[i])) {
                    return false;
                }
            }
            return true;
        }

        /// Whether `r` crosses the box anywhere along its length, behind its
        /// origin included — what lies behind the eye still decides which
        /// material a refracted ray is travelling through.
        ///
        /// The box is the region between three pairs of parallel planes, so
        /// the ray is inside it only where it is inside all three slabs at
        /// once: the entry is the last of the three entries and the exit the
        /// first of the three exits. This is the cube's own test, over
        /// arbitrary bounds rather than -1 and 1, and it treats a direction of
        /// zero the same way — the slab's ends run off to infinity with the
        /// sign of the numerator, and where the ray lies exactly in a face the
        /// resulting NaN is discarded by `@min` and `@max`.
        pub fn intersects(self: Self, r: Ray) bool {
            if (self.isEmpty()) return false;

            const origin = axes(r.origin);
            const direction = axes(r.direction);
            const near = (axes(self.min) - origin) / direction;
            const far = (axes(self.max) - origin) / direction;

            const entry = @reduce(.Max, @min(near, far));
            const exit = @reduce(.Min, @max(near, far));
            return entry <= exit;
        }

        /// The three components that carry position; `w` says point or vector
        /// and has no part in the geometry.
        inline fn axes(t: Point) @Vector(3, T) {
            return @shuffle(T, t.v, undefined, [3]i32{ 0, 1, 2 });
        }
    };
}

/// The box at the precision the ray tracer uses.
pub const B = Bounds(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const R = ray_mod.R;
const Tf = @import("../math/transform.zig").Tf;
const V = tuple.Tup;

test "an empty box holds nothing and is met by nothing" {
    const b: B = .empty;
    try testing.expect(b.isEmpty());
    try testing.expect(!b.contains(V.point(0, 0, 0)));
    try testing.expect(!b.intersects(R.init(V.point(0, 0, -5), V.vector(0, 0, 1))));
}

test "a box holds everything between its corners" {
    const b = B.centered(1, 2, 3);
    try testing.expect(!b.isEmpty());
    try testing.expect(b.contains(V.point(0, 0, 0)));
    try testing.expect(b.contains(V.point(1, 2, 3)));
    try testing.expect(b.contains(V.point(-1, -2, -3)));
    try testing.expect(!b.contains(V.point(1.1, 0, 0)));
}

test "adding a point grows the box to reach it" {
    const b = B.empty.add(V.point(-5, 2, 0)).add(V.point(7, 0, 3));
    try testing.expect(b.min.eql(V.point(-5, 0, 0)));
    try testing.expect(b.max.eql(V.point(7, 2, 3)));
}

test "merging takes the smallest box holding both, and ignores an empty one" {
    const a = B.centered(1, 1, 1);
    const b = B.init(V.point(2, 0, -3), V.point(4, 1, 0));
    const merged = a.merge(b);
    try testing.expect(merged.min.eql(V.point(-1, -1, -3)));
    try testing.expect(merged.max.eql(V.point(4, 1, 1)));

    try testing.expect(a.merge(.empty).min.eql(a.min));
    try testing.expect(B.empty.merge(a).max.eql(a.max));
}

test "overlapping keeps only what both boxes hold" {
    const a = B.centered(1, 1, 1);
    const b = B.init(V.point(0, 0, 0), V.point(4, 1, 3));
    const shared = a.overlap(b);
    try testing.expect(shared.min.eql(V.point(0, 0, 0)));
    try testing.expect(shared.max.eql(V.point(1, 1, 1)));

    // Boxes that never meet share nothing, and neither does an empty one.
    try testing.expect(a.overlap(B.init(V.point(5, 5, 5), V.point(6, 6, 6))).isEmpty());
    try testing.expect(a.overlap(.empty).isEmpty());
}

test "a turned box is measured by where all eight corners land" {
    // A quarter turn about y swaps the box's reach in x and z.
    const turned = B.init(V.point(-1, 0, -2), V.point(3, 1, 2))
        .transform(Tf.rotationY(std.math.pi / 2.0));
    try testing.expect(turned.min.eql(V.point(-2, 0, -3)));
    try testing.expect(turned.max.eql(V.point(2, 1, 1)));

    // Half a turn about z, which no pair of opposite corners survives alone.
    const flipped = B.init(V.point(0, 0, 0), V.point(2, 1, 1))
        .transform(Tf.rotationZ(std.math.pi));
    try testing.expect(flipped.min.eql(V.point(-2, -1, 0)));
    try testing.expect(flipped.max.eql(V.point(0, 0, 1)));
}

test "a box reaching to infinity stays that way under a transformation" {
    const b = B.init(V.point(-B.everything.max.x(), 0, -1), V.point(B.everything.max.x(), 0, 1));
    const moved = b.transform(Tf.translation(0, 3, 0));
    try testing.expect(!moved.isFinite());
    try testing.expect(moved.intersects(R.init(V.point(0, 100, 0), V.vector(0, 1, 0))));

    try testing.expect(B.empty.transform(Tf.scaling(2, 2, 2)).isEmpty());
}

test "a ray meets the box it passes through and misses the one it goes by" {
    const b = B.centered(1, 1, 1);
    try testing.expect(b.intersects(R.init(V.point(5, 0.5, 0), V.vector(-1, 0, 0))));
    try testing.expect(b.intersects(R.init(V.point(0, 0, 0), V.vector(0, 0, 1))));
    // Behind the ray still counts: it is the line that is tested, not the
    // half of it ahead of the origin.
    try testing.expect(b.intersects(R.init(V.point(0, 0, 5), V.vector(0, 0, 1))));
    try testing.expect(!b.intersects(R.init(V.point(-2, 0, 0), V.vector(0.2673, 0.5345, 0.8018))));
    try testing.expect(!b.intersects(R.init(V.point(2, 2, 0), V.vector(-1, 0, 0))));
}

test "a ray running along a face of the box sees it edge-on" {
    const b = B.centered(1, 1, 1);
    // The same answer the cube gives: a face met edge-on is missed.
    try testing.expect(!b.intersects(R.init(V.point(1, 0, -5), V.vector(0, 0, 1))));
}

test "boxes are built and tested at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const b = B.empty.add(V.point(0, 0, 0)).add(V.point(1, 1, 1));
        try testing.expect(b.transform(Tf.translation(5, 0, 0)).contains(V.point(5.5, 0.5, 0.5)));
        try testing.expect(b.intersects(R.init(V.point(0.5, 0.5, -5), V.vector(0, 0, 1))));
    }
}

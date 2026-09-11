//! Rays: a starting point and the direction it travels in.

const std = @import("std");
const matrix = @import("../math/matrix.zig");
const tuple = @import("../math/tuple.zig");

/// A ray, over a float type.
pub fn Ray(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const M = matrix.Matrix(T, 4);
        pub const Scalar = T;

        /// Where the ray starts, a point.
        origin: Point,
        /// Where it goes, a vector. Its length is the distance covered per
        /// unit of t, so it is deliberately not normalized on construction.
        direction: Point,

        pub inline fn init(origin: Point, direction: Point) Self {
            return .{ .origin = origin, .direction = direction };
        }

        /// The point t units along the ray. Negative t looks backwards, past
        /// the origin.
        pub inline fn position(self: Self, t: T) Point {
            return self.origin.add(self.direction.mul(t));
        }

        /// The ray seen through a transformation, as a new ray. The direction
        /// is transformed too and keeps whatever length that gives it, so a t
        /// computed against the result still measures the original distance.
        pub fn transform(self: Self, m: M) Self {
            return .{
                .origin = m.mulTuple(self.origin),
                .direction = m.mulTuple(self.direction),
            };
        }
    };
}

/// The ray at the precision the ray tracer uses.
pub const R = Ray(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const Tf = @import("../math/transform.zig").Tf;

test "creating and querying a ray" {
    const origin = V.point(1, 2, 3);
    const direction = V.vector(4, 5, 6);
    const r = R.init(origin, direction);
    try testing.expect(r.origin.eql(origin));
    try testing.expect(r.direction.eql(direction));
}

test "computing a point from a distance" {
    const r = R.init(V.point(2, 3, 4), V.vector(1, 0, 0));
    try testing.expect(r.position(0).eql(V.point(2, 3, 4)));
    try testing.expect(r.position(1).eql(V.point(3, 3, 4)));
    try testing.expect(r.position(-1).eql(V.point(1, 3, 4)));
    try testing.expect(r.position(2.5).eql(V.point(4.5, 3, 4)));
}

test "translating a ray" {
    const r = R.init(V.point(1, 2, 3), V.vector(0, 1, 0));
    const r2 = r.transform(Tf.translation(3, 4, 5));
    try testing.expect(r2.origin.eql(V.point(4, 6, 8)));
    // A vector has w = 0, so the translation leaves the direction alone.
    try testing.expect(r2.direction.eql(V.vector(0, 1, 0)));
}

test "scaling a ray" {
    const r = R.init(V.point(1, 2, 3), V.vector(0, 1, 0));
    const r2 = r.transform(Tf.scaling(2, 3, 4));
    try testing.expect(r2.origin.eql(V.point(2, 6, 12)));
    try testing.expect(r2.direction.eql(V.vector(0, 3, 0)));
}

test "rays can be cast at comptime" {
    comptime {
        const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
        try testing.expect(r.position(5).eql(V.point(0, 0, 0)));
        const moved = r.transform(Tf.translation(0, 1, 0));
        try testing.expect(moved.origin.eql(V.point(0, 1, -5)));
    }
}

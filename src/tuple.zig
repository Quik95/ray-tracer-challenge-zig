//! Tuples, points, and vectors.
//!
//! A tuple is an (x, y, z, w) quadruple. `w = 1` marks a point (a position in
//! space), `w = 0` marks a vector (a direction plus a distance). Keeping `w`
//! around is what makes points and vectors distinguishable, and it becomes
//! load-bearing once tuples get multiplied by matrices.

const std = @import("std");

/// Component selector. Used as a `comptime` argument so `get` compiles down to
/// a plain vector element access with no runtime branch.
pub const Axis = enum(u2) { x, y, z, w };

/// Compare two floats for equivalence, tolerating round-off error.
pub fn feq(comptime T: type, a: T, b: T) bool {
    return @abs(a - b) < epsilonOf(T);
}

/// The book uses a single EPSILON of 0.00001 regardless of precision.
pub fn epsilonOf(comptime T: type) T {
    return 1e-5;
}

/// A 4-component tuple backed by a SIMD vector, generic over the float type.
pub fn Tuple(comptime T: type) type {
    if (@typeInfo(T) != .float) {
        @compileError("Tuple requires a floating point type, got " ++ @typeName(T));
    }

    return struct {
        const Self = @This();

        /// Underlying SIMD representation.
        pub const Repr = @Vector(4, T);
        pub const Scalar = T;
        pub const epsilon: T = epsilonOf(T);

        /// The zero tuple, (0, 0, 0, 0).
        pub const zero: Self = .{ .v = @splat(0) };

        v: Repr,

        /// tuple(x, y, z, w)
        pub inline fn init(x_: T, y_: T, z_: T, w_: T) Self {
            return .{ .v = .{ x_, y_, z_, w_ } };
        }

        /// point(x, y, z) creates tuples with w=1.
        pub inline fn point(x_: T, y_: T, z_: T) Self {
            return init(x_, y_, z_, 1);
        }

        /// vector(x, y, z) creates tuples with w=0.
        pub inline fn vector(x_: T, y_: T, z_: T) Self {
            return init(x_, y_, z_, 0);
        }

        /// Read a single component. The axis is comptime-known, so this is a
        /// free vector element access.
        pub inline fn get(self: Self, comptime axis: Axis) T {
            return self.v[@intFromEnum(axis)];
        }

        pub inline fn x(self: Self) T {
            return self.get(.x);
        }

        pub inline fn y(self: Self) T {
            return self.get(.y);
        }

        pub inline fn z(self: Self) T {
            return self.get(.z);
        }

        pub inline fn w(self: Self) T {
            return self.get(.w);
        }

        pub inline fn isPoint(self: Self) bool {
            return feq(T, self.w(), 1);
        }

        pub inline fn isVector(self: Self) bool {
            return feq(T, self.w(), 0);
        }

        /// Component-wise comparison within EPSILON.
        pub fn eql(a: Self, b: Self) bool {
            const diff = @abs(a.v - b.v);
            return @reduce(.And, diff < @as(Repr, @splat(epsilon)));
        }

        /// Adding a vector to a point moves the point along the vector. The w
        /// components add too: point + vector = point, vector + vector = vector.
        pub inline fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v };
        }

        /// point - point = vector, point - vector = point, vector - vector = vector.
        pub inline fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v };
        }

        /// -tuple: (x, y, z, w) becomes (-x, -y, -z, -w).
        pub inline fn neg(self: Self) Self {
            return .{ .v = -self.v };
        }

        /// Scale the tuple uniformly.
        pub inline fn mul(self: Self, scalar: T) Self {
            return .{ .v = self.v * @as(Repr, @splat(scalar)) };
        }

        pub inline fn div(self: Self, scalar: T) Self {
            return .{ .v = self.v / @as(Repr, @splat(scalar)) };
        }

        /// Length of the vector: sqrt(x² + y² + z² + w²).
        pub fn magnitude(self: Self) T {
            return @sqrt(@reduce(.Add, self.v * self.v));
        }

        /// Convert a vector into a unit vector, preserving its direction.
        pub fn normalize(self: Self) Self {
            return self.div(self.magnitude());
        }

        /// Sum of the products of corresponding components. For unit vectors
        /// this is the cosine of the angle between them.
        pub fn dot(a: Self, b: Self) T {
            return @reduce(.Add, a.v * b.v);
        }

        /// Three-dimensional cross product: a vector perpendicular to both
        /// inputs. Order matters — cross(b, a) points the other way.
        ///
        /// Shuffling by (y, z, x) and (z, x, y) gives the three 2x2
        /// determinants in one pass; slot w works out to a.w*b.w - a.w*b.w = 0,
        /// so the result is always a vector.
        pub fn cross(a: Self, b: Self) Self {
            const yzx: @Vector(4, i32) = .{ 1, 2, 0, 3 };
            const zxy: @Vector(4, i32) = .{ 2, 0, 1, 3 };
            const a_yzx = @shuffle(T, a.v, undefined, yzx);
            const a_zxy = @shuffle(T, a.v, undefined, zxy);
            const b_yzx = @shuffle(T, b.v, undefined, yzx);
            const b_zxy = @shuffle(T, b.v, undefined, zxy);
            return .{ .v = a_yzx * b_zxy - a_zxy * b_yzx };
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("({d}, {d}, {d}, {d})", .{ self.x(), self.y(), self.z(), self.w() });
        }
    };
}

/// The precision the ray tracer uses everywhere.
pub const Tup = Tuple(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = Tup;

/// The specs are stated for plain numbers, so run the core scenarios at both
/// precisions to keep the generic code honest.
const precisions = .{ f32, f64 };

test "a tuple with w=1.0 is a point" {
    const a = V.init(4.3, -4.2, 3.1, 1.0);
    try testing.expectEqual(@as(f64, 4.3), a.x());
    try testing.expectEqual(@as(f64, -4.2), a.y());
    try testing.expectEqual(@as(f64, 3.1), a.z());
    try testing.expectEqual(@as(f64, 1.0), a.w());
    try testing.expect(a.isPoint());
    try testing.expect(!a.isVector());
}

test "a tuple with w=0 is a vector" {
    const a = V.init(4.3, -4.2, 3.1, 0.0);
    try testing.expectEqual(@as(f64, 4.3), a.x());
    try testing.expectEqual(@as(f64, -4.2), a.y());
    try testing.expectEqual(@as(f64, 3.1), a.z());
    try testing.expectEqual(@as(f64, 0.0), a.w());
    try testing.expect(!a.isPoint());
    try testing.expect(a.isVector());
}

test "point() creates tuples with w=1" {
    inline for (precisions) |T| {
        const P = Tuple(T);
        try testing.expect(P.point(4, -4, 3).eql(P.init(4, -4, 3, 1)));
    }
}

test "vector() creates tuples with w=0" {
    inline for (precisions) |T| {
        const P = Tuple(T);
        try testing.expect(P.vector(4, -4, 3).eql(P.init(4, -4, 3, 0)));
    }
}

test "adding two tuples" {
    const a1 = V.init(3, -2, 5, 1);
    const a2 = V.init(-2, 3, 1, 0);
    try testing.expect(a1.add(a2).eql(V.init(1, 1, 6, 1)));
}

test "subtracting two points" {
    const p1 = V.point(3, 2, 1);
    const p2 = V.point(5, 6, 7);
    try testing.expect(p1.sub(p2).eql(V.vector(-2, -4, -6)));
}

test "subtracting a vector from a point" {
    const p = V.point(3, 2, 1);
    const v = V.vector(5, 6, 7);
    try testing.expect(p.sub(v).eql(V.point(-2, -4, -6)));
}

test "subtracting two vectors" {
    const v1 = V.vector(3, 2, 1);
    const v2 = V.vector(5, 6, 7);
    try testing.expect(v1.sub(v2).eql(V.vector(-2, -4, -6)));
}

test "subtracting a vector from the zero vector" {
    const v = V.vector(1, -2, 3);
    try testing.expect(V.zero.sub(v).eql(V.vector(-1, 2, -3)));
}

test "negating a tuple" {
    const a = V.init(1, -2, 3, -4);
    try testing.expect(a.neg().eql(V.init(-1, 2, -3, 4)));
}

test "multiplying a tuple by a scalar" {
    const a = V.init(1, -2, 3, -4);
    try testing.expect(a.mul(3.5).eql(V.init(3.5, -7, 10.5, -14)));
}

test "multiplying a tuple by a fraction" {
    const a = V.init(1, -2, 3, -4);
    try testing.expect(a.mul(0.5).eql(V.init(0.5, -1, 1.5, -2)));
}

test "dividing a tuple by a scalar" {
    const a = V.init(1, -2, 3, -4);
    try testing.expect(a.div(2).eql(V.init(0.5, -1, 1.5, -2)));
}

test "computing the magnitude of unit vectors" {
    try testing.expectEqual(@as(f64, 1), V.vector(1, 0, 0).magnitude());
    try testing.expectEqual(@as(f64, 1), V.vector(0, 1, 0).magnitude());
    try testing.expectEqual(@as(f64, 1), V.vector(0, 0, 1).magnitude());
}

test "computing the magnitude of vector(1, 2, 3)" {
    try testing.expect(feq(f64, V.vector(1, 2, 3).magnitude(), @sqrt(14.0)));
}

test "computing the magnitude of vector(-1, -2, -3)" {
    try testing.expect(feq(f64, V.vector(-1, -2, -3).magnitude(), @sqrt(14.0)));
}

test "normalizing vector(4, 0, 0) gives (1, 0, 0)" {
    try testing.expect(V.vector(4, 0, 0).normalize().eql(V.vector(1, 0, 0)));
}

test "normalizing vector(1, 2, 3)" {
    // vector(1/√14, 2/√14, 3/√14)
    const expected = V.vector(0.26726, 0.53452, 0.80178);
    try testing.expect(V.vector(1, 2, 3).normalize().eql(expected));
}

test "the magnitude of a normalized vector" {
    const norm = V.vector(1, 2, 3).normalize();
    try testing.expect(feq(f64, norm.magnitude(), 1));
}

test "the dot product of two tuples" {
    const a = V.vector(1, 2, 3);
    const b = V.vector(2, 3, 4);
    try testing.expectEqual(@as(f64, 20), a.dot(b));
}

test "the cross product of two vectors" {
    const a = V.vector(1, 2, 3);
    const b = V.vector(2, 3, 4);
    try testing.expect(a.cross(b).eql(V.vector(-1, 2, -1)));
    try testing.expect(b.cross(a).eql(V.vector(1, -2, 1)));
    // The cross product of two vectors is a vector.
    try testing.expect(a.cross(b).isVector());
}

test "the axes are mutually perpendicular under cross product" {
    const x_axis = V.vector(1, 0, 0);
    const y_axis = V.vector(0, 1, 0);
    const z_axis = V.vector(0, 0, 1);
    try testing.expect(x_axis.cross(y_axis).eql(z_axis));
    try testing.expect(y_axis.cross(z_axis).eql(x_axis));
    try testing.expect(z_axis.cross(x_axis).eql(y_axis));
    try testing.expect(y_axis.cross(x_axis).eql(z_axis.neg()));
}

test "tuple arithmetic is available at comptime" {
    comptime {
        const p = V.point(3, -2, 5);
        const moved = p.add(V.vector(-2, 3, 1));
        try testing.expect(moved.eql(V.point(1, 1, 6)));
        try testing.expect(moved.isPoint());
        try testing.expect(feq(f64, V.vector(1, 2, 3).normalize().magnitude(), 1));
    }
}

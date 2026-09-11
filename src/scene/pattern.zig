//! Patterns: rules that colour a surface by where a point lies on it.
//!
//! A pattern is written in its own coordinates, the way a geometry is, and
//! carries a transformation that says how those coordinates sit on the object
//! wearing it. A point therefore travels twice before it reaches the rule:
//! world space into object space by the shape's inverse, object space into
//! pattern space by the pattern's own.
//!
//! Which rule a pattern follows is a tagged union, like a shape's geometry —
//! a switch the compiler can see through, and no allocation, so a patterned
//! scene is still usable at comptime.

const std = @import("std");
const color_mod = @import("../render/color.zig");
const matrix = @import("../math/matrix.zig");
const tuple = @import("../math/tuple.zig");

/// A surface pattern, over a float type.
pub fn Pattern(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const C = color_mod.Color(T);
        pub const Point = tuple.Tuple(T);
        pub const M = matrix.Matrix(T, 4);
        pub const Scalar = T;

        /// The two colours a repeating pattern alternates between.
        pub const Pair = struct {
            a: C = C.white,
            b: C = C.black,

            pub fn eql(x: Pair, y: Pair) bool {
                return x.a.eql(y.a) and x.b.eql(y.b);
            }

            /// The colour for an even/odd decision already made.
            inline fn pick(self: Pair, even: bool) C {
                return if (even) self.a else self.b;
            }
        };

        /// The rules themselves.
        pub const Kind = union(enum) {
            /// Bands alternating along x, constant in y and z.
            stripes: Pair,
            /// A smooth blend from one colour to the other along x.
            gradient: Pair,
            /// Concentric cylinders about the y axis.
            rings: Pair,
            /// Cubes of alternating colour filling all three dimensions.
            checkers: Pair,
            /// The point itself, read as a colour. Nothing in a scene wants
            /// this; it is how a test sees which point the rule was handed.
            position,

            pub fn eql(x: Kind, y: Kind) bool {
                if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
                return switch (x) {
                    .position => true,
                    inline else => |pair, tag| pair.eql(@field(y, @tagName(tag))),
                };
            }
        };

        /// Pattern space to object space.
        transform: M = M.identity,
        kind: Kind,

        pub fn stripes(a: C, b: C) Self {
            return .{ .kind = .{ .stripes = .{ .a = a, .b = b } } };
        }

        pub fn gradient(a: C, b: C) Self {
            return .{ .kind = .{ .gradient = .{ .a = a, .b = b } } };
        }

        pub fn rings(a: C, b: C) Self {
            return .{ .kind = .{ .rings = .{ .a = a, .b = b } } };
        }

        pub fn checkers(a: C, b: C) Self {
            return .{ .kind = .{ .checkers = .{ .a = a, .b = b } } };
        }

        pub fn setTransform(self: *Self, m: M) void {
            self.transform = m;
        }

        pub fn eql(x: Self, y: Self) bool {
            return x.transform.eql(y.transform) and x.kind.eql(y.kind);
        }

        /// The colour this rule gives a point already in pattern space.
        pub fn at(self: Self, p: Point) C {
            return switch (self.kind) {
                .stripes => |pair| pair.pick(isEven(@floor(p.x()))),
                .rings => |pair| pair.pick(isEven(@floor(@sqrt(p.x() * p.x() + p.z() * p.z())))),
                // The sum of the three floors flips parity whenever any one
                // of them does, which is what makes neighbouring cubes differ.
                .checkers => |pair| pair.pick(isEven(@floor(p.x()) + @floor(p.y()) + @floor(p.z()))),
                // The fractional part of x walks from a to b and snaps back,
                // so the blend repeats once per unit.
                .gradient => |pair| pair.a.add(pair.b.sub(pair.a).mul(p.x() - @floor(p.x()))),
                .position => C.init(p.x(), p.y(), p.z()),
            };
        }

        /// The colour for a point in the coordinates of the object wearing
        /// this pattern. A pattern scaled to nothing has no inverse to carry
        /// the point along, and shows its first colour everywhere.
        pub fn atObject(self: Self, object_point: Point) C {
            const inv = self.transform.inverse() catch return self.at(Point.point(0, 0, 0));
            return self.at(inv.mulTuple(object_point));
        }

        /// Whether a whole-numbered float is even. `@mod` keeps the answer
        /// right on the negative side, where truncation would mirror the
        /// pattern about the origin and double the width of the band there.
        inline fn isEven(v: T) bool {
            return @mod(v, 2) == 0;
        }
    };
}

/// The pattern at the precision the ray tracer uses.
pub const Pat = Pattern(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const Col = color_mod.Col;
const Tf = @import("../math/transform.zig").Tf;
const V = tuple.Tup;

const white = Col.white;
const black = Col.black;

test "a pattern keeps the two colors it was made with" {
    const p = Pat.stripes(white, black);
    try testing.expect(p.kind.stripes.a.eql(white));
    try testing.expect(p.kind.stripes.b.eql(black));
}

test "a pattern sits on its object unmoved by default" {
    const p = Pat.stripes(white, black);
    try testing.expect(p.transform.eql(Pat.M.identity));
}

test "a pattern's transformation can be assigned" {
    var p = Pat.stripes(white, black);
    p.setTransform(Tf.translation(1, 2, 3));
    try testing.expect(p.transform.eql(Tf.translation(1, 2, 3)));
}

test "stripes are constant in y and z" {
    const p = Pat.stripes(white, black);
    try testing.expect(p.at(V.point(0, 1, 0)).eql(white));
    try testing.expect(p.at(V.point(0, 2, 0)).eql(white));
    try testing.expect(p.at(V.point(0, 0, 1)).eql(white));
    try testing.expect(p.at(V.point(0, 0, 2)).eql(white));
}

test "stripes alternate in x" {
    const p = Pat.stripes(white, black);
    try testing.expect(p.at(V.point(0, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(0.9, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(1, 0, 0)).eql(black));
    try testing.expect(p.at(V.point(-0.1, 0, 0)).eql(black));
    try testing.expect(p.at(V.point(-1, 0, 0)).eql(black));
    try testing.expect(p.at(V.point(-1.1, 0, 0)).eql(white));
}

test "a gradient interpolates between its colors" {
    const p = Pat.gradient(white, black);
    try testing.expect(p.at(V.point(0, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(0.25, 0, 0)).eql(Col.init(0.75, 0.75, 0.75)));
    try testing.expect(p.at(V.point(0.5, 0, 0)).eql(Col.init(0.5, 0.5, 0.5)));
    try testing.expect(p.at(V.point(0.75, 0, 0)).eql(Col.init(0.25, 0.25, 0.25)));
}

test "rings extend in both x and z" {
    const p = Pat.rings(white, black);
    try testing.expect(p.at(V.point(0, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(1, 0, 0)).eql(black));
    try testing.expect(p.at(V.point(0, 0, 1)).eql(black));
    // Just past the unit circle, on the diagonal.
    try testing.expect(p.at(V.point(0.708, 0, 0.708)).eql(black));
}

test "checkers repeat in every dimension" {
    const p = Pat.checkers(white, black);
    try testing.expect(p.at(V.point(0, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(0.99, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(1.01, 0, 0)).eql(black));
    try testing.expect(p.at(V.point(0, 0.99, 0)).eql(white));
    try testing.expect(p.at(V.point(0, 1.01, 0)).eql(black));
    try testing.expect(p.at(V.point(0, 0, 0.99)).eql(white));
    try testing.expect(p.at(V.point(0, 0, 1.01)).eql(black));
}

test "a pattern transformation moves the pattern over the object" {
    var p: Pat = .{ .kind = .position };
    p.setTransform(Tf.scaling(2, 2, 2));
    try testing.expect(p.atObject(V.point(2, 3, 4)).eql(Col.init(1, 1.5, 2)));
}

test "a pattern scaled to nothing still answers with a color" {
    var p = Pat.stripes(white, black);
    p.setTransform(Tf.scaling(0, 0, 0));
    try testing.expect(p.atObject(V.point(5, 0, 0)).eql(white));
}

test "patterns are evaluated at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const p = Pat.checkers(white, black);
        try testing.expect(p.at(V.point(1.01, 0, 0)).eql(black));
        try testing.expect(p.atObject(V.point(0.5, 0, 0)).eql(white));
    }
}

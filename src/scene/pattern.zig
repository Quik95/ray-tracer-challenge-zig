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
const float = @import("../math/float.zig");

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

        /// Which cell of the unit grid a coordinate falls in.
        ///
        /// Not simply `@floor`. A surface laid along a cell boundary is the
        /// ordinary case — a floor sits at y = 0, which is a boundary in y —
        /// and the coordinate that arrives here is that zero plus whatever
        /// round-off the ray's own arithmetic left behind, a hair either side
        /// of it. `@floor` is discontinuous exactly there and reads a
        /// negative hair as a whole cell down, so the surface comes out
        /// speckled with pixels belonging to its neighbour.
        ///
        /// Pulling a coordinate that is within tolerance of a whole number
        /// onto that number first makes the whole surface agree. It moves the
        /// boundaries by the width of the tolerance, which no scene can see.
        inline fn cellOf(v: T) T {
            const whole = @round(v);
            return if (float.feq(T, v, whole)) whole else @floor(v);
        }

        /// How a point on a surface is read as a place on a flat image.
        ///
        /// A solid pattern is a rule about all of space, and an object is
        /// coloured by whatever part of that space it happens to occupy. A
        /// mapping does the opposite: it hands the surface its own two
        /// coordinates, `u` around and `v` across, both running from zero to
        /// one, so that a picture can be wrapped onto the shape the way a
        /// label is wrapped onto a can.
        pub const Mapping = enum {
            /// Straight down onto the xz plane, repeating every unit. What a
            /// floor or a wall wants.
            planar,
            /// Longitude and latitude on the unit sphere, so that `u` goes
            /// once round the equator and `v` from the south pole to the
            /// north.
            spherical,
            /// Round the y axis for `u`, and straight up it for `v`, which
            /// leaves the ends of a cylinder to nothing in particular.
            cylindrical,

            /// The place on the image that `p` is coloured by.
            pub fn at(self: Mapping, p: Point) struct { T, T } {
                return switch (self) {
                    .planar => .{ fract(p.x()), fract(p.z()) },
                    .cylindrical => .{ around(p), fract(p.y()) },
                    .spherical => blk: {
                        const radius = p.magnitude();
                        // The angle down from the north pole, which is the
                        // latitude read the other way up.
                        const phi = std.math.acos(std.math.clamp(
                            if (radius == 0) @as(T, 0) else p.y() / radius,
                            -1,
                            1,
                        ));
                        break :blk .{ around(p), 1 - phi / std.math.pi };
                    },
                };
            }

            /// How far round the y axis a point lies, as a fraction of the
            /// whole turn, counted the way the surface is seen from outside.
            fn around(p: Point) T {
                const theta = std.math.atan2(p.x(), p.z());
                return 1 - (theta / (2 * std.math.pi) + 0.5);
            }

            /// The part of a number past its whole, kept positive so the
            /// pattern does not mirror itself about the origin.
            fn fract(v: T) T {
                return v - cellOf(v);
            }
        };

        /// Squares laid out on a surface's own two coordinates: `u` of them
        /// round it and `v` of them across.
        pub const UvCheckers = struct {
            pair: Pair = .{},
            map: Mapping = .planar,
            u: T = 2,
            v: T = 2,

            pub fn eql(x: UvCheckers, y: UvCheckers) bool {
                return x.pair.eql(y.pair) and x.map == y.map and
                    tuple.feq(T, x.u, y.u) and tuple.feq(T, x.v, y.v);
            }

            fn at(self: UvCheckers, p: Point) C {
                const u, const v = self.map.at(p);
                const squares = cellOf(u * self.u) + cellOf(v * self.v);
                return self.pair.pick(@mod(squares, 2) == 0);
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
            /// Squares laid out on the surface itself rather than in space.
            uv_checkers: UvCheckers,
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

        /// Squares wrapped onto the surface by `map`: `u` of them round it
        /// and `v` of them across, however large the object itself is.
        pub fn uvCheckers(map: Mapping, u: T, v: T, a: C, b: C) Self {
            return .{ .kind = .{ .uv_checkers = .{
                .pair = .{ .a = a, .b = b },
                .map = map,
                .u = u,
                .v = v,
            } } };
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
                .stripes => |pair| pair.pick(isEven(cellOf(p.x()))),
                .rings => |pair| pair.pick(isEven(cellOf(@sqrt(p.x() * p.x() + p.z() * p.z())))),
                // The sum of the three floors flips parity whenever any one
                // of them does, which is what makes neighbouring cubes differ.
                .checkers => |pair| pair.pick(isEven(cellOf(p.x()) + cellOf(p.y()) + cellOf(p.z()))),
                // The fractional part of x walks from a to b and snaps back,
                // so the blend repeats once per unit.
                .gradient => |pair| pair.a.add(pair.b.sub(pair.a).mul(p.x() - cellOf(p.x()))),
                // Where a solid checker asks where in space the point is,
                // this one asks where on the surface it is.
                .uv_checkers => |squares| squares.at(p),
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

test "a planar mapping repeats every unit of the floor" {
    const p = Pat.uvCheckers(.planar, 2, 2, white, black);
    try testing.expect(p.at(V.point(0.25, 0, 0.25)).eql(white));
    try testing.expect(p.at(V.point(0.75, 0, 0.25)).eql(black));
    try testing.expect(p.at(V.point(0.25, 0, 0.75)).eql(black));
    try testing.expect(p.at(V.point(0.75, 0, 0.75)).eql(white));
    // Height makes no difference to it, and neither does which unit square
    // the point lies in.
    try testing.expect(p.at(V.point(1.25, 9, 3.25)).eql(white));
    try testing.expect(p.at(V.point(-0.75, 0, -0.75)).eql(white));
}

test "a spherical mapping runs u round the equator and v up the poles" {
    const p = Pat.uvCheckers(.spherical, 4, 2, white, black);
    // Round the equator, a quarter turn at a time: the squares alternate.
    try testing.expect(p.at(V.point(0, 0, -1)).eql(black));
    try testing.expect(p.at(V.point(1, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(0, 0, 1)).eql(black));
    try testing.expect(p.at(V.point(-1, 0, 0)).eql(white));
    // The two poles are on opposite sides of the one division in v.
    try testing.expect(!p.at(V.point(0, 1, 0)).eql(p.at(V.point(0, -1, 0))));
}

test "a cylindrical mapping runs u round the side and v up it" {
    const p = Pat.uvCheckers(.cylindrical, 2, 2, white, black);
    const front_low = p.at(V.point(0, 0.25, -1));
    // Half a turn away, and half a unit higher: each flips the square.
    try testing.expect(!p.at(V.point(0, 0.25, 1)).eql(front_low));
    try testing.expect(!p.at(V.point(0, 0.75, -1)).eql(front_low));
    try testing.expect(p.at(V.point(0, 0.75, 1)).eql(front_low));
}

test "a mapped pattern is moved by its own transformation" {
    var p = Pat.uvCheckers(.planar, 2, 2, white, black);
    try testing.expect(p.atObject(V.point(0.25, 0, 0.25)).eql(white));
    // Stretched to twice its size, what fell in the first square now falls
    // in the same square at half the coordinates.
    p.setTransform(Tf.scaling(2, 2, 2));
    try testing.expect(p.atObject(V.point(0.5, 0, 0.5)).eql(white));
    try testing.expect(p.atObject(V.point(1.5, 0, 0.5)).eql(black));
}

test "mapped patterns differ when only their mapping does" {
    const a = Pat.uvCheckers(.spherical, 4, 2, white, black);
    const b = Pat.uvCheckers(.cylindrical, 4, 2, white, black);
    const c = Pat.uvCheckers(.spherical, 8, 2, white, black);
    try testing.expect(!a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(a.eql(a));
}

test "mapped patterns are evaluated at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const p = Pat.uvCheckers(.spherical, 4, 2, white, black);
        try testing.expect(p.at(V.point(0, 0, -1)).eql(black));
        try testing.expect(p.at(V.point(1, 0, 0)).eql(white));
    }
}

test "a surface lying along a cell boundary takes one colour, not two" {
    // A floor sits at y = 0, and the y that reaches the pattern is that zero
    // plus the round-off of the ray arithmetic that found the point. Flooring
    // it directly would send the negative side a whole cell down and speckle
    // the floor with its neighbour's colour.
    const p = Pat.checkers(white, black);
    const wanted = p.at(V.point(0.5, 0, 0.5));
    for ([_]f64{ 0, -0.0, 1e-17, -1e-17, 1e-12, -1e-12 }) |y| {
        try testing.expect(p.at(V.point(0.5, y, 0.5)).eql(wanted));
    }
}

test "cells still change where the coordinate really crosses a boundary" {
    const p = Pat.stripes(white, black);
    try testing.expect(p.at(V.point(0.5, 0, 0)).eql(white));
    try testing.expect(p.at(V.point(1.5, 0, 0)).eql(black));
    try testing.expect(p.at(V.point(-0.5, 0, 0)).eql(black));
}

//! Light sources.

const std = @import("std");
const color = @import("../render/color.zig");
const tuple = @import("../math/tuple.zig");

/// A light, either concentrated at a single point or spread over a rectangle.
/// Its intensity doubles as its color: a dim light and a light of a darker
/// color are the same thing to the shading maths.
///
/// A light with no size casts shadows with perfectly sharp outlines, because
/// a point either sees it or does not. Give the light a surface and the
/// answer stops being yes or no: some of the surface may be visible and the
/// rest hidden, and the shadow softens at its edge in proportion.
pub fn PointLight(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const C = color.Color(T);
        pub const Scalar = T;

        /// The rectangle a light of some size is spread over, sampled on a
        /// grid. `u` and `v` are one cell's worth of each edge, not the whole
        /// edge, so a sample is a cell count away from the corner.
        pub const Surface = struct {
            corner: Point,
            u: Point,
            usteps: usize,
            v: Point,
            vsteps: usize,

            pub inline fn samples(self: Surface) usize {
                return self.usteps * self.vsteps;
            }

            pub fn eql(a: Surface, b: Surface) bool {
                return a.corner.eql(b.corner) and a.u.eql(b.u) and a.v.eql(b.v) and
                    a.usteps == b.usteps and a.vsteps == b.vsteps;
            }
        };

        /// Where the light stands, and where a light of some size has its
        /// middle.
        position: Point,
        intensity: C,
        /// The surface the light is spread over, if it has any size at all.
        surface: ?Surface = null,

        pub inline fn init(position: Point, intensity: C) Self {
            return .{ .position = position, .intensity = intensity };
        }

        /// A light spread over the rectangle reaching from `corner` along the
        /// two full edge vectors, sampled `usteps` by `vsteps` times.
        pub fn area(
            corner: Point,
            u_edge: Point,
            usteps: usize,
            v_edge: Point,
            vsteps: usize,
            intensity: C,
        ) Self {
            std.debug.assert(usteps > 0 and vsteps > 0);
            return .{
                .position = corner.add(u_edge.mul(0.5)).add(v_edge.mul(0.5)),
                .intensity = intensity,
                .surface = .{
                    .corner = corner,
                    .u = u_edge.div(@floatFromInt(usteps)),
                    .usteps = usteps,
                    .v = v_edge.div(@floatFromInt(vsteps)),
                    .vsteps = vsteps,
                },
            };
        }

        /// How many places on the light a shadow ray is aimed at.
        pub inline fn samples(self: Self) usize {
            const s = self.surface orelse return 1;
            return s.samples();
        }

        /// The `i`th of those places, taken at the middle of its cell.
        pub fn sample(self: Self, i: usize) Point {
            return self.sampleWithin(i, 0.5, 0.5);
        }

        /// The `i`th place, taken `u_off` and `v_off` of the way across its
        /// cell rather than at the middle. Sampling the same grid the same
        /// way everywhere leaves rings where the count of visible samples
        /// steps up; moving the sample about inside its own cell trades those
        /// rings for a scatter the eye reads as grain.
        pub fn sampleWithin(self: Self, i: usize, u_off: T, v_off: T) Point {
            const s = self.surface orelse return self.position;
            const u = i % s.usteps;
            const v = i / s.usteps;
            return s.corner
                .add(s.u.mul(@as(T, @floatFromInt(u)) + u_off))
                .add(s.v.mul(@as(T, @floatFromInt(v)) + v_off));
        }

        pub fn eql(a: Self, b: Self) bool {
            if ((a.surface == null) != (b.surface == null)) return false;
            if (a.surface) |sa| if (!sa.eql(b.surface.?)) return false;
            return a.position.eql(b.position) and a.intensity.eql(b.intensity);
        }
    };
}

/// The light at the precision the ray tracer uses.
pub const Light = PointLight(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const Col = color.Col;

test "a point light has a position and an intensity" {
    const position = V.point(0, 0, 0);
    const intensity = Col.init(1, 1, 1);
    const light = Light.init(position, intensity);
    try testing.expect(light.position.eql(position));
    try testing.expect(light.intensity.eql(intensity));
}

test "a point light is sampled at the one place it stands" {
    const light = Light.init(V.point(1, 2, 3), Col.white);
    try testing.expectEqual(@as(usize, 1), light.samples());
    try testing.expect(light.sample(0).eql(V.point(1, 2, 3)));
}

test "an area light is centred on the rectangle it covers" {
    const light = Light.area(
        V.point(0, 0, 0),
        V.vector(2, 0, 0),
        4,
        V.vector(0, 0, 1),
        2,
        Col.white,
    );
    const s = light.surface orelse return error.MissingSurface;
    try testing.expect(s.corner.eql(V.point(0, 0, 0)));
    try testing.expect(s.u.eql(V.vector(0.5, 0, 0)));
    try testing.expect(s.v.eql(V.vector(0, 0, 0.5)));
    try testing.expectEqual(@as(usize, 8), light.samples());
    try testing.expect(light.position.eql(V.point(1, 0, 0.5)));
}

test "an area light is sampled at the middle of each of its cells" {
    const light = Light.area(
        V.point(0, 0, 0),
        V.vector(2, 0, 0),
        2,
        V.vector(0, 0, 1),
        2,
        Col.white,
    );
    const expected = [_]tuple.Tup{
        V.point(0.5, 0, 0.25),
        V.point(1.5, 0, 0.25),
        V.point(0.5, 0, 0.75),
        V.point(1.5, 0, 0.75),
    };
    for (expected, 0..) |want, i| {
        try testing.expect(light.sample(i).eql(want));
    }
}

test "lights of different shapes are never the same light" {
    const point = Light.init(V.point(1, 0, 0.5), Col.white);
    const spread = Light.area(V.point(0, 0, 0), V.vector(2, 0, 0), 2, V.vector(0, 0, 1), 2, Col.white);
    try testing.expect(point.position.eql(spread.position));
    try testing.expect(!point.eql(spread));
    try testing.expect(spread.eql(spread));
}

test "lights exist at comptime" {
    comptime {
        const light = Light.init(V.point(1, 2, 3), Col.white);
        try testing.expect(light.eql(Light.init(V.point(1, 2, 3), Col.white)));
        const spread = Light.area(V.point(0, 0, 0), V.vector(1, 0, 0), 2, V.vector(0, 0, 1), 2, Col.white);
        try testing.expect(spread.sample(3).eql(V.point(0.75, 0, 0.75)));
    }
}

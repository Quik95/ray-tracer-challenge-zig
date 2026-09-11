//! Light sources.

const std = @import("std");
const color = @import("../render/color.zig");
const tuple = @import("../math/tuple.zig");

/// A light with no size, all of it concentrated at a single point. Its
/// intensity doubles as its color: a dim light and a light of a darker color
/// are the same thing to the shading maths.
pub fn PointLight(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const C = color.Color(T);
        pub const Scalar = T;

        position: Point,
        intensity: C,

        pub inline fn init(position: Point, intensity: C) Self {
            return .{ .position = position, .intensity = intensity };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.position.eql(b.position) and a.intensity.eql(b.intensity);
        }
    };
}

/// The point light at the precision the ray tracer uses.
pub const Light = PointLight(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "a point light has a position and an intensity" {
    const position = tuple.Tup.point(0, 0, 0);
    const intensity = color.Col.init(1, 1, 1);
    const light = Light.init(position, intensity);
    try testing.expect(light.position.eql(position));
    try testing.expect(light.intensity.eql(intensity));
}

test "point lights exist at comptime" {
    comptime {
        const light = Light.init(tuple.Tup.point(1, 2, 3), color.Col.white);
        try testing.expect(light.eql(Light.init(tuple.Tup.point(1, 2, 3), color.Col.white)));
    }
}

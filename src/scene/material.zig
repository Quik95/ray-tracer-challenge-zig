//! Surface materials, and the Phong reflection model that shades them.
//!
//! Phong approximates a lit surface as the sum of three contributions:
//! ambient light that reaches the surface from everywhere at once, diffuse
//! light scattered by a matte surface, and a specular highlight â the mirror
//! image of the light source itself.

const std = @import("std");
const color_mod = @import("../render/color.zig");
const light_mod = @import("light.zig");
const pattern_mod = @import("pattern.zig");
const tuple = @import("../math/tuple.zig");

/// What a surface is made of, over a float type.
pub fn Material(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const C = color_mod.Color(T);
        pub const Point = tuple.Tuple(T);
        pub const Light = light_mod.PointLight(T);
        pub const Pattern = pattern_mod.Pattern(T);
        pub const Scalar = T;

        /// The color the surface reflects where no pattern overrides it.
        color: C = C.white,
        /// A rule colouring the surface by position, in place of `color`.
        pattern: ?Pattern = null,
        /// Share of the surface color present even where no light reaches.
        ambient: T = 0.1,
        /// Share scattered evenly, falling off with the angle to the light.
        diffuse: T = 0.9,
        /// Strength of the highlight where the light reflects into the eye.
        specular: T = 0.9,
        /// How tightly that highlight is focused. Small values spread it over
        /// the surface; large ones pull it into a pinpoint.
        shininess: T = 200.0,
        /// Share of what the surface mirrors back. Zero is a matte surface,
        /// one a perfect mirror, and anything between a partial reflection.
        reflective: T = 0.0,
        /// Share of what shows through the surface from behind it. Zero is
        /// opaque, one lets the scene behind show through entirely.
        transparency: T = 0.0,
        /// How strongly light bends on entering this material, relative to
        /// a vacuum. One leaves it straight; glass is about 1.5.
        refractive_index: T = 1.0,

        pub fn eql(a: Self, b: Self) bool {
            if ((a.pattern == null) != (b.pattern == null)) return false;
            if (a.pattern) |pa| if (!pa.eql(b.pattern.?)) return false;
            return a.color.eql(b.color) and
                tuple.feq(T, a.ambient, b.ambient) and
                tuple.feq(T, a.diffuse, b.diffuse) and
                tuple.feq(T, a.specular, b.specular) and
                tuple.feq(T, a.shininess, b.shininess) and
                tuple.feq(T, a.reflective, b.reflective) and
                tuple.feq(T, a.transparency, b.transparency) and
                tuple.feq(T, a.refractive_index, b.refractive_index);
        }

        /// The color the surface shows at a point given in the coordinates
        /// of the object wearing this material — where a pattern, if there
        /// is one, is written.
        pub fn colorAt(self: Self, object_point: Point) C {
            const p = self.pattern orelse return self.color;
            return p.atObject(object_point);
        }

        /// The color of this material at `point`, lit by `light` and seen
        /// along `eye`, where the surface faces `normal`. All three vectors
        /// are expected to be normalized. A point `in_shadow` sees none of
        /// the light directly, so only the ambient term reaches it.
        ///
        /// `point` is in world space, which is where the light stands;
        /// `object_point` is the same place in the object's own coordinates,
        /// which is where a pattern is read.
        pub fn lighting(
            self: Self,
            light: Light,
            point: Point,
            object_point: Point,
            eye: Point,
            normal: Point,
            in_shadow: bool,
        ) C {
            // A surface can only reflect what the light actually emits.
            const effective = self.colorAt(object_point).hadamard(light.intensity);
            const ambient = effective.mul(self.ambient);

            // Both remaining terms are answers to the light itself; where it
            // is blocked, neither has anything to answer.
            if (in_shadow) return ambient;

            const light_dir = light.position.sub(point).normalize();

            // The cosine of the angle to the light; negative means the light
            // is behind the surface, which leaves only the ambient term.
            const light_dot_normal = light_dir.dot(normal);
            if (light_dot_normal < 0) return ambient;

            const diffuse = effective.mul(self.diffuse * light_dot_normal);

            // Likewise for the highlight: the light has to bounce towards the
            // eye, not away from it, for any of it to be seen.
            const reflected = light_dir.neg().reflect(normal);
            const reflect_dot_eye = reflected.dot(eye);
            if (reflect_dot_eye <= 0) return ambient.add(diffuse);

            const factor = std.math.pow(T, reflect_dot_eye, self.shininess);
            const specular = light.intensity.mul(self.specular * factor);

            return ambient.add(diffuse).add(specular);
        }
    };
}

/// The material at the precision the ray tracer uses.
pub const Mat = Material(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const Col = color_mod.Col;
const V = tuple.Tup;
const L = light_mod.Light;

const half_root_two = @sqrt(2.0) / 2.0;

test "the default material" {
    const m: Mat = .{};
    try testing.expect(m.color.eql(Col.init(1, 1, 1)));
    try testing.expectEqual(@as(f64, 0.1), m.ambient);
    try testing.expectEqual(@as(f64, 0.9), m.diffuse);
    try testing.expectEqual(@as(f64, 0.9), m.specular);
    try testing.expectEqual(@as(f64, 200.0), m.shininess);
    try testing.expectEqual(@as(f64, 0.0), m.reflective);
    try testing.expectEqual(@as(f64, 0.0), m.transparency);
    try testing.expectEqual(@as(f64, 1.0), m.refractive_index);
}

test "lighting with the eye between the light and the surface" {
    const m: Mat = .{};
    const position = V.point(0, 0, 0);
    const eye = V.vector(0, 0, -1);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 0, -10), Col.white);
    try testing.expect(m.lighting(light, position, position, eye, normal, false).eql(Col.init(1.9, 1.9, 1.9)));
}

test "lighting with the eye offset 45 degrees loses the highlight" {
    const m: Mat = .{};
    const position = V.point(0, 0, 0);
    const eye = V.vector(0, half_root_two, -half_root_two);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 0, -10), Col.white);
    try testing.expect(m.lighting(light, position, position, eye, normal, false).eql(Col.init(1.0, 1.0, 1.0)));
}

test "lighting with the light offset 45 degrees dims the diffuse term" {
    const m: Mat = .{};
    const position = V.point(0, 0, 0);
    const eye = V.vector(0, 0, -1);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 10, -10), Col.white);
    const result = m.lighting(light, position, position, eye, normal, false);
    try testing.expect(result.eql(Col.init(0.7364, 0.7364, 0.7364)));
}

test "lighting with the eye in the path of the reflection" {
    const m: Mat = .{};
    const position = V.point(0, 0, 0);
    const eye = V.vector(0, -half_root_two, -half_root_two);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 10, -10), Col.white);
    const result = m.lighting(light, position, position, eye, normal, false);
    try testing.expect(result.eql(Col.init(1.6364, 1.6364, 1.6364)));
}

test "lighting with the light behind the surface leaves only ambient" {
    const m: Mat = .{};
    const position = V.point(0, 0, 0);
    const eye = V.vector(0, 0, -1);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 0, 10), Col.white);
    try testing.expect(m.lighting(light, position, position, eye, normal, false).eql(Col.init(0.1, 0.1, 0.1)));
}

test "the light's color tints what the surface reflects" {
    const m: Mat = .{ .color = Col.init(1, 1, 1) };
    const light = L.init(V.point(0, 0, -10), Col.init(1, 0, 0));
    const result = m.lighting(light, V.point(0, 0, 0), V.point(0, 0, 0), V.vector(0, 0, -1), V.vector(0, 0, -1), false);
    try testing.expect(result.eql(Col.init(1.9, 0, 0)));
}

test "lighting a surface in shadow leaves only ambient" {
    const m: Mat = .{};
    const position = V.point(0, 0, 0);
    const eye = V.vector(0, 0, -1);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 0, -10), Col.white);
    try testing.expect(m.lighting(light, position, position, eye, normal, true).eql(Col.init(0.1, 0.1, 0.1)));
}

test "materials shade at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const m: Mat = .{};
        const light = L.init(V.point(0, 0, -10), Col.white);
        const result = m.lighting(light, V.point(0, 0, 0), V.point(0, 0, 0), V.vector(0, 0, -1), V.vector(0, 0, -1), false);
        try testing.expect(result.eql(Col.init(1.9, 1.9, 1.9)));
    }
}

test "a patterned material takes its color from the pattern" {
    const m: Mat = .{
        .pattern = pattern_mod.Pat.stripes(Col.white, Col.black),
        .ambient = 1,
        .diffuse = 0,
        .specular = 0,
    };
    const eye = V.vector(0, 0, -1);
    const normal = V.vector(0, 0, -1);
    const light = L.init(V.point(0, 0, -10), Col.white);

    const c1 = m.lighting(light, V.point(0.9, 0, 0), V.point(0.9, 0, 0), eye, normal, false);
    const c2 = m.lighting(light, V.point(1.1, 0, 0), V.point(1.1, 0, 0), eye, normal, false);
    try testing.expect(c1.eql(Col.white));
    try testing.expect(c2.eql(Col.black));
}

test "materials differ when only their patterns do" {
    const a: Mat = .{ .pattern = pattern_mod.Pat.stripes(Col.white, Col.black) };
    const b: Mat = .{ .pattern = pattern_mod.Pat.stripes(Col.black, Col.white) };
    try testing.expect(!a.eql(b));
    try testing.expect(!a.eql(.{}));
    try testing.expect(a.eql(a));
}

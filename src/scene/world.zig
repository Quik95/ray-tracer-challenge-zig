//! A world: everything a ray can meet, and the light that shows it.
//!
//! The objects are a slice the caller owns, so a scene is built as a plain
//! array and handed over — the world never allocates.

const std = @import("std");
const color_mod = @import("../render/color.zig");
const light_mod = @import("light.zig");
const ray_mod = @import("ray.zig");
const shape_mod = @import("shape.zig");
const transform = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");

/// A scene of spheres lit by a single light, over a float type.
pub fn World(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const C = color_mod.Color(T);
        pub const Light = light_mod.PointLight(T);
        pub const Object = shape_mod.Shape(T);
        pub const Ray = ray_mod.Ray(T);
        pub const Hit = Object.Hit;
        pub const Comps = Hit.Computations;
        pub const Scalar = T;

        /// How many times a ray may be spawned again from what it meets
        /// before the tracer gives up and calls the result black. Mirrors
        /// facing each other would otherwise bounce a ray forever; a
        /// handful of bounces is already more than the eye can tell from
        /// an endless one.
        pub const max_bounces = 5;

        /// How many crossings of a single ray the shader works from. Every
        /// one is wanted, since which materials meet at the hit depends on
        /// the objects around it, but the buffer lives on the stack of a
        /// recursive call and so is bounded.
        pub const max_intersections = 64;

        objects: []const Object = &.{},
        /// A world with no light shows nothing; every surface comes out black.
        light: ?Light = null,

        /// Every crossing of `r` with every object, nearest first, written
        /// into `buf`. Each object contributes at most two, so a buffer of
        /// `2 * objects.len` always suffices; a shorter one stops early.
        pub fn intersect(self: Self, r: Ray, buf: []Hit) []Hit {
            var n: usize = 0;
            for (self.objects) |*object| {
                const xs = object.intersect(r);
                for (xs.items()) |x| {
                    if (n == buf.len) break;
                    buf[n] = x;
                    n += 1;
                }
                if (n == buf.len) break;
            }
            const found = buf[0..n];
            Hit.sort(found);
            return found;
        }

        /// The crossing the eye sees, found without collecting the rest —
        /// which is what the render loop wants, and what keeps it free of
        /// any scratch buffer.
        pub fn hit(self: Self, r: Ray) ?Hit {
            var closest: ?Hit = null;
            for (self.objects) |*object| {
                const xs = object.intersect(r);
                for (xs.items()) |x| {
                    if (x.t < 0) continue;
                    if (closest == null or x.t < closest.?.t) closest = x;
                }
            }
            return closest;
        }

        /// Whether something stands between `point` and the light. A world
        /// with no light shadows nothing: there is no light to block.
        pub fn isShadowed(self: Self, point: Object.Point) bool {
            const light = self.light orelse return false;

            const to_light = light.position.sub(point);
            const distance = to_light.magnitude();
            const r = Ray.init(point, to_light.normalize());

            // Only what lies short of the light itself casts a shadow here;
            // anything beyond it is behind the point's light source.
            const blocker = self.hit(r) orelse return false;
            return blocker.t < distance;
        }

        /// Shade a prepared crossing with this world's light.
        pub fn shadeHit(self: Self, comps: Comps) C {
            return self.shadeHitWithin(comps, max_bounces);
        }

        /// Shade a prepared crossing, with `bounces` further rays allowed to
        /// be cast from it.
        ///
        /// The surface answers the light directly; what it mirrors and what
        /// shows through it are two more rays, followed from here. A surface
        /// that both mirrors and transmits divides the light between the two
        /// by Fresnel's rule, rather than showing all of both — which would
        /// leave it brighter than the scene around it, and would black out
        /// wherever refraction fails.
        pub fn shadeHitWithin(self: Self, comps: Comps, bounces: usize) C {
            const light = self.light orelse return C.black;
            // A pattern is written in the object's own coordinates, so the
            // lit point is handed over in both; a collapsed object has no
            // object space left to speak of and falls back to world space.
            const object_point = comps.object.localPoint(comps.over_point) orelse comps.over_point;
            const surface = comps.object.material.lighting(
                light,
                comps.over_point,
                object_point,
                comps.eye,
                comps.normal,
                self.isShadowed(comps.over_point),
            );

            const reflected = self.reflectedColor(comps, bounces);
            const refracted = self.refractedColor(comps, bounces);

            const m = comps.object.material;
            if (m.reflective > 0 and m.transparency > 0) {
                const r = comps.reflectance();
                return surface.add(reflected.mul(r)).add(refracted.mul(1 - r));
            }
            return surface.add(reflected).add(refracted);
        }

        /// What the surface at `comps` mirrors, or black where it mirrors
        /// nothing — including once the ray has bounced as far as it may.
        pub fn reflectedColor(self: Self, comps: Comps, bounces: usize) C {
            const reflective = comps.object.material.reflective;
            if (bounces == 0 or reflective == 0) return C.black;

            const reflect_ray = Ray.init(comps.over_point, comps.reflect);
            return self.colorAtWithin(reflect_ray, bounces - 1).mul(reflective);
        }

        /// What shows through the surface at `comps` from behind it, or black
        /// where nothing does.
        ///
        /// Snell's law gives the direction the ray carries on in, from the
        /// refractive indices on either side of the surface. Where it has no
        /// solution the light cannot cross the interface at all — total
        /// internal reflection — and nothing is transmitted.
        pub fn refractedColor(self: Self, comps: Comps, bounces: usize) C {
            const transparency = comps.object.material.transparency;
            if (bounces == 0 or transparency == 0) return C.black;

            const n_ratio = comps.n1 / comps.n2;
            const cos_i = comps.eye.dot(comps.normal);
            const sin2_t = n_ratio * n_ratio * (1 - cos_i * cos_i);
            if (sin2_t > 1) return C.black;

            const cos_t = @sqrt(1 - sin2_t);
            const direction = comps.normal.mul(n_ratio * cos_i - cos_t)
                .sub(comps.eye.mul(n_ratio));

            const refract_ray = Ray.init(comps.under_point, direction);
            return self.colorAtWithin(refract_ray, bounces - 1).mul(transparency);
        }

        /// What the eye sees along `r`: black where the ray meets nothing.
        pub fn colorAt(self: Self, r: Ray) C {
            return self.colorAtWithin(r, max_bounces);
        }

        /// What the eye sees along `r`, with `bounces` further rays allowed
        /// to be cast from whatever it meets.
        ///
        /// Every crossing of the ray is collected, not just the nearest one:
        /// which materials meet at the hit is a question about the objects
        /// the hit lies inside of, and only the whole list answers it.
        pub fn colorAtWithin(self: Self, r: Ray, bounces: usize) C {
            var buf: [max_intersections]Hit = undefined;
            const xs = self.intersect(r, &buf);
            const nearest = Hit.hit(xs) orelse return C.black;
            const comps = nearest.prepareAmong(r, xs) orelse return C.black;
            return self.shadeHitWithin(comps, bounces);
        }
    };
}

/// The world at the precision the ray tracer uses.
pub const W = World(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const Col = color_mod.Col;
const L = light_mod.Light;
const R = ray_mod.R;
const Sh = shape_mod.Sh;
const Tf = transform.Tf;
const V = tuple.Tup;

/// The two concentric spheres the chapter's scenarios are posed against: a
/// unit sphere and a half-size one inside it.
fn defaultObjects() [2]Sh {
    return .{
        .{ .material = .{ .color = Col.init(0.8, 1.0, 0.6), .diffuse = 0.7, .specular = 0.2 } },
        .{ .id = 1, .transform = Tf.scaling(0.5, 0.5, 0.5) },
    };
}

fn defaultWorld(objects: []const Sh) W {
    return .{
        .objects = objects,
        .light = L.init(V.point(-10, 10, -10), Col.white),
    };
}

test "a fresh world holds nothing and shows nothing" {
    const w: W = .{};
    try testing.expectEqual(@as(usize, 0), w.objects.len);
    try testing.expect(w.light == null);
    try testing.expect(w.colorAt(R.init(V.point(0, 0, -5), V.vector(0, 0, 1))).eql(Col.black));
}

test "intersecting a world collects every crossing in order" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));

    var buf: [4]W.Hit = undefined;
    const xs = w.intersect(r, &buf);
    try testing.expectEqual(@as(usize, 4), xs.len);
    try testing.expectEqual(@as(f64, 4), xs[0].t);
    try testing.expectEqual(@as(f64, 4.5), xs[1].t);
    try testing.expectEqual(@as(f64, 5.5), xs[2].t);
    try testing.expectEqual(@as(f64, 6), xs[3].t);
}

test "shading an intersection from outside" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const comps = W.Hit.init(4, &objects[0]).prepare(r).?;
    try testing.expect(w.shadeHit(comps).eql(Col.init(0.38066, 0.47583, 0.2855)));
}

test "shading an intersection from inside" {
    const objects = defaultObjects();
    var w = defaultWorld(&objects);
    w.light = L.init(V.point(0, 0.25, 0), Col.white);
    const r = R.init(V.point(0, 0, 0), V.vector(0, 0, 1));
    const comps = W.Hit.init(0.5, &objects[1]).prepare(r).?;
    try testing.expect(w.shadeHit(comps).eql(Col.init(0.90498, 0.90498, 0.90498)));
}

test "the color when a ray misses everything" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    const r = R.init(V.point(0, 0, -5), V.vector(0, 1, 0));
    try testing.expect(w.colorAt(r).eql(Col.black));
}

test "the color when a ray hits" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    try testing.expect(w.colorAt(r).eql(Col.init(0.38066, 0.47583, 0.2855)));
}

test "an intersection behind the ray is not the one shaded" {
    var objects = defaultObjects();
    objects[0].material.ambient = 1;
    objects[1].material.ambient = 1;
    const w = defaultWorld(&objects);

    // Between the two spheres, aimed at the inner one.
    const r = R.init(V.point(0, 0, 0.75), V.vector(0, 0, -1));
    try testing.expect(w.colorAt(r).eql(objects[1].material.color));
}

test "a world without a light shades everything black" {
    const objects = defaultObjects();
    const w: W = .{ .objects = &objects };
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    try testing.expect(w.colorAt(r).eql(Col.black));
}

test "worlds are shaded at comptime" {
    comptime {
        @setEvalBranchQuota(100_000);
        const objects = defaultObjects();
        const w = defaultWorld(&objects);
        const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
        try testing.expect(w.colorAt(r).eql(Col.init(0.38066, 0.47583, 0.2855)));
    }
}

test "nothing collinear with the point and the light casts a shadow" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    try testing.expect(!w.isShadowed(V.point(0, 10, 0)));
}

test "an object between the point and the light casts a shadow" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    try testing.expect(w.isShadowed(V.point(10, -10, 10)));
}

test "an object behind the light casts no shadow" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    try testing.expect(!w.isShadowed(V.point(-20, 20, -20)));
}

test "an object behind the point casts no shadow" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);
    try testing.expect(!w.isShadowed(V.point(-2, 2, -2)));
}

test "a world without a light shadows nothing" {
    const objects = defaultObjects();
    const w: W = .{ .objects = &objects };
    try testing.expect(!w.isShadowed(V.point(10, -10, 10)));
}

test "shading a crossing that lies in shadow leaves only ambient" {
    const objects = [2]Sh{
        .{},
        .{ .id = 1, .transform = Tf.translation(0, 0, 10) },
    };
    const w: W = .{
        .objects = &objects,
        .light = L.init(V.point(0, 0, -10), Col.white),
    };
    const r = R.init(V.point(0, 0, 5), V.vector(0, 0, 1));
    const comps = W.Hit.init(4, &objects[1]).prepare(r).?;
    try testing.expect(w.shadeHit(comps).eql(Col.init(0.1, 0.1, 0.1)));
}

test "a pattern on a transformed object moves with it" {
    // A striped sphere scaled by two: the stripes are twice as wide in the
    // world as they are on the sphere, so a point that would fall in the
    // second band lands in the first.
    var pattern = @import("pattern.zig").Pat.stripes(Col.white, Col.black);
    pattern.setTransform(Tf.scaling(0.5, 0.5, 0.5));
    const objects = [1]Sh{.{
        .transform = Tf.scaling(2, 2, 2),
        .material = .{ .pattern = pattern, .ambient = 1, .diffuse = 0, .specular = 0 },
    }};
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    try testing.expect(w.colorAt(r).eql(Col.white));
}

const half_root_two = @sqrt(2.0) / 2.0;

/// Compare against a color the book prints to five decimal places, truncated
/// rather than rounded, and shifted in its last digit by the epsilon-sized
/// offset that lifts a spawned ray off the surface. `eql` is tighter than
/// those figures are written.
fn expectColorNear(want: Col, got: Col) !void {
    const tolerance = 1e-4;
    inline for (.{ .red, .green, .blue }) |channel| {
        try testing.expectApproxEqAbs(want.get(channel), got.get(channel), tolerance);
    }
}

/// The default world with a plane laid under the spheres, which is what the
/// reflection and refraction scenarios need a surface for.
fn objectsWithFloor(floor_material: Sh.Mat) [3]Sh {
    const defaults = defaultObjects();
    return .{
        defaults[0],
        defaults[1],
        .{ .id = 2, .geometry = .{ .plane = .{} }, .transform = Tf.translation(0, -1, 0), .material = floor_material },
    };
}

test "a nonreflective surface mirrors nothing" {
    var objects = defaultObjects();
    objects[1].material.ambient = 1;
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, 0), V.vector(0, 0, 1));
    const comps = W.Hit.init(1, &objects[1]).prepare(r).?;
    try testing.expect(w.reflectedColor(comps, W.max_bounces).eql(Col.black));
}

test "a reflective surface mirrors what stands over it" {
    const objects = objectsWithFloor(.{ .reflective = 0.5 });
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -3), V.vector(0, -half_root_two, half_root_two));
    const comps = W.Hit.init(@sqrt(2.0), &objects[2]).prepare(r).?;
    try expectColorNear(Col.init(0.19032, 0.2379, 0.14274), w.reflectedColor(comps, W.max_bounces));
}

test "shading a reflective surface adds what it mirrors" {
    const objects = objectsWithFloor(.{ .reflective = 0.5 });
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -3), V.vector(0, -half_root_two, half_root_two));
    const comps = W.Hit.init(@sqrt(2.0), &objects[2]).prepare(r).?;
    try expectColorNear(Col.init(0.87677, 0.92436, 0.82918), w.shadeHit(comps));
}

test "a ray between two mirrors stops bouncing" {
    // Two perfect mirrors facing each other, and a ray sent straight up
    // between them: the bounce limit is the only thing that ends this.
    const objects = [2]Sh{
        .{ .id = 0, .geometry = .{ .plane = .{} }, .transform = Tf.translation(0, -1, 0), .material = .{ .reflective = 1 } },
        .{ .id = 1, .geometry = .{ .plane = .{} }, .transform = Tf.translation(0, 1, 0), .material = .{ .reflective = 1 } },
    };
    const w: W = .{ .objects = &objects, .light = L.init(V.point(0, 0, 0), Col.white) };

    _ = w.colorAt(R.init(V.point(0, 0, 0), V.vector(0, 1, 0)));
}

test "a surface mirrors nothing once the ray has bounced its last" {
    const objects = objectsWithFloor(.{ .reflective = 0.5 });
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -3), V.vector(0, -half_root_two, half_root_two));
    const comps = W.Hit.init(@sqrt(2.0), &objects[2]).prepare(r).?;
    try testing.expect(w.reflectedColor(comps, 0).eql(Col.black));
}

test "an opaque surface shows nothing behind it" {
    const objects = defaultObjects();
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const xs = [_]W.Hit{ W.Hit.init(4, &objects[0]), W.Hit.init(6, &objects[0]) };
    const comps = xs[0].prepareAmong(r, &xs).?;
    try testing.expect(w.refractedColor(comps, W.max_bounces).eql(Col.black));
}

test "a transparent surface shows nothing once the ray has bounced its last" {
    var objects = defaultObjects();
    objects[0].material.transparency = 1.0;
    objects[0].material.refractive_index = 1.5;
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const xs = [_]W.Hit{ W.Hit.init(4, &objects[0]), W.Hit.init(6, &objects[0]) };
    const comps = xs[0].prepareAmong(r, &xs).?;
    try testing.expect(w.refractedColor(comps, 0).eql(Col.black));
}

test "nothing crosses a surface under total internal reflection" {
    var objects = defaultObjects();
    objects[0].material.transparency = 1.0;
    objects[0].material.refractive_index = 1.5;
    const w = defaultWorld(&objects);

    // Inside the glass, striking the surface past the critical angle.
    const r = R.init(V.point(0, 0, half_root_two), V.vector(0, 1, 0));
    const xs = [_]W.Hit{ W.Hit.init(-half_root_two, &objects[0]), W.Hit.init(half_root_two, &objects[0]) };
    const comps = xs[1].prepareAmong(r, &xs).?;
    try testing.expect(w.refractedColor(comps, W.max_bounces).eql(Col.black));
}

test "a transparent surface shows the scene behind it, bent" {
    // The outer sphere wears the pattern that reports the point it was asked
    // about, so the color coming back says where the refracted ray landed.
    var objects = defaultObjects();
    objects[0].material.ambient = 1.0;
    objects[0].material.pattern = .{ .kind = .position };
    objects[1].material.transparency = 1.0;
    objects[1].material.refractive_index = 1.5;
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, 0.1), V.vector(0, 1, 0));
    const xs = [_]W.Hit{
        W.Hit.init(-0.9899, &objects[0]), W.Hit.init(-0.4899, &objects[1]),
        W.Hit.init(0.4899, &objects[1]),  W.Hit.init(0.9899, &objects[0]),
    };
    const comps = xs[2].prepareAmong(r, &xs).?;
    try expectColorNear(Col.init(0, 0.99888, 0.04725), w.refractedColor(comps, W.max_bounces));
}

test "shading a transparent surface adds what shows through it" {
    const defaults = defaultObjects();
    const objects = [4]Sh{
        defaults[0],
        defaults[1],
        .{
            .id = 2,
            .geometry = .{ .plane = .{} },
            .transform = Tf.translation(0, -1, 0),
            .material = .{ .transparency = 0.5, .refractive_index = 1.5 },
        },
        .{
            .id = 3,
            .transform = Tf.translation(0, -3.5, -0.5),
            .material = .{ .color = Col.init(1, 0, 0), .ambient = 0.5 },
        },
    };
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -3), V.vector(0, -half_root_two, half_root_two));
    const xs = [_]W.Hit{W.Hit.init(@sqrt(2.0), &objects[2])};
    const comps = xs[0].prepareAmong(r, &xs).?;
    try expectColorNear(Col.init(0.93642, 0.68642, 0.68642), w.shadeHit(comps));
}

test "a surface both mirroring and transparent divides the light between the two" {
    const defaults = defaultObjects();
    const objects = [4]Sh{
        defaults[0],
        defaults[1],
        .{
            .id = 2,
            .geometry = .{ .plane = .{} },
            .transform = Tf.translation(0, -1, 0),
            .material = .{ .reflective = 0.5, .transparency = 0.5, .refractive_index = 1.5 },
        },
        .{
            .id = 3,
            .transform = Tf.translation(0, -3.5, -0.5),
            .material = .{ .color = Col.init(1, 0, 0), .ambient = 0.5 },
        },
    };
    const w = defaultWorld(&objects);

    const r = R.init(V.point(0, 0, -3), V.vector(0, -half_root_two, half_root_two));
    const xs = [_]W.Hit{W.Hit.init(@sqrt(2.0), &objects[2])};
    const comps = xs[0].prepareAmong(r, &xs).?;
    try expectColorNear(Col.init(0.93391, 0.69643, 0.69243), w.shadeHit(comps));
}

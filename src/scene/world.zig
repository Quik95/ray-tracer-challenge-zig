//! A world: everything a ray can meet, and the light that shows it.
//!
//! The objects are a slice the caller owns, so a scene is built as a plain
//! array and handed over — the world never allocates.

const std = @import("std");
const color_mod = @import("../render/color.zig");
const light_mod = @import("light.zig");
const ray_mod = @import("ray.zig");
const sphere_mod = @import("sphere.zig");
const transform = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");

/// A scene of spheres lit by a single light, over a float type.
pub fn World(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const C = color_mod.Color(T);
        pub const Light = light_mod.PointLight(T);
        pub const Object = sphere_mod.Sphere(T);
        pub const Ray = ray_mod.Ray(T);
        pub const Hit = Object.Hit;
        pub const Comps = Hit.Computations;
        pub const Scalar = T;

        objects: []const Object = &.{},
        /// A world with no light shows nothing; every surface comes out black.
        light: ?Light = null,

        /// Every crossing of `r` with every object, nearest first, written
        /// into `buf`. Each object contributes at most two, so a buffer of
        /// `2 * objects.len` always suffices; a shorter one stops early.
        pub fn intersect(self: Self, r: Ray, buf: []Hit) []Hit {
            var n: usize = 0;
            for (self.objects) |*object| {
                const xs = object.intersect(r) orelse continue;
                for (xs) |x| {
                    if (n == buf.len) break;
                    buf[n] = x;
                    n += 1;
                }
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
                const xs = object.intersect(r) orelse continue;
                for (xs) |x| {
                    if (x.t < 0) continue;
                    if (closest == null or x.t < closest.?.t) closest = x;
                }
            }
            return closest;
        }

        /// Shade a prepared crossing with this world's light.
        pub fn shadeHit(self: Self, comps: Comps) C {
            const light = self.light orelse return C.black;
            return comps.object.material.lighting(
                light,
                comps.point,
                comps.eye,
                comps.normal,
            );
        }

        /// What the eye sees along `r`: black where the ray meets nothing.
        pub fn colorAt(self: Self, r: Ray) C {
            const nearest = self.hit(r) orelse return C.black;
            const comps = nearest.prepare(r) orelse return C.black;
            return self.shadeHit(comps);
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
const S = sphere_mod.S;
const Tf = transform.Tf;
const V = tuple.Tup;

/// The two concentric spheres the chapter's scenarios are posed against: a
/// unit sphere and a half-size one inside it.
fn defaultObjects() [2]S {
    return .{
        .{ .material = .{ .color = Col.init(0.8, 1.0, 0.6), .diffuse = 0.7, .specular = 0.2 } },
        .{ .id = 1, .transform = Tf.scaling(0.5, 0.5, 0.5) },
    };
}

fn defaultWorld(objects: []const S) W {
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

//! One checkered pattern, laid on three surfaces three different ways.
//!
//! A pattern written in space colours a shape by where its points happen to
//! fall, which suits a floor and fights a sphere. Mapping instead asks the
//! surface for its own two coordinates, so the same squares wrap a ball round
//! the equator and up to its poles, run round a cylinder and along its length,
//! and tile a plane flat — each of them evenly, and none of them sliced by the
//! shape's own curvature.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const color = @import("../render/color.zig");
const light_mod = @import("../scene/light.zig");
const pattern_mod = @import("../scene/pattern.zig");
const shape = @import("../scene/shape.zig");
const transform = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");
const world_mod = @import("../scene/world.zig");

/// The scene, over a float type.
pub fn Scene(comptime T: type) type {
    return struct {
        pub const C = color.Color(T);
        pub const Cam = camera_mod.Camera(T);
        pub const Light = light_mod.PointLight(T);
        pub const Object = shape.Shape(T);
        pub const Pattern = pattern_mod.Pattern(T);
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);

        pub const name = "texture-maps";
        pub const group = "texture";
        pub const object_count = 4;

        const light_grey = C.init(0.92, 0.92, 0.9);
        const dark = C.init(0.15, 0.2, 0.3);
        const warm = C.init(0.85, 0.4, 0.2);

        fn mapped(map: Pattern.Mapping, u: T, v: T, a: C, b: C) Object.Mat {
            return .{
                .diffuse = 0.75,
                .specular = 0.2,
                .shininess = 60,
                .pattern = Pattern.uvCheckers(map, u, v, a, b),
            };
        }

        /// The floor tiled flat, then the ball, the cylinder, and a smaller
        /// ball wearing the squares finer to show the count is the pattern's
        /// own rather than the shape's.
        pub fn objects() [object_count]Object {
            return .{
                .{
                    .geometry = .{ .plane = .{} },
                    .material = mapped(.planar, 2, 2, light_grey, dark),
                },
                .{
                    .geometry = .{ .sphere = .{} },
                    .transform = Tf.translation(-1.4, 1, 0.4),
                    .material = mapped(.spherical, 16, 8, light_grey, dark),
                },
                .{
                    .geometry = .{ .cylinder = .{ .minimum = 0, .maximum = 2, .closed = true } },
                    .transform = Tf.chain().scale(0.7, 1, 0.7).translate(1.5, 0, -0.2).m,
                    .material = mapped(.cylindrical, 12, 6, light_grey, warm),
                },
                .{
                    .geometry = .{ .sphere = .{} },
                    .transform = Tf.chain().scale(0.5, 0.5, 0.5).translate(0.1, 0.5, -1.6).m,
                    .material = mapped(.spherical, 6, 3, light_grey, warm),
                },
            };
        }

        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.init(V.point(-4, 6, -5), C.init(1, 1, 1)),
            };
        }

        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            // Squares this fine alias badly against the pixel grid, so every
            // pixel is worth more than one ray.
            c.supersample = 3;
            c.transform = Tf.view(
                V.point(0, 2.2, -5.5),
                V.point(0, 0.9, 0),
                V.vector(0, 1, 0),
            );
            return c;
        }
    };
}

pub const Default = Scene(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const P = tuple.Tup;

test "every surface in the scene is textured by its own coordinates" {
    const objects = Default.objects();
    for (objects) |o| {
        const p = o.material.pattern orelse return error.MissingPattern;
        try testing.expect(p.kind == .uv_checkers);
    }
}

test "the three mappings are each shown once over" {
    const objects = Default.objects();
    try testing.expectEqual(
        pattern_mod.Pattern(f64).Mapping.planar,
        objects[0].material.pattern.?.kind.uv_checkers.map,
    );
    try testing.expectEqual(
        pattern_mod.Pattern(f64).Mapping.spherical,
        objects[1].material.pattern.?.kind.uv_checkers.map,
    );
    try testing.expectEqual(
        pattern_mod.Pattern(f64).Mapping.cylindrical,
        objects[2].material.pattern.?.kind.uv_checkers.map,
    );
}

test "the squares on a ball alternate round it" {
    const objects = Default.objects();
    const p = objects[1].material.pattern.?;
    // Sixteen squares round the equator: one square along is the other
    // colour, and two are back to the first.
    const front = p.atObject(P.point(0, 0, -1));
    try testing.expect(!p.atObject(P.point(@sin(std.math.pi / 8.0), 0, -@cos(std.math.pi / 8.0))).eql(front));
    try testing.expect(p.atObject(P.point(@sin(std.math.pi / 4.0), 0, -@cos(std.math.pi / 4.0))).eql(front));
}

test "the camera finds a textured surface in the centre of the frame" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(20, 10);
    const h = w.hit(c.rayForPixel(10, 5).?) orelse return error.LookingAtNothing;
    try testing.expect(h.object.material.pattern != null);
}

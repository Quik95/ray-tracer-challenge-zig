//! Two balls under a light with a surface, and the fuzzy shadows it leaves.
//!
//! A light concentrated at a point is either seen from a place or hidden from
//! it, so the shadows it casts have hard outlines. The lamp overhead here has
//! size instead: near the middle of a shadow none of it shows, out at the rim
//! some of its samples come into view and the rest stay hidden, and the shade
//! lifts gradually between the two. A pale cube stands in for the lamp itself,
//! lit from within so it reads as the source of everything below it.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const color = @import("../render/color.zig");
const light_mod = @import("../scene/light.zig");
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
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);

        pub const name = "soft-shadows";
        pub const group = "light";
        pub const object_count = 4;

        /// The rectangle the light covers, hanging level above the scene, and
        /// how finely it is sampled. Every sample is another shadow ray per
        /// lit point, so the count buys smoothness at a price.
        pub const corner = [3]T{ -1.25, 3.6, -2.2 };
        pub const u_edge = [3]T{ 2.5, 0, 0 };
        pub const v_edge = [3]T{ 0, 0, 2.5 };
        pub const usteps = 6;
        pub const vsteps = 6;

        /// Matte, so the floor shows the shadows rather than the reflections.
        const floor: Object.Mat = .{
            .color = C.init(0.85, 0.84, 0.82),
            .diffuse = 0.9,
            .specular = 0,
        };

        /// The lamp's own body: unlit by anything, and bright of itself.
        const lamp: Object.Mat = .{
            .color = C.init(1, 1, 1),
            .ambient = 1,
            .diffuse = 0,
            .specular = 0,
        };

        fn ball(t: Object.M, c: C) Object {
            return .{
                .transform = t,
                .material = .{ .color = c, .diffuse = 0.8, .specular = 0.3, .shininess = 80 },
            };
        }

        /// The floor, the lamp standing in for the light, then the two balls
        /// whose shadows it spreads.
        pub fn objects() [object_count]Object {
            return .{
                .{ .geometry = .{ .plane = .{} }, .material = floor },
                .{
                    .geometry = .{ .cube = .{} },
                    // Flattened onto the rectangle the light covers, and
                    // lifted just clear of it so the lamp never stands in the
                    // way of the light it marks.
                    .transform = Tf.chain()
                        .scale(u_edge[0] / 2, 0.02, v_edge[2] / 2)
                        .translate(
                            corner[0] + u_edge[0] / 2,
                            corner[1] + 0.05,
                            corner[2] + v_edge[2] / 2,
                        ).m,
                    .material = lamp,
                },
                ball(Tf.translation(-0.8, 1, 0), C.init(0.85, 0.3, 0.25)),
                ball(
                    Tf.chain().scale(0.6, 0.6, 0.6).translate(1.1, 0.6, -0.6).m,
                    C.init(0.25, 0.45, 0.8),
                ),
            };
        }

        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.area(
                    V.point(corner[0], corner[1], corner[2]),
                    V.vector(u_edge[0], u_edge[1], u_edge[2]),
                    usteps,
                    V.vector(v_edge[0], v_edge[1], v_edge[2]),
                    vsteps,
                    C.init(1.4, 1.4, 1.4),
                ),
            };
        }

        /// Low and near, where the shadows stretch towards the eye and their
        /// soft rims are widest.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            // The balls' outlines are what the shadows are read against, so
            // they are worth four rays a pixel rather than one.
            c.supersample = 2;
            c.transform = Tf.view(
                V.point(0, 1.6, -5),
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

test "the scene is lit by a light with a surface, sampled over a grid" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const light = w.light orelse return error.MissingLight;
    try testing.expectEqual(@as(usize, Default.usteps * Default.vsteps), light.samples());
    // The lamp hangs over the balls, which stand on the floor beneath it.
    try testing.expect(light.position.y() > 1);
}

test "the shadow under a ball fades rather than ending at a line" {
    const objects = Default.objects();
    const w = Default.world(&objects);

    // Straight under the near ball nothing of the light gets through;
    // well in front of them all of it does; and between the two the shadow
    // gives way by degrees rather than at once.
    try testing.expectEqual(@as(f64, 0), w.intensityAt(P.point(-0.8, 0.001, 0)));
    try testing.expectEqual(@as(f64, 1), w.intensityAt(P.point(0, 0.001, -4)));

    var partial: usize = 0;
    var x: f64 = -2.6;
    while (x < -0.8) : (x += 0.05) {
        const i = w.intensityAt(P.point(x, 0.001, 0));
        if (i > 0 and i < 1) partial += 1;
    }
    try testing.expect(partial > 4);
}

test "the lamp shines of itself, so the light shows where it comes from" {
    const objects = Default.objects();
    try testing.expect(objects[1].geometry == .cube);
    try testing.expectEqual(@as(f64, 1), objects[1].material.ambient);
}

test "the camera finds the near ball in the centre of the frame" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(20, 10);
    const h = w.hit(c.rayForPixel(10, 5).?) orelse return error.LookingAtNothing;
    try testing.expectEqual(&objects[2], h.object);
}

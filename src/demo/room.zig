//! Three balls in a corner, where everything is a sphere.
//!
//! The room has no flat surfaces of its own: the floor and the two walls are
//! spheres flattened almost to nothing and turned into place, which is enough
//! to stand on and lean against as long as the camera keeps its distance.

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

        pub const name = "room";
        pub const group = "scenes";
        pub const object_count = 6;

        /// Wide and thin: a sphere stretched flat enough that the part of it
        /// under the balls is level to within a fraction of a pixel.
        const slab = Tf.scaling(10, 0.01, 10);

        /// Plaster, near enough: barely tinted, and with no shine at all, so
        /// the walls stay quiet behind what stands in front of them.
        const plaster: Object.Mat = .{ .color = C.init(1, 0.9, 0.9), .specular = 0 };

        /// A ball that is only its colour: matte, with a small highlight.
        fn ball(t: Object.M, c: C) Object {
            return .{
                .transform = t,
                .material = .{ .color = c, .diffuse = 0.7, .specular = 0.3 },
            };
        }

        /// The floor and the two walls, then the balls standing on them.
        pub fn objects() [object_count]Object {
            const quarter = std.math.pi / 4.0;
            const right_angle = std.math.pi / 2.0;
            return .{
                .{ .transform = slab, .material = plaster },
                // Tipped upright, then swung apart so the two walls meet
                // behind the balls in a corner the camera looks into.
                .{
                    .transform = Tf.chain().scale(10, 0.01, 10)
                        .rotateX(right_angle).rotateY(-quarter).translate(0, 0, 5).m,
                    .material = plaster,
                },
                .{
                    .transform = Tf.chain().scale(10, 0.01, 10)
                        .rotateX(right_angle).rotateY(quarter).translate(0, 0, 5).m,
                    .material = plaster,
                },
                ball(Tf.translation(-0.5, 1, 0.5), C.init(0.1, 1, 0.5)),
                ball(
                    Tf.chain().scale(0.5, 0.5, 0.5).translate(1.5, 0.5, -0.5).m,
                    C.init(0.5, 1, 0.1),
                ),
                ball(
                    Tf.chain().scale(0.33, 0.33, 0.33).translate(-1.5, 0.33, -0.75).m,
                    C.init(1, 0.8, 0.1),
                ),
            };
        }

        /// Lit from above and to the left, looking at the objects the caller
        /// keeps alive.
        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.init(V.point(-10, 10, -10), C.init(1, 1, 1)),
            };
        }

        /// An eye standing on the floor a few units back, looking at the
        /// middle ball.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(V.point(0, 1.5, -5), V.point(0, 1, 0), V.vector(0, 1, 0));
            return c;
        }
    };
}

pub const Default = Scene(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "the room is built from spheres alone" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);
    for (objects) |object| try testing.expect(object.geometry == .sphere);
}

test "the flattened spheres are level enough to stand on" {
    const objects = Default.objects();
    const floor = objects[0];
    // Over the middle of the room the floor faces the sky; a hand-span to the
    // side it has barely tilted, which is what makes the sphere pass for one.
    try testing.expect(floor.normalAt(tuple.Tup.point(0, 0.01, 0)).?
        .eql(tuple.Tup.vector(0, 1, 0)));
    const off_centre = floor.normalAt(tuple.Tup.point(-0.5, 0.01, 0.5)).?;
    try testing.expect(off_centre.dot(tuple.Tup.vector(0, 1, 0)) > 0.999);
}

test "the camera looks into the corner and finds the middle ball" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(20, 10);
    const r = c.rayForPixel(10, 5).?;
    const h = w.hit(r) orelse return error.LookingAtNothing;
    try testing.expectEqual(&objects[3], h.object);
}

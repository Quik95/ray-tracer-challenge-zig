//! Three spheres resting in a corner, and the camera that looks at them.
//!
//! The room is built from spheres too: flattening one almost to nothing and
//! standing it up gives a floor or a wall, which saves needing a second kind
//! of shape to put the scene in a room.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const color = @import("../render/color.zig");
const light_mod = @import("../scene/light.zig");
const sphere = @import("../scene/sphere.zig");
const transform = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");
const world_mod = @import("../scene/world.zig");

/// The scene, over a float type.
pub fn Scene(comptime T: type) type {
    return struct {
        pub const C = color.Color(T);
        pub const Cam = camera_mod.Camera(T);
        pub const Light = light_mod.PointLight(T);
        pub const Object = sphere.Sphere(T);
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);

        pub const object_count = 6;

        /// The matte, barely reflective surface the room is made of.
        const room_material: Object.Mat = .{ .color = C.init(1, 0.9, 0.9), .specular = 0 };

        /// The floor and the two walls behind it, then the three balls.
        pub fn objects() [object_count]Object {
            const wall = Tf.chain().scale(10, 0.01, 10).rotateX(std.math.pi / 2.0);
            return .{
                .{
                    .id = 0,
                    .transform = Tf.scaling(10, 0.01, 10),
                    .material = room_material,
                },
                .{
                    .id = 1,
                    .transform = wall.rotateY(-std.math.pi / 4.0).translate(0, 0, 5).m,
                    .material = room_material,
                },
                .{
                    .id = 2,
                    .transform = wall.rotateY(std.math.pi / 4.0).translate(0, 0, 5).m,
                    .material = room_material,
                },
                .{
                    .id = 3,
                    .transform = Tf.translation(-0.5, 1, 0.5),
                    .material = .{ .color = C.init(0.1, 1, 0.5), .diffuse = 0.7, .specular = 0.3 },
                },
                .{
                    .id = 4,
                    .transform = Tf.chain().scale(0.5, 0.5, 0.5).translate(1.5, 0.5, -0.5).m,
                    .material = .{ .color = C.init(0.5, 1, 0.1), .diffuse = 0.7, .specular = 0.3 },
                },
                .{
                    .id = 5,
                    .transform = Tf.chain().scale(0.33, 0.33, 0.33).translate(-1.5, 0.33, -0.75).m,
                    .material = .{ .color = C.init(1, 0.8, 0.1), .diffuse = 0.7, .specular = 0.3 },
                },
            };
        }

        /// The scene lit from above and to the left, looking at the objects
        /// the caller keeps alive.
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

test "the scene stands three balls in a room" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);

    // The middle ball is a unit sphere lifted to rest on the floor.
    try testing.expect(objects[3].transform.mulTuple(tuple.Tup.point(0, -1, 0))
        .eql(tuple.Tup.point(-0.5, 0, 0.5)));
}

test "the camera looks at the middle ball from in front of it" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(20, 10);

    // The centre of the frame lands on something, not on empty space.
    const r = c.rayForPixel(10, 5).?;
    try testing.expect(w.hit(r) != null);
}

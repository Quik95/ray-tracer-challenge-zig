//! The same three balls, now on a real floor.
//!
//! A plane is flat everywhere and endless in both directions, so the room no
//! longer has to be faked out of stretched spheres: one plane lies down for
//! the floor, a second stands on edge behind the balls for the backdrop, and
//! neither has an edge the camera can find.

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

        pub const name = "planes";
        pub const group = "scenes";
        pub const object_count = 5;

        const plaster: Object.Mat = .{ .color = C.init(1, 0.9, 0.9), .specular = 0 };

        fn ball(t: Object.M, c: C) Object {
            return .{
                .transform = t,
                .material = .{ .color = c, .diffuse = 0.7, .specular = 0.3 },
            };
        }

        /// The floor, the backdrop behind it, then the balls.
        pub fn objects() [object_count]Object {
            return .{
                .{ .geometry = .{ .plane = .{} }, .material = plaster },
                // A plane lies in the xz plane where it is written, so the
                // backdrop is one tipped upright and pushed away from the eye.
                .{
                    .geometry = .{ .plane = .{} },
                    .transform = Tf.chain().rotateX(std.math.pi / 2.0).translate(0, 0, 5).m,
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

        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.init(V.point(-10, 10, -10), C.init(1, 1, 1)),
            };
        }

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

test "the room is two planes and three balls" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);
    try testing.expect(objects[0].geometry == .plane);
    try testing.expect(objects[1].geometry == .plane);
    for (objects[2..]) |object| try testing.expect(object.geometry == .sphere);
}

test "the floor faces up and the backdrop faces the eye" {
    const objects = Default.objects();
    try testing.expect(objects[0].normalAt(tuple.Tup.point(9, 0, -4)).?
        .eql(tuple.Tup.vector(0, 1, 0)));
    // Tipping the plane upright turns its normal to face along z; which of
    // the two faces of a plane a normal points out of does not matter to the
    // shading, which flips it towards the eye when it has to.
    try testing.expect(objects[1].normalAt(tuple.Tup.point(2, 3, 5)).?
        .eql(tuple.Tup.vector(0, 0, 1)));
}

test "the balls rest on the floor rather than sinking into it" {
    const objects = Default.objects();
    // The lowest point of each ball is its centre pushed straight down.
    for (objects[2..]) |object| {
        const bottom = object.transform.mulTuple(tuple.Tup.point(0, -1, 0));
        try testing.expect(tuple.feq(f64, bottom.y(), 0));
    }
}

test "the camera finds the middle ball in the centre of the frame" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(20, 10);
    const h = w.hit(c.rayForPixel(10, 5).?) orelse return error.LookingAtNothing;
    try testing.expectEqual(&objects[2], h.object);
}

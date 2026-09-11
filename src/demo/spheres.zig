//! Three spheres resting on a floor, and the camera that looks at them.
//!
//! The room is two planes: one lying flat for the floor, one stood on edge
//! behind the balls for the backdrop. The floor is faintly polished and one
//! of the balls is glass, so part of the scene is made of the rest of it.

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
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);
        pub const Pattern = pattern_mod.Pattern(T);

        pub const object_count = 5;

        /// The surface the room is made of: matte, and just polished enough
        /// to catch a soft image of what stands on it.
        fn roomMaterial(p: Pattern) Object.Mat {
            return .{ .color = C.init(1, 0.9, 0.9), .specular = 0, .reflective = 0.15, .pattern = p };
        }

        /// A tiled floor, and a wall of narrow vertical bands behind it.
        const floor_pattern: Pattern = .{
            .transform = Tf.scaling(0.5, 0.5, 0.5),
            .kind = .{ .checkers = .{ .a = C.init(0.9, 0.9, 0.9), .b = C.init(0.35, 0.35, 0.4) } },
        };
        const wall_pattern: Pattern = .{
            .transform = Tf.scaling(0.25, 0.25, 0.25),
            .kind = .{ .stripes = .{ .a = C.init(1, 0.9, 0.9), .b = C.init(0.7, 0.55, 0.55) } },
        };

        /// The floor and the wall behind it, then the three balls.
        pub fn objects() [object_count]Object {
            return .{
                .{
                    .id = 0,
                    .geometry = .{ .plane = .{} },
                    .material = roomMaterial(floor_pattern),
                },
                .{
                    .id = 1,
                    .geometry = .{ .plane = .{} },
                    .transform = Tf.chain().rotateX(std.math.pi / 2.0).translate(0, 0, 5).m,
                    .material = roomMaterial(wall_pattern),
                },
                .{
                    .id = 2,
                    .transform = Tf.translation(-0.5, 1, 0.5),
                    .material = .{
                        .diffuse = 0.7,
                        .specular = 0.3,
                        // Rings lying flat would band the ball horizontally;
                        // tipping and shrinking them wraps it instead.
                        .pattern = .{
                            .transform = Tf.chain().scale(0.25, 0.25, 0.25).rotateX(std.math.pi / 3.0).m,
                            .kind = .{ .rings = .{ .a = C.init(0.1, 1, 0.5), .b = C.init(0.05, 0.4, 0.25) } },
                        },
                    },
                },
                // A marble of glass. Its own color is nearly black: what it
                // shows is the room behind and around it, not itself, and a
                // brighter surface would drown that out. Being mirrored as
                // well as clear is what fills in the rim, where the light
                // stops crossing the surface and is turned back instead.
                .{
                    .id = 3,
                    .transform = Tf.chain().scale(0.5, 0.5, 0.5).translate(1.5, 0.5, -0.5).m,
                    .material = .{
                        .color = C.init(0.05, 0.05, 0.06),
                        .ambient = 0.05,
                        .diffuse = 0.1,
                        .specular = 1,
                        .shininess = 300,
                        .reflective = 0.9,
                        .transparency = 0.9,
                        .refractive_index = 1.5,
                    },
                },
                .{
                    .id = 4,
                    .transform = Tf.chain().scale(0.33, 0.33, 0.33).translate(-1.5, 0.33, -0.75).m,
                    .material = .{
                        .diffuse = 0.7,
                        .specular = 0.3,
                        .pattern = .{
                            .transform = Tf.scaling(0.2, 0.2, 0.2),
                            .kind = .{ .stripes = .{ .a = C.init(1, 0.8, 0.1), .b = C.init(0.6, 0.3, 0.05) } },
                        },
                    },
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

test "the scene stands three balls on a floor" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);

    // The middle ball is a unit sphere lifted to rest on the floor.
    try testing.expect(objects[2].transform.mulTuple(tuple.Tup.point(0, -1, 0))
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

test "the floor is a plane the balls stand on" {
    const objects = Default.objects();
    try testing.expect(objects[0].geometry == .plane);
    try testing.expect(objects[0].normalAt(tuple.Tup.point(7, 0, -3)).?
        .eql(tuple.Tup.vector(0, 1, 0)));
}

test "the floor is tiled, and the tiles alternate" {
    const objects = Default.objects();
    const floor = objects[0].material;
    try testing.expect(floor.pattern != null);
    try testing.expect(!floor.colorAt(tuple.Tup.point(0.25, 0, 0.25))
        .eql(floor.colorAt(tuple.Tup.point(0.75, 0, 0.25))));
}

test "one of the balls is glass, and shows the room through it" {
    const objects = Default.objects();
    const glass = objects[3].material;
    try testing.expect(glass.transparency > 0.5);
    try testing.expect(glass.reflective > 0.5);
    try testing.expect(glass.refractive_index > 1);

    // A ray aimed at the glass ball comes back with more than the ball's own
    // near-black surface on it.
    const w = Default.world(&objects);
    const r = @import("../scene/ray.zig").R.init(tuple.Tup.point(1.5, 0.5, -5), tuple.Tup.vector(0, 0, 1));
    try testing.expect(!w.colorAt(r).eql(glass.color));
}

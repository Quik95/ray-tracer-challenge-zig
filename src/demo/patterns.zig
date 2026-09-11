//! The four patterns, all in one room.
//!
//! Nothing here is a plain colour: the floor is checkered, the backdrop is
//! striped, and each ball wears a different rule — rings, a gradient, stripes
//! of its own — so that one image shows how each pattern behaves both on a
//! flat surface and wrapped around a curved one.

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

        pub const name = "patterns";
        pub const group = "scenes";
        pub const object_count = 5;

        /// A pattern is written in its own space and then placed, so the
        /// floor's squares are sized here rather than at every point of it.
        const floor_pattern: Pattern = .{
            .transform = Tf.scaling(0.5, 0.5, 0.5),
            .kind = .{ .checkers = .{ .a = C.init(0.9, 0.9, 0.9), .b = C.init(0.25, 0.3, 0.35) } },
        };
        /// Stripes run along x, so a backdrop tipped upright bands vertically.
        const wall_pattern: Pattern = .{
            .transform = Tf.scaling(0.25, 0.25, 0.25),
            .kind = .{ .stripes = .{ .a = C.init(1, 0.9, 0.9), .b = C.init(0.65, 0.5, 0.5) } },
        };

        fn room(p: Pattern) Object.Mat {
            return .{ .specular = 0, .pattern = p };
        }

        fn ball(t: Object.M, p: Pattern) Object {
            return .{
                .transform = t,
                .material = .{ .diffuse = 0.7, .specular = 0.3, .pattern = p },
            };
        }

        pub fn objects() [object_count]Object {
            return .{
                .{
                    .geometry = .{ .plane = .{} },
                    .material = room(floor_pattern),
                },
                .{
                    .geometry = .{ .plane = .{} },
                    .transform = Tf.chain().rotateX(std.math.pi / 2.0).translate(0, 0, 5).m,
                    .material = room(wall_pattern),
                },
                // Rings lying flat would band the ball horizontally; tipping
                // and shrinking them wraps it instead.
                ball(Tf.translation(-0.5, 1, 0.5), .{
                    .transform = Tf.chain().scale(0.25, 0.25, 0.25).rotateX(std.math.pi / 3.0).m,
                    .kind = .{ .rings = .{ .a = C.init(0.1, 1, 0.5), .b = C.init(0.05, 0.4, 0.25) } },
                }),
                // A gradient runs from one colour to the other across a single
                // unit of x, so it is stretched to span the whole ball.
                ball(Tf.chain().scale(0.5, 0.5, 0.5).translate(1.5, 0.5, -0.5).m, .{
                    .transform = Tf.chain().scale(2, 2, 2).translate(-1, 0, 0).m,
                    .kind = .{ .gradient = .{ .a = C.init(0.9, 1, 0.2), .b = C.init(0.1, 0.4, 0.8) } },
                }),
                ball(Tf.chain().scale(0.33, 0.33, 0.33).translate(-1.5, 0.33, -0.75).m, .{
                    .transform = Tf.chain().scale(0.2, 0.2, 0.2).rotateZ(std.math.pi / 4.0).m,
                    .kind = .{ .stripes = .{ .a = C.init(1, 0.8, 0.1), .b = C.init(0.6, 0.3, 0.05) } },
                }),
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

test "everything in the room wears a pattern" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);
    for (objects) |object| try testing.expect(object.material.pattern != null);
}

test "the four patterns are all represented" {
    const objects = Default.objects();
    var seen: [4]bool = @splat(false);
    for (objects) |object| switch (object.material.pattern.?.kind) {
        .stripes => seen[0] = true,
        .gradient => seen[1] = true,
        .rings => seen[2] = true,
        .checkers => seen[3] = true,
        // A position pattern is a debugging aid, not something to look at.
        else => {},
    };
    for (seen) |kind| try testing.expect(kind);
}

test "the floor's squares alternate at the size they were scaled to" {
    const objects = Default.objects();
    const floor = objects[0].material;
    try testing.expect(!floor.colorAt(tuple.Tup.point(0.25, 0, 0.25))
        .eql(floor.colorAt(tuple.Tup.point(0.75, 0, 0.25))));
}

test "the camera finds the middle ball in the centre of the frame" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(20, 10);
    const h = w.hit(c.rayForPixel(10, 5).?) orelse return error.LookingAtNothing;
    try testing.expectEqual(&objects[2], h.object);
}

//! A row of balls running away from the eye, with only one of them sharp.
//!
//! A pinhole camera takes in light through a hole just wide enough for a
//! single ray, so everything it sees is equally in focus. Widen the hole and
//! a pixel gathers light arriving from several directions at once: those
//! directions agree about whatever stands at the focal distance and disagree
//! about everything else, by more the further off it is. The ball the camera
//! is focused on therefore keeps its edges, and its neighbours lose theirs.

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

        pub const name = "focal-blur";
        pub const group = "lens";

        /// How many balls stand in the row, and which of them is the subject:
        /// the second, so that the blur is seen growing in both directions.
        pub const ball_count = 6;
        pub const subject = 1;
        pub const object_count = ball_count + 1;

        /// Where the eye stands, and where it looks.
        const eye = [3]T{ -5.0, 1.6, -6.0 };
        const looking_at = [3]T{ 1.0, 0.8, 2.0 };

        /// The row runs away from the eye and off to the right, so the balls
        /// stand clear of one another instead of hiding behind the first.
        fn ballAt(i: usize) Object {
            const step: T = @floatFromInt(i);
            const radius = 0.75;
            return .{
                .transform = Tf.chain()
                    .scale(radius, radius, radius)
                    .translate(-0.9 + step * 0.8, radius, -2.2 + step * 2.2).m,
                .material = .{
                    // Warm at the front of the row, cool at the back of it.
                    .color = C.init(
                        0.85 - step * 0.1,
                        0.3 + step * 0.07,
                        0.25 + step * 0.12,
                    ),
                    .diffuse = 0.75,
                    .specular = 0.4,
                    .shininess = 120,
                },
            };
        }

        /// The floor, then the row of balls standing on it.
        pub fn objects() [object_count]Object {
            var all: [object_count]Object = undefined;
            all[0] = .{
                .geometry = .{ .plane = .{} },
                .material = .{
                    .specular = 0,
                    .pattern = .{ .kind = .{ .checkers = .{
                        .a = C.init(0.82, 0.8, 0.78),
                        .b = C.init(0.5, 0.49, 0.47),
                    } } },
                },
            };
            for (all[1..], 0..) |*ball, i| ball.* = ballAt(i);
            return all;
        }

        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.init(V.point(-5, 7, -6), C.init(1, 1, 1)),
            };
        }

        /// How far ahead of the eye the subject stands: what the camera is
        /// focused on, and the one distance the picture is sharp at.
        pub fn focus() T {
            const ball = ballAt(subject).transform.mulTuple(V.point(0, 0, 0));
            return ball.sub(V.point(eye[0], eye[1], eye[2])).magnitude();
        }

        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(
                V.point(eye[0], eye[1], eye[2]),
                V.point(looking_at[0], looking_at[1], looking_at[2]),
                V.vector(0, 1, 0),
            );
            // Wide enough that the far end of the row goes soft, and sampled
            // finely enough that what it gathers reads as blur, not as noise.
            c.aperture = 0.5;
            c.focus = focus();
            c.supersample = 7;
            return c;
        }
    };
}

pub const Default = Scene(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const P = tuple.Tup;

test "the scene is a row of balls on a checkered floor" {
    const objects = Default.objects();
    try testing.expect(objects[0].geometry == .plane);
    try testing.expect(objects[0].material.pattern != null);
    for (objects[1..]) |ball| try testing.expect(ball.geometry == .sphere);
}

test "the balls stand on the floor, each further off than the last" {
    const objects = Default.objects();
    var last: f64 = -std.math.inf(f64);
    for (objects[1..]) |ball| {
        const centre = ball.transform.mulTuple(P.point(0, 0, 0));
        const bottom = ball.transform.mulTuple(P.point(0, -1, 0));
        try testing.expect(tuple.feq(f64, bottom.y(), 0));
        try testing.expect(centre.z() > last);
        last = centre.z();
    }
}

test "the camera is focused on the subject and opened wide" {
    const c = Default.camera(40, 20);
    try testing.expect(c.aperture > 0);
    try testing.expect(c.supersample > 1);

    // The focal distance is the distance to the subject itself, so the ball
    // the picture is about is the one thing standing exactly in focus.
    const objects = Default.objects();
    const centre = objects[1 + Default.subject].transform.mulTuple(P.point(0, 0, 0));
    const from_eye = (c.transform.inverse() catch unreachable).mulTuple(P.point(0, 0, 0));
    try testing.expect(tuple.feq(f64, c.focus, centre.sub(from_eye).magnitude()));
}

test "the row of balls is what the camera is pointed at" {
    const objects = Default.objects();
    const w = Default.world(&objects);
    const c = Default.camera(40, 20);
    const h = w.hit(c.rayForPixel(20, 10).?) orelse return error.LookingAtNothing;
    try testing.expect(h.object.geometry == .sphere or h.object.geometry == .plane);
}

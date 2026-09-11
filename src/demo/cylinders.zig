//! A colonnade: six columns on a polished floor, around a glass case.
//!
//! Everything standing here is a cylinder or a cone. A column is three of
//! them — a squat base, a tall shaft, and a capital that flares out to meet
//! the base's width again — and the case in the middle is an open tube of
//! glass with a spike of stone inside it, which is the pair of shapes the
//! chapter's caps and truncation are easiest to see in.

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

        pub const name = "cylinders";
        pub const group = "shapes";

        /// Where the columns stand: two rows, three deep.
        const column_x = 2.6;
        const column_z = [_]T{ -2, 1.5, 5 };
        pub const parts_per_column = 3;
        pub const column_count = 2 * column_z.len;
        pub const object_count = 1 + parts_per_column * column_count + 2;

        /// A column, from the floor up. The base and the capital are as wide
        /// as each other; the shaft between them is narrower, so both read as
        /// a collar rather than as more of the same stone.
        const base_radius = 0.45;
        const base_height = 0.16;
        const shaft_radius = 0.3;
        const shaft_height = 1.9;
        const shaft_top = base_height + shaft_height;

        /// A length of pipe standing on y = 0 in its own coordinates, so the
        /// transform that places it only has to say how tall and how wide.
        fn tube(t: Object.M, m: Object.Mat, closed: bool) Object {
            return .{
                .geometry = .{ .cylinder = .{ .minimum = 0, .maximum = 1, .closed = closed } },
                .transform = t,
                .material = m,
            };
        }

        /// A slice of the cone between two heights, kept at its own scale so
        /// that the radii it flares between are the heights themselves.
        fn frustum(t: Object.M, m: Object.Mat, min: T, max: T) Object {
            return .{
                .geometry = .{ .cone = .{ .minimum = min, .maximum = max, .closed = true } },
                .transform = t,
                .material = m,
            };
        }

        const stone: Object.Mat = .{
            .color = C.init(0.78, 0.75, 0.68),
            .diffuse = 0.75,
            .specular = 0.2,
            .shininess = 40,
        };

        /// Dark polished floor, in one-unit squares, holding just enough of a
        /// reflection to stand the columns on something.
        const floor: Object.Mat = .{
            .specular = 0.3,
            .shininess = 80,
            .reflective = 0.25,
            .pattern = .{
                .kind = .{ .checkers = .{
                    .a = C.init(0.18, 0.19, 0.22),
                    .b = C.init(0.42, 0.41, 0.38),
                } },
            },
        };

        fn column(x: T, z: T, out: *[parts_per_column]Object) void {
            out.* = .{
                tube(
                    Tf.chain().scale(base_radius, base_height, base_radius).translate(x, 0, z).m,
                    stone,
                    true,
                ),
                tube(
                    Tf.chain()
                        .scale(shaft_radius, shaft_height, shaft_radius)
                        .translate(x, base_height, z).m,
                    stone,
                    true,
                ),
                // The cone's radius equals its height, so slicing it between
                // y = 0.3 and y = 0.45 gives a collar that widens from the
                // shaft's radius to the base's over that much rise.
                frustum(
                    Tf.translation(x, shaft_top - shaft_radius, z),
                    stone,
                    shaft_radius,
                    base_radius,
                ),
            };
        }

        /// The floor, the columns, and the case they stand around.
        pub fn objects() [object_count]Object {
            var all: [object_count]Object = undefined;

            all[0] = .{ .geometry = .{ .plane = .{} }, .material = floor };

            var next: usize = 1;
            for (column_z) |z| {
                for ([_]T{ -column_x, column_x }) |x| {
                    column(x, z, all[next..][0..parts_per_column]);
                    next += parts_per_column;
                }
            }

            // A spike of dark stone, its tip at the top: the cone's lower
            // nappe, which widens as it falls, closed off by a cap.
            all[next] = frustum(
                Tf.chain().scale(0.55, 1.3, 0.55).translate(0, 1.3, 0).m,
                .{
                    .color = C.init(0.15, 0.18, 0.3),
                    .diffuse = 0.6,
                    .specular = 0.9,
                    .shininess = 200,
                    .reflective = 0.2,
                },
                -1,
                0,
            );

            // The glass case around it, left open at both ends so the eye
            // looks through two thicknesses of wall and nothing else.
            all[next + 1] = tube(
                Tf.scaling(0.85, 1.7, 0.85),
                .{
                    .color = C.init(0.02, 0.05, 0.05),
                    .ambient = 0.05,
                    .diffuse = 0.1,
                    .specular = 1,
                    .shininess = 300,
                    .reflective = 0.6,
                    .transparency = 0.9,
                    .refractive_index = 1.5,
                },
                false,
            );

            return all;
        }

        /// Lit from high and to the left, in front of the colonnade, so the
        /// columns cast their shadows back down it.
        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.init(V.point(-5, 8, -6), C.init(1, 1, 1)),
            };
        }

        /// Standing at the near end of the colonnade, looking down it.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(
                V.point(0, 2.2, -9.5),
                V.point(0, 1.5, 1.5),
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

test "the colonnade is built from cylinders and cones on a plane" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);
    try testing.expect(objects[0].geometry == .plane);
    for (objects[1..]) |o| {
        try testing.expect(o.geometry == .cylinder or o.geometry == .cone);
    }
}

test "every part of every column is closed, and the case is not" {
    const objects = Default.objects();
    const parts = Default.parts_per_column * Default.column_count;
    for (objects[1 .. 1 + parts]) |o| switch (o.geometry) {
        .cylinder => |g| try testing.expect(g.closed),
        .cone => |g| try testing.expect(g.closed),
        else => unreachable,
    };
    // The spike is capped; the glass tube around it is open at both ends.
    try testing.expect(objects[objects.len - 2].geometry.cone.closed);
    try testing.expect(!objects[objects.len - 1].geometry.cylinder.closed);
}

test "a column's base, shaft, and capital stack without a gap" {
    const objects = Default.objects();
    const base = objects[1];
    const shaft = objects[2];
    const capital = objects[3];

    const top_of = struct {
        fn f(o: Default.Object, local_y: f64) f64 {
            return o.transform.mulTuple(P.point(0, local_y, 0)).y();
        }
    }.f;

    const base_top = top_of(base, 1);
    try testing.expect(tuple.feq(f64, base_top, top_of(shaft, 0)));
    // The capital is a slice of the cone, so its own extents are the heights
    // the geometry was truncated to rather than 0 and 1.
    const capital_geometry = capital.geometry.cone;
    try testing.expect(tuple.feq(
        f64,
        top_of(shaft, 1),
        top_of(capital, capital_geometry.minimum),
    ));
}

test "the capital flares from the shaft's width out to the base's" {
    const objects = Default.objects();
    const g = objects[3].geometry.cone;
    // A cone's radius at a height is that height, and this one is placed
    // without any scaling, so its extents are its radii.
    try testing.expect(tuple.feq(f64, g.minimum, Default.shaft_radius));
    try testing.expect(tuple.feq(f64, g.maximum, Default.base_radius));
}

test "the columns stand in two rows, clear of the case in the middle" {
    const objects = Default.objects();
    for (objects[1 .. 1 + Default.parts_per_column * Default.column_count]) |o| {
        const x = o.transform.mulTuple(P.point(0, 0, 0)).x();
        try testing.expect(@abs(x) > 1);
    }
}

test "the camera looks down the colonnade from above the floor" {
    const eye = (Default.camera(10, 10).transform.inverse() catch unreachable)
        .mulTuple(P.point(0, 0, 0));
    try testing.expect(eye.y() > 0);
    try testing.expect(eye.z() < 0);
}

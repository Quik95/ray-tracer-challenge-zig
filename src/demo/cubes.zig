//! A room furnished entirely with boxes.
//!
//! Everything here is the same unit cube, stretched and moved: the room, the
//! table, and what stands on it. The room is two cubes rather than one, the
//! second a little wider and a little shorter than the first, so its floor and
//! ceiling sit just inside the first's while its walls hide outside them —
//! which is how the floor gets a pattern the walls do not share.

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

        pub const name = "cubes";
        pub const group = "shapes";
        pub const object_count = 11;

        /// Half the room's width and depth, and its full height. The room
        /// stands on y = 0 so everything in it can be placed from the floor up.
        const room_half_width = 7.0;
        const room_height = 5.0;

        /// The floor and ceiling shell, inset from the walls by this much, so
        /// that the two cubes never fight over the same surface.
        const inset = 0.02;

        /// One-unit squares: the shell is `room_half_width` across in object
        /// space, so the pattern has to shrink by the same amount to come out
        /// life-sized in the world.
        const tile_scale = 1.0 / room_half_width;

        fn cube(t: Object.M, m: Object.Mat) Object {
            return .{ .geometry = .{ .cube = .{} }, .transform = t, .material = m };
        }

        /// Painted plaster: matte, and bright enough to bounce light back
        /// into the room.
        const wall_material: Object.Mat = .{
            .color = C.init(0.82, 0.78, 0.72),
            .diffuse = 0.8,
            .specular = 0,
        };

        /// Waxed tiles, checkered and just shiny enough to hold a reflection.
        const tile_material: Object.Mat = .{
            .specular = 0.2,
            .shininess = 40,
            .reflective = 0.08,
            .pattern = .{
                .transform = Tf.scaling(tile_scale, tile_scale, tile_scale),
                .kind = .{ .checkers = .{
                    .a = C.init(0.85, 0.85, 0.87),
                    .b = C.init(0.25, 0.27, 0.32),
                } },
            },
        };

        const wood: Object.Mat = .{
            .color = C.init(0.45, 0.28, 0.14),
            .diffuse = 0.7,
            .specular = 0.3,
            .shininess = 60,
            .reflective = 0.05,
        };

        /// The table top, the four legs beneath it, and where each leg stands.
        const table_top_y = 1.5;
        const top_thickness = 0.08;
        const leg = 0.09;
        const leg_x = 1.4;
        const leg_z = 0.7;
        const leg_height = (table_top_y - 2 * top_thickness) / 2.0;

        fn tableLeg(x: T, z: T) Object {
            return cube(
                Tf.chain().scale(leg, leg_height, leg).translate(x, leg_height, z).m,
                wood,
            );
        }

        /// The room, then the table, then what is standing around it.
        pub fn objects() [object_count]Object {
            const w = room_half_width;
            const h = room_height;
            return .{
                // The walls. Seen from inside, so the room is the inside of
                // a box, with the camera standing in it.
                cube(Tf.chain().scale(w, h, w).translate(0, h, 0).m, wall_material),
                // The floor and the ceiling: wider than the walls, so its own
                // walls fall outside the room and are never seen, and shorter,
                // so these two surfaces show in front of the first cube's.
                cube(
                    Tf.chain().scale(w + inset, h - inset, w + inset).translate(0, h, 0).m,
                    tile_material,
                ),

                // The table: a slab on four legs.
                cube(
                    Tf.chain()
                        .scale(1.6, top_thickness, 0.9)
                        .translate(0, table_top_y - top_thickness, 0).m,
                    wood,
                ),
                tableLeg(leg_x, leg_z),
                tableLeg(-leg_x, leg_z),
                tableLeg(leg_x, -leg_z),
                tableLeg(-leg_x, -leg_z),

                // A block of glass on the table, catching the room in its
                // faces and bending the tiles seen through it.
                cube(
                    Tf.chain()
                        .scale(0.3, 0.3, 0.3)
                        .rotateY(0.4)
                        .translate(0.55, table_top_y + 0.3, -0.1).m,
                    .{
                        .color = C.init(0.05, 0.07, 0.06),
                        .ambient = 0.05,
                        .diffuse = 0.1,
                        .specular = 1,
                        .shininess = 300,
                        .reflective = 0.9,
                        .transparency = 0.9,
                        .refractive_index = 1.5,
                    },
                ),
                // A painted box beside it, small enough to read as a trinket.
                cube(
                    Tf.chain()
                        .scale(0.22, 0.16, 0.22)
                        .rotateY(-0.7)
                        .translate(-0.6, table_top_y + 0.16, 0.15).m,
                    .{ .color = C.init(0.75, 0.15, 0.2), .specular = 0.4, .shininess = 80 },
                ),

                // Two crates left on the floor, one of them polished.
                cube(
                    Tf.chain().scale(0.6, 0.6, 0.6).rotateY(0.3).translate(-2.9, 0.6, 0.4).m,
                    .{ .color = C.init(0.2, 0.35, 0.45), .specular = 0.5, .reflective = 0.35 },
                ),
                cube(
                    Tf.chain().scale(0.45, 0.9, 0.45).rotateY(-0.25).translate(2.9, 0.9, 0.8).m,
                    .{ .color = C.init(0.35, 0.45, 0.25), .specular = 0.3 },
                ),
            };
        }

        /// Lit from high on the left, well inside the room so the walls take
        /// the light rather than shadowing it.
        pub fn world(scene_objects: []const Object) World {
            return .{
                .objects = scene_objects,
                .light = Light.init(V.point(-4, 8.5, -5), C.init(1, 1, 1)),
            };
        }

        /// An eye standing in the room, a little above the table, looking
        /// down at it.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(
                V.point(0, 3.2, -5.5),
                V.point(0, 1.3, 0),
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

test "the room is furnished with nothing but cubes" {
    const objects = Default.objects();
    try testing.expectEqual(Default.object_count, objects.len);
    for (objects) |o| try testing.expect(o.geometry == .cube);
}

test "the table top rests on its legs" {
    const objects = Default.objects();
    const top = objects[2];
    const table_leg = objects[3];
    // The underside of the top and the top of a leg meet at the same height.
    const top_underside = top.transform.mulTuple(P.point(0, -1, 0)).y();
    const leg_top = table_leg.transform.mulTuple(P.point(0, 1, 0)).y();
    try testing.expect(tuple.feq(f64, top_underside, leg_top));
}

test "the camera stands inside the room" {
    const objects = Default.objects();
    const walls = objects[0];
    const eye = (Default.camera(10, 10).transform.inverse() catch unreachable).mulTuple(P.point(0, 0, 0));
    const inside = walls.worldToObject(eye).?;
    inline for (.{ .x, .y, .z }) |axis| {
        try testing.expect(@abs(inside.get(axis)) < 1);
    }
}

test "the floor shell shows through the walls it is nested in" {
    const objects = Default.objects();
    const walls = objects[0];
    const tiles = objects[1];
    const floor_of = struct {
        fn f(o: Default.Object) f64 {
            return o.transform.mulTuple(P.point(0, -1, 0)).y();
        }
    }.f;
    // The tiled floor sits just above the wall cube's own floor, so it is the
    // one the eye meets first.
    try testing.expect(floor_of(tiles) > floor_of(walls));
}

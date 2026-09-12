//! A hexagon of spheres and cylinders, built once and turned into place.
//!
//! Every side of the ring is the same pair of shapes — a ball for the corner
//! and a length of pipe for the edge — modelled once at the origin. Each side
//! is a group holding that pair, and the ring is a group holding the six
//! sides, each turned a sixth of a circle further round. Nothing is placed by
//! hand: the only transformations written out are the ones that shape a single
//! side, and the ones that turn and tilt the whole ring.

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

        pub const name = "hexagon";
        pub const group = "groups";

        pub const sides = 6;
        /// A corner and the edge that leaves it.
        pub const parts_per_side = 2;

        /// Brass, bright enough to pick up the floor beneath the ring.
        pub const brass: Object.Mat = .{
            .color = C.init(0.74, 0.55, 0.22),
            .diffuse = 0.6,
            .specular = 0.9,
            .shininess = 200,
            .reflective = 0.3,
        };

        /// Dark squares, holding just enough of a reflection to stand the
        /// ring over something.
        const floor: Object.Mat = .{
            .specular = 0.2,
            .shininess = 60,
            .reflective = 0.2,
            .pattern = .{
                .kind = .{ .checkers = .{
                    .a = C.init(0.16, 0.17, 0.2),
                    .b = C.init(0.36, 0.37, 0.4),
                } },
            },
        };

        /// The ball at the near corner of a side.
        fn corner() Object {
            return .{
                .geometry = .{ .sphere = .{} },
                .transform = Tf.chain().scale(0.25, 0.25, 0.25).translate(0, 0, -1).m,
            };
        }

        /// The pipe that runs from that corner to the next one: a unit length
        /// of cylinder, thinned, tipped over, and swung round to lie along the
        /// side rather than across it.
        fn edge() Object {
            return .{
                .geometry = .{ .cylinder = .{ .minimum = 0, .maximum = 1, .closed = false } },
                .transform = Tf.chain()
                    .scale(0.25, 1, 0.25)
                    .rotateZ(-std.math.pi / 2.0)
                    .rotateY(-std.math.pi / 6.0)
                    .translate(0, 0, -1).m,
            };
        }

        /// Everything the scene stands on, laid out so that each group's
        /// children are an array the scene itself owns.
        pub const Objects = struct {
            /// The corner and edge of each side, in the side's coordinates.
            parts: [sides][parts_per_side]Object,
            /// One group per side, turned into its place in the ring.
            side_groups: [sides]Object,
            /// The ring itself, and the floor it stands on.
            top: [2]Object,

            /// Point every group at the children it holds, and tell those
            /// children which group holds them. The children of a group are a
            /// slice, so they can only be pointed at once the arrays are
            /// where they will stay — which is here, and not in `objects`.
            pub fn assemble(self: *Objects) void {
                for (&self.side_groups, &self.parts) |*side, *parts| {
                    side.geometry.group.children = parts;
                }
                self.top[0].geometry.group.children = &self.side_groups;
                Object.linkAll(&self.top);
            }
        };

        /// The ring, unassembled: the shapes themselves, with the groups still
        /// to be pointed at their children.
        pub fn objects() Objects {
            // SAFETY: every field is filled in below before `all` is returned.
            var all: Objects = undefined;

            for (&all.parts, &all.side_groups, 0..) |*parts, *side, i| {
                parts.* = .{ corner(), edge() };
                for (parts) |*part| part.material = brass;

                side.* = Object.group(&.{});
                side.transform = Tf.rotationY(@as(T, @floatFromInt(i)) * std.math.pi / 3.0);
            }

            // Tilted towards the eye and lifted clear of the floor, so the
            // ring reads as a ring rather than as a line of balls.
            all.top[0] = Object.group(&.{});
            all.top[0].transform = Tf.chain()
                .rotateX(-std.math.pi / 5.0)
                .translate(0, 1.1, 0).m;
            all.top[1] = .{ .geometry = .{ .plane = .{} }, .material = floor };

            return all;
        }

        /// Lit from above and to the left, in front of the ring, so its
        /// shadow falls back and away from the eye.
        pub fn world(scene_objects: *Objects) World {
            scene_objects.assemble();
            return .{
                .objects = &scene_objects.top,
                .light = Light.init(V.point(-4, 7, -6), C.init(1, 1, 1)),
            };
        }

        /// Level with the ring and a little above it, close enough that the
        /// hexagon fills the frame.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(
                V.point(0, 2.2, -4.5),
                V.point(0, 1, 0),
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
const R = @import("../scene/ray.zig").R;

test "the ring is one group of six sides, each a group of two shapes" {
    var all = Default.objects();
    all.assemble();

    const ring = all.top[0].geometry.group;
    try testing.expectEqual(@as(usize, Default.sides), ring.children.len);
    for (ring.children) |*side| {
        const parts = side.geometry.group;
        try testing.expectEqual(@as(usize, Default.parts_per_side), parts.children.len);
        try testing.expect(parts.children[0].geometry == .sphere);
        try testing.expect(parts.children[1].geometry == .cylinder);
        try testing.expectEqual(&all.top[0], side.parent);
        for (parts.children) |*part| try testing.expectEqual(side, part.parent);
    }
}

test "the corners sit a sixth of a circle apart around the ring" {
    var all = Default.objects();
    const w = Default.world(&all);

    // Where each corner's centre lands inside the ring, which is one turn of
    // the side's own transformation away from where the corner is written.
    for (w.objects[0].geometry.group.children, 0..) |*side, i| {
        const corner = side.geometry.group.children[0];
        const centre = side.transform
            .mul(corner.transform)
            .mulTuple(P.point(0, 0, 0));

        const turn = @as(f64, @floatFromInt(i)) * std.math.pi / 3.0;
        // The corners lie a unit out from the axis, a sixth of a circle apart.
        try testing.expectApproxEqAbs(-@cos(turn), centre.z(), 1e-9);
        try testing.expectApproxEqAbs(-@sin(turn), centre.x(), 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0), centre.y(), 1e-9);
    }
}

test "a ray through the middle of the ring meets nothing but the floor" {
    var all = Default.objects();
    const w = Default.world(&all);

    // The hole in the middle is a hole: whatever lies beyond it is what the
    // eye sees there, never the ring itself.
    const r = R.init(P.point(0, 1.1, -5), P.vector(0, 0, 1));
    if (w.hit(r)) |h| try testing.expect(h.object.geometry == .plane);
}

test "the ring is met where its groups put it, and answers with a normal" {
    var all = Default.objects();
    const w = Default.world(&all);

    // The near corner of the first side, carried out of the ring's own
    // coordinates by the only transformation that stands the ring anywhere.
    const corner = all.top[0].transform.mulTuple(P.point(0, 0, -1));
    const r = R.init(P.point(corner.x(), corner.y(), corner.z() - 3), P.vector(0, 0, 1));

    const h = w.hit(r) orelse return error.LookingAtNothing;
    try testing.expect(h.object.geometry == .sphere);
    try testing.expect(h.object.material.eql(Default.brass));

    // The ball is met head on, so its normal comes back out of both groups
    // pointing straight at the eye.
    const n = h.object.normalAt(r.position(h.t)).?;
    try testing.expect(n.eql(P.vector(0, 0, -1)));
}

test "the camera looks at the ring from in front of and above it" {
    const eye = (Default.camera(10, 10).transform.inverse() catch unreachable)
        .mulTuple(P.point(0, 0, 0));
    try testing.expect(eye.y() > 1);
    try testing.expect(eye.z() < 0);
}

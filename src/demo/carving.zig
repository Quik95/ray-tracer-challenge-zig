//! The same cube and ball, combined three ways: kept together, kept where they
//! overlap, and one taken out of the other.
//!
//! All three shapes on the floor are built from the same two primitives, so
//! the only thing that differs between them is the set operation. On the left
//! the ball swells out through the faces of the cube; in the middle it has
//! pared the cube's corners and edges away; on the right a smaller ball has
//! been carved out of one corner, and the hollow it leaves is red, because the
//! surface bounding it still belongs to the ball and is shaded by the ball's
//! material.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const color = @import("../render/color.zig");
const csg_mod = @import("../scene/csg.zig");
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
        pub const Operation = csg_mod.Csg(T).Operation;
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);

        pub const name = "csg";
        pub const group = "csg";

        /// One shape per operation, in the order they are easiest to read:
        /// what the two shapes cover together, what they cover in common, and
        /// what is left of one once the other is taken out of it.
        pub const operations = [_]Operation{ .@"union", .intersect, .difference };

        /// How far out the ball reaches when it is being added to or clipped
        /// against the cube. Past the faces, so the union bulges and the
        /// intersection is a cube with its corners pared off, but not so far
        /// that the intersection is just the cube again.
        const ball_radius = 1.35;

        /// Where the ball sits when it is being carved out, and how big: small
        /// enough to leave a corner rather than halve the cube, and pushed out
        /// to the near top corner so the hollow faces the eye.
        const bite_radius = 1.0;
        const bite_at = [3]T{ -0.9, 0.9, -0.9 };

        /// Warm and matte: the outside of every shape.
        pub const shell: Object.Mat = .{
            .color = C.init(0.9, 0.72, 0.2),
            .diffuse = 0.75,
            .specular = 0.3,
            .shininess = 90,
        };

        /// Red, and lit a little from within, so the inside of the hollow
        /// reads as a surface of its own rather than as shadow.
        pub const core: Object.Mat = .{
            .color = C.init(0.75, 0.15, 0.15),
            .ambient = 0.2,
            .diffuse = 0.8,
            .specular = 0.3,
            .shininess = 90,
        };

        /// Dark squares, holding just enough of a reflection to stand the
        /// three shapes over something.
        const floor: Object.Mat = .{
            .specular = 0.2,
            .shininess = 60,
            .reflective = 0.2,
            .pattern = .{
                .kind = .{ .checkers = .{
                    .a = C.init(0.15, 0.16, 0.19),
                    .b = C.init(0.33, 0.34, 0.37),
                } },
            },
        };

        /// Everything the scene stands on, laid out so that each operation's
        /// operands are an array the scene itself owns.
        pub const Objects = struct {
            /// The cube and the ball of each shape, in that shape's own
            /// coordinates: left operand first, as a CSG shape expects.
            operands: [operations.len][2]Object,
            /// The three combined shapes, and the floor they stand on.
            top: [operations.len + 1]Object,

            /// Point each shape at its operands, and tell the operands which
            /// shape holds them. Only possible once the arrays are where they
            /// will stay, which is here and not in `objects`.
            pub fn assemble(self: *Objects) void {
                for (self.top[0..operations.len], &self.operands) |*combined, *pair| {
                    combined.geometry.csg.children = pair;
                }
                Object.linkAll(&self.top);
            }
        };

        /// The three shapes, unassembled: the primitives themselves, with the
        /// operations still to be pointed at them.
        pub fn objects() Objects {
            // SAFETY: every field is filled in below before `all` is returned.
            var all: Objects = undefined;

            for (&all.operands, all.top[0..operations.len], operations, 0..) |*pair, *combined, operation, i| {
                pair[0] = .{ .geometry = .{ .cube = .{} }, .material = shell };
                pair[1] = .{ .geometry = .{ .sphere = .{} }, .material = core };
                pair[1].transform = switch (operation) {
                    // Swollen past the faces, and centred, so that what it
                    // adds or clips is the same all the way round.
                    .@"union", .intersect => Tf.scaling(ball_radius, ball_radius, ball_radius),
                    // Smaller, and out at the corner it eats into.
                    .difference => Tf.chain()
                        .scale(bite_radius, bite_radius, bite_radius)
                        .translate(bite_at[0], bite_at[1], bite_at[2]).m,
                };

                // Set out in a row, turned so the eye sees two faces of each
                // cube and can tell a bulge from a bite.
                combined.* = Object.csg(operation, &.{});
                combined.transform = Tf.chain()
                    .scale(0.8, 0.8, 0.8)
                    .rotateY(-std.math.pi / 7.0)
                    .translate(@as(T, @floatFromInt(i)) * 3.0 - 3.0, 1.1, 0).m;
            }
            all.top[operations.len] = .{ .geometry = .{ .plane = .{} }, .material = floor };

            return all;
        }

        /// Lit from above and to the left and in front, which is the corner
        /// the hollow opens towards.
        pub fn world(scene_objects: *Objects) World {
            scene_objects.assemble();
            return .{
                .objects = &scene_objects.top,
                .light = Light.init(V.point(-6, 8, -8), C.init(1, 1, 1)),
            };
        }

        /// Far enough back for all three to stand in the frame, and high
        /// enough to look down into the carved corner.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(
                V.point(0, 3, -8.5),
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
const R = @import("../scene/ray.zig").R;

test "the scene shows each operation over the same pair of primitives" {
    var all = Default.objects();
    const w = Default.world(&all);

    for (w.objects[0..3], Default.operations) |combined, operation| {
        const c = combined.geometry.csg;
        try testing.expectEqual(operation, c.operation);
        try testing.expect(c.left().geometry == .cube);
        try testing.expect(c.right().geometry == .sphere);
        try testing.expect(c.left().material.eql(Default.shell));
        try testing.expect(c.right().material.eql(Default.core));
    }
    try testing.expect(w.objects[3].geometry == .plane);
}

test "only the union reaches past the cube it was built from" {
    var all = Default.objects();
    const w = Default.world(&all);

    // Each shape is boxed in its own coordinates, where the cube reaches to
    // one either way, so the boxes compare directly.
    const boxes = [3]Default.Object.Bounds{
        w.objects[0].geometry.csg.bounds(),
        w.objects[1].geometry.csg.bounds(),
        w.objects[2].geometry.csg.bounds(),
    };
    try testing.expect(boxes[0].max.x() > 1);
    // What is kept in common, and what is left over, both fit in the cube.
    try testing.expect(boxes[1].max.eql(P.point(1, 1, 1)));
    try testing.expect(boxes[2].max.eql(P.point(1, 1, 1)));
}

test "the ball pares the corners off the shape kept in common" {
    var all = Default.objects();
    const w = Default.world(&all);

    // Down the diagonal towards the middle of each shape, in its own
    // coordinates: the union is met at the cube's corner, the intersection
    // short of it, where the ball has cut the corner away.
    // The ray starts four along each axis, so it has 4√3 to run before the
    // middle; the corner stands √3 out from there, and the ball 1.35.
    const third = 1.0 / @sqrt(3.0);
    const start = 4 * @sqrt(3.0);
    for (w.objects[0..2], [2]f64{ start - @sqrt(3.0), start - 1.35 }) |combined, expected| {
        const r = R.init(
            combined.transform.mulTuple(P.point(4, 4, -4)),
            combined.transform.mulTuple(P.vector(-third, -third, third)).normalize(),
        );
        const h = combined.nearestHit(r) orelse return error.LookingAtNothing;
        // The shapes are scaled, so what the distance is measured against is
        // the same scale the ray was carried out into the world by.
        try testing.expectApproxEqAbs(expected, h.t / 0.8, 1e-6);
    }
}

test "the hollow carved out of the last shape keeps the ball's colour" {
    var all = Default.objects();
    const w = Default.world(&all);

    const carved = w.objects[2];
    const third = 1.0 / @sqrt(3.0);
    const r = R.init(
        carved.transform.mulTuple(P.point(-4, 4, -4)),
        carved.transform.mulTuple(P.vector(third, -third, third)).normalize(),
    );
    const h = carved.nearestHit(r) orelse return error.LookingAtNothing;
    // The corner is gone, so what the eye meets first along that line is the
    // wall of the hollow — which is the ball, and so is red.
    try testing.expect(h.object.geometry == .sphere);
    try testing.expect(h.object.material.eql(Default.core));
}

test "the shapes stand clear of the floor they cast onto" {
    var all = Default.objects();
    const w = Default.world(&all);

    for (w.objects[0..3]) |combined| {
        try testing.expect(combined.geometry.csg.bounds().transform(combined.transform).min.y() > 0);
    }
}

test "the camera looks at the row from in front of and above it" {
    const eye = (Default.camera(10, 10).transform.inverse() catch unreachable)
        .mulTuple(P.point(0, 0, 0));
    try testing.expect(eye.y() > 1);
    try testing.expect(eye.z() < 0);
}

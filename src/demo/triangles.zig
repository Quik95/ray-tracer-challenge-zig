//! Two balls of triangles, side by side: the same mesh shaded as the flat
//! facets it is, and as the sphere it is pretending to be.
//!
//! The mesh is a geodesic sphere — an icosahedron with every face quartered,
//! each new corner pushed back out onto the sphere — worked out at compile
//! time, so the scene carries the eighty triangles rather than the code that
//! makes them. Both balls are that same mesh. The left one is built from plain
//! triangles and shows every facet; the right one carries a normal at each
//! corner, pointing straight out of the sphere, and the blend between them
//! hides the facets that are still there. The silhouette gives it away: it
//! stays as angular on the right as on the left, because only the shading was
//! ever smoothed.

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

        pub const name = "triangles";
        pub const group = "triangles";

        /// The twenty faces of an icosahedron, quartered once.
        pub const facet_count = 20 * 4;

        /// Pale clay, matte enough that the shading carries the shape and
        /// nothing else does.
        pub const clay: Object.Mat = .{
            .color = C.init(0.83, 0.55, 0.42),
            .diffuse = 0.8,
            .specular = 0.35,
            .shininess = 80,
        };

        /// Dark and faintly reflective, to stand the two balls over something
        /// without competing with them.
        const floor: Object.Mat = .{
            .color = C.init(0.18, 0.19, 0.22),
            .specular = 0.1,
            .reflective = 0.15,
        };

        /// A point on the unit sphere in the direction of `p`.
        fn onSphere(x: T, y: T, z: T) V {
            const length = @sqrt(x * x + y * y + z * z);
            return V.point(x / length, y / length, z / length);
        }

        /// The point halfway between two on the sphere, pushed back out onto
        /// it — which is what turns a subdivided icosahedron into a ball
        /// rather than a slightly less pointy icosahedron.
        fn midpoint(a: V, b: V) V {
            return onSphere(
                (a.x() + b.x()) / 2,
                (a.y() + b.y()) / 2,
                (a.z() + b.z()) / 2,
            );
        }

        /// The sphere's outward direction at a point on it. The point already
        /// lies a unit from the middle, so it is its own normal.
        fn outward(p: V) V {
            return V.vector(p.x(), p.y(), p.z());
        }

        /// The corners of every facet, worked out once at compile time.
        ///
        /// An icosahedron's twelve corners are the corners of three golden
        /// rectangles standing at right angles to each other; its twenty faces
        /// are the triples of those corners that lie a short edge apart.
        pub const facets: [facet_count][3]V = blk: {
            @setEvalBranchQuota(100_000);

            const phi = (1.0 + @sqrt(5.0)) / 2.0;
            const corners = [12]V{
                onSphere(-1, phi, 0),  onSphere(1, phi, 0),
                onSphere(-1, -phi, 0), onSphere(1, -phi, 0),
                onSphere(0, -1, phi),  onSphere(0, 1, phi),
                onSphere(0, -1, -phi), onSphere(0, 1, -phi),
                onSphere(phi, 0, -1),  onSphere(phi, 0, 1),
                onSphere(-phi, 0, -1), onSphere(-phi, 0, 1),
            };
            const triples = [20][3]usize{
                .{ 0, 11, 5 },  .{ 0, 5, 1 },  .{ 0, 1, 7 },  .{ 0, 7, 10 },
                .{ 0, 10, 11 }, .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 },
                .{ 10, 7, 6 },  .{ 7, 1, 8 },  .{ 3, 9, 4 },  .{ 3, 4, 2 },
                .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },  .{ 4, 9, 5 },
                .{ 2, 4, 11 },  .{ 6, 2, 10 }, .{ 8, 6, 7 },  .{ 9, 8, 1 },
            };

            var all: [facet_count][3]V = undefined;
            var next: usize = 0;
            for (triples) |triple| {
                const a = corners[triple[0]];
                const b = corners[triple[1]];
                const c = corners[triple[2]];
                // The three edge midpoints cut the face into a middle
                // triangle and one at each corner.
                const ab = midpoint(a, b);
                const bc = midpoint(b, c);
                const ca = midpoint(c, a);
                for ([4][3]V{
                    .{ a, ab, ca },
                    .{ ab, b, bc },
                    .{ ca, bc, c },
                    .{ ab, bc, ca },
                }) |face| {
                    all[next] = face;
                    next += 1;
                }
            }
            break :blk all;
        };

        /// Everything the scene stands on, laid out so that each group's
        /// children are an array the scene itself owns.
        pub const Objects = struct {
            /// The same mesh twice: flat facets, then smoothed ones.
            meshes: [2][facet_count]Object,
            /// A group per mesh, and the floor they stand on.
            top: [3]Object,

            /// Point each ball at its facets, and tell the facets which ball
            /// holds them. Only possible once the arrays are where they will
            /// stay, which is here and not in `objects`.
            pub fn assemble(self: *Objects) void {
                for (self.top[0..2], &self.meshes) |*ball, *mesh| {
                    ball.geometry.group.children = mesh;
                }
                Object.linkAll(&self.top);
            }
        };

        /// The two balls, unassembled: the facets themselves, with the groups
        /// still to be pointed at them.
        pub fn objects() Objects {
            var all: Objects = undefined;

            for (&all.meshes, 0..) |*mesh, smooth| {
                for (mesh, facets) |*facet, corners| {
                    facet.* = if (smooth == 1) Object.smoothTriangle(
                        corners[0],
                        corners[1],
                        corners[2],
                        outward(corners[0]),
                        outward(corners[1]),
                        outward(corners[2]),
                    ) else Object.triangle(corners[0], corners[1], corners[2]);
                    facet.material = clay;
                }
            }

            // Set apart far enough to read as two balls, and turned so that
            // the same facets face the eye in both.
            for (all.top[0..2], [2]T{ -1.25, 1.25 }) |*ball, x| {
                ball.* = Object.group(&.{});
                ball.transform = Tf.chain()
                    .rotateY(std.math.pi / 7.0)
                    .translate(x, 1.05, 0).m;
            }
            all.top[2] = .{ .geometry = .{ .plane = .{} }, .material = floor };

            return all;
        }

        /// Lit from above and to the left, close in front, so the terminator
        /// crosses both balls where the faceting shows most.
        pub fn world(scene_objects: *Objects) World {
            scene_objects.assemble();
            return .{
                .objects = &scene_objects.top,
                .light = Light.init(V.point(-5, 6, -5), C.init(1, 1, 1)),
            };
        }

        /// Level with the balls and a little above, near enough that the pair
        /// fills the frame.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.5);
            c.transform = Tf.view(
                V.point(0, 2, -5.5),
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

test "the mesh quarters every face of an icosahedron" {
    try testing.expectEqual(@as(usize, 80), Default.facets.len);

    // Every corner of every facet lies on the unit sphere, and no facet is
    // degenerate — a subdivision that collapsed an edge would show as a
    // triangle with no direction to face.
    for (Default.facets) |facet| {
        for (facet) |corner| {
            try testing.expectApproxEqAbs(@as(f64, 1), P.vector(corner.x(), corner.y(), corner.z()).magnitude(), 1e-12);
        }
        const tri = Default.Object.triangle(facet[0], facet[1], facet[2]).geometry.triangle;
        try testing.expectApproxEqAbs(@as(f64, 1), tri.normal.magnitude(), 1e-12);
    }
}

test "the two balls are the same mesh, one flat and one smooth" {
    var all = Default.objects();
    all.assemble();

    const flat = all.top[0].geometry.group.children;
    const smooth = all.top[1].geometry.group.children;
    try testing.expectEqual(@as(usize, Default.facet_count), flat.len);
    try testing.expectEqual(@as(usize, Default.facet_count), smooth.len);

    for (flat, smooth) |a, b| {
        try testing.expect(!a.geometry.triangle.isSmooth());
        try testing.expect(b.geometry.triangle.isSmooth());
        try testing.expect(a.geometry.triangle.p1.eql(b.geometry.triangle.p1));
        try testing.expect(a.material.eql(Default.clay));
    }
}

test "the smoothed ball answers with a normal that turns across a facet" {
    var all = Default.objects();
    const w = Default.world(&all);

    // A ray down the z axis into each ball, aimed a little off centre so it
    // lands inside a facet rather than on an edge.
    for (w.objects[0..2], [2]f64{ -1.25, 1.25 }) |ball, x| {
        const r = R.init(P.point(x + 0.2, 1.2, -5), P.vector(0, 0, 1));
        const h = ball.nearestHit(r) orelse return error.LookingAtNothing;
        const point = r.position(h.t);
        const n = h.object.normalAt(point).?;
        try testing.expectApproxEqAbs(@as(f64, 1), n.magnitude(), 1e-9);
        // Whichever way the facet is wound, the surface is met from outside.
        try testing.expect(n.dot(r.direction) < 0 or n.neg().dot(r.direction) < 0);
    }

    // Two points inside one facet of the smooth ball differ in their normals,
    // where on the flat ball they would not.
    const smooth = w.objects[1].geometry.group.children[0].geometry.triangle;
    const a = smooth.localNormalAt(smooth.p1);
    const b = smooth.localNormalAt(smooth.p2);
    try testing.expect(!a.eql(b));
}

test "the balls stand clear of the floor they cast onto" {
    var all = Default.objects();
    const w = Default.world(&all);

    try testing.expect(w.objects[2].geometry == .plane);
    for (w.objects[0..2]) |ball| {
        // Each mesh is a unit ball, lifted just past its own radius.
        try testing.expect(ball.geometry.group.bounds().transform(ball.transform).min.y() > 0);
    }
}

test "the camera looks at the pair from in front of and above them" {
    const eye = (Default.camera(10, 10).transform.inverse() catch unreachable)
        .mulTuple(P.point(0, 0, 0));
    try testing.expect(eye.y() > 1);
    try testing.expect(eye.z() < 0);
}

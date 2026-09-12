//! Three meshes read from disk, standing in a row.
//!
//! Everything else in the gallery is written out in source, shape by shape,
//! which stops being possible somewhere around a few dozen triangles. These
//! are the models the graphics world has passed around for decades — the Utah
//! teapot, Blender's Suzanne, and Spot — read from the OBJ files the library
//! carries: thirteen thousand triangles between them.
//!
//! Nothing in the files says how large a model is or where it stands, and the
//! three were digitised at wildly different scales. So the scene measures the
//! box around each one as it comes in and works out the transform that stands
//! it on the floor at a size that matches its neighbours, centred over its
//! place in the row. Every corner carries a normal, so the facets are shaded
//! away and the silhouette is the only place the mesh shows through.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const color = @import("../render/color.zig");
const light_mod = @import("../scene/light.zig");
const obj_mod = @import("../scene/obj.zig");
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
        pub const Obj = obj_mod.Obj(T);
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);

        pub const name = "models";
        pub const group = "models";

        pub const LoadError = Obj.ParseError;

        /// One model: the file it is read from, and where and how it stands.
        const Piece = struct {
            source: []const u8,
            /// How large it is made: the longest side of the box around it,
            /// in world units. Measuring the longest side rather than the
            /// height is what keeps a low, long model from coming out tiny
            /// beside a tall one.
            size: T,
            /// Where along the row it stands, and how far back.
            x: T,
            z: T = 0,
            /// How far it is turned about its own axis, to show the side
            /// worth seeing.
            spin: T,
            material: Object.Mat,
        };

        /// Glazed porcelain: bright, hard-edged highlight, and enough of a
        /// mirror to pick up the floor under the spout.
        const porcelain: Object.Mat = .{
            .color = C.init(0.92, 0.93, 0.95),
            .diffuse = 0.7,
            .specular = 0.9,
            .shininess = 300,
            .reflective = 0.12,
        };

        /// Unfired clay, matte enough that only the shading describes the
        /// face.
        const clay: Object.Mat = .{
            .color = C.init(0.78, 0.45, 0.32),
            .diffuse = 0.85,
            .specular = 0.2,
            .shininess = 40,
        };

        /// Painted wood, the colour Spot is usually shown in.
        const paint: Object.Mat = .{
            .color = C.init(0.85, 0.72, 0.55),
            .diffuse = 0.8,
            .specular = 0.35,
            .shininess = 90,
        };

        /// Slate, dark and faintly wet, so the row stands over something that
        /// answers it without competing.
        const floor: Object.Mat = .{
            .color = C.init(0.16, 0.17, 0.2),
            .diffuse = 0.7,
            .specular = 0.2,
            .shininess = 60,
            .reflective = 0.18,
        };

        const pieces = [_]Piece{
            .{
                .source = @embedFile("teapot.obj"),
                .size = 3.0,
                .x = -3.3,
                .z = 0.2,
                .spin = -std.math.pi / 5.0,
                .material = porcelain,
            },
            .{
                .source = @embedFile("suzanne.obj"),
                .size = 2.0,
                .x = 0,
                .z = -0.3,
                .spin = std.math.pi,
                .material = clay,
            },
            .{
                .source = @embedFile("spot.obj"),
                .size = 2.4,
                .x = 3.3,
                .z = 0.2,
                .spin = std.math.pi / 4.0,
                .material = paint,
            },
        };

        pub const count = pieces.len;

        /// The scene's shapes: the meshes as they were read, and the row of
        /// groups over them.
        pub const Objects = struct {
            models: [count]Obj.Model,
            /// A group per model, and the floor they stand on.
            top: [count + 1]Object,

            pub fn deinit(self: *Objects) void {
                for (&self.models) |*model| model.deinit();
                self.* = undefined;
            }

            /// Stand each mesh where it belongs and tie the tree together.
            ///
            /// A model is measured before it is placed and placed before the
            /// scene is linked, since a group's box is drawn around children
            /// that already stand where they will stay.
            pub fn assemble(self: *Objects) void {
                for (self.top[0..count], &self.models, pieces) |*stand, *model, piece| {
                    stand.* = model.root;
                    stand.link();
                    stand.transform = standing(stand.geometry.group.bounds(), piece);
                }
                Object.linkAll(&self.top);
            }
        };

        /// The transform that takes a model from wherever its file left it to
        /// its place in the row: centred over the spot, standing on the floor,
        /// and scaled so the whole row reads as one set of objects rather than
        /// three unrelated ones.
        fn standing(box: Object.Bounds, piece: Piece) Object.M {
            const extent = box.max.sub(box.min);
            const scale = piece.size / @max(extent.x(), @max(extent.y(), extent.z()));
            return Tf.chain()
                .translate(
                    -(box.min.x() + box.max.x()) / 2,
                    -box.min.y(),
                    -(box.min.z() + box.max.z()) / 2,
                )
                .scale(scale, scale, scale)
                .rotateY(piece.spin)
                .translate(piece.x, 0, piece.z).m;
        }

        /// Read every model. The caller owns the result and frees it with
        /// `deinit`; `world` is what stands the meshes up.
        pub fn objects(allocator: std.mem.Allocator) LoadError!Objects {
            var all: Objects = .{ .models = undefined, .top = undefined };
            var loaded: usize = 0;
            errdefer for (all.models[0..loaded]) |*model| model.deinit();

            for (&all.models, pieces) |*model, piece| {
                model.* = try Obj.parse(allocator, piece.source);
                for (model.faces) |*face| face.material = piece.material;
                loaded += 1;
            }

            all.top[count] = .{ .geometry = .{ .plane = .{} }, .material = floor };
            return all;
        }

        /// Lit from high and to the left, far enough forward that the teapot's
        /// highlight lands on its shoulder rather than behind it.
        pub fn world(scene_objects: *Objects) World {
            scene_objects.assemble();
            return .{
                .objects = &scene_objects.top,
                .light = Light.init(V.point(-6, 8, -6), C.init(1, 1, 1)),
            };
        }

        /// Level with the row and a little above it, back far enough that all
        /// three fit the frame with the floor showing under them.
        pub fn camera(width: usize, height: usize) Cam {
            var c = Cam.init(width, height, std.math.pi / 3.0);
            c.transform = Tf.view(
                V.point(0, 2.4, -8),
                V.point(0, 1.0, 0),
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

test "every model in the row reads cleanly" {
    var all = try Default.objects(testing.allocator);
    defer all.deinit();

    // The files carry nothing but a name, corners, normals, and faces, so a
    // line the reader passed over means one it failed to understand.
    for (all.models) |model| {
        try testing.expectEqual(@as(usize, 0), model.ignored);
        try testing.expect(model.faces.len > 0);
        try testing.expectEqual(model.vertices.len, model.normals.len);
    }

    // The counts the files were checked in with. A model that silently loses
    // faces still renders, only less of itself.
    try testing.expectEqual(@as(usize, 6320), all.models[0].faces.len);
    try testing.expectEqual(@as(usize, 968), all.models[1].faces.len);
    try testing.expectEqual(@as(usize, 5856), all.models[2].faces.len);
}

test "every corner of every face carries a normal" {
    var all = try Default.objects(testing.allocator);
    defer all.deinit();

    for (all.models) |model| {
        for (model.faces) |face| {
            try testing.expect(face.geometry.triangle.isSmooth());
        }
    }
}

test "each model stands on the floor at the size it was asked for" {
    var all = try Default.objects(testing.allocator);
    const w = Default.world(&all);
    defer all.deinit();

    try testing.expect(w.objects[Default.count].geometry == .plane);

    for (w.objects[0..Default.count], Default.pieces) |stand, piece| {
        const box = stand.geometry.group.bounds().transform(stand.transform);
        const extent = box.max.sub(box.min);
        try testing.expectApproxEqAbs(@as(f64, 0), box.min.y(), 1e-9);
        // A model is sized before it is turned, and turning a box about its
        // middle only ever grows the box drawn around it — by at most the
        // diagonal of the square it turns within.
        const longest = @max(extent.x(), @max(extent.y(), extent.z()));
        try testing.expect(longest >= piece.size - 1e-9);
        try testing.expect(longest <= piece.size * @sqrt(2.0) + 1e-9);
        // Centred over its place in the row, whichever way it was turned.
        try testing.expectApproxEqAbs(piece.x, (box.min.x() + box.max.x()) / 2, 1e-9);
        try testing.expectApproxEqAbs(piece.z, (box.min.z() + box.max.z()) / 2, 1e-9);
    }
}

test "the models stand apart, each in its own space" {
    var all = try Default.objects(testing.allocator);
    const w = Default.world(&all);
    defer all.deinit();

    for (w.objects[0..Default.count], 0..) |stand, i| {
        const box = stand.geometry.group.bounds().transform(stand.transform);
        for (w.objects[i + 1 .. Default.count]) |other| {
            const with = other.geometry.group.bounds().transform(other.transform);
            try testing.expect(box.overlap(with).isEmpty());
        }
    }
}

test "a ray down the row meets the mesh in front of it" {
    var all = try Default.objects(testing.allocator);
    const w = Default.world(&all);
    defer all.deinit();

    // Straight at the middle of each model from where the eye stands. A hit
    // is answered by a triangle of that model and by no other.
    for (w.objects[0..Default.count], Default.pieces) |*stand, piece| {
        const r = R.init(P.point(piece.x, 0.7, -8), P.vector(0, 0, 1));
        const h = stand.nearestHit(r) orelse return error.LookingAtNothing;
        try testing.expect(stand.includes(h.object));
        try testing.expect(h.object.geometry == .triangle);

        // Smooth shading is the point of the normals: the surface answers
        // with a unit normal that faces the eye.
        const n = h.object.normalAt(r.position(h.t)).?;
        try testing.expectApproxEqAbs(@as(f64, 1), n.magnitude(), 1e-9);
        try testing.expect(n.dot(r.direction) < 0);
    }
}

test "the camera looks along the row from in front of and above it" {
    const eye = (Default.camera(10, 10).transform.inverse() catch unreachable)
        .mulTuple(P.point(0, 0, 0));
    try testing.expect(eye.y() > 1);
    try testing.expect(eye.z() < -1);
}

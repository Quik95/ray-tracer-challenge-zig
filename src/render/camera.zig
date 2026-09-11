//! The camera: where the scene is viewed from, and the canvas it lands on.
//!
//! The canvas always sits exactly one unit in front of the camera, which is
//! what lets the field of view alone fix its size. The camera itself never
//! moves — its transformation moves the world in front of it — so every ray
//! starts at the origin and is carried into the scene by the inverse of that
//! transformation.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const matrix = @import("../math/matrix.zig");
const ray_mod = @import("../scene/ray.zig");
const tuple = @import("../math/tuple.zig");
const world_mod = @import("../scene/world.zig");

/// A camera over a float type.
pub fn Camera(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const M = matrix.Matrix(T, 4);
        pub const Point = tuple.Tuple(T);
        pub const Ray = ray_mod.Ray(T);
        pub const World = world_mod.World(T);
        pub const Image = canvas_mod.Canvas(World.C);
        pub const Scalar = T;

        /// Canvas width in pixels.
        hsize: usize,
        /// Canvas height in pixels.
        vsize: usize,
        /// How wide an angle the camera takes in. Narrowing it zooms in.
        field_of_view: T,
        /// World to camera space; usually a view transformation.
        transform: M = M.identity,

        pub fn init(hsize: usize, vsize: usize, field_of_view: T) Self {
            return .{ .hsize = hsize, .vsize = vsize, .field_of_view = field_of_view };
        }

        /// Half the canvas's width and height in world units. Half the field
        /// of view spans a right triangle one unit deep, so its tangent is
        /// the longer of the two; the aspect ratio gives the other.
        pub fn halfExtents(self: Self) struct { T, T } {
            const half_view = @tan(self.field_of_view / 2);
            const aspect = @as(T, @floatFromInt(self.hsize)) / @as(T, @floatFromInt(self.vsize));
            return if (aspect >= 1)
                .{ half_view, half_view / aspect }
            else
                .{ half_view * aspect, half_view };
        }

        /// How much of the canvas one pixel spans, in world units. Pixels are
        /// square, so one number covers both directions.
        pub fn pixelSize(self: Self) T {
            const half_width, _ = self.halfExtents();
            return half_width * 2 / @as(T, @floatFromInt(self.hsize));
        }

        const Prepared = struct {
            inverse: M,
            origin: Point,
            half_width: T,
            half_height: T,
            pixel_size: T,

            fn init(camera: Self) CameraError!Prepared {
                if (camera.hsize == 0 or camera.vsize == 0) return error.InvalidDimensions;
                if (!std.math.isFinite(camera.field_of_view) or
                    camera.field_of_view <= 0 or camera.field_of_view >= std.math.pi)
                    return error.InvalidFieldOfView;
                const inverse = camera.transform.inverse() catch return error.NonInvertibleCamera;
                const half_width, const half_height = camera.halfExtents();
                return .{
                    .inverse = inverse,
                    .origin = inverse.mulTuple(Point.point(0, 0, 0)),
                    .half_width = half_width,
                    .half_height = half_height,
                    .pixel_size = half_width * 2 / @as(T, @floatFromInt(camera.hsize)),
                };
            }

            fn rayForPixel(self: Prepared, x: usize, y: usize) Ray {
                const world_x = self.half_width - (@as(T, @floatFromInt(x)) + 0.5) * self.pixel_size;
                const world_y = self.half_height - (@as(T, @floatFromInt(y)) + 0.5) * self.pixel_size;
                const pixel = self.inverse.mulTuple(Point.point(world_x, world_y, -1));
                return Ray.init(self.origin, pixel.sub(self.origin).normalize());
            }
        };

        pub const CameraError = error{ InvalidDimensions, InvalidFieldOfView, NonInvertibleCamera };
        pub const RenderError = std.mem.Allocator.Error || Image.InitError || World.TraceError || CameraError;

        pub fn rayForPixel(self: Self, x: usize, y: usize) ?Ray {
            const prepared = Prepared.init(self) catch return null;
            return prepared.rayForPixel(x, y);
        }

        /// Render `world` onto a fresh canvas. The caller owns the result.
        ///
        /// One row is one unit of progress under `parent`; pass
        /// `std.Progress.Node.none` to render silently.
        pub fn render(
            self: Self,
            allocator: std.mem.Allocator,
            world: World,
            parent: std.Progress.Node,
        ) RenderError!Image {
            const prepared = try Prepared.init(self);
            var image = try Image.init(allocator, self.hsize, self.vsize);
            errdefer image.deinit(allocator);

            const progress = parent.start("rows", self.vsize);
            defer progress.end();

            for (0..self.vsize) |y| {
                defer progress.completeOne();
                for (0..self.hsize) |x| {
                    const r = prepared.rayForPixel(x, y);
                    image.writePixel(x, y, try world.colorAt(r));
                }
            }
            return image;
        }
    };
}

/// The camera at the precision the ray tracer uses.
pub const Cam = Camera(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const color = @import("color.zig");
const light = @import("../scene/light.zig");
const shape = @import("../scene/shape.zig");
const transform = @import("../math/transform.zig");

const Col = color.Col;
const Sh = shape.Sh;
const Tf = transform.Tf;
const V = tuple.Tup;
const pi = std.math.pi;

test "constructing a camera" {
    const c = Cam.init(160, 120, pi / 2.0);
    try testing.expectEqual(@as(usize, 160), c.hsize);
    try testing.expectEqual(@as(usize, 120), c.vsize);
    try testing.expectEqual(pi / 2.0, c.field_of_view);
    try testing.expect(c.transform.eql(Cam.M.identity));
}

test "the pixel size is the same for horizontal and vertical canvases" {
    try testing.expect(tuple.feq(f64, 0.01, Cam.init(200, 125, pi / 2.0).pixelSize()));
    try testing.expect(tuple.feq(f64, 0.01, Cam.init(125, 200, pi / 2.0).pixelSize()));
}

test "a ray through the centre of the canvas looks straight ahead" {
    const c = Cam.init(201, 101, pi / 2.0);
    const r = c.rayForPixel(100, 50).?;
    try testing.expect(r.origin.eql(V.point(0, 0, 0)));
    try testing.expect(r.direction.eql(V.vector(0, 0, -1)));
}

test "a ray through a corner of the canvas" {
    const c = Cam.init(201, 101, pi / 2.0);
    const r = c.rayForPixel(0, 0).?;
    try testing.expect(r.origin.eql(V.point(0, 0, 0)));
    try testing.expect(r.direction.eql(V.vector(0.66519, 0.33259, -0.66851)));
}

test "a transformed camera casts its rays from where it stands" {
    var c = Cam.init(201, 101, pi / 2.0);
    c.transform = Tf.rotationY(pi / 4.0).mul(Tf.translation(0, -2, 5));
    const r = c.rayForPixel(100, 50).?;
    const half_root_two = @sqrt(2.0) / 2.0;
    try testing.expect(r.origin.eql(V.point(0, 2, -5)));
    try testing.expect(r.direction.eql(V.vector(half_root_two, 0, -half_root_two)));
}

test "a collapsed camera transformation casts no rays" {
    var c = Cam.init(11, 11, pi / 2.0);
    c.transform = Tf.scaling(0, 0, 0);
    try testing.expect(c.rayForPixel(5, 5) == null);
}

test "render rejects invalid camera literals before allocating" {
    const world: Cam.World = .{};
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 0 }, .{ 0, 0 } }) |size| {
        const c: Cam = .{ .hsize = size[0], .vsize = size[1], .field_of_view = pi / 2.0 };
        try testing.expectError(error.InvalidDimensions, c.render(testing.failing_allocator, world, .none));
        try testing.expect(c.rayForPixel(0, 0) == null);
    }
    for ([_]f64{ 0, -1, pi, pi + 1, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |fov| {
        const c: Cam = .{ .hsize = 1, .vsize = 1, .field_of_view = fov };
        try testing.expectError(error.InvalidFieldOfView, c.render(testing.failing_allocator, world, .none));
        try testing.expect(c.rayForPixel(0, 0) == null);
    }
    var c = Cam.init(1, 1, pi / 2.0);
    c.transform = Tf.scaling(0, 1, 1);
    try testing.expectError(error.NonInvertibleCamera, c.render(testing.failing_allocator, world, .none));
}

test "prepared rays match individual rays across transformed canvases" {
    for ([_][2]usize{ .{ 7, 3 }, .{ 3, 7 } }) |size| {
        var c = Cam.init(size[0], size[1], pi / 3.0);
        c.transform = Tf.rotationY(pi / 4.0).mul(Tf.translation(0, -2, 5));
        const prepared = try Cam.Prepared.init(c);
        try testing.expect(tuple.feq(f64, c.pixelSize(), prepared.pixel_size));
        for (0..c.vsize) |y| {
            for (0..c.hsize) |x| {
                const expected = c.rayForPixel(x, y).?;
                const actual = prepared.rayForPixel(x, y);
                try testing.expect(expected.origin.eql(actual.origin));
                try testing.expect(expected.direction.eql(actual.direction));
            }
        }
    }
}

test "rendering a world with a camera" {
    const objects = [_]Sh{
        .{ .material = .{ .color = Col.init(0.8, 1.0, 0.6), .diffuse = 0.7, .specular = 0.2 } },
        .{ .id = 1, .transform = Tf.scaling(0.5, 0.5, 0.5) },
    };
    const world: Cam.World = .{
        .objects = &objects,
        .light = light.Light.init(V.point(-10, 10, -10), Col.white),
    };

    var c = Cam.init(11, 11, pi / 2.0);
    c.transform = Tf.view(V.point(0, 0, -5), V.point(0, 0, 0), V.vector(0, 1, 0));

    var image = try c.render(testing.allocator, world, .none);
    defer image.deinit(testing.allocator);
    try testing.expect(image.pixelAt(5, 5).eql(Col.init(0.38066, 0.47583, 0.2855)));
}

test "cameras cast rays at comptime" {
    comptime {
        @setEvalBranchQuota(50_000);
        const c = Cam.init(201, 101, pi / 2.0);
        const prepared = try Cam.Prepared.init(c);
        const r = prepared.rayForPixel(100, 50);
        try testing.expect(r.direction.eql(V.vector(0, 0, -1)));
        try testing.expect(prepared.rayForPixel(0, 0).direction.eql(c.rayForPixel(0, 0).?.direction));
    }
}

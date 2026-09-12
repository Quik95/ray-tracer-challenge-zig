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
const noise = @import("../math/noise.zig");
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
        /// How finely each pixel is divided when it is sampled: one ray
        /// through the middle at one, and `n` by `n` rays at `n`. A pixel is
        /// not a point, and a single ray through its middle has to answer for
        /// the whole of it, which turns a diagonal edge into a staircase.
        /// Sampling the pixel in several places and averaging the answers
        /// lets an edge land part way between the colours it divides.
        supersample: usize = 1,
        /// How wide the hole is that light enters through. At zero the camera
        /// is a pinhole and the whole scene is in focus at once; widen it and
        /// light reaches a pixel from several directions, so that whatever is
        /// not at the focal distance is smeared over its neighbours.
        aperture: T = 0,
        /// How far ahead of the camera things come out sharp. Rays cast from
        /// anywhere on the aperture cross at that distance, so the subject of
        /// the picture belongs there.
        focus: T = 1,

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
            supersample: usize,
            aperture: T,
            focus: T,
            /// The camera's own sideways and upwards directions, in world
            /// space: where a point on the aperture moves the ray's start.
            right: Point,
            up: Point,

            fn init(camera: Self) CameraError!Prepared {
                if (camera.hsize == 0 or camera.vsize == 0) return error.InvalidDimensions;
                if (!std.math.isFinite(camera.field_of_view) or
                    camera.field_of_view <= 0 or camera.field_of_view >= std.math.pi)
                    return error.InvalidFieldOfView;
                if (!std.math.isFinite(camera.aperture) or camera.aperture < 0 or
                    !std.math.isFinite(camera.focus) or camera.focus <= 0)
                    return error.InvalidLens;
                const inverse = camera.transform.inverse() catch return error.NonInvertibleCamera;
                const half_width, const half_height = camera.halfExtents();
                return .{
                    .inverse = inverse,
                    .origin = inverse.mulTuple(Point.point(0, 0, 0)),
                    .half_width = half_width,
                    .half_height = half_height,
                    .pixel_size = half_width * 2 / @as(T, @floatFromInt(camera.hsize)),
                    .supersample = @max(1, camera.supersample),
                    .aperture = camera.aperture,
                    .focus = camera.focus,
                    .right = inverse.mulTuple(Point.vector(1, 0, 0)),
                    .up = inverse.mulTuple(Point.vector(0, 1, 0)),
                };
            }

            /// The ray through the point `u` and `v` of the way across the
            /// pixel; half and half is its middle. It starts `lens_x` and
            /// `lens_y` from the middle of the aperture, and is aimed so that
            /// it crosses the focal plane where a ray from the middle would:
            /// what stands there is seen the same way from all of the
            /// aperture and stays sharp, and everything else does not.
            fn rayWithin(self: Prepared, x: usize, y: usize, u: T, v: T, lens_x: T, lens_y: T) Ray {
                const world_x = self.half_width - (@as(T, @floatFromInt(x)) + u) * self.pixel_size;
                const world_y = self.half_height - (@as(T, @floatFromInt(y)) + v) * self.pixel_size;
                const pixel = self.inverse.mulTuple(Point.point(world_x, world_y, -1));

                // The canvas sits one unit ahead, so the focal plane is the
                // same direction carried `focus` times as far.
                const target = self.origin.add(pixel.sub(self.origin).mul(self.focus));
                const start = self.origin.add(self.right.mul(lens_x)).add(self.up.mul(lens_y));
                return Ray.init(start, target.sub(start).normalize());
            }

            fn rayForPixel(self: Prepared, x: usize, y: usize) Ray {
                return self.rayWithin(x, y, 0.5, 0.5, 0, 0);
            }

            /// A place on the round aperture, from two fractions of one. The
            /// square root spreads the places evenly over the disc rather
            /// than crowding them at its middle.
            fn lensPoint(self: Prepared, a: T, b: T) struct { T, T } {
                if (self.aperture == 0) return .{ 0, 0 };
                const radius = self.aperture / 2 * @sqrt(a);
                const angle = 2 * std.math.pi * b;
                return .{ radius * @cos(angle), radius * @sin(angle) };
            }

            /// What the eye sees of one whole pixel: the average of the rays
            /// cast through an evenly spread grid of points inside it.
            fn colorForPixel(self: Prepared, world: World, x: usize, y: usize) World.TraceError!World.C {
                if (self.supersample == 1 and self.aperture == 0) {
                    return world.colorAt(self.rayForPixel(x, y));
                }

                const n = self.supersample;
                const step = 1 / @as(T, @floatFromInt(n));
                // Where on the aperture each of those rays starts is scattered
                // from the pixel's own position, so that a wide aperture comes
                // out as blur rather than as a lattice of ghosts.
                var scatter = noise.Stream.init(.{ x, y });
                var sum = World.C.black;
                for (0..n) |j| {
                    for (0..n) |i| {
                        const u = (@as(T, @floatFromInt(i)) + 0.5) * step;
                        const v = (@as(T, @floatFromInt(j)) + 0.5) * step;
                        const lens_x, const lens_y =
                            self.lensPoint(scatter.unit(T), scatter.unit(T));
                        sum = sum.add(try world.colorAt(self.rayWithin(x, y, u, v, lens_x, lens_y)));
                    }
                }
                return sum.div(@floatFromInt(n * n));
            }
        };

        pub const CameraError = error{ InvalidDimensions, InvalidFieldOfView, InvalidLens, NonInvertibleCamera };
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
                try renderRow(prepared, world, image, y);
                progress.completeOne();
            }
            return image;
        }

        fn renderRow(prepared: Prepared, world: World, image: Image, y: usize) World.TraceError!void {
            for (0..image.width) |x| {
                image.writePixel(x, y, try prepared.colorForPixel(world, x, y));
            }
        }

        fn renderWorker(
            prepared: Prepared,
            world: World,
            image: Image,
            next_row: *std.atomic.Value(usize),
            progress: std.Progress.Node,
        ) World.TraceError!void {
            while (true) {
                const y = next_row.fetchAdd(1, .monotonic);
                if (y >= image.height) return;
                try renderRow(prepared, world, image, y);
                progress.completeOne();
            }
        }

        pub fn renderParallel(
            self: Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            world: World,
            parent: std.Progress.Node,
            worker_count: usize,
        ) RenderError!Image {
            const prepared = try Prepared.init(self);
            const count = @min(self.vsize, @max(1, if (worker_count == 0)
                std.Thread.getCpuCount() catch 1
            else
                worker_count));
            if (count == 1) return self.render(allocator, world, parent);

            var image = try Image.init(allocator, self.hsize, self.vsize);
            errdefer image.deinit(allocator);
            const futures = try allocator.alloc(std.Io.Future(World.TraceError!void), count - 1);
            defer allocator.free(futures);

            const progress = parent.start("rows", self.vsize);
            defer progress.end();
            var next_row: std.atomic.Value(usize) = .init(0);
            var started: usize = 0;
            defer for (futures[0..started]) |*future| {
                future.await(io) catch {};
            };
            for (futures) |*future| {
                future.* = io.concurrent(renderWorker, .{ prepared, world, image, &next_row, progress }) catch break;
                started += 1;
            }
            var failure: ?World.TraceError = null;
            renderWorker(prepared, world, image, &next_row, progress) catch |err| {
                failure = err;
            };
            for (futures[0..started]) |*future| {
                future.await(io) catch |err| {
                    failure = err;
                };
            }
            if (failure) |err| return err;
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

test "parallel rendering matches every serial pixel" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    inline for (.{ f32, f64 }) |T| {
        const Scene = @import("../demo/cubes.zig").Scene(T);
        const objects = Scene.objects();
        const world = Scene.world(&objects);
        for ([_][2]usize{ .{ 13, 7 }, .{ 1, 5 }, .{ 5, 1 } }) |size| {
            const camera = Scene.camera(size[0], size[1]);
            var serial = try camera.render(testing.allocator, world, .none);
            defer serial.deinit(testing.allocator);
            for ([_]usize{ 0, 1, 2, 4, 32 }) |workers| {
                var parallel = try camera.renderParallel(testing.allocator, threaded.io(), world, .none, workers);
                defer parallel.deinit(testing.allocator);
                for (serial.pixels, parallel.pixels) |expected, actual| {
                    try testing.expectEqualDeep(expected, actual);
                }
            }
        }
    }
}

test "parallel rendering falls back when concurrency is unavailable" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const camera = Cam.init(3, 5, pi / 2.0);
    var image = try camera.renderParallel(testing.allocator, threaded.io(), .{}, .none, 4);
    defer image.deinit(testing.allocator);
    for (image.pixels) |pixel| try testing.expect(pixel.eql(Col.black));
}

test "parallel rendering propagates trace and allocation errors" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var camera = Cam.init(3, 5, pi / 2.0);
    camera.transform = Tf.view(V.point(0, 0, -5), V.point(0, 0, 0), V.vector(0, 1, 0));
    const objects = [_]Sh{.{}} ** (Cam.World.max_intersections / 2 + 1);
    try testing.expectError(error.IntersectionOverflow, camera.renderParallel(
        testing.allocator,
        threaded.io(),
        .{ .objects = &objects },
        .none,
        3,
    ));
    try testing.expectError(error.OutOfMemory, camera.renderParallel(testing.failing_allocator, threaded.io(), .{}, .none, 3));
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, camera.renderParallel(failing.allocator(), threaded.io(), .{}, .none, 3));
    camera.hsize = 0;
    try testing.expectError(error.InvalidDimensions, camera.renderParallel(testing.failing_allocator, threaded.io(), .{}, .none, 3));
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

test "a supersampled pixel is the average of the rays cast through it" {
    const objects = [_]Sh{.{ .material = .{ .color = Col.init(1, 0, 0), .ambient = 1, .diffuse = 0, .specular = 0 } }};
    const world: Cam.World = .{
        .objects = &objects,
        .light = light.Light.init(V.point(0, 0, -10), Col.white),
    };

    // A canvas wide enough that the ball covers part of one pixel and none of
    // its neighbour: the edge pixel comes out between the ball and the black
    // behind it, where a single ray through the middle would pick one or the
    // other.
    var sharp = Cam.init(9, 9, pi / 2.0);
    sharp.transform = Tf.view(V.point(0, 0, -5), V.point(0, 0, 0), V.vector(0, 1, 0));
    var smooth = sharp;
    smooth.supersample = 4;

    var hard = try sharp.render(testing.allocator, world, .none);
    defer hard.deinit(testing.allocator);
    var soft = try smooth.render(testing.allocator, world, .none);
    defer soft.deinit(testing.allocator);

    var softened = false;
    for (hard.pixels, soft.pixels) |a, b| {
        if (a.eql(Col.black) or a.eql(Col.init(1, 0, 0))) {
            if (!b.eql(a)) {
                // Wherever the two differ it is because the pixel straddles
                // the ball's outline, and so is part red and part black.
                try testing.expect(b.red() > 0 and b.red() < 1);
                softened = true;
            }
        }
    }
    try testing.expect(softened);
}

test "one sample per pixel is the ray through its middle" {
    const objects = [_]Sh{.{ .material = .{ .color = Col.init(0.8, 1.0, 0.6), .diffuse = 0.7, .specular = 0.2 } }};
    const world: Cam.World = .{
        .objects = &objects,
        .light = light.Light.init(V.point(-10, 10, -10), Col.white),
    };

    var c = Cam.init(7, 5, pi / 2.0);
    c.transform = Tf.view(V.point(0, 0, -5), V.point(0, 0, 0), V.vector(0, 1, 0));
    var plain = try c.render(testing.allocator, world, .none);
    defer plain.deinit(testing.allocator);

    // Zero is no sensible count of rays, so it is read as the single one.
    c.supersample = 0;
    var none = try c.render(testing.allocator, world, .none);
    defer none.deinit(testing.allocator);
    for (plain.pixels, none.pixels) |expected, actual| {
        try testing.expectEqualDeep(expected, actual);
    }
}

test "an aperture of no width leaves the whole scene sharp" {
    const objects = [_]Sh{
        .{ .material = .{ .color = Col.init(0.8, 1.0, 0.6), .diffuse = 0.7, .specular = 0.2 } },
        .{ .id = 1, .transform = Tf.scaling(0.5, 0.5, 0.5) },
    };
    const world: Cam.World = .{
        .objects = &objects,
        .light = light.Light.init(V.point(-10, 10, -10), Col.white),
    };

    var pinhole = Cam.init(9, 9, pi / 2.0);
    pinhole.transform = Tf.view(V.point(0, 0, -5), V.point(0, 0, 0), V.vector(0, 1, 0));
    pinhole.supersample = 2;
    // Where nothing is spread over the aperture, how far off the focal plane
    // a thing stands makes no difference to it.
    var focused = pinhole;
    focused.focus = 4;

    var a = try pinhole.render(testing.allocator, world, .none);
    defer a.deinit(testing.allocator);
    var b = try focused.render(testing.allocator, world, .none);
    defer b.deinit(testing.allocator);
    for (a.pixels, b.pixels) |expected, actual| {
        try testing.expectEqualDeep(expected, actual);
    }
}

test "a wide aperture blurs what does not stand at the focal distance" {
    // One ball at the focal distance and one well behind it, side by side.
    const objects = [_]Sh{
        .{ .transform = Tf.translation(-1.2, 0, 0), .material = .{ .color = Col.init(1, 0, 0), .ambient = 1, .diffuse = 0, .specular = 0 } },
        .{ .id = 1, .transform = Tf.translation(1.6, 0, 6), .material = .{ .color = Col.init(0, 0, 1), .ambient = 1, .diffuse = 0, .specular = 0 } },
    };
    const world: Cam.World = .{
        .objects = &objects,
        .light = light.Light.init(V.point(-10, 10, -10), Col.white),
    };

    var c = Cam.init(41, 21, pi / 3.0);
    c.transform = Tf.view(V.point(0, 0, -5), V.point(0, 0, 0), V.vector(0, 1, 0));
    c.supersample = 4;
    c.aperture = 0.8;
    c.focus = 5;

    var image = try c.render(testing.allocator, world, .none);
    defer image.deinit(testing.allocator);

    // The near ball's outline is where the camera is focused, so it keeps the
    // hard edge between red and black; the far ball's is smeared into the
    // black around it, and leaves pixels of neither colour behind.
    var mixed_near: usize = 0;
    var mixed_far: usize = 0;
    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const p = image.pixelAt(x, y);
            const partial = p.red() > 0.01 and p.red() < 0.99;
            const hazy = p.blue() > 0.01 and p.blue() < 0.99;
            if (partial) mixed_near += 1;
            if (hazy) mixed_far += 1;
        }
    }
    try testing.expect(mixed_far > mixed_near);
}

test "a camera with an impossible lens renders nothing" {
    const world: Cam.World = .{};
    for ([_]f64{ -1, std.math.inf(f64), std.math.nan(f64) }) |aperture| {
        var c = Cam.init(1, 1, pi / 2.0);
        c.aperture = aperture;
        try testing.expectError(error.InvalidLens, c.render(testing.failing_allocator, world, .none));
    }
    for ([_]f64{ 0, -2, std.math.inf(f64), std.math.nan(f64) }) |focus| {
        var c = Cam.init(1, 1, pi / 2.0);
        c.focus = focus;
        try testing.expectError(error.InvalidLens, c.render(testing.failing_allocator, world, .none));
    }
}

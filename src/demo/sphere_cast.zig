//! A sphere's shadow, cast pixel by pixel onto a wall behind it.
//!
//! This is the ray tracer at its smallest: no world, no camera, just an eye at
//! a fixed point firing one ray per pixel at a flat wall, and a single unit
//! sphere in the way: every ray the sphere stops is marked, and what that
//! leaves behind is its outline.

const std = @import("std");
const canvas = @import("../render/canvas.zig");
const color = @import("../render/color.zig");
const ray_mod = @import("../scene/ray.zig");
const shape = @import("../scene/shape.zig");
const transform = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");

/// The frame both drawings are made in, over a float type.
pub fn Cast(comptime T: type) type {
    return struct {
        pub const C = color.Color(T);
        pub const Image = canvas.Canvas(C);
        pub const Object = shape.Shape(T);
        pub const Ray = ray_mod.Ray(T);
        pub const Tf = transform.Transforms(T);
        pub const V = tuple.Tuple(T);

        /// The eye sits back along -z; the wall stands square across +z, far
        /// enough behind the sphere that the shadow spreads to nearly fill it.
        pub const eye: V = .point(0, 0, -5);
        pub const wall_z: T = 10;
        /// Rays from the eye past a unit sphere have spread to six units
        /// across by the time they reach the wall; seven leaves a margin.
        pub const wall_size: T = 7;

        /// Where on the wall the pixel at (x, y) falls. The canvas counts y
        /// downwards and the world counts it up, so the row index is
        /// subtracted from the top edge rather than added to the bottom.
        pub fn wallPoint(image: Image, x: usize, y: usize) V {
            const across: T = @floatFromInt(image.width);
            const down: T = @floatFromInt(image.height);
            // The shorter side of the canvas spans the wall; the longer one
            // sees further, rather than stretching the same view across more
            // pixels and flattening the sphere into an ellipse.
            const per_pixel = wall_size / @min(across, down);
            const fx: T = @floatFromInt(x);
            const fy: T = @floatFromInt(y);
            return .point(
                (fx + 0.5 - across / 2) * per_pixel,
                (down / 2 - fy - 0.5) * per_pixel,
                wall_z,
            );
        }

        /// The ray leaving the eye for that pixel. Normalized, so that a `t`
        /// it comes back with is a distance and the shading that uses it is
        /// not skewed by how far away the wall happens to be.
        pub fn rayFor(image: Image, x: usize, y: usize) Ray {
            return .init(eye, wallPoint(image, x, y).sub(eye).normalize());
        }
    };
}

/// The outline alone: red where the sphere is, black where it is not.
pub fn Silhouette(comptime T: type) type {
    return struct {
        pub const Frame = Cast(T);
        pub const C = Frame.C;
        pub const Image = Frame.Image;
        pub const Object = Frame.Object;

        pub const name = "silhouette";
        pub const group = "rays";

        pub const ink: C = .init(1, 0, 0);

        pub fn sphere() Object {
            return .{};
        }

        pub fn draw(image: Image) void {
            const ball = sphere();
            for (0..image.height) |y| {
                for (0..image.width) |x| {
                    const hits = ball.intersect(Frame.rayFor(image, x, y));
                    if (Object.Hit.hit(hits.items()) != null) image.writePixel(x, y, ink);
                }
            }
        }
    };
}

pub const DefaultSilhouette = Silhouette(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "the wall is centred on the sphere and read top-down" {
    const image: Cast(f64).Image = .{ .width = 10, .height = 10, .pixels = &.{} };
    const top_left = Cast(f64).wallPoint(image, 0, 0);
    const bottom_right = Cast(f64).wallPoint(image, 9, 9);

    try testing.expect(top_left.x() < 0 and top_left.y() > 0);
    try testing.expect(bottom_right.x() > 0 and bottom_right.y() < 0);
    try testing.expect(tuple.feq(f64, top_left.z(), Cast(f64).wall_z));
    // Symmetric about the centre, so the shadow lands in the middle.
    try testing.expect(tuple.feq(f64, top_left.x(), -bottom_right.x()));
    try testing.expect(tuple.feq(f64, top_left.y(), -bottom_right.y()));
}

test "the rays leaving the eye are unit length" {
    const image: Cast(f64).Image = .{ .width = 4, .height = 4, .pixels = &.{} };
    for (0..4) |y| for (0..4) |x| {
        const r = Cast(f64).rayFor(image, x, y);
        try testing.expect(tuple.feq(f64, r.direction.magnitude(), 1));
        try testing.expect(r.origin.eql(Cast(f64).eye));
    };
}

test "the silhouette is round: filled in the middle, empty at the corners" {
    var image = try DefaultSilhouette.Image.init(testing.allocator, 21, 21);
    defer image.deinit(testing.allocator);
    DefaultSilhouette.draw(image);

    try testing.expect(image.pixelAt(10, 10).eql(DefaultSilhouette.ink));
    try testing.expect(image.pixelAt(0, 0).eql(DefaultSilhouette.C.black));
    try testing.expect(image.pixelAt(20, 20).eql(DefaultSilhouette.C.black));
}

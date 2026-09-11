//! The Ray Tracer Challenge, implemented in Zig.

const std = @import("std");

// Referencing an import is what makes the compiler analyze that file, which is
// what makes its `test` blocks run under `zig build test`. Zig 0.16 removed
// `std.testing.refAllDeclsRecursive`; the maintainers' advice is to list
// declarations explicitly, so every module of this package is named here.
// Numbers and geometry.
pub const tuple = @import("math/tuple.zig");
pub const matrix = @import("math/matrix.zig");
pub const transform = @import("math/transform.zig");

// What a ray meets, and what it meets it with.
pub const ray = @import("scene/ray.zig");
pub const intersection = @import("scene/intersection.zig");
pub const sphere = @import("scene/sphere.zig");
pub const light = @import("scene/light.zig");
pub const material = @import("scene/material.zig");
pub const world = @import("scene/world.zig");

// Pixels, and getting them out of the program.
pub const color = @import("render/color.zig");
pub const canvas = @import("render/canvas.zig");
pub const camera = @import("render/camera.zig");

// Scenes the demo program can draw.
pub const projectile = @import("demo/projectile.zig");
pub const clock = @import("demo/clock.zig");
pub const spheres = @import("demo/spheres.zig");

/// Generic 4-tuple, parameterized by float type.
pub const Tuple = tuple.Tuple;
/// The f64 tuple used throughout the ray tracer.
pub const Tup = tuple.Tup;
pub const Axis = tuple.Axis;
pub const feq = tuple.feq;

/// Generic RGB color, parameterized by float type.
pub const Color = color.Color;
/// The f64 color used throughout the ray tracer.
pub const Col = color.Col;
pub const Channel = color.Channel;

/// Generic square matrix, parameterized by float type and size.
pub const Matrix = matrix.Matrix;
/// The matrix sizes the ray tracer works in.
pub const Mat2 = matrix.Mat2;
pub const Mat3 = matrix.Mat3;
pub const Mat4 = matrix.Mat4;

/// The transformation matrices, over a float type.
pub const Transforms = transform.Transforms;
/// The transformations at the precision the ray tracer uses.
pub const Tf = transform.Tf;

/// Generic ray, parameterized by float type.
pub const Ray = ray.Ray;
/// The ray at the precision the ray tracer uses.
pub const R = ray.R;

/// Generic ray-object intersection.
pub const Intersection = intersection.Intersection;

/// Generic sphere, parameterized by float type.
pub const Sphere = sphere.Sphere;
/// The sphere at the precision the ray tracer uses.
pub const S = sphere.S;

/// Generic point light, parameterized by float type.
pub const PointLight = light.PointLight;
/// The point light at the precision the ray tracer uses.
pub const Light = light.Light;

/// Generic surface material, parameterized by float type.
pub const Material = material.Material;
/// The material at the precision the ray tracer uses.
pub const Mat = material.Mat;

/// Generic world of objects and a light, parameterized by float type.
pub const World = world.World;
/// The world at the precision the ray tracer uses.
pub const W = world.W;

/// Generic camera, parameterized by float type.
pub const Camera = camera.Camera;
/// The camera at the precision the ray tracer uses.
pub const Cam = camera.Cam;

/// Generic pixel grid, parameterized by color type.
pub const Canvas = canvas.Canvas;
/// The canvas the ray tracer renders into.
pub const Image = canvas.Image;

/// Source files whose tests are pulled in by the imports above. Kept in sync
/// with `src/` by the test below, so adding a file and forgetting to import it
/// fails the suite instead of silently skipping its tests.
const covered_sources = [_][]const u8{
    "root.zig",
    "math/tuple.zig",
    "math/matrix.zig",
    "math/transform.zig",
    "scene/ray.zig",
    "scene/intersection.zig",
    "scene/sphere.zig",
    "scene/light.zig",
    "scene/material.zig",
    "scene/world.zig",
    "render/color.zig",
    "render/canvas.zig",
    "render/camera.zig",
    "demo/projectile.zig",
    "demo/clock.zig",
    "demo/spheres.zig",
    // Root of the executable module, covered by its own test binary.
    "main.zig",
};

test {
    _ = tuple;
    _ = color;
    _ = canvas;
    _ = matrix;
    _ = transform;
    _ = projectile;
    _ = clock;
    _ = ray;
    _ = intersection;
    _ = sphere;
    _ = light;
    _ = material;
    _ = world;
    _ = camera;
    _ = spheres;
}

test "every file in src/ is imported here" {
    // build.zig scans src/ and hands the real listing over as an option.
    const on_disk = @import("source_files").names;

    for (on_disk) |name| {
        for (covered_sources) |covered| {
            if (std.mem.eql(u8, name, covered)) break;
        } else {
            std.debug.print(
                "src/{s} is not imported by src/root.zig, so its tests never run\n",
                .{name},
            );
            return error.UnimportedSourceFile;
        }
    }
}

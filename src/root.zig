//! The Ray Tracer Challenge, implemented in Zig.

const std = @import("std");

// Referencing an import is what makes the compiler analyze that file, which is
// what makes its `test` blocks run under `zig build test`. Zig 0.16 removed
// `std.testing.refAllDeclsRecursive`; the maintainers' advice is to list
// declarations explicitly, so every module of this package is named here.
pub const tuple = @import("tuple.zig");
pub const color = @import("color.zig");
pub const canvas = @import("canvas.zig");
pub const projectile = @import("projectile.zig");

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

/// Generic pixel grid, parameterized by color type.
pub const Canvas = canvas.Canvas;
/// The canvas the ray tracer renders into.
pub const Image = canvas.Image;

/// Source files whose tests are pulled in by the imports above. Kept in sync
/// with `src/` by the test below, so adding a file and forgetting to import it
/// fails the suite instead of silently skipping its tests.
const covered_sources = [_][]const u8{
    "root.zig",
    "tuple.zig",
    "color.zig",
    "canvas.zig",
    "projectile.zig",
    // Root of the executable module, covered by its own test binary.
    "main.zig",
};

test {
    _ = tuple;
    _ = color;
    _ = canvas;
    _ = projectile;
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

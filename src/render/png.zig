//! Writing a canvas out as a PNG.
//!
//! The canvas stores colors as floats, unbounded and linear; PNG stores eight
//! bits per channel. The conversion between the two is the same clamp and
//! scale the PPM writer performs, so both formats render a canvas identically.

const std = @import("std");
const zigimg = @import("zigimg");
const canvas = @import("canvas.zig");
const color = @import("color.zig");

const Allocator = std.mem.Allocator;

/// The canvas as tightly packed 8-bit RGB, row by row from the top left —
/// the layout PNG stores and the one zigimg calls `rgb24`. Caller owns it.
pub fn toRgb24(image: anytype, allocator: Allocator) Allocator.Error![]u8 {
    const channels = 3;
    const bytes = try allocator.alloc(u8, image.pixels.len * channels);
    errdefer allocator.free(bytes);

    for (image.pixels, 0..) |pixel, i| {
        inline for (.{ .red, .green, .blue }, 0..) |channel, c| {
            bytes[i * channels + c] = pixel.scaleChannel(channel, canvas.max_color_value);
        }
    }
    return bytes;
}

pub const WriteError = Allocator.Error || zigimg.Image.WriteError;

/// Wrap packed bytes as an image zigimg can encode. The wrapper borrows the
/// bytes rather than copying them, so they must outlive it — and it must not
/// be deinitialized, or it would free a buffer it does not own.
fn borrow(image: anytype, bytes: []const u8) zigimg.Image.Error!zigimg.Image {
    return zigimg.Image.fromRawPixelsOwned(image.width, image.height, bytes, .rgb24);
}

/// Write the canvas to an already-open file as a PNG.
pub fn writeFile(image: anytype, allocator: Allocator, io: std.Io, file: std.Io.File) WriteError!void {
    const bytes = try toRgb24(image, allocator);
    defer allocator.free(bytes);

    const wrapped = try borrow(image, bytes);
    var buffer: [64 * 1024]u8 = undefined;
    try wrapped.writeToFile(allocator, io, file, &buffer, .{ .png = .{} });
}

/// The PNG image as a freshly allocated buffer. Caller owns it.
pub fn toPng(image: anytype, allocator: Allocator) WriteError![]u8 {
    const bytes = try toRgb24(image, allocator);
    defer allocator.free(bytes);

    const wrapped = try borrow(image, bytes);

    // The encoder writes into a fixed buffer rather than growing one, so it
    // gets room for the pixels uncompressed plus slack for headers and for
    // the per-row filter bytes. Compressed output cannot exceed that.
    const slack = 64 * 1024 + image.height;
    const buffer = try allocator.alloc(u8, bytes.len + slack);
    defer allocator.free(buffer);

    const encoded = try wrapped.writeToMemory(allocator, buffer, .{ .png = .{} });
    return allocator.dupe(u8, encoded);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const C = color.Col;

test "packing a canvas into RGB bytes clamps and scales each channel" {
    var c = try canvas.Image.init(testing.allocator, 2, 1);
    defer c.deinit(testing.allocator);

    c.writePixel(0, 0, C.init(1.5, 0.5, -0.5));
    c.writePixel(1, 0, C.init(0, 0, 1));

    const bytes = try toRgb24(c, testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 0, 0, 255 }, bytes);
}

test "a PNG opens with the signature and carries the canvas size" {
    var c = try canvas.Image.init(testing.allocator, 5, 3);
    defer c.deinit(testing.allocator);

    const png = try toPng(c, testing.allocator);
    defer testing.allocator.free(png);

    try testing.expect(std.mem.startsWith(u8, png, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }));

    var decoded = try zigimg.Image.fromMemory(testing.allocator, png);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), decoded.width);
    try testing.expectEqual(@as(usize, 3), decoded.height);
}

test "a canvas survives the round trip through a PNG" {
    var c = try canvas.Image.init(testing.allocator, 7, 4);
    defer c.deinit(testing.allocator);

    // A gradient rather than flat colour, so a wrong row stride or a mixed-up
    // channel order shows up instead of hiding behind uniform pixels.
    for (0..c.height) |y| {
        for (0..c.width) |x| {
            const fx = @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(c.width - 1));
            const fy = @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(c.height - 1));
            c.writePixel(x, y, C.init(fx, fy, 0.25));
        }
    }

    const png = try toPng(c, testing.allocator);
    defer testing.allocator.free(png);

    var decoded = try zigimg.Image.fromMemory(testing.allocator, png);
    defer decoded.deinit(testing.allocator);

    const expected = try toRgb24(c, testing.allocator);
    defer testing.allocator.free(expected);

    try testing.expectEqualSlices(u8, expected, std.mem.sliceAsBytes(decoded.pixels.rgb24));
}

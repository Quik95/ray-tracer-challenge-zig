//! Writing a canvas out as an AVIF: one AV1 intra frame in a HEIF container,
//! encoded by the system libavif.
//!
//! The encoder is handed the same 8-bit bytes the PNG writer stores and told
//! they are sRGB, so a viewer shows both files alike. Chroma is kept at full
//! resolution (4:4:4) rather than the 4:2:0 photos get: a render is full of
//! hard edges between saturated colors, and halving chroma smears them.

const std = @import("std");
const build_options = @import("build_options");
const canvas = @import("canvas.zig");
const color = @import("color.zig");
const png = @import("png.zig");

const Allocator = std.mem.Allocator;

/// Whether this build links libavif (`-Davif`). Nothing else here may be
/// referenced when it does not.
pub const available = build_options.avif;
const c = if (available) @import("avif_c") else struct {};

pub const Options = struct {
    /// 0 is the smallest file, 100 is lossless; anything above means 100.
    /// Lossless stores RGB as is instead of converting to YCbCr, since the
    /// conversion itself rounds.
    quality: u7 = 80,
    /// 0 is the slowest search for the smallest file, 10 the fastest;
    /// anything above means 10.
    speed: u4 = 6,

    const lossless = 100;
    const fastest = 10;
};

pub const EncodeError = Allocator.Error || error{ ImageTooLarge, AvifEncodeFailed };
pub const WriteError = EncodeError || std.Io.File.Writer.Error;

/// Write the canvas to an already-open file as an AVIF.
pub fn writeFile(image: anytype, allocator: Allocator, io: std.Io, file: std.Io.File, options: Options) WriteError!void {
    var encoded = try encode(image, allocator, options);
    defer c.avifRWDataFree(&encoded);
    try file.writeStreamingAll(io, encoded.data[0..encoded.size]);
}

/// The AVIF image as a freshly allocated buffer. Caller owns it.
pub fn toAvif(image: anytype, allocator: Allocator, options: Options) EncodeError![]u8 {
    var encoded = try encode(image, allocator, options);
    defer c.avifRWDataFree(&encoded);
    return allocator.dupe(u8, encoded.data[0..encoded.size]);
}

/// The encoded file, in a buffer libavif owns: free it with `avifRWDataFree`.
fn encode(image: anytype, allocator: Allocator, options: Options) EncodeError!c.avifRWData {
    const width = std.math.cast(u32, image.width) orelse return error.ImageTooLarge;
    const height = std.math.cast(u32, image.height) orelse return error.ImageTooLarge;
    const row_bytes = std.math.mul(u32, width, 3) catch return error.ImageTooLarge;

    const rgb24 = try png.toRgb24(image, allocator);
    defer allocator.free(rgb24);

    const quality = @min(options.quality, Options.lossless);
    const lossless = quality == Options.lossless;

    const yuv = c.avifImageCreate(width, height, 8, c.AVIF_PIXEL_FORMAT_YUV444);
    if (yuv == null) return error.OutOfMemory;
    defer c.avifImageDestroy(yuv);
    yuv.*.yuvRange = c.AVIF_RANGE_FULL;
    yuv.*.colorPrimaries = c.AVIF_COLOR_PRIMARIES_BT709;
    yuv.*.transferCharacteristics = c.AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    yuv.*.matrixCoefficients = if (lossless)
        c.AVIF_MATRIX_COEFFICIENTS_IDENTITY
    else
        c.AVIF_MATRIX_COEFFICIENTS_BT601;

    // SAFETY: avifRGBImageSetDefaults fills in every field.
    var rgb: c.avifRGBImage = undefined;
    c.avifRGBImageSetDefaults(&rgb, yuv);
    rgb.format = c.AVIF_RGB_FORMAT_RGB;
    rgb.rowBytes = row_bytes;
    // The conversion only reads the pixels; the field is mutable because the
    // same struct also receives them when decoding.
    rgb.pixels = @constCast(rgb24.ptr);
    try check(c.avifImageRGBToYUV(yuv, &rgb));

    const encoder = c.avifEncoderCreate();
    if (encoder == null) return error.OutOfMemory;
    defer c.avifEncoderDestroy(encoder);
    encoder.*.quality = quality;
    encoder.*.speed = @min(options.speed, Options.fastest);
    encoder.*.maxThreads = @intCast(@min(std.Thread.getCpuCount() catch 1, std.math.maxInt(c_int)));

    var encoded: c.avifRWData = .{ .data = null, .size = 0 };
    try check(c.avifEncoderWrite(encoder, yuv, &encoded));
    return encoded;
}

fn check(result: c.avifResult) EncodeError!void {
    switch (result) {
        c.AVIF_RESULT_OK => {},
        c.AVIF_RESULT_OUT_OF_MEMORY => return error.OutOfMemory,
        else => {
            std.log.err("libavif: {s}", .{c.avifResultToString(result)});
            return error.AvifEncodeFailed;
        },
    }
}

const testing = std.testing;
const C = color.Col;

/// A gradient rather than flat colour, so a wrong row stride or a mixed-up
/// channel order shows up instead of hiding behind uniform pixels.
fn gradient(width: usize, height: usize) !canvas.Image {
    var image = try canvas.Image.init(testing.allocator, width, height);
    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1));
            const fy = @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height - 1));
            image.writePixel(x, y, C.init(fx, fy, 0.25));
        }
    }
    return image;
}

/// Decode an AVIF back to packed 8-bit RGB through libavif. Caller owns it.
fn decodeRgb24(avif: []const u8, width: usize, height: usize) ![]u8 {
    const decoder = c.avifDecoderCreate();
    if (decoder == null) return error.OutOfMemory;
    defer c.avifDecoderDestroy(decoder);

    const yuv = c.avifImageCreateEmpty();
    if (yuv == null) return error.OutOfMemory;
    defer c.avifImageDestroy(yuv);

    if (c.avifDecoderReadMemory(decoder, yuv, avif.ptr, avif.len) != c.AVIF_RESULT_OK)
        return error.AvifDecodeFailed;
    try testing.expectEqual(width, yuv.*.width);
    try testing.expectEqual(height, yuv.*.height);
    try testing.expectEqual(8, yuv.*.depth);

    const bytes = try testing.allocator.alloc(u8, width * height * 3);
    errdefer testing.allocator.free(bytes);
    // SAFETY: avifRGBImageSetDefaults fills in every field.
    var rgb: c.avifRGBImage = undefined;
    c.avifRGBImageSetDefaults(&rgb, yuv);
    rgb.format = c.AVIF_RGB_FORMAT_RGB;
    rgb.rowBytes = @intCast(width * 3);
    rgb.pixels = bytes.ptr;
    if (c.avifImageYUVToRGB(yuv, &rgb) != c.AVIF_RESULT_OK) return error.AvifDecodeFailed;
    return bytes;
}

test "an AVIF opens with a file type box naming the avif brand" {
    if (!available) return error.SkipZigTest;
    var image = try canvas.Image.init(testing.allocator, 5, 3);
    defer image.deinit(testing.allocator);

    const avif = try toAvif(image, testing.allocator, .{});
    defer testing.allocator.free(avif);

    try testing.expectEqualStrings("ftyp", avif[4..8]);
    try testing.expectEqualStrings("avif", avif[8..12]);
}

test "a lossless AVIF gives the canvas back exactly" {
    if (!available) return error.SkipZigTest;
    var image = try gradient(7, 4);
    defer image.deinit(testing.allocator);

    const avif = try toAvif(image, testing.allocator, .{ .quality = 100 });
    defer testing.allocator.free(avif);

    const decoded = try decodeRgb24(avif, image.width, image.height);
    defer testing.allocator.free(decoded);
    const expected = try png.toRgb24(image, testing.allocator);
    defer testing.allocator.free(expected);

    try testing.expectEqualSlices(u8, expected, decoded);
}

test "a lossy AVIF keeps every pixel near the canvas" {
    if (!available) return error.SkipZigTest;
    var image = try gradient(32, 16);
    defer image.deinit(testing.allocator);

    const avif = try toAvif(image, testing.allocator, .{ .quality = 80 });
    defer testing.allocator.free(avif);

    const decoded = try decodeRgb24(avif, image.width, image.height);
    defer testing.allocator.free(decoded);
    const expected = try png.toRgb24(image, testing.allocator);
    defer testing.allocator.free(expected);

    for (expected, decoded) |want, got| {
        try testing.expect(@abs(@as(i16, want) - got) <= 12);
    }
}

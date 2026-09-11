//! A rectangular grid of pixels, and its serialization to plain PPM.

const std = @import("std");
const color = @import("color.zig");

const Allocator = std.mem.Allocator;

/// Largest component value a plain PPM pixel may carry. 255 gives one byte per
/// channel, which every image viewer understands.
pub const max_color_value: u8 = 255;

/// The PPM spec allows lines of at most 70 characters. Most viewers are more
/// forgiving, but the ones that are not fail silently, so rows get wrapped.
const max_line_len: usize = 70;

/// A canvas of pixels, generic over the color type it stores.
pub fn Canvas(comptime Col: type) type {
    return struct {
        const Self = @This();

        pub const Pixel = Col;

        width: usize,
        height: usize,
        /// Row-major, `width * height` entries. The origin is the top-left
        /// corner and y grows downwards, matching how image files are read.
        pixels: []Col,

        pub const InitError = Allocator.Error || error{Overflow};

        /// A canvas of the given size, every pixel black.
        pub fn init(allocator: Allocator, width: usize, height: usize) InitError!Self {
            const count = try std.math.mul(usize, width, height);
            _ = try std.math.mul(usize, count, @sizeOf(Col));
            const pixels = try allocator.alloc(Col, count);
            @memset(pixels, Col.black);
            return .{ .width = width, .height = height, .pixels = pixels };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.pixels);
            self.* = undefined;
        }

        pub inline fn contains(self: Self, x: usize, y: usize) bool {
            return x < self.width and y < self.height;
        }

        inline fn indexOf(self: Self, x: usize, y: usize) usize {
            std.debug.assert(self.contains(x, y));
            return y * self.width + x;
        }

        /// Colour the pixel at (x, y). Coordinates are 0-based and must be in
        /// bounds; use `plot` when they come from a computation that may stray
        /// off the canvas.
        pub fn writePixel(self: Self, x: usize, y: usize, c: Col) void {
            self.pixels[self.indexOf(x, y)] = c;
        }

        /// Like `writePixel`, but silently drops points outside the canvas.
        /// Returns whether the pixel landed. World coordinates routinely run
        /// past the edges, and clipping them is the expected behaviour rather
        /// than an error.
        pub fn plot(self: Self, x: isize, y: isize, c: Col) bool {
            if (x < 0 or y < 0) return false;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            if (!self.contains(ux, uy)) return false;
            self.writePixel(ux, uy, c);
            return true;
        }

        pub fn pixelAt(self: Self, x: usize, y: usize) Col {
            return self.pixels[self.indexOf(x, y)];
        }

        pub fn fill(self: Self, c: Col) void {
            @memset(self.pixels, c);
        }

        /// Write the canvas as a plain (P3) PPM image.
        pub fn writePpm(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("P3\n{d} {d}\n{d}\n", .{ self.width, self.height, max_color_value });

            for (0..self.height) |y| {
                const row = self.pixels[y * self.width ..][0..self.width];
                // Tracks the length of the line being built so a row can be
                // broken at a space rather than in the middle of a number.
                var line_len: usize = 0;
                for (row) |pixel| {
                    inline for (.{ .red, .green, .blue }) |channel| {
                        var buf: [3]u8 = undefined;
                        const text = std.fmt.bufPrint(
                            &buf,
                            "{d}",
                            .{pixel.scaleChannel(channel, max_color_value)},
                        ) catch unreachable;

                        if (line_len == 0) {
                            // Nothing on this line yet.
                        } else if (line_len + 1 + text.len > max_line_len) {
                            try writer.writeByte('\n');
                            line_len = 0;
                        } else {
                            try writer.writeByte(' ');
                            line_len += 1;
                        }
                        try writer.writeAll(text);
                        line_len += text.len;
                    }
                }
                try writer.writeByte('\n');
            }
        }

        /// The PPM image as a freshly allocated string. Caller owns it.
        pub fn toPpm(self: Self, allocator: Allocator) Allocator.Error![]u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            self.writePpm(&out.writer) catch return error.OutOfMemory;
            return out.toOwnedSlice();
        }
    };
}

/// The canvas the ray tracer renders into.
pub const Image = Canvas(color.Col);

// --- Tests ------------------------------------------------------------------

test "canvas rejects pixel count and allocation byte overflow" {
    inline for (.{ f32, f64 }) |T| {
        const P = Canvas(color.Color(T));
        const max = std.math.maxInt(usize);
        try testing.expectError(error.Overflow, P.init(testing.allocator, max, 2));
        try testing.expectError(error.Overflow, P.init(testing.allocator, max / @sizeOf(P.Pixel) + 1, 1));
        var empty = try P.init(testing.allocator, max, 0);
        defer empty.deinit(testing.allocator);
        try testing.expectEqual(0, empty.pixels.len);
    }
}

const testing = std.testing;
const C = color.Col;

/// Lines `from` through `to` of `text`, 1-based and inclusive, without the
/// trailing newline — the shape the PPM scenarios are written in.
fn lines(text: []const u8, from: usize, to: usize) []const u8 {
    var start: usize = 0;
    var line: usize = 1;
    while (line < from) : (line += 1) {
        const break_at = std.mem.indexOfScalar(u8, text[start..], '\n') orelse return text[text.len..];
        start += break_at + 1;
    }

    var end = start;
    while (line <= to) : (line += 1) {
        const break_at = std.mem.indexOfScalar(u8, text[end..], '\n') orelse return text[start..];
        end += break_at + 1;
    }
    // Drop the newline that closed the last line of the range.
    return text[start .. end - 1];
}

test "creating a canvas fills it with black" {
    var c = try Image.init(testing.allocator, 10, 20);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 10), c.width);
    try testing.expectEqual(@as(usize, 20), c.height);
    for (c.pixels) |pixel| try testing.expect(pixel.eql(C.black));
}

test "writing pixels to a canvas" {
    var c = try Image.init(testing.allocator, 10, 20);
    defer c.deinit(testing.allocator);

    const red = C.init(1, 0, 0);
    c.writePixel(2, 3, red);
    try testing.expect(c.pixelAt(2, 3).eql(red));
    try testing.expect(c.pixelAt(3, 2).eql(C.black));
}

test "plotting outside the canvas is ignored" {
    var c = try Image.init(testing.allocator, 4, 4);
    defer c.deinit(testing.allocator);

    const red = C.init(1, 0, 0);
    try testing.expect(!c.plot(-1, 2, red));
    try testing.expect(!c.plot(2, -1, red));
    try testing.expect(!c.plot(4, 0, red));
    try testing.expect(!c.plot(0, 4, red));
    try testing.expect(c.plot(3, 3, red));
    try testing.expect(c.pixelAt(3, 3).eql(red));
}

test "constructing the PPM header" {
    var c = try Image.init(testing.allocator, 5, 3);
    defer c.deinit(testing.allocator);

    const ppm = try c.toPpm(testing.allocator);
    defer testing.allocator.free(ppm);

    try testing.expectEqualStrings("P3\n5 3\n255", lines(ppm, 1, 3));
}

test "constructing the PPM pixel data" {
    var c = try Image.init(testing.allocator, 5, 3);
    defer c.deinit(testing.allocator);

    c.writePixel(0, 0, C.init(1.5, 0, 0));
    c.writePixel(2, 1, C.init(0, 0.5, 0));
    c.writePixel(4, 2, C.init(-0.5, 0, 1));

    const ppm = try c.toPpm(testing.allocator);
    defer testing.allocator.free(ppm);

    try testing.expectEqualStrings(
        \\255 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        \\0 0 0 0 0 0 0 128 0 0 0 0 0 0 0
        \\0 0 0 0 0 0 0 0 0 0 0 0 0 0 255
    , lines(ppm, 4, 6));
}

test "long rows are split so no line exceeds 70 characters" {
    var c = try Image.init(testing.allocator, 10, 2);
    defer c.deinit(testing.allocator);
    c.fill(C.init(1, 0.8, 0.6));

    const ppm = try c.toPpm(testing.allocator);
    defer testing.allocator.free(ppm);

    try testing.expectEqualStrings(
        \\255 204 153 255 204 153 255 204 153 255 204 153 255 204 153 255 204
        \\153 255 204 153 255 204 153 255 204 153 255 204 153
        \\255 204 153 255 204 153 255 204 153 255 204 153 255 204 153 255 204
        \\153 255 204 153 255 204 153 255 204 153 255 204 153
    , lines(ppm, 4, 7));

    var it = std.mem.splitScalar(u8, ppm, '\n');
    while (it.next()) |line| try testing.expect(line.len <= 70);
}

test "PPM files are terminated by a newline character" {
    var c = try Image.init(testing.allocator, 5, 3);
    defer c.deinit(testing.allocator);

    const ppm = try c.toPpm(testing.allocator);
    defer testing.allocator.free(ppm);

    try testing.expect(std.mem.endsWith(u8, ppm, "\n"));
}

test "a zero-height canvas still produces a valid header" {
    var c = try Image.init(testing.allocator, 5, 0);
    defer c.deinit(testing.allocator);

    const ppm = try c.toPpm(testing.allocator);
    defer testing.allocator.free(ppm);

    try testing.expectEqualStrings("P3\n5 0\n255\n", ppm);
}

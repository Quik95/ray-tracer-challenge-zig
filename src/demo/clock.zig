//! The hour marks of an analog clock face, placed by rotation.
//!
//! The face lies in the xz plane, centred on the origin and one unit across,
//! viewed down the negative y axis: twelve o'clock sits at (0, 0, 1) and each
//! following hour is a twelfth of a turn about y away from it.

const std = @import("std");
const canvas = @import("../render/canvas.zig");
const color = @import("../render/color.zig");
const transform = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");

/// The clock face, over a float type.
pub fn Clock(comptime T: type) type {
    return struct {
        pub const Tf = transform.Transforms(T);
        pub const Point = tuple.Tuple(T);

        pub const hours = 12;

        /// The mark the others are rotated from.
        pub const twelve: Point = .point(0, 0, 1);

        /// Angle between neighbouring hours.
        pub const hour_angle: T = 2 * std.math.pi / @as(T, hours);

        /// Where `hour` falls on the face. Hours past twelve wrap around, so
        /// 13 lands on 1.
        pub fn hourPosition(hour: usize) Point {
            const turns: T = @floatFromInt(hour % hours);
            return Tf.rotationY(turns * hour_angle).mulTuple(twelve);
        }

        /// All twelve marks, starting at twelve o'clock and going clockwise
        /// as seen from the front.
        pub fn positions() [hours]Point {
            var out: [hours]Point = undefined;
            for (&out, 0..) |*p, hour| p.* = hourPosition(hour);
            return out;
        }
    };
}

pub const Default = Clock(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;

test "twelve o'clock is on the positive z axis" {
    try testing.expect(Default.hourPosition(0).eql(V.point(0, 0, 1)));
}

test "three o'clock is a quarter turn away, on the positive x axis" {
    try testing.expect(Default.hourPosition(3).eql(V.point(1, 0, 0)));
    try testing.expect(Default.hourPosition(6).eql(V.point(0, 0, -1)));
    try testing.expect(Default.hourPosition(9).eql(V.point(-1, 0, 0)));
}

test "the hours wrap around the face" {
    try testing.expect(Default.hourPosition(13).eql(Default.hourPosition(1)));
}

test "every mark is a unit from the centre and level with the face" {
    for (Default.positions()) |p| {
        // Only x and z matter; a point carries w = 1, which magnitude counts.
        try testing.expect(tuple.feq(f64, p.x() * p.x() + p.z() * p.z(), 1));
        try testing.expect(tuple.feq(f64, p.y(), 0));
        try testing.expect(p.isPoint());
    }
}

test "the face can be laid out at comptime" {
    comptime {
        const marks = Default.positions();
        try testing.expect(marks[0].eql(V.point(0, 0, 1)));
        try testing.expect(marks[3].eql(V.point(1, 0, 0)));
    }
}

/// The face, drawn: the twelve marks placed on a canvas.
///
/// The face is looked at down the y axis, so the mark's x runs across the
/// canvas and its z runs up it, and the whole face is scaled to sit inside
/// whichever of the two canvas dimensions is smaller.
pub fn Face(comptime T: type) type {
    return struct {
        pub const C = color.Color(T);
        pub const Image = canvas.Canvas(C);
        pub const Marks = Clock(T);

        pub const name = "clock";
        pub const group = "canvas";

        pub const ink: C = .init(1, 0.9, 0.6);

        /// How much of the canvas the face spans, leaving a margin for the
        /// marks themselves, which are drawn as blocks around their point.
        const fill = 0.375;

        pub fn draw(image: Image) void {
            const across: T = @floatFromInt(image.width);
            const down: T = @floatFromInt(image.height);
            const radius = fill * @min(across, down);
            const side = @max(1, @min(image.width, image.height) / 60);

            for (Marks.positions()) |mark| {
                // The canvas counts y downwards, so the top of the face —
                // twelve o'clock, at positive z — is the smaller row number.
                const x: isize = @intFromFloat(across / 2 + mark.x() * radius);
                const y: isize = @intFromFloat(down / 2 - mark.z() * radius);
                image.plotSquare(x, y, side, ink);
            }
        }
    };
}

pub const DefaultFace = Face(f64);

test "the twelve marks land on a circle around the middle of the canvas" {
    var image = try DefaultFace.Image.init(testing.allocator, 100, 100);
    defer image.deinit(testing.allocator);
    DefaultFace.draw(image);

    var drawn: usize = 0;
    for (0..image.height) |y| for (0..image.width) |x| {
        if (image.pixelAt(x, y).eql(DefaultFace.C.black)) continue;
        drawn += 1;
        const dx: f64 = @as(f64, @floatFromInt(x)) - 50;
        const dy: f64 = @as(f64, @floatFromInt(y)) - 50;
        // Every lit pixel sits on the rim, a block's width either side of it.
        try testing.expectApproxEqAbs(37.5, @sqrt(dx * dx + dy * dy), 2);
    };
    try testing.expect(drawn >= Default.hours);
    // The middle of the face stays empty.
    try testing.expect(image.pixelAt(50, 50).eql(DefaultFace.C.black));
}

test "twelve o'clock is at the top and three o'clock to the right" {
    var image = try DefaultFace.Image.init(testing.allocator, 100, 100);
    defer image.deinit(testing.allocator);
    DefaultFace.draw(image);

    try testing.expect(!image.pixelAt(50, 12).eql(DefaultFace.C.black));
    try testing.expect(!image.pixelAt(87, 50).eql(DefaultFace.C.black));
}

//! The hour marks of an analog clock face, placed by rotation.
//!
//! The face lies in the xz plane, centred on the origin and one unit across,
//! viewed down the negative y axis: twelve o'clock sits at (0, 0, 1) and each
//! following hour is a twelfth of a turn about y away from it.

const std = @import("std");
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

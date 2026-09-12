//! Colors as (red, green, blue) triples.
//!
//! Components are nominally in 0..1, but nothing clamps them here: light
//! accumulated across reflections and transparency routinely overshoots 1 or
//! dips below 0 mid-computation, and rounding it off early would visibly
//! flatten the highlights and shadows. Clamping happens once, at the point
//! where the image is written out.

const std = @import("std");
const float = @import("../math/float.zig");

/// Component selector, mirroring `tuple.Axis`.
pub const Channel = enum(u2) { red, green, blue };

/// An RGB color backed by a SIMD vector, generic over the float type.
pub fn Color(comptime T: type) type {
    if (@typeInfo(T) != .float) {
        @compileError("Color requires a floating point type, got " ++ @typeName(T));
    }

    return struct {
        const Self = @This();

        /// Underlying SIMD representation. Padded to four lanes so it maps to
        /// the same register width as a tuple; the fourth lane is unused.
        pub const Repr = @Vector(4, T);
        pub const Scalar = T;
        pub const epsilon: T = float.epsilonOf(T);

        pub const black: Self = init(0, 0, 0);
        pub const white: Self = init(1, 1, 1);

        v: Repr,

        /// color(red, green, blue)
        pub inline fn init(r: T, g: T, b: T) Self {
            return .{ .v = .{ r, g, b, 0 } };
        }

        pub inline fn get(self: Self, comptime channel: Channel) T {
            return self.v[@intFromEnum(channel)];
        }

        pub inline fn red(self: Self) T {
            return self.get(.red);
        }

        pub inline fn green(self: Self) T {
            return self.get(.green);
        }

        pub inline fn blue(self: Self) T {
            return self.get(.blue);
        }

        /// Component-wise comparison, tolerating round-off error. The fourth
        /// lane is padding and carries no channel, so it is left out.
        pub fn eql(a: Self, b: Self) bool {
            const lanes = @Vector(3, i32){ 0, 1, 2 };
            const ra: @Vector(3, T) = @shuffle(T, a.v, a.v, lanes);
            const rb: @Vector(3, T) = @shuffle(T, b.v, b.v, lanes);
            return @reduce(.And, float.vectorEql(T, 3, ra, rb));
        }

        /// Combining two light sources adds their colors.
        pub inline fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v };
        }

        pub inline fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v };
        }

        /// Brighten or dim uniformly.
        pub inline fn mul(self: Self, scalar: T) Self {
            return .{ .v = self.v * @as(Repr, @splat(scalar)) };
        }

        pub inline fn div(self: Self, scalar: T) Self {
            return .{ .v = self.v / @as(Repr, @splat(scalar)) };
        }

        /// Blend two colors by multiplying corresponding components — the
        /// Hadamard product. This is what a surface looks like under a light
        /// of a given color: whatever the surface does not reflect and the
        /// light does not emit is missing from the result.
        pub inline fn hadamard(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v };
        }

        /// Scale one component to an integer in 0..max, clamping out-of-range
        /// values. Rounding (rather than truncating) keeps 0.5 at the midpoint
        /// of the output range instead of biasing every value downwards.
        pub fn scaleChannel(self: Self, comptime channel: Channel, max: u8) u8 {
            const scaled = @round(self.get(channel) * @as(T, @floatFromInt(max)));
            return @intFromFloat(std.math.clamp(scaled, 0, @as(T, @floatFromInt(max))));
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("color({d}, {d}, {d})", .{ self.red(), self.green(), self.blue() });
        }
    };
}

/// The precision the ray tracer uses everywhere.
pub const Col = Color(f64);

// --- Tests ------------------------------------------------------------------

test "color equality ignores SIMD padding" {
    inline for (precisions) |T| {
        const P = Color(T);
        var padded = P.white;
        padded.v[3] = std.math.nan(T);
        try testing.expect(padded.eql(P.white));
        padded.v[0] = 0;
        try testing.expect(!padded.eql(P.white));
        comptime {
            var c = P.white;
            c.v[3] = std.math.inf(T);
            try testing.expect(c.eql(P.white));
        }
    }
}

const testing = std.testing;
const C = Col;

/// Run the core scenarios at both precisions to keep the generic code honest.
const precisions = .{ f32, f64 };

test "colors are (red, green, blue) tuples" {
    const c = C.init(-0.5, 0.4, 1.7);
    try testing.expectEqual(@as(f64, -0.5), c.red());
    try testing.expectEqual(@as(f64, 0.4), c.green());
    try testing.expectEqual(@as(f64, 1.7), c.blue());
}

test "adding colors" {
    inline for (precisions) |T| {
        const P = Color(T);
        const c1 = P.init(0.9, 0.6, 0.75);
        const c2 = P.init(0.7, 0.1, 0.25);
        try testing.expect(c1.add(c2).eql(P.init(1.6, 0.7, 1.0)));
    }
}

test "subtracting colors" {
    inline for (precisions) |T| {
        const P = Color(T);
        const c1 = P.init(0.9, 0.6, 0.75);
        const c2 = P.init(0.7, 0.1, 0.25);
        try testing.expect(c1.sub(c2).eql(P.init(0.2, 0.5, 0.5)));
    }
}

test "multiplying a color by a scalar" {
    const c = C.init(0.2, 0.3, 0.4);
    try testing.expect(c.mul(2).eql(C.init(0.4, 0.6, 0.8)));
}

test "dividing a color by a scalar" {
    const c = C.init(0.4, 0.6, 0.8);
    try testing.expect(c.div(2).eql(C.init(0.2, 0.3, 0.4)));
}

test "multiplying colors blends them component-wise" {
    const c1 = C.init(1, 0.2, 0.4);
    const c2 = C.init(0.9, 1, 0.1);
    try testing.expect(c1.hadamard(c2).eql(C.init(0.9, 0.2, 0.04)));
}

test "black absorbs and white preserves under blending" {
    const c = C.init(0.3, 0.6, 0.9);
    try testing.expect(c.hadamard(C.black).eql(C.black));
    try testing.expect(c.hadamard(C.white).eql(c));
}

test "scaling a channel clamps to the output range" {
    try testing.expectEqual(@as(u8, 255), C.init(1.5, 0, 0).scaleChannel(.red, 255));
    try testing.expectEqual(@as(u8, 0), C.init(-0.5, 0, 0).scaleChannel(.red, 255));
    try testing.expectEqual(@as(u8, 128), C.init(0, 0.5, 0).scaleChannel(.green, 255));
    try testing.expectEqual(@as(u8, 255), C.init(0, 0, 1).scaleChannel(.blue, 255));
}

test "color arithmetic is available at comptime" {
    comptime {
        const lit = C.init(1, 0.2, 0.4).hadamard(C.init(0.9, 1, 0.1));
        try testing.expect(lit.eql(C.init(0.9, 0.2, 0.04)));
    }
}

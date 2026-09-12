//! A cheap, repeatable scatter.
//!
//! Sampling a light or a lens on a fixed grid leaves its own pattern in the
//! image — rings where the count of visible samples steps up, or a lattice
//! where the same offsets are taken everywhere. Moving each sample about
//! inside its own cell breaks that pattern up into a scatter the eye reads as
//! grain instead. What is wanted of the numbers is only that neighbours
//! disagree; nothing here is meant to stand up as a source of randomness.
//!
//! The scatter is a function of what is being sampled, never of when, so the
//! same scene always renders to the same image — including one rendered
//! across several threads, or at comptime.

const std = @import("std");

/// One round of splitmix64.
pub fn mix(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// A run of numbers, stirred from whatever is handed to `init`: floats by
/// their bits, integers by their value.
pub const Stream = struct {
    state: u64,

    pub fn init(args: anytype) Stream {
        var state: u64 = 0x9e3779b97f4a7c15;
        inline for (args) |arg| state = mix(state ^ bits(arg));
        return .{ .state = state };
    }

    pub fn next(self: *Stream) u64 {
        self.state = mix(self.state);
        return self.state;
    }

    /// The next number as a fraction of one, in [0, 1).
    pub fn unit(self: *Stream, comptime T: type) T {
        return @as(T, @floatFromInt(self.next() >> 40)) / @as(T, 1 << 24);
    }

    fn bits(arg: anytype) u64 {
        return switch (@typeInfo(@TypeOf(arg))) {
            // Narrowing to 32 bits first keeps points that differ only in the
            // last places of their coordinates from being told apart, which
            // is what stops the scatter from turning into noise of its own.
            .float, .comptime_float => @as(u32, @bitCast(@as(f32, @floatCast(arg)))),
            else => @intCast(arg),
        };
    }
};

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "a stream gives fractions of one" {
    var s = Stream.init(.{ 1.5, 2.5, @as(usize, 3) });
    for (0..64) |_| {
        const v = s.unit(f64);
        try testing.expect(v >= 0 and v < 1);
    }
}

test "the same arguments give the same run, and different ones do not" {
    var a = Stream.init(.{ 1.0, 2.0 });
    var b = Stream.init(.{ 1.0, 2.0 });
    var c = Stream.init(.{ 1.0, 2.5 });
    var differed = false;
    for (0..16) |_| {
        try testing.expectEqual(a.next(), b.next());
        if (c.next() != a.state) differed = true;
    }
    try testing.expect(differed);
}

test "neighbouring places disagree about where to sample" {
    // Points a step apart, as a row of pixels or a grid of samples would be.
    var seen: [32]f64 = undefined;
    for (&seen, 0..) |*v, i| {
        var s = Stream.init(.{ @as(f64, @floatFromInt(i)) * 0.01, 0.0, i });
        v.* = s.unit(f64);
    }
    for (seen, 0..) |v, i| {
        for (seen[i + 1 ..]) |other| try testing.expect(v != other);
    }
}

test "streams run at comptime" {
    comptime {
        var s = Stream.init(.{ 1.0, @as(usize, 2) });
        const v = s.unit(f64);
        try testing.expect(v >= 0 and v < 1);
    }
}

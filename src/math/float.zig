//! Deciding when two floats are close enough.
//!
//! A single absolute tolerance cannot do this job alone. The spacing between
//! neighbouring floats grows with magnitude, so a fixed epsilon is far wider
//! than the representable gaps near zero and narrower than a single gap once
//! the values get large — past 2^24 for `f32`, consecutive floats are more
//! than 1.0 apart and any sub-unit epsilon degenerates into exact equality.
//!
//! So the comparison is hybrid. Near zero, where relative distance explodes
//! and floats crowd together, an absolute tolerance answers. Everywhere else
//! the question is how many representable values separate the two operands —
//! their distance in ULPs, units in the last place — which scales with the
//! numbers themselves because the float layout already encodes that scaling:
//! reinterpreting the bits of a positive float as an integer yields a count,
//! and adjacent floats differ by one.
//!
//! This is deliberately not an equivalence relation. Two values can each be
//! near a third without being near each other, so nothing here may be used to
//! sort, hash, or key on.

const std = @import("std");

/// Absolute tolerance used for values near zero.
///
/// Wide compared to the hardware's own epsilon, because the tolerance has to
/// absorb the round-off of whole transform chains and inversions, not a
/// single operation.
pub fn epsilonOf(comptime T: type) T {
    return 1e-5;
}

/// How many representable values two operands may be apart and still count as
/// equal, once they are far enough from zero for ULPs to mean anything.
pub const max_ulps = 4;

/// The signed integer that shares a float's width. Reinterpreting a float's
/// bits as one of these turns the exponent and mantissa into a single ordered
/// count of representable values — but only within one sign, which is why
/// operands of opposite sign are never compared this way.
pub fn Bits(comptime T: type) type {
    return std.meta.Int(.signed, @bitSizeOf(T));
}

/// Compare two floats for equivalence, tolerating round-off error.
pub fn feq(comptime T: type, a: T, b: T) bool {
    return @reduce(.And, vectorEql(T, 1, .{a}, .{b}));
}

/// How many representable values lie between `a` and `b`, saturating at the
/// largest count when the two cannot be compared this way at all: opposite
/// signs, or a non-finite operand.
pub fn ulpsDistance(comptime T: type, a: T, b: T) Bits(T) {
    const I = Bits(T);
    if (a == b) return 0;
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return std.math.maxInt(I);

    const ia: I = @bitCast(a);
    const ib: I = @bitCast(b);
    // The bit pattern counts upward from zero within each sign, so it only
    // orders values that share one. Equal magnitudes of opposite sign are
    // adjacent in reality but sit at opposite ends of the integer range; `a
    // == b` above has already let the one case that matters, +0 and -0,
    // through.
    if ((ia < 0) != (ib < 0)) return std.math.maxInt(I);
    return @intCast(@abs(ia -% ib));
}

/// Lane-wise `feq` over a SIMD vector, so the vector types can compare a whole
/// tuple, color, or matrix row at once rather than a component at a time.
pub fn vectorEql(
    comptime T: type,
    comptime n: usize,
    a: @Vector(n, T),
    b: @Vector(n, T),
) @Vector(n, bool) {
    // Reinterpreting bits costs the comptime interpreter more than the plain
    // subtraction this replaced, and callers that compare in a comptime loop
    // run out of the default allowance well before they are done.
    @setEvalBranchQuota(100_000);

    const I = Bits(T);
    const IV = @Vector(n, I);

    const exact = a == b;
    const near_zero = @abs(a - b) <= @as(@Vector(n, T), @splat(epsilonOf(T)));

    const ia: IV = @bitCast(a);
    const ib: IV = @bitCast(b);
    const zero: IV = @splat(0);
    const same_sign = (ia < zero) == (ib < zero);
    const UV = @Vector(n, std.meta.Int(.unsigned, @bitSizeOf(T)));
    const within_ulps = @abs(ia -% ib) <= @as(UV, @splat(max_ulps));

    // A non-finite operand has a bit pattern like any other, so the ULP test
    // would happily call two distinct infinities — or two NaNs — neighbours.
    const finite = isFiniteVector(T, n, a) & isFiniteVector(T, n, b);

    return exact | near_zero | (finite & same_sign & within_ulps);
}

fn isFiniteVector(comptime T: type, comptime n: usize, v: @Vector(n, T)) @Vector(n, bool) {
    // Both infinities and every NaN have an all-ones exponent, which is the
    // largest bit pattern a float of that width can hold once the sign is
    // dropped. Testing for it in the integer domain keeps this usable at
    // comptime, where materializing an infinity costs branch quota.
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const magnitude: @Vector(n, U) = @bitCast(@abs(v));
    const largest_finite: @Vector(n, U) = @splat(@bitCast(std.math.floatMax(T)));
    return magnitude <= largest_finite;
}

const testing = std.testing;

test "values a few representable steps apart compare equal" {
    const a: f64 = 1000.0;
    const b = std.math.nextAfter(f64, std.math.nextAfter(f64, a, 2000), 2000);
    try testing.expect(a != b);
    try testing.expect(feq(f64, a, b));
    try testing.expectEqual(@as(i64, 2), ulpsDistance(f64, a, b));
}

test "large values an absolute epsilon could never separate still compare unequal" {
    // Past 2^24 a single f32 step exceeds 1.0, so `@abs(a - b) < 1e-5` here
    // answers the same as `a == b` and calls these two neighbours distinct.
    const a: f32 = 1 << 25;
    const b = std.math.nextAfter(f32, a, 1e30);
    try testing.expect(b - a > 1);
    try testing.expect(feq(f32, a, b));

    var far = a;
    for (0..max_ulps + 1) |_| far = std.math.nextAfter(f32, far, 1e30);
    try testing.expect(!feq(f32, a, far));
}

test "values straddling zero are compared absolutely, not in ULPs" {
    // Denormals put millions of representable values between these two, but
    // as quantities they are indistinguishable at this scale.
    try testing.expect(feq(f64, 1e-300, -1e-300));
    try testing.expect(feq(f64, 0.0, -0.0));
    try testing.expectEqual(@as(i64, 0), ulpsDistance(f64, 0.0, -0.0));
}

test "opposite signs at a real distance stay unequal" {
    try testing.expect(!feq(f64, 1.0, -1.0));
    try testing.expectEqual(std.math.maxInt(i64), ulpsDistance(f64, 1.0, -1.0));
}

test "non-finite values are never neighbours" {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    try testing.expect(feq(f64, inf, inf));
    try testing.expect(!feq(f64, inf, std.math.floatMax(f64)));
    try testing.expect(!feq(f64, nan, nan));
    try testing.expectEqual(std.math.maxInt(i64), ulpsDistance(f64, nan, nan));
}

test "round-off from a long chain of operations is tolerated" {
    var acc: f64 = 0;
    for (0..10) |_| acc += 0.1;
    try testing.expect(acc != 1.0);
    try testing.expect(feq(f64, acc, 1.0));
}

test "comparison works at comptime" {
    comptime {
        try testing.expect(feq(f64, 0.1 + 0.2, 0.3));
        try testing.expect(!feq(f64, 1.0, 2.0));
        try testing.expect(@reduce(.And, vectorEql(f32, 4, @splat(1.0), @splat(1.0))));
    }
}

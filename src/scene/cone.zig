//! The cone: two of them, really — one upright and one inverted, their tips
//! meeting at the origin and widening towards infinity in both directions.
//!
//! It is the same surface of revolution as the cylinder with one thing
//! changed, the radius it holds at a height y, so the whole of it lives in
//! `cylinder.Quadric` under the other profile. Truncating it to one side of
//! the origin is what leaves the single cone a scene usually wants.

const std = @import("std");
const cylinder = @import("cylinder.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// The double-napped cone about the y axis, over a float type.
pub fn Cone(comptime T: type) type {
    return cylinder.Quadric(T, .cone);
}

/// The cone at the precision the ray tracer uses.
pub const Cn = Cone(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;

test "a ray strikes the cone's wall" {
    const cases = [_]struct { origin: V, direction: V, t0: f64, t1: f64 }{
        .{ .origin = V.point(0, 0, -5), .direction = V.vector(0, 0, 1), .t0 = 5, .t1 = 5 },
        .{
            .origin = V.point(0, 0, -5),
            .direction = V.vector(1, 1, 1),
            .t0 = 8.66025,
            .t1 = 8.66025,
        },
        // Skewed enough to enter one nappe and leave through the other, far away.
        .{
            .origin = V.point(1, 1, -5),
            .direction = V.vector(-0.5, -1, 1),
            .t0 = 4.55006,
            .t1 = 49.44994,
        },
    };

    for (cases) |case| {
        const xs = Cn.localIntersect(.{}, R.init(case.origin, case.direction.normalize()));
        try testing.expectEqual(@as(usize, 2), xs.len);
        try testing.expectApproxEqAbs(case.t0, xs.items()[0], 1e-5);
        try testing.expectApproxEqAbs(case.t1, xs.items()[1], 1e-5);
    }
}

test "a ray parallel to one half of the cone still meets the other" {
    const r = R.init(V.point(0, 0, -1), V.vector(0, 1, 1).normalize());
    const xs = Cn.localIntersect(.{}, r);
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectApproxEqAbs(@as(f64, 0.35355), xs.items()[0], 1e-5);
}

test "a closed cone's caps widen with the height they cover" {
    const c: Cn = .{ .minimum = -0.5, .maximum = 0.5, .closed = true };
    const cases = [_]struct { origin: V, direction: V, count: usize }{
        .{ .origin = V.point(0, 0, -5), .direction = V.vector(0, 1, 0), .count = 0 },
        .{ .origin = V.point(0, 0, -0.25), .direction = V.vector(0, 1, 1), .count = 2 },
        // Straight up the axis from the apex: both walls and both caps.
        .{ .origin = V.point(0, 0, -0.25), .direction = V.vector(0, 1, 0), .count = 4 },
    };

    for (cases) |case| {
        const xs = c.localIntersect(R.init(case.origin, case.direction.normalize()));
        try testing.expectEqual(case.count, xs.len);
    }
}

test "the normal on the cone's wall follows its slope" {
    const half_root_two = @sqrt(2.0) / 2.0;
    try testing.expect(Cn.localNormalAt(.{}, V.point(0, 0, 0)).eql(V.vector(0, 0, 0)));
    try testing.expect(Cn.localNormalAt(.{}, V.point(1, 1, 1))
        .eql(V.vector(1, -@sqrt(2.0), 1)));
    try testing.expect(Cn.localNormalAt(.{}, V.point(-1, -1, 0)).eql(V.vector(-1, 1, 0)));
    // The slope is 45°, so a normalized wall normal splits evenly between
    // the radial direction and y — tilting back towards the apex, which for
    // a point on the lower nappe means upwards.
    const n = Cn.localNormalAt(.{}, V.point(0, -2, 2)).normalize();
    try testing.expect(n.eql(V.vector(0, half_root_two, half_root_two)));
}

test "cones are intersected at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const xs = Cn.localIntersect(.{}, R.init(V.point(0, 0, -5), V.vector(0, 0, 1)));
        try testing.expect(xs.len == 2 and xs.items()[0] == 5 and xs.items()[1] == 5);
        try testing.expect(Cn.localNormalAt(.{}, V.point(-1, -1, 0)).eql(V.vector(-1, 1, 0)));
    }
}

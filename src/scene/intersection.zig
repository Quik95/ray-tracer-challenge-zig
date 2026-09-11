//! Intersections: where a ray meets an object, and which of those the eye
//! actually sees.

const std = @import("std");

/// A single crossing of a ray and an object, over a float type and the type
/// of object that was hit.
pub fn Intersection(comptime T: type, comptime Object: type) type {
    return struct {
        const Self = @This();

        pub const Scalar = T;

        /// How far along the ray the crossing is.
        t: T,
        /// What was crossed. Objects are compared by identity, so this is a
        /// pointer into the scene rather than a copy.
        object: *const Object,

        pub inline fn init(t: T, object: *const Object) Self {
            return .{ .t = t, .object = object };
        }

        pub inline fn eql(a: Self, b: Self) bool {
            return a.t == b.t and a.object == b.object;
        }

        /// The intersection the eye sees: the nearest one that is not behind
        /// the ray's origin. Intersections behind it are kept by callers —
        /// they matter for shapes inside other shapes — but never counted as
        /// the hit.
        pub fn hit(xs: []const Self) ?Self {
            var closest: ?Self = null;
            for (xs) |x| {
                if (x.t < 0) continue;
                if (closest == null or x.t < closest.?.t) closest = x;
            }
            return closest;
        }

        /// Order intersections by increasing t, nearest first.
        pub fn sort(xs: []Self) void {
            std.mem.sort(Self, xs, {}, lessThan);
        }

        fn lessThan(_: void, a: Self, b: Self) bool {
            return a.t < b.t;
        }
    };
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const sphere = @import("sphere.zig");
const S = sphere.S;
const X = S.Hit;

test "an intersection encapsulates t and object" {
    const s = S.init();
    const i = X.init(3.5, &s);
    try testing.expectEqual(@as(f64, 3.5), i.t);
    try testing.expectEqual(&s, i.object);
}

test "aggregating intersections" {
    const s = S.init();
    const xs = [_]X{ X.init(1, &s), X.init(2, &s) };
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 1), xs[0].t);
    try testing.expectEqual(@as(f64, 2), xs[1].t);
}

test "the hit, when all intersections have positive t" {
    const s = S.init();
    const near = X.init(1, &s);
    const far = X.init(2, &s);
    const xs = [_]X{ far, near };
    try testing.expect(X.hit(&xs).?.eql(near));
}

test "the hit, when some intersections have negative t" {
    const s = S.init();
    const behind = X.init(-1, &s);
    const ahead = X.init(1, &s);
    const xs = [_]X{ ahead, behind };
    try testing.expect(X.hit(&xs).?.eql(ahead));
}

test "the hit, when all intersections have negative t" {
    const s = S.init();
    const xs = [_]X{ X.init(-2, &s), X.init(-1, &s) };
    try testing.expect(X.hit(&xs) == null);
}

test "the hit is always the lowest nonnegative intersection" {
    const s = S.init();
    const nearest = X.init(2, &s);
    const xs = [_]X{ X.init(5, &s), X.init(7, &s), X.init(-3, &s), nearest };
    try testing.expect(X.hit(&xs).?.eql(nearest));
}

test "sorting orders intersections nearest first" {
    const s = S.init();
    var xs = [_]X{ X.init(5, &s), X.init(-3, &s), X.init(2, &s) };
    X.sort(&xs);
    try testing.expectEqual(@as(f64, -3), xs[0].t);
    try testing.expectEqual(@as(f64, 2), xs[1].t);
    try testing.expectEqual(@as(f64, 5), xs[2].t);
}

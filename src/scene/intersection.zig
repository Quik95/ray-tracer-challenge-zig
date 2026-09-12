//! Intersections: where a ray meets an object, and which of those the eye
//! actually sees.

const std = @import("std");

/// The distances along a ray at which a bare geometry is met — at most
/// `capacity` of them, since every shape the tracer knows is met a bounded
/// number of times. Geometries report distances alone; the shape wearing the
/// geometry is what turns them into intersections.
pub fn Roots(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        ts: [capacity]T = @splat(0),
        len: usize = 0,

        /// No crossing at all: the ray misses.
        pub const none: Self = .{};

        /// The roots given, in the order given.
        pub fn of(ts: anytype) Self {
            var self: Self = .{};
            inline for (ts) |t| {
                self.ts[self.len] = t;
                self.len += 1;
            }
            return self;
        }

        /// Keep another root. A geometry only ever pushes as many as its own
        /// `max_hits`, which is what sizes the buffer.
        pub fn push(self: *Self, t: T) void {
            self.ts[self.len] = t;
            self.len += 1;
        }

        /// Put the roots in the order the ray meets them. There are only
        /// ever a handful, so insertion beats anything cleverer.
        pub fn sort(self: *Self) void {
            if (self.len < 2) return;
            for (1..self.len) |i| {
                const t = self.ts[i];
                var j = i;
                while (j > 0 and self.ts[j - 1] > t) : (j -= 1) self.ts[j] = self.ts[j - 1];
                self.ts[j] = t;
            }
        }

        pub fn items(self: *const Self) []const T {
            return self.ts[0..self.len];
        }
    };
}

/// A single crossing of a ray and an object, over a float type and the type
/// of object that was hit.
pub fn Intersection(comptime T: type, comptime Object: type) type {
    return struct {
        const Self = @This();

        pub const Scalar = T;
        pub const PrepareError = error{ TargetAbsent, ContainerOverflow, NoSurface };

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

        /// Everything the shader needs about one crossing, worked out once so
        /// that later passes over the same hit do not repeat it.
        pub const Computations = struct {
            t: T,
            object: *const Object,
            /// Where the crossing is, in world space.
            point: Object.Point,
            /// The same place, nudged clear of the surface along the normal.
            /// Rays cast from the surface start here, so that rounding in
            /// `point` cannot drop them below it and make the object block
            /// itself.
            over_point: Object.Point,
            /// The same place, nudged the other way, just under the surface.
            /// A ray carrying on through the object starts here, for the same
            /// reason in reverse.
            under_point: Object.Point,
            /// From the surface back towards the eye.
            eye: Object.Point,
            /// The surface normal there, always facing the eye.
            normal: Object.Point,
            /// Where the ray bounces off the surface.
            reflect: Object.Point,
            /// Whether the ray met the surface from within the object.
            inside: bool,
            /// Refractive index of the material the ray is leaving.
            n1: T,
            /// Refractive index of the material the ray is entering.
            n2: T,

            /// What fraction of the light is reflected here rather than
            /// carried through, by Schlick's approximation to the Fresnel
            /// equations: glancing angles mirror, head-on angles let light
            /// pass. The full equations model more than the tracer cares
            /// about, and cost more than it can afford per ray.
            pub fn reflectance(self: Computations) T {
                var cos = self.eye.dot(self.normal);

                // Light can only fail to cross the interface on its way into
                // the thinner medium, so only that direction is checked.
                if (self.n1 > self.n2) {
                    const n = self.n1 / self.n2;
                    const sin2_t = n * n * (1.0 - cos * cos);
                    // Past the critical angle nothing is transmitted: the
                    // surface is a perfect mirror.
                    if (sin2_t > 1.0) return 1.0;
                    cos = @sqrt(1.0 - sin2_t);
                }

                const r0 = std.math.pow(T, (self.n1 - self.n2) / (self.n1 + self.n2), 2);
                return r0 + (1 - r0) * std.math.pow(T, 1 - cos, 5);
            }
        };

        /// How deeply objects may be nested before the pair of refractive
        /// indices at a crossing returns an error. Scenes put a
        /// bubble inside a marble, not a hundred of them.
        const max_nesting = 16;

        /// Work out the shading vectors for this crossing of `r`, treating
        /// the object as an isolated boundary between its material and vacuum.
        pub fn prepare(self: Self, r: Object.Ray) ?Computations {
            return self.prepareSurface(r);
        }

        /// Work out the shading vectors for this crossing of `r`, or an error
        /// for a missing target, excessive nesting, or an absent surface.
        ///
        /// A hit from inside the object has its normal pointing away from the
        /// eye, which would shade the surface as though it faced away from
        /// every light. Flipping it there keeps the interior lit.
        ///
        /// `xs` is every crossing of the same ray, sorted, which is what says
        /// which materials lie on either side of this one: an object already
        /// entered and not yet left is an object the crossing is inside of.
        pub fn prepareAmong(self: Self, r: Object.Ray, xs: []const Self) PrepareError!Computations {
            const media = try self.refractiveIndices(xs);
            var comps = self.prepareSurface(r) orelse return error.NoSurface;
            comps.n1 = media[0];
            comps.n2 = media[1];
            return comps;
        }

        fn prepareSurface(self: Self, r: Object.Ray) ?Computations {
            const point = r.position(self.t);
            const eye = r.direction.neg();
            const normal = self.object.normalAt(point) orelse return null;

            const inside = normal.dot(eye) < 0;
            const facing = if (inside) normal.neg() else normal;
            const offset = facing.mul(Object.Point.epsilon);

            return .{
                .t = self.t,
                .object = self.object,
                .point = point,
                .over_point = point.add(offset),
                .under_point = point.sub(offset),
                .eye = eye,
                .normal = facing,
                .reflect = r.direction.reflect(facing),
                .inside = inside,
                .n1 = if (inside) self.object.material.refractive_index else 1,
                .n2 = if (inside) 1 else self.object.material.refractive_index,
            };
        }

        /// The refractive indices on either side of this crossing: what the
        /// ray is leaving, and what it is entering.
        ///
        /// Walking the sorted crossings up to this one and keeping the
        /// objects entered but not yet left gives the nesting: the innermost
        /// of them is the material the ray is travelling through. Empty
        /// means open air, which the tracer treats as a vacuum.
        fn refractiveIndices(self: Self, xs: []const Self) PrepareError![2]T {
            const vacuum: T = 1.0;

            var containers: [max_nesting]*const Object = undefined;
            var depth: usize = 0;

            for (xs) |x| {
                const is_hit = x.eql(self);
                const before: T = if (depth == 0) vacuum else containers[depth - 1].material.refractive_index;

                // Meeting an object already entered is leaving it again.
                const found: ?usize = for (containers[0..depth], 0..) |object, i| {
                    if (object == x.object) break i;
                } else null;
                if (found) |i| {
                    std.mem.copyForwards(*const Object, containers[i .. depth - 1], containers[i + 1 .. depth]);
                    depth -= 1;
                } else {
                    if (depth == max_nesting) return error.ContainerOverflow;
                    containers[depth] = x.object;
                    depth += 1;
                }

                if (is_hit) {
                    const after: T = if (depth == 0) vacuum else containers[depth - 1].material.refractive_index;
                    return .{ before, after };
                }
            }

            // The crossing is not among those given; nothing is known to
            // stand on either side of it.
            return error.TargetAbsent;
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
const shape = @import("shape.zig");
const Sh = shape.Sh;
const X = Sh.Hit;
const R = @import("ray.zig").R;
const Tf = @import("../math/transform.zig").Tf;
const V = @import("../math/tuple.zig").Tup;
const feq = @import("../math/tuple.zig").feq;

test "preparing an absent crossing reports an error" {
    const s = Sh.glassSphere();
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    try testing.expectError(error.TargetAbsent, X.init(4, &s).prepareAmong(r, &.{}));
}

test "preparing nested media rejects overflow but accepts exact capacity" {
    var objects: [17]Sh = @splat(Sh.glassSphere());
    var xs: [17]X = undefined;
    for (&objects, &xs, 0..) |*object, *x, i| x.* = X.init(@floatFromInt(i + 1), object);
    const r = R.init(V.point(0, 0, -20), V.vector(0, 0, 1));
    const comps = try xs[15].prepareAmong(r, xs[0..16]);
    try testing.expectEqual(@as(f64, 1.5), comps.n2);
    try testing.expectError(error.ContainerOverflow, xs[16].prepareAmong(r, &xs));
}

test "an isolated glass exit leaves glass for vacuum" {
    comptime {
        @setEvalBranchQuota(100_000);
        const s = Sh.glassSphere();
        const r = R.init(V.point(0, 0, 0), V.vector(0, 0, 1));
        const comps = X.init(1, &s).prepare(r).?;
        try testing.expectEqual(@as(f64, 1.5), comps.n1);
        try testing.expectEqual(@as(f64, 1), comps.n2);
    }
}

test "an intersection encapsulates t and object" {
    const s = Sh.sphere();
    const i = X.init(3.5, &s);
    try testing.expectEqual(@as(f64, 3.5), i.t);
    try testing.expectEqual(&s, i.object);
}

test "aggregating intersections" {
    const s = Sh.sphere();
    const xs = [_]X{ X.init(1, &s), X.init(2, &s) };
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 1), xs[0].t);
    try testing.expectEqual(@as(f64, 2), xs[1].t);
}

test "the hit, when all intersections have positive t" {
    const s = Sh.sphere();
    const near = X.init(1, &s);
    const far = X.init(2, &s);
    const xs = [_]X{ far, near };
    try testing.expect(X.hit(&xs).?.eql(near));
}

test "the hit, when some intersections have negative t" {
    const s = Sh.sphere();
    const behind = X.init(-1, &s);
    const ahead = X.init(1, &s);
    const xs = [_]X{ ahead, behind };
    try testing.expect(X.hit(&xs).?.eql(ahead));
}

test "the hit, when all intersections have negative t" {
    const s = Sh.sphere();
    const xs = [_]X{ X.init(-2, &s), X.init(-1, &s) };
    try testing.expect(X.hit(&xs) == null);
}

test "the hit is always the lowest nonnegative intersection" {
    const s = Sh.sphere();
    const nearest = X.init(2, &s);
    const xs = [_]X{ X.init(5, &s), X.init(7, &s), X.init(-3, &s), nearest };
    try testing.expect(X.hit(&xs).?.eql(nearest));
}

test "sorting orders intersections nearest first" {
    const s = Sh.sphere();
    var xs = [_]X{ X.init(5, &s), X.init(-3, &s), X.init(2, &s) };
    X.sort(&xs);
    try testing.expectEqual(@as(f64, -3), xs[0].t);
    try testing.expectEqual(@as(f64, 2), xs[1].t);
    try testing.expectEqual(@as(f64, 5), xs[2].t);
}

test "the hit lifts the point clear of the surface" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    const s: Sh = .{ .transform = Tf.translation(0, 0, 1) };
    const comps = X.init(5, &s).prepare(r).?;

    try testing.expect(comps.over_point.z() < -V.epsilon / 2);
    try testing.expect(comps.point.z() > comps.over_point.z());
}

test "the reflection vector bounces off the surface at the angle it arrived" {
    const s: Sh = .{ .geometry = .{ .plane = .{} } };
    const half_root_two = @sqrt(2.0) / 2.0;
    const r = R.init(V.point(0, 1, -1), V.vector(0, -half_root_two, half_root_two));
    const comps = X.init(@sqrt(2.0), &s).prepare(r).?;
    try testing.expect(comps.reflect.eql(V.vector(0, half_root_two, half_root_two)));
}

test "the hit pushes a second point just under the surface" {
    const r = R.init(V.point(0, 0, -5), V.vector(0, 0, 1));
    var s = Sh.glassSphere();
    s.setTransform(Tf.translation(0, 0, 1));
    const i = X.init(5, &s);
    const comps = try i.prepareAmong(r, &.{i});

    try testing.expect(comps.under_point.z() > V.epsilon / 2);
    try testing.expect(comps.point.z() < comps.under_point.z());
}

test "the materials on either side of nested crossings" {
    // Three glass spheres on a line: a big one holding two smaller ones that
    // overlap each other, and a ray threaded through all of them.
    var a = Sh.glassSphere();
    a.setTransform(Tf.scaling(2, 2, 2));
    var b = Sh.glassSphere();
    b.setTransform(Tf.translation(0, 0, -0.25));
    b.material.refractive_index = 2.0;
    var c = Sh.glassSphere();
    c.setTransform(Tf.translation(0, 0, 0.25));
    c.material.refractive_index = 2.5;

    const r = R.init(V.point(0, 0, -4), V.vector(0, 0, 1));
    const xs = [_]X{
        X.init(2, &a),    X.init(2.75, &b), X.init(3.25, &c),
        X.init(4.75, &b), X.init(5.25, &c), X.init(6, &a),
    };

    const expected = [_][2]f64{
        .{ 1.0, 1.5 }, .{ 1.5, 2.0 }, .{ 2.0, 2.5 },
        // Leaving b from inside c leaves c on both sides of the crossing.
        .{ 2.5, 2.5 }, .{ 2.5, 1.5 }, .{ 1.5, 1.0 },
    };
    for (xs, expected) |x, want| {
        const comps = try x.prepareAmong(r, &xs);
        try testing.expectEqual(want[0], comps.n1);
        try testing.expectEqual(want[1], comps.n2);
    }
}

test "reflectance is total under total internal reflection" {
    const s = Sh.glassSphere();
    const half_root_two = @sqrt(2.0) / 2.0;
    const r = R.init(V.point(0, 0, half_root_two), V.vector(0, 1, 0));
    const xs = [_]X{ X.init(-half_root_two, &s), X.init(half_root_two, &s) };
    const comps = try xs[1].prepareAmong(r, &xs);
    try testing.expectEqual(@as(f64, 1.0), comps.reflectance());
}

test "reflectance is slight where the ray meets the surface head on" {
    const s = Sh.glassSphere();
    const r = R.init(V.point(0, 0, 0), V.vector(0, 1, 0));
    const xs = [_]X{ X.init(-1, &s), X.init(1, &s) };
    const comps = try xs[1].prepareAmong(r, &xs);
    try testing.expect(feq(f64, 0.04, comps.reflectance()));
}

test "reflectance is significant where the ray grazes the surface" {
    const s = Sh.glassSphere();
    const r = R.init(V.point(0, 0.99, -2), V.vector(0, 0, 1));
    const xs = [_]X{X.init(1.8589, &s)};
    const comps = try xs[0].prepareAmong(r, &xs);
    try testing.expect(feq(f64, 0.48873, comps.reflectance()));
}

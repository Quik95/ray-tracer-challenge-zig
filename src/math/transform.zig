//! Matrix transformations: translation, scaling, rotation, and shearing.
//!
//! Every transformation is a 4x4 matrix, so any number of them concatenate
//! into a single matrix by multiplication. Because a tuple is multiplied on
//! the right, the matrix applied last stands leftmost in the product — the
//! reverse of the order the transformations happen in.

const std = @import("std");
const matrix = @import("matrix.zig");
const tuple = @import("tuple.zig");

const Axis = tuple.Axis;

/// The transformations, over a float type.
pub fn Transforms(comptime T: type) type {
    return struct {
        /// The matrices these functions build.
        pub const M = matrix.Matrix(T, 4);
        pub const Tuple4 = tuple.Tuple(T);
        pub const Scalar = T;

        /// Leaves everything where it is.
        pub const identity = M.identity;

        /// Radians from degrees, for callers who would rather think in
        /// degrees.
        pub inline fn radians(degrees: T) T {
            return degrees * std.math.pi / 180.0;
        }

        /// Moves points by (x, y, z). The offsets sit in the last column,
        /// where they are multiplied by the tuple's `w` — so points move and
        /// vectors, with `w = 0`, do not.
        pub fn translation(x: T, y: T, z: T) M {
            var m = identity;
            m.set(0, 3, x);
            m.set(1, 3, y);
            m.set(2, 3, z);
            return m;
        }

        /// Multiplies each component by its factor, growing or shrinking an
        /// object about the origin. A negative factor reflects across that
        /// axis.
        pub fn scaling(x: T, y: T, z: T) M {
            var m = identity;
            m.set(0, 0, x);
            m.set(1, 1, y);
            m.set(2, 2, z);
            return m;
        }

        /// Rotate `r` radians about one axis, left-handed: with the left
        /// thumb along the positive axis, the rotation follows the fingers.
        ///
        /// The axis is comptime-known, so the two components it mixes are
        /// resolved at compile time. Those two are the axis's successors in
        /// the cyclic order x → y → z → x, which is what makes one formula
        /// cover all three axes.
        pub fn rotation(comptime axis: Axis, r: T) M {
            const b, const c = comptime switch (axis) {
                .x => .{ 1, 2 },
                .y => .{ 2, 0 },
                .z => .{ 0, 1 },
                .w => @compileError("cannot rotate about w"),
            };
            const cos = @cos(r);
            const sin = @sin(r);
            var m = identity;
            m.set(b, b, cos);
            m.set(b, c, -sin);
            m.set(c, b, sin);
            m.set(c, c, cos);
            return m;
        }

        pub inline fn rotationX(r: T) M {
            return rotation(.x, r);
        }

        pub inline fn rotationY(r: T) M {
            return rotation(.y, r);
        }

        pub inline fn rotationZ(r: T) M {
            return rotation(.z, r);
        }

        /// Slants straight lines: each of x, y, and z moves in proportion to
        /// the two components it is not. `xy` is the amount of y added to x,
        /// and so on for the rest.
        pub fn shearing(xy: T, xz: T, yx: T, yz: T, zx: T, zy: T) M {
            var m = identity;
            m.set(0, 1, xy);
            m.set(0, 2, xz);
            m.set(1, 0, yx);
            m.set(1, 2, yz);
            m.set(2, 0, zx);
            m.set(2, 1, zy);
            return m;
        }

        /// Orients the world for an eye at `from` looking at `to`, with `up`
        /// pointing roughly upwards.
        ///
        /// It is easier to imagine this moving the eye, but it moves the
        /// world: the eye stays at the origin looking down -z, and everything
        /// else is carried into place around it. `up` only has to point
        /// vaguely upwards — it is squared up against the view direction
        /// here, so framing a scene takes no trigonometry.
        pub fn view(from: Tuple4, to: Tuple4, up: Tuple4) M {
            return viewChecked(from, to, up) catch @panic("view requires finite points and nonzero, nonparallel directions");
        }

        pub const ViewError = error{Degenerate};

        pub fn viewChecked(from: Tuple4, to: Tuple4, up: Tuple4) ViewError!M {
            if (from.w() != 1 or to.w() != 1 or up.w() != 0) return error.Degenerate;
            inline for (0..4) |i| {
                if (!std.math.isFinite(from.v[i]) or !std.math.isFinite(to.v[i])) return error.Degenerate;
            }
            const forward = try to.sub(from).normalizeChecked();
            const left = forward.cross(try up.normalizeChecked());
            _ = try left.normalizeChecked();
            const true_up = left.cross(forward);

            const orientation = M.init(.{
                .{ left.x(), left.y(), left.z(), 0 },
                .{ true_up.x(), true_up.y(), true_up.z(), 0 },
                .{ -forward.x(), -forward.y(), -forward.z(), 0 },
                .{ 0, 0, 0, 1 },
            });
            const result = orientation.mul(translation(-from.x(), -from.y(), -from.z()));
            for (result.toArray()) |row| {
                for (row) |value| if (!std.math.isFinite(value)) return error.Degenerate;
            }
            return result;
        }

        /// A transformation under construction. Each step multiplies its
        /// matrix onto the left of what came before, so the chain reads in
        /// the order the steps are applied rather than in reverse.
        pub const Chain = struct {
            m: M = identity,

            inline fn then(self: Chain, step: M) Chain {
                return .{ .m = step.mul(self.m) };
            }

            pub fn translate(self: Chain, x: T, y: T, z: T) Chain {
                return self.then(translation(x, y, z));
            }

            pub fn scale(self: Chain, x: T, y: T, z: T) Chain {
                return self.then(scaling(x, y, z));
            }

            pub fn rotate(self: Chain, comptime axis: Axis, r: T) Chain {
                return self.then(rotation(axis, r));
            }

            pub fn rotateX(self: Chain, r: T) Chain {
                return self.rotate(.x, r);
            }

            pub fn rotateY(self: Chain, r: T) Chain {
                return self.rotate(.y, r);
            }

            pub fn rotateZ(self: Chain, r: T) Chain {
                return self.rotate(.z, r);
            }

            pub fn shear(self: Chain, xy: T, xz: T, yx: T, yz: T, zx: T, zy: T) Chain {
                return self.then(shearing(xy, xz, yx, yz, zx, zy));
            }

            /// Transform a tuple by the chain built so far.
            pub fn apply(self: Chain, t: Tuple4) Tuple4 {
                return self.m.mulTuple(t);
            }
        };

        /// Start a chain of transformations from the identity.
        pub inline fn chain() Chain {
            return .{};
        }
    };
}

/// The transformations at the precision the ray tracer uses.
pub const Tf = Transforms(f64);

// --- Tests ------------------------------------------------------------------

test "checked view rejects degenerate frames" {
    inline for (.{ f32, f64 }) |T| {
        try checkView(T);
        comptime try checkView(T);
    }
}

fn checkView(comptime T: type) !void {
    @setEvalBranchQuota(10000);
    const F = Transforms(T);
    const P = F.Tuple4;
    const origin = P.point(0, 0, 0);
    const target = P.point(0, 0, -1);
    const up = P.vector(0, 1, 0);
    try testing.expect((try F.viewChecked(origin, target, up)).eql(F.identity));
    try testing.expectError(error.Degenerate, F.viewChecked(origin, origin, up));
    try testing.expectError(error.Degenerate, F.viewChecked(origin, target, P.zero));
    try testing.expectError(error.Degenerate, F.viewChecked(origin, target, P.vector(0, 0, 1)));
    try testing.expectError(error.Degenerate, F.viewChecked(origin, target, P.vector(0, 0, -1)));
    try testing.expectError(error.Degenerate, F.viewChecked(origin, target, P.vector(std.math.nan(T), 1, 0)));
    try testing.expectError(error.Degenerate, F.viewChecked(P.point(std.math.inf(T), 0, 0), target, up));
    try testing.expectError(error.Degenerate, F.viewChecked(P.zero, target, up));
}

const testing = std.testing;
const V = tuple.Tup;
const pi = std.math.pi;
const root2over2 = @sqrt(2.0) / 2.0;

test "multiplying by a translation matrix" {
    const transform = Tf.translation(5, -3, 2);
    const p = V.point(-3, 4, 5);
    try testing.expect(transform.mulTuple(p).eql(V.point(2, 1, 7)));
}

test "multiplying by the inverse of a translation matrix" {
    const transform = Tf.translation(5, -3, 2);
    const inv = try transform.inverse();
    const p = V.point(-3, 4, 5);
    try testing.expect(inv.mulTuple(p).eql(V.point(-8, 7, 3)));
}

test "translation does not affect vectors" {
    const transform = Tf.translation(5, -3, 2);
    const v = V.vector(-3, 4, 5);
    try testing.expect(transform.mulTuple(v).eql(v));
}

test "a scaling matrix applied to a point" {
    const transform = Tf.scaling(2, 3, 4);
    const p = V.point(-4, 6, 8);
    try testing.expect(transform.mulTuple(p).eql(V.point(-8, 18, 32)));
}

test "a scaling matrix applied to a vector" {
    const transform = Tf.scaling(2, 3, 4);
    const v = V.vector(-4, 6, 8);
    try testing.expect(transform.mulTuple(v).eql(V.vector(-8, 18, 32)));
}

test "multiplying by the inverse of a scaling matrix" {
    const transform = Tf.scaling(2, 3, 4);
    const inv = try transform.inverse();
    const v = V.vector(-4, 6, 8);
    try testing.expect(inv.mulTuple(v).eql(V.vector(-2, 2, 2)));
}

test "reflection is scaling by a negative value" {
    const transform = Tf.scaling(-1, 1, 1);
    const p = V.point(2, 3, 4);
    try testing.expect(transform.mulTuple(p).eql(V.point(-2, 3, 4)));
}

test "rotating a point around the x axis" {
    const p = V.point(0, 1, 0);
    const half_quarter = Tf.rotationX(pi / 4.0);
    const full_quarter = Tf.rotationX(pi / 2.0);
    try testing.expect(half_quarter.mulTuple(p).eql(V.point(0, root2over2, root2over2)));
    try testing.expect(full_quarter.mulTuple(p).eql(V.point(0, 0, 1)));
}

test "the inverse of an x-rotation rotates in the opposite direction" {
    const p = V.point(0, 1, 0);
    const inv = try Tf.rotationX(pi / 4.0).inverse();
    try testing.expect(inv.mulTuple(p).eql(V.point(0, root2over2, -root2over2)));
}

test "rotating a point around the y axis" {
    const p = V.point(0, 0, 1);
    const half_quarter = Tf.rotationY(pi / 4.0);
    const full_quarter = Tf.rotationY(pi / 2.0);
    try testing.expect(half_quarter.mulTuple(p).eql(V.point(root2over2, 0, root2over2)));
    try testing.expect(full_quarter.mulTuple(p).eql(V.point(1, 0, 0)));
}

test "rotating a point around the z axis" {
    const p = V.point(0, 1, 0);
    const half_quarter = Tf.rotationZ(pi / 4.0);
    const full_quarter = Tf.rotationZ(pi / 2.0);
    try testing.expect(half_quarter.mulTuple(p).eql(V.point(-root2over2, root2over2, 0)));
    try testing.expect(full_quarter.mulTuple(p).eql(V.point(-1, 0, 0)));
}

test "a full turn about any axis leaves a point where it started" {
    inline for (.{ Axis.x, Axis.y, Axis.z }) |axis| {
        const p = V.point(1, 2, 3);
        try testing.expect(Tf.rotation(axis, 2 * pi).mulTuple(p).eql(p));
    }
}

test "degrees convert to radians" {
    try testing.expect(tuple.feq(f64, Tf.radians(180), pi));
    try testing.expect(Tf.rotationZ(Tf.radians(90)).eql(Tf.rotationZ(pi / 2.0)));
}

test "a shearing transformation moves x in proportion to y" {
    const transform = Tf.shearing(1, 0, 0, 0, 0, 0);
    try testing.expect(transform.mulTuple(V.point(2, 3, 4)).eql(V.point(5, 3, 4)));
}

test "a shearing transformation moves x in proportion to z" {
    const transform = Tf.shearing(0, 1, 0, 0, 0, 0);
    try testing.expect(transform.mulTuple(V.point(2, 3, 4)).eql(V.point(6, 3, 4)));
}

test "a shearing transformation moves y in proportion to x" {
    const transform = Tf.shearing(0, 0, 1, 0, 0, 0);
    try testing.expect(transform.mulTuple(V.point(2, 3, 4)).eql(V.point(2, 5, 4)));
}

test "a shearing transformation moves y in proportion to z" {
    const transform = Tf.shearing(0, 0, 0, 1, 0, 0);
    try testing.expect(transform.mulTuple(V.point(2, 3, 4)).eql(V.point(2, 7, 4)));
}

test "a shearing transformation moves z in proportion to x" {
    const transform = Tf.shearing(0, 0, 0, 0, 1, 0);
    try testing.expect(transform.mulTuple(V.point(2, 3, 4)).eql(V.point(2, 3, 6)));
}

test "a shearing transformation moves z in proportion to y" {
    const transform = Tf.shearing(0, 0, 0, 0, 0, 1);
    try testing.expect(transform.mulTuple(V.point(2, 3, 4)).eql(V.point(2, 3, 7)));
}

test "individual transformations are applied in sequence" {
    const p = V.point(1, 0, 1);
    const a = Tf.rotationX(pi / 2.0);
    const b = Tf.scaling(5, 5, 5);
    const c = Tf.translation(10, 5, 7);

    const p2 = a.mulTuple(p);
    try testing.expect(p2.eql(V.point(1, -1, 0)));
    const p3 = b.mulTuple(p2);
    try testing.expect(p3.eql(V.point(5, -5, 0)));
    const p4 = c.mulTuple(p3);
    try testing.expect(p4.eql(V.point(15, 0, 7)));
}

test "chained transformations must be applied in reverse order" {
    const p = V.point(1, 0, 1);
    const a = Tf.rotationX(pi / 2.0);
    const b = Tf.scaling(5, 5, 5);
    const c = Tf.translation(10, 5, 7);
    const t = c.mul(b).mul(a);
    try testing.expect(t.mulTuple(p).eql(V.point(15, 0, 7)));
}

test "a chain applies its steps in the order they are written" {
    const p = V.point(1, 0, 1);
    const t = Tf.chain()
        .rotateX(pi / 2.0)
        .scale(5, 5, 5)
        .translate(10, 5, 7);
    try testing.expect(t.apply(p).eql(V.point(15, 0, 7)));
    try testing.expect(t.m.eql(
        Tf.translation(10, 5, 7).mul(Tf.scaling(5, 5, 5)).mul(Tf.rotationX(pi / 2.0)),
    ));
}

test "transformations are available at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const t = Tf.chain().scale(2, 2, 2).translate(1, 2, 3);
        try testing.expect(t.apply(V.point(1, 1, 1)).eql(V.point(3, 4, 5)));
        const back = try t.m.inverse();
        try testing.expect(back.mulTuple(V.point(3, 4, 5)).eql(V.point(1, 1, 1)));
    }
}

test "the transformations work at other precisions" {
    const T32 = Transforms(f32);
    const P = tuple.Tuple(f32);
    const t = T32.chain().rotateY(std.math.pi / 2.0).translate(0, 1, 0);
    try testing.expect(t.apply(P.point(0, 0, 1)).eql(P.point(1, 1, 0)));
}

test "the view transformation for the default orientation is the identity" {
    const t = Tf.view(V.point(0, 0, 0), V.point(0, 0, -1), V.vector(0, 1, 0));
    try testing.expect(t.eql(Tf.identity));
}

test "looking in the positive z direction mirrors the world" {
    const t = Tf.view(V.point(0, 0, 0), V.point(0, 0, 1), V.vector(0, 1, 0));
    try testing.expect(t.eql(Tf.scaling(-1, 1, -1)));
}

test "the view transformation moves the world, not the eye" {
    const t = Tf.view(V.point(0, 0, 8), V.point(0, 0, 0), V.vector(0, 1, 0));
    try testing.expect(t.eql(Tf.translation(0, 0, -8)));
}

test "an arbitrary view orients and moves the world at once" {
    const t = Tf.view(V.point(1, 3, 2), V.point(4, -2, 8), V.vector(1, 1, 0));
    try testing.expect(t.eql(Tf.M.init(.{
        .{ -0.50709, 0.50709, 0.67612, -2.36643 },
        .{ 0.76772, 0.60609, 0.12122, -2.82843 },
        .{ -0.35857, 0.59761, -0.71714, 0.00000 },
        .{ 0.00000, 0.00000, 0.00000, 1.00000 },
    })));
}

test "the view transformation is available at comptime" {
    comptime {
        const t = Tf.view(V.point(0, 0, 0), V.point(0, 0, -1), V.vector(0, 1, 0));
        try testing.expect(t.eql(Tf.identity));
    }
}

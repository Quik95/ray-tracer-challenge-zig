//! Two shapes combined by a set operation: what they cover together, what
//! they cover in common, or what the first covers and the second does not.
//!
//! A ray meets a CSG shape the way it meets a group — by meeting its children
//! — and the operation decides which of those crossings survive. Walking the
//! crossings in order says, at every step, whether the ray is inside the left
//! operand and whether it is inside the right; a crossing is kept only where
//! that pair of answers agrees with the operation. What is left describes the
//! combined surface, and nothing else had to be worked out geometrically.
//!
//! The children are a two-element slice the caller owns, left first, so a tree
//! is built as plain arrays like everything else here. Because a CSG shape is
//! itself a shape, an operand may be another CSG shape, which is what makes
//! strictly binary operations enough to carve anything.
//!
//! There is no normal to compute: a surviving crossing still names the
//! primitive it was found on, so the primitive shades it, keeping its own
//! material. That is what lets the inside of a carved hollow be a different
//! colour from the surface it was carved out of.

const std = @import("std");
const bounds_mod = @import("bounds.zig");
const shape_mod = @import("shape.zig");

/// Two shapes combined by a set operation, over a float type.
pub fn Csg(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Child = shape_mod.Shape(T);
        pub const Bounds = bounds_mod.Bounds(T);

        /// How the operands are combined.
        pub const Operation = enum {
            /// Everything either operand covers.
            @"union",
            /// Only what both operands cover.
            intersect,
            /// What the left operand covers and the right one does not.
            difference,
        };

        /// Like a group, a CSG shape has no surface of its own: it is met
        /// only through its operands.
        pub const max_hits = 0;

        operation: Operation = .@"union",
        /// The two operands, left first. A CSG shape with any other number of
        /// children is met by nothing, the way an empty group is.
        children: []Child = &.{},
        /// A box holding the combined shape, in this shape's own coordinates,
        /// worked out by `Shape.link` once the tree stands where it will stay.
        box: Bounds = .everything,

        pub fn init(operation: Operation, children: []Child) Self {
            return .{ .operation = operation, .children = children };
        }

        pub fn isEmpty(self: Self) bool {
            return self.children.len != 2;
        }

        pub fn left(self: Self) *Child {
            return &self.children[0];
        }

        pub fn right(self: Self) *Child {
            return &self.children[1];
        }

        /// The box holding the combined shape, in its own coordinates.
        pub fn bounds(self: Self) Bounds {
            return self.box;
        }

        /// The box to draw around the operands, given where they now stand.
        ///
        /// A union reaches as far as either operand; an intersection no
        /// further than where both reach; a difference no further than the
        /// left operand, since nothing outside it can survive. Each is an
        /// upper bound on the result, which is all a box has to be.
        pub fn boundsOf(self: Self) Bounds {
            if (self.isEmpty()) return .empty;
            const l = self.left().parentBounds();
            const r = self.right().parentBounds();
            return switch (self.operation) {
                .@"union" => l.merge(r),
                .intersect => l.overlap(r),
                .difference => l,
            };
        }

        /// Whether a crossing is part of the combined surface, given the
        /// operation, which operand was met, and which operands the ray was
        /// inside at the time.
        ///
        /// A union keeps what is met from outside the other operand, since
        /// anything met inside it is a surface buried in solid. An
        /// intersection keeps the opposite: only what is met while inside the
        /// other operand, which is where the two overlap. A difference keeps
        /// the left operand's surface where the right one is not covering it,
        /// and the right operand's surface where it is cutting into the left
        /// — that second kind is the wall of the hollow.
        pub fn allowed(
            operation: Operation,
            hit_left: bool,
            inside_left: bool,
            inside_right: bool,
        ) bool {
            return switch (operation) {
                .@"union" => if (hit_left) !inside_right else !inside_left,
                .intersect => if (hit_left) inside_right else inside_left,
                .difference => if (hit_left) !inside_right else inside_left,
            };
        }

        /// The crossings of `xs` that belong to the combined surface, kept in
        /// order at the front of `xs` and returned as that prefix.
        ///
        /// `xs` must be sorted by distance: the walk works out where the ray
        /// is by counting the surfaces it has passed through, which only says
        /// anything if they arrive in the order the ray meets them.
        pub fn filter(self: Self, xs: []Child.Hit) []Child.Hit {
            if (self.isEmpty()) return xs[0..0];

            // The ray starts outside both operands. Every crossing of one of
            // them puts it in or takes it out again.
            var inside_left = false;
            var inside_right = false;
            var kept: usize = 0;

            for (xs) |x| {
                const hit_left = self.left().includes(x.object);
                if (allowed(self.operation, hit_left, inside_left, inside_right)) {
                    // Never further along than where it was read from, so the
                    // survivors can be packed into the same buffer.
                    xs[kept] = x;
                    kept += 1;
                }
                if (hit_left) inside_left = !inside_left else inside_right = !inside_right;
            }
            return xs[0..kept];
        }
    };
}

/// The CSG shape at the precision the ray tracer uses.
pub const Cs = Csg(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const Sh = shape_mod.Sh;
const Tf = @import("../math/transform.zig").Tf;
const R = @import("ray.zig").R;
const V = @import("../math/tuple.zig").Tup;

test "a CSG shape is an operation over two shapes, which belong to it" {
    var pair = [_]Sh{ Sh.sphere(), Sh.cube() };
    var c = Sh.csg(.@"union", &pair);
    c.link();

    try testing.expectEqual(Cs.Operation.@"union", c.geometry.csg.operation);
    try testing.expectEqual(&pair[0], c.geometry.csg.left());
    try testing.expectEqual(&pair[1], c.geometry.csg.right());
    try testing.expectEqual(&c, pair[0].parent);
    try testing.expectEqual(&c, pair[1].parent);
}

test "the rule for a union keeps what is met outside the other shape" {
    const cases = [_][4]bool{
        // hit left, inside left, inside right, kept
        .{ true, true, true, false },
        .{ true, true, false, true },
        .{ true, false, true, false },
        .{ true, false, false, true },
        .{ false, true, true, false },
        .{ false, true, false, false },
        .{ false, false, true, true },
        .{ false, false, false, true },
    };
    for (cases) |case| {
        try testing.expectEqual(case[3], Cs.allowed(.@"union", case[0], case[1], case[2]));
    }
}

test "the rule for an intersection keeps what is met inside the other shape" {
    const cases = [_][4]bool{
        .{ true, true, true, true },
        .{ true, true, false, false },
        .{ true, false, true, true },
        .{ true, false, false, false },
        .{ false, true, true, true },
        .{ false, true, false, true },
        .{ false, false, true, false },
        .{ false, false, false, false },
    };
    for (cases) |case| {
        try testing.expectEqual(case[3], Cs.allowed(.intersect, case[0], case[1], case[2]));
    }
}

test "the rule for a difference keeps the left surface and the cut it leaves" {
    const cases = [_][4]bool{
        .{ true, true, true, false },
        .{ true, true, false, true },
        .{ true, false, true, false },
        .{ true, false, false, true },
        .{ false, true, true, true },
        .{ false, true, false, true },
        .{ false, false, true, false },
        .{ false, false, false, false },
    };
    for (cases) |case| {
        try testing.expectEqual(case[3], Cs.allowed(.difference, case[0], case[1], case[2]));
    }
}

test "filtering keeps the crossings the operation asks for" {
    const expected = [_][2]usize{
        .{ 0, 3 }, // union: the outermost pair
        .{ 1, 2 }, // intersection: the innermost pair
        .{ 0, 1 }, // difference: into the left, then out through the cut
    };
    for ([_]Cs.Operation{ .@"union", .intersect, .difference }, expected) |operation, want| {
        var pair = [_]Sh{ Sh.sphere(), Sh.cube() };
        var c = Sh.csg(operation, &pair);
        c.link();

        // Four crossings alternating between the operands, as a ray through
        // two overlapping shapes gives.
        var xs = [_]Sh.Hit{
            .init(1, &pair[0]),
            .init(2, &pair[1]),
            .init(3, &pair[0]),
            .init(4, &pair[1]),
        };
        const kept = c.geometry.csg.filter(&xs);
        try testing.expectEqual(@as(usize, 2), kept.len);
        // The survivors are packed to the front, so compare by distance.
        try testing.expectEqual(@as(f64, @floatFromInt(want[0] + 1)), kept[0].t);
        try testing.expectEqual(@as(f64, @floatFromInt(want[1] + 1)), kept[1].t);
    }
}

test "a crossing on a shape deep inside the left operand still counts as left" {
    var leaves = [_]Sh{Sh.sphere()};
    const branch = [_]Sh{Sh.group(&leaves)};
    var pair = [_]Sh{ branch[0], Sh.cube() };
    var c = Sh.csg(.@"union", &pair);
    c.link();

    const deep = &pair[0].geometry.group.children[0];
    try testing.expect(c.geometry.csg.left().includes(deep));
    try testing.expect(!c.geometry.csg.right().includes(deep));
}

test "a ray misses a CSG shape it passes by" {
    var pair = [_]Sh{ Sh.sphere(), Sh.cube() };
    var c = Sh.csg(.@"union", &pair);
    c.link();

    var buf: [8]Sh.Hit = undefined;
    const xs = try c.intersect(R.init(V.point(0, 2, -5), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "a ray through a union meets only its outer surface" {
    var pair = [_]Sh{ Sh.sphere(), Sh.sphere() };
    pair[1].setTransform(Tf.translation(0, 0, 0.5));
    var c = Sh.csg(.@"union", &pair);
    c.link();

    var buf: [8]Sh.Hit = undefined;
    const xs = try c.intersect(R.init(V.point(0, 0, -5), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 4), xs[0].t);
    try testing.expectEqual(&pair[0], xs[0].object);
    try testing.expectEqual(@as(f64, 6.5), xs[1].t);
    try testing.expectEqual(&pair[1], xs[1].object);
}

test "a difference is entered on the left and left through the cut" {
    var pair = [_]Sh{ Sh.sphere(), Sh.sphere() };
    pair[1].setTransform(Tf.translation(0, 0, 0.5));
    var c = Sh.csg(.difference, &pair);
    c.link();

    var buf: [8]Sh.Hit = undefined;
    const xs = try c.intersect(R.init(V.point(0, 0, -5), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    // In through the front of the left sphere, out through the front of the
    // one carving into it — the near wall of the hollow.
    try testing.expectEqual(@as(f64, 4), xs[0].t);
    try testing.expectEqual(&pair[0], xs[0].object);
    try testing.expectEqual(@as(f64, 4.5), xs[1].t);
    try testing.expectEqual(&pair[1], xs[1].object);
}

test "an intersection is only where both shapes are" {
    var pair = [_]Sh{ Sh.sphere(), Sh.sphere() };
    pair[1].setTransform(Tf.translation(0, 0, 0.5));
    var c = Sh.csg(.intersect, &pair);
    c.link();

    var buf: [8]Sh.Hit = undefined;
    const xs = try c.intersect(R.init(V.point(0, 0, -5), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectEqual(@as(f64, 4.5), xs[0].t);
    try testing.expectEqual(&pair[1], xs[0].object);
    try testing.expectEqual(@as(f64, 6), xs[1].t);
    try testing.expectEqual(&pair[0], xs[1].object);
}

test "the nearest crossing of a CSG shape is one the operation kept" {
    var pair = [_]Sh{ Sh.sphere(), Sh.sphere() };
    pair[1].setTransform(Tf.translation(0, 0, 0.5));
    var c = Sh.csg(.intersect, &pair);
    c.link();

    const h = c.nearestHit(R.init(V.point(0, 0, -5), V.vector(0, 0, 1))).?;
    try testing.expectEqual(@as(f64, 4.5), h.t);
    // The crossing names the sphere it was found on, not the CSG shape, so
    // the sphere's own material is what shades it.
    try testing.expectEqual(&pair[1], h.object);
}

test "a CSG shape is boxed by the operation, not merely by its operands" {
    var pair = [_]Sh{ Sh.sphere(), Sh.sphere() };
    pair[1].setTransform(Tf.translation(3, 0, 0));

    for ([_]Cs.Operation{ .@"union", .intersect, .difference }) |operation| {
        var c = Sh.csg(operation, &pair);
        c.link();
        const box = c.geometry.csg.bounds();
        switch (operation) {
            // Both spheres, end to end.
            .@"union" => try testing.expect(box.min.eql(V.point(-1, -1, -1)) and
                box.max.eql(V.point(4, 1, 1))),
            // They touch at a point and share nothing worth opening.
            .intersect => try testing.expect(!box.contains(V.point(-1, 0, 0))),
            // Never wider than the sphere being carved.
            .difference => try testing.expect(box.max.eql(V.point(1, 1, 1))),
        }
    }
}

test "a CSG shape whose box a ray misses is left unopened" {
    var pair = [_]Sh{ Sh.sphere(), Sh.cube() };
    var c = Sh.csg(.intersect, &pair);
    c.setTransform(Tf.translation(0, 0, 20));
    c.link();

    const aside = R.init(V.point(6, 0, -5), V.vector(0, 0, 1));
    try testing.expect(!c.geometry.csg.bounds().intersects(c.localRay(aside).?));
    try testing.expect(c.nearestHit(aside) == null);
}

test "a CSG shape with no surface of its own has no normal" {
    var pair = [_]Sh{ Sh.sphere(), Sh.cube() };
    var c = Sh.csg(.@"union", &pair);
    c.link();
    try testing.expect(c.normalAt(V.point(0, 1, 0)) == null);
}

test "shapes are carved at comptime" {
    comptime {
        @setEvalBranchQuota(100_000);
        var pair = [_]Sh{ Sh.sphere(), Sh.sphere() };
        pair[1].setTransform(Tf.translation(0, 0, 0.5));
        var c = Sh.csg(.difference, &pair);
        c.link();

        var buf: [8]Sh.Hit = undefined;
        const xs = try c.intersect(R.init(V.point(0, 0, -5), V.vector(0, 0, 1)), &buf);
        try testing.expect(xs.len == 2);
        try testing.expect(xs[1].t == 4.5);
    }
}

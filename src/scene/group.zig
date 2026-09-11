//! A group: a shape with no surface of its own, which takes its form from the
//! shapes it holds.
//!
//! A group's children are a slice the caller owns, so a tree is built as plain
//! arrays and handed over — nothing here allocates. Because the children are
//! reached through the group, whatever transformation the group carries
//! applies to all of them at once: a shape is modelled at the origin, dropped
//! into a group, and the group is what puts it somewhere.
//!
//! The children point back at the group they belong to, so that a normal found
//! on a child can be carried back out through every transformation between it
//! and the world. `Shape.link` is what ties the two directions together, and
//! must be called once the tree is standing where it will stay.

const std = @import("std");
const shape_mod = @import("shape.zig");

/// A group of shapes, over a float type.
pub fn Group(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Child = shape_mod.Shape(T);

        /// A group is met only through its children, never on its own, so it
        /// contributes no crossings of its own to the buffer they fill.
        pub const max_hits = 0;

        children: []Child = &.{},

        pub fn init(children: []Child) Self {
            return .{ .children = children };
        }

        pub fn isEmpty(self: Self) bool {
            return self.children.len == 0;
        }

        /// Whether `child` is one of this group's own children. Shapes are
        /// compared by identity, as everywhere else in the tracer.
        pub fn includes(self: Self, child: *const Child) bool {
            for (self.children) |*c| {
                if (c == child) return true;
            }
            return false;
        }
    };
}

/// The group at the precision the ray tracer uses.
pub const G = Group(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const Sh = shape_mod.Sh;
const Tf = @import("../math/transform.zig").Tf;
const R = @import("ray.zig").R;
const V = @import("../math/tuple.zig").Tup;

test "a new group is empty and stands where it is written" {
    var children: [0]Sh = .{};
    const g = Sh.group(&children);
    try testing.expect(g.transform.eql(Sh.M.identity));
    try testing.expect(g.geometry.group.isEmpty());
}

test "a linked child belongs to the group that holds it" {
    var children = [_]Sh{Sh.sphere()};
    var g = Sh.group(&children);
    g.link();

    try testing.expect(!g.geometry.group.isEmpty());
    try testing.expect(g.geometry.group.includes(&children[0]));
    try testing.expectEqual(&g, children[0].parent);
    try testing.expect(!g.geometry.group.includes(&g));
}

test "a shape has no parent until it is put in a group" {
    const s = Sh.sphere();
    try testing.expect(s.parent == null);
}

test "a ray misses an empty group" {
    var children: [0]Sh = .{};
    const g = Sh.group(&children);
    var buf: [4]Sh.Hit = undefined;
    const xs = try g.intersect(R.init(V.point(0, 0, 0), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "a ray meets the children of a group, nearest first" {
    var children = [_]Sh{
        Sh.sphere(),
        .{ .id = 1, .transform = Tf.translation(0, 0, -3) },
        .{ .id = 2, .transform = Tf.translation(5, 0, 0) },
    };
    var g = Sh.group(&children);
    g.link();

    var buf: [16]Sh.Hit = undefined;
    const xs = try g.intersect(R.init(V.point(0, 0, -5), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 4), xs.len);
    // The sphere in front is met first, twice, and then the one at the origin.
    try testing.expectEqual(&children[1], xs[0].object);
    try testing.expectEqual(&children[1], xs[1].object);
    try testing.expectEqual(&children[0], xs[2].object);
    try testing.expectEqual(&children[0], xs[3].object);
}

test "a group's transformation applies to its children" {
    var children = [_]Sh{.{ .transform = Tf.translation(5, 0, 0) }};
    var g = Sh.group(&children);
    g.setTransform(Tf.scaling(2, 2, 2));
    g.link();

    var buf: [8]Sh.Hit = undefined;
    const xs = try g.intersect(R.init(V.point(10, 0, -10), V.vector(0, 0, 1)), &buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
}

test "a group is met through its children at comptime" {
    comptime {
        @setEvalBranchQuota(40_000);
        var children = [_]Sh{Sh.sphere()};
        var g = Sh.group(&children);
        g.setTransform(Tf.translation(0, 0, 3));
        g.link();

        var buf: [8]Sh.Hit = undefined;
        const xs = try g.intersect(R.init(V.point(0, 0, -5), V.vector(0, 0, 1)), &buf);
        try testing.expect(xs.len == 2);
        try testing.expect(xs[0].t == 7);
    }
}

test "a group's own surface is nothing to shade" {
    var children = [_]Sh{Sh.sphere()};
    var g = Sh.group(&children);
    g.link();
    try testing.expect(g.normalAt(V.point(0, 1, 0)) == null);
}

//! The triangle: three corners, and the flat surface between them.
//!
//! Every other geometry here is written once in its own coordinates and put
//! somewhere by a transformation. A triangle is the exception: it carries its
//! three corners directly, because a mesh is thousands of triangles that share
//! nothing but a list of points, and standing each of them up from a canonical
//! triangle would cost a matrix apiece to say what three points already say.
//! A triangle can still be transformed like anything else.
//!
//! A triangle may also carry a normal at each corner. The surface is still
//! flat, but the normal reported anywhere on it is then blended from the
//! three, which lets a coarse mesh of flat facets shade as though it were
//! curved. Nothing else about the triangle changes, so the two kinds are one
//! type with the corner normals present or absent.

const std = @import("std");
const bounds_mod = @import("bounds.zig");
const intersection = @import("intersection.zig");
const ray = @import("ray.zig");
const tuple = @import("../math/tuple.zig");

/// A triangle given by its three corners, over a float type.
pub fn Triangle(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Point = tuple.Tuple(T);
        pub const Ray = ray.Ray(T);
        pub const Scalar = T;

        /// A flat surface is crossed once or not at all.
        pub const max_hits = 1;
        pub const Roots = intersection.Roots(T, max_hits);

        pub const Bounds = bounds_mod.Bounds(T);

        /// The corners, in the order that fixes which way the surface faces.
        p1: Point = Point.point(0, 1, 0),
        p2: Point = Point.point(-1, 0, 0),
        p3: Point = Point.point(1, 0, 0),
        /// The two edges leaving `p1`. The intersection test needs them for
        /// every ray, and the corners never move, so they are worked out once.
        e1: Point = Point.vector(-1, -1, 0),
        e2: Point = Point.vector(1, -1, 0),
        /// The surface normal, which is the same everywhere on a flat face.
        normal: Point = Point.vector(0, 0, -1),
        /// A normal at each corner, when the triangle is one facet of a
        /// surface meant to read as smooth. Absent, the face is as flat to
        /// the light as it is to the geometry.
        normals: ?[3]Point = null,

        pub fn init(p1: Point, p2: Point, p3: Point) Self {
            const e1 = p2.sub(p1);
            const e2 = p3.sub(p1);
            return .{
                .p1 = p1,
                .p2 = p2,
                .p3 = p3,
                .e1 = e1,
                .e2 = e2,
                // A triangle whose corners are collinear encloses nothing and
                // has no direction to face; it is left with a zero normal,
                // and the determinant below sends every ray past it.
                .normal = e2.cross(e1).normalizeChecked() catch Point.vector(0, 0, 0),
            };
        }

        /// The same triangle, shaded as though the surface curved through it:
        /// `n1`, `n2`, and `n3` are the normals at the matching corners, and
        /// the normal anywhere between them is blended from the three.
        pub fn smooth(
            p1: Point,
            p2: Point,
            p3: Point,
            n1: Point,
            n2: Point,
            n3: Point,
        ) Self {
            var self = init(p1, p2, p3);
            self.normals = .{ n1, n2, n3 };
            return self;
        }

        pub fn isSmooth(self: Self) bool {
            return self.normals != null;
        }

        /// The box around the three corners, which is as tight as an
        /// axis-aligned box around a triangle gets.
        pub fn bounds(self: Self) Bounds {
            return Bounds.empty.add(self.p1).add(self.p2).add(self.p3);
        }

        /// Where the ray crosses the triangle, by the Möller–Trumbore test.
        ///
        /// The ray direction crossed with one edge, dotted with the other,
        /// gives the volume of the box the three of them span. A volume of
        /// zero means the ray runs parallel to the surface and never meets
        /// it. Otherwise that volume normalizes two more triple products into
        /// `u` and `v`: how far across the two edges the crossing lies. Both
        /// are fractions of the way from `p1`, so a negative one, or a pair
        /// summing past one, puts the crossing outside an edge and the ray
        /// misses.
        pub fn localIntersect(self: Self, r: Ray) Roots {
            const uv = self.barycentricOf(r) orelse return .none;
            return .of(.{uv[2]});
        }

        /// Where on the surface the ray crosses, as the pair of fractions
        /// along `e1` and `e2`, together with the distance along the ray —
        /// or null where the ray misses. The pair is what a smooth triangle
        /// blends its corner normals by.
        fn barycentricOf(self: Self, r: Ray) ?[3]T {
            const dir_cross_e2 = r.direction.cross(self.e2);
            const det = self.e1.dot(dir_cross_e2);
            if (@abs(det) < tuple.epsilonOf(T)) return null;

            const f = 1.0 / det;
            const p1_to_origin = r.origin.sub(self.p1);
            const u = f * p1_to_origin.dot(dir_cross_e2);
            if (u < 0 or u > 1) return null;

            const origin_cross_e1 = p1_to_origin.cross(self.e1);
            const v = f * r.direction.dot(origin_cross_e1);
            if (v < 0 or u + v > 1) return null;

            return .{ u, v, f * self.e2.dot(origin_cross_e1) };
        }

        /// The unit vector perpendicular to the surface at a point on it.
        ///
        /// A flat triangle answers the same everywhere. A smooth one blends
        /// the corner normals by how far the point lies along each edge —
        /// which is the very pair the intersection test computed, recovered
        /// here from the point so that a normal can be asked for on its own
        /// rather than only alongside a crossing.
        pub fn localNormalAt(self: Self, point: Point) Point {
            const normals = self.normals orelse return self.normal;
            const uv = self.barycentricAt(point);
            const blended = normals[1].mul(uv[0])
                .add(normals[2].mul(uv[1]))
                .add(normals[0].mul(1 - uv[0] - uv[1]));
            return blended.normalizeChecked() catch self.normal;
        }

        /// How far `point` lies along each of the two edges leaving `p1`.
        ///
        /// The point is taken to be on the surface, so the pair is the least
        /// squares solution of `point - p1 = u*e1 + v*e2` — two equations in
        /// two unknowns, once both sides are dotted with each edge in turn.
        fn barycentricAt(self: Self, point: Point) [2]T {
            const d11 = self.e1.dot(self.e1);
            const d12 = self.e1.dot(self.e2);
            const d22 = self.e2.dot(self.e2);
            const from_p1 = point.sub(self.p1);
            const b1 = from_p1.dot(self.e1);
            const b2 = from_p1.dot(self.e2);

            // Zero only for a degenerate triangle, whose corner normals have
            // no surface to be spread over anyway.
            const det = d11 * d22 - d12 * d12;
            if (det == 0) return .{ 0, 0 };
            return .{
                (d22 * b1 - d12 * b2) / det,
                (d11 * b2 - d12 * b1) / det,
            };
        }
    };
}

/// The triangle at the precision the ray tracer uses.
pub const Tri = Triangle(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const V = tuple.Tup;
const R = ray.R;

/// The triangle every scenario below is written against.
const unit = Tri.init(V.point(0, 1, 0), V.point(-1, 0, 0), V.point(1, 0, 0));

test "a triangle keeps its corners, its edges, and the way it faces" {
    try testing.expect(unit.p1.eql(V.point(0, 1, 0)));
    try testing.expect(unit.p2.eql(V.point(-1, 0, 0)));
    try testing.expect(unit.p3.eql(V.point(1, 0, 0)));
    try testing.expect(unit.e1.eql(V.vector(-1, -1, 0)));
    try testing.expect(unit.e2.eql(V.vector(1, -1, 0)));
    try testing.expect(unit.normal.eql(V.vector(0, 0, -1)));
    try testing.expect(!unit.isSmooth());
}

test "the normal of a flat triangle is the same all over it" {
    try testing.expect(unit.localNormalAt(V.point(0, 0.5, 0)).eql(unit.normal));
    try testing.expect(unit.localNormalAt(V.point(-0.5, 0.75, 0)).eql(unit.normal));
    try testing.expect(unit.localNormalAt(V.point(0.5, 0.25, 0)).eql(unit.normal));
}

test "a triangle is boxed by its corners" {
    const box = unit.bounds();
    try testing.expect(box.min.eql(V.point(-1, 0, 0)));
    try testing.expect(box.max.eql(V.point(1, 1, 0)));
}

test "a ray parallel to the triangle misses it" {
    const xs = unit.localIntersect(R.init(V.point(0, -1, -2), V.vector(0, 1, 0)));
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "a ray passing beyond an edge misses the triangle" {
    // Past the p1-p3 edge, the p1-p2 edge, and the p2-p3 edge in turn.
    for ([_]V{ V.point(1, 1, -2), V.point(-1, 1, -2), V.point(0, -1, -2) }) |origin| {
        const xs = unit.localIntersect(R.init(origin, V.vector(0, 0, 1)));
        try testing.expectEqual(@as(usize, 0), xs.len);
    }
}

test "a ray strikes a triangle" {
    const xs = unit.localIntersect(R.init(V.point(0, 0.5, -2), V.vector(0, 0, 1)));
    try testing.expectEqualSlices(f64, &.{2}, xs.items());
}

test "a triangle whose corners are collinear is met by nothing" {
    const flat = Tri.init(V.point(0, 0, 0), V.point(1, 0, 0), V.point(2, 0, 0));
    try testing.expect(flat.normal.eql(V.vector(0, 0, 0)));
    const xs = flat.localIntersect(R.init(V.point(1, 1, 0), V.vector(0, -1, 0)));
    try testing.expectEqual(@as(usize, 0), xs.len);
}

/// The smooth triangle the scenarios below are written against: the same
/// corners, with a normal at each one leaning away from the middle.
const smooth = Tri.smooth(
    V.point(0, 1, 0),
    V.point(-1, 0, 0),
    V.point(1, 0, 0),
    V.vector(0, 1, 0),
    V.vector(-1, 0, 0),
    V.vector(1, 0, 0),
);

test "a smooth triangle keeps a normal at each of its corners" {
    try testing.expect(smooth.isSmooth());
    try testing.expect(smooth.p1.eql(V.point(0, 1, 0)));
    try testing.expect(smooth.normals.?[0].eql(V.vector(0, 1, 0)));
    try testing.expect(smooth.normals.?[1].eql(V.vector(-1, 0, 0)));
    try testing.expect(smooth.normals.?[2].eql(V.vector(1, 0, 0)));
}

test "a smooth triangle is met exactly where a flat one is" {
    const r = R.init(V.point(-0.2, 0.3, -2), V.vector(0, 0, 1));
    try testing.expectEqualSlices(f64, unit.localIntersect(r).items(), smooth.localIntersect(r).items());
}

test "a crossing lies a fraction of the way along each edge" {
    const uv = unit.barycentricOf(R.init(V.point(-0.2, 0.3, -2), V.vector(0, 0, 1))).?;
    try testing.expectApproxEqAbs(@as(f64, 0.45), uv[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), uv[1], 1e-9);

    // Which is the same pair the point itself gives back.
    const at = unit.barycentricAt(V.point(-0.2, 0.3, 0));
    try testing.expectApproxEqAbs(uv[0], at[0], 1e-9);
    try testing.expectApproxEqAbs(uv[1], at[1], 1e-9);
}

test "a smooth triangle blends its corner normals across the face" {
    const n = smooth.localNormalAt(V.point(-0.2, 0.3, 0));
    inline for (.{ -0.5547, 0.83205, 0.0 }, 0..) |expected, i| {
        try testing.expectApproxEqAbs(@as(f64, expected), n.v[i], 1e-5);
    }

    // At a corner the blend is that corner's own normal, and nothing else.
    try testing.expect(smooth.localNormalAt(V.point(0, 1, 0)).eql(V.vector(0, 1, 0)));
    try testing.expect(smooth.localNormalAt(V.point(-1, 0, 0)).eql(V.vector(-1, 0, 0)));
    try testing.expect(smooth.localNormalAt(V.point(1, 0, 0)).eql(V.vector(1, 0, 0)));
}

test "corner normals that cancel leave the face's own normal" {
    // Opposite normals at two corners sum to nothing halfway between them,
    // which has no direction to point in.
    const opposed = Tri.smooth(
        V.point(0, 1, 0),
        V.point(-1, 0, 0),
        V.point(1, 0, 0),
        V.vector(0, 0, -1),
        V.vector(1, 0, 0),
        V.vector(-1, 0, 0),
    );
    try testing.expect(opposed.localNormalAt(V.point(0, 0, 0)).eql(opposed.normal));
}

test "triangles are built, met, and shaded at comptime" {
    comptime {
        @setEvalBranchQuota(20_000);
        const t = Tri.init(V.point(0, 1, 0), V.point(-1, 0, 0), V.point(1, 0, 0));
        try testing.expect(t.localIntersect(R.init(V.point(0, 0.5, -2), V.vector(0, 0, 1))).items()[0] == 2);
        try testing.expect(t.localNormalAt(V.point(0, 0.5, 0)).eql(V.vector(0, 0, -1)));

        const s = Tri.smooth(
            V.point(0, 1, 0),
            V.point(-1, 0, 0),
            V.point(1, 0, 0),
            V.vector(0, 1, 0),
            V.vector(-1, 0, 0),
            V.vector(1, 0, 0),
        );
        try testing.expect(s.localNormalAt(V.point(0, 1, 0)).eql(V.vector(0, 1, 0)));
    }
}

//! Square matrices.
//!
//! A matrix is a grid of numbers manipulated as a single unit. The renderer
//! lives on 4x4 matrices — big enough to carry a translation alongside a
//! rotation, scale, and shear, which is exactly why tuples keep a `w` — but
//! the smaller sizes fall out of the same generic code and are needed anyway
//! to compute determinants recursively.

const std = @import("std");
const tuple = @import("tuple.zig");
const float = @import("float.zig");

const feq = float.feq;
const epsilonOf = float.epsilonOf;

/// An NxN matrix of `T`, stored row-major with each row a SIMD vector.
pub fn Matrix(comptime T: type, comptime n: usize) type {
    if (@typeInfo(T) != .float) {
        @compileError("Matrix requires a floating point type, got " ++ @typeName(T));
    }
    if (n == 0) @compileError("Matrix requires at least one row");

    return struct {
        const Self = @This();

        /// One row, held as a SIMD vector so a whole row multiplies at once.
        pub const Row = @Vector(n, T);
        pub const Scalar = T;
        pub const size = n;
        pub const epsilon: T = epsilonOf(T);

        /// The tuple type this matrix can transform, when it is 4x4.
        pub const Tuple4 = tuple.Tuple(T);

        rows: [n]Row,

        pub const zero: Self = .{ .rows = @splat(@splat(0)) };

        /// All zeros but for ones down the diagonal: multiplying by it is a
        /// no-op, which makes it the starting point for chained transforms.
        pub const identity: Self = blk: {
            var m = Self.zero;
            for (0..n) |i| m.rows[i][i] = 1;
            break :blk m;
        };

        /// Build a matrix from its rows, written out the way the book prints
        /// them.
        pub inline fn init(rows: [n][n]T) Self {
            var m: Self = undefined;
            for (rows, 0..) |row, i| m.rows[i] = row;
            return m;
        }

        /// The rows as plain arrays. Vectors cannot be indexed with a runtime
        /// index during comptime evaluation, so the algorithms that walk the
        /// grid element by element work on this instead.
        pub inline fn toArray(self: Self) [n][n]T {
            var out: [n][n]T = undefined;
            for (0..n) |i| out[i] = self.rows[i];
            return out;
        }

        /// M[row, col].
        pub inline fn at(self: Self, row: usize, col: usize) T {
            return self.rows[row][col];
        }

        pub inline fn set(self: *Self, row: usize, col: usize, value: T) void {
            self.rows[row][col] = value;
        }

        /// Element-wise comparison, tolerating round-off error. Matrices arrive
        /// out of inversions and long transform chains, so exact equality is
        /// useless.
        pub fn eql(a: Self, b: Self) bool {
            for (a.rows, b.rows) |ra, rb| {
                if (!@reduce(.And, float.vectorEql(T, n, ra, rb))) return false;
            }
            return true;
        }

        /// Matrix product: element (i, j) is the dot product of A's row i with
        /// B's column j. Taken a row at a time, that is B's rows scaled by
        /// A's row and summed, which keeps everything in whole-row SIMD ops.
        pub fn mul(a: Self, b: Self) Self {
            var out: Self = undefined;
            for (0..n) |i| {
                var acc: Row = @splat(0);
                inline for (0..n) |k| {
                    acc += @as(Row, @splat(a.rows[i][k])) * b.rows[k];
                }
                out.rows[i] = acc;
            }
            return out;
        }

        /// Matrix times tuple, treating the tuple as a one-column matrix.
        pub fn mulTuple(self: Self, t: Tuple4) Tuple4 {
            if (n != 4) @compileError("only a 4x4 matrix can transform a tuple");
            var out: Tuple4 = undefined;
            inline for (0..4) |i| {
                out.v[i] = @reduce(.Add, self.rows[i] * t.v);
            }
            return out;
        }

        /// Flip the matrix about its diagonal, turning rows into columns.
        pub fn transpose(self: Self) Self {
            const a = self.toArray();
            var out: [n][n]T = undefined;
            for (0..n) |i| {
                for (0..n) |j| out[i][j] = a[j][i];
            }
            return init(out);
        }

        /// The matrix with one row and one column removed. One size smaller,
        /// which is what makes the determinant recursion terminate.
        pub fn submatrix(self: Self, row: usize, col: usize) Matrix(T, n - 1) {
            if (n < 2) @compileError("a 1x1 matrix has no submatrix");
            const a = self.toArray();
            var out: [n - 1][n - 1]T = undefined;
            var oi: usize = 0;
            for (0..n) |i| {
                if (i == row) continue;
                var oj: usize = 0;
                for (0..n) |j| {
                    if (j == col) continue;
                    out[oi][oj] = a[i][j];
                    oj += 1;
                }
                oi += 1;
            }
            return Matrix(T, n - 1).init(out);
        }

        /// Determinant of the submatrix at (row, col).
        pub fn minor(self: Self, row: usize, col: usize) T {
            return self.submatrix(row, col).determinant();
        }

        /// The minor, negated when the row and column indices differ in
        /// parity — the checkerboard of signs that makes cofactor expansion
        /// work out.
        pub fn cofactor(self: Self, row: usize, col: usize) T {
            const m = self.minor(row, col);
            return if ((row + col) % 2 == 0) m else -m;
        }

        /// Scale factor the matrix applies to volume; zero means the matrix
        /// collapses space and cannot be undone.
        pub fn determinant(self: Self) T {
            if (n == 1) return self.rows[0][0];
            if (n == 2) {
                return self.rows[0][0] * self.rows[1][1] - self.rows[0][1] * self.rows[1][0];
            }
            // Expand along the first row: every element times its cofactor.
            var sum: T = 0;
            const first = self.toArray()[0];
            for (0..n) |col| sum += first[col] * self.cofactor(0, col);
            return sum;
        }

        pub fn isInvertible(self: Self) bool {
            _ = self.inverse() catch return false;
            return true;
        }

        pub const InverseError = error{Singular};

        /// The matrix that undoes this one. Each element of the cofactor
        /// matrix, transposed and divided by the determinant.
        pub fn inverse(self: Self) InverseError!Self {
            @setEvalBranchQuota(100000);
            for (self.toArray()) |row| {
                for (row) |value| if (!std.math.isFinite(value)) return error.Singular;
            }
            const det = self.determinant();
            if (det == 0 or !std.math.isFinite(det)) return error.Singular;
            var out: [n][n]T = undefined;
            for (0..n) |row| {
                for (0..n) |col| {
                    // Writing to [col][row] is the transpose, done in place.
                    out[col][row] = (if (n == 1) @as(T, 1) else self.cofactor(row, col)) / det;
                    if (!std.math.isFinite(out[col][row])) return error.Singular;
                }
            }
            return init(out);
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (self.rows) |row| {
                try writer.writeAll("|");
                for (0..n) |j| try writer.print(" {d} |", .{row[j]});
                try writer.writeAll("\n");
            }
        }
    };
}

/// The sizes the ray tracer works in, at its usual precision.
pub const Mat2 = Matrix(f64, 2);
pub const Mat3 = Matrix(f64, 3);
pub const Mat4 = Matrix(f64, 4);

// --- Tests ------------------------------------------------------------------

test "inverse accepts finite nonzero determinants independently of equality tolerance" {
    inline for (precisions) |T| {
        try checkInverseContract(T);
        comptime try checkInverseContract(T);
    }
}

fn checkInverseContract(comptime T: type) !void {
    @setEvalBranchQuota(100000);
    const M = Matrix(T, 4);
    const small = M.init(.{
        .{ 0.001, 0, 0, 0 },
        .{ 0, 0.001, 0, 0 },
        .{ 0, 0, 0.001, 0 },
        .{ 0, 0, 0, 1 },
    });
    try testing.expect(small.isInvertible());
    try testing.expect(small.mul(try small.inverse()).eql(M.identity));
    const One = Matrix(T, 1);
    try testing.expect((try One.init(.{.{0.000001}}).inverse()).mul(One.init(.{.{0.000001}})).eql(One.identity));
    try testing.expectError(error.Singular, One.zero.inverse());
    inline for (.{ std.math.inf(T), std.math.nan(T) }) |value| {
        const invalid = One.init(.{.{value}});
        try testing.expect(!invalid.isInvertible());
        try testing.expectError(error.Singular, invalid.inverse());
    }
    const overflow = Matrix(T, 2).init(.{ .{ std.math.floatMax(T), 0 }, .{ 0, 2 } });
    try testing.expectError(error.Singular, overflow.inverse());
    const tiny = std.math.floatMin(T) * std.math.floatEps(T);
    try testing.expectError(error.Singular, One.init(.{.{tiny}}).inverse());
}

const testing = std.testing;
const V = tuple.Tup;

/// The scenarios are stated for plain numbers, so run a few at both
/// precisions to keep the generic code honest.
const precisions = .{ f32, f64 };

test "constructing and inspecting a 4x4 matrix" {
    const m = Mat4.init(.{
        .{ 1, 2, 3, 4 },
        .{ 5.5, 6.5, 7.5, 8.5 },
        .{ 9, 10, 11, 12 },
        .{ 13.5, 14.5, 15.5, 16.5 },
    });
    try testing.expectEqual(@as(f64, 1), m.at(0, 0));
    try testing.expectEqual(@as(f64, 4), m.at(0, 3));
    try testing.expectEqual(@as(f64, 5.5), m.at(1, 0));
    try testing.expectEqual(@as(f64, 7.5), m.at(1, 2));
    try testing.expectEqual(@as(f64, 11), m.at(2, 2));
    try testing.expectEqual(@as(f64, 13.5), m.at(3, 0));
    try testing.expectEqual(@as(f64, 15.5), m.at(3, 2));
}

test "a 2x2 matrix ought to be representable" {
    const m = Mat2.init(.{
        .{ -3, 5 },
        .{ 1, -2 },
    });
    try testing.expectEqual(@as(f64, -3), m.at(0, 0));
    try testing.expectEqual(@as(f64, 5), m.at(0, 1));
    try testing.expectEqual(@as(f64, 1), m.at(1, 0));
    try testing.expectEqual(@as(f64, -2), m.at(1, 1));
}

test "a 3x3 matrix ought to be representable" {
    const m = Mat3.init(.{
        .{ -3, 5, 0 },
        .{ 1, -2, -7 },
        .{ 0, 1, 1 },
    });
    try testing.expectEqual(@as(f64, -3), m.at(0, 0));
    try testing.expectEqual(@as(f64, -2), m.at(1, 1));
    try testing.expectEqual(@as(f64, 1), m.at(2, 2));
}

test "matrix equality with identical matrices" {
    inline for (precisions) |T| {
        const M = Matrix(T, 4);
        const a = M.init(.{
            .{ 1, 2, 3, 4 },
            .{ 5, 6, 7, 8 },
            .{ 9, 8, 7, 6 },
            .{ 5, 4, 3, 2 },
        });
        try testing.expect(a.eql(a));
    }
}

test "matrix equality with different matrices" {
    const a = Mat4.init(.{
        .{ 1, 2, 3, 4 },
        .{ 5, 6, 7, 8 },
        .{ 9, 8, 7, 6 },
        .{ 5, 4, 3, 2 },
    });
    const b = Mat4.init(.{
        .{ 2, 3, 4, 5 },
        .{ 6, 7, 8, 9 },
        .{ 8, 7, 6, 5 },
        .{ 4, 3, 2, 1 },
    });
    try testing.expect(!a.eql(b));
}

test "multiplying two matrices" {
    const a = Mat4.init(.{
        .{ 1, 2, 3, 4 },
        .{ 5, 6, 7, 8 },
        .{ 9, 8, 7, 6 },
        .{ 5, 4, 3, 2 },
    });
    const b = Mat4.init(.{
        .{ -2, 1, 2, 3 },
        .{ 3, 2, 1, -1 },
        .{ 4, 3, 6, 5 },
        .{ 1, 2, 7, 8 },
    });
    const expected = Mat4.init(.{
        .{ 20, 22, 50, 48 },
        .{ 44, 54, 114, 108 },
        .{ 40, 58, 110, 102 },
        .{ 16, 26, 46, 42 },
    });
    try testing.expect(a.mul(b).eql(expected));
}

test "a matrix multiplied by a tuple" {
    const a = Mat4.init(.{
        .{ 1, 2, 3, 4 },
        .{ 2, 4, 4, 2 },
        .{ 8, 6, 4, 1 },
        .{ 0, 0, 0, 1 },
    });
    const b = V.init(1, 2, 3, 1);
    try testing.expect(a.mulTuple(b).eql(V.init(18, 24, 33, 1)));
}

test "multiplying a matrix by the identity matrix" {
    const a = Mat4.init(.{
        .{ 0, 1, 2, 4 },
        .{ 1, 2, 4, 8 },
        .{ 2, 4, 8, 16 },
        .{ 4, 8, 16, 32 },
    });
    try testing.expect(a.mul(Mat4.identity).eql(a));
    try testing.expect(Mat4.identity.mul(a).eql(a));
}

test "multiplying the identity matrix by a tuple" {
    const a = V.init(1, 2, 3, 4);
    try testing.expect(Mat4.identity.mulTuple(a).eql(a));
}

test "transposing a matrix" {
    const a = Mat4.init(.{
        .{ 0, 9, 3, 0 },
        .{ 9, 8, 0, 8 },
        .{ 1, 8, 5, 3 },
        .{ 0, 0, 5, 8 },
    });
    const expected = Mat4.init(.{
        .{ 0, 9, 1, 0 },
        .{ 9, 8, 8, 0 },
        .{ 3, 0, 5, 5 },
        .{ 0, 8, 3, 8 },
    });
    try testing.expect(a.transpose().eql(expected));
}

test "transposing the identity matrix" {
    try testing.expect(Mat4.identity.transpose().eql(Mat4.identity));
}

test "calculating the determinant of a 2x2 matrix" {
    const a = Mat2.init(.{
        .{ 1, 5 },
        .{ -3, 2 },
    });
    try testing.expectEqual(@as(f64, 17), a.determinant());
}

test "a submatrix of a 3x3 matrix is a 2x2 matrix" {
    const a = Mat3.init(.{
        .{ 1, 5, 0 },
        .{ -3, 2, 7 },
        .{ 0, 6, -3 },
    });
    const expected = Mat2.init(.{
        .{ -3, 2 },
        .{ 0, 6 },
    });
    try testing.expect(a.submatrix(0, 2).eql(expected));
}

test "a submatrix of a 4x4 matrix is a 3x3 matrix" {
    const a = Mat4.init(.{
        .{ -6, 1, 1, 6 },
        .{ -8, 5, 8, 6 },
        .{ -1, 0, 8, 2 },
        .{ -7, 1, -1, 1 },
    });
    const expected = Mat3.init(.{
        .{ -6, 1, 6 },
        .{ -8, 8, 6 },
        .{ -7, -1, 1 },
    });
    try testing.expect(a.submatrix(2, 1).eql(expected));
}

test "calculating a minor of a 3x3 matrix" {
    const a = Mat3.init(.{
        .{ 3, 5, 0 },
        .{ 2, -1, -7 },
        .{ 6, -1, 5 },
    });
    try testing.expectEqual(@as(f64, 25), a.submatrix(1, 0).determinant());
    try testing.expectEqual(@as(f64, 25), a.minor(1, 0));
}

test "calculating a cofactor of a 3x3 matrix" {
    const a = Mat3.init(.{
        .{ 3, 5, 0 },
        .{ 2, -1, -7 },
        .{ 6, -1, 5 },
    });
    try testing.expectEqual(@as(f64, -12), a.minor(0, 0));
    try testing.expectEqual(@as(f64, -12), a.cofactor(0, 0));
    try testing.expectEqual(@as(f64, 25), a.minor(1, 0));
    try testing.expectEqual(@as(f64, -25), a.cofactor(1, 0));
}

test "calculating the determinant of a 3x3 matrix" {
    const a = Mat3.init(.{
        .{ 1, 2, 6 },
        .{ -5, 8, -4 },
        .{ 2, 6, 4 },
    });
    try testing.expectEqual(@as(f64, 56), a.cofactor(0, 0));
    try testing.expectEqual(@as(f64, 12), a.cofactor(0, 1));
    try testing.expectEqual(@as(f64, -46), a.cofactor(0, 2));
    try testing.expectEqual(@as(f64, -196), a.determinant());
}

test "calculating the determinant of a 4x4 matrix" {
    const a = Mat4.init(.{
        .{ -2, -8, 3, 5 },
        .{ -3, 1, 7, 3 },
        .{ 1, 2, -9, 6 },
        .{ -6, 7, 7, -9 },
    });
    try testing.expectEqual(@as(f64, 690), a.cofactor(0, 0));
    try testing.expectEqual(@as(f64, 447), a.cofactor(0, 1));
    try testing.expectEqual(@as(f64, 210), a.cofactor(0, 2));
    try testing.expectEqual(@as(f64, 51), a.cofactor(0, 3));
    try testing.expectEqual(@as(f64, -4071), a.determinant());
}

test "testing an invertible matrix for invertibility" {
    const a = Mat4.init(.{
        .{ 6, 4, 4, 4 },
        .{ 5, 5, 7, 6 },
        .{ 4, -9, 3, -7 },
        .{ 9, 1, 7, -6 },
    });
    try testing.expectEqual(@as(f64, -2120), a.determinant());
    try testing.expect(a.isInvertible());
}

test "testing a noninvertible matrix for invertibility" {
    const a = Mat4.init(.{
        .{ -4, 2, -2, -3 },
        .{ 9, 6, 2, 6 },
        .{ 0, -5, 1, -5 },
        .{ 0, 0, 0, 0 },
    });
    try testing.expectEqual(@as(f64, 0), a.determinant());
    try testing.expect(!a.isInvertible());
    try testing.expectError(error.Singular, a.inverse());
}

test "calculating the inverse of a matrix" {
    const a = Mat4.init(.{
        .{ -5, 2, 6, -8 },
        .{ 1, -5, 1, 8 },
        .{ 7, 7, -6, -7 },
        .{ 1, -3, 7, 4 },
    });
    const b = try a.inverse();
    try testing.expectEqual(@as(f64, 532), a.determinant());
    try testing.expectEqual(@as(f64, -160), a.cofactor(2, 3));
    try testing.expect(feq(f64, b.at(3, 2), -160.0 / 532.0));
    try testing.expectEqual(@as(f64, 105), a.cofactor(3, 2));
    try testing.expect(feq(f64, b.at(2, 3), 105.0 / 532.0));
    const expected = Mat4.init(.{
        .{ 0.21805, 0.45113, 0.24060, -0.04511 },
        .{ -0.80827, -1.45677, -0.44361, 0.52068 },
        .{ -0.07895, -0.22368, -0.05263, 0.19737 },
        .{ -0.52256, -0.81391, -0.30075, 0.30639 },
    });
    try testing.expect(b.eql(expected));
}

test "calculating the inverse of another matrix" {
    const a = Mat4.init(.{
        .{ 8, -5, 9, 2 },
        .{ 7, 5, 6, 1 },
        .{ -6, 0, 9, 6 },
        .{ -3, 0, -9, -4 },
    });
    const expected = Mat4.init(.{
        .{ -0.15385, -0.15385, -0.28205, -0.53846 },
        .{ -0.07692, 0.12308, 0.02564, 0.03077 },
        .{ 0.35897, 0.35897, 0.43590, 0.92308 },
        .{ -0.69231, -0.69231, -0.76923, -1.92308 },
    });
    try testing.expect((try a.inverse()).eql(expected));
}

test "calculating the inverse of a third matrix" {
    const a = Mat4.init(.{
        .{ 9, 3, 0, 9 },
        .{ -5, -2, -6, -3 },
        .{ -4, 9, 6, 4 },
        .{ -7, 6, 6, 2 },
    });
    const expected = Mat4.init(.{
        .{ -0.04074, -0.07778, 0.14444, -0.22222 },
        .{ -0.07778, 0.03333, 0.36667, -0.33333 },
        .{ -0.02901, -0.14630, -0.10926, 0.12963 },
        .{ 0.17778, 0.06667, -0.26667, 0.33333 },
    });
    try testing.expect((try a.inverse()).eql(expected));
}

test "multiplying a product by its inverse" {
    const a = Mat4.init(.{
        .{ 3, -9, 7, 3 },
        .{ 3, -8, 2, -9 },
        .{ -4, 4, 4, 1 },
        .{ -6, 5, -1, 1 },
    });
    const b = Mat4.init(.{
        .{ 8, 2, 2, 2 },
        .{ 3, -1, 7, 0 },
        .{ 7, 0, 5, 4 },
        .{ 6, -2, 0, 5 },
    });
    const c = a.mul(b);
    try testing.expect(c.mul(try b.inverse()).eql(a));
}

test "matrix arithmetic is available at comptime" {
    comptime {
        // A 4x4 inverse expands into 4x3x2 cofactors; the default quota is
        // nowhere near enough to fold that at compile time.
        @setEvalBranchQuota(20_000);
        const a = Mat4.init(.{
            .{ 3, -9, 7, 3 },
            .{ 3, -8, 2, -9 },
            .{ -4, 4, 4, 1 },
            .{ -6, 5, -1, 1 },
        });
        const inv = try a.inverse();
        try testing.expect(a.mul(inv).eql(Mat4.identity));
        try testing.expect(a.transpose().transpose().eql(a));
        try testing.expect(Mat4.identity.mulTuple(V.point(1, 2, 3)).eql(V.point(1, 2, 3)));
    }
}

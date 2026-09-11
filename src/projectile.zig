//! A virtual cannon, to exercise the tuple code.

const std = @import("std");
const tuple = @import("tuple.zig");

/// The simulation, generic over the tuple type it flies through.
pub fn Sim(comptime Tup: type) type {
    return struct {
        pub const Projectile = struct {
            /// A point.
            position: Tup,
            /// A vector: direction plus speed, per tick.
            velocity: Tup,
        };

        pub const Environment = struct {
            /// A vector, applied to the velocity each tick.
            gravity: Tup,
            /// Likewise a vector.
            wind: Tup,
        };

        /// Advance the projectile by one unit of time.
        pub fn tick(env: Environment, proj: Projectile) Projectile {
            return .{
                .position = proj.position.add(proj.velocity),
                .velocity = proj.velocity.add(env.gravity).add(env.wind),
            };
        }
    };
}

pub const Default = Sim(tuple.Tup);

const testing = std.testing;
const V = tuple.Tup;

test "tick moves the projectile by its velocity and the velocity by the forces" {
    const S = Default;
    const env: S.Environment = .{
        .gravity = V.vector(0, -0.1, 0),
        .wind = V.vector(-0.01, 0, 0),
    };
    const proj: S.Projectile = .{
        .position = V.point(0, 1, 0),
        .velocity = V.vector(1, 1, 0),
    };

    const next = S.tick(env, proj);
    try testing.expect(next.position.eql(V.point(1, 2, 0)));
    try testing.expect(next.velocity.eql(V.vector(0.99, 0.9, 0)));
    try testing.expect(next.position.isPoint());
    try testing.expect(next.velocity.isVector());
}

test "a launched projectile eventually falls back to the ground" {
    const S = Default;
    const env: S.Environment = .{
        .gravity = V.vector(0, -0.1, 0),
        .wind = V.vector(-0.01, 0, 0),
    };
    var proj: S.Projectile = .{
        .position = V.point(0, 1, 0),
        .velocity = V.vector(1, 1, 0).normalize(),
    };

    var ticks: usize = 0;
    while (proj.position.y() > 0) : (ticks += 1) {
        proj = S.tick(env, proj);
        try testing.expect(ticks < 1000); // must not fly forever
    }
    try testing.expect(ticks > 0);
}

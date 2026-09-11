//! A virtual cannon, to exercise the tuple code.

const std = @import("std");
const canvas = @import("../render/canvas.zig");
const color = @import("../render/color.zig");
const tuple = @import("../math/tuple.zig");

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

/// The flight, drawn: the cannon fired once and its path plotted tick by tick.
///
/// The simulation runs in world units that have nothing to do with pixels, so
/// the path is flown twice — once to find how far it reaches, and once to draw
/// it — which fits the same arc to whatever canvas it is given.
pub fn Flight(comptime T: type) type {
    return struct {
        pub const C = color.Color(T);
        pub const Image = canvas.Canvas(C);
        pub const Vec = tuple.Tuple(T);
        pub const S = Sim(Vec);

        pub const name = "projectile";
        pub const group = "canvas";

        pub const ink: C = .init(1, 0.55, 0.15);

        /// Straight up and forwards, at a speed that carries it well clear of
        /// the muzzle before gravity wins.
        pub fn start() S.Projectile {
            return .{
                .position = Vec.point(0, 1, 0),
                .velocity = Vec.vector(1, 1.8, 0).normalize().mul(11.25),
            };
        }

        pub fn environment() S.Environment {
            return .{ .gravity = Vec.vector(0, -0.1, 0), .wind = Vec.vector(-0.01, 0, 0) };
        }

        /// A shot that never comes down would draw forever; in this
        /// environment it lands long before this many ticks.
        const max_ticks = 10_000;

        /// The flight, until the projectile falls back to the ground. `each`
        /// is handed every position it passes through, in order.
        fn fly(context: anytype, comptime each: fn (@TypeOf(context), Vec) void) void {
            const env = environment();
            var shot = start();
            var ticks: usize = 0;
            while (shot.position.y() > 0 and ticks < max_ticks) : (ticks += 1) {
                each(context, shot.position);
                shot = S.tick(env, shot);
            }
        }

        /// How far the shot travels, in world units: the far corner of the
        /// smallest box the whole flight fits inside.
        pub fn extent() Vec {
            var bounds = Vec.vector(0, 0, 0);
            fly(&bounds, struct {
                fn widen(b: *Vec, p: Vec) void {
                    b.* = Vec.vector(@max(b.x(), p.x()), @max(b.y(), p.y()), 0);
                }
            }.widen);
            return bounds;
        }

        pub fn draw(image: Image) void {
            const reach = extent();
            const across: T = @floatFromInt(image.width);
            const down: T = @floatFromInt(image.height);
            // A margin of a twentieth keeps the arc off the edges, and the
            // smaller of the two scales keeps it in proportion.
            const scale = @min(0.9 * across / reach.x(), 0.9 * down / reach.y());
            const left = 0.05 * across;
            const bottom = 0.95 * down;
            const side = @max(1, image.width / 150);

            const Plotter = struct { image: Image, scale: T, left: T, bottom: T, side: usize };
            var plotter: Plotter = .{
                .image = image,
                .scale = scale,
                .left = left,
                .bottom = bottom,
                .side = side,
            };
            fly(&plotter, struct {
                fn mark(p: *Plotter, at: Vec) void {
                    // The canvas counts y downwards and the world counts it
                    // up, so height above the ground is distance up from the
                    // bottom edge.
                    const x: isize = @intFromFloat(p.left + at.x() * p.scale);
                    const y: isize = @intFromFloat(p.bottom - at.y() * p.scale);
                    p.image.plotSquare(x, y, p.side, ink);
                }
            }.mark);
        }
    };
}

pub const DefaultFlight = Flight(f64);

test "the flight reaches up and out before it lands" {
    const reach = DefaultFlight.extent();
    try testing.expect(reach.x() > 0 and reach.y() > 1);
}

test "the arc is drawn inside the canvas, and peaks between its ends" {
    var image = try DefaultFlight.Image.init(testing.allocator, 200, 100);
    defer image.deinit(testing.allocator);
    DefaultFlight.draw(image);

    var first: ?usize = null;
    var last: usize = 0;
    var peak_x: usize = 0;
    var peak_y: usize = image.height;
    for (0..image.height) |y| for (0..image.width) |x| {
        if (image.pixelAt(x, y).eql(DefaultFlight.C.black)) continue;
        if (first == null) first = x;
        first = @min(first.?, x);
        last = @max(last, x);
        if (y < peak_y) {
            peak_y = y;
            peak_x = x;
        }
    };

    // The shot starts at the left edge and lands near the right one.
    try testing.expect(first.? < image.width / 10);
    try testing.expect(last > image.width * 8 / 10);
    // It is highest somewhere between the two, not at either end.
    try testing.expect(peak_x > first.? and peak_x < last);
    try testing.expect(peak_y < image.height / 2);
}

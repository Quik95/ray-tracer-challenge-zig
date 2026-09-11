//! Fires a virtual projectile and reports where it lands.

const std = @import("std");
const Io = std.Io;

const rt = @import("ray_tracing_challange_zig");
const V = rt.Tup;
const Sim = rt.projectile.Default;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    // Projectile starts one unit above the origin, velocity normalized to
    // 1 unit/tick. Multiply the velocity to fire it farther.
    var proj: Sim.Projectile = .{
        .position = V.point(0, 1, 0),
        .velocity = V.vector(1, 1.8, 0).normalize().mul(11.25),
    };

    // Gravity -0.1 unit/tick, wind -0.01 unit/tick.
    const env: Sim.Environment = .{
        .gravity = V.vector(0, -0.1, 0),
        .wind = V.vector(-0.01, 0, 0),
    };

    try out.print("tick  {s:>10}  {s:>10}\n", .{ "x", "y" });

    var ticks: usize = 0;
    while (proj.position.y() > 0) {
        proj = Sim.tick(env, proj);
        ticks += 1;
        try out.print("{d:>4}  {d:>10.4}  {d:>10.4}\n", .{ ticks, proj.position.x(), proj.position.y() });
    }

    try out.print("\nhit the ground after {d} ticks at x = {d:.4}\n", .{ ticks, proj.position.x() });
    try out.flush();
}

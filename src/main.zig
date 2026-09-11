//! Fires a virtual projectile and plots its trajectory to a PPM image.
//!
//! With stdout redirected the image goes there, so the run can be piped into
//! an image viewer or a file. On a terminal, dumping the pixel data would be
//! useless, so it is written to a file under the system temporary directory
//! instead and the path is reported.

const std = @import("std");
const Io = std.Io;

const rt = @import("ray_tracing_challange_zig");
const V = rt.Tup;
const C = rt.Col;
const Sim = rt.projectile.Default;

const width = 900;
const height = 550;
const file_name = "projectile.ppm";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

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

    var image = try rt.Image.init(gpa, width, height);
    defer image.deinit(gpa);

    const trail = C.init(1, 0.6, 0.2);
    var ticks: usize = 0;
    while (proj.position.y() > 0) {
        plot(image, proj.position, trail);
        proj = Sim.tick(env, proj);
        ticks += 1;
    }

    const stdout: Io.File = .stdout();
    const piped = !try stdout.isTty(io);

    // Notes go wherever the image is not, so a redirected stdout stays a
    // valid PPM stream.
    var log_buffer: [1024]u8 = undefined;
    var log_writer: Io.File.Writer = .init(if (piped) .stderr() else stdout, io, &log_buffer);
    const log = &log_writer.interface;
    try log.print(
        "hit the ground after {d} ticks at x = {d:.4}\n",
        .{ ticks, proj.position.x() },
    );

    if (piped) {
        var image_buffer: [64 * 1024]u8 = undefined;
        var image_writer: Io.File.Writer = .init(stdout, io, &image_buffer);
        try image.writePpm(&image_writer.interface);
        try image_writer.interface.flush();
        try log.print("wrote the {d}x{d} image to stdout\n", .{ width, height });
    } else {
        const path = try tempPath(gpa, init.environ_map, file_name);
        defer gpa.free(path);
        try writeFile(io, path, image);
        try log.print("wrote {s} ({d}x{d})\n", .{ path, width, height });
    }

    try log.flush();
}

/// Plot a world-space position onto the image. Canvas y runs downwards from
/// the top, the opposite of world y, hence the subtraction; anything that
/// lands off the canvas is dropped.
fn plot(image: rt.Image, position: V, c: C) void {
    const x: isize = @intFromFloat(@round(position.x()));
    const y: isize = @as(isize, height) - @as(isize, @intFromFloat(@round(position.y())));
    _ = image.plot(x, y, c);
}

/// `name` inside the system temporary directory. Caller owns the result.
fn tempPath(
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    name: []const u8,
) std.mem.Allocator.Error![]u8 {
    const dir = environ.get("TMPDIR") orelse "/tmp";
    return std.fs.path.join(gpa, &.{ dir, name });
}

/// Write the image out, replacing any previous run's file. Written through a
/// temporary and renamed into place so an interrupted run cannot leave a
/// half-written image behind.
fn writeFile(io: Io, path: []const u8, image: rt.Image) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    try image.writePpm(&file_writer.interface);
    try file_writer.interface.flush();

    try atomic.replace(io);
}

//! Draws the twelve hour marks of a clock face to a PPM image.
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
const Face = rt.clock.Default;

const width = 400;
const height = 400;
const file_name = "clock.ppm";

/// How much of the canvas the face spans, as a fraction of its width.
const radius = 3.0 / 8.0 * @as(f64, width);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var image = try rt.Image.init(gpa, width, height);
    defer image.deinit(gpa);

    // The face is a unit circle at the origin; scale it up to the canvas and
    // slide the centre from the corner to the middle.
    const to_canvas = rt.Tf.chain()
        .scale(radius, 1, radius)
        .translate(width / 2, 0, height / 2);

    const mark = C.init(1, 0.85, 0.4);
    for (Face.positions()) |p| plot(image, to_canvas.apply(p), mark);

    const stdout: Io.File = .stdout();
    const piped = !try stdout.isTty(io);

    // Notes go wherever the image is not, so a redirected stdout stays a
    // valid PPM stream.
    var log_buffer: [1024]u8 = undefined;
    var log_writer: Io.File.Writer = .init(if (piped) .stderr() else stdout, io, &log_buffer);
    const log = &log_writer.interface;
    try log.print("placed {d} hour marks\n", .{Face.hours});

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

/// Plot a canvas-space position onto the image. The face lies in the xz
/// plane, so z is what runs down the image; anything that lands off the
/// canvas is dropped.
fn plot(image: rt.Image, position: V, c: C) void {
    const x: isize = @intFromFloat(@round(position.x()));
    const y: isize = @intFromFloat(@round(position.z()));
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

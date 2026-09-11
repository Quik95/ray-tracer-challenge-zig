//! Casts a ray at a sphere for every pixel and shades what it hits, turning
//! the sphere's silhouette into a lit, three-dimensional ball.
//!
//! The image size comes from the command line: `SIZE` for a square, or
//! `WIDTHxHEIGHT` (equivalently `WIDTH HEIGHT`) for anything else.
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

const file_name = "sphere.ppm";

/// The eye, the wall the sphere's shadow falls on, and how much of that wall
/// the image covers. The wall is far enough back and wide enough that a unit
/// sphere at the origin fits on it with room to spare.
const ray_origin = V.point(0, 0, -5);
const wall_z = 10.0;
const wall_size = 7.0;

/// A white light behind, above, and to the left of the eye, so the highlight
/// lands off-centre and the sphere reads as round.
const light = rt.Light.init(V.point(-10, 10, -10), C.init(1, 1, 1));

const Size = struct {
    width: usize,
    height: usize,

    const default: Size = .{ .width = 200, .height = 200 };

    /// How much of the wall one pixel spans, in world units.
    fn pixelSize(self: Size) struct { f64, f64 } {
        return .{
            wall_size / @as(f64, @floatFromInt(self.width)),
            wall_size / @as(f64, @floatFromInt(self.height)),
        };
    }
};

const usage =
    \\usage: silhouette [SIZE | WIDTH HEIGHT | WIDTHxHEIGHT]
    \\
    \\Renders the sphere at the given size in pixels (default 200x200).
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip(); // the program name

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    while (args.next()) |arg| try argv.append(gpa, arg);

    for (argv.items) |arg| {
        if (!std.mem.eql(u8, arg, "-h") and !std.mem.eql(u8, arg, "--help")) continue;
        var buffer: [1024]u8 = undefined;
        var help: Io.File.Writer = .init(.stdout(), io, &buffer);
        try help.interface.writeAll(usage);
        try help.interface.flush();
        return;
    }

    const size = parseSize(argv.items) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr: Io.File.Writer = .init(.stderr(), io, &buffer);
        try stderr.interface.print("clock: {s}\n{s}", .{
            switch (err) {
                error.NotANumber => "sizes must be whole numbers of pixels",
                error.ZeroSize => "both dimensions must be at least one pixel",
                error.TooManyArguments => "expected at most two size arguments",
            },
            usage,
        });
        stderr.interface.flush() catch {};
        // A bad command line is the user's mistake, not a crash: report it
        // plainly rather than unwinding with a stack trace.
        std.process.exit(2);
    };

    var image = try rt.Image.init(gpa, size.width, size.height);
    defer image.deinit(gpa);

    const shape: rt.S = .{ .material = .{ .color = C.init(1, 0.2, 1) } };
    const hits = cast(image, shape);

    const stdout: Io.File = .stdout();
    const piped = !try stdout.isTty(io);

    // Notes go wherever the image is not, so a redirected stdout stays a
    // valid PPM stream.
    var log_buffer: [1024]u8 = undefined;
    var log_writer: Io.File.Writer = .init(if (piped) .stderr() else stdout, io, &log_buffer);
    const log = &log_writer.interface;
    try log.print("{d} of {d} rays hit the sphere\n", .{ hits, size.width * size.height });

    if (piped) {
        var image_buffer: [64 * 1024]u8 = undefined;
        var image_writer: Io.File.Writer = .init(stdout, io, &image_buffer);
        try image.writePpm(&image_writer.interface);
        try image_writer.interface.flush();
        try log.print("wrote the {d}x{d} image to stdout\n", .{ size.width, size.height });
    } else {
        const path = try tempPath(gpa, init.environ_map, file_name);
        defer gpa.free(path);
        try writeFile(io, path, image);
        try log.print("wrote {s} ({d}x{d})\n", .{ path, size.width, size.height });
    }

    try log.flush();
}

const ParseError = error{ NotANumber, ZeroSize, TooManyArguments };

/// The image size named by the arguments: none for the default, one for a
/// square or a `WIDTHxHEIGHT` pair, two for a width and a height.
fn parseSize(argv: []const []const u8) ParseError!Size {
    const size: Size = switch (argv.len) {
        0 => Size.default,
        1 => if (std.mem.indexOfScalar(u8, argv[0], 'x')) |sep| .{
            .width = try parseDimension(argv[0][0..sep]),
            .height = try parseDimension(argv[0][sep + 1 ..]),
        } else square: {
            const side = try parseDimension(argv[0]);
            break :square .{ .width = side, .height = side };
        },
        2 => .{
            .width = try parseDimension(argv[0]),
            .height = try parseDimension(argv[1]),
        },
        else => return error.TooManyArguments,
    };
    if (size.width == 0 or size.height == 0) return error.ZeroSize;
    return size;
}

fn parseDimension(text: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, text, 10) catch error.NotANumber;
}

/// Cast one ray per pixel from the eye through that pixel's point on the
/// wall, shading the pixel wherever the ray reaches the sphere. Returns how
/// many rays hit.
///
/// World y grows upwards and canvas y downwards, so the rows are walked from
/// the top of the wall down.
fn cast(image: rt.Image, shape: rt.S) usize {
    const size: Size = .{ .width = image.width, .height = image.height };
    const pixel_x, const pixel_y = size.pixelSize();
    const half = wall_size / 2.0;

    var hits: usize = 0;
    for (0..image.height) |y| {
        const world_y = half - pixel_y * @as(f64, @floatFromInt(y));
        for (0..image.width) |x| {
            const world_x = -half + pixel_x * @as(f64, @floatFromInt(x));
            const target = V.point(world_x, world_y, wall_z);
            const r = rt.R.init(ray_origin, target.sub(ray_origin).normalize());

            const xs = shape.intersect(r) orelse continue;
            const hit = rt.S.Hit.hit(&xs) orelse continue;

            // Shade the surface where the ray first reaches it, looking back
            // along the ray towards the eye.
            const point = r.position(hit.t);
            const normal = hit.object.normalAt(point) orelse continue;
            const eye = r.direction.neg();
            image.writePixel(x, y, hit.object.material.lighting(light, point, eye, normal));
            hits += 1;
        }
    }
    return hits;
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

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "no arguments render the default size" {
    try testing.expectEqual(Size.default, try parseSize(&.{}));
}

test "a single number is a square" {
    try testing.expectEqual(Size{ .width = 200, .height = 200 }, try parseSize(&.{"200"}));
}

test "a width and a height, together or apart" {
    const expected = Size{ .width = 800, .height = 600 };
    try testing.expectEqual(expected, try parseSize(&.{"800x600"}));
    try testing.expectEqual(expected, try parseSize(&.{ "800", "600" }));
}

test "sizes must be whole positive numbers" {
    try testing.expectError(error.NotANumber, parseSize(&.{"wide"}));
    try testing.expectError(error.NotANumber, parseSize(&.{"1.5"}));
    try testing.expectError(error.NotANumber, parseSize(&.{"-4"}));
    try testing.expectError(error.NotANumber, parseSize(&.{"800x"}));
    try testing.expectError(error.ZeroSize, parseSize(&.{"0"}));
    try testing.expectError(error.ZeroSize, parseSize(&.{"800x0"}));
    try testing.expectError(error.TooManyArguments, parseSize(&.{ "1", "2", "3" }));
}

test "a pixel spans the wall divided by the pixel count" {
    const wide = Size{ .width = 700, .height = 350 };
    const px, const py = wide.pixelSize();
    try testing.expectEqual(@as(f64, 0.01), px);
    try testing.expectEqual(@as(f64, 0.02), py);
}

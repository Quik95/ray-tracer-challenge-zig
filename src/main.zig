//! Renders a colonnade of cylinders and cones, one ray per pixel.
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
const Scene = rt.cylinders.Default;

const file_name = Scene.name ++ ".ppm";

const Size = struct {
    width: usize,
    height: usize,

    const default: Size = .{ .width = 400, .height = 200 };
};

const usage = "usage: " ++ Scene.name ++ " [SIZE | WIDTH HEIGHT | WIDTHxHEIGHT]\n" ++
    "\n" ++
    "Renders the scene at the given size in pixels (default 400x200).\n";

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
        try stderr.interface.print(Scene.name ++ ": {s}\n{s}", .{
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

    const objects = Scene.objects();
    const world = Scene.world(&objects);
    const camera = Scene.camera(size.width, size.height);

    // The bar goes to the terminal, so it stays out of a redirected image and
    // disappears on its own when the output is not a terminal at all.
    const progress = std.Progress.start(io, .{ .root_name = "rendering" });
    defer progress.end();

    var image = try camera.renderParallel(gpa, io, world, progress, 0);
    defer image.deinit(gpa);

    const stdout: Io.File = .stdout();
    const piped = !try stdout.isTty(io);

    // Notes go wherever the image is not, so a redirected stdout stays a
    // valid PPM stream.
    var log_buffer: [1024]u8 = undefined;
    var log_writer: Io.File.Writer = .init(if (piped) .stderr() else stdout, io, &log_buffer);
    const log = &log_writer.interface;

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

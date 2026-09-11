//! Draws the twelve hour marks of a clock face to a PPM image.
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
const Face = rt.clock.Default;

const file_name = "clock.ppm";

const Size = struct {
    width: usize,
    height: usize,

    const default: Size = .{ .width = 400, .height = 400 };

    /// How far the face reaches from the centre, in pixels. Measured against
    /// the shorter side so the clock stays on the canvas when it is not
    /// square.
    fn radius(self: Size) f64 {
        return 3.0 / 8.0 * @as(f64, @floatFromInt(@min(self.width, self.height)));
    }
};

const usage =
    \\usage: clock [SIZE | WIDTH HEIGHT | WIDTHxHEIGHT]
    \\
    \\Renders the clock face at the given size in pixels (default 400x400).
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

    // The face is a unit circle at the origin; scale it up to the canvas and
    // slide the centre from the corner to the middle.
    const to_canvas = rt.Tf.chain()
        .scale(size.radius(), 1, size.radius())
        .translate(
        @as(f64, @floatFromInt(size.width)) / 2,
        0,
        @as(f64, @floatFromInt(size.height)) / 2,
    );

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

test "the face is measured against the shorter side" {
    const wide = Size{ .width = 800, .height = 400 };
    try testing.expectEqual(@as(f64, 150), wide.radius());
}

//! Draws the scenes of the gallery.
//!
//! With no arguments it draws the newest scene alone, at 400x200. A scene name
//! picks a different one, and `all` draws every scene there is, in the order
//! the ray tracer grows into them, so the run leaves behind the whole sequence
//! of images rather than only the latest.
//!
//! Those images go under a single directory, each in the subdirectory its
//! group of scenes shares. The exception is one scene with stdout redirected:
//! that goes straight down the pipe, so a single image can still be fed to an
//! image viewer without touching the disk.

const std = @import("std");
const Io = std.Io;

const rt = @import("ray_tracing_challange_zig");
const Gallery = rt.gallery.Default;

const Size = struct {
    width: usize,
    height: usize,

    const default: Size = .{ .width = 400, .height = 200 };
};

/// What one run draws: the scenes named, how large, and where they land.
const Job = struct {
    scenes: []const Gallery.Entry,
    size: Size,
    /// Null means the default directory, or stdout when that is a pipe.
    out_dir: ?[]const u8,
};

const usage = "usage: gallery [SCENE | all] [SIZE | WIDTH HEIGHT | WIDTHxHEIGHT] [-o DIR]\n" ++
    "\n" ++
    "Renders a scene at the given size in pixels (default 400x200).\n" ++
    "`all` renders every scene, each into its own file under DIR,\n" ++
    "grouped into subdirectories. DIR defaults to a folder of its own\n" ++
    "under the system temporary directory.\n" ++
    "\n" ++
    "Scenes:\n";

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
        for (Gallery.entries) |entry| try help.interface.print("  {s}\n", .{entry.name});
        try help.interface.flush();
        return;
    }

    var selected: [Gallery.count]Gallery.Entry = undefined;
    const job = parseJob(argv.items, &selected) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr: Io.File.Writer = .init(.stderr(), io, &buffer);
        stderr.interface.print("gallery: {s}\n{s}", .{ message(err), usage }) catch {};
        for (Gallery.entries) |entry| stderr.interface.print("  {s}\n", .{entry.name}) catch {};
        stderr.interface.flush() catch {};
        // A bad command line is the user's mistake, not a crash: report it
        // plainly rather than unwinding with a stack trace.
        std.process.exit(2);
    };

    // The bar goes to the terminal, so it stays out of a redirected image and
    // disappears on its own when the output is not a terminal at all.
    const progress = std.Progress.start(io, .{ .root_name = "rendering" });
    defer progress.end();

    const stdout: Io.File = .stdout();
    const to_stdout = job.scenes.len == 1 and job.out_dir == null and !try stdout.isTty(io);

    // Notes go wherever the images are not, so a redirected stdout stays a
    // valid PPM stream.
    var log_buffer: [1024]u8 = undefined;
    var log_writer: Io.File.Writer = .init(if (to_stdout) .stderr() else stdout, io, &log_buffer);
    const log = &log_writer.interface;

    // Everything a run draws goes under one roof, and each image into the
    // subdirectory its group of scenes shares, so a whole gallery arrives
    // sorted rather than as a heap of files.
    const root = if (to_stdout) null else job.out_dir orelse
        try defaultRoot(gpa, init.environ_map);
    defer if (job.out_dir == null) if (root) |path| gpa.free(path);

    for (job.scenes) |scene| {
        const node = progress.start(scene.name, 0);
        defer node.end();

        var image = try scene.render(gpa, io, job.size.width, job.size.height, node, 0);
        defer image.deinit(gpa);

        if (root) |out| {
            const group = try std.fs.path.join(gpa, &.{ out, scene.dir });
            defer gpa.free(group);
            const name = try std.fmt.allocPrint(gpa, "{s}.ppm", .{scene.name});
            defer gpa.free(name);
            const path = try std.fs.path.join(gpa, &.{ group, name });
            defer gpa.free(path);

            try Io.Dir.cwd().createDirPath(io, group);
            try writeFile(io, path, image);
            try log.print("wrote {s} ({d}x{d})\n", .{ path, job.size.width, job.size.height });
        } else {
            var image_buffer: [64 * 1024]u8 = undefined;
            var image_writer: Io.File.Writer = .init(stdout, io, &image_buffer);
            try image.writePpm(&image_writer.interface);
            try image_writer.interface.flush();
            try log.print("wrote the {d}x{d} {s} image to stdout\n", .{
                job.size.width,
                job.size.height,
                scene.name,
            });
        }
        try log.flush();
    }
}

const ParseError = error{
    NotANumber,
    ZeroSize,
    TooManyArguments,
    UnknownScene,
    MissingDirectory,
};

fn message(err: ParseError) []const u8 {
    return switch (err) {
        error.NotANumber => "sizes must be whole numbers of pixels",
        error.ZeroSize => "both dimensions must be at least one pixel",
        error.TooManyArguments => "expected at most two size arguments",
        error.UnknownScene => "no such scene",
        error.MissingDirectory => "-o wants a directory to write into",
    };
}

/// The job the arguments describe. `buffer` holds the selected scenes, which
/// the result borrows, so it must outlive the job.
fn parseJob(argv: []const []const u8, buffer: *[Gallery.count]Gallery.Entry) ParseError!Job {
    var scene_count: usize = 0;
    var out_dir: ?[]const u8 = null;
    var sizes: [2][]const u8 = undefined;
    var size_count: usize = 0;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i == argv.len) return error.MissingDirectory;
            out_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "all")) {
            @memcpy(buffer, &Gallery.entries);
            scene_count = Gallery.count;
        } else if (Gallery.find(arg)) |entry| {
            // Naming the same scene twice draws it once.
            for (buffer[0..scene_count]) |already| {
                if (std.mem.eql(u8, already.name, entry.name)) break;
            } else {
                buffer[scene_count] = entry;
                scene_count += 1;
            }
        } else if (looksLikeSize(arg)) {
            if (size_count == sizes.len) return error.TooManyArguments;
            sizes[size_count] = arg;
            size_count += 1;
        } else return error.UnknownScene;
    }

    if (scene_count == 0) {
        buffer[0] = Gallery.latest;
        scene_count = 1;
    }
    return .{
        .scenes = buffer[0..scene_count],
        .size = try parseSize(sizes[0..size_count]),
        .out_dir = out_dir,
    };
}

/// Whether the argument is meant as a size rather than a scene name, so that a
/// typo in one is not reported as a mistake in the other.
fn looksLikeSize(arg: []const u8) bool {
    return arg.len > 0 and std.ascii.isDigit(arg[0]);
}

const ParseSizeError = error{ NotANumber, ZeroSize, TooManyArguments };

/// The image size named by the arguments: none for the default, one for a
/// square or a `WIDTHxHEIGHT` pair, two for a width and a height.
fn parseSize(argv: []const []const u8) ParseSizeError!Size {
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

fn parseDimension(text: []const u8) ParseSizeError!usize {
    return std.fmt.parseInt(usize, text, 10) catch error.NotANumber;
}

/// The directory a run writes into when none was named: one folder of its
/// own beside whatever else the system keeps temporarily. Caller owns it.
fn defaultRoot(
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) std.mem.Allocator.Error![]u8 {
    const tmp = environ.get("TMPDIR") orelse "/tmp";
    return std.fs.path.join(gpa, &.{ tmp, "ray-tracer-gallery" });
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

test "no arguments draw the newest scene at the default size" {
    var buffer: [Gallery.count]Gallery.Entry = undefined;
    const parsed = try parseJob(&.{}, &buffer);
    try testing.expectEqual(@as(usize, 1), parsed.scenes.len);
    try testing.expectEqualStrings(Gallery.latest.name, parsed.scenes[0].name);
    try testing.expectEqual(Size.default, parsed.size);
    try testing.expect(parsed.out_dir == null);
}

test "a scene name picks that scene, in any position" {
    var buffer: [Gallery.count]Gallery.Entry = undefined;
    for ([_][]const []const u8{ &.{ "spheres", "80" }, &.{ "80", "spheres" } }) |argv| {
        const parsed = try parseJob(argv, &buffer);
        try testing.expectEqual(@as(usize, 1), parsed.scenes.len);
        try testing.expectEqualStrings("spheres", parsed.scenes[0].name);
        try testing.expectEqual(Size{ .width = 80, .height = 80 }, parsed.size);
    }
}

test "all draws every scene, and naming one twice draws it once" {
    var buffer: [Gallery.count]Gallery.Entry = undefined;
    try testing.expectEqual(Gallery.count, (try parseJob(&.{"all"}, &buffer)).scenes.len);

    const parsed = try parseJob(&.{ "cubes", "cubes" }, &buffer);
    try testing.expectEqual(@as(usize, 1), parsed.scenes.len);
}

test "-o names the directory the images land in" {
    var buffer: [Gallery.count]Gallery.Entry = undefined;
    const parsed = try parseJob(&.{ "all", "-o", "images", "320x240" }, &buffer);
    try testing.expectEqualStrings("images", parsed.out_dir.?);
    try testing.expectEqual(Size{ .width = 320, .height = 240 }, parsed.size);
    try testing.expectError(error.MissingDirectory, parseJob(&.{"-o"}, &buffer));
}

test "an unknown scene is a mistake, and so is a bad size" {
    var buffer: [Gallery.count]Gallery.Entry = undefined;
    try testing.expectError(error.UnknownScene, parseJob(&.{"teapot"}, &buffer));
    try testing.expectError(error.NotANumber, parseJob(&.{"1.5"}, &buffer));
    try testing.expectError(error.NotANumber, parseJob(&.{"800x"}, &buffer));
    try testing.expectError(error.ZeroSize, parseJob(&.{"0"}, &buffer));
    try testing.expectError(error.TooManyArguments, parseJob(&.{ "1", "2", "3" }, &buffer));
}

test "a width and a height, together or apart" {
    const expected = Size{ .width = 800, .height = 600 };
    try testing.expectEqual(expected, try parseSize(&.{"800x600"}));
    try testing.expectEqual(expected, try parseSize(&.{ "800", "600" }));
}

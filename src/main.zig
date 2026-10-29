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
//!
//! Images are written as PNG unless `-f avif` asks for AVIF. A render is
//! mostly smooth gradients and flat background, which compresses to a small
//! fraction of the pixels it covers, and a gallery of them is otherwise
//! hundreds of megabytes. AVIF is lossy and smaller again by several times.
//!
//! A scene need not be one of these at all: an argument naming a `.yml` file
//! is read as a scene description and drawn the same way, at the size it asks
//! for unless the command line asks for another.

const std = @import("std");
const Io = std.Io;

const rt = @import("ray_tracing_challange_zig");
const Gallery = rt.gallery.Default;
const Scenes = rt.Desc;

/// How large a scene file may be. Generous for a text file describing a
/// world, and small enough that a wrong path cannot swallow memory.
const scene_file_limit: Io.Limit = .limited(8 << 20);

const Size = struct {
    width: usize,
    height: usize,

    const default: Size = .{ .width = 400, .height = 200 };
};

/// One thing to draw: a scene the gallery carries, or a file describing one.
const Source = union(enum) {
    builtin: Gallery.Entry,
    file: []const u8,

    /// What the image is called, without the extension it is given later.
    fn name(self: Source) []const u8 {
        return switch (self) {
            .builtin => |entry| entry.name,
            .file => |path| std.fs.path.stem(path),
        };
    }

    /// The subdirectory the image belongs in, if it shares one with others.
    /// A scene of the gallery's own belongs with its group; a file belongs
    /// wherever the run was told to write.
    fn dir(self: Source) ?[]const u8 {
        return switch (self) {
            .builtin => |entry| entry.dir,
            .file => null,
        };
    }

    fn eql(a: Source, b: Source) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .builtin => |entry| std.mem.eql(u8, entry.name, b.builtin.name),
            .file => |path| std.mem.eql(u8, path, b.file),
        };
    }
};

/// What one run draws: the scenes named, how large, and where they land.
const Job = struct {
    sources: []const Source,
    /// Null draws each scene at the size it asks for of its own: the default
    /// for one of the gallery's, and whatever a scene file names for one of
    /// those.
    size: ?Size,
    /// Null means the default directory, or stdout when that is a pipe.
    out_dir: ?[]const u8,
    format: Format,
};

/// How the images are stored, named as on the command line and as the
/// extension each file is given.
const Format = enum {
    png,
    avif,

    fn parse(name: []const u8) ParseError!Format {
        const format = std.meta.stringToEnum(Format, name) orelse return error.UnknownFormat;
        if (format == .avif and !rt.avif.available) return error.AvifUnavailable;
        return format;
    }

    fn write(format: Format, gpa: std.mem.Allocator, io: Io, file: Io.File, image: rt.Image) !void {
        switch (format) {
            .png => try rt.png.writeFile(image, gpa, io, file),
            // `parse` never yields AVIF from a build without libavif, and
            // such a build has no encoder to call.
            .avif => if (comptime rt.avif.available)
                try rt.avif.writeFile(image, gpa, io, file, .{})
            else
                unreachable,
        }
    }
};

const usage = "usage: gallery [SCENE | FILE.yml | all] [SIZE | WIDTH HEIGHT | WIDTHxHEIGHT] [-o DIR] [-f png|avif]\n" ++
    "\n" ++
    "Renders a scene at the given size in pixels (default 400x200).\n" ++
    "`all` renders every scene, each into its own file under DIR,\n" ++
    "grouped into subdirectories. DIR defaults to a folder of its own\n" ++
    "under the system temporary directory.\n" ++
    "\n" ++
    "A `.yml` path is read as a scene description and drawn at the size\n" ++
    "written in it, unless a size is given here as well.\n" ++
    "\n" ++
    "-f picks the image format: PNG (the default) or AVIF.\n" ++
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

    // Room for every scene the gallery carries and every file the command
    // line names, which is at most one per argument.
    const selected = try gpa.alloc(Source, Gallery.count + argv.items.len);
    defer gpa.free(selected);

    const job = parseJob(argv.items, selected) catch |err| {
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
    const to_stdout = job.sources.len == 1 and job.out_dir == null and !try stdout.isTty(io);

    // Notes go wherever the images are not, so a redirected stdout stays a
    // valid image stream.
    var log_buffer: [1024]u8 = undefined;
    var log_writer: Io.File.Writer = .init(if (to_stdout) .stderr() else stdout, io, &log_buffer);
    const log = &log_writer.interface;

    // Everything a run draws goes under one roof, and each image into the
    // subdirectory its group of scenes shares, so a whole gallery arrives
    // sorted rather than as a heap of files.
    const root = if (to_stdout) null else job.out_dir orelse
        try defaultRoot(gpa, init.environ_map);
    defer if (job.out_dir == null) if (root) |path| gpa.free(path);

    for (job.sources) |scene| {
        const node = progress.start(scene.name(), 0);
        defer node.end();

        var image = switch (scene) {
            .builtin => |entry| blk: {
                const size = job.size orelse Size.default;
                break :blk try entry.render(gpa, io, size.width, size.height, node, 0);
            },
            .file => |path| try renderFile(gpa, io, path, job.size, node),
        };
        defer image.deinit(gpa);

        if (root) |out| {
            const group = if (scene.dir()) |sub|
                try std.fs.path.join(gpa, &.{ out, sub })
            else
                try gpa.dupe(u8, out);
            defer gpa.free(group);
            const name = try gpa.print("{s}.{s}", .{ scene.name(), @tagName(job.format) });
            defer gpa.free(name);
            const path = try std.fs.path.join(gpa, &.{ group, name });
            defer gpa.free(path);

            try Io.Dir.cwd().createDirPath(io, group);
            try writeFile(gpa, io, path, image, job.format);
            try log.print("wrote {s} ({d}x{d})\n", .{ path, image.width, image.height });
        } else {
            try job.format.write(gpa, io, stdout, image);
            try log.print("wrote the {d}x{d} {s} image to stdout\n", .{
                image.width,
                image.height,
                scene.name(),
            });
        }
        try log.flush();
    }
}

/// Read the scene `path` describes and draw it. A scene that cannot be read
/// is the file's mistake rather than the program's: it is reported where it
/// happened, naming what the reader stopped at, and the run ends there.
fn renderFile(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    size: ?Size,
    node: std.Progress.Node,
) !rt.Image {
    const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, scene_file_limit) catch |err| {
        complain(io, path, @errorName(err), "");
    };
    defer gpa.free(source);

    var diagnostic: Scenes.Diagnostic = .{};
    // A width and a height of zero leave the scene at the size it asks for.
    const width = if (size) |s| s.width else 0;
    const height = if (size) |s| s.height else 0;
    return Scenes.render(gpa, io, source, width, height, node, 0, &diagnostic) catch |err| {
        complain(io, path, @errorName(err), diagnostic.what);
    };
}

/// Report a scene file that could not be drawn, and stop. Nothing has been
/// written yet, so there is nothing to undo.
fn complain(io: Io, path: []const u8, what: []const u8, where: []const u8) noreturn {
    var buffer: [1024]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), io, &buffer);
    stderr.interface.print("gallery: {s}: {s}", .{ path, what }) catch {};
    if (where.len > 0) stderr.interface.print(" at '{s}'", .{where}) catch {};
    stderr.interface.writeAll("\n") catch {};
    stderr.interface.flush() catch {};
    std.process.exit(1);
}

const ParseError = error{
    NotANumber,
    ZeroSize,
    TooManyArguments,
    UnknownScene,
    MissingDirectory,
    MissingFormat,
    UnknownFormat,
    AvifUnavailable,
};

fn message(err: ParseError) []const u8 {
    return switch (err) {
        error.NotANumber => "sizes must be whole numbers of pixels",
        error.ZeroSize => "both dimensions must be at least one pixel",
        error.TooManyArguments => "expected at most two size arguments",
        error.UnknownScene => "no such scene",
        error.MissingDirectory => "-o wants a directory to write into",
        error.MissingFormat, error.UnknownFormat => "-f wants an image format: png or avif",
        error.AvifUnavailable => "this build has no AVIF support; rebuild without -Davif=false",
    };
}

/// The job the arguments describe. `buffer` holds the selected scenes, which
/// the result borrows, so it must outlive the job and have room for every
/// scene the gallery carries as well as every file named.
fn parseJob(argv: []const []const u8, buffer: []Source) ParseError!Job {
    var scene_count: usize = 0;
    var out_dir: ?[]const u8 = null;
    var format: Format = .png;
    var sizes: [2][]const u8 = undefined;
    var size_count: usize = 0;

    // Naming the same scene twice draws it once.
    const pick = struct {
        fn pick(into: []Source, count: *usize, source: Source) void {
            for (into[0..count.*]) |already| {
                if (already.eql(source)) return;
            }
            into[count.*] = source;
            count.* += 1;
        }
    }.pick;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i == argv.len) return error.MissingDirectory;
            out_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i == argv.len) return error.MissingFormat;
            format = try Format.parse(argv[i]);
        } else if (std.mem.eql(u8, arg, "all")) {
            for (Gallery.entries) |entry| pick(buffer, &scene_count, .{ .builtin = entry });
        } else if (Gallery.find(arg)) |entry| {
            pick(buffer, &scene_count, .{ .builtin = entry });
        } else if (looksLikeScene(arg)) {
            pick(buffer, &scene_count, .{ .file = arg });
        } else if (looksLikeSize(arg)) {
            if (size_count == sizes.len) return error.TooManyArguments;
            sizes[size_count] = arg;
            size_count += 1;
        } else return error.UnknownScene;
    }

    if (scene_count == 0) {
        buffer[0] = .{ .builtin = Gallery.latest };
        scene_count = 1;
    }
    return .{
        .sources = buffer[0..scene_count],
        .size = if (size_count == 0) null else try parseSize(sizes[0..size_count]),
        .out_dir = out_dir,
        .format = format,
    };
}

/// Whether the argument is meant as a size rather than a scene name, so that a
/// typo in one is not reported as a mistake in the other.
fn looksLikeSize(arg: []const u8) bool {
    return arg.len > 0 and std.ascii.isDigit(arg[0]);
}

/// Whether the argument names a scene file. Decided by the extension alone
/// rather than by looking on disk, so that a misspelled scene name is
/// reported as one instead of as a missing file.
fn looksLikeScene(arg: []const u8) bool {
    const extension = std.fs.path.extension(arg);
    return std.ascii.eqlIgnoreCase(extension, ".yml") or
        std.ascii.eqlIgnoreCase(extension, ".yaml");
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
fn writeFile(gpa: std.mem.Allocator, io: Io, path: []const u8, image: rt.Image, format: Format) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    try format.write(gpa, io, atomic.file, image);

    try atomic.replace(io);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

/// Room for anything the tests below can select.
const Buffer = [Gallery.count + 8]Source;

test "no arguments draw the newest scene at the size it asks for" {
    var buffer: Buffer = undefined;
    const parsed = try parseJob(&.{}, &buffer);
    try testing.expectEqual(@as(usize, 1), parsed.sources.len);
    try testing.expectEqualStrings(Gallery.latest.name, parsed.sources[0].name());
    try testing.expect(parsed.size == null);
    try testing.expect(parsed.out_dir == null);
}

test "a scene name picks that scene, in any position" {
    var buffer: Buffer = undefined;
    for ([_][]const []const u8{ &.{ "spheres", "80" }, &.{ "80", "spheres" } }) |argv| {
        const parsed = try parseJob(argv, &buffer);
        try testing.expectEqual(@as(usize, 1), parsed.sources.len);
        try testing.expectEqualStrings("spheres", parsed.sources[0].name());
        try testing.expectEqual(Size{ .width = 80, .height = 80 }, parsed.size.?);
    }
}

test "a yaml path is a scene of its own, named after the file" {
    var buffer: Buffer = undefined;
    const parsed = try parseJob(&.{ "scenes/cover.yml", "640x480" }, &buffer);
    try testing.expectEqual(@as(usize, 1), parsed.sources.len);
    try testing.expectEqualStrings("scenes/cover.yml", parsed.sources[0].file);
    try testing.expectEqualStrings("cover", parsed.sources[0].name());
    try testing.expect(parsed.sources[0].dir() == null);
    try testing.expectEqual(Size{ .width = 640, .height = 480 }, parsed.size.?);
}

test "a file and a gallery scene are drawn in the same run" {
    var buffer: Buffer = undefined;
    const parsed = try parseJob(&.{ "cubes", "a.yaml", "cubes", "a.yaml" }, &buffer);
    try testing.expectEqual(@as(usize, 2), parsed.sources.len);
    try testing.expect(parsed.sources[0] == .builtin);
    try testing.expect(parsed.sources[1] == .file);
}

test "all draws every scene, and naming one twice draws it once" {
    var buffer: Buffer = undefined;
    try testing.expectEqual(Gallery.count, (try parseJob(&.{"all"}, &buffer)).sources.len);
    try testing.expectEqual(Gallery.count, (try parseJob(&.{ "all", "all" }, &buffer)).sources.len);

    const parsed = try parseJob(&.{ "cubes", "cubes" }, &buffer);
    try testing.expectEqual(@as(usize, 1), parsed.sources.len);
}

test "-o names the directory the images land in" {
    var buffer: Buffer = undefined;
    const parsed = try parseJob(&.{ "all", "-o", "images", "320x240" }, &buffer);
    try testing.expectEqualStrings("images", parsed.out_dir.?);
    try testing.expectEqual(Size{ .width = 320, .height = 240 }, parsed.size.?);
    try testing.expectError(error.MissingDirectory, parseJob(&.{"-o"}, &buffer));
}

test "-f picks the image format, PNG unless asked otherwise" {
    var buffer: Buffer = undefined;
    try testing.expectEqual(Format.png, (try parseJob(&.{"cubes"}, &buffer)).format);
    try testing.expectEqual(Format.png, (try parseJob(&.{ "--format", "png" }, &buffer)).format);
    if (rt.avif.available) {
        try testing.expectEqual(Format.avif, (try parseJob(&.{ "cubes", "-f", "avif" }, &buffer)).format);
    } else {
        try testing.expectError(error.AvifUnavailable, parseJob(&.{ "-f", "avif" }, &buffer));
    }
    try testing.expectError(error.UnknownFormat, parseJob(&.{ "-f", "jpeg" }, &buffer));
    try testing.expectError(error.MissingFormat, parseJob(&.{"-f"}, &buffer));
}

test "an unknown scene is a mistake, and so is a bad size" {
    var buffer: Buffer = undefined;
    try testing.expectError(error.UnknownScene, parseJob(&.{"teapot"}, &buffer));
    try testing.expectError(error.UnknownScene, parseJob(&.{"scene.json"}, &buffer));
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

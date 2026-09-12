//! The scenes the demo program can draw, as one list.
//!
//! A scene arrives here in one of two shapes. Most are a world seen through a
//! camera, and describe themselves as objects, a world, and an eye. The
//! earliest ones predate both, and draw straight onto the canvas instead. The
//! difference is settled at compile time, so the command line sees one list of
//! names it can render without knowing which kind it asked for.
//!
//! Scenes are kept in the order the ray tracer grows into them, and each
//! belongs to a group — what it is the first image to show — which is also the
//! subdirectory its file lands in.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const canvas = @import("../render/canvas.zig");
const color = @import("../render/color.zig");

const clock = @import("clock.zig");
const hexagon = @import("hexagon.zig");
const triangles = @import("triangles.zig");
const carving = @import("carving.zig");
const cubes = @import("cubes.zig");
const cylinders = @import("cylinders.zig");
const patterns = @import("patterns.zig");
const planes = @import("planes.zig");
const projectile = @import("projectile.zig");
const room = @import("room.zig");
const sphere_cast = @import("sphere_cast.zig");
const spheres = @import("spheres.zig");
const soft_shadows = @import("soft_shadows.zig");

/// The gallery, over a float type.
pub fn Gallery(comptime T: type) type {
    return struct {
        pub const Cam = camera_mod.Camera(T);
        pub const Image = canvas.Canvas(color.Color(T));
        pub const RenderError = Cam.RenderError;

        /// Renders the scene at the given size. The caller owns the result.
        pub const RenderFn = *const fn (
            allocator: std.mem.Allocator,
            io: std.Io,
            width: usize,
            height: usize,
            progress: std.Progress.Node,
            workers: usize,
        ) RenderError!Image;

        pub const Entry = struct {
            name: []const u8,
            /// Where the image belongs among the others: the group's name,
            /// numbered by how far into the gallery the group starts.
            dir: []const u8,
            render: RenderFn,
        };

        /// In the order the ray tracer arrives at them, so drawing the whole
        /// gallery reads as the renderer growing up.
        const scenes = [_]type{
            projectile.Flight(T),
            clock.Face(T),
            sphere_cast.Silhouette(T),
            sphere_cast.Shaded(T),
            room.Scene(T),
            planes.Scene(T),
            patterns.Scene(T),
            spheres.Scene(T),
            cubes.Scene(T),
            cylinders.Scene(T),
            hexagon.Scene(T),
            triangles.Scene(T),
            carving.Scene(T),
            soft_shadows.Scene(T),
        };

        pub const count = scenes.len;

        pub const entries: [count]Entry = blk: {
            var all: [count]Entry = undefined;
            var groups: usize = 0;
            var last: []const u8 = "";
            for (scenes, &all) |Scene, *entry| {
                if (!std.mem.eql(u8, Scene.group, last)) {
                    groups += 1;
                    last = Scene.group;
                }
                entry.* = .{
                    .name = Scene.name,
                    .dir = std.fmt.comptimePrint("{d}-{s}", .{ groups, Scene.group }),
                    .render = renderer(Scene),
                };
            }
            break :blk all;
        };

        /// The scene's whole pipeline behind one function pointer. A world
        /// scene's objects live only as long as the render that looks at them.
        fn renderer(comptime Scene: type) RenderFn {
            return struct {
                fn render(
                    allocator: std.mem.Allocator,
                    io: std.Io,
                    width: usize,
                    height: usize,
                    progress: std.Progress.Node,
                    workers: usize,
                ) RenderError!Image {
                    if (!@hasDecl(Scene, "draw")) {
                        // A scene of groups points its groups at children of its
                        // own, which it can only do once the shapes are
                        // standing where they will stay: here, and not in
                        // the array it handed back.
                        var objects = Scene.objects();
                        const world = Scene.world(&objects);
                        const camera = Scene.camera(width, height);
                        return camera.renderParallel(allocator, io, world, progress, workers);
                    }
                    // Drawing straight onto the canvas costs a fraction of a
                    // render, so it neither reports progress nor splits the
                    // work across threads.
                    var image = try Image.init(allocator, width, height);
                    errdefer image.deinit(allocator);
                    Scene.draw(image);
                    return image;
                }
            }.render;
        }

        /// The scene called `name`, if there is one.
        pub fn find(name: []const u8) ?Entry {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.name, name)) return entry;
            }
            return null;
        }

        /// The last scene: the one the ray tracer has most recently grown
        /// into, and what the demo draws when asked for nothing in particular.
        pub const latest: Entry = entries[count - 1];
    };
}

/// The gallery at the precision the ray tracer uses.
pub const Default = Gallery(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "the gallery runs from the first drawing to the newest scene" {
    try testing.expectEqualStrings("projectile", Default.entries[0].name);
    try testing.expectEqualStrings("soft-shadows", Default.latest.name);

    // Names are what the command line matches on, so they must be distinct.
    for (Default.entries, 0..) |entry, i| {
        for (Default.entries[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, entry.name, other.name));
        }
    }
}

test "scenes of a group share a directory, numbered in gallery order" {
    try testing.expectEqualStrings("1-canvas", Default.entries[0].dir);
    try testing.expectEqualStrings("1-canvas", Default.find("clock").?.dir);
    try testing.expectEqualStrings("2-rays", Default.find("silhouette").?.dir);
    try testing.expectEqualStrings("4-shapes", Default.find("cylinders").?.dir);
    try testing.expectEqualStrings("5-groups", Default.find("hexagon").?.dir);
    try testing.expectEqualStrings("6-triangles", Default.find("triangles").?.dir);
    try testing.expectEqualStrings("7-csg", Default.find("csg").?.dir);
    try testing.expectEqualStrings("8-light", Default.latest.dir);

    // A group is one run of neighbouring scenes: once its directory has been
    // left behind, it is never returned to.
    var seen: [Default.count][]const u8 = undefined;
    var groups: usize = 0;
    for (Default.entries) |entry| {
        if (groups > 0 and std.mem.eql(u8, seen[groups - 1], entry.dir)) continue;
        for (seen[0..groups]) |before| {
            try testing.expect(!std.mem.eql(u8, before, entry.dir));
        }
        seen[groups] = entry.dir;
        groups += 1;
    }
}

test "a scene can be looked up by name, and an unknown one cannot" {
    const entry = Default.find("cubes") orelse return error.MissingScene;
    try testing.expectEqualStrings("cubes", entry.name);
    try testing.expect(Default.find("teapot") == null);
}

test "every scene renders an image of the size asked for" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    for (Default.entries) |entry| {
        var image = try entry.render(testing.allocator, threaded.io(), 4, 3, .none, 2);
        defer image.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 4), image.width);
        try testing.expectEqual(@as(usize, 3), image.height);
    }
}

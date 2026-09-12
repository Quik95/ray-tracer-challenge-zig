//! Scenes read from a file rather than written in source.
//!
//! A scene is a sequence of items, each either something added to the world or
//! a name given to something so that later items can reuse it:
//!
//!     - add: camera
//!       width: 400
//!       height: 200
//!       field-of-view: 1.152
//!       from: [ -3, 2, -6 ]
//!       to: [ 0, 1, 0 ]
//!       up: [ 0, 1, 0 ]
//!
//!     - add: light
//!       at: [ -5, 8, -5 ]
//!       intensity: [ 1, 1, 1 ]
//!
//!     - define: glass
//!       value:
//!         color: [ 0.9, 1, 0.95 ]
//!         transparency: 0.9
//!         refractive-index: 1.5
//!
//!     - add: sphere
//!       material: glass
//!       transform:
//!         - [ scale, 0.7, 0.7, 0.7 ]
//!         - [ translate, 0, 1, 0 ]
//!
//! A definition names a material, a transformation, or a whole shape, and may
//! `extend` another of its kind: the named one is the starting point, and the
//! definition's own keys are laid over it. A transformation extends by being
//! carried out after what it extends, which is the same rule seen from the
//! other side.
//!
//! Every name the format knows is written the way it reads — `field-of-view`,
//! `refractive-index` — and an underscore is accepted wherever a dash is, so a
//! file written either way loads.
//!
//! Nothing here is guessed at. A key the reader does not know is a mistake
//! rather than something quietly skipped, since a typo in a scene file is
//! otherwise invisible: the surface simply comes out the wrong colour.

const std = @import("std");
const camera_mod = @import("../render/camera.zig");
const canvas_mod = @import("../render/canvas.zig");
const color_mod = @import("../render/color.zig");
const csg_mod = @import("csg.zig");
const light_mod = @import("light.zig");
const material_mod = @import("material.zig");
const pattern_mod = @import("pattern.zig");
const shape_mod = @import("shape.zig");
const transform_mod = @import("../math/transform.zig");
const tuple = @import("../math/tuple.zig");
const world_mod = @import("world.zig");
const yaml = @import("yaml.zig");

/// A reader for scene files, over a float type.
pub fn Description(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const C = color_mod.Color(T);
        pub const Cam = camera_mod.Camera(T);
        pub const Image = canvas_mod.Canvas(C);
        pub const Light = light_mod.PointLight(T);
        pub const M = shape_mod.Shape(T).M;
        pub const Mat = material_mod.Material(T);
        pub const Object = shape_mod.Shape(T);
        pub const Pat = pattern_mod.Pattern(T);
        pub const Tf = transform_mod.Transforms(T);
        pub const V = tuple.Tuple(T);
        pub const World = world_mod.World(T);

        /// How deeply one definition may reach through others. A definition
        /// naming itself, however far around, would otherwise not come back.
        const max_depth = 32;

        pub const BuildError = error{
            /// The file is not a sequence of items at all.
            NotAScene,
            /// An item that is not a mapping, or one saying neither what it
            /// adds nor what it defines.
            MalformedItem,
            /// A key the reader does not know, on something that does not
            /// take it.
            UnknownAttribute,
            /// Something added that is neither a known shape nor a defined
            /// one.
            UnknownShape,
            /// A name used before anything was defined under it.
            UnknownDefinition,
            /// A transformation step the reader does not know.
            UnknownTransform,
            /// A pattern of a kind the reader does not know.
            UnknownPattern,
            /// A value of the wrong shape for the key it stands under: three
            /// numbers wanted and two given, a mapping where a name belongs.
            MalformedValue,
            /// Definitions that reach around to themselves.
            DefinitionCycle,
            /// A scene with nothing to look through.
            MissingCamera,
            /// A camera that cannot see: no size, no angle, or an eye and a
            /// subject in the same place.
            BadCamera,
            /// A light of some size with no size, or one spread over nothing.
            BadLight,
        };

        pub const Error = yaml.ParseError || BuildError;

        /// What went wrong, in the file's own words: the name or the value
        /// the reader stopped at. Filled in when parsing fails, so that a
        /// caller can say which key it was rather than only that some key
        /// was wrong.
        pub const Diagnostic = struct {
            /// Borrowed from the source text, so it lives as long as that.
            what: []const u8 = "",
        };

        /// A scene read from a file: what is in it, what lights it, and where
        /// it is seen from.
        ///
        /// The shapes are kept in one arena and never move, which is what
        /// lets a group point at its children and every child point back.
        pub const Scene = struct {
            arena: *std.heap.ArenaAllocator,
            /// The shapes the world holds, already linked.
            objects: []Object,
            light: ?Light,
            camera: Cam,

            pub fn deinit(self: *Scene) void {
                const gpa = self.arena.child_allocator;
                self.arena.deinit();
                gpa.destroy(self.arena);
                self.* = undefined;
            }

            pub fn world(self: *const Scene) World {
                return .{ .objects = self.objects, .light = self.light };
            }

            /// Draw the scene at a size other than the one it asks for. The
            /// field of view is the angle across the wider side either way,
            /// so a scene keeps its framing as it is enlarged.
            pub fn resize(self: *Scene, width: usize, height: usize) void {
                self.camera.hsize = width;
                self.camera.vsize = height;
            }
        };

        /// Read `source` as a scene. The caller owns the result and frees it
        /// with `deinit`; unlike the document it is read from, the scene
        /// holds no slices into `source` and may outlive it.
        pub fn parse(
            gpa: std.mem.Allocator,
            source: []const u8,
            diagnostic: ?*Diagnostic,
        ) Error!Scene {
            var document = try yaml.parse(gpa, source);
            defer document.deinit();

            const arena = try gpa.create(std.heap.ArenaAllocator);
            errdefer gpa.destroy(arena);
            arena.* = .init(gpa);
            errdefer arena.deinit();

            var builder: Builder = .{ .arena = arena.allocator(), .diagnostic = diagnostic };
            const items = switch (document.root) {
                .list => |items| items,
                else => return error.NotAScene,
            };

            var objects: std.ArrayList(Object) = .empty;
            var camera: ?Cam = null;
            var light: ?Light = null;

            for (items) |item| {
                if (item != .map) return error.MalformedItem;

                if (item.get("define")) |name| {
                    const key = name.text() orelse return builder.fail(error.MalformedItem, "define");
                    try builder.defines.put(builder.arena, key, .{
                        .value = item.get("value") orelse .empty,
                        .extend = if (item.get("extend")) |e| e.text() else null,
                    });
                    continue;
                }

                const add = item.get("add") orelse return error.MalformedItem;
                const what = add.text() orelse return builder.fail(error.MalformedItem, "add");
                if (eqlKey(what, "camera")) {
                    camera = try builder.camera(item);
                } else if (eqlKey(what, "light") or eqlKey(what, "point-light") or
                    eqlKey(what, "area-light"))
                {
                    light = try builder.light(item);
                } else {
                    try objects.append(builder.arena, try builder.shape(item));
                }
            }

            // A group learns which children are its own only once they stand
            // where they will stay — here, in the arena, rather than in the
            // list they were collected in.
            const owned = try objects.toOwnedSlice(builder.arena);
            Object.linkAll(owned);

            return .{
                .arena = arena,
                .objects = owned,
                .light = light,
                .camera = camera orelse return error.MissingCamera,
            };
        }

        pub const RenderError = Error || Cam.RenderError;

        /// Read `source` and draw what it describes. A width or a height of
        /// zero takes the scene's own.
        pub fn render(
            gpa: std.mem.Allocator,
            io: std.Io,
            source: []const u8,
            width: usize,
            height: usize,
            progress: std.Progress.Node,
            workers: usize,
            diagnostic: ?*Diagnostic,
        ) RenderError!Image {
            var scene = try parse(gpa, source, diagnostic);
            defer scene.deinit();
            if (width != 0 and height != 0) scene.resize(width, height);
            return scene.camera.renderParallel(gpa, io, scene.world(), progress, workers);
        }

        /// A definition: what was written under the name, and what it builds
        /// on, if anything.
        const Define = struct {
            value: yaml.Value,
            extend: ?[]const u8,
        };

        /// The scene under construction: the names given so far, and the
        /// memory everything is built in.
        const Builder = struct {
            arena: std.mem.Allocator,
            defines: std.StringHashMapUnmanaged(Define) = .empty,
            diagnostic: ?*Diagnostic,
            depth: usize = 0,

            /// Fail with `err`, noting what the reader stopped at.
            fn fail(self: Builder, err: BuildError, what: []const u8) BuildError {
                if (self.diagnostic) |d| d.what = what;
                return err;
            }

            // --- The things a scene is made of --------------------------

            fn camera(self: *Builder, map: yaml.Value) Error!Cam {
                var from: V = .point(0, 0, -1);
                var to: V = .point(0, 0, 0);
                var up: V = .vector(0, 1, 0);
                var result: Cam = .init(100, 100, std.math.pi / 3.0);

                for (map.fields()) |field| {
                    const key = field.key;
                    const value = field.value;
                    if (eqlKey(key, "add")) continue;
                    if (eqlKey(key, "width")) {
                        result.hsize = value.count() orelse return self.fail(error.MalformedValue, key);
                    } else if (eqlKey(key, "height")) {
                        result.vsize = value.count() orelse return self.fail(error.MalformedValue, key);
                    } else if (eqlKey(key, "field-of-view")) {
                        result.field_of_view = try self.number(value, key);
                    } else if (eqlKey(key, "from")) {
                        from = try self.point(value, key);
                    } else if (eqlKey(key, "to")) {
                        to = try self.point(value, key);
                    } else if (eqlKey(key, "up")) {
                        up = try self.vector(value, key);
                    } else if (eqlKey(key, "supersample")) {
                        result.supersample = value.count() orelse return self.fail(error.MalformedValue, key);
                    } else if (eqlKey(key, "aperture")) {
                        result.aperture = try self.number(value, key);
                    } else if (eqlKey(key, "focus")) {
                        result.focus = try self.number(value, key);
                    } else return self.fail(error.UnknownAttribute, key);
                }

                if (result.hsize == 0 or result.vsize == 0) return error.BadCamera;
                result.transform = Tf.viewChecked(from, to, up) catch return error.BadCamera;
                return result;
            }

            fn light(self: *Builder, map: yaml.Value) Error!Light {
                var position: ?V = null;
                var intensity: C = .white;
                var corner: ?V = null;
                var u_edge: V = .vector(1, 0, 0);
                var v_edge: V = .vector(0, 0, 1);
                var usteps: usize = 1;
                var vsteps: usize = 1;

                for (map.fields()) |field| {
                    const key = field.key;
                    const value = field.value;
                    if (eqlKey(key, "add")) continue;
                    if (eqlKey(key, "at") or eqlKey(key, "position")) {
                        position = try self.point(value, key);
                    } else if (eqlKey(key, "intensity")) {
                        intensity = try self.color(value, key);
                    } else if (eqlKey(key, "corner")) {
                        corner = try self.point(value, key);
                    } else if (eqlKey(key, "uvec")) {
                        u_edge = try self.vector(value, key);
                    } else if (eqlKey(key, "vvec")) {
                        v_edge = try self.vector(value, key);
                    } else if (eqlKey(key, "usteps")) {
                        usteps = value.count() orelse return self.fail(error.MalformedValue, key);
                    } else if (eqlKey(key, "vsteps")) {
                        vsteps = value.count() orelse return self.fail(error.MalformedValue, key);
                    } else return self.fail(error.UnknownAttribute, key);
                }

                // A light given a corner is one with a surface, however it
                // was named; one given only a place is a point.
                if (corner) |at| {
                    if (usteps == 0 or vsteps == 0) return error.BadLight;
                    if (u_edge.magnitude() == 0 or v_edge.magnitude() == 0) return error.BadLight;
                    return .area(at, u_edge, usteps, v_edge, vsteps, intensity);
                }
                return .init(position orelse return error.BadLight, intensity);
            }

            /// The shape an `add:` item describes.
            fn shape(self: *Builder, map: yaml.Value) Error!Object {
                const add = map.get("add") orelse return error.MalformedItem;
                const what = add.text() orelse return self.fail(error.MalformedItem, "add");
                var object = try self.geometryOf(what);
                try self.attributes(&object, map);
                return object;
            }

            /// A fresh shape of the kind `what` names: one the reader knows,
            /// or one the file has defined.
            fn geometryOf(self: *Builder, what: []const u8) Error!Object {
                if (eqlKey(what, "sphere")) return .sphere();
                if (eqlKey(what, "plane")) return .plane();
                if (eqlKey(what, "cube")) return .cube();
                if (eqlKey(what, "cylinder")) return .cylinder();
                if (eqlKey(what, "cone")) return .cone();
                if (eqlKey(what, "group")) return .group(&.{});
                if (eqlKey(what, "csg")) {
                    // Both operands stand in the pair from the start, so that
                    // `left` and `right` may be written in either order.
                    const pair = try self.arena.alloc(Object, 2);
                    pair[0] = .sphere();
                    pair[1] = .sphere();
                    return .csg(.@"union", pair);
                }
                if (self.defines.get(what) != null) return self.definedShape(what);
                return self.fail(error.UnknownShape, what);
            }

            /// The shape a definition names: what it extends, if anything,
            /// then what it says of its own.
            fn definedShape(self: *Builder, name: []const u8) Error!Object {
                const define = self.defines.get(name) orelse
                    return self.fail(error.UnknownDefinition, name);
                try self.descend(name);
                defer self.depth -= 1;

                var object: Object = if (define.extend) |base|
                    try self.definedShape(base)
                else
                    .sphere();

                // A definition that extends another may still say what it is,
                // and keeps everything but the geometry of what it extends.
                if (define.value.get("add")) |add| {
                    const what = add.text() orelse return self.fail(error.MalformedItem, "add");
                    object.geometry = (try self.geometryOf(what)).geometry;
                } else if (define.extend == null) {
                    return self.fail(error.MalformedValue, name);
                }

                try self.attributes(&object, define.value);
                return object;
            }

            /// Everything an item says about a shape past what it is.
            fn attributes(self: *Builder, object: *Object, map: yaml.Value) Error!void {
                for (map.fields()) |field| {
                    const key = field.key;
                    const value = field.value;
                    if (eqlKey(key, "add") or eqlKey(key, "define") or
                        eqlKey(key, "extend") or eqlKey(key, "value")) continue;

                    if (eqlKey(key, "material")) {
                        object.material = try self.material(value, object.material);
                    } else if (eqlKey(key, "transform")) {
                        object.transform = try self.transform(value, object.transform);
                    } else if (eqlKey(key, "shadow") or eqlKey(key, "casts-shadow")) {
                        object.casts_shadow = value.boolean() orelse
                            return self.fail(error.MalformedValue, key);
                    } else if (eqlKey(key, "min") or eqlKey(key, "minimum")) {
                        try self.setEnd(object, .minimum, try self.number(value, key), key);
                    } else if (eqlKey(key, "max") or eqlKey(key, "maximum")) {
                        try self.setEnd(object, .maximum, try self.number(value, key), key);
                    } else if (eqlKey(key, "closed")) {
                        const closed = value.boolean() orelse
                            return self.fail(error.MalformedValue, key);
                        switch (object.geometry) {
                            .cylinder => |*g| g.closed = closed,
                            .cone => |*g| g.closed = closed,
                            else => return self.fail(error.UnknownAttribute, key),
                        }
                    } else if (eqlKey(key, "children")) {
                        if (object.geometry != .group) return self.fail(error.UnknownAttribute, key);
                        object.geometry.group.children = try self.children(value);
                    } else if (eqlKey(key, "operation")) {
                        if (object.geometry != .csg) return self.fail(error.UnknownAttribute, key);
                        object.geometry.csg.operation = try self.operation(value, key);
                    } else if (eqlKey(key, "left") or eqlKey(key, "right")) {
                        if (object.geometry != .csg) return self.fail(error.UnknownAttribute, key);
                        if (value != .map) return self.fail(error.MalformedValue, key);
                        const side: usize = if (eqlKey(key, "left")) 0 else 1;
                        object.geometry.csg.children[side] = try self.shape(value);
                    } else return self.fail(error.UnknownAttribute, key);
                }
            }

            /// Where a truncatable shape is cut off. Only the two surfaces of
            /// revolution have ends to speak of.
            fn setEnd(
                self: *Builder,
                object: *Object,
                comptime end: enum { minimum, maximum },
                at: T,
                key: []const u8,
            ) Error!void {
                switch (object.geometry) {
                    .cylinder => |*g| @field(g, @tagName(end)) = at,
                    .cone => |*g| @field(g, @tagName(end)) = at,
                    else => return self.fail(error.UnknownAttribute, key),
                }
            }

            fn children(self: *Builder, value: yaml.Value) Error![]Object {
                var out: std.ArrayList(Object) = .empty;
                for (value.items()) |child| {
                    if (child != .map) return self.fail(error.MalformedValue, "children");
                    try out.append(self.arena, try self.shape(child));
                }
                return out.toOwnedSlice(self.arena);
            }

            fn operation(self: *Builder, value: yaml.Value, key: []const u8) Error!csg_mod.Csg(T).Operation {
                const what = value.text() orelse return self.fail(error.MalformedValue, key);
                if (eqlKey(what, "union")) return .@"union";
                if (eqlKey(what, "intersection") or eqlKey(what, "intersect")) return .intersect;
                if (eqlKey(what, "difference")) return .difference;
                return self.fail(error.MalformedValue, what);
            }

            // --- Materials and patterns ---------------------------------

            /// The material `value` describes, laid over `base`: a name to
            /// look up, or the keys themselves.
            fn material(self: *Builder, value: yaml.Value, base: Mat) Error!Mat {
                if (value.text()) |name| return self.definedMaterial(name, base);
                if (value != .map) return self.fail(error.MalformedValue, "material");

                var result = base;
                for (value.fields()) |field| {
                    const key = field.key;
                    const v = field.value;
                    if (eqlKey(key, "color") or eqlKey(key, "colour")) {
                        result.color = try self.color(v, key);
                    } else if (eqlKey(key, "ambient")) {
                        result.ambient = try self.number(v, key);
                    } else if (eqlKey(key, "diffuse")) {
                        result.diffuse = try self.number(v, key);
                    } else if (eqlKey(key, "specular")) {
                        result.specular = try self.number(v, key);
                    } else if (eqlKey(key, "shininess")) {
                        result.shininess = try self.number(v, key);
                    } else if (eqlKey(key, "reflective")) {
                        result.reflective = try self.number(v, key);
                    } else if (eqlKey(key, "transparency")) {
                        result.transparency = try self.number(v, key);
                    } else if (eqlKey(key, "refractive-index")) {
                        result.refractive_index = try self.number(v, key);
                    } else if (eqlKey(key, "pattern")) {
                        result.pattern = try self.pattern(v);
                    } else return self.fail(error.UnknownAttribute, key);
                }
                return result;
            }

            fn definedMaterial(self: *Builder, name: []const u8, base: Mat) Error!Mat {
                const define = self.defines.get(name) orelse
                    return self.fail(error.UnknownDefinition, name);
                try self.descend(name);
                defer self.depth -= 1;

                const start = if (define.extend) |other|
                    try self.definedMaterial(other, base)
                else
                    base;
                return self.material(define.value, start);
            }

            fn pattern(self: *Builder, value: yaml.Value) Error!Pat {
                if (value != .map) return self.fail(error.MalformedValue, "pattern");

                var kind: ?[]const u8 = null;
                var a: C = .white;
                var b: C = .black;
                var map: Pat.Mapping = .planar;
                var u: T = 2;
                var v: T = 2;
                var matrix: M = .identity;

                for (value.fields()) |field| {
                    const key = field.key;
                    const item = field.value;
                    if (eqlKey(key, "type")) {
                        kind = item.text() orelse return self.fail(error.MalformedValue, key);
                    } else if (eqlKey(key, "colors") or eqlKey(key, "colours")) {
                        const pair = item.items();
                        if (pair.len != 2) return self.fail(error.MalformedValue, key);
                        a = try self.color(pair[0], key);
                        b = try self.color(pair[1], key);
                    } else if (eqlKey(key, "transform")) {
                        matrix = try self.transform(item, matrix);
                    } else if (eqlKey(key, "mapping")) {
                        map = try self.mapping(item, key);
                    } else if (eqlKey(key, "u") or eqlKey(key, "width")) {
                        u = try self.number(item, key);
                    } else if (eqlKey(key, "v") or eqlKey(key, "height")) {
                        v = try self.number(item, key);
                    } else return self.fail(error.UnknownAttribute, key);
                }

                const what = kind orelse return self.fail(error.MalformedValue, "pattern");
                var result: Pat = if (eqlKey(what, "stripes") or eqlKey(what, "stripe"))
                    .stripes(a, b)
                else if (eqlKey(what, "gradient"))
                    .gradient(a, b)
                else if (eqlKey(what, "rings") or eqlKey(what, "ring"))
                    .rings(a, b)
                else if (eqlKey(what, "checkers") or eqlKey(what, "checker"))
                    .checkers(a, b)
                else if (eqlKey(what, "uv-checkers"))
                    .uvCheckers(map, u, v, a, b)
                else
                    return self.fail(error.UnknownPattern, what);

                result.transform = matrix;
                return result;
            }

            fn mapping(self: *Builder, value: yaml.Value, key: []const u8) Error!Pat.Mapping {
                const what = value.text() orelse return self.fail(error.MalformedValue, key);
                if (eqlKey(what, "planar")) return .planar;
                if (eqlKey(what, "spherical")) return .spherical;
                if (eqlKey(what, "cylindrical")) return .cylindrical;
                return self.fail(error.MalformedValue, what);
            }

            // --- Transformations ----------------------------------------

            /// `value` carried out after `base`: a single step, a sequence of
            /// them, or the name of a definition holding either.
            fn transform(self: *Builder, value: yaml.Value, base: M) Error!M {
                if (value.text()) |name| return self.definedTransform(name, base);

                const steps = value.items();
                if (steps.len == 0) return self.fail(error.MalformedValue, "transform");

                // A step and a sequence of steps are both written as a list.
                // What tells them apart is the first element: a step names
                // itself there, a sequence holds another list or a name.
                if (steps[0].text()) |head| return self.step(head, steps, base);

                var result = base;
                for (steps) |item| result = try self.transform(item, result);
                return result;
            }

            fn definedTransform(self: *Builder, name: []const u8, base: M) Error!M {
                const define = self.defines.get(name) orelse
                    return self.fail(error.UnknownDefinition, name);
                try self.descend(name);
                defer self.depth -= 1;

                const start = if (define.extend) |other|
                    try self.definedTransform(other, base)
                else
                    base;
                return self.transform(define.value, start);
            }

            /// One step, named first and given its numbers after.
            fn step(self: *Builder, what: []const u8, words: []const yaml.Value, base: M) Error!M {
                const args = words[1..];
                const m: M = if (eqlKey(what, "translate")) blk: {
                    const n = try self.numbers(3, args, what);
                    break :blk Tf.translation(n[0], n[1], n[2]);
                } else if (eqlKey(what, "scale")) blk: {
                    const n = try self.numbers(3, args, what);
                    break :blk Tf.scaling(n[0], n[1], n[2]);
                } else if (eqlKey(what, "rotate-x")) blk: {
                    const n = try self.numbers(1, args, what);
                    break :blk Tf.rotationX(n[0]);
                } else if (eqlKey(what, "rotate-y")) blk: {
                    const n = try self.numbers(1, args, what);
                    break :blk Tf.rotationY(n[0]);
                } else if (eqlKey(what, "rotate-z")) blk: {
                    const n = try self.numbers(1, args, what);
                    break :blk Tf.rotationZ(n[0]);
                } else if (eqlKey(what, "shear") or eqlKey(what, "shearing")) blk: {
                    const n = try self.numbers(6, args, what);
                    break :blk Tf.shearing(n[0], n[1], n[2], n[3], n[4], n[5]);
                } else return self.fail(error.UnknownTransform, what);

                // Steps are carried out in the order they are written, so
                // each multiplies onto the left of what came before.
                return m.mul(base);
            }

            // --- Reading the numbers themselves --------------------------

            fn descend(self: *Builder, name: []const u8) BuildError!void {
                self.depth += 1;
                if (self.depth > max_depth) return self.fail(error.DefinitionCycle, name);
            }

            fn number(self: Builder, value: yaml.Value, key: []const u8) BuildError!T {
                return value.float(T) orelse self.fail(error.MalformedValue, key);
            }

            /// Exactly `n` numbers, and a mistake if the file wrote another
            /// count — a coordinate short is otherwise a zero nobody meant.
            fn numbers(
                self: Builder,
                comptime n: usize,
                values: []const yaml.Value,
                key: []const u8,
            ) BuildError![n]T {
                if (values.len != n) return self.fail(error.MalformedValue, key);
                var out: [n]T = undefined;
                for (values, &out) |value, *slot| slot.* = try self.number(value, key);
                return out;
            }

            fn point(self: Builder, value: yaml.Value, key: []const u8) BuildError!V {
                const n = try self.numbers(3, value.items(), key);
                return .point(n[0], n[1], n[2]);
            }

            fn vector(self: Builder, value: yaml.Value, key: []const u8) BuildError!V {
                const n = try self.numbers(3, value.items(), key);
                return .vector(n[0], n[1], n[2]);
            }

            fn color(self: Builder, value: yaml.Value, key: []const u8) BuildError!C {
                const n = try self.numbers(3, value.items(), key);
                return .init(n[0], n[1], n[2]);
            }
        };
    };
}

/// Whether two names are the same, reading a dash and an underscore as one
/// character: a file written `refractive_index` means what one written
/// `refractive-index` does.
fn eqlKey(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const cx = if (x == '_') '-' else std.ascii.toLower(x);
        const cy = if (y == '_') '-' else std.ascii.toLower(y);
        if (cx != cy) return false;
    }
    return true;
}

/// The scene reader at the precision the ray tracer uses.
pub const Desc = Description(f64);

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const Col = color_mod.Col;
const V4 = tuple.Tup;
const feq = tuple.feq;

fn read(source: []const u8) !Desc.Scene {
    return Desc.parse(testing.allocator, source, null);
}

/// A scene with the least a file can say, so that a test writing about one
/// thing does not have to describe a whole world around it.
const preamble =
    \\- add: camera
    \\  width: 10
    \\  height: 5
    \\  field-of-view: 0.8
    \\  from: [ 0, 2, -5 ]
    \\  to: [ 0, 1, 0 ]
    \\  up: [ 0, 1, 0 ]
    \\- add: light
    \\  at: [ -5, 10, -5 ]
    \\  intensity: [ 1, 1, 1 ]
    \\
;

test "a camera is placed where the file says it looks from" {
    var scene = try read(preamble);
    defer scene.deinit();

    try testing.expectEqual(@as(usize, 10), scene.camera.hsize);
    try testing.expectEqual(@as(usize, 5), scene.camera.vsize);
    try testing.expect(feq(f64, 0.8, scene.camera.field_of_view));
    try testing.expect(scene.camera.transform.eql(
        Desc.Tf.view(.point(0, 2, -5), .point(0, 1, 0), .vector(0, 1, 0)),
    ));
    try testing.expect(scene.light.?.position.eql(V4.point(-5, 10, -5)));
    try testing.expect(scene.light.?.surface == null);
}

test "a light given a corner is one with a surface" {
    var scene = try read(
        \\- add: camera
        \\  width: 4
        \\  height: 4
        \\  field-of-view: 1
        \\- add: light
        \\  corner: [ -1, 2, 4 ]
        \\  uvec: [ 2, 0, 0 ]
        \\  vvec: [ 0, 2, 0 ]
        \\  usteps: 4
        \\  vsteps: 2
        \\  intensity: [ 1.5, 1.5, 1.5 ]
    );
    defer scene.deinit();

    const surface = scene.light.?.surface.?;
    try testing.expectEqual(@as(usize, 8), scene.light.?.samples());
    try testing.expect(surface.u.eql(V4.vector(0.5, 0, 0)));
    try testing.expect(scene.light.?.position.eql(V4.point(0, 3, 4)));
}

test "the shapes the reader knows" {
    var scene = try read(preamble ++
        \\- add: sphere
        \\- add: plane
        \\- add: cube
        \\- add: cylinder
        \\- add: cone
    );
    defer scene.deinit();

    try testing.expectEqual(@as(usize, 5), scene.objects.len);
    try testing.expect(scene.objects[0].geometry == .sphere);
    try testing.expect(scene.objects[1].geometry == .plane);
    try testing.expect(scene.objects[2].geometry == .cube);
    try testing.expect(scene.objects[3].geometry == .cylinder);
    try testing.expect(scene.objects[4].geometry == .cone);
}

test "transformations are carried out in the order they are written" {
    var scene = try read(preamble ++
        \\- add: sphere
        \\  transform:
        \\    - [ scale, 2, 2, 2 ]
        \\    - [ translate, 0, 1, 0 ]
    );
    defer scene.deinit();

    const expected = Desc.Tf.chain().scale(2, 2, 2).translate(0, 1, 0).m;
    try testing.expect(scene.objects[0].transform.eql(expected));
}

test "every step the reader knows" {
    var scene = try read(preamble ++
        \\- add: sphere
        \\  transform:
        \\    - [ rotate-x, 0.5 ]
        \\    - [ rotate-y, 0.25 ]
        \\    - [ rotate-z, 0.125 ]
        \\    - [ shear, 1, 0, 0, 0, 0, 0 ]
    );
    defer scene.deinit();

    const expected = Desc.Tf.chain()
        .rotateX(0.5)
        .rotateY(0.25)
        .rotateZ(0.125)
        .shear(1, 0, 0, 0, 0, 0).m;
    try testing.expect(scene.objects[0].transform.eql(expected));
}

test "a material is written out or named" {
    var scene = try read(preamble ++
        \\- define: brass
        \\  value:
        \\    color: [ 0.8, 0.7, 0.2 ]
        \\    specular: 0.9
        \\    shininess: 300
        \\- add: sphere
        \\  material: brass
        \\- add: cube
        \\  material:
        \\    color: [ 0.8, 0.7, 0.2 ]
        \\    specular: 0.9
        \\    shininess: 300
    );
    defer scene.deinit();

    try testing.expect(scene.objects[0].material.eql(scene.objects[1].material));
    try testing.expect(scene.objects[0].material.color.eql(Col.init(0.8, 0.7, 0.2)));
}

test "a definition extends another by laying its own keys over it" {
    var scene = try read(preamble ++
        \\- define: base
        \\  value:
        \\    color: [ 1, 1, 1 ]
        \\    diffuse: 0.7
        \\- define: darker
        \\  extend: base
        \\  value:
        \\    diffuse: 0.2
        \\- add: sphere
        \\  material: darker
    );
    defer scene.deinit();

    const m = scene.objects[0].material;
    try testing.expect(m.color.eql(Col.white));
    try testing.expect(feq(f64, 0.2, m.diffuse));
}

test "a transformation extends another by coming after it" {
    var scene = try read(preamble ++
        \\- define: standing
        \\  value:
        \\    - [ scale, 2, 2, 2 ]
        \\- define: standing-back
        \\  extend: standing
        \\  value:
        \\    - [ translate, 0, 0, 5 ]
        \\- add: sphere
        \\  transform: standing-back
    );
    defer scene.deinit();

    const expected = Desc.Tf.chain().scale(2, 2, 2).translate(0, 0, 5).m;
    try testing.expect(scene.objects[0].transform.eql(expected));
}

test "a definition naming a shape is added like any other" {
    var scene = try read(preamble ++
        \\- define: pedestal
        \\  value:
        \\    add: cylinder
        \\    min: 0
        \\    max: 0.4
        \\    closed: true
        \\- add: pedestal
        \\  transform:
        \\    - [ translate, 1, 0, 0 ]
    );
    defer scene.deinit();

    const g = scene.objects[0].geometry.cylinder;
    try testing.expect(feq(f64, 0.4, g.maximum));
    try testing.expect(g.closed);
    try testing.expect(scene.objects[0].transform.eql(Desc.Tf.translation(1, 0, 0)));
}

test "a group holds its children, and they know it holds them" {
    var scene = try read(preamble ++
        \\- add: group
        \\  transform:
        \\    - [ translate, 0, 2, 0 ]
        \\  children:
        \\    - add: sphere
        \\    - add: cube
        \\      transform:
        \\        - [ scale, 0.5, 0.5, 0.5 ]
    );
    defer scene.deinit();

    const children = scene.objects[0].geometry.group.children;
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expect(children[1].parent == &scene.objects[0]);
    try testing.expect(children[1].geometry == .cube);
}

test "a carved shape takes its two sides in either order" {
    inline for (.{
        \\- add: csg
        \\  operation: difference
        \\  left:
        \\    add: cube
        \\  right:
        \\    add: sphere
        ,
        \\- add: csg
        \\  right:
        \\    add: sphere
        \\  left:
        \\    add: cube
        \\  operation: difference
        ,
    }) |tail| {
        var scene = try read(preamble ++ tail);
        defer scene.deinit();

        const c = scene.objects[0].geometry.csg;
        try testing.expectEqual(csg_mod.Cs.Operation.difference, c.operation);
        try testing.expect(c.children[0].geometry == .cube);
        try testing.expect(c.children[1].geometry == .sphere);
    }
}

test "a pattern is read with its colours and its own transformation" {
    var scene = try read(preamble ++
        \\- add: plane
        \\  material:
        \\    pattern:
        \\      type: checkers
        \\      colors:
        \\        - [ 1, 1, 1 ]
        \\        - [ 0, 0, 0 ]
        \\      transform:
        \\        - [ scale, 0.5, 0.5, 0.5 ]
    );
    defer scene.deinit();

    const p = scene.objects[0].material.pattern.?;
    try testing.expect(p.kind == .checkers);
    try testing.expect(p.kind.checkers.a.eql(Col.white));
    try testing.expect(p.transform.eql(Desc.Tf.scaling(0.5, 0.5, 0.5)));
}

test "a pattern wrapped onto the surface itself" {
    var scene = try read(preamble ++
        \\- add: sphere
        \\  material:
        \\    pattern:
        \\      type: uv-checkers
        \\      mapping: spherical
        \\      width: 20
        \\      height: 10
        \\      colors: [ [ 0, 0.5, 0 ], [ 1, 1, 1 ] ]
    );
    defer scene.deinit();

    const uv = scene.objects[0].material.pattern.?.kind.uv_checkers;
    try testing.expectEqual(Desc.Pat.Mapping.spherical, uv.map);
    try testing.expect(feq(f64, 20, uv.u));
    try testing.expect(feq(f64, 10, uv.v));
}

test "a shape can be told not to cast a shadow" {
    var scene = try read(preamble ++
        \\- add: sphere
        \\  shadow: false
        \\- add: cube
    );
    defer scene.deinit();

    try testing.expect(!scene.objects[0].casts_shadow);
    try testing.expect(scene.objects[1].casts_shadow);
}

test "a dash and an underscore read the same" {
    var scene = try read(
        \\- add: camera
        \\  width: 4
        \\  height: 4
        \\  field_of_view: 1
        \\- add: sphere
        \\  material:
        \\    refractive_index: 1.5
    );
    defer scene.deinit();

    try testing.expect(feq(f64, 1.5, scene.objects[0].material.refractive_index));
}

test "the scene is drawn at whatever size is asked for" {
    var scene = try read(preamble);
    defer scene.deinit();

    scene.resize(64, 32);
    try testing.expectEqual(@as(usize, 64), scene.camera.hsize);
    try testing.expectEqual(@as(usize, 32), scene.camera.vsize);
}

test "a mistake in the file names itself" {
    var diagnostic: Desc.Diagnostic = .{};
    try testing.expectError(error.UnknownAttribute, Desc.parse(testing.allocator, preamble ++
        \\- add: sphere
        \\  colour-of-the-day: [ 1, 0, 0 ]
    , &diagnostic));
    try testing.expectEqualStrings("colour-of-the-day", diagnostic.what);

    try testing.expectError(error.UnknownShape, Desc.parse(testing.allocator, preamble ++
        \\- add: dodecahedron
    , &diagnostic));
    try testing.expectEqualStrings("dodecahedron", diagnostic.what);

    try testing.expectError(error.UnknownDefinition, Desc.parse(testing.allocator, preamble ++
        \\- add: sphere
        \\  material: nothing-defined-under-this
    , &diagnostic));
    try testing.expectEqualStrings("nothing-defined-under-this", diagnostic.what);

    try testing.expectError(error.UnknownTransform, Desc.parse(testing.allocator, preamble ++
        \\- add: sphere
        \\  transform:
        \\    - [ wobble, 1 ]
    , &diagnostic));
    try testing.expectEqualStrings("wobble", diagnostic.what);
}

test "a coordinate short is refused rather than filled in" {
    try testing.expectError(error.MalformedValue, read(
        \\- add: camera
        \\  width: 4
        \\  height: 4
        \\  field-of-view: 1
        \\  from: [ 0, 2 ]
    ));
    try testing.expectError(error.MalformedValue, read(preamble ++
        \\- add: sphere
        \\  transform:
        \\    - [ translate, 1, 2 ]
    ));
}

test "definitions that reach around to themselves come back" {
    try testing.expectError(error.DefinitionCycle, read(preamble ++
        \\- define: a
        \\  extend: b
        \\  value:
        \\    diffuse: 0.1
        \\- define: b
        \\  extend: a
        \\  value:
        \\    diffuse: 0.2
        \\- add: sphere
        \\  material: a
    ));
}

test "a scene with no camera is not a scene that can be drawn" {
    try testing.expectError(error.MissingCamera, read(
        \\- add: sphere
    ));
    try testing.expectError(error.NotAScene, read("width: 100"));
    try testing.expectError(error.BadCamera, read(
        \\- add: camera
        \\  width: 0
        \\  height: 4
        \\  field-of-view: 1
    ));
}

test "an ends-only attribute belongs only to what has ends" {
    var diagnostic: Desc.Diagnostic = .{};
    try testing.expectError(error.UnknownAttribute, Desc.parse(testing.allocator, preamble ++
        \\- add: sphere
        \\  closed: true
    , &diagnostic));
    try testing.expectEqualStrings("closed", diagnostic.what);
}

test "a whole scene renders from the file it is written in" {
    var scene = try read(preamble ++
        \\- add: plane
        \\  material:
        \\    color: [ 1, 1, 1 ]
        \\- add: sphere
        \\  transform:
        \\    - [ translate, 0, 1, 0 ]
        \\  material:
        \\    color: [ 1, 0, 0 ]
    );
    defer scene.deinit();

    var image = try scene.camera.render(testing.allocator, scene.world(), .none);
    defer image.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 10), image.width);

    // The sphere stands in the middle of the picture and is the only red
    // thing in it, so the middle pixel has to have caught it.
    const middle = image.pixelAt(image.width / 2, image.height / 2);
    try testing.expect(middle.red() > middle.blue());
}

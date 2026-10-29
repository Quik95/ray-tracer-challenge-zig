const std = @import("std");

// zigimg crashes the self-hosted x86 backend, so everything that reaches its
// code is compiled through LLVM. Upstream does the same for its own tests.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });

    // AVIF output links the system libavif, found through pkg-config. A host
    // without it can still build everything else with `-Davif=false`.
    const avif = b.option(bool, "avif", "Write AVIF images through the system libavif (default: true)") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "avif", avif);

    const mod = b.addModule("ray_tracing_challange_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zigimg", .module = zigimg.module("zigimg") },
        },
    });
    mod.addOptions("build_options", build_options);
    if (avif) {
        const header = b.addWriteFiles().add("avif.h", "#include <avif/avif.h>\n");
        const translate_c = b.addTranslateC(.{
            .root_source_file = header,
            .target = target,
            .optimize = optimize,
        });
        translate_c.linkSystemLibrary("libavif", .{});
        mod.addImport("avif_c", translate_c.createModule());
    }

    // The demo draws a few meshes too large to write out by hand, so the
    // library carries them as files it embeds rather than as source.
    for ([_][]const u8{ "teapot.obj", "suzanne.obj", "spot.obj" }) |model| {
        mod.addAnonymousImport(model, .{ .root_source_file = b.path(b.pathJoin(&.{ "models", model })) });
    }

    const exe = b.addExecutable(.{
        .name = "ray_tracing_challange_zig",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ray_tracing_challange_zig", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    // Zig only runs tests in files the compiler actually analyzes, and 0.16
    // dropped `refAllDeclsRecursive`. src/root.zig imports every module
    // explicitly; this option lets it assert that list matches src/ on disk.
    const source_files = b.addOptions();
    source_files.addOption([]const []const u8, "names", listZigSources(b, "src"));
    mod.addOptions("source_files", source_files);

    const mod_tests = b.addTest(.{ .root_module = mod, .use_llvm = true });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .use_llvm = true });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

/// Paths of the `.zig` files under `sub_path`, relative to it and including
/// subdirectories, sorted for a stable build hash. Read at configure time, so
/// a new file invalidates the cache.
fn listZigSources(b: *std.Build, sub_path: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    collectZigSources(b, &names, sub_path, "");
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);
    return names.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Append every `.zig` file under `dir_path` to `names`, naming each by its
/// path relative to the directory the walk started in.
fn collectZigSources(
    b: *std.Build,
    names: *std.ArrayList([]const u8),
    dir_path: []const u8,
    prefix: []const u8,
) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch std.debug.panic("unable to iterate {s}", .{dir_path})) |entry| {
        // Joined with a forward slash rather than the host separator, so the
        // listing matches `covered_sources` on Windows too.
        const relative = if (prefix.len == 0)
            b.dupe(entry.name)
        else
            b.fmt("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) {
                names.append(b.allocator, relative) catch @panic("OOM");
            },
            .directory => collectZigSources(
                b,
                names,
                b.pathJoin(&.{ dir_path, entry.name }),
                relative,
            ),
            else => {},
        }
    }
}

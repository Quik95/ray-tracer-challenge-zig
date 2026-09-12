# The Ray Tracer Challenge — Zig

A from-scratch ray tracer in Zig, following **_The Ray Tracer Challenge: A
Test-Driven Guide to Your First 3D Renderer_ by Jamis Buck** (Pragmatic
Bookshelf, 2019). The book is language-agnostic: it specifies behaviour as
Cucumber-style scenarios and pseudocode, and the reader supplies the
implementation. This repository is that implementation.

The PDF lives on the owner's machine, outside the repo. Ask for the path if you
need to read the source material; do not commit the book or long excerpts of it.

## Working on this repo

- Zig **0.16.0**, pinned via devenv. Everything runs inside the devenv shell —
  direnv activates it automatically, otherwise prefix commands with
  `devenv shell -- `.
- `devenv test` is the full gate: `zig fmt --check`, `actionlint`, `zizmor`,
  `zig build`, `zig build test`. Run it before claiming work is done.
- `zig build run` runs the demo program; `zig build test` runs the suite.
- The `zig-0.16` skill in `.agents/skills/` covers 0.16 API specifics (the
  `std.Io` rework, `@Type` removal, `@cImport` deprecation). Consult it rather
  than guessing at APIs — 0.16 broke a lot of pre-0.15 material.

## Code guidance

- **Do not reference book chapters in comments or doc comments.** No "Chapter
  1", no "Putting It Together", no "as of Chapter 5". The code should read as a
  ray tracer, not as a reading log. Explain what a thing does and why, never
  where it came from. The sole exception is the commit subject prefix below.
- **Prefix every commit subject with the chapter the work comes from**, as
  `Chapter <n>: <Title> — <subject>`, so the history reads as progress through
  the book:

      Chapter 1: Tuples, Points, and Vectors — add tuples and the sim
      Chapter 2: Drawing on a Canvas — add colors, the canvas, PPM output

  The number and title come from the book verbatim, and the subject after the
  dash stays in the imperative mood; keep it short, since the prefix eats most
  of the line. Work that belongs to no chapter — tooling, CI, a refactor —
  takes no prefix. The body explains what changed and why, and stays free of
  chapter references like the code does.
- Tests mirror the book's scenarios, but name them after the behaviour they
  check, not the scenario number or the chapter.
- **Lean on `comptime` as much as the problem allows.** Reach for it first, not
  as a last resort: parameterize types over the float type and over each other,
  make selectors (axes, channels) `comptime` arguments so they compile down to
  a plain element access, resolve dimensions and dispatch at compile time, and
  push table and constant construction into `comptime` blocks. Generic code
  written this way should also be usable *at* `comptime` — add a test that
  exercises each new type inside a `comptime` block. The one limit is
  readability: skip `comptime` where it only adds ceremony without removing
  duplication or runtime work. The tuple, color, and canvas types are
  parameterized this way, and matrices should follow.
- Favour Zig's SIMD (`@Vector`, `@reduce`, `@shuffle`) for the small fixed-size
  numeric types; the renderer is numeric code in a hot loop.
- Keep comment density as it is: explain the non-obvious (why `w` exists, why
  the cross product shuffle works), skip narrating the obvious.

## Layout

- `src/root.zig` — library root; imports every module explicitly so its tests
  run, and keeps `covered_sources` in sync with `src/` on disk.
- `src/main.zig` — the executable's root, its own module.
- `src/math/` — tuples, matrices, and the transformations built from them.
- `src/scene/` — what a ray is and what it meets: rays, shapes and their
  geometries, intersections, and the reader that builds a world out of a
  scene file.
- `src/render/` — colors and the canvas they are written to.
- `src/demo/` — the scenes `src/main.zig` draws.
- `scenes/` — example scene files, in the text format `src/scene/yaml.zig`
  parses and `src/scene/description.zig` turns into a world and a camera.
- `models/` — the meshes the demo reads: OBJ files the library embeds, and
  the awk script that gave them vertex normals.
- `build.zig` — build graph; `listZigSources` walks `src/` recursively and
  feeds `src/root.zig` the real listing so a new, unimported file fails the
  suite.
- **Adding a file under `src/` means importing it in `src/root.zig` and adding
  its path, relative to `src/`, to `covered_sources`.** Zig 0.16 removed
  `refAllDeclsRecursive`; an unreferenced import is silently never analyzed, so
  its tests never run.
- Modules import their neighbours by relative path (`../math/tuple.zig`); only
  `src/main.zig` goes through the package name.

## Skills

Source of truth is `.agents/skills/`; `.claude/skills/` holds relative symlinks
into it. Install with the skills.sh CLI, available as `skills` in the devenv
shell:

    skills add <owner>/<repo>@<skill> --agent claude-code

`skills-lock.json` pins what is installed. After an install, move the skill into
`.agents/skills/` and symlink it back if the CLI drops it under `.claude/`.

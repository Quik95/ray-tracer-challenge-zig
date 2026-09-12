# Models

Three meshes the demo renders, as Wavefront OBJ. Each is the mesh as its source
publishes it, run through `normals.awk` to add a vertex normal at every corner
so the tracer can shade the surface smooth rather than facet by facet. Nothing
else is changed: the coordinates are the originals, and the scene sizes and
places each model from the box it measures around it.

| File | Mesh | Triangles | Source |
| --- | --- | --- | --- |
| `teapot.obj` | The Utah teapot, Martin Newell, 1975 | 6320 | [common-3d-test-models](https://github.com/alecjacobson/common-3d-test-models) |
| `suzanne.obj` | Suzanne, the Blender mascot | 968 | [common-3d-test-models](https://github.com/alecjacobson/common-3d-test-models) |
| `spot.obj` | Spot, Keenan Crane | 5856 | [common-3d-test-models](https://github.com/alecjacobson/common-3d-test-models) |

Suzanne is from the Blender distribution and is in the public domain; Spot is
published by its author under CC0. The teapot is the oldest test model there
is, and has been passed around freely since it was digitised.

Regenerate a file's normals with:

    gawk -v NAME=<name> -f models/normals.awk <original>.obj > models/<name>.obj

# S³ demo architecture

## Inventory

| Path | What it is | State |
| --- | --- | --- |
| `src/geometry/spherical_game.zig` | Shared `Cl(4,0)` S³ kernels | Canonical |
| `src/demos/spherical_game/scene.zig` | Backend-free S³ scene and exact tracer oracle | Canonical |
| `src/demos/spherical_game/object_scene.zig` | Data-defined S³ half-space scene format | Canonical |
| `tools/spherical_mesh.zig` | Backend-free half-space mesh construction | Shared renderer/test implementation |
| `tools/shader_playground.zig` | Vulkan/GLFW S³ renderer | Canonical graphical demo |
| `src/demos/worlds/` | Four-space frontend, camera uploads, and tracer checks | Shared Vulkan renderer |

The old raylib/OpenGL S³ frontend and its handwritten GLSL math were removed.
`demo-spherical` now runs the Vulkan renderer. There is one graphical S³
implementation, authored in Zig against zmath and compiled to SPIR-V. Both
`demo-spherical` and the spherical mode in `demo-worlds` use it.

## Geometry

S³ is the unit sphere in `Cl(4,0)`. Spatial data uses zmath `Point`,
`Direction`, and `Rotor` carriers:

- Player movement and camera orientation are rotor sandwiches.
- The ground is the equatorial great 2-sphere at `w = 0`.
- The cube, fence planks, and rails are intersections of great-sphere
  half-spaces.
- Rays follow `p(a) = cos(a) origin + sin(a) direction`.
- Great-sphere intersections return cosine/sine angle pairs, avoiding
  unnecessary inverse trigonometry in the renderer.

`scene.zig` retains an exact CPU first-hit tracer. It is the geometry oracle and
test reference, not the graphical rendering path.

The data-defined scene boundary rejects non-finite radii, material values, face
normals, and bounds. Face normals and bound centers must be unit length; bound
cosines must lie in `[-1, 1]`; transforms must satisfy the complete rotor identity.
These checks happen during file validation, not in every geometry operation.

## Checkout and package boundary

Demos and asset-dependent checks require a repository checkout and execution
from its root. The published Zig package intentionally excludes `assets` and
the Nix flake; it advertises library modules, not runnable graphical tools.
Relative `assets/spherical/world.s3obj.json` and `zig-out/shaders` paths are part
of this checkout-only tooling contract. Built executables are not standalone
installations. Fetching the library does not require a window or GPU.

## Vulkan renderer

`tools/shader_playground.zig` creates the S³ mesh once from
`assets/spherical/world.s3obj.json` through `tools/spherical_mesh.zig`:

1. Face vertices come from the GA null-vector construction
   `a ^ b ^ c` followed by the Hodge dual.
2. Great-sphere faces are subdivided on S³.
3. Vertices are deduplicated only when point, color, and face plane match.
4. Vertex and index buffers are uploaded once into device-local memory.

The mesher supports vertex-bounded objects with four to six faces, including
tetrahedra and triangular prisms. The scene format also accepts other half-space
sets, but hemispheres, lunes, and vertex-degenerate geometry require a different
meshing algorithm. These return `UnsupportedMeshGeometry` rather than disappear
silently; failure of any object rejects the complete mesh.

The current scene has 387,072 triangles, 206,010 persistent vertices, and
1,161,216 indices.

Every swapchain image owns a small `FrameGpu` uniform slice and descriptor set.
Camera movement waits only for the acquired image, updates that slice, and
submits a recorded command buffer. It does not reproject mesh vertices on the
CPU, rewrite device-local meshes, wait for all frames, or rerecord commands.

### Shader boundary

`src/shaders/spherical_ga.zig` is the ABI adapter:

- Raw `@Vector` values are restricted to vertex attributes, shader UBO fields,
  colors, and SPIR-V built-ins. Native frame and vertex upload records retain
  GA carriers for geometric fields and arrays for viewport and color data.
  Compile-time checks enforce the existing upload sizes and field offsets.
- Attributes and frame data convert immediately to zmath S³ vectors.
- Shared projection, screen-direction, and great-sphere-intersection kernels
  come from `geometry.spherical_game`.

The mesh vertex shader projects the initial tangent from camera origin to S³
point into homogeneous stereographic clip coordinates. The denominator remains
in `clip_w`, so hardware clipping happens before perspective division. A
near-pole guard collapses invalid chart vertices to the homogeneous origin,
degenerating unsafe primitives instead of letting them cover the frame.

The mesh fragment shader reconstructs the ray direction and uses its interpolated
great-sphere plane to write analytic S³ depth, subject to floating-point
roundoff and only where mesh primitives rasterize. Ground and mesh shaders
both retain the unit-disc viewport mask. Window dimensions come from the live swapchain
extent, so the spherical screen fills the current framebuffer.

## Tests and checks

- `zig build test`: GA, scene, object-format, headless mesh, and renderer-support
  tests. Mesh regressions check bounded tetrahedra/prisms, explicit unsupported
  geometry errors, allocation cleanup, and the canonical asset's triangle count.
- `zig build demo-spherical-check`: S³ scene geometry tests only.
- `zig build spirv-spherical`: Zig-authored spherical SPIR-V modules, validated
  against Vulkan 1.2 before installation.
- `spirv-val --target-env vulkan1.2 zig-out/shaders/spherical_*.spv`:
  Vulkan module validation.
- `zig build spirv-check`: direct carrier interface load/store/member-access
  regression checks.
- `zig build demo-spherical -- --benchmark N`: Vulkan renderer benchmark.

Headless CI runs Debug/fast native tests and expression smoke in parallel, plus
an independent SPIR-V validation and graphics executable build job. The aggregate
`test` check requires all verification jobs to succeed. No GPU session is required.

The CPU tracer remains deliberately richer than the raster path. Headless
checks cover selected scene geometry and occlusion cases, plus sampled mesh
coverage/depth. They do not establish exhaustive CPU/GPU parity or full-image
raster coverage.

## `demo-worlds`

The worlds executable is a thin entry point into the same Vulkan/GLFW frontend.
Its spherical mode uses the same JSON world, persistent vertex/index buffers,
and ground/mesh shader pipelines as `demo-spherical`. The CPU S³ tracer is only
an oracle for headless checks, never the graphical path.

Euclidean and isometric slab tracing and hyperbolic Klein tracing run in
`src/shaders/worlds.frag.zig`. The shader reuses the backend-free kernels in
`src/demos/worlds/space.zig`; camera packing and shading live in `render.zig`.
Hyperbolic inverse sinh uses the native SPIR-V GLSL extended instruction,
while CPU checks retain `std.math.asinh`.

Worlds frame uploads append a 16-byte projection record to the canonical
80-byte spherical frame prefix. Camera uniforms and presentation-wait semaphores
remain per-swapchain-image; acquire semaphores and submission fences use frame
slots. The render-pass dependency orders reuse of the shared depth attachment.
Switching worlds selects precreated pipelines and rerecords commands only on
the switch; moving the camera does not rebuild or upload meshes. Resize rebuilds
swapchain resources for the active mode.

Keys 1–4 (including keypad keys), Tab, and the GPU-rendered mouse selectors
switch worlds. W/S/A/D, arrows, and R retain movement, look, and reset controls;
isometric mode uses Q/E and the scroll wheel. World names and hints appear in
the window title. The former per-frame CPU-traced statistics HUD is removed.

`zig build demo-worlds -- --world spherical --benchmark 300` selects a mode and
runs a frame benchmark. `ZMATH_DEMO_WORLD`, `ZMATH_DEMO_FRAMES`, and the capture
variables `ZMATH_DEMO_CAPTURE`, `ZMATH_DEMO_WALK`, and `ZMATH_DEMO_PITCH` remain
available. PNG capture reads back the rendered swapchain image, not a CPU tracer
frame. `--pose WALK YAW PITCH` overrides the capture pose. Both frontends support
`ZMATH_DEMO_CAPTURE` for same-pose rendering comparisons. Capture bytes retain
the actual swapchain encoding: PNG metadata marks sRGB formats with `sRGB`,
and linear UNORM formats with file gamma 1.

### Maintained framebuffer parity check

From the checkout root:

```sh
nix develop .#ci -c zig build demo-worlds-parity-check -Doptimize=fast
nix develop -c zig build demo-worlds-parity -Doptimize=debug
nix develop -c zig build demo-worlds-parity -Doptimize=fast
```

The first command builds the native reference and tests PNG integrity/color
encoding and an injected pixel mismatch without opening a window; CI includes
it in the shader/build job. The latter commands require a working graphical
session and Vulkan driver. Failures are reported, not silently skipped.

Each GPU run captures Euclidean, isometric, and hyperbolic worlds at two fixed
poses, comparing 81 pixel centers per capture with native f32 reference values.
The comparator applies the capture's linear/sRGB transfer function and permits
at most one RGB byte of difference. Every mode must exercise cube and ground
hits across the sampled poses; selectors are identified separately.

The reference reuses shared shading mathematics, so this detects execution,
frame packing, and presentation drift, not independent mathematical correctness.
Spherical rendering is deliberately excluded: tracer/raster coverage agreement
is a separate measured boundary, not established by these sampled checks.
Captures are temporary and removed after the run.

### Host graphics compatibility

The flake pins the build compiler and user-space dependencies, not the host
Vulkan ICD, Mesa/LLVM, compositor, or their loaded library versions. A supported
Vulkan 1.2 driver can still fail to load when the process mixes incompatible
library generations.

A known NixOS failure combines GLFW-transitive glibc 2.42 libm with host
Mesa/LLVM requiring `GLIBC_2.44`. An older compositor session can outlive a
system update. A Debug run succeeding does not establish fast-mode compatibility:
library load order differs. After a graphics/system update, retest from a fresh
login/compositor session before changing dependency pins. Do not add global
`LD_PRELOAD` overrides; a process-local preload is diagnostic evidence only.

For loader diagnostics, set `VK_LOADER_DEBUG=error,warn` for the demo process
and inspect missing symbol/version messages. In a fresh session, the fast parity
command above must run without an ad hoc preload. If it still fails, compare
host-driver and project dependency closures before choosing an alignment fix.

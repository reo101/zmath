# S³ demo architecture

## Inventory

| Path | What it is | State |
| --- | --- | --- |
| `src/geometry/spherical_game.zig` | Shared `Cl(4,0)` S³ kernels | Canonical |
| `src/demos/spherical_game/scene.zig` | Backend-free S³ scene and exact tracer oracle | Canonical |
| `src/demos/spherical_game/object_scene.zig` | Data-defined S³ half-space scene format | Canonical |
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

## Vulkan renderer

`tools/shader_playground.zig` creates the S³ mesh once from
`assets/spherical/world.s3obj.json`:

1. Face vertices come from the GA null-vector construction
   `a ^ b ^ c` followed by the Hodge dual.
2. Great-sphere faces are subdivided on S³.
3. Vertices are deduplicated only when point, color, and face plane match.
4. Vertex and index buffers are uploaded once into device-local memory.

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
great-sphere plane to write exact S³ depth. Ground and mesh shaders both retain
the unit-disc viewport mask. Window dimensions come from the live swapchain
extent, so the spherical screen fills the current framebuffer.

## Tests and checks

- `zig build test`: GA, scene, object-format, and renderer-support tests.
- `zig build demo-spherical-check`: S³ scene geometry tests only.
- `zig build spirv-spherical`: Zig-authored spherical SPIR-V modules, validated
  against Vulkan 1.2 before installation.
- `spirv-val --target-env vulkan1.2 zig-out/shaders/spherical_*.spv`:
  Vulkan module validation.
- `zig build spirv-check`: direct carrier interface load/store/member-access
  regression checks.
- `zig build demo-spherical -- --benchmark N`: Vulkan renderer benchmark.

The CPU tracer remains deliberately richer than the raster path. It validates
scene geometry and occlusion; the renderer validates mesh coverage and exact
fragment depth over representative camera poses.

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
`ZMATH_DEMO_CAPTURE` for same-pose rendering comparisons.

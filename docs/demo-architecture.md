# Demo architecture and test strategy

Status after the spherical-game rebuild. History, current logic, what is
tested without human input, and what comes next.

## Inventory

| Path | What it is | State |
| --- | --- | --- |
| `src/demos/spherical_game/` | Canonical graphical demo: S³ scene core + raylib frontend | Active |
| `src/demos/core.zig` | Terminal demo (ASCII curved-space walker) | Active, tested |
| `src/demos/main.zig` | Terminal demo entrypoint (`zig build demo`) | Active |
| `src/demos/raylib_demo/`, `src/demos/raylib_main.zig` | Old four-mode raylib app (perspective/isometric/spherical/hyperbolic) | Abandoned, not built |
| `tools/shader_playground.zig` | Vulkan/GLFW SPIR-V playground | Opt-in |
| `tools/profile/*` | CPU probes for curved walk/projection pathologies | Opt-in, not wired |

The old raylib app was unwired for a long time and its shader-resource path
was half-refactored (empty `RenderResources`, shader uniforms with no owner).
It was consciously dropped in favor of a single S³ demo per the Hyperbolica
reference direction. Harvest its ideas, not its code.

## Spherical-game demo

### Geometry model

- Space is true **S³**: unit vectors in `Cl(4,0)` (`geometry.spherical_game`).
- The ground is a convention, not a metric: the equatorial **S²** at
  `w = 0` (`groundPoint`). The renderer still traces full S³, so the far
  hemisphere is visible through the wrap.
- The reference (CodeParade/Hyperbolica) renders **H³/S³ directly**; the
  `H² × R` / `S² × R` product spaces are *physics* simplifications they
  adopted separately (devlog #4). Our ground convention mirrors that spirit
  without lying in the math.

### Scene core (`scene.zig`), backend-free

- `GroundPose`: position on the equator + `right`/`forward` + eye height.
  Movement is a GA rotor between position and the movement axis (`sg.Pose`
  machinery); looking is rotor composition plus a clamped pitch angle.
- `Pose.camera()`: lifts the ground frame to eye height and applies pitch,
  giving an orthonormal GA frame `(position, right, up, forward)`.
- `Cube`: six faces parameterized intrinsically over a tangent frame lifted
  half a cube side off the ground; `surfacePoint(face, u, v)` geodesically
  projects tangent offsets onto S³. Face edges are shared exactly.
- `Scene.projectWithCamera`: S³ gnomonic-style projection. For a world point
  `p` and camera frame: `x = p·right`, `y = p·up`, `z = p·forward`,
  screen = `x/(z·aspect·tan(fov/2))`, `y/(z·tan(fov/2))`. **Both signs of
  `z` are kept**, split into `near`/`far` branches (devlog #4's two-pass
  stereographic equivalent, one pass here).
- `reverse_depth`: triangles whose geodesic distance exceeds `πR/2` need
  inverted depth ordering — the far hemisphere is seen "inside out".

### Frontend (`main.zig`), raylib-only

- C raylib via `@cImport`; no raylib-zig dependency.
- Static cube mesh built once, projected per frame, painter-sorted with
  `drawBefore` (far branch last, ascending distance within it).
- Ground = two families of geodesic grid lines on the equator S².
- Capture mode: `ZMATH_DEMO_CAPTURE=path.png` renders one hidden-window
  frame at the showcase checkpoint and exits. Optional `ZMATH_DEMO_WALK`
  (units before the antipode) and `ZMATH_DEMO_PITCH` (radians) overrides
  for sweeps.

### The reverse-perspective frame

Walking backward from the cube, the view evolves:

1. Near: ordinary perspective, only the front face.
2. Approaching the conjugate/antipode side: all five exposed faces grow;
   near the exact antipode the front face swaps branch and the cube reads
   "inside out" (roof above, walls around, far wall enormous).
3. Non-monotonic truth: closer is not always "more visible". The roof can
   expand past the viewport, and the far wall can occlude it. The locked
   showcase frame (1.0 before the antipode, pitch −0.4) keeps all five
   face colors visible simultaneously — verified by palette measurement,
   not vibes.

## Testing without user input

Layered, cheapest first:

1. **Geometry invariants** (`spherical_game` + `scene.zig` unit tests,
   `zig build test`): orthonormal GA frames after movement; cube samples on
   the sphere; shared face edges; five-face far-side projection with no
   ground face; finite output across a full walk through both branches.
2. **Headless smoke step** (`zig build demo-spherical-check`): runs the
   scene tests alone; wired as a fast CI-able gate.
3. **Rendered smoke capture**: hidden-window Xvfb render + `TakeScreenshot`,
   then an ImageMagick histogram check that all five face colors survive
   final painter occlusion. This is the check that caught the original
   near-first painter ordering burying the far face — projection tests
   alone were green while the image was wrong.
4. **Parameter sweeps**: env-driven walk/pitch capture grid used once to
   locate the showcase frame; rerun when the scene or renderer changes.

Known painter limitation: triangle-level distance sorting is correct
per-ray at triangle granularity but cannot resolve intersections inside a
triangle. The reference engine fixes this with a real two-pass depth
buffer (near pass `0–0.5`, far pass `0.5–1.0` reversed). That is the next
structural upgrade, needed before dense scenes.

## Next steps

1. **Two-pass depth renderer**: near pass then far pass with reversed depth
   (z-buffer instead of painter sort). Unblocks non-convex scenes.
2. **GPU path**: the CPU projection math maps 1:1 to a vertex shader
   (two draws, uniform branch flag); reuse `build_spirv.zig` plumbing.
3. **Gameplay physics**: constrain to the S² ground for walking (matching
   the reference's product-space compromise) while keeping full-S³
   rendering; add jump/gravity on the S².
4. **Golden images**: commit the showcase capture; diff in CI with a small
   tolerance instead of palette-only checks.
5. **Terminal demo**: revive/trim `src/demos/core.zig` modes once the
   raylib path stabilizes; its walk/reversibility tests are already the
   model for curved-camera testing.
6. **Cleanup**: delete or re-wire `tools/profile/*` as build steps; decide
   the fate of `src/demos/raylib_demo/` (delete when nothing is left to
   harvest).

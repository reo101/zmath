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
- `Cube`: the exact spherical cube — intersection of six hemispheres whose
  boundary great spheres sit `half_extent` from the center. No mesh, no
  tessellation. The demo cube is 4.4 units on an R=6 world, so its
  conjugate-region image can dominate the sky.
- `Tracer`: per-frame first-hit ray tracer over the full view sphere.
  Along a geodesic `p(a) = cos(a)·origin + sin(a)·dir`, plane i is crossed
  at `r_i ± pi/2` with `r_i = atan2(dir·n_i, origin·n_i)`; the cube interior
  along the ray is the arc intersection
  `(max r_i - pi/2, min r_i + pi/2)`, so the entry/exit faces and angles are
  exact with zero iteration. Ground = first crossing of the equatorial
  great sphere. Occlusion is exact by construction.
- `Scene.frameDirection`: stereographic wide-FOV frame (150° by default).
  Conformal, maps circles to circles, and keeps the conjugate-region image
  continuous across the frame — the same projection family the reference
  engine uses for spherical space (devlog #4). `Tracer` itself stays a
  pure per-direction tracer.
- `fastAtan2`: polynomial approximation (~1e-5 rad, pinned by test); the
  per-pixel cost is a handful of SIMD dots plus ~7 atan2 calls.

### Frontend (`main.zig`), raylib-only

- C raylib via `@cImport`; no raylib-zig dependency.
- CPU ray-traced 960x540 RGBA buffer uploaded to a texture each frame and
  drawn letterboxed. The demo executable is forced to ReleaseFast.
- Ground shading = checker in ground arc coordinates; cube faces = flat
  color with headlight lambert and mild distance dimming.
- Capture mode: `ZMATH_DEMO_CAPTURE=path.png` renders one hidden-window
  frame and exits. `ZMATH_DEMO_WALK` is the absolute walk distance
  (default = the showcase frame), `ZMATH_DEMO_PITCH` the pitch in radians,
  `ZMATH_DEMO_FRAMES` caps the frame count for headless perf timing.

### The reverse-perspective frame

Walking backward from the cube:

1. Near: ordinary wide-angle view, only the front face.
2. Quarter-turn away: apparent size *dips* (spherical geometry is not
   Euclidean-monotonic).
3. Near the cube's antipodal region the wrapped image explodes. The cube's
   image **owns the entire zenith cap** — every upward ray's great circle
   passes through the cube — and releases it only at the horizon band
   ("all rays eventually hit the ground").
4. The showcase frame: walk to 0.15 before the cube's ground-point
   antipode and pitch up ~80°. The **roof centers overhead** (its ground
   point is nearly antipodal, so it sits almost straight up), the four
   walls splay outward to the frame edges, and ~81% of the frame is cube.
   Walking either direction from there closes the distance and cycles the
   faces behind the roof.
5. The bottom face is never a first hit from above ground — asserted for
   the whole walk.

## Testing without user input

Layered, cheapest first:

1. **Geometry invariants** (`spherical_game` + `scene.zig` unit tests,
   `zig build test`): orthonormal GA frames after movement; cube plane
   edges shared exactly (arc `atan(sqrt(2)·tan(h/R))`); forward ray hits
   the front face on-plane; straight-up rays hit wrapped ground at
   `pi*R - eye_height` ("no sky"); the cube image owns the zenith cap in
   every azimuth and releases it at the horizon; the pitched showcase
   frame centers the roof, shows all five faces with zero bottom hits and
   >80% cube coverage; walking either way from the showcase approaches
   the cube; `fastAtan2` bounded against `std.math.atan2`.
2. **Headless smoke step** (`zig build demo-spherical-check`): runs the
   scene tests alone; wired as a fast CI-able gate.
3. **Rendered smoke capture**: hidden-window Xvfb render + `TakeScreenshot`,
   then an ImageMagick histogram check that all five face colors survive
   in the final composited frame.
4. **Parameter sweeps**: env-driven walk/pitch capture grid used to locate
   the showcase frame; rerun when the scene or renderer changes.

The first-hit tracer eliminated the entire artifact class of the previous
painter-sorted two-branch projection (branch tears + far/near overlap
"self-intersection") by construction.

## Next steps

1. **GPU port**: the tracer maps 1:1 to a fragment shader (fullscreen quad,
   same per-pixel math, uniforms for the camera frame and cube planes);
   reuse `build_spirv.zig` plumbing. The CPU path becomes the reference
   oracle for shader output.
2. **Gameplay physics**: constrain to the S² ground for walking (matching
   the reference's product-space compromise) while keeping full-S³
   rendering; add jump/gravity on the S².
3. **Golden images**: commit the showcase capture; diff in CI with a small
   tolerance instead of palette-only checks.
4. **Scene content**: more objects (the tracer costs ~O(planes) per
   pixel — a BVH over object planes/spheres keeps headroom).
5. **Terminal demo**: revive/trim `src/demos/core.zig` modes once the
   raylib path stabilizes; its walk/reversibility tests are already the
   model for curved-camera testing.
6. **Cleanup**: delete or re-wire `tools/profile/*` as build steps; decide
   the fate of `src/demos/raylib_demo/` (delete when nothing is left to
   harvest).

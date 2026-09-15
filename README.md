# zmath

`zmath` is a Zig library for compile-time-specialized Geometric Algebra / Clifford Algebra.

The core idea: describe the algebra in the type system, keep multivectors sparse, and let `comptime` erase as much abstraction as possible.

## Install

```sh
zig fetch --save <repo-url>
```

Then in your `build.zig`:

```zig
const zmath = b.dependency("zmath", .{ .target = target }).module("zmath");

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmath", .module = zmath }},
    }),
});
```

## Quick example

```zig
const std = @import("std");
const zmath = @import("zmath");

const Cl3 = zmath.ga.Algebra(.euclidean(3)).Instantiate(f32);

pub fn main() void {
    const v = Cl3.Vector.init(.{ 1, 2, 3 });
    const result = Cl3.expr("{v} ^ e12 + 5", .{ .v = v });
    std.debug.print("{}\n", .{result});
}
```

## Main surfaces

- `zmath.ga`: algebra factory, sparse multivectors, products, duals, rotors,
  RGA interior products/projections (`ga.rga`), and the comptime expression
  compiler. `ga.Algebra(sig)` is the entry point; see below.
- `zmath.geometry`: constant-curvature and spherical-game geometry kernels.
- `zmath.parse`: comptime expression parser (implementation detail of `ga`).

## Making an algebra

`ga.Algebra(sig)` bakes a `Cl(p, q, r)` signature into a namespace of
comptime-specialized types:

```zig
const Cl3 = zmath.ga.Algebra(.euclidean(3)).Instantiate(f32);
// Cl3.Vector, Cl3.Rotor, Cl3.KVector(2), Cl3.Basis, Cl3.expr, ...
```

Signatures are plain values: `.euclidean(n)`, or explicit `.{ .p = 3, .q = 1 }`
for mixed metrics (the library itself uses `Cl(3,1)` for hyperbolic space and
`Cl(4,0)` for S³). Non-default basis naming (projective `e0` axes, custom
names) is configured with
`ga.AlgebraWithNamingOptions(sig, ga.blade_parsing.SignedBladeNamingOptions)`
— see the naming test in `src/ga.zig` for the pattern.

## Conventions

- Prefer `complementDual()` for the metric-independent Poincaré dual.
- `dual()` is only a short alias for `complementDual()`.
- Use `hodgeDual()` for the metric-aware dual on non-degenerate metrics.

See `docs/ga-conventions.md` for the product, duality, and expression
conventions.

## Demos

The S³ walker is a Vulkan raster renderer: a spherical cube,
conjugate-region reverse perspective, and a great-circle picket fence.
Its S³ geometry is authored once in Zig with `Cl(4,0)` zmath kernels.

`demo-worlds` is a separate raylib executable with four live-switchable
spaces (euclidean / isometric / spherical / hyperbolic). The hyperbolic
world walks the hyperboloid on GA carriers with Beltrami-Klein projection.

Both scene cores are pinned by headless geometry tests.

## Commands

```sh
zig build test --summary all       # suite: 140 tests across 10 binaries
zig build run                      # usage example
zig build bench-simd               # micro-benchmark (ReleaseFast)
zig build fuzz-expr                # expression parser/evaluator smoke fuzz
zig build fuzz-ga                  # GA algebra-law property tests (Smith-driven)
zig build demo-spherical-build     # build the Vulkan S3 spherical-game demo
zig build demo-spherical           # run the Vulkan S3 spherical-game demo
zig build demo-spherical-check     # headless S3 demo geometry checks
zig build demo-worlds-build        # build the raylib worlds demo (4 spaces)
zig build demo-worlds              # run the worlds demo (keys 1-4 switch)
zig build demo-worlds-check        # headless worlds geometry checks
zig build spirv-vga                # build VGA-based SPIR-V shaders
zig build spirv-raw                # build raw SPIR-V shader baseline
zig build spirv-compare            # compare GA vs raw SPIR-V shader size
zig build spirv-spherical           # build Zig-authored S3 ground shaders
zig build shader-playground-build  # build local Vulkan/GLFW shader playground
zig build shader-playground        # run playground with raw shaders
zig build shader-playground-ga     # run playground with GA shaders
zig build shader-playground-spherical # run the Vulkan S3 renderer
```

The Vulkan demo and shader playground are the same renderer. Run it from the
Nix devshell so Vulkan/GLFW and `spirv-opt` are available. It uses W/S to walk,
A/D to strafe, arrows to look, R to reset, and Esc to quit.

## License

MIT. See `LICENSE`.

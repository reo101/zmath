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

- `zmath.ga`: generic algebra factory, multivectors, products, duals, expression compiler.
- `zmath.flavours`: convenience facades for VGA, PGA, CGA, STA, EPGA, HPGA.
- `zmath.geometry`: constant-curvature and spherical-game geometry helpers.
- `zmath.render`: small software-render/projection helpers used by the demos.

## GA flavour comparison

| Flavour | Signature | Main use |
| --- | --- | --- |
| VGA | `Cl(n, 0, 0)` | Euclidean vector math |
| PGA | `Cl(n, 0, 1)` | Euclidean rigid motion |
| CGA | `Cl(n+1, 1, 0)` | spheres, circles, conformal transforms |
| STA | `Cl(1, 3, 0)` | relativistic spacetime |

## Conventions

- Prefer `complementDual()` for the metric-independent Poincaré dual.
- `dual()` is only a short alias for `complementDual()`.
- Use `hodgeDual()` for the metric-aware dual on non-degenerate metrics.
- PGA/RGA-style bulk and weight duals live under `zmath.flavours.pga`.

See `docs/ga-conventions.md` for the product, duality, expression, and PGA
representation conventions.

## Commands

```sh
zig build test --summary all   # current suite: 168 tests
zig build run                  # usage example
zig build demo                 # terminal demo
zig build bench-simd           # micro-benchmark
zig build fuzz-expr            # expression parser/evaluator smoke fuzz
zig build spirv-vga            # local SPIR-V shader build
zig build shader-playground    # local Vulkan/GLFW shader playground
zig build spherical-game-raylib-build # build local raylib S3 GA demo
zig build spherical-game-raylib       # run local raylib S3 GA demo
```

The shader playground and raylib S3 demo are opt-in; run them from the Nix
devshell so Vulkan/GLFW/raylib and `spirv-opt` are on the include/library
paths.

## License

MIT. See `LICENSE`.

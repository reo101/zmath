# zmath

[![CI](https://github.com/reo101/zmath/actions/workflows/ci.yml/badge.svg)](https://github.com/reo101/zmath/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[zmath](https://github.com/reo101/zmath) is a Zig library for
compile-time-specialized geometric algebra and Clifford algebra.

Describe an algebra in the type system, keep its multivectors sparse, and let
`comptime` erase the generic machinery. The result is type-directed products
and carriers without paying for the whole algebra when an operation cannot
produce it.

## Requirements

Zig 0.17.0 or newer. `nix develop` provides the pinned compiler and a
0.17-compatible ZLS development revision.

## Install

Fetch the repository. Zig resolves the default branch and records the resulting
commit and content hash in the consuming project's `build.zig.zon`.

```sh
zig fetch --save git+https://github.com/reo101/zmath
```

Import its `zmath` module from `build.zig`:

```zig
const zmath = b.dependency("zmath", .{
    .target = target,
    .optimize = optimize,
}).module("zmath");

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

## Quick start

```zig
const std = @import("std");
const zmath = @import("zmath");

const Cl3 = zmath.ga.Algebra(.euclidean(3)).Instantiate(f32);

pub fn main() void {
    const vector = Cl3.Vector.init(.{ 1, 2, 3 });
    const result = Cl3.expr("{vector} ^ e12 + 5", .{ .vector = vector });
    std.debug.print("{}\n", .{result});
}
```

`ga.Algebra(signature)` produces an algebra factory. `Instantiate(T)` binds a
coefficient type and exposes sparse carriers such as `Vector`, `Bivector`,
`Rotor`, `Even`, `KVector(n)`, and `Full`, plus product and expression helpers.

```zig
const Cl31 = zmath.ga.Algebra(.{ .p = 3, .q = 1 }).Instantiate(f64);
const scalar = Cl31.Scalar.init(.{1});
const e1 = Cl31.basisVector(1);
const product = e1.gp(e1);
_ = scalar;
_ = product;
```

Signatures can use `.euclidean(n)` or explicit `.{ .p, .q, .r }` values for
`Cl(p, q, r)`. For custom basis names, including a projective `e0` axis, use
`ga.AlgebraWithNamingOptions`. The tested pattern lives in
[`src/ga.zig`](src/ga.zig).

## Surfaces

- `zmath.ga`: algebra factories, sparse multivectors, products, duals, rotors,
  RGA operations, PGA helpers, and the comptime expression compiler.
- `zmath.ga.pga`: semantic `Cl(3,0,1)` helpers. `pga.extend(Base)` adds planes,
  points, lines, motors, direct motor composition, and prepared point/direction
  transforms while retaining the sparse base carriers.
- `zmath.geometry`: constant-curvature, spherical-game, and hyperbolic geometry
  kernels.
- `zmath.parse`: the expression parser used by `ga`.

### PGA example

```zig
const std = @import("std");
const zmath = @import("zmath");

const RawP3 = zmath.ga.Algebra(.{ .p = 3, .q = 0, .r = 1 }).Instantiate(f32);
const P3 = zmath.ga.pga.extend(RawP3);

pub fn main() !void {
    const motor = P3.compose(
        P3.translator(.{ 1, 0, 0 }),
        try P3.rotation(.{ 0, 0, 1 }, std.math.pi / 2),
    );
    const transformed = P3.transformPoint(P3.point(.{ 1, 0, 0 }), motor);
    _ = transformed;
}
```

Use `P3.prepare(motor)` when applying one motor to a batch of points or
directions.

## Carrier storage

Carriers remain `extern struct` wrappers with coefficient arrays on all targets.
Small numeric carriers retain vector alignment and explicit `@Vector` arithmetic
at runtime; comptime operations use scalar/array paths. `Storage` and `coeffs`
are arrays on both native and SPIR-V targets. `storageView()` returns independent
raw-vector and named value snapshots, not a type-punning union.

Typed shader interfaces such as `@extern(*addrspace(.output) Vec(4), ...)`
remain supported through this project's SPIR-V build steps. The postpass repairs
Zig's `Position` decoration into a float4 interface-block member, converting
between the carrier's array and the interface vector. Every shader is checked
with `spirv-val`. This preserves the carrier wrapper, not type
identity with a raw SPIR-V vector. Direct loads, stores, and member accesses are
supported; passing the interface pointer to other functions is not covered by
the workaround.

## Conventions

- `gp()` / `geometricProduct()` is the Clifford product.
- `wedge()` / `outerProduct()` is the exterior product.
- `complementDual()` is the metric-independent Poincaré dual and is the default
  dual for degenerate projective metrics.
- `dual()` is an alias for `complementDual()`.
- `hodgeDual()` is the metric-aware dual and requires a non-degenerate metric.

See [GA conventions](docs/ga-conventions.md) for products, duality, expression
syntax, RGA operations, and the PGA model.

## Build and test

```sh
zig build test                         # all tests
zig build run                          # usage example
zig build bench-simd                   # full fast-mode micro-benchmark suite
zig build bench-simd -- vec3           # one benchmark case
zig build bench-simd -- rotate2
zig build bench-simd -- rotor3
zig build bench-simd -- pga-compose
zig build bench-simd -- pga-point
zig build fuzz-expr                    # expression parser/evaluator smoke fuzz
zig build fuzz-ga                      # GA algebra-law fuzz target
```

## Demos and shaders

The graphical tooling is optional. Run it from the Nix devshell so Vulkan,
GLFW, raylib, and `spirv-opt` are available.

```sh
zig build demo-spherical-build         # build the Vulkan S³ scene
zig build demo-spherical               # run the Vulkan S³ scene
zig build demo-spherical-check         # headless S³ geometry checks
zig build demo-worlds-build            # build the raylib four-space demo
zig build demo-worlds                  # run it, keys 1–4 switch spaces
zig build demo-worlds-check            # headless worlds checks
zig build spirv-vga                    # build GA SPIR-V shaders
zig build spirv-raw                    # build raw-SPIR-V baselines
zig build spirv-compare                # compare shader sizes
zig build spirv-check                  # validate typed vector interface operations
zig build spirv-spherical              # build Zig-authored S³ shaders
zig build shader-playground-build      # build the Vulkan shader playground
zig build shader-playground            # run raw shaders
zig build shader-playground-ga         # run GA shaders
zig build shader-playground-spherical  # run the Zig-authored S³ scene
```

## License

[MIT](LICENSE).

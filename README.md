# zmath

`zmath` is a playground for making abstract math (somewhat) computationally efficient.

The current focus is Geometric Algebra / Clifford Algebra in Zig: turning symbolic-looking operations into compact, compile-time-checked data layouts and predictable runtime code.

## What This Repo Is

This project is not trying to be a giant batteries-included math framework yet.

It is an experimentation space for:

1. Encoding algebraic structure in types.
2. Shifting work to compile time when practical.
3. Keeping runtime representations sparse and explicit.
4. Making high-level operations feel algebraic without hiding the cost model.

In short: use Zig's type system and comptime features to push abstract math closer to efficient machine-level behavior.

## Current Scope

Right now the repo implements a GA-first core with:

1. Blade masks and canonical ordering.
2. Signed blade parsing (compact, underscore, and delimited syntaxes).
3. Sparse multivector carrier types with typed operations.
4. Euclidean defaults plus signature-aware `Cl(p, q, r)` operations.
5. A specialized 2D rotor helper module.

## Layout

1. `src/ga/` is the core implementation (`blades`, `blade_parsing`, `multivector`, `rotors`, `visualizer`).
2. `src/ga.zig` is the main public GA facade.
3. `src/flavours/` contains specialized GA models:
    - `vga.zig`: Standard Vector GA (Euclidean).
    - `pga.zig`: Projective GA (Affine/Flat Euclidean).
    - `cga.zig`: Conformal GA (Spheres/Circles/Curved).
    - `sta.zig`: Spacetime Algebra (Minkowski/Relativity).
4. `src/root.zig` is the package root and exposes all modules.

## GA Flavour Comparison

| Flavour | Signature | Space | Key Benefit | Primitives |
| :--- | :--- | :--- | :--- | :--- |
| **VGA** | $Cl(n, 0, 0)$ | Flat | Simplest vector math | Vectors, Bivectors |
| **PGA** | $Cl(n, 0, 1)$ | Affine | Euclidean rigid motion | Points, Lines, Planes |
| **CGA** | $Cl(n+1, 1, 0)$ | Conformal | Spheres and circular arcs | Spheres, Circles, Points |
| **STA** | $Cl(3, 1, 0)$ | Hyperbolic | Relativistic physics | Events, Boosts, Spinors |

## Resources

### Videos
- **[Geometric Algebra for Computer Graphics (Siggraph 2019)](https://www.youtube.com/watch?v=tX4H_ctggYo)** - The definitive primer on PGA and CGA.
- **[A Swift Introduction to Geometric Algebra (Sudgylacmoe)](https://www.youtube.com/watch?v=60z_hpEAtD8)** - Very accessible overview of the mechanics.
- **[Conformal Geometric Algebra (Marc Ten Bosch)](https://www.youtube.com/watch?v=0i3o_Zuney4)** - Great visualization of CGA transformations.

## Design Direction

The architecture is intentionally GA/Clifford-first. VGA naming exists as a convenience alias, not as the conceptual core.

The API tries to stay clean and non-leaky by default: expose useful algebraic surfaces publicly, keep implementation detail internal, and avoid accumulating compatibility cruft while the project is still unreleased.

## Running

1. Run tests: `zig build test --summary all`
2. Run demo: `zig build run`
3. Run SIMD benchmark (`ReleaseFast`): `zig build bench-simd`

## Why "Somewhat" Efficient?

Because this repo treats performance as a design constraint, not dogma.

Some abstractions become very efficient with compile-time specialization; some do not. The point of the playground is to iterate on those tradeoffs in a transparent way, measure behavior, and evolve toward a robust computational algebra toolkit.

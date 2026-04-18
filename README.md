# zmath

`zmath` is a playground for making abstract math computationally efficient using Zig's comptime powers.

The current focus is **Geometric Algebra (GA) / Clifford Algebra**: turning symbolic operations into compact, compile-time-specialized data layouts and predictable runtime code.

## Core Mandates

1.  **Algebra as Data:** Encoding complex geometric structures (Metric Signatures, Blade Masks) directly into the type system.
2.  **Comptime-First:** Shifting expensive parsing, resource estimation, and code generation to compile time.
3.  **Sparse Representations:** Multivectors only store the blades they actually use, minimizing memory footprint and SIMD lane waste.
4.  **Mathematical Intent:** High-level algebraic operations (Geometric Product, Wedge, Dual) without hiding the underlying cost model.

## Recent Architectural Shifts

Over the last 70+ commits, `zmath` has evolved from a collection of hard-coded algebras into a **Modular Algebra Factory**:

### 1. The "Families" Revolution
Instead of manual signatures, use high-level builders that automatically manage extra basis vectors:
- **`ga.family.projectiveEuclidean(N)`**: Adds the degenerate $e_0$ for rigid body motion.
- **`ga.family.conformalEuclidean(N)`**: Adds the null-pair ($n_o, n_\infty$) for spherical/circular geometry.
- **`ga.family.minkowski(1, 3)`**: Creates relativistic spacetime.

### 2. Comptime Expression Compiler
A built-in **generic Pratt parser** (`ga.expr`) allows you to write math as strings that compile to optimal Zig code:
```zig
const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f32);
const result = Cl3.expr("v ^ e12 + 5", .{ .v = my_vector });
```
The compiler calculates exact node storage requirements and verifies operator precedence at comptime using $O(1)$ enum-array lookups.

### 3. Logic vs. Surface Split
- **Helpers**: Generic mathematical logic (e.g., how to construct a point in projective space) lives in shared, re-usable modules.
- **Flavours**: Extremely light facades that bind a Family to a set of Helpers and a default scalar type.

### 4. Typed Ambient Interop
Introduced `HyperCoords` and `RoundCoords` to provide metric-specific type safety. The system now prevents accidental mixing of Hyperbolic and Spherical coordinates at the API boundaries.

## GA Flavour Comparison

| Flavour | Signature | Dimensions Aware | Key Benefit |
| :--- | :--- | :--- | :--- |
| **VGA** | $Cl(n, 0, 0)$ | Yes | Simple Euclidean vector math |
| **PGA** | $Cl(n, 0, 1)$ | Yes (adds $e_0$) | Euclidean rigid motion (points/lines/planes) |
| **CGA** | $Cl(n+1, 1, 0)$ | Yes (adds $n_o, n_\infty$) | Spheres, circles, and conformal transforms |
| **STA** | $Cl(1, 3, 0)$ | Yes (Minkowski) | Relativistic physics and spinors |

## Resources

### Videos
- **[Geometric Algebra for Computer Graphics (Siggraph 2019)](https://www.youtube.com/watch?v=tX4H_ctggYo)** - The definitive primer on PGA and CGA.
- **[A Swift Introduction to Geometric Algebra (Sudgylacmoe)](https://www.youtube.com/watch?v=60z_hpEAtD8)** - Very accessible overview of the mechanics.
- **[Conformal Geometric Algebra (Marc Ten Bosch)](https://www.youtube.com/watch?v=0i3o_Zuney4)** - Great visualization of CGA transformations.

## Running

1. **Verify Foundation:** `zig build test --summary all` (144+ tests passing)
2. **Run Demo:** `zig build run`
3. **Run SIMD Benchmark:** `zig build bench-simd`

## Why "Somewhat" Efficient?

Because this repo treats performance as a design constraint, not dogma. We prioritize **mathematical correctness and type safety** first, then use Zig's `comptime` to erase the abstraction overhead.

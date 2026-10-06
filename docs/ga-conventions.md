# GA conventions

`zmath` uses explicit names for the places where GA notation is overloaded.

## Duals

- `complementDual()` is the metric-independent basis-complement / Poincaré
  dual. It works in degenerate projective metrics and is what `join()` and the
  anti-products use.
- `dual()` is only a short alias for `complementDual()`.
- `hodgeDual()` is metric-aware. It is available only for non-degenerate
  metrics and satisfies `A ^ hodgeDual(A) = scalarProduct(A, A) * I` for basis
  blades.

Prefer `complementDual()` or `hodgeDual()` in public examples. Use bare
`dual()` only when the convention is already clear.

## Products

- `gp()` / `geometricProduct()` is the Clifford product.
- `wedge()` / `outerProduct()` is the exterior product.
- `meet()` is an explicit alias for `wedge()` in direct-space contexts.
- `join()` / `antiWedge()` / `regressiveProduct()` is the exterior
  antiproduct: `complementDual(complementDual(A) ^ complementDual(B))`.
- `antiGeometric()` and `antiDot()` are the corresponding anti-products.
- `dot()` is the Hestenes dot product.
- `leftContraction()` and `rightContraction()` are explicit contractions.

## Representations and normalization

Carrier types establish coefficient type, metric signature, and possible blade
support, not geometric membership. `Rotor` is an even carrier; PGA `Motor` is
`base.Even`, and PGA `Point`/`Direction` are the same trivector type. Raw
`init()`, casts, and field writes do not prove unit norm, zero homogeneous
weight, decomposability, or the rotor/Study identities.

| Helper | Contract |
| --- | --- |
| `normalize(v)` | Checked floating grade-1 normalization by absolute metric magnitude. Non-finite inputs/norms, near-zero/null magnitude, and unrepresentable normalized results fail. Timelike vectors retain scalar norm squared -1. |
| `normalized(mv)` | Unchecked scaling by `sqrt(abs(scalarNormSquared()))`; near-zero/null magnitude retains the input. No finite-value or geometric validation. |
| `normalizedRotor(r)` | Scales by `sqrt(abs(<r * reverse(r)>_0))`. Near-zero/non-finite scalar denominators retain the input. Nonscalar terms are ignored; negative denominators produce scalar -1, not +1. This does not turn arbitrary even values into rotors. |
| `debugAssertRotor(r, epsilon)` | Asserts finite identity for the complete `r * reverse(r)` only in Debug; release modes do nothing. |

Near-zero thresholds are 5e-3 for f16, 1e-6 for f32, and 1e-12 for other floating
coefficient types. Successful scalar-magnitude normalization is not proof of
versor membership. A nonzero null vector cannot be normalized by its metric
magnitude; coefficient-space length is a different quantity.

`planarRotor()` and `rotorFromTo()` now return named errors. The planar helper
requires a finite angle; from/to helpers require finite nonzero 2D Euclidean
vectors with representable normalization. `tryRotorFromTo()` retains the same
checked contract. Antiparallel inputs choose the canonical e12 half-turn.
`rotated()` checks carrier compatibility, not unit-versor membership; arbitrary
even values retain grade-projected sandwich semantics rather than an isometry.

## Restricted inverse

`inverse()` uses `reverse(A) / <A * reverse(A)>_0`, not a general multivector
inverse algorithm. Inputs and the nonzero denominator must be finite; every
nonscalar denominator coefficient must be **exactly zero**. Non-finite results
are rejected. Null can mean an unsupported denominator, numerical
underflow/overflow, or a singular value; it does not prove that a general
algebraic inverse is absent. Coefficients are divided directly to avoid an
unrepresentable reciprocal when the final inverse is representable.

## RGA interior products and projections

`ga.rga` (also forwarded on every instantiated namespace) ships the rigid
geometric algebra combinators defined at rigidgeometricalgebra.org, phrased
over generic multivector carriers:

- `bulkDual(u) = reverse(u) ⦑ 𝟙` and `weightDual(u) = reverse(u) ⦗ 1` are the
  right metric dual and antidual. In a degenerate projective metric both are
  nilpotent: applying either twice yields zero (the metric determinant
  vanishes), and the null-axis component contributes nothing.
- Contractions `a ∨ b★` (`bulkContraction`) / `a ∨ b☆` (`weightContraction`)
  and expansions `a ∧ b★` (`bulkExpansion`) / `a ∧ b☆` (`weightExpansion`)
  are the antiwedge/wedge products against the corresponding duals.
- `project(a, b) = b ∨ (a ∧ b☆)` and `antiproject(a, b) = b ∧ (a ∨ b☆)` are
  the orthogonal projection and antiprojection.

Signature caveats (all pinned by tests):

- For same-grade vectors in Euclidean metrics, `bulkContraction(a, b)` equals
  the scalar part of `reverse(b) a` up to the intrinsic double-complement
  sign `(−1)^(n−1)` (positive in `Cl(3,0)`, negative in `Cl(2,0)` and
  `Cl(4,0)`). The same-grade expansion equals `(a • b) ∧ 𝟙` in Euclidean
  metrics.
- In indefinite metrics the equality breaks beyond a sign: the timelike
  contributions carry opposite metric signs (in `Cl(3,1)`,
  `bulkContraction(e4, e4) = +1` while the metric dot is `−1`). That
  divergence is the bulk/weight distinction itself, not a defect.
- The projection/antiprojection formulas assume mixed-grade, mixed-content
  objects (as in the RGA representation). On pure plane-based-PGA blades a
  point (trivector) projected onto a plane (vector) vanishes, because the
  weight duals collapse to the metric-free complement in our primitives;
  the combinators are incidence bookkeeping only in that representation.

## Bivector exponentials

`exp()` returns an even carrier for a finite bivector `B` whose computed square
is a finite scalar. It accepts any metric, including degenerate ones:

| Square | Exponential |
| --- | --- |
| `B² = -θ² < 0` | `cos(θ) + B*sin(θ)/θ` |
| `B² = 0` | `1 + B`, including nonzero null generators |
| `B² = θ² > 0` | `cosh(θ) + B*sinh(θ)/θ` |

The restriction concerns coefficient values, not carrier support; full carriers
containing only a bivector are accepted. Non-bivector values, non-finite inputs
or squares, and nonzero nonscalar square coefficients panic at runtime and
produce a diagnostic at comptime. This is not a general multivector exponential.
Hyperbolic results can overflow the coefficient type's representable range.
All floating coefficient types remain accepted; `f32`/`f64` use the standard
hyperbolic routines, with near-zero/compensated formulas for other types.

## Expressions

The expression compiler follows the same names:

| Expression | Operation |
| --- | --- |
| `*`, `\gp`, `⟑` | geometric product |
| `^`, `∧`, `\wedge` | wedge / meet |
| `&`, `∨`, `\join`, `\regressive`, `\antiwedge` | join |
| `.`, `⋅`, `·`, `•`, `\cdot`, `\bullet` | Hestenes dot |
| `⟇`, `\ganti`, `\antigeometric` | geometric antiproduct |
| `∘`, `\antidot` | antidot |
| `<<`, `⌋`, `\rfloor` | left contraction |
| `>>`, `⌊`, `\lfloor` | right contraction |
| postfix `★`, `\star`, `\dual`, `\complementDual` | complement dual |
| postfix `\hodge`, `\hodgeDual` | Hodge dual |
| postfix `^-1` | inverse for constant expressions |

Hodge operators require a non-degenerate metric. Runtime expression compilation
returns `error.UndefinedHodgeDual` for unsupported Hodge use, including constant
operands; comptime compilation reports the same restriction as a diagnostic.
Ordinary arithmetic and complement duality remain available in projective
metrics. Unsupported Hodge nodes are rejected before evaluation.

## PGA model

Projective Euclidean (PGA-style) models use `Cl(n, 0, 1)` with named basis
vectors `e1..en` for Euclidean directions and `e0` for the degenerate
projective basis vector. Configure it with naming spans:

```zig
const RawP3 = zmath.ga.AlgebraWithNamingOptions(
    .{ .p = 3, .q = 0, .r = 1 },
    zmath.ga.blade_parsing.SignedBladeNamingOptions.withBasisSpans(
        zmath.ga.blades.BasisIndexSpans.init(.{
            .positive = .range(1, 3),
            .degenerate = .singleton(0),
        }),
    ),
).Instantiate(f32);
const P3 = zmath.ga.pga.extend(RawP3);
```

3D PGA points are trivectors built as the complement dual of their
homogeneous coordinate vector:

```text
P(x, y, z) = complementDual(e0 + x*e1 + y*e2 + z*e3)
```

Planes are vectors:

```text
π(a, b, c, d) = a*e1 + b*e2 + c*e3 + d*e0
```

`P3` names the semantic sparse carriers as `Plane`, `Line`, `Point`,
`Direction`, and `Motor`; the underlying general algebra remains available as
`P3.base`. The geometric constructors return named errors:

- `point(position)` requires finite coordinates and sets homogeneous weight 1.
  Signed integer coordinates must also permit the complement's sign changes;
  an unrepresentable negation returns `error.UnrepresentableResult`.
- `direction(vector)` requires finite nonzero coordinates and sets weight 0;
  it does not normalize Euclidean length. Zero returns `error.ZeroDirection`.
- `rotation(axis, angle)` requires a finite nonzero axis and finite angle.
  Maximum-component scaling avoids squared-axis-norm overflow/underflow.
- `translator(displacement)` requires finite displacement; zero returns identity.

Rotation/translation constructors produce unit motors up to floating-point
roundoff, not invariant-bearing types. `P3.compose(lhs, rhs)` applies `rhs` then
`lhs`, and `P3.transformPoint(point, motor)` applies the sandwich. A rigid
isometry requires a genuine unit motor; arbitrary even values retain the
algebraic action. Motor composition and
point/direction actions use the dual-quaternion basis of the same `Even`
subalgebra internally, so they retain general PGA product semantics for
non-unit motors without materializing intermediate multivectors. For batches,
`P3.prepare(motor)` precomputes that action and exposes
`PreparedMotor.transformPoint` and `.transformDirection`.

So for PGA, `wedge()`/`meet()` is the direct incidence product and
`join()` is the regressive product built through complement duality.
The same representation (with a positive or negative homogeneous axis)
is what the constant-curvature kernel uses for its EPGA/HPGA round-trip
helpers. See [geometry construction contracts](geometry-contracts.md) for
checked spherical/constant-curvature entry points and trusted projection kernels.

## Runtime blade indices

There are two runtime blade constructors because projective algebras often use
named basis index `0`:

- `fromInternalIndices()` uses internal one-based basis indices.
- `fromNamedIndices()` uses the algebra's configured named indices.
- `fromIndices()` remains as a legacy alias for `fromInternalIndices()`.

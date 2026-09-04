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

## PGA model

Projective Euclidean (PGA-style) models use `Cl(n, 0, 1)` with named basis
vectors `e1..en` for Euclidean directions and `e0` for the degenerate
projective basis vector. Configure it with naming spans:

```zig
const P3 = zmath.ga.AlgebraWithNamingOptions(
    .{ .p = 3, .q = 0, .r = 1 },
    zmath.ga.blade_parsing.SignedBladeNamingOptions.withBasisSpans(
        zmath.ga.blades.BasisIndexSpans.init(.{
            .positive = .range(1, 3),
            .degenerate = .singleton(0),
        }),
    ),
).Instantiate(f32);
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

So for PGA, `wedge()`/`meet()` is the direct incidence product and
`join()` is the regressive product built through complement duality.
The same representation (with a positive or negative homogeneous axis)
is what the constant-curvature kernel uses for its EPGA/HPGA round-trip
helpers.

## Runtime blade indices

There are two runtime blade constructors because projective algebras often use
named basis index `0`:

- `fromInternalIndices()` uses internal one-based basis indices.
- `fromNamedIndices()` uses the algebra's configured named indices.
- `fromIndices()` remains as a legacy alias for `fromInternalIndices()`.

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

`zmath.flavours.pga` uses `Cl(n, 0, 1)` with named basis vectors
`e1..en` for Euclidean directions and `e0` for the degenerate projective
basis vector.

Default 3D PGA points are trivectors:

```text
P(x, y, z) = x*e_2_3_0 + y*e_3_1_0 + z*e_1_2_0 + e123
```

Planes are vectors:

```text
π(a, b, c, d) = a*e1 + b*e2 + c*e3 + d*e0
```

So for default PGA, `wedge()`/`meet()` is the direct incidence product and
`join()` is the regressive product built through complement duality.

## Runtime blade indices

There are two runtime blade constructors because projective algebras often use
named basis index `0`:

- `fromInternalIndices()` uses internal one-based basis indices.
- `fromNamedIndices()` uses the algebra's configured named indices.
- `fromIndices()` remains as a legacy alias for `fromInternalIndices()`.

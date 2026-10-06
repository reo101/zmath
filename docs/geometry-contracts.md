# Geometry construction contracts

Geometry carriers store coordinates; their types do not establish geometric
validity. `Point` and `Direction` in `geometry.spherical_game` are the same
ambient vector type. A `Rotor` is an even carrier, not proof of Spin(4) membership.
Public struct literals, `init()` on raw GA carriers, and field writes bypass
geometric constructor checks.

## Checked spherical construction

`Pose.init(position, right, up, forward, radius)` and
`TangentFrame.init(center, x, y, z, radius)` require:

- finite, positive radius;
- finite unit ambient vectors;
- axes tangent to the center and mutually orthogonal.

Squared unit norms and dot products use absolute tolerance **1e-3**. The radius
sets physical distance units; ambient points remain on the unit sphere.
`Pose.north(radius)` constructs the canonical frame under the same contract.
These functions return `ConstructionError!T`, not plain values. Their results
remain mutable, so later field writes can invalidate them.

Pose movement/look methods also return errors. Movement requires a finite
physical distance and a unit tangent axis. They reject invalid source frames,
unrepresentable distance/radius ratios, and invalid resulting frames. The demo's
internal wrappers explicitly assume their scene-generated state remains valid;
they are not additional untrusted-input boundaries.

`rotorBetween(a, b, angle)` constructs a **plane rotation**, not a general
from/to alignment. It requires finite orthogonal unit axes and a finite angle.
Zero, parallel, and antiparallel axes are rejected. The complete
`R * reverse(R)` is checked against finite identity with tolerance 1e-3.

`expMap(center, tangent, radius)` checks the radius, unit center, finite tangent,
and tangency. Zero tangent retains the center. Nonzero tangents require a
representable squared length and angular distance; numerical length underflow
is an error, not a silent zero-step fallback. Small physical length alone does
not justify returning the center when the radius is also small. The result
must pass the unit-point check.

`TangentFrame.cubeVertices(half_extent)` checks its frame and requires a finite,
positive half extent. It propagates exponential-map failures instead of
constructing invalid vertices.

Construction errors identify invalid radius/extent, non-finite inputs, non-unit
vectors/rotors, non-tangent directions, non-orthogonal axes, and unrepresentable
results. No constructor silently repairs an invalid frame.

```zig
const spherical = zmath.geometry.spherical_game;
const pose = try spherical.Pose.north(2);
const moved = try pose.moveForward(0.5);
const target = try spherical.expMap(moved.position, moved.right.scale(0.25), moved.radius);
const frame = try spherical.TangentFrame.init(
    moved.position, moved.right, moved.up, moved.forward, moved.radius,
);
const vertices = try frame.cubeVertices(0.1);
_ = target;
_ = vertices;
```

## Existing optional boundaries

- Spherical `normalize()` returns null for non-finite coefficients/squared norm
  or ambient length <= 1e-8. Success establishes unit length, not tangency.
- Spherical `logMap()` checks finite positive radius and finite unit points.
  Coincident points return zero; antipodes return null because there is no
  unique shortest direction. Invalid inputs and non-finite output also return null.
- Constant-curvature `embedConformal()` / `embedProjective()` and their GA
  counterparts reject invalid radii, non-finite chart/intermediate values, and
  points outside the open hyperbolic ball. The model's signed unit squared norm
  must be representable within 1e-3; finite chart points near the hyperbolic
  boundary can therefore be rejected due to cancellation. Spherical GA
  round-trips preserve ambient orientation, including negative homogeneous
  coordinates beyond the conformal chart's equator.
- Constant-curvature frame constructors additionally check finite angles and
  the ambient metric Gram matrix within 1e-3. Degenerate numerical tangent
  construction returns null.

The algorithms remain finite-precision constructions, not exact geometric
predicates or a guarantee that every mathematically valid input is representable.

## Trusted arithmetic kernels

Vector arithmetic, dot/norm evaluation, sandwiches, hemisphere classification,
and per-ray/raster projection kernels do not validate all geometric invariants.
Their inputs must already satisfy the relevant model:

- spherical projection/ray kernels require finite unit points and an
  orthonormal unit tangent basis, plus finite valid projection parameters;
- `rotate()` requires a genuine unit Spin(4) rotor for a length-preserving
  rotation; arbitrary even carriers retain grade-projected sandwich semantics;
- constant-curvature `samplePoint()` requires a valid frame and a point in the
  same metric model.

Validation belongs at construction/input boundaries, not in every arithmetic
operation. See [GA conventions](ga-conventions.md) for metric normalization,
reverse-based inverses, raw carrier aliases, and checked PGA construction.

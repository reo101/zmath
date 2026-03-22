const std = @import("std");

pub const ga = @import("ga.zig");

pub const MetricSignature = ga.MetricSignature;
pub const Multivector = ga.Multivector;
pub const Basis = ga.Basis;
pub const FullMultivector = ga.FullMultivector;
pub const GAVector = ga.GAVector;
pub const Bivector = ga.Bivector;
pub const Trivector = ga.Trivector;
pub const Scalar = ga.Scalar;
pub const Pseudoscalar = ga.Pseudoscalar;
pub const KVector = ga.KVector;

/// PGA signature `Cl(3, 0, 1)`: three positive basis vectors and one
/// degenerate (null) basis vector `e0` that squares to zero.
pub const signature: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };

/// Ambient dimension of the PGA algebra (4).
pub const dimension = signature.p + signature.q + signature.r;

test "pga signature has correct dimension and basis-vector squares" {
    // e1² = e2² = e3² = +1 (positive)
    try std.testing.expectEqual(@as(i8, 1), ga.blades.basisSquareSign(signature, 1));
    try std.testing.expectEqual(@as(i8, 1), ga.blades.basisSquareSign(signature, 2));
    try std.testing.expectEqual(@as(i8, 1), ga.blades.basisSquareSign(signature, 3));

    // e4 (a.k.a. e0) squares to 0 (degenerate)
    try std.testing.expectEqual(@as(i8, 0), ga.blades.basisSquareSign(signature, 4));

    try std.testing.expectEqual(@as(usize, 4), dimension);
}

test "degenerate basis vector squares to zero under geometric product" {
    const E = Basis(f64, dimension);
    const e0 = E.e(4); // the degenerate direction
    const result = e0.gpWithSignature(e0, signature);

    // e0 * e0 = 0 in Cl(3,0,1)
    try std.testing.expectEqual(@as(f64, 0.0), result.coeff(0)); // scalar part
}

test "positive basis vectors still square to +1" {
    const E = Basis(f64, dimension);

    inline for (1..4) |i| {
        const ei = E.e(i);
        const sq = ei.gpWithSignature(ei, signature);
        try std.testing.expectEqual(@as(f64, 1.0), sq.coeff(0));
    }
}

test "geometric product with degenerate vector produces dual-like elements" {
    const E = Basis(f64, dimension);
    const e1 = E.e(1);
    const e0 = E.e(4);

    // e1 * e0 should give a bivector e10 with coefficient +1 (or -1 depending on order)
    const e1e0 = e1.gpWithSignature(e0, signature);
    // The result lives on the blade mask e1^e4 = 0b1001
    const e1e0_mask = ga.blades.basisVectorMask(dimension, 1) ^ ga.blades.basisVectorMask(dimension, 4);
    try std.testing.expect(e1e0.coeff(e1e0_mask) != 0.0);

    // e0 * e1 should give the opposite sign
    const e0e1 = e0.gpWithSignature(e1, signature);
    try std.testing.expectEqual(-e1e0.coeff(e1e0_mask), e0e1.coeff(e1e0_mask));
}

test "ideal point (pure e0 multivector) has zero scalar product with itself" {
    const E = Basis(f64, dimension);
    const e0 = E.e(4);
    const sp = e0.scalarProductWithSignature(e0, signature);
    try std.testing.expectEqual(@as(f64, 0.0), sp);
}

test "euclidean point representation and join" {
    const E = Basis(f64, dimension);
    const e1 = E.e(1);
    const e2 = E.e(2);
    const e3 = E.e(3);
    const e0 = E.e(4);

    // In PGA a Euclidean point is P = x*e1 + y*e2 + z*e3 + e0
    // Build point P = e1 + e0 (x=1, y=0, z=0)
    const p = e1.add(e0);

    // Build point Q = e2 + e0 (x=0, y=1, z=0)
    const q = e2.add(e0);

    // The join (outer product) of two points gives the line through them
    const line = p.outerProduct(q);

    // The line should have a non-zero e12 component (the direction part)
    const e12_mask = ga.blades.basisVectorMask(dimension, 1) ^ ga.blades.basisVectorMask(dimension, 2);
    try std.testing.expect(line.coeff(e12_mask) != 0.0);

    // The line should also have moment components involving e0
    _ = e3; // e3 unused here but available for 3D tests
}

test "fullSignedBladeFromIndicesWithSignature respects degenerate square" {
    // Repeated degenerate index should give zero
    const result = ga.fullSignedBladeFromIndicesWithSignature(f64, signature, &.{ 4, 4 });
    // e0*e0 = 0, so the scalar part must be zero
    try std.testing.expectEqual(@as(f64, 0.0), result.coeff(0));
}

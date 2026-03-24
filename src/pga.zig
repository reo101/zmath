const std = @import("std");

pub const ga = @import("ga.zig");

pub const MetricSignature = ga.MetricSignature;

/// PGA signature `Cl(3, 0, 1)`: three positive basis vectors and one
/// degenerate (null) basis vector `e0` that squares to zero.
const sig: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
pub const metric_signature = sig;

/// Ambient dimension of the PGA algebra (4).
pub const dimension = sig.dimension();
const basis_spans = ga.BasisIndexSpans.init(.{
    .positive = .range(1, 3),
    .degenerate = .singleton(0),
});

const naming_options = ga.SignedBladeNamingOptions.withBasisSpans(basis_spans);
const algebra = ga.AlgebraWithNamingOptions(sig, naming_options);
pub const h = algebra.Instantiate(f64);

fn namedBasisIndex(comptime named_index: usize) usize {
    return comptime ga.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
}


test "pga signature has correct dimension and basis-vector squares" {
    // e1² = e2² = e3² = +1 (positive)
    try std.testing.expectEqual(.positive, sig.basisSquareClass(1));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(2));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(3));

    // e0 squares to 0 (degenerate)
    try std.testing.expectEqual(.degenerate, sig.basisSquareClass(namedBasisIndex(0)));

    try std.testing.expectEqual(@as(usize, 4), dimension);
}

test "degenerate basis vector squares to zero under geometric product" {
    const E = h.Basis;
    const e0 = E.e(0); // the degenerate direction
    const result = e0.gp(e0);

    // e0 * e0 = 0 in Cl(3,0,1)
    try std.testing.expectEqual(@as(f64, 0.0), result.scalarCoeff()); // scalar part
}

test "positive basis vectors still square to +1" {
    const E = h.Basis;

    inline for (1..4) |i| {
        const ei = E.e(i);
        const sq = ei.gp(ei);
        try std.testing.expectEqual(@as(f64, 1.0), sq.scalarCoeff());
    }
}

test "geometric product with degenerate vector produces dual-like elements" {
    const E = h.Basis;
    const e1 = E.e(1);
    const e0 = E.e(0);

    // e1 * e0 should give a bivector e10 with coefficient +1 (or -1 depending on order)
    const e1e0 = e1.gp(e0);
    // The result lives on the blade mask e1^e0.
    const e1e0_mask = E.blade(&.{ 1, 0 });
    try std.testing.expect(e1e0.coeff(e1e0_mask) != 0.0);

    // e0 * e1 should give the opposite sign
    const e0e1 = e0.gp(e1);
    try std.testing.expectEqual(-e1e0.coeff(e1e0_mask), e0e1.coeff(e1e0_mask));
}

test "ideal point (pure e0 multivector) has zero scalar product with itself" {
    const E = h.Basis;
    const e0 = E.e(0);
    const sp = e0.scalarProduct(e0);
    try std.testing.expectEqual(@as(f64, 0.0), sp);
}

test "euclidean point representation and join" {
    const E = h.Basis;
    const e1 = E.e(1);
    const e2 = E.e(2);
    const e3 = E.e(3);
    const e0 = E.e(0);

    // In PGA a Euclidean point is P = x*e1 + y*e2 + z*e3 + e0
    // Build point P = e1 + e0 (x=1, y=0, z=0)
    const p = e1.add(e0);

    // Build point Q = e2 + e0 (x=0, y=1, z=0)
    const q = e2.add(e0);

    // The join (outer product) of two points gives the line through them
    const line = p.outerProduct(q);

    // The line should have a non-zero e12 component (the direction part)
    const e12_mask = E.blade(&.{ 1, 2 });
    try std.testing.expect(line.coeff(e12_mask) != 0.0);

    // The line should also have moment components involving e0
    _ = e3; // e3 unused here but available for 3D tests
}

test "fullSignedBladeFromIndicesWithSignature respects degenerate square" {
    // Repeated degenerate index should give zero
    const degenerate_index = namedBasisIndex(0);
    const result = ga.fullSignedBladeFromIndicesWithSignature(f64, sig, &.{ degenerate_index, degenerate_index });
    // e0*e0 = 0, so the scalar part must be zero
    try std.testing.expectEqual(@as(f64, 0.0), result.scalarCoeff());
}

test "pga signed blade parser accepts e0 alias for degenerate basis" {
    const parsed = ga.parseSignedBlade("e0", dimension, naming_options, false);
    try std.testing.expectEqual(ga.SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, try parsed);

    const E = h.Basis;
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expectError(error.InvalidBasisIndex, ga.resolveNamedBasisIndex(4, dimension, naming_options, false));
    try std.testing.expectError(error.InvalidBasisIndex, ga.parseSignedBlade("e4", dimension, naming_options, false));
    try std.testing.expectError(error.InvalidBasisIndex, ga.parseSignedBlade("e14", dimension, naming_options, false));
}

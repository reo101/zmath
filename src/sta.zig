const std = @import("std");

pub const ga = @import("ga.zig");

pub const MetricSignature = ga.MetricSignature;

/// STA signature `Cl(1, 3, 0)`: one positive timelike basis vector and
/// three negative spacelike basis vectors.
const sig: MetricSignature = .{ .p = 1, .q = 3, .r = 0 };
pub const metric_signature = sig;

/// Ambient dimension of the STA algebra (4).
pub const dimension = sig.dimension();

const basis_spans = ga.BasisIndexSpans.init(.{
    .positive = .singleton(0),
    .negative = .range(1, 3),
});

const naming_options = ga.SignedBladeNamingOptions.withBasisSpans(basis_spans);
const algebra = ga.AlgebraWithNamingOptions(sig, naming_options);
pub const helpers = ga.AlgebraHelperExports(algebra.HelperSurface);

fn namedBasisIndex(comptime named_index: usize) usize {
    return comptime ga.resolveNamedBasisIndexWithOptions(named_index, dimension, naming_options) catch unreachable;
}

test "sta signature has expected metric classes and dimension" {
    try std.testing.expectEqual(@as(usize, 4), dimension);

    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(0)));

    inline for (1..4) |i| {
        try std.testing.expectEqual(.negative, sig.basisSquareClass(namedBasisIndex(i)));
    }
}

test "sta basis vectors square to minkowski signs" {
    const E = helpers.Basis(f64);
    const e0 = E.e(0);

    try std.testing.expectEqual(@as(f64, 1.0), e0.gp(e0).scalarCoeff());

    inline for (1..4) |i| {
        const ei = E.e(i);
        try std.testing.expectEqual(@as(f64, -1.0), ei.gp(ei).scalarCoeff());
    }
}

test "sta signed blade parser keeps strict e0..e3 naming" {
    const parsed = ga.parseSignedBladeWithOptions("e0", dimension, naming_options);
    try std.testing.expectEqual(ga.SignedBladeSpec{ .sign = .positive, .mask = .init(0b0001) }, try parsed);

    const E = helpers.Basis(f64);
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expect(E.signedBlade("e3").eql(E.e(3)));
    try std.testing.expectError(error.InvalidBasisIndex, ga.parseSignedBladeWithOptions("e4", dimension, naming_options));
}

test "sta geometric product preserves vector anti-commutation" {
    const E = helpers.Basis(f64);
    const e0 = E.e(0);
    const e1 = E.e(1);

    const e0e1 = e0.gp(e1);
    const e1e0 = e1.gp(e0);
    const e01_mask = @TypeOf(E.signedBlade("e01")).blades[0];

    try std.testing.expectEqual(-e0e1.coeff(e01_mask), e1e0.coeff(e01_mask));
}

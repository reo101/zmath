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

pub const h = algebra.Instantiate(f64);

const Vector = algebra.Vector(f64);
const Bivector = algebra.Bivector(f64);
const Rotor = algebra.Rotor(f64);

fn namedBasisIndex(comptime named_index: usize) usize {
    return comptime ga.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
}

/// Spacetime split of a vector `x` into time and space components relative
/// to an observer with velocity `gamma0`.
///
/// x*gamma0 = (x . gamma0) + (x ^ gamma0) = t + x_vec
pub fn spacetimeSplit(x: anytype) struct { time: f64, space: h.Bivector } {
    const E = h.Basis;
    const g0 = E.e(0);
    const split = x.gp(g0);
    return .{
        .time = split.scalarCoeff(),
        .space = split.gradePart(2),
    };
}

/// Constructs a Faraday bivector `F = E + I*B` from electric and magnetic field components.
/// Note that in STA, relative 3-vectors like `E` and `B` are represented as bivectors
/// in the spacetime split (spanning the observer's time axis).
pub fn faradayBivector(electric: anytype, magnetic: anytype) h.Bivector {
    const I = h.Pseudoscalar.init(.{1});
    // F = E + I*B
    return electric.add(I.gp(magnetic).gradePart(2));
}



/// Constructs a Lorentz boost rotor `L = exp(phi * v_hat / 2)`.
/// `v_hat` is a unit spacelike bivector representing the boost direction.
pub fn lorentzBoost(rapidity: f64, direction: h.Bivector) h.Rotor {
    const cosh_half = std.math.cosh(rapidity / 2.0);
    const sinh_half = std.math.sinh(rapidity / 2.0);

    // L = cosh(phi/2) + v_hat * sinh(phi/2)
    var rotor = h.Rotor.zero();
    rotor.coeffs[0] = cosh_half; // scalar part (index 0 in EvenMultivector)

    // Direction part (bivector components)
    inline for (h.Bivector.blades, 0..) |mask, b_idx| {
        const r_idx = h.Rotor.blade_index_by_mask[mask.toInt()];
        rotor.coeffs[r_idx] = direction.coeffs[b_idx] * sinh_half;
    }

    return rotor;
}

test "sta signature has expected metric classes and dimension" {
    try std.testing.expectEqual(@as(usize, 4), dimension);

    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(0)));

    inline for (1..4) |i| {
        try std.testing.expectEqual(.negative, sig.basisSquareClass(namedBasisIndex(i)));
    }
}

test "sta basis vectors square to minkowski signs" {
    const E = h.Basis;
    const e0 = E.e(0);

    try std.testing.expectEqual(@as(f64, 1.0), e0.gp(e0).scalarCoeff());

    inline for (1..4) |i| {
        const ei = E.e(i);
        try std.testing.expectEqual(@as(f64, -1.0), ei.gp(ei).scalarCoeff());
    }
}

test "spacetime split correctly extracts components" {
    const E = h.Basis;
    // x = 2*e0 + 3*e1 (time = 2, space_x = 3)
    const x = E.e(0).scale(2.0).add(E.e(1).scale(3.0));

    const split = spacetimeSplit(x);
    try std.testing.expectEqual(@as(f64, 2.0), split.time);

    // The spatial part is the bivector e10 (or -e01)
    try std.testing.expectEqual(@as(f64, 3.0), split.space.coeffNamedWithOptions("e10", naming_options));
}

test "lorentz boost transforms vectors correctly" {
    const E = h.Basis;
    const e0 = E.e(0);

    // Boost in e1 direction with rapidity phi
    const phi: f64 = 0.5;
    // Boost plane is e1 ^ e0 (timelike plane).
    // e10 squares to +1 in STA: (e1*e0)*(e1*e0) = e1*e0*-e0*e1 = -e1*1*e1 = -e1*e1 = 1.
    const boost_plane = E.signedBlade("e10").gradePart(2);
    const L = lorentzBoost(phi, boost_plane);

    // Transform e0: e0' = L * e0 * L_rev
    const e0_prime = L.gp(e0).gp(L.reverse()).gradePart(1);

    // Expected: e0' = cosh(phi)*e0 + sinh(phi)*e1
    const expected_e0 = std.math.cosh(phi);
    const expected_e1 = std.math.sinh(phi);

    try std.testing.expect(ga.rotors2d.nearlyEqual(e0_prime.coeffNamedWithOptions("e0", naming_options), expected_e0, 1e-12));
    try std.testing.expect(ga.rotors2d.nearlyEqual(e0_prime.coeffNamedWithOptions("e1", naming_options), expected_e1, 1e-12));
}

test "faraday bivector construction" {
    const E = h.Basis;
    // Electric field in e1 direction (e10 bivector)
    const electric = E.signedBlade("e10").scale(10.0);
    // Magnetic field in e2 direction (e20 bivector)
    const magnetic = E.signedBlade("e20").scale(5.0);

    const F = faradayBivector(electric, magnetic);

    // F = E + I*B
    // I = e0123
    // I * e20 = e0123 * e20 = -e0123 * e02 = -(e0*e0) * e1 * (e2*e2) * e3 = -1 * e1 * -1 * e3 = e13
    try std.testing.expectEqual(@as(f64, 10.0), F.coeffNamedWithOptions("e10", naming_options));
    try std.testing.expectEqual(@as(f64, 5.0), F.coeffNamedWithOptions("e13", naming_options));
}

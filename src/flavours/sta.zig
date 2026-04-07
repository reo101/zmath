const std = @import("std");

pub const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");
const multivector = @import("../ga/multivector.zig");
const rotors = @import("../ga/rotors.zig");

/// STA signature `Cl(1, 3, 0)`: one positive timelike basis vector and
/// three negative spacelike basis vectors.
const default_family = family.minkowski(1, 3);
pub fn MinkowskiFamily(comptime positive_dimensions: usize, comptime negative_dimensions: usize) type {
    return family.minkowski(positive_dimensions, negative_dimensions);
}

pub fn SpacetimeFamily(comptime time_dimensions: usize, comptime space_dimensions: usize) type {
    return MinkowskiFamily(time_dimensions, space_dimensions);
}

const bindings = family.defaultBindings(default_family, f64);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
/// Ambient dimension of the STA algebra (4).
pub const dimension = bindings.dimension;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;
const naming_options = bindings.naming_options;

fn HelpersFor(comptime H: type, comptime T: type) type {
    const dimension_count = H.Full.dimensions;

    return struct {
        const Self = @This();
        pub const h = H;
        pub const Vector = H.Vector;
        pub const Bivector = H.Bivector;
        pub const Rotor = H.Rotor;
        pub const Spinor = H.Even;

        /// Spacetime split of a vector `x` into time and space components relative
        /// to an observer with velocity `gamma0`.
        ///
        /// x*gamma0 = (x . gamma0) + (x ^ gamma0) = t + x_vec
        pub fn spacetimeSplit(x: anytype) struct { time: T, space: H.Bivector } {
            comptime multivector.ensureMultivector(@TypeOf(x));
            const E = H.Basis;
            const g0 = E.e(0);
            const split = x.gp(g0);
            return .{
                .time = split.scalarCoeff(),
                .space = split.gradePart(2),
            };
        }

        /// Constructs a Faraday bivector `F = E + I*B` from electric and magnetic field components.
        pub fn faradayBivector(electric: anytype, magnetic: anytype) H.Bivector {
            comptime {
                multivector.ensureMultivector(@TypeOf(electric));
                multivector.ensureMultivector(@TypeOf(magnetic));
            }
            const I = H.Pseudoscalar.init(.{1});
            return electric.add(I.gp(magnetic).gradePart(2));
        }

        /// Constructs a Lorentz boost rotor `L = exp(phi * v_hat / 2)`.
        pub fn lorentzBoost(rapidity: T, direction: H.Bivector) H.Rotor {
            const cosh_half = std.math.cosh(rapidity / 2.0);
            const sinh_half = std.math.sinh(rapidity / 2.0);

            var rotor = H.Rotor.zero();
            rotor.coeffs[0] = cosh_half;

            inline for (H.Bivector.blades, 0..) |mask, b_idx| {
                const r_idx = H.Rotor.getBladeIndex(mask);
                rotor.coeffs[r_idx] = direction.coeffs[b_idx] * sinh_half;
            }

            return rotor;
        }

        /// Computes the action of the spacetime gradient (Dirac operator) ∇ on a multivector.
        pub fn applyGradient(comptime MType: type, partial_derivatives: [dimension_count]MType) H.Full {
            const E = H.Basis;
            var result = H.Full.zero();
            inline for (partial_derivatives, 0..) |partial_mu, i| {
                const class = H.Full.metric_signature.basisSquareClass(i + 1);
                const gamma_mu = switch (class) {
                    .negative => E.e(i).negate().gradePart(1),
                    .positive, .degenerate => E.e(i).gradePart(1),
                };
                result = result.add(gamma_mu.gp(partial_mu));
            }

            return result;
        }

        /// Maxwell's equation in STA: ∇F = J
        pub fn maxwellSource(f_derivatives: [dimension_count]H.Bivector) H.Full {
            return Self.applyGradient(H.Bivector, f_derivatives);
        }

        /// Performs a duality rotation on a Faraday bivector F by angle theta.
        pub fn dualityRotate(f: anytype, theta: T) @TypeOf(f.gp(H.Scalar.init(.{0}))) {
            comptime multivector.ensureMultivector(@TypeOf(f));
            const I = H.Pseudoscalar.init(.{1});
            const cos_t = std.math.cos(theta);
            const sin_t = std.math.sin(theta);
            const expo = H.Scalar.init(.{cos_t}).add(I.scale(sin_t));
            return f.gp(expo);
        }

        /// Decomposes a spinor into its scalar and pseudoscalar invariants.
        pub fn spinorInvariants(psi: anytype) struct { @"ρ": T, @"β": T } {
            comptime multivector.ensureMultivector(@TypeOf(psi));
            const rho_exp_ib = psi.gp(psi.reverse());
            const re = rho_exp_ib.scalarCoeff();
            const im = rho_exp_ib.coeff(H.Pseudoscalar.blades[0]);

            return .{
                .@"ρ" = @sqrt(re * re + im * im),
                .@"β" = std.math.atan2(im, re),
            };
        }

        pub fn properTimeSquared(dx: H.Vector) T {
            return dx.scalarProduct(dx);
        }

        pub fn fourVelocity(relative_v: H.Bivector) H.Vector {
            const E = H.Basis;
            const g0 = E.e(0).gradePart(1);
            const v2 = relative_v.scalarProduct(relative_v);
            const gamma = 1.0 / std.math.sqrt(1.0 - v2);
            return g0.add(relative_v.gp(g0).gradePart(1)).scale(gamma);
        }

        pub fn fourMomentum(mass: T, velocity: H.Vector) H.Vector {
            return velocity.scale(mass);
        }

        pub fn perfectFluidStressEnergy(
            a: H.Vector,
            u: H.Vector,
            energy_density: T,
            pressure: T,
        ) H.Vector {
            const dot_au = a.scalarProduct(u);
            const term1 = u.scale((energy_density + pressure) * dot_au);
            const term2 = a.scale(pressure);
            return term1.sub(term2);
        }
    };
}

pub fn FamilyHelpers(comptime FamilyType: type, comptime T: type) type {
    return HelpersFor(FamilyType.Instantiate(T), T);
}

pub fn InstantiateHelpers(comptime T: type) type {
    return HelpersFor(Instantiate(T), T);
}

const default_helpers = InstantiateHelpers(default_scalar);
const Vector = default_helpers.Vector;
const Bivector = default_helpers.Bivector;
const Rotor = default_helpers.Rotor;
pub const spacetimeSplit = default_helpers.spacetimeSplit;
pub const faradayBivector = default_helpers.faradayBivector;
pub const lorentzBoost = default_helpers.lorentzBoost;
pub const applyGradient = default_helpers.applyGradient;
pub const maxwellSource = default_helpers.maxwellSource;
pub const dualityRotate = default_helpers.dualityRotate;
pub const Spinor = default_helpers.Spinor;
pub const spinorInvariants = default_helpers.spinorInvariants;
pub const properTimeSquared = default_helpers.properTimeSquared;
pub const fourVelocity = default_helpers.fourVelocity;
pub const fourMomentum = default_helpers.fourMomentum;
pub const perfectFluidStressEnergy = default_helpers.perfectFluidStressEnergy;

fn namedBasisIndex(comptime named_index: usize) usize {
    return bindings.resolveNamedBasisIndex(named_index);
}


test "sta signature has expected metric classes and dimension" {
    try std.testing.expectEqual(@as(usize, 4), dimension);

    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(0)));

    inline for (1..4) |i| {
        try std.testing.expectEqual(.negative, metric_signature.basisSquareClass(namedBasisIndex(i)));
    }
}

test "sta facade exposes canonical algebra family surface" {
    const H32 = Instantiate(f32);
    try std.testing.expectEqual(@as(f32, 1.0), H32.Basis.e(0).gp(H32.Basis.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), H32.Basis.e(1).gp(H32.Basis.e(1)).scalarCoeff());
}

test "sta exposes configurable Minkowski families" {
    const M22 = MinkowskiFamily(2, 2).Instantiate(f32);

    try std.testing.expectEqual(@as(usize, 4), MinkowskiFamily(2, 2).dimension);
    try std.testing.expectEqual(@as(f32, 1.0), M22.Basis.e(0).gp(M22.Basis.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), M22.Basis.e(1).gp(M22.Basis.e(1)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), M22.Basis.e(2).gp(M22.Basis.e(2)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), M22.Basis.e(3).gp(M22.Basis.e(3)).scalarCoeff());
}

test "sta helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f32);
    const E = Helpers.h.Basis;
    const v = E.signedBlade("e10").scale(0.25).gradePart(2);
    const u = Helpers.fourVelocity(v);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), u.scalarProduct(u), 1e-5);
}

test "sta helpers can be instantiated for other Minkowski families" {
    const Helpers = FamilyHelpers(MinkowskiFamily(2, 2), f32);
    const E = Helpers.h.Basis;
    const derivs = [Helpers.h.Full.dimensions]Helpers.h.Bivector{
        Helpers.h.Bivector.zero(),
        E.signedBlade("e20").scale(0.1).gradePart(2),
        Helpers.h.Bivector.zero(),
        Helpers.h.Bivector.zero(),
    };
    const source = Helpers.maxwellSource(derivs);

    try std.testing.expectEqual(@as(usize, 4), Helpers.h.Full.dimensions);
    try std.testing.expect(std.math.isFinite(source.scalarCoeff()));
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

    try std.testing.expect(rotors.nearlyEqual(e0_prime.coeffNamedWithOptions("e0", naming_options), expected_e0, 1e-12));
    try std.testing.expect(rotors.nearlyEqual(e0_prime.coeffNamedWithOptions("e1", naming_options), expected_e1, 1e-12));
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

test "duality rotation preserves field invariants" {
    const E = h.Basis;
    // F = 10*e10 + 5*e13
    const electric = E.signedBlade("e10").scale(10.0).gradePart(2);
    const magnetic = E.signedBlade("e20").scale(5.0).gradePart(2);
    const F = faradayBivector(electric, magnetic);

    // F^2 = (E^2 - B^2) + 2I(E . B)
    // E^2 = 100, B^2 = 25 -> Scalar part = 75
    // E . B = 0 -> Pseudoscalar part = 0
    const F2 = F.gp(F);
    try std.testing.expectEqual(@as(f64, 75.0), F2.scalarCoeff());

    // Rotate by 45 degrees
    const angle = std.math.pi / 4.0;
    const F_prime = dualityRotate(F, angle);

    // (F')^2 = F^2 * exp(2*I*theta)
    // The magnitude of the invariant complex number s + Ip should be preserved.
    const F_prime2 = F_prime.gp(F_prime);
    const s_prime = F_prime2.scalarCoeff();
    const p_prime = F_prime2.coeff(h.Pseudoscalar.blades[0]);
    const mag_prime = @sqrt(s_prime * s_prime + p_prime * p_prime);

    try std.testing.expect(rotors.nearlyEqual(mag_prime, 75.0, 1e-12));
}

test "spinor invariants extract rho and beta" {
    // Construct simple spinor psi = sqrt(rho) * exp(I * beta / 2)
    const rho = 4.0;
    const beta = 0.6;

    const I = h.Pseudoscalar.init(.{1});
    const expo = h.Scalar.init(.{std.math.cos(beta / 2.0)}).add(I.scale(std.math.sin(beta / 2.0)));
    const psi = expo.scale(@sqrt(rho));

    const inv = spinorInvariants(psi);

    // Use UTF-8 field names
    try std.testing.expect(rotors.nearlyEqual(inv.@"ρ", rho, 1e-12));
    try std.testing.expect(rotors.nearlyEqual(inv.@"β", beta, 1e-12));
}

test "4-velocity squares to 1" {
    const E = h.Basis;
    // v = 0.6 in e1 direction (represented as 0.6 * e10)
    const v = E.signedBlade("e10").scale(0.6).gradePart(2);
    const u = fourVelocity(v);

    // u^2 should be 1
    try std.testing.expect(rotors.nearlyEqual(u.scalarProduct(u), 1.0, 1e-12));

    // Check components: gamma = 1/sqrt(1-0.36) = 1/0.8 = 1.25
    // u = 1.25*e0 + 1.25*0.6*e1 = 1.25*e0 + 0.75*e1
    try std.testing.expect(rotors.nearlyEqual(u.coeffNamedWithOptions("e0", naming_options), 1.25, 1e-12));
    try std.testing.expect(rotors.nearlyEqual(u.coeffNamedWithOptions("e1", naming_options), 0.75, 1e-12));
}

test "stress-energy of a static perfect fluid" {
    const E = h.Basis;
    const u = E.e(0).gradePart(1); // Static observer
    const rho = 10.0;
    const p = 2.0;

    // Energy density seen by observer n=e0 is n . T(n)
    const n = E.e(0).gradePart(1);
    const Tn = perfectFluidStressEnergy(n, u, rho, p);

    // For static fluid, T(e0) = rho * e0
    try std.testing.expectEqual(@as(f64, rho), Tn.coeffNamedWithOptions("e0", naming_options));

    // For static fluid, T(e1) = -p * e1
    const Te1 = perfectFluidStressEnergy(E.e(1).gradePart(1), u, rho, p);
    try std.testing.expectEqual(@as(f64, -p), Te1.coeffNamedWithOptions("e1", naming_options));
}

test "spacetime gradient of a scalar field is a 4-vector" {
    // Scalar field partial derivatives: ∂_0=1, ∂_1=2, ∂_2=0, ∂_3=0
    const partials = [4]h.Scalar{
        h.Scalar.init(.{1.0}),
        h.Scalar.init(.{2.0}),
        h.Scalar.init(.{0.0}),
        h.Scalar.init(.{0.0}),
    };

    const grad = applyGradient(h.Scalar, partials);

    // ∇ φ = γ^0 ∂_0 φ + γ^1 ∂_1 φ = γ_0 (1) - γ_1 (2)
    try std.testing.expectEqual(@as(f64, 1.0), grad.coeffNamedWithOptions("e0", naming_options));
    try std.testing.expectEqual(@as(f64, -2.0), grad.coeffNamedWithOptions("e1", naming_options));
}

test "spacetime gradient of a vector field includes divergence and curl" {
    const E = h.Basis;
    // Vector field partial derivatives: only ∂_0 A_0 = 1, others 0
    const partials = [4]h.Vector{
        E.e(0).gradePart(1), // ∂_0 A
        h.Vector.zero(),
        h.Vector.zero(),
        h.Vector.zero(),
    };

    const result = applyGradient(h.Vector, partials);

    // ∇ A = γ^0 ∂_0 A = γ_0 (e0) = 1 (scalar divergence)
    try std.testing.expectEqual(@as(f64, 1.0), result.scalarCoeff());
}

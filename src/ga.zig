const std = @import("std");

pub const blades = @import("ga/blades.zig");
pub const blade_parsing = @import("ga/blade_parsing.zig");
pub const multivector = @import("ga/multivector.zig");
pub const rotors2d = @import("ga/rotors.zig");

pub const BladeMask = blades.BladeMask;
pub const SignedBladeParseError = blade_parsing.SignedBladeParseError;
pub const SignedBladeSpec = blades.SignedBladeSpec;
pub const MetricSignature = blades.MetricSignature;
pub const euclideanSignature = blades.euclideanSignature;

pub const choose = blades.choose;
pub const bladeCount = blades.bladeCount;
pub const bladeGrade = blades.bladeGrade;
pub const gradeBladeMasks = blades.gradeBladeMasks;
pub const evenBladeMasks = blades.evenBladeMasks;
pub const oddBladeMasks = blades.oddBladeMasks;
pub const basisVectorMask = blades.basisVectorMask;
pub const basisVectorBladeMask = basisVectorMask;
pub const basisBladeMask = blades.basisBladeMask;
pub const writeBladeMask = blades.writeBladeMask;

pub const isSignedBlade = blade_parsing.isSignedBlade;
pub const parseSignedBlade = blade_parsing.parseSignedBlade;
pub const expectSignedBlade = blade_parsing.expectSignedBlade;

pub const MultivectorWithSignature = multivector.Multivector;
pub const BasisWithSignature = multivector.Basis;
pub const FullMultivectorWithSignature = multivector.FullMultivector;
pub const KVectorWithSignature = multivector.KVector;
pub const EvenMultivectorWithSignature = multivector.EvenMultivector;
pub const OddMultivectorWithSignature = multivector.OddMultivector;
pub const ScalarWithSignature = multivector.Scalar;
pub const GAVectorWithSignature = multivector.GAVector;
pub const BivectorWithSignature = multivector.Bivector;
pub const TrivectorWithSignature = multivector.Trivector;
pub const PseudoscalarWithSignature = multivector.Pseudoscalar;
pub const RotorWithSignature = multivector.Rotor;
pub const basisBladeWithSignature = multivector.basisBlade;
pub const basisVectorWithSignature = multivector.basisVector;
pub const signedBladeWithSignature = multivector.signedBlade;

/// Returns a signature-baked algebra namespace for a fixed `Cl(p, q, r)`.
pub fn Algebra(comptime sig: MetricSignature) type {
    return struct {
        pub const metric_signature = sig;
        pub const dimension = metric_signature.dimension();

        pub fn Multivector(comptime T: type, comptime blade_masks: []const BladeMask) type {
            return multivector.Multivector(T, blade_masks, metric_signature);
        }

        pub fn Basis(comptime T: type) type {
            return multivector.Basis(T, metric_signature);
        }

        pub fn FullMultivector(comptime T: type) type {
            return multivector.FullMultivector(T, metric_signature);
        }

        pub fn KVector(comptime T: type, comptime grade: usize) type {
            return multivector.KVector(T, grade, metric_signature);
        }

        pub fn EvenMultivector(comptime T: type) type {
            return multivector.EvenMultivector(T, metric_signature);
        }

        pub fn OddMultivector(comptime T: type) type {
            return multivector.OddMultivector(T, metric_signature);
        }

        pub fn Scalar(comptime T: type) type {
            return multivector.Scalar(T, metric_signature);
        }

        pub fn GAVector(comptime T: type) type {
            return multivector.GAVector(T, metric_signature);
        }

        pub fn Bivector(comptime T: type) type {
            return multivector.Bivector(T, metric_signature);
        }

        pub fn Trivector(comptime T: type) type {
            return multivector.Trivector(T, metric_signature);
        }

        pub fn Pseudoscalar(comptime T: type) type {
            return multivector.Pseudoscalar(T, metric_signature);
        }

        pub fn Rotor(comptime T: type) type {
            return multivector.Rotor(T, metric_signature);
        }

        pub fn basisBlade(
            comptime T: type,
            comptime mask: BladeMask,
        ) multivector.BasisBladeType(T, mask, metric_signature) {
            return multivector.basisBlade(T, mask, metric_signature);
        }

        pub fn basisVector(
            comptime T: type,
            comptime one_based_index: usize,
        ) multivector.BasisBladeType(T, blades.basisVectorMask(metric_signature.dimension(), one_based_index), metric_signature) {
            return multivector.basisVector(T, one_based_index, metric_signature);
        }

        pub fn signedBlade(
            comptime T: type,
            comptime name: []const u8,
        ) multivector.SignedBladeType(T, name, metric_signature) {
            return multivector.signedBlade(T, name, metric_signature);
        }

        pub fn fullSignedBladeFromIndices(
            comptime T: type,
            indices: []const usize,
        ) multivector.FullMultivector(T, metric_signature) {
            return multivector.fullSignedBladeFromIndicesWithSignature(T, metric_signature, indices);
        }
    };
}

pub const fullSignedBladeFromIndicesWithSignature = multivector.fullSignedBladeFromIndicesWithSignature;
pub const writeMultivector = multivector.writeMultivector;

test "ga facade exposes core and specialized modules" {
    try std.testing.expect(choose(5, 2) == blades.choose(5, 2));
    try std.testing.expect(bladeCount(3) == blades.bladeCount(3));
    try std.testing.expect(isSignedBlade("e(1,2)", 2));

    const sig: MetricSignature = .{ .p = 1, .q = 1 };
    const value = fullSignedBladeFromIndicesWithSignature(i32, sig, &.{ 2, 2 });
    try std.testing.expectEqual(@as(i32, -1), value.coeff(.init(0)));

    const E2 = Algebra(.euclidean(2)).Basis(f64);
    const e1 = E2.e(1);
    const half_turn = rotors2d.planarRotor(f64, std.math.pi);
    const rotated_e1 = rotors2d.rotated(e1, half_turn);
    try std.testing.expect(rotors2d.nearlyEqual(rotated_e1.coeff(.init(0b01)), -1.0, 1e-12));
    try std.testing.expect(rotors2d.nearlyEqual(rotated_e1.coeff(.init(0b10)), 0.0, 1e-12));
}

test "signature-baked algebra namespace drives metric-dependent products" {
    const Minkowski11: MetricSignature = .{ .p = 1, .q = 1 };
    const Cl11 = Algebra(Minkowski11);

    const e2 = Cl11.Basis(i32).e(2);
    const e2_squared = e2.gp(e2);
    try std.testing.expectEqual(@as(i32, -1), e2_squared.coeff(.init(0)));
}

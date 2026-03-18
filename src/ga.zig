const std = @import("std");

pub const blades = @import("ga/blades.zig");
pub const blade_parsing = @import("ga/blade_parsing.zig");
pub const multivector = @import("ga/multivector.zig");
pub const rotors2d = @import("ga/rotors.zig");

pub const BladeMask = blades.BladeMask;
pub const SignedBladeParseError = blade_parsing.SignedBladeParseError;
pub const SignedBladeSpec = blades.SignedBladeSpec;
pub const MetricSignature = blades.MetricSignature;

pub const choose = blades.choose;
pub const bladeCount = blades.bladeCount;
pub const bladeGrade = blades.bladeGrade;
pub const gradeBladeMasks = blades.gradeBladeMasks;
pub const evenBladeMasks = blades.evenBladeMasks;
pub const oddBladeMasks = blades.oddBladeMasks;
pub const basisVectorMask = blades.basisVectorMask;
pub const basisBladeMask = blades.basisBladeMask;
pub const writeBladeMask = blades.writeBladeMask;

pub const isSignedBlade = blade_parsing.isSignedBlade;
pub const parseSignedBlade = blade_parsing.parseSignedBlade;
pub const expectSignedBlade = blade_parsing.expectSignedBlade;

pub const Multivector = multivector.Multivector;
pub const Basis = multivector.Basis;
pub const FullMultivector = multivector.FullMultivector;
pub const KVector = multivector.KVector;
pub const EvenMultivector = multivector.EvenMultivector;
pub const OddMultivector = multivector.OddMultivector;
pub const Scalar = multivector.Scalar;
pub const GAVector = multivector.GAVector;
pub const Bivector = multivector.Bivector;
pub const Trivector = multivector.Trivector;
pub const Pseudoscalar = multivector.Pseudoscalar;
pub const Rotor = multivector.Rotor;
pub const basisBlade = multivector.basisBlade;
pub const basisVector = multivector.basisVector;
pub const signedBlade = multivector.signedBlade;
pub const fullSignedBladeFromIndices = multivector.fullSignedBladeFromIndices;
pub const fullSignedBladeFromIndicesWithSignature = multivector.fullSignedBladeFromIndicesWithSignature;
pub const writeMultivector = multivector.writeMultivector;

test "ga facade exposes core and specialized modules" {
    try std.testing.expect(choose(5, 2) == blades.choose(5, 2));
    try std.testing.expect(bladeCount(3) == blades.bladeCount(3));
    try std.testing.expect(isSignedBlade("e(1,2)", 2));

    const signature: MetricSignature = .{ .p = 1, .q = 1 };
    const value = fullSignedBladeFromIndicesWithSignature(i32, signature, &.{ 2, 2 });
    try std.testing.expectEqual(@as(i32, -1), value.coeff(0));

    const e1 = Basis(f64, 2).e(1);
    const half_turn = rotors2d.planarRotor(f64, std.math.pi);
    const rotated_e1 = rotors2d.rotated(e1, half_turn);
    try std.testing.expect(rotors2d.nearlyEqual(rotated_e1.coeff(0b01), -1.0, 1e-12));
    try std.testing.expect(rotors2d.nearlyEqual(rotated_e1.coeff(0b10), 0.0, 1e-12));
}

const std = @import("std");

pub const ga = @import("ga.zig");

const sig = ga.euclideanSignature(2);

pub const MetricSignature = ga.MetricSignature;
pub const dimension: usize = 2;
const algebra = ga.Algebra(sig);

pub fn Multivector(comptime T: type, comptime blade_masks: []const ga.BladeMask) type {
    return algebra.Multivector(T, blade_masks);
}

pub fn Basis(comptime T: type) type {
    return algebra.Basis(T);
}

pub fn FullMultivector(comptime T: type) type {
    return algebra.FullMultivector(T);
}

pub fn KVector(comptime T: type, comptime grade: usize) type {
    return algebra.KVector(T, grade);
}

pub fn EvenMultivector(comptime T: type) type {
    return algebra.EvenMultivector(T);
}

pub fn OddMultivector(comptime T: type) type {
    return algebra.OddMultivector(T);
}

pub fn Scalar(comptime T: type) type {
    return algebra.Scalar(T);
}

pub fn GAVector(comptime T: type) type {
    return algebra.GAVector(T);
}

pub fn Bivector(comptime T: type) type {
    return algebra.Bivector(T);
}

pub fn Pseudoscalar(comptime T: type) type {
    return algebra.Pseudoscalar(T);
}

pub fn Rotor(comptime T: type) type {
    return algebra.Rotor(T);
}

pub const rotors2d = ga.rotors2d;
pub const rotors = rotors2d;

pub const RotorError = rotors2d.RotorError;
pub const radiansFromDegrees = rotors2d.radiansFromDegrees;
pub const normSquared = rotors2d.normSquared;
pub const norm = rotors2d.norm;
pub const normalize = rotors2d.normalize;
pub const normalized = rotors2d.normalized;
pub const nearlyEqual = rotors2d.nearlyEqual;
pub const planarRotor = rotors2d.planarRotor;
pub const tryRotorFromTo = rotors2d.tryRotorFromTo;
pub const rotorFromTo = rotors2d.rotorFromTo;
pub const rotated = rotors2d.rotated;
pub const rotatedByAngle = rotors2d.rotatedByAngle;

test "vga facade keeps ga parity and rotor aliases" {
    try std.testing.expect(rotors == ga.rotors2d);

    const E2 = Basis(f64);
    const e1 = E2.e(1);
    const e2 = E2.e(2);
    const r = planarRotor(f64, radiansFromDegrees(90.0));
    const turned = rotated(e1, r);

    try std.testing.expect(nearlyEqual(turned.coeff(0b01), 0.0, 1e-12));
    try std.testing.expect(nearlyEqual(turned.coeff(0b10), e2.coeff(0b10), 1e-12));
}

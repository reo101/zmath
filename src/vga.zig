const std = @import("std");

pub const ga = @import("ga.zig");

const algebra = ga.Algebra(ga.euclideanSignature(2));
pub const h = algebra.Instantiate(f64);

pub const rotors = ga.rotors;

pub const RotorError = rotors.RotorError;
pub const radiansFromDegrees = rotors.radiansFromDegrees;
pub const normSquared = rotors.normSquared;
pub const norm = rotors.norm;
pub const normalize = rotors.normalize;
pub const normalized = rotors.normalized;
pub const nearlyEqual = rotors.nearlyEqual;
pub const planarRotor = rotors.planarRotor;
pub const tryRotorFromTo = rotors.tryRotorFromTo;
pub const rotorFromTo = rotors.rotorFromTo;
pub const rotated = rotors.rotated;
pub const rotatedByAngle = rotors.rotatedByAngle;

test "vga facade keeps ga parity and rotor aliases" {
    const E2 = h.Basis;
    const e1 = E2.e(1);
    const e2 = E2.e(2);
    const r = planarRotor(f64, radiansFromDegrees(90.0));
    const turned = rotated(e1, r);

    try std.testing.expect(nearlyEqual(turned.coeffNamed("e1"), 0.0, 1e-12));
    try std.testing.expect(nearlyEqual(turned.coeffNamed("e2"), e2.coeffNamed("e2"), 1e-12));
}

const std = @import("std");

pub const ga = @import("ga.zig");

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

    const E2 = ga.Basis(f64, 2);
    const e1 = E2.e(1);
    const e2 = E2.e(2);
    const r = planarRotor(f64, radiansFromDegrees(90.0));
    const turned = rotated(e1, r);

    try std.testing.expect(nearlyEqual(turned.coeff(0b01), 0.0, 1e-12));
    try std.testing.expect(nearlyEqual(turned.coeff(0b10), e2.coeff(0b10), 1e-12));
}

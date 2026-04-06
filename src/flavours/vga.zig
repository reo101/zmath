const std = @import("std");

pub const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");

pub fn EuclideanFamily(comptime dimensions: usize) type {
    return family.euclidean(dimensions);
}

const default_family = EuclideanFamily(2);
const bindings = family.defaultBindings(default_family, f64);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

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

test "vga exposes reusable Euclidean families" {
    const E5 = EuclideanFamily(5).Instantiate(f32);
    const v = E5.Vector.init(.{ 1, 2, 3, 4, 5 });

    try std.testing.expectEqual(@as(f32, 5.0), v.coeffNamed("e5"));
}

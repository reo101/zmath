const std = @import("std");

pub const ga = @import("../ga.zig");
const family = ga.family;

pub fn EuclideanFamily(comptime dimensions: usize) type {
    return family.euclidean(dimensions);
}

const default_family = EuclideanFamily(2);
const bindings = family.defaultBindings(default_family, f64);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
pub const dimension = bindings.dimension;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub const rotors = ga.rotors;

fn assertPlanarEuclideanFamily(comptime H: type) void {
    if (H.Full.dimensions != 2) {
        @compileError("planar VGA helpers require a 2D Euclidean family");
    }
    inline for (0..2) |i| {
        if (H.Full.metric_signature.basisSquareClass(i + 1) != .positive) {
            @compileError("planar VGA helpers require a positive-definite 2D Euclidean family");
        }
    }
}

fn HelpersFor(comptime H: type, comptime T: type) type {
    return struct {
        pub const h = H;
        pub const Vector = H.Vector;
        pub const Bivector = H.Bivector;
        pub const Rotor = H.Rotor;
        pub const RotorError = rotors.RotorError;

        pub const radiansFromDegrees = rotors.radiansFromDegrees;
        pub const normSquared = rotors.normSquared;
        pub const norm = rotors.norm;
        pub const normalize = rotors.normalize;
        pub const normalized = rotors.normalized;
        pub const nearlyEqual = rotors.nearlyEqual;
        pub const rotated = rotors.rotated;

        pub fn planarRotor(angle_radians: T) H.Rotor {
            comptime assertPlanarEuclideanFamily(H);
            return rotors.planarRotor(T, angle_radians);
        }

        pub fn tryRotorFromTo(from: anytype, to: anytype) rotors.RotorError!H.Rotor {
            comptime assertPlanarEuclideanFamily(H);
            return rotors.tryRotorFromTo(from, to);
        }

        pub fn rotorFromTo(from: anytype, to: anytype) H.Rotor {
            comptime assertPlanarEuclideanFamily(H);
            return rotors.rotorFromTo(from, to);
        }

        pub fn rotatedByAngle(vector: anytype, angle_radians: T) H.Vector {
            comptime assertPlanarEuclideanFamily(H);
            return rotors.rotatedByAngle(vector, angle_radians);
        }
    };
}

pub fn FamilyHelpers(comptime FamilyType: type, comptime T: type) type {
    return HelpersFor(FamilyType.Instantiate(T), T);
}

pub fn InstantiateHelpers(comptime T: type) type {
    return FamilyHelpers(Family, T);
}

const default_helpers = InstantiateHelpers(default_scalar);
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

test "vga helpers are instantiatable for the default family" {
    const Helpers = InstantiateHelpers(f32);
    const e1 = Helpers.h.Basis.e(1);
    const rotated_e1 = Helpers.rotatedByAngle(e1, std.math.pi / 2.0);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated_e1.named().e1, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated_e1.named().e2, 1e-6);
}

test "vga helpers are reusable for other Euclidean families" {
    const Helpers = FamilyHelpers(EuclideanFamily(5), f32);
    const v = Helpers.h.Vector.init(.{ 1, 2, 3, 4, 5 });

    try std.testing.expectApproxEqAbs(@as(f32, 55.0), Helpers.normSquared(v), 1e-5);
}

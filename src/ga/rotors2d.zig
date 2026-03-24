const std = @import("std");
const multivector = @import("multivector.zig");
const blades = @import("blades.zig");

const euclidean2 = blades.euclideanSignature(2);

/// Canonical mask for the oriented 2D bivector `e12`.
const e12_mask: blades.BladeMask = .init(0b11);

fn defaultTolerance(comptime T: type) T {
    return switch (T) {
        f16 => 5e-3,
        f32 => 1e-6,
        else => 1e-12,
    };
}

pub const RotorError = error{
    ZeroVector,
};

fn assertFloatVector2(comptime M: type) void {
    if (!@hasDecl(M, "dimensions") or !@hasDecl(M, "Coefficient") or !@hasDecl(M, "blades")) {
        @compileError("expected a 2D multivector type");
    }
    if (M.dimensions != 2) {
        @compileError("this helper is currently specialized to 2D VGA");
    }
    if (!blades.allMasksHaveGrade(M.blades, 1)) {
        @compileError("this helper expects a grade-1 vector type");
    }
    switch (@typeInfo(M.Coefficient)) {
        .float, .comptime_float => {},
        else => @compileError("2D rotor helpers currently require floating-point coefficients"),
    }
}

fn assertFloatRotor2(comptime M: type) void {
    if (!@hasDecl(M, "dimensions") or !@hasDecl(M, "Coefficient") or !@hasDecl(M, "blades")) {
        @compileError("expected a 2D rotor multivector type");
    }
    if (M.dimensions != 2) {
        @compileError("this helper is currently specialized to 2D VGA");
    }
    if (!blades.allMasksHaveParity(M.blades, true)) {
        @compileError("this helper expects an even multivector / rotor carrier");
    }
    switch (@typeInfo(M.Coefficient)) {
        .float, .comptime_float => {},
        else => @compileError("2D rotor helpers currently require floating-point coefficients"),
    }
}

/// Converts degrees to radians.
pub fn radiansFromDegrees(angle_degrees: anytype) f64 {
    return @as(f64, @floatCast(angle_degrees)) * std.math.pi / 180.0;
}

/// Returns the Euclidean norm squared of a 2D grade-1 vector.
pub fn normSquared(vector: anytype) @TypeOf(vector).Coefficient {
    const Vector = @TypeOf(vector);
    comptime assertFloatVector2(Vector);
    return vector.scalarProduct(vector);
}

/// Returns the Euclidean norm of a 2D grade-1 vector.
pub fn norm(vector: anytype) @TypeOf(vector).Coefficient {
    const Vector = @TypeOf(vector);
    comptime assertFloatVector2(Vector);
    return @sqrt(normSquared(vector));
}

/// Returns the normalized version of a 2D grade-1 vector.
pub fn normalized(vector: anytype) @TypeOf(vector) {
    return normalize(vector) catch unreachable;
}

/// Returns the normalized version of a 2D grade-1 vector, or `error.ZeroVector`.
pub fn normalize(vector: anytype) RotorError!@TypeOf(vector) {
    const Vector = @TypeOf(vector);
    comptime assertFloatVector2(Vector);

    const magnitude = norm(vector);
    if (nearlyEqual(magnitude, 0, defaultTolerance(Vector.Coefficient))) {
        return error.ZeroVector;
    }
    return vector.divide(magnitude);
}

/// Returns whether two scalars differ by at most `epsilon`.
pub fn nearlyEqual(lhs: anytype, rhs: @TypeOf(lhs), epsilon: @TypeOf(lhs)) bool {
    const abs_lhs = @abs(lhs);
    const abs_rhs = @abs(rhs);
    const scale = @max(abs_lhs, abs_rhs);
    // Relative tolerance keeps comparisons stable when magnitudes grow,
    // while the absolute term covers values near zero.
    return @abs(lhs - rhs) <= epsilon * @max(1, scale);
}

/// Verifies the rotor normalization invariant in debug builds.
pub fn debugAssertRotor(rotor: anytype, epsilon: @TypeOf(rotor).Coefficient) void {
    const RotorType = @TypeOf(rotor);
    comptime assertFloatRotor2(RotorType);

    if (@import("builtin").mode != .Debug) return;

    const identity = rotor.gp(rotor.reverse());
    inline for (RotorType.blades) |mask| {
        const coeff = identity.coeff(mask);
        if (comptime mask.bitset.mask == 0) {
            std.debug.assert(nearlyEqual(coeff, 1, epsilon));
        } else {
            std.debug.assert(nearlyEqual(coeff, 0, epsilon));
        }
    }
}

/// Returns the unit rotor for a counter-clockwise 2D rotation.
pub fn planarRotor(comptime T: type, angle_radians: T) multivector.Rotor(T, euclidean2) {
    const half_angle = angle_radians / 2;
    const rotor = multivector.Rotor(T, euclidean2).init(.{
        @cos(half_angle),
        -@sin(half_angle),
    });
    debugAssertRotor(rotor, defaultTolerance(T));
    return rotor;
}

/// Returns the rotor that takes `from` onto `to` in 2D VGA.
pub fn rotorFromTo(from: anytype, to: anytype) multivector.Rotor(@TypeOf(from).Coefficient, euclidean2) {
    return tryRotorFromTo(from, to) catch unreachable;
}

/// Returns the rotor that takes `from` onto `to` in 2D VGA, or `error.ZeroVector`.
pub fn tryRotorFromTo(from: anytype, to: anytype) RotorError!multivector.Rotor(@TypeOf(from).Coefficient, euclidean2) {
    const Vector = @TypeOf(from);
    const ToVector = @TypeOf(to);
    comptime assertFloatVector2(Vector);
    comptime assertFloatVector2(ToVector);
    comptime {
        if (Vector.Coefficient != ToVector.Coefficient) {
            @compileError("rotorFromTo expects matching coefficient types");
        }
    }
    const T = Vector.Coefficient;
    const epsilon = defaultTolerance(T);

    const from_unit = try normalize(from);
    const to_unit = try normalize(to);
    const raw = multivector.Scalar(T, euclidean2).init(.{1}).add(to_unit.gp(from_unit));
    const scalar = raw.scalarCoeff();
    const bivector = raw.coeff(e12_mask);
    const magnitude = @sqrt(scalar * scalar + bivector * bivector);

    if (nearlyEqual(magnitude, 0, epsilon)) {
        // Antiparallel vectors admit infinitely many 180° rotors in 2D.
        // Pick the canonical +e12 rotor to produce a deterministic result.
        return multivector.Rotor(T, euclidean2).init(.{ 0, 1 });
    }

    const rotor = multivector.Rotor(T, euclidean2).init(.{
        scalar / magnitude,
        bivector / magnitude,
    });
    debugAssertRotor(rotor, epsilon);
    return rotor;
}

/// Applies the sandwich product `R v ~R` and returns the rotated vector.
pub fn rotated(vector: anytype, rotor: anytype) multivector.Vector(@TypeOf(vector).Coefficient, euclidean2) {
    const Vector = @TypeOf(vector);
    const RotorType = @TypeOf(rotor);
    comptime assertFloatVector2(Vector);
    comptime assertFloatRotor2(RotorType);

    debugAssertRotor(rotor, defaultTolerance(RotorType.Coefficient));
    return rotor.gp(vector).gp(rotor.reverse()).gradePart(1);
}

/// Rotates a vector by an angle in radians using a planar rotor.
pub fn rotatedByAngle(vector: anytype, angle_radians: @TypeOf(vector).Coefficient) multivector.Vector(@TypeOf(vector).Coefficient, euclidean2) {
    const Vector = @TypeOf(vector);
    comptime assertFloatVector2(Vector);
    return rotated(vector, planarRotor(Vector.Coefficient, angle_radians));
}

test "2D rotors rotate vectors in the expected orientation" {
    const E2 = multivector.Basis(f64, euclidean2);
    const e1 = E2.e(1);
    const e2 = E2.e(2);

    const quarter_turn = rotatedByAngle(e1, radiansFromDegrees(90.0));
    try std.testing.expect(nearlyEqual(quarter_turn.coeffNamed("e1"), 0, 1e-12));
    try std.testing.expect(nearlyEqual(quarter_turn.coeffNamed("e2"), e2.coeffNamed("e2"), 1e-12));

    const diagonal = rotorFromTo(e1.add(e2.scale(5)), e2);
    const diagonal_result = rotated(e1.add(e2.scale(5)), diagonal);
    try std.testing.expect(nearlyEqual(diagonal_result.coeffNamed("e1"), 0, 1e-12));
    try std.testing.expect(nearlyEqual(diagonal_result.coeffNamed("e2"), @sqrt(26.0), 1e-12));
}

test "rotorFromTo handles antiparallel vectors" {
    const E2 = multivector.Basis(f64, euclidean2);
    const e1 = E2.e(1);

    const rotor = rotorFromTo(e1, e1.negate());
    const rotated_e1 = rotated(e1, rotor);

    try std.testing.expect(nearlyEqual(rotated_e1.coeffNamed("e1"), -1.0, 1e-12));
    try std.testing.expect(nearlyEqual(rotated_e1.coeffNamed("e2"), 0.0, 1e-12));
}

test "safe rotor helpers return ZeroVector on invalid input" {
    const Vec2 = multivector.Vector(f64, euclidean2);
    const zero = Vec2.zero();
    const e1 = multivector.Basis(f64, euclidean2).e(1);

    try std.testing.expectError(error.ZeroVector, normalize(zero));
    try std.testing.expectError(error.ZeroVector, tryRotorFromTo(zero, e1));
    try std.testing.expectError(error.ZeroVector, tryRotorFromTo(e1, zero));
}

test "planar rotor stays normalized for multiple angles" {
    inline for ([_]f64{ 0.0, std.math.pi / 3.0, -std.math.pi / 2.0, std.math.pi }) |angle| {
        const rotor = planarRotor(f64, angle);
        const identity = rotor.gp(rotor.reverse());
        try std.testing.expect(nearlyEqual(identity.scalarCoeff(), 1.0, 1e-12));
        try std.testing.expect(nearlyEqual(identity.coeffNamed("e12"), 0.0, 1e-12));
    }
}

test "rotorFromTo maps normalized direction and preserves norm" {
    const E2 = multivector.Basis(f64, euclidean2);
    const from = E2.e(1).add(E2.e(2));
    const to = E2.e(2).sub(E2.e(1));

    const rotor = rotorFromTo(from, to);
    const rotated_from = rotated(from, rotor);
    const from_unit = try normalize(from);
    const to_unit = try normalize(to);
    const rotated_unit = try normalize(rotated_from);

    try std.testing.expect(nearlyEqual(rotated_from.scalarProduct(rotated_from), from.scalarProduct(from), 1e-12));
    try std.testing.expect(nearlyEqual(rotated_unit.coeffNamed("e1"), to_unit.coeffNamed("e1"), 1e-12));
    try std.testing.expect(nearlyEqual(rotated_unit.coeffNamed("e2"), to_unit.coeffNamed("e2"), 1e-12));
    try std.testing.expect(nearlyEqual(from_unit.scalarProduct(from_unit), 1.0, 1e-12));
}

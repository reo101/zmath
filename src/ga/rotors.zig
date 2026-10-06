const std = @import("std");
const multivector = @import("multivector.zig");
const blades = @import("blades.zig");
const blade_parsing = @import("blade_parsing.zig");
const expression = @import("expression.zig");
const meta = @import("meta");

const euclidean2 = blades.euclideanSignature(2);

/// Canonical mask for the oriented 2D bivector `e12`.
const e12_mask = blades.BladeMask.parseForDimensionsPanicking("e12", 2);

fn defaultTolerance(comptime T: type) T {
    return switch (T) {
        f16 => 5e-3,
        f32 => 1e-6,
        else => 1e-12,
    };
}

pub const RotorError = error{
    ZeroVector,
    NonFiniteInput,
    NonFiniteNorm,
    UnrepresentableResult,
};

fn assertFloatVector(comptime M: type) void {
    meta.requireDecls(M, &.{ "dimensions", "Coefficient", "blades" }, "multivector type", "public constant");
    if (!blades.allMasksHaveGrade(M.blades, 1)) {
        @compileError("this helper expects a grade-1 vector type");
    }
    switch (@typeInfo(M.Coefficient)) {
        .float, .comptime_float => {},
        else => @compileError("rotor helpers currently require floating-point coefficients"),
    }
}

fn assertPlanarEuclideanVector(comptime M: type) void {
    assertFloatVector(M);
    if (M.dimensions != 2) {
        @compileError("this helper expects a 2D Euclidean vector type");
    }
    inline for (0..2) |i| {
        if (M.metric_signature.basisSquareClass(i + 1) != .positive) {
            @compileError("this helper expects a 2D Euclidean vector type");
        }
    }
}

fn assertFloatRotor(comptime M: type) void {
    meta.requireDecls(M, &.{ "dimensions", "Coefficient", "blades" }, "rotor multivector type", "public constant");
    if (!blades.allMasksHaveParity(M.blades, true)) {
        @compileError("this helper expects an even multivector / rotor carrier");
    }
    switch (@typeInfo(M.Coefficient)) {
        .float, .comptime_float => {},
        else => @compileError("rotor helpers currently require floating-point coefficients"),
    }
}

fn assertCompatibleVectorAndRotor(comptime Vector: type, comptime RotorType: type) void {
    if (Vector.Coefficient != RotorType.Coefficient) {
        @compileError("rotated expects vector and rotor with matching coefficient types");
    }
    if (Vector.dimensions != RotorType.dimensions) {
        @compileError("rotated expects vector and rotor with matching dimensions");
    }
    if (!std.meta.eql(Vector.metric_signature, RotorType.metric_signature)) {
        @compileError("rotated expects vector and rotor from the same metric signature");
    }
}

fn isCanonicalEuclideanRotor(comptime dimensions: usize, comptime Vector: type, comptime RotorType: type) bool {
    return Vector.dimensions == dimensions and
        Vector.metric_signature.p == dimensions and
        Vector.metric_signature.q == 0 and
        Vector.metric_signature.r == 0 and
        blades.sameBladeSet(RotorType.blades, Vector.EvenType.blades);
}

fn rotateEuclidean2(vector: anytype, rotor: anytype) @TypeOf(vector).VectorType {
    const Vector = @TypeOf(vector);
    const e1 = blades.basisVectorMask(2, 1);
    const e2 = blades.basisVectorMask(2, 2);
    const scalar = rotor.scalarCoeff();
    const bivector = rotor.coeff(e12_mask);
    const diagonal = scalar * scalar - bivector * bivector;
    const off_diagonal = 2 * scalar * bivector;

    return Vector.VectorType.init(.{
        diagonal * vector.coeff(e1) + off_diagonal * vector.coeff(e2),
        -off_diagonal * vector.coeff(e1) + diagonal * vector.coeff(e2),
    });
}

fn rotateEuclidean3(vector: anytype, rotor: anytype) @TypeOf(vector).VectorType {
    const Vector = @TypeOf(vector);
    const e1 = blades.basisVectorMask(3, 1);
    const e2 = blades.basisVectorMask(3, 2);
    const e3 = blades.basisVectorMask(3, 3);
    const e12 = blades.BladeMask.parseForDimensionsPanicking("e12", 3);
    const e13 = blades.BladeMask.parseForDimensionsPanicking("e13", 3);
    const e23 = blades.BladeMask.parseForDimensionsPanicking("e23", 3);

    const w = rotor.scalarCoeff();
    const x = -rotor.coeff(e23);
    const y = rotor.coeff(e13);
    const z = -rotor.coeff(e12);
    const vx = vector.coeff(e1);
    const vy = vector.coeff(e2);
    const vz = vector.coeff(e3);

    const m00 = w * w + x * x - y * y - z * z;
    const m01 = 2 * (x * y - w * z);
    const m02 = 2 * (x * z + w * y);
    const m10 = 2 * (x * y + w * z);
    const m11 = w * w - x * x + y * y - z * z;
    const m12 = 2 * (y * z - w * x);
    const m20 = 2 * (x * z - w * y);
    const m21 = 2 * (y * z + w * x);
    const m22 = w * w - x * x - y * y + z * z;

    if (comptime Vector.VectorType.use_simd) {
        const column_x: @Vector(3, Vector.Coefficient) = .{ m00, m10, m20 };
        const column_y: @Vector(3, Vector.Coefficient) = .{ m01, m11, m21 };
        const column_z: @Vector(3, Vector.Coefficient) = .{ m02, m12, m22 };
        const lanes = column_x * @as(@Vector(3, Vector.Coefficient), @splat(vx)) +
            column_y * @as(@Vector(3, Vector.Coefficient), @splat(vy)) +
            column_z * @as(@Vector(3, Vector.Coefficient), @splat(vz));
        return Vector.VectorType.initStorage(lanes);
    }

    return Vector.VectorType.init(.{
        m00 * vx + m01 * vy + m02 * vz,
        m10 * vx + m11 * vy + m12 * vz,
        m20 * vx + m21 * vy + m22 * vz,
    });
}

/// Converts degrees to radians.
pub fn radiansFromDegrees(angle_degrees: anytype) f64 {
    return @as(f64, @floatCast(angle_degrees)) * std.math.pi / 180.0;
}

fn assertFloatMultivector(comptime M: type) void {
    meta.requireDecls(M, &.{ "dimensions", "Coefficient", "blades" }, "multivector type", "public constant");
    switch (@typeInfo(M.Coefficient)) {
        .float, .comptime_float => {},
        else => @compileError("rotor helpers currently require floating-point coefficients"),
    }
}

/// Returns the metric scalar product of a multivector with itself.
pub inline fn scalarNormSquared(mv: anytype) @TypeOf(mv).Coefficient {
    const M = @TypeOf(mv);
    comptime assertFloatMultivector(M);
    return mv.scalarNormSquared();
}

/// Returns the raw coefficient-space norm squared, ignoring the metric.
pub inline fn coeffNormSquared(mv: anytype) @TypeOf(mv).Coefficient {
    const M = @TypeOf(mv);
    comptime assertFloatMultivector(M);
    return mv.coeffNormSquared();
}

/// Alias for `scalarNormSquared()`.
pub inline fn normSquared(mv: anytype) @TypeOf(mv).Coefficient {
    return scalarNormSquared(mv);
}

/// Returns `sqrt(abs(scalarNormSquared()))`.
pub inline fn norm(mv: anytype) @TypeOf(mv).Coefficient {
    return @sqrt(@abs(scalarNormSquared(mv)));
}

/// Returns the basis-complement/Poincaré dual of a multivector.
///
/// This is metric-independent and remains valid for degenerate projective
/// algebras. Use `hodgeDual()` for the metric-aware dual.
pub fn dual(mv: anytype) @TypeOf(mv.dual()) {
    return mv.dual();
}

/// Returns the metric/Hodge dual of a multivector.
///
/// This requires a non-degenerate metric at comptime.
pub fn hodgeDual(mv: anytype) @TypeOf(mv.hodgeDual()) {
    return mv.hodgeDual();
}

/// Scales by sqrt(abs(scalarNormSquared())). Near-zero magnitude retains the
/// input, including nonzero null vectors. This unchecked helper does not
/// validate finite coefficients, grades, or geometric membership.
pub fn normalized(mv: anytype) @TypeOf(mv) {
    const magnitude = norm(mv);
    if (nearlyEqual(magnitude, 0, defaultTolerance(@TypeOf(mv).Coefficient))) {
        return mv;
    }
    return mv.scale(1.0 / magnitude);
}

/// Scales an even carrier by sqrt(abs(<R * ~R>_0)). Near-zero or non-finite
/// scalar denominators retain the input. Nonscalar product terms are ignored;
/// negative denominators yield scalar -1, not +1. This is not a versor validator.
pub fn normalizedRotor(rotor: anytype) @TypeOf(rotor) {
    const RotorType = @TypeOf(rotor);
    comptime assertFloatRotor(RotorType);

    const epsilon = defaultTolerance(RotorType.Coefficient);
    const magnitude_squared = rotor.gp(rotor.reverse()).scalarCoeff();
    if (!std.math.isFinite(magnitude_squared) or nearlyEqual(magnitude_squared, 0, epsilon)) {
        return rotor;
    }
    return rotor.scale(1.0 / @sqrt(@abs(magnitude_squared)));
}

/// Normalizes a floating grade-1 vector by its absolute metric magnitude.
/// Rejects non-finite coefficients/norms and near-zero magnitude (including
/// nonzero null vectors). Scaled results must have a representable unit absolute
/// metric squared norm. Timelike inputs retain scalar norm squared -1.
pub fn normalize(vector: anytype) RotorError!@TypeOf(vector) {
    const Vector = @TypeOf(vector);
    comptime assertFloatVector(Vector);

    for (vector.coeffsArray()) |coefficient| {
        if (!std.math.isFinite(coefficient)) return error.NonFiniteInput;
    }
    const magnitude = norm(vector);
    if (!std.math.isFinite(magnitude)) return error.NonFiniteNorm;
    if (nearlyEqual(magnitude, 0, defaultTolerance(Vector.Coefficient))) {
        return error.ZeroVector;
    }
    const result = vector.divide(magnitude);
    for (result.coeffsArray()) |coefficient| {
        if (!std.math.isFinite(coefficient)) return error.UnrepresentableResult;
    }
    const result_norm_squared = result.scalarNormSquared();
    if (!std.math.isFinite(result_norm_squared)) return error.NonFiniteNorm;
    if (!nearlyEqual(@abs(result_norm_squared), 1, defaultTolerance(Vector.Coefficient))) return error.UnrepresentableResult;
    return result;
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

/// Debug-only assertion that the complete R * reverse(R) is finite identity.
/// Release modes perform no validation.
pub fn debugAssertRotor(rotor: anytype, epsilon: @TypeOf(rotor).Coefficient) void {
    const RotorType = @TypeOf(rotor);
    comptime assertFloatRotor(RotorType);

    if (@import("builtin").mode != .debug) return;

    const identity = rotor.gp(rotor.reverse());
    inline for (@TypeOf(identity).blades) |mask| {
        const coeff = identity.coeff(mask);
        if (comptime mask.bitset.mask == 0) {
            std.debug.assert(std.math.isFinite(coeff) and nearlyEqual(coeff, 1, epsilon));
        } else {
            std.debug.assert(std.math.isFinite(coeff) and nearlyEqual(coeff, 0, epsilon));
        }
    }
}

/// Constructs the unit rotor for a finite counter-clockwise 2D angle.
pub fn planarRotor(comptime T: type, angle_radians: T) RotorError!multivector.Rotor(T, euclidean2) {
    if (!std.math.isFinite(angle_radians)) return error.NonFiniteInput;
    const half_angle = angle_radians / 2;
    const rotor = multivector.Rotor(T, euclidean2).init(.{
        @cos(half_angle),
        -@sin(half_angle),
    });
    debugAssertRotor(rotor, defaultTolerance(T));
    return rotor;
}

/// Constructs the 2D VGA rotor aligning finite nonzero vector directions.
/// Uses the same checked normalization and errors as tryRotorFromTo().
pub fn rotorFromTo(from: anytype, to: anytype) RotorError!@TypeOf(from).EvenType {
    return tryRotorFromTo(from, to);
}

/// Checked from/to construction; antiparallel inputs choose the canonical
/// e12 half-turn rotor. Zero, null, and non-finite normalization is rejected.
pub fn tryRotorFromTo(from: anytype, to: anytype) RotorError!@TypeOf(from).EvenType {
    const Vector = @TypeOf(from);
    const ToVector = @TypeOf(to);
    comptime assertPlanarEuclideanVector(Vector);
    comptime assertPlanarEuclideanVector(ToVector);
    comptime {
        if (Vector.Coefficient != ToVector.Coefficient) {
            @compileError("rotorFromTo expects matching coefficient types");
        }
    }
    const T = Vector.Coefficient;
    const RotorType = Vector.EvenType;
    const epsilon = defaultTolerance(T);

    const from_unit = try normalize(from);
    const to_unit = try normalize(to);
    const raw = Vector.ScalarType.init(.{1}).add(to_unit.gp(from_unit));
    const scalar = raw.scalarCoeff();
    const bivector = raw.coeff(e12_mask);
    const magnitude = @sqrt(scalar * scalar + bivector * bivector);

    if (nearlyEqual(magnitude, 0, epsilon)) {
        // The two rotor signs encode the same 2D half-turn.
        // Pick the canonical +e12 rotor to produce a deterministic result.
        return RotorType.init(.{ 0, 1 });
    }

    const rotor = RotorType.init(.{
        scalar / magnitude,
        bivector / magnitude,
    });
    debugAssertRotor(rotor, epsilon);
    return rotor;
}

/// Applies the sandwich product `R v ~R` and returns the rotated vector.
///
/// Works for any algebra dimensions/signature as long as:
/// - `vector` is grade-1,
/// - `rotor` has even parity blades,
/// - both share coefficient type, dimensions, and metric signature.
///
/// These are carrier checks, not unit-versor checks. Arbitrary even inputs
/// retain grade-projected sandwich semantics, not necessarily an isometry.
pub fn rotated(vector: anytype, rotor: anytype) @TypeOf(vector).VectorType {
    const Vector = @TypeOf(vector);
    const RotorType = @TypeOf(rotor);
    comptime assertFloatVector(Vector);
    comptime assertFloatRotor(RotorType);
    comptime assertCompatibleVectorAndRotor(Vector, RotorType);

    if (comptime isCanonicalEuclideanRotor(2, Vector, RotorType)) {
        return rotateEuclidean2(vector, rotor);
    }
    if (comptime isCanonicalEuclideanRotor(3, Vector, RotorType)) {
        return rotateEuclidean3(vector, rotor);
    }

    // `gradePart(1)` uses the rotor carrier's naming options; preserve the
    // input vector carrier's names for callers with custom bases.
    return rotor.gp(vector).gp(rotor.reverse()).gradePart(1).cast(Vector.VectorType);
}

/// Applies the sandwich product `R v ~R` and returns it as `To`.
///
/// This is useful for custom-named vector carriers that share the canonical
/// grade-1 blade set of the source vector.
pub fn rotatedAs(comptime To: type, vector: anytype, rotor: anytype) To {
    const Vector = @TypeOf(vector);
    comptime assertFloatVector(To);
    if (To.Coefficient != Vector.Coefficient) {
        @compileError("rotatedAs expects matching coefficient types");
    }
    if (To.dimensions != Vector.dimensions) {
        @compileError("rotatedAs expects matching dimensions");
    }
    if (To.metric_signature.p != Vector.metric_signature.p or
        To.metric_signature.q != Vector.metric_signature.q or
        To.metric_signature.r != Vector.metric_signature.r)
    {
        @compileError("rotatedAs expects matching metric signatures");
    }

    return rotated(vector, rotor).cast(To);
}

/// Rotates a 2D Euclidean vector by an angle in radians.
///
/// This is the specialized equivalent of sandwiching with `planarRotor()`.
/// Use `rotated()` when the rotor is already available or the algebra is not 2D.
pub fn rotatedByAngle(vector: anytype, angle_radians: @TypeOf(vector).Coefficient) @TypeOf(vector).VectorType {
    const Vector = @TypeOf(vector);
    comptime assertPlanarEuclideanVector(Vector);

    const sin = @sin(angle_radians);
    const cos = @cos(angle_radians);
    return Vector.VectorType.init(.{
        cos * vector.coeff(blades.basisVectorMask(2, 1)) - sin * vector.coeff(blades.basisVectorMask(2, 2)),
        sin * vector.coeff(blades.basisVectorMask(2, 1)) + cos * vector.coeff(blades.basisVectorMask(2, 2)),
    });
}

test "2D rotors rotate vectors in the expected orientation" {
    const E2 = multivector.Basis(f64, euclidean2);
    const e1 = E2.e(1);
    const e2 = E2.e(2);

    const quarter_turn = rotatedByAngle(e1, radiansFromDegrees(90.0));
    try std.testing.expect(nearlyEqual(quarter_turn.coeffNamed("e1"), 0, 1e-12));
    try std.testing.expect(nearlyEqual(quarter_turn.coeffNamed("e2"), e2.coeffNamed("e2"), 1e-12));

    const diagonal = try rotorFromTo(e1.add(e2.scale(5)), e2);
    const diagonal_result = rotated(e1.add(e2.scale(5)), diagonal);
    try std.testing.expect(nearlyEqual(diagonal_result.coeffNamed("e1"), 0, 1e-12));
    try std.testing.expect(nearlyEqual(diagonal_result.coeffNamed("e2"), @sqrt(26.0), 1e-12));
}

test "rotatedAs preserves custom vector carriers with aliases" {
    const naming = comptime blade_parsing.SignedBladeNamingOptions.withBasisNames(.init(.{
        .positive = .range(1, 2),
    }), .{ "x", "y" });
    const E2 = multivector.BasisWithNamingOptions(f64, euclidean2, naming);
    const CustomVec2 = E2.Vector;
    const quarter_turn = try planarRotor(f64, -std.math.pi / 2.0);

    const preserved = rotated(CustomVec2.init(.{ 3.0, 4.0 }), quarter_turn);
    const tangent = rotatedAs(CustomVec2, CustomVec2.init(.{ 3.0, 4.0 }), quarter_turn);

    try std.testing.expectEqual(CustomVec2, @TypeOf(preserved));
    try std.testing.expect(nearlyEqual(preserved.coeffNamed("x"), 4.0, 1e-12));
    try std.testing.expect(nearlyEqual(preserved.coeffNamed("y"), -3.0, 1e-12));
    try std.testing.expect(nearlyEqual(tangent.named().x, 4.0, 1e-12));
    try std.testing.expect(nearlyEqual(tangent.named().y, -3.0, 1e-12));
}

test "rotorFromTo handles antiparallel vectors" {
    const E2 = multivector.Basis(f64, euclidean2);
    const e1 = E2.e(1);

    const rotor = try rotorFromTo(e1, e1.negate());
    const rotated_e1 = rotated(e1, rotor);

    try std.testing.expect(nearlyEqual(rotated_e1.coeffNamed("e1"), -1.0, 1e-12));
    try std.testing.expect(nearlyEqual(rotated_e1.coeffNamed("e2"), 0.0, 1e-12));
}

test "norm helpers distinguish scalar and coefficient norms" {
    const M11 = multivector.Basis(f64, .{ .p = 1, .q = 1 });
    const e2 = M11.e(2);

    try std.testing.expectEqual(@as(f64, -1.0), scalarNormSquared(e2));
    try std.testing.expectEqual(@as(f64, 1.0), coeffNormSquared(e2));
    try std.testing.expectEqual(@as(f64, 1.0), norm(e2));
}

test "safe rotor helpers return ZeroVector on invalid input" {
    const Vec2 = multivector.Vector(f64, euclidean2);
    const zero = Vec2.zero();
    const e1 = multivector.Basis(f64, euclidean2).e(1);

    try std.testing.expectError(error.ZeroVector, normalize(zero));
    try std.testing.expectError(error.ZeroVector, tryRotorFromTo(zero, e1));
    try std.testing.expectError(error.ZeroVector, tryRotorFromTo(e1, zero));
}

test "checked rotor construction rejects non-finite and null inputs" {
    const E2 = multivector.Basis(f32, euclidean2);
    const from = E2.Vector.init(.{ 1, 0 });
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |value| {
        inline for (0..2) |index| {
            var coefficients = [2]f32{ 1, 0 };
            coefficients[index] = value;
            const invalid = E2.Vector.init(coefficients);
            try std.testing.expectError(error.NonFiniteInput, normalize(invalid));
            try std.testing.expectError(error.NonFiniteInput, rotorFromTo(invalid, from));
            try std.testing.expectError(error.NonFiniteInput, rotorFromTo(from, invalid));
            try std.testing.expectError(error.NonFiniteInput, tryRotorFromTo(invalid, from));
        }
        try std.testing.expectError(error.NonFiniteInput, planarRotor(f32, value));
    }
    try std.testing.expectError(error.NonFiniteNorm, normalize(E2.Vector.init(.{ std.math.floatMax(f32), 0 })));
    const Mixed = multivector.Basis(f32, .{ .p = 1, .q = 1 });
    try std.testing.expectError(error.ZeroVector, normalize(Mixed.Vector.init(.{ 1, 1 })));
    const timelike = try normalize(Mixed.Vector.init(.{ 0, 2 }));
    try std.testing.expectEqual(@as(f32, -1), timelike.scalarNormSquared());
    try std.testing.expectError(error.UnrepresentableResult, normalize(Mixed.Vector.init(.{ 2, 1.9995 })));
    const Projective = multivector.Vector(f32, .{ .p = 1, .r = 1 });
    try std.testing.expectError(error.NonFiniteNorm, normalize(Projective.init(.{ 1e-5, 1e15 })));
}

test "normalization fallbacks do not certify geometric invariants" {
    const Mixed = multivector.Basis(f32, .{ .p = 1, .q = 1 });
    const null_vector = Mixed.Vector.init(.{ 1, 1 });
    try std.testing.expect(normalized(null_vector).eql(null_vector));
    const negative = normalizedRotor(Mixed.Full.EvenType.init(.{ 0, 1 }));
    try std.testing.expectEqual(@as(f32, -1), negative.gp(negative.reverse()).scalarCoeff());
    const E4 = multivector.Basis(f32, .euclidean(4));
    const nonversor = E4.Scalar.init(.{1}).add(E4.signedBlade("e1234")).scale(1.0 / @sqrt(@as(f32, 2))).cast(E4.Full.EvenType);
    const scaled = normalizedRotor(nonversor);
    try std.testing.expect(@abs(scaled.gp(scaled.reverse()).coeffNamed("e1234")) > 0.9);
    const zero = E4.Full.EvenType.zero();
    try std.testing.expect(normalizedRotor(zero).eql(zero));
    const invalid = E4.Scalar.init(.{std.math.inf(f32)}).cast(E4.Full.EvenType);
    try std.testing.expect(normalizedRotor(invalid).eql(invalid));
}

test "planar rotor stays normalized for multiple angles" {
    inline for ([_]f64{ 0.0, std.math.pi / 3.0, -std.math.pi / 2.0, std.math.pi }) |angle| {
        const rotor = try planarRotor(f64, angle);
        const identity = rotor.gp(rotor.reverse());
        try std.testing.expect(nearlyEqual(identity.scalarCoeff(), 1.0, 1e-12));
        try std.testing.expect(nearlyEqual(identity.coeffNamed("e12"), 0.0, 1e-12));
    }
}

test "rotorFromTo maps normalized direction and preserves norm" {
    const E2 = multivector.Basis(f64, euclidean2);
    const from = E2.e(1).add(E2.e(2));
    const to = E2.e(2).sub(E2.e(1));

    const rotor = try rotorFromTo(from, to);
    const rotated_from = rotated(from, rotor);
    const from_unit = try normalize(from);
    const to_unit = try normalize(to);
    const rotated_unit = try normalize(rotated_from);

    try std.testing.expect(nearlyEqual(rotated_from.scalarProduct(rotated_from), from.scalarProduct(from), 1e-12));
    try std.testing.expect(nearlyEqual(rotated_unit.coeffNamed("e1"), to_unit.coeffNamed("e1"), 1e-12));
    try std.testing.expect(nearlyEqual(rotated_unit.coeffNamed("e2"), to_unit.coeffNamed("e2"), 1e-12));
    try std.testing.expect(nearlyEqual(from_unit.scalarProduct(from_unit), 1.0, 1e-12));
}

test "rotated supports non-2D algebras with compatible even rotors" {
    const sig3 = comptime blades.euclideanSignature(3);
    const Vec3 = multivector.Vector(f64, sig3);
    const Rotor3 = multivector.Rotor(f64, sig3);

    const vector = Vec3.init(.{ 1.0, 2.0, 3.0 });
    const identity = Rotor3.init(.{ 1.0, 0.0, 0.0, 0.0 });
    const result = rotated(vector, identity);

    try std.testing.expect(nearlyEqual(result.coeffNamed("e1"), 1.0, 1e-12));
    try std.testing.expect(nearlyEqual(result.coeffNamed("e2"), 2.0, 1e-12));
    try std.testing.expect(nearlyEqual(result.coeffNamed("e3"), 3.0, 1e-12));
}

test "3D fast path matches quaternion rotation" {
    const sig3 = comptime blades.euclideanSignature(3);
    const Vec3 = multivector.Vector(f64, sig3);
    const Rotor3 = multivector.Rotor(f64, sig3);
    const vector = Vec3.init(.{ 1.0, 0.5, -0.25 });
    // Quaternion (0.5, 0.5, 0.5, 0.5) maps to (s, -e12, e13, -e23).
    const rotor = Rotor3.init(.{ 0.5, -0.5, 0.5, -0.5 });
    const result = rotated(vector, rotor);

    const tx = 2.0 * (0.5 * vector.e3() - 0.5 * vector.e2());
    const ty = 2.0 * (0.5 * vector.e1() - 0.5 * vector.e3());
    const tz = 2.0 * (0.5 * vector.e2() - 0.5 * vector.e1());
    const expected = [_]f64{
        vector.e1() + 0.5 * tx + 0.5 * tz - 0.5 * ty,
        vector.e2() + 0.5 * ty + 0.5 * tx - 0.5 * tz,
        vector.e3() + 0.5 * tz + 0.5 * ty - 0.5 * tx,
    };

    try std.testing.expect(nearlyEqual(result.e1(), expected[0], 1e-12));
    try std.testing.expect(nearlyEqual(result.e2(), expected[1], 1e-12));
    try std.testing.expect(nearlyEqual(result.e3(), expected[2], 1e-12));
}

test "2D fast path preserves non-unit sandwich semantics" {
    const Vec2 = multivector.Vector(f64, euclidean2);
    const Rotor2 = multivector.Rotor(f64, euclidean2);
    const vector = Vec2.init(.{ 1.0, -2.0 });
    const rotor = Rotor2.init(.{ 2.0, -0.75 });
    const expected = rotor.gp(vector).gp(rotor.reverse()).gradePart(1);

    try std.testing.expect(rotated(vector, rotor).eql(expected));
}

test "3D fast path preserves non-unit sandwich semantics" {
    const sig3 = comptime blades.euclideanSignature(3);
    const Vec3 = multivector.Vector(f64, sig3);
    const Rotor3 = multivector.Rotor(f64, sig3);
    const vector = Vec3.init(.{ 1.0, -2.0, 0.5 });
    const rotor = Rotor3.init(.{ 2.0, -1.0, 0.75, -0.25 });
    const expected = rotor.gp(vector).gp(rotor.reverse()).gradePart(1);

    try std.testing.expect(rotated(vector, rotor).eql(expected));
}

test "normalizedRotor remains finite for 3D exponentiated bivectors" {
    const sig3 = comptime blades.euclideanSignature(3);
    const Basis3 = multivector.Basis(f32, sig3);
    const Rotor3 = multivector.Rotor(f32, sig3);
    const E3 = Basis3;

    const angle: f32 = 0.5;
    const b12 = E3.signedBlade("e12").scale(@cos(angle * 0.3));
    const b23 = E3.signedBlade("e23").scale(@sin(angle * 0.5));
    const b13 = E3.signedBlade("e13").scale(@cos(angle * 0.7));
    const B = b12.add(b23).add(b13);

    const exp_rotor = B.scale(-0.5).exp();
    var rotor = Rotor3.zero();
    inline for (Rotor3.blades, 0..) |mask, i| {
        rotor.coeffs[i] = exp_rotor.coeff(mask);
    }

    const rotor_normalized = normalizedRotor(rotor);
    const identity = rotor_normalized.gp(rotor_normalized.reverse());

    inline for (Rotor3.blades, 0..) |_, i| {
        try std.testing.expect(!std.math.isNan(rotor_normalized.coeffs[i]));
    }
    try std.testing.expect(nearlyEqual(identity.scalarCoeff(), 1.0, 1e-5));
}

test "From Zero to Geo 3.6 exercises" {
    // Cl(2,0,0) rotor algebra: i = e12, i² = -1
    const naming_options = comptime b: {
        var opts = blade_parsing.SignedBladeNamingOptions.fromSignature(euclidean2);
        opts.blade_aliases = &.{.{
            .name = "i",
            .spec = .{ .sign = .positive, .mask = e12_mask },
        }};
        break :b opts;
    };
    const e = expression.eval;

    const expectSameValue = struct {
        fn case(comptime actual_expr: []const u8, comptime expected_expr: []const u8) !void {
            const actual = e(f64, euclidean2, naming_options, actual_expr, .{});
            const expected = e(f64, euclidean2, naming_options, expected_expr, .{});
            inline for (@TypeOf(expected).blades) |mask| {
                try std.testing.expectApproxEqRel(expected.coeff(mask), actual.coeff(mask), 1e-12);
            }
        }
    }.case;

    // 1. 3 + 5i - 2 = 1 + 5i
    try expectSameValue("3 + 5i - 2", "1 + 5i");
    // 2. i(1 - 2i) = 2 + i
    try expectSameValue("i(1 - 2i)", "2 + i");
    // 3. (5 + i)(-2 + 3i) = -13 + 13i
    try expectSameValue("(5 + i)(-2 + 3i)", "-13 + 13i");
    // 4. (5 + i)(-2) - i = -10 - 3i
    try expectSameValue("(5 + i)(-2) - i", "-10 - 3i");
    // 5. (3 + 4i) / (2i) = 2 - 1.5i
    try expectSameValue("(3 + 4i) / (2i)", "2 - 1.5i");
    // 6. 25 / (3 + 4i) = 3 - 4i
    try expectSameValue("25 / (3 + 4i)", "3 - 4i");
    // 7. (13 - 2i) / (-5 - 12i) = -41/169 + 166/169·i
    try expectSameValue("(13 - 2i) / (-5 - 12i)", "(-41.0 / 169.0) + (166.0 / 169.0)i");
    // 8. (-7 + 3i) / (1 + 2i) = -1/5 + 17/5·i
    try expectSameValue("(-7 + 3i) / (1 + 2i)", "(-1.0 / 5.0) + (17.0 / 5.0)i");
}

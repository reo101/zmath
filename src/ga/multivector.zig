const std = @import("std");
const build_options = @import("build_options");
const blade_parsing = @import("blade_parsing.zig");
const blade_ops = @import("blades.zig");

/// Bitset representation of a basis blade.
pub const BladeMask = blade_ops.BladeMask;

/// Orientation sign attached to a canonicalized signed blade.
pub const OrientationSign = blade_ops.OrientationSign;
pub const SignedBladeParseError = blade_parsing.SignedBladeParseError;

/// Parsed signed blade as a sign plus canonical blade mask.
pub const SignedBladeSpec = blade_ops.SignedBladeSpec;
pub const MetricSignature = blade_ops.MetricSignature;

fn assertMaskWithinDimensions(comptime mask: BladeMask, comptime dimension: usize) void {
    if (mask >= blade_ops.bladeCount(dimension)) {
        @compileError("blade mask has bits set outside the algebra dimensions");
    }
}

fn ensureNumeric(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => {},
        else => @compileError("multivector coefficients must be numeric"),
    }
}

fn supportsNegativeCoefficients(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.signedness == .signed,
        .comptime_int, .float, .comptime_float => true,
        else => false,
    };
}

fn isFloatType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .comptime_float => true,
        else => false,
    };
}

fn isSignedIntType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.signedness == .signed,
        .comptime_int => true,
        else => false,
    };
}

fn isMultivectorType(comptime T: type) bool {
    return @hasDecl(T, "dimensions") and @hasDecl(T, "Coefficient") and @hasDecl(T, "blades") and @hasDecl(T, "metric_signature") and @hasField(T, "coeffs");
}

fn isSimdCoeffType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        else => false,
    };
}

fn canUseLaneWiseSimd(comptime T: type, comptime lane_count: usize) bool {
    return build_options.enable_simd_fast_paths and isSimdCoeffType(T) and lane_count >= 2 and lane_count <= 4;
}

fn coeffsToSimd(comptime T: type, comptime lane_count: usize, coeffs: [lane_count]T) @Vector(lane_count, T) {
    return @bitCast(coeffs);
}

fn simdToCoeffs(comptime T: type, comptime lane_count: usize, vector: @Vector(lane_count, T)) [lane_count]T {
    return @bitCast(vector);
}

fn scalarProductSigns(
    comptime T: type,
    comptime masks: []const BladeMask,
    comptime sig: MetricSignature,
) [masks.len]T {
    var signs: [masks.len]T = undefined;
    inline for (masks, 0..) |mask, index| {
        signs[index] = @as(T, blade_ops.geometricProductSignWithSignature(mask, mask, sig));
    }
    return signs;
}

fn assertCompatibleMultivector(comptime Lhs: type, comptime Rhs: type) void {
    if (!isMultivectorType(Rhs)) {
        @compileError("expected a multivector argument");
    }
    if (Rhs.dimensions != Lhs.dimensions) {
        @compileError("multivector dimensions must match");
    }
    if (Rhs.Coefficient != Lhs.Coefficient) {
        @compileError("cross-coefficient multivector operations are not implemented yet");
    }
}

fn coeffZero(comptime T: type) T {
    return @as(T, 0);
}

fn coeffOne(comptime T: type) T {
    return @as(T, 1);
}

fn reverseSignForGrade(comptime T: type, grade: usize) T {
    // Reverse contributes (-1)^(k*(k-1)/2) for grade k.
    if (grade == 0) return 1;
    return if (((grade * (grade - 1) / 2) & 1) == 0) 1 else -1;
}

fn signedUnit(comptime T: type, sign: OrientationSign) T {
    return switch (sign) {
        .positive => coeffOne(T),
        .negative => -coeffOne(T),
    };
}

fn isNegative(value: anytype) bool {
    const T = @TypeOf(value);
    if (isFloatType(T) or isSignedIntType(T)) {
        return value < 0;
    }
    return false;
}

fn absValue(value: anytype) @TypeOf(value) {
    return if (isNegative(value)) -value else value;
}

fn writeBlade(writer: *std.Io.Writer, comptime dimension: usize, mask: BladeMask) std.Io.Writer.Error!void {
    if (mask == 0) {
        try writer.writeAll("1");
        return;
    }

    try writer.writeByte('e');
    var bit_index: usize = 0;
    while (bit_index < dimension) : (bit_index += 1) {
        const bit = @as(BladeMask, 1) << @intCast(bit_index);
        if ((mask & bit) == 0) continue;
        try writer.print("{}", .{bit_index + 1});
    }
}

fn writeMultivectorImpl(
    writer: *std.Io.Writer,
    value: anytype,
) std.Io.Writer.Error!void {
    const M = @TypeOf(value);
    comptime {
        if (!isMultivectorType(M)) {
            @compileError("expected a multivector value");
        }
    }

    var wrote_any = false;

    for (M.blades, 0..) |mask, index| {
        const coeff_value = value.coeffs[index];
        if (coeff_value == coeffZero(M.Coefficient)) continue;

        if (wrote_any) {
            try writer.writeAll(if (isNegative(coeff_value)) " - " else " + ");
        } else if (isNegative(coeff_value)) {
            try writer.writeByte('-');
        }

        const magnitude = absValue(coeff_value);
        if (mask == 0) {
            try writer.print("{}", .{magnitude});
        } else {
            if (magnitude != coeffOne(M.Coefficient)) {
                try writer.print("{}*", .{magnitude});
            }
            try writeBlade(writer, M.dimensions, mask);
        }

        wrote_any = true;
    }

    if (!wrote_any) {
        try writer.writeByte('0');
    }
}

/// Returns the compact multivector type for a named signed blade.
pub fn SignedBladeType(comptime T: type, comptime name: []const u8, comptime sig: MetricSignature) type {
    ensureNumeric(T);
    const dimension = comptime sig.dimension();
    const spec = comptime blade_parsing.expectSignedBlade(name, dimension);
    return BasisBladeType(T, spec.mask, sig);
}

/// Returns the compact multivector type for a single blade mask.
pub fn BasisBladeType(comptime T: type, comptime mask: BladeMask, comptime sig: MetricSignature) type {
    const masks = [_]BladeMask{mask};
    return Multivector(T, masks[0..], sig);
}

fn signedBladeImpl(
    comptime T: type,
    comptime name: []const u8,
    comptime sig: MetricSignature,
) SignedBladeType(T, name, sig) {
    ensureNumeric(T);

    const dimension = comptime sig.dimension();

    const spec = comptime blade_parsing.expectSignedBlade(name, dimension);
    if (comptime spec.sign.isNegative() and !supportsNegativeCoefficients(T)) {
        @compileError("negative-oriented signed blades require a signed or floating-point coefficient type");
    }

    var result = basisBlade(T, spec.mask, sig);
    result.coeffs[0] = signedUnit(T, spec.sign);
    return result;
}

/// Generic sparse multivector whose storage is restricted to `blade_masks`.
///
/// A concrete metric signature is baked in via `sig`. Metric-aware methods
/// (`.gp()` and `.scalarProduct()`) use it by default.
pub fn Multivector(comptime T: type, comptime blade_masks: []const BladeMask, comptime sig: MetricSignature) type {
    ensureNumeric(T);
    const dimension = comptime sig.dimension();
    _ = blade_ops.bladeCount(dimension);

    if (!blade_ops.areStrictlyAscendingUnique(blade_masks)) {
        @compileError("blade masks must be strictly ascending and unique");
    }

    inline for (blade_masks) |mask| {
        assertMaskWithinDimensions(mask, dimension);
    }

    return struct {
        pub const Self = @This();
        pub const Coefficient = T;
        pub const dimensions = dimension;
        /// Baked-in metric signature used by metric-aware operations.
        pub const metric_signature = sig;
        /// Canonical blade masks stored by this carrier type.
        pub const blades = blade_masks;
        /// Number of coefficient slots physically stored by this carrier type.
        pub const stored_blade_count = blade_masks.len;
        /// Whether this carrier stores every blade in the algebra.
        pub const has_all_blades = blade_masks.len == blade_ops.bladeCount(dimension);
        /// Dense lookup table from blade mask to coefficient slot index.
        pub const blade_index_by_mask = blade_ops.bladeIndexByMask(dimension, blade_masks);
        /// Sentinel used in `blade_index_by_mask` for masks this carrier does not store.
        pub const missing_blade_index = blade_masks.len;

        /// Returns the multivector type for the same coefficient type and signature
        /// but with a different set of stored blade masks.
        pub fn Rebind(comptime new_masks: []const BladeMask) type {
            return Multivector(T, new_masks, sig);
        }

        /// Returns the related carrier type for a single blade mask.
        pub fn BasisBladeType(comptime mask: BladeMask) type {
            return Rebind(&.{mask});
        }

        /// Returns the related carrier type storing every blade in the algebra.
        pub fn FullType() type {
            return FullMultivector(T, sig);
        }

        /// Returns the related carrier type restricted to one grade.
        pub fn GradeType(comptime target_grade: usize) type {
            return KVector(T, target_grade, sig);
        }

        /// Returns the related carrier type restricted to even grades.
        pub fn EvenType() type {
            return EvenMultivector(T, sig);
        }

        /// Returns the related carrier type restricted to odd grades.
        pub fn OddType() type {
            return OddMultivector(T, sig);
        }

        /// Returns the related scalar carrier type.
        pub fn ScalarType() type {
            return GradeType(0);
        }

        /// Returns the related grade-1 vector carrier type.
        pub fn GAVectorType() type {
            return GradeType(1);
        }

        /// Returns the related grade-2 bivector carrier type.
        pub fn BivectorType() type {
            return GradeType(2);
        }

        coeffs: [blade_masks.len]T = std.mem.zeroes([blade_masks.len]T),

        /// Initializes the multivector from coefficients in `blades` order.
        pub fn init(coeffs: [blade_masks.len]T) Self {
            return .{ .coeffs = coeffs };
        }

        /// Returns the additive identity for this carrier type.
        pub fn zero() Self {
            return .{};
        }

        /// Constructs a compile-time signed blade using this carrier's coefficient type.
        pub fn signedBlade(comptime name: []const u8) SignedBladeType(T, name, sig) {
            return signedBladeImpl(T, name, sig);
        }

        /// Constructs a signed blade from runtime basis-vector indices.
        pub fn fromIndices(indices: []const usize) FullMultivector(T, sig) {
            return fullSignedBladeFromIndicesWithSignature(T, sig, indices);
        }

        /// Returns the coefficient of a compile-time blade mask.
        pub fn coeff(self: Self, comptime mask: BladeMask) T {
            comptime {
                if (mask >= blade_ops.bladeCount(dimension)) {
                    @compileError("blade mask outside the algebra dimensions");
                }
            }

            if (Self.has_all_blades) {
                return self.coeffs[mask];
            }

            const index = Self.blade_index_by_mask[mask];
            return if (index < Self.stored_blade_count) self.coeffs[index] else coeffZero(T);
        }

        /// Returns the coefficient of a runtime blade mask.
        pub fn coefficient(self: Self, mask: BladeMask) T {
            std.debug.assert(mask < blade_ops.bladeCount(dimension));

            if (Self.has_all_blades) {
                return self.coeffs[mask];
            }

            const index = Self.blade_index_by_mask[mask];
            return if (index < Self.stored_blade_count) self.coeffs[index] else coeffZero(T);
        }

        /// Returns the scalar coefficient.
        pub fn scalarCoeff(self: Self) T {
            return self.coefficient(0);
        }

        /// Returns `-self`.
        pub fn negate(self: Self) Self {
            if (comptime canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                return .init(simdToCoeffs(T, Self.stored_blade_count, -lanes));
            }

            var result = Self.zero();
            inline for (blade_masks, 0..) |_, index| {
                result.coeffs[index] = -self.coeffs[index];
            }
            return result;
        }

        /// Returns `self` scaled by `scalar`.
        pub fn scale(self: Self, scalar: T) Self {
            if (comptime canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                return .init(simdToCoeffs(T, Self.stored_blade_count, lanes * @as(@Vector(Self.stored_blade_count, T), @splat(scalar))));
            }

            var result = Self.zero();
            inline for (blade_masks, 0..) |_, index| {
                result.coeffs[index] = self.coeffs[index] * scalar;
            }
            return result;
        }

        /// Returns `self / scalar`.
        pub fn divide(self: Self, scalar: T) Self {
            if (comptime canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                return .init(simdToCoeffs(T, Self.stored_blade_count, lanes / @as(@Vector(Self.stored_blade_count, T), @splat(scalar))));
            }

            var result: Self = .zero();
            inline for (blade_masks, 0..) |_, index| {
                result.coeffs[index] = self.coeffs[index] / scalar;
            }
            return result;
        }

        /// Returns the sum of two multivectors.
        pub fn add(self: Self, rhs: anytype) AddResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = AddResultType(T, blade_masks, Rhs.blades, sig);
            if (comptime blade_ops.sameBladeSet(blade_masks, Rhs.blades) and canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const lhs_lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                const rhs_lanes = coeffsToSimd(T, Self.stored_blade_count, rhs.coeffs);
                return Result.init(simdToCoeffs(T, Self.stored_blade_count, lhs_lanes + rhs_lanes));
            }

            var result: Result = .zero();

            inline for (Result.blades, 0..) |mask, index| {
                result.coeffs[index] = self.coefficient(mask) + rhs.coefficient(mask);
            }

            return result;
        }

        /// Returns the difference of two multivectors.
        pub fn sub(self: Self, rhs: anytype) AddResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = AddResultType(T, blade_masks, Rhs.blades, sig);
            if (comptime blade_ops.sameBladeSet(blade_masks, Rhs.blades) and canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const lhs_lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                const rhs_lanes = coeffsToSimd(T, Self.stored_blade_count, rhs.coeffs);
                return Result.init(simdToCoeffs(T, Self.stored_blade_count, lhs_lanes - rhs_lanes));
            }

            var result = Result.zero();

            inline for (Result.blades, 0..) |mask, index| {
                result.coeffs[index] = self.coefficient(mask) - rhs.coefficient(mask);
            }

            return result;
        }

        /// Returns the geometric product of two multivectors.
        pub fn gp(self: Self, rhs: anytype) GeometricProductResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);
            return self.gpWithSignature(rhs, sig);
        }

        /// Returns the geometric product under an arbitrary `Cl(p, q, r)` signature.
        pub fn gpWithSignature(
            self: Self,
            rhs: anytype,
            comptime override_sig: MetricSignature,
        ) GeometricProductResultType(T, blade_masks, @TypeOf(rhs).blades, override_sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);
            comptime {
                if (override_sig.dimension() != dimension) {
                    @compileError("metric signature dimension must match multivector dimension");
                }
            }

            const Result = GeometricProductResultType(T, blade_masks, Rhs.blades, override_sig);
            var result = Result.zero();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    const result_mask = lhs_mask ^ rhs_mask;
                    const result_index = Result.blade_index_by_mask[result_mask];
                    const sign = blade_ops.geometricProductSignWithSignature(lhs_mask, rhs_mask, override_sig);

                    std.debug.assert(result_index < Result.stored_blade_count);
                    result.coeffs[result_index] += self.coeffs[lhs_index] * rhs.coeffs[rhs_index] * @as(T, sign);
                }
            }

            return result;
        }

        /// Returns the outer product of two multivectors.
        pub fn outerProduct(self: Self, rhs: anytype) OuterProductResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = OuterProductResultType(T, blade_masks, Rhs.blades, sig);
            var result = Result.zero();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if ((lhs_mask & rhs_mask) != 0) continue;

                    const result_mask = lhs_mask ^ rhs_mask;
                    const result_index = Result.blade_index_by_mask[result_mask];
                    const sign = blade_ops.geometricProductSign(lhs_mask, rhs_mask);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result.coeffs[result_index] += self.coeffs[lhs_index] * rhs.coeffs[rhs_index] * @as(T, sign);
                }
            }

            return result;
        }

        /// Returns the left contraction (A \rfloor B) of two multivectors.
        pub fn leftContraction(self: Self, rhs: anytype) LeftContractionResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = LeftContractionResultType(T, blade_masks, Rhs.blades, sig);
            var result = Result.zero();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if ((lhs_mask & rhs_mask) != lhs_mask) continue;

                    const result_mask = lhs_mask ^ rhs_mask;
                    const result_index = Result.blade_index_by_mask[result_mask];
                    const sign = blade_ops.geometricProductSignWithSignature(lhs_mask, rhs_mask, sig);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result.coeffs[result_index] += self.coeffs[lhs_index] * rhs.coeffs[rhs_index] * @as(T, sign);
                }
            }

            return result;
        }

        /// Returns the right contraction (A \lfloor B) of two multivectors.
        pub fn rightContraction(self: Self, rhs: anytype) RightContractionResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = RightContractionResultType(T, blade_masks, Rhs.blades, sig);
            var result = Result.zero();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if ((lhs_mask & rhs_mask) != rhs_mask) continue;

                    const result_mask = lhs_mask ^ rhs_mask;
                    const result_index = Result.blade_index_by_mask[result_mask];
                    const sign = blade_ops.geometricProductSignWithSignature(lhs_mask, rhs_mask, sig);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result.coeffs[result_index] += self.coeffs[lhs_index] * rhs.coeffs[rhs_index] * @as(T, sign);
                }
            }

            return result;
        }

        /// Returns the Hestenes dot product (A \cdot B) of two multivectors.
        ///
        /// The Hestenes dot product is defined as the grade |r - s| part of the
        /// geometric product of a grade-r blade and a grade-s blade. If either
        /// input is a scalar, the result is zero.
        pub fn dot(self: Self, rhs: anytype) DotProductResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = DotProductResultType(T, blade_masks, Rhs.blades, sig);
            var result = Result.zero();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                if (lhs_mask == 0) continue; // scalar dot anything is 0

                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if (rhs_mask == 0) continue; // anything dot scalar is 0

                    const lhs_grade = blade_ops.bladeGrade(lhs_mask);
                    const rhs_grade = blade_ops.bladeGrade(rhs_mask);
                    const target_grade = if (lhs_grade > rhs_grade) lhs_grade - rhs_grade else rhs_grade - lhs_grade;

                    const result_mask = lhs_mask ^ rhs_mask;
                    if (blade_ops.bladeGrade(result_mask) != target_grade) continue;

                    const result_index = Result.blade_index_by_mask[result_mask];
                    const sign = blade_ops.geometricProductSignWithSignature(lhs_mask, rhs_mask, sig);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result.coeffs[result_index] += self.coeffs[lhs_index] * rhs.coeffs[rhs_index] * @as(T, sign);
                }
            }

            return result;
        }

        /// Returns the scalar product between two multivectors.
        pub fn scalarProduct(self: Self, rhs: anytype) T {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);
            return self.scalarProductWithSignature(rhs, sig);
        }

        /// Returns the scalar product under an arbitrary `Cl(p, q, r)` signature.
        pub fn scalarProductWithSignature(
            self: Self,
            rhs: anytype,
            comptime override_sig: MetricSignature,
        ) T {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);
            comptime {
                if (override_sig.dimension() != dimension) {
                    @compileError("metric signature dimension must match multivector dimension");
                }
            }

            if (comptime blade_ops.sameBladeSet(blade_masks, Rhs.blades) and canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const signs = comptime scalarProductSigns(T, blade_masks, override_sig);
                const lhs_lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                const rhs_lanes = coeffsToSimd(T, Self.stored_blade_count, rhs.coeffs);
                const sign_lanes = coeffsToSimd(T, Self.stored_blade_count, signs);
                return @reduce(.Add, lhs_lanes * rhs_lanes * sign_lanes);
            }

            var result: T = coeffZero(T);
            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                const rhs_index = Rhs.blade_index_by_mask[lhs_mask];
                if (rhs_index == Rhs.missing_blade_index) continue;

                result += self.coeffs[lhs_index] * rhs.coeffs[rhs_index] * @as(T, blade_ops.geometricProductSignWithSignature(lhs_mask, lhs_mask, override_sig));
            }

            return result;
        }

        /// Returns the reverse involution.
        pub fn reverse(self: Self) Self {
            var result: Self = .zero();
            inline for (blade_masks, 0..) |mask, index| {
                const sign = reverseSignForGrade(T, blade_ops.bladeGrade(mask));
                result.coeffs[index] = self.coeffs[index] * sign;
            }
            return result;
        }

        /// Returns the grade involution.
        pub fn gradeInvolution(self: Self) Self {
            var result: Self = .zero();
            inline for (blade_masks, 0..) |mask, index| {
                const sign: T = if ((blade_ops.bladeGrade(mask) % 2) == 0) 1 else -1;
                result.coeffs[index] = self.coeffs[index] * sign;
            }
            return result;
        }

        /// Returns the Clifford conjugate.
        pub fn cliffordConjugate(self: Self) Self {
            return self.gradeInvolution().reverse();
        }

        /// Projects onto one grade and returns the corresponding `KVector`.
        pub fn gradePart(self: Self, comptime target_grade: usize) GradeType(target_grade) {
            if (target_grade > dimension) {
                @compileError("grade must not exceed the ambient dimension");
            }

            const Result = GradeType(target_grade);
            var result = Result.zero();

            inline for (blade_masks, 0..) |mask, index| {
                if (comptime blade_ops.bladeGrade(mask) == target_grade) {
                    const result_index = Result.blade_index_by_mask[mask];
                    if (result_index < Result.stored_blade_count) result.coeffs[result_index] = self.coeffs[index];
                }
            }

            return result;
        }

        /// Returns the scalar part as a Scalar multivector.
        pub fn scalarPart(self: Self) ScalarType() {
            return self.gradePart(0);
        }

        /// Returns whether two multivectors are coefficient-wise equal.
        pub fn eql(self: Self, rhs: anytype) bool {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            if (comptime blade_ops.sameBladeSet(blade_masks, Rhs.blades)) {
                if (comptime canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                    const lhs_lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffs);
                    const rhs_lanes = coeffsToSimd(T, Self.stored_blade_count, rhs.coeffs);
                    return @reduce(.And, lhs_lanes == rhs_lanes);
                }

                inline for (blade_masks, 0..) |_, index| {
                    if (self.coeffs[index] != rhs.coeffs[index]) return false;
                }
                return true;
            } else {
                const masks = blade_ops.unionBladeMasks(dimension, blade_masks, Rhs.blades);
                inline for (masks) |mask| {
                    if (self.coefficient(mask) != rhs.coefficient(mask)) return false;
                }

                return true;
            }
        }

        /// Writes the multivector through a std.Io writer interface.
        pub fn write(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeMultivectorImpl(writer, self);
        }

        /// Formats the multivector as a sum of scaled basis blades.
        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try self.write(writer);
        }
    };
}

/// Runtime signed-blade construction under an arbitrary `Cl(p, q, r)` signature.
pub fn fullSignedBladeFromIndicesWithSignature(
    comptime T: type,
    comptime sig: MetricSignature,
    indices: []const usize,
) FullMultivector(T, sig) {
    ensureNumeric(T);
    const dimension = comptime sig.dimension();

    if (comptime !supportsNegativeCoefficients(T)) {
        @compileError("runtime signed-blade construction requires signed or floating-point coefficients");
    }

    var spec = SignedBladeSpec{ .sign = .positive, .mask = 0 };
    for (indices) |one_based_index| {
        std.debug.assert(one_based_index >= 1 and one_based_index <= dimension);
        blade_ops.applyBasisIndexWithSignature(&spec, one_based_index, sig);
    }

    var result = FullMultivector(T, sig).zero();
    result.coeffs[@intCast(spec.mask)] = signedUnit(T, spec.sign);
    return result;
}

/// Result carrier for addition or subtraction between two multivectors.
pub fn AddResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const masks = blade_ops.unionBladeMasks(dimension, lhs_masks, rhs_masks);
    return Multivector(T, masks[0..], sig);
}

/// Result carrier for a geometric product.
pub fn GeometricProductResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const masks = blade_ops.geometricProductMasks(dimension, lhs_masks, rhs_masks);
    return Multivector(T, masks[0..], sig);
}

/// Result carrier for an outer product.
pub fn OuterProductResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const masks = blade_ops.outerProductMasks(dimension, lhs_masks, rhs_masks);
    return Multivector(T, masks[0..], sig);
}

/// Result carrier for a left contraction.
pub fn LeftContractionResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const masks = blade_ops.leftContractionMasks(dimension, lhs_masks, rhs_masks);
    return Multivector(T, masks[0..], sig);
}

/// Result carrier for a right contraction.
pub fn RightContractionResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const masks = blade_ops.rightContractionMasks(dimension, lhs_masks, rhs_masks);
    return Multivector(T, masks[0..], sig);
}

/// Result carrier for a Hestenes dot product.
pub fn DotProductResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([blade_ops.bladeCount(dimension)]bool);

    inline for (lhs_masks) |lhs_mask| {
        if (lhs_mask == 0) continue;
        inline for (rhs_masks) |rhs_mask| {
            if (rhs_mask == 0) continue;

            const lhs_grade = blade_ops.bladeGrade(lhs_mask);
            const rhs_grade = blade_ops.bladeGrade(rhs_mask);
            const target_grade = if (lhs_grade > rhs_grade) lhs_grade - rhs_grade else rhs_grade - lhs_grade;

            const result_mask = lhs_mask ^ rhs_mask;
            if (blade_ops.bladeGrade(result_mask) == target_grade) {
                marked[result_mask] = true;
            }
        }
    }

    const masks = blade_ops.collectMarkedMasks(dimension, marked);
    return Multivector(T, masks[0..], sig);
}

/// Constructs a unit blade with coefficient `1`.
pub fn basisBlade(comptime T: type, comptime mask: BladeMask, comptime sig: MetricSignature) BasisBladeType(T, mask, sig) {
    ensureNumeric(T);
    const dimension = comptime sig.dimension();

    comptime assertMaskWithinDimensions(mask, dimension);

    var result = BasisBladeType(T, mask, sig).zero();
    result.coeffs[0] = coeffOne(T);
    return result;
}

/// Constructs the one-based basis vector `e{one_based_index}`.
pub fn basisVector(
    comptime T: type,
    comptime one_based_index: usize,
    comptime sig: MetricSignature,
) BasisBladeType(T, blade_ops.basisVectorMask(sig.dimension(), one_based_index), sig) {
    const dimension = comptime sig.dimension();
    return basisBlade(T, blade_ops.basisVectorMask(dimension, one_based_index), sig);
}

/// Constructs a compile-time signed blade such as `e12` or `e_10_2`.
pub fn signedBlade(comptime T: type, comptime name: []const u8, comptime sig: MetricSignature) SignedBladeType(T, name, sig) {
    return signedBladeImpl(T, name, sig);
}

/// Writes any multivector value through a std.Io writer interface.
pub fn writeMultivector(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    try writeMultivectorImpl(writer, value);
}

/// Carrier type storing every blade in the algebra.
pub fn FullMultivector(comptime T: type, comptime sig: MetricSignature) type {
    return Multivector(T, &blade_ops.allBladeMasks(sig.dimension()), sig);
}

/// Carrier type restricted to one grade.
pub fn KVector(comptime T: type, comptime grade: usize, comptime sig: MetricSignature) type {
    return Multivector(T, &blade_ops.gradeBladeMasks(sig.dimension(), grade), sig);
}

/// Carrier type restricted to even grades.
pub fn EvenMultivector(comptime T: type, comptime sig: MetricSignature) type {
    return Multivector(T, &blade_ops.evenBladeMasks(sig.dimension()), sig);
}

/// Carrier type restricted to odd grades.
pub fn OddMultivector(comptime T: type, comptime sig: MetricSignature) type {
    return Multivector(T, &blade_ops.oddBladeMasks(sig.dimension()), sig);
}

/// Scalar carrier type.
pub fn Scalar(comptime T: type, comptime sig: MetricSignature) type {
    return KVector(T, 0, sig);
}

/// Grade-1 vector carrier type.
pub fn GAVector(comptime T: type, comptime sig: MetricSignature) type {
    return KVector(T, 1, sig);
}

/// Grade-2 bivector carrier type.
pub fn Bivector(comptime T: type, comptime sig: MetricSignature) type {
    return KVector(T, 2, sig);
}

/// Grade-3 trivector carrier type.
pub fn Trivector(comptime T: type, comptime sig: MetricSignature) type {
    return KVector(T, 3, sig);
}

/// Highest-grade pseudoscalar carrier type.
pub fn Pseudoscalar(comptime T: type, comptime sig: MetricSignature) type {
    return KVector(T, sig.dimension(), sig);
}

/// Even multivector carrier commonly used for rotors.
pub fn Rotor(comptime T: type, comptime sig: MetricSignature) type {
    return EvenMultivector(T, sig);
}

/// Namespace for basis-vector and signed-blade helpers in one algebra.
pub fn Basis(comptime T: type, comptime sig: MetricSignature) type {
    const dimension = comptime sig.dimension();
    return struct {
        /// The corresponding carrier type for the full algebra.
        pub const Full = FullMultivector(T, sig);

        /// The corresponding scalar carrier.
        pub const Scalar = Full.ScalarType();

        /// The corresponding grade-1 vector carrier.
        pub const Vector = Full.VectorType();

        /// The corresponding grade-2 bivector carrier.
        pub const Bivector = Full.BivectorType();

        /// Returns the one-based basis vector `e{one_based_index}`.
        pub fn e(
            comptime one_based_index: usize,
        ) BasisBladeType(T, blade_ops.basisVectorMask(dimension, one_based_index), sig) {
            return basisVector(T, one_based_index, sig);
        }

        /// Returns the blade mask for one basis vector.
        pub fn mask(comptime one_based_index: usize) BladeMask {
            return blade_ops.basisVectorMask(dimension, one_based_index);
        }

        /// Returns the blade mask for a list of basis-vector indices.
        pub fn blade(comptime one_based_indices: []const usize) BladeMask {
            return blade_ops.basisBladeMask(dimension, one_based_indices);
        }

        /// Returns a compile-time signed blade such as `e12` or `e_10_2`.
        pub fn signedBlade(comptime name: []const u8) SignedBladeType(T, name, sig) {
            return signedBladeImpl(T, name, sig);
        }

        /// Returns a runtime signed blade from a list of indices.
        pub fn fromIndices(indices: []const usize) FullMultivector(T, sig) {
            return fullSignedBladeFromIndicesWithSignature(T, sig, indices);
        }
    };
}

test "aliases and signed blades expose more than just plain vectors" {
    const E2 = Basis(i32, .euclidean(2));

    try std.testing.expect(E2.e(1).eql(GAVector(i32, .euclidean(2)).init(.{ 1, 0 })));
    try std.testing.expect(E2.e(2).eql(GAVector(i32, .euclidean(2)).init(.{ 0, 1 })));
    try std.testing.expect(E2.signedBlade("e12").eql(Bivector(i32, .euclidean(2)).init(.{1})));
    try std.testing.expect(E2.signedBlade("e21").eql(Bivector(i32, .euclidean(2)).init(.{-1})));
    try std.testing.expect(E2.signedBlade("e11").eql(Scalar(i32, .euclidean(2)).init(.{1})));
}

test "geometric products and involutions follow Euclidean VGA relations" {
    const E3 = Basis(f64, .euclidean(3));
    const e1 = E3.e(1);
    const e2 = E3.e(2);
    const e3 = E3.e(3);

    try std.testing.expect(e1.gp(e1).eql(Scalar(f64, .euclidean(3)).init(.{1})));
    try std.testing.expect(e1.gp(e2).gradePart(2).eql(Bivector(f64, .euclidean(3)).init(.{ 1, 0, 0 })));
    try std.testing.expect(e2.gp(e1).gradePart(2).eql(Bivector(f64, .euclidean(3)).init(.{ -1, 0, 0 })));
    try std.testing.expect(e1.outerProduct(e2).eql(Bivector(f64, .euclidean(3)).init(.{ 1, 0, 0 })));
    try std.testing.expect(e1.outerProduct(e3).eql(Bivector(f64, .euclidean(3)).init(.{ 0, 1, 0 })));

    const mv = FullMultivector(i32, .euclidean(3)).init(.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try std.testing.expect(mv.gradePart(0).eql(Scalar(i32, .euclidean(3)).init(.{1})));
    try std.testing.expect(mv.gradePart(1).eql(GAVector(i32, .euclidean(3)).init(.{ 2, 3, 5 })));
    try std.testing.expect(mv.reverse().eql(FullMultivector(i32, .euclidean(3)).init(.{ 1, 2, 3, -4, 5, -6, -7, -8 })));
    try std.testing.expect(mv.cliffordConjugate().eql(FullMultivector(i32, .euclidean(3)).init(.{ 1, -2, -3, -4, -5, -6, -7, 8 })));

    const e12 = e1.outerProduct(e2);
    try std.testing.expect(e1.leftContraction(e12).eql(e2));
    try std.testing.expect(e12.rightContraction(e2).eql(e1));
    try std.testing.expect(e12.leftContraction(e1).eql(Scalar(f64, .euclidean(3)).zero()));
}

test "writeMultivector renders through std.Io.Writer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = FullMultivector(i32, .euclidean(2)).init(.{ 2, -3, 0, 1 });
    try writeMultivector(&out.writer, value);
    try std.testing.expectEqualSlices(u8, "2 - 3*e1 + e12", out.written());
}

test "multivector.write matches format output path" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = GAVector(i32, .euclidean(2)).init(.{ 1, -2 });
    try value.write(&out.writer);
    try std.testing.expectEqualSlices(u8, "e1 - 2*e2", out.written());
}

test "signature-aware products support Cl(1,1)" {
    const sig: MetricSignature = .{ .p = 1, .q = 1 };
    const Vec = GAVector(f64, sig);
    const e1 = Vec.init(.{ 1.0, 0.0 });
    const e2 = Vec.init(.{ 0.0, 1.0 });

    try std.testing.expect(e1.gpWithSignature(e1, sig).eql(Scalar(f64, sig).init(.{1.0})));
    try std.testing.expect(e2.gpWithSignature(e2, sig).eql(Scalar(f64, sig).init(.{-1.0})));
    try std.testing.expectEqual(@as(f64, -1.0), e2.scalarProductWithSignature(e2, sig));
}

test "sparse coefficient lookup and equality across carrier sets" {
    const Scalar2 = Scalar(i32, .euclidean(2));
    const Bivec2 = Bivector(i32, .euclidean(2));
    const scalar = Scalar2.init(.{5});
    const biv = Bivec2.init(.{-2});
    const sum = scalar.add(biv);

    try std.testing.expectEqual(@as(i32, 5), sum.coeff(0));
    try std.testing.expectEqual(@as(i32, -2), sum.coeff(0b11));
    try std.testing.expectEqual(@as(i32, 0), sum.coefficient(0b01));
    try std.testing.expect(sum.eql(FullMultivector(i32, .euclidean(2)).init(.{ 5, 0, 0, -2 })));
}

test "basis namespace mask and blade helpers agree" {
    const E4 = Basis(i32, .euclidean(4));
    try std.testing.expectEqual(@as(BladeMask, 0b0100), E4.mask(3));
    try std.testing.expect(E4.fromIndices(&.{ 4, 1 }).eql(fullSignedBladeFromIndicesWithSignature(i32, .euclidean(4), &.{ 4, 1 })));
}

test "large-dimension full multivector geometric product with scalar identity" {
    const M8 = FullMultivector(f64, .euclidean(8));
    const scalar_one = Scalar(f64, .euclidean(8)).init(.{1.0});
    var coeffs = std.mem.zeroes([M8.blades.len]f64);

    inline for (M8.blades, 0..) |mask, index| {
        const grade = blade_ops.bladeGrade(mask);
        coeffs[index] = @as(f64, @floatFromInt((@as(i32, @intCast(index % 11)) - 5) * @as(i32, @intCast(grade + 1)))) / 7.0;
    }

    const value = M8.init(coeffs);
    const left = scalar_one.gp(value);
    const right = value.gp(scalar_one);

    try std.testing.expect(left.eql(value));
    try std.testing.expect(right.eql(value));
}

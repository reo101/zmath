const std = @import("std");
const blade_parsing = @import("blade_parsing.zig");
const blade_ops = @import("blades.zig");

/// Bitset representation of a basis blade.
pub const BladeMask = blade_ops.BladeMask;

/// Orientation sign attached to a canonicalized signed blade.
pub const OrientationSign = blade_ops.OrientationSign;
pub const SignatureClass = blade_ops.SignatureClass;
pub const SignedBladeParseError = blade_parsing.SignedBladeParseError;
pub const ExactCastError = error{ExcludedCoefficientNonZero};

/// Parsed signed blade as a sign plus canonical blade mask.
pub const SignedBladeSpec = blade_ops.SignedBladeSpec;
pub const MetricSignature = blade_ops.MetricSignature;

inline fn maskInt(mask: BladeMask) u64 {
    return BladeMask.toInt(mask);
}

inline fn maskIndex(mask: BladeMask) usize {
    return mask.index();
}

fn assertMaskWithinDimensions(comptime mask: BladeMask, comptime dimension: usize) void {
    if (maskInt(mask) >= blade_ops.bladeCount(dimension)) {
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

pub fn isMultivectorType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "dimensions") and @hasDecl(T, "Coefficient") and @hasDecl(T, "blades") and @hasDecl(T, "metric_signature") and @hasField(T, "coeffs"),
        else => false,
    };
}

pub fn ensureMultivector(comptime T: type) void {
    const prefix = "type " ++ @typeName(T) ++ " is not a valid multivector carrier: ";
    if (!@hasDecl(T, "dimensions")) @compileError(prefix ++ "missing public constant 'dimensions'");
    if (!@hasDecl(T, "Coefficient")) @compileError(prefix ++ "missing public constant 'Coefficient'");
    if (!@hasDecl(T, "blades")) @compileError(prefix ++ "missing public constant 'blades'");
    if (!@hasDecl(T, "metric_signature")) @compileError(prefix ++ "missing public constant 'metric_signature'");
    if (!@hasField(T, "coeffs")) @compileError(prefix ++ "missing field 'coeffs'");

    if (@TypeOf(T.dimensions) != usize) @compileError(prefix ++ "'dimensions' must be a usize");
    if (@TypeOf(T.blades) != []const BladeMask) @compileError(prefix ++ "'blades' must be a []const BladeMask");
    if (@TypeOf(T.metric_signature) != MetricSignature) @compileError(prefix ++ "'metric_signature' must be a MetricSignature");
}

fn isSimdCoeffType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        else => false,
    };
}

fn canUseLaneWiseSimd(comptime T: type, comptime lane_count: usize) bool {
    return isSimdCoeffType(T) and lane_count >= 2 and lane_count <= 4;
}

fn coeffsToSimd(comptime T: type, comptime lane_count: usize, coeffs: [lane_count]T) @Vector(lane_count, T) {
    return @bitCast(coeffs);
}

fn simdToCoeffs(comptime T: type, comptime lane_count: usize, vector: @Vector(lane_count, T)) [lane_count]T {
    return @bitCast(vector);
}

fn scalarProductSigns(comptime T: type, comptime masks: []const BladeMask, comptime sig: MetricSignature) [masks.len]T {
    var signs: [masks.len]T = undefined;
    inline for (masks, 0..) |mask, index| {
        signs[index] = @intFromEnum(mask.geometricProductClassWithSignature(mask, sig));
    }
    return signs;
}

fn countMarkedMasks(comptime dimension: usize, comptime marked: [blade_ops.bladeCount(dimension)]bool) usize {
    var count: usize = 0;
    inline for (marked) |is_marked| {
        if (is_marked) count += 1;
    }
    return count;
}

fn collectMarkedMasks(comptime dimension: usize, comptime marked: [blade_ops.bladeCount(dimension)]bool) [countMarkedMasks(dimension, marked)]BladeMask {
    var masks: [countMarkedMasks(dimension, marked)]BladeMask = undefined;
    var cursor: usize = 0;

    inline for (marked, 0..) |is_marked, mask| {
        if (!is_marked) continue;
        masks[cursor] = BladeMask.init(mask);
        cursor += 1;
    }

    return masks;
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

fn writeBlade(writer: *std.Io.Writer, comptime dimension: usize, mask: BladeMask) !void {
    if (mask.bitset.mask == 0) {
        try writer.writeAll("1");
        return;
    }

    try writer.writeByte('e');
    var bit_index: usize = 0;
    while (bit_index < dimension) : (bit_index += 1) {
        if (!mask.bitset.isSet(bit_index)) continue;
        try writer.print("{}", .{bit_index + 1});
    }
}

/// Writes any multivector value through a generic writer interface.
pub fn renderMultivector(writer: anytype, value: anytype) !void {
    comptime {
        if (!isMultivectorType(@TypeOf(value))) {
            @compileError("expected a multivector value");
        }
    }

    var writer_ptr: *std.Io.Writer = undefined;
    if (comptime @TypeOf(writer) == *std.Io.Writer) {
        writer_ptr = writer;
    } else if (comptime @hasDecl(@TypeOf(writer), "any")) {
        var any_writer = writer.any();
        writer_ptr = &any_writer;
    } else {
        // Fallback for types that might not follow the full interface
        // or where we can't easily get a type-erased pointer.
        try value.write(writer);
        return;
    }

    try value.write(writer_ptr);
}

/// Returns the compact multivector type for a named signed blade.
pub fn SignedBladeType(comptime T: type, comptime name: []const u8, comptime sig: MetricSignature) type {
    return SignedBladeTypeWithOptions(T, name, sig, blade_parsing.SignedBladeNamingOptions.fromSignature(sig));
}

/// Returns the compact multivector type for a named signed blade under parser options.
pub fn SignedBladeTypeWithOptions(
    comptime T: type,
    comptime name: []const u8,
    comptime sig: MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
) type {
    ensureNumeric(T);
    const dimension = comptime sig.dimension();
    const spec = comptime blade_parsing.parseSignedBlade(name, dimension, naming_options, true);
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
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
) SignedBladeTypeWithOptions(T, name, sig, naming_options) {
    ensureNumeric(T);

    const dimension = comptime sig.dimension();

    const spec = comptime blade_parsing.parseSignedBlade(name, dimension, naming_options, true);
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
    // Zig's memoization should handle this if the function is pure.
    // Let's ensure it stays pure by moving all logic into an anonymous struct.
    return struct {
        pub const Coefficient = T;
        pub const dimensions = sig.dimension();
        pub const metric_signature = sig;
        pub const blades = blade_masks;
        pub const stored_blade_count = blade_masks.len;
        pub const has_all_blades = blade_masks.len == blade_ops.bladeCount(sig.dimension());
        pub const blade_index_by_mask = blade_ops.bladeIndexByMask(sig.dimension(), blade_masks);
        pub const missing_blade_index = blade_masks.len;

        pub const use_simd = canUseLaneWiseSimd(T, stored_blade_count);
        pub const Storage = if (use_simd) @Vector(stored_blade_count, T) else [stored_blade_count]T;

        pub const Self = @This();

        /// Related carrier type for the same coefficient type and signature
        /// but with a different set of stored blade masks.
        pub fn Rebind(comptime new_masks: []const BladeMask) type {
            return Multivector(T, new_masks, sig);
        }

        /// Related carrier type for a single blade mask.
        pub fn BasisBladeType(comptime mask: BladeMask) type {
            return Rebind(&.{mask});
        }

        /// Related carrier type storing every blade in the algebra.
        pub const FullType = FullMultivector(T, sig);

        /// Related carrier type restricted to one grade.
        pub fn GradeType(comptime target_grade: usize) type {
            return KVector(T, target_grade, sig);
        }

        /// Related carrier type restricted to even grades.
        pub const EvenType = EvenMultivector(T, sig);

        /// Related carrier type restricted to odd grades.
        pub const OddType = OddMultivector(T, sig);

        /// Related scalar carrier type.
        pub const ScalarType = KVector(T, 0, sig);

        /// Related grade-1 vector carrier type.
        pub const VectorType = KVector(T, 1, sig);

        /// Related grade-2 bivector carrier type.
        pub const BivectorType = KVector(T, 2, sig);

        coeffs: Storage = if (use_simd) @as(Storage, @splat(0)) else std.mem.zeroes(Storage),

        /// Returns the coefficients as a standard array for indexing.
        /// This is a no-op if Storage is already an array, or a @bitCast if it's a @Vector.
        pub inline fn coeffsArray(self: Self) [stored_blade_count]T {
            return if (comptime use_simd) @bitCast(self.coeffs) else self.coeffs;
        }

        /// Initializes the multivector from coefficients in `blades` order.
        pub inline fn init(coeffs: [stored_blade_count]T) Self {
            return .{ .coeffs = if (use_simd) coeffsToSimd(T, stored_blade_count, coeffs) else coeffs };
        }

        /// Returns the additive identity for this carrier type.
        pub inline fn zero() Self {
            return .{};
        }

        /// Constructs a compile-time signed blade using this carrier's coefficient type.
        pub fn signedBlade(comptime name: []const u8) SignedBladeType(T, name, sig) {
            return signedBladeImpl(T, name, sig, blade_parsing.SignedBladeNamingOptions.fromSignature(sig));
        }

        /// Constructs a compile-time signed blade using naming options.
        pub fn signedBladeWithOptions(
            comptime name: []const u8,
            comptime naming_options: blade_parsing.SignedBladeNamingOptions,
        ) SignedBladeTypeWithOptions(T, name, sig, naming_options) {
            return signedBladeImpl(T, name, sig, naming_options);
        }

        /// Constructs a signed blade from runtime basis-vector indices.
        pub fn fromIndices(indices: []const usize) FullMultivector(T, sig) {
            return fullSignedBladeFromIndicesWithSignature(T, sig, indices);
        }

        /// Writes this multivector value through the standard Io writer interface.
        pub fn write(self: Self, writer: *std.Io.Writer) !void {
            var wrote_any = false;
            const coeffs_array = self.coeffsArray();

            for (blades, 0..) |mask, index| {
                const coeff_value = coeffs_array[index];
                if (coeff_value == coeffZero(T)) continue;

                if (wrote_any) {
                    try writer.writeAll(if (isNegative(coeff_value)) " - " else " + ");
                } else if (isNegative(coeff_value)) {
                    try writer.writeByte('-');
                }

                const mag = absValue(coeff_value);
                if (mask.bitset.mask == 0) {
                    try writer.print("{}", .{mag});
                } else {
                    if (mag != coeffOne(T)) {
                        try writer.print("{}*", .{mag});
                    }
                    try writeBlade(writer, dimensions, mask);
                }

                wrote_any = true;
            }

            if (!wrote_any) {
                try writer.writeByte('0');
            }
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            try self.write(writer);
        }

        /// Returns the coefficient of a (comptime/runtime) blade mask.
        pub fn coeff(self: Self, mask: BladeMask) T {
            const mask_idx = mask.index();
            if (@inComptime()) {
                if (comptime mask.toInt() >= blade_ops.bladeCount(dimensions)) {
                    @compileError("blade mask outside the algebra dimensions");
                }
            }

            const coeffs_array = self.coeffsArray();
            if (comptime Self.has_all_blades) {
                return coeffs_array[mask_idx];
            }

            const index = Self.blade_index_by_mask[mask_idx];
            if (index < Self.stored_blade_count) {
                return coeffs_array[index];
            } else {
                return coeffZero(T);
            }
        }

        /// Returns the coefficient for a signed-blade name such as `e12`.
        /// Uses signature-derived default naming options.
        pub fn coeffNamed(self: Self, comptime name: []const u8) T {
            return self.coeffNamedWithOptions(name, blade_parsing.SignedBladeNamingOptions.fromSignature(sig));
        }

        /// Returns the coefficient for a signed-blade name under naming options.
        pub fn coeffNamedWithOptions(
            self: Self,
            comptime name: []const u8,
            comptime options: blade_parsing.SignedBladeNamingOptions,
        ) T {
            const spec = comptime blade_parsing.parseSignedBlade(name, dimensions, options, true);
            return self.coeff(spec.mask) * @intFromEnum(spec.sign);
        }

        /// Returns the scalar coefficient.
        pub fn scalarCoeff(self: Self) T {
            return self.coeff(BladeMask.init(0));
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
                result.coeffs[index] = switch (@typeInfo(T)) {
                    .int, .comptime_int => @divTrunc(self.coeffs[index], scalar),
                    else => self.coeffs[index] / scalar,
                };
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

            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            inline for (Result.blades, 0..) |mask, index| {
                result_coeffs[index] = self.coeff(mask) + rhs.coeff(mask);
            }

            return Result.init(result_coeffs);
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

            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            inline for (Result.blades, 0..) |mask, index| {
                result_coeffs[index] = self.coeff(mask) - rhs.coeff(mask);
            }

            return Result.init(result_coeffs);
        }

        /// Returns the geometric product of two multivectors.
        pub fn gp(self: Self, rhs: anytype) GeometricProductResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);
            const Result = GeometricProductResultType(T, blade_masks, Rhs.blades, sig);
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            const lhs_coeffs = self.coeffsArray();
            const rhs_coeffs = rhs.coeffsArray();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    const result_index = comptime Result.blade_index_by_mask[BladeMask.init(lhs_mask.toInt() ^ rhs_mask.toInt()).index()];
                    const sign = lhs_mask.geometricProductClassWithSignature(rhs_mask, sig);

                    std.debug.assert(result_index < Result.stored_blade_count);
                    result_coeffs[result_index] += lhs_coeffs[lhs_index] * rhs_coeffs[rhs_index] * @intFromEnum(sign);
                }
            }

            return Result.init(result_coeffs);
        }

        /// Returns the outer product of two multivectors.
        pub fn outerProduct(self: Self, rhs: anytype) OuterProductResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = OuterProductResultType(T, blade_masks, Rhs.blades, sig);
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            const lhs_coeffs = self.coeffsArray();
            const rhs_coeffs = rhs.coeffsArray();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if ((lhs_mask.toInt() & rhs_mask.toInt()) != 0) continue;

                    const result_index = comptime Result.blade_index_by_mask[BladeMask.init(lhs_mask.toInt() ^ rhs_mask.toInt()).index()];
                    const sign = lhs_mask.geometricProductSign(rhs_mask);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result_coeffs[result_index] += lhs_coeffs[lhs_index] * rhs_coeffs[rhs_index] * @intFromEnum(sign);
                }
            }

            return Result.init(result_coeffs);
        }

        /// Returns the left contraction (A \rfloor B) of two multivectors.
        pub fn leftContraction(self: Self, rhs: anytype) LeftContractionResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = LeftContractionResultType(T, blade_masks, Rhs.blades, sig);
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            const lhs_coeffs = self.coeffsArray();
            const rhs_coeffs = rhs.coeffsArray();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if ((lhs_mask.toInt() & rhs_mask.toInt()) != lhs_mask.toInt()) continue;

                    const result_index = comptime Result.blade_index_by_mask[lhs_mask.bitset.xorWith(rhs_mask.bitset).mask];
                    const sign = lhs_mask.geometricProductClassWithSignature(rhs_mask, sig);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result_coeffs[result_index] += lhs_coeffs[lhs_index] * rhs_coeffs[rhs_index] * @intFromEnum(sign);
                }
            }

            return Result.init(result_coeffs);
        }

        /// Returns the right contraction (A \lfloor B) of two multivectors.
        pub fn rightContraction(self: Self, rhs: anytype) RightContractionResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            const Result = RightContractionResultType(T, blade_masks, Rhs.blades, sig);
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            const lhs_coeffs = self.coeffsArray();
            const rhs_coeffs = rhs.coeffsArray();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                inline for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if ((lhs_mask.toInt() & rhs_mask.toInt()) != rhs_mask.toInt()) continue;

                    const result_index = comptime Result.blade_index_by_mask[lhs_mask.bitset.xorWith(rhs_mask.bitset).mask];
                    const sign = lhs_mask.geometricProductClassWithSignature(rhs_mask, sig);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result_coeffs[result_index] += lhs_coeffs[lhs_index] * rhs_coeffs[rhs_index] * @intFromEnum(sign);
                }
            }

            return Result.init(result_coeffs);
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
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);

            if (comptime Result.stored_blade_count == 0) {
                return Result.init(result_coeffs);
            }

            const lhs_coeffs = self.coeffsArray();
            const rhs_coeffs = rhs.coeffsArray();

            for (blade_masks, 0..) |lhs_mask, lhs_index| {
                if (lhs_mask.bitset.mask == 0) continue; // scalar dot anything is 0

                for (Rhs.blades, 0..) |rhs_mask, rhs_index| {
                    if (rhs_mask.bitset.mask == 0) continue; // anything dot scalar is 0

                    const lhs_grade = blade_ops.bladeGrade(lhs_mask);
                    const rhs_grade = blade_ops.bladeGrade(rhs_mask);
                    const target_grade = if (lhs_grade > rhs_grade) lhs_grade - rhs_grade else rhs_grade - lhs_grade;

                    const result_mask = BladeMask.init(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask);
                    const result_grade = blade_ops.bladeGrade(result_mask);
                    if (result_grade != target_grade) continue;

                    const result_index = Result.blade_index_by_mask[result_mask.index()];
                    const sign = lhs_mask.geometricProductClassWithSignature(rhs_mask, sig);
                    std.debug.assert(result_index < Result.stored_blade_count);
                    result_coeffs[result_index] += lhs_coeffs[lhs_index] * rhs_coeffs[rhs_index] * @intFromEnum(sign);
                }
            }

            return Result.init(result_coeffs);
        }

        /// Returns the scalar product between two multivectors.
        pub fn scalarProduct(self: Self, rhs: anytype) T {
            const Rhs = @TypeOf(rhs);
            comptime assertCompatibleMultivector(Self, Rhs);

            if (comptime blade_ops.sameBladeSet(blade_masks, Rhs.blades) and canUseLaneWiseSimd(T, Self.stored_blade_count)) {
                const signs = comptime scalarProductSigns(T, blade_masks, sig);
                const lhs_lanes = coeffsToSimd(T, Self.stored_blade_count, self.coeffsArray());
                const rhs_lanes = coeffsToSimd(T, Self.stored_blade_count, rhs.coeffsArray());
                const sign_lanes = coeffsToSimd(T, Self.stored_blade_count, signs);
                return @reduce(.Add, lhs_lanes * rhs_lanes * sign_lanes);
            }

            var result: T = coeffZero(T);
            const lhs_coeffs = self.coeffsArray();
            const rhs_coeffs = rhs.coeffsArray();

            inline for (blade_masks, 0..) |lhs_mask, lhs_index| {
                const rhs_index = Rhs.blade_index_by_mask[lhs_mask.index()];
                if (rhs_index == Rhs.missing_blade_index) continue;

                result += lhs_coeffs[lhs_index] * rhs_coeffs[rhs_index] * @intFromEnum(lhs_mask.geometricProductClassWithSignature(lhs_mask, sig));
            }

            return result;
        }

        /// Returns the reverse involution.
        pub fn reverse(self: Self) Self {
            var result_coeffs = std.mem.zeroes([stored_blade_count]T);
            const coeffs_array = self.coeffsArray();

            inline for (blade_masks, 0..) |mask, index| {
                const sign = reverseSignForGrade(T, blade_ops.bladeGrade(mask));
                result_coeffs[index] = coeffs_array[index] * sign;
            }
            return Self.init(result_coeffs);
        }

        /// Returns the grade involution.
        pub fn gradeInvolution(self: Self) Self {
            var result_coeffs = std.mem.zeroes([stored_blade_count]T);
            const coeffs_array = self.coeffsArray();

            inline for (blade_masks, 0..) |mask, index| {
                const sign: T = if ((blade_ops.bladeGrade(mask) % 2) == 0) 1 else -1;
                result_coeffs[index] = coeffs_array[index] * sign;
            }
            return Self.init(result_coeffs);
        }

        /// Returns the Clifford conjugate.
        pub fn cliffordConjugate(self: Self) Self {
            return self.gradeInvolution().reverse();
        }

        /// Projects onto one grade and returns the corresponding `KVector`.
        pub fn gradePart(self: Self, comptime target_grade: usize) GradeType(target_grade) {
            if (target_grade > dimensions) {
                @compileError("grade must not exceed the ambient dimension");
            }

            const Result = GradeType(target_grade);
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);
            const coeffs_array = self.coeffsArray();

            inline for (blade_masks, 0..) |mask, index| {
                if (comptime blade_ops.bladeGrade(mask) == target_grade) {
                    const result_index = comptime Result.blade_index_by_mask[mask.index()];
                    if (result_index < Result.stored_blade_count) result_coeffs[result_index] = coeffs_array[index];
                }
            }

            return Result.init(result_coeffs);
        }

        /// Returns the scalar part as a Scalar multivector.
        pub fn scalarPart(self: Self) ScalarType {
            return self.gradePart(0);
        }

        /// Returns the Euclidean norm squared of this multivector.
        pub fn normSquared(self: Self) T {
            return self.scalarProduct(self);
        }

        /// Returns the Euclidean norm (magnitude) of this multivector.
        pub fn norm(self: Self) T {
            return @sqrt(@abs(self.scalarProduct(self)));
        }

        /// Returns the Euclidean norm (magnitude) of this multivector.
        pub fn magnitude(self: Self) T {
            return self.norm();
        }

        /// Returns the Hodge dual of this multivector relative to the pseudoscalar.
        /// For degenerate metrics (like PGA), this falls back to a Poincaré dual (coefficient swap).
        pub fn dual(self: Self) DualResultType(T, blade_masks, sig) {
            const Result = DualResultType(T, blade_masks, sig);
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]T);
            const pseudoscalar_mask = blade_ops.bladeCount(dimensions) - 1;
            const self_coeffs = self.coeffsArray();

            inline for (blade_masks, 0..) |mask, i| {
                const target_mask = mask.bitset.mask ^ pseudoscalar_mask;
                const result_idx = Result.blade_index_by_mask[target_mask];
                const sign = mask.geometricProductSign(BladeMask.init(pseudoscalar_mask));
                result_coeffs[result_idx] = self_coeffs[i] * @intFromEnum(sign);
            }
            return Result.init(result_coeffs);
        }

        /// Converts this multivector to another multivector type in the same algebra.
        /// Missing blades are set to zero, extra blades in the source are ignored.
        pub fn cast(self: Self, comptime To: type) To {
            if (sig.p != To.metric_signature.p or sig.q != To.metric_signature.q or sig.r != To.metric_signature.r) {
                @compileError("cannot cast multivector to a different metric signature");
            }
            var result_coeffs = std.mem.zeroes([To.stored_blade_count]T);
            const self_coeffs = self.coeffsArray();

            inline for (blade_masks, 0..) |mask, i| {
                const to_idx = To.blade_index_by_mask[mask.index()];
                if (to_idx < To.stored_blade_count) {
                    result_coeffs[to_idx] = self_coeffs[i];
                }
            }
            return To.init(result_coeffs);
        }

        /// Converts this multivector to another carrier in the same algebra,
        /// asserting that no non-zero coefficients are dropped.
        pub fn castExactOrError(self: Self, comptime To: type) ExactCastError!To {
            if (sig.p != To.metric_signature.p or sig.q != To.metric_signature.q or sig.r != To.metric_signature.r) {
                @compileError("cannot cast multivector to a different metric signature");
            }
            if (T != To.Coefficient) {
                @compileError("cannot exactly cast multivector to a different coefficient type");
            }

            var result_coeffs = std.mem.zeroes([To.stored_blade_count]T);
            const self_coeffs = self.coeffsArray();

            inline for (blade_masks, 0..) |mask, i| {
                const to_idx = To.blade_index_by_mask[mask.index()];
                if (to_idx < To.stored_blade_count) {
                    result_coeffs[to_idx] = self_coeffs[i];
                } else if (self_coeffs[i] != 0) {
                    return error.ExcludedCoefficientNonZero;
                }
            }
            return To.init(result_coeffs);
        }

        /// Converts this multivector to another carrier in the same algebra,
        /// panicking if any non-zero coefficients would be dropped.
        pub fn castExact(self: Self, comptime To: type) To {
            return self.castExactOrError(To) catch @panic("exact multivector cast would drop a non-zero coefficient");
        }

        /// Returns the outer product (wedge) of two multivectors.
        pub fn wedge(self: Self, rhs: anytype) @TypeOf(self.outerProduct(rhs)) {
            return self.outerProduct(rhs);
        }

        /// Returns the regressive product (join) of two multivectors.
        /// A v B = dual(dual(A) ^ dual(B))
        pub fn join(self: Self, rhs: anytype) JoinResultType(T, blade_masks, @TypeOf(rhs).blades, sig) {
            const a_dual = self.dual();
            const b_dual = rhs.dual();
            const meet_dual = a_dual.wedge(b_dual);
            return meet_dual.dual();
        }

        /// Returns the multiplicative inverse of this multivector if it exists.
        /// Only valid for elements where self.gp(self.reverse()) is a non-zero scalar.
        pub fn inverse(self: Self) ?Self {
            const rev = self.reverse();
            const denominator_mv = self.gp(rev);
            const denominator = denominator_mv.scalarCoeff();

            // Check if it's a pure scalar and non-zero
            const Denom = @TypeOf(denominator_mv);
            const denom_coeffs = denominator_mv.coeffsArray();
            inline for (Denom.blades, 0..) |mask, i| {
                if (mask.bitset.mask != 0) {
                    if (denom_coeffs[i] != 0) return null;
                }
            }

            if (denominator == 0) return null;
            return rev.scale(1.0 / denominator);
        }

        /// Returns the exponential exp(self).
        /// Currently only implemented for bivectors in Euclidean space
        /// where B^2 is a negative scalar.
        pub fn exp(self: Self) Self {
            // For a bivector B, if B^2 = -theta^2 (scalar), then
            // exp(B) = cos(theta) + (B/theta) * sin(theta)
            const b2_mv = self.gp(self);
            const b2 = b2_mv.scalarCoeff();

            // Check if it's a pure scalar
            var is_pure_scalar = true;
            const B2Mv = @TypeOf(b2_mv);
            const b2_coeffs = b2_mv.coeffsArray();
            inline for (B2Mv.blades, 0..) |mask, i| {
                if (mask.bitset.mask != 0) {
                    if (b2_coeffs[i] != 0) is_pure_scalar = false;
                }
            }

            if (is_pure_scalar and b2 <= 0) {
                const theta = @sqrt(-b2);

                if (theta == 0) {
                    var res_coeffs = std.mem.zeroes([stored_blade_count]T);
                    if (Self.blade_index_by_mask[0] < stored_blade_count) res_coeffs[Self.blade_index_by_mask[0]] = 1;
                    return Self.init(res_coeffs);
                }

                const c = @cos(theta);
                const s = @sin(theta);

                // Result = cos(theta) + (B/theta) * sin(theta)
                var res_coeffs = std.mem.zeroes([stored_blade_count]T);
                if (Self.blade_index_by_mask[0] < stored_blade_count) res_coeffs[Self.blade_index_by_mask[0]] = c;

                inline for (blade_masks, 0..) |mask, i| {
                    if (mask.bitset.mask != 0) {
                        res_coeffs[i] = self.coeff(mask) * (s / theta);
                    }
                }

                return Self.init(res_coeffs);
            }

            // Fallback for general case or non-Euclidean could be power series,
            // but that's complex for a general sparse carrier.
            @panic("exp() only implemented for Euclidean bivectors with B^2 <= 0");
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
                const masks = blade_ops.unionBladeMasks(dimensions, blade_masks, Rhs.blades);
                inline for (masks) |mask| {
                    if (self.coeff(mask) != rhs.coeff(mask)) return false;
                }

                return true;
            }
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

    var spec = SignedBladeSpec{ .sign = .positive, .mask = BladeMask.init(0) };
    for (indices) |basis_index| {
        std.debug.assert(1 <= basis_index and basis_index <= dimension);
        blade_ops.applyBasisIndexWithSignature(&spec, basis_index, sig);
    }

    var result = FullMultivector(T, sig).zero();
    result.coeffs[spec.mask.index()] = signedUnit(T, spec.sign);
    return result;
}

/// Result carrier for a join operation.
pub fn JoinResultType(
    comptime T: type,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const result_masks = blade_ops.dualMasks(dimension, &blade_ops.outerProductMasks(dimension, &blade_ops.dualMasks(dimension, lhs_masks), &blade_ops.dualMasks(dimension, rhs_masks)));
    return Multivector(T, &result_masks, sig);
}

/// Result carrier for a dual operation.
pub fn DualResultType(
    comptime T: type,
    comptime masks: []const BladeMask,
    comptime sig: MetricSignature,
) type {
    const dimension = comptime sig.dimension();
    const result_masks = blade_ops.dualMasks(dimension, masks);
    return Multivector(T, &result_masks, sig);
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
        if (lhs_mask.bitset.mask == 0) continue;
        inline for (rhs_masks) |rhs_mask| {
            if (rhs_mask.bitset.mask == 0) continue;

            const lhs_grade = blade_ops.bladeGrade(lhs_mask);
            const rhs_grade = blade_ops.bladeGrade(rhs_mask);
            const target_grade = if (lhs_grade > rhs_grade) lhs_grade - rhs_grade else rhs_grade - lhs_grade;

            const result_mask = BladeMask.init(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask);
            if (blade_ops.bladeGrade(result_mask) == target_grade) {
                marked[result_mask.index()] = true;
            }
        }
    }

    const masks = collectMarkedMasks(dimension, marked);
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
    return signedBladeImpl(T, name, sig, blade_parsing.SignedBladeNamingOptions.fromSignature(sig));
}

/// Constructs a compile-time signed blade under parser options.
pub fn signedBladeWithOptions(
    comptime T: type,
    comptime name: []const u8,
    comptime sig: MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
) SignedBladeTypeWithOptions(T, name, sig, naming_options) {
    return signedBladeImpl(T, name, sig, naming_options);
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
pub fn Vector(comptime T: type, comptime sig: MetricSignature) type {
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
    return BasisWithNamingOptions(T, sig, blade_parsing.SignedBladeNamingOptions.fromSignature(sig));
}

/// Namespace for basis-vector and signed-blade helpers in one algebra under naming options.
pub fn BasisWithNamingOptions(
    comptime T: type,
    comptime sig: MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
) type {
    const dimension = comptime sig.dimension();
    return struct {
        /// The corresponding carrier type for the full algebra.
        pub const Full = FullMultivector(T, sig);

        /// The corresponding scalar carrier.
        pub const Scalar = Full.ScalarType;

        /// The corresponding grade-1 vector carrier.
        pub const Vector = Full.VectorType;

        /// The corresponding grade-2 bivector carrier.
        pub const Bivector = Full.BivectorType;

        /// Returns the basis vector for the configured named basis index.
        pub fn e(
            comptime named_index: usize,
        ) BasisBladeType(T, blade_ops.basisVectorMask(dimension, blade_parsing.resolveNamedBasisIndex(named_index, dimension, naming_options, true)), sig) {
            const one_based_index = comptime blade_parsing.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
            return basisVector(T, one_based_index, sig);
        }

        /// Returns the `ordinal` basis vector from one signature class (`positive`/`negative`/`degenerate`).
        pub fn basisVectorByClass(
            comptime class: SignatureClass,
            comptime ordinal: usize,
        ) BasisBladeType(T, blade_ops.basisVectorMask(dimension, expectBasisVectorByClass(class, ordinal)), sig) {
            const one_based_index = comptime expectBasisVectorByClass(class, ordinal);
            return basisVector(T, one_based_index, sig);
        }

        fn expectBasisVectorByClass(comptime class: SignatureClass, comptime ordinal: usize) usize {
            const spans = naming_options.basis_spans;

            const span = spans.spanFor(class) orelse @compileError(std.fmt.comptimePrint(
                "no `{s}` basis-vector span configured for this algebra",
                .{@tagName(class)},
            ));

            if (ordinal == 0) {
                @compileError("basis-vector ordinal is one-based and must be >= 1");
            }

            const span_len = span.end - span.start + 1;
            if (ordinal > span_len) {
                @compileError(std.fmt.comptimePrint(
                    "basis-vector ordinal {d} exceeds `{s}` span length {d}",
                    .{ ordinal, @tagName(class), span_len },
                ));
            }

            const named_index = span.start + (ordinal - 1);
            return comptime blade_parsing.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
        }

        /// Returns the blade mask for one configured named basis index.
        pub fn mask(comptime named_index: usize) BladeMask {
            return blade_ops.basisVectorMask(
                dimension,
                blade_parsing.resolveNamedBasisIndex(named_index, dimension, naming_options, true),
            );
        }

        /// Returns the blade mask for configured named basis indices.
        pub fn blade(comptime named_indices: []const usize) BladeMask {
            var result_mask: BladeMask = .init(0);

            inline for (named_indices) |named_index| {
                const one_based_index = comptime blade_parsing.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
                const bit = blade_ops.basisVectorMask(dimension, one_based_index);
                if (result_mask.bitset.intersectWith(bit.bitset).mask != 0) {
                    @compileError("repeated basis vectors cancel in the geometric product and are not represented by a blade mask");
                }
                result_mask.bitset = result_mask.bitset.unionWith(bit.bitset);
            }

            return result_mask;
        }

        /// Returns a compile-time signed blade such as `e12` or `e_10_2`.
        pub fn signedBlade(comptime name: []const u8) SignedBladeTypeWithOptions(T, name, sig, naming_options) {
            return signedBladeImpl(T, name, sig, naming_options);
        }

        /// Returns a compile-time signed blade under explicit naming options.
        pub fn signedBladeWithOptions(
            comptime name: []const u8,
            comptime override_options: blade_parsing.SignedBladeNamingOptions,
        ) SignedBladeTypeWithOptions(T, name, sig, override_options) {
            return signedBladeImpl(T, name, sig, override_options);
        }

        /// Returns a runtime signed blade from a list of indices.
        pub fn fromIndices(indices: []const usize) FullMultivector(T, sig) {
            return fullSignedBladeFromIndicesWithSignature(T, sig, indices);
        }
    };
}

test "aliases and signed blades expose more than just plain vectors" {
    const E2 = Basis(i32, .euclidean(2));

    try std.testing.expect(E2.e(1).eql(Vector(i32, .euclidean(2)).init(.{ 1, 0 })));
    try std.testing.expect(E2.e(2).eql(Vector(i32, .euclidean(2)).init(.{ 0, 1 })));
    try std.testing.expect(E2.signedBlade("e12").eql(Bivector(i32, .euclidean(2)).init(.{1})));
    try std.testing.expect(E2.signedBlade("e21").eql(Bivector(i32, .euclidean(2)).init(.{-1})));
    try std.testing.expect(E2.signedBlade("e11").eql(Scalar(i32, .euclidean(2)).init(.{1})));
}

test "basis helper e applies named index options" {
    const sig: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
    const spans = comptime blade_ops.BasisIndexSpans.init(.{
        .positive = blade_ops.BasisIndexSpan.range(1, 3),
        .degenerate = blade_ops.BasisIndexSpan.singleton(0),
    });
    const options = comptime blade_parsing.SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    const E = BasisWithNamingOptions(f64, sig, options);
    try std.testing.expect(E.e(0).eql(basisVector(f64, 4, sig)));
}

test "basis helper can select nth basis vector by signature class" {
    const sig: MetricSignature = .{ .p = 2, .q = 1, .r = 1 };
    const E = Basis(f64, sig);

    try std.testing.expect(E.basisVectorByClass(.positive, 2).eql(E.e(2)));
    try std.testing.expect(E.basisVectorByClass(.negative, 1).eql(E.e(3)));
    try std.testing.expect(E.basisVectorByClass(.degenerate, 1).eql(E.e(4)));

    const named = BasisWithNamingOptions(f64, sig, .{
        .basis_spans = .init(.{
            .degenerate = .singleton(0),
            .positive = .range(1, 2),
            .negative = .singleton(3),
        }),
    });
    try std.testing.expect(named.basisVectorByClass(.degenerate, 1).eql(named.e(0)));
}

test "geometric products and involutions follow Euclidean VGA relations" {
    const E3 = Basis(f64, .euclidean(3));
    const e1 = E3.e(1);
    const e2 = E3.e(2);
    const e3 = E3.e(3);

    try std.testing.expect(e1.gp(e1).eql(E3.Scalar.init(.{1})));
    try std.testing.expect(e1.gp(e2).gradePart(2).eql(E3.Bivector.init(.{ 1, 0, 0 })));
    try std.testing.expect(e2.gp(e1).gradePart(2).eql(E3.Bivector.init(.{ -1, 0, 0 })));
    try std.testing.expect(e1.outerProduct(e2).eql(E3.Bivector.init(.{ 1, 0, 0 })));
    try std.testing.expect(e1.outerProduct(e3).eql(E3.Bivector.init(.{ 0, 1, 0 })));

    const mv = FullMultivector(i32, .euclidean(3)).init(.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try std.testing.expect(mv.gradePart(0).eql(@TypeOf(mv).ScalarType.init(.{1})));
    try std.testing.expect(mv.gradePart(1).eql(@TypeOf(mv).VectorType.init(.{ 2, 3, 5 })));
    try std.testing.expect(mv.reverse().eql(@TypeOf(mv).FullType.init(.{ 1, 2, 3, -4, 5, -6, -7, -8 })));
    try std.testing.expect(mv.cliffordConjugate().eql(@TypeOf(mv).FullType.init(.{ 1, -2, -3, -4, -5, -6, -7, 8 })));

    const e12 = e1.outerProduct(e2);
    try std.testing.expect(e1.leftContraction(e12).eql(e2));
    try std.testing.expect(e12.rightContraction(e2).eql(e1));
    try std.testing.expect(e12.leftContraction(e1).eql(@TypeOf(e1).ScalarType.zero()));
}

test "writeMultivector renders through std.Io.Writer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = FullMultivector(i32, .euclidean(2)).init(.{ 2, -3, 0, 1 });
    try renderMultivector(&out.writer, value);
    try std.testing.expectEqualSlices(u8, "2 - 3*e1 + e12", out.written());
}

test "multivector.write matches format output path" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const value = Vector(i32, .euclidean(2)).init(.{ 1, -2 });
    try out.writer.print("{f}", .{value});
    try std.testing.expectEqualSlices(u8, "e1 - 2*e2", out.written());
}

test "signature-aware products support Cl(1,1)" {
    const sig: MetricSignature = .{ .p = 1, .q = 1 };
    const Vec = Vector(f64, sig);
    const e1 = Vec.init(.{ 1.0, 0.0 });
    const e2 = Vec.init(.{ 0.0, 1.0 });

    try std.testing.expect(e1.gp(e1).eql(@TypeOf(e1).ScalarType.init(.{1.0})));
    try std.testing.expect(e2.gp(e2).eql(@TypeOf(e2).ScalarType.init(.{-1.0})));
    try std.testing.expectEqual(@as(f64, -1.0), e2.scalarProduct(e2));
}

test "multivector arithmetic helpers cover sparse and dense carriers" {
    const sig = comptime MetricSignature.euclidean(3);
    const Vec3 = Vector(i32, sig);
    const Scalar3 = Scalar(i32, sig);

    const sparse_masks = comptime BladeMask.initMany(.{ 0b001, 0b100 });
    const SparseVec = Multivector(i32, sparse_masks[0..], sig);

    const v = Vec3.init(.{ 2, -1, 3 });
    try std.testing.expect(v.negate().eql(Vec3.init(.{ -2, 1, -3 })));
    try std.testing.expect(v.scale(2).eql(Vec3.init(.{ 4, -2, 6 })));
    try std.testing.expect(v.scale(2).divide(2).eql(v));
    try std.testing.expectEqual(@as(i32, 0), v.scalarCoeff());

    const s = Scalar3.init(.{5});
    const sum = v.add(s);
    try std.testing.expectEqual(@as(i32, 5), sum.scalarCoeff());
    try std.testing.expectEqual(@as(i32, 2), sum.coeffNamed("e1"));
    try std.testing.expectEqual(@as(i32, -1), sum.coeffNamed("e2"));
    try std.testing.expectEqual(@as(i32, 3), sum.coeffNamed("e3"));

    const diff = sum.sub(v);
    try std.testing.expect(diff.eql(s));

    const sparse = SparseVec.init(.{ 2, 4 });
    try std.testing.expectEqual(@as(i32, 20), sparse.scalarProduct(sparse));
    try std.testing.expectEqual(@as(i32, 20), sparse.scalarProduct(sparse));
    try std.testing.expectEqual(@as(i32, 16), v.scalarProduct(sparse));
}

test "product variants agree with expected blade algebra identities" {
    const sig = comptime MetricSignature.euclidean(3);
    const E3 = Basis(i32, sig);
    const e1 = E3.e(1);
    const e2 = E3.e(2);
    const e3 = E3.e(3);
    const scalar_zero = E3.Scalar.init(.{0});
    const scalar_one = E3.Scalar.init(.{1});

    const e12 = e1.outerProduct(e2);
    const e23 = e2.outerProduct(e3);
    const e123 = e12.outerProduct(e3);

    try std.testing.expect(e1.gp(e1).eql(scalar_one));
    try std.testing.expect(e1.outerProduct(e1).eql(scalar_zero));

    try std.testing.expect(e1.leftContraction(e12).eql(e2));
    try std.testing.expect(e12.rightContraction(e2).eql(e1));
    try std.testing.expect(e1.rightContraction(e12).eql(scalar_zero));
    try std.testing.expect(e12.leftContraction(e1).eql(scalar_zero));

    try std.testing.expect(e1.dot(e2).eql(E3.Scalar.zero()));
    try std.testing.expect(e1.dot(e1).eql(scalar_one));
    try std.testing.expect(e1.dot(e12).eql(e2));
    try std.testing.expect(e12.dot(e1).eql(e2.negate()));
    try std.testing.expect(scalar_one.dot(e1).eql(scalar_zero));
    try std.testing.expect(e1.dot(scalar_one).eql(scalar_zero));

    try std.testing.expectEqual(@as(i32, -1), e12.scalarProduct(e12));
    try std.testing.expectEqual(@as(i32, -1), e23.scalarProduct(e23));
    try std.testing.expect(e123.gp(e123).eql(E3.Scalar.init(.{-1})));
}

test "sparse coefficient lookup and equality across carrier sets" {
    const Scalar2 = Scalar(i32, .euclidean(2));
    const biv = Scalar2.BivectorType.init(.{-2});
    const scalar = Scalar2.init(.{5});
    const sum = scalar.add(biv);

    try std.testing.expectEqual(@as(i32, 5), sum.coeff(BladeMask.init(0)));
    try std.testing.expectEqual(@as(i32, -2), sum.coeff(BladeMask.init(0b11)));
    try std.testing.expectEqual(@as(i32, 0), sum.coeff(BladeMask.init(0b01)));
    try std.testing.expect(sum.eql(@TypeOf(sum).FullType.init(.{ 5, 0, 0, -2 })));
}

test "basis namespace mask and blade helpers agree" {
    const E4 = Basis(i32, .euclidean(4));
    try std.testing.expectEqual(BladeMask.init(0b0100), E4.mask(3));
    try std.testing.expect(E4.fromIndices(&.{ 4, 1 }).eql(fullSignedBladeFromIndicesWithSignature(i32, .euclidean(4), &.{ 4, 1 })));
}

test "large-dimension full multivector geometric product with scalar identity" {
    const M8 = FullMultivector(f64, .euclidean(12));
    const scalar_one = M8.ScalarType.init(.{1.0});
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

test "vga helpers use SIMD storage when appropriate" {
    const Vec2 = Vector(f32, .euclidean(2));
    const v = Vec2.init(.{ 1.0, 2.0 });

    // Check that the underlying storage is a @Vector of the correct size and type.
    switch (@typeInfo(@TypeOf(v.coeffs))) {
        .vector => |info| {
            try std.testing.expectEqual(@as(usize, 2), info.len);
            try std.testing.expectEqual(f32, info.child);
        },
        else => {
            try std.testing.expect(false);
        },
    }
}

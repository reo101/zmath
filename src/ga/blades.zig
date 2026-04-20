const std = @import("std");

const parser = @import("blade_parsing.zig");

/// Bitset representation of a basis blade.
///
/// Bit `0` corresponds to `e1`, bit `1` to `e2`, and so on.
pub const BladeMaskBytes = 2;
pub const BladeMaskBitSet = std.bit_set.IntegerBitSet(BladeMaskBytes * 8);
pub const BladeMaskInt = BladeMaskBitSet.MaskInt;

/// Utilities for working with blade masks.
pub const BladeMask = struct {
    bitset: BladeMaskBitSet,

    comptime {
        const this_size = @bitSizeOf(@This());
        const target_size = @bitSizeOf(BladeMaskInt);
        if (this_size != target_size) {
            @compileError(std.fmt.comptimePrint("BladeMask must be exactly the same size as its underlying integer representation ({} != {})", .{ this_size, target_size }));
        }
    }

    /// Explicit constructor for blade masks from integer bit patterns.
    pub inline fn init(value: anytype) BladeMask {
        return .{ .bitset = .{ .mask = @as(BladeMaskInt, @intCast(value)) } };
    }

    /// Constructs a blade mask with exactly one bit set at `bit_index`.
    pub inline fn initOneBit(bit_index: usize) BladeMask {
        var bitset: BladeMaskBitSet = .{ .mask = 0 };
        bitset.set(bit_index);
        return .{ .bitset = bitset };
    }

    /// Constructs a blade mask with bits `[0, count)` set.
    pub inline fn initLowBits(count: usize) BladeMask {
        return if (count == 0)
            .init(0)
        else
            .init((@as(BladeMaskInt, 1) << @intCast(count)) - 1);
    }

    /// Convenience constructor for tuple/array literals of raw masks.
    pub inline fn initMany(comptime values: anytype) [values.len]BladeMask {
        var masks: [values.len]BladeMask = undefined;
        inline for (values, 0..) |value, i| {
            masks[i] = init(value);
        }
        return masks;
    }

    pub inline fn toInt(mask: BladeMask) BladeMaskInt {
        return mask.bitset.mask;
    }

    pub inline fn index(mask: BladeMask) usize {
        return @intCast(mask.toInt());
    }

    pub inline fn eql(self: BladeMask, other: BladeMask) bool {
        return self.toInt() == other.toInt();
    }

    /// Parses a signed blade name and returns its mask when the sign is positive.
    ///
    /// Since this helper returns only `BladeMask`, it rejects negative spellings
    /// (for example `e21`) with a comptime error instead of discarding the sign.
    pub fn parse(comptime name: []const u8) !BladeMask {
        comptime {
            const checked = parser.expectSignedBlade(name, max_supported_basis_vectors);
            if (checked.sign != .positive) {
                @compileError("BladeMask.parse expects a positive signed-blade spelling");
            }
        }

        const spec = try parser.parseSignedBlade(name, max_supported_basis_vectors);
        return spec.mask;
    }

    /// Parses a signed blade name within `dimensions` and returns its mask when
    /// the sign is positive.
    ///
    /// Since this helper returns only `BladeMask`, it rejects negative spellings
    /// with a comptime error instead of discarding the sign.
    pub fn parseForDimensions(comptime name: []const u8, comptime dimensions: usize) !BladeMask {
        comptime {
            const checked = parser.expectSignedBlade(name, dimensions);
            if (checked.sign != .positive) {
                @compileError("BladeMask.parseForDimensions expects a positive signed-blade spelling");
            }
        }

        const spec = try parser.parseSignedBlade(name, dimensions);
        return spec.mask;
    }

    /// Parses a signed blade name and panics at comptime on parse failure.
    ///
    /// This helper also asserts the parsed sign is positive before returning the
    /// mask, because the sign is intentionally not part of the return value.
    pub fn parsePanicking(comptime name: []const u8) BladeMask {
        const spec = comptime parser.expectSignedBlade(name, max_supported_basis_vectors);
        if (spec.sign != .positive) {
            @compileError("BladeMask.parsePanicking expects a positive signed-blade spelling");
        }
        return spec.mask;
    }

    /// Parses a signed blade name for `dimensions` and panics at comptime on
    /// parse failure.
    ///
    /// This helper also asserts the parsed sign is positive before returning the
    /// mask, because the sign is intentionally not part of the return value.
    pub fn parseForDimensionsPanicking(comptime name: []const u8, comptime dimensions: usize) BladeMask {
        const spec = comptime parser.expectSignedBlade(name, dimensions);
        if (spec.sign != .positive) {
            @compileError("BladeMask.parseForDimensionPanicking expects a positive signed-blade spelling");
        }
        return spec.mask;
    }

    /// Returns the orientation sign produced by the Euclidean geometric product with `rhs`.
    pub fn geometricProductSign(lhs: BladeMask, rhs: BladeMask) OrientationSign {
        var sign: OrientationSign = .positive;
        var remaining = lhs.toInt();

        while (remaining != 0) {
            const bit_index = @ctz(remaining);
            remaining &= remaining - 1;

            const lower_bits = if (bit_index == 0)
                @as(BladeMaskInt, 0)
            else
                (@as(BladeMaskInt, 1) << @intCast(bit_index)) - 1;

            const lower_rhs = rhs.bitset.intersectWith(.{ .mask = lower_bits });
            if ((lower_rhs.count() % 2) != 0) {
                sign.flip();
            }
        }

        return sign;
    }

    /// Returns the signature class produced by the `Cl(p, q, r)` geometric product with `rhs`.
    pub fn geometricProductClassWithSignature(lhs: BladeMask, rhs: BladeMask, sig: MetricSignature) SignatureClass {
        var sign: SignatureClass = .positive;
        var remaining = lhs.toInt();
        while (remaining != 0) {
            const bit_index = @ctz(remaining);
            remaining &= remaining - 1;

            const lower_bits = if (bit_index == 0)
                @as(BladeMaskInt, 0)
            else
                (@as(BladeMaskInt, 1) << @intCast(bit_index)) - 1;

            const lower_rhs = rhs.bitset.intersectWith(.{ .mask = lower_bits });
            if ((lower_rhs.count() % 2) != 0) {
                sign = sign.mul(.negative);
            }

            if (rhs.bitset.isSet(bit_index)) {
                sign = sign.mul(sig.basisSquareClass(bit_index + 1));
            }
        }

        return sign;
    }
};

/// Signature class of one basis-vector square in `Cl(p, q, r)`.
pub const SignatureClass = enum(i2) {
    positive = 1,
    negative = -1,
    degenerate = 0,

    pub fn isNegative(self: SignatureClass) bool {
        return self == .negative;
    }

    pub fn mul(self: SignatureClass, rhs: SignatureClass) SignatureClass {
        return if (self == .degenerate or rhs == .degenerate)
            .degenerate
        else if (self == rhs)
            .positive
        else
            .negative;
    }
};

/// Orientation sign attached to a canonicalized signed blade.
pub const OrientationSign = enum(i2) {
    negative = -1,
    positive = 1,

    /// Flips to the opposite orientation sign in place.
    pub fn flip(self: *OrientationSign) void {
        self.* = self.flipped();
    }

    /// Returns the opposite orientation sign.
    pub fn flipped(self: OrientationSign) OrientationSign {
        return switch (self) {
            .negative => .positive,
            .positive => .negative,
        };
    }

    /// Returns whether the sign is negative.
    pub fn isNegative(self: OrientationSign) bool {
        return self == .negative;
    }

    pub fn mul(self: OrientationSign, rhs: OrientationSign) OrientationSign {
        return if (self == rhs)
            .positive
        else
            .negative;
    }
};

/// Canonical signed blade as an orientation sign plus blade mask.
pub const SignedBladeSpec = struct {
    sign: OrientationSign,
    mask: BladeMask,
};

/// Inclusive named-index span of basis-vector indices.
///
/// Spans may include `0` (for names like `e0`) and are mapped onto
/// internal sequential mask indices in signature-class order.
pub const BasisIndexSpan = struct {
    start: usize,
    end: usize,

    pub fn range(start: usize, end: usize) BasisIndexSpan {
        return .{ .start = start, .end = end };
    }

    pub fn singleton(index: usize) BasisIndexSpan {
        return range(index, index);
    }

    pub fn contains(self: BasisIndexSpan, one_based_index: usize) bool {
        return self.start <= one_based_index and one_based_index <= self.end;
    }

    pub fn singleIndex(self: BasisIndexSpan) ?usize {
        return if (self.start == self.end) self.start else null;
    }

    pub fn len(self: BasisIndexSpan) usize {
        return self.end - self.start + 1;
    }
};

/// Basis-index spans partitioned by metric signature category.
pub const BasisIndexSpans = struct {
    pub const ByClass = std.enums.EnumFieldStruct(SignatureClass, ?BasisIndexSpan, @as(?BasisIndexSpan, null));
    pub const ValidationError = error{InvalidBasisConfiguration};

    by_class: ByClass = .{},

    pub fn init(by_class: ByClass) BasisIndexSpans {
        return .{ .by_class = by_class };
    }

    pub fn hasAnySpan(self: BasisIndexSpans) bool {
        inline for (std.meta.tags(SignatureClass)) |class| {
            if (self.spanFor(class) != null) return true;
        }
        return false;
    }

    pub fn fromSignature(comptime sig: MetricSignature) BasisIndexSpans {
        _ = sig.dimensions();

        var by_class: ByClass = .{};
        var next_start: usize = 1;
        inline for (std.meta.tags(SignatureClass)) |class| {
            const count = switch (class) {
                .positive => sig.p,
                .negative => sig.q,
                .degenerate => sig.r,
            };
            if (count != 0) {
                switch (class) {
                    inline else => |tag| @field(by_class, @tagName(tag)) = .range(next_start, next_start + count - 1),
                }
                next_start += count;
            }
        }

        return init(by_class);
    }

    pub fn spanFor(self: BasisIndexSpans, class: SignatureClass) ?BasisIndexSpan {
        return switch (class) {
            inline else => |tag| @field(self.by_class, @tagName(tag)),
        };
    }

    pub fn contains(self: BasisIndexSpans, one_based_index: usize) bool {
        inline for (std.meta.tags(SignatureClass)) |class| {
            if (containsIn(self.spanFor(class), one_based_index)) return true;
        }
        return false;
    }

    pub fn mappedBasisCount(self: BasisIndexSpans) usize {
        var count: usize = 0;
        inline for (std.meta.fields(ByClass)) |field| {
            if (@field(self.by_class, field.name)) |span| {
                count += span.len();
            }
        }
        return count;
    }

    /// Resolves one named basis index to an internal sequential one-based
    /// basis index used by blade masks.
    pub fn resolveNamedBasisIndex(self: BasisIndexSpans, named_index: usize, comptime dimensions: usize) ?usize {
        @setEvalBranchQuota(10_000);
        self.assertValidForDimensions(dimensions);

        var next_internal_index: usize = 1;
        for (std.meta.tags(SignatureClass)) |class| {
            if (self.spanFor(class)) |span| {
                const span_len = span.len();

                if (span.contains(named_index)) {
                    return next_internal_index + (named_index - span.start);
                }

                next_internal_index += span_len;
            }
        }

        return null;
    }

    /// Runtime-capable counterpart to `resolveNamedBasisIndex`.
    pub fn resolveNamedBasisIndexRuntime(self: BasisIndexSpans, named_index: usize, dimensions: usize) ValidationError!?usize {
        try self.validateForDimensions(dimensions);

        var next_internal_index: usize = 1;
        for (std.meta.tags(SignatureClass)) |class| {
            if (self.spanFor(class)) |span| {
                const span_len = span.len();

                if (span.contains(named_index)) {
                    return next_internal_index + (named_index - span.start);
                }

                next_internal_index += span_len;
            }
        }

        return null;
    }

    /// Resolves one internal sequential one-based basis index back to its
    /// configured named index.
    pub fn resolveInternalToNamed(self: BasisIndexSpans, internal_index: usize, comptime dimensions: usize) ?usize {
        @setEvalBranchQuota(10_000);
        self.assertValidForDimensions(dimensions);

        var next_internal_index: usize = 1;
        for (std.meta.tags(SignatureClass)) |class| {
            if (self.spanFor(class)) |span| {
                const span_len = span.len();

                if (internal_index >= next_internal_index and internal_index < next_internal_index + span_len) {
                    return span.start + (internal_index - next_internal_index);
                }

                next_internal_index += span_len;
            }
        }

        return null;
    }

    /// Runtime-capable counterpart to `resolveInternalToNamed`.
    pub fn resolveInternalToNamedRuntime(self: BasisIndexSpans, internal_index: usize, dimensions: usize) ValidationError!?usize {
        try self.validateForDimensions(dimensions);

        var next_internal_index: usize = 1;
        for (std.meta.tags(SignatureClass)) |class| {
            if (self.spanFor(class)) |span| {
                const span_len = span.len();

                if (internal_index >= next_internal_index and internal_index < next_internal_index + span_len) {
                    return span.start + (internal_index - next_internal_index);
                }

                next_internal_index += span_len;
            }
        }

        return null;
    }

    pub fn assertValidForDimensions(self: BasisIndexSpans, comptime dimensions: usize) void {
        const classes = comptime std.meta.tags(SignatureClass);

        inline for (classes) |class| {
            validateSpan(self, class, dimensions);
        }

        inline for (classes, 0..) |lhs_class, lhs_index| {
            inline for (classes[(lhs_index + 1)..]) |rhs_class| {
                validateNoOverlap(self, lhs_class, rhs_class);
            }
        }

        validateMappedBasisCount(self, dimensions);
    }

    /// Runtime-capable counterpart to `assertValidForDimensions`.
    pub fn validateForDimensions(self: BasisIndexSpans, dimensions: usize) ValidationError!void {
        for (std.meta.tags(SignatureClass)) |class| {
            if (self.spanFor(class)) |range| {
                if (range.start > range.end) return error.InvalidBasisConfiguration;
            }
        }

        const classes = std.meta.tags(SignatureClass);
        for (classes, 0..) |lhs_class, lhs_index| {
            const left_span = self.spanFor(lhs_class) orelse continue;
            for (classes[(lhs_index + 1)..]) |rhs_class| {
                const right_span = self.spanFor(rhs_class) orelse continue;
                if (spansOverlap(left_span, right_span)) return error.InvalidBasisConfiguration;
            }
        }

        if (self.mappedBasisCount() > dimensions) return error.InvalidBasisConfiguration;
    }

    fn containsIn(span: ?BasisIndexSpan, one_based_index: usize) bool {
        return if (span) |range| range.contains(one_based_index) else false;
    }

    fn validateSpan(self: BasisIndexSpans, comptime class: SignatureClass, comptime dimensions: usize) void {
        _ = dimensions;
        const label = comptime @tagName(class);
        if (self.spanFor(class)) |range| {
            if (!(range.start <= range.end)) {
                const message = comptime std.fmt.comptimePrint(
                    "{s} basis span must satisfy start <= end",
                    .{label},
                );
                if (@inComptime()) {
                    @compileError(message);
                }
                std.debug.panic("{s}", .{message});
            }
        }
    }

    fn validateMappedBasisCount(self: BasisIndexSpans, comptime dimensions: usize) void {
        @setEvalBranchQuota(10_000);
        const mapped_basis_count = self.mappedBasisCount();

        if (mapped_basis_count > dimensions) {
            if (@inComptime()) {
                @compileError("configured basis spans cover more named indices than the algebra dimensions");
            }
            std.debug.panic(
                "configured basis spans cover {} named indices, exceeding dimensions {}",
                .{ mapped_basis_count, dimensions },
            );
        }
    }

    fn spansOverlap(lhs: BasisIndexSpan, rhs: BasisIndexSpan) bool {
        return lhs.start <= rhs.end and rhs.start <= lhs.end;
    }

    fn validateNoOverlap(
        self: BasisIndexSpans,
        comptime lhs_class: SignatureClass,
        comptime rhs_class: SignatureClass,
    ) void {
        const lhs_label = comptime @tagName(lhs_class);
        const rhs_label = comptime @tagName(rhs_class);

        const left_span = self.spanFor(lhs_class) orelse return;
        const right_span = self.spanFor(rhs_class) orelse return;

        if (spansOverlap(left_span, right_span)) {
            const message = comptime std.fmt.comptimePrint(
                "{s} basis span overlaps {s} span",
                .{ lhs_label, rhs_label },
            );
            if (@inComptime()) {
                @compileError(message);
            }
            std.debug.panic("{s}", .{message});
        }
    }
};

/// Compile-time metric signature for `Cl(p, q, r)`.
///
/// In the Clifford algebra `Cl(p, q, r)`:
/// - `p` = number of basis vectors that square to **+1** (positive signature)
/// - `q` = number of basis vectors that square to **-1** (negative signature)
/// - `r` = number of basis vectors that square to **0** (degenerate/null signature)
///
/// The algebra has dimensions `p + q + r`. Common examples:
/// - `Cl(3, 0, 0)` = standard 3D Euclidean GA
/// - `Cl(4, 1, 0)` = conformal geometric algebra (VGA)
/// - `Cl(3, 0, 1)` = projective geometric algebra (PGA)
/// - `Cl(1, 1, 0)` = Minkowski spacetime
pub const MetricSignature = struct {
    p: usize,
    q: usize = 0,
    r: usize = 0,

    /// Constructs `Cl(p, q, r)` and validates that the dimensions fits `BladeMask`.
    pub fn init(comptime p: usize, comptime q: usize, comptime r: usize) MetricSignature {
        const sig: MetricSignature = .{ .p = p, .q = q, .r = r };
        _ = sig.dimensions();
        return sig;
    }

    /// Constructs the Euclidean signature `Cl(d, 0, 0)`.
    pub fn euclidean(comptime d: usize) MetricSignature {
        return init(d, 0, 0);
    }

    /// Returns `p + q + r` for this metric signature.
    pub fn dimensions(self: MetricSignature) usize {
        const total_dimensions = self.p + self.q + self.r;
        validateDimensions(total_dimensions);
        return total_dimensions;
    }

    /// Returns the square class of one internal one-based basis index.
    pub fn basisSquareClass(self: MetricSignature, basis_index: usize) SignatureClass {
        const sig_dimensions = self.dimensions();
        std.debug.assert(1 <= basis_index and basis_index <= sig_dimensions);

        return if (basis_index <= self.p)
            .positive
        else if (basis_index <= self.p + self.q)
            .negative
        else
            .degenerate;
    }

    /// Applies one internal one-based basis index to an in-progress signed blade.
    pub fn applyBasisIndex(self: MetricSignature, spec: *SignedBladeSpec, basis_index: usize) void {
        const sig_dimensions = self.dimensions();
        std.debug.assert(1 <= basis_index and basis_index <= sig_dimensions);
        const bit: BladeMask = .initOneBit(basis_index - 1);
        if (spec.mask.geometricProductClassWithSignature(bit, self).isNegative()) {
            spec.sign.flip();
        }
        spec.mask.bitset = spec.mask.bitset.xorWith(bit.bitset);
    }
};

/// Largest ambient dimensions that fits inside `BladeMask`.
pub const max_supported_basis_vectors = @bitSizeOf(BladeMask) - 1;

/// Errors that can arise while rendering a blade mask through a writer interface.
pub const WriteBladeMaskError = std.Io.Writer.Error || error{DimensionTooLarge};

fn validateDimensions(dimensions: usize) void {
    if (dimensions > max_supported_basis_vectors) {
        const message = comptime std.fmt.comptimePrint(
            "dimensions up to {} are currently supported",
            .{max_supported_basis_vectors},
        );
        if (@inComptime()) {
            @compileError(message);
        }
        std.debug.panic(message, .{});
    }
}

/// Returns the Euclidean metric signature `Cl(dimensions, 0, 0)`.
pub fn euclideanSignature(comptime dimensions: usize) MetricSignature {
    return MetricSignature.euclidean(dimensions);
}

/// Returns the number of basis blades in `Cl(dimensions, 0, 0)`.
pub fn bladeCount(comptime dimensions: usize) usize {
    validateDimensions(dimensions);
    return @as(usize, 1) << @intCast(dimensions);
}

/// Returns the binomial coefficient `n choose k`.
pub fn choose(comptime n: usize, comptime k: usize) usize {
    if (k > n) return 0;

    const smaller_k = @min(k, n - k);
    if (smaller_k == 0) return 1;

    var result: usize = 1;
    inline for (0..smaller_k) |i| {
        result = (result * (n - i)) / (i + 1);
    }
    return result;
}

/// Returns the grade of a blade mask.
pub fn bladeGrade(mask: BladeMask) usize {
    return mask.bitset.count();
}

fn maskHasParity(mask: BladeMask, comptime even: bool) bool {
    return ((bladeGrade(mask) & 1) == 0) == even;
}

/// Returns whether `masks` are strictly ascending and unique.
pub fn areStrictlyAscendingUnique(comptime masks: []const BladeMask) bool {
    if (masks.len <= 1) return true;

    inline for (masks[0..(masks.len - 1)], masks[1..]) |mask_prev, mask| {
        if (mask_prev.toInt() >= mask.toInt()) return false;
    }

    return true;
}

/// Returns the mask for one internal one-based basis index.
pub fn basisVectorMask(comptime dimensions: usize, basis_index: usize) BladeMask {
    validateDimensions(dimensions);
    std.debug.assert(1 <= basis_index and basis_index <= dimensions);

    return .initOneBit(basis_index - 1);
}

/// Returns the mask for a basis blade expressed as internal one-based indices.
pub fn basisBladeMask(comptime dimensions: usize, comptime basis_indices: []const usize) BladeMask {
    validateDimensions(dimensions);

    var mask: BladeMask = .init(0);
    inline for (basis_indices) |basis_index| {
        const bit = basisVectorMask(dimensions, basis_index);
        if (mask.bitset.intersectWith(bit.bitset).mask != 0) {
            @compileError("repeated basis vectors cancel in the geometric product and are not represented by a blade mask");
        }
        mask.bitset = mask.bitset.unionWith(bit.bitset);
    }

    return mask;
}

/// Folds one basis vector into an in-progress canonical signed blade.
pub fn applyBasisIndex(spec: *SignedBladeSpec, basis_index: usize, comptime dimensions: usize) void {
    euclideanSignature(dimensions).applyBasisIndex(spec, basis_index);
}

/// Runtime-capable counterpart to `applyBasisIndex`.
pub fn applyBasisIndexRuntime(spec: *SignedBladeSpec, basis_index: usize, dimensions: usize) void {
    const sig: MetricSignature = .{ .p = dimensions };
    sig.applyBasisIndex(spec, basis_index);
}

/// Folds one basis vector into an in-progress canonical signed blade under `sig`.
pub fn applyBasisIndexWithSignature(spec: *SignedBladeSpec, basis_index: usize, comptime sig: MetricSignature) void {
    sig.applyBasisIndex(spec, basis_index);
}

/// Returns every blade mask in ascending canonical order.
pub fn allBladeMasks(comptime dimensions: usize) [bladeCount(dimensions)]BladeMask {
    validateDimensions(dimensions);
    @setEvalBranchQuota(1_000_000);

    var masks: [bladeCount(dimensions)]BladeMask = undefined;
    for (0..masks.len) |index| {
        masks[index] = .init(index);
    }
    return masks;
}

/// Advances `mask` to the next larger bit pattern with the same popcount.
///
/// This is Gosper's hack. Starting from a canonical fixed-grade mask such as
/// `0b00111`, it finds the rightmost movable `1` bit, ripples that carry left,
/// then repacks the remaining trailing `1`s as far right as possible. That
/// yields the next fixed-popcount mask in ascending numeric order:
/// `0b00111 -> 0b01011 -> 0b01101 -> ...`.
///
/// Returns `false` when there is no larger mask with the same popcount in the
/// current machine word.
fn advanceFixedPopcountMask(mask: *BladeMask) bool {
    if (mask.toInt() == 0) return false;

    const current = mask.toInt();
    const smallest = current & (~current + 1);
    const ripple = current + smallest;
    if (ripple == 0) return false;

    const ones = ((current ^ ripple) >> 2) / smallest;
    mask.* = .init(ripple | ones);
    return true;
}

/// Returns all blade masks of the requested grade in canonical order.
pub fn gradeBladeMasks(comptime dimensions: usize, comptime grade: usize) [choose(dimensions, grade)]BladeMask {
    validateDimensions(dimensions);
    @setEvalBranchQuota(1_000_000);

    if (grade > dimensions) {
        @compileError("grade must not exceed the ambient dimensions");
    }

    var masks: [choose(dimensions, grade)]BladeMask = undefined;
    if (grade == 0) {
        masks[0] = .init(0);
        return masks;
    }

    var next_index: usize = 0;
    var mask: BladeMask = .initLowBits(grade);
    const limit: BladeMask = .initOneBit(dimensions);

    while (mask.toInt() < limit.toInt()) {
        masks[next_index] = mask;
        next_index += 1;

        if (!advanceFixedPopcountMask(&mask)) break;
    }

    std.debug.assert(next_index == masks.len);
    return masks;
}

fn countParityBladeMasks(comptime dimensions: usize, comptime even: bool) usize {
    return if (dimensions == 0) (if (even) 1 else 0) else bladeCount(dimensions) / 2;
}

fn parityBladeMasks(
    comptime dimensions: usize,
    comptime even: bool,
) [countParityBladeMasks(dimensions, even)]BladeMask {
    validateDimensions(dimensions);
    @setEvalBranchQuota(1_000_000);

    var masks: [countParityBladeMasks(dimensions, even)]BladeMask = undefined;
    var next_index: usize = 0;

    for (0..bladeCount(dimensions)) |index| {
        const candidate: BladeMask = .init(index);
        if (!maskHasParity(candidate, even)) continue;

        masks[next_index] = candidate;
        next_index += 1;
    }

    std.debug.assert(next_index == masks.len);
    return masks;
}

/// Returns every even-grade blade mask in canonical order.
pub fn evenBladeMasks(comptime dimensions: usize) [countParityBladeMasks(dimensions, true)]BladeMask {
    return parityBladeMasks(dimensions, true);
}

/// Returns every odd-grade blade mask in canonical order.
pub fn oddBladeMasks(comptime dimensions: usize) [countParityBladeMasks(dimensions, false)]BladeMask {
    return parityBladeMasks(dimensions, false);
}

fn completeParityOfMaskSet(comptime dimensions: usize, comptime masks: []const BladeMask) ?bool {
    @setEvalBranchQuota(1_000_000);

    if (masks.len == countParityBladeMasks(dimensions, true) and allMasksHaveParity(masks, true)) {
        return true;
    }

    if (masks.len == countParityBladeMasks(dimensions, false) and allMasksHaveParity(masks, false)) {
        return false;
    }

    return null;
}

fn countMarkedMasks(comptime dimensions: usize, comptime marked: [bladeCount(dimensions)]bool) usize {
    var count: usize = 0;
    for (marked) |is_marked| {
        count += @intFromBool(is_marked);
    }
    return count;
}

fn collectMarkedMasks(comptime dimensions: usize, comptime marked: [bladeCount(dimensions)]bool) [countMarkedMasks(dimensions, marked)]BladeMask {
    var masks: [countMarkedMasks(dimensions, marked)]BladeMask = undefined;
    var next_index: usize = 0;

    for (0..marked.len) |index| {
        if (!marked[index]) continue;

        masks[next_index] = .init(index);
        next_index += 1;
    }

    std.debug.assert(next_index == masks.len);
    return masks;
}

/// Returns the sorted union of two blade-mask lists.
pub fn unionBladeMasks(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [countMarkedMasks(dimensions, unionMaskTable(dimensions, lhs_masks, rhs_masks))]BladeMask {
    return collectMarkedMasks(dimensions, unionMaskTable(dimensions, lhs_masks, rhs_masks));
}

fn unionMaskTable(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);

    inline for (lhs_masks) |mask| marked[mask.index()] = true;
    inline for (rhs_masks) |mask| marked[mask.index()] = true;

    return marked;
}

/// Returns every blade that can appear in the geometric product of two blade sets.
pub fn geometricProductMasks(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) @TypeOf(geometricProductMaskResult(dimensions, lhs_masks, rhs_masks).value) {
    return geometricProductMaskResult(dimensions, lhs_masks, rhs_masks).value;
}

fn geometricProductMaskResult(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) type {
    const masks = if (lhs_masks.len == bladeCount(dimensions) and rhs_masks.len == bladeCount(dimensions))
        allBladeMasks(dimensions)
    else if (completeParityOfMaskSet(dimensions, lhs_masks)) |lhs_even|
        if (completeParityOfMaskSet(dimensions, rhs_masks)) |rhs_even|
            if (lhs_even == rhs_even) evenBladeMasks(dimensions) else oddBladeMasks(dimensions)
        else
            collectMarkedMasks(dimensions, geometricProductMaskTable(dimensions, lhs_masks, rhs_masks))
    else
        collectMarkedMasks(dimensions, geometricProductMaskTable(dimensions, lhs_masks, rhs_masks));

    return struct {
        pub const value = masks;
    };
}

fn geometricProductMaskTable(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
        }
    }

    return marked;
}

/// Returns every blade that can appear in the outer product of two blade sets.
pub fn outerProductMasks(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) @TypeOf(outerProductMaskResult(dimensions, lhs_masks, rhs_masks).value) {
    return outerProductMaskResult(dimensions, lhs_masks, rhs_masks).value;
}

fn outerProductMaskResult(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) type {
    const masks = if (lhs_masks.len == bladeCount(dimensions) and rhs_masks.len == bladeCount(dimensions))
        allBladeMasks(dimensions)
    else
        collectMarkedMasks(dimensions, outerProductMaskTable(dimensions, lhs_masks, rhs_masks));

    return struct {
        pub const value = masks;
    };
}

fn outerProductMaskTable(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            if (lhs_mask.bitset.intersectWith(rhs_mask.bitset).mask != 0) continue;
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
        }
    }

    return marked;
}

/// Returns every blade that can appear in the dual of a blade set.
pub fn dualMasks(
    comptime dimensions: usize,
    comptime masks: []const BladeMask,
) @TypeOf(dualMaskResult(dimensions, masks).value) {
    return dualMaskResult(dimensions, masks).value;
}

fn dualMaskResult(
    comptime dimensions: usize,
    comptime masks: []const BladeMask,
) type {
    const result_masks = if (masks.len == bladeCount(dimensions))
        allBladeMasks(dimensions)
    else
        collectMarkedMasks(dimensions, dualMaskTable(dimensions, masks));

    return struct {
        pub const value = result_masks;
    };
}

fn dualMaskTable(
    comptime dimensions: usize,
    comptime masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);
    const pseudoscalar_mask = bladeCount(dimensions) - 1;

    inline for (masks) |mask| {
        marked[@intCast(mask.bitset.mask ^ pseudoscalar_mask)] = true;
    }

    return marked;
}

/// Returns every blade that can appear in the Hestenes dot product of two blade sets.
pub fn dotProductMasks(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) @TypeOf(dotProductMaskResult(dimensions, lhs_masks, rhs_masks).value) {
    return dotProductMaskResult(dimensions, lhs_masks, rhs_masks).value;
}

fn dotProductMaskResult(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) type {
    const masks = if (lhs_masks.len == bladeCount(dimensions) and rhs_masks.len == bladeCount(dimensions))
        allNonPseudoscalarBladeMasks(dimensions)
    else
        collectMarkedMasks(dimensions, dotProductMaskTable(dimensions, lhs_masks, rhs_masks));

    return struct {
        pub const value = masks;
    };
}

fn allNonPseudoscalarBladeMasks(comptime dimensions: usize) [bladeCount(dimensions) - 1]BladeMask {
    validateDimensions(dimensions);
    @setEvalBranchQuota(1_000_000);

    var masks: [bladeCount(dimensions) - 1]BladeMask = undefined;
    for (0..masks.len) |index| {
        masks[index] = .init(index);
    }
    return masks;
}

fn dotProductMaskTable(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);

    for (lhs_masks) |lhs_mask| {
        if (lhs_mask.bitset.mask == 0) continue;
        for (rhs_masks) |rhs_mask| {
            if (rhs_mask.bitset.mask == 0) continue;

            const lhs_grade = bladeGrade(lhs_mask);
            const rhs_grade = bladeGrade(rhs_mask);
            const target_grade = if (lhs_grade > rhs_grade) lhs_grade - rhs_grade else rhs_grade - lhs_grade;

            const result_mask = BladeMask.init(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask);
            if (bladeGrade(result_mask) == target_grade) {
                marked[result_mask.index()] = true;
            }
        }
    }

    return marked;
}

/// Returns every blade that can appear in the left contraction of two blade sets.
pub fn leftContractionMasks(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) @TypeOf(leftContractionMaskResult(dimensions, lhs_masks, rhs_masks).value) {
    return leftContractionMaskResult(dimensions, lhs_masks, rhs_masks).value;
}

fn leftContractionMaskResult(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) type {
    const masks = if (lhs_masks.len == bladeCount(dimensions) and rhs_masks.len == bladeCount(dimensions))
        allBladeMasks(dimensions)
    else
        collectMarkedMasks(dimensions, leftContractionMaskTable(dimensions, lhs_masks, rhs_masks));

    return struct {
        pub const value = masks;
    };
}

fn leftContractionMaskTable(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            // Left contraction B_M \rfloor B_N is non-zero only if M \subseteq N.
            if (!lhs_mask.bitset.subsetOf(rhs_mask.bitset)) continue;
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
        }
    }

    return marked;
}

/// Returns every blade that can appear in the right contraction of two blade sets.
pub fn rightContractionMasks(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) @TypeOf(rightContractionMaskResult(dimensions, lhs_masks, rhs_masks).value) {
    return rightContractionMaskResult(dimensions, lhs_masks, rhs_masks).value;
}

fn rightContractionMaskResult(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) type {
    const masks = if (lhs_masks.len == bladeCount(dimensions) and rhs_masks.len == bladeCount(dimensions))
        allBladeMasks(dimensions)
    else
        collectMarkedMasks(dimensions, rightContractionMaskTable(dimensions, lhs_masks, rhs_masks));

    return struct {
        pub const value = masks;
    };
}

fn rightContractionMaskTable(
    comptime dimensions: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimensions)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimensions)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            // Right contraction B_M \lfloor B_N is non-zero only if N \subseteq M.
            if (!rhs_mask.bitset.subsetOf(lhs_mask.bitset)) continue;
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
        }
    }

    return marked;
}

/// Compact map from blade mask to index, efficient for high dimensions.
pub fn SortedBladeMaskMap(comptime blade_masks: []const BladeMask) type {
    const Entry = struct {
        mask: BladeMaskInt,
        index: usize,

        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.mask < rhs.mask;
        }
    };

    const sorted_entries = blk: {
        var entries: [blade_masks.len]Entry = undefined;
        for (blade_masks, 0..) |mask, i| {
            entries[i] = .{ .mask = mask.toInt(), .index = i };
        }
        std.mem.sort(Entry, &entries, {}, Entry.lessThan);
        break :blk entries;
    };

    return struct {
        pub const entries = sorted_entries;

        pub fn get(mask: BladeMask) ?usize {
            const m = mask.toInt();
            var left: usize = 0;
            var right: usize = entries.len;

            while (left < right) {
                const mid = left + (right - left) / 2;
                const mid_mask = entries[mid].mask;
                if (mid_mask == m) {
                    return entries[mid].index;
                } else if (mid_mask < m) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }

            return null;
        }
    };
}

/// Returns a dense lookup table from blade mask to index within `blade_masks`.
pub fn bladeIndexByMask(
    comptime dimensions: usize,
    comptime blade_masks: []const BladeMask,
) [bladeCount(dimensions)]usize {
    validateDimensions(dimensions);
    @setEvalBranchQuota(1_000_000);

    var result = [_]usize{blade_masks.len} ** bladeCount(dimensions);
    inline for (blade_masks, 0..) |mask, index| {
        result[mask.index()] = index;
    }
    return result;
}

/// Returns whether two blade lists are identical.
pub fn sameBladeSet(comptime lhs_masks: []const BladeMask, comptime rhs_masks: []const BladeMask) bool {
    if (lhs_masks.len != rhs_masks.len) return false;

    inline for (lhs_masks, rhs_masks) |lhs_mask, rhs_mask| {
        if (!lhs_mask.eql(rhs_mask)) return false;
    }

    return true;
}

/// Returns whether every mask has the requested grade.
pub fn allMasksHaveGrade(comptime masks: []const BladeMask, comptime grade: usize) bool {
    inline for (masks) |mask| {
        if (bladeGrade(mask) != grade) return false;
    }

    return true;
}

/// Returns whether every mask has the requested parity.
pub fn allMasksHaveParity(comptime masks: []const BladeMask, comptime even: bool) bool {
    inline for (masks) |mask| {
        if (!maskHasParity(mask, even)) return false;
    }

    return true;
}

/// Writes a fixed-width binary rendering of a blade mask.
pub fn writeBladeMask(writer: *std.Io.Writer, mask: BladeMask, dimensions: usize) WriteBladeMaskError!void {
    if (dimensions > max_supported_basis_vectors) {
        return error.DimensionTooLarge;
    }

    try writer.writeAll("0b");

    var bit_index = dimensions;
    while (bit_index > 0) {
        bit_index -= 1;
        const is_set = mask.bitset.isSet(bit_index);
        try writer.writeByte(if (is_set) '1' else '0');
    }
}

test "blade helpers match basic Euclidean tables" {
    const masks3 = BladeMask.initMany(.{ 0b001, 0b010, 0b100 });
    const masks32 = BladeMask.initMany(.{ 0b011, 0b101, 0b110 });
    const masks42 = BladeMask.initMany(.{ 0b0011, 0b0101, 0b0110, 0b1001, 0b1010, 0b1100 });

    try std.testing.expectEqual(@as(usize, 6), choose(4, 2));
    try std.testing.expectEqual(@as(usize, 8), bladeCount(3));
    try std.testing.expectEqual(@as(usize, 2), bladeGrade(.init(0b011)));
    try std.testing.expectEqualSlices(BladeMask, masks3[0..], gradeBladeMasks(3, 1)[0..]);
    try std.testing.expectEqualSlices(BladeMask, masks32[0..], gradeBladeMasks(3, 2)[0..]);
    try std.testing.expectEqualSlices(BladeMask, masks42[0..], gradeBladeMasks(4, 2)[0..]);
}

test "advanceFixedPopcountMask follows canonical fixed-popcount order" {
    var mask: BladeMask = .init(0b00111);
    const expected = [_]BladeMask{
        .init(0b01011),
        .init(0b01101),
        .init(0b01110),
        .init(0b10011),
        .init(0b10101),
        .init(0b10110),
        .init(0b11001),
        .init(0b11010),
        .init(0b11100),
    };

    inline for (expected) |next_mask| {
        try std.testing.expect(advanceFixedPopcountMask(&mask));
        try std.testing.expectEqual(next_mask, mask);
        try std.testing.expectEqual(@as(usize, 3), bladeGrade(mask));
    }
}

test "advanceFixedPopcountMask reports zero and high-bit transition behavior" {
    var zero: BladeMask = .init(0);
    try std.testing.expect(!advanceFixedPopcountMask(&zero));
    try std.testing.expectEqual(BladeMask.init(0), zero);

    var crossing_high_bit: BladeMask = .init((@as(BladeMaskInt, 1) << (@bitSizeOf(BladeMask) - 2)) | 0b1);
    try std.testing.expect(advanceFixedPopcountMask(&crossing_high_bit));
    try std.testing.expectEqual(BladeMask.init((@as(BladeMaskInt, 1) << (@bitSizeOf(BladeMask) - 2)) | 0b10), crossing_high_bit);
    try std.testing.expectEqual(@as(usize, 2), bladeGrade(crossing_high_bit));
}

test "writeBladeMask renders fixed-width binary through std.Io.Writer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeBladeMask(&out.writer, .init(0b101), 4);
    try std.testing.expectEqualSlices(u8, "0b0101", out.written());
}

test "geometricProductClassWithSignature applies metric square classes" {
    const Minkowski11: MetricSignature = .{ .p = 1, .q = 1 };
    try std.testing.expectEqual(.positive, BladeMask.init(0b01).geometricProductClassWithSignature(.init(0b01), Minkowski11));
    try std.testing.expectEqual(.negative, BladeMask.init(0b10).geometricProductClassWithSignature(.init(0b10), Minkowski11));

    const PGA: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
    // e4 (0b1000) is degenerate
    try std.testing.expectEqual(.degenerate, BladeMask.init(0b1000).geometricProductClassWithSignature(.init(0b1000), PGA));
}

test "mask set helpers compute sorted unions and products" {
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b001, 0b010, 0b100 })[0..], unionBladeMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b000, 0b011, 0b101, 0b110 })[0..], geometricProductMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b011, 0b101, 0b110 })[0..], outerProductMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
    try std.testing.expectEqualSlices(BladeMask, evenBladeMasks(3)[0..], geometricProductMasks(3, &evenBladeMasks(3), &evenBladeMasks(3))[0..]);
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{0b000})[0..], dotProductMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b000, 0b001, 0b010, 0b011, 0b100, 0b101, 0b110 })[0..], dotProductMasks(3, &allBladeMasks(3), &allBladeMasks(3))[0..]);
}

test "orientation sign helpers and parity predicates behave consistently" {
    var sign = OrientationSign.positive;
    sign.flip();
    try std.testing.expect(sign == .negative);
    try std.testing.expect(sign.isNegative());
    try std.testing.expect(sign.flipped() == .positive);

    try std.testing.expect(allMasksHaveGrade(&.{ .init(0b001), .init(0b010), .init(0b100) }, 1));
    try std.testing.expect(allMasksHaveParity(&.{ .init(0b000), .init(0b011), .init(0b101) }, true));
    try std.testing.expect(allMasksHaveParity(&.{ .init(0b001), .init(0b010), .init(0b111) }, false));
}

test "MetricSignature constructors expose dot-syntax helpers" {
    const e3: MetricSignature = .euclidean(3);
    const e2: MetricSignature = .euclidean(2);
    const minkowski11: MetricSignature = .{ .p = 1, .q = 1 };

    try std.testing.expectEqual(@as(usize, 3), e3.dimensions());
    try std.testing.expectEqual(@as(usize, 2), e2.dimensions());
    try std.testing.expectEqual(@as(usize, 2), minkowski11.dimensions());
    try std.testing.expectEqual(.negative, minkowski11.basisSquareClass(2));
}

test "ascending uniqueness helper handles short and invalid slices" {
    try std.testing.expect(areStrictlyAscendingUnique(&.{}));
    try std.testing.expect(areStrictlyAscendingUnique(&.{.init(0b010)}));
    try std.testing.expect(areStrictlyAscendingUnique(&.{ .init(0b001), .init(0b010), .init(0b100) }));
    try std.testing.expect(!areStrictlyAscendingUnique(&.{ .init(0b010), .init(0b001) }));
    try std.testing.expect(!areStrictlyAscendingUnique(&.{ .init(0b001), .init(0b001) }));
}

test "BladeMask.initMany builds explicit mask lists" {
    const masks = BladeMask.initMany(.{ 0, 0b1, 0b11, 0b1010 });
    try std.testing.expectEqualSlices(BladeMask, &.{ .init(0), .init(0b1), .init(0b11), .init(0b1010) }, masks[0..]);
}

test "basis index spans derive from metric signature partitions" {
    const spans = BasisIndexSpans.fromSignature(.{ .p = 2, .q = 1, .r = 1 });
    spans.assertValidForDimensions(4);

    try std.testing.expectEqual(BasisIndexSpan{ .start = 1, .end = 2 }, spans.spanFor(.positive).?);
    try std.testing.expectEqual(BasisIndexSpan{ .start = 3, .end = 3 }, spans.spanFor(.negative).?);
    try std.testing.expectEqual(BasisIndexSpan{ .start = 4, .end = 4 }, spans.spanFor(.degenerate).?);
    try std.testing.expect(spans.contains(4));
    try std.testing.expect(!spans.contains(5));
}

test "basis index spans resolve named indices to sequential basis indices" {
    const spans = BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });

    try std.testing.expectEqual(@as(?usize, 1), spans.resolveNamedBasisIndex(1, 4));
    try std.testing.expectEqual(@as(?usize, 3), spans.resolveNamedBasisIndex(3, 4));
    try std.testing.expectEqual(@as(?usize, 4), spans.resolveNamedBasisIndex(0, 4));
    try std.testing.expectEqual(@as(?usize, null), spans.resolveNamedBasisIndex(4, 4));
}

test "basis index span helpers construct ranges and singletons" {
    try std.testing.expectEqual(BasisIndexSpan{ .start = 2, .end = 5 }, BasisIndexSpan.range(2, 5));
    try std.testing.expectEqual(BasisIndexSpan{ .start = 7, .end = 7 }, BasisIndexSpan.singleton(7));
}

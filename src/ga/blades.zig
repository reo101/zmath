const std = @import("std");

/// Bitset representation of a basis blade.
///
/// Bit `0` corresponds to `e1`, bit `1` to `e2`, and so on.
pub const BladeMask = u64;

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
};

/// Canonical signed blade as an orientation sign plus blade mask.
pub const SignedBladeSpec = struct {
    sign: OrientationSign,
    mask: BladeMask,
};

/// Compile-time metric signature for `Cl(p, q)`.
pub const MetricSignature = struct {
    p: usize,
    q: usize,
};

/// Largest ambient dimension that fits inside `BladeMask`.
pub const max_supported_basis_vectors = @bitSizeOf(BladeMask) - 1;

/// Errors that can arise while rendering a blade mask through a writer interface.
pub const WriteBladeMaskError = std.Io.Writer.Error || error{DimensionTooLarge};

fn validateDimension(comptime dimension: usize) void {
    if (dimension > max_supported_basis_vectors) {
        @compileError("dimensions up to 63 are currently supported");
    }
}

/// Returns `p + q` for a metric signature.
pub fn metricDimension(comptime signature: MetricSignature) usize {
    const dimension = signature.p + signature.q;
    validateDimension(dimension);
    return dimension;
}

/// Returns the Euclidean metric signature `Cl(dimension, 0)`.
pub fn euclideanSignature(comptime dimension: usize) MetricSignature {
    validateDimension(dimension);
    return .{ .p = dimension, .q = 0 };
}

/// Returns the square sign of a one-based basis vector in `signature`.
pub fn basisSquareSign(comptime signature: MetricSignature, one_based_index: usize) i8 {
    const dimension = metricDimension(signature);
    std.debug.assert(one_based_index >= 1 and one_based_index <= dimension);
    return if (one_based_index <= signature.p) 1 else -1;
}

/// Returns the number of basis blades in `Cl(dimension, 0)`.
pub fn bladeCount(comptime dimension: usize) usize {
    validateDimension(dimension);
    return @as(usize, 1) << @intCast(dimension);
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
    return @popCount(mask);
}

fn maskHasParity(mask: BladeMask, comptime even: bool) bool {
    return ((bladeGrade(mask) & 1) == 0) == even;
}

/// Returns whether `masks` are strictly ascending and unique.
pub fn areStrictlyAscendingUnique(comptime masks: []const BladeMask) bool {
    if (masks.len <= 1) return true;

    inline for (masks[0..(masks.len - 1)], masks[1..]) |mask_prev, mask| {
        if (mask_prev >= mask) return false;
    }

    return true;
}

/// Returns the mask for the one-based basis vector `e{one_based_index}`.
pub fn basisVectorMask(comptime dimension: usize, one_based_index: usize) BladeMask {
    validateDimension(dimension);
    std.debug.assert(one_based_index >= 1 and one_based_index <= dimension);

    return @as(BladeMask, 1) << @intCast(one_based_index - 1);
}

/// Returns the mask for a basis blade expressed as one-based indices.
pub fn basisBladeMask(comptime dimension: usize, comptime one_based_indices: []const usize) BladeMask {
    validateDimension(dimension);

    var mask: BladeMask = 0;
    inline for (one_based_indices) |one_based_index| {
        const bit = basisVectorMask(dimension, one_based_index);
        if ((mask & bit) != 0) {
            @compileError("repeated basis vectors cancel in the geometric product and are not represented by a blade mask");
        }
        mask |= bit;
    }

    return mask;
}

/// Folds one basis vector into an in-progress canonical signed blade.
pub fn applyBasisIndex(spec: *SignedBladeSpec, one_based_index: usize, comptime dimension: usize) void {
    applyBasisIndexWithSignature(spec, one_based_index, euclideanSignature(dimension));
}

/// Folds one basis vector into an in-progress canonical signed blade under `signature`.
pub fn applyBasisIndexWithSignature(spec: *SignedBladeSpec, one_based_index: usize, comptime signature: MetricSignature) void {
    const dimension = metricDimension(signature);
    std.debug.assert(one_based_index >= 1 and one_based_index <= dimension);
    const bit = @as(BladeMask, 1) << @intCast(one_based_index - 1);
    if (geometricProductSignWithSignature(spec.mask, bit, signature) < 0) {
        spec.sign.flip();
    }
    spec.mask ^= bit;
}

/// Returns every blade mask in ascending canonical order.
pub fn allBladeMasks(comptime dimension: usize) [bladeCount(dimension)]BladeMask {
    validateDimension(dimension);
    @setEvalBranchQuota(1_000_000);

    var masks: [bladeCount(dimension)]BladeMask = undefined;
    for (0..masks.len) |index| {
        masks[index] = @intCast(index);
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
    if (mask.* == 0) return false;

    const smallest = mask.* & (~mask.* + 1);
    const ripple = mask.* + smallest;
    if (ripple == 0) return false;

    const ones = ((mask.* ^ ripple) >> 2) / smallest;
    mask.* = ripple | ones;
    return true;
}

/// Returns all blade masks of the requested grade in canonical order.
pub fn gradeBladeMasks(comptime dimension: usize, comptime grade: usize) [choose(dimension, grade)]BladeMask {
    validateDimension(dimension);
    @setEvalBranchQuota(1_000_000);

    if (grade > dimension) {
        @compileError("grade must not exceed the ambient dimension");
    }

    var masks: [choose(dimension, grade)]BladeMask = undefined;
    if (grade == 0) {
        masks[0] = 0;
        return masks;
    }

    var next_index: usize = 0;
    var mask = (@as(BladeMask, 1) << @intCast(grade)) - 1;
    const limit = @as(BladeMask, 1) << @intCast(dimension);

    while (mask < limit) {
        masks[next_index] = mask;
        next_index += 1;

        if (!advanceFixedPopcountMask(&mask)) break;
    }

    std.debug.assert(next_index == masks.len);
    return masks;
}

fn countParityBladeMasks(comptime dimension: usize, comptime even: bool) usize {
    return if (dimension == 0) (if (even) 1 else 0) else bladeCount(dimension) / 2;
}

fn parityBladeMasks(
    comptime dimension: usize,
    comptime even: bool,
) [countParityBladeMasks(dimension, even)]BladeMask {
    validateDimension(dimension);
    @setEvalBranchQuota(1_000_000);

    const count = countParityBladeMasks(dimension, even);
    var masks: [count]BladeMask = undefined;
    var next_index: usize = 0;

    for (0..bladeCount(dimension)) |index| {
        const candidate: BladeMask = @intCast(index);
        if (!maskHasParity(candidate, even)) continue;

        masks[next_index] = candidate;
        next_index += 1;
    }

    std.debug.assert(next_index == masks.len);
    return masks;
}

/// Returns every even-grade blade mask in canonical order.
pub fn evenBladeMasks(comptime dimension: usize) [countParityBladeMasks(dimension, true)]BladeMask {
    return parityBladeMasks(dimension, true);
}

/// Returns every odd-grade blade mask in canonical order.
pub fn oddBladeMasks(comptime dimension: usize) [countParityBladeMasks(dimension, false)]BladeMask {
    return parityBladeMasks(dimension, false);
}

fn countMarkedMasks(comptime dimension: usize, comptime marked: [bladeCount(dimension)]bool) usize {
    var count: usize = 0;
    inline for (marked) |is_marked| {
        if (is_marked) count += 1;
    }
    return count;
}

fn collectMarkedMasks(comptime dimension: usize, comptime marked: [bladeCount(dimension)]bool) [countMarkedMasks(dimension, marked)]BladeMask {
    var masks: [countMarkedMasks(dimension, marked)]BladeMask = undefined;
    var next_index: usize = 0;

    for (0..marked.len) |index| {
        if (!marked[index]) continue;

        masks[next_index] = @intCast(index);
        next_index += 1;
    }

    std.debug.assert(next_index == masks.len);
    return masks;
}

/// Returns the sorted union of two blade-mask lists.
pub fn unionBladeMasks(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [countMarkedMasks(dimension, unionMaskTable(dimension, lhs_masks, rhs_masks))]BladeMask {
    return collectMarkedMasks(dimension, unionMaskTable(dimension, lhs_masks, rhs_masks));
}

fn unionMaskTable(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimension)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimension)]bool);

    inline for (lhs_masks) |mask| marked[mask] = true;
    inline for (rhs_masks) |mask| marked[mask] = true;

    return marked;
}

/// Returns every blade that can appear in the geometric product of two blade sets.
pub fn geometricProductMasks(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [countMarkedMasks(dimension, geometricProductMaskTable(dimension, lhs_masks, rhs_masks))]BladeMask {
    return collectMarkedMasks(dimension, geometricProductMaskTable(dimension, lhs_masks, rhs_masks));
}

fn geometricProductMaskTable(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimension)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimension)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            marked[lhs_mask ^ rhs_mask] = true;
        }
    }

    return marked;
}

/// Returns every blade that can appear in the outer product of two blade sets.
pub fn outerProductMasks(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [countMarkedMasks(dimension, outerProductMaskTable(dimension, lhs_masks, rhs_masks))]BladeMask {
    return collectMarkedMasks(dimension, outerProductMaskTable(dimension, lhs_masks, rhs_masks));
}

fn outerProductMaskTable(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimension)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimension)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            if ((lhs_mask & rhs_mask) != 0) continue;
            marked[lhs_mask ^ rhs_mask] = true;
        }
    }

    return marked;
}

/// Returns a dense lookup table from blade mask to index within `blade_masks`.
pub fn bladeIndexByMask(
    comptime dimension: usize,
    comptime blade_masks: []const BladeMask,
) [bladeCount(dimension)]usize {
    validateDimension(dimension);
    @setEvalBranchQuota(1_000_000);

    var result = [_]usize{blade_masks.len} ** bladeCount(dimension);
    inline for (blade_masks, 0..) |mask, index| {
        result[mask] = index;
    }
    return result;
}

/// Returns the sign produced by the Euclidean geometric product of two blade masks.
pub fn geometricProductSign(lhs_mask: BladeMask, rhs_mask: BladeMask) i8 {
    var sign: i8 = 1;
    var remaining = lhs_mask;

    while (remaining != 0) {
        const bit_index = @ctz(remaining);
        remaining &= remaining - 1;

        const lower_bits = if (bit_index == 0)
            @as(BladeMask, 0)
        else
            (@as(BladeMask, 1) << @intCast(bit_index)) - 1;

        if ((@popCount(rhs_mask & lower_bits) % 2) != 0) {
            sign = -sign;
        }
    }

    return sign;
}

/// Returns the sign produced by the `Cl(p, q)` geometric product of two blade masks.
pub fn geometricProductSignWithSignature(
    lhs_mask: BladeMask,
    rhs_mask: BladeMask,
    comptime signature: MetricSignature,
) i8 {
    var sign = geometricProductSign(lhs_mask, rhs_mask);
    var overlap = lhs_mask & rhs_mask;
    while (overlap != 0) {
        const bit_index = @ctz(overlap);
        overlap &= overlap - 1;
        if (basisSquareSign(signature, bit_index + 1) < 0) {
            sign = -sign;
        }
    }

    return sign;
}

/// Returns whether two blade lists are identical.
pub fn sameBladeSet(comptime lhs_masks: []const BladeMask, comptime rhs_masks: []const BladeMask) bool {
    if (lhs_masks.len != rhs_masks.len) return false;

    inline for (lhs_masks, rhs_masks) |lhs_mask, rhs_mask| {
        if (lhs_mask != rhs_mask) return false;
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
pub fn writeBladeMask(writer: *std.Io.Writer, mask: BladeMask, dimension: usize) WriteBladeMaskError!void {
    if (dimension > max_supported_basis_vectors) {
        return error.DimensionTooLarge;
    }

    try writer.writeAll("0b");

    var bit_index = dimension;
    while (bit_index > 0) {
        bit_index -= 1;
        const is_set = ((mask >> @intCast(bit_index)) & 1) == 1;
        try writer.writeByte(if (is_set) '1' else '0');
    }
}

test "blade helpers match basic Euclidean tables" {
    try std.testing.expectEqual(@as(usize, 6), choose(4, 2));
    try std.testing.expectEqual(@as(usize, 8), bladeCount(3));
    try std.testing.expectEqual(@as(usize, 2), bladeGrade(0b011));
    try std.testing.expectEqualSlices(BladeMask, &.{ 0b001, 0b010, 0b100 }, gradeBladeMasks(3, 1)[0..]);
    try std.testing.expectEqualSlices(BladeMask, &.{ 0b011, 0b101, 0b110 }, gradeBladeMasks(3, 2)[0..]);
    try std.testing.expectEqualSlices(BladeMask, &.{ 0b0011, 0b0101, 0b0110, 0b1001, 0b1010, 0b1100 }, gradeBladeMasks(4, 2)[0..]);
}

test "writeBladeMask renders fixed-width binary through std.Io.Writer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeBladeMask(&out.writer, 0b101, 4);
    try std.testing.expectEqualSlices(u8, "0b0101", out.written());
}

test "geometricProductSignWithSignature applies negative basis-vector squares" {
    const Minkowski11: MetricSignature = .{ .p = 1, .q = 1 };
    try std.testing.expectEqual(@as(i8, 1), geometricProductSignWithSignature(0b01, 0b01, Minkowski11));
    try std.testing.expectEqual(@as(i8, -1), geometricProductSignWithSignature(0b10, 0b10, Minkowski11));
}

test "mask set helpers compute sorted unions and products" {
    const lhs = [_]BladeMask{ 0b001, 0b010 };
    const rhs = [_]BladeMask{ 0b010, 0b100 };

    try std.testing.expectEqualSlices(BladeMask, &.{ 0b001, 0b010, 0b100 }, unionBladeMasks(3, lhs[0..], rhs[0..])[0..]);
    try std.testing.expectEqualSlices(BladeMask, &.{ 0b000, 0b011, 0b101, 0b110 }, geometricProductMasks(3, lhs[0..], rhs[0..])[0..]);
    try std.testing.expectEqualSlices(BladeMask, &.{ 0b011, 0b101, 0b110 }, outerProductMasks(3, lhs[0..], rhs[0..])[0..]);
}

test "orientation sign helpers and parity predicates behave consistently" {
    var sign = OrientationSign.positive;
    sign.flip();
    try std.testing.expect(sign == .negative);
    try std.testing.expect(sign.isNegative());
    try std.testing.expect(sign.flipped() == .positive);

    try std.testing.expect(allMasksHaveGrade(&.{ 0b001, 0b010, 0b100 }, 1));
    try std.testing.expect(allMasksHaveParity(&.{ 0b000, 0b011, 0b101 }, true));
    try std.testing.expect(allMasksHaveParity(&.{ 0b001, 0b010, 0b111 }, false));
}

test "ascending uniqueness helper handles short and invalid slices" {
    try std.testing.expect(areStrictlyAscendingUnique(&.{}));
    try std.testing.expect(areStrictlyAscendingUnique(&.{0b010}));
    try std.testing.expect(areStrictlyAscendingUnique(&.{ 0b001, 0b010, 0b100 }));
    try std.testing.expect(!areStrictlyAscendingUnique(&.{ 0b010, 0b001 }));
    try std.testing.expect(!areStrictlyAscendingUnique(&.{ 0b001, 0b001 }));
}

const std = @import("std");

const parser = @import("blade_parsing.zig");

/// Bitset representation of a basis blade.
///
/// Bit `0` corresponds to `e1`, bit `1` to `e2`, and so on.
pub const BladeMaskBytes = 2;
pub const BladeMaskBitSet = std.bit_set.IntegerBitSet(BladeMaskBytes * 8);
pub const BladeMaskInt = BladeMaskBitSet.MaskInt;

/// Utilities for working with blade masks.
pub const BladeMask = packed struct(BladeMaskInt) {
    bitset: BladeMaskBitSet,

    /// Explicit constructor for blade masks from integer bit patterns.
    pub inline fn init(value: anytype) BladeMask {
        return .{ .bitset = .{ .mask = @as(BladeMaskInt, @intCast(value)) } };
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

    pub fn parse(comptime name: []const u8) !BladeMask {
        return (try parser.parseSignedBlade(name, max_supported_basis_vectors)).mask;
    }

    pub fn parseForDimension(comptime name: []const u8, comptime dimension: usize) !BladeMask {
        return (try parser.parseSignedBlade(name, dimension)).mask;
    }

    pub fn parsePanicking(comptime name: []const u8) BladeMask {
        return parser.expectSignedBlade(name, max_supported_basis_vectors).mask;
    }

    pub fn parseForDimensionPanicking(comptime name: []const u8, comptime dimension: usize) BladeMask {
        return parser.expectSignedBlade(name, dimension).mask;
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
};

/// Canonical signed blade as an orientation sign plus blade mask.
pub const SignedBladeSpec = struct {
    sign: OrientationSign,
    mask: BladeMask,
};

/// Compile-time metric signature for `Cl(p, q, r)`.
///
/// In the Clifford algebra `Cl(p, q, r)`:
/// - `p` = number of basis vectors that square to **+1** (positive signature)
/// - `q` = number of basis vectors that square to **-1** (negative signature)
/// - `r` = number of basis vectors that square to **0** (degenerate/null signature)
///
/// The algebra has dimension `p + q + r`. Common examples:
/// - `Cl(3, 0, 0)` = standard 3D Euclidean GA
/// - `Cl(4, 1, 0)` = conformal geometric algebra (VGA)
/// - `Cl(3, 0, 1)` = projective geometric algebra (PGA)
/// - `Cl(1, 1, 0)` = Minkowski spacetime
pub const MetricSignature = struct {
    p: usize,
    q: usize = 0,
    r: usize = 0,

    /// Constructs `Cl(p, q, r)` and validates that the dimension fits `BladeMask`.
    pub fn init(comptime p: usize, comptime q: usize, comptime r: usize) MetricSignature {
        const sig: MetricSignature = .{ .p = p, .q = q, .r = r };
        _ = sig.dimension();
        return sig;
    }

    /// Constructs the Euclidean signature `Cl(d, 0, 0)`.
    pub fn euclidean(comptime d: usize) MetricSignature {
        return init(d, 0, 0);
    }

    /// Returns `p + q + r` for this metric signature.
    pub fn dimension(self: MetricSignature) usize {
        const total_dimension = self.p + self.q + self.r;
        validateDimension(total_dimension);
        return total_dimension;
    }
};

/// Largest ambient dimension that fits inside `BladeMask`.
pub const max_supported_basis_vectors = @bitSizeOf(BladeMask) - 1;

/// Errors that can arise while rendering a blade mask through a writer interface.
pub const WriteBladeMaskError = std.Io.Writer.Error || error{DimensionTooLarge};

fn validateDimension(dimension: usize) void {
    if (dimension > max_supported_basis_vectors) {
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

/// Returns `p + q + r` for a metric signature.
pub fn metricDimension(comptime sig: MetricSignature) usize {
    return sig.dimension();
}

/// Returns the Euclidean metric signature `Cl(dimension, 0, 0)`.
pub fn euclideanSignature(comptime dimension: usize) MetricSignature {
    return MetricSignature.euclidean(dimension);
}

/// Returns the square sign of a one-based basis vector in `sig`.
/// - Returns `1` for basis vectors in the positive signature (first `p` vectors)
/// - Returns `-1` for basis vectors in the negative signature (next `q` vectors)
/// - Returns `0` for basis vectors in the degenerate signature (last `r` vectors)
pub fn basisSquareSign(comptime sig: MetricSignature, one_based_index: usize) i8 {
    const dimension = sig.dimension();
    std.debug.assert(1 <= one_based_index and one_based_index <= dimension);

    return if (one_based_index <= sig.p)
        1
    else if (one_based_index <= sig.p + sig.q)
        -1
    else
        0;
}

/// Returns the number of basis blades in `Cl(dimension, 0, 0)`.
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

/// Returns the mask for the one-based basis vector `e{one_based_index}`.
pub fn basisVectorMask(comptime dimension: usize, one_based_index: usize) BladeMask {
    validateDimension(dimension);
    std.debug.assert(1 <= one_based_index and one_based_index <= dimension);

    return .init(@as(BladeMaskInt, 1) << @intCast(one_based_index - 1));
}

/// Returns the mask for a basis blade expressed as one-based indices.
pub fn basisBladeMask(comptime dimension: usize, comptime one_based_indices: []const usize) BladeMask {
    validateDimension(dimension);

    var mask: BladeMask = .init(0);
    inline for (one_based_indices) |one_based_index| {
        const bit = basisVectorMask(dimension, one_based_index);
        if (mask.bitset.intersectWith(bit.bitset).mask != 0) {
            @compileError("repeated basis vectors cancel in the geometric product and are not represented by a blade mask");
        }
        mask.bitset = mask.bitset.unionWith(bit.bitset);
    }

    return mask;
}

/// Folds one basis vector into an in-progress canonical signed blade.
pub fn applyBasisIndex(spec: *SignedBladeSpec, one_based_index: usize, comptime dimension: usize) void {
    applyBasisIndexWithSignature(spec, one_based_index, euclideanSignature(dimension));
}

/// Folds one basis vector into an in-progress canonical signed blade under `sig`.
pub fn applyBasisIndexWithSignature(spec: *SignedBladeSpec, one_based_index: usize, comptime sig: MetricSignature) void {
    const dimension = sig.dimension();
    std.debug.assert(1 <= one_based_index and one_based_index <= dimension);
    const bit: BladeMask = .init(@as(BladeMaskInt, 1) << @intCast(one_based_index - 1));
    if (geometricProductSignWithSignature(spec.mask, bit, sig) < 0) {
        spec.sign.flip();
    }
    spec.mask.bitset = spec.mask.bitset.xorWith(bit.bitset);
}

/// Returns every blade mask in ascending canonical order.
pub fn allBladeMasks(comptime dimension: usize) [bladeCount(dimension)]BladeMask {
    validateDimension(dimension);
    @setEvalBranchQuota(1_000_000);

    var masks: [bladeCount(dimension)]BladeMask = undefined;
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
pub fn gradeBladeMasks(comptime dimension: usize, comptime grade: usize) [choose(dimension, grade)]BladeMask {
    validateDimension(dimension);
    @setEvalBranchQuota(1_000_000);

    if (grade > dimension) {
        @compileError("grade must not exceed the ambient dimension");
    }

    var masks: [choose(dimension, grade)]BladeMask = undefined;
    if (grade == 0) {
        masks[0] = .init(0);
        return masks;
    }

    var next_index: usize = 0;
    var mask: BladeMask = .init((@as(BladeMaskInt, 1) << @intCast(grade)) - 1);
    const limit = @as(BladeMaskInt, 1) << @intCast(dimension);

    while (mask.toInt() < limit) {
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
        const candidate: BladeMask = .init(index);
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
    for (marked) |is_marked| {
        count += @intFromBool(is_marked);
    }
    return count;
}

fn collectMarkedMasks(comptime dimension: usize, comptime marked: [bladeCount(dimension)]bool) [countMarkedMasks(dimension, marked)]BladeMask {
    var masks: [countMarkedMasks(dimension, marked)]BladeMask = undefined;
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

    inline for (lhs_masks) |mask| marked[mask.index()] = true;
    inline for (rhs_masks) |mask| marked[mask.index()] = true;

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
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
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
            if (lhs_mask.bitset.intersectWith(rhs_mask.bitset).mask != 0) continue;
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
        }
    }

    return marked;
}

/// Returns every blade that can appear in the left contraction of two blade sets.
pub fn leftContractionMasks(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [countMarkedMasks(dimension, leftContractionMaskTable(dimension, lhs_masks, rhs_masks))]BladeMask {
    return collectMarkedMasks(dimension, leftContractionMaskTable(dimension, lhs_masks, rhs_masks));
}

fn leftContractionMaskTable(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimension)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimension)]bool);

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
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [countMarkedMasks(dimension, rightContractionMaskTable(dimension, lhs_masks, rhs_masks))]BladeMask {
    return collectMarkedMasks(dimension, rightContractionMaskTable(dimension, lhs_masks, rhs_masks));
}

fn rightContractionMaskTable(
    comptime dimension: usize,
    comptime lhs_masks: []const BladeMask,
    comptime rhs_masks: []const BladeMask,
) [bladeCount(dimension)]bool {
    @setEvalBranchQuota(1_000_000);
    var marked = std.mem.zeroes([bladeCount(dimension)]bool);

    inline for (lhs_masks) |lhs_mask| {
        inline for (rhs_masks) |rhs_mask| {
            // Right contraction B_M \lfloor B_N is non-zero only if N \subseteq M.
            if (!rhs_mask.bitset.subsetOf(lhs_mask.bitset)) continue;
            marked[@intCast(lhs_mask.bitset.xorWith(rhs_mask.bitset).mask)] = true;
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
        result[mask.index()] = index;
    }
    return result;
}

/// Returns the sign produced by the Euclidean geometric product of two blade masks.
pub fn geometricProductSign(lhs_mask: BladeMask, rhs_mask: BladeMask) i8 {
    var sign: i8 = 1;
    var remaining = lhs_mask.toInt();
    const rhs_bits = rhs_mask.bitset;

    while (remaining != 0) {
        const bit_index = @ctz(remaining);
        remaining &= remaining - 1;

        const lower_bits = if (bit_index == 0)
            @as(BladeMaskInt, 0)
        else
            (@as(BladeMaskInt, 1) << @intCast(bit_index)) - 1;

        const lower_rhs = rhs_bits.intersectWith(.{ .mask = lower_bits });
        if ((lower_rhs.count() % 2) != 0) {
            sign = -sign;
        }
    }

    return sign;
}

/// Returns the sign produced by the `Cl(p, q, r)` geometric product of two blade masks.
pub fn geometricProductSignWithSignature(
    lhs_mask: BladeMask,
    rhs_mask: BladeMask,
    comptime sig: MetricSignature,
) i8 {
    var sign = geometricProductSign(lhs_mask, rhs_mask);
    var overlap = lhs_mask.bitset.intersectWith(rhs_mask.bitset);
    while (overlap.toggleFirstSet()) |bit_index| {
        sign *= basisSquareSign(sig, bit_index + 1);
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

test "geometricProductSignWithSignature applies negative basis-vector squares" {
    const Minkowski11: MetricSignature = .{ .p = 1, .q = 1 };
    try std.testing.expectEqual(@as(i8, 1), geometricProductSignWithSignature(.init(0b01), .init(0b01), Minkowski11));
    try std.testing.expectEqual(@as(i8, -1), geometricProductSignWithSignature(.init(0b10), .init(0b10), Minkowski11));

    const PGA: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
    // e4 (0b1000) is degenerate
    try std.testing.expectEqual(@as(i8, 0), geometricProductSignWithSignature(.init(0b1000), .init(0b1000), PGA));
}

test "mask set helpers compute sorted unions and products" {
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b001, 0b010, 0b100 })[0..], unionBladeMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b000, 0b011, 0b101, 0b110 })[0..], geometricProductMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
    try std.testing.expectEqualSlices(BladeMask, BladeMask.initMany(.{ 0b011, 0b101, 0b110 })[0..], outerProductMasks(3, &comptime BladeMask.initMany(.{ 0b001, 0b010 }), &comptime BladeMask.initMany(.{ 0b010, 0b100 }))[0..]);
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

    try std.testing.expectEqual(@as(usize, 3), e3.dimension());
    try std.testing.expectEqual(@as(usize, 2), e2.dimension());
    try std.testing.expectEqual(@as(usize, 2), minkowski11.dimension());
    try std.testing.expectEqual(@as(i8, -1), basisSquareSign(minkowski11, 2));
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

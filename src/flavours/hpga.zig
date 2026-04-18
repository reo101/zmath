const std = @import("std");

pub const ga = @import("../ga.zig");
const family = ga.family;
const projective_helpers = @import("projective_helpers.zig");

/// Hyperbolic projective algebra signature `Cl(3, 1, 0)`: three positive
/// spatial basis vectors and one negative homogeneous basis vector `e0`.
const default_family = family.projectiveHyperbolic(3);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return family.projectiveHyperbolic(euclidean_dimensions);
}

const bindings = family.defaultBindings(default_family, f32);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
/// Ambient dimensions of the algebra (4).
pub const dimensions = bindings.dimensions;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub fn FamilyHelpers(comptime FamilyType: type, comptime T: type) type {
    return projective_helpers.RoundProjectiveHelpers(T, FamilyType.Instantiate(T), .hyperbolic);
}

pub fn InstantiateHelpers(comptime T: type) type {
    return FamilyHelpers(Family, T);
}

const default_helpers = InstantiateHelpers(default_scalar);
pub const Point = default_helpers.Point;
pub const ambientCoords = default_helpers.ambientCoords;

fn namedBasisIndex(comptime named_index: usize) usize {
    return bindings.resolveNamedBasisIndex(named_index);
}

test "hpga signature has expected basis classes" {
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(1)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(2)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(3)));
    try std.testing.expectEqual(.negative, metric_signature.basisSquareClass(namedBasisIndex(0)));
}

test "hpga proper point normalizes onto the hyperboloid" {
    const p = Point.proper(0.2, -0.1, 0.3).?;
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.gp(p).scalarCoeff(), 1e-5);
}

test "hpga exposes configurable Euclidean families" {
    const H2 = EuclideanFamily(2).Instantiate(f32);
    const e0 = H2.Basis.e(0);
    const e1 = H2.Basis.e(1);

    try std.testing.expectEqual(@as(usize, 3), EuclideanFamily(2).dimensions);
    try std.testing.expectEqual(@as(f32, -1.0), e0.gp(e0).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), e1.gp(e1).scalarCoeff());
}

test "hpga helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f64);
    const p = Helpers.Point.proper(0.2, -0.1, 0.3).?;

    try std.testing.expectApproxEqAbs(@as(f64, -1.0), p.gp(p).scalarCoeff(), 1e-8);
}

test "hpga helpers support non-3d families through coordinate arrays" {
    const Helpers = FamilyHelpers(EuclideanFamily(2), f32);
    const p = Helpers.Point.properFromCoords(.{ 0.2, -0.1 }).?;
    const coords = Helpers.ambientCoords(p);
    const inv: f32 = 1.0 / @sqrt(1.0 - 0.2 * 0.2 - 0.1 * 0.1);

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.gp(p).scalarCoeff(), 1e-5);
    try std.testing.expectApproxEqAbs(inv, coords[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.2 * inv, coords[1], 1e-5);
    try std.testing.expectApproxEqAbs(-0.1 * inv, coords[2], 1e-5);
}

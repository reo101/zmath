const std = @import("std");

pub const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");
const projective_helpers = @import("projective_helpers.zig");

/// Elliptic projective algebra signature `Cl(4, 0, 0)`: four positive basis
/// vectors with homogeneous naming `e0..e3`.
const default_family = family.projectiveElliptic(3);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return family.projectiveElliptic(euclidean_dimensions);
}

const bindings = family.defaultBindings(default_family, f32);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
/// Ambient dimension of the algebra (4).
pub const dimension = bindings.dimension;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub fn FamilyHelpers(comptime FamilyType: type, comptime T: type) type {
    return projective_helpers.RoundProjectiveHelpers(T, FamilyType.Instantiate(T), .elliptic);
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

test "epga signature exposes homogeneous e0 naming on positive basis" {
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(0)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(1)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(2)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(3)));
}

test "epga proper point normalizes onto the 3-sphere" {
    const p = Point.proper(0.4, -0.3, 0.2);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.gp(p).scalarCoeff(), 1e-5);
}

test "epga exposes configurable Euclidean families" {
    const E2 = EuclideanFamily(2).Instantiate(f32);
    const e0 = E2.Basis.e(0);

    try std.testing.expectEqual(@as(usize, 3), EuclideanFamily(2).dimension);
    try std.testing.expectEqual(@as(f32, 1.0), e0.gp(e0).scalarCoeff());
}

test "epga helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f64);
    const p = Helpers.Point.proper(0.4, -0.3, 0.2);

    try std.testing.expectApproxEqAbs(@as(f64, -1.0), p.gp(p).scalarCoeff(), 1e-8);
}

test "epga helpers support non-3d families through coordinate arrays" {
    const Helpers = FamilyHelpers(EuclideanFamily(2), f32);
    const p = Helpers.Point.properFromCoords(.{ 0.4, -0.3 });
    const coords = Helpers.ambientCoords(p);
    const inv: f32 = 1.0 / @sqrt(1.0 + 0.4 * 0.4 + 0.3 * 0.3);

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.gp(p).scalarCoeff(), 1e-5);
    try std.testing.expectApproxEqAbs(inv, coords[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.4 * inv, coords[1], 1e-5);
    try std.testing.expectApproxEqAbs(-0.3 * inv, coords[2], 1e-5);
}

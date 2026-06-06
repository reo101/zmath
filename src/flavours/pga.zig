const std = @import("std");

pub const ga = @import("ga");
const blade_parsing = ga.blade_parsing;
const blades = ga.blades;
const family = ga.family;
const multivector = ga.multivector;
const projective_helpers = @import("projective_helpers.zig");

/// PGA signature `Cl(3, 0, 1)`: three positive basis vectors and one
/// degenerate (null) basis vector `e0` that squares to zero.
const default_family = family.projectiveEuclidean(3);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return family.projectiveEuclidean(euclidean_dimensions);
}

const bindings = family.defaultBindings(default_family, f32);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
/// Ambient dimensions of the PGA algebra (4).
pub const dimensions = bindings.dimensions;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub fn FamilyHelpers(comptime FamilyType: type, comptime T: type) type {
    const H = FamilyType.Instantiate(T);
    const Shared = projective_helpers.EuclideanProjectiveHelpers(T, H);

    return struct {
        pub const h = H;

        pub const Point = struct {
            pub fn initHomogeneousCoords(w: T, coords: [H.Full.dimensions - 1]T) H.Full {
                return Shared.Point.initHomogeneousCoords(w, coords);
            }

            pub fn fromCoords(coords: [H.Full.dimensions - 1]T) H.Full {
                return Shared.Point.fromCoords(coords);
            }

            pub fn init(x: T, y: T, z: T) H.Full {
                // PGA points are trivectors: x*e230 + y*e310 + z*e120 + e123.
                return H.exprAs(H.Full, "{x}*e_2_3_0 + {y}*e_3_1_0 + {z}*e_1_2_0 + e123", .{ .x = x, .y = y, .z = z });
            }

            pub fn directionFromCoords(coords: [H.Full.dimensions - 1]T) H.Full {
                return Shared.Point.directionFromCoords(coords);
            }

            pub fn direction(x: T, y: T, z: T) H.Full {
                return H.exprAs(H.Full, "{x}*e_2_3_0 + {y}*e_3_1_0 + {z}*e_1_2_0", .{ .x = x, .y = y, .z = z });
            }
        };

        pub const Plane = struct {
            pub fn init(a: T, b: T, c: T, d: T) H.Full {
                // Plane: a*e1 + b*e2 + c*e3 + d*e0
                return H.exprAs(H.Full, "{a}*e1 + {b}*e2 + {c}*e3 + {d}*e0", .{ .a = a, .b = b, .c = c, .d = d });
            }
        };

        /// Converts a PGA multivector (intended to be a rotor) to a 4x4 matrix.
        /// Assumes the multivector acts on points P = x*e1 + y*e2 + z*e3 + e0.
        pub fn toMatrix4x4(mv: anytype) [4][4]T {
            multivector.ensureMultivector(@TypeOf(mv));
            const E = H.Basis;
            const basis_vectors = [_]H.Vector{
                E.e(1).gradePart(1),
                E.e(2).gradePart(1),
                E.e(3).gradePart(1),
                E.e(0).gradePart(1),
            };

            var mat: [4][4]T = undefined;
            inline for (basis_vectors, 0..) |v, j| {
                const v_prime = mv.gp(v).gp(mv.reverse()).gradePart(1);
                const n = v_prime.named();
                mat[0][j] = @floatCast(n.e1);
                mat[1][j] = @floatCast(n.e2);
                mat[2][j] = @floatCast(n.e3);
                mat[3][j] = @floatCast(n.e0);
            }
            return mat;
        }

        pub fn ambientCoords(p: anytype) [H.Full.dimensions]T {
            return Shared.ambientCoords(p);
        }

        pub fn geometricProduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.gp(rhs)) {
            return lhs.gp(rhs);
        }

        pub fn exteriorProduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.wedge(rhs)) {
            return lhs.wedge(rhs);
        }

        pub fn regressiveProduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.antiWedge(rhs)) {
            return lhs.antiWedge(rhs);
        }

        pub fn geometricAntiproduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.antiGeometric(rhs)) {
            return lhs.antiGeometric(rhs);
        }

        pub fn dotProduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.dot(rhs)) {
            return lhs.dot(rhs);
        }

        pub fn antidotProduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.antiDot(rhs)) {
            return lhs.antiDot(rhs);
        }

        pub fn complementDual(mv: anytype) @TypeOf(mv.complementDual()) {
            return mv.complementDual();
        }

        fn projectiveBasisMask(comptime Mv: type) blades.BladeMask {
            const index = comptime blade_parsing.resolveNamedBasisIndex(0, Mv.dimensions, Mv.naming, true);
            return .initOneBit(index - 1);
        }

        fn filteredComplementDual(mv: anytype, comptime keep_projective_weight: bool) @TypeOf(mv.complementDual()) {
            const Mv = @TypeOf(mv);
            multivector.ensureMultivector(Mv);
            if (comptime Mv.metric_signature.q != 0 or Mv.metric_signature.r != 1) {
                @compileError("PGA metric dual helpers require a projective Euclidean Cl(n,0,1) algebra");
            }

            const Result = @TypeOf(mv.complementDual());
            var result_coeffs = std.mem.zeroes([Result.stored_blade_count]Mv.Coefficient);
            const self_coeffs = mv.coeffsArray();
            const pseudoscalar_mask = comptime blades.bladeCount(Mv.dimensions) - 1;
            const projective_mask = comptime projectiveBasisMask(Mv);

            inline for (Mv.blades, 0..) |mask, i| {
                const has_projective_weight = comptime mask.bitset.intersectWith(projective_mask.bitset).mask != 0;
                if (has_projective_weight == keep_projective_weight) {
                    const target_mask = blades.BladeMask.init(mask.bitset.mask ^ pseudoscalar_mask);
                    const result_idx = Result.getBladeIndex(target_mask);
                    const sign = mask.geometricProductSign(blades.BladeMask.init(pseudoscalar_mask));
                    result_coeffs[result_idx] = self_coeffs[i] * @intFromEnum(sign);
                }
            }

            return Result.init(result_coeffs);
        }

        /// Returns the RGA metric dual, also called the bulk dual.
        ///
        /// This complements only the bulk components: basis blades that do not
        /// contain the projective `e0` direction.
        pub fn metricDual(mv: anytype) @TypeOf(filteredComplementDual(mv, false)) {
            return filteredComplementDual(mv, false);
        }

        /// Explicit alias for `metricDual()`.
        pub fn bulkDual(mv: anytype) @TypeOf(filteredComplementDual(mv, false)) {
            return filteredComplementDual(mv, false);
        }

        /// Returns the RGA metric antidual, also called the weight dual.
        ///
        /// This complements only the weight components: basis blades that
        /// contain the projective `e0` direction.
        pub fn metricAntidual(mv: anytype) @TypeOf(filteredComplementDual(mv, true)) {
            return filteredComplementDual(mv, true);
        }

        /// Explicit alias for `metricAntidual()`.
        pub fn weightDual(mv: anytype) @TypeOf(filteredComplementDual(mv, true)) {
            return filteredComplementDual(mv, true);
        }
    };
}

pub fn InstantiateHelpers(comptime T: type) type {
    return FamilyHelpers(Family, T);
}

const default_helpers = InstantiateHelpers(default_scalar);
pub const Point = default_helpers.Point;
pub const Plane = default_helpers.Plane;
pub const toMatrix4x4 = default_helpers.toMatrix4x4;
pub const ambientCoords = default_helpers.ambientCoords;
pub const geometricProduct = default_helpers.geometricProduct;
pub const exteriorProduct = default_helpers.exteriorProduct;
pub const regressiveProduct = default_helpers.regressiveProduct;
pub const geometricAntiproduct = default_helpers.geometricAntiproduct;
pub const dotProduct = default_helpers.dotProduct;
pub const antidotProduct = default_helpers.antidotProduct;
pub const complementDual = default_helpers.complementDual;
pub const metricDual = default_helpers.metricDual;
pub const bulkDual = default_helpers.bulkDual;
pub const metricAntidual = default_helpers.metricAntidual;
pub const weightDual = default_helpers.weightDual;

fn namedBasisIndex(comptime named_index: usize) usize {
    return bindings.resolveNamedBasisIndex(named_index);
}

test "pga signature has correct dimensions and basis-vector squares" {
    // e1² = e2² = e3² = +1 (positive)
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(1)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(2)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(3)));

    // e0² = 0 (degenerate)
    try std.testing.expectEqual(.degenerate, metric_signature.basisSquareClass(namedBasisIndex(0)));
}

test "degenerate basis vector squares to zero under geometric product" {
    const E = h.Basis;
    const e0 = E.e(0); // the degenerate direction
    const result = e0.gp(e0);

    // e0 * e0 = 0 in Cl(3,0,1)
    try std.testing.expectEqual(@as(f64, 0.0), result.scalarCoeff()); // scalar part
}

test "positive basis vectors still square to +1" {
    const E = h.Basis;

    inline for (1..4) |i| {
        const ei = E.e(i);
        const sq = ei.gp(ei);
        try std.testing.expectEqual(@as(f64, 1.0), sq.scalarCoeff());
    }
}

test "geometric product with degenerate vector produces dual-like elements" {
    const E = h.Basis;
    const e1 = E.e(1);
    const e0 = E.e(0);

    // e1 * e0 should give a bivector e10 with coefficient +1 (or -1 depending on order)
    const e1e0 = e1.gp(e0);
    try std.testing.expect(e1e0.coeffNamed("e_1_0") != 0.0);

    // e0 * e1 should give the opposite sign
    const e0e1 = e0.gp(e1);
    try std.testing.expectEqual(
        -e1e0.coeffNamed("e_1_0"),
        e0e1.coeffNamed("e_1_0"),
    );
}

test "ideal point (pure e0 multivector) has zero scalar product with itself" {
    const E = h.Basis;
    const e0 = E.e(0);
    const sp = e0.scalarProduct(e0);
    try std.testing.expectEqual(@as(f64, 0.0), sp);
}

test "euclidean point representation and join" {
    const E = h.Basis;
    const e1 = E.e(1);
    const e2 = E.e(2);
    const e3 = E.e(3);
    const e0 = E.e(0);

    // In PGA a Euclidean point is P = x*e1 + y*e2 + z*e3 + e0
    // Build point P = e1 + e0 (x=1, y=0, z=0)
    const p = e1.add(e0);

    // Build point Q = e2 + e0 (x=0, y=1, z=0)
    const q = e2.add(e0);

    // The join (outer product) of two points gives the line through them
    const line = p.outerProduct(q);

    // The line should have a non-zero e12 component (the direction part)
    try std.testing.expect(line.coeffNamed("e12") != 0.0);

    // The line should also have moment components involving e0
    _ = e3; // e3 unused here but available for 3D tests
}

test "fullSignedBladeFromIndicesWithSignature respects degenerate square" {
    // Repeated degenerate index should give zero
    const result = h.Basis.fromIndices(&.{ dimensions, dimensions });
    // e0*e0 = 0, so the scalar part must be zero
    try std.testing.expectEqual(@as(f64, 0.0), result.scalarCoeff());
}

test "pga signed blade parser accepts e0 alias for degenerate basis" {
    const parsed = blade_parsing.parseSignedBlade("e0", dimensions, bindings.naming_options, false);
    try std.testing.expectEqual(blades.SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, try parsed);

    const E = h.Basis;
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expectError(error.InvalidBasisIndex, blade_parsing.resolveNamedBasisIndex(4, dimensions, bindings.naming_options, false));
    try std.testing.expectError(error.InvalidBasisIndex, blade_parsing.parseSignedBlade("e4", dimensions, bindings.naming_options, false));
    try std.testing.expectError(error.InvalidBasisIndex, blade_parsing.parseSignedBlade("e14", dimensions, bindings.naming_options, false));
}

test "Point.init correctly constructs trivectors" {
    const p = Point.init(1, 2, 3);

    // x*e230 + y*e310 + z*e120 + e123
    try std.testing.expectEqual(@as(f32, 1), p.coeffNamed("e_2_3_0"));
    try std.testing.expectEqual(@as(f32, 2), p.coeffNamed("e_3_1_0"));
    try std.testing.expectEqual(@as(f32, 3), p.coeffNamed("e_1_2_0"));
    try std.testing.expectEqual(@as(f32, 1), p.coeffNamed("e123"));
}

test "toMatrix4x4 with identity rotor" {
    const rotor = h.Scalar.init(.{1});
    const mat = toMatrix4x4(rotor);

    try std.testing.expectEqual(@as(f32, 1.0), mat[0][0]);
    try std.testing.expectEqual(@as(f32, 0.0), mat[0][1]);
    try std.testing.expectEqual(@as(f32, 1.0), mat[1][1]);
    try std.testing.expectEqual(@as(f32, 1.0), mat[2][2]);
    try std.testing.expectEqual(@as(f32, 1.0), mat[3][3]);
}

test "pga exposes configurable Euclidean families" {
    const P2 = EuclideanFamily(2).Instantiate(f32);

    try std.testing.expectEqual(@as(usize, 3), EuclideanFamily(2).dimensions);
    try std.testing.expectEqual(@as(f32, 0.0), P2.Basis.e(0).gp(P2.Basis.e(0)).scalarCoeff());
}

test "pga helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f64);
    const p = Helpers.Point.init(1.0, 2.0, 3.0);

    try std.testing.expectEqual(@as(f64, 1.0), p.coeffNamed("e_2_3_0"));
    try std.testing.expectEqual(@as(f64, 1.0), Helpers.toMatrix4x4(Helpers.h.Scalar.init(.{1}))[0][0]);
}

test "pga helpers support non-3d families through coordinate arrays" {
    const Helpers = FamilyHelpers(EuclideanFamily(2), f32);
    const p = Helpers.Point.fromCoords(.{ 1.0, 2.0 });
    const coords = Helpers.ambientCoords(p);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), coords[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), coords[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), coords[2], 1e-6);
}

test "pga exposes complement and anti-product aliases" {
    const E = h.Basis;
    const e0 = E.e(0);
    const e1 = E.e(1);

    try std.testing.expect(complementDual(e1).eql(e1.complementDual()));
    try std.testing.expect(regressiveProduct(e1, e0).eql(e1.antiWedge(e0)));
    try std.testing.expect(geometricAntiproduct(e1, e0).eql(e1.antiGeometric(e0)));
    try std.testing.expect(antidotProduct(e1, e0).eql(e1.antiDot(e0)));
}

test "pga exposes RGA bulk and weight duals" {
    const E = h.Basis;
    const e0 = E.e(0);
    const e1 = E.e(1);
    const mixed = e1.add(e0);

    try std.testing.expect(metricDual(e1).eql(E.signedBlade("e_2_3_0")));
    try std.testing.expect(metricDual(e0).eql(@TypeOf(metricDual(e0)).zero()));
    try std.testing.expect(metricDual(mixed).eql(e1.complementDual()));
    try std.testing.expect(bulkDual(mixed).eql(metricDual(mixed)));

    try std.testing.expect(metricAntidual(e0).eql(E.signedBlade("-e123")));
    try std.testing.expect(metricAntidual(e1).eql(@TypeOf(metricAntidual(e1)).zero()));
    try std.testing.expect(metricAntidual(mixed).eql(e0.complementDual()));
    try std.testing.expect(weightDual(mixed).eql(metricAntidual(mixed)));
}

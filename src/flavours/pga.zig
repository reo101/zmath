const std = @import("std");

pub const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");
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
/// Ambient dimension of the PGA algebra (4).
pub const dimension = bindings.dimension;
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
            ga.multivector.ensureMultivector(@TypeOf(mv));
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

fn namedBasisIndex(comptime named_index: usize) usize {
    return bindings.resolveNamedBasisIndex(named_index);
}

test "pga signature has correct dimension and basis-vector squares" {
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
    try std.testing.expect(e1e0.coeffNamedWithOptions("e_1_0", bindings.naming_options) != 0.0);

    // e0 * e1 should give the opposite sign
    const e0e1 = e0.gp(e1);
    try std.testing.expectEqual(
        -e1e0.coeffNamedWithOptions("e_1_0", bindings.naming_options),
        e0e1.coeffNamedWithOptions("e_1_0", bindings.naming_options),
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
    try std.testing.expect(line.coeffNamedWithOptions("e12", bindings.naming_options) != 0.0);

    // The line should also have moment components involving e0
    _ = e3; // e3 unused here but available for 3D tests
}

test "fullSignedBladeFromIndicesWithSignature respects degenerate square" {
    // Repeated degenerate index should give zero
    const result = ga.multivector.fullSignedBladeFromIndicesWithSignature(f64, metric_signature, &.{ dimension, dimension });
    // e0*e0 = 0, so the scalar part must be zero
    try std.testing.expectEqual(@as(f64, 0.0), result.scalarCoeff());
}

test "pga signed blade parser accepts e0 alias for degenerate basis" {
    const parsed = ga.blade_parsing.parseSignedBlade("e0", dimension, bindings.naming_options, false);
    try std.testing.expectEqual(ga.blades.SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, try parsed);

    const E = h.Basis;
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expectError(error.InvalidBasisIndex, ga.blade_parsing.resolveNamedBasisIndex(4, dimension, bindings.naming_options, false));
    try std.testing.expectError(error.InvalidBasisIndex, ga.blade_parsing.parseSignedBlade("e4", dimension, bindings.naming_options, false));
    try std.testing.expectError(error.InvalidBasisIndex, ga.blade_parsing.parseSignedBlade("e14", dimension, bindings.naming_options, false));
}

test "Point.init correctly constructs trivectors" {
    const p = Point.init(1, 2, 3);

    // x*e230 + y*e310 + z*e120 + e123
    try std.testing.expectEqual(@as(f32, 1), p.coeffNamedWithOptions("e_2_3_0", bindings.naming_options));
    try std.testing.expectEqual(@as(f32, 2), p.coeffNamedWithOptions("e_3_1_0", bindings.naming_options));
    try std.testing.expectEqual(@as(f32, 3), p.coeffNamedWithOptions("e_1_2_0", bindings.naming_options));
    try std.testing.expectEqual(@as(f32, 1), p.coeffNamedWithOptions("e123", bindings.naming_options));
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

    try std.testing.expectEqual(@as(usize, 3), EuclideanFamily(2).dimension);
    try std.testing.expectEqual(@as(f32, 0.0), P2.Basis.e(0).gp(P2.Basis.e(0)).scalarCoeff());
}

test "pga helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f64);
    const p = Helpers.Point.init(1.0, 2.0, 3.0);

    try std.testing.expectEqual(@as(f64, 1.0), p.coeffNamedWithOptions("e_2_3_0", bindings.naming_options));
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

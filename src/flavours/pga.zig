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
        const Self = @This();

        pub const h = H;

        pub const Point = struct {
            pub fn initHomogeneousCoords(w: T, coords: [H.Full.dimensions - 1]T) H.Full {
                return Shared.Point.initHomogeneousCoords(w, coords);
            }

            pub fn fromCoords(coords: [H.Full.dimensions - 1]T) H.Full {
                return Shared.Point.fromCoords(coords);
            }

            pub fn init(x: T, y: T, z: T) H.Full {
                if (comptime H.Full.dimensions != 4) {
                    @compileError("`Point.init(x, y, z)` is only available for 3D PGA; use `Point.fromCoords()` for other dimensions");
                }
                return Shared.Point.fromCoords(.{ x, y, z });
            }

            pub fn directionFromCoords(coords: [H.Full.dimensions - 1]T) H.Full {
                return Shared.Point.directionFromCoords(coords);
            }

            pub fn direction(x: T, y: T, z: T) H.Full {
                if (comptime H.Full.dimensions != 4) {
                    @compileError("`Point.direction(x, y, z)` is only available for 3D PGA; use `Point.directionFromCoords()` for other dimensions");
                }
                return Shared.Point.directionFromCoords(.{ x, y, z });
            }
        };

        pub const Plane = struct {
            pub fn init(a: T, b: T, c: T, d: T) H.Full {
                // Plane: a*e1 + b*e2 + c*e3 + d*e0
                return H.exprAs(H.Full, "{a}*e1 + {b}*e2 + {c}*e3 + {d}*e0", .{ .a = a, .b = b, .c = c, .d = d });
            }
        };

        pub const Motor = H.Even;
        pub const Rotor = H.Even;

        /// Converts the raw PGA versor action on basis vectors to a 4x4 matrix.
        /// For homogeneous point transforms, use `toPointMatrix4x4()`.
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

        /// Converts the facade's point `transform()` action to a homogeneous 4x4 matrix.
        pub fn toPointMatrix4x4(motor: anytype) [4][4]T {
            if (comptime H.Full.dimensions != 4) {
                @compileError("`toPointMatrix4x4()` is only available for 3D PGA");
            }

            const columns = [_]H.Full{
                Self.Point.initHomogeneousCoords(1, .{ 0, 0, 0 }),
                Self.Point.direction(1, 0, 0),
                Self.Point.direction(0, 1, 0),
                Self.Point.direction(0, 0, 1),
            };

            var mat: [4][4]T = undefined;
            inline for (columns, 0..) |point, j| {
                const coords = Self.ambientCoords(Self.transform(point, motor));
                inline for (0..4) |i| {
                    mat[i][j] = coords[i];
                }
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

        pub fn meet(lhs: anytype, rhs: anytype) @TypeOf(lhs.meet(rhs)) {
            return lhs.meet(rhs);
        }

        pub fn regressiveProduct(lhs: anytype, rhs: anytype) @TypeOf(lhs.antiWedge(rhs)) {
            return lhs.antiWedge(rhs);
        }

        pub fn join(lhs: anytype, rhs: anytype) @TypeOf(lhs.join(rhs)) {
            return lhs.join(rhs);
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

        pub fn sandwich(value: anytype, motor: anytype) @TypeOf(value.sandwich(motor)) {
            return value.sandwich(motor);
        }

        pub fn transform(value: anytype, motor: anytype) @TypeOf(motor.reverse().gp(value).gp(motor).cast(@TypeOf(value))) {
            return motor.reverse().gp(value).gp(motor).cast(@TypeOf(value));
        }

        pub fn identityMotor() H.Even {
            return H.Scalar.init(.{1}).cast(H.Even);
        }

        pub fn translatorFromCoords(delta: [H.Full.dimensions - 1]T) H.Even {
            const E = H.Basis;
            var result = Self.identityMotor();
            inline for (delta, 0..) |component, i| {
                const basis = E.e(i + 1).wedge(E.e(0)).gradePart(2);
                result = result.add(basis.scale(-0.5 * component)).cast(H.Even);
            }
            return result;
        }

        pub fn translator(x: T, y: T, z: T) H.Even {
            if (comptime H.Full.dimensions != 4) {
                @compileError("`translator(x, y, z)` is only available for 3D PGA; use `translatorFromCoords()` for other dimensions");
            }
            return Self.translatorFromCoords(.{ x, y, z });
        }

        pub fn rotorInPlane(comptime a: usize, comptime b_idx: usize, angle_radians: T) H.Even {
            const E = H.Basis;
            const half_angle = angle_radians / 2.0;
            const plane = E.e(a).wedge(E.e(b_idx)).gradePart(2);
            return H.Scalar.init(.{@cos(half_angle)})
                .add(plane.scale(@sin(half_angle)))
                .cast(H.Even);
        }

        pub fn composeMotors(lhs: anytype, rhs: anytype) H.Even {
            return lhs.gp(rhs).cast(H.Even);
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
pub const Motor = default_helpers.Motor;
pub const Rotor = default_helpers.Rotor;
pub const toMatrix4x4 = default_helpers.toMatrix4x4;
pub const toPointMatrix4x4 = default_helpers.toPointMatrix4x4;
pub const ambientCoords = default_helpers.ambientCoords;
pub const geometricProduct = default_helpers.geometricProduct;
pub const exteriorProduct = default_helpers.exteriorProduct;
pub const meet = default_helpers.meet;
pub const regressiveProduct = default_helpers.regressiveProduct;
pub const join = default_helpers.join;
pub const geometricAntiproduct = default_helpers.geometricAntiproduct;
pub const dotProduct = default_helpers.dotProduct;
pub const antidotProduct = default_helpers.antidotProduct;
pub const complementDual = default_helpers.complementDual;
pub const sandwich = default_helpers.sandwich;
pub const transform = default_helpers.transform;
pub const identityMotor = default_helpers.identityMotor;
pub const translatorFromCoords = default_helpers.translatorFromCoords;
pub const translator = default_helpers.translator;
pub const rotorInPlane = default_helpers.rotorInPlane;
pub const composeMotors = default_helpers.composeMotors;
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
    const p = Point.init(1, 0, 0);
    const q = Point.init(0, 1, 0);

    // In this PGA facade, points are trivectors and their line is a join.
    const line = join(p, q).gradePart(2);

    try std.testing.expect(line.sumCoeffsSquared() != 0.0);
}

test "runtime blade helpers distinguish named and internal indices" {
    const E = h.Basis;

    // Internal index 4 is named e0 in the default PGA basis.
    try std.testing.expect(E.fromInternalIndices(&.{ dimensions, dimensions }).eql(E.Full.zero()));
    try std.testing.expect((try E.fromNamedIndices(&.{ 0, 0 })).eql(E.Full.zero()));
    try std.testing.expect((try E.fromNamedIndices(&.{0})).eql(E.e(0).cast(E.Full)));
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
    const coords = ambientCoords(p);

    try std.testing.expectEqual(@as(f32, 1), coords[0]);
    try std.testing.expectEqual(@as(f32, 1), coords[1]);
    try std.testing.expectEqual(@as(f32, 2), coords[2]);
    try std.testing.expectEqual(@as(f32, 3), coords[3]);
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

test "toPointMatrix4x4 matches PGA point transforms" {
    const mat = toPointMatrix4x4(translator(4, -1, 2));

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat[0][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), mat[1][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), mat[2][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mat[3][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat[1][1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat[2][2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat[3][3], 1e-5);

    const p = Point.init(1, 2, 3);
    const moved = transform(p, translator(4, -1, 2));
    const coords = ambientCoords(moved);

    try std.testing.expectApproxEqAbs(coords[0], mat[0][0] + mat[0][1] + 2 * mat[0][2] + 3 * mat[0][3], 1e-5);
    try std.testing.expectApproxEqAbs(coords[1], mat[1][0] + mat[1][1] + 2 * mat[1][2] + 3 * mat[1][3], 1e-5);
    try std.testing.expectApproxEqAbs(coords[2], mat[2][0] + mat[2][1] + 2 * mat[2][2] + 3 * mat[2][3], 1e-5);
    try std.testing.expectApproxEqAbs(coords[3], mat[3][0] + mat[3][1] + 2 * mat[3][2] + 3 * mat[3][3], 1e-5);
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

test "pga motors translate and rotate points" {
    const p = Point.init(1, 2, 3);
    const moved = transform(p, translator(4, -1, 2));
    const moved_coords = ambientCoords(moved);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), moved_coords[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), moved_coords[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), moved_coords[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), moved_coords[3], 1e-5);

    const turn = rotorInPlane(1, 2, std.math.pi / 2.0);
    const rotated = transform(Point.init(1, 0, 0), turn);
    const rotated_coords = ambientCoords(rotated);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated_coords[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated_coords[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated_coords[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated_coords[3], 1e-5);
}

test "pga exposes complement and anti-product aliases" {
    const E = h.Basis;
    const e0 = E.e(0);
    const e1 = E.e(1);

    try std.testing.expect(complementDual(e1).eql(e1.complementDual()));
    try std.testing.expect(meet(e1, e0).eql(e1.wedge(e0)));
    try std.testing.expect(regressiveProduct(e1, e0).eql(e1.antiWedge(e0)));
    try std.testing.expect(join(e1, e0).eql(e1.join(e0)));
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

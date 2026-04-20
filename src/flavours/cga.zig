const std = @import("std");
const ga = @import("../ga.zig");
const family = ga.family;
const conformal_helpers = @import("conformal_helpers.zig");

/// CGA signature `Cl(4, 1, 0)`: four positive basis vectors and one negative.
/// Typically used to model 3D Euclidean space conformally.
///
/// 3D points are mapped to null vectors in 5D.
const default_family = b: {
    const sig = ga.blades.MetricSignature{ .p = 4, .q = 1, .r = 0 };
    const spans = ga.blades.BasisIndexSpans.fromSignature(sig);
    // Use explicit aliases so named-field access stays stable.
    const opts = ga.NamingOptions.withBasisNames(spans, .{ "e1", "e2", "e3", "eo", "e∞" });
    break :b ga.family.withNamingOptions(sig, opts);
};

fn makeCgaBasisNames(comptime o_idx: usize, comptime inf_idx: usize) [inf_idx][]const u8 {
    const S = struct {
        fn make(comptime oi: usize, comptime infi: usize) [infi][]const u8 {
            var n: [infi][]const u8 = undefined;
            inline for (0..n.len) |i| {
                n[i] = std.fmt.comptimePrint("e{d}", .{i + 1});
            }
            n[oi - 1] = "eo";
            n[infi - 1] = "e∞";
            return n;
        }
    };
    return comptime S.make(o_idx, inf_idx);
}

pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    const sig = ga.blades.MetricSignature{ .p = @intCast(euclidean_dimensions + 1), .q = 1, .r = 0 };
    const spans = ga.blades.BasisIndexSpans.fromSignature(sig);
    // The last two indices are always Origin and Infinity
    const o_idx = euclidean_dimensions + 1;
    const inf_idx = euclidean_dimensions + 2;
    const opts = ga.NamingOptions.withBasisNames(spans, makeCgaBasisNames(o_idx, inf_idx));
    return ga.family.withNamingOptions(sig, opts);
}

const bindings = family.defaultBindings(default_family, f32);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
/// Ambient dimensions of the CGA algebra (5).
pub const dimensions = bindings.dimensions;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub fn FamilyHelpers(comptime FamilyType: type, comptime T: type) type {
    return conformal_helpers.ConformalEuclideanHelpers(T, FamilyType.Instantiate(T));
}

pub fn InstantiateHelpers(comptime T: type) type {
    return FamilyHelpers(Family, T);
}

const default_helpers = InstantiateHelpers(default_scalar);
pub const no = default_helpers.no;
pub const ninf = default_helpers.ninf;
pub const Point = default_helpers.Point;
pub const Sphere = default_helpers.Sphere;
pub const Plane = default_helpers.Plane;

test "cga origin and infinity are null vectors" {
    // n_o^2 = 0, n_inf^2 = 0
    try std.testing.expectEqual(@as(f32, 0.0), h.normSquared(no));
    try std.testing.expectEqual(@as(f32, 0.0), h.normSquared(ninf));
    
    // n_o . n_inf = -1
    try std.testing.expectEqual(@as(f32, -1.0), no.dot(ninf).scalarCoeff());
}

test "cga points are null vectors" {
    const p = Point.init(1, 2, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), h.normSquared(p), 1e-6);
}

test "cga exposes configurable Euclidean families" {
    const C2 = EuclideanFamily(2).Instantiate(f32);
    const e4 = C2.Basis.e(4);

    try std.testing.expectEqual(@as(usize, 4), EuclideanFamily(2).dimensions);
    try std.testing.expectEqual(@as(f32, -1.0), e4.gp(e4).scalarCoeff());
}

test "cga helpers support non-3d conformal families through coordinate arrays" {
    const Helpers = FamilyHelpers(EuclideanFamily(2), f32);
    const p = Helpers.Point.fromCoords(.{ 0.25, -0.5 });
    const plane = Helpers.Plane.fromNormal(.{ 1.0, 0.0 }, 0.25);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Helpers.h.normSquared(p), 1e-6);
    try std.testing.expect(plane.coeffNamed("e1") != 0.0);
}

test "cga helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f64);
    const p = Helpers.Point.init(1.0, 2.0, 3.0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), Helpers.h.normSquared(p), 1e-8);
}

test "cga basis naming uses custom aliases" {
    const E = h.Basis;
    const eo = E.e(4);
    const einf = E.e(5);

    try std.testing.expectEqual(@as(f32, 1.0), eo.named().eo);
    try std.testing.expectEqual(@as(f32, 1.0), einf.named().@"e∞");
}

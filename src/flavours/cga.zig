const std = @import("std");
const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");

/// CGA signature `Cl(4, 1, 0)`: four positive basis vectors and one negative.
/// Typically used to model 3D Euclidean space conformally.
///
/// 3D points are mapped to null vectors in 5D.
const default_family = family.conformalEuclidean(3);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return family.conformalEuclidean(euclidean_dimensions);
}

const bindings = family.defaultBindings(default_family, f32);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const metric_signature = bindings.metric_signature;
/// Ambient dimension of the CGA algebra (5).
pub const dimension = bindings.dimension;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub fn InstantiateHelpers(comptime T: type) type {
    const H = Instantiate(T);

    return struct {
        const Self = @This();
        pub const h = H;

        /// Null basis vectors for the origin and infinity.
        /// n_o = 0.5 * (e_minus - e_plus)
        /// n_inf = e_plus + e_minus
        pub const no = H.Basis.e(5).sub(H.Basis.e(4)).scale(0.5);
        pub const ninf = H.Basis.e(4).add(H.Basis.e(5));

        pub const Point = struct {
            /// Maps a 3D Euclidean vector (x,y,z) to a CGA null vector.
            /// P = n_o + x*e1 + y*e2 + z*e3 + 0.5*(x^2+y^2+z^2)*n_inf
            pub fn init(x: T, y: T, z: T) H.Vector {
                const E = H.Basis;
                const r2 = x * x + y * y + z * z;
                return Self.no
                    .add(E.e(1).scale(x))
                    .add(E.e(2).scale(y))
                    .add(E.e(3).scale(z))
                    .add(Self.ninf.scale(0.5 * r2));
            }
        };

        pub const Sphere = struct {
            /// A sphere is a vector in CGA.
            /// S = P - 0.5 * r^2 * n_inf
            pub fn init(center_x: T, center_y: T, center_z: T, radius: T) H.Vector {
                const P = Self.Point.init(center_x, center_y, center_z);
                return P.sub(Self.ninf.scale(0.5 * radius * radius));
            }
        };

        pub const Plane = struct {
            /// A plane is a vector in CGA (a sphere with infinite radius).
            /// PI = n + d*n_inf
            pub fn init(nx: T, ny: T, nz: T, d: T) H.Vector {
                const E = H.Basis;
                return E.e(1).scale(nx)
                    .add(E.e(2).scale(ny))
                    .add(E.e(3).scale(nz))
                    .add(Self.ninf.scale(d));
            }
        };
    };
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

    try std.testing.expectEqual(@as(usize, 4), EuclideanFamily(2).dimension);
    try std.testing.expectEqual(@as(f32, -1.0), e4.gp(e4).scalarCoeff());
}

test "cga helpers are instantiatable by scalar type" {
    const Helpers = InstantiateHelpers(f64);
    const p = Helpers.Point.init(1.0, 2.0, 3.0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), Helpers.h.normSquared(p), 1e-8);
}

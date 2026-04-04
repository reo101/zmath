const std = @import("std");
const ga = @import("../ga.zig");

/// CGA signature `Cl(4, 1, 0)`: four positive basis vectors and one negative.
/// Typically used to model 3D Euclidean space conformally.
///
/// 3D points are mapped to null vectors in 5D.
const sig: ga.MetricSignature = .{ .p = 4, .q = 1, .r = 0 };
pub const metric_signature = sig;

/// Ambient dimension of the CGA algebra (5).
pub const dimension = sig.dimension();

const basis_spans = ga.BasisIndexSpans.init(.{
    .positive = .range(1, 4),
    .negative = .singleton(5),
});

const naming_options = ga.SignedBladeNamingOptions.withBasisSpans(basis_spans);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return struct {
        const family_metric_signature: ga.MetricSignature = .{
            .p = euclidean_dimensions + 1,
            .q = 1,
            .r = 0,
        };
        pub const metric_signature = family_metric_signature;
        pub const dimension = family_metric_signature.dimension();
        const family_basis_spans = ga.BasisIndexSpans.init(.{
            .positive = .range(1, euclidean_dimensions + 1),
            .negative = .singleton(euclidean_dimensions + 2),
        });
        const family_naming_options = ga.SignedBladeNamingOptions.withBasisSpans(family_basis_spans);
        pub const naming_options = family_naming_options;
        const family_algebra = ga.AlgebraWithNamingOptions(family_metric_signature, family_naming_options);
        pub const Algebra = family_algebra;

        pub fn Instantiate(comptime T: type) type {
            return family_algebra.Instantiate(T);
        }
    };
}

const default_family = EuclideanFamily(3);
pub const Algebra = default_family.Algebra;

pub fn Instantiate(comptime T: type) type {
    return default_family.Instantiate(T);
}

pub const h = Instantiate(f32);

/// Null basis vectors for the origin and infinity.
/// n_o = 0.5 * (e_minus - e_plus)
/// n_inf = e_plus + e_minus
/// (Where e_plus/e_minus are the 4th/5th basis vectors typically)
/// In our Cl(4,1), we use e4 (+) and e5 (-).
pub const no = h.Basis.e(5).sub(h.Basis.e(4)).scale(0.5);
pub const ninf = h.Basis.e(4).add(h.Basis.e(5));

pub const Point = struct {
    /// Maps a 3D Euclidean vector (x,y,z) to a CGA null vector.
    /// P = n_o + x*e1 + y*e2 + z*e3 + 0.5*(x^2+y^2+z^2)*n_inf
    pub fn init(x: f32, y: f32, z: f32) h.Vector {
        const E = h.Basis;
        const r2 = x*x + y*y + z*z;
        return no
            .add(E.e(1).scale(x))
            .add(E.e(2).scale(y))
            .add(E.e(3).scale(z))
            .add(ninf.scale(0.5 * r2));
    }
};

pub const Sphere = struct {
    /// A sphere is a vector in CGA.
    /// S = P - 0.5 * r^2 * n_inf
    pub fn init(center_x: f32, center_y: f32, center_z: f32, radius: f32) h.Vector {
        const P = Point.init(center_x, center_y, center_z);
        return P.sub(ninf.scale(0.5 * radius * radius));
    }
};

pub const Plane = struct {
    /// A plane is a vector in CGA (a sphere with infinite radius).
    /// PI = n + d*n_inf
    pub fn init(nx: f32, ny: f32, nz: f32, d: f32) h.Vector {
        const E = h.Basis;
        return E.e(1).scale(nx)
            .add(E.e(2).scale(ny))
            .add(E.e(3).scale(nz))
            .add(ninf.scale(d));
    }
};

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

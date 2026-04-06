const std = @import("std");

pub const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");

pub const MetricSignature = ga.MetricSignature;

/// Elliptic projective algebra signature `Cl(4, 0, 0)`: four positive basis
/// vectors with homogeneous naming `e0..e3`.
const sig: MetricSignature = .{ .p = 4, .q = 0, .r = 0 };
pub const metric_signature = sig;

/// Ambient dimension of the algebra (4).
pub const dimension = sig.dimension();
const basis_spans = ga.BasisIndexSpans.init(.{
    .positive = .range(0, 3),
});

const naming_options = ga.SignedBladeNamingOptions.withBasisSpans(basis_spans);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return family.withBasisSpans(
        .{
            .p = euclidean_dimensions + 1,
            .q = 0,
            .r = 0,
        },
        ga.BasisIndexSpans.init(.{
            .positive = .range(0, euclidean_dimensions),
        }),
    );
}

const default_family = EuclideanFamily(3);
const bindings = family.defaultBindings(default_family, f32);
pub const Family = bindings.Family;
pub const default_scalar = bindings.default_scalar;
pub const Algebra = bindings.Algebra;
pub const Instantiate = bindings.Instantiate;
pub const h = bindings.h;

pub const Point = struct {
    pub fn initHomogeneous(w: f32, x: f32, y: f32, z: f32) h.Full {
        return h.exprAs(
            h.Full,
            "{w}*e123 + {x}*e320 + {y}*e130 + {z}*e210",
            .{ .w = w, .x = x, .y = y, .z = z },
        );
    }

    pub fn init(x: f32, y: f32, z: f32) h.Full {
        return initHomogeneous(1.0, x, y, z);
    }

    /// Returns a normalized elliptic point on the unit 3-sphere chart.
    pub fn proper(x: f32, y: f32, z: f32) h.Full {
        // Elliptic `E^3` points normalize onto the unit 3-sphere in the
        // homogeneous model. Reference: https://arxiv.org/abs/1310.2713
        const inv = 1.0 / @sqrt(1.0 + x * x + y * y + z * z);
        return initHomogeneous(inv, x * inv, y * inv, z * inv);
    }
};

pub fn ambientCoords(p: anytype) [4]f32 {
    ga.ensureMultivector(@TypeOf(p));
    return .{
        @floatCast(p.coeffNamedWithOptions("e123", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e320", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e130", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e210", naming_options)),
    };
}

fn namedBasisIndex(comptime named_index: usize) usize {
    return comptime ga.blade_parsing.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
}

test "epga signature exposes homogeneous e0 naming on positive basis" {
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(0)));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(1)));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(2)));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(3)));
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

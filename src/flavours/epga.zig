const std = @import("std");

pub const ga = @import("../ga.zig");

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
const algebra = ga.AlgebraWithNamingOptions(sig, naming_options);
pub const h = algebra.Instantiate(f32);

pub const Point = struct {
    pub fn initHomogeneous(w: f32, x: f32, y: f32, z: f32) h.Full {
        const E = h.Basis;
        const res = E.signedBlade("e123").scale(w)
            .add(E.signedBlade("e320").scale(x))
            .add(E.signedBlade("e130").scale(y))
            .add(E.signedBlade("e210").scale(z));

        var full = h.Full.zero();
        inline for (h.Full.blades, 0..) |mask, i| {
            full.coeffs[i] = res.coeff(mask);
        }
        return full;
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
    return comptime ga.resolveNamedBasisIndex(named_index, dimension, naming_options, true);
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

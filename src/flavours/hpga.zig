const std = @import("std");

pub const ga = @import("../ga.zig");

pub const MetricSignature = ga.MetricSignature;

/// Hyperbolic projective algebra signature `Cl(3, 1, 0)`: three positive
/// spatial basis vectors and one negative homogeneous basis vector `e0`.
const sig: MetricSignature = .{ .p = 3, .q = 1, .r = 0 };
pub const metric_signature = sig;

/// Ambient dimension of the algebra (4).
pub const dimension = sig.dimension();
const basis_spans = ga.BasisIndexSpans.init(.{
    .positive = .range(1, 3),
    .negative = .singleton(0),
});

const naming_options = ga.SignedBladeNamingOptions.withBasisSpans(basis_spans);
pub const Algebra = ga.AlgebraWithNamingOptions(sig, naming_options);

pub fn Instantiate(comptime T: type) type {
    return Algebra.Instantiate(T);
}

pub const h = Instantiate(f32);

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

    /// Returns a normalized proper point inside the unit ball.
    pub fn proper(x: f32, y: f32, z: f32) ?h.Full {
        const r2 = x * x + y * y + z * z;
        if (r2 >= 1.0) return null;

        // Proper `H^3` points lie inside the Klein ball and normalize onto the
        // unit hyperboloid. Reference: https://arxiv.org/pdf/1602.08562
        const inv = 1.0 / @sqrt(1.0 - r2);
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

test "hpga signature has expected basis classes" {
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(1)));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(2)));
    try std.testing.expectEqual(.positive, sig.basisSquareClass(namedBasisIndex(3)));
    try std.testing.expectEqual(.negative, sig.basisSquareClass(namedBasisIndex(0)));
}

test "hpga proper point normalizes onto the hyperboloid" {
    const p = Point.proper(0.2, -0.1, 0.3).?;
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.gp(p).scalarCoeff(), 1e-5);
}

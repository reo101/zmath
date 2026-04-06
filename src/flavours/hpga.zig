const std = @import("std");

pub const ga = @import("../ga.zig");
const family = @import("../ga/family.zig");

pub const MetricSignature = ga.blades.MetricSignature;

/// Hyperbolic projective algebra signature `Cl(3, 1, 0)`: three positive
/// spatial basis vectors and one negative homogeneous basis vector `e0`.
const default_family = family.projectiveHyperbolic(3);
pub fn EuclideanFamily(comptime euclidean_dimensions: usize) type {
    return family.projectiveHyperbolic(euclidean_dimensions);
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
const naming_options = bindings.naming_options;

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
    ga.multivector.ensureMultivector(@TypeOf(p));
    return .{
        @floatCast(p.coeffNamedWithOptions("e123", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e320", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e130", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e210", naming_options)),
    };
}

fn namedBasisIndex(comptime named_index: usize) usize {
    return bindings.resolveNamedBasisIndex(named_index);
}

test "hpga signature has expected basis classes" {
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(1)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(2)));
    try std.testing.expectEqual(.positive, metric_signature.basisSquareClass(namedBasisIndex(3)));
    try std.testing.expectEqual(.negative, metric_signature.basisSquareClass(namedBasisIndex(0)));
}

test "hpga proper point normalizes onto the hyperboloid" {
    const p = Point.proper(0.2, -0.1, 0.3).?;
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), p.gp(p).scalarCoeff(), 1e-5);
}

test "hpga exposes configurable Euclidean families" {
    const H2 = EuclideanFamily(2).Instantiate(f32);
    const e0 = H2.Basis.e(0);
    const e1 = H2.Basis.e(1);

    try std.testing.expectEqual(@as(usize, 3), EuclideanFamily(2).dimension);
    try std.testing.expectEqual(@as(f32, -1.0), e0.gp(e0).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), e1.gp(e1).scalarCoeff());
}

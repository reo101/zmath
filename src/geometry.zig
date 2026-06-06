const std = @import("std");

pub const curved = @import("geometry/curved.zig");
pub const curved_ambient = @import("geometry/curved_ambient.zig");
pub const curved_camera = @import("geometry/curved_camera.zig");
pub const curved_charts = @import("geometry/curved_charts.zig");
pub const curved_sampling = @import("geometry/curved_sampling.zig");
pub const curved_surface = @import("geometry/curved_surface.zig");
pub const curved_tangent = @import("geometry/curved_tangent.zig");
pub const curved_types = @import("geometry/curved_types.zig");
pub const curved_view = @import("geometry/curved_view.zig");
pub const constant_curvature = @import("geometry/constant_curvature.zig");

test "constant curvature conformal embeddings round-trip through GA helpers" {
    const sample = constant_curvature.Vec3{ .x = 0.4, .y = -0.2, .z = 0.7 };
    inline for (.{ constant_curvature.Metric.spherical, constant_curvature.Metric.hyperbolic }) |metric| {
        const raw = constant_curvature.embedConformal(metric, 5.0, sample).?;
        const ga = constant_curvature.embedConformalGa(metric, 5.0, sample).?;
        inline for (raw.asArray(), ga.asArray()) |lhs, rhs| {
            try std.testing.expectApproxEqAbs(lhs, rhs, 1e-6);
        }
    }
}

test "constant curvature projective embeddings match EPGA and HPGA proper helpers" {
    const sample = constant_curvature.Vec3{ .x = 0.3, .y = -0.4, .z = 0.8 };
    inline for (.{ constant_curvature.Metric.spherical, constant_curvature.Metric.hyperbolic }) |metric| {
        const raw = constant_curvature.embedProjective(metric, 4.0, sample).?;
        const ga = constant_curvature.embedProjectiveGa(metric, 4.0, sample).?;
        inline for (raw.asArray(), ga.asArray()) |lhs, rhs| {
            try std.testing.expectApproxEqAbs(lhs, rhs, 1e-6);
        }
    }
}

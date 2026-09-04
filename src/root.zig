const std = @import("std");

pub const ga = @import("ga");
pub const geometry = @import("geometry");
pub const parse = @import("parse");

test "root surface links ga and geometry entrypoints" {
    try std.testing.expectEqual(@as(usize, 3), ga.Algebra(.euclidean(3)).dimensions);
    try std.testing.expectEqual(@as(usize, 4), ga.Algebra(.euclidean(4)).dimensions);

    const E2 = ga.Algebra(.euclidean(2)).Instantiate(f64);
    const e1 = E2.Basis.e(1);
    const rotor = ga.rotors.planarRotor(f64, std.math.pi / 2.0);
    const turned = ga.rotors.rotated(e1, rotor);
    try std.testing.expect(ga.rotors.nearlyEqual(turned.coeffNamed("e1"), 0.0, 1e-12));
    try std.testing.expect(ga.rotors.nearlyEqual(turned.coeffNamed("e2"), 1.0, 1e-12));
    try std.testing.expectEqual(@as(f64, 1.0), E2.Basis.e(1).gp(E2.Basis.e(1)).scalarCoeff());

    const STA = ga.Algebra(.{ .p = 1, .q = 3 }).Instantiate(f64);
    try std.testing.expectEqual(@as(f64, 1.0), STA.Basis.e(1).gp(STA.Basis.e(1)).scalarCoeff());
    try std.testing.expectEqual(@as(f64, -1.0), STA.Basis.e(2).gp(STA.Basis.e(2)).scalarCoeff());
}

test "geometry exposes constant-curvature and spherical-game kernels" {
    _ = geometry.spherical_game.Pose.north(1.0);
    try std.testing.expect(geometry.constant_curvature.embedProjective(.hyperbolic, 4.0, .{ .x = 0.3, .y = 0, .z = 0.4 }) != null);
}

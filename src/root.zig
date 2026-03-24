const std = @import("std");

/// Build-time toggle for internal SIMD fast paths.
pub const enable_simd_fast_paths = true;

pub const ga = @import("ga.zig");
pub const vga = @import("vga.zig");
pub const pga = @import("pga.zig");

test "root surface links ga and vga entrypoints" {
    try std.testing.expect(ga.blades.choose(4, 2) == ga.choose(4, 2));
    try std.testing.expectEqual(ga.blades.BladeMask.init(0b010), ga.basisVectorBladeMask(3, 2));

    const E2 = vga.helpers.Basis(f64);
    const e1 = E2.e(1);
    const rotor = vga.planarRotor(f64, std.math.pi / 2.0);
    const turned = vga.rotated(e1, rotor);
    try std.testing.expect(vga.nearlyEqual(turned.coeff(.init(0b01)), 0.0, 1e-12));
    try std.testing.expect(vga.nearlyEqual(turned.coeff(.init(0b10)), 1.0, 1e-12));
}

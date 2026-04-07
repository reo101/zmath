const std = @import("std");

pub const ga = @import("ga.zig");
pub const flavours = @import("flavours.zig");
pub const geometry = @import("geometry.zig");
pub const parse = @import("parse.zig");
pub const render = @import("render.zig");
pub const visualizer = @import("ga/visualizer.zig");

test "root surface links ga and flavours entrypoints" {
    try std.testing.expectEqual(@as(usize, 3), ga.family.euclidean(3).dimension);
    try std.testing.expectEqual(@as(usize, 4), ga.Algebra(.euclidean(4)).dimension);

    const E2 = flavours.vga.h.Basis;
    const e1 = E2.e(1);
    const rotor = flavours.vga.planarRotor(f64, std.math.pi / 2.0);
    const turned = flavours.vga.rotated(e1, rotor);
    try std.testing.expect(flavours.vga.nearlyEqual(turned.coeffNamed("e1"), 0.0, 1e-12));
    try std.testing.expect(flavours.vga.nearlyEqual(turned.coeffNamed("e2"), 1.0, 1e-12));
    try std.testing.expectEqual(@as(f64, 1.0), flavours.vga.h.Basis.e(1).gp(flavours.vga.h.Basis.e(1)).scalarCoeff());

    const ESTA = flavours.sta.h.Basis;
    try std.testing.expectEqual(@as(f64, 1.0), ESTA.e(0).gp(ESTA.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f64, -1.0), ESTA.e(1).gp(ESTA.e(1)).scalarCoeff());
}

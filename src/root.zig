const std = @import("std");

pub const ga = @import("ga.zig");
pub const flavours = @import("flavours.zig");
pub const vga = @import("flavours/vga.zig");
pub const pga = @import("flavours/pga.zig");
pub const hpga = @import("flavours/hpga.zig");
pub const epga = @import("flavours/epga.zig");
pub const sta = @import("flavours/sta.zig");
pub const cga = @import("flavours/cga.zig");
pub const geometry = @import("geometry.zig");
pub const parse = @import("parse.zig");
pub const render = @import("render.zig");
pub const visualizer = @import("ga/visualizer.zig");

test "root surface links ga and vga entrypoints" {
    try std.testing.expect(ga.blades.choose(4, 2) == ga.choose(4, 2));
    try std.testing.expectEqual(ga.blades.BladeMask.init(0b010), ga.basisVectorBladeMask(3, 2));
    try std.testing.expectEqual(@as(usize, 3), flavours.family.euclidean(3).dimension);

    const E2 = vga.h.Basis;
    const e1 = E2.e(1);
    const rotor = vga.planarRotor(f64, std.math.pi / 2.0);
    const turned = vga.rotated(e1, rotor);
    try std.testing.expect(vga.nearlyEqual(turned.coeffNamed("e1"), 0.0, 1e-12));
    try std.testing.expect(vga.nearlyEqual(turned.coeffNamed("e2"), 1.0, 1e-12));
    try std.testing.expectEqual(@as(f64, 1.0), flavours.vga.h.Basis.e(1).gp(flavours.vga.h.Basis.e(1)).scalarCoeff());

    const ESTA = sta.h.Basis;
    try std.testing.expectEqual(@as(f64, 1.0), ESTA.e(0).gp(ESTA.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f64, -1.0), ESTA.e(1).gp(ESTA.e(1)).scalarCoeff());
}

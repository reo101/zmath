const std = @import("std");
const vga = @import("vga");
const ga = vga.ga;

fn Vec(n: usize) type {
    return ga.Algebra(.euclidean(n)).GAVector(f32);
}

/// Interpolated color from the vertex shader.
pub extern var in_color: Vec(3) addrspace(.input);

/// Final fragment color.
pub extern var out_color: Vec(4) addrspace(.output);

fn colorAsGAVector() Vec(2) {
    return .init(.{ in_color.coeffs[0], in_color.coeffs[1] });
}

export fn main() callconv(.spirv_fragment) void {
    const color_xy = colorAsGAVector();
    const e1: ga.BladeMask = ga.Mask.init(0b01);
    const e2: ga.BladeMask = ga.Mask.init(0b10);
    const intensity = @min(vga.norm(color_xy), 1.0);

    out_color = .init(.{ color_xy.coeff(e1), color_xy.coeff(e2), in_color.coeffs[2], intensity });
}

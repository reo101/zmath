const std = @import("std");
const vga = @import("vga");

fn Vec(n: usize) type {
    return vga.ga.Algebra(.euclidean(n)).Vector(f32);
}

/// Interpolated color from the vertex shader.
pub extern var in_color: Vec(3) addrspace(.input);

/// Final fragment color.
pub extern var out_color: Vec(4) addrspace(.output);

export fn main() callconv(.spirv_fragment) void {
    const color_xy = Vec(2).initStorage(.{ in_color.coeffs[0], in_color.coeffs[1] });
    const intensity = @min(vga.norm(color_xy), 1.0);

    out_color = Vec(4).initStorage(.{ color_xy.coeffs[0], color_xy.coeffs[1], in_color.coeffs[2], intensity });
}

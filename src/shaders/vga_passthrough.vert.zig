const std = @import("std");
const gpu = std.gpu;
const vga = @import("vga");
const ga = vga.ga;

fn Vec(n: usize) type {
    return ga.Algebra(.euclidean(n)).GAVector(f32);
}

/// Vertex input position at location 0.
pub extern var in_pos: Vec(2) addrspace(.input);

/// Vertex output color at location 0.
pub extern var out_color: Vec(3) addrspace(.output);

/// Built-in output for clip-space position.
// pub const gl_position = gpu.position_out;
pub const gl_position = @extern(*addrspace(.output) Vec(4), .{ .name = "position" });


const e1: ga.BladeMask = ga.Mask.init(0b01);
const e2: ga.BladeMask = ga.Mask.init(0b10);

export fn main() callconv(.spirv_vertex) void {
    const x = in_pos.coeff(e1);
    const y = in_pos.coeff(e2);
    gl_position.* = .init(.{ x, y, 0.0, 1.0 });

    const radial = @min(@sqrt(x * x + y * y), 1.0);
    out_color = .init(.{ radial, 1.0 - radial, 0.25 });
}

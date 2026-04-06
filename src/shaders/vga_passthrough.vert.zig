const std = @import("std");
const gpu = std.gpu;
const vga = @import("vga");
const ga = vga.ga;

fn Alg(n: usize) type {
    return ga.Algebra(.euclidean(n));
}
fn Vec(n: usize) type {
    return Alg(n).Vector(f32);
}

/// Vertex input position at location 0.
pub extern var in_pos: Vec(2) addrspace(.input);

/// Vertex output color at location 0.
pub extern var out_color: Vec(3) addrspace(.output);

/// Built-in output for clip-space position.
// pub const gl_position = gpu.position_out;
pub const gl_position = @extern(*addrspace(.output) Vec(4), .{ .name = "position" });

// BUG: causes a `SEGV` signal when compiling to `SPIR-V`
// const e1: ga.blades.BladeMask = ga.blades.BladeMask.parsePanicking("e0");
// const e2: ga.blades.BladeMask = ga.blades.BladeMask.parsePanicking("e1");
// comptime {
//     @compileLog(e1, e2);
// }

export fn main() callconv(.spirv_vertex) void {
    // const x = in_pos.coeff(e1);
    // const y = in_pos.coeff(e2);
    const x = in_pos.coeffs[0];
    const y = in_pos.coeffs[1];
    gl_position.* = .init(.{ x, y, 0.0, 1.0 });

    const radial = @min(@sqrt(x * x + y * y), 1.0);
    out_color = .init(.{ radial, 1.0 - radial, 0.25 });
}

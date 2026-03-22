const std = @import("std");
const gpu = std.gpu;

/// Vertex input position at location 0.
pub extern var in_pos: @Vector(2, f32) addrspace(.input);

/// Vertex output color at location 0.
pub extern var out_color: @Vector(3, f32) addrspace(.output);

/// Built-in output for clip-space position.
pub const gl_position = gpu.position_out;

export fn main() callconv(.spirv_vertex) void {
    const pos = in_pos;
    gl_position.* = .{ pos[0], pos[1], 0.0, 1.0 };

    const radial = @min(@sqrt(pos[0] * pos[0] + pos[1] * pos[1]), 1.0);
    out_color = .{ radial, 1.0 - radial, 0.25 };
}

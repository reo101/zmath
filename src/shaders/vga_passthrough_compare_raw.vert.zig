const std = @import("std");
const gpu = std.gpu;

/// Vertex output color at location 0.
pub const out_color = @extern(*addrspace(.output) @Vector(3, f32), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

/// Built-in output for clip-space position.
pub const gl_position = gpu.position_out;

export fn main() callconv(.spirv_vertex) void {
    const pos: @Vector(2, f32) = switch (gpu.vertex_index) {
        0 => .{ -0.85, -0.85 },
        1 => .{ 0.85, -0.85 },
        else => .{ 0.0, 0.85 },
    };

    const radial = @min(@sqrt(pos[0] * pos[0] + pos[1] * pos[1]), 1.0);

    gl_position.* = .{ pos[0], pos[1], 0.0, 1.0 };
    out_color.* = .{ radial, 1.0 - radial, 0.25 };
}

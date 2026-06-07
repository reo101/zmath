const std = @import("std");
const gpu = std.gpu;

pub const gl_position = gpu.position_out;

export fn main() callconv(.spirv_vertex) void {
    const pos: @Vector(2, f32) = switch (gpu.vertex_index) {
        0 => .{ -1.0, -1.0 },
        1 => .{ 3.0, -1.0 },
        else => .{ -1.0, 3.0 },
    };
    gl_position.* = .{ pos[0], pos[1], 0.0, 1.0 };
}

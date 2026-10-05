const std = @import("std");
const spirv = std.spirv;

pub const gl_position = spirv.position_out;

export fn main() callconv(.spirv_vertex) void {
    const pos: @Vector(2, f32) = switch (spirv.vertex_index) {
        0 => .{ -1.0, -1.0 },
        1 => .{ 3.0, -1.0 },
        else => .{ -1.0, 3.0 },
    };
    gl_position.* = .{ pos[0], pos[1], 0.0, 1.0 };
}

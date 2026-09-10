const std = @import("std");

const Vec3 = @Vector(3, f32);
const Vec4 = @Vector(4, f32);

const in_position = @extern(*addrspace(.input) Vec3, .{ .name = "mesh_position", .decoration = .{ .location = 0 } });
const in_color = @extern(*addrspace(.input) Vec4, .{ .name = "mesh_color", .decoration = .{ .location = 1 } });
const in_plane = @extern(*addrspace(.input) Vec4, .{ .name = "mesh_plane", .decoration = .{ .location = 2 } });

pub const out_color = @extern(*addrspace(.output) Vec4, .{ .name = "color", .decoration = .{ .location = 0 } });
pub const out_plane = @extern(*addrspace(.output) Vec4, .{ .name = "plane", .decoration = .{ .location = 1 } });

pub const gl_position = std.gpu.position_out;

export fn main() callconv(.spirv_vertex) void {
    const position = in_position.*;
    gl_position.* = .{ position[0], position[1], position[2], 1.0 };
    out_color.* = in_color.*;
    out_plane.* = in_plane.*;
}

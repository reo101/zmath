const std = @import("std");
const gpu = std.gpu;
const ga = @import("ga");
const vga = @import("vga");

fn Vec(n: usize) type {
    return ga.Algebra(.euclidean(n)).Vector(f32);
}

pub const out_color = @extern(*addrspace(.output) Vec(3), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

pub const gl_position = @extern(*addrspace(.output) Vec(4), .{
    .name = "position",
});

export fn main() callconv(.spirv_vertex) void {
    const position: Vec(2) = .initStorage(@as(@Vector(2, f32), switch (gpu.vertex_index) {
        0 => .{ -0.85, -0.85 },
        1 => .{ 0.85, -0.85 },
        else => .{ 0.0, 0.85 },
    }));

    const xy = position.swizzle("xy");
    const radial = @min(vga.norm(position), 1.0);

    gl_position.* = .initStorage(@as(@Vector(4, f32), .{ xy[0], xy[1], 0.0, 1.0 }));
    out_color.* = .initStorage(@as(@Vector(3, f32), .{ radial, 1.0 - radial, 0.25 }));
}

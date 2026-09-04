const std = @import("std");
const ga = @import("ga");

fn Vec(n: usize) type {
    return ga.Algebra(.euclidean(n)).Vector(f32);
}

/// Interpolated color from the vertex shader.
pub const in_color = @extern(*addrspace(.input) @Vector(3, f32), .{
    .name = "in_color",
    .decoration = .{ .location = 0 },
});

/// Final fragment color.
pub const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.spirv_fragment) void {
    const color: Vec(3) = .initStorage(in_color.*);
    const color_xy = color.swizzleVector("xy");
    const rgb = color.swizzle("xyz");
    const intensity = @min(ga.rotors.norm(color_xy), 1.0);

    out_color.* = .{ rgb[0], rgb[1], rgb[2], intensity };
}

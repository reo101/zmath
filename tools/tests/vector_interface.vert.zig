const std = @import("std");
const ga = @import("ga");
const E4 = ga.Algebra(.euclidean(4)).Instantiate(f32);
const Vec4 = E4.Vector;
const normal = E4.Basis.e(3).cast(Vec4).scale(2.0).divide(2.0).negate().negate();

comptime {
    std.debug.assert(normal.eql(normal.add(normal).sub(normal)));
    std.debug.assert(normal.scalarProduct(normal) == 1.0);
    std.debug.assert(normal.swizzleVector("zyx").coeffNamed("e3") == 1.0);
    const H = ga.Algebra(.{ .p = 2, .q = 1 }).Instantiate(f32);
    const signed = H.Vector.init(.{ 1.0, 2.0, 3.0 });
    std.debug.assert(signed.scalarProduct(signed) == -4.0);
}

pub const gl_position = @extern(*addrspace(.output) Vec4, .{ .name = "position" });

export fn main() callconv(.spirv_vertex) void {
    const x: f32 = @floatFromInt(std.spirv.vertex_index);
    const local = Vec4.init(.{ x, 0.0, normal.coeffNamed("e3"), 1.0 });
    gl_position.* = local;
    const copied = gl_position.*;
    gl_position.* = copied.scale(0.5);
    const coefficients = gl_position.coeffs;
    gl_position.coeffs = coefficients;
    gl_position.coeffs[std.spirv.vertex_index % 4] = x;
    gl_position.coeffs[3] = 1.0;
}

const std = @import("std");
const gpu = std.gpu;

/// Final fragment color.
pub const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.spirv_fragment) void {
    const p = gpu.frag_coord;
    const uv = @Vector(2, f32){ p[0] / 960.0, p[1] / 640.0 };
    const rings = @abs(@sin((uv[0] * uv[0] + uv[1] * uv[1]) * 24.0));
    out_color.* = .{ uv[0], uv[1], rings, 1.0 };
}

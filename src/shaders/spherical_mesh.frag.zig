const std = @import("std");
const s3 = @import("spherical_ga.zig");

const RawVec4 = s3.RawVec4;

const in_color = @extern(*addrspace(.input) RawVec4, .{
    .name = "color",
    .decoration = .{ .location = 0 },
});
const in_plane = @extern(*addrspace(.input) RawVec4, .{
    .name = "plane",
    .decoration = .{ .location = 1 },
});
const frame = @extern(*addrspace(.uniform) const s3.FrameData, .{
    .name = "Frame",
    .decoration = s3.frame_descriptor_decoration,
});

pub const out_color = @extern(*addrspace(.output) RawVec4, .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.spirv_fragment) void {
    const pixel = std.gpu.frag_coord;
    const uv = @Vector(2, f32){
        (pixel[0] / frame.viewport[0]) * 2.0 - 1.0,
        (1.0 - pixel[1] / frame.viewport[1]) * 2.0 - 1.0,
    };
    if (s3.screenRadiusSquared(uv) > 1.0) {
        std.gpu.frag_depth = 1.0;
        out_color.* = in_color.*;
        return;
    }

    const origin = s3.vector(frame.origin);
    const dir = s3.direction(uv, frame.viewport[3], s3.vector(frame.forward), s3.vector(frame.right), s3.vector(frame.up));
    const intersection = s3.greatSphereIntersection(origin, dir, s3.vector(in_plane.*));
    std.gpu.frag_depth = (1.0 - intersection.cos_angle) * 0.5;
    out_color.* = in_color.*;
}

pub const depth_replacing = std.gpu.executionMode(main, .depth_replacing);

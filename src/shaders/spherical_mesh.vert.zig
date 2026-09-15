const std = @import("std");
const s3 = @import("spherical_ga.zig");

const RawVec4 = s3.RawVec4;

const in_point = @extern(*addrspace(.input) RawVec4, .{ .name = "mesh_point", .decoration = .{ .location = 0 } });
const in_color = @extern(*addrspace(.input) RawVec4, .{ .name = "mesh_color", .decoration = .{ .location = 1 } });
const in_plane = @extern(*addrspace(.input) RawVec4, .{ .name = "mesh_plane", .decoration = .{ .location = 2 } });
const frame = @extern(*addrspace(.uniform) const s3.FrameData, .{
    .name = "Frame",
    .decoration = s3.frame_descriptor_decoration,
});

pub const out_color = @extern(*addrspace(.output) RawVec4, .{ .name = "color", .decoration = .{ .location = 0 } });
pub const out_plane = @extern(*addrspace(.output) RawVec4, .{ .name = "plane", .decoration = .{ .location = 1 } });

pub const gl_position = std.gpu.position_out;

export fn main() callconv(.spirv_vertex) void {
    const projection = s3.rasterProjection(
        s3.vector(frame.origin),
        s3.vector(in_point.*),
        s3.vector(frame.forward),
        s3.vector(frame.right),
        s3.vector(frame.up),
        frame.viewport[3],
        1.0,
    );
    const inside_chart = projection.valid and
        projection.clip_w > 0.02 and
        @abs(projection.clip_x) <= 4.0 * projection.clip_w and
        @abs(projection.clip_y) <= 4.0 * projection.clip_w;
    // The zero homogeneous point contributes no projective position, so any
    // triangle touching the chart pole degenerates instead of spanning the screen.
    gl_position.* = if (inside_chart)
        .{ projection.clip_x, projection.clip_y, 0.0, projection.clip_w }
    else
        @splat(0.0);
    out_color.* = in_color.*;
    out_plane.* = in_plane.*;
}

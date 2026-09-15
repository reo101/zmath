const std = @import("std");
const s3 = @import("spherical_ga.zig");

const RawVec4 = s3.RawVec4;

pub const out_color = @extern(*addrspace(.output) RawVec4, .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

const frame = @extern(*addrspace(.uniform) const s3.FrameData, .{
    .name = "Frame",
    .decoration = s3.frame_descriptor_decoration,
});

fn fastAtan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    const largest = @max(ax, ay);
    const smallest = @min(ax, ay);
    if (largest == 0.0) return 0.0;
    const t = smallest / largest;
    const s = t * t;
    const atan_t = t * (0.9998660 + s * (-0.3302995 + s * (0.180141 + s * (-0.085133 + s * 0.0208351))));
    var angle = if (ay > ax) std.math.pi / 2.0 - atan_t else atan_t;
    if (x < 0.0) angle = std.math.pi - angle;
    if (y < 0.0) angle = -angle;
    return angle;
}

fn fastAsin(x: f32) f32 {
    const clamped = std.math.clamp(x, -1.0, 1.0);
    return fastAtan2(clamped, @sqrt(@max(0.0, 1.0 - clamped * clamped)));
}

fn groundColor(point: s3.Vector) RawVec4 {
    const coords = point.swizzle("xyzw");
    const walk = fastAsin(coords[3]) * frame.viewport[2];
    const strafe = fastAtan2(coords[1], coords[0]) * frame.viewport[2];
    const walk_floor = @floor(walk);
    const strafe_floor = @floor(strafe);
    const checker = walk_floor + strafe_floor - @floor((walk_floor + strafe_floor) / 2.0) * 2.0;
    if (checker < 0.5) return .{ 92.0 / 255.0, 104.0 / 255.0, 96.0 / 255.0, 1.0 };
    return .{ 46.0 / 255.0, 54.0 / 255.0, 50.0 / 255.0, 1.0 };
}

export fn main() callconv(.spirv_fragment) void {
    const pixel = std.gpu.frag_coord;
    const uv = @Vector(2, f32){
        (pixel[0] / frame.viewport[0]) * 2.0 - 1.0,
        (1.0 - pixel[1] / frame.viewport[1]) * 2.0 - 1.0,
    };
    if (s3.screenRadiusSquared(uv) > 1.0) {
        out_color.* = .{ 4.0 / 255.0, 6.0 / 255.0, 10.0 / 255.0, 1.0 };
        std.gpu.frag_depth = 1.0;
        return;
    }

    const origin = s3.vector(frame.origin);
    const dir = s3.direction(uv, frame.viewport[3], s3.vector(frame.forward), s3.vector(frame.right), s3.vector(frame.up));
    const intersection = s3.greatSphereIntersection(origin, dir, s3.ground_normal);
    const point = origin.scale(intersection.cos_angle).add(dir.scale(intersection.sin_angle));
    const tangent = dir.scale(intersection.cos_angle).sub(origin.scale(intersection.sin_angle));
    const brightness = @abs(tangent.scalarProduct(s3.ground_normal));
    out_color.* = groundColor(point) * @as(RawVec4, @splat(0.6 + 0.4 * brightness));
    std.gpu.frag_depth = (1.0 - intersection.cos_angle) * 0.5;
}

pub const depth_replacing = std.gpu.executionMode(main, .depth_replacing);

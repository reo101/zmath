const std = @import("std");
const projection = @import("projection.zig");
const curved_ambient = @import("../geometry/curved_ambient.zig");

pub const Vec3 = curved_ambient.Flat3.Vector;

pub const CameraModel = enum {
    linear,
    conformal,
};

pub const DistanceClip = struct {
    near: f32 = 0.0,
    far: f32 = std.math.inf(f32),
};

pub const Screen = struct {
    width: usize,
    height: usize,
    zoom: f32,
};

pub const Sample = struct {
    distance: f32,
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
};

pub const SampleStatus = enum { hidden, visible, clipped_near, clipped_far };

pub const ProjectedSample = struct {
    distance: f32 = 0.0,
    render_depth: f32 = 0.0,
    projected: ?[2]f32 = null,
    status: SampleStatus = .hidden,
};

fn vec3x(v: Vec3) f32 {
    return v.named().e1;
}

fn vec3y(v: Vec3) f32 {
    return v.named().e2;
}

fn vec3z(v: Vec3) f32 {
    return v.named().e3;
}

pub fn projectSample(
    projection_mode: projection.DirectionProjection,
    point_sample: Sample,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    return projection.projectDirectionWith(
        projection_mode,
        point_sample.x_dir,
        point_sample.y_dir,
        point_sample.z_dir,
        canvas_width,
        canvas_height,
        zoom,
    );
}

pub fn projectConformalModelPoint(
    model_point: Vec3,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (vec3x(model_point) * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) * 0.5);
    const y = (1.0 - vec3y(model_point) * zoom) * (@as(f32, @floatFromInt(canvas_height)) * 0.5);
    const limit = @as(f32, @floatFromInt(@max(canvas_width, canvas_height))) * 4.0;
    if (x < -limit or x > @as(f32, @floatFromInt(canvas_width)) + limit) return null;
    if (y < -limit or y > @as(f32, @floatFromInt(canvas_height)) + limit) return null;
    return .{ x, y };
}

pub fn sampleStatus(distance: f32, clip: DistanceClip, projected: ?[2]f32) SampleStatus {
    if (projected == null) return .hidden;
    if (distance < clip.near) return .clipped_near;
    if (distance > clip.far) return .clipped_far;
    return .visible;
}

fn crossesProjectionWrap(a: [2]f32, b: [2]f32, width: usize) bool {
    return @abs(a[0] - b[0]) > @as(f32, @floatFromInt(width)) * 0.45;
}

fn crossesProjectedJump(a: [2]f32, b: [2]f32, width: usize, height: usize) bool {
    const threshold = @as(f32, @floatFromInt(@max(width, height))) * 0.14;
    return @abs(a[0] - b[0]) > threshold or @abs(a[1] - b[1]) > threshold;
}

pub fn shouldBreakProjectionSegment(
    projection_mode: projection.DirectionProjection,
    a: [2]f32,
    b: [2]f32,
    width: usize,
    height: usize,
) bool {
    return switch (projection_mode) {
        .wrapped => crossesProjectionWrap(a, b, width) or crossesProjectedJump(a, b, width, height),
        .gnomonic, .stereographic, .orthographic => crossesProjectedJump(a, b, width, height),
    };
}

pub fn shouldBreakProjectedSegment(
    projection_mode: projection.DirectionProjection,
    a: [2]f32,
    b: [2]f32,
    width: usize,
    height: usize,
) bool {
    return shouldBreakProjectionSegment(projection_mode, a, b, width, height);
}

test "wrapped projection breaks on large horizontal wrap" {
    try std.testing.expect(shouldBreakProjectionSegment(.wrapped, .{ 10.0, 20.0 }, .{ 85.0, 22.0 }, 100, 50));
    try std.testing.expect(!shouldBreakProjectionSegment(.stereographic, .{ 10.0, 20.0 }, .{ 15.0, 22.0 }, 100, 50));
}

test "sample status correctly handles clipping and visibility" {
    const clip = DistanceClip{ .near = 1.0, .far = 10.0 };
    try std.testing.expectEqual(SampleStatus.visible, sampleStatus(5.0, clip, .{ 10.0, 10.0 }));
    try std.testing.expectEqual(SampleStatus.hidden, sampleStatus(5.0, clip, null));
    try std.testing.expectEqual(SampleStatus.clipped_near, sampleStatus(0.5, clip, .{ 10.0, 10.0 }));
    try std.testing.expectEqual(SampleStatus.clipped_far, sampleStatus(15.0, clip, .{ 10.0, 10.0 }));
}

test "projectConformalModelPoint handles aspect ratio and zoom" {
    const point = Vec3.init(.{ 0.0, 0.0, 0.0 });
    const projected = projectConformalModelPoint(point, 200, 100, 1.0).?;
    // Center should be (100, 50)
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), projected[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), projected[1], 1e-5);

    const offset_point = Vec3.init(.{ 0.1, 0.1, 0.0 });
    const projected_offset = projectConformalModelPoint(offset_point, 200, 100, 1.0).?;
    // x = (0.1 * 1.0 / (200/200) + 1.0) * 100 = 1.1 * 100 = 110
    // y = (1.0 - 0.1 * 1.0) * 50 = 0.9 * 50 = 45
    try std.testing.expectApproxEqAbs(@as(f32, 110.0), projected_offset[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 45.0), projected_offset[1], 1e-5);
}

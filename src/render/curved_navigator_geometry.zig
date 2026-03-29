const std = @import("std");
const curved = @import("../geometry/constant_curvature.zig");

pub const SphericalMapProjection = enum {
    stereographic,
    gnomonic,
};

pub fn signedSphericalAmbient(view: curved.View, chart: curved.Vec3) ?curved.Vec4 {
    var ambient = curved.embedPoint(.spherical, view.params, chart) orelse return null;
    if (view.scene_sign < 0.0) {
        ambient = curved.ambientScale(.spherical, ambient, -1.0);
    }
    return ambient;
}

pub fn defaultSphericalMapCamera() curved.Camera {
    return .{
        .position = .{ 1.0, 0.0, 0.0, 0.0 },
        .right = .{ 0.0, 1.0, 0.0, 0.0 },
        .up = .{ 0.0, 0.0, 1.0, 0.0 },
        .forward = .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

pub fn sphericalGroundOverviewCamera(view: curved.View) curved.Camera {
    const basis = view.walkBasis() orelse return defaultSphericalMapCamera();
    return .{
        .position = view.camera.position,
        .right = basis.right,
        .up = basis.up,
        .forward = basis.forward,
    };
}

pub fn sphericalMapPoint(
    map_camera: curved.Camera,
    ambient: curved.Vec4,
    projection_mode: SphericalMapProjection,
) ?[2]f32 {
    const model: curved.CameraModel = switch (projection_mode) {
        .stereographic => .conformal,
        .gnomonic => .linear,
    };
    const point = curved.modelPointForAmbientWithCamera(.spherical, map_camera, ambient, model) orelse return null;
    return .{ point[0], point[2] };
}

pub fn sphericalGroundFieldExtent(
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: SphericalMapProjection,
    field_radius: f32,
) f32 {
    var extent: f32 = switch (projection_mode) {
        .stereographic => 2.2,
        .gnomonic => 1.2,
    };

    for (0..49) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48.0;
        const theta = t * @as(f32, std.math.pi) * 2.0;
        const lateral = @cos(theta) * field_radius;
        const forward = @sin(theta) * field_radius;
        const ambient = curved.ambientFromTangentBasisPoint(
            .spherical,
            view.params,
            map_camera.position,
            map_camera.right,
            map_camera.forward,
            lateral,
            forward,
        ) orelse continue;
        const point = sphericalMapPoint(map_camera, ambient, projection_mode) orelse continue;
        extent = @max(extent, @abs(point[0]) * 1.08);
        extent = @max(extent, @abs(point[1]) * 1.08);
    }

    return extent;
}

test "signedSphericalAmbient respects scene sign" {
    var view = try curved.View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const chart: curved.Vec3 = .{ 0.12, -0.07, 0.15 };
    const positive = signedSphericalAmbient(view, chart).?;
    view.scene_sign = -1.0;
    const negative = signedSphericalAmbient(view, chart).?;

    try std.testing.expectApproxEqAbs(-positive[0], negative[0], 1e-6);
    try std.testing.expectApproxEqAbs(-positive[1], negative[1], 1e-6);
    try std.testing.expectApproxEqAbs(-positive[2], negative[2], 1e-6);
    try std.testing.expectApproxEqAbs(-positive[3], negative[3], 1e-6);
}

test "sphericalGroundFieldExtent covers projected field" {
    const view = try curved.View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const map_camera = sphericalGroundOverviewCamera(view);
    const extent = sphericalGroundFieldExtent(
        view,
        map_camera,
        .stereographic,
        view.params.radius * (@as(f32, std.math.pi) * 0.5) * 0.98,
    );

    try std.testing.expect(extent > 2.0);
}

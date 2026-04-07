const std = @import("std");
const geometry = @import("../geometry.zig");

const curved = struct {
    pub const Vec3 = geometry.curved.Vec3;
    pub const CameraModel = geometry.curved.CameraModel;
    pub const SphericalView = geometry.curved.SphericalView;
    pub const TypedCamera = geometry.curved.TypedCamera;
    pub const AmbientFor = geometry.curved.AmbientFor;
    pub const ambientFromTypedTangentBasisPoint = geometry.curved.ambientFromTypedTangentBasisPoint;
    pub const modelPointForTypedAmbientWithCamera = geometry.curved.modelPointForTypedAmbientWithCamera;
    pub const vec3 = geometry.curved.vec3;
    pub const vec3x = geometry.curved.vec3x;
    pub const vec3z = geometry.curved.vec3z;
};
const Round = curved.AmbientFor(.spherical);

pub const SphericalAmbient = Round.Vector;
pub const SphericalCamera = curved.TypedCamera(.spherical);

pub const SphericalMapProjection = enum {
    stereographic,
    gnomonic,
};

pub fn sphericalView(view: anytype) curved.SphericalView {
    return switch (@TypeOf(view)) {
        curved.SphericalView => view,
        else => @compileError("expected `SphericalView`"),
    };
}

pub fn signedSphericalAmbient(view: anytype, chart: curved.Vec3) ?SphericalAmbient {
    const spherical = sphericalView(view);
    return spherical.sceneAmbientPoint(chart);
}

pub fn defaultSphericalMapCamera() SphericalCamera {
    return .{
        .position = Round.identity(),
        .right = Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        .up = Round.fromCoords(.{ 0.0, 0.0, 1.0, 0.0 }),
        .forward = Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
    };
}

pub fn sphericalGroundOverviewCamera(view: anytype) SphericalCamera {
    const spherical = sphericalView(view);
    const basis = spherical.walkBasis() orelse return defaultSphericalMapCamera();
    return .{
        .position = spherical.camera.position,
        .right = basis.right,
        .up = basis.up,
        .forward = basis.forward,
    };
}

pub fn sphericalMapPoint(
    map_camera: SphericalCamera,
    ambient: SphericalAmbient,
    projection_mode: SphericalMapProjection,
) ?[2]f32 {
    const model: curved.CameraModel = switch (projection_mode) {
        .stereographic => .conformal,
        .gnomonic => .linear,
    };
    const point = curved.modelPointForTypedAmbientWithCamera(
        .spherical,
        map_camera,
        ambient,
        model,
    ) orelse return null;
    return .{ curved.vec3x(point), curved.vec3z(point) };
}

pub fn sphericalGroundFieldExtent(
    view: anytype,
    map_camera: SphericalCamera,
    projection_mode: SphericalMapProjection,
    field_radius: f32,
) f32 {
    const spherical = sphericalView(view);
    var extent: f32 = switch (projection_mode) {
        .stereographic => 2.2,
        .gnomonic => 1.2,
    };

    for (0..49) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48.0;
        const theta = t * @as(f32, std.math.pi) * 2.0;
        const lateral = @cos(theta) * field_radius;
        const forward = @sin(theta) * field_radius;
        const ambient = curved.ambientFromTypedTangentBasisPoint(
            .spherical,
            spherical.params,
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
    var view = try curved.SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const chart: curved.Vec3 = curved.vec3(0.12, -0.07, 0.15);
    const positive = signedSphericalAmbient(view, chart).?;
    view.scene_sign = -1.0;
    const negative = signedSphericalAmbient(view, chart).?;

    const positive_coords = Round.toCoords(positive);
    const negative_coords = Round.toCoords(negative);
    try std.testing.expectApproxEqAbs(-positive_coords.w, negative_coords.w, 1e-6);
    try std.testing.expectApproxEqAbs(-positive_coords.x, negative_coords.x, 1e-6);
    try std.testing.expectApproxEqAbs(-positive_coords.y, negative_coords.y, 1e-6);
    try std.testing.expectApproxEqAbs(-positive_coords.z, negative_coords.z, 1e-6);
}

test "sphericalGroundFieldExtent covers projected field" {
    const view = try curved.SphericalView.init(
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

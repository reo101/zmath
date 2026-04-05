const std = @import("std");
const projection = @import("../render/projection.zig");
const curved_projection = @import("../render/curved_projection.zig");
const curved_ambient = @import("curved_ambient.zig");
const curved_types = @import("curved_types.zig");

pub const Metric = curved_types.Metric;
pub const Params = curved_types.Params;
pub const CameraModel = curved_types.CameraModel;
pub const DistanceClip = curved_types.DistanceClip;
pub const Screen = curved_types.Screen;
pub const Sample = curved_types.Sample;
pub const ProjectedSample = curved_types.ProjectedSample;
pub const Vec3 = curved_types.Vec3;
pub const AmbientFor = curved_types.AmbientFor;
pub const TypedCamera = curved_types.TypedCamera;

pub const SphericalRenderPass = enum { near, far };

const projectSample = curved_projection.projectSample;
const projectConformalModelPoint = curved_projection.projectConformalModelPoint;
const sampleStatus = curved_projection.sampleStatus;

const RelativeCoords = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,
};

const SphericalPassSelection = struct {
    pass: SphericalRenderPass,
    near_distance: f32,
};

fn vec3(x_value: f32, y_value: f32, z_value: f32) Vec3 {
    return Vec3.init(.{ x_value, y_value, z_value });
}

fn vec3x(v: Vec3) f32 {
    return v.named().e1;
}

fn vec3y(v: Vec3) f32 {
    return v.named().e2;
}

fn vec3z(v: Vec3) f32 {
    return v.named().e3;
}

fn maxSphericalDistance(params: Params) f32 {
    return @as(f32, std.math.pi) * params.radius;
}

fn hemisphereDistance(params: Params) f32 {
    return maxSphericalDistance(params) * 0.5;
}

pub fn sphericalUsesMultipass(projection_mode: projection.DirectionProjection) bool {
    return switch (projection_mode) {
        .wrapped => false,
        .gnomonic, .stereographic, .orthographic => true,
    };
}

pub fn cameraModelForRender(metric: Metric, projection_mode: projection.DirectionProjection) ?CameraModel {
    return switch (projection_mode) {
        .gnomonic => .linear,
        .wrapped, .orthographic => if (metric == .hyperbolic) .linear else null,
        .stereographic => .conformal,
    };
}

fn relativeCoords(
    comptime metric: Metric,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
) RelativeCoords {
    const Ambient = AmbientFor(metric);
    var point = ambient;
    if (metric == .elliptic and Ambient.dot(camera.position, point) < 0.0) {
        point = Ambient.scale(point, -1.0);
    }

    const inner = Ambient.dot(camera.position, point);
    return .{
        .w = switch (metric) {
            .hyperbolic => -inner,
            .elliptic, .spherical => inner,
        },
        .x = Ambient.dot(point, camera.right),
        .y = Ambient.dot(point, camera.up),
        .z = Ambient.dot(point, camera.forward),
    };
}

fn relativeSpatialLength(relative: RelativeCoords) f32 {
    return vec3(relative.x, relative.y, relative.z).magnitude();
}

fn modelRadius(point: Vec3) f32 {
    return point.magnitude();
}

fn sampleModelPoint(metric: Metric, projection_mode: projection.DirectionProjection, params: Params, model_point: Vec3) ?Sample {
    const radius = modelRadius(model_point);
    const distance = switch (cameraModelForRender(metric, projection_mode) orelse return null) {
        .linear => linear_distance: switch (metric) {
            .hyperbolic => {
                if (radius >= 1.0 - 1e-5) return null;
                break :linear_distance params.radius * std.math.atanh(radius);
            },
            .elliptic, .spherical => break :linear_distance params.radius * std.math.atan(radius),
        },
        .conformal => conformal_distance: switch (metric) {
            .hyperbolic => {
                if (radius >= 1.0 - 1e-5) return null;
                break :conformal_distance params.radius * 2.0 * std.math.atanh(radius);
            },
            .elliptic, .spherical => break :conformal_distance params.radius * 2.0 * std.math.atan(radius),
        },
    };

    const spatial_norm = @max(radius, 1e-6);
    return .{
        .distance = distance,
        .x_dir = vec3x(model_point) / spatial_norm,
        .y_dir = vec3y(model_point) / spatial_norm,
        .z_dir = vec3z(model_point) / spatial_norm,
    };
}

pub fn sampleProjectedModelPoint(
    metric: Metric,
    projection_mode: projection.DirectionProjection,
    params: Params,
    clip: DistanceClip,
    model_point: Vec3,
    screen: Screen,
) ProjectedSample {
    const point_sample = sampleModelPoint(metric, projection_mode, params, model_point) orelse return .{};
    const projected = switch (cameraModelForRender(metric, projection_mode) orelse return .{}) {
        .linear => projection.projectDirectionWith(
            projection_mode,
            vec3x(model_point),
            vec3y(model_point),
            vec3z(model_point),
            screen.width,
            screen.height,
            screen.zoom,
        ),
        .conformal => projectConformalModelPoint(model_point, screen.width, screen.height, screen.zoom),
    };
    return .{
        .distance = point_sample.distance,
        .render_depth = vec3z(model_point),
        .projected = projected,
        .status = sampleStatus(point_sample.distance, clip, projected),
    };
}

pub fn sampleAmbientPoint(
    comptime metric: Metric,
    params: Params,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
) ?Sample {
    const relative = relativeCoords(metric, camera, ambient);
    const spatial_norm = relativeSpatialLength(relative);
    if (spatial_norm <= 1e-6) return null;

    const distance = switch (metric) {
        .hyperbolic => params.radius * std.math.acosh(@max(relative.w, 1.0)),
        .elliptic => params.radius * std.math.acos(std.math.clamp(relative.w, -1.0, 1.0)),
        .spherical => params.radius * std.math.acos(std.math.clamp(relative.w, -1.0, 1.0)),
    };

    return .{
        .distance = distance,
        .x_dir = relative.x / spatial_norm,
        .y_dir = relative.y / spatial_norm,
        .z_dir = relative.z / spatial_norm,
    };
}

fn modelPointForAmbient(
    comptime metric: Metric,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
    model: CameraModel,
) ?Vec3 {
    const relative = relativeCoords(metric, camera, ambient);
    const denom = switch (model) {
        .linear => relative.w,
        .conformal => 1.0 + relative.w,
    };
    if (@abs(denom) <= 1e-6) return null;
    return vec3(relative.x / denom, relative.y / denom, relative.z / denom);
}

pub fn modelPointForTypedAmbientWithCamera(
    comptime metric: Metric,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
    model: CameraModel,
) ?Vec3 {
    return modelPointForAmbient(metric, camera, ambient, model);
}

fn antipodalSphericalPassCamera(camera: TypedCamera(.spherical)) TypedCamera(.spherical) {
    return .{
        .position = curved_ambient.Round.scale(camera.position, -1.0),
        .right = camera.right,
        .up = camera.up,
        .forward = curved_ambient.Round.scale(camera.forward, -1.0),
    };
}

fn sphericalPassSelection(
    comptime metric: Metric,
    params: Params,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
) ?SphericalPassSelection {
    const near_sample = sampleAmbientPoint(metric, params, camera, ambient) orelse return null;
    return .{
        .pass = if (near_sample.z_dir >= 0.0) .near else .far,
        .near_distance = near_sample.distance,
    };
}

pub fn sphericalSelectedPassForAmbient(
    comptime metric: Metric,
    params: Params,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
) ?SphericalRenderPass {
    return (sphericalPassSelection(metric, params, camera, ambient) orelse return null).pass;
}

fn sampleProjectedAmbientPointSinglePass(
    comptime metric: Metric,
    params: Params,
    projection_mode: projection.DirectionProjection,
    clip: DistanceClip,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    if (cameraModelForRender(metric, projection_mode)) |camera_model| {
        const model_point = modelPointForAmbient(metric, camera, ambient, camera_model) orelse return .{};
        return sampleProjectedModelPoint(metric, projection_mode, params, clip, model_point, screen);
    }

    const point_sample = sampleAmbientPoint(metric, params, camera, ambient) orelse return .{};
    const projected = projectSample(projection_mode, point_sample, screen.width, screen.height, screen.zoom);
    return .{
        .distance = point_sample.distance,
        .projected = projected,
        .status = sampleStatus(point_sample.distance, clip, projected),
    };
}

pub fn sampleProjectedAmbientPointForPassRaw(
    comptime metric: Metric,
    params: Params,
    projection_mode: projection.DirectionProjection,
    clip: DistanceClip,
    camera: TypedCamera(metric),
    pass: SphericalRenderPass,
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    const model = cameraModelForRender(metric, projection_mode);

    if (pass == .near) {
        if (model) |camera_model| {
            const model_point = modelPointForAmbient(metric, camera, ambient, camera_model) orelse return .{};
            return sampleProjectedModelPoint(metric, projection_mode, params, clip, model_point, screen);
        }

        const near_sample = sampleAmbientPoint(metric, params, camera, ambient) orelse return .{};
        const projected = projectSample(projection_mode, near_sample, screen.width, screen.height, screen.zoom);
        return .{
            .distance = near_sample.distance,
            .projected = projected,
            .status = sampleStatus(near_sample.distance, clip, projected),
        };
    }

    const far_camera = antipodalSphericalPassCamera(camera);
    if (model) |camera_model| {
        const model_point = modelPointForAmbient(metric, far_camera, ambient, camera_model) orelse return .{};
        const far_sample = sampleProjectedModelPoint(
            metric,
            projection_mode,
            params,
            .{ .near = 0.0, .far = hemisphereDistance(params) },
            model_point,
            screen,
        );
        if (far_sample.projected == null) return far_sample;
        const mapped_distance = maxSphericalDistance(params) - far_sample.distance;
        return .{
            .distance = mapped_distance,
            .projected = far_sample.projected,
            .status = sampleStatus(mapped_distance, clip, far_sample.projected),
        };
    }

    const far_pass_sample = sampleAmbientPoint(metric, params, far_camera, ambient) orelse return .{};
    const mapped_distance = maxSphericalDistance(params) - far_pass_sample.distance;
    const projected = projectSample(projection_mode, far_pass_sample, screen.width, screen.height, screen.zoom);
    return .{
        .distance = mapped_distance,
        .projected = projected,
        .status = sampleStatus(mapped_distance, clip, projected),
    };
}

pub fn sampleProjectedAmbientPointForPass(
    comptime metric: Metric,
    params: Params,
    projection_mode: projection.DirectionProjection,
    clip: DistanceClip,
    camera: TypedCamera(metric),
    pass: SphericalRenderPass,
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    const selection = sphericalPassSelection(metric, params, camera, ambient) orelse return .{};
    if (selection.pass != pass) return .{ .distance = selection.near_distance };

    return sampleProjectedAmbientPointForPassRaw(metric, params, projection_mode, clip, camera, pass, ambient, screen);
}

pub fn sampleProjectedAmbientPoint(
    comptime metric: Metric,
    params: Params,
    projection_mode: projection.DirectionProjection,
    clip: DistanceClip,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    if (metric != .spherical or !sphericalUsesMultipass(projection_mode)) {
        return sampleProjectedAmbientPointSinglePass(metric, params, projection_mode, clip, camera, ambient, screen);
    }

    const near = sampleProjectedAmbientPointForPass(metric, params, projection_mode, clip, camera, .near, ambient, screen);
    if (near.status != .hidden or near.projected != null) return near;
    return sampleProjectedAmbientPointForPass(metric, params, projection_mode, clip, camera, .far, ambient, screen);
}

test "camera-relative model queries agree for stereographic spherical points" {
    const Round = AmbientFor(.spherical);
    const camera: TypedCamera(.spherical) = .{
        .position = Round.identity(),
        .right = Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        .up = Round.fromCoords(.{ 0.0, 0.0, 1.0, 0.0 }),
        .forward = Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
    };
    const ambient = Round.fromCoords(.{ 0.9238795, 0.2209424, 0.0, 0.3124597 });
    const model = modelPointForTypedAmbientWithCamera(.spherical, camera, ambient, .conformal).?;
    const sample = sampleProjectedAmbientPoint(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        camera,
        ambient,
        .{ .width = 80, .height = 40, .zoom = 1.0 },
    );

    try std.testing.expect(sample.projected != null);
    try std.testing.expect(vec3z(model) > 0.0);
}

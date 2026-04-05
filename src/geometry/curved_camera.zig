const std = @import("std");
const projection = @import("../render/projection.zig");
const curved_charts = @import("curved_charts.zig");
const curved_tangent = @import("curved_tangent.zig");
const curved_types = @import("curved_types.zig");

pub const Metric = curved_types.Metric;
pub const Params = curved_types.Params;
pub const WalkOrientation = curved_types.WalkOrientation;
pub const AmbientFor = curved_types.AmbientFor;
pub const TypedCamera = curved_types.TypedCamera;
pub const TypedWalkBasis = curved_types.TypedWalkBasis;

pub const CameraError = error{
    InvalidChartPoint,
    DegenerateDirection,
};

fn HeadingBasis(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        east: Ambient.Vector,
        north: Ambient.Vector,
        up: Ambient.Vector,
    };
}

fn rotatePair(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    first: *AmbientFor(metric).Vector,
    second: *AmbientFor(metric).Vector,
    angle: f32,
) void {
    const Ambient = AmbientFor(metric);
    const c = @cos(angle);
    const s = @sin(angle);
    const old_first = first.*;
    const old_second = second.*;
    first.* = Ambient.add(Ambient.scale(old_first, c), Ambient.scale(old_second, s));
    second.* = Ambient.sub(Ambient.scale(old_second, c), Ambient.scale(old_first, s));
    curved_tangent.reorthonormalize(metric, camera);
}

pub fn turnYaw(comptime metric: Metric, camera: *TypedCamera(metric), angle: f32) void {
    rotatePair(metric, camera, &camera.forward, &camera.right, angle);
}

pub fn turnPitch(comptime metric: Metric, camera: *TypedCamera(metric), angle: f32) void {
    rotatePair(metric, camera, &camera.forward, &camera.up, angle);
}

pub fn worldUpDirection(comptime metric: Metric, camera: TypedCamera(metric)) ?AmbientFor(metric).Vector {
    return curved_tangent.worldUpAt(metric, camera.position);
}

fn headingBasis(comptime metric: Metric, camera: TypedCamera(metric)) ?HeadingBasis(metric) {
    const up = worldUpDirection(metric, camera) orelse return null;
    const east = curved_tangent.orthonormalCandidate(metric, camera.position, curved_tangent.basisVector(metric, .{ 0.0, 1.0, 0.0, 0.0 }), &.{up}) orelse
        curved_tangent.orthonormalCandidate(metric, camera.position, curved_tangent.basisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{up}) orelse
        curved_tangent.orthonormalCandidate(metric, camera.position, curved_tangent.basisVector(metric, .{ 1.0, 0.0, 0.0, 0.0 }), &.{up}) orelse
        return null;
    const north = curved_tangent.orthonormalCandidate(metric, camera.position, curved_tangent.basisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{ up, east }) orelse
        curved_tangent.orthonormalCandidate(metric, camera.position, curved_tangent.basisVector(metric, .{ 1.0, 0.0, 0.0, 0.0 }), &.{ up, east }) orelse
        curved_tangent.orthonormalCandidate(metric, camera.position, curved_tangent.basisVector(metric, .{ 0.0, 1.0, 0.0, 0.0 }), &.{ up, east }) orelse
        return null;

    return .{
        .east = east,
        .north = north,
        .up = up,
    };
}

pub fn worldHeadingDirection(
    comptime metric: Metric,
    camera: TypedCamera(metric),
    x_heading: f32,
    z_heading: f32,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    const basis = headingBasis(metric, camera) orelse return null;
    return curved_tangent.tryNormalizeTangent(metric, Ambient.add(
        Ambient.scale(basis.east, x_heading),
        Ambient.scale(basis.north, z_heading),
    ));
}

pub fn currentWalkOrientation(comptime metric: Metric, camera: TypedCamera(metric)) ?WalkOrientation {
    const Ambient = AmbientFor(metric);
    const basis = headingBasis(metric, camera) orelse return null;
    const pitch_angle = std.math.asin(std.math.clamp(Ambient.dot(camera.forward, basis.up), -1.0, 1.0));

    const forward_ground = curved_tangent.orthonormalCandidate(metric, camera.position, camera.forward, &.{basis.up}) orelse fallback_ground: {
        const up_sign: f32 = if (pitch_angle >= 0.0) -1.0 else 1.0;
        break :fallback_ground curved_tangent.orthonormalCandidate(metric, camera.position, Ambient.scale(camera.up, up_sign), &.{basis.up}) orelse return null;
    };

    const x_heading = Ambient.dot(forward_ground, basis.east);
    const z_heading = Ambient.dot(forward_ground, basis.north);
    const heading_len = @sqrt(x_heading * x_heading + z_heading * z_heading);
    if (heading_len <= 1e-6) return null;

    return .{
        .x_heading = x_heading / heading_len,
        .z_heading = z_heading / heading_len,
        .pitch = pitch_angle,
    };
}

pub fn walkBasis(comptime metric: Metric, camera: TypedCamera(metric)) ?TypedWalkBasis(metric) {
    const orientation = currentWalkOrientation(metric, camera) orelse return null;
    const basis = headingBasis(metric, camera) orelse return null;
    return .{
        .forward = worldHeadingDirection(metric, camera, orientation.x_heading, orientation.z_heading) orelse return null,
        .right = worldHeadingDirection(metric, camera, orientation.z_heading, -orientation.x_heading) orelse return null,
        .up = basis.up,
    };
}

pub fn walkSurfaceBasis(comptime metric: Metric, camera: TypedCamera(metric), pitch_angle: f32) ?TypedWalkBasis(metric) {
    const Ambient = AmbientFor(metric);
    const up = worldUpDirection(metric, camera) orelse return null;
    const forward = curved_tangent.orthonormalCandidate(metric, camera.position, camera.forward, &.{up}) orelse fallback_forward: {
        const up_sign: f32 = if (pitch_angle >= 0.0) -1.0 else 1.0;
        break :fallback_forward curved_tangent.orthonormalCandidate(metric, camera.position, Ambient.scale(camera.up, up_sign), &.{up});
    } orelse return null;
    const right = curved_tangent.orthonormalCandidate(metric, camera.position, camera.right, &.{ up, forward }) orelse
        curved_tangent.orthonormalCandidate(metric, camera.position, camera.up, &.{ up, forward }) orelse
        return null;
    return .{
        .forward = forward,
        .right = right,
        .up = up,
    };
}

pub fn orientFromHeadingPitch(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    x_heading: f32,
    z_heading: f32,
    pitch_angle: f32,
) void {
    const Ambient = AmbientFor(metric);
    const basis = headingBasis(metric, camera.*) orelse return;
    const horizontal_forward = worldHeadingDirection(metric, camera.*, x_heading, z_heading) orelse return;
    const horizontal_right = worldHeadingDirection(metric, camera.*, z_heading, -x_heading) orelse return;

    camera.forward = Ambient.add(
        Ambient.scale(horizontal_forward, @cos(pitch_angle)),
        Ambient.scale(basis.up, @sin(pitch_angle)),
    );
    camera.forward = curved_tangent.tryNormalizeTangent(metric, curved_tangent.projectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = curved_tangent.orthonormalCandidate(metric, camera.position, horizontal_right, &.{camera.forward}) orelse return;
    camera.up = curved_tangent.orthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    curved_tangent.reorthonormalize(metric, camera);
}

pub fn turnSurfaceYaw(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    angle: f32,
    pitch_angle: f32,
) void {
    const Ambient = AmbientFor(metric);
    const basis = walkSurfaceBasis(metric, camera.*, pitch_angle) orelse {
        turnYaw(metric, camera, angle);
        return;
    };

    const c = @cos(angle);
    const s = @sin(angle);
    const horizontal_forward = Ambient.add(
        Ambient.scale(basis.forward, c),
        Ambient.scale(basis.right, s),
    );
    const horizontal_right = Ambient.sub(
        Ambient.scale(basis.right, c),
        Ambient.scale(basis.forward, s),
    );

    camera.forward = Ambient.add(
        Ambient.scale(horizontal_forward, @cos(pitch_angle)),
        Ambient.scale(basis.up, @sin(pitch_angle)),
    );
    camera.forward = curved_tangent.tryNormalizeTangent(metric, curved_tangent.projectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = curved_tangent.orthonormalCandidate(metric, camera.position, horizontal_right, &.{ camera.forward, basis.up }) orelse return;
    camera.up = curved_tangent.orthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    curved_tangent.reorthonormalize(metric, camera);
}

pub fn syncSurfacePitch(comptime metric: Metric, camera: *TypedCamera(metric), pitch_angle: f32) void {
    const Ambient = AmbientFor(metric);
    const basis = walkSurfaceBasis(metric, camera.*, pitch_angle) orelse return;

    camera.forward = Ambient.add(
        Ambient.scale(basis.forward, @cos(pitch_angle)),
        Ambient.scale(basis.up, @sin(pitch_angle)),
    );
    camera.forward = curved_tangent.tryNormalizeTangent(metric, curved_tangent.projectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = curved_tangent.orthonormalCandidate(metric, camera.position, basis.right, &.{ camera.forward, basis.up }) orelse return;
    camera.up = curved_tangent.orthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    curved_tangent.reorthonormalize(metric, camera);
}

fn transportedTangent(
    comptime metric: Metric,
    old_direction: AmbientFor(metric).Vector,
    new_direction: AmbientFor(metric).Vector,
    tangent: AmbientFor(metric).Vector,
) AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    const along = Ambient.dot(tangent, old_direction);
    return Ambient.add(
        Ambient.sub(tangent, Ambient.scale(old_direction, along)),
        Ambient.scale(new_direction, along),
    );
}

pub fn geodesicDirection(
    comptime metric: Metric,
    eye: AmbientFor(metric).Vector,
    target_input: AmbientFor(metric).Vector,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    var target = target_input;
    if (metric == .elliptic and Ambient.dot(eye, target) < 0.0) {
        target = Ambient.scale(target, -1.0);
    }

    const inner = Ambient.dot(eye, target);
    const tangent = switch (metric) {
        .hyperbolic => Ambient.add(target, Ambient.scale(eye, inner)),
        .elliptic, .spherical => Ambient.sub(target, Ambient.scale(eye, inner)),
    };
    return curved_tangent.tryNormalizeTangent(metric, tangent);
}

pub fn initCamera(
    comptime metric: Metric,
    params: Params,
    eye_chart_input: anytype,
    target_chart_input: anytype,
) CameraError!TypedCamera(metric) {
    const position = curved_charts.embedPoint(metric, params, eye_chart_input) orelse return error.InvalidChartPoint;
    const target = curved_charts.embedPoint(metric, params, target_chart_input) orelse return error.InvalidChartPoint;
    const forward = geodesicDirection(metric, position, target) orelse return error.DegenerateDirection;
    const up = curved_tangent.orthonormalCandidate(metric, position, curved_tangent.basisVector(metric, .{ 0.0, 0.0, 1.0, 0.0 }), &.{forward}) orelse
        curved_tangent.orthonormalCandidate(metric, position, curved_tangent.basisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{forward}) orelse
        return error.DegenerateDirection;
    const right = curved_tangent.orthonormalCandidate(metric, position, curved_tangent.basisVector(metric, .{ 0.0, 1.0, 0.0, 0.0 }), &.{ forward, up }) orelse
        curved_tangent.orthonormalCandidate(metric, position, curved_tangent.basisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{ forward, up }) orelse
        return error.DegenerateDirection;

    var camera = TypedCamera(metric){
        .position = position,
        .right = right,
        .up = up,
        .forward = forward,
    };
    curved_tangent.reorthonormalize(metric, &camera);
    return camera;
}

pub fn moveAlongDirection(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    params: Params,
    direction: AmbientFor(metric).Vector,
    distance: f32,
) void {
    const Ambient = AmbientFor(metric);
    const old_position = camera.position;
    const old_direction = curved_tangent.tryNormalizeTangent(metric, curved_tangent.projectToTangent(metric, old_position, direction)) orelse return;
    const old_forward = camera.forward;
    const old_right = camera.right;
    const old_up = camera.up;
    const normalized_distance = distance / params.radius;
    var new_position: Ambient.Vector = undefined;
    var new_direction: Ambient.Vector = undefined;

    switch (metric) {
        .hyperbolic => {
            const c = std.math.cosh(normalized_distance);
            const s = std.math.sinh(normalized_distance);
            new_position = Ambient.add(Ambient.scale(old_position, c), Ambient.scale(old_direction, s));
            new_direction = Ambient.add(Ambient.scale(old_position, s), Ambient.scale(old_direction, c));
        },
        .elliptic, .spherical => {
            const c = @cos(normalized_distance);
            const s = @sin(normalized_distance);
            new_position = Ambient.add(Ambient.scale(old_position, c), Ambient.scale(old_direction, s));
            new_direction = Ambient.add(Ambient.scale(old_direction, c), Ambient.scale(old_position, -s));
        },
    }

    camera.position = new_position;
    camera.forward = transportedTangent(metric, old_direction, new_direction, old_forward);
    camera.right = transportedTangent(metric, old_direction, new_direction, old_right);
    camera.up = transportedTangent(metric, old_direction, new_direction, old_up);
    curved_tangent.reorthonormalize(metric, camera);
}

test "walk orientation roundtrips for curved views" {
    var hyper = try initCamera(
        .hyperbolic,
        .{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal },
        .{ 0.0, 0.0, -0.22 },
        .{ 0.0, 0.0, 0.0 },
    );
    orientFromHeadingPitch(.hyperbolic, &hyper, 0.6, 0.8, 0.35);
    const hyper_walk = currentWalkOrientation(.hyperbolic, hyper).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), hyper_walk.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), hyper_walk.z_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), hyper_walk.pitch, 1e-3);

    var spherical = try initCamera(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    orientFromHeadingPitch(.spherical, &spherical, -0.8, 0.6, -0.25);
    const spherical_walk = currentWalkOrientation(.spherical, spherical).?;
    try std.testing.expectApproxEqAbs(@as(f32, -0.8), spherical_walk.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), spherical_walk.z_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), spherical_walk.pitch, 1e-3);
}

const std = @import("std");
const visualizer = @import("zmath").visualizer;
const hpga = @import("zmath").hpga;
const epga = @import("zmath").epga;

pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;

pub const Metric = enum { hyperbolic, elliptic, spherical };

pub const Params = struct {
    // Constant-curvature radius `R`.
    // Hyperbolic curvature is `-1 / R^2`; elliptic/spherical curvature is `+1 / R^2`.
    radius: f32 = 1.0,
    angular_zoom: f32,
};

pub const Camera = struct {
    position: Vec4,
    right: Vec4,
    up: Vec4,
    forward: Vec4,
};

pub const Sample = struct {
    distance: f32,
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
};

fn add4(a: Vec4, b: Vec4) Vec4 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

fn sub4(a: Vec4, b: Vec4) Vec4 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
}

fn scale4(v: Vec4, s: f32) Vec4 {
    return .{ v[0] * s, v[1] * s, v[2] * s, v[3] * s };
}

fn metricDot(metric: Metric, a: Vec4, b: Vec4) f32 {
    return switch (metric) {
        .hyperbolic => -a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3],
        .elliptic, .spherical => a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3],
    };
}

fn tryNormalizeTangent(metric: Metric, v: Vec4) ?Vec4 {
    const n2 = metricDot(metric, v, v);
    if (n2 <= 1e-6) return null;
    return scale4(v, 1.0 / @sqrt(n2));
}

fn projectToTangent(metric: Metric, position: Vec4, candidate: Vec4) Vec4 {
    const denom = metricDot(metric, position, position);
    const along = metricDot(metric, candidate, position) / denom;
    return sub4(candidate, scale4(position, along));
}

fn orthonormalCandidate(metric: Metric, position: Vec4, candidate: Vec4, refs: []const Vec4) ?Vec4 {
    var v = projectToTangent(metric, position, candidate);
    for (refs) |r| {
        v = sub4(v, scale4(r, metricDot(metric, v, r)));
    }
    return tryNormalizeTangent(metric, v);
}

// Normalized homogeneous points for the projective models:
// - hyperbolic `H^3`: unit hyperboloid / Klein chart
// - elliptic `E^3`: unit 3-sphere / projective chart
// See Gunn, "Geometry in the 3-Sphere from a Clifford Perspective"
// https://arxiv.org/abs/1310.2713
// and Gunn, "Geometry in the Hyperbolic Plane and Beyond"
// https://arxiv.org/pdf/1602.08562
pub fn embedPoint(metric: Metric, params: Params, chart: Vec3) ?Vec4 {
    const scaled = Vec3{
        chart[0] / params.radius,
        chart[1] / params.radius,
        chart[2] / params.radius,
    };

    return switch (metric) {
        .hyperbolic => {
            const point = hpga.Point.proper(scaled[0], scaled[1], scaled[2]) orelse return null;
            return hpga.ambientCoords(point);
        },
        .elliptic, .spherical => epga.ambientCoords(epga.Point.proper(scaled[0], scaled[1], scaled[2])),
    };
}

pub fn chartCoords(metric: Metric, params: Params, ambient: Vec4) Vec3 {
    var point = ambient;
    if (metric == .elliptic and point[0] < 0.0) {
        point = scale4(point, -1.0);
    }

    const inv_w = params.radius / @max(point[0], 1e-6);
    return .{
        point[1] * inv_w,
        point[2] * inv_w,
        point[3] * inv_w,
    };
}

fn normalizeAmbient(metric: Metric, ambient: Vec4) Vec4 {
    const norm2 = metricDot(metric, ambient, ambient);
    const inv = switch (metric) {
        .hyperbolic => 1.0 / @sqrt(@max(-norm2, 1e-6)),
        .elliptic, .spherical => 1.0 / @sqrt(@max(norm2, 1e-6)),
    };
    return scale4(ambient, inv);
}

fn transportedTangent(metric: Metric, old_direction: Vec4, new_direction: Vec4, tangent: Vec4) Vec4 {
    const along = metricDot(metric, tangent, old_direction);
    return add4(
        sub4(tangent, scale4(old_direction, along)),
        scale4(new_direction, along),
    );
}

// Intrinsic geodesic interpolation in the ambient constant-curvature models.
// References:
// https://arxiv.org/abs/1310.2713
// https://arxiv.org/pdf/1602.08562
pub fn geodesicChartPoint(metric: Metric, params: Params, a_chart: Vec3, b_chart: Vec3, t: f32) ?Vec3 {
    const a = embedPoint(metric, params, a_chart) orelse return null;
    var b = embedPoint(metric, params, b_chart) orelse return null;

    return switch (metric) {
        .hyperbolic => {
            const cosh_omega = @max(-metricDot(metric, a, b), 1.0);
            const omega = std.math.acosh(cosh_omega);
            if (omega <= 1e-5) return a_chart;

            const inv_denom = 1.0 / std.math.sinh(omega);
            const p = add4(
                scale4(a, std.math.sinh((1.0 - t) * omega) * inv_denom),
                scale4(b, std.math.sinh(t * omega) * inv_denom),
            );
            return chartCoords(metric, params, normalizeAmbient(metric, p));
        },
        .elliptic, .spherical => {
            if (metric == .elliptic and metricDot(metric, a, b) < 0.0) {
                b = scale4(b, -1.0);
            }

            const cos_omega = std.math.clamp(metricDot(metric, a, b), -1.0, 1.0);
            const omega = std.math.acos(cos_omega);
            if (omega <= 1e-5) return a_chart;

            const inv_denom = 1.0 / @sin(omega);
            const p = add4(
                scale4(a, @sin((1.0 - t) * omega) * inv_denom),
                scale4(b, @sin(t * omega) * inv_denom),
            );
            return chartCoords(metric, params, normalizeAmbient(metric, p));
        },
    };
}

// The initial viewing ray is the tangent of the geodesic from the eye point to
// the target point, obtained by removing the eye component with the ambient
// metric of the model. Same references as above.
fn geodesicDirection(metric: Metric, eye: Vec4, target: Vec4) ?Vec4 {
    var adjusted_target = target;
    if (metric == .elliptic and metricDot(metric, eye, adjusted_target) < 0.0) {
        adjusted_target = scale4(adjusted_target, -1.0);
    }

    const inner = metricDot(metric, eye, adjusted_target);
    const tangent = switch (metric) {
        .hyperbolic => add4(adjusted_target, scale4(eye, inner)),
        .elliptic, .spherical => sub4(adjusted_target, scale4(eye, inner)),
    };
    return tryNormalizeTangent(metric, tangent);
}

fn reorthonormalize(metric: Metric, camera: *Camera) void {
    camera.forward = orthonormalCandidate(metric, camera.position, camera.forward, &.{}) orelse camera.forward;
    camera.right = orthonormalCandidate(metric, camera.position, camera.right, &.{camera.forward}) orelse camera.right;
    camera.up = orthonormalCandidate(metric, camera.position, camera.up, &.{ camera.forward, camera.right }) orelse camera.up;
}

pub fn initCamera(metric: Metric, params: Params, eye_chart: Vec3, target_chart: Vec3) Camera {
    const position = embedPoint(metric, params, eye_chart) orelse unreachable;
    const target = embedPoint(metric, params, target_chart) orelse unreachable;
    const forward = geodesicDirection(metric, position, target) orelse unreachable;
    const up = orthonormalCandidate(metric, position, .{ 0.0, 0.0, 1.0, 0.0 }, &.{forward}) orelse
        orthonormalCandidate(metric, position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{forward}) orelse
        unreachable;
    const right = orthonormalCandidate(metric, position, .{ 0.0, 1.0, 0.0, 0.0 }, &.{ forward, up }) orelse
        orthonormalCandidate(metric, position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{ forward, up }) orelse
        unreachable;

    var camera = Camera{
        .position = position,
        .right = right,
        .up = up,
        .forward = forward,
    };
    reorthonormalize(metric, &camera);
    return camera;
}

fn rotatePair(metric: Metric, camera: *Camera, first: *Vec4, second: *Vec4, angle: f32) void {
    const c = @cos(angle);
    const s = @sin(angle);
    const old_first = first.*;
    const old_second = second.*;
    first.* = add4(scale4(old_first, c), scale4(old_second, s));
    second.* = sub4(scale4(old_second, c), scale4(old_first, s));
    reorthonormalize(metric, camera);
}

pub fn yaw(camera: *Camera, metric: Metric, angle: f32) void {
    rotatePair(metric, camera, &camera.forward, &camera.right, angle);
}

pub fn pitch(camera: *Camera, metric: Metric, angle: f32) void {
    rotatePair(metric, camera, &camera.forward, &camera.up, angle);
}

// Geodesic camera transport in the ambient models:
// - sphere: `(cos s) * P + (sin s) * V`
// - hyperboloid: `(cosh s) * P + (sinh s) * V`
// with the companion update for the transported tangent basis.
// References:
// https://arxiv.org/abs/1310.2713
// https://arxiv.org/pdf/1602.08562
pub fn moveAlongDirection(camera: *Camera, metric: Metric, params: Params, direction: Vec4, distance: f32) void {
    const old_position = camera.position;
    const old_direction = tryNormalizeTangent(metric, projectToTangent(metric, old_position, direction)) orelse return;
    const old_forward = camera.forward;
    const old_right = camera.right;
    const old_up = camera.up;
    const normalized_distance = distance / params.radius;
    var new_position: Vec4 = undefined;
    var new_direction: Vec4 = undefined;

    switch (metric) {
        .hyperbolic => {
            const c = std.math.cosh(normalized_distance);
            const s = std.math.sinh(normalized_distance);
            new_position = add4(scale4(old_position, c), scale4(old_direction, s));
            new_direction = add4(scale4(old_position, s), scale4(old_direction, c));
        },
        .elliptic, .spherical => {
            const c = @cos(normalized_distance);
            const s = @sin(normalized_distance);
            new_position = add4(scale4(old_position, c), scale4(old_direction, s));
            new_direction = add4(scale4(old_direction, c), scale4(old_position, -s));
        },
    }

    camera.position = new_position;
    camera.forward = transportedTangent(metric, old_direction, new_direction, old_forward);
    camera.right = transportedTangent(metric, old_direction, new_direction, old_right);
    camera.up = transportedTangent(metric, old_direction, new_direction, old_up);
    reorthonormalize(metric, camera);
}

pub fn moveForward(camera: *Camera, metric: Metric, params: Params, distance: f32) void {
    moveAlongDirection(camera, metric, params, camera.forward, distance);
}

pub fn moveRight(camera: *Camera, metric: Metric, params: Params, distance: f32) void {
    moveAlongDirection(camera, metric, params, camera.right, distance);
}

pub fn worldHeadingDirection(metric: Metric, camera: Camera, x_heading: f32, z_heading: f32) ?Vec4 {
    const candidate = Vec4{ 0.0, x_heading, 0.0, z_heading };
    return tryNormalizeTangent(metric, projectToTangent(metric, camera.position, candidate));
}

pub fn orientFromHeadingPitch(
    metric: Metric,
    camera: *Camera,
    x_heading: f32,
    z_heading: f32,
    pitch_angle: f32,
) void {
    const horizontal_forward = worldHeadingDirection(metric, camera.*, x_heading, z_heading) orelse return;
    const horizontal_right = worldHeadingDirection(metric, camera.*, z_heading, -x_heading) orelse return;
    const world_up = orthonormalCandidate(metric, camera.position, .{ 0.0, 0.0, 1.0, 0.0 }, &.{}) orelse
        orthonormalCandidate(metric, camera.position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{}) orelse
        return;

    camera.forward = add4(
        scale4(horizontal_forward, @cos(pitch_angle)),
        scale4(world_up, @sin(pitch_angle)),
    );
    camera.forward = tryNormalizeTangent(metric, projectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = orthonormalCandidate(metric, camera.position, horizontal_right, &.{camera.forward}) orelse return;
    camera.up = orthonormalCandidate(metric, camera.position, world_up, &.{ camera.forward, camera.right }) orelse return;
    reorthonormalize(metric, camera);
}

fn projectSampleDirection(projection: visualizer.DirectionProjection, x_dir: f32, y_dir: f32, z_dir: f32, canvas_width: usize, canvas_height: usize, zoom: f32) ?[2]f32 {
    return visualizer.projectDirectionWith(projection, x_dir, y_dir, z_dir, canvas_width, canvas_height, zoom);
}

pub fn projectPoint(
    metric: Metric,
    projection: visualizer.DirectionProjection,
    params: Params,
    camera: Camera,
    chart: Vec3,
    canvas_width: usize,
    canvas_height: usize,
) ?[2]f32 {
    const ambient = embedPoint(metric, params, chart) orelse return null;
    const ray = geodesicDirection(metric, camera.position, ambient) orelse return null;

    const x = metricDot(metric, ray, camera.right);
    const y = metricDot(metric, ray, camera.up);
    const z = metricDot(metric, ray, camera.forward);

    return projectSampleDirection(projection, x, y, z, canvas_width, canvas_height, params.angular_zoom);
}

pub fn samplePoint(metric: Metric, params: Params, camera: Camera, chart: Vec3) ?Sample {
    const ambient = embedPoint(metric, params, chart) orelse return null;
    const ray = geodesicDirection(metric, camera.position, ambient) orelse return null;
    const inner = metricDot(metric, camera.position, ambient);

    const distance = switch (metric) {
        .hyperbolic => params.radius * std.math.acosh(@max(-inner, 1.0)),
        .elliptic => params.radius * std.math.acos(@min(@abs(inner), 1.0)),
        .spherical => params.radius * std.math.acos(std.math.clamp(inner, -1.0, 1.0)),
    };

    return .{
        .distance = distance,
        .x_dir = metricDot(metric, ray, camera.right),
        .y_dir = metricDot(metric, ray, camera.up),
        .z_dir = metricDot(metric, ray, camera.forward),
    };
}

pub fn projectSample(projection: visualizer.DirectionProjection, sample: Sample, canvas_width: usize, canvas_height: usize, zoom: f32) ?[2]f32 {
    return projectSampleDirection(projection, sample.x_dir, sample.y_dir, sample.z_dir, canvas_width, canvas_height, zoom);
}

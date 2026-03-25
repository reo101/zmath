const std = @import("std");
const render = @import("../render.zig");
const hpga = @import("../flavours/hpga.zig");
const epga = @import("../flavours/epga.zig");

pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;

pub const Metric = enum { hyperbolic, elliptic, spherical };

pub const ChartModel = enum {
    projective,
    conformal,
};

pub const CameraModel = enum {
    linear,
    conformal,
};

pub const Params = struct {
    // Constant-curvature radius `R`.
    // Hyperbolic curvature is `-1 / R^2`; elliptic/spherical curvature is `+1 / R^2`.
    radius: f32 = 1.0,
    angular_zoom: f32,
    chart_model: ChartModel = .projective,
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

pub const SampleStatus = enum { hidden, visible, clipped_near, clipped_far };

const RelativeCoords = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,
};

pub const ProjectedSample = struct {
    distance: f32 = 0.0,
    projected: ?[2]f32 = null,
    status: SampleStatus = .hidden,
};

pub const EdgeStyle = struct {
    steps: usize = 64,
    char: u8 = '#',
    near_tone: u8 = 255,
    far_tone: u8 = 243,
    shade_far_distance: ?f32 = null,
    break_wrapped: bool = true,
};

pub const FillStyle = struct {
    steps: usize = 12,
    shade: u8,
    tone: u8,
};

pub const CameraError = error{
    InvalidChartPoint,
    DegenerateDirection,
};

pub const View = struct {
    metric: Metric,
    params: Params,
    projection: render.projection.DirectionProjection,
    clip: DistanceClip,
    camera: Camera,

    pub fn init(
        metric: Metric,
        params: Params,
        projection: render.projection.DirectionProjection,
        clip: DistanceClip,
        eye_chart: Vec3,
        target_chart: Vec3,
    ) CameraError!View {
        return .{
            .metric = metric,
            .params = params,
            .projection = projection,
            .clip = clip,
            .camera = try initCamera(metric, params, eye_chart, target_chart),
        };
    }

    pub fn turnYaw(self: *View, angle: f32) void {
        yaw(&self.camera, self.metric, angle);
    }

    pub fn turnPitch(self: *View, angle: f32) void {
        pitch(&self.camera, self.metric, angle);
    }

    pub fn moveAlong(self: *View, direction: Vec4, distance: f32) void {
        moveAlongDirection(&self.camera, self.metric, self.params, direction, distance);
    }

    pub fn moveForwardBy(self: *View, distance: f32) void {
        moveForward(&self.camera, self.metric, self.params, distance);
    }

    pub fn moveRightBy(self: *View, distance: f32) void {
        moveRight(&self.camera, self.metric, self.params, distance);
    }

    pub fn headingDirection(self: View, x_heading: f32, z_heading: f32) ?Vec4 {
        return worldHeadingDirection(self.metric, self.camera, x_heading, z_heading);
    }

    pub fn syncHeadingPitch(self: *View, x_heading: f32, z_heading: f32, pitch_angle: f32) void {
        orientFromHeadingPitch(self.metric, &self.camera, x_heading, z_heading, pitch_angle);
    }

    pub fn adjustRadius(self: *View, radius: f32, look_ahead: f32) CameraError!void {
        if (radius <= 1e-6) return error.InvalidChartPoint;

        self.params.radius = radius;
        const eye_chart = chartCoords(self.metric, self.params, self.camera.position);
        var probe = self.camera;
        moveForward(&probe, self.metric, self.params, look_ahead);
        const target_chart = chartCoords(self.metric, self.params, probe.position);
        self.camera = try initCamera(self.metric, self.params, eye_chart, target_chart);
    }

    pub fn shadeFarDistance(self: View) f32 {
        return if (self.metric == .spherical) (@as(f32, std.math.pi) * self.params.radius) else self.clip.far;
    }

    pub fn sampleProjectedPoint(self: View, chart: Vec3, screen: Screen) ProjectedSample {
        const point_sample = samplePoint(self.metric, self.params, self.camera, chart) orelse return .{};
        const projected = projectSample(self.projection, point_sample, screen.width, screen.height, screen.zoom);
        return .{
            .distance = point_sample.distance,
            .projected = projected,
            .status = sampleStatus(point_sample.distance, self.clip, projected),
        };
    }

    pub fn cameraModelPoint(self: View, chart: Vec3, model: CameraModel) ?Vec3 {
        return modelPointForCamera(self.metric, self.params, self.camera, chart, model);
    }

    pub fn drawEdge(
        self: View,
        canvas: *render.canvas.Canvas,
        a_chart: Vec3,
        b_chart: Vec3,
        screen: Screen,
        style: EdgeStyle,
    ) void {
        var prev_point: ?[2]f32 = null;
        var prev_distance: ?f32 = null;
        var prev_status: SampleStatus = .hidden;
        const shade_far_distance = style.shade_far_distance orelse self.shadeFarDistance();

        for (0..style.steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(style.steps));
            const chart = geodesicChartPoint(self.metric, self.params, a_chart, b_chart, t) orelse {
                prev_point = null;
                prev_distance = null;
                prev_status = .hidden;
                continue;
            };
            const sample = self.sampleProjectedPoint(chart, screen);
            if (sample.projected) |p| {
                if (prev_status == .visible and sample.status == .visible) {
                    if (prev_point) |pp| {
                        if (prev_distance) |pd| {
                            if (!style.break_wrapped or !shouldBreakProjectionSegment(self.projection, pp, p, screen.width)) {
                                canvas.drawLine(
                                    pp[0],
                                    pp[1],
                                    p[0],
                                    p[1],
                                    style.char,
                                    toneForDistance(pd + (sample.distance - pd) * 0.5, self.clip.near, shade_far_distance, style.near_tone, style.far_tone),
                                );
                            }
                        }
                    }
                } else if (prev_status == .visible and sample.status == .clipped_near) {
                    if (prev_point) |pp| canvas.setMarker(pp[0], pp[1], .near);
                } else if (prev_status == .visible and sample.status == .clipped_far) {
                    if (prev_point) |pp| canvas.setMarker(pp[0], pp[1], .far);
                } else if (prev_status == .clipped_near and sample.status == .visible) {
                    canvas.setMarker(p[0], p[1], .near);
                } else if (prev_status == .clipped_far and sample.status == .visible) {
                    canvas.setMarker(p[0], p[1], .far);
                }

                if (sample.status == .visible) {
                    prev_point = p;
                    prev_distance = sample.distance;
                } else {
                    prev_point = null;
                    prev_distance = null;
                }
            } else {
                prev_point = null;
                prev_distance = null;
            }
            prev_status = sample.status;
        }
    }

    pub fn fillQuad(
        self: View,
        canvas: *render.canvas.Canvas,
        quad: [4]Vec3,
        screen: Screen,
        style: FillStyle,
    ) void {
        const a = quad[0];
        const b = quad[1];
        const c = quad[2];
        const d = quad[3];

        for (0..style.steps + 1) |ui| {
            const u = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(style.steps));
            for (0..style.steps + 1) |vi| {
                const v = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(style.steps));
                const point = bilerpQuad(a, b, c, d, u, v);
                const sample = self.sampleProjectedPoint(point, screen);
                if (sample.status != .visible) continue;
                if (sample.projected) |p| {
                    canvas.setFill(p[0], p[1], style.shade, style.tone, sample.distance);
                }
            }
        }
    }
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

fn bilerpQuad(a: Vec3, b: Vec3, c: Vec3, d: Vec3, u: f32, v: f32) Vec3 {
    const ab = lerp3(a, b, u);
    const dc = lerp3(d, c, u);
    return lerp3(ab, dc, v);
}

fn lerp3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{
        a[0] * (1.0 - t) + b[0] * t,
        a[1] * (1.0 - t) + b[1] * t,
        a[2] * (1.0 - t) + b[2] * t,
    };
}

fn chartScale(params: Params) f32 {
    return params.radius * switch (params.chart_model) {
        .projective => @as(f32, 1.0),
        .conformal => @as(f32, 2.0),
    };
}

fn safeDivDenom(value: f32) f32 {
    if (@abs(value) > 1e-6) return value;
    return if (value < 0.0) -1e-6 else 1e-6;
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
// See Gunn, "Geometry in the 3-Sphere from a Clifford Perspective"
// https://arxiv.org/abs/1310.2713
// and Gunn, "Geometry in the Hyperbolic Plane and Beyond"
// https://arxiv.org/pdf/1602.08562
pub fn embedPoint(metric: Metric, params: Params, chart: Vec3) ?Vec4 {
    const scale = chartScale(params);
    const scaled = Vec3{
        chart[0] / scale,
        chart[1] / scale,
        chart[2] / scale,
    };
    const r2 = scaled[0] * scaled[0] + scaled[1] * scaled[1] + scaled[2] * scaled[2];

    return switch (metric) {
        .hyperbolic => switch (params.chart_model) {
            .projective => {
                const point = hpga.Point.proper(scaled[0], scaled[1], scaled[2]) orelse return null;
                return hpga.ambientCoords(point);
            },
            // Hyperbolica devlog #3 uses the conformal Poincare ball internally.
            // https://www.youtube.com/watch?v=pXWRYpdYc7Q
            .conformal => {
                if (r2 >= 1.0) return null;
                const denom = 1.0 - r2;
                return .{
                    (1.0 + r2) / denom,
                    2.0 * scaled[0] / denom,
                    2.0 * scaled[1] / denom,
                    2.0 * scaled[2] / denom,
                };
            },
        },
        .elliptic, .spherical => switch (params.chart_model) {
            .projective => epga.ambientCoords(epga.Point.proper(scaled[0], scaled[1], scaled[2])),
            // Hyperbolica devlogs #2 and #3 treat spherical space through the
            // conformal stereographic chart so the far side can wrap cleanly.
            // https://www.youtube.com/watch?v=yY9GAyJtuJ0
            // https://www.youtube.com/watch?v=pXWRYpdYc7Q
            .conformal => {
                const denom = 1.0 + r2;
                return .{
                    (1.0 - r2) / denom,
                    2.0 * scaled[0] / denom,
                    2.0 * scaled[1] / denom,
                    2.0 * scaled[2] / denom,
                };
            },
        },
    };
}

pub fn chartCoords(metric: Metric, params: Params, ambient: Vec4) Vec3 {
    var point = ambient;
    if (metric == .elliptic and point[0] < 0.0) {
        point = scale4(point, -1.0);
    }

    const scale = chartScale(params);
    return switch (params.chart_model) {
        .projective => {
            const inv_w = scale / safeDivDenom(point[0]);
            return .{
                point[1] * inv_w,
                point[2] * inv_w,
                point[3] * inv_w,
            };
        },
        .conformal => {
            const inv = scale / safeDivDenom(1.0 + point[0]);
            return .{
                point[1] * inv,
                point[2] * inv,
                point[3] * inv,
            };
        },
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

fn relativeCoords(metric: Metric, camera: Camera, ambient: Vec4) RelativeCoords {
    var point = ambient;
    if (metric == .elliptic and metricDot(metric, camera.position, point) < 0.0) {
        point = scale4(point, -1.0);
    }

    const inner = metricDot(metric, camera.position, point);
    return .{
        .w = switch (metric) {
            .hyperbolic => -inner,
            .elliptic, .spherical => inner,
        },
        .x = metricDot(metric, point, camera.right),
        .y = metricDot(metric, point, camera.up),
        .z = metricDot(metric, point, camera.forward),
    };
}

fn relativeSpatialLength(relative: RelativeCoords) f32 {
    return @sqrt(relative.x * relative.x + relative.y * relative.y + relative.z * relative.z);
}

fn reorthonormalize(metric: Metric, camera: *Camera) void {
    camera.forward = orthonormalCandidate(metric, camera.position, camera.forward, &.{}) orelse camera.forward;
    camera.right = orthonormalCandidate(metric, camera.position, camera.right, &.{camera.forward}) orelse camera.right;
    camera.up = orthonormalCandidate(metric, camera.position, camera.up, &.{ camera.forward, camera.right }) orelse camera.up;
}

pub fn initCamera(metric: Metric, params: Params, eye_chart: Vec3, target_chart: Vec3) CameraError!Camera {
    const position = embedPoint(metric, params, eye_chart) orelse return error.InvalidChartPoint;
    const target = embedPoint(metric, params, target_chart) orelse return error.InvalidChartPoint;
    const forward = geodesicDirection(metric, position, target) orelse return error.DegenerateDirection;
    const up = orthonormalCandidate(metric, position, .{ 0.0, 0.0, 1.0, 0.0 }, &.{forward}) orelse
        orthonormalCandidate(metric, position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{forward}) orelse
        return error.DegenerateDirection;
    const right = orthonormalCandidate(metric, position, .{ 0.0, 1.0, 0.0, 0.0 }, &.{ forward, up }) orelse
        orthonormalCandidate(metric, position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{ forward, up }) orelse
        return error.DegenerateDirection;

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

pub fn projectPoint(
    metric: Metric,
    projection: render.projection.DirectionProjection,
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
    return render.projection.projectDirectionWith(projection, x, y, z, canvas_width, canvas_height, params.angular_zoom);
}

pub fn samplePoint(metric: Metric, params: Params, camera: Camera, chart: Vec3) ?Sample {
    const ambient = embedPoint(metric, params, chart) orelse return null;
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

pub fn modelPointForCamera(
    metric: Metric,
    params: Params,
    camera: Camera,
    chart: Vec3,
    model: CameraModel,
) ?Vec3 {
    const ambient = embedPoint(metric, params, chart) orelse return null;
    const relative = relativeCoords(metric, camera, ambient);
    const denom = switch (model) {
        // Hyperbolica devlog #4 renders hyperbolic geometry through the
        // Beltrami-Klein model and spherical geometry through the gnomonic
        // model because they preserve straightness under vertex interpolation.
        // https://www.youtube.com/watch?v=rqSLuOR3dwY
        .linear => relative.w,
        // Devlog #3 uses the conformal charts internally, matching Poincare
        // for hyperbolic space and stereographic for spherical space.
        // https://www.youtube.com/watch?v=pXWRYpdYc7Q
        .conformal => 1.0 + relative.w,
    };
    if (@abs(denom) <= 1e-6) return null;
    return .{
        relative.x / denom,
        relative.y / denom,
        relative.z / denom,
    };
}

pub fn projectSample(
    projection: render.projection.DirectionProjection,
    point_sample: Sample,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    return render.projection.projectDirectionWith(
        projection,
        point_sample.x_dir,
        point_sample.y_dir,
        point_sample.z_dir,
        canvas_width,
        canvas_height,
        zoom,
    );
}

fn sampleStatus(distance: f32, clip: DistanceClip, projected: ?[2]f32) SampleStatus {
    if (projected == null) return .hidden;
    if (distance < clip.near) return .clipped_near;
    if (distance > clip.far) return .clipped_far;
    return .visible;
}

fn toneForDistance(distance: f32, near_distance: f32, far_distance: f32, near_tone: u8, far_tone: u8) u8 {
    const span = @max(far_distance - near_distance, 1e-3);
    const t = std.math.clamp((distance - near_distance) / span, 0.0, 1.0);
    const near_f = @as(f32, @floatFromInt(near_tone));
    const far_f = @as(f32, @floatFromInt(far_tone));
    return @as(u8, @intFromFloat(@round(near_f + (far_f - near_f) * t)));
}

fn crossesProjectionWrap(a: [2]f32, b: [2]f32, width: usize) bool {
    return @abs(a[0] - b[0]) > @as(f32, @floatFromInt(width)) * 0.45;
}

fn shouldBreakProjectionSegment(
    projection: render.projection.DirectionProjection,
    a: [2]f32,
    b: [2]f32,
    width: usize,
) bool {
    return projection == .wrapped and crossesProjectionWrap(a, b, width);
}

test "hyperbolic and spherical views initialize and sample" {
    var hyper = try View.init(
        .hyperbolic,
        .{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -0.22 },
        .{ 0.0, 0.0, 0.0 },
    );
    const hyper_sample = hyper.sampleProjectedPoint(.{ 0.05, 0.02, 0.01 }, .{ .width = 80, .height = 40, .zoom = hyper.params.angular_zoom });
    try std.testing.expect(hyper_sample.status != .hidden);

    var spherical = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const spherical_sample = spherical.sampleProjectedPoint(.{ 0.12, -0.07, 0.15 }, .{ .width = 80, .height = 40, .zoom = spherical.params.angular_zoom });
    try std.testing.expect(spherical_sample.projected != null);
}

test "adjustRadius preserves a valid camera" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    try view.adjustRadius(1.15, 0.18);
    const sample = view.sampleProjectedPoint(.{ 0.10, 0.05, 0.10 }, .{ .width = 80, .height = 40, .zoom = view.params.angular_zoom });
    try std.testing.expect(sample.projected != null);
}

test "conformal chart roundtrips for hyperbolic and spherical spaces" {
    const hyper_params = Params{
        .radius = 0.32,
        .angular_zoom = 0.72,
        .chart_model = .conformal,
    };
    const hyper_chart = Vec3{ 0.10, -0.04, 0.08 };
    const hyper_roundtrip = chartCoords(.hyperbolic, hyper_params, embedPoint(.hyperbolic, hyper_params, hyper_chart).?);
    inline for (hyper_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, hyper_roundtrip[i], 1e-5);
    }

    const spherical_params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const spherical_chart = Vec3{ 0.35, -0.12, 0.28 };
    const spherical_roundtrip = chartCoords(.spherical, spherical_params, embedPoint(.spherical, spherical_params, spherical_chart).?);
    inline for (spherical_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, spherical_roundtrip[i], 1e-5);
    }
}

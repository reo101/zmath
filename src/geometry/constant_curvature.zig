const std = @import("std");
const ga = @import("../ga.zig");
const projection = @import("../render/projection.zig");
const hpga = @import("../flavours/hpga.zig");
const epga = @import("../flavours/epga.zig");

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

pub const WalkOrientation = struct {
    x_heading: f32,
    z_heading: f32,
    pitch: f32,
};

pub const WalkBasis = struct {
    forward: Vec4,
    right: Vec4,
    up: Vec4,
};

const HeadingBasis = struct {
    east: Vec4,
    north: Vec4,
    up: Vec4,
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
    render_depth: f32 = 0.0,
    projected: ?[2]f32 = null,
    status: SampleStatus = .hidden,
};

pub const CameraError = error{
    InvalidChartPoint,
    DegenerateDirection,
};

const hyper_ambient_naming = ga.SignedBladeNamingOptions.withBasisSpans(ga.BasisIndexSpans.init(.{
    .positive = .range(1, 3),
    .negative = .singleton(0),
}));
const round_ambient_naming = ga.SignedBladeNamingOptions.withBasisSpans(ga.BasisIndexSpans.init(.{
    .positive = .range(0, 3),
}));
const Flat3 = ga.Algebra(.euclidean(3)).Instantiate(f32);

pub const Vec3 = Flat3.Vector;
pub const Vec4 = [4]f32;

const HyperAmbient = ga.AlgebraWithNamingOptions(.{ .p = 3, .q = 1 }, hyper_ambient_naming).Instantiate(f32);
const RoundAmbient = ga.AlgebraWithNamingOptions(.{ .p = 4 }, round_ambient_naming).Instantiate(f32);

pub const SphericalRenderPass = enum { near, far };

pub const spherical_chart_min_denom: f32 = 0.25;

const SphericalPassSelection = struct {
    pass: SphericalRenderPass,
    near_distance: f32,
};

pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3.init(.{ x, y, z });
}

pub fn vec3x(v: Vec3) f32 {
    return v.coeffNamed("e1");
}

pub fn vec3y(v: Vec3) f32 {
    return v.coeffNamed("e2");
}

pub fn vec3z(v: Vec3) f32 {
    return v.coeffNamed("e3");
}

pub fn vec3Coords(v: Vec3) [3]f32 {
    return .{ vec3x(v), vec3y(v), vec3z(v) };
}

pub fn coerceVec3(value: anytype) Vec3 {
    return if (@TypeOf(value) == Vec3) value else Vec3.init(value);
}

fn sphericalUsesMultipass(projection_mode: projection.DirectionProjection) bool {
    return switch (projection_mode) {
        .wrapped => false,
        .gnomonic, .stereographic, .orthographic => true,
    };
}

pub const View = struct {
    metric: Metric,
    params: Params,
    projection: projection.DirectionProjection,
    clip: DistanceClip,
    camera: Camera,
    scene_sign: f32,

    pub fn init(
        metric: Metric,
        params: Params,
        projection_mode: projection.DirectionProjection,
        clip: DistanceClip,
        eye_chart: anytype,
        target_chart: anytype,
    ) CameraError!View {
        return .{
            .metric = metric,
            .params = params,
            .projection = projection_mode,
            .clip = clip,
            .camera = try initCamera(metric, params, coerceVec3(eye_chart), coerceVec3(target_chart)),
            .scene_sign = 1.0,
        };
    }

    pub fn turnYaw(self: *View, angle: f32) void {
        yaw(&self.camera, self.metric, angle);
    }

    pub fn turnWalkYaw(self: *View, angle: f32) void {
        const orientation = self.walkOrientation() orelse {
            self.turnYaw(angle);
            return;
        };

        const c = @cos(angle);
        const s = @sin(angle);
        const x_heading = orientation.x_heading * c + orientation.z_heading * s;
        const z_heading = orientation.z_heading * c - orientation.x_heading * s;
        self.syncHeadingPitch(x_heading, z_heading, orientation.pitch);
    }

    pub fn turnSurfaceYaw(self: *View, angle: f32, pitch_angle: f32) void {
        const basis = self.walkSurfaceBasis(pitch_angle) orelse {
            self.turnYaw(angle);
            return;
        };

        const c = @cos(angle);
        const s = @sin(angle);
        const horizontal_forward = add4(
            self.metric,
            scale4(self.metric, basis.forward, c),
            scale4(self.metric, basis.right, s),
        );
        const horizontal_right = sub4(
            self.metric,
            scale4(self.metric, basis.right, c),
            scale4(self.metric, basis.forward, s),
        );

        self.camera.forward = add4(
            self.metric,
            scale4(self.metric, horizontal_forward, @cos(pitch_angle)),
            scale4(self.metric, basis.up, @sin(pitch_angle)),
        );
        self.camera.forward = tryNormalizeTangent(
            self.metric,
            projectToTangent(self.metric, self.camera.position, self.camera.forward),
        ) orelse return;
        self.camera.right = orthonormalCandidate(
            self.metric,
            self.camera.position,
            horizontal_right,
            &.{ self.camera.forward, basis.up },
        ) orelse return;
        self.camera.up = orthonormalCandidate(
            self.metric,
            self.camera.position,
            basis.up,
            &.{ self.camera.forward, self.camera.right },
        ) orelse return;
        reorthonormalize(self.metric, &self.camera);
    }

    pub fn syncSurfacePitch(self: *View, pitch_angle: f32) void {
        const basis = self.walkSurfaceBasis(pitch_angle) orelse {
            return;
        };

        self.camera.forward = add4(
            self.metric,
            scale4(self.metric, basis.forward, @cos(pitch_angle)),
            scale4(self.metric, basis.up, @sin(pitch_angle)),
        );
        self.camera.forward = tryNormalizeTangent(
            self.metric,
            projectToTangent(self.metric, self.camera.position, self.camera.forward),
        ) orelse return;
        self.camera.right = orthonormalCandidate(
            self.metric,
            self.camera.position,
            basis.right,
            &.{ self.camera.forward, basis.up },
        ) orelse return;
        self.camera.up = orthonormalCandidate(
            self.metric,
            self.camera.position,
            basis.up,
            &.{ self.camera.forward, self.camera.right },
        ) orelse return;
        reorthonormalize(self.metric, &self.camera);
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

    pub fn walkOrientation(self: View) ?WalkOrientation {
        return currentWalkOrientation(self.metric, self.camera);
    }

    pub fn walkBasis(self: View) ?WalkBasis {
        const orientation = self.walkOrientation() orelse return null;
        const basis = headingBasis(self.metric, self.camera) orelse return null;
        return .{
            .forward = self.headingDirection(orientation.x_heading, orientation.z_heading) orelse return null,
            .right = self.headingDirection(orientation.z_heading, -orientation.x_heading) orelse return null,
            .up = basis.up,
        };
    }

    pub fn walkSurfaceUp(self: View, pitch_angle: f32) ?Vec4 {
        _ = pitch_angle;
        const basis = headingBasis(self.metric, self.camera) orelse return null;
        return basis.up;
    }

    pub fn walkSurfaceBasis(self: View, pitch_angle: f32) ?WalkBasis {
        const up = self.walkSurfaceUp(pitch_angle) orelse return null;
        const forward = orthonormalCandidate(self.metric, self.camera.position, self.camera.forward, &.{up}) orelse
            fallback_forward: {
                const up_sign: f32 = if (pitch_angle >= 0.0) -1.0 else 1.0;
                break :fallback_forward orthonormalCandidate(self.metric, self.camera.position, scale4(self.metric, self.camera.up, up_sign), &.{up});
            } orelse
            return null;
        const right = orthonormalCandidate(self.metric, self.camera.position, self.camera.right, &.{ up, forward }) orelse
            orthonormalCandidate(self.metric, self.camera.position, self.camera.up, &.{ up, forward }) orelse
            return null;
        return .{
            .forward = forward,
            .right = right,
            .up = up,
        };
    }

    pub fn syncHeadingPitch(self: *View, x_heading: f32, z_heading: f32, pitch_angle: f32) void {
        orientFromHeadingPitch(self.metric, &self.camera, x_heading, z_heading, pitch_angle);
    }

    pub fn wrapSphericalChart(self: *View) void {
        if (self.metric != .spherical or self.params.chart_model != .conformal) return;
        if (1.0 + self.camera.position[0] >= spherical_chart_min_denom) return;

        // Spherical stereographic charts have a single bad pole. Move the
        // camera to the antipodal chart so the active chart is well-conditioned.
        //
        // Position and forward are both negated: on S³ the geodesic from P
        // with tangent V arrives at -P with tangent -V after half a great
        // circle.  Right and up are NOT negated — they are orthogonal to
        // forward and parallel-transport around a great circle preserves
        // vectors perpendicular to the direction of travel.  This keeps
        // screen-space x/y continuous across the wrap.
        //
        // Do NOT switch charts just because `w < 0`. The conformal chart is
        // still perfectly valid there; only the single pole at `w = -1`
        // is singular. Wrapping too early creates visible 180-degree camera
        // branch flips in walk mode.
        //
        // scene_sign is not flipped: objects keep their original ambient
        // coordinates, and the two-pass rendering system handles the change
        // in which hemisphere they appear in.
        //
        // Hyperbolica devlogs #2 and #3 discuss the stereographic charting.
        // https://www.youtube.com/watch?v=yY9GAyJtuJ0
        // https://www.youtube.com/watch?v=pXWRYpdYc7Q
        self.camera.position = scale4(self.metric, self.camera.position, -1.0);
        self.camera.forward = scale4(self.metric, self.camera.forward, -1.0);
        reorthonormalize(self.metric, &self.camera);
    }

    pub fn adjustRadius(self: *View, radius: f32, look_ahead: f32) CameraError!void {
        if (radius <= 1e-6) return error.InvalidChartPoint;

        const next_params = Params{
            .radius = radius,
            .angular_zoom = self.params.angular_zoom,
            .chart_model = self.params.chart_model,
        };
        const eye_chart = chartCoords(self.metric, next_params, self.camera.position);
        var probe = self.camera;
        moveForward(&probe, self.metric, next_params, look_ahead);
        const target_chart = chartCoords(self.metric, next_params, probe.position);
        const next_camera = try initCamera(self.metric, next_params, eye_chart, target_chart);

        self.params = next_params;
        self.camera = next_camera;
    }

    pub fn shadeFarDistance(self: View) f32 {
        return if (self.metric == .spherical) (@as(f32, std.math.pi) * self.params.radius) else self.clip.far;
    }

    fn sceneAmbientPoint(self: View, chart: anytype) ?Vec4 {
        var ambient = embedPoint(self.metric, self.params, chart) orelse return null;
        if (self.metric == .spherical and self.scene_sign < 0.0) {
            ambient = scale4(self.metric, ambient, -1.0);
        }
        return ambient;
    }

    pub fn sampleProjectedPoint(self: View, chart: anytype, screen: Screen) ProjectedSample {
        const ambient = self.sceneAmbientPoint(chart) orelse return .{};
        return sampleProjectedAmbientPoint(self, ambient, screen);
    }

    pub fn sampleProjectedAmbient(self: View, ambient_input: Vec4, screen: Screen) ProjectedSample {
        var ambient = ambient_input;
        if (self.metric == .spherical and self.scene_sign < 0.0) {
            ambient = scale4(self.metric, ambient, -1.0);
        }
        return sampleProjectedAmbientPoint(self, ambient, screen);
    }

    pub fn sampleProjectedPointForSphericalPass(self: View, pass: SphericalRenderPass, chart: anytype, screen: Screen) ProjectedSample {
        const ambient = self.sceneAmbientPoint(chart) orelse return .{};
        return sampleProjectedAmbientForSphericalPass(pass, ambient, screen);
    }

    pub fn sampleProjectedAmbientForSphericalPass(self: View, pass: SphericalRenderPass, ambient_input: Vec4, screen: Screen) ProjectedSample {
        std.debug.assert(self.metric == .spherical);
        std.debug.assert(sphericalUsesMultipass(self.projection));

        const ambient = self.signedSphericalAmbient(ambient_input);
        return sampleProjectedAmbientPointForPass(self, pass, ambient, screen);
    }

    pub fn sampleProjectedAmbientForSphericalPassRaw(self: View, pass: SphericalRenderPass, ambient_input: Vec4, screen: Screen) ProjectedSample {
        std.debug.assert(self.metric == .spherical);
        std.debug.assert(sphericalUsesMultipass(self.projection));

        const ambient = self.signedSphericalAmbient(ambient_input);
        return sampleProjectedAmbientPointForPassRaw(self, pass, ambient, screen);
    }

    pub fn sphericalSelectedPassForAmbient(self: View, ambient_input: Vec4) ?SphericalRenderPass {
        std.debug.assert(self.metric == .spherical);
        std.debug.assert(sphericalUsesMultipass(self.projection));

        const ambient = self.signedSphericalAmbient(ambient_input);
        const selection = sphericalPassSelection(self, ambient) orelse return null;
        return selection.pass;
    }

    pub fn sphericalRenderPass(self: View, pass: SphericalRenderPass) View {
        std.debug.assert(self.metric == .spherical);
        std.debug.assert(sphericalUsesMultipass(self.projection));

        var render_view = self;
        render_view.clip = .{
            .near = if (pass == .near) self.clip.near else 0.0,
            .far = hemisphereDistance(self.params),
        };

        if (pass == .far) {
            render_view.camera = antipodalSphericalPassCamera(self.camera);
        }

        return render_view;
    }

    pub fn mapSphericalRenderDistance(self: View, pass: SphericalRenderPass, pass_distance: f32) f32 {
        std.debug.assert(self.metric == .spherical);
        return switch (pass) {
            .near => pass_distance,
            .far => maxSphericalDistance(self.params) - pass_distance,
        };
    }

    pub fn cameraModelPoint(self: View, chart: anytype, model: CameraModel) ?Vec3 {
        const ambient = self.sceneAmbientPoint(chart) orelse return null;
        return modelPointForAmbient(self.metric, self.camera, ambient, model);
    }

    fn signedSphericalAmbient(self: View, ambient_input: Vec4) Vec4 {
        var ambient = ambient_input;
        if (self.scene_sign < 0.0) {
            ambient = scale4(self.metric, ambient, -1.0);
        }
        return ambient;
    }
};

fn hyperAmbientVector(coords: Vec4) HyperAmbient.Vector {
    const E = HyperAmbient.Basis;
    return E.e(0).scale(coords[0])
        .add(E.e(1).scale(coords[1]))
        .add(E.e(2).scale(coords[2]))
        .add(E.e(3).scale(coords[3]));
}

fn roundAmbientVector(coords: Vec4) RoundAmbient.Vector {
    const E = RoundAmbient.Basis;
    return E.e(0).scale(coords[0])
        .add(E.e(1).scale(coords[1]))
        .add(E.e(2).scale(coords[2]))
        .add(E.e(3).scale(coords[3]));
}

fn coordsFromHyperAmbient(v: HyperAmbient.Vector) Vec4 {
    return .{
        @floatCast(v.coeffNamedWithOptions("e0", hyper_ambient_naming)),
        @floatCast(v.coeffNamedWithOptions("e1", hyper_ambient_naming)),
        @floatCast(v.coeffNamedWithOptions("e2", hyper_ambient_naming)),
        @floatCast(v.coeffNamedWithOptions("e3", hyper_ambient_naming)),
    };
}

fn coordsFromRoundAmbient(v: RoundAmbient.Vector) Vec4 {
    return .{
        @floatCast(v.coeffNamedWithOptions("e0", round_ambient_naming)),
        @floatCast(v.coeffNamedWithOptions("e1", round_ambient_naming)),
        @floatCast(v.coeffNamedWithOptions("e2", round_ambient_naming)),
        @floatCast(v.coeffNamedWithOptions("e3", round_ambient_naming)),
    };
}

fn coordsFromFlatVector(v: Flat3.Vector) Vec3 {
    return v;
}

pub fn ambientAdd(metric: Metric, a: Vec4, b: Vec4) Vec4 {
    return add4(metric, a, b);
}

pub fn ambientSub(metric: Metric, a: Vec4, b: Vec4) Vec4 {
    return sub4(metric, a, b);
}

pub fn ambientScale(metric: Metric, v: Vec4, s: f32) Vec4 {
    return scale4(metric, v, s);
}

pub fn ambientDot(metric: Metric, a: Vec4, b: Vec4) f32 {
    return metricDot(metric, a, b);
}

pub fn flatLerp3(a_input: anytype, b_input: anytype, t: f32) Vec3 {
    const a = coerceVec3(a_input);
    const b = coerceVec3(b_input);
    return a.scale(1.0 - t).add(b.scale(t));
}

pub fn flatBilerpQuad(a: anytype, b: anytype, c: anytype, d: anytype, u: f32, v: f32) Vec3 {
    const ab = flatLerp3(a, b, u);
    const dc = flatLerp3(d, c, u);
    return flatLerp3(ab, dc, v);
}

fn add4(metric: Metric, a: Vec4, b: Vec4) Vec4 {
    return switch (metric) {
        .hyperbolic => coordsFromHyperAmbient(hyperAmbientVector(a).add(hyperAmbientVector(b))),
        .elliptic, .spherical => coordsFromRoundAmbient(roundAmbientVector(a).add(roundAmbientVector(b))),
    };
}

fn sub4(metric: Metric, a: Vec4, b: Vec4) Vec4 {
    return switch (metric) {
        .hyperbolic => coordsFromHyperAmbient(hyperAmbientVector(a).sub(hyperAmbientVector(b))),
        .elliptic, .spherical => coordsFromRoundAmbient(roundAmbientVector(a).sub(roundAmbientVector(b))),
    };
}

fn scale4(metric: Metric, v: Vec4, s: f32) Vec4 {
    return switch (metric) {
        .hyperbolic => coordsFromHyperAmbient(hyperAmbientVector(v).scale(s)),
        .elliptic, .spherical => coordsFromRoundAmbient(roundAmbientVector(v).scale(s)),
    };
}

fn flatVector(point: Vec3) Flat3.Vector {
    return point;
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

fn maxSphericalDistance(params: Params) f32 {
    return @as(f32, std.math.pi) * params.radius;
}

fn hemisphereDistance(params: Params) f32 {
    return maxSphericalDistance(params) * 0.5;
}

pub fn sphericalAmbientFromLocalPoint(params: Params, local_input: anytype) Vec4 {
    const local = coerceVec3(local_input);
    const local_radius = local.magnitude();
    if (local_radius <= 1e-6) return .{ 1.0, 0.0, 0.0, 0.0 };

    const theta = local_radius / params.radius;
    const spatial_scale = @sin(theta) / local_radius;
    return .{
        @cos(theta),
        vec3x(local) * spatial_scale,
        vec3y(local) * spatial_scale,
        vec3z(local) * spatial_scale,
    };
}

pub fn sphericalAmbientFromGroundHeightPoint(params: Params, local_input: anytype) Vec4 {
    const local = coerceVec3(local_input);
    const base = ambientFromTangentBasisPoint(
        .spherical,
        params,
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
        vec3x(local),
        vec3z(local),
    ) orelse return .{ 1.0, 0.0, 0.0, 0.0 };
    if (@abs(vec3y(local)) <= 1e-6) return base;

    const up = worldUpAt(.spherical, base) orelse return base;
    const normalized_height = vec3y(local) / params.radius;
    return normalizeAmbient(.spherical, add4(
        .spherical,
        scale4(.spherical, base, @cos(normalized_height)),
        scale4(.spherical, up, @sin(normalized_height)),
    ));
}

pub fn ambientFromTangentBasisPoint(
    metric: Metric,
    params: Params,
    origin: Vec4,
    right: Vec4,
    forward: Vec4,
    lateral: f32,
    forward_distance: f32,
) ?Vec4 {
    const tangent = add4(
        metric,
        scale4(metric, right, lateral),
        scale4(metric, forward, forward_distance),
    );
    const tangent_norm2 = metricDot(metric, tangent, tangent);
    if (tangent_norm2 <= 1e-6) return origin;

    const tangent_norm = @sqrt(tangent_norm2);
    const normalized_distance = tangent_norm / params.radius;
    const position = switch (metric) {
        .hyperbolic => add4(
            metric,
            scale4(metric, origin, std.math.cosh(normalized_distance)),
            scale4(metric, tangent, std.math.sinh(normalized_distance) / tangent_norm),
        ),
        .elliptic, .spherical => add4(
            metric,
            scale4(metric, origin, @cos(normalized_distance)),
            scale4(metric, tangent, @sin(normalized_distance) / tangent_norm),
        ),
    };
    return normalizeAmbient(metric, position);
}

fn antipodalSphericalPassCamera(camera: Camera) Camera {
    // Move to the antipodal point and reverse the forward direction so the
    // far hemisphere faces the camera.  Right and up are kept unchanged so
    // that screen-space x/y stay continuous across the near/far seam:
    //   near camera relative coords:  (x, y, z)
    //   far camera relative coords:   (x, y, -z)
    // Only z flips, which the pass-selection logic already expects (z < 0
    // in the near camera becomes z > 0 in the far camera).
    return .{
        .position = scale4(.spherical, camera.position, -1.0),
        .right = camera.right,
        .up = camera.up,
        .forward = scale4(.spherical, camera.forward, -1.0),
    };
}

fn sampleProjectedAmbientPointSinglePass(view: View, ambient: Vec4, screen: Screen) ProjectedSample {
    if (cameraModelForRender(view.metric, view.projection)) |camera_model| {
        const model_point = modelPointForAmbient(view.metric, view.camera, ambient, camera_model) orelse return .{};
        return sampleProjectedModelPoint(
            view.metric,
            view.projection,
            view.params,
            view.clip,
            model_point,
            screen,
        );
    }

    const point_sample = sampleAmbientPoint(view.metric, view.params, view.camera, ambient) orelse return .{};
    const projected = projectSample(view.projection, point_sample, screen.width, screen.height, screen.zoom);
    return .{
        .distance = point_sample.distance,
        .projected = projected,
        .status = sampleStatus(point_sample.distance, view.clip, projected),
    };
}

fn sampleProjectedAmbientPointForPass(
    view: View,
    pass: SphericalRenderPass,
    ambient: Vec4,
    screen: Screen,
) ProjectedSample {
    const selection = sphericalPassSelection(view, ambient) orelse return .{};
    if (selection.pass != pass) return .{ .distance = selection.near_distance };

    return sampleProjectedAmbientPointForPassRaw(view, pass, ambient, screen);
}

fn sampleProjectedAmbientPointForPassRaw(
    view: View,
    pass: SphericalRenderPass,
    ambient: Vec4,
    screen: Screen,
) ProjectedSample {
    const model = cameraModelForRender(view.metric, view.projection);

    if (pass == .near) {
        if (model) |camera_model| {
            const model_point = modelPointForAmbient(view.metric, view.camera, ambient, camera_model) orelse return .{};
            return sampleProjectedModelPoint(
                view.metric,
                view.projection,
                view.params,
                view.clip,
                model_point,
                screen,
            );
        }

        const near_sample = sampleAmbientPoint(view.metric, view.params, view.camera, ambient) orelse return .{};
        const projected = projectSample(view.projection, near_sample, screen.width, screen.height, screen.zoom);
        return .{
            .distance = near_sample.distance,
            .projected = projected,
            .status = sampleStatus(near_sample.distance, view.clip, projected),
        };
    }

    const far_camera = antipodalSphericalPassCamera(view.camera);
    if (model) |camera_model| {
        const model_point = modelPointForAmbient(view.metric, far_camera, ambient, camera_model) orelse return .{};
        const far_sample = sampleProjectedModelPoint(
            view.metric,
            view.projection,
            view.params,
            .{ .near = 0.0, .far = hemisphereDistance(view.params) },
            model_point,
            screen,
        );
        if (far_sample.projected == null) return far_sample;
        const mapped_distance = maxSphericalDistance(view.params) - far_sample.distance;
        return .{
            .distance = mapped_distance,
            .projected = far_sample.projected,
            .status = sampleStatus(mapped_distance, view.clip, far_sample.projected),
        };
    }

    const far_pass_sample = sampleAmbientPoint(view.metric, view.params, far_camera, ambient) orelse return .{};
    const mapped_distance = maxSphericalDistance(view.params) - far_pass_sample.distance;
    const projected = projectSample(view.projection, far_pass_sample, screen.width, screen.height, screen.zoom);
    return .{
        .distance = mapped_distance,
        .projected = projected,
        .status = sampleStatus(mapped_distance, view.clip, projected),
    };
}

fn sphericalPassSelection(view: View, ambient: Vec4) ?SphericalPassSelection {
    const near_sample = sampleAmbientPoint(view.metric, view.params, view.camera, ambient) orelse return null;
    return .{
        .pass = if (near_sample.z_dir >= 0.0) .near else .far,
        .near_distance = near_sample.distance,
    };
}

fn sampleProjectedAmbientPoint(view: View, ambient: Vec4, screen: Screen) ProjectedSample {
    if (view.metric != .spherical or !sphericalUsesMultipass(view.projection)) {
        return sampleProjectedAmbientPointSinglePass(view, ambient, screen);
    }

    const near = sampleProjectedAmbientPointForPass(view, .near, ambient, screen);
    if (near.status != .hidden or near.projected != null) return near;
    return sampleProjectedAmbientPointForPass(view, .far, ambient, screen);
}

fn cameraModelForRender(metric: Metric, projection_mode: projection.DirectionProjection) ?CameraModel {
    return switch (projection_mode) {
        // Hyperbolica devlog #4 identifies the camera-relative linear models:
        // Beltrami-Klein for hyperbolic space and gnomonic for spherical
        // space. The same devlog then switches spherical rendering to a
        // two-pass stereographic compromise for full-sphere coverage.
        // https://www.youtube.com/watch?v=rqSLuOR3dwY
        .gnomonic => .linear,
        .wrapped, .orthographic => if (metric == .hyperbolic) .linear else null,
        .stereographic => .conformal,
    };
}

fn metricDot(metric: Metric, a: Vec4, b: Vec4) f32 {
    return switch (metric) {
        .hyperbolic => hyperAmbientVector(a).scalarProduct(hyperAmbientVector(b)),
        .elliptic, .spherical => roundAmbientVector(a).scalarProduct(roundAmbientVector(b)),
    };
}

fn tryNormalizeTangent(metric: Metric, v: Vec4) ?Vec4 {
    const n2 = metricDot(metric, v, v);
    if (n2 <= 1e-6) return null;
    return scale4(metric, v, 1.0 / @sqrt(n2));
}

fn projectToTangent(metric: Metric, position: Vec4, candidate: Vec4) Vec4 {
    const denom = metricDot(metric, position, position);
    const along = metricDot(metric, candidate, position) / denom;
    return sub4(metric, candidate, scale4(metric, position, along));
}

fn orthonormalCandidate(metric: Metric, position: Vec4, candidate: Vec4, refs: []const Vec4) ?Vec4 {
    var v = projectToTangent(metric, position, candidate);
    for (refs) |r| {
        v = sub4(metric, v, scale4(metric, r, metricDot(metric, v, r)));
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
pub fn embedPoint(metric: Metric, params: Params, chart_input: anytype) ?Vec4 {
    const chart = coerceVec3(chart_input);
    const scale = chartScale(params);
    const scaled = vec3(vec3x(chart) / scale, vec3y(chart) / scale, vec3z(chart) / scale);
    const r2 = scaled.scalarProduct(scaled);

    return switch (metric) {
        .hyperbolic => switch (params.chart_model) {
            .projective => {
                const point = hpga.Point.proper(vec3x(scaled), vec3y(scaled), vec3z(scaled)) orelse return null;
                return hpga.ambientCoords(point);
            },
            // Hyperbolica devlog #3 uses the conformal Poincare ball internally.
            // https://www.youtube.com/watch?v=pXWRYpdYc7Q
            .conformal => {
                if (r2 >= 1.0) return null;
                const denom = 1.0 - r2;
                return .{
                    (1.0 + r2) / denom,
                    2.0 * vec3x(scaled) / denom,
                    2.0 * vec3y(scaled) / denom,
                    2.0 * vec3z(scaled) / denom,
                };
            },
        },
        .elliptic, .spherical => switch (params.chart_model) {
            .projective => epga.ambientCoords(epga.Point.proper(vec3x(scaled), vec3y(scaled), vec3z(scaled))),
            // Hyperbolica devlogs #2 and #3 treat spherical space through the
            // conformal stereographic chart so the far side can wrap cleanly.
            // https://www.youtube.com/watch?v=yY9GAyJtuJ0
            // https://www.youtube.com/watch?v=pXWRYpdYc7Q
            .conformal => {
                const denom = 1.0 + r2;
                return .{
                    (1.0 - r2) / denom,
                    2.0 * vec3x(scaled) / denom,
                    2.0 * vec3y(scaled) / denom,
                    2.0 * vec3z(scaled) / denom,
                };
            },
        },
    };
}

pub fn chartCoords(metric: Metric, params: Params, ambient: Vec4) Vec3 {
    var point = ambient;
    if (metric == .elliptic and point[0] < 0.0) {
        point = scale4(metric, point, -1.0);
    }

    const scale = chartScale(params);
    return switch (params.chart_model) {
        .projective => {
            const inv_w = scale / safeDivDenom(point[0]);
            return vec3(point[1] * inv_w, point[2] * inv_w, point[3] * inv_w);
        },
        .conformal => {
            const inv = scale / safeDivDenom(1.0 + point[0]);
            return vec3(point[1] * inv, point[2] * inv, point[3] * inv);
        },
    };
}

fn normalizeAmbient(metric: Metric, ambient: Vec4) Vec4 {
    const norm2 = metricDot(metric, ambient, ambient);
    const inv = switch (metric) {
        .hyperbolic => 1.0 / @sqrt(@max(-norm2, 1e-6)),
        .elliptic, .spherical => 1.0 / @sqrt(@max(norm2, 1e-6)),
    };
    return scale4(metric, ambient, inv);
}

fn transportedTangent(metric: Metric, old_direction: Vec4, new_direction: Vec4, tangent: Vec4) Vec4 {
    const along = metricDot(metric, tangent, old_direction);
    return add4(
        metric,
        sub4(metric, tangent, scale4(metric, old_direction, along)),
        scale4(metric, new_direction, along),
    );
}

fn geodesicAmbientPoint(metric: Metric, a: Vec4, b_input: Vec4, t: f32) ?Vec4 {
    var b = b_input;

    return switch (metric) {
        .hyperbolic => {
            const cosh_omega = @max(-metricDot(metric, a, b), 1.0);
            const omega = std.math.acosh(cosh_omega);
            if (omega <= 1e-5) return a;

            const inv_denom = 1.0 / std.math.sinh(omega);
            const p = add4(
                metric,
                scale4(metric, a, std.math.sinh((1.0 - t) * omega) * inv_denom),
                scale4(metric, b, std.math.sinh(t * omega) * inv_denom),
            );
            return normalizeAmbient(metric, p);
        },
        .elliptic, .spherical => {
            if (metric == .elliptic and metricDot(metric, a, b) < 0.0) {
                b = scale4(metric, b, -1.0);
            }

            const cos_omega = std.math.clamp(metricDot(metric, a, b), -1.0, 1.0);
            const omega = std.math.acos(cos_omega);
            if (omega <= 1e-5) return a;

            const inv_denom = 1.0 / @sin(omega);
            const p = add4(
                metric,
                scale4(metric, a, @sin((1.0 - t) * omega) * inv_denom),
                scale4(metric, b, @sin(t * omega) * inv_denom),
            );
            return normalizeAmbient(metric, p);
        },
    };
}

// Intrinsic geodesic interpolation in the ambient constant-curvature models.
// References:
// https://arxiv.org/abs/1310.2713
// https://arxiv.org/pdf/1602.08562
pub fn geodesicChartPoint(metric: Metric, params: Params, a_chart: anytype, b_chart: anytype, t: f32) ?Vec3 {
    const a = embedPoint(metric, params, a_chart) orelse return null;
    const b = embedPoint(metric, params, b_chart) orelse return null;
    const ambient = geodesicAmbientPoint(metric, a, b, t) orelse return null;
    return chartCoords(metric, params, ambient);
}

// The initial viewing ray is the tangent of the geodesic from the eye point to
// the target point, obtained by removing the eye component with the ambient
// metric of the model. Same references as above.
fn geodesicDirection(metric: Metric, eye: Vec4, target: Vec4) ?Vec4 {
    var adjusted_target = target;
    if (metric == .elliptic and metricDot(metric, eye, adjusted_target) < 0.0) {
        adjusted_target = scale4(metric, adjusted_target, -1.0);
    }

    const inner = metricDot(metric, eye, adjusted_target);
    const tangent = switch (metric) {
        .hyperbolic => add4(metric, adjusted_target, scale4(metric, eye, inner)),
        .elliptic, .spherical => sub4(metric, adjusted_target, scale4(metric, eye, inner)),
    };
    return tryNormalizeTangent(metric, tangent);
}

fn relativeCoords(metric: Metric, camera: Camera, ambient: Vec4) RelativeCoords {
    var point = ambient;
    if (metric == .elliptic and metricDot(metric, camera.position, point) < 0.0) {
        point = scale4(metric, point, -1.0);
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

fn projectConformalModelPoint(
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

fn reorthonormalize(metric: Metric, camera: *Camera) void {
    camera.forward = orthonormalCandidate(metric, camera.position, camera.forward, &.{}) orelse camera.forward;
    camera.right = orthonormalCandidate(metric, camera.position, camera.right, &.{camera.forward}) orelse camera.right;
    camera.up = orthonormalCandidate(metric, camera.position, camera.up, &.{ camera.forward, camera.right }) orelse camera.up;
}

pub fn initCamera(metric: Metric, params: Params, eye_chart_input: anytype, target_chart_input: anytype) CameraError!Camera {
    const eye_chart = coerceVec3(eye_chart_input);
    const target_chart = coerceVec3(target_chart_input);
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
    first.* = add4(metric, scale4(metric, old_first, c), scale4(metric, old_second, s));
    second.* = sub4(metric, scale4(metric, old_second, c), scale4(metric, old_first, s));
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
            new_position = add4(metric, scale4(metric, old_position, c), scale4(metric, old_direction, s));
            new_direction = add4(metric, scale4(metric, old_position, s), scale4(metric, old_direction, c));
        },
        .elliptic, .spherical => {
            const c = @cos(normalized_distance);
            const s = @sin(normalized_distance);
            new_position = add4(metric, scale4(metric, old_position, c), scale4(metric, old_direction, s));
            new_direction = add4(metric, scale4(metric, old_direction, c), scale4(metric, old_position, -s));
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

fn headingBasis(metric: Metric, camera: Camera) ?HeadingBasis {
    const up = worldUpDirection(metric, camera) orelse return null;
    const east = orthonormalCandidate(metric, camera.position, .{ 0.0, 1.0, 0.0, 0.0 }, &.{up}) orelse
        orthonormalCandidate(metric, camera.position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{up}) orelse
        orthonormalCandidate(metric, camera.position, .{ 1.0, 0.0, 0.0, 0.0 }, &.{up}) orelse
        return null;
    const north = orthonormalCandidate(metric, camera.position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{ up, east }) orelse
        orthonormalCandidate(metric, camera.position, .{ 1.0, 0.0, 0.0, 0.0 }, &.{ up, east }) orelse
        orthonormalCandidate(metric, camera.position, .{ 0.0, 1.0, 0.0, 0.0 }, &.{ up, east }) orelse
        return null;

    return .{
        .east = east,
        .north = north,
        .up = up,
    };
}

pub fn worldHeadingDirection(metric: Metric, camera: Camera, x_heading: f32, z_heading: f32) ?Vec4 {
    const basis = headingBasis(metric, camera) orelse return null;
    return tryNormalizeTangent(metric, add4(
        metric,
        scale4(metric, basis.east, x_heading),
        scale4(metric, basis.north, z_heading),
    ));
}

fn worldUpAt(metric: Metric, position: Vec4) ?Vec4 {
    return orthonormalCandidate(metric, position, .{ 0.0, 0.0, 1.0, 0.0 }, &.{}) orelse
        orthonormalCandidate(metric, position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{});
}

fn worldUpDirection(metric: Metric, camera: Camera) ?Vec4 {
    return worldUpAt(metric, camera.position);
}

fn currentWalkOrientation(metric: Metric, camera: Camera) ?WalkOrientation {
    const basis = headingBasis(metric, camera) orelse return null;
    const pitch_angle = std.math.asin(std.math.clamp(metricDot(metric, camera.forward, basis.up), -1.0, 1.0));

    const forward_ground = orthonormalCandidate(metric, camera.position, camera.forward, &.{basis.up}) orelse fallback_ground: {
        const up_sign: f32 = if (pitch_angle >= 0.0) -1.0 else 1.0;
        break :fallback_ground orthonormalCandidate(metric, camera.position, scale4(metric, camera.up, up_sign), &.{basis.up}) orelse return null;
    };

    const x_heading = metricDot(metric, forward_ground, basis.east);
    const z_heading = metricDot(metric, forward_ground, basis.north);
    const heading_len = @sqrt(x_heading * x_heading + z_heading * z_heading);
    if (heading_len <= 1e-6) return null;

    return .{
        .x_heading = x_heading / heading_len,
        .z_heading = z_heading / heading_len,
        .pitch = pitch_angle,
    };
}

pub fn orientFromHeadingPitch(
    metric: Metric,
    camera: *Camera,
    x_heading: f32,
    z_heading: f32,
    pitch_angle: f32,
) void {
    const basis = headingBasis(metric, camera.*) orelse return;
    const horizontal_forward = worldHeadingDirection(metric, camera.*, x_heading, z_heading) orelse return;
    const horizontal_right = worldHeadingDirection(metric, camera.*, z_heading, -x_heading) orelse return;

    camera.forward = add4(
        metric,
        scale4(metric, horizontal_forward, @cos(pitch_angle)),
        scale4(metric, basis.up, @sin(pitch_angle)),
    );
    camera.forward = tryNormalizeTangent(metric, projectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = orthonormalCandidate(metric, camera.position, horizontal_right, &.{camera.forward}) orelse return;
    camera.up = orthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    reorthonormalize(metric, camera);
}

pub fn projectPoint(
    metric: Metric,
    projection_mode: projection.DirectionProjection,
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
    return projection.projectDirectionWith(projection_mode, x, y, z, canvas_width, canvas_height, params.angular_zoom);
}

fn sampleAmbientPoint(metric: Metric, params: Params, camera: Camera, ambient: Vec4) ?Sample {
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

pub fn samplePoint(metric: Metric, params: Params, camera: Camera, chart: anytype) ?Sample {
    const ambient = embedPoint(metric, params, chart) orelse return null;
    return sampleAmbientPoint(metric, params, camera, ambient);
}

fn modelPointForAmbient(metric: Metric, camera: Camera, ambient: Vec4, model: CameraModel) ?Vec3 {
    const relative = relativeCoords(metric, camera, ambient);
    const denom = switch (model) {
        // Hyperbolica devlog #4 uses the linear camera-relative models where
        // straight interpolation matters: Beltrami-Klein for hyperbolic space
        // and gnomonic for spherical space.
        // https://www.youtube.com/watch?v=rqSLuOR3dwY
        .linear => relative.w,
        // Devlog #3 uses the conformal charts internally, matching Poincare
        // for hyperbolic space and stereographic for spherical space.
        // https://www.youtube.com/watch?v=pXWRYpdYc7Q
        .conformal => 1.0 + relative.w,
    };
    if (@abs(denom) <= 1e-6) return null;
    return vec3(relative.x / denom, relative.y / denom, relative.z / denom);
}

pub fn modelPointForAmbientWithCamera(metric: Metric, camera: Camera, ambient: Vec4, model: CameraModel) ?Vec3 {
    return modelPointForAmbient(metric, camera, ambient, model);
}

pub fn modelPointForCamera(
    metric: Metric,
    params: Params,
    camera: Camera,
    chart: Vec3,
    model: CameraModel,
) ?Vec3 {
    const ambient = embedPoint(metric, params, chart) orelse return null;
    return modelPointForAmbient(metric, camera, ambient, model);
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

fn sampleStatus(distance: f32, clip: DistanceClip, projected: ?[2]f32) SampleStatus {
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

fn shouldBreakProjectionSegment(
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

fn edgeHasProjectionBreak(view: View, a_chart: Vec3, b_chart: Vec3, screen: Screen, steps: usize) bool {
    var prev_point: ?[2]f32 = null;

    for (0..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const point = geodesicChartPoint(view.metric, view.params, a_chart, b_chart, t) orelse continue;
        const sample = view.sampleProjectedPoint(point, screen);
        if (sample.status != .visible or sample.projected == null) {
            prev_point = null;
            continue;
        }

        if (prev_point) |pp| {
            if (shouldBreakProjectionSegment(view.projection, pp, sample.projected.?, screen.width, screen.height)) {
                return true;
            }
        }

        prev_point = sample.projected;
    }

    return false;
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

test "ambient helpers and flat interpolation stay consistent" {
    const a: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const b: Vec4 = .{ 0.5, -1.0, 2.0, -0.25 };

    const spherical_sum = ambientAdd(.spherical, a, b);
    try std.testing.expectApproxEqAbs(1.5, spherical_sum[0], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, spherical_sum[1], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, spherical_sum[2], 1e-6);
    try std.testing.expectApproxEqAbs(3.75, spherical_sum[3], 1e-6);

    const hyper_diff = ambientSub(.hyperbolic, a, b);
    try std.testing.expectApproxEqAbs(0.5, hyper_diff[0], 1e-6);
    try std.testing.expectApproxEqAbs(3.0, hyper_diff[1], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, hyper_diff[2], 1e-6);
    try std.testing.expectApproxEqAbs(4.25, hyper_diff[3], 1e-6);

    const scaled = ambientScale(.spherical, a, 0.25);
    try std.testing.expectApproxEqAbs(0.25, scaled[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.5, scaled[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.75, scaled[2], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, scaled[3], 1e-6);

    try std.testing.expectApproxEqAbs(3.5, ambientDot(.spherical, a, b), 1e-6);
    try std.testing.expectApproxEqAbs(2.5, ambientDot(.hyperbolic, a, b), 1e-6);

    const lerped = flatLerp3(.{ 0.0, 0.0, 0.0 }, .{ 2.0, 4.0, 6.0 }, 0.25);
    try std.testing.expectApproxEqAbs(0.5, lerped[0], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, lerped[1], 1e-6);
    try std.testing.expectApproxEqAbs(1.5, lerped[2], 1e-6);

    const bilerped = flatBilerpQuad(
        .{ 0.0, 0.0, 0.0 },
        .{ 2.0, 0.0, 0.0 },
        .{ 2.0, 2.0, 0.0 },
        .{ 0.0, 2.0, 0.0 },
        0.5,
        0.25,
    );
    try std.testing.expectApproxEqAbs(1.0, bilerped[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.5, bilerped[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, bilerped[2], 1e-6);
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

test "adjustRadius leaves the view unchanged on rebuild failure" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const before = view;

    try std.testing.expectError(error.DegenerateDirection, view.adjustRadius(1.15, 0.0));
    try std.testing.expectEqual(before.params.radius, view.params.radius);
    try std.testing.expectEqual(before.scene_sign, view.scene_sign);
    inline for (&.{ before.camera.position, before.camera.right, before.camera.up, before.camera.forward }, &.{ view.camera.position, view.camera.right, view.camera.up, view.camera.forward }) |expected, actual| {
        inline for (expected, 0..) |coord, i| {
            try std.testing.expectApproxEqAbs(coord, actual[i], 1e-6);
        }
    }
}

test "walk orientation roundtrips for curved views" {
    var hyper = try View.init(
        .hyperbolic,
        .{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -0.22 },
        .{ 0.0, 0.0, 0.0 },
    );
    hyper.syncHeadingPitch(0.6, 0.8, 0.35);
    const hyper_walk = hyper.walkOrientation().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), hyper_walk.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), hyper_walk.z_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), hyper_walk.pitch, 1e-3);

    var spherical = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(-0.8, 0.6, -0.25);
    const spherical_walk = spherical.walkOrientation().?;
    try std.testing.expectApproxEqAbs(@as(f32, -0.8), spherical_walk.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), spherical_walk.z_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), spherical_walk.pitch, 1e-3);
}

test "walk yaw preserves pitch while rotating heading" {
    var hyper = try View.init(
        .hyperbolic,
        .{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -0.22 },
        .{ 0.0, 0.0, 0.0 },
    );
    hyper.syncHeadingPitch(0.0, 1.0, 0.35);
    hyper.turnWalkYaw(0.25);

    const orientation = hyper.walkOrientation().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), orientation.pitch, 1e-3);
    try std.testing.expectApproxEqAbs(@sin(@as(f32, 0.25)), orientation.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 0.25)), orientation.z_heading, 1e-3);
}

test "spherical walk yaw stays recoverable near steep pitch" {
    var spherical = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(0.0, 1.0, 1.05);
    spherical.turnWalkYaw(0.35);

    const orientation = spherical.walkOrientation().?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), orientation.pitch, 1e-3);
    try std.testing.expectApproxEqAbs(@sin(@as(f32, 0.35)), orientation.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 0.35)), orientation.z_heading, 1e-3);
}

test "surface yaw keeps spherical walk surface up fixed" {
    var spherical = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(0.0, 1.0, 0.95);
    const before_up = spherical.walkSurfaceUp(0.95).?;
    const before_position = spherical.camera.position;
    spherical.turnSurfaceYaw(0.35, 0.95);
    const after_up = spherical.walkSurfaceUp(0.95).?;
    const orientation = spherical.walkOrientation().?;

    const up_dot = before_up[0] * after_up[0] +
        before_up[1] * after_up[1] +
        before_up[2] * after_up[2] +
        before_up[3] * after_up[3];
    const position_dot = before_position[0] * spherical.camera.position[0] +
        before_position[1] * spherical.camera.position[1] +
        before_position[2] * spherical.camera.position[2] +
        before_position[3] * spherical.camera.position[3];

    try std.testing.expect(up_dot > 0.999);
    try std.testing.expect(position_dot > 0.999);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), orientation.pitch, 1e-3);
}

test "surface pitch keeps spherical walk pitch tied to the surface normal" {
    var spherical = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(0.0, 1.0, 0.35);
    const before_up = spherical.walkSurfaceUp(0.35).?;
    spherical.syncSurfacePitch(1.05);
    const after_up = spherical.walkSurfaceUp(1.05).?;
    const orientation = spherical.walkOrientation().?;

    const up_dot = before_up[0] * after_up[0] +
        before_up[1] * after_up[1] +
        before_up[2] * after_up[2] +
        before_up[3] * after_up[3];
    try std.testing.expect(up_dot > 0.999);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), orientation.pitch, 1e-3);
}

test "spherical walk orientation survives forward transport" {
    var spherical = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(0.42, 0.9075241, 0.55);

    const before = spherical.walkOrientation().?;
    const forward = spherical.headingDirection(before.x_heading, before.z_heading).?;
    spherical.moveAlong(forward, 0.10);
    spherical.wrapSphericalChart();

    const after = spherical.walkOrientation().?;
    try std.testing.expectApproxEqAbs(before.pitch, after.pitch, 1e-3);
    try std.testing.expectApproxEqAbs(before.x_heading, after.x_heading, 1e-3);
    try std.testing.expectApproxEqAbs(before.z_heading, after.z_heading, 1e-3);
}

test "spherical chart wrap preserves the rendered view" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const before = view.sampleProjectedPoint(.{ 0.12, -0.07, 0.15 }, screen);
    try std.testing.expect(before.projected != null);

    view.camera.position = scale4(view.metric, view.camera.position, -1.0);
    view.camera.right = scale4(view.metric, view.camera.right, -1.0);
    view.camera.up = scale4(view.metric, view.camera.up, -1.0);
    view.camera.forward = scale4(view.metric, view.camera.forward, -1.0);
    view.wrapSphericalChart();

    const after = view.sampleProjectedPoint(.{ 0.12, -0.07, 0.15 }, screen);
    try std.testing.expect(after.projected != null);
    try std.testing.expectApproxEqAbs(before.distance, after.distance, 1e-4);
    try std.testing.expectApproxEqAbs(before.projected.?[0], after.projected.?[0], 1e-3);
    try std.testing.expectApproxEqAbs(before.projected.?[1], after.projected.?[1], 1e-3);
}

test "spherical stereographic view renders the far hemisphere via antipodal pass" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    const far_ambient = normalizeAmbient(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.position, -1.0),
            scale4(.spherical, view.camera.right, 0.18),
        ),
    );
    const far_chart = chartCoords(.spherical, view.params, far_ambient);

    const near_sample = view.sphericalRenderPass(.near).sampleProjectedPoint(far_chart, screen);
    try std.testing.expect(near_sample.status != .visible);

    const sample = view.sampleProjectedPoint(far_chart, screen);
    try std.testing.expectEqual(SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
    try std.testing.expect(sample.distance > hemisphereDistance(view.params));
}

test "spherical stereographic near pass uses the conformal camera model" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const ambient = normalizeAmbient(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.position, 0.84),
            scale4(.spherical, view.camera.forward, 0.41),
        ),
    );

    const model_point = modelPointForAmbientWithCamera(.spherical, view.camera, ambient, .conformal).?;
    const expected = projectConformalModelPoint(model_point, screen.width, screen.height, screen.zoom).?;
    const sample = view.sampleProjectedAmbientForSphericalPass(.near, ambient, screen);

    try std.testing.expectEqual(SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
    try std.testing.expectApproxEqAbs(expected[0], sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(expected[1], sample.projected.?[1], 1e-4);
}

test "spherical stereographic far pass uses the antipodal conformal camera model" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const ambient = normalizeAmbient(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.position, -0.84),
            scale4(.spherical, view.camera.right, 0.41),
        ),
    );

    const far_camera = antipodalSphericalPassCamera(view.camera);
    const model_point = modelPointForAmbientWithCamera(.spherical, far_camera, ambient, .conformal).?;
    const expected = projectConformalModelPoint(model_point, screen.width, screen.height, screen.zoom).?;
    const sample = view.sampleProjectedAmbientForSphericalPass(.far, ambient, screen);

    try std.testing.expectEqual(SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
    try std.testing.expectApproxEqAbs(expected[0], sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(expected[1], sample.projected.?[1], 1e-4);
}

test "spherical full-sphere stereographic sampling does not expose a pass far clip" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    const far_ambient = normalizeAmbient(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.position, -1.0),
            scale4(.spherical, view.camera.right, 0.12),
        ),
    );
    const far_chart = chartCoords(.spherical, view.params, far_ambient);
    const sample = view.sampleProjectedPoint(far_chart, screen);

    try std.testing.expectEqual(SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
}

test "spherical stereographic pass split follows viewing hemisphere rather than geodesic distance" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const behind_tangent = tryNormalizeTangent(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.forward, -0.93),
            scale4(.spherical, view.camera.right, 0.37),
        ),
    ).?;
    const distance = view.params.radius * 0.68;
    const theta = distance / view.params.radius;
    const ambient = normalizeAmbient(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.position, @cos(theta)),
            scale4(.spherical, behind_tangent, @sin(theta)),
        ),
    );

    try std.testing.expect(distance < hemisphereDistance(view.params));

    const near_pass = view.sampleProjectedAmbientForSphericalPass(.near, ambient, screen);
    try std.testing.expectEqual(SampleStatus.hidden, near_pass.status);

    const far_pass = view.sampleProjectedAmbientForSphericalPass(.far, ambient, screen);
    try std.testing.expectEqual(SampleStatus.visible, far_pass.status);
    try std.testing.expect(far_pass.projected != null);

    const combined = view.sampleProjectedAmbient(ambient, screen);
    try std.testing.expectEqual(SampleStatus.visible, combined.status);
    try std.testing.expect(combined.projected != null);
    try std.testing.expectApproxEqAbs(far_pass.distance, combined.distance, 1e-5);
    try std.testing.expectApproxEqAbs(far_pass.projected.?[0], combined.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(far_pass.projected.?[1], combined.projected.?[1], 1e-4);
}

test "spherical gnomonic view renders the far hemisphere via antipodal pass" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = 0.52 };

    const far_ambient = normalizeAmbient(
        .spherical,
        add4(
            .spherical,
            scale4(.spherical, view.camera.position, -1.0),
            scale4(.spherical, view.camera.right, 0.18),
        ),
    );

    const near_pass = view.sampleProjectedAmbientForSphericalPass(.near, far_ambient, screen);
    try std.testing.expect(near_pass.status != .visible);

    const far_pass = view.sampleProjectedAmbientForSphericalPass(.far, far_ambient, screen);
    try std.testing.expectEqual(SampleStatus.visible, far_pass.status);
    try std.testing.expect(far_pass.projected != null);

    const combined = view.sampleProjectedAmbient(far_ambient, screen);
    try std.testing.expectEqual(SampleStatus.visible, combined.status);
    try std.testing.expect(combined.projected != null);
    try std.testing.expect(combined.distance > hemisphereDistance(view.params));
}

test "spherical antipodal pass preserves screen up and right orientation" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    const far_up = chartCoords(
        .spherical,
        view.params,
        normalizeAmbient(
            .spherical,
            add4(
                .spherical,
                scale4(.spherical, view.camera.position, -1.0),
                scale4(.spherical, view.camera.up, 0.12),
            ),
        ),
    );
    const far_down = chartCoords(
        .spherical,
        view.params,
        normalizeAmbient(
            .spherical,
            add4(
                .spherical,
                scale4(.spherical, view.camera.position, -1.0),
                scale4(.spherical, view.camera.up, -0.12),
            ),
        ),
    );
    const far_right = chartCoords(
        .spherical,
        view.params,
        normalizeAmbient(
            .spherical,
            add4(
                .spherical,
                scale4(.spherical, view.camera.position, -1.0),
                scale4(.spherical, view.camera.right, 0.12),
            ),
        ),
    );
    const far_left = chartCoords(
        .spherical,
        view.params,
        normalizeAmbient(
            .spherical,
            add4(
                .spherical,
                scale4(.spherical, view.camera.position, -1.0),
                scale4(.spherical, view.camera.right, -0.12),
            ),
        ),
    );

    const up_sample = view.sampleProjectedPoint(far_up, screen);
    const down_sample = view.sampleProjectedPoint(far_down, screen);
    const right_sample = view.sampleProjectedPoint(far_right, screen);
    const left_sample = view.sampleProjectedPoint(far_left, screen);

    try std.testing.expectEqual(SampleStatus.visible, up_sample.status);
    try std.testing.expectEqual(SampleStatus.visible, down_sample.status);
    try std.testing.expectEqual(SampleStatus.visible, right_sample.status);
    try std.testing.expectEqual(SampleStatus.visible, left_sample.status);
    try std.testing.expect(up_sample.projected != null);
    try std.testing.expect(down_sample.projected != null);
    try std.testing.expect(right_sample.projected != null);
    try std.testing.expect(left_sample.projected != null);
    try std.testing.expect(up_sample.projected.?[1] < down_sample.projected.?[1]);
    try std.testing.expect(right_sample.projected.?[0] > left_sample.projected.?[0]);
}

test "spherical stereographic edge discontinuity is detected after steep transport" {
    var view = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    try std.testing.expect(!edgeHasProjectionBreak(view, .{ 0.82, 0.82, 0.82 }, .{ -0.82, -0.82, -0.82 }, screen, 64));

    view.syncHeadingPitch(0.0, 1.0, 1.0);
    const right = view.headingDirection(1.0, 0.0).?;
    view.moveAlong(right, -0.20);
    view.moveAlong(right, -0.20);
    view.wrapSphericalChart();

    try std.testing.expect(edgeHasProjectionBreak(view, .{ 0.82, -0.82, -0.82 }, .{ -0.82, -0.82, -0.82 }, screen, 64));
}

test "conformal chart roundtrips for hyperbolic and spherical spaces" {
    const hyper_params = Params{
        .radius = 0.32,
        .angular_zoom = 0.72,
        .chart_model = .conformal,
    };
    const hyper_chart = vec3(0.10, -0.04, 0.08);
    const hyper_roundtrip = chartCoords(.hyperbolic, hyper_params, embedPoint(.hyperbolic, hyper_params, hyper_chart).?);
    inline for (hyper_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, hyper_roundtrip[i], 1e-5);
    }

    const spherical_params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const spherical_chart = vec3(0.35, -0.12, 0.28);
    const spherical_roundtrip = chartCoords(.spherical, spherical_params, embedPoint(.spherical, spherical_params, spherical_chart).?);
    inline for (spherical_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, spherical_roundtrip[i], 1e-5);
    }
}

test "spherical local exponential map preserves distance from the origin" {
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, -0.22, 0.18);
    const ambient = sphericalAmbientFromLocalPoint(params, local);
    const local_distance = flatVector(local).magnitude();
    const spherical_distance = params.radius * std.math.acos(std.math.clamp(ambient[0], -1.0, 1.0));

    try std.testing.expectApproxEqAbs(local_distance, spherical_distance, 1e-5);
}

test "spherical ground-height mapping matches the radial map on horizontal and vertical axes" {
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };

    const horizontal = vec3(0.31, 0.0, -0.22);
    const horizontal_exp = sphericalAmbientFromLocalPoint(params, horizontal);
    const horizontal_ground = sphericalAmbientFromGroundHeightPoint(params, horizontal);
    inline for (horizontal_exp, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, horizontal_ground[i], 1e-5);
    }

    const vertical = vec3(0.0, 0.27, 0.0);
    const vertical_exp = sphericalAmbientFromLocalPoint(params, vertical);
    const vertical_ground = sphericalAmbientFromGroundHeightPoint(params, vertical);
    inline for (vertical_exp, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, vertical_ground[i], 1e-5);
    }
}

test "spherical ground-height mapping lifts from the wrapped footprint along local up" {
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, 0.27, -0.22);
    const base = ambientFromTangentBasisPoint(
        .spherical,
        params,
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
        vec3x(local),
        vec3z(local),
    ).?;
    const up = worldUpAt(.spherical, base).?;
    const ambient = sphericalAmbientFromGroundHeightPoint(params, local);
    const direction = geodesicDirection(.spherical, base, ambient).?;
    const height_distance = params.radius * std.math.acos(std.math.clamp(metricDot(.spherical, base, ambient), -1.0, 1.0));

    try std.testing.expectApproxEqAbs(vec3y(local), height_distance, 1e-5);
    try std.testing.expectApproxEqAbs(1.0, metricDot(.spherical, direction, up), 1e-5);
}

test "ambient from tangent basis point matches spherical horizontal ground mapping at the origin" {
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, 0.0, -0.22);
    const ambient = ambientFromTangentBasisPoint(
        .spherical,
        params,
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
        vec3x(local),
        vec3z(local),
    ).?;
    const expected = sphericalAmbientFromGroundHeightPoint(params, local);
    inline for (expected, 0..) |coord, i| {
        try std.testing.expectApproxEqAbs(coord, ambient[i], 1e-5);
    }
}

test "spherical direct ambient sampling respects scene sign after chart wrap" {
    var view = try View.init(
        .spherical,
        .{
            .radius = 1.48,
            .angular_zoom = 1.0,
            .chart_model = .conformal,
        },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 160, .height = 90, .zoom = 1.0 };
    const local = vec3(0.26, 0.18, 0.31);
    const ambient = sphericalAmbientFromLocalPoint(view.params, local);
    const chart = chartCoords(.spherical, view.params, ambient);

    var pos_before_wrap = view.camera.position;
    while (1.0 + view.camera.position[0] >= spherical_chart_min_denom) {
        pos_before_wrap = view.camera.position;
        view.moveAlong(view.camera.forward, 0.2);
    }
    view.wrapSphericalChart();
    // After wrap the camera position should have moved to the opposite chart
    // only once the current conformal denominator is near-singular.
    try std.testing.expect(1.0 + pos_before_wrap[0] < spherical_chart_min_denom);
    try std.testing.expect(view.camera.position[0] > 0.0);

    const chart_sample = view.sampleProjectedPoint(chart, screen);
    const ambient_sample = view.sampleProjectedAmbient(ambient, screen);

    try std.testing.expectEqual(chart_sample.status, ambient_sample.status);
    try std.testing.expectApproxEqAbs(chart_sample.distance, ambient_sample.distance, 1e-5);
    try std.testing.expect(chart_sample.projected != null);
    try std.testing.expect(ambient_sample.projected != null);
    try std.testing.expectApproxEqAbs(chart_sample.projected.?[0], ambient_sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(chart_sample.projected.?[1], ambient_sample.projected.?[1], 1e-4);
}

const std = @import("std");
const projection = @import("../render/projection.zig");
const curved_projection = @import("../render/curved_projection.zig");
const curved_ambient = @import("curved_ambient.zig");
const curved_camera = @import("curved_camera.zig");
const curved_charts = @import("curved_charts.zig");
const curved_sampling = @import("curved_sampling.zig");
const curved_surface = @import("curved_surface.zig");
const curved_tangent = @import("curved_tangent.zig");
const curved_types = @import("curved_types.zig");

pub const Metric = curved_types.Metric;
pub const Params = curved_types.Params;
pub const CameraModel = curved_types.CameraModel;
pub const DistanceClip = curved_types.DistanceClip;
pub const Screen = curved_types.Screen;
pub const WalkOrientation = curved_types.WalkOrientation;
pub const Sample = curved_types.Sample;
pub const SampleStatus = curved_types.SampleStatus;
pub const ProjectedSample = curved_types.ProjectedSample;
pub const AmbientFor = curved_types.AmbientFor;
pub const TypedCamera = curved_types.TypedCamera;
pub const TypedWalkBasis = curved_types.TypedWalkBasis;

pub const CameraError = curved_camera.CameraError;
pub const SphericalRenderPass = curved_sampling.SphericalRenderPass;

const spherical_chart_min_denom: f32 = 0.25;
const Flat3 = curved_types.Flat3;
const projectConformalModelPoint = curved_projection.projectConformalModelPoint;
const shouldBreakProjectionSegment = curved_projection.shouldBreakProjectedSegment;
const vec3 = curved_charts.vec3;
const flatLerp3 = curved_charts.flatLerp3;
const flatBilerpQuad = curved_charts.flatBilerpQuad;
const typedEmbedPoint = curved_charts.embedPoint;
const typedChartCoords = curved_charts.chartCoords;
const sphericalAmbientFromLocalPoint = curved_charts.sphericalAmbientFromLocalPoint;
const hemisphereDistance = curved_charts.hemisphereDistance;
const typedTryNormalizeTangent = curved_tangent.tryNormalizeTangent;
const typedNormalizeAmbient = curved_tangent.normalizeAmbient;
const typedWorldUpAt = curved_tangent.worldUpAt;
const sphericalAmbientFromGroundHeightPoint = curved_surface.sphericalAmbientFromGroundHeightPoint;
const ambientFromTypedTangentBasisPoint = curved_surface.ambientFromTypedTangentBasisPoint;
const typedGeodesicDirection = curved_camera.geodesicDirection;

pub fn TypedView(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    const CameraT = TypedCamera(metric);
    const WalkBasisT = TypedWalkBasis(metric);

    return struct {
        params: Params,
        projection: projection.DirectionProjection,
        clip: DistanceClip,
        camera: CameraT,
        scene_sign: f32,

        const Self = @This();

        pub fn init(
            params: Params,
            projection_mode: projection.DirectionProjection,
            clip: DistanceClip,
            eye_chart: anytype,
            target_chart: anytype,
        ) CameraError!Self {
            return .{
                .params = params,
                .projection = projection_mode,
                .clip = clip,
                .camera = try curved_camera.initCamera(metric, params, curved_charts.coerceVec3(eye_chart), curved_charts.coerceVec3(target_chart)),
                .scene_sign = 1.0,
            };
        }

        pub fn turnYaw(self: *Self, angle: f32) void {
            curved_camera.turnYaw(metric, &self.camera, angle);
        }

        pub fn turnWalkYaw(self: *Self, angle: f32) void {
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

        pub fn turnSurfaceYaw(self: *Self, angle: f32, pitch_angle: f32) void {
            curved_camera.turnSurfaceYaw(metric, &self.camera, angle, pitch_angle);
        }

        pub fn syncSurfacePitch(self: *Self, pitch_angle: f32) void {
            curved_camera.syncSurfacePitch(metric, &self.camera, pitch_angle);
        }

        pub fn turnPitch(self: *Self, angle: f32) void {
            curved_camera.turnPitch(metric, &self.camera, angle);
        }

        pub fn moveAlong(self: *Self, direction: Ambient.Vector, distance: f32) void {
            curved_camera.moveAlongDirection(metric, &self.camera, self.params, direction, distance);
        }

        pub fn moveForwardBy(self: *Self, distance: f32) void {
            curved_camera.moveAlongDirection(metric, &self.camera, self.params, self.camera.forward, distance);
        }

        pub fn moveRightBy(self: *Self, distance: f32) void {
            curved_camera.moveAlongDirection(metric, &self.camera, self.params, self.camera.right, distance);
        }

        pub fn headingDirection(self: Self, x_heading: f32, z_heading: f32) ?Ambient.Vector {
            return curved_camera.worldHeadingDirection(metric, self.camera, x_heading, z_heading);
        }

        pub fn walkOrientation(self: Self) ?WalkOrientation {
            return curved_camera.currentWalkOrientation(metric, self.camera);
        }

        pub fn walkBasis(self: Self) ?WalkBasisT {
            return curved_camera.walkBasis(metric, self.camera);
        }

        pub fn walkSurfaceUp(self: Self) ?Ambient.Vector {
            return curved_camera.worldUpDirection(metric, self.camera);
        }

        pub fn walkSurfaceBasis(self: Self, pitch_angle: f32) ?WalkBasisT {
            return curved_camera.walkSurfaceBasis(metric, self.camera, pitch_angle);
        }

        pub fn syncHeadingPitch(self: *Self, x_heading: f32, z_heading: f32, pitch_angle: f32) void {
            curved_camera.orientFromHeadingPitch(metric, &self.camera, x_heading, z_heading, pitch_angle);
        }

        pub fn wrapSphericalChart(self: *Self) void {
            if (metric != .spherical or self.params.chart_model != .conformal) return;
            if (Ambient.w(self.camera.position) + 1.0 >= spherical_chart_min_denom) return;

            self.camera.position = Ambient.scale(self.camera.position, -1.0);
            self.camera.forward = Ambient.scale(self.camera.forward, -1.0);
            curved_tangent.reorthonormalize(metric, &self.camera);
        }

        pub fn adjustRadius(self: *Self, radius: f32, look_ahead: f32) CameraError!void {
            if (radius <= 1e-6) return error.InvalidChartPoint;

            const next_params = Params{
                .radius = radius,
                .angular_zoom = self.params.angular_zoom,
                .chart_model = self.params.chart_model,
            };
            const eye_chart = curved_charts.chartCoords(metric, next_params, self.camera.position);
            var probe = self.camera;
            curved_camera.moveAlongDirection(metric, &probe, next_params, probe.forward, look_ahead);
            const target_chart = curved_charts.chartCoords(metric, next_params, probe.position);
            const next_camera = try curved_camera.initCamera(metric, next_params, eye_chart, target_chart);

            self.params = next_params;
            self.camera = next_camera;
        }

        pub fn shadeFarDistance(self: Self) f32 {
            return if (metric == .spherical) (@as(f32, std.math.pi) * self.params.radius) else self.clip.far;
        }

        pub fn embedPoint(self: Self, chart: anytype) ?Ambient.Vector {
            return curved_charts.embedPoint(metric, self.params, chart);
        }

        pub fn chartCoords(self: Self, ambient: Ambient.Vector) curved_types.Vec3 {
            return curved_charts.chartCoords(metric, self.params, ambient);
        }

        pub fn geodesicChartPoint(self: Self, a_chart: anytype, b_chart: anytype, t: f32) ?curved_types.Vec3 {
            const a = self.embedPoint(a_chart) orelse return null;
            const b = self.embedPoint(b_chart) orelse return null;
            const ambient = curved_charts.geodesicAmbientPoint(metric, a, b, t) orelse return null;
            return self.chartCoords(ambient);
        }

        pub fn sceneAmbientPoint(self: Self, chart: anytype) ?Ambient.Vector {
            const ambient = curved_charts.embedPoint(metric, self.params, chart) orelse return null;
            return self.signedAmbient(ambient);
        }

        pub fn signedAmbient(self: Self, ambient_input: Ambient.Vector) Ambient.Vector {
            return if (metric == .spherical and self.scene_sign < 0.0)
                Ambient.scale(ambient_input, -1.0)
            else
                ambient_input;
        }

        pub fn sampleProjectedPoint(self: Self, chart: anytype, screen: Screen) ProjectedSample {
            const ambient = self.sceneAmbientPoint(chart) orelse return .{};
            return curved_sampling.sampleProjectedAmbientPoint(
                metric,
                self.params,
                self.projection,
                self.clip,
                self.camera,
                ambient,
                screen,
            );
        }

        pub fn sampleAmbient(self: Self, ambient_input: Ambient.Vector) ?Sample {
            return curved_sampling.sampleAmbientPoint(metric, self.params, self.camera, self.signedAmbient(ambient_input));
        }

        pub fn samplePoint(self: Self, chart: anytype) ?Sample {
            const ambient = self.sceneAmbientPoint(chart) orelse return null;
            return curved_sampling.sampleAmbientPoint(metric, self.params, self.camera, ambient);
        }

        pub fn sampleProjectedAmbient(self: Self, ambient_input: Ambient.Vector, screen: Screen) ProjectedSample {
            return curved_sampling.sampleProjectedAmbientPoint(
                metric,
                self.params,
                self.projection,
                self.clip,
                self.camera,
                self.signedAmbient(ambient_input),
                screen,
            );
        }

        pub fn sampleProjectedPointForSphericalPass(self: Self, pass: SphericalRenderPass, chart: anytype, screen: Screen) ProjectedSample {
            const ambient = self.sceneAmbientPoint(chart) orelse return .{};
            return self.sampleProjectedAmbientForSphericalPass(pass, ambient, screen);
        }

        pub fn sampleProjectedAmbientForSphericalPass(
            self: Self,
            pass: SphericalRenderPass,
            ambient_input: Ambient.Vector,
            screen: Screen,
        ) ProjectedSample {
            std.debug.assert(metric == .spherical);
            std.debug.assert(curved_sampling.sphericalUsesMultipass(self.projection));

            return curved_sampling.sampleProjectedAmbientPointForPass(
                metric,
                self.params,
                self.projection,
                self.clip,
                self.camera,
                pass,
                self.signedAmbient(ambient_input),
                screen,
            );
        }

        pub fn sampleProjectedAmbientForSphericalPassRaw(
            self: Self,
            pass: SphericalRenderPass,
            ambient_input: Ambient.Vector,
            screen: Screen,
        ) ProjectedSample {
            std.debug.assert(metric == .spherical);
            std.debug.assert(curved_sampling.sphericalUsesMultipass(self.projection));

            return curved_sampling.sampleProjectedAmbientPointForPassRaw(
                metric,
                self.params,
                self.projection,
                self.clip,
                self.camera,
                pass,
                self.signedAmbient(ambient_input),
                screen,
            );
        }

        pub fn sphericalSelectedPassForAmbient(self: Self, ambient_input: Ambient.Vector) ?SphericalRenderPass {
            std.debug.assert(metric == .spherical);
            std.debug.assert(curved_sampling.sphericalUsesMultipass(self.projection));

            return curved_sampling.sphericalSelectedPassForAmbient(
                metric,
                self.params,
                self.camera,
                self.signedAmbient(ambient_input),
            );
        }

        pub fn sphericalRenderPass(self: Self, pass: SphericalRenderPass) Self {
            std.debug.assert(metric == .spherical);
            std.debug.assert(curved_sampling.sphericalUsesMultipass(self.projection));

            var render_view = self;
            render_view.clip = .{
                .near = if (pass == .near) self.clip.near else 0.0,
                .far = curved_charts.hemisphereDistance(self.params),
            };

            if (pass == .far) {
                render_view.camera = .{
                    .position = Ambient.scale(render_view.camera.position, -1.0),
                    .right = render_view.camera.right,
                    .up = render_view.camera.up,
                    .forward = Ambient.scale(render_view.camera.forward, -1.0),
                };
            }
            return render_view;
        }

        pub fn mapSphericalRenderDistance(self: Self, pass: SphericalRenderPass, pass_distance: f32) f32 {
            std.debug.assert(metric == .spherical);
            return switch (pass) {
                .near => pass_distance,
                .far => curved_charts.maxSphericalDistance(self.params) - pass_distance,
            };
        }

        pub fn cameraModelPointForAmbient(self: Self, ambient_input: Ambient.Vector, model: CameraModel) ?curved_types.Vec3 {
            return curved_sampling.modelPointForTypedAmbientWithCamera(
                metric,
                self.camera,
                self.signedAmbient(ambient_input),
                model,
            );
        }

        pub fn cameraModelPoint(self: Self, chart: anytype, model: CameraModel) ?curved_types.Vec3 {
            const ambient = self.sceneAmbientPoint(chart) orelse return null;
            return self.cameraModelPointForAmbient(ambient, model);
        }

        pub fn projectPoint(self: Self, chart: curved_types.Vec3, canvas_width: usize, canvas_height: usize) ?[2]f32 {
            const sample = self.samplePoint(chart) orelse return null;
            return projection.projectDirectionWith(
                self.projection,
                sample.x_dir,
                sample.y_dir,
                sample.z_dir,
                canvas_width,
                canvas_height,
                self.params.angular_zoom,
            );
        }
    };
}

pub const HyperView = TypedView(.hyperbolic);
pub const EllipticView = TypedView(.elliptic);
pub const SphericalView = TypedView(.spherical);

fn flatVector(point: curved_types.Vec3) Flat3.Vector {
    return point;
}

fn edgeHasProjectionBreak(view: anytype, a_chart: curved_types.Vec3, b_chart: curved_types.Vec3, screen: Screen, steps: usize) bool {
    var prev_point: ?[2]f32 = null;
    const projection_mode = view.projection;

    for (0..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const point = view.geodesicChartPoint(a_chart, b_chart, t) orelse continue;
        const sample = view.sampleProjectedPoint(point, screen);
        if (sample.status != .visible or sample.projected == null) {
            prev_point = null;
            continue;
        }

        if (prev_point) |pp| {
            if (shouldBreakProjectionSegment(projection_mode, pp, sample.projected.?, screen.width, screen.height)) {
                return true;
            }
        }

        prev_point = sample.projected;
    }

    return false;
}

test "hyperbolic and spherical views initialize and sample" {
    var hyper = try HyperView.init(
        .{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -0.22 },
        .{ 0.0, 0.0, 0.0 },
    );
    const hyper_sample = hyper.sampleProjectedPoint(.{ 0.05, 0.02, 0.01 }, .{ .width = 80, .height = 40, .zoom = hyper.params.angular_zoom });
    try std.testing.expect(hyper_sample.status != .hidden);

    var spherical = try SphericalView.init(
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
    const a_round = curved_ambient.Round.fromCoords(.{ 1.0, 2.0, 3.0, 4.0 });
    const b_round = curved_ambient.Round.fromCoords(.{ 0.5, -1.0, 2.0, -0.25 });
    const a_hyper = curved_ambient.Hyper.fromCoords(.{ 1.0, 2.0, 3.0, 4.0 });
    const b_hyper = curved_ambient.Hyper.fromCoords(.{ 0.5, -1.0, 2.0, -0.25 });

    const spherical_sum = curved_ambient.Round.toCoords(curved_ambient.Round.add(a_round, b_round));
    try std.testing.expectApproxEqAbs(1.5, spherical_sum[0], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, spherical_sum[1], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, spherical_sum[2], 1e-6);
    try std.testing.expectApproxEqAbs(3.75, spherical_sum[3], 1e-6);

    const hyper_diff = curved_ambient.Hyper.toCoords(curved_ambient.Hyper.sub(a_hyper, b_hyper));
    try std.testing.expectApproxEqAbs(0.5, hyper_diff[0], 1e-6);
    try std.testing.expectApproxEqAbs(3.0, hyper_diff[1], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, hyper_diff[2], 1e-6);
    try std.testing.expectApproxEqAbs(4.25, hyper_diff[3], 1e-6);

    const scaled = curved_ambient.Round.toCoords(curved_ambient.Round.scale(a_round, 0.25));
    try std.testing.expectApproxEqAbs(0.25, scaled[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.5, scaled[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.75, scaled[2], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, scaled[3], 1e-6);

    try std.testing.expectApproxEqAbs(3.5, curved_ambient.Round.dot(a_round, b_round), 1e-6);
    try std.testing.expectApproxEqAbs(2.5, curved_ambient.Hyper.dot(a_hyper, b_hyper), 1e-6);

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

test "typed hyperbolic view uses GA ambient vector carriers" {
    var view = try HyperView.init(
        .{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -0.22 },
        .{ 0.0, 0.0, 0.0 },
    );
    view.syncHeadingPitch(0.0, 1.0, 0.35);

    try std.testing.expect(@TypeOf(view.camera.position) == curved_ambient.Hyper.Vector);
    try std.testing.expect(@TypeOf(view.camera.forward) == curved_ambient.Hyper.Vector);
    try std.testing.expect(view.walkSurfaceUp() != null);
}

test "adjustRadius preserves a valid camera" {
    var view = try SphericalView.init(
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
    var view = try SphericalView.init(
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
    var hyper = try HyperView.init(
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

    var spherical = try SphericalView.init(
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
    var hyper = try HyperView.init(
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
    var spherical = try SphericalView.init(
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
    var spherical = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(0.0, 1.0, 0.95);
    const before_up = spherical.walkSurfaceUp().?;
    const before_position = spherical.camera.position;
    spherical.turnSurfaceYaw(0.35, 0.95);
    const after_up = spherical.walkSurfaceUp().?;
    const orientation = spherical.walkOrientation().?;

    const up_dot = curved_ambient.Round.dot(before_up, after_up);
    const position_dot = curved_ambient.Round.dot(before_position, spherical.camera.position);

    try std.testing.expect(up_dot > 0.999);
    try std.testing.expect(position_dot > 0.999);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), orientation.pitch, 1e-3);
}

test "surface pitch keeps spherical walk pitch tied to the surface normal" {
    var spherical = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    spherical.syncHeadingPitch(0.0, 1.0, 0.35);
    const before_up = spherical.walkSurfaceUp().?;
    spherical.syncSurfacePitch(1.05);
    const after_up = spherical.walkSurfaceUp().?;
    const orientation = spherical.walkOrientation().?;

    const up_dot = curved_ambient.Round.dot(before_up, after_up);
    try std.testing.expect(up_dot > 0.999);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), orientation.pitch, 1e-3);
}

test "tangent normalization rejects non-finite inputs" {
    const nan = std.math.nan(f32);
    try std.testing.expect(typedTryNormalizeTangent(.spherical, curved_ambient.Round.fromCoords(.{ nan, 0.0, 0.0, 0.0 })) == null);
    try std.testing.expect(typedTryNormalizeTangent(.hyperbolic, curved_ambient.Hyper.fromCoords(.{ 1.0, nan, 0.0, 0.0 })) == null);
}

test "ambient normalization falls back to the model identity on non-finite input" {
    const nan = std.math.nan(f32);
    const hyper = curved_ambient.Hyper.toCoords(typedNormalizeAmbient(.hyperbolic, curved_ambient.Hyper.fromCoords(.{ nan, 0.0, 0.0, 0.0 })));
    const round = curved_ambient.Round.toCoords(typedNormalizeAmbient(.spherical, curved_ambient.Round.fromCoords(.{ 0.0, nan, 0.0, 0.0 })));

    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0 }, &hyper);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0 }, &round);
}

test "ambient tangent-basis point builder rejects non-finite travel inputs" {
    const nan = std.math.nan(f32);
    const origin = curved_ambient.Round.fromCoords(.{ 1.0, 0.0, 0.0, 0.0 });
    const right = curved_ambient.Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 });
    const forward = curved_ambient.Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 });

    const point = ambientFromTypedTangentBasisPoint(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        origin,
        right,
        forward,
        nan,
        0.25,
    ).?;

    try std.testing.expectEqualSlices(f32, &curved_ambient.Round.toCoords(origin), &curved_ambient.Round.toCoords(point));
}

test "spherical walk orientation survives forward transport" {
    var spherical = try SphericalView.init(
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
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const before = view.sampleProjectedPoint(.{ 0.12, -0.07, 0.15 }, screen);
    try std.testing.expect(before.projected != null);

    view.camera.position = view.camera.position.scale(-1.0);
    view.camera.right = view.camera.right.scale(-1.0);
    view.camera.up = view.camera.up.scale(-1.0);
    view.camera.forward = view.camera.forward.scale(-1.0);
    view.wrapSphericalChart();

    const after = view.sampleProjectedPoint(.{ 0.12, -0.07, 0.15 }, screen);
    try std.testing.expect(after.projected != null);
    try std.testing.expectApproxEqAbs(before.distance, after.distance, 1e-4);
    try std.testing.expectApproxEqAbs(before.projected.?[0], after.projected.?[0], 1e-3);
    try std.testing.expectApproxEqAbs(before.projected.?[1], after.projected.?[1], 1e-3);
}

test "spherical stereographic view renders the far hemisphere via antipodal pass" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    const far_ambient = typedNormalizeAmbient(
        .spherical,
        view.camera.position.scale(-1.0).add(view.camera.right.scale(0.18)),
    );
    const far_chart = view.chartCoords(far_ambient);

    const near_sample = view.sphericalRenderPass(.near).sampleProjectedPoint(far_chart, screen);
    try std.testing.expect(near_sample.status != .visible);

    const sample = view.sampleProjectedPoint(far_chart, screen);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
    try std.testing.expect(sample.distance > hemisphereDistance(view.params));
}

test "spherical stereographic near pass uses the conformal camera model" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const ambient = typedNormalizeAmbient(
        .spherical,
        view.camera.position.scale(0.84).add(view.camera.forward.scale(0.41)),
    );

    const model_point = view.sphericalRenderPass(.near).cameraModelPointForAmbient(ambient, .conformal).?;
    const expected = projectConformalModelPoint(model_point, screen.width, screen.height, screen.zoom).?;
    const sample = view.sampleProjectedAmbientForSphericalPass(.near, ambient, screen);

    try std.testing.expectEqual(curved_types.SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
    try std.testing.expectApproxEqAbs(expected[0], sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(expected[1], sample.projected.?[1], 1e-4);
}

test "spherical stereographic far pass uses the antipodal conformal camera model" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const ambient = typedNormalizeAmbient(
        .spherical,
        view.camera.position.scale(-0.84).add(view.camera.right.scale(0.41)),
    );

    const model_point = view.sphericalRenderPass(.far).cameraModelPointForAmbient(ambient, .conformal).?;
    const expected = projectConformalModelPoint(model_point, screen.width, screen.height, screen.zoom).?;
    const sample = view.sampleProjectedAmbientForSphericalPass(.far, ambient, screen);

    try std.testing.expectEqual(curved_types.SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
    try std.testing.expectApproxEqAbs(expected[0], sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(expected[1], sample.projected.?[1], 1e-4);
}

test "spherical full-sphere stereographic sampling does not expose a pass far clip" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    const far_ambient = typedNormalizeAmbient(
        .spherical,
        view.camera.position.scale(-1.0).add(view.camera.right.scale(0.12)),
    );
    const far_chart = view.chartCoords(far_ambient);
    const sample = view.sampleProjectedPoint(far_chart, screen);

    try std.testing.expectEqual(curved_types.SampleStatus.visible, sample.status);
    try std.testing.expect(sample.projected != null);
}

test "spherical stereographic pass split follows viewing hemisphere rather than geodesic distance" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };
    const behind_tangent = typedTryNormalizeTangent(
        .spherical,
        view.camera.forward.scale(-0.93).add(view.camera.right.scale(0.37)),
    ).?;
    const distance = view.params.radius * 0.68;
    const theta = distance / view.params.radius;
    const ambient = typedNormalizeAmbient(
        .spherical,
        view.camera.position.scale(@cos(theta)).add(behind_tangent.scale(@sin(theta))),
    );

    try std.testing.expect(distance < hemisphereDistance(view.params));

    const near_pass = view.sampleProjectedAmbientForSphericalPass(.near, ambient, screen);
    try std.testing.expectEqual(curved_types.SampleStatus.hidden, near_pass.status);

    const far_pass = view.sampleProjectedAmbientForSphericalPass(.far, ambient, screen);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, far_pass.status);
    try std.testing.expect(far_pass.projected != null);

    const combined = view.sampleProjectedAmbient(ambient, screen);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, combined.status);
    try std.testing.expect(combined.projected != null);
    try std.testing.expectApproxEqAbs(far_pass.distance, combined.distance, 1e-5);
    try std.testing.expectApproxEqAbs(far_pass.projected.?[0], combined.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(far_pass.projected.?[1], combined.projected.?[1], 1e-4);
}

test "spherical gnomonic view renders the far hemisphere via antipodal pass" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .gnomonic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = 0.52 };

    const far_ambient = typedNormalizeAmbient(
        .spherical,
        view.camera.position.scale(-1.0).add(view.camera.right.scale(0.18)),
    );

    const near_pass = view.sampleProjectedAmbientForSphericalPass(.near, far_ambient, screen);
    try std.testing.expect(near_pass.status != .visible);

    const far_pass = view.sampleProjectedAmbientForSphericalPass(.far, far_ambient, screen);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, far_pass.status);
    try std.testing.expect(far_pass.projected != null);

    const combined = view.sampleProjectedAmbient(far_ambient, screen);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, combined.status);
    try std.testing.expect(combined.projected != null);
    try std.testing.expect(combined.distance > hemisphereDistance(view.params));
}

test "spherical antipodal pass preserves screen up and right orientation" {
    var view = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const screen = Screen{ .width = 80, .height = 40, .zoom = view.params.angular_zoom };

    const far_up = view.chartCoords(typedNormalizeAmbient(.spherical, view.camera.position.scale(-1.0).add(view.camera.up.scale(0.12))));
    const far_down = view.chartCoords(typedNormalizeAmbient(.spherical, view.camera.position.scale(-1.0).add(view.camera.up.scale(-0.12))));
    const far_right = view.chartCoords(typedNormalizeAmbient(.spherical, view.camera.position.scale(-1.0).add(view.camera.right.scale(0.12))));
    const far_left = view.chartCoords(typedNormalizeAmbient(.spherical, view.camera.position.scale(-1.0).add(view.camera.right.scale(-0.12))));

    const up_sample = view.sampleProjectedPoint(far_up, screen);
    const down_sample = view.sampleProjectedPoint(far_down, screen);
    const right_sample = view.sampleProjectedPoint(far_right, screen);
    const left_sample = view.sampleProjectedPoint(far_left, screen);

    try std.testing.expectEqual(curved_types.SampleStatus.visible, up_sample.status);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, down_sample.status);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, right_sample.status);
    try std.testing.expectEqual(curved_types.SampleStatus.visible, left_sample.status);
    try std.testing.expect(up_sample.projected != null);
    try std.testing.expect(down_sample.projected != null);
    try std.testing.expect(right_sample.projected != null);
    try std.testing.expect(left_sample.projected != null);
    try std.testing.expect(up_sample.projected.?[1] < down_sample.projected.?[1]);
    try std.testing.expect(right_sample.projected.?[0] > left_sample.projected.?[0]);
}

test "spherical stereographic edge discontinuity is detected after steep transport" {
    var view = try SphericalView.init(
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
    const hyper_roundtrip = typedChartCoords(.hyperbolic, hyper_params, typedEmbedPoint(.hyperbolic, hyper_params, hyper_chart).?);
    inline for (hyper_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, hyper_roundtrip[i], 1e-5);
    }

    const spherical_params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const spherical_chart = vec3(0.35, -0.12, 0.28);
    const spherical_roundtrip = typedChartCoords(.spherical, spherical_params, typedEmbedPoint(.spherical, spherical_params, spherical_chart).?);
    inline for (spherical_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, spherical_roundtrip[i], 1e-5);
    }
}

test "spherical local exponential map preserves distance from the origin" {
    const Round = AmbientFor(.spherical);
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, -0.22, 0.18);
    const ambient = sphericalAmbientFromLocalPoint(params, local);
    const local_distance = flatVector(local).magnitude();
    const spherical_distance = params.radius * std.math.acos(std.math.clamp(Round.w(ambient), -1.0, 1.0));

    try std.testing.expectApproxEqAbs(local_distance, spherical_distance, 1e-5);
}

test "spherical ground-height mapping matches the radial map on horizontal and vertical axes" {
    const Round = AmbientFor(.spherical);
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };

    const horizontal = vec3(0.31, 0.0, -0.22);
    const horizontal_exp = sphericalAmbientFromLocalPoint(params, horizontal);
    const horizontal_ground = sphericalAmbientFromGroundHeightPoint(params, horizontal);
    inline for (Round.toCoords(horizontal_exp), Round.toCoords(horizontal_ground)) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-5);
    }

    const vertical = vec3(0.0, 0.27, 0.0);
    const vertical_exp = sphericalAmbientFromLocalPoint(params, vertical);
    const vertical_ground = sphericalAmbientFromGroundHeightPoint(params, vertical);
    inline for (Round.toCoords(vertical_exp), Round.toCoords(vertical_ground)) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-5);
    }
}

test "spherical ground-height mapping lifts from the wrapped footprint along local up" {
    const Round = AmbientFor(.spherical);
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, 0.27, -0.22);
    const base = ambientFromTypedTangentBasisPoint(
        .spherical,
        params,
        Round.identity(),
        Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
        local[0],
        local[2],
    ).?;
    const up = typedWorldUpAt(.spherical, base).?;
    const ambient = sphericalAmbientFromGroundHeightPoint(params, local);
    const direction = typedGeodesicDirection(.spherical, base, ambient).?;
    const height_distance = params.radius * std.math.acos(std.math.clamp(Round.dot(base, ambient), -1.0, 1.0));

    try std.testing.expectApproxEqAbs(local[1], height_distance, 1e-5);
    try std.testing.expectApproxEqAbs(1.0, Round.dot(direction, up), 1e-5);
}

test "ambient from tangent basis point matches spherical horizontal ground mapping at the origin" {
    const Round = AmbientFor(.spherical);
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, 0.0, -0.22);
    const ambient = ambientFromTypedTangentBasisPoint(
        .spherical,
        params,
        Round.identity(),
        Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
        local[0],
        local[2],
    ).?;
    const expected = sphericalAmbientFromGroundHeightPoint(params, local);
    inline for (AmbientFor(.spherical).toCoords(expected), AmbientFor(.spherical).toCoords(ambient)) |coord, actual| {
        try std.testing.expectApproxEqAbs(coord, actual, 1e-5);
    }
}

test "spherical direct ambient sampling respects scene sign after chart wrap" {
    const Round = AmbientFor(.spherical);
    var view = try SphericalView.init(
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
    const chart = view.chartCoords(ambient);

    var pos_before_wrap = view.camera.position;
    while (1.0 + Round.w(view.camera.position) >= spherical_chart_min_denom) {
        pos_before_wrap = view.camera.position;
        view.moveAlong(view.camera.forward, 0.2);
    }
    view.wrapSphericalChart();
    try std.testing.expect(1.0 + Round.w(pos_before_wrap) < spherical_chart_min_denom);
    try std.testing.expect(Round.w(view.camera.position) > 0.0);

    const chart_sample = view.sampleProjectedPoint(chart, screen);
    const ambient_sample = view.sampleProjectedAmbient(ambient, screen);

    try std.testing.expectEqual(chart_sample.status, ambient_sample.status);
    try std.testing.expectApproxEqAbs(chart_sample.distance, ambient_sample.distance, 1e-5);
    try std.testing.expect(chart_sample.projected != null);
    try std.testing.expect(ambient_sample.projected != null);
    try std.testing.expectApproxEqAbs(chart_sample.projected.?[0], ambient_sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(chart_sample.projected.?[1], ambient_sample.projected.?[1], 1e-4);
}

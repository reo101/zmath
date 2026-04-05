const std = @import("std");
const projection = @import("../render/projection.zig");
const curved_projection = @import("../render/curved_projection.zig");
const curved_ambient = @import("curved_ambient.zig");
const curved_charts = @import("curved_charts.zig");
const curved_sampling = @import("curved_sampling.zig");
const curved_surface = @import("curved_surface.zig");
const curved_tangent = @import("curved_tangent.zig");
const curved_types = @import("curved_types.zig");

pub const Metric = curved_types.Metric;
pub const ChartModel = curved_types.ChartModel;
pub const Params = curved_types.Params;
pub const CameraModel = curved_types.CameraModel;
pub const DistanceClip = curved_types.DistanceClip;
pub const Screen = curved_types.Screen;
pub const WalkOrientation = curved_types.WalkOrientation;
pub const Sample = curved_types.Sample;
pub const SampleStatus = curved_types.SampleStatus;

const RelativeCoords = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,
};

pub const ProjectedSample = curved_types.ProjectedSample;

pub const CameraError = error{
    InvalidChartPoint,
    DegenerateDirection,
};

const Flat3 = curved_types.Flat3;

pub const Vec3 = curved_types.Vec3;
pub const projectSample = curved_projection.projectSample;
pub const shouldBreakProjectedSegment = curved_projection.shouldBreakProjectedSegment;

const projectConformalModelPoint = curved_projection.projectConformalModelPoint;
const sampleStatus = curved_projection.sampleStatus;
const shouldBreakProjectionSegment = curved_projection.shouldBreakProjectionSegment;
const sphericalUsesMultipass = curved_sampling.sphericalUsesMultipass;

pub const AmbientFor = curved_types.AmbientFor;
pub const TypedCamera = curved_types.TypedCamera;
pub const TypedWalkBasis = curved_types.TypedWalkBasis;
pub const vec3 = curved_charts.vec3;
pub const vec3x = curved_charts.vec3x;
pub const vec3y = curved_charts.vec3y;
pub const vec3z = curved_charts.vec3z;
pub const vec3Coords = curved_charts.vec3Coords;
pub const flatLerp3 = curved_charts.flatLerp3;
pub const flatBilerpQuad = curved_charts.flatBilerpQuad;
pub const chartCoordsTyped = curved_charts.chartCoords;
pub const sphericalAmbientFromLocalPoint = curved_charts.sphericalAmbientFromLocalPoint;
pub const sphericalAmbientFromGroundHeightPoint = curved_surface.sphericalAmbientFromGroundHeightPoint;
pub const ambientFromTypedTangentBasisPoint = curved_surface.ambientFromTypedTangentBasisPoint;

const coerceVec3 = curved_charts.coerceVec3;
const typedEmbedPoint = curved_charts.embedPoint;
const typedChartCoords = curved_charts.chartCoords;
const typedGeodesicAmbientPoint = curved_charts.geodesicAmbientPoint;
const maxSphericalDistance = curved_charts.maxSphericalDistance;
const hemisphereDistance = curved_charts.hemisphereDistance;
const typedZero = curved_tangent.zero;
const typedBasisVector = curved_tangent.basisVector;
const typedTryNormalizeTangent = curved_tangent.tryNormalizeTangent;
const typedProjectToTangent = curved_tangent.projectToTangent;
const typedOrthonormalCandidate = curved_tangent.orthonormalCandidate;
const typedReorthonormalize = curved_tangent.reorthonormalize;
const typedNormalizeAmbient = curved_tangent.normalizeAmbient;
const typedWorldUpAt = curved_tangent.worldUpAt;

fn TypedHeadingBasis(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        east: Ambient.Vector,
        north: Ambient.Vector,
        up: Ambient.Vector,
    };
}

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
                .camera = try typedInitCamera(metric, params, coerceVec3(eye_chart), coerceVec3(target_chart)),
                .scene_sign = 1.0,
            };
        }

        pub fn turnYaw(self: *Self, angle: f32) void {
            typedYaw(metric, &self.camera, angle);
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
            typedTurnSurfaceYaw(metric, &self.camera, angle, pitch_angle);
        }

        pub fn syncSurfacePitch(self: *Self, pitch_angle: f32) void {
            typedSyncSurfacePitch(metric, &self.camera, pitch_angle);
        }

        pub fn turnPitch(self: *Self, angle: f32) void {
            typedPitch(metric, &self.camera, angle);
        }

        pub fn moveAlong(self: *Self, direction: Ambient.Vector, distance: f32) void {
            typedMoveAlongDirection(metric, &self.camera, self.params, direction, distance);
        }

        pub fn moveForwardBy(self: *Self, distance: f32) void {
            typedMoveAlongDirection(metric, &self.camera, self.params, self.camera.forward, distance);
        }

        pub fn moveRightBy(self: *Self, distance: f32) void {
            typedMoveAlongDirection(metric, &self.camera, self.params, self.camera.right, distance);
        }

        pub fn headingDirection(self: Self, x_heading: f32, z_heading: f32) ?Ambient.Vector {
            return typedWorldHeadingDirection(metric, self.camera, x_heading, z_heading);
        }

        pub fn walkOrientation(self: Self) ?WalkOrientation {
            return typedCurrentWalkOrientation(metric, self.camera);
        }

        pub fn walkBasis(self: Self) ?WalkBasisT {
            return typedWalkBasis(metric, self.camera);
        }

        pub fn walkSurfaceUp(self: Self) ?Ambient.Vector {
            return typedWorldUpDirection(metric, self.camera);
        }

        pub fn walkSurfaceBasis(self: Self, pitch_angle: f32) ?WalkBasisT {
            return typedWalkSurfaceBasis(metric, self.camera, pitch_angle);
        }

        pub fn syncHeadingPitch(self: *Self, x_heading: f32, z_heading: f32, pitch_angle: f32) void {
            typedOrientFromHeadingPitch(metric, &self.camera, x_heading, z_heading, pitch_angle);
        }

        pub fn wrapSphericalChart(self: *Self) void {
            if (metric != .spherical or self.params.chart_model != .conformal) return;
            if (Ambient.w(self.camera.position) + 1.0 >= spherical_chart_min_denom) return;

            self.camera.position = Ambient.scale(self.camera.position, -1.0);
            self.camera.forward = Ambient.scale(self.camera.forward, -1.0);
            typedReorthonormalize(metric, &self.camera);
        }

        pub fn adjustRadius(self: *Self, radius: f32, look_ahead: f32) CameraError!void {
            if (radius <= 1e-6) return error.InvalidChartPoint;

            const next_params = Params{
                .radius = radius,
                .angular_zoom = self.params.angular_zoom,
                .chart_model = self.params.chart_model,
            };
            const eye_chart = typedChartCoords(metric, next_params, self.camera.position);
            var probe = self.camera;
            typedMoveAlongDirection(metric, &probe, next_params, probe.forward, look_ahead);
            const target_chart = typedChartCoords(metric, next_params, probe.position);
            const next_camera = try typedInitCamera(metric, next_params, eye_chart, target_chart);

            self.params = next_params;
            self.camera = next_camera;
        }

        pub fn shadeFarDistance(self: Self) f32 {
            return if (metric == .spherical) (@as(f32, std.math.pi) * self.params.radius) else self.clip.far;
        }

        pub fn embedPoint(self: Self, chart: anytype) ?Ambient.Vector {
            return typedEmbedPoint(metric, self.params, chart);
        }

        pub fn chartCoords(self: Self, ambient: Ambient.Vector) Vec3 {
            return typedChartCoords(metric, self.params, ambient);
        }

        pub fn geodesicChartPoint(self: Self, a_chart: anytype, b_chart: anytype, t: f32) ?Vec3 {
            const a = self.embedPoint(a_chart) orelse return null;
            const b = self.embedPoint(b_chart) orelse return null;
            const ambient = typedGeodesicAmbientPoint(metric, a, b, t) orelse return null;
            return self.chartCoords(ambient);
        }

        pub fn sceneAmbientPoint(self: Self, chart: anytype) ?Ambient.Vector {
            const ambient = typedEmbedPoint(metric, self.params, chart) orelse return null;
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
            std.debug.assert(sphericalUsesMultipass(self.projection));

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
            std.debug.assert(sphericalUsesMultipass(self.projection));

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
            std.debug.assert(sphericalUsesMultipass(self.projection));

            return curved_sampling.sphericalSelectedPassForAmbient(
                metric,
                self.params,
                self.camera,
                self.signedAmbient(ambient_input),
            );
        }

        pub fn sphericalRenderPass(self: Self, pass: SphericalRenderPass) Self {
            std.debug.assert(metric == .spherical);
            std.debug.assert(sphericalUsesMultipass(self.projection));

            var render_view = self;
            render_view.clip = .{
                .near = if (pass == .near) self.clip.near else 0.0,
                .far = hemisphereDistance(self.params),
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
                .far => maxSphericalDistance(self.params) - pass_distance,
            };
        }

        pub fn cameraModelPointForAmbient(self: Self, ambient_input: Ambient.Vector, model: CameraModel) ?Vec3 {
            return curved_sampling.modelPointForTypedAmbientWithCamera(
                metric,
                self.camera,
                self.signedAmbient(ambient_input),
                model,
            );
        }

        pub fn cameraModelPoint(self: Self, chart: anytype, model: CameraModel) ?Vec3 {
            const ambient = self.sceneAmbientPoint(chart) orelse return null;
            return self.cameraModelPointForAmbient(ambient, model);
        }

        pub fn projectPoint(self: Self, chart: Vec3, canvas_width: usize, canvas_height: usize) ?[2]f32 {
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

pub const SphericalRenderPass = curved_sampling.SphericalRenderPass;

const spherical_chart_min_denom: f32 = 0.25;

fn typedRotatePair(
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
    typedReorthonormalize(metric, camera);
}

fn typedYaw(comptime metric: Metric, camera: *TypedCamera(metric), angle: f32) void {
    typedRotatePair(metric, camera, &camera.forward, &camera.right, angle);
}

fn typedPitch(comptime metric: Metric, camera: *TypedCamera(metric), angle: f32) void {
    typedRotatePair(metric, camera, &camera.forward, &camera.up, angle);
}

fn typedWorldUpDirection(comptime metric: Metric, camera: TypedCamera(metric)) ?AmbientFor(metric).Vector {
    return typedWorldUpAt(metric, camera.position);
}

fn typedHeadingBasis(comptime metric: Metric, camera: TypedCamera(metric)) ?TypedHeadingBasis(metric) {
    const up = typedWorldUpDirection(metric, camera) orelse return null;
    const east = typedOrthonormalCandidate(metric, camera.position, typedBasisVector(metric, .{ 0.0, 1.0, 0.0, 0.0 }), &.{up}) orelse
        typedOrthonormalCandidate(metric, camera.position, typedBasisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{up}) orelse
        typedOrthonormalCandidate(metric, camera.position, typedBasisVector(metric, .{ 1.0, 0.0, 0.0, 0.0 }), &.{up}) orelse
        return null;
    const north = typedOrthonormalCandidate(metric, camera.position, typedBasisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{ up, east }) orelse
        typedOrthonormalCandidate(metric, camera.position, typedBasisVector(metric, .{ 1.0, 0.0, 0.0, 0.0 }), &.{ up, east }) orelse
        typedOrthonormalCandidate(metric, camera.position, typedBasisVector(metric, .{ 0.0, 1.0, 0.0, 0.0 }), &.{ up, east }) orelse
        return null;

    return .{
        .east = east,
        .north = north,
        .up = up,
    };
}

fn typedWorldHeadingDirection(
    comptime metric: Metric,
    camera: TypedCamera(metric),
    x_heading: f32,
    z_heading: f32,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    const basis = typedHeadingBasis(metric, camera) orelse return null;
    return typedTryNormalizeTangent(metric, Ambient.add(
        Ambient.scale(basis.east, x_heading),
        Ambient.scale(basis.north, z_heading),
    ));
}

fn typedCurrentWalkOrientation(comptime metric: Metric, camera: TypedCamera(metric)) ?WalkOrientation {
    const Ambient = AmbientFor(metric);
    const basis = typedHeadingBasis(metric, camera) orelse return null;
    const pitch_angle = std.math.asin(std.math.clamp(Ambient.dot(camera.forward, basis.up), -1.0, 1.0));

    const forward_ground = typedOrthonormalCandidate(metric, camera.position, camera.forward, &.{basis.up}) orelse fallback_ground: {
        const up_sign: f32 = if (pitch_angle >= 0.0) -1.0 else 1.0;
        break :fallback_ground typedOrthonormalCandidate(metric, camera.position, Ambient.scale(camera.up, up_sign), &.{basis.up}) orelse return null;
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

fn typedWalkBasis(comptime metric: Metric, camera: TypedCamera(metric)) ?TypedWalkBasis(metric) {
    const orientation = typedCurrentWalkOrientation(metric, camera) orelse return null;
    const basis = typedHeadingBasis(metric, camera) orelse return null;
    return .{
        .forward = typedWorldHeadingDirection(metric, camera, orientation.x_heading, orientation.z_heading) orelse return null,
        .right = typedWorldHeadingDirection(metric, camera, orientation.z_heading, -orientation.x_heading) orelse return null,
        .up = basis.up,
    };
}

fn typedWalkSurfaceBasis(comptime metric: Metric, camera: TypedCamera(metric), pitch_angle: f32) ?TypedWalkBasis(metric) {
    const Ambient = AmbientFor(metric);
    const up = typedWorldUpDirection(metric, camera) orelse return null;
    const forward = typedOrthonormalCandidate(metric, camera.position, camera.forward, &.{up}) orelse
        fallback_forward: {
            const up_sign: f32 = if (pitch_angle >= 0.0) -1.0 else 1.0;
            break :fallback_forward typedOrthonormalCandidate(metric, camera.position, Ambient.scale(camera.up, up_sign), &.{up});
        } orelse
        return null;
    const right = typedOrthonormalCandidate(metric, camera.position, camera.right, &.{ up, forward }) orelse
        typedOrthonormalCandidate(metric, camera.position, camera.up, &.{ up, forward }) orelse
        return null;
    return .{
        .forward = forward,
        .right = right,
        .up = up,
    };
}

fn typedOrientFromHeadingPitch(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    x_heading: f32,
    z_heading: f32,
    pitch_angle: f32,
) void {
    const Ambient = AmbientFor(metric);
    const basis = typedHeadingBasis(metric, camera.*) orelse return;
    const horizontal_forward = typedWorldHeadingDirection(metric, camera.*, x_heading, z_heading) orelse return;
    const horizontal_right = typedWorldHeadingDirection(metric, camera.*, z_heading, -x_heading) orelse return;

    camera.forward = Ambient.add(
        Ambient.scale(horizontal_forward, @cos(pitch_angle)),
        Ambient.scale(basis.up, @sin(pitch_angle)),
    );
    camera.forward = typedTryNormalizeTangent(metric, typedProjectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = typedOrthonormalCandidate(metric, camera.position, horizontal_right, &.{camera.forward}) orelse return;
    camera.up = typedOrthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    typedReorthonormalize(metric, camera);
}

fn typedTurnSurfaceYaw(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    angle: f32,
    pitch_angle: f32,
) void {
    const Ambient = AmbientFor(metric);
    const basis = typedWalkSurfaceBasis(metric, camera.*, pitch_angle) orelse {
        typedYaw(metric, camera, angle);
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
    camera.forward = typedTryNormalizeTangent(metric, typedProjectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = typedOrthonormalCandidate(metric, camera.position, horizontal_right, &.{ camera.forward, basis.up }) orelse return;
    camera.up = typedOrthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    typedReorthonormalize(metric, camera);
}

fn typedSyncSurfacePitch(comptime metric: Metric, camera: *TypedCamera(metric), pitch_angle: f32) void {
    const Ambient = AmbientFor(metric);
    const basis = typedWalkSurfaceBasis(metric, camera.*, pitch_angle) orelse return;

    camera.forward = Ambient.add(
        Ambient.scale(basis.forward, @cos(pitch_angle)),
        Ambient.scale(basis.up, @sin(pitch_angle)),
    );
    camera.forward = typedTryNormalizeTangent(metric, typedProjectToTangent(metric, camera.position, camera.forward)) orelse return;
    camera.right = typedOrthonormalCandidate(metric, camera.position, basis.right, &.{ camera.forward, basis.up }) orelse return;
    camera.up = typedOrthonormalCandidate(metric, camera.position, basis.up, &.{ camera.forward, camera.right }) orelse return;
    typedReorthonormalize(metric, camera);
}

fn typedTransportedTangent(
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

fn typedGeodesicDirection(
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
    return typedTryNormalizeTangent(metric, tangent);
}

fn typedInitCamera(
    comptime metric: Metric,
    params: Params,
    eye_chart_input: anytype,
    target_chart_input: anytype,
) CameraError!TypedCamera(metric) {
    const position = typedEmbedPoint(metric, params, eye_chart_input) orelse return error.InvalidChartPoint;
    const target = typedEmbedPoint(metric, params, target_chart_input) orelse return error.InvalidChartPoint;
    const forward = typedGeodesicDirection(metric, position, target) orelse return error.DegenerateDirection;
    const up = typedOrthonormalCandidate(metric, position, typedBasisVector(metric, .{ 0.0, 0.0, 1.0, 0.0 }), &.{forward}) orelse
        typedOrthonormalCandidate(metric, position, typedBasisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{forward}) orelse
        return error.DegenerateDirection;
    const right = typedOrthonormalCandidate(metric, position, typedBasisVector(metric, .{ 0.0, 1.0, 0.0, 0.0 }), &.{ forward, up }) orelse
        typedOrthonormalCandidate(metric, position, typedBasisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{ forward, up }) orelse
        return error.DegenerateDirection;

    var camera = TypedCamera(metric){
        .position = position,
        .right = right,
        .up = up,
        .forward = forward,
    };
    typedReorthonormalize(metric, &camera);
    return camera;
}

fn typedMoveAlongDirection(
    comptime metric: Metric,
    camera: *TypedCamera(metric),
    params: Params,
    direction: AmbientFor(metric).Vector,
    distance: f32,
) void {
    const Ambient = AmbientFor(metric);
    const old_position = camera.position;
    const old_direction = typedTryNormalizeTangent(metric, typedProjectToTangent(metric, old_position, direction)) orelse return;
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
    camera.forward = typedTransportedTangent(metric, old_direction, new_direction, old_forward);
    camera.right = typedTransportedTangent(metric, old_direction, new_direction, old_right);
    camera.up = typedTransportedTangent(metric, old_direction, new_direction, old_up);
    typedReorthonormalize(metric, camera);
}

fn flatVector(point: Vec3) Flat3.Vector {
    return point;
}

pub const sampleProjectedModelPoint = curved_sampling.sampleProjectedModelPoint;
pub const modelPointForTypedAmbientWithCamera = curved_sampling.modelPointForTypedAmbientWithCamera;

fn edgeHasProjectionBreak(view: anytype, a_chart: Vec3, b_chart: Vec3, screen: Screen, steps: usize) bool {
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
    try std.testing.expectEqual(SampleStatus.visible, sample.status);
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

    try std.testing.expectEqual(SampleStatus.visible, sample.status);
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

    try std.testing.expectEqual(SampleStatus.visible, sample.status);
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

    try std.testing.expectEqual(SampleStatus.visible, sample.status);
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
    try std.testing.expectEqual(SampleStatus.visible, far_pass.status);
    try std.testing.expect(far_pass.projected != null);

    const combined = view.sampleProjectedAmbient(far_ambient, screen);
    try std.testing.expectEqual(SampleStatus.visible, combined.status);
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
        vec3x(local),
        vec3z(local),
    ).?;
    const up = typedWorldUpAt(.spherical, base).?;
    const ambient = sphericalAmbientFromGroundHeightPoint(params, local);
    const direction = typedGeodesicDirection(.spherical, base, ambient).?;
    const height_distance = params.radius * std.math.acos(std.math.clamp(Round.dot(base, ambient), -1.0, 1.0));

    try std.testing.expectApproxEqAbs(vec3y(local), height_distance, 1e-5);
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
        vec3x(local),
        vec3z(local),
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
    // After wrap the camera position should have moved to the opposite chart
    // only once the current conformal denominator is near-singular.
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

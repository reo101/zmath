const std = @import("std");
const projection = @import("../render/projection.zig");
const curved_projection = @import("../render/curved_projection.zig");
const curved_ambient = @import("curved_ambient.zig");
const hpga = @import("../flavours/hpga.zig");
const epga = @import("../flavours/epga.zig");

pub const Metric = enum { hyperbolic, elliptic, spherical };

pub const ChartModel = enum {
    projective,
    conformal,
};

pub const Params = struct {
    // Constant-curvature radius `R`.
    // Hyperbolic curvature is `-1 / R^2`; elliptic/spherical curvature is `+1 / R^2`.
    radius: f32 = 1.0,
    angular_zoom: f32,
    chart_model: ChartModel = .projective,
};

pub const CameraModel = curved_projection.CameraModel;
pub const DistanceClip = curved_projection.DistanceClip;
pub const Screen = curved_projection.Screen;

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

pub const Sample = curved_projection.Sample;
pub const SampleStatus = curved_projection.SampleStatus;

const RelativeCoords = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,
};

pub const ProjectedSample = curved_projection.ProjectedSample;

pub const CameraError = error{
    InvalidChartPoint,
    DegenerateDirection,
};

const Flat3 = curved_ambient.Flat3;

pub const Vec3 = Flat3.Vector;
pub const Vec4 = [4]f32;
pub const projectSample = curved_projection.projectSample;
pub const shouldBreakProjectedSegment = curved_projection.shouldBreakProjectedSegment;

const projectConformalModelPoint = curved_projection.projectConformalModelPoint;
const sampleStatus = curved_projection.sampleStatus;
const shouldBreakProjectionSegment = curved_projection.shouldBreakProjectionSegment;

pub fn AmbientFor(comptime metric: Metric) type {
    return switch (metric) {
        .hyperbolic => curved_ambient.Hyper,
        .elliptic, .spherical => curved_ambient.Round,
    };
}

pub fn TypedCamera(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        position: Ambient.Vector,
        right: Ambient.Vector,
        up: Ambient.Vector,
        forward: Ambient.Vector,
    };
}

pub fn TypedWalkBasis(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        forward: Ambient.Vector,
        right: Ambient.Vector,
        up: Ambient.Vector,
    };
}

fn TypedHeadingBasis(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        east: Ambient.Vector,
        north: Ambient.Vector,
        up: Ambient.Vector,
    };
}

fn typedCameraFromErased(comptime metric: Metric, camera: Camera) TypedCamera(metric) {
    const Ambient = AmbientFor(metric);
    return .{
        .position = Ambient.fromCoords(camera.position),
        .right = Ambient.fromCoords(camera.right),
        .up = Ambient.fromCoords(camera.up),
        .forward = Ambient.fromCoords(camera.forward),
    };
}

fn typedCameraToErased(comptime metric: Metric, camera: TypedCamera(metric)) Camera {
    const Ambient = AmbientFor(metric);
    return .{
        .position = Ambient.toCoords(camera.position),
        .right = Ambient.toCoords(camera.right),
        .up = Ambient.toCoords(camera.up),
        .forward = Ambient.toCoords(camera.forward),
    };
}

fn typedWalkBasisToErased(comptime metric: Metric, basis: TypedWalkBasis(metric)) WalkBasis {
    const Ambient = AmbientFor(metric);
    return .{
        .forward = Ambient.toCoords(basis.forward),
        .right = Ambient.toCoords(basis.right),
        .up = Ambient.toCoords(basis.up),
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

        pub fn fromErased(view: View) Self {
            std.debug.assert(view.metric == metric);
            return .{
                .params = view.params,
                .projection = view.projection,
                .clip = view.clip,
                .camera = typedCameraFromErased(metric, view.camera),
                .scene_sign = view.scene_sign,
            };
        }

        pub fn erased(self: Self) View {
            return .{
                .metric = metric,
                .params = self.params,
                .projection = self.projection,
                .clip = self.clip,
                .camera = typedCameraToErased(metric, self.camera),
                .scene_sign = self.scene_sign,
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
            return typedSampleProjectedAmbientPoint(metric, self, ambient, screen);
        }

        pub fn sampleAmbient(self: Self, ambient_input: Ambient.Vector) ?Sample {
            return typedSampleAmbientPoint(metric, self.params, self.camera, self.signedAmbient(ambient_input));
        }

        pub fn samplePoint(self: Self, chart: anytype) ?Sample {
            const ambient = self.sceneAmbientPoint(chart) orelse return null;
            return typedSampleAmbientPoint(metric, self.params, self.camera, ambient);
        }

        pub fn sampleProjectedAmbient(self: Self, ambient_input: Ambient.Vector, screen: Screen) ProjectedSample {
            return typedSampleProjectedAmbientPoint(metric, self, self.signedAmbient(ambient_input), screen);
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

            return typedSampleProjectedAmbientPointForPass(metric, self, pass, self.signedAmbient(ambient_input), screen);
        }

        pub fn sampleProjectedAmbientForSphericalPassRaw(
            self: Self,
            pass: SphericalRenderPass,
            ambient_input: Ambient.Vector,
            screen: Screen,
        ) ProjectedSample {
            std.debug.assert(metric == .spherical);
            std.debug.assert(sphericalUsesMultipass(self.projection));

            return typedSampleProjectedAmbientPointForPassRaw(metric, self, pass, self.signedAmbient(ambient_input), screen);
        }

        pub fn sphericalSelectedPassForAmbient(self: Self, ambient_input: Ambient.Vector) ?SphericalRenderPass {
            std.debug.assert(metric == .spherical);
            std.debug.assert(sphericalUsesMultipass(self.projection));

            return (typedSphericalPassSelection(metric, self, self.signedAmbient(ambient_input)) orelse return null).pass;
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
                render_view.camera = typedAntipodalSphericalPassCamera(render_view.camera);
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
            return typedModelPointForAmbient(metric, self.camera, self.signedAmbient(ambient_input), model);
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

pub fn erasedView(view: anytype) View {
    const T = @TypeOf(view);
    return if (T == View)
        view
    else if (comptime @hasDecl(T, "erased"))
        view.erased()
    else
        @compileError("expected `constant_curvature.View` or typed curved view");
}

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

fn isFiniteVec4(v: Vec4) bool {
    inline for (v) |component| {
        if (!std.math.isFinite(component)) return false;
    }
    return true;
}

fn typedEmbedPoint(
    comptime metric: Metric,
    params: Params,
    chart_input: anytype,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    const chart = coerceVec3(chart_input);
    const scale = chartScale(params);
    const scaled = vec3(vec3x(chart) / scale, vec3y(chart) / scale, vec3z(chart) / scale);
    const r2 = scaled.scalarProduct(scaled);

    return switch (metric) {
        .hyperbolic => switch (params.chart_model) {
            .projective => {
                const point = hpga.Point.proper(vec3x(scaled), vec3y(scaled), vec3z(scaled)) orelse return null;
                return Ambient.fromCoords(hpga.ambientCoords(point));
            },
            .conformal => {
                if (r2 >= 1.0) return null;
                const denom = 1.0 - r2;
                return Ambient.fromCoords(.{
                    (1.0 + r2) / denom,
                    2.0 * vec3x(scaled) / denom,
                    2.0 * vec3y(scaled) / denom,
                    2.0 * vec3z(scaled) / denom,
                });
            },
        },
        .elliptic, .spherical => switch (params.chart_model) {
            .projective => Ambient.fromCoords(epga.ambientCoords(epga.Point.proper(vec3x(scaled), vec3y(scaled), vec3z(scaled)))),
            .conformal => {
                const denom = 1.0 + r2;
                return Ambient.fromCoords(.{
                    (1.0 - r2) / denom,
                    2.0 * vec3x(scaled) / denom,
                    2.0 * vec3y(scaled) / denom,
                    2.0 * vec3z(scaled) / denom,
                });
            },
        },
    };
}

fn typedChartCoords(
    comptime metric: Metric,
    params: Params,
    ambient: AmbientFor(metric).Vector,
) Vec3 {
    const Ambient = AmbientFor(metric);
    var point = ambient;
    if (metric == .elliptic and Ambient.w(point) < 0.0) {
        point = Ambient.scale(point, -1.0);
    }

    const scale = chartScale(params);
    return switch (params.chart_model) {
        .projective => {
            const inv_w = scale / safeDivDenom(Ambient.w(point));
            return vec3(
                Ambient.x(point) * inv_w,
                Ambient.y(point) * inv_w,
                Ambient.z(point) * inv_w,
            );
        },
        .conformal => {
            const inv = scale / safeDivDenom(1.0 + Ambient.w(point));
            return vec3(
                Ambient.x(point) * inv,
                Ambient.y(point) * inv,
                Ambient.z(point) * inv,
            );
        },
    };
}

fn typedZero(comptime metric: Metric) AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    return Ambient.scale(Ambient.identity(), 0.0);
}

fn typedBasisVector(comptime metric: Metric, coords: [4]f32) AmbientFor(metric).Vector {
    return AmbientFor(metric).fromCoords(coords);
}

fn typedTryNormalizeTangent(comptime metric: Metric, v: AmbientFor(metric).Vector) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    if (!Ambient.isFinite(v)) return null;
    const n2 = Ambient.dot(v, v);
    if (!std.math.isFinite(n2) or n2 <= 1e-6) return null;
    return Ambient.scale(v, 1.0 / @sqrt(n2));
}

fn typedProjectToTangent(
    comptime metric: Metric,
    position: AmbientFor(metric).Vector,
    candidate: AmbientFor(metric).Vector,
) AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    if (!Ambient.isFinite(position) or !Ambient.isFinite(candidate)) return typedZero(metric);
    const denom = Ambient.dot(position, position);
    if (!std.math.isFinite(denom) or @abs(denom) <= 1e-6) return typedZero(metric);
    const along = Ambient.dot(candidate, position) / denom;
    if (!std.math.isFinite(along)) return typedZero(metric);
    return Ambient.sub(candidate, Ambient.scale(position, along));
}

fn typedOrthonormalCandidate(
    comptime metric: Metric,
    position: AmbientFor(metric).Vector,
    candidate: AmbientFor(metric).Vector,
    refs: []const AmbientFor(metric).Vector,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    var v = typedProjectToTangent(metric, position, candidate);
    for (refs) |r| {
        v = Ambient.sub(v, Ambient.scale(r, Ambient.dot(v, r)));
    }
    return typedTryNormalizeTangent(metric, v);
}

fn typedReorthonormalize(comptime metric: Metric, camera: *TypedCamera(metric)) void {
    camera.forward = typedOrthonormalCandidate(metric, camera.position, camera.forward, &.{}) orelse camera.forward;
    camera.right = typedOrthonormalCandidate(metric, camera.position, camera.right, &.{camera.forward}) orelse camera.right;
    camera.up = typedOrthonormalCandidate(metric, camera.position, camera.up, &.{ camera.forward, camera.right }) orelse camera.up;
}

fn typedNormalizeAmbient(comptime metric: Metric, ambient: AmbientFor(metric).Vector) AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    if (!Ambient.isFinite(ambient)) return Ambient.identity();
    const norm2 = Ambient.dot(ambient, ambient);
    const inv = switch (metric) {
        .hyperbolic => inv: {
            if (!std.math.isFinite(norm2) or -norm2 <= 1e-6) return Ambient.identity();
            break :inv 1.0 / @sqrt(-norm2);
        },
        .elliptic, .spherical => inv: {
            if (!std.math.isFinite(norm2) or norm2 <= 1e-6) return Ambient.identity();
            break :inv 1.0 / @sqrt(norm2);
        },
    };
    const normalized = Ambient.scale(ambient, inv);
    return if (Ambient.isFinite(normalized)) normalized else Ambient.identity();
}

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

fn typedWorldUpAt(comptime metric: Metric, position: AmbientFor(metric).Vector) ?AmbientFor(metric).Vector {
    return typedOrthonormalCandidate(metric, position, typedBasisVector(metric, .{ 0.0, 0.0, 1.0, 0.0 }), &.{}) orelse
        typedOrthonormalCandidate(metric, position, typedBasisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{});
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

fn typedGeodesicAmbientPoint(
    comptime metric: Metric,
    a: AmbientFor(metric).Vector,
    b_input: AmbientFor(metric).Vector,
    t: f32,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    var b = b_input;

    return switch (metric) {
        .hyperbolic => {
            const cosh_omega = @max(-Ambient.dot(a, b), 1.0);
            const omega = std.math.acosh(cosh_omega);
            if (omega <= 1e-5) return a;

            const inv_denom = 1.0 / std.math.sinh(omega);
            const p = Ambient.add(
                Ambient.scale(a, std.math.sinh((1.0 - t) * omega) * inv_denom),
                Ambient.scale(b, std.math.sinh(t * omega) * inv_denom),
            );
            return typedNormalizeAmbient(metric, p);
        },
        .elliptic, .spherical => {
            if (metric == .elliptic and Ambient.dot(a, b) < 0.0) {
                b = Ambient.scale(b, -1.0);
            }

            const cos_omega = std.math.clamp(Ambient.dot(a, b), -1.0, 1.0);
            const omega = std.math.acos(cos_omega);
            if (omega <= 1e-5) return a;

            const inv_denom = 1.0 / @sin(omega);
            const p = Ambient.add(
                Ambient.scale(a, @sin((1.0 - t) * omega) * inv_denom),
                Ambient.scale(b, @sin(t * omega) * inv_denom),
            );
            return typedNormalizeAmbient(metric, p);
        },
    };
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

    pub fn typed(self: View, comptime metric_tag: Metric) TypedView(metric_tag) {
        std.debug.assert(self.metric == metric_tag);
        return TypedView(metric_tag).fromErased(self);
    }

    pub fn turnYaw(self: *View, angle: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.turnYaw(angle);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn turnWalkYaw(self: *View, angle: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.turnWalkYaw(angle);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn turnSurfaceYaw(self: *View, angle: f32, pitch_angle: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.turnSurfaceYaw(angle, pitch_angle);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn syncSurfacePitch(self: *View, pitch_angle: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.syncSurfacePitch(pitch_angle);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn turnPitch(self: *View, angle: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.turnPitch(angle);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn moveAlong(self: *View, direction: Vec4, distance: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.moveAlong(AmbientFor(metric_tag).fromCoords(direction), distance);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn moveForwardBy(self: *View, distance: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.moveForwardBy(distance);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn moveRightBy(self: *View, distance: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.moveRightBy(distance);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn headingDirection(self: View, x_heading: f32, z_heading: f32) ?Vec4 {
        return switch (self.metric) {
            inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
                self.typed(metric_tag).headingDirection(x_heading, z_heading) orelse return null,
            ),
        };
    }

    pub fn walkOrientation(self: View) ?WalkOrientation {
        return switch (self.metric) {
            .hyperbolic => self.typed(.hyperbolic).walkOrientation(),
            .elliptic => self.typed(.elliptic).walkOrientation(),
            .spherical => self.typed(.spherical).walkOrientation(),
        };
    }

    pub fn walkBasis(self: View) ?WalkBasis {
        return switch (self.metric) {
            inline else => |metric_tag| typedWalkBasisToErased(
                metric_tag,
                self.typed(metric_tag).walkBasis() orelse return null,
            ),
        };
    }

    pub fn walkSurfaceUp(self: View) ?Vec4 {
        return switch (self.metric) {
            inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
                self.typed(metric_tag).walkSurfaceUp() orelse return null,
            ),
        };
    }

    pub fn walkSurfaceBasis(self: View, pitch_angle: f32) ?WalkBasis {
        return switch (self.metric) {
            inline else => |metric_tag| typedWalkBasisToErased(
                metric_tag,
                self.typed(metric_tag).walkSurfaceBasis(pitch_angle) orelse return null,
            ),
        };
    }

    pub fn syncHeadingPitch(self: *View, x_heading: f32, z_heading: f32, pitch_angle: f32) void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                typed_view.syncHeadingPitch(x_heading, z_heading, pitch_angle);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn wrapSphericalChart(self: *View) void {
        switch (self.metric) {
            .spherical => {
                var typed_view = self.typed(.spherical);
                typed_view.wrapSphericalChart();
                self.* = typed_view.erased();
            },
            inline else => {},
        }
    }

    pub fn adjustRadius(self: *View, radius: f32, look_ahead: f32) CameraError!void {
        switch (self.metric) {
            inline else => |metric_tag| {
                var typed_view = self.typed(metric_tag);
                try typed_view.adjustRadius(radius, look_ahead);
                self.* = typed_view.erased();
            },
        }
    }

    pub fn shadeFarDistance(self: View) f32 {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).shadeFarDistance(),
        };
    }

    pub fn embedPoint(self: View, chart: anytype) ?Vec4 {
        return switch (self.metric) {
            inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
                self.typed(metric_tag).embedPoint(chart) orelse return null,
            ),
        };
    }

    pub fn chartCoords(self: View, ambient: Vec4) Vec3 {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).chartCoords(
                AmbientFor(metric_tag).fromCoords(ambient),
            ),
        };
    }

    pub fn geodesicChartPoint(self: View, a_chart: anytype, b_chart: anytype, t: f32) ?Vec3 {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).geodesicChartPoint(a_chart, b_chart, t),
        };
    }

    pub fn sceneAmbientPoint(self: View, chart: anytype) ?Vec4 {
        return switch (self.metric) {
            inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
                self.typed(metric_tag).sceneAmbientPoint(chart) orelse return null,
            ),
        };
    }

    pub fn signedAmbient(self: View, ambient_input: Vec4) Vec4 {
        return switch (self.metric) {
            inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
                self.typed(metric_tag).signedAmbient(
                    AmbientFor(metric_tag).fromCoords(ambient_input),
                ),
            ),
        };
    }

    pub fn sampleProjectedPoint(self: View, chart: anytype, screen: Screen) ProjectedSample {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).sampleProjectedPoint(chart, screen),
        };
    }

    pub fn sampleAmbient(self: View, ambient_input: Vec4) ?Sample {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).sampleAmbient(
                AmbientFor(metric_tag).fromCoords(ambient_input),
            ),
        };
    }

    pub fn samplePoint(self: View, chart: anytype) ?Sample {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).samplePoint(chart),
        };
    }

    pub fn sampleProjectedAmbient(self: View, ambient_input: Vec4, screen: Screen) ProjectedSample {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).sampleProjectedAmbient(
                AmbientFor(metric_tag).fromCoords(ambient_input),
                screen,
            ),
        };
    }

    pub fn sampleProjectedPointForSphericalPass(self: View, pass: SphericalRenderPass, chart: anytype, screen: Screen) ProjectedSample {
        std.debug.assert(self.metric == .spherical);
        return self.typed(.spherical).sampleProjectedPointForSphericalPass(pass, chart, screen);
    }

    pub fn sampleProjectedAmbientForSphericalPass(self: View, pass: SphericalRenderPass, ambient_input: Vec4, screen: Screen) ProjectedSample {
        std.debug.assert(self.metric == .spherical);
        return self.typed(.spherical).sampleProjectedAmbientForSphericalPass(
            pass,
            curved_ambient.Round.fromCoords(ambient_input),
            screen,
        );
    }

    pub fn sampleProjectedAmbientForSphericalPassRaw(self: View, pass: SphericalRenderPass, ambient_input: Vec4, screen: Screen) ProjectedSample {
        std.debug.assert(self.metric == .spherical);
        return self.typed(.spherical).sampleProjectedAmbientForSphericalPassRaw(
            pass,
            curved_ambient.Round.fromCoords(ambient_input),
            screen,
        );
    }

    pub fn sphericalSelectedPassForAmbient(self: View, ambient_input: Vec4) ?SphericalRenderPass {
        std.debug.assert(self.metric == .spherical);
        return self.typed(.spherical).sphericalSelectedPassForAmbient(
            curved_ambient.Round.fromCoords(ambient_input),
        );
    }

    pub fn sphericalRenderPass(self: View, pass: SphericalRenderPass) View {
        std.debug.assert(self.metric == .spherical);
        return self.typed(.spherical).sphericalRenderPass(pass).erased();
    }

    pub fn mapSphericalRenderDistance(self: View, pass: SphericalRenderPass, pass_distance: f32) f32 {
        std.debug.assert(self.metric == .spherical);
        return self.typed(.spherical).mapSphericalRenderDistance(pass, pass_distance);
    }

    pub fn cameraModelPointForAmbient(self: View, ambient_input: Vec4, model: CameraModel) ?Vec3 {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).cameraModelPointForAmbient(
                AmbientFor(metric_tag).fromCoords(ambient_input),
                model,
            ),
        };
    }

    pub fn cameraModelPoint(self: View, chart: anytype, model: CameraModel) ?Vec3 {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).cameraModelPoint(chart, model),
        };
    }

    pub fn projectPoint(self: View, chart: Vec3, canvas_width: usize, canvas_height: usize) ?[2]f32 {
        return switch (self.metric) {
            inline else => |metric_tag| self.typed(metric_tag).projectPoint(chart, canvas_width, canvas_height),
        };
    }

    fn signedSphericalAmbient(self: View, ambient_input: Vec4) Vec4 {
        var ambient = ambient_input;
        if (self.scene_sign < 0.0) {
            ambient = scale4(self.metric, ambient, -1.0);
        }
        return ambient;
    }
};

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
        .hyperbolic => curved_ambient.Hyper.toCoords(curved_ambient.Hyper.add(
            curved_ambient.Hyper.fromCoords(a),
            curved_ambient.Hyper.fromCoords(b),
        )),
        .elliptic, .spherical => curved_ambient.Round.toCoords(curved_ambient.Round.add(
            curved_ambient.Round.fromCoords(a),
            curved_ambient.Round.fromCoords(b),
        )),
    };
}

fn sub4(metric: Metric, a: Vec4, b: Vec4) Vec4 {
    return switch (metric) {
        .hyperbolic => curved_ambient.Hyper.toCoords(curved_ambient.Hyper.sub(
            curved_ambient.Hyper.fromCoords(a),
            curved_ambient.Hyper.fromCoords(b),
        )),
        .elliptic, .spherical => curved_ambient.Round.toCoords(curved_ambient.Round.sub(
            curved_ambient.Round.fromCoords(a),
            curved_ambient.Round.fromCoords(b),
        )),
    };
}

fn scale4(metric: Metric, v: Vec4, s: f32) Vec4 {
    return switch (metric) {
        .hyperbolic => curved_ambient.Hyper.toCoords(curved_ambient.Hyper.scale(
            curved_ambient.Hyper.fromCoords(v),
            s,
        )),
        .elliptic, .spherical => curved_ambient.Round.toCoords(curved_ambient.Round.scale(
            curved_ambient.Round.fromCoords(v),
            s,
        )),
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
    if (!std.math.isFinite(value)) return 1e-6;
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
    return switch (metric) {
        inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
            ambientFromTypedTangentBasisPoint(
                metric_tag,
                params,
                AmbientFor(metric_tag).fromCoords(origin),
                AmbientFor(metric_tag).fromCoords(right),
                AmbientFor(metric_tag).fromCoords(forward),
                lateral,
                forward_distance,
            ) orelse return null,
        ),
    };
}

pub fn ambientFromTypedTangentBasisPoint(
    comptime metric: Metric,
    params: Params,
    origin: AmbientFor(metric).Vector,
    right: AmbientFor(metric).Vector,
    forward: AmbientFor(metric).Vector,
    lateral: f32,
    forward_distance: f32,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    if (!Ambient.isFinite(origin) or !Ambient.isFinite(right) or !Ambient.isFinite(forward)) return origin;
    if (!std.math.isFinite(lateral) or !std.math.isFinite(forward_distance)) return origin;

    const tangent = Ambient.add(
        Ambient.scale(right, lateral),
        Ambient.scale(forward, forward_distance),
    );
    const tangent_norm2 = Ambient.dot(tangent, tangent);
    if (!std.math.isFinite(tangent_norm2) or tangent_norm2 <= 1e-6) return origin;

    const tangent_norm = @sqrt(tangent_norm2);
    const normalized_distance = tangent_norm / params.radius;
    if (!std.math.isFinite(normalized_distance)) return origin;
    const position = switch (metric) {
        .hyperbolic => Ambient.add(
            Ambient.scale(origin, std.math.cosh(normalized_distance)),
            Ambient.scale(tangent, std.math.sinh(normalized_distance) / tangent_norm),
        ),
        .elliptic, .spherical => Ambient.add(
            Ambient.scale(origin, @cos(normalized_distance)),
            Ambient.scale(tangent, @sin(normalized_distance) / tangent_norm),
        ),
    };
    return typedNormalizeAmbient(metric, position);
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

fn typedAntipodalSphericalPassCamera(camera: TypedCamera(.spherical)) TypedCamera(.spherical) {
    return .{
        .position = curved_ambient.Round.scale(camera.position, -1.0),
        .right = camera.right,
        .up = camera.up,
        .forward = curved_ambient.Round.scale(camera.forward, -1.0),
    };
}

fn sampleProjectedAmbientPointSinglePass(view: View, ambient: Vec4, screen: Screen) ProjectedSample {
    return switch (view.metric) {
        inline else => |metric_tag| typedSampleProjectedAmbientPointSinglePass(
            metric_tag,
            view.typed(metric_tag),
            AmbientFor(metric_tag).fromCoords(ambient),
            screen,
        ),
    };
}

fn typedSampleProjectedAmbientPointSinglePass(
    comptime metric: Metric,
    view: TypedView(metric),
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    if (cameraModelForRender(metric, view.projection)) |camera_model| {
        const model_point = typedModelPointForAmbient(metric, view.camera, ambient, camera_model) orelse return .{};
        return sampleProjectedModelPoint(
            metric,
            view.projection,
            view.params,
            view.clip,
            model_point,
            screen,
        );
    }

    const point_sample = typedSampleAmbientPoint(metric, view.params, view.camera, ambient) orelse return .{};
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
    return switch (view.metric) {
        .spherical => typedSampleProjectedAmbientPointForPass(
            .spherical,
            view.typed(.spherical),
            pass,
            curved_ambient.Round.fromCoords(ambient),
            screen,
        ),
        inline else => .{},
    };
}

fn typedSampleProjectedAmbientPointForPass(
    comptime metric: Metric,
    view: TypedView(metric),
    pass: SphericalRenderPass,
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    const selection = typedSphericalPassSelection(metric, view, ambient) orelse return .{};
    if (selection.pass != pass) return .{ .distance = selection.near_distance };

    return typedSampleProjectedAmbientPointForPassRaw(metric, view, pass, ambient, screen);
}

fn sampleProjectedAmbientPointForPassRaw(
    view: View,
    pass: SphericalRenderPass,
    ambient: Vec4,
    screen: Screen,
) ProjectedSample {
    return switch (view.metric) {
        .spherical => typedSampleProjectedAmbientPointForPassRaw(
            .spherical,
            view.typed(.spherical),
            pass,
            curved_ambient.Round.fromCoords(ambient),
            screen,
        ),
        inline else => .{},
    };
}

fn typedSampleProjectedAmbientPointForPassRaw(
    comptime metric: Metric,
    view: TypedView(metric),
    pass: SphericalRenderPass,
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    const model = cameraModelForRender(metric, view.projection);

    if (pass == .near) {
        if (model) |camera_model| {
            const model_point = typedModelPointForAmbient(metric, view.camera, ambient, camera_model) orelse return .{};
            return sampleProjectedModelPoint(
                metric,
                view.projection,
                view.params,
                view.clip,
                model_point,
                screen,
            );
        }

        const near_sample = typedSampleAmbientPoint(metric, view.params, view.camera, ambient) orelse return .{};
        const projected = projectSample(view.projection, near_sample, screen.width, screen.height, screen.zoom);
        return .{
            .distance = near_sample.distance,
            .projected = projected,
            .status = sampleStatus(near_sample.distance, view.clip, projected),
        };
    }

    const far_camera = typedAntipodalSphericalPassCamera(view.camera);
    if (model) |camera_model| {
        const model_point = typedModelPointForAmbient(metric, far_camera, ambient, camera_model) orelse return .{};
        const far_sample = sampleProjectedModelPoint(
            metric,
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

    const far_pass_sample = typedSampleAmbientPoint(metric, view.params, far_camera, ambient) orelse return .{};
    const mapped_distance = maxSphericalDistance(view.params) - far_pass_sample.distance;
    const projected = projectSample(view.projection, far_pass_sample, screen.width, screen.height, screen.zoom);
    return .{
        .distance = mapped_distance,
        .projected = projected,
        .status = sampleStatus(mapped_distance, view.clip, projected),
    };
}

fn sphericalPassSelection(view: View, ambient: Vec4) ?SphericalPassSelection {
    return switch (view.metric) {
        inline else => |metric_tag| typedSphericalPassSelection(
            metric_tag,
            view.typed(metric_tag),
            AmbientFor(metric_tag).fromCoords(ambient),
        ),
    };
}

fn typedSphericalPassSelection(
    comptime metric: Metric,
    view: TypedView(metric),
    ambient: AmbientFor(metric).Vector,
) ?SphericalPassSelection {
    const near_sample = typedSampleAmbientPoint(metric, view.params, view.camera, ambient) orelse return null;
    return .{
        .pass = if (near_sample.z_dir >= 0.0) .near else .far,
        .near_distance = near_sample.distance,
    };
}

fn sampleProjectedAmbientPoint(view: View, ambient: Vec4, screen: Screen) ProjectedSample {
    return switch (view.metric) {
        inline else => |metric_tag| typedSampleProjectedAmbientPoint(
            metric_tag,
            view.typed(metric_tag),
            AmbientFor(metric_tag).fromCoords(ambient),
            screen,
        ),
    };
}

fn typedSampleProjectedAmbientPoint(
    comptime metric: Metric,
    view: TypedView(metric),
    ambient: AmbientFor(metric).Vector,
    screen: Screen,
) ProjectedSample {
    if (metric != .spherical or !sphericalUsesMultipass(view.projection)) {
        return typedSampleProjectedAmbientPointSinglePass(metric, view, ambient, screen);
    }

    const near = typedSampleProjectedAmbientPointForPass(metric, view, .near, ambient, screen);
    if (near.status != .hidden or near.projected != null) return near;
    return typedSampleProjectedAmbientPointForPass(metric, view, .far, ambient, screen);
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
        .hyperbolic => curved_ambient.Hyper.dot(
            curved_ambient.Hyper.fromCoords(a),
            curved_ambient.Hyper.fromCoords(b),
        ),
        .elliptic, .spherical => curved_ambient.Round.dot(
            curved_ambient.Round.fromCoords(a),
            curved_ambient.Round.fromCoords(b),
        ),
    };
}

fn tryNormalizeTangent(metric: Metric, v: Vec4) ?Vec4 {
    if (!isFiniteVec4(v)) return null;
    const n2 = metricDot(metric, v, v);
    if (!std.math.isFinite(n2) or n2 <= 1e-6) return null;
    return scale4(metric, v, 1.0 / @sqrt(n2));
}

fn projectToTangent(metric: Metric, position: Vec4, candidate: Vec4) Vec4 {
    if (!isFiniteVec4(position) or !isFiniteVec4(candidate)) return .{ 0.0, 0.0, 0.0, 0.0 };
    const denom = metricDot(metric, position, position);
    if (!std.math.isFinite(denom) or @abs(denom) <= 1e-6) return .{ 0.0, 0.0, 0.0, 0.0 };
    const along = metricDot(metric, candidate, position) / denom;
    if (!std.math.isFinite(along)) return .{ 0.0, 0.0, 0.0, 0.0 };
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
    return switch (metric) {
        inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
            typedEmbedPoint(metric_tag, params, chart_input) orelse return null,
        ),
    };
}

pub fn chartCoords(metric: Metric, params: Params, ambient: Vec4) Vec3 {
    return switch (metric) {
        inline else => |metric_tag| typedChartCoords(
            metric_tag,
            params,
            AmbientFor(metric_tag).fromCoords(ambient),
        ),
    };
}

fn normalizeAmbient(metric: Metric, ambient: Vec4) Vec4 {
    return switch (metric) {
        inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
            typedNormalizeAmbient(metric_tag, AmbientFor(metric_tag).fromCoords(ambient)),
        ),
    };
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
    return switch (metric) {
        inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
            typedGeodesicAmbientPoint(
                metric_tag,
                AmbientFor(metric_tag).fromCoords(a),
                AmbientFor(metric_tag).fromCoords(b_input),
                t,
            ) orelse return null,
        ),
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
    return switch (metric) {
        inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
            typedGeodesicDirection(
                metric_tag,
                AmbientFor(metric_tag).fromCoords(eye),
                AmbientFor(metric_tag).fromCoords(target),
            ) orelse return null,
        ),
    };
}

fn relativeCoords(metric: Metric, camera: Camera, ambient: Vec4) RelativeCoords {
    return switch (metric) {
        inline else => |metric_tag| typedRelativeCoords(
            metric_tag,
            typedCameraFromErased(metric_tag, camera),
            AmbientFor(metric_tag).fromCoords(ambient),
        ),
    };
}

fn typedRelativeCoords(
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

fn reorthonormalize(metric: Metric, camera: *Camera) void {
    camera.forward = orthonormalCandidate(metric, camera.position, camera.forward, &.{}) orelse camera.forward;
    camera.right = orthonormalCandidate(metric, camera.position, camera.right, &.{camera.forward}) orelse camera.right;
    camera.up = orthonormalCandidate(metric, camera.position, camera.up, &.{ camera.forward, camera.right }) orelse camera.up;
}

pub fn initCamera(metric: Metric, params: Params, eye_chart_input: anytype, target_chart_input: anytype) CameraError!Camera {
    return switch (metric) {
        inline else => |metric_tag| typedCameraToErased(
            metric_tag,
            try typedInitCamera(metric_tag, params, coerceVec3(eye_chart_input), coerceVec3(target_chart_input)),
        ),
    };
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
    switch (metric) {
        inline else => |metric_tag| {
            var typed_camera = typedCameraFromErased(metric_tag, camera.*);
            typedYaw(metric_tag, &typed_camera, angle);
            camera.* = typedCameraToErased(metric_tag, typed_camera);
        },
    }
}

pub fn pitch(camera: *Camera, metric: Metric, angle: f32) void {
    switch (metric) {
        inline else => |metric_tag| {
            var typed_camera = typedCameraFromErased(metric_tag, camera.*);
            typedPitch(metric_tag, &typed_camera, angle);
            camera.* = typedCameraToErased(metric_tag, typed_camera);
        },
    }
}

// Geodesic camera transport in the ambient models:
// - sphere: `(cos s) * P + (sin s) * V`
// - hyperboloid: `(cosh s) * P + (sinh s) * V`
// with the companion update for the transported tangent basis.
// References:
// https://arxiv.org/abs/1310.2713
// https://arxiv.org/pdf/1602.08562
pub fn moveAlongDirection(camera: *Camera, metric: Metric, params: Params, direction: Vec4, distance: f32) void {
    switch (metric) {
        inline else => |metric_tag| {
            var typed_camera = typedCameraFromErased(metric_tag, camera.*);
            typedMoveAlongDirection(
                metric_tag,
                &typed_camera,
                params,
                AmbientFor(metric_tag).fromCoords(direction),
                distance,
            );
            camera.* = typedCameraToErased(metric_tag, typed_camera);
        },
    }
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
    return switch (metric) {
        inline else => |metric_tag| AmbientFor(metric_tag).toCoords(
            typedWorldHeadingDirection(metric_tag, typedCameraFromErased(metric_tag, camera), x_heading, z_heading) orelse return null,
        ),
    };
}

fn worldUpAt(metric: Metric, position: Vec4) ?Vec4 {
    return orthonormalCandidate(metric, position, .{ 0.0, 0.0, 1.0, 0.0 }, &.{}) orelse
        orthonormalCandidate(metric, position, .{ 0.0, 0.0, 0.0, 1.0 }, &.{});
}

fn worldUpDirection(metric: Metric, camera: Camera) ?Vec4 {
    return worldUpAt(metric, camera.position);
}

fn currentWalkOrientation(metric: Metric, camera: Camera) ?WalkOrientation {
    return switch (metric) {
        inline else => |metric_tag| typedCurrentWalkOrientation(metric_tag, typedCameraFromErased(metric_tag, camera)),
    };
}

pub fn orientFromHeadingPitch(
    metric: Metric,
    camera: *Camera,
    x_heading: f32,
    z_heading: f32,
    pitch_angle: f32,
) void {
    switch (metric) {
        inline else => |metric_tag| {
            var typed_camera = typedCameraFromErased(metric_tag, camera.*);
            typedOrientFromHeadingPitch(metric_tag, &typed_camera, x_heading, z_heading, pitch_angle);
            camera.* = typedCameraToErased(metric_tag, typed_camera);
        },
    }
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
    return (View{
        .metric = metric,
        .params = params,
        .projection = projection_mode,
        .clip = .{},
        .camera = camera,
        .scene_sign = 1.0,
    }).projectPoint(chart, canvas_width, canvas_height);
}

fn sampleAmbientPoint(metric: Metric, params: Params, camera: Camera, ambient: Vec4) ?Sample {
    return switch (metric) {
        inline else => |metric_tag| typedSampleAmbientPoint(
            metric_tag,
            params,
            typedCameraFromErased(metric_tag, camera),
            AmbientFor(metric_tag).fromCoords(ambient),
        ),
    };
}

fn typedSampleAmbientPoint(
    comptime metric: Metric,
    params: Params,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
) ?Sample {
    const relative = typedRelativeCoords(metric, camera, ambient);
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
    return (View{
        .metric = metric,
        .params = params,
        .projection = .gnomonic,
        .clip = .{},
        .camera = camera,
        .scene_sign = 1.0,
    }).samplePoint(chart);
}

fn modelPointForAmbient(metric: Metric, camera: Camera, ambient: Vec4, model: CameraModel) ?Vec3 {
    return switch (metric) {
        inline else => |metric_tag| typedModelPointForAmbient(
            metric_tag,
            typedCameraFromErased(metric_tag, camera),
            AmbientFor(metric_tag).fromCoords(ambient),
            model,
        ),
    };
}

fn typedModelPointForAmbient(
    comptime metric: Metric,
    camera: TypedCamera(metric),
    ambient: AmbientFor(metric).Vector,
    model: CameraModel,
) ?Vec3 {
    const relative = typedRelativeCoords(metric, camera, ambient);
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
    return typedModelPointForAmbient(metric, camera, ambient, model);
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
    return (View{
        .metric = metric,
        .params = params,
        .projection = .gnomonic,
        .clip = .{},
        .camera = camera,
        .scene_sign = 1.0,
    }).cameraModelPoint(chart, model);
}

fn edgeHasProjectionBreak(view: View, a_chart: Vec3, b_chart: Vec3, screen: Screen, steps: usize) bool {
    var prev_point: ?[2]f32 = null;

    for (0..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const point = view.geodesicChartPoint(a_chart, b_chart, t) orelse continue;
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

test "typed spherical view stays in sync with erased view operations" {
    const params = Params{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal };
    const clip = DistanceClip{ .near = 0.08, .far = std.math.inf(f32) };
    var typed = try SphericalView.init(params, .wrapped, clip, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 });
    var erased = try View.init(.spherical, params, .wrapped, clip, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 });
    const typed_from_erased = erased.typed(.spherical);
    inline for (curved_ambient.Round.toCoords(typed_from_erased.camera.position), curved_ambient.Round.toCoords(typed.camera.position)) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, 1e-6);
    }

    typed.syncHeadingPitch(0.42, 0.9075241, 0.55);
    erased.syncHeadingPitch(0.42, 0.9075241, 0.55);
    typed.turnSurfaceYaw(0.2, 0.55);
    erased.turnSurfaceYaw(0.2, 0.55);
    const typed_forward = typed.headingDirection(0.42, 0.9075241).?;
    const erased_forward = erased.headingDirection(0.42, 0.9075241).?;
    typed.moveAlong(typed_forward, 0.10);
    erased.moveAlong(erased_forward, 0.10);

    const typed_erased = typed.erased();
    inline for (typed_erased.camera.position, erased.camera.position) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, 1e-5);
    }
    inline for (typed_erased.camera.forward, erased.camera.forward) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, 1e-5);
    }

    const typed_orientation = typed.walkOrientation().?;
    const erased_orientation = erased.walkOrientation().?;
    try std.testing.expectApproxEqAbs(typed_orientation.x_heading, erased_orientation.x_heading, 1e-5);
    try std.testing.expectApproxEqAbs(typed_orientation.z_heading, erased_orientation.z_heading, 1e-5);
    try std.testing.expectApproxEqAbs(typed_orientation.pitch, erased_orientation.pitch, 1e-5);
}

test "typed spherical view matches erased sampling queries" {
    const params = Params{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal };
    const clip = DistanceClip{ .near = 0.08, .far = std.math.inf(f32) };
    const screen = Screen{ .width = 96, .height = 54, .zoom = 1.0 };
    const chart = vec3(0.12, -0.07, 0.18);

    const typed = try SphericalView.init(params, .stereographic, clip, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 });
    const erased = try View.init(.spherical, params, .stereographic, clip, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 });

    const typed_sample = typed.sampleProjectedPoint(chart, screen);
    const erased_sample = erased.sampleProjectedPoint(chart, screen);
    try std.testing.expectEqual(erased_sample.status, typed_sample.status);
    try std.testing.expectApproxEqAbs(erased_sample.distance, typed_sample.distance, 1e-5);
    try std.testing.expectApproxEqAbs(erased_sample.render_depth, typed_sample.render_depth, 1e-5);
    try std.testing.expectApproxEqAbs(erased_sample.projected.?[0], typed_sample.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(erased_sample.projected.?[1], typed_sample.projected.?[1], 1e-4);

    const typed_model = typed.cameraModelPoint(chart, .conformal).?;
    const erased_model = erased.cameraModelPoint(chart, .conformal).?;
    inline for (vec3Coords(typed_model), vec3Coords(erased_model)) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, 1e-5);
    }

    const typed_ambient = typed.sceneAmbientPoint(chart).?;
    const erased_ambient = erased.sceneAmbientPoint(chart).?;
    try std.testing.expectEqual(
        erased.sphericalSelectedPassForAmbient(erased_ambient).?,
        typed.sphericalSelectedPassForAmbient(typed_ambient).?,
    );
    const typed_far = typed.sampleProjectedAmbientForSphericalPass(.far, typed_ambient, screen);
    const erased_far = erased.sampleProjectedAmbientForSphericalPass(.far, erased_ambient, screen);
    try std.testing.expectEqual(erased_far.status, typed_far.status);
    try std.testing.expectApproxEqAbs(erased_far.distance, typed_far.distance, 1e-5);
    try std.testing.expectApproxEqAbs(erased_far.projected.?[0], typed_far.projected.?[0], 1e-4);
    try std.testing.expectApproxEqAbs(erased_far.projected.?[1], typed_far.projected.?[1], 1e-4);
}

test "typed curved views initialize like erased views" {
    const params = Params{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal };
    const clip = DistanceClip{ .near = 0.08, .far = std.math.inf(f32) };

    const typed_hyper = try HyperView.init(params, .gnomonic, clip, .{ 0.0, 0.0, -0.22 }, .{ 0.0, 0.0, 0.0 });
    const erased_hyper = try View.init(.hyperbolic, params, .gnomonic, clip, .{ 0.0, 0.0, -0.22 }, .{ 0.0, 0.0, 0.0 });
    const typed_round = try SphericalView.init(params, .stereographic, clip, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 });
    const erased_round = try View.init(.spherical, params, .stereographic, clip, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 });

    const typed_hyper_erased = typed_hyper.erased();
    const typed_round_erased = typed_round.erased();
    inline for (&.{ typed_hyper_erased.camera.position, typed_hyper_erased.camera.right, typed_hyper_erased.camera.up, typed_hyper_erased.camera.forward }, &.{ erased_hyper.camera.position, erased_hyper.camera.right, erased_hyper.camera.up, erased_hyper.camera.forward }) |expected, actual| {
        inline for (expected, 0..) |coord, i| {
            try std.testing.expectApproxEqAbs(coord, actual[i], 1e-6);
        }
    }
    inline for (&.{ typed_round_erased.camera.position, typed_round_erased.camera.right, typed_round_erased.camera.up, typed_round_erased.camera.forward }, &.{ erased_round.camera.position, erased_round.camera.right, erased_round.camera.up, erased_round.camera.forward }) |expected, actual| {
        inline for (expected, 0..) |coord, i| {
            try std.testing.expectApproxEqAbs(coord, actual[i], 1e-6);
        }
    }
}

test "typed adjustRadius matches erased adjustment" {
    var typed = try SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    var erased = try View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .wrapped,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );

    try typed.adjustRadius(1.15, 0.18);
    try erased.adjustRadius(1.15, 0.18);

    const typed_erased = typed.erased();
    try std.testing.expectApproxEqAbs(typed_erased.params.radius, erased.params.radius, 1e-6);
    inline for (&.{ typed_erased.camera.position, typed_erased.camera.right, typed_erased.camera.up, typed_erased.camera.forward }, &.{ erased.camera.position, erased.camera.right, erased.camera.up, erased.camera.forward }) |expected, actual| {
        inline for (expected, 0..) |coord, i| {
            try std.testing.expectApproxEqAbs(coord, actual[i], 1e-5);
        }
    }
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
    const before_up = spherical.walkSurfaceUp().?;
    const before_position = spherical.camera.position;
    spherical.turnSurfaceYaw(0.35, 0.95);
    const after_up = spherical.walkSurfaceUp().?;
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
    const before_up = spherical.walkSurfaceUp().?;
    spherical.syncSurfacePitch(1.05);
    const after_up = spherical.walkSurfaceUp().?;
    const orientation = spherical.walkOrientation().?;

    const up_dot = before_up[0] * after_up[0] +
        before_up[1] * after_up[1] +
        before_up[2] * after_up[2] +
        before_up[3] * after_up[3];
    try std.testing.expect(up_dot > 0.999);
    try std.testing.expectApproxEqAbs(@as(f32, 1.05), orientation.pitch, 1e-3);
}

test "tangent normalization rejects non-finite inputs" {
    const nan = std.math.nan(f32);
    try std.testing.expectEqual(@as(?Vec4, null), tryNormalizeTangent(.spherical, .{ nan, 0.0, 0.0, 0.0 }));
    try std.testing.expectEqual(@as(?Vec4, null), tryNormalizeTangent(.hyperbolic, .{ 1.0, nan, 0.0, 0.0 }));
}

test "ambient normalization falls back to the model identity on non-finite input" {
    const nan = std.math.nan(f32);
    const hyper = normalizeAmbient(.hyperbolic, .{ nan, 0.0, 0.0, 0.0 });
    const round = normalizeAmbient(.spherical, .{ 0.0, nan, 0.0, 0.0 });

    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0 }, &hyper);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0 }, &round);
}

test "ambient tangent-basis point builder rejects non-finite travel inputs" {
    const nan = std.math.nan(f32);
    const origin: Vec4 = .{ 1.0, 0.0, 0.0, 0.0 };
    const right: Vec4 = .{ 0.0, 1.0, 0.0, 0.0 };
    const forward: Vec4 = .{ 0.0, 0.0, 0.0, 1.0 };

    const point = ambientFromTangentBasisPoint(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        origin,
        right,
        forward,
        nan,
        0.25,
    ).?;

    try std.testing.expectEqualSlices(f32, &origin, &point);
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
    const far_chart = view.chartCoords(far_ambient);

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

    const model_point = view.sphericalRenderPass(.near).cameraModelPointForAmbient(ambient, .conformal).?;
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

    const model_point = view.sphericalRenderPass(.far).cameraModelPointForAmbient(ambient, .conformal).?;
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
    const far_chart = view.chartCoords(far_ambient);
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

test "typed embed and chart helpers match erased wrappers" {
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const chart = vec3(0.12, -0.07, 0.15);
    const typed_view = try SphericalView.init(
        params,
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const erased_view = typed_view.erased();

    const typed_ambient = typed_view.embedPoint(chart).?;
    const erased_ambient = erased_view.embedPoint(chart).?;
    const typed_ambient_coords = curved_ambient.Round.toCoords(typed_ambient);
    inline for (typed_ambient_coords, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, erased_ambient[i], 1e-6);
    }

    const typed_chart = typed_view.chartCoords(typed_ambient);
    const erased_chart = erased_view.chartCoords(erased_ambient);
    inline for (typed_chart, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, erased_chart[i], 1e-6);
    }
}

test "typed geodesic chart helper matches erased wrapper" {
    const params = Params{
        .radius = 0.32,
        .angular_zoom = 0.72,
        .chart_model = .conformal,
    };
    const typed_view = try HyperView.init(
        params,
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -params.radius * 0.78 },
        .{ 0.0, 0.0, 0.0 },
    );
    const erased_view = typed_view.erased();
    const a = vec3(-0.12, -0.03, 0.08);
    const b = vec3(0.15, 0.09, 0.02);

    const typed_point = typed_view.geodesicChartPoint(a, b, 0.35).?;
    const erased_point = erased_view.geodesicChartPoint(a, b, 0.35).?;
    inline for (typed_point, 0..) |expected, i| {
        try std.testing.expectApproxEqAbs(expected, erased_point[i], 1e-6);
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
    const chart = view.chartCoords(ambient);

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

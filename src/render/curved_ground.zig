const std = @import("std");
const geometry = @import("../geometry.zig");
const projection = @import("projection.zig");

const curved = struct {
    pub const Metric = geometry.curved.Metric;
    pub const Screen = geometry.curved.Screen;
    pub const Vec3 = geometry.curved.Vec3;
    pub const SphericalRenderPass = geometry.curved.SphericalRenderPass;
    pub const HyperView = geometry.curved.HyperView;
    pub const EllipticView = geometry.curved.EllipticView;
    pub const SphericalView = geometry.curved.SphericalView;
    pub const AmbientFor = geometry.curved.AmbientFor;
    pub const TypedCamera = geometry.curved.TypedCamera;
    pub const ambientFromTypedTangentBasisPoint = geometry.curved.ambientFromTypedTangentBasisPoint;
    pub const vec3 = geometry.curved.vec3;
    pub const vec3x = geometry.curved.vec3x;
    pub const vec3y = geometry.curved.vec3y;
    pub const vec3z = geometry.curved.vec3z;
};
const Round = curved.AmbientFor(.spherical);

pub fn TypedGroundBasis(comptime metric: curved.Metric) type {
    const Ambient = curved.AmbientFor(metric);
    return struct {
        origin: Ambient.Vector,
        right: Ambient.Vector,
        forward: Ambient.Vector,
        up: Ambient.Vector,
    };
}

pub const HyperGroundBasis = TypedGroundBasis(.hyperbolic);
pub const EllipticGroundBasis = TypedGroundBasis(.elliptic);
pub const SphericalGroundBasis = TypedGroundBasis(.spherical);

pub const GroundHit = struct {
    distance: f32,
    lateral: f32,
    forward: f32,
};

pub const HyperGroundHit = GroundHit;
pub const SphericalGroundHit = GroundHit;

pub fn hyperbolicGroundBasis(basis: anytype) HyperGroundBasis {
    return switch (@TypeOf(basis)) {
        HyperGroundBasis => basis,
        else => @compileError("expected `HyperGroundBasis`"),
    };
}

fn hyperbolicView(view: anytype) curved.HyperView {
    return switch (@TypeOf(view)) {
        curved.HyperView => view,
        else => @compileError("expected `HyperView`"),
    };
}

pub fn hyperbolicGroundHitForScreenPoint(
    view: anytype,
    basis: HyperGroundBasis,
    screen: curved.Screen,
    point: [2]f32,
) ?HyperGroundHit {
    const hyper = hyperbolicView(view);
    const Hyper = curved.AmbientFor(.hyperbolic);
    const local_dir = inverseGroundScreenDirection(hyper.projection, screen, point) orelse return null;
    const direction = Hyper.add(
        Hyper.add(
            Hyper.scale(hyper.camera.right, curved.vec3x(local_dir)),
            Hyper.scale(hyper.camera.up, curved.vec3y(local_dir)),
        ),
        Hyper.scale(hyper.camera.forward, curved.vec3z(local_dir)),
    );

    const a = Hyper.dot(hyper.camera.position, basis.up);
    const b = Hyper.dot(direction, basis.up);

    // Hyperbolic ray: P(theta) = C*cosh(theta) + D*sinh(theta)
    // Hit ground plane (N): P(theta) . N = 0
    // C.N*cosh(theta) + D.N*sinh(theta) = 0  =>  tanh(theta) = -C.N / D.N
    const tanh_theta = -a / b;
    if (tanh_theta <= 0.0 or tanh_theta >= 1.0) return null;

    const theta = std.math.atanh(tanh_theta);
    const ambient = Hyper.add(
        Hyper.scale(hyper.camera.position, std.math.cosh(theta)),
        Hyper.scale(direction, std.math.sinh(theta)),
    );

    const origin_coord = Hyper.dot(ambient, basis.origin);
    const lateral_coord = Hyper.dot(ambient, basis.right);
    const forward_coord = Hyper.dot(ambient, basis.forward);

    // Coordinate mapping for the Poincare/Exp model ground
    const planar_norm = @sqrt(@max(0.0, lateral_coord * lateral_coord + forward_coord * forward_coord));
    if (planar_norm <= 1e-6) {
        return .{
            .distance = theta * hyper.params.radius,
            .lateral = 0.0,
            .forward = 0.0,
        };
    }

    // In the hyperboloid model, the tangent distance is related to the scale
    // needed to project back to the origin basis.
    const tangent_radius = std.math.atanh(std.math.clamp(planar_norm / origin_coord, 0.0, 0.9999)) * hyper.params.radius;
    const tangent_scale = tangent_radius / planar_norm;

    return .{
        .distance = theta * hyper.params.radius,
        .lateral = lateral_coord * tangent_scale,
        .forward = forward_coord * tangent_scale,
    };
}

pub fn sphericalGroundBasis(basis: anytype) SphericalGroundBasis {
    return switch (@TypeOf(basis)) {
        SphericalGroundBasis => basis,
        else => @compileError("expected `SphericalGroundBasis`"),
    };
}

fn sphericalView(view: anytype) curved.SphericalView {
    return switch (@TypeOf(view)) {
        curved.SphericalView => view,
        else => @compileError("expected `SphericalView`"),
    };
}

pub fn typedWorldGroundBasis(comptime metric: curved.Metric) TypedGroundBasis(metric) {
    const Ambient = curved.AmbientFor(metric);
    return .{
        .origin = Ambient.identity(),
        .right = Ambient.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        .forward = Ambient.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
        .up = Ambient.fromCoords(.{ 0.0, 0.0, 1.0, 0.0 }),
    };
}

pub fn worldSphericalGroundBasis() SphericalGroundBasis {
    return typedWorldGroundBasis(.spherical);
}

pub fn sphericalGroundBasisForPass(pass: curved.SphericalRenderPass) SphericalGroundBasis {
    const basis = worldSphericalGroundBasis();
    return switch (pass) {
        .near => basis,
        .far => .{
            .origin = Round.scale(basis.origin, -1.0),
            .right = basis.right,
            .forward = basis.forward,
            .up = basis.up,
        },
    };
}

pub fn typedWalkGroundBasis(
    view: anytype,
    pitch_angle: f32,
) ?switch (@TypeOf(view)) {
    curved.HyperView => HyperGroundBasis,
    curved.EllipticView => EllipticGroundBasis,
    curved.SphericalView => SphericalGroundBasis,
    else => @compileError("expected typed curved view"),
} {
    const basis = view.walkSurfaceBasis(pitch_angle) orelse return null;
    return .{
        .origin = view.camera.position,
        .right = basis.right,
        .forward = basis.forward,
        .up = basis.up,
    };
}

pub fn ambientPointForBasis(
    view: anytype,
    basis: anytype,
    lateral: f32,
    forward_distance: f32,
) ?switch (@TypeOf(view)) {
    curved.HyperView => curved.AmbientFor(.hyperbolic).Vector,
    curved.EllipticView => curved.AmbientFor(.elliptic).Vector,
    curved.SphericalView => curved.AmbientFor(.spherical).Vector,
    else => @compileError("expected typed curved view"),
} {
    switch (@TypeOf(view)) {
        curved.HyperView => {
            return curved.ambientFromTypedTangentBasisPoint(
                .hyperbolic,
                view.params,
                basis.origin,
                basis.right,
                basis.forward,
                lateral,
                forward_distance,
            );
        },
        curved.EllipticView => {
            return curved.ambientFromTypedTangentBasisPoint(
                .elliptic,
                view.params,
                basis.origin,
                basis.right,
                basis.forward,
                lateral,
                forward_distance,
            );
        },
        curved.SphericalView => {
            return curved.ambientFromTypedTangentBasisPoint(
                .spherical,
                view.params,
                basis.origin,
                basis.right,
                basis.forward,
                lateral,
                forward_distance,
            );
        },
        else => unreachable,
    }
}

pub fn signedSphericalGroundBasisForView(view: anytype, basis: SphericalGroundBasis) SphericalGroundBasis {
    const spherical = sphericalView(view);
    if (spherical.scene_sign >= 0.0) return basis;
    return .{
        .origin = Round.scale(basis.origin, -1.0),
        .right = Round.scale(basis.right, -1.0),
        .forward = Round.scale(basis.forward, -1.0),
        .up = Round.scale(basis.up, -1.0),
    };
}

pub fn inverseStereographicScreenDirection(screen: curved.Screen, point: [2]f32) curved.Vec3 {
    const aspect = @as(f32, @floatFromInt(screen.width)) / @as(f32, @floatFromInt(screen.height * 2));
    const x_raw = ((point[0] / @as(f32, @floatFromInt(screen.width))) * 2.0 - 1.0) * aspect / screen.zoom;
    const y_raw = (1.0 - (point[1] / (@as(f32, @floatFromInt(screen.height)) * 0.5))) / screen.zoom;
    const denom = x_raw * x_raw + y_raw * y_raw + 4.0;
    return curved.vec3(
        4.0 * x_raw / denom,
        4.0 * y_raw / denom,
        (4.0 - x_raw * x_raw - y_raw * y_raw) / denom,
    );
}

pub fn inverseWrappedScreenDirection(screen: curved.Screen, point: [2]f32) curved.Vec3 {
    const x_unit = ((point[0] / @as(f32, @floatFromInt(screen.width))) - 0.5) / screen.zoom + 0.5;
    const azimuth = (x_unit - 0.5) * (@as(f32, std.math.pi) * 2.0);
    const elevation = (1.0 - (point[1] / (@as(f32, @floatFromInt(screen.height)) * 0.5))) *
        ((@as(f32, std.math.pi) * 0.5) / screen.zoom);
    const planar = @cos(elevation);
    return curved.vec3(
        @sin(azimuth) * planar,
        @sin(elevation),
        @cos(azimuth) * planar,
    );
}

pub fn inverseGroundScreenDirection(
    projection_mode: projection.DirectionProjection,
    screen: curved.Screen,
    point: [2]f32,
) ?curved.Vec3 {
    return switch (projection_mode) {
        .stereographic => inverseStereographicScreenDirection(screen, point),
        .wrapped => inverseWrappedScreenDirection(screen, point),
        else => null,
    };
}

pub fn sphericalGroundHitForScreenPoint(
    view: anytype,
    basis_input: SphericalGroundBasis,
    screen: curved.Screen,
    point: [2]f32,
) ?SphericalGroundHit {
    const spherical = sphericalView(view);
    const basis = signedSphericalGroundBasisForView(spherical, basis_input);
    const local_dir = inverseGroundScreenDirection(spherical.projection, screen, point) orelse return null;
    const direction = Round.add(
        Round.add(
            Round.scale(spherical.camera.right, curved.vec3x(local_dir)),
            Round.scale(spherical.camera.up, curved.vec3y(local_dir)),
        ),
        Round.scale(spherical.camera.forward, curved.vec3z(local_dir)),
    );

    const a = Round.dot(spherical.camera.position, basis.up);
    const b = Round.dot(direction, basis.up);
    if (@abs(a) <= 1e-6 and @abs(b) <= 1e-6) return null;

    var theta = std.math.atan2(-a, b);
    if (theta <= 1e-4) theta += @as(f32, std.math.pi);
    if (theta > @as(f32, std.math.pi)) theta -= @as(f32, std.math.pi);
    if (theta <= 1e-4) return null;

    const ambient = Round.add(
        Round.scale(spherical.camera.position, @cos(theta)),
        Round.scale(direction, @sin(theta)),
    );
    const origin_coord = Round.dot(ambient, basis.origin);
    const lateral_coord = Round.dot(ambient, basis.right);
    const forward_coord = Round.dot(ambient, basis.forward);
    const planar_norm = @sqrt(lateral_coord * lateral_coord + forward_coord * forward_coord);
    if (planar_norm <= 1e-6) {
        return .{
            .distance = theta * spherical.params.radius,
            .lateral = 0.0,
            .forward = 0.0,
        };
    }

    const tangent_radius = std.math.atan2(planar_norm, origin_coord) * spherical.params.radius;
    const tangent_scale = tangent_radius / planar_norm;
    return .{
        .distance = theta * spherical.params.radius,
        .lateral = lateral_coord * tangent_scale,
        .forward = forward_coord * tangent_scale,
    };
}

pub fn checkerCoord(value: f32, cell_size: f32) i32 {
    return @as(i32, @intFromFloat(@floor(value / cell_size)));
}

pub fn curvedGroundHitForScreenPoint(
    view: anytype,
    basis: anytype,
    screen: curved.Screen,
    point: [2]f32,
) ?GroundHit {
    return switch (@TypeOf(view)) {
        curved.HyperView => hyperbolicGroundHitForScreenPoint(view, basis, screen, point),
        curved.SphericalView => sphericalGroundHitForScreenPoint(view, basis, screen, point),
        else => @compileError("unsupported view type for ground hit"),
    };
}

pub fn gridLineStrength(value: f32, cell_size: f32, line_half_width: f32) f32 {
    const wrapped = @mod(value, cell_size);
    const distance = @min(wrapped, cell_size - wrapped);
    return std.math.clamp(1.0 - distance / line_half_width, 0.0, 1.0);
}

test "inverse screen directions point forward at screen center" {
    const screen = curved.Screen{ .width = 160, .height = 90, .zoom = 1.0 };
    const center = .{ @as(f32, 80.0), @as(f32, 45.0) };

    const stereo = inverseStereographicScreenDirection(screen, center);
    try std.testing.expectApproxEqAbs(0.0, curved.vec3x(stereo), 1e-6);
    try std.testing.expectApproxEqAbs(0.0, curved.vec3y(stereo), 1e-6);
    try std.testing.expectApproxEqAbs(1.0, curved.vec3z(stereo), 1e-6);

    const wrapped = inverseWrappedScreenDirection(screen, center);
    try std.testing.expectApproxEqAbs(0.0, curved.vec3x(wrapped), 1e-6);
    try std.testing.expectApproxEqAbs(0.0, curved.vec3y(wrapped), 1e-6);
    try std.testing.expectApproxEqAbs(1.0, curved.vec3z(wrapped), 1e-6);
}

test "signedSphericalGroundBasisForView flips spherical negative scene" {
    var view = try curved.SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        curved.vec3(0.0, 0.0, -0.82),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const basis = worldSphericalGroundBasis();
    const positive = signedSphericalGroundBasisForView(view, basis);
    view.scene_sign = -1.0;
    const negative = signedSphericalGroundBasisForView(view, basis);

    try std.testing.expectApproxEqAbs(-Round.w(positive.origin), Round.w(negative.origin), 1e-6);
    try std.testing.expectApproxEqAbs(-Round.x(positive.right), Round.x(negative.right), 1e-6);
    try std.testing.expectApproxEqAbs(-Round.z(positive.forward), Round.z(negative.forward), 1e-6);
    try std.testing.expectApproxEqAbs(-Round.y(positive.up), Round.y(negative.up), 1e-6);
}

test "sphericalGroundHitForScreenPoint returns centered finite hit" {
    const view = try curved.SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        curved.vec3(0.0, 0.0, -0.82),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const basis = worldSphericalGroundBasis();
    const screen = curved.Screen{ .width = 160, .height = 90, .zoom = 1.0 };
    const hit = sphericalGroundHitForScreenPoint(view, basis, screen, .{ 80.0, 45.0 }) orelse return error.TestUnexpectedResult;

    try std.testing.expect(hit.distance > 0.0);
    try std.testing.expectApproxEqAbs(0.0, hit.lateral, 1e-4);
    try std.testing.expect(std.math.isFinite(hit.forward));
}

test "hyperbolicGroundHitForScreenPoint returns centered hit" {
    const params = curved.Params{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal };
    const view = try curved.HyperView.init(
        params,
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        curved.vec3(0.0, 0.0, -params.radius * 0.78),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const basis = typedWorldGroundBasis(.hyperbolic);
    const screen = curved.Screen{ .width = 160, .height = 90, .zoom = params.angular_zoom };
    const hit = hyperbolicGroundHitForScreenPoint(view, basis, screen, .{ 80.0, 45.0 }) orelse return error.TestUnexpectedResult;

    try std.testing.expect(hit.distance > 0.0);
    try std.testing.expectApproxEqAbs(0.0, hit.lateral, 1e-4);
}

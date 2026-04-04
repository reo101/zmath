const std = @import("std");
const curved = @import("../geometry/constant_curvature.zig");
const projection = @import("projection.zig");
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

pub const GroundBasis = struct {
    origin: curved.Vec4,
    right: curved.Vec4,
    forward: curved.Vec4,
    up: curved.Vec4,
};

pub const HyperGroundBasis = TypedGroundBasis(.hyperbolic);
pub const EllipticGroundBasis = TypedGroundBasis(.elliptic);
pub const SphericalGroundBasis = TypedGroundBasis(.spherical);

pub const SphericalGroundHit = struct {
    distance: f32,
    lateral: f32,
    forward: f32,
};

fn ambientCoords(v: anytype) curved.Vec4 {
    return if (@TypeOf(v) == curved.Vec4) v else v.coeffsArray();
}

pub fn erasedGroundBasis(basis: anytype) GroundBasis {
    return .{
        .origin = ambientCoords(basis.origin),
        .right = ambientCoords(basis.right),
        .forward = ambientCoords(basis.forward),
        .up = ambientCoords(basis.up),
    };
}

pub fn sphericalGroundBasis(basis: anytype) SphericalGroundBasis {
    return switch (@TypeOf(basis)) {
        SphericalGroundBasis => basis,
        GroundBasis => .{
            .origin = Round.fromCoords(basis.origin),
            .right = Round.fromCoords(basis.right),
            .forward = Round.fromCoords(basis.forward),
            .up = Round.fromCoords(basis.up),
        },
        else => sphericalGroundBasis(erasedGroundBasis(basis)),
    };
}

fn sphericalView(view: anytype) curved.SphericalView {
    return switch (@TypeOf(view)) {
        curved.SphericalView => view,
        curved.View => view.typed(.spherical),
        else => @compileError("expected `SphericalView` or erased curved `View`"),
    };
}

pub fn worldGroundBasis() GroundBasis {
    return erasedGroundBasis(typedWorldGroundBasis(.hyperbolic));
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

pub fn walkGroundBasis(view: anytype, pitch_angle: f32) ?GroundBasis {
    switch (@TypeOf(view)) {
        curved.HyperView, curved.EllipticView, curved.SphericalView => {
            const basis = typedWalkGroundBasis(view, pitch_angle) orelse return null;
            return erasedGroundBasis(basis);
        },
        else => {},
    }
    const basis = view.walkSurfaceBasis(pitch_angle) orelse return null;
    return .{
        .origin = ambientCoords(view.camera.position),
        .right = ambientCoords(basis.right),
        .forward = ambientCoords(basis.forward),
        .up = ambientCoords(basis.up),
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
) ?curved.Vec4 {
    switch (@TypeOf(view)) {
        curved.HyperView => {
            const ambient = curved.ambientFromTypedTangentBasisPoint(
                .hyperbolic,
                view.params,
                basis.origin,
                basis.right,
                basis.forward,
                lateral,
                forward_distance,
            ) orelse return null;
            return ambient.coeffsArray();
        },
        curved.EllipticView => {
            const ambient = curved.ambientFromTypedTangentBasisPoint(
                .elliptic,
                view.params,
                basis.origin,
                basis.right,
                basis.forward,
                lateral,
                forward_distance,
            ) orelse return null;
            return ambient.coeffsArray();
        },
        curved.SphericalView => {
            const ambient = curved.ambientFromTypedTangentBasisPoint(
                .spherical,
                view.params,
                basis.origin,
                basis.right,
                basis.forward,
                lateral,
                forward_distance,
            ) orelse return null;
            return ambient.coeffsArray();
        },
        else => {
            const erased_basis = erasedGroundBasis(basis);
            return curved.ambientFromTangentBasisPoint(
                view.metric,
                view.params,
                erased_basis.origin,
                erased_basis.right,
                erased_basis.forward,
                lateral,
                forward_distance,
            );
        },
    }
}

pub fn signedGroundBasisForView(view: anytype, basis: GroundBasis) GroundBasis {
    switch (@TypeOf(view)) {
        curved.SphericalView => if (view.scene_sign < 0.0) {
            return .{
                .origin = curved.ambientScale(.spherical, basis.origin, -1.0),
                .right = curved.ambientScale(.spherical, basis.right, -1.0),
                .forward = curved.ambientScale(.spherical, basis.forward, -1.0),
                .up = curved.ambientScale(.spherical, basis.up, -1.0),
            };
        },
        curved.View => {
            if (view.metric != .spherical or view.scene_sign >= 0.0) return basis;
            return .{
                .origin = curved.ambientScale(.spherical, basis.origin, -1.0),
                .right = curved.ambientScale(.spherical, basis.right, -1.0),
                .forward = curved.ambientScale(.spherical, basis.forward, -1.0),
                .up = curved.ambientScale(.spherical, basis.up, -1.0),
            };
        },
        else => {},
    }
    return basis;
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

test "signedGroundBasisForView flips spherical negative scene" {
    var view = try curved.SphericalView.init(
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        curved.vec3(0.0, 0.0, -0.82),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const basis = worldGroundBasis();
    const positive = signedGroundBasisForView(view, basis);
    view.scene_sign = -1.0;
    const negative = signedGroundBasisForView(view, basis);

    try std.testing.expectApproxEqAbs(-positive.origin[0], negative.origin[0], 1e-6);
    try std.testing.expectApproxEqAbs(-positive.right[1], negative.right[1], 1e-6);
    try std.testing.expectApproxEqAbs(-positive.forward[3], negative.forward[3], 1e-6);
    try std.testing.expectApproxEqAbs(-positive.up[2], negative.up[2], 1e-6);
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

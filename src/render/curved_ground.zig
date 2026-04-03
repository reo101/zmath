const std = @import("std");
const curved = @import("../geometry/constant_curvature.zig");
const projection = @import("projection.zig");

pub const GroundBasis = struct {
    origin: curved.Vec4,
    right: curved.Vec4,
    forward: curved.Vec4,
    up: curved.Vec4,
};

pub const SphericalGroundHit = struct {
    distance: f32,
    lateral: f32,
    forward: f32,
};

pub fn worldGroundBasis() GroundBasis {
    return .{
        .origin = .{ 1.0, 0.0, 0.0, 0.0 },
        .right = .{ 0.0, 1.0, 0.0, 0.0 },
        .forward = .{ 0.0, 0.0, 0.0, 1.0 },
        .up = .{ 0.0, 0.0, 1.0, 0.0 },
    };
}

pub fn sphericalGroundBasisForPass(pass: curved.SphericalRenderPass) GroundBasis {
    const basis = worldGroundBasis();
    return switch (pass) {
        .near => basis,
        .far => .{
            .origin = curved.ambientScale(.spherical, basis.origin, -1.0),
            .right = basis.right,
            .forward = basis.forward,
            .up = basis.up,
        },
    };
}

pub fn walkGroundBasis(view: curved.View, pitch_angle: f32) ?GroundBasis {
    const basis = view.walkSurfaceBasis(pitch_angle) orelse return null;
    return .{
        .origin = view.camera.position,
        .right = basis.right,
        .forward = basis.forward,
        .up = basis.up,
    };
}

pub fn signedGroundBasisForView(view: curved.View, basis: GroundBasis) GroundBasis {
    if (view.metric != .spherical or view.scene_sign >= 0.0) return basis;
    return .{
        .origin = curved.ambientScale(view.metric, basis.origin, -1.0),
        .right = curved.ambientScale(view.metric, basis.right, -1.0),
        .forward = curved.ambientScale(view.metric, basis.forward, -1.0),
        .up = curved.ambientScale(view.metric, basis.up, -1.0),
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
    view: curved.View,
    basis_input: GroundBasis,
    screen: curved.Screen,
    point: [2]f32,
) ?SphericalGroundHit {
    if (view.metric != .spherical) return null;

    const basis = signedGroundBasisForView(view, basis_input);
    const local_dir = inverseGroundScreenDirection(view.projection, screen, point) orelse return null;
    const direction = curved.ambientAdd(
        .spherical,
        curved.ambientAdd(
            .spherical,
            curved.ambientScale(.spherical, view.camera.right, curved.vec3x(local_dir)),
            curved.ambientScale(.spherical, view.camera.up, curved.vec3y(local_dir)),
        ),
        curved.ambientScale(.spherical, view.camera.forward, curved.vec3z(local_dir)),
    );

    const a = curved.ambientDot(.spherical, view.camera.position, basis.up);
    const b = curved.ambientDot(.spherical, direction, basis.up);
    if (@abs(a) <= 1e-6 and @abs(b) <= 1e-6) return null;

    var theta = std.math.atan2(-a, b);
    if (theta <= 1e-4) theta += @as(f32, std.math.pi);
    if (theta > @as(f32, std.math.pi)) theta -= @as(f32, std.math.pi);
    if (theta <= 1e-4) return null;

    const ambient = curved.ambientAdd(
        .spherical,
        curved.ambientScale(.spherical, view.camera.position, @cos(theta)),
        curved.ambientScale(.spherical, direction, @sin(theta)),
    );
    const origin_coord = curved.ambientDot(.spherical, ambient, basis.origin);
    const lateral_coord = curved.ambientDot(.spherical, ambient, basis.right);
    const forward_coord = curved.ambientDot(.spherical, ambient, basis.forward);
    const planar_norm = @sqrt(lateral_coord * lateral_coord + forward_coord * forward_coord);
    if (planar_norm <= 1e-6) {
        return .{
            .distance = theta * view.params.radius,
            .lateral = 0.0,
            .forward = 0.0,
        };
    }

    const tangent_radius = std.math.atan2(planar_norm, origin_coord) * view.params.radius;
    const tangent_scale = tangent_radius / planar_norm;
    return .{
        .distance = theta * view.params.radius,
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
    var view = try curved.View.init(
        .spherical,
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

test "sphericalGroundHitForScreenPoint returns centered finite hit" {
    const view = try curved.View.init(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        curved.vec3(0.0, 0.0, -0.82),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const basis = worldGroundBasis();
    const screen = curved.Screen{ .width = 160, .height = 90, .zoom = 1.0 };
    const hit = sphericalGroundHitForScreenPoint(view, basis, screen, .{ 80.0, 45.0 }) orelse return error.TestUnexpectedResult;

    try std.testing.expect(hit.distance > 0.0);
    try std.testing.expectApproxEqAbs(0.0, hit.lateral, 1e-4);
    try std.testing.expect(std.math.isFinite(hit.forward));
}

const std = @import("std");
const curved_types = @import("curved_types.zig");
const curved_charts = @import("curved_charts.zig");
const curved_tangent = @import("curved_tangent.zig");

pub const Metric = curved_types.Metric;
pub const Params = curved_types.Params;
pub const Vec3 = curved_types.Vec3;
pub const AmbientFor = curved_types.AmbientFor;

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
    return curved_tangent.normalizeAmbient(metric, position);
}

pub fn sphericalAmbientFromGroundHeightPoint(params: Params, local_input: anytype) AmbientFor(.spherical).Vector {
    const Round = AmbientFor(.spherical);
    const local = curved_charts.coerceVec3(local_input);
    const base = ambientFromTypedTangentBasisPoint(
        .spherical,
        params,
        Round.identity(),
        Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
        curved_charts.vec3x(local),
        curved_charts.vec3z(local),
    ) orelse return Round.identity();
    if (@abs(curved_charts.vec3y(local)) <= 1e-6) return base;

    const up = curved_tangent.worldUpAt(.spherical, base) orelse return base;
    const normalized_height = curved_charts.vec3y(local) / params.radius;
    return curved_tangent.normalizeAmbient(
        .spherical,
        Round.add(
            Round.scale(base, @cos(normalized_height)),
            Round.scale(up, @sin(normalized_height)),
        ),
    );
}

test "ambient from tangent basis point matches spherical horizontal ground mapping at the origin" {
    const Round = AmbientFor(.spherical);
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = curved_charts.vec3(0.31, 0.0, -0.22);
    const ambient = ambientFromTypedTangentBasisPoint(
        .spherical,
        params,
        Round.identity(),
        Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
        curved_charts.vec3x(local),
        curved_charts.vec3z(local),
    ).?;
    const expected = sphericalAmbientFromGroundHeightPoint(params, local);
    inline for (AmbientFor(.spherical).toCoords(expected), AmbientFor(.spherical).toCoords(ambient)) |coord, actual| {
        try std.testing.expectApproxEqAbs(coord, actual, 1e-5);
    }
}

test "ambient tangent-basis point builder rejects non-finite travel inputs" {
    const nan = std.math.nan(f32);
    const origin = AmbientFor(.spherical).fromCoords(.{ 1.0, 0.0, 0.0, 0.0 });
    const right = AmbientFor(.spherical).fromCoords(.{ 0.0, 1.0, 0.0, 0.0 });
    const forward = AmbientFor(.spherical).fromCoords(.{ 0.0, 0.0, 0.0, 1.0 });

    const point = ambientFromTypedTangentBasisPoint(
        .spherical,
        .{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal },
        origin,
        right,
        forward,
        nan,
        0.25,
    ).?;

    try std.testing.expectEqualSlices(f32, &AmbientFor(.spherical).toCoords(origin), &AmbientFor(.spherical).toCoords(point));
}

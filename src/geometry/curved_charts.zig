const std = @import("std");
const curved_types = @import("curved_types.zig");
const hpga = @import("../flavours/hpga.zig");
const epga = @import("../flavours/epga.zig");

pub const Metric = curved_types.Metric;
pub const Params = curved_types.Params;
pub const Vec3 = curved_types.Vec3;
pub const AmbientFor = curved_types.AmbientFor;

pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return Vec3.init(.{ x, y, z });
}

pub fn vec3x(v: Vec3) f32 {
    return v.named().e1;
}

pub fn vec3y(v: Vec3) f32 {
    return v.named().e2;
}

pub fn vec3z(v: Vec3) f32 {
    return v.named().e3;
}

pub fn vec3Coords(v: Vec3) [3]f32 {
    return .{ vec3x(v), vec3y(v), vec3z(v) };
}

pub fn coerceVec3(value: anytype) Vec3 {
    return if (@TypeOf(value) == Vec3) value else Vec3.init(value);
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

pub fn maxSphericalDistance(params: Params) f32 {
    return @as(f32, std.math.pi) * params.radius;
}

pub fn hemisphereDistance(params: Params) f32 {
    return maxSphericalDistance(params) * 0.5;
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

fn normalizeAmbient(comptime metric: Metric, ambient: AmbientFor(metric).Vector) AmbientFor(metric).Vector {
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

pub fn embedPoint(
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

pub fn chartCoords(
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

pub fn geodesicAmbientPoint(
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
            return normalizeAmbient(metric, p);
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
            return normalizeAmbient(metric, p);
        },
    };
}

pub fn sphericalAmbientFromLocalPoint(params: Params, local_input: anytype) AmbientFor(.spherical).Vector {
    const Round = AmbientFor(.spherical);
    const local = coerceVec3(local_input);
    const local_radius = local.magnitude();
    if (local_radius <= 1e-6) return Round.identity();

    const theta = local_radius / params.radius;
    const spatial_scale = @sin(theta) / local_radius;
    return Round.fromCoords(.{
        @cos(theta),
        vec3x(local) * spatial_scale,
        vec3y(local) * spatial_scale,
        vec3z(local) * spatial_scale,
    });
}

test "chart coordinates roundtrip for hyperbolic and spherical spaces" {
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
    const Round = AmbientFor(.spherical);
    const params = Params{
        .radius = 1.48,
        .angular_zoom = 1.0,
        .chart_model = .conformal,
    };
    const local = vec3(0.31, -0.22, 0.18);
    const ambient = sphericalAmbientFromLocalPoint(params, local);
    const local_distance = local.magnitude();
    const spherical_distance = params.radius * std.math.acos(std.math.clamp(Round.w(ambient), -1.0, 1.0));

    try std.testing.expectApproxEqAbs(local_distance, spherical_distance, 1e-5);
}

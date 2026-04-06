const std = @import("std");
const curved_types = @import("curved_types.zig");

pub const Metric = curved_types.Metric;
pub const AmbientFor = curved_types.AmbientFor;
pub const TypedCamera = curved_types.TypedCamera;

pub fn zero(comptime metric: Metric) AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    return Ambient.scale(Ambient.identity(), 0.0);
}

pub fn basisVector(comptime metric: Metric, coords: anytype) AmbientFor(metric).Vector {
    return AmbientFor(metric).fromCoords(coords);
}

pub fn tryNormalizeTangent(comptime metric: Metric, v: AmbientFor(metric).Vector) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    if (!Ambient.isFinite(v)) return null;
    const n2 = Ambient.dot(v, v);
    if (!std.math.isFinite(n2) or n2 <= 1e-6) return null;
    return Ambient.scale(v, 1.0 / @sqrt(n2));
}

pub fn projectToTangent(
    comptime metric: Metric,
    position: AmbientFor(metric).Vector,
    candidate: AmbientFor(metric).Vector,
) AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    if (!Ambient.isFinite(position) or !Ambient.isFinite(candidate)) return zero(metric);
    const denom = Ambient.dot(position, position);
    if (!std.math.isFinite(denom) or @abs(denom) <= 1e-6) return zero(metric);
    const along = Ambient.dot(candidate, position) / denom;
    if (!std.math.isFinite(along)) return zero(metric);
    return Ambient.sub(candidate, Ambient.scale(position, along));
}

pub fn orthonormalCandidate(
    comptime metric: Metric,
    position: AmbientFor(metric).Vector,
    candidate: AmbientFor(metric).Vector,
    refs: []const AmbientFor(metric).Vector,
) ?AmbientFor(metric).Vector {
    const Ambient = AmbientFor(metric);
    var v = projectToTangent(metric, position, candidate);
    for (refs) |r| {
        v = Ambient.sub(v, Ambient.scale(r, Ambient.dot(v, r)));
    }
    return tryNormalizeTangent(metric, v);
}

pub fn reorthonormalize(comptime metric: Metric, camera: *TypedCamera(metric)) void {
    camera.forward = orthonormalCandidate(metric, camera.position, camera.forward, &.{}) orelse camera.forward;
    camera.right = orthonormalCandidate(metric, camera.position, camera.right, &.{camera.forward}) orelse camera.right;
    camera.up = orthonormalCandidate(metric, camera.position, camera.up, &.{ camera.forward, camera.right }) orelse camera.up;
}

pub fn normalizeAmbient(comptime metric: Metric, ambient: AmbientFor(metric).Vector) AmbientFor(metric).Vector {
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

pub fn worldUpAt(comptime metric: Metric, position: AmbientFor(metric).Vector) ?AmbientFor(metric).Vector {
    return orthonormalCandidate(metric, position, basisVector(metric, .{ 0.0, 0.0, 1.0, 0.0 }), &.{}) orelse
        orthonormalCandidate(metric, position, basisVector(metric, .{ 0.0, 0.0, 0.0, 1.0 }), &.{});
}

test "tangent normalization rejects non-finite inputs" {
    const nan = std.math.nan(f32);
    try std.testing.expect(tryNormalizeTangent(.spherical, AmbientFor(.spherical).fromCoords(.{ nan, 0.0, 0.0, 0.0 })) == null);
    try std.testing.expect(tryNormalizeTangent(.hyperbolic, AmbientFor(.hyperbolic).fromCoords(.{ 1.0, nan, 0.0, 0.0 })) == null);
}

test "ambient normalization falls back to the model identity on non-finite input" {
    const nan = std.math.nan(f32);
    const hyper = AmbientFor(.hyperbolic).toCoords(normalizeAmbient(.hyperbolic, AmbientFor(.hyperbolic).fromCoords(.{ nan, 0.0, 0.0, 0.0 })));
    const round = AmbientFor(.spherical).toCoords(normalizeAmbient(.spherical, AmbientFor(.spherical).fromCoords(.{ 0.0, nan, 0.0, 0.0 })));

    const hyper_array = hyper.asArray();
    const round_array = round.asArray();
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0 }, &hyper_array);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0 }, &round_array);
}

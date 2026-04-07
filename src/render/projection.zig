const std = @import("std");
const ga = @import("../ga.zig");
const multivector = ga.multivector;

const stereographic_extent_limit_factor: f32 = 4.0;

pub const DirectionProjection = enum {
    gnomonic,
    stereographic,
    orthographic,
    wrapped,
};

pub const EuclideanProjection = enum {
    perspective,
    isometric,
};

pub fn euclideanProjectionDepthOffset(projection: EuclideanProjection) f32 {
    return switch (projection) {
        .perspective => 30.0,
        .isometric => 6.0,
    };
}

pub fn directionProjectionLabel(projection: DirectionProjection) []const u8 {
    return switch (projection) {
        .gnomonic => "gnom",
        .stereographic => "stereo",
        .orthographic => "ortho",
        .wrapped => "wrap",
    };
}

pub fn projectEuclidean(
    p: anytype,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
    projection: EuclideanProjection,
) ?[2]f32 {
    multivector.ensureMultivector(@TypeOf(p));

    const n = p.named();
    const x_raw = n.e1;
    const y_raw = n.e2;
    const z_raw = n.e3;

    const z_offset = euclideanProjectionDepthOffset(projection);
    const dist = z_raw + z_offset;
    if (projection == .perspective and dist <= 0.1) return null;

    const scale = if (projection == .perspective) (zoom / dist) else (zoom / z_offset);
    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));

    const x = (x_raw * scale / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_raw * scale) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    return .{ x, y };
}

pub fn projectDirection(
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    if (z_dir <= 1e-4) return null;

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (x_dir * zoom / (z_dir * aspect) + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_dir * zoom / z_dir) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    return .{ x, y };
}

pub fn projectStereographicDirection(
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    const radius = @sqrt(x_dir * x_dir + y_dir * y_dir + z_dir * z_dir);
    if (radius <= 1e-6) return null;

    const nx = x_dir / radius;
    const ny = y_dir / radius;
    const nz = z_dir / radius;
    const denom = 1.0 + nz;
    if (denom <= 1e-4) return null;

    const x_raw = nx * (2.0 / denom);
    const y_raw = ny * (2.0 / denom);
    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (x_raw * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_raw * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    if (!projectedPointWithinReasonableBounds(.stereographic, .{ x, y }, canvas_width, canvas_height)) return null;
    return .{ x, y };
}

pub fn projectOrthographicDirection(
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    const radius = @sqrt(x_dir * x_dir + y_dir * y_dir + z_dir * z_dir);
    if (radius <= 1e-6) return null;

    const nx = x_dir / radius;
    const ny = y_dir / radius;
    const nz = z_dir / radius;
    if (nz <= 1e-4) return null;

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (nx * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - ny * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    return .{ x, y };
}

pub fn projectAngularDirection(
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    if (z_dir <= 1e-4) return null;

    const radius = @sqrt(x_dir * x_dir + y_dir * y_dir + z_dir * z_dir);
    if (radius <= 1e-6) return null;

    const nx = x_dir / radius;
    const ny = y_dir / radius;
    const nz = z_dir / radius;
    const lateral = @sqrt(nx * nx + nz * nz);
    const x_raw = std.math.atan2(nx, nz);
    const y_raw = std.math.atan2(ny, @max(lateral, 1e-6));

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (x_raw * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_raw * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    return .{ x, y };
}

pub fn projectWrappedAngularDirection(
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    const radius = @sqrt(x_dir * x_dir + y_dir * y_dir + z_dir * z_dir);
    if (radius <= 1e-6) return null;

    const nx = x_dir / radius;
    const ny = y_dir / radius;
    const nz = z_dir / radius;
    const lateral = @sqrt(nx * nx + nz * nz);

    const azimuth = std.math.atan2(nx, nz);
    const elevation = std.math.atan2(ny, @max(lateral, 1e-6));
    var x_unit = azimuth / (@as(f32, std.math.pi) * 2.0) + 0.5;
    if (x_unit >= 1.0) x_unit -= 1.0;
    const y_raw = (elevation / (@as(f32, std.math.pi) * 0.5)) * zoom;

    const x = ((x_unit - 0.5) * zoom + 0.5) * @as(f32, @floatFromInt(canvas_width));
    const y = (1.0 - y_raw) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    return .{ x, y };
}

pub fn projectDirectionWith(
    projection: DirectionProjection,
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    return switch (projection) {
        .gnomonic => projectDirection(x_dir, y_dir, z_dir, canvas_width, canvas_height, zoom),
        .stereographic => projectStereographicDirection(x_dir, y_dir, z_dir, canvas_width, canvas_height, zoom),
        .orthographic => projectOrthographicDirection(x_dir, y_dir, z_dir, canvas_width, canvas_height, zoom),
        .wrapped => projectWrappedAngularDirection(x_dir, y_dir, z_dir, canvas_width, canvas_height, zoom),
    };
}

fn projectedPointWithinReasonableBounds(
    projection: DirectionProjection,
    point: [2]f32,
    canvas_width: usize,
    canvas_height: usize,
) bool {
    return switch (projection) {
        .stereographic => {
            const limit = @as(f32, @floatFromInt(@max(canvas_width, canvas_height))) * stereographic_extent_limit_factor;
            return point[0] >= -limit and
                point[0] <= @as(f32, @floatFromInt(canvas_width)) + limit and
                point[1] >= -limit and
                point[1] <= @as(f32, @floatFromInt(canvas_height)) + limit;
        },
        else => true,
    };
}

test "wrapped angular projection spans the full horizontal circle" {
    const width: usize = 160;
    const height: usize = 90;

    const forward = projectWrappedAngularDirection(0.0, 0.0, 1.0, width, height, 1.0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), forward[0], 1e-4);

    const right = projectWrappedAngularDirection(1.0, 0.0, 0.0, width, height, 1.0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), right[0], 1e-4);

    const left = projectWrappedAngularDirection(-1.0, 0.0, 0.0, width, height, 1.0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), left[0], 1e-4);

    const back = projectWrappedAngularDirection(0.0, 0.0, -1.0, width, height, 1.0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), back[0], 1e-4);
}

test "stereographic projection rejects points too close to the pole singularity" {
    const width: usize = 160;
    const height: usize = 90;
    try std.testing.expect(projectStereographicDirection(0.05, 0.0, -0.9987492, width, height, 1.0) == null);
}

/// Projects a point using PGA universal projection formula.
/// P' = (Eye v Point) ^ Screen
pub fn projectPGA(camera: anytype, p: anytype, canvas_width: usize, canvas_height: usize, zoom: f32) ?[2]f32 {
    multivector.ensureMultivector(@TypeOf(p));

    const ray = camera.eye.join(p);
    const p_prime_mv = ray.wedge(camera.screen);
    const p_prime = p_prime_mv.gradePart(3);
    const n = p_prime.named();

    const w = n.e123;
    if (@abs(w) < 1e-6) return null;

    const x_coord = n.e234 / w;
    const y_coord = n.e314 / w;
    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (x_coord * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_coord * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);
    return .{ x, y };
}

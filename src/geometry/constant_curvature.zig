const std = @import("std");
const ga = @import("ga");

pub const Metric = enum {
    spherical,
    hyperbolic,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn add(self: Vec3, rhs: Vec3) Vec3 {
        return .{ .x = self.x + rhs.x, .y = self.y + rhs.y, .z = self.z + rhs.z };
    }

    pub fn scale(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }
};

pub const Vec4 = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,

    pub fn add(self: Vec4, rhs: Vec4) Vec4 {
        return .{ .w = self.w + rhs.w, .x = self.x + rhs.x, .y = self.y + rhs.y, .z = self.z + rhs.z };
    }

    pub fn sub(self: Vec4, rhs: Vec4) Vec4 {
        return .{ .w = self.w - rhs.w, .x = self.x - rhs.x, .y = self.y - rhs.y, .z = self.z - rhs.z };
    }

    pub fn scale(self: Vec4, s: f32) Vec4 {
        return .{ .w = self.w * s, .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub fn asArray(self: Vec4) [4]f32 {
        return .{ self.w, self.x, self.y, self.z };
    }
};

/// Ambient orthonormal camera frame. Direct field initialization is unchecked;
/// use frameFromChart() or frameFromProjectiveChart() for checked construction.
pub const Frame = struct {
    metric: Metric,
    radius: f32,
    origin: Vec4,
    right: Vec4,
    up: Vec4,
    forward: Vec4,
};

fn checkedModelPoint(metric: Metric, point: Vec4) ?Vec4 {
    const expected: f32 = if (metric == .spherical) 1 else -1;
    const norm_squared = dot(metric, point, point);
    if (!std.math.isFinite(norm_squared) or @abs(norm_squared - expected) > 1e-3) return null;
    return point;
}

pub const ViewSample = struct {
    x: f32,
    y: f32,
    z: f32,
    distance: f32,
};

/// Round ambient algebras for the GA round-trip helpers below. Points are
/// represented as complement duals of homogeneous vectors (the PGA
/// convention): the homogeneous axis is the last basis vector, the
/// spatial axes are e1..e3. In Cl(4,0) that axis is positive (elliptic
/// projective), in Cl(3,1) it is the negative one (hyperbolic projective).
const EllipticH = ga.Algebra(.euclidean(4)).Instantiate(f32);
const HyperbolicH = ga.Algebra(.{ .p = 3, .q = 1 }).Instantiate(f32);

fn pointFromHomogeneous(comptime H: type, w: f32, coords: [3]f32) H.Full {
    const E = H.Basis;
    var v = E.e(4).scale(w).cast(H.Vector);
    inline for (coords, 0..) |coord, i| {
        v = v.add(E.e(i + 1).scale(coord));
    }
    return v.dual().cast(H.Full);
}

fn homogeneousPointCoords(comptime H: type, p: anytype) [4]f32 {
    const dual = p.dual().cast(H.Vector);
    // Vector blades are ordered e1..e4; e4 carries the homogeneous weight.
    var v: [4]f32 = undefined;
    inline for (0..4) |i| {
        v[i] = dual.coeff(H.Vector.blades[i]);
    }
    // Preserve ambient orientation: forcing w positive would replace a
    // spherical point beyond the chart equator with its antipode.
    return .{ v[3], v[0], v[1], v[2] };
}

/// Embeds finite chart coordinates at a finite positive radius. Returns null
/// outside the hyperbolic ball, for non-finite intermediate arithmetic, or
/// when the model's signed unit squared norm cannot be represented within 1e-3.
pub fn embedConformal(metric: Metric, radius: f32, chart: Vec3) ?Vec4 {
    if (!std.math.isFinite(radius) or radius <= 0.0) return null;
    const scaled = Vec3{ .x = chart.x / radius, .y = chart.y / radius, .z = chart.z / radius };
    const r2 = scaled.x * scaled.x + scaled.y * scaled.y + scaled.z * scaled.z;
    if (!std.math.isFinite(r2)) return null;
    const ambient: Vec4 = switch (metric) {
        .spherical => blk: {
            const denom = 1.0 + r2;
            break :blk .{
                .w = (1.0 - r2) / denom,
                .x = 2.0 * scaled.x / denom,
                .y = 2.0 * scaled.y / denom,
                .z = 2.0 * scaled.z / denom,
            };
        },
        .hyperbolic => blk: {
            if (r2 >= 1.0) return null;
            const denom = 1.0 - r2;
            break :blk .{
                .w = (1.0 + r2) / denom,
                .x = 2.0 * scaled.x / denom,
                .y = 2.0 * scaled.y / denom,
                .z = 2.0 * scaled.z / denom,
            };
        },
    };
    return checkedModelPoint(metric, ambient);
}

/// Same embedding as `embedConformal`, but materialized through the GA
/// homogeneous point helpers (dual representation). This keeps the public
/// model tied to GA carriers while the renderer uses plain Vec4 arithmetic.
pub fn embedConformalGa(metric: Metric, radius: f32, chart: Vec3) ?Vec4 {
    const ambient = embedConformal(metric, radius, chart) orelse return null;
    return switch (metric) {
        .spherical => fromArray(homogeneousPointCoords(
            EllipticH,
            pointFromHomogeneous(EllipticH, ambient.w, .{ ambient.x, ambient.y, ambient.z }),
        )),
        .hyperbolic => fromArray(homogeneousPointCoords(
            HyperbolicH,
            pointFromHomogeneous(HyperbolicH, ambient.w, .{ ambient.x, ambient.y, ambient.z }),
        )),
    };
}

/// Projective counterpart of embedConformal(), with the same input rejection.
pub fn embedProjective(metric: Metric, radius: f32, chart: Vec3) ?Vec4 {
    if (!std.math.isFinite(radius) or radius <= 0.0) return null;
    const scaled = Vec3{ .x = chart.x / radius, .y = chart.y / radius, .z = chart.z / radius };
    const r2 = scaled.x * scaled.x + scaled.y * scaled.y + scaled.z * scaled.z;
    if (!std.math.isFinite(r2)) return null;
    const ambient: Vec4 = switch (metric) {
        .spherical => blk: {
            const inv = 1.0 / @sqrt(1.0 + r2);
            break :blk .{ .w = inv, .x = scaled.x * inv, .y = scaled.y * inv, .z = scaled.z * inv };
        },
        .hyperbolic => blk: {
            if (r2 >= 1.0) return null;
            const inv = 1.0 / @sqrt(1.0 - r2);
            break :blk .{ .w = inv, .x = scaled.x * inv, .y = scaled.y * inv, .z = scaled.z * inv };
        },
    };
    return checkedModelPoint(metric, ambient);
}

/// Checked projective embedding materialized through the GA point helpers.
pub fn embedProjectiveGa(metric: Metric, radius: f32, chart: Vec3) ?Vec4 {
    const ambient = embedProjective(metric, radius, chart) orelse return null;
    return switch (metric) {
        .spherical => fromArray(homogeneousPointCoords(
            EllipticH,
            pointFromHomogeneous(EllipticH, ambient.w, .{ ambient.x, ambient.y, ambient.z }),
        )),
        .hyperbolic => fromArray(homogeneousPointCoords(
            HyperbolicH,
            pointFromHomogeneous(HyperbolicH, ambient.w, .{ ambient.x, ambient.y, ambient.z }),
        )),
    };
}

pub fn dot(metric: Metric, a: Vec4, b: Vec4) f32 {
    return switch (metric) {
        .spherical => a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z,
        .hyperbolic => -a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z,
    };
}

/// Constructs a tangent orthonormal frame, or null for invalid chart/angle
/// inputs or a numerically degenerate tangent basis.
pub fn frameFromChart(metric: Metric, radius: f32, position: Vec3, yaw: f32, pitch: f32) ?Frame {
    return frameFromEmbedding(metric, radius, position, yaw, pitch, .conformal);
}

pub fn frameFromProjectiveChart(metric: Metric, radius: f32, position: Vec3, yaw: f32, pitch: f32) ?Frame {
    return frameFromEmbedding(metric, radius, position, yaw, pitch, .projective);
}

const ChartModel = enum { conformal, projective };

fn frameFromEmbedding(metric: Metric, radius: f32, position: Vec3, yaw: f32, pitch: f32, chart_model: ChartModel) ?Frame {
    if (!std.math.isFinite(yaw) or !std.math.isFinite(pitch)) return null;
    const origin = embedGa(metric, radius, position, chart_model) orelse return null;
    const flat = flatCameraBasis(yaw, pitch);

    var right = tangentFromChartDirection(metric, radius, position, origin, flat.right, chart_model) orelse return null;
    right = normalizeSpacelike(metric, right) orelse return null;

    var forward = tangentFromChartDirection(metric, radius, position, origin, flat.forward, chart_model) orelse return null;
    forward = rejectSpacelike(metric, forward, right);
    forward = normalizeSpacelike(metric, forward) orelse return null;

    var up = tangentFromChartDirection(metric, radius, position, origin, flat.up, chart_model) orelse return null;
    up = rejectSpacelike(metric, up, right);
    up = rejectSpacelike(metric, up, forward);
    up = normalizeSpacelike(metric, up) orelse return null;

    const basis = [_]Vec4{ origin, right, up, forward };
    for (basis, 0..) |a, i| {
        for (basis[i..], i..) |other, j| {
            const expected: f32 = if (i != j) 0 else if (i == 0 and metric == .hyperbolic) -1 else 1;
            const product = dot(metric, a, other);
            if (!std.math.isFinite(product) or @abs(product - expected) > 1e-3) return null;
        }
    }
    return .{
        .metric = metric,
        .radius = radius,
        .origin = origin,
        .right = right,
        .up = up,
        .forward = forward,
    };
}

/// Samples a model point using a valid frame. Inputs must belong to the same
/// metric model; this projection kernel does not validate those invariants.
pub fn samplePoint(frame: Frame, point: Vec4) ?ViewSample {
    const z = dot(frame.metric, point, frame.forward);
    if (z <= 1e-4 or !std.math.isFinite(z)) return null;

    const x = dot(frame.metric, point, frame.right);
    const y = dot(frame.metric, point, frame.up);
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;

    const distance = switch (frame.metric) {
        .spherical => std.math.acos(std.math.clamp(dot(.spherical, frame.origin, point), -1.0, 1.0)) * frame.radius,
        .hyperbolic => acosh(@max(-dot(.hyperbolic, frame.origin, point), 1.0)) * frame.radius,
    };

    if (!std.math.isFinite(distance)) return null;
    return .{ .x = x, .y = y, .z = z, .distance = distance };
}

fn fromArray(coords: [4]f32) Vec4 {
    return .{ .w = coords[0], .x = coords[1], .y = coords[2], .z = coords[3] };
}

const FlatBasis = struct {
    right: Vec3,
    up: Vec3,
    forward: Vec3,
};

fn flatCameraBasis(yaw: f32, pitch: f32) FlatBasis {
    const sy = @sin(yaw);
    const cy = @cos(yaw);
    const sp = @sin(pitch);
    const cp = @cos(pitch);
    return .{
        .right = .{ .x = cy, .y = 0.0, .z = sy },
        .up = .{ .x = sy * sp, .y = cp, .z = -cy * sp },
        .forward = .{ .x = -sy * cp, .y = sp, .z = cy * cp },
    };
}

fn tangentFromChartDirection(metric: Metric, radius: f32, position: Vec3, origin: Vec4, direction: Vec3, chart_model: ChartModel) ?Vec4 {
    const eps = @max(radius * 1e-3, 1e-3);
    const p1 = embedGa(metric, radius, position.add(direction.scale(eps)), chart_model) orelse return null;
    const raw = p1.sub(origin).scale(1.0 / eps);
    return projectToTangent(metric, origin, raw);
}

fn embedGa(metric: Metric, radius: f32, chart: Vec3, chart_model: ChartModel) ?Vec4 {
    return switch (chart_model) {
        .conformal => embedConformalGa(metric, radius, chart),
        .projective => embedProjectiveGa(metric, radius, chart),
    };
}

fn projectToTangent(metric: Metric, origin: Vec4, v: Vec4) Vec4 {
    const denom = dot(metric, origin, origin);
    return v.sub(origin.scale(dot(metric, v, origin) / denom));
}

fn rejectSpacelike(metric: Metric, v: Vec4, unit_axis: Vec4) Vec4 {
    return v.sub(unit_axis.scale(dot(metric, v, unit_axis)));
}

fn normalizeSpacelike(metric: Metric, v: Vec4) ?Vec4 {
    const norm2 = dot(metric, v, v);
    if (norm2 <= 1e-8 or !std.math.isFinite(norm2)) return null;
    return v.scale(1.0 / @sqrt(norm2));
}

fn acosh(x: f32) f32 {
    return std.math.log(f32, std.math.e, x + @sqrt((x - 1.0) * (x + 1.0)));
}

fn expectVec4ApproxEq(expected: Vec4, actual: Vec4, tolerance: f32) !void {
    inline for (expected.asArray(), actual.asArray()) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, tolerance);
    }
}

test "chart construction rejects non-finite and unrepresentable inputs" {
    const valid = Vec3{ .x = 0.2, .y = -0.3, .z = 0.4 };
    inline for (.{ Metric.spherical, Metric.hyperbolic }) |metric| {
        inline for (.{ embedConformal, embedConformalGa, embedProjective, embedProjectiveGa }) |embed| {
            for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |radius| {
                try std.testing.expect(embed(metric, radius, valid) == null);
            }
            for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), std.math.floatMax(f32) }) |value| {
                try std.testing.expect(embed(metric, 1, .{ .x = value, .y = 0, .z = 0 }) == null);
            }
            try std.testing.expect(embed(metric, std.math.floatMin(f32), valid) == null);
        }
        inline for (.{ frameFromChart, frameFromProjectiveChart }) |construct_frame| {
            for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |angle| {
                try std.testing.expect(construct_frame(metric, 1, valid, angle, 0) == null);
                try std.testing.expect(construct_frame(metric, 1, valid, 0, angle) == null);
            }
        }
    }
    inline for (.{ embedConformal, embedConformalGa, embedProjective, embedProjectiveGa }) |embed| {
        try std.testing.expect(embed(.hyperbolic, 1, .{ .x = 1, .y = 0, .z = 0 }) == null);
    }
    const near_boundary: f32 = 1 - std.math.floatEps(f32);
    try std.testing.expect(embedConformal(.hyperbolic, 1, .{ .x = near_boundary, .y = 0, .z = 0 }) == null);
}

test "conformal embeddings lie on spherical and hyperbolic models" {
    const sphere = embedConformal(.spherical, 7.0, .{ .x = 0.4, .y = -0.7, .z = 1.2 }).?;
    const hyper = embedConformal(.hyperbolic, 7.0, .{ .x = 0.4, .y = -0.7, .z = 1.2 }).?;

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dot(.spherical, sphere, sphere), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), dot(.hyperbolic, hyper, hyper), 1e-5);
}

test "conformal embeddings round-trip through the GA homogeneous point helpers" {
    const samples = [_]Vec3{
        .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .{ .x = 0.4, .y = -0.2, .z = 0.7 },
        .{ .x = -1.5, .y = 0.5, .z = 2.0 },
    };

    inline for (samples) |sample| {
        try expectVec4ApproxEq(embedConformal(.spherical, 5.0, sample).?, embedConformalGa(.spherical, 5.0, sample).?, 1e-6);
        try expectVec4ApproxEq(embedConformal(.hyperbolic, 5.0, sample).?, embedConformalGa(.hyperbolic, 5.0, sample).?, 1e-6);
    }
}

test "spherical GA embedding preserves ambient point orientation" {
    const chart = Vec3{ .x = 2, .y = 0, .z = 0 };
    const expected = Vec4{ .w = -0.6, .x = 0.8, .y = 0, .z = 0 };
    try expectVec4ApproxEq(expected, embedConformal(.spherical, 1, chart).?, 1e-6);
    try expectVec4ApproxEq(expected, embedConformalGa(.spherical, 1, chart).?, 1e-6);
    try std.testing.expect(frameFromChart(.spherical, 1, chart, 0.2, 0.1) != null);
}

test "projective embeddings match the GA proper point helpers" {
    const sample = Vec3{ .x = 0.3, .y = -0.4, .z = 0.8 };
    try expectVec4ApproxEq(embedProjective(.spherical, 4.0, sample).?, embedProjectiveGa(.spherical, 4.0, sample).?, 1e-6);
    try expectVec4ApproxEq(embedProjective(.hyperbolic, 4.0, sample).?, embedProjectiveGa(.hyperbolic, 4.0, sample).?, 1e-6);
}

test "camera frames are tangent and orthonormal in both metrics" {
    inline for (.{ Metric.spherical, Metric.hyperbolic }) |metric| {
        const frame = frameFromChart(metric, 8.0, .{ .x = 0.2, .y = 0.5, .z = -1.1 }, 0.35, 0.2).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(metric, frame.origin, frame.right), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(metric, frame.origin, frame.up), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(metric, frame.origin, frame.forward), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), dot(metric, frame.right, frame.right), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), dot(metric, frame.up, frame.up), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), dot(metric, frame.forward, frame.forward), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(metric, frame.right, frame.up), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(metric, frame.right, frame.forward), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), dot(metric, frame.up, frame.forward), 1e-4);
    }
}

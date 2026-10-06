const std = @import("std");
const ga = @import("ga");

pub const screen = ga.Algebra(.euclidean(2)).Instantiate(f32);
pub const h = ga.Algebra(.euclidean(4)).Instantiate(f32);
/// Raw ambient carriers. These aliases do not enforce unit length, tangency,
/// or Spin(4) membership; direct init() and field writes are unchecked.
pub const Point = h.Vector;
pub const Direction = h.Vector;
pub const Rotor = h.Rotor;

pub const ConstructionError = error{
    InvalidRadius,
    InvalidExtent,
    NonFiniteInput,
    NonUnitVector,
    NonUnitRotor,
    NonTangentDirection,
    NonOrthogonalAxes,
    UnrepresentableResult,
};

const unit_tolerance: f32 = 1e-3;

fn validateRadius(radius: f32) ConstructionError!void {
    if (!std.math.isFinite(radius) or radius <= 0) return error.InvalidRadius;
}

fn validateFiniteVector(vector: Point) ConstructionError!void {
    for (vector.coeffsArray()) |coefficient| {
        if (!std.math.isFinite(coefficient)) return error.NonFiniteInput;
    }
}

fn validateUnitVector(vector: Point) ConstructionError!void {
    try validateFiniteVector(vector);
    const norm_squared = dot(vector, vector);
    if (!std.math.isFinite(norm_squared) or @abs(norm_squared - 1) > unit_tolerance) return error.NonUnitVector;
}

fn validateFrame(center: Point, x: Direction, y: Direction, z: Direction, radius: f32) ConstructionError!void {
    try validateRadius(radius);
    for ([_]Point{ center, x, y, z }) |vector| try validateUnitVector(vector);
    for ([_]Direction{ x, y, z }) |axis| {
        if (@abs(dot(center, axis)) > unit_tolerance) return error.NonTangentDirection;
    }
    if (@abs(dot(x, y)) > unit_tolerance or @abs(dot(x, z)) > unit_tolerance or @abs(dot(y, z)) > unit_tolerance) return error.NonOrthogonalAxes;
}

pub const Projection = struct {
    x: f32,
    y: f32,
    z: f32,
    distance: f32,
};

pub const RasterProjection = struct {
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    depth: f32,
    valid: bool,
};

pub const Hemisphere = enum { front, border, back };

pub const Pose = struct {
    position: Point,
    right: Direction,
    up: Direction,
    forward: Direction,
    radius: f32 = 1.0,

    /// Constructs a finite orthonormal tangent frame. Unit squared norms and
    /// orthogonality are checked with absolute tolerance 1e-3.
    pub fn init(position: Point, right: Direction, up: Direction, forward: Direction, radius: f32) ConstructionError!Pose {
        try validateFrame(position, right, up, forward, radius);
        return .{ .position = position, .right = right, .up = up, .forward = forward, .radius = radius };
    }

    pub fn north(radius: f32) ConstructionError!Pose {
        return init(.init(.{ 1, 0, 0, 0 }), .init(.{ 0, 1, 0, 0 }), .init(.{ 0, 0, 1, 0 }), .init(.{ 0, 0, 0, 1 }), radius);
    }

    pub fn move(self: Pose, tangent_axis: Direction, distance: f32) ConstructionError!Pose {
        try validateRadius(self.radius);
        if (!std.math.isFinite(distance)) return error.NonFiniteInput;
        const angle = distance / self.radius;
        if (!std.math.isFinite(angle)) return error.UnrepresentableResult;
        const r = try rotorBetween(self.position, tangent_axis, angle);
        return self.applyRotor(r);
    }

    pub fn moveForward(self: Pose, distance: f32) ConstructionError!Pose {
        return self.move(self.forward, distance);
    }

    pub fn strafeRight(self: Pose, distance: f32) ConstructionError!Pose {
        return self.move(self.right, distance);
    }

    pub fn moveUp(self: Pose, distance: f32) ConstructionError!Pose {
        return self.move(self.up, distance);
    }

    pub fn yaw(self: Pose, angle: f32) ConstructionError!Pose {
        return self.applyRotor(try rotorBetween(self.right, self.forward, angle));
    }

    pub fn pitch(self: Pose, angle: f32) ConstructionError!Pose {
        return self.applyRotor(try rotorBetween(self.up, self.forward, angle));
    }

    pub fn roll(self: Pose, angle: f32) ConstructionError!Pose {
        return self.applyRotor(try rotorBetween(self.right, self.up, angle));
    }

    pub fn project(self: Pose, world_point: Point) ?Projection {
        const tangent = logMap(self.position, world_point, self.radius) orelse return null;
        const z = dot(tangent, self.forward);
        if (z <= 1e-5) return null;
        const x = dot(tangent, self.right);
        const y = dot(tangent, self.up);
        return .{ .x = x, .y = y, .z = z, .distance = norm(tangent) };
    }

    pub fn hemisphere(self: Pose, world_point: Point) Hemisphere {
        return classifyHemisphere(self.position, world_point, 1e-5);
    }

    fn applyRotor(self: Pose, r: Rotor) ConstructionError!Pose {
        try validateFrame(self.position, self.right, self.up, self.forward, self.radius);
        return init(rotate(self.position, r), rotate(self.right, r), rotate(self.up, r), rotate(self.forward, r), self.radius);
    }
};

pub const TangentFrame = struct {
    center: Point,
    x: Direction,
    y: Direction,
    z: Direction,
    radius: f32 = 1.0,

    /// Checked construction; direct struct literals do not establish invariants.
    pub fn init(center: Point, x: Direction, y: Direction, z: Direction, radius: f32) ConstructionError!TangentFrame {
        try validateFrame(center, x, y, z, radius);
        return .{ .center = center, .x = x, .y = y, .z = z, .radius = radius };
    }

    pub fn cubeVertices(self: TangentFrame, half_extent: f32) ConstructionError![8]Point {
        try validateFrame(self.center, self.x, self.y, self.z, self.radius);
        if (!std.math.isFinite(half_extent) or half_extent <= 0) return error.InvalidExtent;
        var out: [8]Point = undefined;
        var i: usize = 0;
        inline for (.{ -1.0, 1.0 }) |sx| {
            inline for (.{ -1.0, 1.0 }) |sy| {
                inline for (.{ -1.0, 1.0 }) |sz| {
                    const tangent = self.x.scale(sx * half_extent)
                        .add(self.y.scale(sy * half_extent))
                        .add(self.z.scale(sz * half_extent));
                    out[i] = try expMap(self.center, tangent, self.radius);
                    i += 1;
                }
            }
        }
        return out;
    }
};

pub fn dot(a: Point, b: Point) f32 {
    return a.scalarProduct(b);
}

pub fn screenRadiusSquared(u: f32, v: f32) f32 {
    return screen.scalarNormSquared(screen.Vector.init(.{ u, v }));
}

/// Homogeneous stereographic projection of the initial camera-to-point tangent.
/// Keeping the chart denominator in `clip_w` lets the rasterizer clip before
/// perspective division instead of manufacturing giant near-singular triangles.
pub fn rasterProjection(
    origin: Point,
    target: Point,
    forward: Direction,
    right: Direction,
    up: Direction,
    tan_half_fov: f32,
    aspect_scale: f32,
) RasterProjection {
    const path_cos = std.math.clamp(dot(origin, target), -1.0, 1.0);
    const tangent = target.sub(origin.scale(path_cos));
    const path_sin = @sqrt(@max(0.0, dot(tangent, tangent)));
    const forward_component = dot(forward, tangent);
    const valid = path_sin > 1e-6 and tan_half_fov > 0.0;
    const inverse_fov = if (valid) 1.0 / tan_half_fov else 0.0;
    return .{
        .clip_x = dot(right, tangent) * inverse_fov * aspect_scale,
        .clip_y = -dot(up, tangent) * inverse_fov,
        .clip_w = path_sin + forward_component,
        .depth = (1.0 - path_cos) * 0.5,
        .valid = valid,
    };
}

/// Stereographic screen direction in the tangent frame at the camera.
pub fn frameDirection(forward: Direction, right: Direction, up: Direction, tan_half_fov: f32, u: f32, v: f32) Direction {
    const r = @sqrt(screenRadiusSquared(u, v));
    if (r < 1e-6) return forward;

    const t = r * tan_half_fov;
    const inverse = 1.0 / (1.0 + t * t);
    const sin_theta = 2.0 * t * inverse;
    const cos_theta = (1.0 - t * t) * inverse;
    return forward.scale(cos_theta)
        .add(right.scale(sin_theta * u / r))
        .add(up.scale(sin_theta * v / r));
}

pub const GreatSphereIntersection = struct {
    cos_angle: f32,
    sin_angle: f32,
    valid: bool,
};

/// First ray intersection with the great sphere whose normal is `plane`.
pub fn greatSphereIntersection(origin: Point, direction: Direction, plane: Point) GreatSphereIntersection {
    const a = dot(origin, plane);
    const b = dot(direction, plane);
    const magnitude = @sqrt(a * a + b * b);
    const valid = magnitude >= 1e-5;
    return .{
        .cos_angle = if (valid) (if (a >= 0.0) -b / magnitude else b / magnitude) else -1.0,
        .sin_angle = if (valid) @abs(a) / magnitude else 0.0,
        .valid = valid,
    };
}

pub fn norm(v: Point) f32 {
    return @sqrt(@max(dot(v, v), 0.0));
}

test "shared spherical view and plane kernels" {
    const origin = Point.init(.{ 1.0, 0.0, 0.0, 0.0 });
    const forward = Direction.init(.{ 0.0, 1.0, 0.0, 0.0 });
    const right = Direction.init(.{ 0.0, 0.0, 1.0, 0.0 });
    const up = Direction.init(.{ 0.0, 0.0, 0.0, 1.0 });

    const projected = rasterProjection(origin, forward, forward, right, up, 1.0, 1.0);
    try std.testing.expect(projected.valid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), projected.clip_x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), projected.clip_y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), projected.clip_w, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), projected.depth, 1e-6);

    const chart_pole = rasterProjection(origin, forward.negate(), forward, right, up, 1.0, 1.0);
    try std.testing.expect(chart_pole.valid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), chart_pole.clip_w, 1e-6);

    try std.testing.expect(frameDirection(forward, right, up, 1.0, 0.0, 0.0).eql(forward));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), norm(frameDirection(forward, right, up, 1.0, 0.5, -0.25)), 1e-6);

    const hit = greatSphereIntersection(origin, forward, origin);
    try std.testing.expect(hit.valid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hit.cos_angle, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hit.sin_angle, 1e-6);
    try std.testing.expect(!greatSphereIntersection(origin, forward, right).valid);
}

/// Returns a unit ambient vector, or null for non-finite coefficients/squared
/// norm or length <= 1e-8. Does not establish tangency to another point.
pub fn normalize(v: Point) ?Point {
    const norm_squared = dot(v, v);
    if (!std.math.isFinite(norm_squared)) return null;
    const n = @sqrt(norm_squared);
    if (n <= 1e-8) return null;
    return v.scale(1.0 / n);
}

/// Constructs a plane rotation from finite orthogonal unit axes, not a rotor
/// aligning arbitrary from/to points. Axes use the frame tolerance 1e-3.
pub fn rotorBetween(unit_a: Point, unit_b: Point, angle: f32) ConstructionError!Rotor {
    try validateUnitVector(unit_a);
    try validateUnitVector(unit_b);
    if (!std.math.isFinite(angle)) return error.NonFiniteInput;
    if (@abs(dot(unit_a, unit_b)) > unit_tolerance) return error.NonOrthogonalAxes;
    const half = angle / 2.0;
    const plane = unit_a.wedge(unit_b).gradePart(2);
    const rotor = h.Scalar.init(.{@cos(half)})
        .add(plane.scale(-@sin(half)))
        .cast(Rotor);
    const identity = rotor.gp(rotor.reverse());
    inline for (@TypeOf(identity).blades) |mask| {
        const expected: f32 = if (mask.toInt() == 0) 1 else 0;
        const coefficient = identity.coeff(mask);
        if (!std.math.isFinite(coefficient) or @abs(coefficient - expected) > unit_tolerance) return error.NonUnitRotor;
    }
    return rotor;
}

/// Trusted grade-1 sandwich. A genuine unit Spin(4) rotor is required for a
/// length-preserving rotation; an arbitrary even carrier is not validated.
pub fn rotate(v: Point, rotor: Rotor) Point {
    return rotor.gp(v).gp(rotor.reverse()).gradePart(1);
}

/// Checked spherical exponential map. Finite tangent directions must be
/// orthogonal to the unit center. Zero retains the center; nonzero tangents
/// with an unrepresentable squared length or angle are rejected.
pub fn expMap(center: Point, tangent: Direction, radius: f32) ConstructionError!Point {
    try validateRadius(radius);
    try validateUnitVector(center);
    try validateFiniteVector(tangent);
    const norm_squared = dot(tangent, tangent);
    if (!std.math.isFinite(norm_squared)) return error.UnrepresentableResult;
    const len = @sqrt(norm_squared);
    if (@abs(dot(center, tangent)) > unit_tolerance * len) return error.NonTangentDirection;
    if (len == 0) {
        if (!tangent.eql(Point.zero())) return error.UnrepresentableResult;
        return center;
    }
    const angle = len / radius;
    if (!std.math.isFinite(angle)) return error.UnrepresentableResult;
    const axis = tangent.scale(1.0 / len);
    const result = center.scale(@cos(angle)).add(axis.scale(@sin(angle)));
    validateUnitVector(result) catch return error.UnrepresentableResult;
    return result;
}

/// Checked shortest logarithmic map. Coincident points return zero; antipodes
/// return null because the shortest direction is not unique. Invalid inputs
/// and non-finite results also return null.
pub fn logMap(center: Point, target: Point, radius: f32) ?Direction {
    validateRadius(radius) catch return null;
    validateUnitVector(center) catch return null;
    validateUnitVector(target) catch return null;
    const c = std.math.clamp(dot(center, target), -1.0, 1.0);
    const theta = std.math.acos(c);
    if (theta <= 1e-6) return Point.zero();

    const s = @sin(theta);
    if (@abs(s) <= 1e-6) return null; // antipode: no unique shortest direction

    const result = target.sub(center.scale(c)).scale((theta * radius) / s);
    validateFiniteVector(result) catch return null;
    return result;
}

pub fn classifyHemisphere(camera: Point, world_point: Point, epsilon: f32) Hemisphere {
    const c = dot(camera, world_point);
    if (@abs(c) <= epsilon) return .border;
    return if (c > 0) .front else .back;
}

fn expectVectorApprox(expected: [4]f32, actual: Point, tolerance: f32) !void {
    inline for (expected, .{ "e1", "e2", "e3", "e4" }) |value, basis| {
        try std.testing.expectApproxEqAbs(value, actual.coeffNamed(basis), tolerance);
    }
}

test "S3 normalization rejects non-finite and degenerate values" {
    try std.testing.expect(normalize(Point.zero()) == null);
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), std.math.floatMax(f32) }) |value| {
        try std.testing.expect(normalize(Point.init(.{ value, 0, 0, 0 })) == null);
    }
    const normalized = normalize(Point.init(.{ 2, 3, -4, 5 })).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), dot(normalized, normalized), 1e-6);
}

test "S3 constructors reject invalid radii and frames" {
    const pose = try Pose.north(2);
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |radius| {
        try std.testing.expectError(error.InvalidRadius, Pose.north(radius));
        try std.testing.expectError(error.InvalidRadius, TangentFrame.init(pose.position, pose.right, pose.up, pose.forward, radius));
        try std.testing.expectError(error.InvalidRadius, expMap(pose.position, Point.zero(), radius));
        try std.testing.expect(logMap(pose.position, pose.forward, radius) == null);
    }
    try std.testing.expectError(error.NonUnitVector, Pose.init(Point.zero(), pose.right, pose.up, pose.forward, 1));
    try std.testing.expectError(error.NonUnitVector, rotorBetween(pose.position, Point.zero(), 1));
    try std.testing.expectError(error.NonOrthogonalAxes, rotorBetween(pose.position, pose.position, 1));
    try std.testing.expectError(error.NonOrthogonalAxes, rotorBetween(pose.position, pose.position.negate(), 1));
    try std.testing.expectError(error.NonUnitRotor, rotorBetween(pose.position.scale(1.0004), pose.right.scale(1.0004), std.math.pi));
    try std.testing.expectError(error.NonOrthogonalAxes, Pose.init(pose.position, pose.right, pose.right, pose.forward, 1));
    try std.testing.expectError(error.NonTangentDirection, TangentFrame.init(pose.position, pose.position, pose.up, pose.forward, 1));
    try std.testing.expectError(error.NonTangentDirection, expMap(pose.position, pose.position, 1));
    var invalid_pose = pose;
    invalid_pose.radius = 0;
    try std.testing.expectError(error.InvalidRadius, invalid_pose.moveForward(0));
    const frame = try TangentFrame.init(pose.position, pose.right, pose.up, pose.forward, 1);
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |extent| {
        try std.testing.expectError(error.InvalidExtent, frame.cubeVertices(extent));
    }
}

test "S3 construction rejects non-finite values and unrepresentable results" {
    const pose = try Pose.north(1);
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |value| {
        inline for (0..4) |index| {
            var coefficients = [4]f32{ 1, 0, 0, 0 };
            coefficients[index] = value;
            const vector = Point.init(coefficients);
            try std.testing.expectError(error.NonFiniteInput, Pose.init(vector, pose.right, pose.up, pose.forward, 1));
            try std.testing.expectError(error.NonFiniteInput, rotorBetween(vector, pose.right, 1));
            try std.testing.expectError(error.NonFiniteInput, expMap(pose.position, vector, 1));
            try std.testing.expect(logMap(pose.position, vector, 1) == null);
        }
        try std.testing.expectError(error.NonFiniteInput, rotorBetween(pose.position, pose.right, value));
        try std.testing.expectError(error.NonFiniteInput, pose.moveForward(value));
        try std.testing.expectError(error.NonFiniteInput, pose.yaw(value));
        try std.testing.expectError(error.NonFiniteInput, pose.pitch(value));
        try std.testing.expectError(error.NonFiniteInput, pose.roll(value));
    }
    const huge = std.math.floatMax(f32);
    try std.testing.expectError(error.UnrepresentableResult, expMap(pose.position, pose.right.scale(huge), 1));
    try std.testing.expectError(error.UnrepresentableResult, expMap(pose.position, pose.right.scale(10), std.math.floatMin(f32)));
    try std.testing.expectError(error.UnrepresentableResult, (try Pose.north(std.math.floatMin(f32))).moveForward(huge));
    try std.testing.expect(logMap(pose.position, pose.right, huge) == null);
}

test "S3 maps define zero and antipodal behavior and round-trip valid inputs" {
    const pose = try Pose.north(2);
    try std.testing.expect((try expMap(pose.position, Point.zero(), 2)).eql(pose.position));
    try std.testing.expect(logMap(pose.position, pose.position, 2).?.eql(Point.zero()));
    try std.testing.expect(logMap(pose.position, pose.position.negate(), 2) == null);
    try std.testing.expect(logMap(Point.zero(), pose.right, 2) == null);
    // Small physical length is not a small angle when the radius is also small.
    const small_radius_target = try expMap(pose.position, pose.right.scale(1e-9), 1e-9);
    try expectVectorApprox(.{ @cos(@as(f32, 1)), @sin(@as(f32, 1)), 0, 0 }, small_radius_target, 1e-6);
    try std.testing.expectError(error.UnrepresentableResult, expMap(pose.position, pose.right.scale(std.math.floatMin(f32)), 1));
    const tangent = pose.right.scale(0.3).add(pose.up.scale(-0.4));
    const target = try expMap(pose.position, tangent, 2);
    const recovered = logMap(pose.position, target, 2).?;
    inline for (tangent.coeffsArray(), recovered.coeffsArray()) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1e-5);
    }
    var moved = pose;
    for (0..200) |_| {
        moved = try (try (try moved.moveForward(0.01)).yaw(0.003)).pitch(-0.002);
    }
    _ = try Pose.init(moved.position, moved.right, moved.up, moved.forward, moved.radius);
}

test "S3 pose moves by GA rotor on the position-forward plane" {
    const pose = try (try Pose.north(1.0)).moveForward(std.math.pi / 2.0);

    try expectVectorApprox(.{ 0, 0, 0, 1 }, pose.position, 1e-5);
    try expectVectorApprox(.{ -1, 0, 0, 0 }, pose.forward, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dot(pose.position, pose.right), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dot(pose.position, pose.position), 1e-5);
}

test "S3 log projection sees a forward point in front" {
    const pose = try Pose.north(2.0);
    const target = try expMap(pose.position, pose.forward.scale(0.5), pose.radius);
    const projected = pose.project(target).?;

    try std.testing.expectApproxEqAbs(@as(f32, 0), projected.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), projected.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), projected.z, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), projected.distance, 1e-5);
}

test "S3 cube vertices stay on the sphere" {
    const pose = try (try Pose.north(3.0)).moveForward(1.0);
    const frame = try TangentFrame.init(pose.position, pose.right, pose.up, pose.forward, pose.radius);

    for (try frame.cubeVertices(0.25)) |vertex| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), dot(vertex, vertex), 1e-5);
    }
}

test "S3 hemisphere classifier marks the equator border" {
    const pose = try Pose.north(1.0);

    try std.testing.expectEqual(Hemisphere.front, pose.hemisphere(pose.position));
    try std.testing.expectEqual(Hemisphere.border, pose.hemisphere(pose.forward));
    try std.testing.expectEqual(Hemisphere.back, pose.hemisphere(pose.position.negate()));
}

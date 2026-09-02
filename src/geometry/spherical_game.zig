const std = @import("std");
const ga = @import("ga");

pub const h = ga.Algebra(.euclidean(4)).Instantiate(f32);
pub const Point = h.Vector;
pub const Direction = h.Vector;
pub const Rotor = h.Rotor;

pub const Projection = struct {
    x: f32,
    y: f32,
    z: f32,
    distance: f32,
};

pub const Hemisphere = enum { front, border, back };

pub const Pose = struct {
    position: Point,
    right: Direction,
    up: Direction,
    forward: Direction,
    radius: f32 = 1.0,

    pub fn north(radius: f32) Pose {
        return .{
            .position = Point.init(.{ 1, 0, 0, 0 }),
            .right = Direction.init(.{ 0, 1, 0, 0 }),
            .up = Direction.init(.{ 0, 0, 1, 0 }),
            .forward = Direction.init(.{ 0, 0, 0, 1 }),
            .radius = radius,
        };
    }

    pub fn move(self: Pose, tangent_axis: Direction, distance: f32) Pose {
        const r = rotorBetween(self.position, tangent_axis, distance / self.radius);
        return self.applyRotor(r);
    }

    pub fn moveForward(self: Pose, distance: f32) Pose {
        return self.move(self.forward, distance);
    }

    pub fn strafeRight(self: Pose, distance: f32) Pose {
        return self.move(self.right, distance);
    }

    pub fn moveUp(self: Pose, distance: f32) Pose {
        return self.move(self.up, distance);
    }

    pub fn yaw(self: Pose, angle: f32) Pose {
        return self.applyRotor(rotorBetween(self.right, self.forward, angle));
    }

    pub fn pitch(self: Pose, angle: f32) Pose {
        return self.applyRotor(rotorBetween(self.up, self.forward, angle));
    }

    pub fn roll(self: Pose, angle: f32) Pose {
        return self.applyRotor(rotorBetween(self.right, self.up, angle));
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

    fn applyRotor(self: Pose, r: Rotor) Pose {
        return .{
            .position = rotate(self.position, r),
            .right = rotate(self.right, r),
            .up = rotate(self.up, r),
            .forward = rotate(self.forward, r),
            .radius = self.radius,
        };
    }
};

pub const TangentFrame = struct {
    center: Point,
    x: Direction,
    y: Direction,
    z: Direction,
    radius: f32 = 1.0,

    pub fn cubeVertices(self: TangentFrame, half_extent: f32) [8]Point {
        var out: [8]Point = undefined;
        var i: usize = 0;
        inline for (.{ -1.0, 1.0 }) |sx| {
            inline for (.{ -1.0, 1.0 }) |sy| {
                inline for (.{ -1.0, 1.0 }) |sz| {
                    const tangent = self.x.scale(sx * half_extent)
                        .add(self.y.scale(sy * half_extent))
                        .add(self.z.scale(sz * half_extent))
                        .cast(Direction);
                    out[i] = expMap(self.center, tangent, self.radius);
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

pub fn norm(v: Point) f32 {
    return @sqrt(@max(dot(v, v), 0.0));
}

pub fn normalize(v: Point) ?Point {
    const n = norm(v);
    if (n <= 1e-8) return null;
    return v.scale(1.0 / n).cast(Point);
}

pub fn rotorBetween(unit_a: Point, unit_b: Point, angle: f32) Rotor {
    const half = angle / 2.0;
    const plane = unit_a.wedge(unit_b).gradePart(2);
    return h.Scalar.init(.{@cos(half)})
        .add(plane.scale(-@sin(half)))
        .cast(Rotor);
}

pub fn rotate(v: Point, rotor: Rotor) Point {
    return rotor.gp(v).gp(rotor.reverse()).gradePart(1).cast(Point);
}

pub fn expMap(center: Point, tangent: Direction, radius: f32) Point {
    const len = norm(tangent);
    if (len <= 1e-8) return center;
    const angle = len / radius;
    const axis = tangent.scale(1.0 / len);
    return center.scale(@cos(angle)).add(axis.scale(@sin(angle))).cast(Point);
}

pub fn logMap(center: Point, target: Point, radius: f32) ?Direction {
    const c = std.math.clamp(dot(center, target), -1.0, 1.0);
    const theta = std.math.acos(c);
    if (theta <= 1e-6) return Point.zero();

    const s = @sin(theta);
    if (@abs(s) <= 1e-6) return null; // antipode: no unique shortest direction

    return target.sub(center.scale(c)).scale((theta * radius) / s).cast(Direction);
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

test "S3 pose moves by GA rotor on the position-forward plane" {
    const pose = Pose.north(1.0).moveForward(std.math.pi / 2.0);

    try expectVectorApprox(.{ 0, 0, 0, 1 }, pose.position, 1e-5);
    try expectVectorApprox(.{ -1, 0, 0, 0 }, pose.forward, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dot(pose.position, pose.right), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dot(pose.position, pose.position), 1e-5);
}

test "S3 log projection sees a forward point in front" {
    const pose = Pose.north(2.0);
    const target = expMap(pose.position, pose.forward.scale(0.5).cast(Direction), pose.radius);
    const projected = pose.project(target).?;

    try std.testing.expectApproxEqAbs(@as(f32, 0), projected.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), projected.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), projected.z, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), projected.distance, 1e-5);
}

test "S3 cube vertices stay on the sphere" {
    const pose = Pose.north(3.0).moveForward(1.0);
    const frame = TangentFrame{
        .center = pose.position,
        .x = pose.right,
        .y = pose.up,
        .z = pose.forward,
        .radius = pose.radius,
    };

    for (frame.cubeVertices(0.25)) |vertex| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), dot(vertex, vertex), 1e-5);
    }
}

test "S3 hemisphere classifier marks the equator border" {
    const pose = Pose.north(1.0);

    try std.testing.expectEqual(Hemisphere.front, pose.hemisphere(pose.position));
    try std.testing.expectEqual(Hemisphere.border, pose.hemisphere(pose.forward));
    try std.testing.expectEqual(Hemisphere.back, pose.hemisphere(pose.position.negate().cast(Point)));
}

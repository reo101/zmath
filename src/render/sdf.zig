const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn splat(value: f32) Vec3 {
        return .{ .x = value, .y = value, .z = value };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
            .z = self.z - other.z,
        };
    }

    pub fn scale(self: Vec3, factor: f32) Vec3 {
        return .{
            .x = self.x * factor,
            .y = self.y * factor,
            .z = self.z * factor,
        };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn magnitudeSquared(self: Vec3) f32 {
        return self.dot(self);
    }

    pub fn magnitude(self: Vec3) f32 {
        return @sqrt(self.magnitudeSquared());
    }

    pub fn normalized(self: Vec3) Vec3 {
        const length = self.magnitude();
        if (length <= 1e-6) return .{ .x = 0.0, .y = 0.0, .z = 1.0 };
        return self.scale(1.0 / length);
    }

    pub fn abs(self: Vec3) Vec3 {
        return .{
            .x = @abs(self.x),
            .y = @abs(self.y),
            .z = @abs(self.z),
        };
    }

    pub fn max(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = @max(self.x, other.x),
            .y = @max(self.y, other.y),
            .z = @max(self.z, other.z),
        };
    }

    pub fn min(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = @min(self.x, other.x),
            .y = @min(self.y, other.y),
            .z = @min(self.z, other.z),
        };
    }

    pub fn maxComponent(self: Vec3) f32 {
        return @max(self.x, @max(self.y, self.z));
    }
};

pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

    pub fn at(self: Ray, distance: f32) Vec3 {
        return self.origin.add(self.direction.scale(distance));
    }
};

pub const Sample = struct {
    distance: f32,
    material: u8 = 0,
};

pub const Hit = struct {
    distance: f32,
    position: Vec3,
    sample: Sample,
    steps: usize,
};

pub const MarchOptions = struct {
    min_distance: f32 = 0.0,
    max_distance: f32 = 120.0,
    hit_epsilon: f32 = 0.0008,
    min_step: f32 = 0.0004,
    step_scale: f32 = 0.98,
    max_steps: usize = 96,
};

pub fn sphere(point: Vec3, radius: f32) f32 {
    return point.magnitude() - radius;
}

pub fn box(point: Vec3, half_extent: Vec3) f32 {
    const q = point.abs().sub(half_extent);
    const outside = q.max(Vec3.splat(0.0)).magnitude();
    const inside = @min(q.maxComponent(), 0.0);
    return outside + inside;
}

pub fn torus(point: Vec3, major_radius: f32, minor_radius: f32) f32 {
    const qx = @sqrt(point.x * point.x + point.y * point.y) - major_radius;
    return @sqrt(qx * qx + point.z * point.z) - minor_radius;
}

pub fn plane(point: Vec3, unit_normal: Vec3, offset: f32) f32 {
    return point.dot(unit_normal) + offset;
}

pub fn opUnion(a: Sample, b: Sample) Sample {
    return if (a.distance <= b.distance) a else b;
}

pub fn opSubtract(a: Sample, b: Sample) Sample {
    return if (a.distance >= -b.distance)
        a
    else
        .{ .distance = -b.distance, .material = a.material };
}

pub fn smoothUnion(a: Sample, b: Sample, k: f32) Sample {
    if (k <= 1e-6) return opUnion(a, b);
    const h = std.math.clamp(0.5 + 0.5 * (b.distance - a.distance) / k, 0.0, 1.0);
    return .{
        .distance = std.math.lerp(b.distance, a.distance, h) - k * h * (1.0 - h),
        .material = if (h >= 0.5) a.material else b.material,
    };
}

pub fn rotate2(v: [2]f32, angle: f32) [2]f32 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{
        v[0] * c - v[1] * s,
        v[0] * s + v[1] * c,
    };
}

pub fn estimateNormal(scene_fn: anytype, point: Vec3, epsilon: f32) Vec3 {
    const e = epsilon;
    const center = scene_fn(point).distance;
    const nx = center - scene_fn(point.sub(.{ .x = e, .y = 0.0, .z = 0.0 })).distance;
    const ny = center - scene_fn(point.sub(.{ .x = 0.0, .y = e, .z = 0.0 })).distance;
    const nz = center - scene_fn(point.sub(.{ .x = 0.0, .y = 0.0, .z = e })).distance;
    return Vec3.init(nx, ny, nz).normalized();
}

pub fn estimateNormalWith(scene_fn: anytype, ctx: anytype, point: Vec3, epsilon: f32) Vec3 {
    const e = epsilon;
    const center = scene_fn(ctx, point).distance;
    const nx = center - scene_fn(ctx, point.sub(.{ .x = e, .y = 0.0, .z = 0.0 })).distance;
    const ny = center - scene_fn(ctx, point.sub(.{ .x = 0.0, .y = e, .z = 0.0 })).distance;
    const nz = center - scene_fn(ctx, point.sub(.{ .x = 0.0, .y = 0.0, .z = e })).distance;
    return Vec3.init(nx, ny, nz).normalized();
}

pub fn raymarch(scene_fn: anytype, ray: Ray, options: MarchOptions) ?Hit {
    var distance = options.min_distance;
    var step_index: usize = 0;
    while (step_index < options.max_steps and distance <= options.max_distance) : (step_index += 1) {
        const position = ray.at(distance);
        const sample = scene_fn(position);
        if (@abs(sample.distance) <= options.hit_epsilon) {
            return .{
                .distance = distance,
                .position = position,
                .sample = sample,
                .steps = step_index + 1,
            };
        }

        const step_distance = @max(@abs(sample.distance) * options.step_scale, options.min_step);
        distance += step_distance;
    }
    return null;
}

pub fn raymarchWith(scene_fn: anytype, ctx: anytype, ray: Ray, options: MarchOptions) ?Hit {
    var distance = options.min_distance;
    var step_index: usize = 0;
    while (step_index < options.max_steps and distance <= options.max_distance) : (step_index += 1) {
        const position = ray.at(distance);
        const sample = scene_fn(ctx, position);
        if (@abs(sample.distance) <= options.hit_epsilon) {
            return .{
                .distance = distance,
                .position = position,
                .sample = sample,
                .steps = step_index + 1,
            };
        }

        const step_distance = @max(@abs(sample.distance) * options.step_scale, options.min_step);
        distance += step_distance;
    }
    return null;
}

test "sphere sdf is negative inside and zero on surface" {
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), sphere(Vec3.init(0.0, 0.0, 0.0), 1.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sphere(Vec3.init(0.0, 0.0, 1.5), 1.5), 1e-6);
}

test "box sdf matches exact axis-aligned box distance" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), box(Vec3.init(1.0, 0.25, -0.5), Vec3.splat(1.0)), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), box(Vec3.init(2.0, 0.0, 0.0), Vec3.splat(1.0)), 1e-6);
}

test "torus sdf reaches zero on major ring surface" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), torus(Vec3.init(0.5, 0.0, 0.0), 0.4, 0.1), 1e-6);
}

test "union keeps the nearer material" {
    const a = Sample{ .distance = 0.2, .material = 3 };
    const b = Sample{ .distance = 0.4, .material = 7 };
    const result = opUnion(a, b);
    try std.testing.expectEqual(@as(u8, 3), result.material);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), result.distance, 1e-6);
}

test "raymarch hits a sphere" {
    const scene = struct {
        fn sample(point: Vec3) Sample {
            return .{ .distance = sphere(point, 1.0), .material = 1 };
        }
    };

    const ray = Ray{
        .origin = Vec3.init(0.0, 0.0, -3.0),
        .direction = Vec3.init(0.0, 0.0, 1.0),
    };
    const hit = raymarch(scene.sample, ray, .{}) orelse return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hit.distance, 0.02);
    try std.testing.expectEqual(@as(u8, 1), hit.sample.material);
}

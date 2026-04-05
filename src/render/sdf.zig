const std = @import("std");
const curved_ambient = @import("../geometry/curved_ambient.zig");

const Flat3 = curved_ambient.Flat3;
pub const Vec3 = Flat3.Vector;

pub fn vec3(x_value: f32, y_value: f32, z_value: f32) Vec3 {
    return Vec3.init(.{ x_value, y_value, z_value });
}

pub fn splat(value: f32) Vec3 {
    return vec3(value, value, value);
}

fn coords(v: Vec3) [3]f32 {
    return v.coeffsArray();
}

fn x(v: Vec3) f32 {
    return coords(v)[0];
}

fn y(v: Vec3) f32 {
    return coords(v)[1];
}

fn z(v: Vec3) f32 {
    return coords(v)[2];
}

fn normalized(v: Vec3) Vec3 {
    const length = v.magnitude();
    if (length <= 1e-6) return vec3(0.0, 0.0, 1.0);
    return v.scale(1.0 / length);
}

fn abs(v: Vec3) Vec3 {
    const c = coords(v);
    return vec3(@abs(c[0]), @abs(c[1]), @abs(c[2]));
}

fn max(a: Vec3, b: Vec3) Vec3 {
    const ac = coords(a);
    const bc = coords(b);
    return vec3(
        @max(ac[0], bc[0]),
        @max(ac[1], bc[1]),
        @max(ac[2], bc[2]),
    );
}

fn maxComponent(v: Vec3) f32 {
    const c = coords(v);
    return @max(c[0], @max(c[1], c[2]));
}

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
    const q = abs(point).sub(half_extent);
    const outside = max(q, splat(0.0)).magnitude();
    const inside = @min(maxComponent(q), 0.0);
    return outside + inside;
}

pub fn torus(point: Vec3, major_radius: f32, minor_radius: f32) f32 {
    const qx = @sqrt(x(point) * x(point) + y(point) * y(point)) - major_radius;
    return @sqrt(qx * qx + z(point) * z(point)) - minor_radius;
}

pub fn plane(point: Vec3, unit_normal: Vec3, offset: f32) f32 {
    return point.scalarProduct(unit_normal) + offset;
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
    const nx = center - scene_fn(point.sub(vec3(e, 0.0, 0.0))).distance;
    const ny = center - scene_fn(point.sub(vec3(0.0, e, 0.0))).distance;
    const nz = center - scene_fn(point.sub(vec3(0.0, 0.0, e))).distance;
    return normalized(vec3(nx, ny, nz));
}

pub fn estimateNormalWith(scene_fn: anytype, ctx: anytype, point: Vec3, epsilon: f32) Vec3 {
    const e = epsilon;
    const center = scene_fn(ctx, point).distance;
    const nx = center - scene_fn(ctx, point.sub(vec3(e, 0.0, 0.0))).distance;
    const ny = center - scene_fn(ctx, point.sub(vec3(0.0, e, 0.0))).distance;
    const nz = center - scene_fn(ctx, point.sub(vec3(0.0, 0.0, e))).distance;
    return normalized(vec3(nx, ny, nz));
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
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), sphere(vec3(0.0, 0.0, 0.0), 1.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sphere(vec3(0.0, 0.0, 1.5), 1.5), 1e-6);
}

test "box sdf matches exact axis-aligned box distance" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), box(vec3(1.0, 0.25, -0.5), splat(1.0)), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), box(vec3(2.0, 0.0, 0.0), splat(1.0)), 1e-6);
}

test "torus sdf reaches zero on major ring surface" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), torus(vec3(0.5, 0.0, 0.0), 0.4, 0.1), 1e-6);
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
        .origin = vec3(0.0, 0.0, -3.0),
        .direction = vec3(0.0, 0.0, 1.0),
    };
    const hit = raymarch(scene.sample, ray, .{}) orelse return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hit.distance, 0.02);
}

const std = @import("std");
const curved_ambient = @import("../geometry/curved_ambient.zig");

const Flat3 = curved_ambient.Flat3;
const Vec3 = Flat3.Vector;

fn normalizeOr(v: Vec3, fallback: Vec3) Vec3 {
    const length = v.magnitude();
    if (length <= 1e-6) return fallback;
    return v.scale(1.0 / length);
}

fn absVec(v: Vec3) Vec3 {
    const n = v.named();
    return Vec3.init(.{ @abs(n.e1), @abs(n.e2), @abs(n.e3) });
}

fn maxVec(a: Vec3, b: Vec3) Vec3 {
    const an = a.named();
    const bn = b.named();
    return Vec3.init(.{
        @max(an.e1, bn.e1),
        @max(an.e2, bn.e2),
        @max(an.e3, bn.e3),
    });
}

fn maxComponent(v: Vec3) f32 {
    const n = v.named();
    return @max(n.e1, @max(n.e2, n.e3));
}

pub const Ray = struct {
    origin: Flat3.Vector,
    direction: Flat3.Vector,

    pub fn at(self: Ray, distance: f32) Flat3.Vector {
        return self.origin.add(self.direction.scale(distance));
    }
};

pub const Sample = struct {
    distance: f32,
    material: u8 = 0,
};

pub const Hit = struct {
    distance: f32,
    position: Flat3.Vector,
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

pub fn sphere(point: Flat3.Vector, radius: f32) f32 {
    return point.magnitude() - radius;
}

pub fn box(point: Flat3.Vector, half_extent: Flat3.Vector) f32 {
    const q = absVec(point).sub(half_extent);
    const outside = maxVec(q, Vec3.init(.{ 0.0, 0.0, 0.0 })).magnitude();
    const inside = @min(maxComponent(q), 0.0);
    return outside + inside;
}

pub fn torus(point: Flat3.Vector, major_radius: f32, minor_radius: f32) f32 {
    const n = point.named();
    const qx = @sqrt(n.e1 * n.e1 + n.e2 * n.e2) - major_radius;
    return @sqrt(qx * qx + n.e3 * n.e3) - minor_radius;
}

pub fn plane(point: Flat3.Vector, unit_normal: Flat3.Vector, offset: f32) f32 {
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

pub fn estimateNormal(scene_fn: anytype, point: Flat3.Vector, epsilon: f32) Flat3.Vector {
    const e = epsilon;
    const center = scene_fn(point).distance;
    const nx = center - scene_fn(point.sub(Vec3.init(.{ e, 0.0, 0.0 }))).distance;
    const ny = center - scene_fn(point.sub(Vec3.init(.{ 0.0, e, 0.0 }))).distance;
    const nz = center - scene_fn(point.sub(Vec3.init(.{ 0.0, 0.0, e }))).distance;
    return normalizeOr(Vec3.init(.{ nx, ny, nz }), Vec3.init(.{ 0.0, 0.0, 1.0 }));
}

pub fn estimateNormalWith(scene_fn: anytype, ctx: anytype, point: Flat3.Vector, epsilon: f32) Flat3.Vector {
    const e = epsilon;
    const center = scene_fn(ctx, point).distance;
    const nx = center - scene_fn(ctx, point.sub(Vec3.init(.{ e, 0.0, 0.0 }))).distance;
    const ny = center - scene_fn(ctx, point.sub(Vec3.init(.{ 0.0, e, 0.0 }))).distance;
    const nz = center - scene_fn(ctx, point.sub(Vec3.init(.{ 0.0, 0.0, e }))).distance;
    return normalizeOr(Vec3.init(.{ nx, ny, nz }), Vec3.init(.{ 0.0, 0.0, 1.0 }));
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
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), sphere(Vec3.init(.{ 0.0, 0.0, 0.0 }), 1.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sphere(Vec3.init(.{ 0.0, 0.0, 1.5 }), 1.5), 1e-6);
}

test "box sdf matches exact axis-aligned box distance" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), box(Vec3.init(.{ 1.0, 0.25, -0.5 }), Vec3.init(.{ 1.0, 1.0, 1.0 })), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), box(Vec3.init(.{ 2.0, 0.0, 0.0 }), Vec3.init(.{ 1.0, 1.0, 1.0 })), 1e-6);
}

test "torus sdf reaches zero on major ring surface" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), torus(Vec3.init(.{ 0.5, 0.0, 0.0 }), 0.4, 0.1), 1e-6);
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
        .origin = Vec3.init(.{ 0.0, 0.0, -3.0 }),
        .direction = Vec3.init(.{ 0.0, 0.0, 1.0 }),
    };
    const hit = raymarch(scene.sample, ray, .{}) orelse return error.ExpectedHit;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hit.distance, 0.02);
}

const std = @import("std");
const zmath = @import("zmath");
const projection = zmath.render.projection;
const sdf = zmath.render.sdf;
pub const demo_core = @import("core.zig");
const demo = demo_core;

fn normalizeSdfVec3(v: sdf.Vec3) sdf.Vec3 {
    const length = v.magnitude();
    if (length <= 1e-6) return sdf.Vec3.init(.{ 0.0, 0.0, 1.0 });
    return v.scale(1.0 / length);
}

pub const Scene = struct {
    projection_mode: projection.EuclideanProjection,
    zoom: f32,
    eye: sdf.Vec3,
    right: sdf.Vec3,
    up: sdf.Vec3,
    forward: sdf.Vec3,
    cube_half_extent: f32,
    local_row_x: sdf.Vec3,
    local_row_y: sdf.Vec3,
    local_row_z: sdf.Vec3,
    bound_radius: f32,

    pub fn init(scene: demo.EuclideanScene) Scene {
        const cube_inverse_rotor = scene.cube_rotor.reverse();
        const axis_x = sdfVec3FromVector(zmath.ga.rotors.rotated(demo.H.Vector.init(.{ 1.0, 0.0, 0.0 }), cube_inverse_rotor));
        const axis_y = sdfVec3FromVector(zmath.ga.rotors.rotated(demo.H.Vector.init(.{ 0.0, 1.0, 0.0 }), cube_inverse_rotor));
        const axis_z = sdfVec3FromVector(zmath.ga.rotors.rotated(demo.H.Vector.init(.{ 0.0, 0.0, 1.0 }), cube_inverse_rotor));
        return .{
            .projection_mode = scene.projection_mode,
            .zoom = scene.zoom,
            .eye = sdfVec3FromVector(scene.eye),
            .right = sdfVec3FromVector(scene.right),
            .up = sdfVec3FromVector(scene.up),
            .forward = sdfVec3FromVector(scene.forward),
            .cube_half_extent = scene.cube_scale,
            .local_row_x = sdf.Vec3.init(.{ axis_x.named().e1, axis_y.named().e1, axis_z.named().e1 }),
            .local_row_y = sdf.Vec3.init(.{ axis_x.named().e2, axis_y.named().e2, axis_z.named().e2 }),
            .local_row_z = sdf.Vec3.init(.{ axis_x.named().e3, axis_y.named().e3, axis_z.named().e3 }),
            .bound_radius = scene.cube_scale * @sqrt(3.0),
        };
    }

    pub fn worldToCubeLocal(self: Scene, point: sdf.Vec3) sdf.Vec3 {
        return sdf.Vec3.init(.{
            point.scalarProduct(self.local_row_x),
            point.scalarProduct(self.local_row_y),
            point.scalarProduct(self.local_row_z),
        });
    }

    pub fn cubeLocalToWorldDirection(self: Scene, local: sdf.Vec3) sdf.Vec3 {
        return normalizeSdfVec3(sdf.Vec3.init(.{
            self.local_row_x.named().e1 * local.named().e1 + self.local_row_y.named().e1 * local.named().e2 + self.local_row_z.named().e1 * local.named().e3,
            self.local_row_x.named().e2 * local.named().e1 + self.local_row_y.named().e2 * local.named().e2 + self.local_row_z.named().e2 * local.named().e3,
            self.local_row_x.named().e3 * local.named().e1 + self.local_row_y.named().e3 * local.named().e2 + self.local_row_z.named().e3 * local.named().e3,
        }));
    }

    pub fn sample(self: *const Scene, point: sdf.Vec3) sdf.Sample {
        return .{
            .distance = sdf.box(self.worldToCubeLocal(point), sdf.Vec3.init(.{
                self.cube_half_extent,
                self.cube_half_extent,
                self.cube_half_extent,
            })),
            .material = 1,
        };
    }

    pub fn ray(
        self: Scene,
        sample_x: usize,
        sample_y: usize,
        canvas_width: usize,
        canvas_height: usize,
        sample_scale_x: usize,
        sample_scale_y: usize,
    ) sdf.Ray {
        const x_canvas = (@as(f32, @floatFromInt(sample_x)) + 0.5) / @as(f32, @floatFromInt(sample_scale_x));
        const y_canvas = (@as(f32, @floatFromInt(sample_y)) + 0.5) / @as(f32, @floatFromInt(sample_scale_y));
        const width_f = @as(f32, @floatFromInt(canvas_width));
        const height_f = @as(f32, @floatFromInt(canvas_height));
        const aspect = width_f / (height_f * 2.0);
        const x_ndc = x_canvas / (width_f * 0.5) - 1.0;
        const y_ndc = 1.0 - y_canvas / (height_f * 0.5);
        const depth_offset = projection.euclideanProjectionDepthOffset(self.projection_mode);
        const x_plane = x_ndc * aspect * depth_offset / self.zoom;
        const y_plane = y_ndc * depth_offset / self.zoom;
        const plane_point = self.eye.add(self.right.scale(x_plane)).add(self.up.scale(y_plane));

        return switch (self.projection_mode) {
            .perspective => {
                const origin = self.eye.sub(self.forward.scale(depth_offset));
                return .{
                    .origin = origin,
                    .direction = normalizeSdfVec3(plane_point.sub(origin)),
                };
            },
            .isometric => .{
                .origin = plane_point.sub(self.forward.scale(demo.far_clip_z + depth_offset)),
                .direction = self.forward,
            },
        };
    }

    pub fn traceRaw(self: *const Scene, ray_in: sdf.Ray, options: sdf.MarchOptions) ?sdf.Hit {
        return sdf.raymarchWith(sampleScene, self, ray_in, options);
    }

    pub fn traceAccelerated(self: *const Scene, ray_in: sdf.Ray, options: sdf.MarchOptions) ?sdf.Hit {
        const interval = raySphereInterval(ray_in, self.bound_radius) orelse return null;
        const slack = self.cube_half_extent * 0.18 + options.hit_epsilon * 4.0;
        var scoped = options;
        scoped.min_distance = @max(options.min_distance, @max(interval.enter - slack, 0.0));
        scoped.max_distance = @min(options.max_distance, interval.exit + slack);
        if (scoped.min_distance > scoped.max_distance) return null;
        return sdf.raymarchWith(sampleScene, self, ray_in, scoped);
    }

    pub fn localNormal(self: Scene, world_point: sdf.Vec3) sdf.Vec3 {
        return boxLocalNormal(self.worldToCubeLocal(world_point), self.cube_half_extent);
    }

    pub fn worldNormal(self: Scene, world_point: sdf.Vec3) sdf.Vec3 {
        return self.cubeLocalToWorldDirection(self.localNormal(world_point));
    }

    pub fn viewDepth(self: Scene, point: sdf.Vec3) f32 {
        return point.sub(self.eye).scalarProduct(self.forward);
    }
};

pub const RayInterval = struct {
    enter: f32,
    exit: f32,
};

pub fn sampleScene(scene: *const Scene, point: sdf.Vec3) sdf.Sample {
    return scene.sample(point);
}

pub fn raySphereInterval(ray: sdf.Ray, radius: f32) ?RayInterval {
    const b = ray.origin.scalarProduct(ray.direction);
    const c = ray.origin.scalarProduct(ray.origin) - radius * radius;
    const disc = b * b - c;
    if (disc < 0.0) return null;
    const root = @sqrt(disc);
    const t0 = -b - root;
    const t1 = -b + root;
    if (t1 < 0.0) return null;
    return .{
        .enter = t0,
        .exit = t1,
    };
}

pub fn boxLocalNormal(point: sdf.Vec3, half_extent: f32) sdf.Vec3 {
    const abs_point = sdf.Vec3.init(.{
        @abs(point.named().e1),
        @abs(point.named().e2),
        @abs(point.named().e3),
    });
    const delta = abs_point.sub(sdf.Vec3.init(.{ half_extent, half_extent, half_extent }));
    const outside = sdf.Vec3.init(.{
        @max(delta.named().e1, 0.0),
        @max(delta.named().e2, 0.0),
        @max(delta.named().e3, 0.0),
    });
    if (outside.scalarProduct(outside) > 1e-8) {
        return normalizeSdfVec3(sdf.Vec3.init(.{
            signedUnit(point.named().e1) * outside.named().e1,
            signedUnit(point.named().e2) * outside.named().e2,
            signedUnit(point.named().e3) * outside.named().e3,
        }));
    }

    if (abs_point.named().e1 >= abs_point.named().e2 and abs_point.named().e1 >= abs_point.named().e3) {
        return sdf.Vec3.init(.{ signedUnit(point.named().e1), 0.0, 0.0 });
    }
    if (abs_point.named().e2 >= abs_point.named().e3) {
        return sdf.Vec3.init(.{ 0.0, signedUnit(point.named().e2), 0.0 });
    }
    return sdf.Vec3.init(.{ 0.0, 0.0, signedUnit(point.named().e3) });
}

fn signedUnit(value: f32) f32 {
    return if (value < 0.0) -1.0 else 1.0;
}

fn sdfVec3FromVector(v: demo.H.Vector) sdf.Vec3 {
    return sdf.Vec3.init(.{ v.coeffNamed("e1"), v.coeffNamed("e2"), v.coeffNamed("e3") });
}

test "bounding sphere interval rejects clear misses" {
    const ray = sdf.Ray{
        .origin = sdf.Vec3.init(.{ 3.0, 0.0, 0.0 }),
        .direction = sdf.Vec3.init(.{ 0.0, 0.0, 1.0 }),
    };
    try std.testing.expect(raySphereInterval(ray, 1.0) == null);
}

test "box local normal picks dominant face inside box shell" {
    const normal = boxLocalNormal(sdf.Vec3.init(.{ 0.99, 0.10, 0.20 }), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), normal.named().e1, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normal.named().e2, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), normal.named().e3, 1e-6);
}

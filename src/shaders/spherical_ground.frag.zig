const std = @import("std");

pub const out_color = @extern(*addrspace(.output) @Vector(4, f32), .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

const radius: f32 = 6.0;
const eye_height: f32 = 1.1;
const half_fov: f32 = 89.0 * std.math.pi / 180.0;
const origin_angle: f32 = eye_height / radius;
const tan_half_fov: f32 = @tan(half_fov / 2.0);

fn fastAtan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    const largest = @max(ax, ay);
    const smallest = @min(ax, ay);
    if (largest == 0.0) return 0.0;
    const t = smallest / largest;
    const s = t * t;
    const atan_t = t * (0.9998660 + s * (-0.3302995 + s * (0.180141 + s * (-0.085133 + s * 0.0208351))));
    var angle = if (ay > ax) std.math.pi / 2.0 - atan_t else atan_t;
    if (x < 0.0) angle = std.math.pi - angle;
    if (y < 0.0) angle = -angle;
    return angle;
}

export fn main() callconv(.spirv_fragment) void {
    const resolution = @Vector(2, f32){ 960.0, 640.0 };
    const pixel = std.gpu.frag_coord;
    const uv = @Vector(2, f32){
        (pixel[0] / resolution[0]) * 2.0 - 1.0,
        (pixel[1] / resolution[1]) * 2.0 - 1.0,
    };
    const r = @sqrt(uv[0] * uv[0] + uv[1] * uv[1]);
    const t = r * tan_half_fov;
    const inverse = 1.0 / (1.0 + t * t);
    const sin_theta = 2.0 * t * inverse;
    const cos_theta = (1.0 - t * t) * inverse;
    const radial_x = if (r < 0.000001) 0.0 else sin_theta * uv[0] / r;
    const radial_y = if (r < 0.000001) 0.0 else sin_theta * uv[1] / r;

    const direction = @Vector(4, f32){ 0.0, radial_x, radial_y, cos_theta };
    const origin = @Vector(4, f32){ @cos(origin_angle), 0.0, @sin(origin_angle), 0.0 };
    const ground_a = origin[2];
    const ground_b = direction[2];
    const ground_h = @sqrt(ground_b * ground_b + ground_a * ground_a);
    const ground_c = -ground_b / ground_h;
    const ground_s = ground_a / ground_h;
    const point = origin * @as(@Vector(4, f32), @splat(ground_c)) + direction * @as(@Vector(4, f32), @splat(ground_s));

    const walk = point[3] * radius;
    const strafe = fastAtan2(point[1], point[0]) * radius;
    const checker = @floor(walk) + @floor(strafe);
    const light = 0.6 + 0.4 * @abs(ground_b);
    const dark = checker - @floor(checker / 2.0) * 2.0 >= 1.0;
    const base = if (dark) @Vector(3, f32){ 0.18, 0.21, 0.19 } else @Vector(3, f32){ 0.36, 0.41, 0.38 };
    const rgb = base * @as(@Vector(3, f32), @splat(light));
    out_color.* = .{ rgb[0], rgb[1], rgb[2], 1.0 };
}

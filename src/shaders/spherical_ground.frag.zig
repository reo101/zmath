const std = @import("std");

const Vec4 = @Vector(4, f32);
const FrameFloats = extern struct { values: [22]f32 };

pub const out_color = @extern(*addrspace(.output) Vec4, .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

const frame = @extern(*addrspace(.push_constant) const FrameFloats, .{ .name = "Frame" });

fn dot4(a: Vec4, b: Vec4) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn diagonal(value: f32) Vec4 {
    return @splat(value);
}

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

fn fastAsin(x: f32) f32 {
    const clamped = std.math.clamp(x, -1.0, 1.0);
    return fastAtan2(clamped, @sqrt(@max(0.0, 1.0 - clamped * clamped)));
}

fn frameDirection(uv: @Vector(2, f32)) Vec4 {
    const r = @sqrt(uv[0] * uv[0] + uv[1] * uv[1]);
    if (r < 0.000001) return .{ frame.values[18], frame.values[19], frame.values[20], frame.values[21] };
    const t = r * frame.values[3];
    const inverse = 1.0 / (1.0 + t * t);
    const sin_theta = 2.0 * t * inverse;
    const cos_theta = (1.0 - t * t) * inverse;
    var result: Vec4 = @Vector(4, f32){ frame.values[18], frame.values[19], frame.values[20], frame.values[21] } * diagonal(cos_theta);
    result += @Vector(4, f32){ frame.values[10], frame.values[11], frame.values[12], frame.values[13] } * diagonal(sin_theta * uv[0] / r);
    result += @Vector(4, f32){ frame.values[14], frame.values[15], frame.values[16], frame.values[17] } * diagonal(sin_theta * uv[1] / r);
    return result;
}

fn groundColor(point: Vec4) Vec4 {
    const walk = fastAsin(point[3]) * frame.values[2];
    const strafe = fastAtan2(point[1], point[0]) * frame.values[2];
    const walk_floor = @floor(walk);
    const strafe_floor = @floor(strafe);
    const checker = walk_floor + strafe_floor - @floor((walk_floor + strafe_floor) / 2.0) * 2.0;
    if (checker < 0.5) return .{ 92.0 / 255.0, 104.0 / 255.0, 96.0 / 255.0, 1.0 };
    return .{ 46.0 / 255.0, 54.0 / 255.0, 50.0 / 255.0, 1.0 };
}

export fn main() callconv(.spirv_fragment) void {
    const pixel = std.gpu.frag_coord;
    const uv = @Vector(2, f32){
        ((pixel[0] / frame.values[0]) * 2.0 - 1.0) * frame.values[0] / frame.values[1] / (1280.0 / 720.0),
        (1.0 - pixel[1] / frame.values[1]) * 2.0 - 1.0,
    };
    if (uv[0] * uv[0] + uv[1] * uv[1] > 1.0) {
        out_color.* = .{ 4.0 / 255.0, 6.0 / 255.0, 10.0 / 255.0, 1.0 };
        std.gpu.frag_depth = 1.0;
        return;
    }

    const dir = frameDirection(uv);
    const ground_b = dot4(dir, .{ 0.0, 0.0, 1.0, 0.0 });
    const ground_h = @sqrt(ground_b * ground_b + frame.values[4] * frame.values[4]);
    const ground_c = -ground_b / ground_h;
    const ground_s = frame.values[4] / ground_h;
    const origin = @Vector(4, f32){ frame.values[6], frame.values[7], frame.values[8], frame.values[9] };
    const point = origin * diagonal(ground_c) + dir * diagonal(ground_s);
    const tangent = dir * diagonal(ground_c) - origin * diagonal(ground_s);
    const brightness = @abs(dot4(tangent, .{ 0.0, 0.0, 1.0, 0.0 }));
    out_color.* = groundColor(point) * diagonal(0.6 + 0.4 * brightness);
    std.gpu.frag_depth = (1.0 - ground_c) * 0.5;
}

pub const depth_replacing = std.gpu.executionMode(main, .depth_replacing);

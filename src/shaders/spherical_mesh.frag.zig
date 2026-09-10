const std = @import("std");

const Vec4 = @Vector(4, f32);
const FrameFloats = extern struct { values: [22]f32 };

const in_color = @extern(*addrspace(.input) Vec4, .{
    .name = "color",
    .decoration = .{ .location = 0 },
});
const in_plane = @extern(*addrspace(.input) Vec4, .{
    .name = "plane",
    .decoration = .{ .location = 1 },
});
const frame = @extern(*addrspace(.push_constant) const FrameFloats, .{ .name = "Frame" });

pub const out_color = @extern(*addrspace(.output) Vec4, .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

fn dot4(a: Vec4, b: Vec4) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn diagonal(value: f32) Vec4 {
    return @splat(value);
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

export fn main() callconv(.spirv_fragment) void {
    const pixel = std.gpu.frag_coord;
    const uv = @Vector(2, f32){
        ((pixel[0] / frame.values[0]) * 2.0 - 1.0) * frame.values[0] / frame.values[1] / (1280.0 / 720.0),
        (1.0 - pixel[1] / frame.values[1]) * 2.0 - 1.0,
    };
    const origin = @Vector(4, f32){ frame.values[6], frame.values[7], frame.values[8], frame.values[9] };
    const a = dot4(origin, in_plane.*);
    const b = dot4(frameDirection(uv), in_plane.*);
    const h = @sqrt(a * a + b * b);
    const valid = h >= 1e-5;
    std.gpu.frag_depth = if (valid) (1.0 - (if (a >= 0.0) -b / h else b / h)) * 0.5 else 1.0;
    out_color.* = in_color.*;
}

pub const depth_replacing = std.gpu.executionMode(main, .depth_replacing);

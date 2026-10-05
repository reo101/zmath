const std = @import("std");
const spherical = @import("spherical_geometry");

pub const RawVec4 = @Vector(4, f32);
pub const FrameData = extern struct {
    viewport: RawVec4,
    origin: RawVec4,
    right: RawVec4,
    up: RawVec4,
    forward: RawVec4,
};
pub const frame_descriptor_decoration: std.lang.ExternOptions.Decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } };
pub const E4 = spherical.h;
pub const Vector = spherical.Point;
pub const ground_normal = E4.Basis.e(3).cast(Vector);
pub const greatSphereIntersection = spherical.greatSphereIntersection;
pub const rasterProjection = spherical.rasterProjection;

pub inline fn vector(storage: RawVec4) Vector {
    return .initStorage(storage);
}

pub inline fn screenRadiusSquared(uv: @Vector(2, f32)) f32 {
    return spherical.screenRadiusSquared(uv[0], uv[1]);
}

pub inline fn direction(
    uv: @Vector(2, f32),
    tan_half_fov: f32,
    forward: Vector,
    right: Vector,
    up: Vector,
) Vector {
    return spherical.frameDirection(forward, right, up, tan_half_fov, uv[0], uv[1]);
}

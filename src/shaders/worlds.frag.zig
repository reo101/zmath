const std = @import("std");
const worlds = @import("worlds_render");

const RawVec4 = @Vector(4, f32);
const FrameData = extern struct {
    viewport: RawVec4,
    origin: RawVec4,
    right: RawVec4,
    up: RawVec4,
    forward: RawVec4,
    projection: RawVec4,
};

const frame = @extern(*addrspace(.uniform) const FrameData, .{
    .name = "Frame",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});
pub const out_color = @extern(*addrspace(.output) RawVec4, .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    const camera = worlds.Frame{
        .viewport = frame.viewport,
        .origin = .initStorage(frame.origin),
        .right = .initStorage(frame.right),
        .up = .initStorage(frame.up),
        .forward = .initStorage(frame.forward),
        .projection = frame.projection,
    };
    const pixel = std.spirv.frag_coord;
    const u = (pixel[0] / camera.viewport[0]) * 2.0 - 1.0;
    const v = 1.0 - (pixel[1] / camera.viewport[1]) * 2.0;
    if (worlds.selectorColor(pixel[0], pixel[1], camera.projection[0])) |color| {
        out_color.* = color;
    } else if (camera.projection[0] == 2) {
        // In spherical mode this pipeline only overlays the selectors.
        out_color.* = .{ 0, 0, 0, 0 };
    } else {
        out_color.* = worlds.shade(camera, u, v);
    }
}

//! Four-space demo using the shared Vulkan frontend and Zig-authored shaders.
const std = @import("std");
const renderer = @import("vulkan_renderer");

pub fn main(init: std.process.Init) !void {
    try renderer.runWorlds(init);
}

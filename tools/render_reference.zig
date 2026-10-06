//! Native reference samples for the opt-in non-spherical GPU parity check.
const std = @import("std");
const render = @import("worlds_render");
const space = render.space;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const name = args.next() orelse return error.InvalidArgument;
    const kind: space.Kind = if (std.mem.eql(u8, name, "euclidean")) .euclidean else if (std.mem.eql(u8, name, "isometric")) .isometric else if (std.mem.eql(u8, name, "hyperbolic")) .hyperbolic else return error.InvalidWorld;
    const width = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArgument, 10);
    const height = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArgument, 10);
    if (width < 32 or height < 160) return error.InvalidArgument;
    var pose: [3]f32 = undefined;
    for (&pose) |*value| value.* = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument);
    if (args.next() != null) return error.InvalidArgument;
    var mode = space.Mode.init(kind);
    mode.applyCapture(pose[0], 0);
    switch (mode) {
        .euclidean => |*view| view.* = view.yawBy(pose[1]).pitchBy(-pose[2]),
        .isometric => |*view| view.* = view.yawBy(pose[1]),
        .hyperbolic => |*view| view.* = view.yaw(pose[1]).pitch(-pose[2]),
        .spherical => unreachable,
    }
    const frame = render.Frame.init(mode, @floatFromInt(width), @floatFromInt(height));
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("[\n");
    // A grid exercises sky/ground and object interiors, not just the center ray.
    for (0..9) |row| {
        for (0..9) |column| {
            const x = (width * (2 * @as(u32, @intCast(column)) + 1)) / 18;
            const y = (height * (2 * @as(u32, @intCast(row)) + 1)) / 18;
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(width)) * 2 - 1;
            const v = 1 - (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(height)) * 2;
            const color = render.selectorColor(@floatFromInt(x), @floatFromInt(y), frame.projection[0]) orelse render.shade(frame, u, v);
            const hit = frame.hit(u, v);
            try stdout.print("{{\"x\":{d},\"y\":{d},\"rgb\":[{d},{d},{d}],\"surface\":\"{s}\"}}{s}\n", .{
                x,
                y,
                std.math.clamp(color[0], 0, 1),
                std.math.clamp(color[1], 0, 1),
                std.math.clamp(color[2], 0, 1),
                if (render.selectorColor(@floatFromInt(x), @floatFromInt(y), frame.projection[0]) != null) "selector" else @tagName(hit.surface),
                if (row == 8 and column == 8) "" else ",",
            });
        }
    }
    try stdout.writeAll("]\n");
    try stdout.flush();
}

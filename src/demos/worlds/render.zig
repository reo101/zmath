//! Camera upload and non-spherical shading shared by CPU checks and SPIR-V.
const std = @import("std");
const scene = @import("spherical_scene");
pub const space = @import("space.zig");

/// The first 80 bytes match the canonical spherical frame uniform.
pub const Frame = extern struct {
    viewport: [4]f32,
    origin: scene.Point,
    right: scene.Direction,
    up: scene.Direction,
    forward: scene.Direction,
    /// Space tag, orthographic half width, and two reserved components.
    projection: [4]f32,

    pub fn init(mode: space.Mode, width: f32, height: f32) Frame {
        const kind = std.meta.activeTag(mode);
        const projection = [4]f32{ @floatFromInt(@backingInt(kind)), 0, 0, 0 };
        switch (mode) {
            .euclidean, .isometric => {
                const camera = mode.renderer().flat;
                var frame = Frame{
                    .viewport = .{ width, height, 0, camera.tan_half_fov },
                    .origin = .init(.{ camera.eye[0], camera.eye[1], camera.eye[2], 1 }),
                    .right = .init(.{ camera.right[0], camera.right[1], camera.right[2], 0 }),
                    .up = .init(.{ camera.up[0], camera.up[1], camera.up[2], 0 }),
                    .forward = .init(.{ camera.forward[0], camera.forward[1], camera.forward[2], 0 }),
                    .projection = projection,
                };
                frame.projection[1] = camera.ortho_half_width orelse 0;
                return frame;
            },
            .spherical => |world| {
                const camera = world.frameCamera();
                return .{
                    .viewport = .{ width, height, camera.radius, camera.tan_half_fov },
                    .origin = camera.pose.position,
                    .right = camera.pose.right,
                    .up = camera.pose.up,
                    .forward = camera.pose.forward,
                    .projection = projection,
                };
            },
            .hyperbolic => |pose| {
                const camera = pose.camera();
                // Preserve Lorentz coefficients; the shader decodes them with
                // the hyperbolic metric, not the upload carrier's metric.
                return .{
                    .viewport = .{ width, height, space.hyperbolic.radius, @tan(space.hyperbolic.half_fov / 2.0) },
                    .origin = .init(camera.eye.coeffsArray()),
                    .right = .init(camera.right.coeffsArray()),
                    .up = .init(camera.up.coeffsArray()),
                    .forward = .init(camera.forward.coeffsArray()),
                    .projection = projection,
                };
            },
        }
    }

    pub fn hit(self: Frame, u: f32, v: f32) space.Hit {
        const origin = self.origin.coeffsArray();
        const right = self.right.coeffsArray();
        const up = self.up.coeffsArray();
        const forward = self.forward.coeffsArray();
        const aspect = self.viewport[0] / self.viewport[1];
        if (self.projection[0] == @as(f32, @floatFromInt(@backingInt(space.Kind.hyperbolic)))) {
            return (space.hyperbolic.Renderer{
                .k = .{ origin[0] / origin[3], origin[1] / origin[3], origin[2] / origin[3] },
                .lambda_eye = origin[3],
                .right = right,
                .up = up,
                .forward = forward,
                .tan_half_fov = self.viewport[3],
                .aspect = aspect,
            }).render(u, v);
        }
        // Spherical mode uses the canonical mesh/ground shaders, never this
        // per-fragment tracer. The remaining two tags select flat cameras.
        return (space.flat.Renderer{
            .eye = .{ origin[0], origin[1], origin[2] },
            .right = .{ right[0], right[1], right[2] },
            .up = .{ up[0], up[1], up[2] },
            .forward = .{ forward[0], forward[1], forward[2] },
            .tan_half_fov = self.viewport[3],
            .aspect = aspect,
            .ortho_half_width = if (self.projection[0] == @as(f32, @floatFromInt(@backingInt(space.Kind.isometric)))) self.projection[1] else null,
        }).render(u, v);
    }
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 96);
    for (.{ "viewport", "origin", "right", "up", "forward", "projection" }, 0..) |field, index| {
        std.debug.assert(@offsetOf(Frame, field) == index * 16);
    }
}

pub fn shade(frame: Frame, u: f32, v: f32) [4]f32 {
    const hit = frame.hit(u, v);
    const dim = 1.0 - 0.25 * hit.depth01;
    const rgb: [3]f32 = switch (hit.surface) {
        .cube => |face| switch (face) {
            .left => .{ 82, 190, 224 },
            .right => .{ 245, 96, 83 },
            .top => .{ 255, 184, 77 },
            .front => .{ 92, 173, 126 },
            .back => .{ 143, 124, 230 },
            .bottom => .{ 30, 34, 44 },
        },
        .fence => .{ 226, 218, 194 },
        .ground => blk: {
            const sum = @floor(hit.cell[0]) + @floor(hit.cell[1]);
            const checker = sum - @floor(sum / 2.0) * 2.0;
            break :blk if (checker < 0.5) .{ 92, 104, 96 } else .{ 46, 54, 50 };
        },
        .sky => .{ 96, 128, 158 },
    };
    const brightness = switch (hit.surface) {
        .cube, .fence => (0.55 + 0.45 * hit.brightness) * dim,
        .ground => (0.6 + 0.4 * hit.brightness) * dim,
        .sky => 1.0 - 0.3 * @max(v, 0.0),
    };
    return .{ rgb[0] * brightness / 255.0, rgb[1] * brightness / 255.0, rgb[2] * brightness / 255.0, 1 };
}

/// Fixed framebuffer-pixel selectors, also used by GLFW mouse hit testing.
pub fn selectorKind(x: f32, y: f32) ?space.Kind {
    if (x < 16 or x >= 16 + 4 * 168 or y < 118 or y >= 144) return null;
    const button: usize = @intFromFloat(@floor((x - 16) / 168));
    if (x - (16 + @as(f32, @floatFromInt(button)) * 168) >= 162) return null;
    return @fromBackingInt(@as(u2, @intCast(button)));
}

pub fn selectorColor(x: f32, y: f32, active: f32) ?[4]f32 {
    const kind = selectorKind(x, y) orelse return null;
    const button: u32 = @backingInt(kind);
    const selected = active == @as(f32, @floatFromInt(button));
    const background: [4]f32 = if (selected) .{ 1, 184.0 / 255.0, 77.0 / 255.0, 1 } else .{ 24.0 / 255.0, 30.0 / 255.0, 40.0 / 255.0, 1 };
    const local_x = x - (26 + @as(f32, @floatFromInt(button)) * 168);
    const local_y = y - 124;
    if (local_x < 0 or local_x >= 120 or local_y < 0 or local_y >= 14) return background;
    const character: usize = @intFromFloat(@floor(local_x / 10));
    const column: u32 = @intFromFloat(@floor((local_x - @as(f32, @floatFromInt(character)) * 10) / 2));
    const row: u32 = @intFromFloat(@floor(local_y / 2));
    if (column >= 4) return background;
    const label: [12]u32 = switch (button) {
        0 => .{ '1', ' ', 'e', 'u', 'c', 'l', 'i', 'd', 'e', 'a', 'n', ' ' },
        1 => .{ '2', ' ', 'i', 's', 'o', 'm', 'e', 't', 'r', 'i', 'c', ' ' },
        2 => .{ '3', ' ', 's', 'p', 'h', 'e', 'r', 'i', 'c', 'a', 'l', ' ' },
        else => .{ '4', ' ', 'h', 'y', 'p', 'e', 'r', 'b', 'o', 'l', 'i', 'c' },
    };
    const bitmap: u32 = switch (label[character]) {
        '1' => 0b0010_0110_0010_0010_0010_0010_0111,
        '2' => 0b0110_1001_0001_0010_0100_1000_1111,
        '3' => 0b1110_0001_0001_0110_0001_0001_1110,
        '4' => 0b0010_0110_1010_1111_0010_0010_0010,
        'a' => 0b0000_0000_0110_0001_0111_1001_0111,
        'b' => 0b1000_1000_1110_1001_1001_1001_1110,
        'c' => 0b0000_0000_0111_1000_1000_1000_0111,
        'd' => 0b0001_0001_0111_1001_1001_1001_0111,
        'e' => 0b0000_0000_0110_1001_1111_1000_0111,
        'h' => 0b1000_1000_1110_1001_1001_1001_1001,
        'i' => 0b0010_0000_0110_0010_0010_0010_0111,
        'l' => 0b0110_0010_0010_0010_0010_0010_0111,
        'm' => 0b0000_0000_1110_1111_1011_1001_1001,
        'n' => 0b0000_0000_1110_1001_1001_1001_1001,
        'o' => 0b0000_0000_0110_1001_1001_1001_0110,
        'p' => 0b0000_0000_1110_1001_1110_1000_1000,
        'r' => 0b0000_0000_1011_1100_1000_1000_1000,
        's' => 0b0000_0000_0111_1000_0110_0001_1110,
        't' => 0b0100_0100_1110_0100_0100_0100_0011,
        'u' => 0b0000_0000_1001_1001_1001_1001_0111,
        'y' => 0b0000_0000_1001_1001_0111_0001_1110,
        else => 0,
    };
    const shift: u5 = @intCast(27 - row * 4 - column);
    if ((bitmap >> shift) & 1 == 0) return background;
    return if (selected) .{ 24.0 / 255.0, 26.0 / 255.0, 32.0 / 255.0, 1 } else .{ 150.0 / 255.0, 174.0 / 255.0, 201.0 / 255.0, 1 };
}

test "world selectors preserve button bounds and active colors" {
    try std.testing.expectEqual(space.Kind.spherical, selectorKind(360, 120).?);
    try std.testing.expectEqual(@as(?space.Kind, null), selectorKind(179, 120));
    try std.testing.expectEqual(@as(?space.Kind, null), selectorKind(20, 145));
    try std.testing.expect(selectorColor(20, 120, 0).?[0] > selectorColor(20, 120, 1).?[0]);
}

test "GPU camera decoding matches non-spherical CPU tracers" {
    const modes = [_]space.Mode{
        .{ .euclidean = (space.flat.View{}).walkForward(1).yawBy(0.2).pitchBy(-0.3) },
        .{ .isometric = (space.flat.IsoView{}).pan(1, 2).yawBy(0.2).zoom(1.1) },
        .{ .hyperbolic = space.hyperbolic.Pose.start().walkForward(1).yaw(0.2).pitch(-0.3) },
    };
    for (modes) |mode| {
        const frame = Frame.init(mode, 640, 960);
        var reference = mode.renderer();
        switch (reference) {
            .flat => |*camera| camera.aspect = 640.0 / 960.0,
            .hyperbolic => |*camera| camera.aspect = 640.0 / 960.0,
            .spherical => unreachable,
        }
        for ([_]f32{ -0.8, 0, 0.8 }) |u| {
            for ([_]f32{ -0.8, 0, 0.8 }) |v| {
                const expected = reference.render(u, v);
                const actual = frame.hit(u, v);
                try std.testing.expectEqual(expected.surface, actual.surface);
                try std.testing.expectApproxEqAbs(expected.depth01, actual.depth01, 1e-5);
                try std.testing.expectApproxEqAbs(expected.brightness, actual.brightness, 1e-5);
                for (expected.cell, actual.cell) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-5);
                const rgba = shade(frame, u, v);
                for (rgba) |component| try std.testing.expect(component >= 0 and component <= 1);
            }
        }
    }
}

test "spherical upload uses the canonical camera and live dimensions" {
    var world = scene.Scene.init();
    world.walkForward(1);
    world.yaw(0.2);
    world.pitch(-0.3);
    const frame = Frame.init(.{ .spherical = world }, 1280, 720);
    const camera = world.frameCamera();
    try std.testing.expectEqual(camera.pose.position, frame.origin);
    try std.testing.expectEqual(camera.pose.forward, frame.forward);
    try std.testing.expectEqual(camera.pose.right, frame.right);
    try std.testing.expectEqual(camera.pose.up, frame.up);
    try std.testing.expectEqual(@as(f32, 1280), frame.viewport[0]);
    try std.testing.expectEqual(@as(f32, 720), frame.viewport[1]);
    try std.testing.expectEqual(@as(f32, 2), frame.projection[0]);
}

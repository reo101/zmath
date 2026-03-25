const std = @import("std");
const zmath = @import("zmath");
const visualizer = @import("zmath").visualizer;

const Cl3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Cl3.Instantiate(f32);
const E3 = h.Basis;
const DemoMode = enum { perspective, isometric, hyperbolic, spherical };
const EscapeState = enum { idle, esc, csi };
const CameraState = struct {
    rotation: f32 = 0.0,
    pitch: f32 = 0.18,
    eye_x: f32 = 0.0,
    eye_y: f32 = 0.0,
    eye_z: f32 = -10.5,

    fn eyeVector(self: CameraState) h.Vector {
        return h.Vector.init(.{ self.eye_x, self.eye_y, self.eye_z });
    }
};

fn gaCross(a: h.Vector, b: h.Vector) h.Vector {
    // In Euclidean 3D, cross(a, b) corresponds to -dual(a wedge b).
    return a.wedge(b).dual().negate();
}

fn safeNormalize(v: h.Vector, fallback: h.Vector) h.Vector {
    return h.normalize(v) catch fallback;
}

fn lookAtCameraSpace(v: h.Vector, eye: h.Vector, target: h.Vector, up_hint: h.Vector) h.Vector {
    const forward = safeNormalize(target.sub(eye), h.Vector.init(.{ 0, 0, 1 }));

    var right = gaCross(up_hint, forward);
    if (right.scalarProduct(right) <= 1e-6) right = h.Vector.init(.{ 1, 0, 0 });
    right = safeNormalize(right, h.Vector.init(.{ 1, 0, 0 }));

    const up = safeNormalize(gaCross(forward, right), h.Vector.init(.{ 0, 1, 0 }));
    const rel = v.sub(eye);

    return h.Vector.init(.{
        rel.scalarProduct(right),
        rel.scalarProduct(up),
        rel.scalarProduct(forward),
    });
}

fn forwardFromAngles(rotation: f32, pitch: f32) h.Vector {
    const cos_pitch = @cos(pitch);
    return h.Vector.init(.{
        @sin(rotation) * cos_pitch,
        @sin(pitch),
        @cos(rotation) * cos_pitch,
    });
}

fn orientedCameraSpace(v: h.Vector, eye: h.Vector, rotation: f32, pitch: f32) h.Vector {
    const forward = forwardFromAngles(rotation, pitch);
    var right = gaCross(h.Vector.init(.{ 0, 1, 0 }), forward);
    if (right.scalarProduct(right) <= 1e-6) right = h.Vector.init(.{ 1, 0, 0 });
    right = safeNormalize(right, h.Vector.init(.{ 1, 0, 0 }));

    const up = safeNormalize(gaCross(forward, right), h.Vector.init(.{ 0, 1, 0 }));
    const rel = v.sub(eye);

    return h.Vector.init(.{
        rel.scalarProduct(right),
        rel.scalarProduct(up),
        rel.scalarProduct(forward),
    });
}

fn isometricCameraSpace(v: h.Vector) h.Vector {
    return lookAtCameraSpace(
        v,
        h.Vector.init(.{ -18.0, 16.0, -18.0 }),
        h.Vector.zero(),
        h.Vector.init(.{ 0, 1, 0 }),
    );
}

fn hyperbolicCameraSpace(v: h.Vector) h.Vector {
    return lookAtCameraSpace(
        v,
        h.Vector.init(.{ -5.8, 6.2, -8.2 }),
        h.Vector.init(.{ 1.8, 2.8, 3.2 }),
        h.Vector.init(.{ 0, 1, 0 }),
    );
}

fn sphericalCameraSpace(v: h.Vector, angle: f32, camera: CameraState) h.Vector {
    const cycle = 0.5 + 0.5 * @sin(angle * 0.08);
    const eased = cycle * cycle * (3.0 - 2.0 * cycle);
    const dolly = -2.4 + 5.8 * eased;
    const eye = camera.eyeVector().add(forwardFromAngles(camera.rotation, camera.pitch).scale(dolly));
    return orientedCameraSpace(v, eye, camera.rotation, camera.pitch);
}

fn cameraSpace(v: h.Vector, camera: CameraState) h.Vector {
    return orientedCameraSpace(v, camera.eyeVector(), camera.rotation, camera.pitch);
}

fn rotorFromGenerator(B: anytype) h.Rotor {
    if (B.magnitude() <= 1e-6) return h.Rotor.init(.{ 1, 0, 0, 0 });

    const exp_rotor = B.scale(-0.5).exp();
    var rotor = h.Rotor.zero();
    inline for (h.Rotor.blades, 0..) |mask, i| {
        rotor.coeffs[i] = exp_rotor.coeff(mask);
    }
    return zmath.ga.rotors.normalizedRotor(rotor);
}

fn sceneRotor(angle: f32, mode: DemoMode) h.Rotor {
    return switch (mode) {
        .perspective => rotorFromGenerator(
            E3.signedBlade("e12")
                .scale(@cos(angle * 0.3))
                .add(E3.signedBlade("e23").scale(@sin(angle * 0.5)))
                .add(E3.signedBlade("e13").scale(@cos(angle * 0.7))),
        ),
        .isometric => rotorFromGenerator(
            E3.signedBlade("e13")
                .scale(angle * 0.35)
                .add(E3.signedBlade("e12").scale(0.18 * @sin(angle * 0.17))),
        ),
        .hyperbolic => rotorFromGenerator(
            E3.signedBlade("e13")
                .scale(angle * 0.18)
                .add(E3.signedBlade("e23").scale(-0.55 + 0.08 * @sin(angle * 0.13))),
        ),
        .spherical => h.Rotor.init(.{ 1, 0, 0, 0 }),
    };
}

fn modeZoom(angle: f32, mode: DemoMode) f32 {
    return switch (mode) {
        .perspective => 5.75 + 0.20 * @sin(angle * 0.10),
        .isometric => 0.82 + 0.04 * @sin(angle * 0.12),
        .hyperbolic => 18.6 + 0.80 * @sin(angle * 0.08),
        .spherical => 1.34 + 0.05 * @sin(angle * 0.06),
    };
}

fn viewSpace(v: h.Vector, angle: f32, mode: DemoMode, camera: CameraState) h.Vector {
    return switch (mode) {
        .perspective, .isometric, .hyperbolic => cameraSpace(v, camera),
        .spherical => sphericalCameraSpace(v, angle, camera),
    };
}

fn projectionMode(mode: DemoMode) visualizer.ProjectionMode {
    return switch (mode) {
        .perspective => .perspective,
        .isometric => .isometric,
        .hyperbolic => .hyperbolic,
        .spherical => .spherical,
    };
}

fn projectionModeLabel(mode: DemoMode) []const u8 {
    return switch (mode) {
        .perspective => "perspective (point)",
        .isometric => "isometric (plane)",
        .hyperbolic => "hyperbolic",
        .spherical => "spherical",
    };
}

fn nextMode(mode: DemoMode) DemoMode {
    return switch (mode) {
        .perspective => .isometric,
        .isometric => .hyperbolic,
        .hyperbolic => .spherical,
        .spherical => .perspective,
    };
}

fn adjustCameraArrow(camera: *CameraState, arrow: u8) void {
    const pitch_step: f32 = 0.10;
    const rotation_step: f32 = 0.14;

    switch (arrow) {
        'A' => camera.pitch = std.math.clamp(camera.pitch + pitch_step, -1.10, 1.10),
        'B' => camera.pitch = std.math.clamp(camera.pitch - pitch_step, -1.10, 1.10),
        'C' => camera.rotation += rotation_step,
        'D' => camera.rotation -= rotation_step,
        else => {},
    }
}

fn adjustCameraTranslation(camera: *CameraState, key: u8) void {
    const step: f32 = 0.90;
    const sin_rotation = @sin(camera.rotation);
    const cos_rotation = @cos(camera.rotation);
    const forward_x = sin_rotation;
    const forward_z = cos_rotation;
    const right_x = cos_rotation;
    const right_z = -sin_rotation;

    switch (key) {
        'a' => {
            camera.eye_x -= right_x * step;
            camera.eye_z -= right_z * step;
        },
        'd' => {
            camera.eye_x += right_x * step;
            camera.eye_z += right_z * step;
        },
        's' => {
            camera.eye_x -= forward_x * step;
            camera.eye_z -= forward_z * step;
        },
        'w' => {
            camera.eye_x += forward_x * step;
            camera.eye_z += forward_z * step;
        },
        else => {},
    }
}

fn handleInputByte(
    byte: u8,
    escape_state: *EscapeState,
    mode: *DemoMode,
    animate: *bool,
    camera: *CameraState,
) bool {
    switch (escape_state.*) {
        .idle => switch (byte) {
            0x1b => {
                escape_state.* = .esc;
                return false;
            },
            ' ' => {
                mode.* = nextMode(mode.*);
                return false;
            },
            'p' => {
                animate.* = !animate.*;
                return false;
            },
            'q' => return true,
            'w', 'a', 's', 'd' => {
                adjustCameraTranslation(camera, byte);
                return false;
            },
            else => return false,
        },
        .esc => {
            escape_state.* = if (byte == '[') .csi else .idle;
            return false;
        },
        .csi => {
            adjustCameraArrow(camera, byte);
            escape_state.* = .idle;
            return false;
        },
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout_fd = std.posix.STDOUT_FILENO;
    const stdin_fd = std.posix.STDIN_FILENO;

    const original_termios = try std.posix.tcgetattr(stdin_fd);
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};

    var width: usize = 80;
    var height: usize = 40;
    var ws: std.posix.winsize = undefined;
    const TIOCGWINSZ: usize = 0x5413;
    if (std.posix.system.ioctl(stdout_fd, TIOCGWINSZ, @intFromPtr(&ws)) >= 0) {
        width = ws.col;
        height = ws.row;
    }

    var canvas = try visualizer.Canvas.init(allocator, width, height);
    defer canvas.deinit();

    const vertices = [_]h.Vector{
        E3.e(1).add(E3.e(2)).add(E3.e(3)).scale(4.0),
        E3.e(1).add(E3.e(2)).sub(E3.e(3)).scale(4.0),
        E3.e(1).sub(E3.e(2)).add(E3.e(3)).scale(4.0),
        E3.e(1).sub(E3.e(2)).sub(E3.e(3)).scale(4.0),
        E3.e(1).negate().add(E3.e(2)).add(E3.e(3)).scale(4.0),
        E3.e(1).negate().add(E3.e(2)).sub(E3.e(3)).scale(4.0),
        E3.e(1).negate().sub(E3.e(2)).add(E3.e(3)).scale(4.0),
        E3.e(1).negate().sub(E3.e(2)).sub(E3.e(3)).scale(4.0),
    };

    const edges = [_][2]usize{
        .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
        .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 },
        .{ 2, 6 }, .{ 3, 7 }, .{ 4, 5 },
        .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
    };

    var hyperbolic_vertices: [10]h.Vector = undefined;
    const prism_radius: f32 = 5.2;
    const prism_half_depth: f32 = 3.6;
    var prism_i: usize = 0;
    while (prism_i < 5) : (prism_i += 1) {
        const theta = (2.0 * std.math.pi * @as(f32, @floatFromInt(prism_i)) / 5.0) + (std.math.pi / 10.0);
        const ring = E3.e(1).scale(@cos(theta) * prism_radius).add(E3.e(2).scale(@sin(theta) * prism_radius));
        hyperbolic_vertices[prism_i] = ring.add(E3.e(3).scale(prism_half_depth));
        hyperbolic_vertices[prism_i + 5] = ring.sub(E3.e(3).scale(prism_half_depth));
    }

    const hyperbolic_edges = [_][2]usize{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 },
        .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 9 }, .{ 9, 5 },
        .{ 0, 5 }, .{ 1, 6 }, .{ 2, 7 }, .{ 3, 8 }, .{ 4, 9 },
    };

    var angle: f32 = 0;
    var animate = true;
    var mode: DemoMode = .perspective;
    var camera = CameraState{};
    var escape_state: EscapeState = .idle;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();
    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\x1B[?25l\x1B[2J");
    defer {
        stdout.writeAll("\x1B[?25h") catch {};
        stdout.flush() catch {};
    }

    while (true) {
        if (animate) {
            angle += 0.05;
        }
        canvas.clear();

        var input_buf: [16]u8 = undefined;
        if (std.posix.read(stdin_fd, &input_buf)) |bytes_read| {
            if (bytes_read > 0) {
                var should_quit = false;
                for (input_buf[0..bytes_read]) |byte| {
                    if (handleInputByte(byte, &escape_state, &mode, &animate, &camera)) {
                        should_quit = true;
                        break;
                    }
                }
                if (should_quit) break;
            }
        } else |_| {}

        const rotor = sceneRotor(angle, mode);
        const zoom = modeZoom(angle, mode);
        const projection_mode = projectionMode(mode);

        const active_vertices: []const h.Vector = if (mode == .hyperbolic) hyperbolic_vertices[0..] else vertices[0..];
        const active_edges: []const [2]usize = if (mode == .hyperbolic) hyperbolic_edges[0..] else edges[0..];

        for (active_edges) |edge| {
            const v0 = active_vertices[edge[0]];
            const v1 = active_vertices[edge[1]];

            const rv0 = zmath.ga.rotors.rotated(v0, rotor);
            const rv1 = zmath.ga.rotors.rotated(v1, rotor);

            const steps = 50;
            var prev_p: ?[2]f32 = null;
            for (0..steps + 1) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
                const vt = rv0.scale(1.0 - t).add(rv1.scale(t));
                const projected_vt = viewSpace(vt, angle, mode, camera);
                const pt = visualizer.projectSimple(projected_vt, width, height, zoom, projection_mode);

                if (pt) |p| {
                    if (prev_p) |pp| {
                        canvas.drawLine(pp[0], pp[1], p[0], p[1], '#');
                    }
                    prev_p = p;
                } else {
                    prev_p = null;
                }
            }
        }

        try stdout.writeAll("\x1B[H");
        try stdout.print(
            "Mode: {s} | Zoom: {d:.2} | Anim:{s} | Space:Mode P:Pause | Arrows:Rotate WASD:Move | Q:Quit\n",
            .{ projectionModeLabel(mode), zoom, if (animate) "on" else "off" },
        );
        try canvas.writeRowsToWriter(stdout, canvas.height - 1);
        try stdout.flush();

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
    }
}

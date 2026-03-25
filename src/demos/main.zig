const std = @import("std");
const zmath = @import("zmath");
const visualizer = zmath.visualizer;
const curved = @import("curved_geometry.zig");

const Euclid3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Euclid3.Instantiate(f32);
const E3 = h.Basis;

const DemoMode = enum { perspective, isometric, hyperbolic, spherical };
const EscapeState = enum { idle, esc, csi };

const near_clip_z: f32 = 1.2;
const far_clip_z: f32 = 44.0;
const euclidean_cube_scale: f32 = 4.0;
const spherical_chart_scale: f32 = 0.52;
const hyperbolic_prism_radius: f32 = 0.22;
const hyperbolic_prism_half_depth: f32 = 0.14;
const hyperbolic_params = curved.Params{ .radius = hyperbolicRadiusForRightPentagon(hyperbolic_prism_radius), .angular_zoom = 0.72 };
const spherical_params = curved.Params{ .radius = 1.48, .angular_zoom = 0.42 };
const hyperbolic_near_distance: f32 = 0.08;
const hyperbolic_far_distance: f32 = 1.55;
const spherical_near_distance: f32 = 0.08;
const spherical_far_distance: f32 = 1.90;

// For a regular hyperbolic n-gon, the circumradius `rho` satisfies
// `cosh(rho / R) = cot(pi / n) * cot(alpha / 2)`.
// Our pentagon lives on a Klein-model ring of Euclidean radius `r = tanh(rho / R)`,
// so for the chosen chart radius we solve `R = chart_radius / tanh(rho / R)`.
fn hyperbolicRadiusForRightPentagon(chart_radius: f32) f32 {
    const half_interior: f32 = @as(f32, std.math.pi) / 4.0;
    const central_angle: f32 = @as(f32, std.math.pi) / 5.0;
    const cot_central = @cos(central_angle) / @sin(central_angle);
    const cot_half_interior = @cos(half_interior) / @sin(half_interior);
    const normalized_circumradius = std.math.acosh(cot_central * cot_half_interior);
    const klein_radius = std.math.tanh(normalized_circumradius);
    return chart_radius / klein_radius;
}

const CameraState = struct {
    euclid_rotation: f32 = 0.0,
    euclid_pitch: f32 = 0.18,
    euclid_eye_x: f32 = 0.0,
    euclid_eye_y: f32 = 0.0,
    euclid_eye_z: f32 = -10.5,
    hyper: curved.Camera,
    spherical: curved.Camera,

    fn init() CameraState {
        return .{
            .hyper = curved.initCamera(
                .hyperbolic,
                hyperbolic_params,
                .{ 0.0, 0.0, -hyperbolic_params.radius * 0.78 },
                .{ 0.0, 0.0, 0.0 },
            ),
            .spherical = curved.initCamera(.elliptic, spherical_params, .{ 0.0, 0.0, -0.82 }, .{ 0.0, 0.0, 0.0 }),
        };
    }

    fn euclidEyeVector(self: CameraState) h.Vector {
        return h.Vector.init(.{ self.euclid_eye_x, self.euclid_eye_y, self.euclid_eye_z });
    }
};

fn gaCross(a: h.Vector, b: h.Vector) h.Vector {
    return a.wedge(b).dual().negate();
}

fn safeNormalize(v: h.Vector, fallback: h.Vector) h.Vector {
    return h.normalize(v) catch fallback;
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

fn cameraSpace(v: h.Vector, camera: CameraState) h.Vector {
    return orientedCameraSpace(v, camera.euclidEyeVector(), camera.euclid_rotation, camera.euclid_pitch);
}

fn vec3FromVector(v: h.Vector) curved.Vec3 {
    return .{
        v.coeffNamed("e1"),
        v.coeffNamed("e2"),
        v.coeffNamed("e3"),
    };
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
                .scale(angle * 0.22)
                .add(E3.signedBlade("e23").scale(-0.38 + 0.12 * @sin(angle * 0.17))),
        ),
        .spherical => rotorFromGenerator(
            E3.signedBlade("e12")
                .scale(angle * 0.20)
                .add(E3.signedBlade("e23").scale(0.26 * @sin(angle * 0.21))),
        ),
    };
}

fn modeZoom(angle: f32, mode: DemoMode) f32 {
    return switch (mode) {
        .perspective => 5.75 + 0.20 * @sin(angle * 0.10),
        .isometric => 0.82 + 0.04 * @sin(angle * 0.12),
        .hyperbolic => hyperbolic_params.angular_zoom + 0.02 * @sin(angle * 0.11),
        .spherical => spherical_params.angular_zoom + 0.01 * @sin(angle * 0.09),
    };
}

fn projectionModeLabel(mode: DemoMode) []const u8 {
    return switch (mode) {
        .perspective => "perspective (point)",
        .isometric => "isometric (plane)",
        .hyperbolic => "hyperbolic",
        .spherical => "spherical (elliptic)",
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

const DepthClipResult = struct {
    points: [2]h.Vector,
    start_marker: visualizer.MarkerColor = .none,
    end_marker: visualizer.MarkerColor = .none,
};

fn clipSegmentToDepthRange(v0: h.Vector, v1: h.Vector, near_z: f32, far_z: f32) ?DepthClipResult {
    var result = DepthClipResult{ .points = .{ v0, v1 } };

    var z0 = result.points[0].coeffNamed("e3");
    var z1 = result.points[1].coeffNamed("e3");
    const near_in0 = z0 >= near_z;
    const near_in1 = z1 >= near_z;
    if (!near_in0 and !near_in1) return null;
    if (near_in0 != near_in1) {
        const denom = z1 - z0;
        if (@abs(denom) <= 1e-6) return null;
        const t = (near_z - z0) / denom;
        const clipped = result.points[0].scale(1.0 - t).add(result.points[1].scale(t));
        if (!near_in0) {
            result.points[0] = clipped;
            result.start_marker = .near;
        } else {
            result.points[1] = clipped;
            result.end_marker = .near;
        }
    }

    z0 = result.points[0].coeffNamed("e3");
    z1 = result.points[1].coeffNamed("e3");
    const far_in0 = z0 <= far_z;
    const far_in1 = z1 <= far_z;
    if (!far_in0 and !far_in1) return null;
    if (far_in0 != far_in1) {
        const denom = z1 - z0;
        if (@abs(denom) <= 1e-6) return null;
        const t = (far_z - z0) / denom;
        const clipped = result.points[0].scale(1.0 - t).add(result.points[1].scale(t));
        if (!far_in0) {
            result.points[0] = clipped;
            result.start_marker = .far;
        } else {
            result.points[1] = clipped;
            result.end_marker = .far;
        }
    }

    return result;
}

const CurvedSampleStatus = enum { hidden, visible, clipped_near, clipped_far };

fn curvedSampleStatus(distance: f32, near_distance: f32, far_distance: f32, projected: ?[2]f32) CurvedSampleStatus {
    if (projected == null) return .hidden;
    if (distance < near_distance) return .clipped_near;
    if (distance > far_distance) return .clipped_far;
    return .visible;
}

fn adjustCameraArrow(camera: *CameraState, arrow: u8) void {
    const pitch_step: f32 = 0.10;
    const rotation_step: f32 = 0.14;

    switch (arrow) {
        'A' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch + pitch_step, -1.10, 1.10);
            curved.pitch(&camera.hyper, .hyperbolic, pitch_step);
            curved.pitch(&camera.spherical, .elliptic, pitch_step);
        },
        'B' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch - pitch_step, -1.10, 1.10);
            curved.pitch(&camera.hyper, .hyperbolic, -pitch_step);
            curved.pitch(&camera.spherical, .elliptic, -pitch_step);
        },
        'C' => {
            camera.euclid_rotation += rotation_step;
            curved.yaw(&camera.hyper, .hyperbolic, rotation_step);
            curved.yaw(&camera.spherical, .elliptic, rotation_step);
        },
        'D' => {
            camera.euclid_rotation -= rotation_step;
            curved.yaw(&camera.hyper, .hyperbolic, -rotation_step);
            curved.yaw(&camera.spherical, .elliptic, -rotation_step);
        },
        else => {},
    }
}

fn adjustCameraTranslation(camera: *CameraState, key: u8) void {
    const euclid_step: f32 = 0.90;
    const hyper_step: f32 = 0.08;
    const spherical_step: f32 = 0.10;

    const sin_rotation = @sin(camera.euclid_rotation);
    const cos_rotation = @cos(camera.euclid_rotation);
    const forward_x = sin_rotation;
    const forward_z = cos_rotation;
    const right_x = cos_rotation;
    const right_z = -sin_rotation;

    switch (key) {
        'a' => {
            camera.euclid_eye_x -= right_x * euclid_step;
            camera.euclid_eye_z -= right_z * euclid_step;
            curved.moveRight(&camera.hyper, .hyperbolic, hyperbolic_params, -hyper_step);
            curved.moveRight(&camera.spherical, .elliptic, spherical_params, -spherical_step);
        },
        'd' => {
            camera.euclid_eye_x += right_x * euclid_step;
            camera.euclid_eye_z += right_z * euclid_step;
            curved.moveRight(&camera.hyper, .hyperbolic, hyperbolic_params, hyper_step);
            curved.moveRight(&camera.spherical, .elliptic, spherical_params, spherical_step);
        },
        's' => {
            camera.euclid_eye_x -= forward_x * euclid_step;
            camera.euclid_eye_z -= forward_z * euclid_step;
            curved.moveForward(&camera.hyper, .hyperbolic, hyperbolic_params, -hyper_step);
            curved.moveForward(&camera.spherical, .elliptic, spherical_params, -spherical_step);
        },
        'w' => {
            camera.euclid_eye_x += forward_x * euclid_step;
            camera.euclid_eye_z += forward_z * euclid_step;
            curved.moveForward(&camera.hyper, .hyperbolic, hyperbolic_params, hyper_step);
            curved.moveForward(&camera.spherical, .elliptic, spherical_params, spherical_step);
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

    const cube_vertices = [_]h.Vector{
        E3.e(1).add(E3.e(2)).add(E3.e(3)),
        E3.e(1).add(E3.e(2)).sub(E3.e(3)),
        E3.e(1).sub(E3.e(2)).add(E3.e(3)),
        E3.e(1).sub(E3.e(2)).sub(E3.e(3)),
        E3.e(1).negate().add(E3.e(2)).add(E3.e(3)),
        E3.e(1).negate().add(E3.e(2)).sub(E3.e(3)),
        E3.e(1).negate().sub(E3.e(2)).add(E3.e(3)),
        E3.e(1).negate().sub(E3.e(2)).sub(E3.e(3)),
    };

    const cube_edges = [_][2]usize{
        .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
        .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 },
        .{ 2, 6 }, .{ 3, 7 }, .{ 4, 5 },
        .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
    };

    var hyperbolic_vertices: [10]h.Vector = undefined;
    var prism_i: usize = 0;
    while (prism_i < 5) : (prism_i += 1) {
        const theta = (2.0 * std.math.pi * @as(f32, @floatFromInt(prism_i)) / 5.0) + (std.math.pi / 10.0);
        const ring = E3.e(1).scale(@cos(theta) * hyperbolic_prism_radius).add(E3.e(2).scale(@sin(theta) * hyperbolic_prism_radius));
        hyperbolic_vertices[prism_i] = ring.add(E3.e(3).scale(hyperbolic_prism_half_depth));
        hyperbolic_vertices[prism_i + 5] = ring.sub(E3.e(3).scale(hyperbolic_prism_half_depth));
    }

    const hyperbolic_edges = [_][2]usize{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 },
        .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 9 }, .{ 9, 5 },
        .{ 0, 5 }, .{ 1, 6 }, .{ 2, 7 }, .{ 3, 8 }, .{ 4, 9 },
    };

    var angle: f32 = 0.0;
    var animate = true;
    var mode: DemoMode = .perspective;
    var camera = CameraState.init();
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
        if (animate) angle += 0.05;
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

        switch (mode) {
            .perspective, .isometric => {
                const projection_mode: visualizer.ProjectionMode = if (mode == .perspective) .perspective else .isometric;
                for (cube_edges) |edge| {
                    const rv0 = zmath.ga.rotors.rotated(cube_vertices[edge[0]].scale(euclidean_cube_scale), rotor);
                    const rv1 = zmath.ga.rotors.rotated(cube_vertices[edge[1]].scale(euclidean_cube_scale), rotor);
                    const view_v0 = cameraSpace(rv0, camera);
                    const view_v1 = cameraSpace(rv1, camera);
                    const clipped = clipSegmentToDepthRange(view_v0, view_v1, near_clip_z, far_clip_z) orelse continue;

                    var prev_p: ?[2]f32 = null;
                    for (0..51) |i| {
                        const t = @as(f32, @floatFromInt(i)) / 50.0;
                        const vt = clipped.points[0].scale(1.0 - t).add(clipped.points[1].scale(t));
                        const pt = visualizer.projectSimple(vt, width, height, zoom, projection_mode);
                        if (pt) |p| {
                            if (prev_p) |pp| canvas.drawLine(pp[0], pp[1], p[0], p[1], '#');
                            prev_p = p;
                        } else {
                            prev_p = null;
                        }
                    }

                    if (clipped.start_marker != .none) {
                        if (visualizer.projectSimple(clipped.points[0], width, height, zoom, projection_mode)) |p| {
                            canvas.setMarker(p[0], p[1], clipped.start_marker);
                        }
                    }
                    if (clipped.end_marker != .none) {
                        if (visualizer.projectSimple(clipped.points[1], width, height, zoom, projection_mode)) |p| {
                            canvas.setMarker(p[0], p[1], clipped.end_marker);
                        }
                    }
                }
            },
            .hyperbolic => {
                for (hyperbolic_edges) |edge| {
                    const rv0 = zmath.ga.rotors.rotated(hyperbolic_vertices[edge[0]], rotor);
                    const rv1 = zmath.ga.rotors.rotated(hyperbolic_vertices[edge[1]], rotor);

                    var prev_p: ?[2]f32 = null;
                    var prev_status: CurvedSampleStatus = .hidden;
                    for (0..65) |i| {
                        const t = @as(f32, @floatFromInt(i)) / 64.0;
                        const vt = rv0.scale(1.0 - t).add(rv1.scale(t));
                        const sample = curved.samplePoint(.hyperbolic, hyperbolic_params, camera.hyper, vec3FromVector(vt)) orelse {
                            prev_p = null;
                            prev_status = .hidden;
                            continue;
                        };
                        const projected = curved.projectSample(sample, width, height, zoom);
                        const status = curvedSampleStatus(sample.distance, hyperbolic_near_distance, hyperbolic_far_distance, projected);

                        if (projected) |p| {
                            if (prev_status == .visible and status == .visible) {
                                if (prev_p) |pp| canvas.drawLine(pp[0], pp[1], p[0], p[1], '#');
                            } else if (prev_status == .visible and status == .clipped_near) {
                                if (prev_p) |pp| canvas.setMarker(pp[0], pp[1], .near);
                            } else if (prev_status == .visible and status == .clipped_far) {
                                if (prev_p) |pp| canvas.setMarker(pp[0], pp[1], .far);
                            } else if (prev_status == .clipped_near and status == .visible) {
                                canvas.setMarker(p[0], p[1], .near);
                            } else if (prev_status == .clipped_far and status == .visible) {
                                canvas.setMarker(p[0], p[1], .far);
                            }
                            prev_p = if (status == .visible) p else null;
                        } else {
                            prev_p = null;
                        }
                        prev_status = status;
                    }
                }
            },
            .spherical => {
                for (cube_edges) |edge| {
                    const rv0 = zmath.ga.rotors.rotated(cube_vertices[edge[0]].scale(spherical_chart_scale), rotor);
                    const rv1 = zmath.ga.rotors.rotated(cube_vertices[edge[1]].scale(spherical_chart_scale), rotor);

                    var prev_p: ?[2]f32 = null;
                    var prev_status: CurvedSampleStatus = .hidden;
                    for (0..65) |i| {
                        const t = @as(f32, @floatFromInt(i)) / 64.0;
                        const vt = rv0.scale(1.0 - t).add(rv1.scale(t));
                        const sample = curved.samplePoint(.elliptic, spherical_params, camera.spherical, vec3FromVector(vt)) orelse {
                            prev_p = null;
                            prev_status = .hidden;
                            continue;
                        };
                        const projected = curved.projectSample(sample, width, height, zoom);
                        const status = curvedSampleStatus(sample.distance, spherical_near_distance, spherical_far_distance, projected);

                        if (projected) |p| {
                            if (prev_status == .visible and status == .visible) {
                                if (prev_p) |pp| canvas.drawLine(pp[0], pp[1], p[0], p[1], '#');
                            } else if (prev_status == .visible and status == .clipped_near) {
                                if (prev_p) |pp| canvas.setMarker(pp[0], pp[1], .near);
                            } else if (prev_status == .visible and status == .clipped_far) {
                                if (prev_p) |pp| canvas.setMarker(pp[0], pp[1], .far);
                            } else if (prev_status == .clipped_near and status == .visible) {
                                canvas.setMarker(p[0], p[1], .near);
                            } else if (prev_status == .clipped_far and status == .visible) {
                                canvas.setMarker(p[0], p[1], .far);
                            }
                            prev_p = if (status == .visible) p else null;
                        } else {
                            prev_p = null;
                        }
                        prev_status = status;
                    }
                }
            },
        }

        try stdout.writeAll("\x1B[H");
        try stdout.print(
            "{s} Z:{d:.2} E:{d:.1}/{d:.1} S:{d:.2} C:{d:.2}/{d:.2} RGclip A:{s} SPC/P/WASD/Arrows/Q\n",
            .{ projectionModeLabel(mode), zoom, near_clip_z, far_clip_z, spherical_chart_scale, hyperbolic_params.radius, spherical_params.radius, if (animate) "on" else "off" },
        );
        try canvas.writeRowsToWriter(stdout, canvas.height - 1);
        try stdout.flush();

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
    }
}

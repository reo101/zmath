const std = @import("std");
const zmath = @import("zmath");
const visualizer = @import("zmath").visualizer;

const Cl3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Cl3.Instantiate(f32);
const E3 = h.Basis;

fn gaCross(a: h.Vector, b: h.Vector) h.Vector {
    // In Euclidean 3D, cross(a, b) corresponds to -dual(a wedge b).
    return a.wedge(b).dual().negate();
}

fn safeNormalize(v: h.Vector, fallback: h.Vector) h.Vector {
    return h.normalize(v) catch fallback;
}

fn sphericalCameraSpace(v: h.Vector, angle: f32) h.Vector {
    const yaw = 0.55 * @sin(angle * 0.05);
    const pitch = 0.18 + 0.06 * @sin(angle * 0.07);
    const distance = 2.0 + 3.0 * @sin(angle * 0.11);

    const camera = E3.e(1)
        .scale(@cos(yaw) * @cos(pitch) * distance)
        .add(E3.e(2).scale(@sin(pitch) * distance * 0.8))
        .add(E3.e(3).scale(@sin(yaw) * @cos(pitch) * distance));

    const forward = safeNormalize(camera.negate(), h.Vector.zero());
    const world_up = h.Vector.init(.{ 0, 1, 0 });

    var right = gaCross(world_up, forward);
    if (right.scalarProduct(right) <= 1e-6) right = h.Vector.init(.{ 1, 0, 0 });
    right = safeNormalize(right, h.Vector.init(.{ 1, 0, 0 }));
    const up = safeNormalize(gaCross(forward, right), h.Vector.zero());

    const rel = v.sub(camera);
    return E3.e(1)
        .scale(rel.scalarProduct(right))
        .add(E3.e(2).scale(rel.scalarProduct(up)))
        .add(E3.e(3).scale(rel.scalarProduct(forward)));
}

fn projectionModeLabel(mode: visualizer.ProjectionMode) []const u8 {
    return switch (mode) {
        .perspective => "perspective (point)",
        .isometric => "isometric (plane)",
        .hyperbolic => "hyperbolic",
        .spherical => "spherical",
    };
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
    var mode: visualizer.ProjectionMode = .perspective;

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
        angle += 0.05;
        canvas.clear();

        var buf: [1]u8 = undefined;
        if (std.posix.read(stdin_fd, &buf)) |bytes_read| {
            if (bytes_read > 0) {
                if (buf[0] == ' ') {
                    mode = switch (mode) {
                        .perspective => .isometric,
                        .isometric => .hyperbolic,
                        .hyperbolic => .spherical,
                        .spherical => .perspective,
                    };
                } else if (buf[0] == 'q') break;
            }
        } else |_| {}

        const b12 = E3.signedBlade("e12").scale(@cos(angle * 0.3));
        const b23 = E3.signedBlade("e23").scale(@sin(angle * 0.5));
        const b13 = E3.signedBlade("e13").scale(@cos(angle * 0.7));
        const B = b12.add(b23).add(b13);

        var rotor = h.Rotor.init(.{ 1, 0, 0, 0 });
        if (mode != .spherical and B.magnitude() > 1e-6) {
            const exp_rotor = B.scale(-0.5).exp();
            var typed_rotor = h.Rotor.zero();
            inline for (h.Rotor.blades, 0..) |mask, i| {
                typed_rotor.coeffs[i] = exp_rotor.coeff(mask);
            }
            rotor = zmath.ga.rotors.normalizedRotor(typed_rotor);
        }

        const raw_zoom: f32 = 9.2 + 0.8 * @sin(angle * 0.1);
        const zoom = switch (mode) {
            .spherical => 10.5 + 1.0 * @sin(angle * 0.09),
            .isometric => @min(raw_zoom * 0.82, 12.0),
            .perspective => @min(raw_zoom * 0.70, 12.0),
            .hyperbolic => @min(raw_zoom * 0.80, 12.0),
        };
        const projection_mode = mode;

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
                const projected_vt = if (mode == .spherical) sphericalCameraSpace(vt, angle) else vt;
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
        try stdout.print("Mode: {s} (Space: Toggle, Q: Quit) | Zoom: {d:.2}\n", .{ projectionModeLabel(mode), zoom });
        try canvas.writeRowsToWriter(stdout, canvas.height - 1);
        try stdout.flush();

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
    }
}

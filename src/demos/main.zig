const std = @import("std");
const zmath = @import("zmath");
const visualizer = @import("zmath").visualizer;

const Cl3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Cl3.Instantiate(f32);

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout_fd = std.posix.STDOUT_FILENO;

    // Get terminal size
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
    
    const E3 = h.Basis;
    const e1 = E3.e(1);
    const e2 = E3.e(2);
    const e3 = E3.e(3);

    // Cube vertices
    const vertices = [_]h.Vector{
        e1.add(e2).add(e3),
        e1.add(e2).sub(e3),
        e1.sub(e2).add(e3),
        e1.sub(e2).sub(e3),
        e1.negate().add(e2).add(e3),
        e1.negate().add(e2).sub(e3),
        e1.negate().sub(e2).add(e3),
        e1.negate().sub(e2).sub(e3),
    };

    const edges = [_][2]usize{
        .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
        .{ 1, 3 }, .{ 1, 5 },
        .{ 2, 3 }, .{ 2, 6 },
        .{ 3, 7 },
        .{ 4, 5 }, .{ 4, 6 },
        .{ 5, 7 },
        .{ 6, 7 },
    };

    const pga = zmath.pga;
    const PgaMv = pga.h.Full;

    const eye_point = pga.Point.init(0, 0, 20);
    const eye_plane = pga.Plane.init(0, 0, 1, 20); // Plane at z=20
    
    var current_eye = eye_point;
    var is_perspective = true;

    // Screen at z=0, origin at (0,0,0)
    const screen = pga.Plane.init(0, 0, 1, 0);
    const E_pga = pga.h.Basis;
    const pga_camera_base = .{
        .screen = screen,
        .origin = pga.Point.init(0, 0, 0),
        .right = E_pga.e(0).wedge(E_pga.e(2)).wedge(E_pga.e(3)).cast(PgaMv), // Point e023
        .up = E_pga.e(0).wedge(E_pga.e(3)).wedge(E_pga.e(1)).cast(PgaMv),    // Point e031
    };

    var angle: f32 = 0;
    var frame: usize = 0;

    // IO for timing
    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    // Hide cursor and clear screen
    std.debug.print("\x1B[?25l\x1B[2J", .{});
    defer std.debug.print("\x1B[?25h", .{});

    while (frame < 200) : (frame += 1) {
        angle += 0.05;
        canvas.clear();

        // Toggle projection every 50 frames
        if (frame % 50 == 0 and frame > 0) {
            is_perspective = !is_perspective;
            current_eye = if (is_perspective) eye_point else eye_plane;
        }

        const b12 = E3.signedBlade("e12").scale(@cos(angle * 0.3));
        const b23 = E3.signedBlade("e23").scale(@sin(angle * 0.5));
        const b13 = E3.signedBlade("e13").scale(@cos(angle * 0.7));
        const B = b12.add(b23).add(b13);
        const B_mag = B.magnitude();
        
        var rotor = h.Full.init(.{ 1, 0, 0, 0, 0, 0, 0, 0 });
        if (B_mag > 1e-6) {
            const exp_rotor = B.scale(-1.0 / 2.0).exp();
            var full_rotor = h.Full.zero();
            inline for (h.Full.blades, 0..) |mask, i| {
                full_rotor.coeffs[i] = exp_rotor.coeff(mask);
            }
            rotor = full_rotor;
        }

        // Constant zoom effect
        const zoom = 1.0 + 0.5 * @sin(angle * 0.2);
        const scale_factor = (1.0 + 0.3 * @sin(angle * 0.5)) * zoom;

        const camera_to_use = .{
            .eye = current_eye,
            .screen = pga_camera_base.screen,
            .origin = pga_camera_base.origin,
            .right = pga_camera_base.right,
            .up = pga_camera_base.up,
        };

        for (edges) |edge| {
            const v0 = vertices[edge[0]];
            const v1 = vertices[edge[1]];

            const rv0 = rotor.gp(v0).gp(rotor.reverse()).gradePart(1).scale(scale_factor);
            const rv1 = rotor.gp(v1).gp(rotor.reverse()).gradePart(1).scale(scale_factor);

            // Convert Euclidean vector to PGA point
            const p0_pga = pga.Point.init(rv0.coeffNamed("e1"), rv0.coeffNamed("e2"), rv0.coeffNamed("e3"));
            const p1_pga = pga.Point.init(rv1.coeffNamed("e1"), rv1.coeffNamed("e2"), rv1.coeffNamed("e3"));

            const p0 = visualizer.projectPGA(camera_to_use, p0_pga, width, height);
            const p1 = visualizer.projectPGA(camera_to_use, p1_pga, width, height);

            if (p0 != null and p1 != null) {
                canvas.drawLine(p0.?[0], p0.?[1], p1.?[0], p1.?[1], '#');
            }
        }

        std.debug.print("\x1B[H", .{}); // Reset cursor to top
        std.debug.print("Frame: {}, Mode: {s}, Zoom: {d:.2}\n", .{ frame, if (is_perspective) "Perspective" else "Isometric", zoom });
        var y: usize = 0;
        while (y < canvas.height - 1) : (y += 1) {
            std.debug.print("{s}\n", .{canvas.pixels[y * canvas.width .. (y + 1) * canvas.width]});
        }
        
        const duration = std.Io.Duration.fromMilliseconds(30);
        std.Io.sleep(io, duration, .awake) catch {};
    }
}

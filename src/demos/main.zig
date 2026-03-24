const std = @import("std");
const zmath = @import("zmath");
const visualizer = @import("zmath").visualizer;

const Cl3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Cl3.Instantiate(f32);

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
    
    const E3 = h.Basis;
    const vertices = [_]h.Vector{
        E3.e(1).add(E3.e(2)).add(E3.e(3)),
        E3.e(1).add(E3.e(2)).sub(E3.e(3)),
        E3.e(1).sub(E3.e(2)).add(E3.e(3)),
        E3.e(1).sub(E3.e(2)).sub(E3.e(3)),
        E3.e(1).negate().add(E3.e(2)).add(E3.e(3)),
        E3.e(1).negate().add(E3.e(2)).sub(E3.e(3)),
        E3.e(1).negate().sub(E3.e(2)).add(E3.e(3)),
        E3.e(1).negate().sub(E3.e(2)).sub(E3.e(3)),
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

    var angle: f32 = 0;
    var mode: visualizer.ProjectionMode = .perspective;

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    std.debug.print("\x1B[?25l\x1B[2J", .{});

    while (true) {
        angle += 0.05;
        canvas.clear();

        var buf: [1]u8 = undefined;
        if (std.posix.read(stdin_fd, &buf)) |bytes_read| {
            if (bytes_read > 0) {
                if (buf[0] == ' ') {
                    mode = switch (mode) {
                        .isometric => .perspective,
                        .perspective => .curved,
                        .curved => .conformal,
                        .conformal => .isometric,
                    };
                }
 else if (buf[0] == 'q') break;
            }
        } else |_| {}

        const b12 = E3.signedBlade("e12").scale(@cos(angle * 0.3));
        const b23 = E3.signedBlade("e23").scale(@sin(angle * 0.5));
        const b13 = E3.signedBlade("e13").scale(@cos(angle * 0.7));
        const B = b12.add(b23).add(b13);
        
        var rotor = h.Full.init(.{ 1, 0, 0, 0, 0, 0, 0, 0 });
        if (B.magnitude() > 1e-6) {
            const exp_rotor = B.scale(-0.5).exp();
            var full_rotor = h.Full.zero();
            inline for (h.Full.blades, 0..) |mask, i| {
                full_rotor.coeffs[i] = exp_rotor.coeff(mask);
            }
            rotor = full_rotor;
        }

        const zoom = 5.0 + 3.0 * @sin(angle * 0.2);
        const scale_factor: f32 = 1.0; 

        for (edges) |edge| {
            const v0 = vertices[edge[0]];
            const v1 = vertices[edge[1]];

            const rv0 = rotor.gp(v0).gp(rotor.reverse()).gradePart(1).scale(scale_factor);
            const rv1 = rotor.gp(v1).gp(rotor.reverse()).gradePart(1).scale(scale_factor);

            const p0 = visualizer.projectSimple(rv0, width, height, zoom, mode);
            const p1 = visualizer.projectSimple(rv1, width, height, zoom, mode);

            if (p0 != null and p1 != null) {
                canvas.drawLine(p0.?[0], p0.?[1], p1.?[0], p1.?[1], '#');
            }
        }

        std.debug.print("\x1B[H", .{});
        std.debug.print("Mode: {s} (Space: Toggle, Q: Quit) | Zoom: {d:.2}\n", .{ @tagName(mode), zoom });
        var y: usize = 0;
        while (y < canvas.height - 1) : (y += 1) {
            std.debug.print("{s}\n", .{canvas.pixels[y * canvas.width .. (y + 1) * canvas.width]});
        }
        
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
    }
}

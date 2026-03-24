const std = @import("std");
const zmath = @import("../ga.zig");

/// A software canvas for rendering 2D wireframes.
pub const Canvas = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, ' ');
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
    }

    pub fn clear(self: *Canvas) void {
        @memset(self.pixels, ' ');
    }

    pub fn setPixel(self: *Canvas, x: isize, y: isize, char: u8) void {
        if (x < 0 or x >= self.width or y < 0 or y >= self.height) return;
        self.pixels[@intCast(y * @as(isize, @intCast(self.width)) + x)] = char;
    }

    pub fn drawLine(self: *Canvas, x0_f: f32, y0_f: f32, x1_f: f32, y1_f: f32, char: u8) void {
        var x0: isize = @intFromFloat(@round(x0_f));
        var y0: isize = @intFromFloat(@round(y0_f));
        const x1: isize = @intFromFloat(@round(x1_f));
        const y1: isize = @intFromFloat(@round(y1_f));

        const dx = @abs(x1 - x0);
        const dy = -@as(isize, @intCast(@abs(y1 - y0)));
        const sx: isize = if (x0 < x1) 1 else -1;
        const sy: isize = if (y0 < y1) 1 else -1;
        var err = @as(isize, @intCast(dx)) + dy;

        while (true) {
            self.setPixel(x0, y0, char);
            if (x0 == x1 and y0 == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= @as(isize, @intCast(dx))) {
                err += @as(isize, @intCast(dx));
                y0 += sy;
            }
        }
    }

    pub fn writeToWriter(self: Canvas, writer: anytype) !void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            try writer.writeAll(self.pixels[y * self.width .. (y + 1) * self.width]);
            try writer.writeByte('\n');
        }
    }
};

pub const ProjectionMode = enum { perspective, isometric, hyperbolic, spherical };

/// Simple 3D-to-2D projection for the demo.
pub fn projectSimple(p: anytype, canvas_width: usize, canvas_height: usize, zoom: f32, mode: ProjectionMode) ?[2]f32 {
    zmath.ensureMultivector(@TypeOf(p));

    var x_raw = p.coeffNamed("e1");
    var y_raw = p.coeffNamed("e2");
    var z_raw = p.coeffNamed("e3");

    switch (mode) {
        .perspective, .isometric => {},
        .hyperbolic => {
            // Poincare-ball-like compression into a bounded domain.
            const r2 = x_raw * x_raw + y_raw * y_raw + z_raw * z_raw;
            const w = @sqrt(1.0 + r2);
            const factor = 1.0 / (1.0 + w);
            x_raw *= factor;
            y_raw *= factor;
            z_raw *= factor;
        },
        .spherical => {
            // Stereographic projection from the "south" pole after normalization.
            // This intentionally creates a strong singularity near the opposite pole.
            const radius = @sqrt(x_raw * x_raw + y_raw * y_raw + z_raw * z_raw);
            if (radius <= 1e-6) return null;

            const nx = x_raw / radius;
            const ny = y_raw / radius;
            const nz = z_raw / radius;

            const pole_softening: f32 = 0.02;
            const denom = 1.0 + ny + pole_softening;
            x_raw = nx / denom;
            y_raw = nz / denom;
            z_raw = ny;
        },
    }

    const z_offset: f32 = switch (mode) {
        // Pull perspective-style modes farther back so depth motion causes
        // less aggressive zoom-in as geometry approaches the camera.
        .perspective, .hyperbolic => 30.0,
        .isometric => 6.0,
        .spherical => 5.0,
    };
    const dist = z_raw + z_offset;

    // Near plane clipping
    if ((mode == .perspective or mode == .hyperbolic or mode == .spherical) and dist <= 0.1) return null;

    // Normalize scale across modes. Spherical gets an extra shrink factor so
    // the heavily distorted opposite pole stays in frame more often.
    const base_scale = if (mode == .perspective or mode == .hyperbolic or mode == .spherical) (zoom / dist) else (zoom / z_offset);
    const scale = if (mode == .spherical) base_scale * 0.10 else base_scale;

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));

    const x = (x_raw * scale / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_raw * scale) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);

    return .{ x, y };
}

/// Projects a point using PGA universal projection formula.
/// P' = (Eye v Point) ^ Screen
pub fn projectPGA(camera: anytype, p: anytype, canvas_width: usize, canvas_height: usize, zoom: f32) ?[2]f32 {
    zmath.ensureMultivector(@TypeOf(p));

    const ray = camera.eye.join(p);
    const p_prime_mv = ray.wedge(camera.screen);
    const p_prime = p_prime_mv.gradePart(3);

    const w = p_prime.coeffNamed("e123");
    if (@abs(w) < 1e-6) return null;

    const x_coord = p_prime.coeffNamed("e234") / w;
    const y_coord = p_prime.coeffNamed("e314") / w;

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));

    // Scale coordinates to fit roughly in [-1, 1] then map to pixels
    const x = (x_coord * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_coord * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);

    return .{ x, y };
}

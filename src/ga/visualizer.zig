const std = @import("std");
const zmath = @import("../ga.zig");
const cga = @import("../flavours/cga.zig");

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

pub const ProjectionMode = enum { isometric, perspective, curved, conformal };

/// Simple 3D-to-2D projection for the demo.
pub fn projectSimple(p: anytype, canvas_width: usize, canvas_height: usize, zoom: f32, mode: ProjectionMode) ?[2]f32 {
    zmath.ensureMultivector(@TypeOf(p));
    
    var x_raw = p.coeffNamed("e1");
    var y_raw = p.coeffNamed("e2");
    var z_raw = p.coeffNamed("e3");

    if (mode == .curved) {
        // Apply a spherical/fisheye distortion
        const r2 = x_raw * x_raw + y_raw * y_raw + z_raw * z_raw;
        const distortion = 1.0 + r2 * 0.05;
        x_raw /= distortion;
        y_raw /= distortion;
    } else if (mode == .conformal) {
        // Map to CGA and invert in a sphere
        const p_cga = cga.Point.init(x_raw, y_raw, z_raw);
        // Sphere of radius 10 at origin
        const S = cga.Sphere.init(0, 0, 0, 10.0);
        // Spherical inversion: P' = S P S^-1
        const inv_S = S.inverse() orelse S; // Should not be null for non-zero radius
        const p_prime_cga = S.gp(p_cga).gp(inv_S).gradePart(1);
        
        // Map back to Euclidean (x,y,z)
        // den = -(P . ninf)
        const den = -p_prime_cga.dot(cga.ninf).scalarCoeff();
        if (@abs(den) > 1e-6) {
            x_raw = p_prime_cga.dot(cga.h.Basis.e(1)).scalarCoeff() / den;
            y_raw = p_prime_cga.dot(cga.h.Basis.e(2)).scalarCoeff() / den;
            z_raw = p_prime_cga.dot(cga.h.Basis.e(3)).scalarCoeff() / den;
        }
    }

    // Move away from the screen
    const z_offset: f32 = 10.0;
    const dist = z_raw + z_offset;
    
    if ((mode == .perspective or mode == .curved or mode == .conformal) and dist <= 0.1) return null;

    const scale = if (mode == .perspective or mode == .curved or mode == .conformal) (zoom / dist) else (zoom / 5.0);
    
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

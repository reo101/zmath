const std = @import("std");
const zmath = @import("../ga.zig");

/// A software canvas for rendering 2D wireframes.
pub const Canvas = struct {
    const subpixel_x: usize = 2;
    const subpixel_y: usize = 4;
    const max_subpixel_intensity: u8 = 4;
    const dot_ramp = [_][]const u8{ " ", "⠁", "⠃", "⠇", "⠏" };

    width: usize,
    height: usize,
    subpixels: []u8,
    markers: []u8,
    allocator: std.mem.Allocator,

    fn subpixelWidth(self: Canvas) usize {
        return self.width * subpixel_x;
    }

    fn subpixelHeight(self: Canvas) usize {
        return self.height * subpixel_y;
    }

    fn setSubpixel(self: *Canvas, x: isize, y: isize, intensity: u8) void {
        const width_i: isize = @intCast(self.subpixelWidth());
        const height_i: isize = @intCast(self.subpixelHeight());
        if (x < 0 or x >= width_i or y < 0 or y >= height_i) return;

        const idx: usize = @intCast(y * width_i + x);
        const remaining = max_subpixel_intensity -| self.subpixels[idx];
        self.subpixels[idx] += @min(remaining, intensity);
    }

    fn glyphForCell(self: Canvas, cell_x: usize, cell_y: usize) []const u8 {
        const start_x = cell_x * subpixel_x;
        const start_y = cell_y * subpixel_y;
        const sub_w = self.subpixelWidth();
        var occupied: usize = 0;
        var sum_x: f32 = 0;
        var sum_y: f32 = 0;

        var sy: usize = 0;
        while (sy < subpixel_y) : (sy += 1) {
            var sx: usize = 0;
            while (sx < subpixel_x) : (sx += 1) {
                const sample = self.subpixels[(start_y + sy) * sub_w + (start_x + sx)];
                // Collapse overdraw into binary subpixel coverage for character selection.
                if (sample > 0) {
                    occupied += 1;
                    sum_x += @as(f32, @floatFromInt(sx)) * 2.0 - 1.0;
                    sum_y += @as(f32, @floatFromInt(sy)) * 2.0 - 3.0;
                }
            }
        }

        if (occupied == 0) return " ";
        if (occupied <= 2) return dot_ramp[occupied];

        const inv_count = 1.0 / @as(f32, @floatFromInt(occupied));
        const mean_x = sum_x * inv_count;
        const mean_y = sum_y * inv_count;

        var sxx: f32 = 0;
        var syy: f32 = 0;
        var sxy: f32 = 0;

        sy = 0;
        while (sy < subpixel_y) : (sy += 1) {
            var sx: usize = 0;
            while (sx < subpixel_x) : (sx += 1) {
                const sample = self.subpixels[(start_y + sy) * sub_w + (start_x + sx)];
                if (sample == 0) continue;

                const x = @as(f32, @floatFromInt(sx)) * 2.0 - 1.0;
                const y = @as(f32, @floatFromInt(sy)) * 2.0 - 3.0;
                const dx = x - mean_x;
                const dy = y - mean_y;
                sxx += dx * dx;
                syy += dy * dy;
                sxy += dx * dy;
            }
        }

        if (@abs(sxy) > (sxx + syy) * 0.25) {
            return if (sxy < 0) "╱" else "╲";
        }
        if (syy > sxx * 1.35) {
            return if (occupied >= 6) "┃" else "│";
        }
        if (sxx > syy * 1.35) {
            return if (occupied >= 6) "━" else "─";
        }
        if (occupied >= 6) return "┼";

        return dot_ramp[@min(occupied, dot_ramp.len - 1)];
    }

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        const subpixels = try allocator.alloc(u8, width * height * subpixel_x * subpixel_y);
        const markers = try allocator.alloc(u8, width * height);
        @memset(subpixels, 0);
        @memset(markers, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .subpixels = subpixels,
            .markers = markers,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.subpixels);
        self.allocator.free(self.markers);
    }

    pub fn clear(self: *Canvas) void {
        @memset(self.subpixels, 0);
        @memset(self.markers, 0);
    }

    pub fn setPixel(self: *Canvas, x: isize, y: isize, char: u8) void {
        _ = char;
        self.setSubpixel(x * subpixel_x + @as(isize, subpixel_x / 2), y * subpixel_y + @as(isize, subpixel_y / 2), 1);
    }

    pub fn drawLine(self: *Canvas, x0_f: f32, y0_f: f32, x1_f: f32, y1_f: f32, char: u8) void {
        _ = char;

        var x0: isize = @intFromFloat(@round(x0_f * subpixel_x));
        var y0: isize = @intFromFloat(@round(y0_f * subpixel_y));
        const x1: isize = @intFromFloat(@round(x1_f * subpixel_x));
        const y1: isize = @intFromFloat(@round(y1_f * subpixel_y));

        const dx = @abs(x1 - x0);
        const dy = -@as(isize, @intCast(@abs(y1 - y0)));
        const sx: isize = if (x0 < x1) 1 else -1;
        const sy: isize = if (y0 < y1) 1 else -1;
        var err = @as(isize, @intCast(dx)) + dy;

        while (true) {
            self.setSubpixel(x0, y0, 1);
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

    pub fn setMarker(self: *Canvas, x_f: f32, y_f: f32, color: MarkerColor) void {
        const x: isize = @intFromFloat(@round(x_f));
        const y: isize = @intFromFloat(@round(y_f));
        const width_i: isize = @intCast(self.width);
        const height_i: isize = @intCast(self.height);
        if (x < 0 or x >= width_i or y < 0 or y >= height_i) return;

        const idx: usize = @intCast(y * width_i + x);
        self.markers[idx] = @intFromEnum(color);
    }

    pub fn writeToWriter(self: Canvas, writer: anytype) !void {
        return self.writeRowsToWriter(writer, self.height);
    }

    pub fn writeRowsToWriter(self: Canvas, writer: anytype, rows: usize) !void {
        const output_rows = @min(rows, self.height);
        var y: usize = 0;
        while (y < output_rows) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const marker = @as(MarkerColor, @enumFromInt(self.markers[y * self.width + x]));
                switch (marker) {
                    .none => try writer.writeAll(self.glyphForCell(x, y)),
                    .near => try writer.writeAll("\x1B[31m●\x1B[0m"),
                    .far => try writer.writeAll("\x1B[32m●\x1B[0m"),
                }
            }
            if (y + 1 < output_rows) {
                try writer.writeByte('\n');
            }
        }
    }
};

pub const MarkerColor = enum(u8) {
    none = 0,
    near = 1,
    far = 2,
};

pub const ProjectionMode = enum { perspective, isometric, hyperbolic, spherical };
pub const hyperbolic_curvature: f32 = 1.75;

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
            x_raw *= hyperbolic_curvature;
            y_raw *= hyperbolic_curvature;
            z_raw *= hyperbolic_curvature;
            const r2 = x_raw * x_raw + y_raw * y_raw + z_raw * z_raw;
            const w = @sqrt(1.0 + r2);
            const factor = 1.0 / (1.0 + w);
            x_raw *= factor;
            y_raw *= factor;
            z_raw *= factor;
        },
        .spherical => {
            // Project onto the viewing sphere using angular coordinates.
            const radius = @sqrt(x_raw * x_raw + y_raw * y_raw + z_raw * z_raw);
            if (radius <= 1e-6) return null;

            const nx = x_raw / radius;
            const ny = y_raw / radius;
            const nz = z_raw / radius;
            const lateral = @sqrt(nx * nx + nz * nz);
            x_raw = std.math.atan2(nx, nz);
            y_raw = std.math.atan2(ny, @max(lateral, 1e-6));
            z_raw = 0.0;
        },
    }

    const z_offset: f32 = switch (mode) {
        // Pull perspective-style modes farther back so depth motion causes
        // less aggressive zoom-in as geometry approaches the camera.
        .perspective => 30.0,
        .hyperbolic => 8.8,
        .isometric => 6.0,
        .spherical => 1.0,
    };
    const dist = z_raw + z_offset;

    // Near plane clipping
    if ((mode == .perspective or mode == .hyperbolic or mode == .spherical) and dist <= 0.1) return null;

    // Normalize scale across modes. Spherical gets an extra shrink factor so
    // the heavily distorted opposite pole stays in frame more often.
    const base_scale = if (mode == .perspective or mode == .hyperbolic) (zoom / dist) else (zoom / z_offset);
    const scale = base_scale;

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));

    const x = (x_raw * scale / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_raw * scale) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);

    return .{ x, y };
}

pub fn projectDirection(x_dir: f32, y_dir: f32, z_dir: f32, canvas_width: usize, canvas_height: usize, zoom: f32) ?[2]f32 {
    if (z_dir <= 1e-4) return null;

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (x_dir * zoom / (z_dir * aspect) + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_dir * zoom / z_dir) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);

    return .{ x, y };
}

pub fn projectAngularDirection(
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,
    canvas_width: usize,
    canvas_height: usize,
    zoom: f32,
) ?[2]f32 {
    if (z_dir <= 1e-4) return null;

    const radius = @sqrt(x_dir * x_dir + y_dir * y_dir + z_dir * z_dir);
    if (radius <= 1e-6) return null;

    const nx = x_dir / radius;
    const ny = y_dir / radius;
    const nz = z_dir / radius;
    const lateral = @sqrt(nx * nx + nz * nz);

    const x_raw = std.math.atan2(nx, nz);
    const y_raw = std.math.atan2(ny, @max(lateral, 1e-6));

    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    const x = (x_raw * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_raw * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);

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

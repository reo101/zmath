const std = @import("std");

/// A software canvas for rendering 2D wireframes.
pub const Canvas = struct {
    const subpixel_x: usize = 2;
    const subpixel_y: usize = 4;
    const max_subpixel_intensity: u8 = 4;
    const dot_ramp = [_][]const u8{ " ", "⠁", "⠃", "⠇", "⠏" };
    const fill_ramp = [_][]const u8{ " ", "░", "▒", "▓", "█" };

    width: usize,
    height: usize,
    subpixels: []u8,
    tones: []u8,
    fill_shades: []u8,
    fill_tones: []u8,
    fill_depths: []f32,
    markers: []u8,
    allocator: std.mem.Allocator,

    fn subpixelWidth(self: Canvas) usize {
        return self.width * subpixel_x;
    }

    fn subpixelHeight(self: Canvas) usize {
        return self.height * subpixel_y;
    }

    fn setSubpixel(self: *Canvas, x: isize, y: isize, intensity: u8, tone: u8) void {
        const width_i: isize = @intCast(self.subpixelWidth());
        const height_i: isize = @intCast(self.subpixelHeight());
        if (x < 0 or x >= width_i or y < 0 or y >= height_i) return;

        const idx: usize = @intCast(y * width_i + x);
        const remaining = max_subpixel_intensity -| self.subpixels[idx];
        self.subpixels[idx] += @min(remaining, intensity);
        self.tones[idx] = @max(self.tones[idx], tone);
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

    fn toneForCell(self: Canvas, cell_x: usize, cell_y: usize) u8 {
        const start_x = cell_x * subpixel_x;
        const start_y = cell_y * subpixel_y;
        const sub_w = self.subpixelWidth();
        var tone: u8 = 0;

        var sy: usize = 0;
        while (sy < subpixel_y) : (sy += 1) {
            var sx: usize = 0;
            while (sx < subpixel_x) : (sx += 1) {
                const idx = (start_y + sy) * sub_w + (start_x + sx);
                tone = @max(tone, self.tones[idx]);
            }
        }

        return tone;
    }

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        const subpixels = try allocator.alloc(u8, width * height * subpixel_x * subpixel_y);
        const tones = try allocator.alloc(u8, width * height * subpixel_x * subpixel_y);
        const fill_shades = try allocator.alloc(u8, width * height);
        const fill_tones = try allocator.alloc(u8, width * height);
        const fill_depths = try allocator.alloc(f32, width * height);
        const markers = try allocator.alloc(u8, width * height);
        @memset(subpixels, 0);
        @memset(tones, 0);
        @memset(fill_shades, 0);
        @memset(fill_tones, 0);
        @memset(fill_depths, std.math.inf(f32));
        @memset(markers, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .subpixels = subpixels,
            .tones = tones,
            .fill_shades = fill_shades,
            .fill_tones = fill_tones,
            .fill_depths = fill_depths,
            .markers = markers,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.subpixels);
        self.allocator.free(self.tones);
        self.allocator.free(self.fill_shades);
        self.allocator.free(self.fill_tones);
        self.allocator.free(self.fill_depths);
        self.allocator.free(self.markers);
    }

    pub fn clear(self: *Canvas) void {
        @memset(self.subpixels, 0);
        @memset(self.tones, 0);
        @memset(self.fill_shades, 0);
        @memset(self.fill_tones, 0);
        @memset(self.fill_depths, std.math.inf(f32));
        @memset(self.markers, 0);
    }

    pub fn setPixel(self: *Canvas, x: isize, y: isize, char: u8) void {
        _ = char;
        self.setSubpixel(x * subpixel_x + @as(isize, subpixel_x / 2), y * subpixel_y + @as(isize, subpixel_y / 2), 1, 255);
    }

    pub fn drawLine(self: *Canvas, x0_f: f32, y0_f: f32, x1_f: f32, y1_f: f32, char: u8, tone: u8) void {
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
            self.setSubpixel(x0, y0, 1, tone);
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

    pub fn setFill(self: *Canvas, x_f: f32, y_f: f32, shade: u8, tone: u8, depth: f32) void {
        if (shade == 0) return;

        const x: isize = @intFromFloat(@round(x_f));
        const y: isize = @intFromFloat(@round(y_f));
        const width_i: isize = @intCast(self.width);
        const height_i: isize = @intCast(self.height);
        if (x < 0 or x >= width_i or y < 0 or y >= height_i) return;

        const idx: usize = @intCast(y * width_i + x);
        if (depth >= self.fill_depths[idx]) return;

        self.fill_depths[idx] = depth;
        self.fill_shades[idx] = @min(shade, fill_ramp.len - 1);
        self.fill_tones[idx] = tone;
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
                const glyph = self.glyphForCell(x, y);
                const fill_shade = self.fill_shades[y * self.width + x];
                const fill_tone = self.fill_tones[y * self.width + x];
                const marker = @as(MarkerColor, @enumFromInt(self.markers[y * self.width + x]));
                switch (marker) {
                    .none => {
                        if (std.mem.eql(u8, glyph, " ")) {
                            if (fill_shade == 0) {
                                try writer.writeAll(glyph);
                                continue;
                            }

                            var fill_buf: [32]u8 = undefined;
                            const fill_glyph = fill_ramp[fill_shade];
                            const colored_fill = try std.fmt.bufPrint(
                                &fill_buf,
                                "\x1B[38;5;{d}m{s}\x1B[0m",
                                .{ fill_tone, fill_glyph },
                            );
                            try writer.writeAll(colored_fill);
                            continue;
                        }

                        const tone = self.toneForCell(x, y);
                        var buf: [32]u8 = undefined;
                        const colored = try std.fmt.bufPrint(&buf, "\x1B[38;5;{d}m{s}\x1B[0m", .{ tone, glyph });
                        try writer.writeAll(colored);
                    },
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

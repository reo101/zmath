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

/// Projects a point using PGA universal projection formula.
/// P' = (Eye v Point) ^ Screen
pub fn projectPGA(camera: anytype, p: anytype, canvas_width: usize, canvas_height: usize) ?[2]f32 {
    zmath.ensureMultivector(@TypeOf(p));
    
    // ray = Eye v Point
    const ray = camera.eye.join(p);
    
    // point_on_screen = ray ^ Screen
    const p_prime_mv = ray.wedge(camera.screen);
    
    // The result should be a Point (grade 3 in PGA)
    const p_prime = p_prime_mv.gradePart(3);
    
    // In 3D PGA with a 4D carrier, points are trivectors.
    // We'll use the indices directly to avoid naming conflicts if necessary,
    // or use the standard Euclidean names e1, e2, e3, e4.
    // e123, e124, e134, e234 are the trivectors.
    const w = p_prime.coeffNamed("e123");
    if (@abs(w) < 1e-6) return null;

    const x_coord = p_prime.coeffNamed("e234") / w;
    const y_coord = p_prime.coeffNamed("e134") / w; // Use e134 for y
    const z_coord = p_prime.coeffNamed("e124") / w;

    // Vector from origin to projected point on screen
    // Note: Screen is at z=0, so z_coord should be near 0
    _ = z_coord;

    // Mapping to canvas: 
    // We'll use a simple scale factor for visibility
    const zoom: f32 = 10.0;
    const aspect = @as(f32, @floatFromInt(canvas_width)) / @as(f32, @floatFromInt(canvas_height * 2));
    
    const x = (x_coord * zoom / aspect + 1.0) * (@as(f32, @floatFromInt(canvas_width)) / 2.0);
    const y = (1.0 - y_coord * zoom) * (@as(f32, @floatFromInt(canvas_height)) / 2.0);

    return .{ x, y };
}

/// A camera that projects 3D vectors onto a 2D canvas using GA.
pub fn Camera(comptime T: type) type {
    return struct {
        const Self = @This();
        pos: [3]T,
        target: [3]T,
        up: [3]T,
        fov: T,

        pub fn init(pos: anytype, target: anytype, up: anytype, fov: T) Self {
            zmath.ensureMultivector(@TypeOf(pos));
            zmath.ensureMultivector(@TypeOf(target));
            zmath.ensureMultivector(@TypeOf(up));

            return .{
                .pos = .{ pos.coeffNamed("e1"), pos.coeffNamed("e2"), pos.coeffNamed("e3") },
                .target = .{ target.coeffNamed("e1"), target.coeffNamed("e2"), target.coeffNamed("e3") },
                .up = .{ up.coeffNamed("e1"), up.coeffNamed("e2"), up.coeffNamed("e3") },
                .fov = fov,
            };
        }

        /// Projects a 3D point onto a 2D coordinate using perspective projection.
        pub fn project(self: Self, point: anytype) ?[2]T {
            return self.projectInternal(point, true);
        }

        /// Projects a 3D point onto a 2D coordinate using parallel (orthographic) projection.
        pub fn projectParallel(self: Self, point: anytype) ?[2]T {
            return self.projectInternal(point, false);
        }

        fn projectInternal(self: Self, point: anytype, perspective: bool) ?[2]T {
            zmath.ensureMultivector(@TypeOf(point));
            
            const Cl3 = zmath.Algebra(zmath.euclideanSignature(3));
            const h = Cl3.Instantiate(T);

            const cam_pos = h.Vector.init(.{ self.pos[0], self.pos[1], self.pos[2] });
            const cam_target = h.Vector.init(.{ self.target[0], self.target[1], self.target[2] });
            const cam_up = h.Vector.init(.{ self.up[0], self.up[1], self.up[2] });

            const forward = zmath.normalized(cam_target.sub(cam_pos));
            const relative = point.sub(cam_pos);
            
            const depth = relative.dot(forward).scalarCoeff();
            if (perspective and depth <= 0.1) return null;

            // Planar component (rejection from forward)
            const planar = relative.sub(forward.scale(depth));
            
            const right_mv = zmath.dual(forward.outerProduct(cam_up));
            const right = zmath.normalized(right_mv.gradePart(1));
            
            const up_mv = zmath.dual(right.outerProduct(forward));
            const actual_up = zmath.normalized(up_mv.gradePart(1));

            const divisor = if (perspective) depth * @tan(self.fov / 2) else 2.0; // Scale factor for ortho
            const x = planar.dot(right).scalarCoeff() / divisor;
            const y = planar.dot(actual_up).scalarCoeff() / divisor;

            return .{ x, y };
        }

        /// Projects a point from an arbitrary dimension onto a 2D plane defined by two unit basis vectors.
        /// This is a parallel projection.
        pub fn projectND(point: anytype, e_x: anytype, e_y: anytype) [2]T {
            zmath.ensureMultivector(@TypeOf(point));
            zmath.ensureMultivector(@TypeOf(e_x));
            zmath.ensureMultivector(@TypeOf(e_y));
            
            // x = point . e_x, y = point . e_y
            return .{
                point.dot(e_x).scalarCoeff(),
                point.dot(e_y).scalarCoeff(),
            };
        }
    };
}

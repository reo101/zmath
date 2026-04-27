const std = @import("std");
const rl = @import("raylib");
const zmath = @import("zmath");

const Vga3 = zmath.flavours.vga.EuclideanFamily(3).Instantiate(f32);
const Pga3 = zmath.flavours.pga.FamilyHelpers(zmath.flavours.pga.EuclideanFamily(3), f32);

pub const mode_count = 4;

pub const Mode = enum {
    perspective,
    isometric,
    spherical,
    hyperbolic,

    pub fn label(self: Mode) [:0]const u8 {
        return switch (self) {
            .perspective => "classic perspective",
            .isometric => "isometric",
            .spherical => "spherical",
            .hyperbolic => "hyperbolic",
        };
    }

    pub fn flavour(self: Mode) [:0]const u8 {
        return switch (self) {
            .perspective => "VGA camera: Euclidean vectors and perspective divide",
            .isometric => "PGA camera: projective/orthographic view",
            .spherical => "spherical space: two stereographic passes",
            .hyperbolic => "hyperbolic space: compressed projective chart",
        };
    }
};

pub const Input = struct {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    look_left: bool = false,
    look_right: bool = false,
    look_up: bool = false,
    look_down: bool = false,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn add(self: Vec3, rhs: Vec3) Vec3 {
        return .{ .x = self.x + rhs.x, .y = self.y + rhs.y, .z = self.z + rhs.z };
    }

    pub fn sub(self: Vec3, rhs: Vec3) Vec3 {
        return .{ .x = self.x - rhs.x, .y = self.y - rhs.y, .z = self.z - rhs.z };
    }

    pub fn scale(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub fn negate(self: Vec3) Vec3 {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn normalized(self: Vec3) ?Vec3 {
        const len = self.length();
        if (len < 0.0001) return null;
        return self.scale(1.0 / len);
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
        };
    }
};

pub const Camera = struct {
    position: Vec3,
    yaw: f32,
    pitch: f32,

    pub fn reset(mode: Mode) Camera {
        return switch (mode) {
            .perspective => .{
                .position = .{ .x = 0.0, .y = 1.45, .z = -5.2 },
                .yaw = 0.0,
                .pitch = -0.05,
            },
            .isometric => .{
                .position = .{ .x = 0.0, .y = 2.8, .z = -3.2 },
                .yaw = std.math.pi / 4.0,
                .pitch = -0.62,
            },
            .spherical => .{
                .position = .{ .x = 0.0, .y = 1.35, .z = -4.8 },
                .yaw = 0.0,
                .pitch = -0.02,
            },
            .hyperbolic => .{
                .position = .{ .x = 0.0, .y = 1.35, .z = -4.8 },
                .yaw = 0.0,
                .pitch = -0.03,
            },
        };
    }

    pub fn relative(self: Camera, world: Vec3) Vec3 {
        const delta = world.sub(self.position);

        const cy = @cos(-self.yaw);
        const sy = @sin(-self.yaw);
        const x1 = delta.x * cy - delta.z * sy;
        const z1 = delta.x * sy + delta.z * cy;

        const cp = @cos(-self.pitch);
        const sp = @sin(-self.pitch);
        return .{
            .x = x1,
            .y = delta.y * cp - z1 * sp,
            .z = delta.y * sp + z1 * cp,
        };
    }

    pub fn moveLocal(self: *Camera, input: Input, mode: Mode, dt: f32) void {
        var local_x: f32 = 0.0;
        var local_y: f32 = 0.0;
        var local_z: f32 = 0.0;
        if (input.forward) local_z += 1.0;
        if (input.backward) local_z -= 1.0;
        if (input.right) local_x += 1.0;
        if (input.left) local_x -= 1.0;
        if (input.up) local_y += 1.0;
        if (input.down) local_y -= 1.0;

        const speed: f32 = switch (mode) {
            .perspective => 3.1,
            .isometric => 3.6,
            .spherical => 2.2,
            .hyperbolic => 1.7,
        };

        const forward = Vec3{ .x = @sin(self.yaw), .y = 0.0, .z = @cos(self.yaw) };
        const right = Vec3{ .x = @cos(self.yaw), .y = 0.0, .z = -@sin(self.yaw) };
        const movement = forward.scale(local_z).add(right.scale(local_x)).add(.{ .x = 0.0, .y = local_y, .z = 0.0 });
        if (movement.normalized()) |dir| {
            self.position = self.position.add(dir.scale(speed * dt));
        }

        const look_speed: f32 = if (mode == .isometric) 1.0 else 1.35;
        if (input.look_left) self.yaw -= look_speed * dt;
        if (input.look_right) self.yaw += look_speed * dt;

        if (mode != .isometric) {
            if (input.look_up) self.pitch += look_speed * dt;
            if (input.look_down) self.pitch -= look_speed * dt;
            self.pitch = std.math.clamp(self.pitch, -1.15, 1.15);
        }
    }

    pub fn metricDistanceSquaredToCube(self: Camera) f32 {
        const delta = cube_center.sub(self.position);
        const v = Vga3.Vector.init(.{ delta.x, delta.y, delta.z });
        return v.gp(v).scalarCoeff();
    }

    pub fn pgaPosition(self: Camera) [4]f32 {
        return Pga3.ambientCoords(Pga3.Point.fromCoords(.{ self.position.x, self.position.y, self.position.z }));
    }
};

pub const State = struct {
    mode: Mode = .perspective,
    cameras: [mode_count]Camera = defaultCameras(),

    pub fn init() State {
        return .{};
    }

    pub fn activeCamera(self: *const State) Camera {
        return self.cameras[modeIndex(self.mode)];
    }

    pub fn activeCameraPtr(self: *State) *Camera {
        return &self.cameras[modeIndex(self.mode)];
    }

    pub fn setMode(self: *State, mode: Mode) void {
        self.mode = mode;
    }

    pub fn nextMode(self: *State) void {
        self.mode = switch (self.mode) {
            .perspective => .isometric,
            .isometric => .spherical,
            .spherical => .hyperbolic,
            .hyperbolic => .perspective,
        };
    }

    pub fn resetActive(self: *State) void {
        self.cameras[modeIndex(self.mode)] = Camera.reset(self.mode);
    }

    pub fn update(self: *State, input: Input, dt: f32) void {
        self.activeCameraPtr().moveLocal(input, self.mode, dt);
    }
};

pub const Pass = enum {
    main,
    far,
};

pub const Projected = struct {
    pos: rl.Vector2,
    depth: f32,
};

pub const Face = struct {
    indices: [4]usize,
};

pub const cube_center = Vec3{ .x = 0.0, .y = 1.25, .z = 4.8 };
pub const cube_size: f32 = 1.9;

pub const cube_faces = [_]Face{
    .{ .indices = .{ 0, 1, 3, 2 } },
    .{ .indices = .{ 4, 6, 7, 5 } },
    .{ .indices = .{ 0, 4, 5, 1 } },
    .{ .indices = .{ 2, 3, 7, 6 } },
    .{ .indices = .{ 0, 2, 6, 4 } },
    .{ .indices = .{ 1, 5, 7, 3 } },
};

pub const cube_edges = [_][2]usize{
    .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
    .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 },
    .{ 2, 6 }, .{ 3, 7 }, .{ 4, 5 },
    .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
};

pub fn cubeVertices() [8]Vec3 {
    const h = cube_size * 0.5;
    return .{
        cube_center.add(.{ .x = -h, .y = -h, .z = -h }),
        cube_center.add(.{ .x = -h, .y = -h, .z = h }),
        cube_center.add(.{ .x = -h, .y = h, .z = -h }),
        cube_center.add(.{ .x = -h, .y = h, .z = h }),
        cube_center.add(.{ .x = h, .y = -h, .z = -h }),
        cube_center.add(.{ .x = h, .y = -h, .z = h }),
        cube_center.add(.{ .x = h, .y = h, .z = -h }),
        cube_center.add(.{ .x = h, .y = h, .z = h }),
    };
}

pub fn project(mode: Mode, camera: Camera, world: Vec3, rect: rl.Rectangle, pass: Pass) ?Projected {
    return switch (mode) {
        .perspective => projectPerspective(camera.relative(world), rect),
        .isometric => projectIsometric(camera.relative(world), rect),
        .spherical => projectSpherical(camera.relative(world), rect, pass),
        .hyperbolic => projectHyperbolic(camera.relative(world), rect),
    };
}

fn projectPerspective(rel: Vec3, rect: rl.Rectangle) ?Projected {
    if (rel.z <= 0.12) return null;
    const center = rectCenter(rect);
    const focal = @min(rect.width, rect.height) * 0.82;
    return .{
        .pos = .{
            .x = center.x + rel.x / rel.z * focal,
            .y = center.y - rel.y / rel.z * focal,
        },
        .depth = rel.z,
    };
}

fn projectIsometric(rel: Vec3, rect: rl.Rectangle) ?Projected {
    const center = rectCenter(rect);
    const scale = @min(rect.width, rect.height) * 0.115;
    return .{
        .pos = .{
            .x = center.x + rel.x * scale,
            .y = center.y - rel.y * scale,
        },
        .depth = rel.z,
    };
}

fn projectHyperbolic(rel: Vec3, rect: rl.Rectangle) ?Projected {
    if (rel.z <= 0.08) return null;
    const center = rectCenter(rect);
    const focal = @min(rect.width, rect.height) * 0.72;
    const hx = rel.x / rel.z;
    const hy = rel.y / rel.z;
    const r = @sqrt(hx * hx + hy * hy);
    const compress = if (r < 0.0001) 1.0 else std.math.tanh(r * 0.78) / (r * 0.78);
    const depth_compress = std.math.tanh(rel.z * 0.09) * 0.55 + 0.68;

    return .{
        .pos = .{
            .x = center.x + hx * compress * focal * depth_compress,
            .y = center.y - hy * compress * focal * depth_compress,
        },
        .depth = @log(1.0 + rel.z),
    };
}

fn projectSpherical(rel: Vec3, rect: rl.Rectangle, pass: Pass) ?Projected {
    const base_dir = rel.normalized() orelse return null;
    if (pass == .main and base_dir.z < -0.02) return null;
    if (pass == .far and base_dir.z > 0.02) return null;

    const dir = if (pass == .far) base_dir.negate() else base_dir;
    const denom = 1.0 + dir.z;
    if (denom < 0.05) return null;

    const center = rectCenter(rect);
    const scale = @min(rect.width, rect.height) * 0.58;
    return .{
        .pos = .{
            .x = center.x + dir.x / denom * scale,
            .y = center.y - dir.y / denom * scale,
        },
        .depth = if (pass == .far) rel.length() + 200.0 else rel.length(),
    };
}

fn rectCenter(rect: rl.Rectangle) rl.Vector2 {
    return .{ .x = rect.x + rect.width * 0.5, .y = rect.y + rect.height * 0.5 };
}

pub fn modeIndex(mode: Mode) usize {
    return switch (mode) {
        .perspective => 0,
        .isometric => 1,
        .spherical => 2,
        .hyperbolic => 3,
    };
}

fn defaultCameras() [mode_count]Camera {
    return .{
        Camera.reset(.perspective),
        Camera.reset(.isometric),
        Camera.reset(.spherical),
        Camera.reset(.hyperbolic),
    };
}

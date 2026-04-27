const std = @import("std");
const rl = @import("raylib");
const zmath = @import("zmath");

const Vga3 = zmath.flavours.vga.EuclideanFamily(3).Instantiate(f32);
const Pga3 = zmath.flavours.pga.FamilyHelpers(zmath.flavours.pga.EuclideanFamily(3), f32);
const curved = zmath.geometry.curved;
const curved_ground = zmath.render.curved_ground;

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
            .spherical => "S3 view: spherical floor-height embedding, stereographic hemisphere passes",
            .hyperbolic => "H3 view: GA ambient camera, Poincare/Klein-style conformal chart",
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

const CurvedMetric = enum {
    spherical,
    hyperbolic,
};

const CurvedView = union(CurvedMetric) {
    spherical: curved.SphericalView,
    hyperbolic: curved.HyperView,
};

pub const Camera = struct {
    position: Vec3,
    yaw: f32,
    pitch: f32,
    curvature_radius: f32,
    curved_view: ?CurvedView = null,

    pub fn reset(mode: Mode) Camera {
        return switch (mode) {
            .perspective => .{
                .position = .{ .x = 0.0, .y = 1.45, .z = -5.2 },
                .yaw = 0.0,
                .pitch = -0.05,
                .curvature_radius = 0.0,
            },
            .isometric => .{
                .position = .{ .x = 0.0, .y = 2.8, .z = -3.2 },
                .yaw = std.math.pi / 4.0,
                .pitch = -0.62,
                .curvature_radius = 0.0,
            },
            .spherical => .{
                .position = .{ .x = 0.0, .y = 1.35, .z = -4.8 },
                .yaw = 0.0,
                .pitch = -0.02,
                .curvature_radius = default_spherical_radius,
                .curved_view = .{ .spherical = initSphericalView(
                    default_spherical_radius,
                    .{ .x = 0.0, .y = 1.35, .z = -4.8 },
                    0.0,
                    -0.02,
                ) },
            },
            .hyperbolic => .{
                .position = .{ .x = 0.0, .y = 1.35, .z = -4.8 },
                .yaw = 0.0,
                .pitch = -0.03,
                .curvature_radius = default_hyperbolic_radius,
                .curved_view = .{ .hyperbolic = initHyperbolicView(
                    default_hyperbolic_radius,
                    .{ .x = 0.0, .y = 1.35, .z = -4.8 },
                    0.0,
                    -0.03,
                ) },
            },
        };
    }

    pub fn relative(self: *const Camera, world: Vec3) Vec3 {
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
        const previous_position = self.position;
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

        if (curvedMetricForMode(mode)) |metric| {
            self.moveCurved(metric, local_x, local_y, local_z, speed * dt);
        } else {
            const forward = Vec3{ .x = -@sin(self.yaw), .y = 0.0, .z = @cos(self.yaw) };
            const right = Vec3{ .x = @cos(self.yaw), .y = 0.0, .z = @sin(self.yaw) };
            const movement = forward.scale(local_z).add(right.scale(local_x)).add(.{ .x = 0.0, .y = local_y, .z = 0.0 });
            if (movement.normalized()) |dir| {
                self.position = self.position.add(dir.scale(speed * dt));
            }
        }

        self.resolveCubeCollision(mode, previous_position);

        const look_speed: f32 = if (mode == .isometric) 1.0 else 1.35;
        const look_left = input.look_left;
        const look_right = input.look_right;
        if (curvedMetricForMode(mode)) |metric| {
            var yaw_delta: f32 = 0.0;
            if (look_left) yaw_delta -= look_speed * dt;
            if (look_right) yaw_delta += look_speed * dt;
            self.turnCurved(metric, yaw_delta);
        } else {
            if (look_left) self.yaw += look_speed * dt;
            if (look_right) self.yaw -= look_speed * dt;
        }

        if (mode != .isometric) {
            if (input.look_up) self.pitch += look_speed * dt;
            if (input.look_down) self.pitch -= look_speed * dt;
            self.pitch = std.math.clamp(self.pitch, -1.15, 1.15);
            if (curvedMetricForMode(mode)) |metric| {
                self.syncCurvedPitch(metric);
            }
        }
    }

    fn moveCurved(self: *Camera, metric: CurvedMetric, local_x: f32, local_y: f32, local_z: f32, step: f32) void {
        const input_len = @sqrt(local_x * local_x + local_y * local_y + local_z * local_z);
        if (input_len <= 1e-6) return;

        const horizontal_len = @sqrt(local_x * local_x + local_z * local_z);
        const vertical_step = step * local_y / input_len;
        const horizontal_step = step * horizontal_len / input_len;

        switch (metric) {
            .spherical => {
                const view = self.sphericalViewPtr() orelse return;
                if (horizontal_len > 1e-6) {
                    const Round = curved.AmbientFor(.spherical);
                    const basis = view.walkBasis() orelse return;
                    const direction = Round.add(
                        Round.scale(basis.right, local_x / horizontal_len),
                        Round.scale(basis.forward, local_z / horizontal_len),
                    );
                    view.moveAlong(direction, horizontal_step);
                }
                if (@abs(vertical_step) > 1e-6) {
                    const up = view.walkSurfaceUp() orelse view.camera.up;
                    view.moveAlong(up, vertical_step);
                }
                view.wrapSphericalChart();
                self.position = vecFromCurved(view.chartCoords(view.camera.position));
            },
            .hyperbolic => {
                const view = self.hyperbolicViewPtr() orelse return;
                if (horizontal_len > 1e-6) {
                    const Hyper = curved.AmbientFor(.hyperbolic);
                    const basis = view.walkBasis() orelse return;
                    const direction = Hyper.add(
                        Hyper.scale(basis.right, local_x / horizontal_len),
                        Hyper.scale(basis.forward, local_z / horizontal_len),
                    );
                    view.moveAlong(direction, horizontal_step);
                }
                if (@abs(vertical_step) > 1e-6) {
                    const up = view.walkSurfaceUp() orelse view.camera.up;
                    view.moveAlong(up, vertical_step);
                }
                self.position = vecFromCurved(view.chartCoords(view.camera.position));
            },
        }
    }

    fn resolveCubeCollision(self: *Camera, mode: Mode, previous_position: Vec3) void {
        const resolved = resolvePositionOutsideCube(self.position, previous_position) orelse return;
        self.position = resolved;

        const metric = curvedMetricForMode(mode) orelse return;
        const radius = self.curvedRadius(metric);
        self.curvature_radius = radius;
        self.curved_view = switch (metric) {
            .spherical => .{ .spherical = initSphericalView(radius, self.position, self.yaw, self.pitch) },
            .hyperbolic => .{ .hyperbolic = initHyperbolicView(radius, self.position, self.yaw, self.pitch) },
        };
    }

    pub fn adjustCurvature(self: *Camera, mode: Mode, more_curved: bool) void {
        const metric = curvedMetricForMode(mode) orelse return;
        const bounds = curvatureRadiusBounds(metric);
        const factor: f32 = if (more_curved) 0.86 else 1.0 / 0.86;
        const next_radius = std.math.clamp(self.curvedRadius(metric) * factor, bounds.min, bounds.max);
        self.curvature_radius = next_radius;
        switch (metric) {
            .spherical => {
                const view = self.sphericalViewPtr() orelse return;
                view.adjustRadius(next_radius, 0.4) catch {
                    view.* = initSphericalView(next_radius, self.position, self.yaw, self.pitch);
                };
                view.wrapSphericalChart();
                self.position = vecFromCurved(view.chartCoords(view.camera.position));
            },
            .hyperbolic => {
                const view = self.hyperbolicViewPtr() orelse return;
                view.adjustRadius(next_radius, 0.4) catch {
                    view.* = initHyperbolicView(next_radius, self.position, self.yaw, self.pitch);
                };
                self.position = vecFromCurved(view.chartCoords(view.camera.position));
            },
        }
    }

    pub fn curvatureValue(self: Camera, mode: Mode) ?f32 {
        const metric = curvedMetricForMode(mode) orelse return null;
        const radius = self.curvedRadius(metric);
        const magnitude = 1.0 / (radius * radius);
        return switch (metric) {
            .spherical => magnitude,
            .hyperbolic => -magnitude,
        };
    }

    pub fn curvatureRadiusValue(self: Camera, mode: Mode) ?f32 {
        const metric = curvedMetricForMode(mode) orelse return null;
        return self.curvedRadius(metric);
    }

    fn curvedRadius(self: Camera, metric: CurvedMetric) f32 {
        if (self.curved_view) |view| {
            return switch (view) {
                .spherical => |spherical| spherical.params.radius,
                .hyperbolic => |hyperbolic| hyperbolic.params.radius,
            };
        }
        if (self.curvature_radius > 0.0) return self.curvature_radius;
        return defaultCurvedRadius(metric);
    }

    pub fn metricDistanceSquaredToCube(self: Camera) f32 {
        const delta = cube_center.sub(self.position);
        const v = Vga3.Vector.init(.{ delta.x, delta.y, delta.z });
        return v.gp(v).scalarCoeff();
    }

    pub fn pgaPosition(self: Camera) [4]f32 {
        return Pga3.ambientCoords(Pga3.Point.fromCoords(.{ self.position.x, self.position.y, self.position.z }));
    }

    fn sphericalViewPtr(self: *Camera) ?*curved.SphericalView {
        if (self.curved_view) |*view| {
            return switch (view.*) {
                .spherical => |*spherical| spherical,
                .hyperbolic => null,
            };
        }
        return null;
    }

    fn hyperbolicViewPtr(self: *Camera) ?*curved.HyperView {
        if (self.curved_view) |*view| {
            return switch (view.*) {
                .spherical => null,
                .hyperbolic => |*hyperbolic| hyperbolic,
            };
        }
        return null;
    }

    fn turnCurved(self: *Camera, metric: CurvedMetric, angle: f32) void {
        if (@abs(angle) <= 1e-6) return;
        self.yaw -= angle;
        switch (metric) {
            .spherical => {
                const view = self.sphericalViewPtr() orelse return;
                view.turnSurfaceYaw(angle, self.pitch);
            },
            .hyperbolic => {
                const view = self.hyperbolicViewPtr() orelse return;
                view.turnSurfaceYaw(angle, self.pitch);
            },
        }
    }

    fn syncCurvedPitch(self: *Camera, metric: CurvedMetric) void {
        switch (metric) {
            .spherical => {
                const view = self.sphericalViewPtr() orelse return;
                view.syncSurfacePitch(self.pitch);
            },
            .hyperbolic => {
                const view = self.hyperbolicViewPtr() orelse return;
                view.syncSurfacePitch(self.pitch);
            },
        }
    }
};

pub const State = struct {
    mode: Mode = .perspective,
    cameras: [mode_count]Camera,

    pub fn init() State {
        return .{ .cameras = defaultCameras() };
    }

    pub fn activeCamera(self: *const State) Camera {
        return self.cameras[modeIndex(self.mode)];
    }

    pub fn activeCameraPtrConst(self: *const State) *const Camera {
        return &self.cameras[modeIndex(self.mode)];
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

    pub fn adjustActiveCurvature(self: *State, more_curved: bool) void {
        self.activeCameraPtr().adjustCurvature(self.mode, more_curved);
    }

    pub fn update(self: *State, input: Input, dt: f32) void {
        self.activeCameraPtr().moveLocal(input, self.mode, dt);
    }
};

pub const Projected = struct {
    pos: rl.Vector2,
    depth: f32,
};

pub const Pass = enum {
    main,
    far,
};

pub const Face = struct {
    indices: [4]usize,
};

pub const cube_size: f32 = 7.0;
pub const cube_center = Vec3{ .x = 0.0, .y = cube_size * 0.5, .z = 6.8 };
pub const cube_bottom_face_index: usize = 2;
const camera_collision_margin: f32 = 0.45;

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

pub fn cubeVerticesFor(mode: Mode, camera: Camera) [8]Vec3 {
    _ = mode;
    _ = camera;
    return cubeVertices();
}

pub fn segmentPoint(mode: Mode, camera: *const Camera, a: Vec3, b: Vec3, t: f32) Vec3 {
    _ = mode;
    _ = camera;
    return Vec3.lerp(a, b, t);
}

pub fn facePoint(mode: Mode, camera: *const Camera, a: Vec3, b: Vec3, c: Vec3, d: Vec3, u: f32, v: f32) Vec3 {
    _ = mode;
    _ = camera;
    return Vec3.lerp(Vec3.lerp(a, b, u), Vec3.lerp(d, c, u), v);
}

const CubeBounds = struct {
    min: Vec3,
    max: Vec3,
};

fn resolvePositionOutsideCube(position: Vec3, previous_position: Vec3) ?Vec3 {
    const bounds = cubeCollisionBounds();
    if (!insideBounds(position, bounds)) return null;

    var resolved = position;
    if (previous_position.x <= bounds.min.x) {
        resolved.x = bounds.min.x;
        resolved.y = previous_position.y;
    } else if (previous_position.x >= bounds.max.x) {
        resolved.x = bounds.max.x;
        resolved.y = previous_position.y;
    } else if (previous_position.y <= bounds.min.y) {
        resolved.y = bounds.min.y;
    } else if (previous_position.y >= bounds.max.y) {
        resolved.y = bounds.max.y;
    } else if (previous_position.z <= bounds.min.z) {
        resolved.z = bounds.min.z;
        resolved.y = previous_position.y;
    } else if (previous_position.z >= bounds.max.z) {
        resolved.z = bounds.max.z;
        resolved.y = previous_position.y;
    } else {
        resolved = pushOutNearestCubeFace(position, bounds);
    }

    return resolved;
}

fn cubeCollisionBounds() CubeBounds {
    const h = cube_size * 0.5 + camera_collision_margin;
    return .{
        .min = .{ .x = cube_center.x - h, .y = cube_center.y - h, .z = cube_center.z - h },
        .max = .{ .x = cube_center.x + h, .y = cube_center.y + h, .z = cube_center.z + h },
    };
}

fn insideBounds(position: Vec3, bounds: CubeBounds) bool {
    return position.x > bounds.min.x and position.x < bounds.max.x and
        position.y > bounds.min.y and position.y < bounds.max.y and
        position.z > bounds.min.z and position.z < bounds.max.z;
}

fn pushOutNearestCubeFace(position: Vec3, bounds: CubeBounds) Vec3 {
    var resolved = position;
    var best_distance = position.x - bounds.min.x;
    var axis: enum { min_x, max_x, min_y, max_y, min_z, max_z } = .min_x;

    const max_x_distance = bounds.max.x - position.x;
    if (max_x_distance < best_distance) {
        best_distance = max_x_distance;
        axis = .max_x;
    }
    const min_y_distance = position.y - bounds.min.y;
    if (min_y_distance < best_distance) {
        best_distance = min_y_distance;
        axis = .min_y;
    }
    const max_y_distance = bounds.max.y - position.y;
    if (max_y_distance < best_distance) {
        best_distance = max_y_distance;
        axis = .max_y;
    }
    const min_z_distance = position.z - bounds.min.z;
    if (min_z_distance < best_distance) {
        best_distance = min_z_distance;
        axis = .min_z;
    }
    const max_z_distance = bounds.max.z - position.z;
    if (max_z_distance < best_distance) {
        axis = .max_z;
    }

    switch (axis) {
        .min_x => resolved.x = bounds.min.x,
        .max_x => resolved.x = bounds.max.x,
        .min_y => resolved.y = bounds.min.y,
        .max_y => resolved.y = bounds.max.y,
        .min_z => resolved.z = bounds.min.z,
        .max_z => resolved.z = bounds.max.z,
    }
    return resolved;
}

pub fn project(mode: Mode, camera: *const Camera, world: Vec3, rect: rl.Rectangle, pass: Pass) ?Projected {
    return switch (mode) {
        .perspective => projectPerspective(camera.relative(world), rect),
        .isometric => projectIsometric(camera.relative(world), rect),
        .spherical, .hyperbolic => projectCurved(camera, world, rect, pass),
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

fn projectCurved(camera: *const Camera, world: Vec3, rect: rl.Rectangle, pass: Pass) ?Projected {
    _ = pass;
    const view = camera.curved_view orelse return null;
    return switch (view) {
        .spherical => |spherical| projectCurvedSample(
            spherical.sampleProjectedAmbient(sphericalSceneAmbient(spherical.params, world), screenForRect(rect, spherical.params.angular_zoom)),
            rect,
        ),
        .hyperbolic => |hyperbolic| projectCurvedSample(
            hyperbolic.sampleProjectedPoint(curvedVec(world), screenForRect(rect, hyperbolic.params.angular_zoom)),
            rect,
        ),
    };
}

fn projectCurvedSample(sample: curved.ProjectedSample, rect: rl.Rectangle) ?Projected {
    if (sample.status != .visible) return null;
    const projected = sample.projected orelse return null;
    return .{
        .pos = .{
            .x = rect.x + projected[0],
            .y = rect.y + projected[1],
        },
        .depth = sample.distance,
    };
}

pub const GroundSample = struct {
    distance: f32,
    checker: bool,
    line_strength: f32,
};

pub fn groundSample(mode: Mode, camera: *const Camera, rect: rl.Rectangle, point: rl.Vector2) ?GroundSample {
    if (mode != .spherical) return null;
    const view = switch (camera.curved_view orelse return null) {
        .spherical => |spherical| spherical,
        .hyperbolic => return null,
    };
    const screen = screenForRect(rect, view.params.angular_zoom);
    const local = [2]f32{ point.x - rect.x, point.y - rect.y };
    const hit = curved_ground.sphericalGroundHitForScreenPoint(
        view,
        curved_ground.worldSphericalGroundBasis(),
        screen,
        local,
    ) orelse return null;

    const cell_size: f32 = 1.0;
    const line_strength = @max(
        curved_ground.gridLineStrength(hit.lateral, cell_size, 0.065),
        curved_ground.gridLineStrength(hit.forward, cell_size, 0.065),
    );
    const checker = ((curved_ground.checkerCoord(hit.lateral, cell_size) + curved_ground.checkerCoord(hit.forward, cell_size)) & 1) == 0;

    return .{
        .distance = hit.distance,
        .checker = checker,
        .line_strength = line_strength,
    };
}

fn defaultCurvedRadius(metric: CurvedMetric) f32 {
    return switch (metric) {
        .spherical => default_spherical_radius,
        .hyperbolic => default_hyperbolic_radius,
    };
}

const RadiusBounds = struct {
    min: f32,
    max: f32,
};

fn curvatureRadiusBounds(metric: CurvedMetric) RadiusBounds {
    return switch (metric) {
        .spherical => .{ .min = 2.8, .max = 28.0 },
        .hyperbolic => .{ .min = 1.6, .max = 28.0 },
    };
}

fn curvedMetricForMode(mode: Mode) ?CurvedMetric {
    return switch (mode) {
        .perspective, .isometric => null,
        .spherical => .spherical,
        .hyperbolic => .hyperbolic,
    };
}

pub const default_spherical_radius: f32 = 7.1;
pub const default_hyperbolic_radius: f32 = 5.6;
pub const default_spherical_zoom: f32 = 1.0;
pub const default_hyperbolic_zoom: f32 = 0.78;

fn curvedParams(metric: CurvedMetric, radius: f32) curved.Params {
    return .{
        .radius = radius,
        .angular_zoom = switch (metric) {
            .spherical => default_spherical_zoom,
            .hyperbolic => default_hyperbolic_zoom,
        },
        .chart_model = .conformal,
    };
}

fn curvedClip(metric: CurvedMetric) curved.DistanceClip {
    return switch (metric) {
        .spherical => .{ .near = 0.025, .far = std.math.inf(f32) },
        .hyperbolic => .{ .near = 0.04, .far = std.math.inf(f32) },
    };
}

fn initSphericalView(radius: f32, local_position: Vec3, yaw: f32, pitch: f32) curved.SphericalView {
    const params = curvedParams(.spherical, radius);
    const target = lookTarget(local_position, yaw, pitch, @max(radius * 0.08, 0.35));
    const eye_chart = sphericalSceneChart(params, local_position);
    const target_chart = sphericalSceneChart(params, target);
    return curved.SphericalView.init(params, .stereographic, curvedClip(.spherical), eye_chart, target_chart) catch
        curved.SphericalView.init(params, .stereographic, curvedClip(.spherical), curved.vec3(0.0, 0.0, -0.1), curved.vec3(0.0, 0.0, 0.0)) catch unreachable;
}

fn initHyperbolicView(radius: f32, position: Vec3, yaw: f32, pitch: f32) curved.HyperView {
    const params = curvedParams(.hyperbolic, radius);
    const target = lookTarget(position, yaw, pitch, @max(radius * 0.08, 0.35));
    return curved.HyperView.init(params, .stereographic, curvedClip(.hyperbolic), curvedVec(position), curvedVec(target)) catch
        curved.HyperView.init(params, .stereographic, curvedClip(.hyperbolic), curved.vec3(0.0, 0.0, -0.1), curved.vec3(0.0, 0.0, 0.0)) catch unreachable;
}

fn lookTarget(position: Vec3, yaw: f32, pitch: f32, distance: f32) Vec3 {
    const cos_pitch = @cos(pitch);
    return position.add(.{
        .x = -@sin(yaw) * cos_pitch * distance,
        .y = @sin(pitch) * distance,
        .z = @cos(yaw) * cos_pitch * distance,
    });
}

fn sphericalSceneAmbient(params: curved.Params, local: Vec3) curved.AmbientFor(.spherical).Vector {
    // Keep meshes local and let the spherical ground-height embedding do the
    // visual warp, instead of pre-bending vertices in chart space.
    return curved.sphericalAmbientFromGroundHeightPoint(params, curvedVec(local));
}

fn sphericalSceneChart(params: curved.Params, local: Vec3) curved.Vec3 {
    return curved.chartCoordsTyped(.spherical, params, sphericalSceneAmbient(params, local));
}

fn curvedVec(point: Vec3) curved.Vec3 {
    return curved.vec3(point.x, point.y, point.z);
}

fn vecFromCurved(point: curved.Vec3) Vec3 {
    const coords = curved.vec3Coords(point);
    return .{ .x = coords[0], .y = coords[1], .z = coords[2] };
}

fn screenForRect(rect: rl.Rectangle, zoom: f32) curved.Screen {
    return .{
        .width = @as(usize, @intFromFloat(@max(@round(rect.width), 1.0))),
        .height = @as(usize, @intFromFloat(@max(@round(rect.height), 1.0))),
        .zoom = zoom,
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

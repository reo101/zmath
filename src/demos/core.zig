const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
const projection = zmath.render.projection;
const curved = zmath.geometry.constant_curvature;

const Euclid3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Euclid3.Instantiate(f32);

pub const DemoMode = enum { perspective, isometric, hyperbolic, spherical };
const EscapeState = enum { idle, esc, csi };
pub const MovementMode = enum { walk, fly };

pub const Command = enum {
    next_mode,
    toggle_animation,
    toggle_movement_mode,
    cycle_projection,
    more_curved,
    less_curved,
    quit,
    move_forward,
    move_backward,
    move_left,
    move_right,
    look_up,
    look_down,
    look_left,
    look_right,
};

pub const FrameInfo = struct {
    mode_label: []const u8,
    zoom: f32,
    hyper_radius: f32,
    spherical_radius: f32,
    projection_label: []const u8,
    movement_label: []const u8,
    animate: bool,

    pub fn writeStatusLine(self: FrameInfo, writer: anytype) !void {
        try writer.print(
            "{s} Z:{d:.2} C:{d:.2}/{d:.2} V:{s} M:{s} A:{s} SPC/P/G/V/WASD/Ar/+/-/Q\n",
            .{
                self.mode_label,
                self.zoom,
                self.hyper_radius,
                self.spherical_radius,
                self.projection_label,
                self.movement_label,
                if (self.animate) "on" else "off",
            },
        );
    }
};

const near_clip_z: f32 = 1.2;
const far_clip_z: f32 = 44.0;
const euclidean_cube_scale: f32 = 4.0;
const hyperbolic_prism_chart_radius: f32 = 0.24;
const hyperbolic_prism_half_depth: f32 = 0.13;
const spherical_chart_scale: f32 = 0.52;
const animation_step: f32 = 0.05;
const default_hyperbolic_params = curved.Params{
    .radius = 0.32,
    .angular_zoom = 0.72,
    .chart_model = .conformal,
};
const default_spherical_params = curved.Params{
    .radius = 1.48,
    .angular_zoom = 1.0,
    .chart_model = .conformal,
};
const hyperbolic_radius_min: f32 = default_hyperbolic_params.radius * 0.55;
const hyperbolic_radius_max: f32 = default_hyperbolic_params.radius * 2.20;
const spherical_radius_min: f32 = default_spherical_params.radius * 0.50;
const spherical_radius_max: f32 = default_spherical_params.radius * 2.20;
const hyperbolic_near_distance: f32 = 0.08;
const hyperbolic_far_distance: f32 = 1.55;
const spherical_near_distance: f32 = 0.08;
const spherical_far_distance: f32 = std.math.inf(f32);
const face_fill_steps: usize = 12;
const cube_faces = [_][4]usize{
    .{ 0, 2, 3, 1 },
    .{ 4, 5, 7, 6 },
    .{ 0, 1, 5, 4 },
    .{ 2, 6, 7, 3 },
    .{ 0, 4, 6, 2 },
    .{ 1, 3, 7, 5 },
};
const cube_edges = [_][2]usize{
    .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
    .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 },
    .{ 2, 6 }, .{ 3, 7 }, .{ 4, 5 },
    .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
};
const hyperbolic_prism_side_faces = [_][4]usize{
    .{ 0, 1, 6, 5 },
    .{ 1, 2, 7, 6 },
    .{ 2, 3, 8, 7 },
    .{ 3, 4, 9, 8 },
    .{ 4, 0, 5, 9 },
};
const hyperbolic_prism_edges = [_][2]usize{
    .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 0 },
    .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 9 }, .{ 9, 5 },
    .{ 0, 5 }, .{ 1, 6 }, .{ 2, 7 }, .{ 3, 8 }, .{ 4, 9 },
};
const cube_face_colors = [_]u8{
    203, // warm front
    81, // cool back
    220, // top
    121, // bottom
    147, // left
    45, // right
};
const unit_cube_vertices = [_]h.Vector{
    h.exprAs(h.Vector, "e1 + e2 + e3", .{}),
    h.exprAs(h.Vector, "e1 + e2 - e3", .{}),
    h.exprAs(h.Vector, "e1 - e2 + e3", .{}),
    h.exprAs(h.Vector, "e1 - e2 - e3", .{}),
    h.exprAs(h.Vector, "-e1 + e2 + e3", .{}),
    h.exprAs(h.Vector, "-e1 + e2 - e3", .{}),
    h.exprAs(h.Vector, "-e1 - e2 + e3", .{}),
    h.exprAs(h.Vector, "-e1 - e2 - e3", .{}),
};
const perspective_rotor_generator_expr = h.compileExpr("{xy}*e12 + {yz}*e23 + {xz}*e13");
const isometric_rotor_generator_expr = h.compileExpr("{xz}*e13 + {xy}*e12");
const hyperbolic_rotor_generator_expr = h.compileExpr("{xz}*e13 + {yz}*e23");

const CameraState = struct {
    euclid_rotation: f32 = 0.0,
    euclid_pitch: f32 = 0.18,
    euclid_eye_x: f32 = 0.0,
    euclid_eye_y: f32 = 0.0,
    euclid_eye_z: f32 = -10.5,
    movement_mode: MovementMode,
    hyper: curved.View,
    spherical: curved.View,

    fn init() !CameraState {
        return .{
            .movement_mode = .walk,
            .hyper = try curved.View.init(
                .hyperbolic,
                default_hyperbolic_params,
                .gnomonic,
                .{ .near = hyperbolic_near_distance, .far = hyperbolic_far_distance },
                .{ 0.0, 0.0, -default_hyperbolic_params.radius * 0.78 },
                .{ 0.0, 0.0, 0.0 },
            ),
            .spherical = try curved.View.init(
                .spherical,
                default_spherical_params,
                .wrapped,
                .{ .near = spherical_near_distance, .far = spherical_far_distance },
                .{ 0.0, 0.0, -0.82 },
                .{ 0.0, 0.0, 0.0 },
            ),
        };
    }

    fn euclidEyeVector(self: CameraState) h.Vector {
        return h.Vector.init(.{ self.euclid_eye_x, self.euclid_eye_y, self.euclid_eye_z });
    }
};

pub const App = struct {
    angle: f32 = 0.0,
    animate: bool = true,
    mode: DemoMode = .perspective,
    camera: CameraState,
    escape_state: EscapeState = .idle,

    pub fn init() !App {
        return .{ .camera = try CameraState.init() };
    }

    pub fn tick(self: *App) void {
        if (!self.animate) return;

        self.angle += animation_step;
        if (self.mode == .spherical) {
            animateSphericalCamera(&self.camera, self.angle, animation_step);
        }
    }

    pub fn applyCommand(self: *App, command: Command) bool {
        switch (command) {
            .next_mode => self.mode = nextMode(self.mode),
            .toggle_animation => self.animate = !self.animate,
            .toggle_movement_mode => {
                self.camera.movement_mode = if (self.camera.movement_mode == .walk) .fly else .walk;
                if (self.camera.movement_mode == .walk) syncWalkOrientation(&self.camera);
            },
            .cycle_projection => cycleDirectionProjection(&self.camera, self.mode),
            .more_curved => adjustCurvature(&self.camera, self.mode, true),
            .less_curved => adjustCurvature(&self.camera, self.mode, false),
            .move_forward => adjustCameraTranslation(&self.camera, 'w'),
            .move_backward => adjustCameraTranslation(&self.camera, 's'),
            .move_left => adjustCameraTranslation(&self.camera, 'a'),
            .move_right => adjustCameraTranslation(&self.camera, 'd'),
            .look_up => adjustCameraArrow(&self.camera, 'A'),
            .look_down => adjustCameraArrow(&self.camera, 'B'),
            .look_right => adjustCameraArrow(&self.camera, 'C'),
            .look_left => adjustCameraArrow(&self.camera, 'D'),
            .quit => return true,
        }

        return false;
    }

    pub fn handleTerminalByte(self: *App, byte: u8) bool {
        switch (self.escape_state) {
            .idle => switch (byte) {
                0x1b => {
                    self.escape_state = .esc;
                    return false;
                },
                ' ' => return self.applyCommand(.next_mode),
                'p' => return self.applyCommand(.toggle_animation),
                'g' => return self.applyCommand(.toggle_movement_mode),
                'v' => return self.applyCommand(.cycle_projection),
                '+', '=' => return self.applyCommand(.more_curved),
                '-', '_' => return self.applyCommand(.less_curved),
                'q' => return self.applyCommand(.quit),
                'w' => return self.applyCommand(.move_forward),
                'a' => return self.applyCommand(.move_left),
                's' => return self.applyCommand(.move_backward),
                'd' => return self.applyCommand(.move_right),
                else => return false,
            },
            .esc => {
                self.escape_state = if (byte == '[') .csi else .idle;
                return false;
            },
            .csi => {
                self.escape_state = .idle;
                return switch (byte) {
                    'A' => self.applyCommand(.look_up),
                    'B' => self.applyCommand(.look_down),
                    'C' => self.applyCommand(.look_right),
                    'D' => self.applyCommand(.look_left),
                    else => false,
                };
            },
        }
    }

    pub fn processTerminalBytes(self: *App, bytes: []const u8) bool {
        for (bytes) |byte| {
            if (self.handleTerminalByte(byte)) return true;
        }
        return false;
    }

    pub fn render(self: *App, canvas: *canvas_api.Canvas, width: usize, height: usize) FrameInfo {
        canvas.clear();

        const rotor = sceneRotor(self.angle, self.mode);
        const zoom = modeZoom(self.angle, self.mode, self.camera);

        switch (self.mode) {
            .perspective, .isometric => {
                const projection_mode: projection.EuclideanProjection = if (self.mode == .perspective) .perspective else .isometric;
                const world_cube_vertices = rotatedScaledCubeVertices(euclidean_cube_scale, rotor);
                var view_cube_vertices: [unit_cube_vertices.len]h.Vector = undefined;
                for (world_cube_vertices, 0..) |vertex, i| {
                    view_cube_vertices[i] = cameraSpace(vertex, self.camera);
                }

                shadeEuclideanCube(canvas, view_cube_vertices, projection_mode, width, height, zoom);

                for (cube_edges) |edge| {
                    const view_v0 = view_cube_vertices[edge[0]];
                    const view_v1 = view_cube_vertices[edge[1]];
                    const clipped = clipSegmentToDepthRange(view_v0, view_v1, near_clip_z, far_clip_z) orelse continue;

                    var prev_p: ?[2]f32 = null;
                    var prev_depth: ?f32 = null;
                    for (0..51) |i| {
                        const t = @as(f32, @floatFromInt(i)) / 50.0;
                        const vt = clipped.points[0].scale(1.0 - t).add(clipped.points[1].scale(t));
                        const depth = vt.coeffNamed("e3");
                        const pt = projection.projectEuclidean(vt, width, height, zoom, projection_mode);
                        if (pt) |p| {
                            if (prev_p) |pp| {
                                if (prev_depth) |pd| {
                                    const avg_depth = (pd + depth) * 0.5;
                                    const t_depth = std.math.clamp((avg_depth - near_clip_z) / @max(far_clip_z - near_clip_z, 1e-3), 0.0, 1.0);
                                    const tone = @as(u8, @intFromFloat(@round(255.0 + (243.0 - 255.0) * t_depth)));
                                    canvas.drawLine(pp[0], pp[1], p[0], p[1], '#', tone);
                                }
                            }
                            prev_p = p;
                            prev_depth = depth;
                        } else {
                            prev_p = null;
                            prev_depth = null;
                        }
                    }

                    if (clipped.start_marker != .none) {
                        if (projection.projectEuclidean(clipped.points[0], width, height, zoom, projection_mode)) |p| {
                            canvas.setMarker(p[0], p[1], clipped.start_marker);
                        }
                    }
                    if (clipped.end_marker != .none) {
                        if (projection.projectEuclidean(clipped.points[1], width, height, zoom, projection_mode)) |p| {
                            canvas.setMarker(p[0], p[1], clipped.end_marker);
                        }
                    }
                }
            },
            .hyperbolic => {
                const chart_prism_vertices = hyperbolicPrismVertices(rotor);
                const screen = curvedScreen(width, height, zoom);
                shadeCurvedQuads(canvas, chart_prism_vertices[0..], hyperbolic_prism_side_faces[0..], self.camera.hyper, screen);
                drawCurvedEdges(canvas, chart_prism_vertices[0..], hyperbolic_prism_edges[0..], self.camera.hyper, screen);
            },
            .spherical => {
                const chart_cube_vertices = rotatedScaledCubeVertices(spherical_chart_scale, rotor);
                const screen = curvedScreen(width, height, zoom);
                shadeCurvedQuads(canvas, chart_cube_vertices[0..], cube_faces[0..], self.camera.spherical, screen);
                drawCurvedEdges(canvas, chart_cube_vertices[0..], cube_edges[0..], self.camera.spherical, screen);
            },
        }

        return .{
            .mode_label = projectionModeLabel(self.mode),
            .zoom = zoom,
            .hyper_radius = self.camera.hyper.params.radius,
            .spherical_radius = self.camera.spherical.params.radius,
            .projection_label = currentCurvedProjectionLabel(self.mode, self.camera),
            .movement_label = movementModeLabel(self.camera.movement_mode),
            .animate = self.animate,
        };
    }
};

fn gaCross(a: h.Vector, b: h.Vector) h.Vector {
    return a.wedge(b).dual().negate();
}

fn safeNormalize(v: h.Vector, fallback: h.Vector) h.Vector {
    return h.normalize(v) catch fallback;
}

fn forwardFromAngles(rotation: f32, pitch: f32) h.Vector {
    const cos_pitch = @cos(pitch);
    return h.Vector.init(.{
        @sin(rotation) * cos_pitch,
        @sin(pitch),
        @cos(rotation) * cos_pitch,
    });
}

fn orientedCameraSpace(v: h.Vector, eye: h.Vector, rotation: f32, pitch: f32) h.Vector {
    const forward = forwardFromAngles(rotation, pitch);
    var right = gaCross(h.Vector.init(.{ 0, 1, 0 }), forward);
    if (right.scalarProduct(right) <= 1e-6) right = h.Vector.init(.{ 1, 0, 0 });
    right = safeNormalize(right, h.Vector.init(.{ 1, 0, 0 }));

    const up = safeNormalize(gaCross(forward, right), h.Vector.init(.{ 0, 1, 0 }));
    const rel = v.sub(eye);

    return h.Vector.init(.{
        rel.scalarProduct(right),
        rel.scalarProduct(up),
        rel.scalarProduct(forward),
    });
}

fn cameraSpace(v: h.Vector, camera: CameraState) h.Vector {
    return orientedCameraSpace(v, camera.euclidEyeVector(), camera.euclid_rotation, camera.euclid_pitch);
}

fn vec3FromVector(v: h.Vector) curved.Vec3 {
    return .{
        v.coeffNamed("e1"),
        v.coeffNamed("e2"),
        v.coeffNamed("e3"),
    };
}

fn bilerpQuad(a: h.Vector, b: h.Vector, c: h.Vector, d: h.Vector, u: f32, v: f32) h.Vector {
    const ab = a.scale(1.0 - u).add(b.scale(u));
    const dc = d.scale(1.0 - u).add(c.scale(u));
    return ab.scale(1.0 - v).add(dc.scale(v));
}

fn faceShade(normal: h.Vector) u8 {
    const light = safeNormalize(h.Vector.init(.{ 0.45, 0.75, -0.48 }), h.Vector.init(.{ 0, 1, 0 }));
    const unit_normal = safeNormalize(normal, h.Vector.init(.{ 0, 0, -1 }));
    const brightness = std.math.clamp(unit_normal.scalarProduct(light), 0.0, 1.0);
    return 1 + @as(u8, @intFromFloat(brightness * 3.999));
}

fn faceColor(face_index: usize) u8 {
    return cube_face_colors[face_index % cube_face_colors.len];
}

fn shadeEuclideanCube(
    canvas: *canvas_api.Canvas,
    view_vertices: [8]h.Vector,
    projection_mode: projection.EuclideanProjection,
    width: usize,
    height: usize,
    zoom: f32,
) void {
    for (cube_faces, 0..) |face, face_index| {
        const a = view_vertices[face[0]];
        const b = view_vertices[face[1]];
        const c = view_vertices[face[2]];
        const d = view_vertices[face[3]];
        const normal = gaCross(b.sub(a), d.sub(a));
        if (normal.coeffNamed("e3") >= -0.02) continue;

        const shade = faceShade(normal);
        const tone = faceColor(face_index);
        for (0..face_fill_steps + 1) |ui| {
            const u = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(face_fill_steps));
            for (0..face_fill_steps + 1) |vi| {
                const v = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(face_fill_steps));
                const point = bilerpQuad(a, b, c, d, u, v);
                const depth = point.coeffNamed("e3");
                if (depth < near_clip_z or depth > far_clip_z) continue;

                const projected = projection.projectEuclidean(point, width, height, zoom, projection_mode) orelse continue;
                canvas.setFill(projected[0], projected[1], shade, tone, depth);
            }
        }
    }
}

fn shadeCurvedQuads(
    canvas: *canvas_api.Canvas,
    chart_vertices: []const h.Vector,
    faces: []const [4]usize,
    view: curved.View,
    screen: curved.Screen,
) void {
    for (faces, 0..) |face, face_index| {
        const a = chart_vertices[face[0]];
        const b = chart_vertices[face[1]];
        const c = chart_vertices[face[2]];
        const d = chart_vertices[face[3]];
        const shade = faceShade(gaCross(b.sub(a), d.sub(a)));
        const tone = faceColor(face_index);
        view.fillQuad(
            canvas,
            .{
                vec3FromVector(a),
                vec3FromVector(b),
                vec3FromVector(c),
                vec3FromVector(d),
            },
            screen,
            .{ .steps = face_fill_steps, .shade = shade, .tone = tone },
        );
    }
}

fn rotorFromGenerator(B: anytype) h.Rotor {
    if (B.magnitude() <= 1e-6) return h.Rotor.init(.{ 1, 0, 0, 0 });

    const exp_rotor = B.scale(-0.5).exp();
    return zmath.ga.rotors.normalizedRotor(exp_rotor.castExact(h.Rotor));
}

fn sceneRotor(angle: f32, mode: DemoMode) h.Rotor {
    return switch (mode) {
        .perspective => rotorFromGenerator(perspective_rotor_generator_expr.evalAs(h.Bivector, .{
            .xy = @cos(angle * 0.3),
            .yz = @sin(angle * 0.5),
            .xz = @cos(angle * 0.7),
        })),
        .isometric => rotorFromGenerator(isometric_rotor_generator_expr.evalAs(h.Bivector, .{
            .xz = angle * 0.35,
            .xy = 0.18 * @sin(angle * 0.17),
        })),
        .hyperbolic => rotorFromGenerator(hyperbolic_rotor_generator_expr.evalAs(h.Bivector, .{
            .xz = angle * 0.22,
            .yz = -0.38 + 0.12 * @sin(angle * 0.17),
        })),
        .spherical => h.Rotor.init(.{ 1, 0, 0, 0 }),
    };
}

fn modeZoom(angle: f32, mode: DemoMode, camera: CameraState) f32 {
    return switch (mode) {
        .perspective => std.math.clamp(5.75 + 0.20 * @sin(angle * 0.10), 5.2, 6.1),
        .isometric => std.math.clamp(0.82 + 0.04 * @sin(angle * 0.12), 0.75, 0.92),
        .hyperbolic => std.math.clamp(camera.hyper.params.angular_zoom + 0.02 * @sin(angle * 0.11), 0.55, 1.15),
        .spherical => camera.spherical.params.angular_zoom,
    };
}

fn projectionModeLabel(mode: DemoMode) []const u8 {
    return switch (mode) {
        .perspective => "perspective (point)",
        .isometric => "isometric (plane)",
        .hyperbolic => "hyperbolic",
        .spherical => "spherical",
    };
}

fn movementModeLabel(mode: MovementMode) []const u8 {
    return switch (mode) {
        .walk => "walk",
        .fly => "fly",
    };
}

fn currentCurvedProjectionLabel(mode: DemoMode, camera: CameraState) []const u8 {
    return switch (mode) {
        .hyperbolic => projection.directionProjectionLabel(camera.hyper.projection),
        .spherical => projection.directionProjectionLabel(camera.spherical.projection),
        else => "-",
    };
}

const WalkDirections = struct {
    forward: curved.Vec4,
    right: curved.Vec4,
};

fn clampedWalkPitchDelta(view: curved.View, requested_delta: f32) f32 {
    const orientation = view.walkOrientation() orelse return 0.0;
    return std.math.clamp(orientation.pitch + requested_delta, -1.10, 1.10) - orientation.pitch;
}

fn curvedWalkDirections(view: curved.View) WalkDirections {
    const orientation = view.walkOrientation() orelse return .{
        .forward = view.camera.forward,
        .right = view.camera.right,
    };
    return .{
        .forward = view.headingDirection(orientation.x_heading, orientation.z_heading) orelse view.camera.forward,
        .right = view.headingDirection(orientation.z_heading, -orientation.x_heading) orelse view.camera.right,
    };
}

fn nextMode(mode: DemoMode) DemoMode {
    return switch (mode) {
        .perspective => .isometric,
        .isometric => .hyperbolic,
        .hyperbolic => .spherical,
        .spherical => .perspective,
    };
}

const DepthClipResult = struct {
    points: [2]h.Vector,
    start_marker: canvas_api.MarkerColor = .none,
    end_marker: canvas_api.MarkerColor = .none,
};

fn clipSegmentToDepthRange(v0: h.Vector, v1: h.Vector, near_z: f32, far_z: f32) ?DepthClipResult {
    var result = DepthClipResult{ .points = .{ v0, v1 } };

    var z0 = result.points[0].coeffNamed("e3");
    var z1 = result.points[1].coeffNamed("e3");
    const near_in0 = z0 >= near_z;
    const near_in1 = z1 >= near_z;
    if (!near_in0 and !near_in1) return null;
    if (near_in0 != near_in1) {
        const denom = z1 - z0;
        if (@abs(denom) <= 1e-6) return null;
        const t = (near_z - z0) / denom;
        const clipped = result.points[0].scale(1.0 - t).add(result.points[1].scale(t));
        if (!near_in0) {
            result.points[0] = clipped;
            result.start_marker = .near;
        } else {
            result.points[1] = clipped;
            result.end_marker = .near;
        }
    }

    z0 = result.points[0].coeffNamed("e3");
    z1 = result.points[1].coeffNamed("e3");
    const far_in0 = z0 <= far_z;
    const far_in1 = z1 <= far_z;
    if (!far_in0 and !far_in1) return null;
    if (far_in0 != far_in1) {
        const denom = z1 - z0;
        if (@abs(denom) <= 1e-6) return null;
        const t = (far_z - z0) / denom;
        const clipped = result.points[0].scale(1.0 - t).add(result.points[1].scale(t));
        if (!far_in0) {
            result.points[0] = clipped;
            result.start_marker = .far;
        } else {
            result.points[1] = clipped;
            result.end_marker = .far;
        }
    }

    return result;
}

fn nextDirectionProjection(current: projection.DirectionProjection) projection.DirectionProjection {
    return switch (current) {
        .wrapped => .gnomonic,
        .gnomonic => .stereographic,
        .stereographic => .orthographic,
        .orthographic => .wrapped,
    };
}

fn cycleDirectionProjection(camera: *CameraState, mode: DemoMode) void {
    switch (mode) {
        .hyperbolic => camera.hyper.projection = nextDirectionProjection(camera.hyper.projection),
        .spherical => camera.spherical.projection = nextDirectionProjection(camera.spherical.projection),
        else => {},
    }
}

fn syncWalkOrientation(camera: *CameraState) void {
    const x_heading = @sin(camera.euclid_rotation);
    const z_heading = @cos(camera.euclid_rotation);
    camera.hyper.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
    camera.spherical.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
}

fn adjustCameraArrow(camera: *CameraState, arrow: u8) void {
    const pitch_step: f32 = 0.10;
    const rotation_step: f32 = 0.14;

    switch (arrow) {
        'A' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch + pitch_step, -1.10, 1.10);
            if (camera.movement_mode == .walk) {
                const hyper_delta = clampedWalkPitchDelta(camera.hyper, pitch_step);
                const spherical_delta = clampedWalkPitchDelta(camera.spherical, pitch_step);
                camera.hyper.turnPitch(hyper_delta);
                camera.spherical.turnPitch(spherical_delta);
            } else {
                camera.hyper.turnPitch(pitch_step);
                camera.spherical.turnPitch(pitch_step);
            }
        },
        'B' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch - pitch_step, -1.10, 1.10);
            if (camera.movement_mode == .walk) {
                const hyper_delta = clampedWalkPitchDelta(camera.hyper, -pitch_step);
                const spherical_delta = clampedWalkPitchDelta(camera.spherical, -pitch_step);
                camera.hyper.turnPitch(hyper_delta);
                camera.spherical.turnPitch(spherical_delta);
            } else {
                camera.hyper.turnPitch(-pitch_step);
                camera.spherical.turnPitch(-pitch_step);
            }
        },
        'C' => {
            camera.euclid_rotation += rotation_step;
            if (camera.movement_mode == .walk) {
                camera.hyper.turnWalkYaw(rotation_step);
                camera.spherical.turnWalkYaw(rotation_step);
            } else {
                camera.hyper.turnYaw(rotation_step);
                camera.spherical.turnYaw(rotation_step);
            }
        },
        'D' => {
            camera.euclid_rotation -= rotation_step;
            if (camera.movement_mode == .walk) {
                camera.hyper.turnWalkYaw(-rotation_step);
                camera.spherical.turnWalkYaw(-rotation_step);
            } else {
                camera.hyper.turnYaw(-rotation_step);
                camera.spherical.turnYaw(-rotation_step);
            }
        },
        else => {},
    }
}

fn adjustCameraTranslation(camera: *CameraState, key: u8) void {
    const euclid_step: f32 = 0.90;
    const hyper_step: f32 = 0.08;
    const spherical_step: f32 = 0.10;

    const sin_rotation = @sin(camera.euclid_rotation);
    const cos_rotation = @cos(camera.euclid_rotation);
    const forward_x = sin_rotation;
    const forward_z = cos_rotation;
    const right_x = cos_rotation;
    const right_z = -sin_rotation;
    const hyper_walk = curvedWalkDirections(camera.hyper);
    const spherical_walk = curvedWalkDirections(camera.spherical);
    const hyper_forward = if (camera.movement_mode == .walk) hyper_walk.forward else camera.hyper.camera.forward;
    const hyper_right = if (camera.movement_mode == .walk) hyper_walk.right else camera.hyper.camera.right;
    const spherical_forward = if (camera.movement_mode == .walk) spherical_walk.forward else camera.spherical.camera.forward;
    const spherical_right = if (camera.movement_mode == .walk) spherical_walk.right else camera.spherical.camera.right;

    switch (key) {
        'a' => {
            camera.euclid_eye_x -= right_x * euclid_step;
            camera.euclid_eye_z -= right_z * euclid_step;
            camera.hyper.moveAlong(hyper_right, -hyper_step);
            camera.spherical.moveAlong(spherical_right, -spherical_step);
            camera.spherical.wrapSphericalChart();
        },
        'd' => {
            camera.euclid_eye_x += right_x * euclid_step;
            camera.euclid_eye_z += right_z * euclid_step;
            camera.hyper.moveAlong(hyper_right, hyper_step);
            camera.spherical.moveAlong(spherical_right, spherical_step);
            camera.spherical.wrapSphericalChart();
        },
        's' => {
            camera.euclid_eye_x -= forward_x * euclid_step;
            camera.euclid_eye_z -= forward_z * euclid_step;
            camera.hyper.moveAlong(hyper_forward, -hyper_step);
            camera.spherical.moveAlong(spherical_forward, -spherical_step);
            camera.spherical.wrapSphericalChart();
        },
        'w' => {
            camera.euclid_eye_x += forward_x * euclid_step;
            camera.euclid_eye_z += forward_z * euclid_step;
            camera.hyper.moveAlong(hyper_forward, hyper_step);
            camera.spherical.moveAlong(spherical_forward, spherical_step);
            camera.spherical.wrapSphericalChart();
        },
        else => {},
    }
}

fn animateSphericalCamera(camera: *CameraState, angle: f32, delta: f32) void {
    const yaw_delta = 0.19 * delta;
    camera.euclid_rotation += yaw_delta;
    if (camera.movement_mode == .walk) {
        camera.spherical.turnWalkYaw(yaw_delta);
    } else {
        camera.spherical.turnYaw(yaw_delta);
    }

    const radial_delta = 0.012 * @sin(angle * 0.37);
    if (@abs(radial_delta) <= 1e-4) return;

    const walk = curvedWalkDirections(camera.spherical);
    const forward = if (camera.movement_mode == .walk) walk.forward else camera.spherical.camera.forward;
    camera.spherical.moveAlong(forward, radial_delta);
    camera.spherical.wrapSphericalChart();
}

fn vec3Length(v: curved.Vec3) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

fn adjustCurvature(camera: *CameraState, mode: DemoMode, more_curved: bool) void {
    const tighten: f32 = 0.92;
    const loosen: f32 = 1.08;
    const scale = if (more_curved) tighten else loosen;

    switch (mode) {
        .hyperbolic => {
            const eye_chart = curved.chartCoords(.hyperbolic, camera.hyper.params, camera.hyper.camera.position);
            const eye_radius_floor = vec3Length(eye_chart) + 0.04;
            const lower = @max(hyperbolic_radius_min, eye_radius_floor);
            const upper = @max(lower, hyperbolic_radius_max);
            const next_radius = std.math.clamp(camera.hyper.params.radius * scale, lower, upper);
            camera.hyper.adjustRadius(next_radius, 0.18) catch {};
        },
        .spherical => {
            const next_radius = std.math.clamp(camera.spherical.params.radius * scale, spherical_radius_min, spherical_radius_max);
            camera.spherical.adjustRadius(next_radius, 0.18) catch {};
            camera.spherical.wrapSphericalChart();
        },
        else => {},
    }
}

fn curvedScreen(width: usize, height: usize, zoom: f32) curved.Screen {
    return .{
        .width = width,
        .height = height,
        .zoom = zoom,
    };
}

fn drawCurvedEdges(
    canvas: *canvas_api.Canvas,
    chart_vertices: []const h.Vector,
    edges: []const [2]usize,
    view: curved.View,
    screen: curved.Screen,
) void {
    for (edges) |edge| {
        view.drawEdge(
            canvas,
            vec3FromVector(chart_vertices[edge[0]]),
            vec3FromVector(chart_vertices[edge[1]]),
            screen,
            .{},
        );
    }
}

fn rotatedScaledCubeVertices(scale: f32, rotor: h.Rotor) [unit_cube_vertices.len]h.Vector {
    var vertices: [unit_cube_vertices.len]h.Vector = undefined;
    for (unit_cube_vertices, 0..) |vertex, i| {
        vertices[i] = zmath.ga.rotors.rotated(vertex.scale(scale), rotor);
    }
    return vertices;
}

fn hyperbolicPrismVertices(rotor: h.Rotor) [10]h.Vector {
    var vertices: [10]h.Vector = undefined;
    const tau = @as(f32, std.math.pi) * 2.0;
    const top_offset = h.Vector.init(.{ 0.0, 0.0, hyperbolic_prism_half_depth });
    const bottom_offset = h.Vector.init(.{ 0.0, 0.0, -hyperbolic_prism_half_depth });

    for (0..5) |i| {
        const theta = (tau * @as(f32, @floatFromInt(i)) / 5.0) + (@as(f32, std.math.pi) / 10.0);
        const ring = h.Vector.init(.{
            @cos(theta) * hyperbolic_prism_chart_radius,
            @sin(theta) * hyperbolic_prism_chart_radius,
            0.0,
        });

        vertices[i] = zmath.ga.rotors.rotated(ring.add(top_offset), rotor);
        vertices[i + 5] = zmath.ga.rotors.rotated(ring.add(bottom_offset), rotor);
    }

    return vertices;
}

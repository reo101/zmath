const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
const curved_canvas_renderer = zmath.render.curved_canvas;
const curved_navigator_renderer = zmath.render.curved_navigator;
const projection = zmath.render.projection;
const curved = zmath.geometry.constant_curvature;

const Euclid3 = zmath.ga.Algebra(zmath.ga.euclideanSignature(3));
const h = Euclid3.Instantiate(f32);
pub const H = h;

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

const CurvatureTarget = enum { none, hyperbolic, spherical };
const CurvatureNotice = enum { idle, changed, min_clamp, max_clamp, unavailable, failed };

const CurvatureFeedback = struct {
    target: CurvatureTarget = .none,
    notice: CurvatureNotice = .idle,
    previous_radius: f32 = 0.0,
    current_radius: f32 = 0.0,

    fn noticeLabel(self: CurvatureFeedback) []const u8 {
        return switch (self.notice) {
            .idle => "-",
            .changed => "ok",
            .min_clamp => "min",
            .max_clamp => "max",
            .unavailable => "n/a",
            .failed => "err",
        };
    }
};

pub const FrameInfo = struct {
    mode_label: []const u8,
    zoom: f32,
    hyper_radius: f32,
    spherical_radius: f32,
    projection_label: []const u8,
    movement_label: []const u8,
    curvature_notice: []const u8,
    animate: bool,

    pub fn writeStatusLine(self: FrameInfo, writer: anytype) !void {
        try writer.print(
            "{s} Z:{d:.2} C[h/s]:{d:.2}/{d:.2} V:{s} M:{s} K:{s} A:{s} SPC/P/G/V/WASD/Ar/+/-/I/Q\n",
            .{
                self.mode_label,
                self.zoom,
                self.hyper_radius,
                self.spherical_radius,
                self.projection_label,
                self.movement_label,
                self.curvature_notice,
                if (self.animate) "on" else "off",
            },
        );
    }
};

pub const near_clip_z: f32 = 1.2;
pub const far_clip_z: f32 = 44.0;
pub const euclidean_cube_scale: f32 = 4.0;
const hyperbolic_prism_chart_radius: f32 = 0.26;
const hyperbolic_prism_half_depth: f32 = 0.14;
const spherical_local_cube_radius_fraction: f32 = 0.27027026;
const animation_step: f32 = 0.05;
const curvature_tighten_factor: f32 = 0.80;
const curvature_loosen_factor: f32 = 1.25;
const curvature_rebuild_look_ahead: f32 = 0.24;
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
const max_walk_pitch: f32 = 1.45;
const face_fill_steps: usize = 12;
const spherical_wrapped_face_fill_steps: usize = 48;
pub const cube_faces = [_][4]usize{
    .{ 0, 2, 3, 1 },
    .{ 4, 5, 7, 6 },
    .{ 0, 1, 5, 4 },
    .{ 2, 6, 7, 3 },
    .{ 0, 4, 6, 2 },
    .{ 1, 3, 7, 5 },
};
pub const cube_edges = [_][2]usize{
    .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
    .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 },
    .{ 2, 6 }, .{ 3, 7 }, .{ 4, 5 },
    .{ 4, 6 }, .{ 5, 7 }, .{ 6, 7 },
};
pub const hyperbolic_prism_side_faces = [_][4]usize{
    .{ 0, 1, 6, 5 },
    .{ 1, 2, 7, 6 },
    .{ 2, 3, 8, 7 },
    .{ 3, 4, 9, 8 },
    .{ 4, 0, 5, 9 },
};
pub const hyperbolic_prism_edges = [_][2]usize{
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

pub const CameraState = struct {
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
                curved.vec3(0.0, 0.0, -default_hyperbolic_params.radius * 0.78),
                curved.vec3(0.0, 0.0, 0.0),
            ),
            .spherical = try curved.View.init(
                .spherical,
                default_spherical_params,
                .stereographic,
                .{ .near = spherical_near_distance, .far = spherical_far_distance },
                curved.vec3(0.0, 0.0, -0.82),
                curved.vec3(0.0, 0.0, 0.0),
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
    curvature_feedback: CurvatureFeedback = .{},

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
        if (command != .more_curved and command != .less_curved) {
            self.curvature_feedback = .{};
        }

        switch (command) {
            .next_mode => {
                self.mode = nextMode(self.mode);
                if (self.camera.movement_mode == .walk and isCurvedMode(self.mode)) {
                    syncWalkOrientation(&self.camera);
                }
            },
            .toggle_animation => self.animate = !self.animate,
            .toggle_movement_mode => {
                self.camera.movement_mode = if (self.camera.movement_mode == .walk) .fly else .walk;
                if (self.camera.movement_mode == .walk) {
                    syncEuclidWalkOrientation(&self.camera, self.mode);
                    syncWalkOrientation(&self.camera);
                }
            },
            .cycle_projection => cycleDirectionProjection(&self.camera, self.mode),
            .more_curved => self.curvature_feedback = adjustCurvature(&self.camera, self.mode, true),
            .less_curved => self.curvature_feedback = adjustCurvature(&self.camera, self.mode, false),
            .move_forward => adjustCameraTranslation(&self.camera, self.mode, 'w'),
            .move_backward => adjustCameraTranslation(&self.camera, self.mode, 's'),
            .move_left => adjustCameraTranslation(&self.camera, self.mode, 'a'),
            .move_right => adjustCameraTranslation(&self.camera, self.mode, 'd'),
            .look_up => adjustCameraArrow(&self.camera, self.mode, 'A'),
            .look_down => adjustCameraArrow(&self.camera, self.mode, 'B'),
            .look_right => adjustCameraArrow(&self.camera, self.mode, 'C'),
            .look_left => adjustCameraArrow(&self.camera, self.mode, 'D'),
            .quit => return true,
        }

        return false;
    }

    pub fn dumpDebugState(self: App) void {
        std.debug.print(
            \\=== zmath-demo-state ===
            \\mode={s} angle={d:.6} animate={} movement={s}
            \\euclid.rotation={d:.6}
            \\euclid.pitch={d:.6}
            \\euclid.eye=.{{ {d:.6}, {d:.6}, {d:.6} }}
            \\
        ,
            .{
                @tagName(self.mode),
                self.angle,
                self.animate,
                @tagName(self.camera.movement_mode),
                self.camera.euclid_rotation,
                self.camera.euclid_pitch,
                self.camera.euclid_eye_x,
                self.camera.euclid_eye_y,
                self.camera.euclid_eye_z,
            },
        );

        switch (self.mode) {
            .hyperbolic => dumpCurvedViewState("hyper", self.camera.hyper),
            .spherical => dumpCurvedViewState("spherical", self.camera.spherical),
            else => {},
        }
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
                'i' => {
                    self.dumpDebugState();
                    return false;
                },
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
                const chart_vertices = vec3ArrayFromVectors(chart_prism_vertices.len, chart_prism_vertices);
                const mesh = curved_canvas_renderer.Mesh{
                    .vertices = chart_vertices[0..],
                    .faces = hyperbolic_prism_side_faces[0..],
                    .edges = hyperbolic_prism_edges[0..],
                };
                curved_canvas_renderer.drawMesh(canvas, mesh, self.camera.hyper, screen, .{
                    .face_fill_steps = face_fill_steps,
                    .wrapped_face_fill_steps = spherical_wrapped_face_fill_steps,
                    .face_tones = cube_face_colors[0..],
                });
                curved_navigator_renderer.drawCurvedNavigator(canvas, mesh, self.camera.hyper, width, height);
            },
            .spherical => {
                const chart_cube_vertices = sphericalCubeChartVertices(
                    sphericalLocalCubeVertices(sphericalLocalCubeScale(self.camera.spherical.params.radius), rotor),
                    self.camera.spherical.params,
                );
                const screen = curvedScreen(width, height, zoom);
                const chart_vertices = vec3ArrayFromVectors(chart_cube_vertices.len, chart_cube_vertices);
                const mesh = curved_canvas_renderer.Mesh{
                    .vertices = chart_vertices[0..],
                    .faces = cube_faces[0..],
                    .edges = cube_edges[0..],
                };
                curved_canvas_renderer.drawMesh(canvas, mesh, self.camera.spherical, screen, .{
                    .face_fill_steps = face_fill_steps,
                    .wrapped_face_fill_steps = spherical_wrapped_face_fill_steps,
                    .face_tones = cube_face_colors[0..],
                });
                curved_navigator_renderer.drawCurvedNavigator(canvas, mesh, self.camera.spherical, width, height);
            },
        }

        return self.frameInfoWithZoom(zoom);
    }

    pub fn frameInfo(self: App) FrameInfo {
        return self.frameInfoWithZoom(modeZoom(self.angle, self.mode, self.camera));
    }

    fn frameInfoWithZoom(self: App, zoom: f32) FrameInfo {
        return .{
            .mode_label = projectionModeLabel(self.mode),
            .zoom = zoom,
            .hyper_radius = self.camera.hyper.params.radius,
            .spherical_radius = self.camera.spherical.params.radius,
            .projection_label = currentCurvedProjectionLabel(self.mode, self.camera),
            .movement_label = movementModeLabel(self.camera.movement_mode),
            .curvature_notice = self.curvature_feedback.noticeLabel(),
            .animate = self.animate,
        };
    }

    pub fn euclideanScene(self: App) ?EuclideanScene {
        const projection_mode: projection.EuclideanProjection = switch (self.mode) {
            .perspective => .perspective,
            .isometric => .isometric,
            else => return null,
        };

        const rotor = sceneRotor(self.angle, self.mode);
        const basis = euclideanCameraBasis(self.camera);
        const world_cube_vertices = rotatedScaledCubeVertices(euclidean_cube_scale, rotor);
        var view_cube_vertices: [unit_cube_vertices.len]h.Vector = undefined;
        for (world_cube_vertices, 0..) |vertex, i| {
            view_cube_vertices[i] = cameraSpace(vertex, self.camera);
        }

        return .{
            .projection_mode = projection_mode,
            .zoom = modeZoom(self.angle, self.mode, self.camera),
            .view_cube_vertices = view_cube_vertices,
            .eye = basis.eye,
            .right = basis.right,
            .up = basis.up,
            .forward = basis.forward,
            .cube_rotor = rotor,
            .cube_scale = euclidean_cube_scale,
        };
    }
};

pub const EuclideanScene = struct {
    projection_mode: projection.EuclideanProjection,
    zoom: f32,
    view_cube_vertices: [unit_cube_vertices.len]h.Vector,
    eye: h.Vector,
    right: h.Vector,
    up: h.Vector,
    forward: h.Vector,
    cube_rotor: h.Rotor,
    cube_scale: f32,
};

pub const HyperbolicScene = struct {
    view: curved.View,
    screen: curved.Screen,
    chart_vertices: [10]h.Vector,
};

pub const SphericalScene = struct {
    view: curved.View,
    screen: curved.Screen,
    local_vertices: [unit_cube_vertices.len]h.Vector,
    chart_vertices: [unit_cube_vertices.len]h.Vector,
};

pub const CurvedScene = union(enum) {
    hyperbolic: HyperbolicScene,
    spherical: SphericalScene,
};

pub fn curvedScene(self: App, width: usize, height: usize) ?CurvedScene {
    const rotor = sceneRotor(self.angle, self.mode);
    const screen = curvedScreen(width, height, modeZoom(self.angle, self.mode, self.camera));

    return switch (self.mode) {
        .hyperbolic => .{
            .hyperbolic = .{
                .view = self.camera.hyper,
                .screen = screen,
                .chart_vertices = hyperbolicPrismVertices(rotor),
            },
        },
        .spherical => spherical_scene: {
            const local_vertices = sphericalLocalCubeVertices(sphericalLocalCubeScale(self.camera.spherical.params.radius), rotor);
            break :spherical_scene .{
                .spherical = .{
                    .view = self.camera.spherical,
                    .screen = screen,
                    .local_vertices = local_vertices,
                    .chart_vertices = sphericalCubeChartVertices(local_vertices, self.camera.spherical.params),
                },
            };
        },
        else => null,
    };
}

fn gaCross(a: h.Vector, b: h.Vector) h.Vector {
    return a.wedge(b).dual().negate();
}

fn debugPrintVec3(name: []const u8, v: curved.Vec3) void {
    const coords = curved.vec3Coords(v);
    std.debug.print("{s}=.{{ {d:.6}, {d:.6}, {d:.6} }}\n", .{ name, coords[0], coords[1], coords[2] });
}

fn debugPrintVec4(name: []const u8, v: curved.Vec4) void {
    std.debug.print("{s}=.{{ {d:.6}, {d:.6}, {d:.6}, {d:.6} }}\n", .{ name, v[0], v[1], v[2], v[3] });
}

fn dumpCurvedViewState(label: []const u8, view: curved.View) void {
    const eye_chart = curved.chartCoords(view.metric, view.params, view.camera.position);
    var look_probe = view.camera;
    curved.moveForward(&look_probe, view.metric, view.params, @min(view.params.radius * 0.18, 0.18));
    const look_chart = curved.chartCoords(view.metric, view.params, look_probe.position);

    std.debug.print(
        \\{s}.metric={s}
        \\{s}.projection={s}
        \\{s}.chart_model={s}
        \\{s}.scene_sign={d:.1}
        \\{s}.clip=.{{ .near = {d:.6}, .far = {d:.6} }}
        \\{s}.params=.{{ .radius = {d:.6}, .angular_zoom = {d:.6} }}
        \\
    ,
        .{
            label,
            @tagName(view.metric),
            label,
            @tagName(view.projection),
            label,
            @tagName(view.params.chart_model),
            label,
            view.scene_sign,
            label,
            view.clip.near,
            view.clip.far,
            label,
            view.params.radius,
            view.params.angular_zoom,
        },
    );
    debugPrintVec3("eye_chart", eye_chart);
    debugPrintVec3("look_chart", look_chart);
    debugPrintVec4("camera.position", view.camera.position);
    debugPrintVec4("camera.right", view.camera.right);
    debugPrintVec4("camera.up", view.camera.up);
    debugPrintVec4("camera.forward", view.camera.forward);

    if (view.walkOrientation()) |walk| {
        std.debug.print(
            "{s}.walk=.{{ .x_heading = {d:.6}, .z_heading = {d:.6}, .pitch = {d:.6} }}\n",
            .{ label, walk.x_heading, walk.z_heading, walk.pitch },
        );
    } else {
        std.debug.print("{s}.walk=null\n", .{label});
    }
    std.debug.print("=== end-state ===\n", .{});
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

pub const EuclideanCameraBasis = struct {
    eye: h.Vector,
    right: h.Vector,
    up: h.Vector,
    forward: h.Vector,
};

fn euclideanCameraBasisFromAngles(eye: h.Vector, rotation: f32, pitch: f32) EuclideanCameraBasis {
    const forward = forwardFromAngles(rotation, pitch);
    var right = gaCross(h.Vector.init(.{ 0, 1, 0 }), forward);
    if (right.scalarProduct(right) <= 1e-6) right = h.Vector.init(.{ 1, 0, 0 });
    right = safeNormalize(right, h.Vector.init(.{ 1, 0, 0 }));
    const up = safeNormalize(gaCross(forward, right), h.Vector.init(.{ 0, 1, 0 }));
    return .{
        .eye = eye,
        .right = right,
        .up = up,
        .forward = forward,
    };
}

fn orientedCameraSpace(v: h.Vector, eye: h.Vector, rotation: f32, pitch: f32) h.Vector {
    const basis = euclideanCameraBasisFromAngles(eye, rotation, pitch);
    const rel = v.sub(eye);

    return h.Vector.init(.{
        rel.scalarProduct(basis.right),
        rel.scalarProduct(basis.up),
        rel.scalarProduct(basis.forward),
    });
}

fn cameraSpace(v: h.Vector, camera: CameraState) h.Vector {
    return orientedCameraSpace(v, camera.euclidEyeVector(), camera.euclid_rotation, camera.euclid_pitch);
}

pub fn euclideanCameraBasis(camera: CameraState) EuclideanCameraBasis {
    return euclideanCameraBasisFromAngles(camera.euclidEyeVector(), camera.euclid_rotation, camera.euclid_pitch);
}

fn vec3FromVector(v: h.Vector) curved.Vec3 {
    return curved.vec3(v.coeffNamed("e1"), v.coeffNamed("e2"), v.coeffNamed("e3"));
}

fn vectorFromVec3(v: curved.Vec3) h.Vector {
    return h.Vector.init(curved.vec3Coords(v));
}

fn vec3ArrayFromVectors(comptime N: usize, vertices: [N]h.Vector) [N]curved.Vec3 {
    var converted: [N]curved.Vec3 = undefined;
    for (vertices, 0..) |vertex, i| {
        converted[i] = vec3FromVector(vertex);
    }
    return converted;
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

pub fn faceTone(face_index: usize) u8 {
    return faceColor(face_index);
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
        .spherical => camera.spherical.params.angular_zoom * switch (camera.spherical.projection) {
            .gnomonic => @as(f32, 0.52),
            .stereographic => @as(f32, 1.0),
            .orthographic => @as(f32, 0.85),
            .wrapped => @as(f32, 1.0),
        },
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
        .spherical => switch (camera.spherical.projection) {
            .stereographic => "stereo2",
            else => projection.directionProjectionLabel(camera.spherical.projection),
        },
        else => "-",
    };
}

const WalkDirections = struct {
    forward: curved.Vec4,
    right: curved.Vec4,
};

fn curvedWalkDirections(view: curved.View, x_heading: f32, z_heading: f32, pitch_angle: f32) WalkDirections {
    if (view.metric == .spherical) {
        if (view.walkSurfaceBasis(pitch_angle)) |basis| {
            return .{
                .forward = basis.forward,
                .right = basis.right,
            };
        }
    }
    return .{
        .forward = view.headingDirection(x_heading, z_heading) orelse view.camera.forward,
        .right = view.headingDirection(z_heading, -x_heading) orelse view.camera.right,
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

fn isCurvedMode(mode: DemoMode) bool {
    return mode == .hyperbolic or mode == .spherical;
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

fn syncHyperWalkOrientation(camera: *CameraState) void {
    const x_heading = @sin(camera.euclid_rotation);
    const z_heading = @cos(camera.euclid_rotation);
    camera.hyper.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
}

fn wrapAngleNear(angle: f32, reference: f32) f32 {
    const tau = @as(f32, std.math.pi) * 2.0;
    return angle + tau * @round((reference - angle) / tau);
}

const ViewAngleState = struct {
    rotation: f32,
    pitch: f32,
};

fn chooseSphericalAngleState(current_rotation: f32, current_pitch: f32, candidate: ViewAngleState) ViewAngleState {
    const direct = ViewAngleState{
        .rotation = wrapAngleNear(candidate.rotation, current_rotation),
        .pitch = std.math.clamp(candidate.pitch, -max_walk_pitch, max_walk_pitch),
    };
    const antipodal = ViewAngleState{
        .rotation = wrapAngleNear(candidate.rotation + @as(f32, std.math.pi), current_rotation),
        .pitch = std.math.clamp(-candidate.pitch, -max_walk_pitch, max_walk_pitch),
    };

    const direct_error = @abs(direct.rotation - current_rotation) + @abs(direct.pitch - current_pitch);
    const antipodal_error = @abs(antipodal.rotation - current_rotation) + @abs(antipodal.pitch - current_pitch);
    return if (direct_error <= antipodal_error) direct else antipodal;
}

fn syncEuclidFromView(camera: *CameraState, view: curved.View) void {
    const orientation = view.walkOrientation() orelse return;
    const candidate = ViewAngleState{
        .rotation = std.math.atan2(orientation.x_heading, orientation.z_heading),
        .pitch = orientation.pitch,
    };
    const chosen = if (view.metric == .spherical)
        chooseSphericalAngleState(camera.euclid_rotation, camera.euclid_pitch, candidate)
    else
        ViewAngleState{
            .rotation = wrapAngleNear(candidate.rotation, camera.euclid_rotation),
            .pitch = std.math.clamp(candidate.pitch, -max_walk_pitch, max_walk_pitch),
        };
    camera.euclid_rotation = chosen.rotation;
    camera.euclid_pitch = chosen.pitch;
}

fn syncEuclidWalkOrientation(camera: *CameraState, mode: DemoMode) void {
    switch (mode) {
        .hyperbolic => syncEuclidFromView(camera, camera.hyper),
        .spherical => syncEuclidFromView(camera, camera.spherical),
        else => {},
    }
}

fn adjustCameraArrow(camera: *CameraState, _: DemoMode, arrow: u8) void {
    const pitch_step: f32 = 0.10;
    const rotation_step: f32 = 0.14;

    if (camera.movement_mode == .walk) {
        syncHyperWalkOrientation(camera);
    }

    switch (arrow) {
        'A' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch + pitch_step, -max_walk_pitch, max_walk_pitch);
            if (camera.movement_mode == .walk) {
                camera.hyper.syncHeadingPitch(
                    @sin(camera.euclid_rotation),
                    @cos(camera.euclid_rotation),
                    camera.euclid_pitch,
                );
                camera.spherical.syncSurfacePitch(camera.euclid_pitch);
            } else {
                camera.hyper.turnPitch(pitch_step);
                camera.spherical.turnPitch(pitch_step);
            }
        },
        'B' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch - pitch_step, -max_walk_pitch, max_walk_pitch);
            if (camera.movement_mode == .walk) {
                camera.hyper.syncHeadingPitch(
                    @sin(camera.euclid_rotation),
                    @cos(camera.euclid_rotation),
                    camera.euclid_pitch,
                );
                camera.spherical.syncSurfacePitch(camera.euclid_pitch);
            } else {
                camera.hyper.turnPitch(-pitch_step);
                camera.spherical.turnPitch(-pitch_step);
            }
        },
        'C' => {
            camera.euclid_rotation += rotation_step;
            if (camera.movement_mode == .walk) {
                camera.hyper.syncHeadingPitch(
                    @sin(camera.euclid_rotation),
                    @cos(camera.euclid_rotation),
                    camera.euclid_pitch,
                );
                camera.spherical.turnSurfaceYaw(rotation_step, camera.euclid_pitch);
            } else {
                camera.hyper.turnYaw(rotation_step);
                camera.spherical.turnYaw(rotation_step);
            }
        },
        'D' => {
            camera.euclid_rotation -= rotation_step;
            if (camera.movement_mode == .walk) {
                camera.hyper.syncHeadingPitch(
                    @sin(camera.euclid_rotation),
                    @cos(camera.euclid_rotation),
                    camera.euclid_pitch,
                );
                camera.spherical.turnSurfaceYaw(-rotation_step, camera.euclid_pitch);
            } else {
                camera.hyper.turnYaw(-rotation_step);
                camera.spherical.turnYaw(-rotation_step);
            }
        },
        else => {},
    }
}

fn adjustCameraTranslation(camera: *CameraState, _: DemoMode, key: u8) void {
    const euclid_step: f32 = 0.90;
    const hyper_step: f32 = 0.08;
    const spherical_step: f32 = 0.10;

    if (camera.movement_mode == .walk) {
        // Only sync the hyperbolic camera from euclid_rotation.
        // The spherical camera preserves its own basis via parallel transport.
        camera.hyper.syncHeadingPitch(
            @sin(camera.euclid_rotation),
            @cos(camera.euclid_rotation),
            camera.euclid_pitch,
        );
    }

    const sin_rotation = @sin(camera.euclid_rotation);
    const cos_rotation = @cos(camera.euclid_rotation);
    const forward_x = sin_rotation;
    const forward_z = cos_rotation;
    const right_x = cos_rotation;
    const right_z = -sin_rotation;
    const hyper_walk = curvedWalkDirections(camera.hyper, sin_rotation, cos_rotation, camera.euclid_pitch);
    const spherical_walk = curvedWalkDirections(camera.spherical, sin_rotation, cos_rotation, camera.euclid_pitch);
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
        },
        'd' => {
            camera.euclid_eye_x += right_x * euclid_step;
            camera.euclid_eye_z += right_z * euclid_step;
            camera.hyper.moveAlong(hyper_right, hyper_step);
            camera.spherical.moveAlong(spherical_right, spherical_step);
        },
        's' => {
            camera.euclid_eye_x -= forward_x * euclid_step;
            camera.euclid_eye_z -= forward_z * euclid_step;
            camera.hyper.moveAlong(hyper_forward, -hyper_step);
            camera.spherical.moveAlong(spherical_forward, -spherical_step);
        },
        'w' => {
            camera.euclid_eye_x += forward_x * euclid_step;
            camera.euclid_eye_z += forward_z * euclid_step;
            camera.hyper.moveAlong(hyper_forward, hyper_step);
            camera.spherical.moveAlong(spherical_forward, spherical_step);
        },
        else => {},
    }

    if (camera.movement_mode == .walk) {
        // Hyperbolic walk mode still rebuilds from the local input heading.
        // Spherical walk mode must keep the transported frame after movement;
        // re-solving it from the ambient heading basis can pick the opposite
        // tangent branch near the equator and create visible left/right flips.
        camera.hyper.syncHeadingPitch(
            @sin(camera.euclid_rotation),
            @cos(camera.euclid_rotation),
            camera.euclid_pitch,
        );
    }
}

fn animateSphericalCamera(camera: *CameraState, angle: f32, delta: f32) void {
    const yaw_delta = 0.19 * delta;
    camera.euclid_rotation += yaw_delta;
    const x_heading = @sin(camera.euclid_rotation);
    const z_heading = @cos(camera.euclid_rotation);
    if (camera.movement_mode == .walk) {
        camera.hyper.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
        camera.spherical.turnSurfaceYaw(yaw_delta, camera.euclid_pitch);
    } else {
        camera.hyper.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
        camera.spherical.turnYaw(yaw_delta);
    }

    const radial_delta = 0.012 * @sin(angle * 0.37);
    if (@abs(radial_delta) <= 1e-4) return;

    const walk = curvedWalkDirections(camera.spherical, @sin(camera.euclid_rotation), @cos(camera.euclid_rotation), camera.euclid_pitch);
    const forward = if (camera.movement_mode == .walk) walk.forward else camera.spherical.camera.forward;
    camera.spherical.moveAlong(forward, radial_delta);
}

fn vec3Length(v: curved.Vec3) f32 {
    return v.magnitude();
}

fn curvatureTargetForMode(mode: DemoMode) CurvatureTarget {
    return switch (mode) {
        .hyperbolic => .hyperbolic,
        .spherical => .spherical,
        else => .none,
    };
}

fn curvatureFeedback(
    target: CurvatureTarget,
    notice: CurvatureNotice,
    previous_radius: f32,
    current_radius: f32,
) CurvatureFeedback {
    return .{
        .target = target,
        .notice = notice,
        .previous_radius = previous_radius,
        .current_radius = current_radius,
    };
}

fn clampedCurvatureNotice(more_curved: bool) CurvatureNotice {
    return if (more_curved) .min_clamp else .max_clamp;
}

fn hyperbolicRadiusFloor(eye_chart: curved.Vec3) f32 {
    return @max(hyperbolic_radius_min, vec3Length(eye_chart) * 0.5 + 0.04);
}

fn adjustCurvature(camera: *CameraState, mode: DemoMode, more_curved: bool) CurvatureFeedback {
    const scale = if (more_curved) curvature_tighten_factor else curvature_loosen_factor;

    switch (mode) {
        .hyperbolic => {
            const previous_radius = camera.hyper.params.radius;
            const eye_chart = curved.chartCoords(.hyperbolic, camera.hyper.params, camera.hyper.camera.position);
            const lower = hyperbolicRadiusFloor(eye_chart);
            const upper = @max(lower, hyperbolic_radius_max);
            const unclamped_radius = previous_radius * scale;
            const next_radius = std.math.clamp(unclamped_radius, lower, upper);

            if (@abs(next_radius - previous_radius) <= 1e-6) {
                return curvatureFeedback(.hyperbolic, clampedCurvatureNotice(more_curved), previous_radius, previous_radius);
            }

            camera.hyper.adjustRadius(next_radius, curvature_rebuild_look_ahead) catch {
                return curvatureFeedback(.hyperbolic, .failed, previous_radius, previous_radius);
            };
            if (camera.movement_mode == .walk) {
                syncEuclidFromView(camera, camera.hyper);
            }
            return curvatureFeedback(
                .hyperbolic,
                if (@abs(next_radius - unclamped_radius) > 1e-6) clampedCurvatureNotice(more_curved) else .changed,
                previous_radius,
                camera.hyper.params.radius,
            );
        },
        .spherical => {
            const previous_radius = camera.spherical.params.radius;
            const unclamped_radius = previous_radius * scale;
            const next_radius = std.math.clamp(unclamped_radius, spherical_radius_min, spherical_radius_max);

            if (@abs(next_radius - previous_radius) <= 1e-6) {
                return curvatureFeedback(.spherical, clampedCurvatureNotice(more_curved), previous_radius, previous_radius);
            }

            camera.spherical.adjustRadius(next_radius, curvature_rebuild_look_ahead) catch {
                return curvatureFeedback(.spherical, .failed, previous_radius, previous_radius);
            };
            camera.spherical.wrapSphericalChart();
            if (camera.movement_mode == .walk) {
                syncEuclidFromView(camera, camera.spherical);
            }
            return curvatureFeedback(
                .spherical,
                if (@abs(next_radius - unclamped_radius) > 1e-6) clampedCurvatureNotice(more_curved) else .changed,
                previous_radius,
                camera.spherical.params.radius,
            );
        },
        else => return curvatureFeedback(curvatureTargetForMode(mode), .unavailable, 0.0, 0.0),
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

fn sphericalLocalCubeScale(radius: f32) f32 {
    return radius * spherical_local_cube_radius_fraction;
}

pub fn sphericalLocalCubeVertices(scale: f32, rotor: h.Rotor) [unit_cube_vertices.len]h.Vector {
    var vertices: [unit_cube_vertices.len]h.Vector = undefined;
    const ground_lift = h.Vector.init(.{ 0.0, scale, 0.0 });
    for (unit_cube_vertices, 0..) |vertex, i| {
        const centered = zmath.ga.rotors.rotated(vertex.scale(scale), rotor);
        vertices[i] = centered.add(ground_lift);
    }
    return vertices;
}

pub fn sphericalDemoAmbientPoint(params: curved.Params, local: curved.Vec3) curved.Vec4 {
    // HyperEngine models walkable objects relative to the ground plane with a
    // dedicated TanK-height transform instead of as one rigid exponential-map
    // solid. The spherical demo path mirrors that "footprint + lifted height"
    // embedding so vertical walls stay tied to the local ground as the
    // stereographic 3D camera warps them.
    return curved.sphericalAmbientFromGroundHeightPoint(params, local);
}

fn sphericalCubeChartVertices(local_vertices: [unit_cube_vertices.len]h.Vector, params: curved.Params) [unit_cube_vertices.len]h.Vector {
    var chart_vertices: [unit_cube_vertices.len]h.Vector = undefined;
    for (local_vertices, 0..) |vertex, i| {
        const ambient = sphericalDemoAmbientPoint(params, vec3FromVector(vertex));
        chart_vertices[i] = vectorFromVec3(curved.chartCoords(.spherical, params, ambient));
    }
    return chart_vertices;
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

test "flat modes report curvature as unavailable" {
    var camera = try CameraState.init();
    const feedback = adjustCurvature(&camera, .perspective, true);
    try std.testing.expectEqual(CurvatureNotice.unavailable, feedback.notice);
}

test "hyperbolic curvature adjustment changes the demo probe and radius floor" {
    var camera = try CameraState.init();
    const screen = curvedScreen(160, 90, camera.hyper.params.angular_zoom);
    const probe = curved.vec3(hyperbolic_prism_chart_radius, 0.0, hyperbolic_prism_half_depth);
    const before = camera.hyper.sampleProjectedPoint(probe, screen);
    try std.testing.expectEqual(curved.SampleStatus.visible, before.status);

    const first = adjustCurvature(&camera, .hyperbolic, true);
    try std.testing.expect(first.notice == .changed or first.notice == .min_clamp);

    const after = camera.hyper.sampleProjectedPoint(probe, screen);
    try std.testing.expectEqual(curved.SampleStatus.visible, after.status);
    try std.testing.expect(after.projected != null);
    try std.testing.expect(before.projected != null);
    try std.testing.expect(camera.hyper.params.radius < first.previous_radius);
    try std.testing.expect(@abs(after.distance - before.distance) > 1e-2);

    _ = adjustCurvature(&camera, .hyperbolic, true);
    const old_floor = default_hyperbolic_params.radius * 0.78 + 0.04;
    try std.testing.expect(camera.hyper.params.radius < old_floor);
}

test "spherical curvature adjustment changes the demo probe" {
    var camera = try CameraState.init();
    const screen = curvedScreen(160, 90, camera.spherical.params.angular_zoom);
    const before_vertices = sphericalCubeChartVertices(
        sphericalLocalCubeVertices(sphericalLocalCubeScale(camera.spherical.params.radius), h.Rotor.init(.{ 1, 0, 0, 0 })),
        camera.spherical.params,
    );
    const probe = vec3FromVector(before_vertices[0]);
    const before = camera.spherical.sampleProjectedPoint(probe, screen);
    try std.testing.expectEqual(curved.SampleStatus.visible, before.status);

    const feedback = adjustCurvature(&camera, .spherical, true);
    try std.testing.expect(feedback.notice == .changed or feedback.notice == .min_clamp);

    const after_vertices = sphericalCubeChartVertices(
        sphericalLocalCubeVertices(sphericalLocalCubeScale(camera.spherical.params.radius), h.Rotor.init(.{ 1, 0, 0, 0 })),
        camera.spherical.params,
    );
    const after = camera.spherical.sampleProjectedPoint(vec3FromVector(after_vertices[0]), screen);
    try std.testing.expectEqual(curved.SampleStatus.visible, after.status);
    try std.testing.expect(@abs(after.distance - before.distance) > 2e-2);
}

test "spherical walk backward movement evolves smoothly across chart wrap" {
    var camera = try CameraState.init();
    const initial_pos = camera.spherical.camera.position;

    for (0..40) |_| {
        adjustCameraTranslation(&camera, .spherical, 's');
        try std.testing.expect(camera.spherical.walkSurfaceUp() != null);
    }

    // Camera should have moved far enough across the sphere
    const final_pos = camera.spherical.camera.position;
    const pos_dot = initial_pos[0] * final_pos[0] + initial_pos[1] * final_pos[1] +
        initial_pos[2] * final_pos[2] + initial_pos[3] * final_pos[3];
    try std.testing.expect(@abs(pos_dot) < 0.99);
}

test "spherical backward walk step keeps position continuous in locked walk mode" {
    var camera = try CameraState.init();
    camera.movement_mode = .walk;
    camera.euclid_rotation = -3.076082;
    camera.euclid_pitch = -0.013355;
    camera.euclid_eye_x = 165.323760;
    camera.euclid_eye_y = 0.0;
    camera.euclid_eye_z = 179.205610;
    camera.spherical = .{
        .metric = .spherical,
        .params = .{
            .radius = 1.480000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .stereographic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = .{ 0.027459, -0.064229, 0.013690, 0.997459 },
            .right = .{ 0.075515, -0.994948, -0.000000, -0.066146 },
            .up = .{ -0.011556, 0.000014, 0.999843, -0.013404 },
            .forward = .{ 0.996700, 0.077152, 0.011215, -0.022624 },
        },
        .scene_sign = 1.0,
    };

    const before_position = camera.spherical.camera.position;
    adjustCameraTranslation(&camera, .spherical, 's');
    const after_position = camera.spherical.camera.position;

    const position_dot = before_position[0] * after_position[0] +
        before_position[1] * after_position[1] +
        before_position[2] * after_position[2] +
        before_position[3] * after_position[3];

    try std.testing.expect(position_dot > 0.95);
    try std.testing.expectEqual(@as(f32, 1.0), camera.spherical.scene_sign);
}

test "spherical locked walk backward-forward steps stay reversible" {
    var camera = try CameraState.init();
    camera.movement_mode = .walk;

    for (0..120) |_| {
        const before = camera.spherical.camera;

        adjustCameraTranslation(&camera, .spherical, 's');
        adjustCameraTranslation(&camera, .spherical, 'w');

        const after = camera.spherical.camera;
        const position_dot = before.position[0] * after.position[0] +
            before.position[1] * after.position[1] +
            before.position[2] * after.position[2] +
            before.position[3] * after.position[3];
        const forward_dot = before.forward[0] * after.forward[0] +
            before.forward[1] * after.forward[1] +
            before.forward[2] * after.forward[2] +
            before.forward[3] * after.forward[3];

        try std.testing.expect(position_dot > 0.999);
        try std.testing.expect(forward_dot > 0.999);

        adjustCameraTranslation(&camera, .spherical, 's');
    }
}

test "spherical steep-pitch backward walk preserves local heading and pitch" {
    var camera = try CameraState.init();
    camera.movement_mode = .walk;
    camera.euclid_rotation = 0.0;
    camera.euclid_pitch = 1.1;
    syncWalkOrientation(&camera);
    for (0..80) |_| {
        adjustCameraTranslation(&camera, .spherical, 's');
        try std.testing.expect(camera.spherical.walkSurfaceUp() != null);
    }
}

test "spherical walk surface normal does not change with pitch at fixed position" {
    var camera = try CameraState.init();
    camera.movement_mode = .walk;
    camera.euclid_rotation = 0.465501;

    camera.euclid_pitch = -0.6;
    syncWalkOrientation(&camera);
    const down_up = camera.spherical.walkSurfaceUp().?;

    camera.euclid_pitch = 0.2;
    syncWalkOrientation(&camera);
    const up_up = camera.spherical.walkSurfaceUp().?;

    const up_dot = down_up[0] * up_up[0] +
        down_up[1] * up_up[1] +
        down_up[2] * up_up[2] +
        down_up[3] * up_up[3];
    try std.testing.expect(up_dot > 0.999);
}

test "spherical backward walk does not oscillate between two positions" {
    var camera = try CameraState.init();
    camera.movement_mode = .walk;
    camera.euclid_rotation = -2.115804;
    camera.euclid_pitch = -0.020000;
    camera.euclid_eye_x = -70.910950;
    camera.euclid_eye_y = 0.0;
    camera.euclid_eye_z = -176.578800;
    camera.spherical = .{
        .metric = .spherical,
        .params = .{
            .radius = 0.740000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .stereographic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = .{ 0.372664, -0.325853, 0.000000, -0.868872 },
            .right = .{ 0.719299, -0.490129, -0.000000, 0.492324 },
            .up = .{ -0.011725, -0.016168, 0.999800, 0.001035 },
            .forward = .{ -0.586168, -0.808289, -0.019999, 0.051722 },
        },
        .scene_sign = 1.0,
    };

    var prev2_position: ?curved.Vec4 = null;
    var prev_position = camera.spherical.camera.position;
    for (0..40) |_| {
        adjustCameraTranslation(&camera, .spherical, 's');
        const position = camera.spherical.camera.position;
        if (prev2_position) |prev2| {
            const two_step_dot = prev2[0] * position[0] +
                prev2[1] * position[1] +
                prev2[2] * position[2] +
                prev2[3] * position[3];
            try std.testing.expect(two_step_dot < 0.995);
        }
        prev2_position = prev_position;
        prev_position = position;
    }
}

test "spherical walk look controls keep the local camera branch continuous" {
    var camera = try CameraState.init();
    camera.movement_mode = .walk;
    camera.euclid_rotation = 0.285000;
    camera.euclid_pitch = 0.180000;
    camera.euclid_eye_x = -11.469614;
    camera.euclid_eye_y = 0.0;
    camera.euclid_eye_z = -41.803680;
    camera.spherical = .{
        .metric = .spherical,
        .params = .{
            .radius = 1.480000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .stereographic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = .{ -0.956042, -0.096576, 0.000000, -0.276854 },
            .right = .{ 0.006139, 0.937401, 0.000000, -0.348198 },
            .up = .{ -0.052483, 0.059903, 0.983843, 0.160342 },
            .forward = .{ 0.288416, -0.329187, 0.179031, -0.881135 },
        },
        .scene_sign = 1.0,
    };

    const before = camera.spherical.camera;
    const before_up = camera.spherical.walkSurfaceUp().?;

    adjustCameraArrow(&camera, .spherical, 'C');
    const yawed = camera.spherical.camera;
    const yawed_up = camera.spherical.walkSurfaceUp().?;
    const yawed_orientation = camera.spherical.walkOrientation().?;
    const yaw_position_dot = before.position[0] * yawed.position[0] +
        before.position[1] * yawed.position[1] +
        before.position[2] * yawed.position[2] +
        before.position[3] * yawed.position[3];
    const yaw_forward_dot = before.forward[0] * yawed.forward[0] +
        before.forward[1] * yawed.forward[1] +
        before.forward[2] * yawed.forward[2] +
        before.forward[3] * yawed.forward[3];
    const yaw_up_dot = before_up[0] * yawed_up[0] +
        before_up[1] * yawed_up[1] +
        before_up[2] * yawed_up[2] +
        before_up[3] * yawed_up[3];
    try std.testing.expect(yaw_position_dot > 0.999);
    try std.testing.expect(yaw_forward_dot > 0.99);
    try std.testing.expect(yaw_up_dot > 0.999);
    try std.testing.expectApproxEqAbs(camera.euclid_pitch, yawed_orientation.pitch, 1e-3);

    camera.spherical.camera = before;
    camera.euclid_rotation = 0.285000;
    camera.euclid_pitch = 0.180000;
    const before_pitch_up = camera.spherical.walkSurfaceUp().?;

    adjustCameraArrow(&camera, .spherical, 'A');
    const pitched = camera.spherical.camera;
    const pitched_up = camera.spherical.walkSurfaceUp().?;
    const pitched_orientation = camera.spherical.walkOrientation().?;
    const pitch_position_dot = before.position[0] * pitched.position[0] +
        before.position[1] * pitched.position[1] +
        before.position[2] * pitched.position[2] +
        before.position[3] * pitched.position[3];
    const pitch_forward_dot = before.forward[0] * pitched.forward[0] +
        before.forward[1] * pitched.forward[1] +
        before.forward[2] * pitched.forward[2] +
        before.forward[3] * pitched.forward[3];
    const pitch_up_dot = before_pitch_up[0] * pitched_up[0] +
        before_pitch_up[1] * pitched_up[1] +
        before_pitch_up[2] * pitched_up[2] +
        before_pitch_up[3] * pitched_up[3];
    try std.testing.expect(pitch_position_dot > 0.999);
    try std.testing.expect(pitch_forward_dot > 0.99);
    try std.testing.expect(pitch_up_dot > 0.999);
    try std.testing.expectApproxEqAbs(camera.euclid_pitch, pitched_orientation.pitch, 1e-3);
}

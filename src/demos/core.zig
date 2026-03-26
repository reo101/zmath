const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
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
pub const spherical_local_cube_scale: f32 = 0.22;
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
const face_fill_steps: usize = 12;
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
                .{ 0.0, 0.0, -default_hyperbolic_params.radius * 0.78 },
                .{ 0.0, 0.0, 0.0 },
            ),
            .spherical = try curved.View.init(
                .spherical,
                default_spherical_params,
                .stereographic,
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
                shadeCurvedQuads(canvas, chart_prism_vertices[0..], hyperbolic_prism_side_faces[0..], self.camera.hyper, screen);
                drawCurvedEdges(canvas, chart_prism_vertices[0..], hyperbolic_prism_edges[0..], self.camera.hyper, screen);
                drawCurvedNavigator(canvas, chart_prism_vertices[0..], hyperbolic_prism_edges[0..], self.camera.hyper, width, height);
            },
            .spherical => {
                const chart_cube_vertices = sphericalCubeChartVertices(
                    sphericalLocalCubeVertices(sphericalLocalCubeScale(self.camera.spherical.params.radius), rotor),
                    self.camera.spherical.params,
                );
                const screen = curvedScreen(width, height, zoom);
                shadeCurvedQuads(canvas, chart_cube_vertices[0..], cube_faces[0..], self.camera.spherical, screen);
                drawCurvedEdges(canvas, chart_cube_vertices[0..], cube_edges[0..], self.camera.spherical, screen);
                drawCurvedNavigator(canvas, chart_cube_vertices[0..], cube_edges[0..], self.camera.spherical, width, height);
            },
        }

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
        const world_cube_vertices = rotatedScaledCubeVertices(euclidean_cube_scale, rotor);
        var view_cube_vertices: [unit_cube_vertices.len]h.Vector = undefined;
        for (world_cube_vertices, 0..) |vertex, i| {
            view_cube_vertices[i] = cameraSpace(vertex, self.camera);
        }

        return .{
            .projection_mode = projection_mode,
            .zoom = modeZoom(self.angle, self.mode, self.camera),
            .view_cube_vertices = view_cube_vertices,
        };
    }
};

pub const EuclideanScene = struct {
    projection_mode: projection.EuclideanProjection,
    zoom: f32,
    view_cube_vertices: [unit_cube_vertices.len]h.Vector,
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
    std.debug.print("{s}=.{{ {d:.6}, {d:.6}, {d:.6} }}\n", .{ name, v[0], v[1], v[2] });
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

const NavigatorAxes = struct {
    horizontal: usize,
    vertical: usize,
};

const NavigatorRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

fn drawNavigatorBackground(canvas: *canvas_api.Canvas, rect: NavigatorRect) void {
    for (rect.y..rect.y + rect.height) |y| {
        for (rect.x..rect.x + rect.width) |x| {
            canvas.setFill(@floatFromInt(x), @floatFromInt(y), 1, 236, -1.0);
        }
    }
}

fn drawNavigatorFrame(canvas: *canvas_api.Canvas, rect: NavigatorRect) void {
    const left = @as(f32, @floatFromInt(rect.x));
    const right = @as(f32, @floatFromInt(rect.x + rect.width - 1));
    const top = @as(f32, @floatFromInt(rect.y));
    const bottom = @as(f32, @floatFromInt(rect.y + rect.height - 1));

    canvas.drawLine(left, top, right, top, '#', 244);
    canvas.drawLine(left, bottom, right, bottom, '#', 244);
    canvas.drawLine(left, top, left, bottom, '#', 244);
    canvas.drawLine(right, top, right, bottom, '#', 244);
}

fn drawNavigatorAxes(canvas: *canvas_api.Canvas, rect: NavigatorRect) void {
    const center_x = @as(f32, @floatFromInt(rect.x + rect.width / 2));
    const center_y = @as(f32, @floatFromInt(rect.y + rect.height / 2));
    const left = @as(f32, @floatFromInt(rect.x + 1));
    const right = @as(f32, @floatFromInt(rect.x + rect.width - 2));
    const top = @as(f32, @floatFromInt(rect.y + 1));
    const bottom = @as(f32, @floatFromInt(rect.y + rect.height - 2));

    canvas.drawLine(left, center_y, right, center_y, '#', 239);
    canvas.drawLine(center_x, top, center_x, bottom, '#', 239);
}

fn projectNavigatorPoint(rect: NavigatorRect, extent: f32, horizontal: f32, vertical: f32) [2]f32 {
    const inner_left = @as(f32, @floatFromInt(rect.x + 1));
    const inner_top = @as(f32, @floatFromInt(rect.y + 1));
    const inner_width = @as(f32, @floatFromInt(rect.width - 2));
    const inner_height = @as(f32, @floatFromInt(rect.height - 2));

    return .{
        inner_left + (horizontal / extent * 0.5 + 0.5) * inner_width,
        inner_top + (0.5 - vertical / extent * 0.5) * inner_height,
    };
}

fn drawNavigatorMarker(canvas: *canvas_api.Canvas, point: [2]f32, tone: u8) void {
    canvas.drawLine(point[0] - 0.5, point[1], point[0] + 0.5, point[1], '#', tone);
    canvas.drawLine(point[0], point[1] - 0.5, point[0], point[1] + 0.5, '#', tone);
}

fn navigatorExtent(chart_vertices: []const h.Vector, eye_chart: curved.Vec3, look_chart: curved.Vec3, metric: curved.Metric) f32 {
    var extent: f32 = switch (metric) {
        .hyperbolic => 0.38,
        .elliptic, .spherical => 1.0,
    };

    for (chart_vertices) |vertex| {
        const chart = vec3FromVector(vertex);
        inline for (chart) |coord| {
            extent = @max(extent, @abs(coord) * 1.15);
        }
    }

    inline for (eye_chart) |coord| extent = @max(extent, @abs(coord) * 1.12);
    inline for (look_chart) |coord| extent = @max(extent, @abs(coord) * 1.12);
    return extent;
}

fn drawNavigatorGeodesic(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    axes: NavigatorAxes,
    a_chart: curved.Vec3,
    b_chart: curved.Vec3,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;

    for (0..19) |i| {
        const t = @as(f32, @floatFromInt(i)) / 18.0;
        const chart = curved.geodesicChartPoint(view.metric, view.params, a_chart, b_chart, t) orelse continue;
        const point = projectNavigatorPoint(rect, extent, chart[axes.horizontal], chart[axes.vertical]);
        if (prev_point) |prev| {
            canvas.drawLine(prev[0], prev[1], point[0], point[1], '#', tone);
        }
        prev_point = point;
    }
}

fn drawNavigatorPanel(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    chart_vertices: []const h.Vector,
    edges: []const [2]usize,
    eye_chart: curved.Vec3,
    look_chart: curved.Vec3,
    axes: NavigatorAxes,
) void {
    drawNavigatorBackground(canvas, rect);
    drawNavigatorFrame(canvas, rect);
    drawNavigatorAxes(canvas, rect);

    for (edges) |edge| {
        drawNavigatorGeodesic(
            canvas,
            rect,
            extent,
            view,
            axes,
            vec3FromVector(chart_vertices[edge[0]]),
            vec3FromVector(chart_vertices[edge[1]]),
            81,
        );
    }

    const eye_point = projectNavigatorPoint(rect, extent, eye_chart[axes.horizontal], eye_chart[axes.vertical]);
    const look_point = projectNavigatorPoint(rect, extent, look_chart[axes.horizontal], look_chart[axes.vertical]);
    canvas.drawLine(eye_point[0], eye_point[1], look_point[0], look_point[1], '#', 253);
    drawNavigatorMarker(canvas, look_point, 253);
    drawNavigatorMarker(canvas, eye_point, 220);
}

fn drawCurvedNavigator(
    canvas: *canvas_api.Canvas,
    chart_vertices: []const h.Vector,
    edges: []const [2]usize,
    view: curved.View,
    width: usize,
    height: usize,
) void {
    if (width < 54 or height < 26) return;

    const panel_width = @min(@as(usize, 26), @max(@as(usize, 18), width / 4));
    const panel_height = @min(@as(usize, 10), @max(@as(usize, 7), height / 5));
    const margin: usize = 2;
    const gap: usize = 2;
    const total_height = panel_height *| 2 +| gap;
    if (panel_width +| margin >= width or total_height +| margin *| 2 >= height) return;

    const panel_x = width - panel_width - margin;
    const top_y = margin;
    const bottom_y = top_y + panel_height + gap;
    const top_rect = NavigatorRect{ .x = panel_x, .y = top_y, .width = panel_width, .height = panel_height };
    const bottom_rect = NavigatorRect{ .x = panel_x, .y = bottom_y, .width = panel_width, .height = panel_height };

    const eye_chart = curved.chartCoords(view.metric, view.params, view.camera.position);
    var look_probe = view.camera;
    curved.moveForward(&look_probe, view.metric, view.params, @min(view.params.radius * 0.18, 0.18));
    const look_chart = curved.chartCoords(view.metric, view.params, look_probe.position);
    const extent = navigatorExtent(chart_vertices, eye_chart, look_chart, view.metric);

    drawNavigatorPanel(canvas, top_rect, extent, view, chart_vertices, edges, eye_chart, look_chart, .{ .horizontal = 0, .vertical = 2 });
    drawNavigatorPanel(canvas, bottom_rect, extent, view, chart_vertices, edges, eye_chart, look_chart, .{ .horizontal = 2, .vertical = 1 });
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
        .spherical => "stereo2",
        else => "-",
    };
}

const WalkDirections = struct {
    forward: curved.Vec4,
    right: curved.Vec4,
};

fn curvedWalkDirections(view: curved.View, x_heading: f32, z_heading: f32) WalkDirections {
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
        .spherical => camera.spherical.projection = .stereographic,
        else => {},
    }
}

fn syncWalkOrientation(camera: *CameraState) void {
    const x_heading = @sin(camera.euclid_rotation);
    const z_heading = @cos(camera.euclid_rotation);
    camera.hyper.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
    camera.spherical.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
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
        .pitch = std.math.clamp(candidate.pitch, -1.10, 1.10),
    };
    const antipodal = ViewAngleState{
        .rotation = wrapAngleNear(candidate.rotation + @as(f32, std.math.pi), current_rotation),
        .pitch = std.math.clamp(-candidate.pitch, -1.10, 1.10),
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
            .pitch = std.math.clamp(candidate.pitch, -1.10, 1.10),
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
        syncWalkOrientation(camera);
    }

    switch (arrow) {
        'A' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch + pitch_step, -1.10, 1.10);
            if (camera.movement_mode == .walk) {
                syncWalkOrientation(camera);
            } else {
                camera.hyper.turnPitch(pitch_step);
                camera.spherical.turnPitch(pitch_step);
            }
        },
        'B' => {
            camera.euclid_pitch = std.math.clamp(camera.euclid_pitch - pitch_step, -1.10, 1.10);
            if (camera.movement_mode == .walk) {
                syncWalkOrientation(camera);
            } else {
                camera.hyper.turnPitch(-pitch_step);
                camera.spherical.turnPitch(-pitch_step);
            }
        },
        'C' => {
            camera.euclid_rotation += rotation_step;
            if (camera.movement_mode == .walk) {
                syncWalkOrientation(camera);
            } else {
                camera.hyper.turnYaw(rotation_step);
                camera.spherical.turnYaw(rotation_step);
            }
        },
        'D' => {
            camera.euclid_rotation -= rotation_step;
            if (camera.movement_mode == .walk) {
                syncWalkOrientation(camera);
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
    const hyper_walk = curvedWalkDirections(camera.hyper, sin_rotation, cos_rotation);
    const hyper_forward = if (camera.movement_mode == .walk) hyper_walk.forward else camera.hyper.camera.forward;
    const hyper_right = if (camera.movement_mode == .walk) hyper_walk.right else camera.hyper.camera.right;
    // For spherical walk, use the camera's own parallel-transported forward
    // direction, projected to the ground plane.  This avoids going through
    // the heading basis (which is position-dependent and rotates as the
    // camera crosses the sphere).
    const spherical_forward = camera.spherical.camera.forward;
    const spherical_right = camera.spherical.camera.right;

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

    if (camera.movement_mode == .walk) {
        // Do NOT call syncWalkOrientation here. The spherical camera basis
        // was already correctly evolved by moveAlongDirection's parallel
        // transport. Overwriting it from euclid_rotation would fight the
        // transport (the heading basis rotates as the camera moves across
        // the sphere, so a fixed euclid_rotation maps to different world
        // directions at different positions).
        //
        // Re-sync the hyperbolic camera from euclid_rotation since its
        // heading basis behaves differently.
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
    if (camera.movement_mode == .walk) {
        const x_heading = @sin(camera.euclid_rotation);
        const z_heading = @cos(camera.euclid_rotation);
        camera.spherical.syncHeadingPitch(x_heading, z_heading, camera.euclid_pitch);
    } else {
        camera.spherical.turnYaw(yaw_delta);
    }

    const radial_delta = 0.012 * @sin(angle * 0.37);
    if (@abs(radial_delta) <= 1e-4) return;

    const walk = curvedWalkDirections(camera.spherical, @sin(camera.euclid_rotation), @cos(camera.euclid_rotation));
    const forward = if (camera.movement_mode == .walk) walk.forward else camera.spherical.camera.forward;
    camera.spherical.moveAlong(forward, radial_delta);
    camera.spherical.wrapSphericalChart();
    if (camera.movement_mode == .walk) {
        syncEuclidFromView(camera, camera.spherical);
    }
}

fn vec3Length(v: curved.Vec3) f32 {
    return h.Vector.init(v).magnitude();
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
    _ = radius;
    return spherical_local_cube_scale;
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

fn sphericalCubeChartVertices(local_vertices: [unit_cube_vertices.len]h.Vector, params: curved.Params) [unit_cube_vertices.len]h.Vector {
    var chart_vertices: [unit_cube_vertices.len]h.Vector = undefined;
    for (local_vertices, 0..) |vertex, i| {
        const ambient = curved.sphericalAmbientFromGroundHeightPoint(params, vec3FromVector(vertex));
        chart_vertices[i] = h.Vector.init(curved.chartCoords(.spherical, params, ambient));
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
    const probe = curved.Vec3{ hyperbolic_prism_chart_radius, 0.0, hyperbolic_prism_half_depth };
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

    var prev_orientation = camera.spherical.walkOrientation().?;
    var max_heading_delta: f32 = 0.0;
    var max_pitch_delta: f32 = 0.0;

    for (0..40) |_| {
        adjustCameraTranslation(&camera, .spherical, 's');
        const orientation = camera.spherical.walkOrientation() orelse continue;
        // Heading should evolve smoothly — no large jumps per step
        const heading_angle = std.math.atan2(orientation.x_heading, orientation.z_heading);
        const prev_heading_angle = std.math.atan2(prev_orientation.x_heading, prev_orientation.z_heading);
        const heading_delta = @abs(heading_angle - wrapAngleNear(prev_heading_angle, heading_angle));
        const pitch_delta = @abs(orientation.pitch - prev_orientation.pitch);
        max_heading_delta = @max(max_heading_delta, heading_delta);
        max_pitch_delta = @max(max_pitch_delta, pitch_delta);
        prev_orientation = orientation;
    }

    // Camera should have moved far enough across the sphere
    const final_pos = camera.spherical.camera.position;
    const pos_dot = initial_pos[0] * final_pos[0] + initial_pos[1] * final_pos[1] +
        initial_pos[2] * final_pos[2] + initial_pos[3] * final_pos[3];
    try std.testing.expect(@abs(pos_dot) < 0.99);

    // No step should produce a heading jump larger than ~0.3 rad (~17 deg)
    try std.testing.expect(max_heading_delta < 0.3);
    // Pitch should stay nearly constant when walking straight backward
    try std.testing.expect(max_pitch_delta < 0.40);

    // euclid_rotation should track the current spherical heading
    const final_orientation = camera.spherical.walkOrientation().?;
    const final_heading = std.math.atan2(final_orientation.x_heading, final_orientation.z_heading);
    const euclid_heading = wrapAngleNear(camera.euclid_rotation, final_heading);
    try std.testing.expectApproxEqAbs(final_heading, euclid_heading, 0.02);
}

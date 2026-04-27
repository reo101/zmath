const std = @import("std");
const rl = @import("raylib");
const rlgl = rl.gl;
const draw = @import("draw.zig");
const story = @import("story.zig");
const style = @import("style.zig");

const window_width: i32 = 1360;
const window_height: i32 = 820;

pub const App = struct {
    scene: story.State,
    paused: bool = false,

    pub fn init() App {
        return .{ .scene = story.State.init() };
    }

    pub fn run(self: *App) !void {
        rl.setConfigFlags(.{
            .window_resizable = true,
            .vsync_hint = true,
        });
        rl.setTraceLogLevel(.warning);
        rl.initWindow(window_width, window_height, "zmath demo: walkable geometries");
        defer rl.closeWindow();

        var resources = try RenderResources.init();
        defer resources.deinit();

        rl.setTargetFPS(60);

        while (!rl.windowShouldClose()) {
            self.update();
            self.render(&resources);
        }
    }

    fn update(self: *App) void {
        if (rl.isKeyPressed(.tab)) self.scene.nextMode();
        if (rl.isKeyPressed(.one)) self.scene.setMode(.perspective);
        if (rl.isKeyPressed(.two)) self.scene.setMode(.isometric);
        if (rl.isKeyPressed(.three)) self.scene.setMode(.spherical);
        if (rl.isKeyPressed(.four)) self.scene.setMode(.hyperbolic);
        if (rl.isKeyPressed(.p)) self.paused = !self.paused;
        if (rl.isKeyPressed(.r)) self.scene.resetActive();
        if (rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add)) self.scene.adjustActiveCurvature(true);
        if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) self.scene.adjustActiveCurvature(false);

        if (!self.paused) {
            self.scene.update(readInput(), rl.getFrameTime());
        }
    }

    fn render(self: *const App, resources: *const RenderResources) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();
        const screen = rl.Rectangle{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(screen_w),
            .height = @floatFromInt(screen_h),
        };
        const world_rect = draw.inset(screen, 22.0);

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(style.bg_bottom);
        rl.drawRectangleGradientV(0, 0, screen_w, screen_h, style.bg_top, style.bg_bottom);
        drawAtmosphere(screen, self.scene.mode);
        drawWorld(resources, self.scene.mode, self.scene.activeCameraPtrConst(), world_rect);
        drawHud(self, screen);
    }
};

const RenderResources = struct {
    spherical_shader: rl.Shader,
    spherical_locations: SphericalShaderLocations,

    fn init() !RenderResources {
        const spherical_shader = try rl.loadShaderFromMemory(
            @embedFile("shaders/spherical_mesh.vs"),
            @embedFile("shaders/spherical_mesh.fs"),
        );
        return .{
            .spherical_shader = spherical_shader,
            .spherical_locations = SphericalShaderLocations.init(spherical_shader),
        };
    }

    fn deinit(self: *RenderResources) void {
        self.spherical_shader.unload();
    }
};

const SphericalShaderLocations = struct {
    rect: i32,
    screen: i32,
    camera_pos: i32,
    yaw: i32,
    pitch: i32,
    radius: i32,
    zoom: i32,
    far_pass: i32,

    fn init(shader: rl.Shader) SphericalShaderLocations {
        return .{
            .rect = rl.getShaderLocation(shader, "u_rect"),
            .screen = rl.getShaderLocation(shader, "u_screen"),
            .camera_pos = rl.getShaderLocation(shader, "u_camera_pos"),
            .yaw = rl.getShaderLocation(shader, "u_yaw"),
            .pitch = rl.getShaderLocation(shader, "u_pitch"),
            .radius = rl.getShaderLocation(shader, "u_radius"),
            .zoom = rl.getShaderLocation(shader, "u_zoom"),
            .far_pass = rl.getShaderLocation(shader, "u_far_pass"),
        };
    }
};

const FaceRender = struct {
    points: [4]rl.Vector2,
    depth: f32,
    color: rl.Color,
};

const max_cube_face_steps = 18;
const max_cube_cells = story.cube_faces.len * max_cube_face_steps * max_cube_face_steps;
const spherical_shader_face_steps = 24;
const spherical_shader_edge_steps = spherical_shader_face_steps * 2;

const face_colors = [_]rl.Color{
    style.coral,
    style.cyan,
    style.amber,
    style.moss,
    style.violet,
    style.panel,
};

fn readInput() story.Input {
    return .{
        .forward = rl.isKeyDown(.w),
        .backward = rl.isKeyDown(.s),
        .left = rl.isKeyDown(.a),
        .right = rl.isKeyDown(.d),
        .up = rl.isKeyDown(.e),
        .down = rl.isKeyDown(.q),
        .look_left = rl.isKeyDown(.left),
        .look_right = rl.isKeyDown(.right),
        .look_up = rl.isKeyDown(.up),
        .look_down = rl.isKeyDown(.down),
    };
}

fn drawAtmosphere(screen: rl.Rectangle, mode: story.Mode) void {
    const accent = modeAccent(mode);
    rl.drawCircleV(.{ .x = screen.width * 0.18, .y = screen.height * 0.22 }, screen.height * 0.24, style.alpha(accent, 28));
    rl.drawCircleV(.{ .x = screen.width * 0.82, .y = screen.height * 0.70 }, screen.height * 0.32, style.alpha(style.cyan, 18));
}

fn drawWorld(resources: *const RenderResources, mode: story.Mode, camera: *const story.Camera, rect: rl.Rectangle) void {
    drawGround(mode, camera, rect, .main, 255);
    if (mode == .spherical) {
        drawSphericalCubeShader(resources, camera, rect, 246);
        return;
    }
    drawCube(mode, camera, rect, .main, 246);
}

fn drawGround(mode: story.Mode, camera: *const story.Camera, rect: rl.Rectangle, pass: story.Pass, fade: u8) void {
    if (mode == .spherical) {
        drawSphericalGround(camera, rect, fade);
        return;
    }

    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        const tint = if (@mod(x, 4) == 0) style.alpha(style.white, fade / 2) else style.alpha(style.white, fade / 5);
        drawWorldLine(
            mode,
            camera,
            rect,
            .{ .x = @floatFromInt(x), .y = 0.0, .z = -8.0 },
            .{ .x = @floatFromInt(x), .y = 0.0, .z = 18.0 },
            tint,
            if (@mod(x, 4) == 0) 1.7 else 1.0,
            pass,
        );
    }

    var z: i32 = -8;
    while (z <= 18) : (z += 1) {
        const tint = if (@mod(z, 4) == 0) style.alpha(style.white, fade / 2) else style.alpha(style.white, fade / 5);
        drawWorldLine(
            mode,
            camera,
            rect,
            .{ .x = -8.0, .y = 0.0, .z = @floatFromInt(z) },
            .{ .x = 8.0, .y = 0.0, .z = @floatFromInt(z) },
            tint,
            if (@mod(z, 4) == 0) 1.7 else 1.0,
            pass,
        );
    }
}

fn drawSphericalGround(camera: *const story.Camera, rect: rl.Rectangle, fade: u8) void {
    const step: i32 = 6;
    const min_x = draw.toInt(rect.x);
    const min_y = draw.toInt(rect.y);
    const max_x = draw.toInt(rect.x + rect.width);
    const max_y = draw.toInt(rect.y + rect.height);

    var y = min_y;
    while (y < max_y) : (y += step) {
        var x = min_x;
        while (x < max_x) : (x += step) {
            const sample_point = rl.Vector2{
                .x = @as(f32, @floatFromInt(x)) + @as(f32, @floatFromInt(step)) * 0.5,
                .y = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(step)) * 0.5,
            };
            const sample = story.groundSample(.spherical, camera, rect, sample_point) orelse continue;
            const checker_alpha: u8 = if (sample.checker) fade / 12 else fade / 18;
            const grid_alpha = @as(u8, @intFromFloat(@round(@as(f32, @floatFromInt(fade)) * 0.42 * sample.line_strength)));
            const fill = if (grid_alpha > 0)
                style.alpha(style.white, @max(grid_alpha, fade / 9))
            else if (sample.checker)
                style.alpha(style.cyan, checker_alpha)
            else
                style.alpha(style.moss, checker_alpha);
            rl.drawRectangle(x, y, step + 1, step + 1, fill);
        }
    }
}

fn drawSphericalCubeShader(resources: *const RenderResources, camera: *const story.Camera, rect: rl.Rectangle, fade: u8) void {
    enableRectScissor(rect);
    defer rlgl.rlDisableScissorTest();

    rlgl.rlDisableBackfaceCulling();
    defer rlgl.rlEnableBackfaceCulling();
    rlgl.rlEnableDepthTest();
    rlgl.rlEnableDepthMask();
    defer rlgl.rlDisableDepthTest();

    rl.beginShaderMode(resources.spherical_shader);
    defer rl.endShaderMode();

    drawSphericalCubeShaderPass(resources, camera, rect, fade, false);
    drawSphericalCubeShaderPass(resources, camera, rect, fade, true);
}

fn drawSphericalCubeShaderPass(resources: *const RenderResources, camera: *const story.Camera, rect: rl.Rectangle, fade: u8, far_pass: bool) void {
    setSphericalShaderUniforms(resources, camera, rect, far_pass);
    drawSphericalCubeFacesShader(fade);
    drawSphericalCubeEdgesShader();
}

fn setSphericalShaderUniforms(resources: *const RenderResources, camera: *const story.Camera, rect: rl.Rectangle, far_pass: bool) void {
    const shader = resources.spherical_shader;
    const locations = resources.spherical_locations;
    const screen = [2]f32{
        @floatFromInt(rl.getScreenWidth()),
        @floatFromInt(rl.getScreenHeight()),
    };
    const rect_values = [4]f32{ rect.x, rect.y, rect.width, rect.height };
    const camera_pos = [3]f32{ camera.position.x, camera.position.y, camera.position.z };
    const radius = camera.curvatureRadiusValue(.spherical) orelse story.default_spherical_radius;
    const zoom: f32 = story.default_spherical_zoom;
    const far_pass_int: i32 = if (far_pass) 1 else 0;

    rl.setShaderValue(shader, locations.rect, &rect_values, .vec4);
    rl.setShaderValue(shader, locations.screen, &screen, .vec2);
    rl.setShaderValue(shader, locations.camera_pos, &camera_pos, .vec3);
    rl.setShaderValue(shader, locations.yaw, &camera.yaw, .float);
    rl.setShaderValue(shader, locations.pitch, &camera.pitch, .float);
    rl.setShaderValue(shader, locations.radius, &radius, .float);
    rl.setShaderValue(shader, locations.zoom, &zoom, .float);
    rl.setShaderValue(shader, locations.far_pass, &far_pass_int, .int);
}

fn drawSphericalCubeFacesShader(fade: u8) void {
    const vertices = story.cubeVertices();
    rlgl.rlBegin(rlgl.rl_triangles);
    for (story.cube_faces, 0..) |face, face_index| {
        if (face_index == story.cube_bottom_face_index) continue;
        const color = style.alpha(face_colors[face_index], fade);
        rlgl.rlColor4ub(color.r, color.g, color.b, color.a);

        var u_index: usize = 0;
        while (u_index < spherical_shader_face_steps) : (u_index += 1) {
            var v_index: usize = 0;
            while (v_index < spherical_shader_face_steps) : (v_index += 1) {
                const min_u = @as(f32, @floatFromInt(u_index)) / @as(f32, @floatFromInt(spherical_shader_face_steps));
                const min_v = @as(f32, @floatFromInt(v_index)) / @as(f32, @floatFromInt(spherical_shader_face_steps));
                const max_u = @as(f32, @floatFromInt(u_index + 1)) / @as(f32, @floatFromInt(spherical_shader_face_steps));
                const max_v = @as(f32, @floatFromInt(v_index + 1)) / @as(f32, @floatFromInt(spherical_shader_face_steps));

                const a = cubeFacePointForVertices(vertices, face, min_u, min_v);
                const b = cubeFacePointForVertices(vertices, face, max_u, min_v);
                const c = cubeFacePointForVertices(vertices, face, max_u, max_v);
                const d = cubeFacePointForVertices(vertices, face, min_u, max_v);
                emitShaderQuad(a, b, c, d);
            }
        }
    }
    rlgl.rlEnd();
}

fn drawSphericalCubeEdgesShader() void {
    const vertices = story.cubeVertices();
    rlgl.rlSetLineWidth(1.8);
    rlgl.rlColor4ub(style.white.r, style.white.g, style.white.b, 190);
    rlgl.rlBegin(rlgl.rl_lines);
    for (story.cube_edges) |edge| {
        const a = vertices[edge[0]];
        const b = vertices[edge[1]];
        var i: usize = 0;
        while (i < spherical_shader_edge_steps) : (i += 1) {
            const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(spherical_shader_edge_steps));
            const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(spherical_shader_edge_steps));
            emitShaderVertex(story.Vec3.lerp(a, b, t0));
            emitShaderVertex(story.Vec3.lerp(a, b, t1));
        }
    }
    rlgl.rlEnd();
}

fn cubeFacePointForVertices(vertices: [8]story.Vec3, face: story.Face, u: f32, v: f32) story.Vec3 {
    const a = vertices[face.indices[0]];
    const b = vertices[face.indices[1]];
    const c = vertices[face.indices[2]];
    const d = vertices[face.indices[3]];
    return story.Vec3.lerp(story.Vec3.lerp(a, b, u), story.Vec3.lerp(d, c, u), v);
}

fn emitShaderQuad(a: story.Vec3, b: story.Vec3, c: story.Vec3, d: story.Vec3) void {
    emitShaderVertex(a);
    emitShaderVertex(b);
    emitShaderVertex(c);
    emitShaderVertex(a);
    emitShaderVertex(c);
    emitShaderVertex(d);
}

fn emitShaderVertex(point: story.Vec3) void {
    rlgl.rlVertex3f(point.x, point.y, point.z);
}

fn enableRectScissor(rect: rl.Rectangle) void {
    const screen_h = rl.getScreenHeight();
    const x = draw.toInt(rect.x);
    const y = draw.toInt(rect.y);
    const width = draw.toInt(rect.width);
    const height = draw.toInt(rect.height);

    rlgl.rlEnableScissorTest();
    rlgl.rlScissor(x, screen_h - y - height, width, height);
}

fn drawCube(mode: story.Mode, camera: *const story.Camera, rect: rl.Rectangle, pass: story.Pass, fade: u8) void {
    const vertices = story.cubeVerticesFor(mode, camera.*);
    var rendered: [max_cube_cells]FaceRender = undefined;
    var rendered_count: usize = 0;
    const steps = cubeFaceSteps(mode);

    for (story.cube_faces, 0..) |face, face_index| {
        if (face_index == story.cube_bottom_face_index) continue;
        var u_index: usize = 0;
        while (u_index < steps) : (u_index += 1) {
            var v_index: usize = 0;
            while (v_index < steps) : (v_index += 1) {
                if (rendered_count >= rendered.len) break;

                const min_u = @as(f32, @floatFromInt(u_index)) / @as(f32, @floatFromInt(steps));
                const min_v = @as(f32, @floatFromInt(v_index)) / @as(f32, @floatFromInt(steps));
                const max_u = @as(f32, @floatFromInt(u_index + 1)) / @as(f32, @floatFromInt(steps));
                const max_v = @as(f32, @floatFromInt(v_index + 1)) / @as(f32, @floatFromInt(steps));

                const cell = [_]story.Vec3{
                    cubeFacePoint(mode, camera, vertices, face, min_u, min_v),
                    cubeFacePoint(mode, camera, vertices, face, max_u, min_v),
                    cubeFacePoint(mode, camera, vertices, face, max_u, max_v),
                    cubeFacePoint(mode, camera, vertices, face, min_u, max_v),
                };

                var points: [4]rl.Vector2 = undefined;
                var depth: f32 = 0.0;
                var visible = true;
                for (cell, 0..) |world, point_index| {
                    const projected = story.project(mode, camera, world, rect, pass) orelse {
                        visible = false;
                        break;
                    };
                    points[point_index] = projected.pos;
                    depth += projected.depth;
                }
                if (!visible) continue;
                if (!faceCellLooksRenderable(mode, rect, points, depth / 4.0)) continue;

                const color = style.alpha(face_colors[face_index], fade);
                rendered[rendered_count] = .{
                    .points = points,
                    .depth = depth / 4.0,
                    .color = color,
                };
                rendered_count += 1;
            }
        }
    }

    sortFaces(rendered[0..rendered_count]);
    for (rendered[0..rendered_count]) |face| {
        draw.quad(face.points, face.color);
    }

    for (story.cube_edges) |edge| {
        drawWorldLine(
            mode,
            camera,
            rect,
            vertices[edge[0]],
            vertices[edge[1]],
            style.alpha(style.white, 160),
            2.0,
            pass,
        );
    }
}

fn cubeFaceSteps(mode: story.Mode) usize {
    return switch (mode) {
        .perspective, .isometric => 1,
        .spherical, .hyperbolic => max_cube_face_steps,
    };
}

fn cubeFacePoint(mode: story.Mode, camera: *const story.Camera, vertices: [8]story.Vec3, face: story.Face, u: f32, v: f32) story.Vec3 {
    const a = vertices[face.indices[0]];
    const b = vertices[face.indices[1]];
    const c = vertices[face.indices[2]];
    const d = vertices[face.indices[3]];
    return story.facePoint(mode, camera, a, b, c, d, u, v);
}

fn drawWorldLine(
    mode: story.Mode,
    camera: *const story.Camera,
    rect: rl.Rectangle,
    a: story.Vec3,
    b: story.Vec3,
    color: rl.Color,
    width: f32,
    pass: story.Pass,
) void {
    var previous: ?rl.Vector2 = null;
    const steps = worldLineSteps(mode);
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const world = story.segmentPoint(mode, camera, a, b, t);
        const projected = story.project(mode, camera, world, rect, pass) orelse {
            previous = null;
            continue;
        };
        if (previous) |p| {
            const dx = projected.pos.x - p.x;
            const dy = projected.pos.y - p.y;
            if (dx * dx + dy * dy < maxWorldLineSegmentDistanceSquared(mode, rect)) {
                draw.line(p, projected.pos, width, color);
            }
        }
        previous = projected.pos;
    }
}

fn worldLineSteps(mode: story.Mode) usize {
    return switch (mode) {
        .perspective, .isometric => 32,
        .spherical, .hyperbolic => 96,
    };
}

fn faceCellLooksRenderable(mode: story.Mode, rect: rl.Rectangle, points: [4]rl.Vector2, depth: f32) bool {
    if (!isCurvedMode(mode)) return true;
    if (!std.math.isFinite(depth) or depth < minCurvedFaceDistance(mode)) return false;

    for (points) |point| {
        if (!pointIsFinite(point)) return false;
    }

    const bounds = pointBounds(points);
    const max_dim = @max(rect.width, rect.height);
    if (bounds.max_x < rect.x or bounds.min_x > rect.x + rect.width) return false;
    if (bounds.max_y < rect.y or bounds.min_y > rect.y + rect.height) return false;
    if (bounds.max_x - bounds.min_x > max_dim * 0.45) return false;
    if (bounds.max_y - bounds.min_y > max_dim * 0.45) return false;

    const point_margin = max_dim * 0.12;
    for (points) |point| {
        if (point.x < rect.x - point_margin or point.x > rect.x + rect.width + point_margin) return false;
        if (point.y < rect.y - point_margin or point.y > rect.y + rect.height + point_margin) return false;
    }
    if (!quadHasConsistentWinding(points)) return false;

    const max_edge = max_dim * 0.24;
    const max_edge_squared = max_edge * max_edge;
    if (distanceSquared(points[0], points[1]) > max_edge_squared) return false;
    if (distanceSquared(points[1], points[2]) > max_edge_squared) return false;
    if (distanceSquared(points[2], points[3]) > max_edge_squared) return false;
    if (distanceSquared(points[3], points[0]) > max_edge_squared) return false;

    return true;
}

fn minCurvedFaceDistance(mode: story.Mode) f32 {
    return switch (mode) {
        .perspective, .isometric => 0.0,
        .spherical => 0.28,
        .hyperbolic => 0.20,
    };
}

fn maxWorldLineSegmentDistanceSquared(mode: story.Mode, rect: rl.Rectangle) f32 {
    const max_segment = switch (mode) {
        .perspective, .isometric => 300.0,
        .spherical, .hyperbolic => @max(rect.width, rect.height) * 0.38,
    };
    return max_segment * max_segment;
}

const PointBounds = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
};

fn pointBounds(points: [4]rl.Vector2) PointBounds {
    var bounds = PointBounds{
        .min_x = points[0].x,
        .max_x = points[0].x,
        .min_y = points[0].y,
        .max_y = points[0].y,
    };
    for (points[1..]) |point| {
        bounds.min_x = @min(bounds.min_x, point.x);
        bounds.max_x = @max(bounds.max_x, point.x);
        bounds.min_y = @min(bounds.min_y, point.y);
        bounds.max_y = @max(bounds.max_y, point.y);
    }
    return bounds;
}

fn pointIsFinite(point: rl.Vector2) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn distanceSquared(a: rl.Vector2, b: rl.Vector2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

fn quadHasConsistentWinding(points: [4]rl.Vector2) bool {
    var sign: f32 = 0.0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const a = points[i];
        const b = points[(i + 1) % points.len];
        const c = points[(i + 2) % points.len];
        const cross = cross2(a, b, c);
        if (@abs(cross) <= 1e-3) continue;

        const current_sign: f32 = if (cross > 0.0) 1.0 else -1.0;
        if (sign == 0.0) {
            sign = current_sign;
        } else if (sign != current_sign) {
            return false;
        }
    }
    return sign != 0.0;
}

fn cross2(a: rl.Vector2, b: rl.Vector2, c: rl.Vector2) f32 {
    return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
}

fn isCurvedMode(mode: story.Mode) bool {
    return mode == .spherical or mode == .hyperbolic;
}

fn drawHud(app: *const App, screen: rl.Rectangle) void {
    const camera = app.scene.activeCamera();
    const accent = modeAccent(app.scene.mode);
    const pga_pos = camera.pgaPosition();
    const dist2 = camera.metricDistanceSquaredToCube();
    const curvature = camera.curvatureValue(app.scene.mode);
    const curvature_radius = camera.curvatureRadiusValue(app.scene.mode);

    const hud = rl.Rectangle{ .x = 22.0, .y = 22.0, .width = screen.width - 44.0, .height = 92.0 };
    rl.drawRectangleRec(hud, style.alpha(style.bg_bottom, 198));
    rl.drawRectangleRec(.{ .x = hud.x, .y = hud.y, .width = 8.0, .height = hud.height }, accent);
    rl.drawRectangleLinesEx(hud, 1.0, style.alpha(style.white, 48));

    draw.text(app.scene.mode.label(), hud.x + 24.0, hud.y + 14.0, 30, style.white);
    draw.text(app.scene.mode.flavour(), hud.x + 26.0, hud.y + 52.0, 19, style.alpha(style.white, 190));

    var buf: [256]u8 = undefined;
    draw.textFmt(
        &buf,
        hud.x + hud.width - 560.0,
        hud.y + 16.0,
        18,
        style.alpha(style.white, 210),
        "camera [{d:.2}:{d:.2}:{d:.2}:{d:.2}]  cube d2={d:.2}",
        .{ pga_pos[0], pga_pos[1], pga_pos[2], pga_pos[3], dist2 },
    );
    if (curvature) |k| {
        draw.textFmt(
            &buf,
            hud.x + hud.width - 560.0,
            hud.y + 50.0,
            18,
            style.alpha(style.white, 175),
            "WASD walk   arrows look   E/Q lift   +/- curvature   R={d:.2} K={d:.3}",
            .{ curvature_radius orelse 0.0, k },
        );
    } else {
        draw.text(
            "1-4/Tab view   WASD walk   arrows look   E/Q lift   R reset   P pause",
            hud.x + hud.width - 560.0,
            hud.y + 50.0,
            18,
            style.alpha(style.white, 175),
        );
    }
}

fn sortFaces(faces: []FaceRender) void {
    var i: usize = 1;
    while (i < faces.len) : (i += 1) {
        var j = i;
        while (j > 0 and faces[j - 1].depth < faces[j].depth) : (j -= 1) {
            const tmp = faces[j - 1];
            faces[j - 1] = faces[j];
            faces[j] = tmp;
        }
    }
}

fn modeAccent(mode: story.Mode) rl.Color {
    return switch (mode) {
        .perspective => style.amber,
        .isometric => style.moss,
        .spherical => style.cyan,
        .hyperbolic => style.coral,
    };
}

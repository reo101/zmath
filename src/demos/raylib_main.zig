const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
const projection = zmath.render.projection;
const curved = zmath.geometry.constant_curvature;
const demo = @import("core.zig");

const rl = @cImport({
    @cInclude("raylib.h");
});

const subpixel_x: usize = 2;
const subpixel_y: usize = 4;

const window_width: i32 = 1440;
const window_height: i32 = 900;
const canvas_width: usize = 160;
const canvas_height: usize = 90;

const bg_color = rl.Color{ .r = 7, .g = 9, .b = 16, .a = 255 };
const hud_bg_color = rl.Color{ .r = 14, .g = 20, .b = 30, .a = 228 };
const scene_panel_color = rl.Color{ .r = 12, .g = 16, .b = 24, .a = 255 };
const scene_panel_border = rl.Color{ .r = 44, .g = 60, .b = 84, .a = 255 };
const scene_shadow = rl.Color{ .r = 2, .g = 4, .b = 8, .a = 130 };
const accent_warm = rl.Color{ .r = 255, .g = 176, .b = 124, .a = 70 };
const accent_cool = rl.Color{ .r = 98, .g = 170, .b = 255, .a = 55 };
const white = rl.Color{ .r = 236, .g = 240, .b = 255, .a = 255 };
const hint = rl.Color{ .r = 163, .g = 177, .b = 202, .a = 255 };
const near_marker_color = rl.Color{ .r = 245, .g = 84, .b = 91, .a = 255 };
const far_marker_color = rl.Color{ .r = 102, .g = 214, .b = 145, .a = 255 };
const edge_shadow = rl.Color{ .r = 5, .g = 8, .b = 13, .a = 210 };
const viewport_glow = rl.Color{ .r = 158, .g = 214, .b = 255, .a = 18 };
const native_curved_fill_steps: usize = 12;
const native_curved_edge_steps: usize = 84;
const native_ground_steps: usize = 10;
const spherical_walk_eye_height: f32 = 0.34;
const hyperbolic_walk_eye_height_scale: f32 = 0.28;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = try demo.App.init();
    var canvas = try canvas_api.Canvas.init(allocator, canvas_width, canvas_height);
    defer canvas.deinit();

    const subpixel_width = canvas.width * subpixel_x;
    const subpixel_height = canvas.height * subpixel_y;
    const pixels = try allocator.alloc(rl.Color, subpixel_width * subpixel_height);
    defer allocator.free(pixels);

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(window_width, window_height, "zmath demo (raylib backend)");
    defer rl.CloseWindow();

    rl.SetTargetFPS(30);
    rl.SetExitKey(0);

    const texture_width: c_int = @intCast(subpixel_width);
    const texture_height: c_int = @intCast(subpixel_height);
    const image = rl.Image{
        .data = @ptrCast(pixels.ptr),
        .width = texture_width,
        .height = texture_height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    while (!rl.WindowShouldClose()) {
        if (consumeInput(&app)) break;

        app.tick();
        const frame = app.render(&canvas, canvas.width, canvas.height);
        const viewport = sceneViewportRect();
        const needs_canvas_overlay = isCurvedMode(app.mode);
        if (needs_canvas_overlay) {
            rasterizeCanvas(&canvas, pixels);
            rl.UpdateTexture(texture, @ptrCast(pixels.ptr));
        }

        rl.BeginDrawing();
        defer rl.EndDrawing();

        drawBackdrop();
        drawScenePanel(viewport);

        rl.BeginScissorMode(
            @intFromFloat(@round(viewport.x)),
            @intFromFloat(@round(viewport.y)),
            @intFromFloat(@round(viewport.width)),
            @intFromFloat(@round(viewport.height)),
        );
        if (!drawNativeScene(&app, viewport)) {
            drawCanvasTexture(texture, viewport);
        }
        if (needs_canvas_overlay) {
            drawCurvedNavigatorOverlay(texture, viewport);
        }
        rl.EndScissorMode();

        if (needs_canvas_overlay) {
            drawCurvedNavigatorLabels(viewport);
        }
        drawHud(frame, app.mode);
    }
}

fn consumeInput(app: *demo.App) bool {
    if (keyTriggered(rl.KEY_SPACE) and app.applyCommand(.next_mode)) return true;
    if (keyTriggered(rl.KEY_P) and app.applyCommand(.toggle_animation)) return true;
    if (keyTriggered(rl.KEY_G) and app.applyCommand(.toggle_movement_mode)) return true;
    if (keyTriggered(rl.KEY_V) and app.applyCommand(.cycle_projection)) return true;
    if (keyTriggered(rl.KEY_I)) app.dumpDebugState();

    if ((keyTriggered(rl.KEY_EQUAL) or keyTriggered(rl.KEY_KP_ADD)) and app.applyCommand(.more_curved)) return true;
    if ((keyTriggered(rl.KEY_MINUS) or keyTriggered(rl.KEY_KP_SUBTRACT)) and app.applyCommand(.less_curved)) return true;

    if ((keyTriggered(rl.KEY_Q) or keyTriggered(rl.KEY_ESCAPE)) and app.applyCommand(.quit)) return true;

    const movement = [_]struct { key: c_int, command: demo.Command }{
        .{ .key = rl.KEY_W, .command = .move_forward },
        .{ .key = rl.KEY_A, .command = .move_left },
        .{ .key = rl.KEY_S, .command = .move_backward },
        .{ .key = rl.KEY_D, .command = .move_right },
    };
    for (movement) |entry| {
        if (keyHeld(entry.key) and app.applyCommand(entry.command)) return true;
    }

    const look = [_]struct { key: c_int, command: demo.Command }{
        .{ .key = rl.KEY_UP, .command = .look_up },
        .{ .key = rl.KEY_DOWN, .command = .look_down },
        .{ .key = rl.KEY_LEFT, .command = .look_left },
        .{ .key = rl.KEY_RIGHT, .command = .look_right },
    };
    for (look) |entry| {
        if (keyHeld(entry.key) and app.applyCommand(entry.command)) return true;
    }

    return false;
}

fn keyTriggered(key: c_int) bool {
    return rl.IsKeyPressed(key) or rl.IsKeyPressedRepeat(key);
}

fn keyHeld(key: c_int) bool {
    return rl.IsKeyDown(key) or keyTriggered(key);
}

fn isNativeEuclideanMode(mode: demo.DemoMode) bool {
    return mode == .perspective or mode == .isometric;
}

fn isCurvedMode(mode: demo.DemoMode) bool {
    return mode == .hyperbolic or mode == .spherical;
}

fn sceneViewportRect() rl.Rectangle {
    const hud_height: f32 = 84.0;
    const outer_margin: f32 = 24.0;
    const screen_w = @as(f32, @floatFromInt(rl.GetScreenWidth()));
    const screen_h = @as(f32, @floatFromInt(rl.GetScreenHeight()));
    const available_w = @max(screen_w - outer_margin * 2.0, 1.0);
    const available_h = @max(screen_h - hud_height - outer_margin * 2.0, 1.0);
    const virtual_w = @as(f32, @floatFromInt(canvas_width * subpixel_x));
    const virtual_h = @as(f32, @floatFromInt(canvas_height * subpixel_y));
    const scale = @min(available_w / virtual_w, available_h / virtual_h);

    const draw_w = virtual_w * scale;
    const draw_h = virtual_h * scale;
    const draw_x = (screen_w - draw_w) * 0.5;
    const draw_y = outer_margin + (available_h - draw_h) * 0.5;

    return .{ .x = draw_x, .y = draw_y, .width = draw_w, .height = draw_h };
}

fn drawBackdrop() void {
    const screen_w = rl.GetScreenWidth();
    const screen_h = rl.GetScreenHeight();
    rl.ClearBackground(bg_color);
    rl.DrawRectangleGradientV(0, 0, screen_w, screen_h, rl.Color{ .r = 16, .g = 22, .b = 34, .a = 255 }, bg_color);
    rl.DrawCircleV(.{ .x = @as(f32, @floatFromInt(screen_w)) * 0.18, .y = @as(f32, @floatFromInt(screen_h)) * 0.16 }, @as(f32, @floatFromInt(screen_h)) * 0.19, accent_warm);
    rl.DrawCircleV(.{ .x = @as(f32, @floatFromInt(screen_w)) * 0.82, .y = @as(f32, @floatFromInt(screen_h)) * 0.22 }, @as(f32, @floatFromInt(screen_h)) * 0.22, accent_cool);
}

fn drawScenePanel(viewport: rl.Rectangle) void {
    rl.DrawRectangleRec(
        .{ .x = viewport.x + 12.0, .y = viewport.y + 16.0, .width = viewport.width, .height = viewport.height },
        scene_shadow,
    );
    rl.DrawRectangleRec(
        .{ .x = viewport.x - 10.0, .y = viewport.y - 10.0, .width = viewport.width + 20.0, .height = viewport.height + 20.0 },
        scene_panel_color,
    );
    rl.DrawRectangleLinesEx(
        .{ .x = viewport.x - 10.0, .y = viewport.y - 10.0, .width = viewport.width + 20.0, .height = viewport.height + 20.0 },
        2.0,
        scene_panel_border,
    );
}

fn drawCanvasTexture(texture: rl.Texture2D, viewport: rl.Rectangle) void {
    const texture_w = @as(f32, @floatFromInt(texture.width));
    const texture_h = @as(f32, @floatFromInt(texture.height));

    rl.DrawTexturePro(
        texture,
        .{ .x = 0.0, .y = 0.0, .width = texture_w, .height = texture_h },
        viewport,
        .{ .x = 0.0, .y = 0.0 },
        0.0,
        white,
    );
}

fn drawHud(frame: demo.FrameInfo, mode: demo.DemoMode) void {
    const hud_height: c_int = 76;
    const hud_y = rl.GetScreenHeight() - hud_height;

    rl.DrawRectangle(0, hud_y, rl.GetScreenWidth(), hud_height, hud_bg_color);

    var status_buf: [256]u8 = undefined;
    const status = std.fmt.bufPrintZ(
        &status_buf,
        "{s} Z:{d:.2} C[h/s]:{d:.2}/{d:.2} V:{s} M:{s} K:{s} A:{s}",
        .{
            frame.mode_label,
            frame.zoom,
            frame.hyper_radius,
            frame.spherical_radius,
            frame.projection_label,
            frame.movement_label,
            frame.curvature_notice,
            if (frame.animate) "on" else "off",
        },
    ) catch unreachable;
    rl.DrawText(status.ptr, 12, hud_y + 8, 21, white);

    const help = if (isNativeEuclideanMode(mode))
        "SPC/P/G/V/WASD/Ar/+/-/I/Q | native"
    else
        "SPC/P/G/V/WASD/Ar/+/-/I/Q | nav:right xz/zy";
    rl.DrawText(help, 12, hud_y + 36, 18, hint);
}

const FaceOrder = struct {
    index: usize,
    distance: f32,
};

const CurvedRenderPass = union(enum) {
    direct,
    spherical: curved.SphericalRenderPass,
};

const GroundBasis = struct {
    origin: curved.Vec4,
    right: curved.Vec4,
    forward: curved.Vec4,
};

const NativeFace = struct {
    points: [8]rl.Vector2,
    len: usize,
    avg_depth: f32,
    fill: rl.Color,
    stroke: rl.Color,
};

const ClippedPolygon = struct {
    vertices: [8]demo.H.Vector,
    len: usize,
};

fn canvasPointToViewport(viewport: rl.Rectangle, point: [2]f32) rl.Vector2 {
    const scale_x = viewport.width / @as(f32, @floatFromInt(canvas_width));
    const scale_y = viewport.height / @as(f32, @floatFromInt(canvas_height));
    return .{
        .x = viewport.x + point[0] * scale_x,
        .y = viewport.y + point[1] * scale_y,
    };
}

fn gaCross(a: demo.H.Vector, b: demo.H.Vector) demo.H.Vector {
    return a.wedge(b).dual().negate();
}

fn safeNormalize(v: demo.H.Vector, fallback: demo.H.Vector) demo.H.Vector {
    return demo.H.normalize(v) catch fallback;
}

fn mixColor(a: rl.Color, b: rl.Color, t_raw: f32) rl.Color {
    const t = std.math.clamp(t_raw, 0.0, 1.0);
    const inv_t = 1.0 - t;
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(a.r)) * inv_t + @as(f32, @floatFromInt(b.r)) * t)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(a.g)) * inv_t + @as(f32, @floatFromInt(b.g)) * t)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(a.b)) * inv_t + @as(f32, @floatFromInt(b.b)) * t)),
        .a = @intFromFloat(@round(@as(f32, @floatFromInt(a.a)) * inv_t + @as(f32, @floatFromInt(b.a)) * t)),
    };
}

fn colorWithAlpha(color: rl.Color, alpha: u8) rl.Color {
    var result = color;
    result.a = alpha;
    return result;
}

fn nativeFaceColor(face_index: usize, normal: demo.H.Vector, avg_depth: f32) rl.Color {
    const light = safeNormalize(demo.H.Vector.init(.{ 0.38, 0.79, -0.48 }), demo.H.Vector.init(.{ 0, 1, 0 }));
    const unit_normal = safeNormalize(normal, demo.H.Vector.init(.{ 0, 0, -1 }));
    const lambert = std.math.clamp(unit_normal.scalarProduct(light), 0.0, 1.0);
    const depth_t = std.math.clamp((avg_depth - demo.near_clip_z) / @max(demo.far_clip_z - demo.near_clip_z, 1e-3), 0.0, 1.0);
    const scale = (0.44 + lambert * 0.44) * (0.90 - depth_t * 0.20);
    var fill = scaledToneColor(demo.faceTone(face_index), scale);
    fill = mixColor(fill, white, 0.12 + lambert * 0.10);
    fill.a = 236;
    return fill;
}

fn nativeStrokeColor(fill: rl.Color, avg_depth: f32) rl.Color {
    const depth_t = std.math.clamp((avg_depth - demo.near_clip_z) / @max(demo.far_clip_z - demo.near_clip_z, 1e-3), 0.0, 1.0);
    return colorWithAlpha(mixColor(fill, white, 0.28 - depth_t * 0.10), 255);
}

fn intersectDepth(v0: demo.H.Vector, v1: demo.H.Vector, target_z: f32) demo.H.Vector {
    const z0 = v0.coeffNamed("e3");
    const z1 = v1.coeffNamed("e3");
    const denom = z1 - z0;
    if (@abs(denom) <= 1e-6) return v0;
    const t = (target_z - z0) / denom;
    return v0.scale(1.0 - t).add(v1.scale(t));
}

fn clipPolygonAgainstMinDepth(input: []const demo.H.Vector, output: *[8]demo.H.Vector, min_depth: f32) usize {
    if (input.len == 0) return 0;

    var out_len: usize = 0;
    var prev = input[input.len - 1];
    var prev_inside = prev.coeffNamed("e3") >= min_depth;

    for (input) |curr| {
        const curr_inside = curr.coeffNamed("e3") >= min_depth;
        if (curr_inside != prev_inside) {
            output[out_len] = intersectDepth(prev, curr, min_depth);
            out_len += 1;
        }
        if (curr_inside) {
            output[out_len] = curr;
            out_len += 1;
        }
        prev = curr;
        prev_inside = curr_inside;
    }

    return out_len;
}

fn clipPolygonAgainstMaxDepth(input: []const demo.H.Vector, output: *[8]demo.H.Vector, max_depth: f32) usize {
    if (input.len == 0) return 0;

    var out_len: usize = 0;
    var prev = input[input.len - 1];
    var prev_inside = prev.coeffNamed("e3") <= max_depth;

    for (input) |curr| {
        const curr_inside = curr.coeffNamed("e3") <= max_depth;
        if (curr_inside != prev_inside) {
            output[out_len] = intersectDepth(prev, curr, max_depth);
            out_len += 1;
        }
        if (curr_inside) {
            output[out_len] = curr;
            out_len += 1;
        }
        prev = curr;
        prev_inside = curr_inside;
    }

    return out_len;
}

fn clipFaceToDepthRange(face_vertices: [4]demo.H.Vector) ?ClippedPolygon {
    var a: [8]demo.H.Vector = undefined;
    var b: [8]demo.H.Vector = undefined;
    for (face_vertices, 0..) |vertex, i| a[i] = vertex;

    const near_len = clipPolygonAgainstMinDepth(a[0..face_vertices.len], &b, demo.near_clip_z);
    if (near_len < 3) return null;

    const far_len = clipPolygonAgainstMaxDepth(b[0..near_len], &a, demo.far_clip_z);
    if (far_len < 3) return null;

    return .{ .vertices = a, .len = far_len };
}

fn drawPolygonFan(points: []const rl.Vector2, color: rl.Color) void {
    if (points.len < 3) return;

    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        rl.DrawTriangle(points[0], points[i], points[i + 1], color);
    }
}

fn drawPolygonOutline(points: []const rl.Vector2, line_width: f32, color: rl.Color) void {
    if (points.len < 2) return;

    for (0..points.len) |i| {
        const next = (i + 1) % points.len;
        rl.DrawLineEx(points[i], points[next], line_width, color);
    }
}

fn drawNativeScene(app: *const demo.App, viewport: rl.Rectangle) bool {
    if (isNativeEuclideanMode(app.mode)) {
        drawNativeEuclideanScene(app, viewport);
        return true;
    }

    if (isCurvedMode(app.mode)) {
        drawNativeCurvedScene(app, viewport);
        return true;
    }

    return false;
}

fn drawNativeEuclideanScene(app: *const demo.App, viewport: rl.Rectangle) void {
    const scene = app.euclideanScene() orelse return;

    rl.DrawRectangleGradientV(
        @intFromFloat(@round(viewport.x)),
        @intFromFloat(@round(viewport.y)),
        @intFromFloat(@round(viewport.width)),
        @intFromFloat(@round(viewport.height)),
        rl.Color{ .r = 20, .g = 28, .b = 40, .a = 255 },
        rl.Color{ .r = 8, .g = 12, .b = 20, .a = 255 },
    );
    rl.DrawCircleV(
        .{ .x = viewport.x + viewport.width * 0.68, .y = viewport.y + viewport.height * 0.22 },
        @min(viewport.width, viewport.height) * 0.24,
        viewport_glow,
    );

    var faces: [demo.cube_faces.len]NativeFace = undefined;
    var face_count: usize = 0;

    for (demo.cube_faces, 0..) |face, face_index| {
        const a = scene.view_cube_vertices[face[0]];
        const b = scene.view_cube_vertices[face[1]];
        const c = scene.view_cube_vertices[face[2]];
        const d = scene.view_cube_vertices[face[3]];
        const normal = gaCross(b.sub(a), d.sub(a));
        if (normal.coeffNamed("e3") >= -0.02) continue;

        const clipped = clipFaceToDepthRange(.{ a, b, c, d }) orelse continue;
        var projected: [8]rl.Vector2 = undefined;
        var avg_depth: f32 = 0.0;
        var project_failed = false;
        for (clipped.vertices[0..clipped.len], 0..) |vertex, i| {
            const screen = projection.projectEuclidean(vertex, canvas_width, canvas_height, scene.zoom, scene.projection_mode) orelse {
                project_failed = true;
                break;
            };
            projected[i] = canvasPointToViewport(viewport, screen);
            avg_depth += vertex.coeffNamed("e3");
        }
        if (project_failed) continue;

        avg_depth /= @as(f32, @floatFromInt(clipped.len));
        const fill = nativeFaceColor(face_index, normal, avg_depth);
        faces[face_count] = .{
            .points = projected,
            .len = clipped.len,
            .avg_depth = avg_depth,
            .fill = fill,
            .stroke = nativeStrokeColor(fill, avg_depth),
        };
        face_count += 1;
    }

    for (0..face_count) |i| {
        var best = i;
        for (i + 1..face_count) |j| {
            if (faces[j].avg_depth > faces[best].avg_depth) best = j;
        }
        if (best != i) std.mem.swap(NativeFace, &faces[i], &faces[best]);
    }

    for (faces[0..face_count]) |face| {
        drawPolygonFan(face.points[0..face.len], face.fill);
        drawPolygonOutline(face.points[0..face.len], 3.0, edge_shadow);
        drawPolygonOutline(face.points[0..face.len], 1.2, face.stroke);
    }
}

fn vec3FromVector(v: demo.H.Vector) curved.Vec3 {
    return .{
        v.coeffNamed("e1"),
        v.coeffNamed("e2"),
        v.coeffNamed("e3"),
    };
}

fn lerpVec3(a: curved.Vec3, b: curved.Vec3, t: f32) curved.Vec3 {
    return .{
        a[0] * (1.0 - t) + b[0] * t,
        a[1] * (1.0 - t) + b[1] * t,
        a[2] * (1.0 - t) + b[2] * t,
    };
}

fn bilerpCurvedQuad(a: curved.Vec3, b: curved.Vec3, c: curved.Vec3, d: curved.Vec3, u: f32, v: f32) curved.Vec3 {
    const ab = lerpVec3(a, b, u);
    const dc = lerpVec3(d, c, u);
    return lerpVec3(ab, dc, v);
}

fn mapSphericalPassSample(
    base_view: curved.View,
    pass: curved.SphericalRenderPass,
    sample_in: curved.ProjectedSample,
) curved.ProjectedSample {
    var sample = sample_in;
    if (sample.projected == null or sample.status != .visible) return sample;

    sample.distance = base_view.mapSphericalRenderDistance(pass, sample.distance);
    sample.status = if (sample.distance < base_view.clip.near)
        .clipped_near
    else if (sample.distance > base_view.clip.far)
        .clipped_far
    else
        .visible;
    return sample;
}

fn sortFaceOrders(items: []FaceOrder) void {
    for (0..items.len) |i| {
        var best = i;
        for (i + 1..items.len) |j| {
            if (items[j].distance > items[best].distance) best = j;
        }
        if (best != i) std.mem.swap(FaceOrder, &items[i], &items[best]);
    }
}

fn depthRatio(distance: f32, near_distance: f32, far_distance: f32) f32 {
    const span = @max(far_distance - near_distance, 1e-3);
    return std.math.clamp((distance - near_distance) / span, 0.0, 1.0);
}

fn nativeCurvedFillColor(metric: curved.Metric, face_index: usize, distance: f32, near_distance: f32, far_distance: f32) rl.Color {
    const tint = if (metric == .spherical) accent_cool else accent_warm;
    const t = depthRatio(distance, near_distance, far_distance);
    var fill = scaledToneColor(demo.faceTone(face_index), 0.86 - t * 0.34);
    fill = mixColor(fill, tint, 0.16);
    fill = mixColor(fill, white, 0.10);
    fill.a = 208;
    return fill;
}

fn nativeCurvedStrokeColor(metric: curved.Metric, face_index: usize, distance: f32, near_distance: f32, far_distance: f32) rl.Color {
    const base = nativeCurvedFillColor(metric, face_index, distance, near_distance, far_distance);
    const t = depthRatio(distance, near_distance, far_distance);
    return colorWithAlpha(mixColor(base, white, 0.34 - t * 0.12), 255);
}

fn sampleForCurvedRender(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    chart: curved.Vec3,
    screen: curved.Screen,
) curved.ProjectedSample {
    var sample = render_view.sampleProjectedPoint(chart, screen);
    switch (render_pass) {
        .direct => {},
        .spherical => |pass| sample = mapSphericalPassSample(base_view, pass, sample),
    }
    return sample;
}

fn sampleSphericalLocalPoint(
    base_view: curved.View,
    render_view: curved.View,
    pass: curved.SphericalRenderPass,
    local: curved.Vec3,
    screen: curved.Screen,
) curved.ProjectedSample {
    _ = render_view;
    const ambient = curved.sphericalAmbientFromGroundHeightPoint(base_view.params, local);
    return base_view.sampleProjectedAmbientForSphericalPass(pass, ambient, screen);
}

fn walkEyeHeight(view: curved.View) f32 {
    return switch (view.metric) {
        .hyperbolic => view.params.radius * hyperbolic_walk_eye_height_scale,
        .elliptic, .spherical => spherical_walk_eye_height,
    };
}

fn liftedWalkView(view: curved.View) curved.View {
    const basis = view.walkBasis() orelse return view;
    var lifted = view;
    curved.moveAlongDirection(
        &lifted.camera,
        view.metric,
        view.params,
        basis.up,
        walkEyeHeight(view),
    );
    return lifted;
}

fn worldGroundBasis(metric: curved.Metric) GroundBasis {
    _ = metric;
    return .{
        .origin = .{ 1.0, 0.0, 0.0, 0.0 },
        .right = .{ 0.0, 1.0, 0.0, 0.0 },
        .forward = .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

fn groundSampleForCurvedRender(
    surface_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    lateral: f32,
    forward_distance: f32,
    screen: curved.Screen,
) curved.ProjectedSample {
    const ambient = curved.ambientFromTangentBasisPoint(
        surface_view.metric,
        surface_view.params,
        basis.origin,
        basis.right,
        basis.forward,
        lateral,
        forward_distance,
    ) orelse return .{};

    return switch (render_pass) {
        .direct => render_view.sampleProjectedAmbient(ambient, screen),
        .spherical => |pass| render_view.sampleProjectedAmbientForSphericalPass(pass, ambient, screen),
    };
}

fn groundFillColor(metric: curved.Metric, distance: f32, near_distance: f32, far_distance: f32, checker: bool) rl.Color {
    const base = switch (metric) {
        .hyperbolic => rl.Color{ .r = 58, .g = 40, .b = 48, .a = 255 },
        .elliptic, .spherical => rl.Color{ .r = 36, .g = 72, .b = 64, .a = 255 },
    };
    const tint = if (metric == .spherical) accent_cool else accent_warm;
    const depth_t = depthRatio(distance, near_distance, far_distance);
    var fill = mixColor(base, tint, 0.08 + depth_t * 0.10);
    fill = mixColor(fill, white, if (checker) 0.05 else 0.02);
    fill.a = 226;
    return fill;
}

fn groundStrokeColor(fill: rl.Color) rl.Color {
    return colorWithAlpha(mixColor(fill, white, 0.16), 44);
}

fn groundExtent(view: curved.View) f32 {
    return switch (view.metric) {
        .hyperbolic => view.params.radius * 2.35,
        .elliptic, .spherical => view.params.radius * 1.65,
    };
}

fn drawCurvedGroundPatch(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    viewport: rl.Rectangle,
) void {
    const basis = worldGroundBasis(world_view.metric);
    const lateral_extent = groundExtent(world_view) * 1.45;
    const forward_extent = lateral_extent;
    const far_distance = render_view.shadeFarDistance();

    for (0..native_ground_steps) |ui| {
        const u_t0 = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(native_ground_steps));
        const u_t1 = @as(f32, @floatFromInt(ui + 1)) / @as(f32, @floatFromInt(native_ground_steps));
        const x0 = (u_t0 * 2.0 - 1.0) * lateral_extent;
        const x1 = (u_t1 * 2.0 - 1.0) * lateral_extent;

        for (0..native_ground_steps) |vi| {
            const v_t0 = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(native_ground_steps));
            const v_t1 = @as(f32, @floatFromInt(vi + 1)) / @as(f32, @floatFromInt(native_ground_steps));
            const z0 = (v_t0 * 2.0 - 1.0) * forward_extent;
            const z1 = (v_t1 * 2.0 - 1.0) * forward_extent;

            const s00 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x0, z0, screen);
            const s10 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x1, z0, screen);
            const s11 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x1, z1, screen);
            const s01 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x0, z1, screen);

            if (s00.status != .visible or s10.status != .visible or s11.status != .visible or s01.status != .visible) continue;
            if (s00.projected == null or s10.projected == null or s11.projected == null or s01.projected == null) continue;

            const p00 = s00.projected.?;
            const p10 = s10.projected.?;
            const p11 = s11.projected.?;
            const p01 = s01.projected.?;
            if (curved.shouldBreakProjectedSegment(render_view.projection, p00, p10, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p10, p11, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p11, p01, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p01, p00, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p00, p11, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p10, p01, screen.width, screen.height))
            {
                continue;
            }

            const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
            const fill = groundFillColor(render_view.metric, avg_distance, render_view.clip.near, far_distance, ((ui + vi) & 1) == 0);
            const stroke = groundStrokeColor(fill);
            const poly = [_]rl.Vector2{
                canvasPointToViewport(viewport, p00),
                canvasPointToViewport(viewport, p10),
                canvasPointToViewport(viewport, p11),
                canvasPointToViewport(viewport, p01),
            };
            drawPolygonFan(poly[0..], fill);
            drawPolygonOutline(poly[0..], 0.8, stroke);
        }
    }
}

fn drawCurvedSegment(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    viewport: rl.Rectangle,
    a: curved.Vec3,
    b: curved.Vec3,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;
    var prev_distance: f32 = 0.0;
    const far_distance = base_view.shadeFarDistance();

    for (0..native_curved_edge_steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(native_curved_edge_steps));
        const chart = curved.geodesicChartPoint(base_view.metric, base_view.params, a, b, t) orelse {
            prev_point = null;
            continue;
        };
        const sample = sampleForCurvedRender(base_view, render_view, render_pass, chart, screen);
        if (sample.status != .visible or sample.projected == null) {
            prev_point = null;
            continue;
        }

        if (prev_point) |prev| {
            const point = sample.projected.?;
            if (!curved.shouldBreakProjectedSegment(render_view.projection, prev, point, screen.width, screen.height)) {
                const avg_distance = (prev_distance + sample.distance) * 0.5;
                const scale = 0.96 - depthRatio(avg_distance, base_view.clip.near, far_distance) * 0.28;
                const edge = mixColor(scaledToneColor(tone, scale), white, 0.24);
                const p0 = canvasPointToViewport(viewport, prev);
                const p1 = canvasPointToViewport(viewport, point);
                rl.DrawLineEx(p0, p1, 3.0, edge_shadow);
                rl.DrawLineEx(p0, p1, 1.35, edge);
            }
        }

        prev_point = sample.projected;
        prev_distance = sample.distance;
    }
}

fn drawCurvedFaceGrid(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    viewport: rl.Rectangle,
    quad: [4]curved.Vec3,
    face_index: usize,
) void {
    const grid_side = native_curved_fill_steps + 1;
    var samples: [grid_side * grid_side]curved.ProjectedSample = undefined;

    for (0..grid_side) |ui| {
        const u = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(native_curved_fill_steps));
        for (0..grid_side) |vi| {
            const v = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(native_curved_fill_steps));
            samples[ui * grid_side + vi] = sampleForCurvedRender(
                base_view,
                render_view,
                render_pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], u, v),
                screen,
            );
        }
    }

    const far_distance = base_view.shadeFarDistance();
    for (0..native_curved_fill_steps) |ui| {
        for (0..native_curved_fill_steps) |vi| {
            const s00 = samples[ui * grid_side + vi];
            const s10 = samples[(ui + 1) * grid_side + vi];
            const s11 = samples[(ui + 1) * grid_side + (vi + 1)];
            const s01 = samples[ui * grid_side + (vi + 1)];
            if (s00.status != .visible or s10.status != .visible or s11.status != .visible or s01.status != .visible) continue;
            if (s00.projected == null or s10.projected == null or s11.projected == null or s01.projected == null) continue;

            const p00 = s00.projected.?;
            const p10 = s10.projected.?;
            const p11 = s11.projected.?;
            const p01 = s01.projected.?;
            if (curved.shouldBreakProjectedSegment(render_view.projection, p00, p10, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p10, p11, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p11, p01, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p01, p00, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p00, p11, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p10, p01, screen.width, screen.height))
            {
                continue;
            }

            const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
            const fill = nativeCurvedFillColor(base_view.metric, face_index, avg_distance, base_view.clip.near, far_distance);
            const stroke = nativeCurvedStrokeColor(base_view.metric, face_index, avg_distance, base_view.clip.near, far_distance);

            const v00 = canvasPointToViewport(viewport, p00);
            const v10 = canvasPointToViewport(viewport, p10);
            const v11 = canvasPointToViewport(viewport, p11);
            const v01 = canvasPointToViewport(viewport, p01);
            rl.DrawTriangle(v00, v10, v11, fill);
            rl.DrawTriangle(v00, v11, v01, fill);
            rl.DrawLineEx(v00, v10, 0.8, colorWithAlpha(stroke, 34));
            rl.DrawLineEx(v10, v11, 0.8, colorWithAlpha(stroke, 34));
            rl.DrawLineEx(v11, v01, 0.8, colorWithAlpha(stroke, 34));
            rl.DrawLineEx(v01, v00, 0.8, colorWithAlpha(stroke, 34));
        }
    }
}

fn faceOrderDistance(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    quad: [4]curved.Vec3,
) f32 {
    const center = bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], 0.5, 0.5);
    const center_sample = sampleForCurvedRender(base_view, render_view, render_pass, center, screen);
    if (center_sample.status == .visible) return center_sample.distance;

    var total: f32 = 0.0;
    var count: usize = 0;
    for (quad) |vertex| {
        const sample = sampleForCurvedRender(base_view, render_view, render_pass, vertex, screen);
        if (sample.status == .visible) {
            total += sample.distance;
            count += 1;
        }
    }
    if (count > 0) return total / @as(f32, @floatFromInt(count));
    return 0.0;
}

fn drawCurvedSceneBackdrop(view: curved.View, viewport: rl.Rectangle) void {
    const top_color = if (view.metric == .spherical)
        rl.Color{ .r = 18, .g = 34, .b = 54, .a = 255 }
    else
        rl.Color{ .r = 32, .g = 20, .b = 28, .a = 255 };
    const bottom_color = if (view.metric == .spherical)
        rl.Color{ .r = 7, .g = 12, .b = 22, .a = 255 }
    else
        rl.Color{ .r = 10, .g = 8, .b = 16, .a = 255 };

    rl.DrawRectangleGradientV(
        @intFromFloat(@round(viewport.x)),
        @intFromFloat(@round(viewport.y)),
        @intFromFloat(@round(viewport.width)),
        @intFromFloat(@round(viewport.height)),
        top_color,
        bottom_color,
    );
    rl.DrawCircleV(
        .{
            .x = viewport.x + viewport.width * (if (view.metric == .spherical) @as(f32, 0.76) else @as(f32, 0.24)),
            .y = viewport.y + viewport.height * 0.18,
        },
        @min(viewport.width, viewport.height) * 0.22,
        if (view.metric == .spherical) accent_cool else accent_warm,
    );
}

fn drawCurvedSceneGeometry(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    chart_vertices: []const demo.H.Vector,
    faces: []const [4]usize,
    edges: []const [2]usize,
    viewport: rl.Rectangle,
) void {
    var order: [6]FaceOrder = undefined;
    std.debug.assert(faces.len <= order.len);
    for (faces, 0..) |face, i| {
        const quad = .{
            vec3FromVector(chart_vertices[face[0]]),
            vec3FromVector(chart_vertices[face[1]]),
            vec3FromVector(chart_vertices[face[2]]),
            vec3FromVector(chart_vertices[face[3]]),
        };
        order[i] = .{ .index = i, .distance = faceOrderDistance(base_view, render_view, render_pass, screen, quad) };
    }
    sortFaceOrders(order[0..faces.len]);

    for (order[0..faces.len]) |entry| {
        const face = faces[entry.index];
        drawCurvedFaceGrid(
            base_view,
            render_view,
            render_pass,
            screen,
            viewport,
            .{
                vec3FromVector(chart_vertices[face[0]]),
                vec3FromVector(chart_vertices[face[1]]),
                vec3FromVector(chart_vertices[face[2]]),
                vec3FromVector(chart_vertices[face[3]]),
            },
            entry.index,
        );
    }

    for (edges, 0..) |edge, i| {
        drawCurvedSegment(
            base_view,
            render_view,
            render_pass,
            screen,
            viewport,
            vec3FromVector(chart_vertices[edge[0]]),
            vec3FromVector(chart_vertices[edge[1]]),
            demo.faceTone(i),
        );
    }
}

fn sphericalLocalFaceOrderDistance(
    base_view: curved.View,
    render_view: curved.View,
    pass: curved.SphericalRenderPass,
    screen: curved.Screen,
    quad: [4]curved.Vec3,
) f32 {
    const center = bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], 0.5, 0.5);
    const center_sample = sampleSphericalLocalPoint(base_view, render_view, pass, center, screen);
    if (center_sample.status == .visible) return center_sample.distance;

    var total: f32 = 0.0;
    var count: usize = 0;
    for (quad) |vertex| {
        const sample = sampleSphericalLocalPoint(base_view, render_view, pass, vertex, screen);
        if (sample.status == .visible) {
            total += sample.distance;
            count += 1;
        }
    }
    if (count > 0) return total / @as(f32, @floatFromInt(count));
    return 0.0;
}

fn drawSphericalLocalFaceGrid(
    base_view: curved.View,
    render_view: curved.View,
    pass: curved.SphericalRenderPass,
    screen: curved.Screen,
    viewport: rl.Rectangle,
    quad: [4]curved.Vec3,
    face_index: usize,
) void {
    const grid_side = native_curved_fill_steps + 1;
    var samples: [grid_side * grid_side]curved.ProjectedSample = undefined;

    for (0..grid_side) |ui| {
        const u = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(native_curved_fill_steps));
        for (0..grid_side) |vi| {
            const v = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(native_curved_fill_steps));
            samples[ui * grid_side + vi] = sampleSphericalLocalPoint(
                base_view,
                render_view,
                pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], u, v),
                screen,
            );
        }
    }

    const far_distance = base_view.shadeFarDistance();
    for (0..native_curved_fill_steps) |ui| {
        for (0..native_curved_fill_steps) |vi| {
            const s00 = samples[ui * grid_side + vi];
            const s10 = samples[(ui + 1) * grid_side + vi];
            const s11 = samples[(ui + 1) * grid_side + (vi + 1)];
            const s01 = samples[ui * grid_side + (vi + 1)];
            if (s00.status != .visible or s10.status != .visible or s11.status != .visible or s01.status != .visible) continue;
            if (s00.projected == null or s10.projected == null or s11.projected == null or s01.projected == null) continue;

            const p00 = s00.projected.?;
            const p10 = s10.projected.?;
            const p11 = s11.projected.?;
            const p01 = s01.projected.?;
            const u_mid = (@as(f32, @floatFromInt(ui)) + 0.5) / @as(f32, @floatFromInt(native_curved_fill_steps));
            const v_mid = (@as(f32, @floatFromInt(vi)) + 0.5) / @as(f32, @floatFromInt(native_curved_fill_steps));
            const center = sampleSphericalLocalPoint(
                base_view,
                render_view,
                pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], u_mid, v_mid),
                screen,
            );
            const top_mid = sampleSphericalLocalPoint(
                base_view,
                render_view,
                pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], u_mid, @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(native_curved_fill_steps))),
                screen,
            );
            const right_mid = sampleSphericalLocalPoint(
                base_view,
                render_view,
                pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], @as(f32, @floatFromInt(ui + 1)) / @as(f32, @floatFromInt(native_curved_fill_steps)), v_mid),
                screen,
            );
            const bottom_mid = sampleSphericalLocalPoint(
                base_view,
                render_view,
                pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], u_mid, @as(f32, @floatFromInt(vi + 1)) / @as(f32, @floatFromInt(native_curved_fill_steps))),
                screen,
            );
            const left_mid = sampleSphericalLocalPoint(
                base_view,
                render_view,
                pass,
                bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(native_curved_fill_steps)), v_mid),
                screen,
            );
            if (center.status != .visible or top_mid.status != .visible or right_mid.status != .visible or bottom_mid.status != .visible or left_mid.status != .visible) continue;
            if (center.projected == null or top_mid.projected == null or right_mid.projected == null or bottom_mid.projected == null or left_mid.projected == null) continue;
            if (curved.shouldBreakProjectedSegment(render_view.projection, p00, p10, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p10, p11, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p11, p01, screen.width, screen.height) or
                curved.shouldBreakProjectedSegment(render_view.projection, p01, p00, screen.width, screen.height))
            {
                continue;
            }

            const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
            const fill = nativeCurvedFillColor(base_view.metric, face_index, avg_distance, base_view.clip.near, far_distance);
            const stroke = nativeCurvedStrokeColor(base_view.metric, face_index, avg_distance, base_view.clip.near, far_distance);
            const poly = [_]rl.Vector2{
                canvasPointToViewport(viewport, p00),
                canvasPointToViewport(viewport, p10),
                canvasPointToViewport(viewport, p11),
                canvasPointToViewport(viewport, p01),
            };
            drawPolygonFan(poly[0..], fill);
            drawPolygonOutline(poly[0..], 1.1, colorWithAlpha(stroke, 96));
        }
    }
}

fn drawSphericalLocalSegment(
    base_view: curved.View,
    render_view: curved.View,
    pass: curved.SphericalRenderPass,
    screen: curved.Screen,
    viewport: rl.Rectangle,
    a: curved.Vec3,
    b: curved.Vec3,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;
    var prev_distance: f32 = 0.0;
    const far_distance = base_view.shadeFarDistance();

    for (0..native_curved_edge_steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(native_curved_edge_steps));
        const sample = sampleSphericalLocalPoint(base_view, render_view, pass, lerpVec3(a, b, t), screen);
        if (sample.status != .visible or sample.projected == null) {
            prev_point = null;
            continue;
        }

        if (prev_point) |prev| {
            const point = sample.projected.?;
            if (!curved.shouldBreakProjectedSegment(render_view.projection, prev, point, screen.width, screen.height)) {
                const avg_distance = (prev_distance + sample.distance) * 0.5;
                const scale = 0.96 - depthRatio(avg_distance, base_view.clip.near, far_distance) * 0.28;
                const edge = mixColor(scaledToneColor(tone, scale), white, 0.24);
                const p0 = canvasPointToViewport(viewport, prev);
                const p1 = canvasPointToViewport(viewport, point);
                rl.DrawLineEx(p0, p1, 3.0, edge_shadow);
                rl.DrawLineEx(p0, p1, 1.35, edge);
            }
        }

        prev_point = sample.projected;
        prev_distance = sample.distance;
    }
}

fn drawSphericalLocalGeometry(
    base_view: curved.View,
    render_view: curved.View,
    pass: curved.SphericalRenderPass,
    screen: curved.Screen,
    local_vertices: []const demo.H.Vector,
    faces: []const [4]usize,
    edges: []const [2]usize,
    viewport: rl.Rectangle,
) void {
    var order: [6]FaceOrder = undefined;
    std.debug.assert(faces.len <= order.len);
    for (faces, 0..) |face, i| {
        const quad = .{
            vec3FromVector(local_vertices[face[0]]),
            vec3FromVector(local_vertices[face[1]]),
            vec3FromVector(local_vertices[face[2]]),
            vec3FromVector(local_vertices[face[3]]),
        };
        order[i] = .{ .index = i, .distance = sphericalLocalFaceOrderDistance(base_view, render_view, pass, screen, quad) };
    }
    sortFaceOrders(order[0..faces.len]);

    for (order[0..faces.len]) |entry| {
        const face = faces[entry.index];
        drawSphericalLocalFaceGrid(
            base_view,
            render_view,
            pass,
            screen,
            viewport,
            .{
                vec3FromVector(local_vertices[face[0]]),
                vec3FromVector(local_vertices[face[1]]),
                vec3FromVector(local_vertices[face[2]]),
                vec3FromVector(local_vertices[face[3]]),
            },
            entry.index,
        );
    }

    for (edges, 0..) |edge, i| {
        drawSphericalLocalSegment(
            base_view,
            render_view,
            pass,
            screen,
            viewport,
            vec3FromVector(local_vertices[edge[0]]),
            vec3FromVector(local_vertices[edge[1]]),
            demo.faceTone(i),
        );
    }
}

fn drawNativeCurvedScene(app: *const demo.App, viewport: rl.Rectangle) void {
    const scene = demo.curvedScene(app.*, canvas_width, canvas_height) orelse return;

    switch (scene) {
        .hyperbolic => |hyper| {
            const render_view = if (app.camera.movement_mode == .walk) liftedWalkView(hyper.view) else hyper.view;
            drawCurvedSceneBackdrop(render_view, viewport);
            if (app.camera.movement_mode == .walk) {
                drawCurvedGroundPatch(
                    hyper.view,
                    render_view,
                    .direct,
                    hyper.screen,
                    viewport,
                );
            }
            drawCurvedSceneGeometry(
                render_view,
                render_view,
                .direct,
                hyper.screen,
                hyper.chart_vertices[0..],
                demo.hyperbolic_prism_side_faces[0..],
                demo.hyperbolic_prism_edges[0..],
                viewport,
            );
        },
        .spherical => |spherical| {
            const render_view = if (app.camera.movement_mode == .walk) liftedWalkView(spherical.view) else spherical.view;
            drawCurvedSceneBackdrop(render_view, viewport);
            const far_view = render_view.sphericalRenderPass(.far);
            if (app.camera.movement_mode == .walk) {
                drawCurvedGroundPatch(
                    spherical.view,
                    render_view,
                    .{ .spherical = .near },
                    spherical.screen,
                    viewport,
                );
            }
            drawSphericalLocalGeometry(
                render_view,
                far_view,
                .far,
                spherical.screen,
                spherical.local_vertices[0..],
                demo.cube_faces[0..],
                demo.cube_edges[0..],
                viewport,
            );
            const near_view = render_view.sphericalRenderPass(.near);
            drawSphericalLocalGeometry(
                render_view,
                near_view,
                .near,
                spherical.screen,
                spherical.local_vertices[0..],
                demo.cube_faces[0..],
                demo.cube_edges[0..],
                viewport,
            );
        },
    }
}

const NavigatorRegion = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

fn curvedNavigatorRegion() ?NavigatorRegion {
    if (canvas_width < 54 or canvas_height < 26) return null;

    const panel_width = @min(@as(usize, 26), @max(@as(usize, 18), canvas_width / 4));
    const panel_height = @min(@as(usize, 10), @max(@as(usize, 7), canvas_height / 5));
    const margin: usize = 2;
    const gap: usize = 2;
    const total_height = panel_height *| 2 +| gap;
    if (panel_width +| margin >= canvas_width or total_height +| margin *| 2 >= canvas_height) return null;

    return .{
        .x = canvas_width - panel_width - margin,
        .y = margin,
        .width = panel_width,
        .height = total_height,
    };
}

fn drawCurvedNavigatorOverlay(texture: rl.Texture2D, viewport: rl.Rectangle) void {
    const region = curvedNavigatorRegion() orelse return;
    const src = rl.Rectangle{
        .x = @floatFromInt(region.x * subpixel_x),
        .y = @floatFromInt(region.y * subpixel_y),
        .width = @floatFromInt(region.width * subpixel_x),
        .height = @floatFromInt(region.height * subpixel_y),
    };
    const top_left = canvasPointToViewport(viewport, .{ @floatFromInt(region.x), @floatFromInt(region.y) });
    const bottom_right = canvasPointToViewport(viewport, .{ @floatFromInt(region.x + region.width), @floatFromInt(region.y + region.height) });
    const dest = rl.Rectangle{
        .x = top_left.x,
        .y = top_left.y,
        .width = bottom_right.x - top_left.x,
        .height = bottom_right.y - top_left.y,
    };

    rl.DrawRectangleRec(
        .{ .x = dest.x + 8.0, .y = dest.y + 10.0, .width = dest.width, .height = dest.height },
        colorWithAlpha(scene_shadow, 180),
    );
    rl.DrawTexturePro(texture, src, dest, .{ .x = 0.0, .y = 0.0 }, 0.0, white);
}

fn drawNavigatorLabel(label: [:0]const u8, anchor: rl.Vector2) void {
    const font_size: c_int = 15;
    const pad_x: c_int = 7;
    const pad_y: c_int = 4;
    const text_width = rl.MeasureText(label.ptr, font_size);
    const x = @as(c_int, @intFromFloat(@round(anchor.x)));
    const y = @as(c_int, @intFromFloat(@round(anchor.y)));
    const rect_w = text_width + pad_x * 2;
    const rect_h = font_size + pad_y * 2;
    rl.DrawRectangle(x, y, rect_w, rect_h, rl.Color{ .r = 10, .g = 16, .b = 25, .a = 210 });
    rl.DrawRectangleLines(x, y, rect_w, rect_h, rl.Color{ .r = 52, .g = 72, .b = 102, .a = 255 });
    rl.DrawText(label.ptr, x + pad_x, y + pad_y, font_size, white);
}

fn drawCurvedNavigatorLabels(viewport: rl.Rectangle) void {
    const region = curvedNavigatorRegion() orelse return;
    const panel_height = @min(@as(usize, 10), @max(@as(usize, 7), canvas_height / 5));
    const gap: usize = 2;
    const panel_x = region.x;
    const top_y = region.y;
    const bottom_y = top_y + panel_height + gap;

    const top_anchor = canvasPointToViewport(viewport, .{ @floatFromInt(panel_x), @floatFromInt(top_y) });
    const bottom_anchor = canvasPointToViewport(viewport, .{ @floatFromInt(panel_x), @floatFromInt(bottom_y) });
    drawNavigatorLabel("XZ", .{ .x = top_anchor.x + 10.0, .y = top_anchor.y + 10.0 });
    drawNavigatorLabel("ZY", .{ .x = bottom_anchor.x + 10.0, .y = bottom_anchor.y + 10.0 });
}

fn rasterizeCanvas(canvas: *const canvas_api.Canvas, pixels: []rl.Color) void {
    const subpixel_width = canvas.width * subpixel_x;
    const subpixel_height = canvas.height * subpixel_y;
    std.debug.assert(pixels.len == subpixel_width * subpixel_height);

    @memset(pixels, bg_color);

    for (0..canvas.height) |cell_y| {
        for (0..canvas.width) |cell_x| {
            const cell_idx = cell_y * canvas.width + cell_x;
            const fill_shade = canvas.fill_shades[cell_idx];
            if (fill_shade > 0) {
                const fill_scale = (@as(f32, @floatFromInt(fill_shade)) / 4.0) * 0.82;
                const fill_color = scaledToneColor(canvas.fill_tones[cell_idx], fill_scale);
                for (0..subpixel_y) |sy| {
                    const py = cell_y * subpixel_y + sy;
                    for (0..subpixel_x) |sx| {
                        const px = cell_x * subpixel_x + sx;
                        blendMax(&pixels[py * subpixel_width + px], fill_color);
                    }
                }
            }
        }
    }

    for (0..subpixel_height) |sub_y| {
        for (0..subpixel_width) |sub_x| {
            const idx = sub_y * subpixel_width + sub_x;
            const intensity = canvas.subpixels[idx];
            if (intensity == 0) continue;
            const scale = @as(f32, @floatFromInt(intensity)) / 4.0;
            const line_color = scaledToneColor(canvas.tones[idx], scale);
            blendMax(&pixels[idx], line_color);
        }
    }

    for (0..canvas.height) |cell_y| {
        for (0..canvas.width) |cell_x| {
            const cell_idx = cell_y * canvas.width + cell_x;
            const marker = @as(canvas_api.MarkerColor, @enumFromInt(canvas.markers[cell_idx]));
            if (marker == .none) continue;

            const marker_color = switch (marker) {
                .none => unreachable,
                .near => near_marker_color,
                .far => far_marker_color,
            };

            const start_x = cell_x * subpixel_x;
            const start_y = cell_y * subpixel_y + 1;
            for (0..subpixel_x) |dx| {
                const px = start_x + dx;
                const py = @min(start_y, subpixel_height - 1);
                blendMax(&pixels[py * subpixel_width + px], marker_color);
            }
        }
    }
}

fn blendMax(dst: *rl.Color, src: rl.Color) void {
    dst.r = @max(dst.r, src.r);
    dst.g = @max(dst.g, src.g);
    dst.b = @max(dst.b, src.b);
    dst.a = 255;
}

fn scaledToneColor(tone: u8, scale: f32) rl.Color {
    const base = ansi256ToRgb(tone);
    const clamped = std.math.clamp(scale, 0.0, 1.0);
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(base[0])) * clamped)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(base[1])) * clamped)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(base[2])) * clamped)),
        .a = 255,
    };
}

fn ansi256ToRgb(index: u8) [3]u8 {
    if (index < 16) {
        return ansi_16_palette[index];
    }

    if (index < 232) {
        const adjusted = index - 16;
        const r = adjusted / 36;
        const g = (adjusted % 36) / 6;
        const b = adjusted % 6;
        return .{ cubeComponent(r), cubeComponent(g), cubeComponent(b) };
    }

    const gray = 8 + (index - 232) * 10;
    return .{ gray, gray, gray };
}

fn cubeComponent(level: u8) u8 {
    return if (level == 0) 0 else @as(u8, @intCast(55 + @as(u16, level) * 40));
}

const ansi_16_palette = [_][3]u8{
    .{ 0x00, 0x00, 0x00 },
    .{ 0x80, 0x00, 0x00 },
    .{ 0x00, 0x80, 0x00 },
    .{ 0x80, 0x80, 0x00 },
    .{ 0x00, 0x00, 0x80 },
    .{ 0x80, 0x00, 0x80 },
    .{ 0x00, 0x80, 0x80 },
    .{ 0xc0, 0xc0, 0xc0 },
    .{ 0x80, 0x80, 0x80 },
    .{ 0xff, 0x00, 0x00 },
    .{ 0x00, 0xff, 0x00 },
    .{ 0xff, 0xff, 0x00 },
    .{ 0x5c, 0x5c, 0xff },
    .{ 0xff, 0x00, 0xff },
    .{ 0x00, 0xff, 0xff },
    .{ 0xff, 0xff, 0xff },
};

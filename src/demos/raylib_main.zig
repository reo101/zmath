const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
const projection = zmath.render.projection;
const sdf = zmath.render.sdf;
const curved = zmath.geometry.constant_curvature;
const demo = @import("core.zig");
const euclidean_sdf_renderer = @import("euclidean_sdf.zig");

const rl = @cImport({
    @cInclude("raylib.h");
});

const subpixel_x: usize = 2;
const subpixel_y: usize = 4;
const euclidean_sdf_scale_x: usize = 1;
const euclidean_sdf_scale_y: usize = 2;

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
const native_ground_steps: usize = 12;
const native_ground_subdivide_depth: usize = 2;
const spherical_ground_radial_steps: usize = 4;
const spherical_ground_angular_steps: usize = 12;
const spherical_ground_subdivide_depth: usize = 0;
const spherical_ground_screen_scale_x: usize = 2;
const spherical_ground_screen_scale_y: usize = 2;
const hyperbolic_walk_eye_height_scale: f32 = 0.28;
const spherical_walk_eye_height_scale: f32 = 0.035;

const BenchmarkSlot = enum {
    app_render,
    rasterize,
    native_scene,
    navigator,
    hud,
    spherical_backdrop,
    spherical_ground,
    spherical_geometry_near,
    spherical_geometry_far,
};

const BenchmarkState = struct {
    warmup_frames: usize,
    measured_frames: usize,
    frame_index: usize = 0,
    app_render_ns: u64 = 0,
    rasterize_ns: u64 = 0,
    native_scene_ns: u64 = 0,
    navigator_ns: u64 = 0,
    hud_ns: u64 = 0,
    spherical_backdrop_ns: u64 = 0,
    spherical_ground_ns: u64 = 0,
    spherical_geometry_near_ns: u64 = 0,
    spherical_geometry_far_ns: u64 = 0,

    fn isMeasuring(self: BenchmarkState) bool {
        return self.frame_index >= self.warmup_frames and self.frame_index < self.warmup_frames + self.measured_frames;
    }

    fn isDone(self: BenchmarkState) bool {
        return self.frame_index >= self.warmup_frames + self.measured_frames;
    }
};

var active_benchmark: ?*BenchmarkState = null;

fn benchStart() ?f64 {
    if (active_benchmark == null) return null;
    return rl.GetTime();
}

fn benchAdd(slot: BenchmarkSlot, start: ?f64) void {
    const start_time = start orelse return;
    const bench = active_benchmark orelse return;
    if (!bench.isMeasuring()) return;
    const elapsed_s = @max(rl.GetTime() - start_time, 0.0);
    const delta: u64 = @intFromFloat(elapsed_s * 1_000_000_000.0);
    switch (slot) {
        .app_render => bench.app_render_ns += delta,
        .rasterize => bench.rasterize_ns += delta,
        .native_scene => bench.native_scene_ns += delta,
        .navigator => bench.navigator_ns += delta,
        .hud => bench.hud_ns += delta,
        .spherical_backdrop => bench.spherical_backdrop_ns += delta,
        .spherical_ground => bench.spherical_ground_ns += delta,
        .spherical_geometry_near => bench.spherical_geometry_near_ns += delta,
        .spherical_geometry_far => bench.spherical_geometry_far_ns += delta,
    }
}

fn parseEnvUsize(name: [*:0]const u8) ?usize {
    const value_z = std.c.getenv(name) orelse return null;
    const value = std.mem.sliceTo(value_z, 0);
    return std.fmt.parseUnsigned(usize, value, 10) catch null;
}

fn parseEnvBool(name: [*:0]const u8) bool {
    const value_z = std.c.getenv(name) orelse return false;
    const value = std.mem.sliceTo(value_z, 0);
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

fn printBenchmarkSummary(bench: BenchmarkState) void {
    const frames_f = @as(f64, @floatFromInt(@max(bench.measured_frames, 1)));
    const ns_to_ms = 1.0 / 1_000_000.0;
    std.debug.print(
        \\=== zmath-raylib-benchmark ===
        \\frames={d} warmup={d}
        \\app.render={d:.3}ms
        \\rasterize={d:.3}ms
        \\native_scene={d:.3}ms
        \\navigator={d:.3}ms
        \\hud={d:.3}ms
        \\spherical_backdrop={d:.3}ms
        \\spherical_ground={d:.3}ms
        \\spherical_geometry_far={d:.3}ms
        \\spherical_geometry_near={d:.3}ms
        \\=== end-benchmark ===
        \\
    , .{
        bench.measured_frames,
        bench.warmup_frames,
        @as(f64, @floatFromInt(bench.app_render_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.rasterize_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.native_scene_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.navigator_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.hud_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.spherical_backdrop_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.spherical_ground_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.spherical_geometry_far_ns)) * ns_to_ms / frames_f,
        @as(f64, @floatFromInt(bench.spherical_geometry_near_ns)) * ns_to_ms / frames_f,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const capture_path = std.c.getenv("ZMATH_CAPTURE_PATH");
    const capture_preset = std.c.getenv("ZMATH_CAPTURE_PRESET");
    const benchmark_frames = parseEnvUsize("ZMATH_BENCH_FRAMES");
    const benchmark_warmup = parseEnvUsize("ZMATH_BENCH_WARMUP") orelse 20;
    const enable_euclidean_sdf = parseEnvBool("ZMATH_EUCLIDEAN_SDF");
    const capture_mode = capture_path != null;
    const benchmark_mode = benchmark_frames != null;

    var app = try demo.App.init();
    if (capture_preset) |preset_z| {
        try applyCapturePreset(&app, std.mem.sliceTo(preset_z, 0));
    }
    var benchmark_state = if (benchmark_frames) |frames|
        BenchmarkState{ .warmup_frames = benchmark_warmup, .measured_frames = frames }
    else
        null;
    active_benchmark = if (benchmark_state) |*bench| bench else null;
    defer active_benchmark = null;
    var canvas = try canvas_api.Canvas.init(allocator, canvas_width, canvas_height);
    defer canvas.deinit();

    const subpixel_width = canvas.width * subpixel_x;
    const subpixel_height = canvas.height * subpixel_y;
    const pixels = try allocator.alloc(rl.Color, subpixel_width * subpixel_height);
    defer allocator.free(pixels);
    const depth_buffer = try allocator.alloc(f32, subpixel_width * subpixel_height);
    defer allocator.free(depth_buffer);

    const config_flags: c_uint = @intCast(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT | if (capture_mode or benchmark_mode) rl.FLAG_WINDOW_HIDDEN else 0);
    rl.SetConfigFlags(config_flags);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(window_width, window_height, "zmath demo (raylib backend)");
    defer rl.CloseWindow();

    rl.SetTargetFPS(if (benchmark_mode) 0 else 30);
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
    rl.SetTextureFilter(texture, rl.TEXTURE_FILTER_POINT);
    defer rl.UnloadTexture(texture);

    while (!rl.WindowShouldClose()) {
        if (benchmark_state) |bench| {
            if (bench.isDone()) {
                printBenchmarkSummary(bench);
                return;
            }
        }

        if (consumeInput(&app)) break;

        const viewport = sceneViewportRect();
        const native_mode = isNativeEuclideanMode(app.mode) or isCurvedMode(app.mode);
        const needs_canvas_overlay = app.mode == .hyperbolic;
        app.tick();
        const render_start = benchStart();
        const frame = if (native_mode and !needs_canvas_overlay)
            app.frameInfo()
        else
            app.render(&canvas, canvas.width, canvas.height);
        benchAdd(.app_render, render_start);
        if (needs_canvas_overlay) {
            const rasterize_start = benchStart();
            rasterizeCanvas(&canvas, pixels);
            rl.UpdateTexture(texture, @ptrCast(pixels.ptr));
            benchAdd(.rasterize, rasterize_start);
        }
        const scene_overlay_ready = if (app.mode == .spherical) overlay: {
            const rasterize_start = benchStart();
            const ready = rasterizeSphericalNativeOverlay(&app, pixels, depth_buffer);
            if (ready) rl.UpdateTexture(texture, @ptrCast(pixels.ptr));
            benchAdd(.rasterize, rasterize_start);
            break :overlay ready;
        } else if (enable_euclidean_sdf and isNativeEuclideanMode(app.mode)) overlay: {
            const rasterize_start = benchStart();
            const ready = rasterizeEuclideanSdfOverlay(&app, pixels, depth_buffer);
            if (ready) rl.UpdateTexture(texture, @ptrCast(pixels.ptr));
            benchAdd(.rasterize, rasterize_start);
            break :overlay ready;
        } else false;

        rl.BeginDrawing();

        drawBackdrop();
        drawScenePanel(viewport);

        rl.BeginScissorMode(
            @intFromFloat(@round(viewport.x)),
            @intFromFloat(@round(viewport.y)),
            @intFromFloat(@round(viewport.width)),
            @intFromFloat(@round(viewport.height)),
        );
        const native_scene_start = benchStart();
        if (!drawNativeScene(&app, viewport, if (scene_overlay_ready) texture else null)) {
            drawCanvasTexture(texture, viewport);
        }
        benchAdd(.native_scene, native_scene_start);
        if (needs_canvas_overlay) {
            const navigator_start = benchStart();
            drawCurvedNavigatorOverlay(texture, viewport);
            benchAdd(.navigator, navigator_start);
        }
        rl.EndScissorMode();

        if (needs_canvas_overlay) {
            drawCurvedNavigatorLabels(viewport, app.mode);
        }
        const hud_start = benchStart();
        drawHud(frame, app.mode);
        benchAdd(.hud, hud_start);

        if (capture_path) |path_z| {
            rl.EndDrawing();
            const image_capture = rl.LoadImageFromScreen();
            defer rl.UnloadImage(image_capture);
            if (!rl.ExportImage(image_capture, path_z)) {
                return error.ExportImageFailed;
            }
            return;
        }

        rl.EndDrawing();

        if (benchmark_state) |*bench| {
            bench.frame_index += 1;
        }
    }
}

fn applyCapturePreset(app: *demo.App, preset: []const u8) !void {
    if (std.mem.eql(u8, preset, "spherical_compare_ref")) {
        app.animate = false;
        app.mode = .spherical;
        app.angle = 4.499999;
        app.camera.movement_mode = .walk;
        app.camera.euclid_rotation = 0.366000;
        app.camera.euclid_pitch = 0.100000;
        app.camera.euclid_eye_x = -7.520036;
        app.camera.euclid_eye_y = 0.0;
        app.camera.euclid_eye_z = -59.213104;
        app.camera.spherical = .{
            .metric = .spherical,
            .params = .{
                .radius = 1.480000,
                .angular_zoom = 1.000000,
                .chart_model = .conformal,
            },
            .projection = .stereographic,
            .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
            .camera = .{
                .position = .{ -0.768220, -0.231342, 0.000000, 0.596922 },
                .right = .{ -0.222363, 0.944205, -0.229501, 0.079760 },
                .up = .{ 0.047435, 0.231729, 0.959841, 0.150856 },
                .forward = .{ -0.598448, -0.035495, 0.161355, -0.783942 },
            },
            .scene_sign = 1.0,
        };
        return;
    }

    if (std.mem.eql(u8, preset, "spherical_compare_ref_gnomonic")) {
        try applyCapturePreset(app, "spherical_compare_ref");
        app.camera.spherical.projection = .gnomonic;
        return;
    }

    if (std.mem.eql(u8, preset, "spherical_user_ref_1")) {
        app.animate = false;
        app.mode = .spherical;
        app.angle = 4.149998;
        app.camera.movement_mode = .walk;
        app.camera.euclid_rotation = 0.038000;
        app.camera.euclid_pitch = 0.480000;
        app.camera.euclid_eye_x = 1.743780;
        app.camera.euclid_eye_y = 0.0;
        app.camera.euclid_eye_z = 35.366875;
        app.camera.spherical = .{
            .metric = .spherical,
            .params = .{
                .radius = 1.480000,
                .angular_zoom = 1.000000,
                .chart_model = .conformal,
            },
            .projection = .stereographic,
            .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
            .camera = .{
                .position = .{ -0.979191, -0.012116, 0.000000, 0.202571 },
                .right = .{ -0.019152, 0.999278, 0.000000, -0.032809 },
                .up = .{ 0.093292, 0.016627, 0.886995, 0.451952 },
                .forward = .{ -0.179197, -0.031937, 0.461779, -0.868118 },
            },
            .scene_sign = 1.0,
        };
        return;
    }

    if (std.mem.eql(u8, preset, "spherical_default")) {
        app.animate = false;
        app.mode = .spherical;
        return;
    }

    return error.UnknownCapturePreset;
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
    up: curved.Vec4,
};

const GroundExtents = struct {
    lateral: f32,
    backward: f32,
    forward: f32,
};

const NativeFace = struct {
    points: [8]rl.Vector2,
    len: usize,
    avg_depth: f32,
    fill: rl.Color,
    stroke: rl.Color,
};

const SphericalRasterCell = struct {
    points: [8]rl.Vector2,
    depths: [8]f32,
    len: usize,
    fill: rl.Color,
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

fn samplePointToViewport(viewport: rl.Rectangle, point: [2]f32, sample_width: usize, sample_height: usize) rl.Vector2 {
    const scale_x = viewport.width / @as(f32, @floatFromInt(sample_width));
    const scale_y = viewport.height / @as(f32, @floatFromInt(sample_height));
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

const EuclideanSdfScene = struct {
    projection_mode: projection.EuclideanProjection,
    zoom: f32,
    eye: sdf.Vec3,
    right: sdf.Vec3,
    up: sdf.Vec3,
    forward: sdf.Vec3,
    cube_half_extent: f32,
    cube_inverse_rotor: demo.H.Rotor,

    fn worldToCubeLocal(self: *const EuclideanSdfScene, point: sdf.Vec3) sdf.Vec3 {
        return sdfVec3FromVector(zmath.ga.rotors.rotated(vectorFromSdfVec3(point), self.cube_inverse_rotor));
    }

    fn sample(self: *const EuclideanSdfScene, point: sdf.Vec3) sdf.Sample {
        return .{
            .distance = sdf.box(self.worldToCubeLocal(point), sdf.Vec3.splat(self.cube_half_extent)),
            .material = 1,
        };
    }
};

fn sdfVec3FromVector(v: demo.H.Vector) sdf.Vec3 {
    return .{
        .x = v.coeffNamed("e1"),
        .y = v.coeffNamed("e2"),
        .z = v.coeffNamed("e3"),
    };
}

fn vectorFromSdfVec3(v: sdf.Vec3) demo.H.Vector {
    return demo.H.Vector.init(.{ v.x, v.y, v.z });
}

fn euclideanSdfScene(scene: demo.EuclideanScene) EuclideanSdfScene {
    return .{
        .projection_mode = scene.projection_mode,
        .zoom = scene.zoom,
        .eye = sdfVec3FromVector(scene.eye),
        .right = sdfVec3FromVector(scene.right),
        .up = sdfVec3FromVector(scene.up),
        .forward = sdfVec3FromVector(scene.forward),
        .cube_half_extent = scene.cube_scale,
        .cube_inverse_rotor = scene.cube_rotor.reverse(),
    };
}

fn sampleEuclideanSdfScene(scene: *const EuclideanSdfScene, point: sdf.Vec3) sdf.Sample {
    return scene.sample(point);
}

fn euclideanSdfRay(scene: EuclideanSdfScene, sample_x: usize, sample_y: usize) sdf.Ray {
    const x_canvas = (@as(f32, @floatFromInt(sample_x)) + 0.5) / @as(f32, @floatFromInt(subpixel_x));
    const y_canvas = (@as(f32, @floatFromInt(sample_y)) + 0.5) / @as(f32, @floatFromInt(subpixel_y));
    const width_f = @as(f32, @floatFromInt(canvas_width));
    const height_f = @as(f32, @floatFromInt(canvas_height));
    const aspect = width_f / (height_f * 2.0);
    const x_ndc = x_canvas / (width_f * 0.5) - 1.0;
    const y_ndc = 1.0 - y_canvas / (height_f * 0.5);
    const depth_offset = projection.euclideanProjectionDepthOffset(scene.projection_mode);
    const x_plane = x_ndc * aspect * depth_offset / scene.zoom;
    const y_plane = y_ndc * depth_offset / scene.zoom;
    const plane_point = scene.eye.add(scene.right.scale(x_plane)).add(scene.up.scale(y_plane));

    return switch (scene.projection_mode) {
        .perspective => {
            const origin = scene.eye.sub(scene.forward.scale(depth_offset));
            return .{
                .origin = origin,
                .direction = plane_point.sub(origin).normalized(),
            };
        },
        .isometric => .{
            .origin = plane_point.sub(scene.forward.scale(demo.far_clip_z + depth_offset)),
            .direction = scene.forward,
        },
    };
}

fn cubeFaceIndexFromLocalNormal(normal: sdf.Vec3) usize {
    const ax = @abs(normal.x);
    const ay = @abs(normal.y);
    const az = @abs(normal.z);
    if (ax >= ay and ax >= az) return if (normal.x >= 0.0) 0 else 1;
    if (ay >= az) return if (normal.y >= 0.0) 2 else 3;
    return if (normal.z >= 0.0) 4 else 5;
}

fn euclideanViewDepth(scene: EuclideanSdfScene, point: sdf.Vec3) f32 {
    return point.sub(scene.eye).dot(scene.forward);
}

fn nativeEuclideanSdfColor(face_index: usize, normal: sdf.Vec3, depth: f32, steps: usize) rl.Color {
    var fill = nativeFaceColor(face_index, vectorFromSdfVec3(normal), depth);
    const march_t = std.math.clamp(@as(f32, @floatFromInt(steps)) / 72.0, 0.0, 1.0);
    fill = mixColor(fill, white, 0.06 * (1.0 - march_t));
    fill.a = 255;
    return fill;
}

fn rasterizeEuclideanSdfOverlay(app: *const demo.App, pixels: []rl.Color, depth_buffer: []f32) bool {
    const scene_raw = app.euclideanScene() orelse return false;
    const scene = euclidean_sdf_renderer.Scene.init(scene_raw);
    clearOverlayPixels(pixels, depth_buffer);

    const options = sdf.MarchOptions{
        .min_distance = 0.0,
        .max_distance = demo.far_clip_z + projection.euclideanProjectionDepthOffset(scene.projection_mode) + scene.cube_half_extent * 2.0,
        .hit_epsilon = 0.0014,
        .min_step = 0.0008,
        .step_scale = 0.98,
        .max_steps = 96,
    };

    const sdf_width = canvas_width * euclidean_sdf_scale_x;
    const sdf_height = canvas_height * euclidean_sdf_scale_y;
    const block_width = subpixel_x / euclidean_sdf_scale_x;
    const block_height = subpixel_y / euclidean_sdf_scale_y;
    std.debug.assert(subpixel_x % euclidean_sdf_scale_x == 0);
    std.debug.assert(subpixel_y % euclidean_sdf_scale_y == 0);
    const overlay_width = canvas_width * subpixel_x;

    for (0..sdf_height) |sy| {
        for (0..sdf_width) |sx| {
            const ray = scene.ray(sx, sy, canvas_width, canvas_height, euclidean_sdf_scale_x, euclidean_sdf_scale_y);
            const hit = scene.traceAccelerated(ray, options) orelse continue;
            const depth = scene.viewDepth(hit.position);
            if (depth < demo.near_clip_z or depth > demo.far_clip_z) continue;

            const local_normal = scene.localNormal(hit.position);
            const normal = scene.cubeLocalToWorldDirection(local_normal);
            const face_index = cubeFaceIndexFromLocalNormal(local_normal);
            const color = nativeEuclideanSdfColor(face_index, normal, depth, hit.steps);
            const start_x = sx * block_width;
            const start_y = sy * block_height;
            for (0..block_height) |dy| {
                const py = start_y + dy;
                for (0..block_width) |dx| {
                    const px = start_x + dx;
                    const idx = py * overlay_width + px;
                    pixels[idx] = color;
                    depth_buffer[idx] = depth;
                }
            }
        }
    }

    return true;
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

fn drawNativeScene(app: *const demo.App, viewport: rl.Rectangle, overlay_texture: ?rl.Texture2D) bool {
    if (isNativeEuclideanMode(app.mode)) {
        drawNativeEuclideanScene(app, viewport, overlay_texture);
        return true;
    }

    if (isCurvedMode(app.mode)) {
        drawNativeCurvedScene(app, viewport, overlay_texture);
        return true;
    }

    return false;
}

fn drawNativeEuclideanScene(app: *const demo.App, viewport: rl.Rectangle, overlay_texture: ?rl.Texture2D) void {
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

    if (overlay_texture) |texture| {
        drawCanvasTexture(texture, viewport);
        return;
    }

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

fn isSphericalGnomonic(view: curved.View) bool {
    return view.metric == .spherical and view.projection == .gnomonic;
}

fn sphericalLocalFillSteps(view: curved.View) usize {
    return if (view.metric != .spherical)
        native_curved_fill_steps
    else if (view.projection == .gnomonic)
        5
    else
        4;
}

fn sphericalLocalEdgeSteps(view: curved.View) usize {
    return if (view.metric != .spherical)
        native_curved_edge_steps
    else if (view.projection == .gnomonic)
        20
    else
        16;
}

fn curvedGroundSteps(view: curved.View) usize {
    return if (view.metric == .spherical) 8 else native_ground_steps;
}

fn curvedGroundSubdivideDepth(world_view: curved.View, render_view: curved.View) usize {
    _ = world_view;
    return if (render_view.metric == .spherical)
        2
    else
        native_ground_subdivide_depth;
}

fn scaleVec4(v: curved.Vec4, s: f32) curved.Vec4 {
    return .{ v[0] * s, v[1] * s, v[2] * s, v[3] * s };
}

fn addVec4(a: curved.Vec4, b: curved.Vec4) curved.Vec4 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

fn metricDot4(metric: curved.Metric, a: curved.Vec4, b: curved.Vec4) f32 {
    return switch (metric) {
        .hyperbolic => -a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3],
        .elliptic, .spherical => a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3],
    };
}

fn signedAmbientForView(view: curved.View, ambient_input: curved.Vec4) curved.Vec4 {
    var ambient = ambient_input;
    if (view.metric == .spherical and view.scene_sign < 0.0) {
        ambient = scaleVec4(ambient, -1.0);
    }
    return ambient;
}

fn sampleAmbientForNativeRender(view: curved.View, ambient_input: curved.Vec4, screen: curved.Screen) curved.ProjectedSample {
    const ambient = signedAmbientForView(view, ambient_input);
    if (view.metric == .spherical and view.projection == .gnomonic) {
        const model_point = curved.modelPointForAmbientWithCamera(
            view.metric,
            view.camera,
            ambient,
            .linear,
        ) orelse return .{};
        return curved.sampleProjectedModelPoint(
            view.metric,
            view.projection,
            view.params,
            view.clip,
            model_point,
            screen,
        );
    }
    return view.sampleProjectedAmbient(ambient, screen);
}

fn projectNativeSphericalConformalPoint(model_point: curved.Vec3, screen: curved.Screen) ?[2]f32 {
    const z = model_point[2];
    if (z <= 1e-4) return null;

    const aspect = @as(f32, @floatFromInt(screen.width)) / @as(f32, @floatFromInt(screen.height * 2));
    const x = (model_point[0] * screen.zoom / (z * aspect) + 1.0) * (@as(f32, @floatFromInt(screen.width)) * 0.5);
    const y = (1.0 - model_point[1] * screen.zoom / z) * (@as(f32, @floatFromInt(screen.height)) * 0.5);
    const limit = @as(f32, @floatFromInt(@max(screen.width, screen.height))) * 6.0;
    if (x < -limit or x > @as(f32, @floatFromInt(screen.width)) + limit) return null;
    if (y < -limit or y > @as(f32, @floatFromInt(screen.height)) + limit) return null;
    return .{ x, y };
}

fn nativeSphericalSampleStatus(distance: f32, clip: curved.DistanceClip, projected: ?[2]f32) curved.SampleStatus {
    if (projected == null) return .hidden;
    if (distance < clip.near) return .clipped_near;
    if (distance > clip.far) return .clipped_far;
    return .visible;
}

fn nativeSphericalConformalSampleForPass(
    base_view: curved.View,
    render_view: curved.View,
    pass: curved.SphericalRenderPass,
    ambient_input: curved.Vec4,
    screen: curved.Screen,
) curved.ProjectedSample {
    _ = render_view;
    const ambient = signedAmbientForView(base_view, ambient_input);
    const model_point = curved.modelPointForAmbientWithCamera(
        .spherical,
        base_view.camera,
        ambient,
        .conformal,
    ) orelse return .{};
    const radius2 = model_point[0] * model_point[0] + model_point[1] * model_point[1] + model_point[2] * model_point[2];
    if (radius2 <= 1e-6) return .{};

    const projected_point = switch (pass) {
        .near => if (radius2 <= 1.0) model_point else return .{},
        .far => if (radius2 >= 1.0)
            .{
                model_point[0] / radius2,
                model_point[1] / radius2,
                model_point[2] / radius2,
            }
        else
            return .{},
    };
    const distance = base_view.params.radius * 2.0 * std.math.atan(@sqrt(radius2));
    const projected = projectNativeSphericalConformalPoint(projected_point, screen);
    return .{
        .distance = distance,
        .render_depth = projected_point[2],
        .projected = projected,
        .status = nativeSphericalSampleStatus(distance, base_view.clip, projected),
    };
}

fn signedGroundBasisForView(view: curved.View, basis: GroundBasis) GroundBasis {
    if (view.metric != .spherical or view.scene_sign >= 0.0) return basis;
    return .{
        .origin = scaleVec4(basis.origin, -1.0),
        .right = scaleVec4(basis.right, -1.0),
        .forward = scaleVec4(basis.forward, -1.0),
        .up = scaleVec4(basis.up, -1.0),
    };
}

fn inverseStereographicScreenDirection(screen: curved.Screen, point: [2]f32) curved.Vec3 {
    const aspect = @as(f32, @floatFromInt(screen.width)) / @as(f32, @floatFromInt(screen.height * 2));
    const x_raw = ((point[0] / @as(f32, @floatFromInt(screen.width))) * 2.0 - 1.0) * aspect / screen.zoom;
    const y_raw = (1.0 - (point[1] / (@as(f32, @floatFromInt(screen.height)) * 0.5))) / screen.zoom;
    const denom = x_raw * x_raw + y_raw * y_raw + 4.0;
    return .{
        4.0 * x_raw / denom,
        4.0 * y_raw / denom,
        (4.0 - x_raw * x_raw - y_raw * y_raw) / denom,
    };
}

fn inverseWrappedScreenDirection(screen: curved.Screen, point: [2]f32) curved.Vec3 {
    const x_unit = ((point[0] / @as(f32, @floatFromInt(screen.width))) - 0.5) / screen.zoom + 0.5;
    const azimuth = (x_unit - 0.5) * (@as(f32, std.math.pi) * 2.0);
    const elevation = (1.0 - (point[1] / (@as(f32, @floatFromInt(screen.height)) * 0.5))) *
        ((@as(f32, std.math.pi) * 0.5) / screen.zoom);
    const planar = @cos(elevation);
    return .{
        @sin(azimuth) * planar,
        @sin(elevation),
        @cos(azimuth) * planar,
    };
}

fn inverseGroundScreenDirection(
    projection_mode: projection.DirectionProjection,
    screen: curved.Screen,
    point: [2]f32,
) ?curved.Vec3 {
    return switch (projection_mode) {
        .stereographic => inverseStereographicScreenDirection(screen, point),
        .wrapped => inverseWrappedScreenDirection(screen, point),
        else => null,
    };
}

const SphericalGroundHit = struct {
    distance: f32,
    lateral: f32,
    forward: f32,
};

fn sphericalGroundHitForScreenPoint(
    view: curved.View,
    basis_input: GroundBasis,
    screen: curved.Screen,
    point: [2]f32,
) ?SphericalGroundHit {
    if (view.metric != .spherical) return null;

    const basis = signedGroundBasisForView(view, basis_input);
    const local_dir = inverseGroundScreenDirection(view.projection, screen, point) orelse return null;
    const direction = addVec4(
        addVec4(scaleVec4(view.camera.right, local_dir[0]), scaleVec4(view.camera.up, local_dir[1])),
        scaleVec4(view.camera.forward, local_dir[2]),
    );

    const a = metricDot4(.spherical, view.camera.position, basis.up);
    const b = metricDot4(.spherical, direction, basis.up);
    if (@abs(a) <= 1e-6 and @abs(b) <= 1e-6) return null;

    var theta = std.math.atan2(-a, b);
    if (theta <= 1e-4) theta += @as(f32, std.math.pi);
    if (theta > @as(f32, std.math.pi)) theta -= @as(f32, std.math.pi);
    if (theta <= 1e-4) return null;

    const ambient = addVec4(
        scaleVec4(view.camera.position, @cos(theta)),
        scaleVec4(direction, @sin(theta)),
    );
    const origin_coord = metricDot4(.spherical, ambient, basis.origin);
    const lateral_coord = metricDot4(.spherical, ambient, basis.right);
    const forward_coord = metricDot4(.spherical, ambient, basis.forward);
    const planar_norm = @sqrt(lateral_coord * lateral_coord + forward_coord * forward_coord);
    if (planar_norm <= 1e-6) {
        return .{
            .distance = theta * view.params.radius,
            .lateral = 0.0,
            .forward = 0.0,
        };
    }

    const tangent_radius = std.math.atan2(planar_norm, origin_coord) * view.params.radius;
    const tangent_scale = tangent_radius / planar_norm;
    return .{
        .distance = theta * view.params.radius,
        .lateral = lateral_coord * tangent_scale,
        .forward = forward_coord * tangent_scale,
    };
}

fn checkerCoord(value: f32, cell_size: f32) i32 {
    return @as(i32, @intFromFloat(@floor(value / cell_size)));
}

fn gridLineStrength(value: f32, cell_size: f32, line_half_width: f32) f32 {
    const wrapped = @mod(value, cell_size);
    const distance = @min(wrapped, cell_size - wrapped);
    return std.math.clamp(1.0 - distance / line_half_width, 0.0, 1.0);
}

fn drawSphericalGroundFullscreen(
    view: curved.View,
    basis: GroundBasis,
    screen: curved.Screen,
    viewport: rl.Rectangle,
) void {
    const ground_screen = curved.Screen{
        .width = screen.width * spherical_ground_screen_scale_x,
        .height = screen.height * spherical_ground_screen_scale_y,
        .zoom = screen.zoom,
    };
    const far_distance = view.shadeFarDistance();
    const cell_size = view.params.radius * 0.22;
    const line_half_width = cell_size * 0.08;

    for (0..ground_screen.height) |yi| {
        const y0 = @as(f32, @floatFromInt(yi));
        const y1 = @as(f32, @floatFromInt(yi + 1));
        for (0..ground_screen.width) |xi| {
            const x0 = @as(f32, @floatFromInt(xi));
            const x1 = @as(f32, @floatFromInt(xi + 1));
            const hit = sphericalGroundHitForScreenPoint(view, basis, ground_screen, .{ x0 + 0.5, y0 + 0.5 }) orelse continue;
            const checker = ((checkerCoord(hit.lateral, cell_size) + checkerCoord(hit.forward, cell_size)) & 1) == 0;
            var fill = groundFillColor(.spherical, hit.distance, view.clip.near, far_distance, checker);
            const line_strength = @max(
                gridLineStrength(hit.lateral, cell_size, line_half_width),
                gridLineStrength(hit.forward, cell_size, line_half_width),
            );
            if (line_strength > 0.0) {
                fill = mixColor(fill, white, line_strength * 0.16);
            }

            const top_left = samplePointToViewport(viewport, .{ x0, y0 }, ground_screen.width, ground_screen.height);
            const bottom_right = samplePointToViewport(viewport, .{ x1, y1 }, ground_screen.width, ground_screen.height);
            rl.DrawRectangleRec(
                .{
                    .x = top_left.x,
                    .y = top_left.y,
                    .width = bottom_right.x - top_left.x,
                    .height = bottom_right.y - top_left.y,
                },
                fill,
            );
        }
    }
}

fn rasterizeSphericalGroundFullscreen(
    view: curved.View,
    basis: GroundBasis,
    screen: curved.Screen,
    pixels: []rl.Color,
    depth_buffer: []f32,
) void {
    const pixel_width = canvas_width * subpixel_x;
    const pixel_height = canvas_height * subpixel_y;
    std.debug.assert(pixels.len == pixel_width * pixel_height);
    std.debug.assert(depth_buffer.len == pixels.len);

    const far_distance = view.shadeFarDistance();
    const cell_size = view.params.radius * 0.22;
    const line_half_width = cell_size * 0.08;

    for (0..pixel_height) |yi| {
        const canvas_y = (@as(f32, @floatFromInt(yi)) + 0.5) / @as(f32, @floatFromInt(subpixel_y));
        for (0..pixel_width) |xi| {
            const canvas_x = (@as(f32, @floatFromInt(xi)) + 0.5) / @as(f32, @floatFromInt(subpixel_x));
            const hit = sphericalGroundHitForScreenPoint(view, basis, screen, .{ canvas_x, canvas_y }) orelse continue;
            const checker = ((checkerCoord(hit.lateral, cell_size) + checkerCoord(hit.forward, cell_size)) & 1) == 0;
            var fill = groundFillColor(.spherical, hit.distance, view.clip.near, far_distance, checker);
            const line_strength = @max(
                gridLineStrength(hit.lateral, cell_size, line_half_width),
                gridLineStrength(hit.forward, cell_size, line_half_width),
            );
            if (line_strength > 0.0) {
                fill = mixColor(fill, white, line_strength * 0.16);
            }

            const idx = yi * pixel_width + xi;
            pixels[idx] = fill;
            depth_buffer[idx] = hit.distance;
        }
    }
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
    fill.a = if (metric == .spherical) 255 else 208;
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
    render_pass: CurvedRenderPass,
    local: curved.Vec3,
    screen: curved.Screen,
) curved.ProjectedSample {
    const ambient = demo.sphericalDemoAmbientPoint(base_view.params, local);
    return switch (render_pass) {
        .direct => sampleAmbientForNativeRender(render_view, ambient, screen),
        .spherical => |pass| nativeSphericalConformalSampleForPass(base_view, render_view, pass, ambient, screen),
    };
}

fn walkEyeHeight(view: curved.View) f32 {
    return switch (view.metric) {
        .hyperbolic => view.params.radius * hyperbolic_walk_eye_height_scale,
        .elliptic => 0.14,
        .spherical => view.params.radius * spherical_walk_eye_height_scale,
    };
}

fn liftedWalkView(view: curved.View, pitch_angle: f32) curved.View {
    const surface_up = view.walkSurfaceUp(pitch_angle) orelse return view;
    var lifted = view;
    curved.moveAlongDirection(
        &lifted.camera,
        view.metric,
        view.params,
        surface_up,
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
        .up = .{ 0.0, 0.0, 1.0, 0.0 },
    };
}

fn sphericalGroundBasisForPass(pass: curved.SphericalRenderPass) GroundBasis {
    const basis = worldGroundBasis(.spherical);
    return switch (pass) {
        .near => basis,
        .far => .{
            .origin = .{ -basis.origin[0], -basis.origin[1], -basis.origin[2], -basis.origin[3] },
            .right = basis.right,
            .forward = basis.forward,
            .up = basis.up,
        },
    };
}

fn walkGroundBasis(view: curved.View, pitch_angle: f32) ?GroundBasis {
    const basis = view.walkSurfaceBasis(pitch_angle) orelse return null;
    return .{
        .origin = view.camera.position,
        .right = basis.right,
        .forward = basis.forward,
        .up = basis.up,
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
    if (!groundPointAllowed(surface_view, lateral, forward_distance)) return .{};
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
        .direct => sampleAmbientForNativeRender(render_view, ambient, screen),
        .spherical => |pass| nativeSphericalConformalSampleForPass(surface_view, render_view, pass, ambient, screen),
    };
}

fn sphericalGroundTangentRadius(params: curved.Params) f32 {
    return params.radius * (@as(f32, std.math.pi) * 0.5) * 0.98;
}

fn groundPointAllowed(view: curved.View, lateral: f32, forward_distance: f32) bool {
    if (view.metric != .spherical) return true;
    const max_radius = sphericalGroundTangentRadius(view.params);
    return lateral * lateral + forward_distance * forward_distance <= max_radius * max_radius;
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

fn groundExtents(view: curved.View) GroundExtents {
    return switch (view.metric) {
        .hyperbolic => .{
            .lateral = view.params.radius * 2.15,
            .backward = view.params.radius * 0.85,
            .forward = view.params.radius * 3.05,
        },
        .elliptic, .spherical => .{
            .lateral = sphericalGroundTangentRadius(view.params),
            .backward = sphericalGroundTangentRadius(view.params),
            .forward = sphericalGroundTangentRadius(view.params),
        },
    };
}

fn sampleVisible(sample: curved.ProjectedSample) bool {
    return sample.status == .visible and sample.projected != null;
}

fn sampleRasterDepth(sample: curved.ProjectedSample) f32 {
    if (sample.render_depth > 0.0) return sample.render_depth;
    return sample.distance;
}

fn groundCellBroken(
    render_view: curved.View,
    screen: curved.Screen,
    p00: [2]f32,
    p10: [2]f32,
    p11: [2]f32,
    p01: [2]f32,
) bool {
    return curved.shouldBreakProjectedSegment(render_view.projection, p00, p10, screen.width, screen.height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p10, p11, screen.width, screen.height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p11, p01, screen.width, screen.height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p01, p00, screen.width, screen.height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p00, p11, screen.width, screen.height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p10, p01, screen.width, screen.height);
}

fn projectedQuadTooLarge(
    p00: [2]f32,
    p10: [2]f32,
    p11: [2]f32,
    p01: [2]f32,
    screen: curved.Screen,
    fraction: f32,
) bool {
    const min_x = @min(@min(p00[0], p10[0]), @min(p11[0], p01[0]));
    const max_x = @max(@max(p00[0], p10[0]), @max(p11[0], p01[0]));
    const min_y = @min(@min(p00[1], p10[1]), @min(p11[1], p01[1]));
    const max_y = @max(@max(p00[1], p10[1]), @max(p11[1], p01[1]));
    const span_x = max_x - min_x;
    const span_y = max_y - min_y;
    const limit = @as(f32, @floatFromInt(@max(screen.width, screen.height))) * fraction;
    return span_x > limit or span_y > limit;
}

fn drawGroundTriangle(
    viewport: rl.Rectangle,
    fill: rl.Color,
    a: [2]f32,
    b: [2]f32,
    c: [2]f32,
) void {
    const v0 = canvasPointToViewport(viewport, a);
    const v1 = canvasPointToViewport(viewport, b);
    const v2 = canvasPointToViewport(viewport, c);
    rl.DrawTriangle(v0, v1, v2, fill);
}

fn drawCurvedGroundCell(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    screen: curved.Screen,
    viewport: rl.Rectangle,
    x0: f32,
    x1: f32,
    z0: f32,
    z1: f32,
    checker: bool,
    depth: usize,
    far_distance: f32,
) void {
    const s00 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x0, z0, screen);
    const s10 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x1, z0, screen);
    const s11 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x1, z1, screen);
    const s01 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, x0, z1, screen);
    const center = groundSampleForCurvedRender(
        world_view,
        render_view,
        render_pass,
        basis,
        (x0 + x1) * 0.5,
        (z0 + z1) * 0.5,
        screen,
    );

    var visible_count: usize = 0;
    if (sampleVisible(s00)) visible_count += 1;
    if (sampleVisible(s10)) visible_count += 1;
    if (sampleVisible(s11)) visible_count += 1;
    if (sampleVisible(s01)) visible_count += 1;
    const center_visible = sampleVisible(center);

    if (visible_count == 0 and !center_visible) return;

    if (visible_count == 4 and center_visible) {
        const p00 = s00.projected.?;
        const p10 = s10.projected.?;
        const p11 = s11.projected.?;
        const p01 = s01.projected.?;
        if (!groundCellBroken(render_view, screen, p00, p10, p11, p01)) {
            const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
            const fill = groundFillColor(render_view.metric, avg_distance, render_view.clip.near, far_distance, checker);
            const stroke = groundStrokeColor(fill);
            const poly = [_]rl.Vector2{
                canvasPointToViewport(viewport, p00),
                canvasPointToViewport(viewport, p10),
                canvasPointToViewport(viewport, p11),
                canvasPointToViewport(viewport, p01),
            };
            drawPolygonFan(poly[0..], fill);
            if (render_view.metric != .spherical) {
                drawPolygonOutline(poly[0..], 0.8, stroke);
            }
            return;
        }
    }

    if (depth > 0) {
        const cx = (x0 + x1) * 0.5;
        const cz = (z0 + z1) * 0.5;
        drawCurvedGroundCell(world_view, render_view, render_pass, basis, screen, viewport, x0, cx, z0, cz, checker, depth - 1, far_distance);
        drawCurvedGroundCell(world_view, render_view, render_pass, basis, screen, viewport, cx, x1, z0, cz, checker, depth - 1, far_distance);
        drawCurvedGroundCell(world_view, render_view, render_pass, basis, screen, viewport, cx, x1, cz, z1, checker, depth - 1, far_distance);
        drawCurvedGroundCell(world_view, render_view, render_pass, basis, screen, viewport, x0, cx, cz, z1, checker, depth - 1, far_distance);
        return;
    }

    if (world_view.metric == .spherical) return;

    if (!center_visible) return;

    const center_point = center.projected.?;
    const fill = groundFillColor(render_view.metric, center.distance, render_view.clip.near, far_distance, checker);
    const corners = [_]curved.ProjectedSample{ s00, s10, s11, s01 };
    const next = [_]usize{ 1, 2, 3, 0 };
    for (corners, 0..) |corner, i| {
        const adjacent = corners[next[i]];
        if (!sampleVisible(corner) or !sampleVisible(adjacent)) continue;
        const p0 = corner.projected.?;
        const p1 = adjacent.projected.?;
        if (curved.shouldBreakProjectedSegment(render_view.projection, center_point, p0, screen.width, screen.height) or
            curved.shouldBreakProjectedSegment(render_view.projection, center_point, p1, screen.width, screen.height) or
            curved.shouldBreakProjectedSegment(render_view.projection, p0, p1, screen.width, screen.height))
        {
            continue;
        }
        drawGroundTriangle(viewport, fill, center_point, p0, p1);
    }
}

fn drawCurvedGroundPatch(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    screen: curved.Screen,
    viewport: rl.Rectangle,
) void {
    if (world_view.metric == .spherical) {
        drawSphericalGroundPatchPolar(world_view, render_view, render_pass, basis, screen, viewport);
        return;
    }

    const extents = groundExtents(world_view);
    const far_distance = render_view.shadeFarDistance();
    const subdivide_depth = curvedGroundSubdivideDepth(world_view, render_view);
    const ground_steps = curvedGroundSteps(render_view);

    for (0..ground_steps) |ui| {
        const u_t0 = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(ground_steps));
        const u_t1 = @as(f32, @floatFromInt(ui + 1)) / @as(f32, @floatFromInt(ground_steps));
        const x0 = (u_t0 * 2.0 - 1.0) * extents.lateral;
        const x1 = (u_t1 * 2.0 - 1.0) * extents.lateral;

        for (0..ground_steps) |vi| {
            const v_t0 = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(ground_steps));
            const v_t1 = @as(f32, @floatFromInt(vi + 1)) / @as(f32, @floatFromInt(ground_steps));
            const z0 = -extents.backward + v_t0 * (extents.backward + extents.forward);
            const z1 = -extents.backward + v_t1 * (extents.backward + extents.forward);
            drawCurvedGroundCell(
                world_view,
                render_view,
                render_pass,
                basis,
                screen,
                viewport,
                x0,
                x1,
                z0,
                z1,
                ((ui + vi) & 1) == 0,
                subdivide_depth,
                far_distance,
            );
        }
    }
}

fn sphericalGroundRingRadius(max_radius: f32, t: f32) f32 {
    const remaining = 1.0 - t;
    return max_radius * (1.0 - remaining * remaining);
}

fn sphericalGroundPolarPoint(radius: f32, angle: f32) struct { lateral: f32, forward: f32 } {
    return .{
        .lateral = @cos(angle) * radius,
        .forward = @sin(angle) * radius,
    };
}

fn drawSphericalGroundPolarCell(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    screen: curved.Screen,
    viewport: rl.Rectangle,
    r0: f32,
    r1: f32,
    theta0: f32,
    theta1: f32,
    checker: bool,
    depth: usize,
    far_distance: f32,
) void {
    const c00 = sphericalGroundPolarPoint(r0, theta0);
    const c10 = sphericalGroundPolarPoint(r1, theta0);
    const c11 = sphericalGroundPolarPoint(r1, theta1);
    const c01 = sphericalGroundPolarPoint(r0, theta1);
    const center_radius = (r0 + r1) * 0.5;
    const center_theta = (theta0 + theta1) * 0.5;
    const cc = sphericalGroundPolarPoint(center_radius, center_theta);

    const s00 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c00.lateral, c00.forward, screen);
    const s10 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c10.lateral, c10.forward, screen);
    const s11 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c11.lateral, c11.forward, screen);
    const s01 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c01.lateral, c01.forward, screen);
    const center = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, cc.lateral, cc.forward, screen);

    var visible_count: usize = 0;
    if (sampleVisible(s00)) visible_count += 1;
    if (sampleVisible(s10)) visible_count += 1;
    if (sampleVisible(s11)) visible_count += 1;
    if (sampleVisible(s01)) visible_count += 1;
    const center_visible = sampleVisible(center);

    if (visible_count == 0 and !center_visible) return;

    if (visible_count == 4 and center_visible) {
        const p00 = s00.projected.?;
        const p10 = s10.projected.?;
        const p11 = s11.projected.?;
        const p01 = s01.projected.?;
        const broken = groundCellBroken(render_view, screen, p00, p10, p11, p01);
        const too_large = projectedQuadTooLarge(p00, p10, p11, p01, screen, 0.24);
        if (!broken and (!too_large or depth == 0)) {
            const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
            const fill = groundFillColor(render_view.metric, avg_distance, render_view.clip.near, far_distance, checker);
            const poly = [_]rl.Vector2{
                canvasPointToViewport(viewport, p00),
                canvasPointToViewport(viewport, p10),
                canvasPointToViewport(viewport, p11),
                canvasPointToViewport(viewport, p01),
            };
            drawPolygonFan(poly[0..], fill);
            return;
        }
    }

    if (depth == 0) return;

    const radius_mid = (r0 + r1) * 0.5;
    const theta_mid = (theta0 + theta1) * 0.5;
    drawSphericalGroundPolarCell(world_view, render_view, render_pass, basis, screen, viewport, r0, radius_mid, theta0, theta_mid, checker, depth - 1, far_distance);
    drawSphericalGroundPolarCell(world_view, render_view, render_pass, basis, screen, viewport, radius_mid, r1, theta0, theta_mid, checker, depth - 1, far_distance);
    drawSphericalGroundPolarCell(world_view, render_view, render_pass, basis, screen, viewport, radius_mid, r1, theta_mid, theta1, checker, depth - 1, far_distance);
    drawSphericalGroundPolarCell(world_view, render_view, render_pass, basis, screen, viewport, r0, radius_mid, theta_mid, theta1, checker, depth - 1, far_distance);
}

fn drawSphericalGroundPatchPolar(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    screen: curved.Screen,
    viewport: rl.Rectangle,
) void {
    const max_radius = sphericalGroundTangentRadius(world_view.params);
    const far_distance = render_view.shadeFarDistance();
    const tau = @as(f32, std.math.pi) * 2.0;

    for (0..spherical_ground_radial_steps) |ri| {
        const t0 = @as(f32, @floatFromInt(ri)) / @as(f32, @floatFromInt(spherical_ground_radial_steps));
        const t1 = @as(f32, @floatFromInt(ri + 1)) / @as(f32, @floatFromInt(spherical_ground_radial_steps));
        const r0 = sphericalGroundRingRadius(max_radius, t0);
        const r1 = sphericalGroundRingRadius(max_radius, t1);

        for (0..spherical_ground_angular_steps) |ai| {
            const a0 = tau * @as(f32, @floatFromInt(ai)) / @as(f32, @floatFromInt(spherical_ground_angular_steps));
            const a1 = tau * @as(f32, @floatFromInt(ai + 1)) / @as(f32, @floatFromInt(spherical_ground_angular_steps));
            drawSphericalGroundPolarCell(
                world_view,
                render_view,
                render_pass,
                basis,
                screen,
                viewport,
                r0,
                r1,
                a0,
                a1,
                ((ri + ai) & 1) == 0,
                spherical_ground_subdivide_depth,
                far_distance,
            );
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

const spherical_local_subdivide_depth: usize = 1;
const max_spherical_fill_steps: usize = 10;
const max_spherical_local_cells = demo.cube_faces.len * max_spherical_fill_steps * max_spherical_fill_steps * 24;
var spherical_local_cells_storage: [max_spherical_local_cells]SphericalRasterCell = undefined;

fn appendSphericalLocalProjectedCell(
    base_view: curved.View,
    face_index: usize,
    far_distance: f32,
    s00: curved.ProjectedSample,
    s10: curved.ProjectedSample,
    s11: curved.ProjectedSample,
    s01: curved.ProjectedSample,
    cells: *[max_spherical_local_cells]SphericalRasterCell,
    cell_count: *usize,
) bool {
    if (!sampleVisible(s00) or !sampleVisible(s10) or !sampleVisible(s11) or !sampleVisible(s01)) return false;

    const p00 = s00.projected.?;
    const p10 = s10.projected.?;
    const p11 = s11.projected.?;
    const p01 = s01.projected.?;
    const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
    const fill = nativeCurvedFillColor(base_view.metric, face_index, avg_distance, base_view.clip.near, far_distance);
    var poly: [8]rl.Vector2 = undefined;
    poly[0] = .{ .x = p00[0] * @as(f32, @floatFromInt(subpixel_x)), .y = p00[1] * @as(f32, @floatFromInt(subpixel_y)) };
    poly[1] = .{ .x = p10[0] * @as(f32, @floatFromInt(subpixel_x)), .y = p10[1] * @as(f32, @floatFromInt(subpixel_y)) };
    poly[2] = .{ .x = p11[0] * @as(f32, @floatFromInt(subpixel_x)), .y = p11[1] * @as(f32, @floatFromInt(subpixel_y)) };
    poly[3] = .{ .x = p01[0] * @as(f32, @floatFromInt(subpixel_x)), .y = p01[1] * @as(f32, @floatFromInt(subpixel_y)) };

    if (cell_count.* >= cells.len) return false;
    cells[cell_count.*] = .{
        .points = poly,
        .depths = .{
            sampleRasterDepth(s00),
            sampleRasterDepth(s10),
            sampleRasterDepth(s11),
            sampleRasterDepth(s01),
            0.0,
            0.0,
            0.0,
            0.0,
        },
        .len = 4,
        .fill = fill,
    };
    cell_count.* += 1;
    return true;
}

fn appendSphericalLocalCellRecursive(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    quad: [4]curved.Vec3,
    face_index: usize,
    depth: usize,
    far_distance: f32,
    cells: *[max_spherical_local_cells]SphericalRasterCell,
    cell_count: *usize,
) void {
    const s00 = sampleSphericalLocalPoint(base_view, render_view, render_pass, quad[0], screen);
    const s10 = sampleSphericalLocalPoint(base_view, render_view, render_pass, quad[1], screen);
    const s11 = sampleSphericalLocalPoint(base_view, render_view, render_pass, quad[2], screen);
    const s01 = sampleSphericalLocalPoint(base_view, render_view, render_pass, quad[3], screen);
    const center_local = bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], 0.5, 0.5);
    const center = sampleSphericalLocalPoint(base_view, render_view, render_pass, center_local, screen);

    var visible_count: usize = 0;
    if (sampleVisible(s00)) visible_count += 1;
    if (sampleVisible(s10)) visible_count += 1;
    if (sampleVisible(s11)) visible_count += 1;
    if (sampleVisible(s01)) visible_count += 1;
    const center_visible = sampleVisible(center);

    if (visible_count == 0 and !center_visible) return;

    if (visible_count == 4 and center_visible) {
        const p00 = s00.projected.?;
        const p10 = s10.projected.?;
        const p11 = s11.projected.?;
        const p01 = s01.projected.?;
        const broken = groundCellBroken(render_view, screen, p00, p10, p11, p01);
        const too_large = projectedQuadTooLarge(p00, p10, p11, p01, screen, 0.60);
        if (!broken and (!too_large or depth == 0)) {
            _ = appendSphericalLocalProjectedCell(base_view, face_index, far_distance, s00, s10, s11, s01, cells, cell_count);
            return;
        }
    }

    if (depth > 0) {
        const top_mid = lerpVec3(quad[0], quad[1], 0.5);
        const right_mid = lerpVec3(quad[1], quad[2], 0.5);
        const bottom_mid = lerpVec3(quad[3], quad[2], 0.5);
        const left_mid = lerpVec3(quad[0], quad[3], 0.5);

        appendSphericalLocalCellRecursive(base_view, render_view, render_pass, screen, .{ quad[0], top_mid, center_local, left_mid }, face_index, depth - 1, far_distance, cells, cell_count);
        appendSphericalLocalCellRecursive(base_view, render_view, render_pass, screen, .{ top_mid, quad[1], right_mid, center_local }, face_index, depth - 1, far_distance, cells, cell_count);
        appendSphericalLocalCellRecursive(base_view, render_view, render_pass, screen, .{ center_local, right_mid, quad[2], bottom_mid }, face_index, depth - 1, far_distance, cells, cell_count);
        appendSphericalLocalCellRecursive(base_view, render_view, render_pass, screen, .{ left_mid, center_local, bottom_mid, quad[3] }, face_index, depth - 1, far_distance, cells, cell_count);
        return;
    }

    if (!center_visible) return;

    const center_point = center.projected.?;
    const fill = nativeCurvedFillColor(base_view.metric, face_index, center.distance, base_view.clip.near, far_distance);
    const corners = [_]curved.ProjectedSample{ s00, s10, s11, s01 };
    const next = [_]usize{ 1, 2, 3, 0 };
    for (corners, 0..) |corner, i| {
        const adjacent = corners[next[i]];
        if (!sampleVisible(corner) or !sampleVisible(adjacent)) continue;

        const p0 = corner.projected.?;
        const p1 = adjacent.projected.?;
        if (curved.shouldBreakProjectedSegment(render_view.projection, center_point, p0, screen.width, screen.height) or
            curved.shouldBreakProjectedSegment(render_view.projection, center_point, p1, screen.width, screen.height) or
            curved.shouldBreakProjectedSegment(render_view.projection, p0, p1, screen.width, screen.height))
        {
            continue;
        }

        if (cell_count.* >= cells.len) return;
        var poly: [8]rl.Vector2 = undefined;
        poly[0] = .{ .x = center_point[0] * @as(f32, @floatFromInt(subpixel_x)), .y = center_point[1] * @as(f32, @floatFromInt(subpixel_y)) };
        poly[1] = .{ .x = p0[0] * @as(f32, @floatFromInt(subpixel_x)), .y = p0[1] * @as(f32, @floatFromInt(subpixel_y)) };
        poly[2] = .{ .x = p1[0] * @as(f32, @floatFromInt(subpixel_x)), .y = p1[1] * @as(f32, @floatFromInt(subpixel_y)) };
        cells[cell_count.*] = .{
            .points = poly,
            .depths = .{
                sampleRasterDepth(center),
                sampleRasterDepth(corner),
                sampleRasterDepth(adjacent),
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
            },
            .len = 3,
            .fill = fill,
        };
        cell_count.* += 1;
    }
}

fn appendSphericalLocalFaceCells(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    quad: [4]curved.Vec3,
    face_index: usize,
    cells: *[max_spherical_local_cells]SphericalRasterCell,
    cell_count: *usize,
) void {
    const fill_steps = sphericalLocalFillSteps(render_view);
    const grid_side = max_spherical_fill_steps + 1;
    var samples: [grid_side * grid_side]curved.Vec3 = undefined;

    for (0..fill_steps + 1) |ui| {
        const u = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(fill_steps));
        for (0..fill_steps + 1) |vi| {
            const v = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(fill_steps));
            samples[ui * grid_side + vi] = bilerpCurvedQuad(quad[0], quad[1], quad[2], quad[3], u, v);
        }
    }

    const far_distance = base_view.shadeFarDistance();
    for (0..fill_steps) |ui| {
        for (0..fill_steps) |vi| {
            appendSphericalLocalCellRecursive(
                base_view,
                render_view,
                render_pass,
                screen,
                .{
                    samples[ui * grid_side + vi],
                    samples[(ui + 1) * grid_side + vi],
                    samples[(ui + 1) * grid_side + (vi + 1)],
                    samples[ui * grid_side + (vi + 1)],
                },
                face_index,
                spherical_local_subdivide_depth,
                far_distance,
                cells,
                cell_count,
            );
        }
    }
}

fn drawSphericalLocalGeometry(
    base_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    screen: curved.Screen,
    local_vertices: []const demo.H.Vector,
    faces: []const [4]usize,
    pixels: []rl.Color,
    depth_buffer: []f32,
) void {
    var cells = &spherical_local_cells_storage;
    var cell_count: usize = 0;

    for (faces, 0..) |face, face_index| {
        appendSphericalLocalFaceCells(
            base_view,
            render_view,
            render_pass,
            screen,
            .{
                vec3FromVector(local_vertices[face[0]]),
                vec3FromVector(local_vertices[face[1]]),
                vec3FromVector(local_vertices[face[2]]),
                vec3FromVector(local_vertices[face[3]]),
            },
            face_index,
            cells,
            &cell_count,
        );
    }

    for (cells[0..cell_count]) |cell| {
        rasterizeSphericalCell(cell, pixels, depth_buffer);
    }
}

fn drawSphericalLocalSegment(
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
    const edge_steps = sphericalLocalEdgeSteps(render_view);

    for (0..edge_steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(edge_steps));
        const sample = sampleSphericalLocalPoint(base_view, render_view, render_pass, lerpVec3(a, b, t), screen);
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

fn clearOverlayPixels(pixels: []rl.Color, depth_buffer: []f32) void {
    std.debug.assert(pixels.len == depth_buffer.len);
    @memset(pixels, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
    @memset(depth_buffer, std.math.inf(f32));
}

fn edgeFunction(a: rl.Vector2, b: rl.Vector2, p: rl.Vector2) f32 {
    return (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x);
}

fn writeOverlayPixel(
    pixels: []rl.Color,
    depth_buffer: []f32,
    x: i32,
    y: i32,
    depth: f32,
    color: rl.Color,
) void {
    if (x < 0 or y < 0) return;
    if (x >= @as(i32, @intCast(canvas_width * subpixel_x)) or y >= @as(i32, @intCast(canvas_height * subpixel_y))) return;

    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    const idx = uy * (canvas_width * subpixel_x) + ux;
    if (depth >= depth_buffer[idx]) return;

    depth_buffer[idx] = depth;
    pixels[idx] = color;
}

fn rasterizeOverlayTriangle(
    pixels: []rl.Color,
    depth_buffer: []f32,
    p0: rl.Vector2,
    p1: rl.Vector2,
    p2: rl.Vector2,
    d0: f32,
    d1: f32,
    d2: f32,
    color: rl.Color,
) void {
    const area = edgeFunction(p0, p1, p2);
    if (@abs(area) <= 1e-5) return;
    const edge_epsilon: f32 = 0.75;

    const min_x = @max(0, @as(i32, @intFromFloat(@floor(@min(p0.x, @min(p1.x, p2.x)) - 1.0))));
    const max_x = @min(@as(i32, @intCast(canvas_width * subpixel_x - 1)), @as(i32, @intFromFloat(@ceil(@max(p0.x, @max(p1.x, p2.x)) + 1.0))));
    const min_y = @max(0, @as(i32, @intFromFloat(@floor(@min(p0.y, @min(p1.y, p2.y)) - 1.0))));
    const max_y = @min(@as(i32, @intCast(canvas_height * subpixel_y - 1)), @as(i32, @intFromFloat(@ceil(@max(p0.y, @max(p1.y, p2.y)) + 1.0))));

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const point = rl.Vector2{
                .x = @as(f32, @floatFromInt(x)) + 0.5,
                .y = @as(f32, @floatFromInt(y)) + 0.5,
            };
            const w0 = edgeFunction(p1, p2, point);
            const w1 = edgeFunction(p2, p0, point);
            const w2 = edgeFunction(p0, p1, point);
            const inside = if (area > 0.0)
                (w0 >= -edge_epsilon and w1 >= -edge_epsilon and w2 >= -edge_epsilon)
            else
                (w0 <= edge_epsilon and w1 <= edge_epsilon and w2 <= edge_epsilon);
            if (!inside) continue;

            const inv_area = 1.0 / area;
            const b0 = w0 * inv_area;
            const b1 = w1 * inv_area;
            const b2 = w2 * inv_area;
            const depth = b0 * d0 + b1 * d1 + b2 * d2;
            writeOverlayPixel(pixels, depth_buffer, x, y, depth, color);
        }
    }
}

fn rasterizeSphericalCell(cell: SphericalRasterCell, pixels: []rl.Color, depth_buffer: []f32) void {
    if (cell.len < 3) return;
    var i: usize = 1;
    while (i + 1 < cell.len) : (i += 1) {
        rasterizeOverlayTriangle(
            pixels,
            depth_buffer,
            cell.points[0],
            cell.points[i],
            cell.points[i + 1],
            cell.depths[0],
            cell.depths[i],
            cell.depths[i + 1],
            cell.fill,
        );
    }
}

fn rasterizeSphericalGroundCellOverlay(
    fill: rl.Color,
    s00: curved.ProjectedSample,
    s10: curved.ProjectedSample,
    s11: curved.ProjectedSample,
    s01: curved.ProjectedSample,
    pixels: []rl.Color,
    depth_buffer: []f32,
) void {
    var cell = SphericalRasterCell{
        .points = undefined,
        .depths = .{
            sampleRasterDepth(s00),
            sampleRasterDepth(s10),
            sampleRasterDepth(s11),
            sampleRasterDepth(s01),
            0.0,
            0.0,
            0.0,
            0.0,
        },
        .len = 4,
        .fill = fill,
    };
    cell.points[0] = .{ .x = s00.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = s00.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    cell.points[1] = .{ .x = s10.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = s10.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    cell.points[2] = .{ .x = s11.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = s11.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    cell.points[3] = .{ .x = s01.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = s01.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    rasterizeSphericalCell(cell, pixels, depth_buffer);
}

fn rasterizeSphericalGroundTriangleOverlay(
    fill: rl.Color,
    a: curved.ProjectedSample,
    b: curved.ProjectedSample,
    c: curved.ProjectedSample,
    pixels: []rl.Color,
    depth_buffer: []f32,
) void {
    var cell = SphericalRasterCell{
        .points = undefined,
        .depths = .{
            sampleRasterDepth(a),
            sampleRasterDepth(b),
            sampleRasterDepth(c),
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
        },
        .len = 3,
        .fill = fill,
    };
    cell.points[0] = .{ .x = a.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = a.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    cell.points[1] = .{ .x = b.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = b.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    cell.points[2] = .{ .x = c.projected.?[0] * @as(f32, @floatFromInt(subpixel_x)), .y = c.projected.?[1] * @as(f32, @floatFromInt(subpixel_y)) };
    rasterizeSphericalCell(cell, pixels, depth_buffer);
}

fn rasterizeSphericalGroundPolarCellOverlay(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    screen: curved.Screen,
    r0: f32,
    r1: f32,
    theta0: f32,
    theta1: f32,
    checker: bool,
    depth: usize,
    far_distance: f32,
    pixels: []rl.Color,
    depth_buffer: []f32,
) void {
    const c00 = sphericalGroundPolarPoint(r0, theta0);
    const c10 = sphericalGroundPolarPoint(r1, theta0);
    const c11 = sphericalGroundPolarPoint(r1, theta1);
    const c01 = sphericalGroundPolarPoint(r0, theta1);
    const center_radius = (r0 + r1) * 0.5;
    const center_theta = (theta0 + theta1) * 0.5;
    const cc = sphericalGroundPolarPoint(center_radius, center_theta);

    const s00 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c00.lateral, c00.forward, screen);
    const s10 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c10.lateral, c10.forward, screen);
    const s11 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c11.lateral, c11.forward, screen);
    const s01 = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, c01.lateral, c01.forward, screen);
    const center = groundSampleForCurvedRender(world_view, render_view, render_pass, basis, cc.lateral, cc.forward, screen);

    var visible_count: usize = 0;
    if (sampleVisible(s00)) visible_count += 1;
    if (sampleVisible(s10)) visible_count += 1;
    if (sampleVisible(s11)) visible_count += 1;
    if (sampleVisible(s01)) visible_count += 1;
    const center_visible = sampleVisible(center);

    if (visible_count == 0 and !center_visible) return;

    if (visible_count == 4 and center_visible) {
        const p00 = s00.projected.?;
        const p10 = s10.projected.?;
        const p11 = s11.projected.?;
        const p01 = s01.projected.?;
        const broken = groundCellBroken(render_view, screen, p00, p10, p11, p01);
        const too_large = projectedQuadTooLarge(p00, p10, p11, p01, screen, 0.24);
        if (!broken and (!too_large or depth == 0)) {
            const avg_distance = (s00.distance + s10.distance + s11.distance + s01.distance) * 0.25;
            const fill = groundFillColor(render_view.metric, avg_distance, render_view.clip.near, far_distance, checker);
            rasterizeSphericalGroundCellOverlay(fill, s00, s10, s11, s01, pixels, depth_buffer);
            return;
        }
    }

    if (depth > 0) {
        const radius_mid = (r0 + r1) * 0.5;
        const theta_mid = (theta0 + theta1) * 0.5;
        rasterizeSphericalGroundPolarCellOverlay(world_view, render_view, render_pass, basis, screen, r0, radius_mid, theta0, theta_mid, checker, depth - 1, far_distance, pixels, depth_buffer);
        rasterizeSphericalGroundPolarCellOverlay(world_view, render_view, render_pass, basis, screen, radius_mid, r1, theta0, theta_mid, checker, depth - 1, far_distance, pixels, depth_buffer);
        rasterizeSphericalGroundPolarCellOverlay(world_view, render_view, render_pass, basis, screen, radius_mid, r1, theta_mid, theta1, checker, depth - 1, far_distance, pixels, depth_buffer);
        rasterizeSphericalGroundPolarCellOverlay(world_view, render_view, render_pass, basis, screen, r0, radius_mid, theta_mid, theta1, checker, depth - 1, far_distance, pixels, depth_buffer);
        return;
    }

    if (!center_visible) return;

    const fill = groundFillColor(render_view.metric, center.distance, render_view.clip.near, far_distance, checker);
    const corners = [_]curved.ProjectedSample{ s00, s10, s11, s01 };
    const next = [_]usize{ 1, 2, 3, 0 };
    for (corners, 0..) |corner, i| {
        const adjacent = corners[next[i]];
        if (!sampleVisible(corner) or !sampleVisible(adjacent)) continue;
        const center_point = center.projected.?;
        const p0 = corner.projected.?;
        const p1 = adjacent.projected.?;
        if (curved.shouldBreakProjectedSegment(render_view.projection, center_point, p0, screen.width, screen.height) or
            curved.shouldBreakProjectedSegment(render_view.projection, center_point, p1, screen.width, screen.height) or
            curved.shouldBreakProjectedSegment(render_view.projection, p0, p1, screen.width, screen.height))
        {
            continue;
        }
        rasterizeSphericalGroundTriangleOverlay(fill, center, corner, adjacent, pixels, depth_buffer);
    }
}

fn rasterizeSphericalGroundPatchOverlay(
    world_view: curved.View,
    render_view: curved.View,
    render_pass: CurvedRenderPass,
    basis: GroundBasis,
    screen: curved.Screen,
    pixels: []rl.Color,
    depth_buffer: []f32,
) void {
    const max_radius = sphericalGroundTangentRadius(world_view.params);
    const far_distance = render_view.shadeFarDistance();
    const tau = @as(f32, std.math.pi) * 2.0;

    for (0..spherical_ground_radial_steps) |ri| {
        const t0 = @as(f32, @floatFromInt(ri)) / @as(f32, @floatFromInt(spherical_ground_radial_steps));
        const t1 = @as(f32, @floatFromInt(ri + 1)) / @as(f32, @floatFromInt(spherical_ground_radial_steps));
        const r0 = sphericalGroundRingRadius(max_radius, t0);
        const r1 = sphericalGroundRingRadius(max_radius, t1);

        for (0..spherical_ground_angular_steps) |ai| {
            const a0 = tau * @as(f32, @floatFromInt(ai)) / @as(f32, @floatFromInt(spherical_ground_angular_steps));
            const a1 = tau * @as(f32, @floatFromInt(ai + 1)) / @as(f32, @floatFromInt(spherical_ground_angular_steps));
            rasterizeSphericalGroundPolarCellOverlay(
                world_view,
                render_view,
                render_pass,
                basis,
                screen,
                r0,
                r1,
                a0,
                a1,
                ((ri + ai) & 1) == 0,
                spherical_ground_subdivide_depth,
                far_distance,
                pixels,
                depth_buffer,
            );
        }
    }
}

fn rasterizeSphericalNativeOverlay(app: *const demo.App, pixels: []rl.Color, depth_buffer: []f32) bool {
    const scene = demo.curvedScene(app.*, canvas_width, canvas_height) orelse return false;
    const spherical = switch (scene) {
        .spherical => |value| value,
        else => return false,
    };
    clearOverlayPixels(pixels, depth_buffer);

    const render_view = if (app.camera.movement_mode == .walk)
        liftedWalkView(spherical.view, app.camera.euclid_pitch)
    else
        spherical.view;

    if (app.camera.movement_mode == .walk and spherical.view.projection != .wrapped) {
        const ground_basis = worldGroundBasis(.spherical);
        const ground_far_start = benchStart();
        rasterizeSphericalGroundPatchOverlay(
            spherical.view,
            render_view,
            .{ .spherical = .far },
            ground_basis,
            spherical.screen,
            pixels,
            depth_buffer,
        );
        benchAdd(.spherical_ground, ground_far_start);
        const ground_near_start = benchStart();
        rasterizeSphericalGroundPatchOverlay(
            spherical.view,
            render_view,
            .{ .spherical = .near },
            ground_basis,
            spherical.screen,
            pixels,
            depth_buffer,
        );
        benchAdd(.spherical_ground, ground_near_start);
    }

    if (spherical.view.projection != .wrapped) {
        const far_start = benchStart();
        drawSphericalLocalGeometry(
            render_view,
            render_view.sphericalRenderPass(.far),
            .{ .spherical = .far },
            spherical.screen,
            spherical.local_vertices[0..],
            demo.cube_faces[0..],
            pixels,
            depth_buffer,
        );
        benchAdd(.spherical_geometry_far, far_start);

        const near_start = benchStart();
        drawSphericalLocalGeometry(
            render_view,
            render_view.sphericalRenderPass(.near),
            .{ .spherical = .near },
            spherical.screen,
            spherical.local_vertices[0..],
            demo.cube_faces[0..],
            pixels,
            depth_buffer,
        );
        benchAdd(.spherical_geometry_near, near_start);
    } else {
        const geom_start = benchStart();
        drawSphericalLocalGeometry(
            render_view,
            render_view,
            .direct,
            spherical.screen,
            spherical.local_vertices[0..],
            demo.cube_faces[0..],
            pixels,
            depth_buffer,
        );
        benchAdd(.spherical_geometry_near, geom_start);
    }

    return true;
}

fn drawNativeCurvedScene(app: *const demo.App, viewport: rl.Rectangle, spherical_overlay: ?rl.Texture2D) void {
    const scene = demo.curvedScene(app.*, canvas_width, canvas_height) orelse return;

    switch (scene) {
        .hyperbolic => |hyper| {
            const render_view = if (app.camera.movement_mode == .walk)
                liftedWalkView(hyper.view, app.camera.euclid_pitch)
            else
                hyper.view;
            drawCurvedSceneBackdrop(render_view, viewport);
            if (app.camera.movement_mode == .walk) {
                const ground_basis = walkGroundBasis(hyper.view, app.camera.euclid_pitch) orelse worldGroundBasis(hyper.view.metric);
                drawCurvedGroundPatch(
                    hyper.view,
                    render_view,
                    .direct,
                    ground_basis,
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
            const render_view = if (app.camera.movement_mode == .walk)
                liftedWalkView(spherical.view, app.camera.euclid_pitch)
            else
                spherical.view;
            const backdrop_start = benchStart();
            drawCurvedSceneBackdrop(render_view, viewport);
            benchAdd(.spherical_backdrop, backdrop_start);
            if (spherical.view.projection == .wrapped) {
                if (app.camera.movement_mode == .walk) {
                    const ground_start = benchStart();
                    const ground_basis = worldGroundBasis(.spherical);
                    drawSphericalGroundFullscreen(
                        render_view,
                        ground_basis,
                        spherical.screen,
                        viewport,
                    );
                    benchAdd(.spherical_ground, ground_start);
                }
            }
            if (spherical_overlay) |texture| drawCanvasTexture(texture, viewport);
            const navigator_start = benchStart();
            drawNativeSphericalNavigator(spherical.view, spherical.local_vertices[0..], demo.cube_edges[0..], viewport);
            benchAdd(.navigator, navigator_start);
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

fn nativeNavigatorPanels(viewport: rl.Rectangle) ?struct { top: rl.Rectangle, bottom: rl.Rectangle } {
    const margin = @max(16.0, viewport.width * 0.025);
    const gap = 14.0;
    const panel_width = std.math.clamp(viewport.width * 0.20, 160.0, 260.0);
    const panel_height = std.math.clamp(viewport.height * 0.135, 90.0, 130.0);
    const total_height = panel_height * 2.0 + gap;
    if (panel_width + margin * 2.0 >= viewport.width or total_height + margin * 2.0 >= viewport.height) return null;

    const x = viewport.x + viewport.width - panel_width - margin;
    const top_y = viewport.y + margin;
    return .{
        .top = .{ .x = x, .y = top_y, .width = panel_width, .height = panel_height },
        .bottom = .{ .x = x, .y = top_y + panel_height + gap, .width = panel_width, .height = panel_height },
    };
}

fn drawNativeNavigatorPanel(rect: rl.Rectangle) void {
    rl.DrawRectangleRec(
        .{ .x = rect.x + 8.0, .y = rect.y + 10.0, .width = rect.width, .height = rect.height },
        colorWithAlpha(scene_shadow, 180),
    );
    rl.DrawRectangleRec(rect, rl.Color{ .r = 10, .g = 16, .b = 24, .a = 228 });
    rl.DrawRectangleLinesEx(rect, 2.0, rl.Color{ .r = 44, .g = 60, .b = 84, .a = 255 });
}

fn drawNativeNavigatorAxes(rect: rl.Rectangle) void {
    const cx = rect.x + rect.width * 0.5;
    const cy = rect.y + rect.height * 0.5;
    rl.DrawLineEx(.{ .x = rect.x + 10.0, .y = cy }, .{ .x = rect.x + rect.width - 10.0, .y = cy }, 1.0, rl.Color{ .r = 42, .g = 48, .b = 62, .a = 255 });
    rl.DrawLineEx(.{ .x = cx, .y = rect.y + 10.0 }, .{ .x = cx, .y = rect.y + rect.height - 10.0 }, 1.0, rl.Color{ .r = 42, .g = 48, .b = 62, .a = 255 });
}

fn nativeNavigatorProject(rect: rl.Rectangle, extent: f32, horizontal: f32, vertical: f32) rl.Vector2 {
    const inner_left = rect.x + 10.0;
    const inner_top = rect.y + 10.0;
    const inner_width = rect.width - 20.0;
    const inner_height = rect.height - 20.0;
    return .{
        .x = inner_left + (horizontal / extent * 0.5 + 0.5) * inner_width,
        .y = inner_top + (0.5 - vertical / extent * 0.5) * inner_height,
    };
}

fn drawNativeNavigatorMarker(point: rl.Vector2, color: rl.Color) void {
    rl.DrawLineEx(.{ .x = point.x - 4.0, .y = point.y }, .{ .x = point.x + 4.0, .y = point.y }, 1.4, color);
    rl.DrawLineEx(.{ .x = point.x, .y = point.y - 4.0 }, .{ .x = point.x, .y = point.y + 4.0 }, 1.4, color);
}

fn nativeNavigatorPointReasonable(rect: rl.Rectangle, point: rl.Vector2) bool {
    const margin = @max(rect.width, rect.height) * 1.5;
    return point.x >= rect.x - margin and
        point.x <= rect.x + rect.width + margin and
        point.y >= rect.y - margin and
        point.y <= rect.y + rect.height + margin;
}

fn nativeNavigatorShouldBreak(rect: rl.Rectangle, a: rl.Vector2, b: rl.Vector2) bool {
    if (!nativeNavigatorPointReasonable(rect, a) or !nativeNavigatorPointReasonable(rect, b)) return true;
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const max_jump = @max(rect.width, rect.height) * 0.85;
    return dx * dx + dy * dy > max_jump * max_jump;
}

fn sphericalNativeOverviewCamera(view: curved.View) curved.Camera {
    const basis = view.walkBasis() orelse return .{
        .position = .{ 1.0, 0.0, 0.0, 0.0 },
        .right = .{ 0.0, 1.0, 0.0, 0.0 },
        .up = .{ 0.0, 0.0, 1.0, 0.0 },
        .forward = .{ 0.0, 0.0, 0.0, 1.0 },
    };
    return .{
        .position = view.camera.position,
        .right = basis.right,
        .up = basis.up,
        .forward = basis.forward,
    };
}

fn sphericalNativeOverviewRadius(view: curved.View, projection_mode: demo.SphericalMapProjection) f32 {
    return switch (projection_mode) {
        .stereographic => view.params.radius * (@as(f32, std.math.pi) * 0.5) * 0.98,
        .gnomonic => view.params.radius * 0.72,
    };
}

fn sphericalNativeMapPoint(
    map_camera: curved.Camera,
    ambient: curved.Vec4,
    projection_mode: demo.SphericalMapProjection,
) ?[2]f32 {
    const model: curved.CameraModel = switch (projection_mode) {
        .stereographic => .conformal,
        .gnomonic => .linear,
    };
    const point = curved.modelPointForAmbientWithCamera(.spherical, map_camera, ambient, model) orelse return null;
    return .{ point[0], point[2] };
}

fn sphericalNativeMapExtent(
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: demo.SphericalMapProjection,
    field_radius: f32,
) f32 {
    var extent: f32 = switch (projection_mode) {
        .stereographic => 2.2,
        .gnomonic => 1.2,
    };

    for (0..17) |i| {
        const t = @as(f32, @floatFromInt(i)) / 16.0;
        const theta = t * @as(f32, std.math.pi) * 2.0;
        const lateral = @cos(theta) * field_radius;
        const forward = @sin(theta) * field_radius;
        const ambient = curved.ambientFromTangentBasisPoint(
            .spherical,
            view.params,
            map_camera.position,
            map_camera.right,
            map_camera.forward,
            lateral,
            forward,
        ) orelse continue;
        const point = sphericalNativeMapPoint(map_camera, ambient, projection_mode) orelse continue;
        extent = @max(extent, @abs(point[0]) * 1.08);
        extent = @max(extent, @abs(point[1]) * 1.08);
    }

    return extent;
}

fn drawNativeSphericalGroundGridLine(
    rect: rl.Rectangle,
    extent: f32,
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: demo.SphericalMapProjection,
    constant_lateral: bool,
    fixed: f32,
    field_radius: f32,
    color: rl.Color,
) void {
    var prev: ?rl.Vector2 = null;

    for (0..49) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48.0;
        const sweep = (t * 2.0 - 1.0) * field_radius;
        const lateral = if (constant_lateral) fixed else sweep;
        const forward = if (constant_lateral) sweep else fixed;
        if (lateral * lateral + forward * forward > field_radius * field_radius) {
            prev = null;
            continue;
        }

        const ambient = curved.ambientFromTangentBasisPoint(
            .spherical,
            view.params,
            map_camera.position,
            map_camera.right,
            map_camera.forward,
            lateral,
            forward,
        ) orelse {
            prev = null;
            continue;
        };
        const map_point = sphericalNativeMapPoint(map_camera, ambient, projection_mode) orelse {
            prev = null;
            continue;
        };
        const point = nativeNavigatorProject(rect, extent, map_point[0], map_point[1]);
        if (!nativeNavigatorPointReasonable(rect, point)) {
            prev = null;
            continue;
        }
        if (prev) |pp| {
            if (!nativeNavigatorShouldBreak(rect, pp, point)) rl.DrawLineEx(pp, point, 1.1, color);
        }
        prev = point;
    }
}

fn drawNativeSphericalGroundBoundary(
    rect: rl.Rectangle,
    extent: f32,
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: demo.SphericalMapProjection,
    field_radius: f32,
    color: rl.Color,
) void {
    var prev: ?rl.Vector2 = null;
    for (0..21) |i| {
        const t = @as(f32, @floatFromInt(i)) / 20.0;
        const theta = t * @as(f32, std.math.pi) * 2.0;
        const ambient = curved.ambientFromTangentBasisPoint(
            .spherical,
            view.params,
            map_camera.position,
            map_camera.right,
            map_camera.forward,
            @cos(theta) * field_radius,
            @sin(theta) * field_radius,
        ) orelse {
            prev = null;
            continue;
        };
        const map_point = sphericalNativeMapPoint(map_camera, ambient, projection_mode) orelse {
            prev = null;
            continue;
        };
        const point = nativeNavigatorProject(rect, extent, map_point[0], map_point[1]);
        if (!nativeNavigatorPointReasonable(rect, point)) {
            prev = null;
            continue;
        }
        if (prev) |pp| {
            if (!nativeNavigatorShouldBreak(rect, pp, point)) rl.DrawLineEx(pp, point, 1.4, color);
        }
        prev = point;
    }
}

fn drawNativeSphericalLocalEdge(
    rect: rl.Rectangle,
    extent: f32,
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: demo.SphericalMapProjection,
    a_local: curved.Vec3,
    b_local: curved.Vec3,
    color: rl.Color,
) void {
    var prev: ?rl.Vector2 = null;
    for (0..9) |i| {
        const t = @as(f32, @floatFromInt(i)) / 8.0;
        const local = lerpVec3(a_local, b_local, t);
        const ambient = signedAmbientForView(view, demo.sphericalDemoAmbientPoint(view.params, local));
        const map_point = sphericalNativeMapPoint(map_camera, ambient, projection_mode) orelse {
            prev = null;
            continue;
        };
        const point = nativeNavigatorProject(rect, extent, map_point[0], map_point[1]);
        if (!nativeNavigatorPointReasonable(rect, point)) {
            prev = null;
            continue;
        }
        if (prev) |pp| {
            if (!nativeNavigatorShouldBreak(rect, pp, point)) rl.DrawLineEx(pp, point, 1.5, color);
        }
        prev = point;
    }
}

fn drawNativeSphericalNavigatorPanel(
    rect: rl.Rectangle,
    label: [:0]const u8,
    view: curved.View,
    local_vertices: []const demo.H.Vector,
    edges: []const [2]usize,
    projection_mode: demo.SphericalMapProjection,
) void {
    const map_camera = sphericalNativeOverviewCamera(view);
    const field_radius = sphericalNativeOverviewRadius(view, projection_mode);
    const extent = sphericalNativeMapExtent(view, map_camera, projection_mode, field_radius);

    drawNativeNavigatorPanel(rect);
    rl.BeginScissorMode(
        @as(c_int, @intFromFloat(@round(rect.x))),
        @as(c_int, @intFromFloat(@round(rect.y))),
        @as(c_int, @intFromFloat(@round(rect.width))),
        @as(c_int, @intFromFloat(@round(rect.height))),
    );
    drawNativeNavigatorAxes(rect);
    drawNavigatorLabel(label, .{ .x = rect.x + 10.0, .y = rect.y + 10.0 });

    drawNativeSphericalGroundBoundary(rect, extent, view, map_camera, projection_mode, field_radius, rl.Color{ .r = 92, .g = 122, .b = 138, .a = 255 });

    var line_index: i32 = -2;
    while (line_index <= 2) : (line_index += 1) {
        const line_t = @as(f32, @floatFromInt(line_index)) / 2.0;
        const fixed = line_t * field_radius;
        drawNativeSphericalGroundGridLine(rect, extent, view, map_camera, projection_mode, true, fixed, field_radius, rl.Color{ .r = 70, .g = 106, .b = 118, .a = 255 });
        drawNativeSphericalGroundGridLine(rect, extent, view, map_camera, projection_mode, false, fixed, field_radius, rl.Color{ .r = 56, .g = 88, .b = 96, .a = 255 });
    }

    for (edges) |edge| {
        drawNativeSphericalLocalEdge(
            rect,
            extent,
            view,
            map_camera,
            projection_mode,
            vec3FromVector(local_vertices[edge[0]]),
            vec3FromVector(local_vertices[edge[1]]),
            rl.Color{ .r = 112, .g = 208, .b = 255, .a = 255 },
        );
    }

    const eye = nativeNavigatorProject(rect, extent, 0.0, 0.0);
    const heading_ambient = curved.ambientFromTangentBasisPoint(
        .spherical,
        view.params,
        map_camera.position,
        map_camera.right,
        map_camera.forward,
        0.0,
        field_radius * 0.18,
    ) orelse return;
    const look_map = sphericalNativeMapPoint(map_camera, heading_ambient, projection_mode) orelse return;
    const look = nativeNavigatorProject(rect, extent, look_map[0], look_map[1]);
    if (!nativeNavigatorShouldBreak(rect, eye, look)) {
        rl.DrawLineEx(eye, look, 1.6, rl.Color{ .r = 244, .g = 246, .b = 255, .a = 255 });
    }
    drawNativeNavigatorMarker(eye, rl.Color{ .r = 248, .g = 210, .b = 84, .a = 255 });
    drawNativeNavigatorMarker(look, rl.Color{ .r = 244, .g = 246, .b = 255, .a = 255 });
    rl.EndScissorMode();
}

fn drawNativeSphericalNavigator(
    view: curved.View,
    local_vertices: []const demo.H.Vector,
    edges: []const [2]usize,
    viewport: rl.Rectangle,
) void {
    const panels = nativeNavigatorPanels(viewport) orelse return;
    drawNativeSphericalNavigatorPanel(panels.top, "ST", view, local_vertices, edges, .stereographic);
    drawNativeSphericalNavigatorPanel(panels.bottom, "GN", view, local_vertices, edges, .gnomonic);
}

fn drawCurvedNavigatorLabels(viewport: rl.Rectangle, mode: demo.DemoMode) void {
    const region = curvedNavigatorRegion() orelse return;
    const panel_height = @min(@as(usize, 10), @max(@as(usize, 7), canvas_height / 5));
    const gap: usize = 2;
    const panel_x = region.x;
    const top_y = region.y;
    const bottom_y = top_y + panel_height + gap;

    const top_anchor = canvasPointToViewport(viewport, .{ @floatFromInt(panel_x), @floatFromInt(top_y) });
    const bottom_anchor = canvasPointToViewport(viewport, .{ @floatFromInt(panel_x), @floatFromInt(bottom_y) });
    if (mode == .spherical) {
        drawNavigatorLabel("ST", .{ .x = top_anchor.x + 10.0, .y = top_anchor.y + 10.0 });
        drawNavigatorLabel("GN", .{ .x = bottom_anchor.x + 10.0, .y = bottom_anchor.y + 10.0 });
    } else {
        drawNavigatorLabel("XZ", .{ .x = top_anchor.x + 10.0, .y = top_anchor.y + 10.0 });
        drawNavigatorLabel("ZY", .{ .x = bottom_anchor.x + 10.0, .y = bottom_anchor.y + 10.0 });
    }
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

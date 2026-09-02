const std = @import("std");
const scene = @import("scene.zig");

const rl = @cImport({
    @cInclude("stdlib.h");
    @cInclude("raylib.h");
});

const render_width = 960;
const render_height = 540;

const default_capture_walk: f32 = scene.default_cube_distance + std.math.pi * scene.default_radius - 0.15;
const default_capture_pitch: f32 = -1.4;

pub fn main() void {
    const capture_path = rl.getenv("ZMATH_DEMO_CAPTURE");
    const capture = capture_path != null;

    var flags: c_uint = rl.FLAG_WINDOW_RESIZABLE;
    if (capture) {
        flags |= rl.FLAG_WINDOW_HIDDEN;
    } else {
        flags |= rl.FLAG_VSYNC_HINT;
    }
    rl.SetConfigFlags(flags);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(1280, 720, "zmath demo: spherical game");
    defer rl.CloseWindow();

    var world = scene.Scene.init();
    if (capture) {
        const walk = if (rl.getenv("ZMATH_DEMO_WALK")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch default_capture_walk
        else
            default_capture_walk;
        const pitch = if (rl.getenv("ZMATH_DEMO_PITCH")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch default_capture_pitch
        else
            default_capture_pitch;
        world.walkForward(walk);
        if (pitch != 0.0) world.pitch(pitch);
    }

    const image = rl.GenImageColor(render_width, render_height, color(0, 0, 0, 255));
    defer rl.UnloadImage(image);
    const texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);
    const pixels: [*]u8 = @ptrCast(image.data.?);

    // Optional frame cap for headless perf measurement.
    const frame_cap: ?u32 = if (rl.getenv("ZMATH_DEMO_FRAMES")) |value|
        std.fmt.parseInt(u32, std.mem.span(value), 10) catch null
    else
        null;
    var frames: u32 = 0;

    while (!rl.WindowShouldClose()) : (frames += 1) {
        if (frame_cap) |cap| {
            if (frames >= cap) break;
        }
        if (!capture) {
            const dt = @min(rl.GetFrameTime(), 0.05);
            update(&world, dt);
        }

        renderFrame(&world, pixels);
        rl.UpdateTexture(texture, pixels);

        rl.BeginDrawing();
        rl.ClearBackground(color(4, 6, 10, 255));
        drawScaled(texture);
        drawHud(&world);
        rl.EndDrawing();

        if (capture) {
            rl.TakeScreenshot(capture_path.?);
            break;
        }
    }
}

fn update(world: *scene.Scene, dt: f32) void {
    if (rl.IsKeyPressed(rl.KEY_R)) world.* = scene.Scene.init();

    // Pace movement by the conjugate gap: the reverse-perspective morph
    // compresses into a small walk window around it, so ease off there.
    const speed_scale = scene.Scene.speedScaleForGap(world.conjugateGap());
    const move_speed: f32 = 2.2 * speed_scale;
    const look_speed: f32 = 1.35;
    if (rl.IsKeyDown(rl.KEY_S)) world.walkForward(-move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_W)) world.walkForward(move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_D)) world.strafeRight(move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_A)) world.strafeRight(-move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_LEFT)) world.yaw(look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_RIGHT)) world.yaw(-look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_UP)) world.pitch(-look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_DOWN)) world.pitch(look_speed * dt);
}

const RenderJob = struct {
    tracer: scene.Tracer,
    cam: scene.FrameCamera,
    pixels: [*]u8,
    row_start: usize,
    row_end: usize,
};

fn renderBand(job: RenderJob) void {
    for (job.row_start..job.row_end) |row| {
        for (0..render_width) |column| {
            const u = ((@as(f32, @floatFromInt(column)) + 0.5) / render_width) * 2.0 - 1.0;
            const v = 1.0 - ((@as(f32, @floatFromInt(row)) + 0.5) / render_height) * 2.0;
            const hit = job.tracer.trace(job.cam.direction(u, v));
            const rgb = shadeHit(hit);

            const offset = (row * render_width + column) * 4;
            job.pixels[offset] = rgb.r;
            job.pixels[offset + 1] = rgb.g;
            job.pixels[offset + 2] = rgb.b;
            job.pixels[offset + 3] = 255;
        }
    }
}

fn renderFrame(world: *scene.Scene, pixels: [*]u8) void {
    const job_base = RenderJob{
        .tracer = world.tracer(),
        .cam = world.frameCamera(),
        .pixels = pixels,
        .row_start = 0,
        .row_end = 0,
    };

    const thread_count: usize = @min(std.Thread.getCpuCount() catch 1, 8);
    const band = (render_height + thread_count - 1) / thread_count;
    var threads: [8]?std.Thread = @splat(null);
    defer {
        for (threads) |thread| {
            if (thread) |t| t.join();
        }
    }

    // First band on the spawning thread, the rest on workers.
    var start: usize = 0;
    var end = @min(start + band, render_height);
    var job = job_base;
    job.row_start = start;
    job.row_end = end;
    renderBand(job);
    start = end;

    var spawned: usize = 0;
    while (start < render_height) : (spawned += 1) {
        end = @min(start + band, render_height);
        job = job_base;
        job.row_start = start;
        job.row_end = end;
        threads[spawned] = std.Thread.spawn(.{}, renderBand, .{job}) catch blk: {
            renderBand(job);
            break :blk null;
        };
        start = end;
    }
}

fn shadeHit(hit: scene.Hit) rl.Color {
    // Monotone angle proxy (1 - cos a)/2 in [0, 1] - keeps the hot path
    // free of transcendentals while dimming identically in character.
    const dim = 1.0 - 0.25 * (1.0 - hit.cos_angle) / 2.0;
    return switch (hit.surface) {
        .cube => |face| scale(
            faceColor(face),
            (0.55 + 0.45 * hit.brightness) * dim,
        ),
        .ground => scale(groundColor(hit.point), 0.6 + 0.4 * hit.brightness),
    };
}

fn groundColor(point: scene.Point) rl.Color {
    // Checker in ground arc coordinates. The walk axis is the e4 direction
    // and the strafe axis sweeps the e1-e2 plane (see GroundPose.north).
    const walk = std.math.asin(std.math.clamp(sg_dot(point, axisWalk()), -1.0, 1.0)) * scene.default_radius;
    const strafe = scene.fastAtan2(sg_dot(point, axisStrafeB()), sg_dot(point, axisStrafeA())) * scene.default_radius;
    const cell: f32 = 1.0;
    const checker = (@as(i32, @intFromFloat(@floor(walk / cell))) +
        @as(i32, @intFromFloat(@floor(strafe / cell)))) & 1 == 0;
    return if (checker) color(92, 104, 96, 255) else color(46, 54, 50, 255);
}

fn drawScaled(texture: rl.Texture2D) void {
    const screen_width: f32 = @floatFromInt(rl.GetScreenWidth());
    const screen_height: f32 = @floatFromInt(rl.GetScreenHeight());
    const fit = @min(screen_width / render_width, screen_height / render_height);
    const dest_width = render_width * fit;
    const dest_height = render_height * fit;
    rl.DrawTexturePro(
        texture,
        .{ .x = 0, .y = 0, .width = render_width, .height = render_height },
        .{
            .x = (screen_width - dest_width) / 2.0,
            .y = (screen_height - dest_height) / 2.0,
            .width = dest_width,
            .height = dest_height,
        },
        .{ .x = 0, .y = 0 },
        0.0,
        color(255, 255, 255, 255),
    );
}

fn drawHud(world: *scene.Scene) void {
    const stats = scene.Scene.sampleFrame(world.*, 64, 36);

    rl.DrawRectangle(16, 16, 660, 92, color(4, 7, 12, 205));
    rl.DrawRectangleLines(16, 16, 660, 92, color(130, 155, 180, 110));
    rl.DrawText("S3 spherical-game demo (stereographic ray trace)", 30, 27, 22, color(246, 247, 241, 255));
    rl.DrawText("W/S move, A/D strafe, arrows look, R reset. Walk S past the far side, then look up: the roof centers and the walls wrap the sky.", 30, 57, 16, color(190, 204, 220, 235));

    var buffer: [192]u8 = undefined;
    const status = if (world.cubeBearingForwardCosine() < 0.0)
        std.fmt.bufPrintZ(
            &buffer,
            "the cube is behind you - turn around   faces {d}/5   frame cube {d:.0}%   {d} fps",
            .{ stats.visibleFaceCount(), stats.cubeFraction() * 100.0, rl.GetFPS() },
        ) catch return
    else
        std.fmt.bufPrintZ(
            &buffer,
            "cube distance {d:.2} / {d:.2}   faces {d}/5   frame cube {d:.0}%   {d} fps",
            .{
                world.distanceToCube(),
                std.math.pi * world.radius,
                stats.visibleFaceCount(),
                stats.cubeFraction() * 100.0,
                rl.GetFPS(),
            },
        ) catch return;
    rl.DrawText(status, 30, 82, 16, color(150, 174, 201, 230));
}

fn faceColor(face: scene.Face) rl.Color {
    return switch (face) {
        .left => color(82, 190, 224, 255),
        .right => color(245, 96, 83, 255),
        .top => color(255, 184, 77, 255),
        .front => color(92, 173, 126, 255),
        .back => color(143, 124, 230, 255),
        .bottom => color(30, 34, 44, 255),
    };
}

fn scale(base: rl.Color, factor: f32) rl.Color {
    return color(
        @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(base.r)) * factor, 0.0, 255.0)),
        @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(base.g)) * factor, 0.0, 255.0)),
        @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(base.b)) * factor, 0.0, 255.0)),
        255,
    );
}

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

const sg_dot = scene.dot;

fn axisWalk() scene.Point {
    return scene.Point.init(.{ 0, 0, 0, 1 });
}

fn axisStrafeA() scene.Point {
    return scene.Point.init(.{ 1, 0, 0, 0 });
}

fn axisStrafeB() scene.Point {
    return scene.Point.init(.{ 0, 1, 0, 0 });
}

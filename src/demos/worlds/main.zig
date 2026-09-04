//! Worlds demo: one executable, four spaces, live switching.
//!
//! Keys 1-4 rebuild the world mid-run as euclidean / isometric / spherical
//! / hyperbolic. Every world uses the same first-hit ray tracer contract
//! (`space.Mode`), the same face palette and checker ground, and the same
//! threaded row-band renderer, so the geometries can be compared directly.
const std = @import("std");
const space = @import("space.zig");
const s3scene = @import("spherical_scene");

const rl = @cImport({
    @cInclude("stdlib.h");
    @cInclude("raylib.h");
});

const render_width = 960;
const render_height = 540;

pub fn main() void {
    const capture_path = rl.getenv("ZMATH_DEMO_CAPTURE");
    const capture = capture_path != null;

    var flags: c_uint = rl.FLAG_WINDOW_RESIZABLE;
    if (capture) {
        flags |= rl.FLAG_WINDOW_HIDDEN;
    } else {
        flags |= rl.FLAG_VSYNC_HINT;
    }
    var world = space.Mode.init(initialKind());
    rl.SetConfigFlags(flags);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(1280, 720, titleFor(std.meta.activeTag(world)));
    defer rl.CloseWindow();

    if (capture) {
        const defaults = space.Mode.captureDefaults(std.meta.activeTag(world));
        const walk = if (rl.getenv("ZMATH_DEMO_WALK")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch defaults.walk
        else
            defaults.walk;
        const pitch = if (rl.getenv("ZMATH_DEMO_PITCH")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch defaults.pitch
        else
            defaults.pitch;
        world.applyCapture(walk, pitch);
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

fn kindFromName(name: []const u8) ?space.Kind {
    inline for (@typeInfo(space.Kind).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(space.Kind, field.name);
    }
    return null;
}

fn kindFromKey(key: c_int) ?space.Kind {
    return switch (key) {
        rl.KEY_ONE => .euclidean,
        rl.KEY_TWO => .isometric,
        rl.KEY_THREE => .spherical,
        rl.KEY_FOUR => .hyperbolic,
        else => null,
    };
}

fn initialKind() space.Kind {
    if (rl.getenv("ZMATH_DEMO_WORLD")) |name| {
        if (kindFromName(std.mem.span(name))) |kind| return kind;
    }
    return .euclidean;
}

fn titleFor(kind: space.Kind) [*:0]const u8 {
    return switch (kind) {
        .euclidean => "zmath demo: worlds [1] euclidean",
        .isometric => "zmath demo: worlds [2] isometric",
        .spherical => "zmath demo: worlds [3] spherical",
        .hyperbolic => "zmath demo: worlds [4] hyperbolic",
    };
}

fn switchToWorld(world: *space.Mode, k: space.Kind) void {
    world.* = space.Mode.init(k);
    rl.SetWindowTitle(titleFor(k));
    std.debug.print("worlds: active world -> {s}\n", .{@tagName(k)});
}

fn update(world: *space.Mode, dt: f32) void {
    // Drain the key queue with GetKeyPressed - one reliable path for all
    // switch keys (IsKeyPressed edge-polls proved flaky per key).
    while (true) {
        const pending = rl.GetKeyPressed();
        if (pending == 0) break;
        const kind: ?space.Kind = switch (pending) {
            rl.KEY_ONE, rl.KEY_KP_1 => .euclidean,
            rl.KEY_TWO, rl.KEY_KP_2 => .isometric,
            rl.KEY_THREE, rl.KEY_KP_3 => .spherical,
            rl.KEY_FOUR, rl.KEY_KP_4 => .hyperbolic,
            else => null,
        };
        if (kind) |k| {
            switchToWorld(world, k);
        } else if (pending == rl.KEY_TAB) {
            // Layout-independent cycle: Tab survives keymaps that remap
            // digits (non-QWERTY layouts, kanata-style remappers, WMs).
            const current: usize = @intFromEnum(std.meta.activeTag(world.*));
            switchToWorld(world, @enumFromInt((current + 1) % 4));
        } else if (pending == rl.KEY_R) {
            world.* = space.Mode.init(std.meta.activeTag(world.*));
        } else if (rl.getenv("ZMATH_DEMO_KEYLOG") != null) {
            std.debug.print("worlds: key event code {d}\n", .{pending});
        }
    }
    switch (world.*) {
        .euclidean => |*view| {
            const move: f32 = 4.0 * dt;
            const look: f32 = 1.6 * dt;
            if (rl.IsKeyDown(rl.KEY_S)) view.* = view.walkForward(-move);
            if (rl.IsKeyDown(rl.KEY_W)) view.* = view.walkForward(move);
            if (rl.IsKeyDown(rl.KEY_D)) view.* = view.strafeRight(move);
            if (rl.IsKeyDown(rl.KEY_A)) view.* = view.strafeRight(-move);
            if (rl.IsKeyDown(rl.KEY_LEFT)) view.* = view.yawBy(look);
            if (rl.IsKeyDown(rl.KEY_RIGHT)) view.* = view.yawBy(-look);
            if (rl.IsKeyDown(rl.KEY_UP)) view.* = view.pitchBy(look);
            if (rl.IsKeyDown(rl.KEY_DOWN)) view.* = view.pitchBy(-look);
        },
        .isometric => |*iso| {
            const pan_speed: f32 = 8.0 * dt;
            const rotate: f32 = 1.4 * dt;
            if (rl.IsKeyDown(rl.KEY_S)) iso.* = iso.pan(0.0, -pan_speed);
            if (rl.IsKeyDown(rl.KEY_W)) iso.* = iso.pan(0.0, pan_speed);
            if (rl.IsKeyDown(rl.KEY_D)) iso.* = iso.pan(pan_speed, 0.0);
            if (rl.IsKeyDown(rl.KEY_A)) iso.* = iso.pan(-pan_speed, 0.0);
            if (rl.IsKeyDown(rl.KEY_Q)) iso.* = iso.yawBy(rotate);
            if (rl.IsKeyDown(rl.KEY_E)) iso.* = iso.yawBy(-rotate);
            const wheel = rl.GetMouseWheelMove();
            if (wheel != 0.0) iso.* = iso.zoom(1.0 + 0.12 * wheel);
        },
        .spherical => |*s3| {
            // Pace movement by the conjugate gap (see the canonical demo).
            const move: f32 = 2.2 * s3scene.Scene.speedScaleForGap(s3.conjugateGap()) * dt;
            const look: f32 = 1.35 * dt;
            if (rl.IsKeyDown(rl.KEY_S)) s3.walkForward(-move);
            if (rl.IsKeyDown(rl.KEY_W)) s3.walkForward(move);
            if (rl.IsKeyDown(rl.KEY_D)) s3.strafeRight(move);
            if (rl.IsKeyDown(rl.KEY_A)) s3.strafeRight(-move);
            if (rl.IsKeyDown(rl.KEY_LEFT)) s3.yaw(look);
            if (rl.IsKeyDown(rl.KEY_RIGHT)) s3.yaw(-look);
            if (rl.IsKeyDown(rl.KEY_UP)) s3.pitch(-look);
            if (rl.IsKeyDown(rl.KEY_DOWN)) s3.pitch(look);
        },
        .hyperbolic => |*pose| {
            const move: f32 = 2.2 * dt;
            const look: f32 = 1.35 * dt;
            if (rl.IsKeyDown(rl.KEY_S)) pose.* = pose.walkForward(-move);
            if (rl.IsKeyDown(rl.KEY_W)) pose.* = pose.walkForward(move);
            if (rl.IsKeyDown(rl.KEY_D)) pose.* = pose.strafeRight(move);
            if (rl.IsKeyDown(rl.KEY_A)) pose.* = pose.strafeRight(-move);
            if (rl.IsKeyDown(rl.KEY_LEFT)) pose.* = pose.yaw(look);
            if (rl.IsKeyDown(rl.KEY_RIGHT)) pose.* = pose.yaw(-look);
            if (rl.IsKeyDown(rl.KEY_UP)) pose.* = pose.pitch(-look);
            if (rl.IsKeyDown(rl.KEY_DOWN)) pose.* = pose.pitch(look);
        },
    }
}

const RenderJob = struct {
    frame: space.Renderer,
    pixels: [*]u8,
    row_start: usize,
    row_end: usize,
};

fn renderBand(job: RenderJob) void {
    for (job.row_start..job.row_end) |row| {
        for (0..render_width) |column| {
            const u = ((@as(f32, @floatFromInt(column)) + 0.5) / render_width) * 2.0 - 1.0;
            const v = 1.0 - ((@as(f32, @floatFromInt(row)) + 0.5) / render_height) * 2.0;
            const hit = job.frame.render(u, v);
            const rgb = shadeHit(hit, v);

            const offset = (row * render_width + column) * 4;
            job.pixels[offset] = rgb.r;
            job.pixels[offset + 1] = rgb.g;
            job.pixels[offset + 2] = rgb.b;
            job.pixels[offset + 3] = 255;
        }
    }
}

fn renderFrame(world: *space.Mode, pixels: [*]u8) void {
    const job_base = RenderJob{
        .frame = world.renderer(),
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

fn shadeHit(hit: space.Hit, v: f32) rl.Color {
    const dim = 1.0 - 0.25 * hit.depth01;
    return switch (hit.surface) {
        .cube => |face| scale(
            faceColor(face),
            (0.55 + 0.45 * hit.brightness) * dim,
        ),
        .fence => scale(color(226, 218, 194, 255), (0.55 + 0.45 * hit.brightness) * dim),
        .ground => scale(groundColor(hit.cell), (0.6 + 0.4 * hit.brightness) * dim),
        .sky => scale(color(96, 128, 158, 255), 1.0 - 0.3 * @max(v, 0.0)),
    };
}

fn groundColor(cell: [2]f32) rl.Color {
    const cell_size: f32 = 1.0;
    const checker = (@as(i32, @intFromFloat(@floor(cell[0] / cell_size))) +
        @as(i32, @intFromFloat(@floor(cell[1] / cell_size)))) & 1 == 0;
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

fn drawHud(world: *space.Mode) void {
    const stats = space.sampleStats(world.*, 64, 36);

    var title_buffer: [128]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buffer, "worlds demo - {s}", .{world.label()}) catch return;

    rl.DrawRectangle(16, 16, 660, 92, color(4, 7, 12, 205));
    rl.DrawRectangleLines(16, 16, 660, 92, color(130, 155, 180, 110));
    rl.DrawText(title, 30, 27, 22, color(246, 247, 241, 255));

    var hint_buffer: [128]u8 = undefined;
    const hint = std.fmt.bufPrintZ(&hint_buffer, "{s}", .{world.hint()}) catch return;
    rl.DrawText(hint, 30, 57, 16, color(190, 204, 220, 235));

    var buffer: [160]u8 = undefined;
    const status = std.fmt.bufPrintZ(
        &buffer,
        "faces {d}/5   frame cube {d:.0}%   {d} fps",
        .{ stats.visibleFaceCount(), stats.cubeFraction() * 100.0, rl.GetFPS() },
    ) catch return;
    rl.DrawText(status, 30, 82, 16, color(150, 174, 201, 230));

    drawWorldSwitcher(world);
}

const WorldButton = struct { kind: space.Kind, label: [*:0]const u8 };

const world_buttons = [_]WorldButton{
    .{ .kind = .euclidean, .label = "[1] euclidean" },
    .{ .kind = .isometric, .label = "[2] isometric" },
    .{ .kind = .spherical, .label = "[3] spherical" },
    .{ .kind = .hyperbolic, .label = "[4] hyperbolic" },
};

/// Clickable world selector. Mouse input travels a different pipeline
/// than keyboard (compositor grabs and keymaps never touch it), so this
/// is the guaranteed switching path.
fn drawWorldSwitcher(world: *space.Mode) void {
    const mouse = rl.GetMousePosition();
    const active = std.meta.activeTag(world.*);
    for (world_buttons, 0..) |entry, i| {
        const rect = rl.Rectangle{
            .x = @floatFromInt(16 + i * 168),
            .y = 118,
            .width = 162,
            .height = 26,
        };
        if (entry.kind == active) {
            rl.DrawRectangleRec(rect, color(255, 184, 77, 255));
            rl.DrawText(entry.label, @intFromFloat(rect.x + 10), 124, 15, color(24, 26, 32, 255));
        } else {
            rl.DrawRectangleRec(rect, color(24, 30, 40, 230));
            rl.DrawRectangleLinesEx(rect, 1.0, color(130, 155, 180, 130));
            rl.DrawText(entry.label, @intFromFloat(rect.x + 10), 124, 15, color(150, 174, 201, 235));
            if (rl.CheckCollisionPointRec(mouse, rect) and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
                switchToWorld(world, entry.kind);
            }
        }
    }
}

fn faceColor(face: space.Face) rl.Color {
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

const std = @import("std");
const zmath = @import("zmath");
const canvas_api = zmath.render.canvas;
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
const hud_bg_color = rl.Color{ .r = 14, .g = 20, .b = 30, .a = 235 };
const white = rl.Color{ .r = 236, .g = 240, .b = 255, .a = 255 };
const hint = rl.Color{ .r = 163, .g = 177, .b = 202, .a = 255 };
const near_marker_color = rl.Color{ .r = 245, .g = 84, .b = 91, .a = 255 };
const far_marker_color = rl.Color{ .r = 102, .g = 214, .b = 145, .a = 255 };

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

        rasterizeCanvas(&canvas, pixels);
        rl.UpdateTexture(texture, @ptrCast(pixels.ptr));

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(bg_color);
        drawCanvasTexture(texture);
        drawHud(frame);
    }
}

fn consumeInput(app: *demo.App) bool {
    if (keyTriggered(rl.KEY_SPACE) and app.applyCommand(.next_mode)) return true;
    if (keyTriggered(rl.KEY_P) and app.applyCommand(.toggle_animation)) return true;
    if (keyTriggered(rl.KEY_G) and app.applyCommand(.toggle_movement_mode)) return true;
    if (keyTriggered(rl.KEY_V) and app.applyCommand(.cycle_projection)) return true;

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

fn drawCanvasTexture(texture: rl.Texture2D) void {
    const hud_height: f32 = 72.0;
    const screen_w = @as(f32, @floatFromInt(rl.GetScreenWidth()));
    const screen_h = @as(f32, @floatFromInt(rl.GetScreenHeight()));
    const available_h = @max(screen_h - hud_height, 1.0);
    const texture_w = @as(f32, @floatFromInt(texture.width));
    const texture_h = @as(f32, @floatFromInt(texture.height));
    const scale = @min(screen_w / texture_w, available_h / texture_h);

    const draw_w = texture_w * scale;
    const draw_h = texture_h * scale;
    const draw_x = (screen_w - draw_w) * 0.5;
    const draw_y = (available_h - draw_h) * 0.5;

    rl.DrawTexturePro(
        texture,
        .{ .x = 0.0, .y = 0.0, .width = texture_w, .height = texture_h },
        .{ .x = draw_x, .y = draw_y, .width = draw_w, .height = draw_h },
        .{ .x = 0.0, .y = 0.0 },
        0.0,
        white,
    );
}

fn drawHud(frame: demo.FrameInfo) void {
    const hud_height: c_int = 64;
    const hud_y = rl.GetScreenHeight() - hud_height;

    rl.DrawRectangle(0, hud_y, rl.GetScreenWidth(), hud_height, hud_bg_color);

    var status_buf: [256]u8 = undefined;
    const status = std.fmt.bufPrintZ(
        &status_buf,
        "{s} Z:{d:.2} C:{d:.2}/{d:.2} V:{s} M:{s} A:{s}",
        .{
            frame.mode_label,
            frame.zoom,
            frame.hyper_radius,
            frame.spherical_radius,
            frame.projection_label,
            frame.movement_label,
            if (frame.animate) "on" else "off",
        },
    ) catch unreachable;
    rl.DrawText(status.ptr, 12, hud_y + 8, 21, white);

    const help = "SPC/P/G/V/WASD/Ar/+/-/Q";
    rl.DrawText(help, 12, hud_y + 36, 18, hint);
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

const rl = @import("raylib");

const window_width: i32 = 1280;
const window_height: i32 = 720;

const background_top = rl.Color{ .r = 13, .g = 22, .b = 30, .a = 255 };
const background_bottom = rl.Color{ .r = 4, .g = 7, .b = 12, .a = 255 };
const card = rl.Color{ .r = 232, .g = 228, .b = 214, .a = 255 };
const ink = rl.Color{ .r = 24, .g = 26, .b = 27, .a = 255 };
const muted = rl.Color{ .r = 102, .g = 111, .b = 119, .a = 255 };
const amber = rl.Color{ .r = 255, .g = 179, .b = 71, .a = 255 };
const cyan = rl.Color{ .r = 100, .g = 211, .b = 255, .a = 255 };

pub fn main() !void {
    rl.setConfigFlags(.{
        .window_resizable = true,
        .vsync_hint = true,
    });
    rl.setTraceLogLevel(.warning);
    rl.initWindow(window_width, window_height, "zmath demo rebuild");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        const screen_width = rl.getScreenWidth();
        const screen_height = rl.getScreenHeight();
        const center = rl.Vector2{
            .x = @as(f32, @floatFromInt(screen_width)) * 0.5,
            .y = @as(f32, @floatFromInt(screen_height)) * 0.5,
        };

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.drawRectangleGradientV(0, 0, screen_width, screen_height, background_top, background_bottom);
        rl.drawCircleV(
            .{ .x = center.x - 220.0, .y = center.y - 130.0 },
            190.0,
            rl.Color{ .r = amber.r, .g = amber.g, .b = amber.b, .a = 48 },
        );
        rl.drawCircleV(
            .{ .x = center.x + 260.0, .y = center.y + 120.0 },
            230.0,
            rl.Color{ .r = cyan.r, .g = cyan.g, .b = cyan.b, .a = 42 },
        );

        const panel_width: i32 = 620;
        const panel_height: i32 = 220;
        const panel_x = @divTrunc(screen_width - panel_width, 2);
        const panel_y = @divTrunc(screen_height - panel_height, 2);

        rl.drawRectangle(panel_x + 12, panel_y + 14, panel_width, panel_height, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 88 });
        rl.drawRectangle(panel_x, panel_y, panel_width, panel_height, card);
        rl.drawRectangle(panel_x, panel_y, panel_width, 8, amber);
        rl.drawRectangle(panel_x + panel_width - 124, panel_y, 124, 8, cyan);

        rl.drawText("zmath demo", panel_x + 42, panel_y + 44, 44, ink);
        rl.drawText("the old raylib backend has been cleared", panel_x + 44, panel_y + 104, 22, muted);
        rl.drawText("raylib 6.0 + Zig 0.16 build path is alive", panel_x + 44, panel_y + 142, 22, ink);
    }
}

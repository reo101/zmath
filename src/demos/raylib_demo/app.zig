const std = @import("std");
const rl = @import("raylib");
const draw = @import("draw.zig");
const style = @import("style.zig");
const story = @import("story.zig");

const window_width: i32 = 1360;
const window_height: i32 = 820;

pub const App = struct {
    time: f32 = 0.0,
    paused: bool = false,

    pub fn init() App {
        return .{};
    }

    pub fn run(self: *App) !void {
        rl.setConfigFlags(.{
            .window_resizable = true,
            .vsync_hint = true,
        });
        rl.setTraceLogLevel(.warning);
        rl.initWindow(window_width, window_height, "zmath demo: VGA -> PGA -> CGA");
        defer rl.closeWindow();

        rl.setTargetFPS(60);

        while (!rl.windowShouldClose()) {
            self.update();
            self.render();
        }
    }

    fn update(self: *App) void {
        if (rl.isKeyPressed(.space)) self.paused = !self.paused;
        if (rl.isKeyPressed(.r)) self.time = 0.0;

        if (!self.paused) {
            self.time += rl.getFrameTime();
        }
    }

    fn render(self: *const App) void {
        const screen_w = rl.getScreenWidth();
        const screen_h = rl.getScreenHeight();

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.drawRectangleGradientV(0, 0, screen_w, screen_h, style.bg_top, style.bg_bottom);
        drawHeader(self, screen_w);

        const margin: f32 = 28.0;
        const gap: f32 = 18.0;
        const top: f32 = 124.0;
        const available_w = @as(f32, @floatFromInt(screen_w)) - margin * 2.0;
        const available_h = @as(f32, @floatFromInt(screen_h)) - top - 34.0;
        const panel_w = (available_w - gap * 2.0) / 3.0;
        const panel_h = available_h;

        const sample = story.sampleAt(self.time);
        const vga_rect = rl.Rectangle{ .x = margin, .y = top, .width = panel_w, .height = panel_h };
        const pga_rect = rl.Rectangle{ .x = margin + panel_w + gap, .y = top, .width = panel_w, .height = panel_h };
        const cga_rect = rl.Rectangle{ .x = margin + (panel_w + gap) * 2.0, .y = top, .width = panel_w, .height = panel_h };

        drawVgaPanel(vga_rect, sample);
        drawPgaPanel(pga_rect, sample);
        drawCgaPanel(cga_rect, sample);
    }
};

fn drawHeader(app: *const App, screen_w: i32) void {
    const title: [:0]const u8 = "one point, three carriers";
    const subtitle: [:0]const u8 = "VGA moves arrows, PGA adds a horizon, CGA lifts the same point onto a null cone";
    const controls: [:0]const u8 = if (app.paused) "Space: resume   R: reset" else "Space: pause   R: reset";

    rl.drawCircleV(.{ .x = 120.0, .y = 54.0 }, 112.0, style.alpha(style.amber, 34));
    rl.drawCircleV(.{ .x = @as(f32, @floatFromInt(screen_w)) - 160.0, .y = 68.0 }, 140.0, style.alpha(style.cyan, 28));
    draw.text(title, 34.0, 28.0, 40, style.white);
    draw.text(subtitle, 36.0, 78.0, 20, style.alpha(style.white, 188));
    draw.text(controls, @as(f32, @floatFromInt(screen_w)) - 250.0, 38.0, 20, style.alpha(style.white, 205));
}

fn drawVgaPanel(rect: rl.Rectangle, sample: story.Sample) void {
    draw.panel(rect, style.panel, "VGA", style.amber);

    const body = draw.inset(rect, 30.0);
    const units: f32 = @min(body.width, body.height) / 7.0;
    draw.grid(body, units, style.alpha(style.paper_line, 150));

    const origin = draw.plot(body, 0.0, 0.0, units);
    const p_screen = draw.plot(body, sample.x, sample.y, units);
    draw.arrow(origin, p_screen, 4.0, style.coral);
    draw.dot(p_screen, 7.0, style.coral);

    var buf: [160]u8 = undefined;
    draw.text("just a displacement in metric space", rect.x + 26.0, rect.y + 64.0, 18, style.muted);
    draw.textFmt(&buf, rect.x + 26.0, rect.y + rect.height - 84.0, 18, style.ink, "v = {d:.2}e1 + {d:.2}e2", .{ sample.x, sample.y });
    draw.textFmt(&buf, rect.x + 26.0, rect.y + rect.height - 56.0, 18, style.ink, "v*v = {d:.3}", .{sample.vga_norm2});
}

fn drawPgaPanel(rect: rl.Rectangle, sample: story.Sample) void {
    draw.panel(rect, style.panel_alt, "PGA", style.moss);

    const body = draw.inset(rect, 32.0);
    const units: f32 = @min(body.width, body.height) / 7.2;
    draw.grid(body, units, style.alpha(style.paper_line, 140));

    const horizon_y = body.y + 58.0;
    draw.line(.{ .x = body.x + 4.0, .y = horizon_y }, .{ .x = body.x + body.width - 4.0, .y = horizon_y }, 2.5, style.moss);
    draw.text("w=0", body.x + body.width - 54.0, horizon_y - 28.0, 18, style.moss);

    const p_screen = draw.plot(body, sample.x, sample.y, units);
    draw.dot(p_screen, 7.5, style.moss);

    const lane_a0 = draw.plot(body, -1.9, sample.y - 0.48, units);
    const lane_a1 = rl.Vector2{ .x = body.x + body.width - 18.0, .y = horizon_y + 10.0 };
    const lane_b0 = draw.plot(body, -1.9, sample.y + 0.48, units);
    const lane_b1 = rl.Vector2{ .x = body.x + body.width - 18.0, .y = horizon_y + 10.0 };
    draw.arrow(lane_a0, lane_a1, 2.0, style.alpha(style.moss, 180));
    draw.arrow(lane_b0, lane_b1, 2.0, style.alpha(style.moss, 180));
    draw.dot(lane_a1, 6.0, style.moss);

    var buf: [192]u8 = undefined;
    draw.text("finite points and ideal directions live together", rect.x + 26.0, rect.y + 64.0, 18, style.muted);
    draw.textFmt(
        &buf,
        rect.x + 26.0,
        rect.y + rect.height - 106.0,
        18,
        style.ink,
        "P = [{d:.0}:{d:.2}:{d:.2}]",
        .{ sample.pga_point[0], sample.pga_point[1], sample.pga_point[2] },
    );
    draw.textFmt(
        &buf,
        rect.x + 26.0,
        rect.y + rect.height - 78.0,
        18,
        style.ink,
        "parallel direction = [{d:.0}:{d:.0}:{d:.0}]",
        .{ sample.pga_direction[0], sample.pga_direction[1], sample.pga_direction[2] },
    );
    draw.text("the horizon is not off-screen; it is part of the algebra", rect.x + 26.0, rect.y + rect.height - 50.0, 18, style.ink);
}

fn drawCgaPanel(rect: rl.Rectangle, sample: story.Sample) void {
    draw.panel(rect, style.panel, "CGA", style.cyan);

    const body = draw.inset(rect, 38.0);
    const graph = rl.Rectangle{
        .x = body.x + 6.0,
        .y = body.y + 82.0,
        .width = body.width - 12.0,
        .height = body.height - 190.0,
    };
    const bounds = draw.Bounds{ .min_x = -2.25, .max_x = 2.25, .min_y = -0.25, .max_y = 3.25 };

    const x_axis_a = draw.mapRect(graph, bounds.min_x, 0.0, bounds);
    const x_axis_b = draw.mapRect(graph, bounds.max_x, 0.0, bounds);
    const y_axis_a = draw.mapRect(graph, 0.0, bounds.min_y, bounds);
    const y_axis_b = draw.mapRect(graph, 0.0, bounds.max_y, bounds);
    draw.line(x_axis_a, x_axis_b, 1.5, style.alpha(style.ink, 100));
    draw.line(y_axis_a, y_axis_b, 1.5, style.alpha(style.ink, 100));

    var prev: ?rl.Vector2 = null;
    var i: usize = 0;
    while (i <= 96) : (i += 1) {
        const u = bounds.min_x + (bounds.max_x - bounds.min_x) * @as(f32, @floatFromInt(i)) / 96.0;
        const lift = 0.5 * u * u;
        const p = draw.mapRect(graph, u, lift, bounds);
        if (prev) |q| draw.line(q, p, 2.0, style.alpha(style.cyan, 180));
        prev = p;
    }

    const lifted = draw.mapRect(graph, sample.x, sample.cga_lift, bounds);
    const base = draw.mapRect(graph, sample.x, 0.0, bounds);
    draw.line(base, lifted, 2.0, style.alpha(style.coral, 130));
    draw.dot(lifted, 8.0, style.cyan);
    draw.dot(draw.mapRect(graph, 0.0, 0.0, bounds), 5.0, style.amber);

    var buf: [224]u8 = undefined;

    draw.text("the point becomes a null vector with room for rounds", rect.x + 26.0, rect.y + 64.0, 18, style.muted);
    draw.text("n_o", graph.x + graph.width * 0.5 + 10.0, graph.y + graph.height - 6.0, 18, style.amber);
    draw.text("1/2 |p|^2 n_inf", graph.x + graph.width - 142.0, graph.y + 12.0, 18, style.cyan);
    draw.textFmt(&buf, rect.x + 26.0, rect.y + rect.height - 112.0, 18, style.ink, "P = n_o + p + {d:.3} n_inf", .{sample.cga_lift});
    draw.textFmt(&buf, rect.x + 26.0, rect.y + rect.height - 84.0, 18, style.ink, "p = {d:.2}e1 + {d:.2}e2", .{ sample.x, sample.y });
    draw.textFmt(&buf, rect.x + 26.0, rect.y + rect.height - 56.0, 18, style.ink, "P*P = {d:.5}", .{sample.cga_null_error});
}

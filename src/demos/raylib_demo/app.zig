const rl = @import("raylib");
const draw = @import("draw.zig");
const story = @import("story.zig");
const style = @import("style.zig");

const window_width: i32 = 1360;
const window_height: i32 = 820;

pub const App = struct {
    scene: story.State = story.State.init(),
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
        rl.initWindow(window_width, window_height, "zmath demo: walkable geometries");
        defer rl.closeWindow();

        rl.setTargetFPS(60);

        while (!rl.windowShouldClose()) {
            self.update();
            self.render();
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

        if (!self.paused) {
            self.scene.update(readInput(), rl.getFrameTime());
        }
    }

    fn render(self: *const App) void {
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

        rl.drawRectangleGradientV(0, 0, screen_w, screen_h, style.bg_top, style.bg_bottom);
        drawAtmosphere(screen, self.scene.mode);
        drawWorld(self.scene.mode, self.scene.activeCamera(), world_rect);
        drawHud(self, screen);
    }
};

const FaceRender = struct {
    points: [4]rl.Vector2,
    depth: f32,
    color: rl.Color,
};

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

fn drawWorld(mode: story.Mode, camera: story.Camera, rect: rl.Rectangle) void {
    const pass_order = if (mode == .spherical)
        [_]story.Pass{ .far, .main }
    else
        [_]story.Pass{ .main, .main };

    for (pass_order, 0..) |pass, pass_index| {
        if (mode != .spherical and pass_index != 0) continue;
        const fade: u8 = if (pass == .far) 72 else 255;

        drawGround(mode, camera, rect, pass, fade);
        drawCube(mode, camera, rect, pass, fade);
    }

    if (mode == .spherical) {
        const center = draw.centerOf(rect);
        const radius = @min(rect.width, rect.height) * 0.43;
        rl.drawCircleLines(draw.toInt(center.x), draw.toInt(center.y), radius, style.alpha(style.white, 58));
        draw.text("far hemisphere pass", center.x - radius + 18.0, center.y + radius - 30.0, 18, style.alpha(style.white, 150));
    }
}

fn drawGround(mode: story.Mode, camera: story.Camera, rect: rl.Rectangle, pass: story.Pass, fade: u8) void {
    var x: i32 = -8;
    while (x <= 8) : (x += 1) {
        const tint = if (@mod(x, 4) == 0) style.alpha(style.white, fade / 2) else style.alpha(style.white, fade / 5);
        drawWorldLine(
            mode,
            camera,
            rect,
            .{ .x = @floatFromInt(x), .y = 0.0, .z = -8.0 },
            .{ .x = @floatFromInt(x), .y = 0.0, .z = 18.0 },
            pass,
            tint,
            if (@mod(x, 4) == 0) 1.7 else 1.0,
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
            pass,
            tint,
            if (@mod(z, 4) == 0) 1.7 else 1.0,
        );
    }
}

fn drawCube(mode: story.Mode, camera: story.Camera, rect: rl.Rectangle, pass: story.Pass, fade: u8) void {
    const vertices = story.cubeVertices();
    var rendered: [story.cube_faces.len]FaceRender = undefined;
    var rendered_count: usize = 0;

    for (story.cube_faces, 0..) |face, face_index| {
        var points: [4]rl.Vector2 = undefined;
        var depth: f32 = 0.0;
        var visible = true;
        for (face.indices, 0..) |vertex_index, point_index| {
            const projected = story.project(mode, camera, vertices[vertex_index], rect, pass) orelse {
                visible = false;
                break;
            };
            points[point_index] = projected.pos;
            depth += projected.depth;
        }
        if (!visible) continue;

        const color = style.alpha(face_colors[face_index], if (pass == .far) fade else 214);
        rendered[rendered_count] = .{
            .points = points,
            .depth = depth / 4.0,
            .color = color,
        };
        rendered_count += 1;
    }

    sortFaces(rendered[0..rendered_count]);
    for (rendered[0..rendered_count]) |face| {
        draw.quad(face.points, face.color);
        draw.quadLines(face.points, 2.0, style.alpha(style.ink, if (pass == .far) 54 else 170));
    }

    for (story.cube_edges) |edge| {
        const a = story.project(mode, camera, vertices[edge[0]], rect, pass) orelse continue;
        const b = story.project(mode, camera, vertices[edge[1]], rect, pass) orelse continue;
        draw.line(a.pos, b.pos, 2.0, style.alpha(style.white, if (pass == .far) 62 else 160));
    }
}

fn drawWorldLine(
    mode: story.Mode,
    camera: story.Camera,
    rect: rl.Rectangle,
    a: story.Vec3,
    b: story.Vec3,
    pass: story.Pass,
    color: rl.Color,
    width: f32,
) void {
    var previous: ?rl.Vector2 = null;
    var i: usize = 0;
    while (i <= 32) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 32.0;
        const world = story.Vec3.lerp(a, b, t);
        const projected = story.project(mode, camera, world, rect, pass) orelse {
            previous = null;
            continue;
        };
        if (previous) |p| {
            const dx = projected.pos.x - p.x;
            const dy = projected.pos.y - p.y;
            if (dx * dx + dy * dy < 90000.0) {
                draw.line(p, projected.pos, width, color);
            }
        }
        previous = projected.pos;
    }
}

fn drawHud(app: *const App, screen: rl.Rectangle) void {
    const camera = app.scene.activeCamera();
    const accent = modeAccent(app.scene.mode);
    const pga_pos = camera.pgaPosition();
    const dist2 = camera.metricDistanceSquaredToCube();

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
    draw.text(
        "1-4/Tab view   WASD walk   arrows look   E/Q lift   R reset   P pause",
        hud.x + hud.width - 560.0,
        hud.y + 50.0,
        18,
        style.alpha(style.white, 175),
    );
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

const std = @import("std");
const zmath = @import("zmath");
const sg = zmath.geometry.spherical_game;

const rl = @cImport({
    @cInclude("raylib.h");
});

const width = 1280;
const height = 720;
const cube_edges = [_][2]usize{
    .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 },
    .{ 3, 1 }, .{ 3, 2 }, .{ 3, 7 },
    .{ 5, 1 }, .{ 5, 4 }, .{ 5, 7 },
    .{ 6, 2 }, .{ 6, 4 }, .{ 6, 7 },
};

pub fn main() void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(width, height, "zmath S3 GA demo");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    var pose = sg.Pose.north(6.0);
    const origin = sg.Pose.north(6.0);
    const cube = sg.TangentFrame{
        .center = sg.expMap(origin.position, origin.forward.scale(2.6).cast(sg.Direction), origin.radius),
        .x = origin.right,
        .y = origin.up,
        .z = origin.forward,
        .radius = origin.radius,
    };

    while (!rl.WindowShouldClose()) {
        const dt = rl.GetFrameTime();
        pose = updatePose(pose, dt);

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(color(12, 13, 20, 255));
        drawCube(pose, cube);
        drawHud(pose);
    }
}

fn updatePose(pose: sg.Pose, dt: f32) sg.Pose {
    var out = pose;
    const speed: f32 = 2.2;
    const look: f32 = 1.6;

    if (rl.IsKeyDown(rl.KEY_W)) out = out.moveForward(speed * dt);
    if (rl.IsKeyDown(rl.KEY_S)) out = out.moveForward(-speed * dt);
    if (rl.IsKeyDown(rl.KEY_D)) out = out.strafeRight(speed * dt);
    if (rl.IsKeyDown(rl.KEY_A)) out = out.strafeRight(-speed * dt);
    if (rl.IsKeyDown(rl.KEY_E)) out = out.moveUp(speed * dt);
    if (rl.IsKeyDown(rl.KEY_Q)) out = out.moveUp(-speed * dt);

    if (rl.IsKeyDown(rl.KEY_RIGHT)) out = out.yaw(-look * dt);
    if (rl.IsKeyDown(rl.KEY_LEFT)) out = out.yaw(look * dt);
    if (rl.IsKeyDown(rl.KEY_UP)) out = out.pitch(look * dt);
    if (rl.IsKeyDown(rl.KEY_DOWN)) out = out.pitch(-look * dt);

    return out;
}

fn drawCube(pose: sg.Pose, frame: sg.TangentFrame) void {
    const vertices = frame.cubeVertices(0.55);

    for (cube_edges) |edge| {
        const a = projectToScreen(pose, vertices[edge[0]]) orelse continue;
        const b = projectToScreen(pose, vertices[edge[1]]) orelse continue;
        const hemisphere = pose.hemisphere(vertices[edge[0]]);
        const tint = switch (hemisphere) {
            .front => color(102, 217, 239, 255),
            .border => color(255, 209, 102, 255),
            .back => color(255, 107, 107, 180),
        };
        rl.DrawLineEx(a, b, 3.0, tint);
    }

    for (vertices) |vertex| {
        const p = projectToScreen(pose, vertex) orelse continue;
        rl.DrawCircleV(p, 4.0, color(245, 245, 245, 230));
    }
}

fn projectToScreen(pose: sg.Pose, point: sg.Point) ?rl.Vector2 {
    const p = pose.project(point) orelse return null;
    const zoom = @min(@as(f32, @floatFromInt(rl.GetScreenWidth())), @as(f32, @floatFromInt(rl.GetScreenHeight()))) * 0.72;
    return .{
        .x = @as(f32, @floatFromInt(rl.GetScreenWidth())) * 0.5 + zoom * p.x / p.z,
        .y = @as(f32, @floatFromInt(rl.GetScreenHeight())) * 0.5 - zoom * p.y / p.z,
    };
}

fn drawHud(pose: sg.Pose) void {
    _ = pose;
    rl.DrawText("S3 GA demo: WASD move, QE vertical, arrows look", 20, 20, 20, color(245, 245, 245, 230));
    rl.DrawText("Object lives on the 3-sphere; projection is log-map into camera tangent space", 20, 46, 16, color(180, 190, 210, 220));
    rl.DrawText("yellow=hemisphere border, red=far hemisphere edges", 20, 68, 16, color(180, 190, 210, 220));
}

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

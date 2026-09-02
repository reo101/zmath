const std = @import("std");
const scene = @import("scene.zig");

const rl = @cImport({
    @cInclude("stdlib.h");
    @cInclude("raylib.h");
});

const window_width = 1280;
const window_height = 720;

pub fn main() void {
    const capture_path = rl.getenv("ZMATH_DEMO_CAPTURE");
    const capture = capture_path != null;
    var window_flags: c_uint = rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT;
    if (capture) window_flags |= rl.FLAG_WINDOW_HIDDEN;
    rl.SetConfigFlags(window_flags);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(window_width, window_height, "zmath demo: spherical game");
    defer rl.CloseWindow();

    if (!capture) rl.SetTargetFPS(60);

    var world = scene.Scene.init();
    if (capture) {
        const before_antipode = if (rl.getenv("ZMATH_DEMO_WALK")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch 1.0
        else
            1.0;
        const pitch = if (rl.getenv("ZMATH_DEMO_PITCH")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch -0.4
        else
            -0.4;
        world.walkForward(-(@as(f32, std.math.pi) * world.radius - scene.default_cube_distance - before_antipode));
        if (pitch != 0.0) world.pitch(pitch);
    }
    var mesh: [scene.max_cube_triangles]scene.WorldTriangle = undefined;
    const mesh_count = world.cubeMesh(&mesh);
    var projected: [scene.max_cube_triangles]scene.ProjectedTriangle = undefined;
    var auto_back = false;

    while (!rl.WindowShouldClose()) {
        const dt = @min(rl.GetFrameTime(), 0.05);
        update(&world, dt, &auto_back);

        const screen_width: f32 = @floatFromInt(rl.GetScreenWidth());
        const screen_height: f32 = @floatFromInt(rl.GetScreenHeight());
        const aspect = screen_width / @max(screen_height, 1.0);
        const projected_count = world.projectCube(mesh[0..mesh_count], &projected, aspect);
        std.mem.sort(
            scene.ProjectedTriangle,
            projected[0..projected_count],
            {},
            scene.ProjectedTriangle.drawBefore,
        );

        rl.BeginDrawing();
        rl.ClearBackground(color(6, 9, 15, 255));
        rl.DrawRectangleGradientV(
            0,
            0,
            rl.GetScreenWidth(),
            rl.GetScreenHeight(),
            color(20, 28, 44, 255),
            color(5, 7, 12, 255),
        );

        drawGround(world, aspect, screen_width, screen_height);
        drawCube(projected[0..projected_count], screen_width, screen_height, world.radius);
        drawHud(world, projected[0..projected_count], auto_back);
        rl.EndDrawing();

        if (capture) {
            rl.TakeScreenshot(capture_path.?);
            break;
        }
    }
}

fn update(world: *scene.Scene, dt: f32, auto_back: *bool) void {
    if (rl.IsKeyPressed(rl.KEY_R)) world.* = scene.Scene.init();
    if (rl.IsKeyPressed(rl.KEY_SPACE)) auto_back.* = !auto_back.*;

    const move_speed: f32 = 2.2;
    const look_speed: f32 = 1.35;
    if (auto_back.* or rl.IsKeyDown(rl.KEY_S)) world.walkForward(-move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_W)) world.walkForward(move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_D)) world.strafeRight(move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_A)) world.strafeRight(-move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_LEFT)) world.yaw(look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_RIGHT)) world.yaw(-look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_UP)) world.pitch(-look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_DOWN)) world.pitch(look_speed * dt);
}

fn drawGround(world: scene.Scene, aspect: f32, width: f32, height: f32) void {
    const camera = world.camera();
    const latitude_steps = 64;
    const longitude_steps = 96;

    for (0..17) |longitude_index| {
        const longitude = -@as(f32, std.math.pi) +
            @as(f32, @floatFromInt(longitude_index)) * (2.0 * @as(f32, std.math.pi) / 16.0);
        var previous = world.projectWithCamera(
            camera,
            scene.groundPoint(longitude, -@as(f32, std.math.pi) / 2.0),
            aspect,
        );
        for (1..latitude_steps + 1) |latitude_index| {
            const latitude = -@as(f32, std.math.pi) / 2.0 +
                @as(f32, @floatFromInt(latitude_index)) * (@as(f32, std.math.pi) / @as(f32, @floatFromInt(latitude_steps)));
            const current = world.projectWithCamera(camera, scene.groundPoint(longitude, latitude), aspect);
            drawGroundSegment(previous, current, width, height);
            previous = current;
        }
    }

    for (1..12) |latitude_index| {
        const latitude = -@as(f32, std.math.pi) / 2.0 +
            @as(f32, @floatFromInt(latitude_index)) * (@as(f32, std.math.pi) / 12.0);
        var previous = world.projectWithCamera(camera, scene.groundPoint(-@as(f32, std.math.pi), latitude), aspect);
        for (1..longitude_steps + 1) |longitude_index| {
            const longitude = -@as(f32, std.math.pi) +
                @as(f32, @floatFromInt(longitude_index)) * (2.0 * @as(f32, std.math.pi) / @as(f32, @floatFromInt(longitude_steps)));
            const current = world.projectWithCamera(camera, scene.groundPoint(longitude, latitude), aspect);
            drawGroundSegment(previous, current, width, height);
            previous = current;
        }
    }
}

fn drawGroundSegment(a: ?scene.ProjectedVertex, b: ?scene.ProjectedVertex, width: f32, height: f32) void {
    const pa = a orelse return;
    const pb = b orelse return;
    if (pa.branch != pb.branch) return;

    const screen_a = toScreen(pa.position, width, height);
    const screen_b = toScreen(pb.position, width, height);
    const dx = screen_b.x - screen_a.x;
    const dy = screen_b.y - screen_a.y;
    const max_length = @max(width, height) * 0.22;
    if (dx * dx + dy * dy > max_length * max_length) return;

    const tint = if (pa.branch == .near)
        color(112, 140, 166, 92)
    else
        color(84, 99, 130, 54);
    rl.DrawLineEx(screen_a, screen_b, if (pa.branch == .near) 1.2 else 0.8, tint);
}

fn drawCube(triangles: []const scene.ProjectedTriangle, width: f32, height: f32, radius: f32) void {
    for (triangles) |triangle| {
        const a = toScreen(triangle.vertices[0].position, width, height);
        const b = toScreen(triangle.vertices[1].position, width, height);
        const c = toScreen(triangle.vertices[2].position, width, height);
        const tint = shade(faceColor(triangle.face), triangle.distance / (@as(f32, std.math.pi) * radius));
        rl.DrawTriangle(a, b, c, tint);
        rl.DrawTriangle(c, b, a, tint);
    }

    for (triangles) |triangle| {
        const a = toScreen(triangle.vertices[0].position, width, height);
        const b = toScreen(triangle.vertices[1].position, width, height);
        const c = toScreen(triangle.vertices[2].position, width, height);
        const alpha: u8 = if (triangle.vertices[0].branch == .near) 42 else 28;
        rl.DrawTriangleLines(a, b, c, color(246, 247, 241, alpha));
    }
}

fn drawHud(world: scene.Scene, triangles: []const scene.ProjectedTriangle, auto_back: bool) void {
    const stats = scene.Scene.projectionStats(triangles);
    var visible_faces: usize = 0;
    inline for (.{ scene.Face.left, scene.Face.right, scene.Face.top, scene.Face.front, scene.Face.back }) |face| {
        if (stats.faceTriangles(face) > 0) visible_faces += 1;
    }

    rl.DrawRectangle(16, 16, 760, 92, color(4, 7, 12, 205));
    rl.DrawRectangleLines(16, 16, 760, 92, color(130, 155, 180, 110));
    rl.DrawText("S3 spherical-game demo", 30, 27, 24, color(246, 247, 241, 255));
    rl.DrawText("W/S move, A/D strafe, arrows look, R reset, Space auto-back", 30, 57, 18, color(190, 204, 220, 235));

    var buffer: [192]u8 = undefined;
    const status = std.fmt.bufPrintZ(
        &buffer,
        "cube distance {d:.2} / {d:.2}   projected faces {d}/5   near/far triangles {d}/{d}   auto {s}",
        .{
            world.distanceToCube(),
            @as(f32, std.math.pi) * world.radius,
            visible_faces,
            stats.branches[@intFromEnum(scene.Branch.near)],
            stats.branches[@intFromEnum(scene.Branch.far)],
            if (auto_back) "on" else "off",
        },
    ) catch return;
    rl.DrawText(status, 30, 82, 16, color(150, 174, 201, 230));
    rl.DrawFPS(rl.GetScreenWidth() - 92, 22);
}

fn toScreen(point: [2]f32, width: f32, height: f32) rl.Vector2 {
    return .{
        .x = (point[0] + 1.0) * width * 0.5,
        .y = (1.0 - point[1]) * height * 0.5,
    };
}

fn faceColor(face: scene.Face) rl.Color {
    return switch (face) {
        .left => color(82, 190, 224, 238),
        .right => color(245, 96, 83, 238),
        .top => color(255, 184, 77, 242),
        .front => color(92, 173, 126, 240),
        .back => color(143, 124, 230, 236),
        .bottom => color(30, 34, 44, 255),
    };
}

fn shade(base: rl.Color, normalized_distance: f32) rl.Color {
    const amount = 1.0 - std.math.clamp(normalized_distance, 0.0, 1.0) * 0.28;
    return color(
        @intFromFloat(@round(@as(f32, @floatFromInt(base.r)) * amount)),
        @intFromFloat(@round(@as(f32, @floatFromInt(base.g)) * amount)),
        @intFromFloat(@round(@as(f32, @floatFromInt(base.b)) * amount)),
        base.a,
    );
}

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

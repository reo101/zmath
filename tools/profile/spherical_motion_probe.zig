const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.constant_curvature;

const screen_width: usize = 160;
const screen_height: usize = 90;
const spherical_walk_eye_height_scale: f32 = 0.035;
const spherical_local_cube_radius_fraction: f32 = 0.27027026;

const ProbePoint = struct {
    name: []const u8,
    local: curved.Vec3,
};

const MotionSample = struct {
    pass: ?curved.SphericalRenderPass,
    status: curved.SampleStatus,
    distance: f32,
    projected: ?[2]f32,
};

fn vec3FromVector(v: demo.H.Vector) curved.Vec3 {
    return .{
        v.coeffNamed("e1"),
        v.coeffNamed("e2"),
        v.coeffNamed("e3"),
    };
}

fn dot4(a: curved.Vec4, b: curved.Vec4) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn liftedWalkView(view: curved.View, pitch_angle: f32) curved.View {
    const surface_up = view.walkSurfaceUp(pitch_angle) orelse return view;
    var lifted = view;
    curved.moveAlongDirection(
        &lifted.camera,
        view.metric,
        view.params,
        surface_up,
        view.params.radius * spherical_walk_eye_height_scale,
    );
    return lifted;
}

fn localCubeScale(radius: f32) f32 {
    return radius * spherical_local_cube_radius_fraction;
}

fn worldGroundAmbient(view: curved.View, lateral: f32, forward_distance: f32) curved.Vec4 {
    return curved.ambientFromTangentBasisPoint(
        view.metric,
        view.params,
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
        lateral,
        forward_distance,
    ) orelse unreachable;
}

fn passLabel(pass: ?curved.SphericalRenderPass) []const u8 {
    return if (pass) |resolved| @tagName(resolved) else "none";
}

fn fmtProjected(projected: ?[2]f32) [32]u8 {
    var buf: [32]u8 = undefined;
    if (projected) |p| {
        _ = std.fmt.bufPrint(&buf, "({d:.2},{d:.2})", .{ p[0], p[1] }) catch unreachable;
    } else {
        _ = std.fmt.bufPrint(&buf, "(-,-)", .{}) catch unreachable;
    }
    return buf;
}

fn sampleAmbient(view: curved.View, ambient: curved.Vec4) MotionSample {
    const screen = curved.Screen{
        .width = screen_width,
        .height = screen_height,
        .zoom = 1.0,
    };
    const sample = view.sampleProjectedAmbient(ambient, screen);
    return .{
        .pass = view.sphericalSelectedPassForAmbient(ambient),
        .status = sample.status,
        .distance = sample.distance,
        .projected = sample.projected,
    };
}

fn sampleMainRender(view: curved.View, ambient: curved.Vec4) MotionSample {
    const screen = curved.Screen{
        .width = screen_width,
        .height = screen_height,
        .zoom = 1.0,
    };
    const sample = view.sampleProjectedAmbient(ambient, screen);
    return .{
        .pass = view.sphericalSelectedPassForAmbient(ambient),
        .status = sample.status,
        .distance = sample.distance,
        .projected = sample.projected,
    };
}

fn projectConformalFlat(view: curved.View, ambient: curved.Vec4) ?[2]f32 {
    const selected = view.sphericalSelectedPassForAmbient(ambient) orelse return null;
    const far_camera = curved.Camera{
        .position = .{ -view.camera.position[0], -view.camera.position[1], -view.camera.position[2], -view.camera.position[3] },
        .right = view.camera.right,
        .up = view.camera.up,
        .forward = .{ -view.camera.forward[0], -view.camera.forward[1], -view.camera.forward[2], -view.camera.forward[3] },
    };
    const camera = switch (selected) {
        .near => view.camera,
        .far => far_camera,
    };
    const model = curved.modelPointForAmbientWithCamera(.spherical, camera, ambient, .conformal) orelse return null;
    const aspect = @as(f32, @floatFromInt(screen_width)) / @as(f32, @floatFromInt(screen_height * 2));
    return .{
        (model[0] / aspect + 1.0) * (@as(f32, @floatFromInt(screen_width)) * 0.5),
        (1.0 - model[1]) * (@as(f32, @floatFromInt(screen_height)) * 0.5),
    };
}

fn projectConformalFlatGroundHeight(view: curved.View, local: curved.Vec3) ?[2]f32 {
    const ambient = curved.sphericalAmbientFromGroundHeightPoint(view.params, local);
    return projectConformalFlat(view, ambient);
}

const FaceStats = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    visible: usize,
};

fn faceStats(view: curved.View, points: []const curved.Vec3) ?FaceStats {
    var result: ?FaceStats = null;
    for (points) |local| {
        const ambient = demo.sphericalDemoAmbientPoint(view.params, local);
        const sample = sampleMainRender(view, ambient);
        const projected = sample.projected orelse continue;
        if (sample.status != .visible) continue;

        if (result) |*stats| {
            stats.min_x = @min(stats.min_x, projected[0]);
            stats.max_x = @max(stats.max_x, projected[0]);
            stats.min_y = @min(stats.min_y, projected[1]);
            stats.max_y = @max(stats.max_y, projected[1]);
            stats.visible += 1;
        } else {
            result = .{
                .min_x = projected[0],
                .max_x = projected[0],
                .min_y = projected[1],
                .max_y = projected[1],
                .visible = 1,
            };
        }
    }
    return result;
}

fn faceStatsConformalFlat(view: curved.View, points: []const curved.Vec3) ?FaceStats {
    var result: ?FaceStats = null;
    for (points) |local| {
        const ambient = demo.sphericalDemoAmbientPoint(view.params, local);
        const projected = projectConformalFlat(view, ambient) orelse continue;

        if (result) |*stats| {
            stats.min_x = @min(stats.min_x, projected[0]);
            stats.max_x = @max(stats.max_x, projected[0]);
            stats.min_y = @min(stats.min_y, projected[1]);
            stats.max_y = @max(stats.max_y, projected[1]);
            stats.visible += 1;
        } else {
            result = .{
                .min_x = projected[0],
                .max_x = projected[0],
                .min_y = projected[1],
                .max_y = projected[1],
                .visible = 1,
            };
        }
    }
    return result;
}

fn faceStatsConformalFlatGroundHeight(view: curved.View, points: []const curved.Vec3) ?FaceStats {
    var result: ?FaceStats = null;
    for (points) |local| {
        const projected = projectConformalFlatGroundHeight(view, local) orelse continue;

        if (result) |*stats| {
            stats.min_x = @min(stats.min_x, projected[0]);
            stats.max_x = @max(stats.max_x, projected[0]);
            stats.min_y = @min(stats.min_y, projected[1]);
            stats.max_y = @max(stats.max_y, projected[1]);
            stats.visible += 1;
        } else {
            result = .{
                .min_x = projected[0],
                .max_x = projected[0],
                .min_y = projected[1],
                .max_y = projected[1],
                .visible = 1,
            };
        }
    }
    return result;
}

fn printFaceStats(writer: anytype, label: []const u8, view: curved.View, scale: f32) !void {
    const top = [_]curved.Vec3{
        .{ scale, scale * 2.0, scale },
        .{ scale, scale * 2.0, -scale },
        .{ -scale, scale * 2.0, scale },
        .{ -scale, scale * 2.0, -scale },
    };
    const front = [_]curved.Vec3{
        .{ scale, scale, scale },
        .{ scale, scale * 2.0, scale },
        .{ -scale, scale, scale },
        .{ -scale, scale * 2.0, scale },
    };
    const right = [_]curved.Vec3{
        .{ -scale, scale, scale },
        .{ -scale, scale * 2.0, scale },
        .{ -scale, scale, -scale },
        .{ -scale, scale * 2.0, -scale },
    };

    try writer.print("\n== {s} ==\n", .{label});
    inline for (.{
        .{ "top", top[0..] },
        .{ "front", front[0..] },
        .{ "right", right[0..] },
    }) |entry| {
        if (faceStats(view, entry.@"1")) |stats| {
            try writer.print(
                "{s}: visible={d} x=[{d:.2},{d:.2}] y=[{d:.2},{d:.2}] w={d:.2} h={d:.2}\n",
                .{
                    entry.@"0",
                    stats.visible,
                    stats.min_x,
                    stats.max_x,
                    stats.min_y,
                    stats.max_y,
                    stats.max_x - stats.min_x,
                    stats.max_y - stats.min_y,
                },
            );
        } else {
            try writer.print("{s}: hidden\n", .{entry.@"0"});
        }
    }
}

fn printAltFaceStats(writer: anytype, label: []const u8, view: curved.View, scale: f32) !void {
    const top = [_]curved.Vec3{
        .{ scale, scale * 2.0, scale },
        .{ scale, scale * 2.0, -scale },
        .{ -scale, scale * 2.0, scale },
        .{ -scale, scale * 2.0, -scale },
    };
    const front = [_]curved.Vec3{
        .{ scale, scale, scale },
        .{ scale, scale * 2.0, scale },
        .{ -scale, scale, scale },
        .{ -scale, scale * 2.0, scale },
    };
    const right = [_]curved.Vec3{
        .{ -scale, scale, scale },
        .{ -scale, scale * 2.0, scale },
        .{ -scale, scale, -scale },
        .{ -scale, scale * 2.0, -scale },
    };

    try writer.print("\n== {s} ==\n", .{label});
    inline for (.{
        .{ "top", top[0..] },
        .{ "front", front[0..] },
        .{ "right", right[0..] },
    }) |entry| {
        if (faceStatsConformalFlat(view, entry.@"1")) |stats| {
            try writer.print(
                "{s}: visible={d} x=[{d:.2},{d:.2}] y=[{d:.2},{d:.2}] w={d:.2} h={d:.2}\n",
                .{
                    entry.@"0",
                    stats.visible,
                    stats.min_x,
                    stats.max_x,
                    stats.min_y,
                    stats.max_y,
                    stats.max_x - stats.min_x,
                    stats.max_y - stats.min_y,
                },
            );
        } else {
            try writer.print("{s}: hidden\n", .{entry.@"0"});
        }
    }
}

fn printGroundHeightFaceStats(writer: anytype, label: []const u8, view: curved.View, scale: f32) !void {
    const top = [_]curved.Vec3{
        .{ scale, scale * 2.0, scale },
        .{ scale, scale * 2.0, -scale },
        .{ -scale, scale * 2.0, scale },
        .{ -scale, scale * 2.0, -scale },
    };
    const front = [_]curved.Vec3{
        .{ scale, scale, scale },
        .{ scale, scale * 2.0, scale },
        .{ -scale, scale, scale },
        .{ -scale, scale * 2.0, scale },
    };
    const right = [_]curved.Vec3{
        .{ -scale, scale, scale },
        .{ -scale, scale * 2.0, scale },
        .{ -scale, scale, -scale },
        .{ -scale, scale * 2.0, -scale },
    };

    try writer.print("\n== {s} ==\n", .{label});
    inline for (.{
        .{ "top", top[0..] },
        .{ "front", front[0..] },
        .{ "right", right[0..] },
    }) |entry| {
        if (faceStatsConformalFlatGroundHeight(view, entry.@"1")) |stats| {
            try writer.print(
                "{s}: visible={d} x=[{d:.2},{d:.2}] y=[{d:.2},{d:.2}] w={d:.2} h={d:.2}\n",
                .{
                    entry.@"0",
                    stats.visible,
                    stats.min_x,
                    stats.max_x,
                    stats.min_y,
                    stats.max_y,
                    stats.max_x - stats.min_x,
                    stats.max_y - stats.min_y,
                },
            );
        } else {
            try writer.print("{s}: hidden\n", .{entry.@"0"});
        }
    }
}

fn printDelta(writer: anytype, before: MotionSample, after: MotionSample) !void {
    if (before.projected) |bp| {
        if (after.projected) |ap| {
            const dx = ap[0] - bp[0];
            const dy = ap[1] - bp[1];
            try writer.print(
                " dx={s}{d:.2} dy={s}{d:.2}",
                .{
                    if (dx >= 0.0) "+" else "-",
                    @abs(dx),
                    if (dy >= 0.0) "+" else "-",
                    @abs(dy),
                },
            );
            return;
        }
    }
    try writer.writeAll(" dx=n/a dy=n/a");
}

fn printPointMotion(
    writer: anytype,
    label: []const u8,
    before: MotionSample,
    after: MotionSample,
) !void {
    try writer.print(
        "{s}: {s}/{s} {d:.2} -> {s}/{s} {d:.2}",
        .{
            label,
            passLabel(before.pass),
            @tagName(before.status),
            if (before.projected) |p| p[0] else -1.0,
            passLabel(after.pass),
            @tagName(after.status),
            if (after.projected) |p| p[0] else -1.0,
        },
    );
    try writer.print(
        " y={d:.2}->{d:.2}",
        .{
            if (before.projected) |p| p[1] else -1.0,
            if (after.projected) |p| p[1] else -1.0,
        },
    );
    try printDelta(writer, before, after);
    try writer.writeAll("\n");
}

fn configureReferenceState(app: *demo.App) void {
    app.animate = false;
    app.mode = .spherical;
    app.angle = 1.849999;
    app.camera.movement_mode = .walk;
    app.camera.euclid_rotation = -0.484000;
    app.camera.euclid_pitch = -1.100000;
    app.camera.euclid_eye_x = -1.610958;
    app.camera.euclid_eye_y = 0.0;
    app.camera.euclid_eye_z = 8.896189;
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
            .position = .{ 0.570661, -0.095725, 0.000000, 0.815585 },
            .right = .{ -0.296451, 0.902192, -0.000000, 0.313315 },
            .up = .{ -0.682494, -0.374823, 0.453595, 0.433545 },
            .forward = .{ -0.347367, -0.190773, -0.891208, 0.220660 },
        },
        .scene_sign = 1.0,
    };
}

fn renderView(app: demo.App) curved.View {
    return if (app.camera.movement_mode == .walk)
        liftedWalkView(app.camera.spherical, app.camera.euclid_pitch)
    else
        app.camera.spherical;
}

fn printProbeSet(
    writer: anytype,
    title: []const u8,
    before_view: curved.View,
    after_view: curved.View,
    cube_points: []const ProbePoint,
    ground_points: []const ProbePoint,
) !void {
    try writer.print("\n== {s} ==\n", .{title});
    try writer.print(
        "camera pos_dot={d:.6} fwd_dot={d:.6}\n",
        .{
            dot4(before_view.camera.position, after_view.camera.position),
            dot4(before_view.camera.forward, after_view.camera.forward),
        },
    );
    for (cube_points) |point| {
        const before_ambient = demo.sphericalDemoAmbientPoint(before_view.params, point.local);
        const after_ambient = demo.sphericalDemoAmbientPoint(after_view.params, point.local);
        try printPointMotion(
            writer,
            point.name,
            sampleAmbient(before_view, before_ambient),
            sampleAmbient(after_view, after_ambient),
        );
    }
    for (ground_points) |point| {
        const before_ambient = worldGroundAmbient(before_view, point.local[0], point.local[2]);
        const after_ambient = worldGroundAmbient(after_view, point.local[0], point.local[2]);
        try printPointMotion(
            writer,
            point.name,
            sampleAmbient(before_view, before_ambient),
            sampleAmbient(after_view, after_ambient),
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var app = try demo.App.init();
    configureReferenceState(&app);

    const scale = localCubeScale(app.camera.spherical.params.radius);
    const cube_points = [_]ProbePoint{
        .{ .name = "cube_center", .local = .{ 0.0, scale, 0.0 } },
        .{ .name = "cube_top", .local = .{ 0.0, scale * 2.0, 0.0 } },
        .{ .name = "cube_front", .local = .{ 0.0, scale, scale } },
        .{ .name = "cube_back", .local = .{ 0.0, scale, -scale } },
        .{ .name = "cube_left", .local = .{ scale, scale, 0.0 } },
        .{ .name = "cube_right", .local = .{ -scale, scale, 0.0 } },
    };
    const ground_points = [_]ProbePoint{
        .{ .name = "ground_origin", .local = .{ 0.0, 0.0, 0.0 } },
        .{ .name = "ground_forward", .local = .{ 0.0, 0.0, scale * 6.0 } },
        .{ .name = "ground_backward", .local = .{ 0.0, 0.0, -scale * 6.0 } },
        .{ .name = "ground_right", .local = .{ scale * 6.0, 0.0, 0.0 } },
    };

    try stdout.writeAll("# spherical motion probe\n");
    try stdout.print(
        "start eye_chart=({d:.6},{d:.6},{d:.6}) pitch={d:.6} rot={d:.6}\n",
        .{
            curved.chartCoords(app.camera.spherical.metric, app.camera.spherical.params, app.camera.spherical.camera.position)[0],
            curved.chartCoords(app.camera.spherical.metric, app.camera.spherical.params, app.camera.spherical.camera.position)[1],
            curved.chartCoords(app.camera.spherical.metric, app.camera.spherical.params, app.camera.spherical.camera.position)[2],
            app.camera.euclid_pitch,
            app.camera.euclid_rotation,
        },
    );

    const before_view = renderView(app);
    try printFaceStats(stdout, "surface camera", app.camera.spherical, scale);
    try printFaceStats(stdout, "lifted walk camera", before_view, scale);
    try printAltFaceStats(stdout, "lifted walk camera conformal-flat", before_view, scale);
    try printGroundHeightFaceStats(stdout, "lifted walk camera ground-height", before_view, scale);

    var look_right = app;
    _ = look_right.applyCommand(.look_right);
    try printProbeSet(stdout, "look_right", before_view, renderView(look_right), &cube_points, &ground_points);

    var look_up = app;
    _ = look_up.applyCommand(.look_up);
    try printProbeSet(stdout, "look_up", before_view, renderView(look_up), &cube_points, &ground_points);

    var move_forward = app;
    _ = move_forward.applyCommand(.move_forward);
    try printProbeSet(stdout, "move_forward", before_view, renderView(move_forward), &cube_points, &ground_points);

    var move_backward = app;
    _ = move_backward.applyCommand(.move_backward);
    try printProbeSet(stdout, "move_backward", before_view, renderView(move_backward), &cube_points, &ground_points);

    try stdout.flush();
}

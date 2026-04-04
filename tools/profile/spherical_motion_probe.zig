const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.constant_curvature;
const Round = curved.AmbientFor(.spherical);
const SphericalView = curved.SphericalView;

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
    return curved.vec3(v.coeffNamed("e1"), v.coeffNamed("e2"), v.coeffNamed("e3"));
}

fn dot4(a: Round.Vector, b: Round.Vector) f32 {
    return Round.dot(a, b);
}

fn liftedWalkView(view: SphericalView, _: f32) SphericalView {
    const surface_up = view.walkSurfaceUp() orelse return view;
    var lifted = view;
    lifted.moveAlong(surface_up, view.params.radius * spherical_walk_eye_height_scale);
    return lifted;
}

fn localCubeScale(radius: f32) f32 {
    return radius * spherical_local_cube_radius_fraction;
}

fn worldGroundAmbient(view: SphericalView, lateral: f32, forward_distance: f32) Round.Vector {
    return curved.ambientFromTypedTangentBasisPoint(
        .spherical,
        view.params,
        Round.fromCoords(.{ 1.0, 0.0, 0.0, 0.0 }),
        Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
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

fn sampleAmbient(view: SphericalView, ambient: Round.Vector) MotionSample {
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

fn sampleMainRender(view: SphericalView, ambient: Round.Vector) MotionSample {
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

fn projectConformalFlat(view: SphericalView, ambient: Round.Vector) ?[2]f32 {
    const selected = view.sphericalSelectedPassForAmbient(ambient) orelse return null;
    const far_camera = curved.TypedCamera(.spherical){
        .position = Round.scale(view.camera.position, -1.0),
        .right = view.camera.right,
        .up = view.camera.up,
        .forward = Round.scale(view.camera.forward, -1.0),
    };
    const camera = switch (selected) {
        .near => curved.TypedCamera(.spherical){
            .position = view.camera.position,
            .right = view.camera.right,
            .up = view.camera.up,
            .forward = view.camera.forward,
        },
        .far => far_camera,
    };
    const model = curved.modelPointForTypedAmbientWithCamera(.spherical, camera, ambient, .conformal) orelse return null;
    const aspect = @as(f32, @floatFromInt(screen_width)) / @as(f32, @floatFromInt(screen_height * 2));
    return .{
        (curved.vec3x(model) / aspect + 1.0) * (@as(f32, @floatFromInt(screen_width)) * 0.5),
        (1.0 - curved.vec3y(model)) * (@as(f32, @floatFromInt(screen_height)) * 0.5),
    };
}

fn projectConformalFlatGroundHeight(view: SphericalView, local: curved.Vec3) ?[2]f32 {
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

fn faceStats(view: SphericalView, points: []const curved.Vec3) ?FaceStats {
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

fn faceStatsConformalFlat(view: SphericalView, points: []const curved.Vec3) ?FaceStats {
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

fn faceStatsConformalFlatGroundHeight(view: SphericalView, points: []const curved.Vec3) ?FaceStats {
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

fn printFaceStats(writer: anytype, label: []const u8, view: SphericalView, scale: f32) !void {
    const top = [_]curved.Vec3{
        curved.vec3(scale, scale * 2.0, scale),
        curved.vec3(scale, scale * 2.0, -scale),
        curved.vec3(-scale, scale * 2.0, scale),
        curved.vec3(-scale, scale * 2.0, -scale),
    };
    const front = [_]curved.Vec3{
        curved.vec3(scale, scale, scale),
        curved.vec3(scale, scale * 2.0, scale),
        curved.vec3(-scale, scale, scale),
        curved.vec3(-scale, scale * 2.0, scale),
    };
    const right = [_]curved.Vec3{
        curved.vec3(-scale, scale, scale),
        curved.vec3(-scale, scale * 2.0, scale),
        curved.vec3(-scale, scale, -scale),
        curved.vec3(-scale, scale * 2.0, -scale),
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

fn printAltFaceStats(writer: anytype, label: []const u8, view: SphericalView, scale: f32) !void {
    const top = [_]curved.Vec3{
        curved.vec3(scale, scale * 2.0, scale),
        curved.vec3(scale, scale * 2.0, -scale),
        curved.vec3(-scale, scale * 2.0, scale),
        curved.vec3(-scale, scale * 2.0, -scale),
    };
    const front = [_]curved.Vec3{
        curved.vec3(scale, scale, scale),
        curved.vec3(scale, scale * 2.0, scale),
        curved.vec3(-scale, scale, scale),
        curved.vec3(-scale, scale * 2.0, scale),
    };
    const right = [_]curved.Vec3{
        curved.vec3(-scale, scale, scale),
        curved.vec3(-scale, scale * 2.0, scale),
        curved.vec3(-scale, scale, -scale),
        curved.vec3(-scale, scale * 2.0, -scale),
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

fn printGroundHeightFaceStats(writer: anytype, label: []const u8, view: SphericalView, scale: f32) !void {
    const top = [_]curved.Vec3{
        curved.vec3(scale, scale * 2.0, scale),
        curved.vec3(scale, scale * 2.0, -scale),
        curved.vec3(-scale, scale * 2.0, scale),
        curved.vec3(-scale, scale * 2.0, -scale),
    };
    const front = [_]curved.Vec3{
        curved.vec3(scale, scale, scale),
        curved.vec3(scale, scale * 2.0, scale),
        curved.vec3(-scale, scale, scale),
        curved.vec3(-scale, scale * 2.0, scale),
    };
    const right = [_]curved.Vec3{
        curved.vec3(-scale, scale, scale),
        curved.vec3(-scale, scale * 2.0, scale),
        curved.vec3(-scale, scale, -scale),
        curved.vec3(-scale, scale * 2.0, -scale),
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
        .params = .{
            .radius = 1.480000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .stereographic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = Round.fromCoords(.{ 0.570661, -0.095725, 0.000000, 0.815585 }),
            .right = Round.fromCoords(.{ -0.296451, 0.902192, -0.000000, 0.313315 }),
            .up = Round.fromCoords(.{ -0.682494, -0.374823, 0.453595, 0.433545 }),
            .forward = Round.fromCoords(.{ -0.347367, -0.190773, -0.891208, 0.220660 }),
        },
        .scene_sign = 1.0,
    };
}

fn renderView(app: demo.App) SphericalView {
    return if (app.camera.movement_mode == .walk)
        liftedWalkView(app.camera.spherical, app.camera.euclid_pitch)
    else
        app.camera.spherical;
}

fn printProbeSet(
    writer: anytype,
    title: []const u8,
    before_view: SphericalView,
    after_view: SphericalView,
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
        const before_ambient = worldGroundAmbient(before_view, curved.vec3x(point.local), curved.vec3z(point.local));
        const after_ambient = worldGroundAmbient(after_view, curved.vec3x(point.local), curved.vec3z(point.local));
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
        .{ .name = "cube_center", .local = curved.vec3(0.0, scale, 0.0) },
        .{ .name = "cube_top", .local = curved.vec3(0.0, scale * 2.0, 0.0) },
        .{ .name = "cube_front", .local = curved.vec3(0.0, scale, scale) },
        .{ .name = "cube_back", .local = curved.vec3(0.0, scale, -scale) },
        .{ .name = "cube_left", .local = curved.vec3(scale, scale, 0.0) },
        .{ .name = "cube_right", .local = curved.vec3(-scale, scale, 0.0) },
    };
    const ground_points = [_]ProbePoint{
        .{ .name = "ground_origin", .local = curved.vec3(0.0, 0.0, 0.0) },
        .{ .name = "ground_forward", .local = curved.vec3(0.0, 0.0, scale * 6.0) },
        .{ .name = "ground_backward", .local = curved.vec3(0.0, 0.0, -scale * 6.0) },
        .{ .name = "ground_right", .local = curved.vec3(scale * 6.0, 0.0, 0.0) },
    };

    try stdout.writeAll("# spherical motion probe\n");
    try stdout.print(
        "start eye_chart=({d:.6},{d:.6},{d:.6}) pitch={d:.6} rot={d:.6}\n",
        .{
            curved.vec3x(app.camera.spherical.chartCoords(app.camera.spherical.camera.position)),
            curved.vec3y(app.camera.spherical.chartCoords(app.camera.spherical.camera.position)),
            curved.vec3z(app.camera.spherical.chartCoords(app.camera.spherical.camera.position)),
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

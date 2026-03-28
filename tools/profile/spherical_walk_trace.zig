const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.constant_curvature;

const screen_width: usize = 160;
const screen_height: usize = 90;
const trace_steps: usize = 40;

const top_vertices = [_]usize{ 0, 1, 4, 5 };
const bottom_vertices = [_]usize{ 2, 3, 6, 7 };

const PassStats = struct {
    selected_near: usize = 0,
    selected_far: usize = 0,
    selected_hidden: usize = 0,
    near_raw_visible: usize = 0,
    far_raw_visible: usize = 0,
};

const VertexStats = struct {
    min_x: f32 = std.math.inf(f32),
    max_x: f32 = -std.math.inf(f32),
    min_y: f32 = std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),
    total_length: f32 = 0.0,
    max_jump: f32 = 0.0,
    visible_steps: usize = 0,
    hidden_steps: usize = 0,
    prev: ?[2]f32 = null,

    fn observe(self: *VertexStats, sample: curved.ProjectedSample) void {
        if (sample.status != .visible or sample.projected == null) {
            self.hidden_steps += 1;
            self.prev = null;
            return;
        }

        const point = sample.projected.?;
        self.visible_steps += 1;
        self.min_x = @min(self.min_x, point[0]);
        self.max_x = @max(self.max_x, point[0]);
        self.min_y = @min(self.min_y, point[1]);
        self.max_y = @max(self.max_y, point[1]);

        if (self.prev) |prev| {
            const dx = point[0] - prev[0];
            const dy = point[1] - prev[1];
            const jump = @sqrt(dx * dx + dy * dy);
            self.total_length += jump;
            self.max_jump = @max(self.max_jump, jump);
        }

        self.prev = point;
    }
};

fn vec3FromVector(v: demo.H.Vector) curved.Vec3 {
    return .{
        v.coeffNamed("e1"),
        v.coeffNamed("e2"),
        v.coeffNamed("e3"),
    };
}

fn configureRepro(app: *demo.App) void {
    app.animate = false;
    app.mode = .spherical;
    app.angle = 4.499999;
    app.camera.movement_mode = .walk;
    app.camera.euclid_rotation = 0.366000;
    app.camera.euclid_pitch = 0.100000;
    app.camera.euclid_eye_x = -7.520036;
    app.camera.euclid_eye_y = 0.0;
    app.camera.euclid_eye_z = -59.213104;
    app.camera.spherical = .{
        .metric = .spherical,
        .params = .{
            .radius = 1.480000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .gnomonic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = .{ -0.768220, -0.231342, 0.000000, 0.596922 },
            .right = .{ -0.222363, 0.944205, -0.229501, 0.079760 },
            .up = .{ 0.047435, 0.231729, 0.959841, 0.150856 },
            .forward = .{ -0.598448, -0.035495, 0.161355, -0.783942 },
        },
        .scene_sign = 1.0,
    };
}

fn averageProjectedY(samples: []const curved.ProjectedSample, indices: []const usize) ?f32 {
    var total: f32 = 0.0;
    var count: usize = 0;
    for (indices) |index| {
        const sample = samples[index];
        if (sample.status != .visible or sample.projected == null) continue;
        total += sample.projected.?[1];
        count += 1;
    }
    if (count == 0) return null;
    return total / @as(f32, @floatFromInt(count));
}

fn passLabel(pass: ?curved.SphericalRenderPass) []const u8 {
    return if (pass) |resolved| @tagName(resolved) else "none";
}

fn sampleProjectedX(sample: curved.ProjectedSample) f32 {
    return if (sample.projected) |p| p[0] else -1.0;
}

fn sampleProjectedY(sample: curved.ProjectedSample) f32 {
    return if (sample.projected) |p| p[1] else -1.0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var app = try demo.App.init();
    configureRepro(&app);

    var stats: [8]VertexStats = [_]VertexStats{VertexStats{}} ** 8;
    var pass_stats = PassStats{};
    var previous_scene_sign = app.camera.spherical.scene_sign;

    try stdout.writeAll(
        "# spherical walk trace\n" ++
            "# summary: step,scene_sign,wrapped,eye_chart_x,eye_chart_z,top_avg_y,bottom_avg_y\n" ++
            "# vertex: step,vertex,selected,combined_status,combined_distance,combined_x,combined_y," ++
            "near_status,near_distance,near_x,near_y,far_status,far_distance,far_x,far_y," ++
            "near_raw_status,near_raw_distance,near_raw_x,near_raw_y,far_raw_status,far_raw_distance,far_raw_x,far_raw_y\n",
    );

    for (0..trace_steps + 1) |step| {
        const scene = demo.curvedScene(app, screen_width, screen_height).?.spherical;
        const eye_chart = curved.chartCoords(.spherical, scene.view.params, scene.view.camera.position);
        const wrapped = scene.view.scene_sign != previous_scene_sign;

        var samples: [8]curved.ProjectedSample = undefined;
        for (scene.local_vertices, 0..) |local_vertex, i| {
            const ambient = demo.sphericalDemoAmbientPoint(scene.view.params, vec3FromVector(local_vertex));
            const selected_pass = scene.view.sphericalSelectedPassForAmbient(ambient);
            const near_sample = scene.view.sampleProjectedAmbientForSphericalPass(.near, ambient, scene.screen);
            const far_sample = scene.view.sampleProjectedAmbientForSphericalPass(.far, ambient, scene.screen);
            const near_raw_sample = scene.view.sampleProjectedAmbientForSphericalPassRaw(.near, ambient, scene.screen);
            const far_raw_sample = scene.view.sampleProjectedAmbientForSphericalPassRaw(.far, ambient, scene.screen);
            const combined_sample = scene.view.sampleProjectedAmbient(ambient, scene.screen);

            samples[i] = combined_sample;
            stats[i].observe(combined_sample);

            if (selected_pass) |pass| {
                switch (pass) {
                    .near => pass_stats.selected_near += 1,
                    .far => pass_stats.selected_far += 1,
                }
            } else {
                pass_stats.selected_hidden += 1;
            }
            if (near_raw_sample.status == .visible) pass_stats.near_raw_visible += 1;
            if (far_raw_sample.status == .visible) pass_stats.far_raw_visible += 1;

            try stdout.print(
                "vertex,{d},{d},{s},{s},{d:.6},{d:.6},{d:.6},{s},{d:.6},{d:.6},{d:.6}," ++
                    "{s},{d:.6},{d:.6},{d:.6},{s},{d:.6},{d:.6},{d:.6},{s},{d:.6},{d:.6},{d:.6}\n",
                .{
                    step,
                    i,
                    passLabel(selected_pass),
                    @tagName(combined_sample.status),
                    combined_sample.distance,
                    sampleProjectedX(combined_sample),
                    sampleProjectedY(combined_sample),
                    @tagName(near_sample.status),
                    near_sample.distance,
                    sampleProjectedX(near_sample),
                    sampleProjectedY(near_sample),
                    @tagName(far_sample.status),
                    far_sample.distance,
                    sampleProjectedX(far_sample),
                    sampleProjectedY(far_sample),
                    @tagName(near_raw_sample.status),
                    near_raw_sample.distance,
                    sampleProjectedX(near_raw_sample),
                    sampleProjectedY(near_raw_sample),
                    @tagName(far_raw_sample.status),
                    far_raw_sample.distance,
                    sampleProjectedX(far_raw_sample),
                    sampleProjectedY(far_raw_sample),
                },
            );
        }

        try stdout.print(
            "summary,{d},{d:.1},{s},{d:.6},{d:.6},{d:.6},{d:.6}\n",
            .{
                step,
                scene.view.scene_sign,
                if (wrapped) "wrap" else "-",
                eye_chart[0],
                eye_chart[2],
                averageProjectedY(&samples, &top_vertices) orelse -1.0,
                averageProjectedY(&samples, &bottom_vertices) orelse -1.0,
            },
        );

        previous_scene_sign = scene.view.scene_sign;
        if (step < trace_steps) _ = app.applyCommand(.move_backward);
    }

    try stdout.writeAll("# stats: vertex,min_x,max_x,min_y,max_y,total_path,max_jump,visible,hidden\n");
    for (stats, 0..) |stat, i| {
        try stdout.print(
            "stats,{d},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d},{d}\n",
            .{
                i,
                stat.min_x,
                stat.max_x,
                stat.min_y,
                stat.max_y,
                stat.total_length,
                stat.max_jump,
                stat.visible_steps,
                stat.hidden_steps,
            },
        );
    }
    try stdout.print(
        "# pass_stats:selected_near={d},selected_far={d},selected_none={d},near_raw_visible={d},far_raw_visible={d}\n",
        .{
            pass_stats.selected_near,
            pass_stats.selected_far,
            pass_stats.selected_hidden,
            pass_stats.near_raw_visible,
            pass_stats.far_raw_visible,
        },
    );

    try stdout.flush();
}

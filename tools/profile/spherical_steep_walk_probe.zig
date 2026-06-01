const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.curved;
const Round = curved.AmbientFor(.spherical);
const SphericalView = curved.SphericalView;
const screen_width: usize = 160;
const screen_height: usize = 90;

fn printState(writer: anytype, step: usize, app: demo.App) !void {
    const view = app.camera.spherical;
    const eye_chart = view.chartCoords(view.camera.position);
    const walk = view.walkOrientation();
    const pos = Round.toCoords(view.camera.position);
    const fwd = Round.toCoords(view.camera.forward);
    const up = Round.toCoords(view.camera.up);

    try writer.print(
        "step {d} eye_chart=({d:.6},{d:.6},{d:.6}) w={d:.6} denom={d:.6}\n",
        .{ step, curved.vec3x(eye_chart), curved.vec3y(eye_chart), curved.vec3z(eye_chart), pos.inner.w, 1.0 + pos.inner.w },
    );
    try writer.print(
        "  pos=({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            pos.inner.w,
            pos.inner.x,
            pos.inner.y,
            pos.inner.z,
        },
    );
    try writer.print(
        "  fwd=({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            fwd.inner.w,
            fwd.inner.x,
            fwd.inner.y,
            fwd.inner.z,
        },
    );
    try writer.print(
        "  up =({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            up.inner.w,
            up.inner.x,
            up.inner.y,
            up.inner.z,
        },
    );
    if (walk) |w| {
        try writer.print(
            "  walk=({d:.6},{d:.6},{d:.6})\n",
            .{ w.x_heading, w.z_heading, w.pitch },
        );
    } else {
        try writer.writeAll("  walk=null\n");
    }
}

fn printViewState(writer: anytype, step: usize, view: SphericalView) !void {
    const eye_chart = view.chartCoords(view.camera.position);
    const walk = view.walkOrientation();
    const pos = Round.toCoords(view.camera.position);
    const fwd = Round.toCoords(view.camera.forward);
    const up = Round.toCoords(view.camera.up);

    try writer.print(
        "step {d} eye_chart=({d:.6},{d:.6},{d:.6}) w={d:.6} denom={d:.6}\n",
        .{ step, curved.vec3x(eye_chart), curved.vec3y(eye_chart), curved.vec3z(eye_chart), pos.inner.w, 1.0 + pos.inner.w },
    );
    try writer.print(
        "  pos=({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            pos.inner.w,
            pos.inner.x,
            pos.inner.y,
            pos.inner.z,
        },
    );
    try writer.print(
        "  fwd=({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            fwd.inner.w,
            fwd.inner.x,
            fwd.inner.y,
            fwd.inner.z,
        },
    );
    try writer.print(
        "  up =({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            up.inner.w,
            up.inner.x,
            up.inner.y,
            up.inner.z,
        },
    );
    if (walk) |w| {
        try writer.print(
            "  walk=({d:.6},{d:.6},{d:.6})\n",
            .{ w.x_heading, w.z_heading, w.pitch },
        );
    } else {
        try writer.writeAll("  walk=null\n");
    }
}

fn vec3FromVector(v: demo.H.Vector) curved.Vec3 {
    return curved.vec3(v.coeffNamed("e1"), v.coeffNamed("e2"), v.coeffNamed("e3"));
}

fn liftedWalkView(view: SphericalView, _: f32) SphericalView {
    const surface_up = view.walkSurfaceUp() orelse return view;
    var lifted = view;
    lifted.moveAlong(surface_up, 0.34);
    return lifted;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var app = try demo.App.init();
    app.mode = .spherical;
    app.animate = false;
    app.camera.movement_mode = .walk;
    app.camera.euclid_rotation = 0.0;
    app.camera.euclid_pitch = 1.1;
    app.camera.spherical.syncHeadingPitch(0.0, 1.0, app.camera.euclid_pitch);

    try stdout.writeAll("# spherical steep backward walk probe\n");
    try printState(stdout, 0, app);

    var prev_view = app.camera.spherical;
    var prev_pos = app.camera.spherical.camera.position;
    var prev_fwd = app.camera.spherical.camera.forward;
    var prev_walk = app.camera.spherical.walkOrientation();
    var prev_projected: [8]?[2]f32 = [_]?[2]f32{null} ** 8;
    var first_projected_discontinuity: ?usize = null;

    const initial_scene = demo.curvedScene(app, screen_width, screen_height).?.spherical;
    const initial_render_view = liftedWalkView(initial_scene.view, app.camera.euclid_pitch);
    for (initial_scene.local_vertices, 0..) |local_vertex, i| {
        const ambient = demo.sphericalDemoAmbientPoint(initial_scene.view.params, vec3FromVector(local_vertex));
        const sample = initial_render_view.sampleProjectedAmbient(ambient, initial_scene.screen);
        prev_projected[i] = if (sample.status == .visible) sample.projected else null;
    }

    for (1..121) |step| {
        _ = app.applyCommand(.move_backward);

        const pos = app.camera.spherical.camera.position;
        const fwd = app.camera.spherical.camera.forward;
        const position_dot = Round.dot(prev_pos, pos);
        const forward_dot = Round.dot(prev_fwd, fwd);
        const scene = demo.curvedScene(app, screen_width, screen_height).?.spherical;
        const render_view = liftedWalkView(scene.view, app.camera.euclid_pitch);

        var max_projected_jump: f32 = 0.0;
        for (scene.local_vertices, 0..) |local_vertex, i| {
            const ambient = demo.sphericalDemoAmbientPoint(scene.view.params, vec3FromVector(local_vertex));
            const sample = render_view.sampleProjectedAmbient(ambient, scene.screen);
            const projected = if (sample.status == .visible) sample.projected else null;
            if (prev_projected[i]) |prev| {
                if (projected) |point| {
                    const dx = point[0] - prev[0];
                    const dy = point[1] - prev[1];
                    max_projected_jump = @max(max_projected_jump, @sqrt(dx * dx + dy * dy));
                }
            }
            prev_projected[i] = projected;
        }

        try stdout.print("delta {d} pos_dot={d:.6} fwd_dot={d:.6} proj_jump={d:.6}\n", .{ step, position_dot, forward_dot, max_projected_jump });
        const walk = app.camera.spherical.walkOrientation();
        if (walk) |w| {
            if (prev_walk) |pw| {
                try stdout.print(
                    "  walk_delta {d} dx={d:.6} dz={d:.6} dpitch={d:.6}\n",
                    .{
                        step,
                        w.x_heading - pw.x_heading,
                        w.z_heading - pw.z_heading,
                        w.pitch - pw.pitch,
                    },
                );
            }
        }

        if (forward_dot < 0.95) {
            try stdout.writeAll("! forward discontinuity\n");
            try printViewState(stdout, step - 1, prev_view);
            try printState(stdout, step, app);
            break;
        }

        if (max_projected_jump > 20.0 and first_projected_discontinuity == null) {
            first_projected_discontinuity = step;
            try stdout.writeAll("! projected discontinuity (continuing; not a camera jump)\n");
            try printState(stdout, step, app);
        }

        if (position_dot < 0.0 or forward_dot < 0.0) {
            try stdout.writeAll("! jump detected\n");
            try printState(stdout, step, app);
            break;
        }

        if (walk != null and prev_walk != null and ((walk.?.z_heading * prev_walk.?.z_heading) < 0.0 or (walk.?.pitch * prev_walk.?.pitch) < 0.0)) {
            try stdout.writeAll("! walk-heading singularity\n");
            try printState(stdout, step, app);
            break;
        }

        prev_pos = pos;
        prev_fwd = fwd;
        prev_walk = walk;
        prev_view = app.camera.spherical;
    }

    if (first_projected_discontinuity) |step| {
        try stdout.print("# first_projected_discontinuity={d}\n", .{step});
    } else {
        try stdout.writeAll("# first_projected_discontinuity=none\n");
    }

    try stdout.flush();
}

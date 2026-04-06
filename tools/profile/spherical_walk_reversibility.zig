const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.curved;
const Round = curved.AmbientFor(.spherical);
const SphericalView = curved.SphericalView;

fn dot4(a: Round.Vector, b: Round.Vector) f32 {
    return Round.dot(a, b);
}

fn printState(writer: anytype, label: []const u8, app: demo.App) !void {
    const view = app.camera.spherical;
    const eye_chart = view.chartCoords(view.camera.position);
    const pos = Round.toCoords(view.camera.position);
    const fwd = Round.toCoords(view.camera.forward);
    try writer.print(
        "{s}: eye_chart=({d:.6},{d:.6},{d:.6}) scene_sign={d:.1} pos=({d:.6},{d:.6},{d:.6},{d:.6}) fwd=({d:.6},{d:.6},{d:.6},{d:.6})\n",
        .{
            label,
            curved.vec3x(eye_chart),
            curved.vec3y(eye_chart),
            curved.vec3z(eye_chart),
            view.scene_sign,
            pos[0],
            pos[1],
            pos[2],
            pos[3],
            fwd[0],
            fwd[1],
            fwd[2],
            fwd[3],
        },
    );
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

    try stdout.writeAll("# spherical walk reversibility\n");
    try printState(stdout, "start", app);

    for (1..121) |step| {
        const before = app;

        var backward = before;
        _ = backward.applyCommand(.move_backward);

        var roundtrip = backward;
        _ = roundtrip.applyCommand(.move_forward);

        const step_pos_dot = dot4(before.camera.spherical.camera.position, backward.camera.spherical.camera.position);
        const step_fwd_dot = dot4(before.camera.spherical.camera.forward, backward.camera.spherical.camera.forward);
        const return_pos_dot = dot4(before.camera.spherical.camera.position, roundtrip.camera.spherical.camera.position);
        const return_fwd_dot = dot4(before.camera.spherical.camera.forward, roundtrip.camera.spherical.camera.forward);

        try stdout.print(
            "step {d} back.pos_dot={d:.6} back.fwd_dot={d:.6} return.pos_dot={d:.6} return.fwd_dot={d:.6} before.sign={d:.1} back.sign={d:.1} return.sign={d:.1}\n",
            .{
                step,
                step_pos_dot,
                step_fwd_dot,
                return_pos_dot,
                return_fwd_dot,
                before.camera.spherical.scene_sign,
                backward.camera.spherical.scene_sign,
                roundtrip.camera.spherical.scene_sign,
            },
        );

        if (return_pos_dot < 0.999 or return_fwd_dot < 0.999) {
            try stdout.writeAll("! irreversible step\n");
            try printState(stdout, "before", before);
            try printState(stdout, "back", backward);
            try printState(stdout, "roundtrip", roundtrip);
            break;
        }

        app = backward;
    }

    try stdout.flush();
}

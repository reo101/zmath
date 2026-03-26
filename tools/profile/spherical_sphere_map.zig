const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.constant_curvature;

const screen_width: usize = 160;
const screen_height: usize = 90;
const trace_steps: usize = 40;

// ASCII sphere-map: 2D circle showing where vertices sit on S³ relative to camera.
// Top-down view (xz plane) and side view (xz-forward vs y-up) of the unit sphere.
const map_radius: usize = 12;
const map_diameter: usize = map_radius * 2 + 1;

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
    app.angle = 17.450020;
    app.camera.movement_mode = .walk;
    app.camera.euclid_rotation = -2.115804;
    app.camera.euclid_pitch = -0.020000;
    app.camera.euclid_eye_x = -70.910950;
    app.camera.euclid_eye_y = 0.0;
    app.camera.euclid_eye_z = -176.578800;
    app.camera.spherical = .{
        .metric = .spherical,
        .params = .{
            .radius = 0.740000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .stereographic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = .{ 0.372664, -0.325853, 0.000000, -0.868872 },
            .right = .{ 0.719299, -0.490129, -0.000000, 0.492324 },
            .up = .{ -0.011725, -0.016168, 0.999800, 0.001035 },
            .forward = .{ -0.586168, -0.808289, -0.019999, 0.051722 },
        },
        .scene_sign = 1.0,
    };
}

// Compute the angular position of a point on the sphere relative to camera.
// Returns: azimuth (angle in camera's right-forward plane, radians),
//          elevation (angle above/below the equator, radians),
//          geodesic distance (radians on unit sphere).
const AngularPosition = struct {
    azimuth: f32, // angle from forward in right-forward plane
    elevation: f32, // angle above/below forward-right plane
    geodesic_angle: f32, // total arc on unit sphere (0 = same point, pi = antipodal)
    z_dir: f32, // camera-relative z (positive = in front)
    hemisphere: u8, // 'N' = near (z_dir >= 0), 'F' = far
};

fn angularPosition(view: curved.View, ambient: curved.Vec4) ?AngularPosition {
    // Dot product gives cos(geodesic_angle) on unit sphere
    const dot = ambient[0] * view.camera.position[0] +
        ambient[1] * view.camera.position[1] +
        ambient[2] * view.camera.position[2] +
        ambient[3] * view.camera.position[3];
    const geodesic_angle = std.math.acos(std.math.clamp(dot, -1.0, 1.0));

    // Project into camera-relative coordinates
    const x_dir = ambient[0] * view.camera.right[0] +
        ambient[1] * view.camera.right[1] +
        ambient[2] * view.camera.right[2] +
        ambient[3] * view.camera.right[3];
    const y_dir = ambient[0] * view.camera.up[0] +
        ambient[1] * view.camera.up[1] +
        ambient[2] * view.camera.up[2] +
        ambient[3] * view.camera.up[3];
    const z_dir = ambient[0] * view.camera.forward[0] +
        ambient[1] * view.camera.forward[1] +
        ambient[2] * view.camera.forward[2] +
        ambient[3] * view.camera.forward[3];

    const azimuth = std.math.atan2(x_dir, z_dir);
    const lateral = @sqrt(x_dir * x_dir + z_dir * z_dir);
    const elevation = std.math.atan2(y_dir, @max(lateral, 1e-6));

    return .{
        .azimuth = azimuth,
        .elevation = elevation,
        .geodesic_angle = geodesic_angle,
        .z_dir = z_dir,
        .hemisphere = if (z_dir >= 0.0) 'N' else 'F',
    };
}

// Plot a point on the ASCII circle map.
// The circle represents the full sphere: center = camera position,
// edge of circle = antipodal point (geodesic_angle = pi).
// Top-down map: azimuth controls angle, geodesic_angle controls radial distance.
fn plotOnMap(
    map: *[map_diameter][map_diameter]u8,
    geodesic_angle: f32,
    angle_on_map: f32,
    char: u8,
) void {
    const r_frac = geodesic_angle / std.math.pi; // 0..1 from center to edge
    const r_px = r_frac * @as(f32, @floatFromInt(map_radius));
    const cx = @as(f32, @floatFromInt(map_radius)) + r_px * @cos(angle_on_map);
    const cy = @as(f32, @floatFromInt(map_radius)) - r_px * @sin(angle_on_map);

    const ix: usize = @intFromFloat(@round(std.math.clamp(cx, 0.0, @as(f32, @floatFromInt(map_diameter - 1)))));
    const iy: usize = @intFromFloat(@round(std.math.clamp(cy, 0.0, @as(f32, @floatFromInt(map_diameter - 1)))));
    map[iy][ix] = char;
}

fn clearMap(map: *[map_diameter][map_diameter]u8) void {
    for (map) |*row| {
        @memset(row, ' ');
    }
    // Draw circle outline
    const steps: usize = 120;
    for (0..steps) |i| {
        const theta = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)) * 2.0 * std.math.pi;
        const px = @as(f32, @floatFromInt(map_radius)) + @as(f32, @floatFromInt(map_radius)) * @cos(theta);
        const py = @as(f32, @floatFromInt(map_radius)) - @as(f32, @floatFromInt(map_radius)) * @sin(theta);
        const ix: usize = @intFromFloat(@round(std.math.clamp(px, 0.0, @as(f32, @floatFromInt(map_diameter - 1)))));
        const iy: usize = @intFromFloat(@round(std.math.clamp(py, 0.0, @as(f32, @floatFromInt(map_diameter - 1)))));
        if (map[iy][ix] == ' ') map[iy][ix] = '.';
    }
    // Draw crosshairs
    map[map_radius][map_radius] = '+'; // camera at center
    // Hemisphere boundary (half-circle at r/2)
    for (0..steps) |i| {
        const theta = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)) * 2.0 * std.math.pi;
        const half_r = @as(f32, @floatFromInt(map_radius)) * 0.5;
        const px = @as(f32, @floatFromInt(map_radius)) + half_r * @cos(theta);
        const py = @as(f32, @floatFromInt(map_radius)) - half_r * @sin(theta);
        const ix: usize = @intFromFloat(@round(std.math.clamp(px, 0.0, @as(f32, @floatFromInt(map_diameter - 1)))));
        const iy: usize = @intFromFloat(@round(std.math.clamp(py, 0.0, @as(f32, @floatFromInt(map_diameter - 1)))));
        if (map[iy][ix] == ' ') map[iy][ix] = ':';
    }
}

fn writeMap(stdout: anytype, map: *const [map_diameter][map_diameter]u8) !void {
    for (map) |*row| {
        try stdout.writeAll(row);
        try stdout.writeAll("\n");
    }
}

fn passLabel(pass: ?curved.SphericalRenderPass) []const u8 {
    return if (pass) |resolved| @tagName(resolved) else "none";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var app = try demo.App.init();
    configureRepro(&app);

    const vertex_chars = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7' };

    for (0..trace_steps + 1) |step| {
        const scene = demo.curvedScene(app, screen_width, screen_height).?.spherical;
        const view = scene.view;
        const eye_chart = curved.chartCoords(.spherical, view.params, view.camera.position);

        try stdout.print(
            "\n===== STEP {d:>3} | eye_chart=({d:.4},{d:.4},{d:.4}) =====\n",
            .{ step, eye_chart[0], eye_chart[1], eye_chart[2] },
        );

        // Top-down sphere map (azimuth from forward, looking down from above)
        var top_map: [map_diameter][map_diameter]u8 = undefined;
        clearMap(&top_map);

        // Side sphere map (azimuth from forward vs elevation)
        var side_map: [map_diameter][map_diameter]u8 = undefined;
        clearMap(&side_map);

        // Mark forward direction with 'F' on top map (at center-top, small radius)
        plotOnMap(&top_map, 0.15, std.math.pi / 2.0, 'F');

        try stdout.print(
            "  vtx hemi  geod_deg  azim_deg  elev_deg   z_dir   pass   proj_x   proj_y  status\n",
            .{},
        );

        for (scene.local_vertices, 0..) |local_vertex, i| {
            const ambient = curved.sphericalAmbientFromGroundHeightPoint(view.params, vec3FromVector(local_vertex));

            const signed_ambient = ambient;

            const ang = angularPosition(view, signed_ambient) orelse continue;
            const selected_pass = view.sphericalSelectedPassForAmbient(ambient);
            const screen: curved.Screen = scene.screen;
            const combined = view.sampleProjectedAmbient(ambient, screen);

            // Plot on top-down map (azimuth as angle from up/forward direction)
            plotOnMap(&top_map, ang.geodesic_angle, ang.azimuth + std.math.pi / 2.0, vertex_chars[i]);

            // Plot on side map: x-axis = azimuth mapped to angle, y-axis = elevation
            // Use geodesic_angle and elevation for side view
            const side_angle = ang.elevation + std.math.pi / 2.0;
            plotOnMap(&side_map, ang.geodesic_angle, side_angle, vertex_chars[i]);

            const deg = 180.0 / std.math.pi;
            try stdout.print(
                "   {d}   {c}    {d:>7.1}   {d:>7.1}   {d:>7.1}  {d:>6.3}   {s:<4}  {d:>7.1}  {d:>7.1}  {s}\n",
                .{
                    i,
                    ang.hemisphere,
                    ang.geodesic_angle * deg,
                    ang.azimuth * deg,
                    ang.elevation * deg,
                    ang.z_dir,
                    passLabel(selected_pass),
                    if (combined.projected) |p| p[0] else -1.0,
                    if (combined.projected) |p| p[1] else -1.0,
                    @tagName(combined.status),
                },
            );
        }

        try stdout.writeAll("\n  TOP-DOWN (center=camera, edge=antipode, ':'=hemisphere boundary):\n");
        try writeMap(stdout, &top_map);

        try stdout.writeAll("\n  SIDE VIEW (center=camera, up=elevation, right=forward):\n");
        try writeMap(stdout, &side_map);

        if (step < trace_steps) _ = app.applyCommand(.move_backward);
    }

    try stdout.flush();
}

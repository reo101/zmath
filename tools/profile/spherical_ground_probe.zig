const std = @import("std");
const zmath = @import("zmath");
const demo = @import("demo_core");

const curved = zmath.geometry.constant_curvature;
const Round = curved.AmbientFor(.spherical);
const SphericalView = curved.SphericalView;

const screen_width: usize = 160;
const screen_height: usize = 90;
const spherical_ground_radial_steps: usize = 8;
const spherical_ground_angular_steps: usize = 24;
const spherical_ground_subdivide_depth: usize = 1;

const GroundBasis = struct {
    origin: Round.Vector,
    right: Round.Vector,
    forward: Round.Vector,
};

const GroundExtents = struct {
    lateral: f32,
    backward: f32,
    forward: f32,
};

const ProbeStats = struct {
    full_visible: usize = 0,
    partial_visible: usize = 0,
    all_hidden: usize = 0,
    broken: usize = 0,
    center_visible: usize = 0,
    recursive_pieces: usize = 0,
};

fn configureReferenceState(app: *demo.App) void {
    app.animate = false;
    app.mode = .spherical;
    app.angle = 2.849999;
    app.camera.movement_mode = .walk;
    app.camera.euclid_rotation = 0.285000;
    app.camera.euclid_pitch = 0.180000;
    app.camera.euclid_eye_x = -11.469614;
    app.camera.euclid_eye_y = 0.0;
    app.camera.euclid_eye_z = -41.803680;
    app.camera.spherical = .{
        .params = .{
            .radius = 1.480000,
            .angular_zoom = 1.000000,
            .chart_model = .conformal,
        },
        .projection = .stereographic,
        .clip = .{ .near = 0.080000, .far = std.math.inf(f32) },
        .camera = .{
            .position = Round.fromCoords(.{ -0.956042, -0.096576, 0.000000, -0.276854 }),
            .right = Round.fromCoords(.{ 0.006139, 0.937401, 0.000000, -0.348198 }),
            .up = Round.fromCoords(.{ -0.052483, 0.059903, 0.983843, 0.160342 }),
            .forward = Round.fromCoords(.{ 0.288416, -0.329187, 0.179031, -0.881135 }),
        },
        .scene_sign = 1.0,
    };
}

fn walkEyeHeight(view: SphericalView) f32 {
    return view.params.radius * 0.035;
}

fn liftedWalkView(view: SphericalView, _: f32) SphericalView {
    const surface_up = view.walkSurfaceUp() orelse return view;
    var lifted = view;
    lifted.moveAlong(surface_up, walkEyeHeight(view));
    return lifted;
}

fn worldGroundBasis() GroundBasis {
    return .{
        .origin = Round.fromCoords(.{ 1.0, 0.0, 0.0, 0.0 }),
        .right = Round.fromCoords(.{ 0.0, 1.0, 0.0, 0.0 }),
        .forward = Round.fromCoords(.{ 0.0, 0.0, 0.0, 1.0 }),
    };
}

fn sphericalGroundBasisForPass(pass: curved.SphericalRenderPass) GroundBasis {
    const basis = worldGroundBasis();
    return switch (pass) {
        .near => basis,
        .far => .{
            .origin = Round.scale(basis.origin, -1.0),
            .right = basis.right,
            .forward = basis.forward,
        },
    };
}

fn groundExtents(view: SphericalView) GroundExtents {
    return .{
        .lateral = sphericalGroundTangentRadius(view.params),
        .backward = sphericalGroundTangentRadius(view.params),
        .forward = sphericalGroundTangentRadius(view.params),
    };
}

fn sphericalGroundTangentRadius(params: curved.Params) f32 {
    return params.radius * (@as(f32, std.math.pi) * 0.5) * 0.98;
}

fn groundPointAllowed(view: SphericalView, lateral: f32, forward_distance: f32) bool {
    const max_radius = sphericalGroundTangentRadius(view.params);
    return lateral * lateral + forward_distance * forward_distance <= max_radius * max_radius;
}

fn sampleVisible(sample: curved.ProjectedSample) bool {
    return sample.status == .visible and sample.projected != null;
}

fn groundCellBroken(
    render_view: SphericalView,
    p00: [2]f32,
    p10: [2]f32,
    p11: [2]f32,
    p01: [2]f32,
) bool {
    return curved.shouldBreakProjectedSegment(render_view.projection, p00, p10, screen_width, screen_height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p10, p11, screen_width, screen_height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p11, p01, screen_width, screen_height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p01, p00, screen_width, screen_height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p00, p11, screen_width, screen_height) or
        curved.shouldBreakProjectedSegment(render_view.projection, p10, p01, screen_width, screen_height);
}

fn sampleGround(
    world_view: SphericalView,
    render_view: SphericalView,
    pass: curved.SphericalRenderPass,
    basis: GroundBasis,
    lateral: f32,
    forward_distance: f32,
) curved.ProjectedSample {
    if (!groundPointAllowed(world_view, lateral, forward_distance)) return .{};
    const ambient = curved.ambientFromTypedTangentBasisPoint(
        .spherical,
        world_view.params,
        basis.origin,
        basis.right,
        basis.forward,
        lateral,
        forward_distance,
    ) orelse return .{};
    const screen = curved.Screen{
        .width = screen_width,
        .height = screen_height,
        .zoom = 0.52,
    };
    return render_view.sampleProjectedAmbientForSphericalPass(pass, ambient, screen);
}

fn recursivePieceCount(
    world_view: SphericalView,
    render_view: SphericalView,
    pass: curved.SphericalRenderPass,
    basis: GroundBasis,
    r0: f32,
    r1: f32,
    theta0: f32,
    theta1: f32,
    depth: usize,
) usize {
    const p00 = polarPoint(r0, theta0);
    const p10 = polarPoint(r1, theta0);
    const p11 = polarPoint(r1, theta1);
    const p01 = polarPoint(r0, theta1);
    const center = polarPoint((r0 + r1) * 0.5, (theta0 + theta1) * 0.5);

    const s00 = sampleGround(world_view, render_view, pass, basis, p00.lateral, p00.forward);
    const s10 = sampleGround(world_view, render_view, pass, basis, p10.lateral, p10.forward);
    const s11 = sampleGround(world_view, render_view, pass, basis, p11.lateral, p11.forward);
    const s01 = sampleGround(world_view, render_view, pass, basis, p01.lateral, p01.forward);
    const sc = sampleGround(world_view, render_view, pass, basis, center.lateral, center.forward);

    var visible_count: usize = 0;
    if (sampleVisible(s00)) visible_count += 1;
    if (sampleVisible(s10)) visible_count += 1;
    if (sampleVisible(s11)) visible_count += 1;
    if (sampleVisible(s01)) visible_count += 1;
    const center_visible = sampleVisible(sc);

    if (visible_count == 0 and !center_visible) return 0;

    if (visible_count == 4 and center_visible) {
        if (!groundCellBroken(render_view, s00.projected.?, s10.projected.?, s11.projected.?, s01.projected.?)) {
            return 1;
        }
    }

    if (depth > 0) {
        const radius_mid = (r0 + r1) * 0.5;
        const theta_mid = (theta0 + theta1) * 0.5;
        return recursivePieceCount(world_view, render_view, pass, basis, r0, radius_mid, theta0, theta_mid, depth - 1) +
            recursivePieceCount(world_view, render_view, pass, basis, radius_mid, r1, theta0, theta_mid, depth - 1) +
            recursivePieceCount(world_view, render_view, pass, basis, radius_mid, r1, theta_mid, theta1, depth - 1) +
            recursivePieceCount(world_view, render_view, pass, basis, r0, radius_mid, theta_mid, theta1, depth - 1);
    }

    if (!center_visible) return 0;
    var pieces: usize = 0;
    const corners = [_]curved.ProjectedSample{ s00, s10, s11, s01 };
    const next = [_]usize{ 1, 2, 3, 0 };
    const center_point = sc.projected.?;
    for (corners, 0..) |corner, i| {
        const adjacent = corners[next[i]];
        if (!sampleVisible(corner) or !sampleVisible(adjacent)) continue;
        const p0 = corner.projected.?;
        const p1 = adjacent.projected.?;
        if (curved.shouldBreakProjectedSegment(render_view.projection, center_point, p0, screen_width, screen_height) or
            curved.shouldBreakProjectedSegment(render_view.projection, center_point, p1, screen_width, screen_height) or
            curved.shouldBreakProjectedSegment(render_view.projection, p0, p1, screen_width, screen_height))
        {
            continue;
        }
        pieces += 1;
    }
    return pieces;
}

fn sphericalGroundRingRadius(max_radius: f32, t: f32) f32 {
    const remaining = 1.0 - t;
    return max_radius * (1.0 - remaining * remaining);
}

fn polarPoint(radius: f32, theta: f32) struct { lateral: f32, forward: f32 } {
    return .{
        .lateral = @cos(theta) * radius,
        .forward = @sin(theta) * radius,
    };
}

fn analyzePass(
    world_view: SphericalView,
    render_view: SphericalView,
    pass: curved.SphericalRenderPass,
    writer: anytype,
) !void {
    var stats = ProbeStats{};
    const basis = sphericalGroundBasisForPass(pass);
    const max_radius = sphericalGroundTangentRadius(world_view.params);
    const tau = @as(f32, std.math.pi) * 2.0;

    for (0..spherical_ground_radial_steps) |ri| {
        const t0 = @as(f32, @floatFromInt(ri)) / @as(f32, @floatFromInt(spherical_ground_radial_steps));
        const t1 = @as(f32, @floatFromInt(ri + 1)) / @as(f32, @floatFromInt(spherical_ground_radial_steps));
        const r0 = sphericalGroundRingRadius(max_radius, t0);
        const r1 = sphericalGroundRingRadius(max_radius, t1);

        for (0..spherical_ground_angular_steps) |ai| {
            const a0 = tau * @as(f32, @floatFromInt(ai)) / @as(f32, @floatFromInt(spherical_ground_angular_steps));
            const a1 = tau * @as(f32, @floatFromInt(ai + 1)) / @as(f32, @floatFromInt(spherical_ground_angular_steps));
            const p00 = polarPoint(r0, a0);
            const p10 = polarPoint(r1, a0);
            const p11 = polarPoint(r1, a1);
            const p01 = polarPoint(r0, a1);
            const center = polarPoint((r0 + r1) * 0.5, (a0 + a1) * 0.5);

            const s00 = sampleGround(world_view, render_view, pass, basis, p00.lateral, p00.forward);
            const s10 = sampleGround(world_view, render_view, pass, basis, p10.lateral, p10.forward);
            const s11 = sampleGround(world_view, render_view, pass, basis, p11.lateral, p11.forward);
            const s01 = sampleGround(world_view, render_view, pass, basis, p01.lateral, p01.forward);
            var visible_count: usize = 0;
            if (s00.status == .visible and s00.projected != null) visible_count += 1;
            if (s10.status == .visible and s10.projected != null) visible_count += 1;
            if (s11.status == .visible and s11.projected != null) visible_count += 1;
            if (s01.status == .visible and s01.projected != null) visible_count += 1;

            const center_sample = sampleGround(world_view, render_view, pass, basis, center.lateral, center.forward);
            if (sampleVisible(center_sample)) stats.center_visible += 1;

            if (visible_count == 0) {
                stats.all_hidden += 1;
            } else if (visible_count < 4) {
                stats.partial_visible += 1;
            } else {
                const pp00 = s00.projected.?;
                const pp10 = s10.projected.?;
                const pp11 = s11.projected.?;
                const pp01 = s01.projected.?;
                if (groundCellBroken(render_view, pp00, pp10, pp11, pp01)) {
                    stats.broken += 1;
                } else {
                    stats.full_visible += 1;
                }
            }
            stats.recursive_pieces += recursivePieceCount(world_view, render_view, pass, basis, r0, r1, a0, a1, spherical_ground_subdivide_depth);
        }
    }

    try writer.print(
        "{s}: full={d} partial={d} broken={d} hidden={d} center_visible={d} recursive_pieces={d}\n",
        .{ @tagName(pass), stats.full_visible, stats.partial_visible, stats.broken, stats.all_hidden, stats.center_visible, stats.recursive_pieces },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var app = try demo.App.init();
    configureReferenceState(&app);
    const world_view = app.camera.spherical;
    const render_view = liftedWalkView(world_view, app.camera.euclid_pitch);

    try stdout.writeAll("# spherical ground probe\n");
    try stdout.print(
        "eye_chart=({d:.6},{d:.6},{d:.6})\n",
        .{
            curved.vec3x(world_view.chartCoords(world_view.camera.position)),
            curved.vec3y(world_view.chartCoords(world_view.camera.position)),
            curved.vec3z(world_view.chartCoords(world_view.camera.position)),
        },
    );
    try analyzePass(world_view, render_view, .near, stdout);
    try analyzePass(world_view, render_view, .far, stdout);
    try stdout.flush();
}

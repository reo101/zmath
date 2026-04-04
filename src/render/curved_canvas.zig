const std = @import("std");
const canvas_api = @import("canvas.zig");
const curved = @import("../geometry/constant_curvature.zig");
const ga = @import("../ga.zig");

const Flat3 = ga.Algebra(ga.euclideanSignature(3)).Instantiate(f32);

pub const Mesh = struct {
    vertices: []const curved.Vec3,
    faces: []const [4]usize,
    edges: []const [2]usize,
};

pub const MeshStyle = struct {
    face_fill_steps: usize = 12,
    wrapped_face_fill_steps: usize = 48,
    edge_steps: usize = 64,
    face_tones: []const u8,
    light_direction: curved.Vec3 = curved.vec3(0.45, 0.75, -0.48),
    edge_char: u8 = '#',
    edge_near_tone: u8 = 255,
    edge_far_tone: u8 = 243,
};

fn viewMetric(view: anytype) curved.Metric {
    return switch (@TypeOf(view)) {
        curved.HyperView => .hyperbolic,
        curved.EllipticView => .elliptic,
        curved.SphericalView => .spherical,
        curved.View => view.metric,
        else => @compileError("expected typed or erased curved view"),
    };
}

pub fn drawMesh(
    canvas: *canvas_api.Canvas,
    mesh: Mesh,
    view: anytype,
    screen: curved.Screen,
    style: MeshStyle,
) void {
    drawFaces(canvas, mesh, view, screen, style);
    drawEdges(canvas, mesh, view, screen, style);
}

pub fn drawFaces(
    canvas: *canvas_api.Canvas,
    mesh: Mesh,
    view: anytype,
    screen: curved.Screen,
    style: MeshStyle,
) void {
    const fill_steps = if (viewMetric(view) == .spherical and view.projection == .wrapped)
        style.wrapped_face_fill_steps
    else
        style.face_fill_steps;

    for (mesh.faces, 0..) |face, face_index| {
        const a = mesh.vertices[face[0]];
        const b = mesh.vertices[face[1]];
        const c = mesh.vertices[face[2]];
        const d = mesh.vertices[face[3]];
        const shade = faceShade(a, b, d, style.light_direction);
        const tone = faceTone(style, face_index);

        for (0..fill_steps + 1) |ui| {
            const u = @as(f32, @floatFromInt(ui)) / @as(f32, @floatFromInt(fill_steps));
            for (0..fill_steps + 1) |vi| {
                const v = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(fill_steps));
                const point = curved.flatBilerpQuad(a, b, c, d, u, v);
                const sample = view.sampleProjectedPoint(point, screen);
                if (sample.status != .visible) continue;
                if (sample.projected) |p| {
                    canvas.setFill(p[0], p[1], shade, tone, sample.distance);
                }
            }
        }
    }
}

pub fn drawEdges(
    canvas: *canvas_api.Canvas,
    mesh: Mesh,
    view: anytype,
    screen: curved.Screen,
    style: MeshStyle,
) void {
    for (mesh.edges, 0..) |edge, edge_index| {
        drawEdge(
            canvas,
            mesh.vertices[edge[0]],
            mesh.vertices[edge[1]],
            view,
            screen,
            .{
                .steps = style.edge_steps,
                .char = style.edge_char,
                .near_tone = style.edge_near_tone,
                .far_tone = style.edge_far_tone,
                .tone = faceTone(style, edge_index),
            },
        );
    }
}

pub const EdgeStyle = struct {
    steps: usize = 64,
    char: u8 = '#',
    near_tone: u8 = 255,
    far_tone: u8 = 243,
    tone: u8 = 255,
};

pub fn drawEdge(
    canvas: *canvas_api.Canvas,
    a_chart: curved.Vec3,
    b_chart: curved.Vec3,
    view: anytype,
    screen: curved.Screen,
    style: EdgeStyle,
) void {
    var prev_point: ?[2]f32 = null;
    var prev_distance: ?f32 = null;
    var prev_status: curved.SampleStatus = .hidden;
    const shade_far_distance = view.shadeFarDistance();
    const metric = viewMetric(view);

    for (0..style.steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(style.steps));
        const chart = curved.geodesicChartPoint(metric, view.params, a_chart, b_chart, t) orelse {
            prev_point = null;
            prev_distance = null;
            prev_status = .hidden;
            continue;
        };
        const sample = view.sampleProjectedPoint(chart, screen);
        if (sample.projected) |p| {
            if (prev_status == .visible and sample.status == .visible) {
                if (prev_point) |pp| {
                    if (prev_distance) |pd| {
                        if (!curved.shouldBreakProjectedSegment(view.projection, pp, p, screen.width, screen.height)) {
                            canvas.drawLine(
                                pp[0],
                                pp[1],
                                p[0],
                                p[1],
                                style.char,
                                toneForDistance(pd + (sample.distance - pd) * 0.5, view.clip.near, shade_far_distance, style.near_tone, style.far_tone),
                            );
                        }
                    }
                }
            } else if (prev_status == .visible and sample.status == .clipped_near) {
                if (prev_point) |pp| canvas.setMarker(pp[0], pp[1], .near);
            } else if (prev_status == .visible and sample.status == .clipped_far) {
                if (prev_point) |pp| canvas.setMarker(pp[0], pp[1], .far);
            } else if (prev_status == .clipped_near and sample.status == .visible) {
                canvas.setMarker(p[0], p[1], .near);
            } else if (prev_status == .clipped_far and sample.status == .visible) {
                canvas.setMarker(p[0], p[1], .far);
            }

            if (sample.status == .visible) {
                prev_point = p;
                prev_distance = sample.distance;
            } else {
                prev_point = null;
                prev_distance = null;
            }
        } else {
            prev_point = null;
            prev_distance = null;
        }
        prev_status = sample.status;
    }
}

fn faceTone(style: MeshStyle, index: usize) u8 {
    std.debug.assert(style.face_tones.len > 0);
    return style.face_tones[index % style.face_tones.len];
}

fn flatVector(v: curved.Vec3) Flat3.Vector {
    return v;
}

fn safeNormalize(v: Flat3.Vector, fallback: Flat3.Vector) Flat3.Vector {
    return Flat3.normalize(v) catch fallback;
}

fn flatCross(a: Flat3.Vector, b: Flat3.Vector) Flat3.Vector {
    return a.wedge(b).dual().negate();
}

fn faceShade(a: curved.Vec3, b: curved.Vec3, d: curved.Vec3, light_direction: curved.Vec3) u8 {
    const light = safeNormalize(flatVector(light_direction), curved.vec3(0.0, 1.0, 0.0));
    const normal = safeNormalize(
        flatCross(flatVector(b).sub(flatVector(a)), flatVector(d).sub(flatVector(a))),
        curved.vec3(0.0, 0.0, -1.0),
    );
    const brightness = std.math.clamp(normal.scalarProduct(light), 0.0, 1.0);
    return 1 + @as(u8, @intFromFloat(brightness * 3.999));
}

fn toneForDistance(distance: f32, near_distance: f32, far_distance: f32, near_tone: u8, far_tone: u8) u8 {
    const span = @max(far_distance - near_distance, 1e-3);
    const t = std.math.clamp((distance - near_distance) / span, 0.0, 1.0);
    const near_f = @as(f32, @floatFromInt(near_tone));
    const far_f = @as(f32, @floatFromInt(far_tone));
    return @as(u8, @intFromFloat(@round(near_f + (far_f - near_f) * t)));
}

test "drawMesh paints visible curved cells and edges" {
    var canvas = try canvas_api.Canvas.init(std.testing.allocator, 80, 40);
    defer canvas.deinit();

    const params = curved.Params{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal };
    const view = try curved.HyperView.init(
        params,
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        curved.vec3(0.0, 0.0, -params.radius * 0.78),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const screen = curved.Screen{ .width = 80, .height = 40, .zoom = params.angular_zoom };
    const vertices = [_]curved.Vec3{
        curved.vec3(-0.15, -0.15, 0.02),
        curved.vec3(0.15, -0.15, 0.02),
        curved.vec3(0.15, 0.15, 0.02),
        curved.vec3(-0.15, 0.15, 0.02),
    };
    const mesh = Mesh{
        .vertices = vertices[0..],
        .faces = &.{.{ 0, 1, 2, 3 }},
        .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } },
    };

    drawMesh(&canvas, mesh, view, screen, .{ .face_tones = &.{220} });

    var fill_count: usize = 0;
    for (canvas.fill_shades) |shade| {
        if (shade > 0) fill_count += 1;
    }
    var subpixel_count: usize = 0;
    for (canvas.subpixels) |sample| {
        if (sample > 0) subpixel_count += 1;
    }

    try std.testing.expect(fill_count > 0);
    try std.testing.expect(subpixel_count > 0);
}

test "drawEdge marks clipped near transitions" {
    var canvas = try canvas_api.Canvas.init(std.testing.allocator, 80, 40);
    defer canvas.deinit();

    const params = curved.Params{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal };
    const view = try curved.HyperView.init(
        params,
        .gnomonic,
        .{ .near = 0.28, .far = 1.55 },
        curved.vec3(0.0, 0.0, -params.radius * 0.78),
        curved.vec3(0.0, 0.0, 0.0),
    );
    const screen = curved.Screen{ .width = 80, .height = 40, .zoom = params.angular_zoom };

    drawEdge(
        &canvas,
        curved.vec3(-0.02, 0.0, -params.radius * 0.70),
        curved.vec3(-0.02, 0.0, 0.18),
        view,
        screen,
        .{ .steps = 96 },
    );

    var marker_count: usize = 0;
    for (canvas.markers) |marker| {
        if (marker != 0) marker_count += 1;
    }

    try std.testing.expect(marker_count > 0);
}

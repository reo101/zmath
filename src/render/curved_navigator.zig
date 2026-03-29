const std = @import("std");
const canvas_api = @import("canvas.zig");
const curved = @import("../geometry/constant_curvature.zig");
const curved_canvas = @import("curved_canvas.zig");
const nav_geom = @import("curved_navigator_geometry.zig");

const NavigatorAxes = struct {
    horizontal: usize,
    vertical: usize,
};

pub const SphericalMapProjection = nav_geom.SphericalMapProjection;

const NavigatorRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub fn drawCurvedNavigator(
    canvas: *canvas_api.Canvas,
    mesh: curved_canvas.Mesh,
    view: curved.View,
    width: usize,
    height: usize,
) void {
    if (width < 54 or height < 26) return;

    const panel_width = @min(@as(usize, 26), @max(@as(usize, 18), width / 4));
    const panel_height = @min(@as(usize, 10), @max(@as(usize, 7), height / 5));
    const margin: usize = 2;
    const gap: usize = 2;
    const total_height = panel_height *| 2 +| gap;
    if (panel_width +| margin >= width or total_height +| margin *| 2 >= height) return;

    const panel_x = width - panel_width - margin;
    const top_y = margin;
    const bottom_y = top_y + panel_height + gap;
    const top_rect = NavigatorRect{ .x = panel_x, .y = top_y, .width = panel_width, .height = panel_height };
    const bottom_rect = NavigatorRect{ .x = panel_x, .y = bottom_y, .width = panel_width, .height = panel_height };

    const eye_chart = curved.chartCoords(view.metric, view.params, view.camera.position);
    var look_probe = view.camera;
    curved.moveForward(&look_probe, view.metric, view.params, @min(view.params.radius * 0.18, 0.18));
    const look_chart = curved.chartCoords(view.metric, view.params, look_probe.position);

    if (view.metric == .spherical) {
        const map_camera = nav_geom.sphericalGroundOverviewCamera(view);
        const stereo_radius = sphericalOverviewFieldRadius(view, .stereographic);
        const gnomonic_radius = sphericalOverviewFieldRadius(view, .gnomonic);
        const stereo_extent = sphericalGroundMapExtent(view, map_camera, mesh.vertices, .stereographic, stereo_radius);
        const gnomonic_extent = sphericalGroundMapExtent(view, map_camera, mesh.vertices, .gnomonic, gnomonic_radius);

        drawSphericalGroundOverviewPanel(canvas, top_rect, stereo_extent, view, mesh, map_camera, .stereographic, stereo_radius);
        drawSphericalGroundOverviewPanel(canvas, bottom_rect, gnomonic_extent, view, mesh, map_camera, .gnomonic, gnomonic_radius);
        return;
    }

    const extent = navigatorExtent(mesh.vertices, eye_chart, look_chart, view.metric);
    drawNavigatorPanel(canvas, top_rect, extent, view, mesh, eye_chart, look_chart, .{ .horizontal = 0, .vertical = 2 });
    drawNavigatorPanel(canvas, bottom_rect, extent, view, mesh, eye_chart, look_chart, .{ .horizontal = 2, .vertical = 1 });
}

fn drawNavigatorBackground(canvas: *canvas_api.Canvas, rect: NavigatorRect) void {
    for (rect.y..rect.y + rect.height) |y| {
        for (rect.x..rect.x + rect.width) |x| {
            canvas.setFill(@floatFromInt(x), @floatFromInt(y), 1, 236, -1.0);
        }
    }
}

fn drawNavigatorFrame(canvas: *canvas_api.Canvas, rect: NavigatorRect) void {
    const left = @as(f32, @floatFromInt(rect.x));
    const right = @as(f32, @floatFromInt(rect.x + rect.width - 1));
    const top = @as(f32, @floatFromInt(rect.y));
    const bottom = @as(f32, @floatFromInt(rect.y + rect.height - 1));

    canvas.drawLine(left, top, right, top, '#', 244);
    canvas.drawLine(left, bottom, right, bottom, '#', 244);
    canvas.drawLine(left, top, left, bottom, '#', 244);
    canvas.drawLine(right, top, right, bottom, '#', 244);
}

fn drawNavigatorAxes(canvas: *canvas_api.Canvas, rect: NavigatorRect) void {
    const center_x = @as(f32, @floatFromInt(rect.x + rect.width / 2));
    const center_y = @as(f32, @floatFromInt(rect.y + rect.height / 2));
    const left = @as(f32, @floatFromInt(rect.x + 1));
    const right = @as(f32, @floatFromInt(rect.x + rect.width - 2));
    const top = @as(f32, @floatFromInt(rect.y + 1));
    const bottom = @as(f32, @floatFromInt(rect.y + rect.height - 2));

    canvas.drawLine(left, center_y, right, center_y, '#', 239);
    canvas.drawLine(center_x, top, center_x, bottom, '#', 239);
}

fn projectNavigatorPoint(rect: NavigatorRect, extent: f32, horizontal: f32, vertical: f32) [2]f32 {
    const inner_left = @as(f32, @floatFromInt(rect.x + 1));
    const inner_top = @as(f32, @floatFromInt(rect.y + 1));
    const inner_width = @as(f32, @floatFromInt(rect.width - 2));
    const inner_height = @as(f32, @floatFromInt(rect.height - 2));

    return .{
        inner_left + (horizontal / extent * 0.5 + 0.5) * inner_width,
        inner_top + (0.5 - vertical / extent * 0.5) * inner_height,
    };
}

fn drawNavigatorMarker(canvas: *canvas_api.Canvas, point: [2]f32, tone: u8) void {
    canvas.drawLine(point[0] - 0.5, point[1], point[0] + 0.5, point[1], '#', tone);
    canvas.drawLine(point[0], point[1] - 0.5, point[0], point[1] + 0.5, '#', tone);
}

fn sphericalOverviewFieldRadius(view: curved.View, projection_mode: SphericalMapProjection) f32 {
    return switch (projection_mode) {
        .stereographic => view.params.radius * (@as(f32, std.math.pi) * 0.5) * 0.98,
        .gnomonic => view.params.radius * 1.10,
    };
}

fn drawSphericalMapGeodesic(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: SphericalMapProjection,
    a_chart: curved.Vec3,
    b_chart: curved.Vec3,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;

    for (0..25) |i| {
        const t = @as(f32, @floatFromInt(i)) / 24.0;
        const chart = curved.geodesicChartPoint(.spherical, view.params, a_chart, b_chart, t) orelse continue;
        const ambient = nav_geom.signedSphericalAmbient(view, chart) orelse continue;
        const map_point = nav_geom.sphericalMapPoint(map_camera, ambient, projection_mode) orelse {
            prev_point = null;
            continue;
        };
        const point = projectNavigatorPoint(rect, extent, map_point[0], map_point[1]);
        if (prev_point) |prev| {
            canvas.drawLine(prev[0], prev[1], point[0], point[1], '#', tone);
        }
        prev_point = point;
    }
}

fn drawSphericalGroundBoundary(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: SphericalMapProjection,
    field_radius: f32,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;

    for (0..65) |i| {
        const t = @as(f32, @floatFromInt(i)) / 64.0;
        const theta = t * @as(f32, std.math.pi) * 2.0;
        const lateral = @cos(theta) * field_radius;
        const forward = @sin(theta) * field_radius;
        const ambient = curved.ambientFromTangentBasisPoint(
            .spherical,
            view.params,
            map_camera.position,
            map_camera.right,
            map_camera.forward,
            lateral,
            forward,
        ) orelse continue;
        const map_point = nav_geom.sphericalMapPoint(map_camera, ambient, projection_mode) orelse {
            prev_point = null;
            continue;
        };
        const point = projectNavigatorPoint(rect, extent, map_point[0], map_point[1]);
        if (prev_point) |prev| {
            canvas.drawLine(prev[0], prev[1], point[0], point[1], '#', tone);
        }
        prev_point = point;
    }
}

fn drawSphericalGroundGridLine(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    map_camera: curved.Camera,
    projection_mode: SphericalMapProjection,
    fixed_is_lateral: bool,
    fixed: f32,
    field_radius: f32,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;

    for (0..49) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48.0;
        const varying = (t * 2.0 - 1.0) * field_radius;
        const lateral = if (fixed_is_lateral) fixed else varying;
        const forward = if (fixed_is_lateral) varying else fixed;
        const ambient = curved.ambientFromTangentBasisPoint(
            .spherical,
            view.params,
            map_camera.position,
            map_camera.right,
            map_camera.forward,
            lateral,
            forward,
        ) orelse {
            prev_point = null;
            continue;
        };
        const map_point = nav_geom.sphericalMapPoint(map_camera, ambient, projection_mode) orelse {
            prev_point = null;
            continue;
        };
        const point = projectNavigatorPoint(rect, extent, map_point[0], map_point[1]);
        if (prev_point) |prev| {
            canvas.drawLine(prev[0], prev[1], point[0], point[1], '#', tone);
        }
        prev_point = point;
    }
}

fn sphericalGroundMapExtent(
    view: curved.View,
    map_camera: curved.Camera,
    chart_vertices: []const curved.Vec3,
    projection_mode: SphericalMapProjection,
    field_radius: f32,
) f32 {
    var extent = nav_geom.sphericalGroundFieldExtent(view, map_camera, projection_mode, field_radius);

    for (chart_vertices) |vertex| {
        const ambient = nav_geom.signedSphericalAmbient(view, vertex) orelse continue;
        const point = nav_geom.sphericalMapPoint(map_camera, ambient, projection_mode) orelse continue;
        extent = @max(extent, @abs(point[0]) * 1.06);
        extent = @max(extent, @abs(point[1]) * 1.06);
    }

    return extent;
}

fn drawSphericalGroundOverviewPanel(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    mesh: curved_canvas.Mesh,
    map_camera: curved.Camera,
    projection_mode: SphericalMapProjection,
    field_radius: f32,
) void {
    drawNavigatorBackground(canvas, rect);
    drawNavigatorFrame(canvas, rect);
    drawNavigatorAxes(canvas, rect);

    drawSphericalGroundBoundary(canvas, rect, extent, view, map_camera, projection_mode, field_radius, 238);

    var line_index: i32 = -4;
    while (line_index <= 4) : (line_index += 1) {
        const line_t = @as(f32, @floatFromInt(line_index)) / 4.0;
        const fixed = line_t * field_radius;
        drawSphericalGroundGridLine(canvas, rect, extent, view, map_camera, projection_mode, true, fixed, field_radius, 238);
        drawSphericalGroundGridLine(canvas, rect, extent, view, map_camera, projection_mode, false, fixed, field_radius, 239);
    }

    for (mesh.edges) |edge| {
        drawSphericalMapGeodesic(
            canvas,
            rect,
            extent,
            view,
            map_camera,
            projection_mode,
            mesh.vertices[edge[0]],
            mesh.vertices[edge[1]],
            81,
        );
    }

    const eye_point = projectNavigatorPoint(rect, extent, 0.0, 0.0);
    const heading_ambient = curved.ambientFromTangentBasisPoint(
        .spherical,
        view.params,
        map_camera.position,
        map_camera.right,
        map_camera.forward,
        0.0,
        field_radius * 0.18,
    ) orelse return;
    const look_map = nav_geom.sphericalMapPoint(map_camera, heading_ambient, projection_mode) orelse return;
    const look_point = projectNavigatorPoint(rect, extent, look_map[0], look_map[1]);
    canvas.drawLine(eye_point[0], eye_point[1], look_point[0], look_point[1], '#', 253);
    drawNavigatorMarker(canvas, look_point, 253);
    drawNavigatorMarker(canvas, eye_point, 220);
}

fn navigatorExtent(chart_vertices: []const curved.Vec3, eye_chart: curved.Vec3, look_chart: curved.Vec3, metric: curved.Metric) f32 {
    var extent: f32 = switch (metric) {
        .hyperbolic => 0.38,
        .elliptic, .spherical => 1.0,
    };

    for (chart_vertices) |chart| {
        inline for (chart) |coord| {
            extent = @max(extent, @abs(coord) * 1.15);
        }
    }

    inline for (eye_chart) |coord| extent = @max(extent, @abs(coord) * 1.12);
    inline for (look_chart) |coord| extent = @max(extent, @abs(coord) * 1.12);
    return extent;
}

fn drawNavigatorGeodesic(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    axes: NavigatorAxes,
    a_chart: curved.Vec3,
    b_chart: curved.Vec3,
    tone: u8,
) void {
    var prev_point: ?[2]f32 = null;

    for (0..19) |i| {
        const t = @as(f32, @floatFromInt(i)) / 18.0;
        const chart = curved.geodesicChartPoint(view.metric, view.params, a_chart, b_chart, t) orelse continue;
        const point = projectNavigatorPoint(rect, extent, chart[axes.horizontal], chart[axes.vertical]);
        if (prev_point) |prev| {
            canvas.drawLine(prev[0], prev[1], point[0], point[1], '#', tone);
        }
        prev_point = point;
    }
}

fn drawNavigatorPanel(
    canvas: *canvas_api.Canvas,
    rect: NavigatorRect,
    extent: f32,
    view: curved.View,
    mesh: curved_canvas.Mesh,
    eye_chart: curved.Vec3,
    look_chart: curved.Vec3,
    axes: NavigatorAxes,
) void {
    drawNavigatorBackground(canvas, rect);
    drawNavigatorFrame(canvas, rect);
    drawNavigatorAxes(canvas, rect);

    for (mesh.edges) |edge| {
        drawNavigatorGeodesic(
            canvas,
            rect,
            extent,
            view,
            axes,
            mesh.vertices[edge[0]],
            mesh.vertices[edge[1]],
            81,
        );
    }

    const eye_point = projectNavigatorPoint(rect, extent, eye_chart[axes.horizontal], eye_chart[axes.vertical]);
    const look_point = projectNavigatorPoint(rect, extent, look_chart[axes.horizontal], look_chart[axes.vertical]);
    canvas.drawLine(eye_point[0], eye_point[1], look_point[0], look_point[1], '#', 253);
    drawNavigatorMarker(canvas, look_point, 253);
    drawNavigatorMarker(canvas, eye_point, 220);
}

test "drawCurvedNavigator paints minimap content" {
    var canvas = try canvas_api.Canvas.init(std.testing.allocator, 80, 40);
    defer canvas.deinit();

    const params = curved.Params{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal };
    const view = try curved.View.init(
        .hyperbolic,
        params,
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -params.radius * 0.78 },
        .{ 0.0, 0.0, 0.0 },
    );
    const vertices = [_]curved.Vec3{
        .{ -0.15, -0.15, 0.02 },
        .{ 0.15, -0.15, 0.02 },
        .{ 0.15, 0.15, 0.02 },
        .{ -0.15, 0.15, 0.02 },
    };
    const mesh = curved_canvas.Mesh{
        .vertices = vertices[0..],
        .faces = &.{.{ 0, 1, 2, 3 }},
        .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } },
    };

    drawCurvedNavigator(&canvas, mesh, view, 80, 40);

    var active_cells: usize = 0;
    for (canvas.fill_shades, canvas.markers) |shade, marker| {
        if (shade > 0 or marker != 0) active_cells += 1;
    }
    var active_subpixels: usize = 0;
    for (canvas.subpixels) |sample| {
        if (sample > 0) active_subpixels += 1;
    }

    try std.testing.expect(active_cells > 0);
    try std.testing.expect(active_subpixels > 0);
}

test "drawCurvedNavigator paints spherical overview content" {
    var canvas = try canvas_api.Canvas.init(std.testing.allocator, 80, 40);
    defer canvas.deinit();

    const params = curved.Params{ .radius = 1.48, .angular_zoom = 1.0, .chart_model = .conformal };
    const view = try curved.View.init(
        .spherical,
        params,
        .stereographic,
        .{ .near = 0.08, .far = std.math.inf(f32) },
        .{ 0.0, 0.0, -0.82 },
        .{ 0.0, 0.0, 0.0 },
    );
    const vertices = [_]curved.Vec3{
        .{ -0.12, 0.12, -0.12 },
        .{ 0.12, 0.12, -0.12 },
        .{ 0.12, 0.36, -0.12 },
        .{ -0.12, 0.36, -0.12 },
    };
    const mesh = curved_canvas.Mesh{
        .vertices = vertices[0..],
        .faces = &.{.{ 0, 1, 2, 3 }},
        .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } },
    };

    drawCurvedNavigator(&canvas, mesh, view, 80, 40);

    var active_cells: usize = 0;
    for (canvas.fill_shades, canvas.markers) |shade, marker| {
        if (shade > 0 or marker != 0) active_cells += 1;
    }
    var active_subpixels: usize = 0;
    for (canvas.subpixels) |sample| {
        if (sample > 0) active_subpixels += 1;
    }

    try std.testing.expect(active_cells > 0);
    try std.testing.expect(active_subpixels > 0);
}

test "drawCurvedNavigator is a no-op on tiny canvases" {
    var canvas = try canvas_api.Canvas.init(std.testing.allocator, 40, 20);
    defer canvas.deinit();

    const params = curved.Params{ .radius = 0.32, .angular_zoom = 0.72, .chart_model = .conformal };
    const view = try curved.View.init(
        .hyperbolic,
        params,
        .gnomonic,
        .{ .near = 0.08, .far = 1.55 },
        .{ 0.0, 0.0, -params.radius * 0.78 },
        .{ 0.0, 0.0, 0.0 },
    );
    const vertices = [_]curved.Vec3{
        .{ -0.15, -0.15, 0.02 },
        .{ 0.15, -0.15, 0.02 },
        .{ 0.15, 0.15, 0.02 },
        .{ -0.15, 0.15, 0.02 },
    };
    const mesh = curved_canvas.Mesh{
        .vertices = vertices[0..],
        .faces = &.{.{ 0, 1, 2, 3 }},
        .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } },
    };

    drawCurvedNavigator(&canvas, mesh, view, 40, 20);

    for (canvas.fill_shades, canvas.markers) |shade, marker| {
        try std.testing.expectEqual(@as(u8, 0), shade);
        try std.testing.expectEqual(@as(u8, 0), marker);
    }
    for (canvas.subpixels) |sample| {
        try std.testing.expectEqual(@as(u8, 0), sample);
    }
}

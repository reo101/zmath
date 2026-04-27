const std = @import("std");
const rl = @import("raylib");
const story = @import("raylib_demo_story");

const max_cube_face_steps = 18;

const QuadIssue = enum {
    rendered,
    skipped_bottom,
    hidden_corner,
    non_finite,
    near_eye,
    huge_bounds,
    outside_margin,
    twisted,
    long_edge,
};

const IssueStats = struct {
    rendered: usize = 0,
    skipped_bottom: usize = 0,
    hidden_corner: usize = 0,
    non_finite: usize = 0,
    near_eye: usize = 0,
    huge_bounds: usize = 0,
    outside_margin: usize = 0,
    twisted: usize = 0,
    long_edge: usize = 0,

    fn add(self: *IssueStats, issue: QuadIssue) void {
        switch (issue) {
            .rendered => self.rendered += 1,
            .skipped_bottom => self.skipped_bottom += 1,
            .hidden_corner => self.hidden_corner += 1,
            .non_finite => self.non_finite += 1,
            .near_eye => self.near_eye += 1,
            .huge_bounds => self.huge_bounds += 1,
            .outside_margin => self.outside_margin += 1,
            .twisted => self.twisted += 1,
            .long_edge => self.long_edge += 1,
        }
    }
};

const PointBounds = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,

    fn width(self: PointBounds) f32 {
        return self.max_x - self.min_x;
    }

    fn height(self: PointBounds) f32 {
        return self.max_y - self.min_y;
    }
};

const WorstCell = struct {
    face: usize = 0,
    u: usize = 0,
    v: usize = 0,
    max_edge: f32 = 0.0,
    bounds: PointBounds = .{ .min_x = 0.0, .max_x = 0.0, .min_y = 0.0, .max_y = 0.0 },
    depth: f32 = 0.0,
};

const FrameStats = struct {
    issues: IssueStats = .{},
    worst_rendered_edge: WorstCell = .{},
    worst_rejected_edge: WorstCell = .{},
    face_positive_area: [story.cube_faces.len]usize = @splat(0),
    face_negative_area: [story.cube_faces.len]usize = @splat(0),
    edge_cells: usize = 0,
    max_depth: f32 = 0.0,
    min_depth: f32 = std.math.inf(f32),
};

fn screenRect() rl.Rectangle {
    return .{
        .x = 22.0,
        .y = 22.0,
        .width = 1316.0,
        .height = 776.0,
    };
}

fn cubeFacePoint(vertices: [8]story.Vec3, face: story.Face, u: f32, v: f32) story.Vec3 {
    const a = vertices[face.indices[0]];
    const b = vertices[face.indices[1]];
    const c = vertices[face.indices[2]];
    const d = vertices[face.indices[3]];
    return story.Vec3.lerp(story.Vec3.lerp(a, b, u), story.Vec3.lerp(d, c, u), v);
}

fn analyzeFrame(camera: *const story.Camera) FrameStats {
    const rect = screenRect();
    const vertices = story.cubeVerticesFor(.spherical, camera.*);
    var stats = FrameStats{};

    for (story.cube_faces, 0..) |face, face_index| {
        if (face_index == story.cube_bottom_face_index) {
            stats.issues.skipped_bottom += max_cube_face_steps * max_cube_face_steps;
            continue;
        }
        var u_index: usize = 0;
        while (u_index < max_cube_face_steps) : (u_index += 1) {
            var v_index: usize = 0;
            while (v_index < max_cube_face_steps) : (v_index += 1) {
                const min_u = @as(f32, @floatFromInt(u_index)) / @as(f32, @floatFromInt(max_cube_face_steps));
                const min_v = @as(f32, @floatFromInt(v_index)) / @as(f32, @floatFromInt(max_cube_face_steps));
                const max_u = @as(f32, @floatFromInt(u_index + 1)) / @as(f32, @floatFromInt(max_cube_face_steps));
                const max_v = @as(f32, @floatFromInt(v_index + 1)) / @as(f32, @floatFromInt(max_cube_face_steps));

                const cell = [_]story.Vec3{
                    cubeFacePoint(vertices, face, min_u, min_v),
                    cubeFacePoint(vertices, face, max_u, min_v),
                    cubeFacePoint(vertices, face, max_u, max_v),
                    cubeFacePoint(vertices, face, min_u, max_v),
                };

                var points: [4]rl.Vector2 = undefined;
                var depth: f32 = 0.0;
                var visible = true;
                for (cell, 0..) |world, point_index| {
                    const projected = story.project(.spherical, camera, world, rect, .main) orelse {
                        visible = false;
                        break;
                    };
                    points[point_index] = projected.pos;
                    depth += projected.depth;
                }

                const issue = if (visible)
                    classifyProjectedCell(rect, points, depth / 4.0)
                else
                    QuadIssue.hidden_corner;
                stats.issues.add(issue);

                if (!visible) continue;
                const bounds = pointBounds(points);
                const max_edge = maxQuadEdge(points);
                const cell_info = WorstCell{
                    .face = face_index,
                    .u = u_index,
                    .v = v_index,
                    .max_edge = max_edge,
                    .bounds = bounds,
                    .depth = depth / 4.0,
                };

                if (issue == .rendered) {
                    if (quadSignedArea(points) >= 0.0) {
                        stats.face_positive_area[face_index] += 1;
                    } else {
                        stats.face_negative_area[face_index] += 1;
                    }
                    if (max_edge > stats.worst_rendered_edge.max_edge) stats.worst_rendered_edge = cell_info;
                    if (isNearViewportEdge(rect, bounds)) stats.edge_cells += 1;
                    stats.min_depth = @min(stats.min_depth, depth / 4.0);
                    stats.max_depth = @max(stats.max_depth, depth / 4.0);
                } else if (max_edge > stats.worst_rejected_edge.max_edge) {
                    stats.worst_rejected_edge = cell_info;
                }
            }
        }
    }

    return stats;
}

fn classifyProjectedCell(rect: rl.Rectangle, points: [4]rl.Vector2, depth: f32) QuadIssue {
    if (!std.math.isFinite(depth) or depth < 0.28) return .near_eye;

    for (points) |point| {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return .non_finite;
    }

    const bounds = pointBounds(points);
    const max_dim = @max(rect.width, rect.height);
    if (bounds.max_x < rect.x or bounds.min_x > rect.x + rect.width) return .outside_margin;
    if (bounds.max_y < rect.y or bounds.min_y > rect.y + rect.height) return .outside_margin;
    if (bounds.width() > max_dim * 0.45 or bounds.height() > max_dim * 0.45) return .huge_bounds;

    const point_margin = max_dim * 0.12;
    for (points) |point| {
        if (point.x < rect.x - point_margin or point.x > rect.x + rect.width + point_margin) return .outside_margin;
        if (point.y < rect.y - point_margin or point.y > rect.y + rect.height + point_margin) return .outside_margin;
    }
    if (!quadHasConsistentWinding(points)) return .twisted;

    const max_edge = max_dim * 0.24;
    if (maxQuadEdge(points) > max_edge) return .long_edge;

    return .rendered;
}

fn pointBounds(points: [4]rl.Vector2) PointBounds {
    var bounds = PointBounds{
        .min_x = points[0].x,
        .max_x = points[0].x,
        .min_y = points[0].y,
        .max_y = points[0].y,
    };
    for (points[1..]) |point| {
        bounds.min_x = @min(bounds.min_x, point.x);
        bounds.max_x = @max(bounds.max_x, point.x);
        bounds.min_y = @min(bounds.min_y, point.y);
        bounds.max_y = @max(bounds.max_y, point.y);
    }
    return bounds;
}

fn maxQuadEdge(points: [4]rl.Vector2) f32 {
    return @sqrt(@max(
        @max(distanceSquared(points[0], points[1]), distanceSquared(points[1], points[2])),
        @max(distanceSquared(points[2], points[3]), distanceSquared(points[3], points[0])),
    ));
}

fn quadSignedArea(points: [4]rl.Vector2) f32 {
    var area: f32 = 0.0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const a = points[i];
        const b = points[(i + 1) % points.len];
        area += a.x * b.y - b.x * a.y;
    }
    return area * 0.5;
}

fn distanceSquared(a: rl.Vector2, b: rl.Vector2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

fn quadHasConsistentWinding(points: [4]rl.Vector2) bool {
    var sign: f32 = 0.0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const a = points[i];
        const b = points[(i + 1) % points.len];
        const c = points[(i + 2) % points.len];
        const cross = cross2(a, b, c);
        if (@abs(cross) <= 1e-3) continue;

        const current_sign: f32 = if (cross > 0.0) 1.0 else -1.0;
        if (sign == 0.0) {
            sign = current_sign;
        } else if (sign != current_sign) {
            return false;
        }
    }
    return sign != 0.0;
}

fn cross2(a: rl.Vector2, b: rl.Vector2, c: rl.Vector2) f32 {
    return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
}

fn isNearViewportEdge(rect: rl.Rectangle, bounds: PointBounds) bool {
    const edge_band = @max(rect.width, rect.height) * 0.08;
    return bounds.min_x < rect.x + edge_band or
        bounds.max_x > rect.x + rect.width - edge_band or
        bounds.min_y < rect.y + edge_band or
        bounds.max_y > rect.y + rect.height - edge_band;
}

fn printWorst(writer: anytype, label: []const u8, cell: WorstCell) !void {
    try writer.print(
        "{s}=face:{d} cell:{d},{d} edge:{d:.2} depth:{d:.2} bounds:[{d:.1},{d:.1}]x[{d:.1},{d:.1}]",
        .{
            label,
            cell.face,
            cell.u,
            cell.v,
            cell.max_edge,
            cell.depth,
            cell.bounds.min_x,
            cell.bounds.max_x,
            cell.bounds.min_y,
            cell.bounds.max_y,
        },
    );
}

fn printFrame(writer: anytype, label: []const u8, camera: story.Camera, stats: FrameStats) !void {
    const rendered = stats.issues.rendered;
    const rejected = stats.issues.skipped_bottom + stats.issues.hidden_corner + stats.issues.non_finite + stats.issues.near_eye +
        stats.issues.huge_bounds + stats.issues.outside_margin + stats.issues.twisted + stats.issues.long_edge;
    try writer.print(
        "{s} pos=({d:.2},{d:.2},{d:.2}) pitch={d:.2} rendered={d} edge={d} rejected={d} skipped_bottom={d} hidden={d} near={d} huge={d} outside={d} twisted={d} long={d} depth=[{d:.2},{d:.2}] ",
        .{
            label,
            camera.position.x,
            camera.position.y,
            camera.position.z,
            camera.pitch,
            rendered,
            stats.edge_cells,
            rejected,
            stats.issues.skipped_bottom,
            stats.issues.hidden_corner,
            stats.issues.near_eye,
            stats.issues.huge_bounds,
            stats.issues.outside_margin,
            stats.issues.twisted,
            stats.issues.long_edge,
            if (std.math.isFinite(stats.min_depth)) stats.min_depth else -1.0,
            stats.max_depth,
        },
    );
    try printWorst(writer, "worst_rendered", stats.worst_rendered_edge);
    try writer.writeAll(" ");
    try printWorst(writer, "worst_rejected", stats.worst_rejected_edge);
    try writer.print(
        " face_area=[{d}+/{d}-,{d}+/{d}-,{d}+/{d}-,{d}+/{d}-,{d}+/{d}-,{d}+/{d}-]",
        .{
            stats.face_positive_area[0],
            stats.face_negative_area[0],
            stats.face_positive_area[1],
            stats.face_negative_area[1],
            stats.face_positive_area[2],
            stats.face_negative_area[2],
            stats.face_positive_area[3],
            stats.face_negative_area[3],
            stats.face_positive_area[4],
            stats.face_negative_area[4],
            stats.face_positive_area[5],
            stats.face_negative_area[5],
        },
    );
    try writer.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("# raylib spherical cube CPU projection probe\n");

    var camera = story.Camera.reset(.spherical);
    var frame_index: usize = 0;
    while (frame_index < 120) : (frame_index += 1) {
        if (frame_index % 10 == 0 or frame_index > 100) {
            var label_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "forward_{d}", .{frame_index});
            try printFrame(stdout, label, camera, analyzeFrame(&camera));
        }
        camera.moveLocal(.{ .forward = true }, .spherical, 1.0 / 30.0);
    }

    var close = camera;
    var pitch_index: usize = 0;
    while (pitch_index <= 8) : (pitch_index += 1) {
        close = camera;
        const pitch = -0.55 + @as(f32, @floatFromInt(pitch_index)) * 0.14;
        close.pitch = pitch;
        close.moveLocal(.{}, .spherical, 0.0);
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "pitch_{d:.2}", .{pitch});
        try printFrame(stdout, label, close, analyzeFrame(&close));
    }

    try stdout.flush();
}

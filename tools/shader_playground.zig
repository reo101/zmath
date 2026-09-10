const std = @import("std");

const c = @import("vulkan_glfw");
const object_scene = @import("object_scene");
const spherical_scene = @import("spherical_scene");

const window_width = 960;
const window_height = 640;
const max_frames_in_flight = 2;
const raster_margin_pixels = 0.75;

const MaxFaces = 384;
const MaxObjects = 64;
const MaxMaterials = 16;

const SphericalFrame = extern struct {
    width: f32,
    height: f32,
    radius: f32,
    tan_half_fov: f32,
    ground_a: f32,
    object_count: f32,
    origin: [4]f32,
    right: [4]f32,
    up: [4]f32,
    forward: [4]f32,
};

const ObjectGpuBlock = extern struct {
    normals: [MaxFaces][4]f32,
    meta: [MaxFaces][4]f32,
    colors: [MaxMaterials][4]f32,
    bounds: [MaxObjects][4]f32,
};

const default_object_path = "assets/spherical/world.s3obj.json";

const default_vert_path = "zig-out/shaders/vga_passthrough_raw.vert.spv";
const default_frag_path = "zig-out/shaders/vga_passthrough_raw.frag.spv";

const Vertex = extern struct {
    pos: [3]f32,
    color: [4]f32,
    plane: [4]f32,
};

const MeshTriangle = struct {
    points: [3][4]f32,
    color: [4]f32,
    plane: [4]f32,
    object_index: usize,
};

const FacePoint = struct {
    point: [4]f32,
    angle: f32,
};

fn dot4(a: [4]f32, b: [4]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn normalize4(v: [4]f32) ?[4]f32 {
    const length = @sqrt(dot4(v, v));
    if (length < 1e-6) return null;
    return .{ v[0] / length, v[1] / length, v[2] / length, v[3] / length };
}

fn sub4(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
}

fn add4(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

fn scale4(a: [4]f32, scale: f32) [4]f32 {
    return .{ a[0] * scale, a[1] * scale, a[2] * scale, a[3] * scale };
}

fn det3(a: [3]f32, b: [3]f32, c_: [3]f32) f32 {
    return a[0] * (b[1] * c_[2] - b[2] * c_[1]) -
        a[1] * (b[0] * c_[2] - b[2] * c_[0]) +
        a[2] * (b[0] * c_[1] - b[1] * c_[0]);
}

fn nullVector(a: [4]f32, b: [4]f32, c_: [4]f32) ?[4]f32 {
    const result = [4]f32{
        det3(.{ a[1], a[2], a[3] }, .{ b[1], b[2], b[3] }, .{ c_[1], c_[2], c_[3] }),
        -det3(.{ a[0], a[2], a[3] }, .{ b[0], b[2], b[3] }, .{ c_[0], c_[2], c_[3] }),
        det3(.{ a[0], a[1], a[3] }, .{ b[0], b[1], b[3] }, .{ c_[0], c_[1], c_[3] }),
        -det3(.{ a[0], a[1], a[2] }, .{ b[0], b[1], b[2] }, .{ c_[0], c_[1], c_[2] }),
    };
    return normalize4(result);
}

fn faceContains(point: [4]f32, normals: [6][4]f32, faces: []const object_scene.Face) bool {
    for (faces, 0..) |face, i| {
        const side = dot4(point, normals[i]);
        if (if (face.positive) side < -1e-4 else side > 1e-4) return false;
    }
    return true;
}

fn appendSubdividedTriangle(
    triangles: *std.ArrayList(MeshTriangle),
    allocator: std.mem.Allocator,
    a: [4]f32,
    b: [4]f32,
    c_: [4]f32,
    color: [4]f32,
    plane: [4]f32,
    object_index: usize,
    depth: u32,
) !void {
    if (depth == 0) {
        try triangles.append(allocator, .{ .points = .{ a, b, c_ }, .color = color, .plane = plane, .object_index = object_index });
        return;
    }
    const ab = normalize4(add4(a, b)) orelse return;
    const bc = normalize4(add4(b, c_)) orelse return;
    const ca = normalize4(add4(c_, a)) orelse return;
    try appendSubdividedTriangle(triangles, allocator, a, ab, ca, color, plane, object_index, depth - 1);
    try appendSubdividedTriangle(triangles, allocator, ab, b, bc, color, plane, object_index, depth - 1);
    try appendSubdividedTriangle(triangles, allocator, ca, bc, c_, color, plane, object_index, depth - 1);
    try appendSubdividedTriangle(triangles, allocator, ab, bc, ca, color, plane, object_index, depth - 1);
}

fn projectPoint(frame: SphericalFrame, point: [4]f32) ?[3]f32 {
    // A screen pixel denotes the initial tangent direction of a geodesic,
    // not the S3 position of its eventual hit. Euclidean perspective makes
    // those equivalent; S3 does not. Project the tangent from the camera to
    // the point so a raster vertex uses the exact same view map as the tracer.
    const path_cos = dot4(frame.origin, point);
    const path_sin = @sqrt(@max(0.0, 1.0 - path_cos * path_cos));
    if (path_sin <= 1e-5) return null;
    const tangent = scale4(sub4(point, scale4(frame.origin, path_cos)), 1.0 / path_sin);
    const forward_cos = dot4(frame.forward, tangent);
    const denominator = 1.0 + forward_cos;
    if (denominator <= 0.02) return null;
    const inv = 1.0 / (denominator * frame.tan_half_fov);
    const aspect_scale = frame.height / frame.width * (1280.0 / 720.0);
    return .{
        dot4(frame.right, tangent) * inv * aspect_scale,
        -dot4(frame.up, tangent) * inv,
        (1.0 - path_cos) * 0.5,
    };
}

fn frameDirection(frame: SphericalFrame, uv: [2]f32) [4]f32 {
    const r = @sqrt(uv[0] * uv[0] + uv[1] * uv[1]);
    if (r < 1e-6) return frame.forward;
    const t = r * frame.tan_half_fov;
    const inverse = 1.0 / (1.0 + t * t);
    const sin_theta = 2.0 * t * inverse;
    const cos_theta = (1.0 - t * t) * inverse;
    return normalize4(.{
        frame.forward[0] * cos_theta + (frame.right[0] * uv[0] + frame.up[0] * uv[1]) * sin_theta / r,
        frame.forward[1] * cos_theta + (frame.right[1] * uv[0] + frame.up[1] * uv[1]) * sin_theta / r,
        frame.forward[2] * cos_theta + (frame.right[2] * uv[0] + frame.up[2] * uv[1]) * sin_theta / r,
        frame.forward[3] * cos_theta + (frame.right[3] * uv[0] + frame.up[3] * uv[1]) * sin_theta / r,
    }).?;
}

fn planeDepth(frame: SphericalFrame, dir: [4]f32, plane: [4]f32) f32 {
    const a = dot4(frame.origin, plane);
    const b = dot4(dir, plane);
    const h = @sqrt(a * a + b * b);
    const cos_angle = if (a >= 0.0) -b / h else b / h;
    return (1.0 - cos_angle) * 0.5;
}

fn buildMeshTriangles(allocator: std.mem.Allocator, file: object_scene.File) ![]MeshTriangle {
    var triangles: std.ArrayList(MeshTriangle) = .empty;
    errdefer triangles.deinit(allocator);

    for (file.objects, 0..) |object, object_index| {
        if (object.faces.len != 6) continue;
        var normals: [6][4]f32 = undefined;
        for (object.faces, 0..) |face, i| normals[i] = object.transformNormal(face.normal);

        for (object.faces, 0..) |face, face_index| {
            var points: [8]FacePoint = undefined;
            var point_count: usize = 0;
            var j: usize = 0;
            while (j < 6) : (j += 1) {
                if (j == face_index) continue;
                var k = j + 1;
                while (k < 6) : (k += 1) {
                    if (k == face_index) continue;
                    const candidate = nullVector(normals[face_index], normals[j], normals[k]) orelse continue;
                    for ([_]f32{ 1.0, -1.0 }) |sign| {
                        const point = scale4(candidate, sign);
                        if (!faceContains(point, normals, object.faces)) continue;
                        var duplicate = false;
                        for (points[0..point_count]) |existing| {
                            if (dot4(existing.point, point) > 0.9999) duplicate = true;
                        }
                        if (!duplicate and point_count < points.len) {
                            points[point_count] = .{ .point = point, .angle = 0.0 };
                            point_count += 1;
                        }
                    }
                }
            }
            if (point_count < 3) continue;

            var center_sum = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
            for (points[0..point_count]) |point| center_sum = add4(center_sum, point.point);
            const center = normalize4(center_sum) orelse continue;
            const radial = sub4(points[0].point, scale4(center, dot4(points[0].point, center)));
            const e1 = normalize4(radial) orelse continue;
            const e2 = nullVector(normals[face_index], center, e1) orelse continue;
            for (points[0..point_count]) |*point| {
                point.angle = std.math.atan2(dot4(point.point, e2), dot4(point.point, e1));
            }
            std.mem.sort(FacePoint, points[0..point_count], {}, struct {
                fn lessThan(_: void, left: FacePoint, right: FacePoint) bool {
                    return left.angle < right.angle;
                }
            }.lessThan);

            const material = file.materials[face.material];
            const color = .{
                material.color[0] * (0.55 + 0.45 * material.tone),
                material.color[1] * (0.55 + 0.45 * material.tone),
                material.color[2] * (0.55 + 0.45 * material.tone),
                material.color[3],
            };
            for (0..point_count) |i| {
                const next = (i + 1) % point_count;
                try appendSubdividedTriangle(&triangles, allocator, center, points[i].point, points[next].point, color, normals[face_index], object_index, 4);
            }
        }
    }
    return try triangles.toOwnedSlice(allocator);
}

fn frameForScene(scene: spherical_scene.Scene, width: f32, height: f32) SphericalFrame {
    const tracer = scene.tracer();
    const camera = scene.frameCamera();
    return .{
        .width = width,
        .height = height,
        .radius = tracer.radius,
        .tan_half_fov = camera.tan_half_fov,
        .ground_a = tracer.ground_a,
        .object_count = 0.0,
        .origin = tracer.origin.coeffsArray(),
        .right = tracer.right.coeffsArray(),
        .up = tracer.up.coeffsArray(),
        .forward = tracer.forward.coeffsArray(),
    };
}

fn triangleContains(point: [3]f32, triangle: [3][3]f32) bool {
    const edge = struct {
        fn cross(a: [3]f32, b: [3]f32, p: [3]f32) f32 {
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
        }
    }.cross;
    const a = edge(triangle[0], triangle[1], point);
    const b = edge(triangle[1], triangle[2], point);
    const c_ = edge(triangle[2], triangle[0], point);
    return (a >= -1e-4 and b >= -1e-4 and c_ >= -1e-4) or
        (a <= 1e-4 and b <= 1e-4 and c_ <= 1e-4);
}

fn triangleContainsStrict(point: [3]f32, triangle: [3][3]f32) bool {
    const edge = struct {
        fn cross(a: [3]f32, b: [3]f32, p: [3]f32) f32 {
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
        }
    }.cross;
    const a = edge(triangle[0], triangle[1], point);
    const b = edge(triangle[1], triangle[2], point);
    const c_ = edge(triangle[2], triangle[0], point);
    return (a >= 0.0 and b >= 0.0 and c_ >= 0.0) or
        (a <= 0.0 and b <= 0.0 and c_ <= 0.0);
}

fn meshStrictCoversPoint(triangles: []const MeshTriangle, frame: SphericalFrame, point: [4]f32) bool {
    const projected_point = projectPoint(frame, point) orelse return false;
    for (triangles) |triangle| {
        const a = projectPoint(frame, triangle.points[0]) orelse continue;
        const b = projectPoint(frame, triangle.points[1]) orelse continue;
        const c_ = projectPoint(frame, triangle.points[2]) orelse continue;
        if (triangleContainsStrict(projected_point, .{ a, b, c_ })) return true;
    }
    return false;
}

fn meshCoversPoint(triangles: []const MeshTriangle, frame: SphericalFrame, point: [4]f32) bool {
    const projected_point = projectPoint(frame, point) orelse return false;
    for (triangles) |triangle| {
        const a = projectPoint(frame, triangle.points[0]) orelse continue;
        const b = projectPoint(frame, triangle.points[1]) orelse continue;
        const c_ = projectPoint(frame, triangle.points[2]) orelse continue;
        if (triangleContains(projected_point, .{ a, b, c_ })) return true;
    }
    return false;
}

const MeshCoverStatus = enum { none, rasterizable, filtered };

fn meshCoverStatus(triangles: []const MeshTriangle, frame: SphericalFrame, point: [4]f32) MeshCoverStatus {
    const projected_point = projectPoint(frame, point) orelse return .none;
    var covered = false;
    for (triangles) |triangle| {
        var projected: [3][3]f32 = undefined;
        var valid = true;
        for (triangle.points, 0..) |vertex, i| {
            projected[i] = projectPoint(frame, vertex) orelse {
                valid = false;
                break;
            };
        }
        if (!valid or !triangleContains(projected_point, projected)) continue;
        covered = true;
        inline for (0..3) |i| {
            const next = (i + 1) % 3;
            const dx = projected[i][0] - projected[next][0];
            const dy = projected[i][1] - projected[next][1];
            if (@abs(projected[i][0]) > 4.0 or @abs(projected[i][1]) > 4.0 or dx * dx + dy * dy > 4.0) valid = false;
        }
        if (valid) return .rasterizable;
    }
    return if (covered) .filtered else .none;
}

const RasterHit = struct {
    object_index: ?usize = null,
    depth: f32 = 1.0,
};

const RasterCompare = struct {
    pixels: usize = 0,
    object_mismatches: usize = 0,
    depth_mismatches: usize = 0,
    first_mismatch: ?struct { x: usize, y: usize, expected: ?usize, actual: ?usize, expected_depth: f32, actual_depth: f32, mesh_covers: bool, mesh_strict_covers: bool, cover_status: MeshCoverStatus, hit_ndc: [2]f32, sample_ndc: [2]f32 } = null,
};

fn rasterCompare(triangles: []const MeshTriangle, scene: spherical_scene.Scene) !RasterCompare {
    const width = window_width;
    const height = window_height;
    const frame = frameForScene(scene, width, height);
    const raster = try std.heap.page_allocator.alloc(RasterHit, width * height);
    defer std.heap.page_allocator.free(raster);
    for (raster, 0..) |*hit, index| {
        const x = index % width;
        const y = index / width;
        const disc_u = (@as(f32, @floatFromInt(x)) + 0.5) / width * 2.0 - 1.0;
        const disc_v = 1.0 - (@as(f32, @floatFromInt(y)) + 0.5) / height * 2.0;
        if (disc_u * disc_u + disc_v * disc_v > 1.0) continue;
        const dir = frameDirection(frame, .{ disc_u * frame.width / frame.height / (1280.0 / 720.0), disc_v });
        hit.depth = planeDepth(frame, dir, .{ 0.0, 0.0, 1.0, 0.0 });
    }

    for (triangles) |triangle| {
        var projected: [3][3]f32 = undefined;
        var valid = true;
        for (triangle.points, 0..) |point, i| {
            const pos = projectPoint(frame, point) orelse {
                valid = false;
                break;
            };
            if (@abs(pos[0]) > 4.0 or @abs(pos[1]) > 4.0) {
                valid = false;
                break;
            }
            projected[i] = pos;
        }
        if (valid) {
            inline for (0..3) |i| {
                const next = (i + 1) % 3;
                const dx = projected[i][0] - projected[next][0];
                const dy = projected[i][1] - projected[next][1];
                if (dx * dx + dy * dy > 4.0) valid = false;
            }
        }
        if (!valid) continue;

        const center = [2]f32{
            (projected[0][0] + projected[1][0] + projected[2][0]) / 3.0,
            (projected[0][1] + projected[1][1] + projected[2][1]) / 3.0,
        };
        for (&projected) |*vertex| {
            const dx = (vertex[0] - center[0]) * frame.width * 0.5;
            const dy = (vertex[1] - center[1]) * frame.height * 0.5;
            const length = @sqrt(dx * dx + dy * dy);
            if (length == 0.0) continue;
            vertex[0] += dx / length * (2.0 * raster_margin_pixels / @as(f32, window_width));
            vertex[1] += dy / length * (2.0 * raster_margin_pixels / @as(f32, window_height));
        }

        const left = @min(projected[0][0], @min(projected[1][0], projected[2][0]));
        const right = @max(projected[0][0], @max(projected[1][0], projected[2][0]));
        const top = @max(projected[0][1], @max(projected[1][1], projected[2][1]));
        const bottom = @min(projected[0][1], @min(projected[1][1], projected[2][1]));
        const min_x = std.math.clamp(@as(isize, @intFromFloat(@floor((left + 1.0) * 0.5 * width))), 0, width - 1);
        const max_x = std.math.clamp(@as(isize, @intFromFloat(@ceil((right + 1.0) * 0.5 * width))), 0, width - 1);
        // Vulkan's positive-height viewport maps NDC -1 to the top row.
        const min_y = std.math.clamp(@as(isize, @intFromFloat(@floor((bottom + 1.0) * 0.5 * height))), 0, height - 1);
        const max_y = std.math.clamp(@as(isize, @intFromFloat(@ceil((top + 1.0) * 0.5 * height))), 0, height - 1);
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const point = [3]f32{
                    (@as(f32, @floatFromInt(x)) + 0.5) / width * 2.0 - 1.0,
                    (@as(f32, @floatFromInt(y)) + 0.5) / height * 2.0 - 1.0,
                    0.0,
                };
                if (!triangleContainsStrict(point, projected)) continue;
                const dir = frameDirection(frame, .{ point[0] * frame.width / frame.height / (1280.0 / 720.0), -point[1] });
                const a = dot4(frame.origin, triangle.plane);
                const b = dot4(dir, triangle.plane);
                if (a * a + b * b < 1e-10) continue;
                const depth = planeDepth(frame, dir, triangle.plane);
                const index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                if (depth < raster[index].depth) raster[index] = .{ .object_index = triangle.object_index, .depth = depth };
            }
        }
    }

    const tracer = scene.tracer();
    var result = RasterCompare{};
    for (raster, 0..) |actual, index| {
        const x = index % width;
        const y = index / width;
        const disc_uv = [2]f32{
            (@as(f32, @floatFromInt(x)) + 0.5) / width * 2.0 - 1.0,
            1.0 - (@as(f32, @floatFromInt(y)) + 0.5) / height * 2.0,
        };
        if (disc_uv[0] * disc_uv[0] + disc_uv[1] * disc_uv[1] > 1.0) continue;
        const uv = [2]f32{ disc_uv[0] * frame.width / frame.height / (1280.0 / 720.0), disc_uv[1] };
        result.pixels += 1;
        const hit = tracer.trace(spherical_scene.Direction.init(frameDirection(frame, uv)));
        const expected: ?usize = switch (hit.surface) {
            .ground => null,
            .cube => 0,
            .fence => 1,
        };
        const actual_object = if (actual.object_index) |object_index| if (object_index == 0) @as(?usize, 0) else 1 else null;
        const expected_depth = (1.0 - hit.cos_angle) * 0.5;
        const hit_ndc = projectPoint(frame, hit.point.coeffsArray()).?;
        const sample_ndc = [2]f32{ disc_uv[0], -disc_uv[1] };
        if (expected != actual_object) {
            result.object_mismatches += 1;
            if (result.first_mismatch == null) result.first_mismatch = .{ .x = x, .y = y, .expected = expected, .actual = actual_object, .expected_depth = expected_depth, .actual_depth = actual.depth, .mesh_covers = meshCoversPoint(triangles, frame, hit.point.coeffsArray()), .mesh_strict_covers = meshStrictCoversPoint(triangles, frame, hit.point.coeffsArray()), .cover_status = meshCoverStatus(triangles, frame, hit.point.coeffsArray()), .hit_ndc = .{ hit_ndc[0], hit_ndc[1] }, .sample_ndc = sample_ndc };
        } else if (expected != null and @abs(expected_depth - actual.depth) > 1e-3) {
            result.depth_mismatches += 1;
            if (result.first_mismatch == null) result.first_mismatch = .{ .x = x, .y = y, .expected = expected, .actual = actual_object, .expected_depth = expected_depth, .actual_depth = actual.depth, .mesh_covers = meshCoversPoint(triangles, frame, hit.point.coeffsArray()), .mesh_strict_covers = meshStrictCoversPoint(triangles, frame, hit.point.coeffsArray()), .cover_status = meshCoverStatus(triangles, frame, hit.point.coeffsArray()), .hit_ndc = .{ hit_ndc[0], hit_ndc[1] }, .sample_ndc = sample_ndc };
        }
    }
    return result;
}

fn meshSelfCheck(triangles: []const MeshTriangle, compare: bool) !void {
    const poses = [_]spherical_scene.Scene{
        spherical_scene.Scene.init(),
        blk: {
            var scene = spherical_scene.Scene.init();
            scene.walkForward(1.0);
            scene.yaw(0.35);
            break :blk scene;
        },
        blk: {
            var scene = spherical_scene.Scene.init();
            scene.walkForward(4.0);
            scene.pitch(-0.35);
            break :blk scene;
        },
    };
    var expected_objects: usize = 0;
    var covered_objects: usize = 0;
    var samples: usize = 0;
    for (poses) |scene| {
        const frame = frameForScene(scene, 96.0, 64.0);
        const tracer = scene.tracer();
        var y: usize = 0;
        while (y < 6) : (y += 1) {
            var x: usize = 0;
            while (x < 8) : (x += 1) {
                const pixel = [2]f32{ @floatFromInt(x * 2 + 1), @floatFromInt(y * 2 + 1) };
                const uv = [2]f32{
                    (pixel[0] / frame.width * 2.0 - 1.0) * frame.width / frame.height / (1280.0 / 720.0),
                    (1.0 - pixel[1] / frame.height) * 2.0 - 1.0,
                };
                if (uv[0] * uv[0] + uv[1] * uv[1] > 1.0) continue;
                const r = @sqrt(uv[0] * uv[0] + uv[1] * uv[1]);
                const t = r * frame.tan_half_fov;
                const inverse = 1.0 / (1.0 + t * t);
                const sin_theta = 2.0 * t * inverse;
                const cos_theta = (1.0 - t * t) * inverse;
                const dir = normalize4(.{
                    frame.forward[0] * cos_theta + (frame.right[0] * uv[0] + frame.up[0] * uv[1]) * sin_theta / @max(r, 1e-6),
                    frame.forward[1] * cos_theta + (frame.right[1] * uv[0] + frame.up[1] * uv[1]) * sin_theta / @max(r, 1e-6),
                    frame.forward[2] * cos_theta + (frame.right[2] * uv[0] + frame.up[2] * uv[1]) * sin_theta / @max(r, 1e-6),
                    frame.forward[3] * cos_theta + (frame.right[3] * uv[0] + frame.up[3] * uv[1]) * sin_theta / @max(r, 1e-6),
                }) orelse continue;
                const hit = tracer.trace(spherical_scene.Direction.init(dir));
                const object_hit = switch (hit.surface) {
                    .ground => false,
                    .fence, .cube => true,
                };
                if (object_hit) {
                    expected_objects += 1;
                    if (meshCoversPoint(triangles, frame, hit.point.coeffsArray())) covered_objects += 1;
                }
                samples += 1;
            }
        }
    }
    const frame = frameForScene(spherical_scene.Scene.init(), 960.0, 640.0);
    const tracer = spherical_scene.Scene.init().tracer();
    const dir = frameDirection(frame, .{ 0.0, 0.0 });
    const hit = tracer.trace(spherical_scene.Direction.init(dir));
    const projected = projectPoint(frame, hit.point.coeffsArray()).?;
    var nearest_depth: f32 = 1.0;
    var nearest_color: ?[4]f32 = null;
    var strict_hits: usize = 0;
    var strict_valid_hits: usize = 0;
    for (triangles) |triangle| {
        const a = projectPoint(frame, triangle.points[0]) orelse continue;
        const b = projectPoint(frame, triangle.points[1]) orelse continue;
        const c_ = projectPoint(frame, triangle.points[2]) orelse continue;
        if (!triangleContains(projected, .{ a, b, c_ })) continue;
        if (triangleContainsStrict(projected, .{ a, b, c_ })) {
            strict_hits += 1;
            const plane_a = dot4(frame.origin, triangle.plane);
            const plane_b = dot4(dir, triangle.plane);
            if (plane_a * plane_a + plane_b * plane_b >= 1e-10) strict_valid_hits += 1;
        }
        const depth = planeDepth(frame, dir, triangle.plane);
        if (depth < nearest_depth) {
            nearest_depth = depth;
            nearest_color = triangle.color;
        }
    }
    std.debug.print("mesh self-check: {d}/{d} object hits covered across {d} samples; center cpu={d:.6} mesh={d:.6} ground={d:.6} strict={d}/{d} color={any}\n", .{ covered_objects, expected_objects, samples, (1.0 - hit.cos_angle) * 0.5, nearest_depth, planeDepth(frame, dir, .{ 0.0, 0.0, 1.0, 0.0 }), strict_valid_hits, strict_hits, nearest_color });
    if (compare) {
        for (poses, 0..) |pose, i| {
            const comparison = try rasterCompare(triangles, pose);
            std.debug.print("mesh raster compare pose {d}: {d} pixels, object mismatches={d}, depth mismatches={d}, first={any}\n", .{ i, comparison.pixels, comparison.object_mismatches, comparison.depth_mismatches, comparison.first_mismatch });
        }
    }
}

const QueueFamilyIndices = struct {
    graphics: ?u32 = null,
    present: ?u32 = null,

    fn complete(self: QueueFamilyIndices) bool {
        return self.graphics != null and self.present != null;
    }
};

const SwapchainSupport = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    present_modes: []c.VkPresentModeKHR,

    fn deinit(self: SwapchainSupport, allocator: std.mem.Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }
};

const PipelineBundle = struct {
    layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    world: spherical_scene.Scene,
    object_block: ObjectGpuBlock,
    object_count: u32,
    mesh_triangles: []MeshTriangle,
    projected_vertices: []Vertex,
    mesh_vertex_count: u32 = 0,
    window: ?*c.GLFWwindow = null,

    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    queue_families: QueueFamilyIndices = .{},

    swapchain: c.VkSwapchainKHR = null,
    swapchain_images: []c.VkImage = &.{},
    swapchain_image_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    swapchain_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    swapchain_image_views: []c.VkImageView = &.{},
    framebuffers: []c.VkFramebuffer = &.{},
    depth_image: c.VkImage = null,
    depth_image_memory: c.VkDeviceMemory = null,
    depth_image_view: c.VkImageView = null,

    render_pass: c.VkRenderPass = null,
    pipeline_layout: c.VkPipelineLayout = null,
    graphics_pipeline: c.VkPipeline = null,
    mesh_pipeline_layout: c.VkPipelineLayout = null,
    mesh_pipeline: c.VkPipeline = null,

    command_pool: c.VkCommandPool = null,
    command_buffers: []c.VkCommandBuffer = &.{},

    vertex_buffer: c.VkBuffer = null,
    vertex_buffer_memory: c.VkDeviceMemory = null,
    object_buffer: c.VkBuffer = null,
    object_buffer_memory: c.VkDeviceMemory = null,
    object_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    object_descriptor_pool: c.VkDescriptorPool = null,
    object_descriptor_set: c.VkDescriptorSet = null,

    image_available: [max_frames_in_flight]c.VkSemaphore = [_]c.VkSemaphore{null} ** max_frames_in_flight,
    render_finished: [max_frames_in_flight]c.VkSemaphore = [_]c.VkSemaphore{null} ** max_frames_in_flight,
    in_flight: [max_frames_in_flight]c.VkFence = [_]c.VkFence{null} ** max_frames_in_flight,
    current_frame: usize = 0,

    framebuffer_resized: bool = false,
    vert_path: []const u8 = default_vert_path,
    frag_path: []const u8 = default_frag_path,
    mesh_vert_path: ?[]const u8 = null,
    mesh_frag_path: ?[]const u8 = null,
    benchmark_frames: u32 = 0,
    rendered_frames: u32 = 0,
    benchmark_started_at: f64 = 0.0,
    vert_mtime: i128 = 0,
    frag_mtime: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, vert_path: []const u8, frag_path: []const u8, mesh_vert_path: ?[]const u8, mesh_frag_path: ?[]const u8, benchmark_frames: u32, world: spherical_scene.Scene, compare: bool) !App {
        const object_text = try std.Io.Dir.cwd().readFileAlloc(io, default_object_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(object_text);
        const parsed = try object_scene.parse(allocator, object_text);
        defer parsed.deinit();
        var object_block: ObjectGpuBlock = undefined;
        @memset(std.mem.asBytes(&object_block), 0);
        try fillObjectBlock(&object_block, parsed.value);
        const mesh_triangles = try buildMeshTriangles(allocator, parsed.value);
        const projected_vertices = allocator.alloc(Vertex, mesh_triangles.len * 3) catch |err| {
            allocator.free(mesh_triangles);
            return err;
        };
        try meshSelfCheck(mesh_triangles, compare);

        var app = App{
            .allocator = allocator,
            .io = io,
            .world = world,
            .object_block = object_block,
            .object_count = @intCast(parsed.value.objects.len),
            .mesh_triangles = mesh_triangles,
            .projected_vertices = projected_vertices,
            .vert_path = vert_path,
            .frag_path = frag_path,
            .mesh_vert_path = mesh_vert_path,
            .mesh_frag_path = mesh_frag_path,
            .benchmark_frames = benchmark_frames,
        };
        errdefer app.deinit();

        try app.initWindow();
        try app.initVulkan();
        app.vert_mtime = fileMtime(app.io, vert_path) catch 0;
        app.frag_mtime = fileMtime(app.io, frag_path) catch 0;
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.device != null) _ = c.vkDeviceWaitIdle(self.device);

        self.cleanupSwapchain();

        if (self.vertex_buffer != null) c.vkDestroyBuffer(self.device, self.vertex_buffer, null);
        if (self.vertex_buffer_memory != null) c.vkFreeMemory(self.device, self.vertex_buffer_memory, null);
        self.allocator.free(self.mesh_triangles);
        self.allocator.free(self.projected_vertices);
        if (self.object_buffer != null) c.vkDestroyBuffer(self.device, self.object_buffer, null);
        if (self.object_buffer_memory != null) c.vkFreeMemory(self.device, self.object_buffer_memory, null);
        if (self.object_descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.object_descriptor_pool, null);
        if (self.object_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.object_descriptor_set_layout, null);

        for (0..max_frames_in_flight) |i| {
            if (self.image_available[i] != null) c.vkDestroySemaphore(self.device, self.image_available[i], null);
            if (self.render_finished[i] != null) c.vkDestroySemaphore(self.device, self.render_finished[i], null);
            if (self.in_flight[i] != null) c.vkDestroyFence(self.device, self.in_flight[i], null);
        }

        if (self.command_pool != null) c.vkDestroyCommandPool(self.device, self.command_pool, null);
        if (self.device != null) c.vkDestroyDevice(self.device, null);
        if (self.surface != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        if (self.window) |window| c.glfwDestroyWindow(window);
        c.glfwTerminate();
    }

    pub fn run(self: *App) !void {
        std.debug.print("shader playground\n", .{});
        std.debug.print("  vertex:   {s}\n", .{self.vert_path});
        std.debug.print("  fragment: {s}\n", .{self.frag_path});
        std.debug.print("  mesh triangles: {d}, projected vertices: {d}\n", .{ self.mesh_triangles.len, self.projected_vertices.len });
        std.debug.print("  controls: W/S walk, A/D strafe, arrows look, R reset, Esc quit\n", .{});
        std.debug.print("Run this in another terminal for live SPIR-V rebuilds:\n", .{});
        std.debug.print("  zig build --watch spirv-raw     # driver-valid raw baseline\n", .{});
        std.debug.print("  zig build --watch spirv-vga     # GA shaders, currently useful for compiler/driver debugging\n\n", .{});

        var dirty = true;
        self.benchmark_started_at = c.glfwGetTime();
        var previous_time = self.benchmark_started_at;
        while (c.glfwWindowShouldClose(self.window) == c.GLFW_FALSE) {
            if (self.benchmark_frames == 0) c.glfwWaitEventsTimeout(1.0 / 60.0) else c.glfwPollEvents();
            const now = c.glfwGetTime();
            const delta_time: f32 = @floatCast(@min(now - previous_time, 0.1));
            previous_time = now;

            if (self.benchmark_frames > 0) dirty = true;
            if (self.framebuffer_resized) dirty = true;
            if (try self.reloadShadersIfChanged()) dirty = true;
            if (try self.updateInput(delta_time)) {
                try vkCheck(c.vkDeviceWaitIdle(self.device));
                try self.recreateCommandBuffers();
                dirty = true;
            }
            if (dirty) {
                try self.drawFrame();
                self.rendered_frames += 1;
                dirty = false;
                if (self.benchmark_frames > 0 and self.rendered_frames >= self.benchmark_frames) {
                    try vkCheck(c.vkDeviceWaitIdle(self.device));
                    const elapsed = c.glfwGetTime() - self.benchmark_started_at;
                    std.debug.print("benchmark: {d} frames, {d:.3}s, {d:.1} fps\n", .{ self.rendered_frames, elapsed, @as(f64, @floatFromInt(self.rendered_frames)) / @max(elapsed, 0.000001) });
                    c.glfwSetWindowShouldClose(self.window, c.GLFW_TRUE);
                }
            }
        }
        try vkCheck(c.vkDeviceWaitIdle(self.device));
    }

    fn updateInput(self: *App, delta_time: f32) !bool {
        if (self.keyDown(c.GLFW_KEY_ESCAPE)) {
            c.glfwSetWindowShouldClose(self.window, c.GLFW_TRUE);
            return false;
        }

        const speed_scale = spherical_scene.Scene.speedScaleForGap(self.world.conjugateGap());
        const move = 2.2 * speed_scale * delta_time;
        const turn = 1.35 * delta_time;
        var changed = false;
        if (self.keyDown(c.GLFW_KEY_W)) {
            self.world.walkForward(move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_S)) {
            self.world.walkForward(-move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_D)) {
            self.world.strafeRight(move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_A)) {
            self.world.strafeRight(-move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_RIGHT)) {
            self.world.yaw(-turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_LEFT)) {
            self.world.yaw(turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_UP)) {
            self.world.pitch(-turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_DOWN)) {
            self.world.pitch(turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_R)) {
            self.world = spherical_scene.Scene.init();
            changed = true;
        }
        return changed;
    }

    fn keyDown(self: *App, key: c_int) bool {
        return c.glfwGetKey(self.window, key) == c.GLFW_PRESS;
    }

    fn initWindow(self: *App) !void {
        if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
        if (c.glfwVulkanSupported() != c.GLFW_TRUE) return error.GlfwVulkanUnavailable;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
        self.window = c.glfwCreateWindow(window_width, window_height, "zmath SPIR-V playground", null, null) orelse return error.GlfwCreateWindowFailed;
        c.glfwSetWindowUserPointer(self.window, self);
        _ = c.glfwSetFramebufferSizeCallback(self.window, framebufferResizeCallback);
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createObjectResources();
        try self.createSwapchain();
        try self.createImageViews();
        try self.createRenderPass();
        try self.createDepthResources();
        const bundle = try self.createGraphicsPipeline();
        self.pipeline_layout = bundle.layout;
        self.graphics_pipeline = bundle.pipeline;
        if (self.mesh_vert_path != null and self.mesh_frag_path != null) {
            const mesh_bundle = try self.createMeshPipeline();
            self.mesh_pipeline_layout = mesh_bundle.layout;
            self.mesh_pipeline = mesh_bundle.pipeline;
        }
        try self.createFramebuffers();
        try self.createCommandPool();
        try self.createVertexBuffer();
        try self.createCommandBuffers();
        try self.createSyncObjects();
    }

    fn createInstance(self: *App) !void {
        var glfw_extension_count: u32 = 0;
        const glfw_extensions_ptr = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count) orelse return error.GlfwVulkanUnavailable;

        const app_name = "zmath shader playground";
        const engine_name = "zmath";
        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = app_name,
            .applicationVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = engine_name,
            .engineVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = c.VK_API_VERSION_1_0,
        };

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = glfw_extension_count,
            .ppEnabledExtensionNames = glfw_extensions_ptr,
        };

        try vkCheck(c.vkCreateInstance(&create_info, null, &self.instance));
    }

    fn createSurface(self: *App) !void {
        try vkCheck(c.glfwCreateWindowSurface(self.instance, self.window, null, &self.surface));
    }

    fn pickPhysicalDevice(self: *App) !void {
        var device_count: u32 = 0;
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &device_count, null));
        if (device_count == 0) return error.NoVulkanDevices;

        const devices = try self.allocator.alloc(c.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr));

        for (devices) |device| {
            if (try self.isDeviceSuitable(device)) {
                self.physical_device = device;
                self.queue_families = try self.findQueueFamilies(device);
                return;
            }
        }
        return error.NoSuitableVulkanDevice;
    }

    fn isDeviceSuitable(self: *App, device: c.VkPhysicalDevice) !bool {
        const indices = try self.findQueueFamilies(device);
        if (!indices.complete()) return false;
        if (!try self.checkDeviceExtensionSupport(device)) return false;

        const support = try self.querySwapchainSupport(device);
        defer support.deinit(self.allocator);
        return support.formats.len > 0 and support.present_modes.len > 0;
    }

    fn checkDeviceExtensionSupport(self: *App, device: c.VkPhysicalDevice) !bool {
        var extension_count: u32 = 0;
        try vkCheck(c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null));
        const extensions = try self.allocator.alloc(c.VkExtensionProperties, extension_count);
        defer self.allocator.free(extensions);
        try vkCheck(c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, extensions.ptr));

        for (extensions) |extension| {
            const name = std.mem.sliceTo(&extension.extensionName, 0);
            if (std.mem.eql(u8, name, "VK_KHR_swapchain")) return true;
        }
        return false;
    }

    fn findQueueFamilies(self: *App, device: c.VkPhysicalDevice) !QueueFamilyIndices {
        var indices = QueueFamilyIndices{};
        var queue_family_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
        const families = try self.allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
        defer self.allocator.free(families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, families.ptr);

        for (families, 0..) |family, i| {
            const index: u32 = @intCast(i);
            if ((family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) indices.graphics = index;

            var present_support: c.VkBool32 = c.VK_FALSE;
            try vkCheck(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, index, self.surface, &present_support));
            if (present_support == c.VK_TRUE) indices.present = index;

            if (indices.complete()) break;
        }
        return indices;
    }

    fn createLogicalDevice(self: *App) !void {
        const graphics_family = self.queue_families.graphics.?;
        const present_family = self.queue_families.present.?;
        const queue_priority: f32 = 1.0;

        var queue_create_infos: [2]c.VkDeviceQueueCreateInfo = undefined;
        var queue_create_info_count: u32 = 0;

        queue_create_infos[queue_create_info_count] = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        queue_create_info_count += 1;

        if (present_family != graphics_family) {
            queue_create_infos[queue_create_info_count] = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = present_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_create_info_count += 1;
        }

        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        const device_features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        const create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = queue_create_info_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
            .pEnabledFeatures = &device_features,
        };

        try vkCheck(c.vkCreateDevice(self.physical_device, &create_info, null, &self.device));
        c.vkGetDeviceQueue(self.device, graphics_family, 0, &self.graphics_queue);
        c.vkGetDeviceQueue(self.device, present_family, 0, &self.present_queue);
    }

    fn querySwapchainSupport(self: *App, device: c.VkPhysicalDevice) !SwapchainSupport {
        var support: SwapchainSupport = undefined;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.surface, &support.capabilities));

        var format_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &format_count, null));
        support.formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        errdefer self.allocator.free(support.formats);
        if (format_count > 0) try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &format_count, support.formats.ptr));

        var present_mode_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &present_mode_count, null));
        support.present_modes = try self.allocator.alloc(c.VkPresentModeKHR, present_mode_count);
        errdefer self.allocator.free(support.present_modes);
        if (present_mode_count > 0) try vkCheck(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &present_mode_count, support.present_modes.ptr));

        return support;
    }

    fn createObjectResources(self: *App) !void {
        const binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };
        const layout_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 1,
            .pBindings = &binding,
        };
        try vkCheck(c.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.object_descriptor_set_layout));

        try self.createBuffer(
            @sizeOf(ObjectGpuBlock),
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.object_buffer,
            &self.object_buffer_memory,
        );
        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.object_buffer_memory, 0, @sizeOf(ObjectGpuBlock), 0, &mapped));
        const bytes = std.mem.asBytes(&self.object_block);
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..bytes.len], bytes);
        c.vkUnmapMemory(self.device, self.object_buffer_memory);

        const pool_size = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
        };
        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        try vkCheck(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.object_descriptor_pool));

        const allocate_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.object_descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.object_descriptor_set_layout,
        };
        try vkCheck(c.vkAllocateDescriptorSets(self.device, &allocate_info, &self.object_descriptor_set));

        const buffer_info = c.VkDescriptorBufferInfo{
            .buffer = self.object_buffer,
            .offset = 0,
            .range = @sizeOf(ObjectGpuBlock),
        };
        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.object_descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_info,
            .pTexelBufferView = null,
        };
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    fn createSwapchain(self: *App) !void {
        const support = try self.querySwapchainSupport(self.physical_device);
        defer support.deinit(self.allocator);

        const surface_format = chooseSwapSurfaceFormat(support.formats);
        const present_mode = chooseSwapPresentMode(support.present_modes);
        const extent = chooseSwapExtent(self.window, support.capabilities);

        var image_count = support.capabilities.minImageCount + 1;
        if (support.capabilities.maxImageCount > 0 and image_count > support.capabilities.maxImageCount) {
            image_count = support.capabilities.maxImageCount;
        }

        const queue_family_indices = [_]u32{ self.queue_families.graphics.?, self.queue_families.present.? };
        const sharing_mode: c.VkSharingMode = if (queue_family_indices[0] != queue_family_indices[1]) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE;
        const queue_family_index_count: u32 = if (sharing_mode == c.VK_SHARING_MODE_CONCURRENT) 2 else 0;
        const queue_family_index_ptr: [*c]const u32 = if (sharing_mode == c.VK_SHARING_MODE_CONCURRENT) queue_family_indices[0..].ptr else null;

        const create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = sharing_mode,
            .queueFamilyIndexCount = queue_family_index_count,
            .pQueueFamilyIndices = queue_family_index_ptr,
            .preTransform = support.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        try vkCheck(c.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain));

        var actual_image_count: u32 = 0;
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, null));
        self.swapchain_images = try self.allocator.alloc(c.VkImage, actual_image_count);
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, self.swapchain_images.ptr));

        self.swapchain_image_format = surface_format.format;
        self.swapchain_extent = extent;
    }

    fn createImageViews(self: *App) !void {
        self.swapchain_image_views = try self.allocator.alloc(c.VkImageView, self.swapchain_images.len);
        errdefer self.allocator.free(self.swapchain_image_views);

        for (self.swapchain_images, 0..) |image, i| {
            const create_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_image_format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            try vkCheck(c.vkCreateImageView(self.device, &create_info, null, &self.swapchain_image_views[i]));
        }
    }

    fn createRenderPass(self: *App) !void {
        const color_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_image_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const depth_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = c.VK_FORMAT_D32_SFLOAT,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
        const color_attachment_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const depth_attachment_ref = c.VkAttachmentReference{
            .attachment = 1,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = &depth_attachment_ref,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const attachments = [_]c.VkAttachmentDescription{ color_attachment, depth_attachment };
        const render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 2,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };
        try vkCheck(c.vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass));
    }

    fn createGraphicsPipeline(self: *App) !PipelineBundle {
        return self.createPipeline(self.vert_path, self.frag_path, false);
    }

    fn createMeshPipeline(self: *App) !PipelineBundle {
        return self.createPipeline(self.mesh_vert_path.?, self.mesh_frag_path.?, true);
    }

    fn createPipeline(self: *App, vert_path: []const u8, frag_path: []const u8, mesh: bool) !PipelineBundle {
        const vert_words = try readSpirvWords(self.allocator, self.io, vert_path);
        defer self.allocator.free(vert_words);
        const frag_words = try readSpirvWords(self.allocator, self.io, frag_path);
        defer self.allocator.free(frag_words);

        const vert_module = try self.createShaderModule(vert_words);
        defer c.vkDestroyShaderModule(self.device, vert_module, null);
        const frag_module = try self.createShaderModule(frag_words);
        defer c.vkDestroyShaderModule(self.device, frag_module, null);

        const main_name = "main";
        const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = main_name,
                .pSpecializationInfo = null,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = main_name,
                .pSpecializationInfo = null,
            },
        };

        const vertex_binding = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };
        const vertex_attributes = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "color") },
            .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "plane") },
        };
        const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = if (mesh) 1 else 0,
            .pVertexBindingDescriptions = if (mesh) &vertex_binding else null,
            .vertexAttributeDescriptionCount = if (mesh) 3 else 0,
            .pVertexAttributeDescriptions = if (mesh) &vertex_attributes else null,
        };
        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };
        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
        };
        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };
        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };
        const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const color_blending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        var pipeline_layout: c.VkPipelineLayout = null;
        const push_constant_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(SphericalFrame),
        };
        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.object_descriptor_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_range,
        };
        try vkCheck(c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(self.device, pipeline_layout, null);

        const depth_stencil = c.VkPipelineDepthStencilStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = c.VK_TRUE,
            .depthCompareOp = if (mesh) c.VK_COMPARE_OP_LESS else c.VK_COMPARE_OP_ALWAYS,
            .depthBoundsTestEnable = c.VK_FALSE,
            .stencilTestEnable = c.VK_FALSE,
            .front = std.mem.zeroes(c.VkStencilOpState),
            .back = std.mem.zeroes(c.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };
        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = null,
            .layout = pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        var pipeline: c.VkPipeline = null;
        try vkCheck(c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &pipeline));
        errdefer c.vkDestroyPipeline(self.device, pipeline, null);

        return .{ .layout = pipeline_layout, .pipeline = pipeline };
    }

    fn createShaderModule(self: *App, words: []const u32) !c.VkShaderModule {
        const create_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = words.len * @sizeOf(u32),
            .pCode = words.ptr,
        };
        var shader_module: c.VkShaderModule = null;
        try vkCheck(c.vkCreateShaderModule(self.device, &create_info, null, &shader_module));
        return shader_module;
    }

    fn createDepthResources(self: *App) !void {
        const image_info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = c.VK_FORMAT_D32_SFLOAT,
            .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try vkCheck(c.vkCreateImage(self.device, &image_info, null, &self.depth_image));
        errdefer c.vkDestroyImage(self.device, self.depth_image, null);

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.depth_image, &requirements);
        const allocation = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };
        try vkCheck(c.vkAllocateMemory(self.device, &allocation, null, &self.depth_image_memory));
        errdefer c.vkFreeMemory(self.device, self.depth_image_memory, null);
        try vkCheck(c.vkBindImageMemory(self.device, self.depth_image, self.depth_image_memory, 0));

        const view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.depth_image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_D32_SFLOAT,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        try vkCheck(c.vkCreateImageView(self.device, &view_info, null, &self.depth_image_view));
    }

    fn createFramebuffers(self: *App) !void {
        self.framebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len);
        errdefer self.allocator.free(self.framebuffers);

        for (self.swapchain_image_views, 0..) |image_view, i| {
            const attachments = [_]c.VkImageView{ image_view, self.depth_image_view };
            const framebuffer_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = 2,
                .pAttachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };
            try vkCheck(c.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]));
        }
    }

    fn createCommandPool(self: *App) !void {
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_families.graphics.?,
        };
        try vkCheck(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
    }

    fn createVertexBuffer(self: *App) !void {
        const buffer_size: c.VkDeviceSize = @intCast(self.projected_vertices.len * @sizeOf(Vertex));
        try self.createBuffer(
            buffer_size,
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );

        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.vertex_buffer_memory, 0, buffer_size, 0, &mapped));
        c.vkUnmapMemory(self.device, self.vertex_buffer_memory);
    }

    fn createBuffer(self: *App, size: c.VkDeviceSize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags, buffer: *c.VkBuffer, memory: *c.VkDeviceMemory) !void {
        const buffer_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        try vkCheck(c.vkCreateBuffer(self.device, &buffer_info, null, buffer));
        errdefer c.vkDestroyBuffer(self.device, buffer.*, null);

        var mem_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buffer.*, &mem_requirements);
        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = try self.findMemoryType(mem_requirements.memoryTypeBits, properties),
        };
        try vkCheck(c.vkAllocateMemory(self.device, &alloc_info, null, memory));
        errdefer c.vkFreeMemory(self.device, memory.*, null);
        try vkCheck(c.vkBindBufferMemory(self.device, buffer.*, memory.*, 0));
    }

    fn findMemoryType(self: *App, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
        var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);
        for (0..mem_properties.memoryTypeCount) |i_usize| {
            const i: u5 = @intCast(i_usize);
            if ((type_filter & (@as(u32, 1) << i)) != 0 and (mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
                return @intCast(i_usize);
            }
        }
        return error.NoSuitableMemoryType;
    }

    fn createCommandBuffers(self: *App) !void {
        self.command_buffers = try self.allocator.alloc(c.VkCommandBuffer, self.framebuffers.len);
        errdefer self.allocator.free(self.command_buffers);

        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(self.command_buffers.len),
        };
        try vkCheck(c.vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr));
        try self.recordCommandBuffers();
    }

    fn currentFrame(self: *App) SphericalFrame {
        const tracer = self.world.tracer();
        const camera = self.world.frameCamera();
        return .{
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .radius = tracer.radius,
            .tan_half_fov = camera.tan_half_fov,
            .ground_a = tracer.ground_a,
            .object_count = @floatFromInt(self.object_count),
            .origin = tracer.origin.coeffsArray(),
            .right = tracer.right.coeffsArray(),
            .up = tracer.up.coeffsArray(),
            .forward = tracer.forward.coeffsArray(),
        };
    }

    fn updateProjectedMesh(self: *App, frame: SphericalFrame) !void {
        var vertex_count: usize = 0;

        for (self.mesh_triangles) |triangle| {
            var projected: [3]Vertex = undefined;
            var valid = true;
            for (triangle.points, 0..) |point, i| {
                const pos = projectPoint(frame, point) orelse {
                    valid = false;
                    break;
                };
                // The stereographic chart is singular at the antipode. Letting
                // Vulkan clip a triangle with a near-singular vertex creates a
                // giant screen-spanning primitive that is no longer the
                // spherical triangle. Drop it until chart-boundary clipping
                // is implemented.
                if (@abs(pos[0]) > 4.0 or @abs(pos[1]) > 4.0) {
                    valid = false;
                    break;
                }
                projected[i] = .{ .pos = pos, .color = triangle.color, .plane = triangle.plane };
            }
            if (valid) {
                inline for (0..3) |i| {
                    const next = (i + 1) % 3;
                    const dx = projected[i].pos[0] - projected[next].pos[0];
                    const dy = projected[i].pos[1] - projected[next].pos[1];
                    if (dx * dx + dy * dy > 4.0) valid = false;
                }
            }
            if (!valid) continue;
            const center = [2]f32{
                (projected[0].pos[0] + projected[1].pos[0] + projected[2].pos[0]) / 3.0,
                (projected[0].pos[1] + projected[1].pos[1] + projected[2].pos[1]) / 3.0,
            };
            for (&projected) |*vertex| {
                const dx = (vertex.pos[0] - center[0]) * frame.width * 0.5;
                const dy = (vertex.pos[1] - center[1]) * frame.height * 0.5;
                const length = @sqrt(dx * dx + dy * dy);
                if (length == 0.0) continue;
                vertex.pos[0] += dx / length * (2.0 * raster_margin_pixels / frame.width);
                vertex.pos[1] += dy / length * (2.0 * raster_margin_pixels / frame.height);
            }
            self.projected_vertices[vertex_count + 0] = projected[0];
            self.projected_vertices[vertex_count + 1] = projected[1];
            self.projected_vertices[vertex_count + 2] = projected[2];
            vertex_count += 3;
        }
        self.mesh_vertex_count = @intCast(vertex_count);

        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.vertex_buffer_memory, 0, @intCast(self.projected_vertices.len * @sizeOf(Vertex)), 0, &mapped));
        const bytes = std.mem.sliceAsBytes(self.projected_vertices[0..vertex_count]);
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..bytes.len], bytes);
        c.vkUnmapMemory(self.device, self.vertex_buffer_memory);
    }

    fn recordCommandBuffers(self: *App) !void {
        const frame = self.currentFrame();
        try self.updateProjectedMesh(frame);
        for (self.command_buffers, 0..) |command_buffer, i| {
            const begin_info = c.VkCommandBufferBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = 0,
                .pInheritanceInfo = null,
            };
            try vkCheck(c.vkBeginCommandBuffer(command_buffer, &begin_info));

            const clear_values = [_]c.VkClearValue{
                .{ .color = .{ .float32 = .{ 0.025, 0.025, 0.035, 1.0 } } },
                .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
            };
            const render_pass_info = c.VkRenderPassBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext = null,
                .renderPass = self.render_pass,
                .framebuffer = self.framebuffers[i],
                .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
                .clearValueCount = 2,
                .pClearValues = &clear_values,
            };
            c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
            c.vkCmdBindDescriptorSets(
                command_buffer,
                c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                self.pipeline_layout,
                0,
                1,
                &self.object_descriptor_set,
                0,
                null,
            );
            c.vkCmdPushConstants(
                command_buffer,
                self.pipeline_layout,
                c.VK_SHADER_STAGE_FRAGMENT_BIT,
                0,
                @sizeOf(SphericalFrame),
                @ptrCast(&frame),
            );
            c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
            if (self.mesh_pipeline != null and self.mesh_vertex_count > 0) {
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.mesh_pipeline);
                c.vkCmdPushConstants(
                    command_buffer,
                    self.mesh_pipeline_layout,
                    c.VK_SHADER_STAGE_FRAGMENT_BIT,
                    0,
                    @sizeOf(SphericalFrame),
                    @ptrCast(&frame),
                );
                const offsets = [_]c.VkDeviceSize{0};
                c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &self.vertex_buffer, &offsets);
                c.vkCmdDraw(command_buffer, self.mesh_vertex_count, 1, 0, 0);
            }
            c.vkCmdEndRenderPass(command_buffer);
            try vkCheck(c.vkEndCommandBuffer(command_buffer));
        }
    }

    fn recreateCommandBuffers(self: *App) !void {
        if (self.command_buffers.len > 0) {
            c.vkFreeCommandBuffers(self.device, self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        try self.createCommandBuffers();
    }

    fn createSyncObjects(self: *App) !void {
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        for (0..max_frames_in_flight) |i| {
            try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available[i]));
            try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished[i]));
            try vkCheck(c.vkCreateFence(self.device, &fence_info, null, &self.in_flight[i]));
        }
    }

    fn drawFrame(self: *App) !void {
        try vkCheck(c.vkWaitForFences(self.device, 1, &self.in_flight[self.current_frame], c.VK_TRUE, std.math.maxInt(u64)));

        var image_index: u32 = 0;
        const acquire_result = c.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available[self.current_frame], null, &image_index);
        if (acquire_result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return;
        }
        try vkCheckAllowSuboptimal(acquire_result);

        try vkCheck(c.vkResetFences(self.device, 1, &self.in_flight[self.current_frame]));

        const wait_semaphores = [_]c.VkSemaphore{self.image_available[self.current_frame]};
        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]c.VkSemaphore{self.render_finished[self.current_frame]};
        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[image_index],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };
        try vkCheck(c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight[self.current_frame]));

        const swapchains = [_]c.VkSwapchainKHR{self.swapchain};
        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        const present_result = c.vkQueuePresentKHR(self.present_queue, &present_info);
        if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreateSwapchain();
        } else {
            try vkCheck(present_result);
        }

        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
    }

    fn reloadShadersIfChanged(self: *App) !bool {
        const new_vert_mtime = fileMtime(self.io, self.vert_path) catch return false;
        const new_frag_mtime = fileMtime(self.io, self.frag_path) catch return false;
        if (new_vert_mtime == self.vert_mtime and new_frag_mtime == self.frag_mtime) return false;

        std.debug.print("detected shader update; reloading...\n", .{});
        try vkCheck(c.vkDeviceWaitIdle(self.device));

        const new_bundle = self.createGraphicsPipeline() catch |err| {
            std.debug.print("shader reload failed: {s}; keeping previous pipeline\n", .{@errorName(err)});
            return false;
        };

        c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.graphics_pipeline = new_bundle.pipeline;
        self.pipeline_layout = new_bundle.layout;
        try self.recreateCommandBuffers();
        self.vert_mtime = new_vert_mtime;
        self.frag_mtime = new_frag_mtime;
        std.debug.print("shader reload ok\n", .{});
        return true;
    }

    fn recreateSwapchain(self: *App) !void {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(self.window, &width, &height);
        while (width == 0 or height == 0) {
            c.glfwWaitEvents();
            c.glfwGetFramebufferSize(self.window, &width, &height);
        }

        try vkCheck(c.vkDeviceWaitIdle(self.device));
        self.cleanupSwapchain();
        try self.createSwapchain();
        try self.createImageViews();
        try self.createRenderPass();
        try self.createDepthResources();
        const bundle = try self.createGraphicsPipeline();
        self.pipeline_layout = bundle.layout;
        self.graphics_pipeline = bundle.pipeline;
        if (self.mesh_vert_path != null and self.mesh_frag_path != null) {
            const mesh_bundle = try self.createMeshPipeline();
            self.mesh_pipeline_layout = mesh_bundle.layout;
            self.mesh_pipeline = mesh_bundle.pipeline;
        }
        try self.createFramebuffers();
        try self.createCommandBuffers();
    }

    fn cleanupSwapchain(self: *App) void {
        if (self.command_buffers.len > 0 and self.command_pool != null) {
            c.vkFreeCommandBuffers(self.device, self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        for (self.framebuffers) |framebuffer| c.vkDestroyFramebuffer(self.device, framebuffer, null);
        self.allocator.free(self.framebuffers);
        self.framebuffers = &.{};

        if (self.graphics_pipeline != null) c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        if (self.mesh_pipeline != null) c.vkDestroyPipeline(self.device, self.mesh_pipeline, null);
        if (self.mesh_pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.mesh_pipeline_layout, null);
        self.graphics_pipeline = null;
        self.mesh_pipeline = null;
        self.mesh_pipeline_layout = null;
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.pipeline_layout = null;
        if (self.render_pass != null) c.vkDestroyRenderPass(self.device, self.render_pass, null);
        self.render_pass = null;
        if (self.depth_image_view != null) c.vkDestroyImageView(self.device, self.depth_image_view, null);
        self.depth_image_view = null;
        if (self.depth_image != null) c.vkDestroyImage(self.device, self.depth_image, null);
        self.depth_image = null;
        if (self.depth_image_memory != null) c.vkFreeMemory(self.device, self.depth_image_memory, null);
        self.depth_image_memory = null;

        for (self.swapchain_image_views) |image_view| c.vkDestroyImageView(self.device, image_view, null);
        self.allocator.free(self.swapchain_image_views);
        self.swapchain_image_views = &.{};
        self.allocator.free(self.swapchain_images);
        self.swapchain_images = &.{};
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
    }
};

fn fillObjectBlock(block: *ObjectGpuBlock, file: object_scene.File) !void {
    try file.validateGpuCapacity(MaxObjects, MaxMaterials);
    for (file.objects, 0..) |object, object_index| {
        const base = object_index * 6;
        for (object.faces, 0..) |face, face_index| {
            const normal = object.transformNormal(face.normal);
            block.normals[base + face_index] = normal;
            block.meta[base + face_index] = .{
                if (face.positive) 1.0 else 0.0,
                file.materials[face.material].tone,
                @floatFromInt(face.material),
                0.0,
            };
        }
        if (object.bound) |bound| {
            block.bounds[object_index] = object.transformPoint(bound.center);
            block.meta[base][3] = bound.cos_radius;
        } else {
            block.meta[base][3] = -1.0;
        }
    }
    for (file.materials, 0..) |material, index| block.colors[index] = material.color;
}

fn framebufferResizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    _ = width;
    _ = height;
    const user_ptr = c.glfwGetWindowUserPointer(window);
    if (user_ptr) |ptr| {
        const app: *App = @ptrCast(@alignCast(ptr));
        app.framebuffer_resized = true;
    }
}

fn chooseSwapSurfaceFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) return format;
    }
    return formats[0];
}

fn chooseSwapPresentMode(present_modes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
    for (present_modes) |mode| {
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) return mode;
    }
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(window: ?*c.GLFWwindow, capabilities: c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) return capabilities.currentExtent;

    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(window, &width, &height);
    return .{
        .width = std.math.clamp(@as(u32, @intCast(width)), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
        .height = std.math.clamp(@as(u32, @intCast(height)), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
    };
}

fn readSpirvWords(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u32 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidSpirvSize;
    const words = try allocator.alloc(u32, bytes.len / @sizeOf(u32));
    @memcpy(std.mem.sliceAsBytes(words), bytes);
    return words;
}

fn fileMtime(io: std.Io, path: []const u8) !i128 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return stat.mtime.nanoseconds;
}

fn vkCheck(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return vkError(result);
}

fn vkCheckAllowSuboptimal(result: c.VkResult) !void {
    if (result == c.VK_SUCCESS or result == c.VK_SUBOPTIMAL_KHR) return;
    return vkError(result);
}

fn vkError(result: c.VkResult) anyerror {
    std.debug.print("Vulkan error: {d}\n", .{result});
    return error.VulkanError;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const vert_path = args.next() orelse default_vert_path;
    const frag_path = args.next() orelse default_frag_path;
    const mesh_vert_path = args.next();
    const mesh_frag_path = args.next();
    var benchmark_frames: u32 = 0;
    var world = spherical_scene.Scene.init();
    var compare = false;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--benchmark")) {
            benchmark_frames = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArgument, 10);
        } else if (std.mem.eql(u8, flag, "--compare")) {
            compare = true;
        } else if (std.mem.eql(u8, flag, "--pose")) {
            const walk = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument);
            const yaw = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument);
            const pitch = try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument);
            world.walkForward(walk);
            if (yaw != 0.0) world.yaw(yaw);
            if (pitch != 0.0) world.pitch(pitch);
        } else return error.InvalidArgument;
    }

    var app = try App.init(allocator, init.io, vert_path, frag_path, mesh_vert_path, mesh_frag_path, benchmark_frames, world, compare);
    defer app.deinit();
    try app.run();
}

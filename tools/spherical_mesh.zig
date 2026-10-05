const std = @import("std");
const object_scene = @import("object_scene");
const spherical_scene = @import("spherical_scene");

const Point = spherical_scene.Point;
const mesh_subdivision_depth = 4;

pub const Triangle = struct {
    points: [3]Point,
    color: [4]f32,
    plane: Point,
    object_index: usize,
};

const FacePoint = struct {
    point: Point,
    angle: f32,
};

fn normalizePoint(point: Point) ?Point {
    const length = @sqrt(@max(point.scalarProduct(point), 0.0));
    if (length < 1e-6) return null;
    return point.scale(1.0 / length);
}

fn nullVector(a: Point, b: Point, c: Point) ?Point {
    return normalizePoint(a.wedge(b).wedge(c).hodgeDual());
}

fn faceContains(point: Point, normals: [6]Point, faces: []const object_scene.Face) bool {
    for (faces, 0..) |face, i| {
        const side = spherical_scene.dot(point, normals[i]);
        if (if (face.positive) side < -1e-4 else side > 1e-4) return false;
    }
    return true;
}

fn appendSubdividedTriangle(
    triangles: *std.ArrayList(Triangle),
    allocator: std.mem.Allocator,
    a: Point,
    b: Point,
    c: Point,
    color: [4]f32,
    plane: Point,
    object_index: usize,
    depth: u32,
) !void {
    if (depth == 0) {
        try triangles.append(allocator, .{ .points = .{ a, b, c }, .color = color, .plane = plane, .object_index = object_index });
        return;
    }
    const ab = normalizePoint(a.add(b)) orelse return error.UnsupportedMeshGeometry;
    const bc = normalizePoint(b.add(c)) orelse return error.UnsupportedMeshGeometry;
    const ca = normalizePoint(c.add(a)) orelse return error.UnsupportedMeshGeometry;
    try appendSubdividedTriangle(triangles, allocator, a, ab, ca, color, plane, object_index, depth - 1);
    try appendSubdividedTriangle(triangles, allocator, ab, b, bc, color, plane, object_index, depth - 1);
    try appendSubdividedTriangle(triangles, allocator, ca, bc, c, color, plane, object_index, depth - 1);
    try appendSubdividedTriangle(triangles, allocator, ab, bc, ca, color, plane, object_index, depth - 1);
}

/// Builds vertex-bounded four- to six-face objects from a validated spherical
/// scene. Returns UnsupportedMeshGeometry rather than omit unsupported objects.
pub fn buildTriangles(allocator: std.mem.Allocator, file: object_scene.File) ![]Triangle {
    var triangles: std.ArrayList(Triangle) = .empty;
    errdefer triangles.deinit(allocator);

    for (file.objects, 0..) |object, object_index| {
        if (object.faces.len < 4 or object.faces.len > 6) return error.UnsupportedMeshGeometry;
        const first_triangle = triangles.items.len;
        var normals: [6]Point = undefined;
        for (object.faces, 0..) |face, i| normals[i] = object.transformNormal(face.normal);

        for (object.faces, 0..) |face, face_index| {
            var points: [8]FacePoint = undefined;
            var point_count: usize = 0;
            var j: usize = 0;
            while (j < object.faces.len) : (j += 1) {
                if (j == face_index) continue;
                var k = j + 1;
                while (k < object.faces.len) : (k += 1) {
                    if (k == face_index) continue;
                    const candidate = nullVector(normals[face_index], normals[j], normals[k]) orelse continue;
                    for ([_]f32{ 1.0, -1.0 }) |sign| {
                        const point = candidate.scale(sign);
                        if (!faceContains(point, normals, object.faces)) continue;
                        var duplicate = false;
                        for (points[0..point_count]) |existing| {
                            if (spherical_scene.dot(existing.point, point) > 0.9999) duplicate = true;
                        }
                        if (!duplicate) {
                            if (point_count == points.len) return error.UnsupportedMeshGeometry;
                            points[point_count] = .{ .point = point, .angle = 0.0 };
                            point_count += 1;
                        }
                    }
                }
            }
            if (point_count < 3) continue;

            var center_sum = Point.zero();
            for (points[0..point_count]) |point| center_sum = center_sum.add(point.point);
            const center = normalizePoint(center_sum) orelse return error.UnsupportedMeshGeometry;
            const radial = points[0].point.sub(center.scale(spherical_scene.dot(points[0].point, center)));
            const e1 = normalizePoint(radial) orelse return error.UnsupportedMeshGeometry;
            const e2 = nullVector(normals[face_index], center, e1) orelse return error.UnsupportedMeshGeometry;
            for (points[0..point_count]) |*point| {
                point.angle = std.math.atan2(spherical_scene.dot(point.point, e2), spherical_scene.dot(point.point, e1));
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
                try appendSubdividedTriangle(&triangles, allocator, center, points[i].point, points[next].point, color, normals[face_index], object_index, mesh_subdivision_depth);
            }
        }
        if (triangles.items.len == first_triangle) return error.UnsupportedMeshGeometry;
    }
    return try triangles.toOwnedSlice(allocator);
}

test "meshes bounded tetrahedra and triangular prisms" {
    const tetrahedron_source =
        \\{"version":1,"space":"spherical","radius":6,"materials":[{"name":"stone","color":[1,1,1,1]}],"objects":[{"name":"tetrahedron","kind":"halfspaces","faces":[{"normal":[0,1,0,0]},{"normal":[0,0,1,0]},{"normal":[0,0,0,1]},{"normal":[0.5,-0.5,-0.5,-0.5]}]}]}
    ;
    const prism_source =
        \\{"version":1,"space":"spherical","radius":6,"materials":[{"name":"stone","color":[1,1,1,1]}],"objects":[{"name":"prism","kind":"halfspaces","faces":[{"normal":[0.70710678,0.70710678,0,0]},{"normal":[0.70710678,-0.35355339,0.61237244,0]},{"normal":[0.70710678,-0.35355339,-0.61237244,0]},{"normal":[0.70710678,0,0,0.70710678]},{"normal":[0.70710678,0,0,-0.70710678]}]}]}
    ;
    for ([_][]const u8{ tetrahedron_source, prism_source }) |source| {
        const parsed = try object_scene.parse(std.testing.allocator, source);
        defer parsed.deinit();
        const triangles = try buildTriangles(std.testing.allocator, parsed.value);
        defer std.testing.allocator.free(triangles);
        const faces = parsed.value.objects[0].faces;
        // Four triangular faces, or three quadrilaterals and two triangles.
        const expected: usize = if (faces.len == 4) 12 else 18;
        try std.testing.expectEqual(@as(usize, expected * 256), triangles.len);
        var face_counts: [6]usize = @splat(0);
        for (triangles) |triangle| {
            try std.testing.expectEqual(@as(usize, 0), triangle.object_index);
            var face_index: ?usize = null;
            for (faces, 0..) |face, i| {
                if (triangle.plane.eql(Point.init(face.normal))) face_index = i;
            }
            try std.testing.expect(face_index != null);
            face_counts[face_index.?] += 1;
            for (triangle.points) |point| {
                try std.testing.expectApproxEqAbs(@as(f32, 1), point.scalarNormSquared(), 1e-5);
                try std.testing.expectApproxEqAbs(@as(f32, 0), spherical_scene.dot(point, triangle.plane), 1e-5);
                for (faces) |face| {
                    try std.testing.expect(spherical_scene.dot(point, Point.init(face.normal)) >= -1e-4);
                }
            }
        }
        for (face_counts[0..faces.len]) |count| try std.testing.expect(count > 0);
    }
}

test "canonical spherical asset meshes every object" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/spherical/world.s3obj.json", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(source);
    const parsed = try object_scene.parse(std.testing.allocator, source);
    defer parsed.deinit();
    const triangles = try buildTriangles(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(triangles);
    try std.testing.expectEqual(@as(usize, 387_072), triangles.len);
    const counts = try std.testing.allocator.alloc(usize, parsed.value.objects.len);
    defer std.testing.allocator.free(counts);
    @memset(counts, 0);
    for (triangles) |triangle| counts[triangle.object_index] += 1;
    for (counts) |count| try std.testing.expect(count > 0);
}

test "rejects halfspace geometry without a triangulable surface" {
    var materials = [_]object_scene.Material{.{ .name = "material", .color = .{ 1, 1, 1, 1 } }};
    var faces = [_]object_scene.Face{
        .{ .normal = .{ 1, 0, 0, 0 } },
        .{ .normal = .{ 1, 0, 0, 0 } },
        .{ .normal = .{ 1, 0, 0, 0 } },
        .{ .normal = .{ 1, 0, 0, 0 } },
        .{ .normal = .{ 1, 0, 0, 0 } },
        .{ .normal = .{ 1, 0, 0, 0 } },
    };
    var bounded_faces = [_]object_scene.Face{
        .{ .normal = .{ 1, 0, 0, 0 } },
        .{ .normal = .{ 0, 1, 0, 0 } },
        .{ .normal = .{ 0, 0, 1, 0 } },
        .{ .normal = .{ 0, 0, 0, 1 } },
    };
    var objects = [_]object_scene.Object{
        .{ .name = "tetrahedron", .kind = .halfspaces, .faces = &bounded_faces },
        .{ .name = "hemisphere", .kind = .halfspaces, .faces = &faces },
    };
    const file = object_scene.File{ .version = 1, .space = .spherical, .radius = 6, .materials = &materials, .objects = &objects };
    for (1..7) |face_count| {
        objects[1].faces = faces[0..face_count];
        try file.validate();
        try std.testing.expectError(error.UnsupportedMeshGeometry, buildTriangles(std.testing.allocator, file));
    }
}

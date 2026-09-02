const std = @import("std");
const zmath = @import("zmath");
const sg = zmath.geometry.spherical_game;

pub const Point = sg.Point;
pub const Direction = sg.Direction;
pub const Pose = sg.Pose;

pub const default_radius: f32 = 6.0;
pub const default_cube_distance: f32 = 2.8;
pub const default_cube_half_extent: f32 = 0.9;
pub const default_eye_height: f32 = 0.35;
pub const default_vertical_fov: f32 = std.math.degreesToRadians(80.0);
pub const default_pitch: f32 = -0.2;
pub const cube_face_steps: usize = 24;
pub const max_cube_triangles: usize = 5 * cube_face_steps * cube_face_steps * 2;

pub const Face = enum {
    left,
    right,
    bottom,
    top,
    front,
    back,
};

pub const Branch = enum { near, far };

pub const ProjectedVertex = struct {
    position: [2]f32,
    distance: f32,
    branch: Branch,
};

pub const WorldTriangle = struct {
    vertices: [3]Point,
    face: Face,
};

pub const ProjectedTriangle = struct {
    vertices: [3]ProjectedVertex,
    face: Face,
    distance: f32,
    reverse_depth: bool,

    pub fn drawBefore(_: void, lhs: ProjectedTriangle, rhs: ProjectedTriangle) bool {
        if (lhs.reverse_depth != rhs.reverse_depth) return lhs.reverse_depth;
        return if (lhs.reverse_depth)
            lhs.distance < rhs.distance
        else
            lhs.distance > rhs.distance;
    }
};

pub const ProjectionStats = struct {
    triangles: usize = 0,
    branches: [2]usize = @splat(0),
    faces: [@typeInfo(Face).@"enum".fields.len]usize = @splat(0),
    min_x: f32 = std.math.inf(f32),
    max_x: f32 = -std.math.inf(f32),
    min_y: f32 = std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),

    pub fn faceTriangles(self: ProjectionStats, face: Face) usize {
        return self.faces[@intFromEnum(face)];
    }

    pub fn width(self: ProjectionStats) f32 {
        return self.max_x - self.min_x;
    }

    pub fn height(self: ProjectionStats) f32 {
        return self.max_y - self.min_y;
    }
};

pub const GroundPose = struct {
    position: Point,
    right: Direction,
    forward: Direction,
    radius: f32,
    eye_height: f32,
    pitch_angle: f32 = 0.0,

    pub fn north(radius: f32, eye_height: f32) GroundPose {
        return .{
            .position = Point.init(.{ 1, 0, 0, 0 }),
            .right = Direction.init(.{ 0, 1, 0, 0 }),
            .forward = Direction.init(.{ 0, 0, 0, 1 }),
            .radius = radius,
            .eye_height = eye_height,
        };
    }

    pub fn camera(self: GroundPose) Pose {
        const lift = sg.rotorBetween(self.position, worldUp(), self.eye_height / self.radius);
        const pose = Pose{
            .position = sg.rotate(self.position, lift),
            .right = sg.rotate(self.right, lift),
            .up = sg.rotate(worldUp(), lift),
            .forward = sg.rotate(self.forward, lift),
            .radius = self.radius,
        };
        return pose.pitch(self.pitch_angle);
    }

    pub fn moveForward(self: GroundPose, distance: f32) GroundPose {
        return self.moved(self.forward, distance);
    }

    pub fn strafeRight(self: GroundPose, distance: f32) GroundPose {
        return self.moved(self.right, distance);
    }

    pub fn yaw(self: GroundPose, angle: f32) GroundPose {
        return self.applied(sg.rotorBetween(self.right, self.forward, angle));
    }

    pub fn pitch(self: GroundPose, angle: f32) GroundPose {
        var out = self;
        out.pitch_angle = std.math.clamp(out.pitch_angle + angle, -1.45, 1.45);
        return out;
    }

    fn moved(self: GroundPose, axis: Direction, distance: f32) GroundPose {
        return self.applied(sg.rotorBetween(self.position, axis, distance / self.radius));
    }

    fn applied(self: GroundPose, rotor: sg.Rotor) GroundPose {
        return .{
            .position = sg.rotate(self.position, rotor),
            .right = sg.rotate(self.right, rotor),
            .forward = sg.rotate(self.forward, rotor),
            .radius = self.radius,
            .eye_height = self.eye_height,
            .pitch_angle = self.pitch_angle,
        };
    }
};

pub const Cube = struct {
    center: Point,
    right: Direction,
    up: Direction,
    forward: Direction,
    half_extent: f32,
    radius: f32,

    pub fn grounded(frame: GroundPose, half_extent: f32) Cube {
        const lift = sg.rotorBetween(frame.position, worldUp(), half_extent / frame.radius);
        return .{
            .center = sg.rotate(frame.position, lift),
            .right = sg.rotate(frame.right, lift),
            .up = sg.rotate(worldUp(), lift),
            .forward = sg.rotate(frame.forward, lift),
            .half_extent = half_extent,
            .radius = frame.radius,
        };
    }

    pub fn surfacePoint(self: Cube, face: Face, u: f32, v: f32) Point {
        const h = self.half_extent;
        const tangent = switch (face) {
            .left => self.right.scale(-h).add(self.up.scale(v * h)).add(self.forward.scale(u * h)),
            .right => self.right.scale(h).add(self.up.scale(v * h)).add(self.forward.scale(-u * h)),
            .bottom => self.right.scale(u * h).add(self.up.scale(-h)).add(self.forward.scale(v * h)),
            .top => self.right.scale(u * h).add(self.up.scale(h)).add(self.forward.scale(-v * h)),
            .front => self.right.scale(-u * h).add(self.up.scale(v * h)).add(self.forward.scale(-h)),
            .back => self.right.scale(u * h).add(self.up.scale(v * h)).add(self.forward.scale(h)),
        }.cast(Direction);
        return sg.expMap(self.center, tangent, self.radius);
    }
};

pub const Scene = struct {
    player: GroundPose,
    cube: Cube,
    radius: f32,
    vertical_fov: f32 = default_vertical_fov,

    pub fn init() Scene {
        var player = GroundPose.north(default_radius, default_eye_height);
        player.pitch_angle = default_pitch;
        return .{
            .player = player,
            .cube = Cube.grounded(player.moveForward(default_cube_distance), default_cube_half_extent),
            .radius = default_radius,
        };
    }

    pub fn camera(self: Scene) Pose {
        return self.player.camera();
    }

    pub fn walkForward(self: *Scene, distance: f32) void {
        self.player = self.player.moveForward(distance);
    }

    pub fn strafeRight(self: *Scene, distance: f32) void {
        self.player = self.player.strafeRight(distance);
    }

    pub fn yaw(self: *Scene, angle: f32) void {
        self.player = self.player.yaw(angle);
    }

    pub fn pitch(self: *Scene, angle: f32) void {
        self.player = self.player.pitch(angle);
    }

    pub fn project(self: Scene, point: Point, aspect: f32) ?ProjectedVertex {
        return self.projectWithCamera(self.camera(), point, aspect);
    }

    pub fn cubeMesh(self: Scene, output: []WorldTriangle) usize {
        var count: usize = 0;
        inline for (.{ Face.left, Face.right, Face.top, Face.front, Face.back }) |face| {
            for (0..cube_face_steps) |u_index| {
                for (0..cube_face_steps) |v_index| {
                    const ua = gridCoord(u_index);
                    const va = gridCoord(v_index);
                    const ub = gridCoord(u_index + 1);
                    const vb = gridCoord(v_index + 1);
                    const cell = [_]Point{
                        self.cube.surfacePoint(face, ua, va),
                        self.cube.surfacePoint(face, ub, va),
                        self.cube.surfacePoint(face, ub, vb),
                        self.cube.surfacePoint(face, ua, vb),
                    };
                    if (count + 2 > output.len) return count;
                    output[count] = .{ .vertices = .{ cell[0], cell[1], cell[2] }, .face = face };
                    output[count + 1] = .{ .vertices = .{ cell[0], cell[2], cell[3] }, .face = face };
                    count += 2;
                }
            }
        }
        return count;
    }

    pub fn projectCube(self: Scene, mesh: []const WorldTriangle, output: []ProjectedTriangle, aspect: f32) usize {
        const camera_pose = self.camera();
        var count: usize = 0;
        for (mesh) |triangle| {
            count = self.appendTriangle(camera_pose, output, count, triangle.face, aspect, triangle.vertices);
        }
        return count;
    }

    pub fn projectionStats(triangles: []const ProjectedTriangle) ProjectionStats {
        var stats = ProjectionStats{};
        for (triangles) |triangle| {
            stats.triangles += 1;
            stats.branches[@intFromEnum(triangle.vertices[0].branch)] += 1;
            stats.faces[@intFromEnum(triangle.face)] += 1;
            for (triangle.vertices) |vertex| {
                stats.min_x = @min(stats.min_x, vertex.position[0]);
                stats.max_x = @max(stats.max_x, vertex.position[0]);
                stats.min_y = @min(stats.min_y, vertex.position[1]);
                stats.max_y = @max(stats.max_y, vertex.position[1]);
            }
        }
        return stats;
    }

    pub fn distanceToCube(self: Scene) f32 {
        const cosine = std.math.clamp(sg.dot(self.camera().position, self.cube.center), -1.0, 1.0);
        return std.math.acos(cosine) * self.radius;
    }

    pub fn projectWithCamera(self: Scene, camera_pose: Pose, point: Point, aspect: f32) ?ProjectedVertex {
        const x = sg.dot(point, camera_pose.right);
        const y = sg.dot(point, camera_pose.up);
        const z = sg.dot(point, camera_pose.forward);
        if (@abs(z) <= 1e-5) return null;

        const scale = @tan(self.vertical_fov * 0.5);
        const distance = std.math.acos(std.math.clamp(sg.dot(camera_pose.position, point), -1.0, 1.0)) * self.radius;
        const projected = ProjectedVertex{
            .position = .{ x / (z * aspect * scale), y / (z * scale) },
            .distance = distance,
            .branch = if (z > 0.0) .near else .far,
        };
        if (!std.math.isFinite(projected.position[0]) or
            !std.math.isFinite(projected.position[1]) or
            !std.math.isFinite(projected.distance)) return null;
        return projected;
    }

    fn appendTriangle(
        self: Scene,
        camera_pose: Pose,
        output: []ProjectedTriangle,
        count: usize,
        face: Face,
        aspect: f32,
        points: [3]Point,
    ) usize {
        if (count >= output.len) return count;
        const a = self.projectWithCamera(camera_pose, points[0], aspect) orelse return count;
        const b = self.projectWithCamera(camera_pose, points[1], aspect) orelse return count;
        const c = self.projectWithCamera(camera_pose, points[2], aspect) orelse return count;
        if (a.branch != b.branch or a.branch != c.branch) return count;
        if (!triangleIntersectsView(.{ a, b, c })) return count;

        const distance = (a.distance + b.distance + c.distance) / 3.0;
        output[count] = .{
            .vertices = .{ a, b, c },
            .face = face,
            .distance = distance,
            .reverse_depth = distance > @as(f32, std.math.pi) * self.radius * 0.5,
        };
        return count + 1;
    }
};

pub fn groundPoint(longitude: f32, latitude: f32) Point {
    const latitude_cos = @cos(latitude);
    return Point.init(.{
        latitude_cos * @cos(longitude),
        latitude_cos * @sin(longitude),
        0.0,
        @sin(latitude),
    });
}

fn triangleIntersectsView(vertices: [3]ProjectedVertex) bool {
    var min_x = vertices[0].position[0];
    var max_x = min_x;
    var min_y = vertices[0].position[1];
    var max_y = min_y;
    for (vertices[1..]) |vertex| {
        min_x = @min(min_x, vertex.position[0]);
        max_x = @max(max_x, vertex.position[0]);
        min_y = @min(min_y, vertex.position[1]);
        max_y = @max(max_y, vertex.position[1]);
    }
    if (max_x < -1.05 or min_x > 1.05 or max_y < -1.05 or min_y > 1.05) return false;
    if (max_x - min_x > 4.0 or max_y - min_y > 4.0) return false;

    const ab_x = vertices[1].position[0] - vertices[0].position[0];
    const ab_y = vertices[1].position[1] - vertices[0].position[1];
    const ac_x = vertices[2].position[0] - vertices[0].position[0];
    const ac_y = vertices[2].position[1] - vertices[0].position[1];
    return @abs(ab_x * ac_y - ab_y * ac_x) > 1e-8;
}

fn gridCoord(index: usize) f32 {
    return @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(cube_face_steps)) * 2.0 - 1.0;
}

fn worldUp() Direction {
    return Direction.init(.{ 0, 0, 1, 0 });
}

fn expectOrthonormal(pose: Pose) !void {
    const frame = [_]Point{ pose.position, pose.right, pose.up, pose.forward };
    for (frame, 0..) |axis, i| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), sg.dot(axis, axis), 1e-4);
        for (frame[i + 1 ..]) |other| {
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), sg.dot(axis, other), 1e-4);
        }
    }
}

test "grounded S3 camera remains orthonormal after movement and look" {
    const player = GroundPose.north(default_radius, default_eye_height)
        .moveForward(3.7)
        .strafeRight(-1.2)
        .yaw(0.6)
        .pitch(-0.35);

    try expectOrthonormal(player.camera());
    try std.testing.expectApproxEqAbs(@sin(default_eye_height / default_radius), sg.dot(player.camera().position, worldUp()), 1e-5);
}

test "cube surface samples remain on S3 and share face edges" {
    const cube = Scene.init().cube;
    inline for (.{ Face.left, Face.right, Face.top, Face.front, Face.back }) |face| {
        const sample = cube.surfacePoint(face, 0.37, -0.22);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), sg.dot(sample, sample), 1e-5);
    }

    const left_front_top = cube.surfacePoint(.left, -1.0, 1.0);
    const front_left_top = cube.surfacePoint(.front, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sg.dot(left_front_top, front_left_top), 1e-5);
}

test "far-side projection exposes all five non-ground cube faces" {
    var scene = Scene.init();
    const before_antipode: f32 = 1.5;
    scene.walkForward(-(@as(f32, std.math.pi) * scene.radius - default_cube_distance - before_antipode));

    var mesh: [max_cube_triangles]WorldTriangle = undefined;
    const mesh_count = scene.cubeMesh(&mesh);
    var triangles: [max_cube_triangles]ProjectedTriangle = undefined;
    const count = scene.projectCube(mesh[0..mesh_count], &triangles, 16.0 / 9.0);
    const stats = Scene.projectionStats(triangles[0..count]);

    try std.testing.expect(stats.faceTriangles(.left) > 0);
    try std.testing.expect(stats.faceTriangles(.right) > 0);
    try std.testing.expect(stats.faceTriangles(.top) > 0);
    try std.testing.expect(stats.faceTriangles(.front) > 0);
    try std.testing.expect(stats.faceTriangles(.back) > 0);
    try std.testing.expectEqual(@as(usize, 0), stats.faceTriangles(.bottom));
    try std.testing.expect(stats.width() > 1.75);
    try std.testing.expect(stats.height() > 1.25);
}

test "projection remains finite across the near and far branches" {
    var scene = Scene.init();
    var mesh: [max_cube_triangles]WorldTriangle = undefined;
    const mesh_count = scene.cubeMesh(&mesh);
    var triangles: [max_cube_triangles]ProjectedTriangle = undefined;

    for (0..25) |_| {
        const count = scene.projectCube(mesh[0..mesh_count], &triangles, 16.0 / 9.0);
        for (triangles[0..count]) |triangle| {
            try std.testing.expect(std.math.isFinite(triangle.distance));
            for (triangle.vertices) |vertex| {
                try std.testing.expect(std.math.isFinite(vertex.position[0]));
                try std.testing.expect(std.math.isFinite(vertex.position[1]));
            }
        }
        scene.walkForward(-0.7);
    }
}

const std = @import("std");
const zmath = @import("zmath");
const sg = zmath.geometry.spherical_game;

pub const Point = sg.Point;
pub const Direction = sg.Direction;
pub const Pose = sg.Pose;
pub const dot = sg.dot;

pub const default_radius: f32 = 6.0;
pub const default_cube_distance: f32 = 2.8;
pub const default_cube_half_extent: f32 = 2.2;
pub const default_eye_height: f32 = 0.35;
pub const default_half_fov: f32 = std.math.degreesToRadians(75.0);

pub const Face = enum {
    left,
    right,
    bottom,
    top,
    front,
    back,
};

pub const Surface = union(enum) {
    ground,
    cube: Face,
};

pub const Hit = struct {
    surface: Surface,
    distance: f32,
    point: Point,
    brightness: f32,
};

pub const Plane = struct {
    inward_normal: Direction,
    face: Face,
};

pub const ViewStats = struct {
    pixels: usize = 0,
    ground: usize = 0,
    cube: usize = 0,
    faces: [@typeInfo(Face).@"enum".fields.len]usize = @splat(0),

    pub fn faceHits(self: ViewStats, face: Face) usize {
        return self.faces[@intFromEnum(face)];
    }

    pub fn cubeFraction(self: ViewStats) f32 {
        if (self.pixels == 0) return 0.0;
        return @as(f32, @floatFromInt(self.cube)) / @as(f32, @floatFromInt(self.pixels));
    }

    pub fn visibleFaceCount(self: ViewStats) usize {
        var count: usize = 0;
        inline for (.{ Face.left, Face.right, Face.top, Face.front, Face.back }) |face| {
            if (self.faceHits(face) > 0) count += 1;
        }
        return count;
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
        // GA frames have no gimbal degeneracy at vertical, so allow looking
        // slightly past straight up/down.
        out.pitch_angle = std.math.clamp(out.pitch_angle + angle, -1.6, 1.6);
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
    planes: [6]Plane,

    pub fn grounded(frame: GroundPose, half_extent: f32) Cube {
        const lift = sg.rotorBetween(frame.position, worldUp(), half_extent / frame.radius);
        const center = sg.rotate(frame.position, lift);
        const right = sg.rotate(frame.right, lift);
        const up = sg.rotate(worldUp(), lift);
        const forward = sg.rotate(frame.forward, lift);

        return .{
            .center = center,
            .right = right,
            .up = up,
            .forward = forward,
            .half_extent = half_extent,
            .radius = frame.radius,
            .planes = .{
                facePlane(center, right, -1.0, half_extent, frame.radius, .left),
                facePlane(center, right, 1.0, half_extent, frame.radius, .right),
                facePlane(center, up, -1.0, half_extent, frame.radius, .bottom),
                facePlane(center, up, 1.0, half_extent, frame.radius, .top),
                facePlane(center, forward, -1.0, half_extent, frame.radius, .front),
                facePlane(center, forward, 1.0, half_extent, frame.radius, .back),
            },
        };
    }

    pub fn contains(self: Cube, point: Point, epsilon: f32) bool {
        for (self.planes) |plane| {
            if (sg.dot(point, plane.inward_normal) < -epsilon) return false;
        }
        return true;
    }
};

/// Per-frame first-hit ray tracer over the full view sphere.
///
/// The cube is the exact intersection of six hemispheres on S3. Along a
/// geodesic ray `p(a) = cos(a)·origin + sin(a)·dir`, plane i is crossed where
/// `a_i cos(a) + b_i sin(a) = 0`, i.e. at `a = r_i ± pi/2` with
/// `r_i = atan2(b_i, a_i)`. The cube interior along the ray is the
/// intersection of all six arcs, so the entry angle is
/// `max(r_i) - pi/2` and the exit angle is `min(r_i) + pi/2`.
pub const Tracer = struct {
    origin: Point,
    right: Direction,
    up: Direction,
    forward: Direction,
    cube: Cube,
    radius: f32,
    plane_a: [6]f32,
    ground_a: f32,

    pub fn init(camera_pose: Pose, cube: Cube) Tracer {
        var tracer = Tracer{
            .origin = camera_pose.position,
            .right = camera_pose.right,
            .up = camera_pose.up,
            .forward = camera_pose.forward,
            .cube = cube,
            .radius = cube.radius,
            .plane_a = undefined,
            .ground_a = sg.dot(camera_pose.position, worldUp()),
        };
        for (cube.planes, 0..) |plane, i| {
            tracer.plane_a[i] = sg.dot(camera_pose.position, plane.inward_normal);
        }
        return tracer;
    }

    /// Full-sky fisheye direction for screen offsets `u`, `v` in [-1, 1].
    /// The whole direction sphere maps onto the unit disc (azimuthal
    /// equidistant): radius = angle from the view center, so the rim is the
    /// antipodal direction. Returns null outside the disc.
    pub fn direction(self: Tracer, u: f32, v: f32) ?Direction {
        const r2 = u * u + v * v;
        if (r2 > 1.0) return null;
        const r = @sqrt(r2);
        if (r < 1e-6) return self.forward;

        const theta = r * std.math.pi;
        const sin_theta = @sin(theta);
        return self.forward.scale(@cos(theta))
            .add(self.right.scale(sin_theta * u / r))
            .add(self.up.scale(sin_theta * v / r))
            .cast(Direction);
    }

    pub fn trace(self: Tracer, dir: Direction) Hit {
        var angles: [6]f32 = undefined;
        for (self.cube.planes, 0..) |plane, i| {
            const b = sg.dot(dir, plane.inward_normal);
            angles[i] = fastAtan2(b, self.plane_a[i]);
        }

        // The cube is small, so the six hemisphere-center angles form one
        // tight cluster on the angle circle; unwrap it around its circular
        // mean before taking max/min.
        var sin_sum: f32 = 0.0;
        var cos_sum: f32 = 0.0;
        for (angles) |angle| {
            sin_sum += @sin(angle);
            cos_sum += @cos(angle);
        }
        const mean = fastAtan2(sin_sum, cos_sum);
        for (&angles) |*angle| {
            while (angle.* - mean > std.math.pi) angle.* -= 2.0 * std.math.pi;
            while (angle.* - mean < -std.math.pi) angle.* += 2.0 * std.math.pi;
        }

        var r_max = -std.math.inf(f32);
        var r_min = std.math.inf(f32);
        var winner: usize = 0;
        var loser: usize = 0;
        for (angles, 0..) |angle, i| {
            if (angle > r_max) {
                r_max = angle;
                winner = i;
            }
            if (angle < r_min) {
                r_min = angle;
                loser = i;
            }
        }

        const entry = r_max - std.math.pi / 2.0;
        const exit = r_min + std.math.pi / 2.0;

        const b_ground = sg.dot(dir, worldUp());
        var ground_angle = fastAtan2(b_ground, self.ground_a) + std.math.pi / 2.0;
        if (ground_angle <= 1e-6) ground_angle += std.math.pi;
        if (ground_angle > std.math.pi) ground_angle -= std.math.pi;

        const inside = entry <= 1e-4 and exit > 1e-4;
        const cube_angle: ?f32 = if (inside)
            exit
        else if (entry > 1e-4 and entry < exit)
            entry
        else
            null;

        if (cube_angle == null or ground_angle < cube_angle.?) {
            const alpha = ground_angle;
            return .{
                .surface = .ground,
                .distance = alpha * self.radius,
                .point = pointAlong(self.origin, dir, alpha),
                .brightness = groundBrightness(self.origin, dir, alpha),
            };
        }

        const alpha = cube_angle.?;
        const hit_plane = if (inside) self.cube.planes[loser] else self.cube.planes[winner];
        const tangent = tangentAlong(self.origin, dir, alpha);
        var brightness = sg.dot(tangent, hit_plane.inward_normal);
        if (inside) brightness = -brightness;
        return .{
            .surface = .{ .cube = hit_plane.face },
            .distance = alpha * self.radius,
            .point = pointAlong(self.origin, dir, alpha),
            .brightness = std.math.clamp(brightness, 0.0, 1.0),
        };
    }
};

pub const Scene = struct {
    player: GroundPose,
    cube: Cube,
    radius: f32,
    half_fov: f32 = default_half_fov,

    pub fn init() Scene {
        const player = GroundPose.north(default_radius, default_eye_height);
        return .{
            .player = player,
            .cube = Cube.grounded(player.moveForward(default_cube_distance), default_cube_half_extent),
            .radius = default_radius,
        };
    }

    pub fn camera(self: Scene) Pose {
        return self.player.camera();
    }

    pub fn tracer(self: Scene) Tracer {
        return Tracer.init(self.camera(), self.cube);
    }

    /// Stereographic wide-FOV frame direction for screen offsets `u`, `v` in
    /// [-1, 1]. Conformal (circles map to circles), and - unlike a pinhole -
    /// keeps the conjugate-region image continuous across the frame. The
    /// reference engine renders spherical space through the same projection
    /// family (Hyperbolica devlog #4).
    pub fn frameDirection(self: Scene, u: f32, v: f32) Direction {
        const camera_pose = self.camera();
        const r = @sqrt(u * u + v * v);
        if (r < 1e-6) return camera_pose.forward;

        const theta = 2.0 * std.math.atan(r * @tan(self.half_fov / 2.0));
        const sin_theta = @sin(theta);
        return camera_pose.forward.scale(@cos(theta))
            .add(camera_pose.right.scale(sin_theta * u / r))
            .add(camera_pose.up.scale(sin_theta * v / r))
            .cast(Direction);
    }

    pub fn sampleFrame(self: Scene, width: usize, height: usize) ViewStats {
        var stats = ViewStats{};
        const frame_tracer = self.tracer();
        for (0..height) |row| {
            for (0..width) |column| {
                const u = ((@as(f32, @floatFromInt(column)) + 0.5) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
                const v = 1.0 - ((@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(height))) * 2.0;
                stats.pixels += 1;
                switch (frame_tracer.trace(self.frameDirection(u, v)).surface) {
                    .ground => stats.ground += 1,
                    .cube => |face| {
                        stats.cube += 1;
                        stats.faces[@intFromEnum(face)] += 1;
                    },
                }
            }
        }
        return stats;
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

    pub fn distanceToCube(self: Scene) f32 {
        const cosine = std.math.clamp(sg.dot(self.camera().position, self.cube.center), -1.0, 1.0);
        return std.math.acos(cosine) * self.radius;
    }
};

pub fn sampleStats(tracer: Tracer, width: usize, height: usize) ViewStats {
    var stats = ViewStats{};
    for (0..height) |row| {
        for (0..width) |column| {
            const u = ((@as(f32, @floatFromInt(column)) + 0.5) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
            const v = 1.0 - ((@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(height))) * 2.0;
            const dir = tracer.direction(u, v) orelse continue;
            stats.pixels += 1;
            switch (tracer.trace(dir).surface) {
                .ground => stats.ground += 1,
                .cube => |face| {
                    stats.cube += 1;
                    stats.faces[@intFromEnum(face)] += 1;
                },
            }
        }
    }
    return stats;
}

fn pointAlong(origin: Point, dir: Direction, angle: f32) Point {
    return origin.scale(@cos(angle))
        .add(dir.scale(@sin(angle)))
        .cast(Point);
}

fn tangentAlong(origin: Point, dir: Direction, angle: f32) Direction {
    return dir.scale(@cos(angle))
        .sub(origin.scale(@sin(angle)))
        .cast(Direction);
}

fn groundBrightness(origin: Point, dir: Direction, angle: f32) f32 {
    const tangent = tangentAlong(origin, dir, angle);
    return @abs(sg.dot(tangent, worldUp()));
}

fn facePlane(center: Point, axis: Direction, sign: f32, half_extent: f32, radius: f32, face: Face) Plane {
    const angle = half_extent / radius;
    return .{
        .inward_normal = center.scale(@sin(angle))
            .sub(axis.scale(sign * @cos(angle)))
            .cast(Direction),
        .face = face,
    };
}

fn worldUp() Direction {
    return Direction.init(.{ 0, 0, 1, 0 });
}

/// Polynomial atan2 approximation (Robin Green, "Faster Math Functions").
/// Accurate to ~1e-5 radians, which is far below visual perception; the
/// accuracy is pinned by a unit test against std.math.atan2.
pub fn fastAtan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    const mx = @max(ax, ay);
    const mn = @min(ax, ay);
    if (mx == 0.0) return 0.0;

    const t = mn / mx;
    const s = t * t;
    const atan_t = t * (0.9998660 + s * (-0.3302995 + s * (0.180141 + s * (-0.085133 + s * 0.0208351))));

    var angle = if (ay > ax) std.math.pi / 2.0 - atan_t else atan_t;
    if (x < 0.0) angle = std.math.pi - angle;
    if (y < 0.0) angle = -angle;
    return angle;
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

test "fastAtan2 matches std within visual tolerance" {
    var max_error: f32 = 0.0;
    var y: f32 = -3.0;
    while (y <= 3.0) : (y += 0.037) {
        var x: f32 = -3.0;
        while (x <= 3.0) : (x += 0.041) {
            const expected = std.math.atan2(y, x);
            const actual = fastAtan2(y, x);
            max_error = @max(max_error, @abs(expected - actual));
        }
    }
    try std.testing.expect(max_error < 1e-4);
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

test "cube planes enclose the center and share face edges" {
    const cube = Scene.init().cube;
    try std.testing.expect(cube.contains(cube.center, 1e-5));

    // Edge shared by the left and front faces: the edge arc from the center
    // along the (-right,-forward) diagonal solves
    // cos(b)·sin(a) - sin(b)·cos(a)/sqrt(2) = 0, i.e. b = atan(sqrt(2)·tan(a)).
    const a = cube.half_extent / cube.radius;
    const beta = std.math.atan(@sqrt(2.0) * std.math.tan(a));
    const diagonal = cube.right.scale(-1.0).add(cube.forward.scale(-1.0)).cast(Direction);
    const edge = sg.expMap(cube.center, sg.normalize(diagonal).?.scale(beta * cube.radius).cast(Direction), cube.radius);

    for (cube.planes) |plane| {
        const side = sg.dot(edge, plane.inward_normal);
        if (plane.face == .left or plane.face == .front) {
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), side, 1e-5);
        } else {
            try std.testing.expect(side > 0.0);
        }
    }
}

test "center ray hits the cube front face near the expected distance" {
    const scene = Scene.init();
    const tracer = scene.tracer();
    const hit = tracer.trace(tracer.forward);

    try std.testing.expectEqual(Face.front, hit.surface.cube);
    // The wall is a great sphere, not a flat plane, so the crossing angle
    // along the geodesic is not the linear offset; pin it to a band and
    // verify the hit point lies exactly on the front plane instead.
    try std.testing.expect(hit.distance > 0.4);
    try std.testing.expect(hit.distance < default_cube_distance);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.0),
        sg.dot(hit.point, scene.cube.planes[@intFromEnum(Face.front)].inward_normal),
        1e-4,
    );
}

test "straight up is ground, not sky" {
    const scene = Scene.init();
    const tracer = scene.tracer();
    const hit = tracer.trace(tracer.up);

    try std.testing.expectEqual(Surface.ground, hit.surface);
    try std.testing.expectApproxEqAbs(
        std.math.pi * default_radius - default_eye_height,
        hit.distance,
        0.01,
    );
}

test "cube image owns the zenith and releases it at the horizon" {
    var scene = Scene.init();
    scene.walkForward(default_cube_distance + std.math.pi * default_radius - 0.15);
    const tracer = scene.tracer();

    // Fan around the world axes (unpitched): zenith angle from world up,
    // azimuth around the vertical.
    for ([_]f32{ 0.0, 45.0, 90.0, 135.0, 180.0 }) |azim_deg| {
        const azim = std.math.degreesToRadians(azim_deg);
        const dir_at = struct {
            fn f(t: Tracer, zeta: f32, psi: f32) Direction {
                return t.up.scale(@cos(zeta))
                    .add(t.forward.scale(@sin(zeta) * @cos(psi)))
                    .add(t.right.scale(@sin(zeta) * @sin(psi)))
                    .cast(Direction);
            }
        }.f;

        // Near the zenith every azimuth hits the roof.
        const zenith_hit = tracer.trace(sg.normalize(dir_at(tracer, std.math.degreesToRadians(20.0), azim)).?);
        try std.testing.expectEqual(Face.top, zenith_hit.surface.cube);

        // Mid-height directions hit walls.
        const wall_hit = tracer.trace(sg.normalize(dir_at(tracer, std.math.degreesToRadians(60.0), azim)).?);
        try std.testing.expect(wall_hit.surface.cube != .bottom);

        // The horizon band is ground: "all rays eventually hit the ground".
        const horizon_hit = tracer.trace(sg.normalize(dir_at(tracer, std.math.degreesToRadians(88.0), azim)).?);
        try std.testing.expectEqual(Surface.ground, horizon_hit.surface);
    }
}

test "showcase frame is filled by the unfolded cube" {
    var scene = Scene.init();
    scene.walkForward(default_cube_distance + std.math.pi * default_radius - 0.15);
    scene.pitch(-1.4);

    const tracer = scene.tracer();
    const center = tracer.trace(tracer.forward);
    try std.testing.expectEqual(Face.top, center.surface.cube);

    const stats = scene.sampleFrame(96, 54);
    try std.testing.expect(stats.visibleFaceCount() == 5);
    try std.testing.expectEqual(@as(usize, 0), stats.faceHits(.bottom));
    try std.testing.expect(stats.cubeFraction() > 0.8);
}

test "walking on from the showcase cycles faces while the cube approaches" {
    var scene = Scene.init();
    scene.walkForward(default_cube_distance + std.math.pi * default_radius - 0.15);
    scene.pitch(-1.4);

    const before = scene.distanceToCube();
    for ([_]f32{ -0.6, 0.6 }) |step| {
        var moved = scene;
        moved.walkForward(step);
        // Either walking direction closes the distance to the cube: the
        // showcase sits near the conjugate point.
        try std.testing.expect(moved.distanceToCube() < before);

        const stats = moved.sampleFrame(64, 36);
        try std.testing.expect(stats.visibleFaceCount() >= 4);
        try std.testing.expectEqual(@as(usize, 0), stats.faceHits(.bottom));
    }
}

test "cube coverage dips mid-range then explodes near the antipode" {
    // Spherical apparent size is not Euclidean-monotonic: it dips around a
    // quarter-turn away, then explodes as the camera nears the cube's
    // antipodal region. Assert both regimes instead of a fake monotone.
    var scene = Scene.init();
    scene.walkForward(12.0);
    const mid = sampleStats(scene.tracer(), 64, 36).cubeFraction();

    scene = Scene.init();
    scene.walkForward(18.5);
    const far = sampleStats(scene.tracer(), 64, 36).cubeFraction();

    scene = Scene.init();
    scene.walkForward(4.0);
    const near = sampleStats(scene.tracer(), 64, 36).cubeFraction();

    try std.testing.expect(near > mid);
    try std.testing.expect(far > mid);
}

test "bottom face is never the first hit along the walk" {
    for ([_]f32{ 0.0, 5.0, 10.0, 14.0, 16.5, 18.0, 20.0, 21.2 }) |walk| {
        var scene = Scene.init();
        scene.walkForward(walk);
        const stats = sampleStats(scene.tracer(), 64, 36);
        try std.testing.expectEqual(@as(usize, 0), stats.faceHits(.bottom));
    }
}

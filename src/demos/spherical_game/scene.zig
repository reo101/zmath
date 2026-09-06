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
pub const default_fence_height: f32 = 1.5;
pub const default_fence_spacing: f32 = 0.75;
pub const default_fence_width: f32 = 0.3;
pub const default_fence_thickness: f32 = 0.25;

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
    fence,
    cube: Face,
};

pub const FencePart = enum {
    /// The broad face of the plank (toward or away from the fence pole).
    face,
    /// The thin end face of the plank (seen looking along the fence).
    edge,
    /// The roof or floor slab of the plank.
    cap,
};

pub const Hit = struct {
    surface: Surface,
    cos_angle: f32,
    sin_angle: f32,
    point: Point,
    brightness: f32,
    /// Which part of the plank the fence hit landed on.
    fence_part: FencePart = .face,
    /// Height above the ground at the hit, as a fraction of the fence's
    /// top (0 = base, 1 = top). Debug aid for orientation; 0 elsewhere.
    height_fraction: f32 = 0,
    /// Hit angle along the ray in radians. Only for tests/HUD; the pixel
    /// loop never pays for it.
    pub fn angle(self: Hit) f32 {
        return std.math.atan2(self.sin_angle, self.cos_angle);
    }

    pub fn distance(self: Hit, radius: f32) f32 {
        return self.angle() * radius;
    }
};

const PlankEntry = struct {
    cos: f32,
    sin: f32,
    brightness: f32,
    part: FencePart,
};

pub const Plane = struct {
    inward_normal: Direction,
    face: Face,
};

/// Picket fence along a ground great circle. The circle's pole is the
/// cube's ground point, so the ring sits a quarter circle (pi*R/2) away
/// from the cube in every direction and crosses the walk path exactly
/// halfway between the cube and its antipode. Standing at the cube the
/// fence reads as a circle around the world; standing at the crossing it
/// is a straight picket row receding to the horizon.
///
/// Each plank is a geodesic box: width along the ring's arc, height over
/// the ground, thickness across the curtain. Its two faces are the
/// curtain great sphere rotated by the half thickness around the plank's
/// ring tangent (outward normals toward and away from the fence pole);
/// its arc edges are the tangent great spheres at the pattern bounds; and
/// its caps are the ground great sphere below and the great sphere
/// through the top rim above (all four side planes contain the vertical
/// e3 direction, so the box is a geodesic prism along "up" and one extra
/// plane per cap is exact to O(delta^2)). A ray enters the box through
/// whichever surface comes first with all six constraints satisfied, so
/// circling the fence rotates the sight line through a plank's face
/// plane (face -> edge -> far face: planks flip), and the wrapped sky
/// serves the far planks from above: their tops hang from the ceiling
/// and catch the ray on the cap.
///
/// Rays are still selected by the "curtain" over the circle: the vertical
/// great 2-sphere with the same pole (a geodesic plane, exactly like the
/// ground), filtered to a height band and a picket/gap pattern along the
/// arc. Gaps are see-through: the ray continues to whatever is behind.
pub const Fence = struct {
    /// Pole of the fence circle AND of its vertical curtain great sphere:
    /// the cube's ground point.
    pole: Point,
    /// The ring crosses the walk path here (pattern angle 0, kept as a
    /// gate gap so the walker passes between pickets).
    anchor: Point,
    /// Second in-plane axis (the e2 strafe pole) completing the circle's
    /// plane span{anchor, axis}.
    axis: Direction,
    height: f32,
    spacing: f32,
    width: f32,
    thickness: f32,
    radius: f32,
};

pub const ViewStats = struct {
    pixels: usize = 0,
    ground: usize = 0,
    fence: usize = 0,
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
    fence: Fence,
    radius: f32,
    plane_a: [6]f32,
    ground_a: f32,
    fence_pole: Direction,
    fence_a: f32,
    sin_half_width: f32,
    cos_half_width: f32,
    sin_half_thick: f32,
    cos_half_thick: f32,

    pub fn init(camera_pose: Pose, cube: Cube, fence: Fence) Tracer {
        var tracer = Tracer{
            .origin = camera_pose.position,
            .right = camera_pose.right,
            .up = camera_pose.up,
            .forward = camera_pose.forward,
            .cube = cube,
            .fence = fence,
            .radius = cube.radius,
            .plane_a = undefined,
            .ground_a = sg.dot(camera_pose.position, worldUp()),
            .fence_pole = fence.pole.cast(Direction),
            .fence_a = sg.dot(camera_pose.position, fence.pole),
            .sin_half_width = @sin(0.5 * fence.width / fence.radius),
            .cos_half_width = @cos(0.5 * fence.width / fence.radius),
            .sin_half_thick = @sin(0.5 * fence.thickness / fence.radius),
            .cos_half_thick = @cos(0.5 * fence.thickness / fence.radius),
        };
        for (cube.planes, 0..) |plane, i| {
            tracer.plane_a[i] = sg.dot(camera_pose.position, plane.inward_normal);
        }
        // Orient the curtain plane so its origin component is positive -
        // the same convention as the ground crossing - so the candidate-A
        // crossing sits in (0, pi/2].
        if (tracer.fence_a < 0.0) {
            tracer.fence_pole = tracer.fence_pole.negate();
            tracer.fence_a = -tracer.fence_a;
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

    /// Intersects the ray with the geodesic box of the plank centered at
    /// ring angle `(cos_theta, sin_theta)`. The plank is a little
    /// parallelepiped on S3, built exactly like the cube: six great-sphere
    /// slabs, two per axis. The broad faces are the curtain rotated by the
    /// half thickness around the plank's ring tangent (outward normals
    /// toward/away from the fence pole); the end faces are the tangent
    /// great spheres at the pattern bounds; the roof is the great sphere
    /// through the top rim; the floor is the ground great sphere itself
    /// (all four side planes contain the vertical e3 direction, so the
    /// box is a geodesic prism along "up"). No extra wedge planes: the
    /// caps are single slabs, so the silhouette is a plain box, not a
    /// gable. The ray enters through whichever face comes first with all
    /// six half-space constraints satisfied: circling the fence rotates
    /// the sight line through a plank's face plane, so the entry switches
    /// face -> edge -> far face - planks flip instead of sliding around
    /// as painted patches - and the wrapped sky serves the far planks from
    /// above, so their roof slabs catch the ray on the cap.
    fn plankEntry(
        self: Tracer,
        dir: Direction,
        sin_theta: f32,
        cos_theta: f32,
        sin_top: f32,
    ) ?PlankEntry {
        const radial = self.fence.anchor.cast(Direction).scale(cos_theta)
            .add(self.fence.axis.scale(sin_theta));
        const n_near = self.fence_pole.scale(self.cos_half_thick)
            .sub(radial.scale(self.sin_half_thick));
        const n_far = self.fence_pole.scale(self.cos_half_thick)
            .add(radial.scale(self.sin_half_thick));
        const edge_low = self.fence.anchor.cast(Direction)
            .scale(cos_theta * self.sin_half_width - sin_theta * self.cos_half_width)
            .add(self.fence.axis.scale(cos_theta * self.cos_half_width + sin_theta * self.sin_half_width));
        const edge_high = self.fence.anchor.cast(Direction)
            .scale(-(cos_theta * self.sin_half_width + sin_theta * self.cos_half_width))
            .add(self.fence.axis.scale(cos_theta * self.cos_half_width - sin_theta * self.sin_half_width));
        const cos_top = @sqrt(1.0 - sin_top * sin_top);
        const cap_top = worldUp().scale(cos_top).sub(radial.scale(sin_top));

        // Six half-space constraints (two faces, two ends, roof, floor),
        // each crossed exactly once forward. The box entry is the crossing
        // where all six hold. The floor slab is the ground great sphere
        // itself: it closes the bottom exactly (the prism's side planes
        // contain e3, so the ground sphere caps the prism flush).
        const normals = [6]Direction{ n_near, n_far, edge_low, edge_high, cap_top, worldUp() };
        const want_positive = [6]bool{ false, true, true, false, false, true };
        var a_c: [6]f32 = undefined;
        var b_c: [6]f32 = undefined;
        var cross_cos: [6]f32 = undefined;
        var cross_sin: [6]f32 = undefined;
        var cross_angle: [6]f32 = undefined;
        var state: [6]bool = undefined;
        var order: [6]usize = undefined;
        var n_order: usize = 0;
        var inside: usize = 0;
        for (normals, 0..) |n_k, k| {
            a_c[k] = sg.dot(self.origin, n_k);
            b_c[k] = sg.dot(dir, n_k);
            const h_k = @sqrt(a_c[k] * a_c[k] + b_c[k] * b_c[k]);
            if (h_k <= 1e-9) {
                // The ray lies in this surface's great sphere (an
                // along-the-fence sight line slides in a plank's face
                // plane): the constraint never toggles and holds
                // throughout.
                state[k] = true;
                inside += 1;
                cross_sin[k] = -1.0;
                continue;
            }
            state[k] = (a_c[k] >= 0.0) == want_positive[k];
            if (state[k]) inside += 1;
            // The surface's single forward crossing, as (cos, sin) with
            // the tracer's sign convention.
            if (a_c[k] >= 0.0) {
                cross_cos[k] = -b_c[k] / h_k;
                cross_sin[k] = a_c[k] / h_k;
            } else {
                cross_cos[k] = b_c[k] / h_k;
                cross_sin[k] = -a_c[k] / h_k;
            }
            cross_angle[k] = std.math.atan2(cross_sin[k], cross_cos[k]);
            // Insert into the ascending crossing order.
            var pos = n_order;
            while (pos > 0) {
                const j = order[pos - 1];
                if (cross_angle[k] < cross_angle[j]) {
                    order[pos] = j;
                    pos -= 1;
                } else break;
            }
            order[pos] = k;
            n_order += 1;
        }
        for (order[0..n_order]) |k| {
            if (state[k]) {
                inside -= 1;
            } else {
                inside += 1;
            }
            state[k] = !state[k];
            if (inside != 6) continue;
            // The ray enters the plank here; the caps bound the height,
            // so no separate band check.
            const brightness: f32 = switch (k) {
                // Per-part tones, the way the cube's faces carry distinct
                // colors: without them a box with identical faces reads as
                // one anonymous curved surface. Near face brightest, far
                // face a step down, ends dark tan, roof lit, floor
                // shadowed.
                0 => 0.78,
                1 => 0.58,
                2 => 0.34,
                3 => 0.34,
                4 => 0.88,
                5 => 0.42,
                else => unreachable,
            };
            const part: FencePart = switch (k) {
                0, 1 => .face,
                2, 3 => .edge,
                else => .cap,
            };
            return .{ .cos = cross_cos[k], .sin = cross_sin[k], .brightness = brightness, .part = part };
        }
        return null;
    }

    /// Tests the cap-entry candidate at ring-point `phi_c` (where the ray
    /// crosses a cap level). Returns true if a fence entry was kept and
    /// no further candidates should be tried (it is closer than any
    /// found so far at the head of the angle order... the caller stops
    /// when the entry is closer than the current best).
    fn capCandidate(
        self: Tracer,
        dir: Direction,
        phi_c: f32,
        sin_top: f32,
        fence_hit: *bool,
        cos_fence: *f32,
        sin_fence: *f32,
        fence_brightness: *f32,
        fence_part: *FencePart,
    ) bool {
        const cap_point = self.origin.scale(@cos(phi_c))
            .add(dir.scale(@sin(phi_c)))
            .cast(Point);
        const theta_c = fastAtan2(
            sg.dot(cap_point, self.fence.axis),
            sg.dot(cap_point, self.fence.anchor),
        );
        const arc_c = theta_c * self.fence.radius;
        if (@mod(arc_c + self.fence.spacing / 2.0, self.fence.spacing) >= self.fence.width) return false;
        const sin_theta = sg.dot(cap_point, self.fence.axis);
        const cos_theta = sg.dot(cap_point, self.fence.anchor);
        if (self.plankEntry(dir, sin_theta, cos_theta, sin_top)) |e| {
            const e_angle = std.math.atan2(e.sin, e.cos);
            const cur_angle = std.math.atan2(sin_fence.*, cos_fence.*);
            if (!fence_hit.* or e_angle < cur_angle) {
                fence_hit.* = true;
                cos_fence.* = e.cos;
                sin_fence.* = e.sin;
                fence_brightness.* = e.brightness;
                fence_part.* = e.part;
                return true;
            }
        }
        return false;
    }

    pub fn trace(self: Tracer, dir: Direction) Hit {
        // Per-plane ray components. b_i = dir·n_i; a_i = origin·n_i is
        // precomputed per frame.
        var b: [6]f32 = undefined;
        for (self.cube.planes, 0..) |plane, i| {
            b[i] = sg.dot(dir, plane.inward_normal);
        }

        // Partition by which side of each hemisphere the camera starts on.
        // Planes with a_i < 0 are entry candidates (their forward crossing
        // angle sits in (0, pi)); planes with a_i > 0 are exit candidates.
        // Within each subset the determinant sign
        //   b_i*a_j - a_i*b_j = h_i h_j sin(r_i - r_j)
        // orders the crossing angles exactly (angles confined to one
        // semicircle per subset), so no trig is needed here.
        var best_entry: ?usize = null;
        var worst_exit: ?usize = null;
        for (0..6) |i| {
            if (self.plane_a[i] < 0.0) {
                if (best_entry) |j| {
                    if (b[i] * self.plane_a[j] - self.plane_a[i] * b[j] > 0.0) best_entry = i;
                } else best_entry = i;
            } else {
                if (worst_exit) |j| {
                    if (b[i] * self.plane_a[j] - self.plane_a[i] * b[j] < 0.0) worst_exit = i;
                } else worst_exit = i;
            }
        }

        // Ground first-positive root: (cos, sin) = (-b_g, a_g)/h_g, since
        // a_g = sin(eye_height/R) > 0.
        const b_ground = sg.dot(dir, worldUp());
        const h_g = @sqrt(b_ground * b_ground + self.ground_a * self.ground_a);
        const cos_ground = -b_ground / h_g;
        const sin_ground = self.ground_a / h_g;

        // Fence candidates. A plank the ray transits always stands on the
        // ring; which plank, and which surface the ray enters through,
        // depends on the approach:
        // - Candidate A: the plank under the ray's curtain crossing
        //   {<p, pole> = 0} (the vertical great sphere over the ring). This
        //   catches side entries - the ray crossing the plank's curtain
        //   slice - including near-cap descents (the band is widened
        //   upward; the box test is the precise filter).
        // - Candidate B: the plank at the ray's ground-crossing arc. This
        //   catches planks seen hanging from the wrapped sky: their tops
        //   face the ray, which never crosses their curtain slice inside
        //   the box.
        // Both candidates are box-tested; the closer entry wins.
        var fence_hit = false;
        var cos_fence: f32 = 0.0;
        var sin_fence: f32 = 0.0;
        var fence_brightness: f32 = 0.0;
        var fence_part: FencePart = .face;
        const sin_top = std.math.sin(self.fence.height / self.fence.radius);

        const b_fence = sg.dot(dir, self.fence_pole);
        const h_fence2 = self.fence_a * self.fence_a + b_fence * b_fence;
        if (h_fence2 > 1e-12) {
            const h_fence = @sqrt(h_fence2);
            const sin_f = self.fence_a / h_fence;
            const cos_f = -b_fence / h_fence;
            if (sin_f > 1e-3) {
                const curtain_point = self.origin.scale(cos_f)
                    .add(dir.scale(sin_f))
                    .cast(Point);
                const sin_psi = sg.dot(curtain_point, worldUp());
                if (sin_psi >= 0.0 and sin_psi <= 3.0 * sin_top) {
                    const theta = fastAtan2(
                        sg.dot(curtain_point, self.fence.axis),
                        sg.dot(curtain_point, self.fence.anchor),
                    );
                    const arc = theta * self.fence.radius;
                    // Half-spacing offset: the crossing point (arc 0) sits
                    // in a gate gap so the walker passes between pickets.
                    if (@mod(arc + self.fence.spacing / 2.0, self.fence.spacing) < self.fence.width) {
                        const cos_psi = @sqrt(1.0 - sin_psi * sin_psi);
                        const sin_theta = sg.dot(curtain_point, self.fence.axis) / cos_psi;
                        const cos_theta = sg.dot(curtain_point, self.fence.anchor) / cos_psi;
                        if (self.plankEntry(dir, sin_theta, cos_theta, sin_top)) |e| {
                            fence_hit = true;
                            cos_fence = e.cos;
                            sin_fence = e.sin;
                            fence_brightness = e.brightness;
                            fence_part = e.part;
                        }
                    }
                }
            }
        }

        // Candidate B: the plank at the ray's ground-crossing arc. A ray
        // tilted up from the fence line crosses the ground plane way out
        // on the far arc - this is what makes the fence wrap the sky:
        // from the gate the far planks hang overhead, and this candidate
        // is what builds their boxes. Near the ring's antipode the ring
        // coordinates degenerate to noise, but the box test then simply
        // rejects - no plank stands there.
        const ground_point = self.origin.scale(cos_ground)
            .add(dir.scale(sin_ground))
            .cast(Point);
        const theta_g = fastAtan2(
            sg.dot(ground_point, self.fence.axis),
            sg.dot(ground_point, self.fence.anchor),
        );
        const arc_g = theta_g * self.fence.radius;
        if (@mod(arc_g + self.fence.spacing / 2.0, self.fence.spacing) < self.fence.width) {
            const sin_theta = sg.dot(ground_point, self.fence.axis);
            const cos_theta = sg.dot(ground_point, self.fence.anchor);
            if (self.plankEntry(dir, sin_theta, cos_theta, sin_top)) |e| {
                const e_angle = std.math.atan2(e.sin, e.cos);
                const cur_angle = std.math.atan2(sin_fence, cos_fence);
                if (!fence_hit or e_angle < cur_angle) {
                    fence_hit = true;
                    cos_fence = e.cos;
                    sin_fence = e.sin;
                    fence_brightness = e.brightness;
                    fence_part = e.part;
                }
            }
        }

        // Candidate C: roof entries, selected at the ray's DESCENDING
        // crossing of the plank-top level e3·x = sin(psi_top). Rays that
        // skim along the curtain (standing on the fence line looking
        // along it, pitched up) or hang in from the far side cross the
        // top level far from their curtain crossing; the roof entry
        // happens exactly there, so the top-level crossing point selects
        // the plank. Rays whose e3 amplitude never reaches the top level
        // have no roof entry and are gated out cheaply.
        const r3_sq = self.ground_a * self.ground_a + b_ground * b_ground;
        if (r3_sq >= sin_top * sin_top) {
            const r3 = @sqrt(r3_sq);
            const phi3 = std.math.atan2(b_ground, self.ground_a);
            const half_top = std.math.acos(std.math.clamp(sin_top / r3, -1.0, 1.0));
            const roots = [2]f32{ phi3 - half_top, phi3 + half_top };
            for (roots) |phi_c| {
                // Descending root only, and within the forward semicircle.
                const slope = -self.ground_a * @sin(phi_c) + b_ground * @cos(phi_c);
                if (slope >= 0.0) continue;
                if (phi_c <= 0.0 or phi_c >= std.math.pi) continue;
                if (self.capCandidate(dir, phi_c, sin_top, &fence_hit, &cos_fence, &sin_fence, &fence_brightness, &fence_part)) break;
            }
        }

        var surface: Surface = undefined;
        var cos_alpha: f32 = undefined;
        var sin_alpha: f32 = undefined;
        var inward: Direction = undefined;

        if (best_entry == null) {
            // Camera inside every hemisphere: the visible surface is the
            // forward exit wall.
            const i = worst_exit.?;
            const a_x = self.plane_a[i];
            const h_x = @sqrt(a_x * a_x + b[i] * b[i]);
            cos_alpha = -b[i] / h_x;
            sin_alpha = a_x / h_x;
            surface = .{ .cube = self.cube.planes[i].face };
            inward = self.cube.planes[i].inward_normal;
        } else {
            const i = best_entry.?;
            const a_e = self.plane_a[i];
            const h_e = @sqrt(a_e * a_e + b[i] * b[i]);
            const cos_entry = b[i] / h_e;
            const sin_entry = -a_e / h_e;

            // Entry beats the exit plane iff entry angle < exit angle, i.e.
            // sin(entry - exit) < 0  <=>  a_e*b_x - b_e*a_x < 0.
            var cube_wins = true;
            if (worst_exit) |x| {
                const a_x = self.plane_a[x];
                if (a_e * b[x] - b[i] * a_x > 0.0) cube_wins = false;
            }
            // ... and beats the ground iff entry angle < ground angle:
            // sin(entry - ground) < 0  <=>  a_e*b_g - b_e*a_g < 0.
            if (a_e * b_ground - b[i] * self.ground_a > 0.0) cube_wins = false;
            // ... and beats the fence box entry by the same (cos, sin)
            // comparison: the fence is closer iff sin(phi_f - phi_e) < 0.
            if (fence_hit and sin_fence * cos_entry - cos_fence * sin_entry < 0.0) cube_wins = false;

            if (cube_wins) {
                cos_alpha = cos_entry;
                sin_alpha = sin_entry;
                surface = .{ .cube = self.cube.planes[i].face };
                inward = self.cube.planes[i].inward_normal;
            } else if (fence_hit and sin_fence * cos_ground - cos_fence * sin_ground < 0.0) {
                cos_alpha = cos_fence;
                sin_alpha = sin_fence;
                surface = .fence;
                inward = worldUp();
            } else {
                cos_alpha = cos_ground;
                sin_alpha = sin_ground;
                surface = .ground;
                inward = worldUp();
            }
        }

        const point = self.origin.scale(cos_alpha)
            .add(dir.scale(sin_alpha))
            .cast(Point);
        const tangent = dir.scale(cos_alpha)
            .sub(self.origin.scale(sin_alpha))
            .cast(Direction);
        var brightness = sg.dot(tangent, inward);
        if (best_entry == null) brightness = -brightness;
        if (surface == .ground or surface == .fence) brightness = @abs(brightness);
        if (surface == .fence) brightness = fence_brightness;

        return .{
            .surface = surface,
            .cos_angle = cos_alpha,
            .sin_angle = sin_alpha,
            .point = point,
            .brightness = std.math.clamp(brightness, 0.0, 1.0),
            .fence_part = fence_part,
            .height_fraction = if (surface == .fence)
                sg.dot(point, worldUp()) / std.math.sin(self.fence.height / self.fence.radius)
            else
                0,
        };
    }
};

pub const FrameCamera = struct {
    pose: Pose,
    tan_half_fov: f32,

    /// Stereographic wide-FOV frame direction for screen offsets `u`, `v`
    /// in [-1, 1]. Conformal (circles map to circles), and - unlike a
    /// pinhole - keeps the conjugate-region image continuous across the
    /// frame. The reference engine renders spherical space through the same
    /// projection family (Hyperbolica devlog #4).
    ///
    /// Uses the half-angle identities so the hot path stays free of
    /// transcendentals: with t = r·tan(fov/2), sin(2·atan t) = 2t/(1+t²)
    /// and cos(2·atan t) = (1-t²)/(1+t²).
    pub fn direction(self: FrameCamera, u: f32, v: f32) Direction {
        const r = @sqrt(u * u + v * v);
        if (r < 1e-6) return self.pose.forward;

        const t = r * self.tan_half_fov;
        const denom = 1.0 / (1.0 + t * t);
        const sin_theta = 2.0 * t * denom;
        const cos_theta = (1.0 - t * t) * denom;
        return self.pose.forward.scale(cos_theta)
            .add(self.pose.right.scale(sin_theta * u / r))
            .add(self.pose.up.scale(sin_theta * v / r))
            .cast(Direction);
    }
};

pub const Scene = struct {
    player: GroundPose,
    cube: Cube,
    fence: Fence,
    radius: f32,
    half_fov: f32 = default_half_fov,

    pub fn init() Scene {
        const player = GroundPose.north(default_radius, default_eye_height);
        // Fence ring: pole at the cube's ground point, so the ring is a
        // quarter circle from the cube and crosses the walk path exactly
        // halfway to the antipode. Pattern anchored at the crossing.
        const theta_c = default_cube_distance / default_radius;
        const theta_m = theta_c + std.math.pi / 2.0;
        return .{
            .player = player,
            .cube = Cube.grounded(player.moveForward(default_cube_distance), default_cube_half_extent),
            .fence = .{
                .pole = Point.init(.{ @cos(theta_c), 0, 0, @sin(theta_c) }),
                .anchor = Point.init(.{ @cos(theta_m), 0, 0, @sin(theta_m) }),
                .axis = Point.init(.{ 0, 1, 0, 0 }),
                .height = default_fence_height,
                .spacing = default_fence_spacing,
                .width = default_fence_width,
                .thickness = default_fence_thickness,
                .radius = default_radius,
            },
            .radius = default_radius,
        };
    }

    pub fn camera(self: Scene) Pose {
        return self.player.camera();
    }

    pub fn tracer(self: Scene) Tracer {
        return Tracer.init(self.camera(), self.cube, self.fence);
    }

    /// Per-frame camera + projection state. Build once, then call
    /// `direction` per pixel - `camera()` composes GA rotors and must stay
    /// out of the hot path.
    pub fn frameCamera(self: Scene) FrameCamera {
        return .{
            .pose = self.camera(),
            .tan_half_fov = @tan(self.half_fov / 2.0),
        };
    }

    pub fn sampleFrame(self: Scene, width: usize, height: usize) ViewStats {
        var stats = ViewStats{};
        const frame_tracer = self.tracer();
        const cam = self.frameCamera();
        for (0..height) |row| {
            for (0..width) |column| {
                const u = ((@as(f32, @floatFromInt(column)) + 0.5) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
                const v = 1.0 - ((@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(height))) * 2.0;
                stats.pixels += 1;
                switch (frame_tracer.trace(cam.direction(u, v)).surface) {
                    .ground => stats.ground += 1,
                    .fence => stats.fence += 1,
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

    pub fn cubeBearingForwardCosine(self: Scene) f32 {
        // Cosine of the angle between the camera's forward tangent and the
        // initial bearing toward the cube center (tangent-projected).
        const camera_pose = self.camera();
        const cosine = sg.dot(camera_pose.position, self.cube.center);
        const bearing = self.cube.center.sub(camera_pose.position.scale(cosine)).cast(Direction);
        const bearing_unit = sg.normalize(bearing) orelse return 1.0;
        return sg.dot(camera_pose.forward, bearing_unit);
    }

    pub fn distanceToCube(self: Scene) f32 {
        const cosine = std.math.clamp(sg.dot(self.camera().position, self.cube.center), -1.0, 1.0);
        return std.math.acos(cosine) * self.radius;
    }

    /// Walk distance from the viewer to the conjugate point of the cube
    /// center (where the cube sits antipodal and the unfolded sky peaks).
    /// The reverse-perspective morph compresses into a small walk window
    /// around it, so the frontend paces movement by this gap.
    pub fn conjugateGap(self: Scene) f32 {
        return @abs(std.math.pi * self.radius - self.distanceToCube());
    }

    /// Movement speed multiplier for a given conjugate gap: full speed far
    /// away, down to a third inside the warping window, so the face-cycling
    /// reads as a gradual unfold instead of a snap.
    pub fn speedScaleForGap(gap_units: f32) f32 {
        return std.math.clamp(gap_units / 5.0, 1.0 / 3.0, 1.0);
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
                .fence => stats.fence += 1,
                .cube => |face| {
                    stats.cube += 1;
                    stats.faces[@intFromEnum(face)] += 1;
                },
            }
        }
    }
    return stats;
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
    try std.testing.expect(hit.distance(default_radius) > 0.4);
    try std.testing.expect(hit.distance(default_radius) < default_cube_distance);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.0),
        sg.dot(hit.point, scene.cube.planes[@intFromEnum(Face.front)].inward_normal),
        1e-4,
    );
}

test "walk speed eases near the conjugate window" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), Scene.speedScaleForGap(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Scene.speedScaleForGap(5.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Scene.speedScaleForGap(50.0), 1e-6);

    const scene = Scene.init();
    try std.testing.expect(scene.conjugateGap() > 5.0);
}

test "probe cap hits from past the fence looking up-back" {
    var found: usize = 0;
    var walk: f32 = 13.0;
    while (walk <= 14.5) : (walk += 0.5) {
        var yaw_deg: f32 = 150;
        while (yaw_deg <= 230) : (yaw_deg += 5) {
            var pitch_deg: f32 = 15;
            while (pitch_deg <= 45) : (pitch_deg += 1) {
                var s = Scene.init();
                s.walkForward(walk);
                s.yaw(std.math.degreesToRadians(yaw_deg));
                // Positive pose pitch looks down; up-looks need negative.
                s.pitch(-std.math.degreesToRadians(pitch_deg));
                const tracer = s.tracer();
                const hit = tracer.trace(tracer.forward);
                if (hit.surface == .fence and hit.fence_part == .cap) {
                    found += 1;
                    if (found <= 8) std.debug.print("cap: walk={d:.2} yaw={d:.1} pitch={d:.1} b={d:.2}\n", .{ walk, yaw_deg, pitch_deg, hit.brightness });
                }
            }
        }
    }
    std.debug.print("total up-back cap hits: {d}\n", .{found});
}

test "fence planks show their caps from beneath the wrapped sky" {
    // Past the fence, pitched up: the already-crossed planks hang from the
    // ceiling. Their undersides must render (cap + cap_side sub-quads),
    // not fall through to the wrapped ground.
    var s = Scene.init();
    s.walkForward(12.0);
    s.yaw(3.14);
    s.pitch(-0.9);
    const fc = s.frameCamera();
    const tracer = s.tracer();
    var caps: usize = 0;
    var vi: usize = 0;
    while (vi < 60) : (vi += 1) {
        var ui: usize = 0;
        while (ui < 80) : (ui += 1) {
            const u = @as(f32, @floatFromInt(ui)) / 79.0 * 2.0 - 1.0;
            const v = @as(f32, @floatFromInt(vi)) / 59.0 * 2.0 - 1.0;
            const hit = tracer.trace(fc.direction(u, v));
            if (hit.surface == .fence) {
                caps += @intFromBool(hit.fence_part == .cap);
            }
        }
    }
    try std.testing.expect(caps >= 10);
}

fn unitToward(from: Point, to: Point) Direction {
    const raw = to.sub(from.scale(sg.dot(from, to))).cast(Direction);
    return raw.scale(1.0 / @sqrt(sg.dot(raw, raw)));
}

test "fence planks flip through their edges when circling the ring" {
    const scene = Scene.init();

    // Picket centers sit at arc = -spacing/2 + width/2 + k*spacing; the
    // one at arc 11.775 is on the backward side of the ring, clear of the
    // cube's silhouette from the start.
    const picket_angle = 11.775 / default_radius;
    const mid_height = (default_fence_height / 2.0) / default_radius;
    const radial = scene.fence.anchor.cast(Direction).scale(@cos(picket_angle))
        .add(scene.fence.axis.scale(@sin(picket_angle)));
    const target = radial.scale(@cos(mid_height))
        .add(worldUp().scale(@sin(mid_height)))
        .cast(Point);

    // From the cube the sight line crosses the curtain rotated toward the
    // pole (the plank's near face) inside the plank's arc range.
    const face_tracer = scene.tracer();
    const face_hit = face_tracer.trace(unitToward(face_tracer.origin, target));
    try std.testing.expectEqual(Surface.fence, face_hit.surface);
    try std.testing.expectEqual(FencePart.face, face_hit.fence_part);
    try std.testing.expectApproxEqAbs(@as(f32, 0.78), face_hit.brightness, 1e-6);

    // Standing just off the ring line (0.01 toward the pole) with the
    // first picket half a radian ahead: the sight line lies nearly in the
    // plank's face plane, so the box entry happens through the arc edge.
    const stand_angle = default_fence_spacing / 2.0 + default_fence_width / 2.0 + default_fence_spacing; // arc 0.525: the first picket center
    const stand_theta = (stand_angle - 0.5) / default_radius;
    const eps = 0.01;
    const ground = scene.fence.pole.scale(@sin(eps))
        .add(scene.fence.anchor.cast(Direction).scale(@cos(stand_theta) * @cos(eps)))
        .add(scene.fence.axis.scale(@sin(stand_theta) * @cos(eps)))
        .cast(Point);
    const lift = sg.rotorBetween(ground, worldUp(), default_eye_height / default_radius);
    const pose = sg.Pose{
        .position = sg.rotate(ground, lift),
        .right = sg.rotate(ground.cast(Direction), lift),
        .up = sg.rotate(worldUp(), lift),
        .forward = sg.rotate(
            scene.fence.anchor.cast(Direction).scale(-@sin(stand_theta))
                .add(scene.fence.axis.scale(@cos(stand_theta))),
            lift,
        ),
        .radius = default_radius,
    };
    const edge_tracer = Tracer.init(pose, scene.cube, scene.fence);
    const edge_target = scene.fence.anchor.cast(Direction)
        .scale(@cos(stand_angle / default_radius) * @cos(mid_height))
        .add(scene.fence.axis.scale(@sin(stand_angle / default_radius) * @cos(mid_height)))
        .add(worldUp().scale(@sin(mid_height)))
        .cast(Point);
    const edge_hit = edge_tracer.trace(unitToward(edge_tracer.origin, edge_target));
    try std.testing.expectEqual(Surface.fence, edge_hit.surface);
    try std.testing.expectEqual(FencePart.edge, edge_hit.fence_part);
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), edge_hit.brightness, 1e-6);
}

test "fence ring crosses the walk path halfway to the antipode" {
    const f = Scene.init().fence;

    // The ring's pole is the cube's ground point: the ring sits a quarter
    // circle from the cube, and its pattern anchor is exactly halfway
    // between the cube and the antipode along the walk great circle.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sg.dot(f.pole, f.anchor), 1e-5);
    try std.testing.expectApproxEqAbs(
        default_cube_distance + std.math.pi * default_radius / 2.0,
        std.math.acos(std.math.clamp(sg.dot(f.anchor, Point.init(.{ 1, 0, 0, 0 })), -1.0, 1.0)) * default_radius,
        1e-4,
    );
}

test "fence pickets ring the walker past the cube" {
    var s = Scene.init();
    // Just past the cube (outside its footprint): the ring is ~7 units
    // ahead, wrapping the walker.
    s.walkForward(default_cube_distance + 2.5);
    const stats = s.sampleFrame(160, 90);

    try std.testing.expect(stats.fence > 0);
    try std.testing.expect(stats.ground > 0);
}

test "fence pickets are visible from the start behind the cube" {
    const stats = Scene.init().sampleFrame(160, 90);
    try std.testing.expect(stats.fence > 0);
    try std.testing.expect(stats.cube > 0);
    // Gaps dominate: pickets are thinner than the spacing.
    try std.testing.expect(stats.fence < stats.ground);
}

test "fence reads as a straight picket row when standing close to it" {
    var scene = Scene.init();
    // Walk 0.4 past the crossing: off the ring line (the walk direction is
    // perpendicular to the ring there), then face along the fence.
    scene.walkForward(default_cube_distance + std.math.pi * default_radius / 2.0 + 0.4);
    scene.yaw(std.math.pi / 2.0);
    const stats = scene.sampleFrame(160, 90);

    // Facing along the fence from just off the line: pickets recede
    // toward the vanishing direction instead of wrapping the view.
    try std.testing.expect(stats.fence > 0);
    try std.testing.expect(stats.fence < stats.ground);
}

test "straight up far from the cube is wrapped ground, not sky" {
    var scene = Scene.init();
    scene.walkForward(10.0);
    const tracer = scene.tracer();
    const hit = tracer.trace(tracer.up);

    try std.testing.expectEqual(Surface.ground, hit.surface);
    try std.testing.expectApproxEqAbs(
        std.math.pi * default_radius - default_eye_height,
        hit.distance(default_radius),
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

        // The horizon band is ground or the fence ring (pickets stand on
        // the horizon from the showcase) - never the cube: "all rays
        // eventually leave the cube".
        const horizon_hit = tracer.trace(sg.normalize(dir_at(tracer, std.math.degreesToRadians(88.0), azim)).?);
        try std.testing.expect(horizon_hit.surface == .ground or horizon_hit.surface == .fence);
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

test "back face emerges as a far-side slice well before the conjugate" {
    // The back face's ground-level edge becomes entry-eligible the moment
    // the viewer passes the contact point's antipode (walk ~16.05), so the
    // moon slice is visible in the plain walking view and expands toward
    // the conjugate.
    var scene = Scene.init();
    scene.walkForward(17.0);
    const early = sampleStats(scene.tracer(), 64, 36).faceHits(.back);

    scene = Scene.init();
    scene.walkForward(21.0);
    const late = sampleStats(scene.tracer(), 64, 36).faceHits(.back);

    try std.testing.expect(early > 0);
    try std.testing.expect(late > 0);

    // And it is on screen once the player turns to face the cube — past
    // the contact-point antipode the cube lives in the backward sky.
    scene = Scene.init();
    scene.walkForward(17.5);
    scene.yaw(std.math.pi);
    const frame_stats = scene.sampleFrame(64, 36);
    try std.testing.expect(frame_stats.faceHits(.back) > 0);
}

test "bottom face is never the first hit along the walk" {
    // The camera always stays inside the bottom plane's hemisphere (it
    // walks on the ground the bottom face is tangent to), so the bottom
    // face is structurally an exit candidate, never an entry face.
    for ([_]f32{ 0.0, 5.0, 10.0, 14.0, 16.5, 18.0, 20.0, 21.2, 22.5 }) |walk| {
        var scene = Scene.init();
        scene.walkForward(walk);
        const stats = sampleStats(scene.tracer(), 64, 36);
        try std.testing.expectEqual(@as(usize, 0), stats.faceHits(.bottom));
    }
}

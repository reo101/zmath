//! Worlds demo kernel: one first-hit ray-tracing shell over four spaces.
//!
//! Modes share the canonical spherical-game vocabulary (six face colors, a
//! checker ground, first-hit tracing) so the geometries can be compared
//! 1:1 at the press of a key:
//!
//! 1. `euclidean`  - flat space, pinhole perspective camera.
//! 2. `isometric`  - flat space, orthographic axonometric camera.
//! 3. `spherical`  - S3, wraps the canonical `spherical_game` scene as-is.
//! 4. `hyperbolic` - H3 rendered through the Beltrami-Klein model: the
//!    Hyperbolica reference engine's own hyperbolic projection. Geodesics
//!    are straight chords and totally-geodesic planes are Euclidean planes
//!    cutting the Klein ball, so the per-pixel tracer is flat linear
//!    algebra; hyperbolicity lives in the metric (depth, checker, walking).
//!
//! Curvature is a runtime value here: the mode union tag selects which
//! metric and projection the pixel loop dispatches to (one predictable
//! branch per pixel).
const std = @import("std");
const zmath = @import("zmath");
const scene = @import("spherical_scene");
const ga = zmath.ga;

/// (3, 1) signature: e1-e3 spacelike, e4 timelike. H3 = unit hyperboloid
/// {<p,p> = -1, e4 > 0} with <a,b> = a.e1 b.e1 + a.e2 b.e2 + a.e3 b.e3
/// - a.e4 b.e4. The library's Lorentz carrier for the hyperbolic mode
/// (HPGA conventions, e4^2 = -1).
const Hy = ga.Algebra(.{ .p = 3, .q = 1 }).Instantiate(f32);
const HyVector = Hy.Vector;

/// Face ids shared with the canonical spherical scene (same palette).
pub const Face = scene.Face;

pub const Surface = union(enum) {
    ground,
    sky,
    cube: Face,
};

/// Mode-agnostic hit for the demo shell. `depth01` is a monotone 0 (near)
/// .. 1 (far) proxy - each mode picks its own scale, the shell only dims
/// with it. `cell` carries ground coordinates for the checker.
pub const Hit = struct {
    surface: Surface,
    depth01: f32,
    brightness: f32,
    cell: [2]f32 = .{ 0, 0 },
};

pub const ViewStats = scene.ViewStats;

pub const Kind = enum { euclidean, isometric, spherical, hyperbolic };

pub const frame_aspect: f32 = 16.0 / 9.0;

const face_pairs = [3]struct { lo: Face, hi: Face }{
    .{ .lo = .front, .hi = .back }, // x
    .{ .lo = .left, .hi = .right }, // y
    .{ .lo = .bottom, .hi = .top }, // z
};

// ---------------------------------------------------------------------------
// Euclidean world (modes 1 and 2 share it; only the camera differs)
// ---------------------------------------------------------------------------

pub const flat = struct {
    pub const cube_center = [3]f32{ 8.0, 0.0, 1.2 };
    pub const cube_half = [3]f32{ 1.2, 1.2, 1.2 };
    pub const eye_height: f32 = 1.6;
    pub const half_fov: f32 = std.math.degreesToRadians(45.0);
    /// True isometric elevation: asin(1/sqrt(3)) = 35.264 degrees.
    pub const iso_pitch: f32 = 0.61547971;
    pub const iso_yaw: f32 = std.math.pi / 4.0;
    pub const iso_half_width: f32 = 7.0;
    pub const iso_distance: f32 = 60.0;
    pub const dim_distance: f32 = 30.0;

    /// FPS state on the flat ground plane z = 0 (up = +z).
    pub const View = struct {
        pos: [2]f32 = .{ 0, 0 },
        yaw: f32 = 0,
        pitch: f32 = 0,

        pub fn walkForward(self: View, distance: f32) View {
            var out = self;
            out.pos[0] += @cos(self.yaw) * distance;
            out.pos[1] += @sin(self.yaw) * distance;
            return out;
        }

        pub fn strafeRight(self: View, distance: f32) View {
            var out = self;
            out.pos[0] += @sin(self.yaw) * distance;
            out.pos[1] += -@cos(self.yaw) * distance;
            return out;
        }

        pub fn yawBy(self: View, angle: f32) View {
            var out = self;
            out.yaw += angle;
            return out;
        }

        pub fn pitchBy(self: View, angle: f32) View {
            var out = self;
            out.pitch = std.math.clamp(out.pitch + angle, -1.45, 1.45);
            return out;
        }
    };

    /// Isometric viewer state: pans a focus point over the ground.
    pub const IsoView = struct {
        focus: [2]f32 = .{ 5.5, 0 },
        yaw: f32 = iso_yaw,
        pitch: f32 = iso_pitch,
        half_width: f32 = iso_half_width,

        pub fn pan(self: IsoView, right: f32, forward: f32) IsoView {
            var out = self;
            const cy = @cos(self.yaw);
            const sy = @sin(self.yaw);
            out.focus[0] += cy * forward + sy * right;
            out.focus[1] += sy * forward - cy * right;
            return out;
        }

        pub fn yawBy(self: IsoView, angle: f32) IsoView {
            var out = self;
            out.yaw += angle;
            return out;
        }

        pub fn zoom(self: IsoView, factor: f32) IsoView {
            var out = self;
            out.half_width = std.math.clamp(out.half_width / factor, 2.0, 40.0);
            return out;
        }
    };

    const BoxRange = struct {
        t_enter: f32 = -std.math.inf(f32),
        t_exit: f32 = std.math.inf(f32),
        enter_face: Face = .front,
        enter_axis: usize = 0,
        exit_face: Face = .back,
        exit_axis: usize = 0,
        hit: bool = false,
    };

    /// Axis-aligned box by the slab method; entry and exit faces exact.
    fn traceBox(origin: [3]f32, dir: [3]f32) BoxRange {
        var range = BoxRange{};
        for (0..3) |axis| {
            const d = dir[axis];
            const lo = cube_center[axis] - cube_half[axis] - origin[axis];
            const hi = cube_center[axis] + cube_half[axis] - origin[axis];
            if (@abs(d) < 1e-8) {
                if (lo > 0 or hi < 0) return range; // parallel, outside slab
                continue;
            }
            var t1 = lo / d;
            var t2 = hi / d;
            var face_lo = face_pairs[axis].lo;
            var face_hi = face_pairs[axis].hi;
            if (t1 > t2) {
                std.mem.swap(f32, &t1, &t2);
                std.mem.swap(Face, &face_lo, &face_hi);
            }
            if (t1 > range.t_enter) {
                range.t_enter = t1;
                range.enter_face = face_lo;
                range.enter_axis = axis;
            }
            if (t2 < range.t_exit) {
                range.t_exit = t2;
                range.exit_face = face_hi;
                range.exit_axis = axis;
            }
        }
        range.hit = range.t_enter <= range.t_exit and range.t_exit > 0;
        return range;
    }

    /// Per-frame camera + world snapshot for the flat tracer.
    pub const Renderer = struct {
        eye: [3]f32,
        right: [3]f32,
        up: [3]f32,
        forward: [3]f32,
        tan_half_fov: f32,
        aspect: f32,
        ortho_half_width: ?f32 = null,

        pub fn fromView(view: View) @This() {
            const cy = @cos(view.yaw);
            const sy = @sin(view.yaw);
            const cp = @cos(view.pitch);
            const sp = @sin(view.pitch);
            const forward = [3]f32{ cy * cp, sy * cp, sp };
            const right = [3]f32{ sy, -cy, 0 };
            const up = [3]f32{
                right[1] * forward[2] - right[2] * forward[1],
                right[2] * forward[0] - right[0] * forward[2],
                right[0] * forward[1] - right[1] * forward[0],
            };
            return .{
                .eye = .{ view.pos[0], view.pos[1], eye_height },
                .right = right,
                .up = up,
                .forward = forward,
                .tan_half_fov = @tan(half_fov / 2.0),
                .aspect = frame_aspect,
            };
        }

        pub fn fromIso(iso: IsoView) @This() {
            const cp = @cos(iso.pitch);
            const sp = @sin(iso.pitch);
            const cy = @cos(iso.yaw);
            const sy = @sin(iso.yaw);
            // Orthographic camera looking down toward the focus point.
            const dir = [3]f32{ cp * cy, cp * sy, -sp };
            const right = [3]f32{ sy, -cy, 0 };
            const up = [3]f32{
                right[1] * dir[2] - right[2] * dir[1],
                right[2] * dir[0] - right[0] * dir[2],
                right[0] * dir[1] - right[1] * dir[0],
            };
            var base: [3]f32 = undefined;
            const focus3 = [3]f32{ iso.focus[0], iso.focus[1], 0.0 };
            for (0..3) |i| {
                base[i] = focus3[i] - dir[i] * iso_distance;
            }
            return .{
                .eye = base,
                .right = right,
                .up = up,
                .forward = dir,
                .tan_half_fov = 1.0,
                .aspect = frame_aspect,
                .ortho_half_width = iso.half_width,
            };
        }

        pub fn render(self: *const @This(), u: f32, v: f32) Hit {
            var origin: [3]f32 = self.eye;
            var dir: [3]f32 = undefined;
            if (self.ortho_half_width) |hw| {
                for (0..3) |i| {
                    origin[i] = self.eye[i] + self.right[i] * (u * hw) + self.up[i] * (v * hw * self.aspect);
                }
                dir = self.forward; // unit by construction
            } else {
                const tx = u * self.tan_half_fov * self.aspect;
                const ty = v * self.tan_half_fov;
                for (0..3) |i| {
                    dir[i] = self.forward[i] + self.right[i] * tx + self.up[i] * ty;
                }
                const inv = 1.0 / @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
                for (0..3) |i| dir[i] *= inv;
            }

            const box = traceBox(origin, dir);
            const t_ground: f32 = if (dir[2] < -1e-8) -origin[2] / dir[2] else std.math.inf(f32);

            var surface: Surface = .sky;
            var t_hit: f32 = std.math.inf(f32);
            var face_axis: usize = 0;

            if (box.hit) {
                const inside = box.t_enter < 0;
                const t_cube = if (inside) box.t_exit else box.t_enter;
                if (t_cube < t_ground) {
                    surface = .{ .cube = if (inside) box.exit_face else box.enter_face };
                    t_hit = t_cube;
                    face_axis = if (inside) box.exit_axis else box.enter_axis;
                }
            }
            if (surface == .sky and t_ground < std.math.inf(f32)) {
                surface = .ground;
                t_hit = t_ground;
            }

            var brightness: f32 = 0.0;
            var cell = [2]f32{ 0, 0 };
            if (surface == .ground) {
                brightness = -dir[2]; // headlight on the horizontal ground
                cell = .{ origin[0] + t_hit * dir[0], origin[1] + t_hit * dir[1] };
            } else if (surface == .cube) {
                brightness = @abs(dir[face_axis]);
            }

            return .{
                .surface = surface,
                .depth01 = if (t_hit == std.math.inf(f32)) 1.0 else std.math.clamp(t_hit / dim_distance, 0.0, 1.0),
                .brightness = brightness,
                .cell = cell,
            };
        }
    };
};

// ---------------------------------------------------------------------------
// Spherical world: thin wrapper over the canonical S3 scene
// ---------------------------------------------------------------------------

pub const SphericalRenderer = struct {
    tracer: scene.Tracer,
    cam: scene.FrameCamera,
    radius: f32,

    pub fn init(world: scene.Scene) SphericalRenderer {
        return .{
            .tracer = world.tracer(),
            .cam = world.frameCamera(),
            .radius = world.radius,
        };
    }

    pub fn render(self: SphericalRenderer, u: f32, v: f32) Hit {
        const sh = self.tracer.trace(self.cam.direction(u, v));
        const surface: Surface = switch (sh.surface) {
            .ground => .ground,
            .cube => |face| .{ .cube = face },
        };
        var cell = [2]f32{ 0, 0 };
        if (surface == .ground) {
            const p = sh.point;
            const walk = std.math.asin(std.math.clamp(scene.dot(p, scene.Point.init(.{ 0, 0, 0, 1 })), -1.0, 1.0)) * self.radius;
            const strafe = scene.fastAtan2(
                scene.dot(p, scene.Point.init(.{ 0, 1, 0, 0 })),
                scene.dot(p, scene.Point.init(.{ 1, 0, 0, 0 })),
            ) * self.radius;
            cell = .{ walk, strafe };
        }
        return .{
            .surface = surface,
            // Matches the canonical demo's dim proxy exactly.
            .depth01 = (1.0 - sh.cos_angle) / 2.0,
            .brightness = sh.brightness,
            .cell = cell,
        };
    }
};

// ---------------------------------------------------------------------------
// Hyperbolic world (Beltrami-Klein)
// ---------------------------------------------------------------------------

pub const hyperbolic = struct {
    pub const radius: f32 = 3.0;
    pub const eye_height: f32 = 0.35;
    pub const half_fov: f32 = std.math.degreesToRadians(45.0);
    /// Axis-aligned box in Klein coordinates, derived from Fermi extents:
    /// walls at 1.8..3.0 world units ahead of the start point, ±0.7 to the
    /// sides, 1.0 world unit tall. A Klein offset for a plane at hyperbolic
    /// distance D from the origin point is tanh(D/r); the bottom face is
    /// the ground plane itself (z = 0), so the cell stands on the floor.
    pub const box_fermi_near: f32 = 1.8;
    pub const box_fermi_far: f32 = 3.0;
    pub const box_fermi_side: f32 = 0.7;
    pub const box_height: f32 = 1.0;

    pub fn boxKleinExtents() struct { x_near: f32, x_far: f32, side: f32, top: f32 } {
        return .{
            .x_near = std.math.tanh(box_fermi_near / radius),
            .x_far = std.math.tanh(box_fermi_far / radius),
            .side = std.math.tanh(box_fermi_side / radius),
            .top = std.math.tanh(box_height / radius),
        };
    }

    const k_e2 = HyVector.init(.{ 0, 1, 0, 0 });
    const k_e3 = HyVector.init(.{ 0, 0, 1, 0 });

    fn ldot(a: HyVector, b: HyVector) f32 {
        return a.scalarProduct(b);
    }

    fn raw4(v: HyVector) [4]f32 {
        return .{
            v.coeffNamed("e1"),
            v.coeffNamed("e2"),
            v.coeffNamed("e3"),
            v.coeffNamed("e4"),
        };
    }

    /// Parallel transport of a tangent `u` at `p` along the boost toward
    /// unit tangent `d` by rapidity factors (c, s) = (cosh, sinh)(t):
    /// u' = u_perp + <u,d>·(c·d + s·p). Vectors orthogonal to the boost
    /// axis pass through unchanged.
    fn transport(u: HyVector, p: HyVector, d: HyVector, c: f32, s: f32) HyVector {
        const ud = ldot(u, d);
        return u.sub(d.scale(ud)).add(d.scale(ud * c)).add(p.scale(ud * s));
    }

    /// Player state: a point on the ground hyperbolic plane {<p, e3> = 0}
    /// with an orthonormal tangent frame - the hyperbolic mirror of the
    /// spherical GroundPose, moved by Lorentz boosts instead of rotors.
    pub const Pose = struct {
        ground: HyVector,
        right: HyVector,
        forward: HyVector,
        pitch_angle: f32 = 0,

        pub fn start() Pose {
            return .{
                .ground = HyVector.init(.{ 0, 0, 0, 1 }),
                .right = k_e2,
                .forward = HyVector.init(.{ 1, 0, 0, 0 }),
            };
        }

        /// Eye point on the hyperboloid, lifted `eye_height` world units
        /// along the fixed ground pole e3.
        pub fn eye(self: Pose) HyVector {
            const ch = std.math.cosh(eye_height / radius);
            const sh = std.math.sinh(eye_height / radius);
            return self.ground.scale(ch).add(k_e3.scale(sh));
        }

        /// Unit tangent at the eye pointing away from the ground.
        pub fn up(self: Pose) HyVector {
            const ch = std.math.cosh(eye_height / radius);
            const sh = std.math.sinh(eye_height / radius);
            return self.ground.scale(sh).add(k_e3.scale(ch));
        }

        /// Full tangent frame at the eye, pitched around the lifted frame.
        pub fn camera(self: Pose) struct { eye: HyVector, right: HyVector, up: HyVector, forward: HyVector } {
            const cp = @cos(self.pitch_angle);
            const sp = @sin(self.pitch_angle);
            const up_e = self.up();
            return .{
                .eye = self.eye(),
                .right = self.right,
                .up = up_e.scale(cp).sub(self.forward.scale(sp)),
                .forward = self.forward.scale(cp).add(up_e.scale(sp)),
            };
        }

        pub fn walkForward(self: Pose, distance: f32) Pose {
            return self.boosted(self.forward, distance);
        }

        pub fn strafeRight(self: Pose, distance: f32) Pose {
            return self.boosted(self.right, distance);
        }

        pub fn yaw(self: Pose, angle: f32) Pose {
            var out = self;
            const c = @cos(angle);
            const s = @sin(angle);
            out.right = self.right.scale(c).add(self.forward.scale(s));
            out.forward = self.forward.scale(c).sub(self.right.scale(s));
            return out;
        }

        pub fn pitch(self: Pose, angle: f32) Pose {
            var out = self;
            out.pitch_angle = std.math.clamp(out.pitch_angle + angle, -1.6, 1.6);
            return out;
        }

        fn boosted(self: Pose, axis: HyVector, distance: f32) Pose {
            const t = distance / radius;
            const c = std.math.cosh(t);
            const s = std.math.sinh(t);
            var out = self;
            out.ground = self.ground.scale(c).add(axis.scale(s));
            out.forward = transport(self.forward, self.ground, axis, c, s);
            out.right = transport(self.right, self.ground, axis, c, s);
            return out;
        }
    };

    const Plane = struct {
        n: [3]f32, // inward normal (Klein space)
        c: f32, // inside: u·n >= c
        face: Face,
        axis: usize,
    };

    fn boxPlanes() [6]Plane {
        const k = boxKleinExtents();
        const cx = (k.x_near + k.x_far) / 2.0;
        const hx = (k.x_far - k.x_near) / 2.0;
        return .{
            .{ .n = .{ 1, 0, 0 }, .c = cx - hx, .face = .front, .axis = 0 },
            .{ .n = .{ -1, 0, 0 }, .c = -(cx + hx), .face = .back, .axis = 0 },
            .{ .n = .{ 0, 1, 0 }, .c = -k.side, .face = .left, .axis = 1 },
            .{ .n = .{ 0, -1, 0 }, .c = -k.side, .face = .right, .axis = 1 },
            .{ .n = .{ 0, 0, 1 }, .c = 0, .face = .bottom, .axis = 2 },
            .{ .n = .{ 0, 0, -1 }, .c = -k.top, .face = .top, .axis = 2 },
        };
    }

    const BoxRange = struct {
        t_enter: f32 = -std.math.inf(f32),
        t_exit: f32 = std.math.inf(f32),
        enter_face: Face = .front,
        enter_axis: usize = 0,
        exit_face: Face = .back,
        exit_axis: usize = 0,
        hit: bool = false,
    };

    /// Klein-space box: inside is u·n >= c for all six planes. A crossing
    /// with d·n > 0 enters the half-space, d·n < 0 leaves it.
    fn traceBox(k: [3]f32, d: [3]f32) BoxRange {
        var range = BoxRange{};
        for (boxPlanes()) |plane| {
            const kn = k[0] * plane.n[0] + k[1] * plane.n[1] + k[2] * plane.n[2];
            const den = d[0] * plane.n[0] + d[1] * plane.n[1] + d[2] * plane.n[2];
            if (@abs(den) < 1e-9) {
                if (kn < plane.c) return range; // parallel, outside slab
                continue;
            }
            const t = (plane.c - kn) / den;
            if (den > 0) {
                if (t > range.t_enter) {
                    range.t_enter = t;
                    range.enter_face = plane.face;
                    range.enter_axis = plane.axis;
                }
            } else {
                if (t < range.t_exit) {
                    range.t_exit = t;
                    range.exit_face = plane.face;
                    range.exit_axis = plane.axis;
                }
            }
        }
        range.hit = range.t_enter <= range.t_exit and range.t_exit > 0;
        return range;
    }

    /// Per-frame camera + world snapshot for the Klein tracer.
    pub const Renderer = struct {
        k: [3]f32, // Klein eye point
        lambda_eye: f32,
        right: [4]f32,
        up: [4]f32,
        forward: [4]f32,
        tan_half_fov: f32,
        aspect: f32,

        pub fn init(pose: Pose) @This() {
            const cam = pose.camera();
            const e = raw4(cam.eye);
            const w = e[3];
            return .{
                .k = .{ e[0] / w, e[1] / w, e[2] / w },
                .lambda_eye = w,
                .right = raw4(cam.right),
                .up = raw4(cam.up),
                .forward = raw4(cam.forward),
                .tan_half_fov = @tan(half_fov / 2.0),
                .aspect = frame_aspect,
            };
        }

        pub fn render(self: *const @This(), u: f32, v: f32) Hit {
            // Pinhole in the tangent space at the eye; the Beltrami-Klein
            // projection keeps world straight lines straight on screen.
            const tx = u * self.tan_half_fov * self.aspect;
            const ty = v * self.tan_half_fov;
            var t4: [4]f32 = undefined;
            for (0..4) |i| {
                t4[i] = self.forward[i] + self.right[i] * tx + self.up[i] * ty;
            }
            const d = [3]f32{
                t4[0] - t4[3] * self.k[0],
                t4[1] - t4[3] * self.k[1],
                t4[2] - t4[3] * self.k[2],
            };
            const dd = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
            const inv_len = 1.0 / @sqrt(dd);
            const kd = self.k[0] * d[0] + self.k[1] * d[1] + self.k[2] * d[2];
            const kk = self.k[0] * self.k[0] + self.k[1] * self.k[1] + self.k[2] * self.k[2];
            // Affine parameter where the chord reaches the Klein boundary
            // (hyperbolic infinity): |k + s*d|^2 = 1.
            const s_boundary = (-kd + @sqrt(kd * kd + dd * (1.0 - kk))) / dd;

            const box = traceBox(self.k, d);
            const t_ground: f32 = if (d[2] < -1e-9) -self.k[2] / d[2] else std.math.inf(f32);
            const ground_valid = t_ground < s_boundary;

            var surface: Surface = .sky;
            var t_hit: f32 = std.math.inf(f32);
            var face_axis: usize = 0;

            if (box.hit) {
                const inside = box.t_enter < 0;
                const t_cube = if (inside) box.t_exit else box.t_enter;
                // Strict < against the ground: the box bottom is coplanar
                // with the ground, and the ground wins ties (the bottom
                // face is structurally never the first hit from above).
                if (t_cube < s_boundary and t_cube < t_ground) {
                    surface = .{ .cube = if (inside) box.exit_face else box.enter_face };
                    t_hit = t_cube;
                    face_axis = if (inside) box.exit_axis else box.enter_axis;
                }
            }
            if (surface == .sky and ground_valid) {
                surface = .ground;
                t_hit = t_ground;
            }

            var brightness: f32 = 0.0;
            var cell = [2]f32{ 0, 0 };
            var depth01: f32 = 1.0;

            if (t_hit < std.math.inf(f32)) {
                const uh = [3]f32{
                    self.k[0] + t_hit * d[0],
                    self.k[1] + t_hit * d[1],
                    self.k[2] + t_hit * d[2],
                };
                const r2 = uh[0] * uh[0] + uh[1] * uh[1] + uh[2] * uh[2];
                const lambda_hit = 1.0 / @sqrt(1.0 - r2);
                // Hyperbolic distance proxy along the geodesic:
                // cosh(d/r) = lambda_eye * lambda_hit * (1 - k.u).
                const cosh_d = self.lambda_eye * lambda_hit * (1.0 - kk - t_hit * kd);
                depth01 = std.math.clamp(1.0 - 1.0 / cosh_d, 0.0, 1.0);

                if (surface == .ground) {
                    // Hyperbolic Fermi coordinates on the ground: the
                    // hyperboloid point is (u, 1)/lambda_hit, so
                    // <P, e_i> = u_i * lambda_hit and dist = r·asinh(...).
                    cell = .{
                        radius * std.math.asinh(uh[0] * lambda_hit),
                        radius * std.math.asinh(uh[1] * lambda_hit),
                    };
                    brightness = @abs(d[2]) * inv_len;
                } else {
                    brightness = @abs(d[face_axis]) * inv_len;
                }
            }

            return .{
                .surface = surface,
                .depth01 = depth01,
                .brightness = std.math.clamp(brightness, 0.0, 1.0),
                .cell = cell,
            };
        }
    };
};

// ---------------------------------------------------------------------------
// Mode union + shell helpers
// ---------------------------------------------------------------------------

pub const Mode = union(Kind) {
    euclidean: flat.View,
    isometric: flat.IsoView,
    spherical: scene.Scene,
    hyperbolic: hyperbolic.Pose,

    pub fn init(kind: Kind) Mode {
        return switch (kind) {
            .euclidean => .{ .euclidean = .{} },
            .isometric => .{ .isometric = .{} },
            .spherical => .{ .spherical = scene.Scene.init() },
            .hyperbolic => .{ .hyperbolic = hyperbolic.Pose.start() },
        };
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .euclidean => "euclidean (flat space, pinhole)",
            .isometric => "isometric (flat space, orthographic)",
            .spherical => "spherical (S3, stereographic)",
            .hyperbolic => "hyperbolic (H3, Beltrami-Klein)",
        };
    }

    pub fn hint(self: Mode) []const u8 {
        return switch (self) {
            .euclidean => "W/S/A/D walk, arrows look, R reset. Tab or 1-4 switch worlds.",
            .isometric => "W/A/S/D pan, Q/E rotate, wheel zoom, R reset. Tab or 1-4 switch.",
            .spherical => "W/S/A/D walk, arrows look, R reset. Walk past the far side, look up.",
            .hyperbolic => "W/S/A/D walk, arrows look, R reset. Tab or 1-4 switch worlds.",
        };
    }

    /// Headless capture defaults per mode (ZMATH_DEMO_WALK / ZMATH_DEMO_PITCH).
    pub fn captureDefaults(kind: Kind) struct { walk: f32, pitch: f32 } {
        return switch (kind) {
            .euclidean => .{ .walk = 4.0, .pitch = 0.0 },
            .isometric => .{ .walk = 0.0, .pitch = 0.0 },
            // The canonical showcase: roof centered overhead, walls splayed.
            .spherical => .{ .walk = scene.default_cube_distance + std.math.pi * scene.default_radius - 0.15, .pitch = -1.4 },
            .hyperbolic => .{ .walk = 0.0, .pitch = 0.0 },
        };
    }

    /// Apply capture state. `pitch` follows the spherical convention
    /// (negative = look up); the flat and hyperbolic poses negate it.
    pub fn applyCapture(self: *Mode, walk: f32, pitch: f32) void {
        switch (self.*) {
            .euclidean => |*view| {
                view.* = view.walkForward(walk - view.pos[0]);
                view.* = view.pitchBy(-pitch);
            },
            .isometric => |*iso| {
                iso.focus[0] += walk;
            },
            .spherical => |*world| {
                world.walkForward(walk);
                if (pitch != 0.0) world.pitch(pitch);
            },
            .hyperbolic => |*pose| {
                pose.* = pose.walkForward(walk);
                if (pitch != 0.0) pose.* = pose.pitch(-pitch);
            },
        }
    }

    pub fn renderer(self: Mode) Renderer {
        return switch (self) {
            .euclidean => |view| .{ .flat = flat.Renderer.fromView(view) },
            .isometric => |iso| .{ .flat = flat.Renderer.fromIso(iso) },
            .spherical => |world| .{ .spherical = SphericalRenderer.init(world) },
            .hyperbolic => |pose| .{ .hyperbolic = hyperbolic.Renderer.init(pose) },
        };
    }
};

pub const Renderer = union(enum) {
    flat: flat.Renderer,
    spherical: SphericalRenderer,
    hyperbolic: hyperbolic.Renderer,

    pub fn render(self: Renderer, u: f32, v: f32) Hit {
        return switch (self) {
            .flat => |r| r.render(u, v),
            .spherical => |r| r.render(u, v),
            .hyperbolic => |r| r.render(u, v),
        };
    }
};

pub fn sampleStats(mode: Mode, width: usize, height: usize) ViewStats {
    var stats = ViewStats{};
    const frame = mode.renderer();
    for (0..height) |row| {
        for (0..width) |column| {
            const u = ((@as(f32, @floatFromInt(column)) + 0.5) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
            const v = 1.0 - ((@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(height))) * 2.0;
            stats.pixels += 1;
            switch (frame.render(u, v).surface) {
                .ground => stats.ground += 1,
                .sky => {},
                .cube => |face| {
                    stats.cube += 1;
                    stats.faces[@intFromEnum(face)] += 1;
                },
            }
        }
    }
    return stats;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn hypAxes() [3]HyVector {
    return .{
        HyVector.init(.{ 1, 0, 0, 0 }),
        HyVector.init(.{ 0, 1, 0, 0 }),
        HyVector.init(.{ 0, 0, 1, 0 }),
    };
}

fn hypLdot(a: HyVector, b: HyVector) f32 {
    return a.scalarProduct(b);
}

fn renderCenter(mode: Mode) Hit {
    return mode.renderer().render(0.0, 0.0);
}

test "flat center ray hits the cube front face" {
    // Eye at height 1.6 aimed straight at the cube center (8, 0, 1.2).
    var view = flat.View{};
    view.yaw = 0.0;
    view.pitch = std.math.asin((flat.cube_center[2] - flat.eye_height) / flat.cube_center[0]);
    const hit = flat.Renderer.fromView(view).render(0.0, 0.0);
    try std.testing.expectEqual(Face.front, hit.surface.cube);
    try std.testing.expect(hit.brightness > 0.99);
}

test "flat sky above the horizon, ground below" {
    var view = flat.View{};
    view.pitch = 0.8;
    const up = flat.Renderer.fromView(view).render(0.0, 0.0);
    try std.testing.expectEqual(Surface.sky, up.surface);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), up.depth01, 1e-6);

    view.pitch = -0.5;
    const down = flat.Renderer.fromView(view).render(0.0, 0.0);
    try std.testing.expectEqual(Surface.ground, down.surface);
    try std.testing.expect(down.brightness > 0.3);
}

test "flat walking advances the ground checker" {
    const view = flat.View{};
    const hit = flat.Renderer.fromView(view).render(0.0, -0.9);
    try std.testing.expectEqual(Surface.ground, hit.surface);

    const walked = flat.Renderer.fromView(view.walkForward(1.0)).render(0.0, -0.9);
    try std.testing.expectApproxEqAbs(hit.cell[0] + 1.0, walked.cell[0], 1e-4);
}

test "isometric frames the box with top and front faces" {
    const stats = sampleStats(.{ .isometric = flat.IsoView{} }, 96, 54);
    try std.testing.expect(stats.cube > 0);
    try std.testing.expect(stats.faceHits(.top) > 0);
    try std.testing.expect(stats.faceHits(.front) > 0);
    try std.testing.expect(stats.ground > stats.cube);
}

test "hyperbolic frame stays orthonormal under movement" {
    const pose = hyperbolic.Pose.start()
        .walkForward(2.0)
        .strafeRight(-1.0)
        .yaw(0.7)
        .pitch(0.4);
    const cam = pose.camera();

    try std.testing.expectApproxEqAbs(@as(f32, -1.0), hypLdot(cam.eye, cam.eye), 1e-3);
    inline for (.{ cam.right, cam.up, cam.forward }) |axis| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), hypLdot(axis, axis), 1e-3);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), hypLdot(cam.eye, axis), 1e-3);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hypLdot(cam.right, cam.up), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hypLdot(cam.right, cam.forward), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hypLdot(cam.up, cam.forward), 1e-3);

    // The eye keeps its height above the ground plane, and the ground
    // point stays on the ground.
    const eh = std.math.sinh(hyperbolic.eye_height / hyperbolic.radius);
    try std.testing.expectApproxEqAbs(eh, hypLdot(cam.eye, hypAxes()[2]), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hypLdot(pose.ground, hypAxes()[2]), 1e-3);
}

test "hyperbolic center ray hits the box front face" {
    const hit = renderCenter(.{ .hyperbolic = hyperbolic.Pose.start() });
    try std.testing.expectEqual(Face.front, hit.surface.cube);
    try std.testing.expect(hit.brightness > 0.9);
}

test "hyperbolic cube bottom face is never the first hit from above" {
    var pose = hyperbolic.Pose.start();
    var walk: f32 = 0.0;
    while (walk <= 4.5) : (walk += 0.5) {
        const stats = sampleStats(.{ .hyperbolic = pose }, 64, 36);
        try std.testing.expectEqual(@as(usize, 0), stats.faceHits(.bottom));
        pose = pose.walkForward(0.5);
    }
}

test "hyperbolic cube recedes exponentially with walking" {
    // Geodesic distance from the eye to the box front plane {u_x = x_near}:
    // the plane's pole is m = (1,0,0,c)/sqrt(1 - c^2) and
    // d = r·asinh(<E, m>), which grows exponentially with the walk gap.
    const r = hyperbolic.radius;
    const c = hyperbolic.boxKleinExtents().x_near;
    const m_norm = @sqrt(1.0 - c * c);
    const frontPlaneDistance = struct {
        fn call(pose: hyperbolic.Pose, plane_c: f32, norm: f32, radius: f32) f32 {
            const e = hyperbolic.raw4(pose.camera().eye);
            return radius * std.math.asinh(e[3] * (plane_c - e[0] / e[3]) / norm);
        }
    }.call;

    const near_d = frontPlaneDistance(hyperbolic.Pose.start().walkForward(-0.5), c, m_norm, r);
    const far_d = frontPlaneDistance(hyperbolic.Pose.start().walkForward(-4.5), c, m_norm, r);
    try std.testing.expect(far_d > 2.0 * near_d);

    // The rendered center ray from moderately far back still hits the wall.
    const near = renderCenter(.{ .hyperbolic = hyperbolic.Pose.start().walkForward(-0.5) });
    try std.testing.expectEqual(Face.front, near.surface.cube);
    const near_cosh = 1.0 / (1.0 - near.depth01);
    try std.testing.expectApproxEqAbs(
        std.math.cosh(near_d / hyperbolic.radius),
        near_cosh,
        0.02,
    );
}

test "hyperbolic ground checker advances with walking" {
    // Steep down-look (v = -0.9) lands in front of the box footprint.
    const start_mode = Mode{ .hyperbolic = hyperbolic.Pose.start() };
    const start = start_mode.renderer().render(0.0, -0.9);
    try std.testing.expectEqual(Surface.ground, start.surface);

    // Walk AWAY from the box: the Fermi walk coordinate shifts rigidly.
    const walked_mode = Mode{ .hyperbolic = hyperbolic.Pose.start().walkForward(-1.0) };
    const walked = walked_mode.renderer().render(0.0, -0.9);
    try std.testing.expectEqual(Surface.ground, walked.surface);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), walked.cell[0] - start.cell[0], 0.15);
}

test "hyperbolic sky above the horizon" {
    const mode = Mode{ .hyperbolic = hyperbolic.Pose.start().pitch(0.8) };
    const hit = mode.renderer().render(0.0, 0.0);
    try std.testing.expectEqual(Surface.sky, hit.surface);
}

test "every mode samples a full frame" {
    inline for ([_]Kind{ .euclidean, .isometric, .spherical, .hyperbolic }) |kind| {
        const stats = sampleStats(Mode.init(kind), 64, 36);
        try std.testing.expectEqual(@as(usize, 64 * 36), stats.pixels);
    }
}

test "spherical mode wraps the canonical scene" {
    const hit = renderCenter(.{ .spherical = scene.Scene.init() });
    try std.testing.expectEqual(Face.front, hit.surface.cube);
}

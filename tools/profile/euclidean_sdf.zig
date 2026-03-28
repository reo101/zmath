const std = @import("std");
const zmath = @import("zmath");
const euclidean_sdf = @import("demo_euclidean_sdf");

const sdf = zmath.render.sdf;
const linux = std.os.linux;
const demo = euclidean_sdf.demo_core;

const canvas_width: usize = 160;
const canvas_height: usize = 90;
const sample_scale_x: usize = 1;
const sample_scale_y: usize = 2;

const TraceMode = enum {
    raw,
    accelerated,
};

const NormalMode = enum {
    sdf_estimate,
    exact_box,
};

const Stats = struct {
    elapsed_ns: u64 = 0,
    rays: usize = 0,
    hits: usize = 0,
    sphere_rejects: usize = 0,
    total_steps: usize = 0,
    checksum: f64 = 0.0,
};

fn monotonicNanos() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn runCase(
    writer: anytype,
    label: []const u8,
    scene: euclidean_sdf.Scene,
    trace_mode: TraceMode,
    normal_mode: NormalMode,
) !void {
    const options = sdf.MarchOptions{
        .min_distance = 0.0,
        .max_distance = demo.far_clip_z + zmath.render.projection.euclideanProjectionDepthOffset(scene.projection_mode) + scene.cube_half_extent * 2.0,
        .hit_epsilon = 0.0014,
        .min_step = 0.0008,
        .step_scale = 0.98,
        .max_steps = 96,
    };

    const overlay_width = canvas_width * sample_scale_x;
    const overlay_height = canvas_height * sample_scale_y;
    var stats = Stats{};

    const start_ns = monotonicNanos();
    for (0..overlay_height) |sy| {
        for (0..overlay_width) |sx| {
            stats.rays += 1;
            const ray = scene.ray(sx, sy, canvas_width, canvas_height, sample_scale_x, sample_scale_y);
            if (trace_mode == .accelerated and euclidean_sdf.raySphereInterval(ray, scene.bound_radius) == null) {
                stats.sphere_rejects += 1;
                continue;
            }

            const hit = switch (trace_mode) {
                .raw => scene.traceRaw(ray, options),
                .accelerated => scene.traceAccelerated(ray, options),
            } orelse continue;

            stats.hits += 1;
            stats.total_steps += hit.steps;

            const local_normal = switch (normal_mode) {
                .sdf_estimate => scene.localNormal(hit.position),
                .exact_box => scene.localNormal(hit.position),
            };
            const world_normal = switch (normal_mode) {
                .sdf_estimate => sdf.estimateNormalWith(euclidean_sdf.sampleScene, &scene, hit.position, scene.cube_half_extent * 0.0035),
                .exact_box => scene.cubeLocalToWorldDirection(local_normal),
            };
            stats.checksum += @as(f64, world_normal.x + world_normal.y + world_normal.z + scene.viewDepth(hit.position));
        }
    }
    stats.elapsed_ns = monotonicNanos() - start_ns;

    const elapsed_ms = @as(f64, @floatFromInt(stats.elapsed_ns)) / @as(f64, std.time.ns_per_ms);
    const avg_steps_per_hit = if (stats.hits == 0)
        0.0
    else
        @as(f64, @floatFromInt(stats.total_steps)) / @as(f64, @floatFromInt(stats.hits));
    const avg_ns_per_ray = @as(f64, @floatFromInt(stats.elapsed_ns)) / @as(f64, @floatFromInt(stats.rays));

    try writer.print(
        "{s}\n  rays={d} hits={d} sphere_rejects={d}\n  total={d:.3}ms avg_ray={d:.1}ns avg_hit_steps={d:.2}\n  checksum={d:.6}\n",
        .{
            label,
            stats.rays,
            stats.hits,
            stats.sphere_rejects,
            elapsed_ms,
            avg_ns_per_ray,
            avg_steps_per_hit,
            stats.checksum,
        },
    );
}

fn benchmarkMode(writer: anytype, mode: demo.DemoMode) !void {
    var app = try demo.App.init();
    app.animate = false;
    app.mode = mode;
    const scene = euclidean_sdf.Scene.init(app.euclideanScene() orelse return error.ExpectedEuclideanScene);
    try writer.print("mode={s}\n", .{@tagName(mode)});
    try runCase(writer, "  raw + sdf normal", scene, .raw, .sdf_estimate);
    try runCase(writer, "  accelerated + exact normal", scene, .accelerated, .exact_box);
    try writer.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    try benchmarkMode(writer, .perspective);
    try benchmarkMode(writer, .isometric);
    try stdout_writer.flush();
}

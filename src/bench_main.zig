const std = @import("std");
const zmath = @import("zmath");
const ga = zmath.ga;
const Cl3 = ga.Algebra(.euclidean(3));
const Cl2 = ga.Algebra(.euclidean(2));

fn timestampNow(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn elapsedNanos(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
    const duration = start.durationTo(end);
    return @intCast(duration.toNanoseconds());
}

fn benchmarkVector3(io: std.Io, iterations: usize) u64 {
    const Vec3 = Cl3.Vector(f32);
    var a = Vec3.init(.{ 1.0, 2.0, 3.0 });
    var b = Vec3.init(.{ 4.0, 5.0, 6.0 });
    var sink: f32 = 0;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        a = a.add(b).scale(0.99991);
        b = b.sub(a).scale(1.00003);
        sink += a.scalarProduct(b);
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(sink);
    return elapsedNanos(start, end);
}

fn benchmarkRawVector3(io: std.Io, iterations: usize) u64 {
    var a: @Vector(3, f32) = .{ 1.0, 2.0, 3.0 };
    var b: @Vector(3, f32) = .{ 4.0, 5.0, 6.0 };
    var sink: f32 = 0;

    const mul_a: @Vector(3, f32) = @splat(0.99991);
    const mul_b: @Vector(3, f32) = @splat(1.00003);

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        a = (a + b) * mul_a;
        b = (b - a) * mul_b;

        const prod = a * b;
        sink += prod[0] + prod[1] + prod[2];
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(sink);
    return elapsedNanos(start, end);
}

fn benchmarkRotor2(io: std.Io, iterations: usize) u64 {
    const E2 = Cl2.Basis(f32);
    var v = E2.e(1).add(E2.e(2).scale(0.5));
    var angle: f32 = 0;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        angle += 0.0009;
        const r = ga.rotors2d.planarRotor(f32, angle);
        v = ga.rotors2d.rotated(v, r);
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

pub fn run(init: std.process.Init, backend_name: []const u8) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const vector_iterations: usize = 30_000_000;
    const rotor_iterations: usize = 20_000_000;

    const ga_vec_ns = benchmarkVector3(io, vector_iterations);
    const raw_vec_ns = benchmarkRawVector3(io, vector_iterations);
    const rotor_ns = benchmarkRotor2(io, rotor_iterations);

    try stdout.print("backend: {s}\n", .{backend_name});

    try stdout.print("GA Vec3 add/sub/scale/dot: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        vector_iterations,
        ga_vec_ns,
        @as(f64, @floatFromInt(ga_vec_ns)) / @as(f64, @floatFromInt(vector_iterations)),
    });
    try stdout.print("Raw @Vector(3,f32): {} iters in {} ns ({d:.3} ns/iter)\n", .{
        vector_iterations,
        raw_vec_ns,
        @as(f64, @floatFromInt(raw_vec_ns)) / @as(f64, @floatFromInt(vector_iterations)),
    });
    try stdout.print("GA/raw ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(ga_vec_ns)) / @as(f64, @floatFromInt(raw_vec_ns)),
    });
    try stdout.print("2D rotor rotate: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        rotor_ns,
        @as(f64, @floatFromInt(rotor_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.flush();
}

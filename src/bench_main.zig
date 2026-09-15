const std = @import("std");
const zmath = @import("zmath");
const ga = zmath.ga;
const H3 = ga.Algebra(.euclidean(3)).Instantiate(f32);
const H2 = ga.Algebra(.euclidean(2)).Instantiate(f32);
const P3 = ga.pga.extend(ga.Algebra(.{ .p = 3, .q = 0, .r = 1 }).Instantiate(f32));
const cl3_benchmark_rotor = H3.exprAs(H3.Rotor, "0.7 - 0.46904158 e12 - 0.5 e13 - 0.2 e23", .{});
const cl3_benchmark_vector = H3.exprAs(H3.Vector, "e1 + e2 / 2 - e3 / 4", .{});

fn timestampNow(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn elapsedNanos(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
    const duration = start.durationTo(end);
    return @intCast(duration.toNanoseconds());
}

const DualQuaternion = struct {
    real: @Vector(4, f32),
    dual: @Vector(4, f32),
};

fn quaternionProduct(lhs: @Vector(4, f32), rhs: @Vector(4, f32)) @Vector(4, f32) {
    return .{
        lhs[0] * rhs[0] - lhs[1] * rhs[1] - lhs[2] * rhs[2] - lhs[3] * rhs[3],
        lhs[0] * rhs[1] + lhs[1] * rhs[0] + lhs[2] * rhs[3] - lhs[3] * rhs[2],
        lhs[0] * rhs[2] - lhs[1] * rhs[3] + lhs[2] * rhs[0] + lhs[3] * rhs[1],
        lhs[0] * rhs[3] + lhs[1] * rhs[2] - lhs[2] * rhs[1] + lhs[3] * rhs[0],
    };
}

fn quaternionConjugate(quaternion: @Vector(4, f32)) @Vector(4, f32) {
    return .{ quaternion[0], -quaternion[1], -quaternion[2], -quaternion[3] };
}

fn dualQuaternionProduct(lhs: DualQuaternion, rhs: DualQuaternion) DualQuaternion {
    return .{
        .real = quaternionProduct(lhs.real, rhs.real),
        .dual = quaternionProduct(lhs.real, rhs.dual) + quaternionProduct(lhs.dual, rhs.real),
    };
}

fn dualQuaternionFromRotationTranslation(axis: @Vector(3, f32), angle: f32, translation: @Vector(3, f32)) DualQuaternion {
    const half_angle = angle / 2;
    const axis_scale = @sin(half_angle) / @sqrt(@reduce(.Add, axis * axis));
    const real: @Vector(4, f32) = .{ @cos(half_angle), axis[0] * axis_scale, axis[1] * axis_scale, axis[2] * axis_scale };
    return .{
        .real = real,
        .dual = quaternionProduct(.{ 0, translation[0], translation[1], translation[2] }, real) * @as(@Vector(4, f32), @splat(0.5)),
    };
}

fn transformPointByDualQuaternion(point: @Vector(3, f32), motor: DualQuaternion) @Vector(3, f32) {
    const conjugate = quaternionConjugate(motor.real);
    const rotated = quaternionProduct(quaternionProduct(motor.real, .{ 0, point[0], point[1], point[2] }), conjugate);
    const translation = quaternionProduct(motor.dual, conjugate) * @as(@Vector(4, f32), @splat(2));
    return .{ rotated[1] + translation[1], rotated[2] + translation[2], rotated[3] + translation[3] };
}

fn benchmarkVector3(io: std.Io, iterations: usize) u64 {
    const Vec3 = H3.Vector;
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
    var v = H2.exprAs(H2.Vector, "e1 + e2 / 2", .{});
    var angle: f32 = 0;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        angle += 0.0009;
        const r = ga.rotors.planarRotor(f32, angle);
        v = ga.rotors.rotated(v, r);
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

fn benchmarkRotatedByAngle2(io: std.Io, iterations: usize) u64 {
    var v = H2.exprAs(H2.Vector, "e1 + e2 / 2", .{});
    var angle: f32 = 0;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        angle += 0.0009;
        v = ga.rotors.rotatedByAngle(v, angle);
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

fn benchmarkRawRotor2(io: std.Io, iterations: usize) u64 {
    var v: @Vector(2, f32) = .{ 1.0, 0.5 };
    var angle: f32 = 0;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        angle += 0.0009;
        const sin = @sin(angle);
        const cos = @cos(angle);
        v = .{ cos * v[0] - sin * v[1], sin * v[0] + cos * v[1] };
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

fn benchmarkGenericRotor3(io: std.Io, iterations: usize) u64 {
    var v = cl3_benchmark_vector;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) v = cl3_benchmark_rotor.gp(v).gp(cl3_benchmark_rotor.reverse()).gradePart(1);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

fn benchmarkRotor3(io: std.Io, iterations: usize) u64 {
    var v = cl3_benchmark_vector;

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) v = ga.rotors.rotated(v, cl3_benchmark_rotor);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

fn benchmarkGenericPgaMotorComposition(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const displacement: @Vector(3, f32) = .{ 0.01, -0.02, 0.005 };
    const delta = P3.compose(P3.translator(displacement), P3.rotation(axis, 0.0009) catch unreachable);
    var motor = P3.compose(P3.translator(.{ 0.3, -0.2, 0.1 }), P3.rotation(axis, 0.7) catch unreachable);

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) motor = delta.gp(motor);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(motor);
    return elapsedNanos(start, end);
}

fn benchmarkPgaMotorComposition(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const displacement: @Vector(3, f32) = .{ 0.01, -0.02, 0.005 };
    const delta = P3.compose(P3.translator(displacement), P3.rotation(axis, 0.0009) catch unreachable);
    var motor = P3.compose(P3.translator(.{ 0.3, -0.2, 0.1 }), P3.rotation(axis, 0.7) catch unreachable);

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) motor = P3.compose(delta, motor);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(motor);
    return elapsedNanos(start, end);
}

fn benchmarkDualQuaternionComposition(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const delta = dualQuaternionFromRotationTranslation(axis, 0.0009, .{ 0.01, -0.02, 0.005 });
    var motor = dualQuaternionFromRotationTranslation(axis, 0.7, .{ 0.3, -0.2, 0.1 });

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) motor = dualQuaternionProduct(delta, motor);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(motor);
    return elapsedNanos(start, end);
}

fn benchmarkGenericPgaMotorPoint(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const motor = P3.compose(P3.translator(.{ 0.01, -0.02, 0.005 }), P3.rotation(axis, 0.0009) catch unreachable);
    var point = P3.point(.{ 1.0, 0.5, -0.25 });

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) point = motor.sandwichGrade(point, 3).cast(P3.Point);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(point);
    return elapsedNanos(start, end);
}

fn benchmarkPgaMotorPoint(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const motor = P3.compose(P3.translator(.{ 0.01, -0.02, 0.005 }), P3.rotation(axis, 0.0009) catch unreachable);
    var point = P3.point(.{ 1.0, 0.5, -0.25 });

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) point = P3.transformPoint(point, motor);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(point);
    return elapsedNanos(start, end);
}

fn benchmarkPreparedPgaMotorPoint(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const motor = P3.compose(P3.translator(.{ 0.01, -0.02, 0.005 }), P3.rotation(axis, 0.0009) catch unreachable);
    const action = P3.prepare(motor);
    var point = P3.point(.{ 1.0, 0.5, -0.25 });

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) point = action.transformPoint(point);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(point);
    return elapsedNanos(start, end);
}

fn benchmarkDualQuaternionPoint(io: std.Io, iterations: usize) u64 {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const motor = dualQuaternionFromRotationTranslation(axis, 0.0009, .{ 0.01, -0.02, 0.005 });
    var point: @Vector(3, f32) = .{ 1.0, 0.5, -0.25 };

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) point = transformPointByDualQuaternion(point, motor);
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(point);
    return elapsedNanos(start, end);
}

fn assertPgaMotorMatchesDualQuaternion() void {
    const axis: @Vector(3, f32) = .{ 0.2, -0.5, 0.46904158 };
    const translation: @Vector(3, f32) = .{ 0.3, -0.2, 0.1 };
    const motor = P3.compose(P3.translator(translation), P3.rotation(axis, 0.7) catch unreachable);
    const dual_quaternion = dualQuaternionFromRotationTranslation(axis, 0.7, translation);
    const transformed = P3.transformPoint(P3.point(.{ 1.0, 0.5, -0.25 }), motor);
    const expected = P3.point(transformPointByDualQuaternion(.{ 1.0, 0.5, -0.25 }, dual_quaternion));

    inline for (P3.Point.blades) |mask| {
        if (@abs(transformed.coeff(mask) - expected.coeff(mask)) > 1e-5) {
            @panic("PGA motor and dual quaternion transforms disagree");
        }
    }
}

fn benchmarkRawRotor3(io: std.Io, iterations: usize) u64 {
    const w: f32 = 0.7;
    const x: f32 = 0.2;
    const y: f32 = -0.5;
    const z: f32 = 0.46904158;
    const column_x: @Vector(3, f32) = .{
        w * w + x * x - y * y - z * z,
        2 * (x * y + w * z),
        2 * (x * z - w * y),
    };
    const column_y: @Vector(3, f32) = .{
        2 * (x * y - w * z),
        w * w - x * x + y * y - z * z,
        2 * (y * z + w * x),
    };
    const column_z: @Vector(3, f32) = .{
        2 * (x * z + w * y),
        2 * (y * z - w * x),
        w * w - x * x - y * y + z * z,
    };
    var v: @Vector(3, f32) = .{ 1.0, 0.5, -0.25 };

    const start = timestampNow(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        v = column_x * @as(@Vector(3, f32), @splat(v[0])) +
            column_y * @as(@Vector(3, f32), @splat(v[1])) +
            column_z * @as(@Vector(3, f32), @splat(v[2]));
    }
    const end = timestampNow(io);

    std.mem.doNotOptimizeAway(v);
    return elapsedNanos(start, end);
}

const Benchmark = enum {
    vec3,
    rotate2,
    rotor3,
    pga_compose,
    pga_point,
};

fn selectedBenchmark(init: std.process.Init) !?Benchmark {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const name = args.next() orelse return null;
    if (args.next() != null) return error.InvalidBenchmarkArguments;

    if (std.mem.eql(u8, name, "vec3")) return .vec3;
    if (std.mem.eql(u8, name, "rotate2")) return .rotate2;
    if (std.mem.eql(u8, name, "rotor3")) return .rotor3;
    if (std.mem.eql(u8, name, "pga-compose")) return .pga_compose;
    if (std.mem.eql(u8, name, "pga-point")) return .pga_point;
    return error.UnknownBenchmark;
}

fn printCase(stdout: *std.Io.Writer, label: []const u8, elapsed_ns: u64, iterations: usize) !void {
    try stdout.print("{s}: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        label,
        iterations,
        elapsed_ns,
        @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)),
    });
}

fn runSelectedBenchmark(init: std.process.Init, backend_name: []const u8, selected: Benchmark) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const vector_iterations: usize = 30_000_000;
    const rotor_iterations: usize = 20_000_000;

    try stdout.print("backend: {s}\n", .{backend_name});
    switch (selected) {
        .vec3 => {
            try printCase(stdout, "GA Vec3 add/sub/scale/dot", benchmarkVector3(io, vector_iterations), vector_iterations);
            try printCase(stdout, "Raw @Vector(3,f32)", benchmarkRawVector3(io, vector_iterations), vector_iterations);
        },
        .rotate2 => {
            try printCase(stdout, "GA planar 2D rotor", benchmarkRotor2(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "GA direct 2D rotation", benchmarkRotatedByAngle2(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "Raw 2D rotation", benchmarkRawRotor2(io, rotor_iterations), rotor_iterations);
        },
        .rotor3 => {
            try printCase(stdout, "GA generic Cl3 rotor", benchmarkGenericRotor3(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "GA fast Cl3 rotor", benchmarkRotor3(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "Raw SIMD Cl3 rotor matrix", benchmarkRawRotor3(io, rotor_iterations), rotor_iterations);
        },
        .pga_compose => {
            try printCase(stdout, "PGA generic motor compose", benchmarkGenericPgaMotorComposition(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "PGA fast motor compose", benchmarkPgaMotorComposition(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "Dual quaternion compose", benchmarkDualQuaternionComposition(io, rotor_iterations), rotor_iterations);
        },
        .pga_point => {
            try printCase(stdout, "PGA generic motor point transform", benchmarkGenericPgaMotorPoint(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "PGA fast motor point transform", benchmarkPgaMotorPoint(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "PGA prepared motor point transform", benchmarkPreparedPgaMotorPoint(io, rotor_iterations), rotor_iterations);
            try printCase(stdout, "Dual quaternion point transform", benchmarkDualQuaternionPoint(io, rotor_iterations), rotor_iterations);
        },
    }
    try stdout.flush();
}

pub fn run(init: std.process.Init, backend_name: []const u8) !void {
    if (try selectedBenchmark(init)) |selected| return runSelectedBenchmark(init, backend_name, selected);

    const io = init.io;
    assertPgaMotorMatchesDualQuaternion();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const vector_iterations: usize = 30_000_000;
    const rotor_iterations: usize = 20_000_000;

    const ga_vec_ns = benchmarkVector3(io, vector_iterations);
    const raw_vec_ns = benchmarkRawVector3(io, vector_iterations);
    const rotor_ns = benchmarkRotor2(io, rotor_iterations);
    const by_angle_ns = benchmarkRotatedByAngle2(io, rotor_iterations);
    const raw_rotor_ns = benchmarkRawRotor2(io, rotor_iterations);
    const generic_rotor3_ns = benchmarkGenericRotor3(io, rotor_iterations);
    const rotor3_ns = benchmarkRotor3(io, rotor_iterations);
    const raw_rotor3_ns = benchmarkRawRotor3(io, rotor_iterations);
    const generic_pga_motor_compose_ns = benchmarkGenericPgaMotorComposition(io, rotor_iterations);
    const pga_motor_compose_ns = benchmarkPgaMotorComposition(io, rotor_iterations);
    const dual_quaternion_compose_ns = benchmarkDualQuaternionComposition(io, rotor_iterations);
    const generic_pga_motor_point_ns = benchmarkGenericPgaMotorPoint(io, rotor_iterations);
    const pga_motor_point_ns = benchmarkPgaMotorPoint(io, rotor_iterations);
    const prepared_pga_motor_point_ns = benchmarkPreparedPgaMotorPoint(io, rotor_iterations);
    const dual_quaternion_point_ns = benchmarkDualQuaternionPoint(io, rotor_iterations);

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
    try stdout.print("GA planar 2D rotor: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        rotor_ns,
        @as(f64, @floatFromInt(rotor_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("GA direct 2D rotation: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        by_angle_ns,
        @as(f64, @floatFromInt(by_angle_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("Raw 2D rotation: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        raw_rotor_ns,
        @as(f64, @floatFromInt(raw_rotor_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("GA planar/raw rotor ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(rotor_ns)) / @as(f64, @floatFromInt(raw_rotor_ns)),
    });
    try stdout.print("GA direct/raw rotor ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(by_angle_ns)) / @as(f64, @floatFromInt(raw_rotor_ns)),
    });
    try stdout.print("GA generic Cl3 rotor: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        generic_rotor3_ns,
        @as(f64, @floatFromInt(generic_rotor3_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("GA fast Cl3 rotor: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        rotor3_ns,
        @as(f64, @floatFromInt(rotor3_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("Raw SIMD Cl3 rotor matrix: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        raw_rotor3_ns,
        @as(f64, @floatFromInt(raw_rotor3_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("GA generic/raw Cl3 rotor ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(generic_rotor3_ns)) / @as(f64, @floatFromInt(raw_rotor3_ns)),
    });
    try stdout.print("GA fast/raw Cl3 rotor ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(rotor3_ns)) / @as(f64, @floatFromInt(raw_rotor3_ns)),
    });
    try stdout.print("PGA generic motor compose: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        generic_pga_motor_compose_ns,
        @as(f64, @floatFromInt(generic_pga_motor_compose_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("PGA fast motor compose: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        pga_motor_compose_ns,
        @as(f64, @floatFromInt(pga_motor_compose_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("Dual quaternion compose: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        dual_quaternion_compose_ns,
        @as(f64, @floatFromInt(dual_quaternion_compose_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("PGA generic/DQ compose ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(generic_pga_motor_compose_ns)) / @as(f64, @floatFromInt(dual_quaternion_compose_ns)),
    });
    try stdout.print("PGA fast/DQ compose ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(pga_motor_compose_ns)) / @as(f64, @floatFromInt(dual_quaternion_compose_ns)),
    });
    try stdout.print("PGA generic motor point transform: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        generic_pga_motor_point_ns,
        @as(f64, @floatFromInt(generic_pga_motor_point_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("PGA fast motor point transform: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        pga_motor_point_ns,
        @as(f64, @floatFromInt(pga_motor_point_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("PGA prepared motor point transform: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        prepared_pga_motor_point_ns,
        @as(f64, @floatFromInt(prepared_pga_motor_point_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("Dual quaternion point transform: {} iters in {} ns ({d:.3} ns/iter)\n", .{
        rotor_iterations,
        dual_quaternion_point_ns,
        @as(f64, @floatFromInt(dual_quaternion_point_ns)) / @as(f64, @floatFromInt(rotor_iterations)),
    });
    try stdout.print("PGA generic/DQ point ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(generic_pga_motor_point_ns)) / @as(f64, @floatFromInt(dual_quaternion_point_ns)),
    });
    try stdout.print("PGA fast/DQ point ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(pga_motor_point_ns)) / @as(f64, @floatFromInt(dual_quaternion_point_ns)),
    });
    try stdout.print("PGA prepared/DQ point ratio: {d:.3}x\n", .{
        @as(f64, @floatFromInt(prepared_pga_motor_point_ns)) / @as(f64, @floatFromInt(dual_quaternion_point_ns)),
    });
    try stdout.flush();
}

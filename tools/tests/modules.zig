const std = @import("std");
const zmath = @import("zmath");

const constant_curvature = zmath.geometry.constant_curvature;
const spherical_game = zmath.geometry.spherical_game;

const StorageKind = enum { array, vector };

const CarrierShape = struct {
    layout: std.builtin.Type.ContainerLayout,
    field_count: usize,
    storage_kind: StorageKind,
    storage_type: type,
    coeff_type: type,
    coeff_count: usize,
    bit_size: usize,
    abi_size: usize,
    abi_align: usize,
};

fn gaCarrierShape(comptime Carrier: type) CarrierShape {
    const info = @typeInfo(Carrier).@"struct";
    if (info.fields.len != 1) {
        @compileError("expected GA carrier to have exactly one storage field");
    }

    const field = info.fields[0];
    if (!std.mem.eql(u8, field.name, "coeffs")) {
        @compileError("expected GA carrier storage field to be named coeffs");
    }

    const storage_kind: StorageKind, const coeff_type: type, const coeff_count: usize = switch (@typeInfo(field.type)) {
        .array => |array| .{ .array, array.child, array.len },
        .vector => |vector| .{ .vector, vector.child, vector.len },
        else => @compileError("expected GA carrier coeffs storage to be an array or vector"),
    };
    return .{
        .layout = info.layout,
        .field_count = info.fields.len,
        .storage_kind = storage_kind,
        .storage_type = field.type,
        .coeff_type = coeff_type,
        .coeff_count = coeff_count,
        .bit_size = @bitSizeOf(Carrier),
        .abi_size = @sizeOf(Carrier),
        .abi_align = @alignOf(Carrier),
    };
}

test "import geometry test modules" {
    _ = constant_curvature;
    _ = spherical_game;
    try std.testing.expect(true);
}

test "GA vector carriers are extern structs backed by Zig SIMD vectors" {
    const E2 = zmath.ga.Algebra(.euclidean(2)).Instantiate(f32);
    const E4 = zmath.ga.Algebra(.euclidean(4)).Instantiate(f32);

    try std.testing.expect(std.meta.eql(
        gaCarrierShape(E2.Vector),
        CarrierShape{
            .layout = .@"extern",
            .field_count = 1,
            .storage_kind = .vector,
            .storage_type = @Vector(2, f32),
            .coeff_type = f32,
            .coeff_count = 2,
            .bit_size = @sizeOf(@Vector(2, f32)) * 8,
            .abi_size = @sizeOf(@Vector(2, f32)),
            .abi_align = @alignOf(@Vector(2, f32)),
        },
    ));
    try std.testing.expect(std.meta.eql(
        gaCarrierShape(E4.Vector),
        CarrierShape{
            .layout = .@"extern",
            .field_count = 1,
            .storage_kind = .vector,
            .storage_type = @Vector(4, f32),
            .coeff_type = f32,
            .coeff_count = 4,
            .bit_size = @sizeOf(@Vector(4, f32)) * 8,
            .abi_size = @sizeOf(@Vector(4, f32)),
            .abi_align = @alignOf(@Vector(4, f32)),
        },
    ));
}

test "GA vector carriers remain wrappers around Zig SIMD vector storage" {
    const E2 = zmath.ga.Algebra(.euclidean(2)).Instantiate(f32);
    const Simd2 = @Vector(2, f32);

    try std.testing.expect(@typeInfo(E2.Vector) == .@"struct");
    try std.testing.expect(@typeInfo(Simd2) == .vector);
    try std.testing.expect(!std.meta.eql(@typeInfo(E2.Vector), @typeInfo(Simd2)));

    try std.testing.expectEqual(@bitSizeOf(E2.Vector.Storage), @bitSizeOf(Simd2));
    try std.testing.expect(@sizeOf(E2.Vector.Storage) <= @sizeOf(Simd2));
    try std.testing.expect(@alignOf(E2.Vector.Storage) <= @alignOf(Simd2));

    const carrier = E2.Vector.init(.{ 1.25, -2.5 });
    const lanes: Simd2 = @bitCast(carrier.coeffs);
    try std.testing.expectEqual(@as(f32, 1.25), lanes[0]);
    try std.testing.expectEqual(@as(f32, -2.5), lanes[1]);

    const roundtrip = E2.Vector.init(@bitCast(lanes));
    try std.testing.expectEqual(carrier.coeffs, roundtrip.coeffs);
}

test "constant curvature conformal embeddings round-trip through GA helpers" {
    const sample = constant_curvature.Vec3{ .x = 0.4, .y = -0.2, .z = 0.7 };
    inline for (.{ constant_curvature.Metric.spherical, constant_curvature.Metric.hyperbolic }) |metric| {
        const raw = constant_curvature.embedConformal(metric, 5.0, sample).?;
        const ga = constant_curvature.embedConformalGa(metric, 5.0, sample).?;
        inline for (raw.asArray(), ga.asArray()) |lhs, rhs| {
            try std.testing.expectApproxEqAbs(lhs, rhs, 1e-6);
        }
    }
}

test "constant curvature projective embeddings match the GA proper point helpers" {
    const sample = constant_curvature.Vec3{ .x = 0.3, .y = -0.4, .z = 0.8 };
    inline for (.{ constant_curvature.Metric.spherical, constant_curvature.Metric.hyperbolic }) |metric| {
        const raw = constant_curvature.embedProjective(metric, 4.0, sample).?;
        const ga = constant_curvature.embedProjectiveGa(metric, 4.0, sample).?;
        inline for (raw.asArray(), ga.asArray()) |lhs, rhs| {
            try std.testing.expectApproxEqAbs(lhs, rhs, 1e-6);
        }
    }
}

test "constant curvature camera frames are tangent and orthonormal" {
    inline for (.{ constant_curvature.Metric.spherical, constant_curvature.Metric.hyperbolic }) |metric| {
        const frame = constant_curvature.frameFromChart(metric, 8.0, .{ .x = 0.2, .y = 0.5, .z = -1.1 }, 0.35, 0.2).?;
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), constant_curvature.dot(metric, frame.origin, frame.right), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), constant_curvature.dot(metric, frame.origin, frame.up), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), constant_curvature.dot(metric, frame.origin, frame.forward), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), constant_curvature.dot(metric, frame.right, frame.right), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), constant_curvature.dot(metric, frame.up, frame.up), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), constant_curvature.dot(metric, frame.forward, frame.forward), 1e-4);
    }
}

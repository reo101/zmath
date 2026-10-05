const std = @import("std");
const zmath = @import("zmath");

const constant_curvature = zmath.geometry.constant_curvature;
const spherical_game = zmath.geometry.spherical_game;

const StorageKind = enum { array, vector };

const CarrierShape = struct {
    layout: std.lang.Type.ContainerLayout,
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
    if (info.field_names.len != 1) {
        @compileError("expected GA carrier to have exactly one storage field");
    }

    const field_type = info.field_types[0];
    if (!std.mem.eql(u8, info.field_names[0], "coeffs")) {
        @compileError("expected GA carrier storage field to be named coeffs");
    }

    const storage_kind: StorageKind, const coeff_type: type, const coeff_count: usize = switch (@typeInfo(field_type)) {
        .array => |array| .{ .array, array.child, array.len },
        .vector => |vector| .{ .vector, vector.child, vector.len },
        else => @compileError("expected GA carrier coeffs storage to be an array or vector"),
    };
    return .{
        .layout = info.layout,
        .field_count = info.field_names.len,
        .storage_kind = storage_kind,
        .storage_type = field_type,
        .coeff_type = coeff_type,
        .coeff_count = coeff_count,
        .bit_size = @sizeOf(Carrier) * 8,
        .abi_size = @sizeOf(Carrier),
        .abi_align = @alignOf(Carrier),
    };
}

test "import geometry test modules" {
    _ = constant_curvature;
    _ = spherical_game;
    try std.testing.expect(true);
}

test "native GA vector carriers are aligned extern structs backed by arrays" {
    const E2 = zmath.ga.Algebra(.euclidean(2)).Instantiate(f32);
    const E4 = zmath.ga.Algebra(.euclidean(4)).Instantiate(f32);

    try std.testing.expect(std.meta.eql(
        gaCarrierShape(E2.Vector),
        CarrierShape{
            .layout = .@"extern",
            .field_count = 1,
            .storage_kind = .array,
            .storage_type = [2]f32,
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
            .storage_kind = .array,
            .storage_type = [4]f32,
            .coeff_type = f32,
            .coeff_count = 4,
            .bit_size = @sizeOf(@Vector(4, f32)) * 8,
            .abi_size = @sizeOf(@Vector(4, f32)),
            .abi_align = @alignOf(@Vector(4, f32)),
        },
    ));
}

test "native GA vector carriers match raw vector size, alignment, and coefficient bytes" {
    inline for (2..5) |dimensions| {
        const Carrier = zmath.ga.Algebra(.euclidean(dimensions)).Instantiate(f32).Vector;
        const Raw = @Vector(dimensions, f32);
        try std.testing.expect(Carrier.use_simd);
        try std.testing.expectEqual(@sizeOf(Raw), @sizeOf(Carrier));
        try std.testing.expectEqual(@alignOf(Raw), @alignOf(Carrier));

        var coefficients: [dimensions]f32 = undefined;
        inline for (0..dimensions) |i| coefficients[i] = @as(f32, @floatFromInt(i)) - 1.25;
        const carrier = Carrier.init(coefficients);
        const raw: Raw = coefficients;
        const coefficient_bytes = dimensions * @sizeOf(f32);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&raw)[0..coefficient_bytes], std.mem.asBytes(&carrier)[0..coefficient_bytes]);
    }
}

test "GA carriers support comptime construction and scalar arithmetic" {
    const E4 = zmath.ga.Algebra(.euclidean(4)).Instantiate(f32);
    const normal = comptime E4.Basis.e(3).cast(E4.Vector).scale(2.0).divide(2.0).negate().negate();
    try std.testing.expectEqual([4]f32{ 0.0, 0.0, 1.0, 0.0 }, normal.coeffs);
    try std.testing.expect(comptime normal.eql(normal.add(normal).sub(normal)));
    try std.testing.expectEqual(@as(f32, 1.0), comptime normal.scalarProduct(normal));
    try std.testing.expectEqual([3]f32{ 1.0, 0.0, 0.0 }, comptime normal.swizzleVector("zyx").coeffs);

    const H = zmath.ga.Algebra(.{ .p = 2, .q = 1 }).Instantiate(f32);
    const signed = comptime H.Vector.init(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(f32, -4.0), comptime signed.scalarProduct(signed));
}

test "native GA vector carriers retain SIMD lane conversions" {
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

test "permuted full carrier lookups follow declared blade order" {
    const E1 = zmath.ga.Algebra(.euclidean(1)).Instantiate(f32);
    const Permuted = E1.Multivector(&.{ .init(1), .init(0) });
    const value = comptime Permuted.init(.{ 7, 3 });
    try std.testing.expect(Permuted.has_all_blades);
    try std.testing.expectEqual(@as(f32, 3), value.scalarCoeff());
    try std.testing.expectEqual(@as(f32, 7), value.coeff(.init(1)));
    try std.testing.expectEqual(value.coeffNamed("e1"), value.basisCoeff(1));
    try std.testing.expectEqual(value.coeffNamed("e1"), value.coeff(.init(1)));
    try std.testing.expectEqual(@as(f32, 3), comptime value.scalarCoeff());
    try std.testing.expectEqual(@as(f32, 7), comptime value.coeff(.init(1)));

    var updated = value;
    try updated.setCoeffOrError(.init(0), 5);
    try std.testing.expectEqual(@as(f32, 5), updated.scalarCoeff());
    try std.testing.expectEqual(@as(f32, 7), updated.coeff(.init(1)));
}

test "permuted full carrier operations match canonical references" {
    const E2 = zmath.ga.Algebra(.euclidean(2)).Instantiate(f32);
    const reference = comptime E2.Full.init(.{ 1, 2, 3, 4 });
    const other = comptime E2.Full.init(.{ 4, 3, 2, 1 });
    inline for (comptime .{
        &[_]zmath.ga.blades.BladeMask{ .init(3), .init(2), .init(1), .init(0) },
        &[_]zmath.ga.blades.BladeMask{ .init(2), .init(0), .init(3), .init(1) },
    }) |masks| {
        const Permuted = E2.Multivector(masks);
        const value = comptime reference.cast(Permuted);
        const rhs = comptime other.cast(Permuted);
        try std.testing.expect(value.eql(reference));
        inline for (E2.Full.blades) |mask| {
            try std.testing.expectEqual(reference.coeff(mask), value.coeff(mask));
        }
        try std.testing.expectEqualSlices(f32, &reference.coeffs, &value.cast(E2.Full).coeffs);
        try std.testing.expect(value.castExact(E2.Full).eql(reference));
        try std.testing.expect(value.gradePart(1).eql(reference.gradePart(1)));
        try std.testing.expect(value.reverse().eql(reference.reverse()));
        try std.testing.expect(value.gp(rhs).eql(reference.gp(other)));
        try std.testing.expect(value.wedge(rhs).eql(reference.wedge(other)));
        try std.testing.expectEqual(reference.scalarProduct(other), value.scalarProduct(rhs));
        try std.testing.expect(value.add(rhs).eql(reference.add(other)));
        try std.testing.expect(value.sub(rhs).eql(reference.sub(other)));
        try std.testing.expect((comptime value.add(rhs)).eql(reference.add(other)));
        try std.testing.expect((comptime value.sub(rhs)).eql(reference.sub(other)));
        try std.testing.expect(value.add(other).eql(reference.add(other)));
        try std.testing.expect(value.sub(other).eql(reference.sub(other)));
    }
}

test "swizzled carrier arithmetic preserves basis coefficients at runtime and comptime" {
    inline for (comptime .{ zmath.ga.MetricSignature.euclidean(3), zmath.ga.MetricSignature{ .p = 2, .q = 1 } }) |signature| {
        const Algebra = zmath.ga.Algebra(signature).Instantiate(f32);
        const vector = comptime Algebra.Vector.init(.{ 1, 2, 3 });
        inline for (.{ "xyz", "xzy", "yxz", "yzx", "zxy", "zyx", "zy", "yx", "xz", "zx" }) |pattern| {
            const value = comptime vector.swizzleVector(pattern);
            const reference = value.cast(Algebra.Vector);
            const expected_sum = reference.scale(2);
            const expected_difference = reference.scale(0.75);
            try std.testing.expect(value.add(value).eql(expected_sum));
            try std.testing.expect(value.sub(value.scale(0.25)).eql(expected_difference));
            try std.testing.expect((comptime value.add(value)).eql(expected_sum));
            try std.testing.expect((comptime value.sub(value.scale(0.25))).eql(expected_difference));
            try std.testing.expect(value.add(reference).eql(expected_sum));
            try std.testing.expect(value.sub(reference.scale(0.25)).eql(expected_difference));
            try std.testing.expectEqual(reference.scalarProduct(reference), value.scalarProduct(value));
            try std.testing.expect(value.gp(value).eql(reference.gp(reference)));
            try std.testing.expect(value.gradePart(1).eql(reference));
        }
    }
}

test "same metric carriers with different naming remain compatible" {
    const E2 = zmath.ga.Algebra(.euclidean(2)).Instantiate(f32);
    const naming = comptime zmath.ga.NamingOptions.withBasisNames(.fromSignature(.euclidean(2)), .{ "u", "v" });
    const Named = zmath.ga.AlgebraWithNamingOptions(.euclidean(2), naming).Instantiate(f32);
    const lhs = E2.Vector.init(.{ 1, 2 });
    const rhs = Named.Vector.init(.{ 3, 4 });
    try std.testing.expectEqual(@as(f32, 4), lhs.add(rhs).coeffNamed("e1"));
    try std.testing.expectEqual(@as(f32, 6), lhs.add(rhs).coeffNamed("e2"));
    try std.testing.expectEqual(@as(f32, 11), lhs.gp(rhs).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 11), lhs.scalarProduct(rhs));
    try std.testing.expect(lhs.eql(Named.Vector.init(.{ 1, 2 })));
}

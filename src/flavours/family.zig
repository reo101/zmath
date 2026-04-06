const std = @import("std");
const ga = @import("../ga.zig");

pub fn withNamingOptions(
    comptime metric_sig: ga.MetricSignature,
    comptime naming_opts: ga.SignedBladeNamingOptions,
) type {
    return struct {
        pub const signature = metric_sig;
        pub const metric_signature = metric_sig;
        pub const dimension = metric_sig.dimension();
        pub const naming_options = naming_opts;
        pub const Algebra = ga.AlgebraWithNamingOptions(metric_sig, naming_opts);

        pub fn Instantiate(comptime T: type) type {
            return Algebra.Instantiate(T);
        }
    };
}

pub fn withBasisSpans(
    comptime metric_signature: ga.MetricSignature,
    comptime basis_spans: ga.BasisIndexSpans,
) type {
    return withNamingOptions(metric_signature, ga.SignedBladeNamingOptions.withBasisSpans(basis_spans));
}

pub fn euclidean(comptime dimensions: usize) type {
    return withNamingOptions(
        ga.euclideanSignature(dimensions),
        ga.SignedBladeNamingOptions.euclidean(dimensions),
    );
}

pub fn defaultBindings(comptime DefaultFamily: type, comptime DefaultScalar: type) type {
    return struct {
        pub const Family = DefaultFamily;
        pub const default_scalar = DefaultScalar;
        pub const Algebra = Family.Algebra;

        pub fn Instantiate(comptime T: type) type {
            return Family.Instantiate(T);
        }

        pub const h = Instantiate(DefaultScalar);
    };
}

test "family builder exposes named algebra metadata" {
    const Family = withBasisSpans(
        .{ .p = 2, .q = 1, .r = 0 },
        ga.BasisIndexSpans.init(.{
            .positive = .range(1, 2),
            .negative = .singleton(0),
        }),
    );
    const H = Family.Instantiate(f32);

    try std.testing.expectEqual(@as(usize, 3), Family.dimension);
    try std.testing.expectEqual(@as(f32, -1.0), H.Basis.e(0).gp(H.Basis.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), H.Basis.e(1).gp(H.Basis.e(1)).scalarCoeff());
}

test "euclidean family builder matches default euclidean naming" {
    const E4 = euclidean(4).Instantiate(f32);
    const v = E4.Vector.init(.{ 1, 2, 3, 4 });

    try std.testing.expectEqual(@as(usize, 4), euclidean(4).dimension);
    try std.testing.expectEqual(@as(f32, 4.0), v.coeffNamed("e4"));
}

test "default bindings expose a canonical family surface" {
    const Bindings = defaultBindings(euclidean(3), f32);
    const E3 = Bindings.Instantiate(f32);
    const v = E3.Vector.init(.{ 1, 2, 3 });

    try std.testing.expectEqual(@as(usize, 3), Bindings.Family.dimension);
    try std.testing.expectEqual(@as(f32, 3.0), v.coeffNamed("e3"));
}

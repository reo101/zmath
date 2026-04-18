const std = @import("std");
const ga = @import("../ga.zig");
const blades = ga.blades;
const blade_parsing = ga.blade_parsing;

pub fn withNamingOptions(
    comptime metric_sig: blades.MetricSignature,
    comptime naming_opts: blade_parsing.SignedBladeNamingOptions,
) type {
    return struct {
        pub const signature = metric_sig;
        pub const metric_signature = metric_sig;
        pub const dimensions = metric_sig.dimensions();
        pub const naming_options = naming_opts;
        pub const Algebra = ga.AlgebraWithNamingOptions(metric_sig, naming_opts);

        pub fn Instantiate(comptime T: type) type {
            return Algebra.Instantiate(T);
        }
    };
}

pub fn withBasisSpans(
    comptime metric_signature: blades.MetricSignature,
    comptime basis_spans: blades.BasisIndexSpans,
) type {
    return withNamingOptions(metric_signature, blade_parsing.SignedBladeNamingOptions.withBasisSpans(basis_spans));
}

pub fn euclidean(comptime dimensions: usize) type {
    return withNamingOptions(
        ga.euclideanSignature(dimensions),
        blade_parsing.SignedBladeNamingOptions.euclidean(dimensions),
    );
}

fn homogeneousSpans(
    comptime first_positive_index: usize,
    comptime positive_dimensions: usize,
    comptime negative_index: ?usize,
    comptime degenerate_index: ?usize,
) blades.BasisIndexSpans {
    return blades.BasisIndexSpans.init(.{
        .positive = if (positive_dimensions == 0) null else .range(first_positive_index, first_positive_index + positive_dimensions - 1),
        .negative = if (negative_index) |index| .singleton(index) else null,
        .degenerate = if (degenerate_index) |index| .singleton(index) else null,
    });
}

pub fn minkowski(comptime positive_dimensions: usize, comptime negative_dimensions: usize) type {
    return withBasisSpans(
        .{ .p = positive_dimensions, .q = negative_dimensions, .r = 0 },
        blades.BasisIndexSpans.init(.{
            .positive = if (positive_dimensions == 0) null else .range(0, positive_dimensions - 1),
            .negative = if (negative_dimensions == 0) null else .range(positive_dimensions, positive_dimensions + negative_dimensions - 1),
        }),
    );
}

pub fn projectiveEuclidean(comptime euclidean_dimensions: usize) type {
    return withBasisSpans(
        .{ .p = euclidean_dimensions, .q = 0, .r = 1 },
        homogeneousSpans(1, euclidean_dimensions, null, 0),
    );
}

pub fn projectiveHyperbolic(comptime euclidean_dimensions: usize) type {
    return withBasisSpans(
        .{ .p = euclidean_dimensions, .q = 1, .r = 0 },
        homogeneousSpans(1, euclidean_dimensions, 0, null),
    );
}

pub fn projectiveElliptic(comptime euclidean_dimensions: usize) type {
    return withBasisSpans(
        .{ .p = euclidean_dimensions + 1, .q = 0, .r = 0 },
        homogeneousSpans(0, euclidean_dimensions + 1, null, null),
    );
}

pub fn conformalEuclidean(comptime euclidean_dimensions: usize) type {
    return withBasisSpans(
        .{ .p = euclidean_dimensions + 1, .q = 1, .r = 0 },
        homogeneousSpans(1, euclidean_dimensions + 1, euclidean_dimensions + 2, null),
    );
}

pub fn defaultBindings(comptime DefaultFamily: type, comptime DefaultScalar: type) type {
    return struct {
        pub const Family = DefaultFamily;
        pub const default_scalar = DefaultScalar;
        pub const metric_signature = Family.metric_signature;
        pub const dimensions = Family.dimensions;
        pub const naming_options = Family.naming_options;
        pub const Algebra = Family.Algebra;

        pub fn Instantiate(comptime T: type) type {
            return Family.Instantiate(T);
        }

        pub fn resolveNamedBasisIndex(comptime named_index: usize) usize {
            return comptime blade_parsing.resolveNamedBasisIndex(named_index, dimensions, naming_options, true);
        }

        pub const h = Instantiate(DefaultScalar);
    };
}

test "family builder exposes named algebra metadata" {
    const Family = withBasisSpans(
        .{ .p = 2, .q = 1, .r = 0 },
        blades.BasisIndexSpans.init(.{
            .positive = .range(1, 2),
            .negative = .singleton(0),
        }),
    );
    const H = Family.Instantiate(f32);

    try std.testing.expectEqual(@as(usize, 3), Family.dimensions);
    try std.testing.expectEqual(@as(f32, -1.0), H.Basis.e(0).gp(H.Basis.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), H.Basis.e(1).gp(H.Basis.e(1)).scalarCoeff());
}

test "euclidean family builder matches default euclidean naming" {
    const E4 = euclidean(4).Instantiate(f32);
    const v = E4.Vector.init(.{ 1, 2, 3, 4 });

    try std.testing.expectEqual(@as(usize, 4), euclidean(4).dimensions);
    try std.testing.expectEqual(@as(f32, 4.0), v.coeffNamed("e4"));
}

test "default bindings expose a canonical family surface" {
    const Bindings = defaultBindings(euclidean(3), f32);
    const E3 = Bindings.Instantiate(f32);
    const v = E3.Vector.init(.{ 1, 2, 3 });

    try std.testing.expectEqual(@as(usize, 3), Bindings.Family.dimensions);
    try std.testing.expectEqual(@as(f32, 3.0), v.coeffNamed("e3"));
}

test "minkowski family exposes split basis spans" {
    const M22 = minkowski(2, 2).Instantiate(f32);

    try std.testing.expectEqual(@as(usize, 4), minkowski(2, 2).dimensions);
    try std.testing.expectEqual(@as(f32, 1.0), M22.Basis.e(0).gp(M22.Basis.e(0)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), M22.Basis.e(1).gp(M22.Basis.e(1)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), M22.Basis.e(2).gp(M22.Basis.e(2)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), M22.Basis.e(3).gp(M22.Basis.e(3)).scalarCoeff());
}

test "projective families expose expected homogeneous coordinates" {
    const P3 = projectiveEuclidean(3).Instantiate(f32);
    const H3 = projectiveHyperbolic(3).Instantiate(f32);
    const E3 = projectiveElliptic(3).Instantiate(f32);
    const C3 = conformalEuclidean(3).Instantiate(f32);

    try std.testing.expectEqual(@as(f32, 0.0), P3.Basis.basisVectorByClass(.degenerate, 1).gp(P3.Basis.basisVectorByClass(.degenerate, 1)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), H3.Basis.basisVectorByClass(.negative, 1).gp(H3.Basis.basisVectorByClass(.negative, 1)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1.0), E3.Basis.basisVectorByClass(.positive, 1).gp(E3.Basis.basisVectorByClass(.positive, 1)).scalarCoeff());
    try std.testing.expectEqual(@as(f32, -1.0), C3.Basis.basisVectorByClass(.negative, 1).gp(C3.Basis.basisVectorByClass(.negative, 1)).scalarCoeff());
}

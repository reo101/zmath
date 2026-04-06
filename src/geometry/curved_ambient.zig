const std = @import("std");
const ga = @import("../ga.zig");

pub const Coords4 = [4]f32;
pub const Flat3 = ga.Algebra(.euclidean(3)).Instantiate(f32);

fn AmbientFamily(
    comptime metric_signature: ga.MetricSignature,
    comptime naming_options_value: ga.SignedBladeNamingOptions,
) type {
    return struct {
        pub const naming_options = naming_options_value;
        pub const Algebra = ga.AlgebraWithNamingOptions(metric_signature, naming_options).Instantiate(f32);
        pub const Vector = Algebra.Vector;

        pub const Camera = struct {
            position: Vector,
            right: Vector,
            up: Vector,
            forward: Vector,
        };

        pub fn fromCoords(coords: Coords4) Vector {
            const E = Algebra.Basis;
            return E.e(0).scale(coords[0])
                .add(E.e(1).scale(coords[1]))
                .add(E.e(2).scale(coords[2]))
                .add(E.e(3).scale(coords[3]));
        }

        pub fn identity() Vector {
            return fromCoords(.{ 1.0, 0.0, 0.0, 0.0 });
        }

        pub fn toCoords(v: Vector) Coords4 {
            return .{
                @floatCast(v.coeffNamedWithOptions("e0", naming_options)),
                @floatCast(v.coeffNamedWithOptions("e1", naming_options)),
                @floatCast(v.coeffNamedWithOptions("e2", naming_options)),
                @floatCast(v.coeffNamedWithOptions("e3", naming_options)),
            };
        }

        pub fn add(a: Vector, b: Vector) Vector {
            return a.add(b);
        }

        pub fn sub(a: Vector, b: Vector) Vector {
            return a.sub(b);
        }

        pub fn scale(v: Vector, s: f32) Vector {
            return v.scale(s);
        }

        pub fn dot(a: Vector, b: Vector) f32 {
            return a.scalarProduct(b);
        }

        pub fn w(v: Vector) f32 {
            return toCoords(v)[0];
        }

        pub fn x(v: Vector) f32 {
            return toCoords(v)[1];
        }

        pub fn y(v: Vector) f32 {
            return toCoords(v)[2];
        }

        pub fn z(v: Vector) f32 {
            return toCoords(v)[3];
        }

        pub fn isFinite(v: Vector) bool {
            inline for (toCoords(v)) |component| {
                if (!std.math.isFinite(component)) return false;
            }
            return true;
        }
    };
}

pub const Hyper = AmbientFamily(
    .{ .p = 3, .q = 1, .r = 0 },
    ga.SignedBladeNamingOptions.withBasisSpans(ga.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .negative = .singleton(0),
    })),
);

pub const Round = AmbientFamily(
    .{ .p = 4, .q = 0, .r = 0 },
    ga.SignedBladeNamingOptions.withBasisSpans(ga.BasisIndexSpans.init(.{
        .positive = .range(0, 3),
    })),
);

fn expectCoordsApproxEq(expected: Coords4, actual: Coords4, tolerance: f32) !void {
    inline for (expected, actual) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, tolerance);
    }
}

test "hyper ambient coords round-trip through typed GA vectors" {
    const coords: Coords4 = .{ 1.25, -0.5, 0.75, 2.0 };
    try expectCoordsApproxEq(coords, Hyper.toCoords(Hyper.fromCoords(coords)), 1e-6);
}

test "round ambient coords round-trip through typed GA vectors" {
    const coords: Coords4 = .{ 0.25, -1.0, 0.5, 1.75 };
    try expectCoordsApproxEq(coords, Round.toCoords(Round.fromCoords(coords)), 1e-6);
}

test "ambient signatures keep their scalar products distinct" {
    const a: Coords4 = .{ 1.0, 2.0, -1.0, 0.5 };
    const b: Coords4 = .{ -0.25, 0.5, 3.0, 1.0 };

    try std.testing.expectApproxEqAbs(@as(f32, -1.75), Round.dot(Round.fromCoords(a), Round.fromCoords(b)), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.25), Hyper.dot(Hyper.fromCoords(a), Hyper.fromCoords(b)), 1e-6);
}

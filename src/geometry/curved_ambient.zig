const std = @import("std");
const ga = @import("../ga.zig");
const blades = ga.blades;
const blade_parsing = ga.blade_parsing;

pub const Coords4 = struct {
    w: f32,
    x: f32,
    y: f32,
    z: f32,

    pub fn init(values: anytype) Coords4 {
        return coerceCoords4(values);
    }

    pub fn asArray(self: Coords4) [4]f32 {
        return .{ self.w, self.x, self.y, self.z };
    }
};

fn coerceCoords4(values: anytype) Coords4 {
    const T = @TypeOf(values);
    if (T == Coords4) return values;

    return switch (@typeInfo(T)) {
        .array => |array| blk: {
            if (array.len != 4) @compileError("expected 4 ambient coordinates");
            break :blk .{
                .w = values[0],
                .x = values[1],
                .y = values[2],
                .z = values[3],
            };
        },
        .vector => |vector| blk: {
            if (vector.len != 4) @compileError("expected 4 ambient coordinates");
            break :blk .{
                .w = values[0],
                .x = values[1],
                .y = values[2],
                .z = values[3],
            };
        },
        .@"struct" => |struct_info| blk: {
            if (!struct_info.is_tuple or struct_info.fields.len != 4) {
                @compileError("expected a 4-tuple or `Coords4`");
            }
            break :blk .{
                .w = values[0],
                .x = values[1],
                .y = values[2],
                .z = values[3],
            };
        },
        else => @compileError("expected `Coords4`-compatible ambient coordinates"),
    };
}

pub const Flat3 = ga.Algebra(.euclidean(3)).Instantiate(f32);

fn AmbientFamily(
    comptime metric_signature: blades.MetricSignature,
    comptime naming_options_value: blade_parsing.SignedBladeNamingOptions,
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

        pub fn fromCoords(coords_input: anytype) Vector {
            const coords = coerceCoords4(coords_input);
            const E = Algebra.Basis;
            return E.e(0).scale(coords.w)
                .add(E.e(1).scale(coords.x))
                .add(E.e(2).scale(coords.y))
                .add(E.e(3).scale(coords.z));
        }

        pub fn identity() Vector {
            return fromCoords(.{ 1.0, 0.0, 0.0, 0.0 });
        }

        pub fn toCoords(v: Vector) Coords4 {
            const n = v.named();
            return .{
                n.e0,
                n.e1,
                n.e2,
                n.e3,
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
            return v.named().e0;
        }

        pub fn x(v: Vector) f32 {
            return v.named().e1;
        }

        pub fn y(v: Vector) f32 {
            return v.named().e2;
        }

        pub fn z(v: Vector) f32 {
            return v.named().e3;
        }

        pub fn isFinite(v: Vector) bool {
            inline for (v.coeffs) |component| {
                if (!std.math.isFinite(component)) return false;
            }
            return true;
        }
    };
}

pub const Hyper = AmbientFamily(
    .{ .p = 3, .q = 1, .r = 0 },
    blade_parsing.SignedBladeNamingOptions.withBasisSpans(blades.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .negative = .singleton(0),
    })),
);

pub const Round = AmbientFamily(
    .{ .p = 4, .q = 0, .r = 0 },
    blade_parsing.SignedBladeNamingOptions.withBasisSpans(blades.BasisIndexSpans.init(.{
        .positive = .range(0, 3),
    })),
);

fn expectCoordsApproxEq(expected: Coords4, actual: Coords4, tolerance: f32) !void {
    inline for (expected.asArray(), actual.asArray()) |lhs, rhs| {
        try std.testing.expectApproxEqAbs(lhs, rhs, tolerance);
    }
}

test "hyper ambient coords round-trip through typed GA vectors" {
    const coords = Coords4.init(.{ 1.25, -0.5, 0.75, 2.0 });
    try expectCoordsApproxEq(coords, Hyper.toCoords(Hyper.fromCoords(coords)), 1e-6);
}

test "round ambient coords round-trip through typed GA vectors" {
    const coords = Coords4.init(.{ 0.25, -1.0, 0.5, 1.75 });
    try expectCoordsApproxEq(coords, Round.toCoords(Round.fromCoords(coords)), 1e-6);
}

test "ambient signatures keep their scalar products distinct" {
    const a = Coords4.init(.{ 1.0, 2.0, -1.0, 0.5 });
    const b = Coords4.init(.{ -0.25, 0.5, 3.0, 1.0 });

    try std.testing.expectApproxEqAbs(@as(f32, -1.75), Round.dot(Round.fromCoords(a), Round.fromCoords(b)), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.25), Hyper.dot(Hyper.fromCoords(a), Hyper.fromCoords(b)), 1e-6);
}

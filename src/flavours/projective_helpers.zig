const ga = @import("../ga.zig");

pub const RoundMetric = enum {
    hyperbolic,
    elliptic,
};

pub fn initHomogeneousPoint3(comptime H: type, w: anytype, x: anytype, y: anytype, z: anytype) H.Full {
    return H.exprAs(
        H.Full,
        "{w}*e123 + {x}*e320 + {y}*e130 + {z}*e210",
        .{ .w = w, .x = x, .y = y, .z = z },
    );
}

pub fn initPoint3(comptime H: type, x: anytype, y: anytype, z: anytype) H.Full {
    const T = @TypeOf(x + y + z);
    const one: T = 1.0;
    return initHomogeneousPoint3(H, one, x, y, z);
}

pub fn direction3(comptime H: type, x: anytype, y: anytype, z: anytype) H.Full {
    return H.exprAs(H.Full, "{x}*e_2_3_0 + {y}*e_3_1_0 + {z}*e_1_2_0", .{ .x = x, .y = y, .z = z });
}

pub fn properHyperbolicPoint3(comptime H: type, x: anytype, y: anytype, z: anytype) ?H.Full {
    const T = @TypeOf(x + y + z);
    const r2: T = x * x + y * y + z * z;
    if (r2 >= 1.0) return null;

    const inv = 1.0 / @sqrt(1.0 - r2);
    return initHomogeneousPoint3(H, inv, x * inv, y * inv, z * inv);
}

pub fn properEllipticPoint3(comptime H: type, x: anytype, y: anytype, z: anytype) H.Full {
    const T = @TypeOf(x + y + z);
    const inv: T = 1.0 / @sqrt(1.0 + x * x + y * y + z * z);
    return initHomogeneousPoint3(H, inv, x * inv, y * inv, z * inv);
}

pub fn ambientCoords3(comptime T: type, comptime naming_options: ga.blade_parsing.SignedBladeNamingOptions, p: anytype) [4]T {
    ga.multivector.ensureMultivector(@TypeOf(p));
    return .{
        @floatCast(p.coeffNamedWithOptions("e123", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e320", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e130", naming_options)),
        @floatCast(p.coeffNamedWithOptions("e210", naming_options)),
    };
}

pub fn RoundProjectiveHelpers(
    comptime T: type,
    comptime H: type,
    comptime naming_options: ga.blade_parsing.SignedBladeNamingOptions,
    comptime metric: RoundMetric,
) type {
    return struct {
        pub const h = H;

        pub const Point = struct {
            pub fn initHomogeneous(w: T, x: T, y: T, z: T) H.Full {
                return initHomogeneousPoint3(H, w, x, y, z);
            }

            pub fn init(x: T, y: T, z: T) H.Full {
                return initPoint3(H, x, y, z);
            }

            pub fn proper(
                x: T,
                y: T,
                z: T,
            ) switch (metric) {
                .hyperbolic => ?H.Full,
                .elliptic => H.Full,
            } {
                return switch (metric) {
                    .hyperbolic => properHyperbolicPoint3(H, x, y, z),
                    .elliptic => properEllipticPoint3(H, x, y, z),
                };
            }
        };

        pub fn ambientCoords(p: anytype) [4]T {
            return ambientCoords3(T, naming_options, p);
        }
    };
}

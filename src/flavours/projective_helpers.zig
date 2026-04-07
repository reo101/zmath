const ga = @import("../ga.zig");

pub const RoundMetric = enum {
    hyperbolic,
    elliptic,
};

fn homogeneousVector(comptime T: type, comptime H: type, w: T, coords: [H.Full.dimensions - 1]T) H.Vector {
    const E = H.Basis;
    var v = E.e(0).scale(w).cast(H.Vector);

    inline for (coords, 0..) |coord, i| {
        v = v.add(E.e(i + 1).scale(coord)).cast(H.Vector);
    }

    return v;
}

pub fn initHomogeneousPoint(comptime T: type, comptime H: type, w: T, coords: [H.Full.dimensions - 1]T) H.Full {
    return homogeneousVector(T, H, w, coords).dual().cast(H.Full);
}

pub fn initHomogeneousPoint3(comptime H: type, w: anytype, x: anytype, y: anytype, z: anytype) H.Full {
    const T = @TypeOf(w + x + y + z);
    return initHomogeneousPoint(T, H, w, .{ x, y, z });
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

pub fn homogeneousCoords(comptime T: type, comptime H: type, p: anytype) [H.Full.dimensions]T {
    ga.multivector.ensureMultivector(@TypeOf(p));
    const dual = p.dual().cast(H.Vector);
    var coords: [H.Full.dimensions]T = undefined;

    inline for (0..H.Full.dimensions) |i| {
        const BasisVector = @TypeOf(H.Basis.e(i));
        coords[i] = @floatCast(dual.coeff(BasisVector.blades[0]));
    }

    if (coords[0] < 0.0) {
        inline for (0..coords.len) |i| {
            coords[i] = -coords[i];
        }
    }

    return coords;
}

pub fn ambientCoords3(comptime T: type, comptime H: type, p: anytype) [4]T {
    return homogeneousCoords(T, H, p);
}

pub fn RoundProjectiveHelpers(
    comptime T: type,
    comptime H: type,
    comptime metric: RoundMetric,
) type {
    const coord_count = H.Full.dimensions - 1;

    return struct {
        pub const h = H;

        pub const Point = struct {
            pub fn initHomogeneousCoords(w: T, coords: [H.Full.dimensions - 1]T) H.Full {
                return initHomogeneousPoint(T, H, w, coords);
            }

            pub fn initHomogeneous(w: T, x: T, y: T, z: T) H.Full {
                return initHomogeneousPoint3(H, w, x, y, z);
            }

            pub fn fromCoords(coords: [H.Full.dimensions - 1]T) H.Full {
                return initHomogeneousPoint(T, H, 1.0, coords);
            }

            pub fn properFromCoords(
                coords: [coord_count]T,
            ) switch (metric) {
                .hyperbolic => ?H.Full,
                .elliptic => H.Full,
            } {
                var r2: T = 0.0;
                inline for (coords) |coord| {
                    r2 += coord * coord;
                }

                return switch (metric) {
                    .hyperbolic => blk: {
                        if (r2 >= 1.0) break :blk null;
                        const inv: T = 1.0 / @sqrt(1.0 - r2);
                        var scaled: [coord_count]T = undefined;
                        inline for (coords, 0..) |coord, i| {
                            scaled[i] = coord * inv;
                        }
                        break :blk initHomogeneousPoint(T, H, inv, scaled);
                    },
                    .elliptic => blk: {
                        const inv: T = 1.0 / @sqrt(1.0 + r2);
                        var scaled: [coord_count]T = undefined;
                        inline for (coords, 0..) |coord, i| {
                            scaled[i] = coord * inv;
                        }
                        break :blk initHomogeneousPoint(T, H, inv, scaled);
                    },
                };
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
                return properFromCoords(.{ x, y, z });
            }
        };

        pub fn ambientCoords(p: anytype) [H.Full.dimensions]T {
            return homogeneousCoords(T, H, p);
        }
    };
}

pub fn EuclideanProjectiveHelpers(comptime T: type, comptime H: type) type {
    const coord_count = H.Full.dimensions - 1;

    return struct {
        pub const h = H;

        pub const Point = struct {
            pub fn initHomogeneousCoords(w: T, coords: [coord_count]T) H.Full {
                return initHomogeneousPoint(T, H, w, coords);
            }

            pub fn fromCoords(coords: [coord_count]T) H.Full {
                return initHomogeneousPoint(T, H, 1.0, coords);
            }

            pub fn init(x: T, y: T, z: T) H.Full {
                if (comptime coord_count != 3) {
                    @compileError("`Point.init(x, y, z)` is only available for 3D projective Euclidean families; use `Point.fromCoords()` for other dimensions");
                }
                return fromCoords(.{ x, y, z });
            }

            pub fn directionFromCoords(coords: [coord_count]T) H.Full {
                return initHomogeneousPoint(T, H, 0.0, coords);
            }

            pub fn direction(x: T, y: T, z: T) H.Full {
                if (comptime coord_count != 3) {
                    @compileError("`Point.direction(x, y, z)` is only available for 3D projective Euclidean families; use `Point.directionFromCoords()` for other dimensions");
                }
                return directionFromCoords(.{ x, y, z });
            }
        };

        pub fn ambientCoords(p: anytype) [H.Full.dimensions]T {
            return homogeneousCoords(T, H, p);
        }
    };
}

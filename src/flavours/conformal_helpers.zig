pub fn ConformalEuclideanHelpers(comptime T: type, comptime H: type) type {
    const euclidean_dimensions = H.Full.dimensions - 2;
    const positive_infinity_index = euclidean_dimensions + 1;
    const negative_infinity_index = euclidean_dimensions + 2;

    return struct {
        const Self = @This();

        pub const h = H;

        /// Null basis vectors for the origin and infinity.
        /// `n_o = 0.5 * (e_- - e_+)`, `n_inf = e_+ + e_-`.
        pub const no = H.Basis.e(negative_infinity_index).sub(H.Basis.e(positive_infinity_index)).scale(0.5);
        pub const ninf = H.Basis.e(positive_infinity_index).add(H.Basis.e(negative_infinity_index));

        pub const Point = struct {
            /// Maps Euclidean coordinates to a CGA null vector.
            pub fn fromCoords(coords: [euclidean_dimensions]T) H.Vector {
                const E = H.Basis;
                var r2: T = 0.0;
                var point = Self.no.cast(H.Vector);

                inline for (coords, 0..) |coord, i| {
                    r2 += coord * coord;
                    point = point.add(E.e(i + 1).scale(coord)).cast(H.Vector);
                }

                return point.add(Self.ninf.scale(0.5 * r2)).cast(H.Vector);
            }

            pub fn init(x: T, y: T, z: T) H.Vector {
                if (comptime euclidean_dimensions != 3) {
                    @compileError("`Point.init(x, y, z)` is only available for 3D conformal families; use `Point.fromCoords()` for other dimensions");
                }
                return fromCoords(.{ x, y, z });
            }
        };

        pub const Sphere = struct {
            /// A sphere is a vector in CGA: `S = P - 0.5 * r^2 * n_inf`.
            pub fn fromCenterCoords(center: [euclidean_dimensions]T, radius: T) H.Vector {
                const point = Point.fromCoords(center);
                return point.sub(Self.ninf.scale(0.5 * radius * radius));
            }

            pub fn init(center_x: T, center_y: T, center_z: T, radius: T) H.Vector {
                if (comptime euclidean_dimensions != 3) {
                    @compileError("`Sphere.init(x, y, z, r)` is only available for 3D conformal families; use `Sphere.fromCenterCoords()` for other dimensions");
                }
                return fromCenterCoords(.{ center_x, center_y, center_z }, radius);
            }
        };

        pub const Plane = struct {
            /// A plane is a vector in CGA: `Π = n + d * n_inf`.
            pub fn fromNormal(normal: [euclidean_dimensions]T, offset: T) H.Vector {
                const E = H.Basis;
                var plane = Self.ninf.scale(offset).cast(H.Vector);

                inline for (normal, 0..) |coord, i| {
                    plane = plane.add(E.e(i + 1).scale(coord)).cast(H.Vector);
                }

                return plane;
            }

            pub fn init(nx: T, ny: T, nz: T, d: T) H.Vector {
                if (comptime euclidean_dimensions != 3) {
                    @compileError("`Plane.init(nx, ny, nz, d)` is only available for 3D conformal families; use `Plane.fromNormal()` for other dimensions");
                }
                return fromNormal(.{ nx, ny, nz }, d);
            }
        };
    };
}

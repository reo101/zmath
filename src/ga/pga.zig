//! Semantic helpers for 3D plane-based projective geometric algebra, Cl(3,0,1).
//!
//! Use `extend()` with an instantiated algebra namespace. The resulting
//! namespace keeps the raw algebra under `.base` and adds PGA names and motion
//! helpers without changing the underlying sparse carrier types.
const blades = @import("blades.zig");

fn bladeMask(comptime name: []const u8) blades.BladeMask {
    @setEvalBranchQuota(10_000);
    return blades.BladeMask.parseForDimensionsPanicking(name, 4);
}

fn assertProjective3(comptime Base: type) void {
    if (!@hasDecl(Base, "Coefficient") or
        !@hasDecl(Base, "signature") or
        !@hasDecl(Base, "Scalar") or
        !@hasDecl(Base, "Vector") or
        !@hasDecl(Base, "Bivector") or
        !@hasDecl(Base, "Trivector") or
        !@hasDecl(Base, "Even") or
        !@hasDecl(Base, "basisVector"))
    {
        @compileError("pga.extend expects an instantiated zmath algebra namespace");
    }

    const sig: blades.MetricSignature = Base.signature;
    if (sig.p != 3 or sig.q != 0 or sig.r != 1) {
        @compileError("pga.extend supports only plane-based Cl(3,0,1)");
    }
}

/// Extends an instantiated `Cl(3,0,1)` algebra namespace with 3D PGA helpers.
///
/// The source namespace remains available as `base`. Its existing types stay
/// unchanged; `Motor` is the same sparse even carrier as `base.Even`.
pub fn extend(comptime Base: type) type {
    comptime {
        @setEvalBranchQuota(10_000);
        assertProjective3(Base);
    }

    const scalar = comptime blades.BladeMask.init(0);
    const e1 = comptime bladeMask("e1");
    const e2 = comptime bladeMask("e2");
    const e3 = comptime bladeMask("e3");
    const e4 = comptime bladeMask("e4");
    const e12 = comptime bladeMask("e12");
    const e13 = comptime bladeMask("e13");
    const e14 = comptime bladeMask("e14");
    const e23 = comptime bladeMask("e23");
    const e24 = comptime bladeMask("e24");
    const e34 = comptime bladeMask("e34");
    const e1234 = comptime bladeMask("e1234");
    comptime {
        const plane_blades = [_]blades.BladeMask{ e1, e2, e3, e4 };
        for (plane_blades, 0..) |mask, index| {
            if (Base.Vector.blades[index].toInt() != mask.toInt()) {
                @compileError("Cl(3,0,1) vectors must use canonical basis order");
            }
        }

        const motor_blades = [_]blades.BladeMask{ scalar, e12, e13, e23, e14, e24, e34, e1234 };
        for (motor_blades, 0..) |mask, index| {
            if (Base.Even.blades[index].toInt() != mask.toInt()) {
                @compileError("Cl(3,0,1) even blades must use canonical order");
            }
        }
    }

    return struct {
        pub const base = Base;
        pub const Coefficient = Base.Coefficient;

        /// A plane `ax + by + cz + d = 0`.
        pub const Plane = Base.Vector;
        /// A Plücker line.
        pub const Line = Base.Bivector;
        /// A homogeneous finite or ideal point.
        pub const Point = Base.Trivector;
        /// An ideal point representing a Euclidean direction.
        pub const Direction = Point;
        /// An even multivector representing a rigid Euclidean motion.
        pub const Motor = Base.Even;

        pub const MotorError = error{ZeroAxis};

        const Quaternion = @Vector(4, Coefficient);

        fn quaternionProduct(lhs: Quaternion, rhs: Quaternion) Quaternion {
            return .{
                lhs[0] * rhs[0] - lhs[1] * rhs[1] - lhs[2] * rhs[2] - lhs[3] * rhs[3],
                lhs[0] * rhs[1] + lhs[1] * rhs[0] + lhs[2] * rhs[3] - lhs[3] * rhs[2],
                lhs[0] * rhs[2] - lhs[1] * rhs[3] + lhs[2] * rhs[0] + lhs[3] * rhs[1],
                lhs[0] * rhs[3] + lhs[1] * rhs[2] - lhs[2] * rhs[1] + lhs[3] * rhs[0],
            };
        }

        fn motorReal(motor: Motor) Quaternion {
            var scalar_part: Coefficient = undefined;
            var xy: Coefficient = undefined;
            var xz: Coefficient = undefined;
            var yz: Coefficient = undefined;

            inline for (Motor.blades, motor.coeffsArray()) |mask, coefficient| {
                switch (mask.toInt()) {
                    scalar.toInt() => scalar_part = coefficient,
                    e12.toInt() => xy = coefficient,
                    e13.toInt() => xz = coefficient,
                    e23.toInt() => yz = coefficient,
                    else => {},
                }
            }
            return .{ scalar_part, -yz, xz, -xy };
        }

        fn motorDual(motor: Motor) Quaternion {
            var scalar_part: Coefficient = undefined;
            var x: Coefficient = undefined;
            var y: Coefficient = undefined;
            var z: Coefficient = undefined;

            inline for (Motor.blades, motor.coeffsArray()) |mask, coefficient| {
                switch (mask.toInt()) {
                    e1234.toInt() => scalar_part = coefficient,
                    e14.toInt() => x = coefficient,
                    e24.toInt() => y = coefficient,
                    e34.toInt() => z = coefficient,
                    else => {},
                }
            }
            return .{ scalar_part, x, y, z };
        }

        fn motorFromDualQuaternion(real: Quaternion, dual: Quaternion) Motor {
            var coefficients: [Motor.stored_blade_count]Coefficient = undefined;
            inline for (&coefficients, Motor.blades) |*coefficient, mask| {
                coefficient.* = switch (mask.toInt()) {
                    scalar.toInt() => real[0],
                    e12.toInt() => -real[3],
                    e13.toInt() => real[2],
                    e23.toInt() => -real[1],
                    e14.toInt() => dual[1],
                    e24.toInt() => dual[2],
                    e34.toInt() => dual[3],
                    e1234.toInt() => dual[0],
                    else => unreachable,
                };
            }
            return Motor.init(coefficients);
        }

        fn rotateByQuaternion(vector: @Vector(3, Coefficient), real: Quaternion) @Vector(3, Coefficient) {
            const w = real[0];
            const x = real[1];
            const y = real[2];
            const z = real[3];
            return .{
                (w * w + x * x - y * y - z * z) * vector[0] + 2 * (x * y - w * z) * vector[1] + 2 * (x * z + w * y) * vector[2],
                2 * (x * y + w * z) * vector[0] + (w * w - x * x + y * y - z * z) * vector[1] + 2 * (y * z - w * x) * vector[2],
                2 * (x * z - w * y) * vector[0] + 2 * (y * z + w * x) * vector[1] + (w * w - x * x - y * y + z * z) * vector[2],
            };
        }

        /// A motor action with its rotation, translation, and homogeneous scale prepared once.
        pub const PreparedMotor = struct {
            real: Quaternion,
            translation: @Vector(3, Coefficient),
            homogeneous_scale: Coefficient,

            /// Applies this prepared motor to a homogeneous point.
            pub fn transformPoint(self: PreparedMotor, point_value: Point) Point {
                const homogeneous = point_value.complementDual().cast(Plane);
                var x: Coefficient = undefined;
                var y: Coefficient = undefined;
                var z: Coefficient = undefined;
                var weight: Coefficient = undefined;
                inline for (Plane.blades, homogeneous.coeffsArray()) |mask, coefficient| {
                    switch (mask.toInt()) {
                        e1.toInt() => x = coefficient,
                        e2.toInt() => y = coefficient,
                        e3.toInt() => z = coefficient,
                        e4.toInt() => weight = coefficient,
                        else => unreachable,
                    }
                }
                const position: @Vector(3, Coefficient) = .{ x, y, z };
                const rotated = rotateByQuaternion(position, self.real);
                const transformed = Plane.init(.{
                    rotated[0] + weight * self.translation[0],
                    rotated[1] + weight * self.translation[1],
                    rotated[2] + weight * self.translation[2],
                    weight * self.homogeneous_scale,
                });
                return transformed.complementDual().cast(Point);
            }

            /// Applies this prepared motor to an ideal direction.
            pub fn transformDirection(self: PreparedMotor, direction_value: Direction) Direction {
                const homogeneous = direction_value.complementDual().cast(Plane);
                var x: Coefficient = undefined;
                var y: Coefficient = undefined;
                var z: Coefficient = undefined;
                inline for (Plane.blades, homogeneous.coeffsArray()) |mask, coefficient| {
                    switch (mask.toInt()) {
                        e1.toInt() => x = coefficient,
                        e2.toInt() => y = coefficient,
                        e3.toInt() => z = coefficient,
                        e4.toInt() => {},
                        else => unreachable,
                    }
                }
                const vector: @Vector(3, Coefficient) = .{ x, y, z };
                const rotated = rotateByQuaternion(vector, self.real);
                return Plane.init(.{ rotated[0], rotated[1], rotated[2], 0 }).complementDual().cast(Direction);
            }
        };

        /// Prepares a motor action for transforming several points or directions.
        pub fn prepare(motor: Motor) PreparedMotor {
            const real = motorReal(motor);
            const dual = motorDual(motor);
            const real_conjugate: Quaternion = .{ real[0], -real[1], -real[2], -real[3] };
            const translation_part = quaternionProduct(dual, real_conjugate);
            return .{
                .real = real,
                .translation = .{ 2 * translation_part[1], 2 * translation_part[2], 2 * translation_part[3] },
                .homogeneous_scale = @reduce(.Add, real * real),
            };
        }

        /// Constructs the finite point at `position`.
        pub fn point(position: @Vector(3, Coefficient)) Point {
            const homogeneous = Plane.init(.{ position[0], position[1], position[2], 1 });
            return homogeneous.complementDual().cast(Point);
        }

        /// Constructs the ideal point representing `vector`.
        pub fn direction(vector: @Vector(3, Coefficient)) Direction {
            const homogeneous = Plane.init(.{ vector[0], vector[1], vector[2], 0 });
            return homogeneous.complementDual().cast(Direction);
        }

        /// Constructs the unit motor for an axis-angle rotation.
        pub fn rotation(axis: @Vector(3, Coefficient), angle_radians: Coefficient) MotorError!Motor {
            const axis_norm_squared = @reduce(.Add, axis * axis);
            if (axis_norm_squared == 0) return error.ZeroAxis;

            const half_angle = angle_radians / 2;
            const scale = @sin(half_angle) / @sqrt(axis_norm_squared);
            const bivector = Base.basisBlade(e12).scale(-axis[2] * scale)
                .add(Base.basisBlade(e13).scale(axis[1] * scale))
                .add(Base.basisBlade(e23).scale(-axis[0] * scale));
            return Base.Scalar.init(.{@cos(half_angle)}).add(bivector).cast(Motor);
        }

        /// Constructs the motor that translates by `displacement`.
        pub fn translator(displacement: @Vector(3, Coefficient)) Motor {
            const displacement_plane = Plane.init(.{ displacement[0], displacement[1], displacement[2], 0 });
            const null_axis = Base.basisVector(4);
            const generator = displacement_plane.wedge(null_axis).scale(0.5);
            return Base.Scalar.init(.{1}).add(generator).cast(Motor);
        }

        /// Composes `lhs` after `rhs`.
        ///
        /// Cl(3,0,1)'s even subalgebra is dual-quaternion algebra. This is the
        /// exact PGA product, including for non-unit even multivectors.
        pub fn compose(lhs: Motor, rhs: Motor) Motor {
            const lhs_real = motorReal(lhs);
            const rhs_real = motorReal(rhs);
            return motorFromDualQuaternion(
                quaternionProduct(lhs_real, rhs_real),
                quaternionProduct(lhs_real, motorDual(rhs)) + quaternionProduct(motorDual(lhs), rhs_real),
            );
        }

        /// Applies a motor sandwich to a homogeneous point.
        pub fn transformPoint(point_value: Point, motor: Motor) Point {
            return prepare(motor).transformPoint(point_value);
        }

        /// Applies a motor sandwich to an ideal direction.
        pub fn transformDirection(direction_value: Direction, motor: Motor) Direction {
            return prepare(motor).transformDirection(direction_value);
        }
    };
}

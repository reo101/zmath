//! Geometric Algebra (GA) core module.
//!
//! This module provides the foundational tools for working with multivectors,
//! blades, and algebras.
//!
//! ### Canonical Usage
//! For most users, the `Algebra` function is the primary entry point. It creates
//! a namespace for a specific metric signature (e.g., Euclidean, Minkowski, Projective).
//!
//! ```zig
//! const Cl3 = ga.Algebra(.euclidean(3)).Instantiate(f64);
//! const v = Cl3.Vector.init(.{1, 2, 3});
//! ```
//!
//! ### Advanced Usage
//! The underlying modules (`blades`, `multivector`, `rotors`) can be used directly
//! for more low-level control or when building custom algebra abstractions.

const std = @import("std");

pub const blades = @import("ga/blades.zig");
pub const blade_parsing = @import("ga/blade_parsing.zig");
pub const expression = @import("ga/expression.zig");
pub const family = @import("ga/family.zig");
pub const multivector = @import("ga/multivector.zig");
pub const rotors = @import("ga/rotors.zig");

pub const MetricSignature = blades.MetricSignature;
pub const BasisIndexSpans = blades.BasisIndexSpans;
pub const NamingOptions = blade_parsing.SignedBladeNamingOptions;
pub const euclideanSignature = blades.euclideanSignature;

/// Returns a signature-baked algebra namespace for a fixed `Cl(p, q, r)`.
///
/// This provides a high-level API for creating multivector types, basis helpers,
/// and expression compilers for a specific algebra.
pub fn Algebra(comptime sig: blades.MetricSignature) type {
    return AlgebraWithNamingOptions(sig, blade_parsing.SignedBladeNamingOptions.fromSignature(sig));
}

/// Returns a signature-baked algebra namespace with naming options.
pub fn AlgebraWithNamingOptions(comptime sig: blades.MetricSignature, comptime naming_options: blade_parsing.SignedBladeNamingOptions) type {
    return struct {
        pub const Self = @This();
        pub const metric_signature = sig;
        pub const dimension = metric_signature.dimension();
        pub const naming = naming_options;

        /// Creates a generic multivector type restricted to specific blades.
        pub fn Multivector(comptime T: type, comptime blade_masks: []const blades.BladeMask) type {
            return multivector.MultivectorWithNaming(T, blade_masks, metric_signature, naming);
        }

        /// Creates a basis helper for this algebra, providing named basis vectors (e.g., `e1`, `e12`).
        pub fn Basis(comptime T: type) type {
            return multivector.BasisWithNamingOptions(T, metric_signature, naming);
        }

        /// Multivector carrier containing all possible blades for this algebra.
        pub fn FullMultivector(comptime T: type) type {
            return Self.Multivector(T, &blades.allBladeMasks(dimension));
        }

        /// Grade-restricted multivector carrier (e.g., only Vectors, only Bivectors).
        pub fn KVector(comptime T: type, comptime grade: usize) type {
            return Self.Multivector(T, &blades.gradeBladeMasks(dimension, grade));
        }

        /// Multivector containing only even-grade blades (e.g., Scalars + Bivectors).
        pub fn EvenMultivector(comptime T: type) type {
            return Self.Multivector(T, &blades.evenBladeMasks(dimension));
        }

        /// Multivector containing only odd-grade blades (e.g., Vectors + Trivectors).
        pub fn OddMultivector(comptime T: type) type {
            return Self.Multivector(T, &blades.oddBladeMasks(dimension));
        }

        /// Scalar type (Grade 0).
        pub fn Scalar(comptime T: type) type {
            return Self.KVector(T, 0);
        }

        /// Vector type (Grade 1).
        pub fn Vector(comptime T: type) type {
            return Self.KVector(T, 1);
        }

        /// Bivector type (Grade 2).
        pub fn Bivector(comptime T: type) type {
            return Self.KVector(T, 2);
        }

        /// Trivector type (Grade 3).
        pub fn Trivector(comptime T: type) type {
            return Self.KVector(T, 3);
        }

        /// Pseudoscalar type (Top Grade).
        pub fn Pseudoscalar(comptime T: type) type {
            return Self.KVector(T, dimension);
        }

        /// Rotor type (Even Multivectors).
        pub fn Rotor(comptime T: type) type {
            return Self.EvenMultivector(T);
        }

        /// Constructs a unit basis blade from a mask.
        pub fn basisBlade(
            comptime T: type,
            comptime mask: blades.BladeMask,
        ) Self.Multivector(T, &.{mask}) {
            return Self.Multivector(T, &.{mask}).init(.{1});
        }

        /// Constructs a basis vector from a one-based index.
        pub fn basisVector(
            comptime T: type,
            comptime one_based_index: usize,
        ) Self.Multivector(T, &.{blades.basisVectorMask(dimension, one_based_index)}) {
            return Self.basisBlade(T, blades.basisVectorMask(dimension, one_based_index));
        }

        /// Constructs a signed blade from a name string (e.g., "e1", "-e12", "e(1,2)").
        pub fn signedBlade(
            comptime T: type,
            comptime name: []const u8,
        ) Self.Multivector(T, &.{blade_parsing.parseSignedBlade(name, dimension, naming, true).mask}) {
            const spec = comptime blade_parsing.parseSignedBlade(name, dimension, naming, true);
            return Self.basisBlade(T, spec.mask).scale(@intFromEnum(spec.sign));
        }

        /// Constructs a signed blade from internal basis indices.
        pub fn fullSignedBladeFromIndices(
            comptime T: type,
            indices: []const usize,
        ) Self.FullMultivector(T) {
            const raw = multivector.fullSignedBladeFromIndicesWithSignature(T, metric_signature, indices);
            return Self.FullMultivector(T).init(raw.coeffsArray());
        }

        /// Returns a namespace where all type constructors and common operations are bound to a specific coefficient type `T`.
        pub fn Instantiate(comptime T: type) type {
            return struct {
                /// Scalar type (Grade 0) bound to `T`.
                pub const Scalar = Self.Scalar(T);
                /// Vector type (Grade 1) bound to `T`.
                pub const Vector = Self.Vector(T);
                /// Bivector type (Grade 2) bound to `T`.
                pub const Bivector = Self.Bivector(T);
                /// Trivector type (Grade 3) bound to `T`.
                pub const Trivector = Self.Trivector(T);
                /// Full multivector carrier bound to `T`.
                pub const Full = Self.FullMultivector(T);
                /// Even-grade multivector carrier bound to `T`.
                pub const Even = Self.EvenMultivector(T);
                /// Odd-grade multivector carrier bound to `T`.
                pub const Odd = Self.OddMultivector(T);
                /// Pseudoscalar type bound to `T`.
                pub const Pseudoscalar = Self.Pseudoscalar(T);
                /// Rotor type bound to `T`.
                pub const Rotor = Self.Rotor(T);
                /// Basis helper providing named basis vectors, bound to `T`.
                pub const Basis = Self.Basis(T);

                /// Constructs a unit basis blade from a mask.
                pub fn basisBlade(comptime mask: blades.BladeMask) Self.Multivector(T, &.{mask}) {
                    return Self.basisBlade(T, mask);
                }

                /// Constructs a basis vector from a one-based index.
                pub fn basisVector(comptime index: usize) Self.Multivector(T, &.{blades.basisVectorMask(dimension, index)}) {
                    return Self.basisVector(T, index);
                }

                /// Constructs a signed blade from a name string.
                pub fn signedBlade(comptime name: []const u8) Self.Multivector(T, &.{blade_parsing.parseSignedBlade(name, dimension, naming, true).mask}) {
                    return Self.signedBlade(T, name);
                }

                /// Returns the Euclidean norm of a multivector.
                pub fn norm(mv: anytype) T {
                    return rotors.norm(mv);
                }

                /// Returns the Euclidean norm squared of a multivector.
                pub fn normSquared(mv: anytype) T {
                    return rotors.normSquared(mv);
                }

                /// Normalizes a multivector to unit magnitude.
                pub fn normalize(mv: anytype) rotors.RotorError!@TypeOf(mv) {
                    return rotors.normalize(mv);
                }

                /// Normalizes a multivector, returning it as is if zero.
                pub fn normalized(mv: anytype) @TypeOf(mv) {
                    return rotors.normalized(mv);
                }

                /// Normalizes a rotor, returning it as is if zero.
                pub fn normalizedRotor(rotor: anytype) @TypeOf(rotor) {
                    return rotors.normalizedRotor(rotor);
                }

                /// Returns the magnitude of a multivector.
                pub fn magnitude(mv: anytype) T {
                    return rotors.norm(mv);
                }

                /// Returns the Hodge/Poincaré dual of a multivector.
                pub fn dual(mv: anytype) multivector.DualResultType(T, @TypeOf(mv).blades, metric_signature) {
                    return mv.dual();
                }

                /// Returns the outer product (wedge) of two multivectors.
                pub fn wedge(lhs: anytype, rhs: anytype) @TypeOf(lhs.wedge(rhs)) {
                    return lhs.wedge(rhs);
                }

                /// Compiles a multivector expression string at comptime.
                pub fn compileExpr(comptime source: []const u8) expression.CompiledExpression(T, metric_signature, naming, source) {
                    return expression.compile(T, metric_signature, naming, source);
                }

                /// Evaluates a multivector expression string into a Full multivector.
                pub fn expr(comptime source: []const u8, args: anytype) multivector.FullMultivector(T, metric_signature) {
                    return compileExpr(source).eval(args);
                }

                /// Evaluates a multivector expression string into a specific result type.
                pub fn exprAs(comptime Result: type, comptime source: []const u8, args: anytype) Result {
                    return compileExpr(source).evalAs(Result, args);
                }
            };
        }
    };
}

test "ga facade exposes canonical family and rotor surface" {
    _ = expression;

    try std.testing.expectEqual(@as(usize, 5), family.euclidean(5).dimension);

    const E2 = Algebra(.euclidean(2)).Basis(f64);
    const e1 = E2.e(1);
    const half_turn = rotors.planarRotor(f64, std.math.pi);
    const rotated_e1 = rotors.rotated(e1, half_turn);
    try std.testing.expect(rotors.nearlyEqual(rotated_e1.coeffNamed("e1"), -1.0, 1e-12));
    try std.testing.expect(rotors.nearlyEqual(rotated_e1.coeffNamed("e2"), 0.0, 1e-12));
}

test "signature-baked algebra namespace drives metric-dependent products" {
    const Minkowski11: blades.MetricSignature = .{ .p = 1, .q = 1 };
    const Cl11 = Algebra(Minkowski11);

    const e2 = Cl11.Basis(i32).e(2);
    const e2_squared = e2.gp(e2);
    try std.testing.expectEqual(@as(i32, -1), e2_squared.scalarCoeff());
}

test "algebra naming options can expose span-mapped named indices" {
    const sig: blades.MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const opts = comptime blade_parsing.SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    const parsed = try blade_parsing.parseSignedBlade("e0", sig.dimension(), opts, false);
    try std.testing.expectEqual(blades.SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, parsed);

    const Cl301 = AlgebraWithNamingOptions(sig, opts);
    const E = Cl301.Basis(f64);
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expectError(error.InvalidBasisIndex, blade_parsing.parseSignedBlade("e4", sig.dimension(), opts, false));
}

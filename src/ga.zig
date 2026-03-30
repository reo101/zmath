const std = @import("std");

pub const blades = @import("ga/blades.zig");
pub const blade_parsing = @import("ga/blade_parsing.zig");
pub const expression = @import("ga/expression.zig");
pub const multivector = @import("ga/multivector.zig");
pub const rotors = @import("ga/rotors.zig");

pub const BladeMask = blades.BladeMask;
pub const SignedBladeParseError = blade_parsing.SignedBladeParseError;
pub const SignedBladeSpec = blades.SignedBladeSpec;
pub const MetricSignature = blades.MetricSignature;
pub const SignatureClass = blades.SignatureClass;
pub const BasisIndexSpan = blades.BasisIndexSpan;
pub const BasisIndexSpans = blades.BasisIndexSpans;
pub const SignedBladeNamingOptions = blade_parsing.SignedBladeNamingOptions;
pub const euclideanSignature = blades.euclideanSignature;

pub const choose = blades.choose;
pub const bladeCount = blades.bladeCount;
pub const bladeGrade = blades.bladeGrade;
pub const gradeBladeMasks = blades.gradeBladeMasks;
pub const evenBladeMasks = blades.evenBladeMasks;
pub const oddBladeMasks = blades.oddBladeMasks;
pub const basisVectorMask = blades.basisVectorMask;
pub const basisVectorBladeMask = basisVectorMask;
pub const basisBladeMask = blades.basisBladeMask;
pub const writeBladeMask = blades.writeBladeMask;

pub const isSignedBlade = blade_parsing.isSignedBlade;
pub const isMultivectorType = multivector.isMultivectorType;
pub const ensureMultivector = multivector.ensureMultivector;

pub const norm = rotors.norm;
pub const normSquared = rotors.normSquared;
pub const normalize = rotors.normalize;
pub const normalized = rotors.normalized;
pub const normalizedRotor = rotors.normalizedRotor;

/// Parses a signed blade name into a canonical spec.
pub fn parseSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) SignedBladeSpec else SignedBladeParseError!SignedBladeSpec {
    return blade_parsing.parseSignedBlade(name, dimension, options, panicking);
}

/// Parses a signed blade name, panicking on failure.
pub fn expectSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
) SignedBladeSpec {
    return parseSignedBlade(name, dimension, options, true);
}

/// Resolves a named basis index into its sequential internal index.
pub fn resolveNamedBasisIndex(
    comptime named_index: usize,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) usize else SignedBladeParseError!usize {
    return blade_parsing.resolveNamedBasisIndex(named_index, dimension, options, panicking);
}

/// Resolves a named basis index, panicking on failure.
pub fn expectNamedBasisIndex(
    comptime named_index: usize,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
) usize {
    return resolveNamedBasisIndex(named_index, dimension, options, true);
}

pub const Multivector = multivector.Multivector;
pub const Basis = multivector.Basis;
pub const FullMultivector = multivector.FullMultivector;
pub const KVector = multivector.KVector;
pub const EvenMultivector = multivector.EvenMultivector;
pub const OddMultivector = multivector.OddMultivector;
pub const Scalar = multivector.Scalar;
pub const Vector = multivector.Vector;
pub const Bivector = multivector.Bivector;
pub const Trivector = multivector.Trivector;
pub const Pseudoscalar = multivector.Pseudoscalar;
pub const Rotor = multivector.Rotor;
pub const basisBlade = multivector.basisBlade;
pub const basisVector = multivector.basisVector;
pub const signedBlade = multivector.signedBlade;
pub const signedBladeWithOptions = multivector.signedBladeWithOptions;

/// Returns a signature-baked algebra namespace for a fixed `Cl(p, q, r)`.
pub fn Algebra(comptime sig: MetricSignature) type {
    return AlgebraWithNamingOptions(sig, SignedBladeNamingOptions.fromSignature(sig));
}

/// Returns a signature-baked algebra namespace with naming options.
pub fn AlgebraWithNamingOptions(comptime sig: MetricSignature, comptime naming_options: SignedBladeNamingOptions) type {
    return struct {
        pub const Self = @This();
        pub const metric_signature = sig;
        pub const dimension = metric_signature.dimension();
        pub const naming = naming_options;

        /// Generic multivector type for this algebra.
        pub fn Multivector(comptime T: type, comptime blade_masks: []const BladeMask) type {
            return multivector.Multivector(T, blade_masks, metric_signature);
        }

        /// Basis helper for this algebra.
        pub fn Basis(comptime T: type) type {
            return multivector.BasisWithNamingOptions(T, metric_signature, naming);
        }

        /// Full multivector carrier for this algebra.
        pub fn FullMultivector(comptime T: type) type {
            return multivector.FullMultivector(T, metric_signature);
        }

        /// Grade-restricted multivector carrier for this algebra.
        pub fn KVector(comptime T: type, comptime grade: usize) type {
            return multivector.KVector(T, grade, metric_signature);
        }

        pub fn EvenMultivector(comptime T: type) type {
            return multivector.EvenMultivector(T, metric_signature);
        }

        pub fn OddMultivector(comptime T: type) type {
            return multivector.OddMultivector(T, metric_signature);
        }

        pub fn Scalar(comptime T: type) type {
            return multivector.Scalar(T, metric_signature);
        }

        pub fn Vector(comptime T: type) type {
            return multivector.Vector(T, metric_signature);
        }

        pub fn Bivector(comptime T: type) type {
            return multivector.Bivector(T, metric_signature);
        }

        pub fn Trivector(comptime T: type) type {
            return multivector.Trivector(T, metric_signature);
        }

        pub fn Pseudoscalar(comptime T: type) type {
            return multivector.Pseudoscalar(T, metric_signature);
        }

        pub fn Rotor(comptime T: type) type {
            return multivector.Rotor(T, metric_signature);
        }

        /// Constructs a unit basis blade from a mask.
        pub fn basisBlade(
            comptime T: type,
            comptime mask: BladeMask,
        ) multivector.BasisBladeType(T, mask, metric_signature) {
            return multivector.basisBlade(T, mask, metric_signature);
        }

        /// Constructs a basis vector from a one-based index.
        pub fn basisVector(
            comptime T: type,
            comptime one_based_index: usize,
        ) multivector.BasisBladeType(T, blades.basisVectorMask(metric_signature.dimension(), one_based_index), metric_signature) {
            return multivector.basisVector(T, one_based_index, metric_signature);
        }

        /// Constructs a signed blade from a name string.
        pub fn signedBlade(
            comptime T: type,
            comptime name: []const u8,
        ) multivector.SignedBladeTypeWithOptions(T, name, metric_signature, naming) {
            return multivector.signedBladeWithOptions(T, name, metric_signature, naming);
        }

        /// Constructs a signed blade from internal indices.
        pub fn fullSignedBladeFromIndices(
            comptime T: type,
            indices: []const usize,
        ) multivector.FullMultivector(T, metric_signature) {
            return multivector.fullSignedBladeFromIndicesWithSignature(T, metric_signature, indices);
        }

        /// Returns a namespace where all type constructors are bound to `T`.
        pub fn Instantiate(comptime T: type) type {
            return struct {
                pub const Scalar = Self.Scalar(T);
                pub const Vector = Self.Vector(T);
                pub const Bivector = Self.Bivector(T);
                pub const Trivector = Self.Trivector(T);
                pub const Full = Self.FullMultivector(T);
                pub const Even = Self.EvenMultivector(T);
                pub const Odd = Self.OddMultivector(T);
                pub const Pseudoscalar = Self.Pseudoscalar(T);
                pub const Rotor = Self.Rotor(T);
                pub const Basis = Self.Basis(T);

                /// Constructs a unit basis blade from a mask.
                pub fn basisBlade(comptime mask: BladeMask) multivector.BasisBladeType(T, mask, metric_signature) {
                    return Self.basisBlade(T, mask);
                }

                /// Constructs a basis vector from a one-based index.
                pub fn basisVector(comptime index: usize) multivector.BasisBladeType(T, blades.basisVectorMask(metric_signature.dimension(), index), metric_signature) {
                    return Self.basisVector(T, index);
                }

                /// Constructs a signed blade from a name string.
                pub fn signedBlade(comptime name: []const u8) multivector.SignedBladeTypeWithOptions(T, name, metric_signature, naming) {
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

                /// Evaluates a multivector expression string.
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

pub const fullSignedBladeFromIndicesWithSignature = multivector.fullSignedBladeFromIndicesWithSignature;
pub const writeMultivector = multivector.writeMultivector;

test "ga facade exposes core and specialized modules" {
    _ = expression;

    try std.testing.expect(choose(5, 2) == blades.choose(5, 2));
    try std.testing.expect(bladeCount(3) == blades.bladeCount(3));
    try std.testing.expect(isSignedBlade("e(1,2)", 2, null));

    const sig: MetricSignature = .{ .p = 1, .q = 1 };
    const value = fullSignedBladeFromIndicesWithSignature(i32, sig, &.{ 2, 2 });
    try std.testing.expectEqual(@as(i32, -1), value.scalarCoeff());

    const E2 = Algebra(.euclidean(2)).Basis(f64);
    const e1 = E2.e(1);
    const half_turn = rotors.planarRotor(f64, std.math.pi);
    const rotated_e1 = rotors.rotated(e1, half_turn);
    try std.testing.expect(rotors.nearlyEqual(rotated_e1.coeffNamed("e1"), -1.0, 1e-12));
    try std.testing.expect(rotors.nearlyEqual(rotated_e1.coeffNamed("e2"), 0.0, 1e-12));
}

test "signature-baked algebra namespace drives metric-dependent products" {
    const Minkowski11: MetricSignature = .{ .p = 1, .q = 1 };
    const Cl11 = Algebra(Minkowski11);

    const e2 = Cl11.Basis(i32).e(2);
    const e2_squared = e2.gp(e2);
    try std.testing.expectEqual(@as(i32, -1), e2_squared.scalarCoeff());
}

test "algebra naming options can expose span-mapped named indices" {
    const sig: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
    const spans = comptime BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const opts = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    const parsed = try parseSignedBlade("e0", sig.dimension(), opts, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, parsed);

    const Cl301 = AlgebraWithNamingOptions(sig, opts);
    const E = Cl301.Basis(f64);
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e4", sig.dimension(), opts, false));
}

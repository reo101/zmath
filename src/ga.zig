const std = @import("std");

pub const blades = @import("ga/blades.zig");
pub const blade_parsing = @import("ga/blade_parsing.zig");
pub const multivector = @import("ga/multivector.zig");
pub const rotors2d = @import("ga/rotors2d.zig");

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
pub const isSignedBladeWithOptions = blade_parsing.isSignedBladeWithOptions;
pub const parseSignedBlade = blade_parsing.parseSignedBlade;
pub const parseSignedBladeWithOptions = blade_parsing.parseSignedBladeWithOptions;
pub const resolveBasisHelperIndexWithOptions = blade_parsing.resolveBasisHelperIndexWithOptions;
pub const expectSignedBlade = blade_parsing.expectSignedBlade;
pub const expectSignedBladeWithOptions = blade_parsing.expectSignedBladeWithOptions;

pub const MultivectorWithSignature = multivector.Multivector;
pub const BasisWithSignature = multivector.Basis;
pub const FullMultivectorWithSignature = multivector.FullMultivector;
pub const KVectorWithSignature = multivector.KVector;
pub const EvenMultivectorWithSignature = multivector.EvenMultivector;
pub const OddMultivectorWithSignature = multivector.OddMultivector;
pub const ScalarWithSignature = multivector.Scalar;
pub const VectorWithSignature = multivector.Vector;
pub const BivectorWithSignature = multivector.Bivector;
pub const TrivectorWithSignature = multivector.Trivector;
pub const PseudoscalarWithSignature = multivector.Pseudoscalar;
pub const RotorWithSignature = multivector.Rotor;
pub const basisBladeWithSignature = multivector.basisBlade;
pub const basisVectorWithSignature = multivector.basisVector;
pub const signedBladeWithSignature = multivector.signedBlade;
pub const signedBladeWithSignatureAndOptions = multivector.signedBladeWithOptions;

fn algebraBoundHelpers(comptime sig: MetricSignature, comptime naming_options: SignedBladeNamingOptions) type {
    return struct {
        const metric_signature = sig;

        pub fn Multivector(comptime T: type, comptime blade_masks: []const BladeMask) type {
            return multivector.Multivector(T, blade_masks, metric_signature);
        }

        pub fn Basis(comptime T: type) type {
            return multivector.BasisWithNamingOptions(T, metric_signature, naming_options);
        }

        pub fn FullMultivector(comptime T: type) type {
            return multivector.FullMultivector(T, metric_signature);
        }

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

        pub fn basisBlade(
            comptime T: type,
            comptime mask: BladeMask,
        ) multivector.BasisBladeType(T, mask, metric_signature) {
            return multivector.basisBlade(T, mask, metric_signature);
        }

        pub fn basisVector(
            comptime T: type,
            comptime one_based_index: usize,
        ) multivector.BasisBladeType(T, blades.basisVectorMask(metric_signature.dimension(), one_based_index), metric_signature) {
            return multivector.basisVector(T, one_based_index, metric_signature);
        }

        pub fn signedBlade(
            comptime T: type,
            comptime name: []const u8,
        ) multivector.SignedBladeTypeWithOptions(T, name, metric_signature, naming_options) {
            return multivector.signedBladeWithOptions(T, name, metric_signature, naming_options);
        }

        pub fn fullSignedBladeFromIndices(
            comptime T: type,
            indices: []const usize,
        ) multivector.FullMultivector(T, metric_signature) {
            return multivector.fullSignedBladeFromIndicesWithSignature(T, metric_signature, indices);
        }
    };
}

fn requiredHelperExportFieldNames() []const []const u8 {
    return &.{
        "Multivector",
        "Basis",
        "FullMultivector",
        "KVector",
        "EvenMultivector",
        "OddMultivector",
        "Scalar",
        "Vector",
        "Bivector",
        "Pseudoscalar",
        "Rotor",
    };
}

fn hasAllRequiredHelperExports(comptime AlgebraType: type) bool {
    inline for (requiredHelperExportFieldNames()) |name| {
        if (!@hasDecl(AlgebraType, name)) return false;
    }
    return true;
}

fn helperExportFieldNames(comptime AlgebraType: type) []const []const u8 {
    @setEvalBranchQuota(10_000);

    const required_names = requiredHelperExportFieldNames();
    const declarations = std.meta.declarations(AlgebraType);

    var optional_count: usize = 0;
    inline for (declarations) |decl| {
        if (!isOptionalHelperExportDecl(AlgebraType, decl.name)) continue;
        optional_count += 1;
    }

    const total_len = required_names.len + optional_count;
    var names: [total_len][]const u8 = undefined;
    var cursor: usize = 0;

    inline for (required_names) |name| {
        names[cursor] = name;
        cursor += 1;
    }

    inline for (declarations) |decl| {
        if (!isOptionalHelperExportDecl(AlgebraType, decl.name)) continue;
        names[cursor] = decl.name;
        cursor += 1;
    }

    return names[0..];
}

fn isRequiredHelperExportName(comptime name: []const u8) bool {
    inline for (requiredHelperExportFieldNames()) |required_name| {
        if (std.mem.eql(u8, required_name, name)) return true;
    }
    return false;
}

fn isOptionalHelperExportDecl(comptime AlgebraType: type, comptime name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isUpper(name[0])) return false;
    if (isRequiredHelperExportName(name)) return false;

    const value = @field(AlgebraType, name);
    return @typeInfo(@TypeOf(value)) == .@"fn";
}

fn algebraHelperExportType(comptime AlgebraType: type) type {
    const names = helperExportFieldNames(AlgebraType);
    var field_types: [names.len]type = undefined;
    var field_attrs: [names.len]std.builtin.Type.StructField.Attributes = undefined;

    inline for (names, &field_types, &field_attrs) |name, *field_type, *field_attr| {
        field_type.* = @TypeOf(@field(AlgebraType, name));
        field_attr.* = .{};
    }

    return @Struct(
        .auto,
        null,
        names,
        &field_types,
        &field_attrs,
    );
}

/// Generates facade-ready reexports for a signature-baked algebra namespace.
pub fn AlgebraHelperExports(comptime AlgebraType: type) algebraHelperExportType(AlgebraType) {
    comptime {
        if (!hasAllRequiredHelperExports(AlgebraType)) {
            @compileError("expected an Algebra-like namespace with the helper constructors");
        }
    }

    const Result = algebraHelperExportType(AlgebraType);
    const names = helperExportFieldNames(AlgebraType);
    var result: Result = undefined;

    inline for (names) |name| {
        @field(result, name) = @field(AlgebraType, name);
    }

    return result;
}

/// Returns a signature-baked algebra namespace for a fixed `Cl(p, q, r)`.
pub fn Algebra(comptime sig: MetricSignature) type {
    return AlgebraWithNamingOptions(sig, SignedBladeNamingOptions.fromSignature(sig));
}

/// Returns a signature-baked algebra namespace with naming options.
pub fn AlgebraWithNamingOptions(comptime sig: MetricSignature, comptime naming_options: SignedBladeNamingOptions) type {
    return struct {
        pub const metric_signature = sig;
        pub const dimension = metric_signature.dimension();
        pub const signed_blade_naming_options = naming_options;
        pub const HelperSurface = algebraBoundHelpers(metric_signature, signed_blade_naming_options);
        /// Alias-only helper type for facade reexports.
        pub const HelperAliases = AlgebraHelperExports(HelperSurface);
    };
}

pub const fullSignedBladeFromIndicesWithSignature = multivector.fullSignedBladeFromIndicesWithSignature;
pub const writeMultivector = multivector.writeMultivector;

test "ga facade exposes core and specialized modules" {
    try std.testing.expect(choose(5, 2) == blades.choose(5, 2));
    try std.testing.expect(bladeCount(3) == blades.bladeCount(3));
    try std.testing.expect(isSignedBlade("e(1,2)", 2));

    const sig: MetricSignature = .{ .p = 1, .q = 1 };
    const value = fullSignedBladeFromIndicesWithSignature(i32, sig, &.{ 2, 2 });
    try std.testing.expectEqual(@as(i32, -1), value.coeff(.init(0)));

    const E2 = Algebra(.euclidean(2)).HelperSurface.Basis(f64);
    const e1 = E2.e(1);
    const half_turn = rotors2d.planarRotor(f64, std.math.pi);
    const rotated_e1 = rotors2d.rotated(e1, half_turn);
    try std.testing.expect(rotors2d.nearlyEqual(rotated_e1.coeff(.init(0b01)), -1.0, 1e-12));
    try std.testing.expect(rotors2d.nearlyEqual(rotated_e1.coeff(.init(0b10)), 0.0, 1e-12));
}

test "signature-baked algebra namespace drives metric-dependent products" {
    const Minkowski11: MetricSignature = .{ .p = 1, .q = 1 };
    const Cl11 = Algebra(Minkowski11);

    const e2 = Cl11.HelperSurface.Basis(i32).e(2);
    const e2_squared = e2.gp(e2);
    try std.testing.expectEqual(@as(i32, -1), e2_squared.coeff(.init(0)));
}

test "algebra naming options can expose span-mapped parser indices" {
    const sig: MetricSignature = .{ .p = 3, .q = 0, .r = 1 };
    const spans = comptime BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const opts = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    const parsed = try parseSignedBladeWithOptions("e0", sig.dimension(), opts);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, parsed);

    const Cl301 = AlgebraWithNamingOptions(sig, opts);
    const E = Cl301.HelperSurface.Basis(f64);
    try std.testing.expect(E.signedBlade("e0").eql(E.e(0)));
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBladeWithOptions("e4", sig.dimension(), opts));
}

test "generated algebra helper exports include optional helpers when available" {
    const Cl2 = Algebra(.euclidean(2));

    const helpers = AlgebraHelperExports(Cl2.HelperSurface);
    try std.testing.expect(@hasField(@TypeOf(helpers), "Trivector"));

    const E2 = helpers.Basis(f64);
    try std.testing.expect(E2.e(1).eql(Cl2.HelperSurface.Basis(f64).e(1)));
}

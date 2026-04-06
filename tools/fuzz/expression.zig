const std = @import("std");
const ga = @import("zmath").ga;

const blades = ga.blades;
const blade_parsing = ga.blade_parsing;
const expression = ga.expression;
const multivector = ga.multivector;

fn smithedScalar(smith: *std.testing.Smith) f32 {
    return @as(f32, @floatFromInt(smith.value(i8))) / 8.0;
}

fn smithedFullValue(comptime Full: type, smith: *std.testing.Smith) Full {
    return Full.init(.{
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
    });
}

fn fuzzRuntimeExpressionCorpusCase(case: anytype, smith: *std.testing.Smith) !void {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const E3 = ga.Algebra(sig).Instantiate(f32);
    const naming_options = blade_parsing.SignedBladeNamingOptions.euclidean(3);
    const Basis = E3.Basis;
    const Full = E3.Full;
    const Scalar = E3.Scalar;
    const scalar = smithedScalar(smith);
    const other_scalar = smithedScalar(smith);

    const v = Basis.Vector.init(.{
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
    });
    const a = Basis.Vector.init(.{
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
    });
    const b = Basis.Vector.init(.{
        smithedScalar(smith),
        smithedScalar(smith),
        smithedScalar(smith),
    });

    const actual: Full, const expected: Full = switch (case) {
        .constant => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "2*e12 + e21");
            defer expr.deinit();
            break :blk .{
                try expr.eval(.{}),
                Basis.Bivector.init(.{ 1, 0, 0 }).cast(Full),
            };
        },
        .named => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "2*e(1,2) + 3*{v}");
            defer expr.deinit();
            break :blk .{
                try expr.eval(.{ .v = v }),
                Basis.Bivector.init(.{ 2, 0, 0 }).add(v.scale(3)).cast(Full),
            };
        },
        .tuple => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "{} + {}");
            defer expr.deinit();
            const slot_values = [_]Full{
                Scalar.init(.{scalar}).cast(Full),
                Scalar.init(.{other_scalar}).cast(Full),
            };
            break :blk .{
                try expr.evalSlots(&slot_values),
                Full.ScalarType.init(.{scalar + other_scalar}).cast(Full),
            };
        },
        .reuse => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "{v} + {v}");
            defer expr.deinit();
            const slot_values = [_]Full{v.cast(Full)};
            break :blk .{
                try expr.evalSlots(&slot_values),
                v.add(v).cast(Full),
            };
        },
        .scaled => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "{s}*{v}");
            defer expr.deinit();
            break :blk .{
                try expr.eval(.{ .s = scalar, .v = v }),
                v.scale(scalar).cast(Full),
            };
        },
        .affine => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "-({s}*e_1) + {v}");
            defer expr.deinit();
            break :blk .{
                try expr.eval(.{ .s = scalar, .v = v }),
                Basis.e(1).scale(-scalar).add(v).cast(Full),
            };
        },
        .mul_pair => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "({a}+e1)*({b}-e2)");
            defer expr.deinit();
            break :blk .{
                try expr.eval(.{ .a = a, .b = b }),
                a.add(Basis.e(1)).gp(b.sub(Basis.e(2))).cast(Full),
            };
        },
        .inverse => blk: {
            var expr = try expression.compileRuntime(f32, sig, naming_options, std.testing.allocator, "(2*e1)^-1");
            defer expr.deinit();
            break :blk .{
                try expr.eval(.{}),
                Basis.e(1).scale(0.5).cast(Full),
            };
        },
    };

    try std.testing.expect(actual.eql(expected));
}

fn fuzzRandomRuntimeExpression(smith: *std.testing.Smith) !void {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const E3 = ga.Algebra(sig).Instantiate(f32);
    const options = blade_parsing.SignedBladeNamingOptions.euclidean(3);
    const Full = E3.Full;
    const alphabet = "e0123456789_[](){}+-*^. ,abcsv";

    var buf: [192]u8 = undefined;
    const len = smith.slice(&buf);
    for (buf[0..len]) |*byte| {
        byte.* = alphabet[byte.* % alphabet.len];
    }

    var compiled = expression.compileRuntime(f32, sig, options, std.testing.allocator, buf[0..len]) catch |err| switch (err) {
        error.MissingBasisPrefix,
        error.EmptySignedBlade,
        error.InvalidBasisIndex,
        error.InvalidBasisSeparator,
        error.InvalidBasisDelimiter,
        error.TrailingBasisSeparator,
        error.InvalidBasisConfiguration,
        error.UnexpectedToken,
        error.UnsupportedExponent,
        error.UnterminatedPlaceholder,
        error.MissingClosingParen,
        error.UnexpectedTrailingInput,
        error.InverseRequiresConstant,
        error.UndefinedInverse,
        error.InvalidNumericLiteral,
        => return,
        error.OutOfMemory => return err,
    };
    defer compiled.deinit();

    const slot_values = try std.testing.allocator.alloc(Full, compiled.placeholders.len);
    defer std.testing.allocator.free(slot_values);
    for (slot_values) |*slot| {
        slot.* = smithedFullValue(Full, smith);
    }

    _ = try compiled.evalSlots(slot_values);
}

test "expression fuzz: runtime parser and evaluator stay consistent" {
    const Case = enum(u3) {
        constant,
        named,
        tuple,
        reuse,
        scaled,
        affine,
        mul_pair,
        inverse,
    };

    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            inline for (std.meta.tags(Case)) |case| {
                try fuzzRuntimeExpressionCorpusCase(case, smith);
            }

            while (!smith.eosWeightedSimple(31, 1)) {
                try fuzzRuntimeExpressionCorpusCase(smith.value(Case), smith);
                try fuzzRandomRuntimeExpression(smith);
            }
        }
    }.testOne, .{});
}

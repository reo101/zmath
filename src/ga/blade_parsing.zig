const std = @import("std");
const blades = @import("blades.zig");

/// Bitset representation of a basis blade.
pub const BladeMask = blades.BladeMask;

/// Orientation sign attached to a canonicalized signed blade.
pub const OrientationSign = blades.OrientationSign;

/// Parsed signed blade as an orientation sign plus canonical blade mask.
pub const SignedBladeSpec = blades.SignedBladeSpec;

/// Parsing errors for signed-blade syntax.
pub const SignedBladeParseError = error{
    MissingBasisPrefix,
    EmptySignedBlade,
    InvalidBasisIndex,
    InvalidBasisSeparator,
    InvalidBasisDelimiter,
    TrailingBasisSeparator,
};

/// Naming and parser behavior switches for signed-blade syntax.
pub const SignedBladeNamingOptions = struct {
    /// Basis-index partition used for parser/programming-visible naming.
    ///
    /// This is required so parser/programming-visible indexing is always
    /// explicit and derived from one source of truth.
    basis_spans: blades.BasisIndexSpans,

    /// Required prefix byte for signed-blade names (default: `e`).
    basis_prefix: u8 = 'e',

    /// Whether compact spellings like `e12` are accepted.
    allow_compact_form: bool = true,

    /// Whether underscore spellings like `e_10_2` are accepted.
    allow_underscore_form: bool = true,

    /// Whether parenthesized spellings like `e(10,2)` are accepted.
    allow_parenthesized_form: bool = true,

    /// Whether bracketed spellings like `e[10,2]` are accepted.
    allow_bracketed_form: bool = true,

    /// Builds naming options from basis spans while keeping parser syntax
    /// behavior at defaults (`basis_prefix = 'e'`, all forms enabled).
    pub fn withBasisSpans(basis_spans: blades.BasisIndexSpans) SignedBladeNamingOptions {
        return .{ .basis_spans = basis_spans };
    }

    /// Default strict one-based naming (`e1..eN`) for dimension-only usage.
    pub fn euclidean(comptime dimension: usize) SignedBladeNamingOptions {
        return withBasisSpans(.init(.{ .positive = .range(1, dimension) }));
    }

    /// Default strict one-based naming derived from a metric signature.
    pub fn fromSignature(comptime sig: blades.MetricSignature) SignedBladeNamingOptions {
        return withBasisSpans(.fromSignature(sig));
    }

    fn assertValid(self: SignedBladeNamingOptions, comptime dimension: usize) void {
        self.basis_spans.assertValidForDimension(dimension);
    }

    fn resolveNamedBasisIndex(
        comptime self: SignedBladeNamingOptions,
        raw_index: usize,
        comptime dimension: usize,
    ) SignedBladeParseError!usize {
        self.assertValid(dimension);
        return self.basis_spans.resolveBasisIndex(raw_index, dimension) orelse error.InvalidBasisIndex;
    }
};

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn parseBasisIndex(
    comptime name: []const u8,
    position: *usize,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    if (position.* >= name.len or !isDigit(name[position.*])) {
        return error.InvalidBasisIndex;
    }

    const start = position.*;
    var value: usize = 0;
    while (position.* < name.len and isDigit(name[position.*])) : (position.* += 1) {
        value = value * 10 + (name[position.*] - '0');
    }

    if (position.* - start > 1 and name[start] == '0') return error.InvalidBasisIndex;

    return options.resolveNamedBasisIndex(value, dimension);
}

fn applyParsedIndex(
    spec: *SignedBladeSpec,
    basis_index: usize,
    comptime dimension: usize,
) void {
    blades.applyBasisIndex(spec, basis_index, dimension);
}

const SeparatedBladeSyntax = struct {
    start: usize,
    end: usize,
    separator: u8,
    allow_leading_separator: bool,
    trailing_separator_error: SignedBladeParseError,
};

fn parseSeparatedSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime syntax: SeparatedBladeSyntax,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    var spec = SignedBladeSpec{ .sign = .positive, .mask = .init(0) };
    var position = syntax.start;

    if (syntax.allow_leading_separator and position < syntax.end and name[position] == syntax.separator) {
        position += 1;
    }
    if (position >= syntax.end) return error.EmptySignedBlade;

    while (true) {
        const basis_index = try parseBasisIndex(name, &position, dimension, options);
        applyParsedIndex(&spec, basis_index, dimension);

        if (position == syntax.end) return spec;
        if (name[position] != syntax.separator) return error.InvalidBasisSeparator;

        position += 1;
        if (position == syntax.end) return syntax.trailing_separator_error;
    }
}

fn hasUnderscoreSyntax(comptime name: []const u8) bool {
    return if (name.len <= 1) false else std.mem.indexOfScalar(u8, name[1..], '_') != null;
}

fn invalidSignedBladeCompileError(comptime name: []const u8, comptime dimension: usize, comptime err: SignedBladeParseError) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid signed blade `{s}` for this algebra of dimension {d}: {s}",
        .{ name, dimension, @errorName(err) },
    ));
}

fn invalidBasisIndexCompileError(comptime raw_index: usize, comptime dimension: usize, comptime err: SignedBladeParseError) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid basis index `{d}` for this algebra of dimension {d}: {s}",
        .{ raw_index, dimension, @errorName(err) },
    ));
}

/// Signed-blade syntax cluster:
/// - compact identifier form: `e12`
/// - underscore identifier forms: `e1_2`, `e_10_2`
/// - delimited list forms: `e(10,2)`, `e[10,2]`
///
/// The compact form tokenizes one digit at a time, so `e12` means `e1 e2`.
/// Use a leading underscore when a multi-digit basis index must stay intact,
/// such as `e_12` for the single basis vector `e12`.
fn parseCompactSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    var spec = SignedBladeSpec{ .sign = .positive, .mask = .init(0) };
    inline for (name[1..], 1..) |char, position| {
        if (char == '_' or char == ',' or char == '-' or char == ')' or char == ']') {
            return if (position == 1) error.InvalidBasisIndex else error.InvalidBasisSeparator;
        }

        const raw_index: usize = switch (char) {
            '0'...'9' => @as(usize, char - '0'),
            else => return error.InvalidBasisIndex,
        };
        const basis_index = try options.resolveNamedBasisIndex(raw_index, dimension);

        applyParsedIndex(&spec, basis_index, dimension);
    }

    return spec;
}

/// Parses underscore-separated signed blades such as `e1_2` or `e_10_2`.
fn parseUnderscoreSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len < 3) return error.EmptySignedBlade;

    return parseSeparatedSignedBlade(name, dimension, .{
        .start = 1,
        .end = name.len,
        .separator = '_',
        .allow_leading_separator = true,
        .trailing_separator_error = error.InvalidBasisIndex,
    }, options);
}

/// Parses delimited signed blades such as `e(1,2)` or `e[10,2]`.
fn parseDelimitedSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime open: u8,
    comptime close: u8,
    comptime separator: u8,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len < 5) return error.EmptySignedBlade;
    if (name[1] != open or name[name.len - 1] != close) return error.InvalidBasisDelimiter;

    return parseSeparatedSignedBlade(name, dimension, .{
        .start = 2,
        .end = name.len - 1,
        .separator = separator,
        .allow_leading_separator = false,
        .trailing_separator_error = error.TrailingBasisSeparator,
    }, options);
}

/// Returns whether `name` is a valid signed-blade spelling for the algebra.
pub fn isSignedBlade(comptime name: []const u8, comptime dimension: usize) bool {
    _ = parseSignedBlade(name, dimension) catch return false;
    return true;
}

/// Returns whether `name` is a valid signed-blade spelling under naming options.
pub fn isSignedBladeWithOptions(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) bool {
    _ = parseSignedBladeWithOptions(name, dimension, options) catch return false;
    return true;
}

/// Parses a signed blade into a canonical sign-plus-mask representation.
pub fn parseSignedBlade(comptime name: []const u8, comptime dimension: usize) SignedBladeParseError!SignedBladeSpec {
    return parseSignedBladeWithOptions(name, dimension, SignedBladeNamingOptions.euclidean(dimension));
}

/// Parses a signed blade into a canonical sign-plus-mask representation under naming options.
pub fn parseSignedBladeWithOptions(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len == 0 or name[0] != options.basis_prefix) return error.MissingBasisPrefix;
    if (name.len < 2) return error.EmptySignedBlade;

    return switch (name[1]) {
        '(' => if (options.allow_parenthesized_form)
            parseDelimitedSignedBlade(name, dimension, '(', ')', ',', options)
        else
            error.InvalidBasisDelimiter,
        '[' => if (options.allow_bracketed_form)
            parseDelimitedSignedBlade(name, dimension, '[', ']', ',', options)
        else
            error.InvalidBasisDelimiter,
        else => if (hasUnderscoreSyntax(name))
            if (options.allow_underscore_form)
                parseUnderscoreSignedBlade(name, dimension, options)
            else
                error.InvalidBasisSeparator
        else if (options.allow_compact_form)
            parseCompactSignedBlade(name, dimension, options)
        else
            error.InvalidBasisSeparator,
    };
}

/// Resolves one raw parser index under naming options.
pub fn resolveBasisIndexWithOptions(
    comptime raw_index: usize,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    return options.resolveNamedBasisIndex(raw_index, dimension);
}

/// Resolves one raw parser index under naming options or emits compile error.
pub fn expectBasisIndexWithOptions(
    comptime raw_index: usize,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) usize {
    return comptime resolveBasisIndexWithOptions(raw_index, dimension, options) catch |err| invalidBasisIndexCompileError(raw_index, dimension, err);
}

/// Resolves one basis-helper index (`Basis.e(index)`) under naming options.
pub fn resolveBasisHelperIndexWithOptions(
    comptime index: usize,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    return options.resolveNamedBasisIndex(index, dimension);
}

/// Resolves one basis-helper index (`Basis.e(index)`) or emits compile error.
pub fn expectBasisHelperIndexWithOptions(
    comptime index: usize,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) usize {
    return comptime resolveBasisHelperIndexWithOptions(index, dimension, options) catch |err| invalidBasisIndexCompileError(index, dimension, err);
}

/// Parses a signed blade or emits a compile error if the spelling is invalid.
pub fn expectSignedBlade(comptime name: []const u8, comptime dimension: usize) SignedBladeSpec {
    return comptime parseSignedBlade(name, dimension) catch |err| invalidSignedBladeCompileError(name, dimension, err);
}

/// Parses a signed blade with naming options or emits a compile error if invalid.
pub fn expectSignedBladeWithOptions(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: SignedBladeNamingOptions,
) SignedBladeSpec {
    return comptime parseSignedBladeWithOptions(name, dimension, options) catch |err| invalidSignedBladeCompileError(name, dimension, err);
}

test "signed blades keep compact and multi-digit forms distinct" {
    const compact = try parseSignedBlade("e12", 12);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b011) }, compact);

    const single = try parseSignedBlade("e_12", 12);
    try std.testing.expectEqual(
        SignedBladeSpec{ .sign = .positive, .mask = .init(@as(u64, 1) << 11) },
        single,
    );

    const swapped = try parseSignedBlade("e21", 2);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b011) }, swapped);
}

test "invalid signed blades produce parse errors" {
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e10", 3));
    try std.testing.expectError(error.InvalidBasisSeparator, parseSignedBlade("e1-2", 3));
    try std.testing.expectError(error.TrailingBasisSeparator, parseSignedBlade("e(1,2,)", 3));
}

test "delimited and underscore forms agree on canonical output" {
    const from_parens = try parseSignedBlade("e(3,1,2)", 3);
    const from_brackets = try parseSignedBlade("e[3,1,2]", 3);
    const from_underscore = try parseSignedBlade("e_3_1_2", 3);

    try std.testing.expectEqual(from_parens, from_brackets);
    try std.testing.expectEqual(from_brackets, from_underscore);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b111) }, from_parens);
}

test "isSignedBlade rejects malformed delimiters and separators" {
    try std.testing.expect(!isSignedBlade("e(1,2]", 3));
    try std.testing.expect(!isSignedBlade("e[1;2]", 3));
    try std.testing.expect(!isSignedBlade("e_", 3));
    try std.testing.expect(isSignedBlade("e(1,2)", 3));
}

test "naming options can map e0 through degenerate parser span" {
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const options = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    const e0 = try parseSignedBladeWithOptions("e0", 4, options);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, e0);

    const e10 = try parseSignedBladeWithOptions("e10", 4, options);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b1001) }, e10);

    const mixed = try parseSignedBladeWithOptions("e(1,0,2)", 4, options);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b1011) }, mixed);

    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e0", 4));
    try std.testing.expect(isSignedBladeWithOptions("e_0_1", 4, options));
}

test "e0 alias requires singleton degenerate span" {
    const no_degenerate = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{ .positive = .range(1, 3) }),
    };
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBladeWithOptions("e0", 4, no_degenerate));

    const allowed_spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 2),
        .degenerate = .range(3, 4),
    });
    const allowed_range = comptime SignedBladeNamingOptions{
        .basis_spans = allowed_spans,
    };
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBladeWithOptions("e0", 4, allowed_range));
}

test "basis index resolution with options derives e0 alias from spans" {
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = blades.BasisIndexSpan.range(1, 3),
        .degenerate = blades.BasisIndexSpan.singleton(0),
    });
    const options = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    try std.testing.expectEqual(@as(usize, 4), try resolveBasisIndexWithOptions(0, 4, options));
    try std.testing.expectEqual(@as(usize, 2), try resolveBasisIndexWithOptions(2, 4, options));
    try std.testing.expectEqual(@as(usize, 4), try resolveBasisHelperIndexWithOptions(0, 4, options));
    try std.testing.expectError(error.InvalidBasisIndex, resolveBasisIndexWithOptions(4, 4, options));
}

test "configured parser indices are the only accepted spellings" {
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const mapped = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    try std.testing.expect(isSignedBladeWithOptions("e0", 4, mapped));
    try std.testing.expect(!isSignedBladeWithOptions("e4", 4, mapped));
    try std.testing.expectError(error.InvalidBasisIndex, resolveBasisIndexWithOptions(4, 4, mapped));
}

test "unconfigured parser indices are rejected" {
    const options = comptime SignedBladeNamingOptions.euclidean(4);
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBladeWithOptions("e0", 4, options));
}

test "syntax policy can gate prefix and accepted forms" {
    const prefixed = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{ .positive = .range(1, 3) }),
        .basis_prefix = 'v',
        .allow_parenthesized_form = false,
        .allow_bracketed_form = false,
    };

    try std.testing.expect(isSignedBladeWithOptions("v12", 3, prefixed));
    try std.testing.expectError(error.MissingBasisPrefix, parseSignedBladeWithOptions("e12", 3, prefixed));
    try std.testing.expectError(error.InvalidBasisDelimiter, parseSignedBladeWithOptions("v(1,2)", 3, prefixed));

    const no_compact = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{ .positive = .range(1, 12) }),
        .allow_compact_form = false,
        .allow_underscore_form = true,
    };
    try std.testing.expectError(error.InvalidBasisSeparator, parseSignedBladeWithOptions("e12", 12, no_compact));
    try std.testing.expect(isSignedBladeWithOptions("e_12", 12, no_compact));
}

test "e0 alias is only enabled by singleton degenerate span" {
    const no_spans = comptime SignedBladeNamingOptions.euclidean(4);
    try std.testing.expectError(error.InvalidBasisIndex, resolveBasisIndexWithOptions(0, 4, no_spans));

    const no_singleton = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{
            .positive = .range(1, 2),
            .degenerate = .range(3, 4),
        }),
    };
    try std.testing.expectError(error.InvalidBasisIndex, resolveBasisIndexWithOptions(0, 4, no_singleton));

    const singleton = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{
            .positive = .range(1, 3),
            .degenerate = .singleton(0),
        }),
    };
    try std.testing.expectEqual(@as(usize, 4), try resolveBasisIndexWithOptions(0, 4, singleton));
}

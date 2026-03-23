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

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn isNonZeroDigit(char: u8) bool {
    return char >= '1' and char <= '9';
}

fn parseBasisIndex(
    comptime name: []const u8,
    position: *usize,
    comptime dimension: usize,
) SignedBladeParseError!usize {
    if (position.* >= name.len or !isNonZeroDigit(name[position.*])) {
        return error.InvalidBasisIndex;
    }

    var value: usize = 0;
    while (position.* < name.len and isDigit(name[position.*])) : (position.* += 1) {
        value = value * 10 + (name[position.*] - '0');
    }

    if (value == 0 or value > dimension) return error.InvalidBasisIndex;
    return value;
}

fn applyParsedIndex(
    spec: *SignedBladeSpec,
    one_based_index: usize,
    comptime dimension: usize,
) void {
    blades.applyBasisIndex(spec, one_based_index, dimension);
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
) SignedBladeParseError!SignedBladeSpec {
    var spec = SignedBladeSpec{ .sign = .positive, .mask = .init(0) };
    var position = syntax.start;

    if (syntax.allow_leading_separator and position < syntax.end and name[position] == syntax.separator) {
        position += 1;
    }
    if (position >= syntax.end) return error.EmptySignedBlade;

    while (true) {
        const one_based_index = try parseBasisIndex(name, &position, dimension);
        applyParsedIndex(&spec, one_based_index, dimension);

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
) SignedBladeParseError!SignedBladeSpec {
    var spec = SignedBladeSpec{ .sign = .positive, .mask = .init(0) };
    inline for (name[1..], 1..) |char, position| {
        if (char == '_' or char == ',' or char == '-' or char == ')' or char == ']') {
            return if (position == 1) error.InvalidBasisIndex else error.InvalidBasisSeparator;
        }

        const one_based_index: usize = switch (char) {
            '1'...'9' => @as(usize, char - '0'),
            else => return error.InvalidBasisIndex,
        };
        if (one_based_index > dimension) return error.InvalidBasisIndex;

        applyParsedIndex(&spec, one_based_index, dimension);
    }

    return spec;
}

/// Parses underscore-separated signed blades such as `e1_2` or `e_10_2`.
fn parseUnderscoreSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len < 3) return error.EmptySignedBlade;

    return parseSeparatedSignedBlade(name, dimension, .{
        .start = 1,
        .end = name.len,
        .separator = '_',
        .allow_leading_separator = true,
        .trailing_separator_error = error.InvalidBasisIndex,
    });
}

/// Parses delimited signed blades such as `e(1,2)` or `e[10,2]`.
fn parseDelimitedSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime open: u8,
    comptime close: u8,
    comptime separator: u8,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len < 5) return error.EmptySignedBlade;
    if (name[1] != open or name[name.len - 1] != close) return error.InvalidBasisDelimiter;

    return parseSeparatedSignedBlade(name, dimension, .{
        .start = 2,
        .end = name.len - 1,
        .separator = separator,
        .allow_leading_separator = false,
        .trailing_separator_error = error.TrailingBasisSeparator,
    });
}

/// Returns whether `name` is a valid signed-blade spelling for the algebra.
pub fn isSignedBlade(comptime name: []const u8, comptime dimension: usize) bool {
    _ = parseSignedBlade(name, dimension) catch return false;
    return true;
}

/// Parses a signed blade into a canonical sign-plus-mask representation.
pub fn parseSignedBlade(comptime name: []const u8, comptime dimension: usize) SignedBladeParseError!SignedBladeSpec {
    if (name.len == 0 or name[0] != 'e') return error.MissingBasisPrefix;
    if (name.len < 2) return error.EmptySignedBlade;

    return switch (name[1]) {
        '(' => parseDelimitedSignedBlade(name, dimension, '(', ')', ','),
        '[' => parseDelimitedSignedBlade(name, dimension, '[', ']', ','),
        else => if (hasUnderscoreSyntax(name))
            parseUnderscoreSignedBlade(name, dimension)
        else
            parseCompactSignedBlade(name, dimension),
    };
}

/// Parses a signed blade or emits a compile error if the spelling is invalid.
pub fn expectSignedBlade(comptime name: []const u8, comptime dimension: usize) SignedBladeSpec {
    return comptime parseSignedBlade(name, dimension) catch |err| invalidSignedBladeCompileError(name, dimension, err);
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

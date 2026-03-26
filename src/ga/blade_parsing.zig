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
    InvalidBasisConfiguration,
};

/// Result of parsing a signed blade token from inside a larger source string.
pub const SignedBladePrefixParseResult = struct {
    spec: SignedBladeSpec,
    end: usize,
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

    fn validate(self: SignedBladeNamingOptions, dimension: usize) SignedBladeParseError!void {
        self.basis_spans.validateForDimension(dimension) catch return error.InvalidBasisConfiguration;
    }

    fn resolveNamedBasisIndexComptime(
        comptime self: SignedBladeNamingOptions,
        named_index: usize,
        comptime dimension: usize,
    ) SignedBladeParseError!usize {
        self.assertValid(dimension);
        return self.basis_spans.resolveNamedBasisIndex(named_index, dimension) orelse error.InvalidBasisIndex;
    }

    fn resolveNamedBasisIndexRuntime(
        self: SignedBladeNamingOptions,
        named_index: usize,
        dimension: usize,
    ) SignedBladeParseError!usize {
        try self.validate(dimension);
        const resolved = self.basis_spans.resolveNamedBasisIndexRuntime(named_index, dimension) catch return error.InvalidBasisConfiguration;
        return resolved orelse error.InvalidBasisIndex;
    }
};

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn runtimeDefaultOptions(dimension: usize) SignedBladeNamingOptions {
    return SignedBladeNamingOptions.withBasisSpans(.init(.{
        .positive = .range(1, dimension),
    }));
}

fn parseBasisIndex(
    name: []const u8,
    position: *usize,
    dimension: usize,
    options: SignedBladeNamingOptions,
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

    return options.resolveNamedBasisIndexRuntime(value, dimension);
}

fn applyParsedIndex(
    spec: *SignedBladeSpec,
    basis_index: usize,
    dimension: usize,
) void {
    blades.applyBasisIndexRuntime(spec, basis_index, dimension);
}

const SeparatedBladeSyntax = struct {
    start: usize,
    end: usize,
    separator: u8,
    allow_leading_separator: bool,
    trailing_separator_error: SignedBladeParseError,
};

fn parseSeparatedSignedBlade(
    name: []const u8,
    dimension: usize,
    syntax: SeparatedBladeSyntax,
    options: SignedBladeNamingOptions,
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

fn hasUnderscoreSyntax(name: []const u8) bool {
    return if (name.len <= 1) false else std.mem.indexOfScalar(u8, name[1..], '_') != null;
}

fn invalidSignedBladeCompileError(comptime name: []const u8, comptime dimension: usize, comptime err: SignedBladeParseError) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid signed blade `{s}` for this algebra of dimension {d}: {s}",
        .{ name, dimension, @errorName(err) },
    ));
}

fn invalidBasisIndexCompileError(comptime named_index: usize, comptime dimension: usize, comptime err: SignedBladeParseError) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid basis index `{d}` for this algebra of dimension {d}: {s}",
        .{ named_index, dimension, @errorName(err) },
    ));
}

fn parseCompactSignedBlade(
    name: []const u8,
    dimension: usize,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    var spec = SignedBladeSpec{ .sign = .positive, .mask = .init(0) };
    for (name[1..], 1..) |char, position| {
        if (char == '_' or char == ',' or char == '-' or char == ')' or char == ']') {
            return if (position == 1) error.InvalidBasisIndex else error.InvalidBasisSeparator;
        }

        const named_index: usize = switch (char) {
            '0'...'9' => @as(usize, char - '0'),
            else => return error.InvalidBasisIndex,
        };
        const basis_index = try options.resolveNamedBasisIndexRuntime(named_index, dimension);

        applyParsedIndex(&spec, basis_index, dimension);
    }

    return spec;
}

fn parseUnderscoreSignedBlade(
    name: []const u8,
    dimension: usize,
    options: SignedBladeNamingOptions,
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

fn parseDelimitedSignedBlade(
    name: []const u8,
    dimension: usize,
    open: u8,
    close: u8,
    separator: u8,
    options: SignedBladeNamingOptions,
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

/// Returns whether `name` is a valid signed-blade spelling under naming options.
pub fn isSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
) bool {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimension);
    _ = parseSignedBladeImpl(name, dimension, opts) catch return false;
    return true;
}

/// Runtime-capable counterpart to `isSignedBlade`.
pub fn isSignedBladeRuntime(
    name: []const u8,
    dimension: usize,
    options: ?SignedBladeNamingOptions,
) bool {
    const opts = options orelse runtimeDefaultOptions(dimension);
    _ = parseSignedBladeImpl(name, dimension, opts) catch return false;
    return true;
}

/// Parses a signed blade into a canonical sign-plus-mask representation under naming options.
/// If `panicking` is true, invalid blades will trigger a compile error instead of returning an error union.
pub fn parseSignedBlade(
    comptime name: []const u8,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) SignedBladeSpec else SignedBladeParseError!SignedBladeSpec {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimension);
    if (panicking) {
        return comptime parseSignedBladeImpl(name, dimension, opts) catch |err| invalidSignedBladeCompileError(name, dimension, err);
    } else {
        return parseSignedBladeImpl(name, dimension, opts);
    }
}

fn parseSignedBladeImpl(
    name: []const u8,
    dimension: usize,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len == 0 or name[0] != options.basis_prefix) return error.MissingBasisPrefix;
    if (name.len < 2) return error.EmptySignedBlade;
    try options.validate(dimension);

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

fn scanSignedBladeTokenEnd(
    source: []const u8,
    start: usize,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    if (start >= source.len or source[start] != options.basis_prefix) return error.MissingBasisPrefix;
    if (start + 1 >= source.len) return error.EmptySignedBlade;

    var position = start + 1;
    return switch (source[position]) {
        '(' => blk: {
            position += 1;
            while (position < source.len and source[position] != ')') : (position += 1) {}
            if (position >= source.len) return error.InvalidBasisDelimiter;
            break :blk position + 1;
        },
        '[' => blk: {
            position += 1;
            while (position < source.len and source[position] != ']') : (position += 1) {}
            if (position >= source.len) return error.InvalidBasisDelimiter;
            break :blk position + 1;
        },
        else => blk: {
            while (position < source.len and (isDigit(source[position]) or source[position] == '_')) : (position += 1) {}
            break :blk position;
        },
    };
}

/// Runtime-capable counterpart to `parseSignedBlade`.
pub fn parseSignedBladeRuntime(
    name: []const u8,
    dimension: usize,
    options: ?SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    const opts = options orelse runtimeDefaultOptions(dimension);
    return parseSignedBladeImpl(name, dimension, opts);
}

/// Parses a signed blade starting at `start` inside a larger source string and
/// returns both the canonical spec and the first byte past the consumed token.
pub fn parseSignedBladePrefix(
    comptime source: []const u8,
    comptime start: usize,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) SignedBladePrefixParseResult else SignedBladeParseError!SignedBladePrefixParseResult {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimension);

    if (panicking) {
        const end = comptime scanSignedBladeTokenEnd(source, start, opts) catch |err| invalidSignedBladeCompileError(source[start..], dimension, err);
        const token = source[start..end];
        return .{
            .spec = comptime parseSignedBladeImpl(token, dimension, opts) catch |err| invalidSignedBladeCompileError(token, dimension, err),
            .end = end,
        };
    }

    const end = comptime scanSignedBladeTokenEnd(source, start, opts) catch |err| return err;
    const token = source[start..end];
    return .{
        .spec = try parseSignedBladeImpl(token, dimension, opts),
        .end = end,
    };
}

/// Runtime-capable counterpart to `parseSignedBladePrefix`.
pub fn parseSignedBladePrefixRuntime(
    source: []const u8,
    start: usize,
    dimension: usize,
    options: ?SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladePrefixParseResult {
    const opts = options orelse runtimeDefaultOptions(dimension);
    const end = try scanSignedBladeTokenEnd(source, start, opts);
    const token = source[start..end];
    return .{
        .spec = try parseSignedBladeImpl(token, dimension, opts),
        .end = end,
    };
}

/// Resolves one named basis index under naming options.
/// If `panicking` is true, invalid indices will trigger a compile error instead of returning an error union.
pub fn resolveNamedBasisIndex(
    comptime named_index: usize,
    comptime dimension: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) usize else SignedBladeParseError!usize {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimension);
    if (panicking) {
        return comptime opts.resolveNamedBasisIndexComptime(named_index, dimension) catch |err| invalidBasisIndexCompileError(named_index, dimension, err);
    } else {
        return opts.resolveNamedBasisIndexComptime(named_index, dimension);
    }
}

/// Runtime-capable counterpart to `resolveNamedBasisIndex`.
pub fn resolveNamedBasisIndexRuntime(
    named_index: usize,
    dimension: usize,
    options: ?SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    const opts = options orelse runtimeDefaultOptions(dimension);
    return opts.resolveNamedBasisIndexRuntime(named_index, dimension);
}

test "signed blades keep compact and multi-digit forms distinct" {
    const compact = try parseSignedBlade("e12", 12, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b011) }, compact);

    const single = try parseSignedBlade("e_12", 12, null, false);
    try std.testing.expectEqual(
        SignedBladeSpec{ .sign = .positive, .mask = .initOneBit(11) },
        single,
    );

    const swapped = try parseSignedBlade("e21", 2, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b011) }, swapped);
}

test "invalid signed blades produce parse errors" {
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e10", 3, null, false));
    try std.testing.expectError(error.InvalidBasisSeparator, parseSignedBlade("e1-2", 3, null, false));
    try std.testing.expectError(error.TrailingBasisSeparator, parseSignedBlade("e(1,2,)", 3, null, false));
}

test "delimited and underscore forms agree on canonical output" {
    const from_parens = try parseSignedBlade("e(3,1,2)", 3, null, false);
    const from_brackets = try parseSignedBlade("e[3,1,2]", 3, null, false);
    const from_underscore = try parseSignedBlade("e_3_1_2", 3, null, false);

    try std.testing.expectEqual(from_parens, from_brackets);
    try std.testing.expectEqual(from_brackets, from_underscore);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b111) }, from_parens);
}

test "isSignedBlade rejects malformed delimiters and separators" {
    try std.testing.expect(!isSignedBlade("e(1,2]", 3, null));
    try std.testing.expect(!isSignedBlade("e[1;2]", 3, null));
    try std.testing.expect(!isSignedBlade("e_", 3, null));
    try std.testing.expect(isSignedBlade("e(1,2)", 3, null));
}

test "signed blade prefix parser returns consumed length" {
    const parsed = try parseSignedBladePrefix("2*e(3,1,2) + tail", 2, 3, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b111) }, parsed.spec);
    try std.testing.expectEqual(@as(usize, 10), parsed.end);

    const compact = try parseSignedBladePrefix("e12+rest", 0, 12, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b011) }, compact.spec);
    try std.testing.expectEqual(@as(usize, 3), compact.end);
}

test "naming options can map e0 through degenerate parser span" {
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const options = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    const e0 = try parseSignedBlade("e0", 4, options, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b1000) }, e0);

    const e10 = try parseSignedBlade("e10", 4, options, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b1001) }, e10);

    const mixed = try parseSignedBlade("e(1,0,2)", 4, options, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b1011) }, mixed);

    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e0", 4, null, false));
    try std.testing.expect(isSignedBlade("e_0_1", 4, options));
}

test "e0 alias requires singleton degenerate span" {
    const no_degenerate = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{ .positive = .range(1, 3) }),
    };
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e0", 4, no_degenerate, false));

    const allowed_spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 2),
        .degenerate = .range(3, 4),
    });
    const allowed_range = comptime SignedBladeNamingOptions{
        .basis_spans = allowed_spans,
    };
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e0", 4, allowed_range, false));
}

test "basis index resolution with options derives e0 alias from spans" {
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = blades.BasisIndexSpan.range(1, 3),
        .degenerate = blades.BasisIndexSpan.singleton(0),
    });
    const options = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    try std.testing.expectEqual(@as(usize, 4), try resolveNamedBasisIndex(0, 4, options, false));
    try std.testing.expectEqual(@as(usize, 2), try resolveNamedBasisIndex(2, 4, options, false));
    try std.testing.expectEqual(@as(usize, 4), try resolveNamedBasisIndex(0, 4, options, false));
    try std.testing.expectError(error.InvalidBasisIndex, resolveNamedBasisIndex(4, 4, options, false));
}

test "configured named indices are the only accepted spellings" {
    const spans = comptime blades.BasisIndexSpans.init(.{
        .positive = .range(1, 3),
        .degenerate = .singleton(0),
    });
    const mapped = comptime SignedBladeNamingOptions{
        .basis_spans = spans,
    };

    try std.testing.expect(isSignedBlade("e0", 4, mapped));
    try std.testing.expect(!isSignedBlade("e4", 4, mapped));
    try std.testing.expectError(error.InvalidBasisIndex, resolveNamedBasisIndex(4, 4, mapped, false));
}

test "unconfigured named indices are rejected" {
    const options = comptime SignedBladeNamingOptions.euclidean(4);
    try std.testing.expectError(error.InvalidBasisIndex, parseSignedBlade("e0", 4, options, false));
}

test "syntax policy can gate prefix and accepted forms" {
    const prefixed = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{ .positive = .range(1, 3) }),
        .basis_prefix = 'v',
        .allow_parenthesized_form = false,
        .allow_bracketed_form = false,
    };

    try std.testing.expect(isSignedBlade("v12", 3, prefixed));
    try std.testing.expectError(error.MissingBasisPrefix, parseSignedBlade("e12", 3, prefixed, false));
    try std.testing.expectError(error.InvalidBasisDelimiter, parseSignedBlade("v(1,2)", 3, prefixed, false));

    const no_compact = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{ .positive = .range(1, 12) }),
        .allow_compact_form = false,
        .allow_underscore_form = true,
    };
    try std.testing.expectError(error.InvalidBasisSeparator, parseSignedBlade("e12", 12, no_compact, false));
    try std.testing.expect(isSignedBlade("e_12", 12, no_compact));
}

test "e0 alias is only enabled by singleton degenerate span" {
    const no_spans = comptime SignedBladeNamingOptions.euclidean(4);
    try std.testing.expectError(error.InvalidBasisIndex, resolveNamedBasisIndex(0, 4, no_spans, false));

    const no_singleton = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{
            .positive = .range(1, 2),
            .degenerate = .range(3, 4),
        }),
    };
    try std.testing.expectError(error.InvalidBasisIndex, resolveNamedBasisIndex(0, 4, no_singleton, false));

    const singleton = comptime SignedBladeNamingOptions{
        .basis_spans = .init(.{
            .positive = .range(1, 3),
            .degenerate = .singleton(0),
        }),
    };
    try std.testing.expectEqual(@as(usize, 4), try resolveNamedBasisIndex(0, 4, singleton, false));
}

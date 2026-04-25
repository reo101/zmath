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

/// A named alias that maps a string to a signed blade spec.
pub const BladeAlias = struct {
    name: []const u8,
    spec: SignedBladeSpec,
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

    /// Whether underscore spellings like `e_1_2` are accepted.
    allow_underscore_form: bool = true,

    /// Whether parenthesized spellings like `e(1,2)` are accepted.
    allow_parenthesized_form: bool = true,

    /// Whether bracketed spellings like `e[1,2]` are accepted.
    allow_bracketed_form: bool = true,

    /// Custom blade aliases (e.g., `i` → `e12` in Cl(2,0,0)).
    blade_aliases: []const BladeAlias = &.{},

    /// Optional aliases for each mapped basis vector in internal basis order.
    /// Prefer `withBasisNames()` so the count is checked against
    /// `basis_spans` at the call site.
    basis_names: ?[]const []const u8 = null,

    /// Builds naming options from basis spans while keeping parser syntax
    /// behavior at defaults (`basis_prefix = 'e'`, all forms enabled).
    pub fn withBasisSpans(basis_spans: blades.BasisIndexSpans) SignedBladeNamingOptions {
        return .{ .basis_spans = basis_spans };
    }

    pub fn withBasisNames(
        comptime basis_spans: blades.BasisIndexSpans,
        comptime names: [basis_spans.mappedBasisCount()][]const u8,
    ) SignedBladeNamingOptions {
        const aliases = comptime basisNameAliases(basis_spans, names);
        return .{
            .basis_spans = basis_spans,
            .blade_aliases = aliases[0..],
            .basis_names = names[0..],
        };
    }

    /// Default strict one-based naming (`e1..eN`) for dimensions-only usage.
    pub fn euclidean(comptime dimensions: usize) SignedBladeNamingOptions {
        return withBasisSpans(.init(.{ .positive = .range(1, dimensions) }));
    }

    /// Default strict one-based naming derived from a metric signature.
    pub fn fromSignature(comptime sig: blades.MetricSignature) SignedBladeNamingOptions {
        return withBasisSpans(.fromSignature(sig));
    }

    fn assertValid(comptime self: SignedBladeNamingOptions, comptime dimensions: usize) void {
        self.basis_spans.assertValidForDimensions(dimensions);
        if (self.basis_names) |names| {
            const expected = comptime self.basis_spans.mappedBasisCount();
            if (names.len != expected) {
                @compileError(std.fmt.comptimePrint(
                    "basis_names must contain exactly {} entries for the configured basis spans",
                    .{expected},
                ));
            }
        }
    }

    fn validate(self: SignedBladeNamingOptions, dimensions: usize) SignedBladeParseError!void {
        self.basis_spans.validateForDimensions(dimensions) catch return error.InvalidBasisConfiguration;
        if (self.basis_names) |names| {
            if (names.len != self.basis_spans.mappedBasisCount()) return error.InvalidBasisConfiguration;
        }
    }

    fn resolveNamedBasisIndexComptime(
        comptime self: SignedBladeNamingOptions,
        named_index: usize,
        comptime dimensions: usize,
    ) SignedBladeParseError!usize {
        self.assertValid(dimensions);
        return self.basis_spans.resolveNamedBasisIndex(named_index, dimensions) orelse error.InvalidBasisIndex;
    }

    fn resolveNamedBasisIndexRuntime(
        self: SignedBladeNamingOptions,
        named_index: usize,
        dimensions: usize,
    ) SignedBladeParseError!usize {
        try self.validate(dimensions);
        const resolved = self.basis_spans.resolveNamedBasisIndexRuntime(named_index, dimensions) catch return error.InvalidBasisConfiguration;
        return resolved orelse error.InvalidBasisIndex;
    }
};

fn basisNameAliasCount(
    comptime basis_spans: blades.BasisIndexSpans,
    comptime names: [basis_spans.mappedBasisCount()][]const u8,
) usize {
    @setEvalBranchQuota(10_000);
    var count: usize = 0;
    inline for (names, 0..) |name, index| {
        if (name.len == 0) {
            @compileError("basis_names entries must not be empty");
        }
        inline for (names[0..index]) |previous| {
            if (std.mem.eql(u8, name, previous)) {
                @compileError("basis_names entries must be unique");
            }
        }
        if (!indexedNameResolvesToBasisName(basis_spans, name, index)) {
            count += 1;
        }
    }
    return count;
}

fn basisNameAliases(
    comptime basis_spans: blades.BasisIndexSpans,
    comptime names: [basis_spans.mappedBasisCount()][]const u8,
) [basisNameAliasCount(basis_spans, names)]BladeAlias {
    var aliases: [basisNameAliasCount(basis_spans, names)]BladeAlias = undefined;
    var cursor: usize = 0;
    inline for (names, 0..) |name, internal_index| {
        if (comptime indexedNameResolvesToBasisName(basis_spans, name, internal_index)) continue;

        aliases[cursor] = .{
            .name = name,
            .spec = .{
                .sign = .positive,
                .mask = .initOneBit(internal_index),
            },
        };
        cursor += 1;
    }
    return aliases;
}

fn indexedNameResolvesToBasisName(
    comptime basis_spans: blades.BasisIndexSpans,
    comptime name: []const u8,
    comptime internal_index: usize,
) bool {
    @setEvalBranchQuota(10_000);
    if (!isIndexedSignedBladeName(name, 'e')) return false;

    const options = SignedBladeNamingOptions.withBasisSpans(basis_spans);
    const spec = parseSignedBladeImpl(name, basis_spans.mappedBasisCount(), options) catch return false;
    return spec.sign == .positive and spec.mask.eql(.initOneBit(internal_index));
}

const LeadingBladeSign = struct {
    sign: OrientationSign,
    operand_start: usize,
};

fn parseLeadingBladeSign(source: []const u8, start: usize) LeadingBladeSign {
    var sign: OrientationSign = .positive;
    var position = start;
    while (position < source.len) {
        switch (source[position]) {
            '+' => {},
            '-' => sign.flip(),
            else => break,
        }
        position += 1;
    }
    return .{ .sign = sign, .operand_start = position };
}

fn applyLeadingBladeSign(spec: SignedBladeSpec, sign: OrientationSign) SignedBladeSpec {
    return .{
        .sign = spec.sign.mul(sign),
        .mask = spec.mask,
    };
}

fn isIndexedSignedBladeName(comptime name: []const u8, comptime basis_prefix: u8) bool {
    const leading = comptime parseLeadingBladeSign(name, 0);
    const start = comptime leading.operand_start;
    if (name.len - start < 2 or name[start] != basis_prefix) return false;
    return switch (name[start + 1]) {
        '0'...'9', '_', '(', '[' => true,
        else => false,
    };
}

fn isDigit(char: u8) bool {
    return std.ascii.isDigit(char);
}

fn runtimeDefaultOptions(dimensions: usize) SignedBladeNamingOptions {
    return SignedBladeNamingOptions.withBasisSpans(.init(.{
        .positive = .range(1, dimensions),
    }));
}

fn parseBasisIndex(
    name: []const u8,
    position: *usize,
    dimensions: usize,
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

    return options.resolveNamedBasisIndexRuntime(value, dimensions);
}

fn applyParsedIndex(
    spec: *SignedBladeSpec,
    basis_index: usize,
    dimensions: usize,
) void {
    blades.applyBasisIndexRuntime(spec, basis_index, dimensions);
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
    dimensions: usize,
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
        const basis_index = try parseBasisIndex(name, &position, dimensions, options);
        applyParsedIndex(&spec, basis_index, dimensions);

        if (position == syntax.end) return spec;
        if (name[position] != syntax.separator) return error.InvalidBasisSeparator;

        position += 1;
        if (position == syntax.end) return syntax.trailing_separator_error;
    }
}

fn hasUnderscoreSyntax(name: []const u8) bool {
    return if (name.len <= 1) false else std.mem.indexOfScalar(u8, name[1..], '_') != null;
}

fn invalidSignedBladeCompileError(comptime name: []const u8, comptime dimensions: usize, comptime err: SignedBladeParseError) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid signed blade `{s}` for this algebra of dimensions {d}: {s}",
        .{ name, dimensions, @errorName(err) },
    ));
}

fn invalidBasisIndexCompileError(comptime named_index: usize, comptime dimensions: usize, comptime err: SignedBladeParseError) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid basis index `{d}` for this algebra of dimensions {d}: {s}",
        .{ named_index, dimensions, @errorName(err) },
    ));
}

fn parseCompactSignedBlade(
    name: []const u8,
    dimensions: usize,
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
        const basis_index = try options.resolveNamedBasisIndexRuntime(named_index, dimensions);

        applyParsedIndex(&spec, basis_index, dimensions);
    }

    return spec;
}

fn parseUnderscoreSignedBlade(
    name: []const u8,
    dimensions: usize,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len < 3) return error.EmptySignedBlade;

    return parseSeparatedSignedBlade(name, dimensions, .{
        .start = 1,
        .end = name.len,
        .separator = '_',
        .allow_leading_separator = true,
        .trailing_separator_error = error.InvalidBasisIndex,
    }, options);
}

fn parseDelimitedSignedBlade(
    name: []const u8,
    dimensions: usize,
    open: u8,
    close: u8,
    separator: u8,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (name.len < 5) return error.EmptySignedBlade;
    if (name[1] != open or name[name.len - 1] != close) return error.InvalidBasisDelimiter;

    return parseSeparatedSignedBlade(name, dimensions, .{
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
    comptime dimensions: usize,
    comptime options: ?SignedBladeNamingOptions,
) bool {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimensions);
    _ = parseSignedBladeImpl(name, dimensions, opts) catch return false;
    return true;
}

/// Runtime-capable counterpart to `isSignedBlade`.
pub fn isSignedBladeRuntime(
    name: []const u8,
    dimensions: usize,
    options: ?SignedBladeNamingOptions,
) bool {
    const opts = options orelse runtimeDefaultOptions(dimensions);
    _ = parseSignedBladeImpl(name, dimensions, opts) catch return false;
    return true;
}

/// Parses a signed blade into a canonical sign-plus-mask representation under naming options.
/// If `panicking` is true, invalid blades will trigger a compile error instead of returning an error union.
pub fn parseSignedBlade(
    comptime name: []const u8,
    comptime dimensions: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) SignedBladeSpec else SignedBladeParseError!SignedBladeSpec {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimensions);
    if (panicking) {
        return comptime parseSignedBladeImpl(name, dimensions, opts) catch |err| invalidSignedBladeCompileError(name, dimensions, err);
    } else {
        return parseSignedBladeImpl(name, dimensions, opts);
    }
}

fn resolveAlias(name: []const u8, options: SignedBladeNamingOptions) ?SignedBladeSpec {
    for (options.blade_aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias.spec;
    }
    return null;
}

fn parseSignedBladeImpl(
    name: []const u8,
    dimensions: usize,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    if (resolveAlias(name, options)) |spec| return spec;

    const leading = parseLeadingBladeSign(name, 0);
    const operand = name[leading.operand_start..];
    if (resolveAlias(operand, options)) |spec| return applyLeadingBladeSign(spec, leading.sign);
    if (operand.len == 0 or operand[0] != options.basis_prefix) return error.MissingBasisPrefix;
    if (operand.len < 2) return error.EmptySignedBlade;
    try options.validate(dimensions);

    const spec = try switch (operand[1]) {
        '(' => if (options.allow_parenthesized_form)
            parseDelimitedSignedBlade(operand, dimensions, '(', ')', ',', options)
        else
            error.InvalidBasisDelimiter,
        '[' => if (options.allow_bracketed_form)
            parseDelimitedSignedBlade(operand, dimensions, '[', ']', ',', options)
        else
            error.InvalidBasisDelimiter,
        else => if (hasUnderscoreSyntax(operand))
            if (options.allow_underscore_form)
                parseUnderscoreSignedBlade(operand, dimensions, options)
            else
                error.InvalidBasisSeparator
        else if (options.allow_compact_form)
            parseCompactSignedBlade(operand, dimensions, options)
        else
            error.InvalidBasisSeparator,
    };
    return applyLeadingBladeSign(spec, leading.sign);
}

fn scanAliasTokenEnd(source: []const u8, start: usize, options: SignedBladeNamingOptions) ?usize {
    var best_end: ?usize = null;
    for (options.blade_aliases) |alias| {
        if (start + alias.name.len <= source.len and
            std.mem.eql(u8, source[start..][0..alias.name.len], alias.name))
        {
            if (best_end == null or alias.name.len > best_end.? - start) {
                best_end = start + alias.name.len;
            }
        }
    }
    return best_end;
}

fn scanSignedBladeTokenEnd(
    source: []const u8,
    start: usize,
    options: SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    if (scanAliasTokenEnd(source, start, options)) |end| return end;

    const leading = parseLeadingBladeSign(source, start);
    const operand_start = leading.operand_start;
    if (scanAliasTokenEnd(source, operand_start, options)) |end| return end;
    if (operand_start >= source.len or source[operand_start] != options.basis_prefix) return error.MissingBasisPrefix;
    if (operand_start + 1 >= source.len) return error.EmptySignedBlade;

    var position = operand_start + 1;
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
    dimensions: usize,
    options: ?SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladeSpec {
    const opts = options orelse runtimeDefaultOptions(dimensions);
    return parseSignedBladeImpl(name, dimensions, opts);
}

/// Parses a signed blade starting at `start` inside a larger source string and
/// returns both the canonical spec and the first byte past the consumed token.
pub fn parseSignedBladePrefix(
    comptime source: []const u8,
    comptime start: usize,
    comptime dimensions: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) SignedBladePrefixParseResult else SignedBladeParseError!SignedBladePrefixParseResult {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimensions);

    if (panicking) {
        const end = comptime scanSignedBladeTokenEnd(source, start, opts) catch |err| invalidSignedBladeCompileError(source[start..], dimensions, err);
        const token = source[start..end];
        return .{
            .spec = comptime parseSignedBladeImpl(token, dimensions, opts) catch |err| invalidSignedBladeCompileError(token, dimensions, err),
            .end = end,
        };
    }

    const end = comptime scanSignedBladeTokenEnd(source, start, opts) catch |err| return err;
    const token = source[start..end];
    return .{
        .spec = try parseSignedBladeImpl(token, dimensions, opts),
        .end = end,
    };
}

/// Runtime-capable counterpart to `parseSignedBladePrefix`.
pub fn parseSignedBladePrefixRuntime(
    source: []const u8,
    start: usize,
    dimensions: usize,
    options: ?SignedBladeNamingOptions,
) SignedBladeParseError!SignedBladePrefixParseResult {
    const opts = options orelse runtimeDefaultOptions(dimensions);
    const end = try scanSignedBladeTokenEnd(source, start, opts);
    const token = source[start..end];
    return .{
        .spec = try parseSignedBladeImpl(token, dimensions, opts),
        .end = end,
    };
}

/// Resolves one named basis index under naming options.
/// If `panicking` is true, invalid indices will trigger a compile error instead of returning an error union.
pub fn resolveNamedBasisIndex(
    comptime named_index: usize,
    comptime dimensions: usize,
    comptime options: ?SignedBladeNamingOptions,
    comptime panicking: bool,
) if (panicking) usize else SignedBladeParseError!usize {
    const opts = comptime options orelse SignedBladeNamingOptions.euclidean(dimensions);
    if (panicking) {
        return comptime opts.resolveNamedBasisIndexComptime(named_index, dimensions) catch |err| invalidBasisIndexCompileError(named_index, dimensions, err);
    } else {
        return opts.resolveNamedBasisIndexComptime(named_index, dimensions);
    }
}

/// Runtime-capable counterpart to `resolveNamedBasisIndex`.
pub fn resolveNamedBasisIndexRuntime(
    named_index: usize,
    dimensions: usize,
    options: ?SignedBladeNamingOptions,
) SignedBladeParseError!usize {
    const opts = options orelse runtimeDefaultOptions(dimensions);
    return opts.resolveNamedBasisIndexRuntime(named_index, dimensions);
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

test "signed blades accept leading sign sequences" {
    const negative = try parseSignedBlade("-e13", 3, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b101) }, negative);

    const double_negative = try parseSignedBlade("--e13", 3, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b101) }, double_negative);

    const mixed_signs = try parseSignedBlade("+-e13", 3, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b101) }, mixed_signs);

    try std.testing.expect(isSignedBlade("-e13", 3, null));
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

    const signed = try parseSignedBladePrefix("-e13+rest", 0, 3, null, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b101) }, signed.spec);
    try std.testing.expectEqual(@as(usize, 4), signed.end);
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

test "blade aliases map custom names to signed blade specs" {
    const options = comptime b: {
        var opts = SignedBladeNamingOptions.euclidean(2);
        opts.blade_aliases = &.{
            .{ .name = "i", .spec = .{ .sign = .positive, .mask = .init(0b11) } },
            .{ .name = "I", .spec = .{ .sign = .positive, .mask = .init(0b11) } },
        };
        break :b opts;
    };

    const i_spec = try parseSignedBlade("i", 2, options, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b11) }, i_spec);

    const neg_i_spec = try parseSignedBlade("-i", 2, options, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .negative, .mask = .init(0b11) }, neg_i_spec);

    const double_neg_i_spec = try parseSignedBlade("--i", 2, options, false);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b11) }, double_neg_i_spec);

    try std.testing.expect(isSignedBlade("i", 2, options));
    try std.testing.expect(isSignedBlade("I", 2, options));
    try std.testing.expect(isSignedBlade("-i", 2, options));
    try std.testing.expect(!isSignedBlade("j", 2, options));
    try std.testing.expect(isSignedBlade("e12", 2, options));
}

test "basis names alias indexed-looking names when spans would map elsewhere" {
    const options = comptime SignedBladeNamingOptions.withBasisNames(
        .init(.{ .positive = .range(1, 2) }),
        .{ "e0", "e1" },
    );

    const e0 = try parseSignedBlade("e0", 2, options, false);
    const e1 = try parseSignedBlade("e1", 2, options, false);

    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b01) }, e0);
    try std.testing.expectEqual(SignedBladeSpec{ .sign = .positive, .mask = .init(0b10) }, e1);
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

const std = @import("std");
const blades = @import("blades.zig");
const blade_parsing = @import("blade_parsing.zig");
const multivector = @import("multivector.zig");
const parse = @import("../parse.zig");
const node_storage = parse.node_storage;
const pratt = parse.pratt;

pub const BladeMask = blades.BladeMask;

fn tupleFieldName(comptime index: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{index});
}

fn compileErrorAt(comptime source: []const u8, comptime position: usize, comptime message: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint(
        "invalid expression `{s}` at byte {d}: {s}",
        .{ source, position, message },
    ));
}

fn ensureNumericCoefficient(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => {},
        else => @compileError("expression coefficient type must be numeric"),
    }
}

fn coerceScalar(comptime T: type, value: anytype) T {
    ensureNumericCoefficient(T);
    return switch (@typeInfo(T)) {
        .float, .comptime_float => @as(T, @floatCast(value)),
        .int, .comptime_int => @as(T, @intCast(value)),
        else => unreachable,
    };
}

// NOTE: `Scalar.init(.{v}).cast(Full)` compiles down to the same code as
// `Full.zero()` + raw `coeffs[0] = v` — LLVM eliminates the intermediate
// struct and cast loop entirely.
fn scalarConstant(comptime T: type, comptime sig: blades.MetricSignature, value: T) multivector.FullMultivector(T, sig) {
    return multivector.Scalar(T, sig).init(.{value}).cast(multivector.FullMultivector(T, sig));
}

fn exactResultCast(
    comptime Result: type,
    comptime T: type,
    comptime sig: blades.MetricSignature,
    value: multivector.FullMultivector(T, sig),
) multivector.ExactCastError!Result {
    multivector.ensureMultivector(Result);

    if (comptime Result.Coefficient != T) {
        @compileError("expression result type must use the same coefficient type as the expression namespace");
    }
    if (comptime Result.metric_signature.p != sig.p or Result.metric_signature.q != sig.q or Result.metric_signature.r != sig.r) {
        @compileError("expression result type must live in the same algebra as the expression namespace");
    }

    return value.castExactOrError(Result);
}

fn isNumericType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

fn ensureSupportedArgs(comptime Args: type) void {
    const info = @typeInfo(Args);
    if (info != .@"struct") {
        @compileError("expression placeholders expect tuple or struct arguments");
    }
}

fn ensureArgsCompatible(comptime Args: type, comptime placeholder_names: []const []const u8) void {
    ensureSupportedArgs(Args);
    const info = @typeInfo(Args).@"struct";

    if (info.is_tuple) {
        if (info.fields.len != placeholder_names.len) {
            @compileError(std.fmt.comptimePrint(
                "expression expects {d} placeholder argument(s) but tuple has {d}",
                .{ placeholder_names.len, info.fields.len },
            ));
        }
        return;
    }

    inline for (placeholder_names) |name| {
        if (name.len == 0) {
            @compileError("unnamed `{}` placeholders require tuple arguments");
        }
        if (!@hasField(Args, name)) {
            @compileError(std.fmt.comptimePrint(
                "expression placeholder `{{{s}}}` is missing from argument struct type `{s}`",
                .{ name, @typeName(Args) },
            ));
        }
    }
}

fn placeholderArg(
    comptime placeholder_names: []const []const u8,
    comptime slot: usize,
    args: anytype,
) @TypeOf(if (@typeInfo(@TypeOf(args)).@"struct".is_tuple)
    @field(args, tupleFieldName(slot))
else
    @field(args, placeholder_names[slot])) {
    const Args = @TypeOf(args);
    ensureArgsCompatible(Args, placeholder_names);

    return if (@typeInfo(Args).@"struct".is_tuple)
        @field(args, tupleFieldName(slot))
    else
        @field(args, placeholder_names[slot]);
}

fn hasRuntimePlaceholderField(comptime Args: type, name: []const u8) bool {
    inline for (@typeInfo(Args).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn ensureArgsCompatibleRuntime(comptime Args: type, placeholder_names: []const []const u8) RuntimeEvalError!void {
    ensureSupportedArgs(Args);
    const info = @typeInfo(Args).@"struct";

    if (info.is_tuple) {
        if (info.fields.len != placeholder_names.len) return error.PlaceholderCountMismatch;
        return;
    }

    for (placeholder_names) |name| {
        if (name.len == 0) return error.UnnamedPlaceholderRequiresTuple;
        if (!hasRuntimePlaceholderField(Args, name)) return error.MissingPlaceholderArgument;
    }
}

fn promoteArg(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    value: anytype,
) multivector.FullMultivector(T, sig) {
    const Full = multivector.FullMultivector(T, sig);
    const Value = @TypeOf(value);

    if (comptime multivector.isMultivectorType(Value)) {
        if (comptime Value.Coefficient != T) {
            @compileError("expression arguments must use the same coefficient type as the expression namespace");
        }
        if (comptime Value.metric_signature.p != sig.p or Value.metric_signature.q != sig.q or Value.metric_signature.r != sig.r) {
            @compileError("expression arguments must live in the same algebra as the expression namespace");
        }
        return value.cast(Full);
    }

    if (comptime !isNumericType(Value)) {
        @compileError("expression placeholders accept only numeric scalars or multivectors");
    }

    return scalarConstant(T, sig, coerceScalar(T, value));
}

fn placeholderArgRuntimeToFull(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    placeholder_names: []const []const u8,
    slot: usize,
    args: anytype,
) RuntimeEvalError!multivector.FullMultivector(T, sig) {
    const Args = @TypeOf(args);
    try ensureArgsCompatibleRuntime(Args, placeholder_names);

    const info = @typeInfo(Args).@"struct";
    if (info.is_tuple) {
        inline for (info.fields, 0..) |field, index| {
            if (index == slot) return promoteArg(T, sig, @field(args, field.name));
        }
        return error.PlaceholderCountMismatch;
    }

    const name = placeholder_names[slot];
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return promoteArg(T, sig, @field(args, field.name));
        }
    }
    return error.MissingPlaceholderArgument;
}

fn slotValueRuntimeToFull(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    slot_values: []const multivector.FullMultivector(T, sig),
    slot: usize,
) RuntimeEvalError!multivector.FullMultivector(T, sig) {
    if (slot >= slot_values.len) return error.PlaceholderCountMismatch;
    return slot_values[slot];
}

fn parseScalarLiteral(comptime T: type, comptime token: []const u8) T {
    ensureNumericCoefficient(T);
    return switch (@typeInfo(T)) {
        .float, .comptime_float => std.fmt.parseFloat(T, token) catch @compileError(std.fmt.comptimePrint(
            "invalid numeric literal `{s}` in expression",
            .{token},
        )),
        .int, .comptime_int => std.fmt.parseInt(T, token, 10) catch @compileError(std.fmt.comptimePrint(
            "invalid integer literal `{s}` in expression",
            .{token},
        )),
        else => unreachable,
    };
}

pub const RuntimeCompileError = blade_parsing.SignedBladeParseError || error{
    UnexpectedToken,
    UnsupportedExponent,
    UnterminatedPlaceholder,
    MissingClosingParen,
    UnexpectedTrailingInput,
    InverseRequiresConstant,
    UndefinedInverse,
    InvalidNumericLiteral,
};

pub const RuntimeEvalError = error{
    PlaceholderCountMismatch,
    UnnamedPlaceholderRequiresTuple,
    MissingPlaceholderArgument,
};

fn parseScalarLiteralRuntime(comptime T: type, token: []const u8) RuntimeCompileError!T {
    ensureNumericCoefficient(T);
    return switch (@typeInfo(T)) {
        .float, .comptime_float => std.fmt.parseFloat(T, token) catch error.InvalidNumericLiteral,
        .int, .comptime_int => std.fmt.parseInt(T, token, 10) catch error.InvalidNumericLiteral,
        else => unreachable,
    };
}

fn ConstantValue(comptime T: type, comptime sig: blades.MetricSignature) type {
    ensureNumericCoefficient(T);
    const Full = multivector.FullMultivector(T, sig);

    return union(enum) {
        const Self = @This();

        scalar: T,
        blade: struct {
            coeff: T,
            mask: blades.BladeMask,
        },
        dense: Full,

        fn coeffFromSign(sign: blade_parsing.OrientationSign) T {
            return switch (@typeInfo(T)) {
                .float, .comptime_float => @as(T, @floatFromInt(@intFromEnum(sign))),
                .int, .comptime_int => @as(T, @intCast(@intFromEnum(sign))),
                else => unreachable,
            };
        }

        pub fn fromBladeSpec(spec: blade_parsing.SignedBladeSpec) Self {
            if (spec.mask.bitset.mask == 0) {
                return .{ .scalar = coeffFromSign(spec.sign) };
            }
            return .{
                .blade = .{
                    .coeff = coeffFromSign(spec.sign),
                    .mask = spec.mask,
                },
            };
        }

        pub fn fromFull(full: Full) Self {
            const coeffs = full.coeffsArray();

            var found_index: ?usize = null;
            for (coeffs, 0..) |coeff, index| {
                if (coeff == 0) continue;
                if (found_index != null) return .{ .dense = full };
                found_index = index;
            }

            const index = found_index orelse return .{ .scalar = 0 };
            const mask = Full.blades[index];
            const coeff = coeffs[index];

            if (mask.bitset.mask == 0) return .{ .scalar = coeff };
            return .{
                .blade = .{
                    .coeff = coeff,
                    .mask = mask,
                },
            };
        }

        pub fn toFull(self: Self) Full {
            switch (self) {
                .scalar => |value| return scalarConstant(T, sig, value),
                .blade => |blade| {
                    var coeffs = std.mem.zeroes([Full.stored_blade_count]T);
                    coeffs[blade.mask.index()] = blade.coeff;
                    return Full.init(coeffs);
                },
                .dense => |value| return value,
            }
        }

        pub fn isZero(self: Self) bool {
            return switch (self) {
                .scalar => |value| value == 0,
                .blade => |blade| blade.coeff == 0,
                .dense => blk: {
                    const coeffs = self.dense.coeffsArray();
                    for (coeffs) |coeff| {
                        if (coeff != 0) break :blk false;
                    }
                    break :blk true;
                },
            };
        }

        pub fn asScalar(self: Self) ?T {
            return switch (self) {
                .scalar => |value| value,
                .blade => null,
                .dense => |value| blk: {
                    const coeffs = value.coeffsArray();
                    var scalar: T = 0;
                    for (Full.blades, 0..) |mask, index| {
                        if (mask.bitset.mask == 0) {
                            scalar = coeffs[index];
                        } else if (coeffs[index] != 0) {
                            break :blk null;
                        }
                    }
                    break :blk scalar;
                },
            };
        }

        pub fn negate(self: Self) Self {
            return switch (self) {
                .scalar => |value| .{ .scalar = -value },
                .blade => |blade| .{
                    .blade = .{
                        .coeff = -blade.coeff,
                        .mask = blade.mask,
                    },
                },
                .dense => |value| Self.fromFull(value.negate()),
            };
        }

        pub fn scale(self: Self, scalar: T) Self {
            if (scalar == 0) return .{ .scalar = 0 };
            if (scalar == 1) return self;

            return switch (self) {
                .scalar => |value| .{ .scalar = value * scalar },
                .blade => |blade| .{
                    .blade = .{
                        .coeff = blade.coeff * scalar,
                        .mask = blade.mask,
                    },
                },
                .dense => |value| Self.fromFull(value.scale(scalar)),
            };
        }

        pub fn add(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().add(rhs.toFull()));
        }

        pub fn gp(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().gp(rhs.toFull()));
        }

        pub fn wedge(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().wedge(rhs.toFull()).cast(Full));
        }

        pub fn join(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().join(rhs.toFull()).cast(Full));
        }

        pub fn dot(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().dot(rhs.toFull()).cast(Full));
        }

        pub fn leftContraction(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().leftContraction(rhs.toFull()).cast(Full));
        }

        pub fn rightContraction(self: Self, rhs: Self) Self {
            return Self.fromFull(self.toFull().rightContraction(rhs.toFull()).cast(Full));
        }

        pub fn inverse(self: Self) ?Self {
            const inverse_value = self.toFull().inverse() orelse return null;
            return Self.fromFull(inverse_value.cast(Full));
        }
    };
}

fn ParserTypes(comptime T: type, comptime sig: blades.MetricSignature) type {
    const Const = ConstantValue(T, sig);

    return struct {
        pub const Token = union(enum) {
            eof: void,
            plus: void,
            minus: void,
            star: void,
            wedge: void,
            join: void,
            dot: void,
            left_contraction: void,
            right_contraction: void,
            lparen: void,
            rparen: void,
            slash: void,
            inverse: void,
            number: []const u8,
            blade: blade_parsing.SignedBladeSpec,
            placeholder: []const u8,
        };
        pub const TokenTag = std.meta.Tag(Token);

        pub const Binary = struct {
            lhs: usize,
            rhs: usize,
        };

        pub const Scale = struct {
            scalar: T,
            child: usize,
        };

        pub const Node = union(enum) {
            constant: Const,
            placeholder: usize,
            negate: usize,
            scale: Scale,
            add: Binary,
            gp: Binary,
            wedge: Binary,
            join: Binary,
            dot: Binary,
            left_contraction: Binary,
            right_contraction: Binary,
        };

        pub const NodeInfo = struct {
            constant: ?Const = null,
            scalar: ?T = null,
            is_zero: bool = false,
        };
    };
}

fn parserErrorMessage(err: RuntimeCompileError) []const u8 {
    return switch (err) {
        error.UnexpectedToken => "unexpected token",
        error.UnsupportedExponent => "only postfix `^-1` is supported after `^`",
        error.UnterminatedPlaceholder => "unterminated placeholder",
        error.MissingClosingParen => "missing closing `)`",
        error.UnexpectedTrailingInput => "unexpected trailing input",
        error.InverseRequiresConstant => "postfix `^-1` currently requires a fully constant operand",
        error.UndefinedInverse => "expression inverse is undefined for this value",
        error.InvalidNumericLiteral => "invalid numeric literal",
        inline else => @errorName(err),
    };
}

fn parserInfoForConstant(comptime T: type, comptime sig: blades.MetricSignature, value: ConstantValue(T, sig)) ParserTypes(T, sig).NodeInfo {
    return .{
        .constant = value,
        .scalar = value.asScalar(),
        .is_zero = value.isZero(),
    };
}

fn parserConstantNode(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    value: ConstantValue(T, sig),
) @TypeOf(self.*).ParserError!usize {
    return self.newNode(.{ .constant = value }, parserInfoForConstant(T, sig, value));
}

fn parserConstantScalar(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    value: T,
) @TypeOf(self.*).ParserError!usize {
    return parserConstantNode(T, sig, self, .{ .scalar = value });
}

fn parserBuildNegate(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    child: usize,
) @TypeOf(self.*).ParserError!usize {
    if (self.nodeInfo(child).constant) |constant| {
        return parserConstantNode(T, sig, self, constant.negate());
    }

    return switch (self.nodeAt(child)) {
        .negate => |inner| inner,
        .scale => |scale| self.newNode(.{
            .scale = .{
                .scalar = -scale.scalar,
                .child = scale.child,
            },
        }, .{}),
        else => self.newNode(.{ .negate = child }, .{}),
    };
}

fn parserBuildScale(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    child: usize,
    scalar: T,
) @TypeOf(self.*).ParserError!usize {
    const Node = ParserTypes(T, sig).Node;
    _ = Node;

    if (scalar == 0) return parserConstantScalar(T, sig, self, 0);
    if (scalar == 1) return child;

    if (self.nodeInfo(child).constant) |constant| {
        return parserConstantNode(T, sig, self, constant.scale(scalar));
    }

    return switch (self.nodeAt(child)) {
        .scale => |scale| parserBuildScale(T, sig, self, scale.child, scale.scalar * scalar),
        else => self.newNode(.{
            .scale = .{
                .scalar = scalar,
                .child = child,
            },
        }, .{}),
    };
}

fn parserBuildAdd(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.is_zero) return rhs;
    if (rhs_info.is_zero) return lhs;

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.add(rhs_constant));
        }
    }

    return self.newNode(.{ .add = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildSub(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    return parserBuildAdd(T, sig, self, lhs, try parserBuildNegate(T, sig, self, rhs));
}

fn parserBuildGp(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.gp(rhs_constant));
        }
        if (lhs_info.scalar) |scalar| {
            return parserBuildScale(T, sig, self, rhs, scalar);
        }
    }

    if (rhs_info.scalar) |scalar| {
        return parserBuildScale(T, sig, self, lhs, scalar);
    }

    return self.newNode(.{ .gp = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildWedge(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.wedge(rhs_constant));
        }
    }

    return self.newNode(.{ .wedge = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildJoin(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.join(rhs_constant));
        }
    }

    return self.newNode(.{ .join = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildDot(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.dot(rhs_constant));
        }
    }

    return self.newNode(.{ .dot = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildLeftContraction(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.leftContraction(rhs_constant));
        }
    }

    return self.newNode(.{ .left_contraction = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildRightContraction(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    lhs: usize,
    rhs: usize,
) @TypeOf(self.*).ParserError!usize {
    const lhs_info = self.nodeInfo(lhs);
    const rhs_info = self.nodeInfo(rhs);

    if (lhs_info.constant) |lhs_constant| {
        if (rhs_info.constant) |rhs_constant| {
            return parserConstantNode(T, sig, self, lhs_constant.rightContraction(rhs_constant));
        }
    }

    return self.newNode(.{ .right_contraction = .{ .lhs = lhs, .rhs = rhs } }, .{});
}

fn parserBuildInverse(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    child: usize,
) @TypeOf(self.*).ParserError!usize {
    const constant = self.nodeInfo(child).constant orelse return error.InverseRequiresConstant;
    const inverse = constant.inverse() orelse return error.UndefinedInverse;
    return parserConstantNode(T, sig, self, inverse);
}

fn parserSkipWhitespace(self: anytype) void {
    while (self.position < self.source.len and std.ascii.isWhitespace(self.source[self.position])) {
        self.position += 1;
    }
}

fn parserIsBladePrefixStart(self: anytype, char: u8) bool {
    if (char == self.naming_options.basis_prefix) return true;
    for (self.naming_options.blade_aliases) |alias| {
        if (alias.name.len > 0 and alias.name[0] == char) return true;
    }
    return false;
}

fn parserLexNumber(comptime T: type, comptime sig: blades.MetricSignature, self: anytype) ParserTypes(T, sig).Token {
    const start = self.position;
    var saw_dot = false;
    if (self.source[self.position] == '.') saw_dot = true;
    self.position += 1;
    while (self.position < self.source.len) : (self.position += 1) {
        const char = self.source[self.position];
        if (std.ascii.isDigit(char)) continue;
        if (char == '.') {
            if (saw_dot) break;
            saw_dot = true;
            continue;
        }
        break;
    }
    return .{ .number = self.source[start..self.position] };
}

fn parserLexBlade(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!ParserTypes(T, sig).Token {
    const parsed = try blade_parsing.parseSignedBladePrefixRuntime(
        self.source,
        self.position,
        sig.dimensions(),
        self.naming_options,
    );
    self.position = parsed.end;
    return .{ .blade = parsed.spec };
}

fn parserLexPlaceholder(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!ParserTypes(T, sig).Token {
    const start = self.position;
    self.position += 1;
    const name_start = self.position;

    while (self.position < self.source.len and self.source[self.position] != '}') {
        self.position += 1;
    }
    if (self.position >= self.source.len) {
        self.current_start = start;
        return error.UnterminatedPlaceholder;
    }

    const name = std.mem.trim(u8, self.source[name_start..self.position], &std.ascii.whitespace);
    self.position += 1;
    return .{ .placeholder = name };
}

fn parserLexLatexOperator(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!ParserTypes(T, sig).Token {
    const start = self.position;
    self.position += 1; // skip \
    const name_start = self.position;

    while (self.position < self.source.len and std.ascii.isAlphabetic(self.source[self.position])) {
        self.position += 1;
    }

    const name = self.source[name_start..self.position];
    if (std.mem.eql(u8, name, "wedge")) return .{ .wedge = {} };
    if (std.mem.eql(u8, name, "vee")) return .{ .join = {} };
    if (std.mem.eql(u8, name, "cdot")) return .{ .dot = {} };
    if (std.mem.eql(u8, name, "rfloor")) return .{ .left_contraction = {} };
    if (std.mem.eql(u8, name, "lfloor")) return .{ .right_contraction = {} };

    self.position = start;
    return error.UnexpectedToken;
}

fn parserLexUnicodeOperator(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!ParserTypes(T, sig).Token {
    const Types = ParserTypes(T, sig);
    const Mapping = struct {
        symbol: []const u8,
        token: Types.Token,
    };

    const mappings = [_]Mapping{
        .{ .symbol = "\u{2227}", .token = .{ .wedge = {} } }, // ∧
        .{ .symbol = "\u{2228}", .token = .{ .join = {} } }, // ∨
        .{ .symbol = "\u{22C5}", .token = .{ .dot = {} } }, // ⋅
        .{ .symbol = "\u{00B7}", .token = .{ .dot = {} } }, // ·
        .{ .symbol = "\u{230B}", .token = .{ .left_contraction = {} } }, // ⌋
        .{ .symbol = "\u{230A}", .token = .{ .right_contraction = {} } }, // ⌊
    };

    const rest = self.source[self.position..];
    inline for (mappings) |m| {
        if (std.mem.startsWith(u8, rest, m.symbol)) {
            self.position += m.symbol.len;
            return m.token;
        }
    }

    return error.UnexpectedToken;
}

fn parserNextToken(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!ParserTypes(T, sig).Token {
    parserSkipWhitespace(self);
    self.current_start = self.position;

    if (self.position >= self.source.len) {
        return .{ .eof = {} };
    }

    const char = self.source[self.position];
    return switch (char) {
        '+' => blk: {
            self.position += 1;
            break :blk .{ .plus = {} };
        },
        '-' => blk: {
            self.position += 1;
            break :blk .{ .minus = {} };
        },
        '*' => blk: {
            self.position += 1;
            break :blk .{ .star = {} };
        },
        '/' => blk: {
            self.position += 1;
            break :blk .{ .slash = {} };
        },
        '^' => blk: {
            if (std.mem.startsWith(u8, self.source[self.position..], "^-1")) {
                self.position += 3;
                break :blk .{ .inverse = {} };
            }
            self.position += 1;
            break :blk .{ .wedge = {} };
        },
        '&' => blk: {
            self.position += 1;
            break :blk .{ .join = {} };
        },
        '.' => blk: {
            const next_pos = self.position + 1;
            if (next_pos < self.source.len and std.ascii.isDigit(self.source[next_pos])) {
                break :blk parserLexNumber(T, sig, self);
            }
            self.position += 1;
            break :blk .{ .dot = {} };
        },
        '<' => blk: {
            if (std.mem.startsWith(u8, self.source[self.position..], "<<")) {
                self.position += 2;
                break :blk .{ .left_contraction = {} };
            }
            return error.UnexpectedToken;
        },
        '>' => blk: {
            if (std.mem.startsWith(u8, self.source[self.position..], ">>")) {
                self.position += 2;
                break :blk .{ .right_contraction = {} };
            }
            return error.UnexpectedToken;
        },
        '(' => blk: {
            self.position += 1;
            break :blk .{ .lparen = {} };
        },
        ')' => blk: {
            self.position += 1;
            break :blk .{ .rparen = {} };
        },
        '{' => parserLexPlaceholder(T, sig, self),
        '\\' => parserLexLatexOperator(T, sig, self),
        else => blk: {
            if (char & 0x80 != 0) {
                break :blk parserLexUnicodeOperator(T, sig, self);
            }
            if (std.ascii.isDigit(char)) {
                break :blk parserLexNumber(T, sig, self);
            }
            if (parserIsBladePrefixStart(self, char)) {
                break :blk try parserLexBlade(T, sig, self);
            }
            return error.UnexpectedToken;
        },
    };
}

fn parserAdvance(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!void {
    self.current = try parserNextToken(T, sig, self);
}

fn parserResolvePlaceholder(self: anytype, name: []const u8) @TypeOf(self.*).ParserError!usize {
    if (name.len != 0) {
        for (self.placeholderNames(), 0..) |existing, index| {
            if (std.mem.eql(u8, existing, name)) return index;
        }
    }
    return self.appendPlaceholder(name);
}

fn parserParsePrefix(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!usize {
    const token = self.current;
    const token_start = self.current_start;
    try parserAdvance(T, sig, self);

    return switch (token) {
        .number => |literal| parserConstantScalar(T, sig, self, try parseScalarLiteralRuntime(T, literal)),
        .blade => |spec| parserConstantNode(T, sig, self, ConstantValue(T, sig).fromBladeSpec(spec)),
        .placeholder => |name| self.newNode(.{ .placeholder = try parserResolvePlaceholder(self, name) }, .{}),
        .lparen => blk: {
            const inner = try parserParseExpression(T, sig, self, 0);
            switch (self.current) {
                .rparen => try parserAdvance(T, sig, self),
                else => {
                    self.current_start = token_start;
                    return error.MissingClosingParen;
                },
            }
            break :blk inner;
        },
        .plus => parserParseExpression(T, sig, self, 7),
        .minus => parserBuildNegate(T, sig, self, try parserParseExpression(T, sig, self, 7)),
        else => {
            self.current_start = token_start;
            return error.UnexpectedToken;
        },
    };
}

const InfixOperatorKind = enum {
    inverse,
    implicit_gp,
    gp,
    divide,
    wedge,
    dot,
    left_contraction,
    right_contraction,
    join,
    add,
    sub,
};

fn infixOperatorBindingPower(kind: InfixOperatorKind) pratt.BindingPower {
    return switch (kind) {
        .inverse => pratt.postfix(9),
        .implicit_gp => pratt.leftAssoc(7),
        .gp, .divide, .wedge, .dot, .left_contraction, .right_contraction => pratt.leftAssoc(5),
        .join => pratt.leftAssoc(4),
        .add, .sub => pratt.leftAssoc(3),
    };
}

fn infixOperatorNodeCost(kind: InfixOperatorKind) usize {
    return switch (kind) {
        .divide, .sub => 2,
        .inverse,
        .implicit_gp,
        .gp,
        .wedge,
        .dot,
        .left_contraction,
        .right_contraction,
        .join,
        .add,
        => 1,
    };
}

fn infixOperator(tag: anytype, kind: InfixOperatorKind) pratt.Operator(@TypeOf(tag)) {
    return .{
        .tag = tag,
        .binding_power = infixOperatorBindingPower(kind),
    };
}

fn infixOperatorKindForTag(tag: anytype) ?InfixOperatorKind {
    return switch (tag) {
        .inverse => .inverse,
        .number, .blade, .placeholder, .lparen => .implicit_gp,
        .star => .gp,
        .slash => .divide,
        .wedge => .wedge,
        .dot => .dot,
        .left_contraction => .left_contraction,
        .right_contraction => .right_contraction,
        .join => .join,
        .plus => .add,
        .minus => .sub,
        else => null,
    };
}

fn ParserPrattContext(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime Parser: type,
) type {
    return struct {
        const Self = @This();
        pub const NodeIndex = usize;
        pub const ParseError = Parser.ParserError;
        const TokenTag = ParserTypes(T, sig).TokenTag;
        pub const operator_table = pratt.initTable(TokenTag, .{
            .inverse = infixOperatorBindingPower(.inverse),
            .number = infixOperatorBindingPower(.implicit_gp),
            .blade = infixOperatorBindingPower(.implicit_gp),
            .placeholder = infixOperatorBindingPower(.implicit_gp),
            .lparen = infixOperatorBindingPower(.implicit_gp),
            .star = infixOperatorBindingPower(.gp),
            .slash = infixOperatorBindingPower(.divide),
            .wedge = infixOperatorBindingPower(.wedge),
            .dot = infixOperatorBindingPower(.dot),
            .left_contraction = infixOperatorBindingPower(.left_contraction),
            .right_contraction = infixOperatorBindingPower(.right_contraction),
            .join = infixOperatorBindingPower(.join),
            .plus = infixOperatorBindingPower(.add),
            .minus = infixOperatorBindingPower(.sub),
            .eof = null,
            .rparen = null,
        });

        comptime {
            pratt.validate(@This());
        }

        parser: *Parser,

        pub fn parsePrefix(self: *Self) ParseError!NodeIndex {
            return parserParsePrefix(T, sig, self.parser);
        }

        pub fn currentTokenTag(self: Self) TokenTag {
            return std.meta.activeTag(self.parser.current);
        }

        pub fn parseInfix(self: *Self, lhs: NodeIndex, bp: pratt.BindingPower) ParseError!NodeIndex {
            const current_token = self.parser.current;
            const token_tag = std.meta.activeTag(current_token);
            const operator_kind = infixOperatorKindForTag(token_tag) orelse return error.UnexpectedToken;

            return switch (operator_kind) {
                .implicit_gp => blk: {
                    const rhs = try pratt.parseExpression(Self, self, bp.right);
                    break :blk parserBuildGp(T, sig, self.parser, lhs, rhs);
                },
                .inverse => blk: {
                    try parserAdvance(T, sig, self.parser);
                    break :blk parserBuildInverse(T, sig, self.parser, lhs);
                },
                .gp, .divide, .wedge, .dot, .left_contraction, .right_contraction, .join, .add, .sub => blk: {
                    try parserAdvance(T, sig, self.parser);
                    const rhs = try pratt.parseExpression(Self, self, bp.right);
                    break :blk switch (operator_kind) {
                        .gp => parserBuildGp(T, sig, self.parser, lhs, rhs),
                        .divide => parserBuildGp(T, sig, self.parser, lhs, try parserBuildInverse(T, sig, self.parser, rhs)),
                        .wedge => parserBuildWedge(T, sig, self.parser, lhs, rhs),
                        .dot => parserBuildDot(T, sig, self.parser, lhs, rhs),
                        .left_contraction => parserBuildLeftContraction(T, sig, self.parser, lhs, rhs),
                        .right_contraction => parserBuildRightContraction(T, sig, self.parser, lhs, rhs),
                        .join => parserBuildJoin(T, sig, self.parser, lhs, rhs),
                        .add => parserBuildAdd(T, sig, self.parser, lhs, rhs),
                        .sub => parserBuildSub(T, sig, self.parser, lhs, rhs),
                        else => unreachable,
                    };
                },
            };
        }
    };
}

fn parserParseExpression(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    min_bp: u8,
) @TypeOf(self.*).ParserError!usize {
    const Context = ParserPrattContext(T, sig, @TypeOf(self.*));
    var context = Context{ .parser = self };
    return pratt.parseExpression(Context, &context, min_bp);
}

const CompilerStorageCaps = struct {
    max_nodes: usize,
    max_placeholders: usize,
};

fn tokenTagStartsImplicitGp(tag: anytype) bool {
    return infixOperatorKindForTag(tag) == .implicit_gp;
}

fn tokenStartsImplicitGp(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    token: ParserTypes(T, sig).Token,
) bool {
    return tokenTagStartsImplicitGp(std.meta.activeTag(token));
}

fn compilerStorageCaps(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
) CompilerStorageCaps {
    const Lexer = struct {
        pub const ParserError = RuntimeCompileError;

        source: []const u8,
        position: usize = 0,
        current_start: usize = 0,
        naming_options: blade_parsing.SignedBladeNamingOptions,
    };

    const placeholder_token_count = comptime blk: {
        var lexer = Lexer{
            .source = source,
            .naming_options = naming_options,
        };
        var count: usize = 0;

        while (true) {
            const token = parserNextToken(T, sig, &lexer) catch |err| {
                compileErrorAt(source, lexer.current_start, parserErrorMessage(err));
            };
            switch (token) {
                .eof => break,
                .placeholder => count += 1,
                else => {},
            }
        }

        break :blk count;
    };

    var unique_placeholder_names: [placeholder_token_count][]const u8 = undefined;
    var unique_placeholder_count: usize = 0;
    var operand_node_count: usize = 0;
    var operator_node_count: usize = 0;
    var expecting_prefix = true;

    var lexer = Lexer{
        .source = source,
        .naming_options = naming_options,
    };

    while (true) {
        const token = parserNextToken(T, sig, &lexer) catch |err| {
            compileErrorAt(source, lexer.current_start, parserErrorMessage(err));
        };
        switch (token) {
            .eof => break,
            else => {},
        }

        if (!expecting_prefix and tokenStartsImplicitGp(T, sig, token)) {
            operator_node_count += infixOperatorNodeCost(.implicit_gp);
            expecting_prefix = true;
        }

        if (expecting_prefix) {
            switch (token) {
                .number, .blade => {
                    operand_node_count += 1;
                    expecting_prefix = false;
                },
                .placeholder => |name| {
                    operand_node_count += 1;
                    if (name.len == 0) {
                        unique_placeholder_count += 1;
                    } else {
                        var found = false;
                        for (unique_placeholder_names[0..unique_placeholder_count]) |existing| {
                            if (std.mem.eql(u8, existing, name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            unique_placeholder_names[unique_placeholder_count] = name;
                            unique_placeholder_count += 1;
                        }
                    }
                    expecting_prefix = false;
                },
                .lparen, .plus => {},
                .minus => operator_node_count += 1,
                else => {},
            }
            continue;
        }

        switch (token) {
            .inverse => operator_node_count += infixOperatorNodeCost(.inverse),
            .star, .slash, .wedge, .join, .dot, .left_contraction, .right_contraction, .plus, .minus => {
                operator_node_count += infixOperatorNodeCost(infixOperatorKindForTag(std.meta.activeTag(token)).?);
                expecting_prefix = true;
            },
            .rparen => {},
            else => {},
        }
    }

    return .{
        .max_nodes = @max(operand_node_count + operator_node_count, 1),
        .max_placeholders = unique_placeholder_count,
    };
}

fn parserCompile(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
) @TypeOf(self.*).ParserError!@TypeOf(self.*).Compiled {
    try parserAdvance(T, sig, self);
    const root = try parserParseExpression(T, sig, self, 0);

    switch (self.current) {
        .eof => {},
        else => return error.UnexpectedTrailingInput,
    }

    return self.finish(root);
}

fn FixedCompilerStorage(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime max_nodes: usize,
    comptime max_placeholders: usize,
) type {
    const Types = ParserTypes(T, sig);
    return node_storage.Fixed(Types.Node, Types.NodeInfo, max_nodes, max_placeholders);
}

fn DynamicCompilerStorage(
    comptime T: type,
    comptime sig: blades.MetricSignature,
) type {
    const Types = ParserTypes(T, sig);
    return node_storage.Dynamic(Types.Node, Types.NodeInfo);
}

fn ensureCompilerStorage(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime Storage: type,
) void {
    const Types = ParserTypes(T, sig);
    const owner = std.fmt.comptimePrint(
        "compiler storage `{s}`",
        .{@typeName(Storage)},
    );
    node_storage.ensureStorage(
        Storage,
        Types.Node,
        Types.NodeInfo,
        owner,
    );
}

fn Compiler(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime Storage: type,
) type {
    ensureCompilerStorage(T, sig, Storage);
    const Types = ParserTypes(T, sig);
    const Token = Types.Token;
    const Node = Types.Node;
    const NodeInfo = Types.NodeInfo;

    return struct {
        const Self = @This();
        pub const ParserError = Storage.StorageError || RuntimeCompileError;
        pub const Compiled = Storage.Compiled;

        source: []const u8,
        naming_options: blade_parsing.SignedBladeNamingOptions,
        current: Token = .{ .eof = {} },
        current_start: usize = 0,
        position: usize = 0,
        storage: Storage,

        fn init(
            source: []const u8,
            naming_options: blade_parsing.SignedBladeNamingOptions,
            storage: Storage,
        ) Self {
            return .{
                .source = source,
                .naming_options = naming_options,
                .storage = storage,
            };
        }

        fn deinit(self: *Self) void {
            self.storage.deinit();
        }

        fn newNode(self: *Self, node: Node, info: NodeInfo) ParserError!usize {
            return self.storage.newNode(node, info);
        }

        fn nodeInfo(self: Self, index: usize) NodeInfo {
            return self.storage.nodeInfo(index);
        }

        fn nodeAt(self: Self, index: usize) Node {
            return self.storage.nodeAt(index);
        }

        fn placeholderNames(self: Self) []const []const u8 {
            return self.storage.placeholderNames();
        }

        fn appendPlaceholder(self: *Self, name: []const u8) ParserError!usize {
            return self.storage.appendPlaceholder(name);
        }

        fn finish(self: *Self, root: usize) ParserError!Compiled {
            return self.storage.finish(root);
        }
    };
}

fn evalNode(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime placeholder_names: []const []const u8,
    comptime compiled: anytype,
    comptime index: usize,
    args: anytype,
) multivector.FullMultivector(T, sig) {
    const Full = multivector.FullMultivector(T, sig);
    return switch (compiled.nodes[index]) {
        .constant => |value| value.toFull(),
        .placeholder => |slot| promoteArg(T, sig, placeholderArg(placeholder_names, slot, args)),
        .negate => |child| evalNode(T, sig, placeholder_names, compiled, child, args).negate(),
        .scale => |scale| evalNode(T, sig, placeholder_names, compiled, scale.child, args).scale(scale.scalar),
        .add => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).add(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
        .gp => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).gp(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
        .wedge => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).wedge(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
        .join => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).join(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
        .dot => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).dot(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
        .left_contraction => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).leftContraction(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
        .right_contraction => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).rightContraction(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)).cast(Full),
    };
}

fn evalNodeRuntimeArgs(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    placeholder_names: []const []const u8,
    nodes: []const ParserTypes(T, sig).Node,
    index: usize,
    args: anytype,
) RuntimeEvalError!multivector.FullMultivector(T, sig) {
    const Full = multivector.FullMultivector(T, sig);
    return switch (nodes[index]) {
        .constant => |value| value.toFull(),
        .placeholder => |slot| placeholderArgRuntimeToFull(T, sig, placeholder_names, slot, args),
        .negate => |child| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, child, args)).negate(),
        .scale => |scale| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, scale.child, args)).scale(scale.scalar),
        .add => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).add(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
        .gp => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).gp(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
        .wedge => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).wedge(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
        .join => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).join(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
        .dot => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).dot(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
        .left_contraction => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).leftContraction(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
        .right_contraction => |binary| (try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.lhs, args)).rightContraction(try evalNodeRuntimeArgs(T, sig, placeholder_names, nodes, binary.rhs, args)).cast(Full),
    };
}

fn evalNodeRuntimeSlots(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    nodes: []const ParserTypes(T, sig).Node,
    index: usize,
    slot_values: []const multivector.FullMultivector(T, sig),
) RuntimeEvalError!multivector.FullMultivector(T, sig) {
    const Full = multivector.FullMultivector(T, sig);
    return switch (nodes[index]) {
        .constant => |value| value.toFull(),
        .placeholder => |slot| slotValueRuntimeToFull(T, sig, slot_values, slot),
        .negate => |child| (try evalNodeRuntimeSlots(T, sig, nodes, child, slot_values)).negate(),
        .scale => |scale| (try evalNodeRuntimeSlots(T, sig, nodes, scale.child, slot_values)).scale(scale.scalar),
        .add => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).add(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
        .gp => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).gp(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
        .wedge => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).wedge(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
        .join => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).join(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
        .dot => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).dot(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
        .left_contraction => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).leftContraction(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
        .right_contraction => |binary| (try evalNodeRuntimeSlots(T, sig, nodes, binary.lhs, slot_values)).rightContraction(try evalNodeRuntimeSlots(T, sig, nodes, binary.rhs, slot_values)).cast(Full),
    };
}

pub fn RuntimeCompiledExpression(comptime T: type, comptime sig: blades.MetricSignature) type {
    const Full = multivector.FullMultivector(T, sig);
    const Node = ParserTypes(T, sig).Node;

    return struct {
        pub const Self = @This();
        pub const Coefficient = T;
        pub const metric_signature = sig;

        allocator: std.mem.Allocator,
        source: []const u8,
        nodes: []const Node,
        root: usize,
        placeholders: []const []const u8,

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.nodes);
            self.allocator.free(self.placeholders);
            self.allocator.free(self.source);
            self.* = undefined;
        }

        pub fn eval(self: Self, args: anytype) RuntimeEvalError!Full {
            const Args = @TypeOf(args);
            try ensureArgsCompatibleRuntime(Args, self.placeholders);
            return evalNodeRuntimeArgs(T, sig, self.placeholders, self.nodes, self.root, args);
        }

        pub fn evalAs(
            self: Self,
            comptime Result: type,
            args: anytype,
        ) (RuntimeEvalError || multivector.ExactCastError)!Result {
            return try exactResultCast(Result, T, sig, try self.eval(args));
        }

        pub fn evalSlots(self: Self, slot_values: []const Full) RuntimeEvalError!Full {
            if (slot_values.len != self.placeholders.len) return error.PlaceholderCountMismatch;
            return evalNodeRuntimeSlots(T, sig, self.nodes, self.root, slot_values);
        }

        pub fn evalSlotsAs(
            self: Self,
            comptime Result: type,
            slot_values: []const Full,
        ) (RuntimeEvalError || multivector.ExactCastError)!Result {
            return try exactResultCast(Result, T, sig, try self.evalSlots(slot_values));
        }
    };
}

pub fn compileRuntime(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    naming_options: blade_parsing.SignedBladeNamingOptions,
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || RuntimeCompileError)!RuntimeCompiledExpression(T, sig) {
    const Runtime = RuntimeCompiledExpression(T, sig);
    const Storage = DynamicCompilerStorage(T, sig);
    const CompilerImpl = Compiler(T, sig, Storage);

    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);

    var compiler = CompilerImpl.init(owned_source, naming_options, Storage.init(allocator));
    defer compiler.deinit();

    const compiled = try parserCompile(T, sig, &compiler);
    return Runtime{
        .allocator = allocator,
        .source = owned_source,
        .nodes = compiled.nodes,
        .root = compiled.root,
        .placeholders = compiled.placeholder_names,
    };
}

pub fn evaluateRuntime(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    naming_options: blade_parsing.SignedBladeNamingOptions,
    allocator: std.mem.Allocator,
    source: []const u8,
    args: anytype,
) (std.mem.Allocator.Error || RuntimeCompileError || RuntimeEvalError)!multivector.FullMultivector(T, sig) {
    var compiled = try compileRuntime(T, sig, naming_options, allocator, source);
    defer compiled.deinit();
    return compiled.eval(args);
}

pub fn evaluateRuntimeAs(
    comptime Result: type,
    comptime T: type,
    comptime sig: blades.MetricSignature,
    naming_options: blade_parsing.SignedBladeNamingOptions,
    allocator: std.mem.Allocator,
    source: []const u8,
    args: anytype,
) (std.mem.Allocator.Error || RuntimeCompileError || RuntimeEvalError || multivector.ExactCastError)!Result {
    var compiled = try compileRuntime(T, sig, naming_options, allocator, source);
    defer compiled.deinit();
    return compiled.evalAs(Result, args);
}

pub fn CompiledExpression(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
) type {
    const Full = multivector.FullMultivector(T, sig);
    const caps = comptime compilerStorageCaps(T, sig, naming_options, source);
    const Storage = FixedCompilerStorage(
        T,
        sig,
        caps.max_nodes,
        caps.max_placeholders,
    );
    const CompilerImpl = Compiler(T, sig, Storage);
    const compiled = comptime blk: {
        @setEvalBranchQuota(2_000_000);

        var compiler = CompilerImpl.init(source, naming_options, .{});
        break :blk parserCompile(T, sig, &compiler) catch |err| switch (err) {
            error.ExpressionTooLarge => compileErrorAt(source, compiler.current_start, "expression is too large"),
            inline else => compileErrorAt(source, compiler.current_start, parserErrorMessage(err)),
        };
    };
    const placeholder_names = compiled.placeholder_names[0..compiled.placeholder_count];

    return struct {
        pub const Self = @This();
        pub const Coefficient = T;
        pub const metric_signature = sig;
        pub const expression_source = source;
        pub const placeholders = placeholder_names;
        pub const placeholder_count = placeholder_names.len;

        pub fn eval(_: Self, args: anytype) Full {
            const Args = @TypeOf(args);
            ensureArgsCompatible(Args, placeholder_names);
            return evalNode(T, sig, placeholder_names, compiled, compiled.root, args);
        }

        pub fn evalAs(self: Self, comptime Result: type, args: anytype) Result {
            return exactResultCast(Result, T, sig, self.eval(args)) catch @panic("expression result had non-zero coefficients outside the requested carrier");
        }
    };
}

/// Compiles a small multivector expression at comptime.
pub fn compile(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
) CompiledExpression(T, sig, naming_options, source) {
    return .{};
}

/// Parses a small multivector expression at comptime and evaluates the
/// remaining runtime residue against `args`.
///
/// Supported syntax:
/// - numeric literals such as `0`, `1`, `2`, `0.5`
/// - signed blades such as `e12`, `e(1,2)`, `e0`
/// - placeholders such as `{v}` or `{}`
/// - operators `+`, `-`, `*`, `^`, `&`, `.`, `<<`, `>>`, unary `+/-`, parentheses, and postfix `^-1`
/// - unicode operators `∧` (`^`), `∨` (`&`), `⋅`/`·` (`.`), `⌋` (`<<`), `⌊` (`>>`)
/// - latex-style operators `\wedge`, `\vee`, `\cdot`, `\rfloor`, `\lfloor`
///
/// Constant-only subexpressions are folded at comptime. Placeholder-bearing
/// subtrees are left as residual operations and specialized into the generated
/// code.
pub fn eval(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
    args: anytype,
) multivector.FullMultivector(T, sig) {
    return compile(T, sig, naming_options, source).eval(args);
}

/// Like `eval`, but casts the result to `Result` carrier type.
pub fn evalAs(
    comptime Result: type,
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
    args: anytype,
) Result {
    return compile(T, sig, naming_options, source).evalAs(Result, args);
}

test "expression supports GA operators" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const options = comptime blade_parsing.SignedBladeNamingOptions.euclidean(3);
    const Basis = multivector.Basis(f32, sig);
    const e1 = Basis.e(1);
    const e2 = Basis.e(2);

    // Wedge
    try std.testing.expect(eval(f32, sig, options, "e1 ^ e2", .{}).eql(Basis.signedBlade("e12")));
    try std.testing.expect(eval(f32, sig, options, "e1 ∧ e2", .{}).eql(Basis.signedBlade("e12")));
    try std.testing.expect(eval(f32, sig, options, "e1 \\wedge e2", .{}).eql(Basis.signedBlade("e12")));

    // Dot
    try std.testing.expect(eval(f32, sig, options, "e1 . e1", .{}).scalarCoeff() == 1.0);
    try std.testing.expect(eval(f32, sig, options, "e1 ⋅ e1", .{}).scalarCoeff() == 1.0);
    try std.testing.expect(eval(f32, sig, options, "e1 · e1", .{}).scalarCoeff() == 1.0);
    try std.testing.expect(eval(f32, sig, options, "e1 \\cdot e1", .{}).scalarCoeff() == 1.0);

    // Contractions
    try std.testing.expect(eval(f32, sig, options, "e1 << e12", .{}).eql(e2));
    try std.testing.expect(eval(f32, sig, options, "e1 ⌋ e12", .{}).eql(e2));
    try std.testing.expect(eval(f32, sig, options, "e1 \\rfloor e12", .{}).eql(e2));
    try std.testing.expect(eval(f32, sig, options, "e12 >> e2", .{}).eql(e1));
    try std.testing.expect(eval(f32, sig, options, "e12 ⌊ e2", .{}).eql(e1));
    try std.testing.expect(eval(f32, sig, options, "e12 \\lfloor e2", .{}).eql(e1));

    // Join
    try std.testing.expect(eval(f32, sig, options, "e12 & e23", .{}).eql(Basis.e(2).negate()));
    try std.testing.expect(eval(f32, sig, options, "e12 ∨ e23", .{}).eql(Basis.e(2).negate()));
    try std.testing.expect(eval(f32, sig, options, "e12 \\vee e23", .{}).eql(Basis.e(2).negate()));
}

test "expression folds constant blade arithmetic" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const value = eval(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "2*e12 + e21", .{});

    try std.testing.expectEqual(@as(f32, 1), value.coeffNamed("e12"));
    try std.testing.expectEqual(@as(f32, 0), value.coeffNamed("e13"));
}

test "compiled expression supports named struct placeholders" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const Basis = multivector.Basis(f32, sig);
    const runtime = Basis.e(1).add(Basis.e(2));
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "2*e12 + 3*{v}");
    const value = expr.eval(.{ .v = runtime });

    try std.testing.expectEqual(@as(usize, 1), @TypeOf(expr).placeholder_count);
    try std.testing.expectEqualStrings("v", @TypeOf(expr).placeholders[0]);
    try std.testing.expectEqual(@as(f32, 2), value.coeffNamed("e12"));
    try std.testing.expectEqual(@as(f32, 3), value.coeffNamed("e1"));
    try std.testing.expectEqual(@as(f32, 3), value.coeffNamed("e2"));
}

test "compiled expression keeps tuple placeholders positional" {
    const sig = comptime blades.MetricSignature.euclidean(2);
    const Basis = multivector.Basis(f32, sig);
    const runtime = Basis.e(1);
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(2), "{} + {}");
    const value = expr.eval(.{ runtime, runtime });

    try std.testing.expectEqual(@as(f32, 2), value.coeffNamed("e1"));
}

test "expression reuses placeholder names" {
    const sig = comptime blades.MetricSignature.euclidean(2);
    const Basis = multivector.Basis(f32, sig);
    const runtime = Basis.e(1);
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(2), "{v} + {v}");
    const value = expr.eval(.{ .v = runtime });

    try std.testing.expectEqual(@as(usize, 1), @TypeOf(expr).placeholder_count);
    try std.testing.expectEqual(@as(f32, 2), value.coeffNamed("e1"));
}

test "expression supports postfix inverse on comptime values" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const value = eval(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "(2*e1)^-1", .{});

    try std.testing.expectEqual(@as(f32, 0.5), value.coeffNamed("e1"));
}

test "compiled expression can narrow to an exact carrier type" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const Basis = multivector.Basis(f32, sig);
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "2*e1 + 3*{v}");
    const value = expr.evalAs(Basis.Vector, .{ .v = Basis.e(2) });

    try std.testing.expect(value.eql(Basis.Vector.init(.{ 2, 3, 0 })));
}

test "runtime compiled expression supports named and slot evaluation" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const options = blade_parsing.SignedBladeNamingOptions.euclidean(3);
    const Basis = multivector.Basis(f32, sig);
    const Full = multivector.FullMultivector(f32, sig);

    var named = try compileRuntime(f32, sig, options, std.testing.allocator, "2*e12 + 3*{v}");
    defer named.deinit();

    const runtime = Basis.e(1).add(Basis.e(2));
    const named_value = try named.eval(.{ .v = runtime });
    try std.testing.expectEqualStrings("v", named.placeholders[0]);
    try std.testing.expectEqual(@as(f32, 2), named_value.coeffNamed("e12"));
    try std.testing.expectEqual(@as(f32, 3), named_value.coeffNamed("e1"));
    try std.testing.expectEqual(@as(f32, 3), named_value.coeffNamed("e2"));

    var tuple = try compileRuntime(f32, sig, options, std.testing.allocator, "{} + {}");
    defer tuple.deinit();

    const slot_values = [_]Full{
        scalarConstant(f32, sig, 1),
        scalarConstant(f32, sig, 2),
    };
    const tuple_value = try tuple.evalSlots(&slot_values);
    try std.testing.expectEqual(@as(f32, 3), tuple_value.scalarCoeff());
}

test "runtime compiled expression can narrow to an exact carrier type" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const options = blade_parsing.SignedBladeNamingOptions.euclidean(3);
    const Basis = multivector.Basis(f32, sig);

    var expr = try compileRuntime(f32, sig, options, std.testing.allocator, "2*e1 + 3*{v}");
    defer expr.deinit();

    const value = try expr.evalAs(Basis.Vector, .{ .v = Basis.e(2) });
    try std.testing.expect(value.eql(Basis.Vector.init(.{ 2, 3, 0 })));
}

test "expression supports division operator" {
    const sig = comptime blades.MetricSignature.euclidean(2);
    const naming = comptime b: {
        var opts = blade_parsing.SignedBladeNamingOptions.fromSignature(sig);
        opts.blade_aliases = &.{.{
            .name = "i",
            .spec = .{ .sign = .positive, .mask = .init(0b11) },
        }};
        break :b opts;
    };

    // scalar / scalar
    try std.testing.expectEqual(@as(f32, 2.5), eval(f32, sig, naming, "5 / 2", .{}).scalarCoeff());

    // scalar / blade
    const inv_i = eval(f32, sig, naming, "1 / i", .{});
    try std.testing.expectEqual(@as(f32, -1), inv_i.coeff(.init(0b11)));

    // complex-style division
    const result = eval(f32, sig, naming, "(3 + 4i) / (2i)", .{});
    try std.testing.expectApproxEqAbs(@as(f32, 2), result.scalarCoeff(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), result.coeff(.init(0b11)), 1e-6);
}

test "expression supports implicit multiplication" {
    const sig = comptime blades.MetricSignature.euclidean(2);
    const naming = comptime b: {
        var opts = blade_parsing.SignedBladeNamingOptions.fromSignature(sig);
        opts.blade_aliases = &.{.{
            .name = "i",
            .spec = .{ .sign = .positive, .mask = .init(0b11) },
        }};
        break :b opts;
    };

    // number blade: 5i = 5 * i
    try std.testing.expectEqual(@as(f32, 5), eval(f32, sig, naming, "5i", .{}).coeff(.init(0b11)));

    // number basis: 3e1 = 3 * e1
    try std.testing.expectEqual(@as(f32, 3), eval(f32, sig, naming, "3e1", .{}).coeffNamed("e1"));

    // blade lparen: i(1 + i) = i + i² = -1 + i
    const bi = eval(f32, sig, naming, "i(1 + i)", .{});
    try std.testing.expectEqual(@as(f32, -1), bi.scalarCoeff());
    try std.testing.expectEqual(@as(f32, 1), bi.coeff(.init(0b11)));

    // rparen lparen: (2)(3) = 6
    try std.testing.expectEqual(@as(f32, 6), eval(f32, sig, naming, "(2)(3)", .{}).scalarCoeff());

    // implicit multiply binds tighter than explicit *
    // 2i * 3e1 vs 2 i*3 e1 — both produce the same since * and implicit
    // are both left-to-right geometric products
    try std.testing.expect(eval(f32, sig, naming, "2i * 3e1", .{}).eql(
        eval(f32, sig, naming, "2*i*3*e1", .{}),
    ));

    // implicit multiply binds tighter than /,
    // so `1/2i` parses as `1 / (2i)` regardless of whitespace
    const half_inv_i = eval(f32, sig, naming, "1/2i", .{});
    const half_inv_i_spaced = eval(f32, sig, naming, "1/2 i", .{});
    try std.testing.expectApproxEqAbs(@as(f32, 0), half_inv_i.scalarCoeff(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), half_inv_i.coeff(.init(0b11)), 1e-6);
    try std.testing.expect(half_inv_i.eql(half_inv_i_spaced));
}

test "compiler storage caps derive from expression grammar" {
    const sig = comptime blades.MetricSignature.euclidean(2);
    const naming = comptime b: {
        var opts = blade_parsing.SignedBladeNamingOptions.fromSignature(sig);
        opts.blade_aliases = &.{.{
            .name = "i",
            .spec = .{ .sign = .positive, .mask = .init(0b11) },
        }};
        break :b opts;
    };

    const inverse_caps = comptime compilerStorageCaps(f32, sig, naming, "1/2 i");
    try std.testing.expectEqual(@as(usize, 6), inverse_caps.max_nodes);
    try std.testing.expectEqual(@as(usize, 0), inverse_caps.max_placeholders);

    const placeholder_caps = comptime compilerStorageCaps(f32, sig, naming, "{a}+{a}+{}");
    try std.testing.expectEqual(@as(usize, 5), placeholder_caps.max_nodes);
    try std.testing.expectEqual(@as(usize, 2), placeholder_caps.max_placeholders);

    const Storage = FixedCompilerStorage(f32, sig, placeholder_caps.max_nodes, placeholder_caps.max_placeholders);
    const CompilerImpl = Compiler(f32, sig, Storage);
    const compiled = comptime blk: {
        var compiler = CompilerImpl.init("{a}+{a}+{}", naming, .{});
        break :blk parserCompile(f32, sig, &compiler) catch |err| switch (err) {
            error.ExpressionTooLarge => compileErrorAt("{a}+{a}+{}", compiler.current_start, "expression is too large"),
            inline else => compileErrorAt("{a}+{a}+{}", compiler.current_start, parserErrorMessage(err)),
        };
    };
    try std.testing.expectEqual(@as(usize, 2), compiled.placeholder_count);
}

test "AST shape of simple expressions" {
    const sig = comptime blades.MetricSignature.euclidean(2);
    const naming = comptime b: {
        var opts = blade_parsing.SignedBladeNamingOptions.fromSignature(sig);
        opts.blade_aliases = &.{.{
            .name = "i",
            .spec = .{ .sign = .positive, .mask = .init(0b11) },
        }};
        break :b opts;
    };

    const Node = ParserTypes(f32, sig).Node;
    const Const = ConstantValue(f32, sig);
    const compileAst = struct {
        fn f(comptime source: []const u8) struct { nodes: []const Node, root: usize, placeholders: []const []const u8 } {
            const caps = comptime compilerStorageCaps(f32, sig, naming, source);
            const Storage = FixedCompilerStorage(f32, sig, caps.max_nodes, caps.max_placeholders);
            const CompilerImpl = Compiler(f32, sig, Storage);
            const compiled = comptime blk: {
                var compiler = CompilerImpl.init(source, naming, .{});
                break :blk parserCompile(f32, sig, &compiler) catch |err| switch (err) {
                    error.ExpressionTooLarge => compileErrorAt(source, compiler.current_start, "expression is too large"),
                    inline else => compileErrorAt(source, compiler.current_start, parserErrorMessage(err)),
                };
            };
            return .{
                .nodes = &compiled.nodes,
                .root = compiled.root,
                .placeholders = compiled.placeholder_names[0..compiled.placeholder_count],
            };
        }
    }.f;

    const ExpectedAst = struct {
        const Tree = union(enum) {
            const Self = @This();

            constant: Const,
            placeholder: usize,
            negate: *const Self,
            scale: struct {
                scalar: f32,
                child: *const Self,
            },
            add: Binary,
            gp: Binary,
            wedge: Binary,
            join: Binary,
            dot: Binary,
            left_contraction: Binary,
            right_contraction: Binary,

            const Binary = struct {
                lhs: *const Self,
                rhs: *const Self,
            };
        };

        root: *const Tree,
        placeholders: []const []const u8,
    };

    const TreeArena = struct {
        const Self = @This();

        nodes: [128]ExpectedAst.Tree = undefined,
        len: usize = 0,

        fn push(self: *Self, node: ExpectedAst.Tree) *const ExpectedAst.Tree {
            const index = self.len;
            self.nodes[index] = node;
            self.len += 1;
            return &self.nodes[index];
        }

        fn constant(self: *Self, value: Const) *const ExpectedAst.Tree {
            return self.push(.{ .constant = value });
        }

        fn placeholder(self: *Self, slot: usize) *const ExpectedAst.Tree {
            return self.push(.{ .placeholder = slot });
        }

        fn negate(self: *Self, child: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .negate = child });
        }

        fn scale(self: *Self, scalar: f32, child: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .scale = .{
                .scalar = scalar,
                .child = child,
            } });
        }

        fn add(self: *Self, lhs: *const ExpectedAst.Tree, rhs: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .add = .{ .lhs = lhs, .rhs = rhs } });
        }

        fn gp(self: *Self, lhs: *const ExpectedAst.Tree, rhs: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .gp = .{ .lhs = lhs, .rhs = rhs } });
        }

        fn wedge(self: *Self, lhs: *const ExpectedAst.Tree, rhs: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .wedge = .{ .lhs = lhs, .rhs = rhs } });
        }

        fn dot(self: *Self, lhs: *const ExpectedAst.Tree, rhs: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .dot = .{ .lhs = lhs, .rhs = rhs } });
        }

        fn leftContraction(self: *Self, lhs: *const ExpectedAst.Tree, rhs: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .left_contraction = .{ .lhs = lhs, .rhs = rhs } });
        }

        fn rightContraction(self: *Self, lhs: *const ExpectedAst.Tree, rhs: *const ExpectedAst.Tree) *const ExpectedAst.Tree {
            return self.push(.{ .right_contraction = .{ .lhs = lhs, .rhs = rhs } });
        }

        fn fromFlat(self: *Self, nodes: []const Node, index: usize) *const ExpectedAst.Tree {
            return switch (nodes[index]) {
                .constant => |value| self.constant(value),
                .placeholder => |slot| self.placeholder(slot),
                .negate => |child| self.negate(self.fromFlat(nodes, child)),
                .scale => |scale_node| self.scale(scale_node.scalar, self.fromFlat(nodes, scale_node.child)),
                .add => |binary| self.add(self.fromFlat(nodes, binary.lhs), self.fromFlat(nodes, binary.rhs)),
                .gp => |binary| self.gp(self.fromFlat(nodes, binary.lhs), self.fromFlat(nodes, binary.rhs)),
                .wedge => |binary| self.wedge(self.fromFlat(nodes, binary.lhs), self.fromFlat(nodes, binary.rhs)),
                .join => |binary| self.push(.{ .join = .{
                    .lhs = self.fromFlat(nodes, binary.lhs),
                    .rhs = self.fromFlat(nodes, binary.rhs),
                } }),
                .dot => |binary| self.dot(self.fromFlat(nodes, binary.lhs), self.fromFlat(nodes, binary.rhs)),
                .left_contraction => |binary| self.leftContraction(self.fromFlat(nodes, binary.lhs), self.fromFlat(nodes, binary.rhs)),
                .right_contraction => |binary| self.rightContraction(self.fromFlat(nodes, binary.lhs), self.fromFlat(nodes, binary.rhs)),
            };
        }

        fn actual(self: *Self, comptime source: []const u8) ExpectedAst {
            const ast = compileAst(source);
            return .{
                .root = self.fromFlat(ast.nodes, ast.root),
                .placeholders = ast.placeholders,
            };
        }

        fn expected(
            self: *Self,
            placeholders: []const []const u8,
            root: *const ExpectedAst.Tree,
        ) ExpectedAst {
            _ = self;
            return .{
                .root = root,
                .placeholders = placeholders,
            };
        }
    };

    const expectAst = struct {
        fn f(comptime source: []const u8, buildExpected: fn (*TreeArena) ExpectedAst) !void {
            var actual_arena: TreeArena = .{};
            const actual = actual_arena.actual(source);

            var expected_arena: TreeArena = .{};
            const expected = buildExpected(&expected_arena);

            try std.testing.expectEqualDeep(expected, actual);
        }
    }.f;

    try expectAst("42", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{}, arena.constant(.{ .scalar = 42 }));
        }
    }.build);

    try expectAst("e1", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{}, arena.constant(.{
                .blade = .{
                    .coeff = 1,
                    .mask = BladeMask.init(0b01),
                },
            }));
        }
    }.build);

    try expectAst("2 + 3", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{}, arena.constant(.{ .scalar = 5 }));
        }
    }.build);

    try expectAst("{x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.placeholder(0));
        }
    }.build);

    try expectAst("{x} + {y}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y" }, arena.add(arena.placeholder(0), arena.placeholder(1)));
        }
    }.build);

    try expectAst("{x} * {y}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y" }, arena.gp(arena.placeholder(0), arena.placeholder(1)));
        }
    }.build);

    try expectAst("3 * {x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.scale(3, arena.placeholder(0)));
        }
    }.build);

    try expectAst("-{x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.negate(arena.placeholder(0)));
        }
    }.build);

    try expectAst("{x} ^ {y}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y" }, arena.wedge(arena.placeholder(0), arena.placeholder(1)));
        }
    }.build);

    try expectAst("{x} . {y}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y" }, arena.dot(arena.placeholder(0), arena.placeholder(1)));
        }
    }.build);

    try expectAst("{x} << {y}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y" }, arena.leftContraction(arena.placeholder(0), arena.placeholder(1)));
        }
    }.build);

    try expectAst("{x} >> {y}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y" }, arena.rightContraction(arena.placeholder(0), arena.placeholder(1)));
        }
    }.build);

    try expectAst("2{x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.scale(2, arena.placeholder(0)));
        }
    }.build);

    try expectAst("{x} / (2e1)", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.gp(
                arena.placeholder(0),
                arena.constant(.{
                    .blade = .{
                        .coeff = 0.5,
                        .mask = BladeMask.init(0b01),
                    },
                }),
            ));
        }
    }.build);

    try expectAst("{x} + {y} * {z}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y", "z" }, arena.add(
                arena.placeholder(0),
                arena.gp(arena.placeholder(1), arena.placeholder(2)),
            ));
        }
    }.build);

    try expectAst("{x}{y} * {z}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{ "x", "y", "z" }, arena.gp(
                arena.gp(arena.placeholder(0), arena.placeholder(1)),
                arena.placeholder(2),
            ));
        }
    }.build);

    try expectAst("--{x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.placeholder(0));
        }
    }.build);

    try expectAst("2 * (3 * {x})", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.scale(6, arena.placeholder(0)));
        }
    }.build);

    try expectAst("0 * {x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.constant(.{ .scalar = 0 }));
        }
    }.build);

    try expectAst("0 + {x}", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{"x"}, arena.placeholder(0));
        }
    }.build);

    try expectAst("-5", struct {
        fn build(arena: *TreeArena) ExpectedAst {
            return arena.expected(&.{}, arena.constant(.{ .scalar = -5 }));
        }
    }.build);
}

test "runtime exact typed evaluation rejects non-zero omitted coefficients" {
    const sig = comptime blades.MetricSignature.euclidean(3);
    const options = blade_parsing.SignedBladeNamingOptions.euclidean(3);
    const Basis = multivector.Basis(f32, sig);

    var expr = try compileRuntime(f32, sig, options, std.testing.allocator, "e1 + e12");
    defer expr.deinit();

    try std.testing.expectError(
        multivector.ExactCastError.ExcludedCoefficientNonZero,
        expr.evalAs(Basis.Vector, .{}),
    );
}

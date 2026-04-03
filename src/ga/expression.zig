const std = @import("std");
const blades = @import("blades.zig");
const blade_parsing = @import("blade_parsing.zig");
const multivector = @import("multivector.zig");
const meta = @import("../meta.zig");

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
            inverse: void,
            number: []const u8,
            blade: blade_parsing.SignedBladeSpec,
            placeholder: []const u8,
        };

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
    return char == self.naming_options.basis_prefix;
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
        sig.dimension(),
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

fn parserParseExpression(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    self: anytype,
    min_bp: u8,
) @TypeOf(self.*).ParserError!usize {
    var lhs = try parserParsePrefix(T, sig, self);

    while (true) {
        const current_token = self.current;
        switch (current_token) {
            .inverse => {
                const left_bp: u8 = 9;
                if (left_bp < min_bp) break;
                try parserAdvance(T, sig, self);
                lhs = try parserBuildInverse(T, sig, self, lhs);
            },
            .star, .wedge, .dot, .left_contraction, .right_contraction => |tag| {
                _ = tag;
                const left_bp: u8 = 5;
                const right_bp: u8 = 6;
                if (left_bp < min_bp) break;
                try parserAdvance(T, sig, self);
                const rhs = try parserParseExpression(T, sig, self, right_bp);
                lhs = switch (current_token) {
                    .star => try parserBuildGp(T, sig, self, lhs, rhs),
                    .wedge => try parserBuildWedge(T, sig, self, lhs, rhs),
                    .dot => try parserBuildDot(T, sig, self, lhs, rhs),
                    .left_contraction => try parserBuildLeftContraction(T, sig, self, lhs, rhs),
                    .right_contraction => try parserBuildRightContraction(T, sig, self, lhs, rhs),
                    else => unreachable,
                };
            },
            .join => {
                const left_bp: u8 = 4;
                const right_bp: u8 = 5;
                if (left_bp < min_bp) break;
                try parserAdvance(T, sig, self);
                const rhs = try parserParseExpression(T, sig, self, right_bp);
                lhs = try parserBuildJoin(T, sig, self, lhs, rhs);
            },
            .plus => {
                const left_bp: u8 = 3;
                const right_bp: u8 = 4;
                if (left_bp < min_bp) break;
                try parserAdvance(T, sig, self);
                const rhs = try parserParseExpression(T, sig, self, right_bp);
                lhs = try parserBuildAdd(T, sig, self, lhs, rhs);
            },
            .minus => {
                const left_bp: u8 = 3;
                const right_bp: u8 = 4;
                if (left_bp < min_bp) break;
                try parserAdvance(T, sig, self);
                const rhs = try parserParseExpression(T, sig, self, right_bp);
                lhs = try parserBuildSub(T, sig, self, lhs, rhs);
            },
            else => break,
        }
    }

    return lhs;
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
    const Node = Types.Node;
    const NodeInfo = Types.NodeInfo;

    return struct {
        const Self = @This();
        pub const StorageError = error{ExpressionTooLarge};

        pub const Compiled = struct {
            nodes: [max_nodes]Node,
            node_count: usize,
            root: usize,
            placeholder_names: [max_placeholders][]const u8,
            placeholder_count: usize,
        };

        nodes: [max_nodes]Node = undefined,
        infos: [max_nodes]NodeInfo = undefined,
        node_count: usize = 0,
        placeholder_names: [max_placeholders][]const u8 = undefined,
        placeholder_count: usize = 0,

        fn deinit(_: *Self) void {}

        fn newNode(self: *Self, node: Node, info: NodeInfo) StorageError!usize {
            if (self.node_count >= max_nodes) return error.ExpressionTooLarge;
            const index = self.node_count;
            self.nodes[index] = node;
            self.infos[index] = info;
            self.node_count += 1;
            return index;
        }

        fn nodeInfo(self: Self, index: usize) NodeInfo {
            return self.infos[index];
        }

        fn nodeAt(self: Self, index: usize) Node {
            return self.nodes[index];
        }

        fn placeholderNames(self: Self) []const []const u8 {
            return self.placeholder_names[0..self.placeholder_count];
        }

        fn appendPlaceholder(self: *Self, name: []const u8) StorageError!usize {
            if (self.placeholder_count >= max_placeholders) return error.ExpressionTooLarge;
            const slot = self.placeholder_count;
            self.placeholder_names[slot] = name;
            self.placeholder_count += 1;
            return slot;
        }

        fn finish(self: *Self, root: usize) StorageError!Compiled {
            return .{
                .nodes = self.nodes,
                .node_count = self.node_count,
                .root = root,
                .placeholder_names = self.placeholder_names,
                .placeholder_count = self.placeholder_count,
            };
        }
    };
}

fn DynamicCompilerStorage(
    comptime T: type,
    comptime sig: blades.MetricSignature,
) type {
    const Types = ParserTypes(T, sig);
    const Node = Types.Node;
    const NodeInfo = Types.NodeInfo;

    return struct {
        const Self = @This();
        pub const StorageError = std.mem.Allocator.Error;

        pub const Compiled = struct {
            nodes: []const Node,
            root: usize,
            placeholder_names: []const []const u8,
        };

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        infos: std.ArrayList(NodeInfo) = .empty,
        placeholder_names: std.ArrayList([]const u8) = .empty,

        fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.infos.deinit(self.allocator);
            self.placeholder_names.deinit(self.allocator);
        }

        fn newNode(self: *Self, node: Node, info: NodeInfo) StorageError!usize {
            const index = self.nodes.items.len;
            try self.nodes.append(self.allocator, node);
            errdefer self.nodes.items.len -= 1;
            try self.infos.append(self.allocator, info);
            return index;
        }

        fn nodeInfo(self: Self, index: usize) NodeInfo {
            return self.infos.items[index];
        }

        fn nodeAt(self: Self, index: usize) Node {
            return self.nodes.items[index];
        }

        fn placeholderNames(self: Self) []const []const u8 {
            return self.placeholder_names.items;
        }

        fn appendPlaceholder(self: *Self, name: []const u8) StorageError!usize {
            const slot = self.placeholder_names.items.len;
            try self.placeholder_names.append(self.allocator, name);
            return slot;
        }

        fn finish(self: *Self, root: usize) StorageError!Compiled {
            const nodes = try self.nodes.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(nodes);

            const placeholder_names = try self.placeholder_names.toOwnedSlice(self.allocator);
            return .{
                .nodes = nodes,
                .root = root,
                .placeholder_names = placeholder_names,
            };
        }
    };
}

fn ensureCompilerStorage(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime Storage: type,
) void {
    const Types = ParserTypes(T, sig);
    const Node = Types.Node;
    const NodeInfo = Types.NodeInfo;
    const owner = std.fmt.comptimePrint(
        "compiler storage `{s}`",
        .{@typeName(Storage)},
    );
    const declaration_options: meta.DeclLookupOptions = .{
        .owner = owner,
    };
    const method_options: meta.DeclLookupOptions = .{
        .owner = owner,
        .decl_role = "method",
    };
    const lookup_decl_type = struct {
        fn get(comptime name: []const u8) ?type {
            if (!@hasDecl(Storage, name)) return null;

            const value = @field(Storage, name);
            return if (@TypeOf(value) == type) value else @TypeOf(value);
        }
    }.get;

    meta.requireLookupDecl(
        lookup_decl_type,
        "Compiled",
        declaration_options,
    );
    meta.requireLookupDeclSatisfies(
        lookup_decl_type,
        "StorageError",
        meta.isErrorSetType,
        "an error set",
        declaration_options,
    );

    meta.requireLookupDeclType(
        lookup_decl_type,
        "deinit",
        fn (*Storage) void,
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "newNode",
        &.{fn (*Storage, Node, NodeInfo) Storage.StorageError!usize},
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "nodeInfo",
        &.{
            fn (Storage, usize) NodeInfo,
            fn (*const Storage, usize) NodeInfo,
        },
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "nodeAt",
        &.{
            fn (Storage, usize) Node,
            fn (*const Storage, usize) Node,
        },
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "placeholderNames",
        &.{
            fn (Storage) []const []const u8,
            fn (*const Storage) []const []const u8,
        },
        method_options,
    );
    meta.requireLookupDeclType(
        lookup_decl_type,
        "appendPlaceholder",
        fn (*Storage, []const u8) Storage.StorageError!usize,
        method_options,
    );
    meta.requireLookupDeclType(
        lookup_decl_type,
        "finish",
        fn (*Storage, usize) Storage.StorageError!Storage.Compiled,
        method_options,
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
    const Storage = FixedCompilerStorage(
        T,
        sig,
        source.len * 4 + 8,
        if (source.len == 0) 1 else source.len,
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

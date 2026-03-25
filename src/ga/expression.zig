const std = @import("std");
const blades = @import("blades.zig");
const blade_parsing = @import("blade_parsing.zig");
const multivector = @import("multivector.zig");

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

fn scalarConstant(comptime T: type, comptime sig: blades.MetricSignature, value: T) multivector.FullMultivector(T, sig) {
    const Full = multivector.FullMultivector(T, sig);
    var result = Full.zero();
    result.coeffs[Full.blade_index_by_mask[0]] = value;
    return result;
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
            inline for (coeffs, 0..) |coeff, index| {
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
                    var result = Full.zero();
                    result.coeffs[blade.mask.index()] = blade.coeff;
                    return result;
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
                    inline for (coeffs) |coeff| {
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
                    inline for (Full.blades, 0..) |mask, index| {
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

        pub fn inverse(self: Self) ?Self {
            const inverse_value = self.toFull().inverse() orelse return null;
            return Self.fromFull(inverse_value.cast(Full));
        }
    };
}

fn Compiler(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
) type {
    const Const = ConstantValue(T, sig);
    const max_nodes = source.len * 4 + 8;
    const max_placeholders = if (source.len == 0) 1 else source.len;

    return struct {
        const Self = @This();

        const TokenTag = enum {
            eof,
            plus,
            minus,
            star,
            lparen,
            rparen,
            inverse,
            number,
            blade,
            placeholder,
        };

        const Token = union(TokenTag) {
            eof: void,
            plus: void,
            minus: void,
            star: void,
            lparen: void,
            rparen: void,
            inverse: void,
            number: []const u8,
            blade: blade_parsing.SignedBladeSpec,
            placeholder: []const u8,
        };

        const Binary = struct {
            lhs: usize,
            rhs: usize,
        };

        const Scale = struct {
            scalar: T,
            child: usize,
        };

        const Node = union(enum) {
            constant: Const,
            placeholder: usize,
            negate: usize,
            scale: Scale,
            add: Binary,
            gp: Binary,
        };

        const NodeInfo = struct {
            constant: ?Const = null,
            scalar: ?T = null,
            is_zero: bool = false,
        };

        const Compiled = struct {
            nodes: [max_nodes]Node,
            node_count: usize,
            root: usize,
            placeholder_names: [max_placeholders][]const u8,
            placeholder_count: usize,
        };

        current: Token = .{ .eof = {} },
        current_start: usize = 0,
        position: usize = 0,
        nodes: [max_nodes]Node = undefined,
        infos: [max_nodes]NodeInfo = undefined,
        node_count: usize = 0,
        placeholder_names: [max_placeholders][]const u8 = undefined,
        placeholder_count: usize = 0,

        fn fail(self: Self, comptime message: []const u8) noreturn {
            compileErrorAt(source, self.current_start, message);
        }

        fn infoForConstant(value: Const) NodeInfo {
            return .{
                .constant = value,
                .scalar = value.asScalar(),
                .is_zero = value.isZero(),
            };
        }

        fn newNode(self: *Self, node: Node, info: NodeInfo) usize {
            if (self.node_count >= max_nodes) {
                compileErrorAt(source, self.current_start, "expression is too large");
            }
            const index = self.node_count;
            self.nodes[index] = node;
            self.infos[index] = info;
            self.node_count += 1;
            return index;
        }

        fn constantNode(self: *Self, value: Const) usize {
            return self.newNode(.{ .constant = value }, infoForConstant(value));
        }

        fn constantScalar(self: *Self, value: T) usize {
            return self.constantNode(.{ .scalar = value });
        }

        fn nodeInfo(self: Self, index: usize) NodeInfo {
            return self.infos[index];
        }

        fn buildNegate(self: *Self, child: usize) usize {
            if (self.nodeInfo(child).constant) |constant| {
                return self.constantNode(constant.negate());
            }

            return switch (self.nodes[child]) {
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

        fn buildScale(self: *Self, child: usize, scalar: T) usize {
            if (scalar == 0) return self.constantScalar(0);
            if (scalar == 1) return child;

            if (self.nodeInfo(child).constant) |constant| {
                return self.constantNode(constant.scale(scalar));
            }

            return switch (self.nodes[child]) {
                .scale => |scale| self.buildScale(scale.child, scale.scalar * scalar),
                else => self.newNode(.{
                    .scale = .{
                        .scalar = scalar,
                        .child = child,
                    },
                }, .{}),
            };
        }

        fn buildAdd(self: *Self, lhs: usize, rhs: usize) usize {
            const lhs_info = self.nodeInfo(lhs);
            const rhs_info = self.nodeInfo(rhs);

            if (lhs_info.is_zero) return rhs;
            if (rhs_info.is_zero) return lhs;

            if (lhs_info.constant) |lhs_constant| {
                if (rhs_info.constant) |rhs_constant| {
                    return self.constantNode(lhs_constant.add(rhs_constant));
                }
            }

            return self.newNode(.{ .add = .{ .lhs = lhs, .rhs = rhs } }, .{});
        }

        fn buildSub(self: *Self, lhs: usize, rhs: usize) usize {
            return self.buildAdd(lhs, self.buildNegate(rhs));
        }

        fn buildGp(self: *Self, lhs: usize, rhs: usize) usize {
            const lhs_info = self.nodeInfo(lhs);
            const rhs_info = self.nodeInfo(rhs);

            if (lhs_info.constant) |lhs_constant| {
                if (rhs_info.constant) |rhs_constant| {
                    return self.constantNode(lhs_constant.gp(rhs_constant));
                }
                if (lhs_info.scalar) |scalar| {
                    return self.buildScale(rhs, scalar);
                }
            }

            if (rhs_info.scalar) |scalar| {
                return self.buildScale(lhs, scalar);
            }

            return self.newNode(.{ .gp = .{ .lhs = lhs, .rhs = rhs } }, .{});
        }

        fn buildInverse(self: *Self, child: usize) usize {
            const constant = self.nodeInfo(child).constant orelse compileErrorAt(
                source,
                self.current_start,
                "postfix `^-1` currently requires a fully comptime operand",
            );
            const inverse = constant.inverse() orelse compileErrorAt(
                source,
                self.current_start,
                "expression inverse is undefined for this value",
            );
            return self.constantNode(inverse);
        }

        fn skipWhitespace(self: *Self) void {
            while (self.position < source.len and std.ascii.isWhitespace(source[self.position])) {
                self.position += 1;
            }
        }

        fn isBladePrefixStart(char: u8) bool {
            return char == naming_options.basis_prefix;
        }

        fn lexNumber(self: *Self) Token {
            const start = self.position;
            var saw_dot = false;
            if (source[self.position] == '.') saw_dot = true;
            self.position += 1;
            while (self.position < source.len) : (self.position += 1) {
                const char = source[self.position];
                if (std.ascii.isDigit(char)) continue;
                if (char == '.') {
                    if (saw_dot) break;
                    saw_dot = true;
                    continue;
                }
                break;
            }
            return .{ .number = source[start..self.position] };
        }

        fn lexBlade(self: *Self) Token {
            const parsed = blade_parsing.parseSignedBladePrefix(source, self.position, sig.dimension(), naming_options, false) catch |err| {
                compileErrorAt(source, self.position, @errorName(err));
            };
            self.position = parsed.end;
            return .{ .blade = parsed.spec };
        }

        fn lexPlaceholder(self: *Self) Token {
            const start = self.position;
            self.position += 1;
            const name_start = self.position;

            while (self.position < source.len and source[self.position] != '}') {
                self.position += 1;
            }
            if (self.position >= source.len) {
                compileErrorAt(source, start, "unterminated placeholder");
            }

            const name = std.mem.trim(u8, source[name_start..self.position], &std.ascii.whitespace);
            self.position += 1;
            return .{ .placeholder = name };
        }

        fn nextToken(self: *Self) Token {
            self.skipWhitespace();
            self.current_start = self.position;

            if (self.position >= source.len) {
                return .{ .eof = {} };
            }

            return switch (source[self.position]) {
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
                '(' => blk: {
                    self.position += 1;
                    break :blk .{ .lparen = {} };
                },
                ')' => blk: {
                    self.position += 1;
                    break :blk .{ .rparen = {} };
                },
                '^' => blk: {
                    if (!std.mem.startsWith(u8, source[self.position..], "^-1")) {
                        compileErrorAt(source, self.position, "only postfix `^-1` is supported after `^`");
                    }
                    self.position += 3;
                    break :blk .{ .inverse = {} };
                },
                '{' => self.lexPlaceholder(),
                else => |char| blk: {
                    if (std.ascii.isDigit(char) or char == '.') {
                        break :blk self.lexNumber();
                    }
                    if (isBladePrefixStart(char)) {
                        break :blk self.lexBlade();
                    }
                    compileErrorAt(source, self.position, "unexpected token");
                },
            };
        }

        fn advance(self: *Self) void {
            self.current = self.nextToken();
        }

        fn resolvePlaceholder(self: *Self, comptime name: []const u8) usize {
            if (name.len == 0) {
                if (self.placeholder_count >= max_placeholders) {
                    compileErrorAt(source, self.current_start, "too many placeholders for this expression");
                }
                const slot = self.placeholder_count;
                self.placeholder_names[slot] = name;
                self.placeholder_count += 1;
                return slot;
            }

            var index: usize = 0;
            while (index < self.placeholder_count) : (index += 1) {
                if (std.mem.eql(u8, self.placeholder_names[index], name)) return index;
            }

            if (self.placeholder_count >= max_placeholders) {
                compileErrorAt(source, self.current_start, "too many placeholders for this expression");
            }

            const slot = self.placeholder_count;
            self.placeholder_names[slot] = name;
            self.placeholder_count += 1;
            return slot;
        }

        fn parsePrefix(self: *Self) usize {
            const token = self.current;
            const token_start = self.current_start;
            self.advance();

            return switch (token) {
                .number => |literal| self.constantScalar(parseScalarLiteral(T, literal)),
                .blade => |spec| self.constantNode(Const.fromBladeSpec(spec)),
                .placeholder => |name| self.newNode(.{ .placeholder = self.resolvePlaceholder(name) }, .{}),
                .lparen => blk: {
                    const inner = self.parseExpression(0);
                    switch (self.current) {
                        .rparen => self.advance(),
                        else => compileErrorAt(source, token_start, "missing closing `)`"),
                    }
                    break :blk inner;
                },
                .plus => self.parseExpression(7),
                .minus => self.buildNegate(self.parseExpression(7)),
                else => compileErrorAt(source, token_start, "expected an expression"),
            };
        }

        fn parseExpression(self: *Self, min_bp: u8) usize {
            var lhs = self.parsePrefix();

            while (true) {
                switch (self.current) {
                    .inverse => {
                        const left_bp: u8 = 9;
                        if (left_bp < min_bp) break;
                        self.advance();
                        lhs = self.buildInverse(lhs);
                    },
                    .star => {
                        const left_bp: u8 = 5;
                        const right_bp: u8 = 6;
                        if (left_bp < min_bp) break;
                        self.advance();
                        const rhs = self.parseExpression(right_bp);
                        lhs = self.buildGp(lhs, rhs);
                    },
                    .plus => {
                        const left_bp: u8 = 3;
                        const right_bp: u8 = 4;
                        if (left_bp < min_bp) break;
                        self.advance();
                        const rhs = self.parseExpression(right_bp);
                        lhs = self.buildAdd(lhs, rhs);
                    },
                    .minus => {
                        const left_bp: u8 = 3;
                        const right_bp: u8 = 4;
                        if (left_bp < min_bp) break;
                        self.advance();
                        const rhs = self.parseExpression(right_bp);
                        lhs = self.buildSub(lhs, rhs);
                    },
                    else => break,
                }
            }

            return lhs;
        }

        fn compile() Compiled {
            @setEvalBranchQuota(2_000_000);

            var self = Self{};
            self.advance();
            const root = self.parseExpression(0);

            switch (self.current) {
                .eof => {},
                else => self.fail("unexpected trailing input"),
            }

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

fn evalNode(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime placeholder_names: []const []const u8,
    compiled: anytype,
    comptime index: usize,
    args: anytype,
) multivector.FullMultivector(T, sig) {
    return switch (compiled.nodes[index]) {
        .constant => |value| value.toFull(),
        .placeholder => |slot| promoteArg(T, sig, placeholderArg(placeholder_names, slot, args)),
        .negate => |child| evalNode(T, sig, placeholder_names, compiled, child, args).negate(),
        .scale => |scale| evalNode(T, sig, placeholder_names, compiled, scale.child, args).scale(scale.scalar),
        .add => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).add(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)),
        .gp => |binary| evalNode(T, sig, placeholder_names, compiled, binary.lhs, args).gp(evalNode(T, sig, placeholder_names, compiled, binary.rhs, args)),
    };
}

pub fn CompiledExpression(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
) type {
    const Full = multivector.FullMultivector(T, sig);
    const compiled = comptime Compiler(T, sig, naming_options, source).compile();
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

        pub fn evaluate(self: Self, args: anytype) Full {
            return self.eval(args);
        }
    };
}

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
/// - operators `+`, `-`, `*`, unary `+/-`, parentheses, and postfix `^-1`
///
/// Constant-only subexpressions are folded at comptime. Placeholder-bearing
/// subtrees are left as residual operations and specialized into the generated
/// code.
pub fn evaluate(
    comptime T: type,
    comptime sig: blades.MetricSignature,
    comptime naming_options: blade_parsing.SignedBladeNamingOptions,
    comptime source: []const u8,
    args: anytype,
) multivector.FullMultivector(T, sig) {
    return compile(T, sig, naming_options, source).eval(args);
}

test "expression folds constant blade arithmetic" {
    const sig = blades.MetricSignature.euclidean(3);
    const value = evaluate(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "2*e12 + e21", .{});

    try std.testing.expectEqual(@as(f32, 1), value.coeffNamed("e12"));
    try std.testing.expectEqual(@as(f32, 0), value.coeffNamed("e13"));
}

test "compiled expression supports named struct placeholders" {
    const sig = blades.MetricSignature.euclidean(3);
    const Basis = multivector.Basis(f32, sig);
    const runtime = Basis.e(1).add(Basis.e(2));
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "2*e12 + 3*{v}");
    const value = expr.eval(.{ .v = runtime });

    try std.testing.expectEqual(@as(f32, 1), expr.placeholder_count);
    try std.testing.expectEqualStrings("v", expr.placeholders[0]);
    try std.testing.expectEqual(@as(f32, 2), value.coeffNamed("e12"));
    try std.testing.expectEqual(@as(f32, 3), value.coeffNamed("e1"));
    try std.testing.expectEqual(@as(f32, 3), value.coeffNamed("e2"));
}

test "compiled expression keeps tuple placeholders positional" {
    const sig = blades.MetricSignature.euclidean(2);
    const Basis = multivector.Basis(f32, sig);
    const runtime = Basis.e(1);
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(2), "{} + {}");
    const value = expr.eval(.{ runtime, runtime });

    try std.testing.expectEqual(@as(f32, 2), value.coeffNamed("e1"));
}

test "expression reuses placeholder names" {
    const sig = blades.MetricSignature.euclidean(2);
    const Basis = multivector.Basis(f32, sig);
    const runtime = Basis.e(1);
    const expr = compile(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(2), "{v} + {v}");
    const value = expr.eval(.{ .v = runtime });

    try std.testing.expectEqual(@as(f32, 1), expr.placeholder_count);
    try std.testing.expectEqual(@as(f32, 2), value.coeffNamed("e1"));
}

test "expression supports postfix inverse on comptime values" {
    const sig = blades.MetricSignature.euclidean(3);
    const value = evaluate(f32, sig, blade_parsing.SignedBladeNamingOptions.euclidean(3), "(2*e1)^-1", .{});

    try std.testing.expectEqual(@as(f32, 0.5), value.coeffNamed("e1"));
}

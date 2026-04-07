const std = @import("std");

pub const BindingPower = struct {
    left: u8,
    right: u8,
};

pub fn leftAssoc(precedence: u8) BindingPower {
    return .{
        .left = precedence,
        .right = precedence + 1,
    };
}

pub fn rightAssoc(precedence: u8) BindingPower {
    return .{
        .left = precedence,
        .right = precedence,
    };
}

pub fn postfix(precedence: u8) BindingPower {
    return leftAssoc(precedence);
}

pub fn Operator(comptime TokenTag: type) type {
    return struct {
        tag: TokenTag,
        binding_power: BindingPower,
    };
}

pub fn leftAssocOperator(tag: anytype, precedence: u8) Operator(@TypeOf(tag)) {
    return .{
        .tag = tag,
        .binding_power = leftAssoc(precedence),
    };
}

pub fn rightAssocOperator(tag: anytype, precedence: u8) Operator(@TypeOf(tag)) {
    return .{
        .tag = tag,
        .binding_power = rightAssoc(precedence),
    };
}

pub fn postfixOperator(tag: anytype, precedence: u8) Operator(@TypeOf(tag)) {
    return .{
        .tag = tag,
        .binding_power = postfix(precedence),
    };
}

pub fn bindingPowerFor(tag: anytype, operator_table: []const Operator(@TypeOf(tag))) ?BindingPower {
    for (operator_table) |entry| {
        if (entry.tag == tag) return entry.binding_power;
    }

    return null;
}

pub fn ensureContext(comptime Context: type) void {
    if (!@hasDecl(Context, "NodeIndex")) @compileError(@typeName(Context) ++ " must declare `NodeIndex`");
    if (!@hasDecl(Context, "ParseError")) @compileError(@typeName(Context) ++ " must declare `ParseError`");
    if (!@hasDecl(Context, "parsePrefix")) @compileError(@typeName(Context) ++ " must declare `parsePrefix`");
    if (!@hasDecl(Context, "currentBindingPower")) @compileError(@typeName(Context) ++ " must declare `currentBindingPower`");
    if (!@hasDecl(Context, "parseInfix")) @compileError(@typeName(Context) ++ " must declare `parseInfix`");
}

pub fn parseExpression(
    comptime Context: type,
    context: *Context,
    min_bp: u8,
) Context.ParseError!Context.NodeIndex {
    ensureContext(Context);

    var lhs = try context.parsePrefix();

    while (context.currentBindingPower()) |bp| {
        if (bp.left < min_bp) break;
        lhs = try context.parseInfix(lhs, bp);
    }

    return lhs;
}

test "binding power helpers encode associativity" {
    try std.testing.expectEqual(BindingPower{ .left = 3, .right = 4 }, leftAssoc(3));
    try std.testing.expectEqual(BindingPower{ .left = 5, .right = 5 }, rightAssoc(5));
    try std.testing.expectEqual(BindingPower{ .left = 7, .right = 8 }, postfix(7));
}

test "operator table lookup returns matching binding powers" {
    const Tag = enum { plus, star, bang };
    const table: []const Operator(Tag) = &.{
        leftAssocOperator(Tag.plus, 3),
        leftAssocOperator(Tag.star, 5),
        postfixOperator(Tag.bang, 9),
    };
    const empty: []const Operator(Tag) = &.{};

    try std.testing.expectEqual(leftAssoc(3), bindingPowerFor(Tag.plus, table).?);
    try std.testing.expectEqual(leftAssoc(5), bindingPowerFor(Tag.star, table).?);
    try std.testing.expectEqual(postfix(9), bindingPowerFor(Tag.bang, table).?);
    try std.testing.expect(bindingPowerFor(@as(Tag, .plus), empty) == null);
}

test "pratt loop handles precedence, prefix recursion, and postfix operators" {
    const Token = union(enum) {
        eof: void,
        number: i32,
        plus: void,
        star: void,
        minus: void,
        bang: void,
        lparen: void,
        rparen: void,
    };

    const Parser = struct {
        pub const NodeIndex = i32;
        pub const ParseError = error{UnexpectedToken};
        const TokenTag = std.meta.Tag(Token);
        const operator_table: []const Operator(TokenTag) = &.{
            leftAssocOperator(TokenTag.plus, 3),
            leftAssocOperator(TokenTag.star, 5),
            postfixOperator(TokenTag.bang, 9),
        };

        tokens: []const Token,
        index: usize = 0,

        fn current(self: *const @This()) Token {
            return self.tokens[self.index];
        }

        fn advance(self: *@This()) void {
            if (self.index + 1 < self.tokens.len) self.index += 1;
        }

        pub fn parsePrefix(self: *@This()) ParseError!NodeIndex {
            const token = self.current();
            self.advance();
            return switch (token) {
                .number => |value| value,
                .minus => -(try parseExpression(@This(), self, 7)),
                .lparen => blk: {
                    const inner = try parseExpression(@This(), self, 0);
                    switch (self.current()) {
                        .rparen => self.advance(),
                        else => return error.UnexpectedToken,
                    }
                    break :blk inner;
                },
                else => error.UnexpectedToken,
            };
        }

        pub fn currentBindingPower(self: @This()) ?BindingPower {
            return bindingPowerFor(std.meta.activeTag(self.tokens[self.index]), operator_table);
        }

        pub fn parseInfix(self: *@This(), lhs: NodeIndex, bp: BindingPower) ParseError!NodeIndex {
            const token = self.current();
            return switch (token) {
                .bang => blk: {
                    self.advance();
                    break :blk switch (lhs) {
                        0 => 1,
                        1 => 1,
                        2 => 2,
                        3 => 6,
                        4 => 24,
                        5 => 120,
                        else => return error.UnexpectedToken,
                    };
                },
                .plus, .star => blk: {
                    self.advance();
                    const rhs = try parseExpression(@This(), self, bp.right);
                    break :blk switch (token) {
                        .plus => lhs + rhs,
                        .star => lhs * rhs,
                        else => unreachable,
                    };
                },
                else => error.UnexpectedToken,
            };
        }
    };

    var parser = Parser{
        .tokens = &.{
            .{ .minus = {} },
            .{ .number = 2 },
            .{ .bang = {} },
            .{ .plus = {} },
            .{ .number = 3 },
            .{ .star = {} },
            .{ .lparen = {} },
            .{ .number = 4 },
            .{ .plus = {} },
            .{ .number = 1 },
            .{ .rparen = {} },
            .{ .eof = {} },
        },
    };

    try std.testing.expectEqual(@as(i32, 13), try parseExpression(Parser, &parser, 0));
}

test "pratt loop can express right-associative operators with a table" {
    const Token = union(enum) {
        eof: void,
        number: i32,
        caret: void,
    };

    const Parser = struct {
        pub const NodeIndex = i32;
        pub const ParseError = error{UnexpectedToken};
        const TokenTag = std.meta.Tag(Token);
        const operator_table: []const Operator(TokenTag) = &.{
            rightAssocOperator(TokenTag.caret, 7),
        };

        tokens: []const Token,
        index: usize = 0,

        fn current(self: *const @This()) Token {
            return self.tokens[self.index];
        }

        fn advance(self: *@This()) void {
            if (self.index + 1 < self.tokens.len) self.index += 1;
        }

        fn ipow(base: i32, exponent: i32) i32 {
            var result: i32 = 1;
            var i: i32 = 0;
            while (i < exponent) : (i += 1) result *= base;
            return result;
        }

        pub fn parsePrefix(self: *@This()) ParseError!NodeIndex {
            const token = self.current();
            self.advance();
            return switch (token) {
                .number => |value| value,
                else => error.UnexpectedToken,
            };
        }

        pub fn currentBindingPower(self: @This()) ?BindingPower {
            return bindingPowerFor(std.meta.activeTag(self.tokens[self.index]), operator_table);
        }

        pub fn parseInfix(self: *@This(), lhs: NodeIndex, bp: BindingPower) ParseError!NodeIndex {
            const token = self.current();
            self.advance();
            const rhs = try parseExpression(@This(), self, bp.right);
            return switch (token) {
                .caret => ipow(lhs, rhs),
                else => error.UnexpectedToken,
            };
        }
    };

    var parser = Parser{
        .tokens = &.{
            .{ .number = 2 },
            .{ .caret = {} },
            .{ .number = 3 },
            .{ .caret = {} },
            .{ .number = 2 },
            .{ .eof = {} },
        },
    };

    try std.testing.expectEqual(@as(i32, 512), try parseExpression(Parser, &parser, 0));
}

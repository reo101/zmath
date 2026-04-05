const std = @import("std");

pub const BindingPower = struct {
    left: u8,
    right: u8,
};

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

test "pratt loop handles precedence and prefix recursion" {
    const Token = union(enum) {
        eof: void,
        number: i32,
        plus: void,
        star: void,
        minus: void,
        lparen: void,
        rparen: void,
    };

    const Parser = struct {
        pub const NodeIndex = i32;
        pub const ParseError = error{UnexpectedToken};

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
            return switch (self.tokens[self.index]) {
                .plus => .{ .left = 3, .right = 4 },
                .star => .{ .left = 5, .right = 6 },
                else => null,
            };
        }

        pub fn parseInfix(self: *@This(), lhs: NodeIndex, bp: BindingPower) ParseError!NodeIndex {
            const token = self.current();
            self.advance();
            const rhs = try parseExpression(@This(), self, bp.right);
            return switch (token) {
                .plus => lhs + rhs,
                .star => lhs * rhs,
                else => error.UnexpectedToken,
            };
        }
    };

    var parser = Parser{
        .tokens = &.{
            .{ .minus = {} },
            .{ .number = 2 },
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

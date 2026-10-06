const std = @import("std");
const ga = @import("zmath").ga;
const expression = ga.expression;
const sig = ga.blades.MetricSignature.euclidean(3);
const naming = ga.blade_parsing.SignedBladeNamingOptions.fromSignature(sig);

fn compile(source: []const u8) !expression.RuntimeCompiledExpression(f32, sig) {
    return expression.compileRuntime(f32, sig, naming, std.testing.allocator, source);
}

test "runtime expression limits bound source and discarded nodes" {
    var source: [expression.runtime_source_limit + 1]u8 = @splat(' ');
    source[0] = '1';
    var boundary = try compile(source[0..expression.runtime_source_limit]);
    defer boundary.deinit();
    try std.testing.expectError(error.ExpressionTooLarge, compile(&source));
    var unbounded = try expression.compileRuntimeUnbounded(f32, sig, naming, std.testing.allocator, &source);
    defer unbounded.deinit();
    try std.testing.expectEqual(@as(f32, 1), (try unbounded.eval(.{})).scalarCoeff());

    // Constant folding keeps evaluation shallow but must not bypass node limits.
    var additions: [expression.runtime_node_limit + 1]u8 = undefined;
    for (&additions, 0..) |*byte, index| byte.* = if (index % 2 == 0) '1' else '+';
    var below_limit = try compile(additions[0 .. additions.len - 2]);
    defer below_limit.deinit();
    try std.testing.expectEqual(@as(f32, @floatFromInt(expression.runtime_node_limit / 2)), (try below_limit.eval(.{})).scalarCoeff());
    try std.testing.expectError(error.ExpressionTooLarge, compile(&additions));
}

test "runtime expression limits bound parsing and evaluation depth independently" {
    var nested: [2 * expression.runtime_depth_limit + 1]u8 = undefined;
    @memset(nested[0..expression.runtime_depth_limit], '(');
    nested[expression.runtime_depth_limit] = '1';
    @memset(nested[expression.runtime_depth_limit + 1 ..], ')');
    var boundary = try compile(nested[1 .. nested.len - 1]);
    defer boundary.deinit();
    try std.testing.expectError(error.ExpressionTooDeep, compile(&nested));
    var unbounded = try expression.compileRuntimeUnbounded(f32, sig, naming, std.testing.allocator, &nested);
    defer unbounded.deinit();
    try std.testing.expectEqual(@as(f32, 1), (try unbounded.eval(.{})).scalarCoeff());
    @memset(nested[0..expression.runtime_depth_limit], '-');
    nested[expression.runtime_depth_limit] = '1';
    try std.testing.expectError(error.ExpressionTooDeep, compile(nested[0 .. expression.runtime_depth_limit + 1]));

    var chain: [4 * (expression.runtime_depth_limit + 1) - 1]u8 = undefined;
    for (&chain, 0..) |*byte, index| byte.* = "{v}+"[index % 4];
    var shallow = try compile(chain[0 .. chain.len - 4]);
    defer shallow.deinit();
    try std.testing.expectEqual(@as(f32, @floatFromInt(expression.runtime_depth_limit)), (try shallow.eval(.{ .v = @as(f32, 1) })).scalarCoeff());
    try std.testing.expectError(error.ExpressionTooDeep, compile(&chain));
    var deep = try expression.compileRuntimeUnbounded(f32, sig, naming, std.testing.allocator, &chain);
    defer deep.deinit();
    try std.testing.expectEqual(@as(f32, @floatFromInt(expression.runtime_depth_limit + 1)), (try deep.eval(.{ .v = @as(f32, 1) })).scalarCoeff());
}

fn allocationCase(allocator: std.mem.Allocator, invalid: bool) !void {
    const source = "({a}+{b})*e1 + {a} + {b} + {} + {a} + {b} + {a} + {b}";
    var compiled = expression.compileRuntime(f32, sig, naming, allocator, if (invalid) source ++ " + ?" else source) catch |err| {
        if (invalid and err == error.UnexpectedToken) return;
        return err;
    };
    defer compiled.deinit();
    try std.testing.expect(!invalid);
    const Full = ga.Algebra(sig).Instantiate(f32).Full;
    const slots = [_]Full{ Full.zero(), Full.zero(), Full.zero() };
    try std.testing.expect((try compiled.evalSlots(&slots)).eql(Full.zero()));
}

test "runtime expression allocation failures clean partial and completed storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{true});
}

test "runtime expressions handle bytes placeholders and metric classes" {
    for ([_][]const u8{ "\xff", "\xc0\xaf", "\xe2\x88", "\x00", "e1 + \x80" }) |source| {
        try std.testing.expectError(error.UnexpectedToken, compile(source));
    }
    // Placeholder names remain opaque trimmed byte strings, not UTF-8 identifiers.
    var opaque_placeholder = try compile("{\xff}");
    defer opaque_placeholder.deinit();
    try std.testing.expectEqualSlices(u8, "\xff", opaque_placeholder.placeholders[0]);
    inline for (.{
        ga.blades.MetricSignature{ .p = 3 },
        ga.blades.MetricSignature{ .p = 2, .q = 1 },
        ga.blades.MetricSignature{ .p = 2, .r = 1 },
        ga.blades.MetricSignature{ .p = 1, .q = 1, .r = 1 },
    }) |metric| {
        const Algebra = ga.Algebra(metric).Instantiate(f32);
        var compiled = try expression.compileRuntime(f32, metric, .fromSignature(metric), std.testing.allocator, "({v}+e1)*2-{v}");
        defer compiled.deinit();
        const vector = Algebra.Basis.e(1).scale(3);
        const expected = vector.add(Algebra.Basis.e(1).scale(2)).cast(Algebra.Full);
        try std.testing.expect((try compiled.eval(.{ .v = vector })).eql(expected));
        const slots = [_]Algebra.Full{vector.cast(Algebra.Full)};
        try std.testing.expect((try compiled.evalSlots(&slots)).eql(expected));
        try std.testing.expectError(error.PlaceholderCountMismatch, compiled.evalSlots(&.{}));
        try std.testing.expectError(error.PlaceholderCountMismatch, compiled.eval(.{}));
        try std.testing.expectError(error.MissingPlaceholderArgument, compiled.eval(.{ .other = @as(f32, 1) }));
    }
}

const zmath = @import("zmath");

comptime {
    const P2 = zmath.ga.Algebra(.{ .p = 2, .r = 1 }).Instantiate(f32);
    _ = P2.compileExpr("{v} \\hodge");
}

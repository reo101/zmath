const zmath = @import("zmath");
const operation = @import("build_options").operation;

comptime {
    const Euclidean = zmath.ga.Algebra(.euclidean(2)).Instantiate(f32);
    const Lorentz = zmath.ga.Algebra(.{ .p = 1, .q = 1 }).Instantiate(f32);
    const Projective = zmath.ga.Algebra(.{ .p = 1, .r = 1 }).Instantiate(f32);
    const lhs = Euclidean.Vector.init(.{ 1, 2 });
    const rhs = if (operation == .degenerate_gp) Projective.Vector.init(.{ 1, 2 }) else Lorentz.Vector.init(.{ 1, 2 });

    switch (operation) {
        .add => _ = lhs.add(rhs),
        .sub => _ = lhs.sub(rhs),
        .gp, .degenerate_gp => _ = lhs.gp(rhs),
        .gp_grade => _ = lhs.gpGrade(rhs, 0),
        .wedge => _ = lhs.wedge(rhs),
        .left_contraction => _ = lhs.leftContraction(rhs),
        .right_contraction => _ = lhs.rightContraction(rhs),
        .dot => _ = lhs.dot(rhs),
        .scalar_product => _ = lhs.scalarProduct(rhs),
        .eql => _ = lhs.eql(rhs),
        .join => _ = lhs.join(rhs),
        .anti_geometric => _ = lhs.antiGeometric(rhs),
        .anti_dot => _ = lhs.antiDot(rhs),
        .sandwich => _ = lhs.sandwich(rhs),
    }
}

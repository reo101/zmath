const std = @import("std");
const zmath = @import("zmath");
const input_case = @import("build_options").input_case;

comptime {
    const P2 = zmath.ga.Algebra(.{ .p = 2, .r = 1 }).Instantiate(f64);
    const E4 = zmath.ga.Algebra(.euclidean(4)).Instantiate(f64);
    switch (input_case) {
        .non_bivector => _ = P2.Basis.e(3).exp(),
        .nonscalar_square => _ = E4.Basis.signedBlade("e12").add(E4.Basis.signedBlade("e34")).exp(),
        .nan_coefficient => _ = P2.Basis.signedBlade("e13").scale(std.math.nan(f64)).exp(),
        .infinite_coefficient => _ = P2.Basis.signedBlade("e13").scale(std.math.inf(f64)).exp(),
        .non_finite_square => _ = E4.Basis.signedBlade("e12").scale(std.math.floatMax(f64)).exp(),
    }
}

const ga = @import("ga");

comptime {
    const E4 = ga.Algebra(.euclidean(4)).Instantiate(f32);
    // Scalar denominator 1, but a nonzero e1234 term outside the input support.
    const nonversor = E4.Scalar.init(.{0})
        .add(E4.signedBlade("e12"))
        .add(E4.signedBlade("e34"))
        .scale(1.0 / @sqrt(@as(f32, 2)));
    ga.rotors.debugAssertRotor(nonversor, 1e-5);
}

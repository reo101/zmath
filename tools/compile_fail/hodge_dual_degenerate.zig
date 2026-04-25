const zmath = @import("zmath");

comptime {
    const P2 = zmath.ga.family.projectiveEuclidean(2).Instantiate(f32);
    _ = P2.Basis.e(1).hodgeDual();
}
